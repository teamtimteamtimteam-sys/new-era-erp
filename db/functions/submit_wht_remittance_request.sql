-- db/functions/submit_wht_remittance_request.sql
-- PAY-REQ-1 · Batch B(2026-09-23,Tim 的 Q15):提一张【代扣税缴纳】申请。
--
-- ★【金额是推导出来的,申请冻结的是提交那一刻的数】欠多少从 wht_liability_by_month 读
--   (与 remit_wht_internal 读同一张视图 —— 不在这里另算一份)。CFO 批的就是这个数;
--   执行时推导值变了,remit_wht_internal 按名拒 WHT_REMIT_AMOUNT_CHANGED。
-- ★ 同一个代扣月同时只能有一张未了结的缴纳申请(payment_requests_one_open_wht_month):
--   两张各自都试跑得过、合起来汇两遍,是试跑看不见的(试跑只看已过账的缴纳)。
--
-- 参考号必填、银行默认 1000 且必须是本位币户 —— 与 remit_wht 同一组规矩,由试跑按原话拒。
-- 两道权限检查与 remit_wht 同形:edit,以及读那张视图要的 view(WHT-1 fu1)。
-- 日期与参考号的 DEFAULT NULL 与 remit_wht 同一条:页面空着就【不传】,由这里按名拒
-- (WHT_REMIT_DATE_REQUIRED / WHT_FILED_REFERENCE_REQUIRED)—— 不是一个默认值。
-- NOTE: introduced by db/migrations/2026-09-23-payreqb-transfers-and-wht-through-requests.sql.

CREATE OR REPLACE FUNCTION public.submit_wht_remittance_request(p_period_month date, p_planned_date date DEFAULT NULL::date, p_filed_reference text DEFAULT NULL::text, p_bank_account text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_month  date;
    v_ref    text;
    v_amount numeric;
    v_id     uuid := gen_random_uuid();
    v_code   text;
    v_res    jsonb;
    v_on     boolean := approvals_enabled();
BEGIN
    PERFORM require_permission('module.finance.edit');
    PERFORM require_permission('module.finance.view');

    IF p_period_month IS NULL THEN
        RAISE EXCEPTION 'WHT_PERIOD_REQUIRED';
    END IF;
    v_month := date_trunc('month', p_period_month)::date;
    IF p_planned_date IS NULL THEN
        RAISE EXCEPTION 'WHT_REMIT_DATE_REQUIRED|%', v_month;
    END IF;
    v_ref := NULLIF(btrim(COALESCE(p_filed_reference, '')), '');
    IF v_ref IS NULL THEN
        RAISE EXCEPTION 'WHT_FILED_REFERENCE_REQUIRED|%', v_month;
    END IF;
    IF EXISTS (SELECT 1 FROM payment_requests r
                WHERE r.period_month = v_month AND r.kind = 'wht_remittance'
                  AND r.status IN ('submitted', 'approved')) THEN
        RAISE EXCEPTION 'WHT_REMITTANCE_ALREADY_REQUESTED|%', v_month;
    END IF;

    SELECT unremitted_base INTO v_amount FROM wht_liability_by_month WHERE period_month = v_month;
    IF COALESCE(v_amount, 0) <= 0 THEN
        RAISE EXCEPTION 'WHT_NOTHING_TO_REMIT|%|%', v_month, COALESCE(v_amount, 0);
    END IF;

    v_code := next_payment_request_code(p_planned_date);
    INSERT INTO payment_requests (id, code, kind, status, counterparty_type,
                                  amount_ccy, currency, amount_base, bank_account_code,
                                  period_month, filed_reference, planned_date, notes, created_by)
    VALUES (v_id, v_code, 'wht_remittance',
            CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
            NULL,
            v_amount, base_currency_code(), v_amount,
            COALESCE(NULLIF(btrim(COALESCE(p_bank_account, '')), ''), '1000'),
            v_month, v_ref, p_planned_date, NULLIF(btrim(COALESCE(p_notes, '')), ''), auth.uid());

    v_res := payment_request_dry_run(v_id);
    UPDATE payment_requests SET amount_base = (v_res->>'amount_base')::numeric WHERE id = v_id;

    IF v_on THEN
        PERFORM record_approval_decision('payment_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        PERFORM record_approval_decision('payment_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved,没有人按过批准');
    END IF;

    RETURN jsonb_build_object('request_id', v_id, 'code', v_code,
                              'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
                              'amount_base', (v_res->>'amount_base')::numeric);
END;
$function$
;
