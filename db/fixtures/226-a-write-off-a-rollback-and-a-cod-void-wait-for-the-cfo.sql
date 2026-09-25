-- 226 APR-7:注销批次、加工回滚、作废销毁证书 —— 仓库提,CFO 批每一张,批准之前什么都不发生(2026-09-25)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(APR-7 grilling Q1–Q9,Tim 2026-09-25 全部接受)
--   A  引擎登记:名册只有二级一行,门 = module.finance.view + data.view_prices;operations_now 有
--        warehouse_request_pending;内层算子 authenticated 调不到;旧门:回滚与作废一张都不做
--        (WAREHOUSE_NEEDS_APPROVED_REQUEST),一步删还有料的批次同样按名拒
--   B  ★★ 提一张注销申请(没计价、还有料):submitted;批次原样、流水一条没多;留痕 submitted、二级、
--        金额 0;在途清单那一支 blocks_disable、fixed_level = 2、主角 NULL;看板有它
--   C  ★★ 冻结(Q3):那一批上任何流水按名拒 WAREHOUSE_REQUEST_FREEZES_BATCH;同一批第二张 → WAREHOUSE_REQUEST_OPEN
--   D  谁批不了:提单人(仓库)→ PERMISSION_DENIED(批的门);一级 → APPROVAL_NOT_AUTHORISED|2;
--        驳回不给理由 → WAREHOUSE_REQUEST_REJECT_REASON_REQUIRED
--   E  ★★ 提单人之外没人批得动:CFO 那个人的另一个账号提 → WAREHOUSE_REQUEST_NO_OTHER_DECIDER,一行不落
--   F  ★★ CFO 批准:那一批注销,deleted_by = 提单人(Q6)、理由原样;writeoff 流水落在批准日;没计价 → 没有分录
--   G  ★★ 产出批注销(有单位成本):试跑金额 = 剩余 × 单位成本;批准过 借 5200 / 贷 1220,同一个数
--   H  ★★ 回滚(Q3 · Q5):snapshot 点名会被作废的证书;产出批冻结;碰到同一批 / 同一张证书的申请 →
--        WAREHOUSE_REQUEST_OPEN;批准:加工单 reversed、deleted_by = 提单人、投料还原、证书作废且没有替代品
--   I  ★★ 证书作废:在等的时候公开核验仍然说 issued;批准之后 void,voided_by = 提单人,没有替代品
--   J  撤回:既不是提单人、又不持那个码 → PERMISSION_DENIED;另一个仓库撤得了;撤回不写留痕;冻结解开
--   K  驳回:要理由;驳回之后什么都没发生,留痕 rejected
--   L  提交就拒(Q1 · Q4):还欠着供应商钱 INBOUND_HAS_OPEN_PAYABLE;空批 WAREHOUSE_REQUEST_NOT_NEEDED(空批照旧一步删)
--   M  审批关着:生下来 approved、当场生效、留痕 auto_approved
--   N  ★ 故障注入:摘掉 trg_inventory_movements_warehouse_request_freeze,冻结的那一批上的流水就进得去 ——
--        冻结是那支守卫给的,不是别的什么碰巧挡住的
--
-- 自带数据(README 第 2 条);锁期与审批开关自己设(README 第 4 条)。
-- 加工与签发在打开审批之前做完(那是布景,不是被测的东西)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';

CREATE FUNCTION pg_temp.f226_try(p_sql text, p_auth boolean DEFAULT false) RETURNS text
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

CREATE FUNCTION pg_temp.f226_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true)
$f$;

DO $$
DECLARE
    u_all   uuid := gen_random_uuid();   -- 布景:持全部码,只用来加工与签发
    u_wh    uuid := gen_random_uuid();   -- 仓库 —— 提单人
    u_wh2   uuid := gen_random_uuid();   -- 另一个仓库(撤回那一臂)
    u_cfo   uuid := gen_random_uuid();   -- 二级:CFO 的形状;在册员工 e_cfo 的主账号
    u_cfo2  uuid := gen_random_uuid();   -- ★ e_cfo 的另一个账号,持仓库角色 —— "同一个人提的"那一臂
    u_l1    uuid := gen_random_uuid();   -- 一级
    u_ops   uuid := gen_random_uuid();   -- 一个仓库码都不持
    r_all uuid; r_wh uuid; r_l1 uuid; r_l2 uuid; r_ops uuid;
    e_cfo uuid := gen_random_uuid();
    mat uuid; sup uuid;
    b_un uuid; b_px uuid; b_empty uuid; b_d1 uuid; b_d2 uuid; b_frz uuid;
    run_r uuid; run_c uuid; ob_r uuid; ob_c uuid;
    cod1 uuid; cod2 uuid; v_tok uuid;
    q uuid; q2 uuid; v_res jsonb; v_msg text; v_n int; v_mv0 int; v_je0 int; v_log0 int; v_code text;
    d date := CURRENT_DATE;
BEGIN
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;

    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email_confirmed_at) VALUES
        (u_all, now()), (u_wh, now()), (u_wh2, now()), (u_cfo, now()), (u_cfo2, now()), (u_l1, now()), (u_ops, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx226-all','f','f',true) RETURNING id INTO r_all;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx226-wh','f','f',true)  RETURNING id INTO r_wh;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx226-l1','f','f',true)  RETURNING id INTO r_l1;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx226-l2','f','f',true)  RETURNING id INTO r_l2;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx226-ops','f','f',true) RETURNING id INTO r_ops;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        -- 仓库:三个提单的码 + 看得见库存;【不】持 data.view_prices
        (r_wh, 'action.batch_write_off'), (r_wh, 'action.processing_rollback'), (r_wh, 'action.issue_cod'),
        (r_wh, 'module.inventory.view'), (r_wh, 'module.inbound.view'),
        -- 一级:审批开得了(每条分档链的门它都持)—— 批不了仓库申请只能因为【级别】
        (r_l1, 'module.purchasing.view'), (r_l1, 'data.view_prices'), (r_l1, 'data.view_purchase_prices'),
        (r_l1, 'module.finance.view'), (r_l1, 'module.hr.view'), (r_l1, 'data.view_pay'), (r_l1, 'module.inbound.view'),
        -- 二级:CFO 的形状 —— 读得到、看得见,一个仓库码都没有
        (r_l2, 'module.purchasing.view'), (r_l2, 'data.view_prices'), (r_l2, 'data.view_purchase_prices'),
        (r_l2, 'module.finance.view'), (r_l2, 'module.hr.view'), (r_l2, 'data.view_pay'), (r_l2, 'module.inbound.view'),
        (r_l2, 'module.sales.view'), (r_l2, 'module.inventory.view'),
        (r_ops, 'module.inventory.view');
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_all, r_all), (u_wh, r_wh), (u_wh2, r_wh), (u_cfo, r_l2), (u_cfo2, r_wh), (u_l1, r_l1), (u_ops, r_ops);
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id)
    VALUES (e_cfo, 'FX226-CFO', 'FX226 CFO', 'full_time', 'office', d - 400, u_cfo);
    INSERT INTO employee_accounts (user_id, employee_id) VALUES (u_cfo2, e_cfo);

    -- 公司抬头与执照(签发的前提;fixture 195 同形)
    IF NOT EXISTS (SELECT 1 FROM company_profile) THEN
        INSERT INTO company_profile (legal_name, registration_no, address_lines, city, postal_code, country)
        VALUES ('Fixture 226 Recovery Pte. Ltd.', 'FX226-UEN', '1 Fixture Road', 'Singapore', '000000', 'Singapore');
    ELSIF NOT EXISTS (SELECT 1 FROM company_profile WHERE btrim(COALESCE(legal_name, '')) <> '') THEN
        UPDATE company_profile SET legal_name = 'Fixture 226 Recovery Pte. Ltd.',
               registration_no = COALESCE(registration_no, 'FX226-UEN'),
               address_lines = COALESCE(address_lines, '1 Fixture Road'),
               city = COALESCE(city, 'Singapore'), country = COALESCE(country, 'Singapore');
    END IF;
    INSERT INTO company_compliance (cert_type_code, cert_no, issuing_body, status, valid_from, valid_until)
    VALUES ('gwdf', 'FX226-GWDF', 'NEA', 'active', d - 400, d + 365);

    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('FX226-M', 'fixture 226 material', 'battery_material', true, 'black_mass', 'end_of_life')
    RETURNING id INTO mat;
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FX226-S', 'Fixture 226 Battery Recycle Co.', 'SG', 'goods_supplier')
    RETURNING id INTO sup;

    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, source_reason_code, source_reason_note)
    VALUES ('FX226-UN',    mat, sup, 30,  'kg', 30,  d - 20, 'other', 'fixture 226'),
           ('FX226-FRZ',   mat, sup, 40,  'kg', 40,  d - 20, 'other', 'fixture 226'),
           ('FX226-EMPTY', mat, sup, 10,  'kg', 10,  d - 20, 'other', 'fixture 226'),
           ('FX226-D1',    mat, sup, 100, 'kg', 100, d - 20, 'other', 'fixture 226'),
           ('FX226-D2',    mat, sup, 100, 'kg', 100, d - 20, 'other', 'fixture 226');
    SELECT id INTO b_un    FROM inbound_batches WHERE code = 'FX226-UN';
    SELECT id INTO b_frz   FROM inbound_batches WHERE code = 'FX226-FRZ';
    SELECT id INTO b_empty FROM inbound_batches WHERE code = 'FX226-EMPTY';
    SELECT id INTO b_d1    FROM inbound_batches WHERE code = 'FX226-D1';
    SELECT id INTO b_d2    FROM inbound_batches WHERE code = 'FX226-D2';
    -- 空批:一条盘点调整清零(没有证书)
    INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date, created_by)
    VALUES (b_empty, 'adjustment', -10, d - 5, u_all);
    UPDATE inbound_batches SET remaining_qty = 0 WHERE id = b_empty;
    -- 计价、还欠着供应商钱的一批(L 臂):单价在建的那一刻给(应付之锚)
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty, unit_price,
                                 arrival_date, source_reason_code, source_reason_note)
    VALUES ('FX226-PX', mat, sup, 50, 'kg', 50, 10, d - 20, 'other', 'fixture 226')
    RETURNING id INTO b_px;

    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT id, 'discharged_verified' FROM inbound_batches WHERE code LIKE 'FX226-%';

    -- 两张真加工单(真路径):各自整批吃掉一票货 → 各成立一张证书;签发它们
    PERFORM pg_temp.f226_as(u_all);
    run_r := commit_processing_run(d - 3, 'fixture 226 rollback run', 20,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', b_d1, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', mat, 'quantity', 80)),
        'weight', NULL, NULL, 'manual_disassembly');
    run_c := commit_processing_run(d - 3, 'fixture 226 cod run', 20,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', b_d2, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', mat, 'quantity', 80)),
        'weight', NULL, NULL, 'manual_disassembly');
    SELECT output_batch_id INTO ob_r FROM processing_outputs WHERE run_id = run_r;
    SELECT output_batch_id INTO ob_c FROM processing_outputs WHERE run_id = run_c;
    -- G 臂的产出批要有一个单位成本(注销按它计价;这里直接写,被测的不是分摊)
    UPDATE processing_outputs SET unit_cost_base = 2.5 WHERE run_id = run_c;
    SELECT id INTO cod1 FROM certificates_of_destruction WHERE inbound_batch_id = b_d1 AND status = 'pending';
    SELECT id INTO cod2 FROM certificates_of_destruction WHERE inbound_batch_id = b_d2 AND status = 'pending';
    IF cod1 IS NULL OR cod2 IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 226 前提失败:两票整批加工完的货应当各成立一张证书'; END IF;
    PERFORM issue_cod(cod1);
    PERFORM issue_cod(cod2);

    -- 策略:一级 fx226-l1、二级 fx226-l2;审批打开
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level1_role_code = 'fx226-l1', approval_level2_role_code = 'fx226-l2',
                                approval_threshold_base = 1000;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;

    -- ══════════════ A · 引擎登记与关上的门 ══════════════
    IF (SELECT array_agg(level::int ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'warehouse_request')
         IS DISTINCT FROM ARRAY[2]
       OR (SELECT gate_permissions FROM approval_chain_gates() WHERE subject_type = 'warehouse_request')
         IS DISTINCT FROM ARRAY['module.finance.view', 'data.view_prices']::text[] THEN
        RAISE EXCEPTION 'FIXTURE 226A1 失败:warehouse_request 的名册应当只有二级一行,门 = finance.view + view_prices'; END IF;
    IF position('warehouse_request_pending' IN pg_get_viewdef('public.operations_now'::regclass)) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 226A2 失败:operations_now 没有 warehouse_request_pending 那一支'; END IF;
    SELECT string_agg(s, ', ') INTO v_msg FROM unnest(ARRAY[
        'public.soft_delete_inbound_batch_internal(uuid, text, uuid)',
        'public.soft_delete_output_batch_internal(uuid, text, uuid)',
        'public.rollback_processing_run_internal(uuid, text, uuid)',
        'public.warehouse_request_submit_internal(text, uuid, text)',
        'public.warehouse_request_execute_internal(uuid)', 'public.warehouse_request_dry_run(uuid)',
        'public.void_cod_internal(uuid, text, uuid, uuid)']) s
     WHERE has_function_privilege('authenticated', s::regprocedure, 'EXECUTE');
    IF v_msg IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 226A3 失败:authenticated 仍调得到 %', v_msg; END IF;
    PERFORM pg_temp.f226_as(u_wh);
    v_msg := pg_temp.f226_try(format('SELECT rollback_processing_run(%L, %L)', run_r, 'f226 A4'));
    IF v_msg <> 'WAREHOUSE_NEEDS_APPROVED_REQUEST|rollback|' || (SELECT code FROM processing_runs WHERE id = run_r) THEN
        RAISE EXCEPTION 'FIXTURE 226A4 失败:一步回滚应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f226_try(format('SELECT void_cod(%L, %L)', cod1, 'f226 A5'));
    IF v_msg NOT LIKE 'WAREHOUSE_NEEDS_APPROVED_REQUEST|cod_void|COD-%' THEN
        RAISE EXCEPTION 'FIXTURE 226A5 失败:一步作废应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f226_try(format('SELECT soft_delete_inbound_batch(%L, %L)', b_un, 'f226 A6'));
    IF v_msg <> 'WAREHOUSE_NEEDS_APPROVED_REQUEST|write_off_inbound|FX226-UN' THEN
        RAISE EXCEPTION 'FIXTURE 226A6 失败:一步注销还有料的进料批应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f226_try(format('SELECT soft_delete_inbound_batch(%L, %L)', b_d1, 'f226 A7'));
    IF v_msg <> 'WAREHOUSE_NEEDS_APPROVED_REQUEST|write_off_inbound|FX226-D1' THEN
        RAISE EXCEPTION 'FIXTURE 226A7 失败:空批但挂着已签发证书,一步注销应当按名拒(Q1),实得 %', v_msg; END IF;
    IF (SELECT status FROM processing_runs WHERE id = run_r) <> 'committed'
       OR (SELECT status FROM certificates_of_destruction WHERE id = cod1) <> 'issued' THEN
        RAISE EXCEPTION 'FIXTURE 226A 失败:被拒的旧门动了东西'; END IF;

    -- ══════════════ B · 提一张注销申请 ══════════════
    SELECT count(*) INTO v_mv0 FROM inventory_movements;
    SELECT count(*) INTO v_je0 FROM journal_entries;
    PERFORM pg_temp.f226_as(u_wh);
    v_res := submit_inbound_write_off_request(b_un, '  受潮结块,整票报废  ');
    q := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'submitted' OR (v_res->>'amount_base')::numeric <> 0
       OR v_res->>'label' <> 'FX226-UN · write-off #1' THEN
        RAISE EXCEPTION 'FIXTURE 226B1 失败:提交应当 submitted、金额 0、label FX226-UN · write-off #1,实得 %', v_res; END IF;
    IF (SELECT deleted_at FROM inbound_batches WHERE id = b_un) IS NOT NULL
       OR (SELECT remaining_qty FROM inbound_batches WHERE id = b_un) <> 30
       OR (SELECT count(*) FROM inventory_movements) <> v_mv0
       OR (SELECT count(*) FROM journal_entries) <> v_je0 THEN
        RAISE EXCEPTION 'FIXTURE 226B2 失败:提交就动了批次、流水或分录 —— 批准之前什么都不许发生'; END IF;
    IF (SELECT reason FROM warehouse_requests WHERE id = q) <> '受潮结块,整票报废'
       OR (SELECT created_by FROM warehouse_requests WHERE id = q) <> u_wh
       OR (SELECT snapshot->>'batch_code' FROM warehouse_requests WHERE id = q) <> 'FX226-UN' THEN
        RAISE EXCEPTION 'FIXTURE 226B3 失败:申请行的理由 / 提单人 / snapshot 不对'; END IF;
    IF NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'warehouse_request' AND subject_id = q
                    AND decision = 'submitted' AND level = 2 AND amount_base = 0) THEN
        RAISE EXCEPTION 'FIXTURE 226B4 失败:没有 submitted、二级、金额 0 的留痕'; END IF;
    IF NOT EXISTS (SELECT 1 FROM approval_pending_documents() p
                    WHERE p.subject_type = 'warehouse_request' AND p.doc_id = q AND p.blocks_disable
                      AND p.fixed_level = 2 AND p.subject_employee_id IS NULL AND p.raiser_user_id = u_wh) THEN
        RAISE EXCEPTION 'FIXTURE 226B5 失败:在途清单那一支应当 blocks_disable、fixed_level 2、主角 NULL'; END IF;
    -- 看板那一格给 module.finance.view 的读者(CFO);仓库读不到它(它要的是自己那一块,在库存页)
    IF EXISTS (SELECT 1 FROM operations_now WHERE item_type = 'warehouse_request_pending' AND item_id = q) THEN
        RAISE EXCEPTION 'FIXTURE 226B6 失败:仓库不该在看板上看到等 CFO 批的那一格'; END IF;
    PERFORM pg_temp.f226_as(u_cfo);
    IF NOT EXISTS (SELECT 1 FROM operations_now WHERE item_type = 'warehouse_request_pending' AND item_id = q) THEN
        RAISE EXCEPTION 'FIXTURE 226B6 失败:CFO 的看板没有这张在等的申请'; END IF;
    PERFORM pg_temp.f226_as(u_wh);
    -- 仓库读得到自己的申请,金额给 NULL(不持 data.view_prices);CFO 读得到金额
    IF (SELECT amount_base FROM warehouse_requests_visible() WHERE id = q) IS NOT NULL
       OR NOT (SELECT raised_by_me FROM warehouse_requests_visible() WHERE id = q) THEN
        RAISE EXCEPTION 'FIXTURE 226B7 失败:仓库读自己的申请,金额应当是 NULL、raised_by_me = true'; END IF;
    PERFORM pg_temp.f226_as(u_cfo);
    IF (SELECT amount_base FROM warehouse_requests_visible() WHERE id = q) IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'FIXTURE 226B8 失败:CFO 读得到金额'; END IF;

    -- ══════════════ C · 冻结 ══════════════
    v_msg := pg_temp.f226_try(format(
        'INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date) VALUES (%L, %L, -1, %L)',
        b_un, 'adjustment', d));
    IF v_msg <> 'WAREHOUSE_REQUEST_FREEZES_BATCH|FX226-UN|FX226-UN · write-off #1' THEN
        RAISE EXCEPTION 'FIXTURE 226C1 失败:冻结的那一批上的流水应当按名拒,实得 %', v_msg; END IF;
    PERFORM pg_temp.f226_as(u_wh2);
    v_msg := pg_temp.f226_try(format('SELECT submit_inbound_write_off_request(%L, %L)', b_un, 'f226 C2'));
    IF v_msg <> 'WAREHOUSE_REQUEST_OPEN|FX226-UN|FX226-UN · write-off #1' THEN
        RAISE EXCEPTION 'FIXTURE 226C2 失败:同一批第二张申请应当 WAREHOUSE_REQUEST_OPEN,实得 %', v_msg; END IF;

    -- ══════════════ D · 谁批不了 ══════════════
    PERFORM pg_temp.f226_as(u_wh);
    -- 提单人(仓库)连批的门都没有 —— 门码先拒;"同一个人的另一个账号"那一条腿由 E 臂钉
    v_msg := pg_temp.f226_try(format('SELECT decide_warehouse_request(%L, true)', q));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|%' THEN
        RAISE EXCEPTION 'FIXTURE 226D1 失败:提单人没有批的门,应当 PERMISSION_DENIED,实得 %', v_msg; END IF;
    PERFORM pg_temp.f226_as(u_l1);
    v_msg := pg_temp.f226_try(format('SELECT decide_warehouse_request(%L, true)', q));
    IF v_msg NOT LIKE 'APPROVAL_NOT_AUTHORISED|2|%' THEN
        RAISE EXCEPTION 'FIXTURE 226D2 失败:一级批二级的单应当 APPROVAL_NOT_AUTHORISED|2,实得 %', v_msg; END IF;
    PERFORM pg_temp.f226_as(u_cfo);
    v_msg := pg_temp.f226_try(format('SELECT decide_warehouse_request(%L, false, %L)', q, '   '));
    IF v_msg <> 'WAREHOUSE_REQUEST_REJECT_REASON_REQUIRED|FX226-UN · write-off #1' THEN
        RAISE EXCEPTION 'FIXTURE 226D3 失败:驳回不给理由应当按名拒,实得 %', v_msg; END IF;

    -- ══════════════ E · 提单人之外没人批得动 ══════════════
    PERFORM pg_temp.f226_as(u_cfo2);
    v_msg := pg_temp.f226_try(format('SELECT submit_inbound_write_off_request(%L, %L)', b_frz, 'f226 E'));
    IF v_msg <> 'WAREHOUSE_REQUEST_NO_OTHER_DECIDER|FX226-FRZ · write-off #1' THEN
        RAISE EXCEPTION 'FIXTURE 226E1 失败:CFO 那个人的另一个账号提,应当 WAREHOUSE_REQUEST_NO_OTHER_DECIDER,实得 %', v_msg; END IF;
    IF EXISTS (SELECT 1 FROM warehouse_requests WHERE inbound_batch_id = b_frz) THEN
        RAISE EXCEPTION 'FIXTURE 226E2 失败:被拒的提交留下了一行'; END IF;
    -- 提单人自己(按人认):同一个人的另一个账号批不了
    PERFORM pg_temp.f226_as(u_wh);
    v_res := submit_inbound_write_off_request(b_frz, 'f226 E3');
    q2 := (v_res->>'request_id')::uuid;
    PERFORM pg_temp.f226_as(u_cfo);

    -- ══════════════ F · CFO 批准那一张注销 ══════════════
    SELECT count(*) INTO v_log0 FROM approval_log WHERE subject_type = 'warehouse_request' AND subject_id = q;
    v_res := decide_warehouse_request(q, true, 'f226 F 同意');
    IF v_res->>'status' <> 'approved' THEN RAISE EXCEPTION 'FIXTURE 226F1 失败:%', v_res; END IF;
    IF (SELECT deleted_at FROM inbound_batches WHERE id = b_un) IS NULL
       OR (SELECT deleted_by FROM inbound_batches WHERE id = b_un) <> u_wh
       OR (SELECT delete_reason FROM inbound_batches WHERE id = b_un) <> '受潮结块,整票报废'
       OR (SELECT remaining_qty FROM inbound_batches WHERE id = b_un) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 226F2 失败:批准之后那一批应当注销,deleted_by = 提单人,理由原样'; END IF;
    IF NOT EXISTS (SELECT 1 FROM inventory_movements WHERE inbound_batch_id = b_un AND movement_type = 'writeoff'
                    AND qty_delta = -30 AND business_date = d) THEN
        RAISE EXCEPTION 'FIXTURE 226F3 失败:没有落在批准日的 writeoff 流水'; END IF;
    IF (SELECT count(*) FROM journal_entries) <> v_je0 THEN
        RAISE EXCEPTION 'FIXTURE 226F4 失败:没计价的批次注销不该过分录'; END IF;
    IF (SELECT status FROM warehouse_requests WHERE id = q) <> 'approved'
       OR (SELECT decided_by FROM warehouse_requests WHERE id = q) <> u_cfo
       OR (SELECT executed_at FROM warehouse_requests WHERE id = q) IS NULL
       OR NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'warehouse_request' AND subject_id = q
                       AND decision = 'approved' AND level = 2 AND actor_user_id = u_cfo AND self_decided = false) THEN
        RAISE EXCEPTION 'FIXTURE 226F5 失败:申请行 / 留痕不对'; END IF;
    -- 冻结随之解开(那一批已经没了,但另一张 —— E3 那一张 —— 还冻着 FX226-FRZ)
    v_msg := pg_temp.f226_try(format(
        'INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date) VALUES (%L, %L, -1, %L)',
        b_frz, 'adjustment', d));
    IF v_msg NOT LIKE 'WAREHOUSE_REQUEST_FREEZES_BATCH|FX226-FRZ|%' THEN
        RAISE EXCEPTION 'FIXTURE 226F6 失败:另一张在等的申请仍然冻着它那一批,实得 %', v_msg; END IF;

    -- ══════════════ K · 驳回 ══════════════
    v_res := decide_warehouse_request(q2, false, 'f226 K:这票货还能用');
    IF (SELECT status FROM warehouse_requests WHERE id = q2) <> 'rejected'
       OR (SELECT deleted_at FROM inbound_batches WHERE id = b_frz) IS NOT NULL
       OR NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'warehouse_request' AND subject_id = q2
                       AND decision = 'rejected') THEN
        RAISE EXCEPTION 'FIXTURE 226K 失败:驳回之后应当 rejected、批次原样、留痕 rejected'; END IF;

    -- ══════════════ G · 产出批注销,有单位成本 ══════════════
    PERFORM pg_temp.f226_as(u_wh);
    v_res := submit_output_write_off_request(ob_c, 'f226 G:产出批被水浸');
    q := (v_res->>'request_id')::uuid;
    IF (v_res->>'amount_base')::numeric <> 200.00 THEN   -- 80 × 2.5
        RAISE EXCEPTION 'FIXTURE 226G1 失败:试跑金额应当 200.00(80 × 2.5),实得 %', v_res->>'amount_base'; END IF;
    PERFORM pg_temp.f226_as(u_cfo);
    v_res := decide_warehouse_request(q, true);
    IF (SELECT count(*) FROM journal_entries) <> v_je0 + 1
       OR (SELECT cardinality(result_entry_ids) FROM warehouse_requests WHERE id = q) <> 1
       OR (SELECT amount_base FROM warehouse_requests WHERE id = q) <> 200.00 THEN
        RAISE EXCEPTION 'FIXTURE 226G2 失败:批准应当过一张 200.00 的分录并记在申请上'; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM journal_lines l JOIN accounts a ON a.id = l.account_id
         WHERE l.entry_id = (SELECT result_entry_ids[1] FROM warehouse_requests WHERE id = q)
           AND a.code = '5200' AND l.debit = 200.00)
       OR NOT EXISTS (
        SELECT 1 FROM journal_lines l JOIN accounts a ON a.id = l.account_id
         WHERE l.entry_id = (SELECT result_entry_ids[1] FROM warehouse_requests WHERE id = q)
           AND a.code = '1220' AND l.credit = 200.00) THEN
        RAISE EXCEPTION 'FIXTURE 226G3 失败:分录应当是 借 5200 / 贷 1220 各 200.00'; END IF;
    IF (SELECT deleted_by FROM output_batches WHERE id = ob_c) <> u_wh THEN
        RAISE EXCEPTION 'FIXTURE 226G4 失败:产出批的 deleted_by 应当是提单人'; END IF;

    -- ══════════════ I · 证书作废 ══════════════
    SELECT verification_token INTO v_tok FROM certificates_of_destruction WHERE id = cod2;
    PERFORM pg_temp.f226_as(u_wh);
    v_res := submit_cod_void_request(cod2, 'f226 I:供应商名称录错了');
    q := (v_res->>'request_id')::uuid;
    IF (cod_verification(v_tok::text))->>'status' <> 'issued' THEN
        RAISE EXCEPTION 'FIXTURE 226I1 失败:作废在等的时候,公开核验应当仍然说 issued'; END IF;
    PERFORM pg_temp.f226_as(u_cfo);
    PERFORM decide_warehouse_request(q, true);
    IF (SELECT status FROM certificates_of_destruction WHERE id = cod2) <> 'void'
       OR (SELECT voided_by FROM certificates_of_destruction WHERE id = cod2) <> u_wh
       OR (SELECT void_reason FROM certificates_of_destruction WHERE id = cod2) <> 'f226 I:供应商名称录错了'
       OR (SELECT replaced_by_cod_id FROM certificates_of_destruction WHERE id = cod2) IS NOT NULL
       OR (cod_verification(v_tok::text))->>'status' <> 'void' THEN
        RAISE EXCEPTION 'FIXTURE 226I2 失败:批准之后证书应当 void、voided_by = 提单人、没有替代品,核验说 void'; END IF;

    -- ══════════════ H · 回滚 ══════════════
    SELECT code INTO v_code FROM certificates_of_destruction WHERE id = cod1;
    PERFORM pg_temp.f226_as(u_wh);
    v_res := submit_rollback_request(run_r, 'f226 H:投料批次搞混了');
    q := (v_res->>'request_id')::uuid;
    IF (SELECT snapshot->'cods_voided' FROM warehouse_requests WHERE id = q) <> jsonb_build_array(v_code) THEN
        RAISE EXCEPTION 'FIXTURE 226H1 失败:snapshot 应当点名会被作废的证书 %', v_code; END IF;
    v_msg := pg_temp.f226_try(format(
        'INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date) VALUES (%L, %L, -1, %L)',
        ob_r, 'adjustment', d));
    IF v_msg NOT LIKE 'WAREHOUSE_REQUEST_FREEZES_BATCH|%' THEN
        RAISE EXCEPTION 'FIXTURE 226H2 失败:回滚在等的时候,它的产出批应当冻结,实得 %', v_msg; END IF;
    PERFORM pg_temp.f226_as(u_wh2);
    v_msg := pg_temp.f226_try(format('SELECT submit_output_write_off_request(%L, %L)', ob_r, 'f226 H3'));
    IF v_msg NOT LIKE 'WAREHOUSE_REQUEST_OPEN|%' THEN
        RAISE EXCEPTION 'FIXTURE 226H3 失败:回滚的产出批上再提注销应当 WAREHOUSE_REQUEST_OPEN,实得 %', v_msg; END IF;
    v_msg := pg_temp.f226_try(format('SELECT submit_cod_void_request(%L, %L)', cod1, 'f226 H4'));
    IF v_msg NOT LIKE 'WAREHOUSE_REQUEST_OPEN|%' THEN
        RAISE EXCEPTION 'FIXTURE 226H4 失败:回滚会作废的证书上再提作废应当 WAREHOUSE_REQUEST_OPEN(Q3 跨种类),实得 %', v_msg; END IF;
    PERFORM pg_temp.f226_as(u_cfo);
    PERFORM decide_warehouse_request(q, true);
    IF (SELECT status FROM processing_runs WHERE id = run_r) <> 'reversed'
       OR (SELECT deleted_by FROM processing_runs WHERE id = run_r) <> u_wh
       OR (SELECT remaining_qty FROM inbound_batches WHERE id = b_d1) <> 100
       OR (SELECT deleted_at FROM output_batches WHERE id = ob_r) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 226H5 失败:批准之后加工单应当 reversed(deleted_by = 提单人)、投料还原、产出注销'; END IF;
    IF (SELECT status FROM certificates_of_destruction WHERE id = cod1) <> 'void'
       OR (SELECT replaced_by_cod_id FROM certificates_of_destruction WHERE id = cod1) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 226H6 失败:回滚之后那张证书应当作废,没有替代品'; END IF;

    -- ══════════════ J · 撤回 ══════════════
    PERFORM pg_temp.f226_as(u_wh);
    v_res := submit_inbound_write_off_request(b_frz, 'f226 J');
    q := (v_res->>'request_id')::uuid;
    SELECT count(*) INTO v_log0 FROM approval_log WHERE subject_type = 'warehouse_request' AND subject_id = q;
    PERFORM pg_temp.f226_as(u_ops);
    v_msg := pg_temp.f226_try(format('SELECT withdraw_warehouse_request(%L)', q));
    IF v_msg <> 'PERMISSION_DENIED|action.batch_write_off' THEN
        RAISE EXCEPTION 'FIXTURE 226J1 失败:既不是提单人、又不持码的人撤回应当 PERMISSION_DENIED,实得 %', v_msg; END IF;
    PERFORM pg_temp.f226_as(u_wh2);
    PERFORM withdraw_warehouse_request(q, 'f226 J:先不报废');
    IF (SELECT status FROM warehouse_requests WHERE id = q) <> 'withdrawn'
       OR (SELECT count(*) FROM approval_log WHERE subject_type = 'warehouse_request' AND subject_id = q) <> v_log0 THEN
        RAISE EXCEPTION 'FIXTURE 226J2 失败:另一个仓库撤得了,撤回不写留痕'; END IF;
    PERFORM pg_temp.f226_as(u_all);
    -- 一对 +1 / −1 的盘点调整(净零,台账恒等式不受影响):冻结解开了,就进得去
    v_msg := pg_temp.f226_try(format(
        'INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date) VALUES (%L, %L, 1, %L)',
        b_frz, 'adjustment', d));
    IF v_msg = 'OK' THEN
        v_msg := pg_temp.f226_try(format(
            'INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date) VALUES (%L, %L, -1, %L)',
            b_frz, 'adjustment', d));
    END IF;
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 226J3 失败:撤回之后冻结应当解开,实得 %', v_msg; END IF;

    -- ══════════════ L · 提交就拒 ══════════════
    PERFORM pg_temp.f226_as(u_wh);
    v_msg := pg_temp.f226_try(format('SELECT submit_inbound_write_off_request(%L, %L)', b_px, 'f226 L1'));
    IF v_msg NOT LIKE 'INBOUND_HAS_OPEN_PAYABLE|FX226-PX|%' THEN
        RAISE EXCEPTION 'FIXTURE 226L1 失败:还欠着供应商钱的批次提交就应当拒(Q4),实得 %', v_msg; END IF;
    v_msg := pg_temp.f226_try(format('SELECT submit_inbound_write_off_request(%L, %L)', b_empty, 'f226 L2'));
    IF v_msg <> 'WAREHOUSE_REQUEST_NOT_NEEDED|FX226-EMPTY' THEN
        RAISE EXCEPTION 'FIXTURE 226L2 失败:空批不经申请,应当 WAREHOUSE_REQUEST_NOT_NEEDED,实得 %', v_msg; END IF;
    v_msg := pg_temp.f226_try(format('SELECT submit_inbound_write_off_request(%L, %L)', b_px, '   '));
    IF v_msg <> 'WAREHOUSE_REQUEST_REASON_REQUIRED|write_off_inbound|FX226-PX' THEN
        RAISE EXCEPTION 'FIXTURE 226L3 失败:空理由应当按名拒,实得 %', v_msg; END IF;
    IF EXISTS (SELECT 1 FROM warehouse_requests WHERE inbound_batch_id IN (b_px, b_empty)) THEN
        RAISE EXCEPTION 'FIXTURE 226L4 失败:被拒的提交留下了行'; END IF;
    PERFORM soft_delete_inbound_batch(b_empty, 'f226 L5:空批一步删');
    IF (SELECT deleted_by FROM inbound_batches WHERE id = b_empty) <> u_wh THEN
        RAISE EXCEPTION 'FIXTURE 226L5 失败:空批照旧由仓库一步删'; END IF;

    -- ══════════════ N · 故障注入:冻结是那支守卫给的 ══════════════
    PERFORM pg_temp.f226_as(u_wh);
    v_res := submit_inbound_write_off_request(b_frz, 'f226 N');
    q := (v_res->>'request_id')::uuid;
    BEGIN
        EXECUTE 'DROP TRIGGER trg_inventory_movements_warehouse_request_freeze ON public.inventory_movements';
        INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date)
        VALUES (b_frz, 'adjustment', -1, d);
        RAISE EXCEPTION 'F226N_UNDO';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg <> 'F226N_UNDO' THEN
        RAISE EXCEPTION 'FIXTURE 226N 失败:摘掉冻结守卫之后流水应当进得去(然后被撤销),实得 %', v_msg; END IF;
    v_msg := pg_temp.f226_try(format(
        'INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date) VALUES (%L, %L, -1, %L)',
        b_frz, 'adjustment', d));
    IF v_msg NOT LIKE 'WAREHOUSE_REQUEST_FREEZES_BATCH|%' THEN
        RAISE EXCEPTION 'FIXTURE 226N2 失败:守卫应当回来了,实得 %', v_msg; END IF;
    PERFORM withdraw_warehouse_request(q);

    -- ══════════════ M · 审批关着:生下来 approved ══════════════
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;
    PERFORM pg_temp.f226_as(u_wh);
    v_res := submit_inbound_write_off_request(b_frz, 'f226 M:审批关着');
    q := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'approved'
       OR (SELECT deleted_by FROM inbound_batches WHERE id = b_frz) <> u_wh
       OR NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'warehouse_request' AND subject_id = q
                       AND decision = 'auto_approved') THEN
        RAISE EXCEPTION 'FIXTURE 226M 失败:审批关着时应当生下来 approved、当场注销、留痕 auto_approved,实得 %', v_res; END IF;

    RAISE NOTICE 'FIXTURE 226 全部通过:引擎登记与旧门(A)· 提交不动任何东西(B)· 冻结与一张在等(C)· 谁批不了(D)· 没有别的决定人(E)· 批准即注销、deleted_by = 提单人(F)· 产出批 200.00 借 5200 / 贷 1220(G)· 回滚作废证书、没有替代品(H)· 证书作废与公开核验(I)· 撤回(J)· 驳回(K)· 提交就拒(L)· 审批关着(M)· 故障注入(N)';
END;
$$;

ROLLBACK;
