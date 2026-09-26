-- db/functions/withdraw_terms_request.sql
-- APR-8(2026-09-26):撤回一张在等的条款申请。谁能撤:提单人本人(按人认),或持这一种那个码的人
-- (公式 module.pricing.edit · 合同 action.contract_terms)。只撤 submitted。撤回什么都不生效、冻结随之解开;
-- 新建公式的申请撤回后,那张公式停用着留下。记在本行上,【不】写 approval_log(撤回不是一次决定)。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.withdraw_terms_request(p_request_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r terms_requests%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM terms_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TERMS_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF self_leg(v_r.created_by, NULL, auth.uid()) <> 'raiser' THEN
        PERFORM require_permission(CASE WHEN v_r.kind = 'contract_activate' THEN 'action.contract_terms'
                                        ELSE 'module.pricing.edit' END);
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'TERMS_REQUEST_NOT_OPEN|%|%', v_r.label, v_r.status;
    END IF;
    UPDATE terms_requests
       SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid(),
           withdraw_reason = NULLIF(btrim(COALESCE(p_reason, '')), '')
     WHERE id = p_request_id;
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'withdrawn');
END;
$function$;
