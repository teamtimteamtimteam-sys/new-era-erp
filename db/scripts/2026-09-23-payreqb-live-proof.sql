-- db/scripts/2026-09-23-payreqb-live-proof.sql
-- PAY-REQ-1 · Batch B 的线上证明 —— 拒绝、读回,以及两段【整支回滚】的对照生命周期
-- (一笔转账与它的冲销;一笔代扣税缴纳与通用冲销口对它的拒绝)。
-- 整支一笔事务,最后 ROLLBACK:线上一行都不留(申请、分录、转账、缴纳、留痕)。
--
-- 为什么不在 db/fixtures/:它要的是【线上真账号】在【线上真数据】上被拒。fixture 211 在重建库上
-- 证同一批规矩的形状;这一支证的是"线上此刻,这几个人,真的被拒了 / 真的走得通"。
--
-- 身份:以 postgres 连接(rolbypassrls = t),每一格用 set_config('request.jwt.claims') 换成那个
-- 真账号,并在 SET LOCAL ROLE authenticated 之下跑 —— RLS、列权限、函数 EXECUTE 按那个人判。
-- 失败 = RAISE(退出码非零);成功 = 最后一行 NOTICE 'PAYREQB LIVE PROOF: n cells passed'。
--
-- 线上此刻(以 postgres 读基表实测,2026-09-23):bank_transfers 0 行、wht_remittances 0 行、
-- 科目 2150 没有任何分录行 —— 所以代扣税那一段要先在事务里记一笔 2150 的代扣(手工分录,
-- 由 chooer@ 以 authenticated 记;与其余一切一起回滚),才有东西可缴、可冲。
BEGIN;

CREATE FUNCTION pg_temp.as_user(p_email text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
    SELECT id INTO v FROM auth.users WHERE email = p_email;
    IF v IS NULL THEN RAISE EXCEPTION 'PROOF_SETUP|no such account %', p_email; END IF;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
    RETURN v;
END $$;

CREATE FUNCTION pg_temp.try_sql(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_msg text;
BEGIN
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        EXECUTE p_sql;
        EXECUTE 'RESET ROLE';
        RETURN NULL;
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        EXECUTE 'RESET ROLE';
        RETURN v_msg;
    END;
END $$;

CREATE FUNCTION pg_temp.run_json(p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
END $$;

CREATE FUNCTION pg_temp.count_as(p_sql text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v bigint;
BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
END $$;

DO $proof$
DECLARE
    c record;
    v_msg text;
    v_cells int := 0;
    v_acct text; v_base text;
    v_res jsonb; v_req uuid; v_req2 uuid; v_tid uuid; v_wid uuid; v_eid uuid;
    v_je bigint; v_bt bigint; v_n bigint; v_m bigint; v_unrem numeric;
BEGIN
    SELECT code INTO v_acct FROM accounts WHERE account_type = 'expense' AND is_active ORDER BY code LIMIT 1;
    SELECT code INTO v_base FROM currencies WHERE is_base;
    IF v_acct IS NULL OR v_base IS NULL OR bank_native_currency('1000') <> v_base OR bank_native_currency('1010') = v_base THEN
        RAISE EXCEPTION 'PROOF_SETUP|expected 1000 in the base currency and 1010 in a foreign one';
    END IF;

    FOR c IN SELECT * FROM (VALUES
      ('chooer@evoltrya.test', 'finance 直接记转账 → 要申请',
         'SELECT record_bank_transfer(DATE ''2026-09-23'', ''1000'', ''1010'', 1, 0.75, NULL, ''proof'')',
         'PAYMENT_REQUEST_REQUIRED|bank_transfer'),
      ('chooer@evoltrya.test', 'finance 直接冲销转账 → 要冲销申请',
         'SELECT reverse_bank_transfer(gen_random_uuid(), DATE ''2026-09-23'', ''proof'')',
         'PAYMENT_REQUEST_REQUIRED|bank_transfer_reversal'),
      ('chooer@evoltrya.test', 'finance 直接缴代扣税 → 要申请',
         'SELECT remit_wht(DATE ''2026-09-01'', DATE ''2026-09-23'', ''proof'', ''1000'', NULL)',
         'PAYMENT_REQUEST_REQUIRED|wht_remittance'),
      ('chooer@evoltrya.test', 'finance 直接调转账引擎 → 调不到',
         'SELECT record_bank_transfer_internal(DATE ''2026-09-23'', ''1000'', ''1010'', 1, 0.75, NULL, ''proof'')',
         'permission denied for function record_bank_transfer_internal'),
      ('chooer@evoltrya.test', 'finance 直接调缴纳引擎 → 调不到',
         'SELECT remit_wht_internal(DATE ''2026-09-01'', DATE ''2026-09-23'', ''proof'', ''1000'', NULL, NULL)',
         'permission denied for function remit_wht_internal'),
      ('chooer@evoltrya.test', 'finance 直接调缴纳冲销引擎 → 调不到',
         'SELECT reverse_wht_remittance_internal(gen_random_uuid(), DATE ''2026-09-23'', ''proof'')',
         'permission denied for function reverse_wht_remittance_internal'),
      ('chooer@evoltrya.test', 'finance 提缴纳申请,而线上这个月没有欠款 → 按名拒',
         'SELECT submit_wht_remittance_request(DATE ''2026-08-01'', DATE ''2026-09-23'', ''proof'', NULL, NULL)',
         'WHT_NOTHING_TO_REMIT|%'),
      ('tim@evoltrya.test', 'CFO 提不了转账申请(提单归财务)',
         'SELECT submit_bank_transfer_request(DATE ''2026-09-23'', ''1000'', ''1010'', 1, 0.75, NULL, ''proof'')',
         'PERMISSION_DENIED|module.finance.edit'),
      -- ★ 这一格原本用 admin@。开工后实测(2026-09-23 23:33:27 CST,created_by = admin@swm-os.test):
      --   admin 角色被人改成持全部 45 个码(含 module.finance.edit)—— 那是 Tim 的线上动作,本刀不碰,
      --   交回报告里点名。于是"没有写码的人"改用 fusheng@(warehouse:没有 finance 的任何码)。
      ('fusheng@evoltrya.test', 'warehouse 提不了转账申请(没有财务码)',
         'SELECT submit_bank_transfer_request(DATE ''2026-09-23'', ''1000'', ''1010'', 1, 0.75, NULL, ''proof'')',
         'PERMISSION_DENIED|module.finance.edit')
    ) AS t(who, what, sql, expect) LOOP
        PERFORM pg_temp.as_user(c.who);
        v_msg := pg_temp.try_sql(c.sql);
        IF v_msg IS NULL OR v_msg NOT LIKE c.expect THEN
            RAISE EXCEPTION 'PAYREQB_PROOF|% | %: expected %, got %', c.who, c.what, c.expect, COALESCE(v_msg, '(no error)');
        END IF;
        v_cells := v_cells + 1;
        RAISE NOTICE 'cell % | % | % → %', v_cells, c.who, c.what, v_msg;
    END LOOP;

    -- ── 对照生命周期 1(整支回滚):转账 1000 → 1010,提 → 自批被拒 → 未批不能执行 → CFO 执行不了
    --    → CFO 批 → 不给日期执行不了 → 财务执行 → 冲销申请 → 批 → 执行 ──
    SELECT count(*) INTO v_je FROM journal_entries;
    SELECT count(*) INTO v_bt FROM bank_transfers;
    PERFORM pg_temp.as_user('chooer@evoltrya.test');
    v_res := pg_temp.run_json('SELECT submit_bank_transfer_request(DATE ''2026-09-23'', ''1000'', ''1010'', 1, 0.75, ''PROOF-REF'', ''PAY-REQ-1 Batch B live proof'')');
    v_req := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'submitted' OR (v_res->>'amount_base')::numeric <> 1 THEN
        RAISE EXCEPTION 'PAYREQB_PROOF|transfer submit: %', v_res; END IF;
    v_cells := v_cells + 1; RAISE NOTICE 'cell % | chooer@ | 提转账申请 → %', v_cells, v_res;

    v_msg := pg_temp.try_sql(format('SELECT decide_payment_request(%L::uuid, true, NULL)', v_req));
    IF v_msg IS DISTINCT FROM 'SELF_APPROVAL_FORBIDDEN|raiser' THEN
        RAISE EXCEPTION 'PAYREQB_PROOF|raiser approving own: %', COALESCE(v_msg, '(approved)'); END IF;
    v_cells := v_cells + 1; RAISE NOTICE 'cell % | chooer@ | 批自己提的 → %', v_cells, v_msg;

    v_msg := pg_temp.try_sql(format('SELECT pay_payment_request(%L::uuid, DATE ''2026-09-23'', NULL)', v_req));
    IF v_msg NOT LIKE 'PAYMENT_REQUEST_NOT_APPROVED|%|submitted' THEN
        RAISE EXCEPTION 'PAYREQB_PROOF|executing unapproved: %', COALESCE(v_msg, '(done)'); END IF;
    v_cells := v_cells + 1; RAISE NOTICE 'cell % | chooer@ | 执行一张没批的 → %', v_cells, v_msg;

    PERFORM pg_temp.as_user('tim@evoltrya.test');
    v_msg := pg_temp.try_sql(format('SELECT pay_payment_request(%L::uuid, DATE ''2026-09-23'', NULL)', v_req));
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|module.finance.edit' THEN
        RAISE EXCEPTION 'PAYREQB_PROOF|CFO executing: %', COALESCE(v_msg, '(done)'); END IF;
    v_cells := v_cells + 1; RAISE NOTICE 'cell % | tim@ | CFO 自己执行 → %', v_cells, v_msg;

    v_res := pg_temp.run_json(format('SELECT decide_payment_request(%L::uuid, true, NULL)', v_req));
    IF v_res->>'status' <> 'approved' THEN RAISE EXCEPTION 'PAYREQB_PROOF|CFO approve: %', v_res; END IF;
    IF (SELECT count(*) FROM journal_entries) <> v_je OR (SELECT count(*) FROM bank_transfers) <> v_bt THEN
        RAISE EXCEPTION 'PAYREQB_PROOF|submit/approve touched the ledger or bank_transfers'; END IF;
    v_cells := v_cells + 1; RAISE NOTICE 'cell % | tim@ | CFO 批准 → %;分录 % → %,转账 % → %(提与批都不碰)',
        v_cells, v_res, v_je, (SELECT count(*) FROM journal_entries), v_bt, (SELECT count(*) FROM bank_transfers);

    PERFORM pg_temp.as_user('chooer@evoltrya.test');
    v_msg := pg_temp.try_sql(format('SELECT pay_payment_request(%L::uuid, NULL, NULL)', v_req));
    IF v_msg IS DISTINCT FROM 'PAYMENT_DATE_REQUIRED' THEN
        RAISE EXCEPTION 'PAYREQB_PROOF|executing without a date: %', COALESCE(v_msg, '(done)'); END IF;
    v_cells := v_cells + 1; RAISE NOTICE 'cell % | chooer@ | 不给转账日执行 → %', v_cells, v_msg;

    v_res := pg_temp.run_json(format('SELECT pay_payment_request(%L::uuid, DATE ''2026-09-23'', NULL)', v_req));
    SELECT result_transfer_id, result_journal_entry_id INTO v_tid, v_eid FROM payment_requests WHERE id = v_req;
    IF v_tid IS NULL OR v_eid IS NULL OR (SELECT count(*) FROM journal_entries) <> v_je + 1
       OR (SELECT count(*) FROM bank_transfers) <> v_bt + 1 THEN
        RAISE EXCEPTION 'PAYREQB_PROOF|transfer execute: %', v_res; END IF;
    v_cells := v_cells + 1; RAISE NOTICE 'cell % | chooer@ | 执行转账 → % ;分录恰好 +1、转账恰好 +1', v_cells, v_res->>'journal_code';

    v_msg := pg_temp.try_sql(format('SELECT reverse_journal_entry(%L::uuid, DATE ''2026-09-23'', ''proof'')', v_eid));
    IF v_msg NOT LIKE 'JE_REVERSE_USE_SOURCE_PATH|%|transfer' THEN
        RAISE EXCEPTION 'PAYREQB_PROOF|generic reversal of a transfer entry: %', COALESCE(v_msg, '(reversed)'); END IF;
    v_cells := v_cells + 1; RAISE NOTICE 'cell % | chooer@ | 从通用冲销口冲转账分录 → %', v_cells, v_msg;

    v_req2 := (pg_temp.run_json(format('SELECT submit_bank_transfer_reversal_request(%L::uuid, ''proof: wrong account'')', v_tid))->>'request_id')::uuid;
    PERFORM pg_temp.as_user('tim@evoltrya.test');
    PERFORM pg_temp.run_json(format('SELECT decide_payment_request(%L::uuid, true, NULL)', v_req2));
    PERFORM pg_temp.as_user('chooer@evoltrya.test');
    PERFORM pg_temp.run_json(format('SELECT pay_payment_request(%L::uuid, DATE ''2026-09-23'', NULL)', v_req2));
    IF (SELECT reversed_at FROM bank_transfers WHERE id = v_tid) IS NULL OR (SELECT count(*) FROM journal_entries) <> v_je + 2 THEN
        RAISE EXCEPTION 'PAYREQB_PROOF|transfer reversal did not take'; END IF;
    v_cells := v_cells + 1; RAISE NOTICE 'cell % | chooer@ 提 → tim@ 批 → chooer@ 执行转账冲销 → 原转账已冲,分录再 +1', v_cells;

    -- ── 对照生命周期 2(整支回滚):先记 12.34 的代扣(手工分录贷 2150)→ 缴纳申请冻结 12.34 →
    --    CFO 批 → 财务付 → 这个月欠款归零 → 通用冲销口冲这张缴纳分录 → 按名拒 ──
    PERFORM pg_temp.as_user('chooer@evoltrya.test');
    PERFORM pg_temp.run_json(format(
        'SELECT post_journal_entry(DATE ''2026-09-23'', ''PAY-REQ-1 Batch B proof: withheld'', ''manual'', NULL, %L::jsonb)',
        jsonb_build_array(
            jsonb_build_object('account_code', v_acct, 'side', 'debit',  'currency', v_base, 'amount_ccy', 12.34),
            jsonb_build_object('account_code', '2150', 'side', 'credit', 'currency', v_base, 'amount_ccy', 12.34))));
    v_res := pg_temp.run_json('SELECT submit_wht_remittance_request(DATE ''2026-09-01'', DATE ''2026-09-23'', ''PROOF-IRAS'', NULL, ''proof'')');
    v_req := (v_res->>'request_id')::uuid;
    IF (v_res->>'amount_base')::numeric <> 12.34 OR (SELECT amount_ccy FROM payment_requests WHERE id = v_req) <> 12.34 THEN
        RAISE EXCEPTION 'PAYREQB_PROOF|WHT request should freeze 12.34: %', v_res; END IF;
    PERFORM pg_temp.as_user('tim@evoltrya.test');
    PERFORM pg_temp.run_json(format('SELECT decide_payment_request(%L::uuid, true, NULL)', v_req));
    PERFORM pg_temp.as_user('chooer@evoltrya.test');
    PERFORM pg_temp.run_json(format('SELECT pay_payment_request(%L::uuid, DATE ''2026-09-23'', NULL)', v_req));
    SELECT unremitted_base INTO v_unrem FROM wht_liability_by_month WHERE period_month = DATE '2026-09-01';
    SELECT id, journal_entry_id INTO v_wid, v_eid FROM wht_remittances
     WHERE journal_entry_id = (SELECT result_journal_entry_id FROM payment_requests WHERE id = v_req);
    IF v_wid IS NULL OR v_unrem <> 0 THEN
        RAISE EXCEPTION 'PAYREQB_PROOF|WHT remittance did not clear the month: %', v_unrem; END IF;
    v_cells := v_cells + 1; RAISE NOTICE 'cell % | chooer@ 提 12.34 → tim@ 批 → chooer@ 付 → 2026-09 欠款 0', v_cells;

    v_msg := pg_temp.try_sql(format('SELECT reverse_journal_entry(%L::uuid, DATE ''2026-09-23'', ''proof'')', v_eid));
    IF v_msg NOT LIKE 'JE_REVERSE_USE_SOURCE_PATH|%|wht_remittance' THEN
        RAISE EXCEPTION 'PAYREQB_PROOF|generic reversal of a WHT entry: %', COALESCE(v_msg, '(reversed)'); END IF;
    v_cells := v_cells + 1; RAISE NOTICE 'cell % | chooer@ | 从通用冲销口冲缴纳分录 → %', v_cells, v_msg;

    -- ── 读回:同一会话、同一张表、两个身份 ──
    PERFORM pg_temp.as_user('tim@evoltrya.test');
    v_n := pg_temp.count_as('SELECT count(*) FROM payment_requests WHERE kind IN (''bank_transfer'',''bank_transfer_reversal'',''wht_remittance'')');
    PERFORM pg_temp.as_user('fusheng@evoltrya.test');
    v_m := pg_temp.count_as('SELECT count(*) FROM payment_requests');
    IF v_n <> 3 OR v_m <> 0 THEN
        RAISE EXCEPTION 'PAYREQB_PROOF|tim@ should read 3 new-kind requests and fusheng@ 0, got % / %', v_n, v_m; END IF;
    v_cells := v_cells + 1; RAISE NOTICE 'cell % | tim@ 读到 % 张新种类申请;fusheng@ 读到 %', v_cells, v_n, v_m;

    RAISE NOTICE 'PAYREQB LIVE PROOF: % cells passed', v_cells;
END;
$proof$;

ROLLBACK;
