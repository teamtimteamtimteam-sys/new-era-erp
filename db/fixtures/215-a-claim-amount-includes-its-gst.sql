-- 215 报销额是收据上的总额 —— 税从里面拆出来,不加在上面(CLAIM-GST-1,2026-09-24)
--
-- 员工报上来的数是【收据总额】,已含 GST。此前 decide_expense_claim / pay_medical_claim 把它
-- 当净额、再加 9%:报 109 的记成欠员工 118.81。Tim CLAIM-GST-1 Q1–Q5 的修法,逐条钉住:
--
--   A  报销单 109.00 · TX 9% → 净 100.00 + 进项税 9.00(1400);欠员工的恰好是 109.00;
--      清单 = 总账;付 109.01 按名拒,付 109.00 结清,报销单翻成"已付"。
--   A2 报销单 120.50 · TX → 税 9.95(round(120.50 × 9/109) = 9.9495… 半数进位),净 110.55。
--   B  报销单 10.11 · TX —— 【写不成 净 + round(净 × 9%) 的那一种总额】:税 0.83、净 9.28,
--      而 tax_amount_for(9.28) = 0.84。清单必须仍是 10.11,清单 ↔ 总账未解释 0.00 ——
--      这一臂就是 expenses.tax_ccy 必须【存】而不能【算】的理由。
--   C  医疗申报 32.70 · BL → 净 30.00 + 不可抵税 2.70,两条都借 6120,1400 一分不进;欠 32.70。
--   D  报销单 50.00 · ZP(0%)→ 净 50.00、税 0.00,没有税那条腿。
--   E  报销单 USD 109.00 · TX,牌价 1.2345 → 净 100 + 税 9(原币);本位币 123.45 + 11.11;
--      清单 open_base 134.56 = 总账。
--   F  【对照】费用表单 / 供应商账单(默认 p_amount_includes_tax = false)照旧是净额 + 税另算:
--      p_amount 100 · TX → 应付 109.00。这一刀只动两条报销路。
--   G  每一步之后 list_ledger_reconciliation() 的应付侧未解释额 = 0.00。
--
-- ★ 每一臂先证【非空转】:"拆出来"与"加上去"给出的数必须真的不同,否则断言什么都没证明。
--
-- 自带数据(README 第 2 条);期间锁、GST 开关、system_start_date、牌价自己设(第 4/5 条)。
-- 两个人都拿全权限:批准人与报销人必须是不同的人(forbid_self_approval)。
BEGIN;
DO $$
DECLARE
    v_claimant uuid := gen_random_uuid();
    v_approver uuid := gen_random_uuid();
    r_all      uuid;
    v_emp      uuid;
    v_sup      uuid;
    v_base     text; v_usd text; v_bank text;
    d_spend    date := CURRENT_DATE - 10;
    v_res      jsonb; v_c uuid; v_exp uuid; v_je uuid;
    v_net numeric; v_tax numeric; v_taxb numeric; v_amtb numeric;
    v_x numeric; v_y numeric; v_z numeric;
    v_msg text; v_owing boolean; v_paid boolean;
    c_claimant text; c_approver text;
BEGIN
    -- ══════════════════ 布景 ══════════════════
    INSERT INTO auth.users (id) VALUES (v_claimant), (v_approver);
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-215', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_claimant, r_all), (v_approver, r_all);
    c_claimant := format('{"sub":"%s","role":"authenticated"}', v_claimant);
    c_approver := format('{"sub":"%s","role":"authenticated"}', v_approver);

    -- 【前提显式设定】全程要能过账;GST 开着(重建库的引导默认是 false);
    -- 医疗额度按 system_start_date 截断,重建库里它是 NULL(fixture 90 记过)。
    UPDATE finance_settings
       SET locked_before = NULL, gst_registered = true,
           gst_registration_no = COALESCE(gst_registration_no, 'M9-FIX215-1'),
           system_start_date = CURRENT_DATE - 800;
    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT code INTO v_usd FROM currencies WHERE NOT is_base ORDER BY code LIMIT 1;
    v_bank := bank_account_for_currency(v_base);

    -- E 要一个【确定的】外币牌价(fixture 208 / 212 同款:先软删窗口内既有的,再插自己的)。
    UPDATE fx_rates SET deleted_at = now()
     WHERE currency = v_usd AND rate_type = 'tt_sell' AND deleted_at IS NULL
       AND rate_date BETWEEN d_spend - 10 AND d_spend;
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES (v_usd, d_spend, 'tt_sell', 1.2345);

    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, employment_status, user_id)
    VALUES ('ZZ-F215-E', 'fixture 215 claimant', 'full_time', 'office', CURRENT_DATE - 400, 'active', v_claimant)
    RETURNING id INTO v_emp;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ-F215-S', 'fixture 215 supplier', 'SG', 'active', 'goods_supplier')
    RETURNING id INTO v_sup;

    -- 税率是真的 9%(否则 A 臂的"109 = 100 + 9"是一句凑出来的话)
    IF tax_rate_for('TX', d_spend) <> 9 THEN
        RAISE EXCEPTION 'FIXTURE 215 前提失败:TX 在 % 的税率是 %,不是 9', d_spend, tax_rate_for('TX', d_spend);
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- A 臂 · 报销单 109.00 · TX → 净 100.00 + 进项税 9.00,欠 109.00
    -- ══════════════════════════════════════════════════════════════════════
    -- ★ 非空转:旧算法(当净额、加在上面)给的是 118.81,与 109.00 分得开。
    IF 109.00 + tax_amount_for(109.00, 9) = 109.00 THEN
        RAISE EXCEPTION 'FIXTURE 215A 失败(空转):加在上面与拆出来给出同一个数';
    END IF;
    PERFORM set_config('request.jwt.claims', c_claimant, true);
    v_res := submit_expense_claim(v_emp, d_spend, 109.00, v_base, 'fixture 215A 出租车', '收据在司机那边');
    v_c := (v_res->>'claim_id')::uuid;
    PERFORM set_config('request.jwt.claims', c_approver, true);
    v_res := decide_expense_claim(v_c, true, '6120', 'TX', NULL, NULL);
    v_exp := (v_res->>'expense_id')::uuid;
    SELECT amount_ccy, tax_ccy, tax_base, amount_base, journal_entry_id
      INTO v_net, v_tax, v_taxb, v_amtb, v_je FROM expenses WHERE id = v_exp;
    IF v_net <> 100.00 OR v_tax <> 9.00 OR v_taxb <> 9.00 OR v_amtb <> 100.00 THEN
        RAISE EXCEPTION 'FIXTURE 215A 失败:报 109.00(TX)应当记 净 100.00 + 税 9.00,实得 净 % + 税 %(本位币 % + %)',
            v_net, v_tax, v_amtb, v_taxb;
    END IF;
    -- 分录:6120 借 100.00 且带 TX(box5 的来源)· 1400 借 9.00(box7 的来源)· 2000 贷 109.00
    SELECT COALESCE(sum(l.debit) FILTER (WHERE a.code = '6120' AND l.tax_code = 'TX'), 0),
           COALESCE(sum(l.debit - l.credit) FILTER (WHERE a.code = '1400'), 0),
           COALESCE(sum(l.credit - l.debit) FILTER (WHERE a.code = '2000'), 0)
      INTO v_x, v_y, v_z
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id WHERE l.entry_id = v_je;
    IF v_x <> 100.00 OR v_y <> 9.00 OR v_z <> 109.00 THEN
        RAISE EXCEPTION 'FIXTURE 215A 失败:分录应当是 6120(TX) 100.00 · 1400 9.00 · 2000 贷 109.00,实得 % · % · %', v_x, v_y, v_z;
    END IF;
    SELECT open_ccy, open_base INTO v_x, v_y FROM ap_open_items WHERE doc_kind = 'expense' AND doc_id = v_exp;
    IF v_x IS DISTINCT FROM 109.00 OR v_y IS DISTINCT FROM 109.00 THEN
        RAISE EXCEPTION 'FIXTURE 215A 失败:清单上应当欠 109.00,实得 open_ccy % / open_base %', v_x, v_y;
    END IF;
    SELECT (s->>'unexplained_base')::numeric INTO v_x
      FROM jsonb_array_elements(list_ledger_reconciliation()->'sides') s WHERE s->>'side' = 'ap';
    IF v_x IS DISTINCT FROM 0.00 THEN
        RAISE EXCEPTION 'FIXTURE 215G 失败(A 之后):应付侧未解释额应当 0.00,实得 %', v_x;
    END IF;
    SELECT is_owing, is_paid INTO v_owing, v_paid FROM expense_claim_status WHERE claim_id = v_c;
    IF NOT v_owing OR v_paid THEN
        RAISE EXCEPTION 'FIXTURE 215A 失败:批了没付应当 is_owing / not is_paid,实得 % / %', v_owing, v_paid;
    END IF;
    -- 上限就是员工报的那个数:多一分按名拒
    BEGIN
        PERFORM record_payment('out', v_emp, 109.01, v_base, NULL, v_bank, CURRENT_DATE, 'fixture 215A 多付一分',
            jsonb_build_array(jsonb_build_object('expense_id', v_exp, 'amount_doc', 109.01)), 'employee');
        RAISE EXCEPTION 'FIXTURE 215A 失败:付 109.01 被收下了 —— 员工只报了 109.00';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'ALLOC_EXCEEDS%' THEN
            RAISE EXCEPTION 'FIXTURE 215A 失败:付 109.01 应当 ALLOC_EXCEEDS,实得 %', v_msg;
        END IF;
    END;
    PERFORM record_payment('out', v_emp, 109.00, v_base, NULL, v_bank, CURRENT_DATE, 'fixture 215A 付清',
        jsonb_build_array(jsonb_build_object('expense_id', v_exp, 'amount_doc', 109.00)), 'employee');
    SELECT is_owing, is_paid INTO v_owing, v_paid FROM expense_claim_status WHERE claim_id = v_c;
    IF v_owing OR NOT v_paid THEN
        RAISE EXCEPTION 'FIXTURE 215A 失败:付 109.00 之后应当已付,实得 is_owing % / is_paid %', v_owing, v_paid;
    END IF;
    IF EXISTS (SELECT 1 FROM ap_open_items WHERE doc_kind = 'expense' AND doc_id = v_exp) THEN
        RAISE EXCEPTION 'FIXTURE 215A 失败:付清之后它还在清单上';
    END IF;
    RAISE NOTICE '215A 报 109.00(TX)→ 100.00 + 9.00,付 109.00 结清 ✓';

    -- ══ A2 · 120.50 · TX → 税 9.95(半数进位那一格)══════════════════════
    -- ★ 非空转:120.50 × 9/109 = 9.9495…,截断是 9.94、四舍五入是 9.95 —— 两种取整分得开。
    IF trunc(120.50 * 9 / 109.0, 2) = round(120.50 * 9 / 109.0, 2) THEN
        RAISE EXCEPTION 'FIXTURE 215A2 失败(空转):这个总额分不开截断与四舍五入';
    END IF;
    PERFORM set_config('request.jwt.claims', c_claimant, true);
    v_res := submit_expense_claim(v_emp, d_spend, 120.50, v_base, 'fixture 215A2', '收据丢了');
    v_c := (v_res->>'claim_id')::uuid;
    PERFORM set_config('request.jwt.claims', c_approver, true);
    v_exp := (decide_expense_claim(v_c, true, '6120', 'TX', NULL, NULL)->>'expense_id')::uuid;
    SELECT amount_ccy, tax_ccy INTO v_net, v_tax FROM expenses WHERE id = v_exp;
    IF v_net <> 110.55 OR v_tax <> 9.95 THEN
        RAISE EXCEPTION 'FIXTURE 215A2 失败:报 120.50(TX)应当记 110.55 + 9.95,实得 % + %', v_net, v_tax;
    END IF;
    RAISE NOTICE '215A2 报 120.50 → 110.55 + 9.95 ✓';

    -- ══════════════════════════════════════════════════════════════════════
    -- B 臂 · 10.11 —— 写不成 净 + round(净 × 9%) 的总额
    -- ══════════════════════════════════════════════════════════════════════
    -- ★ 非空转:证明 10.11 真的是那一种 —— 拆出来的税 ≠ 按拆出来的净额重算的税。
    v_tax := tax_included_in(10.11, 9);
    IF tax_amount_for(10.11 - v_tax, 9) = v_tax THEN
        RAISE EXCEPTION 'FIXTURE 215B 失败(空转):10.11 在 9%% 下写得成 净 + round(净 × 9%%) —— 这一臂证明不了 tax_ccy 必须存';
    END IF;
    PERFORM set_config('request.jwt.claims', c_claimant, true);
    v_res := submit_expense_claim(v_emp, d_spend, 10.11, v_base, 'fixture 215B', '自动售票机不出收据');
    v_c := (v_res->>'claim_id')::uuid;
    PERFORM set_config('request.jwt.claims', c_approver, true);
    v_exp := (decide_expense_claim(v_c, true, '6120', 'TX', NULL, NULL)->>'expense_id')::uuid;
    SELECT amount_ccy, tax_ccy, journal_entry_id INTO v_net, v_tax, v_je FROM expenses WHERE id = v_exp;
    IF v_net <> 9.28 OR v_tax <> 0.83 THEN
        RAISE EXCEPTION 'FIXTURE 215B 失败:报 10.11(TX)应当记 9.28 + 0.83,实得 % + %', v_net, v_tax;
    END IF;
    SELECT COALESCE(sum(l.credit - l.debit), 0) INTO v_z
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id WHERE l.entry_id = v_je AND a.code = '2000';
    SELECT open_ccy, open_base INTO v_x, v_y FROM ap_open_items WHERE doc_kind = 'expense' AND doc_id = v_exp;
    IF v_x IS DISTINCT FROM 10.11 OR v_y IS DISTINCT FROM 10.11 OR v_z <> 10.11 THEN
        RAISE EXCEPTION 'FIXTURE 215B 失败:清单 open_ccy % / open_base %,总账 2000 %,三个都应当是 10.11', v_x, v_y, v_z;
    END IF;
    SELECT (s->>'unexplained_base')::numeric INTO v_x
      FROM jsonb_array_elements(list_ledger_reconciliation()->'sides') s WHERE s->>'side' = 'ap';
    IF v_x IS DISTINCT FROM 0.00 THEN
        RAISE EXCEPTION 'FIXTURE 215G 失败(B 之后):应付侧未解释额应当 0.00,实得 % —— 清单在重算税,而不是读落库的那一笔', v_x;
    END IF;
    RAISE NOTICE '215B 报 10.11 → 9.28 + 0.83,清单 10.11 = 总账,未解释 0.00 ✓';

    -- ══════════════════════════════════════════════════════════════════════
    -- C 臂 · 医疗申报 32.70 · BL → 6120 借 30.00(带 BL)+ 2.70(不带税码),1400 零
    -- ══════════════════════════════════════════════════════════════════════
    PERFORM set_config('request.jwt.claims', c_claimant, true);
    v_res := submit_medical_claim(p_employee_id := v_emp, p_claim_date := d_spend,
        p_amount_sgd := 32.70, p_description := 'fixture 215C 门诊');
    v_c := (v_res->>'claim_id')::uuid;
    PERFORM set_config('request.jwt.claims', c_approver, true);
    PERFORM decide_medical_claim(p_claim_id := v_c, p_approve := true);
    v_res := pay_medical_claim(p_claim_id := v_c, p_expense_date := d_spend, p_tax_code := 'BL');
    v_exp := (v_res->>'expense_id')::uuid;
    SELECT amount_ccy, tax_ccy, journal_entry_id INTO v_net, v_tax, v_je FROM expenses WHERE id = v_exp;
    IF v_net <> 30.00 OR v_tax <> 2.70 THEN
        RAISE EXCEPTION 'FIXTURE 215C 失败:医疗申报 32.70(BL)应当记 30.00 + 2.70,实得 % + %', v_net, v_tax;
    END IF;
    SELECT COALESCE(sum(l.debit) FILTER (WHERE a.code = '6120' AND l.tax_code = 'BL'), 0),
           COALESCE(sum(l.debit) FILTER (WHERE a.code = '6120' AND l.tax_code IS NULL), 0),
           COALESCE(sum(l.debit - l.credit) FILTER (WHERE a.code = '1400'), 0),
           COALESCE(sum(l.credit - l.debit) FILTER (WHERE a.code = '2000'), 0)
      INTO v_x, v_y, v_z, v_amtb
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id WHERE l.entry_id = v_je;
    IF v_x <> 30.00 OR v_y <> 2.70 OR v_z <> 0 OR v_amtb <> 32.70 THEN
        RAISE EXCEPTION 'FIXTURE 215C 失败:应当 6120(BL) 30.00 · 6120(无码) 2.70 · 1400 0 · 2000 贷 32.70,实得 % · % · % · %',
            v_x, v_y, v_z, v_amtb;
    END IF;
    SELECT open_ccy INTO v_x FROM ap_open_items WHERE doc_kind = 'expense' AND doc_id = v_exp;
    IF v_x IS DISTINCT FROM 32.70 THEN
        RAISE EXCEPTION 'FIXTURE 215C 失败:清单上应当欠 32.70,实得 %', v_x;
    END IF;
    RAISE NOTICE '215C 医疗 32.70(BL)→ 30.00 + 2.70,全部进 6120 ✓';

    -- ══════════════════════════════════════════════════════════════════════
    -- D 臂 · 50.00 · ZP(0%)→ 净 50.00、税 0,没有税那条腿
    -- ══════════════════════════════════════════════════════════════════════
    PERFORM set_config('request.jwt.claims', c_claimant, true);
    v_res := submit_expense_claim(v_emp, d_spend, 50.00, v_base, 'fixture 215D', '零税率');
    v_c := (v_res->>'claim_id')::uuid;
    PERFORM set_config('request.jwt.claims', c_approver, true);
    v_exp := (decide_expense_claim(v_c, true, '6120', 'ZP', NULL, NULL)->>'expense_id')::uuid;
    SELECT amount_ccy, tax_ccy, tax_code, journal_entry_id INTO v_net, v_tax, v_msg, v_je FROM expenses WHERE id = v_exp;
    IF v_net <> 50.00 OR v_tax <> 0 OR v_msg IS DISTINCT FROM 'ZP' THEN
        RAISE EXCEPTION 'FIXTURE 215D 失败:报 50.00(ZP)应当记 50.00 + 0、税码 ZP,实得 % + %、%', v_net, v_tax, v_msg;
    END IF;
    SELECT count(*) INTO v_x FROM journal_lines WHERE entry_id = v_je;
    IF v_x <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 215D 失败:0%% 的税没有那条腿,分录应当恰好 2 行,实得 %', v_x;
    END IF;
    RAISE NOTICE '215D 报 50.00(ZP)→ 50.00 + 0 ✓';

    -- ══════════════════════════════════════════════════════════════════════
    -- E 臂 · USD 109.00 · TX,牌价 1.2345 —— 在报销单自己的币种里拆
    -- ══════════════════════════════════════════════════════════════════════
    PERFORM set_config('request.jwt.claims', c_claimant, true);
    v_res := submit_expense_claim(v_emp, d_spend, 109.00, v_usd, 'fixture 215E 海外', '外币收据');
    v_c := (v_res->>'claim_id')::uuid;
    PERFORM set_config('request.jwt.claims', c_approver, true);
    v_exp := (decide_expense_claim(v_c, true, '6120', 'TX', NULL, NULL)->>'expense_id')::uuid;
    SELECT amount_ccy, tax_ccy, amount_base, tax_base, currency
      INTO v_net, v_tax, v_amtb, v_taxb, v_msg FROM expenses WHERE id = v_exp;
    IF v_msg <> v_usd OR v_net <> 100.00 OR v_tax <> 9.00 OR v_amtb <> 123.45 OR v_taxb <> 11.11 THEN
        RAISE EXCEPTION 'FIXTURE 215E 失败:USD 109(TX,1.2345)应当 净 100 + 税 9(本位币 123.45 + 11.11),实得 % % + %(% + %)',
            v_msg, v_net, v_tax, v_amtb, v_taxb;
    END IF;
    SELECT open_ccy, open_base INTO v_x, v_y FROM ap_open_items WHERE doc_kind = 'expense' AND doc_id = v_exp;
    IF v_x IS DISTINCT FROM 109.00 OR v_y IS DISTINCT FROM 134.56 THEN
        RAISE EXCEPTION 'FIXTURE 215E 失败:清单应当 USD 109.00 / 本位币 134.56,实得 % / %', v_x, v_y;
    END IF;
    SELECT (s->>'unexplained_base')::numeric INTO v_x
      FROM jsonb_array_elements(list_ledger_reconciliation()->'sides') s WHERE s->>'side' = 'ap';
    IF v_x IS DISTINCT FROM 0.00 THEN
        RAISE EXCEPTION 'FIXTURE 215G 失败(E 之后):应付侧未解释额应当 0.00,实得 %', v_x;
    END IF;
    RAISE NOTICE '215E USD 109(TX)→ 100 + 9,清单 134.56 = 总账 ✓';

    -- ══════════════════════════════════════════════════════════════════════
    -- F 臂 · 对照:费用表单 / 供应商账单仍是【净额】,税另算
    -- ══════════════════════════════════════════════════════════════════════
    PERFORM set_config('request.jwt.claims', c_approver, true);
    v_res := record_expense(p_expense_date := d_spend, p_account_code := '6400', p_amount := 100,
        p_currency := v_base, p_payment_status := 'unpaid', p_supplier_id := v_sup, p_tax_code := 'TX');
    v_exp := (v_res->>'expense_id')::uuid;
    SELECT amount_ccy, tax_ccy INTO v_net, v_tax FROM expenses WHERE id = v_exp;
    SELECT open_ccy INTO v_x FROM ap_open_items WHERE doc_kind = 'expense' AND doc_id = v_exp;
    IF v_net <> 100 OR v_tax <> 9.00 OR v_x IS DISTINCT FROM 109.00 THEN
        RAISE EXCEPTION 'FIXTURE 215F 失败:费用表单 100(TX)应当仍是 100 + 9 = 109,实得 % + %,清单 %', v_net, v_tax, v_x;
    END IF;
    IF (v_res->>'amount_ccy')::numeric <> 100 OR (v_res->>'tax_ccy')::numeric <> 9.00 THEN
        RAISE EXCEPTION 'FIXTURE 215F 失败:record_expense 应当把净额与税回给调用方,实得 %', v_res;
    END IF;
    SELECT (s->>'unexplained_base')::numeric INTO v_x
      FROM jsonb_array_elements(list_ledger_reconciliation()->'sides') s WHERE s->>'side' = 'ap';
    IF v_x IS DISTINCT FROM 0.00 THEN
        RAISE EXCEPTION 'FIXTURE 215G 失败(收尾):应付侧未解释额应当 0.00,实得 %', v_x;
    END IF;
    RAISE NOTICE '215F 费用表单 100(TX)仍是 100 + 9 ✓';

    -- 末尾强制校验一次借贷平衡(fixture 104 / 208 / 212 同款)
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;

    RAISE NOTICE 'FIXTURE 215 全部通过:报销额里的税是拆出来的(A/A2/B/C/D/E),费用表单照旧(F),清单 ↔ 总账未解释 0.00(G)';
END $$;
ROLLBACK;
