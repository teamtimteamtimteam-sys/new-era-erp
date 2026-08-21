-- 14 全额核销的收付款,挂账余额【恰好】为零 —— 哪怕汇率动过
--
-- 为什么值得常设:这条错了,屏幕上会凭空多出一笔并不存在的预收/预付,
-- 而没有任何东西会报错。收付款详情页曾把挂账写作
--     payments.amount_base − Σ payment_allocations.allocated_base
-- 两个数同为本位币,却不是同一个汇率:amount_base 按【结算日】汇率,
-- allocated_base 按【单据入账】汇率。两者之差正是记进 7100 的已实现汇兑。
-- 线上 PMT-2026-0003(付 USD 1,215 @1.265,单据入账 @1.26)因此显示"未冲销 6.08"。
--
-- FIN-18 把消耗掉的付款额落进 payment_allocations.allocated_pay,挂账改为
--     payments.amount_ccy − Σ allocated_pay          (两边同为付款币种)
--
-- 本 fixture 两头都断言:
--   ① 新口径必须恰好为 0;
--   ② 旧口径必须【不为 0】—— 否则这个用例根本分辨不出两种算法,
--      会因为"两边都对"而通过,那是 README 第 1 条要防的那种绿。
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid();
    v_role uuid; v_cust uuid; v_mat uuid; v_batch uuid; v_sale uuid; v_pay uuid;
    dA date := '2026-06-15';   -- 周一,工作日;每个用例自带自己的牌价日
    dB date := '2026-06-16';   -- 周二 —— A 与 B 的 USD 牌价不同,不能共用一天
    v_new numeric; v_old numeric;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-14', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);

    -- 期间锁是运行时状态,自己设,不继承(README 第 4、5 条)
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO customers (code, legal_name, country) VALUES ('FIXT-C14', 'Fixture Customer 14', 'SG')
        RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES ('FIXT-M14', 'Fixture Material 14', 'battery_material', true, 'black_mass', 'end_of_life')
        RETURNING id INTO v_mat;

    -- ════════════════════════════════════════════════════════════════════════
    -- A. 同币种,但【结算日汇率 ≠ 单据入账汇率】
    --   单据:100 kg × USD 10 = USD 1,000,入账汇率 1.20 → amount_base 1,200
    --   收款:USD 1,000,结算日 tt_buy 1.30 → amount_base 1,300
    --   全额核销 ⇒ allocated_pay = 1,000(同币种不换算)
    --     新口径 = 1,000 − 1,000 = 0
    --     旧口径 = 1,300 − 1,200 = 100.00 ← 正是已实现汇兑,不是挂账
    -- ════════════════════════════════════════════════════════════════════════
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES ('USD', dA, 'tt_buy', 1.30), ('USD', dA, 'tt_sell', 1.30);

    INSERT INTO output_batches (material_id, code, quantity, remaining_qty, unit,
                                output_date, state, customer_id)
    VALUES (v_mat, 'FIXT-B14A', 100, 100, 'kg', dA, '库存中', v_cust) RETURNING id INTO v_batch;
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
                               currency, fx_rate, amount_base, sale_date)
    VALUES (v_batch, v_cust, 100, 10, 'USD', 1.20, 1200, dA) RETURNING id INTO v_sale;

    PERFORM record_payment('in', v_cust, 1000, 'USD', NULL, '1010', dA, NULL,
        jsonb_build_array(jsonb_build_object('sales_record_id', v_sale, 'amount_doc', 1000)));

    SELECT payment_id INTO v_pay FROM payment_allocations WHERE sales_record_id = v_sale;

    SELECT round(p.amount_ccy - sum(pa.allocated_pay), 2) INTO v_new
    FROM payments p JOIN payment_allocations pa ON pa.payment_id = p.id
    WHERE p.id = v_pay GROUP BY p.amount_ccy;
    IF v_new <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 14A 失败:全额核销后挂账余额应为 0(付款币种口径),实得 %', v_new;
    END IF;

    -- ② 旧口径必须不为 0,否则本用例分辨不出两种算法
    SELECT round(p.amount_base - sum(pa.allocated_base), 2) INTO v_old
    FROM payments p JOIN payment_allocations pa ON pa.payment_id = p.id
    WHERE p.id = v_pay GROUP BY p.amount_base;
    IF v_old = 0 THEN
        RAISE EXCEPTION 'FIXTURE 14A 失败:本用例没有制造出汇率差(旧口径也是 0),分辨不出两种算法 —— 检查 1.20 / 1.30 这组汇率是否被改过';
    END IF;
    IF v_old <> 100.00 THEN
        RAISE EXCEPTION 'FIXTURE 14A 失败:旧口径应为 100.00(= 1000×1.30 − 1000×1.20,即已实现汇兑),实得 %', v_old;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- B. 跨币种:USD 单据,拿本位币付
    --   单据:100 kg × USD 12 = USD 1,200,入账汇率 1.20
    --   收款:SGD 1,240(本位币,v_fx = 1);结算日 USD tt_buy = 1.24
    --   核销 USD 1,000 ⇒ 消耗 = 1000 × 1.24 / 1 = 1,240.00 = 整笔款
    --     新口径 = 1,240 − 1,240 = 0
    --     旧口径 = 1,240 − (1000 × 1.20) = 40.00
    -- ════════════════════════════════════════════════════════════════════════
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES ('USD', dB, 'tt_buy', 1.24), ('USD', dB, 'tt_sell', 1.24);

    INSERT INTO output_batches (material_id, code, quantity, remaining_qty, unit,
                                output_date, state, customer_id)
    VALUES (v_mat, 'FIXT-B14B', 100, 100, 'kg', dB, '库存中', v_cust) RETURNING id INTO v_batch;
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
                               currency, fx_rate, amount_base, sale_date)
    VALUES (v_batch, v_cust, 100, 12, 'USD', 1.20, 1440, dB) RETURNING id INTO v_sale;

    PERFORM record_payment('in', v_cust, 1240, 'SGD', NULL, '1000', dB, NULL,
        jsonb_build_array(jsonb_build_object('sales_record_id', v_sale, 'amount_doc', 1000)));

    SELECT payment_id INTO v_pay FROM payment_allocations WHERE sales_record_id = v_sale;

    SELECT round(p.amount_ccy - sum(pa.allocated_pay), 2) INTO v_new
    FROM payments p JOIN payment_allocations pa ON pa.payment_id = p.id
    WHERE p.id = v_pay GROUP BY p.amount_ccy;
    IF v_new <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 14B 失败:跨币种全额核销后挂账余额应为 0,实得 %', v_new;
    END IF;

    SELECT round(p.amount_base - sum(pa.allocated_base), 2) INTO v_old
    FROM payments p JOIN payment_allocations pa ON pa.payment_id = p.id
    WHERE p.id = v_pay GROUP BY p.amount_base;
    IF v_old <> 40.00 THEN
        RAISE EXCEPTION 'FIXTURE 14B 失败:旧口径应为 40.00(= 1240 − 1000×1.20),实得 %', v_old;
    END IF;

    -- ③ allocated_pay 的定义本身:同币种即 allocated_ccy,跨币种按结算日两率之比
    SELECT sum(allocated_pay) INTO v_new FROM payment_allocations WHERE payment_id = v_pay;
    IF v_new <> 1240.00 THEN
        RAISE EXCEPTION 'FIXTURE 14B 失败:消耗的付款额应为 1240.00 SGD(= 1000 USD × 1.24),实得 %', v_new;
    END IF;
END $$;
ROLLBACK;
