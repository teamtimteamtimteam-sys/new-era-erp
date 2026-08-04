-- db/functions/revalue_foreign_balances.sql
-- 期末重估(FIN-3):只动【货币性】科目(accounts.is_monetary)的外币余额。
-- 每科目每币种:调整额 = round(外币净额 × 期末中间价, 2) − 当前外币承载基准额。
-- 承载额 = 该科目外币行的基准净额 + 【本函数既往调整行】的基准净额 ——
-- 于是逐期自我修正(D1),同一期末重跑时调整额为零、一行都不发(D4:幂等,
-- 而不是拒绝 —— 拒绝需要记"跑过没有",幂等只需要算术)。
-- 【非货币科目一个不碰】存货、预付、损益类保持历史汇率(Part B)。
-- 期末无中间价即拒(FX_RATE_MISSING,fx_rate_for 只认当日,D2)。
-- 全部进【未实现】7110;已实现差异在结算时点由 record_payment 进 7100(C5)。
-- 期间锁:分录日期 = p_period_end,经 post_journal_entry 的 PERIOD_LOCKED 把守 ——
-- 先重估、后关期,顺序颠倒会被锁拒掉(Part A4)。
--
-- FIN-9(2026-08-05):算术不再自带一份 —— 本函数改为调用
-- preview_revalue_foreign_balances 再据其结果发行。界面预览走同一个函数,于是
-- 屏幕上的调整额与过账的调整额不可能再漂开(修前它们已经漂开了)。
--
-- NOTE: introduced by db/migrations/2026-08-04-fin3-revaluation.sql;
-- refactored by db/migrations/2026-08-05-fin9-revaluation-single-implementation.sql.

CREATE OR REPLACE FUNCTION public.revalue_foreign_balances(p_period_end date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_preview jsonb;
    v_r       jsonb;
    v_adj     numeric;
    v_lines   jsonb := '[]'::jsonb;
    v_detail  jsonb := '[]'::jsonb;
    v_total   numeric := 0;
    v_je      jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_period_end IS NULL THEN
        RAISE EXCEPTION 'DATE_REQUIRED';
    END IF;

    v_preview := preview_revalue_foreign_balances(p_period_end);

    -- 缺当日中间价即拒(D2)。这里【故意再调一次 fx_rate_for】把它自己的异常抛出来,
    -- 免得错误文案在两处各写一遍又各自漂移 —— 与本次修的病同源。
    IF jsonb_array_length(v_preview->'missing_rates') > 0 THEN
        PERFORM fx_rate_for((v_preview->'missing_rates'->>0), p_period_end, 'mid');
    END IF;

    FOR v_r IN SELECT * FROM jsonb_array_elements(v_preview->'rows')
    LOOP
        v_adj := (v_r->>'adjustment')::numeric;
        IF v_adj IS NOT NULL AND v_adj <> 0 THEN
            v_lines := v_lines || jsonb_build_object(
                'account_code', v_r->>'account',
                'side', CASE WHEN v_adj > 0 THEN 'debit' ELSE 'credit' END,
                'currency', 'SGD', 'amount_ccy', abs(v_adj), 'fx_rate', 1,
                'line_memo', (v_r->>'currency') || ' @ ' || (v_r->>'rate'));
            v_total := v_total + v_adj;
            v_detail := v_detail || jsonb_build_object(
                'account', v_r->>'account', 'currency', v_r->>'currency',
                'native', (v_r->>'native')::numeric,
                'target_base', (v_r->>'target_base')::numeric,
                'adjustment', v_adj);
        END IF;
    END LOOP;

    IF v_total <> 0 THEN
        -- 净额对方科目:未实现汇兑损益(C5;已实现的走结算时点的 7100)
        v_lines := v_lines || jsonb_build_object(
            'account_code', '7110',
            'side', CASE WHEN v_total > 0 THEN 'credit' ELSE 'debit' END,
            'currency', 'SGD', 'amount_ccy', abs(v_total), 'fx_rate', 1);
    END IF;

    IF jsonb_array_length(v_lines) = 0 THEN
        RETURN jsonb_build_object('period_end', p_period_end, 'adjustments', 0,
                                  'detail', '[]'::jsonb, 'journal_code', NULL);
    END IF;

    v_je := post_journal_entry(p_period_end,
        format('FX revaluation as at %s', p_period_end), 'revaluation', NULL, v_lines);

    RETURN jsonb_build_object('period_end', p_period_end,
                              'adjustments', jsonb_array_length(v_detail),
                              'detail', v_detail, 'journal_code', v_je->>'code');
END;
$function$
;
