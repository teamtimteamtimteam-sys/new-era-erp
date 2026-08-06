-- db/functions/reopen_financial_year.sql
-- 重开年(FIN-23)。分录不可变 → 重开 = 结转分录的镜像冲销(日期同为年末,连
-- "截至年末"口径的报表一并复原)+ year_closes 盖章留痕(守卫触发器只放行这一种
-- UPDATE)。必须给理由;隔着后年重开前年拒绝(LATER_YEAR_CLOSED)。
-- 【不动 locked_before】:关年没动过它,重开也不动 —— 要改年内月份,下一步是
-- reopen_period(月级、自己留痕);YEAR_CLOSED 闸已随盖章抬起。

CREATE OR REPLACE FUNCTION public.reopen_financial_year(p_year_end date, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_row   record;
    v_lines jsonb := '[]'::jsonb;
    v_l     record;
    v_je    jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;
    PERFORM 1 FROM finance_settings WHERE id FOR UPDATE;

    SELECT * INTO v_row FROM year_closes
    WHERE year_end = p_year_end AND reopened_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        IF EXISTS (SELECT 1 FROM year_closes WHERE year_end = p_year_end) THEN
            RAISE EXCEPTION 'ALREADY_REOPENED';
        END IF;
        RAISE EXCEPTION 'CLOSE_NOT_FOUND';
    END IF;
    -- 只能从最晚的仍有效年结往回重开 —— 隔着后年重开前年,3100 的链条就断了
    IF EXISTS (SELECT 1 FROM year_closes
               WHERE reopened_at IS NULL AND year_end > p_year_end) THEN
        RAISE EXCEPTION 'LATER_YEAR_CLOSED|%', p_year_end;
    END IF;

    -- 冲销行 = 结转分录的镜像(借贷互换),日期同为年末 —— 恢复到关年之前的
    -- 状态,连"截至年末"口径的报表也一并复原
    FOR v_l IN
        SELECT a.code, jl.debit, jl.credit
        FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
        WHERE jl.entry_id = v_row.closing_journal_id
        ORDER BY a.code
    LOOP
        v_lines := v_lines || jsonb_build_object(
            'account_code', v_l.code,
            'side', CASE WHEN v_l.debit > 0 THEN 'credit' ELSE 'debit' END,
            'currency', 'SGD', 'amount_ccy', CASE WHEN v_l.debit > 0 THEN v_l.debit ELSE v_l.credit END,
            'fx_rate', 1, 'line_memo', 'year-end close reversal');
    END LOOP;

    -- 凭 close_ctx 过两道闸(本年 year_closes 行此刻仍有效 → YEAR_CLOSED 需豁免;
    -- 月锁同理),先过账、后一次性盖章 —— 守卫触发器只放行这一种 UPDATE。
    PERFORM set_config('evoltrya.close_ctx', 'year_close', true);
    v_je := post_journal_entry(p_year_end,
        'REVERSAL: year-end close FY ending ' || p_year_end || ' — ' || btrim(p_reason),
        'year_close', v_row.id, v_lines);
    PERFORM set_config('evoltrya.close_ctx', '', true);

    UPDATE year_closes
    SET reopened_at = now(), reopened_by = v_user, reopen_reason = btrim(p_reason),
        reversal_journal_id = (v_je->>'entry_id')::uuid
    WHERE id = v_row.id;

    RETURN jsonb_build_object('year_end', p_year_end,
        'reversal_journal_code', v_je->>'code', 'net_result_reversed', v_row.net_result);
END;
$function$;
