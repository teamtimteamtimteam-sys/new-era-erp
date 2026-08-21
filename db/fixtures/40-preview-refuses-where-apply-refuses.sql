-- 40 化验试算与提交【同一个答案】:提交会拒的地方试算也拒;试算说的数就是提交存的数
--
-- 【判别臂是 D:汇率那一乘】ASY-1 之前 preview_reprice_inbound_batch 里写的是
-- v_usd := round(p_new_unit_price, 4) —— 一次都不换汇,而 apply_assay_result 按
-- 'USD' 递给 reprice_inbound_batch,FIN-0 之后 USD 是外币,提交乘 tt_sell。
-- 线上实测(已回滚):10 USD/kg → 预览 10.0000 / 提交 12.8000,总调整 500 对 780。
-- 只测"预览有数、提交也有数"的 fixture 对那个实现照样全绿 —— 必须【比两个数】。
-- 注入方式:把 preview_reprice_inbound_batch 的 v_base := round(p*v_fx,4) 改回
-- round(p,4),本臂即红并把两个数一起说出来。
--
-- 【A/B/C 臂是拒绝的三个闸】承诺条款、汇率、期间锁 —— 每臂都断言【两侧】:
-- 试算抛的码 = 提交抛的码。少一侧就退化成"各测各的",而这正是页面按钮敢跟着
-- 横幅走的全部依据(按钮禁用条件 = 预览有 error)。
BEGIN;
DO $$
DECLARE
    u uuid := gen_random_uuid();
    r uuid;
    v_mat uuid; v_sup uuid; v_b uuid; v_assay uuid; v_f uuid;
    v_metals jsonb := '[{"metal":"ni","content_pct":50}]'::jsonb;
    v_prev_err text; v_apply_err text;
    v_prev jsonb; v_impact jsonb; v_stored numeric; v_prev_new numeric;
    v_fx numeric;
BEGIN
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-40', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r, unnest(ARRAY['data.view_prices','module.inbound.edit','module.inbound.view',
                           'module.finance.edit','module.finance.view','module.pricing.view']);
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);

    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX40-M', 'fixture 40 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX40-S', 'fixture 40 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;

    -- 行情与牌价:ni 20,000 USD/吨;USD tt_sell 1.30(【今天】—— 提交按定价日折算)
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source)
    VALUES ('ni', 20000, CURRENT_DATE, 'broker_quote');
    DELETE FROM fx_rates WHERE currency = 'USD' AND rate_date = CURRENT_DATE AND rate_type = 'tt_sell';
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES ('USD', CURRENT_DATE, 'tt_sell', 1.30);

    INSERT INTO pricing_formulas (code, name, direction, price_basis,
                                  treatment_charge_usd_per_tonne, flat_discount_pct)
    VALUES ('ZZFIX40-PF', 'fixture 40 formula', 'purchase', 'spot', 0, 0) RETURNING id INTO v_f;
    INSERT INTO pricing_formula_metals (formula_id, metal, payable_pct) VALUES (v_f, 'ni', 100);

    -- 批次:100 kg,当前单价 5(本位币),挂【活公式】但【无承诺副本】
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
                                 arrival_date, unit_price, pricing_formula_id)
    VALUES ('ZZFIX40-IB', v_mat, v_sup, 100, 100, CURRENT_DATE, 5, v_f) RETURNING id INTO v_b;
    INSERT INTO assay_results (code, inbound_batch_id, assay_date, is_final)
    VALUES ('ZZFIX40-AR', v_b, CURRENT_DATE, true) RETURNING id INTO v_assay;
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct)
    VALUES (v_assay, 'ni', 50);

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u), true);

    -- ══════════ A. 承诺条款缺失:试算拒 ⇔ 提交拒(FIN-27,页面上那条横幅)══════
    v_prev_err := NULL; v_apply_err := NULL;
    BEGIN
        PERFORM preview_assay_price(v_b, v_metals, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN v_prev_err := SQLERRM;
    END;
    BEGIN
        PERFORM apply_assay_result(v_assay);
    EXCEPTION WHEN OTHERS THEN v_apply_err := SQLERRM;
    END;
    IF v_prev_err IS NULL OR v_apply_err IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 40A 失败:有活公式无副本时试算与提交都该拒,实得 preview=% apply=%',
            COALESCE(v_prev_err, '(通过)'), COALESCE(v_apply_err, '(通过)');
    END IF;
    IF v_prev_err <> v_apply_err OR v_prev_err NOT LIKE 'PRICING_TERMS_NOT_COMMITTED|ZZFIX40-IB|ZZFIX40-PF%' THEN
        RAISE EXCEPTION 'FIXTURE 40A 失败:两侧应抛【同一个】点名拒绝,实得 preview=「%」 apply=「%」 —— 不一致,页面按钮就不能跟着横幅走',
            v_prev_err, v_apply_err;
    END IF;

    -- 补上承诺副本:后面几臂才谈得上定价
    PERFORM commit_pricing_terms(v_f, NULL, v_b);

    -- ══════════ B. 缺汇率:试算拒 ⇔ 提交拒(ASY-1 之前试算一声不吭)═══════════
    DELETE FROM fx_rates WHERE currency = 'USD' AND rate_type = 'tt_sell'
      AND rate_date > CURRENT_DATE - 10;
    v_prev_err := NULL; v_apply_err := NULL;
    BEGIN
        PERFORM preview_assay_price(v_b, v_metals, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN v_prev_err := SQLERRM;
    END;
    BEGIN
        PERFORM apply_assay_result(v_assay);
    EXCEPTION WHEN OTHERS THEN v_apply_err := SQLERRM;
    END;
    IF v_prev_err IS NULL OR v_apply_err IS NULL
       OR v_prev_err NOT LIKE 'FX_RATE_MISSING|USD|%' OR v_prev_err <> v_apply_err THEN
        RAISE EXCEPTION 'FIXTURE 40B 失败:缺 USD 牌价时两侧都该点名 FX_RATE_MISSING,实得 preview=「%」 apply=「%」 —— 试算不查汇率,按钮就会请人去点一个必定失败的应用',
            COALESCE(v_prev_err, '(通过)'), COALESCE(v_apply_err, '(通过)');
    END IF;
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES ('USD', CURRENT_DATE, 'tt_sell', 1.30);

    -- ══════════ C. 期间锁:试算拒 ⇔ 提交拒(过账日是 CURRENT_DATE)═════════════
    UPDATE finance_settings SET locked_before = CURRENT_DATE + 1;
    v_prev_err := NULL; v_apply_err := NULL;
    BEGIN
        PERFORM preview_assay_price(v_b, v_metals, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN v_prev_err := SQLERRM;
    END;
    BEGIN
        PERFORM apply_assay_result(v_assay);
    EXCEPTION WHEN OTHERS THEN v_apply_err := SQLERRM;
    END;
    IF v_prev_err IS NULL OR v_apply_err IS NULL
       OR v_prev_err NOT LIKE 'PERIOD_LOCKED|%' OR v_prev_err <> v_apply_err THEN
        RAISE EXCEPTION 'FIXTURE 40C 失败:期间锁住今天时两侧都该点名 PERIOD_LOCKED,实得 preview=「%」 apply=「%」 —— 闸只长在过账那一侧,试算就会说"可以"',
            COALESCE(v_prev_err, '(通过)'), COALESCE(v_apply_err, '(通过)');
    END IF;
    UPDATE finance_settings SET locked_before = NULL;

    -- ══════════ D. 【判别臂】试算说的数 = 提交真正存下的数(汇率那一乘)═════════
    -- ni 20,000 USD/吨 × 50% × 100% = 10 USD/kg;× tt_sell 1.30 = 13.0000 本位币。
    -- 手算依据写在这里(fixture 规则一:字面量即断言时要写清怎么来的)。
    v_prev := preview_assay_price(v_b, v_metals, CURRENT_DATE);
    v_impact := v_prev->'impact';
    IF v_impact IS NULL OR v_impact = 'null'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 40D 前置失败:应当有试算影响块,实得 % —— 后面的比数是空转的', v_prev;
    END IF;
    v_prev_new := (v_impact->>'new_unit_price')::numeric;
    v_fx := (v_impact->>'fx_rate')::numeric;
    IF v_fx <> 1.30 THEN
        RAISE EXCEPTION 'FIXTURE 40D 前置失败:试算该报出用了哪个牌价(1.30),实得 %', v_fx;
    END IF;
    IF v_prev_new <> 13.0000 THEN
        RAISE EXCEPTION 'FIXTURE 40D 失败:试算新单价应为 13.0000(10 USD/kg × tt_sell 1.30),实得 % —— 少乘一次汇率,屏幕上的数就不是将要入账的那个',
            v_prev_new;
    END IF;

    PERFORM apply_assay_result(v_assay);
    SELECT unit_price INTO v_stored FROM inbound_batches WHERE id = v_b;
    IF v_stored <> v_prev_new THEN
        RAISE EXCEPTION 'FIXTURE 40D 失败:试算说 %,提交存下 % —— 屏幕与账本各说各话(ASY-1 之前正是 10.0000 对 12.8000)',
            v_prev_new, v_stored;
    END IF;

    -- ══════════ E. 缺行情【不是拒绝】:跳过该金属,两侧都不抛 ═══════════════════
    -- 与 A/B/C 相反的一臂:分不清"警告"与"拒绝"的实现会把按钮也禁掉,
    -- 而含量本该照常落地(缺行情从来不是硬错误 —— allocate_processing_costs 的先例)。
    DECLARE v_b2 uuid; v_a2 uuid; v_res jsonb;
    BEGIN
        -- 本臂自己造"没有行情"的条件(fixture 规则二:要什么自己设,不继承库里
        -- 碰巧有没有 co 的报价);并把 co 放进条款,免得断言被"没谈价"混淆 ——
        -- unpaid(没谈价)与 skipped(没行情)是两件事。
        INSERT INTO pricing_formula_metals (formula_id, metal, payable_pct) VALUES (v_f, 'co', 100);
        DELETE FROM metal_prices WHERE metal = 'co';

        INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
                                     arrival_date, unit_price, pricing_formula_id)
        VALUES ('ZZFIX40-IB2', v_mat, v_sup, 100, 100, CURRENT_DATE, 5, v_f) RETURNING id INTO v_b2;
        PERFORM commit_pricing_terms(v_f, NULL, v_b2);
        INSERT INTO assay_results (code, inbound_batch_id, assay_date, is_final)
        VALUES ('ZZFIX40-AR2', v_b2, CURRENT_DATE, true) RETURNING id INTO v_a2;
        -- co 没有任何行情:该金属被跳过
        INSERT INTO assay_result_metals (assay_result_id, metal, content_pct) VALUES (v_a2, 'co', 40);

        v_res := preview_assay_price(v_b2, '[{"metal":"co","content_pct":40}]'::jsonb, CURRENT_DATE);
        IF NOT ((v_res->'calc'->'skipped_metals') ? 'co') THEN
            RAISE EXCEPTION 'FIXTURE 40E 失败:缺行情的金属应出现在 skipped_metals(而不是让整次试算失败),实得 skipped=% unpaid=%',
                v_res->'calc'->'skipped_metals', v_res->'calc'->'unpaid_metals';
        END IF;
        -- 提交也不拒:含量落地,只是不定价
        PERFORM apply_assay_result(v_a2);
        IF NOT EXISTS (SELECT 1 FROM inbound_batch_metals WHERE inbound_batch_id = v_b2 AND metal = 'co') THEN
            RAISE EXCEPTION 'FIXTURE 40E 失败:缺行情时含量仍应落地 —— 化验是实验室的事实,不该被行情表拖住';
        END IF;
    END;
END $$;
ROLLBACK;
