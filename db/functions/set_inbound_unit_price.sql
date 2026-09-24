CREATE OR REPLACE FUNCTION public.set_inbound_unit_price(p_inbound_batch_id uuid, p_unit_price numeric, p_currency text DEFAULT 'USD'::text, p_fx_rate numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- ★ ROLE-1 Batch 4a:定价归财务(action.price_receipts),而且看不见采购价的人不能定价 ——
    --   两个码都在库里问(grilling Q1)。引擎 reprice_inbound_batch 自己再问一次后者。
    PERFORM require_permission('action.price_receipts');
    PERFORM require_permission('data.view_purchase_prices');
    RETURN reprice_inbound_batch(p_inbound_batch_id, p_unit_price, p_currency, p_fx_rate, p_notes);
END;
$function$;