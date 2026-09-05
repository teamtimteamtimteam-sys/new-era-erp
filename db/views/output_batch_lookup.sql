-- db/views/output_batch_lookup.sql
-- FIX-2a(2026-09-05)· 跨模块【查名】视图。
-- ★ 暴露面【就是】下面的列清单。加一列等于扩一次权 —— 连着 db/fixtures/194 一起想。
-- 不变量:本视图只改【行】谓词;每一列原样保留它已有的 data.* 遮蔽。
-- NOTE: introduced by db/migrations/2026-09-05-fix2a-cross-module-lookup-views.sql.

CREATE VIEW public.output_batch_lookup WITH (security_invoker = off) AS
 SELECT id,
    code,
    material_id,
    customer_id,
    quantity,
    remaining_qty,
    unit,
    output_date,
    state,
    status,
    deleted_at
   FROM output_batches b
  WHERE has_permission('module.output.view'::text) OR has_permission('module.purchasing.view'::text) OR has_permission('module.finance.view'::text) OR has_permission('module.inventory.view'::text) OR has_permission('module.processing.view'::text);

COMMENT ON VIEW public.output_batch_lookup IS
    'FIX-2a:产出批次的【查名】视图 —— 编号 / 物料 / 客户 / 数量 / 状态 / 产出日。库存与财务五处要把一行库存或一笔金额指回它是哪一批。★ output_batches 这张表【本来就没有任何价格列】,所以这里没有遮蔽 —— 毛利在 batch_margin,单位成本在 processing_outputs,两张都【没有】跟着放宽。行谓词 output.view OR purchasing.view OR finance.view OR inventory.view OR processing.view。没有 purity / notes / purpose_code。';

GRANT SELECT ON public.output_batch_lookup TO authenticated;
