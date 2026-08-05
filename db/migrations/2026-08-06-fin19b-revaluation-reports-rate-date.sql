-- db/migrations/2026-08-06-fin19b-revaluation-reports-rate-date.sql
--
-- FIN-19b:重估预览把【中间价取自哪一天】一并报出来。
--
-- 与 FIN-19 同源。回溯之所以被接受,条件是"取自哪一天要说出来"(FIN-13 第 5 条),
-- 而这条路径一直只把 rate 带回去。期末落在周末的机会大约是 2/7 —— 月末用周五的
-- 中间价是对的,但操作员是照着这张表按下过账按钮的,他有权知道自己在看哪一天。
--
-- 顺带把 fx_rate_for + EXCEPTION 的写法换成直接问 fx_rate_asof:缺牌价时它返回
-- 空行而不是抛异常,拿 as_of 也只有它给得出。写入侧 revalue_foreign_balances
-- 仍旧【故意再调一次 fx_rate_for】把 FX_RATE_MISSING 抛出来 —— 那一段不动,
-- 错误文案仍然只有一处。算术一个字没改,只是多返回一个字段。

BEGIN;

CREATE OR REPLACE FUNCTION public.preview_revalue_foreign_balances(p_period_end date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_row     record;
    v_rate    numeric;
    v_rate_asof date;   -- FIN-19:这个牌价【取自哪一天】
    v_target  numeric;
    v_adj     numeric;
    v_carry   numeric;
    v_rows    jsonb := '[]'::jsonb;
    v_missing jsonb := '[]'::jsonb;
    v_total   numeric := 0;
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_period_end IS NULL THEN
        RAISE EXCEPTION 'DATE_REQUIRED';
    END IF;

    FOR v_row IN
        SELECT a.code, l.currency,
               round(sum(CASE WHEN l.debit > 0 THEN l.amount_ccy ELSE -l.amount_ccy END), 2) AS native,
               round(sum(l.debit - l.credit), 2) AS carry_fx
        FROM journal_lines l
        JOIN accounts a ON a.id = l.account_id
        JOIN journal_entries e ON e.id = l.entry_id
        WHERE e.status = 'posted' AND e.entry_date <= p_period_end
          AND a.is_monetary AND l.currency <> 'SGD'
        GROUP BY a.code, l.currency
        ORDER BY a.code, l.currency
    LOOP
        -- 既往重估调整行(本币行,挂在 revaluation 分录上)也算进承载额
        SELECT v_row.carry_fx + COALESCE(round(sum(l2.debit - l2.credit), 2), 0)
        INTO v_carry
        FROM journal_lines l2
        JOIN accounts a2 ON a2.id = l2.account_id
        JOIN journal_entries e2 ON e2.id = l2.entry_id
        WHERE a2.code = v_row.code AND l2.currency = 'SGD'
          AND e2.source_type = 'revaluation' AND e2.status = 'posted'
          AND e2.entry_date <= p_period_end;

        -- FIN-19:问 fx_rate_asof 而不是 fx_rate_for —— 要的是【牌价取自哪一天】。
        -- 期末常常落在周末(月末约 2/7 的机会),那时用周五的中间价是对的,
        -- 但屏幕上必须说出来:回溯当初就是以"说得出取自哪天"为条件被接受的。
        -- 缺牌价时 fx_rate_asof 返回空行(不抛),所以这里不再需要 EXCEPTION 兜。
        v_rate := NULL; v_rate_asof := NULL;
        SELECT x.rate, x.as_of INTO v_rate, v_rate_asof
        FROM fx_rate_asof(v_row.currency, p_period_end, 'mid') x;
        IF v_rate IS NULL AND NOT (v_missing @> to_jsonb(v_row.currency)) THEN
            v_missing := v_missing || to_jsonb(v_row.currency);
        END IF;

        IF v_rate IS NULL THEN
            v_target := NULL; v_adj := NULL;
        ELSE
            v_target := round(v_row.native * v_rate, 2);
            v_adj    := round(v_target - v_carry, 2);
            v_total  := v_total + v_adj;
        END IF;

        v_rows := v_rows || jsonb_build_object(
            'account', v_row.code, 'currency', v_row.currency,
            'native', v_row.native, 'carry_base', v_carry,
            'rate', v_rate, 'rate_as_of', v_rate_asof,
            'target_base', v_target, 'adjustment', v_adj);
    END LOOP;

    RETURN jsonb_build_object(
        'period_end', p_period_end,
        'rows', v_rows,
        'total_adjustment', v_total,
        'missing_rates', v_missing);
END;
$function$
;

COMMIT;
