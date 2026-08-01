CREATE OR REPLACE FUNCTION public.calculate_metal_price(p_formula_id uuid, p_metals jsonb, p_quantity_kg numeric, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('data.view_prices');
    RETURN calculate_metal_price_internal(p_formula_id, p_metals, p_quantity_kg, p_reference_date);
END;
$function$;