-- db/views/electricity_allocation_lines_masked.sql
-- MES-5a-2(2026-10-08,MES-5a Step 0 Q30,Tim):遮蔽伴生视图 —— electricity_allocation_lines 的每一列都在,amount → data.view_prices。
--   kWh、依据、份额不遮。属主权限,表的读策略原样写回视图体。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a2-energy.sql.

CREATE VIEW public.electricity_allocation_lines_masked WITH (security_invoker = off) AS
 SELECT id,
    allocation_id,
    run_id,
    equipment_id,
    basis,
    run_energy_kwh,
    run_minutes,
    weight,
    share,
    machine_kwh,
    kwh,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN amount
            ELSE NULL::numeric
        END AS amount,
    cost_entry_id,
    created_at
   FROM electricity_allocation_lines
  WHERE has_any_permission(ARRAY['module.finance.view'::text, 'module.processing.view'::text]);

GRANT SELECT ON public.electricity_allocation_lines_masked TO authenticated;
REVOKE ALL ON public.electricity_allocation_lines_masked FROM anon;
