-- 20 采购行价出处:computed 可重导出、manual 不被化验推翻、存量 NULL 不被猜
--
-- 为什么值得常设(FIN-26):8.0000 挨着 PF-2026-0001,Claude 把手敲的数读成了
-- 公式输出 —— 供应商报价单和审计读到的一样。出处必须是【记录】:
--   A computed 行存的依据够把数【重新导出来】:化验 × 可付比 × 行情 ÷ 1000 −
--     处理费 − 折扣 → USD/kg × fx —— fixture 用存进 provenance 的数字逐步复算,
--     必须恰好等于行上的 estimated_unit_price。导不出来的出处只是标签。
--   B manual 是记录不是推断:行上【设了】expected_assay 照样读 manual ——
--     从"化验空不空"猜出处,在谁改了一个字段没改另一个那一刻就失真。
--   C 存量行(不带出处的旧调用形状)保持 NULL —— 不回填猜测,配对约束也不许
--     provenance 无 source 单飞。
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid(); v_role uuid;
    v_sup uuid; v_mat uuid; v_fx numeric := 1.26; v_po jsonb;
    v_line record; v_prov jsonb; v_expect numeric; v_usd numeric;
    v_gross numeric; v_treat numeric; v_disc numeric;
    v_today date := CURRENT_DATE; v_formula uuid;
    v_msg text; v_ok boolean;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-20', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO suppliers (code, legal_name, country, counterparty_type) VALUES ('FIXT-S20', 'Fixture Supplier 20', 'SG', 'goods_supplier')
        RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES ('FIXT-M20', 'Fixture Material 20', 'battery_material', true, 'black_mass', 'end_of_life')
        RETURNING id INTO v_mat;
    -- 下单日牌价(单据 SGD:分子 fx(USD)=1.26,分母 fx(SGD)=1 → factor 1.26)
    DELETE FROM fx_rates WHERE currency = 'USD' AND rate_date = v_today AND rate_type = 'tt_sell';
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES ('USD', v_today, 'tt_sell', v_fx);
    SELECT id INTO v_formula FROM pricing_formulas WHERE deleted_at IS NULL AND is_active LIMIT 1;

    -- ════════ A. computed:provenance 进库,且能【重导出】行价 ════════════════
    -- 依据(与 computeLineEstimate 的产物同构):镍 30%、可付 70%、行情 15000
    -- USD/t、处理费 200 USD/t、折扣 0;100 kg。
    --   gross = 100×0.30×0.70×15000/1000 = 315;treat = 100/1000×200 = 20;
    --   net = 295 → 2.95 USD/kg × 1.26 = 3.717 SGD/kg(表单四舍到 4 位 = 3.717)。
    v_prov := jsonb_build_object(
        'calc', jsonb_build_object(
            'formula_code', 'FIXT-PF', 'price_basis', 'spot', 'reference_date', v_today,
            'quantity_kg', 100,
            'lines', jsonb_build_array(jsonb_build_object(
                'metal', 'ni', 'content_pct', 30, 'payable_pct', 70,
                'price_usd_per_tonne', 15000, 'price_date', v_today, 'metal_value_usd', 315)),
            'gross_value_usd', 315, 'treatment_usd', 20, 'discount_usd', 0,
            'net_value_usd', 295, 'unit_price_usd_per_kg', 2.95,
            'treatment_charge_usd_per_tonne', 200),
        'fx_factor', v_fx, 'fx_as_of', v_today, 'doc_price', '3.717', 'currency', 'SGD');

    v_po := create_purchase_order(v_sup, v_today, NULL, 'SGD', NULL, NULL, NULL, NULL,
        jsonb_build_array(jsonb_build_object(
            'line_no', 1, 'material_id', v_mat, 'quantity', 100, 'unit', 'kg',
            'pricing_formula_id', v_formula, 'estimated_unit_price', 3.717,
            'expected_assay', jsonb_build_array(jsonb_build_object('metal','ni','content_pct',30)),
            'price_source', 'computed', 'price_provenance', v_prov)),
        NULL);

    -- APR-2:采购单现在【生为 draft/pending】,而未获批的单收不了货。本 fixture 测的
    -- 不是审批流,所以直接把它置成已批 —— 与 fixture 26/30 为 fx_rate 显式给值同一
    -- 性质:把新增的前置条件明写出来,而不是让它悄悄挡住别的断言。
    -- (审批流本身由 db/fixtures/35 覆盖。)
    UPDATE purchase_orders SET approval_status = 'approved', status = 'confirmed'
     WHERE id = (v_po->>'purchase_order_id')::uuid;

    SELECT * INTO v_line FROM purchase_order_lines
    WHERE purchase_order_id = (v_po->>'purchase_order_id')::uuid AND line_no = 1;
    IF v_line.price_source IS DISTINCT FROM 'computed' OR v_line.price_provenance IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 20A 失败:computed 行应带出处,实得 source=% prov?=%',
            v_line.price_source, (v_line.price_provenance IS NOT NULL);
    END IF;
    -- 【重导出】只用行上存的数字,一步步把价算回来
    v_prov := v_line.price_provenance;
    SELECT SUM( (v_prov->'calc'->>'quantity_kg')::numeric
              * (l->>'content_pct')::numeric / 100.0
              * (l->>'payable_pct')::numeric / 100.0
              * (l->>'price_usd_per_tonne')::numeric / 1000.0 )
      INTO v_gross
    FROM jsonb_array_elements(v_prov->'calc'->'lines') l;
    v_treat := (v_prov->'calc'->>'quantity_kg')::numeric / 1000.0
             * (v_prov->'calc'->>'treatment_charge_usd_per_tonne')::numeric;
    v_disc := COALESCE((v_prov->'calc'->>'discount_usd')::numeric, 0);
    v_usd := round((v_gross - v_treat - v_disc) / (v_prov->'calc'->>'quantity_kg')::numeric, 4);
    v_expect := round(v_usd * (v_prov->>'fx_factor')::numeric, 4);
    IF v_expect <> v_line.estimated_unit_price THEN
        RAISE EXCEPTION 'FIXTURE 20A 失败:从出处重导出 %(gross % − treat % − disc % → %/kg × fx %),行上存的却是 % —— 出处导不出这个数,它只是标签',
            v_expect, v_gross, v_treat, v_disc, v_usd, v_prov->>'fx_factor', v_line.estimated_unit_price;
    END IF;

    -- ════════ B. manual 是记录:行上【有】化验照样 manual ════════════════════
    v_po := create_purchase_order(v_sup, v_today, NULL, 'SGD', NULL, NULL, NULL, NULL,
        jsonb_build_array(jsonb_build_object(
            'line_no', 1, 'material_id', v_mat, 'quantity', 50, 'unit', 'kg',
            'pricing_formula_id', v_formula, 'estimated_unit_price', 8,
            'expected_assay', jsonb_build_array(jsonb_build_object('metal','ni','content_pct',25)),
            'price_source', 'manual')),
        NULL);

    -- APR-2:采购单现在【生为 draft/pending】,而未获批的单收不了货。本 fixture 测的
    -- 不是审批流,所以直接把它置成已批 —— 与 fixture 26/30 为 fx_rate 显式给值同一
    -- 性质:把新增的前置条件明写出来,而不是让它悄悄挡住别的断言。
    -- (审批流本身由 db/fixtures/35 覆盖。)
    UPDATE purchase_orders SET approval_status = 'approved', status = 'confirmed'
     WHERE id = (v_po->>'purchase_order_id')::uuid;
    SELECT * INTO v_line FROM purchase_order_lines
    WHERE purchase_order_id = (v_po->>'purchase_order_id')::uuid AND line_no = 1;
    IF v_line.price_source IS DISTINCT FROM 'manual' OR v_line.price_provenance IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 20B 失败:带化验的手填行应读 manual 且无出处,实得 source=% —— 谁在从化验空不空推断出处?', v_line.price_source;
    END IF;

    -- ════════ C. 存量形状(不带出处)→ NULL 保持 NULL;配对约束把守 ═══════════
    v_po := create_purchase_order(v_sup, v_today, NULL, 'SGD', NULL, NULL, NULL, NULL,
        jsonb_build_array(jsonb_build_object(
            'line_no', 1, 'material_id', v_mat, 'quantity', 10, 'unit', 'kg',
            'estimated_unit_price', 5)),
        NULL);

    -- APR-2:采购单现在【生为 draft/pending】,而未获批的单收不了货。本 fixture 测的
    -- 不是审批流,所以直接把它置成已批 —— 与 fixture 26/30 为 fx_rate 显式给值同一
    -- 性质:把新增的前置条件明写出来,而不是让它悄悄挡住别的断言。
    -- (审批流本身由 db/fixtures/35 覆盖。)
    UPDATE purchase_orders SET approval_status = 'approved', status = 'confirmed'
     WHERE id = (v_po->>'purchase_order_id')::uuid;
    SELECT * INTO v_line FROM purchase_order_lines
    WHERE purchase_order_id = (v_po->>'purchase_order_id')::uuid AND line_no = 1;
    IF v_line.price_source IS NOT NULL OR v_line.price_provenance IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 20C 失败:旧调用形状的行应保持 NULL(未知,不猜),实得 %', v_line.price_source;
    END IF;
    -- computed 无依据 → 函数点名拒
    v_ok := false; v_msg := NULL;
    BEGIN
        PERFORM create_purchase_order(v_sup, v_today, NULL, 'SGD', NULL, NULL, NULL, NULL,
            jsonb_build_array(jsonb_build_object(
                'line_no', 1, 'material_id', v_mat, 'quantity', 10,
                'estimated_unit_price', 5, 'price_source', 'computed')),
            NULL);
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'PROVENANCE_REQUIRED%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 20C 失败:computed 无依据应 PROVENANCE_REQUIRED 拒,实得:%', COALESCE(v_msg, '(没有报错)');
    END IF;
END $$;
ROLLBACK;
