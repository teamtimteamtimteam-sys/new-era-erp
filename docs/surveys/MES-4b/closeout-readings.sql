-- MES-4a close-out (2026-10-07) · read-only live readings, run twice at 20:58 CST by the close-out session.
-- Identity: postgres over the pooler (rolbypassrls = true); every business relation read is a BASE table (RLS takes no part); part 2 also reads the catalog.
-- Run: PGOPTIONS='-c default_transaction_read_only=on' psql "host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 \
--        user=postgres.wvywpohbwkiinmipmuku dbname=postgres" -X -q -f docs/surveys/MES-4b/closeout-readings.sql
-- Part 1 = items a and b (opening figures re-read; which stock the input guard would admit today, same predicate as guard_processing_input).
-- Part 2 = items e and g (policies, privileges and write guards on the four processing tables; V1 / V6 / V36 arm counts).
BEGIN READ ONLY;
\pset pager off
\pset format unaligned
SELECT 'identity', current_user, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user),
       current_setting('transaction_read_only'), (now() AT TIME ZONE 'Asia/Singapore')::text;
SELECT 'accounts', count(*), count(*) FILTER (WHERE banned_until > now()) AS disabled FROM auth.users;
SELECT 'finance_settings', approvals_enabled FROM finance_settings;
SELECT 'calibration_switch', coalesce(require_calibrated_since::text, 'NULL') FROM ingest_settings;
-- the hand-back's opening figures, re-read now
SELECT 'runs', status, (deleted_at IS NULL) AS live, count(*),
       count(*) FILTER (WHERE allocated_at IS NULL) AS unallocated,
       count(*) FILTER (WHERE started_at IS NOT NULL) AS mes4a_runs
  FROM processing_runs GROUP BY 2, 3 ORDER BY 2, 3;
SELECT 'loss_rows', count(*) FROM processing_run_losses;
SELECT 'shifts', code, coalesce(starts_at::text, 'NULL'), coalesce(ends_at::text, 'NULL'), is_active FROM shifts ORDER BY sort_order;
SELECT 'weighings', count(*) FROM weighings;
SELECT 'machine_links', count(*) FROM operation_type_equipment;
SELECT 'tolerances_set', count(*) FROM operation_types WHERE balance_tolerance_pct IS NOT NULL;
SELECT 'recipes', count(*) FROM process_recipes;
SELECT 'ranges_set', count(*) FROM operation_type_fields WHERE range_min IS NOT NULL OR range_max IS NOT NULL;
SELECT 'fields_required', count(*) FROM operation_type_fields WHERE is_required;
SELECT 'operation_types', code, kind_code, is_active,
       (SELECT string_agg(a.safety_state_code || CASE WHEN a.resolves THEN '(resolves)' ELSE '' END, ',' ORDER BY a.safety_state_code)
          FROM operation_type_safety_states a WHERE a.operation_type_code = ot.code) AS accepts
  FROM operation_types ot ORDER BY sort_order;
-- MES-3a / 3b values still unset
SELECT 'mes3_values', (SELECT count(*) FROM nea_waste_categories) AS categories, (SELECT count(*) FROM licence_storage_limits) AS ceilings,
       (SELECT count(*) FROM inbound_safety_states WHERE dwell_warning_days IS NOT NULL) AS dwell,
       (SELECT count(*) FROM storage_locations WHERE is_quarantine) AS quarantine_locations,
       (SELECT count(*) FROM materials WHERE dg_code IS NOT NULL) AS dg_on_materials,
       (SELECT count(*) FROM materials WHERE hs_code IS NOT NULL) AS hs_on_materials;
-- which live inbound batches the input guard would admit today, per operation (same predicate as guard_processing_input)
WITH avail AS (
    SELECT m.inbound_batch_id AS id, sum(m.qty_delta) AS qty FROM inventory_movements m
     WHERE m.inbound_batch_id IS NOT NULL AND m.stock_status = 'available' GROUP BY 1 HAVING sum(m.qty_delta) > 0),
cand AS (
    SELECT ib.id, ib.code, a.qty, mat.may_be_processed, mk.has_condition_axes,
           coalesce(cc.may_be_fed, true) AS chem_ok,
           ARRAY(SELECT s.safety_state_code FROM inbound_batch_safety_states s
                  WHERE s.inbound_batch_id = ib.id AND s.ended_at IS NULL ORDER BY 1) AS states
      FROM avail a JOIN inbound_batches ib ON ib.id = a.id AND ib.deleted_at IS NULL
      JOIN materials mat ON mat.id = ib.material_id
      LEFT JOIN material_kinds mk ON mk.code = mat.kind_code
      LEFT JOIN inbound_chemistry_certainties cc ON cc.code = ib.chemistry_certainty_code)
SELECT 'feedable_inbound', ot.code,
       count(*) FILTER (WHERE c.may_be_processed IS TRUE
                          AND (c.has_condition_axes IS NOT TRUE
                               OR (cardinality(c.states) > 0 AND c.chem_ok
                                   AND NOT EXISTS (SELECT 1 FROM unnest(c.states) st
                                                    WHERE NOT EXISTS (SELECT 1 FROM operation_type_safety_states x
                                                                       WHERE x.operation_type_code = ot.code AND x.safety_state_code = st))))) AS admitted,
       count(*) AS with_available_stock
  FROM operation_types ot CROSS JOIN cand c WHERE ot.is_active GROUP BY ot.code, ot.sort_order ORDER BY ot.sort_order;
SELECT 'stock_batches_detail', c.code, c.qty, c.may_be_processed, c.has_condition_axes, c.chem_ok, array_to_string(c.states, ',')
  FROM (SELECT ib.code, a.qty, mat.may_be_processed, mk.has_condition_axes, coalesce(cc.may_be_fed, true) AS chem_ok,
               ARRAY(SELECT s.safety_state_code FROM inbound_batch_safety_states s WHERE s.inbound_batch_id = ib.id AND s.ended_at IS NULL ORDER BY 1) AS states
          FROM (SELECT m.inbound_batch_id AS id, sum(m.qty_delta) AS qty FROM inventory_movements m
                 WHERE m.inbound_batch_id IS NOT NULL AND m.stock_status = 'available' GROUP BY 1 HAVING sum(m.qty_delta) > 0) a
          JOIN inbound_batches ib ON ib.id = a.id AND ib.deleted_at IS NULL
          JOIN materials mat ON mat.id = ib.material_id
          LEFT JOIN material_kinds mk ON mk.code = mat.kind_code
          LEFT JOIN inbound_chemistry_certainties cc ON cc.code = ib.chemistry_certainty_code) c
 ORDER BY c.code;
SELECT 'output_stock_with_states', count(*) FILTER (WHERE EXISTS (SELECT 1 FROM output_batch_safety_states s WHERE s.output_batch_id = ob.id AND s.ended_at IS NULL)),
       count(*) FROM output_batches ob
 WHERE ob.deleted_at IS NULL AND (SELECT coalesce(sum(m.qty_delta), 0) FROM inventory_movements m WHERE m.output_batch_id = ob.id AND m.stock_status = 'available') > 0;
SELECT 'processable_battery_materials', count(*) FROM materials m JOIN material_kinds mk ON mk.code = m.kind_code
 WHERE m.deleted_at IS NULL AND m.may_be_processed IS TRUE;
ROLLBACK;

-- ── Part 2 ──
BEGIN READ ONLY;
\pset pager off
\pset format unaligned
SELECT 'identity', current_user, current_setting('transaction_read_only');
SELECT 'policies', tablename, cmd, policyname FROM pg_policies
 WHERE schemaname = 'public' AND tablename IN ('processing_runs','processing_inputs','processing_outputs','processing_run_losses') ORDER BY 2, 3;
SELECT 'privileges', t, has_table_privilege('authenticated', 'public.' || t, 'INSERT') AS ins,
       has_table_privilege('authenticated', 'public.' || t, 'UPDATE') AS upd, has_table_privilege('authenticated', 'public.' || t, 'DELETE') AS del
  FROM unnest(ARRAY['processing_runs','processing_inputs','processing_outputs','processing_run_losses']) t;
SELECT 'write_triggers', c.relname, t.tgname FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
 WHERE NOT t.tgisinternal AND c.relname IN ('processing_runs','processing_inputs','processing_outputs','processing_run_losses')
   AND (t.tgname LIKE '%direct%' OR t.tgname LIKE '%append_only%' OR t.tgname LIKE '%inputs_guard%') ORDER BY 2, 3;
SELECT 'pending_arms', value_code, count(*) FROM (
  SELECT 'V1' v, 1 FROM operation_types ot JOIN operation_kinds k ON k.code = ot.kind_code WHERE ot.is_active AND k.produces_outputs AND ot.balance_tolerance_pct IS NULL
  UNION ALL SELECT 'V6', 1 FROM shifts WHERE is_active AND starts_at IS NULL AND ends_at IS NULL
  UNION ALL SELECT 'V36', 1 FROM operation_type_fields f WHERE f.is_active AND f.has_range AND f.range_min IS NULL AND f.range_max IS NULL) x(value_code, one)
 GROUP BY 2 ORDER BY 2;
ROLLBACK;
