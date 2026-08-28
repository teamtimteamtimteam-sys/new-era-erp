-- db/views/wht_liability_by_month.sql
-- WHT-1:每个代扣月欠 IRAS 多少、已汇多少、余额、法定到期日(次月 15 日)。
--
-- 【属主权限】它读总账与 wht_remittances 两处,invoker 语义会让无权读总账的人
-- 静默少算 —— 少算一笔要汇的税,与 OPS-14 找到的那五处「行悄悄消失」同一个病。
--
-- NOTE: introduced by db/migrations/2026-08-28-wht1-withholding-tax-on-non-resident-payments.sql.

CREATE VIEW public.wht_liability_by_month
WITH (security_invoker = off) AS
WITH withheld AS (
    -- 代扣发生在【付款】那一刻,所以归属月 = 那张分录的日期所在的月。
    -- ★【判据是"不是汇款",不是"是付款"】★ 写成 source_type = 'payment' 会
    --   把【手工分录】对 2150 的调整整个漏掉 —— 而手工分录是这套系统里一条
    --   真实存在的路(/finance/journal/new)。漏掉的后果不是报错,是这张视图
    --   的合计与 2150 的科目余额【对不上】,而没有任何东西会说它对不上。
    --   取补集之后,下面那条不变量才成立:
    --       Σ 各月 unremitted_base ≡ 2150 的科目余额
    --   fixture 142 的 F 臂断言它 —— 两边来自两条【真正不同】的推导路径
    --   (这张视图 vs balance_sheet),所以它是一条【动得开】的勾稽,
    --   不是 OPS-17 抓到的那种"拿一个数和它自己比"。
    SELECT date_trunc('month', l.entry_date)::date AS period_month,
           SUM(l.credit - l.debit)                 AS withheld_base
      FROM journal_activity_lines('1900-01-01'::date, '2999-12-31'::date, true) l
     WHERE l.account_code = '2150'
       AND l.source_type IS DISTINCT FROM 'wht_remittance'
     GROUP BY 1
), remitted AS (
    -- 【按它自己声明的所属月归集,不按汇款日】—— 八月的税九月汇,
    -- 按汇款日归集会让八月永远欠着、九月永远多汇。
    -- 【这里【就是】status='posted' 正确的那一种用法】问的是"这一笔汇款
    -- 还立着吗" —— 单张分录的死活。冲销一笔汇款,原分录变 reversed,
    -- 这一行就整个掉出来,而它的冲销分录带着同一个 source_type('wht_remittance',
    -- reverse_journal_entry_internal 原样抄),于是也【不会】被上面那半
    -- 当成一笔新的代扣数进去。两半各自正确,合起来这个月的余额干净地回涨。
    SELECT r.period_month,
           SUM(r.amount_base) AS remitted_base
      FROM wht_remittances r
      JOIN journal_entries e ON e.id = r.journal_entry_id
     WHERE e.status = 'posted'          -- ← 单张分录的死活,见上面第二条
     GROUP BY 1
)
SELECT m.period_month,
       COALESCE(w.withheld_base, 0)                                   AS withheld_base,
       COALESCE(r.remitted_base, 0)                                   AS remitted_base,
       COALESCE(w.withheld_base, 0) - COALESCE(r.remitted_base, 0)    AS unremitted_base,
       -- 【次月 15 日】—— 法定期限。与 CPF 的次月 14 日是两个不同的数,
       -- 各自来自各自的法令,不要"顺手统一"。
       (m.period_month + INTERVAL '1 month 14 days')::date            AS due_date,
       ((m.period_month + INTERVAL '1 month 14 days')::date < CURRENT_DATE
        AND COALESCE(w.withheld_base, 0) - COALESCE(r.remitted_base, 0) > 0) AS is_overdue
  FROM (SELECT period_month FROM withheld
        UNION
        SELECT period_month FROM remitted) m
  LEFT JOIN withheld w ON w.period_month = m.period_month
  LEFT JOIN remitted r ON r.period_month = m.period_month
 -- ★ fu1:**读者自己的模块谓词** —— 属主权限解决"读得到",这一句解决"谁可以读"。
 --   属主权限让本视图跨总账与 wht_remittances 读全量(invoker 会静默少算一笔
 --   要汇的税,与 OPS-14 那五处「行悄悄消失」同病);而它【不】回答谁可以读,
 --   于是没有这一句时,任何登录用户都能经 PostgREST 读到公司欠 IRAS 多少。
 --   has_permission() 是 SECURITY DEFINER 且按 auth.uid() 解析,答的是【调用者】,
 --   与这张视图归谁所有无关 —— 先例是 db/views/customer_credit_status.sql。
 WHERE has_permission('module.finance.view'::text);

GRANT SELECT ON public.wht_liability_by_month TO authenticated;

COMMENT ON VIEW public.wht_liability_by_month IS
'WHT-1:每个代扣月欠 IRAS 多少、已汇多少、余额、法定到期日(次月 15 日)。
**属主权限**:它读总账与 wht_remittances 两处,而 invoker 语义会让无权读总账的人
静默少算 —— 少算一笔要汇的税,与 OPS-14 那五处"行悄悄消失"是同一个病。
读者的门在 /finance/wht 那一页与 operations_now 的 wht_due 支上按 permission 判。

【一个月被汇过之后又出现新的代扣,余额会重新变正 —— 那是对的,不是漂移】
补记一张八月的付款,八月就确实又欠了税。视图【分开报】冻下来的与现在算出来的
两个数(remitted_base / withheld_base),不把它们抹平 —— 与 gst_return_boxes
那条"当时报了多少"与"现在算出来多少"是两个问题,逐字同源。';
