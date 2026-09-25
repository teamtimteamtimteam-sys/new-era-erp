-- db/functions/submit_bank_transfer_request.sql
-- PAY-REQ-1 · Batch B(2026-09-23,Tim 的 Q15):提一张【行内转账】申请。
-- 参数与 record_bank_transfer 同一组(日期那一格是【计划】转账日;真正的转账日在执行那一步给)。
--
-- 顺序:权限 → 必填 → 落一行 → 按引擎试跑一遍(同币种金额不等、同一个账户、期间锁……
-- 都在这里按原话拒)→ 本位币额取试跑那张分录的借方合计 → 按审批开关定状态、写留痕。
-- 批的是冻结的那组:两个账户、两边金额、参考号;执行时一个字都改不了。
--
-- 【没有收款人】转账是两个自家账户之间挪钱,counterparty_type 为 NULL(表的形状约束允许
-- 且只允许这四种新申请这样)。付款的那道"收款人被拉黑/暂停"检查于是不适用。
--
-- 【审批关着时】生下来就是 approved,留痕 auto_approved —— 与出款申请同一条(Batch A 的 Q8)。
-- NOTE: introduced by db/migrations/2026-09-23-payreqb-transfers-and-wht-through-requests.sql.

CREATE OR REPLACE FUNCTION public.submit_bank_transfer_request(p_planned_date date, p_from_account text, p_to_account text, p_amount_out numeric, p_amount_in numeric, p_bank_reference text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id   uuid := gen_random_uuid();
    v_code text;
    v_res  jsonb;
    v_on   boolean := approvals_enabled();
BEGIN
    PERFORM require_permission('module.finance.edit');

    IF p_planned_date IS NULL THEN
        RAISE EXCEPTION 'DATE_REQUIRED';
    END IF;
    IF p_from_account IS NULL OR p_from_account NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', COALESCE(p_from_account, '?');
    END IF;
    IF p_to_account IS NULL OR p_to_account NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', COALESCE(p_to_account, '?');
    END IF;
    IF p_amount_out IS NULL OR p_amount_out <= 0 OR p_amount_in IS NULL OR p_amount_in <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;

    -- ★ ROLE-1 Batch 3a(Q12):提单人之外没人批得动 → 按名拒(审批关着时不拒)。先于取号:拒了不烧号。
    PERFORM assert_other_decider('payment_request', 'decide_payment_request', 2::smallint,
                                 'PAYMENT_REQUEST_NO_OTHER_DECIDER');
    v_code := next_payment_request_code(p_planned_date);
    INSERT INTO payment_requests (id, code, kind, status, counterparty_type,
                                  amount_ccy, currency, amount_base, bank_account_code,
                                  to_account_code, amount_in, bank_reference,
                                  planned_date, notes, created_by)
    VALUES (v_id, v_code, 'bank_transfer',
            CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
            NULL,
            p_amount_out, bank_native_currency(p_from_account), 0, p_from_account,
            p_to_account, p_amount_in, NULLIF(btrim(COALESCE(p_bank_reference, '')), ''),
            p_planned_date, NULLIF(btrim(COALESCE(p_notes, '')), ''), auth.uid());

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
