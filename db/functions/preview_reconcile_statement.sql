CREATE OR REPLACE FUNCTION public.preview_reconcile_statement(p_statement_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_stmt        record;
    v_book        numeric;
    v_outstanding integer;
BEGIN
    PERFORM require_permission('module.finance.view');
    SELECT * INTO v_stmt FROM bank_statements
    WHERE id = p_statement_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'STATEMENT_NOT_FOUND|%', p_statement_id;
    END IF;

    v_book := bank_book_balance_asof(v_stmt.bank_account_code, v_stmt.period_end);

    SELECT count(*) FILTER (WHERE match_status = 'unmatched')
    INTO v_outstanding
    FROM bank_statement_lines WHERE statement_id = p_statement_id;

    RETURN jsonb_build_object(
        'statement_id', p_statement_id,
        'code', v_stmt.code,
        'currency', v_stmt.currency,
        'as_of', v_stmt.period_end,
        'bank_closing_balance', v_stmt.closing_balance,
        'book_balance', v_book,
        'difference', round(v_book - v_stmt.closing_balance, 2),
        'outstanding_lines', v_outstanding
    );
END;
$function$;