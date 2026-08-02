-- db/functions/accrued_annual_leave.sql
-- 当年度已累积、可请的天数(向下取到 0.5 天)。明细见 accrued_annual_leave_detail。
--
-- NOTE: introduced/updated by db/migrations/2026-08-06-hr2c-monthly-accrual.sql.

CREATE OR REPLACE FUNCTION public.accrued_annual_leave(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT (accrued_annual_leave_detail(p_employee_id, p_as_of)->>'accrued_days')::numeric;
$function$
;