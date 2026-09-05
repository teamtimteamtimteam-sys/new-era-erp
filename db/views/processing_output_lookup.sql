-- db/views/processing_output_lookup.sql
-- FIX-2a(2026-09-05)· 跨模块【查名】视图。
-- ★ 暴露面【就是】下面的列清单。加一列等于扩一次权 —— 连着 db/fixtures/194 一起想。
-- 不变量:本视图只改【行】谓词;每一列原样保留它已有的 data.* 遮蔽。
-- NOTE: introduced by db/migrations/2026-09-05-fix2a-cross-module-lookup-views.sql.

CREATE VIEW public.processing_output_lookup WITH (security_invoker = off) AS
 SELECT id,
    output_batch_id,
    run_id,
    quantity_produced,
    cost_incomplete,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN unit_cost_base
            ELSE NULL::numeric
        END AS unit_cost_base
   FROM processing_outputs o
  WHERE has_permission('module.processing.view'::text) OR has_permission('module.finance.view'::text) OR has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.processing_output_lookup IS
    'FIX-2a:产出腿的【查名】视图 —— 批次 / 加工单 / 数量,外加按 data.view_prices 遮的单位成本(与 processing_outputs_masked 同一条列谓词)。只改【行】谓词:此前读不到行的人在 /inventory 上拿到的是一个自信的 0.00,而那一页自己已经有具名受限的渲染,只是没有行去驱动它。行谓词 processing.view OR finance.view OR inventory.view。';

GRANT SELECT ON public.processing_output_lookup TO authenticated;
