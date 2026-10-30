-- GOLIVE-2 Step 0 · 本地一年种子上:/settings/dictionaries 每一节底部那一块审计记录(record_trail(dictionary_*, 'all', 20))各要多久。
--   以种子 admin 的身份(七节字典都看得见),整笔回滚。只对本地跑。
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"7f89668d-5f83-dd1e-214a-0b451e4b09df","role":"authenticated"}', true) \g /dev/null
DO $t$
DECLARE s text; t0 timestamptz; n int; tot numeric := 0;
BEGIN
    FOREACH s IN ARRAY ARRAY['dictionary_substances','dictionary_battery_chemistries','dictionary_material_kinds','dictionary_inbound_safety_states',
        'dictionary_laboratories','dictionary_inbound_source_reasons','dictionary_nea_waste_categories','dictionary_dangerous_goods_codes',
        'dictionary_label_templates','dictionary_shifts','dictionary_processing_event_types','dictionary_cell_constructions',
        'dictionary_contamination_streams','dictionary_assay_indicators','dictionary_downtime_causes','dictionary_incident_kinds',
        'dictionary_environmental_parameters'] LOOP
        t0 := clock_timestamp();
        SELECT count(*) INTO n FROM record_trail(s, 'all', 20);
        tot := tot + extract(epoch FROM clock_timestamp()-t0)*1000;
        RAISE NOTICE 'TRAIL|% · % rows · % ms', s, n, round(extract(epoch FROM clock_timestamp()-t0)*1000);
    END LOOP;
    RAISE NOTICE 'TRAIL|total % ms', round(tot);
END $t$;
ROLLBACK;
