-- 248 U1-B:工作流上的几扇门与剩下的几处泄漏(UNBLOCK-1 Q15 · Q20 · Q25 · Step 0 §3 3.6 / 5.1 · U1-A close-out 三件;v1.4.36)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】一臂一条裁定;每一臂都有一格故障注入(db/scripts/2026-10-05-u1b-fixture-injections.py)必须让它红。
--   DT  停机(Q15):持加工编辑权的人【更正】一段停机(起止与原因,直连 UPDATE),变更记录留着旧值;【作废】要理由、只经函数;
--       作废之后那一行冻住、不挡重叠、不算开着的那一段、交接单不能引用它;直连改作废三列被拒;
--       【任何人都删不掉】—— authenticated 与属主两种身份都按名拒 DOWNTIME_NEVER_DELETED
--   PO  采购单关闭 / 重开(Q25):理由进 close_reason / reopen_reason(人与时刻也进它们自己的列),notes 一个字不动;
--       修改史各记一行 closed / reopened,理由在 amend_reason
--   DD  深度放电判断(Q20):只持 module.purchasing.edit 的人(不是开单人、不持品类码)写得进一行;取消了的单按名拒;
--       回到空按名拒;不持码按名拒;变更记录记下那一次
--   CL  报销单的另一位决定人(Step 0 §3 3.6):审批开着、提单人与主角之外没人批得动 → EXPENSE_CLAIM_NO_OTHER_DECIDER,一张不落;
--       提单人那条腿(CL1)与主角那条腿(CL2)各一格;多一个能批的人就照开(CL3);Tim 的 R2 例外照算(CL4:唯一的二级持有人
--       替自己报的单,他可以决定自己的报销,所以不拒)
--   LV  九支请假函数(U1A-SELF-GATE-NULL-TRAP):一个没有员工档案、不持 module.hr.view 的账号,九支都按名拒
--   JR  工资分录的冲销申请(U1A-PAYROLL-REVERSAL-REQUEST-SHOWS-AMOUNT):不持 data.view_pay 的财务读者 —— 基表那一列 42501、
--       遮蔽视图里金额 NULL 且 amount_restricted、审批留痕的金额 NULL、变更记录的规则答"看不见";持码的人全看得见;
--       一张非工资分录的冲销申请对两人一样
--   MC  医疗报销的批准理由(Tim 对医疗报销费用单的裁定):不持 data.view_health 的读者 —— decision_notes 基表 42501、遮蔽视图 NULL、
--       审批留痕的 note NULL(基表 42501)、规则答"看不见"、自批报表里金额与说明 NULL;本人与持码的人看得见
--   ME  月结(Step 0 §3 5.1):processing_runs_blocking_close 数的就是 close_period 拒的那一句(已提交 · 未分摊 · 未删 · 不晚于月末),
--       一个不持加工码的财务读者读到同一个数;不持财务读码的人按名拒;close_period 调的就是它
--
-- 自带数据(README 第 2 条);审批开关与级别自己设(第 4 条)。
-- 以 postgres 跑(绕过 RLS)—— 每一次读都切成 authenticated + 那个人的 JWT(fixture 26 的教训)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '240s';

CREATE FUNCTION pg_temp.f248_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

-- 以某人的身份跑一句;成功回 'OK',失败回错误原文(SQLSTATE 42501 回 '42501')
CREATE FUNCTION pg_temp.f248_try(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f248_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN CASE WHEN SQLSTATE = '42501' AND SQLERRM NOT LIKE 'PERMISSION_DENIED%' THEN '42501' ELSE SQLERRM END;
END;
$f$;

-- 以某人的身份读一个 jsonb;读不出来就抛,带着臂名 —— 一次失败不许被读成 0 或 NULL
CREATE FUNCTION pg_temp.f248_read(p_arm text, p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f248_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RAISE EXCEPTION 'FIXTURE 248 %: the read failed: % — %', p_arm, SQLSTATE, SQLERRM;
END;
$f$;

DO $$
DECLARE
    u_proc uuid := gen_random_uuid();   -- 加工编辑(记 / 改 / 作废停机)
    u_view uuid := gen_random_uuid();   -- 只看加工
    u_pur  uuid := gen_random_uuid();   -- 只持 module.purchasing.edit + view(不是开单人、不持品类码)—— cto 的形状
    u_wh   uuid := gen_random_uuid();   -- 开单人:耗材品类码
    u_cto  uuid := gen_random_uuid();   -- finance.view + hr.view,不持 view_pay / view_health
    u_pay  uuid := gen_random_uuid();   -- finance.view + hr.view + view_pay + view_health
    u_fin  uuid := gen_random_uuid();   -- finance.view,不持任何加工码(月结那一臂)
    u_none uuid := gen_random_uuid();   -- 一个码都没有,也没有员工档案(请假那一臂)
    u_emp  uuid := gen_random_uuid();   -- 普通员工:医疗报销的主角,一个码都没有
    u_sub  uuid := gen_random_uuid();   -- 一级与二级审批角色唯一的持有人(员工 e_sub)
    u_l2b  uuid := gen_random_uuid();   -- 后来才授一级的人(员工 e_l2b)
    u_sa   uuid := gen_random_uuid();   -- 读自批报表的人:data.view_self_approvals,不持 view_health
    u_keep uuid := gen_random_uuid();   -- 一个站着不动的系统角色持有人 —— 撤授权时 guard_last_admin 要看见"还有一个"(重建库里一个真持有人都没有)
    r_proc uuid; r_view uuid; r_pur uuid; r_wh uuid; r_cto uuid; r_pay uuid; r_fin uuid; r_sub uuid; r_l1 uuid; r_l2 uuid; r_sa uuid;
    e_emp uuid := gen_random_uuid(); e_sub uuid := gen_random_uuid(); e_l2b uuid := gen_random_uuid();
    v_base text; v_msg text; v_n int; v_j jsonb; v_t text; v_x numeric;
    fa uuid; dt1 uuid; dt2 uuid; dt3 uuid; v_ho uuid;
    v_sup uuid; m_cons uuid; po uuid; po_x uuid; ln uuid; ln_x uuid; v_log bigint;
    je_pay uuid; je_man uuid; jr_pay uuid; jr_man uuid; ap_jr uuid;
    mc uuid; ap_mc uuid;
    v_end date := (date_trunc('month', CURRENT_DATE) - interval '1 day')::date;
    f text;
BEGIN
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;
    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES
        (u_proc, 'fx248-proc@test.local', now(), now()), (u_view, 'fx248-view@test.local', now(), now()),
        (u_pur, 'fx248-pur@test.local', now(), now()), (u_wh, 'fx248-wh@test.local', now(), now()),
        (u_cto, 'fx248-cto@test.local', now(), now()), (u_pay, 'fx248-pay@test.local', now(), now()),
        (u_fin, 'fx248-fin@test.local', now(), now()), (u_none, 'fx248-none@test.local', now(), now()),
        (u_emp, 'fx248-emp@test.local', now(), now()), (u_sub, 'fx248-sub@test.local', now(), now()),
        (u_l2b, 'fx248-l2b@test.local', now(), now()), (u_sa, 'fx248-sa@test.local', now(), now()),
        (u_keep, 'fx248-keep@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx248-proc', 'f', 'f', true) RETURNING id INTO r_proc;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx248-view', 'f', 'f', true) RETURNING id INTO r_view;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx248-pur', 'f', 'f', true) RETURNING id INTO r_pur;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx248-wh', 'f', 'f', true) RETURNING id INTO r_wh;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx248-cto', 'f', 'f', true) RETURNING id INTO r_cto;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx248-pay', 'f', 'f', true) RETURNING id INTO r_pay;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx248-fin', 'f', 'f', true) RETURNING id INTO r_fin;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx248-sub', 'f', 'f', true) RETURNING id INTO r_sub;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx248-l1', 'f', 'f', true) RETURNING id INTO r_l1;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx248-l2', 'f', 'f', true) RETURNING id INTO r_l2;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx248-sa', 'f', 'f', true) RETURNING id INTO r_sa;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_proc, 'module.processing.edit'), (r_proc, 'module.processing.view'), (r_proc, 'module.finance.view'),
        (r_view, 'module.processing.view'),
        (r_pur, 'module.purchasing.view'), (r_pur, 'module.purchasing.edit'), (r_pur, 'data.view_purchase_prices'),
        (r_wh, 'module.purchasing.view'), (r_wh, 'data.view_purchase_prices'), (r_wh, 'action.raise_po_consumables'),
        (r_cto, 'module.finance.view'), (r_cto, 'module.hr.view'),
        (r_pay, 'module.finance.view'), (r_pay, 'module.hr.view'), (r_pay, 'data.view_pay'), (r_pay, 'data.view_health'),
        (r_fin, 'module.finance.view'),
        (r_sub, 'module.finance.view'),
        (r_sa, 'data.view_self_approvals');
    -- 一级与二级:每一条链的门都持(审批才开得了 —— guard_approvals_switch);二级多出条款链与评估的几个码(fixture 229 的同一组)
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r.id, c FROM unnest(ARRAY[r_l1, r_l2]) r(id)
     CROSS JOIN unnest(ARRAY['module.purchasing.view', 'data.view_prices', 'data.view_purchase_prices',
        'module.finance.view', 'module.hr.view', 'data.view_pay', 'module.inbound.view', 'module.sales.view']) c;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_l2, c FROM unnest(ARRAY['module.pricing.view', 'module.suppliers.view', 'module.customers.view',
        'action.approve_review', 'action.finance_reopen']) c;
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_proc, r_proc), (u_view, r_view), (u_pur, r_pur), (u_wh, r_wh), (u_cto, r_cto), (u_pay, r_pay), (u_fin, r_fin),
        (u_sub, r_sub), (u_sub, r_l1), (u_sub, r_l2), (u_sa, r_sa);
    INSERT INTO user_roles (user_id, role_id)
    SELECT u_keep, r.id FROM roles r WHERE r.is_system AND r.is_active AND r.deleted_at IS NULL ORDER BY r.code LIMIT 1;
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id, employment_status) VALUES
        (e_emp, 'FX248-EMP', 'FX248 Employee', 'full_time', 'office', CURRENT_DATE - 400, u_emp, 'active'),
        (e_sub, 'FX248-SUB', 'FX248 Submitter', 'full_time', 'office', CURRENT_DATE - 400, u_sub, 'active'),
        (e_l2b, 'FX248-L2B', 'FX248 Second approver', 'full_time', 'office', CURRENT_DATE - 400, u_l2b, 'active');

    -- 审批开起来:一级 fx248-l1、二级 fx248-l2、门槛 1,000(本位币)
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level1_role_code = 'fx248-l1', approval_level2_role_code = 'fx248-l2',
                                approval_threshold_base = 1000;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;

    -- ══════════════ DT · 停机:更正、作废、永远不删 ══════════════
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_ccy, currency, fx_rate, cost_base,
                              useful_life_months, residual_base)
    VALUES ('FX248-A1', 'fixture 248 feeder', 'equipment', CURRENT_DATE - 60, 0, v_base, 1, 0, 60, 0) RETURNING id INTO fa;
    PERFORM pg_temp.f248_as(u_proc);
    INSERT INTO equipment_downtime (equipment_id, started_at, ended_at, reason)
    VALUES (fa, now() - interval '10 days', now() - interval '9 days', 'FX248 belt snapped') RETURNING id INTO dt1;
    INSERT INTO equipment_downtime (equipment_id, started_at, ended_at, reason)
    VALUES (fa, now() - interval '5 days', NULL, 'FX248 entered on the wrong machine') RETURNING id INTO dt2;
    PERFORM set_config('request.jwt.claims', '', true);
    SELECT max(seq) INTO v_log FROM change_log;

    -- DT1 更正:持加工编辑权的人直连改起止与原因;变更记录留着旧值
    v_msg := pg_temp.f248_try(u_proc, format(
        'UPDATE equipment_downtime SET started_at = now() - interval ''10 days 1 hour'', ended_at = now() - interval ''9 days 2 hours'', reason = ''FX248 belt snapped on the feeder'' WHERE id = %L', dt1));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 248 DT1: a processing editor could not correct a downtime period: %', v_msg; END IF;
    IF (SELECT reason FROM equipment_downtime WHERE id = dt1) <> 'FX248 belt snapped on the feeder' THEN
        RAISE EXCEPTION 'FIXTURE 248 DT1: the correction did not land'; END IF;
    IF NOT EXISTS (SELECT 1 FROM change_log c WHERE c.seq > v_log AND c.table_name = 'equipment_downtime' AND c.op = 'UPDATE'
                      AND c.old ->> 'reason' = 'FX248 belt snapped' AND c.new ->> 'reason' = 'FX248 belt snapped on the feeder') THEN
        RAISE EXCEPTION 'FIXTURE 248 DT1: the change log does not keep the old reason beside the new one'; END IF;

    -- DT2 作废:要理由;只看加工的人不行;直连改作废三列不行;经函数可以
    v_msg := pg_temp.f248_try(u_proc, format('SELECT void_equipment_downtime(%L, %L)', dt2, '  '));
    IF v_msg NOT LIKE 'DOWNTIME_VOID_REASON_REQUIRED%' THEN
        RAISE EXCEPTION 'FIXTURE 248 DT2: a void with no reason should be refused by name, got %', v_msg; END IF;
    v_msg := pg_temp.f248_try(u_view, format('SELECT void_equipment_downtime(%L, %L)', dt2, 'x'));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.processing.edit%' THEN
        RAISE EXCEPTION 'FIXTURE 248 DT2: a processing viewer voided a downtime period: %', v_msg; END IF;
    v_msg := pg_temp.f248_try(u_proc, format(
        'UPDATE equipment_downtime SET voided_at = now(), voided_by = auth.uid(), void_reason = ''direct'' WHERE id = %L', dt2));
    IF v_msg NOT LIKE 'DOWNTIME_VOID_THROUGH_FUNCTION_ONLY%' THEN
        RAISE EXCEPTION 'FIXTURE 248 DT2: a direct write voided a downtime period: %', v_msg; END IF;
    v_msg := pg_temp.f248_try(u_proc, format('SELECT void_equipment_downtime(%L, %L)', dt2, 'FX248 never happened'));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 248 DT2: the void through the function failed: %', v_msg; END IF;
    IF (SELECT void_reason FROM equipment_downtime WHERE id = dt2) IS DISTINCT FROM 'FX248 never happened'
       OR (SELECT voided_by FROM equipment_downtime WHERE id = dt2) IS DISTINCT FROM u_proc THEN
        RAISE EXCEPTION 'FIXTURE 248 DT2: the void did not record its reason and its author'; END IF;

    -- DT3 作废之后:冻住;不挡重叠、不算开着的那一段(同一段时间再开一段照开);交接单不能引用它
    v_msg := pg_temp.f248_try(u_proc, format('UPDATE equipment_downtime SET reason = ''again'' WHERE id = %L', dt2));
    IF v_msg NOT LIKE 'DOWNTIME_VOIDED%' THEN
        RAISE EXCEPTION 'FIXTURE 248 DT3: a voided period was changed afterwards: %', v_msg; END IF;
    v_msg := pg_temp.f248_try(u_proc, format('SELECT void_equipment_downtime(%L, %L)', dt2, 'twice'));
    IF v_msg NOT LIKE 'DOWNTIME_ALREADY_VOIDED%' THEN
        RAISE EXCEPTION 'FIXTURE 248 DT3: a second void should be refused by name, got %', v_msg; END IF;
    v_msg := pg_temp.f248_try(u_proc, format(
        'INSERT INTO equipment_downtime (equipment_id, started_at, reason) VALUES (%L, now() - interval ''5 days'', ''FX248 the real one'')', fa));
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 248 DT3: the voided open period still blocks a new one: %', v_msg; END IF;
    SELECT id INTO dt3 FROM equipment_downtime WHERE equipment_id = fa AND reason = 'FX248 the real one';
    -- 交接单不能引用一段作废了的停机(必填条目先放下 —— 这一臂问的是停机那一句,不是条目;随事务回滚)
    UPDATE handover_item_types SET is_required = false;
    v_msg := pg_temp.f248_try(u_proc, format(
        'SELECT submit_shift_handover((SELECT code FROM shifts WHERE is_active ORDER BY code LIMIT 1), CURRENT_DATE, %L, %L, NULL, NULL, ARRAY[%L]::uuid[])',
        e_emp, e_sub, dt2));
    IF v_msg NOT LIKE 'HANDOVER_DOWNTIME_VOIDED%' THEN
        RAISE EXCEPTION 'FIXTURE 248 DT3: a handover took a voided downtime period: %', v_msg; END IF;
    v_msg := pg_temp.f248_try(u_proc, format(
        'SELECT submit_shift_handover((SELECT code FROM shifts WHERE is_active ORDER BY code LIMIT 1), CURRENT_DATE, %L, %L, NULL, NULL, ARRAY[%L]::uuid[])',
        e_emp, e_sub, dt3));
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 248 DT3: a handover could not reference a live downtime period: %', v_msg; END IF;

    -- DT4 永远不删:持加工编辑权的人、以及属主身份,两种都按名拒
    v_msg := pg_temp.f248_try(u_proc, format('DELETE FROM equipment_downtime WHERE id = %L', dt1));
    IF v_msg NOT LIKE 'DOWNTIME_NEVER_DELETED%' THEN
        RAISE EXCEPTION 'FIXTURE 248 DT4: an authenticated delete of a downtime period did not refuse: %', v_msg; END IF;
    BEGIN
        DELETE FROM equipment_downtime WHERE id = dt1;
        RAISE EXCEPTION 'FIXTURE 248 DT4: the owner hard-deleted a downtime period';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'DOWNTIME_NEVER_DELETED%' THEN RAISE; END IF;
    END;
    IF (SELECT count(*) FROM equipment_downtime WHERE equipment_id = fa) <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 248 DT4: expected 3 downtime rows on the asset, found %', (SELECT count(*) FROM equipment_downtime WHERE equipment_id = fa); END IF;

    -- ══════════════ PO · 关闭 / 重开的理由在它们自己的列里 ══════════════
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type)
    VALUES ('active', 'FX248-S', 'fixture 248 supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed)
    VALUES ('FX248-CONS', 'fixture 248 gloves', 'consumable', false) RETURNING id INTO m_cons;
    PERFORM pg_temp.f248_as(u_wh);
    po := (create_purchase_order(v_sup, CURRENT_DATE, NULL, v_base, NULL, NULL, NULL, 'FX248 deliver to bay 2',
        jsonb_build_array(jsonb_build_object('material_id', m_cons, 'quantity', 5, 'unit', 'box', 'estimated_unit_price', 10)),
        p_category => 'consumables')->>'purchase_order_id')::uuid;
    po_x := (create_purchase_order(v_sup, CURRENT_DATE, NULL, v_base, NULL, NULL, NULL, NULL,
        jsonb_build_array(jsonb_build_object('material_id', m_cons, 'quantity', 2, 'unit', 'box', 'estimated_unit_price', 10)),
        p_category => 'consumables')->>'purchase_order_id')::uuid;
    PERFORM set_config('request.jwt.claims', '', true);
    IF po IS NULL OR po_x IS NULL THEN RAISE EXCEPTION 'FIXTURE 248 PO setup: create_purchase_order returned no id'; END IF;
    v_t := (SELECT notes FROM purchase_orders WHERE id = po);
    SELECT count(*) INTO v_n FROM purchase_order_history WHERE purchase_order_id = po AND change_type = 'header_update';

    v_msg := pg_temp.f248_try(u_wh, format('SELECT close_purchase_order(%L, %L)', po, 'FX248 supplier cannot deliver the rest'));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 248 PO1: the raiser could not close: %', v_msg; END IF;
    IF (SELECT close_reason FROM purchase_orders WHERE id = po) IS DISTINCT FROM 'FX248 supplier cannot deliver the rest'
       OR (SELECT closed_by FROM purchase_orders WHERE id = po) IS DISTINCT FROM u_wh THEN
        RAISE EXCEPTION 'FIXTURE 248 PO1: the close reason and who closed are not in their own columns'; END IF;
    IF (SELECT notes FROM purchase_orders WHERE id = po) IS DISTINCT FROM v_t THEN
        RAISE EXCEPTION 'FIXTURE 248 PO1: closing rewrote the notes: %', (SELECT notes FROM purchase_orders WHERE id = po); END IF;
    IF NOT EXISTS (SELECT 1 FROM purchase_order_history WHERE purchase_order_id = po AND change_type = 'closed'
                      AND amend_reason = 'FX248 supplier cannot deliver the rest')
       OR (SELECT count(*) FROM purchase_order_history WHERE purchase_order_id = po AND change_type = 'header_update') <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 248 PO1: the history should carry one closed row with its reason and no reasonless header_update'; END IF;

    v_msg := pg_temp.f248_try(u_wh, format('SELECT reopen_purchase_order(%L, %L)', po, 'FX248 supplier found the stock'));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 248 PO2: the raiser could not reopen: %', v_msg; END IF;
    IF (SELECT reopen_reason FROM purchase_orders WHERE id = po) IS DISTINCT FROM 'FX248 supplier found the stock'
       OR (SELECT reopened_by FROM purchase_orders WHERE id = po) IS DISTINCT FROM u_wh
       OR (SELECT reopened_at FROM purchase_orders WHERE id = po) IS NULL
       OR (SELECT close_reason FROM purchase_orders WHERE id = po) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 248 PO2: the reopen reason, who and when are not in their own columns'; END IF;
    IF (SELECT notes FROM purchase_orders WHERE id = po) IS DISTINCT FROM v_t THEN
        RAISE EXCEPTION 'FIXTURE 248 PO2: reopening rewrote the notes'; END IF;
    IF NOT EXISTS (SELECT 1 FROM purchase_order_history WHERE purchase_order_id = po AND change_type = 'reopened'
                      AND amend_reason = 'FX248 supplier found the stock') THEN
        RAISE EXCEPTION 'FIXTURE 248 PO2: the history should carry one reopened row with its reason'; END IF;

    -- ══════════════ DD · 深度放电判断 ══════════════
    SELECT id INTO ln FROM purchase_order_lines WHERE purchase_order_id = po;
    SELECT id INTO ln_x FROM purchase_order_lines WHERE purchase_order_id = po_x;
    SELECT max(seq) INTO v_log FROM change_log;
    v_msg := pg_temp.f248_try(u_pur, format('SELECT set_po_line_deep_discharge(%L, %L)', ln, 'cannot'));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 248 DD1: a purchasing editor could not record the judgement: %', v_msg; END IF;
    IF (SELECT deep_discharge_judgement_code FROM purchase_order_lines WHERE id = ln) IS DISTINCT FROM 'cannot' THEN
        RAISE EXCEPTION 'FIXTURE 248 DD1: the judgement did not land'; END IF;
    IF NOT EXISTS (SELECT 1 FROM change_log c WHERE c.seq > v_log AND c.table_name = 'purchase_order_lines'
                      AND c.new ->> 'deep_discharge_judgement_code' = 'cannot') THEN
        RAISE EXCEPTION 'FIXTURE 248 DD1: the change log did not record the judgement'; END IF;
    v_msg := pg_temp.f248_try(u_pur, format('SELECT set_po_line_deep_discharge(%L, NULL)', ln));
    IF v_msg NOT LIKE 'DEEP_DISCHARGE_JUDGEMENT_REQUIRED%' THEN
        RAISE EXCEPTION 'FIXTURE 248 DD2: going back to empty should be refused by name, got %', v_msg; END IF;
    v_msg := pg_temp.f248_try(u_pur, format('SELECT set_po_line_deep_discharge(%L, %L)', ln, 'maybe'));
    IF v_msg NOT LIKE 'DEEP_DISCHARGE_JUDGEMENT_UNKNOWN%' THEN
        RAISE EXCEPTION 'FIXTURE 248 DD2: an unknown code should be refused by name, got %', v_msg; END IF;
    v_msg := pg_temp.f248_try(u_cto, format('SELECT set_po_line_deep_discharge(%L, %L)', ln, 'can'));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.purchasing.edit%' THEN
        RAISE EXCEPTION 'FIXTURE 248 DD2: a reader without purchasing edit recorded a judgement: %', v_msg; END IF;
    v_msg := pg_temp.f248_try(u_wh, format('SELECT cancel_purchase_order(%L, %L)', po_x, 'FX248 cancel'));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 248 DD3 setup: could not cancel the second order: %', v_msg; END IF;
    v_msg := pg_temp.f248_try(u_pur, format('SELECT set_po_line_deep_discharge(%L, %L)', ln_x, 'can'));
    IF v_msg NOT LIKE 'PO_CANCELLED%' THEN
        RAISE EXCEPTION 'FIXTURE 248 DD3: a cancelled order took a judgement: %', v_msg; END IF;

    -- ══════════════ CL · 报销单的另一位决定人 ══════════════
    -- u_sub 持一级与二级(唯一的持有人,员工 e_sub);u_l2b 后来只持一级(员工 e_l2b);u_pay 是一个不在名册上的提单人。
    -- CL1 提单人那条腿:u_sub 替 e_emp 报一张一级的单 —— 除了他(提单人)没人批得动 → 按名拒,一张不落
    SELECT count(*) INTO v_n FROM expense_claims;
    v_msg := pg_temp.f248_try(u_sub, format('SELECT submit_expense_claim(%L, CURRENT_DATE - 1, 200, %L, %L, NULL)',
                                            e_emp, v_base, 'FX248 taxi'));
    IF v_msg NOT LIKE 'EXPENSE_CLAIM_NO_OTHER_DECIDER|CLM-%' THEN
        RAISE EXCEPTION 'FIXTURE 248 CL1: a claim only its raiser could decide should be refused by name, got %', v_msg; END IF;
    IF (SELECT count(*) FROM expense_claims) <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 248 CL1: the refused claim was stored'; END IF;
    -- CL4 Tim 的 R2 例外照算:唯一的二级持有人替自己报 ≥ 1,000 的单 —— 他可以决定自己的报销,所以不拒
    v_msg := pg_temp.f248_try(u_sub, format('SELECT submit_expense_claim(%L, CURRENT_DATE - 1, 1500, %L, %L, NULL)',
                                            e_sub, v_base, 'FX248 conference fee'));
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 248 CL4: the R2 self-exception should let the only level-2 holder submit his own claim, got %', v_msg; END IF;
    -- CL2 主角那条腿:名册上只剩 u_l2b(一级,不持二级),u_pay 替 u_l2b 报一张一级的单 —— 主角批不了自己的(没有 R2),没人 → 按名拒
    DELETE FROM user_roles WHERE user_id = u_sub AND role_id IN (r_l1, r_l2);
    INSERT INTO user_roles (user_id, role_id) VALUES (u_l2b, r_l1);
    v_msg := pg_temp.f248_try(u_pay, format('SELECT submit_expense_claim(%L, CURRENT_DATE - 1, 200, %L, %L, NULL)',
                                            e_l2b, v_base, 'FX248 claimed for the approver'));
    IF v_msg NOT LIKE 'EXPENSE_CLAIM_NO_OTHER_DECIDER|%' THEN
        RAISE EXCEPTION 'FIXTURE 248 CL2: the subject leg is not counted (a claim only its subject could decide went in): %', v_msg; END IF;
    -- CL3 多一个能批的人 → 同一张单照开
    INSERT INTO user_roles (user_id, role_id) VALUES (u_sub, r_l1);
    v_msg := pg_temp.f248_try(u_pay, format('SELECT submit_expense_claim(%L, CURRENT_DATE - 1, 200, %L, %L, NULL)',
                                            e_l2b, v_base, 'FX248 claimed for the approver'));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 248 CL3: with another decider the claim should go in, got %', v_msg; END IF;

    -- ══════════════ LV · 九支请假函数的 NULL 陷阱 ══════════════
    FOREACH f IN ARRAY ARRAY[
        format('SELECT accrued_annual_leave_detail(%L)', e_emp), format('SELECT accrued_annual_leave(%L)', e_emp),
        format('SELECT annual_leave_available_from(%L, 1)', e_emp), format('SELECT annual_leave_rate_per_year(%L)', e_emp),
        format('SELECT available_annual_accrual(%L)', e_emp), format('SELECT consumed_from_accrual(%L, %s)', e_emp, extract(year from CURRENT_DATE)::int),
        format('SELECT compute_leave_encashment(%L)', e_emp), format('SELECT leave_balance_internal(%L)', e_emp),
        format('SELECT leave_balance(%L)', e_emp)] LOOP
        v_msg := pg_temp.f248_try(u_none, f);
        IF v_msg NOT LIKE 'PERMISSION_DENIED|module.hr.view%' THEN
            RAISE EXCEPTION 'FIXTURE 248 LV: an account with no employee record passed the self gate of «%»: %', f, v_msg; END IF;
    END LOOP;
    -- 本人照旧读得到自己的(这一道门对有档案的人没有变窄)
    v_msg := pg_temp.f248_try(u_emp, format('SELECT leave_balance(%L)', e_emp));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 248 LV: the employee can no longer read their own balance: %', v_msg; END IF;

    -- ══════════════ JR · 工资分录的冲销申请 ══════════════
    je_pay := (post_journal_entry(CURRENT_DATE, 'FX248 salary payment', 'payroll', gen_random_uuid(), jsonb_build_array(
        jsonb_build_object('account_code', '2300', 'side', 'debit', 'currency', v_base, 'amount_ccy', 4677, 'fx_rate', 1),
        jsonb_build_object('account_code', '1000', 'side', 'credit', 'currency', v_base, 'amount_ccy', 4677, 'fx_rate', 1)))->>'entry_id')::uuid;
    je_man := (post_journal_entry(CURRENT_DATE, 'FX248 office supplies', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code', '6200', 'side', 'debit', 'currency', v_base, 'amount_ccy', 88, 'fx_rate', 1),
        jsonb_build_object('account_code', '1000', 'side', 'credit', 'currency', v_base, 'amount_ccy', 88, 'fx_rate', 1)))->>'entry_id')::uuid;
    IF je_pay IS NULL OR je_man IS NULL THEN RAISE EXCEPTION 'FIXTURE 248 JR setup: post_journal_entry returned no entry id'; END IF;
    INSERT INTO journal_requests (kind, status, label, entry_date, memo, target_entry_id, amount_base, credits_bank, created_by)
    VALUES ('reversal', 'submitted', 'FX248 reversal pay', CURRENT_DATE, 'FX248 paid twice', je_pay, 4677, true, u_pay) RETURNING id INTO jr_pay;
    INSERT INTO journal_requests (kind, status, label, entry_date, memo, target_entry_id, amount_base, credits_bank, created_by)
    VALUES ('reversal', 'submitted', 'FX248 reversal manual', CURRENT_DATE, 'FX248 wrong account', je_man, 88, true, u_pay) RETURNING id INTO jr_man;
    INSERT INTO approval_log (subject_type, subject_id, subject_code, decision, level, actor_user_id, amount_ccy, currency, fx_rate, amount_base)
    VALUES ('journal_request', jr_pay, 'FX248 reversal pay', 'submitted', 2, u_pay, 4677, v_base, 1, 4677) RETURNING id INTO ap_jr;

    v_msg := pg_temp.f248_try(u_cto, format('SELECT amount_base FROM journal_requests WHERE id = %L', jr_pay));
    IF v_msg <> '42501' THEN RAISE EXCEPTION 'FIXTURE 248 JR1: expected 42501 on journal_requests.amount_base, got %', v_msg; END IF;
    v_j := pg_temp.f248_read('JR', u_cto, format(
        'SELECT jsonb_build_object(''pay'', (SELECT to_jsonb(m) FROM journal_requests_masked m WHERE m.id = %L), ''man'', (SELECT to_jsonb(m) FROM journal_requests_masked m WHERE m.id = %L), ''apr'', (SELECT a.amount_base FROM approval_log_masked a WHERE a.id = %L))',
        jr_pay, jr_man, ap_jr));
    IF v_j -> 'pay' IS NULL OR jsonb_typeof(v_j -> 'pay') <> 'object' THEN RAISE EXCEPTION 'FIXTURE 248 JR2: cto cannot see the payroll reversal request row at all'; END IF;
    IF (v_j #>> '{pay,amount_base}') IS NOT NULL OR (v_j #>> '{pay,amount_restricted}')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 248 JR2: a reader without data.view_pay reads the payroll reversal amount: %', v_j -> 'pay'; END IF;
    IF (v_j #>> '{man,amount_base}')::numeric IS DISTINCT FROM 88 OR (v_j #>> '{man,amount_restricted}')::boolean IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 248 JR2: a non-payroll reversal amount should be visible to the same reader: %', v_j -> 'man'; END IF;
    IF (v_j ->> 'apr') IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 248 JR3: the approval row of the payroll reversal request carries its amount for a reader without data.view_pay'; END IF;
    PERFORM pg_temp.f248_as(u_cto);
    IF change_log_rule_visible('jr_amount', 'journal_requests', jsonb_build_object('id', jr_pay), NULL, jsonb_build_object('id', jr_pay)) THEN
        PERFORM set_config('request.jwt.claims', '', true);
        RAISE EXCEPTION 'FIXTURE 248 JR4: the change-log rule shows the payroll reversal amount to a reader without data.view_pay'; END IF;
    PERFORM pg_temp.f248_as(u_pay);
    IF NOT change_log_rule_visible('jr_amount', 'journal_requests', jsonb_build_object('id', jr_pay), NULL, jsonb_build_object('id', jr_pay)) THEN
        PERFORM set_config('request.jwt.claims', '', true);
        RAISE EXCEPTION 'FIXTURE 248 JR4: the change-log rule hides the amount from a data.view_pay holder'; END IF;
    PERFORM set_config('request.jwt.claims', '', true);
    v_j := pg_temp.f248_read('JR', u_pay, format(
        'SELECT jsonb_build_object(''pay'', (SELECT m.amount_base FROM journal_requests_masked m WHERE m.id = %L), ''apr'', (SELECT a.amount_base FROM approval_log_masked a WHERE a.id = %L))',
        jr_pay, ap_jr));
    IF (v_j ->> 'pay')::numeric IS DISTINCT FROM 4677 OR (v_j ->> 'apr')::numeric IS DISTINCT FROM 4677 THEN
        RAISE EXCEPTION 'FIXTURE 248 JR5: a data.view_pay holder should read 4677 on the request and on its approval row: %', v_j; END IF;

    -- ══════════════ MC · 医疗报销的批准理由 ══════════════
    INSERT INTO medical_claims (code, employee_id, claim_date, claim_year, amount_sgd, description, receipt_ref, status, decided_at, decided_by, decision_notes)
    VALUES ('FX248-MC', e_emp, CURRENT_DATE - 3, extract(year from CURRENT_DATE)::int, 120, 'FX248-SECRET migraine', 'FX248-RC', 'approved', now(), u_pay,
            'FX248-SECRET covered under the outpatient benefit') RETURNING id INTO mc;
    INSERT INTO approval_log (subject_type, subject_id, subject_code, decision, level, actor_user_id, note, amount_ccy, currency, fx_rate, amount_base, self_decided)
    VALUES ('medical_claim', mc, 'FX248-MC', 'approved', 1, u_pay, 'FX248-SECRET covered under the outpatient benefit', 120, v_base, 1, 120, true) RETURNING id INTO ap_mc;
    v_msg := pg_temp.f248_try(u_cto, format('SELECT decision_notes FROM medical_claims WHERE id = %L', mc));
    IF v_msg <> '42501' THEN RAISE EXCEPTION 'FIXTURE 248 MC1: expected 42501 on medical_claims.decision_notes, got %', v_msg; END IF;
    v_msg := pg_temp.f248_try(u_cto, format('SELECT note FROM approval_log WHERE id = %L', ap_mc));
    IF v_msg <> '42501' THEN RAISE EXCEPTION 'FIXTURE 248 MC1: expected 42501 on approval_log.note, got %', v_msg; END IF;
    v_j := pg_temp.f248_read('MC', u_cto, format(
        'SELECT jsonb_build_object(''mc'', (SELECT to_jsonb(m) FROM medical_claims_masked m WHERE m.id = %L), ''apr'', (SELECT to_jsonb(a) FROM approval_log_masked a WHERE a.id = %L))', mc, ap_mc));
    IF jsonb_typeof(v_j -> 'mc') <> 'object' OR jsonb_typeof(v_j -> 'apr') <> 'object' THEN
        RAISE EXCEPTION 'FIXTURE 248 MC2: cto should still see the claim and its approval row (rows are not hidden): %', v_j; END IF;
    IF (v_j #>> '{mc,decision_notes}') IS NOT NULL OR (v_j #>> '{apr,note}') IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 248 MC2: a reader without data.view_health reads the medical decision text: %', v_j; END IF;
    v_j := pg_temp.f248_read('MC', u_emp, format(
        'SELECT jsonb_build_object(''mc'', (SELECT m.decision_notes FROM medical_claims_masked m WHERE m.id = %L))', mc));
    IF (v_j ->> 'mc') IS DISTINCT FROM 'FX248-SECRET covered under the outpatient benefit' THEN
        RAISE EXCEPTION 'FIXTURE 248 MC3: the employee cannot read the decision on their own claim: %', v_j; END IF;
    v_j := pg_temp.f248_read('MC', u_pay, format(
        'SELECT jsonb_build_object(''mc'', (SELECT m.decision_notes FROM medical_claims_masked m WHERE m.id = %L), ''apr'', (SELECT a.note FROM approval_log_masked a WHERE a.id = %L))', mc, ap_mc));
    IF (v_j ->> 'mc') IS NULL OR (v_j ->> 'apr') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 248 MC3: a data.view_health holder cannot read the decision text: %', v_j; END IF;
    PERFORM pg_temp.f248_as(u_cto);
    IF change_log_rule_visible('apr_note', 'approval_log', jsonb_build_object('id', ap_mc), NULL,
                               jsonb_build_object('subject_type', 'medical_claim', 'subject_id', mc))
       OR change_log_rule_visible('code_or_self:data.view_health:employee_id', 'medical_claims', jsonb_build_object('id', mc), NULL,
                                  jsonb_build_object('employee_id', e_emp)) THEN
        PERFORM set_config('request.jwt.claims', '', true);
        RAISE EXCEPTION 'FIXTURE 248 MC4: the change-log rules show the medical decision text to a reader without data.view_health'; END IF;
    PERFORM set_config('request.jwt.claims', '', true);
    IF NOT EXISTS (SELECT 1 FROM change_log_mask_rules() WHERE table_name = 'medical_claims' AND column_name = 'decision_notes')
       OR NOT EXISTS (SELECT 1 FROM change_log_mask_rules() WHERE table_name = 'approval_log' AND column_name = 'note' AND rule = 'apr_note')
       OR NOT EXISTS (SELECT 1 FROM change_log_mask_rules() WHERE table_name = 'journal_requests' AND column_name = 'amount_base' AND rule = 'jr_amount') THEN
        RAISE EXCEPTION 'FIXTURE 248 MC4: a mask rule is missing (medical decision_notes / approval note / journal request amount)'; END IF;
    v_j := pg_temp.f248_read('MC', u_sa, format(
        'SELECT (SELECT to_jsonb(s) FROM self_approved_decisions() s WHERE s.subject_id = %L)', mc));
    IF jsonb_typeof(v_j) <> 'object' THEN RAISE EXCEPTION 'FIXTURE 248 MC5: the self-approval report lost the medical decision row'; END IF;
    IF (v_j ->> 'note') IS NOT NULL OR (v_j ->> 'amount_ccy') IS NOT NULL OR (v_j ->> 'amount_base') IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 248 MC5: the self-approval report shows a medical decision''s text or amount to a reader without data.view_health: %', v_j; END IF;

    -- ══════════════ ME · 月结清单数的就是关账拒的那一句 ══════════════
    INSERT INTO processing_runs (code, process_date, total_input, status, allocation_basis, operation_type_code, allocated_at, deleted_at, started_at, ended_at, shift_code)
    VALUES ('ZZF248-R1', v_end - 3, 100, 'committed', 'weight', 'manual_disassembly', NULL, NULL, (v_end - 3)::timestamptz, LEAST((v_end - 3)::timestamptz + interval '1 hour', now()), 'day'),      -- 挡
           ('ZZF248-R2', v_end - 2, 100, 'committed', 'weight', 'manual_disassembly', now(), NULL, (v_end - 2)::timestamptz, LEAST((v_end - 2)::timestamptz + interval '1 hour', now()), 'day'),     -- 已分摊
           ('ZZF248-R3', v_end + 2, 100, 'committed', 'weight', 'manual_disassembly', NULL, NULL, (v_end + 2)::timestamptz, LEAST((v_end + 2)::timestamptz + interval '1 hour', now()), 'day'),      -- 晚于月末
           ('ZZF248-R4', v_end - 1, 100, 'committed', 'weight', 'manual_disassembly', NULL, now(), (v_end - 1)::timestamptz, LEAST((v_end - 1)::timestamptz + interval '1 hour', now()), 'day');     -- 已删
    SELECT count(*) INTO v_n FROM processing_runs r
     WHERE r.deleted_at IS NULL AND r.status = 'committed' AND r.allocated_at IS NULL AND r.process_date <= v_end;
    v_j := pg_temp.f248_read('ME', u_fin, format('SELECT (SELECT to_jsonb(b) FROM processing_runs_blocking_close(%L::date) b)', v_end));
    IF (v_j ->> 'run_count')::int IS DISTINCT FROM v_n OR position('ZZF248-R1' IN COALESCE(v_j ->> 'run_codes', '')) = 0
       OR position('ZZF248-R3' IN COALESCE(v_j ->> 'run_codes', '')) > 0 OR position('ZZF248-R2' IN COALESCE(v_j ->> 'run_codes', '')) > 0 THEN
        RAISE EXCEPTION 'FIXTURE 248 ME1: a finance reader with no processing code reads % (expected % blocking runs incl. ZZF248-R1 only of the four)', v_j, v_n; END IF;
    v_msg := pg_temp.f248_try(u_view, format('SELECT processing_runs_blocking_close(%L::date)', v_end));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.finance.view%' THEN
        RAISE EXCEPTION 'FIXTURE 248 ME2: a reader without finance view read the month-end blockers: %', v_msg; END IF;
    -- 认【调用的形状】,不认名字:close_period 的注释里也写着这支函数的名字(fault injection 实测:按名字认,拿掉调用照样绿)
    IF position('processing_runs_blocking_close(p_period_end)' IN (SELECT prosrc FROM pg_proc WHERE proname = 'close_period')) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 248 ME3: close_period does not ask processing_runs_blocking_close — the checklist and the close count two things'; END IF;

    RAISE NOTICE 'FIXTURE 248 全部通过: DT · PO · DD · CL · LV · JR · MC · ME';
END;
$$;

ROLLBACK;
