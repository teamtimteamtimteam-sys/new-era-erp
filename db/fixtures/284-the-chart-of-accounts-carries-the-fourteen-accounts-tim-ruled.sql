-- 284 FIN-CHAIN-1:科目表增补的十四个科目(Tim 2026-10-20)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(委托书 A1–A4;Step 0 Q10)
--   A  一个全新安装(本库就是从镜像重建的)带着这十四个科目,逐字是 Tim 定的那样:非系统、启用;
--        2600 Loan Payable / 应付借款 是负债、货币性、筹资段;十三个费用科目非货币性、不是现金、不定段
--   B  不该有的没有:Freight Charges · Other Operating Expenses · 第二个 Repairs & Maintenance · 第二个 Share Capital;
--        6300 / 6900 名字没改;3000 仍是 Share Capital
--   C  ★ 费用单的科目下拉(/finance/expenses/new 的那一句:account_type = 'expense' AND is_active)列出全部十三个、不列 2600
--   D  record_expense 认新费用科目(6010 记得进去),拒 2600(ACCOUNT_NOT_EXPENSE)—— 下拉之外的那一道门也守着
--   E  2600 走手工分录记得进去(它就是给手工分录用的)
--
-- 依赖的是【稳定的引导数据】(README 第 4 条:科目表)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_base text; v_msg text; v_n int; v_sup uuid; v_je jsonb;
    exp_codes text[] := ARRAY['6010','6130','6140','6210','6220','6230','6240','6250','6310','6410','6420','6510','6520'];
    exp_names text[] := ARRAY['Equipment Rental','Staff Training & Development','Recruitment Expenses','Telephone & Internet',
        'IT & Software Expenses','Printing & Stationery','Office Expenses','Cleaning Expenses','Vehicle Expenses',
        'Licences & Permits','Insurance Expenses','Business Travel Expenses','Entertainment Expenses'];
    exp_zh text[] := ARRAY['设备租赁费','员工培训与发展','招聘费用','电话与网络费','IT与软件费用','印刷与文具','办公费用',
        '清洁费用','车辆费用','执照与许可费','保险费','差旅费','业务招待费'];
    i int;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL, gst_registered = false;

    -- A · 十四个,逐字
    IF NOT EXISTS (SELECT 1 FROM accounts WHERE code = '2600' AND name_en = 'Loan Payable' AND name_zh = '应付借款'
                    AND account_type = 'liability' AND is_monetary AND NOT is_system AND is_active
                    AND cash_flow_section = 'financing' AND NOT is_cash) THEN
        RAISE EXCEPTION 'FIXTURE 284A1 失败:2600 应当是 Loan Payable / 应付借款、负债、货币性、非系统、启用、筹资段'; END IF;
    FOR i IN 1 .. array_length(exp_codes, 1) LOOP
        IF NOT EXISTS (SELECT 1 FROM accounts WHERE code = exp_codes[i] AND name_en = exp_names[i] AND name_zh = exp_zh[i]
                        AND account_type = 'expense' AND NOT is_monetary AND NOT is_system AND is_active
                        AND NOT is_cash AND cash_flow_section IS NULL) THEN
            RAISE EXCEPTION 'FIXTURE 284A2 失败:% 应当是 % / %、费用、非货币性、非系统、启用', exp_codes[i], exp_names[i], exp_zh[i]; END IF;
    END LOOP;

    -- B · 不该有的没有
    IF EXISTS (SELECT 1 FROM accounts WHERE name_en IN ('Freight Charges', 'Other Operating Expenses'))
       OR (SELECT count(*) FROM accounts WHERE name_en = 'Repairs & Maintenance') <> 1
       OR (SELECT count(*) FROM accounts WHERE name_en = 'Share Capital') <> 1
       OR NOT EXISTS (SELECT 1 FROM accounts WHERE code = '3000' AND name_en = 'Share Capital')
       OR NOT EXISTS (SELECT 1 FROM accounts WHERE code = '6300' AND name_en = 'Transport & Logistics')
       OR NOT EXISTS (SELECT 1 FROM accounts WHERE code = '6900' AND name_en = 'Miscellaneous') THEN
        RAISE EXCEPTION 'FIXTURE 284B 失败:不该建的科目建了,或 3000 / 6300 / 6900 的名字被改了'; END IF;

    -- C · 费用单的科目下拉(与 app/finance/expenses/new/page.tsx 那一句同一个谓词)
    SELECT count(*) INTO v_n FROM accounts WHERE account_type = 'expense' AND is_active AND code = ANY (exp_codes);
    IF v_n <> 13 OR EXISTS (SELECT 1 FROM accounts WHERE account_type = 'expense' AND is_active AND code = '2600') THEN
        RAISE EXCEPTION 'FIXTURE 284C 失败:费用单下拉应当列出十三个新费用科目(实得 %)、不列 2600', v_n; END IF;

    -- D · 下拉之外那一道门
    INSERT INTO auth.users (id) VALUES (v_user);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx284', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_user), true);
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ-F284-S', 'fixture 284 supplier', 'SG', 'active', 'service_vendor') RETURNING id INTO v_sup;
    PERFORM record_expense(p_expense_date := CURRENT_DATE - 1, p_account_code := '6010', p_amount := 120,
        p_currency := v_base, p_payment_status := 'unpaid', p_supplier_id := v_sup);
    IF NOT EXISTS (SELECT 1 FROM expense_lines l WHERE l.account_code = '6010') THEN   -- EXPENSE-MULTILINE-1:科目在行上
        RAISE EXCEPTION 'FIXTURE 284D1 失败:新费用科目 6010 应当记得进费用单'; END IF;
    BEGIN
        PERFORM record_expense(p_expense_date := CURRENT_DATE - 1, p_account_code := '2600', p_amount := 120,
            p_currency := v_base, p_payment_status := 'unpaid', p_supplier_id := v_sup);
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    IF v_msg NOT LIKE 'ACCOUNT_NOT_EXPENSE%' THEN
        RAISE EXCEPTION 'FIXTURE 284D2 失败:2600 是负债,费用单应当按名拒 ACCOUNT_NOT_EXPENSE,实得 %', v_msg; END IF;

    -- E · 2600 走手工分录
    v_je := post_journal_entry(CURRENT_DATE - 1, 'fixture 284 loan drawn', 'manual', NULL,
        jsonb_build_array(
            jsonb_build_object('account_code', '1000', 'side', 'debit',  'currency', v_base, 'amount_ccy', 5000),
            jsonb_build_object('account_code', '2600', 'side', 'credit', 'currency', v_base, 'amount_ccy', 5000)));
    IF (v_je->>'entry_id') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 284E 失败:2600 应当记得进手工分录,实得 %', v_je; END IF;

    RAISE NOTICE 'FIXTURE 284 全部通过:A 十四个逐字 · B 不该有的没有 · C 费用单下拉 · D 记账门 · E 手工分录';
END;
$$;
ROLLBACK;
