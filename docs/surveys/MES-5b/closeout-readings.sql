-- MES-5a-2 close-out · read-only readings on live (2026-10-08). Run as postgres (rolbypassrls = true) over direct psql to the pooler;
-- every relation read here is a base table. Nothing is written: BEGIN READ ONLY … ROLLBACK.
-- Part 1: did anyone use the MES-5a-2 machinery inside the broken window (start 2026-10-08 16:05:51 CST)?
-- Part 2: which live roles hold the three action codes item f asks about, and do they also hold the view code each page asks?
BEGIN READ ONLY;
SELECT jsonb_build_object(
  'meters',                     (SELECT count(*) FROM devices WHERE kind = 'meter'),
  'meter_readings',             (SELECT count(*) FROM meter_readings),
  'allocations',                (SELECT count(*) FROM electricity_allocations),
  'allocation_lines',           (SELECT count(*) FROM electricity_allocation_lines),
  'v25_rule',                   (SELECT shared_pool_rule FROM electricity_settings),
  'energy_kwh_values',          (SELECT count(*) FROM processing_run_values WHERE field_code = 'energy_kwh'),
  'runs_since_window_start',    (SELECT count(*) FROM processing_runs WHERE created_at >= '2026-10-08 16:05:51+08'),
  'electricity_lines',          (SELECT jsonb_build_object(
                                   'live', count(*) FILTER (WHERE deleted_at IS NULL),
                                   'estimates_open', count(*) FILTER (WHERE deleted_at IS NULL AND is_estimate AND relieved_at IS NULL),
                                   'relieved', count(*) FILTER (WHERE relieved_at IS NOT NULL))
                                   FROM processing_cost_entries WHERE cost_type = 'electricity'),
  'require_calibrated_since',   (SELECT require_calibrated_since FROM ingest_settings LIMIT 1),
  'notifications_total',        (SELECT count(*) FROM notifications),
  'accounts',                   (SELECT count(*) FROM auth.users),
  'accounts_banned',            (SELECT count(*) FROM auth.users WHERE banned_until IS NOT NULL AND banned_until > now())
) AS part1;
SELECT r.code AS role,
       bool_or(rp.permission_code = 'action.manage_devices')  AS manage_devices,
       bool_or(rp.permission_code = 'action.confirm_capture') AS confirm_capture,
       bool_or(rp.permission_code = 'module.processing.view') AS processing_view,
       bool_or(rp.permission_code = 'module.finance.edit')    AS finance_edit,
       bool_or(rp.permission_code = 'module.finance.view')    AS finance_view,
       (SELECT count(*) FROM user_roles ur WHERE ur.role_id = r.id AND ur.revoked_at IS NULL) AS live_holders
  FROM roles r JOIN role_permissions rp ON rp.role_id = r.id
 WHERE r.is_active AND r.deleted_at IS NULL
 GROUP BY r.id, r.code
HAVING bool_or(rp.permission_code IN ('action.manage_devices', 'action.confirm_capture', 'module.finance.edit'))
 ORDER BY r.code;
ROLLBACK;
