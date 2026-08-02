-- db/functions/annual_leave_rate_per_month.sql
-- 当月适用的每月累积天数。界面上的「年度天数」= 这个数 × 12,
-- 那是一个【费率】不是余额 —— 上个月入职的人费率 24/年,但只能请 2 天。
--
-- NOTE: introduced/updated by db/migrations/2026-08-06-hr2c-monthly-accrual.sql.

CREATE OR REPLACE FUNCTION public.annual_leave_rate_per_month(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT (leave_accrual_rate(
                p_employee_id,
                employee_work_category_at(p_employee_id, date_trunc('month', p_as_of)::date),
                date_trunc('month', p_as_of)::date
            )->>'days_per_month')::numeric;
$function$
;