-- db/views/attendance_period_status.sql
-- ATTEND-1：每个考勤月一行 —— 铺了几行、还有几行没人记、三类加班工时合计、
-- 无薪假天数，以及那个月的工资过账了没有。
--
-- ★【已完成的读冻下来的，还开着的读此刻的】★ 两者是不同的问题：前者是
-- 「我们当时报给服务商的是什么」，后者是「现在看是多少」。请假单事后被取消，
-- 已完成那一份必须仍然说得出当时报了什么 —— 否则底稿就不是底稿。
--
-- ★ WITH (security_invoker = off) 与 COMMENT ON VIEW 都是【手工补回来的】★
-- pg_get_viewdef() 只吐 SELECT —— 既不吐 reloptions，也不吐对象注释。
--
-- NOTE: introduced by db/migrations/2026-08-28-attend1-attendance-as-payroll-input.sql.

CREATE VIEW public.attendance_period_status WITH (security_invoker = off) AS
 SELECT ap.id AS period_id,
    ap.code,
    ap.period_month,
    ap.status,
    ap.opened_at,
    ap.completed_at,
    ap.reopened_at,
    ap.reopen_reason,
    count(al.id)::integer AS line_count,
    count(al.id) FILTER (WHERE al.recorded_at IS NULL)::integer AS unrecorded_count,
    round(COALESCE(sum(al.ot_normal_hours), 0::numeric), 2) AS ot_normal_hours,
    round(COALESCE(sum(al.ot_rest_day_hours), 0::numeric), 2) AS ot_rest_day_hours,
    round(COALESCE(sum(al.ot_public_holiday_hours), 0::numeric), 2) AS ot_public_holiday_hours,
    round(COALESCE(sum(
        CASE
            WHEN ap.status = 'complete'::text THEN al.unpaid_days
            ELSE attendance_unpaid_days(al.employee_id, ap.period_month)
        END), 0::numeric), 2) AS unpaid_days,
    (EXISTS ( SELECT 1
           FROM payroll_periods pp
          WHERE pp.deleted_at IS NULL AND pp.status = 'posted'::text AND date_trunc('month'::text, pp.period_month::timestamp with time zone)::date = ap.period_month)) AS payroll_posted
   FROM attendance_periods ap
     LEFT JOIN attendance_lines al ON al.period_id = ap.id
  GROUP BY ap.id;

COMMENT ON VIEW public.attendance_period_status IS
    'ATTEND-1:每个考勤月一行 —— 铺了几行、还有几行没人记、三类加班工时合计、无薪假天数,以及那个月的工资过账了没有。★【已完成的读冻下来的,还开着的读此刻的】★ 两者是不同的问题:前者是"我们当时报给服务商的是什么",后者是"现在看是多少"。属主权限(security_invoker = off):它横跨 hr 与 finance,invoker 会让读者无权的那一侧静默丢掉行,而行消失在这里意味着"这个月没有工资"—— 一句会被信的假话(OPS-14 修法 (a));调用方按 module.hr.view 把关。';
