-- db/views/blending_plan_prediction.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q17 · Q19 · Q20,Tim):【一份配料计划的预测成分 —— 每一种金属一行,算出来的,不落盘】。
--   金属 = 这份计划的目标金属 ∪ 任何一行批次此刻量过的金属。
--   预测 = 按计划公斤数加权的平均:Σ(planned_kg × content_pct) ÷ Σ planned_kg,【只在每一行都量过这种金属时】才算;
--   任何一行没有这种金属 → predicted_pct 为 NULL、not_measured 为真(屏幕上"没量过",不是 0 —— 少一行就把平均算歪,而且算歪的方向
--   恰好是看起来更合格的那一边)。出处数出来:几行来自化验、几行人填、几行出处不明。
--   出界只标出来,不拒(Q20):flag = below_min / above_max / within;没有目标的金属、或预测算不出 → NULL。比的是未取整的值(屏幕取两位)。
--   ★ 门:module.processing.view。★ 预测本身由各行的含量算出 —— 一行的计划,预测【就是】那一批的含量。所以读者只要看不见其中任何一批
--     (进料批 module.inbound.view / 产出批 module.output.view),预测、出处计数与旗都是 NULL,content_restricted 为真(「受限」)。
--     目标的两个界不遮(那是计划自己的事实)。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.

CREATE VIEW public.blending_plan_prediction WITH (security_invoker = off) AS
 WITH plan_lines AS (
         SELECT l.plan_id,
            count(*) AS line_count,
            sum(l.planned_kg) AS planned_kg,
            bool_or(l.inbound_batch_id IS NOT NULL) AS any_inbound,
            bool_or(l.output_batch_id IS NOT NULL) AS any_output
           FROM blending_plan_lines l
          GROUP BY l.plan_id
        ), plan_metals AS (
         SELECT t.plan_id,
            t.metal
           FROM blending_plan_targets t
        UNION
         SELECT a.plan_id,
            a.metal
           FROM blending_plan_line_metals_all a
          WHERE a.metal IS NOT NULL
        ), calc AS (
         SELECT pm.plan_id,
            pm.metal,
            pl.line_count,
            pl.planned_kg,
            pl.any_inbound,
            pl.any_output,
            count(a.line_id) AS lines_measured,
            count(a.line_id) FILTER (WHERE a.content_source = 'assay'::text) AS lines_from_assay,
            count(a.line_id) FILTER (WHERE a.content_source = 'manual'::text) AS lines_manual,
            count(a.line_id) FILTER (WHERE a.content_source = 'unknown'::text) AS lines_source_unknown,
            sum(a.planned_kg * a.content_pct) AS weighted_sum
           FROM plan_metals pm
             LEFT JOIN plan_lines pl ON pl.plan_id = pm.plan_id
             LEFT JOIN blending_plan_line_metals_all a ON a.plan_id = pm.plan_id AND a.metal = pm.metal
          GROUP BY pm.plan_id, pm.metal, pl.line_count, pl.planned_kg, pl.any_inbound, pl.any_output
        ), pred AS (
         SELECT c.plan_id,
            c.metal,
            c.line_count,
            c.planned_kg,
            c.any_inbound,
            c.any_output,
            c.lines_measured,
            c.lines_from_assay,
            c.lines_manual,
            c.lines_source_unknown,
                CASE
                    WHEN c.line_count > 0 AND c.lines_measured = c.line_count THEN c.weighted_sum / c.planned_kg
                    ELSE NULL::numeric
                END AS predicted_pct,
            COALESCE(c.line_count, 0) = 0 OR c.lines_measured < c.line_count AS not_measured,
            t.min_pct,
            t.max_pct,
            t.source AS target_source,
            t.metal IS NOT NULL AS has_target
           FROM calc c
             LEFT JOIN blending_plan_targets t ON t.plan_id = c.plan_id AND t.metal = c.metal
        )
 SELECT p.plan_id,
    p.metal,
    p.has_target,
    p.min_pct,
    p.max_pct,
    p.target_source,
    COALESCE(p.line_count, 0) AS line_count,
    p.planned_kg,
        CASE
            WHEN v.visible THEN p.lines_measured
            ELSE NULL::bigint
        END AS lines_measured,
        CASE
            WHEN v.visible THEN p.lines_from_assay
            ELSE NULL::bigint
        END AS lines_from_assay,
        CASE
            WHEN v.visible THEN p.lines_manual
            ELSE NULL::bigint
        END AS lines_manual,
        CASE
            WHEN v.visible THEN p.lines_source_unknown
            ELSE NULL::bigint
        END AS lines_source_unknown,
        CASE
            WHEN v.visible THEN p.predicted_pct
            ELSE NULL::numeric
        END AS predicted_pct,
        CASE
            WHEN v.visible THEN p.not_measured
            ELSE NULL::boolean
        END AS not_measured,
        CASE
            WHEN NOT v.visible OR p.predicted_pct IS NULL OR NOT p.has_target THEN NULL::text
            WHEN p.min_pct IS NOT NULL AND p.predicted_pct < p.min_pct THEN 'below_min'::text
            WHEN p.max_pct IS NOT NULL AND p.predicted_pct > p.max_pct THEN 'above_max'::text
            ELSE 'within'::text
        END AS flag,
    NOT v.visible AS content_restricted
   FROM pred p
     CROSS JOIN LATERAL ( SELECT (NOT COALESCE(p.any_inbound, false) OR has_permission('module.inbound.view'::text))
                             AND (NOT COALESCE(p.any_output, false) OR has_permission('module.output.view'::text)) AS visible) v
  WHERE has_permission('module.processing.view'::text);

COMMENT ON VIEW public.blending_plan_prediction IS
    'MES-5b-3:配料计划的预测成分,每种金属一行(目标金属 ∪ 量过的金属):按计划公斤数加权的平均,任何一行没量过这种金属就是 NULL(not_measured);出处计数;出界只标(below_min / above_max / within),不拒。门 module.processing.view;看不见其中任何一批的读者,预测、计数与旗都是 NULL(content_restricted)。';

GRANT SELECT ON public.blending_plan_prediction TO authenticated;
REVOKE ALL ON public.blending_plan_prediction FROM anon;
