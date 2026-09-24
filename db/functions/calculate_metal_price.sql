CREATE OR REPLACE FUNCTION public.calculate_metal_price(p_formula_id uuid, p_metals jsonb, p_quantity_kg numeric, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- ROLE-1 Batch 4a(grilling Q9):计价器算出的是【这条公式那一侧】的价格 —— 销售公式要
    -- data.view_prices,采购与两用公式要 data.view_purchase_prices(与三张公式视图同一条线,
    -- pricing_formula_terms_visible)。公式不存在时按采购那一侧问,随后由 _internal 报找不到。
    PERFORM require_permission(CASE WHEN (SELECT f.direction FROM pricing_formulas f WHERE f.id = p_formula_id) = 'sale'
                                    THEN 'data.view_prices' ELSE 'data.view_purchase_prices' END);
    RETURN calculate_metal_price_internal(p_formula_id, p_metals, p_quantity_kg, p_reference_date);
END;
$function$;