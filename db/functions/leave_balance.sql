-- db/functions/leave_balance.sql
-- 对外的余额查询:只比 leave_balance_internal 多做一件事 —— 查权限。
-- 【算式只有一份】属主权限的视图要复用同一套数,不能被权限检查挡住。
--
-- NOTE: introduced/updated by db/migrations/2026-08-06-hr2c-monthly-accrual.sql.

CREATE OR REPLACE FUNCTION public.leave_balance(p_employee_id uuid, p_leave_type_code text DEFAULT 'annual'::text, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT (has_permission('module.hr.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;
    RETURN leave_balance_internal(p_employee_id, p_leave_type_code, p_as_of);
END;
$function$
;