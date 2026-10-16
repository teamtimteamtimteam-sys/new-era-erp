#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// MES-7b-1(2026-10-16)· 线上验证 —— 事故登记:受伤的细节只给持健康码的人与受伤的本人 · 未来时刻与 device 来源按名拒 ·
//   用过的种类代号锁死 · 两种建议(库位 / 机器)· 确认 · 按批号挑 · 带理由解开 · 从链接开一张来源 incident 的不合格报告并暂扣 ·
//   NEA 两条提醒与"未确认"的期限 → 记下通报 → 交了报告 · 交接班引用事故(两页都读得到)· F12 读回 · 七个角色的只读读数表
//   一笔【回滚】的事务;不碰任何桶
// ════════════════════════════════════════════════════════════════════════════
// 【形状】照 db/scripts/2026-10-16-mes7a2-live-proof.mjs:一支 psql,一笔事务从 BEGIN 开到 ROLLBACK(ON_ERROR_STOP:任何一步红,事务中止、
//   连接关掉,等于回滚)。每一步以一次性账号的身份跑:先 set_config('request.jwt.claims') 再 SET LOCAL ROLE authenticated。
//   拒绝在子事务里试(BEGIN … EXCEPTION),不打断整笔。
// 【身份】每一个动作都以一次性账号跑(前缀 mes7b1probe),七个真账号一个都不用:
//   inv = 布景(收货、产出批)—— 持 permissions 表里每一个码的一次性角色(mintThrowaway 'all';它不是 admin,也不是任何真角色)
//   ed  = 记事故与之后的事实、链 / 解(module.safety.view · .edit · inbound / output 查看)—— 不持 data.view_health
//   hl  = module.safety.view + data.view_health
//   inj = 受伤的那名员工(只持 module.tasks.view —— 没有安全码、没有健康码);他的员工行在事务里插、user_id 指向这个账号,随回滚消失
//   qe  = 开不合格报告(module.quality.view · .edit · inbound / output / safety 查看)
//   ho  = 交接班(module.processing.view · .edit)
//   c_<角色> = 七个真账号此刻持有的七个角色的码的克隆(cloneOf,只读;c_cfo 读两条勾稽)
// 【布景】都是我自己的行(前缀 ZZ-PROBE-MES7B1),在事务里插,随回滚消失。在册的东西一行都不改、不决定、不删 ——
//   事故种类那一格改的是迁移自己建的那一行(本次会话造的),也在子事务里、随回滚撤。safety_settings 一个字都不碰。
// 【判决】只从日志里最后那一行 `MES7B1_PROOF_EXIT=` 读。0 = 走完、回滚、一次性账号收干净 · 1 = 证明红了 · 2 = 驱动自己坏了 ·
//   5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:node db/scripts/2026-10-16-mes7b1-live-proof.mjs > <log> 2>&1
// ════════════════════════════════════════════════════════════════════════════
import { onlyWhenRunDirectly } from '../../scripts/lib/entrypoint.mjs'
import { spawnSync } from 'node:child_process'
import { acquireOrExit, release, heldBy } from '../../scripts/liveLock.mjs'
import { openPlan, mintThrowaway, reapStalePlans, installExitHooks, exitAfterCleanup } from '../../scripts/ephemeral.mjs'

onlyWhenRunDirectly(import.meta.url)

const DSN = process.env.CHECK_MIRRORS_DSN || 'host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres'
const ROLES = ['admin', 'cfo', 'finance', 'warehouse', 'cto', 'cco', 'gm']   // 七个真账号此刻各持一个角色(开场读数)

let locked = false
installExitHooks({
    onFinish: (code) => {
        try { if (locked) release() } catch { /* 放锁失败不改判决 */ }
        console.log(`MES7B1_PROOF_EXIT=${code}`)
    },
})

const lit = (s) => `'${String(s).replace(/'/g, "''")}'`

function proofSql(u) {
    const roleArms = ROLES.map((r) => `
    -- ── 角色 ${r}(克隆 ${u['c_' + r]})── 事故清单 · 事故页(那一件受伤的)· 交接班页上的引用 · 待补的值 V19 · 记一件(子事务,成了也撤回)
    v_list := pg_temp.p_count(${lit(u['c_' + r])}, $q$SELECT count(*) FROM incident_rows WHERE code IS NOT NULL$q$);
    v_j    := pg_temp.p_jget(${lit(u['c_' + r])}, format($q$SELECT jsonb_build_object('seen', true, 'injury_visible', r.injury_visible, 'nature', r.injury_nature) FROM incident_rows r WHERE r.id = %L$q$, i_inj));
    v_ho_n := pg_temp.p_count(${lit(u['c_' + r])}, format('SELECT count(*) FROM shift_handover_incident_refs WHERE handover_id = %L', v_ho));
    v_ho_seen := pg_temp.p_count(${lit(u['c_' + r])}, format('SELECT count(*) FROM shift_handovers WHERE id = %L', v_ho));
    v_v19  := pg_temp.p_count(${lit(u['c_' + r])}, $q$SELECT count(*) FROM pending_values WHERE value_code = 'V19'$q$);
    v_rem  := pg_temp.p_count(${lit(u['c_' + r])}, format($q$SELECT count(*) FROM operations_now WHERE item_id = %L$q$, i_mach));
    v_msg  := pg_temp.p_try(${lit(u['c_' + r])}, format($q$SELECT record_incident('near_miss', %L, 'ZZ probe role check', 'none', false, p_responsible_name => 'Probe')$q$, t_m));
    RAISE NOTICE 'ROLE|${r}|codes=%|safety.view=%|safety.edit=%|health=%|incident list rows=%|injury incident=%|handover seen=%|handover refs=%|V19 rows=%|reminders on the machine incident=%|record=%',
        (SELECT count(*) FROM role_permissions rp JOIN user_roles ur ON ur.role_id = rp.role_id WHERE ur.user_id = ${lit(u['c_' + r])} AND ur.revoked_at IS NULL),
        pg_temp.p_has(${lit(u['c_' + r])}, 'module.safety.view'), pg_temp.p_has(${lit(u['c_' + r])}, 'module.safety.edit'), pg_temp.p_has(${lit(u['c_' + r])}, 'data.view_health'),
        v_list, COALESCE(v_j::text, 'not seen'), v_ho_seen, v_ho_n, v_v19, v_rem, left(v_msg, 60);`).join('\n')

    return `\\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.p_as(p_user uuid) RETURNS void LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;
CREATE FUNCTION pg_temp.p_get(p_user uuid, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.p_as(p_user); EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE'; PERFORM pg_temp.p_as(NULL);
    RETURN v;
EXCEPTION WHEN OTHERS THEN EXECUTE 'RESET ROLE'; PERFORM pg_temp.p_as(NULL); RAISE;
END $f$;
-- 同 p_get,但读不到 / 被拒时返回 NULL(角色表用:它只问"读不读得到")
CREATE FUNCTION pg_temp.p_jget(p_user uuid, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.p_as(p_user); EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE'; PERFORM pg_temp.p_as(NULL);
    RETURN v;
EXCEPTION WHEN OTHERS THEN EXECUTE 'RESET ROLE'; PERFORM pg_temp.p_as(NULL); RETURN jsonb_build_object('refused', SQLERRM);
END $f$;
CREATE FUNCTION pg_temp.p_count(p_user uuid, p_sql text) RETURNS bigint LANGUAGE plpgsql AS $f$
DECLARE v bigint;
BEGIN
    PERFORM pg_temp.p_as(p_user); EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE'; PERFORM pg_temp.p_as(NULL);
    RETURN v;
EXCEPTION WHEN OTHERS THEN EXECUTE 'RESET ROLE'; PERFORM pg_temp.p_as(NULL); RETURN -1;
END $f$;
CREATE FUNCTION pg_temp.p_has(p_user uuid, p_code text) RETURNS boolean LANGUAGE plpgsql AS $f$
DECLARE v boolean;
BEGIN
    PERFORM pg_temp.p_as(p_user); v := has_permission(p_code); PERFORM pg_temp.p_as(NULL); RETURN v;
END $f$;
-- 在一个子事务里试一句;返回 'OK' 或那一句的错误。成了也撤回(子事务以 RAISE 结束)
CREATE FUNCTION pg_temp.p_try(p_user uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
    BEGIN
        PERFORM pg_temp.p_as(p_user); EXECUTE 'SET LOCAL ROLE authenticated';
        EXECUTE p_sql;
        RAISE EXCEPTION 'P_TRY_OK';
    EXCEPTION WHEN OTHERS THEN
        EXECUTE 'RESET ROLE'; PERFORM pg_temp.p_as(NULL);
        RETURN CASE WHEN SQLERRM = 'P_TRY_OK' THEN 'OK' ELSE SQLERRM END;
    END;
END $f$;
-- 同 p_try,但成了就【留下】(这一步要被后面读到)
CREATE FUNCTION pg_temp.p_do(p_user uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
    BEGIN
        PERFORM pg_temp.p_as(p_user); EXECUTE 'SET LOCAL ROLE authenticated';
        EXECUTE p_sql;
        EXECUTE 'RESET ROLE'; PERFORM pg_temp.p_as(NULL);
        RETURN 'OK';
    EXCEPTION WHEN OTHERS THEN
        EXECUTE 'RESET ROLE'; PERFORM pg_temp.p_as(NULL);
        RETURN SQLERRM;
    END;
END $f$;
CREATE FUNCTION pg_temp.p_expect(p_what text, p_got text, p_like text) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
    IF p_got IS NULL OR p_got NOT LIKE p_like THEN RAISE EXCEPTION 'MES7B1_LIVE|% expected % got %', p_what, p_like, COALESCE(p_got, '<null>'); END IF;
    RAISE NOTICE 'STEP|%|%', p_what, left(p_got, 120);
END $f$;
-- 两条勾稽(以 cfo 的克隆读):应付 / 应收清单 = 总账,未解释 0.00;存货控制科目对得上
CREATE FUNCTION pg_temp.p_recon(p_step text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v jsonb; s jsonb; txt text := '';
BEGIN
    v := pg_temp.p_get(${lit(u.c_cfo)}, 'SELECT list_ledger_reconciliation()');
    FOR s IN SELECT * FROM jsonb_array_elements(v -> 'sides') LOOP
        txt := txt || concat_ws(' ', s ->> 'side', s ->> 'list_base', '/', s ->> 'ledger_base', '/', s ->> 'unexplained_base') || ' · ';
        IF (s ->> 'unexplained_base')::numeric <> 0 THEN RAISE EXCEPTION 'MES7B1_LIVE|RECON % % list ≠ ledger %', p_step, s ->> 'side', s; END IF;
    END LOOP;
    v := pg_temp.p_get(${lit(u.c_cfo)}, 'SELECT gl_control_reconciliation(CURRENT_DATE)');
    FOR s IN SELECT x FROM jsonb_array_elements(v -> 'sides') x WHERE x ->> 'side' LIKE 'inventory%' LOOP
        txt := txt || concat_ws(' ', s ->> 'side', s ->> 'ledger_base', '/', s ->> 'subledger_base', '/', s ->> 'unexplained_base') || ' · ';
        IF (s ->> 'unexplained_base')::numeric <> 0 OR NOT (s ->> 'reconciled')::boolean THEN
            RAISE EXCEPTION 'MES7B1_LIVE|RECON % inventory control % not reconciled %', p_step, s ->> 'side', s; END IF;
    END LOOP;
    RAISE NOTICE 'STEP|recon %|%', p_step, txt;
END $f$;

DO $proof$
DECLARE
    inv uuid := ${lit(u.inv)}; ed uuid := ${lit(u.ed)}; hl uuid := ${lit(u.hl)}; inj uuid := ${lit(u.inj)};
    qe uuid := ${lit(u.qe)}; ho uuid := ${lit(u.ho)}; c_wh uuid := ${lit(u.c_warehouse)}; c_cfo uuid := ${lit(u.c_cfo)};
    v_base text; v_today date := (now() AT TIME ZONE 'Asia/Singapore')::date; d date := (now() AT TIME ZONE 'Asia/Singapore')::date - 5;
    t_m timestamptz := now() - interval '2 hours';
    e_inj uuid := gen_random_uuid(); e_out uuid := gen_random_uuid(); e_in uuid := gen_random_uuid();
    sup uuid; bm uuid; om uuid; fa uuid; fa2 uuid; loc uuid; ib_l uuid; ib_m uuid; ib_free uuid; ob_m uuid; ob_x uuid;
    run_m uuid; dt_m uuid; dt_x uuid; ev_w bigint;
    i_inj uuid; i_nr uuid; i_loc uuid; i_mach uuid; v_ho uuid; v_link bigint; v_shift text; v_items jsonb;
    v_ss_n bigint; v_mv_n bigint; v_j jsonb; v_msg text; v_n bigint; v_n2 bigint; v_txt text;
    v_list bigint; v_ho_n bigint; v_ho_seen bigint; v_v19 bigint; v_rem bigint;
BEGIN
    RAISE NOTICE 'STEP|who|%|bypassrls=%', current_user, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user);
    SELECT code INTO v_base FROM currencies WHERE is_base;
    IF EXISTS (SELECT 1 FROM materials WHERE code LIKE 'ZZ-PROBE-MES7B1%') THEN RAISE EXCEPTION 'MES7B1_LIVE|probe rows already exist'; END IF;
    RAISE NOTICE 'STEP|before|incidents %|updates %|links %|handover refs %|V19 % confirmed=%', (SELECT count(*) FROM incidents), (SELECT count(*) FROM incident_updates),
        (SELECT count(*) FROM incident_batches), (SELECT count(*) FROM shift_handover_incident_refs),
        (SELECT nea_report_working_days FROM safety_settings), (SELECT nea_report_days_confirmed_at IS NOT NULL FROM safety_settings);
    -- F12:迁移写下、并在同一笔事务里读回过的那一句,现在仍在
    v_txt := (SELECT notes FROM material_kinds WHERE code = 'spare_part');
    IF v_txt NOT LIKE '%received as lots so stock and cost are counted%' OR v_txt NOT LIKE '%no per-piece traceability%' THEN
        RAISE EXCEPTION 'MES7B1_LIVE|F12 note %', v_txt; END IF;
    RAISE NOTICE 'STEP|F12 read back|%', left(v_txt, 160);
    PERFORM pg_temp.p_recon('before anything');

    -- ── 布景(属主插,我自己的行)──
    INSERT INTO employees (id, code, legal_name, preferred_name, employment_type, work_category, hire_date, user_id) VALUES
        (e_inj, 'ZZ-PROBE-MES7B1-E1', 'ZZ probe injured worker', 'Probe Hurt', 'full_time', 'shopfloor', DATE '2020-01-01', inj),
        (e_out, 'ZZ-PROBE-MES7B1-E2', 'ZZ probe outgoing', 'Probe Out', 'full_time', 'shopfloor', DATE '2020-01-01', NULL),
        (e_in,  'ZZ-PROBE-MES7B1-E3', 'ZZ probe incoming', 'Probe In', 'full_time', 'shopfloor', DATE '2020-01-01', NULL);
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ-PROBE-MES7B1-S', 'ZZ probe cells vendor', 'SG', 'active', 'goods_supplier') RETURNING id INTO sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ-PROBE-MES7B1-BM', 'ZZ probe modules', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO bm;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ-PROBE-MES7B1-OUT', 'ZZ probe output', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO om;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_ccy, currency, fx_rate, cost_base, useful_life_months, residual_base)
    VALUES ('ZZ-PROBE-MES7B1-M', 'ZZ probe shredder', 'equipment', d - 50, 0, v_base, 1, 0, 60, 0) RETURNING id INTO fa;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_ccy, currency, fx_rate, cost_base, useful_life_months, residual_base)
    VALUES ('ZZ-PROBE-MES7B1-M2', 'ZZ probe other machine', 'equipment', d - 50, 0, v_base, 1, 0, 60, 0) RETURNING id INTO fa2;
    INSERT INTO storage_locations (code, name, is_active) VALUES ('ZZ-PROBE-MES7B1-L1', 'ZZ probe discharge bay', true) RETURNING id INTO loc;
    ib_l := (pg_temp.p_get(inv, format($q$SELECT create_inbound_batch(%L, %L, 100, 'kg', %L, '待加工', p_location_id => %L, p_safety_states => ARRAY['discharged_verified'],
                 p_source_reason_code => 'other', p_source_reason_note => 'ZZ probe at the bay')$q$, bm, sup, d, loc)) ->> 'batch_id')::uuid;
    ib_m := (pg_temp.p_get(inv, format($q$SELECT create_inbound_batch(%L, %L, 40, 'kg', %L, '待加工', p_safety_states => ARRAY['discharged_verified'],
                 p_source_reason_code => 'other', p_source_reason_note => 'ZZ probe fed to the machine')$q$, bm, sup, d)) ->> 'batch_id')::uuid;
    ib_free := (pg_temp.p_get(inv, format($q$SELECT create_inbound_batch(%L, %L, 30, 'kg', %L, '待加工', p_safety_states => ARRAY['discharged_verified'],
                 p_source_reason_code => 'other', p_source_reason_note => 'ZZ probe picked by code')$q$, bm, sup, d)) ->> 'batch_id')::uuid;
    ob_m := (pg_temp.p_get(inv, format($q$SELECT create_output_batch(%L, 10, 'kg', %L)$q$, om, d)) ->> 'batch_id')::uuid;
    ob_x := (pg_temp.p_get(inv, format($q$SELECT create_output_batch(%L, 10, 'kg', %L)$q$, om, d)) ->> 'batch_id')::uuid;
    SELECT code INTO v_shift FROM shifts WHERE is_active ORDER BY sort_order, code LIMIT 1;
    -- 一张在 t_m 那一刻在机器上跑的已提交单(属主插,与 fixture 267 / MES-7a-1 的证明同一种处置 —— 它不是被证的那条路)
    INSERT INTO processing_runs (code, status, allocation_basis, process_date, operation_type_code, equipment_id, started_at, ended_at, shift_code)
    VALUES ('ZZ-PROBE-MES7B1-RUN', 'committed', 'weight', (t_m AT TIME ZONE 'Asia/Singapore')::date, 'manual_disassembly', fa, t_m - interval '1 hour', t_m + interval '1 hour', v_shift)
    RETURNING id INTO run_m;
    PERFORM set_config('evoltrya.movement_ctx', 'processing:' || run_m, true);
    INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed) VALUES (run_m, ib_m, 10);
    PERFORM set_config('evoltrya.movement_ctx', '', true);
    INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced) VALUES (run_m, ob_m, 10);
    INSERT INTO equipment_downtime (equipment_id, started_at, ended_at, reason, cause_code, source)
    VALUES (fa, t_m - interval '10 minutes', t_m + interval '20 minutes', 'ZZ probe stop after the smoke', 'breakdown', 'manual') RETURNING id INTO dt_m;
    INSERT INTO equipment_downtime (equipment_id, started_at, ended_at, reason, cause_code, source)
    VALUES (fa2, t_m - interval '10 minutes', t_m + interval '20 minutes', 'ZZ probe stop on the other machine', 'breakdown', 'manual') RETURNING id INTO dt_x;
    INSERT INTO processing_run_events (run_id, event_type_code, occurred_at, action_taken, responsible_person)
    VALUES (run_m, 'safety_alarm', t_m, 'ZZ probe alarm', 'Probe') RETURNING id INTO ev_w;
    INSERT INTO processing_run_events (run_id, event_type_code, occurred_at, action_taken, responsible_person, withdrawn, corrects_id, correction_reason)
    VALUES (run_m, 'safety_alarm', t_m, 'ZZ probe alarm', 'Probe', true, ev_w, 'ZZ probe false alarm');
    RAISE NOTICE 'STEP|scenery|bay batch %|run %|downtime on M %|other machine %', (SELECT code FROM inbound_batches WHERE id = ib_l), run_m, dt_m, dt_x;
    PERFORM pg_temp.p_recon('after the receipts');

    -- ── 1 受伤:细节只给健康码与本人 ──
    v_j := pg_temp.p_get(ed, format($q$SELECT record_incident('injury', %L, 'ZZ probe: a cell vented and burned a hand', 'First aid; area cleared', true,
               p_responsible_name => 'Probe lead', p_location_id => %L, p_injured_employee_id => %L, p_injury_nature => 'ZZ burn to the left hand',
               p_injury_treatment => 'ZZ outpatient', p_days_lost => 2)$q$, t_m, loc, e_inj));
    i_inj := (v_j ->> 'incident_id')::uuid;
    RAISE NOTICE 'STEP|recorded|% (injury, NEA-reportable)', v_j ->> 'code';
    v_j := pg_temp.p_get(ed, format($q$SELECT record_incident('near_miss', %L, 'ZZ probe: a pallet nearly fell', 'Re-stacked', false, p_responsible_name => 'Probe lead')$q$, t_m));
    i_nr := (v_j ->> 'incident_id')::uuid;
    RAISE NOTICE 'STEP|recorded|% (near miss)', v_j ->> 'code';
    v_j := pg_temp.p_get(c_wh, format($q$SELECT to_jsonb(r) FROM incident_rows r WHERE r.id = %L$q$, i_inj));
    IF v_j IS NULL OR (v_j ->> 'injury_visible')::boolean OR v_j ->> 'injury_nature' IS NOT NULL OR v_j ->> 'injured_employee_id' IS NOT NULL THEN
        RAISE EXCEPTION 'MES7B1_LIVE|warehouse clone sees the injury: %', v_j; END IF;
    RAISE NOTICE 'STEP|mask|warehouse clone (safety view, no health): incident seen, injury_visible=false, nature=%, days_lost=%', COALESCE(v_j ->> 'injury_nature', 'NULL'), COALESCE(v_j ->> 'days_lost', 'NULL');
    v_msg := pg_temp.p_do(c_wh, format($q$SELECT injury_nature FROM incidents WHERE id = %L$q$, i_inj));
    PERFORM pg_temp.p_expect('mask|warehouse clone reads the base column', v_msg, 'permission denied%');
    v_j := pg_temp.p_get(hl, format($q$SELECT to_jsonb(r) FROM incident_rows r WHERE r.id = %L$q$, i_inj));
    IF NOT (v_j ->> 'injury_visible')::boolean OR v_j ->> 'injury_nature' <> 'ZZ burn to the left hand' THEN RAISE EXCEPTION 'MES7B1_LIVE|health holder: %', v_j; END IF;
    RAISE NOTICE 'STEP|mask|health holder sees %, % days lost', v_j ->> 'injury_nature', v_j ->> 'days_lost';
    v_j := pg_temp.p_get(inj, format($q$SELECT to_jsonb(r) FROM incident_rows r WHERE r.id = %L$q$, i_inj));
    IF v_j IS NULL OR NOT (v_j ->> 'injury_visible')::boolean OR v_j ->> 'injury_nature' <> 'ZZ burn to the left hand' THEN
        RAISE EXCEPTION 'MES7B1_LIVE|the injured person (no safety code) does not read their own incident: %', v_j; END IF;
    v_n := pg_temp.p_count(inj, format('SELECT count(*) FROM incident_rows WHERE id = %L', i_nr));
    v_n2 := pg_temp.p_count(inj, 'SELECT count(*) FROM incident_rows');
    IF v_n <> 0 OR v_n2 <> 1 THEN RAISE EXCEPTION 'MES7B1_LIVE|the injured person reads other incidents (% / %)', v_n, v_n2; END IF;
    RAISE NOTICE 'STEP|self|the injured person (only module.tasks.view) reads their own incident with the injury, and no other (rows seen %)', v_n2;
    v_j := pg_temp.p_get(c_wh, format($q$SELECT t.new FROM record_trail('incident', %L) t WHERE t.table_name = 'incidents' AND t.op = 'INSERT'$q$, i_inj));
    IF v_j -> 'injury_nature' IS DISTINCT FROM '{"$restricted": true}'::jsonb THEN RAISE EXCEPTION 'MES7B1_LIVE|trail for warehouse clone: %', v_j; END IF;
    v_j := pg_temp.p_get(c_cfo, format($q$SELECT t.new FROM record_trail('incident', %L) t WHERE t.table_name = 'incidents' AND t.op = 'INSERT'$q$, i_inj));
    RAISE NOTICE 'STEP|trail|warehouse clone reads injury_nature = {"$restricted": true}; cfo clone (health) reads "%"', v_j ->> 'injury_nature';

    -- ── 2 拒:未来时刻 · device 来源 ──
    v_msg := pg_temp.p_try(ed, format($q$SELECT record_incident('fire_smoke', %L, 'x', 'y', false, p_responsible_name => 'Probe')$q$, now() + interval '1 hour'));
    PERFORM pg_temp.p_expect('refused|future time', v_msg, 'INCIDENT_TIME_IN_FUTURE|%');
    v_msg := pg_temp.p_try(ed, format($q$SELECT record_incident('fire_smoke', %L, 'x', 'y', false, p_responsible_name => 'Probe', p_source => 'device')$q$, t_m));
    PERFORM pg_temp.p_expect('refused|device source', v_msg, 'INCIDENT_SOURCE_RESERVED|device');
    v_msg := pg_temp.p_try(${lit(u.c_gm)}, format($q$SELECT record_incident('fire_smoke', %L, 'x', 'y', false, p_responsible_name => 'Probe')$q$, t_m));
    PERFORM pg_temp.p_expect('refused|gm clone has no edit code', v_msg, 'PERMISSION_DENIED|module.safety.edit');

    -- ── 3 种类代号锁死(用过的)· 名字照改 ──
    v_msg := pg_temp.p_try(ed, $q$UPDATE incident_kinds SET code = 'injuries' WHERE code = 'injury'$q$);
    PERFORM pg_temp.p_expect('kind|used code locked', v_msg, 'INCIDENT_KIND_CODE_LOCKED|injury|1');
    v_msg := pg_temp.p_try(ed, $q$UPDATE incident_kinds SET name_en = 'Injury at work' WHERE code = 'injury'$q$);
    PERFORM pg_temp.p_expect('kind|rename (tried, rolled back)', v_msg, 'OK');

    -- ── 4 建议 · 确认 · 按批号挑 · 解开 —— 从不设安全状态、从不动货 ──
    v_j := pg_temp.p_get(ed, format($q$SELECT record_incident('gas_release', %L, 'ZZ probe: electrolyte smell at the bay', 'Bay ventilated', false, p_responsible_name => 'Probe lead', p_location_id => %L)$q$, now(), loc));
    i_loc := (v_j ->> 'incident_id')::uuid;
    v_j := pg_temp.p_get(ed, format($q$SELECT record_incident('fire_smoke', %L, 'ZZ probe: smoke from the shredder', 'E-stop pressed', true, p_responsible_name => 'Probe lead', p_equipment_id => %L, p_downtime_id => %L)$q$, t_m, fa, dt_m));
    i_mach := (v_j ->> 'incident_id')::uuid;
    SELECT count(*) INTO v_ss_n FROM inbound_batch_safety_states; SELECT count(*) INTO v_mv_n FROM inventory_movements;
    v_j := pg_temp.p_get(ed, format($q$SELECT jsonb_agg(jsonb_build_object('basis', s.basis, 'batch', s.batch_code, 'evidence', s.evidence, 'qty', s.qty) ORDER BY s.basis, s.batch_code) FROM suggest_incident_batches(%L) s$q$, i_loc));
    IF (SELECT count(*) FROM jsonb_array_elements(v_j) x WHERE x ->> 'basis' = 'location' AND x ->> 'batch' = (SELECT code FROM inbound_batches WHERE id = ib_l)) <> 1 THEN
        RAISE EXCEPTION 'MES7B1_LIVE|location suggestion %', v_j; END IF;
    RAISE NOTICE 'STEP|suggest|location incident → %', v_j;
    v_j := pg_temp.p_get(ed, format($q$SELECT jsonb_agg(jsonb_build_object('basis', s.basis, 'batch', s.batch_code, 'evidence', s.evidence, 'qty', s.qty) ORDER BY s.basis, s.batch_code) FROM suggest_incident_batches(%L) s$q$, i_mach));
    IF (SELECT count(*) FROM jsonb_array_elements(v_j) x WHERE x ->> 'basis' = 'machine_run' AND x ->> 'evidence' = 'ZZ-PROBE-MES7B1-RUN') <> 2 THEN
        RAISE EXCEPTION 'MES7B1_LIVE|machine suggestion %', v_j; END IF;
    RAISE NOTICE 'STEP|suggest|machine incident → %', v_j;
    v_msg := pg_temp.p_do(ed, format($q$SELECT link_incident_batch(%L, 'location', p_inbound_batch_id => %L)$q$, i_loc, ib_l));
    PERFORM pg_temp.p_expect('link|confirm the location suggestion', v_msg, 'OK');
    v_msg := pg_temp.p_do(ed, format($q$SELECT link_incident_batch(%L, 'machine_run', p_output_batch_id => %L)$q$, i_mach, ob_m));
    PERFORM pg_temp.p_expect('link|confirm the machine suggestion (output)', v_msg, 'OK');
    v_msg := pg_temp.p_try(ed, format($q$SELECT link_incident_batch(%L, 'location', p_inbound_batch_id => %L)$q$, i_loc, ib_free));
    PERFORM pg_temp.p_expect('link|a batch not in the suggestions', v_msg, 'INCIDENT_LINK_NOT_SUGGESTED|location|%');
    v_msg := pg_temp.p_do(ed, format($q$SELECT link_incident_batch(%L, 'picked', p_inbound_batch_id => %L)$q$, i_mach, ib_free));
    PERFORM pg_temp.p_expect('link|pick a batch by code', v_msg, 'OK');
    SELECT id INTO v_link FROM incident_batches WHERE incident_id = i_mach AND inbound_batch_id = ib_free;
    v_msg := pg_temp.p_try(ed, format($q$SELECT unlink_incident_batch(%L, '  ')$q$, v_link));
    PERFORM pg_temp.p_expect('link|unlink without a reason', v_msg, 'INCIDENT_UNLINK_REASON_REQUIRED');
    v_msg := pg_temp.p_do(ed, format($q$SELECT unlink_incident_batch(%L, 'ZZ probe: picked by mistake')$q$, v_link));
    PERFORM pg_temp.p_expect('link|unlink with a reason', v_msg, 'OK');
    v_msg := pg_temp.p_try(ed, format($q$SELECT unlink_incident_batch(%L, 'again')$q$, v_link));
    PERFORM pg_temp.p_expect('link|unlink twice', v_msg, 'INCIDENT_LINK_ALREADY_UNLINKED|%');
    IF (SELECT count(*) FROM inbound_batch_safety_states) <> v_ss_n OR (SELECT count(*) FROM inventory_movements) <> v_mv_n THEN
        RAISE EXCEPTION 'MES7B1_LIVE|a link changed a safety state or moved stock'; END IF;
    RAISE NOTICE 'STEP|link|safety-state rows % and movements % unchanged by linking / unlinking', v_ss_n, v_mv_n;
    v_j := pg_temp.p_get(ed, format($q$SELECT jsonb_agg(jsonb_build_object('batch', b.batch_code, 'basis', b.basis, 'active', b.active) ORDER BY b.batch_code) FROM incident_batch_rows b WHERE b.incident_id = %L$q$, i_mach));
    RAISE NOTICE 'STEP|link|machine incident links %', v_j;

    -- ── 5 从链接开一张来源 incident 的不合格报告 → 质量暂扣 ──
    IF EXISTS (SELECT 1 FROM batch_quality_hold(NULL, ob_m)) THEN RAISE EXCEPTION 'MES7B1_LIVE|a link alone held the batch'; END IF;
    v_msg := pg_temp.p_try(qe, format($q$SELECT open_ncr('incident', 'ZZ probe', p_output_batch_id => %L, p_incident_id => %L)$q$, ob_x, i_mach));
    PERFORM pg_temp.p_expect('ncr|batch not linked to the incident', v_msg, 'NCR_INCIDENT_BATCH_NOT_LINKED|%');
    v_j := pg_temp.p_get(qe, format($q$SELECT open_ncr('incident', 'ZZ probe: smoke damage, hold until inspected', p_output_batch_id => %L, p_incident_id => %L)$q$, ob_m, i_mach));
    IF NOT EXISTS (SELECT 1 FROM batch_quality_hold(NULL, ob_m) h WHERE h.ncr_id = (v_j ->> 'ncr_id')::uuid) THEN RAISE EXCEPTION 'MES7B1_LIVE|no hold %', v_j; END IF;
    v_j := pg_temp.p_get(qe, format($q$SELECT jsonb_build_object('code', n.code, 'source', n.source, 'incident', n.incident_code, 'holding', n.holding) FROM ncr_rows n WHERE n.id = %L$q$, (v_j ->> 'ncr_id')::uuid));
    RAISE NOTICE 'STEP|ncr|incident-source NCR on the linked batch: % → batch on quality hold', v_j;

    -- ── 6 引用:另一台机器的停机 · 撤回的运行事件 ──
    v_msg := pg_temp.p_try(ed, format($q$SELECT record_incident('fire_smoke', %L, 'x', 'y', false, p_responsible_name => 'Probe', p_equipment_id => %L, p_downtime_id => %L)$q$, t_m, fa, dt_x));
    PERFORM pg_temp.p_expect('cite|downtime of another machine', v_msg, 'INCIDENT_DOWNTIME_OTHER_MACHINE|%');
    v_msg := pg_temp.p_try(ed, format($q$SELECT record_incident('fire_smoke', %L, 'x', 'y', false, p_responsible_name => 'Probe', p_equipment_id => %L, p_run_event_id => %L)$q$, t_m, fa, ev_w));
    PERFORM pg_temp.p_expect('cite|withdrawn run event', v_msg, 'INCIDENT_RUN_EVENT_WITHDRAWN|%');

    -- ── 7 NEA:两条提醒 · 期限算出来、标着未确认 → 记下通报 → 交了报告 ──
    v_j := pg_temp.p_get(c_wh, format($q$SELECT jsonb_agg(o.item_type || ':' || COALESCE(o.doc_kind, '-') || ':' || o.item_date ORDER BY o.item_type) FROM operations_now o WHERE o.item_id = %L$q$, i_inj));
    IF jsonb_array_length(v_j) <> 2 THEN RAISE EXCEPTION 'MES7B1_LIVE|reminders %', v_j; END IF;
    RAISE NOTICE 'STEP|nea|both reminders: %', v_j;
    v_j := pg_temp.p_get(c_wh, format($q$SELECT jsonb_build_object('state', r.deadline_state, 'deadline', r.report_deadline, 'working_days', r.deadline_working_days, 'confirmed', r.deadline_confirmed, 'occurred_on', r.occurred_on) FROM incident_rows r WHERE r.id = %L$q$, i_inj));
    IF (v_j ->> 'confirmed')::boolean OR (v_j ->> 'working_days')::int <> 2 THEN RAISE EXCEPTION 'MES7B1_LIVE|deadline %', v_j; END IF;
    RAISE NOTICE 'STEP|nea|deadline %', v_j;
    v_msg := pg_temp.p_do(ed, format($q$SELECT record_incident_update(%L, 'nea_notified', %L, 'ZZ probe hotline ref')$q$, i_inj, now()));
    PERFORM pg_temp.p_expect('nea|notified', v_msg, 'OK');
    v_j := pg_temp.p_get(c_wh, format($q$SELECT jsonb_agg(o.item_type) FROM operations_now o WHERE o.item_id = %L$q$, i_inj));
    IF v_j IS DISTINCT FROM '["incident_report_due"]'::jsonb THEN RAISE EXCEPTION 'MES7B1_LIVE|after notification %', v_j; END IF;
    RAISE NOTICE 'STEP|nea|after the notification only %', v_j;
    v_msg := pg_temp.p_do(ed, format($q$SELECT record_incident_update(%L, 'report_submitted', %L, 'ZZ probe report ref')$q$, i_inj, now()));
    PERFORM pg_temp.p_expect('nea|report submitted', v_msg, 'OK');
    v_n := pg_temp.p_count(c_wh, format($q$SELECT count(*) FROM operations_now o WHERE o.item_id = %L$q$, i_inj));
    IF v_n <> 0 THEN RAISE EXCEPTION 'MES7B1_LIVE|after the report % reminders', v_n; END IF;
    RAISE NOTICE 'STEP|nea|after the report no reminder; state now %', (SELECT deadline_state FROM incident_current_all WHERE id = i_inj);
    v_n := pg_temp.p_count(c_wh, $q$SELECT count(*) FROM pending_values WHERE value_code = 'V19'$q$);
    IF v_n <> 1 THEN RAISE EXCEPTION 'MES7B1_LIVE|V19 rows %', v_n; END IF;
    RAISE NOTICE 'STEP|V19|on the pending list for the warehouse clone (unconfirmed)';

    -- ── 8 交接班引用事故:交接班页(加工查看)与事故页(安全查看)都读得到 ──
    -- 每一种启用的交接事项各写一句(必填的那几种因此都在)
    SELECT jsonb_agg(jsonb_build_object('item_type_code', code, 'body', 'ZZ probe nothing to hand over') ORDER BY sort_order) INTO v_items FROM handover_item_types WHERE is_active;
    v_j := pg_temp.p_get(ho, format($q$SELECT to_jsonb(submit_shift_handover(%L, %L, %L, %L, 'ZZ probe handover', %L::jsonb, NULL, ARRAY[%L, %L]::uuid[]))$q$,
                                     v_shift, v_today, e_out, e_in, v_items, i_inj, i_mach));
    v_ho := (v_j #>> '{}')::uuid;
    v_n := pg_temp.p_count(ho, format('SELECT count(*) FROM shift_handover_incident_refs WHERE handover_id = %L', v_ho));
    v_n2 := pg_temp.p_count(${lit(u.vw)}, format('SELECT count(*) FROM shift_handover_incident_refs WHERE incident_id = %L', i_mach));
    IF v_n <> 2 OR v_n2 <> 1 THEN RAISE EXCEPTION 'MES7B1_LIVE|handover refs % / %', v_n, v_n2; END IF;
    RAISE NOTICE 'STEP|handover|shift % · the handover page (processing view) reads % refs · the incident page (safety view only) reads %', v_shift, v_n, v_n2;
    v_msg := pg_temp.p_try(ho, format($q$INSERT INTO shift_handover_incident_refs (handover_id, incident_id) VALUES (%L, %L)$q$, v_ho, i_nr));
    PERFORM pg_temp.p_expect('handover|direct insert of a reference', v_msg, 'permission denied%');

    -- ── 9 七个角色:读得到什么、按得下去什么 ──
${roleArms}

    PERFORM pg_temp.p_recon('at the end');
    RAISE NOTICE 'STEP|done|in this transaction: incidents %, updates %, links %, handover refs %, NCRs from incidents %',
        (SELECT count(*) FROM incidents), (SELECT count(*) FROM incident_updates), (SELECT count(*) FROM incident_batches),
        (SELECT count(*) FROM shift_handover_incident_refs), (SELECT count(*) FROM nonconformance_reports WHERE source = 'incident');
END
$proof$;
ROLLBACK;
SELECT 'AFTER|incidents=' || (SELECT count(*) FROM incidents) || '|updates=' || (SELECT count(*) FROM incident_updates)
    || '|links=' || (SELECT count(*) FROM incident_batches) || '|handover refs=' || (SELECT count(*) FROM shift_handover_incident_refs)
    || '|probe materials=' || (SELECT count(*) FROM materials WHERE code LIKE 'ZZ-PROBE-MES7B1%')
    || '|probe employees=' || (SELECT count(*) FROM employees WHERE code LIKE 'ZZ-PROBE-MES7B1%')
    || '|incident NCRs=' || (SELECT count(*) FROM nonconformance_reports WHERE source = 'incident')
    || '|kind injury name=' || (SELECT name_en FROM incident_kinds WHERE code = 'injury')
    || '|V19=' || (SELECT nea_report_working_days || ' confirmed=' || (nea_report_days_confirmed_at IS NOT NULL) FROM safety_settings);
`
}

// 【--local <dsn>】只为在一个本地重建上排练这一支证明的 SQL:一次性账号改由 SQL 建在那个本地库里、同一笔事务之内(不经线上的 mintThrowaway),
//   不拿 live-lock;对着线上 DSN 一律拒绝。真跑(不带参数)才是交回报告里的那一次。
async function local(dsn) {
    if (!dsn || /supabase|pooler/.test(dsn)) { console.error('--local needs a local DSN (refusing a live one)'); return exitAfterCleanup(2) }
    const { randomUUID } = await import('node:crypto')
    const u = {}
    let setup = ''
    const add = (label, codesSql) => {
        const uid = randomUUID()
        u[label] = uid
        setup += `DO $l$ DECLARE r uuid; BEGIN
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES (${lit(uid)}, ${lit('mes7b1local-' + label + '@test.local')}, now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES (${lit('probe-mes7b1local-' + label)}, 'p', 'p', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT DISTINCT r, c FROM (${codesSql}) x(c);
    INSERT INTO user_roles (user_id, role_id) VALUES (${lit(uid)}, r);
END $l$;
`
    }
    const arr = (a) => `SELECT unnest(ARRAY[${a.map(lit).join(', ')}])`
    add('inv', 'SELECT code FROM permissions')
    add('ed', arr(['module.safety.view', 'module.safety.edit', 'module.inbound.view', 'module.output.view']))
    add('hl', arr(['module.safety.view', 'data.view_health']))
    add('vw', arr(['module.safety.view']))
    add('inj', arr(['module.tasks.view']))
    add('qe', arr(['module.quality.view', 'module.quality.edit', 'module.inbound.view', 'module.output.view', 'module.safety.view']))
    add('ho', arr(['module.processing.view', 'module.processing.edit']))
    // 重建里没有 cfo / cto / cco 这三个真角色:排练时它们拿 admin 的码(只为让 SQL 走得通;真跑用真角色此刻的码)
    for (const r of ROLES) {
        add('c_' + r, `SELECT rp.permission_code FROM role_permissions rp JOIN roles ro ON ro.id = rp.role_id
                        WHERE ro.code = COALESCE((SELECT code FROM roles WHERE code = ${lit(r)}), 'admin')`)
    }
    const sql = proofSql(u).replace('BEGIN;\n', 'BEGIN;\n' + setup)
    const p = spawnSync('psql', ['-X', '-q', dsn], { input: sql, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
    for (const line of (p.stderr + p.stdout).split('\n')) {
        const m = line.match(/(STEP\|.*|ROLE\|.*|AFTER\|.*|ERROR:.*|MES7B1_LIVE\|.*)$/)
        if (m) console.log(m[1])
    }
    return exitAfterCleanup(p.status === 0 && !/ERROR:/.test(p.stderr) ? 0 : 1)
}

async function main() {
    if (process.argv[2] === '--local') return local(process.argv[3] ?? '')
    const other = heldBy(); if (other) { console.error(`live-lock held by ${other.holder}`); return exitAfterCleanup(5) }
    acquireOrExit('2026-10-16-mes7b1-live-proof.mjs', { ownExit: false }); locked = true
    openPlan('db/scripts/2026-10-16-mes7b1-live-proof.mjs'); await reapStalePlans()
    const stamp = Date.now()
    const u = {}
    const mk = async (label, codes) => (await mintThrowaway({ prefix: 'mes7b1probe', label, stamp, signIn: false, codes })).userId
    u.inv = await mk('inv', 'all')
    u.ed = await mk('ed', ['module.safety.view', 'module.safety.edit', 'module.inbound.view', 'module.output.view'])
    u.hl = await mk('hl', ['module.safety.view', 'data.view_health'])
    u.vw = await mk('vw', ['module.safety.view'])
    u.inj = await mk('inj', ['module.tasks.view'])
    u.qe = await mk('qe', ['module.quality.view', 'module.quality.edit', 'module.inbound.view', 'module.output.view', 'module.safety.view'])
    u.ho = await mk('ho', ['module.processing.view', 'module.processing.edit'])
    for (const r of ROLES) u['c_' + r] = await mk(`cof-${r}`, { cloneOf: r })
    console.log(`ACCOUNTS|${Object.entries(u).map(([k, v]) => `${k} ${v}`).join('|')}`)
    const t0 = Date.now()
    const p = spawnSync('psql', ['-X', '-q', DSN], { input: proofSql(u), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
    for (const line of (p.stderr + p.stdout).split('\n')) {
        const m = line.match(/(STEP\|.*|ROLE\|.*|AFTER\|.*|ERROR:.*|MES7B1_LIVE\|.*)$/)
        if (m) console.log(m[1])
    }
    console.log(`TXN|psql exit ${p.status}|${((Date.now() - t0) / 1000).toFixed(1)} s in the transaction`)
    return exitAfterCleanup(p.status === 0 && !/ERROR:/.test(p.stderr) ? 0 : 1)
}
main().catch((e) => { console.error('✗', e?.stack || e); exitAfterCleanup(2) })
