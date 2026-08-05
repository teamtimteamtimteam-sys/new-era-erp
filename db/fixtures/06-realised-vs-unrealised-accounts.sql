-- 06 已实现汇兑进 7100,重估进 7110 —— 两者永不串门
--
-- 为什么值得常设:这两个科目的分工是【结算时点认列】与【期末估值】的分界。
-- 串了之后两边都还是"汇兑损益",报表总额一分不差,只有科目错 —— 最不容易被看出来。
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid(); v_role uuid; v_cust uuid; v_mat uuid;
    v_batch uuid; v_sale uuid; d date := '2026-06-15'; m date := '2026-06-30';
    v_7100_settle int; v_7110_settle int; v_7100_reval int; v_7110_reval int;
    v_je uuid; v_pay jsonb; v_rev jsonb;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-06', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES ('USD', d, 'tt_buy', 1.30), ('USD', d, 'tt_sell', 1.30),
           ('USD', m, 'mid', 1.40);

    INSERT INTO customers (code, legal_name, country)
    VALUES ('FIXT-C6', 'Fixture Customer 6', 'SG') RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, category)
    VALUES ('FIXT-M6', 'Fixture Material 6', 'black_mass') RETURNING id INTO v_mat;
    INSERT INTO output_batches (material_id, code, quantity, remaining_qty, unit,
                                output_date, state, customer_id)
    VALUES (v_mat, 'FIXT-B6', 100, 100, 'kg', d, '库存中', v_cust) RETURNING id INTO v_batch;
    -- 入账汇率 1.20,结算日 1.30 → 结算必然产生【已实现】差异
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
                               currency, fx_rate, amount_base, sale_date)
    VALUES (v_batch, v_cust, 100, 10, 'USD', 1.20, 1200, d) RETURNING id INTO v_sale;

    -- 【只看自己造出来的那张分录】用返回的凭证号定位,不要 ORDER BY created_at DESC ——
    -- 那会捞到库里既有的分录,于是断言的是别人的数据(本 fixture 第一版就这么错过)。
    v_pay := record_payment('in', v_cust, 1000, 'USD', NULL, '1010', d, NULL,
        jsonb_build_array(jsonb_build_object('sales_record_id', v_sale, 'amount_doc', 1000)));

    SELECT je.id INTO v_je FROM journal_entries je WHERE je.code = v_pay->>'journal_code';
    SELECT count(*) FILTER (WHERE a.code = '7100'), count(*) FILTER (WHERE a.code = '7110')
      INTO v_7100_settle, v_7110_settle
    FROM journal_lines l JOIN accounts a ON a.id = l.account_id WHERE l.entry_id = v_je;

    IF v_7100_settle = 0 THEN
        RAISE EXCEPTION 'FIXTURE 06 失败:入账 1.20、结算 1.30,结算分录里应有 7100(已实现)行,实得 0';
    END IF;
    IF v_7110_settle <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 06 失败:结算分录里出现了 7110(未实现)—— 期末估值的科目串到结算时点了';
    END IF;

    -- 期末重估:另造一笔【未结】外币余额,确保有东西可重估
    PERFORM post_journal_entry(m, 'fixture 06 open balance', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code','1100','side','debit','currency','USD',
                           'amount_ccy',500,'fx_rate',1.20),
        jsonb_build_object('account_code','4000','side','credit','currency','USD',
                           'amount_ccy',500,'fx_rate',1.20)));
    v_rev := revalue_foreign_balances(m);
    IF v_rev->>'journal_code' IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 06 无法进行:重估没有产生任何分录 —— 断言前提不成立';
    END IF;
    SELECT je.id INTO v_je FROM journal_entries je WHERE je.code = v_rev->>'journal_code';
    SELECT count(*) FILTER (WHERE a.code = '7100'), count(*) FILTER (WHERE a.code = '7110')
      INTO v_7100_reval, v_7110_reval
    FROM journal_lines l JOIN accounts a ON a.id = l.account_id WHERE l.entry_id = v_je;

    -- 【断言"不串门",不断言"一定有 7110"】各科目的调整额可能【正好抵消】,
    -- 那时分录自平、不需要 7110 这条平衡行 —— 本 fixture 第一版就误把它当成必然,
    -- 结果拿到 1010 +100 / 1100 −100 的自平分录,断言失败而代码是对的。
    -- 真正的不变量是:重估分录里【不许出现 7100】,且除货币性科目外的平衡行
    -- 【只能是 7110】。
    IF v_7100_reval <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 06 失败:重估分录里出现了 7100(已实现)—— 结算时点的科目串到期末了';
    END IF;
    IF EXISTS (
        SELECT 1 FROM journal_lines l JOIN accounts a ON a.id = l.account_id
        WHERE l.entry_id = v_je AND NOT a.is_monetary AND a.code <> '7110'
    ) THEN
        RAISE EXCEPTION 'FIXTURE 06 失败:重估分录里出现了 7110 以外的非货币性科目 —— 平衡行只能进 7110';
    END IF;
END $$;
ROLLBACK;
