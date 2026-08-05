-- 05 发薪:一人一条银行行
--
-- 为什么值得常设:FIN-4 的整个理由就是【银行对账单上一人一行】。若哪天有人
-- "优化"成一条汇总付款,账仍然平、总额仍然对,但对账从此逐行对不上 —— 没有报错。
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid(); v_role uuid; v_period uuid; v_emp uuid;
    v_ids uuid[] := '{}'; v_je uuid; d date := '2026-06-25';
    v_bank_lines int; v_debit_lines int; v_memos int; i int;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-05', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO payroll_periods (code, period_month, payment_date, currency, fx_rate, status)
    VALUES ('FIXT-PR5', '2026-06-01', d, 'SGD', 1, 'posted') RETURNING id INTO v_period;

    -- 五名员工,各一条工资行
    FOR i IN 1..5 LOOP
        INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date)
        VALUES ('FIXT-E5-' || i, 'Fixture Employee 5-' || i, 'full_time', 'office', '2026-01-01')
        RETURNING id INTO v_emp;
        INSERT INTO payroll_lines (payroll_period_id, employee_id, gross_pay, net_pay)
        VALUES (v_period, v_emp, 3000 + i, 2500 + i);
        v_ids := v_ids || (SELECT id FROM payroll_lines
                           WHERE payroll_period_id = v_period AND employee_id = v_emp);
    END LOOP;

    PERFORM pay_payroll_lines(v_period, v_ids, d, NULL);

    SELECT je.id INTO v_je FROM journal_entries je
    WHERE je.source_type = 'payroll' AND je.source_id = v_period
    ORDER BY je.created_at DESC LIMIT 1;

    -- 【不变量】银行侧行数 = 人数;每行备注各不相同(对账要能逐行认人);
    -- 借方只有一条汇总(2300)。金额不断言 —— 那不是这条规矩关心的事。
    SELECT count(*) INTO v_bank_lines FROM journal_lines l
    JOIN accounts a ON a.id = l.account_id
    WHERE l.entry_id = v_je AND a.code IN ('1000','1010') AND l.credit > 0;
    IF v_bank_lines <> 5 THEN
        RAISE EXCEPTION 'FIXTURE 05 失败:五个人应产生 5 条银行行(一人一条),实得 %', v_bank_lines;
    END IF;

    SELECT count(DISTINCT l.line_memo) INTO v_memos FROM journal_lines l
    JOIN accounts a ON a.id = l.account_id
    WHERE l.entry_id = v_je AND a.code IN ('1000','1010') AND l.credit > 0;
    IF v_memos <> 5 THEN
        RAISE EXCEPTION 'FIXTURE 05 失败:5 条银行行应有 5 个互不相同的备注(逐行认人),实得 %', v_memos;
    END IF;

    SELECT count(*) INTO v_debit_lines FROM journal_lines l
    JOIN accounts a ON a.id = l.account_id
    WHERE l.entry_id = v_je AND a.code = '2300' AND l.debit > 0;
    IF v_debit_lines <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 05 失败:应恰有 1 条 2300 借方汇总行,实得 %', v_debit_lines;
    END IF;
END $$;
ROLLBACK;
