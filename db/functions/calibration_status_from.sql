-- db/functions/calibration_status_from.sql
-- MES-2(2026-10-06,MES-0 Q30 · Q31;MES-2 Step 0 Q25,Tim):【在不在校准期内】的那一句判据 —— 唯一一份。
--   入参是【已经挑出来的那一行校准记录】(没作废、calibrated_on ≤ 那一天的最近一行)的结论与有效期,以及那一天:
--     没有记录(p_result 为空)→ never_calibrated(也算不在期内,Q25)
--     没通过                  → failed
--     通过、那一天 ≤ 有效期    → in_calibration
--     通过、那一天已过有效期   → expired
--   纯函数(IMMUTABLE,不读任何表),所以在属主视图里调它不会撞上读者的 RLS:挑那一行的是视图自己(属主身份),
--   这里只做判断。读它的:weighing_calibration_all(每一次称重在它那一刻)· instrument_calibration_now(每一台仪器在今天)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.calibration_status_from(p_result text, p_valid_until date, p_on date)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE
               WHEN p_result IS NULL THEN 'never_calibrated'
               WHEN p_result = 'failed' THEN 'failed'
               WHEN p_on <= p_valid_until THEN 'in_calibration'
               ELSE 'expired'
           END;
$function$;
