-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 275 —— 一个供应商门户账号 = 一家供应商 + 它的一位联系人;它只够得着自己那一家,撤销了下一次调用就拒;
--   员工的令牌一个字节都不变(MES-9a,2026-10-19;MES-9 Step 0 Q2 · Q3 · Q5–Q11 · Q20 · Q21 · Q24 · Q26 · Q28,Tim)
-- ═══════════════════════════════════════════════════════════════════════════
-- 臂:
--   CODE     action.manage_portal_users 是一个动作码,声明 module.suppliers.view;admin 持它
--   LINK     开一个门户账号只经 portal_user_create_link,门 action.manage_portal_users(只持 module.suppliers.view 的人按名拒);
--            联系人不属于这家 / 邮箱不是这位联系人的 / 这位联系人已经有一个没撤销的 → 各自按名拒
--   SEP      一个门户账号永远不持角色、永远不是员工(授角色 / 挂档案 / 挂额外账号 → 按名拒);反过来,一个持角色或挂着档案的账号开不了门户
--   HOOK     access token hook:重建库里【每一个】角色的持有人、一个全码会话、一个没有角色的会话、一个只挂 floor_display 的会话 ——
--            返回的 event 与传进去的逐字节相同;一个门户账号 → claims.role = supplier_portal、别的键一个不动;
--            函数里的失败(user_id 不是 uuid · supabase_auth_admin 读不到表)→ 原样返回,不抛;supabase_auth_admin 照迁移的授法读得到
--   EVERY    supplier_portal 能执行的【每一支】public 函数(从目录里枚举 —— 判词八保证目录 = 基线;一支没有用例的函数让本臂红;
--            MES-9b 的四支按名交给 fixture 276 的 EVERY 臂,名单与目录对不上也红):
--            两家供应商各自只看见自己那一家(对方的编号、名字、邮箱一个字都没有);员工角色(authenticated)调 → 42501;
--            角色对了而令牌声明不对 → PORTAL_ROLE_REQUIRED;会话不在 → PORTAL_SESSION_ENDED;不是门户账号 → PORTAL_NOT_A_PORTAL_ACCOUNT;
--            被封 → PORTAL_ACCESS_REVOKED
--   REVOKE   撤销:理由必填;不持码按名拒;撤销删掉它的会话;它的下一次调用 PORTAL_ACCESS_REVOKED,另一家照常;再撤 PORTAL_ALREADY_REVOKED
--   EXPORT   portal_export_my_data 只有调用者自己的:它的联系人(没有员工写的内部备注)、链接、账号、供应商
--   ANON     匿名化:没撤销按名拒;撤销之后联系人名字换成 Anonymised、邮箱电话清空、软删;变更记录里关于它的影像涂掉;账号 id 留着
--   TRAIL    审计记录里门户账号做的事:trail_actor → 「portal」+ 供应商名;portal_actor_labels 只回门户账号;供应商的审计记录列出门户链接
--   VIEW     supplier_portal_accounts 对 module.suppliers.view 列出两家的账号、对没有码的人 0 行;user_directory 不列门户账号
--   VALUES   V38 · V40 两支待补的值(action.manage_permissions)在;set_account_setting 给了 V38 那一行就没了;形状不对 / 键不认识按名拒
--   LOG      两张新表进变更记录,豁免是 9(MES-9b 加了门户下载记录)
--   GRANTS   portal_* 只给 supplier_portal(authenticated · anon 调不到);hook 只给 supabase_auth_admin;portal_require_link 谁都不给
-- 前提:db/platform-prelude.sql 建了 supplier_portal · supabase_auth_admin · authenticator 与 auth.sessions。自带数据(README 第 2 条)。
-- 注入(故障注入的记录在 docs/handbacks/MES-9a.md):db/scripts/2026-10-19-mes9a-fixture-injections.py。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f275_claims(p_user uuid, p_role text, p_sid uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN ''
                           ELSE jsonb_build_object('sub', p_user, 'role', p_role, 'session_id', p_sid)::text END, true)
$f$;

-- 以 (账号, 数据库角色, 令牌里的 role 声明, 会话) 跑一句,回结果的文字;出错回 'ERR|<sqlstate>|<消息>'
CREATE FUNCTION pg_temp.f275_call(p_user uuid, p_dbrole text, p_claim text, p_sid uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v text;
BEGIN
    PERFORM pg_temp.f275_claims(p_user, p_claim, p_sid);
    EXECUTE format('SET LOCAL ROLE %I', p_dbrole);
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f275_claims(NULL, NULL, NULL);
    RETURN COALESCE(v, '<null>');
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f275_claims(NULL, NULL, NULL);
    RETURN 'ERR|' || SQLSTATE || '|' || SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f275_who(p_codes text[]) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE r uuid; u uuid := gen_random_uuid();
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx275-' || left(u::text, 8), 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT DISTINCT r, c FROM unnest(p_codes) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);
    RETURN u;
END;
$f$;

CREATE FUNCTION pg_temp.f275_event(p_user text) RETURNS jsonb
LANGUAGE sql AS $f$
    SELECT jsonb_build_object('user_id', p_user, 'authentication_method', 'password',
        'claims', jsonb_build_object('aud', 'authenticated', 'exp', 2000000000, 'iat', 1900000000, 'sub', p_user, 'email', 'x@test.local',
                                     'phone', '', 'role', 'authenticated', 'aal', 'aal1', 'session_id', '00000000-0000-4000-8000-000000000275',
                                     'is_anonymous', false, 'app_metadata', jsonb_build_object('provider', 'email'),
                                     'user_metadata', jsonb_build_object('must_change_password', true), 'amr', '[]'::jsonb))
$f$;

-- the hook must never raise: a raise is reported as the HOOK arm's failure, by name
CREATE FUNCTION pg_temp.f275_hook(p_event jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $f$
BEGIN
    RETURN public.portal_access_token_hook(p_event);
EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'FIXTURE 275 HOOK: the hook raised (%) — it must fall back to the unchanged claims', SQLERRM;
END;
$f$;

DO $f275$
DECLARE
    s_a uuid; s_b uuid; c_a uuid; c_b uuid; c_r uuid; c_e uuid;
    u_a uuid := gen_random_uuid(); u_b uuid := gen_random_uuid(); u_r uuid := gen_random_uuid(); u_e uuid := gen_random_uuid();
    sid_a uuid := gen_random_uuid(); sid_b uuid := gen_random_uuid();
    u_mgr uuid; u_view uuid; u_perm uuid; u_none uuid; u uuid;
    l_a uuid; l_b uuid;
    v text; v_n bigint; v_j jsonb; v_ev jsonb; v_fn text; r record;
    v_cases jsonb := jsonb_build_object(
        'portal_me()', 'SELECT public.portal_me()::text',
        'portal_export_my_data()', 'SELECT public.portal_export_my_data()::text');
    -- MES-9b(2026-10-19):这四支的两家供应商用例在 fixture 276 的 EVERY 臂(它们要单据、收货与存储);276 断言两支 fixture 合起来正好覆盖目录。
    --   不在这里、也不在这份名单上的一支 → 本臂照旧红。
    -- MES-9c(2026-10-20):再加五支,它们的两家供应商用例在 fixture 277 的 EVERY 臂(它们要申请、V39 与存储)。名单名字仍叫 v_9b(=「后面几刀的」)。
    v_9b text[] := ARRAY['portal_documents()', 'portal_deliveries()', 'portal_document_open(p_kind text, p_issue_id uuid)',
                         'portal_can_read_object(p_bucket text, p_name text)',
                         'portal_certificates()',
                         'portal_submission_begin(p_cert_type text, p_file_name text, p_file_type text, p_file_size bigint, p_cert_no text, p_valid_from date, p_valid_until date)',
                         'portal_submission_finish(p_submission_id uuid)', 'portal_submission_abandon(p_submission_id uuid)',
                         'portal_can_upload_object(p_bucket text, p_name text)'];
    v_9b_seen int := 0;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supplier_portal') OR to_regclass('auth.sessions') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 275 SETUP: the prelude did not create supplier_portal / auth.sessions on this rebuild';
    END IF;

    -- ── data of its own ─────────────────────────────────────────────────────
    INSERT INTO suppliers (code, legal_name, country, counterparty_type) VALUES ('FX275-SA', 'fixture 275 supplier A', 'SG', 'goods_supplier') RETURNING id INTO s_a;
    INSERT INTO suppliers (code, legal_name, country, counterparty_type) VALUES ('FX275-SB', 'fixture 275 supplier B', 'SG', 'goods_supplier') RETURNING id INTO s_b;
    INSERT INTO counterparty_contacts (supplier_id, name, email, phone, notes) VALUES (s_a, 'Ada FX275', 'ada.fx275@a.test', '+65 1111 0001', 'FX275-INTERNAL-NOTE-A') RETURNING id INTO c_a;
    INSERT INTO counterparty_contacts (supplier_id, name, email, phone, notes) VALUES (s_b, 'Bea FX275', 'bea.fx275@b.test', '+65 2222 0002', 'FX275-INTERNAL-NOTE-B') RETURNING id INTO c_b;
    INSERT INTO counterparty_contacts (supplier_id, name, email) VALUES (s_a, 'Ron FX275', 'ron.fx275@a.test') RETURNING id INTO c_r;
    INSERT INTO counterparty_contacts (supplier_id, name, email) VALUES (s_a, 'Eve FX275', 'eve.fx275@a.test') RETURNING id INTO c_e;
    INSERT INTO auth.users (id, email, email_confirmed_at, raw_user_meta_data) VALUES
        (u_a, 'ada.fx275@a.test', now(), '{"must_change_password": true}'), (u_b, 'bea.fx275@b.test', now(), '{}'),
        (u_r, 'ron.fx275@a.test', now(), '{}'), (u_e, 'eve.fx275@a.test', now(), '{}');
    INSERT INTO auth.sessions (id, user_id) VALUES (sid_a, u_a), (sid_b, u_b);
    u_mgr  := pg_temp.f275_who(ARRAY['action.manage_portal_users', 'module.suppliers.view']);
    u_view := pg_temp.f275_who(ARRAY['module.suppliers.view']);
    u_perm := pg_temp.f275_who(ARRAY['action.manage_permissions']);
    u_none := gen_random_uuid();

    -- ── CODE ───────────────────────────────────────────────────────────────
    IF NOT EXISTS (SELECT 1 FROM permissions WHERE code = 'action.manage_portal_users' AND category = 'action'
                    AND requires_view_any = ARRAY['module.suppliers.view']) THEN
        RAISE EXCEPTION 'FIXTURE 275 CODE: action.manage_portal_users must be an action code declaring module.suppliers.view'; END IF;
    IF NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles ro ON ro.id = rp.role_id
                    WHERE ro.code = 'admin' AND rp.permission_code = 'action.manage_portal_users') THEN
        RAISE EXCEPTION 'FIXTURE 275 CODE: admin does not hold action.manage_portal_users'; END IF;

    -- ── LINK ───────────────────────────────────────────────────────────────
    v := pg_temp.f275_call(u_view, 'authenticated', 'authenticated', NULL, format('SELECT public.portal_user_create_link(%L, %L, %L)::text', u_a, s_a, c_a));
    IF v NOT LIKE 'ERR|%PERMISSION_DENIED%' THEN RAISE EXCEPTION 'FIXTURE 275 LINK: a suppliers viewer created a portal account (%)', v; END IF;
    v := pg_temp.f275_call(u_mgr, 'authenticated', 'authenticated', NULL, format('SELECT public.portal_user_create_link(%L, %L, %L)::text', u_a, s_b, c_a));
    IF v NOT LIKE 'ERR|%PORTAL_CONTACT_NOT_OF_SUPPLIER%' THEN RAISE EXCEPTION 'FIXTURE 275 LINK: another supplier''s contact was accepted (%)', v; END IF;
    v := pg_temp.f275_call(u_mgr, 'authenticated', 'authenticated', NULL, format('SELECT public.portal_user_create_link(%L, %L, %L)::text', u_b, s_a, c_a));
    IF v NOT LIKE 'ERR|%PORTAL_EMAIL_NOT_CONTACT%' THEN RAISE EXCEPTION 'FIXTURE 275 LINK: an account whose email is not the contact''s was accepted (%)', v; END IF;
    v := pg_temp.f275_call(u_mgr, 'authenticated', 'authenticated', NULL, format('SELECT public.portal_user_create_link(%L, %L, %L)::text', u_a, s_a, c_a));
    IF v LIKE 'ERR|%' THEN RAISE EXCEPTION 'FIXTURE 275 LINK: the code holder could not create A (%)', v; END IF;
    l_a := v::uuid;
    v := pg_temp.f275_call(u_mgr, 'authenticated', 'authenticated', NULL, format('SELECT public.portal_user_create_link(%L, %L, %L)::text', u_b, s_b, c_b));
    IF v LIKE 'ERR|%' THEN RAISE EXCEPTION 'FIXTURE 275 LINK: the code holder could not create B (%)', v; END IF;
    l_b := v::uuid;
    v := pg_temp.f275_call(u_mgr, 'authenticated', 'authenticated', NULL, format('SELECT public.portal_user_create_link(%L, %L, %L)::text', u_a, s_a, c_a));
    IF v NOT LIKE 'ERR|%PORTAL_CONTACT_ALREADY_LINKED%' THEN RAISE EXCEPTION 'FIXTURE 275 LINK: a second live account for one contact (%)', v; END IF;
    v := pg_temp.f275_call(u_mgr, 'authenticated', 'authenticated', NULL, 'INSERT INTO public.supplier_portal_users (user_id, supplier_id, contact_id) VALUES (gen_random_uuid(), gen_random_uuid(), gen_random_uuid()) RETURNING id::text');
    IF v NOT LIKE 'ERR|%' THEN RAISE EXCEPTION 'FIXTURE 275 LINK: a direct insert by a staff session went through'; END IF;

    -- ── LOG (before anything that reads the change log: the trail, the anonymisation) ──
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 10 THEN
        RAISE EXCEPTION 'FIXTURE 275 LOG: change-log coverage %', v_j; END IF;
    IF NOT EXISTS (SELECT 1 FROM change_log WHERE table_name = 'supplier_portal_users' AND row_key ->> 'id' = l_a::text AND op = 'INSERT') THEN
        RAISE EXCEPTION 'FIXTURE 275 LOG: the portal link is not change-logged'; END IF;

    -- ── SEP ────────────────────────────────────────────────────────────────
    BEGIN
        INSERT INTO user_roles (user_id, role_id) SELECT u_a, id FROM roles WHERE code = 'admin';
        RAISE EXCEPTION 'FIXTURE 275 SEP: a portal account was granted a role';
    EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE '%PORTAL_ACCOUNT_NO_ROLES%' THEN RAISE; END IF; END;
    BEGIN
        INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id)
        VALUES (gen_random_uuid(), 'FX275-E1', 'FX275 Employee', 'full_time', 'office', DATE '2020-01-01', u_a);
        RAISE EXCEPTION 'FIXTURE 275 SEP: a portal account was linked to an employee';
    EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE '%PORTAL_ACCOUNT_NO_EMPLOYEE%' THEN RAISE; END IF; END;
    BEGIN
        INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date)
        VALUES ('00000000-0000-4000-8000-0000000002e1', 'FX275-E2', 'FX275 Employee 2', 'full_time', 'office', DATE '2020-01-01');
        INSERT INTO employee_accounts (user_id, employee_id) VALUES (u_a, '00000000-0000-4000-8000-0000000002e1');
        RAISE EXCEPTION 'FIXTURE 275 SEP: a portal account became an additional account';
    EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE '%PORTAL_ACCOUNT_NO_EMPLOYEE%' THEN RAISE; END IF; END;
    INSERT INTO user_roles (user_id, role_id) SELECT u_r, id FROM roles WHERE code = 'admin';
    v := pg_temp.f275_call(u_mgr, 'authenticated', 'authenticated', NULL, format('SELECT public.portal_user_create_link(%L, %L, %L)::text', u_r, s_a, c_r));
    IF v NOT LIKE 'ERR|%PORTAL_ACCOUNT_HAS_ROLE%' THEN RAISE EXCEPTION 'FIXTURE 275 SEP: an account holding a role got a portal link (%)', v; END IF;
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id)
    VALUES (gen_random_uuid(), 'FX275-E3', 'FX275 Employee 3', 'full_time', 'office', DATE '2020-01-01', u_e);
    v := pg_temp.f275_call(u_mgr, 'authenticated', 'authenticated', NULL, format('SELECT public.portal_user_create_link(%L, %L, %L)::text', u_e, s_a, c_e));
    IF v NOT LIKE 'ERR|%PORTAL_ACCOUNT_IS_EMPLOYEE%' THEN RAISE EXCEPTION 'FIXTURE 275 SEP: an employee account got a portal link (%)', v; END IF;

    -- ── HOOK ───────────────────────────────────────────────────────────────
    -- every role on the rebuild, held by an account of its own (with an auth.users row, as on live)
    FOR r IN SELECT id, code FROM roles WHERE deleted_at IS NULL ORDER BY code LOOP
        u := gen_random_uuid();
        INSERT INTO auth.users (id, email) VALUES (u, 'fx275-' || left(u::text, 8) || '@test.local');
        INSERT INTO user_roles (user_id, role_id) VALUES (u, r.id);
        v_ev := pg_temp.f275_event(u::text);
        IF pg_temp.f275_hook(v_ev) IS DISTINCT FROM v_ev THEN
            RAISE EXCEPTION 'FIXTURE 275 HOOK: the claims of a % holder changed', r.code; END IF;
    END LOOP;
    FOREACH u IN ARRAY ARRAY[u_mgr, u_view, u_perm, u_none, pg_temp.f275_who(ARRAY(SELECT code FROM permissions))] LOOP
        v_ev := pg_temp.f275_event(u::text);
        IF pg_temp.f275_hook(v_ev) IS DISTINCT FROM v_ev THEN
            RAISE EXCEPTION 'FIXTURE 275 HOOK: a staff / no-role session''s claims changed'; END IF;
    END LOOP;
    v_ev := pg_temp.f275_event(u_a::text);
    v_j := pg_temp.f275_hook(v_ev);
    IF v_j #>> '{claims,role}' IS DISTINCT FROM 'supplier_portal' OR (v_j #- '{claims,role}') IS DISTINCT FROM (v_ev #- '{claims,role}') THEN
        RAISE EXCEPTION 'FIXTURE 275 HOOK: a portal account''s token is not exactly the input with role = supplier_portal (%)', v_j; END IF;
    v_ev := pg_temp.f275_event('not-a-uuid');
    IF pg_temp.f275_hook(v_ev) IS DISTINCT FROM v_ev THEN
        RAISE EXCEPTION 'FIXTURE 275 HOOK: an internal failure (bad user_id) did not fall back to the unchanged claims'; END IF;
    -- as the identity Supabase Auth uses: reads the table through its policy and grant
    SET LOCAL ROLE supabase_auth_admin;
    v_j := pg_temp.f275_hook(pg_temp.f275_event(u_a::text));
    RESET ROLE;
    IF v_j #>> '{claims,role}' IS DISTINCT FROM 'supplier_portal' THEN
        RAISE EXCEPTION 'FIXTURE 275 HOOK: supabase_auth_admin cannot read the portal link'; END IF;
    BEGIN
        REVOKE SELECT ON public.supplier_portal_users FROM supabase_auth_admin;
        SET LOCAL ROLE supabase_auth_admin;
        v_ev := pg_temp.f275_event(u_a::text);
        v_j := pg_temp.f275_hook(v_ev);
        RESET ROLE;
        IF v_j IS DISTINCT FROM v_ev THEN
            RAISE EXCEPTION 'FIXTURE 275 HOOK: a failure inside the hook did not return the unchanged event'; END IF;
        RAISE EXCEPTION 'f275-undo';
    EXCEPTION WHEN OTHERS THEN
        RESET ROLE;
        IF SQLERRM <> 'f275-undo' THEN RAISE; END IF;
    END;

    -- ── EVERY ──────────────────────────────────────────────────────────────
    v_n := 0;
    FOR r IN SELECT p.oid::regprocedure::text AS sig, p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS key
               FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'public' AND has_function_privilege('supplier_portal', p.oid, 'EXECUTE') ORDER BY 1 LOOP
        IF NOT v_cases ? r.key AND r.key = ANY (v_9b) THEN
            v_9b_seen := v_9b_seen + 1;
            CONTINUE;
        END IF;
        v_n := v_n + 1;
        IF NOT v_cases ? r.key THEN
            RAISE EXCEPTION 'FIXTURE 275 EVERY: % is executable by supplier_portal and has no two-supplier case here or in fixture 276', r.sig; END IF;
        v_fn := v_cases ->> r.key;
        -- A sees A, not B; B sees B, not A
        v := pg_temp.f275_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, v_fn);
        IF v LIKE 'ERR|%' OR v NOT LIKE '%FX275-SA%' OR v LIKE '%FX275-SB%' OR v LIKE '%bea.fx275%' OR v LIKE '%supplier B%' THEN
            RAISE EXCEPTION 'FIXTURE 275 EVERY: % as A — %', r.sig, left(v, 300); END IF;
        v := pg_temp.f275_call(u_b, 'supplier_portal', 'supplier_portal', sid_b, v_fn);
        IF v LIKE 'ERR|%' OR v NOT LIKE '%FX275-SB%' OR v LIKE '%FX275-SA%' OR v LIKE '%ada.fx275%' OR v LIKE '%supplier A%' THEN
            RAISE EXCEPTION 'FIXTURE 275 EVERY: % as B — %', r.sig, left(v, 300); END IF;
        -- a staff (authenticated) session — or a portal account whose token fell back to authenticated — cannot call it
        v := pg_temp.f275_call(u_a, 'authenticated', 'authenticated', sid_a, v_fn);
        IF v NOT LIKE 'ERR|42501|%' THEN RAISE EXCEPTION 'FIXTURE 275 EVERY: % as authenticated — %', r.sig, left(v, 200); END IF;
        v := pg_temp.f275_call(u_mgr, 'authenticated', 'authenticated', NULL, v_fn);
        IF v NOT LIKE 'ERR|42501|%' THEN RAISE EXCEPTION 'FIXTURE 275 EVERY: % as a staff code holder — %', r.sig, left(v, 200); END IF;
        v := pg_temp.f275_call(u_a, 'supplier_portal', 'authenticated', sid_a, v_fn);
        IF v NOT LIKE 'ERR|%PORTAL_ROLE_REQUIRED%' THEN RAISE EXCEPTION 'FIXTURE 275 EVERY: % with a non-portal claim — %', r.sig, left(v, 200); END IF;
        v := pg_temp.f275_call(u_a, 'supplier_portal', 'supplier_portal', gen_random_uuid(), v_fn);
        IF v NOT LIKE 'ERR|%PORTAL_SESSION_ENDED%' THEN RAISE EXCEPTION 'FIXTURE 275 EVERY: % with an ended session — %', r.sig, left(v, 200); END IF;
        v := pg_temp.f275_call(u_a, 'supplier_portal', 'supplier_portal', NULL, v_fn);
        IF v NOT LIKE 'ERR|%PORTAL_SESSION_ENDED%' THEN RAISE EXCEPTION 'FIXTURE 275 EVERY: % with no session id — %', r.sig, left(v, 200); END IF;
        v := pg_temp.f275_call(u_none, 'supplier_portal', 'supplier_portal', sid_a, v_fn);
        IF v NOT LIKE 'ERR|%PORTAL_NOT_A_PORTAL_ACCOUNT%' THEN RAISE EXCEPTION 'FIXTURE 275 EVERY: % as a non-portal account — %', r.sig, left(v, 200); END IF;
        UPDATE auth.users SET banned_until = now() + interval '1 day' WHERE id = u_b;
        v := pg_temp.f275_call(u_b, 'supplier_portal', 'supplier_portal', sid_b, v_fn);
        UPDATE auth.users SET banned_until = NULL WHERE id = u_b;
        IF v NOT LIKE 'ERR|%PORTAL_ACCESS_REVOKED%' THEN RAISE EXCEPTION 'FIXTURE 275 EVERY: % as a banned account — %', r.sig, left(v, 200); END IF;
    END LOOP;
    IF v_n <> jsonb_array_length(jsonb_path_query_array(v_cases, '$.keyvalue()')) THEN
        RAISE EXCEPTION 'FIXTURE 275 EVERY: % function(s) executable by supplier_portal, % case(s) here — a case lost its function', v_n,
            jsonb_array_length(jsonb_path_query_array(v_cases, '$.keyvalue()')); END IF;
    IF v_9b_seen <> cardinality(v_9b) THEN
        RAISE EXCEPTION 'FIXTURE 275 EVERY: % of the % MES-9b / MES-9c functions are executable by supplier_portal — the name list here is stale', v_9b_seen, cardinality(v_9b); END IF;

    -- ── EXPORT ─────────────────────────────────────────────────────────────
    v := pg_temp.f275_call(u_b, 'supplier_portal', 'supplier_portal', sid_b, 'SELECT public.portal_export_my_data()::text');
    IF v NOT LIKE '%bea.fx275@b.test%' OR v NOT LIKE '%+65 2222 0002%' OR v LIKE '%FX275-INTERNAL-NOTE%' OR v LIKE '%ada.fx275%' THEN
        RAISE EXCEPTION 'FIXTURE 275 EXPORT: %', left(v, 300); END IF;

    -- ── REVOKE ─────────────────────────────────────────────────────────────
    v := pg_temp.f275_call(u_mgr, 'authenticated', 'authenticated', NULL, format('SELECT public.portal_user_revoke(%L, %L)::text', l_a, '  '));
    IF v NOT LIKE 'ERR|%PORTAL_REVOKE_REASON_REQUIRED%' THEN RAISE EXCEPTION 'FIXTURE 275 REVOKE: a revoke without a reason (%)', v; END IF;
    v := pg_temp.f275_call(u_view, 'authenticated', 'authenticated', NULL, format('SELECT public.portal_user_revoke(%L, %L)::text', l_a, 'fx'));
    IF v NOT LIKE 'ERR|%PERMISSION_DENIED%' THEN RAISE EXCEPTION 'FIXTURE 275 REVOKE: a viewer revoked (%)', v; END IF;
    v := pg_temp.f275_call(u_mgr, 'authenticated', 'authenticated', NULL, format('SELECT public.portal_user_revoke(%L, %L)::text', l_a, 'fixture 275: left the supplier'));
    IF v LIKE 'ERR|%' OR (v::jsonb ->> 'sessions_ended')::int <> 1 OR EXISTS (SELECT 1 FROM auth.sessions WHERE user_id = u_a) THEN
        RAISE EXCEPTION 'FIXTURE 275 REVOKE: the revoke did not end A''s session (%)', v; END IF;
    INSERT INTO auth.sessions (id, user_id) VALUES (sid_a, u_a);      -- even a session that somehow survived: the link answers
    v := pg_temp.f275_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, 'SELECT public.portal_me()::text');
    IF v NOT LIKE 'ERR|%PORTAL_ACCESS_REVOKED%' THEN RAISE EXCEPTION 'FIXTURE 275 REVOKE: A''s next call after revoke — %', left(v, 200); END IF;
    v := pg_temp.f275_call(u_b, 'supplier_portal', 'supplier_portal', sid_b, 'SELECT public.portal_me()::text');
    IF v LIKE 'ERR|%' OR v NOT LIKE '%FX275-SB%' THEN RAISE EXCEPTION 'FIXTURE 275 REVOKE: B stopped working when A was revoked — %', left(v, 200); END IF;
    v := pg_temp.f275_call(u_mgr, 'authenticated', 'authenticated', NULL, format('SELECT public.portal_user_revoke(%L, %L)::text', l_a, 'again'));
    IF v NOT LIKE 'ERR|%PORTAL_ALREADY_REVOKED%' THEN RAISE EXCEPTION 'FIXTURE 275 REVOKE: a second revoke (%)', v; END IF;
    -- the hook keeps a revoked account inside the portal role (it never falls back to a staff-side token)
    IF pg_temp.f275_hook(pg_temp.f275_event(u_a::text)) #>> '{claims,role}' IS DISTINCT FROM 'supplier_portal' THEN
        RAISE EXCEPTION 'FIXTURE 275 REVOKE: a revoked portal account''s next token is not supplier_portal'; END IF;

    -- ── ANON ───────────────────────────────────────────────────────────────
    v := pg_temp.f275_call(u_mgr, 'authenticated', 'authenticated', NULL, format('SELECT public.portal_contact_anonymise(%L)::text', l_b));
    IF v NOT LIKE 'ERR|%PORTAL_ANONYMISE_NEEDS_REVOKE%' THEN RAISE EXCEPTION 'FIXTURE 275 ANON: anonymised a live account (%)', v; END IF;
    UPDATE counterparty_contacts SET role = 'Sales FX275' WHERE id = c_b;          -- a logged edit whose images carry the contact's data
    v := pg_temp.f275_call(u_mgr, 'authenticated', 'authenticated', NULL, format('SELECT public.portal_user_revoke(%L, %L)::text', l_b, 'fixture 275: on request'));
    IF v LIKE 'ERR|%' THEN RAISE EXCEPTION 'FIXTURE 275 ANON: revoke B (%)', v; END IF;
    v := pg_temp.f275_call(u_mgr, 'authenticated', 'authenticated', NULL, format('SELECT public.portal_contact_anonymise(%L)::text', l_b));
    IF v LIKE 'ERR|%' THEN RAISE EXCEPTION 'FIXTURE 275 ANON: %', v; END IF;
    IF NOT EXISTS (SELECT 1 FROM counterparty_contacts WHERE id = c_b AND name = 'Anonymised' AND email IS NULL AND phone IS NULL
                    AND notes IS NULL AND role IS NULL AND deleted_at IS NOT NULL AND anonymised_at IS NOT NULL) THEN
        RAISE EXCEPTION 'FIXTURE 275 ANON: the contact still carries personal data'; END IF;
    IF EXISTS (SELECT 1 FROM change_log c WHERE c.table_name = 'counterparty_contacts' AND c.row_key ->> 'id' = c_b::text
                AND (COALESCE(c.old::text, '') || COALESCE(c.new::text, '')) ~ '(bea\.fx275|Bea FX275|2222 0002|FX275-INTERNAL-NOTE-B|Sales FX275)') THEN
        RAISE EXCEPTION 'FIXTURE 275 ANON: the change log still holds the contact''s personal data'; END IF;
    IF (SELECT count(*) FROM change_log c WHERE c.table_name = 'counterparty_contacts' AND c.row_key ->> 'id' = c_b::text) < 3 THEN
        RAISE EXCEPTION 'FIXTURE 275 ANON: the arm is vacuous — fewer than three logged images of the contact'; END IF;
    IF NOT EXISTS (SELECT 1 FROM supplier_portal_users WHERE id = l_b AND user_id = u_b AND anonymised_at IS NOT NULL) THEN
        RAISE EXCEPTION 'FIXTURE 275 ANON: the link lost its account id or its stamp'; END IF;
    v := pg_temp.f275_call(u_mgr, 'authenticated', 'authenticated', NULL, format('SELECT public.portal_contact_anonymise(%L)::text', l_b));
    IF v NOT LIKE 'ERR|%PORTAL_ALREADY_ANONYMISED%' THEN RAISE EXCEPTION 'FIXTURE 275 ANON: a second anonymisation (%)', v; END IF;

    -- ── TRAIL ──────────────────────────────────────────────────────────────
    v_j := trail_actor('user', u_a, NULL);
    IF v_j IS DISTINCT FROM jsonb_build_object('state', 'portal', 'name', 'fixture 275 supplier A') THEN
        RAISE EXCEPTION 'FIXTURE 275 TRAIL: trail_actor for a portal account is %', v_j; END IF;
    IF trail_actor('user', u_mgr, NULL) ->> 'state' = 'portal' THEN
        RAISE EXCEPTION 'FIXTURE 275 TRAIL: a staff account reads as the portal'; END IF;
    v := pg_temp.f275_call(u_view, 'authenticated', 'authenticated', NULL,
        format('SELECT string_agg(user_id::text || ''='' || supplier_name, '','') FROM public.portal_actor_labels(ARRAY[%L, %L]::uuid[])', u_a, u_mgr));
    IF v IS DISTINCT FROM u_a::text || '=fixture 275 supplier A' THEN RAISE EXCEPTION 'FIXTURE 275 TRAIL: portal_actor_labels → %', v; END IF;
    v := pg_temp.f275_call(NULL, 'authenticated', 'authenticated', NULL, format('SELECT count(*)::text FROM public.portal_actor_labels(ARRAY[%L]::uuid[])', u_a));
    IF v NOT LIKE 'ERR|%' THEN RAISE EXCEPTION 'FIXTURE 275 TRAIL: portal_actor_labels answered a call with no session'; END IF;
    v := pg_temp.f275_call(u_view, 'authenticated', 'authenticated', NULL,
        format('SELECT count(*)::text FROM public.record_trail(''supplier'', %L, 200) r WHERE to_jsonb(r) ->> ''table_name'' = ''supplier_portal_users''', s_a));
    IF v LIKE 'ERR|%' OR v::int < 2 THEN RAISE EXCEPTION 'FIXTURE 275 TRAIL: the supplier''s trail does not show its portal account being created and revoked (%)', v; END IF;

    -- ── VIEW ───────────────────────────────────────────────────────────────
    v := pg_temp.f275_call(u_view, 'authenticated', 'authenticated', NULL,
        format('SELECT string_agg(account_email || '':'' || (revoked_at IS NOT NULL)::text || '':'' || must_change_password::text, '','' ORDER BY account_email) FROM public.supplier_portal_accounts WHERE supplier_id IN (%L, %L)', s_a, s_b));
    IF v IS DISTINCT FROM 'ada.fx275@a.test:true:true,bea.fx275@b.test:true:false' THEN
        RAISE EXCEPTION 'FIXTURE 275 VIEW: supplier_portal_accounts for a suppliers viewer → %', v; END IF;
    v := pg_temp.f275_call(u_perm, 'authenticated', 'authenticated', NULL, 'SELECT count(*)::text FROM public.supplier_portal_accounts');
    IF v <> '0' THEN RAISE EXCEPTION 'FIXTURE 275 VIEW: a reader without module.suppliers.view sees % portal account(s)', v; END IF;
    v := pg_temp.f275_call(u_perm, 'authenticated', 'authenticated', NULL,
        format('SELECT count(*)::text FROM public.user_directory WHERE user_id IN (%L, %L, %L)', u_a, u_b, u_r));
    IF v <> '1' THEN RAISE EXCEPTION 'FIXTURE 275 VIEW: user_directory lists % of (A, B, a staff account) — expected the staff account only', v; END IF;

    -- ── VALUES ─────────────────────────────────────────────────────────────
    v := pg_temp.f275_call(u_perm, 'authenticated', 'authenticated', NULL,
        'SELECT string_agg(value_code || ''@'' || href, '','' ORDER BY value_code) FROM public.pending_values WHERE value_code IN (''V38'', ''V40'')');
    IF v IS DISTINCT FROM 'V38@/settings/accounts,V40@/settings/accounts' THEN RAISE EXCEPTION 'FIXTURE 275 VALUES: pending → %', v; END IF;
    v := pg_temp.f275_call(u_view, 'authenticated', 'authenticated', NULL,
        'SELECT count(*)::text FROM public.pending_values WHERE value_code IN (''V38'', ''V40'')');
    IF v <> '0' THEN RAISE EXCEPTION 'FIXTURE 275 VALUES: a reader without action.manage_permissions sees V38 / V40'; END IF;
    v := pg_temp.f275_call(u_view, 'authenticated', 'authenticated', NULL, 'SELECT public.set_account_setting(''initial_password_valid_days'', 14)::text');
    IF v NOT LIKE 'ERR|%PERMISSION_DENIED%' THEN RAISE EXCEPTION 'FIXTURE 275 VALUES: a viewer set V38 (%)', v; END IF;
    v := pg_temp.f275_call(u_perm, 'authenticated', 'authenticated', NULL, 'SELECT public.set_account_setting(''initial_password_valid_days'', 0)::text');
    IF v NOT LIKE 'ERR|%ACCOUNT_SETTING_INVALID|initial_password_valid_days%' THEN RAISE EXCEPTION 'FIXTURE 275 VALUES: V38 = 0 (%)', v; END IF;
    v := pg_temp.f275_call(u_perm, 'authenticated', 'authenticated', NULL, 'SELECT public.set_account_setting(''password_min_length'', 5)::text');
    IF v NOT LIKE 'ERR|%ACCOUNT_SETTING_INVALID|password_min_length%' THEN RAISE EXCEPTION 'FIXTURE 275 VALUES: V40 = 5 (%)', v; END IF;
    v := pg_temp.f275_call(u_perm, 'authenticated', 'authenticated', NULL, 'SELECT public.set_account_setting(''nope'', 1)::text');
    IF v NOT LIKE 'ERR|%ACCOUNT_SETTING_UNKNOWN|nope%' THEN RAISE EXCEPTION 'FIXTURE 275 VALUES: unknown key (%)', v; END IF;
    v := pg_temp.f275_call(u_perm, 'authenticated', 'authenticated', NULL, 'SELECT public.set_account_setting(''initial_password_valid_days'', 14)::text');
    IF v LIKE 'ERR|%' THEN RAISE EXCEPTION 'FIXTURE 275 VALUES: set V38 (%)', v; END IF;
    v := pg_temp.f275_call(u_perm, 'authenticated', 'authenticated', NULL,
        'SELECT string_agg(value_code, '','' ORDER BY value_code) FROM public.pending_values WHERE value_code IN (''V38'', ''V40'')');
    IF v IS DISTINCT FROM 'V40' THEN RAISE EXCEPTION 'FIXTURE 275 VALUES: after V38 was set → %', v; END IF;

    -- ── LOG (account settings) ─────────────────────────────────────────────
    IF NOT EXISTS (SELECT 1 FROM change_log WHERE table_name = 'account_settings' AND op = 'UPDATE') THEN
        RAISE EXCEPTION 'FIXTURE 275 LOG: account_settings is not change-logged'; END IF;

    -- ── GRANTS ─────────────────────────────────────────────────────────────
    FOREACH v IN ARRAY ARRAY['public.portal_me()', 'public.portal_export_my_data()'] LOOP
        IF NOT has_function_privilege('supplier_portal', v::regprocedure, 'EXECUTE')
           OR has_function_privilege('authenticated', v::regprocedure, 'EXECUTE')
           OR has_function_privilege('anon', v::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'FIXTURE 275 GRANTS: % must be executable by supplier_portal only', v; END IF;
    END LOOP;
    IF NOT has_function_privilege('supabase_auth_admin', 'public.portal_access_token_hook(jsonb)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.portal_access_token_hook(jsonb)', 'EXECUTE')
       OR has_function_privilege('supplier_portal', 'public.portal_access_token_hook(jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 275 GRANTS: the hook must be executable by supabase_auth_admin only'; END IF;
    IF has_function_privilege('authenticated', 'public.portal_require_link()', 'EXECUTE')
       OR has_function_privilege('supplier_portal', 'public.portal_require_link()', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 275 GRANTS: portal_require_link must be executable by nobody'; END IF;
    IF pg_has_role('supplier_portal', 'authenticated', 'MEMBER') OR pg_has_role('supplier_portal', 'anon', 'MEMBER') THEN
        RAISE EXCEPTION 'FIXTURE 275 GRANTS: supplier_portal must not be a member of authenticated or anon'; END IF;

    RAISE NOTICE 'FIXTURE 275 全部通过: CODE · LINK · SEP · HOOK · EVERY · EXPORT · REVOKE · ANON · TRAIL · VIEW · VALUES · LOG · GRANTS';
END
$f275$;
ROLLBACK;
