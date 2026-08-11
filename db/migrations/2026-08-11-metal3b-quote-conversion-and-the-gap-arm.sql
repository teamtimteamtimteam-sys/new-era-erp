-- METAL-3 第二部分(2026-08-11):报价换算(读时、按报价日、中间价、两条腿)
--                                 + 让缺 mid 在【等人处理】那一头出现,而不是在拒绝那一头
--
-- 抬头的完整理由在第一部分(2026-08-11-metal3-smm-quotes-in-cny.sql)。这里只记
-- 两件它没说完的事。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【一 · fx_rate_gaps 盯得住 mid,却盯不住这一刀新加的义务】
-- 那张视图确实对三种价都检查(tt_buy / tt_sell / mid),但它的日期来源是
-- 【过账】—— 有外币分录的那些天。而报价日不是过账日,CNY 更是【永远不会过账】
-- (它不可交易)。于是按本刀的做法,缺一条 CNY 中间价【只会在有人计价时以一次拒绝
-- 现身】,那是错的一头:等人处理的事应当先出现在看板上,而不是等它挡住一次报价。
--
-- 所以这里给它加第二个日期来源:【有报价、而报价币种不是本位币的那些天】。
-- 两个来源要的价并不一样,这一点写进视图而不是抹平:
--     过账日 → tt_buy / tt_sell / mid 都要(结算与重估各取所需)
--     报价日 → 只要 mid(换算用的就是它;在报价日上追问 tt 两侧是噪音)
-- 同一天两种来源都命中时取并集。新增一列 gap_source 说明这一行是【为什么】要价,
-- 免得看板上一条"缺牌价"读起来像是有人漏记了一笔交易。
--
-- 【二 · 换算是一个独立的小函数,spot 与 average 共用】
-- metal_quote_to_usd 一处实现,两个口径调它:
--   * spot:挑中的那一条报价,按【它自己那天】换;
--   * average:窗口内【每一条各按自己那天】换,再取平均 —— 不是先平均再换。
--     先平均再换会让窗口内的一次汇率波动污染窗口里的每一天。
-- 它同时把【出处】吐出来:原始 CNY 数、两条腿的汇率、各自实际取自哪一天
-- (可能因为周末就近取前一天)、以及价种。与 price_history 记
-- original_price / fx_rate / rate_as_of / rate_type 是同一套做法 —— 数要能被重导出,
-- 而不是被相信。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 换算:一处实现 ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.metal_quote_to_usd(
    p_price numeric, p_quote_currency text, p_quote_date date)
RETURNS TABLE(usd numeric, leg jsonb)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    -- 【USD 是本函数族的报价基准,不是本位币】金属按 USD/吨报价是市场惯例
    -- (AGENTS.md 已把它记成一条决定),而本位币是 SGD。两者不是一回事,
    -- 所以这里的 'USD' 不是"把本位币写死了"。
    c_quote_basis constant text := 'USD';
    v_base  text;
    r_ccy   numeric; a_ccy date;
    r_usd   numeric; a_usd date;
BEGIN
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;

    IF p_quote_currency IS NULL THEN
        RAISE EXCEPTION 'INDEX_CURRENCY_NOT_STATED|?';
    END IF;

    -- 报价本来就是 USD:不换算,也不去查任何汇率(没有汇率可编,也没有必要)
    IF p_quote_currency = c_quote_basis THEN
        usd := p_price;
        leg := jsonb_build_object(
            'quote_currency', p_quote_currency,
            'quote_date', p_quote_date,
            'original_price', p_price,
            'converted', false);
        RETURN NEXT;
        RETURN;
    END IF;

    -- 两条腿:报价币 → 本位币 → USD。汇率记的是【本位币 / 一单位外币】,
    -- 所以 usd = price × rate(报价币) / rate(USD)。本位币自己没有行(fx_rates 的
    -- CHECK 挡着),它的"汇率"恒为 1 —— 那是定义,不是兜底。
    IF p_quote_currency = v_base THEN
        r_ccy := 1; a_ccy := p_quote_date;
    ELSE
        -- 缺汇率【不是跳过,是拒绝】:我们手里有那条报价,只是表达不出来。
        -- fx_rate_asof 自己会抛 FX_RATE_MISSING|币种|日期|价种,并带着有界的就近取值。
        SELECT f.rate, f.as_of INTO r_ccy, a_ccy
        FROM fx_rate_asof(p_quote_currency, p_quote_date, 'mid') f;
    END IF;

    IF v_base = c_quote_basis THEN
        r_usd := 1; a_usd := p_quote_date;
    ELSE
        SELECT f.rate, f.as_of INTO r_usd, a_usd
        FROM fx_rate_asof(c_quote_basis, p_quote_date, 'mid') f;
    END IF;

    usd := round(p_price * r_ccy / r_usd, 6);
    leg := jsonb_build_object(
        'quote_currency', p_quote_currency,
        'quote_date', p_quote_date,
        'original_price', p_price,          -- 【发布时的原始数字】,出处的根
        'converted', true,
        'rate_type', 'mid',                 -- 行情是参考价,不是成交价
        'rate_quote_ccy', r_ccy,
        'rate_quote_ccy_as_of', a_ccy,      -- 可能因非发布日就近取前一天
        'rate_usd', r_usd,
        'rate_usd_as_of', a_usd,
        'usd_per_tonne', usd);
    RETURN NEXT;
END;
$function$;

-- ── 缺牌价的日子:第二个来源(报价日,只问 mid)──────────────────────────────
CREATE OR REPLACE VIEW public.fx_rate_gaps WITH (security_invoker = on) AS
 SELECT d.rate_date,
    d.currency,
    m.missing_types,
    d.txn_count,
    d.gap_source
   FROM ( SELECT u.rate_date, u.currency,
                 -- ::bigint 是必需的:sum() 出来是 numeric,而 CREATE OR REPLACE VIEW
                 -- 不许改已有列的类型(原来的 count(*) 是 bigint)
                 sum(u.txn_count)::bigint AS txn_count,
                 -- 过账日要三种价(结算与重估各取所需);报价日只要 mid。
                 -- 【用一个布尔量而不是"数组的数组"】PostgreSQL 没有嵌套数组:
                 -- array_agg(text[]) 会摊平成多维数组,再 unnest 就不是原来那几组了。
                 bool_or(u.src = 'posting') AS needs_settlement_types,
                 array_to_string(array_agg(DISTINCT u.src ORDER BY u.src), '+') AS gap_source
          FROM (
            -- 来源一:有外币过账的那些天(原有行为,一字未改)
            SELECT e.entry_date AS rate_date,
                   l.currency,
                   count(DISTINCT l.entry_id) AS txn_count,
                   'posting'::text AS src
              FROM journal_lines l
              JOIN journal_entries e ON e.id = l.entry_id
             WHERE l.currency <> (SELECT c.code FROM currencies c WHERE c.is_base)
               AND e.status = 'posted'::text
             GROUP BY e.entry_date, l.currency
            UNION ALL
            -- 来源二(METAL-3):有报价、而报价币种不是本位币的那些天。
            -- 换算只用 mid,所以只问 mid —— 在报价日上追问 tt 两侧是噪音。
            -- 【为什么必须有这一支】CNY 永远不会过账(它不可交易),所以来源一
            -- 看不见它;缺一条 CNY 中间价就只会以"计价被拒"现身,那是错的一头 ——
            -- 等人处理的事应当先上看板,而不是等它挡住一次报价。
            SELECT mp.price_date AS rate_date,
                   i.quote_currency AS currency,
                   count(*) AS txn_count,
                   'quote'::text AS src
              FROM metal_prices mp
              JOIN metal_price_indices i ON i.code = mp.price_index
             WHERE mp.deleted_at IS NULL
               AND i.is_active
               AND i.quote_currency IS NOT NULL
               AND i.quote_currency <> (SELECT c.code FROM currencies c WHERE c.is_base)
             GROUP BY mp.price_date, i.quote_currency
          ) u
          GROUP BY u.rate_date, u.currency) d
     CROSS JOIN LATERAL ( SELECT array_agg(t.t) AS missing_types
           FROM unnest(CASE WHEN d.needs_settlement_types
                            THEN ARRAY['tt_buy'::text,'tt_sell'::text,'mid'::text]
                            ELSE ARRAY['mid'::text] END) t(t)
          WHERE NOT (EXISTS ( SELECT 1
                   FROM fx_rate_asof(d.currency, d.rate_date, t.t) fx_rate_asof(rate, as_of)))) m
  WHERE m.missing_types IS NOT NULL;

COMMIT;
