-- db/functions/withdraw_receipt_price_request.sql
-- ROLE-1 Batch 4b(2026-09-25,Tim 的 Q7):撤回一张在等的收货定价申请。
-- 谁能撤:提单人本人(按人认 —— self_leg 说这个账号就是提单人那个人),或任何持 action.price_receipts
-- 的人(财务)。化验来源的申请,提单的 cto 自己撤得了;撤销应用那份化验也会撤回它
-- (unapply_assay_result)。撤回不过账,只是放弃;不写 approval_log(撤回不是一次决定)。
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.withdraw_receipt_price_request(p_request_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r receipt_price_requests%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM receipt_price_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF self_leg(v_r.created_by, NULL, auth.uid()) <> 'raiser' THEN
        PERFORM require_permission('action.price_receipts');
    END IF;
    RETURN receipt_price_withdraw_internal(p_request_id, p_reason);
END;
$function$
;
