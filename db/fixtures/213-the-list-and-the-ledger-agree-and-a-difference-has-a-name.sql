-- 213 清单与总账逐分相等,一笔差额要么有名字、要么就是"未解释"(AP-RECON-1 Batch B)
--
-- list_ledger_reconciliation() 把应付清单 ↔ 2000、应收清单 ↔ 1100【全账、不截日】比一遍。
-- 允许的差只有三种:登记的残留(list_ledger_residue,只有迁移能写)、重估(算出来的一行)、
-- 挂账的收付款(算出来的一行,冲销对两边都不算)。其余一律 unexplained,没有兜底桶。
--
-- ★ 重建出来的库上残留表是【空的】,所以这里要的是【严格相等】:每一条过账路径之后,
--   两边的 unexplained 都必须是 0.00 —— 不是"差不多",不是"在已知范围内"。
--   Tim AP-RECON-1 Q7/Q11 + Batch B:这份 fixture 是那张"证明 Batch A 修好的不会再坏"的网。
--
--   0  起点:两边都是空的,残留表是空的
--   A  应付:带价建单 · 定价(外币)· 改价 · 带税费用(本位币 / 外币)· 部分付 · 付清 ·
--      运费(外币)部分付 · 付清 · 出口运费 · 费用冲销 · 运费冲销 · 挂账付款及其冲销 ·
--      付款冲销 · 定金 → 冲抵(进料 / 费用)· 代扣 · 加工应计转应付
--   B  那一分钱(APRECON1-FOREIGN-TAXED-EXPENSE-CENT):外币单据部分结清时,核销解除的本位币
--      = 清单在这一笔之前与之后显示的差 —— 于是总账每一步都恰好等于清单,付清时恰好归零。
--      每一组数先证【非空转】:按旧式 round(核销额 × 汇率) 解除,这组数真的会差一分。
--   C  应收:销售(本位币 / 外币)部分收 · 收齐 · sale 型发票的税 · 订单发票(外币)部分收 ·
--      贷项凭证 · 收齐 · 带税的订单发票 · 作废 · 挂账收款及其冲销
--   D  重估:两边各有一行,金额就是重估分录,未解释仍是 0
--   E  ★勾稽动得开★:往 2000 打一笔 1.00 的手工分录,应付的未解释当场是 1.00;冲掉就回到 0
--   F  门:没有 data.view_prices 的人两边都按名拒(数字 NULL,不是 0);没有 finance.view 的人拒
--
-- 日期全部落在 2025 年(Tim AP-RECON-1 Batch B Q8:锚在真实的过去)。牌价自己插,精确落在
-- 用到的每一天上。期间锁、GST 开关自己设(README 第 4/5 条)。
-- 【SET CONSTRAINTS ALL IMMEDIATE】末尾强制校验一次借贷平衡(fixture 104 / 208 / 212 同款)。
BEGIN;

-- 每一步之后调它:两边都不许按名拒、残留必须是 0、未解释必须是 0.00。
-- 它住在 pg_temp,随本事务一起回滚。
CREATE FUNCTION pg_temp.f213_agree(p_step text) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE r jsonb; s jsonb;
BEGIN
    r := list_ledger_reconciliation();
    FOR s IN SELECT * FROM jsonb_array_elements(r->'sides') LOOP
        IF s->>'refusal' IS NOT NULL THEN
            RAISE EXCEPTION 'FIXTURE 213 % 失败:% 边按名拒了 %', p_step, s->>'side', s->>'refusal';
        END IF;
        IF (s->>'residue_base')::numeric <> 0 THEN
            RAISE EXCEPTION 'FIXTURE 213 % 失败:重建库上残留表应当是空的,% 边读到 %', p_step, s->>'side', s->>'residue_base';
        END IF;
        IF (s->>'unexplained_base')::numeric IS DISTINCT FROM 0 THEN
            RAISE EXCEPTION 'FIXTURE 213 % 失败:% 边 清单 % / 总账 % / 差 % / 重估 % / 挂账 % → 未解释 %',
                p_step, s->>'side', s->>'list_base', s->>'ledger_base', s->>'gap_base',
                s->>'revaluation_base', s->>'on_account_base', s->>'unexplained_base';
        END IF;
    END LOOP;
    RETURN r;
END $f$;

DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    v_user2 uuid := gen_random_uuid();
    v_user3 uuid := gen_random_uuid();
    r_all uuid; r_view uuid; r_none uuid;
    v_base text;
    D0 constant date := DATE '2025-03-03';   -- 周一:单据日
    D1 constant date := DATE '2025-03-10';   -- 周一:第一笔结算
    D2 constant date := DATE '2025-03-17';   -- 周一:第二笔结算
    DE constant date := DATE '2025-03-31';   -- 周一:期末重估
    FX constant numeric := 1.2345;
    v_s_tx uuid; v_s_goods uuid; v_fwd uuid; v_s_nr uuid; v_cust uuid;
    v_mat uuid; v_mat2 uuid; v_ob1 uuid; v_ob2 uuid; v_ob3 uuid; v_ob4 uuid;
    v_b1 uuid; v_b2 uuid; v_b3 uuid; v_ib uuid; v_run uuid; v_pce uuid;
    v_exp uuid; v_exp_usd uuid; v_exp_open uuid; v_exp_rev uuid; v_exp_wht uuid; v_exp_pp uuid;
    v_fd uuid; v_fd_rev uuid; v_xfd uuid;
    v_po uuid; v_sale uuid; v_sale_usd uuid; v_sale_open uuid; v_sale_tax uuid;
    v_inv uuid; v_so uuid; v_so2 uuid; v_so3 uuid; v_oi uuid; v_oi2 uuid; v_oi3 uuid; v_il uuid;
    v_res jsonb; v_r jsonb; v_pay uuid; v_je uuid; v_inj jsonb;
    v_x numeric; v_y numeric; v_tax numeric; v_n int; v_msg text; v_ok boolean;
BEGIN
    -- ══════════════════ 布景 ══════════════════
    INSERT INTO auth.users (id) VALUES (v_user), (v_user2), (v_user3);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-213', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-213-view', 'f', 'f', true) RETURNING id INTO r_view;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_view, 'module.finance.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user2, r_view);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-213-none', 'f', 'f', true) RETURNING id INTO r_none;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user3, r_none);

    UPDATE finance_settings SET locked_before = NULL, gst_registered = true, gst_registration_no = 'M9-FIX213-9';
    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- 牌价由系统查,不收调用方给的数(FX_RATE_NOT_ACCEPTED)—— 所以每一个用到的日子都自己插。
    -- 改价按【今天】的牌价过账,所以今天也要一行(与 D0 同价,单据的数不因跑在哪天而变)。
    UPDATE fx_rates SET deleted_at = now()
     WHERE currency = 'USD' AND deleted_at IS NULL
       AND (rate_date BETWEEN D0 - 10 AND DE OR rate_date BETWEEN CURRENT_DATE - 10 AND CURRENT_DATE);
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    SELECT 'USD', dt, rt, r
      FROM (VALUES (D0, FX), (D1, 1.30), (D2, 1.31), (DE, 1.40), (CURRENT_DATE, FX)) v(dt, r)
     CROSS JOIN (VALUES ('tt_sell'), ('tt_buy'), ('mid')) t(rt);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, default_tax_code)
    VALUES ('ZZFIX213-TX', 'fixture 213 taxed vendor', 'SG', 'active', 'service_vendor', 'TX') RETURNING id INTO v_s_tx;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, default_tax_code)
    VALUES ('ZZFIX213-G', 'fixture 213 goods supplier', 'SG', 'active', 'goods_supplier', 'ZP') RETURNING id INTO v_s_goods;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX213-F', 'fixture 213 forwarder', 'SG', 'active', 'forwarder') RETURNING id INTO v_fwd;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, default_tax_code, tax_residence)
    VALUES ('ZZFIX213-NR', 'fixture 213 non-resident', 'CN', 'active', 'service_vendor', 'ZP', 'non_resident') RETURNING id INTO v_s_nr;
    INSERT INTO customers (code, legal_name, country, default_tax_code, payment_terms_days)
    VALUES ('ZZFIX213-C', 'fixture 213 customer', 'SG', 'SR', 30) RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX213-M', 'fixture 213 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
    VALUES ('ZZFIX213-P', 'fixture 213 pack', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction') RETURNING id INTO v_mat2;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZFIX213-OB1', v_mat, 10000, 10000, D0) RETURNING id INTO v_ob1;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZFIX213-OB2', v_mat, 10000, 10000, D0) RETURNING id INTO v_ob2;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZFIX213-OB3', v_mat, 10000, 10000, D0) RETURNING id INTO v_ob3;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZFIX213-OB4', v_mat, 10000, 10000, D0) RETURNING id INTO v_ob4;

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ 0 · 起点 ══════════
    v_r := pg_temp.f213_agree('0');
    IF (v_r->'sides'->0->>'list_base')::numeric <> 0 OR (v_r->'sides'->0->>'ledger_base')::numeric <> 0
       OR (v_r->'sides'->1->>'list_base')::numeric <> 0 OR (v_r->'sides'->1->>'ledger_base')::numeric <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 213-0 前提失败:重建库上两边应当都是空的,实得 %', v_r;
    END IF;

    -- ══════════ C0 · 挂账收款(先跑)══════════
    -- 挂账收款只在未登记 GST 时收得进来;而一旦有带税码的单据,GST 就关不掉
    -- (GST_CANNOT_DISABLE_WITH_CODED_EXPENSES)—— 所以这一臂排在任何带税过账之前。
    -- 具名的一行,冲掉之后是 0。
    UPDATE finance_settings SET gst_registered = false;
    v_res := record_payment_internal('in', v_cust, 300, v_base, NULL, NULL, D1, 'f213 receipt on account', '[]'::jsonb);
    v_pay := (v_res->>'payment_id')::uuid;
    v_r := pg_temp.f213_agree('C0a 挂账收款');
    IF (v_r->'sides'->1->>'on_account_base')::numeric <> 300 THEN
        RAISE EXCEPTION 'FIXTURE 213-C0a 失败:挂账收款 300 应当是具名的一行 300,实得 %', v_r->'sides'->1->>'on_account_base';
    END IF;
    PERFORM reverse_payment_internal(v_pay, 'f213');
    v_r := pg_temp.f213_agree('C0b 挂账收款冲销');
    IF (v_r->'sides'->1->>'on_account_base')::numeric <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 213-C0b 失败:冲掉之后挂账那一行应当是 0,实得 %', v_r->'sides'->1->>'on_account_base';
    END IF;
    UPDATE finance_settings SET gst_registered = true;

    -- ══════════ A · 应付的每一条过账路径 ══════════
    v_res := create_inbound_batch(v_mat, v_s_goods, 14, 'kg', D0, '待加工', 150, 'f213 priced',
        p_source_reason_code => 'other', p_source_reason_note => 'fixture 213 自带数据', p_currency => v_base);
    v_b1 := (v_res->>'batch_id')::uuid;
    v_r := pg_temp.f213_agree('A1 带价建单');
    -- ★ 非空转:从这一步起应付两边都不是零,"相等"不再是空集上的恒真。
    IF (v_r->'sides'->0->>'ledger_base')::numeric <= 0 THEN
        RAISE EXCEPTION 'FIXTURE 213-A1 失败(空转):带价建单之后 2000 仍是 %', v_r->'sides'->0->>'ledger_base';
    END IF;

    v_res := create_inbound_batch(v_mat, v_s_goods, 33, 'kg', D0, '待加工', NULL, 'f213 bare',
        p_source_reason_code => 'other', p_source_reason_note => 'fixture 213 自带数据');
    v_b2 := (v_res->>'batch_id')::uuid;
    PERFORM set_inbound_unit_price(v_b2, 2.37, 'USD', NULL, 'f213');
    PERFORM pg_temp.f213_agree('A2 定价(外币)');
    PERFORM reprice_inbound_batch(v_b2, 3.11, 'USD', NULL, 'f213');
    PERFORM pg_temp.f213_agree('A3 改价');

    v_res := record_expense(p_expense_date := D0, p_account_code := '6400', p_amount := 100,
        p_currency := v_base, p_payment_status := 'unpaid', p_supplier_id := v_s_tx);
    v_exp := (v_res->>'expense_id')::uuid;
    PERFORM pg_temp.f213_agree('A4 带税费用(本位币)');

    -- ══════════ B · 那一分钱:外币带税费用,部分付,再付清 ══════════
    -- 净 10.04 + 税 0.90 = 10.94 USD,牌价 1.2345:总账 12.39 + 1.11 = 13.50。
    -- 先付 2.00,再付 8.94。旧式按 round(核销 × 汇率) 解除:2.47 + 11.04 = 13.51 ≠ 13.50。
    v_res := record_expense(p_expense_date := D0, p_account_code := '6400', p_amount := 10.04,
        p_currency := 'USD', p_payment_status := 'unpaid', p_supplier_id := v_s_tx);
    v_exp_usd := (v_res->>'expense_id')::uuid;
    SELECT amount_base + tax_base INTO v_x FROM expenses WHERE id = v_exp_usd;
    IF round(2.00 * FX, 2) + round(8.94 * FX, 2) = v_x THEN
        RAISE EXCEPTION 'FIXTURE 213-B 失败(空转):按旧式解除这组数恰好闭合(% = %)—— 分不开两种算法', round(2.00 * FX, 2) + round(8.94 * FX, 2), v_x;
    END IF;
    PERFORM pg_temp.f213_agree('B1 外币带税费用');
    PERFORM record_payment_internal('out', v_s_tx, 2.00, 'USD', NULL, NULL, D1, 'f213 B partial',
        jsonb_build_array(jsonb_build_object('expense_id', v_exp_usd, 'amount_doc', 2.00)));
    PERFORM pg_temp.f213_agree('B2 外币费用部分付');
    PERFORM record_payment_internal('out', v_s_tx, 8.94, 'USD', NULL, NULL, D2, 'f213 B close',
        jsonb_build_array(jsonb_build_object('expense_id', v_exp_usd, 'amount_doc', 8.94)));
    PERFORM pg_temp.f213_agree('B3 外币费用付清');
    SELECT COALESCE(sum(l.credit - l.debit), 0) INTO v_x
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id JOIN journal_entries e ON e.id = l.entry_id
     WHERE a.code = '2000' AND (e.source_id = v_exp_usd
        OR e.source_id IN (SELECT pa.payment_id FROM payment_allocations pa WHERE pa.expense_id = v_exp_usd));
    IF v_x <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 213-B3 失败:付清之后 2000 上这张单还剩 % —— 就是那一分钱', v_x;
    END IF;

    -- 运费(外币,未税):100.01 USD → 123.46;先付 50.00(旧式 61.73),再付 50.01(旧式 61.74)。
    v_res := record_freight_document(D0, v_fwd, 100.01, 'USD', 'weight', 'unpaid', NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_b1)), 'f213 freight', NULL);
    v_fd := (v_res->>'freight_document_id')::uuid;
    SELECT amount_base INTO v_x FROM freight_documents WHERE id = v_fd;
    IF round(50.00 * FX, 2) + round(50.01 * FX, 2) = v_x THEN
        RAISE EXCEPTION 'FIXTURE 213-A5 失败(空转):运费那组数按旧式恰好闭合';
    END IF;
    PERFORM pg_temp.f213_agree('A5 运费(外币)');
    PERFORM record_payment_internal('out', v_fwd, 50.00, 'USD', NULL, NULL, D1, 'f213 freight partial',
        jsonb_build_array(jsonb_build_object('freight_document_id', v_fd, 'amount_doc', 50.00)));
    PERFORM pg_temp.f213_agree('A6 运费部分付');
    PERFORM record_payment_internal('out', v_fwd, 50.01, 'USD', NULL, NULL, D2, 'f213 freight close',
        jsonb_build_array(jsonb_build_object('freight_document_id', v_fd, 'amount_doc', 50.01)));
    PERFORM pg_temp.f213_agree('A7 运费付清');

    v_res := record_export_freight_document(D0, v_fwd, 20, 'USD', 'unpaid', NULL, NULL, 'f213 export');
    v_xfd := (v_res->>'freight_document_id')::uuid;
    PERFORM pg_temp.f213_agree('A8 出口运费');
    PERFORM record_payment_internal('out', v_fwd, 20, 'USD', NULL, NULL, D1, 'f213 export pay',
        jsonb_build_array(jsonb_build_object('freight_document_id', v_xfd, 'amount_doc', 20)));
    PERFORM pg_temp.f213_agree('A9 出口运费付清');

    v_res := record_expense(p_expense_date := D0, p_account_code := '6400', p_amount := 70,
        p_currency := v_base, p_payment_status := 'unpaid', p_supplier_id := v_s_goods);
    v_exp_rev := (v_res->>'expense_id')::uuid;
    PERFORM reverse_expense(v_exp_rev, 'f213');
    PERFORM pg_temp.f213_agree('A10 费用冲销');

    v_res := record_freight_document(D0, v_fwd, 40, v_base, 'weight', 'unpaid', NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_b1)), 'f213 freight to reverse', NULL);
    v_fd_rev := (v_res->>'freight_document_id')::uuid;
    PERFORM reverse_freight_document(v_fd_rev, 'f213');
    PERFORM pg_temp.f213_agree('A11 运费冲销');

    -- 挂账付款:具名的一行,金额就是它;冲掉之后那一行是 0(冲销对两边都不算)
    v_res := record_payment_internal('out', v_s_goods, 500, v_base, NULL, NULL, D1, 'f213 on account',
        '[]'::jsonb, 'supplier');
    v_pay := (v_res->>'payment_id')::uuid;
    v_r := pg_temp.f213_agree('A12 挂账付款');
    IF (v_r->'sides'->0->>'on_account_base')::numeric <> 500 THEN
        RAISE EXCEPTION 'FIXTURE 213-A12 失败:挂账付款 500 应当是具名的一行 500,实得 %', v_r->'sides'->0->>'on_account_base';
    END IF;
    PERFORM reverse_payment_internal(v_pay, 'f213');
    v_r := pg_temp.f213_agree('A13 挂账付款冲销');
    IF (v_r->'sides'->0->>'on_account_base')::numeric <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 213-A13 失败:冲掉之后挂账那一行应当是 0,实得 % —— 冲销件被读成了挂账', v_r->'sides'->0->>'on_account_base';
    END IF;

    v_res := record_payment_internal('out', v_s_tx, 109, v_base, NULL, NULL, D1, 'f213 pay then reverse',
        jsonb_build_array(jsonb_build_object('expense_id', v_exp, 'amount_doc', 109)));
    PERFORM pg_temp.f213_agree('A14 付款');
    PERFORM reverse_payment_internal((v_res->>'payment_id')::uuid, 'f213');
    PERFORM pg_temp.f213_agree('A15 付款冲销');

    -- 定金 → 冲抵
    v_res := create_purchase_order(v_s_goods, D0, D2, v_base, NULL, NULL, NULL, 'f213 PO',
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100, 'unit', 'kg',
                                             'estimated_unit_price', 20)));
    v_po := (v_res->>'purchase_order_id')::uuid;
    PERFORM record_payment_internal('out', v_s_goods, 1000, v_base, NULL, NULL, D0, 'f213 deposit',
        jsonb_build_array(jsonb_build_object('purchase_order_id', v_po, 'amount_doc', 1000)), 'supplier');
    PERFORM pg_temp.f213_agree('A16 定金');
    v_res := create_inbound_batch(v_mat, v_s_goods, 100, 'kg', D0, '待加工', 20, 'f213 PO batch',
        v_po, (SELECT id FROM purchase_order_lines WHERE purchase_order_id = v_po), NULL, NULL, p_source_reason_code => 'other', p_source_reason_note => 'fixture 213 自带数据',
        p_currency => v_base);
    v_b3 := (v_res->>'batch_id')::uuid;
    PERFORM apply_prepayment(v_po, v_b3, 600, NULL, NULL, D1);
    PERFORM pg_temp.f213_agree('A17 定金冲抵进料');
    v_res := record_expense(p_expense_date := D0, p_account_code := '6400', p_amount := 300,
        p_currency := v_base, p_payment_status := 'unpaid', p_supplier_id := v_s_goods);
    v_exp_pp := (v_res->>'expense_id')::uuid;
    PERFORM apply_prepayment(v_po, NULL, 200, NULL, v_exp_pp, D1);
    PERFORM pg_temp.f213_agree('A18 定金冲抵费用');

    -- 代扣:付给非居民,债全额解除、钱只走净额
    v_res := record_expense(p_expense_date := D0, p_account_code := '6400', p_amount := 1000,
        p_currency := v_base, p_payment_status := 'unpaid', p_supplier_id := v_s_nr,
        p_wht_nature := 'technical_service_fee', p_tax_code := 'ZP');
    v_exp_wht := (v_res->>'expense_id')::uuid;
    SELECT wht_amount_ccy INTO v_x FROM expenses WHERE id = v_exp_wht;
    IF COALESCE(v_x, 0) <= 0 THEN
        RAISE EXCEPTION 'FIXTURE 213-A19 失败(空转):这张单没有要代扣的数(%)', v_x;
    END IF;
    PERFORM record_payment_internal('out', v_s_nr, 1000 - v_x, v_base, NULL, NULL, D1, 'f213 wht',
        jsonb_build_array(jsonb_build_object('expense_id', v_exp_wht, 'amount_doc', 1000)));
    PERFORM pg_temp.f213_agree('A19 代扣付款');

    -- 加工应计 → 应付(挂账给供应商)
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date,
        source_reason_code, source_reason_note)
    VALUES ('ZZFIX213-IB', v_mat2, v_s_goods, 100, 100, 'kg', D0 - 1, 'other', 'fixture 213 自带数据') RETURNING id INTO v_ib;
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) VALUES (v_ib, 'discharged_verified');
    PERFORM reprice_inbound_batch(v_ib, 5, v_base, NULL, 'f213');
    v_run := commit_processing_run(D0, 'f213 放电', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
        '[]'::jsonb, 'weight', NULL, NULL, 'deep_discharge');
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate)
    VALUES (v_run, 'electricity', 400, true) RETURNING id INTO v_pce;
    PERFORM relieve_processing_accruals(ARRAY[v_pce], 450, D1, 'unpaid', NULL, v_s_tx, NULL, 'f213 relief');
    PERFORM pg_temp.f213_agree('A20 加工应计转应付');

    -- 留一张外币费用开着,给 D 的重估用
    v_res := record_expense(p_expense_date := D0, p_account_code := '6400', p_amount := 50,
        p_currency := 'USD', p_payment_status := 'unpaid', p_supplier_id := v_s_goods);
    v_exp_open := (v_res->>'expense_id')::uuid;
    PERFORM pg_temp.f213_agree('A21 外币费用(留着)');

    -- ══════════ C · 应收的每一条过账路径 ══════════
    v_res := record_output_sale(v_ob1, 10, 100, v_base, NULL, v_cust, D0, 'f213', 'manual', NULL);
    v_sale := (v_res->>'sale_id')::uuid;
    v_r := pg_temp.f213_agree('C1 销售(本位币)');
    IF (v_r->'sides'->1->>'ledger_base')::numeric <= 0 THEN
        RAISE EXCEPTION 'FIXTURE 213-C1 失败(空转):销售之后 1100 仍是 %', v_r->'sides'->1->>'ledger_base';
    END IF;

    -- 外币销售 100.01 USD,部分收 50.00,再收齐 50.01(与运费同一组数,旧式差一分)
    v_res := record_output_sale(v_ob2, 1, 100.01, 'USD', NULL, v_cust, D0, 'f213 usd', 'manual', NULL);
    v_sale_usd := (v_res->>'sale_id')::uuid;
    PERFORM pg_temp.f213_agree('C2 外币销售');
    -- 收款须核销到单据上(GST 已登记,挂账收款按名拒)
    PERFORM record_payment_internal('in', v_cust, 50.00, 'USD', NULL, NULL, D1, 'f213 receipt partial',
        jsonb_build_array(jsonb_build_object('sales_record_id', v_sale_usd, 'amount_doc', 50.00)));
    PERFORM pg_temp.f213_agree('C3 外币销售部分收');
    PERFORM record_payment_internal('in', v_cust, 50.01, 'USD', NULL, NULL, D2, 'f213 receipt close',
        jsonb_build_array(jsonb_build_object('sales_record_id', v_sale_usd, 'amount_doc', 50.01)));
    PERFORM pg_temp.f213_agree('C4 外币销售收齐');

    -- sale 型发票:税是它自己的一项应收
    v_res := record_output_sale(v_ob3, 10, 10, v_base, NULL, v_cust, D0, 'f213 taxed', 'manual', NULL);
    v_sale_tax := (v_res->>'sale_id')::uuid;
    v_res := create_invoice(v_cust, ARRAY[v_sale_tax], D0);
    v_inv := (v_res->>'invoice_id')::uuid;
    SELECT tax_base INTO v_tax FROM invoices WHERE id = v_inv;
    IF COALESCE(v_tax, 0) <= 0 THEN
        RAISE EXCEPTION 'FIXTURE 213-C5 失败(空转):这张发票的税是 %', v_tax;
    END IF;
    PERFORM pg_temp.f213_agree('C5 sale 型发票');
    PERFORM record_payment_internal('in', v_cust, 100 + v_tax, v_base, NULL, NULL, D1, 'f213 receipt taxed',
        jsonb_build_array(jsonb_build_object('sales_record_id', v_sale_tax, 'amount_doc', 100),
                          jsonb_build_object('invoice_id', v_inv, 'amount_doc', v_tax)));
    PERFORM pg_temp.f213_agree('C6 净额与税一起收');

    -- 订单发票(外币,零税率):部分收 → 贷项凭证 → 收齐
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(D0), v_cust, D0, 'USD', FX) RETURNING id INTO v_so;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (v_so, 1, v_mat, 10, 10.01);
    PERFORM set_sales_order_status(v_so, 'confirmed');
    v_res := create_order_invoice(v_so, D0, NULL, NULL, NULL, NULL, 'ZR');
    v_oi := (v_res->>'invoice_id')::uuid;
    SELECT id INTO v_il FROM invoice_lines WHERE invoice_id = v_oi;
    PERFORM pg_temp.f213_agree('C7 订单发票(外币)');
    PERFORM record_payment_internal('in', v_cust, 40.00, 'USD', NULL, NULL, D1, 'f213 order partial',
        jsonb_build_array(jsonb_build_object('invoice_id', v_oi, 'amount_doc', 40.00)));
    PERFORM pg_temp.f213_agree('C8 订单发票部分收');
    PERFORM create_credit_note_internal(v_oi, D1, 'f213 短装',
        jsonb_build_array(jsonb_build_object('invoice_line_id', v_il, 'kind', 'unshipped_cancel',
                                             'qty', 1, 'amount', 10.01)));
    PERFORM pg_temp.f213_agree('C9 贷项凭证');
    SELECT open_ccy INTO v_x FROM order_invoice_balance_all WHERE invoice_id = v_oi;
    PERFORM record_payment_internal('in', v_cust, v_x, 'USD', NULL, NULL, D2, 'f213 order close',
        jsonb_build_array(jsonb_build_object('invoice_id', v_oi, 'amount_doc', v_x)));
    PERFORM pg_temp.f213_agree('C10 订单发票收齐');

    -- 带税的订单发票(本位币,SR)
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(D0), v_cust, D0, v_base, 1) RETURNING id INTO v_so2;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (v_so2, 1, v_mat, 10, 20);
    PERFORM set_sales_order_status(v_so2, 'confirmed');
    v_res := create_order_invoice(v_so2, D0, NULL, NULL, NULL, NULL, 'SR');
    v_oi2 := (v_res->>'invoice_id')::uuid;
    SELECT tax_base INTO v_tax FROM invoices WHERE id = v_oi2;
    IF COALESCE(v_tax, 0) <= 0 THEN
        RAISE EXCEPTION 'FIXTURE 213-C11 失败(空转):这张订单发票的税是 %', v_tax;
    END IF;
    PERFORM pg_temp.f213_agree('C11 带税的订单发票');
    -- 清单认的是 净额 + 税(Tim Batch B 追加裁定:与费用单同一条)
    SELECT open_ccy INTO v_x FROM ar_open_items WHERE doc_kind = 'invoice' AND invoice_id = v_oi2;
    IF v_x IS DISTINCT FROM 200 + v_tax THEN
        RAISE EXCEPTION 'FIXTURE 213-C11 失败:带税订单发票清单上应当欠 净额 200 + 税 %,实得 %', v_tax, v_x;
    END IF;
    PERFORM record_payment_internal('in', v_cust, 50, v_base, NULL, NULL, D1, 'f213 taxed order partial',
        jsonb_build_array(jsonb_build_object('invoice_id', v_oi2, 'amount_doc', 50)));
    PERFORM pg_temp.f213_agree('C11a 带税订单发票部分收');
    PERFORM create_credit_note_internal(v_oi2, D1, 'f213 taxed cn',
        jsonb_build_array(jsonb_build_object('invoice_line_id', (SELECT id FROM invoice_lines WHERE invoice_id = v_oi2),
                                             'kind', 'unshipped_cancel', 'qty', 1, 'amount', 20)));
    PERFORM pg_temp.f213_agree('C11b 带税的贷项凭证');
    SELECT open_ccy INTO v_x FROM order_invoice_balance_all WHERE invoice_id = v_oi2;
    -- ★ 非空转:上限就是 净额 + 税 −已收 −已贷记(含税)。多一分必须拒。
    v_ok := false; v_msg := NULL;
    BEGIN
        PERFORM record_payment_internal('in', v_cust, v_x + 0.01, v_base, NULL, NULL, D2, 'f213 over',
            jsonb_build_array(jsonb_build_object('invoice_id', v_oi2, 'amount_doc', v_x + 0.01)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_ok := (SQLERRM LIKE 'ALLOC_EXCEEDS|%');
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 213-C11c 失败:超过开放余额一分应当 ALLOC_EXCEEDS,实得 %', COALESCE(v_msg, '(收下了)');
    END IF;
    PERFORM record_payment_internal('in', v_cust, v_x, v_base, NULL, NULL, D2, 'f213 taxed order close',
        jsonb_build_array(jsonb_build_object('invoice_id', v_oi2, 'amount_doc', v_x)));
    PERFORM pg_temp.f213_agree('C11c 带税订单发票收齐');
    SELECT COALESCE(sum(l.debit - l.credit), 0) INTO v_x
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id JOIN journal_entries e ON e.id = l.entry_id
     WHERE a.code = '1100' AND (e.id = (SELECT entry_id FROM invoices WHERE id = v_oi2)
        OR e.id IN (SELECT entry_id FROM credit_notes WHERE invoice_id = v_oi2)
        OR e.source_id IN (SELECT pa.payment_id FROM payment_allocations pa WHERE pa.invoice_id = v_oi2));
    IF v_x <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 213-C11c 失败:收齐之后 1100 上这张发票还剩 % —— 那笔税', v_x;
    END IF;

    -- 外币带税订单发票:部分收 → 带税贷项凭证 → 收齐(三步都要逐分相等)
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(D0), v_cust, D0, 'USD', FX) RETURNING id INTO v_so2;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (v_so2, 1, v_mat, 7, 13.37);
    PERFORM set_sales_order_status(v_so2, 'confirmed');
    v_res := create_order_invoice(v_so2, D0, NULL, NULL, NULL, NULL, 'SR');
    v_oi2 := (v_res->>'invoice_id')::uuid;
    PERFORM pg_temp.f213_agree('C11d 外币带税订单发票');
    PERFORM record_payment_internal('in', v_cust, 33.33, 'USD', NULL, NULL, D1, 'f213 usd taxed partial',
        jsonb_build_array(jsonb_build_object('invoice_id', v_oi2, 'amount_doc', 33.33)));
    PERFORM pg_temp.f213_agree('C11e 外币带税订单发票部分收');
    PERFORM create_credit_note_internal(v_oi2, D1, 'f213 usd taxed cn',
        jsonb_build_array(jsonb_build_object('invoice_line_id', (SELECT id FROM invoice_lines WHERE invoice_id = v_oi2),
                                             'kind', 'unshipped_cancel', 'qty', 1, 'amount', 13.37)));
    PERFORM pg_temp.f213_agree('C11f 外币带税贷项凭证');
    SELECT open_ccy INTO v_x FROM order_invoice_balance_all WHERE invoice_id = v_oi2;
    PERFORM record_payment_internal('in', v_cust, v_x, 'USD', NULL, NULL, D2, 'f213 usd taxed close',
        jsonb_build_array(jsonb_build_object('invoice_id', v_oi2, 'amount_doc', v_x)));
    PERFORM pg_temp.f213_agree('C11g 外币带税订单发票收齐');

    -- 作废一张没收过钱的订单发票
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(D0), v_cust, D0, v_base, 1) RETURNING id INTO v_so3;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (v_so3, 1, v_mat, 5, 20);
    PERFORM set_sales_order_status(v_so3, 'confirmed');
    v_res := create_order_invoice(v_so3, D0, NULL, NULL, NULL, NULL, 'ZR');
    v_oi3 := (v_res->>'invoice_id')::uuid;
    PERFORM void_invoice_internal(v_oi3, 'f213', D1);
    PERFORM pg_temp.f213_agree('C12 作废订单发票');


    -- 留一张外币销售开着,给 D 的重估用
    PERFORM record_output_sale(v_ob4, 3, 33.33, 'USD', NULL, v_cust, D0, 'f213 usd open', 'manual', NULL);
    PERFORM pg_temp.f213_agree('C15 外币销售(留着)');

    -- ══════════ D · 重估:两边各有一行,未解释仍是 0 ══════════
    PERFORM revalue_foreign_balances(DE);
    v_r := pg_temp.f213_agree('D 重估');
    IF (v_r->'sides'->0->>'revaluation_base')::numeric = 0 OR (v_r->'sides'->1->>'revaluation_base')::numeric = 0 THEN
        RAISE EXCEPTION 'FIXTURE 213-D 失败(空转):重估之后两边都应当有一条非零的重估行,实得 应付 % / 应收 %',
            v_r->'sides'->0->>'revaluation_base', v_r->'sides'->1->>'revaluation_base';
    END IF;

    -- 账龄(截至今天)与清单是同一个数的两个读法;对账单(D0 → 今天)按构造对得上
    SELECT (ap_aging_asof(CURRENT_DATE)->>'total_open_base')::numeric,
           (ar_aging_asof(CURRENT_DATE)->>'total_open_base')::numeric INTO v_x, v_y;
    IF v_x IS DISTINCT FROM (v_r->'sides'->0->>'list_base')::numeric
       OR v_y IS DISTINCT FROM (v_r->'sides'->1->>'list_base')::numeric THEN
        RAISE EXCEPTION 'FIXTURE 213-D 失败:账龄(今天)应付 % / 应收 %,清单 % / %',
            v_x, v_y, v_r->'sides'->0->>'list_base', v_r->'sides'->1->>'list_base';
    END IF;
    v_res := customer_statement_data(v_cust, D0, CURRENT_DATE);
    IF NOT (v_res->>'ties')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 213-D 失败:这位客户的对账单对不上,差 % —— 发生 / 贷记 / 核销有一项没按总账口径', v_res->>'tie_difference';
    END IF;

    -- ══════════ E · ★勾稽动得开★ ══════════
    v_inj := post_journal_entry(D1, 'f213 manual into 2000', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code', '2000', 'side', 'debit', 'currency', v_base, 'amount_ccy', 1.00),
        jsonb_build_object('account_code', '1000', 'side', 'credit', 'currency', v_base, 'amount_ccy', 1.00)));
    v_r := list_ledger_reconciliation();
    IF (v_r->'sides'->0->>'unexplained_base')::numeric IS DISTINCT FROM 1.00
       OR (v_r->'sides'->1->>'unexplained_base')::numeric IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'FIXTURE 213-E 失败:往 2000 打一笔 1.00 的手工分录,应付未解释应当是 1.00、应收是 0,实得 % / %',
            v_r->'sides'->0->>'unexplained_base', v_r->'sides'->1->>'unexplained_base';
    END IF;
    IF (v_r->'sides'->0->>'agrees')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 213-E 失败:未解释 1.00 时 agrees 仍是 true';
    END IF;
    PERFORM reverse_journal_entry((v_inj->>'entry_id')::uuid, D1, 'f213');
    PERFORM pg_temp.f213_agree('E 冲掉之后');

    -- ══════════ F · 门 ══════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_user2), true);
    v_r := list_ledger_reconciliation();
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_r->'sides') s
     WHERE s->>'refusal' = 'PRICES_RESTRICTED' AND s->'list_base' = 'null'::jsonb
       AND s->'ledger_base' = 'null'::jsonb AND s->'unexplained_base' = 'null'::jsonb;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 213-F 失败:没有 data.view_prices 的人两边都应当按名拒、数字为 NULL(不是 0),实得 %', v_r;
    END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_user3), true);
    v_ok := false; v_msg := NULL;
    BEGIN
        PERFORM list_ledger_reconciliation();
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_ok := (SQLERRM = 'PERMISSION_DENIED|module.finance.view');
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 213-F 失败:没有 module.finance.view 的人应当 PERMISSION_DENIED,实得 %', COALESCE(v_msg, '(读到了)');
    END IF;
    IF has_table_privilege('anon', 'public.list_ledger_residue', 'SELECT')
       OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.list_ledger_residue'::regclass AND polcmd <> 'r') THEN
        RAISE EXCEPTION 'FIXTURE 213-F 失败:残留表只许迁移写 —— 不许有写策略,anon 不许读';
    END IF;

    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE NOTICE 'FIXTURE 213 全部通过:0 起点 · A 应付 21 条路径逐步严格相等 · B 外币部分付那一分钱 · C 应收 22 条路径(含带税订单发票、外币带税贷项凭证) · D 重估是具名的一行 · E 手工分录让它当场不为零 · F 两道门';
END $$;
ROLLBACK;
