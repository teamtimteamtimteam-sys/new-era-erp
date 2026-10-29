-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 302 —— 看不见身份四列的人保存员工表单,那四列原样不动(GOLIVE-1 第 11 行,Tim 2026-10-23 TABLE-EXPORT-2b Q5 · 2026-10-29 Q8)
-- ═══════════════════════════════════════════════════════════════════════════
-- 【钉的事】save_employee(SECURITY INVOKER)以编辑页真的那个样子被调:表单交回整行,而看不见的四格是空的(页面画「受限」、不送值 ——
--   readForm 把不在表单里的格读成 NULL):
--   A  持 module.hr.view + edit、【不】持 data.view_identity 的编辑者(线上今天只有 cco 这样):legal_name 改了,
--      work_email · work_phone · identity_no · work_pass_no 四列原样(S1234567A 不变成 NULL —— TABLE-EXPORT-2b 量到的正是这一处)
--   B  对照:持 data.view_identity 的编辑者交回空的四格 → 四列真的被清(这条路照旧,证明 A 不是"什么都没写")
--   C  本人:一个持 hr.edit 而不持 data.view_identity 的人改【自己】那一行,看得见自己的四列(employees_masked 的 OR id = 本人),
--      他交的新值照写
--   D  新建(p_id 为空)不变:不持 data.view_identity 的人新建,填的证件号照写(Q8:新建页不变)
--   E  ★ 故障注入(每次都跑):子事务里把 save_employee 里那一支分岔关掉(ELSIF false AND …),A 的判据必须读出四列被清成 NULL;子事务回滚
-- 自带数据:角色、授予、auth.users 行(employees.user_id 有外键)、员工全部本支自造。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '120s';

CREATE FUNCTION pg_temp.f302_save(p_user uuid, p_id uuid, p_fields jsonb) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v uuid;
BEGIN
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v := save_employee(p_id, p_fields, NULL);
    EXECUTE 'RESET ROLE';
    RETURN v;
END;
$f$;

-- 编辑页交回的样子:这一行今天的值(以 postgres 读基表),看不见的四格是空的
CREATE FUNCTION pg_temp.f302_form(p_id uuid, p_masked boolean) RETURNS jsonb
LANGUAGE sql AS $f$
    SELECT to_jsonb(e) - 'id' - 'code' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by'
           || CASE WHEN p_masked THEN '{"work_email": null, "work_phone": null, "identity_no": null, "work_pass_no": null}'::jsonb ELSE '{}'::jsonb END
      FROM employees e WHERE e.id = p_id
$f$;

CREATE FUNCTION pg_temp.f302_four(p_id uuid) RETURNS text
LANGUAGE sql AS $f$
    SELECT concat_ws(' | ', coalesce(work_email, 'NULL'), coalesce(work_phone, 'NULL'), coalesce(identity_no, 'NULL'), coalesce(work_pass_no, 'NULL'))
      FROM employees WHERE id = p_id
$f$;

DO $f302$
DECLARE
    u_ed   uuid := '00000000-0000-4000-8000-0000030200e1';   -- hr.view + hr.edit,不持 data.view_identity
    u_id   uuid := '00000000-0000-4000-8000-0000030200e2';   -- 再加 data.view_identity
    e_a uuid := '00000000-0000-4000-8000-0000030200a1';
    e_b uuid := '00000000-0000-4000-8000-0000030200a2';
    e_me uuid := '00000000-0000-4000-8000-0000030200a3';
    e_new uuid;
    k_four text := 'a@zz.test | +65 6000 0000 | S1234567A | G7654321X';
    v text;
    v_fdef text;
BEGIN
    INSERT INTO auth.users (id) VALUES (u_ed), (u_id);
    INSERT INTO roles (code, name_en, name_zh) VALUES ('zz-fx302-ed', 'ZZ fixture 302 editor', 'ZZ fixture 302 editor'),
                                                      ('zz-fx302-id', 'ZZ fixture 302 identity', 'ZZ fixture 302 identity');
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT id, c FROM roles, unnest(ARRAY['module.hr.view', 'module.hr.edit']) c WHERE code IN ('zz-fx302-ed', 'zz-fx302-id');
    INSERT INTO role_permissions (role_id, permission_code) SELECT id, 'data.view_identity' FROM roles WHERE code = 'zz-fx302-id';
    INSERT INTO user_roles (user_id, role_id) SELECT u_ed, id FROM roles WHERE code = 'zz-fx302-ed';
    INSERT INTO user_roles (user_id, role_id) SELECT u_id, id FROM roles WHERE code = 'zz-fx302-id';
    INSERT INTO employees (id, code, legal_name, first_name, employment_type, work_category, hire_date, employment_status,
                           work_email, work_phone, residency_status, identity_no, work_pass_type, work_pass_no, work_pass_issue_date, work_pass_expiry_date, user_id) VALUES
        (e_a,  'FX302-A',  'FX302 Alpha', 'Alpha', 'full_time', 'office', DATE '2020-01-01', 'active',
         'a@zz.test', '+65 6000 0000', 'work_pass', 'S1234567A', 'EP', 'G7654321X', DATE '2025-01-01', DATE '2027-01-01', NULL),
        (e_b,  'FX302-B',  'FX302 Bravo', 'Bravo', 'full_time', 'office', DATE '2020-01-01', 'active',
         'a@zz.test', '+65 6000 0000', 'work_pass', 'S1234567A', 'EP', 'G7654321X', DATE '2025-01-01', DATE '2027-01-01', NULL),
        (e_me, 'FX302-ME', 'FX302 Myself', 'Me', 'full_time', 'office', DATE '2020-01-01', 'active',
         'a@zz.test', '+65 6000 0000', 'work_pass', 'S1234567A', 'EP', 'G7654321X', DATE '2025-01-01', DATE '2027-01-01', u_ed);

    -- A
    PERFORM pg_temp.f302_save(u_ed, e_a, pg_temp.f302_form(e_a, true) || '{"legal_name": "FX302 Alpha Renamed"}'::jsonb);
    IF (SELECT legal_name FROM employees WHERE id = e_a) <> 'FX302 Alpha Renamed' THEN RAISE EXCEPTION 'FIXTURE 302 A: the save did not write the name'; END IF;
    v := pg_temp.f302_four(e_a);
    IF v <> k_four THEN RAISE EXCEPTION 'FIXTURE 302 A: a writer without data.view_identity changed the four identity columns: % (was %)', v, k_four; END IF;
    -- B
    PERFORM pg_temp.f302_save(u_id, e_b, pg_temp.f302_form(e_b, true));
    v := pg_temp.f302_four(e_b);
    IF v <> 'NULL | NULL | NULL | NULL' THEN RAISE EXCEPTION 'FIXTURE 302 B: a writer with data.view_identity sending blanks should clear them, got %', v; END IF;
    -- C
    PERFORM pg_temp.f302_save(u_ed, e_me, pg_temp.f302_form(e_me, false) || '{"identity_no": "S7777777Z"}'::jsonb);
    IF (SELECT identity_no FROM employees WHERE id = e_me) <> 'S7777777Z' THEN RAISE EXCEPTION 'FIXTURE 302 C: an editor changing his own identity number was ignored'; END IF;
    -- D
    e_new := pg_temp.f302_save(u_ed, NULL, '{"legal_name": "FX302 New", "first_name": "New", "employment_type": "full_time", "work_category": "office",
                                             "hire_date": "2026-10-01", "employment_status": "probation", "identity_no": "S5555555A"}'::jsonb);
    IF (SELECT identity_no FROM employees WHERE id = e_new) IS DISTINCT FROM 'S5555555A' THEN RAISE EXCEPTION 'FIXTURE 302 D: a new employee lost the identity number typed in'; END IF;
    -- E · 故障注入
    v_fdef := pg_get_functiondef('public.save_employee(uuid,jsonb,jsonb)'::regprocedure);
    IF v_fdef NOT LIKE '%ELSIF NOT (has_permission(''data.view_identity'')%' THEN RAISE EXCEPTION 'FIXTURE 302 E: the branch to inject into is not there'; END IF;
    BEGIN
        EXECUTE replace(v_fdef, 'ELSIF NOT (has_permission(''data.view_identity'')', 'ELSIF false AND NOT (has_permission(''data.view_identity'')');
        UPDATE employees SET work_email = 'a@zz.test', work_phone = '+65 6000 0000', identity_no = 'S1234567A', work_pass_no = 'G7654321X' WHERE id = e_a;
        PERFORM pg_temp.f302_save(u_ed, e_a, pg_temp.f302_form(e_a, true));
        IF pg_temp.f302_four(e_a) <> 'NULL | NULL | NULL | NULL' THEN
            RAISE EXCEPTION 'FIXTURE 302 E: without the branch arm A still kept the four columns (%) — it does not measure the branch', pg_temp.f302_four(e_a);
        END IF;
        RAISE EXCEPTION 'f302 injection ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'f302 injection ok' THEN RAISE; END IF;
    END;
    IF pg_get_functiondef('public.save_employee(uuid,jsonb,jsonb)'::regprocedure) <> v_fdef THEN RAISE EXCEPTION 'FIXTURE 302 E: the injection did not roll back'; END IF;
    RAISE NOTICE 'FIXTURE 302 全部通过: 看不见身份四列的编辑者保存,四列原样、别的照写(A);看得见的交空就清(B);本人改自己的照写(C);新建照写(D);关掉那一支,A 的判据读出四列被清(E)';
END
$f302$;
ROLLBACK;
