-- 108 机器做过什么 —— 归属、用量推导、以及停机是它自己的一张表
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据。每一臂自己造供应商 / 物料 /
-- 进料批次 / 资产卡 / 加工,【不从别处借】,也不吃别的臂的状态(README 第 2 条)。
--
-- 【每一臂建什么、钉什么】
-- F1 前提,先于一切派生量:**不给机器 id 的加工,逐字照旧**。
--    建:供应商 + 物料 + 一个进料批次 + 一炉加工。钉:炉子建出来了、
--    equipment_id 为空、投入腿与产出腿照常、批次余量照常扣。
--    本刀换了 commit_processing_run 的签名,所以"常态那条路没动"必须先证明。
--    (整套既有加工 fixture 18/19/… 由闸门在同一跑里复核,那是这一条的另一半。)
-- F2 正题:建一台【已投用】的机器 + 一炉归给它的加工。
--    钉:链接落库,且 equipment_usage 把它算进去(炉数 1、投入公斤 = 那一炉的)。
-- F3 D1 的边界,【三种情形一起钉才说明它是一个铰链】:
--    (a) 加工日早于取得日 → 按名拒 EQUIPMENT_NOT_ACQUIRED;
--    (b) 取得了、【但还没投用】→ **允许**(试车)—— 这是本刀对原设计改动最大的一处;
--    (c) 已处置之后 → 按名拒 EQUIPMENT_DISPOSED。
--    只钉 (a)(c) 而不钉 (b),就分不出"边界钉在取得日"还是"钉在投用日"。
-- F4 D2:被回滚的炉子【不算数】。断言回滚【前】与【后】两个数,
--    而不是只断言"有个过滤器"。
-- F5 D3:停机。开口的一段表示得出来且读得回来;闭合的一段自己算出长度;
--    倒着走的一段按名拒;同一台机器【第二段开口】被那条部分唯一索引拒。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_ccy text; v_today date := DATE '2027-05-10';
    v_sup uuid; v_mat uuid; v_matB uuid;
    v_ib uuid; v_run uuid; v_run2 uuid;
    v_asset uuid; v_asset2 uuid; v_res jsonb;
    v_eq uuid; v_n int; v_kg numeric; v_kg2 numeric;
    v_msg text; v_denied boolean; v_dur interval; v_dt uuid;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-108', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX108-S', 'fixture 108 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES ('ZZFIX108-M', 'fixture 108 raw', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES ('ZZFIX108-MB', 'fixture 108 out', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_matB;

    -- ══════════ F1 · 不给机器 id 的加工,逐字照旧 ═══════════════════════════
    RAISE NOTICE 'fixture 108 · 进入 F1';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZFIX108-IB1', v_mat, v_sup, 100, 100, 'kg', v_today) RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, v_ccy, NULL, 'fixture 108 price');

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
    v_run := commit_processing_run(v_today, 'fixture 108 unattributed', 20,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 80)), 'metal_value');

    SELECT equipment_id INTO v_eq FROM processing_runs WHERE id = v_run;
    IF v_eq IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 108F1 失败:不给机器 id 的加工,equipment_id 应当为空,实得 % —— 本刀换了这个函数的签名,常态那条路若已经变了,后面每一条都不必再看', v_eq;
    END IF;
    SELECT count(*) INTO v_n FROM processing_inputs WHERE run_id = v_run;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 108F1 失败:投入腿应当照常建出 1 条,实得 %', v_n; END IF;
    SELECT count(*) INTO v_n FROM processing_outputs WHERE run_id = v_run;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 108F1 失败:产出腿应当照常建出 1 条,实得 %', v_n; END IF;
    SELECT remaining_qty INTO v_kg FROM inbound_batches WHERE id = v_ib;
    IF v_kg <> 0 THEN RAISE EXCEPTION 'FIXTURE 108F1 失败:批次余量应当照常扣到 0,实得 %', v_kg; END IF;

    -- ══════════ F2 · 归给一台已投用的机器,用量算得进去 ══════════════════════
    RAISE NOTICE 'fixture 108 · 进入 F2';
    v_res := create_fixed_asset('fixture 108 furnace', 120, DATE '2027-01-01');
    v_asset := (v_res->>'asset_id')::uuid;
    -- 给它一点成本再投用(零成本卡投不了用 —— EQP-1c-a 的 ASSET_HAS_NO_COST)
    PERFORM record_expense(DATE '2027-01-05', '1500', 50000, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'fixture 108 machine invoice', jsonb_build_object('asset_id', v_asset), NULL);
    PERFORM set_asset_in_service(v_asset, DATE '2027-02-01');

    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZFIX108-IB2', v_mat, v_sup, 60, 60, 'kg', v_today) RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, v_ccy, NULL, 'fixture 108 price 2');
    -- PROC-3:同上 —— 这一臂之前又造了新批次,补上可投料的安全状态。
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT ib.id, 'discharged_verified'
      FROM inbound_batches ib
      JOIN materials m       ON m.id   = ib.material_id
      JOIN material_kinds mk ON mk.code = m.kind_code
     WHERE mk.has_condition_axes
       AND NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states s
                        WHERE s.inbound_batch_id = ib.id);
    v_run := commit_processing_run(v_today, 'fixture 108 attributed', 10,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 60)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 50)), 'metal_value',
        NULL, v_asset);

    SELECT equipment_id INTO v_eq FROM processing_runs WHERE id = v_run;
    IF v_eq IS DISTINCT FROM v_asset THEN
        RAISE EXCEPTION 'FIXTURE 108F2 失败:归属没有落库,实得 %', COALESCE(v_eq::text,'(null)');
    END IF;
    SELECT run_count, input_kg INTO v_n, v_kg FROM equipment_usage WHERE equipment_id = v_asset;
    IF v_n <> 1 OR v_kg <> 60 THEN
        RAISE EXCEPTION 'FIXTURE 108F2 失败:用量推导应当算进这一炉(1 炉 / 60 kg),实得 % 炉 / % kg', v_n, v_kg;
    END IF;

    -- ══════════ F3 · 边界:取得日,而不是投用日 ═══════════════════════════════
    RAISE NOTICE 'fixture 108 · 进入 F3';
    -- (a) 加工日早于取得日 → 拒
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZFIX108-IB3', v_mat, v_sup, 10, 10, 'kg', DATE '2026-12-01') RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, v_ccy, NULL, 'fixture 108 price 3');
    v_denied := false; v_msg := NULL;
    BEGIN
        -- PROC-3:同上 —— 这一臂之前又造了新批次,补上可投料的安全状态。
        INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
        SELECT ib.id, 'discharged_verified'
          FROM inbound_batches ib
          JOIN materials m       ON m.id   = ib.material_id
          JOIN material_kinds mk ON mk.code = m.kind_code
         WHERE mk.has_condition_axes
           AND NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states s
                            WHERE s.inbound_batch_id = ib.id);
        PERFORM commit_processing_run(DATE '2026-12-01', 'fixture 108 before acquisition', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 10)),
            jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 10)), 'metal_value',
            NULL, v_asset);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('EQUIPMENT_NOT_ACQUIRED' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 108F3a 失败:加工日早于取得日应按名拒 EQUIPMENT_NOT_ACQUIRED,实得 denied=% msg=% —— 那天这台机器还不是我们的',
            v_denied, COALESCE(v_msg,'(收下了)');
    END IF;

    -- (b) 【取得了、但还没投用 → 允许】这是本刀对原设计改动最大的一处:
    --     试车是这盘生意里一件有名有姓的事,而它正好证明投用日。
    v_res := create_fixed_asset('fixture 108 commissioning rig', 60, DATE '2027-03-01');
    v_asset2 := (v_res->>'asset_id')::uuid;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZFIX108-IB4', v_mat, v_sup, 30, 30, 'kg', DATE '2027-03-15') RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, v_ccy, NULL, 'fixture 108 price 4');
    -- PROC-3:同上 —— 这一臂之前又造了新批次,补上可投料的安全状态。
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT ib.id, 'discharged_verified'
      FROM inbound_batches ib
      JOIN materials m       ON m.id   = ib.material_id
      JOIN material_kinds mk ON mk.code = m.kind_code
     WHERE mk.has_condition_axes
       AND NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states s
                        WHERE s.inbound_batch_id = ib.id);
    v_run2 := commit_processing_run(DATE '2027-03-15', 'fixture 108 trial run', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 30)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 30)), 'metal_value',
        NULL, v_asset2);
    SELECT in_service_date INTO v_today FROM fixed_assets WHERE id = v_asset2;
    IF v_today IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 108F3b 前提失败:这台机器本该【还没投用】,实得投用日 %', v_today;
    END IF;
    SELECT equipment_id INTO v_eq FROM processing_runs WHERE id = v_run2;
    IF v_eq IS DISTINCT FROM v_asset2 THEN
        RAISE EXCEPTION 'FIXTURE 108F3b 失败:【尚未投用】的机器应当归得上试车那一炉,实得 % —— 拒掉它,系统就记不下那些正好用来证明投用日的加工,也丢掉了那段真实的磨损(EQP-2b 的保养间隔要读它)',
            COALESCE(v_eq::text,'(null)');
    END IF;

    -- (c) 已处置之后 → 拒
    -- 先给它成本再投用、再处置(零成本卡投不了用也处置不了 —— EQP-1c-a)。
    PERFORM record_expense(DATE '2027-03-02', '1500', 9000, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'fixture 108 rig invoice', jsonb_build_object('asset_id', v_asset2), NULL);
    PERFORM set_asset_in_service(v_asset2, DATE '2027-03-20');
    PERFORM dispose_fixed_asset(v_asset2, DATE '2027-04-01', 0, NULL, 'fixture 108 scrap');
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZFIX108-IB5', v_mat, v_sup, 10, 10, 'kg', DATE '2027-04-15') RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, v_ccy, NULL, 'fixture 108 price 5');
    v_denied := false; v_msg := NULL;
    BEGIN
        -- PROC-3:同上 —— 这一臂之前又造了新批次,补上可投料的安全状态。
        INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
        SELECT ib.id, 'discharged_verified'
          FROM inbound_batches ib
          JOIN materials m       ON m.id   = ib.material_id
          JOIN material_kinds mk ON mk.code = m.kind_code
         WHERE mk.has_condition_axes
           AND NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states s
                            WHERE s.inbound_batch_id = ib.id);
        PERFORM commit_processing_run(DATE '2027-04-15', 'fixture 108 after disposal', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 10)),
            jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 10)), 'metal_value',
            NULL, v_asset2);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('EQUIPMENT_DISPOSED' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 108F3c 失败:加工日晚于处置日应按名拒 EQUIPMENT_DISPOSED,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg,'(收下了)');
    END IF;

    -- ══════════ F4 · 被回滚的炉子不算数(断言前后两个数)══════════════════════
    RAISE NOTICE 'fixture 108 · 进入 F4';
    SELECT run_count, input_kg INTO v_n, v_kg FROM equipment_usage WHERE equipment_id = v_asset;
    IF v_n <> 1 OR v_kg <> 60 THEN
        RAISE EXCEPTION 'FIXTURE 108F4 前提失败:回滚【之前】应当是 1 炉 / 60 kg,实得 % / %', v_n, v_kg;
    END IF;
    PERFORM rollback_processing_run(v_run, 'fixture 108 rollback');
    SELECT run_count, input_kg INTO v_n, v_kg2 FROM equipment_usage WHERE equipment_id = v_asset;
    IF v_n <> 0 OR v_kg2 <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 108F4 失败:回滚【之后】那一炉不该再算数(应 0 炉 / 0 kg),实得 % / % —— 判据是 status=''committed'' AND deleted_at IS NULL 两列一起看',
            v_n, v_kg2;
    END IF;
    -- 判据的两列确实同源:rollback 在同一条 UPDATE 里写下它们。
    SELECT count(*) INTO v_n FROM processing_runs
     WHERE id = v_run AND status = 'reversed' AND deleted_at IS NOT NULL;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 108F4 失败:回滚应当【同时】置 reversed 与 deleted_at(两个标记同源),实得 %', v_n;
    END IF;

    -- ══════════ F5 · 停机:开口、闭合、倒着走、以及第二段开口 ════════════════
    RAISE NOTICE 'fixture 108 · 进入 F5';
    -- 开口的一段:表示得出来,也读得回来
    INSERT INTO equipment_downtime (equipment_id, started_at, reason)
    VALUES (v_asset, TIMESTAMPTZ '2027-05-01 09:00+08', 'fixture 108 bearing failure')
    RETURNING id INTO v_dt;
    SELECT ended_at, duration INTO v_today, v_dur FROM equipment_downtime WHERE id = v_dt;
    IF v_today IS NOT NULL OR v_dur IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 108F5 失败:一段【还没结束】的停机,结束时刻与长度都应当是 NULL —— 那不是零,是"还不知道"';
    END IF;

    -- 同一台机器的【第二段开口】—— 机器不会同时坏两次
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO equipment_downtime (equipment_id, started_at, reason)
        VALUES (v_asset, TIMESTAMPTZ '2027-05-02 09:00+08', 'fixture 108 second open');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('uq_equipment_downtime_open' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 108F5 失败:同一台机器不该有第二段【没结束】的停机,应撞上 uq_equipment_downtime_open,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg,'(收下了)');
    END IF;

    -- 闭合它:长度自己算出来
    UPDATE equipment_downtime SET ended_at = TIMESTAMPTZ '2027-05-01 17:30+08' WHERE id = v_dt;
    SELECT duration INTO v_dur FROM equipment_downtime WHERE id = v_dt;
    IF v_dur <> INTERVAL '8 hours 30 minutes' THEN
        RAISE EXCEPTION 'FIXTURE 108F5 失败:闭合之后长度应当是 8:30(09:00 → 17:30),实得 % —— 它是两个记下来的事实之差,不需要任何判断(而可用率需要一个没人选过的分母,所以本刀不算)', v_dur;
    END IF;

    -- 倒着走的一段:按名拒
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO equipment_downtime (equipment_id, started_at, ended_at, reason)
        VALUES (v_asset, TIMESTAMPTZ '2027-05-03 12:00+08', TIMESTAMPTZ '2027-05-03 08:00+08', 'fixture 108 backwards');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('equipment_downtime_period_order' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 108F5 失败:结束早于开始的一段应被 equipment_downtime_period_order 拒,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg,'(收下了)');
    END IF;

    RAISE NOTICE 'fixture 108:F1/F2/F3/F4/F5 通过';
END $$;
ROLLBACK;
