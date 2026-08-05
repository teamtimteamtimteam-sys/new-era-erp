-- FIN-13(2026-08-05):汇率可以就近取上一个【发布日】,但有界、有留痕。
-- 中间跨过的每一天都必须是非发布日(周末 / SG 生效假日),夹着工作日即拒绝;
-- 另有 4 个自然日的硬上限。fx_rate_asof 同时返回【实际取自哪一天】。
-- 理由与 4 天的由来见 db/migrations/2026-08-05-fin13-rate-asof-and-business-days.sql。

CREATE OR REPLACE FUNCTION public.is_business_day(p_date date, p_country text DEFAULT 'SG'::text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT p_date IS NOT NULL
       AND EXTRACT(ISODOW FROM p_date) < 6
       AND NOT EXISTS (
           SELECT 1 FROM public_holidays h
           WHERE h.holiday_date = p_date AND h.country = p_country AND h.is_active);
$function$;
