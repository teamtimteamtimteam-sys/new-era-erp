-- db/scripts/2026-10-04-at1d1-live-proof.sql
-- AUDIT-TRAIL-1d-1 · 线上的证明(形状照 1c-3 的那一份)。以 postgres 跑,读者一律是【真账号】的会话(SET LOCAL ROLE authenticated + JWT)。
--   A  只读,以 admin@(唯一持 action.manage_permissions 的账号)读:每一个账号(M9)· 每一名员工(含删掉的)· 审批方针那一段 ·
--      cto 那个角色(Q22:它被授给了谁 —— phua@ 那一笔必须在)· 每一个部门、每一条培训记录、每一批导入 · 六本字典(M11)。
--      不许被拒;每一个账号有它的建立("记录开始之前"那一行);每一名员工有它的建立;一行只出现一次;审批方针那一段只有它那四列。
--      外加以 tim@(cfo:持 hr.view、不持 manage_permissions)读一名挂着账号的员工 —— 账号那几行必须是 Restricted(Q21)。
--   B  回滚,以 admin@:经 save_employee 入职一名员工、再编辑他(一次转部门)· 给一个【已有的】账号授一个角色 · 在一本字典里加一个值
--      再改它(不改任何一个已有的字典值)。以 admin@ 读它们的审计记录。
--   ★ 不建、不停、不删任何账号;不碰任何一张在这之前就在的单据。被改的旧行只有 user_roles 那一行新授权的那个账号(授权本身是
--     新的一行),回滚之后原样(前后读数为证)。
--   整个文件一笔事务,末尾 ROLLBACK —— 不留下任何东西。
-- 跑法:psql "$DSN" -X -q -v ON_ERROR_STOP=1 -f db/scripts/2026-10-04-at1d1-live-proof.sql > out.txt;  PROOF_OWN_EXIT=$?
BEGIN;
SET LOCAL statement_timeout = '600s';

CREATE TEMP TABLE p_out (label text, subject text, id text, grp text, rows jsonb) ON COMMIT DROP;

CREATE FUNCTION pg_temp.p_trail(p_user uuid, p_subject text, p_id text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.entry_no, r.seq NULLS LAST, r.occurred_at), '[]'::jsonb) INTO v
      FROM record_trail(p_subject, p_id, 500) r;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RAISE EXCEPTION 'PROOF|% % refused or failed: %', p_subject, p_id, SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.p_twice(p_trail jsonb) RETURNS text
LANGUAGE sql AS $f$
    SELECT string_agg(k, ', ') FROM (
        SELECT COALESCE(e ->> 'seq', 'P') || ':' || (e ->> 'table_name') || ':' || (e ->> 'row_key') || ':' || (e ->> 'op') || ':' ||
               COALESCE(e ->> 'changed_columns', '') AS k
          FROM jsonb_array_elements(p_trail) e WHERE NOT (e ->> 'row_hidden')::boolean
         GROUP BY 1 HAVING count(*) > 1) d
$f$;

CREATE FUNCTION pg_temp.p_has(p_trail jsonb, p_table text, p_op text, p_col text DEFAULT NULL) RETURNS boolean
LANGUAGE sql AS $f$
    SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(p_trail) e
                    WHERE e ->> 'table_name' = p_table AND e ->> 'op' = p_op AND NOT (e ->> 'row_hidden')::boolean
                      AND (p_col IS NULL OR e -> 'changed_columns' ? p_col))
$f$;

CREATE FUNCTION pg_temp.p_keep(p_label text, p_user uuid, p_subject text, p_id text, p_grp text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb := pg_temp.p_trail(p_user, p_subject, p_id);
BEGIN
    INSERT INTO p_out VALUES (p_label, p_subject, p_id, p_grp, v);
    RETURN v;
END;
$f$;

-- ══════════════ A · 只读:线上的每一条 ══════════════
DO $a$
DECLARE
    adm uuid := '321f1819-8449-48f7-9ae0-78b2c4b50f35';   -- admin@swm-os.test
    tim uuid := '634c00f9-c3a9-4444-9eed-b624cb6a2a93';   -- tim@evoltrya.test(cfo)
    v jsonb; t record; n int := 0; m int;
BEGIN
    -- 每一个账号(M9):有它的建立,一行只一次
    FOR t IN SELECT id::text AS id, email FROM auth.users ORDER BY created_at LOOP
        v := pg_temp.p_keep('A account', adm, 'account', t.id);
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) e WHERE e ->> 'table_name' = 'auth.users'
                         AND ((e ->> 'prelog')::boolean AND e ->> 'op' = 'INSERT' OR e ->> 'op' = 'ACCOUNT_CREATE')) THEN
            RAISE EXCEPTION 'PROOF A|account % has no creation on its trail', t.email; END IF;
        IF v::text ~ 'encrypted_password|refresh_token|confirmation_token' THEN RAISE EXCEPTION 'PROOF A|account % leaks an auth column', t.email; END IF;
        n := n + 1;
    END LOOP;
    -- 每一名员工(删掉的也读):有它的建立
    FOR t IN SELECT id::text AS id, code FROM employees ORDER BY code LOOP
        v := pg_temp.p_keep('A employee', adm, 'employee', t.id);
        IF NOT pg_temp.p_has(v, 'employees', 'INSERT') THEN RAISE EXCEPTION 'PROOF A|employee % has no creation on its trail', t.code; END IF;
        n := n + 1;
    END LOOP;
    -- 审批方针:它那一行修改史在;只有它那四列
    v := pg_temp.p_keep('A approval policy', adm, 'approval_policy', 'true');
    IF (SELECT count(*) FROM finance_settings_history) > 0 AND NOT pg_temp.p_has(v, 'finance_settings_history', 'INSERT') THEN
        RAISE EXCEPTION 'PROOF A|the approval-policy trail does not show its history (M7)'; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v) e, jsonb_array_elements_text(COALESCE(e -> 'changed_columns', '[]')) col
                WHERE e ->> 'table_name' = 'finance_settings'
                  AND col NOT IN ('approvals_enabled', 'approval_threshold_base', 'approval_level1_role_code', 'approval_level2_role_code')) THEN
        RAISE EXCEPTION 'PROOF A|the approval-policy trail shows a settings column it does not own (M6)'; END IF;
    n := n + 1;
    -- cto 的角色页:每一笔授权都在(phua@ 那一笔)
    v := pg_temp.p_keep('A role cto', adm, 'role', (SELECT id::text FROM roles WHERE code = 'cto'));
    SELECT count(*) INTO m FROM jsonb_array_elements(v) e WHERE e ->> 'table_name' = 'user_roles' AND e ->> 'op' = 'INSERT';
    IF m < (SELECT count(*) FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE r.code = 'cto') THEN
        RAISE EXCEPTION 'PROOF A|the cto role trail shows % grant(s), user_roles holds %', m,
            (SELECT count(*) FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE r.code = 'cto'); END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) e JOIN auth.users u ON u.id::text = e -> 'new' ->> 'user_id'
                    WHERE e ->> 'table_name' = 'user_roles' AND u.email LIKE 'phua@%') THEN
        RAISE EXCEPTION 'PROOF A|phua@''s cto grant is not on the cto role trail (Q22)'; END IF;
    n := n + 1;
    FOR t IN SELECT 'department' AS s, id::text AS id FROM departments
             UNION ALL SELECT 'training_record', id::text FROM training_records
             UNION ALL SELECT 'import_batch', id::text FROM import_batches LOOP
        v := pg_temp.p_keep('A ' || t.s, adm, t.s, t.id);
        IF jsonb_array_length(v) = 0 THEN RAISE EXCEPTION 'PROOF A|% % has an empty trail', t.s, t.id; END IF;
        n := n + 1;
    END LOOP;
    FOR t IN SELECT s.subject FROM trail_subjects() s WHERE s.root_rule = 'collection' LOOP
        PERFORM pg_temp.p_keep('A dictionary', adm, t.subject, 'all');
        n := n + 1;
    END LOOP;
    IF EXISTS (SELECT 1 FROM p_out WHERE pg_temp.p_twice(rows) IS NOT NULL) THEN
        RAISE EXCEPTION 'PROOF A|a row shows twice: %', (SELECT string_agg(label || ' ' || id || ': ' || pg_temp.p_twice(rows), '; ') FROM p_out WHERE pg_temp.p_twice(rows) IS NOT NULL); END IF;
    -- Q21:cfo(hr.view,无 manage_permissions)读一名挂着账号的员工 —— 账号那几行看不见(row_hidden),一行 auth.users 都读不到
    SELECT id::text INTO t FROM employees WHERE user_id IS NOT NULL AND deleted_at IS NULL ORDER BY code LIMIT 1;
    IF FOUND THEN
        v := pg_temp.p_trail(tim, 'employee', (SELECT id::text FROM employees WHERE user_id IS NOT NULL AND deleted_at IS NULL ORDER BY code LIMIT 1));
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(v) e WHERE e ->> 'table_name' = 'auth.users') THEN
            RAISE EXCEPTION 'PROOF A|cfo reads an account event on the employee page (Q21)'; END IF;
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) e WHERE (e ->> 'row_hidden')::boolean) THEN
            RAISE EXCEPTION 'PROOF A|the account rows on the employee page should be Restricted for cfo (Q21)'; END IF;
    END IF;
    RAISE NOTICE 'PROOF A passed: % records read as admin@, none refused; cto shows % grant(s); cfo sees the account rows Restricted', n, m;
END;
$a$;

-- ══════════════ B · 回滚:入职 · 编辑 · 授权 · 字典 ══════════════
DO $b$
DECLARE
    adm uuid := '321f1819-8449-48f7-9ae0-78b2c4b50f35';
    acct uuid; e_new uuid; d1 uuid; d2 uuid; r_aud uuid; v jsonb; v_roles uuid[];
BEGIN
    SELECT id INTO acct FROM auth.users WHERE email LIKE 'fusheng@%';
    SELECT id INTO r_aud FROM roles WHERE code = 'auditor' AND deleted_at IS NULL;
    SELECT id INTO d1 FROM departments WHERE deleted_at IS NULL ORDER BY code LIMIT 1;
    IF acct IS NULL OR r_aud IS NULL THEN RAISE EXCEPTION 'PROOF B|setup: fusheng@ or the auditor role not found'; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', adm), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    e_new := save_employee(NULL, jsonb_build_object('legal_name', 'ZZ AT1D1 Proof Hire', 'first_name', 'Proof', 'employment_type', 'full_time',
        'work_category', 'office', 'hire_date', '2026-10-01', 'employment_status', 'probation', 'department_id', d1),
        jsonb_build_object('effective_date', '2026-10-01', 'change_type', 'hired', 'department_id', d1,
                           'employment_type', 'full_time', 'employment_status', 'probation'));
    -- 表单每一次交齐那几栏(以 authenticated 读不得整行:几列被遮蔽 —— 照表单的样子把它们写出来)
    PERFORM save_employee(e_new, jsonb_build_object('legal_name', 'ZZ AT1D1 Proof Hire', 'first_name', 'Proof', 'preferred_name', 'Proofy',
        'employment_type', 'full_time', 'work_category', 'office', 'hire_date', '2026-10-01', 'employment_status', 'active', 'department_id', d1),
        jsonb_build_object('effective_date', '2026-11-01', 'change_type', 'confirmed', 'department_id', d1,
                           'employment_type', 'full_time', 'employment_status', 'active', 'notes', 'status: probation → active'));
    SELECT array_agg(ur.role_id) INTO v_roles FROM user_roles ur WHERE ur.user_id = acct AND ur.revoked_at IS NULL;
    PERFORM set_user_roles(acct, COALESCE(v_roles, ARRAY[]::uuid[]) || r_aud, NULL);
    INSERT INTO laboratories (code, name_en, name_zh) VALUES ('ZZ-AT1D1', 'ZZ proof lab', 'f');
    UPDATE laboratories SET name_en = 'ZZ proof laboratory' WHERE code = 'ZZ-AT1D1';
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);

    v := pg_temp.p_keep('B employee', adm, 'employee', e_new::text);
    IF NOT pg_temp.p_has(v, 'employees', 'INSERT') OR NOT pg_temp.p_has(v, 'employment_history', 'INSERT') THEN
        RAISE EXCEPTION 'PROOF B|the hire is incomplete on the trail'; END IF;
    v := pg_temp.p_keep('B account', adm, 'account', acct::text);
    IF NOT pg_temp.p_has(v, 'user_roles', 'INSERT') THEN RAISE EXCEPTION 'PROOF B|the grant is missing on the account trail'; END IF;
    v := pg_temp.p_keep('B role auditor', adm, 'role', r_aud::text);
    IF NOT pg_temp.p_has(v, 'user_roles', 'INSERT') THEN RAISE EXCEPTION 'PROOF B|the grant is missing on the role trail (Q22)'; END IF;
    v := pg_temp.p_keep('B dictionary', adm, 'dictionary_laboratories', 'all');
    IF NOT pg_temp.p_has(v, 'laboratories', 'INSERT') OR NOT pg_temp.p_has(v, 'laboratories', 'UPDATE', 'name_en') THEN
        RAISE EXCEPTION 'PROOF B|the dictionary change is missing (M11)'; END IF;
    IF EXISTS (SELECT 1 FROM p_out WHERE label LIKE 'B%' AND pg_temp.p_twice(rows) IS NOT NULL) THEN
        RAISE EXCEPTION 'PROOF B|a row shows twice'; END IF;
    RAISE NOTICE 'PROOF B passed: hired %, granted auditor to fusheng@, laboratory ZZ-AT1D1 added and renamed',
        (SELECT code FROM employees WHERE id = e_new);
END;
$b$;

-- 给造句器的那一份:每一条一行 JSON
\pset tuples_only on
\pset format unaligned
SELECT jsonb_build_object('label', label, 'subject', subject, 'id', id, 'grp', grp, 'rows', rows)::text FROM p_out ORDER BY label LIKE 'B%', label, subject, id;

ROLLBACK;
