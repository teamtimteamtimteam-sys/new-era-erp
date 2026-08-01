-- db/functions/compute_leave_encashment.sql
-- 离职补偿的参考金额。日薪用 MOM 公式 12×月薪÷(52×每周工作天数)。【明确不过账】。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.

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
    v_gross numeric;
    v_dpw   numeric;
    v_daily numeric;
BEGIN
    IF NOT (has_permission('module.hr.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;

    SELECT id, code, legal_name INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    v_bal := leave_balance(p_employee_id, 'annual', p_as_of);
    v_days := (v_bal->>'available')::numeric;

    -- 最近一个【已过账】期间的应发工资当作月薪基数
    SELECT pl.gross_pay INTO v_gross
    FROM payroll_lines pl JOIN payroll_periods pp ON pp.id = pl.payroll_period_id
    WHERE pl.employee_id = p_employee_id AND pp.status = 'posted' AND pp.deleted_at IS NULL
    ORDER BY pp.period_month DESC LIMIT 1;

    SELECT working_days_per_week INTO v_dpw FROM hr_settings WHERE id;

    -- 【日薪口径】用 MOM 对月薪员工的定义:12 × 月薪 ÷ (52 × 每周工作天数)。
    -- 每周 5 天时相当于月薪 ÷ 21.667。选它而不是"21.75"是因为 21.75 只是这个公式
    -- 在 5 天工作制下的一个近似;把每周天数存成配置,公式对 5.5 天制也照样成立。
    v_daily := CASE WHEN v_gross IS NULL THEN NULL
                    ELSE round((12.0 * v_gross) / (52.0 * v_dpw), 2) END;

    RETURN jsonb_build_object(
        'employee_id', p_employee_id, 'employee_code', v_emp.code, 'as_of', p_as_of,
        'unused_days', v_days,
        'monthly_gross_basis', v_gross,
        'daily_rate', v_daily,
        'daily_rate_formula', format('12 x monthly gross / (52 x %s working days per week)', v_dpw),
        'indicative_amount', CASE WHEN v_daily IS NULL THEN NULL ELSE round(v_daily * v_days, 2) END,
        -- 【这一面旗子是有意放在返回值里的】:调用方看得见"这只是参考,没有入账"
        'journal_posted', false,
        'note', 'Indicative only. Payment is made by the outsourced payroll provider; no journal entry is created by this system.',
        'balance_detail', v_bal);
END;
$function$;
