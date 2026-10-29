-- db/functions/list_totals_settlements.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1):/contracts 上「已记录的结算」那张表的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/contracts/page.tsx:112-116 同一套:sales_settlements,superseded_by IS NULL(没有地址栏筛选)。
-- 【合计】amount(amount_usd)。currency 给 NULL:这一列固定是美元,列头(contracts.settlement.colAmount)写着 USD。
-- 【净额】被改记的结算由 superseded_by 指向新的那一条,旧的不在集合里 —— 每一笔结算只算它当前的那一次。
-- 【门】require_permission('module.suppliers.view') —— 与页面守卫(requireModule(MOD.suppliers))同一个码。invoker。
-- 【受限】整个读者:NOT has_permission('module.customers.view')。页面的门是 suppliers.view,而这张表的读策略要
--   customers.view(sales_settlements.sql:90-92)—— 不持它的读者读到【零行】,而那不是「没有结算」。
--   所以那时回一行 restricted(currency NULL,total NULL),不回零行。
-- ★ GOLIVE-1 第 12 行(Tim Q9):结算金额从此按 data.view_prices 遮 —— amount_usd 不在 authenticated 的列级 SELECT 里,
--   这里改读 sales_settlements_masked;不持 data.view_prices 的读者同样回一行 restricted(屏幕上那一列是「受限」,表尾不许是一个数)。
CREATE OR REPLACE FUNCTION public.list_totals_settlements()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.suppliers.view');
    IF NOT has_permission('module.customers.view') OR NOT has_permission('data.view_prices') THEN
        RETURN QUERY SELECT ''::text, NULL::text, 'amount'::text, NULL::numeric, true;
        RETURN;
    END IF;
    RETURN QUERY
    SELECT ''::text, NULL::text, 'amount'::text, round(sum(ss.amount_usd), 2), false
      FROM sales_settlements_masked ss
     WHERE ss.superseded_by IS NULL
    HAVING count(*) > 0;
END;
$function$;