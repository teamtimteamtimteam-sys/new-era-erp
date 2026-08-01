-- db/functions/compute_leave_encashment.sql
-- 离职补偿的参考金额。日薪用 MOM 公式 12×月薪÷(52×每周工作天数)。【明确不过账】。
--
-- 【HR-3b 换了取数来源,这是本函数最要紧的一处】原来取"最近一个已过账期间的
-- payroll_lines.gross_pay"—— 那是服务商算出的实发口径,【含加班、奖金、一次性补发】,
-- 于是离职月恰好加过班的人补偿就凭空变多。现在取 employees.monthly_salary =
-- 【月固定工资总额】(合同底薪 + 固定经常性津贴),也就是 MOM 的 gross rate of pay。
--
-- 【monthly_salary 为空时报错,不算 0、不退回 gross_pay】。一个静悄悄的 0 会变成一个
-- 离职的人少拿的钱,而且没有人会看见它发生;一个"兜底回退"会把刚拔掉的加班费接回来。
-- 空值由 hr_alerts 的 salary_not_set 一支提前顶出来,不留到离职当天。
--
-- 【取整】先把日薪取到分,再乘天数、再取到分 —— 与财务层"每个分量各自取到分"一致。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql;
--       basis changed by db/migrations/2026-08-04-hr3b-salary-basis-and-review-visibility.sql.

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
BEGIN
    IF NOT (has_permission('module.hr.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;

    SELECT id, code, legal_name, monthly_salary INTO v_emp
    FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- 【B3 NULL 守卫】没录固定工资就【报错】,不算 0,也不退回 gross_pay。
    -- 这里是整个切次最要紧的三行:一个静悄悄的 0 会变成一个离职的人少拿的钱,
    -- 而且没有任何人会看见它发生。退回 gross_pay 更糟 —— 那正是本切拔掉的东西,
    -- 一个"兜底"会把它悄悄接回来。
    -- ══════════════════════════════════════════════════════════════════════
    IF v_emp.monthly_salary IS NULL THEN
        RAISE EXCEPTION 'SALARY_NOT_SET|%', v_emp.code;
    END IF;

    v_bal := leave_balance(p_employee_id, 'annual', p_as_of);
    v_days := (v_bal->>'available')::numeric;
    v_basis := v_emp.monthly_salary;

    SELECT working_days_per_week INTO v_dpw FROM hr_settings WHERE id;

    -- 【日薪口径】MOM 对月薪员工的定义:12 × 月薪 ÷ (52 × 每周工作天数)。
    -- 月薪取【固定工资总额】(见 employees.monthly_salary 的注释),不取实发口径。
    -- 【取整规则】先把日薪取到分,再乘天数、再取到分 —— 与财务层"每个分量各自取到分"
    -- 的做法一致(见 allocate_processing_costs 的分摊与余额补差)。日薪是要写在
    -- 结算单上、要被人核对的一个数,所以它先成为一个真实的分值,而不是中间态。
    v_daily := round((12.0 * v_basis) / (52.0 * v_dpw), 2);

    RETURN jsonb_build_object(
        'employee_id', p_employee_id, 'employee_code', v_emp.code, 'as_of', p_as_of,
        'unused_days', v_days,
        -- 【键名换了】原来叫 monthly_gross_basis,那个名字现在会误导 ——
        -- "gross" 在本系统里已经专指服务商的实发口径。
        'monthly_fixed_gross_basis', v_basis,
        'basis_source', 'employees.monthly_salary (contracted fixed gross; excludes overtime, bonus, AWS, commission)',
        'daily_rate', v_daily,
        'daily_rate_formula', format('12 x monthly fixed gross / (52 x %s working days per week)', v_dpw),
        'rounding', 'daily rate rounded to 2 dp, then multiplied by days and rounded to 2 dp',
        'indicative_amount', round(v_daily * v_days, 2),
        -- 【这一面旗子是有意放在返回值里的】:调用方看得见"这只是参考,没有入账"
        'journal_posted', false,
        'note', 'Indicative only. Payment is made by the outsourced payroll provider; no journal entry is created by this system.',
        'balance_detail', v_bal);
END;
$function$
;