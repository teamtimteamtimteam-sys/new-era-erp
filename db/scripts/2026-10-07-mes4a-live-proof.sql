-- db/scripts/2026-10-07-mes4a-live-proof.sql
-- MES-4a · 线上的证明 —— 【一笔事务,以 ROLLBACK 收尾】:什么都不留。审批开着,一处都不关。
--   每一步都以【真账号】跑:SET LOCAL ROLE authenticated + 那个人的 JWT(PostgREST 每一次请求做的就是这件事)。
--   用的全是【自己造的】东西(ZZ-PROBE-MES4A-* 物料 / 供应商 / 进料批 / 配方 / 一个探针参数,以及由它们生出来的加工单与称重);
--   在册的单据一张都不碰、不决定、不改;在册的加工单(14 张,含 8 张没分摊的)一张都不读写。挂机器那一步挂的是一台在册的资产卡
--   (FA-2026-0001),只在 operation_type_equipment 里加一行,资产卡本身一个字节都不动,随回滚消失。
--   ① phua@(cto,module.processing.edit):把 FA-2026-0001 挂到手工拆解上;给手工拆解定 2% 的平衡容差;给它加一个探针参数(有范围 10–20);
--      给早班定 07:00–19:00;建一个配方、写一版(探针参数 = 15)。
--   ② fusheng@(warehouse,提交 + 善后):挑一条称重(先经手工录入落一磅 60 kg)+ 敲一个重量(39 kg)提交一炉手工拆解:
--      不选机器 → 按名拒;选了 → 进;照配方、探针参数改成 25(越界,照记、标出来、与配方不同)。
--   ③ fusheng@:提交之后记一个值、更正它;记一件异常、更正它、撤回它;记一类损耗、更正它;
--      结平(余数在容差内)→ 结了;之后再更正损耗 → 平衡重新打开 → 再结。
--   ④ fusheng@:第二炉,余数 20%:不写解释结平 → 按名拒;写了 → 结了。
--   ⑤ fusheng@:抬头更正(结束时刻)→ 一行更正;
--   ⑥ fusheng@:深度放电走【页面那条路】(产出 [] · 损耗不送)→ 进,平衡"无平衡";
--   ⑦ fusheng@:开壳、极片分离各一炉(只收已放电并核实的料)。
-- 打印的每一行都是 STEP|… ;任何一处与预期不符就 RAISE,整笔回滚。跑法:psql "<pooler dsn>" -X -v ON_ERROR_STOP=1 -f 本文件
\pset pager off
\pset format unaligned
\pset tuples_only on
BEGIN;
SET LOCAL statement_timeout = '180s';

CREATE FUNCTION pg_temp.as_(p_email text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v uuid;
BEGIN
    EXECUTE 'RESET ROLE';
    SELECT id INTO v FROM auth.users WHERE email = p_email;
    IF v IS NULL THEN RAISE EXCEPTION 'MES4A_LIVE|no account %', p_email; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
END $f$;
CREATE FUNCTION pg_temp.try_(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE p_sql;
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    RETURN SQLERRM;
END $f$;
GRANT EXECUTE ON FUNCTION pg_temp.as_(text), pg_temp.try_(text) TO authenticated;

-- 一批进料(布景,以属主插 —— 与 fixture 253 同一个 helper):定价、化学确定、带一个安全状态
CREATE FUNCTION pg_temp.ib_(p_code text, p_mat uuid, p_sup uuid, p_qty numeric, p_state text, p_d date) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v uuid; v_ccy text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES (p_code, p_mat, p_sup, p_qty, p_qty, 'kg', p_d - 1, 'other', 'MES-4a live proof') RETURNING id INTO v;
    PERFORM reprice_inbound_batch(v, 1, v_ccy, NULL, 'MES-4a live proof');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) VALUES (v, p_state);
    RETURN v;
END $f$;

DO $live$
DECLARE
    d   date := (now() AT TIME ZONE 'Asia/Singapore')::date - 1;
    t0  timestamptz;
    t1  timestamptz;
    u_admin uuid := (SELECT id FROM auth.users WHERE email = 'admin@swm-os.test');
    fa  uuid := (SELECT id FROM fixed_assets WHERE code = 'FA-2026-0001');
    sup uuid; m_pack uuid; m_cell uuid; m_dec uuid; m_out uuid;
    ib1 uuid; ib2 uuid; ib3 uuid; ib4 uuid; ib5 uuid;
    rec uuid; rv uuid; w_pick uuid;
    run_a uuid; run_b uuid; run_d uuid; run_c uuid; run_e uuid;
    v_id bigint; v_id2 bigint; v_msg text; v_j jsonb; v_n int; v_txt text;
BEGIN
    t0 := (d::text || ' 09:00:00+08')::timestamptz;
    t1 := (d::text || ' 11:00:00+08')::timestamptz;
    -- 布景:供应商、四种物料、五批进料 —— 以属主插(一个真账号直连插供应商只能是 draft;送审会留一张要人决定的单据,这一刀不许留)
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_admin), true);
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ-PROBE-MES4A-S', 'MES-4a probe supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ-PROBE-MES4A-PACK', 'MES-4a probe packs', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction') RETURNING id INTO m_pack;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ-PROBE-MES4A-CELL', 'MES-4a probe cells', 'battery_material', true, 'loose_cells', 'end_of_life', 'ev_traction') RETURNING id INTO m_cell;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ-PROBE-MES4A-DEC', 'MES-4a probe de-cased cells', 'battery_material', true, 'de_cased_cell', 'end_of_life', 'ev_traction') RETURNING id INTO m_dec;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ-PROBE-MES4A-OUT', 'MES-4a probe output', 'battery_material', true, 'loose_cells', 'end_of_life', 'ev_traction') RETURNING id INTO m_out;
    ib1 := pg_temp.ib_('ZZ-PROBE-MES4A-IB1', m_pack, sup, 500, 'discharged_verified', d);
    ib2 := pg_temp.ib_('ZZ-PROBE-MES4A-IB2', m_pack, sup, 300, 'charged_not_discharged', d);
    ib3 := pg_temp.ib_('ZZ-PROBE-MES4A-IB3', m_cell, sup, 100, 'discharged_verified', d);
    ib4 := pg_temp.ib_('ZZ-PROBE-MES4A-IB4', m_dec, sup, 100, 'discharged_verified', d);
    ib5 := pg_temp.ib_('ZZ-PROBE-MES4A-IB5', m_cell, sup, 100, 'charged_not_discharged', d);   -- 7b:IB2 会被放电那一炉改成已放电,所以另起一批
    IF fa IS NULL THEN RAISE EXCEPTION 'MES4A_LIVE|FA-2026-0001 not found'; END IF;

    -- ① phua@(cto):配置手工拆解
    PERFORM pg_temp.as_('phua@evolytra.test');
    INSERT INTO operation_type_equipment (operation_type_code, fixed_asset_id) VALUES ('manual_disassembly', fa);
    UPDATE operation_types SET balance_tolerance_pct = 2 WHERE code = 'manual_disassembly';
    INSERT INTO operation_type_fields (operation_type_code, field_code, name_en, name_zh, kind, value_type, unit, has_range, range_min, range_max, sort_order)
    VALUES ('manual_disassembly', 'zz_probe_torque', 'Probe torque', '探针扭矩', 'parameter', 'number', 'Nm', true, 10, 20, 99);
    UPDATE shifts SET starts_at = '07:00', ends_at = '19:00' WHERE code = 'day';
    INSERT INTO process_recipes (operation_type_code, code, name_en, name_zh) VALUES ('manual_disassembly', 'ZZ-PROBE-MES4A-R', 'Probe recipe', '探针配方')
    RETURNING id INTO rec;
    rv := create_recipe_version(rec, '{"zz_probe_torque": 15}'::jsonb, 'MES-4a live proof');
    RAISE NOTICE 'STEP|1 phua@ linked %, tolerance %, probe field range %, day shift %, recipe version %|%',
        'FA-2026-0001', (SELECT balance_tolerance_pct FROM operation_types WHERE code = 'manual_disassembly'),
        (SELECT range_min || '–' || range_max FROM operation_type_fields WHERE field_code = 'zz_probe_torque'),
        (SELECT starts_at || '–' || ends_at FROM shifts WHERE code = 'day'),
        (SELECT version FROM process_recipe_versions WHERE id = rv), 'OK';

    -- ② fusheng@:一磅经手工录入落下(挑的那一条),然后提交
    PERFORM pg_temp.as_('fusheng@evoltrya.test');
    v_j := submit_manual_capture('weighing', '{"weight_kg": 60}'::jsonb);
    w_pick := (v_j ->> 'weighing_id')::uuid;
    RAISE NOTICE 'STEP|2a fusheng@ manual weighing to pick|% kg, status %', (SELECT weight_kg FROM run_weighing_options WHERE weighing_id = w_pick),
        (SELECT calibration_status FROM run_weighing_options WHERE weighing_id = w_pick);
    v_msg := pg_temp.try_(format($q$SELECT commit_processing_run(%L::date, 'MES-4a live proof A', NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', %L, 'unit', 'kg', 'weighing_id', %L),
                          jsonb_build_object('material_id', %L, 'unit', 'kg', 'weight_kg', 39)),
        'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day',
        p_recipe_version_id => %L)$q$, d, ib1, m_out, w_pick, m_out, t0, t1, rv));
    RAISE NOTICE 'STEP|2b fusheng@ commits without a machine|%', v_msg;
    IF v_msg NOT LIKE 'EQUIPMENT_REQUIRED_FOR_OPERATION|%' THEN RAISE EXCEPTION 'MES4A_LIVE|no machine: %', v_msg; END IF;
    run_a := commit_processing_run(d, 'MES-4a live proof A', NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', ib1, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', m_out, 'unit', 'kg', 'weighing_id', w_pick),
                          jsonb_build_object('material_id', m_out, 'unit', 'kg', 'weight_kg', 39)),
        'weight', NULL, fa, 'manual_disassembly', p_started_at => t0, p_ended_at => t1, p_shift_code => 'day',
        p_recipe_version_id => rv, p_values => '{"zz_probe_torque": 25}'::jsonb);
    SELECT to_jsonb(v) INTO v_j FROM processing_run_values_current v WHERE v.run_id = run_a AND v.field_code = 'zz_probe_torque';
    RAISE NOTICE 'STEP|2c run % committed: in %, out %, loss % · legs weighed % · probe value % (source %, out of range %, differs from recipe %)|OK',
        (SELECT code FROM processing_runs_masked WHERE id = run_a), (SELECT total_input FROM processing_runs_masked WHERE id = run_a),
        (SELECT total_output FROM processing_runs_masked WHERE id = run_a), (SELECT loss_qty FROM processing_runs_masked WHERE id = run_a),
        (SELECT count(*) FROM processing_outputs_masked WHERE run_id = run_a AND weighing_id IS NOT NULL),
        v_j ->> 'value_number', v_j ->> 'source', v_j ->> 'out_of_range', v_j ->> 'differs_from_recipe';
    IF (v_j ->> 'out_of_range')::boolean IS NOT TRUE OR (v_j ->> 'differs_from_recipe')::boolean IS NOT TRUE
       OR (SELECT count(*) FROM processing_outputs_masked WHERE run_id = run_a AND weighing_id IS NOT NULL) <> 2 THEN
        RAISE EXCEPTION 'MES4A_LIVE|run A shape: %', v_j; END IF;

    -- ③ 提交之后:值、事件、损耗、结平
    v_id := record_run_value(run_a, 'cells_out', '120'::jsonb);
    v_id2 := correct_run_value(v_id, '118'::jsonb, 'MES-4a live proof: recount');
    RAISE NOTICE 'STEP|3a fusheng@ value recorded then corrected|% (corrected %, reason "%")',
        (SELECT value_number FROM processing_run_values_current WHERE run_id = run_a AND field_code = 'cells_out'),
        (SELECT corrected FROM processing_run_values_current WHERE run_id = run_a AND field_code = 'cells_out'),
        (SELECT correction_reason FROM processing_run_values_current WHERE run_id = run_a AND field_code = 'cells_out');
    v_id := record_run_event(run_a, 'unplanned_stop', t0 + interval '30 minutes', 12, 'Cleared a jam', 'Line lead', NULL);
    v_id2 := correct_run_event(v_id, 'unplanned_stop', t0 + interval '30 minutes', 15, 'Cleared a jam', 'Line lead', NULL, false, 'MES-4a live proof: timed it');
    v_n := record_run_event(run_a, 'equipment_alarm', t0 + interval '45 minutes', NULL, 'Reset', 'Line lead', NULL);
    PERFORM correct_run_event(v_n, NULL, NULL, NULL, NULL, NULL, NULL, true, 'MES-4a live proof: false alarm');
    RAISE NOTICE 'STEP|3b fusheng@ events: % rows (% current, % withdrawn)|OK', (SELECT count(*) FROM processing_run_events WHERE run_id = run_a),
        (SELECT count(*) FROM processing_run_events e WHERE run_id = run_a AND NOT EXISTS (SELECT 1 FROM processing_run_events x WHERE x.corrects_id = e.id)),
        (SELECT count(*) FROM processing_run_events WHERE run_id = run_a AND withdrawn);
    v_msg := pg_temp.try_(format($q$SELECT record_run_event(%L, 'other', now(), 1, 'x', 'y')$q$, run_a));
    RAISE NOTICE 'STEP|3c fusheng@ records an event of kind "other"|%', v_msg;
    v_id := record_run_loss(run_a, 'sweepings', 0.5, NULL);
    v_id2 := correct_run_loss(v_id, 0.4, 'MES-4a live proof: reweighed the sweepings');
    v_msg := pg_temp.try_(format($q$UPDATE processing_run_losses SET quantity = 0.3 WHERE id = %s$q$, v_id2));
    RAISE NOTICE 'STEP|3d fusheng@ loss recorded 0.5 then corrected to %; a direct update|%',
        (SELECT quantity FROM processing_run_losses WHERE id = v_id2), v_msg;
    SELECT to_jsonb(b) INTO v_j FROM processing_run_balance b WHERE b.run_id = run_a;
    RAISE NOTICE 'STEP|3e balance before closing: state %, remainder %, tolerance %, within %|OK', v_j ->> 'balance_state', v_j ->> 'remainder_qty',
        v_j ->> 'tolerance_pct', v_j ->> 'within_tolerance';
    v_id := close_run_balance(run_a, NULL);
    RAISE NOTICE 'STEP|3f fusheng@ closes within tolerance, no explanation|state %', (SELECT balance_state FROM processing_run_balance WHERE run_id = run_a);
    PERFORM correct_run_loss(v_id2, 0.6, 'MES-4a live proof: one more bag');
    RAISE NOTICE 'STEP|3g a later loss correction reopens it|state %', (SELECT balance_state FROM processing_run_balance WHERE run_id = run_a);
    PERFORM close_run_balance(run_a, NULL);
    RAISE NOTICE 'STEP|3h closed again|state %, closures %', (SELECT balance_state FROM processing_run_balance WHERE run_id = run_a),
        (SELECT count(*) FROM processing_run_closures WHERE run_id = run_a);
    IF (SELECT balance_state FROM processing_run_balance WHERE run_id = run_a) <> 'closed' THEN RAISE EXCEPTION 'MES4A_LIVE|run A not closed'; END IF;

    -- ④ 第二炉:余数 20%
    run_b := commit_processing_run(d, 'MES-4a live proof B', NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', ib1, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', m_out, 'unit', 'kg', 'weight_kg', 80)),
        'weight', NULL, fa, 'manual_disassembly', p_started_at => t0, p_ended_at => t1, p_shift_code => 'day');
    v_msg := pg_temp.try_(format($q$SELECT close_run_balance(%L, NULL)$q$, run_b));
    RAISE NOTICE 'STEP|4a fusheng@ closes run % beyond tolerance with no explanation|%', (SELECT code FROM processing_runs_masked WHERE id = run_b), v_msg;
    IF v_msg NOT LIKE 'RUN_BALANCE_EXPLANATION_REQUIRED|%' THEN RAISE EXCEPTION 'MES4A_LIVE|beyond tolerance: %', v_msg; END IF;
    PERFORM close_run_balance(run_b, 'MES-4a live proof: 20 kg of fines went to the dust collector, not weighed this shift');
    RAISE NOTICE 'STEP|4b closed with an explanation|state %, within %, explanation kept %', (SELECT balance_state FROM processing_run_balance WHERE run_id = run_b),
        (SELECT within_tolerance FROM processing_run_closures WHERE run_id = run_b), (SELECT explanation IS NOT NULL FROM processing_run_closures WHERE run_id = run_b);

    -- ⑤ 抬头更正
    v_id := correct_run_header(run_a, 'ended_at', (t1 + interval '15 minutes')::text, 'MES-4a live proof: the card says 11:15');
    RAISE NOTICE 'STEP|5 fusheng@ corrects run A end time|% → % (%)', (SELECT old_value FROM processing_run_corrections WHERE id = v_id),
        (SELECT new_value FROM processing_run_corrections WHERE id = v_id), (SELECT reason FROM processing_run_corrections WHERE id = v_id);

    -- ⑥ 深度放电走页面那条路:产出 [],损耗不送
    run_d := commit_processing_run(d, NULL, NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', ib2, 'quantity_consumed', 300)), '[]'::jsonb, 'weight', NULL, NULL, 'deep_discharge',
        p_started_at => t0, p_ended_at => t1, p_shift_code => 'night', p_recipe_version_id => NULL, p_values => NULL, p_corrects_run_id => NULL);
    RAISE NOTICE 'STEP|6 deep discharge through the page path: run %, loss %, balance %|OK', (SELECT code FROM processing_runs_masked WHERE id = run_d),
        (SELECT loss_qty FROM processing_runs_masked WHERE id = run_d), (SELECT balance_state FROM processing_run_balance WHERE run_id = run_d);

    -- ⑦ 两道新工序
    run_c := commit_processing_run(d, 'MES-4a live proof casing', NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', ib3, 'quantity_consumed', 50)),
        jsonb_build_array(jsonb_build_object('material_id', m_dec, 'unit', 'kg', 'weight_kg', 42)),
        'weight', NULL, NULL, 'casing_removal', p_started_at => t0, p_ended_at => t1, p_shift_code => 'day');
    run_e := commit_processing_run(d, 'MES-4a live proof electrode', NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', ib4, 'quantity_consumed', 50)),
        jsonb_build_array(jsonb_build_object('material_id', m_out, 'unit', 'kg', 'weight_kg', 30)),
        'weight', NULL, NULL, 'electrode_separation', p_started_at => t0, p_ended_at => t1, p_shift_code => 'day');
    RAISE NOTICE 'STEP|7 casing removal % and electrode separation % committed; balances % / % (tolerance not set → explanation needed)|OK',
        (SELECT code FROM processing_runs_masked WHERE id = run_c), (SELECT code FROM processing_runs_masked WHERE id = run_e),
        (SELECT balance_state FROM processing_run_balance WHERE run_id = run_c), (SELECT balance_state FROM processing_run_balance WHERE run_id = run_e);
    v_msg := pg_temp.try_(format($q$SELECT commit_processing_run(%L::date, 'x', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 10)),
        jsonb_build_array(jsonb_build_object('material_id', %L, 'unit', 'kg', 'weight_kg', 5)), 'weight', NULL, NULL, 'casing_removal',
        p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day')$q$, d, ib5, m_dec, t0, t1));
    RAISE NOTICE 'STEP|7b casing removal refuses charged cells|%', v_msg;
    IF v_msg NOT LIKE 'INPUT_SAFETY_STATE_NOT_%' THEN RAISE EXCEPTION 'MES4A_LIVE|casing removal took charged material: %', v_msg; END IF;

    -- 读:提醒臂与月末那一行(以 fusheng@ 的码读提醒;月末要 finance.view,以 tim@ 读)
    RAISE NOTICE 'STEP|8a fusheng@ sees processing_balance_unclosed for %|OK',
        (SELECT string_agg(item_code, ',' ORDER BY item_code) FROM operations_now WHERE item_type = 'processing_balance_unclosed'
            AND item_id IN (run_a, run_b, run_c, run_d, run_e));
    PERFORM pg_temp.as_('tim@evoltrya.test');
    SELECT run_count || ' · ' || COALESCE(run_codes, '-') INTO v_txt FROM processing_runs_unclosed_balance(d);
    RAISE NOTICE 'STEP|8b tim@ month-end warning for %|%', d, v_txt;
    EXECUTE 'RESET ROLE';
END;
$live$;

ROLLBACK;
SELECT 'PROOF_ROLLED_BACK', (SELECT count(*) FROM materials WHERE code LIKE 'ZZ-PROBE-MES4A%'), (SELECT count(*) FROM processing_runs),
       (SELECT count(*) FROM weighings), (SELECT count(*) FROM operation_type_equipment), (SELECT count(*) FROM process_recipes),
       (SELECT COALESCE(balance_tolerance_pct::text, 'NULL') FROM operation_types WHERE code = 'manual_disassembly'),
       (SELECT COALESCE(starts_at::text, 'NULL') FROM shifts WHERE code = 'day');
