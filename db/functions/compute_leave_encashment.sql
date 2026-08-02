-- db/functions/compute_leave_encashment.sql
-- 离职补偿的参考金额。日薪用 MOM 公式 12×月薪÷(52×每周工作天数)。【明确不过账】。
-- 基数取 employees.monthly_salary(月固定工资总额,HR-3b);月薪未录则 SALARY_NOT_SET。
-- 【累积停在最后在职日】不跑到今天 —— 离职之后的月份他并不在职,那些天不是他挣的。
-- 天数用与员工一整年看到的【同一个】数(已向下取到 0.5 天)。
--
-- NOTE: introduced/updated by db/migrations/2026-08-06-hr2c-monthly-accrual.sql.

CREATE OR REPLACE FUNCTION public.compute_leave_encashment(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp   record;
    v_bal   jsonb;
    v_days  numeric;
    v_basis numeric;
    v_dpw   numeric;
    v_daily numeric;
    v_asof  date;
BEGIN
    IF NOT (has_permission('module.hr.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;

    SELECT id, code, legal_name, monthly_salary, separation_date INTO v_emp
    FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    IF v_emp.monthly_salary IS NULL THEN
        RAISE EXCEPTION 'SALARY_NOT_SET|%', v_emp.code;
    END IF;

    -- 【离职的人算到最后在职日为止】。跑到今天会把离职之后的月份也算进去 ——
    -- 那些月他并没有在职,那些天不是他挣的。
    v_asof := p_as_of;
    IF v_emp.separation_date IS NOT NULL AND v_emp.separation_date < v_asof THEN
        v_asof := v_emp.separation_date;
    END IF;

    v_bal := leave_balance(p_employee_id, 'annual', v_asof);
    -- 【与员工一整年看到的是同一个数】leave_balance 已经向下取到 0.5 天(B5)
    v_days := (v_bal->>'available')::numeric;
    v_basis := v_emp.monthly_salary;

    SELECT working_days_per_week INTO v_dpw FROM hr_settings WHERE id;

    v_daily := round((12.0 * v_basis) / (52.0 * v_dpw), 2);

    RETURN jsonb_build_object(
        'employee_id', p_employee_id, 'employee_code', v_emp.code,
        'as_of', p_as_of, 'effective_as_of', v_asof,
        'frozen_at_separation', v_emp.separation_date IS NOT NULL AND v_emp.separation_date < p_as_of,
        'unused_days', v_days,
        'monthly_fixed_gross_basis', v_basis,
        'basis_source', 'employees.monthly_salary (contracted fixed gross; excludes overtime, bonus, AWS, commission)',
        'daily_rate', v_daily,
        'daily_rate_formula', format('12 x monthly fixed gross / (52 x %s working days per week)', v_dpw),
        'rounding', 'accrual floored to 0.5 day; daily rate rounded to 2 dp, then multiplied by days and rounded to 2 dp',
        'indicative_amount', round(v_daily * v_days, 2),
        'journal_posted', false,
        'note', 'Indicative only. Payment is made by the outsourced payroll provider; no journal entry is created by this system.',
        'balance_detail', v_bal);
END;
$function$
;