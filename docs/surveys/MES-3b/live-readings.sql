-- MES-3b Step 0 live readings (2026-10-07). Read-only: the session runs with default_transaction_read_only = on
-- (PGOPTIONS), and the block is BEGIN READ ONLY … ROLLBACK. Run as postgres (rolbypassrls = true) over psql to the pooler;
-- every object read below is a BASE table (relkind 'r') unless named otherwise, so RLS does not take part in the counts.
BEGIN READ ONLY;
\pset pager off
\pset format unaligned
SELECT 'identity', current_user, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user),
       current_setting('transaction_read_only'), (now() AT TIME ZONE 'Asia/Singapore')::text;
-- accounts, roles, approvals (the brief's live-state lines)
SELECT 'accounts', u.email,
       coalesce(string_agg(r.code, ',' ORDER BY r.code) FILTER (WHERE ur.revoked_at IS NULL), '-') AS active_roles,
       (u.banned_until IS NOT NULL AND u.banned_until > now()) AS disabled
  FROM auth.users u LEFT JOIN user_roles ur ON ur.user_id = u.id LEFT JOIN roles r ON r.id = ur.role_id
 GROUP BY u.email, u.banned_until ORDER BY u.email;
SELECT 'finance_settings', row_to_json(f)::text FROM finance_settings f;
-- the codes the MES-3b pages and functions would gate on, by role
SELECT 'code_holders', rp.permission_code, string_agg(r.code, ' · ' ORDER BY r.code)
  FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
 WHERE rp.permission_code ~ '^(module\.(inventory|logistics|suppliers|materials|inbound|output|processing|sales)\.(view|edit)|action\.(ship_goods|receive_goods|confirm_capture|manage_devices|processing_aftercare|hold_stock|transfer_stock).*)$'
 GROUP BY rp.permission_code ORDER BY rp.permission_code;
SELECT 'permission_codes_total', count(*) FROM permissions;
-- what MES-3a set or did not set (the brief: nothing is set by this work)
SELECT 'mes3a_state', (SELECT count(*) FROM nea_waste_categories) AS nea_categories,
       (SELECT count(*) FROM licence_storage_limits) AS ceilings,
       (SELECT count(*) FROM storage_locations WHERE is_quarantine) AS quarantine_locations,
       (SELECT count(*) FROM inbound_safety_states WHERE dwell_warning_days IS NOT NULL) AS dwell_periods,
       (SELECT coalesce(require_calibrated_since::text, 'NULL') FROM ingest_settings WHERE id) AS calib_switch;
-- materials: how many, of which kind and form; which could carry a DG code
SELECT 'materials_by_kind', m.kind_code, k.has_condition_axes, count(*) FILTER (WHERE m.deleted_at IS NULL) AS live, count(*) AS all_rows
  FROM materials m LEFT JOIN material_kinds k ON k.code = m.kind_code GROUP BY 2, 3 ORDER BY 2;
SELECT 'material_forms', string_agg(code, ' · ' ORDER BY code) FROM material_forms;
-- batches and their code shapes
SELECT 'inbound_batches', count(*) FILTER (WHERE deleted_at IS NULL), count(*), min(code), max(code) FROM inbound_batches;
SELECT 'output_batches', count(*) FILTER (WHERE deleted_at IS NULL), count(*), min(code), max(code) FROM output_batches;
SELECT 'code_overlap_inbound_output', count(*) FROM inbound_batches i JOIN output_batches o ON o.code = i.code;
-- shipments
SELECT 'shipments', count(*) FROM shipments;
SELECT 'shipment_lines', count(*) FROM shipment_lines;
SELECT 'columns', table_name, string_agg(column_name, ', ' ORDER BY ordinal_position)
  FROM information_schema.columns
 WHERE table_schema = 'public' AND table_name IN ('shipments', 'shipment_lines', 'customers', 'storage_locations')
 GROUP BY table_name ORDER BY table_name;
-- locations (codes that a location label could carry)
SELECT 'storage_locations', count(*) FILTER (WHERE is_active), count(*) FROM storage_locations;
-- the ingestion classes MES-1/2 seeded (is there a scan class?)
SELECT 'ingest_data_classes', row_to_json(c)::text FROM ingest_data_classes c ORDER BY code;
-- document types (a print archive or new prefixes would add rows)
SELECT 'document_types', count(*) FROM document_types;
ROLLBACK;
