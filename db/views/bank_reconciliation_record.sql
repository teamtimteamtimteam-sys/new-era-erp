-- db/views/bank_reconciliation_record.sql
-- BANK-REC:**每月的对账记录 —— 事后读得到的那一份。**
--
-- 【冻结的 vs 今天重算的,并排,谁也不替换谁】
--   bank_closing_balance / book_balance / difference —— 对账那一刻抄下来的,不动。
--   book_balance_now / book_balance_drift —— 现在重算的,以及两者之差。
--   与 GST 已申报的那一份同一条规矩。
--
-- ★ CLEANUP-A(2026-08-31):壳 + DEFINER 取数体 ★
--   它【不在委托书点名的六个里】,一起做的理由:它是 bank_reconciliation_status
--   的同胞,同样消费 bank_book_balance_asof 并拿它做减法,而无权限读者从前拿到的是
--   **空列表** —— R1 明写着 NEVER AN EMPTY LIST。修一张留一张,就是"两处分开看都好、
--   合起来仍然说谎"的同一个形状。
--
-- WITH (security_invoker = on) 与 COMMENT ON VIEW 是手工补回来的。
--
-- NOTE: introduced by db/migrations/2026-08-26-bankrec-balance-agreement-and-the-explained-difference.sql.
-- NOTE: repointed at bank_reconciliation_record_rows() by
--       db/migrations/2026-08-31-cleanupa-a-restricted-reader-gets-a-name-not-a-smaller-number.sql.

CREATE VIEW public.bank_reconciliation_record WITH (security_invoker=on) AS
 SELECT reconciliation_id,
    statement_id,
    statement_code,
    bank_account_code,
    period_start,
    period_end,
    currency,
    bank_closing_balance,
    book_balance,
    difference,
    matched_lines,
    ignored_lines,
    reconciled_at,
    reconciled_by,
    superseded_at,
    superseded_reason,
    is_current,
    book_balance_now,
    book_balance_drift,
    variance_item_count
   FROM bank_reconciliation_record_rows() r(reconciliation_id, statement_id, statement_code, bank_account_code, period_start, period_end, currency, bank_closing_balance, book_balance, difference, matched_lines, ignored_lines, reconciled_at, reconciled_by, superseded_at, superseded_reason, is_current, book_balance_now, book_balance_drift, variance_item_count);

COMMENT ON VIEW public.bank_reconciliation_record IS
    '每月的对账记录 —— 事后读得到的那一份。冻结的(bank_closing_balance / book_balance / difference)与现在重算的(book_balance_now / book_balance_drift)并排,谁也不替换谁。CLEANUP-A 起它是bank_reconciliation_record_rows() 的一层壳,按 module.finance.view 按名拒绝 —— 从前无权限读者拿到的是空列表。';
