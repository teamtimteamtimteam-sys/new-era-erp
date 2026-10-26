-- db/functions/list_totals_commissions.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q3):/sales/commissions 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/sales/commissions/page.tsx:47-53 同一套:commission_agreements,deleted_at IS NULL(没有地址栏筛选)。
-- 【只加定额】(Q3)只有 basis = 'fixed_amount' 的行进合计:percentage_of_value 是费率(没有金额),per_tonne 是每吨的价 ——
--   加起来是把单价相加。每个币种一行,measure amount(amount_ccy)→ 表的「费率」列。
-- 【净额】协议没有冲销镜像行;软删的不算(与列表同)。
-- 【门】require_permission('module.suppliers.view') —— 与页面守卫(requireModule(MOD.suppliers))、与表的读策略同一个码。invoker。
-- 【受限】这一列不遮;照实算 bool_or(amount_ccy IS NULL) —— fixed_amount 行的 amount_ccy 由 CHECK 保证非空
--   (commission_agreements.sql:62-67),所以这里的 NULL 只可能是看不见。
CREATE OR REPLACE FUNCTION public.list_totals_commissions()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.suppliers.view');
    RETURN QUERY
    SELECT ''::text, ca.currency::text, 'amount'::text,
           CASE WHEN bool_or(ca.amount_ccy IS NULL) THEN NULL::numeric ELSE round(sum(ca.amount_ccy), 2) END,
           bool_or(ca.amount_ccy IS NULL)
      FROM commission_agreements ca
     WHERE ca.deleted_at IS NULL
       AND ca.basis = 'fixed_amount'
     GROUP BY ca.currency
     ORDER BY 2;
END;
$function$;