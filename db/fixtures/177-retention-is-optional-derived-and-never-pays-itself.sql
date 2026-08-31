-- 177 质保金:可选、推导、而且【永远不会自己把钱付出去】
--
-- 【这份 fixture 钉的四件事,正是切次收尾点名的四条】
-- A 【没有质保金】与【0% 质保金】不是同一件事,而且第二件【存不进去】。
--   absence 是结构性的:没有质保金 = 没有那一行。0% 撞 CHECK,不是撞一条规矩。
-- B 到期【提示】,不【付款】。到期只让状态变成 awaiting_confirmation,
--   没有任何应付因此成立;放款只能由人经 release_purchase_order_retention 确认。
-- C ★【锚一动,到期日跟着动】★ 到期日是【算】出来的,不是存下来的。
--   把验收日推后三个月,到期日必须跟着推后三个月 —— 断言的是【差值】,
--   不是两个字面日期。一份把到期日存成列的实现在这一臂上红。
-- D 部分扣留:扣了多少、为什么扣,都记得下来;而扣了不说理由要被拒。
--
-- 【另外三臂,各堵一条歧路】
-- E 质保金只能挂在设备行上(材料行没有验收,也就没有可起算的锚)。
-- F 锚只能是一个【记得住日期】的事件 —— training_complete 没有日期,拒。
-- G 没验收就没有起算点:clock_not_started 不是"还没到期",放款要拒得不一样。
--
-- 【为什么 C 断言差值而不是字面日期】断言 '2028-04-15' 这种字面量,会在有人
-- 改了 fixture 里那个起始日的时候一起过期,而读的人分不清是回归还是过期
-- (README 第 1 条)。差值是不变量:锚 +3 个月 → 到期 +3 个月。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid;
    v_sup uuid; v_mat uuid; v_ccy text; v_res jsonb;
    v_asset_a uuid; v_asset_b uuid;
    po_a uuid; po_b uuid; po_mat uuid;
    line_a uuid; line_b uuid; line_mat uuid;
    ret_a uuid;
    v_msg text; v_denied boolean; v_n int;
    v_state text; v_mat_date date; v_mat_date2 date; v_amt numeric;
    v_rel numeric; v_wh numeric; v_reason text; v_by uuid;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-175', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, default_tax_code)
    VALUES ('ZZFIX177-S', 'fixture 177 supplier', 'SG', 'active', 'goods_supplier', 'TX')
    RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX177-M', 'fixture 177 material', 'battery_material', true, 'black_mass', 'end_of_life')
    RETURNING id INTO v_mat;

    -- 两台机器:A 有质保金,B 没有。**它们的区别必须是结构性的。**
    v_res := record_expense(DATE '2025-01-05', '1500', 400000, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'fixture 177 machine A',
        jsonb_build_object('description', 'machine A', 'useful_life_months', 120), NULL);
    SELECT id INTO v_asset_a FROM fixed_assets WHERE expense_id = (v_res->>'expense_id')::uuid;
    v_res := record_expense(DATE '2025-01-06', '1500', 200000, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'fixture 177 machine B',
        jsonb_build_object('description', 'machine B', 'useful_life_months', 120), NULL);
    SELECT id INTO v_asset_b FROM fixed_assets WHERE expense_id = (v_res->>'expense_id')::uuid;
    IF v_asset_a IS NULL OR v_asset_b IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 177 前提失败:资产卡没建出来';
    END IF;

    v_res := create_purchase_order(v_sup, DATE '2025-01-10', DATE '2025-04-01', v_ccy, NULL,
        NULL, NULL, 'fixture 177 PO A (with retention)',
        jsonb_build_array(jsonb_build_object('asset_id', v_asset_a, 'estimated_unit_price', 400000)));
    po_a := (v_res->>'purchase_order_id')::uuid;
    SELECT id INTO line_a FROM purchase_order_lines WHERE purchase_order_id = po_a;

    v_res := create_purchase_order(v_sup, DATE '2025-01-11', DATE '2025-04-01', v_ccy, NULL,
        NULL, NULL, 'fixture 177 PO B (no retention)',
        jsonb_build_array(jsonb_build_object('asset_id', v_asset_b, 'estimated_unit_price', 200000)));
    po_b := (v_res->>'purchase_order_id')::uuid;
    SELECT id INTO line_b FROM purchase_order_lines WHERE purchase_order_id = po_b;

    -- ══════════ A · "没有" 与 "0%" ══════════════════════════════════════════
    -- 【0% 存不进去】—— 这一臂断言的是 absence 的【结构性】,不是一条规矩。
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO purchase_order_line_retentions (purchase_order_line_id, percentage)
        VALUES (line_b, 0);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 177A 失败:0%% 的质保金行【应当存不进去】—— 它存进去了,于是"0%% 质保金"与"没有质保金"从此可以长得一样';
    END IF;

    -- 10% 质保金挂到 A 上;B 一行都不加。
    INSERT INTO purchase_order_line_retentions (purchase_order_line_id, percentage, retention_months)
    VALUES (line_a, 10, 12) RETURNING id INTO ret_a;

    -- 两者的区别是【有没有行】,不是一个数的大小。
    SELECT count(*) INTO v_n FROM purchase_order_line_retentions WHERE purchase_order_line_id = line_a;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 177A 失败:A 应当有 1 行质保金,实得 %', v_n; END IF;
    SELECT count(*) INTO v_n FROM purchase_order_line_retentions WHERE purchase_order_line_id = line_b;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 177A 失败:B 应当【一行都没有】,实得 %', v_n; END IF;
    SELECT count(*) INTO v_n FROM purchase_order_retention_status WHERE purchase_order_id = po_b;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 177A 失败:没有质保金的单在状态视图里应当【不出现】,实得 % 行', v_n;
    END IF;
    -- 默认 12 个月,而且可改(下面 C 臂会改它)
    SELECT retention_months INTO v_n FROM purchase_order_line_retentions WHERE id = ret_a;
    IF v_n <> 12 THEN RAISE EXCEPTION 'FIXTURE 177A 失败:默认应当是 12 个月,实得 %', v_n; END IF;

    -- ══════════ G · 没验收 = 时钟没起算(不是"还没到期")══════════════════════
    SELECT retention_state, maturity_date INTO v_state, v_mat_date
    FROM purchase_order_retention_status WHERE retention_id = ret_a;
    IF v_state <> 'clock_not_started' THEN
        RAISE EXCEPTION 'FIXTURE 177G 失败:还没验收时状态应当是 clock_not_started,实得 %', v_state;
    END IF;
    IF v_mat_date IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 177G 失败:没有锚的时候到期日应当是 NULL(不许编一个),实得 %', v_mat_date;
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM release_purchase_order_retention(ret_a, 40000, 0, NULL);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('RETENTION_CLOCK_NOT_STARTED' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 177G 失败:没验收就放款应当按名拒 RETENTION_CLOCK_NOT_STARTED,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(放了)');
    END IF;

    -- ══════════ C · 锚一动,到期日跟着动 ════════════════════════════════════
    -- 【验收日必须由人明确填写,不从任何东西默认出来】
    PERFORM set_asset_acceptance(v_asset_a, (CURRENT_DATE - INTERVAL '18 months')::date);
    SELECT maturity_date INTO v_mat_date
    FROM purchase_order_retention_status WHERE retention_id = ret_a;
    IF v_mat_date IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 177C 失败:填了验收日之后到期日应当算得出来';
    END IF;

    -- 把验收推后三个月 —— 到期日必须【正好】跟着推后三个月。
    PERFORM set_asset_acceptance(v_asset_a, (CURRENT_DATE - INTERVAL '15 months')::date);
    SELECT maturity_date INTO v_mat_date2
    FROM purchase_order_retention_status WHERE retention_id = ret_a;
    IF v_mat_date2 IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 177C 失败:改了验收日之后到期日不见了';
    END IF;
    IF v_mat_date2 <> (v_mat_date + INTERVAL '3 months')::date THEN
        RAISE EXCEPTION 'FIXTURE 177C 失败:★ 验收日推后 3 个月,到期日必须跟着推后 3 个月 ★ —— 旧到期 %,新到期 %,期望 %。到期日若是【存下来的字面量】,它不会动,而没有任何人会发现',
            v_mat_date, v_mat_date2, (v_mat_date + INTERVAL '3 months')::date;
    END IF;
    -- 月数可改,而且改了到期日也要跟着走(逐台可改是 Tim 的要求)
    UPDATE purchase_order_line_retentions SET retention_months = 18 WHERE id = ret_a;
    SELECT maturity_date INTO v_mat_date FROM purchase_order_retention_status WHERE retention_id = ret_a;
    IF v_mat_date <> (v_mat_date2 + INTERVAL '6 months')::date THEN
        RAISE EXCEPTION 'FIXTURE 177C 失败:12 → 18 个月,到期日应当推后 6 个月,实得 % vs %',
            v_mat_date, (v_mat_date2 + INTERVAL '6 months')::date;
    END IF;
    UPDATE purchase_order_line_retentions SET retention_months = 12 WHERE id = ret_a;

    -- ══════════ B · 到期【提示】,不【付款】═══════════════════════════════════
    -- 验收在 15 个月前、质保 12 个月 → 已到期。
    SELECT retention_state INTO v_state FROM purchase_order_retention_status WHERE retention_id = ret_a;
    IF v_state <> 'awaiting_confirmation' THEN
        RAISE EXCEPTION 'FIXTURE 177B 失败:已到期的质保金状态应当是 awaiting_confirmation(等人确认),实得 %', v_state;
    END IF;
    -- ★ 到期【没有】产生任何应付,也没有把自己标成已放款 ★
    SELECT released_at IS NULL INTO v_denied FROM purchase_order_line_retentions WHERE id = ret_a;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 177B 失败:到期【不许】自动放款 —— released_at 自己填上了。质保金的意义就是它扣得下来,自动放款等于把它废掉';
    END IF;

    -- 未到期的不许提前放款(反方向):把验收改回 1 个月前
    PERFORM set_asset_acceptance(v_asset_a, (CURRENT_DATE - INTERVAL '1 month')::date);
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM release_purchase_order_retention(ret_a, 40000, 0, NULL);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('RETENTION_NOT_MATURE' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 177B 失败:未到期就放款应当按名拒 RETENTION_NOT_MATURE,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(放了)');
    END IF;
    PERFORM set_asset_acceptance(v_asset_a, (CURRENT_DATE - INTERVAL '15 months')::date);

    -- ══════════ D · 部分扣留,连同它的理由 ═══════════════════════════════════
    -- 质保金 = 400,000 × 10% = 40,000。
    SELECT retention_amount_ccy INTO v_amt FROM purchase_order_retention_status WHERE retention_id = ret_a;
    IF v_amt <> 40000 THEN
        RAISE EXCEPTION 'FIXTURE 177D 失败:质保金应当是 400000 × 10%% = 40000,实得 %', v_amt;
    END IF;

    -- 扣了钱不说理由 → 拒
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM release_purchase_order_retention(ret_a, 30000, 10000, NULL);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('RETENTION_WITHHOLDING_NEEDS_REASON' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 177D 失败:扣留而不说理由应当按名拒,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;
    -- 放款 + 扣留对不上总额 → 拒(那笔差额会没有下落)
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM release_purchase_order_retention(ret_a, 30000, 5000, '对不上');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('RETENTION_RELEASE_DOES_NOT_BALANCE' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 177D 失败:放款+扣留 ≠ 总额应当按名拒,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- 正路:放 30,000、扣 10,000,理由记下来
    v_res := release_purchase_order_retention(ret_a, 30000, 10000, '调试期间两次停机,备件费由供方承担');
    SELECT released_amount_ccy, withheld_amount_ccy, withholding_reason, released_by
    INTO v_rel, v_wh, v_reason, v_by
    FROM purchase_order_line_retentions WHERE id = ret_a;
    IF v_rel <> 30000 OR v_wh <> 10000 THEN
        RAISE EXCEPTION 'FIXTURE 177D 失败:应当放 30000 扣 10000,实得 % / %', v_rel, v_wh;
    END IF;
    IF v_reason IS NULL OR position('停机' in v_reason) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 177D 失败:扣留的理由没有记下来,实得 %', COALESCE(v_reason, '(空)');
    END IF;
    IF v_by IS DISTINCT FROM v_user THEN
        RAISE EXCEPTION 'FIXTURE 177D 失败:放款人应当记成确认的那个人,实得 %', v_by;
    END IF;
    SELECT retention_state INTO v_state FROM purchase_order_retention_status WHERE retention_id = ret_a;
    IF v_state <> 'released' THEN
        RAISE EXCEPTION 'FIXTURE 177D 失败:确认之后状态应当是 released,实得 %', v_state;
    END IF;
    -- 放过一次就不能再放
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM release_purchase_order_retention(ret_a, 40000, 0, NULL);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('RETENTION_ALREADY_RELEASED' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 177D 失败:重复放款应当按名拒,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(又放了一次)');
    END IF;

    -- ══════════ E · 质保金只挂设备行 ════════════════════════════════════════
    v_res := create_purchase_order(v_sup, DATE '2025-01-12', DATE '2025-03-01', v_ccy, NULL,
        NULL, NULL, 'fixture 177 material PO',
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100,
                                             'estimated_unit_price', 10)));
    po_mat := (v_res->>'purchase_order_id')::uuid;
    SELECT id INTO line_mat FROM purchase_order_lines WHERE purchase_order_id = po_mat;
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO purchase_order_line_retentions (purchase_order_line_id, percentage)
        VALUES (line_mat, 10);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('RETENTION_NOT_AN_EQUIPMENT_LINE' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 177E 失败:材料行上的质保金应当按名拒,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- ══════════ F · 锚必须是一个记得住日期的事件 ═════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO purchase_order_line_retentions (purchase_order_line_id, percentage, anchor_event)
        VALUES (line_b, 10, 'training_complete');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('RETENTION_ANCHOR_HAS_NO_DATE' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 177F 失败:锚在一个没有日期的事件上应当按名拒(否则到期日算不出来),实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- ══════════ H · 走【门】建单:一张带质保金、一张不带 ═══════════════════════
    -- 【这一臂对着"完成的定义"那一条】"一张单建得出【不带】质保金,也建得出
    -- 【带】质保金,而且两者在屏幕上分得开"。分得开的依据就是【有没有那一行】。
    DECLARE
        po_h1 uuid; po_h2 uuid; line_h1 uuid; line_h2 uuid;
        v_asset_c uuid; v_asset_d uuid; v_h jsonb;
    BEGIN
        v_h := record_expense(DATE '2025-01-07', '1500', 100000, v_ccy, NULL, 'unpaid', NULL,
            v_sup, NULL, 'fixture 177 machine C',
            jsonb_build_object('description', 'machine C', 'useful_life_months', 120), NULL);
        SELECT id INTO v_asset_c FROM fixed_assets WHERE expense_id = (v_h->>'expense_id')::uuid;
        v_h := record_expense(DATE '2025-01-08', '1500', 100000, v_ccy, NULL, 'unpaid', NULL,
            v_sup, NULL, 'fixture 177 machine D',
            jsonb_build_object('description', 'machine D', 'useful_life_months', 120), NULL);
        SELECT id INTO v_asset_d FROM fixed_assets WHERE expense_id = (v_h->>'expense_id')::uuid;

        -- 带质保金:10%,18 个月(【逐台可改】—— 不是那个 12 的默认值)
        v_h := create_purchase_order(v_sup, DATE '2025-01-13', DATE '2025-04-01', v_ccy, NULL,
            NULL, NULL, 'fixture 177 H1 with retention',
            jsonb_build_array(jsonb_build_object('asset_id', v_asset_c, 'estimated_unit_price', 100000,
                'retention', jsonb_build_object('percentage', 10, 'retention_months', 18))));
        po_h1 := (v_h->>'purchase_order_id')::uuid;
        IF (v_h->>'retention_count')::int <> 1 THEN
            RAISE EXCEPTION 'FIXTURE 177H 失败:带质保金的单应当报 retention_count = 1,实得 %', v_h->>'retention_count';
        END IF;

        -- 不带:负载里【没有 retention 这一键】
        v_h := create_purchase_order(v_sup, DATE '2025-01-14', DATE '2025-04-01', v_ccy, NULL,
            NULL, NULL, 'fixture 177 H2 without retention',
            jsonb_build_array(jsonb_build_object('asset_id', v_asset_d, 'estimated_unit_price', 100000)));
        po_h2 := (v_h->>'purchase_order_id')::uuid;
        IF (v_h->>'retention_count')::int <> 0 THEN
            RAISE EXCEPTION 'FIXTURE 177H 失败:不带质保金的单应当报 retention_count = 0,实得 %', v_h->>'retention_count';
        END IF;

        -- ★ 分得开:一张在状态视图里有行,另一张【一行都没有】★
        SELECT count(*) INTO v_n FROM purchase_order_retention_status WHERE purchase_order_id = po_h1;
        IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 177H 失败:H1 应当有 1 条质保金,实得 %', v_n; END IF;
        SELECT count(*) INTO v_n FROM purchase_order_retention_status WHERE purchase_order_id = po_h2;
        IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 177H 失败:H2 应当【一行都没有】,实得 %', v_n; END IF;
        SELECT retention_months INTO v_n FROM purchase_order_retention_status WHERE purchase_order_id = po_h1;
        IF v_n <> 18 THEN RAISE EXCEPTION 'FIXTURE 177H 失败:月数应当逐台可改(18),实得 %', v_n; END IF;

        -- 材料行上带 retention → 按名拒(门上那一句)
        v_denied := false; v_msg := NULL;
        BEGIN
            v_h := create_purchase_order(v_sup, DATE '2025-01-15', NULL, v_ccy, NULL,
                NULL, NULL, 'fixture 177 H3 material with retention',
                jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 10,
                    'estimated_unit_price', 5,
                    'retention', jsonb_build_object('percentage', 10))));
        EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
        END;
        IF NOT v_denied OR position('RETENTION_NOT_AN_EQUIPMENT_LINE' in v_msg) = 0 THEN
            RAISE EXCEPTION 'FIXTURE 177H 失败:材料行上的质保金应当在门上按名拒,实得 denied=% msg=%',
                v_denied, COALESCE(v_msg, '(收下了)');
        END IF;
    END;

    RAISE NOTICE 'FIXTURE 177 ✓ 可选(结构性缺席)· 到期只提示 · 锚动则到期动 · 部分扣留有理由';
END $$;
ROLLBACK;
