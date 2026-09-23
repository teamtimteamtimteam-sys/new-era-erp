-- 208 建单时带价的收货,与之后再定价的收货【过同一条账】(INB-PAY-1,2026-09-23)
--
-- 【这份 fixture 自带全部数据】一家供货商、一个物料、它自己要用的牌价
-- (README 第 4 条:不借线上的 fx_rates)。定价按 CURRENT_DATE 入账、按 CURRENT_DATE
-- 的 tt_sell 估值 —— 那是 reprice_inbound_batch 的既定行为(Tim Q5「记于定价日」),
-- 所以本 fixture 【自己】把今天要用的牌价摆好、把今天不该有的牌价撤掉,并把
-- locked_before 清空,不继承任何随时间变的状态。
--
-- 【被钉的规矩】建单带价 = 建单 + 定价,同一份实现。此前 create_inbound_batch 把价格
-- 直写进行里:没有 purchase 分录、没有 price_history;之后再定价只过【价差】,
-- 于是旧价 × 数量永远不进 2000,而 ap_open_items / apply_prepayment 按
-- 数量 × 单价认欠款 —— 明细账与总账各说各话。
--
-- 【臂】
-- A 本位币建单带价:一条 purchase 分录(Dr 1200 = Cr 2000 = 数量 × 价)、一行
--   price_history(旧价 NULL → 新价)。
-- B 先建不带价、再经 set_inbound_unit_price 定同一个价:与 A 【逐项相同】——
--   分录行(科目 / 借 / 贷)、price_history 的 old / new / 币种 / 原币价 / 汇率。
--   ★ 这一臂是整份 fixture 的主张:两条路过的是同一条账。
-- C 对 A 那张再定价(150 → 160):第二条分录恰好 Cr 2000 = 数量 × 10,
--   而这张批次在 2000 上的净额 = 数量 × 160 = ap_open_items 的 doc_value 那个算式。
--   ★ 故障注入(把建单改回直写价格)时,A 与 B 都会红,而 C 会读到只剩价差 ——
--   总账比单据少 数量 × 150。
-- D 外币建单带价:按今天的 tt_sell 估值,price_history 记原币与汇率,
--   与之后再定价逐项相同(同 B 的比法)。
-- E 拒绝【按名】,且整笔建单回滚(供应商名下的批次数不变):
--   价格 0 / 负数 → PRICE_INVALID;带价不给币种 → CURRENCY_INVALID;
--   外币今天没有牌价 → FX_RATE_MISSING。
-- F 不带价建单:没有分录、没有 price_history、pricing 返回 null —— 行为不变。
--
-- 【SET CONSTRAINTS ALL IMMEDIATE】journal_lines 的借贷平衡是 DEFERRABLE 的
-- 约束触发器;这里 ROLLBACK,所以在末尾强制校验一次(fixture 104 同款)。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid;
    v_sup uuid; v_mat uuid; v_base text; v_ccy text;
    v_fx numeric;
    b_a uuid; b_b uuid; b_d uuid; b_d2 uuid; b_f uuid;
    v_res jsonb;
    v_n int; v_n0 int; v_msg text;
    v_lines_a text; v_lines_b text; v_ph_a text; v_ph_b text;
    v_net numeric; v_doc numeric;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    -- 一种外币(非本位币的任意一种;CHECK 只允许三种)
    SELECT code INTO v_ccy FROM currencies WHERE NOT is_base ORDER BY code LIMIT 1;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-208', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- 今天的牌价由本 fixture 自己决定:撤掉所有外币近 10 天的 tt_sell,
    -- 再给 v_ccy 摆一条今天的。E 臂要的"今天没有牌价"用另一种外币。
    UPDATE fx_rates SET deleted_at = now()
    WHERE currency <> v_base AND rate_type = 'tt_sell' AND deleted_at IS NULL
      AND rate_date BETWEEN CURRENT_DATE - 10 AND CURRENT_DATE;
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES (v_ccy, CURRENT_DATE, 'tt_sell', 1.25);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX208-S', 'fixture 208 supplier', 'SG', 'active', 'goods_supplier')
    RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX208-M', 'fixture 208 material', 'battery_material', true, 'black_mass', 'end_of_life')
    RETURNING id INTO v_mat;

    -- ══════════ A · 本位币建单带价 ══════════════════════════════════════════
    v_res := create_inbound_batch(v_mat, v_sup, 14, 'kg', DATE '2027-06-01', '待加工',
        150, 'fixture 208 A', p_source_reason_code => 'other',
        p_source_reason_note => 'fixture 208 自带数据', p_currency => v_base);
    b_a := (v_res->>'batch_id')::uuid;
    IF v_res->'pricing'->>'journal_code' IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 208A 失败:建单带价应当返回定价分解与分录号,实得 %', v_res->'pricing';
    END IF;
    SELECT count(*) INTO v_n FROM journal_entries
    WHERE source_type = 'purchase' AND source_id = b_a AND status = 'posted';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 208A 失败:建单带价应当恰好一条 purchase 分录,实得 % —— 为 0 就是 INB-PAY-1 那个缺陷:价格落了,应付没落', v_n;
    END IF;
    SELECT COALESCE(sum(jl.credit - jl.debit), 0) INTO v_net
    FROM journal_lines jl JOIN journal_entries e ON e.id = jl.entry_id
    JOIN accounts a ON a.id = jl.account_id
    WHERE a.code = '2000' AND e.source_type = 'purchase' AND e.source_id = b_a;
    IF v_net <> 2100.00 THEN   -- 14 × 150
        RAISE EXCEPTION 'FIXTURE 208A 失败:2000 应当贷 14 × 150 = 2100.00,实得 %', v_net;
    END IF;
    SELECT count(*) INTO v_n FROM price_history
    WHERE inbound_batch_id = b_a AND old_unit_price IS NULL AND new_unit_price = 150;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 208A 失败:建单带价应当留一行 price_history(NULL → 150),实得 % 行', v_n;
    END IF;

    -- ══════════ B · 先建不带价、再定同一个价 —— 与 A 逐项相同 ═══════════════
    v_res := create_inbound_batch(v_mat, v_sup, 14, 'kg', DATE '2027-06-01', '待加工',
        NULL, 'fixture 208 B', p_source_reason_code => 'other',
        p_source_reason_note => 'fixture 208 自带数据', p_currency => v_base);
    b_b := (v_res->>'batch_id')::uuid;
    PERFORM set_inbound_unit_price(b_b, 150, v_base);

    SELECT string_agg(a.code || ':' || jl.debit || ':' || jl.credit, ',' ORDER BY a.code, jl.debit, jl.credit)
    INTO v_lines_a
    FROM journal_lines jl JOIN journal_entries e ON e.id = jl.entry_id JOIN accounts a ON a.id = jl.account_id
    WHERE e.source_type = 'purchase' AND e.source_id = b_a;
    SELECT string_agg(a.code || ':' || jl.debit || ':' || jl.credit, ',' ORDER BY a.code, jl.debit, jl.credit)
    INTO v_lines_b
    FROM journal_lines jl JOIN journal_entries e ON e.id = jl.entry_id JOIN accounts a ON a.id = jl.account_id
    WHERE e.source_type = 'purchase' AND e.source_id = b_b;
    IF v_lines_a IS NULL OR v_lines_a IS DISTINCT FROM v_lines_b THEN
        RAISE EXCEPTION 'FIXTURE 208B 失败:建单带价与之后再定价应当过【同一条账】—— 建单带价 [%] / 之后再定价 [%]', v_lines_a, v_lines_b;
    END IF;
    SELECT string_agg(concat_ws(':', old_unit_price, new_unit_price, currency, original_price, fx_rate, rate_type), ',')
    INTO v_ph_a FROM price_history WHERE inbound_batch_id = b_a;
    SELECT string_agg(concat_ws(':', old_unit_price, new_unit_price, currency, original_price, fx_rate, rate_type), ',')
    INTO v_ph_b FROM price_history WHERE inbound_batch_id = b_b;
    IF v_ph_a IS NULL OR v_ph_a IS DISTINCT FROM v_ph_b THEN
        RAISE EXCEPTION 'FIXTURE 208B 失败:两条路的价格史应当逐项相同 —— 建单带价 [%] / 之后再定价 [%]', v_ph_a, v_ph_b;
    END IF;

    -- ══════════ C · 对建单带价的那张再定价:过的是【完整的】价差 ═══════════
    PERFORM set_inbound_unit_price(b_a, 160, v_base);
    SELECT COALESCE(sum(jl.credit - jl.debit), 0) INTO v_net
    FROM journal_lines jl JOIN journal_entries e ON e.id = jl.entry_id
    JOIN accounts a ON a.id = jl.account_id
    WHERE a.code = '2000' AND e.source_type = 'purchase' AND e.source_id = b_a;
    SELECT round(quantity * unit_price, 2) INTO v_doc FROM inbound_batches WHERE id = b_a;
    IF v_net <> v_doc OR v_doc <> 2240.00 THEN   -- 14 × 160
        RAISE EXCEPTION 'FIXTURE 208C 失败:再定价之后,这张批次在 2000 上的净额应当等于 数量 × 单价(ap_open_items 的 doc_value 算式)= 2240.00;总账 %,单据 % —— 若总账只有 140.00,说明建单那一段 14 × 150 从来没进过总账', v_net, v_doc;
    END IF;

    -- ══════════ D · 外币建单带价,与之后再定价逐项相同 ═════════════════════
    SELECT rate INTO v_fx FROM fx_rate_asof(v_ccy, CURRENT_DATE, 'tt_sell');
    IF v_fx IS DISTINCT FROM 1.25 THEN
        RAISE EXCEPTION 'FIXTURE 208D 前提失败:本 fixture 摆的今天 % tt_sell 应当是 1.25,实得 %', v_ccy, v_fx;
    END IF;
    v_res := create_inbound_batch(v_mat, v_sup, 10, 'kg', DATE '2027-06-01', '待加工',
        4, 'fixture 208 D', p_source_reason_code => 'other',
        p_source_reason_note => 'fixture 208 自带数据', p_currency => v_ccy);
    b_d := (v_res->>'batch_id')::uuid;
    v_res := create_inbound_batch(v_mat, v_sup, 10, 'kg', DATE '2027-06-01', '待加工',
        NULL, 'fixture 208 D2', p_source_reason_code => 'other',
        p_source_reason_note => 'fixture 208 自带数据', p_currency => v_ccy);
    b_d2 := (v_res->>'batch_id')::uuid;
    PERFORM set_inbound_unit_price(b_d2, 4, v_ccy);

    IF (SELECT unit_price FROM inbound_batches WHERE id = b_d) <> 5.0000 THEN   -- 4 × 1.25
        RAISE EXCEPTION 'FIXTURE 208D 失败:外币 4 @1.25 应当落本位单价 5.0000,实得 %',
            (SELECT unit_price FROM inbound_batches WHERE id = b_d);
    END IF;
    SELECT string_agg(a.code || ':' || jl.debit || ':' || jl.credit, ',' ORDER BY a.code, jl.debit, jl.credit)
    INTO v_lines_a
    FROM journal_lines jl JOIN journal_entries e ON e.id = jl.entry_id JOIN accounts a ON a.id = jl.account_id
    WHERE e.source_type = 'purchase' AND e.source_id = b_d;
    SELECT string_agg(a.code || ':' || jl.debit || ':' || jl.credit, ',' ORDER BY a.code, jl.debit, jl.credit)
    INTO v_lines_b
    FROM journal_lines jl JOIN journal_entries e ON e.id = jl.entry_id JOIN accounts a ON a.id = jl.account_id
    WHERE e.source_type = 'purchase' AND e.source_id = b_d2;
    IF v_lines_a IS NULL OR v_lines_a IS DISTINCT FROM v_lines_b THEN
        RAISE EXCEPTION 'FIXTURE 208D 失败:外币建单带价与之后再定价应当过同一条账 —— [%] / [%]', v_lines_a, v_lines_b;
    END IF;
    SELECT string_agg(concat_ws(':', old_unit_price, new_unit_price, currency, original_price, fx_rate, rate_as_of, rate_type), ',')
    INTO v_ph_a FROM price_history WHERE inbound_batch_id = b_d;
    SELECT string_agg(concat_ws(':', old_unit_price, new_unit_price, currency, original_price, fx_rate, rate_as_of, rate_type), ',')
    INTO v_ph_b FROM price_history WHERE inbound_batch_id = b_d2;
    IF v_ph_a IS NULL OR v_ph_a IS DISTINCT FROM v_ph_b THEN
        RAISE EXCEPTION 'FIXTURE 208D 失败:外币两条路的价格史应当逐项相同 —— [%] / [%]', v_ph_a, v_ph_b;
    END IF;

    -- ══════════ E · 拒绝按名,整笔回滚 ═══════════════════════════════════════
    SELECT count(*) INTO v_n0 FROM inbound_batches WHERE supplier_id = v_sup;

    BEGIN
        PERFORM create_inbound_batch(v_mat, v_sup, 5, 'kg', DATE '2027-06-01', '待加工', 0, NULL,
            p_source_reason_code => 'other', p_source_reason_note => 'fixture 208 自带数据', p_currency => v_base);
        RAISE EXCEPTION 'FIXTURE 208E 失败:价格 0 应当按名拒 PRICE_INVALID,却建成了';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'PRICE_INVALID%' THEN
            RAISE EXCEPTION 'FIXTURE 208E 失败:价格 0 应当按名拒 PRICE_INVALID,实得:%', v_msg;
        END IF;
    END;

    BEGIN
        PERFORM create_inbound_batch(v_mat, v_sup, 5, 'kg', DATE '2027-06-01', '待加工', -5, NULL,
            p_source_reason_code => 'other', p_source_reason_note => 'fixture 208 自带数据', p_currency => v_base);
        RAISE EXCEPTION 'FIXTURE 208E 失败:负价应当按名拒 PRICE_INVALID,却建成了';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'PRICE_INVALID%' THEN
            RAISE EXCEPTION 'FIXTURE 208E 失败:负价应当按名拒 PRICE_INVALID,实得:%', v_msg;
        END IF;
    END;

    BEGIN
        PERFORM create_inbound_batch(v_mat, v_sup, 5, 'kg', DATE '2027-06-01', '待加工', 10, NULL,
            p_source_reason_code => 'other', p_source_reason_note => 'fixture 208 自带数据');
        RAISE EXCEPTION 'FIXTURE 208E 失败:带价不给币种应当按名拒 CURRENCY_INVALID,却建成了';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'CURRENCY_INVALID%' THEN
            RAISE EXCEPTION 'FIXTURE 208E 失败:带价不给币种应当按名拒 CURRENCY_INVALID,实得:%', v_msg;
        END IF;
    END;

    BEGIN
        -- 另一种外币:上面已撤掉它近 10 天的 tt_sell,今天一定没有牌价
        PERFORM create_inbound_batch(v_mat, v_sup, 5, 'kg', DATE '2027-06-01', '待加工', 10, NULL,
            p_source_reason_code => 'other', p_source_reason_note => 'fixture 208 自带数据',
            p_currency => (SELECT code FROM currencies WHERE NOT is_base AND code <> v_ccy ORDER BY code LIMIT 1));
        RAISE EXCEPTION 'FIXTURE 208E 失败:今天没有牌价的外币应当按名拒 FX_RATE_MISSING,却建成了';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'FX_RATE_MISSING%' THEN
            RAISE EXCEPTION 'FIXTURE 208E 失败:缺牌价应当按名拒 FX_RATE_MISSING,实得:%', v_msg;
        END IF;
    END;

    SELECT count(*) INTO v_n FROM inbound_batches WHERE supplier_id = v_sup;
    IF v_n <> v_n0 THEN
        RAISE EXCEPTION 'FIXTURE 208E 失败:被拒的建单应当整笔回滚,供应商名下批次 % → %', v_n0, v_n;
    END IF;

    -- ══════════ F · 不带价建单:行为不变 ════════════════════════════════════
    v_res := create_inbound_batch(v_mat, v_sup, 3, 'kg', DATE '2027-06-01', '待加工',
        NULL, 'fixture 208 F', p_source_reason_code => 'other',
        p_source_reason_note => 'fixture 208 自带数据', p_currency => v_base);
    b_f := (v_res->>'batch_id')::uuid;
    IF jsonb_typeof(v_res->'pricing') <> 'null'
       OR EXISTS (SELECT 1 FROM journal_entries WHERE source_type = 'purchase' AND source_id = b_f)
       OR EXISTS (SELECT 1 FROM price_history WHERE inbound_batch_id = b_f)
       OR (SELECT unit_price FROM inbound_batches WHERE id = b_f) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 208F 失败:不带价建单不应当过账、不应当留价格史,pricing 应为 null(实得 %)', v_res->'pricing';
    END IF;

    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE NOTICE 'FIXTURE 208 通过:建单带价与之后再定价过同一条账(本位币与外币),再定价过完整价差,拒绝按名且整笔回滚';
END;
$$;
ROLLBACK;
