-- db/functions/withdraw_payment_request.sql
-- PAY-REQ-1(2026-09-23):撤回一张申请。submitted 与 approved 都可以撤回
-- (approved 那一格的理由写在 payment_requests 表抬头:一张付不出去的申请不许永远
-- 占着它要付的单据)。撤回不花钱、不过账,只是放弃;paid / rejected / withdrawn 不能撤。
-- 谁能撤:财务(module.finance.edit)—— 提单人本来就持这个码。
-- 不写 approval_log:撤回不是一次【决定】,是提单一方收回请求(与报销单的撤回同一条)。
-- NOTE: introduced by db/migrations/2026-09-23-payreq1a-money-leaves-only-after-approval.sql.

CREATE OR REPLACE FUNCTION public.withdraw_payment_request(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r payment_requests%ROWTYPE;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_r FROM payment_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYMENT_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.status NOT IN ('submitted', 'approved') THEN
        RAISE EXCEPTION 'PAYMENT_REQUEST_NOT_OPEN|%|%', v_r.code, v_r.status;
    END IF;
    UPDATE payment_requests
       SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid()
     WHERE id = p_request_id;
    RETURN jsonb_build_object('request_id', p_request_id, 'code', v_r.code, 'status', 'withdrawn');
END;
$function$
;
