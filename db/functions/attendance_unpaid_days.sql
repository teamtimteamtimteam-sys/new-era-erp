CREATE OR REPLACE FUNCTION public.attendance_unpaid_days(p_employee_id uuid, p_month date)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
       AND lr.end_date   >= date_trunc('month', p_month)::date;
$function$

;
