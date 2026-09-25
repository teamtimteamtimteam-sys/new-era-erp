-- db/functions/receipt_price_withdraw_internal.sql
-- ROLE-1 Batch 4b(2026-09-25,Tim 的 Q3 · Q5 · Q7):撤回一张在等的定价申请,记下谁、何时,以及(有的话)为什么。
-- 三个调用者:withdraw_receipt_price_request(人按的)· unapply_assay_result(撤销应用化验撤回它那张)·
-- apply_assay_result(一份新化验取代在等的那张化验申请)。系统撤回的理由由调用者写明
-- 是哪一份化验、为什么;人按的撤回理由可空(工资申请的撤回连理由都不收)。只撤 submitted;不写 approval_log(撤回不是一次决定)。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.receipt_price_withdraw_internal(p_request_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r receipt_price_requests%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM receipt_price_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_NOT_OPEN|%|%', v_r.label, v_r.status;
    END IF;
    UPDATE receipt_price_requests
       SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid(),
           withdraw_reason = NULLIF(btrim(COALESCE(p_reason, '')), '')
     WHERE id = p_request_id;
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'withdrawn');
END;
$function$
;
