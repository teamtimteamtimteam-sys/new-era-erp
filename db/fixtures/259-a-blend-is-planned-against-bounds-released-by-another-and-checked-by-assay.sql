-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 259 —— 一份配料计划:对着上下界排、先看预测、别人放行、从计划页执行成一炉、混出来那一批化验之后对着目标比
--   (MES-5b-3,2026-10-09;MES-5b Step 0 Q16–Q20 · Q32 · Q35,Tim 照推荐裁定;并入:admin 持每一个码)
-- ═══════════════════════════════════════════════════════════════════════════
-- 臂:
--   PLAN   BLD- 按年无洞(下一年从 0001 起);四态;只有草稿改得动;取消要理由、已执行的取消不了;没有 action.wo_create 建不了;
--          建单人之外没有别的放行人 → 建不了(BLEND_NO_OTHER_RELEASER)
--   SALE   产出物料不可售 → BLEND_OUTPUT_NOT_SALEABLE(按名,带形态);可售但不是配料的产出形态 → BLEND_OUTPUT_FORM_NOT_BLENDABLE;
--          一行批次不是配料收的形态 → BLEND_LINE_FORM_NOT_BLENDABLE;单位不是 kg;同一批两行;公斤数 ≤ 0
--   TGT    每种金属的下界 / 上界:人敲的(来源 manual)与从合同的品位规格抄来的(来源 contract,快照)—— 不给目标而选了合同就整份抄
--          适用于这种物料的规格(指名物料的那一条优先;给别的物料的不抄);至少一个界、0–100、下界不高于上界、一种金属一行;
--          指名一条别的合同的规格 / 给别的物料的规格按名拒
--   PRED   预测 = 按计划公斤数加权的平均;出处照直数(化验 / 人填);任何一行没量过 → NULL + not_measured;出界只标(above_max)不拒,
--          照样放行、照样执行
--   REL    建单人放行 → SELF_APPROVAL_FORBIDDEN|raiser;没有 action.wo_release → PERMISSION_DENIED;另一个持码人放行得了;没有目标放行不了
--   EXEC   只从计划页上:直接拿 blending 记一炉 → BLEND_RUN_FROM_PLAN_ONLY;新建加工单的选单(started_from_run_page = false)里没有它;
--          引擎的签名逐字未变;没有 action.processing_commit → PERMISSION_DENIED;草稿执行不了;实际行对不上 → BLEND_ACTUAL_LINES_MISMATCH;
--          实际公斤数与计划不同 → 照记,差多少由 blending_plan_execution 照直说;计划 executed、记下那一炉;混出来那一批一行含量都没有
--   ASSAY  混出来那一批的含量只来自化验:人填一行 → BLEND_CONTENT_FROM_ASSAY_ONLY;化验之前 not_assayed;记一份化验之后逐条对着目标
--          (within / above_max / metal_not_in_assay);应用那份化验之后批次的含量来源是 assay
--   READ   含量只给看得见那一批的人:只持加工查看的读者 → 含量 NULL、受限;持产出查看、不持进料查看的读者 → 产出那一行看得见、进料那一行受限,
--          预测整份受限;没有加工查看的读者一行计划都读不到
--   LOG    三张新表进变更记录(覆盖零缺口、豁免仍是 8);审计主语 blending_plan 登记了、门是加工查看码;目标与批次在它的记录上
--   ADMIN  引导的 admin 持目录里【每一个】码(含 module.tasks.view_all);把每一个码经 set_role_permissions 存给一个角色 —— 过得了"动作码蕴含查看码"
--
-- 自带数据(README 第 2 条)。以 postgres 跑(绕过 RLS);员工的调用真的切成 authenticated + 那个人的 JWT。
-- 【数怎么来的】(README 第 1 条)
--   A 进料黑粉 1000 kg:ni 20 · co 6(人填)。B 进料黑粉 1000 kg:ni 10(人填,没有 co)。C 产出黑粉 500 kg:ni 16 · co 4(化验,应用过)。
--   计划一:A 300 + C 200 → ni (300×20 + 200×16) / 500 = 18.4 · co (300×6 + 200×4) / 500 = 5.2;目标 ni 18–22(within)· co ≤ 5(above_max)·
--     li ≥ 1(两行都没量过 → NULL)。执行:A 310 · C 190(差 +10 / −10),称出 495。化验:ni 18.9 · co 5.3(没有 li)。
--   计划二:A 100 + B 100 → ni 15;co 只有 A 量过 → NULL(lines_measured 1 / 2)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f259_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

-- 以某人跑一句;返回 'OK' 或错误原文。之后身份回到调用之前的那一个。
CREATE FUNCTION pg_temp.f259_do(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v_prev text := NULLIF(current_setting('request.jwt.claims', true), '');
BEGIN
    PERFORM pg_temp.f259_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_prev, ''), true);
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_prev, ''), true);
    RETURN SQLERRM;
END;
$f$;

-- 以某人读一个值(读不到就抛 —— 读的失败不许被读成一个答案)
CREATE FUNCTION pg_temp.f259_get(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_prev text := NULLIF(current_setting('request.jwt.claims', true), '');
BEGIN
    PERFORM pg_temp.f259_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_prev, ''), true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_prev, ''), true);
    RAISE;
END;
$f$;

-- 一个角色带一组码,授给一个新账号
CREATE FUNCTION pg_temp.f259_user(p_label text, p_codes text[]) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE u uuid := gen_random_uuid(); r uuid;
BEGIN
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES (u, 'fx259-' || p_label || '@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx259-' || p_label, 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r, c FROM unnest(p_codes) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);
    RETURN u;
END;
$f$;

DO $$
DECLARE
    u_all  uuid; u_wc uuid; u_wr uuid; u_pc uuid; u_pv uuid; u_ov uuid; u_none uuid; u_oe uuid;
    v_year int := EXTRACT(YEAR FROM CURRENT_DATE)::int;
    d date := CURRENT_DATE - 3;
    v_sup uuid; v_ctr uuid; v_ctr2 uuid; s_ni uuid; s_co uuid; s_mn uuid; s_other uuid;
    m_bm uuid; m_cpw uuid; m_as uuid; m_sep uuid; m_mod uuid;
    b_a uuid; b_b uuid; b_c uuid; b_mod uuid; b_pcs uuid;
    p1 uuid; p2 uuid; p3 uuid; p4 uuid; l_a uuid; l_c uuid;
    v_j jsonb; v_msg text; v_n bigint; v_num numeric; v_txt text; v_run uuid; v_batch uuid; v_assay uuid;
    v_engine text;
BEGIN
    u_all  := pg_temp.f259_user('all', (SELECT array_agg(code) FROM permissions));
    u_wc   := pg_temp.f259_user('wc', ARRAY['action.wo_create', 'module.processing.view', 'module.inbound.view', 'module.output.view']);
    u_wr   := pg_temp.f259_user('wr', ARRAY['action.wo_release', 'module.processing.view']);
    u_pc   := pg_temp.f259_user('pc', ARRAY['action.processing_commit', 'module.processing.view', 'module.inbound.view', 'module.output.view']);
    u_pv   := pg_temp.f259_user('pv', ARRAY['module.processing.view']);
    u_ov   := pg_temp.f259_user('ov', ARRAY['module.processing.view', 'module.output.view']);
    u_none := pg_temp.f259_user('none', ARRAY['module.tasks.view']);
    u_oe   := pg_temp.f259_user('oe', ARRAY['module.output.view', 'module.output.edit']);

    -- ══════════════ 布景 ══════════════
    PERFORM pg_temp.f259_as(NULL);
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ259-S', 'f259 powder supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    PERFORM pg_temp.f259_as(u_all);
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ259-BM', 'f259 black mass', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO m_bm;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ259-CPW', 'f259 cathode powder', 'battery_material', true, 'cathode_powder', 'end_of_life') RETURNING id INTO m_cpw;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ259-AS', 'f259 anode sheet', 'battery_material', true, 'anode_sheet', 'end_of_life') RETURNING id INTO m_as;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ259-SEP', 'f259 separator', 'battery_material', true, 'separator', 'end_of_life') RETURNING id INTO m_sep;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ259-MOD', 'f259 modules', 'battery_material', true, 'module', 'end_of_life', 'ev_traction') RETURNING id INTO m_mod;
    PERFORM pg_temp.f259_as(NULL);
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ259-A', m_bm, v_sup, 1000, 1000, 'kg', d - 30, 'other', 'fixture 259 自带数据') RETURNING id INTO b_a;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ259-B', m_bm, v_sup, 1000, 1000, 'kg', d - 30, 'other', 'fixture 259 自带数据') RETURNING id INTO b_b;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ259-MODB', m_mod, v_sup, 500, 500, 'kg', d - 30, 'other', 'fixture 259 自带数据') RETURNING id INTO b_mod;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ259-PCS', m_bm, v_sup, 10, 10, 'pcs', d - 30, 'other', 'fixture 259 自带数据') RETURNING id INTO b_pcs;
    PERFORM pg_temp.f259_as(u_all);
    PERFORM reprice_inbound_batch(b_a, 1, (SELECT code FROM currencies WHERE is_base), NULL, 'f259');
    PERFORM reprice_inbound_batch(b_b, 1, (SELECT code FROM currencies WHERE is_base), NULL, 'f259');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id IN (b_a, b_b);
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) VALUES (b_a, 'discharged_verified'), (b_b, 'discharged_verified');
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source) VALUES
        (b_a, 'ni', 20, 'manual'), (b_a, 'co', 6, 'manual'), (b_b, 'ni', 10, 'manual');
    -- C:一批产出的黑粉,含量来自一份应用过的化验
    INSERT INTO output_batches (material_id, quantity, unit, remaining_qty, output_date, state)
    VALUES (m_bm, 500, 'kg', 500, d - 20, '库存中') RETURNING id INTO b_c;
    INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code) VALUES (b_c, 'discharged_verified');
    v_j := pg_temp.f259_get(u_all, format($q$SELECT record_assay_result(%L::date, '[{"metal":"ni","content_pct":16},{"metal":"co","content_pct":4}]'::jsonb,
        p_output_batch_id => %L::uuid, p_weight_basis => 'dry', p_result_party => 'ours')$q$, d - 15, b_c));
    v_msg := pg_temp.f259_do(u_all, format($q$SELECT apply_output_assay(%L::uuid)$q$, v_j ->> 'assay_result_id'));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 259 setup: applying the assay on C: %', v_msg; END IF;
    IF (SELECT count(*) FROM output_batch_metals WHERE output_batch_id = b_c AND content_source = 'assay') <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 259 setup: C should carry two assayed metals'; END IF;
    -- 一份合同,三条品位规格:ni ≥ 17(不指物料)· co ≤ 6(指黑粉)· mn ≤ 1(指正极粉 —— 不适用于黑粉)
    INSERT INTO contracts (supplier_id, kind, title, effective_from, status)
    VALUES (v_sup, 'offtake', 'f259 offtake', d - 60, 'draft') RETURNING id INTO v_ctr;
    INSERT INTO contracts (supplier_id, kind, title, effective_from, status)
    VALUES (v_sup, 'offtake', 'f259 other contract', d - 60, 'draft') RETURNING id INTO v_ctr2;
    INSERT INTO contract_grade_specs (contract_id, material_id, metal, min_pct, max_pct) VALUES (v_ctr, NULL, 'ni', 17, NULL) RETURNING id INTO s_ni;
    INSERT INTO contract_grade_specs (contract_id, material_id, metal, min_pct, max_pct) VALUES (v_ctr, m_bm, 'co', NULL, 6) RETURNING id INTO s_co;
    INSERT INTO contract_grade_specs (contract_id, material_id, metal, min_pct, max_pct) VALUES (v_ctr, m_cpw, 'mn', NULL, 1) RETURNING id INTO s_mn;
    INSERT INTO contract_grade_specs (contract_id, material_id, metal, min_pct, max_pct) VALUES (v_ctr2, NULL, 'li', 1, NULL) RETURNING id INTO s_other;

    -- ══════════════ PLAN ══════════════
    RAISE NOTICE 'fixture 259 · PLAN';
    v_msg := pg_temp.f259_do(u_none, format($q$SELECT create_blending_plan(%L::uuid, '[{"inbound_batch_id":"%s","planned_kg":10}]'::jsonb)$q$, m_bm, b_a));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.wo_create%' THEN RAISE EXCEPTION 'FIXTURE 259 PLAN: creating needs action.wo_create, got %', v_msg; END IF;
    -- 建单人之外没有别的放行人 → 建不了(子块里把别的持码人拿掉,子块回滚把它还回来)
    BEGIN
        PERFORM pg_temp.f259_as(u_all);
        DELETE FROM role_permissions WHERE permission_code = 'action.wo_release';
        v_msg := pg_temp.f259_do(u_wc, format($q$SELECT create_blending_plan(%L::uuid, '[{"inbound_batch_id":"%s","planned_kg":10}]'::jsonb)$q$, m_bm, b_a));
        RAISE EXCEPTION 'F259_PROBE|%', v_msg;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'F259_PROBE|BLEND_NO_OTHER_RELEASER%' THEN
            RAISE EXCEPTION 'FIXTURE 259 PLAN: with no other holder of action.wo_release the plan must not be born, got %', SQLERRM; END IF;
    END;
    v_j := pg_temp.f259_get(u_wc, format($q$SELECT create_blending_plan(%L::uuid,
        '[{"inbound_batch_id":"%s","planned_kg":300},{"output_batch_id":"%s","planned_kg":200}]'::jsonb,
        '[{"metal":"ni","min_pct":18,"max_pct":22},{"metal":"co","max_pct":5},{"metal":"li","min_pct":1}]'::jsonb, NULL, 'f259 plan one')$q$, m_bm, b_a, b_c));
    p1 := (v_j ->> 'plan_id')::uuid;
    v_j := pg_temp.f259_get(u_wc, format($q$SELECT create_blending_plan(%L::uuid,
        '[{"inbound_batch_id":"%s","planned_kg":100},{"inbound_batch_id":"%s","planned_kg":100}]'::jsonb,
        '[{"metal":"ni","min_pct":12}]'::jsonb)$q$, m_bm, b_a, b_b));
    p2 := (v_j ->> 'plan_id')::uuid;
    IF (SELECT code FROM blending_plans WHERE id = p1) <> 'BLD-' || v_year || '-0001'
       OR (SELECT code FROM blending_plans WHERE id = p2) <> 'BLD-' || v_year || '-0002' THEN
        RAISE EXCEPTION 'FIXTURE 259 PLAN: codes should be BLD-%-0001 and -0002, got % / %', v_year,
            (SELECT code FROM blending_plans WHERE id = p1), (SELECT code FROM blending_plans WHERE id = p2); END IF;
    IF next_blending_plan_code(make_date(v_year + 1, 1, 5)) <> 'BLD-' || (v_year + 1) || '-0001'
       OR next_blending_plan_code(CURRENT_DATE) <> 'BLD-' || v_year || '-0003' THEN
        RAISE EXCEPTION 'FIXTURE 259 PLAN: numbering is yearly and gapless (next year starts at 0001)'; END IF;
    IF (SELECT status FROM blending_plans WHERE id = p1) <> 'draft' OR (SELECT created_by FROM blending_plans WHERE id = p1) <> u_wc THEN
        RAISE EXCEPTION 'FIXTURE 259 PLAN: a new plan is a draft, created by its creator'; END IF;
    -- 改草稿(同一个码)—— 整份替换,判据同一份
    v_msg := pg_temp.f259_do(u_wc, format($q$SELECT amend_blending_plan(%L::uuid, %L::uuid,
        '[{"inbound_batch_id":"%s","planned_kg":100},{"inbound_batch_id":"%s","planned_kg":100}]'::jsonb,
        '[{"metal":"ni","min_pct":12,"max_pct":30}]'::jsonb, NULL, 'f259 plan two, amended')$q$, p2, m_bm, b_a, b_b));
    IF v_msg <> 'OK' OR (SELECT max_pct FROM blending_plan_targets WHERE plan_id = p2 AND metal = 'ni') <> 30 THEN
        RAISE EXCEPTION 'FIXTURE 259 PLAN: amending a draft replaces its targets and lines (%)', v_msg; END IF;
    v_msg := pg_temp.f259_do(u_pv, format($q$SELECT amend_blending_plan(%L::uuid, %L::uuid, '[{"inbound_batch_id":"%s","planned_kg":5}]'::jsonb)$q$, p2, m_bm, b_a));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.wo_create%' THEN RAISE EXCEPTION 'FIXTURE 259 PLAN: amending needs action.wo_create, got %', v_msg; END IF;

    -- ══════════════ SALE ══════════════
    RAISE NOTICE 'fixture 259 · SALE';
    v_msg := pg_temp.f259_do(u_wc, format($q$SELECT create_blending_plan(%L::uuid, '[{"inbound_batch_id":"%s","planned_kg":10}]'::jsonb)$q$, m_as, b_a));
    IF v_msg NOT LIKE 'BLEND_OUTPUT_NOT_SALEABLE|ZZ259-AS|anode_sheet|%' THEN
        RAISE EXCEPTION 'FIXTURE 259 SALE: a non-saleable output material is refused by name (with its form), got %', v_msg; END IF;
    v_msg := pg_temp.f259_do(u_wc, format($q$SELECT create_blending_plan(%L::uuid, '[{"inbound_batch_id":"%s","planned_kg":10}]'::jsonb)$q$, m_sep, b_a));
    IF v_msg NOT LIKE 'BLEND_OUTPUT_FORM_NOT_BLENDABLE|ZZ259-SEP|separator%' THEN
        RAISE EXCEPTION 'FIXTURE 259 SALE: a saleable form that blending does not output is refused, got %', v_msg; END IF;
    v_msg := pg_temp.f259_do(u_wc, format($q$SELECT create_blending_plan(%L::uuid, '[{"inbound_batch_id":"%s","planned_kg":10}]'::jsonb)$q$, m_bm, b_mod));
    IF v_msg NOT LIKE 'BLEND_LINE_FORM_NOT_BLENDABLE|ZZ259-MODB|module%' THEN
        RAISE EXCEPTION 'FIXTURE 259 SALE: a line whose form blending does not take is refused, got %', v_msg; END IF;
    v_msg := pg_temp.f259_do(u_wc, format($q$SELECT create_blending_plan(%L::uuid, '[{"inbound_batch_id":"%s","planned_kg":1}]'::jsonb)$q$, m_bm, b_pcs));
    IF v_msg NOT LIKE 'BLEND_LINE_UNIT_NOT_KG|ZZ259-PCS|pcs%' THEN RAISE EXCEPTION 'FIXTURE 259 SALE: a non-kg batch is refused, got %', v_msg; END IF;
    v_msg := pg_temp.f259_do(u_wc, format($q$SELECT create_blending_plan(%L::uuid, '[{"inbound_batch_id":"%s","planned_kg":1},{"inbound_batch_id":"%s","planned_kg":2}]'::jsonb)$q$, m_bm, b_a, b_a));
    IF v_msg NOT LIKE 'BLEND_LINE_DUPLICATE_BATCH|ZZ259-A%' THEN RAISE EXCEPTION 'FIXTURE 259 SALE: one batch, one line, got %', v_msg; END IF;
    v_msg := pg_temp.f259_do(u_wc, format($q$SELECT create_blending_plan(%L::uuid, '[{"inbound_batch_id":"%s","planned_kg":0}]'::jsonb)$q$, m_bm, b_a));
    IF v_msg NOT LIKE 'BLEND_LINE_KG_INVALID|ZZ259-A%' THEN RAISE EXCEPTION 'FIXTURE 259 SALE: planned kg must be > 0, got %', v_msg; END IF;
    v_msg := pg_temp.f259_do(u_wc, format($q$SELECT create_blending_plan(%L::uuid, '[]'::jsonb)$q$, m_bm));
    IF v_msg NOT LIKE 'BLEND_NO_LINES%' THEN RAISE EXCEPTION 'FIXTURE 259 SALE: a plan needs a line, got %', v_msg; END IF;
    IF (SELECT count(*) FROM blending_plans) <> 2 THEN RAISE EXCEPTION 'FIXTURE 259 SALE: a refused plan left a row'; END IF;

    -- ══════════════ TGT ══════════════
    RAISE NOTICE 'fixture 259 · TGT';
    IF (SELECT string_agg(metal || ':' || COALESCE(min_pct::text, '-') || ':' || COALESCE(max_pct::text, '-') || ':' || source, ',' ORDER BY metal)
          FROM blending_plan_targets WHERE plan_id = p1) <> 'co:-:5:manual,li:1:-:manual,ni:18:22:manual' THEN
        RAISE EXCEPTION 'FIXTURE 259 TGT: hand-entered bounds per metal, got %',
            (SELECT string_agg(metal || ':' || COALESCE(min_pct::text, '-') || ':' || COALESCE(max_pct::text, '-') || ':' || source, ',' ORDER BY metal)
               FROM blending_plan_targets WHERE plan_id = p1); END IF;
    -- 选了合同而不给目标:整份抄适用于黑粉的规格(ni 不指物料、co 指黑粉;mn 是给正极粉的 —— 不抄)
    v_j := pg_temp.f259_get(u_wc, format($q$SELECT create_blending_plan(%L::uuid, '[{"inbound_batch_id":"%s","planned_kg":50}]'::jsonb, NULL, %L::uuid)$q$, m_bm, b_b, v_ctr));
    p3 := (v_j ->> 'plan_id')::uuid;
    IF (SELECT string_agg(metal || ':' || COALESCE(min_pct::text, '-') || ':' || COALESCE(max_pct::text, '-') || ':' || source || ':' || (source_grade_spec_id IS NOT NULL), ',' ORDER BY metal)
          FROM blending_plan_targets WHERE plan_id = p3) <> 'co:-:6:contract:true,ni:17:-:contract:true' THEN
        RAISE EXCEPTION 'FIXTURE 259 TGT: copying a contract takes its applicable grade specs (ni, co — not mn), got %',
            (SELECT string_agg(metal || ':' || COALESCE(min_pct::text, '-') || ':' || COALESCE(max_pct::text, '-') || ':' || source, ',' ORDER BY metal)
               FROM blending_plan_targets WHERE plan_id = p3); END IF;
    -- 快照:合同以后改了,计划不跟
    UPDATE contract_grade_specs SET min_pct = 19 WHERE id = s_ni;
    IF (SELECT min_pct FROM blending_plan_targets WHERE plan_id = p3 AND metal = 'ni') <> 17 THEN
        RAISE EXCEPTION 'FIXTURE 259 TGT: a copied bound is a snapshot'; END IF;
    UPDATE contract_grade_specs SET min_pct = 17 WHERE id = s_ni;
    -- 逐条:一条合同规格 + 一条人敲的
    v_msg := pg_temp.f259_do(u_wc, format($q$SELECT amend_blending_plan(%L::uuid, %L::uuid, '[{"inbound_batch_id":"%s","planned_kg":50}]'::jsonb,
        '[{"grade_spec_id":"%s"},{"metal":"li","min_pct":2}]'::jsonb, %L::uuid)$q$, p3, m_bm, b_b, s_co, v_ctr));
    IF v_msg <> 'OK' OR (SELECT string_agg(metal || ':' || source, ',' ORDER BY metal) FROM blending_plan_targets WHERE plan_id = p3) <> 'co:contract,li:manual' THEN
        RAISE EXCEPTION 'FIXTURE 259 TGT: one copied and one entered (%)', v_msg; END IF;
    v_msg := pg_temp.f259_do(u_wc, format($q$SELECT amend_blending_plan(%L::uuid, %L::uuid, '[{"inbound_batch_id":"%s","planned_kg":50}]'::jsonb, '[{"grade_spec_id":"%s"}]'::jsonb, %L::uuid)$q$, p3, m_bm, b_b, s_mn, v_ctr));
    IF v_msg NOT LIKE 'BLEND_TARGET_SPEC_OTHER_MATERIAL|mn|ZZ259-CPW%' THEN RAISE EXCEPTION 'FIXTURE 259 TGT: a spec for another material is refused, got %', v_msg; END IF;
    v_msg := pg_temp.f259_do(u_wc, format($q$SELECT amend_blending_plan(%L::uuid, %L::uuid, '[{"inbound_batch_id":"%s","planned_kg":50}]'::jsonb, '[{"grade_spec_id":"%s"}]'::jsonb, %L::uuid)$q$, p3, m_bm, b_b, s_other, v_ctr));
    IF v_msg NOT LIKE 'BLEND_TARGET_SPEC_NOT_FROM_CONTRACT|%' THEN RAISE EXCEPTION 'FIXTURE 259 TGT: a spec from another contract is refused, got %', v_msg; END IF;
    v_msg := pg_temp.f259_do(u_wc, format($q$SELECT amend_blending_plan(%L::uuid, %L::uuid, '[{"inbound_batch_id":"%s","planned_kg":50}]'::jsonb, '[{"metal":"ni"}]'::jsonb)$q$, p3, m_bm, b_b));
    IF v_msg NOT LIKE 'BLEND_TARGET_NEEDS_A_BOUND|ni%' THEN RAISE EXCEPTION 'FIXTURE 259 TGT: a target needs a bound, got %', v_msg; END IF;
    v_msg := pg_temp.f259_do(u_wc, format($q$SELECT amend_blending_plan(%L::uuid, %L::uuid, '[{"inbound_batch_id":"%s","planned_kg":50}]'::jsonb, '[{"metal":"ni","min_pct":30,"max_pct":20}]'::jsonb)$q$, p3, m_bm, b_b));
    IF v_msg NOT LIKE 'BLEND_TARGET_BOUNDS_ORDER|ni%' THEN RAISE EXCEPTION 'FIXTURE 259 TGT: min above max is refused, got %', v_msg; END IF;
    v_msg := pg_temp.f259_do(u_wc, format($q$SELECT amend_blending_plan(%L::uuid, %L::uuid, '[{"inbound_batch_id":"%s","planned_kg":50}]'::jsonb, '[{"metal":"ni","max_pct":101}]'::jsonb)$q$, p3, m_bm, b_b));
    IF v_msg NOT LIKE 'BLEND_TARGET_PCT_INVALID|ni%' THEN RAISE EXCEPTION 'FIXTURE 259 TGT: a bound outside 0–100 is refused, got %', v_msg; END IF;
    v_msg := pg_temp.f259_do(u_wc, format($q$SELECT amend_blending_plan(%L::uuid, %L::uuid, '[{"inbound_batch_id":"%s","planned_kg":50}]'::jsonb, '[{"metal":"ni","min_pct":1},{"metal":"ni","max_pct":9}]'::jsonb)$q$, p3, m_bm, b_b));
    IF v_msg NOT LIKE 'BLEND_TARGET_DUPLICATE_METAL|ni%' THEN RAISE EXCEPTION 'FIXTURE 259 TGT: one metal one line, got %', v_msg; END IF;
    v_msg := pg_temp.f259_do(u_wc, format($q$SELECT amend_blending_plan(%L::uuid, %L::uuid, '[{"inbound_batch_id":"%s","planned_kg":50}]'::jsonb, '[{"metal":"unobtainium","min_pct":1}]'::jsonb)$q$, p3, m_bm, b_b));
    IF v_msg NOT LIKE 'METAL_INVALID|unobtainium%' THEN RAISE EXCEPTION 'FIXTURE 259 TGT: an unknown metal is refused, got %', v_msg; END IF;

    -- ══════════════ PRED ══════════════
    RAISE NOTICE 'fixture 259 · PRED';
    v_j := pg_temp.f259_get(u_all, format($q$SELECT jsonb_object_agg(metal, jsonb_build_object('p', predicted_pct, 'nm', not_measured, 'f', flag,
        'm', lines_measured, 'n', line_count, 'a', lines_from_assay, 'h', lines_manual, 'r', content_restricted)) FROM blending_plan_prediction WHERE plan_id = %L$q$, p1));
    IF (v_j #>> '{ni,p}')::numeric <> (300 * 20 + 200 * 16)::numeric / 500 OR (v_j #>> '{ni,f}') <> 'within' THEN
        RAISE EXCEPTION 'FIXTURE 259 PRED: ni is the mass-weighted mean 18.4, within 18–22, got %', v_j -> 'ni'; END IF;
    IF (v_j #>> '{co,p}')::numeric <> (300 * 6 + 200 * 4)::numeric / 500 OR (v_j #>> '{co,f}') <> 'above_max' THEN
        RAISE EXCEPTION 'FIXTURE 259 PRED: co is 5.2, flagged above its max 5, got %', v_j -> 'co'; END IF;
    IF (v_j #>> '{ni,a}')::int <> 1 OR (v_j #>> '{ni,h}')::int <> 1 OR (v_j #>> '{ni,m}')::int <> 2 OR (v_j #>> '{ni,n}')::int <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 259 PRED: the source is shown (one line from an assay, one entered by hand), got %', v_j -> 'ni'; END IF;
    IF (v_j -> 'li' -> 'p') <> 'null'::jsonb OR NOT (v_j #>> '{li,nm}')::boolean OR (v_j -> 'li' -> 'f') <> 'null'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 259 PRED: li is not measured on any line — no prediction, no flag, got %', v_j -> 'li'; END IF;
    v_j := pg_temp.f259_get(u_all, format($q$SELECT jsonb_object_agg(metal, jsonb_build_object('p', predicted_pct, 'nm', not_measured, 'm', lines_measured)) FROM blending_plan_prediction WHERE plan_id = %L$q$, p2));
    IF (v_j #>> '{ni,p}')::numeric <> 15 OR (v_j -> 'co' -> 'p') <> 'null'::jsonb OR NOT (v_j #>> '{co,nm}')::boolean OR (v_j #>> '{co,m}')::int <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 259 PRED: plan two — ni 15; co measured on one line of two, so not measured, got %', v_j; END IF;

    -- ══════════════ REL ══════════════
    RAISE NOTICE 'fixture 259 · REL';
    v_msg := pg_temp.f259_do(u_wc, format($q$SELECT release_blending_plan(%L::uuid)$q$, p1));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.wo_release%' THEN RAISE EXCEPTION 'FIXTURE 259 REL: releasing needs action.wo_release, got %', v_msg; END IF;
    -- 建单人即使持放行码也放行不了自己的计划:把放行码给建单人那个角色(子块里)
    BEGIN
        INSERT INTO role_permissions (role_id, permission_code) SELECT ur.role_id, 'action.wo_release' FROM user_roles ur WHERE ur.user_id = u_wc;
        v_msg := pg_temp.f259_do(u_wc, format($q$SELECT release_blending_plan(%L::uuid)$q$, p1));
        RAISE EXCEPTION 'F259_PROBE|%', v_msg;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'F259_PROBE|SELF_APPROVAL_FORBIDDEN|raiser%' THEN
            RAISE EXCEPTION 'FIXTURE 259 REL: the creator can never release their own plan, got %', SQLERRM; END IF;
    END;
    v_msg := pg_temp.f259_do(u_wr, format($q$SELECT release_blending_plan(%L::uuid)$q$, p1));
    IF v_msg <> 'OK' OR (SELECT status FROM blending_plans WHERE id = p1) <> 'released' OR (SELECT released_by FROM blending_plans WHERE id = p1) <> u_wr THEN
        RAISE EXCEPTION 'FIXTURE 259 REL: another holder of action.wo_release releases it — even with a prediction above a bound (%)', v_msg; END IF;
    v_msg := pg_temp.f259_do(u_wr, format($q$SELECT release_blending_plan(%L::uuid)$q$, p1));
    IF v_msg NOT LIKE 'BLEND_PLAN_NOT_DRAFT|%|released%' THEN RAISE EXCEPTION 'FIXTURE 259 REL: a released plan is not released twice, got %', v_msg; END IF;
    v_msg := pg_temp.f259_do(u_wc, format($q$SELECT amend_blending_plan(%L::uuid, %L::uuid, '[{"inbound_batch_id":"%s","planned_kg":5}]'::jsonb)$q$, p1, m_bm, b_a));
    IF v_msg NOT LIKE 'BLEND_PLAN_NOT_DRAFT|%|released%' THEN RAISE EXCEPTION 'FIXTURE 259 REL: a released plan is frozen, got %', v_msg; END IF;
    v_j := pg_temp.f259_get(u_wc, format($q$SELECT create_blending_plan(%L::uuid, '[{"inbound_batch_id":"%s","planned_kg":5}]'::jsonb)$q$, m_bm, b_b));
    p4 := (v_j ->> 'plan_id')::uuid;
    v_msg := pg_temp.f259_do(u_wr, format($q$SELECT release_blending_plan(%L::uuid)$q$, p4));
    IF v_msg NOT LIKE 'BLEND_PLAN_NO_TARGETS|%' THEN RAISE EXCEPTION 'FIXTURE 259 REL: a plan with no target is not released, got %', v_msg; END IF;
    -- 取消:要理由;草稿取消得了
    v_msg := pg_temp.f259_do(u_wc, format($q$SELECT cancel_blending_plan(%L::uuid, '  ')$q$, p4));
    IF v_msg NOT LIKE 'BLEND_CANCEL_REASON_REQUIRED%' THEN RAISE EXCEPTION 'FIXTURE 259 REL: cancelling needs a reason, got %', v_msg; END IF;
    v_msg := pg_temp.f259_do(u_wc, format($q$SELECT cancel_blending_plan(%L::uuid, 'f259 not needed')$q$, p4));
    IF v_msg <> 'OK' OR (SELECT status FROM blending_plans WHERE id = p4) <> 'cancelled' THEN RAISE EXCEPTION 'FIXTURE 259 REL: a draft is cancelled with a reason (%)', v_msg; END IF;

    -- ══════════════ EXEC ══════════════
    RAISE NOTICE 'fixture 259 · EXEC';
    SELECT id INTO l_a FROM blending_plan_lines WHERE plan_id = p1 AND inbound_batch_id = b_a;
    SELECT id INTO l_c FROM blending_plan_lines WHERE plan_id = p1 AND output_batch_id = b_c;
    v_engine := pg_get_function_arguments('public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid, uuid, text, timestamp with time zone, timestamp with time zone, text, uuid, jsonb, uuid)'::regprocedure);
    IF v_engine <> 'p_process_date date, p_notes text, p_loss_qty numeric, p_inputs jsonb, p_outputs jsonb, p_allocation_basis text, p_work_order_id uuid DEFAULT NULL::uuid, p_equipment_id uuid DEFAULT NULL::uuid, p_operation_type_code text DEFAULT NULL::text, p_started_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_ended_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_shift_code text DEFAULT NULL::text, p_recipe_version_id uuid DEFAULT NULL::uuid, p_values jsonb DEFAULT NULL::jsonb, p_corrects_run_id uuid DEFAULT NULL::uuid' THEN
        RAISE EXCEPTION 'FIXTURE 259 EXEC: the run engine signature changed: %', v_engine; END IF;
    IF (SELECT count(*) FROM pg_proc WHERE proname = 'commit_processing_run') <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 259 EXEC: commit_processing_run must have exactly one signature'; END IF;
    IF EXISTS (SELECT 1 FROM operation_types WHERE code = 'blending' AND NOT started_from_run_page)
       OR NOT EXISTS (SELECT 1 FROM operation_types WHERE code = 'blending' AND is_active) THEN
        RAISE EXCEPTION 'FIXTURE 259 EXEC: blending is an active operation left out of the ordinary new-run form (started_from_run_page)'; END IF;
    -- 直接拿 blending 记一炉 → 拒(同一个持码人,同一批料)
    v_msg := pg_temp.f259_do(u_pc, format($q$SELECT commit_processing_run(%L::date, 'f259 direct', NULL, '[{"inbound_batch_id":"%s","quantity_consumed":10}]'::jsonb,
        '[{"material_id":"%s","weight_kg":10}]'::jsonb, 'weight', NULL, NULL, 'blending', %L::timestamptz, %L::timestamptz, 'day')$q$,
        d, b_a, m_bm, d::timestamp + interval '9 hours', d::timestamp + interval '10 hours'));
    IF v_msg NOT LIKE 'BLEND_RUN_FROM_PLAN_ONLY%' THEN RAISE EXCEPTION 'FIXTURE 259 EXEC: a blending run outside a plan is refused, got %', v_msg; END IF;
    v_msg := pg_temp.f259_do(u_wc, format($q$SELECT execute_blending_plan(%L::uuid, %L::date, %L::timestamptz, %L::timestamptz, 'day',
        '[{"line_id":"%s","actual_kg":310},{"line_id":"%s","actual_kg":190}]'::jsonb, 495)$q$, p1, d, d::timestamp + interval '9 hours', d::timestamp + interval '10 hours', l_a, l_c));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.processing_commit%' THEN RAISE EXCEPTION 'FIXTURE 259 EXEC: executing needs action.processing_commit, got %', v_msg; END IF;
    v_msg := pg_temp.f259_do(u_pc, format($q$SELECT execute_blending_plan(%L::uuid, %L::date, %L::timestamptz, %L::timestamptz, 'day', '[]'::jsonb, 10)$q$,
        p2, d, d::timestamp + interval '9 hours', d::timestamp + interval '10 hours'));
    IF v_msg NOT LIKE 'BLEND_PLAN_NOT_RELEASED|%|draft%' THEN RAISE EXCEPTION 'FIXTURE 259 EXEC: a draft is not executed, got %', v_msg; END IF;
    v_msg := pg_temp.f259_do(u_pc, format($q$SELECT execute_blending_plan(%L::uuid, %L::date, %L::timestamptz, %L::timestamptz, 'day',
        '[{"line_id":"%s","actual_kg":310}]'::jsonb, 300)$q$, p1, d, d::timestamp + interval '9 hours', d::timestamp + interval '10 hours', l_a));
    IF v_msg NOT LIKE 'BLEND_ACTUAL_LINES_MISMATCH|%' THEN RAISE EXCEPTION 'FIXTURE 259 EXEC: every line must say what it actually fed, got %', v_msg; END IF;
    v_j := pg_temp.f259_get(u_pc, format($q$SELECT execute_blending_plan(%L::uuid, %L::date, %L::timestamptz, %L::timestamptz, 'day',
        '[{"line_id":"%s","actual_kg":310},{"line_id":"%s","actual_kg":190}]'::jsonb, 495)$q$, p1, d, d::timestamp + interval '9 hours', d::timestamp + interval '10 hours', l_a, l_c));
    v_run := (v_j ->> 'run_id')::uuid; v_batch := (v_j ->> 'batch_id')::uuid;
    IF (SELECT status FROM blending_plans WHERE id = p1) <> 'executed' OR (SELECT run_id FROM blending_plans WHERE id = p1) <> v_run THEN
        RAISE EXCEPTION 'FIXTURE 259 EXEC: the plan is executed and points at its run'; END IF;
    IF (SELECT operation_type_code || ':' || total_input || ':' || total_output FROM processing_runs WHERE id = v_run) <> 'blending:500:495' THEN
        RAISE EXCEPTION 'FIXTURE 259 EXEC: the run is a blending run, input 500 (310 + 190), output 495, got %',
            (SELECT operation_type_code || ':' || total_input || ':' || total_output FROM processing_runs WHERE id = v_run); END IF;
    IF (SELECT material_id FROM output_batches WHERE id = v_batch) <> m_bm THEN RAISE EXCEPTION 'FIXTURE 259 EXEC: the blended batch is the plan''s output material'; END IF;
    v_j := pg_temp.f259_get(u_pv, format($q$SELECT jsonb_object_agg(batch_code, jsonb_build_object('p', planned_kg, 'a', actual_kg, 'd', difference_kg, 's', run_status)) FROM blending_plan_execution WHERE plan_id = %L$q$, p1));
    IF (v_j #>> '{ZZ259-A,a}')::numeric <> 310 OR (v_j #>> '{ZZ259-A,d}')::numeric <> 10 OR (v_j #>> '{ZZ259-A,p}')::numeric <> 300
       OR (v_j -> (SELECT code FROM output_batches WHERE id = b_c) ->> 'd')::numeric <> -10 OR (v_j #>> '{ZZ259-A,s}') <> 'committed' THEN
        RAISE EXCEPTION 'FIXTURE 259 EXEC: actual differs from plan and the difference is shown (A +10, C −10), got %', v_j; END IF;
    IF EXISTS (SELECT 1 FROM output_batch_metals WHERE output_batch_id = v_batch) THEN
        RAISE EXCEPTION 'FIXTURE 259 EXEC: the blended batch must carry no metal content — never the prediction'; END IF;
    v_msg := pg_temp.f259_do(u_pc, format($q$SELECT execute_blending_plan(%L::uuid, %L::date, %L::timestamptz, %L::timestamptz, 'day',
        '[{"line_id":"%s","actual_kg":1},{"line_id":"%s","actual_kg":1}]'::jsonb, 2)$q$, p1, d, d::timestamp + interval '9 hours', d::timestamp + interval '10 hours', l_a, l_c));
    IF v_msg NOT LIKE 'BLEND_PLAN_NOT_RELEASED|%|executed%' THEN RAISE EXCEPTION 'FIXTURE 259 EXEC: an executed plan is not executed twice, got %', v_msg; END IF;
    v_msg := pg_temp.f259_do(u_wc, format($q$SELECT cancel_blending_plan(%L::uuid, 'too late')$q$, p1));
    IF v_msg NOT LIKE 'BLEND_PLAN_NOT_CANCELLABLE|%|executed%' THEN RAISE EXCEPTION 'FIXTURE 259 EXEC: an executed plan cannot be cancelled, got %', v_msg; END IF;

    -- ══════════════ ASSAY ══════════════
    RAISE NOTICE 'fixture 259 · ASSAY';
    v_msg := pg_temp.f259_do(u_oe, format($q$INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source) VALUES (%L, 'ni', 18.4, 'manual')$q$, v_batch));
    IF v_msg NOT LIKE 'BLEND_CONTENT_FROM_ASSAY_ONLY|%' THEN
        RAISE EXCEPTION 'FIXTURE 259 ASSAY: content typed onto the blended batch is refused — it comes from an assay only, got %', v_msg; END IF;
    -- 对照:一批不是混出来的料,人填一行照旧写得进(守卫只认混出来的那一批)
    v_msg := pg_temp.f259_do(u_oe, format($q$INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source) VALUES (%L, 'li', 1.5, 'manual')$q$, b_c));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 259 ASSAY: the guard must not touch a batch that was not blended, got %', v_msg; END IF;
    DELETE FROM output_batch_metals WHERE output_batch_id = b_c AND metal = 'li';
    v_j := pg_temp.f259_get(u_ov, format($q$SELECT jsonb_object_agg(metal, verdict) FROM blending_plan_outcome WHERE plan_id = %L$q$, p1));
    IF v_j <> '{"ni":"not_assayed","co":"not_assayed","li":"not_assayed"}'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 259 ASSAY: before any assay every target reads not_assayed, got %', v_j; END IF;
    v_j := pg_temp.f259_get(u_all, format($q$SELECT record_assay_result(%L::date, '[{"metal":"ni","content_pct":18.9},{"metal":"co","content_pct":5.3}]'::jsonb,
        p_output_batch_id => %L::uuid, p_weight_basis => 'dry', p_result_party => 'ours')$q$, CURRENT_DATE, v_batch));
    v_assay := (v_j ->> 'assay_result_id')::uuid;
    v_j := pg_temp.f259_get(u_ov, format($q$SELECT jsonb_object_agg(metal, jsonb_build_object('v', verdict, 'c', content_pct, 'a', assay_id)) FROM blending_plan_outcome WHERE plan_id = %L$q$, p1));
    IF (v_j #>> '{ni,v}') <> 'within' OR (v_j #>> '{ni,c}')::numeric <> 18.9 OR (v_j #>> '{co,v}') <> 'above_max'
       OR (v_j #>> '{li,v}') <> 'metal_not_in_assay' OR (v_j #>> '{ni,a}')::uuid <> v_assay THEN
        RAISE EXCEPTION 'FIXTURE 259 ASSAY: the later assay is compared with the bounds (ni within, co above max, li not in the assay), got %', v_j; END IF;
    IF EXISTS (SELECT 1 FROM output_batch_metals WHERE output_batch_id = v_batch) THEN
        RAISE EXCEPTION 'FIXTURE 259 ASSAY: recording an assay does not write the batch''s content (applying it does)'; END IF;
    v_msg := pg_temp.f259_do(u_all, format($q$SELECT apply_output_assay(%L::uuid)$q$, v_assay));
    IF v_msg <> 'OK' OR (SELECT string_agg(metal || ':' || content_pct || ':' || content_source, ',' ORDER BY metal) FROM output_batch_metals WHERE output_batch_id = v_batch) <> 'co:5.3:assay,ni:18.9:assay' THEN
        RAISE EXCEPTION 'FIXTURE 259 ASSAY: applying the assay gives the blended batch its content, from the assay (%)', v_msg; END IF;

    -- ══════════════ READ ══════════════
    RAISE NOTICE 'fixture 259 · READ';
    v_j := pg_temp.f259_get(u_pv, format($q$SELECT jsonb_build_object('rows', count(*), 'visible', count(*) FILTER (WHERE content_pct IS NOT NULL), 'restricted', count(*) FILTER (WHERE content_restricted)) FROM blending_plan_line_metals WHERE plan_id = %L$q$, p1));
    IF (v_j ->> 'rows')::int <> 4 OR (v_j ->> 'visible')::int <> 0 OR (v_j ->> 'restricted')::int <> 4 THEN
        RAISE EXCEPTION 'FIXTURE 259 READ: a reader who cannot view the batches sees their content as restricted, got %', v_j; END IF;
    v_j := pg_temp.f259_get(u_ov, format($q$SELECT jsonb_object_agg(batch_kind || ':' || metal, jsonb_build_object('c', content_pct, 'r', content_restricted, 's', content_source)) FROM blending_plan_line_metals WHERE plan_id = %L$q$, p1));
    IF (v_j #>> '{output:ni,c}')::numeric <> 16 OR (v_j #>> '{output:ni,s}') <> 'assay' OR (v_j -> 'inbound:ni' ->> 'c') IS NOT NULL
       OR NOT (v_j #>> '{inbound:ni,r}')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 259 READ: output view without inbound view — the output line visible, the inbound line restricted, got %', v_j; END IF;
    v_j := pg_temp.f259_get(u_ov, format($q$SELECT jsonb_object_agg(metal, jsonb_build_object('p', predicted_pct, 'f', flag, 'r', content_restricted, 'min', min_pct)) FROM blending_plan_prediction WHERE plan_id = %L$q$, p1));
    IF (v_j -> 'ni' -> 'p') <> 'null'::jsonb OR (v_j -> 'ni' -> 'f') <> 'null'::jsonb OR NOT (v_j #>> '{ni,r}')::boolean OR (v_j #>> '{ni,min}')::numeric <> 18 THEN
        RAISE EXCEPTION 'FIXTURE 259 READ: a prediction built from a batch the reader cannot view is restricted (bounds still shown), got %', v_j; END IF;
    v_j := pg_temp.f259_get(u_pv, format($q$SELECT jsonb_object_agg(metal, jsonb_build_object('v', verdict, 'c', content_pct, 'r', content_restricted)) FROM blending_plan_outcome WHERE plan_id = %L$q$, p1));
    IF (v_j -> 'ni' -> 'v') <> 'null'::jsonb OR (v_j -> 'ni' -> 'c') <> 'null'::jsonb OR NOT (v_j #>> '{ni,r}')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 259 READ: the blended batch''s assay is restricted without output view, got %', v_j; END IF;
    v_n := (pg_temp.f259_get(u_none, $q$SELECT to_jsonb((SELECT count(*) FROM blending_plans) + (SELECT count(*) FROM blending_plan_targets) + (SELECT count(*) FROM blending_plan_lines)
        + (SELECT count(*) FROM blending_plan_prediction) + (SELECT count(*) FROM blending_plan_line_metals) + (SELECT count(*) FROM blending_plan_execution))$q$))::text::bigint;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 259 READ: a reader without processing view reads no plan (got % rows)', v_n; END IF;
    BEGIN
        v_n := (pg_temp.f259_get(u_all, $q$SELECT to_jsonb(count(*)) FROM blending_plan_line_metals_all$q$))::text::bigint;
        RAISE EXCEPTION 'F259_PROBE|read';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%permission denied%' THEN RAISE EXCEPTION 'FIXTURE 259 READ: the base view is not readable by authenticated, got %', SQLERRM; END IF;
    END;

    -- ══════════════ LOG ══════════════
    RAISE NOTICE 'fixture 259 · LOG';
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'FIXTURE 259 LOG: change-log coverage (no gaps, 8 excluded), got %', v_j; END IF;
    IF (SELECT count(DISTINCT table_name) FROM change_log WHERE table_name IN ('blending_plans', 'blending_plan_targets', 'blending_plan_lines')
          AND row_key ->> 'id' IN (SELECT id::text FROM blending_plans UNION ALL SELECT id::text FROM blending_plan_targets UNION ALL SELECT id::text FROM blending_plan_lines)) <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 259 LOG: all three new tables are change-logged'; END IF;
    IF NOT EXISTS (SELECT 1 FROM change_log WHERE table_name = 'blending_plans' AND op = 'UPDATE' AND row_key ->> 'id' = p1::text
                     AND new ->> 'status' = 'released') THEN
        RAISE EXCEPTION 'FIXTURE 259 LOG: the release is in the change log'; END IF;
    IF NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'blending_plan' AND s.view_codes = ARRAY['module.processing.view'] AND s.root_table = 'blending_plans')
       OR (SELECT count(*) FROM trail_subject_members() m WHERE m.subject = 'blending_plan' AND m.home) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 259 LOG: the blending_plan trail subject is registered with its two members'; END IF;
    v_j := pg_temp.f259_get(u_pv, format($q$SELECT jsonb_object_agg(t.table_name, t.n) FROM (SELECT table_name, count(*) AS n FROM record_trail('blending_plan', %L, 500) GROUP BY table_name) t$q$, p1));
    IF (v_j ->> 'blending_plans')::int < 2 OR (v_j ->> 'blending_plan_targets')::int < 3 OR (v_j ->> 'blending_plan_lines')::int < 2 THEN
        RAISE EXCEPTION 'FIXTURE 259 LOG: the plan''s own trail carries the plan, its targets and its lines, got %', v_j; END IF;

    -- ══════════════ ADMIN ══════════════
    RAISE NOTICE 'fixture 259 · ADMIN';
    IF EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                             WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'FIXTURE 259 ADMIN: the bootstrap admin holds every code, module.tasks.view_all included — missing %',
            (SELECT string_agg(p.code, ',') FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                                  WHERE r.code = 'admin' AND rp.permission_code = p.code)); END IF;
    PERFORM pg_temp.f259_as(NULL);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx259-every', 'f', 'f', true) RETURNING id INTO p3;
    v_msg := pg_temp.f259_do(u_all, format($q$SELECT set_role_permissions(%L::uuid, (SELECT array_agg(code) FROM permissions))$q$, p3));
    IF v_msg <> 'OK' OR (SELECT count(*) FROM role_permissions WHERE role_id = p3) <> (SELECT count(*) FROM permissions) THEN
        RAISE EXCEPTION 'FIXTURE 259 ADMIN: every code saves through set_role_permissions (action-implies-view holds), got %', v_msg; END IF;
    v_msg := pg_temp.f259_do(u_all, format($q$SELECT set_role_permissions(%L::uuid, ARRAY['action.manage_devices'])$q$, p3));
    IF v_msg NOT LIKE 'ACTION_REQUIRES_VIEW|%' THEN
        RAISE EXCEPTION 'FIXTURE 259 ADMIN: the action-implies-view check still bites (control), got %', v_msg; END IF;
    v_msg := pg_temp.f259_do(u_all, format($q$SELECT set_role_permissions(%L::uuid, (SELECT array_agg(code) FROM permissions))$q$,
                                           (SELECT id FROM roles WHERE code = 'admin')));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 259 ADMIN: re-saving the admin role with every code passes, got %', v_msg; END IF;

    RAISE NOTICE 'FIXTURE 259 全部通过: PLAN · SALE · TGT · PRED · REL · EXEC · ASSAY · READ · LOG · ADMIN';
END $$;

ROLLBACK;
