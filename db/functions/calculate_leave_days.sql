-- db/functions/calculate_leave_days.sql
-- 工作日计算:周一至周五扣公共假期,半天各减 0.5。【不建模轮班】。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.
--
-- FIN-13(2026-08-05):汇率可以就近取上一个【发布日】,但有界、有留痕。
-- 中间跨过的每一天都必须是非发布日(周末 / SG 生效假日),夹着工作日即拒绝;
-- 另有 4 个自然日的硬上限。fx_rate_asof 同时返回【实际取自哪一天】。
-- 理由与 4 天的由来见 db/migrations/2026-08-05-fin13-rate-asof-and-business-days.sql。

CREATE OR REPLACE FUNCTION public.calculate_leave_days(p_start date, p_end date, p_start_half boolean DEFAULT false, p_end_half boolean DEFAULT false)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT GREATEST(
        (SELECT count(*)
         FROM generate_series(p_start, p_end, interval '1 day') d
         WHERE is_business_day(d::date))::numeric
        - CASE WHEN p_start_half THEN 0.5 ELSE 0 END
        - CASE WHEN p_end_half THEN 0.5 ELSE 0 END,
        0);
$function$;
