-- db/functions/bank_reconciliation_record_rows.sql
-- CLEANUP-A(2026-08-31):bank_reconciliation_record 的取数体,判据 module.finance.view。
-- 从前无权限读者拿到【空列表】,而 R1 明写着 NEVER AN EMPTY LIST。

CREATE OR REPLACE FUNCTION public.bank_reconciliation_record_rows()
 RETURNS TABLE(reconciliation_id uuid, statement_id uuid, statement_code text, bank_account_code text, period_start date, period_end date, currency text, bank_closing_balance numeric, book_balance numeric, difference numeric, matched_lines integer, ignored_lines integer, reconciled_at timestamp with time zone, reconciled_by uuid, superseded_at timestamp with time zone, superseded_reason text, is_current boolean, book_balance_now numeric, book_balance_drift numeric, variance_item_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');

    RETURN QUERY
    SELECT r.id, s.id, s.code, s.bank_account_code, s.period_start, s.period_end,
        r.currency, r.bank_closing_balance, r.book_balance, r.difference,
        r.matched_lines, r.ignored_lines, r.reconciled_at, r.reconciled_by,
        r.superseded_at, r.superseded_reason, r.superseded_at IS NULL,
        -- 【冻结的 vs 现在重算的,并排,谁也不替换谁】—— BANK-REC 的规矩,没动。
        bank_book_balance_asof(s.bank_account_code, s.period_end),
        round(bank_book_balance_asof(s.bank_account_code, s.period_end) - r.book_balance, 2),
        COALESCE(vi.item_count, 0::bigint)
       FROM bank_reconciliations r
         JOIN bank_statements s ON s.id = r.statement_id
         LEFT JOIN LATERAL ( SELECT count(*) AS item_count
               FROM bank_reconciliation_variance_items v
              WHERE v.reconciliation_id = r.id) vi ON true;
END;
$function$;

COMMENT ON FUNCTION public.bank_reconciliation_record_rows() IS
    'CLEANUP-A:bank_reconciliation_record 的取数体,判据 module.finance.view。它不在委托书点名的六个里 —— 一起做的理由:它是 bank_reconciliation_status 的同胞,同样消费 bank_book_balance_asof 并拿它做减法(book_balance_drift),而无权限读者从前拿到**空列表**,R1 明写着 NEVER AN EMPTY LIST。修一张留一张,就是"两处分开看都好、合起来仍然说谎"的同一个形状。';
