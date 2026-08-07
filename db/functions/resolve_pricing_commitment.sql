CREATE OR REPLACE FUNCTION public.resolve_pricing_commitment(p_inbound_batch_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RETURN COALESCE(
        (SELECT c.id FROM pricing_term_commitments c
          WHERE c.inbound_batch_id = p_inbound_batch_id),
        (SELECT c.id FROM pricing_term_commitments c
           JOIN inbound_batches b ON b.purchase_order_line_id = c.purchase_order_line_id
          WHERE b.id = p_inbound_batch_id)
    );
END;
$function$;