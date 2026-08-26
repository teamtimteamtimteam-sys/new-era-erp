-- db/views/fx_rate_gaps.sql
-- 【缺牌价的日子】:某一天某个外币需要牌价、而当天缺了要的那几侧,一行一个 (日期, 币种)。
-- C5 让"当天没牌价"的交易直接失败,所以这里主要顶出来的是:
-- 手工分录显式给了汇率的那些天(post_journal_entry 仍收手工汇率),
-- 以及换基准之前的旧数据。牌价是每日日课 —— 这张视图就是漏掉那天的账单。
-- SECURITY INVOKER:底下 journal/fx 各自的 RLS 说了算。
--
-- ════════════════════════════════════════════════════════════════════════════
-- FX-RATES-1(2026-08-27):**这张视图【看不见月末】,而那是刻意的。**
-- 它的日期只有两个来源:【过账日】与【报价日】。一个既没有过账、也没有报价的
-- 月末(例如 2026-08-31)对它是【结构性不可见】的 —— 偏偏月末重估非要那天的
-- 中间价不可。那个盲区由 `fx_month_end_readiness` 单独回答。
--
-- ★【不要把两张合并】★ 本视图的每一行都【有证据撑着】:那天确实有过账,
--   或确实有报价。而"月末"是一个【被发明出来的日期】—— 把它塞进来,
--   毁掉的正是"每一行都有证据"这个性质,而那是本视图值得被相信的全部理由。
--   两张视图,两个意思。
-- ════════════════════════════════════════════════════════════════════════════
--
-- NOTE: introduced by db/migrations/2026-08-04-fin0-sgd-base-and-fx-policy.sql.

-- METAL-3(2026-08-11):第二个日期来源 —— 【有报价、而报价币种不是本位币的那些天】。
-- 原来的来源只有【过账】,而报价日不是过账日,CNY 更是永远不会过账(它不可交易)。
-- 于是缺一条 CNY 中间价只会在有人计价时以一次拒绝现身 —— 那是错的一头:
-- 等人处理的事应当先上看板。两个来源要的价种不同(过账日三种,报价日只要 mid),
-- gap_source 列说明这一行是【为什么】要价。

-- ════════════════════════════════════════════════════════════════════════════
-- FXG-1(2026-08-17):【一行一个数,一个数一件事】—— 原来的 txn_count 已经删掉。
--
-- METAL-3 加了第二支来源,却让两支共用一列计数:过账那一支数的是【凭证】,
-- 报价那一支数的是【报价条数】,而外层 sum() 把它们加在一起。页面的文案一律念成
-- "当天 N 笔凭证"。三种谎,全部实测复现过(回滚型探针,线上真实视图输出):
--
--   纯报价日  2026-08-20 CNY {mid}                 txn_count=2  quote
--             —— 那天一笔外币凭证都没有,屏幕上却写"当天 2 笔凭证"。
--   混合日    2026-08-21 CNY {tt_buy,tt_sell,mid}  txn_count=2  posting+quote
--             —— 那个 2 是【1 笔凭证 + 1 条报价】,两种单位相加。
--
-- 线上今天恰好只有 posting 那一支的 7 行,所以这三种谎【一次都没有被看见过】——
-- 这正是它值得修的理由,不是不值得修的理由。
--
-- 【为什么拆成两列,而不是一列加一个随 gap_source 变的标签】混合日两支【都】命中,
-- 它真的有两个数;一列只能挑一个说,那是另一种撒谎。拆开之后每列单位固定,
-- 页面直接画,不做第二次推导。
--
-- 【0 是一次测量,不是占位】纯报价日的 entry_count = 0:过账那一支扫过了那一天,
-- 确实没有非本位币凭证。与「报表不报这一行 ≠ 报表报了 0」不矛盾 ——
-- 那里的 0 是把"没问过"说成"答案是零",这里是问过了、答案就是零。
--
-- 【消费者】/finance/fx 的缺口块(两个计数 + 按 gap_source 说出这是哪一种缺口)、
-- /finance/month-end 的一步(只数行数)、operations_now 的 fx_rate_gap 支
-- (只读 rate_date / currency / missing_types)。db/fixtures/81 把三种行钉住。
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW public.fx_rate_gaps WITH (security_invoker = on) AS
 SELECT d.rate_date,
    d.currency,
    m.missing_types,
    d.entry_count,
    d.quote_count,
    d.gap_source
   FROM ( SELECT u.rate_date,
            u.currency,
            sum(u.entry_count)::bigint AS entry_count,
            sum(u.quote_count)::bigint AS quote_count,
            bool_or(u.src = 'posting'::text) AS needs_settlement_types,
            array_to_string(array_agg(DISTINCT u.src ORDER BY u.src), '+'::text) AS gap_source
           FROM ( SELECT e.entry_date AS rate_date,
                    l.currency,
                    count(DISTINCT l.entry_id) AS entry_count,
                    0::bigint AS quote_count,
                    'posting'::text AS src
                   FROM journal_lines l
                     JOIN journal_entries e ON e.id = l.entry_id
                  WHERE l.currency <> (( SELECT c.code
                           FROM currencies c
                          WHERE c.is_base)) AND e.status = 'posted'::text
                  GROUP BY e.entry_date, l.currency
                UNION ALL
                 SELECT mp.price_date AS rate_date,
                    i.quote_currency AS currency,
                    0::bigint AS entry_count,
                    count(*) AS quote_count,
                    'quote'::text AS src
                   FROM metal_prices mp
                     JOIN metal_price_indices i ON i.code = mp.price_index
                  WHERE mp.deleted_at IS NULL AND i.is_active AND i.quote_currency IS NOT NULL AND i.quote_currency <> (( SELECT c.code
                           FROM currencies c
                          WHERE c.is_base))
                  GROUP BY mp.price_date, i.quote_currency) u
          GROUP BY u.rate_date, u.currency) d
     CROSS JOIN LATERAL ( SELECT array_agg(t.t) AS missing_types
           FROM unnest(
                CASE
                    WHEN d.needs_settlement_types THEN ARRAY['tt_buy'::text, 'tt_sell'::text, 'mid'::text]
                    ELSE ARRAY['mid'::text]
                END) t(t)
          WHERE NOT (EXISTS ( SELECT 1
                   FROM fx_rate_asof(d.currency, d.rate_date, t.t) fx_rate_asof(rate, as_of)))) m
  WHERE m.missing_types IS NOT NULL;
