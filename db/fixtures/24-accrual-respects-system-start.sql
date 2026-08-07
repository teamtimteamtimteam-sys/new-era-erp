-- 24 按月累积的年假认【完整记录起始日】,三个日期一次取最大 —— 不叠加
--
-- 为什么值得常设(HR-7):累积的起点是三件事的交集 —— 入职、假期年、本库从哪天起
-- 持有完整记录。少了第三件,一个 10 月才上线的库对 3 月入职的人照样从 3 月起算,
-- 把它一无所知的七个月一起给了出去;compute_leave_encashment 再把它换成钱。
-- 而修它的方式【只能是一次 GREATEST】:HR-6 的医疗额度就是栽在逐条扣减上,
-- 按入职月折一次、再按起始月折一次,两步各自"正确",合起来 3 个月折成 1 个月。
-- 四臂:
--   A 3 月入职 / 10 月上线 → 从 10 月起算(3 个月:10、11、12),不是 3 月,
--     【也不是叠加后的更小值】。
--   B 10 月入职 / 3 月上线 → 同样从 10 月起算。【同一个答案,输入对调】——
--     这一臂才证明它是交集而不是累加:叠加实现在这里会给出比 3 更小的数,
--     而正确实现两次都给 3。
--   C 起始日【未设置】→ 不拒绝,退回两日期口径,并在返回值里如实说
--     system_start_applied=false;hr_alerts 同时冒出 system_start_not_set。
--     余额坐在 /me 上,不能因为财务少填一个设置就对全体员工消失。
--   D 兑现:跨着起始日的人,拿到的是【交集后】的余额 —— 它读 leave_balance,
--     自动继承,不该有自己的一份日期逻辑。
--
-- 【数字怎么来的】office 类别年额 24 天(引导默认值,本 fixture 开头自证)。
--   3 个月(10/11/12):24 × 3 / 12 = 6.0 天
--   若少了起始日这一刀(从 3 月起,10 个月):24 × 10 / 12 = 20.0 天
--   若按"先扣入职、再扣起始"叠加:月数会掉到 3 以下,得数 < 6.0
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid(); v_role uuid;
    v_a uuid; v_b uuid; v_c uuid;
    v_d jsonb; v_bal numeric; v_enc jsonb; v_n integer; v_dpy numeric;
    v_asof date := DATE '2026-12-31';
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-24', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);
    UPDATE finance_settings SET locked_before = NULL, system_start_date = '2026-10-01';

    -- 【自证前提】office 的年额必须真的是 24,否则下面每个数字都失去意义。
    -- (费率行由 guard_effective_accrual_rate 保护、不可改,所以读而不设 ——
    --  db/fixtures/README.md 第 5 条的例外分支。)
    SELECT (leave_accrual_rate(NULL, 'office', DATE '2026-10-01')->>'days_per_year')::numeric
    INTO v_dpy;
    IF v_dpy IS DISTINCT FROM 24 THEN
        RAISE EXCEPTION 'FIXTURE 24 前提失败:office 年额应为 24,实得 % —— 下面的 6.0 / 20.0 全部据此推出', v_dpy;
    END IF;

    -- ════════ A. 3 月入职 / 10 月上线 → 从 10 月起 ═══════════════════════════
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, employment_status)
    VALUES ('FIXT-E24A', 'Fixture 24 A', 'full_time', 'office', '2026-03-01', 'active')
    RETURNING id INTO v_a;
    INSERT INTO employment_history (employee_id, effective_date, change_type, work_category)
    VALUES (v_a, '2026-03-01', 'hired', 'office');

    v_d := accrued_annual_leave_detail(v_a, v_asof);
    IF v_d->>'first_month' IS DISTINCT FROM '2026-10' THEN
        RAISE EXCEPTION 'FIXTURE 24A 失败:起点应为 2026-10(三日期取最大),实得 % —— 少了完整记录起始日这一刀',
            v_d->>'first_month';
    END IF;
    IF (v_d->>'months_accrued')::integer <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 24A 失败:应累积 3 个月(10/11/12),实得 % —— 小于 3 说明被叠加扣了两次',
            v_d->>'months_accrued';
    END IF;
    IF (v_d->>'accrued_days')::numeric <> 6.0 THEN
        RAISE EXCEPTION 'FIXTURE 24A 失败:24 × 3 / 12 = 6.0,实得 %(20.0 = 起始日没生效;< 6.0 = 叠加)',
            v_d->>'accrued_days';
    END IF;
    IF (v_d->>'system_start_applied')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 24A 失败:起始日已设置,system_start_applied 应为 true';
    END IF;

    -- ════════ B. 10 月入职 / 3 月上线 → 同一个答案,输入对调 ══════════════════
    -- 【这一臂才是"交集而非累加"的证明】叠加实现在 A 与 B 会给出不同的、都更小的
    -- 数;正确实现两次都是 3 个月 / 6.0 天。
    UPDATE finance_settings SET system_start_date = '2026-03-01';
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, employment_status)
    VALUES ('FIXT-E24B', 'Fixture 24 B', 'full_time', 'office', '2026-10-01', 'active')
    RETURNING id INTO v_b;
    INSERT INTO employment_history (employee_id, effective_date, change_type, work_category)
    VALUES (v_b, '2026-10-01', 'hired', 'office');

    v_d := accrued_annual_leave_detail(v_b, v_asof);
    IF v_d->>'first_month' IS DISTINCT FROM '2026-10' THEN
        RAISE EXCEPTION 'FIXTURE 24B 失败:输入对调后起点仍应为 2026-10,实得 %', v_d->>'first_month';
    END IF;
    IF (v_d->>'months_accrued')::integer <> 3 OR (v_d->>'accrued_days')::numeric <> 6.0 THEN
        RAISE EXCEPTION 'FIXTURE 24B 失败:对调输入应得到与 A 完全相同的 3 个月 / 6.0 天,实得 % 个月 / % 天 —— 不同就说明它在累加而不是取交集',
            v_d->>'months_accrued', v_d->>'accrued_days';
    END IF;

    -- ════════ C. 起始日未设置 → 不拒绝,退回两日期,并被告警点名 ══════════════
    UPDATE finance_settings SET system_start_date = NULL;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, employment_status)
    VALUES ('FIXT-E24C', 'Fixture 24 C', 'full_time', 'office', '2026-03-01', 'active')
    RETURNING id INTO v_c;
    INSERT INTO employment_history (employee_id, effective_date, change_type, work_category)
    VALUES (v_c, '2026-03-01', 'hired', 'office');

    -- 【不许抛】余额坐在 /me 上:因为财务少填一个设置就让全体员工看不到自己的假期,
    -- 是把后台配置问题变成所有人的故障。
    v_d := accrued_annual_leave_detail(v_c, v_asof);
    IF (v_d->>'system_start_applied')::boolean IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 24C 失败:起始日未设置时应如实报 system_start_applied=false,实得 %',
            v_d->>'system_start_applied';
    END IF;
    IF v_d->>'first_month' IS DISTINCT FROM '2026-03' OR (v_d->>'months_accrued')::integer <> 10 THEN
        RAISE EXCEPTION 'FIXTURE 24C 失败:未设置时应退回两日期口径(3 月起、10 个月),实得 % / %',
            v_d->>'first_month', v_d->>'months_accrued';
    END IF;
    -- 缺的那个设置必须有人被喊 —— 否则"不拒绝"就变成了"不说话"
    SELECT count(*) INTO v_n FROM hr_alerts WHERE alert_type = 'system_start_not_set';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 24C 失败:起始日未设置应冒出 1 条 system_start_not_set 告警,实得 % 条 —— 不拒绝的前提是有人被催',
            v_n;
    END IF;
    -- 设回去之后告警必须消失(否则它只是常亮,不是告警)
    UPDATE finance_settings SET system_start_date = '2026-10-01';
    SELECT count(*) INTO v_n FROM hr_alerts WHERE alert_type = 'system_start_not_set';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 24C 失败:设置填回之后告警应消失,实得 % 条', v_n;
    END IF;

    -- ════════ D. 兑现拿到的是交集后的余额(继承,不另算)═══════════════════════
    -- A 的人跨着 2026-10-01 起始日;兑现读 leave_balance → … → 本函数。
    UPDATE employees SET monthly_salary = 2600 WHERE id = v_a;
    v_bal := (leave_balance(v_a, 'annual', v_asof)->>'balance_days')::numeric;
    IF v_bal <> 6.0 THEN
        RAISE EXCEPTION 'FIXTURE 24D 失败:余额应为交集后的 6.0 天,实得 % —— 兑现要继承这一刀,而不是自带一套日期', v_bal;
    END IF;
    v_enc := compute_leave_encashment(v_a, v_asof);
    IF (v_enc->>'days')::numeric <> 6.0 THEN
        RAISE EXCEPTION 'FIXTURE 24D 失败:兑现天数应为 6.0(= 余额),实得 % —— 它没有继承起始日这一刀',
            v_enc->>'days';
    END IF;
END $$;
ROLLBACK;
