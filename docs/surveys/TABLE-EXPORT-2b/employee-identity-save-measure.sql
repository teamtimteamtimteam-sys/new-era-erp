-- TABLE-EXPORT-2b-1 · Tim 2026-10-23 Q5(员工编辑那一半):量,不修。
-- 问题:一个持 module.hr.edit、【不】持 data.view_identity 的人打开员工编辑页(identity_no 预填空白),什么都不改就保存 ——
--       库里的证件号会不会被清空?
-- 对着【本地重建库】跑(db/verify_rebuild.py --offline 建的空库),整支回滚。绝不对着线上跑。
-- 表单的形状:app/hr/employees/actions.ts readForm → `identity_no: s('identity_no') || null`,经 save_employee(SECURITY INVOKER)写。
-- 两臂:A 看不见证件号的编辑者照表单的样子送 identity_no = null;B 对照臂 —— 看得见的编辑者送回原值。
\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE
    u_blind uuid := gen_random_uuid(); u_full uuid := gen_random_uuid();
    r_blind uuid; r_full uuid; e uuid; seen text; v_after text; v_after_b text; f jsonb;
BEGIN
    INSERT INTO auth.users (id, email_confirmed_at) VALUES (u_blind, now()), (u_full, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('m-blind','m','m',true) RETURNING id INTO r_blind;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('m-full','m','m',true) RETURNING id INTO r_full;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_blind, c FROM unnest(ARRAY['module.hr.view','module.hr.edit']) c;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_full, c FROM unnest(ARRAY['module.hr.view','module.hr.edit','data.view_identity']) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u_blind, r_blind), (u_full, r_full);
    INSERT INTO employees (code, legal_name, first_name, employment_type, work_category, hire_date, identity_no, residency_status)
    VALUES ('MEAS-1', 'Measure One', 'Measure', 'full_time', 'office', CURRENT_DATE - 100, 'S1234567A', 'citizen') RETURNING id INTO e;

    -- 编辑页读的那一份(employees_masked)对看不见的人是什么
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_blind), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT identity_no INTO seen FROM employees_masked WHERE id = e;
    -- 表单交上来的那一份:各列照原样,identity_no 是空白读成的 null
    f := jsonb_build_object('legal_name','Measure One','first_name','Measure','employment_type','full_time','work_category','office',
                            'hire_date', (CURRENT_DATE - 100)::text, 'employment_status','active','residency_status','citizen','identity_no', NULL);
    PERFORM save_employee(e, f, NULL);
    EXECUTE 'RESET ROLE';
    SELECT identity_no INTO v_after FROM employees WHERE id = e;

    -- 对照臂:看得见的人送回原值
    UPDATE employees SET identity_no = 'S1234567A' WHERE id = e;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_full), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM save_employee(e, f || jsonb_build_object('identity_no', 'S1234567A'), NULL);
    EXECUTE 'RESET ROLE';
    SELECT identity_no INTO v_after_b FROM employees WHERE id = e;

    RAISE NOTICE 'MEASURE|A blind editor: employees_masked.identity_no read as % ; after save the stored identity_no is %', COALESCE(seen,'NULL'), COALESCE(v_after,'NULL');
    RAISE NOTICE 'MEASURE|B control (data.view_identity): after save the stored identity_no is %', COALESCE(v_after_b,'NULL');
END;
$$;
ROLLBACK;
