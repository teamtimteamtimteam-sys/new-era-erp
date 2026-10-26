-- db/functions/list_totals_wht_liability.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1):/finance/wht 那张【按月欠税】表的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】页面没有筛选,一次读全 wht_liability_by_month(app/finance/wht/page.tsx:48-50)。本函数读同一张视图
--   (属主权限、行谓词 has_permission('module.finance.view'))—— 不另起一份对总账与 wht_remittances 的算术。
-- 【三个合计】measure 'withheld' = withheld_base、'remitted' = remitted_base、'unremitted' = unremitted_base,
--   全是本位币:currency 给 (SELECT code FROM currencies WHERE is_base)。
--   Σ unremitted ≡ 2150 的科目余额(视图抬头那条不变量),所以它不是一个余额列的合计,是那个余额本身。
-- 【净额】(Q2)已在视图里:冲销的汇款整笔掉出 remitted(e.status = 'posted'),它的冲销分录带同一个 source_type、
--   也不进 withheld —— 一对冲销加起来是 0。
-- 【门】require_permission('module.finance.view') —— 页面守卫 requireModule(MOD.finance)(wht/page.tsx:36),与视图谓词同一个码。
--   invoker;没有金额被遮,restricted 恒为 false。
CREATE OR REPLACE FUNCTION public.list_totals_wht_liability()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base text := (SELECT c.code FROM currencies c WHERE c.is_base);
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN QUERY
    SELECT ''::text, v_base, m.m, round(sum(m.amt), 2), false
      FROM wht_liability_by_month w
      CROSS JOIN LATERAL (VALUES (1, 'withheld'::text, w.withheld_base),
                                 (2, 'remitted'::text, w.remitted_base),
                                 (3, 'unremitted'::text, w.unremitted_base)) AS m(ord, m, amt)
     GROUP BY m.ord, m.m
     ORDER BY m.ord;
END;
$function$;