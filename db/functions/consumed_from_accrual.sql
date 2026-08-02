-- db/functions/consumed_from_accrual.sql
-- 某一年的【派生累积】里已经用掉的天数(draw − release)。
--
-- NOTE: introduced/updated by db/migrations/2026-08-06-hr2c-monthly-accrual.sql.

CREATE OR REPLACE FUNCTION public.consumed_from_accrual(p_employee_id uuid, p_leave_year integer)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(SUM(CASE WHEN c.entry_type = 'draw' THEN c.days ELSE -c.days END), 0)
    FROM leave_consumption c
    JOIN leave_requests r ON r.id = c.leave_request_id
    WHERE c.accrual_year = p_leave_year AND r.employee_id = p_employee_id;
$function$
;