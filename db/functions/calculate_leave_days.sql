-- db/functions/calculate_leave_days.sql
-- 工作日计算:周一至周五扣公共假期,半天各减 0.5。【不建模轮班】。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.

CREATE OR REPLACE FUNCTION public.calculate_leave_days(p_start date, p_end date, p_start_half boolean DEFAULT false, p_end_half boolean DEFAULT false)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT GREATEST(
        (SELECT count(*)
         FROM generate_series(p_start, p_end, interval '1 day') d
         WHERE EXTRACT(ISODOW FROM d) < 6
           AND NOT EXISTS (
               SELECT 1 FROM public_holidays h
               WHERE h.holiday_date = d::date AND h.country = 'SG' AND h.is_active))::numeric
        - CASE WHEN p_start_half THEN 0.5 ELSE 0 END
        - CASE WHEN p_end_half THEN 0.5 ELSE 0 END,
        0);
$function$;
