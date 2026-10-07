-- db/scripts/2026-10-07-mes4b-live-proof.sql
-- MES-4b · 线上的证明 —— 【一笔事务,以 ROLLBACK 收尾】:什么都不留。审批开着,一处都不关。
--   每一步都以【真账号】跑:SET LOCAL ROLE authenticated + 那个人的 JWT(PostgREST 每一次请求做的就是这件事)。
--   用的全是【自己造的】东西(ZZ-PROBE-MES4B-* 物料 / 供应商 / 进料批,以及由它们生出来的加工单、产出批与称重);
--   在册的单据、批次、加工单一张都不碰、不决定、不改。工序与流的两处设定(勾电解液挥发、给份额、给警戒线)只在这一笔事务里,随回滚消失。
--   ① fusheng@(warehouse):收一批电芯带结构(卷绕),收一批不带;在批次页那条路上(set_batch_cell_construction)给没带的那一批补上。
--   ② fusheng@:极片分离 —— 一批记成"未知"的已开壳电芯按名拒;卷绕的那一批进;开壳一炉两批卷绕电芯 → 已开壳电芯继承卷绕;
--      喂过之后改那一批的结构 → 锁(CELL_CONSTRUCTION_LOCKED)。
--   ③ fusheng@:每一种新形态各一种物料:极片粉料线一炉出 CPW · APW · CUF · ALF · DST;开壳出 CEL;另验 CTS · ANS · OUT。
--   ④ phua@(cto,module.processing.edit):在极片分离上勾「Electrolyte evaporates in this step」、给份额 12.5%。
--      fusheng@:结平 → 记一笔算出来的电解液挥发 → 那一炉重新打开 → 再结 → 改成量出来的 → 又重新打开。
--   ⑤ phua@:给正极流一条警戒线 1%;fusheng@:正极抽检 2% → 标出来;负极那一格在提醒里 → 记"没抽 + 理由" → 提醒消失。
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
    IF v IS NULL THEN RAISE EXCEPTION 'MES4B_LIVE|no account %', p_email; END IF;
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

-- 一批进料(布景,以属主插 —— 与 fixture 254 同一个 helper):定价、化学确定、带一个安全状态、可选一个结构
CREATE FUNCTION pg_temp.ib_(p_code text, p_mat uuid, p_sup uuid, p_qty numeric, p_state text, p_d date, p_cc text DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v uuid; v_ccy text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note,
                                 cell_construction_code)
    VALUES (p_code, p_mat, p_sup, p_qty, p_qty, 'kg', p_d - 1, 'other', 'MES-4b live proof', p_cc) RETURNING id INTO v;
    PERFORM reprice_inbound_batch(v, 1, v_ccy, NULL, 'MES-4b live proof');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v;
    IF p_state IS NOT NULL THEN INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) VALUES (v, p_state); END IF;
    RETURN v;
END $f$;
GRANT EXECUTE ON FUNCTION pg_temp.ib_(text, uuid, uuid, numeric, text, date, text) TO authenticated;

CREATE FUNCTION pg_temp.run_(p_op text, p_inputs jsonb, p_outputs jsonb, p_d date) RETURNS uuid LANGUAGE plpgsql AS $f$
BEGIN
    RETURN commit_processing_run(p_d, 'MES-4b live proof', NULL, p_inputs, p_outputs, 'weight', NULL, NULL, p_op,
        p_started_at => (p_d::text || ' 09:00:00+08')::timestamptz, p_ended_at => (p_d::text || ' 11:00:00+08')::timestamptz, p_shift_code => 'day');
END $f$;
GRANT EXECUTE ON FUNCTION pg_temp.run_(text, jsonb, jsonb, date) TO authenticated;

DO $live$
DECLARE
    d   date := (now() AT TIME ZONE 'Asia/Singapore')::date - 1;
    y   text := EXTRACT(YEAR FROM now())::text;
    u_admin uuid := (SELECT id FROM auth.users WHERE email = 'admin@swm-os.test');
    sup uuid; m_cell uuid; m_dec uuid; m_cts uuid; m_ans uuid; m_scrap uuid; m_bm uuid;
    m_cpw uuid; m_apw uuid; m_cuf uuid; m_alf uuid; m_dst uuid; m_hbb uuid;
    ib_w uuid; ib_none uuid; ib_unk uuid; ib_dw uuid; ib_c1 uuid; ib_c2 uuid; ib_scrap uuid;
    run_sep uuid; run_cas uuid; run_pow uuid;
    v_id bigint; v_id2 bigint; v_msg text; v_j jsonb; v_n int; v_txt text; v_ob uuid; r record;
BEGIN
    -- 布景:供应商与物料 —— 以属主插(一个真账号直连插供应商只能是 draft;送审会留一张要人决定的单据,这一刀不许留)
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_admin), true);
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ-PROBE-MES4B-S', 'MES-4b probe supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ-PROBE-MES4B-CELL', 'MES-4b probe cells', 'battery_material', true, 'loose_cells', 'end_of_life', 'ev_traction') RETURNING id INTO m_cell;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ-PROBE-MES4B-DEC', 'MES-4b probe de-cased cells', 'battery_material', true, 'de_cased_cell', 'end_of_life', 'ev_traction') RETURNING id INTO m_dec;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ-PROBE-MES4B-CTS', 'MES-4b probe cathode sheet', 'battery_material', true, 'cathode_sheet', 'end_of_life') RETURNING id INTO m_cts;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ-PROBE-MES4B-ANS', 'MES-4b probe anode sheet', 'battery_material', true, 'anode_sheet', 'end_of_life') RETURNING id INTO m_ans;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ-PROBE-MES4B-SCRAP', 'MES-4b probe electrode scrap', 'battery_material', true, 'electrode_scrap', 'end_of_life') RETURNING id INTO m_scrap;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ-PROBE-MES4B-BM', 'MES-4b probe black mass', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO m_bm;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ-PROBE-MES4B-CPW', 'MES-4b probe cathode powder', 'battery_material', true, 'cathode_powder', 'end_of_life') RETURNING id INTO m_cpw;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ-PROBE-MES4B-APW', 'MES-4b probe anode powder', 'battery_material', true, 'anode_powder', 'end_of_life') RETURNING id INTO m_apw;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ-PROBE-MES4B-CUF', 'MES-4b probe copper foil', 'battery_material', true, 'copper_foil', 'end_of_life') RETURNING id INTO m_cuf;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ-PROBE-MES4B-ALF', 'MES-4b probe aluminium foil', 'battery_material', true, 'aluminium_foil', 'end_of_life') RETURNING id INTO m_alf;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ-PROBE-MES4B-DST', 'MES-4b probe collected dust', 'battery_material', true, 'collected_dust', 'end_of_life') RETURNING id INTO m_dst;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ-PROBE-MES4B-HBB', 'MES-4b probe harness / BMS / busbar', 'battery_material', true, 'harness_bms_busbar', 'end_of_life') RETURNING id INTO m_hbb;
    RAISE NOTICE 'STEP|setup|supplier + 13 probe materials (one of each new form)';

    -- ① 收货带结构 / 不带;在批次页那条路上补
    PERFORM pg_temp.as_('fusheng@evoltrya.test');
    v_j := create_inbound_batch(p_material_id => m_cell, p_supplier_id => sup, p_quantity => 100, p_arrival_date => d,
                                p_source_reason_code => 'other', p_source_reason_note => 'MES-4b live proof', p_cell_construction => 'wound');
    ib_w := (v_j ->> 'batch_id')::uuid;
    v_j := create_inbound_batch(p_material_id => m_cell, p_supplier_id => sup, p_quantity => 100, p_arrival_date => d,
                                p_source_reason_code => 'other', p_source_reason_note => 'MES-4b live proof');
    ib_none := (v_j ->> 'batch_id')::uuid;
    EXECUTE 'RESET ROLE';
    IF (SELECT cell_construction_code FROM inbound_batches WHERE id = ib_w) IS DISTINCT FROM 'wound'
       OR (SELECT cell_construction_code FROM inbound_batches WHERE id = ib_none) IS NOT NULL THEN
        RAISE EXCEPTION 'MES4B_LIVE|receipt construction not as expected'; END IF;
    RAISE NOTICE 'STEP|receipt|fusheng@ received % with wound and % with none', (SELECT code FROM inbound_batches WHERE id = ib_w), (SELECT code FROM inbound_batches WHERE id = ib_none);
    PERFORM pg_temp.as_('fusheng@evoltrya.test');
    PERFORM set_batch_cell_construction('inbound', ib_none, 'stacked');
    EXECUTE 'RESET ROLE';
    IF (SELECT cell_construction_code FROM inbound_batches WHERE id = ib_none) IS DISTINCT FROM 'stacked' THEN
        RAISE EXCEPTION 'MES4B_LIVE|set later failed'; END IF;
    RAISE NOTICE 'STEP|batch page|fusheng@ set the missing one to stacked (set_batch_cell_construction)';

    -- ② 极片分离:未知拒,卷绕进;开壳继承;锁
    EXECUTE 'RESET ROLE';
    ib_unk := pg_temp.ib_('ZZ-PROBE-MES4B-IB-UNK', m_dec, sup, 100, 'discharged_verified', d, 'unknown');
    ib_dw  := pg_temp.ib_('ZZ-PROBE-MES4B-IB-DW', m_dec, sup, 100, 'discharged_verified', d, 'wound');
    ib_c1  := pg_temp.ib_('ZZ-PROBE-MES4B-IB-C1', m_cell, sup, 100, 'discharged_verified', d, 'wound');
    ib_c2  := pg_temp.ib_('ZZ-PROBE-MES4B-IB-C2', m_cell, sup, 100, 'discharged_verified', d, 'wound');
    ib_scrap := pg_temp.ib_('ZZ-PROBE-MES4B-IB-SCRAP', m_scrap, sup, 200, 'discharged_verified', d);
    PERFORM pg_temp.as_('fusheng@evoltrya.test');
    v_msg := pg_temp.try_(format($q$SELECT pg_temp.run_('electrode_separation', jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 50)),
        jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 20)), %L::date)$q$, ib_unk, m_cts, d));
    IF v_msg NOT LIKE 'INPUT_CELL_CONSTRUCTION_REQUIRED|ZZ-PROBE-MES4B-IB-UNK%' THEN RAISE EXCEPTION 'MES4B_LIVE|unknown construction not refused: %', v_msg; END IF;
    RAISE NOTICE 'STEP|separation|unknown construction refused: %', v_msg;
    run_sep := pg_temp.run_('electrode_separation', jsonb_build_array(jsonb_build_object('inbound_batch_id', ib_dw, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', m_cts, 'weight_kg', 40), jsonb_build_object('material_id', m_ans, 'weight_kg', 30)), d);
    run_cas := pg_temp.run_('casing_removal', jsonb_build_array(jsonb_build_object('inbound_batch_id', ib_c1, 'quantity_consumed', 50),
        jsonb_build_object('inbound_batch_id', ib_c2, 'quantity_consumed', 50)), jsonb_build_array(jsonb_build_object('material_id', m_dec, 'weight_kg', 80)), d);
    EXECUTE 'RESET ROLE';
    SELECT ob.code, ob.cell_construction_code INTO v_txt, v_msg FROM processing_outputs po JOIN output_batches ob ON ob.id = po.output_batch_id WHERE po.run_id = run_cas;
    IF v_msg IS DISTINCT FROM 'wound' OR v_txt !~ ('^CEL-' || y || '-[0-9]{5}$') THEN RAISE EXCEPTION 'MES4B_LIVE|inheritance/CEL not as expected: % %', v_txt, v_msg; END IF;
    RAISE NOTICE 'STEP|separation|% committed on wound input; casing removal % → % inherits wound', (SELECT code FROM processing_runs WHERE id = run_sep),
        (SELECT code FROM processing_runs WHERE id = run_cas), v_txt;
    PERFORM pg_temp.as_('fusheng@evoltrya.test');
    v_msg := pg_temp.try_(format($q$SELECT set_batch_cell_construction('inbound', %L, 'stacked')$q$, ib_dw));
    EXECUTE 'RESET ROLE';
    IF v_msg NOT LIKE 'CELL_CONSTRUCTION_LOCKED|%' THEN RAISE EXCEPTION 'MES4B_LIVE|lock missing: %', v_msg; END IF;
    RAISE NOTICE 'STEP|lock|%', v_msg;

    -- ③ 每一种新形态的号
    PERFORM pg_temp.as_('fusheng@evoltrya.test');
    run_pow := pg_temp.run_('electrode_powder_line', jsonb_build_array(jsonb_build_object('inbound_batch_id', ib_scrap, 'quantity_consumed', 200)),
        jsonb_build_array(jsonb_build_object('material_id', m_cpw, 'weight_kg', 60), jsonb_build_object('material_id', m_apw, 'weight_kg', 50),
                          jsonb_build_object('material_id', m_cuf, 'weight_kg', 30), jsonb_build_object('material_id', m_alf, 'weight_kg', 20),
                          jsonb_build_object('material_id', m_dst, 'weight_kg', 5), jsonb_build_object('material_id', m_bm, 'weight_kg', 10)), d);
    EXECUTE 'RESET ROLE';
    FOR r IN SELECT ob.code, m.code AS mat FROM processing_outputs po JOIN output_batches ob ON ob.id = po.output_batch_id
               JOIN materials m ON m.id = ob.material_id WHERE po.run_id IN (run_pow, run_sep, run_cas) ORDER BY ob.code LOOP
        RAISE NOTICE 'STEP|codes|% ← %', r.code, r.mat;
    END LOOP;
    SELECT string_agg(left(ob.code, 3), ',' ORDER BY left(ob.code, 3)) INTO v_txt FROM processing_outputs po JOIN output_batches ob ON ob.id = po.output_batch_id
     WHERE po.run_id IN (run_pow, run_sep, run_cas);
    IF v_txt IS DISTINCT FROM 'ALF,ANS,APW,CEL,CPW,CTS,CUF,DST,OUT' THEN RAISE EXCEPTION 'MES4B_LIVE|prefixes not as expected: %', v_txt; END IF;
    IF EXISTS (SELECT 1 FROM processing_outputs po JOIN output_batches ob ON ob.id = po.output_batch_id WHERE po.run_id IN (run_pow, run_sep, run_cas)
                 AND left(ob.code, 3) <> 'OUT' AND ob.code !~ ('^[A-Z]{3}-' || y || '-[0-9]{5}$')) THEN
        RAISE EXCEPTION 'MES4B_LIVE|a new prefix code is not five digits'; END IF;

    -- ④ 电解液:勾、给份额;结平 → 算一笔 → 重开 → 再结 → 改成量出来的 → 重开
    PERFORM pg_temp.as_('phua@evolytra.test');
    v_msg := pg_temp.try_($q$UPDATE operation_types SET electrolyte_loss_applies = true, electrolyte_share_pct = 12.5 WHERE code = 'electrode_separation'$q$);
    EXECUTE 'RESET ROLE';
    IF v_msg <> 'OK' OR NOT (SELECT electrolyte_loss_applies FROM operation_types WHERE code = 'electrode_separation') THEN
        RAISE EXCEPTION 'MES4B_LIVE|phua could not tick electrolyte: %', v_msg; END IF;
    RAISE NOTICE 'STEP|electrolyte|phua@ ticked "Electrolyte evaporates in this step" on electrode separation, share 12.5%%';
    PERFORM pg_temp.as_('fusheng@evoltrya.test');
    PERFORM close_run_balance(run_sep, 'MES-4b live proof: closing before the electrolyte loss is recorded');
    EXECUTE 'RESET ROLE';
    IF (SELECT balance_state FROM processing_run_balance_all WHERE run_id = run_sep) <> 'closed' THEN RAISE EXCEPTION 'MES4B_LIVE|not closed'; END IF;
    PERFORM pg_temp.as_('fusheng@evoltrya.test');
    v_id := record_derived_electrolyte_loss(run_sep, 'MES-4b live proof');
    EXECUTE 'RESET ROLE';
    SELECT quantity, basis INTO v_j, v_txt FROM (SELECT to_jsonb(quantity) AS quantity, basis FROM processing_run_losses WHERE id = v_id) x;
    IF (v_j #>> '{}')::numeric <> 12.5 OR v_txt <> 'derived' OR (SELECT balance_state FROM processing_run_balance_all WHERE run_id = run_sep) <> 'open' THEN
        RAISE EXCEPTION 'MES4B_LIVE|derived loss / reopen not as expected'; END IF;
    RAISE NOTICE 'STEP|electrolyte|fusheng@ derived 12.5 kg (12.5%% × 100 kg), basis derived; the closed run reopened (state %)',
        (SELECT balance_state FROM processing_run_balance_all WHERE run_id = run_sep);
    PERFORM pg_temp.as_('fusheng@evoltrya.test');
    PERFORM close_run_balance(run_sep, 'MES-4b live proof: closing with the calculated electrolyte loss');
    v_id2 := correct_run_loss(v_id, 11, 'MES-4b live proof: weighed at the duct');
    EXECUTE 'RESET ROLE';
    IF (SELECT basis FROM processing_run_losses WHERE id = v_id2) <> 'measured'
       OR (SELECT balance_state FROM processing_run_balance_all WHERE run_id = run_sep) <> 'open' THEN
        RAISE EXCEPTION 'MES4B_LIVE|switch to measured / reopen not as expected'; END IF;
    RAISE NOTICE 'STEP|electrolyte|closed again, corrected to measured 11 kg (reason kept); reopened again (state %)',
        (SELECT balance_state FROM processing_run_balance_all WHERE run_id = run_sep);

    -- ⑤ 交叉污染:警戒线、超线标出、没抽 + 理由清掉提醒
    PERFORM pg_temp.as_('fusheng@evoltrya.test');
    SELECT count(*) INTO v_n FROM operations_now WHERE item_type = 'contamination_check_missing' AND item_id = run_sep;
    EXECUTE 'RESET ROLE';
    IF v_n <> 2 THEN RAISE EXCEPTION 'MES4B_LIVE|expected the reminder for both streams, got %', v_n; END IF;
    RAISE NOTICE 'STEP|contamination|reminder shows % rows for % (both streams)', v_n, (SELECT code FROM processing_runs WHERE id = run_sep);
    PERFORM pg_temp.as_('phua@evolytra.test');
    v_msg := pg_temp.try_($q$UPDATE contamination_streams SET warning_pct = 1 WHERE code = 'cathode'$q$);
    EXECUTE 'RESET ROLE';
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'MES4B_LIVE|phua could not set V11: %', v_msg; END IF;
    SELECT po.output_batch_id INTO v_ob FROM processing_outputs po JOIN output_batches ob ON ob.id = po.output_batch_id WHERE po.run_id = run_sep AND ob.material_id = m_cts;
    PERFORM pg_temp.as_('fusheng@evoltrya.test');
    v_id := record_contamination_check(run_sep, 'cathode', 'sampled', v_ob, 100, 2, (d::text || ' 10:00:00+08')::timestamptz, 'sieve');
    EXECUTE 'RESET ROLE';
    IF (SELECT above_warning FROM contamination_checks WHERE id = v_id) IS NOT TRUE THEN RAISE EXCEPTION 'MES4B_LIVE|not flagged'; END IF;
    RAISE NOTICE 'STEP|contamination|phua@ set the cathode warning level 1%%; fusheng@ checked 2%% → flagged above (never refused)';
    PERFORM pg_temp.as_('fusheng@evoltrya.test');
    PERFORM record_contamination_check(run_sep, 'anode', 'not_sampled', p_not_sampled_reason => 'MES-4b live proof: sampler absent');
    SELECT count(*) INTO v_n FROM operations_now WHERE item_type = 'contamination_check_missing' AND item_id = run_sep;
    EXECUTE 'RESET ROLE';
    IF v_n <> 0 THEN RAISE EXCEPTION 'MES4B_LIVE|reminder did not clear (% rows)', v_n; END IF;
    RAISE NOTICE 'STEP|contamination|anode not sampled with a reason → reminder cleared (0 rows)';

    RAISE NOTICE 'STEP|done|all steps as expected — rolling back';
END
$live$;

ROLLBACK;
SELECT 'AFTER|probe materials', count(*) FROM materials WHERE code LIKE 'ZZ-PROBE-MES4B%';
SELECT 'AFTER|electrolyte flags', count(*) FROM operation_types WHERE electrolyte_loss_applies OR electrolyte_share_pct IS NOT NULL;
SELECT 'AFTER|warning levels', count(*) FROM contamination_streams WHERE warning_pct IS NOT NULL;
SELECT 'AFTER|contamination checks', count(*) FROM contamination_checks;
SELECT 'AFTER|batches with construction', (SELECT count(*) FROM inbound_batches WHERE cell_construction_code IS NOT NULL) + (SELECT count(*) FROM output_batches WHERE cell_construction_code IS NOT NULL);
