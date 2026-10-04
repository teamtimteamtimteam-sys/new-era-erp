-- db/scripts/2026-10-04-at1c3-live-proof.sql
-- AUDIT-TRAIL-1c-3 · 线上的证明(形状照 1c-2 的那一份)。以 postgres 跑,读者一律是【真账号】的会话(SET LOCAL ROLE authenticated + JWT)。
--   A  只读:十二个新主语在线上的【每一条】记录,以 tim@(cfo)读 —— 锁期与 GST 两块面板(同一行设置)· 公司资料 · 每一张报销单
--      (外加以【报销人自己的账号】读 my_expense_claim —— M8)· 清单块读的那几种:重估与工资的分录、加工成本结算留下的分录与费用单、
--      每一条汇率、删掉的那一张对账单;年结 · 人工分录申请 · 转账 · 缴纳 · 预测 · 常设行 · 导入映射在线上今天是 0 条,照直报。
--      不许被拒;每一条记录都有它的建立;锁期那一段里有记录开始之前的那一次月结(M7);一行只出现一次。
--   B  回滚:chooer@(finance)提、做、付;tim@(cfo)批;sandra@(cco)建供应商;fusheng@(warehouse,一个财务的码都没有)是报销人 ——
--      挪锁(往前一个月、再挪回来)· 改 GST 注册号 · 改公司地址 · 人工分录申请(提 → tim@ 批;另一张提 → 撤回)·
--      报销单(fusheng@ 提 → chooer@ 批)· 行内转账(申请 → 批 → 付 → 冲销申请 → 批 → 付)· 代扣税缴纳(一张代扣的账单 → 付 →
--      缴纳申请 → 批 → 付 → 冲销申请 → 批 → 付)· 现金预测(冻结 → 同一周再冻结一张,取代旧的)· 常设行(加 → 改金额 → 关掉)·
--      导入映射(建 → 改名 → 删)· 批量汇率(一天两条,那一天线上一条都没有);以 tim@ 读它们的审计记录,报销单再以 fusheng@ 读。
--   ★ 月结 / 反结【不在 B 里】:线上有 8 张已提交、从未分摊成本的加工单(process_date 都 ≤ 31/08/2026),close_period 按名拒
--     (PROCESSING_COSTS_UNALLOCATED)每一个锁之后的月末 —— 分摊它们就是替【在这之前就在的单据】做决定,连回滚的事务里也不做
--     (委托书的常设规矩)。月结 / 反结的读法由 fixture 243 L 臂在重建库上走真函数证;线上锁期那一段读得到记录开始之前的那一次月结(A)。
--     年结同理(它的硬前置要先关掉最后一个月)。
--   整个文件一笔事务,末尾 ROLLBACK —— 不留下任何东西(前后两份读数逐字相同为证)。
--   ★ 不碰任何一张在这之前就在的单据 —— 改的每一行都是本文件自己建的;唯一被改的旧行是 finance_settings 与 company_profile 那两个
--     单行设置(委托书点名要挪锁、改 GST 设置),回滚之后原样(前后读数为证)。
-- 跑法:psql "$DSN" -X -q -v ON_ERROR_STOP=1 -f db/scripts/2026-10-04-at1c3-live-proof.sql > out.txt;  PROOF_OWN_EXIT=$?
BEGIN;
SET LOCAL statement_timeout = '600s';

CREATE TEMP TABLE p_out (label text, subject text, id text, grp text, rows jsonb) ON COMMIT DROP;

CREATE FUNCTION pg_temp.p_trail(p_user uuid, p_subject text, p_id text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.entry_no, r.seq NULLS LAST, r.occurred_at), '[]'::jsonb) INTO v
      FROM record_trail(p_subject, p_id, 500) r;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RAISE EXCEPTION 'PROOF|% % refused or failed: %', p_subject, p_id, SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.p_twice(p_trail jsonb) RETURNS text
LANGUAGE sql AS $f$
    SELECT string_agg(k, ', ') FROM (
        SELECT COALESCE(e ->> 'seq', 'P') || ':' || (e ->> 'table_name') || ':' || (e ->> 'row_key') || ':' || (e ->> 'op') || ':' ||
               COALESCE(e ->> 'changed_columns', '') AS k
          FROM jsonb_array_elements(p_trail) e WHERE NOT (e ->> 'row_hidden')::boolean
         GROUP BY 1 HAVING count(*) > 1) d
$f$;

CREATE FUNCTION pg_temp.p_has(p_trail jsonb, p_table text, p_op text, p_col text DEFAULT NULL) RETURNS boolean
LANGUAGE sql AS $f$
    SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(p_trail) e
                    WHERE e ->> 'table_name' = p_table AND e ->> 'op' = p_op AND NOT (e ->> 'row_hidden')::boolean
                      AND (p_col IS NULL OR e -> 'changed_columns' ? p_col))
$f$;

CREATE FUNCTION pg_temp.p_keep(p_label text, p_user uuid, p_subject text, p_id text, p_grp text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb := pg_temp.p_trail(p_user, p_subject, p_id);
BEGIN
    INSERT INTO p_out VALUES (p_label, p_subject, p_id, p_grp, v);
    RETURN v;
END;
$f$;

-- ══════════════ A · 只读:线上的每一条 ══════════════
DO $a$
DECLARE
    tim uuid := '634c00f9-c3a9-4444-9eed-b624cb6a2a93';
    v jsonb; t record; n int := 0; c jsonb;
BEGIN
    -- 两块面板(同一行设置)与公司资料
    v := pg_temp.p_keep('A', tim, 'finance_lock', 'true');
    IF (SELECT count(*) FROM period_closes) > 0 AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) e WHERE e ->> 'table_name' = 'period_closes' AND e ->> 'op' = 'INSERT') THEN
        RAISE EXCEPTION 'PROOF A|the lock trail does not show the month close(s) on live (M7)'; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v) e, jsonb_array_elements_text(COALESCE(e -> 'changed_columns', '[]')) col
                WHERE e ->> 'table_name' = 'finance_settings' AND col <> 'locked_before') THEN
        RAISE EXCEPTION 'PROOF A|the lock trail shows a settings column it does not own (M6)'; END IF;
    v := pg_temp.p_keep('A', tim, 'finance_gst', 'true');
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v) e WHERE e ->> 'table_name' = 'period_closes') THEN
        RAISE EXCEPTION 'PROOF A|a month close reached the GST panel'; END IF;
    PERFORM pg_temp.p_keep('A', tim, 'company_profile', 'true');
    n := 3;
    -- 每一张报销单:财务那一页(tim@)与报销人自己(M8,报销人的账号)
    FOR t IN SELECT ec.id, ec.code, e.user_id FROM expense_claims ec JOIN employees e ON e.id = ec.employee_id ORDER BY ec.code LOOP
        v := pg_temp.p_keep('A', tim, 'expense_claim', t.id::text);
        IF NOT pg_temp.p_has(v, 'expense_claims', 'INSERT') THEN RAISE EXCEPTION 'PROOF A|claim %: its submission is missing', t.code; END IF;
        IF t.user_id IS NOT NULL THEN
            c := pg_temp.p_keep('A claimant', t.user_id, 'my_expense_claim', t.id::text);
            IF NOT pg_temp.p_has(c, 'expense_claims', 'INSERT') THEN RAISE EXCEPTION 'PROOF A|claim %: the claimant cannot see the submission (M8)', t.code; END IF;
            n := n + 1;
        END IF;
        n := n + 1;
    END LOOP;
    -- 清单块读的那几种
    FOR t IN SELECT 'journal_entry' AS s, id::text AS id FROM journal_entries WHERE source_type IN ('revaluation', 'payroll', 'depreciation', 'year_close')
             UNION ALL SELECT 'journal_entry', remitted_journal_entry_id::text FROM processing_cost_entries WHERE remitted_journal_entry_id IS NOT NULL
             UNION ALL SELECT 'expense', relief_expense_id::text FROM processing_cost_entries WHERE relief_expense_id IS NOT NULL
             UNION ALL SELECT 'fx_rate', id::text FROM fx_rates
             UNION ALL SELECT 'bank_statement', id::text FROM bank_statements WHERE deleted_at IS NOT NULL
             UNION ALL SELECT 'year_close', id::text FROM year_closes
             UNION ALL SELECT 'journal_request', id::text FROM journal_requests
             UNION ALL SELECT 'bank_transfer', id::text FROM bank_transfers
             UNION ALL SELECT 'wht_remittance', id::text FROM wht_remittances
             UNION ALL SELECT 'cash_forecast', id::text FROM cash_forecasts
             UNION ALL SELECT 'cash_forecast_line', id::text FROM cash_forecast_lines
             UNION ALL SELECT 'bank_import_profile', id::text FROM bank_import_profiles LOOP
        v := pg_temp.p_keep('A', tim, t.s, t.id);
        IF jsonb_array_length(v) = 0 THEN RAISE EXCEPTION 'PROOF A|% % has an empty trail (every live record has at least its creation)', t.s, t.id; END IF;
        n := n + 1;
    END LOOP;
    IF EXISTS (SELECT 1 FROM p_out WHERE label LIKE 'A%' AND pg_temp.p_twice(rows) IS NOT NULL) THEN
        RAISE EXCEPTION 'PROOF A|a row shows twice: %', (SELECT string_agg(subject || ' ' || id || ': ' || pg_temp.p_twice(rows), '; ') FROM p_out WHERE label LIKE 'A%' AND pg_temp.p_twice(rows) IS NOT NULL); END IF;
    RAISE NOTICE 'PROOF A passed: % records read, none refused, none empty (except the GST panel / company profile, which have no record on live)', n;
END;
$a$;

-- ══════════════ B · 回滚:建 · 改 · 读(审批开着)══════════════
DO $b$
DECLARE
    fin uuid := '476bf8c8-c248-4352-9a75-945bf52ca390';   -- chooer@evoltrya.test(finance)
    tim uuid := '634c00f9-c3a9-4444-9eed-b624cb6a2a93';   -- tim@evoltrya.test(cfo,二级审批)
    san uuid := '01ae00e4-306f-4527-8537-10291e4750c7';   -- sandra@evoltrya.test(cco)
    fus uuid := 'c8116e6c-80db-4a16-be12-24fb6ce6859d';   -- fusheng@evoltrya.test(warehouse —— 没有任何财务的码)
    fus_emp uuid := '747d70e4-4382-4555-ac2c-1aa49bb33b85';
    d date := CURRENT_DATE;
    v_ws date := date_trunc('week', CURRENT_DATE)::date;
    v_fxd date := CURRENT_DATE - 2;
    v_base text; v_fc text; v_acct text := '6100';
    v_lock date; v_reg text; v_res jsonb; v jsonb;
    jr uuid; jr2 uuid; cl uuid; v_sup uuid; ex uuid; pr uuid; pay uuid; wpr uuid; wr uuid; wrev uuid;
    tpr uuid; bt uuid; trev uuid; f1 uuid; f2 uuid; cfl uuid; bp uuid; fxa uuid; fxb uuid;
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'PROOF B|approvals must be ON'; END IF;
    SELECT code INTO v_base FROM currencies WHERE is_base;
    -- 外币取自数据(币种是数据,不是字面量 —— check-currency-literals)
    SELECT code INTO v_fc FROM currencies WHERE NOT is_base ORDER BY code LIMIT 1;
    SELECT locked_before, gst_registration_no INTO v_lock, v_reg FROM finance_settings;
    -- 不碰旧的:那一周线上没有预测、那一天线上没有汇率 —— 否则拒绝(那会改一条在这之前就在的记录)
    IF EXISTS (SELECT 1 FROM cash_forecasts WHERE week_start = v_ws) THEN RAISE EXCEPTION 'PROOF B|a forecast for % already exists on live', v_ws; END IF;
    IF EXISTS (SELECT 1 FROM fx_rates WHERE rate_date = v_fxd) THEN RAISE EXCEPTION 'PROOF B|a rate for % already exists on live', v_fxd; END IF;

    -- ── 人工分录申请(Q17):chooer@ 提 → tim@ 批;另一张提 → 撤回 ──
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', fin), true);
    jr := (submit_journal_request(d, 'AT-1c-3 live proof accrual', jsonb_build_array(
        jsonb_build_object('account_code', v_acct, 'side', 'debit', 'currency', v_base, 'amount_ccy', 12),
        jsonb_build_object('account_code', '1000', 'side', 'credit', 'currency', v_base, 'amount_ccy', 12))) ->> 'request_id')::uuid;
    jr2 := (submit_journal_request(d, 'AT-1c-3 live proof second', jsonb_build_array(
        jsonb_build_object('account_code', v_acct, 'side', 'debit', 'currency', v_base, 'amount_ccy', 5),
        jsonb_build_object('account_code', '1000', 'side', 'credit', 'currency', v_base, 'amount_ccy', 5))) ->> 'request_id')::uuid;
    PERFORM withdraw_journal_request(jr2, 'AT-1c-3 live proof: wrong month');
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', tim), true);
    PERFORM decide_journal_request(jr, true, 'proof');

    -- ── 报销单(Q20):fusheng@ 提 → chooer@ 批(一级;报销人不是决定人)──
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', fus), true);
    cl := (submit_expense_claim(fus_emp, d, 42.5, v_base, 'AT-1c-3 live proof taxi', 'AT-1c-3 live proof: the driver had no slip') ->> 'claim_id')::uuid;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', fin), true);
    PERFORM decide_expense_claim(cl, true, v_acct, 'OP', NULL, 'AT-1c-3 live proof: fine');

    -- ── 行内转账:申请 → tim@ 批 → chooer@ 付;冲销申请 → 批 → 付 ──
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', fin), true);
    tpr := (submit_bank_transfer_request(d, '1000', '1010', 1350, 1000, 'AT1C3-PROOF', 'AT-1c-3 live proof transfer') ->> 'request_id')::uuid;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', tim), true);
    PERFORM decide_payment_request(tpr, true, NULL);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', fin), true);
    PERFORM pay_payment_request(tpr, d, NULL);
    SELECT result_transfer_id INTO bt FROM payment_requests WHERE id = tpr;
    UPDATE bank_transfers SET notes = 'AT-1c-3 live proof transfer (slip filed)' WHERE id = bt;
    trev := (submit_bank_transfer_reversal_request(bt, 'AT-1c-3 live proof: wrong account') ->> 'request_id')::uuid;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', tim), true);
    PERFORM decide_payment_request(trev, true, NULL);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', fin), true);
    PERFORM pay_payment_request(trev, d, NULL);

    -- ── 代扣税缴纳(Q30):sandra@ 建一家非居民服务商;chooer@ 记一张代扣的账单、付它(代扣留在 IRAS 那一边)、缴纳 → 冲销 ──
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', san), true);
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type, tax_residence)
    VALUES ('active', 'ZZ-AT1C3-PROOF-SUP', 'AT-1c-3 live proof vendor — rolled back', 'MY', 'service_vendor', 'non_resident') RETURNING id INTO v_sup;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', fin), true);
    ex := (record_expense(p_expense_date := d, p_account_code := v_acct, p_amount := 100, p_currency := v_base, p_supplier_id := v_sup,
           p_notes := 'AT-1c-3 live proof management fee', p_tax_code := 'OP', p_wht_nature := 'management_fee', p_wht_rate_pct := 17) ->> 'expense_id')::uuid;
    pr := (submit_payment_request(v_sup, 83, v_base, NULL, NULL, d, 'AT-1c-3 live proof pay the vendor',
           jsonb_build_array(jsonb_build_object('expense_id', ex, 'amount_doc', 100))) ->> 'request_id')::uuid;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', tim), true);
    PERFORM decide_payment_request(pr, true, NULL);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', fin), true);
    PERFORM pay_payment_request(pr, d, NULL);
    wpr := (submit_wht_remittance_request(date_trunc('month', d)::date, d, 'AT1C3-IRAS', NULL, 'AT-1c-3 live proof remittance') ->> 'request_id')::uuid;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', tim), true);
    PERFORM decide_payment_request(wpr, true, NULL);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', fin), true);
    PERFORM pay_payment_request(wpr, d, NULL);
    SELECT w.id INTO wr FROM wht_remittances w JOIN payment_requests p ON p.result_journal_entry_id = w.journal_entry_id WHERE p.id = wpr;
    IF wr IS NULL THEN RAISE EXCEPTION 'PROOF B|the WHT remittance was not made'; END IF;
    wrev := (submit_wht_remittance_reversal_request(wr, 'AT-1c-3 live proof: filed against the wrong month') ->> 'request_id')::uuid;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', tim), true);
    PERFORM decide_payment_request(wrev, true, NULL);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', fin), true);
    PERFORM pay_payment_request(wrev, d, NULL);

    -- ── 现金预测(Q16):冻结 → 同一周再冻结一张(取代旧的)· 常设行 · 导入映射 · 批量汇率 ──
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', fin), true);
    PERFORM freeze_cash_forecast(v_ws, NULL);
    SELECT id INTO f1 FROM cash_forecasts WHERE week_start = v_ws AND superseded_at IS NULL;
    PERFORM freeze_cash_forecast(v_ws, 'AT-1c-3 live proof: a customer paid early');
    SELECT id INTO f2 FROM cash_forecasts WHERE week_start = v_ws AND superseded_at IS NULL;
    INSERT INTO cash_forecast_lines (label, direction, amount_ccy, currency, cadence, start_date, created_by)
    VALUES ('AT-1c-3 live proof rent', 'out', 4200, v_base, 'monthly', d, fin) RETURNING id INTO cfl;
    UPDATE cash_forecast_lines SET amount_ccy = 4400, updated_by = fin WHERE id = cfl;
    UPDATE cash_forecast_lines SET is_active = false, updated_by = fin WHERE id = cfl;
    INSERT INTO bank_import_profiles (bank_account_code, name, mapping) VALUES ('1000', 'AT-1c-3 live proof DBS', '{"date": 0, "amount": 3}') RETURNING id INTO bp;
    UPDATE bank_import_profiles SET name = 'AT-1c-3 live proof DBS business' WHERE id = bp;
    UPDATE bank_import_profiles SET deleted_at = now() WHERE id = bp;
    PERFORM record_fx_rates_bulk(jsonb_build_array(
        jsonb_build_object('currency', v_fc, 'rate_date', v_fxd, 'rate_type', 'tt_buy', 'rate', 1.3388, 'source', 'DBS'),
        jsonb_build_object('currency', v_fc, 'rate_date', v_fxd, 'rate_type', 'tt_sell', 'rate', 1.3521, 'source', 'DBS')));
    SELECT id INTO fxa FROM fx_rates WHERE rate_date = v_fxd AND rate_type = 'tt_buy';
    SELECT id INTO fxb FROM fx_rates WHERE rate_date = v_fxd AND rate_type = 'tt_sell';

    -- ── 两块面板与公司资料:改 GST 注册号(tim@)· 挪锁往前一个月、再挪回来(chooer@,设置页那一格的直连写)· 改公司地址(tim@)──
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', tim), true);
    PERFORM set_finance_settings(jsonb_build_object('gst_registration_no', v_reg || '-PROOF'));
    UPDATE company_profile SET address_lines = 'AT-1c-3 live proof address', updated_by = tim WHERE id;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', fin), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE finance_settings SET locked_before = (v_lock + interval '1 month')::date, updated_by = fin WHERE id;
    UPDATE finance_settings SET locked_before = v_lock, updated_by = fin WHERE id;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);

    -- ── 读:以 tim@;报销单再以 fusheng@(M8)──
    v := pg_temp.p_keep('B lock', tim, 'finance_lock', 'true');
    IF (SELECT count(*) FROM jsonb_array_elements(v) e WHERE e ->> 'table_name' = 'finance_settings' AND e -> 'changed_columns' ? 'locked_before') < 2 THEN
        RAISE EXCEPTION 'PROOF B|the lock trail does not show both lock moves'; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v) e, jsonb_array_elements_text(COALESCE(e -> 'changed_columns', '[]')) col
                WHERE e ->> 'table_name' = 'finance_settings' AND col <> 'locked_before') THEN
        RAISE EXCEPTION 'PROOF B|the lock trail shows the GST change (M6)'; END IF;
    v := pg_temp.p_keep('B gst', tim, 'finance_gst', 'true');
    IF NOT pg_temp.p_has(v, 'finance_settings', 'UPDATE', 'gst_registration_no') OR pg_temp.p_has(v, 'finance_settings', 'UPDATE', 'locked_before') THEN
        RAISE EXCEPTION 'PROOF B|the GST trail should show the registration number and not the lock (M6)'; END IF;
    v := pg_temp.p_keep('B company', tim, 'company_profile', 'true');
    IF NOT pg_temp.p_has(v, 'company_profile', 'UPDATE', 'address_lines') THEN RAISE EXCEPTION 'PROOF B|the company profile edit is missing'; END IF;
    v := pg_temp.p_keep('B journal request', tim, 'journal_request', jr::text);
    IF NOT pg_temp.p_has(v, 'journal_requests', 'INSERT') OR NOT pg_temp.p_has(v, 'approval_log', 'INSERT') OR NOT pg_temp.p_has(v, 'journal_entries', 'INSERT') THEN
        RAISE EXCEPTION 'PROOF B|the journal request trail is incomplete'; END IF;
    v := pg_temp.p_keep('B journal request withdrawn', tim, 'journal_request', jr2::text);
    v := pg_temp.p_keep('B claim', tim, 'expense_claim', cl::text);
    IF NOT pg_temp.p_has(v, 'approval_log', 'INSERT') OR NOT pg_temp.p_has(v, 'expenses', 'INSERT') THEN RAISE EXCEPTION 'PROOF B|the claim trail misses the decision or the expense'; END IF;
    v := pg_temp.p_keep('B claim · claimant', fus, 'my_expense_claim', cl::text);
    IF pg_temp.p_has(v, 'approval_log', 'INSERT') OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) e WHERE (e ->> 'row_hidden')::boolean) THEN
        RAISE EXCEPTION 'PROOF B|the claimant should see the decision as Restricted (M8 · Q4)'; END IF;
    v := pg_temp.p_keep('B transfer', tim, 'bank_transfer', bt::text);
    IF NOT pg_temp.p_has(v, 'bank_transfers', 'UPDATE', 'reversed_at') THEN RAISE EXCEPTION 'PROOF B|the transfer reversal is missing'; END IF;
    v := pg_temp.p_keep('B WHT remittance', tim, 'wht_remittance', wr::text);
    IF NOT pg_temp.p_has(v, 'journal_entries', 'UPDATE', 'reversed_by') THEN RAISE EXCEPTION 'PROOF B|the WHT reversal is missing (Q30)'; END IF;
    PERFORM pg_temp.p_keep('B forecast (new)', tim, 'cash_forecast', f2::text, 'forecast');
    PERFORM pg_temp.p_keep('B forecast (old)', tim, 'cash_forecast', f1::text, 'forecast');
    PERFORM pg_temp.p_keep('B recurring line', tim, 'cash_forecast_line', cfl::text);
    PERFORM pg_temp.p_keep('B import mapping', tim, 'bank_import_profile', bp::text);
    PERFORM pg_temp.p_keep('B FX bulk (buy)', tim, 'fx_rate', fxa::text, 'fxbulk');
    PERFORM pg_temp.p_keep('B FX bulk (sell)', tim, 'fx_rate', fxb::text, 'fxbulk');
    IF EXISTS (SELECT 1 FROM p_out WHERE label LIKE 'B%' AND pg_temp.p_twice(rows) IS NOT NULL) THEN
        RAISE EXCEPTION 'PROOF B|a row shows twice: %', (SELECT string_agg(label || ': ' || pg_temp.p_twice(rows), '; ') FROM p_out WHERE label LIKE 'B%' AND pg_temp.p_twice(rows) IS NOT NULL); END IF;
    RAISE NOTICE 'PROOF B passed: journal request %, claim %, transfer request %, WHT remittance %, forecasts %/%, rates on %',
        (SELECT label FROM journal_requests WHERE id = jr), (SELECT code FROM expense_claims WHERE id = cl), (SELECT code FROM payment_requests WHERE id = tpr),
        (SELECT code FROM wht_remittances WHERE id = wr), (SELECT code FROM cash_forecasts WHERE id = f1), (SELECT code FROM cash_forecasts WHERE id = f2), v_fxd;
END;
$b$;

-- 给造句器的那一份:每一条一行 JSON
\pset tuples_only on
\pset format unaligned
SELECT jsonb_build_object('label', label, 'subject', subject, 'id', id, 'grp', grp, 'rows', rows)::text FROM p_out ORDER BY label LIKE 'B%', label, subject, id;

ROLLBACK;
