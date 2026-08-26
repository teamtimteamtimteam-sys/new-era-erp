-- db/views/fx_month_end_readiness.sql
-- FX-RATES-1:**月末重估跑不跑得起来 —— 一个月末一个币种一行。**
--
-- ★【为什么这是【另一张】视图,而不是给 fx_rate_gaps 加第三种 gap_source】★
--   **两张视图断言的是两件不同的事,而其中一件的可信度全靠它【不】做另一件:**
--     · `fx_rate_gaps`:「**发生过事情**的那一天缺牌价」——
--       它的每一行都有证据撑着(那天有过账,或那天有报价)。
--     · 本视图:「**可能什么都还没发生**的那一天【仍然】需要牌价」——
--       月末正是这样的日子:2026-08-31 上没有一笔过账、没有一条报价,
--       而月末重估**非要它的中间价不可**。
--   把"发明出来的日期"塞进 fx_rate_gaps,会毁掉【它每一行都有证据】这个性质,
--   而那正是它值得被相信的全部理由。**所以:两张视图,两个意思,不要合并。**
--   (同一段话抄在 fx_rate_gaps 的文件头上。)
--
-- 【问的是 fx_rate_asof,不是精确匹配】因为重估问的就是它:月末落在周六时,
-- 用周五的中间价是对的(FIN-19 的有界回溯),那种日子【就绪】,不该报成缺。
--
-- 【revalued 用 status='posted',而这是【对的】那一类用法】它问的是
-- "这一期已经重估过了吗" ——【单张分录还活着没有】,不是求和
-- (AGENTS.md「求和 vs 判活」那一节)。
--
-- 【范围由数据定】从第一笔外币货币性分录所在的月份起,到当月止。
-- 没有外币分录就一行都没有 —— 空集在这里是正确答案,不是失败。
-- SECURITY INVOKER。
--
-- NOTE: introduced by db/migrations/2026-08-27-fxrates1-one-write-path-history-and-month-end-readiness.sql.

CREATE OR REPLACE VIEW public.fx_month_end_readiness
WITH (security_invoker = on) AS
 WITH b AS (
         SELECT c_1.code
           FROM currencies c_1
          WHERE c_1.is_base
        ), fx_lines AS (
         SELECT jl.currency,
            e.entry_date
           FROM journal_lines jl
             JOIN accounts a ON a.id = jl.account_id
             JOIN journal_entries e ON e.id = jl.entry_id
          WHERE a.is_monetary AND jl.currency <> (( SELECT b.code
                   FROM b))
        ), ccy AS (
         SELECT DISTINCT fx_lines.currency
           FROM fx_lines
        ), span AS (
         SELECT date_trunc('month'::text, min(fx_lines.entry_date)::timestamp with time zone)::date AS first_month
           FROM fx_lines
        ), months AS (
         SELECT (date_trunc('month'::text, gs.gs)::date + '1 mon'::interval - '1 day'::interval)::date AS month_end
           FROM span,
            LATERAL generate_series(span.first_month::timestamp with time zone, date_trunc('month'::text, CURRENT_DATE::timestamp with time zone)::date::timestamp with time zone, '1 mon'::interval) gs(gs)
          WHERE span.first_month IS NOT NULL
        )
 SELECT m.month_end,
    c.currency,
    ( SELECT x.rate
           FROM fx_rate_asof(c.currency, m.month_end, 'mid'::text) x(rate, as_of)) AS mid_rate,
    ( SELECT x.as_of
           FROM fx_rate_asof(c.currency, m.month_end, 'mid'::text) x(rate, as_of)) AS mid_rate_as_of,
    (( SELECT x.rate
           FROM fx_rate_asof(c.currency, m.month_end, 'mid'::text) x(rate, as_of))) IS NOT NULL AS has_mid,
    (EXISTS ( SELECT 1
           FROM journal_entries e2
          WHERE e2.source_type = 'revaluation'::text AND e2.entry_date = m.month_end AND e2.status = 'posted'::text)) AS revalued,
    (( SELECT x.rate
           FROM fx_rate_asof(c.currency, m.month_end, 'mid'::text) x(rate, as_of))) IS NULL AND NOT (EXISTS ( SELECT 1
           FROM journal_entries e3
          WHERE e3.source_type = 'revaluation'::text AND e3.entry_date = m.month_end AND e3.status = 'posted'::text)) AS blocks_close
   FROM months m
     CROSS JOIN ccy c;
