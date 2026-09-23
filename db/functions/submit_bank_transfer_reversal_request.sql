-- db/functions/submit_bank_transfer_reversal_request.sql
-- PAY-REQ-1 · Batch B(2026-09-23,Tim 的 Q4):提一张【转账冲销】申请。
-- 理由必填(它就是审批人要读的那一句,也是冲销分录上的备注)。冲销日在执行那一步给(必填)。
-- 同一笔转账同时只能有一张未了结的冲销申请(payment_requests_one_open_transfer_reversal)。
-- 金额、两个账户从原转账【抄过来】,只供审批人看;执行时引擎照原分录逐行翻边。
-- 提交时试跑一遍:已冲销、期间锁这些在这里就按原话拒。
-- NOTE: introduced by db/migrations/2026-09-23-payreqb-transfers-and-wht-through-requests.sql.

CREATE OR REPLACE FUNCTION public.submit_bank_transfer_reversal_request(p_transfer_id uuid, p_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t    bank_transfers%ROWTYPE;
    v_id   uuid := gen_random_uuid();
    v_code text;
    v_res  jsonb;
    v_on   boolean := approvals_enabled();
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_t FROM bank_transfers WHERE id = p_transfer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRANSFER_NOT_FOUND|%', COALESCE(p_transfer_id::text, '?');
    END IF;
    IF v_t.reversed_at IS NOT NULL THEN
        RAISE EXCEPTION 'TRANSFER_ALREADY_REVERSED|%', p_transfer_id;
    END IF;
    IF p_notes IS NULL OR btrim(p_notes) = '' THEN
        RAISE EXCEPTION 'REVERSAL_REASON_REQUIRED';
    END IF;
    IF EXISTS (SELECT 1 FROM payment_requests r
                WHERE r.transfer_id = p_transfer_id AND r.kind = 'bank_transfer_reversal'
                  AND r.status IN ('submitted', 'approved')) THEN
        RAISE EXCEPTION 'TRANSFER_REVERSAL_ALREADY_REQUESTED|%', p_transfer_id;
    END IF;

    v_code := next_payment_request_code(CURRENT_DATE);
    INSERT INTO payment_requests (id, code, kind, status, counterparty_type,
                                  amount_ccy, currency, amount_base, bank_account_code,
                                  to_account_code, amount_in, bank_reference,
                                  transfer_id, notes, created_by)
    VALUES (v_id, v_code, 'bank_transfer_reversal',
            CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
            NULL,
            v_t.amount_out, bank_native_currency(v_t.from_account), 0, v_t.from_account,
            v_t.to_account, v_t.amount_in, v_t.bank_reference,
            p_transfer_id, btrim(p_notes), auth.uid());

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
