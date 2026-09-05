-- db/views/material_lookup.sql
-- FIX-1 item 3(2026-09-05):物料的【查名】视图 —— id / 编号 / 名称。
-- 收货、产出与化验三处表单用它把单据指向一种物料;化验成分、规格、安全库存
-- 与废物分类【不出现】—— 那些是物料主数据的内容,不是叫出名字要的东西。
-- ★ 暴露面【就是】下面的列清单。
-- NOTE: introduced by db/migrations/2026-09-05-fix1-cross-module-lookup-views.sql.

-- ★ FIX-2a(2026-09-05):体内谓词放宽/修正,列未改动。
--   替换用的是 -- ★ FIX-2a(2026-09-05):体内谓词放宽/修正,列未改动。
--   替换用的是 -- ★ FIX-2a(2026-09-05):体内谓词放宽/修正,列未改动。
--   替换用的是 CREATE OR REPLACE VIEW,而它【会丢掉 WITH (...)】——
--   迁移末尾因此补了一句 ALTER VIEW ... SET (security_invoker = off)。

CREATE VIEW public.material_lookup WITH (security_invoker = off) AS
 SELECT m.id,
    m.code,
    m.name,
    m.deleted_at,
    m.unit,
    m.kind_code,
    k.name_en AS kind_name_en,
    k.name_zh AS kind_name_zh,
    m.waste_classification_code
   FROM materials m
     LEFT JOIN material_kinds k ON k.code = m.kind_code
  WHERE has_permission('module.materials.view'::text) OR has_permission('module.inbound.view'::text) OR has_permission('module.output.view'::text) OR has_permission('module.inventory.view'::text) OR has_permission('module.purchasing.view'::text);

COMMENT ON VIEW public.material_lookup IS
    'FIX-1 item 3:物料的【查名】视图 —— 只有 id/编号/名称。收货、产出与化验表单用它把单据指向一种物料,而【不】因此拿到化验成分、规格、安全库存或废物分类。属主权限 + 体内谓词 materials.view OR inbound.view OR output.view;新读到它的只有 warehouse(operations 本来就持 materials.view)。暴露面就是这张视图的列清单。';

GRANT SELECT ON public.material_lookup TO authenticated;
