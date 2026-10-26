-- db/functions/list_totals_electricity.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q2):/finance/electricity 分摊表的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】页面没有筛选,一次读全 electricity_allocations_masked(app/finance/electricity/page.tsx:46-48)。
-- 【三个合计】measure 'bill' = bill_amount(列键 amount)、'runs' = allocated_amount、'overhead' = overhead_amount;
--   按行上的 currency 分组(每个币种一行)。读【同一张遮蔽视图】—— 基表的金额列对 authenticated 收回了。
-- 【净额】(Q2)撤回的分摊只在 electricity_allocation_reversals 里多一行、原件金额照旧是正数 → 撤回过的【排除】(加 0)。
--   撤回读页面读的那张 electricity_allocation_reversals_masked(page.tsx:50)。
-- 【受限】遮蔽对一个读者是全有或全无(has_permission('data.view_prices'),视图体),三列在表里都 NOT NULL
--   —— 于是 restricted = NOT has_permission('data.view_prices'),与页面的 canViewPrices() 同一个判据;受限时 total 为 NULL。
-- 【门】require_permission('module.finance.view') —— 页面守卫 requireModule(MOD.finance)(electricity/page.tsx:32)。invoker。
CREATE OR REPLACE FUNCTION public.list_totals_electricity()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_hidden boolean;
BEGIN
    PERFORM require_permission('module.finance.view');
    v_hidden := NOT has_permission('data.view_prices');
    RETURN QUERY
    SELECT ''::text, x.ccy, x.m,
           CASE WHEN v_hidden THEN NULL::numeric ELSE round(sum(x.amt), 2) END,
           v_hidden
      FROM (SELECT a.currency::text AS ccy, m.m, m.amt
              FROM electricity_allocations_masked a
              CROSS JOIN LATERAL (VALUES (1, 'bill'::text, a.bill_amount),
                                         (2, 'runs'::text, a.allocated_amount),
                                         (3, 'overhead'::text, a.overhead_amount)) AS m(ord, m, amt)
             WHERE NOT EXISTS (SELECT 1 FROM electricity_allocation_reversals_masked r WHERE r.allocation_id = a.id)) x
     GROUP BY x.ccy, x.m
     ORDER BY x.ccy, min(CASE x.m WHEN 'bill' THEN 1 WHEN 'runs' THEN 2 ELSE 3 END);
END;
$function$;