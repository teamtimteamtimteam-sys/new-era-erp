-- fixture 289 —— 付款 · 行内转账 · 代扣税缴纳:银行行已经配上对账单行,就不冲(PAYROLL-PAY-REVERSAL-1,2026-10-22)
--
-- Tim 2026-10-22(Step 0 Q6):工资付款冲销的那道银行判据,【同一刀】加到另外三条冲销路上 —— 它们有同一个缺口
-- (Step 0 量过:库里没有一条冲销路看 bank_line_matches)。每一条路一臂,三格:
--   ① 配着的时候提冲销申请 → 按名拒 REVERSAL_BANK_MATCHED(提交的试跑走的是那支引擎;批准的试跑是同一支,fixture 288 F 证了批那一格);
--   ② 取消配对 → 提得上去(审批关着:生下来 approved);
--   ③ 再配上 → 执行按名拒;取消配对 → 执行冲得掉,原分录 reversed。
--   外加一格:对完账的对账单,拒绝说 reconciled(先撤销对账)。
-- 审批关着(本支测的是银行判据,不是审批链 —— 那是 210 / 211 的事)。自带数据;日期在真实的过去(281 的规矩:晚于今天的单据按名拒)。
BEGIN;
SET LOCAL statement_timeout = '180s';

CREATE FUNCTION pg_temp.f289_try(p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE p_sql;
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    RETURN SQLERRM;
END;
$f$;

DO $$
DECLARE
    u_fin uuid := gen_random_uuid();
    r_fin uuid;
    v_base text; v_acct text; v_usd text; v_cust uuid;
    d date := DATE '2025-05-05';
    v_month date := DATE '2025-05-01';
    v_pay uuid; v_tid uuid; v_wid uuid; v_eid uuid;
    v_stmt uuid; v_l1 uuid; v_l2 uuid; v_l3 uuid; v_jl uuid;
    v_req uuid; v_msg text; r record;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT code INTO v_acct FROM accounts WHERE account_type = 'expense' AND is_active ORDER BY code LIMIT 1;
    v_usd := CASE WHEN bank_native_currency('1010') <> v_base THEN '1010' END;
    IF v_base IS NULL OR v_acct IS NULL OR v_usd IS NULL OR bank_native_currency('1000') <> v_base THEN
        RAISE EXCEPTION 'FIXTURE 289 布景失败:要本位币户 1000、外币户 1010 与一个费用科目(依赖种子数据)'; END IF;

    INSERT INTO auth.users (id, email_confirmed_at) VALUES (u_fin, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx289-fin','f','f',true) RETURNING id INTO r_fin;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_fin, c FROM unnest(ARRAY['module.finance.view', 'module.finance.edit', 'data.view_prices', 'data.view_purchase_prices']) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u_fin, r_fin);

    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE finance_settings SET locked_before = NULL;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;
    INSERT INTO customers (code, legal_name, country) VALUES ('FX289-C', 'FX289 Customer', 'SG') RETURNING id INTO v_cust;
    -- 代扣税:这个月在 2150 上记 70 的代扣(211 D 臂的做法)
    PERFORM post_journal_entry(d, 'fx289 withheld', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code', v_acct, 'side', 'debit',  'currency', v_base, 'amount_ccy', 70),
        jsonb_build_object('account_code', '2150', 'side', 'credit', 'currency', v_base, 'amount_ccy', 70)));

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    -- 三样东西:一笔收款(进 1000 +100)· 一笔转账(1000 −135 → 1010)· 一笔代扣税缴纳(1000 −70)
    v_pay := (record_payment('in', v_cust, 100, v_base, NULL, '1000', d, 'fx289', '[]'::jsonb)->>'payment_id')::uuid;
    -- 转账与缴纳走内层引擎(以 postgres 调,带财务的会话:引擎里读的视图问的是"你是谁")—— 本支测的不是它们的申请链
    v_tid := (record_bank_transfer_internal(d, '1000', v_usd, 135, 100, 'FX289-T', 'fx289')->>'transfer_id')::uuid;
    v_wid := (remit_wht_internal(v_month, d, 'ZZ-F289-IRAS', '1000', 'fx289', 70)->>'remittance_id')::uuid;
    IF v_pay IS NULL OR v_tid IS NULL OR v_wid IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 289 布景失败:收款 / 转账 / 缴纳没有建出来(% / % / %)', v_pay, v_tid, v_wid; END IF;

    -- 一张对账单,三行,各对一笔
    v_stmt := (import_bank_statement('1000', d, d + 3, 1000, 895, 'fx289.csv', jsonb_build_array(
        jsonb_build_object('line_date', d, 'description', 'receipt',  'reference', 'P', 'amount', 100),
        jsonb_build_object('line_date', d, 'description', 'transfer', 'reference', 'T', 'amount', -135),
        jsonb_build_object('line_date', d, 'description', 'IRAS',     'reference', 'W', 'amount', -70)))->>'statement_id')::uuid;
    SELECT id INTO v_l1 FROM bank_statement_lines WHERE statement_id = v_stmt AND line_no = 1;
    SELECT id INTO v_l2 FROM bank_statement_lines WHERE statement_id = v_stmt AND line_no = 2;
    SELECT id INTO v_l3 FROM bank_statement_lines WHERE statement_id = v_stmt AND line_no = 3;

    FOR r IN SELECT * FROM (VALUES
            ('payment',  v_l1, (SELECT journal_entry_id FROM payments WHERE id = v_pay),
             format('SELECT submit_payment_reversal_request(%L, %L)', v_pay, 'fx289 payment')),
            ('transfer', v_l2, (SELECT journal_entry_id FROM bank_transfers WHERE id = v_tid),
             format('SELECT submit_bank_transfer_reversal_request(%L, %L)', v_tid, 'fx289 transfer')),
            ('wht',      v_l3, (SELECT journal_entry_id FROM wht_remittances WHERE id = v_wid),
             format('SELECT submit_wht_remittance_reversal_request(%L, %L)', v_wid, 'fx289 wht'))) x(k, bl, je, submit_sql) LOOP
        SELECT l.id INTO v_jl FROM journal_lines l JOIN accounts a ON a.id = l.account_id
         WHERE l.entry_id = r.je AND a.code = '1000';
        PERFORM match_bank_line(r.bl, ARRAY[v_jl]);
        -- ① 配着 → 提交按名拒
        v_msg := pg_temp.f289_try(r.submit_sql);
        IF v_msg NOT LIKE 'REVERSAL_BANK_MATCHED|%|%|open' THEN
            RAISE EXCEPTION 'FIXTURE 289-% ① 失败:已配对的 % 提冲销申请应当按名拒,实得 %', r.k, r.k, v_msg; END IF;
        IF EXISTS (SELECT 1 FROM payment_requests WHERE notes = 'fx289 ' || r.k) THEN
            RAISE EXCEPTION 'FIXTURE 289-% ① 失败:被拒的提交留下了一张申请', r.k; END IF;
        -- 对完账的对账单:同一句,换成 reconciled(直接写状态 —— 本格问的是那句话)
        PERFORM set_config('request.jwt.claims', '', true);
        UPDATE bank_statements SET status = 'reconciled' WHERE id = v_stmt;
        PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
        v_msg := pg_temp.f289_try(r.submit_sql);
        IF v_msg NOT LIKE 'REVERSAL_BANK_MATCHED|%|%|reconciled' THEN
            RAISE EXCEPTION 'FIXTURE 289-% 失败:对完账的对账单,拒绝应当说 reconciled,实得 %', r.k, v_msg; END IF;
        PERFORM set_config('request.jwt.claims', '', true);
        UPDATE bank_statements SET status = 'open' WHERE id = v_stmt;
        PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
        -- ② 取消配对 → 提得上去(审批关着,生下来 approved)
        PERFORM unmatch_bank_line(r.bl);
        EXECUTE r.submit_sql;
        SELECT id INTO v_req FROM payment_requests WHERE notes = 'fx289 ' || r.k AND status = 'approved';
        IF v_req IS NULL THEN
            RAISE EXCEPTION 'FIXTURE 289-% ② 失败:取消配对之后应当提得上去', r.k; END IF;
        -- ③ 再配上 → 执行按名拒;取消配对 → 执行冲得掉
        PERFORM match_bank_line(r.bl, ARRAY[v_jl]);
        -- 付款冲销执行时不收日期(PAYMENT_REVERSAL_TAKES_NO_DATE);转账与缴纳的冲销收一个
        v_msg := pg_temp.f289_try(format('SELECT pay_payment_request(%L, %L)', v_req, CASE WHEN r.k = 'payment' THEN NULL ELSE d + 2 END));
        IF v_msg NOT LIKE 'REVERSAL_BANK_MATCHED|%|%|open' THEN
            RAISE EXCEPTION 'FIXTURE 289-% ③ 失败:执行时银行行已配对,应当按名拒,实得 %', r.k, v_msg; END IF;
        PERFORM unmatch_bank_line(r.bl);
        PERFORM pay_payment_request(v_req, CASE WHEN r.k = 'payment' THEN NULL ELSE d + 2 END);
        IF (SELECT status FROM journal_entries WHERE id = r.je) <> 'reversed' THEN
            RAISE EXCEPTION 'FIXTURE 289-% ③ 失败:取消配对之后执行应当冲掉原分录', r.k; END IF;
    END LOOP;

    RAISE NOTICE 'FIXTURE 289 全部通过:付款 · 行内转账 · 代扣税缴纳 —— 银行行已配对,提交与执行都按名拒(open / reconciled 两种说法);取消配对之后照常冲';
END $$;
ROLLBACK;
