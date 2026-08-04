-- db/views/sales_records_visible.sql
-- 产出批次的销售记录。要 module.output.view 【且】 data.view_sales。
--
-- 【为什么要第二个码】线上 module.output.view 的持有者里包含 operations 与 warehouse,
-- 而这两个角色【没有】data.view_prices —— 只按模块放开这张视图,现场当场就看见售价了,
-- 与'现场不需要钱'的原则直接冲突。data.view_sales 比 data.view_prices 窄(只是成交记录,
-- 不含采购成本、加工成本、计价公式),所以能发给要看销售盘子的岗位而不打开整个成本面。
--
-- 范围是【团队全部】而非 created_by:销售小团队互相顶班是常态,按 created_by 切会让
-- 同事替录的单从视野里消失;何况 created_by 记的是谁调用了 record_output_sale,
-- 实际发货时那往往是运营或仓储的人,拿它当'这单是谁的'本身就不准。
--
-- NOTE: introduced/updated by db/migrations/2026-08-02-perm4-self-service.sql.

CREATE VIEW public.sales_records_visible WITH (security_invoker = off) AS
 SELECT sr.id,
    sr.output_batch_id,
    ob.code AS output_batch_code,
    sr.customer_id,
    c.legal_name AS customer_name,
    sr.quantity,
    sr.unit_price,
    sr.currency,
    sr.fx_rate,
    sr.amount_base,
    sr.sale_date,
    sr.notes,
    sr.created_at,
    sr.created_by
   FROM sales_records sr
     LEFT JOIN output_batches ob ON ob.id = sr.output_batch_id
     LEFT JOIN customers c ON c.id = sr.customer_id
  WHERE has_permission('module.output.view'::text) AND has_permission('data.view_sales'::text);
