-- db/scripts/2026-09-25-apr5a-live-proof.sql
-- APR-5a · 线上证明(一笔事务,最后 ROLLBACK —— 线上什么都不留)。
-- 以 postgres 连接(rolbypassrls = t);每一格用 request.jwt.claims 换成一个【真账号】,在
-- SET LOCAL ROLE authenticated 下跑,拒绝与读回各印一行 CELL。任何一格与期望不符 → RAISE,整笔回滚,
-- psql 以非零退出(PROOF_OWN_EXIT)。
--   chooer@ = finance · tim@ = cfo · admin@ = admin(与 tim@ 同一个人)· sandra@ = cco · vince@ = gm
-- 用到的线上行(2026-09-25 16:4x 以 postgres 读基表):
--   INV-2026-0007 order · issued · 414.00 · 开放 364.00 · 已发货 · 挂着 1 张贷项;
--   INV-2026-0009 sale  · issued · 1,245.87 · 税 102.87 · 有分录(只过税);
--   INV-2026-0002 sale  · issued · 24,000.00 · 不带税 · 没有分录。
-- 发货那一格(Q10)线上【证不到】:没有一张 confirmed / partially_shipped 的订单(Step 0 读数),
-- 由 fixture 223 E / H 两臂钉着 —— 这里不造订单去凑。
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

-- 一格:以某个账号、在 authenticated 下跑一句,返回 'OK' 或那一句拒绝的原文
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

-- 一格:以某个账号调一个返回 jsonb 的函数
CREATE FUNCTION pg_temp.call_as(p_email text, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.as_user(p_email);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
END $$;

-- 账户余额(借减贷,本位币),postgres 读基表,全部行(不按 posted 过滤 —— AGENTS.md)
CREATE FUNCTION pg_temp.bal(p_code text) RETURNS numeric LANGUAGE sql AS $$
    SELECT round(COALESCE(sum(l.debit - l.credit), 0), 2) FROM accounts a
      LEFT JOIN journal_lines l ON l.account_id = a.id WHERE a.code = p_code
$$;

-- 清单对总账:以 tim@ 读(函数问的是"你是谁")
CREATE FUNCTION pg_temp.recon() RETURNS TABLE(side text, list numeric, ledger numeric, unexplained numeric) LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.as_user('tim@evoltrya.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    RETURN QUERY SELECT s->>'side', (s->>'list_base')::numeric, (s->>'ledger_base')::numeric, (s->>'unexplained_base')::numeric
                   FROM jsonb_array_elements(list_ledger_reconciliation()->'sides') s;
    EXECUTE 'RESET ROLE';
END $$;

DO $proof$
DECLARE
    i7 uuid; i9 uuid; i2 uuid; il7 uuid; e9 uuid; cn7_entry uuid; v_cust uuid;
    q uuid; q9 uuid; q2 uuid; v_res jsonb; v_msg text; v_n int; v_je0 int; v_log0 int; v_cn0 int;
    v_1100 numeric; v_2100 numeric; v_4000 numeric; v_2500 numeric; v_amt numeric;
    r record; d date := CURRENT_DATE;
BEGIN
    SELECT id, customer_id INTO i7, v_cust FROM invoices WHERE code = 'INV-2026-0007';
    SELECT id, entry_id INTO i9, e9 FROM invoices WHERE code = 'INV-2026-0009';
    SELECT id INTO i2 FROM invoices WHERE code = 'INV-2026-0002';
    SELECT il.id INTO il7 FROM invoice_lines il WHERE il.invoice_id = i7 AND NOT il.invoice_voided ORDER BY il.line_no LIMIT 1;
    SELECT cn.entry_id INTO cn7_entry FROM credit_notes cn WHERE cn.invoice_id = i7 LIMIT 1;
    IF i7 IS NULL OR i9 IS NULL OR i2 IS NULL OR il7 IS NULL OR e9 IS NULL OR cn7_entry IS NULL THEN
        RAISE EXCEPTION 'PROOF_SETUP|a live row this proof names is not there';
    END IF;
    SELECT count(*) INTO v_je0 FROM journal_entries;
    SELECT count(*) INTO v_log0 FROM approval_log;
    SELECT count(*) INTO v_cn0 FROM credit_notes;
    v_1100 := pg_temp.bal('1100'); v_2100 := pg_temp.bal('2100'); v_4000 := pg_temp.bal('4000'); v_2500 := pg_temp.bal('2500');
    FOR r IN SELECT * FROM pg_temp.recon() LOOP
        RAISE NOTICE 'CELL L0 tim@ · list_ledger_reconciliation % before: list % / ledger % / unexplained %', r.side, r.list, r.ledger, r.unexplained;
    END LOOP;

    -- ── D · 两扇门对任何人都按名拒;没有码的人先听见 PERMISSION_DENIED ─────────────
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT void_invoice(%L, %L, %L)', i9, 'x', d));
    IF v_msg <> 'INVOICE_NEEDS_APPROVED_REQUEST|INV-2026-0009' THEN RAISE EXCEPTION 'CELL D1 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL D1 chooer@ · void_invoice INV-2026-0009 → %', v_msg;
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT create_credit_note(%L, %L, %L, %L::jsonb)', i7, d, 'x',
        jsonb_build_array(jsonb_build_object('invoice_line_id', il7, 'kind', 'revenue_reduction', 'amount', 1))));
    IF v_msg <> 'INVOICE_NEEDS_APPROVED_REQUEST|INV-2026-0007' THEN RAISE EXCEPTION 'CELL D2 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL D2 chooer@ · create_credit_note INV-2026-0007 → %', v_msg;
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format('SELECT submit_invoice_void_request(%L, %L, %L)', i9, 'x', d));
    IF v_msg <> 'PERMISSION_DENIED|module.finance.edit' THEN RAISE EXCEPTION 'CELL D3 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL D3 sandra@ · submit_invoice_void_request → %', v_msg;

    -- ── W · 五条直连路(Q11)────────────────────────────────────────────────────
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('UPDATE invoices SET status = %L, voided_at = now() WHERE id = %L', 'void', i9));
    IF v_msg <> 'INVOICE_THROUGH_FUNCTION_ONLY' THEN RAISE EXCEPTION 'CELL W1 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL W1 chooer@ · direct UPDATE invoices SET status = void → %', v_msg;
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('UPDATE invoice_lines SET invoice_voided = true WHERE invoice_id = %L', i9));
    IF v_msg <> 'INVOICE_THROUGH_FUNCTION_ONLY' THEN RAISE EXCEPTION 'CELL W2 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL W2 chooer@ · direct UPDATE invoice_lines SET invoice_voided → %', v_msg;
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format(
        'INSERT INTO invoices (code, customer_id, issue_date, due_date, payment_terms_days, currency) VALUES (%L, %L, %L, %L, 0, %L)',
        'ZZ-APR5A-FAKE', v_cust, d, d, 'SGD'));
    IF v_msg <> 'INVOICE_THROUGH_FUNCTION_ONLY' THEN RAISE EXCEPTION 'CELL W3 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL W3 chooer@ · direct INSERT invoices → %', v_msg;
    BEGIN
        UPDATE invoice_lines SET invoice_voided = true WHERE invoice_id = i9;
        RAISE EXCEPTION 'CELL W4 wrong: the owner path flipped invoice_voided on a live invoice';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'INVOICE_IMMUTABLE' THEN RAISE EXCEPTION 'CELL W4 wrong: %', SQLERRM; END IF;
        RAISE NOTICE 'CELL W4 postgres · owner-path UPDATE invoice_lines SET invoice_voided on a live invoice → %', SQLERRM;
    END;
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT reverse_journal_entry(%L, %L)', e9, d));
    IF v_msg NOT LIKE 'JE_REVERSE_USE_SOURCE_PATH|%|invoice' THEN RAISE EXCEPTION 'CELL W5 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL W5 chooer@ · reverse_journal_entry(INV-2026-0009 entry) → %', v_msg;
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT reverse_journal_entry(%L, %L)', cn7_entry, d));
    IF v_msg NOT LIKE 'JE_REVERSE_USE_SOURCE_PATH|%|credit_note' THEN RAISE EXCEPTION 'CELL W6 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL W6 chooer@ · reverse_journal_entry(credit note entry on INV-2026-0007) → %', v_msg;
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT submit_invoice_void_request(%L, %L, %L)', i7, 'APR5A proof', d));
    IF v_msg NOT LIKE 'INVOICE_SHIPPED_NOT_VOIDABLE|INV-2026-0007%' THEN RAISE EXCEPTION 'CELL W7 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL W7 chooer@ · void request on shipped INV-2026-0007 → % (engine''s own words at submit; nothing saved)', v_msg;
    v_msg := pg_temp.try_as('admin@swm-os.test', format('SELECT submit_invoice_void_request(%L, %L, %L)', i9, 'APR5A proof', d));
    IF v_msg <> 'INVOICE_REQUEST_NO_OTHER_DECIDER|INV-2026-0009' THEN RAISE EXCEPTION 'CELL N1 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL N1 admin@ · void request on INV-2026-0009 → % (admin@ and tim@ are one person)', v_msg;
    IF (SELECT count(*) FROM invoice_requests) <> 0 THEN RAISE EXCEPTION 'CELL N1 wrong: a refused submit left a row'; END IF;

    -- ── C · 贷项:chooer@ 提 → tim@ 批 → 当场过账 ────────────────────────────────
    v_res := pg_temp.call_as('chooer@evoltrya.test', format('SELECT submit_credit_note_request(%L, %L, %L, %L::jsonb)', i7, d,
        'APR5A live proof', jsonb_build_array(jsonb_build_object('invoice_line_id', il7, 'kind', 'revenue_reduction', 'amount', 1))));
    q := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'submitted' OR (SELECT count(*) FROM credit_notes) <> v_cn0
       OR (SELECT count(*) FROM journal_entries) <> v_je0 OR pg_temp.bal('1100') <> v_1100 THEN
        RAISE EXCEPTION 'CELL C1 wrong: %', v_res; END IF;
    RAISE NOTICE 'CELL C1 chooer@ · credit note request on INV-2026-0007 (revenue_reduction 1.00) → % % · amount %; no credit note, no entry, 1100 unchanged',
        v_res->>'status', v_res->>'label', v_res->>'amount_base';
    SELECT count(*) INTO v_n FROM approval_pending_documents() p
     WHERE p.subject_type = 'invoice_request' AND p.doc_id = q AND p.blocks_disable AND p.fixed_level = 2;
    IF v_n <> 1 THEN RAISE EXCEPTION 'CELL C2 wrong: pending arm'; END IF;
    SELECT string_agg(u.email, ' ') INTO v_msg
      FROM approval_deciders('invoice_request', 'decide_invoice_request', 2::smallint,
                             (SELECT created_by FROM invoice_requests WHERE id = q), NULL,
                             (SELECT approval_level1_role_code FROM finance_settings),
                             (SELECT approval_level2_role_code FROM finance_settings)) d2
      JOIN auth.users u ON u.id = d2.user_id;
    IF v_msg IS NULL OR v_msg NOT LIKE '%tim@evoltrya.test%' THEN RAISE EXCEPTION 'CELL C2 wrong: deciders %', v_msg; END IF;
    RAISE NOTICE 'CELL C2 postgres · approval_pending_documents: invoice_request blocks_disable, fixed_level 2 · deciders: %', v_msg;
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT submit_invoice_void_request(%L, %L, %L)', i7, 'x', d));
    IF v_msg NOT LIKE 'INVOICE_REQUEST_OPEN|INV-2026-0007|%' THEN RAISE EXCEPTION 'CELL C3 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL C3 chooer@ · second request on INV-2026-0007 → %', v_msg;
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT decide_invoice_request(%L, true)', q));
    IF v_msg <> 'SELF_APPROVAL_FORBIDDEN|raiser' THEN
        RAISE EXCEPTION 'CELL C4 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL C4 chooer@ · decide own request → %', v_msg;
    v_msg := pg_temp.try_as('vince@evoltrya.test', format('SELECT withdraw_invoice_request(%L)', q));
    IF v_msg <> 'PERMISSION_DENIED|module.finance.edit' THEN RAISE EXCEPTION 'CELL C5 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL C5 vince@ · withdraw → %', v_msg;
    v_res := pg_temp.call_as('tim@evoltrya.test', format('SELECT decide_invoice_request(%L, true, %L)', q, 'APR5A live proof'));
    SELECT amount_base INTO v_amt FROM invoice_requests WHERE id = q AND status = 'approved' AND result_credit_note_id IS NOT NULL;
    IF v_res->>'status' <> 'approved' OR v_amt IS NULL
       OR (SELECT count(*) FROM credit_notes) <> v_cn0 + 1 OR (SELECT count(*) FROM journal_entries) <> v_je0 + 1
       OR pg_temp.bal('1100') <> v_1100 - v_amt OR pg_temp.bal('4000') <> v_4000 + v_amt THEN
        RAISE EXCEPTION 'CELL C6 wrong: % · 1100 % → % · 4000 % → %', v_res, v_1100, pg_temp.bal('1100'), v_4000, pg_temp.bal('4000'); END IF;
    RAISE NOTICE 'CELL C6 tim@ · approve → credit note %, entry %; 1100 % → %, 4000 % → % (amount %)',
        v_res->>'credit_note_code', v_res->>'journal_code', v_1100, pg_temp.bal('1100'), v_4000, pg_temp.bal('4000'), v_amt;
    IF NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'invoice_request' AND subject_id = q AND decision = 'approved'
                    AND level = 2 AND NOT self_decided
                    AND actor_user_id = (SELECT id FROM auth.users WHERE email = 'tim@evoltrya.test')) THEN
        RAISE EXCEPTION 'CELL C7 wrong: approval_log'; END IF;
    RAISE NOTICE 'CELL C7 postgres · approval_log: submitted + approved, level 2, actor tim@, self_decided = false';

    -- ── V · 作废带税的 sale 型发票:chooer@ 提 → tim@ 批 → 当场作废并冲销税 ─────────
    v_1100 := pg_temp.bal('1100'); v_2100 := pg_temp.bal('2100');
    SELECT count(*) INTO v_je0 FROM journal_entries;
    v_res := pg_temp.call_as('chooer@evoltrya.test', format('SELECT submit_invoice_void_request(%L, %L, %L)', i9, 'APR5A live proof', d));
    q9 := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'submitted' OR (SELECT status FROM invoices WHERE id = i9) <> 'issued' THEN
        RAISE EXCEPTION 'CELL V1 wrong: %', v_res; END IF;
    RAISE NOTICE 'CELL V1 chooer@ · void request on INV-2026-0009 → % % · amount %; invoice still issued', v_res->>'status', v_res->>'label', v_res->>'amount_base';
    v_res := pg_temp.call_as('tim@evoltrya.test', format('SELECT decide_invoice_request(%L, true)', q9));
    IF (SELECT status FROM invoices WHERE id = i9) <> 'void'
       OR (SELECT count(*) FROM journal_entries) <> v_je0 + 1
       OR pg_temp.bal('1100') <> v_1100 - 102.87 OR pg_temp.bal('2100') <> v_2100 + 102.87 THEN
        RAISE EXCEPTION 'CELL V2 wrong: % · 1100 % → % · 2100 % → %', v_res, v_1100, pg_temp.bal('1100'), v_2100, pg_temp.bal('2100'); END IF;
    RAISE NOTICE 'CELL V2 tim@ · approve → INV-2026-0009 void, reversal %; 1100 % → %, 2100 % → %',
        v_res->>'journal_code', v_1100, pg_temp.bal('1100'), v_2100, pg_temp.bal('2100');

    -- ── R · 驳回与撤回(不过账)──────────────────────────────────────────────────
    SELECT count(*) INTO v_je0 FROM journal_entries;
    v_res := pg_temp.call_as('chooer@evoltrya.test', format('SELECT submit_invoice_void_request(%L, %L)', i2, 'APR5A live proof'));
    q2 := (v_res->>'request_id')::uuid;
    v_msg := pg_temp.try_as('tim@evoltrya.test', format('SELECT decide_invoice_request(%L, false, %L)', q2, '  '));
    IF v_msg NOT LIKE 'INVOICE_REQUEST_REJECT_REASON_REQUIRED|%' THEN RAISE EXCEPTION 'CELL R1 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL R1 tim@ · reject without a reason → %', v_msg;
    v_res := pg_temp.call_as('tim@evoltrya.test', format('SELECT decide_invoice_request(%L, false, %L)', q2, 'APR5A live proof: no'));
    IF (SELECT status FROM invoice_requests WHERE id = q2) <> 'rejected' OR (SELECT status FROM invoices WHERE id = i2) <> 'issued'
       OR (SELECT count(*) FROM journal_entries) <> v_je0 THEN RAISE EXCEPTION 'CELL R2 wrong: %', v_res; END IF;
    RAISE NOTICE 'CELL R2 tim@ · reject INV-2026-0002 void → rejected; invoice still issued, no entry';
    v_res := pg_temp.call_as('chooer@evoltrya.test', format('SELECT submit_invoice_void_request(%L, %L)', i2, 'APR5A live proof 2'));
    q2 := (v_res->>'request_id')::uuid;
    v_res := pg_temp.call_as('chooer@evoltrya.test', format('SELECT withdraw_invoice_request(%L, %L)', q2, 'APR5A live proof'));
    IF (SELECT status FROM invoice_requests WHERE id = q2) <> 'withdrawn' THEN RAISE EXCEPTION 'CELL R3 wrong: %', v_res; END IF;
    RAISE NOTICE 'CELL R3 chooer@ · withdraw own request → withdrawn (no approval_log row: %)',
        (SELECT count(*) FROM approval_log WHERE subject_id = q2 AND decision <> 'submitted');

    -- ── L · 清单对总账:两边都 0.00 未解释(批准的贷项与作废之后)──────────────────
    FOR r IN SELECT * FROM pg_temp.recon() LOOP
        IF r.unexplained <> 0 THEN RAISE EXCEPTION 'CELL L1 wrong: % unexplained %', r.side, r.unexplained; END IF;
        RAISE NOTICE 'CELL L1 tim@ · list_ledger_reconciliation % after: list % / ledger % / unexplained %', r.side, r.list, r.ledger, r.unexplained;
    END LOOP;
    IF (SELECT count(*) FROM invoice_requests WHERE status = 'submitted') <> 0 THEN
        RAISE EXCEPTION 'CELL L2 wrong: a request left waiting'; END IF;
    RAISE NOTICE 'CELL L2 postgres · no invoice request left waiting inside the transaction; ROLLBACK removes all of it';
END;
$proof$;
SELECT 'PROOF PASSED (inside the transaction; ROLLBACK follows)' AS verdict, now() AS finished_at;
ROLLBACK;
