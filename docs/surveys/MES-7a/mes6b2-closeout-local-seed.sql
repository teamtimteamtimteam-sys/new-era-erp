-- LOCAL harness only (never live): data of my own. Output batch OB (lineage → three inbound leaves of mixed certainty, a final assay) to issue
-- through the app; output batch OBV (a final assay) to issue and then raise a coa_void request on, so the CFO request list has one waiting.
\set ON_ERROR_STOP 1
CREATE FUNCTION pg_temp.as_(p uuid) RETURNS void LANGUAGE sql AS $f$ SELECT set_config('request.jwt.claims', CASE WHEN p IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p) END, false) $f$;
DO $seed$
DECLARE sup uuid; mat uuid; ib1 uuid; ib2 uuid; ib3 uuid; ob uuid; obv uuid; run uuid; i uuid; d date := CURRENT_DATE; a uuid;
BEGIN
  UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;
  UPDATE ingest_settings SET require_calibrated_since = NULL;
  PERFORM set_config('evoltrya.approvals_policy_ctx', '1', false);
  UPDATE finance_settings SET approvals_enabled = true, approval_level1_role_code = 'probe-clone-cfo', approval_level2_role_code = 'probe-clone-cfo', approval_threshold_base = 1000;
  PERFORM set_config('evoltrya.approvals_policy_ctx', '', false);
  IF NOT EXISTS (SELECT 1 FROM company_profile) THEN
    INSERT INTO company_profile (legal_name, registration_no, address_lines, city, postal_code, country) VALUES ('Harness Recovery Pte. Ltd.', 'HX-UEN', '1 Harness Road', 'Singapore', '000000', 'Singapore');
  ELSE UPDATE company_profile SET legal_name = 'Harness Recovery Pte. Ltd.', registration_no = COALESCE(registration_no, 'HX-UEN'); END IF;
  INSERT INTO suppliers (code, legal_name, country, status, counterparty_type) VALUES ('ZZH-S', 'Harness supplier Pte Ltd', 'SG', 'active', 'goods_supplier') RETURNING id INTO sup;
  INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
  VALUES ('ZZH-BM', 'Harness black mass', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO mat;
  INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note, chemistry_certainty_code) VALUES
    ('ZZH-IB1', mat, sup, 100, 100, 'kg', d - 9, 'other', 'harness', 'single_known'),
    ('ZZH-IB2', mat, sup, 100, 100, 'kg', d - 9, 'other', 'harness', 'mixed'),
    ('ZZH-IB3', mat, sup, 100, 100, 'kg', d - 9, 'other', 'harness', 'single_known');
  SELECT id INTO ib1 FROM inbound_batches WHERE code = 'ZZH-IB1'; SELECT id INTO ib2 FROM inbound_batches WHERE code = 'ZZH-IB2'; SELECT id INTO ib3 FROM inbound_batches WHERE code = 'ZZH-IB3';
  INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) SELECT id, 'discharged_verified' FROM inbound_batches WHERE code LIKE 'ZZH-IB%';
  PERFORM pg_temp.as_('a0000000-0000-4000-8000-000000000001');
  ob  := (create_output_batch(mat, 100, 'kg', d - 3, p_notes => 'harness: issue through the app') ->> 'batch_id')::uuid;
  obv := (create_output_batch(mat, 100, 'kg', d - 3, p_notes => 'harness: issue, then a void request') ->> 'batch_id')::uuid;
  PERFORM pg_temp.as_(NULL);
  INSERT INTO processing_runs (code, status, allocation_basis, process_date, operation_type_code, started_at, ended_at, shift_code)
  VALUES ('ZZH-RUN', 'committed', 'weight', d - 3, 'manual_disassembly', (d - 3)::timestamptz, (d - 3)::timestamptz + interval '1 hour', 'day') RETURNING id INTO run;
  PERFORM set_config('evoltrya.movement_ctx', 'processing:' || run, false);
  FOREACH i IN ARRAY ARRAY[ib1, ib2, ib3] LOOP INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed) VALUES (run, i, 10); END LOOP;
  PERFORM set_config('evoltrya.movement_ctx', '', false);
  INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced) VALUES (run, ob, 10);
  INSERT INTO assay_results (code, output_batch_id, assay_date, is_final, weight_basis, moisture_pct, result_party, lab_name, certificate_ref)
  VALUES ('ZZH-ASY-OB', ob, d - 2, true, 'dry', 6.4, 'ours', NULL, 'HL-0001') RETURNING id INTO a;
  INSERT INTO assay_result_metals (assay_result_id, metal, content_pct) VALUES (a, 'ni', 21.5), (a, 'co', 5.2), (a, 'f', 0.0123);
  INSERT INTO assay_results (code, output_batch_id, assay_date, is_final, weight_basis, moisture_pct, result_party, lab_name, certificate_ref)
  VALUES ('ZZH-ASY-OBV', obv, d - 2, true, 'dry', 5.9, 'ours', NULL, 'HL-0002') RETURNING id INTO a;
  INSERT INTO assay_result_metals (assay_result_id, metal, content_pct) VALUES (a, 'ni', 19.0), (a, 'co', 4.8);
  RAISE NOTICE 'HARNESS|ob=%|obv=%', ob, obv;
END $seed$;
