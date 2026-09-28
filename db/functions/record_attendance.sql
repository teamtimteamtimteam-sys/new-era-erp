-- db/functions/record_attendance.sql
-- ATTEND-1:记一行考勤底稿(module.hr.edit)—— "这一行有人看过了" + 一句备注。
--
-- ★ OVERTIME-1(Tim Q3,2026-09-28):加班小时【不再从这里打字进来】。
--   它们只有一个来源:仓库批过的加班批(overtime_batches / overtime_lines),在那个月考勤完成时
--   由 complete_attendance_period 冻进三个桶。这里再收小时就是同一个事实的第二个入口。
--   ☞ 签名【一个字没改】—— 破窗里旧界面照旧调这支函数,传三个 0 就照旧成功;
--     传任何一个非零的小时 → 按名拒 ATTENDANCE_OT_THROUGH_OVERTIME|<员工编号>。
--   ☞ 三个桶这里【不写】:它们由完成那一步写,还开着的月份屏幕读此刻批过的数(overtime_month_hours)。

CREATE OR REPLACE FUNCTION public.record_attendance(p_line_id uuid, p_normal numeric DEFAULT 0, p_rest_day numeric DEFAULT 0, p_holiday numeric DEFAULT 0, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_l attendance_lines%ROWTYPE; v_p attendance_periods%ROWTYPE;
BEGIN
    PERFORM require_permission('module.hr.edit');
    SELECT * INTO v_l FROM attendance_lines WHERE id = p_line_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ATTENDANCE_LINE_NOT_FOUND|%', COALESCE(p_line_id::text, '?');
    END IF;
    SELECT * INTO v_p FROM attendance_periods WHERE id = v_l.period_id;
    IF v_p.status <> 'open' THEN
        -- 完成之后不许再改:那份底稿【就是】我们报出去的东西
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_NOT_OPEN|%|%', v_p.code, v_p.status;
    END IF;
    -- ★ OVERTIME-1(Tim Q3):加班小时只经加班批进来,这里一个都不收。
    IF COALESCE(p_normal, 0) <> 0 OR COALESCE(p_rest_day, 0) <> 0 OR COALESCE(p_holiday, 0) <> 0 THEN
        RAISE EXCEPTION 'ATTENDANCE_OT_THROUGH_OVERTIME|%',
            (SELECT e.code FROM employees e WHERE e.id = v_l.employee_id);
    END IF;

    UPDATE attendance_lines
       SET note = NULLIF(btrim(COALESCE(p_note, '')), ''),
           recorded_at = now(), recorded_by = auth.uid()
     WHERE id = p_line_id;

    RETURN jsonb_build_object('line_id', p_line_id, 'recorded', true);
END;
$function$

;
