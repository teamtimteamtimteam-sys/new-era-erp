-- db/functions/business_days_after.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q10,Tim):【某一天之后的第 n 个工作日】—— 从 p_date 的【下一天】数起,只数工作日
--   (is_business_day:周一到周五、不是新加坡的启用的公共假期 —— 汇率回溯与假期计算用的同一个定义),数到第 n 个,返回那一天。
--   n = 2、事故在星期五:星期一是第 1 个,星期二是第 2 个 → 星期二。
--   ★ 算不出来就返回 NULL,不猜一个日子:
--     · p_date 或 p_n 为空、或 p_n < 1;
--     · 数的过程中碰到的任何一天,它那一年在 public_holidays 里【一行启用的新加坡假期都没有】—— 那一年的日历缺了,
--       "这一天是不是工作日"答不出来(hr_alerts 的 holiday_calendar_missing 用的是同一条判据)。屏幕上说"算不出来"。
--   STABLE,不读调用者是谁:谁都可以调(它只读公共假期表,而那张表对每一个登录的人可读)。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
CREATE OR REPLACE FUNCTION public.business_days_after(p_date date, p_n integer)
 RETURNS date
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_day     date := p_date;
    v_counted integer := 0;
    v_steps   integer := 0;
    v_year    integer := NULL;
BEGIN
    IF p_date IS NULL OR p_n IS NULL OR p_n < 1 THEN
        RETURN NULL;
    END IF;
    WHILE v_counted < p_n LOOP
        v_day := v_day + 1;
        v_steps := v_steps + 1;
        -- 有界:一年最多 366 天,任何 n 都不会让这个循环数过十年 —— 真到那一步,是日历本身出了问题
        IF v_steps > 3660 THEN
            RETURN NULL;
        END IF;
        IF v_year IS DISTINCT FROM EXTRACT(YEAR FROM v_day)::integer THEN
            v_year := EXTRACT(YEAR FROM v_day)::integer;
            IF NOT EXISTS (SELECT 1 FROM public_holidays h
                            WHERE h.is_active AND h.country = 'SG' AND EXTRACT(YEAR FROM h.holiday_date)::integer = v_year) THEN
                RETURN NULL;
            END IF;
        END IF;
        IF is_business_day(v_day) THEN
            v_counted := v_counted + 1;
        END IF;
    END LOOP;
    RETURN v_day;
END;
$function$;
