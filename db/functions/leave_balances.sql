-- db/functions/leave_balances.sql
-- PAYROLL-PAY-REVERSAL-1 · B2(Tim 2026-10-22,Step 0 Q12):一个人【每一种有额度的假别】的余额,一次调用读完 ——
--   /me 那张表画的就是它(年假在内,共 12 种;无薪假没有额度,不在里面)。每一项 = leave_balance_internal 的原样回答,
--   外加假别编号与 gender_restriction(员工档案没有性别,所以产假 / 陪产假对每个人都列出来,屏幕上标「视资格而定」)。
--   顺序 = leave_types.sort_order。只列 is_active 的假别。
-- 【门】与 leave_balance 同一道:本人或 module.hr.view(COALESCE 把「没有员工档案」读成「不是本人」—— U1-B 那条)。
-- NOTE: introduced by db/migrations/2026-10-22-payroll-pay-reversal-1.sql.

CREATE OR REPLACE FUNCTION public.leave_balances(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_out jsonb := '[]'::jsonb;
    r     record;
BEGIN
    IF NOT (has_permission('module.hr.view') OR COALESCE(p_employee_id = current_user_employee(), false)) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;
    FOR r IN
        SELECT lt.code, lt.gender_restriction
          FROM leave_types lt
         WHERE lt.is_active AND (lt.is_accrued OR lt.default_days_per_year IS NOT NULL)
         ORDER BY lt.sort_order, lt.code
    LOOP
        v_out := v_out || jsonb_build_array(
            leave_balance_internal(p_employee_id, r.code, p_as_of)
            || jsonb_build_object('gender_restriction', r.gender_restriction));
    END LOOP;
    RETURN v_out;
END;
$function$;
