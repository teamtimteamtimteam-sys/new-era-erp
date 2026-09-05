-- db/views/material_lookup.sql
-- FIX-1 item 3(2026-09-05):物料的【查名】视图 —— id / 编号 / 名称。
-- 收货、产出与化验三处表单用它把单据指向一种物料;化验成分、规格、安全库存
-- 与废物分类【不出现】—— 那些是物料主数据的内容,不是叫出名字要的东西。
-- ★ 暴露面【就是】下面的列清单。
-- NOTE: introduced by db/migrations/2026-09-05-fix1-cross-module-lookup-views.sql.

CREATE VIEW public.material_lookup WITH (security_invoker = off) AS
 SELECT id,
    code,
    name,
    deleted_at
   FROM materials m
  WHERE has_permission('module.materials.view'::text) OR has_permission('module.inbound.view'::text) OR has_permission('module.output.view'::text);

COMMENT ON VIEW public.material_lookup IS
    'FIX-1 item 3:物料的【查名】视图 —— 只有 id/编号/名称。收货、产出与化验表单用它把单据指向一种物料,而【不】因此拿到化验成分、规格、安全库存或废物分类。属主权限 + 体内谓词 materials.view OR inbound.view OR output.view;新读到它的只有 warehouse(operations 本来就持 materials.view)。暴露面就是这张视图的列清单。';

GRANT SELECT ON public.material_lookup TO authenticated;
