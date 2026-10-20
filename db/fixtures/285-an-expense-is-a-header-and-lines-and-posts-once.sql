-- db/fixtures/285-an-expense-is-a-header-and-lines-and-posts-once.sql
-- ═══════════════════════════════════════════════════════════════════════════
-- EXPENSE-MULTILINE-1(Tim 2026-10-20,Step 0 Q1–Q16):一张费用单是【表头 + 行】,过【一张】分录、欠【一笔】应付。
--
--   A  三行的单据:每行自己的科目与税码(TX 可抵 · BL 不可抵 · ZP),表头四个合计 = 各行之和;一张分录、借贷平衡;
--      可抵的税借 1400,不可抵的税借进那一行自己的科目;净额腿各带自己的税码;应付清单里是【一行】,金额 = 净额 + 税。
--   B  税按行 round(Q16):两行各 5.05 @ 9% → 每行 0.45,合计 0.90(按整张单算会是 0.91)—— 两种算法在这里分得开。
--   C  资本单恰好一行(Q1):1500 混在两行里、或两行带 p_asset → EXPENSE_CAPITAL_SOLE_LINE。
--   D  逐行的拒绝带行号:第 2 行金额不对 → AMOUNT_INVALID|2;第 2 行是负债科目 → ACCOUNT_NOT_EXPENSE|2600|2;空行 → EXPENSE_LINES_REQUIRED。
--   E  代扣一张单一个性质与税率、按净额之和算(Q12);带代扣的单【任何一行】带 GST → EXPENSE_WHT_WITH_GST(Q2)。
--   F  合计守卫(Q10):表头没有行 → EXPENSE_HAS_NO_LINES;表头与行对不上 → EXPENSE_TOTALS_MISMATCH(都在提交时 —— 这里强制立即);
--      行不可改、不可删(EXPENSE_LINE_IMMUTABLE)。
--   G  冲销是整张单(Q4):镜像单带着原单的每一行(净额,不带税码),镜像表头 = 镜像行之和;原分录被冲掉。
--   H  record_expense(单行包装,Q11)写出一行,分录与此前逐行同形(借净额 · 借税 · 贷净额 · 贷税)。
--   I  GST 关着时,任何一行带税码 → GST_NOT_REGISTERED(那道闸随码搬到了行上)。
-- 自带数据(README 第 2 条);GST 开关与期间锁自己设(第 4/5 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user  uuid := gen_random_uuid();
    r_all   uuid;
    v_sup   uuid; v_nr uuid;
    v_base  text;
    d       date := CURRENT_DATE - 3;
    v_res   jsonb; v_exp uuid; v_je uuid; v_mirror uuid;
    v_h     record; v_s record;
    v_n     int; v_x numeric; v_y numeric; v_msg text;
    v_rate  numeric;
BEGIN
    INSERT INTO auth.users (id) VALUES (v_user);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-285', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_user), true);
    SELECT code INTO v_base FROM currencies WHERE is_base;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ-F285-S', 'fixture 285 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;

    -- ══════════ I · GST 关着:任何一行带码 → 拒(那道闸随码搬到了行上)—— 先跑,开关此刻还关着 ══════════
    UPDATE finance_settings SET locked_before = NULL, gst_registered = false;
    BEGIN
        PERFORM record_expense_document(p_expense_date := d, p_currency := v_base, p_supplier_id := v_sup,
            p_lines := jsonb_build_array(jsonb_build_object('account_code', '6100', 'amount', 10),
                                         jsonb_build_object('account_code', '6100', 'amount', 10, 'tax_code', 'TX')));
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg <> 'GST_NOT_REGISTERED|TX' THEN RAISE EXCEPTION 'FIXTURE 285I 失败:未注册时第二行带 TX 应当 GST_NOT_REGISTERED|TX,实得 %', v_msg; END IF;
    -- 表上那一层(直插绕过函数):行上的触发器照样拒
    v_res := record_expense_document(p_expense_date := d, p_currency := v_base, p_supplier_id := v_sup,
        p_lines := jsonb_build_array(jsonb_build_object('account_code', '6100', 'amount', 10)));
    BEGIN
        INSERT INTO expense_lines (expense_id, line_no, account_code, amount_ccy, amount_base, tax_code, tax_rate_pct)
        VALUES ((v_res->>'expense_id')::uuid, 2, '6100', 1, 1, 'TX', 9);
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg <> 'GST_NOT_REGISTERED|TX' THEN RAISE EXCEPTION 'FIXTURE 285I 失败:未注册时直插一条带码的行应当被行上的闸拒,实得 %', v_msg; END IF;
    UPDATE finance_settings SET gst_registered = true, gst_registration_no = COALESCE(gst_registration_no, 'ZZ-F285-GST');
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, tax_residence)
    VALUES ('ZZ-F285-NR', 'fixture 285 non-resident', 'SG', 'active', 'service_vendor', 'non_resident') RETURNING id INTO v_nr;

    -- ══════════ A · 三行、三种税码、一张分录、一笔应付 ══════════
    v_res := record_expense_document(
        p_expense_date := d, p_currency := v_base, p_supplier_id := v_sup,
        p_notes := 'fixture 285 A',
        p_lines := jsonb_build_array(
            jsonb_build_object('account_code', '6100', 'amount', 200, 'tax_code', 'TX', 'notes', 'line one'),
            jsonb_build_object('account_code', '6120', 'amount', 100, 'tax_code', 'BL', 'notes', 'line two'),
            jsonb_build_object('account_code', '6010', 'amount', 50,  'tax_code', 'ZP')));
    v_exp := (v_res->>'expense_id')::uuid;
    IF (v_res->>'line_count')::int <> 3 THEN RAISE EXCEPTION 'FIXTURE 285A 失败:应当三行,实得 %', v_res; END IF;
    SELECT amount_ccy, amount_base, tax_ccy, tax_base, journal_entry_id INTO v_h FROM expenses WHERE id = v_exp;
    SELECT count(*) AS n, sum(amount_ccy) AS a, sum(amount_base) AS b, sum(tax_ccy) AS t, sum(tax_base) AS tb
      INTO v_s FROM expense_lines WHERE expense_id = v_exp;
    IF v_s.n <> 3 OR v_h.amount_ccy <> 350 OR v_h.tax_ccy <> 27.00
       OR (v_h.amount_ccy, v_h.amount_base, v_h.tax_ccy, v_h.tax_base) IS DISTINCT FROM (v_s.a, v_s.b, v_s.t, v_s.tb) THEN
        RAISE EXCEPTION 'FIXTURE 285A 失败:表头 % 与行 % 对不上(应当净额 350、税 18 + 9 + 0 = 27)', v_h, v_s;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM expense_lines WHERE expense_id = v_exp AND line_no = 2 AND account_code = '6120'
                    AND tax_code = 'BL' AND tax_ccy = 9.00 AND notes = 'line two') THEN
        RAISE EXCEPTION 'FIXTURE 285A 失败:第二行应当是 6120 / BL / 税 9.00 / 备注 line two'; END IF;
    v_je := v_h.journal_entry_id;
    SELECT count(*) INTO v_n FROM journal_entries WHERE source_type = 'expense' AND source_id = v_exp;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 285A 失败:一张单应当一张分录,实得 %', v_n; END IF;
    SELECT sum(debit), sum(credit) INTO v_x, v_y FROM journal_lines WHERE entry_id = v_je;
    IF v_x <> v_y OR v_x <> 377.00 THEN RAISE EXCEPTION 'FIXTURE 285A 失败:分录借 % 贷 %,应当都是 377.00', v_x, v_y; END IF;
    -- 可抵的 18 借 1400;不可抵的 9 借进 6120(那条腿不带税码);净额腿各带自己的码
    IF (SELECT sum(jl.debit) FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id WHERE jl.entry_id = v_je AND a.code = '1400') <> 18.00
       OR (SELECT sum(jl.debit) FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id WHERE jl.entry_id = v_je AND a.code = '6120') <> 109.00
       OR NOT EXISTS (SELECT 1 FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
                       WHERE jl.entry_id = v_je AND a.code = '6120' AND jl.tax_code IS NULL AND jl.debit = 9.00)
       OR (SELECT count(*) FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
            WHERE jl.entry_id = v_je AND jl.tax_code IS NOT NULL AND jl.debit > 0) <> 3
       OR (SELECT sum(jl.credit) FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id WHERE jl.entry_id = v_je AND a.code = '2000') <> 377.00 THEN
        RAISE EXCEPTION 'FIXTURE 285A 失败:分录的形状不对(1400 借 18 · 6120 借 100 + 9 且税腿无码 · 三条带码的净额腿 · 2000 贷 377)';
    END IF;
    SELECT count(*), sum(open_ccy) INTO v_n, v_x FROM ap_open_items WHERE doc_id = v_exp;
    IF v_n <> 1 OR v_x <> 377.00 THEN
        RAISE EXCEPTION 'FIXTURE 285A 失败:应付清单应当是【一行】377.00,实得 % 行 %', v_n, v_x; END IF;

    -- ══════════ B · 税按行 round(Q16)══════════
    -- ★ 自证分得开:按整张单算是 round(10.10 × 9%) = 0.91;按行是 0.45 + 0.45 = 0.90
    IF round(10.10 * 9 / 100.0, 2) = 0.90 THEN RAISE EXCEPTION 'FIXTURE 285B 失败(空转):两种算法在这组数上不分开'; END IF;
    v_res := record_expense_document(p_expense_date := d, p_currency := v_base, p_supplier_id := v_sup,
        p_lines := jsonb_build_array(jsonb_build_object('account_code', '6100', 'amount', 5.05, 'tax_code', 'TX'),
                                     jsonb_build_object('account_code', '6100', 'amount', 5.05, 'tax_code', 'TX')));
    IF (v_res->>'tax_ccy')::numeric <> 0.90 THEN
        RAISE EXCEPTION 'FIXTURE 285B 失败:税应当按行 round 合计 0.90,实得 %', v_res->>'tax_ccy'; END IF;

    -- ══════════ C · 资本单恰好一行(Q1)══════════
    BEGIN
        PERFORM record_expense_document(p_expense_date := d, p_currency := v_base, p_supplier_id := v_sup,
            p_lines := jsonb_build_array(jsonb_build_object('account_code', '6100', 'amount', 10, 'tax_code', 'TX'),
                                         jsonb_build_object('account_code', '1500', 'amount', 10, 'tax_code', 'TX')));
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg NOT LIKE 'EXPENSE_CAPITAL_SOLE_LINE|2%' THEN
        RAISE EXCEPTION 'FIXTURE 285C 失败:1500 混在两行里应当按名拒 EXPENSE_CAPITAL_SOLE_LINE,实得 %', v_msg; END IF;
    BEGIN
        PERFORM record_expense_document(p_expense_date := d, p_currency := v_base, p_supplier_id := v_sup,
            p_asset := jsonb_build_object('description', 'x', 'useful_life_months', 12),
            p_lines := jsonb_build_array(jsonb_build_object('account_code', '1500', 'amount', 10, 'tax_code', 'TX'),
                                         jsonb_build_object('account_code', '1500', 'amount', 10, 'tax_code', 'TX')));
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg NOT LIKE 'EXPENSE_CAPITAL_SOLE_LINE|2%' THEN
        RAISE EXCEPTION 'FIXTURE 285C 失败:带资产的两行单应当按名拒 EXPENSE_CAPITAL_SOLE_LINE,实得 %', v_msg; END IF;
    -- 反臂:一行的资本单照旧建得出资产
    v_res := record_expense_document(p_expense_date := d, p_currency := v_base, p_supplier_id := v_sup,
        p_asset := jsonb_build_object('description', 'fixture 285 machine', 'useful_life_months', 60),
        p_lines := jsonb_build_array(jsonb_build_object('account_code', '1500', 'amount', 1000, 'tax_code', 'TX')));
    IF (v_res->>'asset_id') IS NULL THEN RAISE EXCEPTION 'FIXTURE 285C 失败:一行的资本单应当建得出资产,实得 %', v_res; END IF;

    -- ══════════ D · 逐行的拒绝带行号 ══════════
    BEGIN
        PERFORM record_expense_document(p_expense_date := d, p_currency := v_base, p_supplier_id := v_sup,
            p_lines := jsonb_build_array(jsonb_build_object('account_code', '6100', 'amount', 10, 'tax_code', 'TX'),
                                         jsonb_build_object('account_code', '6100', 'amount', 0, 'tax_code', 'TX')));
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg <> 'AMOUNT_INVALID|2' THEN RAISE EXCEPTION 'FIXTURE 285D 失败:第 2 行金额为 0 应当 AMOUNT_INVALID|2,实得 %', v_msg; END IF;
    BEGIN
        PERFORM record_expense_document(p_expense_date := d, p_currency := v_base, p_supplier_id := v_sup,
            p_lines := jsonb_build_array(jsonb_build_object('account_code', '6100', 'amount', 10, 'tax_code', 'TX'),
                                         jsonb_build_object('account_code', '2600', 'amount', 10, 'tax_code', 'TX')));
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg <> 'ACCOUNT_NOT_EXPENSE|2600|2' THEN RAISE EXCEPTION 'FIXTURE 285D 失败:第 2 行是负债科目应当 ACCOUNT_NOT_EXPENSE|2600|2,实得 %', v_msg; END IF;
    BEGIN
        PERFORM record_expense_document(p_expense_date := d, p_currency := v_base, p_supplier_id := v_sup, p_lines := '[]'::jsonb);
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg <> 'EXPENSE_LINES_REQUIRED' THEN RAISE EXCEPTION 'FIXTURE 285D 失败:空行应当 EXPENSE_LINES_REQUIRED,实得 %', v_msg; END IF;

    -- ══════════ E · 代扣:一张单一个税率,按净额之和;带 GST 的行 → 拒 ══════════
    v_rate := wht_rate_for('technical_service_fee', d);
    IF v_rate IS NULL OR v_rate <= 0 THEN RAISE EXCEPTION 'FIXTURE 285E 失败(空转):技术服务费税率是 %', v_rate; END IF;
    v_res := record_expense_document(p_expense_date := d, p_currency := v_base, p_supplier_id := v_nr,
        p_wht_nature := 'technical_service_fee',
        p_lines := jsonb_build_array(jsonb_build_object('account_code', '6400', 'amount', 100, 'tax_code', 'OP'),
                                     jsonb_build_object('account_code', '6400', 'amount', 233.33, 'tax_code', 'OP')));
    IF (v_res->>'wht_amount_ccy')::numeric <> round(333.33 * v_rate / 100.0, 2) THEN
        RAISE EXCEPTION 'FIXTURE 285E 失败:代扣应当按净额之和 333.33 × % 算,实得 %', v_rate, v_res->>'wht_amount_ccy'; END IF;
    BEGIN
        PERFORM record_expense_document(p_expense_date := d, p_currency := v_base, p_supplier_id := v_nr,
            p_wht_nature := 'technical_service_fee',
            p_lines := jsonb_build_array(jsonb_build_object('account_code', '6400', 'amount', 100, 'tax_code', 'OP'),
                                         jsonb_build_object('account_code', '6400', 'amount', 100, 'tax_code', 'TX')));
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg NOT LIKE 'EXPENSE_WHT_WITH_GST|technical_service_fee|TX%' THEN
        RAISE EXCEPTION 'FIXTURE 285E 失败:代扣单的第二行带 TX 应当 EXPENSE_WHT_WITH_GST,实得 %', v_msg; END IF;

    -- ══════════ F · 合计守卫与行不可改 ══════════
    BEGIN
        INSERT INTO expenses (code, expense_date, amount_ccy, currency, fx_rate, amount_base, payment_status, supplier_id)
        VALUES ('ZZ-F285-NOLINES', d, 10, v_base, 1, 10, 'unpaid', v_sup);
        SET CONSTRAINTS ALL IMMEDIATE;
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    SET CONSTRAINTS ALL DEFERRED;
    IF v_msg NOT LIKE 'EXPENSE_HAS_NO_LINES|ZZ-F285-NOLINES%' THEN
        RAISE EXCEPTION 'FIXTURE 285F 失败:没有行的表头应当在提交时被拒 EXPENSE_HAS_NO_LINES,实得 %', v_msg; END IF;
    BEGIN
        INSERT INTO expenses (code, expense_date, amount_ccy, currency, fx_rate, amount_base, payment_status, supplier_id)
        VALUES ('ZZ-F285-MISMATCH', d, 10, v_base, 1, 10, 'unpaid', v_sup);
        INSERT INTO expense_lines (expense_id, line_no, account_code, amount_ccy, amount_base)
        SELECT id, 1, '6100', 9, 9 FROM expenses WHERE code = 'ZZ-F285-MISMATCH';
        SET CONSTRAINTS ALL IMMEDIATE;
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    SET CONSTRAINTS ALL DEFERRED;
    IF v_msg NOT LIKE 'EXPENSE_TOTALS_MISMATCH|ZZ-F285-MISMATCH%' THEN
        RAISE EXCEPTION 'FIXTURE 285F 失败:表头 10 与行 9 应当在提交时被拒 EXPENSE_TOTALS_MISMATCH,实得 %', v_msg; END IF;
    BEGIN
        UPDATE expense_lines SET notes = 'edited' WHERE expense_id = v_exp AND line_no = 1;
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg <> 'EXPENSE_LINE_IMMUTABLE' THEN RAISE EXCEPTION 'FIXTURE 285F 失败:改一行应当 EXPENSE_LINE_IMMUTABLE,实得 %', v_msg; END IF;
    BEGIN
        DELETE FROM expense_lines WHERE expense_id = v_exp AND line_no = 3;
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg <> 'EXPENSE_LINE_IMMUTABLE' THEN RAISE EXCEPTION 'FIXTURE 285F 失败:删一行应当 EXPENSE_LINE_IMMUTABLE,实得 %', v_msg; END IF;

    -- ══════════ G · 冲销整张单(Q4)══════════
    v_res := reverse_expense(v_exp, 'fixture 285 reversal');
    v_mirror := (v_res->>'reversal_expense_id')::uuid;
    SELECT count(*) INTO v_n FROM expense_lines WHERE expense_id = v_mirror;
    SELECT amount_ccy, amount_base INTO v_h FROM expenses WHERE id = v_mirror;
    IF v_n <> 3 OR v_h.amount_ccy <> 350
       OR (SELECT sum(amount_ccy) FROM expense_lines WHERE expense_id = v_mirror) <> v_h.amount_ccy
       OR EXISTS (SELECT 1 FROM expense_lines WHERE expense_id = v_mirror AND (tax_code IS NOT NULL OR tax_ccy <> 0)) THEN
        RAISE EXCEPTION 'FIXTURE 285G 失败:镜像单应当带着原单的三行净额、不带税码,表头 = 行之和'; END IF;
    IF (SELECT status FROM journal_entries WHERE id = v_je) <> 'reversed' OR (SELECT status FROM expenses WHERE id = v_exp) <> 'reversed' THEN
        RAISE EXCEPTION 'FIXTURE 285G 失败:原单与原分录都应当是 reversed'; END IF;

    -- ══════════ H · 单行包装:一行,分录四条腿 ══════════
    v_res := record_expense(p_expense_date := d, p_account_code := '6100', p_amount := 100, p_currency := v_base,
                            p_payment_status := 'unpaid', p_supplier_id := v_sup, p_tax_code := 'TX');
    v_exp := (v_res->>'expense_id')::uuid;
    SELECT count(*) INTO v_n FROM expense_lines WHERE expense_id = v_exp;
    IF v_n <> 1 OR (SELECT count(*) FROM journal_lines WHERE entry_id = (SELECT journal_entry_id FROM expenses WHERE id = v_exp)) <> 4 THEN
        RAISE EXCEPTION 'FIXTURE 285H 失败:record_expense 应当写一行、分录四条腿'; END IF;

    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    RAISE NOTICE 'FIXTURE 285 全部通过:三行一张分录一笔应付(A)· 税按行 round(B)· 资本单恰好一行(C)· 逐行拒绝带行号(D)· 代扣按净额之和、带 GST 拒(E)· 合计守卫与行不可改(F)· 整张冲销带着行(G)· 单行包装(H)· 税码闸在行上(I)';
END $$;
ROLLBACK;
