-- db/views/bank_reconciliation_status.sql
-- 银行对账总览:每个银行账户一行('1000' SGD / '1010' USD)。
-- ledger_balance = 该科目上 posted 分录行的原币净额(借正贷负,币种 = 账户本币)。
-- 对账恒等式:latest_closing_balance + 未匹配分录行净额 − 未匹配报表行净额
-- 应当回到 ledger_balance —— difference(= ledger_balance − latest_closing_balance)
-- 的缺口由两侧未匹配清单解释(UI 并排列出:未匹配分录行 = 账上有银行没有;
-- 未匹配报表行 = 银行有账上没有)。未导入过报表时 difference 为 NULL。
-- SECURITY INVOKER。
-- NOTE: introduced by db/migrations/2026-07-30-phase3-s3a-bank-reconciliation.sql.

CREATE OR REPLACE VIEW public.bank_reconciliation_status
WITH (security_invoker = on) AS
 SELECT b.account_code,
    bank_native_currency(b.account_code) AS currency,
    round(COALESCE(led.balance, 0::numeric), 2) AS ledger_balance,
    ls.code AS latest_statement_code,
    ls.period_end AS latest_statement_period_end,
    ls.closing_balance AS latest_closing_balance,
    COALESCE(sl.unmatched, 0::bigint) AS unmatched_statement_lines,
    COALESCE(sl.ignored, 0::bigint) AS ignored_statement_lines,
    COALESCE(jl.unmatched_count, 0::bigint) AS unmatched_journal_lines,
    round(COALESCE(jl.unmatched_net, 0::numeric), 2) AS unmatched_journal_amount,
    round(COALESCE(led.balance, 0::numeric) - ls.closing_balance, 2) AS difference
   FROM ( VALUES ('1000'::text), ('1010'::text)) b(account_code)
     LEFT JOIN LATERAL ( SELECT sum(
                CASE
                    WHEN l.debit > 0::numeric THEN l.amount_ccy
                    ELSE - l.amount_ccy
                END) AS balance
           FROM journal_lines l
             JOIN accounts a ON a.id = l.account_id AND a.code = b.account_code
             JOIN journal_entries e ON e.id = l.entry_id AND e.status = 'posted'::text
          WHERE l.currency = bank_native_currency(b.account_code)) led ON true
     LEFT JOIN LATERAL ( SELECT s.code,
            s.period_end,
            s.closing_balance
           FROM bank_statements s
          WHERE s.bank_account_code = b.account_code AND s.deleted_at IS NULL
          ORDER BY s.period_end DESC, s.created_at DESC
         LIMIT 1) ls ON true
     LEFT JOIN LATERAL ( SELECT count(*) FILTER (WHERE l.match_status = 'unmatched'::text) AS unmatched,
            count(*) FILTER (WHERE l.match_status = 'ignored'::text) AS ignored
           FROM bank_statement_lines l
             JOIN bank_statements s ON s.id = l.statement_id
          WHERE s.bank_account_code = b.account_code AND s.deleted_at IS NULL) sl ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS unmatched_count,
            sum(
                CASE
                    WHEN l.debit > 0::numeric THEN l.amount_ccy
                    ELSE - l.amount_ccy
                END) AS unmatched_net
           FROM journal_lines l
             JOIN accounts a ON a.id = l.account_id AND a.code = b.account_code
             JOIN journal_entries e ON e.id = l.entry_id AND e.status = 'posted'::text
          WHERE l.currency = bank_native_currency(b.account_code) AND NOT (EXISTS ( SELECT 1
                   FROM bank_line_matches m
                  WHERE m.journal_line_id = l.id))) jl ON true;
