CREATE OR REPLACE FUNCTION public.complete_attendance_period(p_period_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_p attendance_periods%ROWTYPE; v_added int; v_missing int; v_end date;
BEGIN
    PERFORM require_permission('module.hr.edit');
    SELECT * INTO v_p FROM attendance_periods WHERE id = p_period_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_NOT_FOUND|%', COALESCE(p_period_id::text, '?');
    END IF;
    IF v_p.status <> 'open' THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_NOT_OPEN|%|%', v_p.code, v_p.status;
    END IF;
    v_end := (v_p.period_month + interval '1 month - 1 day')::date;

    -- ① 【先补名单,再谈完整 —— 这是安全网,不是操作路径】月中入职的人在
    --    开期间时还不在册;不补就会出现"一份声称完整的底稿里少了一个人",
    --    而那句断言恰恰在这种时候才要紧。
    --    【但它到不了操作员手上】补完若仍有没记的行,下面那句 RAISE 会把
    --    同一条语句里刚补出来的行一起回滚掉 —— 所以能被【看见和记录】的
    --    那条路是 sync_attendance_period(页面每次打开调一次)。两者同一句
    --    SQL,故意重复:少了这里就漏得掉人,少了那里就补不进去。
    INSERT INTO attendance_lines (period_id, employee_id)
    SELECT v_p.id, e.id FROM employees e
     WHERE e.deleted_at IS NULL
       AND e.hire_date <= v_end
       AND (e.separation_date IS NULL OR e.separation_date >= v_p.period_month)
       AND NOT EXISTS (SELECT 1 FROM attendance_lines al
                        WHERE al.period_id = v_p.id AND al.employee_id = e.id);
    GET DIAGNOSTICS v_added = ROW_COUNT;

    -- ② 【还有没记的就拒,并说出还差几行】一个容得下空白的"完成"是一个勾选框,
    --    不是一句断言 —— 而工资过账那道拒绝【整个】压在这句断言上。
    SELECT count(*) INTO v_missing FROM attendance_lines
     WHERE period_id = v_p.id AND recorded_at IS NULL;
    IF v_missing > 0 THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_INCOMPLETE|%|%', v_p.code, v_missing::text;
    END IF;

    -- ③ 【冻推导值】此后请假单再被取消,这份底稿仍然说得出当时报了什么
    UPDATE attendance_lines al
       SET unpaid_days = attendance_unpaid_days(al.employee_id, v_p.period_month),
           active_from = GREATEST(e.hire_date, v_p.period_month),
           active_to   = LEAST(COALESCE(e.separation_date, v_end), v_end),
           frozen_at   = now()
      FROM employees e
     WHERE e.id = al.employee_id AND al.period_id = v_p.id;

    UPDATE attendance_periods
       SET status = 'complete', completed_at = now(), completed_by = auth.uid()
     WHERE id = p_period_id;

    RETURN jsonb_build_object('period_id', p_period_id, 'code', v_p.code,
                              'status', 'complete', 'lines_added', v_added);
END;
$function$

;
