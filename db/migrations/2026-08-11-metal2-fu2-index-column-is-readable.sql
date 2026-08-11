-- METAL-2 fu2(2026-08-11):把 price_index 加进两张遮蔽表的列级 SELECT 授权与
--                          它们的 _masked 视图
--
-- 【gate 的 colgrant 抓到的,而且这正是它存在的理由】perm2b 把这两张表改成了
-- 【列清单式】的 SELECT 授权,而 PostgreSQL 对两个动词的处理不对称:
-- 表级 INSERT/UPDATE 会自动扩展到后加的列,列清单式 SELECT【不会】——
-- 清单是冻结的。于是 ALTER TABLE ... ADD COLUMN 造出一列"写得进、读不出"的列,
-- 任何 SELECT 到它、甚至只是拿它做过滤的查询,都会 42501。
-- FIN-6 对 processing_cost_entries 干过一次,那两块屏从上线那天起就是空的,
-- 而所有的门都是绿的。
--
-- 【price_index 属于可读的那一类,与 price_basis 同级】它是"这单在哪个市场结算",
-- 不是费率。真正受限的是 treatment_charge / flat_discount(那两列仍只走
-- _masked 视图的 data.view_prices 分支,一字未动)。
--
-- 【视图用 CREATE OR REPLACE 追加在末尾】REPLACE 不许改列集,但允许【在末尾追加】。
BEGIN;

GRANT SELECT (price_index) ON public.pricing_formulas TO authenticated;
GRANT SELECT (price_index) ON public.pricing_term_commitments TO authenticated;

CREATE OR REPLACE VIEW public.pricing_formulas_masked WITH (security_invoker = off) AS
 SELECT id, code, name, direction, price_basis, average_days,
        CASE WHEN has_permission('data.view_prices'::text) THEN treatment_charge_usd_per_tonne
             ELSE NULL::numeric END AS treatment_charge_usd_per_tonne,
        CASE WHEN has_permission('data.view_prices'::text) THEN flat_discount_pct
             ELSE NULL::numeric END AS flat_discount_pct,
    supplier_id, customer_id, notes, is_active, deleted_at,
    created_at, created_by, updated_at, updated_by,
    price_index
   FROM pricing_formulas
  WHERE has_permission('module.pricing.view'::text);

CREATE OR REPLACE VIEW public.pricing_term_commitments_masked WITH (security_invoker = off) AS
 SELECT id, purchase_order_line_id, inbound_batch_id, source_formula_id,
    source_formula_code, source_formula_name, price_basis, average_days,
        CASE WHEN has_permission('data.view_prices'::text) THEN treatment_charge_usd_per_tonne
             ELSE NULL::numeric END AS treatment_charge_usd_per_tonne,
        CASE WHEN has_permission('data.view_prices'::text) THEN flat_discount_pct
             ELSE NULL::numeric END AS flat_discount_pct,
    committed_at, committed_by,
    price_index
   FROM pricing_term_commitments
  WHERE has_permission('module.purchasing.view'::text) OR has_permission('module.inbound.view'::text);

COMMIT;
