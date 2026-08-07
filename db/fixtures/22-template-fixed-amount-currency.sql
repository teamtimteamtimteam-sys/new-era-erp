-- 22 付款条款模板的定额:必须自带币种,套到别的币种的单上即拒(不换算)
--
-- 为什么值得常设(FIN-29):模板不属于任何单据,所以它上面的定额在被套用之前
-- 【没有币种】。而 apply_payment_term_template 是【逐字照抄】—— 不换算、不查汇率
-- —— 于是"定额 10,000"落到 USD 单和 SGD 单上都写着 10,000,两边看起来都对,
-- 实际差着一个汇率。比"换错汇率"更安静的一类错。四臂:
--   A 同币种:金额【原样】抄过去(10,000 还是 10,000),日期照常按 days_offset 算。
--   B 不同币种:点名拒(TEMPLATE_CURRENCY_MISMATCH),【且原有计划一行未动】——
--     这个函数的语义是"替换整份计划",所以校验必须发生在 DELETE 之前;
--     本臂先给 PO 铺一份自有计划,再断言被拒之后它还在。
--   C 只有比例的模板:不需要币种,套到任何币种的单上都不该有意见 ——
--     没有这一臂,"把币种做成必填"也能过 A 和 B,而那会逼人给纯比例模板瞎填一个。
--   D 存量/绕过:有定额腿却没声明币种 —— 两道关各拒一次。
--     * 建的时候:守卫触发器 TEMPLATE_CURRENCY_REQUIRED;
--     * 万一有一行绕过守卫落了地(守卫之前建的行 —— 本臂显式关掉触发器造一行,
--       那是这个状态唯一的到达方式):套用时 TEMPLATE_CURRENCY_UNDECLARED。
--       【不猜、不照抄】—— 照抄等于替双方认下一个没人谈过的币种。
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid(); v_role uuid;
    v_sup uuid; v_mat uuid; v_today date := CURRENT_DATE;
    v_tpl_usd uuid; v_tpl_pct uuid; v_tpl_bad uuid;
    v_po_usd jsonb; v_po_sgd jsonb; v_po_usd_id uuid; v_po_sgd_id uuid;
    v_res jsonb; v_amt numeric; v_due date; v_n integer; v_lbl text;
    v_msg text; v_ok boolean;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-22', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);
    -- 前提显式设定(README 第 5 条)
    UPDATE finance_settings SET locked_before = NULL;
    DELETE FROM fx_rates WHERE currency = 'USD' AND rate_date = v_today AND rate_type = 'tt_sell';
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES ('USD', v_today, 'tt_sell', 1.26);

    INSERT INTO suppliers (code, legal_name, country) VALUES ('FIXT-S22', 'Fixture Supplier 22', 'SG')
        RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, category) VALUES ('FIXT-M22', 'Fixture Material 22', 'black_mass')
        RETURNING id INTO v_mat;

    -- 两张单:一张 USD、一张 SGD(本位币,无需牌价)
    v_po_usd := create_purchase_order(v_sup, v_today, NULL, 'USD', NULL, NULL, NULL, NULL,
        jsonb_build_array(jsonb_build_object('line_no', 1, 'material_id', v_mat,
            'quantity', 100, 'unit', 'kg', 'estimated_unit_price', 5)), NULL);
    v_po_usd_id := (v_po_usd->>'purchase_order_id')::uuid;
    v_po_sgd := create_purchase_order(v_sup, v_today, NULL, 'SGD', NULL, NULL, NULL, NULL,
        jsonb_build_array(jsonb_build_object('line_no', 1, 'material_id', v_mat,
            'quantity', 100, 'unit', 'kg', 'estimated_unit_price', 5)), NULL);
    v_po_sgd_id := (v_po_sgd->>'purchase_order_id')::uuid;

    -- ════════ A. 同币种:定额原样抄过去 ══════════════════════════════════════
    INSERT INTO payment_term_templates (name, is_active, currency)
    VALUES ('FIXT-22 USD deposit', true, 'USD') RETURNING id INTO v_tpl_usd;
    INSERT INTO payment_term_template_lines (template_id, seq, label, percentage,
                                             fixed_amount_ccy, trigger_event, days_offset)
    VALUES (v_tpl_usd, 1, 'Deposit', NULL, 10000, 'fixed_date', 30),
           (v_tpl_usd, 2, 'Balance', 40, NULL, 'on_arrival', NULL);

    v_res := apply_payment_term_template(v_po_usd_id, v_tpl_usd);
    SELECT fixed_amount_ccy, due_date, label INTO v_amt, v_due, v_lbl
    FROM purchase_order_payment_terms WHERE purchase_order_id = v_po_usd_id AND seq = 1;
    IF v_amt IS DISTINCT FROM 10000 THEN
        RAISE EXCEPTION 'FIXTURE 22A 失败:同币种套用应【原样】抄下 10000,实得 % —— 定额被折算了',
            COALESCE(v_amt::text, 'NULL');
    END IF;
    IF v_due IS DISTINCT FROM (v_today + 30) THEN
        RAISE EXCEPTION 'FIXTURE 22A 失败:due_date 应为下单日 + 30 = %,实得 %', v_today + 30, v_due;
    END IF;
    IF (v_res->>'fixed_leg_count')::integer <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 22A 失败:返回值应报 1 条定额腿,实得 %', v_res->>'fixed_leg_count';
    END IF;

    -- ════════ B. 不同币种:点名拒,且原有计划一行未动 ════════════════════════
    -- 先给 SGD 单铺一份【自有】计划:被拒之后它必须还在
    INSERT INTO purchase_order_payment_terms (purchase_order_id, seq, label, percentage,
                                              trigger_event)
    VALUES (v_po_sgd_id, 1, 'Own plan, untouched', 100, 'on_order');

    v_ok := false; v_msg := NULL;
    BEGIN
        PERFORM apply_payment_term_template(v_po_sgd_id, v_tpl_usd);
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'TEMPLATE_CURRENCY_MISMATCH%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 22B 失败:USD 模板套到 SGD 单上应 TEMPLATE_CURRENCY_MISMATCH 点名拒,实得:%',
            COALESCE(v_msg, '(没有报错 —— 定额多半被照抄进了别的币种)');
    END IF;
    -- 【拒必须是真的什么都没做】—— 校验在 DELETE 之前,不是靠回滚兜
    SELECT count(*), max(label) INTO v_n, v_lbl
    FROM purchase_order_payment_terms WHERE purchase_order_id = v_po_sgd_id;
    IF v_n <> 1 OR v_lbl IS DISTINCT FROM 'Own plan, untouched' THEN
        RAISE EXCEPTION 'FIXTURE 22B 失败:被拒之后原计划应一行未动(1 行 "Own plan, untouched"),实得 % 行 / %',
            v_n, COALESCE(v_lbl, 'NULL');
    END IF;

    -- ════════ C. 只有比例的模板:任何币种都能套,不需要币种 ══════════════════
    -- 没有这一臂,"币种一律必填"也能过 A、B —— 而那会逼人给纯比例模板瞎填一个,
    -- 瞎填的字段迟早被当真。
    INSERT INTO payment_term_templates (name, is_active) VALUES ('FIXT-22 pct only', true)
        RETURNING id INTO v_tpl_pct;
    -- 【自己报自己的名】纯比例模板【建得起来】本身就是本臂的断言。裸着写,
    -- 守卫若被改成"一律必填",这里抛的是守卫的错误码,读的人还得回头找是哪一臂。
    BEGIN
        INSERT INTO payment_term_template_lines (template_id, seq, label, percentage,
                                                 fixed_amount_ccy, trigger_event)
        VALUES (v_tpl_pct, 1, 'On order', 30, NULL, 'on_order'),
               (v_tpl_pct, 2, 'On arrival', 70, NULL, 'on_arrival');
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        RAISE EXCEPTION 'FIXTURE 22C 失败:纯比例模板不该需要币种,建行却被拒:% —— 币种被做成了无条件必填,而百分比对任何币种都成立', v_msg;
    END;

    PERFORM apply_payment_term_template(v_po_sgd_id, v_tpl_pct);
    PERFORM apply_payment_term_template(v_po_usd_id, v_tpl_pct);
    SELECT count(*) INTO v_n FROM purchase_order_payment_terms
    WHERE purchase_order_id IN (v_po_sgd_id, v_po_usd_id) AND percentage IS NOT NULL;
    IF v_n <> 4 THEN
        RAISE EXCEPTION 'FIXTURE 22C 失败:纯比例模板应能套到两种币种的单上(共 4 行),实得 % 行', v_n;
    END IF;
    IF (SELECT currency FROM payment_term_templates WHERE id = v_tpl_pct) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 22C 失败:纯比例模板不该被逼着声明币种';
    END IF;

    -- ════════ D. 有定额腿却没声明币种:建的时候拒,套的时候也拒 ═══════════════
    INSERT INTO payment_term_templates (name, is_active) VALUES ('FIXT-22 undeclared', true)
        RETURNING id INTO v_tpl_bad;
    v_ok := false; v_msg := NULL;
    BEGIN
        INSERT INTO payment_term_template_lines (template_id, seq, label, percentage,
                                                 fixed_amount_ccy, trigger_event)
        VALUES (v_tpl_bad, 1, 'Deposit', NULL, 5000, 'on_order');
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'TEMPLATE_CURRENCY_REQUIRED%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 22D 失败:未声明币种就加定额腿应 TEMPLATE_CURRENCY_REQUIRED 拒,实得:%',
            COALESCE(v_msg, '(插进去了)');
    END IF;

    -- 守卫【之前】建出来的行长什么样:显式关掉触发器造一行 —— 这是那个状态
    -- 唯一的到达方式(今天全库 0 条定额腿,所以真实存量为空)。整段回滚。
    ALTER TABLE payment_term_template_lines DISABLE TRIGGER trg_ptt_lines_fixed_needs_currency;
    INSERT INTO payment_term_template_lines (template_id, seq, label, percentage,
                                             fixed_amount_ccy, trigger_event)
    VALUES (v_tpl_bad, 1, 'Legacy deposit', NULL, 5000, 'on_order');
    ALTER TABLE payment_term_template_lines ENABLE TRIGGER trg_ptt_lines_fixed_needs_currency;

    v_ok := false; v_msg := NULL;
    BEGIN
        PERFORM apply_payment_term_template(v_po_usd_id, v_tpl_bad);
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'TEMPLATE_CURRENCY_UNDECLARED%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 22D 失败:未声明币种的定额腿套用时应 TEMPLATE_CURRENCY_UNDECLARED 拒(不猜、不照抄),实得:%',
            COALESCE(v_msg, '(照抄了 —— 等于替双方认下一个没人谈过的币种)');
    END IF;
    -- 被拒的那张单的计划仍是 C 臂留下的两行比例,没有被这次调用清掉
    SELECT count(*) INTO v_n FROM purchase_order_payment_terms WHERE purchase_order_id = v_po_usd_id;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 22D 失败:被拒之后 USD 单的计划应仍是 2 行,实得 %', v_n;
    END IF;
END $$;
ROLLBACK;
