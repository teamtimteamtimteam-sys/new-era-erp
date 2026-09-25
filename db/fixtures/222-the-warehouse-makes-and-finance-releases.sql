-- 222 ROLE-1 Batch 3b · 收货建单、工单、加工提交、回滚与注销归仓库;下达归财务,建单人永远不能下达
--     (Tim 2026-09-25,Batch 3 grilling Q1 · Q6–Q9;Batch 3b grilling Q1–Q6)
--
-- 【它钉的是什么】
--   R  收货建单 = action.receive_goods
--      R1 只持 module.inbound.edit(连同两个定价码)的人建不了单 —— 带价也好、现场按单收货也好,
--         拒绝点名的都是 action.receive_goods(Q5:它先问,所以不会点名定价码)
--      R2 仓库不带价建单照成,created_by 是它自己
--      R3 仓库带价建单 → PERMISSION_DENIED|action.price_receipts(建单码过了,定价码没过)
--   W  注销批次 = action.batch_write_off:只持 inbound.edit / output.edit 的人按名拒;仓库注销进料与产出批次
--   O  工单
--      O1 只持 module.processing.edit 的人建不了单 → PERMISSION_DENIED|action.wo_create
--      O2 仓库建单,created_by 是它自己;仓库与 processing.edit 都下达不了 → PERMISSION_DENIED|action.wo_release
--      O3 ★ 建单人持下达码也下达不了 → SELF_APPROVAL_FORBIDDEN|raiser
--      O4 ★★ 按人认:建单人的【另一个账号】持下达码,也下达不了
--      O5 另一个人(财务)下达得了;work_order_history 那一行记的是他
--      O6 改 / 取消 / 关闭 = action.wo_create 或 module.processing.edit;只持下达码的人按名拒 action.wo_create
--      O7 ★ 建单人之外没有真持有人持下达码 → WO_NO_OTHER_RELEASER(别的角色上的下达码全拿掉;一个都不留)
--      O8 ★★ 按人认:唯一剩下的下达人是建单人自己的另一个账号 → 同样 WO_NO_OTHER_RELEASER
--   P  加工
--      P1 只持 processing.edit 的人提交不了 → PERMISSION_DENIED|action.processing_commit
--      P2 仓库照一张已下达的工单提交
--      P3 ★ 直连写一律按名拒 PROCESSING_THROUGH_FUNCTION_ONLY|表|动作:插加工单、把状态改成 reversed、
--         改挂工单、删加工单、插产出、删产出、删投料;同一行改备注照旧放行(UPDATE 策略留着)
--      P4 只持 processing.edit 的人回滚不了 → PERMISSION_DENIED|action.processing_rollback;仓库回滚得了
--      P5 ★ 故障注入:拿掉 processing_runs 上的直连删守卫,持 processing.edit 的人直连删一张加工单
--         就变成【零行、不报错】(DELETE 策略已经没了 —— SILENT-1 那一族)—— 守卫是承重的
--   L  损耗分类与交接班 = action.processing_aftercare 或 module.processing.edit
--      L1 仓库记、改、删损耗分类;只持 processing.view 的人插不进(RLS)、改不了(PERMISSION_DENIED)
--      L2 交接班的门:只持 view 的人 → PERMISSION_DENIED|action.processing_aftercare;仓库过了门(撞的是下一句)
--   M  只持 module.processing.view 的人从 material_lookup 读得到物料名,从 materials 读到 0 行(Q4 · Q8)
--
-- 自带数据(README 第 2 条);锁期与审批开关自己设(README 第 4 条)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';

CREATE FUNCTION pg_temp.f222_try(p_sql text, p_auth boolean DEFAULT false) RETURNS text
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

CREATE FUNCTION pg_temp.f222_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true)
$f$;

DO $$
DECLARE
    u_wh    uuid := gen_random_uuid();   -- 仓库;在册员工 e_wh 的主账号
    u_whfin uuid := gen_random_uuid();   -- ★ e_wh 的另一个账号,持下达码
    u_fin   uuid := gen_random_uuid();   -- 财务:下达
    u_both  uuid := gen_random_uuid();   -- 建单码 + 下达码都持(admin 的形状)
    u_edit  uuid := gen_random_uuid();   -- 旧的宽码:processing / inbound / output 的 edit,外加两个定价码
    u_view  uuid := gen_random_uuid();   -- 只有 module.processing.view
    u_all   uuid := gen_random_uuid();   -- 布景用:每一个码(没有 auth.users 行 —— 不算真持有人)
    r_wh uuid; r_fin uuid; r_whfin uuid; r_both uuid; r_edit uuid; r_view uuid; r_all uuid;
    e_wh uuid := gen_random_uuid();
    v_today date := CURRENT_DATE;
    v_base text;
    v_sup uuid; v_matA uuid; v_matB uuid; b_in uuid; b_wo uuid; b_out uuid; b_new uuid;
    wo1 uuid; wo2 uuid; wo3 uuid; v_run uuid; v_out uuid;
    v_res jsonb; v_msg text; v_n int;
    v_lines jsonb;
    v_trg_def text;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- ── 布景 ──────────────────────────────────────────────────────────────
    INSERT INTO auth.users (id, email_confirmed_at) VALUES
        (u_wh, now()), (u_whfin, now()), (u_fin, now()), (u_both, now()), (u_edit, now()), (u_view, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx222-wh','f','f',true)   RETURNING id INTO r_wh;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx222-fin','f','f',true)  RETURNING id INTO r_fin;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx222-whfin','f','f',true) RETURNING id INTO r_whfin;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx222-both','f','f',true) RETURNING id INTO r_both;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx222-edit','f','f',true) RETURNING id INTO r_edit;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx222-view','f','f',true) RETURNING id INTO r_view;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx222-all','f','f',true)  RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        -- 仓库的形状(与线上 warehouse 本刀之后同形,只取本支用得到的)
        (r_wh, 'action.receive_goods'), (r_wh, 'action.batch_write_off'), (r_wh, 'action.wo_create'),
        (r_wh, 'action.processing_commit'), (r_wh, 'action.processing_rollback'), (r_wh, 'action.processing_aftercare'),
        (r_wh, 'module.processing.view'), (r_wh, 'module.inbound.view'), (r_wh, 'module.inbound.edit'),
        (r_wh, 'module.output.view'), (r_wh, 'module.output.edit'), (r_wh, 'data.view_purchase_prices'),
        (r_fin, 'action.wo_release'), (r_fin, 'module.processing.view'),
        (r_whfin, 'action.wo_release'), (r_whfin, 'module.processing.view'),
        (r_both, 'action.wo_create'), (r_both, 'action.wo_release'), (r_both, 'module.processing.view'),
        (r_edit, 'module.processing.edit'), (r_edit, 'module.processing.view'),
        (r_edit, 'module.inbound.edit'), (r_edit, 'module.inbound.view'),
        (r_edit, 'module.output.edit'), (r_edit, 'module.output.view'),
        (r_edit, 'action.price_receipts'), (r_edit, 'data.view_purchase_prices'),
        (r_view, 'module.processing.view');
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_wh, r_wh), (u_whfin, r_whfin), (u_fin, r_fin), (u_both, r_both), (u_edit, r_edit), (u_view, r_view),
        (u_all, r_all);
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id) VALUES
        (e_wh, 'FX222-WH', 'FX222 Warehouse', 'full_time', 'office', v_today - 400, u_wh);
    INSERT INTO employee_accounts (user_id, employee_id) VALUES (u_whfin, e_wh);

    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE finance_settings SET locked_before = NULL;
    -- 两级审批:每一条链的门都持(否则开关先为别的链变红)—— fixture 221 同一个布景
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx222-l1','f','f',true), ('fx222-l2','f','f',true);
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r.id, p.code FROM roles r CROSS JOIN permissions p WHERE r.code IN ('fx222-l1', 'fx222-l2');
    -- 两级各一个真人(开关要每一级都有真持有人)。他们也持下达码 —— O7 / O8 撤的是【所有】别的下达人,连他们一起。
    WITH u AS (INSERT INTO auth.users (id, email_confirmed_at) VALUES (gen_random_uuid(), now()), (gen_random_uuid(), now()) RETURNING id),
         n AS (SELECT id, row_number() OVER () AS k FROM u)
    INSERT INTO user_roles (user_id, role_id)
    SELECT n.id, r.id FROM n JOIN roles r ON r.code = CASE n.k WHEN 1 THEN 'fx222-l1' ELSE 'fx222-l2' END;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level1_role_code = 'fx222-l1', approval_level2_role_code = 'fx222-l2',
                                approval_threshold_base = 1000;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type) VALUES
        ('ZZFIX222-S', 'fixture 222 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX222-MA', 'fixture 222 raw', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_matA;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX222-MB', 'fixture 222 fine', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_matB;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date,
                                 source_reason_code, source_reason_note) VALUES
        ('ZZFIX222-IBW', v_matA, v_sup, 200, 200, v_today - 1, 'other', 'fixture 222'),
        ('ZZFIX222-IBD', v_matA, v_sup, 10, 10, v_today - 1, 'other', 'fixture 222');
    SELECT id INTO b_wo FROM inbound_batches WHERE code = 'ZZFIX222-IBW';
    SELECT id INTO b_in FROM inbound_batches WHERE code = 'ZZFIX222-IBD';
    -- 投料的批次要一条【可投料】的安全状态(fixture 75 同一个手法)
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT ib.id, 'discharged_verified'
      FROM inbound_batches ib
      JOIN materials m       ON m.id   = ib.material_id
      JOIN material_kinds mk ON mk.code = m.kind_code
     WHERE ib.id = b_wo AND mk.has_condition_axes;
    PERFORM set_config('evoltrya.price_ctx', 'fixture', true);
    UPDATE inbound_batches SET unit_price = 1 WHERE id = b_wo;
    PERFORM set_config('evoltrya.price_ctx', '', true);
    PERFORM pg_temp.f222_as(u_all);
    v_res := to_jsonb(create_output_batch(v_matB, 5, 'kg', v_today, p_notes => 'fixture 222'));
    SELECT id INTO b_out FROM output_batches WHERE material_id = v_matB AND deleted_at IS NULL ORDER BY created_at DESC LIMIT 1;
    v_lines := jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 100));

    -- ══════════ R · 收货建单 ══════════
    PERFORM pg_temp.f222_as(u_edit);
    v_msg := pg_temp.f222_try(format('SELECT create_inbound_batch(%L, %L, 3, %L, %L, %L, NULL, %L, p_source_reason_code => %L, p_source_reason_note => %L)',
                                     v_matA, v_sup, 'kg', v_today, '待加工', 'fixture 222 R1', 'other', 'fixture 222'));
    IF v_msg <> 'PERMISSION_DENIED|action.receive_goods' THEN
        RAISE EXCEPTION 'FIXTURE 222R1 失败:只持 inbound.edit 的人建单应当 PERMISSION_DENIED|action.receive_goods,实得 %', v_msg; END IF;
    v_msg := pg_temp.f222_try(format('SELECT create_inbound_batch(%L, %L, 3, %L, %L, %L, 9, %L, p_source_reason_code => %L, p_source_reason_note => %L, p_currency => %L)',
                                     v_matA, v_sup, 'kg', v_today, '待加工', 'fixture 222 R1', 'other', 'fixture 222', v_base));
    IF v_msg <> 'PERMISSION_DENIED|action.receive_goods' THEN
        RAISE EXCEPTION 'FIXTURE 222R1 失败:持两个定价码、不持建单码的人带价建单应当点名 action.receive_goods(Q5),实得 %', v_msg; END IF;
    v_msg := pg_temp.f222_try(format('SELECT receive_inbound_batch_against_po(%L, %L, 3)', v_matA, v_sup));
    IF v_msg <> 'PERMISSION_DENIED|action.receive_goods' THEN
        RAISE EXCEPTION 'FIXTURE 222R1 失败:现场按单收货应当 PERMISSION_DENIED|action.receive_goods,实得 %', v_msg; END IF;
    PERFORM pg_temp.f222_as(u_wh);
    v_res := create_inbound_batch(v_matA, v_sup, 3, 'kg', v_today, '待加工', NULL, 'fixture 222 R2',
        p_source_reason_code => 'other', p_source_reason_note => 'fixture 222');
    b_new := (v_res->>'batch_id')::uuid;
    IF b_new IS NULL OR (SELECT created_by FROM inbound_batches WHERE id = b_new) IS DISTINCT FROM u_wh THEN
        RAISE EXCEPTION 'FIXTURE 222R2 失败:仓库不带价建单应当照成、建单人是它自己,实得 %', v_res; END IF;
    v_msg := pg_temp.f222_try(format('SELECT create_inbound_batch(%L, %L, 3, %L, %L, %L, 9, %L, p_source_reason_code => %L, p_source_reason_note => %L, p_currency => %L)',
                                     v_matA, v_sup, 'kg', v_today, '待加工', 'fixture 222 R3', 'other', 'fixture 222', v_base));
    IF v_msg <> 'PERMISSION_DENIED|action.price_receipts' THEN
        RAISE EXCEPTION 'FIXTURE 222R3 失败:仓库带价建单应当拒在定价码上,实得 %', v_msg; END IF;

    -- ══════════ W · 注销批次 ══════════
    PERFORM pg_temp.f222_as(u_edit);
    v_msg := pg_temp.f222_try(format('SELECT soft_delete_inbound_batch(%L, %L)', b_new, 'fixture 222 W1'));
    IF v_msg <> 'PERMISSION_DENIED|action.batch_write_off' THEN
        RAISE EXCEPTION 'FIXTURE 222W1 失败:只持 inbound.edit 的人注销进料应当 PERMISSION_DENIED|action.batch_write_off,实得 %', v_msg; END IF;
    v_msg := pg_temp.f222_try(format('SELECT soft_delete_output_batch(%L, %L)', b_out, 'fixture 222 W1'));
    IF v_msg <> 'PERMISSION_DENIED|action.batch_write_off' THEN
        RAISE EXCEPTION 'FIXTURE 222W1 失败:只持 output.edit 的人注销产出应当 PERMISSION_DENIED|action.batch_write_off,实得 %', v_msg; END IF;
    PERFORM pg_temp.f222_as(u_wh);
    PERFORM soft_delete_inbound_batch(b_new, 'fixture 222 W2');
    PERFORM soft_delete_output_batch(b_out, 'fixture 222 W2');
    IF (SELECT deleted_by FROM inbound_batches WHERE id = b_new) IS DISTINCT FROM u_wh
       OR (SELECT deleted_by FROM output_batches WHERE id = b_out) IS DISTINCT FROM u_wh THEN
        RAISE EXCEPTION 'FIXTURE 222W2 失败:仓库注销进料与产出批次应当照成,注销人是它自己'; END IF;

    -- ══════════ O · 工单 ══════════
    PERFORM pg_temp.f222_as(u_edit);
    v_msg := pg_temp.f222_try(format('SELECT create_work_order(%L::jsonb)', v_lines));
    IF v_msg <> 'PERMISSION_DENIED|action.wo_create' THEN
        RAISE EXCEPTION 'FIXTURE 222O1 失败:只持 processing.edit 的人建工单应当 PERMISSION_DENIED|action.wo_create,实得 %', v_msg; END IF;
    PERFORM pg_temp.f222_as(u_wh);
    wo1 := (create_work_order(v_lines, NULL, v_today, 'fixture 222 O2')->>'work_order_id')::uuid;
    IF (SELECT created_by FROM work_orders WHERE id = wo1) IS DISTINCT FROM u_wh THEN
        RAISE EXCEPTION 'FIXTURE 222O2 失败:建单人应当是 auth.uid()'; END IF;
    v_msg := pg_temp.f222_try(format('SELECT release_work_order(%L)', wo1));
    IF v_msg <> 'PERMISSION_DENIED|action.wo_release' THEN
        RAISE EXCEPTION 'FIXTURE 222O2 失败:仓库下达应当 PERMISSION_DENIED|action.wo_release,实得 %', v_msg; END IF;
    PERFORM pg_temp.f222_as(u_edit);
    v_msg := pg_temp.f222_try(format('SELECT release_work_order(%L)', wo1));
    IF v_msg <> 'PERMISSION_DENIED|action.wo_release' THEN
        RAISE EXCEPTION 'FIXTURE 222O2 失败:只持 processing.edit 的人下达应当 PERMISSION_DENIED|action.wo_release,实得 %', v_msg; END IF;
    -- O3 建单人持下达码也下达不了
    PERFORM pg_temp.f222_as(u_both);
    wo2 := (create_work_order(v_lines, NULL, v_today, 'fixture 222 O3')->>'work_order_id')::uuid;
    v_msg := pg_temp.f222_try(format('SELECT release_work_order(%L)', wo2));
    IF v_msg <> 'SELF_APPROVAL_FORBIDDEN|raiser' THEN
        RAISE EXCEPTION 'FIXTURE 222O3 失败:建单人下达自己的工单应当 SELF_APPROVAL_FORBIDDEN|raiser,实得 %', v_msg; END IF;
    -- O4 按人认:同一个人的另一个账号
    PERFORM pg_temp.f222_as(u_whfin);
    v_msg := pg_temp.f222_try(format('SELECT release_work_order(%L)', wo1));
    IF v_msg <> 'SELF_APPROVAL_FORBIDDEN|raiser' THEN
        RAISE EXCEPTION 'FIXTURE 222O4 失败:建单人的另一个账号下达应当 SELF_APPROVAL_FORBIDDEN|raiser,实得 %', v_msg; END IF;
    -- O5 另一个人下达得了
    PERFORM pg_temp.f222_as(u_fin);
    PERFORM release_work_order(wo1);
    IF (SELECT status FROM work_orders WHERE id = wo1) <> 'released'
       OR NOT EXISTS (SELECT 1 FROM work_order_history WHERE work_order_id = wo1 AND change_type = 'released' AND changed_by = u_fin) THEN
        RAISE EXCEPTION 'FIXTURE 222O5 失败:财务下达应当照成,留痕记的是他'; END IF;
    -- O6 改 / 取消 / 关闭
    v_msg := pg_temp.f222_try(format('SELECT amend_work_order(%L, %L, p_notes => %L, p_set_notes => true)', wo1, 'fixture 222 O6', 'x'));
    IF v_msg <> 'PERMISSION_DENIED|action.wo_create' THEN
        RAISE EXCEPTION 'FIXTURE 222O6 失败:只持下达码的人改工单应当 PERMISSION_DENIED|action.wo_create,实得 %', v_msg; END IF;
    PERFORM pg_temp.f222_as(u_edit);
    PERFORM amend_work_order(wo1, 'fixture 222 O6 edit', p_notes => 'by processing.edit', p_set_notes => true);
    PERFORM pg_temp.f222_as(u_wh);
    PERFORM amend_work_order(wo1, 'fixture 222 O6 wh', p_notes => 'by wo_create', p_set_notes => true);
    PERFORM pg_temp.f222_as(u_edit);
    PERFORM cancel_work_order(wo2, 'fixture 222 O6 cancel');
    IF (SELECT status FROM work_orders WHERE id = wo2) <> 'cancelled' THEN
        RAISE EXCEPTION 'FIXTURE 222O6 失败:持 processing.edit 的人取消应当照成'; END IF;
    -- O7 别的下达人全撤掉(子块:成功也抛,撤销随子块回滚)
    PERFORM pg_temp.f222_as(u_both);
    v_msg := NULL;
    BEGIN
        -- 【拿掉码,不撤授权】撤授权会撞 LAST_ADMIN_PROTECTED(持全部码的那几个角色里有管理码)
        DELETE FROM role_permissions WHERE permission_code = 'action.wo_release' AND role_id <> r_both;
        PERFORM create_work_order(v_lines, NULL, v_today, 'fixture 222 O7');
        RAISE EXCEPTION 'F222_UNEXPECTED_OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg <> 'WO_NO_OTHER_RELEASER' THEN
        RAISE EXCEPTION 'FIXTURE 222O7 失败:建单人之外没人下达得了时应当 WO_NO_OTHER_RELEASER,实得 %', v_msg; END IF;
    -- O8 按人认:唯一剩下的下达人是建单人自己的另一个账号
    PERFORM pg_temp.f222_as(u_wh);
    v_msg := NULL;
    BEGIN
        DELETE FROM role_permissions WHERE permission_code = 'action.wo_release' AND role_id <> r_whfin;
        PERFORM create_work_order(v_lines, NULL, v_today, 'fixture 222 O8');
        RAISE EXCEPTION 'F222_UNEXPECTED_OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg <> 'WO_NO_OTHER_RELEASER' THEN
        RAISE EXCEPTION 'FIXTURE 222O8 失败:唯一的下达人是建单人自己的另一个账号时应当 WO_NO_OTHER_RELEASER,实得 %', v_msg; END IF;
    IF (SELECT count(*) FROM user_roles WHERE revoke_reason LIKE 'fixture 222 O%') <> 0
       OR NOT EXISTS (SELECT 1 FROM role_permissions WHERE role_id = r_all AND permission_code = 'action.wo_release') THEN
        RAISE EXCEPTION 'FIXTURE 222O8 失败:子块里拿掉的码与撤销应当随子块回滚'; END IF;

    -- ══════════ P · 加工 ══════════
    PERFORM pg_temp.f222_as(u_edit);
    v_msg := pg_temp.f222_try(format($q$SELECT commit_processing_run(%L, 'f222', 5, %L::jsonb, %L::jsonb, 'weight', %L, NULL, 'manual_disassembly')$q$,
        v_today, jsonb_build_array(jsonb_build_object('inbound_batch_id', b_wo, 'quantity_consumed', 80)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 75)), wo1));
    IF v_msg <> 'PERMISSION_DENIED|action.processing_commit' THEN
        RAISE EXCEPTION 'FIXTURE 222P1 失败:只持 processing.edit 的人提交应当 PERMISSION_DENIED|action.processing_commit,实得 %', v_msg; END IF;
    PERFORM pg_temp.f222_as(u_wh);
    v_run := commit_processing_run(v_today, 'f222', 5,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', b_wo, 'quantity_consumed', 80)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 75)), 'weight',
        wo1, NULL, 'manual_disassembly');
    IF (SELECT work_order_id FROM processing_runs WHERE id = v_run) IS DISTINCT FROM wo1
       OR (SELECT status FROM processing_runs WHERE id = v_run) <> 'committed' THEN
        RAISE EXCEPTION 'FIXTURE 222P2 失败:仓库照已下达的工单提交应当照成'; END IF;
    SELECT output_batch_id INTO v_out FROM processing_outputs WHERE run_id = v_run LIMIT 1;

    -- P3 直连写(持 processing.edit 的人 —— 策略那一层对他是开的,拒他的只能是守卫)
    PERFORM pg_temp.f222_as(u_edit);
    v_msg := pg_temp.f222_try(format($q$INSERT INTO processing_runs (process_date, status, allocation_basis, operation_type_code) VALUES (%L, 'committed', 'weight', 'manual_disassembly')$q$, v_today), true);
    IF v_msg <> 'PROCESSING_THROUGH_FUNCTION_ONLY|processing_runs|insert' THEN
        RAISE EXCEPTION 'FIXTURE 222P3 失败:直连插加工单应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f222_try(format($q$UPDATE processing_runs SET status = 'reversed' WHERE id = %L$q$, v_run), true);
    IF v_msg <> 'PROCESSING_THROUGH_FUNCTION_ONLY|processing_runs|update' THEN
        RAISE EXCEPTION 'FIXTURE 222P3 失败:直连把状态改成 reversed 应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f222_try(format($q$UPDATE processing_runs SET work_order_id = NULL WHERE id = %L$q$, v_run), true);
    IF v_msg <> 'PROCESSING_THROUGH_FUNCTION_ONLY|processing_runs|update' THEN
        RAISE EXCEPTION 'FIXTURE 222P3 失败:直连改挂工单应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f222_try(format($q$UPDATE processing_runs SET notes = 'f222 note' WHERE id = %L$q$, v_run), true);
    IF v_msg <> 'OK' OR (SELECT notes FROM processing_runs WHERE id = v_run) <> 'f222 note' THEN
        RAISE EXCEPTION 'FIXTURE 222P3 失败:同一行改备注应当照旧放行(UPDATE 策略留着),实得 %', v_msg; END IF;
    v_msg := pg_temp.f222_try(format('DELETE FROM processing_runs WHERE id = %L', v_run), true);
    IF v_msg <> 'PROCESSING_THROUGH_FUNCTION_ONLY|processing_runs|delete' THEN
        RAISE EXCEPTION 'FIXTURE 222P3 失败:直连删加工单应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f222_try(format('INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced) VALUES (%L, %L, 1)', v_run, v_out), true);
    IF v_msg <> 'PROCESSING_THROUGH_FUNCTION_ONLY|processing_outputs|insert' THEN
        RAISE EXCEPTION 'FIXTURE 222P3 失败:直连插产出应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f222_try(format('DELETE FROM processing_outputs WHERE run_id = %L', v_run), true);
    IF v_msg <> 'PROCESSING_THROUGH_FUNCTION_ONLY|processing_outputs|delete' THEN
        RAISE EXCEPTION 'FIXTURE 222P3 失败:直连删产出应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f222_try(format('DELETE FROM processing_inputs WHERE run_id = %L', v_run), true);
    IF v_msg <> 'PROCESSING_THROUGH_FUNCTION_ONLY|processing_inputs|delete' THEN
        RAISE EXCEPTION 'FIXTURE 222P3 失败:直连删投料应当按名拒,实得 %', v_msg; END IF;

    -- ══════════ L · 损耗分类与交接班 ══════════
    PERFORM pg_temp.f222_as(u_view);
    v_msg := pg_temp.f222_try(format($q$INSERT INTO processing_run_losses (run_id, loss_category_code, quantity) VALUES (%L, 'moisture', 1)$q$, v_run), true);
    IF v_msg = 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 222L1 失败:只持 view 的人不该插得进损耗分类'; END IF;
    PERFORM pg_temp.f222_as(u_wh);
    v_msg := pg_temp.f222_try(format($q$INSERT INTO processing_run_losses (run_id, loss_category_code, quantity) VALUES (%L, 'moisture', 2)$q$, v_run), true);
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 222L1 失败:仓库(aftercare)记损耗分类应当照成,实得 %', v_msg; END IF;
    PERFORM pg_temp.f222_as(u_view);
    v_msg := pg_temp.f222_try(format('UPDATE processing_run_losses SET quantity = 3 WHERE run_id = %L', v_run), true);
    IF v_msg <> 'PERMISSION_DENIED|module.processing.edit' THEN
        RAISE EXCEPTION 'FIXTURE 222L1 失败:只持 view 的人改损耗应当 PERMISSION_DENIED,实得 %', v_msg; END IF;
    PERFORM pg_temp.f222_as(u_wh);
    v_msg := pg_temp.f222_try(format('UPDATE processing_run_losses SET quantity = 3 WHERE run_id = %L', v_run), true);
    IF v_msg <> 'OK' OR (SELECT quantity FROM processing_run_losses WHERE run_id = v_run) <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 222L1 失败:仓库改损耗应当照成,实得 %', v_msg; END IF;
    v_msg := pg_temp.f222_try(format('DELETE FROM processing_run_losses WHERE run_id = %L', v_run), true);
    IF v_msg <> 'OK' OR EXISTS (SELECT 1 FROM processing_run_losses WHERE run_id = v_run) THEN
        RAISE EXCEPTION 'FIXTURE 222L1 失败:仓库删损耗应当照成,实得 %', v_msg; END IF;
    PERFORM pg_temp.f222_as(u_view);
    v_msg := pg_temp.f222_try(format('SELECT acknowledge_shift_handover(%L)', gen_random_uuid()));
    IF v_msg <> 'PERMISSION_DENIED|action.processing_aftercare' THEN
        RAISE EXCEPTION 'FIXTURE 222L2 失败:只持 view 的人确认交接班应当 PERMISSION_DENIED|action.processing_aftercare,实得 %', v_msg; END IF;
    PERFORM pg_temp.f222_as(u_wh);
    v_msg := pg_temp.f222_try(format('SELECT acknowledge_shift_handover(%L)', gen_random_uuid()));
    IF v_msg NOT LIKE 'HANDOVER_NOT_FOUND|%' THEN
        RAISE EXCEPTION 'FIXTURE 222L2 失败:仓库应当过得了交接班的门(撞在 HANDOVER_NOT_FOUND 上),实得 %', v_msg; END IF;

    -- ══════════ P4 · 回滚 ══════════
    PERFORM pg_temp.f222_as(u_edit);
    v_msg := pg_temp.f222_try(format('SELECT rollback_processing_run(%L, %L)', v_run, 'fixture 222 P4'));
    IF v_msg <> 'PERMISSION_DENIED|action.processing_rollback' THEN
        RAISE EXCEPTION 'FIXTURE 222P4 失败:只持 processing.edit 的人回滚应当 PERMISSION_DENIED|action.processing_rollback,实得 %', v_msg; END IF;
    PERFORM pg_temp.f222_as(u_wh);
    PERFORM rollback_processing_run(v_run, 'fixture 222 P4');
    IF (SELECT status FROM processing_runs WHERE id = v_run) <> 'reversed' THEN
        RAISE EXCEPTION 'FIXTURE 222P4 失败:仓库回滚应当照成'; END IF;
    PERFORM close_work_order(wo1, 'fixture 222 close');
    IF (SELECT status FROM work_orders WHERE id = wo1) <> 'closed' THEN
        RAISE EXCEPTION 'FIXTURE 222O6 失败:仓库(wo_create)关闭工单应当照成'; END IF;

    -- ══════════ M · 查名视图 ══════════
    PERFORM pg_temp.f222_as(u_view);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM material_lookup WHERE id IN (v_matA, v_matB);
    EXECUTE 'RESET ROLE';
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 222M 失败:只持 processing.view 的人应当从 material_lookup 读到 2 个物料名,实得 %', v_n; END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM materials WHERE id IN (v_matA, v_matB);
    EXECUTE 'RESET ROLE';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 222M 失败:只持 processing.view 的人从 materials 表应当读到 0 行(Q8),实得 %', v_n; END IF;

    -- ══════════ P5 · 故障注入:拿掉直连删守卫 → 零行、不报错 ══════════
    PERFORM set_config('request.jwt.claims', '', true);
    DROP TRIGGER trg_processing_runs_direct_delete ON processing_runs;
    PERFORM pg_temp.f222_as(u_edit);
    v_msg := pg_temp.f222_try(format('DELETE FROM processing_runs WHERE id = %L', v_run), true);
    IF v_msg <> 'OK' OR NOT EXISTS (SELECT 1 FROM processing_runs WHERE id = v_run) THEN
        RAISE EXCEPTION 'FIXTURE 222P5 失败:拿掉守卫后直连删应当是【零行、不报错】(证明守卫承重),实得 %', v_msg; END IF;

    RAISE NOTICE 'FIXTURE 222 全部通过:R1–R3 · W1–W2 · O1–O8 · P1–P5 · L1–L2 · M';
END;
$$;

ROLLBACK;
