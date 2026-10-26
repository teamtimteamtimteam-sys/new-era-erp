-- db/functions/list_totals_expenses.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1–Q3):/finance/expenses 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/finance/expenses/expenseRows.ts 的 applyExpenseFilters 逐项同一套:expense_date ≥ from、≤ to、payment_status = 状态;
--   科目筛选(resolveExpenseFilter,原先在 JS 里解出一组 id)在这里是 EXISTS(任何一行记在这个科目上)。
-- 【量】每个单据币种一行(amount_ccy)。筛着科目时只加【那个科目的行】的 amount_ccy(一张三行单只有一行是差旅),
--   按表头币种分组 —— 与 page.tsx 原先「只加这个科目的行」同一个意思,只是改成按币种、由库算。
-- 【净额】(Q2)冲销在本表是一张同为正数的镜像单(reverse_expense_internal.sql:143-159),原单翻成 reversed 并以
--   reversed_by_expense 指着它;镜像单(及它的行)在这里记【负数】,一对冲销加起来是 0。
-- 【门】require_permission('module.finance.view') —— 与页面守卫 requireModule(MOD.finance)、与 expenses / expense_lines 的
--   SELECT 策略同一个码。invoker;没有任何金额被遮,restricted 恒为 false。
CREATE OR REPLACE FUNCTION public.list_totals_expenses(p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_payment_status text DEFAULT NULL::text, p_account text DEFAULT NULL::text)
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN QUERY
    SELECT ''::text,
           e.currency::text,
           'amount'::text,
           round(sum(CASE WHEN EXISTS (SELECT 1 FROM expenses o WHERE o.reversed_by_expense = e.id) THEN -1 ELSE 1 END
                     * CASE WHEN p_account IS NULL THEN e.amount_ccy
                            ELSE (SELECT sum(l.amount_ccy) FROM expense_lines l
                                   WHERE l.expense_id = e.id AND l.account_code = p_account) END), 2),
           false
      FROM expenses e
     WHERE (p_date_from IS NULL OR e.expense_date >= p_date_from)
       AND (p_date_to IS NULL OR e.expense_date <= p_date_to)
       AND (p_payment_status IS NULL OR e.payment_status = p_payment_status)
       AND (p_account IS NULL OR EXISTS (SELECT 1 FROM expense_lines l
                                          WHERE l.expense_id = e.id AND l.account_code = p_account))
     GROUP BY 2
     ORDER BY 2;
END;
$function$;