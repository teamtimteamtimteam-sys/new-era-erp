-- 58 建批次只有一扇门(IOD-1b):RPC 带库位,而侧门是关着的
--
-- 【C 臂是这份 fixture 的要点】三个 RPC 能不能带库位,是这一刀的功能;
-- 而【客户端直插被拒】是这一刀真正买到的东西 —— IOD-2 要在"货落进哪个库位"
-- 上设闸,**一个留着侧门的卡口不是卡口**。今天把门收成一扇,IOD-2 只需在
-- 这一扇门上加判断,不必再去追有没有第二条路径绕过它。
-- 这一臂因此不是"顺便测一下权限",它是明天那句话能不能成立的全部依据。
--
-- 【IOD-2 已经落闸(2026-08-13),所以 C/F 两臂从"为明天铺路"变成"守住今天"】
-- 判断加在了这一扇门上(check_location_class,行为见 fixture 59)。侧门一旦
-- 重新打开,那道闸就有了绕过去的路 —— F 臂守的正是这个。
-- 另:三个 RPC 的返回值从 uuid 变成 jsonb（{batch_id, warnings}），本文件取
-- ->>'batch_id'。
--
-- 各臂:
--   A 前提:库位存在且在用;分类字典非空(IOD-2 会用到,先确认地基)
--   B 三个 RPC 各自带库位建批 → 收货流水带着那个库位
--   C 不给库位 → 落在【未指定】桶(一等状态,不是缺失)
--   D commit_processing_run 不受影响 —— 【验证,不是假定】:撤掉 INSERT 策略
--     之后,它仍然建得出产出批(它是 DEFINER,以属主身份写入)
--   E 停用库位 / 不存在的库位 → 各自按名拒绝
--   F 【侧门】以 authenticated 身份直插两张批次表 → 都必须被 RLS 拒
--
-- 日期无关。自带数据(README 第 2 条)。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_mat uuid; v_sup uuid; v_loc uuid; v_loc2 uuid;
    b uuid; ob uuid; run1 uuid;
    v_got uuid; v_n int; v_msg text; v_denied boolean; d date := CURRENT_DATE;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-58', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZFIX58-M', 'fixture 58 material', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO v_mat;
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FIXT-S58', 'Fixture Supplier 58', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO storage_locations (code, name) VALUES ('ZZ58-A', 'rack A') RETURNING id INTO v_loc;
    INSERT INTO storage_locations (code, name, is_active) VALUES ('ZZ58-OFF', 'retired rack', false) RETURNING id INTO v_loc2;

    -- ══════════ A. 前提 ═════════════════════════════════════════════════════
    IF NOT EXISTS (SELECT 1 FROM storage_locations WHERE id = v_loc AND is_active) THEN
        RAISE EXCEPTION 'FIXTURE 58A 失败:前提不成立 —— 目标库位应当存在且在用';
    END IF;
    SELECT count(*) INTO v_n FROM waste_classifications;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'FIXTURE 58A 失败:分类字典为空 —— IOD-2 的判据将建立在它上面,地基先确认';
    END IF;

    -- ══════════ B. 三个 RPC 各自带库位 ═══════════════════════════════════════
    b := (create_inbound_batch(v_mat, v_sup, 100, 'kg', d, '待加工', NULL, NULL, NULL, NULL, v_loc, p_source_reason_code => 'other', p_source_reason_note => 'fixture 58 自带数据') ->> 'batch_id')::uuid;
    SELECT location_id INTO v_got FROM inventory_movements
     WHERE inbound_batch_id = b AND movement_type = 'receipt';
    IF v_got IS DISTINCT FROM v_loc THEN
        RAISE EXCEPTION 'FIXTURE 58B 失败:create_inbound_batch 的库位没有落到收货流水上(得到 %)', COALESCE(v_got::text,'NULL');
    END IF;

    b := (receive_inbound_batch_against_po(v_mat, v_sup, 60, d, NULL, NULL, NULL, v_loc, p_source_reason_code => 'other', p_source_reason_note => 'fixture 58 自带数据') ->> 'batch_id')::uuid;
    SELECT location_id INTO v_got FROM inventory_movements
     WHERE inbound_batch_id = b AND movement_type = 'receipt';
    IF v_got IS DISTINCT FROM v_loc THEN
        RAISE EXCEPTION 'FIXTURE 58B 失败:receive_inbound_batch_against_po 的库位没有落到收货流水上(得到 %)', COALESCE(v_got::text,'NULL');
    END IF;

    ob := (create_output_batch(v_mat, 40, 'kg', d, '库存中', NULL, NULL, NULL, v_loc) ->> 'batch_id')::uuid;
    SELECT location_id INTO v_got FROM inventory_movements
     WHERE output_batch_id = ob AND movement_type = 'receipt';
    IF v_got IS DISTINCT FROM v_loc THEN
        RAISE EXCEPTION 'FIXTURE 58B 失败:create_output_batch 的库位没有落到收货流水上(得到 %)', COALESCE(v_got::text,'NULL');
    END IF;

    -- ══════════ C. 不给库位 → 未指定桶 ═══════════════════════════════════════
    b := (create_inbound_batch(v_mat, v_sup, 25, 'kg', d, p_source_reason_code => 'other', p_source_reason_note => 'fixture 58 自带数据') ->> 'batch_id')::uuid;
    SELECT location_id INTO v_got FROM inventory_movements
     WHERE inbound_batch_id = b AND movement_type = 'receipt';
    IF v_got IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 58C 失败:不选库位应当落在【未指定】桶(NULL),实际 %', v_got;
    END IF;
    -- 而它在分布视图里【看得见】,不是消失了
    SELECT count(*) INTO v_n FROM stock_by_status
     WHERE inbound_batch_id = b AND location_id IS NULL;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 58C 失败:未指定库位的那一桶必须照样出现在分布视图里,实际 % 行', v_n;
    END IF;

    -- ══════════ D. commit_processing_run 不受影响(验证,不是假定)═══════════
    -- 撤掉客户端 INSERT 策略之后,它仍然建得出产出批 —— 它是 DEFINER,
    -- 以属主身份写入,面向 authenticated 的 RLS 策略对它本就不适用。
    b := (create_inbound_batch(v_mat, v_sup, 80, 'kg', d, p_source_reason_code => 'other', p_source_reason_note => 'fixture 58 自带数据') ->> 'batch_id')::uuid;
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
    SELECT commit_processing_run(d, 'fixture 58 D', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', b, 'quantity_consumed', 80)),
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 80)),
        'weight', NULL, NULL, 'manual_disassembly') INTO run1;
    SELECT count(*) INTO v_n FROM processing_outputs WHERE run_id = run1;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 58D 失败:撤掉 INSERT 策略之后 commit_processing_run 应当照样建得出产出批,实际 % 条产出腿 —— 这一刀把客户端的门关了,不该把加工那条内部路径一起关掉', v_n;
    END IF;

    -- ══════════ E. 停用 / 不存在的库位,各自按名拒绝 ═════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM create_inbound_batch(v_mat, v_sup, 10, 'kg', d, NULL, NULL, NULL, NULL, NULL, v_loc2, p_source_reason_code => 'other', p_source_reason_note => 'fixture 58 自带数据');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'IOD_RECEIPT_LOCATION_INACTIVE|ZZ58-OFF' THEN
        RAISE EXCEPTION 'FIXTURE 58E 失败:收货进【停用】库位应当按名拒绝(IOD_RECEIPT_LOCATION_INACTIVE|ZZ58-OFF),实际:%',
            CASE WHEN v_denied THEN v_msg ELSE '成功了 —— 货落进了一个已经停用的库位' END;
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN PERFORM create_output_batch(v_mat, 10, 'kg', d, NULL, NULL, NULL, NULL, gen_random_uuid());
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'IOD_RECEIPT_LOCATION_UNKNOWN' THEN
        RAISE EXCEPTION 'FIXTURE 58E 失败:收货进【不存在】的库位应当按名拒绝(IOD_RECEIPT_LOCATION_UNKNOWN),实际:%',
            CASE WHEN v_denied THEN v_msg ELSE '成功了' END;
    END IF;

    -- ══════════ F. 【侧门】客户端直插必须被拒 ════════════════════════════════
    -- 这一臂是 IOD-2 那句"卡口"能不能成立的全部依据。
    -- 【必须切数据库角色】fixture 以 postgres 跑,而 postgres 是超级用户,
    -- RLS 对它完全不生效 —— 不切角色,这一臂就是在证明空话(README 第 6 条)。
    v_denied := false; v_msg := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        INSERT INTO inbound_batches (material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
        VALUES (v_mat, v_sup, 5, 5, 'kg', d, 'other', 'fixture 58 自带数据');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    RESET ROLE;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 58F 失败:客户端直插 inbound_batches 应当被 RLS 拒 —— 侧门开着,IOD-2 的"卡口"就只是一句话';
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        INSERT INTO output_batches (material_id, quantity, remaining_qty, unit, output_date)
        VALUES (v_mat, 5, 5, 'kg', d);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    RESET ROLE;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 58F 失败:客户端直插 output_batches 应当被 RLS 拒 —— 侧门开着,IOD-2 的"卡口"就只是一句话';
    END IF;

    -- 而【经由 RPC】的同一件事必须仍然做得到(拒的是侧门,不是这件事本身)
    b := (create_inbound_batch(v_mat, v_sup, 5, 'kg', d, p_source_reason_code => 'other', p_source_reason_note => 'fixture 58 自带数据') ->> 'batch_id')::uuid;
    IF b IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 58F 失败:关掉侧门之后,正门也走不通了';
    END IF;
END $$;
ROLLBACK;
