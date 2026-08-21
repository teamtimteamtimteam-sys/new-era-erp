-- 75 接缝(WO-1b):加工单认下它照的那张工单,而差异算得出来
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉住的东西】
--
--   ① 【工单参数是【可选】的,而"不传"这一支必须一字不变】临时起意的加工是
--      合法的。所以这里既验"传了会挂上",也验"不传照样跑通、且 work_order_id
--      留成 NULL" —— 后者是这一刀"纯增量"那句话的行为断言。
--      (更硬的那半在别处:fixture 18/19/25 一个字没改就得重新跑通。)
--   ② 【只有放行了的工单可以开工】draft 是还没答应的事;closed / cancelled 是
--      已经结束的事 —— 三个方向各拒一次,各自是唯一没满足的前提。
--   ③ 【冲销对齐:链接是历史,它断言过的消耗不是】一次加工被冲销之后,
--      地板降下来、取消重新变得合法、差异视图里那几个数回到零 ——
--      而 work_order_id 【仍然留在那一行上】。四件事一起验,因为只验其中一件
--      的实现有很多种,而它们只有在四件都对的时候才是同一个规则。
--   ④ 【没估过 ≠ 估了零】预期产出缺席时 variance 是 NULL,has_plan 是 false。
--      一个 COALESCE(...,0) 的实现在这一臂当场红。
--   ⑤ 【计划外的加工不在差异视图里】—— 它不是"计划为零"的一行,因为没有人
--      计划过零。
--
-- 【注入臂:三个,各删一道门,各自从【任何注入之前】取的原样定义派生】
--   注入 1:删掉【只有放行了的工单可以开工】→ 照草稿开工当场走通(B 臂有牙)。
--           **这一道是单层的** —— 表上没有任何东西阻止一次加工挂到草稿/已收工/
--           已取消的工单上,所以它漏了就是真的会写进去。
--   注入 2:把【只数没被冲销的】那个过滤整个拿掉 → 被冲销的加工重新拦住取消
--           (D 臂④有牙)。
--   注入 3:删掉 WO_NOT_FOUND → 落到 processing_runs 的外键上(第二层,按名断言)。
-- 【注入臂放在最后】(fixture 64/69/71/73/74 都付过这笔账)。
-- 原样定义在【任何注入之前】一次取齐 —— 见 fixture 74 那条同样的教训。
-- 自带数据(README 第 2 条)。期间锁显式设 NULL(第 5 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user  uuid := gen_random_uuid();
    v_view  uuid := gen_random_uuid();   -- 只有 module.processing.view
    v_other uuid := gen_random_uuid();   -- 只有别的模块
    r_all uuid; r_view uuid; r_other uuid;
    v_sup uuid; v_matA uuid; v_matB uuid;
    v_ib1 uuid; v_ib2 uuid; v_ib3 uuid;
    woOK uuid; woDraft uuid; woClosed uuid; woCancelled uuid; woRev uuid; woNoExp uuid;
    v_run uuid; v_run2 uuid; v_runFree uuid;
    v_res jsonb; v_msg text; v_denied boolean; v_n integer; v_qty numeric;
    v_planned numeric; v_actual numeric; v_var numeric; v_hasplan boolean;
    def_commit text; def_cancel text;
    v_def text; v_inj text;
    d date := CURRENT_DATE;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-75', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-75-view', 'f', 'f', true) RETURNING id INTO r_view;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_view, 'module.processing.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (v_view, r_view);

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-75-other', 'f', 'f', true) RETURNING id INTO r_other;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_other, 'module.sales.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (v_other, r_other);

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    UPDATE finance_settings SET locked_before = NULL;
    -- 【审批显式设成关闭】(README 第 5 条:前提要自己设,哪怕默认值恰好合用)
    -- 放行这一刀之后会走审批分支,而 approvals_enabled 是一个运营可改的开关 ——
    -- 不显式设,这份 fixture 的绿会取决于线上此刻有没有人打开过它。
    UPDATE finance_settings SET approvals_enabled = false;

    -- 【原样定义在任何注入之前取齐】fixture 74 学到的:临用临取会取到已经被
    -- 上一个注入改过的那一份,于是门会累积。
    -- EQP-2a:签名又多了一个 p_equipment_id(这一炉归给哪台机器),这里跟着改。
    -- 【它把签名钉死是对的,而且改签名【一定】会在这里红一次 —— 那是设计】
    -- regprocedure 找不到那个签名就当场报错,于是"签名动了"永远不会静悄悄过去。
    -- 同一形状已经发生过两次(WO-1b 加 p_work_order_id、本刀加 p_equipment_id),
    -- 而 fixture 77 对 record_expense 也是同一条 —— 所以它是规律,不是意外。
    def_commit := pg_get_functiondef('public.commit_processing_run(date,text,numeric,jsonb,jsonb,text,uuid,uuid)'::regprocedure);
    def_cancel := pg_get_functiondef('public.cancel_work_order(uuid,text)'::regprocedure);

    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('ZZ75-S', 'fixture 75 supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES ('ZZ75-MA','f75 raw', 'battery_material', true, 'black_mass', 'end_of_life')
        RETURNING id INTO v_matA;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES ('ZZ75-MB','f75 fine', 'battery_material', true, 'black_mass', 'end_of_life')
        RETURNING id INTO v_matB;

    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ75-IB1', v_matA, v_sup, 200, 200, 'kg', d) RETURNING id INTO v_ib1;
    PERFORM reprice_inbound_batch(v_ib1, 1, 'SGD', NULL, 'f75 price');
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ75-IB2', v_matA, v_sup, 200, 200, 'kg', d) RETURNING id INTO v_ib2;
    PERFORM reprice_inbound_batch(v_ib2, 1, 'SGD', NULL, 'f75 price');
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ75-IB3', v_matA, v_sup, 200, 200, 'kg', d) RETURNING id INTO v_ib3;
    PERFORM reprice_inbound_batch(v_ib3, 1, 'SGD', NULL, 'f75 price');

    -- ══════════ A. 挂上工单:链接写进去了,库存效果一字不变 ═══════════════════
    v_res := create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'expected_qty', 90)),
        d, 'f75 OK');
    woOK := (v_res->>'work_order_id')::uuid;
    PERFORM release_work_order(woOK);

    v_run := commit_processing_run(d, 'f75 run', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib1, 'quantity_consumed', 80)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 75)), 'weight',
        woOK);
    IF (SELECT work_order_id FROM processing_runs WHERE id = v_run) IS DISTINCT FROM woOK THEN
        RAISE EXCEPTION 'FIXTURE 75A 失败:加工单应当认下它照的那张工单';
    END IF;
    -- 【库存那一侧一字不变 —— 这是"纯增量"的行为断言】
    IF (SELECT remaining_qty FROM inbound_batches WHERE id = v_ib1) <> 120 THEN
        RAISE EXCEPTION 'FIXTURE 75A 失败:挂了工单不该改变扣料(200 - 80 = 120)';
    END IF;
    IF (SELECT stage FROM inbound_batches WHERE id = v_ib1) <> '加工中' THEN
        RAISE EXCEPTION 'FIXTURE 75A 失败:挂了工单不该改变批次阶段';
    END IF;
    IF (SELECT count(*) FROM inventory_movements
         WHERE run_id = v_run AND movement_type = 'processing_consume') = 0 THEN
        RAISE EXCEPTION 'FIXTURE 75A 失败:挂了工单不该改变库存流水';
    END IF;

    -- 【不传参数照样跑通,而且 work_order_id 留成 NULL】—— 临时起意的加工是合法的
    v_runFree := commit_processing_run(d, 'f75 unplanned run', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib3, 'quantity_consumed', 10)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 9)), 'weight');
    IF (SELECT work_order_id FROM processing_runs WHERE id = v_runFree) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 75A 失败:不传工单参数时 work_order_id 应当留成 NULL';
    END IF;

    -- ══════════ B. 三个方向的拒绝,各自只差它自己那一件 ═══════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM commit_processing_run(d, 'x', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib2, 'quantity_consumed', 1)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 1)), 'weight',
        gen_random_uuid());
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'WO_NOT_FOUND|%' THEN
        RAISE EXCEPTION 'FIXTURE 75B 失败:不存在的工单应当按名拒,实得 %', COALESCE(v_msg,'(提交了)');
    END IF;

    -- 草稿:还没答应的事
    v_res := create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 10)), NULL, NULL, 'f75 draft');
    woDraft := (v_res->>'work_order_id')::uuid;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM commit_processing_run(d, 'x', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib2, 'quantity_consumed', 1)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 1)), 'weight', woDraft);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'WO_NOT_RELEASED|%|draft' THEN
        RAISE EXCEPTION 'FIXTURE 75B 失败:草稿工单不该开得了工,实得 %', COALESCE(v_msg,'(提交了)');
    END IF;

    -- 已收工:已经结束的事(再挂一次会让它收工之后完成度继续变)
    v_res := create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 10)), NULL, NULL, 'f75 closed');
    woClosed := (v_res->>'work_order_id')::uuid;
    PERFORM release_work_order(woClosed);
    PERFORM close_work_order(woClosed, 'f75:先收工');
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM commit_processing_run(d, 'x', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib2, 'quantity_consumed', 1)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 1)), 'weight', woClosed);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'WO_NOT_RELEASED|%|closed' THEN
        RAISE EXCEPTION 'FIXTURE 75B 失败:已收工的工单不该再挂加工,实得 %', COALESCE(v_msg,'(提交了)');
    END IF;

    -- 已取消
    v_res := create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 10)), NULL, NULL, 'f75 cancelled');
    woCancelled := (v_res->>'work_order_id')::uuid;
    PERFORM cancel_work_order(woCancelled, 'f75:先取消');
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM commit_processing_run(d, 'x', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib2, 'quantity_consumed', 1)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 1)), 'weight', woCancelled);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'WO_NOT_RELEASED|%|cancelled' THEN
        RAISE EXCEPTION 'FIXTURE 75B 失败:已取消的工单不该挂加工,实得 %', COALESCE(v_msg,'(提交了)');
    END IF;
    -- 【拒了就是什么都没写】—— 上面四次被拒都不该扣掉 ib2 一克
    IF (SELECT remaining_qty FROM inbound_batches WHERE id = v_ib2) <> 200 THEN
        RAISE EXCEPTION 'FIXTURE 75B 失败:被拒的提交不该动库存(ib2 应当仍是 200)';
    END IF;

    -- ══════════ C. 差异算术 ═══════════════════════════════════════════════════
    -- woOK:计划投 100,实吃 80;预期产 90,实产 75。
    SELECT planned_or_expected_qty, actual_qty, variance_qty, has_plan
      INTO v_planned, v_actual, v_var, v_hasplan
      FROM work_order_fulfilment
     WHERE work_order_id = woOK AND side = 'input' AND material_id = v_matA;
    IF v_planned <> 100 OR v_actual <> 80 OR v_var <> -20 OR NOT v_hasplan THEN
        RAISE EXCEPTION 'FIXTURE 75C 失败:投入侧应当是 计划 100 / 实吃 80 / 差 -20,实得 % / % / %',
            v_planned, v_actual, v_var;
    END IF;
    SELECT planned_or_expected_qty, actual_qty, variance_qty
      INTO v_planned, v_actual, v_var
      FROM work_order_fulfilment
     WHERE work_order_id = woOK AND side = 'output' AND material_id = v_matB;
    IF v_planned <> 90 OR v_actual <> 75 OR v_var <> -15 THEN
        RAISE EXCEPTION 'FIXTURE 75C 失败:产出侧应当是 预期 90 / 实产 75 / 差 -15,实得 % / % / %',
            v_planned, v_actual, v_var;
    END IF;

    -- 【没估过 ≠ 估了零】—— 一张不给预期产出的工单
    v_res := create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 50)),
        NULL, NULL, 'f75 no expectation');
    woNoExp := (v_res->>'work_order_id')::uuid;
    PERFORM release_work_order(woNoExp);
    PERFORM commit_processing_run(d, 'f75 run noexp', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib2, 'quantity_consumed', 40)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 38)), 'weight',
        woNoExp);
    SELECT planned_or_expected_qty, actual_qty, variance_qty, has_plan
      INTO v_planned, v_actual, v_var, v_hasplan
      FROM work_order_fulfilment
     WHERE work_order_id = woNoExp AND side = 'output' AND material_id = v_matB;
    IF v_actual <> 38 THEN
        RAISE EXCEPTION 'FIXTURE 75C 失败:没估过的产出仍然要报实产 38,实得 %', v_actual;
    END IF;
    IF v_planned IS NOT NULL OR v_var IS NOT NULL OR v_hasplan THEN
        RAISE EXCEPTION 'FIXTURE 75C 失败:没有预期时 预期/差异 都该是 NULL、has_plan 为 false —— 实得 % / % / %。一个 COALESCE(...,0) 会让任何产出都成为超额完成',
            COALESCE(v_planned::text,'NULL'), COALESCE(v_var::text,'NULL'), v_hasplan;
    END IF;

    -- 【计划外的加工不在这张视图里】—— 它不是"计划为零"的一行
    IF EXISTS (SELECT 1 FROM work_order_fulfilment f
                JOIN processing_runs r ON r.work_order_id = f.work_order_id
               WHERE r.id = v_runFree) THEN
        RAISE EXCEPTION 'FIXTURE 75C 失败:计划外的加工不该出现在差异视图里(没有人计划过零)';
    END IF;

    -- ══════════ D. 冲销对齐:四件事一起 ═══════════════════════════════════════
    v_res := create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 100)), NULL, d, 'f75 rev');
    woRev := (v_res->>'work_order_id')::uuid;
    PERFORM release_work_order(woRev);
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ75-IB4', v_matA, v_sup, 100, 100, 'kg', d) RETURNING id INTO v_ib3;
    PERFORM reprice_inbound_batch(v_ib3, 1, 'SGD', NULL, 'f75 price');
    v_run2 := commit_processing_run(d, 'f75 to be reversed', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib3, 'quantity_consumed', 70)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 65)), 'weight',
        woRev);

    -- 冲销之前:地板拦、取消拦、差异视图数得到
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM amend_work_order(woRev, '冲销前想改小', NULL, false, NULL, false,
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 50)), NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'WO_LINE_BELOW_CONSUMED|%|50|70' THEN
        RAISE EXCEPTION 'FIXTURE 75D 前提不成立:冲销【之前】地板就该拦住,实得 %', COALESCE(v_msg,'(改成了)');
    END IF;
    SELECT actual_qty INTO v_actual FROM work_order_fulfilment
     WHERE work_order_id = woRev AND side = 'input' AND material_id = v_matA;
    IF v_actual <> 70 THEN
        RAISE EXCEPTION 'FIXTURE 75D 前提不成立:冲销之前差异视图应当数到 70,实得 %', v_actual;
    END IF;

    PERFORM rollback_processing_run(v_run2, 'fixture:AUDEL-1b 之后理由必填');

    -- 冲销之后,四件事:
    -- ① 链接【留在那一行上】—— 那次加工确实是照这张工单做的,抹掉它是篡改历史
    IF (SELECT work_order_id FROM processing_runs WHERE id = v_run2) IS DISTINCT FROM woRev THEN
        RAISE EXCEPTION 'FIXTURE 75D 失败:冲销不该抹掉链接 —— 链接是历史,它断言过的消耗才不是';
    END IF;
    -- ② 地板降下来了
    PERFORM amend_work_order(woRev, '冲销之后把计划改小', NULL, false, NULL, false,
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 50)), NULL);
    IF (SELECT planned_qty FROM work_order_lines WHERE work_order_id = woRev AND material_id = v_matA) <> 50 THEN
        RAISE EXCEPTION 'FIXTURE 75D 失败:冲销之后地板应当降下来 —— 那次消耗不再是发生过的事实';
    END IF;
    -- ③ 差异视图里那几个数回到零
    SELECT actual_qty INTO v_actual FROM work_order_fulfilment
     WHERE work_order_id = woRev AND side = 'input' AND material_id = v_matA;
    IF v_actual <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 75D 失败:冲销之后差异视图不该再数那次消耗,实得 %', v_actual;
    END IF;
    -- ④ 取消重新变得合法(这一条 WO-1a 是错的:它只看 deleted_at,不看 status)
    v_res := cancel_work_order(woRev, 'f75:冲销之后这张单不做了');
    IF (v_res->>'status') <> 'cancelled' THEN
        RAISE EXCEPTION 'FIXTURE 75D 失败:唯一那次加工被冲销之后,取消应当重新合法 —— 拦住它等于用一次没有发生的加工做理由';
    END IF;

    -- ══════════ E. 审批主体 ═══════════════════════════════════════════════════
    -- 关着的时候也要留痕,而且要说实话(与 create_purchase_order 逐字同一句)
    IF NOT EXISTS (SELECT 1 FROM approval_log
                    WHERE subject_type = 'work_order' AND subject_id = woOK
                      AND decision = 'auto_approved') THEN
        RAISE EXCEPTION 'FIXTURE 75E 失败:审批关着时放行也要留一条 auto_approved 痕 —— 不能把"系统盖章"伪装成没发生过';
    END IF;
    -- 【工单没有金额 —— 那四列留空,不是塞 0】0 会让它在按金额筛的报表里排到最前面
    IF (SELECT amount_base FROM approval_log
         WHERE subject_type='work_order' AND subject_id=woOK LIMIT 1) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 75E 失败:工单没有金额,那几列应当留空而不是 0';
    END IF;
    -- 编号冻结在当时
    IF (SELECT subject_code FROM approval_log
         WHERE subject_type='work_order' AND subject_id=woOK LIMIT 1)
       IS DISTINCT FROM (SELECT code FROM work_orders WHERE id = woOK) THEN
        RAISE EXCEPTION 'FIXTURE 75E 失败:留痕应当冻结工单编号';
    END IF;
    -- 主体必须真的存在 —— 不插指向空气的痕
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM record_approval_decision('work_order', gen_random_uuid(), 'approved', 1::smallint, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'APPROVAL_SUBJECT_NOT_FOUND|work_order|%' THEN
        RAISE EXCEPTION 'FIXTURE 75E 失败:不存在的工单不该留得下审批痕,实得 %', COALESCE(v_msg,'(留下了)');
    END IF;

    -- ══════════ F. 权限:视图按数据自己的 RLS ═══════════════════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_view), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM work_order_fulfilment WHERE work_order_id = woOK;
    RESET ROLE;
    IF v_n < 2 THEN
        RAISE EXCEPTION 'FIXTURE 75F 失败:只有 processing.view 的读者应当读得到两侧各一行,实得 % 行', v_n;
    END IF;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_other), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM work_order_fulfilment;
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 75F 失败:没有 processing.view 的读者应当一行都看不见,实得 % 行', v_n;
    END IF;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ 注入 1:删掉【只有放行了的工单可以开工】那道门 ═══════════════
    -- 前提:woDraft 是草稿,料够,其余参数都合法 —— 只差这一件。
    IF (SELECT status FROM work_orders WHERE id = woDraft) <> 'draft' THEN
        RAISE EXCEPTION 'FIXTURE 75 注入1 前提不成立:要的是一张【草稿】工单';
    END IF;
    v_inj := replace(def_commit,
$g$        IF v_wo.status <> 'released' THEN
            RAISE EXCEPTION 'WO_NOT_RELEASED|%|%', v_wo.code, v_wo.status;
        END IF;
$g$, '');
    IF v_inj = def_commit THEN
        RAISE EXCEPTION 'FIXTURE 75 注入1 失败:在函数定义里没找到【只有放行了的可以开工】那道门的原文 —— 这个注入什么也没删';
    END IF;
    EXECUTE v_inj;
    v_run := commit_processing_run(d, '注入之后照草稿开工', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib2, 'quantity_consumed', 5)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 4)), 'weight', woDraft);
    IF (SELECT work_order_id FROM processing_runs WHERE id = v_run) IS DISTINCT FROM woDraft THEN
        RAISE EXCEPTION 'FIXTURE 75 注入1 失败:删掉那道门之后,照草稿开工【仍然】没写进去 —— 说明 B 臂拒它的不是那道门';
    END IF;

    -- ══════════ 注入 3:删掉 WO_NOT_FOUND 那道门 ═════════════════════════════
    -- 【这一臂预期落到第二层,而那一层是外键】—— 与 fixture 74 的注入 3/4 同形。
    -- 门拿掉之后 SELECT ... INTO 找不到行,v_wo 各列全是 NULL,于是紧接着那句
    -- `v_wo.status <> 'released'` 求值为 NULL —— **IF NULL 不成立**,所以它
    -- 【也不会】拦下来(这本身就值得知道:两道门是串着的,前一道漏了会让后一道
    -- 静默失效,而不是接住)。函数一路走到建表头,work_order_id 指着一个不存在的
    -- 工单,由 processing_runs 的外键当场拒掉。
    -- 所以这一臂断言的不是"现在成功了",而是【现在由外键按名拒】。
    IF (SELECT count(*) FROM pg_constraint
         WHERE conrelid = 'public.processing_runs'::regclass
           AND contype = 'f' AND conname LIKE '%work_order%') <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 75 注入3 前提不成立:processing_runs 上应当有一条指向 work_orders 的外键 —— 它就是这一臂等着的第二层';
    END IF;
    v_inj := replace(def_commit,
$g$        IF NOT FOUND THEN
            RAISE EXCEPTION 'WO_NOT_FOUND|%', p_work_order_id;
        END IF;
$g$, '');
    IF v_inj = def_commit THEN
        RAISE EXCEPTION 'FIXTURE 75 注入3 失败:在函数定义里没找到 WO_NOT_FOUND 那道门的原文 —— 这个注入什么也没删';
    END IF;
    EXECUTE v_inj;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM commit_processing_run(d, '注入之后照一张不存在的工单开工', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib2, 'quantity_consumed', 3)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 2)), 'weight',
        gen_random_uuid());
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg LIKE 'WO_NOT_FOUND%' THEN
        RAISE EXCEPTION 'FIXTURE 75 注入3 失败:删掉函数那道门之后,拒绝【仍然】来自函数(实得 %)—— 说明 B 臂拒它的不是那道门',
            COALESCE(v_msg, '(提交成功了,而且外键也没拦 —— 那是第二个问题)');
    END IF;
    IF v_msg NOT LIKE '%work_order%' OR v_msg NOT LIKE '%foreign key%' THEN
        RAISE EXCEPTION 'FIXTURE 75 注入3 失败:函数那道门删掉之后,应当由 processing_runs 的外键兜住,实得 %', v_msg;
    END IF;

    -- ══════════ 注入 2:把"只数没被冲销的"这个过滤【整个拿掉】════════════════
    -- 【这一臂的第一版写错了,而它自己把这件事查了出来 —— 所以过程留在这里】
    -- 第一版把过滤退回成 WO-1a 那句只看 `deleted_at IS NULL` 的写法,断言
    -- "取消应当重新被拦" —— 因为 WO-1b 的抬头当时声称那是一个被修掉的 bug。
    -- **取消成功了。** 原因是 `rollback_processing_run` 同时写 `status='reversed'`
    -- 与 `deleted_at = now()`,所以单看 deleted_at 已经把冲销掉的排除在外 ——
    -- 两个条件今天等价,WO-1a 在这一点上并没有错。那句抬头因此被改掉了
    -- (见 db/migrations/2026-08-16-wo1b-fu1-*.sql)。
    -- **一个注入本来是用来证明门有牙的;这一次它证明的是【描述错了】,
    --   而那同样是它该做的事。**
    -- 现在这一臂验的是真正成立的那条性质:把过滤【整个】拿掉,一次被冲销的加工
    -- 就会重新拦住取消 —— 也就是 D 臂④那条断言不是空转。
    -- (woRev 已经取消掉了,所以另造一张同形的。)
    DECLARE
        woRev2 uuid; v_ibx uuid; v_runx uuid;
    BEGIN
        v_res := create_work_order(
            jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 30)), NULL, d, 'f75 rev2');
        woRev2 := (v_res->>'work_order_id')::uuid;
        PERFORM release_work_order(woRev2);
        INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
        VALUES ('ZZ75-IB5', v_matA, v_sup, 50, 50, 'kg', d) RETURNING id INTO v_ibx;
        PERFORM reprice_inbound_batch(v_ibx, 1, 'SGD', NULL, 'f75 price');
        v_runx := commit_processing_run(d, 'f75 rev2 run', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ibx, 'quantity_consumed', 20)),
            jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 18)), 'weight', woRev2);
        PERFORM rollback_processing_run(v_runx, 'fixture:AUDEL-1b 之后理由必填');
        -- 修好的版本:取消得掉(这是 D 臂已经验过的,这里只作注入的对照起点)
        IF (SELECT status FROM processing_runs WHERE id = v_runx) <> 'reversed' THEN
            RAISE EXCEPTION 'FIXTURE 75 注入2 前提不成立:那次加工应当已经是 reversed';
        END IF;

        v_inj := replace(def_cancel,
            'WHERE work_order_id = p_work_order_id AND deleted_at IS NULL AND status = ''committed'';',
            'WHERE work_order_id = p_work_order_id;');
        IF v_inj = def_cancel THEN
            RAISE EXCEPTION 'FIXTURE 75 注入2 失败:在函数定义里没找到 WO_HAS_RUNS 那句过滤的原文 —— 这个注入什么也没改';
        END IF;
        EXECUTE v_inj;
        v_denied := false; v_msg := NULL;
        BEGIN PERFORM cancel_work_order(woRev2, '拿掉过滤之后再取消');
        EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
        IF NOT v_denied OR v_msg NOT LIKE 'WO_HAS_RUNS|%' THEN
            RAISE EXCEPTION 'FIXTURE 75 注入2 失败:拿掉"只数没被冲销的"那个过滤之后,一次被冲销的加工应当【重新拦住】取消 —— 实得 %。走不到这一步说明 D 臂④在空转',
                COALESCE(v_msg, '(取消成功了)');
        END IF;
    END;
END $$;
ROLLBACK;
