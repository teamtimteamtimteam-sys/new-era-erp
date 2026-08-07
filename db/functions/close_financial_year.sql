-- db/functions/close_financial_year.sql
-- 年结(FIN-23)。一张分录、日期 = 财年末:每个非零损益科目清零,净额对 3100。
-- 科目按 account_type 推导(见 preview 头注);幂等靠算术(已结/空年 → 全零,
-- 不过账不留行);只能结推导出的下一个财年(乱序会打断 3100 的链条)。
-- 硬前置:月结锁位已过年末(只断言,不动锁)、试算平衡、重估已平、折旧已平 ——
-- 每条点名拒。结转分录凭 evoltrya.close_ctx 过月锁(用毕即清);year_closes 行
-- 随后落库,自此 YEAR_CLOSED 闸生效。

CREATE OR REPLACE FUNCTION public.close_financial_year(p_year_end date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_fs       record;
    v_preview  jsonb;
    v_r        jsonb;
    v_lines    jsonb := '[]'::jsonb;
    v_net      numeric;
    v_amt      numeric;
    v_je       jsonb;
    v_close_id uuid := gen_random_uuid();
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_year_end IS NULL THEN
        RAISE EXCEPTION 'DATE_REQUIRED';
    END IF;
    -- 串行化(与月结同一把锁)
    SELECT * INTO v_fs FROM finance_settings WHERE id FOR UPDATE;

    v_preview := preview_close_financial_year(p_year_end);

    -- 幂等出口:已结(累计已归零)→ 什么都不做,原样说明
    IF (v_preview->>'already_closed')::boolean THEN
        RETURN jsonb_build_object('year_end', p_year_end, 'net_result', 0,
                                  'journal_code', NULL, 'already_closed', true);
    END IF;

    -- 只能结【推导出的下一个财年】—— 乱序关年会把留存收益链条打断
    IF p_year_end <> (v_preview->>'expected_year_end')::date THEN
        RAISE EXCEPTION 'YEAR_END_INVALID|%|%', p_year_end, v_preview->>'expected_year_end';
    END IF;

    -- 硬前置,逐条点名(软警告不在此列 —— 年末应计与草稿薪资由界面提示复核)
    IF NOT (v_preview->>'final_period_closed')::boolean THEN
        RAISE EXCEPTION 'FINAL_PERIOD_NOT_CLOSED|%|%', p_year_end,
            COALESCE(v_fs.locked_before::text, '(unlocked)');
    END IF;
    IF NOT (v_preview->>'trial_balanced')::boolean THEN
        RAISE EXCEPTION 'TRIAL_BALANCE_UNBALANCED|%', p_year_end;
    END IF;
    IF NOT (v_preview->>'revaluation_level')::boolean THEN
        RAISE EXCEPTION 'REVALUATION_NOT_RUN|%', p_year_end;
    END IF;
    IF NOT (v_preview->>'depreciation_level')::boolean THEN
        RAISE EXCEPTION 'DEPRECIATION_NOT_RUN|%', p_year_end;
    END IF;

    v_net := (v_preview->>'net_result')::numeric;

    -- 结转行:把每个非零损益科目清零(贷余借清、借余贷清),净额对 3100
    FOR v_r IN SELECT * FROM jsonb_array_elements(v_preview->'rows')
    LOOP
        v_amt := (v_r->>'net')::numeric;
        v_lines := v_lines || jsonb_build_object(
            'account_code', v_r->>'account',
            'side', CASE WHEN v_amt > 0 THEN 'debit' ELSE 'credit' END,
            'currency', base_currency_code(), 'amount_ccy', abs(v_amt),
            'line_memo', 'year-end close');
    END LOOP;

    IF jsonb_array_length(v_lines) = 0 THEN
        -- 全年损益净额与逐科目都为零(空年)—— 无可结转,不留分录不留行
        RETURN jsonb_build_object('year_end', p_year_end, 'net_result', 0,
                                  'journal_code', NULL, 'already_closed', false);
    END IF;

    IF v_net <> 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '3100',
            'side', CASE WHEN v_net > 0 THEN 'credit' ELSE 'debit' END,
            'currency', base_currency_code(), 'amount_ccy', abs(v_net),
            'line_memo', 'net result to retained earnings');
    END IF;

    -- 结转分录日期 = 年末,而年末已被月结锁住(硬前置)—— 凭 close_ctx 过月锁,
    -- 用毕即清(movement_ctx 同款)。YEAR_CLOSED 闸此刻无感:本年的 year_closes
    -- 行还没落库。
    PERFORM set_config('evoltrya.close_ctx', 'year_close', true);
    v_je := post_journal_entry(p_year_end,
        'Year-end close FY ending ' || p_year_end, 'year_close', v_close_id, v_lines);
    PERFORM set_config('evoltrya.close_ctx', '', true);

    INSERT INTO year_closes (id, year_end, closing_journal_id, net_result, notes, closed_by)
    VALUES (v_close_id, p_year_end, (v_je->>'entry_id')::uuid, v_net, p_notes, v_user);

    RETURN jsonb_build_object('year_end', p_year_end, 'net_result', v_net,
        'journal_code', v_je->>'code', 'rows', v_preview->'rows',
        'already_closed', false);
END;
$function$;
