-- db/fixtures/286-a-claim-is-a-header-and-items-and-becomes-one-expense.sql
-- ═══════════════════════════════════════════════════════════════════════════
-- EXPENSE-MULTILINE-1(Tim 2026-10-20,Step 0 Q3 · Step 0b Q1 · Q3–Q10):报销单是【表头 + 明细】,批准时生出【一张】费用单、每笔明细一行。
--
--   A  提交三笔(同一个月、本位币):表头金额 = 明细之和,表头日期 = 最晚那一笔,用途落在表头;明细逐笔落库,科目与税码空着。
--   B  日期(Q5):跨月 → EXPENSE_CLAIM_ITEMS_SPAN_MONTHS;外币两天 → EXPENSE_CLAIM_FOREIGN_ITEMS_ONE_DATE;外币同一天 → 收下。
--   C  用途必填(Q7)→ EXPENSE_CLAIM_PURPOSE_REQUIRED;明细说明必填(带第几笔)。
--   D  旧的 decide_expense_claim 碰到多笔的单 → EXPENSE_CLAIM_HAS_ITEMS(Q8),什么都不写。
--   E  按明细决定:少给一笔科目 → EXPENSE_CLAIM_ACCOUNT_REQUIRED|单号|2;不存在的行号 → EXPENSE_CLAIM_ITEM_UNKNOWN;
--      某一笔既没附件也没理由 → EXPENSE_CLAIM_NO_EVIDENCE|单号|3(逐笔,Step 0b Q2)。
--   F  批准(Q1):一张费用单,三行;每行的科目 / 税码是财务逐笔给的,备注 = 明细说明;收据金额含税、按行拆(TX 拆出税、BL 进科目);
--      欠的是那名员工、未付、恰好等于三张收据之和;明细上记下了科目与税码,之后不可改(EXPENSE_CLAIM_ITEM_IMMUTABLE)。
--   G  驳回整张(Q3):理由可以点名哪一笔;明细一行不动、没有费用单。
--   H  旧签名的两支(单笔包装,Q8):提交写出一笔;一笔的单经旧决定批得出一张一行的费用单。
--   I  读(与表头同一条):本人读得到自己那几笔;一个不持财务、也不是报销人的人读到 0 笔。
--   J  合计守卫:一张没有明细的表头、或金额与明细对不上的表头,在提交时被拒。
-- 自带数据(README 第 2 条);GST、期间锁自己设(第 4/5 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    u_emp   uuid := gen_random_uuid();   -- 报销人(有员工档案)
    u_fin   uuid := gen_random_uuid();   -- 财务(全权限,决定的人)
    u_other uuid := gen_random_uuid();   -- 不持任何码、有员工档案的另一个人
    r_all   uuid;
    e_emp   uuid; e_other uuid;
    v_base  text;
    d1      date := date_trunc('month', CURRENT_DATE - 40)::date + 2;   -- 一个已过去的月份里的三天
    d2      date := date_trunc('month', CURRENT_DATE - 40)::date + 5;
    d3      date := date_trunc('month', CURRENT_DATE - 40)::date + 9;
    v_res   jsonb; c1 uuid; c2 uuid; c3 uuid; v_exp uuid;
    v_n     int; v_x numeric; v_msg text; v_code text;
BEGIN
    INSERT INTO auth.users (id) VALUES (u_emp), (u_fin), (u_other);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-286', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (u_fin, r_all);
    UPDATE finance_settings SET locked_before = NULL, gst_registered = true,
           gst_registration_no = COALESCE(gst_registration_no, 'ZZ-F286-GST');
    SELECT code INTO v_base FROM currencies WHERE is_base;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id)
    VALUES ('ZZ-F286-E', 'fixture 286 claimant', 'full_time', 'office', CURRENT_DATE - 400, u_emp) RETURNING id INTO e_emp;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id)
    VALUES ('ZZ-F286-O', 'fixture 286 other', 'full_time', 'office', CURRENT_DATE - 400, u_other) RETURNING id INTO e_other;
    IF date_trunc('month', d1) <> date_trunc('month', d3) OR d3 >= CURRENT_DATE THEN
        RAISE EXCEPTION 'FIXTURE 286 布景失败:三天必须同月且已过去'; END IF;

    -- ══════════ A · 提交三笔 ══════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_emp), true);
    v_res := submit_expense_claim_items(e_emp, v_base, 'Client visit, week of the 3rd', jsonb_build_array(
        jsonb_build_object('spend_date', d2, 'amount', 109, 'description', 'taxi to client', 'no_receipt_reason', 'driver had no printer'),
        jsonb_build_object('spend_date', d1, 'amount', 54.50, 'description', 'lunch with client', 'no_receipt_reason', 'lost'),
        jsonb_build_object('spend_date', d3, 'amount', 20, 'description', 'parking')));
    c1 := (v_res->>'claim_id')::uuid; v_code := v_res->>'code';
    IF (v_res->>'item_count')::int <> 3 THEN RAISE EXCEPTION 'FIXTURE 286A 失败:应当三笔,实得 %', v_res; END IF;
    IF NOT EXISTS (SELECT 1 FROM expense_claims WHERE id = c1 AND amount_ccy = 183.50 AND spend_date = d3
                    AND description = 'Client visit, week of the 3rd' AND status = 'submitted') THEN
        RAISE EXCEPTION 'FIXTURE 286A 失败:表头应当是 183.50 / 最晚那天 % / 用途', d3; END IF;
    IF (SELECT count(*) FROM expense_claim_items WHERE claim_id = c1 AND account_code IS NULL AND tax_code IS NULL) <> 3
       OR NOT EXISTS (SELECT 1 FROM expense_claim_items WHERE claim_id = c1 AND line_no = 2 AND spend_date = d1
                       AND amount_ccy = 54.50 AND description = 'lunch with client' AND no_receipt_reason = 'lost') THEN
        RAISE EXCEPTION 'FIXTURE 286A 失败:明细应当逐笔落库、科目与税码空着'; END IF;

    -- ══════════ B · 日期 ══════════
    BEGIN
        PERFORM submit_expense_claim_items(e_emp, v_base, 'two months', jsonb_build_array(
            jsonb_build_object('spend_date', d1, 'amount', 10, 'description', 'a', 'no_receipt_reason', 'x'),
            jsonb_build_object('spend_date', d1 - 40, 'amount', 10, 'description', 'b', 'no_receipt_reason', 'x')));
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg NOT LIKE 'EXPENSE_CLAIM_ITEMS_SPAN_MONTHS|%' THEN RAISE EXCEPTION 'FIXTURE 286B 失败:跨月应当按名拒,实得 %', v_msg; END IF;
    BEGIN
        PERFORM submit_expense_claim_items(e_emp, 'USD', 'trip', jsonb_build_array(
            jsonb_build_object('spend_date', d1, 'amount', 10, 'description', 'a', 'no_receipt_reason', 'x'),
            jsonb_build_object('spend_date', d2, 'amount', 10, 'description', 'b', 'no_receipt_reason', 'x')));
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_base = 'USD' THEN RAISE EXCEPTION 'FIXTURE 286B 布景失败:外币那一臂需要本位币不是 USD'; END IF;
    IF v_msg NOT LIKE 'EXPENSE_CLAIM_FOREIGN_ITEMS_ONE_DATE|USD|%' THEN RAISE EXCEPTION 'FIXTURE 286B 失败:外币两天应当按名拒,实得 %', v_msg; END IF;
    v_res := submit_expense_claim_items(e_emp, 'USD', 'trip', jsonb_build_array(
        jsonb_build_object('spend_date', d1, 'amount', 10, 'description', 'a', 'no_receipt_reason', 'x'),
        jsonb_build_object('spend_date', d1, 'amount', 5, 'description', 'b', 'no_receipt_reason', 'x')));
    IF (v_res->>'claim_id') IS NULL THEN RAISE EXCEPTION 'FIXTURE 286B 失败:外币同一天应当收下'; END IF;

    -- ══════════ C · 用途与说明必填 ══════════
    BEGIN
        PERFORM submit_expense_claim_items(e_emp, v_base, '  ', jsonb_build_array(
            jsonb_build_object('spend_date', d1, 'amount', 10, 'description', 'a')));
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg <> 'EXPENSE_CLAIM_PURPOSE_REQUIRED' THEN RAISE EXCEPTION 'FIXTURE 286C 失败:空用途应当按名拒,实得 %', v_msg; END IF;
    BEGIN
        PERFORM submit_expense_claim_items(e_emp, v_base, 'p', jsonb_build_array(
            jsonb_build_object('spend_date', d1, 'amount', 10, 'description', 'a'),
            jsonb_build_object('spend_date', d1, 'amount', 10, 'description', '')));
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg <> 'EXPENSE_CLAIM_DESCRIPTION_REQUIRED|2' THEN RAISE EXCEPTION 'FIXTURE 286C 失败:第 2 笔没有说明应当带行号拒,实得 %', v_msg; END IF;

    -- ══════════ D · 旧决定碰到多笔 → 拒 ══════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    BEGIN
        PERFORM decide_expense_claim(c1, true, '6120', 'TX', NULL, NULL);
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg <> 'EXPENSE_CLAIM_HAS_ITEMS|' || v_code || '|3' THEN
        RAISE EXCEPTION 'FIXTURE 286D 失败:旧决定碰到三笔的单应当 EXPENSE_CLAIM_HAS_ITEMS,实得 %', v_msg; END IF;
    IF (SELECT status FROM expense_claims WHERE id = c1) <> 'submitted' THEN RAISE EXCEPTION 'FIXTURE 286D 失败:被拒之后单据应当原样'; END IF;

    -- ══════════ E · 按明细决定的拒绝 ══════════
    BEGIN
        PERFORM decide_expense_claim_items(c1, true, jsonb_build_array(
            jsonb_build_object('line_no', 1, 'account_code', '6120', 'tax_code', 'TX'),
            jsonb_build_object('line_no', 3, 'account_code', '6300', 'tax_code', 'BL')), NULL, NULL);
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg <> 'EXPENSE_CLAIM_ACCOUNT_REQUIRED|' || v_code || '|2' THEN
        RAISE EXCEPTION 'FIXTURE 286E 失败:第 2 笔没有科目应当带行号拒,实得 %', v_msg; END IF;
    BEGIN
        PERFORM decide_expense_claim_items(c1, true, jsonb_build_array(
            jsonb_build_object('line_no', 9, 'account_code', '6120', 'tax_code', 'TX')), NULL, NULL);
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg <> 'EXPENSE_CLAIM_ITEM_UNKNOWN|' || v_code || '|9' THEN
        RAISE EXCEPTION 'FIXTURE 286E 失败:不存在的行号应当按名拒,实得 %', v_msg; END IF;
    BEGIN
        PERFORM decide_expense_claim_items(c1, true, jsonb_build_array(
            jsonb_build_object('line_no', 1, 'account_code', '6120', 'tax_code', 'TX'),
            jsonb_build_object('line_no', 2, 'account_code', '6120', 'tax_code', 'BL'),
            jsonb_build_object('line_no', 3, 'account_code', '6300', 'tax_code', 'TX')), NULL, NULL);
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg <> 'EXPENSE_CLAIM_NO_EVIDENCE|' || v_code || '|3' THEN
        RAISE EXCEPTION 'FIXTURE 286E 失败:第 3 笔没有凭据应当逐笔拒,实得 %', v_msg; END IF;
    IF (SELECT count(*) FROM expense_claim_items WHERE claim_id = c1 AND account_code IS NOT NULL) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 286E 失败:被拒的决定不该在明细上留下科目'; END IF;

    -- ══════════ F · 批准:一张费用单、三行 ══════════
    -- 第 3 笔补一份附件(今天只有财务挂得上 —— CLAIM-RECEIPTS-1 之前员工传不了)
    INSERT INTO finance_attachments (claim_id, file_name, file_path, mime_type)
    VALUES (c1, 'parking.pdf', format('%s/parking.pdf', c1), 'application/pdf');
    v_res := decide_expense_claim_items(c1, true, jsonb_build_array(
        jsonb_build_object('line_no', 1, 'account_code', '6120', 'tax_code', 'TX'),
        jsonb_build_object('line_no', 2, 'account_code', '6120', 'tax_code', 'BL'),
        jsonb_build_object('line_no', 3, 'account_code', '6300', 'tax_code', 'TX')), NULL, NULL);
    v_exp := (v_res->>'expense_id')::uuid;
    IF v_res->>'status' <> 'approved' OR v_exp IS NULL THEN RAISE EXCEPTION 'FIXTURE 286F 失败:应当批准并生出费用单,实得 %', v_res; END IF;
    SELECT count(*) INTO v_n FROM expenses WHERE id = v_exp AND employee_id = e_emp AND supplier_id IS NULL
       AND payment_status = 'unpaid' AND expense_date = d3 AND amount_ccy + tax_ccy = 183.50;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 286F 失败:费用单应当挂那名员工、未付、日期 = 最晚那天、欠款 = 三张收据之和 183.50'; END IF;
    IF (SELECT count(*) FROM expense_lines WHERE expense_id = v_exp) <> 3
       -- 109 含 9% TX → 净 100 税 9;54.50 含 9% BL → 净 50 税 4.50(进科目);20 含 9% TX → 拆税
       OR NOT EXISTS (SELECT 1 FROM expense_lines WHERE expense_id = v_exp AND line_no = 1 AND account_code = '6120'
                       AND tax_code = 'TX' AND amount_ccy = 100 AND tax_ccy = 9 AND notes = 'taxi to client')
       OR NOT EXISTS (SELECT 1 FROM expense_lines WHERE expense_id = v_exp AND line_no = 2 AND tax_code = 'BL'
                       AND amount_ccy = 50 AND tax_ccy = 4.50 AND notes = 'lunch with client')
       OR NOT EXISTS (SELECT 1 FROM expense_lines WHERE expense_id = v_exp AND line_no = 3 AND account_code = '6300'
                       AND amount_ccy + tax_ccy = 20 AND notes = 'parking') THEN
        RAISE EXCEPTION 'FIXTURE 286F 失败:三行应当逐笔带着财务给的科目 / 税码、按行拆税、备注 = 说明'; END IF;
    IF (SELECT count(*) FROM expense_claim_items WHERE claim_id = c1 AND account_code IS NOT NULL) <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 286F 失败:明细上应当记下科目'; END IF;
    BEGIN
        UPDATE expense_claim_items SET account_code = '6100' WHERE claim_id = c1 AND line_no = 1;
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg <> 'EXPENSE_CLAIM_ITEM_IMMUTABLE' THEN RAISE EXCEPTION 'FIXTURE 286F 失败:批准之后改科目应当按名拒,实得 %', v_msg; END IF;

    -- ══════════ G · 驳回整张 ══════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_emp), true);
    v_res := submit_expense_claim_items(e_emp, v_base, 'second trip', jsonb_build_array(
        jsonb_build_object('spend_date', d1, 'amount', 30, 'description', 'bus', 'no_receipt_reason', 'x'),
        jsonb_build_object('spend_date', d1, 'amount', 70, 'description', 'hotel minibar', 'no_receipt_reason', 'x')));
    c2 := (v_res->>'claim_id')::uuid;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    v_res := decide_expense_claim_items(c2, false, NULL, NULL, 'item 2 (minibar) is not reimbursable');
    IF v_res->>'status' <> 'rejected'
       OR (SELECT count(*) FROM expense_claim_items WHERE claim_id = c2 AND account_code IS NULL) <> 2
       OR (SELECT expense_id FROM expense_claims WHERE id = c2) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 286G 失败:驳回应当整张、明细不动、没有费用单'; END IF;

    -- ══════════ H · 旧签名的两支 ══════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_emp), true);
    v_res := submit_expense_claim(e_emp, d2, 40, v_base, 'single old-style claim', 'no slip');
    c3 := (v_res->>'claim_id')::uuid;
    IF (SELECT count(*) FROM expense_claim_items WHERE claim_id = c3 AND description = 'single old-style claim'
          AND no_receipt_reason = 'no slip' AND amount_ccy = 40 AND spend_date = d2) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 286H 失败:旧提交应当写出一笔'; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    v_res := decide_expense_claim(c3, true, '6120', 'TX', NULL, NULL);
    IF (SELECT count(*) FROM expense_lines WHERE expense_id = (v_res->>'expense_id')::uuid) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 286H 失败:旧决定批一笔的单应当生出一张一行的费用单,实得 %', v_res; END IF;

    -- ══════════ I · 读 ══════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_emp), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM expense_claim_items WHERE claim_id IN (c1, c2, c3);
    EXECUTE 'RESET ROLE';
    IF v_n <> 6 THEN RAISE EXCEPTION 'FIXTURE 286I 失败:本人应当读到自己的 6 笔,实得 %', v_n; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_other), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM expense_claim_items WHERE claim_id IN (c1, c2, c3);
    EXECUTE 'RESET ROLE';
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 286I 失败:一个不持财务、也不是报销人的人应当读到 0 笔,实得 %', v_n; END IF;

    -- ══════════ J · 合计守卫 ══════════
    BEGIN
        INSERT INTO expense_claims (code, employee_id, spend_date, amount_ccy, currency, description)
        VALUES ('ZZ-F286-NOITEMS', e_emp, d1, 10, v_base, 'x');
        SET CONSTRAINTS ALL IMMEDIATE;
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    SET CONSTRAINTS ALL DEFERRED;
    IF v_msg NOT LIKE 'EXPENSE_CLAIM_HAS_NO_ITEMS|ZZ-F286-NOITEMS%' THEN
        RAISE EXCEPTION 'FIXTURE 286J 失败:没有明细的表头应当在提交时被拒,实得 %', v_msg; END IF;
    BEGIN
        INSERT INTO expense_claims (code, employee_id, spend_date, amount_ccy, currency, description)
        VALUES ('ZZ-F286-MISMATCH', e_emp, d1, 10, v_base, 'x');
        INSERT INTO expense_claim_items (claim_id, line_no, spend_date, amount_ccy, description)
        SELECT id, 1, d1, 9, 'x' FROM expense_claims WHERE code = 'ZZ-F286-MISMATCH';
        SET CONSTRAINTS ALL IMMEDIATE;
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    SET CONSTRAINTS ALL DEFERRED;
    IF v_msg NOT LIKE 'EXPENSE_CLAIM_TOTALS_MISMATCH|ZZ-F286-MISMATCH%' THEN
        RAISE EXCEPTION 'FIXTURE 286J 失败:金额与明细对不上的表头应当在提交时被拒,实得 %', v_msg; END IF;

    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    RAISE NOTICE 'FIXTURE 286 全部通过:三笔提交(A)· 同月 / 外币同日(B)· 用途与说明必填(C)· 旧决定拒多笔(D)· 逐笔的拒绝(E)· 一张单三行、按行拆税(F)· 驳回整张(G)· 旧签名单笔(H)· 本人读得到、旁人读不到(I)· 合计守卫(J)';
END $$;
ROLLBACK;
