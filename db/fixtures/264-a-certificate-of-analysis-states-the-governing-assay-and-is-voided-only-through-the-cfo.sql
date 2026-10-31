-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 264 —— 一张分析证书说出说话的那一份化验、它的成分与来料化学确定度,冻住,只经 CFO 作废
--   (MES-6b-2,2026-10-15;MES-0 Q53 · Q67 · Q68 · Q89 · Q90;MES-6b Step 0 Q10–Q14 · Q20 · Q29–Q32 · Q38–Q42,Tim 照推荐裁定)
-- ═══════════════════════════════════════════════════════════════════════════
-- 臂:
--   REG    码 action.issue_coa 在、声明 module.output.view 与 module.quality.view;单据登记 coa → COA(无洞,/quality/coa);两张新表进变更记录、
--          豁免仍是 8 —— MES-9b 起是 9、没有遮蔽的列(规则数不动、遮蔽零缺口);审计主语 coa 在(根 certificates_of_analysis,查看码 module.output.view)、
--          证书挂在两个批次主语下(产出批直接、进料批经加工单 → 产出腿 → 产出批两块垫脚石);仓库申请认 coa_void(主体 coa_id,恰好一个主体);
--          遮蔽伴生视图有 coa_id;每一个角色仍满足"动作码蕴含查看码"
--   N38    产出批的来料化学确定度 = 进料叶子(任意深度)上最弱的那一个:unknown_pending < 未记录 < mixed < single_known;不认得的码排最弱并
--          原样报出;没有进料叶子 → not_recorded、0 张;读面按产出批的读策略把关(没有 module.output.view → 零行);基视图谁都读不到
--   GOV    说话的那一份化验(Q11)三种情形:结案的争议点名的那一份;点了单 → 那张单的合同约定那一方最新一份活的;否则我们最新一份活的;
--          删掉的不算;【最新的一份不是最终结果 → 拒,不越过它去找一份旧的最终结果】;一份都没有 → 拒
--   NEVER  证书从不读 output_batch_metals:批次含量与那一份化验不同时,纸上的成分是化验自己的行
--   REFUSE 签发按名拒(Q29):没有最终化验 · 质量暂扣 · 开着的争议 · 产出腿称重不在校准期内(开关空着也拒)· 开关给了且没有称过的腿 ·
--          点名的单越限而为它开的报告没有以 accept* 决定(返工不算;接受了就放行)· 单不是这一批的 · 已有一张活证书 · 公司名没录 ·
--          签发人不是员工 · 签发人没有职位 · 没有 action.issue_coa
--   ISSUE  COA-<年>-NNNN 按年无洞;快照有号、签发时刻、签发人名字与职位、批、说话的化验与它的行、指标、N38;点了单 → 客户名、合同号、
--          适用的验收限与判定;一批 × 一张单(或不点名)同时只有一张活证书,不同的单各自一张
--   FROZEN 签发之后改活数据(新化验、改客户名、改批次含量),快照一个字不动;直连改快照 / 删证书按名拒;预览照旧读活数据
--   BYTES  字节档案:路径必须是 <证书 id>/…;一张证书一份;只追加;作废之后仍在
--   VOID   作废只经 CFO 申请:void_coa_internal 员工调不到;提 = action.issue_coa(没有就拒);审批开着 → submitted,证书照旧有效;
--          提单人(同一个人的另一个账号也算)批不了;二级批准 → 作废,voided_by = 提单人,快照与字节不动;作废了的再提按名拒;
--          重开一张是新号,旧的 replaced_by_coa_id 指向它;撤回与驳回什么都不作废;提单人之外没有二级审批人 → 提交就拒
--   ARM    coa_facts_changed:签发之后多了一份化验或一张报告 → 出现(持 action.issue_coa 的人看得见,别人看不见);作废之后消失
--   ISSUER (MES-7a-1 · F9)coa_issuer() 与 issue_coa 冻进快照的签发人逐字相同;常用名 → 法定名;不是员工 / 没有职位 / 没有码按名拒
--   TRAIL  三步各落一行变更记录;record_trail('coa') 有签发、字节与作废申请;产出批与进料批的审计记录里有这张证书
--
-- 自带数据(README 第 2 条);锁期、审批开关自己设(第 4、5 条)。以 postgres 跑;员工的调用切成 authenticated + JWT。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f264_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

CREATE FUNCTION pg_temp.f264_do(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v_prev text := NULLIF(current_setting('request.jwt.claims', true), '');
BEGIN
    PERFORM pg_temp.f264_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_prev, ''), true);
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_prev, ''), true);
    RETURN SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f264_get(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_prev text := NULLIF(current_setting('request.jwt.claims', true), '');
BEGIN
    PERFORM pg_temp.f264_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_prev, ''), true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_prev, ''), true);
    RAISE;
END;
$f$;

CREATE FUNCTION pg_temp.f264_user(p_label text, p_codes text[]) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE u uuid := gen_random_uuid(); r uuid;
BEGIN
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES (u, 'fx264-' || p_label || '@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx264-' || p_label, 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r, c FROM unnest(p_codes) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);
    RETURN u;
END;
$f$;

-- 一张产出批由一张加工单从几批进料做出来(属主路径直插:血缘与产出腿,不动库存 —— 证书读的只是血缘与称重)
CREATE FUNCTION pg_temp.f264_run(p_code text, p_inputs uuid[], p_upstream uuid, p_output uuid, p_weighing uuid, p_d date) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_run uuid; i uuid;
BEGIN
    INSERT INTO processing_runs (code, status, allocation_basis, process_date, operation_type_code, started_at, ended_at, shift_code)
    VALUES (p_code, 'committed', 'weight', p_d, 'manual_disassembly', p_d::timestamptz, p_d::timestamptz + interval '1 hour', 'day')
    RETURNING id INTO v_run;
    PERFORM set_config('evoltrya.movement_ctx', 'processing:' || v_run, true);
    FOREACH i IN ARRAY COALESCE(p_inputs, '{}'::uuid[]) LOOP
        INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed) VALUES (v_run, i, 10);
    END LOOP;
    IF p_upstream IS NOT NULL THEN
        INSERT INTO processing_inputs (run_id, output_batch_id, quantity_consumed) VALUES (v_run, p_upstream, 10);
    END IF;
    PERFORM set_config('evoltrya.movement_ctx', '', true);
    INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced, weighing_id) VALUES (v_run, p_output, 10, p_weighing);
    RETURN v_run;
END;
$f$;

CREATE FUNCTION pg_temp.f264_assay(p_ob uuid, p_code text, p_party text, p_final boolean, p_d date, p_moist numeric, p_ni numeric) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE a uuid;
BEGIN
    -- created_at = clock_timestamp():整支 fixture 是一笔事务,now() 一动不动 —— 而 coa_facts_changed 问的正是"签发【之后】多了一份"
    INSERT INTO assay_results (code, output_batch_id, assay_date, is_final, weight_basis, moisture_pct, result_party, lab_name, certificate_ref, created_at)
    VALUES (p_code, p_ob, p_d, p_final, 'dry', p_moist, p_party, NULL, 'CERT-' || p_code, clock_timestamp()) RETURNING id INTO a;
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct) VALUES (a, 'ni', p_ni), (a, 'co', 5), (a, 'f', 0.0123);
    RETURN a;
END;
$f$;

DO $$
DECLARE
    u_all uuid; u_iss uuid; u_iss_alt uuid; u_iss2 uuid; u_noemp uuid; u_nopos uuid; u_view uuid; u_none uuid; u_qonly uuid;
    u_l2 uuid; u_rec uuid; u_qe uuid; u_dec uuid; u_apl uuid; u_sal uuid; u_mon uuid;
    e_iss uuid := gen_random_uuid(); e_iss2 uuid := gen_random_uuid(); e_nopos uuid := gen_random_uuid();
    p_qm uuid;
    d date := CURRENT_DATE; v_year int := EXTRACT(YEAR FROM CURRENT_DATE)::int; v_base text;
    v_sup uuid; v_mat uuid; v_cust uuid; v_cust2 uuid; conA uuid; conB uuid; soA uuid; soB uuid; soC uuid; lA uuid; lB uuid; lC uuid;
    ib1 uuid; ib2 uuid; ib3 uuid;
    ob_n uuid; ob_n2 uuid; ob_bare uuid; ob_g uuid; ob_cal uuid; ob_hold uuid; ob_disp uuid; ob_lim uuid; ob_lim2 uuid; ob_x uuid; ob_v uuid;
    a1 uuid; a2 uuid; a3 uuid; a4 uuid; a5 uuid; ac uuid; ao uuid; d_g uuid;
    s_exp uuid; w_exp uuid; w_ok uuid; s_ok uuid;
    c1 uuid; c2 uuid; c3 uuid; c4 uuid; c5 uuid; r_l2 uuid; wr uuid;
    n_hold uuid; n_lim uuid; n_lim2 uuid;
    v_j jsonb; v_j2 jsonb; v_msg text; v_n bigint; v_code text; v_code2 text; v_snap jsonb; v_t text;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    PERFORM pg_temp.f264_as(NULL);
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;
    UPDATE ingest_settings SET require_calibrated_since = NULL;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '', true);
    IF NOT EXISTS (SELECT 1 FROM company_profile) THEN
        INSERT INTO company_profile (legal_name, registration_no, address_lines, city, postal_code, country)
        VALUES ('Fixture 264 Recovery Pte. Ltd.', 'FX264-UEN', '1 Fixture Road', 'Singapore', '000000', 'Singapore');
    ELSE
        UPDATE company_profile SET legal_name = 'Fixture 264 Recovery Pte. Ltd.', registration_no = COALESCE(registration_no, 'FX264-UEN');
    END IF;

    INSERT INTO positions (code, title) VALUES ('FX264-QM', 'Quality Manager') RETURNING id INTO p_qm;
    u_all   := pg_temp.f264_user('all', (SELECT array_agg(code) FROM permissions));
    u_iss   := pg_temp.f264_user('iss', ARRAY['action.issue_coa', 'module.output.view', 'module.quality.view', 'module.inventory.view']);
    u_iss_alt := pg_temp.f264_user('issalt', ARRAY['module.finance.view', 'data.view_prices', 'module.inventory.view', 'module.output.view']);
    u_iss2  := pg_temp.f264_user('iss2', ARRAY['action.issue_coa', 'module.output.view']);
    u_noemp := pg_temp.f264_user('noemp', ARRAY['action.issue_coa', 'module.output.view']);
    u_nopos := pg_temp.f264_user('nopos', ARRAY['action.issue_coa', 'module.output.view']);
    u_view  := pg_temp.f264_user('view', ARRAY['module.output.view']);
    u_none  := pg_temp.f264_user('none', ARRAY['module.sales.view']);
    u_qonly := pg_temp.f264_user('qonly', ARRAY['module.quality.view']);
    u_rec   := pg_temp.f264_user('rec', ARRAY['module.output.view', 'module.output.edit']);
    u_qe    := pg_temp.f264_user('qe', ARRAY['module.quality.view', 'module.quality.edit', 'module.output.view']);
    u_dec   := pg_temp.f264_user('dec', ARRAY['action.ncr_decide', 'module.quality.view', 'module.output.view']);
    u_apl   := pg_temp.f264_user('apl', ARRAY['action.apply_assay', 'module.output.view', 'module.inbound.view', 'module.quality.view']);
    u_sal   := pg_temp.f264_user('sal', ARRAY['module.sales.view', 'module.sales.edit', 'module.output.view']);
    u_mon   := pg_temp.f264_user('mon', ARRAY['module.finance.view']);
    INSERT INTO employees (id, code, legal_name, preferred_name, employment_type, work_category, hire_date, user_id, position_id) VALUES
        (e_iss, 'FX264-ISS', 'Fixture Issuer Tan', 'Tan', 'full_time', 'office', d - 400, u_iss, p_qm),
        (e_iss2, 'FX264-ISS2', 'Fixture Second Issuer', NULL, 'full_time', 'office', d - 400, u_iss2, p_qm),
        (e_nopos, 'FX264-NOPOS', 'Fixture No Position', NULL, 'full_time', 'office', d - 400, u_nopos, NULL);
    -- 签发人这个人的另一个账号(二级审批角色)—— "提单人按人认不能批"那一格
    INSERT INTO employee_accounts (user_id, employee_id) VALUES (u_iss_alt, e_iss);

    -- ══════════════ 布景 ══════════════
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ264-S', 'f264 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ264-BM', 'f264 black mass', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO v_mat;
    INSERT INTO customers (code, legal_name, country, payment_terms_days) VALUES ('ZZ264-C', 'f264 Buyer Pte Ltd', 'SG', 30) RETURNING id INTO v_cust;
    INSERT INTO customers (code, legal_name, country, payment_terms_days) VALUES ('ZZ264-C2', 'f264 Second Buyer', 'SG', 30) RETURNING id INTO v_cust2;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note, chemistry_certainty_code) VALUES
        ('ZZ264-IB1', v_mat, v_sup, 100, 100, 'kg', d - 9, 'other', 'fixture 264', 'single_known'),
        ('ZZ264-IB2', v_mat, v_sup, 100, 100, 'kg', d - 9, 'other', 'fixture 264', 'mixed'),
        ('ZZ264-IB3', v_mat, v_sup, 100, 100, 'kg', d - 9, 'other', 'fixture 264', NULL);
    SELECT id INTO ib1 FROM inbound_batches WHERE code = 'ZZ264-IB1';
    SELECT id INTO ib2 FROM inbound_batches WHERE code = 'ZZ264-IB2';
    SELECT id INTO ib3 FROM inbound_batches WHERE code = 'ZZ264-IB3';
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT id, 'discharged_verified' FROM inbound_batches WHERE code LIKE 'ZZ264-IB%';
    PERFORM pg_temp.f264_as(u_all);
    ob_n    := (create_output_batch(v_mat, 100, 'kg', d - 3) ->> 'batch_id')::uuid;
    ob_n2   := (create_output_batch(v_mat, 100, 'kg', d - 3) ->> 'batch_id')::uuid;
    ob_bare := (create_output_batch(v_mat, 100, 'kg', d - 3) ->> 'batch_id')::uuid;
    ob_g    := (create_output_batch(v_mat, 100, 'kg', d - 3) ->> 'batch_id')::uuid;
    ob_cal  := (create_output_batch(v_mat, 100, 'kg', d - 3) ->> 'batch_id')::uuid;
    ob_hold := (create_output_batch(v_mat, 100, 'kg', d - 3) ->> 'batch_id')::uuid;
    ob_disp := (create_output_batch(v_mat, 100, 'kg', d - 3) ->> 'batch_id')::uuid;
    ob_lim  := (create_output_batch(v_mat, 100, 'kg', d - 3) ->> 'batch_id')::uuid;
    ob_lim2 := (create_output_batch(v_mat, 100, 'kg', d - 3) ->> 'batch_id')::uuid;
    ob_x    := (create_output_batch(v_mat, 100, 'kg', d - 3) ->> 'batch_id')::uuid;
    ob_v    := (create_output_batch(v_mat, 100, 'kg', d - 3) ->> 'batch_id')::uuid;
    -- 一台过期的秤、一台在期的秤,各称一次
    s_exp := (save_device('{"name":"ZZF264 expired scale","kind":"scale","interface_status":"manual_only","capacity":5000}'::jsonb))::uuid;
    PERFORM record_instrument_calibration(s_exp, d - 400, d - 30, 'passed');
    w_exp := (submit_manual_capture('weighing', '{"weight_kg": 25}'::jsonb, s_exp) ->> 'weighing_id')::uuid;
    s_ok := (save_device('{"name":"ZZF264 good scale","kind":"scale","interface_status":"manual_only","capacity":5000}'::jsonb))::uuid;
    PERFORM record_instrument_calibration(s_ok, d - 30, d + 300, 'passed');
    w_ok := (submit_manual_capture('weighing', '{"weight_kg": 10}'::jsonb, s_ok) ->> 'weighing_id')::uuid;
    PERFORM pg_temp.f264_as(NULL);
    INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code) VALUES (ob_n, 'discharged_verified');
    -- 血缘:ob_n ← IB1 · IB2 · IB3(一层);ob_n2 ← ob_n(两层,叶子仍是那三批);ob_cal 的产出腿称在过期的秤上;ob_g 的称在在期的秤上
    PERFORM pg_temp.f264_run('ZZ264-RUN-N', ARRAY[ib1, ib2, ib3], NULL, ob_n, NULL, d - 3);
    PERFORM pg_temp.f264_run('ZZ264-RUN-N2', NULL, ob_n, ob_n2, NULL, d - 3);
    PERFORM pg_temp.f264_run('ZZ264-RUN-CAL', ARRAY[ib1], NULL, ob_cal, w_exp, d - 3);
    PERFORM pg_temp.f264_run('ZZ264-RUN-G', ARRAY[ib1], NULL, ob_g, w_ok, d - 3);

    -- ══════════════ REG ══════════════
    RAISE NOTICE 'fixture 264 · REG';
    IF NOT EXISTS (SELECT 1 FROM permissions WHERE code = 'action.issue_coa' AND category = 'action'
                     AND requires_view_any = ARRAY['module.output.view', 'module.quality.view']) THEN
        RAISE EXCEPTION 'FIXTURE 264 REG: action.issue_coa must exist and declare module.output.view and module.quality.view'; END IF;
    IF document_type_prefix('coa') IS DISTINCT FROM 'COA' OR NOT EXISTS (SELECT 1 FROM document_types WHERE key = 'coa'
         AND table_name = 'certificates_of_analysis' AND numbering = 'gapless' AND route = '/quality/coa' AND view_permission = ARRAY['module.output.view']) THEN
        RAISE EXCEPTION 'FIXTURE 264 REG: the document registry carries coa → COA, gapless, /quality/coa, read by module.output.view'; END IF;
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') IS DISTINCT FROM 0 OR (v_j ->> 'excluded')::int IS DISTINCT FROM 12 THEN
        RAISE EXCEPTION 'FIXTURE 264 REG: change-log coverage has no gap and exactly 8 exclusions, got %', v_j; END IF;
    SELECT count(*) INTO v_n FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
     WHERE t.tgname = 'zzz_change_log' AND c.relname IN ('certificates_of_analysis', 'coa_issues');
    IF v_n IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'FIXTURE 264 REG: the two new tables are change-logged, got %', v_n; END IF;
    IF EXISTS (SELECT 1 FROM change_log_mask_rules() r WHERE r.table_name IN ('certificates_of_analysis', 'coa_issues'))
       OR jsonb_array_length(change_log_mask_gaps() -> 'gaps') IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'FIXTURE 264 REG: no masked column on the new tables and no mask gap'; END IF;
    IF NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'coa' AND s.root_table = 'certificates_of_analysis'
                     AND s.view_codes = ARRAY['module.output.view']) THEN
        RAISE EXCEPTION 'FIXTURE 264 REG: trail subject coa (root certificates_of_analysis, module.output.view)'; END IF;
    SELECT count(*) INTO v_n FROM trail_subject_members() m
     WHERE (m.subject, m.table_name, m.parent_table, m.shown, m.home) IN (
            ('coa', 'coa_issues', 'certificates_of_analysis', true, true), ('coa', 'warehouse_requests', 'certificates_of_analysis', true, false),
            ('coa', 'approval_log', 'warehouse_requests', true, false),
            ('output_batch', 'certificates_of_analysis', 'output_batches', true, false), ('output_batch', 'coa_issues', 'certificates_of_analysis', true, false),
            ('output_batch', 'warehouse_requests', 'certificates_of_analysis', true, false),
            ('inbound_batch', 'processing_outputs', 'processing_runs', false, false), ('inbound_batch', 'output_batches', 'processing_outputs', false, false),
            ('inbound_batch', 'certificates_of_analysis', 'output_batches', true, false));
    IF v_n IS DISTINCT FROM 9 THEN RAISE EXCEPTION 'FIXTURE 264 REG: the CoA trail registrations (own subject, output batch, inbound batch through the run), got %', v_n; END IF;
    IF pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'warehouse_requests_kind_check')) NOT LIKE '%coa_void%'
       OR pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'warehouse_requests_one_subject')) NOT LIKE '%coa_id%'
       OR NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'warehouse_requests_masked' AND column_name = 'coa_id') THEN
        RAISE EXCEPTION 'FIXTURE 264 REG: warehouse_requests knows coa_void (subject coa_id, one subject) and the masked view carries coa_id'; END IF;
    SELECT string_agg(r.code || '->' || rp.permission_code, ', ') INTO v_t
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
     WHERE p.requires_view_any IS NOT NULL AND cardinality(p.requires_view_any) > 0
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any));
    IF v_t IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 264 REG: action-implies-view violated: %', v_t; END IF;

    -- ══════════════ N38 ══════════════
    RAISE NOTICE 'fixture 264 · N38';
    -- 单一 · 混的 · 未记录 → 最弱是未记录
    v_j := pg_temp.f264_get(u_view, format($q$SELECT to_jsonb(c) FROM output_batch_chemistry_certainty c WHERE output_batch_id = %L$q$, ob_n));
    IF v_j ->> 'certainty' IS DISTINCT FROM 'not_recorded' OR (v_j ->> 'inbound_leaves')::int IS DISTINCT FROM 3 OR (v_j ->> 'leaves_single_known')::int IS DISTINCT FROM 1
       OR (v_j ->> 'leaves_mixed')::int IS DISTINCT FROM 1 OR (v_j ->> 'leaves_not_recorded')::int IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'FIXTURE 264 N38: single + mixed + not recorded → not_recorded over three leaves, got %', v_j; END IF;
    -- 两层:叶子仍是那三批
    v_j := pg_temp.f264_get(u_view, format($q$SELECT to_jsonb(c) FROM output_batch_chemistry_certainty c WHERE output_batch_id = %L$q$, ob_n2));
    IF v_j ->> 'certainty' IS DISTINCT FROM 'not_recorded' OR (v_j ->> 'inbound_leaves')::int IS DISTINCT FROM 3 THEN
        RAISE EXCEPTION 'FIXTURE 264 N38: the leaves are found at any depth, got %', v_j; END IF;
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = ib3;
    IF (SELECT certainty FROM output_batch_chemistry_certainty_all WHERE output_batch_id = ob_n) IS DISTINCT FROM 'mixed' THEN
        RAISE EXCEPTION 'FIXTURE 264 N38: single + mixed + single → mixed'; END IF;
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = ib2;
    IF (SELECT certainty FROM output_batch_chemistry_certainty_all WHERE output_batch_id = ob_n) IS DISTINCT FROM 'single_known' THEN
        RAISE EXCEPTION 'FIXTURE 264 N38: all single → single_known'; END IF;
    UPDATE inbound_batches SET chemistry_certainty_code = 'unknown_pending' WHERE id = ib2;
    UPDATE inbound_batches SET chemistry_certainty_code = NULL WHERE id = ib3;
    IF (SELECT certainty FROM output_batch_chemistry_certainty_all WHERE output_batch_id = ob_n) IS DISTINCT FROM 'unknown_pending' THEN
        RAISE EXCEPTION 'FIXTURE 264 N38: unknown_pending is below not recorded'; END IF;
    INSERT INTO inbound_chemistry_certainties (code, name_en, name_zh, may_be_fed, sort_order) VALUES ('zz264_new', 'f264 new', 'f264 new', true, 99);
    UPDATE inbound_batches SET chemistry_certainty_code = 'zz264_new' WHERE id = ib1;
    IF (SELECT certainty FROM output_batch_chemistry_certainty_all WHERE output_batch_id = ob_n) IS DISTINCT FROM 'zz264_new' THEN
        RAISE EXCEPTION 'FIXTURE 264 N38: an unrecognised code ranks weakest and is reported as itself'; END IF;
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = ib1;
    UPDATE inbound_batches SET chemistry_certainty_code = 'mixed' WHERE id = ib2;
    UPDATE inbound_batches SET chemistry_certainty_code = NULL WHERE id = ib3;
    -- 没有血缘 → not_recorded、0 张
    IF (SELECT certainty || ':' || inbound_leaves FROM output_batch_chemistry_certainty_all WHERE output_batch_id = ob_bare) IS DISTINCT FROM 'not_recorded:0' THEN
        RAISE EXCEPTION 'FIXTURE 264 N38: no inbound leaves → not_recorded over 0 leaves'; END IF;
    -- 读面跟着产出批的读策略;基视图谁都读不到
    v_msg := pg_temp.f264_do(u_none, format($q$SELECT 1/(SELECT count(*) FROM output_batch_chemistry_certainty WHERE output_batch_id = %L)$q$, ob_n));
    IF v_msg NOT LIKE '%division by zero%' THEN
        RAISE EXCEPTION 'FIXTURE 264 N38: without module.output.view the reader sees no rows, got %', v_msg; END IF;
    IF has_table_privilege('authenticated', 'public.output_batch_chemistry_certainty_all', 'SELECT')
       OR has_table_privilege('anon', 'public.output_batch_chemistry_certainty', 'SELECT') THEN
        RAISE EXCEPTION 'FIXTURE 264 N38: the base view is read by nobody, the gated view never by anon'; END IF;

    -- ══════════════ GOV ══════════════
    RAISE NOTICE 'fixture 264 · GOV';
    IF coa_governing_assay(ob_g, NULL) ->> 'assay_id' IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 264 GOV: no assay → none'; END IF;
    a1 := pg_temp.f264_assay(ob_g, 'ZZ264-G-OURS-1', 'ours', true, d - 5, 6, 20);
    a2 := pg_temp.f264_assay(ob_g, 'ZZ264-G-OURS-2', 'ours', true, d - 2, 6.5, 21);
    a3 := pg_temp.f264_assay(ob_g, 'ZZ264-G-CP-1', 'counterparty', true, d - 1, 7, 19);
    IF (coa_governing_assay(ob_g, NULL) ->> 'assay_id')::uuid IS DISTINCT FROM a2 OR coa_governing_assay(ob_g, NULL) ->> 'basis' IS DISTINCT FROM 'ours' THEN
        RAISE EXCEPTION 'FIXTURE 264 GOV: no order named → our latest live result, got %', coa_governing_assay(ob_g, NULL); END IF;
    UPDATE assay_results SET deleted_at = now() WHERE id = a2;
    IF (coa_governing_assay(ob_g, NULL) ->> 'assay_id')::uuid IS DISTINCT FROM a1 THEN
        RAISE EXCEPTION 'FIXTURE 264 GOV: a deleted result never governs'; END IF;
    UPDATE assay_results SET deleted_at = NULL WHERE id = a2;
    -- 合同:A 约定我们、带水分上限 8;B 约定对手方、不设验收限
    INSERT INTO contracts (customer_id, kind, title, effective_from, status) VALUES (v_cust, 'offtake', 'f264 offtake A', DATE '2026-01-01', 'draft') RETURNING id INTO conA;
    INSERT INTO contract_settlement_terms (contract_id, sale_weight_basis, settling_party, sample_retention_required, refining_charge_basis, penalty_basis, quality_limit_basis)
    VALUES (conA, 'dry', 'ours', false, 'none_agreed', 'per_element', 'per_parameter');
    INSERT INTO contract_quality_limits (contract_id, material_id, parameter, min_value, max_value) VALUES (conA, NULL, 'moisture_pct', NULL, 8);
    UPDATE contracts SET status = 'active' WHERE id = conA;
    INSERT INTO contracts (customer_id, kind, title, effective_from, status) VALUES (v_cust2, 'offtake', 'f264 offtake B', DATE '2026-01-01', 'draft') RETURNING id INTO conB;
    INSERT INTO contract_settlement_terms (contract_id, sale_weight_basis, settling_party, sample_retention_required, refining_charge_basis, penalty_basis, quality_limit_basis)
    VALUES (conB, 'dry', 'counterparty', false, 'none_agreed', 'per_element', 'none_agreed');
    UPDATE contracts SET status = 'active' WHERE id = conB;
    PERFORM pg_temp.f264_as(u_all);
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate) VALUES (next_sales_order_code(d - 4), v_cust, d - 4, v_base, 1) RETURNING id INTO soA;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price) VALUES (soA, 1, v_mat, 500, 10) RETURNING id INTO lA;
    PERFORM set_sales_order_status(soA, 'confirmed');
    PERFORM link_document_to_contract('sales_order', soA, conA);
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate) VALUES (next_sales_order_code(d - 4), v_cust2, d - 4, v_base, 1) RETURNING id INTO soB;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price) VALUES (soB, 1, v_mat, 500, 10) RETURNING id INTO lB;
    PERFORM set_sales_order_status(soB, 'confirmed');
    PERFORM link_document_to_contract('sales_order', soB, conB);
    -- C:不挂合同
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate) VALUES (next_sales_order_code(d - 4), v_cust, d - 4, v_base, 1) RETURNING id INTO soC;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price) VALUES (soC, 1, v_mat, 500, 10) RETURNING id INTO lC;
    PERFORM set_sales_order_status(soC, 'confirmed');
    PERFORM pg_temp.f264_as(NULL);
    PERFORM pg_temp.f264_get(u_sal, format($q$SELECT reserve_stock(%L, %L, 5)$q$, lB, ob_g));
    PERFORM pg_temp.f264_get(u_sal, format($q$SELECT reserve_stock(%L, %L, 5)$q$, lC, ob_g));
    IF (coa_governing_assay(ob_g, soB) ->> 'assay_id')::uuid IS DISTINCT FROM a3 OR coa_governing_assay(ob_g, soB) ->> 'basis' IS DISTINCT FROM 'settling_party' THEN
        RAISE EXCEPTION 'FIXTURE 264 GOV: an order whose contract settles on the counterparty → the counterparty''s latest live result, got %', coa_governing_assay(ob_g, soB); END IF;
    IF (coa_governing_assay(ob_g, soC) ->> 'assay_id')::uuid IS DISTINCT FROM a2 OR coa_governing_assay(ob_g, soC) ->> 'basis' IS DISTINCT FROM 'ours' THEN
        RAISE EXCEPTION 'FIXTURE 264 GOV: an order with no contract → our latest live result, got %', coa_governing_assay(ob_g, soC); END IF;
    -- 结案的争议点名的那一份说了算(无论点不点单)
    d_g := (pg_temp.f264_get(u_qe, format($q$SELECT open_assay_dispute(%L, %L, 'nickel differs', NULL)$q$, a1, a3)) ->> 'dispute_id')::uuid;
    PERFORM pg_temp.f264_get(u_apl, format($q$SELECT resolve_assay_dispute(%L, %L, 'Their reading stands')$q$, d_g, a1));
    IF (coa_governing_assay(ob_g, NULL) ->> 'assay_id')::uuid IS DISTINCT FROM a1 OR (coa_governing_assay(ob_g, soB) ->> 'assay_id')::uuid IS DISTINCT FROM a1
       OR coa_governing_assay(ob_g, NULL) ->> 'basis' IS DISTINCT FROM 'dispute' THEN
        RAISE EXCEPTION 'FIXTURE 264 GOV: a resolved dispute''s governing assay governs, got %', coa_governing_assay(ob_g, NULL); END IF;
    -- is_final:说话的那一份必须是最终结果 —— 一份更新的初步结果在场时拒,不越过它
    a4 := pg_temp.f264_assay(ob_x, 'ZZ264-X-OURS-FINAL', 'ours', true, d - 5, 6, 20);
    a5 := pg_temp.f264_assay(ob_x, 'ZZ264-X-OURS-PRELIM', 'ours', false, d - 1, 6, 22);
    IF NOT (coa_issue_blockers(ob_x, NULL) @> ARRAY['COA_NO_FINAL_ASSAY|' || (SELECT code FROM output_batches WHERE id = ob_x) || '|ZZ264-X-OURS-PRELIM']) THEN
        RAISE EXCEPTION 'FIXTURE 264 GOV: the latest result is preliminary → refused by name (no fallback to an older final one), got %', coa_issue_blockers(ob_x, NULL); END IF;
    IF NOT (coa_issue_blockers(ob_bare, NULL) @> ARRAY['COA_NO_FINAL_ASSAY|' || (SELECT code FROM output_batches WHERE id = ob_bare) || '|-']) THEN
        RAISE EXCEPTION 'FIXTURE 264 GOV: no assay → COA_NO_FINAL_ASSAY|batch|-'; END IF;
    UPDATE assay_results SET is_final = true WHERE id = a5;

    -- ══════════════ NEVER ══════════════
    RAISE NOTICE 'fixture 264 · NEVER';
    DELETE FROM output_batch_metals WHERE output_batch_id = ob_x;
    INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source) VALUES (ob_x, 'ni', 99, 'manual'), (ob_x, 'mn', 7, 'manual');
    v_j := pg_temp.f264_get(u_view, format($q$SELECT coa_certificate_data(%L)$q$, ob_x));
    IF v_j -> 'composition' IS DISTINCT FROM '[{"name": "Nickel", "role": "payable_metal", "symbol": "Ni", "substance": "ni", "content_pct": 22}, {"name": "Cobalt", "role": "payable_metal", "symbol": "Co", "substance": "co", "content_pct": 5}, {"name": "Fluorine", "role": "penalty_element", "symbol": "F", "substance": "f", "content_pct": 0.0123}]'::jsonb
       OR v_j -> 'assay' ->> 'code' IS DISTINCT FROM 'ZZ264-X-OURS-PRELIM' THEN
        RAISE EXCEPTION 'FIXTURE 264 NEVER: the composition is the governing assay''s own lines (ni 22, co 5, f 0.0123), never the batch content (ni 99, mn 7), got %', v_j -> 'composition'; END IF;

    -- ══════════════ REFUSE ══════════════
    RAISE NOTICE 'fixture 264 · REFUSE';
    -- 码
    v_msg := pg_temp.f264_do(u_view, format($q$SELECT issue_coa(%L)$q$, ob_x));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.issue_coa%' THEN RAISE EXCEPTION 'FIXTURE 264 REFUSE: issuing needs action.issue_coa, got %', v_msg; END IF;
    v_msg := pg_temp.f264_do(u_none, format($q$SELECT coa_certificate_data(%L)$q$, ob_x));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.output.view%' THEN RAISE EXCEPTION 'FIXTURE 264 REFUSE: the preview needs module.output.view, got %', v_msg; END IF;
    -- 没有最终化验
    v_msg := pg_temp.f264_do(u_iss, format($q$SELECT issue_coa(%L)$q$, ob_bare));
    IF v_msg NOT LIKE 'COA_NO_FINAL_ASSAY|%|-' THEN RAISE EXCEPTION 'FIXTURE 264 REFUSE: no final assay, got %', v_msg; END IF;
    -- 质量暂扣
    PERFORM pg_temp.f264_assay(ob_hold, 'ZZ264-HOLD-OURS', 'ours', true, d - 1, 6, 20);
    n_hold := (pg_temp.f264_get(u_qe, format($q$SELECT open_ncr('manual', 'Foreign matter found', p_output_batch_id => %L)$q$, ob_hold)) ->> 'ncr_id')::uuid;
    v_msg := pg_temp.f264_do(u_iss, format($q$SELECT issue_coa(%L)$q$, ob_hold));
    IF v_msg NOT LIKE 'QUALITY_HOLD_OPEN|%|NCR-%' THEN RAISE EXCEPTION 'FIXTURE 264 REFUSE: an open NCR refuses, got %', v_msg; END IF;
    -- 开着的争议
    ao := pg_temp.f264_assay(ob_disp, 'ZZ264-DISP-OURS', 'ours', true, d - 2, 6, 20);
    ac := pg_temp.f264_assay(ob_disp, 'ZZ264-DISP-CP', 'counterparty', true, d - 2, 6, 25);
    PERFORM pg_temp.f264_get(u_qe, format($q$SELECT open_assay_dispute(%L, %L, 'nickel differs', NULL)$q$, ao, ac));
    v_msg := pg_temp.f264_do(u_iss, format($q$SELECT issue_coa(%L)$q$, ob_disp));
    IF v_msg NOT LIKE 'ASSAY_DISPUTE_OPEN|%' THEN RAISE EXCEPTION 'FIXTURE 264 REFUSE: an open dispute refuses, got %', v_msg; END IF;
    -- 称重不在校准期内(开关空着也拒)
    PERFORM pg_temp.f264_assay(ob_cal, 'ZZ264-CAL-OURS', 'ours', true, d - 1, 6, 20);
    v_msg := pg_temp.f264_do(u_iss, format($q$SELECT issue_coa(%L)$q$, ob_cal));
    IF v_msg NOT LIKE 'READING_INSTRUMENT_NOT_CALIBRATED|' || (SELECT code FROM devices WHERE id = s_exp) || '|%' THEN
        RAISE EXCEPTION 'FIXTURE 264 REFUSE: an output-leg weighing out of calibration refuses, got %', v_msg; END IF;
    -- 开关给了:没有称过的腿 → 拒;开关空着 → 放(下面 ISSUE 的 ob_x 就是这样签出来的)
    UPDATE ingest_settings SET require_calibrated_since = d - 10;
    v_msg := pg_temp.f264_do(u_iss, format($q$SELECT issue_coa(%L)$q$, ob_x));
    IF v_msg NOT LIKE 'COA_OUTPUT_READING_NOT_RECORDED|%' THEN
        RAISE EXCEPTION 'FIXTURE 264 REFUSE: with the calibration rule on, a batch with no weighed leg is refused, got %', v_msg; END IF;
    UPDATE ingest_settings SET require_calibrated_since = NULL;
    -- 点名的单越限,报告没有被接受(返工)→ 拒;接受了 → 放
    PERFORM pg_temp.f264_get(u_sal, format($q$SELECT reserve_stock(%L, %L, 5)$q$, lA, ob_lim));
    v_j := pg_temp.f264_get(u_rec, format($q$SELECT record_assay_result(p_assay_date => CURRENT_DATE - 1, p_metals => '[{"metal":"ni","content_pct":20}]'::jsonb,
            p_output_batch_id => %L, p_weight_basis => 'dry', p_moisture_pct => 9.2, p_result_party => 'ours', p_is_final => true)$q$, ob_lim));
    SELECT id INTO n_lim FROM nonconformance_reports WHERE code = v_j -> 'ncrs_opened' ->> 0;
    IF n_lim IS NULL THEN RAISE EXCEPTION 'FIXTURE 264 REFUSE: setup — the breach should have opened a system NCR, got %', v_j; END IF;
    PERFORM pg_temp.f264_get(u_dec, format($q$SELECT decide_ncr(%L, 'rework', 'Dry it again')$q$, n_lim));
    v_msg := pg_temp.f264_do(u_iss, format($q$SELECT issue_coa(%L, %L)$q$, ob_lim, soA));
    IF v_msg IS DISTINCT FROM 'COA_LIMIT_BREACHED|' || (SELECT code FROM output_batches WHERE id = ob_lim) || '|' || (SELECT code FROM sales_orders WHERE id = soA) || '|moisture_pct' THEN
        RAISE EXCEPTION 'FIXTURE 264 REFUSE: a breach whose report was decided rework (not accept*) refuses for that order, got %', v_msg; END IF;
    -- 同一批不点单 → 放(验收限只在点名的单上说话)
    v_msg := pg_temp.f264_do(u_iss, format($q$SELECT issue_coa(%L)$q$, ob_lim));
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 264 REFUSE: without an order the limit does not speak, got %', v_msg; END IF;
    PERFORM pg_temp.f264_get(u_sal, format($q$SELECT reserve_stock(%L, %L, 5)$q$, lA, ob_lim2));
    v_j := pg_temp.f264_get(u_rec, format($q$SELECT record_assay_result(p_assay_date => CURRENT_DATE - 1, p_metals => '[{"metal":"ni","content_pct":20}]'::jsonb,
            p_output_batch_id => %L, p_weight_basis => 'dry', p_moisture_pct => 9.5, p_result_party => 'ours', p_is_final => true,
            p_indicators => '[{"indicator":"d50_um","value":12}]'::jsonb)$q$, ob_lim2));
    SELECT id INTO n_lim2 FROM nonconformance_reports WHERE code = v_j -> 'ncrs_opened' ->> 0;
    PERFORM pg_temp.f264_get(u_dec, format($q$SELECT decide_ncr(%L, 'accept', 'Buyer accepts this lot')$q$, n_lim2));
    -- 单不是这一批的
    v_msg := pg_temp.f264_do(u_iss, format($q$SELECT issue_coa(%L, %L)$q$, ob_x, soA));
    IF v_msg NOT LIKE 'COA_SALES_ORDER_NOT_FOR_BATCH|%' THEN RAISE EXCEPTION 'FIXTURE 264 REFUSE: an order that never reserved or shipped the batch, got %', v_msg; END IF;
    -- 签发人:不是员工 / 没有职位
    v_msg := pg_temp.f264_do(u_noemp, format($q$SELECT issue_coa(%L)$q$, ob_g));
    IF v_msg IS DISTINCT FROM 'COA_ISSUER_NOT_AN_EMPLOYEE' THEN RAISE EXCEPTION 'FIXTURE 264 REFUSE: the issuer must be an employee, got %', v_msg; END IF;
    v_msg := pg_temp.f264_do(u_nopos, format($q$SELECT issue_coa(%L)$q$, ob_g));
    IF v_msg IS DISTINCT FROM 'COA_ISSUER_POSITION_MISSING|Fixture No Position' THEN RAISE EXCEPTION 'FIXTURE 264 REFUSE: the issuer must have a position, got %', v_msg; END IF;
    -- 公司名没录
    UPDATE company_profile SET legal_name = '';
    v_msg := pg_temp.f264_do(u_iss, format($q$SELECT issue_coa(%L)$q$, ob_g));
    IF v_msg IS DISTINCT FROM 'COMPANY_LEGAL_NAME_MISSING|/finance/company' THEN RAISE EXCEPTION 'FIXTURE 264 REFUSE: the company name is required, got %', v_msg; END IF;
    UPDATE company_profile SET legal_name = 'Fixture 264 Recovery Pte. Ltd.';
    -- 拒绝之后什么都没留下
    IF EXISTS (SELECT 1 FROM certificates_of_analysis WHERE output_batch_id IN (ob_bare, ob_hold, ob_disp, ob_cal, ob_g)
                 OR (output_batch_id = ob_lim AND sales_order_id IS NOT NULL) OR (output_batch_id = ob_x)) THEN
        RAISE EXCEPTION 'FIXTURE 264 REFUSE: a refused issue leaves no certificate behind'; END IF;

    -- ══════════════ ISSUE ══════════════
    RAISE NOTICE 'fixture 264 · ISSUE';
    v_code := next_coa_code(d);
    IF v_code IS DISTINCT FROM 'COA-' || v_year || '-' || LPAD(((SELECT COALESCE(MAX(split_part(code, '-', 3)::int), 0) FROM certificates_of_analysis
                                                     WHERE code LIKE 'COA-' || v_year || '-%') + 1)::text, 4, '0') THEN
        RAISE EXCEPTION 'FIXTURE 264 ISSUE: next_coa_code follows the gapless formula, got %', v_code; END IF;
    v_j := pg_temp.f264_get(u_iss, format($q$SELECT issue_coa(%L)$q$, ob_x));
    c1 := (v_j ->> 'coa_id')::uuid;
    IF v_j ->> 'code' IS DISTINCT FROM v_code OR next_coa_code(d) IS DISTINCT FROM 'COA-' || v_year || '-' || LPAD((split_part(v_code, '-', 3)::int + 1)::text, 4, '0') THEN
        RAISE EXCEPTION 'FIXTURE 264 ISSUE: the number is minted at issue, gapless (+1 next), got % / %', v_j ->> 'code', next_coa_code(d); END IF;
    SELECT snapshot INTO v_snap FROM certificates_of_analysis WHERE id = c1;
    IF v_snap -> 'certificate' ->> 'code' IS DISTINCT FROM v_code OR v_snap -> 'issuer' ->> 'name' IS DISTINCT FROM 'Tan' OR v_snap -> 'issuer' ->> 'position' IS DISTINCT FROM 'Quality Manager'
       OR v_snap -> 'batch' ->> 'code' IS DISTINCT FROM (SELECT code FROM output_batches WHERE id = ob_x) OR v_snap -> 'assay' ->> 'code' IS DISTINCT FROM 'ZZ264-X-OURS-PRELIM'
       OR (v_snap -> 'assay' ->> 'is_final')::boolean IS NOT TRUE OR v_snap -> 'company' ->> 'legal_name' IS DISTINCT FROM 'Fixture 264 Recovery Pte. Ltd.'
       OR v_snap -> 'chemistry' ->> 'certainty' IS DISTINCT FROM 'not_recorded' OR v_snap -> 'sales_order' IS DISTINCT FROM 'null'::jsonb
       OR (SELECT governing_assay_id FROM certificates_of_analysis WHERE id = c1) IS DISTINCT FROM a5
       OR (SELECT issued_by FROM certificates_of_analysis WHERE id = c1) IS DISTINCT FROM u_iss THEN
        RAISE EXCEPTION 'FIXTURE 264 ISSUE: the snapshot carries the number, "Tan, Quality Manager", the batch, the governing assay, N38 and no order, got %', v_snap; END IF;
    -- ══════════════ ISSUER(MES-7a-1 · F9,MES-7a Step 0 Q8)══════════════
    -- coa_issuer() 是签发人的唯一一份解析:issue_coa 冻进快照的那一位,就是路由在铸号之前、表单在按下之前问到的那一位。
    --   常用名优先(Tan)、没有常用名用法定名(Fixture Second Issuer);不是员工 / 没有职位 / 没有码 —— 同样的拒绝、同样的码。
    v_j2 := pg_temp.f264_get(u_iss, $q$SELECT coa_issuer()$q$);
    IF v_j2 ->> 'name' IS DISTINCT FROM v_snap -> 'issuer' ->> 'name' OR v_j2 ->> 'position' IS DISTINCT FROM v_snap -> 'issuer' ->> 'position'
       OR (v_j2 ->> 'employee_id')::uuid IS DISTINCT FROM e_iss THEN
        RAISE EXCEPTION 'FIXTURE 264 ISSUER: coa_issuer() must name the same person issue_coa froze (% vs %)', v_j2, v_snap -> 'issuer'; END IF;
    v_j2 := pg_temp.f264_get(u_iss2, $q$SELECT coa_issuer()$q$);
    IF v_j2 ->> 'name' IS DISTINCT FROM 'Fixture Second Issuer' OR v_j2 ->> 'position' IS DISTINCT FROM 'Quality Manager' THEN
        RAISE EXCEPTION 'FIXTURE 264 ISSUER: no preferred name falls back to the legal name, got %', v_j2; END IF;
    v_msg := pg_temp.f264_do(u_noemp, $q$SELECT coa_issuer()$q$);
    IF v_msg IS DISTINCT FROM 'COA_ISSUER_NOT_AN_EMPLOYEE' THEN RAISE EXCEPTION 'FIXTURE 264 ISSUER: not an employee, got %', v_msg; END IF;
    v_msg := pg_temp.f264_do(u_nopos, $q$SELECT coa_issuer()$q$);
    IF v_msg IS DISTINCT FROM 'COA_ISSUER_POSITION_MISSING|Fixture No Position' THEN RAISE EXCEPTION 'FIXTURE 264 ISSUER: no position, got %', v_msg; END IF;
    v_msg := pg_temp.f264_do(u_view, $q$SELECT coa_issuer()$q$);
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.issue_coa%' THEN RAISE EXCEPTION 'FIXTURE 264 ISSUER: a reader without the code is refused, got %', v_msg; END IF;
    -- N38 冻进证书:ob_n2(两层血缘)签一张
    PERFORM pg_temp.f264_assay(ob_n2, 'ZZ264-N2-OURS', 'ours', true, d - 1, 6, 20);
    c4 := (pg_temp.f264_get(u_iss, format($q$SELECT issue_coa(%L)$q$, ob_n2)) ->> 'coa_id')::uuid;
    IF (SELECT snapshot -> 'chemistry' ->> 'certainty' FROM certificates_of_analysis WHERE id = c4) IS DISTINCT FROM 'not_recorded'
       OR (SELECT (snapshot -> 'chemistry' ->> 'inbound_leaves')::int FROM certificates_of_analysis WHERE id = c4) IS DISTINCT FROM 3 THEN
        RAISE EXCEPTION 'FIXTURE 264 ISSUE: N38 is frozen into the certificate (not recorded over three leaves)'; END IF;
    -- 点名的单:客户名、合同号、验收限与判定(越限、报告被接受 → 放)
    v_j := pg_temp.f264_get(u_iss, format($q$SELECT issue_coa(%L, %L)$q$, ob_lim2, soA));
    c2 := (v_j ->> 'coa_id')::uuid;
    SELECT snapshot INTO v_snap FROM certificates_of_analysis WHERE id = c2;
    IF v_snap -> 'sales_order' ->> 'customer_name' IS DISTINCT FROM 'f264 Buyer Pte Ltd'
       OR v_snap -> 'sales_order' ->> 'code' IS DISTINCT FROM (SELECT code FROM sales_orders WHERE id = soA)
       OR v_snap -> 'sales_order' ->> 'contract_code' IS DISTINCT FROM (SELECT code FROM contracts WHERE id = conA)
       OR v_snap -> 'sales_order' ->> 'quality_limit_basis' IS DISTINCT FROM 'per_parameter'
       OR v_snap -> 'sales_order' -> 'limits' IS DISTINCT FROM '[{"max_value": 8, "min_value": null, "name": "Moisture", "parameter": "moisture_pct", "unit": "%"}]'::jsonb
       OR jsonb_array_length(v_snap -> 'sales_order' -> 'judgements') IS DISTINCT FROM 1
       OR v_snap -> 'sales_order' -> 'judgements' -> 0 ->> 'result' IS DISTINCT FROM 'above_max'
       OR (v_snap -> 'sales_order' -> 'judgements' -> 0 ->> 'value')::numeric IS DISTINCT FROM 9.5
       OR v_snap -> 'indicators' IS DISTINCT FROM '[{"code": "d50_um", "name": "Particle size D50", "unit": "µm", "value": 12}]'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 264 ISSUE: an order adds the customer, the contract, its limits and the judgement; the indicators are stated, got %', v_snap; END IF;
    -- 一批 × 一张单只有一张活的;不同的单各自一张
    v_msg := pg_temp.f264_do(u_iss, format($q$SELECT issue_coa(%L, %L)$q$, ob_lim2, soA));
    IF v_msg IS DISTINCT FROM 'COA_ALREADY_ISSUED|' || (SELECT code FROM certificates_of_analysis WHERE id = c2) THEN
        RAISE EXCEPTION 'FIXTURE 264 ISSUE: one live certificate per batch × order, got %', v_msg; END IF;
    v_msg := pg_temp.f264_do(u_iss, format($q$SELECT issue_coa(%L)$q$, ob_x));
    IF v_msg IS DISTINCT FROM 'COA_ALREADY_ISSUED|' || v_code THEN RAISE EXCEPTION 'FIXTURE 264 ISSUE: one live certificate per batch with no order, got %', v_msg; END IF;
    c3 := (pg_temp.f264_get(u_iss, format($q$SELECT issue_coa(%L, %L)$q$, ob_g, soB)) ->> 'coa_id')::uuid;
    c5 := (pg_temp.f264_get(u_iss, format($q$SELECT issue_coa(%L, %L)$q$, ob_g, soC)) ->> 'coa_id')::uuid;
    IF (SELECT governing_assay_id FROM certificates_of_analysis WHERE id = c3) IS DISTINCT FROM a1
       OR (SELECT snapshot -> 'sales_order' ->> 'customer_name' FROM certificates_of_analysis WHERE id = c3) IS DISTINCT FROM 'f264 Second Buyer'
       OR (SELECT snapshot -> 'sales_order' -> 'limits' FROM certificates_of_analysis WHERE id = c3) IS DISTINCT FROM '[]'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 264 ISSUE: two orders on one batch each get their own certificate (the resolved dispute governs; no limits declared)'; END IF;

    -- ══════════════ FROZEN ══════════════
    RAISE NOTICE 'fixture 264 · FROZEN';
    SELECT snapshot INTO v_snap FROM certificates_of_analysis WHERE id = c2;
    PERFORM pg_temp.f264_assay(ob_lim2, 'ZZ264-LIM2-LATER', 'ours', true, d, 5, 30);
    UPDATE customers SET legal_name = 'f264 Renamed Buyer' WHERE id = v_cust;
    INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source) VALUES (ob_lim2, 'mn', 3, 'manual')
        ON CONFLICT DO NOTHING;
    IF (SELECT snapshot FROM certificates_of_analysis WHERE id = c2) IS DISTINCT FROM v_snap THEN
        RAISE EXCEPTION 'FIXTURE 264 FROZEN: live changes never reach the snapshot'; END IF;
    v_j := pg_temp.f264_get(u_view, format($q$SELECT coa_certificate_data(%L, %L)$q$, ob_lim2, soA));
    IF v_j -> 'sales_order' ->> 'customer_name' IS DISTINCT FROM 'f264 Renamed Buyer' OR v_j -> 'assay' ->> 'code' IS DISTINCT FROM 'ZZ264-LIM2-LATER' THEN
        RAISE EXCEPTION 'FIXTURE 264 FROZEN: the preview reads live data (that is why it is not the certificate), got %', v_j -> 'assay' ->> 'code'; END IF;
    BEGIN
        UPDATE certificates_of_analysis SET snapshot = snapshot || '{"x":1}'::jsonb WHERE id = c2;
        RAISE EXCEPTION 'FIXTURE 264 FROZEN: the snapshot cannot be rewritten';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE 'COA_ISSUED_IMMUTABLE|%' THEN RAISE; END IF;
    END;
    BEGIN
        DELETE FROM certificates_of_analysis WHERE id = c2;
        RAISE EXCEPTION 'FIXTURE 264 FROZEN: a certificate cannot be deleted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE 'COA_NO_DELETE|%' THEN RAISE; END IF;
    END;
    -- 员工直连写:没有写策略 —— 改是一次碰不到任何行的空操作(RLS 的定义,AGENTS.md ALERT-1),插按名被 RLS 拒
    PERFORM pg_temp.f264_do(u_all, format($q$UPDATE certificates_of_analysis SET status = 'void', void_reason = 'x', voided_at = now(), voided_by = auth.uid() WHERE id = %L$q$, c2));
    IF (SELECT status FROM certificates_of_analysis WHERE id = c2) IS DISTINCT FROM 'issued' THEN
        RAISE EXCEPTION 'FIXTURE 264 FROZEN: staff cannot void a certificate by writing the table'; END IF;
    v_msg := pg_temp.f264_do(u_all, format($q$INSERT INTO certificates_of_analysis (code, output_batch_id, governing_assay_id, issued_at, issued_by, snapshot)
                                              VALUES ('COA-1999-0001', %L, %L, now(), auth.uid(), '{}'::jsonb)$q$, ob_x, a5));
    IF v_msg NOT LIKE '%row-level security%' THEN RAISE EXCEPTION 'FIXTURE 264 FROZEN: staff cannot insert a certificate directly, got %', v_msg; END IF;

    -- ══════════════ BYTES ══════════════
    RAISE NOTICE 'fixture 264 · BYTES';
    v_msg := pg_temp.f264_do(u_iss, format($q$SELECT record_coa_issue(%L, 'elsewhere/x.pdf', %L)$q$, c2, repeat('a', 64)));
    IF v_msg NOT LIKE 'COA_ISSUE_PATH_INVALID|%' THEN RAISE EXCEPTION 'FIXTURE 264 BYTES: the path must sit under the certificate id, got %', v_msg; END IF;
    v_msg := pg_temp.f264_do(u_iss, format($q$SELECT record_coa_issue(%L, %L, 'not-a-hash')$q$, c2, c2 || '/x.pdf'));
    IF v_msg NOT LIKE '%coa_issues_sha256_check%' THEN RAISE EXCEPTION 'FIXTURE 264 BYTES: the sha256 must be 64 hex characters, got %', v_msg; END IF;
    v_msg := pg_temp.f264_do(u_view, format($q$SELECT record_coa_issue(%L, %L, %L)$q$, c2, c2 || '/x.pdf', repeat('a', 64)));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.issue_coa%' THEN RAISE EXCEPTION 'FIXTURE 264 BYTES: recording bytes needs action.issue_coa, got %', v_msg; END IF;
    PERFORM pg_temp.f264_get(u_iss, format($q$SELECT record_coa_issue(%L, %L, %L)$q$, c2, c2 || '/x.pdf', repeat('A', 64)));
    IF (SELECT sha256 FROM coa_issues WHERE coa_id = c2) IS DISTINCT FROM repeat('a', 64) THEN RAISE EXCEPTION 'FIXTURE 264 BYTES: the digest is stored lower-case'; END IF;
    v_msg := pg_temp.f264_do(u_iss, format($q$SELECT record_coa_issue(%L, %L, %L)$q$, c2, c2 || '/y.pdf', repeat('b', 64)));
    IF v_msg NOT LIKE 'COA_BYTES_ALREADY_RECORDED|%' THEN RAISE EXCEPTION 'FIXTURE 264 BYTES: one set of bytes per certificate, got %', v_msg; END IF;
    BEGIN
        UPDATE coa_issues SET sha256 = repeat('c', 64) WHERE coa_id = c2;
        RAISE EXCEPTION 'FIXTURE 264 BYTES: the byte record is append-only';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE 'APPEND_ONLY|coa_issues|update' THEN RAISE; END IF;
    END;

    -- ══════════════ VOID ══════════════
    RAISE NOTICE 'fixture 264 · VOID';
    IF has_function_privilege('authenticated', 'public.void_coa_internal(uuid, text, uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 264 VOID: there is no one-step void for staff'; END IF;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx264-l2', 'f', 'f', true) RETURNING id INTO r_l2;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_l2, c
      FROM unnest(ARRAY['module.finance.view', 'data.view_prices', 'module.inventory.view', 'module.output.view', 'module.purchasing.view',
                        'data.view_purchase_prices', 'module.hr.view', 'data.view_pay', 'module.inbound.view', 'module.sales.view',
                        'module.pricing.view', 'module.suppliers.view', 'module.customers.view']) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u_mon, r_l2), (u_iss_alt, r_l2);
    -- 一次举旗只授权一行(guard_approvals_policy_write 用完即焚)—— 四列一条语句
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level1_role_code = 'fx264-l2', approval_level2_role_code = 'fx264-l2', approval_threshold_base = 1000,
                                approvals_enabled = true;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '', true);
    v_msg := pg_temp.f264_do(u_view, format($q$SELECT submit_coa_void_request(%L, 'x')$q$, c2));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.issue_coa%' THEN RAISE EXCEPTION 'FIXTURE 264 VOID: raising needs action.issue_coa, got %', v_msg; END IF;
    v_msg := pg_temp.f264_do(u_iss, format($q$SELECT submit_coa_void_request(%L, '  ')$q$, c2));
    IF v_msg NOT LIKE 'WAREHOUSE_REQUEST_REASON_REQUIRED|coa_void|%' THEN RAISE EXCEPTION 'FIXTURE 264 VOID: a reason is required, got %', v_msg; END IF;
    v_j := pg_temp.f264_get(u_iss, format($q$SELECT submit_coa_void_request(%L, 'A newer final assay was received')$q$, c2));
    wr := (v_j ->> 'request_id')::uuid;
    IF v_j ->> 'status' IS DISTINCT FROM 'submitted' OR (SELECT status FROM certificates_of_analysis WHERE id = c2) IS DISTINCT FROM 'issued'
       OR (SELECT kind || ':' || coa_id FROM warehouse_requests WHERE id = wr) IS DISTINCT FROM 'coa_void:' || c2
       OR (SELECT snapshot ->> 'coa_code' FROM warehouse_requests WHERE id = wr) IS DISTINCT FROM (SELECT code FROM certificates_of_analysis WHERE id = c2) THEN
        RAISE EXCEPTION 'FIXTURE 264 VOID: approvals on → the request waits and the certificate stays issued, got %', v_j; END IF;
    v_msg := pg_temp.f264_do(u_iss, format($q$SELECT submit_coa_void_request(%L, 'again')$q$, c2));
    IF v_msg NOT LIKE 'WAREHOUSE_REQUEST_OPEN|%' THEN RAISE EXCEPTION 'FIXTURE 264 VOID: one waiting request per certificate, got %', v_msg; END IF;
    -- 提单人这个人的另一个账号(持二级审批角色)批不了
    v_msg := pg_temp.f264_do(u_iss_alt, format($q$SELECT decide_warehouse_request(%L, true, NULL)$q$, wr));
    IF v_msg NOT LIKE 'SELF_APPROVAL_FORBIDDEN|raiser%' THEN RAISE EXCEPTION 'FIXTURE 264 VOID: the raiser (by person) never approves, got %', v_msg; END IF;
    v_j := pg_temp.f264_get(u_mon, format($q$SELECT decide_warehouse_request(%L, true, NULL)$q$, wr));
    IF v_j ->> 'status' IS DISTINCT FROM 'approved'
       OR (SELECT status || ':' || void_reason || ':' || voided_by FROM certificates_of_analysis WHERE id = c2) IS DISTINCT FROM 'void:A newer final assay was received:' || u_iss
       OR (SELECT snapshot FROM certificates_of_analysis WHERE id = c2) IS DISTINCT FROM v_snap
       OR (SELECT sha256 FROM coa_issues WHERE coa_id = c2) IS DISTINCT FROM repeat('a', 64) THEN
        RAISE EXCEPTION 'FIXTURE 264 VOID: the CFO-level approval voids it; voided_by is the raiser; snapshot and bytes are kept, got %', v_j; END IF;
    v_msg := pg_temp.f264_do(u_iss, format($q$SELECT submit_coa_void_request(%L, 'again')$q$, c2));
    IF v_msg NOT LIKE 'COA_NOT_ISSUED|%|void' THEN RAISE EXCEPTION 'FIXTURE 264 VOID: a void certificate cannot be voided again, got %', v_msg; END IF;
    BEGIN
        UPDATE certificates_of_analysis SET status = 'issued' WHERE id = c2;
        RAISE EXCEPTION 'FIXTURE 264 VOID: a void certificate never comes back';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE 'COA_ALREADY_VOID|%' THEN RAISE; END IF;
    END;
    -- 重开一张:新号,旧的指向它
    v_j := pg_temp.f264_get(u_iss2, format($q$SELECT issue_coa(%L, %L)$q$, ob_lim2, soA));
    IF v_j ->> 'replaces' IS DISTINCT FROM (SELECT code FROM certificates_of_analysis WHERE id = c2)
       OR (SELECT replaced_by_coa_id FROM certificates_of_analysis WHERE id = c2) IS DISTINCT FROM (v_j ->> 'coa_id')::uuid
       OR v_j ->> 'code' = (SELECT code FROM certificates_of_analysis WHERE id = c2)
       OR v_j -> 'snapshot' -> 'issuer' ->> 'name' IS DISTINCT FROM 'Fixture Second Issuer'
       OR v_j -> 'snapshot' -> 'sales_order' ->> 'customer_name' IS DISTINCT FROM 'f264 Renamed Buyer' THEN
        RAISE EXCEPTION 'FIXTURE 264 VOID: a replacement gets a new number and the void one links to it, got %', v_j; END IF;
    BEGIN
        UPDATE certificates_of_analysis SET replaced_by_coa_id = c1 WHERE id = c2;
        RAISE EXCEPTION 'FIXTURE 264 VOID: the replacement link is set once';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE 'COA_ISSUED_IMMUTABLE|%' THEN RAISE; END IF;
    END;
    -- 驳回 · 撤回:什么都不作废
    wr := (pg_temp.f264_get(u_iss, format($q$SELECT submit_coa_void_request(%L, 'Wrong order named')$q$, c3)) ->> 'request_id')::uuid;
    PERFORM pg_temp.f264_get(u_mon, format($q$SELECT decide_warehouse_request(%L, false, 'The certificate is right')$q$, wr));
    wr := (pg_temp.f264_get(u_iss, format($q$SELECT submit_coa_void_request(%L, 'Wrong order named')$q$, c3)) ->> 'request_id')::uuid;
    PERFORM pg_temp.f264_get(u_iss2, format($q$SELECT withdraw_warehouse_request(%L, 'Raised twice')$q$, wr));
    IF (SELECT status FROM certificates_of_analysis WHERE id = c3) IS DISTINCT FROM 'issued' THEN
        RAISE EXCEPTION 'FIXTURE 264 VOID: a rejected or withdrawn request voids nothing'; END IF;
    -- 提单人之外没有二级审批人 → 提交就拒:二级换成一个只有提单人这个人(另一个账号)持的角色(不删授权 —— 最后一个管理员的守卫会拦)
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx264-solo', 'f', 'f', true) RETURNING id INTO r_l2;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_l2, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'fx264-l2';
    INSERT INTO user_roles (user_id, role_id) VALUES (u_iss_alt, r_l2);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level2_role_code = 'fx264-solo';
    v_msg := pg_temp.f264_do(u_iss, format($q$SELECT submit_coa_void_request(%L, 'x')$q$, c3));
    IF v_msg NOT LIKE 'WAREHOUSE_REQUEST_NO_OTHER_DECIDER|%' THEN
        RAISE EXCEPTION 'FIXTURE 264 VOID: nobody but the raiser could approve → refused at submission, got %', v_msg; END IF;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level2_role_code = 'fx264-l2';

    -- ══════════════ ARM ══════════════
    RAISE NOTICE 'fixture 264 · ARM';
    v_n := (pg_temp.f264_get(u_iss, format($q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'coa_facts_changed' AND item_id = %L$q$, c3)))::text::bigint;
    IF v_n IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FIXTURE 264 ARM: nothing changed since issue → no reminder'; END IF;
    PERFORM pg_temp.f264_assay(ob_g, 'ZZ264-G-LATER', 'ours', true, d, 6, 20);
    v_j := pg_temp.f264_get(u_iss, format($q$SELECT to_jsonb(o) FROM operations_now o WHERE item_type = 'coa_facts_changed' AND item_id = %L$q$, c3));
    IF v_j IS NULL OR v_j ->> 'subject' IS DISTINCT FROM (SELECT code FROM output_batches WHERE id = ob_g) || ' · ZZ264-G-LATER'
       OR v_j ->> 'item_code' IS DISTINCT FROM (SELECT code FROM certificates_of_analysis WHERE id = c3) THEN
        RAISE EXCEPTION 'FIXTURE 264 ARM: a newer assay on the batch shows the certificate, got %', v_j; END IF;
    v_n := (pg_temp.f264_get(u_view, format($q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'coa_facts_changed' AND item_id = %L$q$, c3)))::text::bigint;
    IF v_n IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FIXTURE 264 ARM: only holders of action.issue_coa see it'; END IF;
    -- 一张报告也会让它出现(另一张证书,没有新化验)。属主直插、opened_at = clock_timestamp()(理由同 f264_assay 的 created_at)
    INSERT INTO nonconformance_reports (code, output_batch_id, source, description, opened_by, opened_at)
    VALUES (next_ncr_code(d), ob_n2, 'customer_complaint', 'Buyer reports caking', u_qe, clock_timestamp());
    IF NOT EXISTS (SELECT 1 FROM pg_temp.f264_get(u_iss, format($q$SELECT to_jsonb(array_agg(o.subject)) FROM operations_now o WHERE item_type = 'coa_facts_changed' AND item_id = %L$q$, c4)) x(v)
                    WHERE x.v ->> 0 LIKE '% · NCR-%') THEN
        RAISE EXCEPTION 'FIXTURE 264 ARM: an NCR opened after issue shows the certificate'; END IF;
    -- 作废之后它消失
    wr := (pg_temp.f264_get(u_iss, format($q$SELECT submit_coa_void_request(%L, 'Newer assay received')$q$, c3)) ->> 'request_id')::uuid;
    PERFORM pg_temp.f264_get(u_mon, format($q$SELECT decide_warehouse_request(%L, true, NULL)$q$, wr));
    v_n := (pg_temp.f264_get(u_iss, format($q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'coa_facts_changed' AND item_id = %L$q$, c3)))::text::bigint;
    IF v_n IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FIXTURE 264 ARM: a voided certificate leaves the list'; END IF;

    -- ══════════════ TRAIL ══════════════
    RAISE NOTICE 'fixture 264 · TRAIL';
    SELECT count(*) INTO v_n FROM change_log WHERE table_name = 'certificates_of_analysis' AND row_key = jsonb_build_object('id', c2)
       AND op IN ('INSERT', 'UPDATE');
    IF v_n < 3 THEN RAISE EXCEPTION 'FIXTURE 264 TRAIL: issue, void and the replacement link are each logged, got %', v_n; END IF;
    IF NOT EXISTS (SELECT 1 FROM change_log WHERE table_name = 'coa_issues' AND op = 'INSERT' AND new ->> 'coa_id' = c2::text) THEN
        RAISE EXCEPTION 'FIXTURE 264 TRAIL: the byte record is logged'; END IF;
    v_t := (pg_temp.f264_get(u_all, format($q$SELECT to_jsonb(array_agg(DISTINCT t.table_name)) FROM record_trail('coa', %L, 50) t$q$, c2::text)))::text;
    IF COALESCE(v_t, '') NOT LIKE '%certificates_of_analysis%' OR COALESCE(v_t, '') NOT LIKE '%coa_issues%' OR COALESCE(v_t, '') NOT LIKE '%warehouse_requests%' THEN
        RAISE EXCEPTION 'FIXTURE 264 TRAIL: the coa trail has the certificate, its bytes and its void request'; END IF;
    v_t := (pg_temp.f264_get(u_all, format($q$SELECT to_jsonb(array_agg(DISTINCT t.table_name)) FROM record_trail('output_batch', %L, 200) t$q$, ob_lim2::text)))::text;
    IF COALESCE(v_t, '') NOT LIKE '%certificates_of_analysis%' OR COALESCE(v_t, '') NOT LIKE '%coa_issues%' THEN
        RAISE EXCEPTION 'FIXTURE 264 TRAIL: the output batch trail shows its certificate and bytes'; END IF;
    v_t := (pg_temp.f264_get(u_all, format($q$SELECT to_jsonb(array_agg(DISTINCT t.table_name)) FROM record_trail('inbound_batch', %L, 200) t$q$, ib1::text)))::text;
    IF COALESCE(v_t, '') NOT LIKE '%certificates_of_analysis%' THEN
        RAISE EXCEPTION 'FIXTURE 264 TRAIL: an inbound batch trail shows certificates on the outputs made from it'; END IF;
    -- 读:跟着产出批的查看码;anon 读不到新的读面
    v_msg := pg_temp.f264_do(u_none, format($q$SELECT 1/(SELECT count(*) FROM certificates_of_analysis WHERE id = %L)$q$, c2));
    IF v_msg NOT LIKE '%division by zero%' THEN RAISE EXCEPTION 'FIXTURE 264 TRAIL: without module.output.view a certificate is not read, got %', v_msg; END IF;
    v_n := (pg_temp.f264_get(u_view, format($q$SELECT to_jsonb(count(*)) FROM coa_rows WHERE id = %L AND customer_name = 'f264 Renamed Buyer'$q$, c2)))::text::bigint;
    IF v_n IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'FIXTURE 264 TRAIL: coa_rows names the customer for an output reader (the label follows the document)'; END IF;
    IF has_table_privilege('anon', 'public.coa_rows', 'SELECT') OR has_table_privilege('anon', 'public.certificates_of_analysis', 'SELECT')
       OR has_table_privilege('anon', 'public.coa_issues', 'SELECT') THEN
        RAISE EXCEPTION 'FIXTURE 264 TRAIL: anon reads nothing new'; END IF;

    RAISE NOTICE 'FIXTURE 264 全部通过:REG · N38 · GOV · NEVER · REFUSE · ISSUE · ISSUER · FROZEN · BYTES · VOID · ARM · TRAIL';
END $$;

ROLLBACK;
