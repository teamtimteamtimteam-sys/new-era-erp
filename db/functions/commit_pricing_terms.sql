CREATE OR REPLACE FUNCTION public.commit_pricing_terms(p_formula_id uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_inbound_batch_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_terms jsonb;
    v_id    uuid;
BEGIN
    IF num_nonnulls(p_purchase_order_line_id, p_inbound_batch_id) <> 1 THEN
        RAISE EXCEPTION 'COMMITMENT_TARGET_INVALID';
    END IF;
    -- 活公式的检查(不存在/软删/停用)在这里发生,而且【只发生在承诺时】:
    -- 结算时再检查活公式,就又把模板的现状拉回到已成交的交易里了。
    v_terms := pricing_terms_of_formula(p_formula_id);

    INSERT INTO pricing_term_commitments (
        purchase_order_line_id, inbound_batch_id,
        source_formula_id, source_formula_code, source_formula_name,
        price_index, price_basis, average_days, treatment_charge_usd_per_tonne, flat_discount_pct)
    VALUES (
        p_purchase_order_line_id, p_inbound_batch_id,
        (v_terms->>'formula_id')::uuid, v_terms->>'formula_code', v_terms->>'formula_name',
        v_terms->>'price_index', v_terms->>'price_basis', (v_terms->>'average_days')::integer,
        (v_terms->>'treatment_charge_usd_per_tonne')::numeric,
        (v_terms->>'flat_discount_pct')::numeric)
    RETURNING id INTO v_id;

    INSERT INTO pricing_term_commitment_metals (commitment_id, metal, payable_pct)
    SELECT v_id, e.key, e.value::numeric
    FROM jsonb_each_text(v_terms->'payables') e;

    RETURN v_id;
END;
$function$;