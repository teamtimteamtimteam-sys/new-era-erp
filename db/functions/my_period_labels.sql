-- db/functions/my_period_labels.sql
-- AUDIT-TRAIL-1d-3(Tim 2026-10-04 的折入:修 Q19,docs/known-issues.md 的 AT1D1-ME-READS-HR-ONLY-PERIOD-TABLES)
--
-- 【它答什么】调用者【自己的】考勤行与工资单落在哪几个期间 —— 每一个期间只给【编号与月份】,别的一列都不给。
--   /me 的考勤表与工资单表要这两样去配"哪一个月 · 哪一张",而两张期间表的读策略都只有 module.hr.view
--   (attendance_periods.sql、payroll_periods.sql),于是一个不持它的员工(线上:warehouse 那一个账号)读到 0 行,
--   屏幕上的编号与月份印成 "—"(AT-1d-2 以 fusheng@ 的身份量过:1 行自己的考勤,0 个它的期间)。
-- 【为什么是一支属主函数,而不是一条"本人的期间"自读策略】一条策略放进来的是【整行】:工资期上有五个合计、
--   一期只有一两个人时合计就是一个人的工资(Q18 登记的那一件);考勤期间上有完成人、重开理由。Tim 的话是
--   "只给编号与月份,别的都不给" —— 列表能做到,策略做不到。
-- 【主语就是调用者】没有参数;current_user_employee() 解析的是调用者自己 —— 对 anon 是 NULL,于是 0 行。
--   只回那几个【有一行是你的】期间:没有你的行的期间、别人的期间,一个都不回。
-- 【为什么是 DEFINER】只用来越过两张期间表的读策略(它们只给 hr.view);行与列都由上面那两条收住。
CREATE OR REPLACE FUNCTION public.my_period_labels()
 RETURNS TABLE(kind text, period_id uuid, code text, period_month date)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT 'attendance'::text, ap.id, ap.code, ap.period_month
      FROM attendance_periods ap
     WHERE EXISTS (SELECT 1 FROM attendance_lines al
                    WHERE al.period_id = ap.id AND al.employee_id = current_user_employee())
    UNION ALL
    SELECT 'payroll'::text, pp.id, pp.code, pp.period_month
      FROM payroll_periods pp
     WHERE EXISTS (SELECT 1 FROM payroll_lines pl
                    WHERE pl.payroll_period_id = pp.id AND pl.employee_id = current_user_employee())
$function$;

COMMENT ON FUNCTION public.my_period_labels() IS
    'AUDIT-TRAIL-1d-3(Q19):调用者自己的考勤行与工资单所在的期间 —— 只给编号与月份(kind · period_id · code · period_month),别的一列都不给。两张期间表的读策略只有 module.hr.view,而 /me 要这两样去配月份;一条自读策略会放进整行(工资期的合计在一期只有一两个人时就是一个人的工资),所以是一支属主函数,行由 current_user_employee() 收住(对 anon 是 NULL → 0 行),列由返回表收住。';
