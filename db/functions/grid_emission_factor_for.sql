-- db/functions/grid_emission_factor_for.sql
-- ESG-2(Tim 2026-10-31 Q2 (a)):某一年【用哪一个】电网排放因子 —— 那一年有就用那一年的,没有就用【更早最近的一年】;
--   一年里取最后一个版本(id 最大 —— identity 记录先后)。比所有已填年份都早 → 零行(「没设因子」,从不读成 0)。
--   回 factor_year(真正用的那一年,与 p_year 不同时页面照直说)与值。读的是一张人人可读的表,不必另判。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.grid_emission_factor_for(p_year integer)
 RETURNS TABLE(factor_year integer, kg_co2_per_kwh numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT g.factor_year, g.kg_co2_per_kwh
      FROM grid_emission_factors g
     WHERE g.factor_year <= p_year
     ORDER BY g.factor_year DESC, g.id DESC
     LIMIT 1;
$function$;
