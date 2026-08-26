-- 81 fx_rate_gaps 的每一行,说得出自己是哪一种缺口,并且只数自己那个单位
--
-- 【它守的是什么】这张视图有两支来源(METAL-3):【过账】与【报价】。
-- FXG-1 之前两支共用一列 txn_count,外层 sum() 把它们加在一起,而页面文案一律念成
-- "当天 N 笔凭证"。三种谎,当时全部实测复现过:
--   * 纯报价日:txn_count=2 而那天【一笔外币凭证都没有】;
--   * 混合日:txn_count=2 其实是【1 笔凭证 + 1 条报价】,两种单位相加;
--   * 顶上那句"N 天有外币过账、却没有当日牌价",对纯报价日整句不成立。
--
-- 【为什么线上没抓到】线上当时恰好只有 posting 那一支的 7 行 —— 三种谎一次都没有
-- 被看见过。所以这份 fixture 造出三种行,不指望线上碰巧有。
--
-- 【混合日的两个数【故意不相等】(2 与 3)】相等的话,一个把两列写反的实现、
-- 或者一个两列都填 sum 的实现,都能蒙混过去。差值也让"5"这个错误答案无处可藏。
--
-- 【前提:显式设定,唯一的例外写明理由】
--   * 用到的指数由本 fixture 自建(FXG81 / CNY / house_assumption),【不借 SMM】——
--     SMM 的 quote_currency 曾经是刻意留空的(见该列注释),借它就是把断言挂在
--     一个会变的运行时配置上。
--   * 币种 CNY 【是断言而不是设定】:currencies.code 上有一条 CHECK
--     (code IN ('USD','SGD','CNY')),插不进第四种,所以这里指得出那条强制它不变的
--     守卫 —— README 那条例外分支的判断标准。仍然断言它存在且不是本位币。
--   * fx_rates:本 fixture 用的三天先清空该币种的牌价,不指望重建库恰好是空的。
--     (fx_rate_asof 最多回溯 4 个日历日,所以清的是含前置缓冲的一整段。)
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid;
    a1 uuid; a2 uuid;
    e_mixed uuid; e_post uuid;
    v_base text;

    -- 三天,彼此相隔够远,互不干扰(fx_rate_asof 的回溯上限是 4 个日历日)
    d_quote date := '2029-03-05';   -- 只有报价
    d_post  date := '2029-03-20';   -- 只有过账
    d_mixed date := '2029-04-10';   -- 两者都有

    n_quote_only  int := 2;   -- 纯报价日的报价条数
    n_post_only   int := 1;   -- 纯过账日的凭证数
    n_mixed_entry int := 2;   -- 混合日的凭证数   ┐ 故意不相等
    n_mixed_quote int := 3;   -- 混合日的报价条数 ┘

    rec record;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    IF NOT EXISTS (SELECT 1 FROM currencies WHERE code = 'CNY' AND NOT is_base) THEN
        RAISE EXCEPTION 'FIXTURE 81 前置失败:CNY 必须存在且不是本位币 —— currencies.code 的 CHECK 枚举里有它,若这条不成立说明币种表被改过';
    END IF;

    SELECT id INTO a1 FROM accounts WHERE code = '1000';
    SELECT id INTO a2 FROM accounts WHERE code = '4000';
    IF a1 IS NULL OR a2 IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 81 前置失败:科目表缺 1000 或 4000 —— 两个都是 is_system 的引导科目';
    END IF;

    -- 角色:自建,不借引导角色。视图是 security_invoker,底下 journal/fx 各自 RLS 说了算;
    -- 本 fixture 以 postgres 跑(绕过 RLS),断言的是【行的内容】不是【谁看得见】,
    -- 所以不需要 SET LOCAL ROLE —— 可见性不是这一份的题目。
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-81', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- 【前提显式设定】这三天(含回溯缓冲)不许有 CNY / USD 牌价,否则缺口根本不出现
    UPDATE fx_rates SET deleted_at = now()
     WHERE currency IN ('CNY', 'USD')
       AND rate_date BETWEEN d_quote - 10 AND d_mixed + 10;

    -- 自建指数:不借 SMM
    INSERT INTO metal_price_indices (code, name_en, name_zh, quote_currency, quote_currency_basis, is_active)
    VALUES ('FXG81', 'fixture 81 index', 'fixture 81 指数', 'CNY', 'house_assumption', true);

    -- ── ① 纯报价日:2 条报价,零凭证 ─────────────────────────────────────────
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source, price_index)
    VALUES ('ni', 15000, d_quote, 'broker_quote', 'FXG81'),
           ('co', 22000, d_quote, 'broker_quote', 'FXG81');

    -- ── ② 纯过账日:1 笔 USD 凭证,零报价 ────────────────────────────────────
    INSERT INTO journal_entries (code, entry_date, memo, source_type, status)
    VALUES ('FIX81-POST', d_post, 'fixture 81 posting-only', 'manual', 'posted')
    RETURNING id INTO e_post;
    INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate)
    VALUES (e_post, a1, 100, 0, 'USD', 80, 1.25),
           (e_post, a2, 0, 100, 'USD', 80, 1.25);

    -- ── ③ 混合日:2 笔 CNY 凭证 + 3 条报价,同一天同一币种 ───────────────────
    FOR rec IN SELECT generate_series(1, n_mixed_entry) AS i LOOP
        INSERT INTO journal_entries (code, entry_date, memo, source_type, status)
        VALUES ('FIX81-MIX-' || rec.i, d_mixed, 'fixture 81 mixed', 'manual', 'posted')
        RETURNING id INTO e_mixed;
        INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate)
        VALUES (e_mixed, a1, 100, 0, 'CNY', 500, 0.2),
               (e_mixed, a2, 0, 100, 'CNY', 500, 0.2);
    END LOOP;
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source, price_index)
    VALUES ('ni', 15100, d_mixed, 'broker_quote', 'FXG81'),
           ('co', 22100, d_mixed, 'broker_quote', 'FXG81'),
           ('cu',  8100, d_mixed, 'broker_quote', 'FXG81');

    -- ══════════ A. 纯报价日:数报价,【永远不】声称凭证 ═══════════════════════
    SELECT * INTO rec FROM fx_rate_gaps g WHERE g.rate_date = d_quote AND g.currency = 'CNY';
    IF rec IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 81A 失败:纯报价日 % 没有出现在 fx_rate_gaps 里 —— 报价那一支不再顶缺口了', d_quote;
    END IF;
    IF rec.quote_count <> n_quote_only THEN
        RAISE EXCEPTION 'FIXTURE 81A 失败:纯报价日应报 % 条报价,实得 %', n_quote_only, rec.quote_count;
    END IF;
    IF rec.entry_count <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 81A 失败:纯报价日的凭证数必须是 0,实得 % —— 这一行【一笔外币凭证都没有】,报出任何非零都是凭空说出来的',
            rec.entry_count;
    END IF;
    IF rec.gap_source <> 'quote' THEN
        RAISE EXCEPTION 'FIXTURE 81A 失败:纯报价日的 gap_source 应为 quote,实得 %', rec.gap_source;
    END IF;
    -- 报价日只要 mid,不要结算那两侧 —— 两支来源要的价种不同,这一条把它钉住
    IF rec.missing_types <> ARRAY['mid'::text] THEN
        RAISE EXCEPTION 'FIXTURE 81A 失败:纯报价日只该缺 {mid},实得 % —— 它把结算那两侧也要上了,而报价日不结算',
            rec.missing_types;
    END IF;

    -- ══════════ B. 纯过账日:反过来 ═══════════════════════════════════════════
    SELECT * INTO rec FROM fx_rate_gaps g WHERE g.rate_date = d_post AND g.currency = 'USD';
    IF rec IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 81B 失败:纯过账日 % 没有出现在 fx_rate_gaps 里', d_post;
    END IF;
    IF rec.entry_count <> n_post_only THEN
        RAISE EXCEPTION 'FIXTURE 81B 失败:纯过账日应报 % 笔凭证,实得 %', n_post_only, rec.entry_count;
    END IF;
    IF rec.quote_count <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 81B 失败:纯过账日的报价条数必须是 0,实得 %', rec.quote_count;
    END IF;
    IF rec.gap_source <> 'posting' THEN
        RAISE EXCEPTION 'FIXTURE 81B 失败:纯过账日的 gap_source 应为 posting,实得 %', rec.gap_source;
    END IF;
    -- 过账日要三侧
    IF NOT (rec.missing_types @> ARRAY['tt_buy'::text,'tt_sell'::text,'mid'::text]) THEN
        RAISE EXCEPTION 'FIXTURE 81B 失败:纯过账日应缺 tt_buy/tt_sell/mid 三侧,实得 %', rec.missing_types;
    END IF;

    -- ══════════ C. 混合日:两个数【都说出来】,而且不跨单位相加 ═══════════════
    SELECT * INTO rec FROM fx_rate_gaps g WHERE g.rate_date = d_mixed AND g.currency = 'CNY';
    IF rec IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 81C 失败:混合日 % 没有出现在 fx_rate_gaps 里', d_mixed;
    END IF;
    IF rec.gap_source <> 'posting+quote' THEN
        RAISE EXCEPTION 'FIXTURE 81C 失败:混合日的 gap_source 应为 posting+quote,实得 % —— 两支来源被并成一支了',
            rec.gap_source;
    END IF;
    IF rec.entry_count <> n_mixed_entry THEN
        RAISE EXCEPTION 'FIXTURE 81C 失败:混合日应报 % 笔凭证,实得 % —— 若为 % 就是把报价也数进凭证里了(两种单位相加,正是 FXG-1 之前的行为)',
            n_mixed_entry, rec.entry_count, n_mixed_entry + n_mixed_quote;
    END IF;
    IF rec.quote_count <> n_mixed_quote THEN
        RAISE EXCEPTION 'FIXTURE 81C 失败:混合日应报 % 条报价,实得 % —— 若为 % 就是两列都填了合计',
            n_mixed_quote, rec.quote_count, n_mixed_entry + n_mixed_quote;
    END IF;
    -- 【这一臂不能靠两个数碰巧相等而通过】构造时就让它们不等;这里把那个前提断言出来,
    -- 否则日后有人"顺手统一"成同一个数,写反两列的实现会重新变得抓不到。
    IF n_mixed_entry = n_mixed_quote THEN
        RAISE EXCEPTION 'FIXTURE 81C 无效:混合日的两个计数被构造成相等了 —— 写反两列的实现会照样通过,换个数';
    END IF;
    -- 混合日要三侧(过账那一支要结算价,取并集)
    IF NOT (rec.missing_types @> ARRAY['tt_buy'::text,'tt_sell'::text,'mid'::text]) THEN
        RAISE EXCEPTION 'FIXTURE 81C 失败:混合日应缺三侧(过账那一支要结算价),实得 %', rec.missing_types;
    END IF;

    -- ══════════ D. 那一列真的没了 ═══════════════════════════════════════════
    -- 【为什么要断言一个列【不存在】】留着 txn_count 就是把陷阱留给下一个人:
    -- 一个"有时是凭证数、有时是报价数、有时是两者相加"的列,读的人没有任何办法
    -- 看出自己拿到的是哪一种。它必须是删掉,不是并排放着。
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'fx_rate_gaps' AND column_name = 'txn_count')
    THEN
        RAISE EXCEPTION 'FIXTURE 81D 失败:fx_rate_gaps 上又出现了 txn_count —— 那正是"一个数两种单位"的那一列';
    END IF;
END $$;
ROLLBACK;
