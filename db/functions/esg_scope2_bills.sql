-- db/functions/esg_scope2_bills.sql
-- ESG-2(Tim 2026-10-31 Q2 · Q3):每一张电费单的 Scope 2(按地点法)—— kWh × 那张单的年份的电网因子 ÷ 1000 = tCO2(EMA 的因子只含 CO2)。
--   【一张单的年份】= 账期结束那一天的年份(电费单是在账期结束时开的);那一年没有因子就用更早最近的一年(grid_emission_factor_for),
--     factor_year 照直交回,页面在它与 bill_year 不同时说「用的是 <年> 的因子」;一个都用不上 → factor_year / tco2 为空 =「没设因子」(Q1)。
--   【哪些单】与能耗强度页同一个判据:electricity_allocations_masked 里、不在 electricity_allocation_reversals_masked 里的(冲回的不算)。
--     kWh 那张视图不遮(它只遮金额)。【一份实现,两个读者】能耗强度页的那一列与 esg_scope2_monthly(月份按天摊的那一份)。
--   【门】与能耗强度页同一对码(module.finance.view 或 module.processing.view);都不持 → 按名拒(零行会把「受限」读成「没有电费单」)。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.esg_scope2_bills()
 RETURNS TABLE(allocation_id uuid, period_from date, period_to date, invoice_ref text, bill_kwh numeric, bill_year integer, factor_year integer, kg_co2_per_kwh numeric, tco2 numeric)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT has_any_permission(ARRAY['module.finance.view', 'module.processing.view']) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.view';
    END IF;
    RETURN QUERY
    SELECT a.id, a.period_from, a.period_to, a.invoice_ref, a.bill_kwh::numeric,
           EXTRACT(year FROM a.period_to)::integer,
           f.factor_year, f.kg_co2_per_kwh,
           CASE WHEN f.kg_co2_per_kwh IS NULL THEN NULL ELSE round(a.bill_kwh::numeric * f.kg_co2_per_kwh / 1000, 6) END
      FROM electricity_allocations_masked a
      LEFT JOIN LATERAL grid_emission_factor_for(EXTRACT(year FROM a.period_to)::integer) f ON true
     WHERE NOT EXISTS (SELECT 1 FROM electricity_allocation_reversals_masked r WHERE r.allocation_id = a.id)
     ORDER BY a.period_from DESC, a.id;
END;
$function$;
