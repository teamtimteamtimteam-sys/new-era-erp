-- 01 结算把单据【恰好】清零 —— 含跨币种
--
-- 为什么值得常设:这条错了,钱对不上而没有任何东西会报错。
-- FIN-2 立的规矩:敞口与核销都在【单据币种】里记,所以单据能恰好归零;
-- FIN-16 放开了"付款必须同币种",但没有动上面那一条。
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid();
    v_role uuid; v_cust uuid; v_mat uuid; v_batch uuid; v_sale uuid;
    d date := '2026-06-15';   -- 周一,工作日;见 README 第 4 条,不依赖假日表
    v_open numeric; v_alloc numeric; v_cnt int;
BEGIN
    -- 自建全权限角色(不借引导角色;user_roles 无 auth.users 外键 —— 见 README)
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-01', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);

    -- 期间锁也是【会变的运行时配置】(线上此刻是 2026-08-01):不能继承它,
    -- 否则今天过、明天锁一推就红。本 fixture 自己把它清掉 —— 整段最后回滚。
    -- 见 README 第 4 条:只依赖稳定的引导数据。
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES ('USD', d, 'tt_buy', 1.24), ('USD', d, 'tt_sell', 1.24);

    INSERT INTO customers (code, legal_name, country) VALUES ('FIXT-C1', 'Fixture Customer 1', 'SG')
        RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES ('FIXT-M1', 'Fixture Material 1', 'battery_material', true, 'black_mass', 'end_of_life')
        RETURNING id INTO v_mat;

    -- ── A. 同币种全额结清 → 敞口恰好 0 ────────────────────────────────────
    INSERT INTO output_batches (material_id, code, quantity, remaining_qty, unit,
                                output_date, state, customer_id)
    VALUES (v_mat, 'FIXT-B1', 100, 100, 'kg', d, '库存中', v_cust) RETURNING id INTO v_batch;
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
                               currency, fx_rate, amount_base, sale_date)
    VALUES (v_batch, v_cust, 100, 10, 'USD', 1.26, 1260, d) RETURNING id INTO v_sale;

    PERFORM record_payment('in', v_cust, 1000, 'USD', NULL, '1010', d, NULL,
        jsonb_build_array(jsonb_build_object('sales_record_id', v_sale, 'amount_doc', 1000)));

    SELECT COALESCE(open_ccy, -1) INTO v_open FROM ar_open_items WHERE sales_record_id = v_sale;
    -- 结清后该行整个从 ar_open_items 消失 —— 取不到即为恰好清零
    IF v_open IS NOT NULL AND v_open <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 01A 失败:同币种全额结清后敞口应为 0(或行消失),实得 %', v_open;
    END IF;

    -- ── B. 跨币种:USD 6,000 的单,收 SGD 6,000 ───────────────────────────
    -- 【这里字面量就是断言对象,说明它怎么来的】
    --   牌价 1.24(本 fixture 自己插的,上面)。SGD 6,000 能买到的美元 =
    --   6000 / 1.24 = 4838.709677… → 分位四舍五入 = 4,838.71。
    --   于是单据仍欠 6000 − 4838.71 = 1,161.29 USD。
    --   改牌价或改收款额,这两个数就都要跟着重算 —— 别直接"修正"它们。
    INSERT INTO output_batches (material_id, code, quantity, remaining_qty, unit,
                                output_date, state, customer_id)
    VALUES (v_mat, 'FIXT-B2', 100, 100, 'kg', d, '库存中', v_cust) RETURNING id INTO v_batch;
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
                               currency, fx_rate, amount_base, sale_date)
    VALUES (v_batch, v_cust, 100, 60, 'USD', 1.26, 7560, d) RETURNING id INTO v_sale;

    PERFORM record_payment('in', v_cust, 6000, 'SGD', NULL, '1000', d, NULL,
        jsonb_build_array(jsonb_build_object('sales_record_id', v_sale, 'amount_doc', 4838.71)));

    SELECT SUM(allocated_ccy) INTO v_alloc FROM payment_allocations WHERE sales_record_id = v_sale;
    IF v_alloc <> 4838.71 THEN
        RAISE EXCEPTION 'FIXTURE 01B 失败:核销额应为 4838.71 USD(= 6000 SGD ÷ 1.24),实得 %', v_alloc;
    END IF;
    SELECT open_ccy INTO v_open FROM ar_open_items WHERE sales_record_id = v_sale;
    IF v_open <> 1161.29 THEN
        RAISE EXCEPTION 'FIXTURE 01B 失败:剩余敞口应为 1161.29 USD(= 6000 − 4838.71),实得 %', v_open;
    END IF;

    -- 消耗掉的是【整笔】付款:未核销为 0,不该有挂账余额
    SELECT count(*) INTO v_cnt FROM payments p
    WHERE p.id = (SELECT payment_id FROM payment_allocations WHERE sales_record_id = v_sale LIMIT 1)
      AND p.amount_ccy = 6000 AND p.currency = 'SGD';
    IF v_cnt <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 01B 失败:付款额应为 SGD 6000,未找到匹配的付款行';
    END IF;
END $$;
ROLLBACK;
