CREATE OR REPLACE FUNCTION public.close_period(p_period_end date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_locked   date;
    v_count    integer;
    v_debits   numeric;
    v_credits  numeric;
    v_new_lock date;
    v_dep      numeric;
    v_run_n    integer;
    v_runs     text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_period_end IS NULL
       OR p_period_end <> (date_trunc('month', p_period_end) + interval '1 month - 1 day')::date THEN
        RAISE EXCEPTION 'NOT_MONTH_END|%', COALESCE(p_period_end::text, '?');
    END IF;

    SELECT locked_before INTO v_locked FROM finance_settings WHERE id FOR UPDATE;
    IF v_locked IS NOT NULL AND p_period_end < v_locked THEN
        RAISE EXCEPTION 'ALREADY_CLOSED|%', v_locked;
    END IF;

    v_dep := (preview_depreciate_fixed_assets(p_period_end)->>'total_delta')::numeric;
    IF COALESCE(v_dep, 0) > 0 THEN
        RAISE EXCEPTION 'DEPRECIATION_OUTSTANDING|%|%', p_period_end, v_dep;
    END IF;

    -- ★ INV-VAL-1 R8:第五条 —— 已提交但从未分摊成本的加工单挡住关账。
    -- 与折旧那一条同形(都是"这个月还欠着一件必须做完的事"),所以紧挨着它。
    SELECT count(*), string_agg(r.code, ', ' ORDER BY r.process_date, r.code)
      INTO v_run_n, v_runs
      FROM processing_runs r
     WHERE r.deleted_at IS NULL
       AND r.status = 'committed'
       AND r.allocated_at IS NULL
       AND r.process_date <= p_period_end;
    IF COALESCE(v_run_n, 0) > 0 THEN
        RAISE EXCEPTION 'PROCESSING_COSTS_UNALLOCATED|%|%|%', p_period_end, v_run_n, v_runs
          USING HINT = '这些加工单已提交但从未分摊成本 —— 料已经动了,而 1200 还没有被解除。'
                    || '在关账之前把它们分摊掉,或者冲销掉不该存在的那些。';
    END IF;

    SELECT COUNT(DISTINCT jl.entry_id),
           round(COALESCE(SUM(jl.debit), 0), 2),
           round(COALESCE(SUM(jl.credit), 0), 2)
    INTO v_count, v_debits, v_credits
    FROM journal_lines jl
    JOIN journal_entries je ON je.id = jl.entry_id
    WHERE je.entry_date <= p_period_end;

    IF v_debits <> v_credits THEN
        RAISE EXCEPTION 'TRIAL_BALANCE_UNBALANCED|%|%', v_debits, v_credits;
    END IF;

    v_new_lock := p_period_end + 1;

    INSERT INTO period_closes (period_end, notes, entries_count, total_debits, total_credits)
    VALUES (p_period_end, p_notes, v_count, v_debits, v_credits);

    UPDATE finance_settings
    SET locked_before = v_new_lock, updated_by = auth.uid()
    WHERE id;

    RETURN jsonb_build_object(
        'period_end', p_period_end,
        'locked_before', v_new_lock,
        'entries_count', v_count,
        'total_debits', v_debits,
        'total_credits', v_credits
    );
END;
$function$
;
