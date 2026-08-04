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

CREATE OR REPLACE FUNCTION public.preview_revalue_foreign_balances(p_period_end date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_row     record;
    v_rate    numeric;
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

        BEGIN
            v_rate := fx_rate_for(v_row.currency, p_period_end, 'mid');
        EXCEPTION WHEN OTHERS THEN
            v_rate := NULL;
            IF NOT (v_missing @> to_jsonb(v_row.currency)) THEN
                v_missing := v_missing || to_jsonb(v_row.currency);
            END IF;
        END;

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
            'rate', v_rate, 'target_base', v_target, 'adjustment', v_adj);
    END LOOP;

    RETURN jsonb_build_object(
        'period_end', p_period_end,
        'rows', v_rows,
        'total_adjustment', v_total,
        'missing_rates', v_missing);
END;
$function$
;
