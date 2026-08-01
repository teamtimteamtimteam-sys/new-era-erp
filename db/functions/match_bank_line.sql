CREATE OR REPLACE FUNCTION public.match_bank_line(p_statement_line_id uuid, p_journal_line_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_line   record;
    v_jl_id  uuid;
    v_jl     record;
    v_sum    numeric := 0;
    v_count  integer := 0;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT l.id, l.amount, l.match_status,
           s.status AS stmt_status, s.bank_account_code, s.currency
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
    IF v_line.match_status <> 'unmatched' THEN
        RAISE EXCEPTION 'LINE_NOT_UNMATCHED|%', v_line.match_status;
    END IF;

    IF p_journal_line_ids IS NULL OR array_length(p_journal_line_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'NO_JOURNAL_LINES';
    END IF;

    FOREACH v_jl_id IN ARRAY p_journal_line_ids
    LOOP
        SELECT l.id, l.debit, l.credit, l.currency, l.amount_ccy,
               a.code AS account_code, e.status AS entry_status
        INTO v_jl
        FROM journal_lines l
        JOIN accounts a ON a.id = l.account_id
        JOIN journal_entries e ON e.id = l.entry_id
        WHERE l.id = v_jl_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'JL_NOT_FOUND|%', v_jl_id;
        END IF;
        IF v_jl.account_code <> v_line.bank_account_code THEN
            RAISE EXCEPTION 'JL_WRONG_ACCOUNT|%', v_jl_id;
        END IF;
        IF v_jl.currency <> v_line.currency THEN
            RAISE EXCEPTION 'JL_WRONG_CURRENCY|%|%', v_jl_id, v_jl.currency;
        END IF;
        IF EXISTS (SELECT 1 FROM bank_line_matches m WHERE m.journal_line_id = v_jl_id) THEN
            RAISE EXCEPTION 'JL_ALREADY_MATCHED|%', v_jl_id;
        END IF;
        IF v_jl.entry_status <> 'posted' THEN
            RAISE EXCEPTION 'JL_ENTRY_REVERSED|%', v_jl_id;
        END IF;
        -- 方向:入账(+)= 银行借方,出账(−)= 银行贷方
        IF (v_line.amount > 0 AND v_jl.debit <= 0) OR (v_line.amount < 0 AND v_jl.credit <= 0) THEN
            RAISE EXCEPTION 'JL_WRONG_DIRECTION|%', v_jl_id;
        END IF;

        -- 立即插入:同一数组里的重复 id 会被上面的 already-matched 检查看见
        INSERT INTO bank_line_matches (statement_line_id, journal_line_id, matched_amount)
        VALUES (p_statement_line_id, v_jl_id, v_jl.amount_ccy);

        v_sum := v_sum + v_jl.amount_ccy;
        v_count := v_count + 1;
    END LOOP;

    IF round(v_sum, 2) IS DISTINCT FROM round(abs(v_line.amount), 2) THEN
        RAISE EXCEPTION 'MATCH_AMOUNT_MISMATCH|%|%', round(abs(v_line.amount), 2), round(v_sum, 2);
    END IF;

    UPDATE bank_statement_lines SET match_status = 'matched' WHERE id = p_statement_line_id;

    RETURN jsonb_build_object(
        'statement_line_id', p_statement_line_id,
        'matched_count', v_count,
        'matched_total', round(v_sum, 2)
    );
END;
$function$;