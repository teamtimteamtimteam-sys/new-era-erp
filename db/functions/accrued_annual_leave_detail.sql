-- db/functions/accrued_annual_leave_detail.sql
-- 按月累积的明细:逐月走,每个月各取各的【年额】(类别可能变、费率可能改)。
-- 累积 = Σ区间(年额 × 区间月数 / 12);实现上先把每月的年额加起来,【最后只除一次 12】——
-- 线性求和结果相同,但中间不产生 25/12 那种除不尽的小数(那正是 24.9996 的来处)。
-- 入职当月算整月;某个月要满了才计入;离职的人算到最后在职日为止。
-- 向下取到 0.5 天【只作用于总数】,不逐月作用。
--
-- NOTE: introduced by db/migrations/2026-08-06-hr2c-monthly-accrual.sql;
--       annual-rate form by db/migrations/2026-08-07-hr2c-fu1-annual-rate-and-immutable-rates.sql.

CREATE OR REPLACE FUNCTION public.accrued_annual_leave_detail(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp      record;
    v_year     integer := EXTRACT(YEAR FROM p_as_of)::integer;
    v_asof     date;
    v_first    date;
    v_last     date;
    v_m        date;
    v_cat      text;
    v_rate     jsonb;
    v_dpy_sum  numeric := 0;
    v_raw      numeric := 0;
    v_months   jsonb := '[]'::jsonb;
    v_sys      date;        -- HR-7:完整记录起始日(finance_settings.system_start_date)
    v_sys_used boolean;
BEGIN
    -- 【本人或 HR】与 leave_balance 同一道口径。
    IF NOT (has_permission('module.hr.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;
    SELECT id, code, hire_date, work_category, employment_status, separation_date
    INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    -- 【离职冻结】最后在职日之后不再累积
    v_asof := p_as_of;
    IF v_emp.separation_date IS NOT NULL AND v_emp.separation_date < v_asof THEN
        v_asof := v_emp.separation_date;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- HR-7:【三个日期一次 GREATEST,不做叠加扣减】
    -- 累积的起点是三件事的【交集】:这个人什么时候入职、这个假期年从哪天开始、
    -- 本库从哪天起持有完整记录。取三者之中最晚的那一个 —— 一次比较,得一个日期。
    --
    -- 【为什么必须是 GREATEST 而不是逐条扣减】HR-6 的医疗额度就是这么栽的:
    -- 先按入职月折一次、再按起始月折一次,两次都"对",合起来把 3 个月折成了
    -- 1 个月、300 折成 100。这里的实现是【日期取最大】而不是【月数打折】,
    -- 结构上就不会叠加 —— 但那正是要写下来的理由:换成"先算月数再逐项扣"的
    -- 写法,数字会安静地变小,而每一步看起来都成立。
    --
    -- 【起始日所在的那个月算进去】与 medical_claim_balance 同口径
    -- (它取 EXTRACT(MONTH FROM v_start),即含起始月)。
    --
    -- 【起始日未设置时不拒绝】HR-5 的结转与 HR-6 的医疗额度都抛
    -- SYSTEM_START_NOT_SET —— 那两个是【动作】(结转、批报销),拒了就停在那里。
    -- 本函数是【余额】:它坐在 my_profile / employees_masked 上,是员工点开
    -- /me 就会看到的那个数。因为财务的一个设置没填而告诉全体员工"你的假期余额
    -- 不可用",是把一个后台配置问题变成所有人的故障。
    -- 所以这里【退回两日期口径】并在返回值里说明,由 hr_alerts 的
    -- system_start_not_set 去催那个设置(同 holiday_calendar_missing 的处置:
    -- 缺配置是告警,不是让功能消失)。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT system_start_date INTO v_sys FROM finance_settings LIMIT 1;
    v_sys_used := v_sys IS NOT NULL;

    v_first := GREATEST(date_trunc('month', v_emp.hire_date)::date, make_date(v_year, 1, 1));
    IF v_sys_used THEN
        v_first := GREATEST(v_first, date_trunc('month', v_sys)::date);
    END IF;
    v_last  := LEAST((date_trunc('month', v_asof + 1) - interval '1 month')::date,
                     make_date(v_year, 12, 1));

    IF v_asof < make_date(v_year, 1, 1) OR v_last < v_first THEN
        RETURN jsonb_build_object(
            'employee_id', p_employee_id, 'employee_code', v_emp.code,
            'leave_year', v_year, 'as_of', p_as_of, 'effective_as_of', v_asof,
            'months', '[]'::jsonb, 'months_accrued', 0, 'raw_days', 0, 'accrued_days', 0,
            'system_start_date', v_sys, 'system_start_applied', v_sys_used,
            'frozen_at_separation', v_emp.separation_date IS NOT NULL AND v_emp.separation_date < p_as_of);
    END IF;

    v_m := v_first;
    WHILE v_m <= v_last LOOP
        v_cat  := employee_work_category_at(p_employee_id, v_m);
        v_rate := leave_accrual_rate(p_employee_id, v_cat, v_m);
        -- 【只累加年额,不在这里除】Σ区间(年额 × 月数/12) 与 (Σ每月年额)/12 是同一个数,
        -- 但后者中间不产生任何除不尽的小数 —— 25/12 那种数字永远不会出现在中间结果里。
        v_dpy_sum := v_dpy_sum + (v_rate->>'days_per_year')::numeric;
        v_months := v_months || jsonb_build_object(
            'month', to_char(v_m, 'YYYY-MM'),
            'work_category', v_cat,
            'days_per_year', (v_rate->>'days_per_year')::numeric,
            'rate_source', v_rate->>'source',
            'rate_effective_from', v_rate->>'effective_from');
        v_m := (v_m + interval '1 month')::date;
    END LOOP;

    v_raw := v_dpy_sum / 12;

    RETURN jsonb_build_object(
        'employee_id', p_employee_id, 'employee_code', v_emp.code,
        'leave_year', v_year, 'as_of', p_as_of, 'effective_as_of', v_asof,
        'first_month', to_char(v_first, 'YYYY-MM'), 'last_complete_month', to_char(v_last, 'YYYY-MM'),
        -- 起点由哪三个日期定的,以及第三个到底有没有生效 —— 看得见才查得动
        'system_start_date', v_sys, 'system_start_applied', v_sys_used,
        'months', v_months,
        'months_accrued', jsonb_array_length(v_months),
        'sum_of_annual_rates', v_dpy_sum,
        'raw_days', trim_scale(v_raw),
        -- 【向下取到 0.5 天只作用于总数】,不再逐月作用 —— 那正是 24.9996 的来处。
        'accrued_days', trim_scale(floor(v_raw * 2) / 2),
        'frozen_at_separation', v_emp.separation_date IS NOT NULL AND v_emp.separation_date < p_as_of);
END;
$function$;