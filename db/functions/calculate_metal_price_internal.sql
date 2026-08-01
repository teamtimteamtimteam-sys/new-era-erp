-- db/functions/calculate_metal_price_internal.sql
-- 计价算术的【内部算子】:DEFINER,不做权限检查,EXECUTE 已对 PUBLIC/authenticated/anon 收回。
-- 它只能从别的函数体内被调用(那时以属主身份运行),不能当作 RPC 直接问出一个价格来。
--
-- 为什么要拆:calculate_metal_price 既是采购页面的界面入口(必须查 data.view_prices),
-- 又被 apply_assay_result 内部调用(仓储/运营在跑,他们没有这个码)。只加一道检查会让
-- 化验应用当场失败,所以把「算」与「谁能问」分开 —— 检查留在同名的入口函数里。
--
-- 【注意】函数默认对 PUBLIC 授予 EXECUTE,只收回 authenticated/anon 是不够的。
--
-- NOTE: introduced by db/migrations/2026-08-01-perm2b-field-masking.sql.

CREATE OR REPLACE FUNCTION public.calculate_metal_price_internal(p_formula_id uuid, p_metals jsonb, p_quantity_kg numeric, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_f            pricing_formulas%ROWTYPE;
    v_ref          date := COALESCE(p_reference_date, CURRENT_DATE);
    v_el           jsonb;
    v_metal        text;
    v_content      numeric;
    v_seen         text[] := ARRAY[]::text[];
    v_payable      numeric;
    v_has_terms    boolean;
    v_price        numeric;
    v_price_date   date;
    v_from         date;
    v_to           date;
    v_contained    numeric;
    v_payable_kg   numeric;
    v_value        numeric;
    v_lines        jsonb := '[]'::jsonb;
    v_skipped      text[] := ARRAY[]::text[];
    v_unpaid       text[] := ARRAY[]::text[];
    v_gross        numeric := 0;
    v_treatment    numeric;
    v_discount     numeric;
    v_net          numeric;
    v_unit         numeric;
BEGIN
    -- 1. 公式
    SELECT * INTO v_f FROM pricing_formulas
    WHERE id = p_formula_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', COALESCE(p_formula_id::text, '?');
    END IF;
    IF NOT v_f.is_active THEN
        RAISE EXCEPTION 'FORMULA_INACTIVE|%', v_f.code;
    END IF;

    -- 2. 数量
    IF p_quantity_kg IS NULL OR p_quantity_kg <= 0 THEN
        RAISE EXCEPTION 'QUANTITY_INVALID';
    END IF;

    -- 3. 金属清单
    IF p_metals IS NULL OR jsonb_typeof(p_metals) <> 'array' OR jsonb_array_length(p_metals) = 0 THEN
        RAISE EXCEPTION 'NO_METALS';
    END IF;

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_metals)
    LOOP
        v_metal := v_el->>'metal';
        IF v_metal IS NULL OR v_metal NOT IN ('ni','co','li','mn','cu','al','fe') THEN
            RAISE EXCEPTION 'METAL_INVALID|%', COALESCE(v_metal, '?');
        END IF;
        IF v_metal = ANY (v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_METAL|%', v_metal;
        END IF;
        v_seen := v_seen || v_metal;

        v_content := (v_el->>'content_pct')::numeric;
        IF v_content IS NULL OR v_content < 0 OR v_content > 100 THEN
            RAISE EXCEPTION 'CONTENT_INVALID|%|%', v_metal, COALESCE((v_el->>'content_pct'), '?');
        END IF;

        -- 4. 商务条款:公式里没有这个金属 = 完全不计价(payable 0),记入 unpaid_metals。
        --    注意与 skipped 的区别:unpaid 是"没谈价",skipped 是"没行情"。
        SELECT pfm.payable_pct INTO v_payable
        FROM pricing_formula_metals pfm
        WHERE pfm.formula_id = p_formula_id AND pfm.metal = v_metal;
        v_has_terms := FOUND;
        IF NOT v_has_terms THEN
            v_payable := 0;
            v_unpaid := v_unpaid || v_metal;
        END IF;

        -- 5. 行情:spot 取参考日之前最近一条;average 取窗口内均值(窗口内无行 → NULL)。
        v_price := NULL; v_price_date := NULL; v_from := NULL; v_to := NULL;
        IF v_f.price_basis = 'spot' THEN
            SELECT mp.price_usd_per_tonne, mp.price_date
            INTO v_price, v_price_date
            FROM metal_prices mp
            WHERE mp.metal = v_metal AND mp.deleted_at IS NULL AND mp.price_date <= v_ref
            ORDER BY mp.price_date DESC
            LIMIT 1;
        ELSE
            -- price_from / price_to 报【实际参与均值的行】的日期范围,而不是名义窗口 ——
            -- 结算单据上要能看出这个均价到底由哪几天的行情撑起来。
            SELECT avg(mp.price_usd_per_tonne), min(mp.price_date), max(mp.price_date)
            INTO v_price, v_from, v_to
            FROM metal_prices mp
            WHERE mp.metal = v_metal AND mp.deleted_at IS NULL
              AND mp.price_date BETWEEN (v_ref - (v_f.average_days - 1)) AND v_ref;
        END IF;

        -- 无可用行情 → 跳过(贡献 0),记入 skipped_metals;沿用 allocate_processing_costs
        -- 的先例:缺行情从来不是硬错误。
        IF v_price IS NULL THEN
            v_skipped := v_skipped || v_metal;
        END IF;

        -- 6. 逐行数量与金额
        v_contained  := round(p_quantity_kg * v_content / 100.0, 4);
        v_payable_kg := round(v_contained * v_payable / 100.0, 4);
        v_value      := CASE WHEN v_price IS NULL THEN 0
                             ELSE round(v_payable_kg / 1000.0 * v_price, 2) END;
        v_gross := v_gross + v_value;

        -- 缺行情/未计价的金属同样出现在 lines 里(金额 0、价格 NULL)——
        -- 结算单据要能逐项交代,不能让它们凭空消失。
        v_lines := v_lines || jsonb_build_object(
            'metal', v_metal,
            'content_pct', v_content,
            'payable_pct', v_payable,
            'contained_kg', v_contained,
            'payable_kg', v_payable_kg,
            'price_usd_per_tonne', v_price,
            'price_date', v_price_date,
            'price_from', v_from,
            'price_to', v_to,
            'metal_value_usd', v_value
        );
    END LOOP;

    -- 7. 汇总
    v_gross     := round(v_gross, 2);
    v_treatment := round(p_quantity_kg / 1000.0 * v_f.treatment_charge_usd_per_tonne, 2);
    v_discount  := round(v_gross * v_f.flat_discount_pct / 100.0, 2);
    v_net       := round(v_gross - v_treatment - v_discount, 2);
    v_unit      := round(v_net / p_quantity_kg, 4);

    RETURN jsonb_build_object(
        'formula_id', v_f.id,
        'formula_code', v_f.code,
        'formula_name', v_f.name,
        'price_basis', v_f.price_basis,
        'average_days', v_f.average_days,
        'reference_date', v_ref,
        'quantity_kg', p_quantity_kg,
        'lines', v_lines,
        'gross_value_usd', v_gross,
        'treatment_usd', v_treatment,
        'discount_usd', v_discount,
        'net_value_usd', v_net,
        'unit_price_usd_per_kg', v_unit,
        -- 低品位料确实可能"不值它的处理费";照实返回,由调用方决定接不接这单。
        'negative_value', (v_net < 0),
        'skipped_metals', to_jsonb(v_skipped),
        'unpaid_metals', to_jsonb(v_unpaid)
    );
END;
$function$;
