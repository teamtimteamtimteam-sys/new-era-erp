-- 48 行情异常:超出区间【提醒并且照常保存】,区间之内不提醒;
--    改一个【配置里的数字】就改变哪一个是哪一个,不动一行代码
--
-- 【为什么是"提醒"而不是"拒收"】3 倍的真实行情是可能的,拒收它是错的;而系统
-- 【无法分辨】这一次是真行情还是键错了一位 —— 与证书处置按类型分(CMP-1)是
-- 同一条理由。所以本 fixture 的 A 臂断言的是【两件事同时成立】:判词是 outside,
-- 并且那一行【确实存在于表里】。少断言后半句,一个"拒收"的实现也能通过。
--
-- 【为什么阈值必须是配置而不是常量】C 臂是这份 fixture 的重心:同样的一步
-- (100 → 200,+100%),在阈值 50 时是异常、在阈值 150 时不是。它把
-- "这个数字住在哪里"变成一条可以失败的断言 —— 写死在代码里的实现过不了它。
-- (FIN-36 的 schema 默认值、CMP-1 的 warn_lead_days,同一条教训的第三次。)
--
-- 【D 臂:no_reference 不是 false】线上 7 个金属里有 4 个只有一条报价,没有可比
-- 的对象。把"没法查"记成"查过、没问题"正是这套检查存在的理由的反面 ——
-- 所以它是第三种判词,而 D 臂钉住它既不是 outside 也不是 inside。
--
-- 【E 臂:参照按 price_date 取,不按 created_at】录入是阵发的,而且补录发生过
-- (ASY-3 实测:6-25 的行情 7-2 才录进来)。补录进序列【最前面】的一行没有更早的
-- 邻居,判据回落到更晚的那一条并说明用的是哪一侧 —— 否则补录的那一条永远不被检查。
--
-- 【F 臂:应用那一侧真的调得动】metal_price_anomaly 是 SECURITY INVOKER
-- (METAL-1 fu1:gate 的 B2 抓到它原本是 DEFINER 且不查调用者)。invoker 意味着
-- 它按【调用者】解析 RLS,所以"以 postgres 跑得通"证明不了"登录用户跑得通" ——
-- 那正是 OPS-13 那一类缺陷的形状(每个真实读者都拿到 42501,而检查一片绿)。
-- 本臂显式切到 authenticated 再调一次(README 第 6 条)。
--
-- 【日期全部落在 2027,自带数据,不继承任何随时间移动的状态】(README 第 4 条)
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid;
    v_verdict jsonb;
    v_saved numeric;
    v_n int;
BEGIN
    -- README 第 5 条:前提显式设定,哪怕引导值恰好合用
    UPDATE pricing_settings SET metal_price_change_warn_pct = 50 WHERE id;

    -- 【序列的起点也是前提,不能继承】D 臂("这个金属的第一条报价")与 E 臂
    -- ("没有更早的邻居")都是关于【序列里有什么】的断言。重建库里 metal_prices
    -- 是空的,于是这两臂在门上恰好成立 —— 而对着线上做回滚型试跑时,那里每个金属
    -- 都已经有报价,两臂会因为别人的数据而红。所以本 fixture 自己把序列清空
    -- (软删,整段回滚,不影响任何人),让每一臂的参照都由它自己摆出来。
    -- 这正是"默认值恰好合用是偶然"那一条:偶然会过期。
    UPDATE metal_prices SET deleted_at = now() WHERE deleted_at IS NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-48', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_all, unnest(ARRAY['module.pricing.view','module.pricing.edit']);
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);

    -- ══════════ A. 超出区间:提醒【并且照常保存】═════════════════════════════
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source)
    VALUES ('li', 100, '2027-03-01', 'broker_quote');
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source)
    VALUES ('li', 200, '2027-03-02', 'broker_quote');          -- +100%,阈值 50

    SELECT anomaly_check, price_usd_per_tonne INTO v_verdict, v_saved
      FROM metal_prices WHERE metal = 'li' AND price_date = '2027-03-02';

    IF v_verdict->>'verdict' <> 'outside' THEN
        RAISE EXCEPTION 'FIXTURE 48A 失败:100 → 200(+100%%)在阈值 50 下应判 outside,实得 % —— 判据没有生效,那么这次录入没有任何东西说过一句话',
            COALESCE(v_verdict->>'verdict', '(没有判词)');
    END IF;
    -- 【提醒不是拦截】—— 少了这一句,一个"拒收"的实现也能通过 A 臂的前半
    IF v_saved IS DISTINCT FROM 200 THEN
        RAISE EXCEPTION 'FIXTURE 48A 失败:被提醒的那一行应当【照常保存】为 200,实得 % —— 真实的 3 倍行情是可能的,拒收它是错的', v_saved;
    END IF;
    -- 提示要能说出【两个数字】,否则人无从判断这一步跳得对不对
    IF (v_verdict->>'reference_price')::numeric <> 100
       OR (v_verdict->>'reference_date')::date <> '2027-03-01'
       OR (v_verdict->>'change_pct')::numeric <> 100
       OR (v_verdict->>'threshold_pct')::numeric <> 50 THEN
        RAISE EXCEPTION 'FIXTURE 48A 失败:判词里应带着"拿什么比、差多少、阈值多少"(100 / 2027-03-01 / 100%% / 50),实得 %', v_verdict::text;
    END IF;

    -- ══════════ B. 区间之内:不提醒 ═════════════════════════════════════════
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source)
    VALUES ('mn', 100, '2027-03-01', 'broker_quote');
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source)
    VALUES ('mn', 140, '2027-03-02', 'broker_quote');          -- +40%,阈值 50

    SELECT anomaly_check INTO v_verdict
      FROM metal_prices WHERE metal = 'mn' AND price_date = '2027-03-02';
    IF v_verdict->>'verdict' <> 'inside' THEN
        RAISE EXCEPTION 'FIXTURE 48B 失败:100 → 140(+40%%)在阈值 50 下不该提醒,实得 % —— 每次录入都提醒,等于没有提醒',
            v_verdict->>'verdict';
    END IF;

    -- ══════════ C. 改配置里的一个数字,同一步的判词就翻过来 ══════════════════
    -- 【本 fixture 的重心】阈值写死在代码里的实现,过不了这一臂。
    UPDATE pricing_settings SET metal_price_change_warn_pct = 150 WHERE id;

    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source)
    VALUES ('fe', 100, '2027-03-01', 'broker_quote');
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source)
    VALUES ('fe', 200, '2027-03-02', 'broker_quote');          -- 与 li 【完全相同】的一步:+100%

    SELECT anomaly_check INTO v_verdict
      FROM metal_prices WHERE metal = 'fe' AND price_date = '2027-03-02';
    IF v_verdict->>'verdict' <> 'inside' THEN
        RAISE EXCEPTION 'FIXTURE 48C 失败:同样的 100 → 200,在阈值 150 下应当【不】提醒,实得 % —— 阈值若不是从 pricing_settings 现读的,那张配置表就只是装饰(FIN-36 的教训第三次)',
            v_verdict->>'verdict';
    END IF;
    IF (v_verdict->>'threshold_pct')::numeric <> 150 THEN
        RAISE EXCEPTION 'FIXTURE 48C 失败:判词里的阈值应当跟着配置走(150),实得 % —— 提示上印的数字与真正判断用的数字必须是同一个',
            v_verdict->>'threshold_pct';
    END IF;
    -- 反向也要成立:li 那一行是在阈值 50 时录的,它的判词是【当时】记下的,
    -- 不随后来改阈值而变(记录,不事后重算 —— 与 FIN-26 的 price_source 同一条)
    SELECT anomaly_check INTO v_verdict
      FROM metal_prices WHERE metal = 'li' AND price_date = '2027-03-02';
    IF v_verdict->>'verdict' <> 'outside' OR (v_verdict->>'threshold_pct')::numeric <> 50 THEN
        RAISE EXCEPTION 'FIXTURE 48C 失败:改阈值不该改写【已经录入的那一行】的判词(应仍是 outside @ 50),实得 % —— 判词是录入那一刻的记录,事后重算给出的是另一个答案',
            v_verdict::text;
    END IF;

    UPDATE pricing_settings SET metal_price_change_warn_pct = 50 WHERE id;   -- 复原,后面几臂用它

    -- ══════════ D. 第一条报价:no_reference,既不是 outside 也不是 inside ════
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source)
    VALUES ('al', 12345, '2027-03-05', 'broker_quote');
    SELECT anomaly_check INTO v_verdict
      FROM metal_prices WHERE metal = 'al' AND price_date = '2027-03-05';
    IF v_verdict->>'verdict' <> 'no_reference' THEN
        RAISE EXCEPTION 'FIXTURE 48D 失败:该金属的第一条报价没有可比对象,应判 no_reference,实得 % —— 记成 inside 就是把"没法查"说成"查过、没问题",而线上 7 个金属里有 4 个正处在这个状态',
            v_verdict->>'verdict';
    END IF;
    IF v_verdict->>'reference_price' IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 48D 失败:no_reference 不该带着一个参照价,实得 %', v_verdict::text;
    END IF;

    -- ══════════ E. 补录:参照按 price_date 取,回落到更晚的一条并说明 ════════
    -- 'co' 先有一条 2027-04-10,再补录一条【更早】的 2027-04-01
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source)
    VALUES ('co', 100, '2027-04-10', 'broker_quote');
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source)
    VALUES ('co', 300, '2027-04-01', 'broker_quote');          -- 补录:没有更早的邻居

    SELECT anomaly_check INTO v_verdict
      FROM metal_prices WHERE metal = 'co' AND price_date = '2027-04-01';
    IF v_verdict->>'verdict' <> 'outside' THEN
        RAISE EXCEPTION 'FIXTURE 48E 失败:补录进序列最前面的一行也必须被检查(300 vs 100 = +200%%),实得 % —— 只看"更早的一条"会让补录的那一行永远不被检查,而补录是这套数据里真实发生过的事',
            COALESCE(v_verdict->>'verdict', '(没有判词)');
    END IF;
    IF v_verdict->>'reference_side' <> 'later' THEN
        RAISE EXCEPTION 'FIXTURE 48E 失败:用的是更晚那一条当参照时要说出来(reference_side = later),实得 % —— 不讲清楚,人会以为系统读错了日期',
            COALESCE(v_verdict->>'reference_side', '(空)');
    END IF;

    -- ══════════ F. 应用那一侧调得动(invoker:按调用者解析 RLS)══════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT metal_price_anomaly('li', 500, DATE '2027-03-03') INTO v_verdict;
    RESET ROLE;
    IF v_verdict->>'verdict' <> 'outside' THEN
        RAISE EXCEPTION 'FIXTURE 48F 失败:登录用户直接调判据应当拿到 outside(500 vs 200 = +150%%),实得 % —— 以 postgres 跑得通证明不了真实读者跑得通,那正是 OPS-13 那一类缺陷的形状',
            COALESCE(v_verdict->>'verdict', '(调不动)');
    END IF;
    -- 批量录入页走的是另一个入口,同样要能被真实读者调用
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT jsonb_array_length(preview_metal_price_anomalies(DATE '2027-03-03',
        jsonb_build_array(
            jsonb_build_object('metal', 'li', 'price_usd_per_tonne', '500'),
            jsonb_build_object('metal', 'mn', 'price_usd_per_tonne', ''))))
      INTO v_n;
    RESET ROLE;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 48F 失败:一填一空的预览应当只回一条判词,实得 % —— 空格子跳过(每日表单常常只填几个金属),与 upsert_metal_prices 同口径', v_n;
    END IF;
END $$;
ROLLBACK;
