-- db/scripts/2026-09-26-apr8-live-proof.sql
-- APR-8 · 线上走证(grilling Q10):每一种申请走一遍完整的生命周期,拒绝与读回,【整支一笔事务,最后 ROLLBACK】。
-- 不在 db/fixtures/ 里,因为它读的是【线上的真账号与真公式】(sandra@ = cco · tim@ = cfo · admin@ = Tim 的另一个账号 ·
-- chooer@ = finance · PF-2026-0001),而门在一个空的重建库上跑 fixture —— 那一半由 fixture 227 自带数据钉住。
--
-- 身份:以 postgres 连接(rolbypassrls = t);每一步以那个人的 JWT、SET LOCAL ROLE authenticated 调门;
--   属主路径的那两步(fingerprint 注入、读公式条款的 pricing_terms_of_formula)明写"以 postgres"。
-- 判词:每一臂不对就 RAISE —— 退出码就是判词;全过打一行 NOTICE,然后 ROLLBACK(什么都不留下)。
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL statement_timeout = '120s';

CREATE FUNCTION pg_temp.as_user(p_email text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v uuid;
BEGIN
    SELECT id INTO v FROM auth.users WHERE email = p_email;
    IF v IS NULL THEN RAISE EXCEPTION 'PROOF_SETUP|no account %', p_email; END IF;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
END $f$;

-- 以某人身份跑一句;成功 'OK',否则拒绝原文
CREATE FUNCTION pg_temp.try_as(p_email text, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM pg_temp.as_user(p_email);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN SQLERRM;
END $f$;

-- 以某人身份调一扇返回 jsonb 的门
CREATE FUNCTION pg_temp.call_as(p_email text, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.as_user(p_email);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
END $f$;

DO $$
DECLARE
    v_pf uuid; v_pf_code text; v_sup uuid; v_new uuid; v_c uuid; v_c_code text;
    v_res jsonb; q uuid; v_msg text; v_log0 int; v_je0 int; v_t jsonb; v_snap jsonb;
    rep text := '';
BEGIN
    SELECT count(*) INTO v_log0 FROM approval_log;
    SELECT count(*) INTO v_je0 FROM journal_entries;
    SELECT id, code INTO v_pf, v_pf_code FROM pricing_formulas WHERE code = 'PF-2026-0001';
    SELECT id INTO v_sup FROM suppliers WHERE deleted_at IS NULL ORDER BY (status = 'approved') DESC, code LIMIT 1;
    IF v_pf IS NULL OR v_sup IS NULL THEN RAISE EXCEPTION 'PROOF_SETUP|PF-2026-0001 or a live supplier missing'; END IF;
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'PROOF_SETUP|approvals are off'; END IF;

    -- ── R · 拒绝 ──────────────────────────────────────────────────────────
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format('UPDATE pricing_formulas SET notes = %L WHERE id = %L', 'x', v_pf));
    IF v_msg <> 'PRICING_FORMULA_THROUGH_REQUEST_ONLY' THEN RAISE EXCEPTION 'R1 cco direct formula update: %', v_msg; END IF;
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('UPDATE pricing_formulas SET notes = %L WHERE id = %L', 'x', v_pf));
    IF v_msg <> 'PERMISSION_DENIED|module.pricing.edit' THEN RAISE EXCEPTION 'R2 finance direct formula update: %', v_msg; END IF;
    v_msg := pg_temp.try_as('chooer@evoltrya.test', $s$SELECT submit_formula_create_request('{"name":"x"}'::jsonb, 'x')$s$);
    IF v_msg <> 'PERMISSION_DENIED|module.pricing.edit' THEN RAISE EXCEPTION 'R3 finance submits a formula: %', v_msg; END IF;
    v_msg := pg_temp.try_as('admin@swm-os.test', $s$SELECT submit_formula_create_request('{"name":"apr8 proof by admin@"}'::jsonb, 'x')$s$);
    IF v_msg NOT LIKE 'TERMS_REQUEST_NO_OTHER_DECIDER|%' THEN RAISE EXCEPTION 'R4 admin@ (Tim) submits: %', v_msg; END IF;
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format(
        $s$INSERT INTO contracts (supplier_id, kind, title, effective_from, status) VALUES (%L, 'supply', 'apr8 proof', CURRENT_DATE, 'active')$s$, v_sup));
    IF v_msg NOT LIKE 'CONTRACT_ACTIVATES_THROUGH_REQUEST|%' THEN RAISE EXCEPTION 'R5 cco inserts an active contract: %', v_msg; END IF;
    rep := rep || 'R refusals ok; ';

    -- ── F1 · formula_create:Sandra 提 → 停用、在等 → Tim 批 → 启用 ─────────────
    v_res := pg_temp.call_as('sandra@evoltrya.test', format($s$SELECT submit_formula_create_request(%L::jsonb, 'apr8 proof F1')$s$,
        jsonb_build_object('name', 'apr8 proof new', 'direction', 'purchase', 'supplier_id', v_sup,
                           'metals', jsonb_build_array(jsonb_build_object('metal', 'ni', 'payable_pct', 70)))::text));
    v_new := (v_res->>'formula_id')::uuid; q := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'submitted' OR (SELECT is_active FROM pricing_formulas WHERE id = v_new) THEN
        RAISE EXCEPTION 'F1a create should wait inactive: %', v_res; END IF;
    v_msg := NULL;
    BEGIN PERFORM pricing_terms_of_formula(v_new); EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;   -- 以 postgres
    IF v_msg NOT LIKE 'FORMULA_INACTIVE|%' THEN RAISE EXCEPTION 'F1b reader before approval: %', v_msg; END IF;
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format('SELECT decide_terms_request(%L, true)', q));
    IF v_msg <> 'SELF_APPROVAL_FORBIDDEN|raiser' THEN RAISE EXCEPTION 'F1c raiser approves own: %', v_msg; END IF;
    v_msg := NULL;
    BEGIN
        PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
        UPDATE finance_settings SET approvals_enabled = false;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg NOT LIKE 'APPROVALS_CANNOT_DISABLE_WITH_PENDING|%' THEN RAISE EXCEPTION 'F1d disable gate: %', v_msg; END IF;
    PERFORM pg_temp.call_as('tim@evoltrya.test', format('SELECT decide_terms_request(%L, true, NULL)', q));
    IF NOT (SELECT is_active FROM pricing_formulas WHERE id = v_new)
       OR (pricing_terms_of_formula(v_new)->'payables'->>'ni')::numeric <> 70
       OR NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'terms_request' AND subject_id = q AND decision = 'approved') THEN
        RAISE EXCEPTION 'F1e approval should activate'; END IF;
    rep := rep || 'F1 create ok; ';

    -- ── F2 · formula_change on PF-2026-0001:等待中读旧条款,批准后读新条款 ─────────
    v_t := formula_terms_state(v_pf) || jsonb_build_object('flat_discount_pct', 2.5);
    v_res := pg_temp.call_as('sandra@evoltrya.test', format($s$SELECT submit_formula_change_request(%L, %L::jsonb, 'apr8 proof F2')$s$, v_pf, v_t::text));
    q := (v_res->>'request_id')::uuid;
    SELECT snapshot INTO v_snap FROM terms_requests WHERE id = q;
    IF (pricing_terms_of_formula(v_pf)->>'flat_discount_pct')::numeric = 2.5
       OR (v_snap->'proposed'->>'flat_discount_pct')::numeric <> 2.5
       OR (v_snap->'usage'->>'po_lines_committed')::int <> 1 THEN
        RAISE EXCEPTION 'F2a waiting change must not be in effect; snapshot %', v_snap; END IF;
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format('SELECT deactivate_pricing_formula(%L)', v_pf));
    IF v_msg NOT LIKE 'TERMS_REQUEST_OPEN|%' THEN RAISE EXCEPTION 'F2b deactivate while waiting: %', v_msg; END IF;
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format($s$SELECT submit_formula_change_request(%L, %L::jsonb, 'again')$s$, v_pf, v_t::text));
    IF v_msg NOT LIKE 'TERMS_REQUEST_OPEN|%' THEN RAISE EXCEPTION 'F2c second request: %', v_msg; END IF;
    PERFORM pg_temp.call_as('tim@evoltrya.test', format('SELECT decide_terms_request(%L, true, NULL)', q));
    IF (pricing_terms_of_formula(v_pf)->>'flat_discount_pct')::numeric <> 2.5 THEN
        RAISE EXCEPTION 'F2d approved change should be in effect'; END IF;
    IF (SELECT flat_discount_pct FROM pricing_term_commitments WHERE source_formula_id = v_pf) = 2.5 THEN
        RAISE EXCEPTION 'F2e the existing commitment must keep its own copy'; END IF;
    rep := rep || 'F2 change ok (commitment untouched); ';

    -- ── F3 · fingerprint:等待中属主路径改了公式 → 批不了;撤回 ───────────────────
    v_res := pg_temp.call_as('sandra@evoltrya.test', format($s$SELECT submit_formula_change_request(%L, %L::jsonb, 'apr8 proof F3')$s$,
        v_pf, (formula_terms_state(v_pf) || jsonb_build_object('flat_discount_pct', 3))::text));
    q := (v_res->>'request_id')::uuid;
    UPDATE pricing_formulas SET notes = COALESCE(notes, '') || ' (owner path)' WHERE id = v_pf;   -- 以 postgres
    v_msg := pg_temp.try_as('tim@evoltrya.test', format('SELECT decide_terms_request(%L, true)', q));
    IF v_msg NOT LIKE 'TERMS_CHANGED_SINCE_REQUEST|%' THEN RAISE EXCEPTION 'F3a fingerprint: %', v_msg; END IF;
    PERFORM pg_temp.call_as('sandra@evoltrya.test', format('SELECT withdraw_terms_request(%L, %L)', q, 'apr8 proof'));
    IF (SELECT status FROM terms_requests WHERE id = q) <> 'withdrawn' THEN RAISE EXCEPTION 'F3b withdraw'; END IF;
    rep := rep || 'F3 fingerprint + withdraw ok; ';

    -- ── F4 · formula_reactivate:停用一步 → 申请 → 驳回(要理由)→ 再申请 → 批 ────────
    PERFORM pg_temp.call_as('sandra@evoltrya.test', format('SELECT deactivate_pricing_formula(%L)', v_new));
    v_res := pg_temp.call_as('sandra@evoltrya.test', format($s$SELECT submit_formula_reactivate_request(%L, NULL, 'apr8 proof F4')$s$, v_new));
    q := (v_res->>'request_id')::uuid;
    v_msg := pg_temp.try_as('tim@evoltrya.test', format('SELECT decide_terms_request(%L, false, %L)', q, ' '));
    IF v_msg NOT LIKE 'TERMS_REQUEST_REJECT_REASON_REQUIRED|%' THEN RAISE EXCEPTION 'F4a reject without reason: %', v_msg; END IF;
    PERFORM pg_temp.call_as('tim@evoltrya.test', format('SELECT decide_terms_request(%L, false, %L)', q, 'apr8 proof: not yet'));
    IF (SELECT is_active FROM pricing_formulas WHERE id = v_new) THEN RAISE EXCEPTION 'F4b rejected stays inactive'; END IF;
    v_res := pg_temp.call_as('sandra@evoltrya.test', format($s$SELECT submit_formula_reactivate_request(%L, NULL, 'apr8 proof F4 again')$s$, v_new));
    PERFORM pg_temp.call_as('tim@evoltrya.test', format('SELECT decide_terms_request(%L, true, NULL)', v_res->>'request_id'));
    IF NOT (SELECT is_active FROM pricing_formulas WHERE id = v_new) THEN RAISE EXCEPTION 'F4c reactivated'; END IF;
    rep := rep || 'F4 reactivate (reject, then approve) ok; ';

    -- ── C · contract_activate:草稿 → 生效 → 冻结 → 暂停 → 改 → 再生效(差别)──────────
    PERFORM pg_temp.as_user('sandra@evoltrya.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO contracts (supplier_id, kind, title, effective_from, status)
    VALUES (v_sup, 'supply', 'apr8 proof contract', CURRENT_DATE, 'draft') RETURNING id, code INTO v_c, v_c_code;
    INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct)
    VALUES (v_c, 'ni', 'shipment', 1, 'LME', 90);
    EXECUTE 'RESET ROLE';
    v_res := pg_temp.call_as('sandra@evoltrya.test', format($s$SELECT submit_contract_activation_request(%L, 'apr8 proof C')$s$, v_c));
    q := (v_res->>'request_id')::uuid;
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format('UPDATE contract_pricing_terms SET payable_pct = 91 WHERE contract_id = %L', v_c));
    IF v_msg NOT LIKE 'CONTRACT_TERMS_FROZEN|%' THEN RAISE EXCEPTION 'C1 terms frozen while waiting: %', v_msg; END IF;
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format($s$UPDATE contracts SET notes = 'x' WHERE id = %L$s$, v_c));
    IF v_msg NOT LIKE 'TERMS_REQUEST_FREEZES_CONTRACT|%' THEN RAISE EXCEPTION 'C2 header frozen while waiting: %', v_msg; END IF;
    PERFORM pg_temp.call_as('tim@evoltrya.test', format('SELECT decide_terms_request(%L, true, NULL)', q));
    IF (SELECT status FROM contracts WHERE id = v_c) <> 'active' THEN RAISE EXCEPTION 'C3 approved contract active'; END IF;
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format($s$UPDATE contracts SET notes = 'x' WHERE id = %L$s$, v_c));
    IF v_msg NOT LIKE 'CONTRACT_ACTIVE_IS_FROZEN|%' THEN RAISE EXCEPTION 'C4 active header frozen: %', v_msg; END IF;
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format($s$UPDATE contracts SET status = 'suspended' WHERE id = %L$s$, v_c));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'C5 suspend one step: %', v_msg; END IF;
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format('UPDATE contract_pricing_terms SET payable_pct = 92 WHERE contract_id = %L', v_c));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'C6 edit while suspended: %', v_msg; END IF;
    v_res := pg_temp.call_as('sandra@evoltrya.test', format($s$SELECT submit_contract_activation_request(%L, 'apr8 proof C again')$s$, v_c));
    q := (v_res->>'request_id')::uuid;
    SELECT snapshot INTO v_snap FROM terms_requests WHERE id = q;
    IF (v_snap->'last_approved'->'pricing_terms'->0->>'payable_pct')::numeric <> 90
       OR (v_snap->'current'->'pricing_terms'->0->>'payable_pct')::numeric <> 92 THEN
        RAISE EXCEPTION 'C7 the CFO sees last approved (90) against now (92): %', v_snap; END IF;
    PERFORM pg_temp.call_as('tim@evoltrya.test', format('SELECT decide_terms_request(%L, true, NULL)', q));
    IF (SELECT status FROM contracts WHERE id = v_c) <> 'active' THEN RAISE EXCEPTION 'C8 re-activated'; END IF;
    rep := rep || 'C contract lifecycle ok; ';

    -- ── K · 读回 ─────────────────────────────────────────────────────────────
    IF (SELECT count(*) FROM journal_entries) <> v_je0 THEN RAISE EXCEPTION 'K1 no journal entry may be posted'; END IF;
    IF EXISTS (SELECT 1 FROM terms_requests WHERE status = 'submitted') THEN RAISE EXCEPTION 'K2 nothing left pending'; END IF;
    RAISE NOTICE 'APR8 LIVE PROOF PASSED: % approval_log +% rows inside the rolled-back transaction', rep,
        (SELECT count(*) FROM approval_log) - v_log0;
END $$;

ROLLBACK;
