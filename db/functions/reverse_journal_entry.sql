CREATE OR REPLACE FUNCTION public.reverse_journal_entry(p_entry_id uuid, p_reversal_date date, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig        record;
    v_lines       jsonb;
    v_result      jsonb;
    v_reversal_id uuid;
BEGIN
    SELECT * INTO v_orig FROM journal_entries WHERE id = p_entry_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'JE_NOT_FOUND|%', p_entry_id;
    END IF;
    IF v_orig.status <> 'posted' OR v_orig.reversed_by IS NOT NULL THEN
        RAISE EXCEPTION 'JE_ALREADY_REVERSED|%', v_orig.code;
    END IF;

    -- 行全部翻边(debit↔credit),原币金额/汇率原样 → USD 侧必然精确对冲。
    SELECT jsonb_agg(
        jsonb_build_object(
            'account_code', a.code,
            'side', CASE WHEN l.debit > 0 THEN 'credit' ELSE 'debit' END,
            'currency', l.currency,
            'amount_ccy', l.amount_ccy,
            'fx_rate', l.fx_rate,
            'line_memo', l.line_memo
        ) ORDER BY l.created_at, l.id
    ) INTO v_lines
    FROM journal_lines l
    JOIN accounts a ON a.id = l.account_id
    WHERE l.entry_id = p_entry_id;

    -- 期间锁由 post_journal_entry 对 p_reversal_date 统一执行
    v_result := post_journal_entry(
        p_reversal_date,
        'REVERSAL: ' || COALESCE(p_memo, v_orig.memo, v_orig.code),
        v_orig.source_type,
        v_orig.id,
        v_lines
    );
    v_reversal_id := (v_result->>'entry_id')::uuid;

    UPDATE journal_entries
    SET status = 'reversed', reversed_by = v_reversal_id
    WHERE id = p_entry_id;

    RETURN jsonb_build_object(
        'reversal_id', v_reversal_id,
        'code', v_result->>'code'
    );
END;
$function$
