-- db/views/pricing_formulas_masked.sql
-- 遮蔽伴生视图:pricing_formulas 的每一列都在,敏感列按 has_permission() 置空。
--   遮蔽的列:flat_discount_pct → data.view_prices, treatment_charge_usd_per_tonne → data.view_prices
--
-- 【属主权限,不是 SECURITY INVOKER】。invoker 视图以调用者身份读基表,于是任何
-- 强到能挡住原始列的机制(收紧行策略、或收回列权限)同样会挡住视图本身 —— 实测
-- 分别得到 0 行与 42501。因此这里用属主权限,并【把模块谓词原样加回视图体】:
--     WHERE has_permission('module.pricing.view')
-- cut 2a 的 SELECT 策略恰好就是这同一个布尔量(与行内容无关,整表要么全可见要么
-- 全不可见),所以这与调用者的 RLS 逐行等价 —— 视图【不放宽任何行访问】。
--
-- NOTE: introduced by db/migrations/2026-08-01-perm2b-field-masking.sql.

CREATE VIEW public.pricing_formulas_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    name,
    direction,
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
    supplier_id,
    customer_id,
    notes,
    is_active,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    price_index
   FROM pricing_formulas
  WHERE has_permission('module.pricing.view'::text);


