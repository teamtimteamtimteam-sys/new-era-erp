-- MES-5b-1 · opening readings on live (2026-10-08). Run as postgres (rolbypassrls = true) over direct psql to the pooler.
-- Every relation read here is a base table. Nothing is written: BEGIN READ ONLY … ROLLBACK.
-- "Today's /inventory lifetime balance" = app/inventory/page.tsx:152-155,326-328 — Σ total_input / total_output / loss_qty over
-- processing_run_lookup rows with deleted_at IS NULL (every operation, discharge throughput and splits included). Per batch below:
-- the input legs each batch fed into those same runs (what the plant figure is made of), plus each run's own in / out / loss.
BEGIN READ ONLY;

\echo '== 1 · runs by era, status, operation; closures'
SELECT jsonb_build_object(
  'runs_total',            (SELECT count(*) FROM processing_runs),
  'pre_mes4a',             (SELECT jsonb_object_agg(k, n) FROM (SELECT status || CASE WHEN deleted_at IS NULL THEN '' ELSE '+deleted' END k, count(*) n FROM processing_runs WHERE started_at IS NULL GROUP BY 1) x),
  'mes4a_era',             (SELECT COALESCE(jsonb_object_agg(k, n), '{}') FROM (SELECT status || CASE WHEN deleted_at IS NULL THEN '' ELSE '+deleted' END k, count(*) n FROM processing_runs WHERE started_at IS NOT NULL GROUP BY 1) x),
  'by_operation',          (SELECT jsonb_object_agg(COALESCE(operation_type_code, '(none)'), n) FROM (SELECT operation_type_code, count(*) n FROM processing_runs GROUP BY 1) x),
  'corrects_run_id_set',   (SELECT count(*) FROM processing_runs WHERE corrects_run_id IS NOT NULL),
  'closures',              (SELECT count(*) FROM processing_run_closures),
  'loss_rows',             (SELECT count(*) FROM processing_run_losses),
  'split_rows',            (SELECT count(*) FROM discharge_module_splits)
) AS runs;

\echo '== 2 · /inventory lifetime balance as today''s code computes it (plant-wide)'
SELECT count(*) AS runs, sum(total_input) AS total_input, sum(total_output) AS total_output, sum(loss_qty) AS total_loss
  FROM processing_runs WHERE deleted_at IS NULL;

\echo '== 3 · per run (every run, with operation kind)'
SELECT r.code, r.status, r.deleted_at IS NOT NULL AS deleted, to_char(r.process_date,'YYYY-MM-DD') d, COALESCE(r.operation_type_code,'(none)') op,
       COALESCE(k.consumes_input::text,'(no kind)') consumes, r.started_at IS NOT NULL AS mes4a, r.total_input, r.total_output, r.loss_qty
  FROM processing_runs r LEFT JOIN operation_types ot ON ot.code = r.operation_type_code LEFT JOIN operation_kinds k ON k.code = ot.kind_code
 ORDER BY r.process_date, r.code;

\echo '== 4 · per batch: kg fed into runs that today''s /inventory figure counts (deleted_at IS NULL), and into reversed runs'
SELECT COALESCE(ib.code, ob.code) AS batch, CASE WHEN pi.inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END AS side,
       COALESCE(ib.unit, ob.unit) AS unit,
       sum(pi.quantity_consumed) FILTER (WHERE r.deleted_at IS NULL) AS counted_by_inventory_today,
       count(DISTINCT r.id) FILTER (WHERE r.deleted_at IS NULL) AS runs_counted,
       sum(pi.quantity_consumed) FILTER (WHERE r.deleted_at IS NOT NULL) AS in_reversed_runs,
       string_agg(DISTINCT r.code || CASE WHEN r.deleted_at IS NULL THEN '' ELSE '(rev)' END, ', ') AS runs
  FROM processing_inputs pi JOIN processing_runs r ON r.id = pi.run_id
  LEFT JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id LEFT JOIN output_batches ob ON ob.id = pi.output_batch_id
 GROUP BY 1, 2, 3 ORDER BY 2, 1;

\echo '== 5 · per batch produced by runs (output legs)'
SELECT ob.code AS batch, ob.unit, r.code AS run, r.deleted_at IS NOT NULL AS run_deleted, po.quantity_produced
  FROM processing_outputs po JOIN processing_runs r ON r.id = po.run_id JOIN output_batches ob ON ob.id = po.output_batch_id
 ORDER BY r.code, ob.code;

\echo '== 6 · material chemistry'
SELECT count(*) FILTER (WHERE deleted_at IS NULL) AS live, count(*) FILTER (WHERE deleted_at IS NULL AND chemistry IS NOT NULL) AS with_chemistry,
       count(*) FILTER (WHERE deleted_at IS NULL AND chemistry IS NULL) AS without_chemistry, count(*) AS all_rows FROM materials;
SELECT code, name, chemistry, deleted_at IS NOT NULL AS deleted FROM materials ORDER BY code;

\echo '== 7 · every role: holders and codes'
SELECT r.code AS role, (SELECT string_agg(u.email, ',') FROM user_roles ur JOIN auth.users u ON u.id = ur.user_id WHERE ur.role_id = r.id AND ur.revoked_at IS NULL) AS holders,
       count(rp.permission_code) AS n_codes, string_agg(rp.permission_code, ' ' ORDER BY rp.permission_code) AS codes
  FROM roles r LEFT JOIN role_permissions rp ON rp.role_id = r.id GROUP BY r.id, r.code ORDER BY r.code;
SELECT count(*) AS catalogue_codes FROM permissions;

\echo '== 8 · standing state'
SELECT (SELECT count(*) FROM auth.users) AS accounts, (SELECT count(*) FROM auth.users WHERE banned_until IS NOT NULL AND banned_until > now()) AS disabled,
       (SELECT approvals_enabled FROM finance_settings LIMIT 1) AS approvals, (SELECT require_calibrated_since FROM ingest_settings LIMIT 1) AS require_calibrated_since,
       (SELECT count(*) FROM change_log) AS change_log_rows, (SELECT max(seq) FROM change_log) AS change_log_max_seq,
       (SELECT count(*) FROM notifications) AS notifications;
SELECT code, kind_code, balance_tolerance_pct FROM operation_types ORDER BY sort_order;
ROLLBACK;
