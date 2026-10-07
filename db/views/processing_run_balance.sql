-- db/views/processing_run_balance.sql
-- MES-4a(2026-10-07,MES-4a Step 0 Q19 · Q22,Tim):【一炉的物料平衡 —— 带门的外壳】。加工单页的平衡面板、加工单清单的那一栏读它。
--   门与 processing_runs 的读规则同一个码(module.processing.view);算术在 processing_run_balance_all,这里一个字都不重算。
--   属主权限:基视图从 authenticated 收回了;视图读视图走属主替换(AGENTS.md「属主视图替得了表」)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE VIEW public.processing_run_balance WITH (security_invoker = off) AS
 SELECT run_id,
    run_code,
    process_date,
    status,
    operation_type_code,
    produces_outputs,
    started_at,
    input_qty,
    output_qty,
    loss_qty,
    named_loss_qty,
    remainder_qty,
    tolerance_pct,
    within_tolerance,
    outputs_total,
    outputs_unweighed,
    required_missing,
    last_closure_id,
    last_closed_at,
    closure_current,
    balance_state
   FROM processing_run_balance_all
  WHERE has_permission('module.processing.view'::text);

COMMENT ON VIEW public.processing_run_balance IS
    'MES-4a:一炉的物料平衡,带门(module.processing.view)。算术全在 processing_run_balance_all。';

GRANT SELECT ON public.processing_run_balance TO authenticated;
REVOKE ALL ON public.processing_run_balance FROM anon;
