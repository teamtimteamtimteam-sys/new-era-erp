-- MES-4b Step 0 · read-only live readings (2026-10-07). Identity: postgres over the pooler (rolbypassrls = true); every business relation is a
-- BASE table (RLS takes no part). Run:
--   PGOPTIONS='-c default_transaction_read_only=on' psql "host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 \
--     user=postgres.wvywpohbwkiinmipmuku dbname=postgres" -X -q -f docs/surveys/MES-4b/live-readings.sql
BEGIN READ ONLY;
\pset pager off
\pset format unaligned
SELECT 'identity', current_user, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user),
       current_setting('transaction_read_only'), (now() AT TIME ZONE 'Asia/Singapore')::text;
SELECT 'accounts', count(*), count(*) FILTER (WHERE banned_until > now()) AS disabled FROM auth.users;
SELECT 'approvals', approvals_enabled FROM finance_settings;
-- material forms and what uses them
SELECT 'material_forms', f.code, f.implies_dismantling, f.may_be_sold, f.is_active,
       (SELECT count(*) FROM materials m WHERE m.form_code = f.code AND m.deleted_at IS NULL) AS materials
  FROM material_forms f ORDER BY f.sort_order, f.code;
SELECT 'materials', count(*) FILTER (WHERE deleted_at IS NULL) AS live, count(*) FILTER (WHERE deleted_at IS NULL AND form_code IS NULL) AS no_form,
       count(*) FILTER (WHERE deleted_at IS NULL AND may_be_processed IS TRUE) AS processable FROM materials;
-- output batches: count, code shapes, the highest sequence number per prefix-year
SELECT 'output_batches', count(*), count(*) FILTER (WHERE deleted_at IS NULL) AS live,
       count(DISTINCT substring(code FROM '^[A-Z]+')) AS prefixes FROM output_batches;
SELECT 'output_code_shapes', substring(code FROM '^([A-Z]+-[0-9]{4})-') AS prefix_year, count(*),
       max(length(code)), max(substring(code FROM '-([0-9]+)$')::int) AS max_n
  FROM output_batches GROUP BY 2 ORDER BY 2;
SELECT 'output_code_seq', last_value, is_called FROM output_code_seq;
SELECT 'inbound_code_seq', last_value, is_called FROM inbound_code_seq;
SELECT 'output_by_form', coalesce(m.form_code, '(none)'), count(*) FROM output_batches ob JOIN materials m ON m.id = ob.material_id
 GROUP BY 2 ORDER BY 2;
SELECT 'inbound_batches', count(*), count(*) FILTER (WHERE deleted_at IS NULL) FROM inbound_batches;
-- document registry
SELECT 'document_types', count(*), string_agg(prefix, ',' ORDER BY prefix) FROM document_types;
SELECT 'document_type_OUT', key, prefix, table_name, numbering, sequence_name FROM document_types WHERE prefix = 'OUT';
-- the loss side MES-4a left
SELECT 'loss_categories', code, metal_fate, is_true_loss, is_active FROM loss_categories ORDER BY sort_order;
SELECT 'loss_rows', count(*) FROM processing_run_losses;
SELECT 'runs_mes4a', count(*) FROM processing_runs WHERE started_at IS NOT NULL;
SELECT 'shifts', code, is_active, coalesce(starts_at::text, 'NULL'), coalesce(ends_at::text, 'NULL') FROM shifts ORDER BY sort_order;
SELECT 'operation_output_forms', operation_type_code, string_agg(form_code, ',' ORDER BY form_code) FROM operation_type_output_forms GROUP BY 2 ORDER BY 2;
SELECT 'operation_input_forms', operation_type_code, string_agg(form_code, ',' ORDER BY form_code) FROM operation_type_input_forms GROUP BY 2 ORDER BY 2;
SELECT 'assay_results', count(*), count(*) FILTER (WHERE output_batch_id IS NOT NULL) AS on_output FROM assay_results;
SELECT 'pending_values_arms', count(DISTINCT value_code) FROM pending_values;  -- as postgres has_permission() is false: expect 0, measured to show it
SELECT 'change_log', count(*), max(seq) FROM change_log;
ROLLBACK;
