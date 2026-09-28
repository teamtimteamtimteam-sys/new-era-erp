-- db/functions/overtime_approved_hours.sql
-- OVERTIME-1(Tim Q1 · Q3):某个月里每个员工【已批准、没作废】的加班小时,按三个桶分。
--
-- 【"只算一次"住在这里】一行只属于一个批次,一个批次只属于一个月;只数 status = 'approved'
--   的批里 voided_at IS NULL 的行。冲销与丢弃的批,它们的行已经作废,所以不进来。
-- 【桶是行上存的 day_kind】批准那一刻定下来的那个,不是今天再算一遍 —— 假期表事后改了,
--   已经批过的小时不会悄悄换桶。
-- 【两个读者,一份定义】complete_attendance_period(冻进 attendance_lines)与
--   overtime_month_hours(屏幕在考勤还开着时读此刻的数)。
-- 【不是 SECURITY DEFINER,EXECUTE 从 authenticated 收回】两个调用者都是 DEFINER,在属主身份下调它。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.overtime_approved_hours(p_month date)
 RETURNS TABLE(employee_id uuid, weekday_hours numeric, rest_day_hours numeric, public_holiday_hours numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT l.employee_id,
           COALESCE(sum(l.hours) FILTER (WHERE l.day_kind = 'weekday'), 0),
           COALESCE(sum(l.hours) FILTER (WHERE l.day_kind = 'rest_day'), 0),
           COALESCE(sum(l.hours) FILTER (WHERE l.day_kind = 'public_holiday'), 0)
      FROM overtime_lines l
      JOIN overtime_batches b ON b.id = l.batch_id
     WHERE b.period_month = date_trunc('month', p_month)::date
       AND b.status = 'approved'
       AND l.voided_at IS NULL
     GROUP BY l.employee_id;
$function$;

COMMENT ON FUNCTION public.overtime_approved_hours(date) IS
'OVERTIME-1:某个月每个员工已批准、没作废的加班小时,按行上存的 day_kind 分三个桶。只数 approved 批里 voided_at IS NULL 的行 —— 每一行只属于一个批、一个月,所以只算一次。读者:complete_attendance_period(冻进 attendance_lines)与 overtime_month_hours。EXECUTE 已从 authenticated 收回。';
