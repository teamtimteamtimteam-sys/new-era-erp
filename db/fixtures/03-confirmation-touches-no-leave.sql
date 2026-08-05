-- 03 转正不碰假期账
--
-- 为什么值得常设:HR-2c 之后年假是【按月累积、读时派生】的,转正不再"发"任何假期。
-- 若哪天有人给 approve_review 加一句"转正送 N 天",它会静静地多给假 —— 没有报错,
-- 只有年底对不上。这是一条【负向不变量】:断言"什么都没发生"。
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid(); v_role uuid; v_emp uuid; v_rev uuid;
    d date := '2026-06-15';
    v_before int; v_after int; v_bal_before numeric; v_bal_after numeric;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-03', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);

    -- 【前提显式化】锁位与评级表都是运行时可改的:即便默认值恰好合用,也要自己设定,
    -- 否则这条断言的成立与否取决于别人改没改过配置(README 第 5 条)。
    UPDATE finance_settings SET locked_before = NULL;
    INSERT INTO review_rating_scale (code, name_en, name_zh, sort_order, is_probation_pass)
    VALUES ('FIXT-PASS-03', 'Fixture Pass', '测试合格', 999, true);

    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date,
                           employment_status, probation_end_date, monthly_salary)
    -- 入职日必须让 probation_end_date ≤ 入职 + 3 个月(employees_probation_cap)
    VALUES ('FIXT-E3', 'Fixture Employee 3', 'full_time', 'office', '2026-04-01',
            'probation', d, 3000)
    RETURNING id INTO v_emp;

    -- 一份可批准的试用期评估(评估人另设一名员工 —— 不能自己评自己)
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date)
    VALUES ('FIXT-E3R', 'Fixture Reviewer 3', 'full_time', 'office', '2025-01-01');
    INSERT INTO performance_reviews (employee_id, review_type, period_start, period_end,
                                     reviewer_employee_id, status, rating_code, summary_text,
                                     probation_outcome)
    SELECT v_emp, 'probation', '2026-04-01', d,
           (SELECT id FROM employees WHERE code = 'FIXT-E3R'),
           'submitted', 'FIXT-PASS-03',
           'fixture summary', 'confirm'
    RETURNING id INTO v_rev;

    SELECT count(*) INTO v_before FROM leave_grants WHERE employee_id = v_emp;
    SELECT COALESCE((leave_balance(v_emp, 'annual')->>'granted')::numeric, 0) INTO v_bal_before;

    PERFORM approve_review(v_rev);

    SELECT count(*) INTO v_after FROM leave_grants WHERE employee_id = v_emp;
    SELECT COALESCE((leave_balance(v_emp, 'annual')->>'granted')::numeric, 0) INTO v_bal_after;

    -- 【不变量】转正本身不得往假期账里写任何一行,也不得改变已累积的额度
    IF v_after <> v_before THEN
        RAISE EXCEPTION 'FIXTURE 03 失败:转正往 leave_grants 写了行(前 %,后 %)—— 年假是派生的,转正不发假',
            v_before, v_after;
    END IF;
    IF v_bal_after IS DISTINCT FROM v_bal_before THEN
        RAISE EXCEPTION 'FIXTURE 03 失败:转正改变了年假额度(前 %,后 %)', v_bal_before, v_bal_after;
    END IF;
    -- 而转正本身必须确实发生了(否则上面两条会因为"什么都没做"而假通过)
    IF NOT EXISTS (SELECT 1 FROM employees WHERE id = v_emp AND confirmation_date IS NOT NULL) THEN
        RAISE EXCEPTION 'FIXTURE 03 失败:approve_review 没有写下转正日 —— 负向断言无从谈起';
    END IF;
END $$;
ROLLBACK;
