-- 10 假日表告警覆盖【全新安装】
--
-- 为什么值得常设:这个守卫的盲区曾经恰好是它唯一该守住的时刻。旧版只在 10 月起
-- 检查【次年】,于是一个 2027 年 3 月建起来的库整年不吭声,而请假天数一直算错。
-- 这条 fixture 断言的是"当年缺就立刻报",与月份无关 —— 它正是全新安装的形状。
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid(); v_role uuid;
    v_cur int; v_next int; v_year int := EXTRACT(year FROM CURRENT_DATE)::int;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-10', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);
    UPDATE finance_settings SET locked_before = NULL;

    -- 【前提显式化】把两年的假日都清掉,造出"全新安装"的样子(README 第 5 条)
    DELETE FROM public_holidays WHERE EXTRACT(year FROM holiday_date) IN (v_year, v_year + 1);

    SELECT count(*) INTO v_cur FROM hr_alerts WHERE alert_type = 'holiday_calendar_missing';
    IF v_cur = 0 THEN
        RAISE EXCEPTION 'FIXTURE 10 失败:当年(%)没有任何假日时,应【立刻】报 holiday_calendar_missing —— 这正是全新安装的处境', v_year;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM hr_alerts
                   WHERE alert_type = 'holiday_calendar_missing' AND severity = 'expired') THEN
        RAISE EXCEPTION 'FIXTURE 10 失败:当年缺假日属于【正在出错】,严重度应为 expired';
    END IF;

    -- 补上当年的一条:当年那支应当熄灭,次年那支的行为不受影响
    -- C-2:holiday_key 是 NOT NULL —— 造数据的地方也要给。
    INSERT INTO public_holidays (holiday_date, name_en, name_zh, holiday_key, country, is_active)
    VALUES (make_date(v_year, 1, 1), 'Fixture NY', '测试元旦', 'fixture-new-year', 'SG', true);
    SELECT count(*) INTO v_cur FROM hr_alerts WHERE alert_type = 'holiday_calendar_missing';
    IF v_cur <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 10 失败:当年已有假日,该告警应熄灭,实得 % 条', v_cur;
    END IF;

    -- 次年那支【只在四季度】开口 —— 与月份有关,所以按当前月份分别断言
    SELECT count(*) INTO v_next FROM hr_alerts WHERE alert_type = 'holiday_calendar_next_year';
    IF EXTRACT(month FROM CURRENT_DATE) >= 10 THEN
        IF v_next = 0 THEN
            RAISE EXCEPTION 'FIXTURE 10 失败:已进入四季度且次年无假日,应报 holiday_calendar_next_year';
        END IF;
    ELSE
        IF v_next <> 0 THEN
            RAISE EXCEPTION 'FIXTURE 10 失败:尚未进入四季度,次年告警不该开口,实得 % 条', v_next;
        END IF;
    END IF;
END $$;
ROLLBACK;
