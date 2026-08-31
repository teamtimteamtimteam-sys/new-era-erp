-- db/views/bank_reconciliation_status.sql
-- 银行对账总览:每个银行账户一行('1000' SGD / '1010' USD)。
--
-- ★ CLEANUP-A(2026-08-31):它现在只是 bank_reconciliation_rows() 的一层壳 ★
--   【为什么】视图【不能 RAISE】。而这张视图对一个没有 module.finance.view 的读者
--   从前返回的既不是"更小的数字"也不是"空列表",而是**两行假零** ——
--   账户码是 VALUES 里硬写的,所以行不会消失,只有钱变成 0.00。
--   实测:operations 读者见 ledger_balance 0.00,而真值是 −29,753.70。
--   **一个空列表还看得出"我什么都没拿到";两行假零看起来就是答案本身。**
--
--   还有一处:旧视图写着 COALESCE(led.balance, 0::numeric),而
--   bank_book_balance_asof 现在对无权限读者返回 NULL —— 那个 COALESCE 会把它
--   **变回 0.00**。两处分开看都"修好了",合起来仍然说谎。COALESCE 已在取数体里拿掉,
--   db/fixtures/175 把【修好的函数穿过修好的视图】一起钉住。
--
-- 对账恒等式、两条 lateral 各自问的问题(尤其 jl 那条为什么【保留】 posted 过滤)
-- 都没有动 —— 理由住在 db/functions/bank_reconciliation_rows.sql 的函数体里。
-- WITH (security_invoker = on) 与 COMMENT ON VIEW 是【手工补回来的】:
-- pg_get_viewdef() 既不吐 reloptions 也不吐对象注释。
--
-- NOTE: introduced by db/migrations/2026-07-30-phase3-s3a-bank-reconciliation.sql.
-- NOTE: repointed at bank_reconciliation_rows() by
--       db/migrations/2026-08-31-cleanupa-a-restricted-reader-gets-a-name-not-a-smaller-number.sql.

CREATE VIEW public.bank_reconciliation_status WITH (security_invoker=on) AS
 SELECT account_code,
    currency,
    ledger_balance,
    latest_statement_code,
    latest_statement_period_end,
    latest_closing_balance,
    unmatched_statement_lines,
    ignored_statement_lines,
    unmatched_journal_lines,
    unmatched_journal_amount,
    difference
   FROM bank_reconciliation_rows() r(account_code, currency, ledger_balance, latest_statement_code, latest_statement_period_end, latest_closing_balance, unmatched_statement_lines, ignored_statement_lines, unmatched_journal_lines, unmatched_journal_amount, difference);

COMMENT ON VIEW public.bank_reconciliation_status IS
    '银行对账总览:每个银行账户一行。CLEANUP-A 起它只是 bank_reconciliation_rows() 的一层壳 —— 视图不能 RAISE,而这张视图对无权限读者从前给出【两行假零】(比空列表更坏:空列表还看得出"我什么都没拿到")。取数体按 module.finance.view 按名拒绝。对账恒等式与两条 lateral 的语义一个字没动,见取数体里的注释。';
