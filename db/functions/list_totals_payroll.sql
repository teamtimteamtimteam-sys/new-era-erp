-- db/functions/list_totals_payroll.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1):/hr/payroll 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/hr/payroll/page.tsx:33-37 同一套:payroll_periods_masked,deleted_at IS NULL(没有地址栏筛选)。
-- 【合计】应发合计 gross(gross_total)与实发合计 net(net_pay_total),每个币种(期间自己的 currency)一行。
-- 【净额】工资期间没有冲销镜像行(状态只有 draft / posted,payroll_periods.sql:24),一期一行 —— 照加。
-- 【门】require_permission('module.hr.view') —— 与页面守卫(requireModule(MOD.hr))、与视图的行谓词同一个码。invoker。
-- 【受限】整个读者:NOT has_permission('data.view_pay') —— 与 payroll_periods_masked.sql:15-34 的 CASE 同一个码。
--   受限而一行都没有时,仍每个 measure 回一行(currency NULL,total NULL,restricted true)。
CREATE OR REPLACE FUNCTION public.list_totals_payroll()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_hidden boolean;
BEGIN
    PERFORM require_permission('module.hr.view');
    v_hidden := NOT has_permission('data.view_pay');
    RETURN QUERY
    WITH s AS (
        SELECT p.currency::text AS ccy, sum(p.gross_total) AS gross, sum(p.net_pay_total) AS net
          FROM payroll_periods_masked p
         WHERE p.deleted_at IS NULL
         GROUP BY p.currency
    )
    SELECT ''::text, s.ccy, m.k, CASE WHEN v_hidden THEN NULL::numeric ELSE round(m.v, 2) END, v_hidden
      FROM s CROSS JOIN LATERAL (VALUES ('gross'::text, s.gross), ('net'::text, s.net)) m(k, v)
    UNION ALL
    SELECT ''::text, NULL::text, m.k, NULL::numeric, true
      FROM (VALUES ('gross'::text), ('net'::text)) m(k)
     WHERE v_hidden AND NOT EXISTS (SELECT 1 FROM s)
     ORDER BY 2, 3;
END;
$function$;