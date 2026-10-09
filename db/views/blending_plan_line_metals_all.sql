-- db/views/blending_plan_line_metals_all.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q17 · Q19,Tim):【一份配料计划的每一行 × 那一批此刻的每一种金属含量,连同出处】—— 属主权限,SELECT 已收回。
--   出处照它自己那张表记的说:assay(实验室,source_assay_id 指着那份化验)· manual(人填的)· unknown(PROC-1 之前的进料行,出处没记 ——
--   不猜成任何一种)。一行一种金属都没有的批次照样出一行(metal 为空),好让预测数得出"这一行没量过"。
--   门在两个读者里:blending_plan_line_metals(逐行,含量按那一批自己的查看码遮)与 blending_plan_prediction(加权平均)。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.

CREATE VIEW public.blending_plan_line_metals_all WITH (security_invoker = off) AS
 SELECT l.id AS line_id,
    l.plan_id,
        CASE
            WHEN l.inbound_batch_id IS NOT NULL THEN 'inbound'::text
            ELSE 'output'::text
        END AS batch_kind,
    COALESCE(l.inbound_batch_id, l.output_batch_id) AS batch_id,
    COALESCE(ib.code, ob.code) AS batch_code,
    l.planned_kg,
    m.metal,
    m.content_pct,
        CASE
            WHEN m.metal IS NULL THEN NULL::text
            ELSE COALESCE(m.content_source, 'unknown'::text)
        END AS content_source,
    m.source_assay_id
   FROM blending_plan_lines l
     LEFT JOIN inbound_batches ib ON ib.id = l.inbound_batch_id
     LEFT JOIN output_batches ob ON ob.id = l.output_batch_id
     LEFT JOIN LATERAL ( SELECT x.metal,
            x.content_pct,
            x.content_source,
            x.source_assay_id
           FROM inbound_batch_metals x
          WHERE x.inbound_batch_id = l.inbound_batch_id
        UNION ALL
         SELECT y.metal,
            y.content_pct,
            y.content_source,
            y.source_assay_id
           FROM output_batch_metals y
          WHERE y.output_batch_id = l.output_batch_id) m ON true;

COMMENT ON VIEW public.blending_plan_line_metals_all IS
    'MES-5b-3:配料计划每一行 × 那一批此刻的每一种金属含量与出处(assay / manual / unknown)。属主权限,authenticated 读不到 —— 经 blending_plan_line_metals 与 blending_plan_prediction 读。';

REVOKE ALL ON public.blending_plan_line_metals_all FROM authenticated, anon;
