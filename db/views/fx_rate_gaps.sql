-- db/views/fx_rate_gaps.sql
-- 【缺牌价的日子】:有外币过账、当天却缺任一侧牌价的 (日期, 币种),每行列出缺哪几侧。
-- C5 让"当天没牌价"的交易直接失败,所以这里主要顶出来的是:
-- 手工分录显式给了汇率的那些天(post_journal_entry 仍收手工汇率),
-- 以及换基准之前的旧数据。牌价是每日日课 —— 这张视图就是漏掉那天的账单。
-- SECURITY INVOKER:底下 journal/fx 各自的 RLS 说了算。
--
-- NOTE: introduced by db/migrations/2026-08-04-fin0-sgd-base-and-fx-policy.sql.

-- METAL-3(2026-08-11):第二个日期来源 —— 【有报价、而报价币种不是本位币的那些天】。
-- 原来的来源只有【过账】,而报价日不是过账日,CNY 更是永远不会过账(它不可交易)。
-- 于是缺一条 CNY 中间价只会在有人计价时以一次拒绝现身 —— 那是错的一头:
-- 等人处理的事应当先上看板。两个来源要的价种不同(过账日三种,报价日只要 mid),
-- 新增的 gap_source 列说明这一行是【为什么】要价。

CREATE OR REPLACE VIEW public.fx_rate_gaps WITH (security_invoker = on) AS
 SELECT d.rate_date,
    d.currency,
    m.missing_types,
    d.txn_count,
    d.gap_source
   FROM ( SELECT u.rate_date,
            u.currency,
            sum(u.txn_count)::bigint AS txn_count,
            bool_or(u.src = 'posting'::text) AS needs_settlement_types,
            array_to_string(array_agg(DISTINCT u.src ORDER BY u.src), '+'::text) AS gap_source
           FROM ( SELECT e.entry_date AS rate_date,
                    l.currency,
                    count(DISTINCT l.entry_id) AS txn_count,
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
                    count(*) AS txn_count,
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


