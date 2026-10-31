-- db/functions/my_concerns.sql
-- ESG-2(Tim 2026-10-31 Q11 · Q13):交的人读到【自己交的那几件】的状态(/me 的「我提出的关切」)—— 标题、交的那一天、有没有标「涉及 CCO」、
--   现在的状态(最后一个追加的状态,没有 = received)与它的时刻。读者写的说明【不】给(Q13:"Filers see the status of their own reports")。
--   不经两张举报表的读策略(交的人通常不是读者);只回 filed_by_employee_id = 调用者自己的那几行。没有员工档案 → 零行。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.my_concerns()
 RETURNS TABLE(id uuid, subject text, received_on date, recorded_at timestamptz, concerns_cco boolean, status text, status_at timestamptz)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT r.id, r.subject, r.received_on, r.recorded_at, r.concerns_cco,
           COALESCE(u.status, 'received'), COALESCE(u.recorded_at, r.recorded_at)
      FROM whistleblowing_reports r
      LEFT JOIN LATERAL (SELECT x.status, x.recorded_at FROM whistleblowing_updates x WHERE x.report_id = r.id ORDER BY x.id DESC LIMIT 1) u ON true
     WHERE r.filed_by_employee_id = current_user_employee()
     ORDER BY r.recorded_at DESC, r.id;
$function$;
