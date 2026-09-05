-- db/views/shipment_lookup.sql
-- FIX-2a(2026-09-05)· 跨模块【查名】视图。
-- ★ 暴露面【就是】下面的列清单。加一列等于扩一次权 —— 连着 db/fixtures/194 一起想。
-- 不变量:本视图只改【行】谓词;每一列原样保留它已有的 data.* 遮蔽。
-- NOTE: introduced by db/migrations/2026-09-05-fix2a-cross-module-lookup-views.sql.

CREATE VIEW public.shipment_lookup WITH (security_invoker = off) AS
 SELECT s.id,
    s.code,
    s.ship_date,
    s.container_id,
    s.sales_order_id,
    o.code AS sales_order_code,
    c.legal_name AS customer_legal_name
   FROM shipments s
     LEFT JOIN sales_orders o ON o.id = s.sales_order_id
     LEFT JOIN customers c ON c.id = o.customer_id
  WHERE has_permission('module.sales.view'::text) OR has_permission('module.logistics.view'::text);

COMMENT ON VIEW public.shipment_lookup IS
    'FIX-2a:发货单的【查名】视图 —— 编号 / 出运日 / 箱子 / 销售订单号 / 客户法定名。★ 客户名与订单号是【摊平】进来的,不是让调用点做 FK 嵌入:PostgREST 的嵌入对每一张被嵌的表各自套一遍 RLS,于是 shipments(sales_orders(customers)) 要同时持 sales.view 与 customers.view,而 /logistics/containers/[id] 的守卫是 logistics.view。摊平之后判据只有一处。行谓词 sales.view OR logistics.view。没有金额、没有数量、没有订单行。';

GRANT SELECT ON public.shipment_lookup TO authenticated;
