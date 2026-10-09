-- db/views/blending_plan_line_metals.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q19,Tim):【配料计划的每一行与那一批的金属含量 —— 带门的外壳】。计划页的"候选批次"一段读它。
--   门:module.processing.view(计划的读码)。★ 含量与出处只给【看得见那一批】的读者(Q19):进料批要 module.inbound.view,产出批要
--   module.output.view;看不见的读到 NULL 而 content_restricted 为真 —— 屏幕上是「受限」,不是空,也不是 0(AGENTS.md 决定 3 的边界:
--   标签跟着单据走,含量不跟)。批号与计划的公斤数不遮(那是计划自己的事实)。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.

CREATE VIEW public.blending_plan_line_metals WITH (security_invoker = off) AS
 SELECT line_id,
    plan_id,
    batch_kind,
    batch_id,
    batch_code,
    planned_kg,
    metal,
        CASE
            WHEN v.visible THEN content_pct
            ELSE NULL::numeric
        END AS content_pct,
        CASE
            WHEN v.visible THEN content_source
            ELSE NULL::text
        END AS content_source,
        CASE
            WHEN v.visible THEN source_assay_id
            ELSE NULL::uuid
        END AS source_assay_id,
    NOT v.visible AS content_restricted
   FROM blending_plan_line_metals_all a
     CROSS JOIN LATERAL ( SELECT
                CASE a.batch_kind
                    WHEN 'inbound'::text THEN has_permission('module.inbound.view'::text)
                    ELSE has_permission('module.output.view'::text)
                END AS visible) v
  WHERE has_permission('module.processing.view'::text);

COMMENT ON VIEW public.blending_plan_line_metals IS
    'MES-5b-3:配料计划的每一行与那一批的金属含量,带门(module.processing.view)。含量与出处只给持那一批查看码的读者(进料 module.inbound.view / 产出 module.output.view),否则 NULL 且 content_restricted。';

GRANT SELECT ON public.blending_plan_line_metals TO authenticated;
REVOKE ALL ON public.blending_plan_line_metals FROM anon;
