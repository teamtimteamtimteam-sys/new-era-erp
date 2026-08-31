-- db/functions/bank_reconciliation_rows.sql
-- CLEANUP-A(2026-08-31):bank_reconciliation_status 的取数体。视图不能 RAISE,
-- 而那张视图从前给无权限读者【两行假零】(比空列表更坏)。照 INV-VAL-1-fu6 的先例。

CREATE OR REPLACE FUNCTION public.bank_reconciliation_rows()
 RETURNS TABLE(account_code text, currency text, ledger_balance numeric, latest_statement_code text, latest_statement_period_end date, latest_closing_balance numeric, unmatched_statement_lines bigint, ignored_statement_lines bigint, unmatched_journal_lines bigint, unmatched_journal_amount numeric, difference numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【definer 必须自己问调用者是谁】—— 授权不是控制。
    PERFORM require_permission('module.finance.view');

    RETURN QUERY
    SELECT b.account_code,
        bank_native_currency(b.account_code),
        -- 【COALESCE(…, 0) 拿掉了,这是本节的要点之一】bank_book_balance_asof
        -- 对没有 finance.view 的读者返回 NULL,而那个 COALESCE 会把它变回 0.00。
        -- 现在:走到这里的人一定有 finance.view(上面那道闸),所以它不会是 NULL;
        -- 万一将来又是了,屏幕上会出现一个空格,而不是一个假的零。
        led.balance,
        ls.code, ls.period_end, ls.closing_balance,
        COALESCE(sl.unmatched, 0::bigint),
        COALESCE(sl.ignored, 0::bigint),
        COALESCE(jl.unmatched_count, 0::bigint),
        round(COALESCE(jl.unmatched_net, 0::numeric), 2),
        -- 未导入过报表时 difference 为 NULL —— 既有行为,一个字没松。
        round(led.balance - ls.closing_balance, 2)
       FROM ( VALUES ('1000'::text), ('1010'::text)) b(account_code)
         LEFT JOIN LATERAL ( SELECT bank_book_balance_asof(b.account_code, NULL::date) AS balance) led ON true
         LEFT JOIN LATERAL ( SELECT s.code, s.period_end, s.closing_balance
               FROM bank_statements s
              WHERE s.bank_account_code = b.account_code AND s.deleted_at IS NULL
              ORDER BY s.period_end DESC, s.created_at DESC
             LIMIT 1) ls ON true
         LEFT JOIN LATERAL ( SELECT count(*) FILTER (WHERE l.match_status = 'unmatched'::text) AS unmatched,
                count(*) FILTER (WHERE l.match_status = 'ignored'::text) AS ignored
               FROM bank_statement_lines l
                 JOIN bank_statements s ON s.id = l.statement_id
              WHERE s.bank_account_code = b.account_code AND s.deleted_at IS NULL) sl ON true
         -- 【这条 lateral 的 posted 过滤【没有】跟着改,而那是对的】它数的是
         -- "工作台里还剩几条候选分录",候选资格由 match_bank_line 定义,而那支函数
         -- 对 reversed 分录的行直接抛 JL_ENTRY_REVERSED。这是"判断单张分录还活着没有",
         -- posted 就是它的正确判据 —— 见 journal_activity_lines 抬头那条判据。
         LEFT JOIN LATERAL ( SELECT count(*) AS unmatched_count,
                sum(CASE WHEN l.debit > 0::numeric THEN l.amount_ccy ELSE - l.amount_ccy END) AS unmatched_net
               FROM journal_lines l
                 JOIN accounts a ON a.id = l.account_id AND a.code = b.account_code
                 JOIN journal_entries e ON e.id = l.entry_id AND e.status = 'posted'::text
              WHERE l.currency = bank_native_currency(b.account_code) AND NOT (EXISTS ( SELECT 1
                       FROM bank_line_matches m
                      WHERE m.journal_line_id = l.id))) jl ON true;
END;
$function$;

COMMENT ON FUNCTION public.bank_reconciliation_rows() IS
    'CLEANUP-A:bank_reconciliation_status 的取数体。存在的理由:视图【不能 RAISE】,所以一张 security_invoker 视图对无权限读者只能给出更小的数字或空列表 —— 而这一张给的是**两行假零**(账户码是 VALUES 里硬写的,行不会消失),实测 operations 读者见 0.00 而真值 −29,753.70。照 INV-VAL-1-fu6 的先例改成壳 + DEFINER 取数体,取数体自己 require_permission(module.finance.view),于是无权限得到按名拒绝。另:旧视图的 COALESCE(led.balance, 0) 会把bank_book_balance_asof 新返回的 NULL 变回 0.00 —— 两处分开看都"修好了",合起来仍然说谎,所以那个 COALESCE 在这里被拿掉。';
