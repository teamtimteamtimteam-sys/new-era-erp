-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 272 —— 一个关了账的月份冻成一份合规包:八节都在、不带任何受伤的细节与钱;开着的月份冻不了;重出一份要理由、旧的一个字不动;
--   它的 PDF 签发档只追加;没冻的已关账月份有一条提醒、月结页有一行警告;V26 / V27 是两行待补的值
--   (MES-8b-1,2026-10-17;MES-0 Q82;MES-8 Step 0 Q14 – Q18 · Q21 – Q24 · Q28,Tim)
-- ═══════════════════════════════════════════════════════════════════════════
-- 臂:
--   REG      三张新表都在;设定那一行在、四样全空(Q18);包与签发档空;单据登记 CPK(读码 module.compliance.view,落点 /compliance/packs);
--            两个新码:module.compliance.view 与 action.compliance_pack(声明 module.compliance.view);动作码蕴含查看码(每一个角色);
--            admin 持目录里每一个码;审计主语 compliance_pack(成员:签发档)与 compliance_settings;三张新表进变更记录,豁免仍 8 —— MES-9b 起是 9;
--            没有遮蔽的列(规则仍 119);F16 仍是 0
--   V2627    设定空着时 V26、V27 各一行(只给持 module.compliance.view 的人);给它们要 action.compliance_pack;格式没有频率 / 方法没有目标按名拒;
--            给全之后两行都消失,预览的第 7、8 节照原样印出给的那几句、不算任何东西
--   GATE     预览要 module.compliance.view;冻、重出与记 PDF 要 action.compliance_pack;月结那一行认 module.finance.view 或 module.compliance.view
--   LOCK     开着的月份冻不了:COMPLIANCE_PACK_MONTH_NOT_LOCKED|<YYYY-MM>|<锁到>,一行都没写;月份为空按名拒
--   SECT     冻下来的 payload 就是那一刻的预览;八节:物料平衡(全厂与工序)· 库存滚动 · 执照在效与月末按类别的在库、上限、没分类的吨数、当月的上限判定 ·
--            当月的事故(编号、种类、要不要通报、通报与书面报告的日子)· 环境监测(限值抄下、判词)· 巡检(合格 / 不合格项数)与月末还开着的发现 ·
--            NEA 申报 not_set(V26)· 欧盟回收效率 not_set(V27)带着这个月的投入与产出
--   NOINJ    payload 里没有任何受伤的细节(受伤的人、外人的名字、伤情、处置、损失天数)、没有人写的经过与处置、没有负责人的名字,
--            也没有钱(价、金额、工资)—— 拿那几段字逐个在 payload 全文里找,一个都找不到
--   NUM      编号 CPK-YYYY-MM;重出:没理由按名拒;带理由 → CPK-YYYY-MM-2,旧的落 superseded_*(谁、何时、理由),旧的 payload 一个字不动
--            (之后又记了一件事故:旧的不动、新的那一份带着它);一个没有在册包的月份写了理由按名拒;改与删对谁都按名拒
--   PDF      记一版 PDF:路径不在包的目录下 · 哈希不是 64 位十六进制 —— 按名拒;大写哈希存成小写;同一串字节再记按名拒;另一串 → 第 2 版;
--            被取代的那一份按名拒;签发档改与删按名拒;会话里直连写包与签发档 → RLS 拒
--   ARM      compliance_pack_not_frozen:从 system_start_date 那个月起,每一个已关账而没有在册包的月一行(只给持 action.compliance_pack 的人);
--            冻了那个月就消失;月结那一行 compliance_pack_month_status 说 locked 与包的编号
--   (PDF 只从冻下来的 payload 渲染、取档重算哈希、对不上 409 —— 那是路由的行为,由 scripts/check-pdf-routes.mjs 的 CPK 三格管;桶在线上证明里)
--
-- 自带数据(README 第 2 条);期间锁与 system_start_date 自己设(README 第 4 条:不继承);事故、巡检与监测经它们自己的函数记(以一个持全部码的人)。
-- 全部判定写成 IF (…) IS NOT FALSE —— 一个 NULL 也是红。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f272_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

CREATE FUNCTION pg_temp.f272_do(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM pg_temp.f272_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f272_as(NULL);
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f272_as(NULL);
    RETURN SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f272_get(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.f272_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f272_as(NULL);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f272_as(NULL);
    RAISE;
END;
$f$;

CREATE FUNCTION pg_temp.f272_user(p_label text, p_codes text[]) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE u uuid := gen_random_uuid(); r uuid;
BEGIN
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES (u, 'fx272-' || p_label || '@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx272-' || p_label, 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r, c FROM unnest(p_codes) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);
    RETURN u;
END;
$f$;

CREATE FUNCTION pg_temp.f272_expect(p_arm text, p_got text, p_like text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    IF (p_got IS NULL OR p_got NOT LIKE p_like) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 % expected % got %', p_arm, p_like, COALESCE(p_got, '<null>');
    END IF;
END;
$f$;

DO $$
DECLARE
    u_all uuid; u_cv uuid; u_cp uuid; u_fin uuid; u_none uuid;
    M date := date_trunc('month', CURRENT_DATE - interval '1 month')::date;      -- 上一个整月
    ME date; P date; PE date; v_ym text; v_pym text;
    v_mat uuid; s uuid; ib uuid; ob uuid; run uuid; e1 uuid; lic uuid; tpl uuid; rn uuid; rn2 uuid; i_inj uuid; i_late uuid;
    v_p jsonb; v_p2 jsonb; v_j jsonb; v_r jsonb; v_msg text; v_n bigint; v_txt text; v_code1 text; v_code2 text;
    pk1 uuid; pk2 uuid; v_stored jsonb;
BEGIN
    ME := (M + interval '1 month - 1 day')::date;
    P  := (M - interval '1 month')::date;                                             -- 再前一个月
    PE := (M - interval '1 day')::date;
    v_ym := to_char(M, 'YYYY-MM'); v_pym := to_char(P, 'YYYY-MM');
    PERFORM pg_temp.f272_as(NULL);
    -- 期间锁与起点自己设(README 第 4 条):起点是前一个月的一号,先只锁到 M 的一号(M 还开着)
    UPDATE finance_settings SET system_start_date = P, locked_before = M;

    u_all  := pg_temp.f272_user('all', ARRAY(SELECT code FROM permissions));
    u_cv   := pg_temp.f272_user('cv', ARRAY['module.compliance.view']);
    u_cp   := pg_temp.f272_user('cp', ARRAY['module.compliance.view', 'action.compliance_pack']);
    u_fin  := pg_temp.f272_user('fin', ARRAY['module.finance.view']);
    u_none := pg_temp.f272_user('none', ARRAY['module.safety.view', 'module.processing.view']);

    -- ══════════════ REG ══════════════
    RAISE NOTICE 'fixture 272 · REG';
    IF (EXISTS (SELECT 1 FROM unnest(ARRAY['compliance_settings', 'compliance_packs', 'compliance_pack_issues']) t WHERE to_regclass('public.' || t) IS NULL)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 REG: the three new tables'; END IF;
    IF ((SELECT count(*) FROM compliance_settings) <> 1
        OR EXISTS (SELECT 1 FROM compliance_settings WHERE nea_return_format IS NOT NULL OR nea_return_frequency IS NOT NULL
                                                      OR eu_efficiency_method IS NOT NULL OR eu_efficiency_targets IS NOT NULL)
        OR EXISTS (SELECT 1 FROM compliance_packs) OR EXISTS (SELECT 1 FROM compliance_pack_issues)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 REG: one settings row with V26 and V27 empty, no pack, no issue (Q18 — nothing is guessed)'; END IF;
    IF (document_type_prefix('compliance_pack') <> 'CPK' OR (SELECT route FROM document_types WHERE key = 'compliance_pack') <> '/compliance/packs'
        OR (SELECT view_permission FROM document_types WHERE key = 'compliance_pack') <> ARRAY['module.compliance.view']) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 REG: document type CPK'; END IF;
    IF (NOT EXISTS (SELECT 1 FROM permissions WHERE code = 'module.compliance.view' AND category = 'module')
        OR (SELECT requires_view_any FROM permissions WHERE code = 'action.compliance_pack') IS DISTINCT FROM ARRAY['module.compliance.view']) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 REG: module.compliance.view, and action.compliance_pack declaring it'; END IF;
    IF (EXISTS (SELECT 1 FROM role_permissions rp JOIN permissions p ON p.code = rp.permission_code
                 WHERE p.requires_view_any IS NOT NULL AND cardinality(p.requires_view_any) > 0
                   AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any)))) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 REG: an action code is held without its declared view (action implies view)'; END IF;
    IF (EXISTS (SELECT 1 FROM roles r WHERE r.code = 'admin' AND EXISTS (SELECT 1 FROM permissions p WHERE p.code IN ('module.compliance.view', 'action.compliance_pack')
                 AND NOT EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.role_id = r.id AND rp.permission_code = p.code))))
        IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 REG: admin holds the two new codes (the admin role holds every code)'; END IF;
    IF (NOT EXISTS (SELECT 1 FROM trail_subjects() t WHERE t.subject = 'compliance_pack' AND t.root_table = 'compliance_packs' AND t.view_codes = ARRAY['module.compliance.view'])
        OR NOT EXISTS (SELECT 1 FROM trail_subjects() t WHERE t.subject = 'compliance_settings' AND t.root_table = 'compliance_settings')
        OR NOT EXISTS (SELECT 1 FROM trail_subject_members() x WHERE x.subject = 'compliance_pack' AND x.table_name = 'compliance_pack_issues' AND x.home)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 REG: trail subjects compliance_pack (with its issues) and compliance_settings'; END IF;
    v_j := change_log_coverage_gaps();
    IF (jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 10) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 REG: change-log coverage (gaps 0, exclusions 9): %', v_j; END IF;
    IF (EXISTS (SELECT 1 FROM change_log_mask_rules() WHERE table_name LIKE 'compliance_%') OR (SELECT count(*) FROM change_log_mask_rules()) <> 132) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 REG: no masked column in MES-8b-1 (rules stay 119 from that cut; 129 since GOLIVE-1 row 12 added the settlement and contract-term prices; 132 since GOLIVE-2 added the frozen contract copy (2) and the terms-request snapshot (1))'; END IF;
    SELECT string_agg(c.relname || ':' || g.r || ':' || p.priv, ', ') INTO v_txt
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     CROSS JOIN (VALUES ('anon'), ('authenticated')) g(r) CROSS JOIN (VALUES ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) p(priv)
     WHERE n.nspname = 'public' AND c.relkind = 'v' AND has_table_privilege(g.r, c.oid, p.priv);
    IF (v_txt IS NOT NULL) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 272 REG: F16 — no view may carry a write grant: %', v_txt; END IF;

    -- ══════════════ 布景:M 这个月里的一炉、执照、NEA 类别、事故、监测、巡检 ══════════════
    PERFORM pg_temp.f272_as(u_all);
    INSERT INTO nea_waste_categories (code, name_en, name_zh, is_active, sort_order) VALUES ('FX272-CAT', 'Fixture 272 batteries', 'f', true, 1);
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, nea_waste_category_code)
    VALUES ('FX272-M', 'fixture 272 material', 'battery_material', true, 'black_mass', 'end_of_life', 'FX272-CAT') RETURNING id INTO v_mat;
    INSERT INTO suppliers (code, legal_name, country, counterparty_type) VALUES ('FX272-S', 'fixture 272 supplier', 'SG', 'goods_supplier') RETURNING id INTO s;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('FX272-IB', v_mat, s, 2000, 2000, 'kg', M + 1, 'other', 'fixture 272 自带数据') RETURNING id INTO ib;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) VALUES (ib, 'discharged_verified');
    INSERT INTO processing_runs (code, status, allocation_basis, operation_type_code, process_date, total_input, total_output, started_at, ended_at, shift_code)
    VALUES ('FX272-R', 'committed', 'weight', 'manual_disassembly', M + 2, 500, 450, (M + 2)::timestamptz + interval '9 hours',
            (M + 2)::timestamptz + interval '11 hours', 'day') RETURNING id INTO run;
    INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed) VALUES (run, ib, 500);
    INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, run_id, business_date) VALUES (ib, 'processing_consume', -500, run, M + 2);
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date) VALUES ('FX272-OB', v_mat, 450, 450, M + 2) RETURNING id INTO ob;
    INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code) VALUES (ob, 'discharged_verified');
    INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced, allocated_cost_base, unit_cost_base, cost_incomplete) VALUES (run, ob, 450, 900, 2, false);
    INSERT INTO company_compliance (cert_type_code, cert_no, issuing_body, valid_from, valid_until, status, approved_storage_limit_tonnes)
    VALUES ('gwdf', 'FX272-WDL', 'NEA', P, ME + 400, 'active', 500) RETURNING id INTO lic;
    INSERT INTO licence_storage_limits (licence_id, category_code, limit_tonnes) VALUES (lic, 'FX272-CAT', 1.5);
    INSERT INTO receipt_ceiling_checks (inbound_batch_id, licence_id, category_code, outcome, quantity_t, on_hand_before_t, limit_t, checked_on)
    VALUES (ib, lic, 'FX272-CAT', 'within', 2, 0, 3, M + 1);
    e1 := gen_random_uuid();
    INSERT INTO employees (id, code, legal_name, preferred_name, employment_type, work_category, hire_date)
    VALUES (e1, 'FX272-E1', 'Fixture272 Inspector Legal', 'Fixture272 Inspector', 'full_time', 'office', DATE '2020-01-01');
    -- 一件要通报的工伤(带着全部受伤的细节)与它的通报、书面报告
    v_j := record_incident('injury', (M + 10)::timestamptz + interval '10 hours', 'FX272-WHAT a cell vented', 'FX272-ACTION first aid', true,
                           p_responsible_name => 'FX272-RESPONSIBLE Lead', p_injured_person_name => 'FX272-INJURED Visitor',
                           p_injury_nature => 'FX272-NATURE burn', p_injury_treatment => 'FX272-TREATMENT hospital', p_days_lost => 3);
    i_inj := (v_j ->> 'incident_id')::uuid; v_code1 := v_j ->> 'code';
    PERFORM record_incident_update(i_inj, 'nea_notified', (M + 10)::timestamptz + interval '12 hours', 'FX272-NEA-REF');
    -- 监测:一个参数(限值 10,max)、两条结果(5 没超、12 超标 —— 超标那一条在同一笔事务里开一件事故)
    INSERT INTO laboratories (code, name_en, name_zh) VALUES ('FX272LAB', 'Fixture 272 lab', 'f');
    INSERT INTO environmental_parameters (code, name_en, name_zh, unit, limit_value, limit_basis, is_active) VALUES ('fx272_pm', 'Fixture 272 particulates', 'f', 'mg/m3', 10, 'max', true);
    PERFORM record_environmental_result('fx272_pm', 'stack 1', M + 5, 'FX272LAB', 'R-1', 5);
    PERFORM record_environmental_result('fx272_pm', 'stack 1', M + 6, 'FX272LAB', 'R-2', 12, true, 'FX272-ENV-ACTION fan reset');
    -- 巡检:一张清单三项;一次巡检(第 2 项不合格)带一条发现(月末还开着);下个月才记的一条发现不进 M 的包
    tpl := (save_inspection_template(NULL, 'FX272-T', 'Fixture 272 checklist', 'Warehouse', '["a", "b", "c"]'::jsonb) ->> 'template_id')::uuid;
    rn := (record_inspection_run(tpl, (M + 3)::timestamptz + interval '10 hours', e1,
           '[{"position": 1, "result": "pass"}, {"position": 2, "result": "fail", "note": "FX272-NOTE"}, {"position": 3, "result": "na"}]'::jsonb) ->> 'run_id')::uuid;
    PERFORM record_inspection_finding(rn, 2, 'FX272-CORRECTIVE replace extinguisher', e1, ME + 10);
    rn2 := (record_inspection_run(tpl, now() - interval '1 hour', e1,
            '[{"position": 1, "result": "fail", "note": "x"}, {"position": 2, "result": "pass"}, {"position": 3, "result": "pass"}]'::jsonb) ->> 'run_id')::uuid;
    PERFORM record_inspection_finding(rn2, 1, 'FX272-LATER finding', e1, NULL);
    PERFORM pg_temp.f272_as(NULL);

    -- ══════════════ V2627 ══════════════
    RAISE NOTICE 'fixture 272 · V2627';
    v_j := pg_temp.f272_get(u_cv, $q$SELECT jsonb_agg(value_code ORDER BY value_code) FROM pending_values WHERE value_code IN ('V26', 'V27')$q$);
    IF (v_j <> '["V26", "V27"]'::jsonb) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 272 V2627: one row each from day one, got %', v_j; END IF;
    v_n := pg_temp.f272_get(u_none, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code IN ('V26', 'V27')$q$)::bigint;
    IF (v_n <> 0) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 272 V2627: V26 / V27 are behind module.compliance.view (got %)', v_n; END IF;
    PERFORM pg_temp.f272_expect('V2627', pg_temp.f272_do(u_cv, $q$SELECT set_compliance_settings('F', 'monthly', NULL, NULL)$q$), 'PERMISSION_DENIED|action.compliance_pack');
    PERFORM pg_temp.f272_expect('V2627', pg_temp.f272_do(u_cp, $q$SELECT set_compliance_settings('F', ' ', NULL, NULL)$q$), 'COMPLIANCE_SETTINGS_PAIR_INCOMPLETE|V26');
    PERFORM pg_temp.f272_expect('V2627', pg_temp.f272_do(u_cp, $q$SELECT set_compliance_settings(NULL, NULL, 'method', NULL)$q$), 'COMPLIANCE_SETTINGS_PAIR_INCOMPLETE|V27');
    IF (EXISTS (SELECT 1 FROM compliance_settings WHERE nea_return_format IS NOT NULL OR eu_efficiency_method IS NOT NULL)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 V2627: a refused setting wrote nothing'; END IF;
    -- (给全那一步放在冻包之后 —— 先冻的那一份要印出 not_set)

    -- ══════════════ GATE ══════════════
    RAISE NOTICE 'fixture 272 · GATE';
    PERFORM pg_temp.f272_expect('GATE', pg_temp.f272_do(u_none, format($q$SELECT compliance_pack_data(%L)$q$, M)), 'PERMISSION_DENIED|module.compliance.view');
    PERFORM pg_temp.f272_expect('GATE', pg_temp.f272_do(u_cv, format($q$SELECT compliance_pack_data(%L)$q$, M)), 'OK');
    PERFORM pg_temp.f272_expect('GATE', pg_temp.f272_do(u_cv, format($q$SELECT freeze_compliance_pack(%L)$q$, M)), 'PERMISSION_DENIED|action.compliance_pack');
    PERFORM pg_temp.f272_expect('GATE', pg_temp.f272_do(u_none, format($q$SELECT compliance_pack_month_status(%L)$q$, M)), 'PERMISSION_DENIED|module.finance.view · module.compliance.view');
    PERFORM pg_temp.f272_expect('GATE', pg_temp.f272_do(u_fin, format($q$SELECT compliance_pack_month_status(%L)$q$, M)), 'OK');
    PERFORM pg_temp.f272_expect('GATE', pg_temp.f272_do(u_cp, format($q$INSERT INTO compliance_packs (code, period_month, period_start, period_end, locked_before_at_freeze, payload) VALUES ('CPK-2001-01', '2001-01-01', '2001-01-01', '2001-01-31', '2001-02-01', '{}')$q$)), '%row-level security%');

    -- ══════════════ LOCK ══════════════
    RAISE NOTICE 'fixture 272 · LOCK';
    PERFORM pg_temp.f272_expect('LOCK', pg_temp.f272_do(u_cp, format($q$SELECT freeze_compliance_pack(%L)$q$, M)), 'COMPLIANCE_PACK_MONTH_NOT_LOCKED|' || v_ym || '|' || M::text);
    PERFORM pg_temp.f272_expect('LOCK', pg_temp.f272_do(u_cp, $q$SELECT freeze_compliance_pack(NULL)$q$), 'COMPLIANCE_PACK_PERIOD_REQUIRED');
    IF (EXISTS (SELECT 1 FROM compliance_packs)) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 272 LOCK: a refused freeze writes nothing'; END IF;
    v_j := pg_temp.f272_get(u_fin, format($q$SELECT compliance_pack_month_status(%L)$q$, M));
    IF ((v_j ->> 'locked')::boolean IS NOT FALSE OR jsonb_typeof(v_j -> 'pack_code') <> 'null') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 LOCK: an open month reads locked false, no pack, got %', v_j; END IF;
    -- 关账:锁到 M 的下一个月一号
    UPDATE finance_settings SET locked_before = ME + 1;

    -- ══════════════ ARM(冻之前)══════════════
    RAISE NOTICE 'fixture 272 · ARM';
    v_j := pg_temp.f272_get(u_cp, $q$SELECT jsonb_agg(item_code ORDER BY item_code) FROM operations_now WHERE item_type = 'compliance_pack_not_frozen'$q$);
    IF (v_j <> jsonb_build_array(v_pym, v_ym)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 ARM: each locked month since system_start_date without a pack is one row (%, %), got %', v_pym, v_ym, v_j; END IF;
    v_n := pg_temp.f272_get(u_cv, $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'compliance_pack_not_frozen'$q$)::bigint;
    IF (v_n <> 0) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 272 ARM: the reminder is for whoever freezes packs (action.compliance_pack), got %', v_n; END IF;

    -- ══════════════ SECT ══════════════
    RAISE NOTICE 'fixture 272 · SECT';
    v_p := pg_temp.f272_get(u_cv, format($q$SELECT compliance_pack_data(%L)$q$, M));
    v_r := pg_temp.f272_get(u_cp, format($q$SELECT freeze_compliance_pack(%L, 'first')$q$, M));
    pk1 := (v_r ->> 'pack_id')::uuid; v_code2 := v_r ->> 'code';
    SELECT payload INTO v_stored FROM compliance_packs WHERE id = pk1;
    IF (v_stored <> v_p) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 272 SECT: the frozen payload is exactly the preview of that moment (one implementation)'; END IF;
    IF (v_stored ->> 'month' <> v_ym OR (v_stored ->> 'month_locked')::boolean IS NOT TRUE OR v_stored -> 'company' ->> 'legal_name' IS NULL) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 SECT: month, locked, letterhead, got %', v_stored ->> 'month'; END IF;
    -- 1 物料平衡:全厂一份与工序一份,投入 500
    IF ((SELECT count(*) FROM jsonb_array_elements(v_stored -> 'processing_balance') x WHERE x ->> 'scope' = 'plant' AND x ->> 'line' = 'input' AND (x ->> 'qty_kg')::numeric >= 500) <> 1
        OR (SELECT count(*) FROM jsonb_array_elements(v_stored -> 'processing_balance') x WHERE x ->> 'scope' = 'operation' AND x ->> 'operation_type_code' = 'manual_disassembly' AND x ->> 'line' = 'input') <> 1)
        IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 272 SECT 1: the processing balance, plant-wide and per operation, got %', v_stored -> 'processing_balance'; END IF;
    -- 2 库存滚动:kg 一行(各列带符号:收货 ≥ 2000、消耗 ≤ −500);期末 = 期初 + 各列之和
    SELECT x INTO v_j FROM jsonb_array_elements(v_stored -> 'stock_rollforward') x WHERE x ->> 'unit' = 'kg';
    IF ((v_j ->> 'received')::numeric < 2000 OR (v_j ->> 'consumed')::numeric > -500
        OR (v_j ->> 'closing')::numeric <> (v_j ->> 'opening')::numeric + (v_j ->> 'received')::numeric + (v_j ->> 'produced')::numeric + (v_j ->> 'consumed')::numeric
           + (v_j ->> 'sold')::numeric + (v_j ->> 'written_off')::numeric + (v_j ->> 'adjusted')::numeric + (v_j ->> 'voided')::numeric
           + (v_j ->> 'issued_to_maintenance')::numeric + (v_j ->> 'moved')::numeric) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 SECT 2: the stock roll-forward of the month, got %', v_j; END IF;
    -- 3 执照:月末在效的那一张;月末按类别 1.5 + 0.45 = 1.95 t(> 上限 1.5)、当月一次 within 的判定
    IF (v_stored -> 'licence' -> 'in_force' ->> 'cert_no' <> 'FX272-WDL') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 SECT 3: the licence in force at month end, got %', v_stored -> 'licence' -> 'in_force'; END IF;
    SELECT x INTO v_j FROM jsonb_array_elements(v_stored -> 'licence' -> 'on_hand_by_category') x WHERE x ->> 'category_code' = 'FX272-CAT';
    IF ((v_j ->> 'tonnes')::numeric <> 1.95 OR (v_j ->> 'limit_tonnes')::numeric <> 1.5 OR v_j ->> 'state' <> 'above_ceiling') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 SECT 3: on hand by NEA category at month end (1.5 t inbound + 0.45 t output) against its ceiling, got %', v_j; END IF;
    IF ((SELECT sum((x ->> 'checks')::int) FROM jsonb_array_elements(v_stored -> 'licence' -> 'ceiling_checks') x WHERE x ->> 'outcome' = 'within') <> 1) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 SECT 3: the month''s ceiling checks by outcome, got %', v_stored -> 'licence' -> 'ceiling_checks'; END IF;
    -- 4 事故:工伤一件(要通报、通报了、书面报告还没交)+ 超标那一件
    SELECT x INTO v_j FROM jsonb_array_elements(v_stored -> 'incidents') x WHERE x ->> 'code' = v_code1;
    IF (v_j ->> 'kind_code' <> 'injury' OR (v_j ->> 'nea_reportable')::boolean IS NOT TRUE OR (v_j ->> 'notified_on')::date <> M + 10
        OR jsonb_typeof(v_j -> 'report_submitted_on') <> 'null' OR v_j ->> 'occurred_on' <> (M + 10)::text
        OR (SELECT count(*) FROM jsonb_array_elements(v_stored -> 'incidents')) <> 2) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 SECT 4: incidents with kind, NEA-reportable, notified and report dates, got %', v_stored -> 'incidents'; END IF;
    -- 5 环境监测:限值抄下,一条 within、一条 exceeds(带它开的那件事故)
    IF ((SELECT string_agg((x ->> 'judgement') || ':' || (x ->> 'limit_value') || ':' || (x ->> 'limit_basis') || ':' || ((x ->> 'incident_code') IS NOT NULL)::text, ',' ORDER BY x ->> 'sampled_on')
           FROM jsonb_array_elements(v_stored -> 'environmental') x) <> 'within:10:max:false,exceeds:10:max:true') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 SECT 5: environmental results with their limits and judgements, got %', v_stored -> 'environmental'; END IF;
    -- 6 巡检:当月一次(合格 1 · 不合格 1 · 不适用 1);月末还开着的发现一条(下个月记的那一条不在)
    IF ((SELECT count(*) FROM jsonb_array_elements(v_stored -> 'inspections' -> 'done')) <> 1
        OR (v_stored -> 'inspections' -> 'done' -> 0 ->> 'failed')::int <> 1 OR (v_stored -> 'inspections' -> 'done' -> 0 ->> 'passed')::int <> 1
        OR (v_stored -> 'inspections' -> 'done' -> 0 ->> 'not_applicable')::int <> 1
        OR (SELECT count(*) FROM jsonb_array_elements(v_stored -> 'inspections' -> 'findings_open_at_month_end')) <> 1
        OR v_stored -> 'inspections' -> 'findings_open_at_month_end' -> 0 ->> 'corrective_action' <> 'FX272-CORRECTIVE replace extinguisher') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 SECT 6: inspections done and findings open at month end, got %', v_stored -> 'inspections'; END IF;
    -- 7 · 8:not_set,带值码;第 8 节带着这个月的投入与产出
    IF (v_stored -> 'nea_return' <> '{"state": "not_set", "value_code": "V26"}'::jsonb
        OR v_stored -> 'eu_efficiency' ->> 'state' <> 'not_set' OR v_stored -> 'eu_efficiency' ->> 'value_code' <> 'V27'
        OR (v_stored -> 'eu_efficiency' -> 'masses' ->> 'input_kg')::numeric < 500
        OR jsonb_array_length(v_stored -> 'eu_efficiency' -> 'masses' -> 'outputs') < 1) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 SECT 7/8: NEA return not set (V26), EU efficiency not set (V27) beside the month''s masses, got % / %', v_stored -> 'nea_return', v_stored -> 'eu_efficiency'; END IF;

    -- ══════════════ NOINJ ══════════════
    RAISE NOTICE 'fixture 272 · NOINJ';
    v_txt := v_stored::text;
    IF (v_txt LIKE '%FX272-INJURED%' OR v_txt LIKE '%FX272-NATURE%' OR v_txt LIKE '%FX272-TREATMENT%' OR v_txt LIKE '%days_lost%' OR v_txt LIKE '%injur%_person%'
        OR v_txt LIKE '%FX272-WHAT%' OR v_txt LIKE '%FX272-ACTION%' OR v_txt LIKE '%FX272-RESPONSIBLE%' OR v_txt LIKE '%FX272-ENV-ACTION%'
        OR v_txt LIKE '%Fixture272 Inspector%' OR v_txt LIKE '%FX272-NOTE%') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 NOINJ: the pack carries no injury detail, no free text written about the incident and no person''s name'; END IF;
    IF (v_txt ~* '(price|amount|_base"|salary|pay_|cost)') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 NOINJ: the pack carries no money (no price, amount, cost or pay)'; END IF;

    -- ══════════════ NUM ══════════════
    RAISE NOTICE 'fixture 272 · NUM';
    IF (v_code2 <> 'CPK-' || v_ym) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 272 NUM: CPK-YYYY-MM, got %', v_code2; END IF;
    v_j := pg_temp.f272_get(u_fin, format($q$SELECT compliance_pack_month_status(%L)$q$, M));
    IF ((v_j ->> 'locked')::boolean IS NOT TRUE OR v_j ->> 'pack_code' <> v_code2) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 NUM: the month-end line now names the pack, got %', v_j; END IF;
    -- 冻之后又记了一件事故:旧的那一份一个字不动
    PERFORM pg_temp.f272_as(u_all);
    v_j := record_incident('near_miss', (M + 20)::timestamptz + interval '10 hours', 'x', 'y', false, p_responsible_name => 'Lead');
    i_late := (v_j ->> 'incident_id')::uuid;
    PERFORM pg_temp.f272_as(NULL);
    IF ((SELECT payload FROM compliance_packs WHERE id = pk1) <> v_stored) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 NUM: a frozen pack does not move when the live data does'; END IF;
    PERFORM pg_temp.f272_expect('NUM', pg_temp.f272_do(u_cp, format($q$SELECT freeze_compliance_pack(%L)$q$, M)), 'COMPLIANCE_PACK_SUPERSEDE_REASON_REQUIRED|' || v_code2);
    PERFORM pg_temp.f272_expect('NUM', pg_temp.f272_do(u_cp, format($q$SELECT freeze_compliance_pack(%L, NULL, 'why')$q$, P)), 'COMPLIANCE_PACK_REASON_WITHOUT_SUPERSEDE|' || v_pym);
    v_r := pg_temp.f272_get(u_cp, format($q$SELECT freeze_compliance_pack(%L, NULL, 'A near miss was recorded late')$q$, M));
    pk2 := (v_r ->> 'pack_id')::uuid;
    IF (v_r ->> 'code' <> 'CPK-' || v_ym || '-2' OR v_r ->> 'superseded' <> v_code2
        OR (SELECT superseded_by FROM compliance_packs WHERE id = pk1) <> pk2
        OR (SELECT superseded_reason FROM compliance_packs WHERE id = pk1) <> 'A near miss was recorded late'
        OR (SELECT superseded_at FROM compliance_packs WHERE id = pk1) IS NULL
        OR (SELECT payload FROM compliance_packs WHERE id = pk1) <> v_stored
        OR (SELECT jsonb_array_length(payload -> 'incidents') FROM compliance_packs WHERE id = pk2) <> 3) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 NUM: CPK-…-2 supersedes the first with the reason; the first keeps its payload; the new one carries the late incident, got %', v_r; END IF;
    v_msg := NULL; BEGIN UPDATE compliance_packs SET payload = '{}'::jsonb WHERE id = pk1; EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    PERFORM pg_temp.f272_expect('NUM', v_msg, 'COMPLIANCE_PACK_IMMUTABLE|update');
    v_msg := NULL; BEGIN UPDATE compliance_packs SET superseded_reason = 'rewritten' WHERE id = pk1; EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    PERFORM pg_temp.f272_expect('NUM', v_msg, 'COMPLIANCE_PACK_IMMUTABLE|update');
    v_msg := NULL; BEGIN DELETE FROM compliance_packs WHERE id = pk2; EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    PERFORM pg_temp.f272_expect('NUM', v_msg, 'COMPLIANCE_PACK_IMMUTABLE|delete');

    -- ══════════════ PDF ══════════════
    RAISE NOTICE 'fixture 272 · PDF';
    PERFORM pg_temp.f272_expect('PDF', pg_temp.f272_do(u_cv, format($q$SELECT record_compliance_pack_issue(%L, '%s/a.pdf', %L)$q$, pk2, pk2, repeat('a', 64))), 'PERMISSION_DENIED|action.compliance_pack');
    PERFORM pg_temp.f272_expect('PDF', pg_temp.f272_do(u_cp, format($q$SELECT record_compliance_pack_issue(%L, 'other/%s/a.pdf', %L)$q$, pk2, pk2, repeat('a', 64))), 'COMPLIANCE_PACK_ISSUE_PATH_INVALID|%');
    PERFORM pg_temp.f272_expect('PDF', pg_temp.f272_do(u_cp, format($q$SELECT record_compliance_pack_issue(%L, '%s/a.pdf', 'not-a-digest')$q$, pk2, pk2)), 'COMPLIANCE_PACK_SHA_INVALID');
    PERFORM pg_temp.f272_expect('PDF', pg_temp.f272_do(u_cp, format($q$SELECT record_compliance_pack_issue(%L, '%s/a.pdf', %L)$q$, pk1, pk1, repeat('a', 64))), 'COMPLIANCE_PACK_SUPERSEDED|' || v_code2 || '|%');
    PERFORM pg_temp.f272_expect('PDF', pg_temp.f272_do(u_cp, format($q$SELECT record_compliance_pack_issue(%L, '%s/a.pdf', %L)$q$, gen_random_uuid(), pk2, repeat('a', 64))), 'COMPLIANCE_PACK_NOT_FOUND|%');
    PERFORM pg_temp.f272_expect('PDF', pg_temp.f272_do(u_cp, format($q$SELECT record_compliance_pack_issue(%L, '%s/a.pdf', %L)$q$, pk2, pk2, repeat('AB', 32))), 'OK');
    IF ((SELECT sha256 FROM compliance_pack_issues WHERE pack_id = pk2 AND version = 1) <> repeat('ab', 32)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 PDF: an upper-case digest is stored lower-case, as version 1'; END IF;
    PERFORM pg_temp.f272_expect('PDF', pg_temp.f272_do(u_cp, format($q$SELECT record_compliance_pack_issue(%L, '%s/b.pdf', %L)$q$, pk2, pk2, repeat('ab', 32))), 'COMPLIANCE_PACK_BYTES_ALREADY_RECORDED|%|1');
    PERFORM pg_temp.f272_expect('PDF', pg_temp.f272_do(u_cp, format($q$SELECT record_compliance_pack_issue(%L, '%s/c.pdf', %L)$q$, pk2, pk2, repeat('c', 64))), 'OK');
    IF ((SELECT string_agg(version::text, ',' ORDER BY version) FROM compliance_pack_issues WHERE pack_id = pk2) <> '1,2') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 PDF: different bytes are the next version'; END IF;
    PERFORM pg_temp.f272_expect('PDF', pg_temp.f272_do(u_cp, format($q$INSERT INTO compliance_pack_issues (pack_id, version, file_path, sha256) VALUES (%L, 9, '%s/z.pdf', %L)$q$, pk2, pk2, repeat('d', 64))), '%row-level security%');
    v_msg := NULL; BEGIN UPDATE compliance_pack_issues SET sha256 = repeat('e', 64) WHERE pack_id = pk2; EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    PERFORM pg_temp.f272_expect('PDF', v_msg, 'COMPLIANCE_PACK_ISSUE_IMMUTABLE|update');
    v_msg := NULL; BEGIN DELETE FROM compliance_pack_issues WHERE pack_id = pk2; EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    PERFORM pg_temp.f272_expect('PDF', v_msg, 'COMPLIANCE_PACK_ISSUE_IMMUTABLE|delete');

    -- ══════════════ ARM(冻之后)══════════════
    RAISE NOTICE 'fixture 272 · ARM after';
    v_j := pg_temp.f272_get(u_cp, $q$SELECT jsonb_agg(item_code ORDER BY item_code) FROM operations_now WHERE item_type = 'compliance_pack_not_frozen'$q$);
    IF (v_j <> jsonb_build_array(v_pym)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 ARM: once a month is frozen it leaves the reminder (only % stays), got %', v_pym, v_j; END IF;

    -- ══════════════ V2627(给全之后)══════════════
    RAISE NOTICE 'fixture 272 · V2627 set';
    PERFORM pg_temp.f272_expect('V2627', pg_temp.f272_do(u_cp, $q$SELECT set_compliance_settings('NEA Form X', 'Monthly', 'Regulation (EU) 2023/1542 method', '70% by 2030')$q$), 'OK');
    v_n := pg_temp.f272_get(u_cv, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code IN ('V26', 'V27')$q$)::bigint;
    IF (v_n <> 0) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 272 V2627: both given → no row (got %)', v_n; END IF;
    v_p2 := pg_temp.f272_get(u_cv, format($q$SELECT compliance_pack_data(%L)$q$, M));
    IF (v_p2 -> 'nea_return' <> '{"state": "set", "value_code": "V26", "format": "NEA Form X", "frequency": "Monthly"}'::jsonb
        OR v_p2 -> 'eu_efficiency' ->> 'state' <> 'set' OR (v_p2 -> 'eu_efficiency' ->> 'computed')::boolean IS NOT FALSE) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 V2627: the preview prints what was given and computes nothing (Q28), got % / %', v_p2 -> 'nea_return', v_p2 -> 'eu_efficiency'; END IF;
    IF ((SELECT payload FROM compliance_packs WHERE id = pk2) -> 'nea_return' ->> 'state' <> 'not_set') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 272 V2627: setting V26 later does not rewrite a frozen pack'; END IF;

    RAISE NOTICE 'FIXTURE 272 全部通过: REG · V2627 · GATE · LOCK · ARM · SECT · NOINJ · NUM · PDF';
END
$$;

ROLLBACK;
