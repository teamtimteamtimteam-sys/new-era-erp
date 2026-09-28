-- db/functions/overtime_day_kind.sql
-- OVERTIME-1(Tim Q4,2026-09-28):一天加班落进哪一个桶。
--   public_holidays 里有这一天(新加坡、启用中)→ public_holiday;
--   星期日 → rest_day(对所有人 —— 按人的休息日推后,见 docs/known-issues.md C-2-OT);
--   其余 → weekday。
-- 【公共假期先判】一个落在星期日的公共假期算 public_holiday。
-- 【不是 SECURITY DEFINER】它只读 public_holidays(任何登录用户都读得到),与 is_business_day 同形。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.overtime_day_kind(p_date date)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE
        WHEN p_date IS NULL THEN NULL
        WHEN EXISTS (SELECT 1 FROM public_holidays h
                      WHERE h.holiday_date = p_date AND h.country = 'SG' AND h.is_active)
            THEN 'public_holiday'
        WHEN EXTRACT(ISODOW FROM p_date) = 7 THEN 'rest_day'
        ELSE 'weekday'
    END;
$function$;

COMMENT ON FUNCTION public.overtime_day_kind(date) IS
'OVERTIME-1(Tim Q4):一天加班落进哪一个桶 —— 公共假期(public_holidays,SG,启用中)→ public_holiday;星期日 → rest_day(对所有人);其余 → weekday。公共假期先判。';
