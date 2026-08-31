-- db/views/attendance_period_status.sql
-- ATTEND-1:每个考勤月一行 —— 铺了几行、还有几行没人记、三类加班工时合计、
-- 无薪假天数,以及那个月的工资过账了没有。
--
-- ★【已完成的读冻下来的,还开着的读此刻的】★ 两者是不同的问题:前者是
-- 「我们当时报给服务商的是什么」,后者是「现在看是多少」。
--
-- ★ CLEANUP-A(2026-08-31):把关搬进 attendance_period_status_rows() ★
--   两个理由,都要紧:
--   ① 它是 attendance_unpaid_days 的【算术调用方】,而 sum() 会【跳过 NULL】。
--      那支函数现在对无权限读者返回 NULL,没有这道闸,月合计会把那些员工
--      **悄悄抽走**,只是"小一点",不报错 —— R2 点名的 PROC-COST-2 形状。
--   ② 这一层此前【没有人问权限】:视图是 security_invoker = off(以属主身份读、
--      RLS 不生效)且 GRANT 给 authenticated,实测任何登录用户都读得到全公司考勤。
--      视图注释把把关记在"调用方"头上 —— 那是"调用方不是控制"(R3 同一条)。
--   invoker = off 当初是对的(OPS-14 修法 (a):invoker 会让读者无权的那一侧静默丢行,
--   而行消失在这里意味着"这个月没有工资"),所以壳仍然是 off,错的只是没人把关。
--
-- WITH (security_invoker = off) 与 COMMENT ON VIEW 都是【手工补回来的】。
--
-- NOTE: introduced by db/migrations/2026-08-28-attend1-attendance-as-payroll-input.sql.
-- NOTE: gated via attendance_period_status_rows() by
--       db/migrations/2026-08-31-cleanupa-a-restricted-reader-gets-a-name-not-a-smaller-number.sql.

CREATE VIEW public.attendance_period_status WITH (security_invoker=off) AS
 SELECT period_id,
    code,
    period_month,
    status,
    opened_at,
    completed_at,
    reopened_at,
    reopen_reason,
    line_count,
    unrecorded_count,
    ot_normal_hours,
    ot_rest_day_hours,
    ot_public_holiday_hours,
    unpaid_days,
    payroll_posted
   FROM attendance_period_status_rows() r(period_id, code, period_month, status, opened_at, completed_at, reopened_at, reopen_reason, line_count, unrecorded_count, ot_normal_hours, ot_rest_day_hours, ot_public_holiday_hours, unpaid_days, payroll_posted);

COMMENT ON VIEW public.attendance_period_status IS
    'ATTEND-1:每个考勤月一行 —— 铺了几行、还有几行没人记、三类加班工时合计、无薪假天数,以及那个月的工资过账了没有。★【已完成的读冻下来的,还开着的读此刻的】★ 两者是不同的问题。CLEANUP-A 起它是 attendance_period_status_rows() 的一层壳,把关(module.hr.view)搬进取数体 —— 此前这一层【没有人问权限】,而视图是 security_invoker = off、GRANT 给 authenticated,于是任何登录用户都读得到全公司考勤;注释把把关记在"调用方"头上,那是"调用方不是控制"。';
