CREATE OR REPLACE FUNCTION public.pricing_terms_of_formula(p_formula_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_f   pricing_formulas%ROWTYPE;
    v_pay jsonb;
BEGIN
    SELECT * INTO v_f FROM pricing_formulas
    WHERE id = p_formula_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', COALESCE(p_formula_id::text, '?');
    END IF;
    IF NOT v_f.is_active THEN
        RAISE EXCEPTION 'FORMULA_INACTIVE|%', v_f.code;
    END IF;

    SELECT COALESCE(jsonb_object_agg(pfm.metal, pfm.payable_pct), '{}'::jsonb)
    INTO v_pay
    FROM pricing_formula_metals pfm WHERE pfm.formula_id = p_formula_id;

    RETURN jsonb_build_object(
        'terms_source', 'formula',
        'commitment_id', NULL,
        'formula_id', v_f.id,
        'formula_code', v_f.code,
        'formula_name', v_f.name,
        -- METAL-2:结算挂在哪个指数上是【交易条款】,与 price_basis 同级 ——
        -- 所以它跟着条款走,承诺时一并抄下(FIN-27)。
        -- NULL = 【未声明指数】,只匹配同样未标注指数的行情,不是"匹配任意行情":
        -- 拿一条没人说过出处的报价去结一笔说明了指数的单,就是替它宣称了出处。
        'price_index', v_f.price_index,
        'price_basis', v_f.price_basis,
        'average_days', v_f.average_days,
        'treatment_charge_usd_per_tonne', v_f.treatment_charge_usd_per_tonne,
        'flat_discount_pct', v_f.flat_discount_pct,
        'payables', v_pay
    );
END;
$function$;