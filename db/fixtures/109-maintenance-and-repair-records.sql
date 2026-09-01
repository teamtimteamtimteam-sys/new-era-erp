-- 109 保养与维修记录 —— 指着钱,自己不过账;阈值现读,而它只建议
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据。每一臂自己造供应商 / 物料 /
-- 资产卡 / 停机 / 支出,【不从别处借】(README 第 2 条)。
--
-- 【每一臂建什么、钉什么】
-- F1 前提,先于一切派生量:**既有的三样一个字没变** ——
--    一炉加工照旧提交、一笔挂在资产上的支出照旧记、一段停机照旧建。
--    本刀只新建对象、不改任何既有东西,所以这一条若红了,说明改到了不该动的地方
--    (而 Tim 正在生产上走 EQP-1c-b)。
-- F2 一次例行保养 + 一次修理,都记得下、读得回、挂在对的机器上。
-- F3 D2 两个方向,【断言行,不只是断言插入没报错】:
--    (a) 一条保养记录【没有】停机;(b) 一段停机【没有】保养记录。两者都合法。
--    【这一臂【隔离不出来】,而理由值得写下来,不是含糊过去】
--    它断言的是【两件事都不是必需的】—— 而"不必需"的机制,就是【没有那条约束】。
--    没有东西可以摘掉:
--      * 唯一造得出来的注入是把 downtime_id 改成 NOT NULL,而它【先红在 F2】——
--        因为 F2 自己那条修理记录本来就没带停机,同一个自由已经被它用过了;
--      * 另一半(停机不需要保养记录)连注入都不存在:全库没有任何守卫要求
--        每段停机都配一条保养,要"破坏"它得先发明一条。
--    所以这一臂的价值不是"能被注入证伪",是【把意图写下来】:
--    下一个人若想给 downtime_id 加 NOT NULL、或给停机加一条"必须有保养"的守卫,
--    这两条断言会当场拦住他,并说出为什么两者都不该有。
-- F4 D4:说要资本化却不给理由 → 按【约束名】拒。
-- F5 D5:阈值【现读】—— 在同一个事务里改它,看结论两个方向都动,
--    并把边界钉死(正好等于阈值 → 达标;差一分 → 不达标)。
--    只调一个方向,一个"永远返回同一个答案"的实现也能过(fixture 76 的原话)。
-- F6 日期不默认:不给 performed_on 的记录进不去(NOT NULL 按名拒),
--    绝不会被悄悄盖上今天。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_ccy text;
    v_sup uuid; v_mat uuid; v_matB uuid; v_ib uuid; v_run uuid;
    v_asset uuid; v_res jsonb; v_exp uuid; v_exp2 uuid;
    v_dt uuid; v_m1 uuid; v_m2 uuid;
    v_n int; v_msg text; v_denied boolean;
    v_meets boolean; v_pct numeric; v_emp uuid;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-109', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX109-S', 'fixture 109 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES ('ZZFIX109-M', 'fixture 109 raw', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES ('ZZFIX109-MB', 'fixture 109 out', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_matB;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, employment_status)
    VALUES ('ZZFIX109-E', 'fixture 109 technician', 'full_time', 'shopfloor', CURRENT_DATE - 200, 'active')
    RETURNING id INTO v_emp;

    -- ══════════ F1 · 既有的三样一个字没变 ══════════════════════════════════
    RAISE NOTICE 'fixture 109 · 进入 F1';
    -- (a) 一炉加工照旧
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZFIX109-IB', v_mat, v_sup, 100, 100, 'kg', DATE '2026-06-01', 'other', 'fixture 109 自带数据') RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, v_ccy, NULL, 'fixture 109 price');
    -- PROC-3:这一支要投料,所以它的电池料批次得带一条【可投料】的安全状态。
    -- 【为什么是一条带 JOIN 的 SELECT,而不是逐个批次写死】本支里哪些批次【吃】
    -- 状态轴,由 material_kinds 回答 —— 实测 ewaste 可加工却【没有】状态轴,
    -- 所以"可加工"并不蕴含"有状态轴"。而没有状态轴的批次插安全状态会被
    -- PROC-2c 的适用性守卫按名拒,所以这个过滤不是优化,是正确性。
    -- 【它出现在每一次投料之前,而不是只在开头一次】批次是各臂【边跑边造】的,
    -- 开头那一次覆盖不到后面才出生的批次。NOT EXISTS 让它重复执行也不撞主键。
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT ib.id, 'discharged_verified'
      FROM inbound_batches ib
      JOIN materials m       ON m.id   = ib.material_id
      JOIN material_kinds mk ON mk.code = m.kind_code
     WHERE mk.has_condition_axes
       AND NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states s
                        WHERE s.inbound_batch_id = ib.id);
    v_run := commit_processing_run(DATE '2026-06-01', 'fixture 109 run', 20,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 80)), 'metal_value', NULL, NULL, 'manual_disassembly');
    SELECT count(*) INTO v_n FROM processing_runs WHERE id = v_run AND status = 'committed';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 109F1a 失败:一炉加工应当照旧提交 —— 本刀只新建对象,若这里红了说明改到了不该动的东西';
    END IF;

    -- (b) 一台机器 + 一笔挂在它身上的支出照旧
    v_res := create_fixed_asset('fixture 109 press', 120, DATE '2026-01-01');
    v_asset := (v_res->>'asset_id')::uuid;
    v_res := record_expense(DATE '2026-01-05', '1500', 100000, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'fixture 109 machine invoice', jsonb_build_object('asset_id', v_asset), NULL);
    SELECT cost_base INTO v_pct FROM fixed_assets WHERE id = v_asset;
    IF v_pct <> 100000 THEN
        RAISE EXCEPTION 'FIXTURE 109F1b 失败:挂在资产上的支出应当照旧把成本落上去(100,000),实得 %', v_pct;
    END IF;

    -- (c) 一段停机照旧
    INSERT INTO equipment_downtime (equipment_id, started_at, ended_at, reason)
    VALUES (v_asset, TIMESTAMPTZ '2026-06-10 08:00+08', TIMESTAMPTZ '2026-06-10 16:00+08', 'fixture 109 planned stop')
    RETURNING id INTO v_dt;
    SELECT count(*) INTO v_n FROM equipment_downtime WHERE id = v_dt AND duration = INTERVAL '8 hours';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 109F1c 失败:一段停机应当照旧建得出来、且自己算出长度';
    END IF;

    -- ══════════ F2 · 例行保养与修理,都记得下、读得回 ══════════════════════
    RAISE NOTICE 'fixture 109 · 进入 F2';
    INSERT INTO equipment_maintenance
        (equipment_id, performed_on, kind, description, performed_by_employee_id, downtime_id)
    VALUES (v_asset, DATE '2026-06-10', 'service', 'fixture 109 routine service', v_emp, v_dt)
    RETURNING id INTO v_m1;
    INSERT INTO equipment_maintenance
        (equipment_id, performed_on, kind, description, performed_by_supplier_id)
    VALUES (v_asset, DATE '2026-07-02', 'repair', 'fixture 109 bearing replacement', v_sup)
    RETURNING id INTO v_m2;

    SELECT count(*) INTO v_n FROM equipment_maintenance WHERE equipment_id = v_asset;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 109F2 失败:这台机器身上应当有 2 条记录,实得 %', v_n;
    END IF;
    SELECT count(*) INTO v_n FROM equipment_maintenance
     WHERE id = v_m1 AND kind = 'service' AND performed_by_employee_id = v_emp AND downtime_id = v_dt;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 109F2 失败:例行保养那一条读不回来'; END IF;
    SELECT count(*) INTO v_n FROM equipment_maintenance
     WHERE id = v_m2 AND kind = 'repair' AND performed_by_supplier_id = v_sup;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 109F2 失败:修理那一条读不回来'; END IF;

    -- 【谁做的:从不两个】
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO equipment_maintenance
            (equipment_id, performed_on, kind, description, performed_by_employee_id, performed_by_supplier_id)
        VALUES (v_asset, DATE '2026-07-03', 'repair', 'fixture 109 both performers', v_emp, v_sup);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('equipment_maintenance_performer_shape' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 109F2 失败:一件活不能同时由自己人和外包做,应被 equipment_maintenance_performer_shape 拒,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg,'(收下了)');
    END IF;
    -- 【至少说出一个】三列全空也拒 —— 否则"没记名字"与"没人填过"是同一个空格子
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO equipment_maintenance (equipment_id, performed_on, kind, description)
        VALUES (v_asset, DATE '2026-07-04', 'repair', 'fixture 109 nobody');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('equipment_maintenance_performer_shape' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 109F2 失败:三列全空应当被同一条约束拒(至少说出一个),实得 denied=% msg=%',
            v_denied, COALESCE(v_msg,'(收下了)');
    END IF;

    -- ══════════ F3 · D2 两个方向,断言【行】而不是断言插入没报错 ════════════
    RAISE NOTICE 'fixture 109 · 进入 F3';
    -- (a) 一条保养记录没有停机(v_m2 就是,上面没给 downtime_id)
    SELECT count(*) INTO v_n FROM equipment_maintenance WHERE id = v_m2 AND downtime_id IS NULL;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 109F3a 失败:一条【不带停机】的保养记录应当合法且读得回来 —— 计划停机里的保养不造成停机';
    END IF;
    -- (b) 一段停机没有任何保养记录
    INSERT INTO equipment_downtime (equipment_id, started_at, reason)
    VALUES (v_asset, TIMESTAMPTZ '2026-08-01 09:00+08', 'fixture 109 breakdown, nobody dispatched yet')
    RETURNING id INTO v_dt;
    SELECT count(*) INTO v_n FROM equipment_downtime d
     WHERE d.id = v_dt AND NOT EXISTS (SELECT 1 FROM equipment_maintenance m WHERE m.downtime_id = d.id);
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 109F3b 失败:一段【还没有人动手】的停机应当合法且读得回来 —— 故障可以在有人修它之前就被记下来';
    END IF;

    -- ══════════ F4 · 说要资本化,就得说为什么 ══════════════════════════════
    RAISE NOTICE 'fixture 109 · 进入 F4';
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO equipment_maintenance
            (equipment_id, performed_on, kind, description, performed_by_supplier_id, capitalised)
        VALUES (v_asset, DATE '2026-07-05', 'repair', 'fixture 109 overhaul', v_sup, true);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('equipment_maintenance_capitalisation_reason' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 109F4 失败:说要资本化却不给理由,应被 equipment_maintenance_capitalisation_reason 拒,实得 denied=% msg=% —— 一个没有理由的判断,在审计面前等于没有判断',
            v_denied, COALESCE(v_msg,'(收下了)');
    END IF;
    -- 给了理由就进得去(证明它是一道铰链,不是一堵墙)
    INSERT INTO equipment_maintenance
        (equipment_id, performed_on, kind, description, performed_by_supplier_id, capitalised, capitalisation_reason)
    VALUES (v_asset, DATE '2026-07-05', 'repair', 'fixture 109 overhaul', v_sup, true,
            'fixture 109: rebuilt the drive, adds an estimated three years of life');

    -- ══════════ F5 · 阈值【现读】,并且边界钉死 ════════════════════════════
    RAISE NOTICE 'fixture 109 · 进入 F5';
    -- 前提自己设成需要的样子(README 第 5 条):10% + 下限 1000。
    UPDATE maintenance_settings SET capitalise_pct_of_cost = 10, capitalise_floor_base = 1000;
    -- 机器记录成本 100,000 → 10% 边界正好是 10,000。
    -- 【正好等于阈值 → 达标】(判据是 >=,这一条把边界本身钉死)
    v_res := record_expense(DATE '2026-07-05', '6100', 10000, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'fixture 109 repair invoice at the boundary', NULL, NULL);
    v_exp := (v_res->>'expense_id')::uuid;
    UPDATE equipment_maintenance SET expense_id = v_exp WHERE id = v_m2;
    SELECT meets_threshold, pct_of_equipment_cost INTO v_meets, v_pct
      FROM equipment_maintenance_advice WHERE maintenance_id = v_m2;
    IF v_meets IS DISTINCT FROM true OR v_pct <> 10 THEN
        RAISE EXCEPTION 'FIXTURE 109F5 失败:10,000 / 100,000 = 10%% 正好等于阈值,应当【达标】,实得 meets=% pct=%',
            COALESCE(v_meets::text,'(null)'), v_pct;
    END IF;

    -- 【差一分 → 不达标】同一条记录换一张 9,999.99 的单
    v_res := record_expense(DATE '2026-07-06', '6100', 9999.99, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'fixture 109 repair invoice one cent below', NULL, NULL);
    v_exp2 := (v_res->>'expense_id')::uuid;
    UPDATE equipment_maintenance SET expense_id = v_exp2 WHERE id = v_m2;
    SELECT meets_threshold INTO v_meets FROM equipment_maintenance_advice WHERE maintenance_id = v_m2;
    IF v_meets IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FIXTURE 109F5 失败:比阈值差一分应当【不达标】,实得 % —— 边界要钉在边界上', COALESCE(v_meets::text,'(null)');
    END IF;

    -- 【现读:同一个事务里把阈值调低,同一条记录当场变达标】
    UPDATE maintenance_settings SET capitalise_pct_of_cost = 5;
    SELECT meets_threshold INTO v_meets FROM equipment_maintenance_advice WHERE maintenance_id = v_m2;
    IF v_meets IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FIXTURE 109F5 失败:阈值从 10%% 调到 5%% 之后,9,999.99 / 100,000 ≈ 10%% 应当变成【达标】,实得 % —— 把阈值写死的实现在这里给的是同一个答案',
            COALESCE(v_meets::text,'(null)');
    END IF;
    -- 【另一个方向也要】只调一个方向,"永远返回同一个答案"的实现也能过。
    UPDATE maintenance_settings SET capitalise_pct_of_cost = 50;
    SELECT meets_threshold INTO v_meets FROM equipment_maintenance_advice WHERE maintenance_id = v_m2;
    IF v_meets IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FIXTURE 109F5 失败:阈值调到 50%% 之后同一条记录应当变回【不达标】,实得 %', COALESCE(v_meets::text,'(null)');
    END IF;
    -- 【绝对下限也要现读,而且它与百分比是【并且】的关系】
    UPDATE maintenance_settings SET capitalise_pct_of_cost = 1, capitalise_floor_base = 50000;
    SELECT meets_threshold INTO v_meets FROM equipment_maintenance_advice WHERE maintenance_id = v_m2;
    IF v_meets IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FIXTURE 109F5 失败:百分比够了但没到绝对下限,应当【不达标】,实得 % —— 两个条件是【并且】,不是【或者】',
            COALESCE(v_meets::text,'(null)');
    END IF;
    -- 【没有花费的行不下断言 —— 空不是零】
    SELECT meets_threshold INTO v_meets FROM equipment_maintenance_advice WHERE maintenance_id = v_m1;
    IF v_meets IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 109F5 失败:没挂支出单的记录不该有结论(应为 NULL),实得 % —— 那不是"不达标",是"这件事还没有钱可谈"', v_meets;
    END IF;

    -- ══════════ F6 · 日期不默认 ════════════════════════════════════════════
    RAISE NOTICE 'fixture 109 · 进入 F6';
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO equipment_maintenance (equipment_id, kind, description, performed_by_supplier_id)
        VALUES (v_asset, 'repair', 'fixture 109 no date', v_sup);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('performed_on' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 109F6 失败:不给 performed_on 的记录应当被拒(NOT NULL,列名要出现在消息里),实得 denied=% msg=% —— 它绝不能被悄悄盖上今天:EQP-2c 的保养间隔要按它算下一次到期',
            v_denied, COALESCE(v_msg,'(收下了)');
    END IF;

    RAISE NOTICE 'fixture 109:F1–F6 通过';
END $$;
ROLLBACK;
