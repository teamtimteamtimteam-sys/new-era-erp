-- db/views/bank_reconciliation_record.sql
-- BANK-REC:**每月的对账记录 —— 事后读得到的那一份。**
--
-- 队列要的是「每月:银行余额、账面余额、差额、说明」。一次对账 = 
-- bank_reconciliations 里的一行,而报表本来就是按月的,所以这张视图就是那份记录。
--
-- 【冻结的 vs 今天重算的,并排,谁也不替换谁】
--   bank_closing_balance / book_balance / difference —— 对账那一刻抄下来的,不动。
--   book_balance_now —— 现在用 bank_book_balance_asof 重算的。
--   book_balance_drift —— 两者之差。**它不为零本身就是要给人看的信息**:
--     日期在 period_end 当天或之前的分录后来动过。
-- 与 GST 已申报的那一份同一条规矩:「我们当时报了多少」与「现在算出来是多少」
-- 是两个不同的问题,把它们抹平才是错的。
--
-- is_current:未被 unreconcile 掀掉的那一份。掀掉的行留着(superseded_at + 理由),
-- 于是"这张报表先后对过几次、每次签的是什么"读得出来。
-- SECURITY INVOKER —— 两张底表各自的 RLS(module.finance.view)照常生效。
--
-- NOTE: introduced by db/migrations/2026-08-26-bankrec-balance-agreement-and-the-explained-difference.sql.

CREATE OR REPLACE VIEW public.bank_reconciliation_record
WITH (security_invoker = on) AS
 SELECT r.id AS reconciliation_id,
    s.id AS statement_id,
    s.code AS statement_code,
    s.bank_account_code,
    s.period_start,
    s.period_end,
    r.currency,
    r.bank_closing_balance,
    r.book_balance,
    r.difference,
    r.matched_lines,
    r.ignored_lines,
    r.reconciled_at,
    r.reconciled_by,
    r.superseded_at,
    r.superseded_reason,
    r.superseded_at IS NULL AS is_current,
    bank_book_balance_asof(s.bank_account_code, s.period_end) AS book_balance_now,
    round(bank_book_balance_asof(s.bank_account_code, s.period_end) - r.book_balance, 2) AS book_balance_drift,
    COALESCE(vi.item_count, 0::bigint) AS variance_item_count
   FROM bank_reconciliations r
     JOIN bank_statements s ON s.id = r.statement_id
     LEFT JOIN LATERAL ( SELECT count(*) AS item_count
           FROM bank_reconciliation_variance_items v
          WHERE v.reconciliation_id = r.id) vi ON true;
