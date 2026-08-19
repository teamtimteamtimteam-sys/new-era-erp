-- 56 库存状态(STK-1):分桶算得对,而【物理总量按构造不动】
--
-- 【C 臂是这份 fixture 的心脏】其余各臂都是它的配套:
--     每一个批次,∑(各状态的派生数量) == 该批次存下来的 remaining_qty
-- 它在每一次暂扣/释放【之前和之后】都断言一遍。
--
-- 【为什么这一条能失败,而不是一句自证的空话】两边是两条【互相独立】的推导:
--   * 左边:现算 —— 按 stock_status 分组 sum(qty_delta),来自 stock_by_status;
--   * 右边:remaining_qty —— 批次上存下来的那个数,由 check_ledger_invariant
--          独立看守(它比的是"总和 vs 缓存",与状态维度完全无关)。
-- 两边可以分开动:任何一条【单边】的状态流水都会让左边变、右边不变。
-- 这正是 OPS-17 给 cash_flow_statement.ties 立的判据 —— 问一句"要怎样它们才会
-- 不相等",答得出来才算一条检查。D 臂就把那个"怎样"真的做出来。
--
-- 各臂:
--   A 前提:三件事先成立(批次存在、流水非空、既有行全是 available)
--   B 回填的历史行读作 available,且总量对得上
--   C 部分暂扣 → 分桶正确;释放 → 回到原样。不变量在每一步前后都断言
--   D 【故障注入】单边状态流水 —— 必须撞上【桶不许为负】那条新守卫
--   E 【故障注入】超量暂扣 / 超量释放 —— 各自按名拒绝
--   F 成对约束:状态变更行漏了 pair id、普通行误带 pair id,都被 CHECK 拒
--
-- 【关于延迟约束】本 fixture 整段回滚、从不 COMMIT,所以 DEFERRABLE 的守卫
-- 默认【一次也不会触发】—— 那会让 D 臂变成一句空话。所以 D 臂把那条新守卫
-- 单独设成 IMMEDIATE(只设它一个:check_ledger_invariant 必须留在延迟,
-- 否则成对写入的第一条腿就会把合法的暂扣打回来)。用完即恢复。
--
-- 日期无关。自带数据(README 第 2 条)。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_mat uuid; v_sup uuid; v_batch uuid;
    v_avail numeric; v_held numeric; v_rem numeric; v_sum numeric;
    v_n int; v_denied boolean; v_msg text;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-56', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO materials (code, name, category, unit)
    VALUES ('ZZFIX56-M', 'fixture 56 material', '进料-电池', 'kg') RETURNING id INTO v_mat;
    INSERT INTO suppliers (code, legal_name, country, counterparty_type) VALUES ('FIXT-S56', 'Fixture Supplier 56', 'SG', 'goods_supplier') RETURNING id INTO v_sup;

    -- 一张 100 kg 的进料批。**收货流水不用手写** —— 建批次时台账触发器自己发一条
    -- receipt(这一点本身就值得断言:A 臂数的就是它)。而它【不显式给 stock_status】,
    -- 靠列默认值落到 available:B 臂要证明的正是这条既有写入路径今天仍然成立,
    -- 没有被这一刀改掉语义。
    INSERT INTO inbound_batches (material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES (v_mat, v_sup, 100, 100, 'kg', CURRENT_DATE) RETURNING id INTO v_batch;

    -- ══════════ A. 前提 ═══════════════════════════════════════════════════
    -- 【先断前提,再断派生】下面每一条都建立在"这批货真的有 100 kg 流水"之上;
    -- 前提不成立时,C 臂的等式会因为两边同时为 0 而【空转通过】。
    SELECT count(*) INTO v_n FROM inventory_movements WHERE inbound_batch_id = v_batch;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 56A 失败:这批货应当恰有 1 条流水,实际 %', v_n;
    END IF;
    SELECT remaining_qty INTO v_rem FROM inbound_batches WHERE id = v_batch;
    IF v_rem <> 100 THEN
        RAISE EXCEPTION 'FIXTURE 56A 失败:remaining_qty 应当是 100,实际 %', v_rem;
    END IF;
    -- 全库不应存在任何非 available 的历史行(这一刀之前没有"暂扣"这个概念)
    SELECT count(*) INTO v_n FROM inventory_movements WHERE stock_status <> 'available';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 56A 失败:重建库里不该有任何非 available 的流水,实际 % 条', v_n;
    END IF;

    -- ══════════ B. 回填/默认值:老路子写出来的行读作 available ═══════════
    SELECT qty INTO v_avail FROM stock_by_status
     WHERE inbound_batch_id = v_batch AND stock_status = 'available';
    IF v_avail IS DISTINCT FROM 100 THEN
        RAISE EXCEPTION 'FIXTURE 56B 失败:没显式给 stock_status 的收货应当落在 available=100,实际 %',
            COALESCE(v_avail::text, 'NULL');
    END IF;
    -- 库位为空的那一桶【看得见】,不因为 location_id IS NULL 而消失
    SELECT count(*) INTO v_n FROM stock_by_status
     WHERE inbound_batch_id = v_batch AND location_id IS NULL;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 56B 失败:未指定库位的那一桶必须照样出现在视图里(线上今天【全部】流水都是这样),实际 % 行', v_n;
    END IF;

    -- ══════════ C. 部分暂扣 → 分桶;释放 → 回到原样。不变量前后都断言 ══════
    -- 暂扣【之前】
    SELECT COALESCE(sum(qty), 0) INTO v_sum FROM stock_by_status WHERE inbound_batch_id = v_batch;
    IF v_sum <> v_rem THEN
        RAISE EXCEPTION 'FIXTURE 56C 失败(暂扣前):各状态之和 % ≠ remaining_qty %', v_sum, v_rem;
    END IF;

    PERFORM hold_stock(p_qty => 40, p_reason => 'fixture 56 hold', p_inbound_batch_id => v_batch);

    SELECT qty INTO v_avail FROM stock_by_status
     WHERE inbound_batch_id = v_batch AND stock_status = 'available';
    SELECT qty INTO v_held FROM stock_by_status
     WHERE inbound_batch_id = v_batch AND stock_status = 'on_hold';
    IF v_avail IS DISTINCT FROM 60 OR v_held IS DISTINCT FROM 40 THEN
        RAISE EXCEPTION 'FIXTURE 56C 失败:暂扣 40 之后应当是 available=60 / on_hold=40,实际 % / %',
            COALESCE(v_avail::text, 'NULL'), COALESCE(v_held::text, 'NULL');
    END IF;
    -- 暂扣【之后】—— 物理总量一点没动,这正是"成对"买来的东西
    SELECT COALESCE(sum(qty), 0) INTO v_sum FROM stock_by_status WHERE inbound_batch_id = v_batch;
    SELECT remaining_qty INTO v_rem FROM inbound_batches WHERE id = v_batch;
    IF v_sum <> v_rem THEN
        RAISE EXCEPTION 'FIXTURE 56C 失败(暂扣后):各状态之和 % ≠ remaining_qty % —— 一次状态变更改动了物理总量', v_sum, v_rem;
    END IF;

    -- 释放一部分:回到 available
    PERFORM release_stock(p_qty => 40, p_inbound_batch_id => v_batch, p_note => 'fixture 56 release');
    SELECT qty INTO v_avail FROM stock_by_status
     WHERE inbound_batch_id = v_batch AND stock_status = 'available';
    IF v_avail IS DISTINCT FROM 100 THEN
        RAISE EXCEPTION 'FIXTURE 56C 失败:全部释放后 available 应当回到 100,实际 %',
            COALESCE(v_avail::text, 'NULL');
    END IF;
    -- 走空的桶不再列出(HAVING <> 0),这不是"数据丢了"
    SELECT count(*) INTO v_n FROM stock_by_status
     WHERE inbound_batch_id = v_batch AND stock_status = 'on_hold';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 56C 失败:释放干净之后 on_hold 那一桶不该再列出来,实际 % 行', v_n;
    END IF;
    SELECT COALESCE(sum(qty), 0) INTO v_sum FROM stock_by_status WHERE inbound_batch_id = v_batch;
    SELECT remaining_qty INTO v_rem FROM inbound_batches WHERE id = v_batch;
    IF v_sum <> v_rem THEN
        RAISE EXCEPTION 'FIXTURE 56C 失败(释放后):各状态之和 % ≠ remaining_qty %', v_sum, v_rem;
    END IF;

    -- ══════════ D. 故障注入:单边状态流水撞【桶不许为负】═══════════════════
    -- 【必须先把那条守卫设成 IMMEDIATE】否则整段回滚、从不 COMMIT,延迟约束
    -- 一次也不会触发,这一臂就成了空话。只设它一个:check_ledger_invariant
    -- 留在延迟,否则合法暂扣的第一条腿就会被它打回来。
    SET CONSTRAINTS trg_inventory_movements_no_negative_bucket IMMEDIATE;

    v_denied := false; v_msg := NULL;
    BEGIN
        -- 单边:只写"出 on_hold"的那条腿,而此刻 on_hold 是 0 —— 桶会变成 -25
        INSERT INTO inventory_movements
            (inbound_batch_id, movement_type, qty_delta, stock_status, pair_id, business_date)
        VALUES (v_batch, 'status_change_out', -25, 'on_hold', gen_random_uuid(), CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'STK_NEGATIVE_BUCKET|%' THEN
        RAISE EXCEPTION 'FIXTURE 56D 失败:单边状态流水应当撞上【桶不许为负】(STK_NEGATIVE_BUCKET),实际:%',
            CASE WHEN v_denied THEN v_msg ELSE '成功了 —— 一个桶被写成了负数,而没有任何东西拦它' END;
    END IF;

    SET CONSTRAINTS trg_inventory_movements_no_negative_bucket DEFERRED;

    -- ══════════ E. 故障注入:超量暂扣 / 超量释放,各自按名拒绝 ═════════════
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM hold_stock(p_qty => 101, p_reason => 'too much', p_inbound_batch_id => v_batch);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'STK_HOLD_EXCEEDS_AVAILABLE|101|100' THEN
        RAISE EXCEPTION 'FIXTURE 56E 失败:超量暂扣应当按名拒绝(STK_HOLD_EXCEEDS_AVAILABLE|101|100),实际:%',
            CASE WHEN v_denied THEN v_msg ELSE '成功了 —— 扣掉了比现有更多的货' END;
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN PERFORM release_stock(p_qty => 1, p_inbound_batch_id => v_batch);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'STK_RELEASE_EXCEEDS_HELD|1|0' THEN
        RAISE EXCEPTION 'FIXTURE 56E 失败:没有扣住任何货时的释放应当按名拒绝(STK_RELEASE_EXCEEDS_HELD|1|0),实际:%',
            CASE WHEN v_denied THEN v_msg ELSE '成功了 —— 释放了并不存在的暂扣' END;
    END IF;

    -- 暂扣必须带理由 —— 一次没有理由的扣货,过两天没人说得清该不该放
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM hold_stock(p_qty => 10, p_reason => '   ', p_inbound_batch_id => v_batch);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'STK_REASON_REQUIRED' THEN
        RAISE EXCEPTION 'FIXTURE 56E 失败:没有理由的暂扣应当被拒(STK_REASON_REQUIRED),实际:%',
            CASE WHEN v_denied THEN v_msg ELSE '成功了' END;
    END IF;

    -- ══════════ F. 成对约束:两个方向都拦 ═════════════════════════════════
    v_denied := false;
    BEGIN
        -- 状态变更行【漏了】配对 id
        INSERT INTO inventory_movements
            (inbound_batch_id, movement_type, qty_delta, stock_status, business_date)
        VALUES (v_batch, 'status_change_in', 5, 'on_hold', CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 56F 失败:状态变更行没有 pair_id 应当被 CHECK 拒 —— 没有配对 id 的状态行,事后无从证明它有没有另一条腿';
    END IF;

    v_denied := false;
    BEGIN
        -- 普通行【误带】配对 id
        INSERT INTO inventory_movements
            (inbound_batch_id, movement_type, qty_delta, pair_id, business_date)
        VALUES (v_batch, 'receipt', 5, gen_random_uuid(), CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 56F 失败:普通流水带 pair_id 应当被 CHECK 拒(配对列只属于状态变更行)';
    END IF;
END $$;
ROLLBACK;
