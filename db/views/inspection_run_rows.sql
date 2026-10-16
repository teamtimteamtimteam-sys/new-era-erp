-- db/views/inspection_run_rows.sql
-- MES-7b-2(2026-10-16,MES-7b Step 0 Q13 · Q14 · Q17,Tim):巡检清单与巡检页读的那一行 —— 一次巡检(编号、照哪一张清单 —— 记下那一刻
--   抄下的代号 / 名字 / 片区、什么时候、谁巡的、在哪、哪台机器)、它更正了哪一次 / 被哪一次更正、合格 / 不合格 / 不适用各几项、
--   发现几条、还开着几条。【属主权限】门 module.safety.view;借来的列只有【标签】(员工的工号与称呼、库位、机器的编号与名字 ——
--   显示标签跟着单据走,四条常设裁定之三)。没有金额。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql.

CREATE VIEW public.inspection_run_rows WITH (security_invoker = off) AS
 SELECT r.id,
    r.code,
    r.template_id,
    r.template_code,
    r.template_name,
    r.template_area,
    r.inspected_at,
    (r.inspected_at AT TIME ZONE 'Asia/Singapore'::text)::date AS inspected_on,
    r.inspector_employee_id,
    (e.code || ' · '::text) || COALESCE(e.preferred_name, e.legal_name) AS inspector_label,
    r.location_id,
    l.code AS location_code,
    l.name AS location_name,
    r.equipment_id,
    fa.code AS equipment_code,
    fa.description AS equipment_name,
    r.notes,
    r.corrects_run_id,
    cr.code AS corrects_run_code,
    r.correction_reason,
    sup.id AS corrected_by_run_id,
    sup.code AS corrected_by_run_code,
    r.recorded_at,
    r.recorded_by,
    ( SELECT count(*)::integer AS count
           FROM inspection_results s
          WHERE s.run_id = r.id AND s.result = 'pass'::text) AS pass_count,
    ( SELECT count(*)::integer AS count
           FROM inspection_results s
          WHERE s.run_id = r.id AND s.result = 'fail'::text) AS fail_count,
    ( SELECT count(*)::integer AS count
           FROM inspection_results s
          WHERE s.run_id = r.id AND s.result = 'na'::text) AS na_count,
    ( SELECT count(*)::integer AS count
           FROM inspection_findings f
          WHERE f.run_id = r.id) AS finding_count,
    ( SELECT count(*)::integer AS count
           FROM inspection_findings f
          WHERE f.run_id = r.id AND NOT (EXISTS ( SELECT 1
                   FROM inspection_finding_closures c
                  WHERE c.finding_id = f.id))) AS open_finding_count
   FROM inspection_runs r
     JOIN employees e ON e.id = r.inspector_employee_id
     LEFT JOIN storage_locations l ON l.id = r.location_id
     LEFT JOIN fixed_assets fa ON fa.id = r.equipment_id
     LEFT JOIN inspection_runs cr ON cr.id = r.corrects_run_id
     LEFT JOIN inspection_runs sup ON sup.corrects_run_id = r.id
  WHERE has_permission('module.safety.view'::text);

COMMENT ON VIEW public.inspection_run_rows IS
    'MES-7b-2:巡检清单与巡检页的一行 —— 编号、记下那一刻抄下的清单代号 / 名字 / 片区、时刻、巡检的人、库位、机器、更正了哪一次 / 被哪一次更正、合格 / 不合格 / 不适用各几项、发现几条与还开着几条。属主权限,门 module.safety.view;借来的只有标签。';

REVOKE ALL ON public.inspection_run_rows FROM authenticated, anon;
GRANT SELECT ON public.inspection_run_rows TO authenticated;
