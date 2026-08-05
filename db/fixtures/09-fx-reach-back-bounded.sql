-- 09 汇率就近取【上一个发布日】,但有界,且报出取自哪一天
--
-- 为什么值得常设:周末交易用周五的价是对的;同一套机制悄悄用上三周前的价则是错的。
-- 两者的分界只有一条代码 —— 中间跨过的每一天都必须是非发布日。它一旦松掉,
-- 每一笔外币过账都会按一个不该用的汇率入账,而账面照样平。
--
-- 【自带假日行】不依赖 public_holidays 的引导数据(那是会随年份过期的,README 第 4 条)。
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid(); v_role uuid;
    r numeric; a date; v_msg text; v_ok boolean := false;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-09', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);

    -- 造一个【自带的】长周末:2026-06-05 周五设为假日,牌价只录到 06-04 周四。
    -- 于是 06-05(五,假)06-06(六)06-07(日)都是非发布日,06-08 周一是工作日。
    DELETE FROM fx_rates WHERE currency = 'USD'
      AND rate_date BETWEEN '2026-06-01' AND '2026-06-12';
    INSERT INTO public_holidays (holiday_date, name_en, name_zh, country, is_active)
    VALUES ('2026-06-05', 'Fixture Holiday', '测试假日', 'SG', true);
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES ('USD', '2026-06-04', 'tt_sell', 1.31);

    -- ① 周六:应取到周四的价,并【报出】取自 06-04
    SELECT x.rate, x.as_of INTO r, a FROM fx_rate_asof('USD', '2026-06-06', 'tt_sell') x;
    IF r IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 09① 失败:周六应取到上一个发布日(06-04)的牌价,却被拒';
    END IF;
    IF a <> DATE '2026-06-04' THEN
        RAISE EXCEPTION 'FIXTURE 09① 失败:必须报出取自哪一天,期望 2026-06-04,实得 %', a;
    END IF;

    -- ② 周一 06-08:中间的 05(假)06 07 全是非发布日 → 仍应取到
    SELECT x.rate, x.as_of INTO r, a FROM fx_rate_asof('USD', '2026-06-08', 'tt_sell') x;
    IF r IS NULL OR a <> DATE '2026-06-04' THEN
        RAISE EXCEPTION 'FIXTURE 09② 失败:跨过一个假日与周末应仍能取到 06-04 的价,实得 rate=% as_of=%', r, a;
    END IF;

    -- ③ 周二 06-09:中间夹了【工作日】06-08(那天该录没录)→ 必须拒绝,
    --    而不是拿更早的价蒙混过去。这一条是整条规则的分界线。
    SELECT x.rate INTO r FROM fx_rate_asof('USD', '2026-06-09', 'tt_sell') x;
    IF r IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 09③ 失败:06-08 是工作日且无牌价,06-09 应【拒绝】而非回溯到 06-04,实得 %', r;
    END IF;

    -- ④ fx_rate_for 的报错口径不变(点名币种/日期/哪一侧)
    BEGIN
        PERFORM fx_rate_for('USD', '2026-06-09', 'tt_sell');
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'FX_RATE_MISSING|USD|2026-06-09|tt_sell%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 09④ 失败:应抛 FX_RATE_MISSING|USD|2026-06-09|tt_sell,实得:%',
            COALESCE(v_msg, '(没有报错)');
    END IF;
END $$;
ROLLBACK;
