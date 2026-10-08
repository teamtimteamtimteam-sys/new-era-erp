-- 253 MES-4a:一炉说出它从几点跑到几点、哪个班;每一条产出都是称出来的;参数与指标是配置;配方一版写了不改;
--     损耗与之后的更正都留着理由、不覆盖;物料平衡不对的时候要一句书面说明才能结平
--     (MES-4a Step 0 Q1–Q36;v1.4.41)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】一臂一组裁定;每一臂都有故障注入(db/scripts/2026-10-07-mes4a-fixture-injections.py)必须让它红在它点名的那一臂。
--   HDR     开始 · 结束 · 班次必填,各一句码;结束不早于开始、不在将来;加工日落在两者的新加坡日期之间;表上的 INSERT 闸对任何写入者成立;
--           MES-4a 之前的单(开始时刻为空)照旧改得动(UPDATE 不过闸)、结不了平、不进清单、表头不更正(Q7 · Q21)
--   MACH    一道挂着机器的工序必须选挂着的那一台;没挂的被拒;处置掉的不算数;非设备类资产挂不上(Q9)
--   FIELD   值在提交时与之后都能记;更正是新行、原行不动;越界照记、标出来;退役的字段不再收新值、也删不掉;用上之后改不了类型(Q10–Q12 · Q29)
--   EVENT   逐件、只追加;更正与撤回是新行;种类只能是字典里的(没有 other)(Q15)
--   RECIPE  一版写了不改;提交时预填参数;当前值对着配方差不差由数据库说(Q16)
--   LOSS    loss_qty = 投入 − 产出,敲一个不同的数按名拒;有名字的损耗不许超过它;只追加,撤回 = 更正成 0;没有直连写的路(Q17 · Q28)
--   CLOSE   缺必填值 · 缺称重 → 拒;余数为 0 → 结;在给了的容差里 → 结;超出、或容差没给 → 没说明拒、有说明结;之后的损耗更正重开它;
--           放电与 MES-4a 之前的单不结;没有 aftercare 的人结不了(Q19–Q21)
--   WEIGH   挑一条称重 · 敲一个重量(同一笔事务里落一条手工称重)· 两样都没有按名拒 · 不在校准期内拒 · 没记仪器只标出来(开关给了才拒)·
--           被更正过的与用过的拒 · 用上之后那条称重不能再更正(Q24–Q26)
--   DISCH   放电记得进,而且不要产出(Q4 的并入);MES-5a-1:提交本身不核实,每一个模组通过之后才核实
--   NEWOPS  开壳与极片分离两道新工序只受理已放电并核实的料(Q3)
--   CORR    表头六个字段逐个可更正、各留一行;别的字段拒;corrects_run_id 只指回已回滚、还没被更正过的单(Q30 · Q31)
--   POL     三张加工表的 UPDATE 策略与损耗的写策略都拿掉了,直连改按名拒(Q32)
--   MONTH   月末那一行只警告(processing_runs_unclosed_balance),不挡关账;提醒臂 processing_balance_unclosed(Q22)
--   COST    分摊与结平两个方向都互不等待、互不改动(Q23)
--   PV      V1(转化型工序的容差)· V36(声明了有范围的参数)· V6 改了去处(Q35)
--   SHIFT   班次的起止时刻改得动(字典编辑器的"时刻"字段写的就是这两列),两个都给或都不给(Q5)
--   TRAIL   加工单的审计记录带上值、事件、结平、表头更正;工序的审计记录带上它的字段、机器与配方(Q33)
--
-- 自带数据(README 第 2 条)。以 postgres 跑(绕过 RLS);员工的直连写真的切成 authenticated + 那个人的 JWT。日期 = 昨天(新加坡),
-- 一炉从 09:00 跑到 11:00 —— 一炉不许记在将来(RUN_IN_FUTURE),所以不用 fixture 惯用的远期日期。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f253_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

-- 跑一句:成功回 'OK'(改动留着),失败回错误原文(那一句的改动随子事务撤掉)。p_auth = 切成 authenticated 跑
CREATE FUNCTION pg_temp.f253_do(p_sql text, p_auth boolean DEFAULT false) RETURNS text
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

-- 一批进料:定价、化学确定、带一个安全状态
CREATE FUNCTION pg_temp.f253_ib(p_code text, p_mat uuid, p_sup uuid, p_qty numeric, p_state text, p_d date) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v uuid; v_ccy text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES (p_code, p_mat, p_sup, p_qty, p_qty, 'kg', p_d - 1, 'other', 'fixture 253 自带数据') RETURNING id INTO v;
    PERFORM reprice_inbound_batch(v, 1, v_ccy, NULL, 'f253');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) VALUES (v, p_state);
    RETURN v;
END;
$f$;

-- MES-4b(2026-10-07,MES-4b Step 0 Q5):极片分离的投料必须带一个确定的电芯结构 —— 这一批是卷绕的(直写,以 postgres 跑)
CREATE FUNCTION pg_temp.f253_ib_wound(p_code text, p_mat uuid, p_sup uuid, p_qty numeric, p_state text, p_d date) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v uuid;
BEGIN
    v := pg_temp.f253_ib(p_code, p_mat, p_sup, p_qty, p_state, p_d);
    UPDATE inbound_batches SET cell_construction_code = 'wound' WHERE id = v;
    RETURN v;
END;
$f$;

DO $$
DECLARE
    u_all   uuid := gen_random_uuid();   -- 全部码
    u_view  uuid := gen_random_uuid();   -- 只看加工
    u_edit  uuid := gen_random_uuid();   -- 加工 view + edit(cto 的形状:配置工序,不提交、不记损耗以外的补记)
    u_noaft uuid := gen_random_uuid();   -- 加工 view + 提交,【没有】aftercare
    r_all uuid; r_view uuid; r_edit uuid; r_noaft uuid;
    d   date := CURRENT_DATE - 1;
    t0  timestamptz := (CURRENT_DATE - 1)::timestamptz + interval '9 hours';
    t1  timestamptz := (CURRENT_DATE - 1)::timestamptz + interval '11 hours';
    v_sup uuid; m_pack uuid; m_cell uuid; m_dec uuid; m_out uuid;
    ib uuid; ib2 uuid;
    a_eq uuid; a_eq2 uuid; a_van uuid; a_gone uuid;
    run uuid; run2 uuid; run3 uuid; run_old uuid; run_dis uuid; run_cost uuid; run_c uuid;
    w1 uuid; w2 uuid; w3 uuid; w_exp uuid; s_exp uuid; s_exp_code text;
    rec uuid; rv1 uuid; rv2 uuid; rv_other uuid;
    v_id bigint; v_id2 bigint;
    v_msg text; v_n int; v_num numeric; v_txt text; v_b boolean; v_j jsonb; v_code text;
    v_cnt0 int;
BEGIN
    UPDATE finance_settings SET locked_before = NULL;
    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES
        (u_all, 'fx253-all@test.local', now(), now()), (u_view, 'fx253-view@test.local', now(), now()),
        (u_edit, 'fx253-edit@test.local', now(), now()), (u_noaft, 'fx253-noaft@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx253-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx253-view', 'f', 'f', true) RETURNING id INTO r_view;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx253-edit', 'f', 'f', true) RETURNING id INTO r_edit;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx253-noaft', 'f', 'f', true) RETURNING id INTO r_noaft;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_view, 'module.processing.view'),
        (r_edit, 'module.processing.view'), (r_edit, 'module.processing.edit'),
        (r_noaft, 'module.processing.view'), (r_noaft, 'action.processing_commit');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_all, r_all), (u_view, r_view), (u_edit, r_edit), (u_noaft, r_noaft);
    PERFORM pg_temp.f253_as(u_all);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ253-S', 'f253 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ253-PACK', 'f253 pack', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction')
    RETURNING id INTO m_pack;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ253-CELL', 'f253 cells', 'battery_material', true, 'loose_cells', 'end_of_life', 'ev_traction')
    RETURNING id INTO m_cell;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ253-DEC', 'f253 de-cased cells', 'battery_material', true, 'de_cased_cell', 'end_of_life', 'ev_traction')
    RETURNING id INTO m_dec;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ253-OUT', 'f253 output', 'battery_material', true, 'loose_cells', 'end_of_life', 'ev_traction')
    RETURNING id INTO m_out;
    ib := pg_temp.f253_ib('ZZ253-IB1', m_pack, v_sup, 5000, 'discharged_verified', d);

    -- ══════════════ HDR · 表头 ══════════════
    RAISE NOTICE 'fixture 253 · HDR';
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 10)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 10)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => NULL, p_ended_at => %L::timestamptz, p_shift_code => 'day')$q$, d, ib, m_out, t1));
    IF v_msg <> 'RUN_TIMES_REQUIRED|start' THEN RAISE EXCEPTION 'FIXTURE 253 HDR: no start time should be RUN_TIMES_REQUIRED|start, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 10)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 10)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => NULL, p_shift_code => 'day')$q$, d, ib, m_out, t0));
    IF v_msg <> 'RUN_TIMES_REQUIRED|end' THEN RAISE EXCEPTION 'FIXTURE 253 HDR: no end time should be RUN_TIMES_REQUIRED|end, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 10)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 10)), 'weight', NULL, NULL, 'manual_disassembly')$q$, d, ib, m_out));
    IF v_msg <> 'RUN_TIMES_REQUIRED|start,end' THEN RAISE EXCEPTION 'FIXTURE 253 HDR: the old call (no times at all) should be RUN_TIMES_REQUIRED|start,end, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 10)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 10)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz)$q$, d, ib, m_out, t0, t1));
    IF v_msg <> 'RUN_SHIFT_REQUIRED' THEN RAISE EXCEPTION 'FIXTURE 253 HDR: no shift should be RUN_SHIFT_REQUIRED, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 10)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 10)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'zz253')$q$, d, ib, m_out, t0, t1));
    IF v_msg <> 'RUN_SHIFT_UNKNOWN|zz253' THEN RAISE EXCEPTION 'FIXTURE 253 HDR: an unknown shift should be RUN_SHIFT_UNKNOWN, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 10)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 10)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day')$q$, d, ib, m_out, t1, t0));
    IF v_msg NOT LIKE 'RUN_END_BEFORE_START|%' THEN RAISE EXCEPTION 'FIXTURE 253 HDR: end before start should be RUN_END_BEFORE_START, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 10)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 10)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => now() + interval '1 hour', p_shift_code => 'day')$q$, CURRENT_DATE, ib, m_out, now() - interval '1 hour'));
    IF v_msg NOT LIKE 'RUN_IN_FUTURE|%' THEN RAISE EXCEPTION 'FIXTURE 253 HDR: an end in the future should be RUN_IN_FUTURE, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 10)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 10)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day')$q$, d - 2, ib, m_out, t0, t1));
    IF v_msg NOT LIKE 'RUN_DATE_OUTSIDE_RUN_TIME|%' THEN RAISE EXCEPTION 'FIXTURE 253 HDR: a process date outside the run should be RUN_DATE_OUTSIDE_RUN_TIME, got %', v_msg; END IF;
    -- 跨午夜的一炉:加工日可以是开始那天,也可以是结束那天
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253 overnight', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 10)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 10)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'night')$q$, d, ib, m_out, (d - 1)::timestamptz + interval '22 hours', d::timestamptz + interval '2 hours'));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 253 HDR: an overnight run dated the day it ended should commit, got %', v_msg; END IF;
    -- 表上的闸对任何写入者成立(属主直插也一样)
    v_msg := pg_temp.f253_do($q$INSERT INTO processing_runs (process_date, status, allocation_basis, operation_type_code) VALUES (CURRENT_DATE - 1, 'committed', 'weight', 'manual_disassembly')$q$);
    IF v_msg <> 'RUN_TIMES_REQUIRED|start,end' THEN RAISE EXCEPTION 'FIXTURE 253 HDR: a direct owner INSERT without times should be refused by the table trigger, got %', v_msg; END IF;
    -- MES-4a 之前的单:绕开闸造一张(那正是它们当初的样子)
    ALTER TABLE processing_runs DISABLE TRIGGER trg_processing_runs_header;
    INSERT INTO processing_runs (code, process_date, total_input, total_output, loss_qty, status, allocation_basis, operation_type_code)
    VALUES ('ZZ253-OLD', d - 30, 100, 90, 10, 'committed', 'weight', 'manual_disassembly') RETURNING id INTO run_old;
    ALTER TABLE processing_runs ENABLE TRIGGER trg_processing_runs_header;
    v_msg := pg_temp.f253_do(format($q$UPDATE processing_runs SET allocation_snapshot = '{"f253": true}'::jsonb WHERE id = %L$q$, run_old));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 253 HDR: an owner UPDATE of a pre-MES-4a run must not meet the header gate (it only watches INSERT), got %', v_msg; END IF;
    IF (SELECT balance_state FROM processing_run_balance_all WHERE run_id = run_old) <> 'before_closure' THEN
        RAISE EXCEPTION 'FIXTURE 253 HDR: a pre-MES-4a run should read before_closure, got %', (SELECT balance_state FROM processing_run_balance_all WHERE run_id = run_old); END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT close_run_balance(%L, 'x')$q$, run_old));
    IF v_msg <> 'RUN_BALANCE_BEFORE_CLOSURE|ZZ253-OLD' THEN RAISE EXCEPTION 'FIXTURE 253 HDR: closing a pre-MES-4a run should be RUN_BALANCE_BEFORE_CLOSURE, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT correct_run_header(%L, 'notes', 'x', 'f253')$q$, run_old));
    IF v_msg <> 'RUN_HEADER_PREDATES_RECORD|ZZ253-OLD' THEN RAISE EXCEPTION 'FIXTURE 253 HDR: correcting a pre-MES-4a header should be RUN_HEADER_PREDATES_RECORD, got %', v_msg; END IF;

    -- ══════════════ MACH · 工序 ↔ 机器 ══════════════
    RAISE NOTICE 'fixture 253 · MACH';
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_base, currency, cost_ccy, fx_rate, status, useful_life_months, residual_base)
    VALUES ('ZZ253-EQ1', 'f253 machine one', 'equipment', d - 200, 0, (SELECT code FROM currencies WHERE is_base), 0, 1, 'active', 100, 0) RETURNING id INTO a_eq;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_base, currency, cost_ccy, fx_rate, status, useful_life_months, residual_base)
    VALUES ('ZZ253-EQ2', 'f253 machine two', 'equipment', d - 200, 0, (SELECT code FROM currencies WHERE is_base), 0, 1, 'active', 100, 0) RETURNING id INTO a_eq2;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_base, currency, cost_ccy, fx_rate, status, useful_life_months, residual_base)
    VALUES ('ZZ253-VAN', 'f253 van', 'vehicle', d - 200, 0, (SELECT code FROM currencies WHERE is_base), 0, 1, 'active', 100, 0) RETURNING id INTO a_van;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_base, currency, cost_ccy, fx_rate, status, disposal_date, useful_life_months, residual_base)
    VALUES ('ZZ253-GONE', 'f253 disposed machine', 'equipment', d - 400, 0, (SELECT code FROM currencies WHERE is_base), 0, 1, 'disposed', d - 100, 100, 0) RETURNING id INTO a_gone;
    v_msg := pg_temp.f253_do(format($q$INSERT INTO operation_type_equipment (operation_type_code, fixed_asset_id) VALUES ('manual_disassembly', %L)$q$, a_van));
    IF v_msg <> 'EQUIPMENT_LINK_NOT_EQUIPMENT|ZZ253-VAN|vehicle' THEN RAISE EXCEPTION 'FIXTURE 253 MACH: a vehicle should not be linkable to an operation, got %', v_msg; END IF;
    PERFORM pg_temp.f253_as(u_edit);
    v_msg := pg_temp.f253_do(format($q$INSERT INTO operation_type_equipment (operation_type_code, fixed_asset_id) VALUES ('manual_disassembly', %L)$q$, a_eq), true);
    PERFORM pg_temp.f253_as(u_all);
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 253 MACH: a processing editor should be able to link a machine, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 10)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 10)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day')$q$, d, ib, m_out, t0, t1));
    IF v_msg <> 'EQUIPMENT_REQUIRED_FOR_OPERATION|manual_disassembly' THEN RAISE EXCEPTION 'FIXTURE 253 MACH: an operation with a linked machine should require one, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 10)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 10)), 'weight', NULL, %L, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day')$q$, d, ib, m_out, a_eq2, t0, t1));
    IF v_msg <> 'EQUIPMENT_NOT_LINKED_TO_OPERATION|ZZ253-EQ2|manual_disassembly' THEN RAISE EXCEPTION 'FIXTURE 253 MACH: an unlinked machine should be refused, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 10)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 10)), 'weight', NULL, %L, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day')$q$, d, ib, m_out, a_eq, t0, t1));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 253 MACH: the linked machine should be accepted, got %', v_msg; END IF;
    -- 只挂着一台已处置的机器 = 没有挂机器
    INSERT INTO operation_type_equipment (operation_type_code, fixed_asset_id) VALUES ('battery_powder_line', a_gone);
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 10)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 10)), 'weight', NULL, NULL, 'battery_powder_line', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day')$q$, d, ib, m_out, t0, t1));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 253 MACH: a disposed machine must not count as a linked one, got %', v_msg; END IF;
    DELETE FROM operation_type_equipment WHERE operation_type_code = 'manual_disassembly';

    -- ══════════════ FIELD · 参数与指标 ══════════════
    RAISE NOTICE 'fixture 253 · FIELD';
    INSERT INTO operation_type_fields (operation_type_code, field_code, name_en, name_zh, kind, value_type, unit, has_range, range_min, range_max, sort_order)
    VALUES ('manual_disassembly', 'blade_speed', 'Blade speed', '刀速', 'parameter', 'number', 'rpm', true, 10, 20, 200);
    run := commit_processing_run(d, 'f253 values', NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', ib, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', m_out, 'weight_kg', 90)), 'weight', NULL, NULL, 'manual_disassembly',
        p_started_at => t0, p_ended_at => t1, p_shift_code => 'day', p_values => '{"modules_in": 4, "blade_speed": 25}'::jsonb);
    SELECT value_number, out_of_range INTO v_num, v_b FROM processing_run_values_current WHERE run_id = run AND field_code = 'blade_speed';
    IF v_num IS DISTINCT FROM 25 OR v_b IS NOT TRUE THEN RAISE EXCEPTION 'FIXTURE 253 FIELD: an out-of-range value should be recorded and flagged (25, true), got (%, %)', v_num, v_b; END IF;
    IF (SELECT out_of_range FROM processing_run_values_current WHERE run_id = run AND field_code = 'modules_in') IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 253 FIELD: a field without a range must read out_of_range NULL (cannot judge), not false'; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT record_run_value(%L, 'cells_out', '30'::jsonb)$q$, run));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 253 FIELD: recording a value later should work, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT record_run_value(%L, 'cells_out', '31'::jsonb)$q$, run));
    IF v_msg <> 'RUN_VALUE_ALREADY_RECORDED|cells_out' THEN RAISE EXCEPTION 'FIXTURE 253 FIELD: a second value for the same field should be RUN_VALUE_ALREADY_RECORDED, got %', v_msg; END IF;
    SELECT id INTO v_id FROM processing_run_values WHERE run_id = run AND field_code = 'cells_out';
    v_msg := pg_temp.f253_do(format($q$SELECT correct_run_value(%s, '31'::jsonb, NULL)$q$, v_id));
    IF v_msg <> 'RUN_VALUE_CORRECTION_REASON_REQUIRED' THEN RAISE EXCEPTION 'FIXTURE 253 FIELD: a correction without a reason should be refused, got %', v_msg; END IF;
    v_id2 := correct_run_value(v_id, '31'::jsonb, 'f253 recounted');
    IF (SELECT value_number FROM processing_run_values WHERE id = v_id) <> 30
       OR (SELECT value_number FROM processing_run_values_current WHERE run_id = run AND field_code = 'cells_out') <> 31
       OR NOT (SELECT corrected FROM processing_run_values_current WHERE run_id = run AND field_code = 'cells_out') THEN
        RAISE EXCEPTION 'FIXTURE 253 FIELD: a correction should add a row (original 30 kept, current 31, corrected)'; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT correct_run_value(%s, '32'::jsonb, 'again')$q$, v_id));
    IF v_msg <> format('RUN_VALUE_SUPERSEDED|%s', v_id) THEN RAISE EXCEPTION 'FIXTURE 253 FIELD: correcting a superseded value should be refused, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT record_run_value(%L, 'cells_damaged', '2.5'::jsonb)$q$, run));
    IF v_msg <> 'RUN_VALUE_INVALID|cells_damaged|count' THEN RAISE EXCEPTION 'FIXTURE 253 FIELD: a fractional count should be refused, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT record_run_value(%L, 'energy_kwh', '5'::jsonb)$q$, run));
    IF v_msg <> 'RUN_VALUE_FIELD_NOT_ON_OPERATION|energy_kwh|manual_disassembly' THEN RAISE EXCEPTION 'FIXTURE 253 FIELD: a field of another operation should be refused, got %', v_msg; END IF;
    UPDATE operation_type_fields SET is_active = false WHERE operation_type_code = 'manual_disassembly' AND field_code = 'cells_damaged';
    v_msg := pg_temp.f253_do(format($q$SELECT record_run_value(%L, 'cells_damaged', '1'::jsonb)$q$, run));
    IF v_msg <> 'RUN_VALUE_FIELD_RETIRED|cells_damaged' THEN RAISE EXCEPTION 'FIXTURE 253 FIELD: a retired field should not take a new value, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do($q$DELETE FROM operation_type_fields WHERE operation_type_code = 'manual_disassembly' AND field_code = 'cells_damaged'$q$);
    IF v_msg <> 'OPERATION_FIELD_RETIRE_NOT_DELETE|manual_disassembly|cells_damaged' THEN RAISE EXCEPTION 'FIXTURE 253 FIELD: a field should be retired, never deleted, got %', v_msg; END IF;
    UPDATE operation_type_fields SET is_active = true WHERE operation_type_code = 'manual_disassembly' AND field_code = 'cells_damaged';
    v_msg := pg_temp.f253_do($q$UPDATE operation_type_fields SET value_type = 'number' WHERE operation_type_code = 'manual_disassembly' AND field_code = 'modules_in'$q$);
    IF v_msg <> 'OPERATION_FIELD_IN_USE|manual_disassembly|modules_in' THEN RAISE EXCEPTION 'FIXTURE 253 FIELD: a used field should not change type, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$UPDATE processing_run_values SET value_number = 99 WHERE id = %s$q$, v_id));
    IF v_msg <> 'APPEND_ONLY|processing_run_values|update' THEN RAISE EXCEPTION 'FIXTURE 253 FIELD: values are append-only even for the owner, got %', v_msg; END IF;
    PERFORM pg_temp.f253_as(u_noaft);
    v_msg := pg_temp.f253_do(format($q$SELECT record_run_value(%L, 'cells_damaged', '1'::jsonb)$q$, run), true);
    PERFORM pg_temp.f253_as(u_all);
    IF v_msg <> 'PERMISSION_DENIED|action.processing_aftercare' THEN RAISE EXCEPTION 'FIXTURE 253 FIELD: recording later needs action.processing_aftercare, got %', v_msg; END IF;

    -- ══════════════ EVENT · 异常事件 ══════════════
    RAISE NOTICE 'fixture 253 · EVENT';
    v_id := record_run_event(run, 'unplanned_stop', t0 + interval '30 minutes', 12, 'reset the cutter', 'f253 lead hand');
    v_msg := pg_temp.f253_do(format($q$SELECT record_run_event(%L, 'other', %L::timestamptz, 1, 'x', 'y')$q$, run, t0));
    IF v_msg <> 'RUN_EVENT_TYPE_UNKNOWN|other' THEN RAISE EXCEPTION 'FIXTURE 253 EVENT: an event type outside the dictionary should be refused, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do($q$INSERT INTO processing_event_types (code, name_en, name_zh) VALUES ('other', 'Other', '其它')$q$);
    IF v_msg NOT LIKE '%processing_event_types_code_check%' THEN RAISE EXCEPTION 'FIXTURE 253 EVENT: the dictionary must not take an "other", got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT record_run_event(%L, 'equipment_alarm', %L::timestamptz, NULL, ' ', 'y')$q$, run, t0));
    IF v_msg <> 'RUN_EVENT_ACTION_REQUIRED' THEN RAISE EXCEPTION 'FIXTURE 253 EVENT: an event needs the action taken, got %', v_msg; END IF;
    v_id2 := correct_run_event(v_id, 'unplanned_stop', t0 + interval '30 minutes', 15, 'reset the cutter', 'f253 lead hand', NULL, false, 'f253 the stop was 15 minutes');
    IF (SELECT duration_min FROM processing_run_events WHERE id = v_id) <> 12 OR (SELECT duration_min FROM processing_run_events WHERE id = v_id2) <> 15 THEN
        RAISE EXCEPTION 'FIXTURE 253 EVENT: a correction should add a row and leave the original'; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT correct_run_event(%s, 'unplanned_stop', now(), 1, 'x', 'y', NULL, false, 'again')$q$, v_id));
    IF v_msg <> format('RUN_EVENT_SUPERSEDED|%s', v_id) THEN RAISE EXCEPTION 'FIXTURE 253 EVENT: correcting a superseded event should be refused, got %', v_msg; END IF;
    v_id := correct_run_event(v_id2, NULL, NULL, NULL, NULL, NULL, NULL, true, 'f253 recorded on the wrong run');
    IF NOT (SELECT withdrawn FROM processing_run_events WHERE id = v_id) THEN RAISE EXCEPTION 'FIXTURE 253 EVENT: a withdrawal should be a withdrawn row'; END IF;
    v_msg := pg_temp.f253_do(format($q$DELETE FROM processing_run_events WHERE id = %s$q$, v_id));
    IF v_msg <> 'APPEND_ONLY|processing_run_events|delete' THEN RAISE EXCEPTION 'FIXTURE 253 EVENT: events are append-only, got %', v_msg; END IF;

    -- ══════════════ RECIPE · 配方 ══════════════
    RAISE NOTICE 'fixture 253 · RECIPE';
    PERFORM pg_temp.f253_as(u_edit);
    v_msg := pg_temp.f253_do($q$INSERT INTO process_recipes (operation_type_code, code, name_en, name_zh) VALUES ('manual_disassembly', 'ZZ253-STD', 'Standard', '标准')$q$, true);
    PERFORM pg_temp.f253_as(u_all);
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 253 RECIPE: a processing editor should create a recipe, got %', v_msg; END IF;
    SELECT id INTO rec FROM process_recipes WHERE code = 'ZZ253-STD';
    v_msg := pg_temp.f253_do(format($q$SELECT create_recipe_version(%L, '{"modules_in": 4}'::jsonb)$q$, rec));
    IF v_msg <> 'RECIPE_FIELD_NOT_A_PARAMETER|modules_in' THEN RAISE EXCEPTION 'FIXTURE 253 RECIPE: an indicator is not a preset, got %', v_msg; END IF;
    rv1 := create_recipe_version(rec, '{"blade_speed": "15"}'::jsonb, 'f253 v1');
    IF (SELECT version FROM process_recipe_versions WHERE id = rv1) <> 1 OR (SELECT param_values FROM process_recipe_versions WHERE id = rv1) <> '{"blade_speed": 15}'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 253 RECIPE: the first version should be 1 with the value normalised to a number'; END IF;
    v_msg := pg_temp.f253_do(format($q$UPDATE process_recipe_versions SET param_values = '{"blade_speed": 16}'::jsonb WHERE id = %L$q$, rv1));
    IF v_msg <> 'APPEND_ONLY|process_recipe_versions|update' THEN RAISE EXCEPTION 'FIXTURE 253 RECIPE: a version is fixed, got %', v_msg; END IF;
    run2 := commit_processing_run(d, 'f253 recipe', NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', ib, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', m_out, 'weight_kg', 100)), 'weight', NULL, NULL, 'manual_disassembly',
        p_started_at => t0, p_ended_at => t1, p_shift_code => 'day', p_recipe_version_id => rv1, p_values => '{"modules_in": 3}'::jsonb);
    SELECT value_number, source, differs_from_recipe INTO v_num, v_txt, v_b FROM processing_run_values_current WHERE run_id = run2 AND field_code = 'blade_speed';
    IF v_num IS DISTINCT FROM 15 OR v_txt <> 'recipe' OR v_b IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FIXTURE 253 RECIPE: the recipe should pre-fill 15 (source recipe, no difference), got (%, %, %)', v_num, v_txt, v_b; END IF;
    IF (SELECT differs_from_recipe FROM processing_run_values_current WHERE run_id = run2 AND field_code = 'modules_in') IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 253 RECIPE: a field the recipe does not name cannot be compared (NULL)'; END IF;
    SELECT value_id INTO v_id FROM processing_run_values_current WHERE run_id = run2 AND field_code = 'blade_speed';
    PERFORM correct_run_value(v_id, '18'::jsonb, 'f253 ran faster than the recipe');
    IF (SELECT differs_from_recipe FROM processing_run_values_current WHERE run_id = run2 AND field_code = 'blade_speed') IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 253 RECIPE: an actual value off the recipe should read differs_from_recipe = true'; END IF;
    rv2 := create_recipe_version(rec, '{"blade_speed": 17}'::jsonb, 'f253 v2');
    IF (SELECT version FROM process_recipe_versions WHERE id = rv2) <> 2 OR (SELECT recipe_version_id FROM processing_runs WHERE id = run2) <> rv1 THEN
        RAISE EXCEPTION 'FIXTURE 253 RECIPE: a new version is 2 and the run keeps the version it used'; END IF;
    INSERT INTO process_recipes (operation_type_code, code, name_en, name_zh) VALUES ('battery_powder_line', 'ZZ253-BAT', 'b', 'b');
    INSERT INTO operation_type_fields (operation_type_code, field_code, name_en, name_zh, kind, value_type, sort_order)
    VALUES ('battery_powder_line', 'feed_rate', 'Feed rate', '给料速度', 'parameter', 'number', 100);
    rv_other := create_recipe_version((SELECT id FROM process_recipes WHERE code = 'ZZ253-BAT'), '{"feed_rate": 3}'::jsonb);
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 10)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 10)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day', p_recipe_version_id => %L)$q$, d, ib, m_out, t0, t1, rv_other));
    IF v_msg <> 'RECIPE_VERSION_NOT_FOR_OPERATION|ZZ253-BAT|manual_disassembly' THEN RAISE EXCEPTION 'FIXTURE 253 RECIPE: a recipe of another operation should be refused, got %', v_msg; END IF;
    UPDATE process_recipes SET is_active = false WHERE id = rec;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 10)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 10)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day', p_recipe_version_id => %L)$q$, d, ib, m_out, t0, t1, rv2));
    IF v_msg <> 'RECIPE_INACTIVE|ZZ253-STD' THEN RAISE EXCEPTION 'FIXTURE 253 RECIPE: a retired recipe should be refused, got %', v_msg; END IF;
    UPDATE process_recipes SET is_active = true WHERE id = rec;

    -- ══════════════ LOSS · 推出来的总量、只追加的分类 ══════════════
    RAISE NOTICE 'fixture 253 · LOSS';
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', 5, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 100)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 90)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day')$q$, d, ib, m_out, t0, t1));
    IF v_msg <> 'LOSS_QTY_NOT_INPUT_MINUS_OUTPUT|5|10' THEN RAISE EXCEPTION 'FIXTURE 253 LOSS: a supplied loss different from input minus output should be refused, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', 10, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 100)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 90)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day')$q$, d, ib, m_out, t0, t1));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 253 LOSS: a supplied loss equal to input minus output is fine, got %', v_msg; END IF;
    IF (SELECT loss_qty FROM processing_runs WHERE id = run) <> 10 THEN RAISE EXCEPTION 'FIXTURE 253 LOSS: loss_qty should be derived as 100 - 90 = 10'; END IF;
    v_id := record_run_loss(run, 'moisture', 4);
    v_msg := pg_temp.f253_do(format($q$SELECT record_run_loss(%L, 'moisture', 1)$q$, run));
    IF v_msg <> 'RUN_LOSS_ALREADY_RECORDED|moisture' THEN RAISE EXCEPTION 'FIXTURE 253 LOSS: a second original row for the same category should be refused, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT record_run_loss(%L, 'dust_spill', 7)$q$, run));
    IF v_msg NOT LIKE 'LOSS_CATEGORIES_EXCEED_LOSS_QTY|%|11|10' THEN RAISE EXCEPTION 'FIXTURE 253 LOSS: named losses above the derived loss should be refused, got %', v_msg; END IF;
    IF (SELECT count(*) FROM loss_categories WHERE code IN ('sampling_consumption', 'equipment_holdup', 'sweepings') AND is_active) <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 253 LOSS: the three Q56 categories should be present'; END IF;
    PERFORM record_run_loss(run, 'sweepings', 2);
    v_id2 := correct_run_loss(v_id, 0, 'f253 it was not moisture');
    IF (SELECT categorised_qty FROM processing_run_loss_breakdown WHERE run_id = run) <> 2
       OR (SELECT quantity FROM processing_run_losses WHERE id = v_id) <> 4 THEN
        RAISE EXCEPTION 'FIXTURE 253 LOSS: a withdrawal is a correction to zero (current sum 2, original 4 kept)'; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT correct_run_loss(%s, 1, 'again')$q$, v_id));
    IF v_msg <> format('RUN_LOSS_SUPERSEDED|%s', v_id) THEN RAISE EXCEPTION 'FIXTURE 253 LOSS: correcting a superseded loss should be refused, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$UPDATE processing_run_losses SET quantity = 1 WHERE id = %s$q$, v_id));
    IF v_msg <> 'APPEND_ONLY|processing_run_losses|update' THEN RAISE EXCEPTION 'FIXTURE 253 LOSS: losses are append-only even for the owner, got %', v_msg; END IF;
    PERFORM pg_temp.f253_as(u_edit);
    v_msg := pg_temp.f253_do(format($q$INSERT INTO processing_run_losses (run_id, loss_category_code, quantity, basis) VALUES (%L, 'dust_spill', 1, 'measured')$q$, run), true);
    PERFORM pg_temp.f253_as(u_all);
    IF v_msg NOT LIKE 'permission denied for table processing_run_losses%' THEN RAISE EXCEPTION 'FIXTURE 253 LOSS: no direct write path should be left, got %', v_msg; END IF;

    -- ══════════════ CLOSE · 结平 ══════════════
    RAISE NOTICE 'fixture 253 · CLOSE';
    -- run:投入 100,产出 90,损耗 10;有名字的损耗当前 2(扫地料)→ 余数 8,容差没给
    UPDATE operation_type_fields SET is_required = true WHERE operation_type_code = 'manual_disassembly' AND field_code = 'cells_damaged';
    v_msg := pg_temp.f253_do(format($q$SELECT close_run_balance(%L, 'f253')$q$, run));
    v_code := (SELECT code FROM processing_runs WHERE id = run);
    IF v_msg <> format('RUN_REQUIRED_VALUES_MISSING|%s|cells_damaged', v_code) THEN RAISE EXCEPTION 'FIXTURE 253 CLOSE: a missing required value should refuse the closure, got %', v_msg; END IF;
    PERFORM record_run_value(run, 'cells_damaged', '0'::jsonb);
    SELECT weighing_id INTO w1 FROM processing_outputs WHERE run_id = run;
    UPDATE processing_outputs SET weighing_id = NULL WHERE run_id = run;   -- 属主路径:造一条没挂称重的腿
    v_msg := pg_temp.f253_do(format($q$SELECT close_run_balance(%L, 'f253')$q$, run));
    IF v_msg <> format('RUN_OUTPUT_WEIGHING_MISSING|%s|1', v_code) THEN RAISE EXCEPTION 'FIXTURE 253 CLOSE: an output without a weighing should refuse the closure, got %', v_msg; END IF;
    UPDATE processing_outputs SET weighing_id = w1 WHERE run_id = run;
    v_msg := pg_temp.f253_do(format($q$SELECT close_run_balance(%L, NULL)$q$, run));
    IF v_msg <> format('RUN_BALANCE_EXPLANATION_REQUIRED|%s|8|not_set', v_code) THEN RAISE EXCEPTION 'FIXTURE 253 CLOSE: a remainder with no tolerance set needs an explanation, got %', v_msg; END IF;
    PERFORM pg_temp.f253_as(u_noaft);
    v_msg := pg_temp.f253_do(format($q$SELECT close_run_balance(%L, 'x')$q$, run), true);
    PERFORM pg_temp.f253_as(u_all);
    IF v_msg <> 'PERMISSION_DENIED|action.processing_aftercare' THEN RAISE EXCEPTION 'FIXTURE 253 CLOSE: closing needs action.processing_aftercare, got %', v_msg; END IF;
    v_id := close_run_balance(run, 'f253: 8 kg is unidentified fines, under review');
    IF (SELECT balance_state FROM processing_run_balance_all WHERE run_id = run) <> 'closed'
       OR (SELECT remainder_qty FROM processing_run_closures WHERE id = v_id) <> 8
       OR (SELECT tolerance_pct FROM processing_run_closures WHERE id = v_id) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 253 CLOSE: closed with an explanation should read closed, remainder 8, tolerance not set'; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT close_run_balance(%L, 'again')$q$, run));
    IF v_msg <> format('RUN_BALANCE_ALREADY_CLOSED|%s', v_code) THEN RAISE EXCEPTION 'FIXTURE 253 CLOSE: a current closure should refuse a second one, got %', v_msg; END IF;
    -- 之后一条损耗的更正 → 重开
    PERFORM correct_run_loss((SELECT id FROM processing_run_losses WHERE run_id = run AND loss_category_code = 'sweepings'), 3, 'f253 more sweepings found');
    IF (SELECT balance_state FROM processing_run_balance_all WHERE run_id = run) <> 'open' THEN
        RAISE EXCEPTION 'FIXTURE 253 CLOSE: a later loss correction should reopen the run'; END IF;
    -- 余数为 0:结,不要说明
    PERFORM correct_run_loss((SELECT l.id FROM processing_run_losses l WHERE l.run_id = run AND l.loss_category_code = 'sweepings'
                                AND NOT EXISTS (SELECT 1 FROM processing_run_losses x WHERE x.corrects_id = l.id)), 10, 'f253 all of it was sweepings');
    v_msg := pg_temp.f253_do(format($q$SELECT close_run_balance(%L, NULL)$q$, run));
    IF v_msg <> 'OK' OR (SELECT balance_state FROM processing_run_balance_all WHERE run_id = run) <> 'closed' THEN
        RAISE EXCEPTION 'FIXTURE 253 CLOSE: a zero remainder should close without an explanation, got %', v_msg; END IF;
    UPDATE operation_type_fields SET is_required = false WHERE operation_type_code = 'manual_disassembly' AND field_code = 'cells_damaged';
    -- 容差给了:在里面结、超出要说明
    UPDATE operation_types SET balance_tolerance_pct = 5 WHERE code = 'manual_disassembly';
    run3 := commit_processing_run(d, 'f253 within', NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', ib, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', m_out, 'weight_kg', 97)), 'weight', NULL, NULL, 'manual_disassembly',
        p_started_at => t0, p_ended_at => t1, p_shift_code => 'day');
    v_msg := pg_temp.f253_do(format($q$SELECT close_run_balance(%L, NULL)$q$, run3));
    IF v_msg <> 'OK' OR (SELECT within_tolerance FROM processing_run_closures WHERE run_id = run3) IS NOT TRUE
       OR (SELECT tolerance_pct FROM processing_run_closures WHERE run_id = run3) <> 5 THEN
        RAISE EXCEPTION 'FIXTURE 253 CLOSE: a remainder within a set tolerance should close without an explanation (and copy the tolerance), got %', v_msg; END IF;
    run_c := commit_processing_run(d, 'f253 beyond', NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', ib, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', m_out, 'weight_kg', 80)), 'weight', NULL, NULL, 'manual_disassembly',
        p_started_at => t0, p_ended_at => t1, p_shift_code => 'day');
    v_msg := pg_temp.f253_do(format($q$SELECT close_run_balance(%L, '  ')$q$, run_c));
    IF v_msg <> format('RUN_BALANCE_EXPLANATION_REQUIRED|%s|20|5', (SELECT code FROM processing_runs WHERE id = run_c)) THEN
        RAISE EXCEPTION 'FIXTURE 253 CLOSE: beyond a set tolerance, a blank explanation should be refused, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT close_run_balance(%L, 'f253: the electrolyte evaporated, not weighed')$q$, run_c));
    IF v_msg <> 'OK' OR (SELECT within_tolerance FROM processing_run_closures WHERE run_id = run_c) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 253 CLOSE: beyond tolerance with an explanation should close (within_tolerance false), got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$INSERT INTO processing_run_closures (run_id, input_qty, output_qty, named_loss_qty, remainder_qty, tolerance_pct, within_tolerance) VALUES (%L, 100, 80, 0, 20, 5, false)$q$, run_c));
    IF v_msg NOT LIKE '%processing_run_closures_explained%' THEN RAISE EXCEPTION 'FIXTURE 253 CLOSE: the table itself must refuse an unexplained closure beyond tolerance, got %', v_msg; END IF;
    UPDATE operation_types SET balance_tolerance_pct = NULL WHERE code = 'manual_disassembly';

    -- ══════════════ WEIGH · 称重 ══════════════
    RAISE NOTICE 'fixture 253 · WEIGH';
    v_n := (SELECT count(*) FROM weighings);
    run3 := commit_processing_run(d, 'f253 typed', NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', ib, 'quantity_consumed', 50)),
        jsonb_build_array(jsonb_build_object('material_id', m_out, 'weight_kg', 45)), 'weight', NULL, NULL, 'manual_disassembly',
        p_started_at => t0, p_ended_at => t1, p_shift_code => 'day');
    SELECT po.weighing_id INTO w1 FROM processing_outputs po WHERE po.run_id = run3;
    IF (SELECT count(*) FROM weighings) <> v_n + 1 OR w1 IS NULL
       OR (SELECT source FROM weighings WHERE id = w1) <> 'manual' OR (SELECT weight_kg FROM weighings WHERE id = w1) <> 45
       OR (SELECT b.source FROM weighings w JOIN ingest_inbox b ON b.id = w.inbox_id WHERE w.id = w1) <> 'manual'
       OR (SELECT quantity_produced FROM processing_outputs WHERE run_id = run3) <> 45 THEN
        RAISE EXCEPTION 'FIXTURE 253 WEIGH: a typed weight should record one manual weighing through the inbox in the same transaction and carry it on the leg'; END IF;
    w2 := (submit_manual_capture('weighing', '{"weight_kg": 30}'::jsonb) ->> 'weighing_id')::uuid;
    IF NOT EXISTS (SELECT 1 FROM run_weighing_options WHERE weighing_id = w2 AND calibration_status = 'not_recorded') THEN
        RAISE EXCEPTION 'FIXTURE 253 WEIGH: a standalone weighing with no instrument should be offered and flagged not_recorded'; END IF;
    run2 := commit_processing_run(d, 'f253 picked', NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', ib, 'quantity_consumed', 40)),
        jsonb_build_array(jsonb_build_object('material_id', m_out, 'weighing_id', w2)), 'weight', NULL, NULL, 'manual_disassembly',
        p_started_at => t0, p_ended_at => t1, p_shift_code => 'day');
    IF (SELECT weighing_id FROM processing_outputs WHERE run_id = run2) <> w2 OR (SELECT quantity_produced FROM processing_outputs WHERE run_id = run2) <> 30 THEN
        RAISE EXCEPTION 'FIXTURE 253 WEIGH: a picked weighing should set the leg quantity (30)'; END IF;
    IF EXISTS (SELECT 1 FROM run_weighing_options WHERE weighing_id = w2) THEN RAISE EXCEPTION 'FIXTURE 253 WEIGH: a used weighing should leave the options'; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 40)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weighing_id', %L)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day')$q$, d, ib, m_out, w2, t0, t1));
    IF v_msg <> format('WEIGHING_ALREADY_USED|%s', (SELECT code FROM processing_runs WHERE id = run2)) THEN RAISE EXCEPTION 'FIXTURE 253 WEIGH: a weighing used by another leg should be refused, got %', v_msg; END IF;
    w3 := (submit_manual_capture('weighing', '{"weight_kg": 20}'::jsonb) ->> 'weighing_id')::uuid;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 40)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weighing_id', %L), jsonb_build_object('material_id', %L, 'weighing_id', %L)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day')$q$, d, ib, m_out, w3, m_out, w3, t0, t1));
    IF v_msg <> 'WEIGHING_ALREADY_USED|2' THEN RAISE EXCEPTION 'FIXTURE 253 WEIGH: the same weighing on two legs of one run should be refused, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 40)), jsonb_build_array(jsonb_build_object('material_id', %L, 'quantity', 20)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day')$q$, d, ib, m_out, t0, t1));
    IF v_msg <> 'OUTPUT_WEIGHING_REQUIRED|1' THEN RAISE EXCEPTION 'FIXTURE 253 WEIGH: a leg with a quantity and no weighing should be OUTPUT_WEIGHING_REQUIRED, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 40)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weighing_id', %L, 'unit', 'pcs')), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day')$q$, d, ib, m_out, w3, t0, t1));
    IF v_msg <> 'OUTPUT_UNIT_NOT_KG|1|pcs' THEN RAISE EXCEPTION 'FIXTURE 253 WEIGH: a weighed leg is in kg, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 40)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weighing_id', %L, 'quantity', 21)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day')$q$, d, ib, m_out, w3, t0, t1));
    IF v_msg <> 'OUTPUT_QTY_NOT_WEIGHING|1|21|20' THEN RAISE EXCEPTION 'FIXTURE 253 WEIGH: a quantity different from the weighing should be refused, got %', v_msg; END IF;
    -- 没记仪器:开关空着照收,开关给了(加工日在它之后)按名拒
    UPDATE ingest_settings SET require_calibrated_since = d - 10;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 40)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weighing_id', %L)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day')$q$, d, ib, m_out, w3, t0, t1));
    UPDATE ingest_settings SET require_calibrated_since = NULL;
    IF v_msg <> 'OUTPUT_WEIGHING_INSTRUMENT_NOT_RECORDED|1' THEN RAISE EXCEPTION 'FIXTURE 253 WEIGH: with the switch on, a weighing with no instrument should be refused, got %', v_msg; END IF;
    -- 被更正过的称重拒;更正它之前它没被用
    PERFORM correct_weighing(w3, 21, 'f253 re-weighed');
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 40)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weighing_id', %L)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day')$q$, d, ib, m_out, w3, t0, t1));
    IF v_msg <> format('WEIGHING_SUPERSEDED|%s', w3) THEN RAISE EXCEPTION 'FIXTURE 253 WEIGH: a superseded weighing should be refused, got %', v_msg; END IF;
    -- 用上之后那条称重不能再更正
    v_msg := pg_temp.f253_do(format($q$SELECT correct_weighing(%L, 31, 'f253')$q$, w2));
    IF v_msg <> format('WEIGHING_IN_USE|%s', (SELECT code FROM processing_runs WHERE id = run2)) THEN RAISE EXCEPTION 'FIXTURE 253 WEIGH: correcting a weighing used by an output should be WEIGHING_IN_USE, got %', v_msg; END IF;
    -- 不在校准期内的仪器:拒(开关空着也一样 —— MES-3a 的裁定 1)
    s_exp := (save_device('{"name":"ZZF253 expired scale","kind":"scale","interface_status":"manual_only","capacity":5000}'::jsonb))::uuid;
    SELECT code INTO s_exp_code FROM devices WHERE id = s_exp;
    PERFORM record_instrument_calibration(s_exp, d - 400, d - 30, 'passed');
    w_exp := (submit_manual_capture('weighing', '{"weight_kg": 25}'::jsonb, s_exp) ->> 'weighing_id')::uuid;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 40)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weighing_id', %L)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day')$q$, d, ib, m_out, w_exp, t0, t1));
    IF v_msg NOT LIKE format('READING_INSTRUMENT_NOT_CALIBRATED|%s|%%', s_exp_code) THEN RAISE EXCEPTION 'FIXTURE 253 WEIGH: a weighing from an expired instrument should be refused, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 40)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 25, 'device_id', %L)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day')$q$, d, ib, m_out, s_exp, t0, t1));
    IF v_msg NOT LIKE format('READING_INSTRUMENT_NOT_CALIBRATED|%s|%%', s_exp_code) THEN RAISE EXCEPTION 'FIXTURE 253 WEIGH: a typed weight on an expired instrument should be refused too, got %', v_msg; END IF;

    -- ══════════════ DISCH · 放电不要产出 ══════════════
    RAISE NOTICE 'fixture 253 · DISCH';
    ib2 := pg_temp.f253_ib('ZZ253-IB2', m_pack, v_sup, 300, 'charged_not_discharged', d);
    run_dis := commit_processing_run(d, 'f253 discharge', NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', ib2, 'quantity_consumed', 300)), '[]'::jsonb, 'weight', NULL, NULL, 'deep_discharge',
        p_started_at => t0, p_ended_at => t1, p_shift_code => 'night');
    IF (SELECT balance_state FROM processing_run_balance_all WHERE run_id = run_dis) <> 'not_applicable'
       OR (SELECT loss_qty FROM processing_runs WHERE id = run_dis) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 253 DISCH: a discharge run with no outputs should commit, loss 0, balance not applicable'; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT close_run_balance(%L, 'x')$q$, run_dis));
    IF v_msg NOT LIKE 'RUN_BALANCE_NOT_APPLICABLE|%' THEN RAISE EXCEPTION 'FIXTURE 253 DISCH: a state-changing run has no closure, got %', v_msg; END IF;
    -- ★ MES-5a-1(2026-10-08,MES-5a Step 0 Q5 · Q6 · Q34,Tim):提交本身不核实 —— 这一批照旧"带电未放电",没有"已放电";
    --   记下它每一个模组的"通过"之后才核实(状态断言在结果之后)。
    IF NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE inbound_batch_id = ib2 AND safety_state_code = 'charged_not_discharged' AND ended_at IS NULL)
       OR EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE inbound_batch_id = ib2 AND safety_state_code = 'discharged_verified' AND ended_at IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 253 DISCH: a discharge commit alone verified the batch (MES-5a-1: verification is by module results)'; END IF;
    PERFORM set_batch_module_count('inbound', ib2, 2);
    PERFORM record_discharge_module_result(run_dis, 'inbound', ib2, 'M01', 0.4, 'pass', t1);
    PERFORM record_discharge_module_result(run_dis, 'inbound', ib2, 'M02', 0.5, 'pass', t1);
    IF EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE inbound_batch_id = ib2 AND safety_state_code = 'charged_not_discharged' AND ended_at IS NULL)
       OR NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE inbound_batch_id = ib2 AND safety_state_code = 'discharged_verified'
                        AND ended_at IS NULL AND created_by_run_id = run_dis) THEN
        RAISE EXCEPTION 'FIXTURE 253 DISCH: after every module passed the batch should read discharged and verified, owned by the run'; END IF;

    -- ══════════════ NEWOPS · 两道新工序 ══════════════
    RAISE NOTICE 'fixture 253 · NEWOPS';
    IF (SELECT string_agg(operation_type_code || ':' || safety_state_code, ',' ORDER BY operation_type_code)
          FROM operation_type_safety_states WHERE operation_type_code IN ('casing_removal', 'electrode_separation'))
       <> 'casing_removal:discharged_verified,electrode_separation:discharged_verified' THEN
        RAISE EXCEPTION 'FIXTURE 253 NEWOPS: the two new operations should accept discharged_verified only'; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 50)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 40)), 'weight', NULL, NULL, 'casing_removal', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day')$q$, d,
        pg_temp.f253_ib('ZZ253-IB3', m_cell, v_sup, 100, 'discharged_verified', d), m_dec, t0, t1));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 253 NEWOPS: casing removal should take discharged cells, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 50)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 40)), 'weight', NULL, NULL, 'casing_removal', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day')$q$, d,
        pg_temp.f253_ib('ZZ253-IB4', m_cell, v_sup, 100, 'damaged_deformed', d), m_dec, t0, t1));
    IF v_msg NOT LIKE 'INPUT_SAFETY_STATE_NOT_%' THEN RAISE EXCEPTION 'FIXTURE 253 NEWOPS: casing removal must not take damaged cells, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 50)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 20)), 'weight', NULL, NULL, 'electrode_separation', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day')$q$, d,
        pg_temp.f253_ib_wound('ZZ253-IB5', m_dec, v_sup, 100, 'discharged_verified', d), m_out, t0, t1));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 253 NEWOPS: electrode separation should take discharged de-cased cells, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 50)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 20)), 'weight', NULL, NULL, 'electrode_separation', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day')$q$, d,
        pg_temp.f253_ib('ZZ253-IB6', m_dec, v_sup, 100, 'charged_not_discharged', d), m_out, t0, t1));
    IF v_msg NOT LIKE 'INPUT_SAFETY_STATE_NOT_%' THEN RAISE EXCEPTION 'FIXTURE 253 NEWOPS: electrode separation must not take charged material, got %', v_msg; END IF;

    -- ══════════════ CORR · 表头更正与 corrects_run_id ══════════════
    RAISE NOTICE 'fixture 253 · CORR';
    v_cnt0 := (SELECT count(*) FROM processing_run_corrections WHERE run_id = run2);
    PERFORM correct_run_header(run2, 'started_at', (t0 - interval '30 minutes')::text, 'f253 started earlier');
    PERFORM correct_run_header(run2, 'ended_at', (t1 + interval '30 minutes')::text, 'f253 ended later');
    PERFORM correct_run_header(run2, 'shift_code', 'night', 'f253 wrong shift');
    PERFORM correct_run_header(run2, 'equipment_id', a_eq2::text, 'f253 it ran on machine two');
    PERFORM correct_run_header(run2, 'recipe_version_id', rv2::text, 'f253 version two was on the card');
    PERFORM correct_run_header(run2, 'notes', 'f253 corrected note', 'f253 note');
    IF (SELECT count(*) FROM processing_run_corrections WHERE run_id = run2) <> v_cnt0 + 6
       OR (SELECT shift_code FROM processing_runs WHERE id = run2) <> 'night'
       OR (SELECT equipment_id FROM processing_runs WHERE id = run2) <> a_eq2
       OR (SELECT recipe_version_id FROM processing_runs WHERE id = run2) <> rv2
       OR (SELECT old_value FROM processing_run_corrections WHERE run_id = run2 AND field = 'shift_code') <> 'day' THEN
        RAISE EXCEPTION 'FIXTURE 253 CORR: each of the six fields should correct, leaving one row each with the old value'; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT correct_run_header(%L, 'process_date', %L, 'f253')$q$, run2, d - 1));
    IF v_msg <> 'RUN_HEADER_FIELD_NOT_CORRECTABLE|process_date' THEN RAISE EXCEPTION 'FIXTURE 253 CORR: process_date is not correctable, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT correct_run_header(%L, 'notes', 'y', ' ')$q$, run2));
    IF v_msg <> 'RUN_HEADER_CORRECTION_REASON_REQUIRED' THEN RAISE EXCEPTION 'FIXTURE 253 CORR: a reason is required, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT correct_run_header(%L, 'ended_at', %L, 'f253')$q$, run2, (t0 - interval '2 hours')::text));
    IF v_msg NOT LIKE 'RUN_END_BEFORE_START|%' THEN RAISE EXCEPTION 'FIXTURE 253 CORR: a corrected end must still follow the start, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253 redo', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 10)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 10)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day', p_corrects_run_id => %L)$q$, d, ib, m_out, t0, t1, run3));
    IF v_msg <> format('RUN_CORRECTS_NOT_REVERSED|%s', (SELECT code FROM processing_runs WHERE id = run3)) THEN RAISE EXCEPTION 'FIXTURE 253 CORR: a replacement must point at a reversed run, got %', v_msg; END IF;
    PERFORM rollback_processing_run_internal(run3, 'f253 quantities were wrong', u_all);
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253 redo', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 10)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 10)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day', p_corrects_run_id => %L)$q$, d, ib, m_out, t0, t1, run3));
    IF v_msg <> 'OK' OR NOT EXISTS (SELECT 1 FROM processing_runs WHERE corrects_run_id = run3) THEN RAISE EXCEPTION 'FIXTURE 253 CORR: a replacement of a reversed run should commit, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do(format($q$SELECT commit_processing_run(%L::date, 'f253 redo 2', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 10)), jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 10)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => %L::timestamptz, p_ended_at => %L::timestamptz, p_shift_code => 'day', p_corrects_run_id => %L)$q$, d, ib, m_out, t0, t1, run3));
    IF v_msg NOT LIKE format('RUN_ALREADY_CORRECTED|%s|%%', (SELECT code FROM processing_runs WHERE id = run3)) THEN RAISE EXCEPTION 'FIXTURE 253 CORR: a run is corrected once, got %', v_msg; END IF;

    -- ══════════════ POL · 写策略 ══════════════
    RAISE NOTICE 'fixture 253 · POL';
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                 AND ((tablename IN ('processing_runs', 'processing_outputs', 'processing_inputs') AND cmd IN ('UPDATE', 'DELETE', 'ALL'))
                      OR (tablename = 'processing_run_losses' AND cmd <> 'SELECT'))) THEN
        RAISE EXCEPTION 'FIXTURE 253 POL: the processing UPDATE policies and the loss write policies should be gone'; END IF;
    PERFORM pg_temp.f253_as(u_edit);
    v_msg := pg_temp.f253_do(format($q$UPDATE processing_runs SET notes = 'x' WHERE id = %L$q$, run2), true);
    PERFORM pg_temp.f253_as(u_all);
    IF v_msg <> 'PROCESSING_THROUGH_FUNCTION_ONLY|processing_runs|update' THEN RAISE EXCEPTION 'FIXTURE 253 POL: a direct header update should be refused by name, got %', v_msg; END IF;

    -- ══════════════ MONTH · 月末警告 · 提醒臂 ══════════════
    RAISE NOTICE 'fixture 253 · MONTH';
    SELECT run_count INTO v_n FROM processing_runs_unclosed_balance(CURRENT_DATE);
    IF v_n <> (SELECT count(*) FROM processing_run_balance_all WHERE balance_state = 'open' AND process_date <= CURRENT_DATE) OR v_n = 0 THEN
        RAISE EXCEPTION 'FIXTURE 253 MONTH: the month-end reader should count the open runs, got %', v_n; END IF;
    IF (SELECT run_codes FROM processing_runs_unclosed_balance(CURRENT_DATE)) LIKE '%ZZ253-OLD%' THEN
        RAISE EXCEPTION 'FIXTURE 253 MONTH: a pre-MES-4a run is never listed'; END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM pg_temp.f253_as(u_view);
    SELECT count(*) INTO v_n FROM operations_now WHERE item_type = 'processing_balance_unclosed' AND item_id = run2;
    SELECT count(*) INTO v_cnt0 FROM operations_now WHERE item_type = 'processing_balance_unclosed' AND item_id = run_c;
    RESET ROLE;
    PERFORM pg_temp.f253_as(u_all);
    IF v_n <> 1 OR v_cnt0 <> 0 THEN RAISE EXCEPTION 'FIXTURE 253 MONTH: the reminder should list an open run (got %) and not a closed one (got %)', v_n, v_cnt0; END IF;

    -- ══════════════ COST · 分摊与结平互不等待 ══════════════
    RAISE NOTICE 'fixture 253 · COST';
    run_cost := run2;   -- 开着(没结平)
    PERFORM allocate_processing_costs(run_cost, 'weight');
    IF (SELECT allocated_at FROM processing_runs WHERE id = run_cost) IS NULL OR (SELECT balance_state FROM processing_run_balance_all WHERE run_id = run_cost) <> 'open' THEN
        RAISE EXCEPTION 'FIXTURE 253 COST: an unclosed run should allocate, and allocation should not touch its balance state'; END IF;
    IF (SELECT run_count FROM processing_runs_blocking_close(CURRENT_DATE)) <> (SELECT count(*) FROM processing_runs WHERE status = 'committed' AND deleted_at IS NULL AND allocated_at IS NULL AND process_date <= CURRENT_DATE) THEN
        RAISE EXCEPTION 'FIXTURE 253 COST: the close-period reader must still count only unallocated runs'; END IF;
    v_txt := (SELECT allocated_at::text || '/' || COALESCE(total_cost_base::text, '-') FROM processing_runs WHERE id = run_cost);
    PERFORM close_run_balance(run_cost, 'f253 cost arm');
    IF (SELECT allocated_at::text || '/' || COALESCE(total_cost_base::text, '-') FROM processing_runs WHERE id = run_cost) <> v_txt THEN
        RAISE EXCEPTION 'FIXTURE 253 COST: closing must not change the allocation'; END IF;
    PERFORM allocate_processing_costs(run_cost, 'weight');
    IF (SELECT balance_state FROM processing_run_balance_all WHERE run_id = run_cost) <> 'closed' THEN
        RAISE EXCEPTION 'FIXTURE 253 COST: re-allocating must not reopen a closed balance'; END IF;

    -- ══════════════ PV · 待补的值 ══════════════
    RAISE NOTICE 'fixture 253 · PV';
    IF NOT EXISTS (SELECT 1 FROM pending_values WHERE value_code = 'V1' AND item_code = 'casing_removal')
       OR EXISTS (SELECT 1 FROM pending_values WHERE value_code = 'V1' AND item_code = 'deep_discharge') THEN
        RAISE EXCEPTION 'FIXTURE 253 PV: V1 lists transforming operations with no tolerance, never the discharge'; END IF;
    UPDATE operation_types SET balance_tolerance_pct = 2 WHERE code = 'casing_removal';
    IF EXISTS (SELECT 1 FROM pending_values WHERE value_code = 'V1' AND item_code = 'casing_removal') THEN
        RAISE EXCEPTION 'FIXTURE 253 PV: V1 should disappear once the tolerance is set'; END IF;
    IF EXISTS (SELECT 1 FROM pending_values WHERE value_code = 'V36' AND item_code = 'manual_disassembly/blade_speed') THEN
        RAISE EXCEPTION 'FIXTURE 253 PV: a field whose range is given is not pending'; END IF;
    INSERT INTO operation_type_fields (operation_type_code, field_code, name_en, name_zh, kind, value_type, unit, has_range, sort_order)
    VALUES ('casing_removal', 'blade_depth', 'Blade depth', '刀深', 'parameter', 'number', 'mm', true, 200);
    IF NOT EXISTS (SELECT 1 FROM pending_values WHERE value_code = 'V36' AND item_code = 'casing_removal/blade_depth'
                     AND href = '/operation/operation-types/casing_removal') THEN
        RAISE EXCEPTION 'FIXTURE 253 PV: a field with a range and no bounds should be V36'; END IF;
    UPDATE operation_type_fields SET range_min = 1, range_max = 3 WHERE operation_type_code = 'casing_removal' AND field_code = 'blade_depth';
    IF EXISTS (SELECT 1 FROM pending_values WHERE value_code = 'V36' AND item_code = 'casing_removal/blade_depth') THEN
        RAISE EXCEPTION 'FIXTURE 253 PV: V36 should disappear once the range is set'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pending_values WHERE value_code = 'V6' AND href = '/settings/dictionaries') THEN
        RAISE EXCEPTION 'FIXTURE 253 PV: V6 (and V7) should send people to the shift dictionary'; END IF;
    PERFORM pg_temp.f253_as(NULL);
    IF EXISTS (SELECT 1 FROM pending_values WHERE value_code IN ('V1', 'V36')) THEN
        RAISE EXCEPTION 'FIXTURE 253 PV: a reader without module.processing.view sees no V1 / V36 row'; END IF;
    PERFORM pg_temp.f253_as(u_all);

    -- ══════════════ SHIFT · 班次的起止时刻 ══════════════
    RAISE NOTICE 'fixture 253 · SHIFT';
    PERFORM pg_temp.f253_as(u_edit);
    v_msg := pg_temp.f253_do($q$UPDATE shifts SET starts_at = '07:00' WHERE code = 'day'$q$, true);
    IF v_msg NOT LIKE '%shifts_hours_paired%' THEN RAISE EXCEPTION 'FIXTURE 253 SHIFT: a start without an end should be refused, got %', v_msg; END IF;
    v_msg := pg_temp.f253_do($q$UPDATE shifts SET starts_at = '07:00', ends_at = '19:00' WHERE code = 'day'$q$, true);
    PERFORM pg_temp.f253_as(u_all);
    IF v_msg <> 'OK' OR EXISTS (SELECT 1 FROM pending_values WHERE value_code = 'V6' AND item_code = 'day') THEN
        RAISE EXCEPTION 'FIXTURE 253 SHIFT: both times set by a processing editor should clear V6 for that shift, got %', v_msg; END IF;

    -- ══════════════ TRAIL · 审计记录 ══════════════
    RAISE NOTICE 'fixture 253 · TRAIL';
    IF NOT EXISTS (SELECT 1 FROM record_trail('processing_run', run::text, 200) t WHERE t.table_name = 'processing_run_values')
       OR NOT EXISTS (SELECT 1 FROM record_trail('processing_run', run::text, 200) t WHERE t.table_name = 'processing_run_closures')
       OR NOT EXISTS (SELECT 1 FROM record_trail('processing_run', run2::text, 200) t WHERE t.table_name = 'processing_run_corrections') THEN
        RAISE EXCEPTION 'FIXTURE 253 TRAIL: a run''s trail should carry its values, closures and header corrections'; END IF;
    IF NOT EXISTS (SELECT 1 FROM record_trail('operation_type', 'manual_disassembly', 200) t WHERE t.table_name = 'operation_type_fields')
       OR NOT EXISTS (SELECT 1 FROM record_trail('operation_type', 'manual_disassembly', 200) t WHERE t.table_name = 'process_recipe_versions') THEN
        RAISE EXCEPTION 'FIXTURE 253 TRAIL: an operation''s trail should carry its fields and its recipe versions'; END IF;
    -- MES-4b(2026-10-07,Tim 的 MES-4a close-out 裁定 c · MES-4b Step 0 Q32):两支在 MES-4a 注入之后才改过、而此前没有一格注入够得着的函数 ——
    --   trail_refs 把一个值的字段解析成字段名(两列外键);trail_ref_label 把一个配方版本说成"配方代号 v版本号"。各自钉一句,各自有注入。
    IF NOT EXISTS (SELECT 1 FROM record_trail('processing_run', run::text, 200) t
                    WHERE t.table_name = 'processing_run_values'
                      AND t.refs -> 'field_code' -> (COALESCE(t.new, t.old) ->> 'field_code') ->> 'label' IS NOT NULL
                      AND (t.refs -> 'field_code' -> (COALESCE(t.new, t.old) ->> 'field_code') ->> 'gone')::boolean IS FALSE) THEN
        RAISE EXCEPTION 'FIXTURE 253 TRAIL: a recorded value should name its field in the trail (trail_refs)'; END IF;
    IF (trail_ref_label('process_recipe_versions', 'id', rv1::text) ->> 'label') IS DISTINCT FROM 'ZZ253-STD v1' THEN
        RAISE EXCEPTION 'FIXTURE 253 TRAIL: a recipe version should be labelled "ZZ253-STD v1" (trail_ref_label), got %',
            trail_ref_label('process_recipe_versions', 'id', rv1::text) ->> 'label'; END IF;

    RAISE NOTICE 'FIXTURE 253 全部通过:HDR · MACH · FIELD · EVENT · RECIPE · LOSS · CLOSE · WEIGH · DISCH · NEWOPS · CORR · POL · MONTH · COST · PV · SHIFT · TRAIL';
END;
$$;

ROLLBACK;
