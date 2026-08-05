-- 08 超额核销被拒 —— 两条守卫,两种币种口径
--
-- 为什么值得常设:这两条守卫【比较的币种不同】,而其中一条曾经把两种货币直接相减,
-- 同币种时完全看不出来。
--   ALLOC_EXCEEDS          —— 单笔核销 > 该单据敞口,比的是【单据币种】
--   ALLOC_EXCEEDS_PAYMENT  —— Σ 消耗 > 款额,比的是【付款币种】
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid(); v_role uuid; v_cust uuid; v_mat uuid;
    v_batch uuid; v_sale uuid; d date := '2026-06-15'; v_msg text; v_ok boolean;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-08', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES ('USD', d, 'tt_buy', 1.24), ('USD', d, 'tt_sell', 1.24);
    INSERT INTO customers (code, legal_name, country)
    VALUES ('FIXT-C8', 'Fixture Customer 8', 'SG') RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, category)
    VALUES ('FIXT-M8', 'Fixture Material 8', 'black_mass') RETURNING id INTO v_mat;

    -- 用例 A 与用例 B 各自一张单据(不共享 —— 共享会让后一条因前一条的累计而被拒,
    -- 那种"通过"与被测规则无关)
    INSERT INTO output_batches (material_id, code, quantity, remaining_qty, unit,
                                output_date, state, customer_id)
    VALUES (v_mat, 'FIXT-B8A', 100, 100, 'kg', d, '库存中', v_cust) RETURNING id INTO v_batch;
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
                               currency, fx_rate, amount_base, sale_date)
    VALUES (v_batch, v_cust, 100, 10, 'USD', 1.24, 1240, d) RETURNING id INTO v_sale;

    -- A. 单笔核销超过单据敞口(1000 USD 的单,核销 1500 USD)→ ALLOC_EXCEEDS
    v_ok := false;
    BEGIN
        PERFORM record_payment('in', v_cust, 5000, 'USD', NULL, '1010', d, NULL,
            jsonb_build_array(jsonb_build_object('sales_record_id', v_sale, 'amount_doc', 1500)));
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'ALLOC_EXCEEDS|%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 08A 失败:核销 1500 > 敞口 1000 应触发 ALLOC_EXCEEDS,实得:%',
            COALESCE(v_msg, '(放行了)');
    END IF;

    -- B. Σ 消耗超过款额,且【两者币种不同】。核销 USD 1000 → 消耗 SGD 1240;
    --    款额只有 SGD 1000。折算后 1240 > 1000 → 拒。
    --    若这条守卫不折算,就是 1000 对 1000 —— 放行。这正是它要挡的那种错。
    INSERT INTO output_batches (material_id, code, quantity, remaining_qty, unit,
                                output_date, state, customer_id)
    VALUES (v_mat, 'FIXT-B8B', 100, 100, 'kg', d, '库存中', v_cust) RETURNING id INTO v_batch;
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
                               currency, fx_rate, amount_base, sale_date)
    VALUES (v_batch, v_cust, 100, 10, 'USD', 1.24, 1240, d) RETURNING id INTO v_sale;

    v_ok := false;
    BEGIN
        PERFORM record_payment('in', v_cust, 1000, 'SGD', NULL, '1000', d, NULL,
            jsonb_build_array(jsonb_build_object('sales_record_id', v_sale, 'amount_doc', 1000)));
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'ALLOC_EXCEEDS_PAYMENT|%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 08B 失败:USD 1000 的核销消耗 SGD 1240 > 款额 SGD 1000,应触发 ALLOC_EXCEEDS_PAYMENT。实得:% —— 若为放行,说明这条守卫又在同币种空间里比了',
            COALESCE(v_msg, '(放行了)');
    END IF;
END $$;
ROLLBACK;
