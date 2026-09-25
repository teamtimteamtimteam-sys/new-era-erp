-- db/scripts/2026-09-25-role1b4b-live-proof.sql
-- ROLE-1 Batch 4b · 线上证明(一笔事务,最后 ROLLBACK —— 线上什么都不留)。
-- 以 postgres 连接(rolbypassrls = t);每一格用 request.jwt.claims 换成一个【真账号】,在
-- SET LOCAL ROLE authenticated 下跑,拒绝与读回各印一行 CELL。任何一格与期望不符 → RAISE,整笔回滚,
-- psql 以非零退出(PROOF_OWN_EXIT)。
--   chooer@ = finance · tim@ = cfo · admin@ = admin(与 tim@ 同一个人)· sandra@ = cco · vince@ = gm ·
--   fusheng@ = warehouse · phua@ = cto
-- 用到的线上行:IN-2026-0153(未定价,680 kg,余量 0 —— 价差整笔进 5000)· IN-2026-0029(已付 30,000.00,
-- 4,000 kg)· IN-2026-0179(未定价)· IN-2026-0181(有承诺副本,化验 ASY-2026-0004 已应用)。
-- ★ 化验那一臂(X)在事务里先插一条【今天】的 USD tt_sell(线上最近一条是 2026-08-17,今天没有)与今天的
--   ni / co / li 行情(IN-2026-0181 的承诺按 30 天均价,线上最近一条行情是 2026-08-10,窗口里一条都没有,
--   算出的价 = −0.80 USD/kg ≤ 0 → 不提申请)—— 两样都随 ROLLBACK 一起消失;没有它们,那一臂证不到申请。
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

-- 账户余额(借减贷,本位币),postgres 读基表
CREATE FUNCTION pg_temp.bal(p_code text) RETURNS numeric LANGUAGE sql AS $$
    SELECT round(COALESCE(sum(l.debit - l.credit), 0), 2) FROM accounts a
      LEFT JOIN journal_lines l ON l.account_id = a.id WHERE a.code = p_code
$$;

DO $proof$
DECLARE
    b153 uuid; b29 uuid; b179 uuid; b181 uuid; v_base text; v_sup2 uuid;
    q uuid; q2 uuid; v_res jsonb; v_msg text; v_n int; v_je0 int; v_log0 int;
    v_2000 numeric; v_1200 numeric; v_5000 numeric;
    v_ap_list0 numeric; v_ap_list1 numeric; v_unx_ap numeric; v_unx_ar numeric; v_ap_ledger0 numeric; v_ap_ledger1 numeric;
    v_snap jsonb; v_assay uuid; v_metals jsonb;
BEGIN
    SELECT id INTO b153 FROM inbound_batches WHERE code = 'IN-2026-0153';
    SELECT id INTO b29  FROM inbound_batches WHERE code = 'IN-2026-0029';
    SELECT id INTO b179 FROM inbound_batches WHERE code = 'IN-2026-0179';
    SELECT id INTO b181 FROM inbound_batches WHERE code = 'IN-2026-0181';
    SELECT id INTO v_sup2 FROM suppliers WHERE code = 'SUP-2026-0002';
    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT count(*) INTO v_je0 FROM journal_entries;
    v_2000 := pg_temp.bal('2000'); v_1200 := pg_temp.bal('1200'); v_5000 := pg_temp.bal('5000');

    -- 清单对总账(tim@ 读,函数问的是"你是谁")
    PERFORM pg_temp.as_user('tim@evoltrya.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT (s->>'list_base')::numeric, (s->>'ledger_base')::numeric INTO v_ap_list0, v_ap_ledger0 FROM jsonb_array_elements(list_ledger_reconciliation()->'sides') s WHERE s->>'side' = 'ap';
    EXECUTE 'RESET ROLE';
    RAISE NOTICE 'CELL L0 tim@ · list_ledger_reconciliation AP before: list % / ledger %', v_ap_list0, v_ap_ledger0;

    -- ── R1 chooer@ 提:IN-2026-0153 @ 2 SGD ────────────────────────────────────
    PERFORM pg_temp.as_user('chooer@evoltrya.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := set_inbound_unit_price(b153, 2, v_base, NULL, 'ROLE1B4B live proof');
    EXECUTE 'RESET ROLE';
    q := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'submitted' THEN RAISE EXCEPTION 'CELL R1 wrong: %', v_res; END IF;
    RAISE NOTICE 'CELL R1 chooer@ · set_inbound_unit_price IN-2026-0153 @ 2 % → % (%)', v_base, v_res->>'status', v_res->>'label';
    IF (SELECT unit_price FROM inbound_batches WHERE id = b153) IS NOT NULL
       OR (SELECT count(*) FROM journal_entries) <> v_je0
       OR pg_temp.bal('2000') <> v_2000 THEN
        RAISE EXCEPTION 'CELL R2 wrong: a waiting request moved the price or the ledger'; END IF;
    PERFORM pg_temp.as_user('tim@evoltrya.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT (s->>'list_base')::numeric, (s->>'ledger_base')::numeric INTO v_ap_list1, v_ap_ledger1 FROM jsonb_array_elements(list_ledger_reconciliation()->'sides') s WHERE s->>'side' = 'ap';
    SELECT count(*) INTO v_n FROM operations_now WHERE item_type = 'receipt_price_request_pending';
    EXECUTE 'RESET ROLE';
    IF v_ap_list1 <> v_ap_list0 OR v_ap_ledger1 <> v_ap_ledger0 THEN
        RAISE EXCEPTION 'CELL R2 wrong: list % → %, ledger % → %', v_ap_list0, v_ap_list1, v_ap_ledger0, v_ap_ledger1; END IF;
    RAISE NOTICE 'CELL R2 postgres/tim@ · while it waits: unit_price NULL, journal_entries % → %, 2000 unchanged, AP list % → %, ledger % → %',
        v_je0, (SELECT count(*) FROM journal_entries), v_ap_list0, v_ap_list1, v_ap_ledger0, v_ap_ledger1;
    IF v_n <> 1 THEN RAISE EXCEPTION 'CELL R3 wrong: tim@ sees % receipt-price reminders', v_n; END IF;
    RAISE NOTICE 'CELL R3 tim@ · operations_now receipt_price_request_pending: % row (view)', v_n;
    IF NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_id = q AND decision = 'submitted' AND level = 2 AND amount_base = 1360.00) THEN
        RAISE EXCEPTION 'CELL R4 wrong: approval_log submitted row'; END IF;
    RAISE NOTICE 'CELL R4 postgres · approval_log: submitted, level 2, 1,360.00 %', v_base;
    SELECT string_agg(DISTINCT u.email, ' ') INTO v_msg
      FROM approval_deciders('receipt_price_request', 'decide_receipt_price_request', 2::smallint,
            (SELECT created_by FROM receipt_price_requests WHERE id = q), NULL,
            (SELECT approval_level1_role_code FROM finance_settings),
            (SELECT approval_level2_role_code FROM finance_settings)) d
      JOIN auth.users u ON u.id = d.user_id;
    IF v_msg IS DISTINCT FROM 'tim@evoltrya.test' THEN RAISE EXCEPTION 'CELL R5 wrong: deciders %', v_msg; END IF;
    RAISE NOTICE 'CELL R5 postgres · approval_deciders for that request: %', v_msg;

    -- ── F 等待期间冻住 ──────────────────────────────────────────────────────────
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT set_inbound_unit_price(%L, 3, %L)', b153, v_base));
    IF v_msg NOT LIKE 'RECEIPT_PRICE_REQUEST_OPEN|IN-2026-0153|%' THEN RAISE EXCEPTION 'CELL F1 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL F1 chooer@ · second request → %', v_msg;
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format('UPDATE inbound_batches SET supplier_id = %L WHERE id = %L', v_sup2, b153));
    IF v_msg NOT LIKE 'RECEIPT_PRICE_REQUEST_OPEN|IN-2026-0153|%' THEN RAISE EXCEPTION 'CELL F2 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL F2 sandra@ · direct UPDATE supplier_id → %', v_msg;
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source) VALUES (%L, %L, 10, %L)', b153, 'ni', 'manual'));
    IF v_msg NOT LIKE 'RECEIPT_PRICE_REQUEST_OPEN|IN-2026-0153|%' THEN RAISE EXCEPTION 'CELL F3 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL F3 fusheng@ · manual metal content → %', v_msg;
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT soft_delete_inbound_batch(%L, %L)', b153, 'ROLE1B4B proof'));
    IF v_msg NOT LIKE 'RECEIPT_PRICE_REQUEST_OPEN|IN-2026-0153|%' THEN RAISE EXCEPTION 'CELL F4 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL F4 chooer@ · soft delete → %', v_msg;

    -- ── D 谁批不了 ──────────────────────────────────────────────────────────────
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT decide_receipt_price_request(%L, true)', q));
    IF v_msg NOT LIKE 'SELF_APPROVAL_FORBIDDEN|raiser%' THEN RAISE EXCEPTION 'CELL D1 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL D1 chooer@ · approve own request → %', v_msg;
    v_msg := pg_temp.try_as('admin@swm-os.test', format('SELECT decide_receipt_price_request(%L, true)', q));
    IF v_msg NOT LIKE 'APPROVAL_NOT_AUTHORISED|2|cfo%' THEN RAISE EXCEPTION 'CELL D2 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL D2 admin@ · approve → %', v_msg;
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format('SELECT decide_receipt_price_request(%L, true)', q));
    IF v_msg NOT LIKE 'APPROVAL_NOT_AUTHORISED|2|cfo%' THEN RAISE EXCEPTION 'CELL D3 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL D3 sandra@ · approve → %', v_msg;
    v_msg := pg_temp.try_as('vince@evoltrya.test', format('SELECT decide_receipt_price_request(%L, true)', q));
    IF v_msg NOT LIKE 'APPROVAL_NOT_AUTHORISED|2|cfo%' THEN RAISE EXCEPTION 'CELL D4 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL D4 vince@ · approve → %', v_msg;
    v_msg := pg_temp.try_as('tim@evoltrya.test', format('SELECT decide_receipt_price_request(%L, false, NULL)', q));
    IF v_msg NOT LIKE 'RECEIPT_PRICE_REQUEST_REJECT_REASON_REQUIRED|%' THEN RAISE EXCEPTION 'CELL D5 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL D5 tim@ · reject without a reason → %', v_msg;

    -- ── C 指纹:批准前那一组事实变了 → 拒,一行不落(改的是冻结的 snapshot,postgres)──
    SELECT snapshot INTO v_snap FROM receipt_price_requests WHERE id = q;
    UPDATE receipt_price_requests SET snapshot = snapshot || '{"quantity": 681}'::jsonb WHERE id = q;
    v_msg := pg_temp.try_as('tim@evoltrya.test', format('SELECT decide_receipt_price_request(%L, true)', q));
    UPDATE receipt_price_requests SET snapshot = v_snap WHERE id = q;
    IF v_msg NOT LIKE 'RECEIPT_PRICE_CHANGED_SINCE_REQUEST|%' OR (SELECT count(*) FROM journal_entries) <> v_je0 THEN
        RAISE EXCEPTION 'CELL C1 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL C1 tim@ · approve after the facts changed → % (journal_entries still %)', v_msg, v_je0;

    -- ── A tim@ 批准:当场过账;清单与总账动同一个数 ─────────────────────────────
    PERFORM pg_temp.as_user('tim@evoltrya.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := decide_receipt_price_request(q, true, 'ROLE1B4B live proof');
    SELECT (s->>'list_base')::numeric, (s->>'ledger_base')::numeric INTO v_ap_list1, v_ap_ledger1 FROM jsonb_array_elements(list_ledger_reconciliation()->'sides') s WHERE s->>'side' = 'ap';
    SELECT (s->>'unexplained_base')::numeric INTO v_unx_ap FROM jsonb_array_elements(list_ledger_reconciliation()->'sides') s WHERE s->>'side' = 'ap';
    SELECT (s->>'unexplained_base')::numeric INTO v_unx_ar FROM jsonb_array_elements(list_ledger_reconciliation()->'sides') s WHERE s->>'side' = 'ar';
    EXECUTE 'RESET ROLE';
    IF v_res->>'status' <> 'approved' OR v_res->>'journal_code' IS NULL
       OR (SELECT unit_price FROM inbound_batches WHERE id = b153) <> 2 THEN
        RAISE EXCEPTION 'CELL A1 wrong: %', v_res; END IF;
    RAISE NOTICE 'CELL A1 tim@ · approve → approved, posted %, unit_price 2.0000', v_res->>'journal_code';
    RAISE NOTICE 'CELL A2 postgres · 2000 % → % · 1200 % → % · 5000 % → % (debit − credit)',
        v_2000, pg_temp.bal('2000'), v_1200, pg_temp.bal('1200'), v_5000, pg_temp.bal('5000');
    IF pg_temp.bal('2000') - v_2000 <> -1360.00 OR (pg_temp.bal('1200') - v_1200) + (pg_temp.bal('5000') - v_5000) <> 1360.00 THEN
        RAISE EXCEPTION 'CELL A2 wrong: the posting is not 1,360.00'; END IF;
    IF v_ap_list1 - v_ap_list0 <> 1360.00 OR v_ap_ledger1 - v_ap_ledger0 <> 1360.00 OR v_unx_ap <> 0 OR v_unx_ar <> 0 THEN
        RAISE EXCEPTION 'CELL A3 wrong: list % → %, ledger % → %, unexplained ap % ar %',
            v_ap_list0, v_ap_list1, v_ap_ledger0, v_ap_ledger1, v_unx_ap, v_unx_ar; END IF;
    RAISE NOTICE 'CELL A3 tim@ · list_ledger_reconciliation AP: list % → % (+1,360.00), ledger % → % (+1,360.00), unexplained ap % · ar %',
        v_ap_list0, v_ap_list1, v_ap_ledger0, v_ap_ledger1, v_unx_ap, v_unx_ar;
    IF NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_id = q AND decision = 'approved' AND level = 2
                    AND amount_base = 1360.00 AND NOT self_decided) THEN
        RAISE EXCEPTION 'CELL A4 wrong: approval_log approved row'; END IF;
    RAISE NOTICE 'CELL A4 postgres · approval_log: approved, level 2, 1,360.00, self_decided = false';

    -- ── B 低于已付 ──────────────────────────────────────────────────────────────
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT set_inbound_unit_price(%L, 7, %L)', b29, v_base));
    IF v_msg <> 'RECEIPT_PRICE_BELOW_SETTLED|IN-2026-0029|28000.00|30000.00' THEN RAISE EXCEPTION 'CELL B1 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL B1 chooer@ · IN-2026-0029 @ 7 → %', v_msg;

    -- ── N 提单人之外没人批得动 ───────────────────────────────────────────────────
    v_msg := pg_temp.try_as('admin@swm-os.test', format('SELECT set_inbound_unit_price(%L, 2, %L)', b179, v_base));
    IF v_msg <> 'RECEIPT_PRICE_NO_OTHER_DECIDER|IN-2026-0179' THEN RAISE EXCEPTION 'CELL N1 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL N1 admin@ · price IN-2026-0179 → % (tim@ is the same person)', v_msg;

    -- ── S pricing_status 直连写 ─────────────────────────────────────────────────
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format('UPDATE inbound_batches SET pricing_status = %L WHERE id = %L', 'final', b179));
    IF v_msg <> 'PRICING_STATUS_VIA_FUNCTION|IN-2026-0179' THEN RAISE EXCEPTION 'CELL S1 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL S1 sandra@ · direct UPDATE pricing_status → %', v_msg;

    -- ── X 化验:应用 → 一张申请在等,不过账;撤销应用 → 撤回 ────────────────────────
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit) VALUES ('USD', CURRENT_DATE, 'tt_sell', 1.30);
    INSERT INTO metal_prices (metal, price_date, price_usd_per_tonne, source) VALUES
        ('ni', CURRENT_DATE, 15000, 'broker_quote'), ('co', CURRENT_DATE, 30000, 'broker_quote'),
        ('li', CURRENT_DATE, 10000, 'broker_quote');
    SELECT jsonb_agg(jsonb_build_object('metal', m.metal, 'content_pct', m.content_pct))
      INTO v_metals FROM assay_result_metals m JOIN assay_results a ON a.id = m.assay_result_id WHERE a.code = 'ASY-2026-0004';
    SELECT count(*) INTO v_je0 FROM journal_entries;
    PERFORM pg_temp.as_user('phua@evolytra.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := record_assay_result(p_assay_date => CURRENT_DATE, p_metals => v_metals,
                                 p_lab_name => (SELECT lab_name FROM assay_results WHERE code = 'ASY-2026-0004'),
                                 p_inbound_batch_id => b181, p_weight_basis => 'as_received', p_result_party => 'ours');
    v_assay := (v_res->>'assay_result_id')::uuid;
    v_res := apply_assay_result(v_assay);
    EXECUTE 'RESET ROLE';
    q2 := (v_res->'price_request'->>'request_id')::uuid;
    IF (v_res->'price_request'->>'status') IS DISTINCT FROM 'submitted' OR (SELECT count(*) FROM journal_entries) <> v_je0
       OR (SELECT created_by FROM receipt_price_requests WHERE id = q2) IS DISTINCT FROM (SELECT id FROM auth.users WHERE email = 'phua@evolytra.test')
       OR (SELECT pricing_status FROM inbound_batches WHERE id = b181) IS DISTINCT FROM 'final'
       OR (SELECT unit_price FROM inbound_batches WHERE id = b181) IS DISTINCT FROM 8.1152 THEN
        RAISE EXCEPTION 'CELL X1 wrong: %', v_res; END IF;
    RAISE NOTICE 'CELL X1 phua@ · apply a new assay on IN-2026-0181 → content applied, % % @ % USD/kg (source assay, raised by phua@); nothing posted, unit_price still 8.1152',
        v_res->'price_request'->>'label', v_res->'price_request'->>'status', v_res->'price_request'->>'unit_price_ccy';
    PERFORM pg_temp.as_user('phua@evolytra.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM unapply_assay_result(v_assay, 'ROLE1B4B live proof');
    EXECUTE 'RESET ROLE';
    IF (SELECT status FROM receipt_price_requests WHERE id = q2) IS DISTINCT FROM 'withdrawn' THEN RAISE EXCEPTION 'CELL X2 wrong'; END IF;
    RAISE NOTICE 'CELL X2 phua@ · unapply → request %, reason "%"',
        (SELECT status FROM receipt_price_requests WHERE id = q2), (SELECT withdraw_reason FROM receipt_price_requests WHERE id = q2);
END;
$proof$;

SET CONSTRAINTS ALL IMMEDIATE;
SELECT 'PROOF PASSED (inside the transaction; ROLLBACK follows)' AS verdict, now() AS finished_at;
ROLLBACK;
