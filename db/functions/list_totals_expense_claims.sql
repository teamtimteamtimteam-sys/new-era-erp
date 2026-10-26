-- db/functions/list_totals_expense_claims.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1):/finance/claims 已决登记簿的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】页面一次读全 expense_claim_status(app/finance/claims/page.tsx:47-52),再在 JS 里只留 status <> 'submitted'
--   (page.tsx:100-101,待批的那一半是卡片)—— 这里在 SQL 里做同一件事。行谓词就是视图自己的那一句
--   (has_permission('module.finance.view') OR employee_id = current_user_employee(),expense_claim_status.sql),
--   本函数是 invoker、读同一张视图,所以读者拿到的行与页面同一份。
-- 【合计】amount_ccy(员工报的含税总额,NOT NULL > 0)按行上的 currency,每个币种一行。
-- 【净额】报销单本身没有冲销行;"批准被撤销"走冲销那笔费用(expense_reversed),单子仍是 approved、行上照旧是原额
--   —— 与页面那一格同一个数,不另扣。
-- 【门】require_permission('module.finance.view') —— 页面守卫 requireModule(MOD.finance)(claims/page.tsx:35)。
--   没有金额被遮(data.view_prices 只管决定表单),restricted 恒为 false。
CREATE OR REPLACE FUNCTION public.list_totals_expense_claims()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN QUERY
    SELECT ''::text, s.currency::text, 'amount'::text, round(sum(s.amount_ccy), 2), false
      FROM expense_claim_status s
     WHERE s.status <> 'submitted'
     GROUP BY s.currency
     ORDER BY s.currency;
END;
$function$;