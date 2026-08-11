CREATE OR REPLACE FUNCTION public.pricing_terms_of_commitment(p_commitment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c   pricing_term_commitments%ROWTYPE;
    v_pay jsonb;
BEGIN
    SELECT * INTO v_c FROM pricing_term_commitments WHERE id = p_commitment_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PRICING_COMMITMENT_NOT_FOUND|%', COALESCE(p_commitment_id::text, '?');
    END IF;

    SELECT COALESCE(jsonb_object_agg(m.metal, m.payable_pct), '{}'::jsonb)
    INTO v_pay
    FROM pricing_term_commitment_metals m WHERE m.commitment_id = p_commitment_id;

    RETURN jsonb_build_object(
        'terms_source', 'commitment',
        'commitment_id', v_c.id,
        'formula_id', v_c.source_formula_id,
        'formula_code', v_c.source_formula_code,
        'formula_name', v_c.source_formula_name,
        -- METAL-2:成交时抄下的指数。公式事后改指数,这一单仍按当初谈的那个结算。
        'price_index', v_c.price_index,
        'price_basis', v_c.price_basis,
        'average_days', v_c.average_days,
        'treatment_charge_usd_per_tonne', v_c.treatment_charge_usd_per_tonne,
        'flat_discount_pct', v_c.flat_discount_pct,
        'payables', v_pay
    );
END;
$function$;