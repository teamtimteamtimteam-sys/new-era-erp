-- db/functions/withdraw_salary_change_request.sql
-- APR-9(2026-09-27):撤回一张在等的调薪申请。谁能撤:提单人本人(按人认),或持提单那一对码的人
-- (module.hr.edit + data.view_pay —— 财务;提单人休假时同事能收回它)。只撤 submitted。
-- 撤回什么都不生效;记在本行上,【不】写 approval_log(撤回不是一次决定 —— ROLE-1 Batch 3a 的记录裁定)。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.withdraw_salary_change_request(p_request_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r salary_change_requests%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM salary_change_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SALARY_CHANGE_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF self_leg(v_r.created_by, NULL, auth.uid()) <> 'raiser' THEN
        PERFORM require_permission('module.hr.edit');
        PERFORM require_permission('data.view_pay');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'SALARY_CHANGE_NOT_OPEN|%|%', v_r.label, v_r.status;
    END IF;
    UPDATE salary_change_requests
       SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid(),
           withdraw_reason = NULLIF(btrim(COALESCE(p_reason, '')), '')
     WHERE id = p_request_id;
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'withdrawn');
END;
$function$;
