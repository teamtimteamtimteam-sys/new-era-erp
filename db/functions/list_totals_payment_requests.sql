-- db/functions/list_totals_payment_requests.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1):/finance/payment-requests 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/finance/payment-requests/requestRows.ts 的 statusSet / applyFilters(:27-29、:45-50)逐项同一套:
--   p_status 'open' = status IN ('submitted','approved');'all' 或 NULL = 不筛;其余 = 那一个状态。
--   页面总是把 parseRequestFilter 解析过的那一个值传进来(默认 'open')。
-- 【合计】amount_ccy 按行上的 currency,每个币种一行;六种 kind 一并计入(列表上的每一行都算,与列表同一个集合)。
-- 【净额】付款申请是一张【申请】,不是一笔过账:冲销申请(payment_reversal 等)是它自己的一行、金额为正,
--   原申请不因此翻状态 —— 没有"镜像行"也没有"被冲销"的标记,所以照行上的数加总。
-- 【门】require_permission('module.finance.view') —— 页面守卫 requireModule(MOD.finance)(payment-requests/page.tsx:33),
--   与 payment_requests 的 SELECT 策略(payment_requests.sql:190-192)同一个码。invoker;没有金额被遮,restricted 恒为 false。
CREATE OR REPLACE FUNCTION public.list_totals_payment_requests(p_status text DEFAULT NULL::text)
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN QUERY
    SELECT ''::text, r.currency::text, 'amount'::text, round(sum(r.amount_ccy), 2), false
      FROM payment_requests r
     WHERE CASE WHEN p_status IS NULL OR p_status = 'all' THEN true
                WHEN p_status = 'open' THEN r.status IN ('submitted', 'approved')
                ELSE r.status = p_status END
     GROUP BY r.currency
     ORDER BY r.currency;
END;
$function$;