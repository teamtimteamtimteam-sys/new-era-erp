-- db/views/output_batch_metal_lookup.sql
-- FIX-2a(2026-09-05)· 跨模块【查名】视图。
-- ★ 暴露面【就是】下面的列清单。加一列等于扩一次权 —— 连着 db/fixtures/194 一起想。
-- 不变量:本视图只改【行】谓词;每一列原样保留它已有的 data.* 遮蔽。
-- NOTE: introduced by db/migrations/2026-09-05-fix2a-cross-module-lookup-views.sql.

CREATE VIEW public.output_batch_metal_lookup WITH (security_invoker = off) AS
 SELECT output_batch_id,
    metal,
    content_pct
   FROM output_batch_metals m
  WHERE has_permission('module.output.view'::text) OR has_permission('module.inventory.view'::text) OR has_permission('module.processing.view'::text);

COMMENT ON VIEW public.output_batch_metal_lookup IS
    'FIX-2a:产出批次金属含量的【查名】视图 —— 批次 / 金属 / 含量百分比。/inventory 的"成品按市价"用它乘以金属行情。★ 含量不是价格:metal_prices 的 SELECT 谓词是 USING (true)(公开),此前含量只对 output.view 可见,于是持 inventory.view 的读者拿到"市值 0.00" —— 两个乘数里公开的那个读得到,另一个读不到。行谓词 output.view OR inventory.view OR processing.view。没有 source_assay_id / 出处 —— 那是含量【怎么来的】,不是含量本身。';

GRANT SELECT ON public.output_batch_metal_lookup TO authenticated;
