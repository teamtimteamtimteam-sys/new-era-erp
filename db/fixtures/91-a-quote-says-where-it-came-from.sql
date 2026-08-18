-- 91 一条行情说得出【它是从哪来的】—— 而"不知道"只属于历史
--
-- 【它守的是什么】LME-1a 之前,metal_prices.source 是
-- `text NOT NULL DEFAULT 'manual'`,没有 CHECK,而唯一的写入函数把它写死成
-- 'manual'。于是这一列【看起来】在回答"这个数从哪来",实际只回答了
-- "有人打字进来的" —— 那对任何一条记录都成立,等于没有回答。
-- 这个数在三个地方动钱(采购计价、批次估值、销售定价),所以出处不是装饰。
--
-- 【四个取值,而 unknown 是一个【只能向后看】的状态】
--   published_index / broker_quote / internal_estimate  —— 新录入三选一;
--   unknown —— 只属于 LME-1a 之前那些无从考证的历史行。
-- 允许新录入选 unknown,等于把这一列变回一句空话,只是换了个词 —— D 臂钉这一条。
--
-- 【为什么"断言值"而不是"断言存在"】brief 说得很准:历史行必须读成 unknown,
-- 【不是】'manual'。一个只检查"source 非空"的断言,对着原样不动的 'manual'
-- 一样通过 —— 那种断言证明不了这一刀做过任何事。
--
-- 【故障注入:表上那道与函数里那道是两道闸,各测各的】
-- 函数拒的是人(具名、看得懂),表拒的是所有绕过函数的门(实测:以
-- authenticated + module.pricing.edit 直插本表是走得通的)。
-- 少了任何一道,另一道都还在 —— 所以注入必须分别打掉它们才看得出谁在守。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid;
    v_msg text; v_denied boolean; n int; v_src text;
    v_res jsonb;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-91', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- 【前提显式设定】异常阈值决定 anomaly_check 会不会被写 —— H 臂要用。
    UPDATE pricing_settings SET metal_price_change_warn_pct = 50;

    -- ══════════════════════════════════════════════════════════════════════════
    -- A. 不给出处 → 【按名】拒绝
    -- ══════════════════════════════════════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM upsert_metal_prices(
            p_price_date := CURRENT_DATE,
            p_prices := jsonb_build_array(jsonb_build_object('metal','ni','price_usd_per_tonne','15000')));
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('QUOTE_SOURCE_REQUIRED' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 91A 不给 source 必须【按名】拒(QUOTE_SOURCE_REQUIRED),实得:%',
            COALESCE(v_msg, '(没有拒绝)');
    END IF;
    -- 【不许漏成约束原文】漏到表那一层,屏幕上会出现 metal_prices_source_check
    IF position('metal_prices_source_check' in v_msg) > 0
       OR position('null value in column' in v_msg) > 0 THEN
        RAISE EXCEPTION 'FIXTURE 91A 拒绝漏到了表那一层(约束原文进了错误信息):%', v_msg;
    END IF;
    RAISE NOTICE '91A 不给出处:按名拒,且没漏成约束原文 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- B. 三种【新录入允许】的出处各自往返一次
    -- ══════════════════════════════════════════════════════════════════════════
    PERFORM upsert_metal_prices(
        p_price_date := CURRENT_DATE, p_price_index := 'LME',
        p_prices := jsonb_build_array(jsonb_build_object('metal','ni','price_usd_per_tonne','15000')),
        p_source := 'published_index',
        p_source_reference := 'LME 官网次日行情截图 2026-08-18.png',
        p_quote_delayed := true);
    SELECT source INTO v_src FROM metal_prices
     WHERE metal='ni' AND price_date=CURRENT_DATE AND price_index='LME';
    IF v_src IS DISTINCT FROM 'published_index' THEN
        RAISE EXCEPTION 'FIXTURE 91B published_index 应当原样落库,实得 %', COALESCE(v_src,'(NULL)');
    END IF;
    -- 凭据与延迟标记也要原样落库(它们是证据,不是装饰)
    SELECT source_reference INTO v_msg FROM metal_prices
     WHERE metal='ni' AND price_date=CURRENT_DATE AND price_index='LME';
    IF v_msg IS DISTINCT FROM 'LME 官网次日行情截图 2026-08-18.png' THEN
        RAISE EXCEPTION 'FIXTURE 91B 凭据应当原样落库,实得 %', COALESCE(v_msg,'(NULL)');
    END IF;
    SELECT count(*) INTO n FROM metal_prices
     WHERE metal='ni' AND price_date=CURRENT_DATE AND price_index='LME' AND quote_delayed;
    IF n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 91B 延迟标记应当为 true,实得 % 行', n;
    END IF;

    PERFORM upsert_metal_prices(
        p_price_date := CURRENT_DATE - 1,
        p_prices := jsonb_build_array(jsonb_build_object('metal','co','price_usd_per_tonne','30000')),
        p_source := 'broker_quote', p_source_reference := '经纪商邮件 主题:Daily Co 8/17');
    SELECT source INTO v_src FROM metal_prices
     WHERE metal='co' AND price_date=CURRENT_DATE-1 AND price_index IS NULL;
    IF v_src IS DISTINCT FROM 'broker_quote' THEN
        RAISE EXCEPTION 'FIXTURE 91B broker_quote 应当原样落库,实得 %', COALESCE(v_src,'(NULL)');
    END IF;

    PERFORM upsert_metal_prices(
        p_price_date := CURRENT_DATE - 2,
        p_prices := jsonb_build_array(jsonb_build_object('metal','li','price_usd_per_tonne','9000')),
        p_source := 'internal_estimate');
    SELECT source, source_reference INTO v_src, v_msg FROM metal_prices
     WHERE metal='li' AND price_date=CURRENT_DATE-2 AND price_index IS NULL;
    IF v_src IS DISTINCT FROM 'internal_estimate' THEN
        RAISE EXCEPTION 'FIXTURE 91B internal_estimate 应当原样落库,实得 %', COALESCE(v_src,'(NULL)');
    END IF;
    -- 【没给凭据就是 NULL】不是空串 —— 空串会让"记了一个空凭据"看起来像"记过"
    IF v_msg IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 91B 没给凭据时应当是 NULL(不是空串),实得 %', quote_literal(v_msg);
    END IF;
    RAISE NOTICE '91B 三种出处各自往返;凭据与延迟标记原样落库,未给凭据为 NULL ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- C. published_index 必须说得出【是哪一个】
    -- ══════════════════════════════════════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM upsert_metal_prices(
            p_price_date := CURRENT_DATE - 3,
            p_prices := jsonb_build_array(jsonb_build_object('metal','cu','price_usd_per_tonne','8000')),
            p_source := 'published_index');   -- 没有 p_price_index
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('QUOTE_SOURCE_INDEX_REQUIRED' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 91C "来自某个发布的指数、但不知道是哪一个"是一句自相矛盾的话 —— 必须按名拒(QUOTE_SOURCE_INDEX_REQUIRED),实得:%',
            COALESCE(v_msg,'(没有拒绝)');
    END IF;
    RAISE NOTICE '91C published_index 缺 price_index:按名拒 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- D. unknown 【不许用在新录入上】—— 否则这一列只是换了个词的空话
    -- ══════════════════════════════════════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM upsert_metal_prices(
            p_price_date := CURRENT_DATE - 4,
            p_prices := jsonb_build_array(jsonb_build_object('metal','al','price_usd_per_tonne','2500')),
            p_source := 'unknown');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('QUOTE_SOURCE_UNKNOWN_NOT_ALLOWED_FOR_NEW' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 91D unknown 只属于历史行,新录入必须被按名拒,实得:%',
            COALESCE(v_msg,'(没有拒绝)');
    END IF;
    RAISE NOTICE '91D unknown 用于新录入:按名拒 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- E. 认不出的取值也拒 —— 集合是【封闭】的
    -- ══════════════════════════════════════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM upsert_metal_prices(
            p_price_date := CURRENT_DATE - 5,
            p_prices := jsonb_build_array(jsonb_build_object('metal','fe','price_usd_per_tonne','500')),
            p_source := 'manual');   -- 旧值,现在不该被接受
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('QUOTE_SOURCE_INVALID' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 91E 旧值 ''manual'' 现在必须被按名拒(QUOTE_SOURCE_INVALID),实得:%',
            COALESCE(v_msg,'(没有拒绝)');
    END IF;
    RAISE NOTICE '91E 认不出的取值(含旧的 manual):按名拒 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- F. 表上那道闸:【绕过函数】的直插也进不来没有出处的行
    --    实测过 authenticated + module.pricing.edit 直插是走得通的,
    --    所以这一臂不是假想 —— 它是那条路今天的样子。
    -- ══════════════════════════════════════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date)
        VALUES ('mn', 1800, CURRENT_DATE - 6);
        RAISE NOTICE 'x';
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 91F 绕过函数、不给 source 的直插必须失败 —— 默认值还在(那正是本刀拿掉的东西)';
    END IF;
    -- 【拒了还不够,要拒对】只断言"被拒了",任何别的原因(唯一键撞车、
    -- 触发器抛错)都能让这一臂变绿 —— 而那时它证明的不是本刀做过的事。
    -- 实测教训:注入"把默认值放回去"之后这一臂依然通过,正是因为它当时
    -- 只问了"有没有被拒",没问"是不是因为 source"。
    IF position('source' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 91F 直插确实被拒了,但【不是因为 source】—— 实得:%', v_msg;
    END IF;
    RAISE NOTICE '91F 绕过函数的直插:因 source 而进不来(表上没有默认值兜着)✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- G. 历史行读作 unknown —— 【断言值,不是断言存在】
    --    只检查"非空"的断言,对着原样不动的 'manual' 一样通过。
    -- ══════════════════════════════════════════════════════════════════════════
    SELECT count(*) INTO n FROM metal_prices WHERE source = 'manual';
    IF n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 91G 不该再有任何一行 source = ''manual'',实得 % 行', n;
    END IF;
    RAISE NOTICE '91G 没有任何一行仍是 manual(历史行读作 unknown)✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- H. 出处这一列【没有把异常检查挤掉】—— 大幅变动仍然留下 anomaly_check
    -- ══════════════════════════════════════════════════════════════════════════
    PERFORM upsert_metal_prices(
        p_price_date := CURRENT_DATE - 20, p_price_index := 'LME',
        p_prices := jsonb_build_array(jsonb_build_object('metal','cu','price_usd_per_tonne','8000')),
        p_source := 'published_index');
    PERFORM upsert_metal_prices(
        p_price_date := CURRENT_DATE - 19, p_price_index := 'LME',
        p_prices := jsonb_build_array(jsonb_build_object('metal','cu','price_usd_per_tonne','20000')),
        p_source := 'published_index');
    SELECT anomaly_check INTO v_res FROM metal_prices
     WHERE metal='cu' AND price_date=CURRENT_DATE-19 AND price_index='LME';
    IF v_res IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 91H 8000→20000(+150%%,阈值 50%%)必须留下 anomaly_check —— 本刀加了三列,不许把既有的异常记录挤掉';
    END IF;
    RAISE NOTICE '91H 大幅变动仍留下 anomaly_check:% ✓', v_res::text;

    RAISE NOTICE 'FIXTURE 91 全部通过';
END $$;
ROLLBACK;
