-- db/functions/preview_revalue_foreign_balances.sql
-- 期末重估的【只读预览】—— 与 revalue_foreign_balances 共用同一份算术:
-- 过账函数调用本函数,再据返回的逐行明细发分录。界面只负责画,不负责算。
--
-- 【为什么必须只有一份】/finance/revaluation 原先用 TypeScript 又算了一遍,两份
-- 实现已经漂开(既往重估行并入承载额的口径不同),而屏幕上的数字会被人当作
-- 过账将要发生什么的承诺。同病此前两次:验配影响预览、GrantRunner 假期公式。
-- 先例:preview_reprice_inbound_batch 与 reprice_inbound_batch 共用 reprice_split。
--
-- 缺当日中间价【不抛】,该行 rate/adjustment 返回 null 并记进 missing_rates ——
-- 页面要能把缺牌价画出来。过账那一侧仍然拒绝(D2 语义不变)。
--
-- NOTE: introduced by db/migrations/2026-08-05-fin9-revaluation-single-implementation.sql.
-- FIN-19b(2026-08-06):多返回 rate_as_of ——【中间价取自哪一天】。期末常落在周末,
-- 用周五的中间价是对的,但必须说出来(FIN-13 接受回溯的条件)。改问 fx_rate_asof
-- (缺牌价返回空行,不抛),写入侧仍再调一次 fx_rate_for 抛 FX_RATE_MISSING。

CREATE OR REPLACE FUNCTION public.preview_revalue_foreign_balances(p_period_end date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base    text;   -- OPS-8:本位币从 currencies.is_base 读
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
    -- OPS-8:本位币是【数据】(currencies.is_base),不是字面量。
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;
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
          AND a.is_monetary AND l.currency <> v_base
        GROUP BY a.code, l.currency
        ORDER BY a.code, l.currency
    LOOP
        -- 既往重估调整行(本币行,挂在 revaluation 分录上)也算进承载额
        SELECT v_row.carry_fx + COALESCE(round(sum(l2.debit - l2.credit), 2), 0)
        INTO v_carry
        FROM journal_lines l2
        JOIN accounts a2 ON a2.id = l2.account_id
        JOIN journal_entries e2 ON e2.id = l2.entry_id
        WHERE a2.code = v_row.code AND l2.currency = v_base
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
$function$;