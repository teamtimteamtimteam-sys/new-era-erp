-- db/views/processing_run_yield.sql
-- MES-5b-1(2026-10-08,MES-5b Step 0 Q13,Tim):【一炉的质量得率 —— 带门的外壳】。/operation/yield 的逐炉一段读它。
--   门与 processing_runs 的读规则同一个码(module.processing.view)。算术全在 processing_run_yield_all。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql.

CREATE VIEW public.processing_run_yield WITH (security_invoker = off) AS
 SELECT run_id,
    run_code,
    process_date,
    month,
    operation_type_code,
    equipment_id,
    era_mes4a,
    input_qty,
    line_kind,
    line_key,
    recoverable,
    qty,
    yield_pct,
    expected_yield_pct,
    below_expected
   FROM processing_run_yield_all
  WHERE has_permission('module.processing.view'::text);

COMMENT ON VIEW public.processing_run_yield IS
    'MES-5b-1:一炉的质量得率,带门(module.processing.view)。算术全在 processing_run_yield_all。';

GRANT SELECT ON public.processing_run_yield TO authenticated;
REVOKE ALL ON public.processing_run_yield FROM anon;
