-- db/views/blending_plan_outcome.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q18 · Q20,Tim):【混出来的那一批,之后的化验对着计划的目标品位】—— 每一条目标一行,只对执行过的计划。
--   比的是那一批【最新的一份有效化验】:没删、没被取代,按化验日、再按化验编号(ASY- 按年无洞,排得出先后)取最后一份。
--   那份化验记下了就比,不必先"应用"(应用是成本那一侧的事;Q20 说的是"之后的化验")。
--   verdict:not_assayed(那一批还没有化验)· metal_not_in_assay(化验里没有这种金属)· below_min · above_max · within。
--   比的是化验原样的数(它的 weight_basis 一并给出:as_received / dry),不换算 —— 与 contract_grade_breaches 同一个比法。
--   ★ 门:module.processing.view。含量、化验编号与判词只给持 module.output.view 的读者(那一批是一批产出,Q19);否则 NULL 且
--     content_restricted 为真。批号与目标的两个界不遮。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.

CREATE VIEW public.blending_plan_outcome WITH (security_invoker = off) AS
 SELECT p.id AS plan_id,
    t.metal,
    t.min_pct,
    t.max_pct,
    p.run_id,
    r.status AS run_status,
    po.output_batch_id AS batch_id,
    ob.code AS batch_code,
        CASE
            WHEN v.visible THEN a.id
            ELSE NULL::uuid
        END AS assay_id,
        CASE
            WHEN v.visible THEN a.code
            ELSE NULL::text
        END AS assay_code,
        CASE
            WHEN v.visible THEN a.assay_date
            ELSE NULL::date
        END AS assay_date,
        CASE
            WHEN v.visible THEN a.weight_basis
            ELSE NULL::text
        END AS weight_basis,
        CASE
            WHEN v.visible THEN m.content_pct
            ELSE NULL::numeric
        END AS content_pct,
        CASE
            WHEN NOT v.visible THEN NULL::text
            WHEN a.id IS NULL THEN 'not_assayed'::text
            WHEN m.content_pct IS NULL THEN 'metal_not_in_assay'::text
            WHEN t.min_pct IS NOT NULL AND m.content_pct < t.min_pct THEN 'below_min'::text
            WHEN t.max_pct IS NOT NULL AND m.content_pct > t.max_pct THEN 'above_max'::text
            ELSE 'within'::text
        END AS verdict,
    NOT v.visible AS content_restricted
   FROM blending_plans p
     JOIN blending_plan_targets t ON t.plan_id = p.id
     JOIN processing_runs r ON r.id = p.run_id
     LEFT JOIN processing_outputs po ON po.run_id = p.run_id
     LEFT JOIN output_batches ob ON ob.id = po.output_batch_id
     LEFT JOIN LATERAL ( SELECT x.id,
            x.code,
            x.assay_date,
            x.weight_basis
           FROM assay_results x
          WHERE x.output_batch_id = po.output_batch_id AND x.deleted_at IS NULL AND x.superseded_by IS NULL
          ORDER BY x.assay_date DESC, x.code DESC
         LIMIT 1) a ON true
     LEFT JOIN assay_result_metals m ON m.assay_result_id = a.id AND m.metal = t.metal
     CROSS JOIN LATERAL ( SELECT has_permission('module.output.view'::text) AS visible) v
  WHERE p.run_id IS NOT NULL AND has_permission('module.processing.view'::text);

COMMENT ON VIEW public.blending_plan_outcome IS
    'MES-5b-3:执行过的配料计划,混出来那一批最新一份有效化验(没删、没被取代,按化验日与编号取最后一份)对着每一条目标:not_assayed / metal_not_in_assay / below_min / above_max / within。门 module.processing.view;含量、化验与判词只给持 module.output.view 的读者(否则 content_restricted)。';

GRANT SELECT ON public.blending_plan_outcome TO authenticated;
REVOKE ALL ON public.blending_plan_outcome FROM anon;
