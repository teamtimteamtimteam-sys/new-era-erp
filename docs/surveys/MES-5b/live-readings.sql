-- MES-5b Step 0 · read-only readings on live (2026-10-08). Run as postgres (rolbypassrls = true) over direct psql to the pooler;
-- every relation read here is a base table. Nothing is written: BEGIN READ ONLY … ROLLBACK.
BEGIN READ ONLY;

-- 1 · runs: status, era (MES-4a header or not), operation, month, legs
SELECT jsonb_build_object(
  'runs_by_status',          (SELECT jsonb_object_agg(k, n) FROM (SELECT status || CASE WHEN deleted_at IS NULL THEN '' ELSE '+deleted' END k, count(*) n FROM processing_runs GROUP BY 1) x),
  'runs_pre_mes4a',          (SELECT count(*) FROM processing_runs WHERE started_at IS NULL),
  'runs_mes4a_era',          (SELECT count(*) FROM processing_runs WHERE started_at IS NOT NULL),
  'runs_no_operation',       (SELECT count(*) FROM processing_runs WHERE operation_type_code IS NULL),
  'runs_by_operation',       (SELECT jsonb_object_agg(COALESCE(operation_type_code, '(none)'), n) FROM (SELECT operation_type_code, count(*) n FROM processing_runs GROUP BY 1) x),
  'runs_by_month',           (SELECT jsonb_object_agg(m, n) FROM (SELECT to_char(process_date, 'YYYY-MM') m, count(*) n FROM processing_runs GROUP BY 1) x),
  'runs_with_corrects',      (SELECT count(*) FROM processing_runs WHERE corrects_run_id IS NOT NULL),
  'runs_with_work_order',    (SELECT count(*) FROM processing_runs WHERE work_order_id IS NOT NULL),
  'inputs_by_source',        (SELECT jsonb_build_object('inbound', count(*) FILTER (WHERE inbound_batch_id IS NOT NULL), 'output', count(*) FILTER (WHERE output_batch_id IS NOT NULL)) FROM processing_inputs),
  'runs_by_input_legs',      (SELECT jsonb_object_agg(legs, n) FROM (SELECT legs, count(*) n FROM (SELECT run_id, count(*) legs FROM processing_inputs GROUP BY run_id) y GROUP BY legs) x),
  'runs_by_output_legs',     (SELECT jsonb_object_agg(legs, n) FROM (SELECT legs, count(*) n FROM (SELECT r.id, count(o.id) legs FROM processing_runs r LEFT JOIN processing_outputs o ON o.run_id = r.id GROUP BY r.id) y GROUP BY legs) x),
  'inbound_batches_fed_by_runs', (SELECT jsonb_object_agg(runs, n) FROM (SELECT runs, count(*) n FROM (SELECT inbound_batch_id, count(DISTINCT run_id) runs FROM processing_inputs WHERE inbound_batch_id IS NOT NULL GROUP BY 1) y GROUP BY runs) x),
  'output_batches_fed_onward',   (SELECT count(DISTINCT output_batch_id) FROM processing_inputs WHERE output_batch_id IS NOT NULL),
  'closures',                (SELECT count(*) FROM processing_run_closures),
  'losses_by_category_basis',(SELECT COALESCE(jsonb_object_agg(k, n), '{}') FROM (SELECT loss_category_code || ':' || COALESCE(basis, '-') k, count(*) n FROM processing_run_losses GROUP BY 1) x),
  'runs_loss_qty_nonzero',   (SELECT count(*) FROM processing_runs WHERE COALESCE(loss_qty, 0) <> 0),
  'sum_in_out_loss_live',    (SELECT jsonb_build_object('in', sum(total_input), 'out', sum(total_output), 'loss', sum(loss_qty)) FROM processing_runs WHERE deleted_at IS NULL AND status = 'committed')
) AS runs;

-- 2 · operations as configured
SELECT code, kind_code, is_active, balance_tolerance_pct, electrolyte_loss_applies, verifies_by_unit, started_from_run_page
  FROM operation_types ORDER BY sort_order;

-- 3 · blending inputs: grade specs, metal content, chemistry, expected outputs, work orders
SELECT jsonb_build_object(
  'contract_grade_specs',        (SELECT count(*) FROM contract_grade_specs),
  'grade_spec_contracts',        (SELECT count(DISTINCT contract_id) FROM contract_grade_specs),
  'output_batch_metals',         (SELECT count(*) FROM output_batch_metals),
  'output_batches_with_metals',  (SELECT count(DISTINCT output_batch_id) FROM output_batch_metals),
  'inbound_batch_metals',        (SELECT count(*) FROM inbound_batch_metals),
  'inbound_batches_with_metals', (SELECT count(DISTINCT inbound_batch_id) FROM inbound_batch_metals),
  'materials_live',              (SELECT count(*) FROM materials WHERE deleted_at IS NULL),
  'materials_with_chemistry',    (SELECT count(*) FROM materials WHERE deleted_at IS NULL AND chemistry IS NOT NULL),
  'materials_with_form',         (SELECT count(*) FROM materials WHERE deleted_at IS NULL AND form_code IS NOT NULL),
  'work_orders',                 (SELECT count(*) FROM work_orders),
  'expected_outputs_by_basis',   (SELECT COALESCE(jsonb_object_agg(COALESCE(basis, '(none)'), n), '{}') FROM (SELECT basis, count(*) n FROM work_order_expected_outputs GROUP BY 1) x)
) AS blending;

-- 4 · finance fold-ins F1 / F2: allocations, relieved estimates and their relief expenses
SELECT jsonb_build_object(
  'electricity_allocations',     (SELECT count(*) FROM electricity_allocations),
  'relieved_cost_entries',       (SELECT COALESCE(jsonb_agg(jsonb_build_object('cost_type', c.cost_type, 'amount', c.amount_base, 'deleted', c.deleted_at IS NOT NULL,
                                     'relief_expense', e.code, 'relief_expense_status', e.status, 'reversed_by', e.reversed_by_expense IS NOT NULL)), '[]')
                                    FROM processing_cost_entries c LEFT JOIN expenses e ON e.id = c.relief_expense_id WHERE c.relieved_at IS NOT NULL),
  'relief_expenses',             (SELECT count(DISTINCT relief_expense_id) FROM processing_cost_entries WHERE relief_expense_id IS NOT NULL),
  'expenses_by_status',          (SELECT jsonb_object_agg(COALESCE(status, '(null)'), n) FROM (SELECT status, count(*) n FROM expenses GROUP BY 1) x),
  'inventory_movements_by_type', (SELECT jsonb_object_agg(movement_type, n) FROM (SELECT movement_type, count(*) n FROM inventory_movements GROUP BY 1) x)
) AS finance;
ROLLBACK;
