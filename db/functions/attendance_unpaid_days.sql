-- db/functions/attendance_unpaid_days.sql
-- CLEANUP-A(2026-08-31):判据 module.hr.view OR 本人,无权限返回 NULL 而不是 0。
-- ★旧行为的后果是【多发工资】★ —— 这个数是工资的扣减项。
-- "OR 本人"是量出来的:leave_requests 有 select own rows 策略,零权限员工今天
-- 正确读到自己的 2.00,只写 module.hr.view 会新打断这条合法的路。

CREATE OR REPLACE FUNCTION public.attendance_unpaid_days(p_employee_id uuid, p_month date)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE WHEN has_permission('module.hr.view'::text)
                  OR p_employee_id = current_user_employee() THEN (
        SELECT COALESCE(round(sum(
            calculate_leave_days(
                GREATEST(lr.start_date, date_trunc('month', p_month)::date),
                LEAST(lr.end_date, (date_trunc('month', p_month) + interval '1 month - 1 day')::date),
                -- 只有裁剪之后仍然是原端点时,半天标记才成立
                lr.start_half_day AND lr.start_date >= date_trunc('month', p_month)::date,
                lr.end_half_day   AND lr.end_date   <= (date_trunc('month', p_month) + interval '1 month - 1 day')::date
            )), 2), 0)
          FROM leave_requests lr
         WHERE lr.employee_id = p_employee_id
           AND lr.leave_type_code = 'unpaid'
           AND lr.status = 'approved'
           AND lr.deleted_at IS NULL
           AND lr.start_date <= (date_trunc('month', p_month) + interval '1 month - 1 day')::date
           AND lr.end_date   >= date_trunc('month', p_month)::date
    ) END;
$function$;

COMMENT ON FUNCTION public.attendance_unpaid_days(p_employee_id uuid, p_month date) IS
    'CLEANUP-A:某员工某月的无薪假天数。【自带判据 module.hr.view OR 本人,无权限返回 NULL 不是 0】★旧行为的后果是【多发工资】★ —— 这个数是工资的扣减项,读成 0 就等于那个月全额发出去,而且不会有任何东西报错。实测 hr 读者 2.00 / operations 读者 0。判据里的"OR 本人"不是客气:leave_requests 有一条 select own rows 策略,实测一个零权限员工今天正确读到自己的 2.00,只写 module.hr.view 会新打断这条合法的路(R2 的反方向失败)。';
