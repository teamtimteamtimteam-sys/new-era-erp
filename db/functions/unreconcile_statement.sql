CREATE OR REPLACE FUNCTION public.unreconcile_statement(p_statement_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_stmt record;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_stmt FROM bank_statements
    WHERE id = p_statement_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'STATEMENT_NOT_FOUND|%', p_statement_id;
    END IF;
    IF v_stmt.status <> 'reconciled' THEN
        RAISE EXCEPTION 'STATEMENT_NOT_RECONCILED|%', v_stmt.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    UPDATE bank_reconciliations
    SET superseded_at = now(), superseded_reason = btrim(p_reason)
    WHERE statement_id = p_statement_id AND superseded_at IS NULL;

    UPDATE bank_statements
    SET status = 'open',
        reconciled_at = NULL,
        reconciled_by = NULL,
        notes = COALESCE(notes || E'\n', '') || 'UNRECONCILED ' || now()::text || ': ' || btrim(p_reason)
    WHERE id = p_statement_id;
END;
$function$;