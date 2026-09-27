-- db/functions/salary_change_open.sql
-- APR-9(2026-09-27,grilling Q6):**一个人同一时刻只有一次在途调薪,跨两条路** —— 一份判据。
--   一张 submitted 的调薪申请                                → 它的 label
--   一张 submitted、带 new_monthly_salary 的绩效评估          → 'review:' || 评估 id
--   都没有                                                   → NULL
-- 读者:submit_salary_change_request(SALARY_CHANGE_OPEN)· submit_review(同一句拒绝,带调薪的评估才问)。
-- 唯一索引 salary_change_requests_one_open 是申请那一侧的第二道;评估那一侧没有索引能跨表,所以这里是唯一的一道,
-- 两扇提交的门都锁员工行(FOR UPDATE)再问它。EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.salary_change_open(p_employee_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(
        (SELECT q.label FROM salary_change_requests q
          WHERE q.employee_id = p_employee_id AND q.status = 'submitted'
          LIMIT 1),
        (SELECT 'review:' || r.id::text FROM performance_reviews r
          WHERE r.employee_id = p_employee_id AND r.status = 'submitted'
            AND r.new_monthly_salary IS NOT NULL
          ORDER BY r.submitted_at
          LIMIT 1));
$function$;
