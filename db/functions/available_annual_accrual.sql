-- db/functions/available_annual_accrual.sql
-- 当年度累积里还剩多少(不含结转)。【不查权限】—— 它是个算式,
-- 谁看得见哪一行由调用方决定(视图的谓词 / leave_balance 的检查)。
--
-- NOTE: introduced/updated by db/migrations/2026-08-06-hr2c-monthly-accrual.sql.

CREATE OR REPLACE FUNCTION public.available_annual_accrual(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
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
    RETURN (SELECT accrued_annual_leave(p_employee_id, p_as_of)
         - consumed_from_accrual(p_employee_id, EXTRACT(YEAR FROM p_as_of)::integer));
END;
$function$
;