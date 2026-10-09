-- 254 MES-4b:一批电芯说出它是卷绕还是叠片;一种产品有它自己的批号前缀;一笔损耗说出它是量出来的还是算出来的;
--     交叉污染按班抽检,一个班没抽要被提醒(MES-4b Step 0 Q1–Q34,Q9 与 Q17 按 Tim 改过的;v1.4.42)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】一臂一组裁定;每一臂都有故障注入(db/scripts/2026-10-07-mes4b-fixture-injections.py)必须让它红在它点名的那一臂。
--   CC     电芯结构:收货时给(两支收货函数末尾的参数)· 之后在批次页给(set_batch_cell_construction)· 非电芯形态拒 · 不认识的拒 ·
--          没有形态的物料不拦 · 极片分离与自动极片线的投料没记 / unknown 拒(INPUT_CELL_CONSTRUCTION_REQUIRED)·
--          投料一致 → 装电芯的产出继承,不一致或有一批没记 → 空 · 喂过一张已提交的单之后锁住(函数与直连两条路)· 没码的人改不了(Q3–Q8)
--   FORM   六种新形态都在、都不装电芯;可售性按 Tim 改过的 Q9:收集的粉尘卖不了、负极粉卖得了(Q9)
--   NUM    每一种映射了的形态铸它自己的前缀、五位;没映射的形态与没有形态的物料仍是 OUT、四位;一条从不重置的序列推过 9,999 不截断
--          (OUT 与 IN 两支);低于 10,000 的号逐字不变;旧的 OUT- 号与新前缀的号都只在它自己那一种单据下搜得到;登记表 55 行(Q12–Q15)
--   LOSS   record_run_loss 写 measured;算出来的电解液挥发 = 份额 × 投入,抄下份额;没份额 · 没勾 · 状态改变型 · 超过 投入 − 产出 ·
--          已经记过 · 没有 aftercare 各自按名拒;重新算与改成量出来的两种更正;结过平的一炉被新的一笔重开;平衡视图报出算出来的那一截(Q16–Q20)
--   CONT   一次抽检 · 一次更正 · 一条"没抽"带理由(没有理由拒)· 超过警戒线标出来、没给线判不了;提醒臂出现、被抽检关掉、被"没抽"关掉;
--          MES-4a 之前的单 · 不是这一炉极片的批 · 质量不对各自按名拒;没码的人记不了(Q21–Q26)
--   DUST   收集的粉尘是一条普通的称重产出腿,前缀 DST,进投入 / 产出的平衡,没有库位(Q27)
--   PV     V10(勾了电解液挥发而没给份额的工序)· V11(没给警戒线的流)(Q29)
--
-- 自带数据(README 第 2 条)。以 postgres 跑(绕过 RLS);员工的调用真的切成 authenticated + 那个人的 JWT。日期 = 昨天(新加坡),
-- 一炉从 09:00 跑到 11:00(一炉不许记在将来)。【序列】NUM 臂推了 output_code_seq 与 inbound_code_seq,结束前按原值放回去
-- (setval 不随事务回滚)—— 后面的 fixture 看到的序列与这一支跑之前一样。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f254_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

-- 跑一句:成功回 'OK'(改动留着),失败回错误原文(那一句的改动随子事务撤掉)。p_auth = 切成 authenticated 跑
CREATE FUNCTION pg_temp.f254_do(p_sql text, p_auth boolean DEFAULT true) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    IF p_auth THEN EXECUTE 'SET LOCAL ROLE authenticated'; END IF;
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN SQLERRM;
END;
$f$;

-- 一批进料:定价、化学确定、带一个安全状态、可选一个电芯结构(直写,以 postgres 跑)
CREATE FUNCTION pg_temp.f254_ib(p_code text, p_mat uuid, p_sup uuid, p_qty numeric, p_state text, p_d date, p_cc text DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v uuid; v_ccy text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note,
                                 cell_construction_code)
    VALUES (p_code, p_mat, p_sup, p_qty, p_qty, 'kg', p_d - 1, 'other', 'fixture 254 自带数据', p_cc) RETURNING id INTO v;
    PERFORM reprice_inbound_batch(v, 1, v_ccy, NULL, 'f254');
    -- 到货状态只对电池料成立(电子废料一类没有)
    IF (SELECT mk.has_condition_axes FROM materials m JOIN material_kinds mk ON mk.code = m.kind_code WHERE m.id = p_mat) THEN
        UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v;
    END IF;
    IF p_state IS NOT NULL THEN
        INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) VALUES (v, p_state);
    END IF;
    RETURN v;
END;
$f$;

-- 提交一炉(以当前的 JWT、authenticated 跑);返回 run id,失败抛原文
CREATE FUNCTION pg_temp.f254_run(p_op text, p_inputs jsonb, p_outputs jsonb, p_d date, p_shift text DEFAULT 'day') RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v uuid;
BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    v := commit_processing_run(p_d, 'f254', NULL, p_inputs, p_outputs, 'weight', NULL, NULL, p_op,
                               p_started_at => p_d::timestamptz + interval '9 hours', p_ended_at => p_d::timestamptz + interval '11 hours',
                               p_shift_code => p_shift);
    EXECUTE 'RESET ROLE';
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RAISE;
END;
$f$;

CREATE FUNCTION pg_temp.f254_in(p_ib uuid, p_q numeric) RETURNS jsonb
LANGUAGE sql AS $f$ SELECT jsonb_build_object('inbound_batch_id', p_ib, 'quantity_consumed', p_q) $f$;
CREATE FUNCTION pg_temp.f254_out(p_mat uuid, p_kg numeric) RETURNS jsonb
LANGUAGE sql AS $f$ SELECT jsonb_build_object('material_id', p_mat, 'weight_kg', p_kg) $f$;

DO $$
DECLARE
    u_all   uuid := gen_random_uuid();   -- 全部码
    u_view  uuid := gen_random_uuid();   -- 只看加工
    u_out   uuid := gen_random_uuid();   -- 只看产出
    r_all uuid; r_view uuid; r_out uuid;
    d   date := CURRENT_DATE - 1;
    d2  date := CURRENT_DATE - 2;
    v_year text := EXTRACT(YEAR FROM NOW())::text;
    v_sup uuid;
    m_cell uuid; m_dec uuid; m_mod uuid; m_cts uuid; m_ans uuid; m_sep uuid; m_bm uuid; m_ew uuid; m_dust uuid; m_scrap uuid;
    m_form uuid;
    ib1 uuid; ib2 uuid; ib3 uuid; ib4 uuid; ib5 uuid; ib6 uuid; ib7 uuid; ib8 uuid;
    run uuid; run_sep uuid; run_cas uuid; run_dis uuid; run_old uuid; run_c1 uuid; run_c2 uuid; run_dust uuid;
    v_msg text; v_n int; v_num numeric; v_txt text; v_b boolean; v_j jsonb; v_code text; v_id bigint; v_id2 bigint; v_ob uuid;
    v_seq_out_last bigint; v_seq_out_called boolean; v_seq_in_last bigint; v_seq_in_called boolean;
    r record;
    MAP constant text[][] := ARRAY[
        ['cathode_powder','CPW'], ['anode_powder','APW'], ['copper_foil','CUF'], ['aluminium_foil','ALF'],
        ['separator','SEP'], ['collected_dust','DST'], ['loose_cells','CEL'], ['de_cased_cell','CEL'],
        ['casing','CSG'], ['structural_parts','STR'], ['harness_bms_busbar','HBB'], ['cathode_sheet','CTS'], ['anode_sheet','ANS']];
BEGIN
    UPDATE finance_settings SET locked_before = NULL;
    SELECT last_value, is_called INTO v_seq_out_last, v_seq_out_called FROM output_code_seq;
    SELECT last_value, is_called INTO v_seq_in_last, v_seq_in_called FROM inbound_code_seq;
    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES
        (u_all, 'fx254-all@test.local', now(), now()), (u_view, 'fx254-view@test.local', now(), now()),
        (u_out, 'fx254-out@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx254-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx254-view', 'f', 'f', true) RETURNING id INTO r_view;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx254-out', 'f', 'f', true) RETURNING id INTO r_out;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_view, 'module.processing.view'), (r_out, 'module.output.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_all, r_all), (u_view, r_view), (u_out, r_out);
    PERFORM pg_temp.f254_as(u_all);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ254-S', 'f254 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ254-CELL', 'f254 cells', 'battery_material', true, 'loose_cells', 'end_of_life', 'ev_traction') RETURNING id INTO m_cell;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ254-DEC', 'f254 de-cased cells', 'battery_material', true, 'de_cased_cell', 'end_of_life', 'ev_traction') RETURNING id INTO m_dec;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ254-MOD', 'f254 modules', 'battery_material', true, 'module', 'end_of_life', 'ev_traction') RETURNING id INTO m_mod;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ254-CTS', 'f254 cathode sheet', 'battery_material', true, 'cathode_sheet', 'end_of_life') RETURNING id INTO m_cts;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ254-ANS', 'f254 anode sheet', 'battery_material', true, 'anode_sheet', 'end_of_life') RETURNING id INTO m_ans;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ254-SEP', 'f254 separator', 'battery_material', true, 'separator', 'end_of_life') RETURNING id INTO m_sep;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ254-BM', 'f254 black mass', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO m_bm;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ254-DUST', 'f254 collected dust', 'battery_material', true, 'collected_dust', 'end_of_life') RETURNING id INTO m_dust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ254-SCRAP', 'f254 electrode scrap', 'battery_material', true, 'electrode_scrap', 'end_of_life') RETURNING id INTO m_scrap;
    INSERT INTO materials (code, name, kind_code, may_be_processed) VALUES
        ('ZZ254-EW', 'f254 e-waste (no form)', 'ewaste', true) RETURNING id INTO m_ew;

    -- ══════════════ CC · 电芯结构 ══════════════
    RAISE NOTICE 'fixture 254 · CC';
    IF (SELECT string_agg(code || ':' || is_determined::text, ',' ORDER BY sort_order) FROM cell_constructions)
       IS DISTINCT FROM 'wound:true,stacked:true,unknown:false' THEN
        RAISE EXCEPTION 'FIXTURE 254 CC: cell_constructions should be wound / stacked (determined) and unknown (not)'; END IF;
    IF (SELECT string_agg(code, ',' ORDER BY code) FROM operation_types WHERE requires_cell_construction)
       IS DISTINCT FROM 'electrode_line,electrode_separation' THEN
        RAISE EXCEPTION 'FIXTURE 254 CC: requires_cell_construction should be on electrode_line and electrode_separation only'; END IF;
    -- 收货时给(create_inbound_batch 末尾的参数)
    v_msg := pg_temp.f254_do(format($q$SELECT set_config('f254.ib', (create_inbound_batch(p_material_id => %L, p_supplier_id => %L, p_quantity => 10,
        p_arrival_date => %L, p_source_reason_code => 'other', p_source_reason_note => 'f254', p_cell_construction => 'wound') ->> 'batch_id'), true)$q$,
        m_cell, v_sup, d));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 254 CC: receipt with a construction should work, got %', v_msg; END IF;
    IF (SELECT cell_construction_code FROM inbound_batches WHERE id = current_setting('f254.ib')::uuid) IS DISTINCT FROM 'wound' THEN
        RAISE EXCEPTION 'FIXTURE 254 CC: the receipt did not record the construction'; END IF;
    -- 收货时不给 = 没记(参数缺省)
    v_msg := pg_temp.f254_do(format($q$SELECT set_config('f254.ib2', (create_inbound_batch(p_material_id => %L, p_supplier_id => %L, p_quantity => 10,
        p_arrival_date => %L, p_source_reason_code => 'other', p_source_reason_note => 'f254') ->> 'batch_id'), true)$q$, m_cell, v_sup, d));
    IF v_msg <> 'OK' OR (SELECT cell_construction_code FROM inbound_batches WHERE id = current_setting('f254.ib2')::uuid) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 254 CC: a receipt without a construction should leave it empty, got %', v_msg; END IF;
    -- 之后在批次页给(同一扇门 set_batch_cell_construction)
    v_msg := pg_temp.f254_do(format($q$SELECT set_batch_cell_construction('inbound', %L, 'stacked')$q$, current_setting('f254.ib2')));
    IF v_msg <> 'OK' OR (SELECT cell_construction_code FROM inbound_batches WHERE id = current_setting('f254.ib2')::uuid) IS DISTINCT FROM 'stacked' THEN
        RAISE EXCEPTION 'FIXTURE 254 CC: setting the construction later should work, got %', v_msg; END IF;
    -- 不认识的结构:收货与批次页两条路都按名拒
    v_msg := pg_temp.f254_do(format($q$SELECT create_inbound_batch(p_material_id => %L, p_supplier_id => %L, p_quantity => 10,
        p_arrival_date => %L, p_source_reason_code => 'other', p_source_reason_note => 'f254', p_cell_construction => 'spiral')$q$, m_cell, v_sup, d));
    IF v_msg NOT LIKE 'CELL_CONSTRUCTION_UNKNOWN|spiral%' THEN RAISE EXCEPTION 'FIXTURE 254 CC: an unknown construction at receipt, got %', v_msg; END IF;
    v_msg := pg_temp.f254_do(format($q$SELECT set_batch_cell_construction('inbound', %L, 'spiral')$q$, current_setting('f254.ib2')));
    IF v_msg NOT LIKE 'CELL_CONSTRUCTION_UNKNOWN|spiral%' THEN RAISE EXCEPTION 'FIXTURE 254 CC: an unknown construction later, got %', v_msg; END IF;
    -- 非电芯形态拒:收货 · 批次页 · 直连三条路
    v_msg := pg_temp.f254_do(format($q$SELECT create_inbound_batch(p_material_id => %L, p_supplier_id => %L, p_quantity => 10,
        p_arrival_date => %L, p_source_reason_code => 'other', p_source_reason_note => 'f254', p_cell_construction => 'wound')$q$, m_bm, v_sup, d));
    IF v_msg NOT LIKE 'CELL_CONSTRUCTION_NOT_APPLICABLE|%|black_mass%' THEN
        RAISE EXCEPTION 'FIXTURE 254 CC: black mass must not carry a construction at receipt, got %', v_msg; END IF;
    ib8 := pg_temp.f254_ib('ZZ254-IB8', m_bm, v_sup, 100, NULL, d);
    v_msg := pg_temp.f254_do(format($q$SELECT set_batch_cell_construction('inbound', %L, 'wound')$q$, ib8));
    IF v_msg NOT LIKE 'CELL_CONSTRUCTION_NOT_APPLICABLE|ZZ254-IB8|black_mass%' THEN
        RAISE EXCEPTION 'FIXTURE 254 CC: black mass must not carry a construction later, got %', v_msg; END IF;
    v_msg := pg_temp.f254_do(format($q$UPDATE inbound_batches SET cell_construction_code = 'wound' WHERE id = %L$q$, ib8), false);
    IF v_msg NOT LIKE 'CELL_CONSTRUCTION_NOT_APPLICABLE|%' THEN
        RAISE EXCEPTION 'FIXTURE 254 CC: a direct write must hit the same guard, got %', v_msg; END IF;
    -- 没有形态的物料不拦(不知道它是什么形态 ≠ 知道它不装电芯)
    ib7 := pg_temp.f254_ib('ZZ254-IB7', m_ew, v_sup, 100, NULL, d);
    v_msg := pg_temp.f254_do(format($q$SELECT set_batch_cell_construction('inbound', %L, 'wound')$q$, ib7));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 254 CC: a form-less material must not be refused, got %', v_msg; END IF;
    -- 没码的人改不了(只看加工)
    PERFORM pg_temp.f254_as(u_view);
    v_msg := pg_temp.f254_do(format($q$SELECT set_batch_cell_construction('inbound', %L, 'wound')$q$, current_setting('f254.ib2')));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.inbound.edit%' THEN RAISE EXCEPTION 'FIXTURE 254 CC: a viewer must not set it, got %', v_msg; END IF;
    PERFORM pg_temp.f254_as(u_all);

    -- 极片分离与自动极片线:没记 · unknown → INPUT_CELL_CONSTRUCTION_REQUIRED|<批号>;wound 过
    ib1 := pg_temp.f254_ib('ZZ254-IB1', m_dec, v_sup, 100, 'discharged_verified', d);              -- 没记
    ib2 := pg_temp.f254_ib('ZZ254-IB2', m_dec, v_sup, 100, 'discharged_verified', d, 'unknown');   -- 看过分不出
    ib3 := pg_temp.f254_ib('ZZ254-IB3', m_dec, v_sup, 100, 'discharged_verified', d, 'wound');
    FOREACH v_txt IN ARRAY ARRAY['electrode_separation', 'electrode_line'] LOOP
        BEGIN
            run := pg_temp.f254_run(v_txt, jsonb_build_array(pg_temp.f254_in(ib1, 10)), jsonb_build_array(pg_temp.f254_out(m_cts, 5)), d);
            RAISE EXCEPTION 'FIXTURE 254 CC: % took an input with no construction', v_txt;
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM NOT LIKE 'INPUT_CELL_CONSTRUCTION_REQUIRED|ZZ254-IB1%' THEN
                RAISE EXCEPTION 'FIXTURE 254 CC: % with no construction should say INPUT_CELL_CONSTRUCTION_REQUIRED, got %', v_txt, SQLERRM; END IF;
        END;
        BEGIN
            run := pg_temp.f254_run(v_txt, jsonb_build_array(pg_temp.f254_in(ib2, 10)), jsonb_build_array(pg_temp.f254_out(m_cts, 5)), d);
            RAISE EXCEPTION 'FIXTURE 254 CC: % took an input of unknown construction', v_txt;
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM NOT LIKE 'INPUT_CELL_CONSTRUCTION_REQUIRED|ZZ254-IB2%' THEN
                RAISE EXCEPTION 'FIXTURE 254 CC: % with unknown construction should say INPUT_CELL_CONSTRUCTION_REQUIRED, got %', v_txt, SQLERRM; END IF;
        END;
    END LOOP;
    -- 一道不要求结构的工序照收没记的料(开壳)
    ib4 := pg_temp.f254_ib('ZZ254-IB4', m_cell, v_sup, 100, 'discharged_verified', d, 'wound');
    ib5 := pg_temp.f254_ib('ZZ254-IB5', m_cell, v_sup, 100, 'discharged_verified', d, 'wound');
    ib6 := pg_temp.f254_ib('ZZ254-IB6', m_cell, v_sup, 100, 'discharged_verified', d, 'stacked');
    run_sep := pg_temp.f254_run('electrode_separation', jsonb_build_array(pg_temp.f254_in(ib3, 100)),
                                jsonb_build_array(pg_temp.f254_out(m_cts, 40), pg_temp.f254_out(m_ans, 30)), d);
    -- 继承:开壳(不要求结构)两批都是 wound → 已开壳电芯继承 wound;产出的极片(不装电芯)不继承
    run_cas := pg_temp.f254_run('casing_removal', jsonb_build_array(pg_temp.f254_in(ib4, 50), pg_temp.f254_in(ib5, 50)),
                                jsonb_build_array(pg_temp.f254_out(m_dec, 80)), d);
    IF (SELECT ob.cell_construction_code FROM processing_outputs po JOIN output_batches ob ON ob.id = po.output_batch_id WHERE po.run_id = run_cas)
       IS DISTINCT FROM 'wound' THEN
        RAISE EXCEPTION 'FIXTURE 254 CC: a de-cased cell output should inherit wound when every input is wound'; END IF;
    IF EXISTS (SELECT 1 FROM processing_outputs po JOIN output_batches ob ON ob.id = po.output_batch_id
                WHERE po.run_id = run_sep AND ob.cell_construction_code IS NOT NULL) THEN
        RAISE EXCEPTION 'FIXTURE 254 CC: sheet outputs (no cells) must not inherit a construction'; END IF;
    -- 不一致(wound + stacked)→ 空;有一批没记 → 空
    run := pg_temp.f254_run('casing_removal', jsonb_build_array(pg_temp.f254_in(ib5, 10), pg_temp.f254_in(ib6, 10)),
                            jsonb_build_array(pg_temp.f254_out(m_dec, 15)), d);
    IF (SELECT ob.cell_construction_code FROM processing_outputs po JOIN output_batches ob ON ob.id = po.output_batch_id WHERE po.run_id = run)
       IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 254 CC: inputs that disagree must leave the output empty'; END IF;
    UPDATE inbound_batches SET cell_construction_code = NULL WHERE id = current_setting('f254.ib2')::uuid;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) VALUES (current_setting('f254.ib2')::uuid, 'discharged_verified');
    run := pg_temp.f254_run('casing_removal', jsonb_build_array(pg_temp.f254_in(ib5, 10), pg_temp.f254_in(current_setting('f254.ib2')::uuid, 5)),
                            jsonb_build_array(pg_temp.f254_out(m_dec, 12)), d);
    IF (SELECT ob.cell_construction_code FROM processing_outputs po JOIN output_batches ob ON ob.id = po.output_batch_id WHERE po.run_id = run)
       IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 254 CC: an input with no construction must leave the output empty'; END IF;
    -- 锁:喂过一张已提交的单之后,批次页与直连都改不了;没喂过的照样改得动
    v_msg := pg_temp.f254_do(format($q$SELECT set_batch_cell_construction('inbound', %L, 'stacked')$q$, ib3));
    IF v_msg NOT LIKE 'CELL_CONSTRUCTION_LOCKED|' || (SELECT code FROM processing_runs WHERE id = run_sep) || '%' THEN
        RAISE EXCEPTION 'FIXTURE 254 CC: a batch that fed a committed run must be locked, got %', v_msg; END IF;
    v_msg := pg_temp.f254_do(format($q$UPDATE inbound_batches SET cell_construction_code = NULL WHERE id = %L$q$, ib3), false);
    IF v_msg NOT LIKE 'CELL_CONSTRUCTION_LOCKED|%' THEN RAISE EXCEPTION 'FIXTURE 254 CC: clearing it directly must be locked too, got %', v_msg; END IF;
    -- 产出批那一侧同一扇门:已开壳电芯批(还没喂过)改得动;它是 output
    SELECT po.output_batch_id INTO v_ob FROM processing_outputs po WHERE po.run_id = run_cas;
    v_msg := pg_temp.f254_do(format($q$SELECT set_batch_cell_construction('output', %L, 'stacked')$q$, v_ob));
    IF v_msg <> 'OK' OR (SELECT cell_construction_code FROM output_batches WHERE id = v_ob) <> 'stacked' THEN
        RAISE EXCEPTION 'FIXTURE 254 CC: an output batch that fed nothing yet should be editable, got %', v_msg; END IF;
    PERFORM pg_temp.f254_as(u_out);
    v_msg := pg_temp.f254_do(format($q$SELECT set_batch_cell_construction('output', %L, 'wound')$q$, v_ob));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.output.edit%' THEN RAISE EXCEPTION 'FIXTURE 254 CC: an output viewer must not set it, got %', v_msg; END IF;
    PERFORM pg_temp.f254_as(u_all);

    -- ══════════════ FORM · 六种新形态与可售性 ══════════════
    RAISE NOTICE 'fixture 254 · FORM';
    IF (SELECT string_agg(code || ':' || may_be_sold::text || ':' || implies_dismantling::text, ',' ORDER BY code) FROM material_forms
         WHERE code IN ('cathode_powder', 'anode_powder', 'copper_foil', 'aluminium_foil', 'collected_dust', 'harness_bms_busbar'))
       IS DISTINCT FROM 'aluminium_foil:true:false,anode_powder:true:false,cathode_powder:true:false,collected_dust:false:false,copper_foil:true:false,harness_bms_busbar:true:false' THEN
        RAISE EXCEPTION 'FIXTURE 254 FORM: the six new forms are not there with the Q9 saleability (dust no, anode powder yes)'; END IF;
    v_msg := pg_temp.f254_do(format($q$SELECT assert_material_form_saleable(%L)$q$, m_dust));
    IF v_msg NOT LIKE 'SALE_FORM_NOT_SALEABLE|collected_dust%' THEN RAISE EXCEPTION 'FIXTURE 254 FORM: collected dust must be refused for sale, got %', v_msg; END IF;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ254-APW', 'f254 anode powder', 'battery_material', true, 'anode_powder', 'end_of_life') RETURNING id INTO m_form;
    v_msg := pg_temp.f254_do(format($q$SELECT assert_material_form_saleable(%L)$q$, m_form));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 254 FORM: anode powder must be saleable (Tim, Q9), got %', v_msg; END IF;

    -- ══════════════ NUM · 编号 ══════════════
    RAISE NOTICE 'fixture 254 · NUM';
    -- MES-5b-3(2026-10-09):55 → 56(blending_plan / BLD;不在 output_batches 上,所以 13 不变)
    IF (SELECT count(*) FROM document_types) <> 56 OR (SELECT count(*) FROM document_types WHERE table_name = 'output_batches') <> 13 THEN
        RAISE EXCEPTION 'FIXTURE 254 NUM: the registry should have 56 rows, 13 of them on output_batches'; END IF;
    -- 每一种映射了的形态:铸它自己的前缀、五位(MAP 是本支的第二份真相 —— Tim 在 MES-0 Q54 定的码,抄在这里)
    FOR v_n IN 1 .. array_length(MAP, 1) LOOP
        EXECUTE format($q$INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
                          VALUES (%L, 'f254 numbering', 'battery_material', true, %L, 'end_of_life',
                                  CASE WHEN (SELECT implies_dismantling FROM material_forms WHERE code = %L) THEN 'ev_traction' END)
                          RETURNING id$q$, 'ZZ254-N' || v_n, MAP[v_n][1], MAP[v_n][1]) INTO m_form;
        EXECUTE 'SET LOCAL ROLE authenticated';
        v_j := create_output_batch(m_form, 1, 'kg', d);
        EXECUTE 'RESET ROLE';
        SELECT code INTO v_code FROM output_batches WHERE id = (v_j ->> 'batch_id')::uuid;
        IF v_code !~ ('^' || MAP[v_n][2] || '-' || v_year || '-[0-9]{5}$') THEN
            RAISE EXCEPTION 'FIXTURE 254 NUM: a % batch should mint %-%-NNNNN, got %', MAP[v_n][1], MAP[v_n][2], v_year, v_code; END IF;
        -- 搜得到,而且只在它自己那一种单据下(同一张表挂 13 行时,搜索按前缀分开)
        SELECT string_agg(s.key, ',') INTO v_txt FROM search_documents(v_code, 20) s WHERE s.code = v_code;
        IF v_txt IS DISTINCT FROM (SELECT f.output_document_key FROM material_forms f WHERE f.code = MAP[v_n][1]) THEN
            RAISE EXCEPTION 'FIXTURE 254 NUM: % should be found once under its own type, got %', v_code, v_txt; END IF;
    END LOOP;
    -- 没映射的形态(黑粉)与没有形态的物料:仍是 OUT,四位
    FOREACH m_form IN ARRAY ARRAY[m_bm, m_ew] LOOP
        EXECUTE 'SET LOCAL ROLE authenticated';
        v_j := create_output_batch(m_form, 1, 'kg', d);
        EXECUTE 'RESET ROLE';
        SELECT code INTO v_code FROM output_batches WHERE id = (v_j ->> 'batch_id')::uuid;
        IF v_code !~ ('^OUT-' || v_year || '-[0-9]{4,}$') THEN
            RAISE EXCEPTION 'FIXTURE 254 NUM: an unmapped form / no form should stay OUT, got %', v_code; END IF;
        SELECT string_agg(s.key, ',') INTO v_txt FROM search_documents(v_code, 20) s WHERE s.code = v_code;
        IF v_txt IS DISTINCT FROM 'output_batch' THEN
            RAISE EXCEPTION 'FIXTURE 254 NUM: an OUT- code should still be found, once, as output_batch; got %', v_txt; END IF;
    END LOOP;
    -- 低于 10,000 逐字不变(四位补零);推过 9,999 照实长出去,不截断(OUT 与 IN 两支从不重置的)
    -- 一个两位数的号(补零看得见);跳过本支前面已经铸过的号,免得撞上
    v_n := 41;
    WHILE EXISTS (SELECT 1 FROM output_batches WHERE code = 'OUT-' || v_year || '-' || lpad((v_n + 1)::text, 4, '0')) LOOP v_n := v_n + 1; END LOOP;
    PERFORM setval('output_code_seq', v_n, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_j := create_output_batch(m_bm, 1, 'kg', d);
    EXECUTE 'RESET ROLE';
    IF (SELECT code FROM output_batches WHERE id = (v_j ->> 'batch_id')::uuid) <> 'OUT-' || v_year || '-' || lpad((v_n + 1)::text, 4, '0') THEN
        RAISE EXCEPTION 'FIXTURE 254 NUM: a two-digit number should still read as four digits (as before), got %', (SELECT code FROM output_batches WHERE id = (v_j ->> 'batch_id')::uuid); END IF;
    PERFORM setval('output_code_seq', 9999, true);   -- 下一个 = 10000(旧的 LPAD(…, 4) 会把它截成 1000)
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_j := create_output_batch(m_bm, 1, 'kg', d);
    EXECUTE 'RESET ROLE';
    IF (SELECT code FROM output_batches WHERE id = (v_j ->> 'batch_id')::uuid) <> 'OUT-' || v_year || '-10000' THEN
        RAISE EXCEPTION 'FIXTURE 254 NUM: number 10000 must not be truncated, got %', (SELECT code FROM output_batches WHERE id = (v_j ->> 'batch_id')::uuid); END IF;
    -- 往后的产出批从一个本支没铸过的号接着铸(否则 10001… 可能撞上本支开头铸过的号 —— 开跑时序列若已过万)
    PERFORM setval('output_code_seq', GREATEST(v_seq_out_last, 10000) + 100, true);
    PERFORM setval('inbound_code_seq', 9999, true);
    v_msg := pg_temp.f254_do(format($q$SELECT set_config('f254.ib3', (create_inbound_batch(p_material_id => %L, p_supplier_id => %L, p_quantity => 10,
        p_arrival_date => %L, p_source_reason_code => 'other', p_source_reason_note => 'f254') ->> 'batch_id'), true)$q$, m_bm, v_sup, d));
    IF v_msg <> 'OK' OR (SELECT code FROM inbound_batches WHERE id = current_setting('f254.ib3')::uuid) <> 'IN-' || v_year || '-10000' THEN
        RAISE EXCEPTION 'FIXTURE 254 NUM: inbound number 10000 must not be truncated, got % / %', v_msg,
            (SELECT code FROM inbound_batches WHERE id = NULLIF(current_setting('f254.ib3', true), '')::uuid); END IF;
    PERFORM setval('inbound_code_seq', GREATEST(v_seq_in_last, 10000) + 100, true);
    -- (两条序列在本支最后放回原值 —— 放早了,本支后面的产出会撞上刚铸过的号)
    -- 取号函数一支都不再写那个会截断的形状(11 支有洞的全扫;注释剥掉,只看会被执行的字节)
    SELECT string_agg(p.proname, ',' ORDER BY p.proname) INTO v_txt
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f'
       AND regexp_replace(pg_get_functiondef(p.oid), '--[^' || chr(10) || ']*', '', 'g') ~* 'lpad\(\s*nextval';
    IF v_txt IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 254 NUM: these generators still truncate with LPAD(nextval(…), 4): %', v_txt; END IF;

    -- ══════════════ LOSS · 损耗的依据与电解液 ══════════════
    RAISE NOTICE 'fixture 254 · LOSS';
    -- run_sep:投入 100 · 产出 70 · loss_qty 30
    PERFORM record_run_loss(run_sep, 'moisture', 1, 'f254');
    IF (SELECT basis FROM processing_run_losses WHERE run_id = run_sep AND loss_category_code = 'moisture') <> 'measured'
       OR (SELECT derived_share_pct FROM processing_run_losses WHERE run_id = run_sep AND loss_category_code = 'moisture') IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 254 LOSS: record_run_loss must write measured with no share'; END IF;
    -- 没勾「Electrolyte evaporates in this step」→ 拒(引导全部为假)
    IF EXISTS (SELECT 1 FROM operation_types WHERE electrolyte_loss_applies OR electrolyte_share_pct IS NOT NULL) THEN
        RAISE EXCEPTION 'FIXTURE 254 LOSS: the electrolyte flag and share should be seeded empty on every operation'; END IF;
    v_msg := pg_temp.f254_do(format('SELECT record_derived_electrolyte_loss(%L)', run_sep));
    IF v_msg NOT LIKE 'ELECTROLYTE_LOSS_NOT_APPLICABLE|electrode_separation%' THEN RAISE EXCEPTION 'FIXTURE 254 LOSS: an operation without the flag, got %', v_msg; END IF;
    UPDATE operation_types SET electrolyte_loss_applies = true WHERE code = 'electrode_separation';
    v_msg := pg_temp.f254_do(format('SELECT record_derived_electrolyte_loss(%L)', run_sep));
    IF v_msg NOT LIKE 'ELECTROLYTE_SHARE_NOT_SET|electrode_separation%' THEN RAISE EXCEPTION 'FIXTURE 254 LOSS: no share, got %', v_msg; END IF;
    UPDATE operation_types SET electrolyte_share_pct = 50 WHERE code = 'electrode_separation';   -- 50 → 50 kg,加上 1 kg moisture > 30
    v_msg := pg_temp.f254_do(format('SELECT record_derived_electrolyte_loss(%L)', run_sep));
    IF v_msg NOT LIKE 'LOSS_CATEGORIES_EXCEED_LOSS_QTY|%' THEN RAISE EXCEPTION 'FIXTURE 254 LOSS: named losses above input − outputs, got %', v_msg; END IF;
    -- 状态改变型(放电):即使勾了、给了份额也拒
    UPDATE operation_types SET electrolyte_loss_applies = true, electrolyte_share_pct = 10 WHERE code = 'deep_discharge';
    run_dis := pg_temp.f254_run('deep_discharge', jsonb_build_array(pg_temp.f254_in(pg_temp.f254_ib('ZZ254-IBD', m_mod, v_sup, 100, 'charged_not_discharged', d), 100)),
                                '[]'::jsonb, d);
    v_msg := pg_temp.f254_do(format('SELECT record_derived_electrolyte_loss(%L)', run_dis));
    IF v_msg NOT LIKE 'ELECTROLYTE_LOSS_STATE_CHANGING|deep_discharge%' THEN RAISE EXCEPTION 'FIXTURE 254 LOSS: a state-changing run, got %', v_msg; END IF;
    UPDATE operation_types SET electrolyte_loss_applies = false, electrolyte_share_pct = NULL WHERE code = 'deep_discharge';
    -- 没有 aftercare 的人记不了
    PERFORM pg_temp.f254_as(u_view);
    v_msg := pg_temp.f254_do(format('SELECT record_derived_electrolyte_loss(%L)', run_sep));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.processing_aftercare%' THEN RAISE EXCEPTION 'FIXTURE 254 LOSS: a viewer must be refused, got %', v_msg; END IF;
    PERFORM pg_temp.f254_as(u_all);
    -- 份额 12.5:算出来 12.5 kg(份额 × 投入 100 / 100),basis derived,份额抄下;不是余数(余数是 30 − 1 = 29)
    UPDATE operation_types SET electrolyte_share_pct = 12.5 WHERE code = 'electrode_separation';
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_id := record_derived_electrolyte_loss(run_sep, 'f254 derived');
    EXECUTE 'RESET ROLE';
    SELECT quantity, basis, derived_share_pct INTO v_num, v_txt, v_j FROM (SELECT quantity, basis, to_jsonb(derived_share_pct) AS derived_share_pct FROM processing_run_losses WHERE id = v_id) x;
    IF v_num <> 12.5 OR v_txt <> 'derived' OR (v_j #>> '{}')::numeric <> 12.5 THEN
        RAISE EXCEPTION 'FIXTURE 254 LOSS: derived row should be 12.5 kg, derived, share 12.5; got % % %', v_num, v_txt, v_j; END IF;
    IF (SELECT derived_loss_qty FROM processing_run_balance_all WHERE run_id = run_sep) <> 12.5
       OR (SELECT named_loss_qty FROM processing_run_balance_all WHERE run_id = run_sep) <> 13.5
       OR (SELECT remainder_qty FROM processing_run_balance_all WHERE run_id = run_sep) <> 16.5 THEN
        RAISE EXCEPTION 'FIXTURE 254 LOSS: the balance should show 13.5 named (12.5 derived) and 16.5 remainder'; END IF;
    v_msg := pg_temp.f254_do(format('SELECT record_derived_electrolyte_loss(%L)', run_sep));
    IF v_msg NOT LIKE 'RUN_LOSS_ALREADY_RECORDED|electrolyte_evaporation%' THEN RAISE EXCEPTION 'FIXTURE 254 LOSS: a second derived row, got %', v_msg; END IF;
    -- 不能把别的类别算出来(只有 may_be_derived 的那一类)
    IF (SELECT string_agg(code, ',') FROM loss_categories WHERE may_be_derived) IS DISTINCT FROM 'electrolyte_evaporation' THEN
        RAISE EXCEPTION 'FIXTURE 254 LOSS: only electrolyte_evaporation may be derived'; END IF;
    v_msg := pg_temp.f254_do(format('SELECT rederive_electrolyte_loss(%s, %L)',
                                    (SELECT id FROM processing_run_losses WHERE run_id = run_sep AND loss_category_code = 'moisture'), 'f254'));
    IF v_msg NOT LIKE 'RUN_LOSS_NOT_DERIVABLE|moisture%' THEN RAISE EXCEPTION 'FIXTURE 254 LOSS: re-deriving a measured-only category, got %', v_msg; END IF;
    -- 结平(容差没给 → 要一句说明),然后重新算 → 重开
    PERFORM close_run_balance(run_sep, 'f254 closing with a derived electrolyte loss');
    IF (SELECT balance_state FROM processing_run_balance_all WHERE run_id = run_sep) <> 'closed' THEN
        RAISE EXCEPTION 'FIXTURE 254 LOSS: the run should be closed'; END IF;
    v_msg := pg_temp.f254_do(format('SELECT rederive_electrolyte_loss(%s, %L)', v_id, 'f254 same share'));
    IF v_msg NOT LIKE 'RUN_LOSS_CORRECTION_SAME_VALUE%' THEN RAISE EXCEPTION 'FIXTURE 254 LOSS: re-deriving with the same share, got %', v_msg; END IF;
    v_msg := pg_temp.f254_do(format('SELECT rederive_electrolyte_loss(%s, %L)', v_id, ''));
    IF v_msg NOT LIKE 'RUN_LOSS_CORRECTION_REASON_REQUIRED%' THEN RAISE EXCEPTION 'FIXTURE 254 LOSS: re-deriving without a reason, got %', v_msg; END IF;
    UPDATE operation_types SET electrolyte_share_pct = 10 WHERE code = 'electrode_separation';
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_id2 := rederive_electrolyte_loss(v_id, 'f254 supplier datasheet says 10 %');
    EXECUTE 'RESET ROLE';
    IF (SELECT quantity FROM processing_run_losses WHERE id = v_id2) <> 10 OR (SELECT derived_share_pct FROM processing_run_losses WHERE id = v_id2) <> 10
       OR (SELECT corrects_id FROM processing_run_losses WHERE id = v_id2) <> v_id OR (SELECT basis FROM processing_run_losses WHERE id = v_id2) <> 'derived' THEN
        RAISE EXCEPTION 'FIXTURE 254 LOSS: re-derivation should be a correction row of 10 kg at share 10'; END IF;
    IF (SELECT balance_state FROM processing_run_balance_all WHERE run_id = run_sep) <> 'open' THEN
        RAISE EXCEPTION 'FIXTURE 254 LOSS: a corrected loss must reopen the closed run'; END IF;
    -- 改成量出来的(同一个数也算一次更正 —— 依据变了)
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_id := correct_run_loss(v_id2, 10, 'f254 weighed at the duct');
    EXECUTE 'RESET ROLE';
    IF (SELECT basis FROM processing_run_losses WHERE id = v_id) <> 'measured' OR (SELECT derived_share_pct FROM processing_run_losses WHERE id = v_id) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 254 LOSS: switching to measured should write a measured row with no share'; END IF;
    IF (SELECT derived_loss_qty FROM processing_run_balance_all WHERE run_id = run_sep) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 254 LOSS: after the switch no part of the named loss is derived'; END IF;
    v_msg := pg_temp.f254_do(format('SELECT correct_run_loss(%s, 10, %L)', v_id, 'f254 same measured value'));
    IF v_msg NOT LIKE 'RUN_LOSS_CORRECTION_SAME_VALUE%' THEN RAISE EXCEPTION 'FIXTURE 254 LOSS: a measured correction to the same value is still refused, got %', v_msg; END IF;
    -- 一条直插不写 basis → 表本身拒(没有默认值)
    v_msg := pg_temp.f254_do(format($q$INSERT INTO processing_run_losses (run_id, loss_category_code, quantity) VALUES (%L, 'dust_spill', 1)$q$, run_cas), false);
    IF v_msg NOT LIKE '%basis%' THEN RAISE EXCEPTION 'FIXTURE 254 LOSS: a loss row with no basis must be refused, got %', v_msg; END IF;
    UPDATE operation_types SET electrolyte_loss_applies = false, electrolyte_share_pct = NULL WHERE code = 'electrode_separation';

    -- ══════════════ CONT · 交叉污染 ══════════════
    RAISE NOTICE 'fixture 254 · CONT';
    -- run_sep(昨天 · 白班)产出了正极片与负极片:两条流都出现在提醒里,指着这一炉
    IF (SELECT count(*) FROM operations_now WHERE item_type = 'contamination_check_missing' AND item_id = run_sep) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 254 CONT: the reminder should list both streams for the shift (got %)',
            (SELECT count(*) FROM operations_now WHERE item_type = 'contamination_check_missing' AND item_id = run_sep); END IF;
    -- 同一个班第二炉:提醒仍是那一格、仍指着最早的那一炉(一格一行)
    ib1 := pg_temp.f254_ib('ZZ254-IBC', m_dec, v_sup, 100, 'discharged_verified', d, 'stacked');
    run_c1 := pg_temp.f254_run('electrode_separation', jsonb_build_array(pg_temp.f254_in(ib1, 50)), jsonb_build_array(pg_temp.f254_out(m_cts, 40)), d);
    IF (SELECT count(*) FROM operations_now WHERE item_type = 'contamination_check_missing' AND item_date = d) <> 2
       OR EXISTS (SELECT 1 FROM operations_now WHERE item_type = 'contamination_check_missing' AND item_id = run_c1) THEN
        RAISE EXCEPTION 'FIXTURE 254 CONT: one row per shift and stream, pointing at the earliest run'; END IF;
    -- 警戒线(V11)空着:抽检照记,判不了(NULL)
    SELECT po.output_batch_id INTO v_ob FROM processing_outputs po JOIN output_batches ob ON ob.id = po.output_batch_id
     WHERE po.run_id = run_sep AND ob.material_id = m_cts;
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_id := record_contamination_check(run_sep, 'cathode', 'sampled', v_ob, 200, 3, d::timestamptz + interval '10 hours', 'sieve');
    EXECUTE 'RESET ROLE';
    IF (SELECT rate_pct FROM contamination_checks WHERE id = v_id) <> 1.5 OR (SELECT above_warning FROM contamination_checks WHERE id = v_id) IS NOT NULL
       OR (SELECT warning_pct_at FROM contamination_checks WHERE id = v_id) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 254 CONT: with no warning level the rate is 1.5 and cannot be judged (NULL)'; END IF;
    -- 抽了正极:正极那一格消失,负极那一格还在
    IF EXISTS (SELECT 1 FROM operations_now WHERE item_type = 'contamination_check_missing' AND item_id = run_sep AND subject = 'cathode')
       OR NOT EXISTS (SELECT 1 FROM operations_now WHERE item_type = 'contamination_check_missing' AND item_id = run_sep AND subject = 'anode') THEN
        RAISE EXCEPTION 'FIXTURE 254 CONT: a check clears its own stream only'; END IF;
    -- 给了警戒线 1.0 之后再抽一次:2.0 % > 1.0 → 标出来,从不拒;线抄进那一行
    UPDATE contamination_streams SET warning_pct = 1.0 WHERE code = 'cathode';
    SELECT po.output_batch_id INTO v_ob FROM processing_outputs po WHERE po.run_id = run_c1;
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_id2 := record_contamination_check(run_c1, 'cathode', 'sampled', v_ob, 100, 2, d::timestamptz + interval '10 hours', NULL);
    EXECUTE 'RESET ROLE';
    IF (SELECT above_warning FROM contamination_checks WHERE id = v_id2) IS NOT TRUE OR (SELECT warning_pct_at FROM contamination_checks WHERE id = v_id2) <> 1.0 THEN
        RAISE EXCEPTION 'FIXTURE 254 CONT: a rate above the warning level must be flagged (and recorded)'; END IF;
    IF (SELECT any_above_warning FROM contamination_shift_status_all WHERE process_date = d AND shift_code = 'day' AND stream_code = 'cathode') IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 254 CONT: the shift status should report a rate above the warning level'; END IF;
    -- 更正:新行指回原行,原行不动;更正链的末端才是当前的;只能更正末端;理由必填
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_id2 := correct_contamination_check(v_id2, 'sampled', v_ob, 100, 0.5, d::timestamptz + interval '10 hours', 'reweighed', NULL, 'f254 balance was not tared');
    EXECUTE 'RESET ROLE';
    IF (SELECT above_warning FROM contamination_checks WHERE id = v_id2) IS NOT FALSE
       OR (SELECT count(*) FROM contamination_check_rows WHERE run_id = run_c1 AND is_current) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 254 CONT: the correction should be the one current row (0.5 %%, not above)'; END IF;
    v_msg := pg_temp.f254_do(format($q$SELECT correct_contamination_check(%s, 'sampled', %L, 100, 1, now(), NULL, NULL, 'again')$q$,
                                    (SELECT corrects_id FROM contamination_checks WHERE id = v_id2), v_ob));
    IF v_msg NOT LIKE 'CONTAMINATION_CHECK_SUPERSEDED|%' THEN RAISE EXCEPTION 'FIXTURE 254 CONT: correcting a superseded row, got %', v_msg; END IF;
    v_msg := pg_temp.f254_do(format($q$SELECT correct_contamination_check(%s, 'sampled', %L, 100, 1, now(), NULL, NULL, ' ')$q$, v_id2, v_ob));
    IF v_msg NOT LIKE 'CONTAMINATION_CORRECTION_REASON_REQUIRED%' THEN RAISE EXCEPTION 'FIXTURE 254 CONT: a correction without a reason, got %', v_msg; END IF;
    -- 没抽:没有理由拒;有理由 → 关掉负极那一格
    v_msg := pg_temp.f254_do(format($q$SELECT record_contamination_check(%L, 'anode', 'not_sampled')$q$, run_sep));
    IF v_msg NOT LIKE 'CONTAMINATION_REASON_REQUIRED%' THEN RAISE EXCEPTION 'FIXTURE 254 CONT: not sampled without a reason, got %', v_msg; END IF;
    v_msg := pg_temp.f254_do(format($q$SELECT record_contamination_check(%L, 'anode', 'not_sampled', p_not_sampled_reason => 'f254 sampler on leave')$q$, run_sep));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 254 CONT: not sampled with a reason should be recorded, got %', v_msg; END IF;
    IF EXISTS (SELECT 1 FROM operations_now WHERE item_type = 'contamination_check_missing' AND item_date = d AND item_code IN
                 ((SELECT code FROM processing_runs WHERE id = run_sep), (SELECT code FROM processing_runs WHERE id = run_c1))) THEN
        RAISE EXCEPTION 'FIXTURE 254 CONT: a not-sampled row with a reason must clear the reminder for that shift and stream'; END IF;
    IF (SELECT check_state FROM contamination_shift_status_all WHERE process_date = d AND shift_code = 'day' AND stream_code = 'anode') <> 'not_sampled' THEN
        RAISE EXCEPTION 'FIXTURE 254 CONT: the anode cell should read not_sampled (the omission stays on record)'; END IF;
    -- 另一个班(夜班)是另一格:提醒在那里出现
    ib2 := pg_temp.f254_ib('ZZ254-IBN', m_dec, v_sup, 100, 'discharged_verified', d, 'wound');
    run_c2 := pg_temp.f254_run('electrode_separation', jsonb_build_array(pg_temp.f254_in(ib2, 50)), jsonb_build_array(pg_temp.f254_out(m_ans, 40)), d, 'night');
    IF NOT EXISTS (SELECT 1 FROM operations_now WHERE item_type = 'contamination_check_missing' AND item_id = run_c2 AND subject = 'anode')
       OR EXISTS (SELECT 1 FROM operations_now WHERE item_type = 'contamination_check_missing' AND item_id = run_c2 AND subject = 'cathode') THEN
        RAISE EXCEPTION 'FIXTURE 254 CONT: the night shift is its own cell (anode only — that run made anode sheets only)'; END IF;
    -- 拒:不是这一炉这条流的极片 · 这一炉没有这条流的极片 · 质量不对 · 抽样时刻 · 混填 · MES-4a 之前的单 · 没码的人
    SELECT po.output_batch_id INTO v_ob FROM processing_outputs po WHERE po.run_id = run_c2;
    v_msg := pg_temp.f254_do(format($q$SELECT record_contamination_check(%L, 'anode', 'sampled', %L, 100, 1, now())$q$, run_sep, v_ob));
    IF v_msg NOT LIKE 'CONTAMINATION_BATCH_NOT_SHEET_OF_RUN|%' THEN RAISE EXCEPTION 'FIXTURE 254 CONT: a batch of another run, got %', v_msg; END IF;
    v_msg := pg_temp.f254_do(format($q$SELECT record_contamination_check(%L, 'cathode', 'not_sampled', p_not_sampled_reason => 'x')$q$, run_c2));
    IF v_msg NOT LIKE 'CONTAMINATION_RUN_HAS_NO_SHEET|%|cathode%' THEN RAISE EXCEPTION 'FIXTURE 254 CONT: a run with no sheet of the stream, got %', v_msg; END IF;
    v_msg := pg_temp.f254_do(format($q$SELECT record_contamination_check(%L, 'anode', 'sampled', %L, 100, 101, now())$q$, run_c2, v_ob));
    IF v_msg NOT LIKE 'CONTAMINATION_MASS_INVALID|%' THEN RAISE EXCEPTION 'FIXTURE 254 CONT: foreign above sample, got %', v_msg; END IF;
    v_msg := pg_temp.f254_do(format($q$SELECT record_contamination_check(%L, 'anode', 'sampled', %L, 100, 1, NULL)$q$, run_c2, v_ob));
    IF v_msg NOT LIKE 'CONTAMINATION_SAMPLED_AT_REQUIRED%' THEN RAISE EXCEPTION 'FIXTURE 254 CONT: no sampling time, got %', v_msg; END IF;
    v_msg := pg_temp.f254_do(format($q$SELECT record_contamination_check(%L, 'anode', 'not_sampled', %L, p_not_sampled_reason => 'x')$q$, run_c2, v_ob));
    IF v_msg NOT LIKE 'CONTAMINATION_FIELDS_MIXED|not_sampled%' THEN RAISE EXCEPTION 'FIXTURE 254 CONT: not sampled with a batch, got %', v_msg; END IF;
    -- MES-4a 之前的单:绕开表头闸造一张(那正是它们当初的样子 —— fixture 253 HDR 的同一个造法)
    ALTER TABLE processing_runs DISABLE TRIGGER trg_processing_runs_header;
    INSERT INTO processing_runs (code, process_date, total_input, total_output, loss_qty, status, allocation_basis, operation_type_code)
    VALUES ('ZZ254-OLD', d - 30, 1, 1, 0, 'committed', 'weight', 'electrode_separation') RETURNING id INTO run_old;
    ALTER TABLE processing_runs ENABLE TRIGGER trg_processing_runs_header;
    v_msg := pg_temp.f254_do(format($q$SELECT record_contamination_check(%L, 'anode', 'not_sampled', p_not_sampled_reason => 'x')$q$, run_old));
    IF v_msg NOT LIKE 'CONTAMINATION_RUN_PREDATES_RECORD|ZZ254-OLD%' THEN
        RAISE EXCEPTION 'FIXTURE 254 CONT: a run without a shift, got %', v_msg; END IF;
    PERFORM pg_temp.f254_as(u_view);
    v_msg := pg_temp.f254_do(format($q$SELECT record_contamination_check(%L, 'anode', 'not_sampled', p_not_sampled_reason => 'x')$q$, run_c2));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.processing_aftercare%' THEN RAISE EXCEPTION 'FIXTURE 254 CONT: a viewer must be refused, got %', v_msg; END IF;
    -- 只持产出码的人读得到抽检(带门的属主视图),读不到加工单;只持加工码的人也读得到
    PERFORM pg_temp.f254_as(u_out);
    IF (SELECT count(*) FROM contamination_check_rows WHERE run_id = run_sep) < 2 OR (SELECT count(*) FROM contamination_shift_status WHERE process_date = d) < 3 THEN
        RAISE EXCEPTION 'FIXTURE 254 CONT: an output.view reader should read the checks and the shift grid'; END IF;
    PERFORM pg_temp.f254_as(NULL);
    IF EXISTS (SELECT 1 FROM contamination_check_rows) OR EXISTS (SELECT 1 FROM contamination_shift_status) THEN
        RAISE EXCEPTION 'FIXTURE 254 CONT: a reader with no code must read nothing'; END IF;
    PERFORM pg_temp.f254_as(u_all);
    -- 抽检不碰物料平衡:run_sep 的余数与上面 LOSS 臂末尾一样
    IF (SELECT remainder_qty FROM processing_run_balance_all WHERE run_id = run_sep) <> 30 - 1 - 10 THEN
        RAISE EXCEPTION 'FIXTURE 254 CONT: contamination checks must not change the balance'; END IF;
    UPDATE contamination_streams SET warning_pct = NULL WHERE code = 'cathode';

    -- ══════════════ DUST · 收集的粉尘 ══════════════
    RAISE NOTICE 'fixture 254 · DUST';
    ib3 := pg_temp.f254_ib('ZZ254-IBS', m_scrap, v_sup, 100, 'discharged_verified', d);
    run_dust := pg_temp.f254_run('electrode_powder_line', jsonb_build_array(pg_temp.f254_in(ib3, 100)),
                                 jsonb_build_array(pg_temp.f254_out(m_bm, 80), pg_temp.f254_out(m_dust, 5)), d);
    SELECT ob.code, ob.id INTO v_code, v_ob FROM processing_outputs po JOIN output_batches ob ON ob.id = po.output_batch_id
     WHERE po.run_id = run_dust AND ob.material_id = m_dust;
    IF v_code !~ ('^DST-' || v_year || '-[0-9]{5}$') THEN RAISE EXCEPTION 'FIXTURE 254 DUST: collected dust should mint DST-, got %', v_code; END IF;
    IF (SELECT output_qty FROM processing_run_balance_all WHERE run_id = run_dust) <> 85
       OR (SELECT loss_qty FROM processing_run_balance_all WHERE run_id = run_dust) <> 15 THEN
        RAISE EXCEPTION 'FIXTURE 254 DUST: the dust leg must count in the outputs (85) and the balance (loss 15)'; END IF;
    IF (SELECT weighing_id FROM processing_outputs WHERE output_batch_id = v_ob) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 254 DUST: the dust leg is weighed like every other leg'; END IF;
    IF EXISTS (SELECT 1 FROM inventory_movements WHERE output_batch_id = v_ob AND location_id IS NOT NULL) THEN
        RAISE EXCEPTION 'FIXTURE 254 DUST: a processing output lands with no location'; END IF;
    IF EXISTS (SELECT 1 FROM output_batch_safety_states WHERE output_batch_id = v_ob) THEN
        RAISE EXCEPTION 'FIXTURE 254 DUST: no safety state is seeded for collected dust'; END IF;

    -- ══════════════ PV · V10 与 V11 ══════════════
    RAISE NOTICE 'fixture 254 · PV';
    IF EXISTS (SELECT 1 FROM pending_values WHERE value_code = 'V10') THEN
        RAISE EXCEPTION 'FIXTURE 254 PV: V10 should be empty while no operation is ticked'; END IF;
    IF (SELECT string_agg(item_code, ',' ORDER BY item_code) FROM pending_values WHERE value_code = 'V11') IS DISTINCT FROM 'anode,cathode' THEN
        RAISE EXCEPTION 'FIXTURE 254 PV: V11 should list both streams with no warning level'; END IF;
    UPDATE operation_types SET electrolyte_loss_applies = true WHERE code = 'casing_removal';
    IF (SELECT string_agg(item_code || '>' || href, ',') FROM pending_values WHERE value_code = 'V10')
       IS DISTINCT FROM 'casing_removal>/operation/operation-types/casing_removal' THEN
        RAISE EXCEPTION 'FIXTURE 254 PV: a ticked operation with no share should appear in V10, pointing at its page'; END IF;
    UPDATE operation_types SET electrolyte_share_pct = 8 WHERE code = 'casing_removal';
    UPDATE contamination_streams SET warning_pct = 2 WHERE code = 'anode';
    IF EXISTS (SELECT 1 FROM pending_values WHERE value_code = 'V10')
       OR (SELECT string_agg(item_code, ',') FROM pending_values WHERE value_code = 'V11') IS DISTINCT FROM 'cathode' THEN
        RAISE EXCEPTION 'FIXTURE 254 PV: giving the value must clear its row'; END IF;
    PERFORM pg_temp.f254_as(u_out);
    IF EXISTS (SELECT 1 FROM pending_values WHERE value_code IN ('V10', 'V11')) THEN
        RAISE EXCEPTION 'FIXTURE 254 PV: V10 and V11 are behind module.processing.view'; END IF;
    PERFORM pg_temp.f254_as(u_all);

    -- 序列放回本支开跑之前的样子(setval 不随事务回滚;后面的 fixture 应当看到与这一支跑之前一样的序列)
    PERFORM setval('output_code_seq', v_seq_out_last, v_seq_out_called);
    PERFORM setval('inbound_code_seq', v_seq_in_last, v_seq_in_called);
    RAISE NOTICE 'FIXTURE 254 全部通过:CC · FORM · NUM · LOSS · CONT · DUST · PV';
END
$$;

ROLLBACK;
