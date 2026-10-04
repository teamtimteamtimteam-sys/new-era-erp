-- 244 AUDIT-TRAIL-1d-1:账号、设置与员工的审计记录 —— M9 · M10 · M11 · M12 · Q13 · save_employee(2026-10-04)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(AT-1d Step 0 的 Q1–Q38,Tim 2026-10-04 全部照建议;这是 1d-1 那一刀)
--   A   账号(M9):根在 auth.users —— 上下文只有那一份安全投影(id · email · created_at · banned_until),口令散列与令牌
--       一个字都不进来;建立 / 停用 / 停用失败 / 恢复 / 回滚掉的建立(ACCOUNT_DELETE)都在;授给它的角色在(家是账号,Q22);
--       不持 action.manage_permissions 的人 → TRAIL_NOT_PERMITTED;记录开始之前那一段的"建立"在之后有 ACCOUNT_CREATE 时不再拼
--   C   M10:账号的审计记录里那名员工只剩 user_id 一列 —— 那名员工的一次人事编辑(改称呼)不在账号上,挂接那一下在
--   K   M11:一本字典整本是一条记录 —— 加上的值、停用那一下都在;不持那一段查看码的人被拒
--   G   M12:'gate:reviewer' —— 审核人读得到;被评审的人(评审已批准,表的规则放他进来)被拒;一个认不出的门名谁都读不了
--   Q   Q13:/settings/change-history 的读法逐行再过一次那张表的读规则 —— 持 view_change_log 而没有 view_pay 的人,
--       调薪申请那一行整份受限;持 view_pay 的人看得见
--   S   save_employee:入职一次调用写下员工与"入职"那一行履历;履历写不进去时员工那一行也不在(同生共死);
--       编辑一列都没变就不写;不持 module.hr.edit → 具名拒绝(不是一次成功的空操作)
--   E   员工页的镜像(Q21 · Q24):不持 manage_permissions 的人事读者 —— 授权、附加账号的挂接看得见;
--       账号事件、挂接史是 Restricted(row_hidden)
--   R   角色页:授给了谁(user_roles 是角色的成员,Q22)
--   P   审批方针(M6 · M7):只有那四列、加上它的修改史;锁期、GST 一列都不进来
--   I   导入批次:清单块读得到;不持 action.bulk_import 的人被拒
--   D   删掉的记录(Q25 · Q26):角色 · 员工 · 部门 · 培训记录进 deleted_records,"谁"取自变更记录
--   N   匿名化(Q30):员工那一行的 anonymised_at 在审计记录里;那个人从此读作 "A former employee"(trail_actor 的 anonymised)
--
-- 自带数据(README 第 2 条):账号、角色、员工、部门、培训、字典值、评审、导入批次全部本支自建;本支读的每一行都由本支写。
-- 以 postgres 跑(绕过 RLS)—— 每一次读都切成 authenticated + 那个人的 JWT(fixture 26 的教训)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '240s';

CREATE FUNCTION pg_temp.f244_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

CREATE FUNCTION pg_temp.f244_trail(p_user uuid, p_subject text, p_id text, p_n int DEFAULT 500) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f244_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.entry_no, r.seq NULLS LAST, r.occurred_at), '[]'::jsonb) INTO v
      FROM record_trail(p_subject, p_id, p_n) r;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN jsonb_build_object('error', SQLERRM);
END;
$f$;

-- 以某人的身份跑一句,返回 'OK' 或那一句拒绝
CREATE FUNCTION pg_temp.f244_try(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f244_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f244_ok(p_arm text, p_trail jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $f$
BEGIN
    IF jsonb_typeof(p_trail) <> 'array' THEN RAISE EXCEPTION 'FIXTURE 244 %: the reader was refused: %', p_arm, p_trail; END IF;
    RETURN p_trail;
END;
$f$;

CREATE FUNCTION pg_temp.f244_refused(p_arm text, p_trail jsonb) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    IF COALESCE(p_trail ->> 'error', '') NOT LIKE 'TRAIL_NOT_PERMITTED%' THEN
        RAISE EXCEPTION 'FIXTURE 244 %: expected TRAIL_NOT_PERMITTED, got %', p_arm, p_trail; END IF;
END;
$f$;

CREATE FUNCTION pg_temp.f244_has(p_trail jsonb, p_table text, p_op text, p_col text DEFAULT NULL, p_new jsonb DEFAULT NULL) RETURNS boolean
LANGUAGE sql AS $f$
    SELECT jsonb_typeof(p_trail) = 'array' AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_trail) e
                   WHERE e ->> 'table_name' = p_table AND e ->> 'op' = p_op AND NOT (e ->> 'row_hidden')::boolean
                     AND (p_col IS NULL OR e -> 'changed_columns' ? p_col)
                     AND (p_new IS NULL OR e -> 'new' @> p_new))
$f$;

CREATE FUNCTION pg_temp.f244_need(p_arm text, p_trail jsonb, p_table text, p_op text, p_col text DEFAULT NULL, p_new jsonb DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    IF NOT pg_temp.f244_has(p_trail, p_table, p_op, p_col, p_new) THEN
        RAISE EXCEPTION 'FIXTURE 244 %: expected a % % row% in the trail, got %', p_arm, p_table, p_op,
            COALESCE(' changing ' || p_col, '') || COALESCE(' with ' || p_new::text, ''), p_trail;
    END IF;
END;
$f$;

DO $$
DECLARE
    u_all  uuid := gen_random_uuid();   -- 全部码(manage_permissions、hr、bulk_import、view_change_log、view_pay、view_deleted…)
    u_hr   uuid := gen_random_uuid();   -- 人事:module.hr.view + module.hr.edit;不持 manage_permissions、不持 view_pay
    u_cl   uuid := gen_random_uuid();   -- 只持 data.view_change_log + module.hr.view:没有 view_pay(Q13)
    u_none uuid := gen_random_uuid();   -- 一个码都没有
    u_acc  uuid := gen_random_uuid();   -- 被管理的那个账号(本支的 M9 主角)
    u_gone uuid := gen_random_uuid();   -- 一个建了又回滚掉的账号(ACCOUNT_DELETE)
    u_rev  uuid := gen_random_uuid();   -- 评审的审核人
    u_sub  uuid := gen_random_uuid();   -- 被评审的那个人
    r_all uuid; r_hr uuid; r_cl uuid; r_x uuid;
    e_acc uuid := gen_random_uuid(); e_rev uuid := gen_random_uuid(); e_sub uuid := gen_random_uuid();
    e_new uuid; e_anon uuid := gen_random_uuid(); d_id uuid; tr_id uuid; pr_id uuid; ib_id uuid; scr uuid;
    v_j jsonb; v_j2 jsonb; v_msg text; v_n int; v_def text; v_row jsonb; v_keys text[];
BEGIN
    -- ══════════════ 布景 ══════════════
    -- last_sign_in_at 是投影【之外】的一列(重建库的 auth.users 只有平台前置那几列;线上还有口令散列与令牌 —— 同一条判据)
    -- u_acc 的 created_at 早于变更记录:它在"记录开始之前"那一段有一条建立 —— 之后又有一行 ACCOUNT_CREATE,M9 只许说一次
    INSERT INTO auth.users (id, email, email_confirmed_at, last_sign_in_at, created_at) VALUES
        (u_all, 'fx244-all@test.local', now(), now(), now()), (u_hr, 'fx244-hr@test.local', now(), NULL, now()),
        (u_cl, 'fx244-cl@test.local', now(), NULL, now()), (u_none, 'fx244-none@test.local', now(), NULL, now()),
        (u_acc, 'fx244-acc@test.local', now(), TIMESTAMPTZ '2001-02-03 04:05:06+00', TIMESTAMPTZ '2026-01-05 09:00:00+08'),
        (u_rev, 'fx244-rev@test.local', now(), NULL, now()), (u_sub, 'fx244-sub@test.local', now(), NULL, now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx244-all', 'FX244 All', 'f', true) RETURNING id INTO r_all;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx244-hr', 'FX244 HR', 'f', true) RETURNING id INTO r_hr;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx244-cl', 'FX244 Log', 'f', true) RETURNING id INTO r_cl;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx244-x', 'FX244 Granted', 'f', true) RETURNING id INTO r_x;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_hr, 'module.hr.view'), (r_hr, 'module.hr.edit'),
        (r_cl, 'data.view_change_log'), (r_cl, 'module.hr.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_all, r_all), (u_hr, r_hr), (u_cl, r_cl);
    -- 停用一个账号要求世上另有一个登录得了的系统角色持有人(LAST_ADMIN_PROTECTED)—— u_all 持 admin
    INSERT INTO user_roles (user_id, role_id) SELECT u_all, id FROM roles WHERE code = 'admin';
    INSERT INTO employees (id, code, legal_name, preferred_name, employment_type, work_category, hire_date, employment_status, user_id) VALUES
        (e_acc, 'FX244-ACC', 'FX244 Account Holder', 'Holder', 'full_time', 'office', DATE '2020-01-01', 'active', NULL),
        (e_rev, 'FX244-REV', 'FX244 Reviewer', 'Rev', 'full_time', 'office', DATE '2020-01-01', 'active', u_rev),
        (e_sub, 'FX244-SUB', 'FX244 Subject', 'Sub', 'full_time', 'office', DATE '2020-01-01', 'active', u_sub);

    -- ══════════════ A · 账号(M9)══════════════
    PERFORM pg_temp.f244_as(u_all);
    PERFORM record_account_event(u_acc, 'ACCOUNT_CREATE', jsonb_build_object('role_id', r_x));
    PERFORM set_user_roles(u_acc, ARRAY[r_x], NULL);
    PERFORM set_user_employee_link(u_acc, e_acc);
    PERFORM record_account_event(u_acc, 'ACCOUNT_DISABLE', '{}'::jsonb);
    PERFORM record_account_event(u_acc, 'ACCOUNT_DISABLE_FAILED', '{"error": "fixture 244"}'::jsonb);
    PERFORM set_user_roles(u_acc, ARRAY[]::uuid[], 'fixture 244: role no longer needed');
    -- 建了又回滚掉的一个账号:auth 那一行已经不在(ACCOUNT_DELETE 只认【已经不在】的账号)
    PERFORM record_account_event(u_gone, 'ACCOUNT_DELETE', jsonb_build_object('email', 'fx244-gone@test.local', 'reason', 'create_rolled_back'));
    PERFORM set_config('request.jwt.claims', '', true);

    v_j := pg_temp.f244_ok('A', pg_temp.f244_trail(u_all, 'account', u_acc::text));
    PERFORM pg_temp.f244_need('A (account created)', v_j, 'auth.users', 'ACCOUNT_CREATE');
    PERFORM pg_temp.f244_need('A (disabled)', v_j, 'auth.users', 'ACCOUNT_DISABLE');
    PERFORM pg_temp.f244_need('A (disabling failed)', v_j, 'auth.users', 'ACCOUNT_DISABLE_FAILED');
    PERFORM pg_temp.f244_need('A (role granted — home on the account)', v_j, 'user_roles', 'INSERT', NULL, jsonb_build_object('role_id', r_x));
    PERFORM pg_temp.f244_need('A (role removed, with its reason)', v_j, 'user_roles', 'UPDATE', 'revoked_at',
        '{"revoke_reason": "fixture 244: role no longer needed"}');
    -- 安全投影:根行的上下文只有那四列 —— 一个口令散列都不许进来
    SELECT ARRAY(SELECT jsonb_object_keys(e -> 'ctx') ORDER BY 1) INTO v_keys
      FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'auth.users' AND e -> 'ctx' IS NOT NULL LIMIT 1;
    IF v_keys IS DISTINCT FROM ARRAY['$gone', 'banned_until', 'created_at', 'email', 'id'] THEN
        RAISE EXCEPTION 'FIXTURE 244 A (M9): the account''s context must be the safe projection only, got %', v_keys; END IF;
    IF v_j::text LIKE '%2001-02-03%' THEN
        RAISE EXCEPTION 'FIXTURE 244 A (M9): a column outside the safe projection (last_sign_in_at) reached the trail'; END IF;
    -- 之后有 ACCOUNT_CREATE,所以"记录开始之前"的建立不再拼(一次建立只说一次)
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE (e ->> 'prelog')::boolean AND e ->> 'table_name' = 'auth.users') THEN
        RAISE EXCEPTION 'FIXTURE 244 A (M9): the creation appears twice (pre-log row beside ACCOUNT_CREATE)'; END IF;
    PERFORM pg_temp.f244_refused('A (no manage_permissions)', pg_temp.f244_trail(u_hr, 'account', u_acc::text));
    -- 回滚掉的那一个:账号已经不在 → 它的审计记录读不到(根行没有今天的样子);那一行事件在变更记录里
    IF NOT EXISTS (SELECT 1 FROM change_log c WHERE c.table_name = 'auth.users' AND c.row_key = jsonb_build_object('id', u_gone)
                    AND c.op = 'ACCOUNT_DELETE' AND c.new ->> 'reason' = 'create_rolled_back') THEN
        RAISE EXCEPTION 'FIXTURE 244 A: the rolled-back creation was not recorded'; END IF;

    -- ══════════════ C · M10:账号上那名员工只剩 user_id ══════════════
    PERFORM pg_temp.f244_as(u_all);
    UPDATE employees SET preferred_name = 'Holder2' WHERE id = e_acc;            -- 一次人事编辑:不是账号的事
    PERFORM set_config('request.jwt.claims', '', true);
    v_j := pg_temp.f244_ok('C', pg_temp.f244_trail(u_all, 'account', u_acc::text));
    PERFORM pg_temp.f244_need('C (M10: the login link)', v_j, 'employees', 'UPDATE', 'user_id');
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e
                WHERE e ->> 'table_name' = 'employees'
                  AND (e -> 'changed_columns' ? 'preferred_name' OR COALESCE(e -> 'new', '{}') ? 'preferred_name'
                       OR COALESCE(e -> 'old', '{}') ? 'preferred_name')) THEN
        RAISE EXCEPTION 'FIXTURE 244 C (M10): an HR edit of the employee reached the account trail: %', v_j; END IF;

    -- ══════════════ E · 员工页上的账号镜像(Q21 · Q24)══════════════
    PERFORM pg_temp.f244_as(u_all);
    PERFORM set_user_roles(u_acc, ARRAY[r_x], 'fixture 244 again');
    PERFORM set_config('request.jwt.claims', '', true);
    v_j := pg_temp.f244_ok('E', pg_temp.f244_trail(u_hr, 'employee', e_acc::text));
    PERFORM pg_temp.f244_need('E (grant visible to HR)', v_j, 'user_roles', 'INSERT', NULL, jsonb_build_object('role_id', r_x));
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE (e ->> 'row_hidden')::boolean) THEN
        RAISE EXCEPTION 'FIXTURE 244 E: account events should be Restricted (hidden) for an HR reader without manage_permissions: %', v_j; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'auth.users') THEN
        RAISE EXCEPTION 'FIXTURE 244 E: an account event was readable without manage_permissions: %', v_j; END IF;
    v_j := pg_temp.f244_ok('E (manage_permissions)', pg_temp.f244_trail(u_all, 'employee', e_acc::text));
    PERFORM pg_temp.f244_need('E (account events visible to manage_permissions)', v_j, 'auth.users', 'ACCOUNT_DISABLE');

    -- ══════════════ R · 角色页:授给了谁(Q22)══════════════
    v_j := pg_temp.f244_ok('R', pg_temp.f244_trail(u_all, 'role', r_x::text));
    PERFORM pg_temp.f244_need('R (granted to the account)', v_j, 'user_roles', 'INSERT', NULL, jsonb_build_object('user_id', u_acc));
    IF (trail_row_record('user_roles', jsonb_build_object('id', (SELECT id FROM user_roles WHERE user_id = u_acc AND role_id = r_x AND revoked_at IS NULL)), NULL, NULL)
        ->> 'table') IS DISTINCT FROM 'auth.users' THEN
        RAISE EXCEPTION 'FIXTURE 244 R (Q22): a grant''s home should be the account'; END IF;

    -- ══════════════ K · M11:字典整本是一条记录 ══════════════
    PERFORM pg_temp.f244_as(u_all);
    INSERT INTO substances (code, name_en, name_zh) VALUES ('FX244', 'Fixture element', 'f');
    UPDATE substances SET is_active = false WHERE code = 'FX244';
    PERFORM set_config('request.jwt.claims', '', true);
    v_j := pg_temp.f244_ok('K', pg_temp.f244_trail(u_all, 'dictionary_substances', 'all'));
    PERFORM pg_temp.f244_need('K (value added)', v_j, 'substances', 'INSERT', NULL, '{"code": "FX244"}');
    PERFORM pg_temp.f244_need('K (value deactivated)', v_j, 'substances', 'UPDATE', 'is_active');
    PERFORM pg_temp.f244_refused('K (no materials.view)', pg_temp.f244_trail(u_none, 'dictionary_substances', 'all'));

    -- ══════════════ G · M12:比表的规则更窄的门 ══════════════
    INSERT INTO performance_reviews (id, employee_id, reviewer_employee_id, review_type, period_start, period_end, status)
        VALUES (gen_random_uuid(), e_sub, e_rev, 'probation', DATE '2025-01-01', DATE '2025-12-31', 'draft') RETURNING id INTO pr_id;
    UPDATE performance_reviews SET summary_text = 'fixture 244 draft wording' WHERE id = pr_id;
    UPDATE performance_reviews SET status = 'approved', rating_code = (SELECT code FROM review_rating_scale ORDER BY code LIMIT 1),
           summary_text = 'fixture 244 final', probation_outcome = 'confirm' WHERE id = pr_id;
    v_def := pg_get_functiondef('public.trail_subjects()'::regprocedure);
    v_def := replace(v_def, E'\n    ) AS s(subject',
        E'\n        , (''fx244_gate'', ARRAY[]::text[], ''performance_reviews'', ''id'', ''gate:reviewer'', NULL)'
        || E'\n        , (''fx244_badgate'', ARRAY[]::text[], ''performance_reviews'', ''id'', ''gate:nosuch'', NULL)'
        || E'\n    ) AS s(subject');
    IF v_def = pg_get_functiondef('public.trail_subjects()'::regprocedure) THEN RAISE EXCEPTION 'FIXTURE 244 G 布景失败:临时主语没有加进去'; END IF;
    EXECUTE v_def;
    v_j := pg_temp.f244_ok('G (the reviewer)', pg_temp.f244_trail(u_rev, 'fx244_gate', pr_id::text));
    PERFORM pg_temp.f244_need('G (the reviewer reads the drafting edit)', v_j, 'performance_reviews', 'UPDATE', 'summary_text');
    -- 被评审的那个人:评审已批准,表的规则("select own approved")放他进来 —— 门不放
    IF pg_temp.f244_try(u_sub, format('SELECT 1 FROM performance_reviews WHERE id = %L', pr_id)) <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 244 G 布景失败:被评审的人本应读得到已批准的评审'; END IF;
    PERFORM pg_temp.f244_refused('G (M12: the reviewed employee)', pg_temp.f244_trail(u_sub, 'fx244_gate', pr_id::text));
    PERFORM pg_temp.f244_refused('G (M12: an unknown gate admits nobody)', pg_temp.f244_trail(u_rev, 'fx244_badgate', pr_id::text));

    -- ══════════════ Q · Q13:汇总页逐行再过读规则 ══════════════
    INSERT INTO salary_change_requests (employee_id, label, old_monthly_salary, new_monthly_salary, effective_date, reason, status, created_by, snapshot)
        VALUES (e_sub, 'FX244-SCR', 3000, 3600, DATE '2026-11-01', 'fixture 244', 'submitted', u_all,
                '{"monthly_salary": 3000, "employment_status": "active"}') RETURNING id INTO scr;
    PERFORM pg_temp.f244_as(u_cl);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT to_jsonb(r) INTO v_row FROM change_log_rows(p_table => 'salary_change_requests', p_limit => 50) r
     WHERE r.row_key ->> 'id' = scr::text LIMIT 1;
    EXECUTE 'RESET ROLE';
    IF v_row IS NULL OR NOT COALESCE((v_row ->> 'row_restricted')::boolean, false)
       OR v_row -> 'new' -> 'new_monthly_salary' IS DISTINCT FROM '{"$restricted": true}'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 244 Q (Q13): a reader without view_pay must see the salary request row Restricted, got %', v_row; END IF;
    PERFORM pg_temp.f244_as(u_all);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT to_jsonb(r) INTO v_row FROM change_log_rows(p_table => 'salary_change_requests', p_limit => 50) r
     WHERE r.row_key ->> 'id' = scr::text LIMIT 1;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    IF v_row IS NULL OR COALESCE((v_row ->> 'row_restricted')::boolean, true) OR v_row -> 'new' -> 'new_monthly_salary' IS DISTINCT FROM '3600'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 244 Q (Q13): a reader with view_pay sees the row, got %', v_row; END IF;

    -- ══════════════ S · save_employee(Q8)══════════════
    PERFORM pg_temp.f244_as(u_hr);
    EXECUTE 'SET LOCAL ROLE authenticated';
    e_new := save_employee(NULL, '{"legal_name": "FX244 New Hire", "first_name": "New", "employment_type": "full_time",
        "work_category": "office", "hire_date": "2026-09-01", "employment_status": "probation"}'::jsonb,
        '{"effective_date": "2026-09-01", "change_type": "hired", "employment_type": "full_time", "employment_status": "probation"}'::jsonb);
    EXECUTE 'RESET ROLE';
    IF (SELECT count(*) FROM employment_history WHERE employee_id = e_new AND change_type = 'hired') <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 244 S: a hire must write its "hired" history row in the same call'; END IF;
    v_j := pg_temp.f244_ok('S', pg_temp.f244_trail(u_hr, 'employee', e_new::text));
    PERFORM pg_temp.f244_need('S (employee added)', v_j, 'employees', 'INSERT');
    PERFORM pg_temp.f244_need('S (hired)', v_j, 'employment_history', 'INSERT', NULL, '{"change_type": "hired"}');
    IF (SELECT count(DISTINCT e ->> 'entry_no') FROM jsonb_array_elements(v_j) e
         WHERE e ->> 'table_name' IN ('employees', 'employment_history') AND e ->> 'op' = 'INSERT') <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 244 S: the hire should read as one entry, got %', v_j; END IF;
    -- 同生共死:履历写不进去(一个不存在的 change_type)→ 员工那一行也不在
    SELECT count(*) INTO v_n FROM employees WHERE legal_name = 'FX244 Never';
    v_msg := pg_temp.f244_try(u_hr, $q$SELECT save_employee(NULL, '{"legal_name": "FX244 Never", "first_name": "N", "employment_type": "full_time",
        "work_category": "office", "hire_date": "2026-09-01", "employment_status": "active"}'::jsonb, '{"change_type": "no_such_change"}'::jsonb)$q$);
    IF v_msg = 'OK' OR (SELECT count(*) FROM employees WHERE legal_name = 'FX244 Never') <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 244 S: a failed history row must take the employee row with it (%)', v_msg; END IF;
    -- 编辑:一次调用;一列都没变就不写
    v_n := (SELECT count(*) FROM change_log WHERE table_name = 'employees' AND row_key = jsonb_build_object('id', e_new));
    -- 表单每一次交的是【整行】:取这一行今天的样子原样交回去(触发器在建行时补过的列也在里面)
    SELECT to_jsonb(e) INTO v_row FROM employees e WHERE e.id = e_new;
    v_msg := pg_temp.f244_try(u_hr, format($q$SELECT save_employee(%L, %L::jsonb, NULL)$q$, e_new, v_row));
    IF v_msg <> 'OK' OR (SELECT count(*) FROM change_log WHERE table_name = 'employees' AND row_key = jsonb_build_object('id', e_new)) <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 244 S: an edit with nothing changed must write nothing (%)', v_msg; END IF;
    v_msg := pg_temp.f244_try(u_hr, format($q$SELECT save_employee(%L, %L::jsonb,
        '{"effective_date": "2026-10-01", "change_type": "confirmed", "employment_type": "full_time", "employment_status": "active"}'::jsonb)$q$,
        e_new, v_row || '{"employment_status": "active"}'::jsonb));
    IF v_msg <> 'OK' OR NOT EXISTS (SELECT 1 FROM employment_history WHERE employee_id = e_new AND change_type = 'confirmed') THEN
        RAISE EXCEPTION 'FIXTURE 244 S: an edit with a history row (%)', v_msg; END IF;
    v_msg := pg_temp.f244_try(u_none, format($q$SELECT save_employee(%L, '{"legal_name": "X"}'::jsonb, NULL)$q$, e_new));
    IF v_msg NOT LIKE 'PERMISSION_DENIED%' THEN
        RAISE EXCEPTION 'FIXTURE 244 S: without module.hr.edit save_employee must refuse by name, got %', v_msg; END IF;

    -- ══════════════ P · 审批方针(M6 · M7)══════════════
    PERFORM pg_temp.f244_as(u_all);
    UPDATE finance_settings SET locked_before = NULL WHERE id;
    PERFORM set_approvals_policy(false, 'fx244-x', NULL, 1234);   -- 关着改(开着要求两级齐全、持有人登录得了 —— 那是开关自己的守卫,不是本支问的事)
    UPDATE finance_settings SET locked_before = DATE '2020-01-01' WHERE id;      -- 锁期那一块的事
    PERFORM set_config('request.jwt.claims', '', true);
    v_j := pg_temp.f244_ok('P', pg_temp.f244_trail(u_all, 'approval_policy', 'true'));
    PERFORM pg_temp.f244_need('P (the policy columns)', v_j, 'finance_settings', 'UPDATE', 'approval_threshold_base');
    PERFORM pg_temp.f244_need('P (M7: its history table)', v_j, 'finance_settings_history', 'INSERT');
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e, jsonb_array_elements_text(COALESCE(e -> 'changed_columns', '[]')) c
                WHERE e ->> 'table_name' = 'finance_settings'
                  AND c NOT IN ('approvals_enabled', 'approval_threshold_base', 'approval_level1_role_code', 'approval_level2_role_code')) THEN
        RAISE EXCEPTION 'FIXTURE 244 P (M6): the approval-policy panel shows columns it does not own: %', v_j; END IF;
    PERFORM pg_temp.f244_refused('P (no manage_permissions)', pg_temp.f244_trail(u_hr, 'approval_policy', 'true'));

    -- ══════════════ I · 导入批次 ══════════════
    INSERT INTO import_batches (target_table, file_name, row_count, code_first, code_last, imported_by)
        VALUES ('suppliers', 'fx244-suppliers.csv', 2, 'SUP-FX244-1', 'SUP-FX244-2', u_all) RETURNING id INTO ib_id;
    v_j := pg_temp.f244_ok('I', pg_temp.f244_trail(u_all, 'import_batch', ib_id::text));
    PERFORM pg_temp.f244_need('I (the batch)', v_j, 'import_batches', 'INSERT', NULL, '{"file_name": "fx244-suppliers.csv"}');
    PERFORM pg_temp.f244_refused('I (no bulk_import)', pg_temp.f244_trail(u_hr, 'import_batch', ib_id::text));

    -- ══════════════ D · 删掉的记录(Q25 · Q26)══════════════
    PERFORM pg_temp.f244_as(u_all);
    INSERT INTO departments (code, name_en, name_zh) VALUES ('FX244-D', 'FX244 Dept', 'f') RETURNING id INTO d_id;
    INSERT INTO training_records (employee_id, training_name, completed_date) VALUES (e_acc, 'FX244 Training', DATE '2026-01-15') RETURNING id INTO tr_id;
    UPDATE departments SET deleted_at = now() WHERE id = d_id;
    UPDATE training_records SET deleted_at = now() WHERE id = tr_id;
    UPDATE roles SET deleted_at = now(), is_active = false WHERE id = r_cl;
    UPDATE employees SET deleted_at = now() WHERE id = e_new;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM deleted_records dr
     WHERE (dr.record_kind, dr.record_id) IN (('department', d_id), ('training_record', tr_id), ('role', r_cl), ('employee', e_new))
       AND dr.deleted_by = u_all;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    IF v_n <> 4 THEN RAISE EXCEPTION 'FIXTURE 244 D: four deleted kinds with "who" from the change log, got %', v_n; END IF;
    v_j := pg_temp.f244_ok('D (deleted department trail)', pg_temp.f244_trail(u_hr, 'department', d_id::text));
    PERFORM pg_temp.f244_need('D (the deletion)', v_j, 'departments', 'UPDATE', 'deleted_at');

    -- ══════════════ N · 匿名化(Q30)══════════════
    UPDATE hr_settings SET personal_data_retention_months = 12;
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, employment_status, separation_date, separation_type)
        VALUES (e_anon, 'FX244-ANON', 'FX244 To Forget', 'full_time', 'office', DATE '2019-01-01', 'separated', DATE '2020-01-31', 'resignation');
    PERFORM pg_temp.f244_as(u_all);
    PERFORM anonymise_employee(e_anon, 'fixture 244: retention elapsed');
    PERFORM set_config('request.jwt.claims', '', true);
    v_j := pg_temp.f244_ok('N', pg_temp.f244_trail(u_all, 'employee', e_anon::text));
    PERFORM pg_temp.f244_need('N (personal data anonymised)', v_j, 'employees', 'UPDATE', 'anonymised_at');
    IF v_j::text LIKE '%FX244 To Forget%' THEN RAISE EXCEPTION 'FIXTURE 244 N: the anonymised name is still on the trail'; END IF;
    PERFORM pg_temp.f244_as(u_all);
    IF trail_actor('prelog', NULL, e_anon) ->> 'state' IS DISTINCT FROM 'anonymised' THEN
        RAISE EXCEPTION 'FIXTURE 244 N: an anonymised person should read as "A former employee" (state anonymised), got %',
            trail_actor('prelog', NULL, e_anon); END IF;
    PERFORM set_config('request.jwt.claims', '', true);

    RAISE NOTICE 'FIXTURE 244 全部通过:A(M9)· C(M10)· E(Q21 · Q24)· R(Q22)· K(M11)· G(M12)· Q(Q13)· S(Q8)· P(M6 · M7)· I · D(Q25 · Q26)· N(Q30)';
END;
$$;

ROLLBACK;
