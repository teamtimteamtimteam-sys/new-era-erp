-- db/views/pricing_term_commitments_masked.sql
-- 遮蔽伴生视图:pricing_term_commitments 的每一列都在,敏感列按 has_permission() 置空。
--   遮蔽的列:treatment_charge_usd_per_tonne → data.view_prices,
--             flat_discount_pct → data.view_prices(与 pricing_formulas 同口径)。
--
-- 【属主权限,不是 SECURITY INVOKER】。invoker 视图以调用者身份读基表,于是任何
-- 强到能挡住原始列的机制(收紧行策略、或收回列权限)同样会挡住视图本身 —— 实测
-- 分别得到 0 行与 42501。因此这里用属主权限,并【把模块谓词原样加回视图体】。
-- 承诺同时被采购与进料两侧读到(采购单行看条款、批次结算看条款),所以谓词是
-- 两个模块的【或】—— 与基表策略逐字一致,视图不放宽任何行访问。
--
-- NOTE: introduced by db/migrations/2026-08-07-fin27-pricing-terms-commitment.sql.

CREATE VIEW public.pricing_term_commitments_masked WITH (security_invoker = off) AS
 SELECT id,
    purchase_order_line_id,
    inbound_batch_id,
    source_formula_id,
    source_formula_code,
    source_formula_name,
    price_basis,
    average_days,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN treatment_charge_usd_per_tonne
            ELSE NULL::numeric
        END AS treatment_charge_usd_per_tonne,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN flat_discount_pct
            ELSE NULL::numeric
        END AS flat_discount_pct,
    committed_at,
    committed_by
   FROM pricing_term_commitments
  WHERE has_permission('module.purchasing.view'::text) OR has_permission('module.inbound.view'::text);
