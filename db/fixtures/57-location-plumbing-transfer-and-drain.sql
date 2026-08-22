-- 57 库位管线(IOD-1):转移、自动排空、以及【那个把整个设计逼出来的场景】
--
-- 【B 臂是这份 fixture 存在的理由】IOD-1 的 survey 在本地重建上实测到:
--     收 100(未指定库位)→ 转移全部到真库位 → 卖 10
--   在 IOD-1 之前,那一笔销售当场 STK_NEGATIVE_BUCKET —— 因为"桶不许为负"
--   按 IS NOT DISTINCT FROM 分组,NULL 自成一桶,而销售一律写 NULL 桶。
--   也就是说【一次转移就能把消耗打坏】。B 臂把这个场景原样钉死,
--   免得以后有人把"转移"与"消耗认识库位"拆成两刀。
--
-- 各臂:
--   A 前提:批次、库位、初始桶都成立
--   B 【那个场景】收 → 全量转移 → 销售成功(靠排空)
--   C 转移成对:桶移动、remaining_qty 不动、两腿共享 pair_id
--   D 排空顺序:NULL 桶优先,再按库位 code 升序;逐桶一行;行和 = 请求量
--   E 暂扣保护:100 中扣 40,卖 61 按名拒、卖 60 成功
--   F 注销排空【所有】桶(含 on_hold)
--   G 转移 on_hold 桶,状态在目的地保持不变
--   H 冲销【逐行镜像】原始投料行的库位与状态,不按规则重算
--   I 超量转移 / 同库位转移,各自按名拒绝
--
-- 【延迟约束】整段回滚、从不 COMMIT,所以 DEFERRABLE 守卫默认不触发。
-- 需要它当场咬的臂,单独把它设成 IMMEDIATE(只设那一条:ledger 不变量必须
-- 留在延迟,否则成对写入的第一条腿就会把合法操作打回来)。
--
-- 日期无关。自带数据(README 第 2 条)。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_mat uuid; v_sup uuid;
    ib uuid; ob uuid; ob2 uuid; run1 uuid;
    locA uuid; locB uuid;
    v jsonb; v_n int; v_sum numeric; v_rem numeric; v_msg text; v_denied boolean;
    v_null_q numeric; v_a numeric; v_b numeric; v_held numeric;
    v_types text[]; v_locs text[];
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-57', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZFIX57-M', 'fixture 57 material', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO v_mat;
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FIXT-S57', 'Fixture Supplier 57', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    -- 【库位 code 故意让 A < B】—— D 臂断言的正是"按 code 升序"
    INSERT INTO storage_locations (code, name) VALUES ('ZZ57-A', 'rack A') RETURNING id INTO locA;
    INSERT INTO storage_locations (code, name) VALUES ('ZZ57-B', 'rack B') RETURNING id INTO locB;

    -- 【IOD-1b:B 臂这一批走 RPC 建】被钉住的那个场景必须走【操作员真正走的那扇门】,
    -- 否则它证明的是一条没人用的路径。其余各臂仍直插建批(fixture 以 postgres 跑,
    -- RLS 不生效),那是为了把这一臂的"同一扇门"这件事single out 出来。
    -- IOD-2:返回值从 uuid 变成 jsonb（{batch_id, warnings}）—— 这里只要批次号。
    ob := (create_output_batch(v_mat, 100, 'kg', CURRENT_DATE) ->> 'batch_id')::uuid;

    -- ══════════ A. 前提 ═════════════════════════════════════════════════════
    SELECT COALESCE(sum(qty_delta),0) INTO v_null_q FROM inventory_movements
     WHERE output_batch_id = ob AND location_id IS NULL AND stock_status = 'available';
    IF v_null_q <> 100 THEN
        RAISE EXCEPTION 'FIXTURE 57A 失败:新批次的 100 应当全部落在【未指定库位】的 available 桶里,实际 %', v_null_q;
    END IF;

    -- ══════════ B. 【那个场景】═══════════════════════════════════════════════
    PERFORM create_stock_transfer(p_qty => 100, p_to_location_id => locA, p_output_batch_id => ob);
    SELECT COALESCE(sum(qty_delta),0) INTO v_null_q FROM inventory_movements
     WHERE output_batch_id = ob AND location_id IS NULL AND stock_status = 'available';
    IF v_null_q <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 57B 失败:全量转移之后 NULL 桶应当是 0,实际 % —— 场景没摆出来,后面的断言就没有意义', v_null_q;
    END IF;
    -- 【这一笔在 IOD-1 之前必然炸】销售不带库位,而 NULL 桶已经空了
    v := record_output_sale(ob, 10, 5, (SELECT code FROM currencies WHERE is_base), NULL, NULL, CURRENT_DATE);
    SELECT COALESCE(sum(qty_delta),0) INTO v_a FROM inventory_movements
     WHERE output_batch_id = ob AND location_id = locA AND stock_status = 'available';
    IF v_a <> 90 THEN
        RAISE EXCEPTION 'FIXTURE 57B 失败:销售应当从真库位排空,A 桶应剩 90,实际 %', v_a;
    END IF;

    -- ══════════ C. 转移成对:桶移动、总量不动、pair_id 共享 ══════════════════
    SELECT remaining_qty INTO v_rem FROM output_batches WHERE id = ob;
    IF v_rem <> 90 THEN
        RAISE EXCEPTION 'FIXTURE 57C 失败:remaining_qty 应当只被销售改动(90),实际 %', v_rem;
    END IF;
    SELECT count(DISTINCT pair_id) INTO v_n FROM inventory_movements
     WHERE output_batch_id = ob AND movement_type IN ('transfer_out','transfer_in');
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 57C 失败:一次转移的两条腿应当共享一个 pair_id,实际 % 个', v_n;
    END IF;
    SELECT count(*) INTO v_n FROM inventory_movements
     WHERE output_batch_id = ob AND movement_type IN ('transfer_out','transfer_in');
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 57C 失败:一次转移应当恰好两行,实际 %', v_n;
    END IF;

    -- ══════════ D. 排空顺序:NULL 优先,再按 code 升序;逐桶一行 ═════════════
    -- 新批次:30 留在 NULL、40 去 A、30 去 B。消耗 80 应当依次吃掉
    -- NULL(30)→ A(40)→ B(10),写出三行。
    INSERT INTO output_batches (material_id, quantity, remaining_qty, unit, output_date)
    VALUES (v_mat, 100, 100, 'kg', CURRENT_DATE) RETURNING id INTO ob2;
    PERFORM create_stock_transfer(p_qty => 40, p_to_location_id => locA, p_output_batch_id => ob2);
    PERFORM create_stock_transfer(p_qty => 30, p_to_location_id => locB, p_output_batch_id => ob2);

    v := record_output_sale(ob2, 80, 5, (SELECT code FROM currencies WHERE is_base), NULL, NULL, CURRENT_DATE);

    -- 【顺序怎么断言 —— 不能按 created_at】同一个事务里所有行的 now() 完全相等,
    -- 按 (created_at, id) 排序等于按随机 uuid 排序(第一版就是这么假红的)。
    -- 所以断言【每个桶各被取走多少】:桶的初始量是 NULL=30 / A=40 / B=30,取 80。
    -- 只有"NULL 优先、再按 code 升序"这一种顺序会给出 30/40/10 ——
    -- A 先则得 40/30/10,B 先则得 30(B)/40(A)/10(NULL)。
    -- 也就是说这三个数【唯一确定】了顺序,而且它们与行的物理顺序无关,可复现。
    SELECT array_agg(x.code ORDER BY x.code), array_agg(x.q::text ORDER BY x.code)
      INTO v_locs, v_types
      FROM (SELECT COALESCE(l.code,'(NULL)') AS code, sum(m.qty_delta) AS q
              FROM inventory_movements m LEFT JOIN storage_locations l ON l.id = m.location_id
             WHERE m.output_batch_id = ob2 AND m.movement_type = 'sale'
             GROUP BY 1) x;
    SELECT count(*) INTO v_n FROM inventory_movements
     WHERE output_batch_id = ob2 AND movement_type = 'sale';
    IF v_n <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 57D 失败:80 跨三个桶应当写出【三行】销售流水(一桶一行),实际 % 行', v_n;
    END IF;
    -- 按 code 排序后:'(NULL)' < 'ZZ57-A' < 'ZZ57-B'
    IF v_locs <> ARRAY['(NULL)','ZZ57-A','ZZ57-B'] OR v_types <> ARRAY['-30','-40','-10'] THEN
        RAISE EXCEPTION 'FIXTURE 57D 失败:排空顺序应当是【NULL 桶优先,再按库位 code 升序】,于是各桶取 30/40/10;实际 % 取 %', v_locs, v_types;
    END IF;
    SELECT COALESCE(sum(qty_delta),0) INTO v_sum FROM inventory_movements
     WHERE output_batch_id = ob2 AND movement_type = 'sale';
    IF v_sum <> -80 THEN
        RAISE EXCEPTION 'FIXTURE 57D 失败:各行之和必须【正好】等于请求量 -80,实际 %', v_sum;
    END IF;

    -- ══════════ E. 暂扣保护:卖不动被扣住的货 ════════════════════════════════
    INSERT INTO output_batches (material_id, quantity, remaining_qty, unit, output_date)
    VALUES (v_mat, 100, 100, 'kg', CURRENT_DATE) RETURNING id INTO ib;   -- 复用变量:这里是产出批
    PERFORM hold_stock(p_qty => 40, p_reason => 'fixture 57 hold', p_output_batch_id => ib);

    v_denied := false; v_msg := NULL;
    BEGIN PERFORM record_output_sale(ib, 61, 5, (SELECT code FROM currencies WHERE is_base), NULL, NULL, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    -- SO-2:消息多了第四个数(已承诺)。这是【过期,不是回归】—— 拒绝要说出
    -- 每一个"货在那里但你动不了"的桶,而 committed 是第三个这样的桶;
    -- 少说一个数,屏幕上就会出现"可用 0、暂扣 0,可是卖不掉"。
    -- 段序:1=码 2=想卖 3=可用 4=暂扣 5=已承诺。
    IF NOT v_denied OR v_msg <> 'IOD_SALE_EXCEEDS_AVAILABLE|61|60|40|0' THEN
        RAISE EXCEPTION 'FIXTURE 57E 失败:卖 61 而只有 60 可用时,应当按名拒绝并【同时说出可用、暂扣与已承诺】(IOD_SALE_EXCEEDS_AVAILABLE|61|60|40|0),实际:%',
            CASE WHEN v_denied THEN v_msg ELSE '成功了 —— 被扣住的货被卖掉了' END;
    END IF;
    -- 60 必须卖得掉:拒绝的是"超过可用",不是"这批货有暂扣"
    v := record_output_sale(ib, 60, 5, (SELECT code FROM currencies WHERE is_base), NULL, NULL, CURRENT_DATE);
    SELECT COALESCE(sum(qty_delta),0) INTO v_held FROM inventory_movements
     WHERE output_batch_id = ib AND stock_status = 'on_hold';
    IF v_held <> 40 THEN
        RAISE EXCEPTION 'FIXTURE 57E 失败:卖掉全部可用之后,暂扣的 40 应当【原样还在】,实际 %', v_held;
    END IF;

    -- ══════════ F. 注销排空【所有】桶,含 on_hold ════════════════════════════
    -- AUDEL-1b:软删只能走门
    PERFORM soft_delete_output_batch(ib, 'fixture:AUDEL-1b 之后理由必填');
    SELECT COALESCE(sum(qty_delta),0) INTO v_held FROM inventory_movements
     WHERE output_batch_id = ib AND stock_status = 'on_hold';
    IF v_held <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 57F 失败:注销应当把【被扣住的那 40 也一并排空】—— 报废一批货不会因为其中一部分被扣住就留在账上,实际 on_hold 还剩 %', v_held;
    END IF;

    -- ══════════ G. 转移 on_hold 桶:状态在目的地保持不变 ═════════════════════
    INSERT INTO output_batches (material_id, quantity, remaining_qty, unit, output_date)
    VALUES (v_mat, 50, 50, 'kg', CURRENT_DATE) RETURNING id INTO ob2;
    PERFORM hold_stock(p_qty => 20, p_reason => 'fixture 57 G', p_output_batch_id => ob2);
    PERFORM create_stock_transfer(p_qty => 20, p_to_location_id => locA,
                                  p_output_batch_id => ob2, p_stock_status => 'on_hold');
    SELECT COALESCE(sum(qty_delta),0) INTO v_a FROM inventory_movements
     WHERE output_batch_id = ob2 AND location_id = locA AND stock_status = 'on_hold';
    IF v_a <> 20 THEN
        RAISE EXCEPTION 'FIXTURE 57G 失败:转移必须【保留状态】—— 被扣住的货换个货架仍然是被扣住的,目的地 on_hold 应为 20,实际 %', v_a;
    END IF;
    SELECT COALESCE(sum(qty_delta),0) INTO v_a FROM inventory_movements
     WHERE output_batch_id = ob2 AND location_id = locA AND stock_status = 'available';
    IF v_a <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 57G 失败:转移把 on_hold 的货变成了 available —— 状态不该被搬运改写';
    END IF;

    -- ══════════ H. 冲销【逐行镜像】原始投料行 ═══════════════════════════════
    -- 一张进料批分散在 NULL 与 A 两个桶,投料跨两桶 → 两行 consume;
    -- 回滚必须把货放回【原来那两个桶】,而不是按 drain 顺序倒推一遍。
    INSERT INTO inbound_batches (material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES (v_mat, v_sup, 100, 100, 'kg', CURRENT_DATE) RETURNING id INTO ib;
    PERFORM create_stock_transfer(p_qty => 60, p_to_location_id => locA, p_inbound_batch_id => ib);
    -- 此刻:NULL 40、A 60。投 70 → NULL 40 + A 30
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
    SELECT commit_processing_run(
        CURRENT_DATE, 'fixture 57 H', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', ib, 'quantity_consumed', 70)),
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 70)),
        'weight') INTO run1;

    SELECT count(*) INTO v_n FROM inventory_movements
     WHERE run_id = run1 AND movement_type = 'processing_consume';
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 57H 失败:跨两个桶的投料应当写出两行 consume,实际 %', v_n;
    END IF;

    PERFORM rollback_processing_run(run1, 'fixture:AUDEL-1b 之后理由必填');

    SELECT COALESCE(sum(qty_delta),0) INTO v_null_q FROM inventory_movements
     WHERE inbound_batch_id = ib AND location_id IS NULL AND stock_status = 'available';
    SELECT COALESCE(sum(qty_delta),0) INTO v_a FROM inventory_movements
     WHERE inbound_batch_id = ib AND location_id = locA AND stock_status = 'available';
    IF v_null_q <> 40 OR v_a <> 60 THEN
        RAISE EXCEPTION 'FIXTURE 57H 失败:回滚必须把货放回【它原来所在的那些桶】(NULL 40 / A 60),实际 NULL=% A=% —— 按规则重算而不是逐行镜像,差额会安静地把库存挪到别的库位上',
            v_null_q, v_a;
    END IF;

    -- ══════════ I. 超量转移 / 同库位转移,各自按名拒绝 ═══════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM create_stock_transfer(p_qty => 999, p_to_location_id => locB, p_inbound_batch_id => ib);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'IOD_TRANSFER_EXCEEDS_BUCKET|999|40' THEN
        RAISE EXCEPTION 'FIXTURE 57I 失败:超量转移应当按名拒绝(IOD_TRANSFER_EXCEEDS_BUCKET|999|40),实际:%',
            CASE WHEN v_denied THEN v_msg ELSE '成功了 —— 搬走了桶里没有的货' END;
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN PERFORM create_stock_transfer(p_qty => 10, p_to_location_id => locA,
                                        p_inbound_batch_id => ib, p_from_location_id => locA);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'IOD_TRANSFER_SAME_LOCATION' THEN
        RAISE EXCEPTION 'FIXTURE 57I 失败:源与目的相同的转移应当按名拒绝(IOD_TRANSFER_SAME_LOCATION)—— 它会写下两行互相抵消的流水,且几乎总意味着选错了一边。实际:%',
            CASE WHEN v_denied THEN v_msg ELSE '成功了' END;
    END IF;
END $$;
ROLLBACK;
