-- db/functions/annual_leave_rate_per_year.sql
-- 当月适用的【年额】。界面上的「年假(天/年)」就是这个数 ——
-- 它是一个【费率】不是余额:上个月入职的人费率 24/年,但只能请 2 天。
--
-- NOTE: introduced by db/migrations/2026-08-06-hr2c-monthly-accrual.sql;
--       annual-rate form by db/migrations/2026-08-07-hr2c-fu1-annual-rate-and-immutable-rates.sql.

CREATE OR REPLACE FUNCTION public.annual_leave_rate_per_year(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
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
    RETURN (SELECT (leave_accrual_rate(
                p_employee_id,
                employee_work_category_at(p_employee_id, date_trunc('month', p_as_of)::date),
                date_trunc('month', p_as_of)::date
            )->>'days_per_year')::numeric);
END;
$function$
;