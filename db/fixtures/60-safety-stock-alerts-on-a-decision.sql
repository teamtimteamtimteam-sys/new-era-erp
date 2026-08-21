-- 60 安全库存告警(SS-1):【空着的阈值不是零】,而暂扣救不了缺货
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 真正钉住的东西 —— D 臂】
-- safety_stock_qty IS NULL 的意思是"还没有人决定要盯这个物料",不是"阈值为零"。
-- 两者在屏幕上长得一模一样(都不告警),所以【只有一条断言能把它们分开】:
-- 一个 NULL 阈值、库存为零的物料,必须【不出现】在这支臂里。
-- 把 NULL 当成 0 的实现(`available < COALESCE(threshold, 0)`)在其他每一条断言上
-- 都通得过 —— 唯独 D 臂红。这是 METAL-1 的 no_reference 那一课的又一次:
-- 一个不会响的检查比没有检查更坏,因为人以为系统在替他盯着。
--
-- 【E 臂:暂扣救不了缺货】阈值问的是"还有多少【能用】的货"。把 on_hold 算进
-- 可用,会让一次暂扣把缺货掩盖掉 —— 那恰好是这个告警最该说话的时刻。
--
-- 各臂:
--   A 前提:列在、视图在、没有流水时可用量是 0(而不是"查不到")
--   B 可用低于阈值 → 上臂,且 subject 报得出【可用 / 阈值】与差额
--   C 补货到阈值之上 → 离臂(它是可以被清掉的等待状态,不是一个状态标记)
--   D 【钉死】NULL 阈值 + 零库存 → 【不上臂】(未监控永不告警)
--   E 暂扣不算可用:大额 on_hold 之下可用仍低于阈值 → 仍然上臂
--   F 阈值 0 / 负数 → 被 CHECK 拒(“不监控”只有留空一种写法)
--   G 故障注入:把这支臂真正依赖的【谓词】打坏,断言 E 当场失守 —— 证明 E 有牙
--
-- 日期无关。自带数据(README 第 2 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user  uuid := gen_random_uuid();
    r_all   uuid;
    v_sup   uuid;
    m_watch uuid;   -- 设了阈值的物料
    m_null  uuid;   -- 【未监控】—— 本 fixture 的主角
    b1 uuid; b2 uuid;
    v_n int; v_subject text; v_avail numeric; v_held numeric;
    v_ok boolean; v_msg text; d date := CURRENT_DATE;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-60', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FIXT-S60', 'Fixture Supplier 60', 'SG', 'goods_supplier') RETURNING id INTO v_sup;

    INSERT INTO materials (code, name, kind_code, may_be_processed, unit, safety_stock_qty)
    VALUES ('ZZFIX60-W', 'fixture 60 watched', 'battery_material', true, 'kg', 50) RETURNING id INTO m_watch;
    -- 【不写 safety_stock_qty】—— 未监控是"没有人做过这个决定",不是某个值
    INSERT INTO materials (code, name, kind_code, may_be_processed, unit)
    VALUES ('ZZFIX60-U', 'fixture 60 unmonitored', 'battery_material', true, 'kg') RETURNING id INTO m_null;

    -- ══════════ A. 前提 ═════════════════════════════════════════════════════
    IF (SELECT safety_stock_qty FROM materials WHERE id = m_null) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 60A 失败:前提不成立 —— m_null 必须是【未监控】';
    END IF;
    SELECT available_qty INTO v_avail FROM material_stock_available WHERE material_id = m_watch;
    IF v_avail IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'FIXTURE 60A 失败:没有流水的物料可用量应当是 0(而不是查不到),实得 %',
            COALESCE(v_avail::text, 'NULL');
    END IF;

    -- ══════════ B. 可用低于阈值 → 上臂,且报得出差额 ══════════════════════════
    b1 := (create_inbound_batch(m_watch, v_sup, 10, 'kg', d) ->> 'batch_id')::uuid;

    SELECT count(*), max(subject) INTO v_n, v_subject
      FROM operations_now WHERE item_type = 'safety_stock_below' AND item_id = m_watch;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 60B 失败:可用 10 低于阈值 50,应当恰好一行,实得 %', v_n;
    END IF;
    IF v_subject NOT LIKE '10 / 50%' THEN
        RAISE EXCEPTION 'FIXTURE 60B 失败:subject 应当以【可用 / 阈值】开头,实得 %',
            COALESCE(v_subject, 'NULL');
    END IF;
    -- 【差额必须在里面】一支只说"有问题"而不说"差多少"的臂,逼着人再翻一遍页面。
    IF v_subject NOT LIKE '%40%' THEN
        RAISE EXCEPTION 'FIXTURE 60B 失败:subject 应当报出差额 40,实得 %', v_subject;
    END IF;

    -- ══════════ C. 补到阈值之上 → 离臂 ══════════════════════════════════════
    b2 := (create_inbound_batch(m_watch, v_sup, 100, 'kg', d) ->> 'batch_id')::uuid;
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'safety_stock_below' AND item_id = m_watch;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 60C 失败:可用 110 高于阈值 50,应当离臂,实得 % 行', v_n;
    END IF;

    -- ══════════ D. 【钉死】未监控 + 零库存 → 不上臂 ═══════════════════════════
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'safety_stock_below' AND item_id = m_null;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 60D 失败:【未监控的物料永不告警】—— 阈值 NULL、库存为零,却上了臂(% 行)。NULL 被当成了 0,而"没人做过这个决定"不等于"决定了阈值是零"', v_n;
    END IF;

    -- ══════════ E. 暂扣救不了缺货 ═══════════════════════════════════════════
    -- 扣住 80:可用 110-80 = 30(< 50),而 on_hold 桶里有 80。
    PERFORM hold_stock(p_qty => 80, p_reason => 'fixture 60 hold', p_inbound_batch_id => b2);

    SELECT available_qty INTO v_avail FROM material_stock_available WHERE material_id = m_watch;
    IF v_avail <> 30 THEN
        RAISE EXCEPTION 'FIXTURE 60E 前提失败:暂扣 80 之后可用应当是 30,实得 %', v_avail;
    END IF;
    SELECT COALESCE(sum(qty_delta), 0) INTO v_held FROM inventory_movements
     WHERE inbound_batch_id = b2 AND stock_status = 'on_hold';
    IF v_held <> 80 THEN
        RAISE EXCEPTION 'FIXTURE 60E 前提失败:on_hold 桶应当是 80,实得 %', v_held;
    END IF;

    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'safety_stock_below' AND item_id = m_watch;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 60E 失败:可用 30 低于阈值 50,即使 on_hold 有 80 也必须上臂,实得 % 行 —— 一次暂扣把缺货掩盖掉,正是这个告警最该说话的时刻', v_n;
    END IF;

    -- ══════════ F. 阈值 0 / 负数被 CHECK 拒 ══════════════════════════════════
    -- "不监控"只有【留空】一种写法;0 是把不监控写成一个看起来像监控的数字。
    FOR v_avail IN SELECT * FROM unnest(ARRAY[0, -5]) LOOP
        v_ok := false; v_msg := NULL;
        BEGIN
            UPDATE materials SET safety_stock_qty = v_avail WHERE id = m_watch;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
            v_ok := v_msg LIKE '%materials_safety_stock_qty_positive%';
        END;
        IF NOT v_ok THEN
            RAISE EXCEPTION 'FIXTURE 60F 失败:阈值 % 应当被 CHECK 拒,实得:%',
                v_avail, COALESCE(v_msg, '(写进去了)');
        END IF;
    END LOOP;

    -- ══════════ G. 故障注入:打坏这支臂依赖的谓词,E 必须当场失守 ═══════════════
    -- 【注入打的是机制,不是断言】—— 把"只数 available"改成"什么状态都数",
    -- 那正是 E 臂唯一依赖的那一句。若 E 在这之后【仍然通过】,说明 E 空转。
    EXECUTE $v$
        CREATE OR REPLACE VIEW public.material_stock_available WITH (security_invoker = off) AS
         SELECT m.id AS material_id, m.code, m.name, m.unit, m.safety_stock_qty,
            COALESCE(s.available_qty, 0::numeric) AS available_qty, s.last_movement_date
           FROM materials m
             LEFT JOIN ( SELECT COALESCE(ib.material_id, ob.material_id) AS material_id,
                    sum(mv.qty_delta) AS available_qty,
                    max(mv.business_date) AS last_movement_date
                   FROM inventory_movements mv
                     LEFT JOIN inbound_batches ib ON ib.id = mv.inbound_batch_id
                     LEFT JOIN output_batches ob ON ob.id = mv.output_batch_id
                  GROUP BY (COALESCE(ib.material_id, ob.material_id))) s ON s.material_id = m.id
          WHERE m.deleted_at IS NULL AND has_permission('module.inventory.view'::text)
    $v$;

    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'safety_stock_below' AND item_id = m_watch;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 60G 失败:注入之后这支臂【仍然响着】—— 说明 E 臂并不依赖 stock_status 那一句,它一直在空转。注入没咬住就是断言没牙(AGENTS.md:从未见过失败的检查不叫能用,只叫安静)';
    END IF;
    -- 注入确实咬住了:可用被算成 110(30 + 80 暂扣),缺货因此被掩盖 —— 正是 E 要防的那件事。
END $$;
ROLLBACK;
