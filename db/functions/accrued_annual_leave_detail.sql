-- db/functions/accrued_annual_leave_detail.sql
-- 按月累积的明细:逐月走,每个月各取各的费率(类别可能变、费率可能改)。
-- 入职当月算整月(沿用 grant_annual_leave 的折算口径);某个月要满了才计入;
-- 离职的人算到最后在职日为止。raw_days 是原始和,accrued_days 向下取到 0.5 天。
--
-- NOTE: introduced/updated by db/migrations/2026-08-06-hr2c-monthly-accrual.sql.

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
    v_raw      numeric := 0;
    v_months   jsonb := '[]'::jsonb;
BEGIN
    SELECT id, code, hire_date, work_category, employment_status, separation_date
    INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    -- 【离职冻结】最后在职日之后不再累积
    v_asof := p_as_of;
    IF v_emp.separation_date IS NOT NULL AND v_emp.separation_date < v_asof THEN
        v_asof := v_emp.separation_date;
    END IF;

    -- 当年度的第一个月:入职当月与年初,取靠后的那个
    v_first := GREATEST(date_trunc('month', v_emp.hire_date)::date, make_date(v_year, 1, 1));
    -- 最后一个【已满】的月:as_of 次日所在月的上一个月;再按年底截断
    v_last  := LEAST((date_trunc('month', v_asof + 1) - interval '1 month')::date,
                     make_date(v_year, 12, 1));

    IF v_asof < make_date(v_year, 1, 1) OR v_last < v_first THEN
        RETURN jsonb_build_object(
            'employee_id', p_employee_id, 'employee_code', v_emp.code,
            'leave_year', v_year, 'as_of', p_as_of, 'effective_as_of', v_asof,
            'months', '[]'::jsonb, 'raw_days', 0, 'accrued_days', 0,
            'frozen_at_separation', v_emp.separation_date IS NOT NULL AND v_emp.separation_date < p_as_of);
    END IF;

    v_m := v_first;
    WHILE v_m <= v_last LOOP
        v_cat  := employee_work_category_at(p_employee_id, v_m);
        v_rate := leave_accrual_rate(p_employee_id, v_cat, v_m);
        v_raw  := v_raw + (v_rate->>'days_per_month')::numeric;
        v_months := v_months || jsonb_build_object(
            'month', to_char(v_m, 'YYYY-MM'),
            'work_category', v_cat,
            'days_per_month', (v_rate->>'days_per_month')::numeric,
            'rate_source', v_rate->>'source',
            'rate_effective_from', v_rate->>'effective_from');
        v_m := (v_m + interval '1 month')::date;
    END LOOP;

    RETURN jsonb_build_object(
        'employee_id', p_employee_id, 'employee_code', v_emp.code,
        'leave_year', v_year, 'as_of', p_as_of, 'effective_as_of', v_asof,
        'first_month', to_char(v_first, 'YYYY-MM'), 'last_complete_month', to_char(v_last, 'YYYY-MM'),
        'months', v_months,
        'raw_days', v_raw,
        -- 【可请的余额向下取到 0.5 天】(B5);补偿用【同一个】数字,
        -- 于是员工一整年看到的那个数,就是最后拿到钱的那个数。
        'accrued_days', trim_scale(floor(v_raw * 2) / 2),
        'frozen_at_separation', v_emp.separation_date IS NOT NULL AND v_emp.separation_date < p_as_of);
END;
$function$
;