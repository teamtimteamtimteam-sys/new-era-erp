-- db/scripts/2026-09-25-apr7-live-proof.sql
-- APR-7 · 线上证明(一笔事务,最后 ROLLBACK —— 线上什么都不留)。
-- 以 postgres 连接(rolbypassrls = t);每一格用 request.jwt.claims 换成一个【真账号】,在
-- SET LOCAL ROLE authenticated 下跑,拒绝与读回各印一行 CELL。任何一格与期望不符 → RAISE,整笔回滚,
-- psql 以非零退出(PROOF_OWN_EXIT)。
--   fusheng@ = warehouse(提单人)· tim@ = cfo(批)· admin@ = admin(与 tim@ 同一个人)·
--   sandra@ = cco(看得见价格、不是二级)· chooer@ = finance(看得见价格、不是二级、不持任何仓库码)
-- 用到的线上行(2026-09-25/26 以 postgres 读基表):
--   IN-2026-0179(没计价、300 kg、不是任何加工单的投料)—— 注销的全程;
--   OUT-2026-0187(PROC-2026-0164 的产出、60 kg、单位成本 2.2477 → 134.86)—— 有价值的注销,借 5200 / 贷 1220;
--   PROC-2026-0225(投料 IN-2026-0180、产出 OUT-2026-0380/0381、没有证书)—— 回滚的全程;
--   PROC-2026-0009(加工日 2026-07-03,落在锁至 2026-08-01 之前的期间里;会作废 COD-2026-0002)—— 只提、再撤回,
--     证 CFO 那一块在批之前看得见「已锁期间」与「会作废哪一张」;
--   COD-2026-0001(IN-2026-0153)—— 作废的全程,连同公开核验在等待中与批准后的读数;
--   IN-2026-0012(计价、还欠供应商 10,000.00)—— 提交就拒 INBOUND_HAS_OPEN_PAYABLE(Q4)。
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

-- 一次直连写,然后【当场】结一次延迟约束的账(PostgREST 一次调用就是一笔事务,只碰一张表)
CREATE FUNCTION pg_temp.try_direct_as(p_email text, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.as_user(p_email);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'DIRECT_WRITE_WENT_THROUGH';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    SET CONSTRAINTS ALL DEFERRED;
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

SELECT side, list, ledger, unexplained FROM pg_temp.recon();

DO $proof$
DECLARE
    v_fu uuid; v_tim uuid;
    b179 uuid; b012 uuid; o187 uuid; o380 uuid; r225 uuid; r009 uuid; c001 uuid; c001_tok uuid;
    q uuid; qx uuid; v_res jsonb; v_msg text; v_n int; v_je0 int; v_mv0 int; v_wr0 int;
    b1200 numeric; b1220 numeric; b5200 numeric; d date := CURRENT_DATE;
BEGIN
    SELECT id INTO v_fu FROM auth.users WHERE email = 'fusheng@evoltrya.test';
    SELECT id INTO v_tim FROM auth.users WHERE email = 'tim@evoltrya.test';
    SELECT id INTO b179 FROM inbound_batches WHERE code = 'IN-2026-0179' AND deleted_at IS NULL;
    SELECT id INTO b012 FROM inbound_batches WHERE code = 'IN-2026-0012' AND deleted_at IS NULL;
    SELECT id INTO o187 FROM output_batches WHERE code = 'OUT-2026-0187' AND deleted_at IS NULL;
    SELECT id INTO o380 FROM output_batches WHERE code = 'OUT-2026-0380' AND deleted_at IS NULL;
    SELECT id INTO r225 FROM processing_runs WHERE code = 'PROC-2026-0225' AND deleted_at IS NULL;
    SELECT id INTO r009 FROM processing_runs WHERE code = 'PROC-2026-0009' AND deleted_at IS NULL;
    SELECT id, verification_token INTO c001, c001_tok FROM certificates_of_destruction WHERE code = 'COD-2026-0001' AND status = 'issued';
    IF b179 IS NULL OR b012 IS NULL OR o187 IS NULL OR o380 IS NULL OR r225 IS NULL OR r009 IS NULL OR c001 IS NULL THEN
        RAISE EXCEPTION 'PROOF_SETUP|a named live row is missing'; END IF;
    SELECT count(*) INTO v_je0 FROM journal_entries;
    SELECT count(*) INTO v_mv0 FROM inventory_movements;
    SELECT count(*) INTO v_wr0 FROM warehouse_requests;
    b1200 := pg_temp.bal('1200'); b1220 := pg_temp.bal('1220'); b5200 := pg_temp.bal('5200');
    RAISE NOTICE 'CELL S0 | postgres | before | JE % · movements % · warehouse_requests % · 1200 % · 1220 % · 5200 %',
        v_je0, v_mv0, v_wr0, b1200, b1220, b5200;

    -- ══ A · 关上的门(fusheng@ 持三个提单码)══
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT rollback_processing_run(%L, %L)', r225, 'door'));
    IF v_msg <> 'WAREHOUSE_NEEDS_APPROVED_REQUEST|rollback|PROC-2026-0225' THEN RAISE EXCEPTION 'CELL A1 %', v_msg; END IF;
    RAISE NOTICE 'CELL A1 | fusheng@ | rollback_processing_run(PROC-2026-0225) | %', v_msg;
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT void_cod(%L, %L)', c001, 'door'));
    IF v_msg <> 'WAREHOUSE_NEEDS_APPROVED_REQUEST|cod_void|COD-2026-0001' THEN RAISE EXCEPTION 'CELL A2 %', v_msg; END IF;
    RAISE NOTICE 'CELL A2 | fusheng@ | void_cod(COD-2026-0001) | %', v_msg;
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT soft_delete_inbound_batch(%L, %L)', b179, 'door'));
    IF v_msg <> 'WAREHOUSE_NEEDS_APPROVED_REQUEST|write_off_inbound|IN-2026-0179' THEN RAISE EXCEPTION 'CELL A3 %', v_msg; END IF;
    RAISE NOTICE 'CELL A3 | fusheng@ | soft_delete_inbound_batch(IN-2026-0179, 300 kg) | %', v_msg;
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT soft_delete_output_batch(%L, %L)', o187, 'door'));
    IF v_msg <> 'WAREHOUSE_NEEDS_APPROVED_REQUEST|write_off_output|OUT-2026-0187' THEN RAISE EXCEPTION 'CELL A4 %', v_msg; END IF;
    RAISE NOTICE 'CELL A4 | fusheng@ | soft_delete_output_batch(OUT-2026-0187, 60 kg) | %', v_msg;
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT rollback_processing_run_internal(%L, %L, NULL)', r225, 'door'));
    IF v_msg NOT LIKE 'permission denied for function rollback_processing_run_internal%' THEN RAISE EXCEPTION 'CELL A5 %', v_msg; END IF;
    RAISE NOTICE 'CELL A5 | fusheng@ | rollback_processing_run_internal (the body) | %', v_msg;
    -- Q7 · 直连写的探针:PostgREST 一次调用只碰一张表,每一条单独都过不了延迟的台账恒等式 / 软删守卫
    v_msg := pg_temp.try_direct_as('fusheng@evoltrya.test', format(
        'INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date) VALUES (%L, %L, -300, %L)',
        b179, 'writeoff', d));
    IF v_msg NOT LIKE 'LEDGER_INVARIANT|IN-2026-0179|%' THEN RAISE EXCEPTION 'CELL A6 %', v_msg; END IF;
    RAISE NOTICE 'CELL A6 | fusheng@ | direct INSERT of a writeoff movement (module.inventory.edit) | %', v_msg;
    v_msg := pg_temp.try_direct_as('fusheng@evoltrya.test', format(
        'UPDATE inbound_batches SET remaining_qty = 0 WHERE id = %L', b179));
    IF v_msg NOT LIKE 'LEDGER_INVARIANT|IN-2026-0179|%' THEN RAISE EXCEPTION 'CELL A7 %', v_msg; END IF;
    RAISE NOTICE 'CELL A7 | fusheng@ | direct UPDATE remaining_qty = 0 (module.inbound.edit) | %', v_msg;
    v_msg := pg_temp.try_direct_as('fusheng@evoltrya.test', format(
        'UPDATE inbound_batches SET deleted_at = now(), deleted_by = auth.uid(), delete_reason = %L WHERE id = %L', 'direct', b179));
    IF v_msg NOT LIKE 'SOFT_DELETE_NO_DIRECT_UPDATE|inbound_batches|IN-2026-0179' THEN RAISE EXCEPTION 'CELL A8 %', v_msg; END IF;
    RAISE NOTICE 'CELL A8 | fusheng@ | direct UPDATE deleted_at | %', v_msg;
    IF (SELECT count(*) FROM journal_entries) <> v_je0 OR (SELECT count(*) FROM inventory_movements) <> v_mv0 THEN
        RAISE EXCEPTION 'CELL A9 a refused door left a row'; END IF;

    -- ══ B · 注销申请(没计价的进料批)══
    v_res := pg_temp.call_as('fusheng@evoltrya.test', format('SELECT submit_inbound_write_off_request(%L, %L)',
        b179, 'APR-7 live proof · water damage'));
    q := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'submitted' OR (v_res->>'amount_base')::numeric <> 0
       OR (SELECT deleted_at FROM inbound_batches WHERE id = b179) IS NOT NULL
       OR (SELECT count(*) FROM inventory_movements) <> v_mv0 THEN RAISE EXCEPTION 'CELL B1 %', v_res; END IF;
    RAISE NOTICE 'CELL B1 | fusheng@ | submit write-off IN-2026-0179 | % · % · amount % · batch untouched · movements %',
        v_res->>'label', v_res->>'status', v_res->>'amount_base', v_mv0;
    SELECT count(*) INTO v_n FROM approval_pending_documents() p
     WHERE p.subject_type = 'warehouse_request' AND p.doc_id = q AND p.blocks_disable AND p.fixed_level = 2 AND p.subject_employee_id IS NULL;
    IF v_n <> 1 THEN RAISE EXCEPTION 'CELL B2 pending arm'; END IF;
    RAISE NOTICE 'CELL B2 | postgres | pending arm | blocks_disable true · fixed_level 2 · subject NULL · deciders: %',
        (SELECT string_agg(u.email, ' ') FROM approval_deciders('warehouse_request', 'decide_warehouse_request', 2::smallint, v_fu, NULL,
            (SELECT approval_level1_role_code FROM finance_settings), (SELECT approval_level2_role_code FROM finance_settings)) dd
          JOIN auth.users u ON u.id = dd.user_id);
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format(
        'INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date) VALUES (%L, %L, -1, %L)',
        b179, 'adjustment', d));
    IF v_msg <> 'WAREHOUSE_REQUEST_FREEZES_BATCH|IN-2026-0179|IN-2026-0179 · write-off #1' THEN RAISE EXCEPTION 'CELL B3 %', v_msg; END IF;
    RAISE NOTICE 'CELL B3 | fusheng@ | a movement on the frozen batch | %', v_msg;
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT submit_inbound_write_off_request(%L, %L)', b179, 'twice'));
    IF v_msg <> 'WAREHOUSE_REQUEST_OPEN|IN-2026-0179|IN-2026-0179 · write-off #1' THEN RAISE EXCEPTION 'CELL B4 %', v_msg; END IF;
    RAISE NOTICE 'CELL B4 | fusheng@ | a second request on the same batch | %', v_msg;
    v_msg := pg_temp.try_as('admin@swm-os.test', format('SELECT submit_output_write_off_request(%L, %L)', o187, 'admin'));
    IF v_msg <> 'WAREHOUSE_REQUEST_NO_OTHER_DECIDER|OUT-2026-0187 · write-off #1' THEN RAISE EXCEPTION 'CELL B5 %', v_msg; END IF;
    RAISE NOTICE 'CELL B5 | admin@ | raise a write-off (the CFO''s other account) | %', v_msg;
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT submit_inbound_write_off_request(%L, %L)', b012, 'owes'));
    IF v_msg NOT LIKE 'INBOUND_HAS_OPEN_PAYABLE|IN-2026-0012|10000.00' THEN RAISE EXCEPTION 'CELL B6 %', v_msg; END IF;
    RAISE NOTICE 'CELL B6 | fusheng@ | write-off of a priced batch still owed (Q4, at submit) | %', v_msg;
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT submit_inbound_write_off_request(%L, %L)', b179, 'finance'));
    IF v_msg <> 'PERMISSION_DENIED|action.batch_write_off' THEN RAISE EXCEPTION 'CELL B7 %', v_msg; END IF;
    RAISE NOTICE 'CELL B7 | chooer@ | raise a write-off | %', v_msg;
    IF (SELECT count(*) FROM warehouse_requests) <> v_wr0 + 1 THEN RAISE EXCEPTION 'CELL B8 a refused submit left a row'; END IF;

    -- ══ C · 谁批不了 ══
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT decide_warehouse_request(%L, true)', q));
    IF v_msg <> 'PERMISSION_DENIED|module.finance.view' THEN RAISE EXCEPTION 'CELL C1 %', v_msg; END IF;
    v_msg := v_msg || ' · ' || pg_temp.try_as('sandra@evoltrya.test', format('SELECT decide_warehouse_request(%L, true)', q));
    IF v_msg NOT LIKE '%APPROVAL_NOT_AUTHORISED|2|cfo' THEN RAISE EXCEPTION 'CELL C2 %', v_msg; END IF;
    v_msg := v_msg || ' · ' || pg_temp.try_as('chooer@evoltrya.test', format('SELECT decide_warehouse_request(%L, true)', q));
    IF v_msg NOT LIKE '%APPROVAL_NOT_AUTHORISED|2|cfo' THEN RAISE EXCEPTION 'CELL C3 %', v_msg; END IF;
    v_msg := v_msg || ' · ' || pg_temp.try_as('tim@evoltrya.test', format('SELECT decide_warehouse_request(%L, false, %L)', q, '  '));
    IF v_msg NOT LIKE '%WAREHOUSE_REQUEST_REJECT_REASON_REQUIRED|IN-2026-0179 · write-off #1' THEN RAISE EXCEPTION 'CELL C4 %', v_msg; END IF;
    RAISE NOTICE 'CELL C | fusheng@ · sandra@ · chooer@ · tim@(reject, blank) | %', v_msg;

    -- ══ D · CFO 批准:注销生效 ══
    v_res := pg_temp.call_as('tim@evoltrya.test', format('SELECT decide_warehouse_request(%L, true)', q));
    IF v_res->>'status' <> 'approved'
       OR (SELECT deleted_by FROM inbound_batches WHERE id = b179) <> v_fu
       OR (SELECT delete_reason FROM inbound_batches WHERE id = b179) <> 'APR-7 live proof · water damage'
       OR NOT EXISTS (SELECT 1 FROM inventory_movements WHERE inbound_batch_id = b179 AND movement_type = 'writeoff'
                       AND qty_delta = -300 AND business_date = d)
       OR (SELECT count(*) FROM journal_entries) <> v_je0 THEN RAISE EXCEPTION 'CELL D1 %', v_res; END IF;
    RAISE NOTICE 'CELL D1 | tim@ | approve | IN-2026-0179 deleted, deleted_by fusheng@, reason as raised · writeoff -300 on % · no journal entry (unpriced) · JE %',
        d, v_je0;
    RAISE NOTICE 'CELL D2 | postgres | approval_log | %',
        (SELECT string_agg(decision || ' L' || COALESCE(level::text, '-') || ' ' || COALESCE(u.email, '?') || ' self=' || COALESCE(self_decided::text, '-'), ' → ' ORDER BY seq)
           FROM approval_log al LEFT JOIN auth.users u ON u.id = al.actor_user_id
          WHERE al.subject_type = 'warehouse_request' AND al.subject_id = q);

    -- ══ E · 有价值的注销:OUT-2026-0187 ══
    v_res := pg_temp.call_as('fusheng@evoltrya.test', format('SELECT submit_output_write_off_request(%L, %L)', o187, 'APR-7 live proof · contaminated'));
    q := (v_res->>'request_id')::uuid;
    IF (v_res->>'amount_base')::numeric <> 134.86 THEN RAISE EXCEPTION 'CELL E1 %', v_res; END IF;
    RAISE NOTICE 'CELL E1 | fusheng@ | submit write-off OUT-2026-0187 | % · dry-run amount %', v_res->>'label', v_res->>'amount_base';
    PERFORM pg_temp.call_as('tim@evoltrya.test', format('SELECT decide_warehouse_request(%L, true)', q));
    IF (SELECT count(*) FROM journal_entries) <> v_je0 + 1 OR pg_temp.bal('1220') <> b1220 - 134.86
       OR pg_temp.bal('5200') <> b5200 + 134.86 THEN RAISE EXCEPTION 'CELL E2'; END IF;
    RAISE NOTICE 'CELL E2 | tim@ | approve | % posted (writeoff) · 1220 % → % · 5200 % → % · deleted_by %',
        (SELECT code FROM journal_entries WHERE id = (SELECT result_entry_ids[1] FROM warehouse_requests WHERE id = q)),
        b1220, pg_temp.bal('1220'), b5200, pg_temp.bal('5200'),
        (SELECT u.email FROM output_batches ob JOIN auth.users u ON u.id = ob.deleted_by WHERE ob.id = o187);

    -- ══ F0 · 线上 10 张在册的加工单【一张都没有工序】(PROC-SUPPORT-1 的测试残留,NOT VALID 的 CHECK 只管新行)——
    --   回滚要改那一行,于是 CHECK 对它生效:提交时的试跑按约束原话拒,一行不落。这不是 APR-7 造成的 ——
    --   旧的一步回滚撞的是同一条约束。登记 APR7-LEGACY-RUNS-CANNOT-ROLL-BACK。
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT submit_rollback_request(%L, %L)', r225, 'as live stands'));
    IF v_msg NOT LIKE '%processing_runs_operation_type_required%' OR EXISTS (SELECT 1 FROM warehouse_requests WHERE run_id = r225) THEN
        RAISE EXCEPTION 'CELL F0 %', v_msg; END IF;
    RAISE NOTICE 'CELL F0 | fusheng@ | submit rollback PROC-2026-0225 as live stands (no operation type) | %', v_msg;
    -- ★ 只为这一次证明、随整笔回滚:给 PROC-2026-0225 与 PROC-2026-0009 填上工序,好让回滚那条路走得到底。
    --   线上从不留下这两个值(见 processing_runs_operation_type_required 的注释:猜出来的工序与真的长得一样)。
    UPDATE processing_runs SET operation_type_code = 'manual_disassembly' WHERE id IN (r225, r009);
    RAISE NOTICE 'CELL F0b | postgres | proof-only, rolled back: operation_type_code set on PROC-2026-0225 and PROC-2026-0009';

    -- ══ F · 回滚:PROC-2026-0225 ══
    v_res := pg_temp.call_as('fusheng@evoltrya.test', format('SELECT submit_rollback_request(%L, %L)', r225, 'APR-7 live proof · wrong input'));
    q := (v_res->>'request_id')::uuid;
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format(
        'INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date) VALUES (%L, %L, -1, %L)',
        o380, 'adjustment', d));
    IF v_msg NOT LIKE 'WAREHOUSE_REQUEST_FREEZES_BATCH|OUT-2026-0380|PROC-2026-0225 · rollback #1' THEN RAISE EXCEPTION 'CELL F1 %', v_msg; END IF;
    RAISE NOTICE 'CELL F1 | fusheng@ | submit rollback % · a movement on its output OUT-2026-0380 | %', v_res->>'label', v_msg;
    PERFORM pg_temp.call_as('tim@evoltrya.test', format('SELECT decide_warehouse_request(%L, true)', q));
    IF (SELECT status FROM processing_runs WHERE id = r225) <> 'reversed'
       OR (SELECT deleted_by FROM processing_runs WHERE id = r225) <> v_fu
       OR (SELECT count(*) FROM output_batches WHERE id IN (SELECT output_batch_id FROM processing_outputs WHERE run_id = r225)
            AND deleted_at IS NULL) <> 0 THEN RAISE EXCEPTION 'CELL F2'; END IF;
    RAISE NOTICE 'CELL F2 | tim@ | approve | PROC-2026-0225 reversed, deleted_by fusheng@ · outputs voided · IN-2026-0180 remaining %',
        (SELECT remaining_qty FROM inbound_batches WHERE code = 'IN-2026-0180');

    -- ══ G · 回滚一张已锁期间里的单:CFO 批之前看得见的那两句(提,再撤回)══
    v_res := pg_temp.call_as('fusheng@evoltrya.test', format('SELECT submit_rollback_request(%L, %L)', r009, 'APR-7 live proof · locked period'));
    qx := (v_res->>'request_id')::uuid;
    IF (SELECT snapshot->>'locked_period' FROM warehouse_requests WHERE id = qx) <> 'true'
       OR (SELECT snapshot->'cods_voided' FROM warehouse_requests WHERE id = qx) <> '["COD-2026-0002"]'::jsonb THEN
        RAISE EXCEPTION 'CELL G1 %', (SELECT snapshot FROM warehouse_requests WHERE id = qx); END IF;
    RAISE NOTICE 'CELL G1 | fusheng@ | submit rollback PROC-2026-0009 | snapshot locked_period % (before %) · cods_voided %',
        (SELECT snapshot->>'locked_period' FROM warehouse_requests WHERE id = qx),
        (SELECT snapshot->>'locked_before' FROM warehouse_requests WHERE id = qx),
        (SELECT snapshot->'cods_voided' FROM warehouse_requests WHERE id = qx);
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT withdraw_warehouse_request(%L)', qx));
    IF v_msg <> 'PERMISSION_DENIED|action.processing_rollback' THEN RAISE EXCEPTION 'CELL G2 %', v_msg; END IF;
    PERFORM pg_temp.call_as('fusheng@evoltrya.test', format('SELECT withdraw_warehouse_request(%L, %L)', qx, 'APR-7 proof'));
    IF (SELECT status FROM warehouse_requests WHERE id = qx) <> 'withdrawn'
       OR (SELECT status FROM certificates_of_destruction WHERE code = 'COD-2026-0002') <> 'issued' THEN RAISE EXCEPTION 'CELL G3'; END IF;
    RAISE NOTICE 'CELL G2 | chooer@ withdraw → % · fusheng@ withdraw → withdrawn · COD-2026-0002 still issued', v_msg;

    -- ══ H · 证书作废:COD-2026-0001 ══
    v_res := pg_temp.call_as('fusheng@evoltrya.test', format('SELECT submit_cod_void_request(%L, %L)', c001, 'APR-7 live proof · wrong supplier name'));
    q := (v_res->>'request_id')::uuid;
    RAISE NOTICE 'CELL H1 | fusheng@ | submit void % · public verification while waiting: %',
        v_res->>'label', (cod_verification(c001_tok::text))->>'status';
    IF (cod_verification(c001_tok::text))->>'status' <> 'issued' THEN RAISE EXCEPTION 'CELL H1'; END IF;
    PERFORM pg_temp.call_as('tim@evoltrya.test', format('SELECT decide_warehouse_request(%L, true)', q));
    IF (SELECT status FROM certificates_of_destruction WHERE id = c001) <> 'void'
       OR (SELECT voided_by FROM certificates_of_destruction WHERE id = c001) <> v_fu
       OR (SELECT replaced_by_cod_id FROM certificates_of_destruction WHERE id = c001) IS NOT NULL
       OR (cod_verification(c001_tok::text))->>'status' <> 'void' THEN RAISE EXCEPTION 'CELL H2'; END IF;
    RAISE NOTICE 'CELL H2 | tim@ | approve | COD-2026-0001 void, voided_by fusheng@, no replacement · public verification: % (replaced_by_code %)',
        (cod_verification(c001_tok::text))->>'status', COALESCE((cod_verification(c001_tok::text))->'void'->>'replaced_by_code', 'null');

    -- ══ I · 驳回(IN-2026-0321,没计价、800 kg)══
    qx := (pg_temp.call_as('fusheng@evoltrya.test', format('SELECT submit_inbound_write_off_request((SELECT id FROM inbound_batches WHERE code = %L), %L)',
        'IN-2026-0321', 'APR-7 live proof · to reject'))->>'request_id')::uuid;
    PERFORM pg_temp.call_as('tim@evoltrya.test', format('SELECT decide_warehouse_request(%L, false, %L)', qx, 'APR-7 proof: the stock is fine'));
    IF (SELECT status FROM warehouse_requests WHERE id = qx) <> 'rejected'
       OR (SELECT deleted_at FROM inbound_batches WHERE code = 'IN-2026-0321') IS NOT NULL THEN RAISE EXCEPTION 'CELL I1'; END IF;
    RAISE NOTICE 'CELL I1 | tim@ | reject with a reason | rejected · IN-2026-0321 untouched (remaining %)',
        (SELECT remaining_qty FROM inbound_batches WHERE code = 'IN-2026-0321');

    -- ══ J · 收尾:没有一张在等 ══
    IF EXISTS (SELECT 1 FROM warehouse_requests WHERE status = 'submitted') THEN RAISE EXCEPTION 'CELL J1 something left waiting'; END IF;
    RAISE NOTICE 'CELL J1 | postgres | warehouse_requests waiting: 0 · by status: % · pending documents: %',
        (SELECT string_agg(status || ' ' || n, ', ' ORDER BY status) FROM (SELECT status, count(*) n FROM warehouse_requests GROUP BY 1) x),
        (SELECT string_agg(subject_type || ' ' || n, ', ') FROM (SELECT subject_type, count(*) n FROM approval_pending_documents() GROUP BY 1) x);
    RAISE NOTICE 'CELL J2 | postgres | after | JE % · 1200 % · 1220 % · 5200 %', (SELECT count(*) FROM journal_entries),
        pg_temp.bal('1200'), pg_temp.bal('1220'), pg_temp.bal('5200');
END;
$proof$;

SELECT side, list, ledger, unexplained FROM pg_temp.recon();
ROLLBACK;
