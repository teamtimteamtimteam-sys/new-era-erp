-- MES-5a-2 · opening readings on live (read-only). Part 1 as postgres (rolbypassrls = true), base tables;
-- part 2 (reconciliation) in tim@'s session, because list_ledger_reconciliation filters by the reader's codes.
BEGIN READ ONLY;
SELECT jsonb_build_object(
  'devices_by_kind', (SELECT jsonb_object_agg(kind, n) FROM (SELECT kind, count(*) n FROM devices GROUP BY kind) x),
  'meters', (SELECT COALESCE(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'equipment_id', equipment_id, 'retired', retired_at IS NOT NULL)), '[]') FROM devices WHERE kind = 'meter'),
  'runs_with_energy_kwh', (SELECT count(DISTINCT run_id) FROM processing_run_values WHERE field_code = 'energy_kwh'),
  'energy_kwh_values', (SELECT count(*) FROM processing_run_values WHERE field_code = 'energy_kwh'),
  'electricity_lines', (SELECT jsonb_build_object(
        'live', count(*) FILTER (WHERE deleted_at IS NULL),
        'live_estimates', count(*) FILTER (WHERE deleted_at IS NULL AND is_estimate),
        'live_actual', count(*) FILTER (WHERE deleted_at IS NULL AND NOT is_estimate),
        'estimates_open', count(*) FILTER (WHERE deleted_at IS NULL AND is_estimate AND relieved_at IS NULL),
        'relieved', count(*) FILTER (WHERE relieved_at IS NOT NULL),
        'remitted', count(*) FILTER (WHERE remitted_at IS NOT NULL),
        'soft_deleted', count(*) FILTER (WHERE deleted_at IS NOT NULL)) FROM processing_cost_entries WHERE cost_type = 'electricity'),
  'expenses_5110_6200', (SELECT jsonb_object_agg(account_code, n) FROM (SELECT account_code, count(*) n FROM expenses WHERE account_code IN ('5110','6200') GROUP BY 1) x),
  'pending_documents', (SELECT COALESCE(string_agg(subject_type || ':' || code || ':' || amount_base, ' · ' ORDER BY code), '-') FROM approval_pending_documents())
);
ROLLBACK;
