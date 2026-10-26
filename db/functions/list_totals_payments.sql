-- db/functions/list_totals_payments.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q2 · Q4):/finance/payments 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/finance/payments/paymentRows.ts 的 applyFilters 逐项同一套:payment_date ≥ from、≤ to、direction = 方向。
-- 【两个合计,不轧差】(Q4)grp 'received' = direction 'in','paid' = 'out';每个币种各一行。
-- 【净额】(Q2)冲销在本表里是一条【同方向、同为正数】的镜像行(reverse_payment_internal.sql:56-63),原件翻成 reversed。
--   镜像行由原件的 reversed_by_payment 指着;它在这里记【负数】,于是一对冲销加起来是 0,而按日期切开时两半各落在
--   各自的日子上 —— 与总账上原分录与冲销分录各自的日期一致。
-- 【门】require_permission('module.finance.view') —— 与页面守卫(requireModule(MOD.finance))、与 payments 的 SELECT 策略同一个码。
--   本函数是 invoker:读的就是读者自己读得到的那些行,与列表同一份。没有任何金额被遮,所以 restricted 恒为 false。
CREATE OR REPLACE FUNCTION public.list_totals_payments(p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_direction text DEFAULT NULL::text)
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN QUERY
    SELECT CASE WHEN p.direction = 'in' THEN 'received' ELSE 'paid' END,
           p.currency::text,
           'amount'::text,
           round(sum(CASE WHEN EXISTS (SELECT 1 FROM payments o WHERE o.reversed_by_payment = p.id)
                          THEN -p.amount_ccy ELSE p.amount_ccy END), 2),
           false
      FROM payments p
     WHERE (p_date_from IS NULL OR p.payment_date >= p_date_from)
       AND (p_date_to IS NULL OR p.payment_date <= p_date_to)
       AND (p_direction IS NULL OR p.direction = p_direction)
     GROUP BY 1, 2
     ORDER BY 1 DESC, 2;
END;
$function$;