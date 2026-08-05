-- 12 医疗额度按"完整记录起始日"设界
--
-- 为什么值得常设:额度是【推导】的,已用额是【记录】的。切换上线时切换前的报销不在
-- 本库,于是 remaining 偏高 —— 而 decide_medical_claim 正是拿它当闸门,
-- 所以这条错不是显示问题,是【真的多批钱】。四个断言里第三个最要紧:
-- 折算必须真的收紧了审批闸门,不能只是把返回值改小。
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid(); v_role uuid; v_emp uuid; v_claim uuid;
    v_bal jsonb; v_msg text; v_ok boolean; v_limit_full numeric; v_limit_part numeric;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-12', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);

    -- 【前提显式化】额度、起始日、锁位都自己设(README 第 5 条)
    UPDATE finance_settings SET locked_before = NULL, system_start_date = '2026-01-01';
    UPDATE hr_settings SET medical_annual_limit_sgd = 1200, medical_pro_rate_for_joiners = false;

    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date,
                           employment_status)
    VALUES ('FIXT-E12', 'Fixture Employee 12', 'full_time', 'office', '2020-03-01', 'active')
    RETURNING id INTO v_emp;

    -- ① 记录完整的年度:整份额度
    v_bal := medical_claim_balance(v_emp, 2026);
    v_limit_full := (v_bal->>'pro_rated_limit_sgd')::numeric;
    IF v_limit_full <> 1200 THEN
        RAISE EXCEPTION 'FIXTURE 12① 失败:2026 全年被完整记录覆盖,额度应为 1200,实得 %', v_limit_full;
    END IF;
    IF (v_bal->>'record_incomplete_for_year')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 12① 失败:1 月 1 日起算的年度不该标记为记录不完整';
    END IF;

    -- ② 起始日挪到 7 月 1 日 → 本库只覆盖 6 个月,额度折半
    UPDATE finance_settings SET system_start_date = '2026-07-01';
    v_bal := medical_claim_balance(v_emp, 2026);
    v_limit_part := (v_bal->>'pro_rated_limit_sgd')::numeric;
    IF v_limit_part >= v_limit_full THEN
        RAISE EXCEPTION 'FIXTURE 12② 失败:本库只覆盖 7–12 月,额度应少于整份 %,实得 %',
            v_limit_full, v_limit_part;
    END IF;
    IF NOT (v_bal->>'record_incomplete_for_year')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 12② 失败:起始日在年中,应标记 record_incomplete_for_year';
    END IF;

    -- ③ 【最要紧的一条】折算必须真的收紧审批闸门,而不只是返回值变小。
    --    报一笔介于"折算后额度"与"整份额度"之间的钱:必须被 CLAIM_EXCEEDS_LIMIT 拒。
    --    少了这一条,②可能只是改了个显示字段而闸门照旧。
    -- code 由取号触发器填,但它只在空值时才动;这里显式给一个,避免烧掉无缝号
    INSERT INTO medical_claims (code, employee_id, claim_date, claim_year, amount_sgd, status)
    VALUES ('ZZ-FIXT-12', v_emp, '2026-08-10', 2026, v_limit_part + 50, 'submitted')
    RETURNING id INTO v_claim;
    v_ok := false;
    BEGIN
        PERFORM decide_medical_claim(v_claim, true);
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'CLAIM_EXCEEDS_LIMIT|%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 12③ 失败:金额 % 超过本库能担保的额度 %,审批应被 CLAIM_EXCEEDS_LIMIT 拒。实得:% —— 若为放行,说明折算只改了返回值、没有收紧闸门',
            v_limit_part + 50, v_limit_part, COALESCE(v_msg, '(批准了)');
    END IF;

    -- ④ 整年都早于起始日 → 拒绝(本库对那一年一无所知)
    v_ok := false;
    BEGIN
        PERFORM medical_claim_balance(v_emp, 2025);
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'CLAIM_YEAR_BEFORE_SYSTEM_START|2025|2026-07-01%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 12④ 失败:2025 整年早于起始日,应抛 CLAIM_YEAR_BEFORE_SYSTEM_START,实得:%',
            COALESCE(v_msg, '(给出了余额 —— 那是编的)');
    END IF;
END $$;
ROLLBACK;
