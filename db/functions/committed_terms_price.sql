CREATE OR REPLACE FUNCTION public.committed_terms_price(p_inbound_batch_id uuid, p_reference_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_batch  record;
    v_commit uuid;
    v_live   uuid;
    v_metals jsonb;
    v_calc   jsonb;
BEGIN
    IF p_reference_date IS NULL THEN
        RAISE EXCEPTION 'REFERENCE_DATE_REQUIRED';
    END IF;

    SELECT id, code, quantity, pricing_formula_id, purchase_order_line_id
    INTO v_batch FROM inbound_batches
    WHERE id = p_inbound_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;

    v_commit := resolve_pricing_commitment(v_batch.id);
    IF v_commit IS NULL THEN
        v_live := COALESCE(v_batch.pricing_formula_id,
                           (SELECT pol.pricing_formula_id FROM purchase_order_lines pol
                             WHERE pol.id = v_batch.purchase_order_line_id));
        RAISE EXCEPTION 'PRICING_TERMS_NOT_COMMITTED|%|%', v_batch.code,
            COALESCE((SELECT pf.code FROM pricing_formulas pf WHERE pf.id = v_live), '?');
    END IF;

    SELECT jsonb_agg(jsonb_build_object('metal', ibm.metal, 'content_pct', ibm.content_pct))
    INTO v_metals
    FROM inbound_batch_metals ibm WHERE ibm.inbound_batch_id = v_batch.id;
    IF v_metals IS NULL THEN
        RAISE EXCEPTION 'NO_METALS';
    END IF;

    v_calc := calculate_metal_price_from_terms(
        pricing_terms_of_commitment(v_commit), v_metals, v_batch.quantity, p_reference_date);

    RETURN v_calc || jsonb_build_object('commitment_id', v_commit, 'batch_code', v_batch.code);
END;
$function$;