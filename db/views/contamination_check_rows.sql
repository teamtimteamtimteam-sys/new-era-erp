-- db/views/contamination_check_rows.sql
-- MES-4b(2026-10-07,MES-4b Step 0 Q21 · Q25,Tim):【一次一次的交叉污染抽检,带上它挂着的那一炉与那一批】—— 带门的属主视图。
--   加工单页、产出批页与 /operation/contamination 读它。门:加工或产出查看码任一。
--   【为什么是属主视图】只持产出码的人读不到 processing_runs(那张表的读规则是加工码),一张 invoker 视图把它们 join 起来会
--   安静地丢掉每一行(AGENTS.md 的 xmodule)。这里借过去的只有那一炉的单号、加工日与班次 —— 一个显示标签与两个它本来就挂着的事实。
--   is_current:没有被别的行更正过(链的末端)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.

CREATE VIEW public.contamination_check_rows WITH (security_invoker = off) AS
 SELECT c.id,
    c.run_id,
    r.code AS run_code,
    r.process_date,
    r.shift_code,
    c.stream_code,
    c.kind,
    c.output_batch_id,
    ob.code AS output_batch_code,
    c.sample_mass_g,
    c.foreign_mass_g,
    c.rate_pct,
    c.warning_pct_at,
    c.above_warning,
    c.sampled_at,
    c.method,
    c.not_sampled_reason,
    c.recorded_at,
    c.recorded_by,
    c.corrects_id,
    c.correction_reason,
    NOT (EXISTS ( SELECT 1
           FROM contamination_checks x
          WHERE x.corrects_id = c.id)) AS is_current
   FROM contamination_checks c
     JOIN processing_runs r ON r.id = c.run_id
     LEFT JOIN output_batches ob ON ob.id = c.output_batch_id
  WHERE has_any_permission(ARRAY['module.processing.view'::text, 'module.output.view'::text]);

COMMENT ON VIEW public.contamination_check_rows IS
    'MES-4b:交叉污染抽检逐次,带那一炉的单号 / 加工日 / 班次与那一批的批号;is_current = 链的末端。带门(加工或产出查看码)的属主视图。';

GRANT SELECT ON public.contamination_check_rows TO authenticated;
REVOKE ALL ON public.contamination_check_rows FROM anon;
