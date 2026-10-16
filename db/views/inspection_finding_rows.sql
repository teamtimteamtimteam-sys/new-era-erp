-- db/views/inspection_finding_rows.sql
-- MES-7b-2(2026-10-16,MES-7b Step 0 Q14 · Q15,Tim):一条巡检发现与它此刻的样子 —— 哪一次巡检、第几项、那一项的字与不合格的说明、纠正措施、
--   负责的人、人选的到期日、它那张任务的编号(按"建一张任务"的人自己的私人任务 —— 这里只给编号这个【标签】,任务的内容与状态照旧只给
--   任务表自己的读者)、关闭(做了什么、谁、什么时候)、还开不开着、过没过到期日、有几张不合格报告引用它。
--   【属主权限】门 module.safety.view。巡检页、提醒的去处与不合格报告页读它。没有金额。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql.

CREATE VIEW public.inspection_finding_rows WITH (security_invoker = off) AS
 SELECT f.id,
    f.run_id,
    r.code AS run_code,
    r.template_name,
    (r.inspected_at AT TIME ZONE 'Asia/Singapore'::text)::date AS inspected_on,
    f.result_id,
    s.position,
    s.item_text,
    s.note AS fail_note,
    f.corrective_action,
    f.owner_employee_id,
    (oe.code || ' · '::text) || COALESCE(oe.preferred_name, oe.legal_name) AS owner_label,
    f.due_date,
    f.task_id,
    tk.code AS task_code,
    f.recorded_at,
    f.recorded_by,
    c.closed_at,
    c.what_was_done,
    c.closed_by,
    c.id IS NULL AS is_open,
    c.id IS NULL AND f.due_date IS NOT NULL AND f.due_date < (now() AT TIME ZONE 'Asia/Singapore'::text)::date AS overdue,
    ( SELECT count(*)::integer AS count
           FROM nonconformance_reports n
          WHERE n.inspection_finding_id = f.id) AS ncr_count
   FROM inspection_findings f
     JOIN inspection_runs r ON r.id = f.run_id
     JOIN inspection_results s ON s.id = f.result_id
     JOIN employees oe ON oe.id = f.owner_employee_id
     LEFT JOIN tasks tk ON tk.id = f.task_id
     LEFT JOIN inspection_finding_closures c ON c.finding_id = f.id
  WHERE has_permission('module.safety.view'::text);

COMMENT ON VIEW public.inspection_finding_rows IS
    'MES-7b-2:一条巡检发现与它此刻的样子 —— 巡检、第几项与它的字、不合格的说明、纠正措施、负责的人、到期日、任务编号(标签;任务本身照旧只给任务表的读者)、关闭、开着与否、过期与否、引用它的不合格报告数。属主权限,门 module.safety.view。';

REVOKE ALL ON public.inspection_finding_rows FROM authenticated, anon;
GRANT SELECT ON public.inspection_finding_rows TO authenticated;
