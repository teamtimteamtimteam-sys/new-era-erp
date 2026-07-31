CREATE OR REPLACE FUNCTION public.set_inbound_unit_price(p_inbound_batch_id uuid, p_unit_price numeric, p_currency text DEFAULT 'USD'::text, p_fx_rate numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN reprice_inbound_batch(p_inbound_batch_id, p_unit_price, p_currency, p_fx_rate, p_notes);
END;
$function$

