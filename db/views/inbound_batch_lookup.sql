-- db/views/inbound_batch_lookup.sql
-- FIX-2a(2026-09-05)· 跨模块【查名】视图。
-- ★ 暴露面【就是】下面的列清单。加一列等于扩一次权 —— 连着 db/fixtures/194 一起想。
-- 不变量:本视图只改【行】谓词;每一列原样保留它已有的 data.* 遮蔽。
-- NOTE: introduced by db/migrations/2026-09-05-fix2a-cross-module-lookup-views.sql.

CREATE VIEW public.inbound_batch_lookup WITH (security_invoker = off) AS
 SELECT id,
    code,
    material_id,
    supplier_id,
    quantity,
    remaining_qty,
    unit,
    stage,
    arrival_date,
    status,
    deleted_at,
    notes,
    created_at,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN unit_price
            ELSE NULL::numeric
        END AS unit_price
   FROM inbound_batches b
  WHERE has_permission('module.inbound.view'::text) OR has_permission('module.purchasing.view'::text) OR has_permission('module.finance.view'::text) OR has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.inbound_batch_lookup IS
    'FIX-2a:进料批次的【查名】视图 —— 编号 / 物料 / 供应商 / 数量 / 阶段 / 到货日。付款、应付、库存与采购四处要把一笔金额或一行库存指回它来自哪一批。unit_price 在列上但【仍按 data.view_prices 遮】,与 inbound_batches_masked 同一条谓词 —— 本视图只改【行】谓词,不改任何一列的遮蔽。行谓词 inbound.view OR purchasing.view OR finance.view OR inventory.view。没有 pricing_formula_id / pricing_status / 进口许可 / 来源理由(notes 与 created_at 在列上,应付明细页要它们 —— 现场备注不是商务条款)。暴露面就是这张视图未遮的列清单。';

GRANT SELECT ON public.inbound_batch_lookup TO authenticated;
