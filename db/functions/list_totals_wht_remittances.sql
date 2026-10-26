-- db/functions/list_totals_wht_remittances.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q2):/finance/wht 那张【汇款登记】表的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】页面没有筛选,一次读全 wht_remittances(app/finance/wht/page.tsx:51-53)。
-- 【合计】amount_base,本位币:currency 给 (SELECT code FROM currencies WHERE is_base)。
-- 【净额】(Q2)冲销一笔汇款只把它的分录翻成 reversed,登记簿上那一行照旧是正数 → 冲销过的【排除】(加 0)。
--   判据与页面逐字同一条:分录 status 不是 'posted' 就算已冲销(page.tsx:127 `entryStatus.get(...) !== 'posted'`),
--   也与 wht_liability_by_month 的 remitted 那一半同一条 —— 于是本合计 ≡ 上面那张表的 remitted 合计。
-- 【门】require_permission('module.finance.view') —— 页面守卫 requireModule(MOD.finance)(wht/page.tsx:36),
--   与 wht_remittances 的 SELECT 策略(wht_remittances.sql:67-70)同一个码。invoker;没有金额被遮,restricted 恒为 false。
CREATE OR REPLACE FUNCTION public.list_totals_wht_remittances()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN QUERY
    SELECT ''::text, (SELECT c.code FROM currencies c WHERE c.is_base)::text, 'amount'::text, round(sum(r.amount_base), 2), false
      FROM wht_remittances r
     WHERE EXISTS (SELECT 1 FROM journal_entries e WHERE e.id = r.journal_entry_id AND e.status = 'posted')
    HAVING count(*) > 0;
END;
$function$;