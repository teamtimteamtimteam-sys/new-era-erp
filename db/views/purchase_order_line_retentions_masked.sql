-- db/views/purchase_order_line_retentions_masked.sql
-- ★ ROLE-1 Batch 4a(2026-09-25,Tim 的 Q9 线):本视图是【采购那一侧】的价格 —— 遮蔽码从 data.view_prices
--   换成 data.view_purchase_prices(今天持 view_prices 的每一个角色一并拿到它,仓库只拿它)。
-- 遮蔽伴生视图:purchase_order_line_retentions 的每一列都在,敏感列按 has_permission() 置空。
--   遮蔽的列:fixed_amount_ccy / released_amount_ccy / withheld_amount_ccy → data.view_prices
--
-- 【属主权限,不是 SECURITY INVOKER】与 purchase_order_payment_terms_masked 同一个理由:
-- invoker 视图以调用者身份读基表,而任何强到能挡住原始列的机制同样会挡住视图本身。
-- 模块谓词原样加回视图体,所以它【不放宽任何行访问】。
--
-- 【为什么 percentage 不遮】purchase_order_payment_terms_masked 也不遮它的 percentage ——
-- 一个比例不是一笔钱,而遮住它会让"这台机器有没有质保金"这个事实本身消失,
-- 那是采购侧要看见的东西。
--
-- NOTE: introduced by db/migrations/2026-09-01-eqppay1-b-equipment-milestones-and-retention.sql.

CREATE VIEW public.purchase_order_line_retentions_masked WITH (security_invoker = off) AS
 SELECT id,
    purchase_order_line_id,
    percentage,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN fixed_amount_ccy
            ELSE NULL::numeric
        END AS fixed_amount_ccy,
    retention_months,
    anchor_event,
    notes,
    created_at,
    created_by,
    released_at,
    released_by,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN released_amount_ccy
            ELSE NULL::numeric
        END AS released_amount_ccy,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN withheld_amount_ccy
            ELSE NULL::numeric
        END AS withheld_amount_ccy,
    withholding_reason
   FROM purchase_order_line_retentions
  WHERE has_permission('module.purchasing.view'::text);
