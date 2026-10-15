-- MES-7a Step 0 — live readings (2026-10-15), read-only: BEGIN READ ONLY … ROLLBACK.
-- Identity: postgres (rolbypassrls = true) on base tables (relkind 'r') and the catalog, so counts are real row counts, not a permission answer.
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/MES-7a/live-readings.sql
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
-- equipment ledger
SELECT 'ASSET|' || code || '|' || category || '|' || status || '|acq=' || acquisition_date || '|in_service=' || COALESCE(in_service_date::text, '-')
    || '|' || left(description, 50) FROM fixed_assets ORDER BY code;
SELECT 'DOWNTIME|' || a.code || '|' || to_char(d.started_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI') || '|end=' || COALESCE(to_char(d.ended_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI'), 'open')
    || '|void=' || (d.voided_at IS NOT NULL) || '|reason=' || left(d.reason, 40) FROM equipment_downtime d JOIN fixed_assets a ON a.id = d.equipment_id ORDER BY d.started_at;
SELECT 'MAINT|' || a.code || '|' || m.performed_on || '|' || m.kind || '|downtime_linked=' || (m.downtime_id IS NOT NULL) || '|expense_linked=' || (m.expense_id IS NOT NULL)
    || '|capitalised=' || m.capitalised || '|' || left(m.description, 40) FROM equipment_maintenance m JOIN fixed_assets a ON a.id = m.equipment_id ORDER BY m.performed_on;
SELECT 'INTERVAL|' || a.code || '|' || i.kind || '|kg=' || COALESCE(i.interval_kg::text, '-') || '|days=' || COALESCE(i.interval_days::text, '-')
  FROM equipment_service_intervals i JOIN fixed_assets a ON a.id = i.equipment_id;
SELECT 'OPLINKS|' || count(*) FROM operation_type_equipment;
-- runs: machine and times (the MTBF denominator's inputs)
SELECT 'RUNS|all=' || count(*) || '|committed=' || count(*) FILTER (WHERE status = 'committed' AND deleted_at IS NULL)
    || '|with machine=' || count(*) FILTER (WHERE equipment_id IS NOT NULL)
    || '|with start+end=' || count(*) FILTER (WHERE started_at IS NOT NULL AND ended_at IS NOT NULL)
    || '|machine+times=' || count(*) FILTER (WHERE equipment_id IS NOT NULL AND started_at IS NOT NULL AND ended_at IS NOT NULL)
    || '|with operation=' || count(*) FILTER (WHERE operation_type_code IS NOT NULL) FROM processing_runs;
SELECT 'RUNVALUES|' || COALESCE(string_agg(field_code || '=' || n, ',' ORDER BY field_code), 'none') FROM (SELECT field_code, count(*) n FROM processing_run_values
 WHERE field_code IN ('run_time_min', 'unplanned_stops', 'unplanned_stop_min', 'cuts_this_run') GROUP BY field_code) x;
SELECT 'RUNEVENTS|' || COALESCE((SELECT string_agg(event_type_code || '=' || n, ',') FROM (SELECT event_type_code, count(*) n FROM processing_run_events GROUP BY 1) x), 'none');
SELECT 'DEVICES|' || kind || '|with machine=' || count(*) FILTER (WHERE equipment_id IS NOT NULL) || '|all=' || count(*) FROM devices GROUP BY kind ORDER BY kind;
-- spare parts and consumables
SELECT 'KINDS|' || COALESCE(kind_code, 'NULL') || '=' || count(*) || '|with safety stock=' || count(*) FILTER (WHERE safety_stock_qty IS NOT NULL)
  FROM materials WHERE deleted_at IS NULL GROUP BY kind_code ORDER BY kind_code;
SELECT 'SPAREBATCHES|' || count(*) FROM inbound_batches b JOIN materials m ON m.id = b.material_id WHERE m.kind_code IN ('spare_part', 'consumable') AND b.deleted_at IS NULL;
SELECT 'MOVETYPES|' || movement_type || '=' || count(*) FROM inventory_movements GROUP BY movement_type ORDER BY movement_type;
SELECT 'MOVECHECK|' || conname || '|' || left(pg_get_constraintdef(oid), 220) FROM pg_constraint
 WHERE conrelid = 'public.inventory_movements'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%movement_type%' ORDER BY conname;
SELECT 'POCATS|' || category || '=' || count(*) FROM purchase_orders GROUP BY category ORDER BY category;
-- registries a new cut extends
SELECT 'DOCTYPES|' || count(*) FROM document_types;
SELECT 'PENDINGARMS|' || count(DISTINCT value_code) FROM pending_values;
SELECT 'TABLES|' || count(*) FROM pg_tables WHERE schemaname = 'public';
-- F10: the issued certificates of destruction — what is frozen and what the live data says today
SELECT 'COD|' || c.code || '|' || c.status || '|issued=' || to_char(c.issued_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI')
    || '|snapshot keys=' || (SELECT string_agg(k, ',' ORDER BY k) FROM jsonb_object_keys(c.snapshot) k)
    || '|bytes=' || EXISTS (SELECT 1 FROM cod_issues i WHERE i.cod_id = c.id)
    || '|company same now=' || ((c.snapshot -> 'company' ->> 'legal_name') IS NOT DISTINCT FROM (SELECT legal_name FROM company_profile LIMIT 1))
    || '|supplier same now=' || ((c.snapshot -> 'supplier' ->> 'name') IS NOT DISTINCT FROM (SELECT s.legal_name FROM inbound_batches b JOIN suppliers s ON s.id = b.supplier_id WHERE b.id = c.inbound_batch_id))
  FROM certificates_of_destruction c WHERE c.snapshot IS NOT NULL ORDER BY c.code;
SELECT 'CODSNAP|' || c.code || '|company keys=' || (SELECT string_agg(k, ',' ORDER BY k) FROM jsonb_object_keys(c.snapshot -> 'company') k)
    || '|licence=' || COALESCE((c.snapshot -> 'licence')::text, 'null') FROM certificates_of_destruction c WHERE c.snapshot IS NOT NULL ORDER BY c.code;
ROLLBACK;
