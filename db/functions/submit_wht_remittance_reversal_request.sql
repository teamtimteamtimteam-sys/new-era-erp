-- db/functions/submit_wht_remittance_reversal_request.sql
-- PAY-REQ-1 · Batch B(2026-09-23,Tim 的 Q3):提一张【代扣税缴纳冲销】申请 ——
-- 一笔缴纳的更正从此走这里(通用冲销口对 wht_remittance 的分录同一刀关上)。
-- 理由必填;冲销日在执行那一步给(必填)。同一笔缴纳同时只能有一张未了结的冲销申请。
-- 金额从原缴纳【抄过来】,只供审批人看;执行时引擎照原分录逐行翻边
-- (reverse_wht_remittance_internal),这个月的欠款于是原样回来。
-- NOTE: introduced by db/migrations/2026-09-23-payreqb-transfers-and-wht-through-requests.sql.

CREATE OR REPLACE FUNCTION public.submit_wht_remittance_reversal_request(p_remittance_id uuid, p_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_w    wht_remittances%ROWTYPE;
    v_st   text;
    v_id   uuid := gen_random_uuid();
    v_code text;
    v_res  jsonb;
    v_on   boolean := approvals_enabled();
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_w FROM wht_remittances WHERE id = p_remittance_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WHT_REMITTANCE_NOT_FOUND|%', COALESCE(p_remittance_id::text, '?');
    END IF;
    SELECT status INTO v_st FROM journal_entries WHERE id = v_w.journal_entry_id;
    IF v_st IS DISTINCT FROM 'posted' THEN
        RAISE EXCEPTION 'WHT_REMITTANCE_ALREADY_REVERSED|%', v_w.code;
    END IF;
    IF p_notes IS NULL OR btrim(p_notes) = '' THEN
        RAISE EXCEPTION 'REVERSAL_REASON_REQUIRED';
    END IF;
    IF EXISTS (SELECT 1 FROM payment_requests r
                WHERE r.wht_remittance_id = p_remittance_id AND r.kind = 'wht_remittance_reversal'
                  AND r.status IN ('submitted', 'approved')) THEN
        RAISE EXCEPTION 'WHT_REVERSAL_ALREADY_REQUESTED|%', v_w.code;
    END IF;

    -- ★ ROLE-1 Batch 3a(Q12):提单人之外没人批得动 → 按名拒(审批关着时不拒)。先于取号:拒了不烧号。
    PERFORM assert_other_decider('payment_request', 'decide_payment_request', 2::smallint,
                                 'PAYMENT_REQUEST_NO_OTHER_DECIDER');
    v_code := next_payment_request_code(CURRENT_DATE);
    INSERT INTO payment_requests (id, code, kind, status, counterparty_type,
                                  amount_ccy, currency, amount_base,
                                  period_month, filed_reference, wht_remittance_id, notes, created_by)
    VALUES (v_id, v_code, 'wht_remittance_reversal',
            CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
            NULL,
            v_w.amount_base, base_currency_code(), v_w.amount_base,
            v_w.period_month, v_w.filed_reference, p_remittance_id, btrim(p_notes), auth.uid());

    v_res := payment_request_dry_run(v_id);
    UPDATE payment_requests SET amount_base = (v_res->>'amount_base')::numeric WHERE id = v_id;

    IF v_on THEN
        PERFORM record_approval_decision('payment_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        PERFORM record_approval_decision('payment_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved,没有人按过批准');
    END IF;

    RETURN jsonb_build_object('request_id', v_id, 'code', v_code,
                              'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END);
END;
$function$
;
