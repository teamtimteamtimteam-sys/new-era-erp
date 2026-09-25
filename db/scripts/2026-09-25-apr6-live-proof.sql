-- db/scripts/2026-09-25-apr6-live-proof.sql
-- APR-6 · 线上证明(一笔事务,最后 ROLLBACK —— 线上什么都不留)。
-- 以 postgres 连接(rolbypassrls = t);每一格用 request.jwt.claims 换成一个【真账号】,在
-- SET LOCAL ROLE authenticated 下跑,拒绝与读回各印一行 CELL。任何一格与期望不符 → RAISE,整笔回滚,
-- psql 以非零退出(PROOF_OWN_EXIT)。
--   chooer@ = finance(提单人)· tim@ = cfo(批)· admin@ = admin(与 tim@ 同一个人)· sandra@ = cco(看得见、不是二级)·
--   fusheng@ = warehouse(没有任何财务码)
-- 用到的线上行(2026-09-25 以 postgres 读基表):JE-2026-0079(线上唯一一张手工凭证,chooer@ 记的);
-- 一张 expense 分录与一张 payment 分录(取最早那一张,只用来证凭证页的门按名指路)。
-- 【锁期那一格不在这里】期间锁在线上只能经 close_period(月末、折旧、成本分摊都要齐)或 CFO 的设置门,
-- 在一笔回滚的事务里造不出一个诚实的月结;"锁永远赢、批准按 PERIOD_LOCKED 拒、提单人锁不了"由
-- fixture 225 的 H 臂在重建库上钉着。本证明的 B5 证的是提交时按引擎原话拒一个已锁的日期。
\set ON_ERROR_STOP 1
\pset footer off
BEGIN;
SELECT current_user AS identity, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user) AS bypassrls, now() AS started_at;

CREATE FUNCTION pg_temp.as_user(p_email text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
    SELECT id INTO v FROM auth.users WHERE email = p_email;
    IF v IS NULL THEN RAISE EXCEPTION 'PROOF_SETUP|no account %', p_email; END IF;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.as_user(text) TO authenticated;

CREATE FUNCTION pg_temp.try_as(p_email text, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.as_user(p_email);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN SQLERRM;
END $$;

CREATE FUNCTION pg_temp.call_as(p_email text, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.as_user(p_email);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
END $$;

CREATE FUNCTION pg_temp.bal(p_code text) RETURNS numeric LANGUAGE sql AS $$
    SELECT round(COALESCE(sum(l.debit - l.credit), 0), 2) FROM accounts a
      LEFT JOIN journal_lines l ON l.account_id = a.id WHERE a.code = p_code
$$;

CREATE FUNCTION pg_temp.recon() RETURNS TABLE(side text, list numeric, ledger numeric, unexplained numeric) LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.as_user('tim@evoltrya.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    RETURN QUERY SELECT s->>'side', (s->>'list_base')::numeric, (s->>'ledger_base')::numeric, (s->>'unexplained_base')::numeric
                   FROM jsonb_array_elements(list_ledger_reconciliation()->'sides') s;
    EXECUTE 'RESET ROLE';
END $$;

CREATE FUNCTION pg_temp.lines(p_dr text, p_cr text, p_amt numeric, p_amt_cr numeric DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
    SELECT jsonb_build_array(
        jsonb_build_object('account_code', p_dr, 'side', 'debit', 'currency', (SELECT code FROM currencies WHERE is_base),
                           'amount_ccy', p_amt, 'line_memo', 'APR-6 live proof'),
        jsonb_build_object('account_code', p_cr, 'side', 'credit', 'currency', (SELECT code FROM currencies WHERE is_base),
                           'amount_ccy', COALESCE(p_amt_cr, p_amt), 'line_memo', 'APR-6 live proof'))
$$;

SELECT side, list, ledger, unexplained FROM pg_temp.recon();

DO $proof$
DECLARE
    v_tim uuid; v_choo uuid;
    v_je79 uuid; v_exp uuid; v_pay uuid;
    q uuid; qr uuid; qx uuid; v_res jsonb; v_msg text; v_n int; v_je0 int; v_entry uuid; v_rev uuid;
    b1000 numeric; b6200 numeric; d date := CURRENT_DATE;
BEGIN
    SELECT id INTO v_tim FROM auth.users WHERE email = 'tim@evoltrya.test';
    SELECT id INTO v_choo FROM auth.users WHERE email = 'chooer@evoltrya.test';
    SELECT id INTO v_je79 FROM journal_entries WHERE code = 'JE-2026-0079';
    SELECT id INTO v_exp FROM journal_entries WHERE source_type = 'expense' AND status = 'posted' ORDER BY code LIMIT 1;
    SELECT id INTO v_pay FROM journal_entries WHERE source_type = 'payment' AND status = 'posted' ORDER BY code LIMIT 1;
    IF v_je79 IS NULL OR v_exp IS NULL OR v_pay IS NULL THEN RAISE EXCEPTION 'PROOF_SETUP|a named live entry is missing'; END IF;
    SELECT count(*) INTO v_je0 FROM journal_entries;
    b1000 := pg_temp.bal('1000'); b6200 := pg_temp.bal('6200');
    RAISE NOTICE 'CELL S0 | postgres | before | JE % · 1000 % · 6200 % · 1300 % · 2000 % · 1100 %',
        v_je0, b1000, b6200, pg_temp.bal('1300'), pg_temp.bal('2000'), pg_temp.bal('1100');

    -- ══ A · 关上的门(chooer@ 持 module.finance.edit)══
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT post_journal_entry(%L::date, %L, %L, NULL, %L::jsonb)',
        d, 'APR-6 forged purchase', 'purchase', pg_temp.lines('1200', '2000', 5)));
    IF v_msg NOT LIKE 'permission denied for function post_journal_entry%' THEN RAISE EXCEPTION 'CELL A1 %', v_msg; END IF;
    RAISE NOTICE 'CELL A1 | chooer@ | post_journal_entry(purchase, 1200/2000) | %', v_msg;
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT post_journal_entry(%L::date, %L, %L, NULL, %L::jsonb)',
        d, 'APR-6 bank out', 'manual', pg_temp.lines('6200', '1000', 5)));
    IF v_msg NOT LIKE 'permission denied for function post_journal_entry%' THEN RAISE EXCEPTION 'CELL A2 %', v_msg; END IF;
    RAISE NOTICE 'CELL A2 | chooer@ | post_journal_entry(manual, credit 1000) | %', v_msg;
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format(
        'INSERT INTO journal_entries (code, entry_date, memo, source_type) VALUES (%L, %L::date, %L, %L)', 'ZZAPR6-DIRECT', d, 'APR-6', 'manual'));
    IF v_msg <> 'JOURNAL_THROUGH_FUNCTION_ONLY' THEN RAISE EXCEPTION 'CELL A3 %', v_msg; END IF;
    RAISE NOTICE 'CELL A3 | chooer@ | INSERT journal_entries | %', v_msg;
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format(
        'INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, fx_rate, amount_ccy) SELECT %L, a.id, 1, 0, %L, 1, 1 FROM accounts a WHERE a.code = %L',
        v_je79, (SELECT code FROM currencies WHERE is_base), '6200'));
    IF v_msg <> 'JOURNAL_THROUGH_FUNCTION_ONLY' THEN RAISE EXCEPTION 'CELL A4 %', v_msg; END IF;
    RAISE NOTICE 'CELL A4 | chooer@ | append a line to JE-2026-0079 (JE-APPEND, open period) | %', v_msg;
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT reverse_journal_entry(%L, %L::date, %L)', v_je79, d, 'door'));
    IF v_msg NOT LIKE 'JOURNAL_NEEDS_APPROVED_REQUEST|JE-2026-0079' THEN RAISE EXCEPTION 'CELL A5 %', v_msg; END IF;
    RAISE NOTICE 'CELL A5 | chooer@ | reverse_journal_entry(JE-2026-0079) | %', v_msg;
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT reverse_journal_entry(%L, %L::date, %L)', v_exp, d, 'door'));
    IF v_msg NOT LIKE 'JE_REVERSE_USE_SOURCE_PATH|%|expense' THEN RAISE EXCEPTION 'CELL A6 %', v_msg; END IF;
    RAISE NOTICE 'CELL A6 | chooer@ | reverse_journal_entry(an expense entry) | %', v_msg;
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT reverse_journal_entry(%L, %L::date, %L)', v_pay, d, 'door'));
    IF v_msg NOT LIKE 'JE_REVERSE_USE_SOURCE_PATH|%|payment' THEN RAISE EXCEPTION 'CELL A7 %', v_msg; END IF;
    RAISE NOTICE 'CELL A7 | chooer@ | reverse_journal_entry(a payment entry) | %', v_msg;
    IF (SELECT count(*) FROM journal_entries) <> v_je0 THEN RAISE EXCEPTION 'CELL A8 a refused door left an entry'; END IF;

    -- ══ B · 提一张手工凭证:一笔银行手续费(借 6200 / 贷 1000)══
    v_res := pg_temp.call_as('chooer@evoltrya.test', format('SELECT submit_journal_request(%L::date, %L, %L::jsonb)',
        d, 'APR-6 live proof · bank fee', pg_temp.lines('6200', '1000', 12.34)));
    q := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'submitted' OR (v_res->>'credits_bank')::boolean IS NOT TRUE
       OR (SELECT count(*) FROM journal_entries) <> v_je0 OR pg_temp.bal('1000') <> b1000 THEN
        RAISE EXCEPTION 'CELL B1 %', v_res; END IF;
    RAISE NOTICE 'CELL B1 | chooer@ | submit (6200 / 1000, 12.34) | % · % · amount % · credits_bank % · JE unchanged %',
        v_res->>'label', v_res->>'status', v_res->>'amount_base', v_res->>'credits_bank', v_je0;
    SELECT count(*) INTO v_n FROM approval_pending_documents() p
     WHERE p.subject_type = 'journal_request' AND p.doc_id = q AND p.blocks_disable AND p.fixed_level = 2 AND p.subject_employee_id IS NULL;
    IF v_n <> 1 THEN RAISE EXCEPTION 'CELL B2 pending arm'; END IF;
    RAISE NOTICE 'CELL B2 | postgres | pending arm | blocks_disable true · fixed_level 2 · subject NULL · deciders: %',
        (SELECT string_agg(u.email, ' ') FROM approval_deciders('journal_request', 'decide_journal_request', 2::smallint, v_choo, NULL,
            (SELECT approval_level1_role_code FROM finance_settings), (SELECT approval_level2_role_code FROM finance_settings)) dd
          JOIN auth.users u ON u.id = dd.user_id);
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT submit_journal_request(%L::date, %L, %L::jsonb)',
        d, 'APR-6 AP', pg_temp.lines('6200', '2000', 5)));
    IF v_msg NOT LIKE 'JE_MANUAL_CONTROL_ACCOUNT|%|2000' THEN RAISE EXCEPTION 'CELL B3 %', v_msg; END IF;
    RAISE NOTICE 'CELL B3 | chooer@ | submit touching 2000 | %', v_msg;
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT submit_journal_request(%L::date, %L, %L::jsonb)',
        d, 'APR-6 wh', pg_temp.lines('6200', '1300', 5)));
    IF v_msg <> 'PERMISSION_DENIED|module.finance.edit' THEN RAISE EXCEPTION 'CELL B4 %', v_msg; END IF;
    RAISE NOTICE 'CELL B4 | fusheng@ | submit | %', v_msg;
    v_msg := pg_temp.try_as('admin@swm-os.test', format('SELECT submit_journal_request(%L::date, %L, %L::jsonb)',
        d, 'APR-6 admin', pg_temp.lines('6200', '1300', 5)));
    IF v_msg NOT LIKE 'JOURNAL_REQUEST_NO_OTHER_DECIDER|%' THEN RAISE EXCEPTION 'CELL B5 %', v_msg; END IF;
    RAISE NOTICE 'CELL B5 | admin@ | submit | %', v_msg;
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT submit_journal_request(%L::date, %L, %L::jsonb)',
        (SELECT locked_before FROM finance_settings) - 1, 'APR-6 locked', pg_temp.lines('6200', '1300', 5)));
    IF v_msg NOT LIKE 'PERIOD_LOCKED|%' THEN RAISE EXCEPTION 'CELL B6 %', v_msg; END IF;
    RAISE NOTICE 'CELL B6 | chooer@ | submit dated in the locked period | %', v_msg;
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT submit_journal_request(%L::date, %L, %L::jsonb)',
        d, 'APR-6 unbalanced', pg_temp.lines('6200', '1300', 5, 4)));
    IF v_msg NOT LIKE 'JOURNAL_UNBALANCED|%' THEN RAISE EXCEPTION 'CELL B7 %', v_msg; END IF;
    RAISE NOTICE 'CELL B7 | chooer@ | submit unbalanced | %', v_msg;
    IF (SELECT count(*) FROM journal_requests) <> 1 THEN RAISE EXCEPTION 'CELL B8 a refused submit left a row'; END IF;

    -- ══ C · 谁批不了 ══
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT decide_journal_request(%L, true)', q));
    IF v_msg <> 'SELF_APPROVAL_FORBIDDEN|raiser' THEN RAISE EXCEPTION 'CELL C1 %', v_msg; END IF;
    RAISE NOTICE 'CELL C1 | chooer@ | decide own | %', v_msg;
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format('SELECT decide_journal_request(%L, true)', q));
    IF v_msg NOT LIKE 'APPROVAL_NOT_AUTHORISED|2|%' THEN RAISE EXCEPTION 'CELL C2 %', v_msg; END IF;
    RAISE NOTICE 'CELL C2 | sandra@ | decide | %', v_msg;
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT decide_journal_request(%L, true)', q));
    IF v_msg <> 'PERMISSION_DENIED|module.finance.view' THEN RAISE EXCEPTION 'CELL C3 %', v_msg; END IF;
    RAISE NOTICE 'CELL C3 | fusheng@ | decide | %', v_msg;

    -- ══ D · tim@ 批准:当场过账 ══
    v_res := pg_temp.call_as('tim@evoltrya.test', format('SELECT decide_journal_request(%L, true)', q));
    v_entry := (v_res->>'entry_id')::uuid;
    IF v_res->>'status' <> 'approved' OR (SELECT count(*) FROM journal_entries) <> v_je0 + 1
       OR (SELECT row(source_type, source_id, entry_date, created_by)::text FROM journal_entries WHERE id = v_entry)
          IS DISTINCT FROM row('manual', q, d, v_tim)::text
       OR pg_temp.bal('1000') <> b1000 - 12.34 OR pg_temp.bal('6200') <> b6200 + 12.34 THEN
        RAISE EXCEPTION 'CELL D1 %', v_res; END IF;
    RAISE NOTICE 'CELL D1 | tim@ | approve | % · manual · source_id = request · dated % · created_by tim@ · 1000 % → % · 6200 % → %',
        v_res->>'journal_code', d, b1000, pg_temp.bal('1000'), b6200, pg_temp.bal('6200');
    IF NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'journal_request' AND subject_id = q AND decision = 'approved'
                    AND level = 2 AND actor_user_id = v_tim AND NOT self_decided) THEN RAISE EXCEPTION 'CELL D2 log'; END IF;
    RAISE NOTICE 'CELL D2 | postgres | approval_log | submitted + approved, level 2, tim@, self_decided false';
    IF NOT (v_choo = ANY (sod_manual_posters_in(d, d))) OR v_tim = ANY (sod_manual_posters_in(d, d)) THEN
        RAISE EXCEPTION 'CELL D3 sod %', sod_manual_posters_in(d, d); END IF;
    RAISE NOTICE 'CELL D3 | postgres | sod_manual_posters_in(today) | chooer@ counted, tim@ not';

    -- ══ E · 冲销那一张:申请 → 批准 ══
    v_res := pg_temp.call_as('chooer@evoltrya.test', format('SELECT submit_journal_reversal_request(%L, %L::date, %L)',
        v_entry, d, 'APR-6 live proof · reverse the fee'));
    qr := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'submitted' OR (SELECT status FROM journal_entries WHERE id = v_entry) <> 'posted' THEN
        RAISE EXCEPTION 'CELL E1 %', v_res; END IF;
    RAISE NOTICE 'CELL E1 | chooer@ | reversal request | % · submitted · entry still posted', v_res->>'label';
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT submit_journal_reversal_request(%L, %L::date, %L)', v_entry, d, 'again'));
    IF v_msg NOT LIKE 'JOURNAL_REQUEST_OPEN|%' THEN RAISE EXCEPTION 'CELL E2 %', v_msg; END IF;
    RAISE NOTICE 'CELL E2 | chooer@ | second reversal request | %', v_msg;
    v_res := pg_temp.call_as('tim@evoltrya.test', format('SELECT decide_journal_request(%L, true)', qr));
    v_rev := (v_res->>'entry_id')::uuid;
    IF (SELECT status FROM journal_entries WHERE id = v_entry) <> 'reversed' OR pg_temp.bal('1000') <> b1000 OR pg_temp.bal('6200') <> b6200 THEN
        RAISE EXCEPTION 'CELL E3 %', v_res; END IF;
    RAISE NOTICE 'CELL E3 | tim@ | approve reversal | % · original reversed · 1000 back to % · 6200 back to %',
        v_res->>'journal_code', pg_temp.bal('1000'), pg_temp.bal('6200');

    -- ══ F · 驳回 · G · 撤回 ══
    qx := (pg_temp.call_as('chooer@evoltrya.test', format('SELECT submit_journal_request(%L::date, %L, %L::jsonb)',
        d, 'APR-6 live proof · to reject', pg_temp.lines('6400', '1300', 7)))->>'request_id')::uuid;
    v_msg := pg_temp.try_as('tim@evoltrya.test', format('SELECT decide_journal_request(%L, false, %L)', qx, '  '));
    IF v_msg NOT LIKE 'JOURNAL_REQUEST_REJECT_REASON_REQUIRED|%' THEN RAISE EXCEPTION 'CELL F1 %', v_msg; END IF;
    PERFORM pg_temp.call_as('tim@evoltrya.test', format('SELECT decide_journal_request(%L, false, %L)', qx, 'APR-6 proof: wrong account'));
    IF (SELECT status FROM journal_requests WHERE id = qx) <> 'rejected' OR (SELECT count(*) FROM journal_entries) <> v_je0 + 2 THEN
        RAISE EXCEPTION 'CELL F2'; END IF;
    RAISE NOTICE 'CELL F | tim@ | reject: no reason → %; with a reason → rejected, nothing posted', v_msg;
    qx := (pg_temp.call_as('chooer@evoltrya.test', format('SELECT submit_journal_request(%L::date, %L, %L::jsonb)',
        d, 'APR-6 live proof · to withdraw', pg_temp.lines('6400', '1300', 8)))->>'request_id')::uuid;
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT withdraw_journal_request(%L)', qx));
    IF v_msg <> 'PERMISSION_DENIED|module.finance.edit' THEN RAISE EXCEPTION 'CELL G1 %', v_msg; END IF;
    PERFORM pg_temp.call_as('chooer@evoltrya.test', format('SELECT withdraw_journal_request(%L, %L)', qx, 'APR-6 proof'));
    IF (SELECT status FROM journal_requests WHERE id = qx) <> 'withdrawn' THEN RAISE EXCEPTION 'CELL G2'; END IF;
    RAISE NOTICE 'CELL G | fusheng@ → %; chooer@ → withdrawn', v_msg;

    -- ══ I · 收尾:没有一张在等 ══
    IF EXISTS (SELECT 1 FROM journal_requests WHERE status = 'submitted') THEN RAISE EXCEPTION 'CELL I1 something left waiting'; END IF;
    RAISE NOTICE 'CELL I1 | postgres | journal_requests waiting: 0 · pending documents: %',
        (SELECT string_agg(subject_type || ' ' || n, ', ') FROM (SELECT subject_type, count(*) n FROM approval_pending_documents() GROUP BY 1) x);
END;
$proof$;

SELECT side, list, ledger, unexplained FROM pg_temp.recon();
ROLLBACK;
