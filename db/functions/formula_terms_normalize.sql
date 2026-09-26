-- db/functions/formula_terms_normalize.sql
-- APR-8(2026-09-26):把屏幕送来的一组公式条款变成规范形(与 formula_terms_state 同一个形状)。
-- 缺省与表的 DEFAULT 一致(direction both · price_basis spot · 两项费用 0);空白的 price_index / notes 读成 NULL。
-- 读不懂 → TERMS_FORMULA_INVALID|哪一项 —— 【不】当成"没有这一项":一组读不懂的金属当空集,等于"所有金属都不计价"
-- (FormulaForm 那座 JSON 桥记过同一条)。值是否在范围内由表上的 CHECK 在试跑时按原话回答。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.formula_terms_normalize(p_terms jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_name   text;
    v_metals jsonb;
    v_field  text := 'terms';
BEGIN
    IF p_terms IS NULL OR jsonb_typeof(p_terms) <> 'object' THEN
        RAISE EXCEPTION 'TERMS_FORMULA_INVALID|terms';
    END IF;
    v_name := btrim(COALESCE(p_terms->>'name', ''));
    IF v_name = '' THEN
        RAISE EXCEPTION 'TERMS_FORMULA_INVALID|name';
    END IF;
    IF jsonb_typeof(COALESCE(p_terms->'metals', '[]'::jsonb)) <> 'array' THEN
        RAISE EXCEPTION 'TERMS_FORMULA_INVALID|metals';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(p_terms->'metals', '[]'::jsonb)) e
                WHERE jsonb_typeof(e) <> 'object' OR COALESCE(btrim(e->>'metal'), '') = ''
                   OR COALESCE(jsonb_typeof(e->'payable_pct'), 'null') = 'null') THEN
        RAISE EXCEPTION 'TERMS_FORMULA_INVALID|metals';
    END IF;
    BEGIN
        v_field := 'metals';
        SELECT COALESCE(jsonb_agg(jsonb_build_object('metal', m.metal, 'payable_pct', m.pct) ORDER BY m.metal), '[]'::jsonb)
          INTO v_metals
          FROM (SELECT btrim(e->>'metal') AS metal, (e->>'payable_pct')::numeric AS pct
                  FROM jsonb_array_elements(COALESCE(p_terms->'metals', '[]'::jsonb)) e) m;
        v_field := 'average_days';
        PERFORM (p_terms->>'average_days')::integer;
        v_field := 'treatment_charge_usd_per_tonne';
        PERFORM (p_terms->>'treatment_charge_usd_per_tonne')::numeric;
        v_field := 'flat_discount_pct';
        PERFORM (p_terms->>'flat_discount_pct')::numeric;
        v_field := 'supplier_id';
        PERFORM (NULLIF(p_terms->>'supplier_id', ''))::uuid;
        v_field := 'customer_id';
        PERFORM (NULLIF(p_terms->>'customer_id', ''))::uuid;
    EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'TERMS_FORMULA_INVALID|%', v_field;
    END;
    RETURN jsonb_build_object(
        'name', v_name,
        'direction', COALESCE(NULLIF(p_terms->>'direction', ''), 'both'),
        'price_basis', COALESCE(NULLIF(p_terms->>'price_basis', ''), 'spot'),
        'average_days', (p_terms->>'average_days')::integer,
        'treatment_charge_usd_per_tonne', COALESCE((p_terms->>'treatment_charge_usd_per_tonne')::numeric, 0),
        'flat_discount_pct', COALESCE((p_terms->>'flat_discount_pct')::numeric, 0),
        'supplier_id', (NULLIF(p_terms->>'supplier_id', ''))::uuid,
        'customer_id', (NULLIF(p_terms->>'customer_id', ''))::uuid,
        'price_index', NULLIF(btrim(COALESCE(p_terms->>'price_index', '')), ''),
        'notes', NULLIF(btrim(COALESCE(p_terms->>'notes', '')), ''),
        'metals', v_metals);
END;
$function$;
