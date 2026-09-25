-- db/functions/withdraw_warehouse_request.sql
-- APR-7(2026-09-25):撤回一张在等的仓库申请。谁能撤:提单人本人(按人认),或持这一种那个码的人
-- (注销 action.batch_write_off · 回滚 action.processing_rollback · 作废 action.issue_cod)。
-- 只撤 submitted。撤回什么都不生效、冻结随之解开;记在本行上,【不】写 approval_log(撤回不是一次决定)。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.withdraw_warehouse_request(p_request_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r warehouse_requests%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM warehouse_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF self_leg(v_r.created_by, NULL, auth.uid()) <> 'raiser' THEN
        PERFORM require_permission(CASE v_r.kind WHEN 'rollback' THEN 'action.processing_rollback'
                                                 WHEN 'cod_void' THEN 'action.issue_cod'
                                                 ELSE 'action.batch_write_off' END);
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_NOT_OPEN|%|%', v_r.label, v_r.status;
    END IF;
    UPDATE warehouse_requests
       SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid(),
           withdraw_reason = NULLIF(btrim(COALESCE(p_reason, '')), '')
     WHERE id = p_request_id;
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'withdrawn');
END;
$function$;
