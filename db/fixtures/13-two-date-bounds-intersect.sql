-- 13 两个日期界限【取交集】,不是两次削减
--
-- 为什么值得常设:入职日与"完整记录起始日"各自都会把年度额度往后推。正确做法是
-- 取【较晚的那一个】(交集 —— 两者中更紧的那个),而不是把两次削减叠加。
--
-- 【今天的数据证明不了这件事】线上唯一一名员工的入职日恰好就是 system_start_date
-- (都是 2026-08-01),两种算法给出同一个数。所以本 fixture 【必须】用两个不同的
-- 日期,而且两个方向都试 —— 与那次预付上限 fixture 栽的是同一个跟头:
-- 用巧合相等的数据去验一条关于"两者不等时怎么办"的规则,什么也没验到。
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid(); v_role uuid; v_emp uuid;
    v_bal jsonb; v_months int; v_limit numeric; v_det jsonb;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-13', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);

    -- 【前提显式化】额度取 1200,好让月份换算出整数;入职折算开关必须开,
    -- 否则入职日根本不参与,这条 fixture 就名不副实(README 第 5 条)
    UPDATE finance_settings SET locked_before = NULL;
    UPDATE hr_settings SET medical_annual_limit_sgd = 1200, medical_pro_rate_for_joiners = true;

    -- ── A. 入职 3 月,完整记录起于 10 月 ──────────────────────────────────
    -- 交集(正确):从 10 月起 → 3 个月 → 1200 × 3/12 = 300
    -- 叠加(错误):12 − (3−1) − (10−1) = 1 个月 → 100
    UPDATE finance_settings SET system_start_date = '2026-10-01';
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date,
                           employment_status)
    VALUES ('FIXT-E13A', 'Fixture 13A', 'full_time', 'office', '2026-03-01', 'active')
    RETURNING id INTO v_emp;

    v_bal := medical_claim_balance(v_emp, 2026);
    v_months := (v_bal->>'months_of_service')::int;
    v_limit  := (v_bal->>'pro_rated_limit_sgd')::numeric;
    IF v_months <> 3 OR v_limit <> 300 THEN
        RAISE EXCEPTION 'FIXTURE 13A 失败:入职 3 月 + 起始 10 月,应取【较晚者】10 月 → 3 个月 / 300。实得 % 个月 / %。若为 1 个月 / 100,说明两次削减被叠加了',
            v_months, v_limit;
    END IF;

    -- ── B. 反方向:入职 10 月,完整记录起于 3 月 ───────────────────────────
    -- 交集仍应是 10 月(较晚者)→ 3 个月 / 300。方向反过来也必须一样。
    UPDATE finance_settings SET system_start_date = '2026-03-01';
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date,
                           employment_status)
    VALUES ('FIXT-E13B', 'Fixture 13B', 'full_time', 'office', '2026-10-01', 'active')
    RETURNING id INTO v_emp;

    v_bal := medical_claim_balance(v_emp, 2026);
    v_months := (v_bal->>'months_of_service')::int;
    v_limit  := (v_bal->>'pro_rated_limit_sgd')::numeric;
    IF v_months <> 3 OR v_limit <> 300 THEN
        RAISE EXCEPTION 'FIXTURE 13B 失败:入职 10 月 + 起始 3 月,仍应取较晚者 10 月 → 3 个月 / 300,实得 % 个月 / %',
            v_months, v_limit;
    END IF;

    -- ── C. 年假累积:同样的两日期形状(入职月 vs 假期年起点)────────────────
    -- 起始日设到年初,让它不成为因素,单独验"入职月 vs 年初取较晚者"。
    UPDATE finance_settings SET system_start_date = '2026-01-01';
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date,
                           employment_status)
    VALUES ('FIXT-E13C', 'Fixture 13C', 'full_time', 'office', '2026-03-01', 'active')
    RETURNING id INTO v_emp;
    INSERT INTO employment_history (employee_id, effective_date, change_type, work_category)
    VALUES (v_emp, '2026-03-01', 'hired', 'office');

    v_det := accrued_annual_leave_detail(v_emp, '2026-12-31');
    IF (v_det->>'months_accrued')::int <> 10 THEN
        RAISE EXCEPTION 'FIXTURE 13C 失败:2026 年 3 月入职,到年末应累积 10 个月(3–12 月),实得 %',
            (v_det->>'months_accrued')::int;
    END IF;

    -- 入职早于本假期年 → 从 1 月起算满 12 个月(取较晚者 = 年初)
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date,
                           employment_status)
    VALUES ('FIXT-E13D', 'Fixture 13D', 'full_time', 'office', '2020-03-01', 'active')
    RETURNING id INTO v_emp;
    INSERT INTO employment_history (employee_id, effective_date, change_type, work_category)
    VALUES (v_emp, '2020-03-01', 'hired', 'office');
    v_det := accrued_annual_leave_detail(v_emp, '2026-12-31');
    IF (v_det->>'months_accrued')::int <> 12 THEN
        RAISE EXCEPTION 'FIXTURE 13D 失败:2020 年入职者在 2026 年应累积 12 个月(界限取假期年年初),实得 %',
            (v_det->>'months_accrued')::int;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【已知缺口,刻意不在此断言】年假累积【尚未把 system_start_date 纳入界限】——
    -- 它只取 GREATEST(入职月, 假期年年初)。于是本库若从 10 月起才有完整记录,
    -- 一位 3 月入职者在 2026 年仍会累积 10 个月,包含本库并未覆盖的 3–9 月。
    -- 这一条在 HR-5 的清单里(docs/fresh-install-checklist.md),尚未实现。
    -- 【不把现状写成期望值】—— 那会在有人修好它的当天把这个 fixture 变红,
    -- 而红的原因是"修对了"。将来补上界限时,请把它写成三者取最晚:
    --     GREATEST(入职月, 假期年年初, 完整记录起始月)
    -- 而【不是】把削减叠加 —— 那正是 A/B 两段所防的错。
    -- ════════════════════════════════════════════════════════════════════════
END $$;
ROLLBACK;
