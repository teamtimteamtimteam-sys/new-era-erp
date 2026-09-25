-- db/scripts/2026-09-25-role1b3a-live-proof.sql
-- ROLE-1 Batch 3a · 线上证明(一笔事务,最后 ROLLBACK —— 线上什么都不留)。
-- 以 postgres 连接(rolbypassrls = t);每一格用 request.jwt.claims 换成一个【真账号】,在
-- SET LOCAL ROLE authenticated 下跑,拒绝与读回各印一行 CELL。任何一格与期望不符 → RAISE,整笔回滚,
-- psql 以非零退出(PROOF_OWN_EXIT)。
--   chooer@ = finance · tim@ = cfo · admin@ = admin(与 tim@ 同一个人)· sandra@ = cco · vince@ = gm ·
--   fusheng@ = warehouse · phua@ = cto
-- 用到的线上行:ST-2026-0082(admin@ 开的在途盘点,0 行)· 第一张【已定价、有余量】的进料批次(按编号取)·
-- IN-2026-0001(已定价)· IN-2026-0153(未定价)· ASY-2026-0004(已应用的化验)· PAY-2026-0001(已过账的工资期)·
-- SUP-2026-0003(已批准的供应商)。事务里开的盘点、录的数、过的账、提的申请都随 ROLLBACK 一起消失。
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

-- 一格:同上,但返回那一句的【单值】(读回用)
CREATE FUNCTION pg_temp.val_as(p_email text, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
    PERFORM pg_temp.as_user(p_email);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN COALESCE(v, 'NULL');
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN 'ERR ' || SQLERRM;
END $$;

-- 账户余额(借减贷,本位币),postgres 读基表
CREATE FUNCTION pg_temp.bal(p_code text) RETURNS numeric LANGUAGE sql AS $$
    SELECT round(COALESCE(sum(l.debit - l.credit), 0), 2) FROM accounts a
      LEFT JOIN journal_lines l ON l.account_id = a.id WHERE a.code = p_code
$$;

DO $proof$
DECLARE
    st82 uuid; b uuid; b_code text; b_rem numeric; b_landed numeric; b1 uuid; b153 uuid; v_sup2 uuid; v_sup3 uuid;
    asy uuid; pay1 uuid; v_base text;
    st uuid; st_code text; v_msg text; v_n int; v_je0 int; v_1200 numeric; v_5200 numeric; v_amt numeric;
    v_res jsonb; v_unx_ap text; v_unx_ar text;
BEGIN
    SELECT id INTO st82 FROM stocktakes WHERE code = 'ST-2026-0082';
    SELECT id, code, remaining_qty INTO b, b_code, b_rem FROM inbound_batches
     WHERE deleted_at IS NULL AND unit_price IS NOT NULL AND remaining_qty >= 1 ORDER BY code LIMIT 1;
    b_landed := inbound_batch_landed_unit_cost_all(b);
    SELECT id INTO b1   FROM inbound_batches WHERE code = 'IN-2026-0001';
    SELECT id INTO b153 FROM inbound_batches WHERE code = 'IN-2026-0153';
    SELECT id INTO v_sup2 FROM suppliers WHERE code = 'SUP-2026-0002';
    SELECT id INTO v_sup3 FROM suppliers WHERE code = 'SUP-2026-0003';
    SELECT id INTO asy  FROM assay_results WHERE code = 'ASY-2026-0004';
    SELECT id INTO pay1 FROM payroll_periods WHERE code = 'PAY-2026-0001';
    SELECT code INTO v_base FROM currencies WHERE is_base;
    IF st82 IS NULL OR b IS NULL OR b1 IS NULL OR b153 IS NULL OR v_sup3 IS NULL OR asy IS NULL OR pay1 IS NULL THEN
        RAISE EXCEPTION 'PROOF_SETUP|a named live row is missing';
    END IF;
    RAISE NOTICE 'SETUP counting batch % (remaining %, landed unit cost %)', b_code, b_rem, b_landed;

    -- ── C · 谁持什么(每个账号以自己的身份问)───────────────────────────────────
    v_msg := pg_temp.val_as('fusheng@evoltrya.test', $q$SELECT ('action.stocktake_count' = ANY (current_user_permissions()))::text || '/' || ('action.stocktake_post' = ANY (current_user_permissions()))::text$q$);
    IF v_msg <> 'true/false' THEN RAISE EXCEPTION 'CELL C1 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL C1 fusheng@ · holds count / post → %', v_msg;
    v_msg := pg_temp.val_as('chooer@evoltrya.test', $q$SELECT ('action.stocktake_count' = ANY (current_user_permissions()))::text || '/' || ('action.stocktake_post' = ANY (current_user_permissions()))::text$q$);
    IF v_msg <> 'false/true' THEN RAISE EXCEPTION 'CELL C2 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL C2 chooer@ · holds count / post → %', v_msg;
    v_msg := pg_temp.val_as('admin@swm-os.test', $q$SELECT ('action.stocktake_count' = ANY (current_user_permissions()))::text || '/' || ('action.stocktake_post' = ANY (current_user_permissions()))::text$q$);
    IF v_msg <> 'true/true' THEN RAISE EXCEPTION 'CELL C3 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL C3 admin@ · holds count / post → %', v_msg;

    -- ── S1 · 旧码持有人开不了单 ────────────────────────────────────────────────
    v_msg := pg_temp.try_as('sandra@evoltrya.test', 'SELECT open_stocktake(NULL)');
    IF v_msg <> 'PERMISSION_DENIED|action.stocktake_count' THEN RAISE EXCEPTION 'CELL S1a wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL S1a sandra@ · open a stocktake → %', v_msg;
    v_msg := pg_temp.try_as('phua@evolytra.test', 'SELECT open_stocktake(NULL)');
    IF v_msg <> 'PERMISSION_DENIED|action.stocktake_count' THEN RAISE EXCEPTION 'CELL S1b wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL S1b phua@ · open a stocktake → %', v_msg;
    v_msg := pg_temp.try_as('chooer@evoltrya.test', 'SELECT open_stocktake(NULL)');
    IF v_msg <> 'PERMISSION_DENIED|action.stocktake_count' THEN RAISE EXCEPTION 'CELL S1c wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL S1c chooer@ · open a stocktake → %', v_msg;

    -- ── S2 · 仓库开单并录数 ────────────────────────────────────────────────────
    PERFORM pg_temp.as_user('fusheng@evoltrya.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := open_stocktake('ROLE1B3A live proof');
    st := (v_res->>'stocktake_id')::uuid; st_code := v_res->>'code';
    PERFORM record_stocktake_count(st, b, NULL, b_rem - 1, 'proof count');
    EXECUTE 'RESET ROLE';
    IF (SELECT created_by FROM stocktakes WHERE id = st) IS DISTINCT FROM (SELECT id FROM auth.users WHERE email = 'fusheng@evoltrya.test')
       OR (SELECT count(*) FROM stocktake_counts WHERE stocktake_id = st) <> 1 THEN
        RAISE EXCEPTION 'CELL S2 wrong: opener / count row';
    END IF;
    RAISE NOTICE 'CELL S2 fusheng@ · open % and count % at % → opener fusheng@, 1 row in stocktake_counts', st_code, b_code, b_rem - 1;

    -- ── S3 · 直连写按名拒 ──────────────────────────────────────────────────────
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format('UPDATE stocktakes SET status = %L WHERE id = %L', 'posted', st));
    IF v_msg <> 'STOCKTAKE_THROUGH_FUNCTION_ONLY' THEN RAISE EXCEPTION 'CELL S3a wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL S3a sandra@ · direct UPDATE status = posted → %', v_msg;
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('INSERT INTO stocktake_lines (stocktake_id, inbound_batch_id, book_qty, counted_qty) VALUES (%L, %L, 1, 1)', st82, b));
    IF v_msg <> 'STOCKTAKE_THROUGH_FUNCTION_ONLY' THEN RAISE EXCEPTION 'CELL S3b wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL S3b fusheng@ · direct INSERT a line → %', v_msg;

    -- ── S4 · 仓库过不了账;录过数的 admin@ 也过不了 ──────────────────────────────
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT post_stocktake(%L)', st));
    IF v_msg <> 'PERMISSION_DENIED|action.stocktake_post' THEN RAISE EXCEPTION 'CELL S4a wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL S4a fusheng@ · post → %', v_msg;
    v_msg := pg_temp.try_as('admin@swm-os.test', format('SELECT record_stocktake_count(%L, %L, NULL, %s, %L)', st, b, b_rem - 1, 'admin recount'));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'CELL S4b setup wrong: %', v_msg; END IF;
    v_msg := pg_temp.try_as('admin@swm-os.test', format('SELECT post_stocktake(%L)', st));
    IF v_msg <> 'STOCKTAKE_COUNTER_CANNOT_POST|' || st_code THEN RAISE EXCEPTION 'CELL S4b wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL S4b admin@ · recount, then post → % (counts on the stocktake: %)', v_msg,
        (SELECT count(*) FROM stocktake_counts WHERE stocktake_id = st);
    v_msg := pg_temp.try_as('admin@swm-os.test', format('SELECT post_stocktake(%L)', st82));
    IF v_msg <> 'SELF_APPROVAL_FORBIDDEN|raiser' THEN RAISE EXCEPTION 'CELL S4c wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL S4c admin@ · post ST-2026-0082 (opened by admin@) → %', v_msg;
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format('SELECT post_stocktake(%L)', st));
    IF v_msg <> 'PERMISSION_DENIED|action.stocktake_post' THEN RAISE EXCEPTION 'CELL S4d wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL S4d sandra@ · post → %', v_msg;

    -- ── S5 · 财务过账 ──────────────────────────────────────────────────────────
    SELECT count(*) INTO v_je0 FROM journal_entries;
    v_1200 := pg_temp.bal('1200'); v_5200 := pg_temp.bal('5200');
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT post_stocktake(%L)', st));
    IF v_msg <> 'OK' OR (SELECT status FROM stocktakes WHERE id = st) <> 'posted' THEN RAISE EXCEPTION 'CELL S5 wrong: %', v_msg; END IF;
    v_amt := round(1 * b_landed, 2);
    IF (SELECT count(*) FROM journal_entries) <> v_je0 + (CASE WHEN v_amt <> 0 THEN 1 ELSE 0 END)
       OR pg_temp.bal('1200') <> v_1200 - v_amt OR pg_temp.bal('5200') <> v_5200 + v_amt
       OR (SELECT remaining_qty FROM inbound_batches WHERE id = b) <> b_rem - 1 THEN
        RAISE EXCEPTION 'CELL S5 wrong: journal / balances / remaining';
    END IF;
    RAISE NOTICE 'CELL S5 chooer@ · post % → posted; % remaining % → %; journal_entries % → %; 1200 % → % · 5200 % → % (1 × landed %)',
        st_code, b_code, b_rem, b_rem - 1, v_je0, (SELECT count(*) FROM journal_entries),
        v_1200, pg_temp.bal('1200'), v_5200, pg_temp.bal('5200'), b_landed;
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT record_stocktake_count(%L, %L, NULL, 1)', st, b));
    IF v_msg <> 'STOCKTAKE_NOT_OPEN|posted' THEN RAISE EXCEPTION 'CELL S6 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL S6 fusheng@ · count after posting → %', v_msg;

    -- ── G1 · 到岸成本不再给仓库 ────────────────────────────────────────────────
    v_msg := pg_temp.val_as('fusheng@evoltrya.test', format('SELECT batch_freight_base(%L)::text || %L || batch_processing_cost_base(%L)::text', b1, ' / ', b1));
    IF v_msg <> 'NULL' THEN RAISE EXCEPTION 'CELL G1a wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL G1a fusheng@ · freight / processing cost of IN-2026-0001 → % (restricted)', v_msg;
    v_msg := pg_temp.val_as('chooer@evoltrya.test', format('SELECT batch_freight_base(%L)::text || %L || batch_processing_cost_base(%L)::text', b1, ' / ', b1));
    IF v_msg = 'NULL' OR v_msg LIKE 'ERR%' THEN RAISE EXCEPTION 'CELL G1b wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL G1b chooer@ · freight / processing cost of IN-2026-0001 → %', v_msg;
    PERFORM pg_temp.as_user('fusheng@evoltrya.test');
    BEGIN
        PERFORM inbound_batch_landed_unit_cost(b1);
        v_msg := 'NO REFUSAL';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg NOT LIKE 'LANDED_COST_PERMISSION_DENIED%' THEN RAISE EXCEPTION 'CELL G1c wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL G1c fusheng@ claims · inbound_batch_landed_unit_cost (asked with EXECUTE) → %', v_msg;

    -- ── G2 · is_final 只走函数 ────────────────────────────────────────────────
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('UPDATE assay_results SET is_final = NOT is_final WHERE id = %L', asy));
    IF v_msg <> 'ASSAY_FINAL_THROUGH_FUNCTION_ONLY' THEN RAISE EXCEPTION 'CELL G2 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL G2 fusheng@ · direct is_final flip on ASY-2026-0004 → %', v_msg;

    -- ── G3 · 已定价的收货不换来路 ──────────────────────────────────────────────
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('UPDATE inbound_batches SET supplier_id = %L WHERE id = %L', v_sup2, b1));
    IF v_msg <> 'RECEIPT_PRICED_SOURCE_FROZEN|IN-2026-0001' THEN RAISE EXCEPTION 'CELL G3a wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL G3a fusheng@ · change supplier of priced IN-2026-0001 → %', v_msg;
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('UPDATE inbound_batches SET supplier_id = %L WHERE id = %L', v_sup2, b153));
    IF v_msg <> 'OK' OR (SELECT supplier_id FROM inbound_batches WHERE id = b153) IS DISTINCT FROM v_sup2 THEN
        RAISE EXCEPTION 'CELL G3b wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL G3b fusheng@ · change supplier of unpriced IN-2026-0153 → % (rolled back)', v_msg;

    -- ── G4 · 提单人之外没人批得动 ──────────────────────────────────────────────
    v_msg := pg_temp.try_as('admin@swm-os.test', format('SELECT submit_payroll_request(%L, %L, %L)', pay1, 'reversal', 'ROLE1B3A live proof'));
    IF v_msg <> 'PAYROLL_NO_OTHER_DECIDER|PAY-2026-0001' THEN RAISE EXCEPTION 'CELL G4a wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL G4a admin@ · payroll reversal request for PAY-2026-0001 → %', v_msg;
    v_msg := pg_temp.try_as('admin@swm-os.test', format('SELECT submit_payment_request(%L, 10, %L, NULL, NULL, CURRENT_DATE, %L)', v_sup3, v_base, 'ROLE1B3A live proof'));
    IF v_msg <> 'PAYMENT_REQUEST_NO_OTHER_DECIDER' THEN RAISE EXCEPTION 'CELL G4b wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL G4b admin@ · payment request 10.00 to SUP-2026-0003 → %', v_msg;
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT submit_payment_request(%L, 10, %L, NULL, NULL, CURRENT_DATE, %L)', v_sup3, v_base, 'ROLE1B3A live proof'));
    IF v_msg <> 'OK' OR (SELECT count(*) FROM payment_requests WHERE status = 'submitted' AND notes = 'ROLE1B3A live proof') <> 1 THEN
        RAISE EXCEPTION 'CELL G4c wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL G4c chooer@ · the same request → submitted (tim@ decides it; rolled back)';

    -- ── L · 清单对总账(tim@ 读;盘点只动 1200 / 5200,不碰应付应收)────────────
    PERFORM pg_temp.as_user('tim@evoltrya.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT s->>'unexplained_base' INTO v_unx_ap FROM jsonb_array_elements(list_ledger_reconciliation()->'sides') s WHERE s->>'side' = 'ap';
    SELECT s->>'unexplained_base' INTO v_unx_ar FROM jsonb_array_elements(list_ledger_reconciliation()->'sides') s WHERE s->>'side' = 'ar';
    EXECUTE 'RESET ROLE';
    IF v_unx_ap <> '0.00' OR v_unx_ar <> '0.00' THEN RAISE EXCEPTION 'CELL L wrong: AP % AR %', v_unx_ap, v_unx_ar; END IF;
    RAISE NOTICE 'CELL L tim@ · list_ledger_reconciliation unexplained inside the transaction → AP % · AR %', v_unx_ap, v_unx_ar;
END;
$proof$;

SELECT 'PROOF PASSED — every cell matched; rolling back' AS verdict, now() AS finished_at;
ROLLBACK;
