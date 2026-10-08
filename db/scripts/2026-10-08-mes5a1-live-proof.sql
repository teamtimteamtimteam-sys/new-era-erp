-- db/scripts/2026-10-08-mes5a1-live-proof.sql
-- MES-5a-1 · 线上的证明 —— 【一笔事务,以 ROLLBACK 收尾】:什么都不留。审批开着,一处都不关。
--   每一步都以【真账号】跑:SET LOCAL ROLE authenticated + 那个人的 JWT(PostgREST 每一次请求做的就是这件事)。
--   用的全是【自己造的】东西(ZZ-PROBE-MES5A1-* 物料 / 供应商 / 批次 / 隔离库位,以及由它们生出来的加工单、产出批、称重与回滚申请);
--   在册的单据、批次、加工单、安全状态一张都不碰、不决定、不改(PROC-2026-0494 与那两条开着的状态在最后读一遍,逐字没变)。
--   模组数、V9、隔离库位、通道分配只设在自己的东西上,只活在这一笔事务里。
--   fusheng@(warehouse)持本刀用到的每一个码:收货 · 提交 · 采集确认 · 善后 · 回滚申请 · 库存编辑;回滚由 tim@(cfo)批准(APR-7 那条路)。
--   ① 收一批电芯带模组数 2;提交一炉深度放电 → 这一批【还不是】已放电并核实(提交只记下放过电),提醒臂 discharge_unverified 出现。
--   ② 两个模组都记通过 → 已放电并核实;状态史记着是这一炉;提醒臂消失;模组数锁住。
--   ③ 第二批(3 个模组):两个通过、一个失败 · 隔离 → 不核实,提醒臂 discharge_quarantine_pending 出现;没有隔离库位 → 拆分按名拒;
--      fusheng@ 标一个自己的隔离库位;拆走那一个 → 新批同一物料、1 个模组、带电未放电、整批在隔离库位;原批核实(通过 + 拆走 = 模组数)。
--   ④ 第三批(1 个模组):失败 · 再放电 → 不核实;再放一炉,同一个模组记通过 → 最新的赢、重放次数 1、核实。
--   ⑤ 第四批 100 kg、2 个模组:只放 10 kg、只记一个通过 → 整批不核实(P1)。
--   ⑥ 第五批放电记通过之后被手工拆解用掉 50 kg;回滚那一炉放电(申请 → CFO 批准)→ 回得了,库存 50 不动、没有还原流水(P2)。
--   ⑦ 一批自产的带电模组(产出批)放电 → 库存一克没动、没有消耗流水(P3)。
-- 打印的每一行都是 STEP|… ;任何一处与预期不符就 RAISE,整笔回滚。跑法:psql "<pooler dsn>" -X -v ON_ERROR_STOP=1 -f 本文件
\pset pager off
\pset format unaligned
\pset tuples_only on
BEGIN;
SET LOCAL statement_timeout = '240s';

CREATE FUNCTION pg_temp.as_(p_email text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v uuid;
BEGIN
    EXECUTE 'RESET ROLE';
    SELECT id INTO v FROM auth.users WHERE email = p_email;
    IF v IS NULL THEN RAISE EXCEPTION 'MES5A1_LIVE|no account %', p_email; END IF;
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
CREATE FUNCTION pg_temp.run_(p_op text, p_inputs jsonb, p_outputs jsonb, p_d date, p_h0 int DEFAULT 9) RETURNS uuid LANGUAGE plpgsql AS $f$
BEGIN
    RETURN commit_processing_run(p_d, 'MES-5a-1 live proof', NULL, p_inputs, p_outputs, 'weight', NULL, NULL, p_op,
        p_started_at => (p_d::text || ' ' || lpad(p_h0::text, 2, '0') || ':00:00+08')::timestamptz,
        p_ended_at => (p_d::text || ' ' || lpad((p_h0 + 2)::text, 2, '0') || ':00:00+08')::timestamptz, p_shift_code => 'day');
END $f$;
CREATE FUNCTION pg_temp.st_(p_batch uuid) RETURNS text LANGUAGE sql AS $f$
    SELECT COALESCE(string_agg(safety_state_code, ',' ORDER BY safety_state_code), '')
      FROM (SELECT safety_state_code FROM inbound_batch_safety_states WHERE inbound_batch_id = p_batch AND ended_at IS NULL
            UNION ALL
            SELECT safety_state_code FROM output_batch_safety_states WHERE output_batch_id = p_batch AND ended_at IS NULL) s
$f$;
GRANT EXECUTE ON FUNCTION pg_temp.as_(text), pg_temp.try_(text), pg_temp.run_(text, jsonb, jsonb, date, int), pg_temp.st_(uuid) TO authenticated;

DO $live$
DECLARE
    d    date := (now() AT TIME ZONE 'Asia/Singapore')::date - 1;
    t10  timestamptz;
    t14  timestamptz;
    u_admin uuid := (SELECT id FROM auth.users WHERE email = 'admin@swm-os.test');
    sup uuid; m_mod uuid; m_cell uuid;
    b1 uuid; b2 uuid; b3 uuid; b4 uuid; b5 uuid; ob uuid; lq uuid;
    r1 uuid; r2 uuid; r3 uuid; r3b uuid; r4 uuid; r5 uuid; r5d uuid; rob uuid;
    v_j jsonb; v_msg text; v_n bigint; v_new uuid; v_split uuid; v_req uuid; v_ob_before numeric;
    p0494 text; s0494 text;
BEGIN
    t10 := (d::text || ' 10:00:00+08')::timestamptz;
    t14 := (d::text || ' 14:00:00+08')::timestamptz;
    -- 在册的那一张与那两条状态:先记下,最后逐字比
    SELECT to_jsonb(x)::text INTO p0494 FROM processing_runs x WHERE code = 'PROC-2026-0494';
    SELECT string_agg(to_jsonb(s)::text, '|' ORDER BY s::text) INTO s0494
      FROM (SELECT * FROM inbound_batch_safety_states WHERE ended_at IS NULL AND safety_state_code IN ('discharged_verified', 'charged_not_discharged')) s;
    s0494 := s0494 || '#' || COALESCE((SELECT string_agg(to_jsonb(s)::text, '|' ORDER BY s::text)
      FROM (SELECT * FROM output_batch_safety_states WHERE ended_at IS NULL AND safety_state_code IN ('discharged_verified', 'charged_not_discharged')) s), '');

    -- 布景:供应商与物料 —— 以属主插(一个真账号直连插供应商只能是 draft;送审会留一张要人决定的单据,这一刀不许留)
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_admin), true);
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ-PROBE-MES5A1-S', 'MES-5a-1 probe supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ-PROBE-MES5A1-MOD', 'MES-5a-1 probe modules', 'battery_material', true, 'module', 'end_of_life', 'ev_traction') RETURNING id INTO m_mod;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ-PROBE-MES5A1-CELL', 'MES-5a-1 probe cells', 'battery_material', true, 'loose_cells', 'end_of_life', 'ev_traction') RETURNING id INTO m_cell;
    RAISE NOTICE 'STEP|setup|probe supplier + module and cell materials';

    -- ① 收货带模组数;提交一炉放电 → 还不是已放电并核实
    PERFORM pg_temp.as_('fusheng@evoltrya.test');
    v_j := create_inbound_batch(p_material_id => m_mod, p_supplier_id => sup, p_quantity => 200, p_arrival_date => d,
                                p_source_reason_code => 'other', p_source_reason_note => 'MES-5a-1 live proof',
                                p_safety_states => ARRAY['charged_not_discharged'], p_chemistry_certainty => 'single_known', p_module_count => 2);
    b1 := (v_j ->> 'batch_id')::uuid;
    r1 := pg_temp.run_('deep_discharge', jsonb_build_array(jsonb_build_object('inbound_batch_id', b1, 'quantity_consumed', 200)), '[]'::jsonb, d);
    SELECT count(*) INTO v_n FROM operations_now WHERE item_type = 'discharge_unverified' AND item_id = r1;
    EXECUTE 'RESET ROLE';
    IF (SELECT module_count FROM inbound_batches WHERE id = b1) IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'MES5A1_LIVE|receipt module count'; END IF;
    IF pg_temp.st_(b1) <> 'charged_not_discharged' THEN RAISE EXCEPTION 'MES5A1_LIVE|commit changed the state: %', pg_temp.st_(b1); END IF;
    IF (SELECT remaining_qty FROM inbound_batches WHERE id = b1) <> 200 THEN RAISE EXCEPTION 'MES5A1_LIVE|commit took stock'; END IF;
    IF v_n <> 1 THEN RAISE EXCEPTION 'MES5A1_LIVE|discharge_unverified not listed (%)', v_n; END IF;
    RAISE NOTICE 'STEP|receive+commit|fusheng@ received % (2 modules) and committed % — state %, stock 200, discharge_unverified listed',
        (SELECT code FROM inbound_batches WHERE id = b1), (SELECT code FROM processing_runs WHERE id = r1), pg_temp.st_(b1);

    -- ② 两个模组都通过 → 核实
    PERFORM pg_temp.as_('fusheng@evoltrya.test');
    v_j := record_discharge_module_result(r1, 'inbound', b1, 'M01', 0.4, 'pass', t10, p_channel_no => 1);
    IF (v_j ->> 'verified')::boolean THEN RAISE EXCEPTION 'MES5A1_LIVE|verified after one of two'; END IF;
    v_j := record_discharge_module_result(r1, 'inbound', b1, 'M02', 0.5, 'pass', t10, p_channel_no => 2);
    SELECT count(*) INTO v_n FROM operations_now WHERE item_type = 'discharge_unverified' AND subject = (SELECT code FROM inbound_batches WHERE id = b1);
    v_msg := pg_temp.try_(format($q$SELECT set_batch_module_count('inbound', %L, 3)$q$, b1));
    EXECUTE 'RESET ROLE';
    IF NOT (v_j ->> 'verified')::boolean OR pg_temp.st_(b1) <> 'discharged_verified' THEN RAISE EXCEPTION 'MES5A1_LIVE|not verified: %', pg_temp.st_(b1); END IF;
    IF NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE inbound_batch_id = b1 AND safety_state_code = 'discharged_verified'
                     AND ended_at IS NULL AND created_by_run_id = r1) THEN RAISE EXCEPTION 'MES5A1_LIVE|history does not name the run'; END IF;
    IF v_n <> 0 THEN RAISE EXCEPTION 'MES5A1_LIVE|reminder did not clear'; END IF;
    IF v_msg NOT LIKE 'MODULE_COUNT_LOCKED|%' THEN RAISE EXCEPTION 'MES5A1_LIVE|count not locked: %', v_msg; END IF;
    RAISE NOTICE 'STEP|verify|M01 0.4 V + M02 0.5 V pass → % is %, owned by %; reminder cleared; count locked (%)',
        (SELECT code FROM inbound_batches WHERE id = b1), pg_temp.st_(b1), (SELECT code FROM processing_runs WHERE id = r1), split_part(v_msg, '|', 1);

    -- ③ 一个失败 · 隔离 → 标自己的隔离库位 → 拆出去
    PERFORM pg_temp.as_('fusheng@evoltrya.test');
    v_j := create_inbound_batch(p_material_id => m_mod, p_supplier_id => sup, p_quantity => 300, p_arrival_date => d,
                                p_source_reason_code => 'other', p_source_reason_note => 'MES-5a-1 live proof',
                                p_safety_states => ARRAY['charged_not_discharged'], p_chemistry_certainty => 'single_known', p_module_count => 3);
    b2 := (v_j ->> 'batch_id')::uuid;
    r2 := pg_temp.run_('deep_discharge', jsonb_build_array(jsonb_build_object('inbound_batch_id', b2, 'quantity_consumed', 300)), '[]'::jsonb, d);
    PERFORM record_discharge_module_result(r2, 'inbound', b2, 'M01', 0.4, 'pass', t10);
    PERFORM record_discharge_module_result(r2, 'inbound', b2, 'M02', 0.4, 'pass', t10);
    PERFORM record_discharge_module_result(r2, 'inbound', b2, 'M03', 9.0, 'fail', t10, 'quarantine', p_notes => 'MES-5a-1 live proof: swollen');
    SELECT count(*) INTO v_n FROM operations_now WHERE item_type = 'discharge_quarantine_pending' AND item_id = r2;
    v_msg := pg_temp.try_(format($q$SELECT split_failed_modules_to_quarantine(%L, 'inbound', %L, ARRAY['M03'], %L, %L, %L, 'day', NULL, 90)$q$,
        r2, b2, d, t10, t10 + interval '30 minutes'));
    EXECUTE 'RESET ROLE';
    IF pg_temp.st_(b2) <> 'charged_not_discharged' OR v_n <> 1 THEN RAISE EXCEPTION 'MES5A1_LIVE|fail/quarantine setup (% / %)', pg_temp.st_(b2), v_n; END IF;
    IF v_msg NOT LIKE 'QUARANTINE_LOCATION_REQUIRED|charged_not_discharged|unspecified%' THEN RAISE EXCEPTION 'MES5A1_LIVE|split without a location: %', v_msg; END IF;
    RAISE NOTICE 'STEP|quarantine|% M03 fail · quarantine → not verified, discharge_quarantine_pending listed; split with no quarantine location refused: %',
        (SELECT code FROM inbound_batches WHERE id = b2), v_msg;
    PERFORM pg_temp.as_('fusheng@evoltrya.test');
    INSERT INTO storage_locations (code, name, is_active, is_quarantine) VALUES ('ZZ-PROBE-MES5A1-Q', 'MES-5a-1 probe quarantine bay', true, true) RETURNING id INTO lq;
    v_j := split_failed_modules_to_quarantine(r2, 'inbound', b2, ARRAY['M03'], d, t10, t10 + interval '30 minutes', 'day', lq, 90);
    SELECT count(*) INTO v_n FROM operations_now WHERE item_type = 'discharge_quarantine_pending' AND subject = (SELECT code FROM inbound_batches WHERE id = b2);
    EXECUTE 'RESET ROLE';
    v_split := (v_j ->> 'split_run_id')::uuid;
    v_new := (v_j ->> 'batch_id')::uuid;
    IF (SELECT remaining_qty FROM inbound_batches WHERE id = b2) <> 210 THEN RAISE EXCEPTION 'MES5A1_LIVE|split mass not consumed'; END IF;
    IF (SELECT material_id FROM output_batches WHERE id = v_new) <> m_mod OR (SELECT quantity FROM output_batches WHERE id = v_new) <> 90
       OR (SELECT module_count FROM output_batches WHERE id = v_new) IS DISTINCT FROM 1 OR pg_temp.st_(v_new) <> 'charged_not_discharged' THEN
        RAISE EXCEPTION 'MES5A1_LIVE|new batch not as expected'; END IF;
    IF (SELECT COALESCE(sum(qty_delta), 0) FROM inventory_movements WHERE output_batch_id = v_new AND location_id = lq) <> 90 THEN
        RAISE EXCEPTION 'MES5A1_LIVE|new batch not in the quarantine location'; END IF;
    IF pg_temp.st_(b2) <> 'discharged_verified' OR v_n <> 0
       OR NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE inbound_batch_id = b2 AND safety_state_code = 'discharged_verified'
                        AND ended_at IS NULL AND created_by_run_id = v_split) THEN
        RAISE EXCEPTION 'MES5A1_LIVE|parent not verified by the split (%)', pg_temp.st_(b2); END IF;
    RAISE NOTICE 'STEP|split|fusheng@ marked ZZ-PROBE-MES5A1-Q and split M03 by % → % (same material, 90 kg, 1 module, %, all 90 kg in quarantine); parent % now % (2 passed + 1 split = 3)',
        v_j ->> 'split_run_code', v_j ->> 'batch_code', pg_temp.st_(v_new), (SELECT code FROM inbound_batches WHERE id = b2), pg_temp.st_(b2);

    -- ④ 再放电:最新的赢
    PERFORM pg_temp.as_('fusheng@evoltrya.test');
    v_j := create_inbound_batch(p_material_id => m_mod, p_supplier_id => sup, p_quantity => 100, p_arrival_date => d,
                                p_source_reason_code => 'other', p_source_reason_note => 'MES-5a-1 live proof',
                                p_safety_states => ARRAY['charged_not_discharged'], p_chemistry_certainty => 'single_known', p_module_count => 1);
    b3 := (v_j ->> 'batch_id')::uuid;
    r3 := pg_temp.run_('deep_discharge', jsonb_build_array(jsonb_build_object('inbound_batch_id', b3, 'quantity_consumed', 100)), '[]'::jsonb, d);
    PERFORM record_discharge_module_result(r3, 'inbound', b3, 'M01', 6.2, 'fail', t10, 're_discharge');
    EXECUTE 'RESET ROLE';
    IF pg_temp.st_(b3) <> 'charged_not_discharged' THEN RAISE EXCEPTION 'MES5A1_LIVE|re-discharge setup'; END IF;
    PERFORM pg_temp.as_('fusheng@evoltrya.test');
    r3b := pg_temp.run_('deep_discharge', jsonb_build_array(jsonb_build_object('inbound_batch_id', b3, 'quantity_consumed', 100)), '[]'::jsonb, d, 13);
    v_j := record_discharge_module_result(r3b, 'inbound', b3, 'M01', 0.3, 'pass', t14);
    EXECUTE 'RESET ROLE';
    IF pg_temp.st_(b3) <> 'discharged_verified' OR (SELECT verdict FROM discharge_module_current_all WHERE batch_id = b3 AND module_ref = 'M01') <> 'pass'
       OR (SELECT redischarge_count FROM discharge_module_current_all WHERE batch_id = b3 AND module_ref = 'M01') <> 1 THEN
        RAISE EXCEPTION 'MES5A1_LIVE|latest did not win'; END IF;
    RAISE NOTICE 'STEP|re-discharge|% M01 failed (6.2 V, re-discharge) on %, passed (0.3 V) on % → latest wins, re-discharges 1, %',
        (SELECT code FROM inbound_batches WHERE id = b3), (SELECT code FROM processing_runs WHERE id = r3), (SELECT code FROM processing_runs WHERE id = r3b), pg_temp.st_(b3);

    -- ⑤ 只放一部分 → 整批不核实(P1)
    PERFORM pg_temp.as_('fusheng@evoltrya.test');
    v_j := create_inbound_batch(p_material_id => m_mod, p_supplier_id => sup, p_quantity => 100, p_arrival_date => d,
                                p_source_reason_code => 'other', p_source_reason_note => 'MES-5a-1 live proof',
                                p_safety_states => ARRAY['charged_not_discharged'], p_chemistry_certainty => 'single_known', p_module_count => 2);
    b4 := (v_j ->> 'batch_id')::uuid;
    r4 := pg_temp.run_('deep_discharge', jsonb_build_array(jsonb_build_object('inbound_batch_id', b4, 'quantity_consumed', 10)), '[]'::jsonb, d);
    PERFORM record_discharge_module_result(r4, 'inbound', b4, 'M01', 0.4, 'pass', t10);
    EXECUTE 'RESET ROLE';
    IF pg_temp.st_(b4) <> 'charged_not_discharged' THEN RAISE EXCEPTION 'MES5A1_LIVE|P1: partial discharge verified the batch'; END IF;
    RAISE NOTICE 'STEP|P1|% 10 kg of 100 discharged, 1 of 2 modules passed → still %', (SELECT code FROM inbound_batches WHERE id = b4), pg_temp.st_(b4);

    -- ⑥ 被下游用掉一部分之后回滚放电(P2):申请 → CFO 批准
    PERFORM pg_temp.as_('fusheng@evoltrya.test');
    v_j := create_inbound_batch(p_material_id => m_mod, p_supplier_id => sup, p_quantity => 100, p_arrival_date => d,
                                p_source_reason_code => 'other', p_source_reason_note => 'MES-5a-1 live proof',
                                p_safety_states => ARRAY['charged_not_discharged'], p_chemistry_certainty => 'single_known', p_module_count => 1);
    b5 := (v_j ->> 'batch_id')::uuid;
    r5 := pg_temp.run_('deep_discharge', jsonb_build_array(jsonb_build_object('inbound_batch_id', b5, 'quantity_consumed', 100)), '[]'::jsonb, d);
    PERFORM record_discharge_module_result(r5, 'inbound', b5, 'M01', 0.4, 'pass', t10);
    r5d := pg_temp.run_('manual_disassembly', jsonb_build_array(jsonb_build_object('inbound_batch_id', b5, 'quantity_consumed', 50)),
                        jsonb_build_array(jsonb_build_object('material_id', m_cell, 'weight_kg', 50)), d, 12);
    v_j := submit_rollback_request(r5, 'MES-5a-1 live proof: discharge recorded on the wrong batch');
    v_req := (v_j ->> 'request_id')::uuid;
    -- 审批开着(线上):申请停在 submitted,由 tim@(cfo)批准才生效;审批关着(本地排练):生下来就 approved
    IF v_j ->> 'status' = 'submitted' THEN
        PERFORM pg_temp.as_('tim@evoltrya.test');
        v_j := decide_warehouse_request(v_req, true, 'MES-5a-1 live proof');
    END IF;
    EXECUTE 'RESET ROLE';
    IF (SELECT status FROM processing_runs WHERE id = r5) <> 'reversed' THEN RAISE EXCEPTION 'MES5A1_LIVE|P2: discharge not reversed'; END IF;
    IF (SELECT remaining_qty FROM inbound_batches WHERE id = b5) <> 50
       OR EXISTS (SELECT 1 FROM inventory_movements WHERE run_id = r5 AND movement_type = 'reversal_restore') THEN
        RAISE EXCEPTION 'MES5A1_LIVE|P2: stock moved on reversing a discharge'; END IF;
    RAISE NOTICE 'STEP|P2|% used 50 kg by %; fusheng@ asked to reverse discharge %, tim@ approved (%) → reversed, stock stays 50, no restore movement, state %',
        (SELECT code FROM inbound_batches WHERE id = b5), (SELECT code FROM processing_runs WHERE id = r5d), (SELECT code FROM processing_runs WHERE id = r5),
        v_j ->> 'status', pg_temp.st_(b5);

    -- ⑦ 放一批自产料(P3)
    EXECUTE 'RESET ROLE';
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, unit, output_date, state)
    VALUES ('ZZ-PROBE-MES5A1-OB', m_mod, 100, 100, 'kg', d - 1, '库存中') RETURNING id INTO ob;
    INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code) VALUES (ob, 'charged_not_discharged');
    PERFORM pg_temp.as_('fusheng@evoltrya.test');
    PERFORM set_batch_module_count('output', ob, 1);
    rob := pg_temp.run_('deep_discharge', jsonb_build_array(jsonb_build_object('output_batch_id', ob, 'quantity_consumed', 100)), '[]'::jsonb, d);
    v_j := record_discharge_module_result(rob, 'output', ob, 'M01', 0.4, 'pass', t10);
    EXECUTE 'RESET ROLE';
    IF (SELECT remaining_qty FROM output_batches WHERE id = ob) <> 100
       OR EXISTS (SELECT 1 FROM inventory_movements WHERE run_id = rob AND movement_type = 'processing_consume') THEN
        RAISE EXCEPTION 'MES5A1_LIVE|P3: a self-produced batch lost stock'; END IF;
    RAISE NOTICE 'STEP|P3|self-produced ZZ-PROBE-MES5A1-OB discharged by % → stock still 100, no consume movement, %', (SELECT code FROM processing_runs WHERE id = rob), pg_temp.st_(ob);

    -- 在册的东西逐字没变
    IF (SELECT to_jsonb(x)::text FROM processing_runs x WHERE code = 'PROC-2026-0494') IS DISTINCT FROM p0494 THEN RAISE EXCEPTION 'MES5A1_LIVE|PROC-2026-0494 changed'; END IF;
    IF (SELECT string_agg(to_jsonb(s)::text, '|' ORDER BY s::text) FROM (SELECT * FROM inbound_batch_safety_states WHERE ended_at IS NULL
            AND safety_state_code IN ('discharged_verified', 'charged_not_discharged') AND inbound_batch_id NOT IN (b1, b2, b3, b4, b5)) s)
       || '#' || COALESCE((SELECT string_agg(to_jsonb(s)::text, '|' ORDER BY s::text) FROM (SELECT * FROM output_batch_safety_states WHERE ended_at IS NULL
            AND safety_state_code IN ('discharged_verified', 'charged_not_discharged') AND output_batch_id NOT IN (ob, v_new)) s), '') IS DISTINCT FROM s0494 THEN
        RAISE EXCEPTION 'MES5A1_LIVE|a pre-existing open state changed'; END IF;
    RAISE NOTICE 'STEP|untouched|PROC-2026-0494 and the two pre-existing open states identical inside the transaction';
    RAISE NOTICE 'STEP|done|all steps as expected — rolling back';
END
$live$;

ROLLBACK;
SELECT 'AFTER|probe materials/suppliers/locations', (SELECT count(*) FROM materials WHERE code LIKE 'ZZ-PROBE-MES5A1%') || ' / '
       || (SELECT count(*) FROM suppliers WHERE code LIKE 'ZZ-PROBE-MES5A1%') || ' / ' || (SELECT count(*) FROM storage_locations WHERE code LIKE 'ZZ-PROBE-MES5A1%');
SELECT 'AFTER|results/channels/splits', (SELECT count(*) FROM discharge_module_results) || ' / ' || (SELECT count(*) FROM discharge_channel_assignments)
       || ' / ' || (SELECT count(*) FROM discharge_module_splits);
SELECT 'AFTER|module counts / V9 / quarantine locations', ((SELECT count(*) FROM inbound_batches WHERE module_count IS NOT NULL) + (SELECT count(*) FROM output_batches WHERE module_count IS NOT NULL))
       || ' / ' || (SELECT count(*) FROM materials WHERE discharge_pass_voltage_v IS NOT NULL) || ' / ' || (SELECT count(*) FROM storage_locations WHERE is_quarantine);
SELECT 'AFTER|pending documents', (SELECT count(*) FROM approval_pending_documents());
