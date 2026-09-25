-- db/views/sales_order_line_releasable_all.sql
-- APR-5b(2026-09-25,APR-5 grilling Q8 · 5b grilling Q1):【一条订单行最多能发多少】—— 唯一一处推导(基视图)。
--
--   releasable_qty = 在册订单流发票行(kind='order'、issued、NOT invoice_voided)的开票数量
--                    − Σ 那条发票行上未发货取消贷项的数量。
--   已发【不】在这里减:三个消费方各自要的已发口径不同(ship_order 还要减同一次调用里已经发过的那一截)。
--   没有在册发票行的订单行【不出现】—— 还没开票与开了票却全取消了,是两件事。
--   贷项的数量从 5b 起提交时必填;更早的、没有数量的行按 金额 ÷ 发票行单价 折回 —— 宁可少发,不许多发
--   (线上这样的行 0 条,5b Step 0 以 postgres 读基表)。
--
-- 【三个消费方,一处推导】ship_order 的天花板(SO_SHIP_EXCEEDS_RELEASABLE)· shipping_queue_rows 的
--   放行数量与剩余 · operations_now 的 shipping_release_ready 一支。
-- 【为什么是一张视图,而不是一支函数】operations_now 是属主权限的视图,而属主视图替得了表、替不了函数的
--   EXECUTE(AGENTS.md)—— 一支对 authenticated 收了权的函数会让每一个读仪表盘的人撞上 42501;
--   不收权又等于把别人订单的发货进度逐行敞开(line_spoken_for 那条理由)。视图引用视图走属主替换。
-- 【客户端读不到本视图】REVOKE SELECT —— 它不带 has_permission 的门。
--
-- NOTE: introduced by db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql.

CREATE VIEW public.sales_order_line_releasable_all WITH (security_invoker = off) AS
 SELECT il.sales_order_line_id,
    il.id AS invoice_line_id,
    il.quantity AS invoiced_qty,
    COALESCE(( SELECT sum(COALESCE(cl.qty, cl.amount / NULLIF(il.unit_price, 0::numeric))) AS sum
           FROM credit_note_lines cl
          WHERE cl.invoice_line_id = il.id AND cl.kind = 'unshipped_cancel'::text), 0::numeric) AS cancelled_qty,
    il.quantity - COALESCE(( SELECT sum(COALESCE(cl.qty, cl.amount / NULLIF(il.unit_price, 0::numeric))) AS sum
           FROM credit_note_lines cl
          WHERE cl.invoice_line_id = il.id AND cl.kind = 'unshipped_cancel'::text), 0::numeric) AS releasable_qty
   FROM invoice_lines il
     JOIN invoices i ON i.id = il.invoice_id
  WHERE il.sales_order_line_id IS NOT NULL AND NOT il.invoice_voided AND i.kind = 'order'::text AND i.status = 'issued'::text;

COMMENT ON VIEW public.sales_order_line_releasable_all IS
    'APR-5b:一条订单行最多能发多少 = 在册订单流发票行的开票数量 − 未发货取消贷项的数量(无数量的旧行按 金额 ÷ 单价 折回)。唯一一处推导;消费方 ship_order · shipping_queue_rows · operations_now(shipping_release_ready)。已发不在这里减。客户端读不到:REVOKE SELECT。';

REVOKE SELECT ON public.sales_order_line_releasable_all FROM authenticated, anon;
