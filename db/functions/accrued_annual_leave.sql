-- db/functions/accrued_annual_leave.sql
-- 当年度已累积、可请的天数(向下取到 0.5 天)。明细见 accrued_annual_leave_detail。
--
-- NOTE: introduced/updated by db/migrations/2026-08-06-hr2c-monthly-accrual.sql.

CREATE OR REPLACE FUNCTION public.accrued_annual_leave(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
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
    RETURN (SELECT (accrued_annual_leave_detail(p_employee_id, p_as_of)->>'accrued_days')::numeric);
END;
$function$
;