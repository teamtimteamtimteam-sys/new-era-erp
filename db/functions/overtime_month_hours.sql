-- db/functions/overtime_month_hours.sql
-- OVERTIME-1(Tim Q1 · Q3):屏幕上"这个月批过的加班小时"—— 考勤页的三列与工资期详情的那一列都读它。
--
-- ★【已完成的读冻下来的,还开着的读此刻的】★ 与 attendance_period_status 同一条:
--   那个月的考勤已完成 → 读 attendance_lines 上冻住的三个桶(fixed = true):我们报给服务商的就是它;
--   还开着(或还没开)→ 读 overtime_approved_hours 此刻的数(fixed = false)。
-- 【门】module.hr.view —— 读它的两页(考勤、工资)都在人力模块里。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.overtime_month_hours(p_month date)
 RETURNS TABLE(employee_id uuid, weekday_hours numeric, rest_day_hours numeric, public_holiday_hours numeric, total_hours numeric, fixed boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_m  date := date_trunc('month', p_month)::date;
BEGIN
    PERFORM require_permission('module.hr.view');
    IF EXISTS (SELECT 1 FROM attendance_periods ap WHERE ap.period_month = v_m AND ap.status = 'complete') THEN
        RETURN QUERY
        SELECT al.employee_id, al.ot_normal_hours, al.ot_rest_day_hours, al.ot_public_holiday_hours,
               al.ot_normal_hours + al.ot_rest_day_hours + al.ot_public_holiday_hours, true
          FROM attendance_lines al
          JOIN attendance_periods ap ON ap.id = al.period_id
         WHERE ap.period_month = v_m;
    ELSE
        RETURN QUERY
        SELECT o.employee_id, o.weekday_hours, o.rest_day_hours, o.public_holiday_hours,
               o.weekday_hours + o.rest_day_hours + o.public_holiday_hours, false
          FROM overtime_approved_hours(v_m) o;
    END IF;
END;
$function$;

COMMENT ON FUNCTION public.overtime_month_hours(date) IS
'OVERTIME-1:某个月每个员工批过的加班小时(三个桶 + 合计)。那个月考勤已完成 → 读 attendance_lines 冻住的数(fixed = true);否则读此刻已批准的(fixed = false)。门 module.hr.view。读者:/hr/attendance/[id] 与 /hr/payroll/[id]。';
