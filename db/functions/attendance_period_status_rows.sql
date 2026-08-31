-- db/functions/attendance_period_status_rows.sql
-- CLEANUP-A(2026-08-31):attendance_period_status 的取数体,判据 module.hr.view。
-- 两个理由:① 它是 attendance_unpaid_days 的算术调用方,而 sum() 会跳过 NULL;
-- ② 视图是 security_invoker = off 且 GRANT 给 authenticated,此前这一层没有人问权限。

CREATE OR REPLACE FUNCTION public.attendance_period_status_rows()
 RETURNS TABLE(period_id uuid, code text, period_month date, status text, opened_at timestamp with time zone, completed_at timestamp with time zone, reopened_at timestamp with time zone, reopen_reason text, line_count integer, unrecorded_count integer, ot_normal_hours numeric, ot_rest_day_hours numeric, ot_public_holiday_hours numeric, unpaid_days numeric, payroll_posted boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【这一层此前【没有人】问权限,而视图注释把这件事记在"调用方"头上】
    PERFORM require_permission('module.hr.view');

    RETURN QUERY
    SELECT ap.id, ap.code, ap.period_month, ap.status,
        ap.opened_at, ap.completed_at, ap.reopened_at, ap.reopen_reason,
        count(al.id)::integer,
        count(al.id) FILTER (WHERE al.recorded_at IS NULL)::integer,
        round(COALESCE(sum(al.ot_normal_hours), 0::numeric), 2),
        round(COALESCE(sum(al.ot_rest_day_hours), 0::numeric), 2),
        round(COALESCE(sum(al.ot_public_holiday_hours), 0::numeric), 2),
        -- ★【已完成的读冻下来的,还开着的读此刻的】★ 两者是不同的问题,没动。
        -- 【sum() 跳过 NULL】—— 走到这里的人一定持 module.hr.view(上面那道闸),
        -- 所以 attendance_unpaid_days 不会返回 NULL,合计不会被悄悄抽走。
        round(COALESCE(sum(
            CASE
                WHEN ap.status = 'complete'::text THEN al.unpaid_days
                ELSE attendance_unpaid_days(al.employee_id, ap.period_month)
            END), 0::numeric), 2),
        (EXISTS ( SELECT 1
               FROM payroll_periods pp
              WHERE pp.deleted_at IS NULL AND pp.status = 'posted'::text
                AND date_trunc('month'::text, pp.period_month::timestamp with time zone)::date = ap.period_month))
       FROM attendance_periods ap
         LEFT JOIN attendance_lines al ON al.period_id = ap.id
      GROUP BY ap.id;
END;
$function$;

COMMENT ON FUNCTION public.attendance_period_status_rows() IS
    'CLEANUP-A:attendance_period_status 的取数体,判据 module.hr.view。两个理由,都要紧:① 它是 attendance_unpaid_days 的【算术调用方】,而 sum() 会跳过 NULL —— 没有这道闸,第三节的修复会让无权限读者的月合计把那些员工悄悄抽走(R2 点名的 PROC-COST-2 形状);② 视图是 security_invoker = off(以属主身份读、RLS 不生效)且 GRANT 给 authenticated,实测任何登录用户都读得到全公司考勤 —— 视图注释把把关记在"调用方"头上,而那是"调用方不是控制"。invoker = off 当初是对的(OPS-14 修法 (a)),错的是没有人在这一层问权限。';
