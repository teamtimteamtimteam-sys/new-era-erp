-- db/views/environmental_result_rows.sql
-- MES-7b-2(2026-10-16,MES-7b Step 0 Q16 · Q17,Tim):环境监测那一页的一行 —— 一条结果(参数的名字、采样点、采样日、实验室、报告编号、
--   数值与单位、记下那一刻抄下的限值与口径)、判定(exceeds 超标 · within 在限值之内 · not_judged 不判定 —— 记下时没有限值)、它开的那件事故、
--   它更正了哪一条 / 被哪一条更正。【属主权限】门 module.safety.view;借来的列只有【标签】(参数与实验室的名字、事故编号)。没有金额。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql.

CREATE VIEW public.environmental_result_rows WITH (security_invoker = off) AS
 SELECT r.id,
    r.parameter_code,
    p.name_en AS parameter_name_en,
    p.name_zh AS parameter_name_zh,
    r.sample_point,
    r.sampled_on,
    r.laboratory_code,
    lab.name_en AS laboratory_name_en,
    lab.name_zh AS laboratory_name_zh,
    r.report_reference,
    r.value,
    r.unit,
    r.limit_value,
    r.limit_basis,
    r.exceeds,
        CASE
            WHEN r.exceeds IS NULL THEN 'not_judged'::text
            WHEN r.exceeds THEN 'exceeds'::text
            ELSE 'within'::text
        END AS judgement,
    r.incident_id,
    inc.code AS incident_code,
    r.corrects_result_id,
    r.correction_reason,
    sup.id AS corrected_by_result_id,
    r.recorded_at,
    r.recorded_by
   FROM environmental_results r
     JOIN environmental_parameters p ON p.code = r.parameter_code
     JOIN laboratories lab ON lab.code = r.laboratory_code
     LEFT JOIN incidents inc ON inc.id = r.incident_id
     LEFT JOIN environmental_results sup ON sup.corrects_result_id = r.id
  WHERE has_permission('module.safety.view'::text);

COMMENT ON VIEW public.environmental_result_rows IS
    'MES-7b-2:环境监测的一行 —— 参数、采样点、采样日、实验室、报告编号、数值与单位、抄下的限值与口径、判定(exceeds · within · not_judged)、开的那件事故、更正关系。属主权限,门 module.safety.view;借来的只有标签。';

REVOKE ALL ON public.environmental_result_rows FROM authenticated, anon;
GRANT SELECT ON public.environmental_result_rows TO authenticated;
