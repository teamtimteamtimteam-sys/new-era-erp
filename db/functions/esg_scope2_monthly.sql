-- db/functions/esg_scope2_monthly.sql
-- ESG-2(Tim 2026-10-31 Q3):某一年每个日历月的 kWh 与 Scope 2 —— 【按天摊】(apportioned by days):一张单的 kWh 与 tCO2 按它的账期里
--   落在那个月的天数 ÷ 账期总天数 分到那个月(SP 的账期按抄表日,不是整月)。每张单的 tCO2 先按它自己那一年的因子算好再摊
--   (esg_scope2_bills,一份实现),所以各月之和 = 各单之和,不会因为摊而多出或少掉一点。
--   一个月里有任何一张单没设因子 → 那个月的 tco2 为空、factor_missing 为真(不把一部分当成全部);bills = 有几张单落进这个月。
--   一个月没有任何单 → kwh 0、bills 0:页面说「没有电费单覆盖这个月」,不说「0 tCO2」。门与 esg_scope2_bills 相同,这里先判一次(不靠被读的那一支恰好被求值)。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.esg_scope2_monthly(p_year integer)
 RETURNS TABLE(month date, kwh numeric, tco2 numeric, factor_missing boolean, bills integer)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
BEGIN
    IF NOT has_any_permission(ARRAY['module.finance.view', 'module.processing.view']) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.view';
    END IF;
    RETURN QUERY
    WITH b AS (
        SELECT s.allocation_id, s.period_from, s.period_to, s.bill_kwh, s.tco2,
               (s.period_to - s.period_from + 1)::numeric AS days
          FROM esg_scope2_bills() s
         WHERE s.period_from <= make_date(p_year, 12, 31) AND s.period_to >= make_date(p_year, 1, 1)
    ), m AS (
        SELECT make_date(p_year, k, 1) AS m_from, (make_date(p_year, k, 1) + interval '1 month - 1 day')::date AS m_to
          FROM generate_series(1, 12) k
    ), share AS (
        SELECT m.m_from, b.allocation_id, b.tco2 IS NULL AS missing,
               (LEAST(b.period_to, m.m_to) - GREATEST(b.period_from, m.m_from) + 1)::numeric / b.days AS frac,
               b.bill_kwh, b.tco2
          FROM m JOIN b ON b.period_from <= m.m_to AND b.period_to >= m.m_from
    )
    SELECT m.m_from,
           COALESCE(round(sum(s.bill_kwh * s.frac), 3), 0),
           CASE WHEN bool_or(s.missing) THEN NULL ELSE COALESCE(round(sum(s.tco2 * s.frac), 6), 0) END,
           COALESCE(bool_or(s.missing), false),
           count(s.allocation_id)::integer
      FROM m LEFT JOIN share s ON s.m_from = m.m_from
     GROUP BY m.m_from
     ORDER BY m.m_from;
END;
$function$;
