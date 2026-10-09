-- db/scripts/2026-10-09-mes5b3-live-proof.sql
-- MES-5b-3 · 线上的证明 —— 【一笔事务,以 ROLLBACK 收尾】:什么都不留。审批开着,一处都不关。
--   由 db/scripts/2026-10-09-mes5b3-live-proof.mjs 驱动:它先用 mintThrowaway 造一次性账号(前缀 mes5b3probe),
--   再以 psql 跑本文件,把那些邮箱经 -v 传进来;跑完按 ephemeral 计划收走账号、授权、一次性角色。
--   【每一个动作都以一次性账号跑】(七个真账号一个都不用):
--     wc  = module.processing/inbound/output.view + action.wo_create + action.wo_release —— 建计划;它也持放行码,好证明建单人放行不了
--     wr  = module.processing.view + action.wo_release                                    —— 另一个持放行码的人,放行
--     ops = module.processing/inbound/output.view + action.processing_commit              —— 从计划页执行
--     lab = module.output.view + module.output.edit                                       —— 记化验
--     apl = module.output.view + action.apply_assay                                       —— 应用化验(布景那两批的含量来自化验)
--     pv  = module.processing.view                                                        —— 看不见批次的读者(含量「受限」)
--     c_<角色> = 七个真角色【此刻的码】的一次性克隆(cloneOf)—— 逐角色读数表;对账在 c_cfo 的会话里读
--   【布景】(以属主插,都是我自己的行):ZZ-PROBE-MES5B3-* 供应商 / 一种可售的黑粉物料 / 一种不可售的负极片物料 /
--     两批黑粉产出批(安全状态"已放电并核验")。两批的含量由 lab 记化验、apl 应用 —— 来自化验,不同的含量。
--   ① wc 建计划(目标 ni 15–18 · co ≤ 4 · li ≥ 1;B1 300 + B2 300)→ 预测 ni 16(在目标内)· co 4.5(高于上限,只标)· li 没量过。
--   ② wc 拿不可售的负极片当产出 → BLEND_OUTPUT_NOT_SALEABLE(按名)。
--   ③ wc 放行自己的计划 → SELF_APPROVAL_FORBIDDEN|raiser;wr 放行 → 成。
--   ④ ops 直接拿 blending 记一炉 → BLEND_RUN_FROM_PLAN_ONLY;ops 从计划执行:B1 310 · B2 290,称出 595 → 一炉 blending,差 +10 / −10。
--   ⑤ 混出来那一批:化验之前 not_assayed;lab 记一份化验(ni 16.2 · co 4.4)→ ni 在目标内 · co 高于上限 · li 不在化验里。
--   ⑥ 逐角色读数表:计划清单与计划页进得去吗、建 / 放行 / 执行按得下去吗、批次的含量是不是受限;外加 pv。
--   每一步之后:AP / AR 清单 = 总账,两边 unexplained 0.00(c_cfo 的会话)。在册的东西一张都不碰、不决定、不改。
-- 打印的每一行都是 STEP|… 或 ROLE|… ;任何一处与预期不符就 RAISE,整笔回滚。
\pset pager off
\pset format unaligned
\pset tuples_only on
BEGIN;
SET LOCAL statement_timeout = '300s';
SELECT set_config('mes5b3.wc', :'wc', true), set_config('mes5b3.wr', :'wr', true), set_config('mes5b3.ops', :'ops', true),
       set_config('mes5b3.lab', :'lab', true), set_config('mes5b3.apl', :'apl', true), set_config('mes5b3.pv', :'pv', true),
       set_config('mes5b3.c_admin', :'c_admin', true), set_config('mes5b3.c_finance', :'c_finance', true),
       set_config('mes5b3.c_warehouse', :'c_warehouse', true), set_config('mes5b3.c_cto', :'c_cto', true),
       set_config('mes5b3.c_cco', :'c_cco', true), set_config('mes5b3.c_cfo', :'c_cfo', true), set_config('mes5b3.c_gm', :'c_gm', true) \g /dev/null

CREATE FUNCTION pg_temp.as_(p_who text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v uuid; e text := current_setting('mes5b3.' || p_who);
BEGIN
    EXECUTE 'RESET ROLE';
    SELECT id INTO v FROM auth.users WHERE email = e;
    IF v IS NULL OR e NOT LIKE 'mes5b3probe-%@test.local' THEN RAISE EXCEPTION 'MES5B3_LIVE|not a throwaway account: % (%)', p_who, e; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
END $f$;
CREATE FUNCTION pg_temp.me_() RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
END $f$;
CREATE FUNCTION pg_temp.try_(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE p_sql;
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    RETURN SQLERRM;
END $f$;
CREATE FUNCTION pg_temp.agree_(p_step text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v jsonb; s jsonb; out text := '';
BEGIN
    PERFORM pg_temp.as_('c_cfo');
    v := list_ledger_reconciliation();
    PERFORM pg_temp.me_();
    FOR s IN SELECT * FROM jsonb_array_elements(v -> 'sides') LOOP
        IF s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric IS DISTINCT FROM 0 THEN
            RAISE EXCEPTION 'MES5B3_LIVE|AP/AR list <> ledger after %: % list % ledger % unexplained %', p_step, s ->> 'side', s ->> 'list_base', s ->> 'ledger_base', s ->> 'unexplained_base';
        END IF;
        out := out || (s ->> 'side') || ' ' || (s ->> 'list_base') || ' / ' || (s ->> 'ledger_base') || ' / ' || (s ->> 'unexplained_base') || '; ';
    END LOOP;
    RETURN out;
END $f$;
GRANT EXECUTE ON FUNCTION pg_temp.as_(text), pg_temp.me_(), pg_temp.try_(text) TO authenticated;

CREATE TEMP TABLE mes5b3_roles (who text, role text, codes integer, list_page boolean, plan_page boolean,
    can_create boolean, can_release boolean, can_execute boolean, plans_read bigint, content_restricted text, prediction text) ON COMMIT DROP;
GRANT INSERT ON mes5b3_roles TO authenticated;

DO $live$
DECLARE
    today date := (now() AT TIME ZONE 'Asia/Singapore')::date;
    d date;
    sup uuid; m_bm uuid; m_as uuid; b1 uuid; b2 uuid; p1 uuid; l1 uuid; l2 uuid; v_run uuid; v_batch uuid; a1 uuid; a2 uuid; a3 uuid;
    v_msg text; v_j jsonb; v_n bigint; v_rec text; v_txt text;
    v_notif bigint := (SELECT count(*) FROM notifications);
    v_pending text := (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents());
    v_fp_before text;
    v_t0 timestamptz := now();
    r record;
BEGIN
    d := today - 1;
    -- 在册的东西先记一个指纹(我的行在事务里 created_at = 事务开始时刻,比较时按 < v_t0 排除)
    SELECT md5(concat_ws('#',
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM processing_runs x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM processing_inputs x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM processing_outputs x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM inbound_batches x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM output_batches x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.inbound_batch_id, x.metal)) FROM inbound_batch_metals x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.output_batch_id, x.metal)) FROM output_batch_metals x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM assay_results x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM inventory_movements x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_entries x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_lines x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM expenses x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM payments x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM work_orders x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM contract_grade_specs x)))
      INTO v_fp_before;
    v_rec := pg_temp.agree_('start');
    RAISE NOTICE 'STEP|start|%', v_rec;
    IF EXISTS (SELECT 1 FROM blending_plans) THEN RAISE EXCEPTION 'MES5B3_LIVE|live already has a blending plan — this proof expects none'; END IF;

    -- ══ 布景(属主):供应商 · 两种物料 · 两批黑粉产出批 ══
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ-PROBE-MES5B3-S', 'ZZ-PROBE-MES5B3 powder supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ-PROBE-MES5B3-BM', 'ZZ-PROBE-MES5B3 black mass', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO m_bm;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ-PROBE-MES5B3-AS', 'ZZ-PROBE-MES5B3 anode sheet', 'battery_material', true, 'anode_sheet', 'end_of_life') RETURNING id INTO m_as;
    INSERT INTO output_batches (material_id, quantity, unit, remaining_qty, output_date, state, notes)
    VALUES (m_bm, 600, 'kg', 600, today - 10, '库存中', 'ZZ-PROBE-MES5B3 B1') RETURNING id INTO b1;
    INSERT INTO output_batches (material_id, quantity, unit, remaining_qty, output_date, state, notes)
    VALUES (m_bm, 400, 'kg', 400, today - 10, '库存中', 'ZZ-PROBE-MES5B3 B2') RETURNING id INTO b2;
    INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code) VALUES (b1, 'discharged_verified'), (b2, 'discharged_verified');
    -- 两批的含量来自化验:lab 记、apl 应用(不同的含量)
    PERFORM pg_temp.as_('lab');
    v_j := record_assay_result(today - 5, '[{"metal":"ni","content_pct":20},{"metal":"co","content_pct":6}]'::jsonb,
                               p_output_batch_id => b1, p_weight_basis => 'dry', p_result_party => 'ours');
    a1 := (v_j ->> 'assay_result_id')::uuid;
    v_j := record_assay_result(today - 5, '[{"metal":"ni","content_pct":12},{"metal":"co","content_pct":3}]'::jsonb,
                               p_output_batch_id => b2, p_weight_basis => 'dry', p_result_party => 'ours');
    a2 := (v_j ->> 'assay_result_id')::uuid;
    PERFORM pg_temp.as_('apl');
    PERFORM apply_output_assay(a1);
    PERFORM apply_output_assay(a2);
    PERFORM pg_temp.me_();
    RAISE NOTICE 'STEP|setup|B1 % (600 kg, ni 20 · co 6 from %) · B2 % (400 kg, ni 12 · co 3 from %)',
        (SELECT code FROM output_batches WHERE id = b1), (SELECT code FROM assay_results WHERE id = a1),
        (SELECT code FROM output_batches WHERE id = b2), (SELECT code FROM assay_results WHERE id = a2);

    -- ══ ① 建计划,看预测 ══
    PERFORM pg_temp.as_('wc');
    v_j := create_blending_plan(m_bm,
        jsonb_build_array(jsonb_build_object('output_batch_id', b1, 'planned_kg', 300), jsonb_build_object('output_batch_id', b2, 'planned_kg', 300)),
        '[{"metal":"ni","min_pct":15,"max_pct":18},{"metal":"co","max_pct":4},{"metal":"li","min_pct":1}]'::jsonb, NULL, 'ZZ-PROBE-MES5B3 plan');
    p1 := (v_j ->> 'plan_id')::uuid;
    SELECT jsonb_object_agg(metal, jsonb_build_object('p', predicted_pct, 'f', flag, 'nm', not_measured, 'a', lines_from_assay, 'm', lines_measured))
      INTO v_j FROM blending_plan_prediction WHERE plan_id = p1;
    PERFORM pg_temp.me_();
    IF (v_j #>> '{ni,p}')::numeric <> 16 OR (v_j #>> '{ni,f}') <> 'within' OR (v_j #>> '{co,p}')::numeric <> 4.5 OR (v_j #>> '{co,f}') <> 'above_max'
       OR (v_j -> 'li' -> 'p') <> 'null'::jsonb OR NOT (v_j #>> '{li,nm}')::boolean OR (v_j #>> '{ni,a}')::int <> 2 THEN
        RAISE EXCEPTION 'MES5B3_LIVE|prediction: %', v_j;
    END IF;
    RAISE NOTICE 'STEP|plan|% created by wc (draft): ni predicted 16 (within 15–18) · co 4.5 (above max 4 — flagged, not refused) · li not measured · both lines from an assay',
        (SELECT code FROM blending_plans WHERE id = p1);

    -- ══ ② 不可售的产出被按名拒 ══
    PERFORM pg_temp.as_('wc');
    v_msg := pg_temp.try_(format($q$SELECT create_blending_plan(%L::uuid, '[{"output_batch_id":"%s","planned_kg":10}]'::jsonb)$q$, m_as, b1));
    PERFORM pg_temp.me_();
    IF v_msg NOT LIKE 'BLEND_OUTPUT_NOT_SALEABLE|ZZ-PROBE-MES5B3-AS|anode_sheet|%' THEN RAISE EXCEPTION 'MES5B3_LIVE|non-saleable output: %', v_msg; END IF;
    RAISE NOTICE 'STEP|not saleable|%', v_msg;

    -- ══ ③ 建单人放行不了;另一个持码人放行 ══
    PERFORM pg_temp.as_('wc');
    v_msg := pg_temp.try_(format('SELECT release_blending_plan(%L::uuid)', p1));
    PERFORM pg_temp.me_();
    IF v_msg NOT LIKE 'SELF_APPROVAL_FORBIDDEN|raiser%' THEN RAISE EXCEPTION 'MES5B3_LIVE|creator release: %', v_msg; END IF;
    RAISE NOTICE 'STEP|creator release|%', v_msg;
    PERFORM pg_temp.as_('wr');
    PERFORM release_blending_plan(p1);
    PERFORM pg_temp.me_();
    IF (SELECT status FROM blending_plans WHERE id = p1) <> 'released' THEN RAISE EXCEPTION 'MES5B3_LIVE|not released'; END IF;
    RAISE NOTICE 'STEP|released|by wr (a second throwaway holding action.wo_release)';
    v_rec := pg_temp.agree_('released');

    -- ══ ④ 只从计划执行;实际与计划不同 ══
    PERFORM pg_temp.as_('ops');
    v_msg := pg_temp.try_(format($q$SELECT commit_processing_run(%L::date, 'probe direct', NULL, '[{"output_batch_id":"%s","quantity_consumed":10}]'::jsonb,
        '[{"material_id":"%s","weight_kg":10}]'::jsonb, 'weight', NULL, NULL, 'blending', %L::timestamptz, %L::timestamptz, 'day')$q$,
        d, b1, m_bm, (d::timestamp + interval '9 hours') AT TIME ZONE 'Asia/Singapore', (d::timestamp + interval '10 hours') AT TIME ZONE 'Asia/Singapore'));
    PERFORM pg_temp.me_();
    IF v_msg NOT LIKE 'BLEND_RUN_FROM_PLAN_ONLY%' THEN RAISE EXCEPTION 'MES5B3_LIVE|direct blending run: %', v_msg; END IF;
    RAISE NOTICE 'STEP|direct run|%', v_msg;
    SELECT id INTO l1 FROM blending_plan_lines WHERE plan_id = p1 AND output_batch_id = b1;
    SELECT id INTO l2 FROM blending_plan_lines WHERE plan_id = p1 AND output_batch_id = b2;
    PERFORM pg_temp.as_('ops');
    v_j := execute_blending_plan(p1, d, (d::timestamp + interval '9 hours') AT TIME ZONE 'Asia/Singapore',
                                 (d::timestamp + interval '10 hours') AT TIME ZONE 'Asia/Singapore', 'day',
                                 jsonb_build_array(jsonb_build_object('line_id', l1, 'actual_kg', 310), jsonb_build_object('line_id', l2, 'actual_kg', 290)), 595);
    PERFORM pg_temp.me_();
    v_run := (v_j ->> 'run_id')::uuid; v_batch := (v_j ->> 'batch_id')::uuid;
    IF (SELECT operation_type_code || ':' || total_input || ':' || total_output FROM processing_runs WHERE id = v_run) <> 'blending:600:595' THEN
        RAISE EXCEPTION 'MES5B3_LIVE|run: %', (SELECT operation_type_code || ':' || total_input || ':' || total_output FROM processing_runs WHERE id = v_run);
    END IF;
    PERFORM pg_temp.as_('ops');
    SELECT string_agg(batch_code || ' planned ' || planned_kg || ' actual ' || actual_kg || ' diff ' || difference_kg, ' · ' ORDER BY batch_code) INTO v_txt
      FROM blending_plan_execution WHERE plan_id = p1;
    SELECT count(*) INTO v_n FROM blending_plan_execution WHERE plan_id = p1 AND difference_kg IN (10, -10);
    PERFORM pg_temp.me_();
    IF v_n <> 2 THEN RAISE EXCEPTION 'MES5B3_LIVE|execution differences: %', v_txt; END IF;
    IF EXISTS (SELECT 1 FROM output_batch_metals WHERE output_batch_id = v_batch) THEN RAISE EXCEPTION 'MES5B3_LIVE|the blended batch got content from somewhere'; END IF;
    RAISE NOTICE 'STEP|executed|by ops: run % (blending, input 600, output 595) → blended batch %; %; no metal content written',
        v_j ->> 'run_code', v_j ->> 'batch_code', v_txt;
    v_rec := pg_temp.agree_('executed');

    -- ══ ⑤ 之后的化验对着目标 ══
    PERFORM pg_temp.as_('ops');
    SELECT jsonb_object_agg(metal, verdict) INTO v_j FROM blending_plan_outcome WHERE plan_id = p1;
    PERFORM pg_temp.me_();
    IF v_j <> '{"ni":"not_assayed","co":"not_assayed","li":"not_assayed"}'::jsonb THEN RAISE EXCEPTION 'MES5B3_LIVE|before assay: %', v_j; END IF;
    PERFORM pg_temp.as_('lab');
    v_j := record_assay_result(today, '[{"metal":"ni","content_pct":16.2},{"metal":"co","content_pct":4.4}]'::jsonb,
                               p_output_batch_id => v_batch, p_weight_basis => 'dry', p_result_party => 'ours');
    a3 := (v_j ->> 'assay_result_id')::uuid;
    v_msg := pg_temp.try_(format($q$INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source) VALUES (%L, 'ni', 16, 'manual')$q$, v_batch));
    PERFORM pg_temp.me_();
    IF v_msg NOT LIKE 'BLEND_CONTENT_FROM_ASSAY_ONLY|%' THEN RAISE EXCEPTION 'MES5B3_LIVE|typed content: %', v_msg; END IF;
    PERFORM pg_temp.as_('ops');
    SELECT jsonb_object_agg(metal, jsonb_build_object('v', verdict, 'c', content_pct)) INTO v_j FROM blending_plan_outcome WHERE plan_id = p1;
    PERFORM pg_temp.me_();
    IF (v_j #>> '{ni,v}') <> 'within' OR (v_j #>> '{co,v}') <> 'above_max' OR (v_j #>> '{li,v}') <> 'metal_not_in_assay' THEN
        RAISE EXCEPTION 'MES5B3_LIVE|outcome: %', v_j;
    END IF;
    RAISE NOTICE 'STEP|assay|lab recorded % on the blended batch: ni 16.2 within 15–18 · co 4.4 above max 4 · li not in the assay; typed content refused (%)',
        (SELECT code FROM assay_results WHERE id = a3), split_part(v_msg, '|', 1);

    -- ══ ⑥ 逐角色读数表 ══
    FOR r IN SELECT unnest(ARRAY['c_admin', 'c_finance', 'c_warehouse', 'c_cto', 'c_cco', 'c_cfo', 'c_gm', 'pv']) AS who LOOP
        PERFORM pg_temp.as_(r.who);
        INSERT INTO mes5b3_roles
        SELECT r.who, (SELECT ro.code FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id WHERE ur.user_id = auth.uid() LIMIT 1),
               cardinality(current_user_permissions()),
               has_permission('module.processing.view'), has_permission('module.processing.view'),
               has_permission('action.wo_create'), has_permission('action.wo_release'), has_permission('action.processing_commit'),
               (SELECT count(*) FROM blending_plans),
               (SELECT COALESCE(string_agg(DISTINCT CASE WHEN content_restricted THEN batch_kind || ':restricted' ELSE batch_kind || ':shown' END, ','), 'no rows')
                  FROM blending_plan_line_metals WHERE plan_id = p1),
               (SELECT COALESCE(string_agg(metal || '=' || CASE WHEN content_restricted THEN 'restricted' ELSE COALESCE(round(predicted_pct, 2)::text, 'not measured') END, ',' ORDER BY metal), 'no rows')
                  FROM blending_plan_prediction WHERE plan_id = p1);
        PERFORM pg_temp.me_();
    END LOOP;
    FOR r IN SELECT * FROM mes5b3_roles LOOP
        RAISE NOTICE 'ROLE|%|% (% codes)|list %|page %|create %|release %|execute %|plans read %|content %|prediction %',
            r.who, r.role, r.codes, r.list_page, r.plan_page, r.can_create, r.can_release, r.can_execute, r.plans_read, r.content_restricted, r.prediction;
    END LOOP;

    -- ══ 在册的东西一个字都没动 ══
    IF md5(concat_ws('#',
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM processing_runs x WHERE x.id <> v_run),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM processing_inputs x WHERE x.run_id <> v_run),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM processing_outputs x WHERE x.run_id <> v_run),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM inbound_batches x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM output_batches x WHERE x.id NOT IN (b1, b2, v_batch)),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.inbound_batch_id, x.metal)) FROM inbound_batch_metals x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.output_batch_id, x.metal)) FROM output_batch_metals x WHERE x.output_batch_id NOT IN (b1, b2, v_batch)),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM assay_results x WHERE x.id NOT IN (a1, a2, a3)),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM inventory_movements x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_entries x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_lines x WHERE x.entry_id IN (SELECT id FROM journal_entries WHERE created_at < v_t0)),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM expenses x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM payments x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM work_orders x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM contract_grade_specs x))) IS DISTINCT FROM v_fp_before THEN
        RAISE EXCEPTION 'MES5B3_LIVE|a pre-existing run, leg, batch, metal content, assay, movement, journal, expense, payment, work order or grade spec changed';
    END IF;
    IF (SELECT count(*) FROM notifications) <> v_notif THEN RAISE EXCEPTION 'MES5B3_LIVE|notifications moved'; END IF;
    IF (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents()) <> v_pending THEN
        RAISE EXCEPTION 'MES5B3_LIVE|pending documents changed';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN RAISE EXCEPTION 'MES5B3_LIVE|require_calibrated_since set'; END IF;
    v_rec := pg_temp.agree_('end');
    RAISE NOTICE 'STEP|untouched|pre-existing runs, legs, batches, metal content, assays, movements, journals, expenses, payments, work orders, grade specs identical; notifications %; pending %; reconciliation %',
        v_notif, v_pending, v_rec;
    RAISE NOTICE 'STEP|done|%', clock_timestamp() - v_t0;
END
$live$;

ROLLBACK;

SELECT 'AFTER|plans=' || (SELECT count(*) FROM blending_plans) || '|probe materials=' || (SELECT count(*) FROM materials WHERE code LIKE 'ZZ-PROBE-MES5B3%')
    || '|probe suppliers=' || (SELECT count(*) FROM suppliers WHERE code LIKE 'ZZ-PROBE-MES5B3%')
    || '|require_calibrated_since=' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings), 'NULL');
