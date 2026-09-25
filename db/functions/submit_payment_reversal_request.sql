-- db/functions/submit_payment_reversal_request.sql
-- PAY-REQ-1(2026-09-23,Tim 的 Q6):提一张【冲销】申请 —— 收款或出款都算。
-- 理由必填(它就是审批人要读的那一句,也是冲销分录上的备注)。
-- 同一笔付款同时只能有一张未了结的冲销申请(payment_requests_one_open_reversal)。
-- 提交时照 reverse_payment_internal 试跑一遍:已冲销、期间锁这些在这里就按原话拒。
--
-- 【审批关着时】生下来就是 approved,留痕 auto_approved —— 与出款申请同一条(Q8)。
-- NOTE: introduced by db/migrations/2026-09-23-payreq1a-money-leaves-only-after-approval.sql.

CREATE OR REPLACE FUNCTION public.submit_payment_reversal_request(p_payment_id uuid, p_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p    payments%ROWTYPE;
    v_id   uuid := gen_random_uuid();
    v_code text;
    v_on   boolean := approvals_enabled();
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_p FROM payments WHERE id = p_payment_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYMENT_NOT_FOUND|%', COALESCE(p_payment_id::text, '?');
    END IF;
    IF v_p.status <> 'posted' OR v_p.reversed_by_payment IS NOT NULL THEN
        RAISE EXCEPTION 'PAYMENT_ALREADY_REVERSED|%', v_p.code;
    END IF;
    IF p_notes IS NULL OR btrim(p_notes) = '' THEN
        RAISE EXCEPTION 'PAYMENT_REVERSAL_REASON_REQUIRED|%', v_p.code;
    END IF;
    IF EXISTS (SELECT 1 FROM payment_requests r
                WHERE r.payment_id = p_payment_id AND r.kind = 'payment_reversal'
                  AND r.status IN ('submitted', 'approved')) THEN
        RAISE EXCEPTION 'PAYMENT_REVERSAL_ALREADY_REQUESTED|%', v_p.code;
    END IF;

    -- ★ ROLE-1 Batch 3a(Q12):提单人之外没人批得动 → 按名拒(审批关着时不拒)。先于取号:拒了不烧号。
    PERFORM assert_other_decider('payment_request', 'decide_payment_request', 2::smallint,
                                 'PAYMENT_REQUEST_NO_OTHER_DECIDER');
    v_code := next_payment_request_code(CURRENT_DATE);
    INSERT INTO payment_requests (id, code, kind, status, counterparty_type,
                                  supplier_id, employee_id, customer_id,
                                  amount_ccy, currency, amount_base, fx_rate, bank_account_code,
                                  payment_id, notes, created_by)
    VALUES (v_id, v_code, 'payment_reversal',
            CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
            v_p.counterparty_type, v_p.supplier_id, v_p.employee_id, v_p.customer_id,
            v_p.amount_ccy, v_p.currency, v_p.amount_base, NULL, v_p.bank_account_code,
            p_payment_id, btrim(p_notes), auth.uid());

    PERFORM payment_request_dry_run(v_id);

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
