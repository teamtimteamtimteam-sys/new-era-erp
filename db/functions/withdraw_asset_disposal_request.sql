-- db/functions/withdraw_asset_disposal_request.sql
-- APR-9(2026-09-27):撤回一张在等的处置申请。谁能撤:提单人本人(按人认),或持 module.finance.edit 的人
-- (提单的那个码)。只撤 submitted。撤回什么都不处置、冻结随之解开;记在本行上,【不】写 approval_log。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.withdraw_asset_disposal_request(p_request_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r asset_disposal_requests%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM asset_disposal_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSET_DISPOSAL_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF self_leg(v_r.created_by, NULL, auth.uid()) <> 'raiser' THEN
        PERFORM require_permission('module.finance.edit');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'ASSET_DISPOSAL_NOT_OPEN|%|%', v_r.label, v_r.status;
    END IF;
    UPDATE asset_disposal_requests
       SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid(),
           withdraw_reason = NULLIF(btrim(COALESCE(p_reason, '')), '')
     WHERE id = p_request_id;
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'withdrawn');
END;
$function$;
