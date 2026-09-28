-- db/functions/my_overtime_lines.sql
-- OVERTIME-1(Tim Q14):/me 上现场员工看见自己【已批准、没作废】的加班 —— 日期、小时、桶、备注、
-- 哪一批、谁什么时候批的。
-- 【为什么是属主权限】员工读不到批次(没有任何加班码),而"这一行批准了没有"住在批次上;
--   批的人是另一个员工,他的名字 employees 的 RLS 也不给。与 my_document_decisions 同形:
--   只替调用者打开他【自己的】那几行。没有员工档案的调用者(current_user_employee() 为 NULL)→ 0 行。
-- 【批的人显示成人】account_person(decided_by) → preferred_name,否则 legal_name。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.my_overtime_lines()
 RETURNS TABLE(line_id uuid, work_date date, hours numeric, day_kind text, note text, batch_label text, approved_at timestamp with time zone, approver text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT l.id, l.work_date, l.hours, l.day_kind, l.note, b.label, b.decided_at,
           (SELECT COALESCE(NULLIF(btrim(e.preferred_name), ''), e.legal_name)
              FROM employees e WHERE e.id = account_person(b.decided_by))
      FROM overtime_lines l
      JOIN overtime_batches b ON b.id = l.batch_id
     WHERE l.employee_id = current_user_employee()
       AND l.voided_at IS NULL
       AND b.status = 'approved'
     ORDER BY l.work_date DESC
$function$;

COMMENT ON FUNCTION public.my_overtime_lines() IS
'OVERTIME-1(Tim Q14):调用者自己已批准、没作废的加班行(日期、小时、桶、备注、批次、批准时刻、批的人显示成人)。属主权限,只给调用者自己的;没有员工档案 → 0 行。';
