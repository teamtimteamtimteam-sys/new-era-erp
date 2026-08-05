-- 11 年末结转不许跨过"本库开始运营"那一天
--
-- 为什么值得常设:结转按【入职日】算累积,与本库那年在不在运行无关。少了这道守卫,
-- 在切换上线的那一年跑一次结转,就会给老员工凭空造出一整年的假期余额 ——
-- 数字合理、无报错。这条 fixture 的两半缺一不可:拒绝要拒对,放行也要真的放行。
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid(); v_role uuid; v_emp uuid;
    v_msg text; v_ok boolean; v_res jsonb;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-11', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);

    -- 【前提显式化】开始日与锁位都自己设(README 第 5 条)。
    -- 本库"从 2026-01-01 开始运营":于是 2025 年结转应拒,2026 年结转应放行。
    UPDATE finance_settings SET locked_before = NULL, system_start_date = '2026-01-01';

    -- 一位【早于开始日入职】的员工 —— 正是会被凭空算出一年累积的那种
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date,
                           employment_status)
    VALUES ('FIXT-E11', 'Fixture Employee 11', 'full_time', 'office', '2020-03-01', 'active')
    RETURNING id INTO v_emp;
    INSERT INTO employment_history (employee_id, effective_date, change_type, work_category)
    VALUES (v_emp, '2020-03-01', 'hired', 'office');

    -- ① 目标年在开始日【之前】→ 必须按名拒绝
    v_ok := false;
    BEGIN
        PERFORM carry_forward_annual_leave(2025);
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'CARRY_FORWARD_BEFORE_SYSTEM_START|2025|2026-01-01%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 11① 失败:2025 年末早于开始日 2026-01-01,应抛 CARRY_FORWARD_BEFORE_SYSTEM_START,实得:%',
            COALESCE(v_msg, '(放行了 —— 会凭空造出 2020 年入职者的整年余额)');
    END IF;

    -- ② 目标年在开始日【之后】→ 必须照常工作(否则①可能只是因为"结转全坏了"而通过)
    v_res := carry_forward_annual_leave(2026);
    IF v_res IS NULL OR (v_res->>'into_year')::int <> 2027 THEN
        RAISE EXCEPTION 'FIXTURE 11② 失败:2026 年末不早于开始日,结转应照常执行,实得 %', v_res;
    END IF;

    -- ③ 没设开始日 = 不知道基线 → 也必须拒(NULL 不等于"不限制")
    UPDATE finance_settings SET system_start_date = NULL;
    v_ok := false;
    BEGIN
        PERFORM carry_forward_annual_leave(2026);
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'SYSTEM_START_NOT_SET%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 11③ 失败:未设开始日时应抛 SYSTEM_START_NOT_SET,实得:%',
            COALESCE(v_msg, '(放行了 —— 从一个不知道的基线往前结转)');
    END IF;
END $$;
ROLLBACK;
