-- db/scripts/2026-09-23-role1-live-proof.sql
-- ROLE-1 · Batch 1 的线上证明 —— 【只有拒绝与读回】,整支一笔事务,最后 ROLLBACK。
--
-- 为什么不在 db/fixtures/:它要的是【线上真账号】(sandra@ / chooer@ / tim@ / admin@ …)
-- 在【线上真数据】上被拒 —— 重建库里没有这些人。fixture 209 在重建库上证同一批规矩的形状;
-- 这一支证的是"线上此刻,这几个人,真的被拒了"。
--
-- 身份:以 postgres 连接(rolbypassrls = t),每一格用 set_config('request.jwt.claims') 换成
-- 那个真账号,并在 SET LOCAL ROLE authenticated 之下跑 —— RLS 与列权限按那个人判,
-- 不是按 postgres 判。每个人至少一格【会通过门】的对照(撞上的是"单据不存在",不是权限)。
--
-- 失败 = RAISE(退出码非零);成功 = 最后一行 NOTICE 'ROLE1 LIVE PROOF: n cells passed'。
BEGIN;

CREATE FUNCTION pg_temp.as_user(p_email text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
    SELECT id INTO v FROM auth.users WHERE email = p_email;
    IF v IS NULL THEN RAISE EXCEPTION 'PROOF_SETUP|no such account %', p_email; END IF;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
    RETURN v;
END $$;

-- 跑一句 SQL,读回它的报错(没有报错 → NULL)
CREATE FUNCTION pg_temp.try_sql(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_msg text;
BEGIN
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        EXECUTE p_sql;
        EXECUTE 'RESET ROLE';
        RETURN NULL;
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        EXECUTE 'RESET ROLE';
        RETURN v_msg;
    END;
END $$;

DO $proof$
DECLARE
    c record;
    v_msg text;
    v_n int := 0;
    v_lv uuid;
    v_emp uuid;
    v_codes text;
    v_cells int := 0;
BEGIN
    SELECT id INTO v_lv FROM leave_requests WHERE code = 'LV-2026-0001';
    SELECT id INTO v_emp FROM employees WHERE code = 'EMP-2026-0003';   -- Vince:不是任何一格的当事人

    FOR c IN SELECT * FROM (VALUES
      -- who, what, sql, expected (LIKE pattern; NULL = must succeed)
      ('sandra@evoltrya.test', 'cco 改不了角色授权(manage_permissions 归 admin)',
         format('SELECT set_user_roles(%L::uuid, ARRAY[]::uuid[], %L)', (SELECT id FROM auth.users WHERE email='vince@evoltrya.test'), 'proof'),
         'PERMISSION_DENIED|action.manage_permissions'),
      ('sandra@evoltrya.test', 'cco 决定不了请假(决定码归 finance / cfo)',
         format('SELECT decide_leave_request(%L::uuid, false, %L)', v_lv, 'proof'), 'PERMISSION_DENIED|action.decide_hr_requests'),
      ('sandra@evoltrya.test', 'cco 分摊不了加工成本(归财务)',
         'SELECT allocate_processing_costs(gen_random_uuid(), ''weight'')', 'PERMISSION_DENIED|module.finance.edit'),
      ('sandra@evoltrya.test', 'cco 做不了批量导入(归 admin)',
         'SELECT master_import_apply(''materials'', ''[]''::jsonb, ''proof.csv'', true)', 'PERMISSION_DENIED|action.bulk_import'),
      ('sandra@evoltrya.test', '【对照】cco 过得了评估那扇门(撞上的是评估不存在)',
         'SELECT void_review(gen_random_uuid(), ''proof'')', 'REVIEW_NOT_FOUND%'),

      ('chooer@evoltrya.test', 'finance 重开不了已关的月(归 CFO)',
         'SELECT reopen_period(DATE ''2026-07-31'', ''proof'')', 'PERMISSION_DENIED|action.finance_reopen'),
      ('chooer@evoltrya.test', 'finance 手动锁的侧门:清空锁 = 重开 2026-07 → 按名拒',
         'UPDATE finance_settings SET locked_before = NULL WHERE id', 'REOPEN_THROUGH_CLOSE_ONLY|2026-07-31'),
      ('chooer@evoltrya.test', 'finance 决定不了【自己的】请假(四眼)',
         format('SELECT decide_leave_request(%L::uuid, false, %L)', v_lv, 'proof'), 'SELF_APPROVAL_FORBIDDEN|raiser'),
      ('chooer@evoltrya.test', 'finance 直连改不了月薪',
         format('UPDATE employees SET monthly_salary = 1 WHERE id = %L::uuid', v_emp), 'SALARY_DIRECT_WRITE_REFUSED'),
      ('chooer@evoltrya.test', '【对照】finance 过得了请假决定那扇门(撞上的是单据不存在)',
         'SELECT decide_leave_request(gen_random_uuid(), false, ''proof'')', 'REQUEST_NOT_FOUND'),

      ('tim@evoltrya.test', '【对照】CFO 过得了请假决定那扇门',
         'SELECT decide_leave_request(gen_random_uuid(), false, ''proof'')', 'REQUEST_NOT_FOUND'),
      ('tim@evoltrya.test', '【对照】CFO 过得了重开那扇门(撞上的是那个月没有关账记录)',
         'SELECT reopen_period(DATE ''2026-06-30'', ''proof'')', 'CLOSE_NOT_FOUND'),
      ('tim@evoltrya.test', 'CFO 仍然开不了采购单(没有 purchasing.edit —— 批的人不开单)',
         'SELECT create_purchase_order(NULL::uuid, CURRENT_DATE, NULL::date, NULL::text, NULL::numeric, NULL::text, NULL::text, NULL::text, ''[]''::jsonb, NULL::jsonb, NULL::text)', 'PERMISSION_DENIED|%'),

      ('admin@swm-os.test', 'admin 决定不了请假(一个业务码都不持)',
         'SELECT decide_leave_request(gen_random_uuid(), false, ''proof'')', 'PERMISSION_DENIED|action.decide_hr_requests'),
      ('admin@swm-os.test', 'admin 过不了财务的门',
         'SELECT reverse_payment(gen_random_uuid(), ''proof'')', 'PERMISSION_DENIED|module.finance.edit'),
      ('admin@swm-os.test', '【对照】admin 过得了匿名化那扇门(撞上的是理由为空)',
         'SELECT anonymise_employee(gen_random_uuid(), '''')', 'PDPA_REASON_REQUIRED'),

      ('phua@evolytra.test', 'cto 做不了批量导入(归 admin)',
         'SELECT master_import_apply(''materials'', ''[]''::jsonb, ''proof.csv'', true)', 'PERMISSION_DENIED|action.bulk_import')
    ) t(who, what, sql, expect) LOOP
        PERFORM pg_temp.as_user(c.who);
        v_msg := pg_temp.try_sql(c.sql);
        IF c.expect IS NULL THEN
            IF v_msg IS NOT NULL THEN
                RAISE EXCEPTION 'ROLE1 LIVE PROOF FAILED | % | % | expected success, got %', c.who, c.what, v_msg;
            END IF;
        ELSIF v_msg IS NULL OR v_msg NOT LIKE c.expect THEN
            RAISE EXCEPTION 'ROLE1 LIVE PROOF FAILED | % | % | expected %, got %', c.who, c.what, c.expect, COALESCE(v_msg, '(no error)');
        END IF;
        v_cells := v_cells + 1;
        RAISE NOTICE 'ok  % | % | %', c.who, c.what, COALESCE(v_msg, '(succeeded)');
    END LOOP;

    -- 读回:admin 读得到可关联的人(employee_lookup),读不到员工档案本表以外的任何人
    PERFORM pg_temp.as_user('admin@swm-os.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM employee_lookup WHERE deleted_at IS NULL;
    EXECUTE 'RESET ROLE';
    IF v_n < 6 THEN
        RAISE EXCEPTION 'ROLE1 LIVE PROOF FAILED | admin@ | employee_lookup | expected >= 6 names, got %', v_n; END IF;
    RAISE NOTICE 'ok  admin@ | employee_lookup rows (as authenticated) | %', v_n;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM invoices_masked;
    EXECUTE 'RESET ROLE';
    RAISE NOTICE 'read  admin@ | invoices_masked rows (as authenticated) | %', v_n;
    -- 同一会话的对照:finance 读得到发票
    PERFORM pg_temp.as_user('chooer@evoltrya.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM invoices_masked;
    EXECUTE 'RESET ROLE';
    RAISE NOTICE 'read  chooer@ | invoices_masked rows (as authenticated, control) | %', v_n;

    -- 读回:每个真账号此刻持有的码(current_user_permissions 按 JWT 解析)
    FOR c IN SELECT email FROM auth.users WHERE email IN ('admin@swm-os.test','tim@evoltrya.test','chooer@evoltrya.test',
             'sandra@evoltrya.test','phua@evolytra.test','fusheng@evoltrya.test','vince@evoltrya.test') ORDER BY email LOOP
        PERFORM pg_temp.as_user(c.email);
        SELECT string_agg(x, ' ' ORDER BY x) INTO v_codes FROM unnest(current_user_permissions()) x;
        RAISE NOTICE 'codes  % | %', c.email, v_codes;
    END LOOP;
    RAISE NOTICE 'ROLE1 LIVE PROOF: % refusal/control cells passed', v_cells;
END
$proof$;

ROLLBACK;
