-- 09 汇率就近取【上一个发布日】,但只在交易日自己不发布牌价时,且报出取自哪一天
--
-- 为什么值得常设:周末交易用周五的价是对的;同一套机制悄悄用上前一天的价则是错的。
-- 它一旦松掉,每一笔外币过账都会按一个不该用的汇率入账,而账面照样平。
--
-- 【FIN-19 修正的分界线】FIN-13 写的是"牌价日与交易日【之间】的每一天都必须是
-- 非发布日",实现为 generate_series(v_when + 1, p_date - 1)。相邻两天时这个区间
-- 【是空的】—— 条件空真,于是任何工作日都接受昨天的牌价。走查里 8/5 录了价、
-- 8/6 没录,8/6 的收货静默用了 8/5 的 1.24,就是这么来的。
-- 正确的条件把右端包含进来:牌价日(不含)→【交易日本身(含)】全是非发布日。
--
-- 本 fixture 的 C、D 两臂就是那条分界线,【两个方向都断言】:
--   * 交易日是非发布日 → 必须够得着(A/B/F);
--   * 交易日是工作日   → 必须拒绝,哪怕只差一天(C/D)。
-- 只断言一边的话,一个"永远拒绝"的实现和一个"永远放行"的实现各能骗过一半。
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
    UPDATE finance_settings SET locked_before = NULL;

    -- ════════════════════════════════════════════════════════════════════════
    -- 窗口一:长周末。06-04 周四有价;06-05 周五设为假日;06-06 六;06-07 日;
    --         06-08 周一、06-09 周二都是工作日。
    -- 【前提显式化】窗口内的牌价与假日都自己说了算(README 第 5 条)。
    -- ════════════════════════════════════════════════════════════════════════
    UPDATE fx_rates SET deleted_at = now() WHERE currency = 'USD'
      AND rate_date BETWEEN '2026-06-01' AND '2026-06-12';
    DELETE FROM public_holidays WHERE holiday_date BETWEEN '2026-06-01' AND '2026-06-12';
    -- C-2:holiday_key 是 NOT NULL(跨年份稳定的身份)—— 造数据的地方也要给。
    INSERT INTO public_holidays (holiday_date, name_en, name_zh, holiday_key, country, is_active)
    VALUES ('2026-06-05', 'Fixture Holiday', '测试假日', 'fixture-holiday', 'SG', true);
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES ('USD', '2026-06-04', 'tt_sell', 1.31);

    -- 前提自证:这几天的工作日属性必须真的是我们以为的样子
    IF is_business_day(DATE '2026-06-05') OR is_business_day(DATE '2026-06-06')
       OR is_business_day(DATE '2026-06-07') THEN
        RAISE EXCEPTION 'FIXTURE 09 前提失败:06-05/06/07 应为非发布日';
    END IF;
    IF NOT is_business_day(DATE '2026-06-08') OR NOT is_business_day(DATE '2026-06-09') THEN
        RAISE EXCEPTION 'FIXTURE 09 前提失败:06-08/06-09 应为工作日';
    END IF;

    -- ── A. 周六:交易日自己不发布 → 取到周四的价,并【报出】取自 06-04 ──────
    SELECT x.rate, x.as_of INTO r, a FROM fx_rate_asof('USD', '2026-06-06', 'tt_sell') x;
    IF r IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 09A 失败:周六应取到上一个发布日(06-04)的牌价,却被拒';
    END IF;
    IF a <> DATE '2026-06-04' THEN
        RAISE EXCEPTION 'FIXTURE 09A 失败:必须报出取自哪一天,期望 2026-06-04,实得 %', a;
    END IF;

    -- ── B. 周日:跨过【假日 + 周六】仍应取到(交易日自己也不发布)──────────
    SELECT x.rate, x.as_of INTO r, a FROM fx_rate_asof('USD', '2026-06-07', 'tt_sell') x;
    IF r IS NULL OR a <> DATE '2026-06-04' THEN
        RAISE EXCEPTION 'FIXTURE 09B 失败:周日跨假日+周六应仍能取到 06-04,实得 rate=% as_of=%', r, a;
    END IF;

    -- ── C. 周一 06-08:【交易日本身是工作日】→ 必须拒绝 ─────────────────────
    --    这一臂在 FIN-19 之前断言的是【相反】的结论(那时它期望取到 06-04),
    --    并且是绿的。不是过期的期望值,是【有意的行为变更】:长周末结束了,
    --    周一是普通工作日,那天该录牌价而没录,就该拒 ——
    --    与"从没有过回溯规则"时的行为一致。
    SELECT x.rate INTO r FROM fx_rate_asof('USD', '2026-06-08', 'tt_sell') x;
    IF r IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 09C 失败:06-08 是工作日且当天无牌价,必须拒绝,实得 %', r;
    END IF;

    -- ── D. 相邻两天,两天都是普通工作日 → 必须拒绝 ─────────────────────────
    --    【这是 FIN-19 的核心用例】:中间一天都没有,老实现的区间为空 → 放行。
    --    走查里 8/5→8/6 就是这个形状。用一段没有任何假日的纯工作日窗口来测。
    UPDATE fx_rates SET deleted_at = now() WHERE currency = 'USD'
      AND rate_date BETWEEN '2026-06-15' AND '2026-06-19';
    DELETE FROM public_holidays WHERE holiday_date BETWEEN '2026-06-15' AND '2026-06-19';
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES ('USD', '2026-06-17', 'tt_sell', 1.32);
    IF NOT is_business_day(DATE '2026-06-17') OR NOT is_business_day(DATE '2026-06-18') THEN
        RAISE EXCEPTION 'FIXTURE 09D 前提失败:06-17(三)/06-18(四)应均为工作日';
    END IF;
    SELECT x.rate, x.as_of INTO r, a FROM fx_rate_asof('USD', '2026-06-18', 'tt_sell') x;
    IF r IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 09D 失败:周三有价、周四没价,周四是工作日 —— 必须拒绝,却取到了 %(as_of %)', r, a;
    END IF;
    -- 精确匹配不能被误伤:06-17 当天照常返回
    SELECT x.rate, x.as_of INTO r, a FROM fx_rate_asof('USD', '2026-06-17', 'tt_sell') x;
    IF r IS NULL OR a <> DATE '2026-06-17' THEN
        RAISE EXCEPTION 'FIXTURE 09D 失败:精确匹配被误伤,rate=% as_of=%', r, a;
    END IF;

    -- ── E. 中间夹着工作日 → 拒绝(FIN-13 立的那条,FIN-19 不改它)──────────
    SELECT x.rate INTO r FROM fx_rate_asof('USD', '2026-06-09', 'tt_sell') x;
    IF r IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 09E 失败:06-08 是工作日且无牌价,06-09 应拒绝而非回溯到 06-04,实得 %', r;
    END IF;

    -- ── F. 四天的顺延假:周五有价,周六/周日/周一/周二连成非发布日 ──────────
    --    形状取自新加坡"顺延假"(4 天上限就是为它定的):交易日周二【自己是假日】,
    --    所以够得着周五。再往后的周三是工作日,必须拒绝 —— 上限与规则各挡一边。
    UPDATE fx_rates SET deleted_at = now() WHERE currency = 'USD'
      AND rate_date BETWEEN '2026-09-01' AND '2026-09-12';
    DELETE FROM public_holidays WHERE holiday_date BETWEEN '2026-09-01' AND '2026-09-12';
    -- C-2:三行共用一个 holiday_key(它们是同一个节日),补假那一行 is_in_lieu ——
    -- 这正是那两列要表达的区别,顺手在 fixture 里也表达出来。
    INSERT INTO public_holidays (holiday_date, name_en, name_zh, holiday_key, is_in_lieu, country, is_active) VALUES
        ('2026-09-06', 'Fixture Festival D1', '测试节日一', 'fixture-festival', false, 'SG', true),      -- 周日
        ('2026-09-07', 'Fixture Festival D2', '测试节日二', 'fixture-festival', false, 'SG', true),      -- 周一
        ('2026-09-08', 'Fixture Festival in lieu', '测试顺延假', 'fixture-festival', true, 'SG', true); -- 周二
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES ('USD', '2026-09-04', 'tt_sell', 1.33);   -- 周五
    IF is_business_day(DATE '2026-09-08') THEN
        RAISE EXCEPTION 'FIXTURE 09F 前提失败:09-08 应为顺延假(非发布日)';
    END IF;
    SELECT x.rate, x.as_of INTO r, a FROM fx_rate_asof('USD', '2026-09-08', 'tt_sell') x;
    IF r IS NULL OR a <> DATE '2026-09-04' THEN
        RAISE EXCEPTION 'FIXTURE 09F 失败:顺延假当天应取到 09-04(4 个自然日),实得 rate=% as_of=%', r, a;
    END IF;
    -- 周三 09-09 是工作日,且已超出 4 天上限 → 两条各自都该拒
    SELECT x.rate INTO r FROM fx_rate_asof('USD', '2026-09-09', 'tt_sell') x;
    IF r IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 09F 失败:09-09 是工作日且超出 4 天上限,必须拒绝,实得 %', r;
    END IF;

    -- ── G. fx_rate_for 的报错口径不变(点名币种/日期/哪一侧)────────────────
    BEGIN
        PERFORM fx_rate_for('USD', '2026-06-09', 'tt_sell');
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'FX_RATE_MISSING|USD|2026-06-09|tt_sell%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 09G 失败:应抛 FX_RATE_MISSING|USD|2026-06-09|tt_sell,实得:%',
            COALESCE(v_msg, '(没有报错)');
    END IF;
END $$;
ROLLBACK;
