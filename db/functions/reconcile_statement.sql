CREATE OR REPLACE FUNCTION public.reconcile_statement(p_statement_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_stmt        record;
    v_outstanding integer;
    v_matched     integer;
    v_ignored     integer;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_stmt FROM bank_statements
    WHERE id = p_statement_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'STATEMENT_NOT_FOUND|%', p_statement_id;
    END IF;
    IF v_stmt.status <> 'open' THEN
        RAISE EXCEPTION 'STATEMENT_ALREADY_RECONCILED|%', v_stmt.code;
    END IF;

    SELECT count(*) FILTER (WHERE match_status = 'unmatched'),
           count(*) FILTER (WHERE match_status = 'matched'),
           count(*) FILTER (WHERE match_status = 'ignored')
    INTO v_outstanding, v_matched, v_ignored
    FROM bank_statement_lines
    WHERE statement_id = p_statement_id;

    IF v_outstanding > 0 THEN
        RAISE EXCEPTION 'LINES_OUTSTANDING|%', v_outstanding;
    END IF;

    UPDATE bank_statements
    SET status = 'reconciled', reconciled_at = now(), reconciled_by = auth.uid()
    WHERE id = p_statement_id;

    RETURN jsonb_build_object(
        'statement_id', p_statement_id,
        'code', v_stmt.code,
        'matched_lines', v_matched,
        'ignored_lines', v_ignored,
        'closing_balance', v_stmt.closing_balance
    );
END;
$function$;