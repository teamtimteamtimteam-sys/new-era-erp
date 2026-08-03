-- db/views/fx_rate_gaps.sql
-- 【缺牌价的日子】:有外币过账、当天却缺任一侧牌价的 (日期, 币种),每行列出缺哪几侧。
-- C5 让"当天没牌价"的交易直接失败,所以这里主要顶出来的是:
-- 手工分录显式给了汇率的那些天(post_journal_entry 仍收手工汇率),
-- 以及换基准之前的旧数据。牌价是每日日课 —— 这张视图就是漏掉那天的账单。
-- SECURITY INVOKER:底下 journal/fx 各自的 RLS 说了算。
--
-- NOTE: introduced by db/migrations/2026-08-04-fin0-sgd-base-and-fx-policy.sql.

CREATE VIEW public.fx_rate_gaps WITH (security_invoker = on) AS
 SELECT d.rate_date,
    d.currency,
    m.missing_types,
    d.txn_count
   FROM ( SELECT e.entry_date AS rate_date,
            l.currency,
            count(DISTINCT l.entry_id) AS txn_count
           FROM journal_lines l
             JOIN journal_entries e ON e.id = l.entry_id
          WHERE l.currency <> 'SGD'::text AND e.status = 'posted'::text
          GROUP BY e.entry_date, l.currency) d
     CROSS JOIN LATERAL ( SELECT array_agg(t.t) AS missing_types
           FROM unnest(ARRAY['tt_buy'::text, 'tt_sell'::text, 'mid'::text]) t(t)
          WHERE NOT (EXISTS ( SELECT 1
                   FROM fx_rates r
                  WHERE r.currency = d.currency AND r.rate_date = d.rate_date AND r.rate_type = t.t AND r.deleted_at IS NULL))) m
  WHERE m.missing_types IS NOT NULL;
