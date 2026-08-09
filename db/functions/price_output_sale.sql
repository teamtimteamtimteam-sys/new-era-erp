CREATE OR REPLACE FUNCTION public.price_output_sale(p_output_batch_id uuid, p_formula_id uuid, p_currency text, p_quantity numeric, p_reference_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    -- 【收钱进来 → tt_buy】。改这一处等于把整个卖方报价换到错误的一边 ——
    -- fixture 38 A 臂在 tt_buy 与 tt_sell 不同的日子上钉着它。
    v_side       constant text := 'tt_buy';
    v_batch      record;
    v_metals     jsonb;
    v_terms      jsonb;
    v_mode       text;
    v_formula_code text;
    v_formula_dir  text;
    v_formula_active boolean;
    v_formula_deleted timestamptz;
    v_result     jsonb;
    v_skipped    text[];
    v_usd_price  numeric;
    v_usd        record;
    v_doc        record;
    v_factor     numeric;
    v_unit_ccy   numeric;
BEGIN
    -- 报价就是价格信息(与 calculate_metal_price 同一道门)
    PERFORM require_permission('data.view_prices');

    IF p_reference_date IS NULL THEN
        RAISE EXCEPTION 'REFERENCE_DATE_REQUIRED';
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'QUANTITY_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;

    SELECT ob.id, ob.code INTO v_batch
    FROM output_batches ob WHERE ob.id = p_output_batch_id AND ob.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_BATCH_NOT_FOUND|%', COALESCE(p_output_batch_id::text, '?');
    END IF;

    -- 金属含量来自产出批自己的化验(output_batch_metals)—— 卖的是这批货的含量
    SELECT COALESCE(jsonb_agg(jsonb_build_object('metal', m.metal, 'content_pct', m.content_pct)), '[]'::jsonb)
    INTO v_metals
    FROM output_batch_metals m WHERE m.output_batch_id = p_output_batch_id;
    IF v_metals = '[]'::jsonb THEN
        RAISE EXCEPTION 'NO_METAL_CONTENT|%', v_batch.code;
    END IF;

    IF p_formula_id IS NOT NULL THEN
        v_mode := 'formula';
        SELECT code, direction, is_active, deleted_at
        INTO v_formula_code, v_formula_dir, v_formula_active, v_formula_deleted
        FROM pricing_formulas WHERE id = p_formula_id;
        IF NOT FOUND OR v_formula_deleted IS NOT NULL THEN
            RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', p_formula_id;
        END IF;
        IF NOT v_formula_active THEN
            RAISE EXCEPTION 'FORMULA_INACTIVE|%', v_formula_code;
        END IF;
        -- 买方公式不能拿来卖:方向是公式自己声明的商务属性
        IF v_formula_dir NOT IN ('sale', 'both') THEN
            RAISE EXCEPTION 'FORMULA_DIRECTION|%|%', v_formula_code, v_formula_dir;
        END IF;
        v_terms := pricing_terms_of_formula(p_formula_id);
    ELSE
        -- ── 现货预设:【填出同一份 terms,走同一台引擎】——————————————————————
        -- 100% 应付、零处理费、零折扣、spot 基准。这不是第四条算术分支:
        -- 下面这份 jsonb 与 pricing_terms_of_formula 的输出同构,进的是同一个
        -- calculate_metal_price_from_terms。fixture 38 B 臂断言它与显式的
        -- 100%/0/0 公式给出同一个数 —— 那正是"预设而非分支"的证明。
        v_mode := 'spot_preset';
        SELECT jsonb_build_object(
            'price_basis', 'spot',
            'average_days', NULL,
            'treatment_charge_usd_per_tonne', 0,
            'flat_discount_pct', 0,
            'payables', COALESCE(jsonb_object_agg(m.metal, 100), '{}'::jsonb))
        INTO v_terms
        FROM output_batch_metals m WHERE m.output_batch_id = p_output_batch_id;
    END IF;

    v_result := calculate_metal_price_from_terms(v_terms, v_metals, p_quantity, p_reference_date);

    -- 报价路径:缺行情即拒(quoting 侧的处置 —— 一份按零价卖出去的报价比停一下更坏;
    -- 分摊侧的"跳过继续"在 allocate_processing_costs,两边注释互指,不要统一)
    SELECT COALESCE(array_agg(x), ARRAY[]::text[]) INTO v_skipped
    FROM jsonb_array_elements_text(COALESCE(v_result->'skipped_metals', '[]'::jsonb)) x;
    IF array_length(v_skipped, 1) > 0 THEN
        RAISE EXCEPTION 'METAL_PRICE_MISSING|%|%', array_to_string(v_skipped, ','), p_reference_date;
    END IF;

    v_usd_price := (v_result->>'unit_price_usd_per_kg')::numeric;

    -- ── USD → 单据币种:与买路径同一扇门(fx_rate_asof),【边】不同 ————————————
    SELECT a.rate, a.as_of INTO v_usd FROM fx_rate_asof('USD', p_reference_date, v_side) a;
    IF v_usd.rate IS NULL THEN
        RAISE EXCEPTION 'FX_RATE_MISSING|USD|%|%', p_reference_date, v_side;
    END IF;
    SELECT a.rate, a.as_of INTO v_doc FROM fx_rate_asof(p_currency, p_reference_date, v_side) a;
    IF v_doc.rate IS NULL THEN
        RAISE EXCEPTION 'FX_RATE_MISSING|%|%|%', p_currency, p_reference_date, v_side;
    END IF;
    v_factor := v_usd.rate / v_doc.rate;
    v_unit_ccy := round(v_usd_price * v_factor, 4);

    RETURN jsonb_build_object(
        'unit_price_ccy', v_unit_ccy,
        'currency', p_currency,
        'quantity_kg', p_quantity,
        'breakdown', v_result,
        -- 出处:足以重导出这个数(FIN-26 的标准:重导不出的出处只是标签)。
        -- price_series 恒为 'metal_prices':每金属只有一条序列,不冒称 LME/SMM。
        'provenance', jsonb_build_object(
            'mode', v_mode,
            'formula_id', CASE WHEN p_formula_id IS NOT NULL THEN p_formula_id::text END,
            'formula_code', v_formula_code,
            'terms', v_terms,
            'metals', v_metals,
            'metal_lines', v_result->'lines',
            'price_series', 'metal_prices',
            'quantity_kg', p_quantity,
            'reference_date', p_reference_date,
            'unit_price_usd_per_kg', v_usd_price,
            'fx', jsonb_build_object(
                'side', v_side,
                'usd_rate', v_usd.rate, 'usd_as_of', v_usd.as_of,
                'doc_rate', v_doc.rate, 'doc_as_of', v_doc.as_of,
                'factor', v_factor)
        )
    );
END;
$function$;