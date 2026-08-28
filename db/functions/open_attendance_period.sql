CREATE OR REPLACE FUNCTION public.open_attendance_period(p_period_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_m date; v_id uuid; v_code text; v_n int;
BEGIN
    PERFORM require_permission('module.hr.edit');
    IF p_period_month IS NULL THEN
        RAISE EXCEPTION 'ATTENDANCE_MONTH_REQUIRED';
    END IF;
    v_m := date_trunc('month', p_period_month)::date;
    -- 【还没过完的月份不开】一个月的考勤在它结束之前不可能是完整的,
    -- 而这张底稿存在的意义就是"完整"这句断言。
    IF v_m > date_trunc('month', CURRENT_DATE)::date THEN
        RAISE EXCEPTION 'ATTENDANCE_MONTH_FUTURE|%|%', v_m::text, CURRENT_DATE::text;
    END IF;
    IF EXISTS (SELECT 1 FROM attendance_periods WHERE period_month = v_m) THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_EXISTS|%',
            (SELECT code FROM attendance_periods WHERE period_month = v_m);
    END IF;

    v_code := 'ATT-' || to_char(v_m, 'YYYY-MM');
    INSERT INTO attendance_periods (code, period_month, opened_by)
    VALUES (v_code, v_m, auth.uid()) RETURNING id INTO v_id;

    -- 【每一个在这个月里在册过的人都铺一行】—— 见抬头 §4:
    -- 只给"有加班的人"建行,会让"没建行"同时意味着"没有加班"和"忘了",
    -- 而那正是这一刀要拆开的两件事。
    INSERT INTO attendance_lines (period_id, employee_id)
    SELECT v_id, e.id FROM employees e
     WHERE e.deleted_at IS NULL
       AND e.hire_date <= (v_m + interval '1 month - 1 day')::date
       AND (e.separation_date IS NULL OR e.separation_date >= v_m);
    GET DIAGNOSTICS v_n = ROW_COUNT;

    RETURN jsonb_build_object('period_id', v_id, 'code', v_code,
                              'period_month', v_m, 'lines', v_n);
END;
$function$

;
