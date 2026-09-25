-- db/scripts/2026-09-25-role1b3b-live-proof.sql
-- ROLE-1 Batch 3b · 线上证明(一笔事务,最后 ROLLBACK —— 线上什么都不留)。
-- 以 postgres 连接(rolbypassrls = t);每一格用 request.jwt.claims 换成一个【真账号】,在
-- SET LOCAL ROLE authenticated 下跑,拒绝与读回各印一行 CELL。任何一格与期望不符 → RAISE,整笔回滚,
-- psql 以非零退出(PROOF_OWN_EXIT)。
--   chooer@ = finance · tim@ = cfo · admin@ = admin(与 tim@ 同一个人)· sandra@ = cco · vince@ = gm ·
--   fusheng@ = warehouse · phua@ = cto
-- 用到的线上行:MAT-2026-0002 · SUP-2026-0003(已批准)· ZZ-PROCCOST1-DEMO(线上唯一一批【可加工】的料:
-- ZZ-SMOKE-NTF,已放电、已定价 —— 工单行、投料与产出都用它;MAT-2026-0002 是 undecided,提交会拒)· OUT-2026-0002(不出自加工的产出批次,注销)。事务里建的收货、工单、加工单、
-- 产出批次与分录都随 ROLLBACK 一起消失 —— ★ 但编号序列【不回滚】(IN / WO / PR / OUT 各前进一两格)。
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
    m2 uuid; mp uuid; s3 uuid; ib3 uuid; ob2 uuid; u_fs uuid; u_ch uuid;
    v_res jsonb; v_msg text; v_n int; v_je0 int; v_1200 numeric; v_1220 numeric;
    wo_fs uuid; wo_fs_code text; wo_ad uuid; v_run uuid; v_rcpt uuid; v_rcpt_code text;
    v_lines jsonb; v_in jsonb; v_out jsonb; v_unx_ap text; v_unx_ar text; e text;
BEGIN
    SELECT id INTO m2 FROM materials WHERE code = 'MAT-2026-0002';
    SELECT id INTO mp FROM materials WHERE code = 'ZZ-SMOKE-NTF';
    SELECT id INTO s3 FROM suppliers WHERE code = 'SUP-2026-0003';
    SELECT id INTO ib3 FROM inbound_batches WHERE code = 'ZZ-PROCCOST1-DEMO';
    SELECT id INTO ob2 FROM output_batches WHERE code = 'OUT-2026-0002';
    SELECT id INTO u_fs FROM auth.users WHERE email = 'fusheng@evoltrya.test';
    SELECT id INTO u_ch FROM auth.users WHERE email = 'chooer@evoltrya.test';
    IF mp IS NULL OR m2 IS NULL OR s3 IS NULL OR ib3 IS NULL OR ob2 IS NULL THEN
        RAISE EXCEPTION 'PROOF_SETUP|a named live row is missing';
    END IF;
    v_lines := jsonb_build_array(jsonb_build_object('material_id', mp, 'planned_qty', 10));
    v_in  := jsonb_build_array(jsonb_build_object('inbound_batch_id', ib3, 'quantity_consumed', 10));
    v_out := jsonb_build_array(jsonb_build_object('material_id', mp, 'quantity', 9));

    -- ── C · 谁持什么(每个账号以自己的身份问)───────────────────────────────────
    FOR e IN SELECT unnest(ARRAY['fusheng@evoltrya.test','chooer@evoltrya.test','admin@swm-os.test','sandra@evoltrya.test',
                                 'phua@evolytra.test','tim@evoltrya.test','vince@evoltrya.test']) LOOP
        v_msg := pg_temp.val_as(e, $q$SELECT string_agg(c, ' ' ORDER BY c) FROM unnest(current_user_permissions()) c
                                     WHERE c IN ('action.receive_goods','action.batch_write_off','action.wo_create','action.wo_release',
                                                 'action.processing_commit','action.processing_rollback','action.processing_aftercare',
                                                 'module.processing.view','module.processing.edit','module.materials.view')$q$);
        RAISE NOTICE 'CELL C % · holds → %', e, v_msg;
        IF e = 'fusheng@evoltrya.test' AND v_msg <> 'action.batch_write_off action.processing_aftercare action.processing_commit action.processing_rollback action.receive_goods action.wo_create module.processing.view' THEN
            RAISE EXCEPTION 'CELL C fusheng wrong: %', v_msg; END IF;
        IF e = 'chooer@evoltrya.test' AND v_msg <> 'action.wo_release module.materials.view module.processing.view' THEN
            RAISE EXCEPTION 'CELL C chooer wrong: %', v_msg; END IF;
    END LOOP;

    -- ── R · 收货建单归仓库 ────────────────────────────────────────────────────
    FOREACH e IN ARRAY ARRAY['sandra@evoltrya.test','phua@evolytra.test','chooer@evoltrya.test'] LOOP
        v_msg := pg_temp.try_as(e, format($q$SELECT create_inbound_batch(%L, %L, 1, 'kg', CURRENT_DATE, '待加工', NULL, 'ROLE1B3B live proof', p_source_reason_code => 'other', p_source_reason_note => 'ROLE1B3B live proof')$q$, m2, s3));
        IF v_msg <> 'PERMISSION_DENIED|action.receive_goods' THEN RAISE EXCEPTION 'CELL R1 % wrong: %', e, v_msg; END IF;
        RAISE NOTICE 'CELL R1 % · create a goods receipt → %', e, v_msg;
    END LOOP;
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format('SELECT receive_inbound_batch_against_po(%L, %L, 1)', m2, s3));
    IF v_msg <> 'PERMISSION_DENIED|action.receive_goods' THEN RAISE EXCEPTION 'CELL R2 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL R2 sandra@ · receive against a PO → %', v_msg;
    PERFORM pg_temp.as_user('fusheng@evoltrya.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := create_inbound_batch(m2, s3, 1, 'kg', CURRENT_DATE, '待加工', NULL, 'ROLE1B3B live proof',
        p_source_reason_code => 'other', p_source_reason_note => 'ROLE1B3B live proof');
    EXECUTE 'RESET ROLE';
    v_rcpt := (v_res->>'batch_id')::uuid;
    SELECT code INTO v_rcpt_code FROM inbound_batches WHERE id = v_rcpt;
    IF (SELECT created_by FROM inbound_batches WHERE id = v_rcpt) IS DISTINCT FROM u_fs THEN RAISE EXCEPTION 'CELL R3 wrong: creator'; END IF;
    RAISE NOTICE 'CELL R3 fusheng@ · create % (unpriced) → created_by fusheng@', v_rcpt_code;

    -- ── O · 工单:仓库建,财务下达,建单人不能下达 ─────────────────────────────────
    FOREACH e IN ARRAY ARRAY['sandra@evoltrya.test','phua@evolytra.test'] LOOP
        v_msg := pg_temp.try_as(e, format('SELECT create_work_order(%L::jsonb)', v_lines));
        IF v_msg <> 'PERMISSION_DENIED|action.wo_create' THEN RAISE EXCEPTION 'CELL O1 % wrong: %', e, v_msg; END IF;
        RAISE NOTICE 'CELL O1 % · create a work order → %', e, v_msg;
    END LOOP;
    PERFORM pg_temp.as_user('fusheng@evoltrya.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := create_work_order(v_lines, NULL, CURRENT_DATE, 'ROLE1B3B live proof');
    EXECUTE 'RESET ROLE';
    wo_fs := (v_res->>'work_order_id')::uuid; wo_fs_code := v_res->>'code';
    RAISE NOTICE 'CELL O2 fusheng@ · create % → draft, created_by fusheng@', wo_fs_code;
    FOREACH e IN ARRAY ARRAY['fusheng@evoltrya.test','sandra@evoltrya.test','phua@evolytra.test'] LOOP
        v_msg := pg_temp.try_as(e, format('SELECT release_work_order(%L)', wo_fs));
        IF v_msg <> 'PERMISSION_DENIED|action.wo_release' THEN RAISE EXCEPTION 'CELL O3 % wrong: %', e, v_msg; END IF;
        RAISE NOTICE 'CELL O3 % · release % → %', e, wo_fs_code, v_msg;
    END LOOP;
    PERFORM pg_temp.as_user('admin@swm-os.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    wo_ad := (create_work_order(v_lines, NULL, CURRENT_DATE, 'ROLE1B3B live proof admin')->>'work_order_id')::uuid;
    EXECUTE 'RESET ROLE';
    v_msg := pg_temp.try_as('admin@swm-os.test', format('SELECT release_work_order(%L)', wo_ad));
    IF v_msg <> 'SELF_APPROVAL_FORBIDDEN|raiser' THEN RAISE EXCEPTION 'CELL O4 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL O4 admin@ · create a work order, then release it → %', v_msg;
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT release_work_order(%L)', wo_fs));
    IF v_msg <> 'OK' OR (SELECT status FROM work_orders WHERE id = wo_fs) <> 'released'
       OR NOT EXISTS (SELECT 1 FROM work_order_history WHERE work_order_id = wo_fs AND change_type = 'released' AND changed_by = u_ch) THEN
        RAISE EXCEPTION 'CELL O5 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL O5 chooer@ · release % → released; history names chooer@', wo_fs_code;
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format($q$SELECT amend_work_order(%L, 'ROLE1B3B live proof', p_notes => 'amended by cco', p_set_notes => true)$q$, wo_fs));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'CELL O6 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL O6 sandra@ · amend % (module.processing.edit) → OK', wo_fs_code;

    -- ── P · 提交加工归仓库 ────────────────────────────────────────────────────
    FOREACH e IN ARRAY ARRAY['sandra@evoltrya.test','phua@evolytra.test'] LOOP
        v_msg := pg_temp.try_as(e, format($q$SELECT commit_processing_run(CURRENT_DATE, 'ROLE1B3B live proof', 1, %L::jsonb, %L::jsonb, 'weight', %L, NULL, 'manual_disassembly')$q$, v_in, v_out, wo_fs));
        IF v_msg <> 'PERMISSION_DENIED|action.processing_commit' THEN RAISE EXCEPTION 'CELL P1 % wrong: %', e, v_msg; END IF;
        RAISE NOTICE 'CELL P1 % · commit a run → %', e, v_msg;
    END LOOP;
    SELECT count(*) INTO v_je0 FROM journal_entries;
    v_1200 := pg_temp.bal('1200'); v_1220 := pg_temp.bal('1220');
    PERFORM pg_temp.as_user('fusheng@evoltrya.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_run := commit_processing_run(CURRENT_DATE, 'ROLE1B3B live proof', 1, v_in, v_out, 'weight', wo_fs, NULL, 'manual_disassembly');
    EXECUTE 'RESET ROLE';
    IF (SELECT work_order_id FROM processing_runs WHERE id = v_run) IS DISTINCT FROM wo_fs THEN RAISE EXCEPTION 'CELL P2 wrong'; END IF;
    RAISE NOTICE 'CELL P2 fusheng@ · commit % against % (ZZ-PROCCOST1-DEMO −10, ZZ-SMOKE-NTF +9, loss 1) → journal_entries % → %; 1200 % → % · 1220 % → %',
        (SELECT code FROM processing_runs WHERE id = v_run), wo_fs_code, v_je0, (SELECT count(*) FROM journal_entries),
        v_1200, pg_temp.bal('1200'), v_1220, pg_temp.bal('1220');

    -- ── D · 直连写按名拒(sandra 持 processing.edit —— 策略那一层对她是开的)─────────
    v_msg := pg_temp.try_as('sandra@evoltrya.test', $q$INSERT INTO processing_runs (process_date, status, allocation_basis, operation_type_code) VALUES (CURRENT_DATE, 'committed', 'weight', 'manual_disassembly')$q$);
    IF v_msg <> 'PROCESSING_THROUGH_FUNCTION_ONLY|processing_runs|insert' THEN RAISE EXCEPTION 'CELL D1 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL D1 sandra@ · direct INSERT a committed run → %', v_msg;
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format($q$UPDATE processing_runs SET status = 'reversed' WHERE id = %L$q$, v_run));
    IF v_msg <> 'PROCESSING_THROUGH_FUNCTION_ONLY|processing_runs|update' THEN RAISE EXCEPTION 'CELL D2 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL D2 sandra@ · direct UPDATE status = reversed → %', v_msg;
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format('DELETE FROM processing_runs WHERE id = %L', v_run));
    IF v_msg <> 'PROCESSING_THROUGH_FUNCTION_ONLY|processing_runs|delete' THEN RAISE EXCEPTION 'CELL D3 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL D3 sandra@ · direct DELETE the run → %', v_msg;

    -- ── A · 损耗与交接班 ──────────────────────────────────────────────────────
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format($q$INSERT INTO processing_run_losses (run_id, loss_category_code, quantity) VALUES (%L, 'moisture', 1)$q$, v_run));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'CELL A1 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL A1 fusheng@ · record a loss category on the run → OK';
    v_msg := pg_temp.try_as('vince@evoltrya.test', format('SELECT acknowledge_shift_handover(%L)', gen_random_uuid()));
    IF v_msg <> 'PERMISSION_DENIED|action.processing_aftercare' THEN RAISE EXCEPTION 'CELL A2 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL A2 vince@ · acknowledge a handover → %', v_msg;
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT acknowledge_shift_handover(%L)', gen_random_uuid()));
    IF v_msg NOT LIKE 'HANDOVER_NOT_FOUND|%' THEN RAISE EXCEPTION 'CELL A3 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL A3 fusheng@ · acknowledge a missing handover → past the gate (HANDOVER_NOT_FOUND)';

    -- ── B · 回滚归仓库;然后关单 ───────────────────────────────────────────────
    v_msg := pg_temp.try_as('phua@evolytra.test', format('SELECT rollback_processing_run(%L, %L)', v_run, 'ROLE1B3B live proof'));
    IF v_msg <> 'PERMISSION_DENIED|action.processing_rollback' THEN RAISE EXCEPTION 'CELL B1 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL B1 phua@ · roll back the run → %', v_msg;
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT rollback_processing_run(%L, %L)', v_run, 'ROLE1B3B live proof'));
    IF v_msg <> 'OK' OR (SELECT status FROM processing_runs WHERE id = v_run) <> 'reversed' THEN RAISE EXCEPTION 'CELL B2 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL B2 fusheng@ · roll back the run → reversed; 1200 back to % · 1220 back to %', pg_temp.bal('1200'), pg_temp.bal('1220');
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT close_work_order(%L, %L)', wo_fs, 'ROLE1B3B live proof'));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'CELL B3 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL B3 fusheng@ · close % → closed', wo_fs_code;

    -- ── W · 注销批次归仓库 ────────────────────────────────────────────────────
    FOREACH e IN ARRAY ARRAY['chooer@evoltrya.test','sandra@evoltrya.test'] LOOP
        v_msg := pg_temp.try_as(e, format('SELECT soft_delete_inbound_batch(%L, %L)', v_rcpt, 'ROLE1B3B live proof'));
        IF v_msg <> 'PERMISSION_DENIED|action.batch_write_off' THEN RAISE EXCEPTION 'CELL W1 % wrong: %', e, v_msg; END IF;
        v_msg := pg_temp.try_as(e, format('SELECT soft_delete_output_batch(%L, %L)', ob2, 'ROLE1B3B live proof'));
        IF v_msg <> 'PERMISSION_DENIED|action.batch_write_off' THEN RAISE EXCEPTION 'CELL W1 % output wrong: %', e, v_msg; END IF;
        RAISE NOTICE 'CELL W1 % · write off an inbound and an output batch → PERMISSION_DENIED|action.batch_write_off ×2', e;
    END LOOP;
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT soft_delete_inbound_batch(%L, %L)', v_rcpt, 'ROLE1B3B live proof'));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'CELL W2 wrong: %', v_msg; END IF;
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT soft_delete_output_batch(%L, %L)', ob2, 'ROLE1B3B live proof'));
    IF v_msg <> 'OK' OR (SELECT deleted_by FROM output_batches WHERE id = ob2) IS DISTINCT FROM u_fs THEN RAISE EXCEPTION 'CELL W2 output wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL W2 fusheng@ · write off % and OUT-2026-0002 → both written off by fusheng@', v_rcpt_code;

    -- ── M · 物料名只经查名视图 ────────────────────────────────────────────────
    v_msg := pg_temp.val_as('fusheng@evoltrya.test', 'SELECT count(*)::text FROM material_lookup');
    IF v_msg IN ('0', 'NULL') OR v_msg LIKE 'ERR%' THEN RAISE EXCEPTION 'CELL M1 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL M1 fusheng@ · material_lookup (view) → % rows', v_msg;
    v_msg := pg_temp.val_as('fusheng@evoltrya.test', 'SELECT count(*)::text FROM materials');
    IF v_msg <> '0' THEN RAISE EXCEPTION 'CELL M2 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL M2 fusheng@ · materials (base table, RLS) → % rows', v_msg;

    -- ── L · 清单对总账(tim@ 读)────────────────────────────────────────────────
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
