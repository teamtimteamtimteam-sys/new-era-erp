-- db/functions/formula_terms_state.sql
-- APR-8(2026-09-26):一张公式此刻的条款,规范形 —— 表头各列 + metals(按金属排序)。不含 is_active / deleted_at。
-- 三个读它的人:提交时的 current 与"没有改动"那一判(与 formula_terms_normalize 出来的拟议条款逐项比 jsonb,
-- 数值按值比,70 与 70.00 相等)、fingerprint、CFO 的 snapshot。不存在的公式 → NULL。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.formula_terms_state(p_formula_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT jsonb_build_object(
               'name', f.name, 'direction', f.direction, 'price_basis', f.price_basis,
               'average_days', f.average_days,
               'treatment_charge_usd_per_tonne', f.treatment_charge_usd_per_tonne,
               'flat_discount_pct', f.flat_discount_pct,
               'supplier_id', f.supplier_id, 'customer_id', f.customer_id,
               'price_index', f.price_index, 'notes', f.notes,
               'metals', COALESCE((SELECT jsonb_agg(jsonb_build_object('metal', m.metal, 'payable_pct', m.payable_pct)
                                                    ORDER BY m.metal)
                                     FROM pricing_formula_metals m WHERE m.formula_id = f.id), '[]'::jsonb))
      FROM pricing_formulas f
     WHERE f.id = p_formula_id
$function$;
