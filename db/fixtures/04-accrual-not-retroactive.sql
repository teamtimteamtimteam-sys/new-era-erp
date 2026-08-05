-- 04 改了工作类别,先前月份的累积【不】跟着改口径
--
-- 为什么值得常设:accrued_annual_leave_detail 逐月调 employee_work_category_at()。
-- 若哪天有人图省事改成"取当前类别",一次调岗就会把过去所有月份按新费率重算 ——
-- 假期额度凭空长出来一截,而没有任何东西会报错。
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid(); v_role uuid; v_emp uuid;
    v_before numeric; v_after numeric; v_rate_a numeric; v_rate_b numeric;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-04', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);

    -- 两个类别的费率必须不同,这条断言才有意义 —— 先自证前提
    SELECT days_per_year INTO v_rate_a FROM leave_accrual_rates
    WHERE work_category = 'office' AND employee_id IS NULL ORDER BY effective_from DESC LIMIT 1;
    SELECT days_per_year INTO v_rate_b FROM leave_accrual_rates
    WHERE work_category = 'shopfloor' AND employee_id IS NULL ORDER BY effective_from DESC LIMIT 1;
    IF v_rate_a IS NULL OR v_rate_b IS NULL OR v_rate_a = v_rate_b THEN
        RAISE EXCEPTION 'FIXTURE 04 无法进行:office/shopfloor 的年假费率相同或缺失(% / %)—— 断言前提不成立',
            v_rate_a, v_rate_b;
    END IF;

    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date,
                           employment_status)
    VALUES ('FIXT-E4', 'Fixture Employee 4', 'full_time', 'shopfloor', '2026-01-01', 'active')
    RETURNING id INTO v_emp;

    -- 【入职那条履历必须先有】employee_work_category_at 的回退规则是:该月之前没有
    -- 记录时,取【最早一条】记录的类别。只插调岗那一条的话,一月也会被判成调岗后的
    -- 类别 —— 那不是 bug,是这个 fixture 少造了数据(第一版就栽在这)。
    INSERT INTO employment_history (employee_id, effective_date, change_type, work_category)
    VALUES (v_emp, '2026-01-01', 'hired', 'shopfloor');

    SELECT accrued_annual_leave(v_emp, '2026-06-30') INTO v_before;

    -- 调岗:6 月起转办公室(employment_history 是 employee_work_category_at 的依据)
    INSERT INTO employment_history (employee_id, effective_date, change_type, work_category)
    VALUES (v_emp, '2026-06-01', 'category_change', 'office');
    UPDATE employees SET work_category = 'office' WHERE id = v_emp;

    SELECT accrued_annual_leave(v_emp, '2026-06-30') INTO v_after;

    -- 【不变量】只有 6 月本身可以按新费率;1–5 月必须原样。
    -- 于是差额【不能】达到"全部 6 个月都按新费率"的程度。
    -- 具体数字不断言 —— 费率改了、月份取整口径调了,这条仍然成立。
    IF v_after > v_before + (v_rate_a - v_rate_b) / 12.0 * 1.5 THEN
        RAISE EXCEPTION 'FIXTURE 04 失败:调岗把先前月份也按新费率重算了(调岗前 %,调岗后 %)—— 累积应逐月按【当月】类别',
            v_before, v_after;
    END IF;
    IF v_after < v_before THEN
        RAISE EXCEPTION 'FIXTURE 04 失败:调岗后累积反而变少(% → %)', v_before, v_after;
    END IF;
END $$;
ROLLBACK;
