-- db/views/pricing_formula_history_masked.sql
-- 遮蔽伴生视图:pricing_formula_history 的每一列都在,敏感列按 has_permission() 置空。
--   遮蔽的列:old/new_payable_pct、old/new_treatment_charge_usd_per_tonne、
--             old/new_flat_discount_pct —— 与它们的源列同口径,归 data.view_prices。
-- 【历史的遮蔽必须与源列一致】否则"从多少改到多少"就是一条绕过遮蔽读到价格的路。
--
-- 属主权限 + 模块谓词原样加回,理由同 pricing_formulas_masked。
--
-- NOTE: introduced by db/migrations/2026-08-07-fin27-pricing-terms-commitment.sql.

CREATE VIEW public.pricing_formula_history_masked WITH (security_invoker = off) AS
 SELECT id,
    formula_id,
    change_type,
    metal,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN old_payable_pct
            ELSE NULL::numeric
        END AS old_payable_pct,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN new_payable_pct
            ELSE NULL::numeric
        END AS new_payable_pct,
    old_name,
    new_name,
    old_direction,
    new_direction,
    old_price_basis,
    new_price_basis,
    old_average_days,
    new_average_days,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN old_treatment_charge_usd_per_tonne
            ELSE NULL::numeric
        END AS old_treatment_charge_usd_per_tonne,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN new_treatment_charge_usd_per_tonne
            ELSE NULL::numeric
        END AS new_treatment_charge_usd_per_tonne,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN old_flat_discount_pct
            ELSE NULL::numeric
        END AS old_flat_discount_pct,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN new_flat_discount_pct
            ELSE NULL::numeric
        END AS new_flat_discount_pct,
    old_is_active,
    new_is_active,
    changed_at,
    changed_by
   FROM pricing_formula_history
  WHERE has_permission('module.pricing.view'::text);
