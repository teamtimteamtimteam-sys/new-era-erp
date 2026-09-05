-- db/views/processing_run_lookup.sql
-- FIX-2a(2026-09-05)· 跨模块【查名】视图。
-- ★ 暴露面【就是】下面的列清单。加一列等于扩一次权 —— 连着 db/fixtures/194 一起想。
-- 不变量:本视图只改【行】谓词;每一列原样保留它已有的 data.* 遮蔽。
-- NOTE: introduced by db/migrations/2026-09-05-fix2a-cross-module-lookup-views.sql.

CREATE VIEW public.processing_run_lookup WITH (security_invoker = off) AS
 SELECT id,
    code,
    process_date,
    status,
    work_order_id,
    total_input,
    total_output,
    loss_qty,
    deleted_at
   FROM processing_runs r
  WHERE has_permission('module.processing.view'::text) OR has_permission('module.finance.view'::text) OR has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.processing_run_lookup IS
    'FIX-2a:加工单的【查名】视图 —— 编号 / 日期 / 状态 / 工单 + 投入、产出、损耗三个【数量】。/inventory 的物料平衡与 /finance/processing-costs 的成本归属要它。★ 一列钱都没有:material_cost_base / process_cost_base / total_cost_base / capitalized_cost_base / allocation_snapshot 全部不出列。行谓词 processing.view OR finance.view OR inventory.view。';

GRANT SELECT ON public.processing_run_lookup TO authenticated;
