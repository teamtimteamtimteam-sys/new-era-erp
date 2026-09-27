-- db/scripts/2026-09-27-terms-edit1-live-proof.sql
-- TERMS-EDIT-1 · 线上证明(grilling Q10,Tim 2026-09-27)。整支一笔事务,最后 ROLLBACK —— 线上什么都不留下。
-- 以 postgres 连接,每一步切到一个【真账号】的 JWT 再 SET LOCAL ROLE authenticated(RLS 与守卫都以那个人的身份判);
-- 读 auth.users 取 id,不写死。每一格断言失败即 RAISE,psql 以非零退出 —— 判词是退出码,不是屏幕上的一段字。
--
--   P1  sandra@(cco)建一份【卖方】草稿,改表头
--   P2  条款不齐就申请生效 → CONTRACT_TERMS_INCOMPLETE|编号|settlement_terms,pricing_terms,一张申请都不落
--   P3  sandra@ 七种条款各录一行(per_metal · per_element 的口径,对应的精炼费与惩罚都填上);清单变空
--   P4  chooer@(finance)与 tim@(cfo)直连写条款 → 被拒(不持 action.contract_terms),一行不落
--   P5  sandra@ 申请生效 → submitted;等待中改条款 → CONTRACT_TERMS_FROZEN|编号|label,改表头 → TERMS_REQUEST_FREEZES_CONTRACT
--   P6  tim@ 读得到这张申请与它冻结的七段条款;批准 → active
--   P7  生效中改条款 → CONTRACT_TERMS_FROZEN|编号|active;改表头 → CONTRACT_ACTIVE_IS_FROZEN
--   P8  暂停(一步)→ payable 90 → 92 → 再申请 → tim@ 看见 last_approved 90 与 current 92 → 批准
--   P9  终止 → 改条款 → CONTRACT_TERMS_FROZEN|编号|terminated(Q4)
--   P10 买方草稿:什么条款都没有也申请得了(清单为空),撤回
--   P11 admin@ 提 → TERMS_REQUEST_NO_OTHER_DECIDER(APR-8 不变)
--   P12 fusheng@(warehouse)读不到卖方合同(RLS),读得到买方的;清单对他为空
--   K   收尾:分录一行没动;没有一张在等
\set ON_ERROR_STOP on
\pset footer off
BEGIN;
SET LOCAL statement_timeout = '120s';

CREATE FUNCTION pg_temp.te1_as(p_email text) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v uuid;
BEGIN
    SELECT id INTO v FROM auth.users WHERE email = p_email;
    IF v IS NULL THEN RAISE EXCEPTION 'PROOF_SETUP|no account %', p_email; END IF;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
    RETURN v;
END $f$;

CREATE FUNCTION pg_temp.te1_try(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN SQLERRM;
END $f$;

CREATE FUNCTION pg_temp.te1_val(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v text;
BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
END $f$;

SELECT current_user AS identity, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user) AS bypassrls, now() AS proof_at;

DO $proof$
DECLARE
    v_cust uuid; v_sup uuid;
    c_sell uuid; c_code text; c_buy uuid;
    v_res jsonb; q uuid; q_label text; v_msg text; v_snap jsonb;
    j_before int; jl_before int; log_before int; v_ccy text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;   -- 币种从数据取,不写死(check-currency-literals)
    SELECT count(*) INTO j_before FROM journal_entries;
    SELECT count(*) INTO jl_before FROM journal_lines;
    SELECT count(*) INTO log_before FROM approval_log;
    SELECT id INTO v_cust FROM customers WHERE deleted_at IS NULL ORDER BY created_at LIMIT 1;
    SELECT id INTO v_sup FROM suppliers WHERE deleted_at IS NULL AND status = 'approved' ORDER BY created_at LIMIT 1;
    IF v_cust IS NULL OR v_sup IS NULL THEN RAISE EXCEPTION 'PROOF_SETUP|need one customer and one approved supplier'; END IF;
    IF NOT approvals_enabled() THEN RAISE EXCEPTION 'PROOF_SETUP|approvals are expected ON'; END IF;

    -- ── P1 ──────────────────────────────────────────────────────────────
    PERFORM pg_temp.te1_as('sandra@evoltrya.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO contracts (customer_id, kind, title, effective_from, status)
    VALUES (v_cust, 'offtake', 'TE1 proof sell', CURRENT_DATE, 'draft') RETURNING id, code INTO c_sell, c_code;
    UPDATE contracts SET incoterm = 'CIF', currency = v_ccy, payment_terms_days = 30 WHERE id = c_sell;
    EXECUTE 'RESET ROLE';
    RAISE NOTICE 'P1 sandra@ drafted % (sell) and edited its header: %', c_code,
        (SELECT incoterm || ' · ' || currency || ' · ' || payment_terms_days FROM contracts WHERE id = c_sell);

    -- ── P2 ──────────────────────────────────────────────────────────────
    v_msg := pg_temp.te1_try(format($s$SELECT submit_contract_activation_request(%L, 'TE1 P2')$s$, c_sell));
    IF v_msg <> 'CONTRACT_TERMS_INCOMPLETE|' || c_code || '|settlement_terms,pricing_terms'
       OR EXISTS (SELECT 1 FROM terms_requests WHERE contract_id = c_sell) THEN
        RAISE EXCEPTION 'PROOF P2|expected CONTRACT_TERMS_INCOMPLETE and no request, got %', v_msg; END IF;
    RAISE NOTICE 'P2 incomplete request refused: %', v_msg;

    -- ── P3 ──────────────────────────────────────────────────────────────
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO contract_grade_specs (contract_id, metal, min_pct, max_pct) VALUES (c_sell, 'ni', 18, 25);
    INSERT INTO contract_insurance_obligations (contract_id, insured_by, cover_type, min_amount, currency)
    VALUES (c_sell, 'counterparty', 'cargo', 500000, v_ccy);
    INSERT INTO contract_volume_commitments (contract_id, committed_by_party, quantity, unit, period, direction)
    VALUES (c_sell, 'us', 200, 't', 'month', 'min');
    INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct)
    VALUES (c_sell, 'ni', 'shipment', 1, 'LME', 90);
    INSERT INTO contract_settlement_terms (contract_id, sale_weight_basis, settling_party, splitting_limit_pct,
        sample_retention_required, sample_retention_days, refining_charge_basis, penalty_basis)
    VALUES (c_sell, 'dry', 'ours', 0.5, true, 90, 'per_metal', 'per_element');
    INSERT INTO contract_refining_charges (contract_id, metal, usd_per_tonne_of_metal) VALUES (c_sell, 'ni', 1500);
    INSERT INTO contract_penalty_elements (contract_id, substance, threshold_pct, usd_per_tonne_per_pct_over)
    VALUES (c_sell, 'cu', 0.5, 3);
    EXECUTE 'RESET ROLE';
    v_msg := pg_temp.te1_val(format($s$SELECT array_to_string(contract_activation_missing(%L), ',')$s$, c_sell));
    IF v_msg <> '' THEN RAISE EXCEPTION 'PROOF P3|checklist should be empty, got %', v_msg; END IF;
    RAISE NOTICE 'P3 sandra@ filed one row of each of the seven kinds; checklist (as sandra@) now empty';

    -- ── P4 ──────────────────────────────────────────────────────────────
    PERFORM pg_temp.te1_as('chooer@evoltrya.test');
    v_msg := pg_temp.te1_try(format($s$INSERT INTO contract_penalty_elements (contract_id, substance, threshold_pct, usd_per_tonne_per_pct_over) VALUES (%L, 'fe', 1, 1)$s$, c_sell));
    IF v_msg = 'OK' THEN RAISE EXCEPTION 'PROOF P4|chooer@ inserted a term'; END IF;
    RAISE NOTICE 'P4a chooer@ (finance) direct insert refused: %', v_msg;
    v_msg := pg_temp.te1_try(format($s$UPDATE contract_pricing_terms SET payable_pct = 50 WHERE contract_id = %L$s$, c_sell));
    IF v_msg <> 'PERMISSION_DENIED|action.contract_terms' THEN RAISE EXCEPTION 'PROOF P4|chooer@ update: %', v_msg; END IF;
    RAISE NOTICE 'P4b chooer@ (finance) direct update refused: %', v_msg;
    PERFORM pg_temp.te1_as('tim@evoltrya.test');
    v_msg := pg_temp.te1_try(format($s$UPDATE contract_pricing_terms SET payable_pct = 50 WHERE contract_id = %L$s$, c_sell));
    IF v_msg <> 'PERMISSION_DENIED|action.contract_terms' THEN RAISE EXCEPTION 'PROOF P4|tim@ update: %', v_msg; END IF;
    IF (SELECT count(*) FROM contract_penalty_elements WHERE contract_id = c_sell) <> 1
       OR (SELECT payable_pct FROM contract_pricing_terms WHERE contract_id = c_sell) <> 90 THEN
        RAISE EXCEPTION 'PROOF P4|a refused write landed'; END IF;
    RAISE NOTICE 'P4c tim@ (cfo) direct update refused: %; rows unchanged', v_msg;

    -- ── P5 ──────────────────────────────────────────────────────────────
    PERFORM pg_temp.te1_as('sandra@evoltrya.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := submit_contract_activation_request(c_sell, 'TE1 proof: offtake agreed');
    EXECUTE 'RESET ROLE';
    q := (v_res->>'request_id')::uuid; q_label := v_res->>'label';
    IF v_res->>'status' <> 'submitted' THEN RAISE EXCEPTION 'PROOF P5|expected submitted, got %', v_res; END IF;
    v_msg := pg_temp.te1_try(format($s$UPDATE contract_pricing_terms SET payable_pct = 91 WHERE contract_id = %L$s$, c_sell));
    IF v_msg <> 'CONTRACT_TERMS_FROZEN|' || c_code || '|' || q_label THEN RAISE EXCEPTION 'PROOF P5|term edit while waiting: %', v_msg; END IF;
    RAISE NOTICE 'P5a sandra@ requested activation (%); term edit while waiting refused: %', q_label, v_msg;
    v_msg := pg_temp.te1_try(format($s$UPDATE contracts SET notes = 'x' WHERE id = %L$s$, c_sell));
    IF v_msg NOT LIKE 'TERMS_REQUEST_FREEZES_CONTRACT|' || c_code || '|%' THEN RAISE EXCEPTION 'PROOF P5|header edit while waiting: %', v_msg; END IF;
    RAISE NOTICE 'P5b header edit while waiting refused: %', v_msg;

    -- ── P6 ──────────────────────────────────────────────────────────────
    PERFORM pg_temp.te1_as('tim@evoltrya.test');
    v_snap := pg_temp.te1_val(format($s$SELECT snapshot::text FROM terms_requests_visible(50) v WHERE v.id = %L$s$, q))::jsonb;
    IF v_snap IS NULL
       OR jsonb_array_length(v_snap->'current'->'grade_specs') <> 1 OR jsonb_array_length(v_snap->'current'->'insurance_obligations') <> 1
       OR jsonb_array_length(v_snap->'current'->'volume_commitments') <> 1 OR jsonb_array_length(v_snap->'current'->'pricing_terms') <> 1
       OR jsonb_array_length(v_snap->'current'->'settlement_terms') <> 1 OR jsonb_array_length(v_snap->'current'->'refining_charges') <> 1
       OR jsonb_array_length(v_snap->'current'->'penalty_elements') <> 1 OR v_snap->'last_approved' <> 'null'::jsonb THEN
        RAISE EXCEPTION 'PROOF P6|tim@ should read all seven sections and no last_approved, got %', v_snap; END IF;
    RAISE NOTICE 'P6a tim@ reads % with all seven sections frozen (1 row each), last_approved null', q_label;
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM decide_terms_request(q, true, NULL);
    EXECUTE 'RESET ROLE';
    IF (SELECT status FROM contracts WHERE id = c_sell) <> 'active' THEN RAISE EXCEPTION 'PROOF P6|not active'; END IF;
    RAISE NOTICE 'P6b tim@ approved → % active', c_code;

    -- ── P7 ──────────────────────────────────────────────────────────────
    PERFORM pg_temp.te1_as('sandra@evoltrya.test');
    v_msg := pg_temp.te1_try(format($s$INSERT INTO contract_grade_specs (contract_id, metal, max_pct) VALUES (%L, 'cu', 1)$s$, c_sell));
    IF v_msg <> 'CONTRACT_TERMS_FROZEN|' || c_code || '|active' THEN RAISE EXCEPTION 'PROOF P7|%', v_msg; END IF;
    RAISE NOTICE 'P7a term add on active refused: %', v_msg;
    v_msg := pg_temp.te1_try(format($s$UPDATE contracts SET title = 'x' WHERE id = %L$s$, c_sell));
    IF v_msg <> 'CONTRACT_ACTIVE_IS_FROZEN|' || c_code THEN RAISE EXCEPTION 'PROOF P7|%', v_msg; END IF;
    RAISE NOTICE 'P7b header edit on active refused: %', v_msg;

    -- ── P8 ──────────────────────────────────────────────────────────────
    v_msg := pg_temp.te1_try(format($s$UPDATE contracts SET status = 'suspended' WHERE id = %L$s$, c_sell));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'PROOF P8|suspend: %', v_msg; END IF;
    v_msg := pg_temp.te1_try(format($s$UPDATE contract_pricing_terms SET payable_pct = 92 WHERE contract_id = %L$s$, c_sell));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'PROOF P8|edit after suspend: %', v_msg; END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := submit_contract_activation_request(c_sell, 'TE1 proof: payable renegotiated');
    EXECUTE 'RESET ROLE';
    q := (v_res->>'request_id')::uuid; q_label := v_res->>'label';
    PERFORM pg_temp.te1_as('tim@evoltrya.test');
    v_snap := pg_temp.te1_val(format($s$SELECT snapshot::text FROM terms_requests_visible(50) v WHERE v.id = %L$s$, q))::jsonb;
    IF (v_snap->'last_approved'->'pricing_terms'->0->>'payable_pct')::numeric <> 90
       OR (v_snap->'current'->'pricing_terms'->0->>'payable_pct')::numeric <> 92 THEN
        RAISE EXCEPTION 'PROOF P8|difference not visible to tim@: %', v_snap; END IF;
    RAISE NOTICE 'P8a suspended, payable 90 → 92, requested again (%); tim@ sees last_approved 90 · current 92', q_label;
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM decide_terms_request(q, true, NULL);
    EXECUTE 'RESET ROLE';
    IF (SELECT status FROM contracts WHERE id = c_sell) <> 'active' THEN RAISE EXCEPTION 'PROOF P8|not active again'; END IF;
    RAISE NOTICE 'P8b tim@ approved again → % active', c_code;

    -- ── P9 ──────────────────────────────────────────────────────────────
    PERFORM pg_temp.te1_as('sandra@evoltrya.test');
    v_msg := pg_temp.te1_try(format($s$UPDATE contracts SET status = 'terminated' WHERE id = %L$s$, c_sell));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'PROOF P9|terminate: %', v_msg; END IF;
    v_msg := pg_temp.te1_try(format($s$UPDATE contract_pricing_terms SET payable_pct = 93 WHERE contract_id = %L$s$, c_sell));
    IF v_msg <> 'CONTRACT_TERMS_FROZEN|' || c_code || '|terminated' THEN RAISE EXCEPTION 'PROOF P9|%', v_msg; END IF;
    RAISE NOTICE 'P9 terminated; term edit refused: %', v_msg;

    -- ── P10 ─────────────────────────────────────────────────────────────
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO contracts (supplier_id, kind, title, effective_from, status)
    VALUES (v_sup, 'supply', 'TE1 proof buy', CURRENT_DATE, 'draft') RETURNING id INTO c_buy;
    v_res := submit_contract_activation_request(c_buy, 'TE1 proof: buy side');
    PERFORM withdraw_terms_request((v_res->>'request_id')::uuid);
    EXECUTE 'RESET ROLE';
    IF v_res->>'status' <> 'submitted' THEN RAISE EXCEPTION 'PROOF P10|%', v_res; END IF;
    RAISE NOTICE 'P10 buy-side draft with no terms: request % submitted, then withdrawn', v_res->>'label';

    -- ── P11 ─────────────────────────────────────────────────────────────
    PERFORM pg_temp.te1_as('admin@swm-os.test');
    v_msg := pg_temp.te1_try(format($s$SELECT submit_contract_activation_request(%L, 'TE1 proof: admin')$s$, c_buy));
    IF v_msg NOT LIKE 'TERMS_REQUEST_NO_OTHER_DECIDER|%' THEN RAISE EXCEPTION 'PROOF P11|%', v_msg; END IF;
    RAISE NOTICE 'P11 admin@ request refused: %', v_msg;

    -- ── P12 ─────────────────────────────────────────────────────────────
    PERFORM pg_temp.te1_as('fusheng@evoltrya.test');
    IF pg_temp.te1_val(format($s$SELECT count(*)::text FROM contracts WHERE id = %L$s$, c_sell)) <> '0'
       OR pg_temp.te1_val(format($s$SELECT count(*)::text FROM contracts WHERE id = %L$s$, c_buy)) <> '1'
       OR pg_temp.te1_val(format($s$SELECT array_to_string(contract_activation_missing(%L), ',')$s$, c_sell)) <> '' THEN
        RAISE EXCEPTION 'PROOF P12|fusheng@ visibility wrong'; END IF;
    RAISE NOTICE 'P12 fusheng@ (warehouse) reads 0 rows of the sell contract (base table, RLS), 1 of the buy one; checklist empty for him';

    -- ── K ───────────────────────────────────────────────────────────────
    PERFORM set_config('request.jwt.claims', '', true);
    IF (SELECT count(*) FROM journal_entries) <> j_before OR (SELECT count(*) FROM journal_lines) <> jl_before THEN
        RAISE EXCEPTION 'PROOF K|journal changed'; END IF;
    IF EXISTS (SELECT 1 FROM terms_requests WHERE status = 'submitted') THEN RAISE EXCEPTION 'PROOF K|a request is waiting'; END IF;
    RAISE NOTICE 'K journal entries % · lines % unchanged; nothing waiting; approval_log +% inside the transaction (rolled back)',
        j_before, jl_before, (SELECT count(*) FROM approval_log) - log_before;
    RAISE NOTICE 'PROOF 全部通过:P1–P12 · K';
END;
$proof$;
ROLLBACK;
