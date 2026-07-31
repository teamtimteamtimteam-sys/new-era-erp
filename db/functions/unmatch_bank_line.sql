CREATE OR REPLACE FUNCTION public.unmatch_bank_line(p_statement_line_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_line record;
BEGIN
    SELECT l.id, l.match_status, s.status AS stmt_status
    INTO v_line
    FROM bank_statement_lines l
    JOIN bank_statements s ON s.id = l.statement_id AND s.deleted_at IS NULL
    WHERE l.id = p_statement_line_id
    FOR UPDATE OF l;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'LINE_NOT_FOUND|%', p_statement_line_id;
    END IF;
    IF v_line.stmt_status <> 'open' THEN
        RAISE EXCEPTION 'STATEMENT_RECONCILED';
    END IF;
    IF v_line.match_status <> 'matched' THEN
        RAISE EXCEPTION 'LINE_NOT_MATCHED|%', v_line.match_status;
    END IF;

    DELETE FROM bank_line_matches WHERE statement_line_id = p_statement_line_id;
    UPDATE bank_statement_lines SET match_status = 'unmatched' WHERE id = p_statement_line_id;
END;
$function$
