-- db/views/work_order_lookup.sql
-- FIX-2a(2026-09-05)· 跨模块【查名】视图。
-- ★ 暴露面【就是】下面的列清单。加一列等于扩一次权 —— 连着 db/fixtures/194 一起想。
-- 不变量:本视图只改【行】谓词;每一列原样保留它已有的 data.* 遮蔽。
-- NOTE: introduced by db/migrations/2026-09-05-fix2a-cross-module-lookup-views.sql.

CREATE VIEW public.work_order_lookup WITH (security_invoker = off) AS
 SELECT id,
    code,
    status,
    scheduled_date
   FROM work_orders w
  WHERE has_permission('module.processing.view'::text) OR has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.work_order_lookup IS
    'FIX-2a:工单的【查名】视图 —— 编号 / 状态 / 排期日。/inventory/output/[materialId] 要把一批产成品指回它的工单。行谓词 processing.view OR inventory.view。没有 notes / close_reason / cancel_reason —— 那三列是【为什么关掉的】,不是"叫出编号"。';

GRANT SELECT ON public.work_order_lookup TO authenticated;
