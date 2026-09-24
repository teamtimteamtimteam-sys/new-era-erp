-- db/scripts/2026-09-25-role1b4a-live-proof.sql
-- ROLE-1 Batch 4a · 线上证明(一笔事务,最后 ROLLBACK —— 线上什么都不留)。
-- 以 postgres 连接(rolbypassrls = t);每一格用 request.jwt.claims 换成一个【真账号】,在
-- SET LOCAL ROLE authenticated 下跑,拒绝与读回各印一行 CELL。任何一格与期望不符 → RAISE,整笔回滚,
-- psql 以非零退出(PROOF_OWN_EXIT)。
--   fusheng@ = warehouse · sandra@ = cco · phua@ = cto · chooer@ = finance · vince@ = gm · tim@ = cfo
-- 用到的线上行:IN-2026-0011(已定价 150,SUP-2026-0002)· IN-2026-0153(未定价,680 kg)。
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

DO $proof$
DECLARE
    v_b11 uuid; v_b153 uuid; v_mat uuid; v_sup uuid; v_base text;
    v_num numeric; v_n int; v_n0 int; v_msg text; v_denied boolean; v_res jsonb; v_je uuid; v_je_code text;
    v_2000_before numeric; v_2000_after numeric; v_sides text;
BEGIN
    SELECT id INTO v_b11 FROM inbound_batches WHERE code = 'IN-2026-0011';
    SELECT id, material_id, supplier_id INTO v_b153, v_mat, v_sup FROM inbound_batches WHERE code = 'IN-2026-0153';
    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- ── fusheng@(warehouse):看得见采购价,看不见销售与成本那一侧,定不了价 ──────────
    PERFORM pg_temp.as_user('fusheng@evoltrya.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT unit_price INTO v_num FROM inbound_batches_masked WHERE id = v_b11;
    IF v_num IS DISTINCT FROM 150 THEN RAISE EXCEPTION 'CELL W1 wrong: fusheng@ unit price %', v_num; END IF;
    RAISE NOTICE 'CELL W1 fusheng@ · inbound_batches_masked IN-2026-0011 unit_price = % (view)', v_num;
    SELECT count(*) FILTER (WHERE new_unit_price IS NOT NULL), count(*) INTO v_n, v_n0
      FROM price_history_masked WHERE inbound_batch_id = v_b11;
    IF v_n <> v_n0 OR v_n0 = 0 THEN RAISE EXCEPTION 'CELL W2 wrong: % of % price-history rows visible', v_n, v_n0; END IF;
    RAISE NOTICE 'CELL W2 fusheng@ · price_history_masked IN-2026-0011: % of % rows carry a price (view)', v_n, v_n0;
    SELECT count(*), count(unit_cost_base) INTO v_n0, v_n FROM output_batch_valuation;
    IF v_n <> 0 THEN RAISE EXCEPTION 'CELL W3 wrong: fusheng@ sees % output unit costs', v_n; END IF;
    RAISE NOTICE 'CELL W3 fusheng@ · output_batch_valuation: % rows, % with a unit cost (valuation stays on view_prices)', v_n0, v_n;
    v_msg := NULL;
    BEGIN PERFORM set_inbound_unit_price(v_b153, 2, v_base); EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|action.price_receipts' THEN RAISE EXCEPTION 'CELL W4 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL W4 fusheng@ · set_inbound_unit_price IN-2026-0153 → %', v_msg;
    SELECT count(*) INTO v_n0 FROM inbound_batches_masked WHERE supplier_id = v_sup;
    v_msg := NULL;
    BEGIN
        PERFORM create_inbound_batch(v_mat, v_sup, 1, 'kg', CURRENT_DATE, '待加工', 9, 'ROLE1B4A proof W5',
            p_source_reason_code => 'other', p_source_reason_note => 'ROLE1B4A live proof', p_currency => v_base);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    SELECT count(*) INTO v_n FROM inbound_batches_masked WHERE supplier_id = v_sup;
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|action.price_receipts' OR v_n <> v_n0 THEN
        RAISE EXCEPTION 'CELL W5 wrong: % / % → %', v_msg, v_n0, v_n; END IF;
    RAISE NOTICE 'CELL W5 fusheng@ · desk receipt WITH a price → % ; receipts for that supplier % → % (nothing written)', v_msg, v_n0, v_n;
    v_msg := NULL;
    BEGIN PERFORM reprice_from_committed_terms(v_b153, CURRENT_DATE); EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|action.price_receipts' THEN RAISE EXCEPTION 'CELL W6 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL W6 fusheng@ · reprice_from_committed_terms → %', v_msg;
    EXECUTE 'RESET ROLE';

    -- ── sandra@(cco)与 phua@(cto):持 inbound.edit,从此定不了价 ────────────────────
    PERFORM pg_temp.as_user('sandra@evoltrya.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_msg := NULL;
    BEGIN PERFORM set_inbound_unit_price(v_b153, 2, v_base); EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    EXECUTE 'RESET ROLE';
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|action.price_receipts' THEN RAISE EXCEPTION 'CELL S1 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL S1 sandra@ · set_inbound_unit_price → %', v_msg;
    PERFORM pg_temp.as_user('phua@evolytra.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_msg := NULL;
    BEGIN PERFORM set_inbound_unit_price(v_b153, 2, v_base); EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    EXECUTE 'RESET ROLE';
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|action.price_receipts' THEN RAISE EXCEPTION 'CELL P1 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL P1 phua@ · set_inbound_unit_price → %', v_msg;

    -- ── chooer@(finance):定价过账;三扇侧门 ─────────────────────────────────────────
    SELECT COALESCE(sum(jl.credit - jl.debit), 0) INTO v_2000_before
      FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id WHERE a.code = '2000';
    PERFORM pg_temp.as_user('chooer@evoltrya.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := set_inbound_unit_price(v_b153, 2, v_base, NULL, 'ROLE1B4A live proof');
    EXECUTE 'RESET ROLE';
    SELECT id, code INTO v_je, v_je_code FROM journal_entries WHERE source_type = 'purchase' AND source_id = v_b153;
    SELECT COALESCE(sum(jl.credit - jl.debit), 0) INTO v_2000_after
      FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id WHERE a.code = '2000';
    IF v_je IS NULL OR v_2000_after - v_2000_before <> 1360.00 THEN
        RAISE EXCEPTION 'CELL F1 wrong: entry % · 2000 moved %', v_je_code, v_2000_after - v_2000_before; END IF;
    RAISE NOTICE 'CELL F1 chooer@ · prices IN-2026-0153 at 2 % → % ; 2000 credit +% (680 × 2) — inside the transaction', v_base, v_je_code, v_2000_after - v_2000_before;
    PERFORM pg_temp.as_user('chooer@evoltrya.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_msg := NULL;
    BEGIN PERFORM reverse_journal_entry(v_je, CURRENT_DATE, 'ROLE1B4A proof'); EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg IS DISTINCT FROM format('JE_REVERSE_USE_SOURCE_PATH|%s|purchase', v_je_code) THEN RAISE EXCEPTION 'CELL F2 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL F2 chooer@ · reverse_journal_entry on the pricing entry → %', v_msg;
    v_msg := NULL;
    BEGIN
        INSERT INTO price_history (inbound_batch_id, old_unit_price, new_unit_price, currency, original_price, fx_rate)
        VALUES (v_b153, 2, 1, v_base, 1, 1);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLSTATE || ' ' || SQLERRM; END;
    IF v_msg IS NULL OR v_msg NOT LIKE '42501%' THEN RAISE EXCEPTION 'CELL F3 wrong: %', COALESCE(v_msg, '(inserted)'); END IF;
    RAISE NOTICE 'CELL F3 chooer@ · direct INSERT into price_history → %', v_msg;
    v_msg := NULL;
    BEGIN PERFORM reprice_inbound_batch(v_b153, 3, v_base, NULL, 'ROLE1B4A proof'); EXCEPTION WHEN OTHERS THEN v_msg := SQLSTATE || ' ' || SQLERRM; END;
    EXECUTE 'RESET ROLE';
    IF v_msg IS NULL OR v_msg NOT LIKE '42501%' THEN RAISE EXCEPTION 'CELL F4 wrong: %', COALESCE(v_msg, '(called)'); END IF;
    RAISE NOTICE 'CELL F4 chooer@ · calling the pricing engine reprice_inbound_batch directly → %', v_msg;

    -- ── vince@(gm)与 tim@(cfo):谁都不少看一格;清单对总账两边都答得上 ───────────
    PERFORM pg_temp.as_user('vince@evoltrya.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT unit_price INTO v_num FROM inbound_batches_masked WHERE id = v_b11;
    EXECUTE 'RESET ROLE';
    IF v_num IS DISTINCT FROM 150 THEN RAISE EXCEPTION 'CELL V1 wrong: %', v_num; END IF;
    RAISE NOTICE 'CELL V1 vince@ · inbound_batches_masked IN-2026-0011 unit_price = % (view)', v_num;
    PERFORM pg_temp.as_user('tim@evoltrya.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT string_agg((s->>'side') || '=' || COALESCE(s->>'refusal', 'answered'), ' ' ORDER BY s->>'side') INTO v_sides
      FROM jsonb_array_elements(list_ledger_reconciliation()->'sides') s;
    EXECUTE 'RESET ROLE';
    IF v_sides IS DISTINCT FROM 'ap=answered ar=answered' THEN RAISE EXCEPTION 'CELL T1 wrong: %', v_sides; END IF;
    RAISE NOTICE 'CELL T1 tim@ · list_ledger_reconciliation sides: %', v_sides;

    -- ── 采购单批准的两级仍各有真的决定人(postgres,基于 approval_deciders)───────────
    FOR v_n IN 1..2 LOOP
        SELECT string_agg(DISTINCT u.email, ' ') INTO v_msg
          FROM approval_deciders('purchase_order', 'approve_purchase_order', v_n::smallint, NULL, NULL,
                (SELECT approval_level1_role_code FROM finance_settings),
                (SELECT approval_level2_role_code FROM finance_settings)) d
          JOIN auth.users u ON u.id = d.user_id;
        IF v_msg IS NULL THEN RAISE EXCEPTION 'CELL A% wrong: no decider', v_n; END IF;
        RAISE NOTICE 'CELL A% postgres · approve_purchase_order level % deciders: %', v_n, v_n, v_msg;
    END LOOP;
END;
$proof$;

SET CONSTRAINTS ALL IMMEDIATE;
SELECT 'PROOF PASSED (inside the transaction; ROLLBACK follows)' AS verdict, now() AS finished_at;
ROLLBACK;
