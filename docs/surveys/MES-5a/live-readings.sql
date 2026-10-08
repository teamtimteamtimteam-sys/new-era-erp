-- MES-5a Step 0 · read-only live readings (2026-10-08). Identity: postgres over the pooler (rolbypassrls = true); every business relation read
-- below is a BASE table (RLS takes no part). Run:
--   PGOPTIONS='-c default_transaction_read_only=on' psql "host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 \
--     user=postgres.wvywpohbwkiinmipmuku dbname=postgres" -X -q -f docs/surveys/MES-5a/live-readings.sql
BEGIN READ ONLY;
\pset pager off
\pset format unaligned
SELECT 'identity', current_user, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user),
       current_setting('transaction_read_only'), (now() AT TIME ZONE 'Asia/Singapore')::text;

-- discharge: the operation, its machines, its runs
SELECT 'op', code, kind_code, resulting_safety_state_code, is_active FROM operation_types WHERE code = 'deep_discharge';
SELECT 'op_fields_on_discharge', count(*) FROM operation_type_fields WHERE operation_type_code = 'deep_discharge';
SELECT 'op_machine_links', operation_type_code, count(*) FROM operation_type_equipment GROUP BY 2 ORDER BY 2;
SELECT 'fixed_assets', code, description, category, coalesce(in_service_date::text, 'NULL'), coalesce(disposal_date::text, 'NULL') FROM fixed_assets ORDER BY code;
SELECT 'discharge_runs', pr.status, count(*), count(*) FILTER (WHERE pr.started_at IS NOT NULL) AS mes4a_era,
       count(*) FILTER (WHERE pr.equipment_id IS NOT NULL) AS with_machine
  FROM processing_runs pr WHERE pr.operation_type_code = 'deep_discharge' GROUP BY pr.status ORDER BY 2;
-- how much of each batch a discharge run put through (the whole-batch flip matters only when this is below the batch quantity)
SELECT 'discharge_inputs', pr.code, pr.status, coalesce(ib.code, ob.code) AS batch, pi.quantity_consumed, coalesce(ib.quantity, ob.quantity) AS batch_qty,
       CASE WHEN pi.output_batch_id IS NOT NULL THEN 'output' ELSE 'inbound' END AS side
  FROM processing_inputs pi JOIN processing_runs pr ON pr.id = pi.run_id
  LEFT JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id LEFT JOIN output_batches ob ON ob.id = pi.output_batch_id
 WHERE pr.operation_type_code = 'deep_discharge' ORDER BY pr.code;
-- safety states open today
SELECT 'open_states_inbound', safety_state_code, count(*) FROM inbound_batch_safety_states WHERE ended_at IS NULL GROUP BY 2 ORDER BY 2;
SELECT 'open_states_output', safety_state_code, count(*) FROM output_batch_safety_states WHERE ended_at IS NULL GROUP BY 2 ORDER BY 2;
SELECT 'state_rows_by_run', count(*) FILTER (WHERE created_by_run_id IS NOT NULL), count(*) FILTER (WHERE ended_by_run_id IS NOT NULL)
  FROM inbound_batch_safety_states;
SELECT 'judgements_on_batches', coalesce(deep_discharge_actual_code, 'NULL'), count(*) FROM inbound_batches WHERE deleted_at IS NULL GROUP BY 2 ORDER BY 2;
SELECT 'safety_dictionary', code, may_be_fed, coalesce(requires_quarantine::text, 'NULL'), coalesce(dwell_warning_days::text, 'NULL')
  FROM inbound_safety_states ORDER BY sort_order;
SELECT 'quarantine_locations', count(*) FILTER (WHERE is_quarantine) FROM storage_locations;

-- ingestion: the two classes MES-1 reserved for MES-5a, and devices of the two kinds
SELECT 'classes', code, coalesce(transform_function, 'NULL'), coalesce(manual_entry_code, 'NULL'), creates_draft, is_active
  FROM ingest_data_classes WHERE code IN ('discharge_module', 'meter_reading', 'weighing') ORDER BY code;
SELECT 'inbox_by_class', data_class, status, count(*) FROM ingest_inbox GROUP BY 2, 3 ORDER BY 2, 3;
SELECT 'devices_by_kind', kind, interface_status, count(*) FILTER (WHERE retired_at IS NULL) FROM devices GROUP BY 2, 3 ORDER BY 2, 3;

-- energy: electricity money lines, settlement, bills
SELECT 'cost_entries', cost_type, is_estimate, count(*) FILTER (WHERE deleted_at IS NULL) AS live,
       count(*) FILTER (WHERE deleted_at IS NULL AND remitted_at IS NOT NULL) AS remitted,
       count(*) FILTER (WHERE deleted_at IS NULL AND relieved_at IS NOT NULL) AS relieved
  FROM processing_cost_entries GROUP BY 2, 3 ORDER BY 2, 3;
SELECT 'expenses_5110_6200', account_code, count(*) FROM expenses WHERE account_code IN ('5110', '6200') GROUP BY 2 ORDER BY 2;
SELECT 'run_values_energy', field_code, count(*) FROM processing_run_values WHERE field_code IN ('energy_kwh', 'run_time_min') GROUP BY 2;
SELECT 'runs_mes4a_era', count(*) FROM processing_runs WHERE started_at IS NOT NULL;
-- who holds the codes MES-5a's paths would ask for (active grants only)
SELECT 'holders', rp.permission_code, string_agg(DISTINCT r.code, ',' ORDER BY r.code) AS roles,
       count(DISTINCT ur.user_id) FILTER (WHERE ur.user_id IS NOT NULL) AS live_accounts
  FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
  LEFT JOIN user_roles ur ON ur.role_id = r.id AND ur.revoked_at IS NULL
 WHERE rp.permission_code IN ('action.confirm_capture','action.manage_devices','action.processing_commit','action.processing_aftercare',
                              'module.finance.edit','data.view_prices','module.processing.view','module.inbound.edit','module.output.edit')
 GROUP BY rp.permission_code ORDER BY rp.permission_code;
ROLLBACK;
