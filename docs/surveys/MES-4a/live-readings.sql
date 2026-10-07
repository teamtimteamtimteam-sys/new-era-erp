-- MES-4a Step 0 live readings (2026-10-07). NOT RUN BY THE STEP 0 SESSION: its psql read to live was refused by the
-- session's permission check, so every live number in STEP0-HANDBACK.md is quoted from an earlier hand-back and tagged [Q].
-- Read-only: run with PGOPTIONS='-c default_transaction_read_only=on'; the block is BEGIN READ ONLY … ROLLBACK.
-- Identity: postgres over the pooler (rolbypassrls = true). Every object below is a BASE table (relkind 'r'), so RLS takes no part.
--   PGOPTIONS='-c default_transaction_read_only=on' psql "host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 \
--     user=postgres.wvywpohbwkiinmipmuku dbname=postgres" -X -q -f docs/surveys/MES-4a/live-readings.sql
BEGIN READ ONLY;
\pset pager off
\pset format unaligned
SELECT 'identity', current_user, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user),
       current_setting('transaction_read_only'), (now() AT TIME ZONE 'Asia/Singapore')::text;
-- accounts and approvals (the brief's live-state lines)
SELECT 'accounts', u.email,
       coalesce(string_agg(r.code, ',' ORDER BY r.code) FILTER (WHERE ur.revoked_at IS NULL), '-') AS active_roles,
       (u.banned_until IS NOT NULL AND u.banned_until > now()) AS disabled
  FROM auth.users u LEFT JOIN user_roles ur ON ur.user_id = u.id LEFT JOIN roles r ON r.id = ur.role_id
 GROUP BY u.email, u.banned_until ORDER BY u.email;
SELECT 'finance_settings', approvals_enabled, locked_before FROM finance_settings;
SELECT 'calibration_switch', coalesce(require_calibrated_since::text, 'NULL') FROM ingest_settings;
-- processing runs: the brief's "10–14 existing test runs" and "8 runs without cost allocation"
SELECT 'runs', status, (deleted_at IS NULL) AS live, count(*),
       count(*) FILTER (WHERE allocated_at IS NULL) AS unallocated,
       count(*) FILTER (WHERE equipment_id IS NOT NULL) AS with_machine,
       count(*) FILTER (WHERE operation_type_code IS NOT NULL) AS with_operation,
       count(*) FILTER (WHERE loss_qty IS DISTINCT FROM total_input - total_output) AS loss_not_in_minus_out,
       min(process_date), max(process_date)
  FROM processing_runs GROUP BY 2, 3 ORDER BY 2, 3;
SELECT 'runs_by_operation', coalesce(operation_type_code, '(none)'), count(*) FROM processing_runs
 WHERE deleted_at IS NULL GROUP BY 2 ORDER BY 2;
SELECT 'loss_rows', count(*), count(DISTINCT run_id) FROM processing_run_losses;
SELECT 'output_units', ob.unit, count(*) FROM processing_outputs po JOIN output_batches ob ON ob.id = po.output_batch_id GROUP BY 2;
-- configuration the cut builds on
SELECT 'operation_types', code, kind_code, is_active FROM operation_types ORDER BY sort_order;
SELECT 'loss_categories', code, metal_fate, is_true_loss, is_active FROM loss_categories ORDER BY sort_order;
SELECT 'shifts', code, coalesce(starts_at::text, 'NULL'), coalesce(ends_at::text, 'NULL'), is_active FROM shifts ORDER BY sort_order;
SELECT 'fixed_assets', code, category, status, coalesce(in_service_date::text, 'NULL') FROM fixed_assets ORDER BY code;
SELECT 'weighings', count(*), count(*) FILTER (WHERE ticket_id IS NULL) AS standalone_net FROM weighings;
SELECT 'ingest_classes', code, coalesce(transform_function, 'NULL'), creates_draft FROM ingest_data_classes ORDER BY code;
-- who holds the codes MES-4a gates on
SELECT 'code_holders', rp.permission_code, string_agg(r.code, ' · ' ORDER BY r.code)
  FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
 WHERE rp.permission_code IN ('module.processing.view', 'module.processing.edit', 'action.processing_commit',
                              'action.processing_aftercare', 'action.processing_rollback', 'action.confirm_capture')
 GROUP BY rp.permission_code ORDER BY rp.permission_code;
-- the UPDATE / DELETE policies Q32 would drop
SELECT 'policies', tablename, policyname, cmd FROM pg_policies
 WHERE schemaname = 'public' AND tablename IN ('processing_runs', 'processing_inputs', 'processing_outputs', 'processing_run_losses')
 ORDER BY tablename, cmd;
ROLLBACK;
