-- MES-5a-1 close-out · read-only readings on live (2026-10-08). Run as postgres (rolbypassrls = true) over the Management API;
-- every relation read here is a base table except where named. Nothing is written: BEGIN READ ONLY, and the API never commits a read.
BEGIN READ ONLY;
SELECT jsonb_build_object(
  'discharge_results',          (SELECT count(*) FROM discharge_module_results),
  'channel_assignments',        (SELECT count(*) FROM discharge_channel_assignments),
  'module_splits',              (SELECT count(*) FROM discharge_module_splits),
  'inbound_with_module_count',  (SELECT count(*) FROM inbound_batches WHERE module_count IS NOT NULL),
  'output_with_module_count',   (SELECT count(*) FROM output_batches WHERE module_count IS NOT NULL),
  'materials_with_v9',          (SELECT count(*) FROM materials WHERE discharge_pass_voltage_v IS NOT NULL),
  'quarantine_locations',       (SELECT count(*) FROM storage_locations WHERE is_quarantine),
  'discharge_runs',             (SELECT jsonb_agg(jsonb_build_object('code', r.code, 'status', r.status, 'deleted', r.deleted_at IS NOT NULL) ORDER BY r.code)
                                   FROM processing_runs r WHERE r.operation_type_code IN ('deep_discharge','discharge_quarantine_split')),
  'runs_since_window_start',    (SELECT count(*) FROM processing_runs WHERE created_at >= '2026-10-08 12:28:14+08'),
  'require_calibrated_since',   (SELECT require_calibrated_since FROM ingest_settings LIMIT 1),
  'notifications_total',        (SELECT count(*) FROM notifications),
  'notifications_since_proof',  (SELECT count(*) FROM notifications WHERE created_at >= '2026-10-08 13:13:00+08'),
  'accounts',                   (SELECT count(*) FROM auth.users),
  'accounts_banned',            (SELECT count(*) FROM auth.users WHERE banned_until IS NOT NULL AND banned_until > now())
);
