-- GOLIVE-2 Step 0 · /settings/dictionaries 的用量计数(page.tsx:156-162:每个字典值 × 每张引用表一次 count(*) HEAD)在库里的总成本与次数。
--   以 postgres 读(计数本身不随读者变 —— 页面的每一次计数走的是读者的 RLS,这里量的是库里的活与次数)。本地种子上跑;线上只数次数。
DO $q$
DECLARE p record; v record; n bigint; probes int := 0; t0 timestamptz := clock_timestamp(); dict_rows int := 0;
BEGIN
  FOR p IN SELECT * FROM (VALUES ('substances','assay_result_metals','metal'),('substances','blending_plan_targets','metal'),('substances','contract_grade_specs','metal'),('substances','contract_penalty_elements','substance'),('substances','contract_pricing_terms','metal'),('substances','contract_refining_charges','metal'),('substances','inbound_batch_metals','metal'),('substances','material_required_metals','metal'),('substances','metal_prices','metal'),('substances','output_batch_metals','metal'),('substances','pricing_formula_history','metal'),('substances','pricing_formula_metals','metal'),('substances','pricing_term_commitment_metals','metal'),('battery_chemistries','materials','chemistry'),('material_kinds','materials','kind_code'),('inbound_safety_states','inbound_batch_safety_states','safety_state_code'),('laboratories','assay_results','lab_name'),('inbound_source_reasons','inbound_batches','source_reason_code'),('nea_waste_categories','materials','nea_waste_category_code'),('nea_waste_categories','licence_storage_limits','category_code'),('dangerous_goods_codes','materials','dg_code'),('label_templates','label_prints','template_code'),('shifts','processing_runs','shift_code'),('shifts','shift_handovers','shift_code'),('processing_event_types','processing_run_events','event_type_code'),('cell_constructions','inbound_batches','cell_construction_code'),('cell_constructions','output_batches','cell_construction_code'),('contamination_streams','contamination_checks','stream_code'),('downtime_causes','equipment_downtime','cause_code'),('incident_kinds','incidents','kind_code'),('environmental_parameters','environmental_results','parameter_code'),('assay_indicators','assay_result_indicators','indicator')) AS x(dict, ref_table, ref_col) LOOP
    FOR v IN EXECUTE format('SELECT code FROM %I', p.dict) LOOP
      EXECUTE format('SELECT count(*) FROM %I WHERE %I = $1', p.ref_table, p.ref_col) INTO n USING v.code;
      probes := probes + 1;
    END LOOP;
  END LOOP;
  RAISE NOTICE 'DICT|% usage counts · % ms in the database', probes, round(extract(epoch FROM clock_timestamp()-t0)*1000);
END $q$;
