-- 212 清单上欠的,就是总账上记的(AP-RECON-1 Batch A)
--
-- AP-RECON-0 / AP-RECON-1 的 grilling 把应付清单 ↔ 2000、应收清单 ↔ 1100 逐分钱拆开,
-- 找到五条【活的】缺陷 —— 每一条都会在今天的代码上继续把清单与总账拉开。
-- 本 fixture 逐条钉住修法:
--
--   A  带税费用单的应付 = 净额 + 进项税 —— 清单、账龄与总账逐分相同,一次核销就闭合到零;
--      A2 是外币那一分钱:round((净+税)×汇率) ≠ round(净×汇率)+round(税×汇率) 的时候,
--      未结的那一刻清单也必须等于总账,不是等于那个"看起来对"的乘积。
--   B  付款上限扣掉预付冲抵 —— 清单说欠 280,付款路径就只肯收 280。
--   C  同一张单既要代扣又带进项税 → 按名拒;税为 0 时照常放行(拒绝是关于"真的有税")。
--   D  sale 型发票的销项税是它自己的一项应收 —— 清单、账龄、敞口、对账单都看得见它;
--      一笔收款同时核销净额与税后,1100 上这一对闭合到零;上限就是那笔税;
--      不带税的 sale 型发票照旧不收核销;有活核销就不许作废。
--   E  还欠着钱的已计价收货不许注销;没计价的照常可以注销。
--   (日期那三条规矩 —— Tim AP-RECON-1 Q7 —— 按 Tim 2026-09-24 的裁定【挪到它自己的一刀】:
--    32 份既有 fixture 刻意把过账记进 2027–2030,那一刀连同它们的改写一起做。)
--
-- ★ 每一臂先证【非空转】(与 fixture 142 同一套写法):被比较的两个数必须真的不同,
--   否则"修好了"与"没修"给出同一个答案,断言什么都没证明。
--
-- 自带数据(README 第 2 条);期间锁、GST 开关自己设(第 4/5 条)。直接调引擎
-- (record_payment_internal)—— 审批那一半归 fixture 210,本文件测的是算术。
-- 【SET CONSTRAINTS ALL IMMEDIATE】末尾强制校验一次借贷平衡(fixture 104 / 208 同款)。
BEGIN;
DO $$
DECLARE
    v_user   uuid := gen_random_uuid();
    r_all    uuid;
    v_base   text; v_usd text;
    d        date := CURRENT_DATE;
    v_s1 uuid; v_s2 uuid; v_s3 uuid; v_mat uuid; v_ob uuid; v_ob2 uuid; v_cust uuid; v_po uuid;
    v_res jsonb; v_exp uuid; v_exp2 uuid; v_exp3 uuid; v_je uuid;
    v_sale uuid; v_sale2 uuid; v_inv uuid; v_inv2 uuid; v_inv_je uuid;
    v_rcpt jsonb; v_rcpt_je uuid; v_pay jsonb; v_pay_je uuid;
    v_b_priced uuid; v_b_bare uuid;
    v_n int; v_msg text; v_ok boolean;
    v_x numeric; v_y numeric; v_z numeric;
    v_tax numeric;
    v_stmt jsonb;
BEGIN
    -- ══════════════════ 布景 ══════════════════
    INSERT INTO auth.users (id) VALUES (v_user);
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-212', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);

    -- 【前提显式设定】全程要能过账;GST 开着(A/C/D 三臂的全部判别力在税上)。
    UPDATE finance_settings SET locked_before = NULL, gst_registered = true, gst_registration_no = 'M9-FIX212-9';
    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT code INTO v_usd FROM currencies WHERE NOT is_base ORDER BY code LIMIT 1;

    -- A2 要一个【确定的】外币牌价:先把窗口内既有的软删掉,再插自己的(fixture 208 同款)。
    UPDATE fx_rates SET deleted_at = now()
     WHERE currency = v_usd AND rate_type = 'tt_sell' AND deleted_at IS NULL
       AND rate_date BETWEEN d - 10 AND d;
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES (v_usd, d, 'tt_sell', 1.2345);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, default_tax_code)
    VALUES ('ZZFIX212-S1', 'fixture 212 taxed supplier', 'SG', 'active', 'service_vendor', 'TX')
    RETURNING id INTO v_s1;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, default_tax_code)
    VALUES ('ZZFIX212-S2', 'fixture 212 zero-rated supplier', 'SG', 'active', 'goods_supplier', 'ZP')
    RETURNING id INTO v_s2;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, default_tax_code, tax_residence)
    VALUES ('ZZFIX212-S3', 'fixture 212 non-resident', 'CN', 'active', 'service_vendor', 'TX', 'non_resident')
    RETURNING id INTO v_s3;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX212-M', 'fixture 212 material', 'battery_material', true, 'black_mass', 'end_of_life')
    RETURNING id INTO v_mat;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZFIX212-OB', v_mat, 10000, 10000, d) RETURNING id INTO v_ob;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZFIX212-OB2', v_mat, 10000, 10000, d) RETURNING id INTO v_ob2;
    INSERT INTO customers (code, legal_name, country, default_tax_code, payment_terms_days)
    VALUES ('ZZFIX212-C', 'fixture 212 customer', 'SG', 'SR', 30) RETURNING id INTO v_cust;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════════════════════════════════════════════════════════════════
    -- A · 带税费用单:清单 = 账龄 = 总账 = 净额 + 税,一次核销闭合到零
    -- ══════════════════════════════════════════════════════════════════════
    v_res := record_expense(p_expense_date := d, p_account_code := '6400', p_amount := 100,
        p_currency := v_base, p_payment_status := 'unpaid', p_supplier_id := v_s1);
    v_exp := (v_res->>'expense_id')::uuid;
    SELECT journal_entry_id, tax_base INTO v_je, v_tax FROM expenses WHERE id = v_exp;
    -- ★ 非空转:这张单真的带税。税为 0 时"净额"与"净额+税"是同一个数。
    IF COALESCE(v_tax, 0) <= 0 THEN
        RAISE EXCEPTION 'FIXTURE 212A 失败(空转):这张费用单的税是 % —— 撑不起"净额+税"的任何一条断言', v_tax;
    END IF;
    SELECT COALESCE(sum(l.credit - l.debit), 0) INTO v_x
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id
     WHERE l.entry_id = v_je AND a.code = '2000';
    SELECT open_base, open_ccy INTO v_y, v_z FROM ap_open_items WHERE doc_kind = 'expense' AND doc_id = v_exp;
    IF v_x <> 100 + v_tax OR v_y IS DISTINCT FROM v_x THEN
        RAISE EXCEPTION 'FIXTURE 212A 失败:总账 2000 为这张单记了 %,清单说欠 % —— 应当都是 净额 100 + 税 %',
            v_x, v_y, v_tax;
    END IF;
    -- ★ open_ccy 单独断言 —— 它是付款页预填的那个数。只断言 open_base 的第一版在
    --   【把 open_ccy 改回净额】的注入下照样绿(未结时 open_base 取的是存下的本位币两腿之和),
    --   而屏幕上那一格会预填 100,付完那笔税就永远挂在 2000 上。
    IF v_z IS DISTINCT FROM 100 + v_tax THEN
        RAISE EXCEPTION 'FIXTURE 212A 失败:清单的 open_ccy 是 %(付款页会预填这个数),应为 净额 100 + 税 %', v_z, v_tax;
    END IF;
    SELECT (e->>'open_base')::numeric, (e->>'open_ccy')::numeric INTO v_z, v_y
      FROM jsonb_array_elements(ap_aging_asof(d)->'rows') e WHERE e->>'doc_id' = v_exp::text;
    IF v_z IS DISTINCT FROM v_x OR v_y IS DISTINCT FROM 100 + v_tax THEN
        RAISE EXCEPTION 'FIXTURE 212A 失败:账龄说欠 %(单据币种 %),总账 2000 记了 % —— 账龄与清单是同一个数的两个读法', v_z, v_y, v_x;
    END IF;
    -- 一次核销全额(净额 + 税)—— 修之前 ALLOC_EXCEEDS
    v_pay := record_payment_internal(p_direction := 'out', p_counterparty_id := v_s1,
        p_amount := 100 + v_tax, p_currency := v_base, p_payment_date := d,
        p_allocations := jsonb_build_array(jsonb_build_object('expense_id', v_exp, 'amount_doc', 100 + v_tax)));
    SELECT journal_entry_id INTO v_pay_je FROM payments WHERE id = (v_pay->>'payment_id')::uuid;
    SELECT count(*) INTO v_n FROM ap_open_items WHERE doc_kind = 'expense' AND doc_id = v_exp;
    SELECT COALESCE(sum(l.credit - l.debit), 0) INTO v_x
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id
     WHERE l.entry_id IN (v_je, v_pay_je) AND a.code = '2000';
    IF v_n <> 0 OR v_x <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 212A 失败:全额付清后清单上还有 % 行,2000 上这一对还剩 % —— 应当都是 0', v_n, v_x;
    END IF;

    -- A2 · 外币那一分钱:净 10.04、税 0.90、牌价 1.2345 → 总账 12.39 + 1.11 = 13.50,
    --      而 round(10.94 × 1.2345) = 13.51。未结的那一刻清单必须是 13.50。
    v_res := record_expense(p_expense_date := d, p_account_code := '6400', p_amount := 10.04,
        p_currency := v_usd, p_payment_status := 'unpaid', p_supplier_id := v_s1);
    v_exp2 := (v_res->>'expense_id')::uuid;
    SELECT journal_entry_id INTO v_je FROM expenses WHERE id = v_exp2;
    SELECT COALESCE(sum(l.credit - l.debit), 0) INTO v_x
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id
     WHERE l.entry_id = v_je AND a.code = '2000';
    SELECT round((amount_ccy + tax_ccy) * fx_rate, 2) INTO v_z FROM expenses WHERE id = v_exp2;
    -- ★ 非空转:那个"看起来对"的乘积真的与总账差一分。
    IF v_z = v_x THEN
        RAISE EXCEPTION 'FIXTURE 212A2 失败(空转):round((净+税)×汇率) = % 恰好等于总账 % —— 这组数分不开两种算法', v_z, v_x;
    END IF;
    SELECT open_base INTO v_y FROM ap_open_items WHERE doc_kind = 'expense' AND doc_id = v_exp2;
    IF v_y IS DISTINCT FROM v_x THEN
        RAISE EXCEPTION 'FIXTURE 212A2 失败:外币带税单未结时清单说欠 %,总账 2000 记了 %(乘积是 %)', v_y, v_x, v_z;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- B · 付款上限扣掉预付冲抵
    -- ══════════════════════════════════════════════════════════════════════
    v_res := record_expense(p_expense_date := d, p_account_code := '6400', p_amount := 400,
        p_currency := v_base, p_payment_status := 'unpaid', p_supplier_id := v_s2);
    v_exp3 := (v_res->>'expense_id')::uuid;
    INSERT INTO purchase_orders (code, supplier_id, order_date, status, currency, fx_rate)
    VALUES ('ZZFIX212-PO', v_s2, d, 'confirmed', v_base, 1) RETURNING id INTO v_po;
    INSERT INTO prepayment_applications (purchase_order_id, expense_id, amount_base, currency, amount_ccy)
    VALUES (v_po, v_exp3, 120, v_base, 120);
    SELECT open_ccy INTO v_y FROM ap_open_items WHERE doc_kind = 'expense' AND doc_id = v_exp3;
    IF v_y IS DISTINCT FROM 280::numeric THEN
        RAISE EXCEPTION 'FIXTURE 212B 前提失败:清单应当说这张单欠 280(400 − 定金 120),实得 %', v_y;
    END IF;
    v_ok := false; v_msg := NULL;
    BEGIN
        PERFORM record_payment_internal(p_direction := 'out', p_counterparty_id := v_s2,
            p_amount := 281, p_currency := v_base, p_payment_date := d,
            p_allocations := jsonb_build_array(jsonb_build_object('expense_id', v_exp3, 'amount_doc', 281)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_ok := (SQLERRM LIKE 'ALLOC_EXCEEDS|%');
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 212B 失败:清单说欠 280,付款路径却收下了 281(或拒得不对):%', COALESCE(v_msg, '(通过了)');
    END IF;
    PERFORM record_payment_internal(p_direction := 'out', p_counterparty_id := v_s2,
        p_amount := 280, p_currency := v_base, p_payment_date := d,
        p_allocations := jsonb_build_array(jsonb_build_object('expense_id', v_exp3, 'amount_doc', 280)));
    SELECT count(*) INTO v_n FROM ap_open_items WHERE doc_kind = 'expense' AND doc_id = v_exp3;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 212B 失败:付了清单上那 280 之后它还在清单上';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- C · 代扣 + 进项税 同在一张单 → 按名拒;税为 0 时放行
    -- ══════════════════════════════════════════════════════════════════════
    IF COALESCE(wht_rate_for('technical_service_fee', d), 0) <= 0 THEN
        RAISE EXCEPTION 'FIXTURE 212C 失败(空转):技术服务费的法定代扣率不是正数 —— 撑不起这一臂';
    END IF;
    v_ok := false; v_msg := NULL;
    BEGIN
        PERFORM record_expense(p_expense_date := d, p_account_code := '6400', p_amount := 1000,
            p_currency := v_base, p_payment_status := 'unpaid', p_supplier_id := v_s3,
            p_wht_nature := 'technical_service_fee');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_ok := (SQLERRM LIKE 'EXPENSE_WHT_WITH_GST|%');
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 212C 失败:代扣 + 进项税应当按名拒 EXPENSE_WHT_WITH_GST,实得 %', COALESCE(v_msg, '(通过了)');
    END IF;
    -- 同一家、同一性质,税码改成 0% 的 ZP → 照常记账(拒绝是关于"真的有税",不是关于这家供应商)
    PERFORM record_expense(p_expense_date := d, p_account_code := '6400', p_amount := 1000,
        p_currency := v_base, p_payment_status := 'unpaid', p_supplier_id := v_s3,
        p_wht_nature := 'technical_service_fee', p_tax_code := 'ZP');

    -- ══════════════════════════════════════════════════════════════════════
    -- D · sale 型发票的销项税是它自己的一项应收
    -- ══════════════════════════════════════════════════════════════════════
    v_res := record_output_sale(v_ob, 100, 10, v_base, NULL, v_cust, d, NULL, 'manual', NULL);
    v_sale := (v_res->>'sale_id')::uuid;
    v_res := create_invoice(v_cust, ARRAY[v_sale], d);
    v_inv := (v_res->>'invoice_id')::uuid;
    SELECT tax_base, entry_id INTO v_tax, v_inv_je FROM invoices WHERE id = v_inv;
    IF COALESCE(v_tax, 0) <= 0 THEN
        RAISE EXCEPTION 'FIXTURE 212D 失败(空转):这张发票的销项税是 % —— 撑不起这一臂', v_tax;
    END IF;
    -- ① 清单、账龄、敞口都看得见这笔税
    SELECT open_base INTO v_y FROM ar_open_items WHERE doc_kind = 'invoice_gst' AND invoice_id = v_inv;
    IF v_y IS DISTINCT FROM v_tax THEN
        RAISE EXCEPTION 'FIXTURE 212D 失败:应收清单上这张发票的税一行是 %,应为 %', v_y, v_tax;
    END IF;
    SELECT count(*) INTO v_n FROM jsonb_array_elements(ar_aging_asof(d)->'rows') e
     WHERE e->>'doc_kind' = 'invoice_gst' AND e->>'invoice_id' = v_inv::text AND (e->>'open_base')::numeric = v_tax;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 212D 失败:账龄里这张发票的税一行出现了 % 次,应为 1', v_n;
    END IF;
    IF customer_ar_exposure_base(v_cust) <> 1000 + v_tax THEN
        RAISE EXCEPTION 'FIXTURE 212D 失败:敞口 %,应为 销售 1000 + 税 %', customer_ar_exposure_base(v_cust), v_tax;
    END IF;
    -- ② 上限就是那笔税
    v_ok := false; v_msg := NULL;
    BEGIN
        PERFORM record_payment_internal(p_direction := 'in', p_counterparty_id := v_cust,
            p_amount := v_tax + 1, p_currency := v_base, p_payment_date := d,
            p_allocations := jsonb_build_array(jsonb_build_object('invoice_id', v_inv, 'amount_doc', v_tax + 1)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_ok := (SQLERRM LIKE 'ALLOC_EXCEEDS|%');
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 212D 失败:核销到发票上的钱超过它的税应当 ALLOC_EXCEEDS,实得 %', COALESCE(v_msg, '(通过了)');
    END IF;
    -- ③ 一笔收款同时核销净额与税 → 两行都走、1100 上这一对闭合到零
    v_rcpt := record_payment_internal(p_direction := 'in', p_counterparty_id := v_cust,
        p_amount := 1000 + v_tax, p_currency := v_base, p_payment_date := d,
        p_allocations := jsonb_build_array(
            jsonb_build_object('sales_record_id', v_sale, 'amount_doc', 1000),
            jsonb_build_object('invoice_id', v_inv, 'amount_doc', v_tax)));
    SELECT journal_entry_id INTO v_rcpt_je FROM payments WHERE id = (v_rcpt->>'payment_id')::uuid;
    SELECT count(*) INTO v_n FROM ar_open_items WHERE customer_id = v_cust;
    SELECT COALESCE(sum(l.debit - l.credit), 0) INTO v_x
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id
      JOIN journal_entries e ON e.id = l.entry_id
     WHERE (e.source_id = v_sale OR e.id IN (v_inv_je, v_rcpt_je)) AND a.code = '1100';
    IF v_n <> 0 OR v_x <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 212D 失败:收齐 净额+税 之后清单上还有 % 行,1100 上还剩 %', v_n, v_x;
    END IF;
    -- ④ 对账单对得上(发生额算进了税,已核销算进了发票上的那一笔)
    v_stmt := customer_statement_data(v_cust, d, d);
    IF NOT (v_stmt->>'ties')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 212D 失败:对账单对不上,差 % —— 发票税的发生或核销漏了一边', v_stmt->>'tie_difference';
    END IF;
    IF (v_stmt->>'charges_base')::numeric <> 1000 + v_tax THEN
        RAISE EXCEPTION 'FIXTURE 212D 失败:对账单发生额 %,应为 1000 + 税 %', v_stmt->>'charges_base', v_tax;
    END IF;
    -- ⑤ 有活核销就不许作废
    v_ok := false; v_msg := NULL;
    BEGIN
        PERFORM void_invoice_internal(v_inv, 'fixture 212', d);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_ok := (SQLERRM LIKE 'INVOICE_HAS_SETTLEMENTS|%');
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 212D 失败:税已被核销的 sale 型发票应当 INVOICE_HAS_SETTLEMENTS,实得 %', COALESCE(v_msg, '(作废了)');
    END IF;
    -- ⑥ 不带税的 sale 型发票照旧不收核销(同一笔债不开第二个入口)
    v_res := record_output_sale(v_ob2, 10, 10, v_base, NULL, v_cust, d, NULL, 'manual', NULL);
    v_sale2 := (v_res->>'sale_id')::uuid;
    v_res := create_invoice(v_cust, ARRAY[v_sale2], d, NULL, NULL, NULL, 'OS');
    v_inv2 := (v_res->>'invoice_id')::uuid;
    v_ok := false; v_msg := NULL;
    BEGIN
        PERFORM record_payment_internal(p_direction := 'in', p_counterparty_id := v_cust,
            p_amount := 1, p_currency := v_base, p_payment_date := d,
            p_allocations := jsonb_build_array(jsonb_build_object('invoice_id', v_inv2, 'amount_doc', 1)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_ok := (SQLERRM LIKE 'ALLOC_INVALID|%');
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 212D 失败:不带税的 sale 型发票应当 ALLOC_INVALID,实得 %', COALESCE(v_msg, '(收下了)');
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- E · 还欠着钱的已计价收货不许注销;没计价的可以
    -- ══════════════════════════════════════════════════════════════════════
    v_res := create_inbound_batch(v_mat, v_s2, 14, 'kg', d, '待加工', 150, 'fixture 212 priced',
        p_source_reason_code => 'other', p_source_reason_note => 'fixture 212 自带数据', p_currency => v_base);
    v_b_priced := (v_res->>'batch_id')::uuid;
    v_ok := false; v_msg := NULL;
    BEGIN
        PERFORM soft_delete_inbound_batch(v_b_priced, 'fixture 212');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_ok := (SQLERRM LIKE 'INBOUND_HAS_OPEN_PAYABLE|%|2100.00');
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 212E 失败:欠着 2,100.00 的已计价收货应当 INBOUND_HAS_OPEN_PAYABLE,实得 %', COALESCE(v_msg, '(注销了)');
    END IF;
    v_res := create_inbound_batch(v_mat, v_s2, 14, 'kg', d, '待加工', NULL, 'fixture 212 bare',
        p_source_reason_code => 'other', p_source_reason_note => 'fixture 212 自带数据');
    v_b_bare := (v_res->>'batch_id')::uuid;
    PERFORM soft_delete_inbound_batch(v_b_bare, 'fixture 212');   -- ★ 非空转:闸不是"一律拒"

    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE NOTICE 'FIXTURE 212 全部通过:A 带税应付逐分等于总账并一次闭合 · A2 外币那一分钱 · B 上限扣定金 · C 代扣+税按名拒 · D 发票销项税是一项应收 · E 欠款的收货不许注销';
END $$;
ROLLBACK;
