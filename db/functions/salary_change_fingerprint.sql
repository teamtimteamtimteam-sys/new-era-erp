-- db/functions/salary_change_fingerprint.sql
-- APR-9(2026-09-27,grilling Q6):一张调薪申请批的是【哪一个起点】—— 提交那一刻的月薪与在职状态。
-- 提交时存进 salary_change_requests.snapshot,批准时再算一遍比:不一样(中间批了一张绩效评估、人离职了、
-- 依法清空了)→ SALARY_CHANGED_SINCE_REQUEST,申请仍在等。员工不存在 → NULL(调用方先查过存在)。
-- 它交出月薪:EXECUTE 已从 authenticated 收回(没有调用者检查,靠的就是调不到)。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.salary_change_fingerprint(p_employee_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT jsonb_build_object('monthly_salary', e.monthly_salary,
                              'employment_status', e.employment_status,
                              'anonymised', e.anonymised_at IS NOT NULL,
                              'deleted', e.deleted_at IS NOT NULL)
      FROM employees e
     WHERE e.id = p_employee_id;
$function$;
