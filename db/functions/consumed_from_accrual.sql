-- db/functions/consumed_from_accrual.sql
-- 某一年的【派生累积】里已经用掉的天数(draw − release)。
--
-- NOTE: introduced/updated by db/migrations/2026-08-06-hr2c-monthly-accrual.sql.

CREATE OR REPLACE FUNCTION public.consumed_from_accrual(p_employee_id uuid, p_leave_year integer)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【本人或 HR】与 leave_balance 同一道口径。
    -- U1-B(U1A-SELF-GATE-NULL-TRAP):没有员工档案的账号,current_user_employee() 是 NULL,
    --   NOT (false OR NULL) 是 NULL,IF NULL 不进分支 —— 门曾经是开的。COALESCE 把「未知」读成「不是本人」。
    IF NOT (has_permission('module.hr.view') OR COALESCE(p_employee_id = current_user_employee(), false)) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;
    RETURN (SELECT COALESCE(SUM(CASE WHEN c.entry_type = 'draw' THEN c.days ELSE -c.days END), 0)
    FROM leave_consumption c
    JOIN leave_requests r ON r.id = c.leave_request_id
    WHERE c.accrual_year = p_leave_year AND r.employee_id = p_employee_id);
END;
$function$
;