-- db/views/bank_reconciliation_status.sql
-- 银行对账总览:每个银行账户一行('1000' SGD / '1010' USD)。
-- ledger_balance = 该科目上分录行的原币净额(借正贷负,币种 = 账户本币),
-- 由 bank_book_balance_asof 算 —— **与 reconcile_statement 拒绝时用的是同一份算术**,
-- 所以屏幕上这个数与拦人时那个数不可能各错各的。
-- 对账恒等式:latest_closing_balance + 未匹配分录行净额 − 未匹配报表行净额
-- 应当回到 ledger_balance —— difference(= ledger_balance − latest_closing_balance)
-- 的缺口由两侧未匹配清单解释(UI 并排列出:未匹配分录行 = 账上有银行没有;
-- 未匹配报表行 = 银行有账上没有)。未导入过报表时 difference 为 NULL。
-- SECURITY INVOKER。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【BANK-REC(2026-08-26)修掉的那个缺陷 —— 它一直在线上】
-- ledger_balance 原来自己算,并且带着
--     JOIN journal_entries e ON e.id = l.entry_id AND e.status = 'posted'
-- 而冲销的形状是:原分录翻成 status='reversed',另发一张【等额反向的 posted
-- 冲销分录】。只留 posted 就是【丢掉原分录、留下冲销分录】,净额刚好错成
-- −原分录。**任何一个银行账户,只要它上面有过一笔被冲销的分录,这里显示的
-- 现金余额就是错的** —— 不报错,只是小(或大)了一笔。
-- journal_activity_lines 这个函数就是为了禁止这一条而存在的;本视图现在通过
-- bank_book_balance_asof 读它,于是"哪些行算数"不再由本文件回答。
--
-- 【jl 那条 lateral 为什么【没有】跟着改】它数的是"工作台里还剩几条候选分录",
-- 而候选资格由 match_bank_line 定义 —— 那个函数对属于 reversed 分录的行直接抛
-- JL_ENTRY_REVERSED。所以它是【判断单张分录还活着没有】那一类,是对的用法。
-- 本视图的两条 lateral 本来就问着两个不同的问题,现在各自答对各自那个。
-- ════════════════════════════════════════════════════════════════════════════
--
-- NOTE: introduced by db/migrations/2026-07-30-phase3-s3a-bank-reconciliation.sql.
-- NOTE: ledger_balance repointed at bank_book_balance_asof by
--       db/migrations/2026-08-26-bankrec-balance-agreement-and-the-explained-difference.sql.

CREATE OR REPLACE VIEW public.bank_reconciliation_status
WITH (security_invoker = on) AS
 SELECT b.account_code,
    bank_native_currency(b.account_code) AS currency,
    COALESCE(led.balance, 0::numeric) AS ledger_balance,
    ls.code AS latest_statement_code,
    ls.period_end AS latest_statement_period_end,
    ls.closing_balance AS latest_closing_balance,
    COALESCE(sl.unmatched, 0::bigint) AS unmatched_statement_lines,
    COALESCE(sl.ignored, 0::bigint) AS ignored_statement_lines,
    COALESCE(jl.unmatched_count, 0::bigint) AS unmatched_journal_lines,
    round(COALESCE(jl.unmatched_net, 0::numeric), 2) AS unmatched_journal_amount,
    round(COALESCE(led.balance, 0::numeric) - ls.closing_balance, 2) AS difference
   FROM ( VALUES ('1000'::text), ('1010'::text)) b(account_code)
     LEFT JOIN LATERAL ( SELECT bank_book_balance_asof(b.account_code, NULL::date) AS balance) led ON true
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
