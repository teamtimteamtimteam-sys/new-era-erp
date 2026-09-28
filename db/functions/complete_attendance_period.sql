-- db/functions/complete_attendance_period.sql
-- ATTEND-1:把一个月的考勤底稿标记为完成 —— 工资过账那道拒绝(PAYROLL_ATTENDANCE_NOT_COMPLETE)整个压在这句断言上。
--
-- ★ OVERTIME-1(Tim Q1 · Q3 · Q8,2026-09-28):
--   ① 那个月还有【开着的】加班批(draft / submitted / rejected)→ 按名拒 OVERTIME_BATCH_OPEN_FOR_MONTH。
--      否则一批还没批完的小时会被一份"完整"的底稿漏掉。
--   ② 三个加班桶在这一刻从【已批准、没作废】的加班行冻进来(overtime_approved_hours)——
--      这是批过的小时进工资的【唯一一次】:之后那个月的加班批建、提交、批、冲销一律拒。
--      重开再完成,会按那时批过的数重新冻一次(不是叠加)。

CREATE OR REPLACE FUNCTION public.complete_attendance_period(p_period_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_p attendance_periods%ROWTYPE; v_added int; v_missing int; v_end date; v_ot text;
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

    -- ★ OVERTIME-1(Tim Q8):那个月还有开着的加班批 → 不许完成
    SELECT b.label || '|' || b.status INTO v_ot FROM overtime_batches b
     WHERE b.period_month = v_p.period_month AND b.status IN ('draft', 'submitted', 'rejected')
     ORDER BY b.seq LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_OPEN_FOR_MONTH|%|%', v_p.code, v_ot;
    END IF;

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

    -- ★ OVERTIME-1(Tim Q1 · Q3):批过的加班小时冻进三个桶 —— 这是它们进工资的唯一一次。
    --   每一行都写(没有批过加班的人写 0),所以重开再完成是【重算】,不是叠加。
    UPDATE attendance_lines al
       SET ot_normal_hours         = COALESCE(o.weekday_hours, 0),
           ot_rest_day_hours       = COALESCE(o.rest_day_hours, 0),
           ot_public_holiday_hours = COALESCE(o.public_holiday_hours, 0)
      FROM attendance_lines al2
      LEFT JOIN overtime_approved_hours(v_p.period_month) o ON o.employee_id = al2.employee_id
     WHERE al2.id = al.id AND al.period_id = v_p.id;
    -- 【冻进来的总和必须等于批过的总和】一个批过加班、却不在这份底稿名单上的人(例如事后被软删)
    --   会让他的小时悄悄掉出工资 —— 那种时候按名拒,不许"完成"。
    IF (SELECT COALESCE(sum(ot_normal_hours + ot_rest_day_hours + ot_public_holiday_hours), 0)
          FROM attendance_lines WHERE period_id = v_p.id)
       <> (SELECT COALESCE(sum(weekday_hours + rest_day_hours + public_holiday_hours), 0)
             FROM overtime_approved_hours(v_p.period_month)) THEN
        RAISE EXCEPTION 'OVERTIME_HOURS_OFF_ROSTER|%', v_p.code;
    END IF;

    UPDATE attendance_periods
       SET status = 'complete', completed_at = now(), completed_by = auth.uid()
     WHERE id = p_period_id;

    RETURN jsonb_build_object('period_id', p_period_id, 'code', v_p.code,
                              'status', 'complete', 'lines_added', v_added);
END;
$function$

;
