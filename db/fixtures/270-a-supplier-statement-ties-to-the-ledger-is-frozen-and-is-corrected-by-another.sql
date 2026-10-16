-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 270 —— 一份供应商对账单对得上应付总账才签得出来、签出来就冻住、更正是另起一份;它的 PDF 签发档只追加
--   (MES-8a,2026-10-16;MES-0 Q79;MES-8 Step 0 Q7 · Q8 · Q9 · Q21–Q24,Tim)
-- ═══════════════════════════════════════════════════════════════════════════
-- 臂:
--   GATE    读 module.finance.view;没有采购价的码 → SUPPLIER_STATEMENT_PRICES_RESTRICTED(一张金额被遮的清单对不了总账);没有收货的查看码 →
--           SUPPLIER_STATEMENT_RECEIPTS_RESTRICTED(收货整支看不见,清单同样残缺);签发与记 PDF 要
--           module.finance.edit;会话里直连写对账单与签发档 → RLS 拒
--   PERIOD  期间必填 / 不倒置 / 不在未来 —— 各自按名拒;员工的 id 不是供应商 → SUPPLIER_NOT_FOUND(员工永远不会有一份)
--   LINES   期初(期间之前的一张挂账费用单)· 发生(暂定价收货 · 另一张收货 · 一张费用单)· 付款(一笔核销、一笔挂账)· 预付冲抵 · 期末;
--           每一笔明细的种类、单据号、金额、暂定价标记;期末未结单据;挂账的付款;【已收到、尚未计价】的收货只有数量、不计金额;
--           这一家之外的单据(别家的收货、员工的报销)一行都不进来;期初 + 发生 − 贷记 − 付款 − 预付冲抵 = 期末
--   TIE     期末(总账 2000 归到这一家)= 期末未结 − 挂账 − 残留,ties = true;每一步之后 AP 清单 = 总账、未解释 0.00
--   ISSUE   签发:SST-年-NNNN;冻下的数与明细、收件人与抬头 = 那一刻的预览;之后再来一张收货,这一份一个字不动
--   NOTIE   给这一家的总账多记一分(一张不经单据的 purchase 分录)→ SUPPLIER_STATEMENT_DOES_NOT_TIE,什么都没写;撤掉之后照常
--   SUPER   同一段期间再签:没理由 → SUPPLIER_STATEMENT_SUPERSEDE_REASON_REQUIRED;带理由 → 新号,旧的落 superseded_* 与理由;
--           一段还没签过的期间(另一家)带理由 → SUPPLIER_STATEMENT_REASON_WITHOUT_SUPERSEDE;签发了的对账单改与删 → SUPPLIER_STATEMENT_IMMUTABLE
--   NUM     号推过 9,999 不截断:SST-年-9999 之后是 10000,再之后是 10001(按数比,不按字比)
--   PDF     记一版 PDF:路径不在对账单目录下 · 哈希不是 64 位十六进制 —— 按名拒;大写哈希存成小写;同一串字节再记 →
--           SUPPLIER_STATEMENT_BYTES_ALREADY_RECORDED;另一串 → 第 2 版;被取代的那一份 → SUPPLIER_STATEMENT_SUPERSEDED;签发档改与删按名拒
--   (PDF 只从冻下来的那一行渲染、取档重算哈希、对不上 409 —— 那是路由的行为,由 scripts/check-pdf-routes.mjs 的 SST 三格管;桶在线上证明里)
--
-- 自带数据(README 第 2 条);期间锁自己设;直接调引擎(record_payment_internal / record_expense / create_inbound_batch)—— 审批那一半不在这里。
-- 全部判定写成 IF (…) IS NOT FALSE —— 一个 NULL 也是红。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f270_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

CREATE FUNCTION pg_temp.f270_do(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM pg_temp.f270_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f270_as(NULL);
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f270_as(NULL);
    RETURN SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f270_get(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.f270_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f270_as(NULL);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f270_as(NULL);
    RAISE;
END;
$f$;

CREATE FUNCTION pg_temp.f270_user(p_label text, p_codes text[]) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE u uuid := gen_random_uuid(); r uuid;
BEGIN
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES (u, 'fx270-' || p_label || '@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx270-' || p_label, 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r, c FROM unnest(p_codes) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);
    RETURN u;
END;
$f$;

CREATE FUNCTION pg_temp.f270_expect(p_arm text, p_got text, p_like text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    IF (p_got IS NULL OR p_got NOT LIKE p_like) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 270 % expected % got %', p_arm, p_like, COALESCE(p_got, '<null>');
    END IF;
END;
$f$;

-- 每一个财务步骤之后:应付清单 = 总账(加上具名项),未解释 0.00(fixture 213 的 f213_agree,AP 那一侧)
CREATE FUNCTION pg_temp.f270_agree(p_step text) RETURNS void
LANGUAGE plpgsql AS $f$
DECLARE v jsonb := list_ledger_reconciliation(); s jsonb;
BEGIN
    SELECT x INTO s FROM jsonb_array_elements(v -> 'sides') x WHERE x ->> 'side' = 'ap';
    IF ((s ->> 'unexplained_base')::numeric <> 0 OR (s ->> 'agrees')::boolean IS NOT TRUE) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 270 TIE [%]: AP list and ledger must agree with 0.00 unexplained, got %', p_step, s; END IF;
END;
$f$;

DO $$
DECLARE
    u_all uuid; u_fv uuid; u_fe uuid; u_np uuid; u_ni uuid; u_none uuid;
    v_base text; v_year text := EXTRACT(YEAR FROM CURRENT_DATE)::text;
    PS date := CURRENT_DATE - 30; PE date := CURRENT_DATE;   -- 收货的计价分录与价格历史都落在【今天】,所以期间要含今天(AGING-1:截至昨天它还没有价)
    s1 uuid; s2 uuid; v_mat uuid; e1 uuid; v_po uuid;
    r0 uuid; r1 uuid; r2 uuid; r3 uuid; r_other uuid; x1 uuid; x_emp uuid; p1 uuid; p2 uuid;
    v_d jsonb; v_d2 jsonb; v_j jsonb; v_r jsonb; v_msg text; v_n bigint; v_txt text;
    st1 uuid; st2 uuid; st_code1 text; v_row supplier_statements%ROWTYPE;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    PERFORM pg_temp.f270_as(NULL);
    UPDATE finance_settings SET locked_before = NULL, gst_registered = false;
    UPDATE company_profile SET legal_name = 'Fixture 270 Recovery Pte. Ltd.', address_lines = '1 Ledger Road', city = 'Singapore';

    u_all  := pg_temp.f270_user('all', ARRAY(SELECT code FROM permissions));
    u_fv   := pg_temp.f270_user('fv', ARRAY['module.finance.view', 'data.view_purchase_prices', 'module.inbound.view']);
    u_fe   := pg_temp.f270_user('fe', ARRAY['module.finance.view', 'module.finance.edit', 'data.view_purchase_prices', 'module.inbound.view']);
    u_np   := pg_temp.f270_user('np', ARRAY['module.finance.view', 'module.inbound.view']);
    u_ni   := pg_temp.f270_user('ni', ARRAY['module.finance.view', 'data.view_purchase_prices']);
    u_none := pg_temp.f270_user('none', ARRAY['module.suppliers.view']);
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type) VALUES
        ('FX270-S1', 'Fixture 270 Statement Supplier', 'SG', 'active', 'goods_supplier'),
        ('FX270-S2', 'Fixture 270 Other Supplier', 'SG', 'active', 'goods_supplier');
    SELECT id INTO s1 FROM suppliers WHERE code = 'FX270-S1';
    SELECT id INTO s2 FROM suppliers WHERE code = 'FX270-S2';
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('FX270-M', 'fixture 270 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    e1 := gen_random_uuid();
    INSERT INTO employees (id, code, legal_name, preferred_name, employment_type, work_category, hire_date)
    VALUES (e1, 'FX270-E1', 'fixture 270 claimant', 'Claim', 'full_time', 'office', DATE '2020-01-01');

    PERFORM pg_temp.f270_as(u_all);
    -- 期初:期间之前一张挂账的费用单(500)—— 收货的计价分录记在计价那一天(今天),落不到期间之前,所以期初用一张费用单
    v_r := record_expense(p_expense_date := PS - 5, p_account_code := '6400', p_amount := 500, p_currency := v_base,
                          p_payment_status := 'unpaid', p_supplier_id := s1);
    r0 := (v_r ->> 'expense_id')::uuid;
    PERFORM pg_temp.f270_agree('opening expense');
    -- 期间里:一张暂定价的收货(20 × 30 = 600)
    v_r := create_inbound_batch(v_mat, s1, 20, 'kg', PS + 2, '待加工', 30, 'f270 provisional', p_source_reason_code => 'other',
                                p_source_reason_note => 'fixture 270 自带数据', p_currency => v_base);
    r1 := (v_r ->> 'batch_id')::uuid;
    PERFORM pg_temp.f270_agree('provisional receipt');
    -- 一张挂单的收货(下面拿定金冲抵它):先建采购单、付定金
    v_r := create_purchase_order(s1, PS, PE, v_base, NULL, NULL, NULL, 'f270 PO',
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 40, 'unit', 'kg', 'estimated_unit_price', 25)), p_category => 'equipment_goods');
    v_po := (v_r ->> 'purchase_order_id')::uuid;
    PERFORM record_payment_internal('out', s1, 300, v_base, NULL, NULL, PS + 1, 'f270 deposit',
        jsonb_build_array(jsonb_build_object('purchase_order_id', v_po, 'amount_doc', 300)), 'supplier');
    PERFORM pg_temp.f270_agree('deposit');
    v_r := create_inbound_batch(v_mat, s1, 40, 'kg', PS + 3, '待加工', 25, 'f270 PO receipt', v_po,
        (SELECT id FROM purchase_order_lines WHERE purchase_order_id = v_po), NULL, NULL, p_source_reason_code => 'other',
        p_source_reason_note => 'fixture 270 自带数据', p_currency => v_base);
    r2 := (v_r ->> 'batch_id')::uuid;
    PERFORM pg_temp.f270_agree('PO receipt');
    PERFORM apply_prepayment(v_po, r2, 300, NULL, NULL, PS + 4);
    PERFORM pg_temp.f270_agree('prepayment applied');
    -- 一张已收到、还没计价的收货(只有数量)
    v_r := create_inbound_batch(v_mat, s1, 77, 'kg', PS + 5, '待加工', NULL, 'f270 unpriced', p_source_reason_code => 'other',
                                p_source_reason_note => 'fixture 270 自带数据', p_currency => v_base);
    r3 := (v_r ->> 'batch_id')::uuid;
    -- 一张费用单(挂账 200)
    v_r := record_expense(p_expense_date := PS + 6, p_account_code := '6400', p_amount := 200, p_currency := v_base,
                          p_payment_status := 'unpaid', p_supplier_id := s1);
    x1 := (v_r ->> 'expense_id')::uuid;
    PERFORM pg_temp.f270_agree('expense');
    -- 一笔核销暂定价那张收货的付款(250)与一笔挂账的付款(100)
    v_r := record_payment_internal('out', s1, 250, v_base, NULL, NULL, PS + 7, 'f270 pay r1',
        jsonb_build_array(jsonb_build_object('inbound_batch_id', r1, 'amount_doc', 250)));
    p1 := (v_r ->> 'payment_id')::uuid;
    PERFORM pg_temp.f270_agree('payment applied');
    v_r := record_payment_internal('out', s1, 100, v_base, NULL, NULL, PS + 8, 'f270 on account', '[]'::jsonb, 'supplier');
    p2 := (v_r ->> 'payment_id')::uuid;
    PERFORM pg_temp.f270_agree('payment on account');
    -- 不归这一家的:别家的一张收货、一名员工的报销
    v_r := create_inbound_batch(v_mat, s2, 5, 'kg', PS + 2, '待加工', 99, 'f270 other supplier', p_source_reason_code => 'other',
                                p_source_reason_note => 'fixture 270 自带数据', p_currency => v_base);
    r_other := (v_r ->> 'batch_id')::uuid;
    v_r := record_expense(p_expense_date := PS + 6, p_account_code := '6400', p_amount := 42, p_currency := v_base,
                          p_payment_status := 'unpaid', p_employee_id := e1);
    x_emp := (v_r ->> 'expense_id')::uuid;
    PERFORM pg_temp.f270_agree('other supplier and an employee claim');
    PERFORM pg_temp.f270_as(NULL);

    -- ══════════════ GATE ══════════════
    RAISE NOTICE 'fixture 270 · GATE';
    PERFORM pg_temp.f270_expect('GATE', pg_temp.f270_do(u_none, format($q$SELECT supplier_statement_data(%L, %L, %L)$q$, s1, PS, PE)), 'PERMISSION_DENIED|module.finance.view');
    PERFORM pg_temp.f270_expect('GATE', pg_temp.f270_do(u_np, format($q$SELECT supplier_statement_data(%L, %L, %L)$q$, s1, PS, PE)), 'SUPPLIER_STATEMENT_PRICES_RESTRICTED');
    PERFORM pg_temp.f270_expect('GATE', pg_temp.f270_do(u_ni, format($q$SELECT supplier_statement_data(%L, %L, %L)$q$, s1, PS, PE)), 'SUPPLIER_STATEMENT_RECEIPTS_RESTRICTED');
    PERFORM pg_temp.f270_expect('GATE', pg_temp.f270_do(u_fv, format($q$SELECT issue_supplier_statement(%L, %L, %L)$q$, s1, PS, PE)), 'PERMISSION_DENIED|module.finance.edit');
    PERFORM pg_temp.f270_expect('GATE', pg_temp.f270_do(u_fe, format($q$INSERT INTO supplier_statements (code, supplier_id, supplier_code, supplier_name, company, period_start, period_end, base_currency, opening_base, charges_base, credits_base, payments_base, prepayments_base, closing_base, list_base, on_account_base, residue_base, lines, open_items, on_account, unpriced, by_currency) VALUES ('X', %L, 'x', 'x', '{"legal_name":"x"}', %L, %L, %L, 0, 0, 0, 0, 0, 0, 0, 0, 0, '[]', '[]', '[]', '[]', '[]')$q$, s1, PS, PE, v_base)), '%row-level security%');

    -- ══════════════ PERIOD ══════════════
    RAISE NOTICE 'fixture 270 · PERIOD';
    PERFORM pg_temp.f270_expect('PERIOD', pg_temp.f270_do(u_fv, format($q$SELECT supplier_statement_data(%L, NULL, %L)$q$, s1, PE)), 'SUPPLIER_STATEMENT_PERIOD_REQUIRED');
    PERFORM pg_temp.f270_expect('PERIOD', pg_temp.f270_do(u_fv, format($q$SELECT supplier_statement_data(%L, %L, %L)$q$, s1, PE, PS)), 'SUPPLIER_STATEMENT_PERIOD_INVALID|%');
    PERFORM pg_temp.f270_expect('PERIOD', pg_temp.f270_do(u_fv, format($q$SELECT supplier_statement_data(%L, %L, %L)$q$, s1, PS, CURRENT_DATE + 3)), 'SUPPLIER_STATEMENT_PERIOD_FUTURE|%');
    PERFORM pg_temp.f270_expect('PERIOD', pg_temp.f270_do(u_fv, format($q$SELECT supplier_statement_data(%L, %L, %L)$q$, e1, PS, PE)), 'SUPPLIER_NOT_FOUND|%');

    -- ══════════════ LINES ══════════════
    RAISE NOTICE 'fixture 270 · LINES';
    v_d := pg_temp.f270_get(u_fv, format($q$SELECT supplier_statement_data(%L, %L, %L)$q$, s1, PS, PE));
    -- 期初 500;发生 600 + 1000 + 200 = 1,800;付款 250 + 100 = 350;预付冲抵 300;期末 500 + 1800 − 350 − 300 = 1,650
    IF ((v_d ->> 'opening_base')::numeric <> 500 OR (v_d ->> 'charges_base')::numeric <> 1800 OR (v_d ->> 'credits_base')::numeric <> 0
        OR (v_d ->> 'payments_base')::numeric <> 350 OR (v_d ->> 'prepayments_base')::numeric <> 300 OR (v_d ->> 'closing_base')::numeric <> 1650) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 270 LINES: opening 500, charges 1,800, credits 0, payments 350, prepayments 300, closing 1,650, got %', v_d - 'lines' - 'open_items' - 'unpriced'; END IF;
    IF (round((v_d ->> 'opening_base')::numeric + (v_d ->> 'charges_base')::numeric - (v_d ->> 'credits_base')::numeric - (v_d ->> 'payments_base')::numeric
              - (v_d ->> 'prepayments_base')::numeric, 2) <> (v_d ->> 'closing_base')::numeric) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 270 LINES: opening + charges − credits − payments − prepayments = closing'; END IF;
    SELECT string_agg((x ->> 'kind') || ':' || (x ->> 'doc_code') || ':' || (x ->> 'amount_base') || ':' || (x ->> 'provisional'), ' | '
                      ORDER BY x ->> 'date', x ->> 'kind', x ->> 'doc_code') INTO v_txt
      FROM jsonb_array_elements(v_d -> 'lines') x;
    -- 定金付在采购单上 → 借的是 1300(预付),不是 2000,所以它【不是】一行;冲抵那一下(借 2000 / 贷 1300)才是。收货的计价分录记在今天,排在最后。
    IF (v_txt <> format('prepayment:%s:-300.00:false | expense:%s:200.00:false | payment:%s:-250.00:false | payment:%s:-100.00:false | receipt:%s:600.00:true | receipt:%s:1000.00:true',
                        (SELECT code FROM purchase_orders WHERE id = v_po), (SELECT code FROM expenses WHERE id = x1),
                        (SELECT code FROM payments WHERE id = p1), (SELECT code FROM payments WHERE id = p2),
                        (SELECT code FROM inbound_batches WHERE id = r1), (SELECT code FROM inbound_batches WHERE id = r2))) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 270 LINES: every 2000 movement of this supplier in the period, with its kind, document, amount and provisional flag, got %', v_txt; END IF;
    IF (EXISTS (SELECT 1 FROM jsonb_array_elements(v_d -> 'lines') x
                 WHERE x ->> 'doc_code' IN ((SELECT code FROM inbound_batches WHERE id = r_other), (SELECT code FROM expenses WHERE id = x_emp),
                                            (SELECT code FROM expenses WHERE id = r0)))) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 270 LINES: another supplier''s receipt, an employee claim and a movement before the period never appear'; END IF;
    IF ((v_d -> 'unpriced') <> jsonb_build_array(jsonb_build_object('doc_code', (SELECT code FROM inbound_batches WHERE id = r3), 'arrival_date', PS + 5,
                                                                    'material_code', 'FX270-M', 'quantity', 77, 'unit', 'kg'))) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 270 LINES: the receipt not yet priced is listed with its quantity only — no amount, got %', v_d -> 'unpriced'; END IF;
    IF ((SELECT count(*) FROM jsonb_array_elements(v_d -> 'open_items') x WHERE (x ->> 'provisional')::boolean) <> 2
        OR (SELECT count(*) FROM jsonb_array_elements(v_d -> 'open_items')) <> 4) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 270 LINES: four open items at the period end (two expenses, two receipts); the two receipts marked provisional (the unpriced one is not an open item), got %', v_d -> 'open_items'; END IF;
    IF ((v_d -> 'on_account') <> jsonb_build_array(jsonb_build_object('code', (SELECT code FROM payments WHERE id = p2), 'payment_date', PS + 8, 'currency', v_base,
                                                                      'unapplied_ccy', 100.00, 'amount_base', 100.00))) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 270 LINES: the payment on account is listed on its own, got %', v_d -> 'on_account'; END IF;

    -- ══════════════ TIE ══════════════
    RAISE NOTICE 'fixture 270 · TIE';
    -- 期末未结:r0 500 + r1 350 + r2 700 + 费用 200 = 1,750;挂账 100;残留 0 → 1,650 = 总账期末
    IF ((v_d ->> 'list_base')::numeric <> 1750 OR (v_d ->> 'on_account_base')::numeric <> 100 OR (v_d ->> 'residue_base')::numeric <> 0
        OR (v_d ->> 'tie_difference')::numeric <> 0 OR (v_d ->> 'ties')::boolean IS NOT TRUE) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 270 TIE: open items 1,750 − on account 100 − residue 0 = ledger 1,650, ties, got %', v_d - 'lines' - 'open_items'; END IF;
    -- 那个"总账 1,650"真的是总账:归到这一家的 2000 行之和(两份独立推导,所以检查是检查)
    IF ((SELECT round(sum(jl.credit - jl.debit), 2) FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id AND a.code = '2000'
           JOIN journal_entries je ON je.id = jl.entry_id
          WHERE je.entry_date <= PE AND ((je.source_type = 'purchase' AND je.source_id IN (r1, r2)) OR (je.source_type = 'expense' AND je.source_id IN (r0, x1))
                                         OR (je.source_type = 'payment' AND je.source_id IN (p1, p2))
                                         OR (je.source_type = 'prepayment' AND je.source_id IN (SELECT id FROM prepayment_applications WHERE purchase_order_id = v_po)))) <> 1650) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 270 TIE: the ledger side is the sum of this supplier''s 2000 lines'; END IF;

    -- ══════════════ NOTIE ══════════════
    RAISE NOTICE 'fixture 270 · NOTIE';
    BEGIN
        PERFORM pg_temp.f270_as(u_all);
        PERFORM post_journal_entry(PS + 9, 'f270 stray', 'purchase', r1,
            jsonb_build_array(jsonb_build_object('account_code', '5000', 'side', 'debit', 'currency', v_base, 'amount_ccy', 0.01, 'fx_rate', 1),
                              jsonb_build_object('account_code', '2000', 'side', 'credit', 'currency', v_base, 'amount_ccy', 0.01, 'fx_rate', 1)));
        PERFORM pg_temp.f270_as(NULL);
        v_msg := pg_temp.f270_do(u_fe, format($q$SELECT issue_supplier_statement(%L, %L, %L)$q$, s1, PS, PE));
        PERFORM pg_temp.f270_expect('NOTIE', v_msg, 'SUPPLIER_STATEMENT_DOES_NOT_TIE|FX270-S1|-0.01|1650.01|1650.00');
        IF (EXISTS (SELECT 1 FROM supplier_statements)) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 270 NOTIE: a refused statement writes nothing'; END IF;
        RAISE EXCEPTION 'f270 undo';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'f270 undo' THEN RAISE; END IF;
    END;
    PERFORM pg_temp.f270_as(NULL);

    -- ══════════════ ISSUE ══════════════
    RAISE NOTICE 'fixture 270 · ISSUE';
    v_r := pg_temp.f270_get(u_fe, format($q$SELECT issue_supplier_statement(%L, %L, %L)$q$, s1, PS, PE));
    st1 := (v_r ->> 'statement_id')::uuid; st_code1 := v_r ->> 'code';
    IF (st_code1 !~ ('^SST-' || v_year || '-[0-9]{4,}$')) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 270 ISSUE: SST-<year>-NNNN, got %', st_code1; END IF;
    SELECT * INTO v_row FROM supplier_statements WHERE id = st1;
    IF ((v_row.closing_base <> 1650 OR v_row.opening_base <> 500 OR v_row.lines <> v_d -> 'lines' OR v_row.open_items <> v_d -> 'open_items'
         OR v_row.unpriced <> v_d -> 'unpriced' OR v_row.on_account <> v_d -> 'on_account' OR v_row.list_base <> 1750
         OR v_row.supplier_code <> 'FX270-S1' OR v_row.supplier_name <> 'Fixture 270 Statement Supplier'
         OR v_row.company ->> 'legal_name' <> 'Fixture 270 Recovery Pte. Ltd.' OR v_row.issued_by <> u_fe)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 270 ISSUE: the row freezes the figures, lines, recipient and letterhead of the preview'; END IF;
    -- 之后再来一张收货、供应商改名、公司换名:冻下来的那一份一个字不动
    PERFORM pg_temp.f270_as(u_all);
    PERFORM create_inbound_batch(v_mat, s1, 3, 'kg', PS + 9, '待加工', 10, 'f270 late', p_source_reason_code => 'other',
                                 p_source_reason_note => 'fixture 270 自带数据', p_currency => v_base);
    PERFORM pg_temp.f270_as(NULL);
    UPDATE suppliers SET legal_name = 'Fixture 270 Renamed Supplier' WHERE id = s1;
    UPDATE company_profile SET legal_name = 'Fixture 270 Renamed Recovery';
    IF ((SELECT to_jsonb(s) FROM supplier_statements s WHERE id = st1) <> to_jsonb(v_row)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 270 ISSUE: an issued statement does not move when the live data does'; END IF;
    v_d2 := pg_temp.f270_get(u_fv, format($q$SELECT supplier_statement_data(%L, %L, %L)$q$, s1, PS, PE));
    IF ((v_d2 ->> 'charges_base')::numeric <> 1830 OR (v_d2 ->> 'ties')::boolean IS NOT TRUE) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 270 ISSUE: the live preview does move (charges 1,830) and still ties, got %', v_d2 - 'lines' - 'open_items'; END IF;
    PERFORM pg_temp.f270_as(u_all); PERFORM pg_temp.f270_agree('late receipt'); PERFORM pg_temp.f270_as(NULL);

    -- ══════════════ SUPER ══════════════
    RAISE NOTICE 'fixture 270 · SUPER';
    PERFORM pg_temp.f270_expect('SUPER', pg_temp.f270_do(u_fe, format($q$SELECT issue_supplier_statement(%L, %L, %L)$q$, s1, PS, PE)),
                                'SUPPLIER_STATEMENT_SUPERSEDE_REASON_REQUIRED|' || st_code1 || '|FX270-S1');
    v_r := pg_temp.f270_get(u_fe, format($q$SELECT issue_supplier_statement(%L, %L, %L, 'A late receipt was recorded')$q$, s1, PS, PE));
    st2 := (v_r ->> 'statement_id')::uuid;
    IF ((v_r ->> 'superseded') <> st_code1 OR (SELECT closing_base FROM supplier_statements WHERE id = st2) <> 1680
        OR (SELECT superseded_by FROM supplier_statements WHERE id = st1) <> st2
        OR (SELECT superseded_reason FROM supplier_statements WHERE id = st1) <> 'A late receipt was recorded'
        OR (SELECT supplier_name FROM supplier_statements WHERE id = st2) <> 'Fixture 270 Renamed Supplier'
        OR (SELECT closing_base FROM supplier_statements WHERE id = st1) <> 1650) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 270 SUPER: a new statement supersedes the old one with the reason; the old one keeps its figures, got %', v_r; END IF;
    PERFORM pg_temp.f270_expect('SUPER', pg_temp.f270_do(u_fe, format($q$SELECT issue_supplier_statement(%L, %L, %L, 'why')$q$, s2, PS, PE)),
                                'SUPPLIER_STATEMENT_REASON_WITHOUT_SUPERSEDE');
    v_msg := NULL; BEGIN UPDATE supplier_statements SET closing_base = 0 WHERE id = st2; EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    PERFORM pg_temp.f270_expect('SUPER', v_msg, 'SUPPLIER_STATEMENT_IMMUTABLE|update');
    v_msg := NULL; BEGIN UPDATE supplier_statements SET superseded_reason = 'rewritten' WHERE id = st1; EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    PERFORM pg_temp.f270_expect('SUPER', v_msg, 'SUPPLIER_STATEMENT_IMMUTABLE|update');
    v_msg := NULL; BEGIN DELETE FROM supplier_statements WHERE id = st1; EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    PERFORM pg_temp.f270_expect('SUPER', v_msg, 'SUPPLIER_STATEMENT_IMMUTABLE|delete');

    -- ══════════════ NUM ══════════════
    RAISE NOTICE 'fixture 270 · NUM';
    IF (next_supplier_statement_code(CURRENT_DATE) <> 'SST-' || v_year || '-0003') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 270 NUM: two issued → the next is 0003, got %', next_supplier_statement_code(CURRENT_DATE); END IF;
    INSERT INTO supplier_statements (code, supplier_id, supplier_code, supplier_name, company, period_start, period_end, base_currency, opening_base, charges_base,
                                     credits_base, payments_base, prepayments_base, closing_base, list_base, on_account_base, residue_base, lines, open_items,
                                     on_account, unpriced, by_currency)
    VALUES ('SST-' || v_year || '-9999', s2, 'FX270-S2', 'x', '{"legal_name":"x"}', PS, PS, v_base, 0, 0, 0, 0, 0, 0, 0, 0, 0, '[]', '[]', '[]', '[]', '[]');
    IF (next_supplier_statement_code(CURRENT_DATE) <> 'SST-' || v_year || '-10000') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 270 NUM: number 10000 must not be truncated, got %', next_supplier_statement_code(CURRENT_DATE); END IF;
    INSERT INTO supplier_statements (code, supplier_id, supplier_code, supplier_name, company, period_start, period_end, base_currency, opening_base, charges_base,
                                     credits_base, payments_base, prepayments_base, closing_base, list_base, on_account_base, residue_base, lines, open_items,
                                     on_account, unpriced, by_currency)
    VALUES ('SST-' || v_year || '-10000', s2, 'FX270-S2', 'x', '{"legal_name":"x"}', PS + 1, PS + 1, v_base, 0, 0, 0, 0, 0, 0, 0, 0, 0, '[]', '[]', '[]', '[]', '[]');
    IF (next_supplier_statement_code(CURRENT_DATE) <> 'SST-' || v_year || '-10001') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 270 NUM: after 10000 comes 10001 (compared as numbers, not text), got %', next_supplier_statement_code(CURRENT_DATE); END IF;

    -- ══════════════ PDF ══════════════
    RAISE NOTICE 'fixture 270 · PDF';
    PERFORM pg_temp.f270_expect('PDF', pg_temp.f270_do(u_fv, format($q$SELECT record_supplier_statement_issue(%L, '%s/a.pdf', %L)$q$, st2, st2, repeat('a', 64))), 'PERMISSION_DENIED|module.finance.edit');
    PERFORM pg_temp.f270_expect('PDF', pg_temp.f270_do(u_fe, format($q$SELECT record_supplier_statement_issue(%L, 'other/%s/a.pdf', %L)$q$, st2, st2, repeat('a', 64))), 'SUPPLIER_STATEMENT_ISSUE_PATH_INVALID|%');
    PERFORM pg_temp.f270_expect('PDF', pg_temp.f270_do(u_fe, format($q$SELECT record_supplier_statement_issue(%L, '%s/a.pdf', 'not-a-digest')$q$, st2, st2)), 'SUPPLIER_STATEMENT_SHA_INVALID');
    PERFORM pg_temp.f270_expect('PDF', pg_temp.f270_do(u_fe, format($q$SELECT record_supplier_statement_issue(%L, '%s/a.pdf', %L)$q$, st1, st1, repeat('a', 64))), 'SUPPLIER_STATEMENT_SUPERSEDED|' || st_code1 || '|%');
    PERFORM pg_temp.f270_expect('PDF', pg_temp.f270_do(u_fe, format($q$SELECT record_supplier_statement_issue(%L, '%s/a.pdf', %L)$q$, gen_random_uuid(), st2, repeat('a', 64))), 'SUPPLIER_STATEMENT_NOT_FOUND|%');
    PERFORM pg_temp.f270_expect('PDF', pg_temp.f270_do(u_fe, format($q$SELECT record_supplier_statement_issue(%L, '%s/a.pdf', %L)$q$, st2, st2, repeat('AB', 32))), 'OK');
    IF ((SELECT sha256 FROM supplier_statement_issues WHERE statement_id = st2 AND version = 1) <> repeat('ab', 32)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 270 PDF: an upper-case digest is stored lower-case, as version 1'; END IF;
    PERFORM pg_temp.f270_expect('PDF', pg_temp.f270_do(u_fe, format($q$SELECT record_supplier_statement_issue(%L, '%s/b.pdf', %L)$q$, st2, st2, repeat('ab', 32))), 'SUPPLIER_STATEMENT_BYTES_ALREADY_RECORDED|%|1');
    PERFORM pg_temp.f270_expect('PDF', pg_temp.f270_do(u_fe, format($q$SELECT record_supplier_statement_issue(%L, '%s/c.pdf', %L)$q$, st2, st2, repeat('c', 64))), 'OK');
    IF ((SELECT string_agg(version::text, ',' ORDER BY version) FROM supplier_statement_issues WHERE statement_id = st2) <> '1,2') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 270 PDF: different bytes are the next version'; END IF;
    PERFORM pg_temp.f270_expect('PDF', pg_temp.f270_do(u_fe, format($q$INSERT INTO supplier_statement_issues (statement_id, version, file_path, sha256) VALUES (%L, 9, '%s/z.pdf', %L)$q$, st2, st2, repeat('d', 64))), '%row-level security%');
    v_msg := NULL; BEGIN UPDATE supplier_statement_issues SET sha256 = repeat('e', 64) WHERE statement_id = st2; EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    PERFORM pg_temp.f270_expect('PDF', v_msg, 'SUPPLIER_STATEMENT_ISSUE_IMMUTABLE|update');
    v_msg := NULL; BEGIN DELETE FROM supplier_statement_issues WHERE statement_id = st2; EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    PERFORM pg_temp.f270_expect('PDF', v_msg, 'SUPPLIER_STATEMENT_ISSUE_IMMUTABLE|delete');

    PERFORM pg_temp.f270_as(u_all);
    PERFORM pg_temp.f270_agree('end');
    RAISE NOTICE 'FIXTURE 270 全部通过: GATE · PERIOD · LINES · TIE · NOTIE · ISSUE · SUPER · NUM · PDF';
END
$$;

ROLLBACK;
