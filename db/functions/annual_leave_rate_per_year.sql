-- db/functions/annual_leave_rate_per_year.sql
-- 当月适用的【年额】。界面上的「年假(天/年)」就是这个数 ——
-- 它是一个【费率】不是余额:上个月入职的人费率 24/年,但只能请 2 天。
--
-- NOTE: introduced by db/migrations/2026-08-06-hr2c-monthly-accrual.sql;
--       annual-rate form by db/migrations/2026-08-07-hr2c-fu1-annual-rate-and-immutable-rates.sql.

CREATE OR REPLACE FUNCTION public.annual_leave_rate_per_year(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT (leave_accrual_rate(
                p_employee_id,
                employee_work_category_at(p_employee_id, date_trunc('month', p_as_of)::date),
                date_trunc('month', p_as_of)::date
            )->>'days_per_year')::numeric;
$function$
;