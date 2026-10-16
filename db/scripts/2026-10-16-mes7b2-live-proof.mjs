#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// MES-7b-2(2026-10-16)· 线上验证 —— 安全巡检与环境监测:
//   一份三项的清单 → 一次带不合格(附说明)的巡检 → 交了就不能改 → 改清单,旧巡检照旧 → 一次带理由的更正巡检 ·
//   一条有责任人的发现 → 生成任务 → 关任务、发现仍开 → 关发现 · 一张来源 inspection、引用该发现的不合格报告 → 批次暂扣 ·
//   有限值的监测项,一条超限结果 → 同一笔事务里开出 emission_exceedance 事故 · 没有限值的 → 不判定 ·
//   F16 读回(视图可写的 (视图, 角色) 对 = 0)· 七个角色的只读读数表 · 一笔【回滚】的事务;不碰任何桶
// ════════════════════════════════════════════════════════════════════════════
// 【形状】照 db/scripts/2026-10-16-mes7b1-live-proof.mjs:一支 psql,一笔事务从 BEGIN 开到 ROLLBACK(ON_ERROR_STOP:任何一步红,事务中止、
//   连接关掉,等于回滚)。每一步以一次性账号的身份跑:先 set_config('request.jwt.claims') 再 SET LOCAL ROLE authenticated。
//   拒绝在子事务里试(BEGIN … EXCEPTION),不打断整笔。
// 【身份】每一个动作都以一次性账号跑(前缀 mes7b2probe),七个真账号一个都不用:
//   inv = 布景(收货)—— 持 permissions 表里每一个码的一次性角色(mintThrowaway 'all';它不是 admin,也不是任何真角色)
//   ed  = 巡检员:清单、巡检、发现、关闭、监测项与结果(module.safety.view · .edit · module.tasks.view);他的员工行在事务里插、随回滚消失
//   vw  = 只看(module.safety.view)—— 交了的巡检它改不了,也写不了
//   qe  = 开不合格报告(module.quality.view · .edit · inbound / safety 查看)
//   c_<角色> = 七个真账号此刻持有的七个角色的码的克隆(cloneOf,只读;c_cfo 读两条勾稽)
// 【布景】都是我自己的行(前缀 ZZ-PROBE-MES7B2),在事务里插,随回滚消失。在册的东西一行都不改、不决定、不删。
//   监测项是字典行:由 ed 经字典那条 RLS 路写入(与设置页同一条路),也随回滚消失。
// 【判决】只从日志里最后那一行 `MES7B2_PROOF_EXIT=` 读。0 = 走完、回滚、一次性账号收干净 · 1 = 证明红了 · 2 = 驱动自己坏了 ·
//   5 = live-lock 被占 · 6 = 收尾没完成。
// 用法:node db/scripts/2026-10-16-mes7b2-live-proof.mjs > <log> 2>&1
//       node db/scripts/2026-10-16-mes7b2-live-proof.mjs --local "<本地 DSN>"   (排练;对着线上 DSN 一律拒绝)
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
        console.log(`MES7B2_PROOF_EXIT=${code}`)
    },
})

const lit = (s) => `'${String(s).replace(/'/g, "''")}'`

function proofSql(u) {
    const roleArms = ROLES.map((r) => `
    -- ── 角色 ${r}(克隆 ${u['c_' + r]})── 巡检清单 · 那一次巡检 · 它的结果 · 环境页 · 待补的值 V18 / V20 · 记一次巡检(子事务,成了也撤回)
    v_list := pg_temp.p_count(${lit(u['c_' + r])}, $q$SELECT count(*) FROM inspection_run_rows$q$);
    v_tpl  := pg_temp.p_count(${lit(u['c_' + r])}, $q$SELECT count(*) FROM inspection_template_rows$q$);
    v_run  := pg_temp.p_count(${lit(u['c_' + r])}, format('SELECT count(*) FROM inspection_run_rows WHERE id = %L', r1));
    v_res  := pg_temp.p_count(${lit(u['c_' + r])}, format('SELECT count(*) FROM inspection_results WHERE run_id = %L', r1));
    v_env  := pg_temp.p_count(${lit(u['c_' + r])}, $q$SELECT count(*) FROM environmental_result_rows$q$);
    v_v18  := pg_temp.p_count(${lit(u['c_' + r])}, $q$SELECT count(*) FROM pending_values WHERE value_code = 'V18'$q$);
    v_v20  := pg_temp.p_count(${lit(u['c_' + r])}, $q$SELECT count(*) FROM pending_values WHERE value_code = 'V20'$q$);
    v_rem  := pg_temp.p_count(${lit(u['c_' + r])}, $q$SELECT count(*) FROM operations_now WHERE item_type IN ('inspection_due', 'inspection_finding_open')$q$);
    v_msg  := pg_temp.p_try(${lit(u['c_' + r])}, format($q$SELECT record_inspection_run(%L, now() - interval '5 minutes', %L, pg_temp.p_results(3))$q$, t1, e_ed));
    RAISE NOTICE 'ROLE|${r}|codes=%|safety.view=%|safety.edit=%|checklists=%|inspection list rows=%|run seen=%|results seen=%|environment rows=%|V18 rows=%|V20 rows=%|inspection reminders=%|record=%',
        (SELECT count(*) FROM role_permissions rp JOIN user_roles ur ON ur.role_id = rp.role_id WHERE ur.user_id = ${lit(u['c_' + r])} AND ur.revoked_at IS NULL),
        pg_temp.p_has(${lit(u['c_' + r])}, 'module.safety.view'), pg_temp.p_has(${lit(u['c_' + r])}, 'module.safety.edit'),
        v_tpl, v_list, v_run, v_res, v_env, v_v18, v_v20, v_rem, left(v_msg, 60);`).join('\n')

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
    IF p_got IS NULL OR p_got NOT LIKE p_like THEN RAISE EXCEPTION 'MES7B2_LIVE|% expected % got %', p_what, p_like, COALESCE(p_got, '<null>'); END IF;
    RAISE NOTICE 'STEP|%|%', p_what, left(p_got, 120);
END $f$;
-- 一条判定:条件不是【真】(假或 NULL)就红 —— NULL 不许读成通过
CREATE FUNCTION pg_temp.p_assert(p_what text, p_ok boolean, p_detail text) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
    IF p_ok IS NOT TRUE THEN RAISE EXCEPTION 'MES7B2_LIVE|% — %', p_what, COALESCE(p_detail, '<null>'); END IF;
    RAISE NOTICE 'STEP|%|%', p_what, left(COALESCE(p_detail, ''), 400);
END $f$;
CREATE FUNCTION pg_temp.p_results(p_n int, p_fail int DEFAULT NULL, p_na int DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_agg(jsonb_build_object('position', i,
                                        'result', CASE WHEN i = p_fail THEN 'fail' WHEN i = p_na THEN 'na' ELSE 'pass' END,
                                        'note', CASE WHEN i = p_fail THEN 'ZZ probe: item ' || i || ' failed' END) ORDER BY i)
      FROM generate_series(1, p_n) i
$f$;
-- 两条勾稽(以 cfo 的克隆读):应付 / 应收清单 = 总账,未解释 0.00;存货控制科目对得上
CREATE FUNCTION pg_temp.p_recon(p_step text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v jsonb; s jsonb; txt text := '';
BEGIN
    v := pg_temp.p_get(${lit(u.c_cfo)}, 'SELECT list_ledger_reconciliation()');
    FOR s IN SELECT * FROM jsonb_array_elements(v -> 'sides') LOOP
        txt := txt || concat_ws(' ', s ->> 'side', s ->> 'list_base', '/', s ->> 'ledger_base', '/', s ->> 'unexplained_base') || ' · ';
        IF (s ->> 'unexplained_base')::numeric IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'MES7B2_LIVE|RECON % % list ≠ ledger %', p_step, s ->> 'side', s; END IF;
    END LOOP;
    v := pg_temp.p_get(${lit(u.c_cfo)}, 'SELECT gl_control_reconciliation(CURRENT_DATE)');
    FOR s IN SELECT x FROM jsonb_array_elements(v -> 'sides') x WHERE x ->> 'side' LIKE 'inventory%' LOOP
        txt := txt || concat_ws(' ', s ->> 'side', s ->> 'ledger_base', '/', s ->> 'subledger_base', '/', s ->> 'unexplained_base') || ' · ';
        IF (s ->> 'unexplained_base')::numeric IS DISTINCT FROM 0 OR (s ->> 'reconciled')::boolean IS NOT TRUE THEN
            RAISE EXCEPTION 'MES7B2_LIVE|RECON % inventory control % not reconciled %', p_step, s ->> 'side', s; END IF;
    END LOOP;
    RAISE NOTICE 'STEP|recon %|%', p_step, txt;
END $f$;

DO $proof$
DECLARE
    inv uuid := ${lit(u.inv)}; ed uuid := ${lit(u.ed)}; vw uuid := ${lit(u.vw)}; qe uuid := ${lit(u.qe)};
    d date := (now() AT TIME ZONE 'Asia/Singapore')::date - 3;
    e_ed uuid := gen_random_uuid(); e_own uuid := gen_random_uuid();
    sup uuid; bm uuid; ib uuid; t1 uuid; r1 uuid; r2 uuid; f1 uuid; v_task uuid; v_lab text;
    v_code1 text; v_code2 text; v_inc_before bigint; v_tasks_before bigint;
    v_j jsonb; v_msg text; v_n bigint; v_txt text;
    v_list bigint; v_tpl bigint; v_run bigint; v_res bigint; v_env bigint; v_v18 bigint; v_v20 bigint; v_rem bigint;
BEGIN
    RAISE NOTICE 'STEP|who|%|bypassrls=%', current_user, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user);
    IF EXISTS (SELECT 1 FROM materials WHERE code LIKE 'ZZ-PROBE-MES7B2%') THEN RAISE EXCEPTION 'MES7B2_LIVE|probe rows already exist'; END IF;
    SELECT count(*) INTO v_inc_before FROM incidents; SELECT count(*) INTO v_tasks_before FROM tasks;
    RAISE NOTICE 'STEP|before|templates %|runs %|findings %|parameters %|results %|incidents %|tasks %|NCRs %',
        (SELECT count(*) FROM inspection_templates), (SELECT count(*) FROM inspection_runs), (SELECT count(*) FROM inspection_findings),
        (SELECT count(*) FROM environmental_parameters), (SELECT count(*) FROM environmental_results), v_inc_before, v_tasks_before,
        (SELECT count(*) FROM nonconformance_reports);
    -- F16:迁移之后,没有一张视图对 anon / authenticated 可写
    SELECT count(*), string_agg(c.relname || ':' || g.r, ', ') INTO v_n, v_txt
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN (VALUES ('anon'), ('authenticated')) g(r)
     WHERE n.nspname = 'public' AND c.relkind = 'v'
       AND (has_table_privilege(g.r, c.oid, 'INSERT') OR has_table_privilege(g.r, c.oid, 'UPDATE')
            OR has_table_privilege(g.r, c.oid, 'DELETE') OR has_table_privilege(g.r, c.oid, 'TRUNCATE'));
    PERFORM pg_temp.p_assert('F16|(view, role) pairs carrying a write grant', v_n = 0, v_n || ' ' || COALESCE(v_txt, '(none)'));
    -- V18 / V20:字典是空的,各一行
    v_n := pg_temp.p_count(${lit(u.c_admin)}, $q$SELECT count(*) FROM pending_values WHERE value_code IN ('V18', 'V20')$q$);
    PERFORM pg_temp.p_assert('V18 · V20|one row each while the dictionaries are empty', v_n = 2, v_n::text);
    PERFORM pg_temp.p_recon('before anything');

    -- ── 布景(属主插,我自己的行)──
    INSERT INTO employees (id, code, legal_name, preferred_name, employment_type, work_category, hire_date, user_id) VALUES
        (e_ed,  'ZZ-PROBE-MES7B2-E1', 'ZZ probe inspector', 'Probe Inspector', 'full_time', 'shopfloor', DATE '2020-01-01', ed),
        (e_own, 'ZZ-PROBE-MES7B2-E2', 'ZZ probe bay lead', 'Probe Lead', 'full_time', 'shopfloor', DATE '2020-01-01', NULL);
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ-PROBE-MES7B2-S', 'ZZ probe cells vendor', 'SG', 'active', 'goods_supplier') RETURNING id INTO sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ-PROBE-MES7B2-BM', 'ZZ probe modules', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO bm;
    ib := (pg_temp.p_get(inv, format($q$SELECT create_inbound_batch(%L, %L, 50, 'kg', %L, '待加工', p_safety_states => ARRAY['discharged_verified'],
                 p_source_reason_code => 'other', p_source_reason_note => 'ZZ probe wet cells')$q$, bm, sup, d)) ->> 'batch_id')::uuid;
    RAISE NOTICE 'STEP|scenery|batch %', (SELECT code FROM inbound_batches WHERE id = ib);
    PERFORM pg_temp.p_recon('after the receipt');

    -- ── 1 一份三项的清单 ──
    v_msg := pg_temp.p_try(vw, $q$SELECT save_inspection_template(NULL, 'zz-probe', 'x', 'y', '["a"]'::jsonb, 7, true, NULL)$q$);
    PERFORM pg_temp.p_expect('template|view-only cannot save', v_msg, 'PERMISSION_DENIED|module.safety.edit');
    v_j := pg_temp.p_get(ed, $q$SELECT save_inspection_template(NULL, 'zz-probe-bay', 'ZZ probe discharge bay', 'Discharge bay',
               '["Extinguishers in place", "Cells stored dry, off the floor", "Emergency stop tested"]'::jsonb, 7, true, NULL)$q$);
    t1 := (v_j ->> 'template_id')::uuid;
    PERFORM pg_temp.p_assert('template|saved with three ordered items', (SELECT count(*) FROM inspection_template_items WHERE template_id = t1) = 3,
        (v_j ->> 'code') || ' · ' || (SELECT string_agg(position || '. ' || item_text, ' / ' ORDER BY position) FROM inspection_template_items WHERE template_id = t1));

    -- ── 2 一次巡检:一项不合格(附说明)· 不合格没有说明按名拒 ──
    v_msg := pg_temp.p_try(ed, format($q$SELECT record_inspection_run(%L, now() - interval '1 hour', %L,
               '[{"position":1,"result":"pass"},{"position":2,"result":"fail"},{"position":3,"result":"pass"}]'::jsonb)$q$, t1, e_ed));
    PERFORM pg_temp.p_expect('run|a fail without a note', v_msg, 'INSPECTION_FAIL_NOTE_REQUIRED|2');
    v_j := pg_temp.p_get(ed, format($q$SELECT record_inspection_run(%L, now() - interval '1 hour', %L, pg_temp.p_results(3, 2), p_notes => 'ZZ probe run',
               p_findings => %L::jsonb)$q$, t1, e_ed,
               jsonb_build_array(jsonb_build_object('position', 2, 'corrective_action', 'ZZ probe: move the cells onto the racking', 'owner_employee_id', e_own,
                                                    'due_date', (now() AT TIME ZONE 'Asia/Singapore')::date + 3))));
    r1 := (v_j ->> 'run_id')::uuid; v_code1 := v_j ->> 'code';
    PERFORM pg_temp.p_assert('run|recorded with its number', v_code1 ~ ('^INS-' || extract(year FROM CURRENT_DATE)::int || '-[0-9]{4,}$'), v_j::text);
    v_j := pg_temp.p_get(vw, format($q$SELECT jsonb_build_object('code', r.code, 'pass', r.pass_count, 'fail', r.fail_count, 'na', r.na_count, 'findings', r.finding_count) FROM inspection_run_rows r WHERE r.id = %L$q$, r1));
    PERFORM pg_temp.p_assert('run|the view-only reader sees it', (v_j ->> 'fail')::int = 1 AND (v_j ->> 'pass')::int = 2, v_j::text);

    -- ── 3 交了就不能改:直接改结果、直接写巡检,都按名拒 ──
    v_msg := pg_temp.p_try(ed, format($q$UPDATE inspection_results SET result = 'pass' WHERE run_id = %L AND position = 2$q$, r1));
    PERFORM pg_temp.p_expect('immutable|an editor rewrites a submitted result', v_msg, 'INSPECTION_RECORD_IMMUTABLE|inspection_results|update');
    v_msg := pg_temp.p_try(ed, format($q$DELETE FROM inspection_runs WHERE id = %L$q$, r1));
    PERFORM pg_temp.p_expect('immutable|an editor deletes a submitted run', v_msg, 'INSPECTION_RECORD_IMMUTABLE|inspection_runs|delete');

    -- ── 4 改清单,旧巡检照旧 ──
    v_msg := pg_temp.p_do(ed, format($q$SELECT save_inspection_template(%L, 'zz-probe-bay', 'ZZ probe discharge bay', 'Discharge bay',
               '["Extinguishers in place and charged", "Cells stored dry, off the floor, away from the drain", "Emergency stop tested"]'::jsonb, 7, true, NULL)$q$, t1));
    PERFORM pg_temp.p_expect('template|edited (items 1 and 2 reworded)', v_msg, 'OK');
    v_txt := (SELECT string_agg(position || '. ' || item_text, ' / ' ORDER BY position) FROM inspection_results WHERE run_id = r1);
    PERFORM pg_temp.p_assert('template|the past run still shows the items as they were inspected',
        v_txt = '1. Extinguishers in place / 2. Cells stored dry, off the floor / 3. Emergency stop tested', v_txt);

    -- ── 5 一次带理由的更正巡检 ──
    v_msg := pg_temp.p_try(ed, format($q$SELECT record_inspection_run(%L, now() - interval '30 minutes', %L, pg_temp.p_results(3, 2), p_corrects_run_id => %L)$q$, t1, e_ed, r1));
    PERFORM pg_temp.p_expect('correction|without a reason', v_msg, 'INSPECTION_CORRECTION_REASON_REQUIRED');
    v_j := pg_temp.p_get(ed, format($q$SELECT record_inspection_run(%L, now() - interval '30 minutes', %L, pg_temp.p_results(3, 2, 3), p_corrects_run_id => %L,
               p_correction_reason => 'ZZ probe: item 3 was not tested that day')$q$, t1, e_ed, r1));
    r2 := (v_j ->> 'run_id')::uuid; v_code2 := v_j ->> 'code';
    v_j := pg_temp.p_get(vw, format($q$SELECT jsonb_build_object('code', r.code, 'corrected_by', r.corrected_by_run_code, 'fail', r.fail_count) FROM inspection_run_rows r WHERE r.id = %L$q$, r1));
    PERFORM pg_temp.p_assert('correction|a new run citing the old one; the old run is unchanged and names it', v_j ->> 'corrected_by' = v_code2 AND (v_j ->> 'fail')::int = 1,
        v_code2 || ' corrects ' || v_j::text);
    v_msg := pg_temp.p_try(ed, format($q$SELECT record_inspection_run(%L, now() - interval '20 minutes', %L, pg_temp.p_results(3), p_corrects_run_id => %L, p_correction_reason => 'again')$q$, t1, e_ed, r1));
    PERFORM pg_temp.p_expect('correction|twice', v_msg, 'INSPECTION_RUN_ALREADY_CORRECTED|%');

    -- ── 6 发现:有责任人 → 生成任务 → 关任务、发现仍开 → 关发现 ──
    SELECT id INTO f1 FROM inspection_findings WHERE run_id = r1;
    v_j := pg_temp.p_get(vw, format($q$SELECT jsonb_build_object('open', f.is_open, 'owner', f.owner_label, 'action', f.corrective_action) FROM inspection_finding_rows f WHERE f.id = %L$q$, f1));
    PERFORM pg_temp.p_assert('finding|recorded on the failed item with its owner', (v_j ->> 'open')::boolean AND v_j ->> 'owner' LIKE 'ZZ-PROBE-MES7B2-E2%', v_j::text);
    v_n := pg_temp.p_count(vw, format($q$SELECT count(*) FROM operations_now WHERE item_type = 'inspection_finding_open' AND item_id = %L$q$, f1));
    PERFORM pg_temp.p_assert('finding|on the dashboard reminder', v_n = 1, v_n::text);
    v_j := pg_temp.p_get(ed, format('SELECT raise_inspection_finding_task(%L)', f1));
    v_task := (v_j ->> 'task_id')::uuid;
    v_j := (SELECT jsonb_build_object('code', t.code, 'type', t.task_type, 'title', t.title, 'owner_is_presser', t.owner_id = e_ed) FROM tasks t WHERE t.id = v_task);
    PERFORM pg_temp.p_assert('task|a personal task for whoever pressed it', (v_j ->> 'owner_is_presser')::boolean AND v_j ->> 'type' = 'personal', v_j::text);
    v_msg := pg_temp.p_do(ed, format($q$UPDATE tasks SET status = 'done' WHERE id = %L$q$, v_task));
    PERFORM pg_temp.p_expect('task|closed by its owner', v_msg, 'OK');
    v_j := pg_temp.p_get(vw, format($q$SELECT jsonb_build_object('open', f.is_open, 'task', f.task_code) FROM inspection_finding_rows f WHERE f.id = %L$q$, f1));
    PERFORM pg_temp.p_assert('task|closing the task does not close the finding', (v_j ->> 'open')::boolean, v_j::text);
    v_msg := pg_temp.p_try(ed, format($q$SELECT close_inspection_finding(%L, '  ')$q$, f1));
    PERFORM pg_temp.p_expect('finding|close without saying what was done', v_msg, 'INSPECTION_FINDING_CLOSE_NOTE_REQUIRED');

    -- ── 7 一张来源 inspection、引用这条发现的不合格报告 → 批次暂扣(发现还开着的时候开)──
    v_msg := pg_temp.p_try(qe, format($q$SELECT open_ncr('inspection', 'ZZ probe', p_inbound_batch_id => %L)$q$, ib));
    PERFORM pg_temp.p_expect('ncr|inspection source without a finding', v_msg, 'NCR_INSPECTION_FINDING_REQUIRED');
    v_j := pg_temp.p_get(qe, format($q$SELECT open_ncr('inspection', 'ZZ probe: wet cells found on the inspection', p_inbound_batch_id => %L, p_inspection_finding_id => %L)$q$, ib, f1));
    PERFORM pg_temp.p_assert('ncr|the batch is on quality hold', EXISTS (SELECT 1 FROM batch_quality_hold(ib, NULL) h WHERE h.ncr_id = (v_j ->> 'ncr_id')::uuid), v_j::text);
    v_j := pg_temp.p_get(qe, format($q$SELECT jsonb_build_object('code', n.code, 'source', n.source, 'run', n.inspection_run_code, 'item', n.inspection_item_position, 'holding', n.holding) FROM ncr_rows n WHERE n.id = %L$q$, (v_j ->> 'ncr_id')::uuid));
    PERFORM pg_temp.p_assert('ncr|names the inspection and the item', v_j ->> 'run' = v_code1 AND (v_j ->> 'item')::int = 2 AND (v_j ->> 'holding')::boolean, v_j::text);

    v_msg := pg_temp.p_do(ed, format($q$SELECT close_inspection_finding(%L, 'ZZ probe: cells moved onto the racking, drain zone marked')$q$, f1));
    PERFORM pg_temp.p_expect('finding|closed with what was done', v_msg, 'OK');
    v_n := pg_temp.p_count(vw, format($q$SELECT count(*) FROM operations_now WHERE item_type = 'inspection_finding_open' AND item_id = %L$q$, f1));
    PERFORM pg_temp.p_assert('finding|leaves the reminder once closed', v_n = 0, v_n::text);

    -- ── 8 监测:有限值的一项,超限 → 同一笔事务里开出事故;没有限值的 → 不判定 ──
    v_msg := pg_temp.p_do(ed, $q$INSERT INTO environmental_parameters (code, name_en, name_zh, unit, limit_value, limit_basis) VALUES
               ('zz_probe_hf', 'ZZ probe hydrogen fluoride', 'ZZ 探针氟化氢', 'mg/Nm3', 5, 'max'),
               ('zz_probe_dust', 'ZZ probe particulates', 'ZZ 探针颗粒物', 'mg/Nm3', NULL, NULL)$q$);
    PERFORM pg_temp.p_expect('env|two parameters through the dictionary path (one with a limit, one without)', v_msg, 'OK');
    v_n := pg_temp.p_count(${lit(u.c_admin)}, $q$SELECT count(*) FROM pending_values WHERE value_code = 'V20'$q$);
    PERFORM pg_temp.p_assert('V20|one row for the parameter without a limit', v_n = 1, v_n::text);
    SELECT code INTO v_lab FROM laboratories ORDER BY code LIMIT 1;
    v_msg := pg_temp.p_try(ed, format($q$SELECT record_environmental_result('zz_probe_hf', 'Stack A', %L, %L, 'ZZ-PROBE-R1', 7.5)$q$, d, v_lab));
    PERFORM pg_temp.p_expect('env|an exceedance needs the NEA answer', v_msg, 'ENV_EXCEEDANCE_NEA_ANSWER_REQUIRED|%');
    v_j := pg_temp.p_get(ed, format($q$SELECT record_environmental_result('zz_probe_hf', 'Stack A', %L, %L, 'ZZ-PROBE-R1', 7.5, true, 'ZZ probe: scrubber dosing raised')$q$, d, v_lab));
    PERFORM pg_temp.p_assert('env|a result above its limit opens an incident in the same transaction',
        (v_j ->> 'exceeds')::boolean AND (SELECT kind_code FROM incidents WHERE id = (v_j ->> 'incident_id')::uuid) = 'emission_exceedance'
        AND (SELECT count(*) FROM incidents) = v_inc_before + 1,
        v_j::text || ' · ' || COALESCE((SELECT left(what_happened, 140) FROM incidents WHERE id = (v_j ->> 'incident_id')::uuid), '<no incident>'));
    v_j := pg_temp.p_get(vw, format($q$SELECT jsonb_build_object('judgement', r.judgement, 'limit', r.limit_value, 'basis', r.limit_basis, 'incident', r.incident_code) FROM environmental_result_rows r WHERE r.id = %L$q$, (v_j ->> 'result_id')::uuid));
    PERFORM pg_temp.p_assert('env|the result row carries its copied limit and the incident', v_j ->> 'judgement' = 'exceeds' AND (v_j ->> 'limit')::numeric = 5, v_j::text);
    v_j := pg_temp.p_get(ed, format($q$SELECT record_environmental_result('zz_probe_dust', 'Stack A', %L, %L, 'ZZ-PROBE-R2', 12.4)$q$, d, v_lab));
    PERFORM pg_temp.p_assert('env|a parameter without a limit is not judged and opens nothing',
        v_j ->> 'exceeds' IS NULL AND v_j ->> 'incident_id' IS NULL AND (SELECT count(*) FROM incidents) = v_inc_before + 1, v_j::text);
    v_msg := pg_temp.p_try(ed, format($q$UPDATE environmental_results SET value = 1 WHERE id = %L$q$, (v_j ->> 'result_id')::uuid));
    PERFORM pg_temp.p_expect('env|a result is append-only', v_msg, 'ENV_RESULT_IMMUTABLE|update');

    -- ── 9 七个角色:读得到什么、按得下去什么 ──
${roleArms}

    PERFORM pg_temp.p_assert('tasks|only the one raised here was added', (SELECT count(*) FROM tasks) = v_tasks_before + 1, (SELECT count(*) FROM tasks)::text);
    PERFORM pg_temp.p_recon('at the end');
    RAISE NOTICE 'STEP|done|in this transaction: templates %, runs %, findings %, closures %, parameters %, results %, incidents %, inspection NCRs %',
        (SELECT count(*) FROM inspection_templates), (SELECT count(*) FROM inspection_runs), (SELECT count(*) FROM inspection_findings),
        (SELECT count(*) FROM inspection_finding_closures), (SELECT count(*) FROM environmental_parameters), (SELECT count(*) FROM environmental_results),
        (SELECT count(*) FROM incidents), (SELECT count(*) FROM nonconformance_reports WHERE source = 'inspection');
END
$proof$;
ROLLBACK;
SELECT 'AFTER|templates=' || (SELECT count(*) FROM inspection_templates) || '|items=' || (SELECT count(*) FROM inspection_template_items)
    || '|runs=' || (SELECT count(*) FROM inspection_runs) || '|results=' || (SELECT count(*) FROM inspection_results)
    || '|findings=' || (SELECT count(*) FROM inspection_findings) || '|closures=' || (SELECT count(*) FROM inspection_finding_closures)
    || '|parameters=' || (SELECT count(*) FROM environmental_parameters) || '|env results=' || (SELECT count(*) FROM environmental_results)
    || '|incidents=' || (SELECT count(*) FROM incidents) || '|tasks=' || (SELECT count(*) FROM tasks)
    || '|NCRs=' || (SELECT count(*) FROM nonconformance_reports)
    || '|probe materials=' || (SELECT count(*) FROM materials WHERE code LIKE 'ZZ-PROBE-MES7B2%')
    || '|probe employees=' || (SELECT count(*) FROM employees WHERE code LIKE 'ZZ-PROBE-MES7B2%');
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
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES (${lit(uid)}, ${lit('mes7b2local-' + label + '@test.local')}, now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES (${lit('probe-mes7b2local-' + label)}, 'p', 'p', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT DISTINCT r, c FROM (${codesSql}) x(c);
    INSERT INTO user_roles (user_id, role_id) VALUES (${lit(uid)}, r);
END $l$;
`
    }
    const arr = (a) => `SELECT unnest(ARRAY[${a.map(lit).join(', ')}])`
    add('inv', 'SELECT code FROM permissions')
    add('ed', arr(['module.safety.view', 'module.safety.edit', 'module.tasks.view']))
    add('vw', arr(['module.safety.view']))
    add('qe', arr(['module.quality.view', 'module.quality.edit', 'module.inbound.view', 'module.safety.view']))
    // 重建里没有 cfo / cto / cco 这些真角色:排练时它们拿 admin 的码(只为让 SQL 走得通;真跑用真角色此刻的码)
    for (const r of ROLES) {
        add('c_' + r, `SELECT rp.permission_code FROM role_permissions rp JOIN roles ro ON ro.id = rp.role_id
                        WHERE ro.code = COALESCE((SELECT code FROM roles WHERE code = ${lit(r)}), 'admin')`)
    }
    // 一个空重建没有总账:勾稽的 reconciled 在那里是 NULL,严格判据会红在布景上。排练时只换掉这一支(真跑一字不改)。
    const noRecon = `CREATE OR REPLACE FUNCTION pg_temp.p_recon(p_step text) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN RAISE NOTICE 'STEP|recon %|skipped on the local rehearsal (a rebuild has no ledger)', p_step; END $f$;
`
    const sql = proofSql(u).replace('BEGIN;\n', 'BEGIN;\n' + setup).replace('DO $proof$', noRecon + 'DO $proof$')
    const p = spawnSync('psql', ['-X', '-q', dsn], { input: sql, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
    for (const line of (p.stderr + p.stdout).split('\n')) {
        const m = line.match(/(STEP\|.*|ROLE\|.*|AFTER\|.*|ERROR:.*|MES7B2_LIVE\|.*)$/)
        if (m) console.log(m[1])
    }
    return exitAfterCleanup(p.status === 0 && !/ERROR:/.test(p.stderr) ? 0 : 1)
}

async function main() {
    if (process.argv[2] === '--local') return local(process.argv[3] ?? '')
    const other = heldBy(); if (other) { console.error(`live-lock held by ${other.holder}`); return exitAfterCleanup(5) }
    acquireOrExit('2026-10-16-mes7b2-live-proof.mjs', { ownExit: false }); locked = true
    openPlan('db/scripts/2026-10-16-mes7b2-live-proof.mjs'); await reapStalePlans()
    const stamp = Date.now()
    const u = {}
    const mk = async (label, codes) => (await mintThrowaway({ prefix: 'mes7b2probe', label, stamp, signIn: false, codes })).userId
    u.inv = await mk('inv', 'all')
    u.ed = await mk('ed', ['module.safety.view', 'module.safety.edit', 'module.tasks.view'])
    u.vw = await mk('vw', ['module.safety.view'])
    u.qe = await mk('qe', ['module.quality.view', 'module.quality.edit', 'module.inbound.view', 'module.safety.view'])
    for (const r of ROLES) u['c_' + r] = await mk(`cof-${r}`, { cloneOf: r })
    console.log(`ACCOUNTS|${Object.entries(u).map(([k, v]) => `${k} ${v}`).join('|')}`)
    const t0 = Date.now()
    const p = spawnSync('psql', ['-X', '-q', DSN], { input: proofSql(u), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
    for (const line of (p.stderr + p.stdout).split('\n')) {
        const m = line.match(/(STEP\|.*|ROLE\|.*|AFTER\|.*|ERROR:.*|MES7B2_LIVE\|.*)$/)
        if (m) console.log(m[1])
    }
    console.log(`TXN|psql exit ${p.status}|${((Date.now() - t0) / 1000).toFixed(1)} s in the transaction`)
    return exitAfterCleanup(p.status === 0 && !/ERROR:/.test(p.stderr) ? 0 : 1)
}
main().catch((e) => { console.error('✗', e?.stack || e); exitAfterCleanup(2) })
