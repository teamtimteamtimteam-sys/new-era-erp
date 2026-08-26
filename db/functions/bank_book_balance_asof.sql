CREATE OR REPLACE FUNCTION public.bank_book_balance_asof(p_account_code text, p_as_of date)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
    SELECT round(COALESCE(sum(
               CASE WHEN jl.debit > 0 THEN jl.amount_ccy ELSE -jl.amount_ccy END
           ), 0), 2)
    FROM journal_activity_lines(NULL, p_as_of, true) act
    JOIN journal_lines jl ON jl.id = act.line_id
    WHERE act.account_code = p_account_code
      AND jl.currency = bank_native_currency(p_account_code);
$function$;