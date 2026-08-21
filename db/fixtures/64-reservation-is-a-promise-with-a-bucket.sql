-- 64 预留(SO-2):committed 是一个【有主人的桶】,而承诺不是销售
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉住的四件事】
--   ① 预留把货从 available 挪进 committed,而【物理侧一个字不动】:
--      remaining_qty 不变、批次的 state 不变(承诺不是销售)。B 臂三样一起断言 ——
--      只断言桶动了,一个顺手把 state 改成「部分售出」的实现照样能过。
--   ② 五条拒绝【各自按名】,而且【两个方向都走】:拒的真拒,该通的真通。
--      只断言"拒",一个永远拒绝的函数也能通过(fixture 63 F 臂的同一课)。
--      按名而不是按"抛了异常",于是"因为别的理由拒绝"会当场露出别的码。
--   ③ 释放不改 qty,而是【整行释放 + 就地重新预留剩余】。D 臂断言的是这个
--      形状本身:老行 released_at 非空、qty 仍是 40,新行 qty 是 15。
--      一个"把 qty 改成 15"的实现在数字上看起来一样,但它改写了历史 ——
--      D 臂能分辨这两者,因为它数【行数】。
--   ④ 【预留不能让一条真实存在的违规消失】。G 臂:同一批货,预留前违规、
--      预留后仍然违规。这一条是 stock_class_violations_all 谓词放宽的全部理由,
--      也是它将来不会被"顺手改回只看 available"的唯一保障。
--
-- 各臂:
--   A 前提:表在;重建库里零条 committed 流水;订单确认了;桶里有货
--   B 预留:成对流水落地、预留行与 pair_id 对上、桶动、物理侧不动
--   C 五条拒绝各自按名 + 每一条的【正向对照】
--   D 释放:整笔释放 / 部分释放(释放-再预留的形状)
--   E 作废即释放,而且【作废之后一条活预留都不剩】(函数自己也断言了一次)
--   F 注销:有活预留就拒(按名);释放之后【同一次注销通得过】—— 两个方向
--   G 违规:预留【不】让违规消失(谓词放宽的钉子)
--   H 销售:超出 available 按名拒且消息里带得出 committed;在 available 之内照卖
--   I 安全库存:一次预留把可用压到阈值以下 → 告警响(SS-1 的口径:阈值问的是
--     "还有多少【能用】的货")
--   J 转移:committed 整桶搬得动,预留行跟着走;搬不完按名拒
--   K 角色:有 sales.edit 的预留得了;只有 sales.view 的被拒;
--     【没有 sales.view 的读者一行都看不见】(切库角色,否则是空话)
--   L 注入:把行天花板那一句拿掉 → C 臂那条超额预留当场【通过】
--
-- 日期无关(不依赖假日表)。期间锁显式设成 NULL(README 第 5 条)。
-- 自带数据(README 第 2 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user  uuid := gen_random_uuid();
    u_edit  uuid := gen_random_uuid();   -- module.sales.view + edit
    u_view  uuid := gen_random_uuid();   -- 只有 module.sales.view
    u_inv   uuid := gen_random_uuid();   -- 只有 module.inventory.view(没有 sales.view)
    r_all uuid; r_edit uuid; r_view uuid; r_inv uuid;
    v_cust uuid; v_mat uuid; m_cls uuid; m_saf uuid; v_ccy text;
    loc_a uuid; loc_b uuid; loc_x uuid;
    so_main uuid; so_draft uuid; so_cancel uuid;
    L1 uuid; L2 uuid; L3 uuid; L4 uuid; L5 uuid; L6 uuid; L7 uuid; LC uuid;
    ob1 uuid; ob2 uuid; ob3 uuid; ob4 uuid; ob5 uuid; ob6 uuid; ob7 uuid;
    v_res jsonb; v_r1 uuid; v_r2 uuid; v_r3 uuid; v_rid uuid;
    v_pair uuid; v_n int; v_qty numeric; v_avail numeric; v_comm numeric;
    v_rem numeric; v_state text; v_msg text; v_ok boolean;
    v_before int; v_after int;
    d date := CURRENT_DATE;
BEGIN
    -- ══════════ 角色与前提数据 ══════════════════════════════════════════════
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-64', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-64-edit', 'f', 'f', true) RETURNING id INTO r_edit;
    INSERT INTO role_permissions (role_id, permission_code)
    VALUES (r_edit, 'module.sales.view'), (r_edit, 'module.sales.edit');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_edit, r_edit);

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-64-view', 'f', 'f', true) RETURNING id INTO r_view;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_view, 'module.sales.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_view, r_view);

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-64-inv', 'f', 'f', true) RETURNING id INTO r_inv;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_inv, 'module.inventory.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_inv, r_inv);

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- 【显式设定前提,即便默认值恰好合用】(README 第 5 条)
    UPDATE finance_settings SET locked_before = NULL;

    SELECT code INTO v_ccy FROM currencies WHERE is_base;

    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZ64-C1', 'fixture 64 customer', 'SG') RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, unit)
    VALUES ('ZZFIX64-M', 'f64 material', 'battery_material', true, 'kg') RETURNING id INTO v_mat;
    INSERT INTO materials (code, name, kind_code, may_be_processed, unit, waste_classification_code)
    VALUES ('ZZFIX64-N', 'f64 classified', 'battery_material', true, 'kg', 'non_focused') RETURNING id INTO m_cls;
    INSERT INTO materials (code, name, kind_code, may_be_processed, unit, safety_stock_qty)
    VALUES ('ZZFIX64-S', 'f64 safety-watched', 'battery_material', true, 'kg', 50) RETURNING id INTO m_saf;

    INSERT INTO storage_locations (code, name) VALUES ('ZZ64-A', 'f64 A') RETURNING id INTO loc_a;
    INSERT INTO storage_locations (code, name) VALUES ('ZZ64-B', 'f64 B') RETURNING id INTO loc_b;
    INSERT INTO storage_locations (code, name) VALUES ('ZZ64-X', 'f64 X') RETURNING id INTO loc_x;

    -- 批次(全部经建批次那一扇门 —— IOD-1b)
    ob1 := (create_output_batch(v_mat, 100, 'kg', d, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;
    ob2 := (create_output_batch(v_mat, 60,  'kg', d, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;
    ob3 := (create_output_batch(v_mat, 30,  'kg', d, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;
    ob4 := (create_output_batch(m_cls, 25,  'kg', d, '库存中', NULL, NULL, NULL, loc_x) ->> 'batch_id')::uuid;
    ob5 := (create_output_batch(v_mat, 50,  'kg', d, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;
    ob6 := (create_output_batch(m_saf, 60,  'kg', d, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;
    ob7 := (create_output_batch(v_mat, 20,  'kg', d, '库存中', NULL, NULL, NULL, loc_a) ->> 'batch_id')::uuid;

    -- 订单:一张确认单(多行,各臂各用一行)、一张草稿单、一张待作废单
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d), v_cust, d, v_ccy, 1) RETURNING id INTO so_main;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so_main, 1, v_mat, 100, 10) RETURNING id INTO L1;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so_main, 2, v_mat, 30, 10) RETURNING id INTO L2;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so_main, 3, v_mat, 20, 10) RETURNING id INTO L3;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so_main, 4, v_mat, 50, 10) RETURNING id INTO L4;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so_main, 5, v_mat, 20, 10) RETURNING id INTO L5;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so_main, 6, m_cls, 25, 10) RETURNING id INTO L6;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so_main, 7, m_saf, 60, 10) RETURNING id INTO L7;
    PERFORM set_sales_order_status(so_main, 'confirmed');

    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d), v_cust, d, v_ccy, 1) RETURNING id INTO so_draft;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so_draft, 1, v_mat, 10, 10);

    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d), v_cust, d, v_ccy, 1) RETURNING id INTO so_cancel;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so_cancel, 1, v_mat, 40, 10) RETURNING id INTO LC;
    PERFORM set_sales_order_status(so_cancel, 'confirmed');

    -- ══════════ A. 前提 ═════════════════════════════════════════════════════
    -- 【前提不成立时,下面的等式会因为两边同时为 0 而空转通过】—— 与 fixture 56
    -- A 臂同一条理由,所以前提自己也是一条断言。
    IF to_regclass('public.sales_order_reservations') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 64A 失败:sales_order_reservations 不在';
    END IF;
    -- 重建库里【不该】有任何 committed 流水:引导数据里没有销售订单,也就没有预留。
    -- (与 fixture 56A 同形:一个存在于引导数据里的 committed 行,说明有人把
    --  业务数据播进了引导集,那会让本文件后面每一条计数都变成别人的数。)
    SELECT count(*) INTO v_n FROM inventory_movements
     WHERE stock_status = 'committed'
       AND output_batch_id NOT IN (ob1, ob2, ob3, ob4, ob5, ob6, ob7);
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 64A 失败:本 fixture 之外不该存在 committed 流水,实得 % 条', v_n;
    END IF;
    SELECT status INTO v_state FROM sales_orders WHERE id = so_main;
    IF v_state <> 'confirmed' THEN
        RAISE EXCEPTION 'FIXTURE 64A 失败:主订单应当是 confirmed,实得 %', v_state;
    END IF;

    -- ══════════ B. 预留:桶动了,物理侧一个字没动 ═════════════════════════════
    SELECT remaining_qty, state INTO v_rem, v_state FROM output_batches WHERE id = ob1;
    IF v_rem <> 100 OR v_state <> '库存中' THEN
        RAISE EXCEPTION 'FIXTURE 64B 前提失败:ob1 应当是 100 / 库存中,实得 % / %', v_rem, v_state;
    END IF;

    v_res := reserve_stock(L1, ob1, 40);
    v_rid := (v_res->>'reservation_id')::uuid;
    v_pair := (v_res->>'pair_id')::uuid;

    -- ① 成对流水:恰好两行,一出 available、一进 committed,同一个 pair_id
    SELECT count(*) INTO v_n FROM inventory_movements WHERE pair_id = v_pair;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 64B 失败:一次预留应当写出【成对】的两行流水,实得 %', v_n;
    END IF;
    SELECT COALESCE(sum(qty_delta), 0) INTO v_qty FROM inventory_movements
     WHERE pair_id = v_pair;
    IF v_qty <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 64B 失败:成对流水的净和必须是 0(物理总量按构造不动),实得 %', v_qty;
    END IF;
    SELECT count(*) INTO v_n FROM inventory_movements
     WHERE pair_id = v_pair AND movement_type = 'status_change_out'
       AND stock_status = 'available' AND qty_delta = -40;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 64B 失败:出腿应当是 available −40,实得 % 行', v_n;
    END IF;
    SELECT count(*) INTO v_n FROM inventory_movements
     WHERE pair_id = v_pair AND movement_type = 'status_change_in'
       AND stock_status = 'committed' AND qty_delta = 40;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 64B 失败:入腿应当是 committed +40,实得 % 行', v_n;
    END IF;

    -- ② 预留行与那一对流水【对得上】—— pair_id 是两侧唯一的连接
    SELECT count(*) INTO v_n FROM sales_order_reservations
     WHERE id = v_rid AND pair_id = v_pair AND qty = 40
       AND sales_order_line_id = L1 AND output_batch_id = ob1
       AND location_id IS NULL AND released_at IS NULL;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 64B 失败:预留行没有与它那一对流水对上(pair_id / 数量 / 行 / 批次 / 桶)';
    END IF;

    -- ③ 派生桶动了
    SELECT derived_stock_qty(NULL, ob1, NULL, 'available') INTO v_avail;
    SELECT derived_stock_qty(NULL, ob1, NULL, 'committed') INTO v_comm;
    IF v_avail <> 60 OR v_comm <> 40 THEN
        RAISE EXCEPTION 'FIXTURE 64B 失败:预留 40 之后应当是 available=60 / committed=40,实得 % / %',
            v_avail, v_comm;
    END IF;

    -- ④ 【物理侧一个字没动】—— 这一条是本臂真正的心脏。
    -- remaining_qty 不变,是账本不变式的直接结果;而 state 不变【是一个决定】:
    -- 承诺不是销售,一批全部许出去的货仍然是「库存中」。想看见许出去多少,
    -- 看的是派生的三态分布,不是那一列。一个顺手把 state 改成「部分售出」的
    -- 实现在前三条上完全通得过,只有这一条能拦住它。
    SELECT remaining_qty, state INTO v_rem, v_state FROM output_batches WHERE id = ob1;
    IF v_rem <> 100 THEN
        RAISE EXCEPTION 'FIXTURE 64B 失败:预留不该动 remaining_qty(它记的是物理剩余),实得 %', v_rem;
    END IF;
    IF v_state <> '库存中' THEN
        RAISE EXCEPTION 'FIXTURE 64B 失败:预留不该动批次 state ——【承诺不是销售】,实得 %', v_state;
    END IF;

    -- ══════════ C. 五条拒绝,各自按名,两个方向都走 ═══════════════════════════
    -- ① 订单没确认
    BEGIN
        PERFORM reserve_stock((SELECT id FROM sales_order_lines WHERE sales_order_id = so_draft), ob2, 5);
        RAISE EXCEPTION 'FIXTURE 64C 失败:草稿单上的行不该预留得了';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_RESERVE_ORDER_NOT_CONFIRMED%' THEN RAISE; END IF;
    END;
    -- 正向对照:同样一次预留,订单确认之后就通 —— 否则"永远拒绝"也能通过本臂
    PERFORM set_sales_order_status(so_draft, 'confirmed');
    PERFORM reserve_stock((SELECT id FROM sales_order_lines WHERE sales_order_id = so_draft), ob2, 5);

    -- ② 不是产出批次(传一个根本不存在的批次 id —— 进料批次同样落在这里,
    --    因为它在 output_batches 里查不到)
    BEGIN
        PERFORM reserve_stock(L2, gen_random_uuid(), 5);
        RAISE EXCEPTION 'FIXTURE 64C 失败:非产出批次不该预留得了';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_RESERVE_OUTPUT_ONLY%' THEN RAISE; END IF;
    END;
    -- 正向对照:换成一个真的产出批次就通
    PERFORM reserve_stock(L2, ob2, 5);

    -- ③ 物料对不上(把 v_mat 的批次预留给 m_cls 的那一行)
    BEGIN
        PERFORM reserve_stock(L6, ob2, 5);
        RAISE EXCEPTION 'FIXTURE 64C 失败:物料对不上的预留不该通过';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_RESERVE_MATERIAL_MISMATCH%' THEN RAISE; END IF;
    END;
    -- 正向对照:同一行配上对的物料就通
    PERFORM reserve_stock(L6, ob4, 5, loc_x);   -- ob4 的货在 loc_x 上,桶要指名

    -- ④ 超出行的天花板(L3 只有 20)
    BEGIN
        PERFORM reserve_stock(L3, ob1, 25);
        RAISE EXCEPTION 'FIXTURE 64C 失败:超出订单行数量的预留不该通过';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_RESERVE_EXCEEDS_LINE%' THEN RAISE; END IF;
    END;
    -- 正向对照:压到 20 就通(且【累计】口径成立 —— 再来 1 就该被拒)
    PERFORM reserve_stock(L3, ob1, 20);
    BEGIN
        PERFORM reserve_stock(L3, ob1, 1);
        RAISE EXCEPTION 'FIXTURE 64C 失败:行天花板是【累计】口径,已经满了还能再预留';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_RESERVE_EXCEEDS_LINE%' THEN RAISE; END IF;
    END;

    -- ⑤ 超出桶里的可用(ob3 只有 30,而且要的是【那个桶】的可用)
    BEGIN
        PERFORM reserve_stock(L4, ob3, 31);
        RAISE EXCEPTION 'FIXTURE 64C 失败:超出可用的预留不该通过';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_RESERVE_EXCEEDS_AVAILABLE%' THEN RAISE; END IF;
    END;
    -- 正向对照:30 正好通
    PERFORM reserve_stock(L4, ob3, 30);

    -- ══════════ D. 释放:整笔 / 部分(【释放-再预留】的形状)════════════════════
    -- 整笔:committed 回到 available,行被作废
    v_res := release_reservation(v_rid, NULL, 'customer deferred');
    SELECT derived_stock_qty(NULL, ob1, NULL, 'available') INTO v_avail;
    SELECT derived_stock_qty(NULL, ob1, NULL, 'committed') INTO v_comm;
    -- ob1 上还有 C④ 留下的 20(挂在 L3 上),所以 available = 100 − 20
    IF v_avail <> 80 OR v_comm <> 20 THEN
        RAISE EXCEPTION 'FIXTURE 64D 失败:整笔释放 40 之后 ob1 应当是 available=80 / committed=20,实得 % / %',
            v_avail, v_comm;
    END IF;
    SELECT count(*) INTO v_n FROM sales_order_reservations
     WHERE id = v_rid AND released_at IS NOT NULL AND release_reason = 'customer deferred'
       AND release_pair_id IS NOT NULL AND qty = 40;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 64D 失败:释放应当写三列并【保留 qty=40】(它是发生过的事实)';
    END IF;

    -- 部分:预留 40,释放 25 —— 期望【两行】:老行整笔作废,新行 15
    v_res := reserve_stock(L1, ob1, 40);
    v_r1  := (v_res->>'reservation_id')::uuid;
    v_res := release_reservation(v_r1, 25, 'partial pushback');

    SELECT count(*) INTO v_n FROM sales_order_reservations
     WHERE id = v_r1 AND released_at IS NOT NULL AND qty = 40;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 64D 失败:部分释放【不该把 qty 改小】—— 老行必须整笔作废且 qty 仍是 40';
    END IF;
    SELECT count(*), COALESCE(max(qty), 0) INTO v_n, v_qty
      FROM sales_order_reservations
     WHERE sales_order_line_id = L1 AND released_at IS NULL;
    IF v_n <> 1 OR v_qty <> 15 THEN
        RAISE EXCEPTION 'FIXTURE 64D 失败:部分释放之后 L1 上应当恰好一条活预留、数量 15,实得 % 条 / %',
            v_n, v_qty;
    END IF;
    -- 【数字对不代表形状对】:把 qty 从 40 改成 15 的实现,数量上与这里一模一样。
    -- 分辨它们的是【行数】—— L1 上一共应当有三行(第一次整笔释放的、部分释放
    -- 作废的、重新预留出来的)。
    SELECT count(*) INTO v_n FROM sales_order_reservations WHERE sales_order_line_id = L1;
    IF v_n <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 64D 失败:L1 上应当留下三行事实(整笔释放 / 部分释放作废 / 重新预留),实得 %', v_n;
    END IF;
    SELECT derived_stock_qty(NULL, ob1, NULL, 'committed') INTO v_comm;
    IF v_comm <> 35 THEN   -- 15(L1)+ 20(L3)
        RAISE EXCEPTION 'FIXTURE 64D 失败:部分释放之后 ob1 的 committed 应当是 35,实得 %', v_comm;
    END IF;

    -- 释放要理由(与暂扣同一条:撤回一个已经做出的承诺本身就需要解释)
    BEGIN
        PERFORM release_reservation(
            (SELECT id FROM sales_order_reservations WHERE sales_order_line_id = L3 AND released_at IS NULL),
            NULL, '   ');
        RAISE EXCEPTION 'FIXTURE 64D 失败:没有理由的释放不该通过';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_RELEASE_REASON_REQUIRED%' THEN RAISE; END IF;
    END;

    -- ══════════ E. 作废即释放 ════════════════════════════════════════════════
    PERFORM reserve_stock(LC, ob2, 40);
    SELECT derived_stock_qty(NULL, ob2, NULL, 'committed') INTO v_comm;
    IF v_comm <> 50 THEN   -- 40(LC)+ 5(so_draft)+ 5(L2)
        RAISE EXCEPTION 'FIXTURE 64E 前提失败:ob2 的 committed 应当是 50,实得 %', v_comm;
    END IF;

    PERFORM set_sales_order_status(so_cancel, 'cancelled', 'customer withdrew');

    SELECT count(*) INTO v_n
      FROM sales_order_reservations r JOIN sales_order_lines l ON l.id = r.sales_order_line_id
     WHERE l.sales_order_id = so_cancel AND r.released_at IS NULL;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 64E 失败:作废之后不该还剩活预留,实得 % 条', v_n;
    END IF;
    SELECT derived_stock_qty(NULL, ob2, NULL, 'committed') INTO v_comm;
    IF v_comm <> 10 THEN
        RAISE EXCEPTION 'FIXTURE 64E 失败:作废释放了 40 之后 ob2 的 committed 应当回到 10,实得 %', v_comm;
    END IF;
    -- 留痕:释放留在【订单的历史】里,不是只留在库存流水里
    SELECT count(*) INTO v_n FROM sales_order_history
     WHERE sales_order_id = so_cancel AND change_type = 'released';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 64E 失败:作废释放应当在订单历史里留一行 released,实得 %', v_n;
    END IF;

    -- ══════════ F. 注销:有活预留就拒,释放之后【同一次注销通得过】════════════
    PERFORM reserve_stock(L2, ob5, 25);
    BEGIN
        PERFORM soft_delete_output_batch(ob5, 'fixture:AUDEL-1b 之后理由必填');   -- AUDEL-1b:走门
        RAISE EXCEPTION 'FIXTURE 64F 失败:一批还许着人的货不该注销得了';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_BATCH_HAS_RESERVATIONS%' THEN RAISE; END IF;
    END;
    -- 【另一个方向】—— 只断言"拒",一个永远拒绝的注销也能通过本臂。
    PERFORM release_reservation(
        (SELECT id FROM sales_order_reservations WHERE output_batch_id = ob5 AND released_at IS NULL),
        NULL, 'batch scrapped');
    PERFORM soft_delete_output_batch(ob5, 'fixture:AUDEL-1b 之后理由必填');   -- AUDEL-1b:走门
    SELECT remaining_qty FROM output_batches WHERE id = ob5 INTO v_rem;
    IF v_rem <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 64F 失败:释放之后注销应当照常排空,实得 remaining_qty=%', v_rem;
    END IF;

    -- ══════════ G. 违规:预留【不】让违规消失 ═════════════════════════════════
    -- ob4 的 25kg(non_focused)躺在 loc_x 上。现在把 loc_x 配成只允许 focused ——
    -- 与 fixture 62 D 臂同一个手法:违规是【配置后来改了】造出来的。
    INSERT INTO storage_location_allowed_classes (location_id, classification_code)
    VALUES (loc_x, 'focused');
    SELECT count(*), COALESCE(max(qty), 0) INTO v_n, v_qty
      FROM stock_class_violations WHERE location_id = loc_x;
    IF v_n <> 1 OR v_qty <> 25 THEN
        RAISE EXCEPTION 'FIXTURE 64G 前提失败:预留之前 loc_x 上应当有一行 25 的违规,实得 % 行 / %', v_n, v_qty;
    END IF;

    -- 现在把它【全部】预留出去(L6 已经占了 5,再来 20 正好 25)
    PERFORM reserve_stock(L6, ob4, 20, loc_x);
    SELECT derived_stock_qty(NULL, ob4, loc_x, 'available') INTO v_avail;
    IF v_avail <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 64G 前提失败:ob4 在 loc_x 上的 available 应当被预留光,实得 %', v_avail;
    END IF;

    -- 【钉子】货还在那个不该放它的库位上 —— 违规必须原样还在,数量也不变。
    -- 谓词若退回"只看 available",这里会变成 0 行,而现实里那 25kg 一克都没动。
    SELECT count(*), COALESCE(max(qty), 0) INTO v_n, v_qty
      FROM stock_class_violations WHERE location_id = loc_x;
    IF v_n <> 1 OR v_qty <> 25 THEN
        RAISE EXCEPTION 'FIXTURE 64G 失败:预留【不该】让违规消失 —— 违规讲的是货待在哪里,与它许给了谁无关;实得 % 行 / %',
            v_n, v_qty;
    END IF;

    -- ══════════ H. 销售:拒绝说得出 committed;在 available 之内照卖 ═══════════
    -- ob3 的 30 全部预留在 L4 上(C⑤),所以 available = 0、committed = 30
    BEGIN
        PERFORM record_output_sale(ob3, 1, 10, v_ccy, NULL, v_cust, d, NULL);
        RAISE EXCEPTION 'FIXTURE 64H 失败:全部被预留的批次不该卖得出去';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'IOD_SALE_EXCEEDS_AVAILABLE%' THEN RAISE; END IF;
        -- 【消息里必须带得出 committed】—— 否则屏幕上会是"可用 0、暂扣 0,
        -- 可是卖不掉",而真正的答案是"它许给了某张订单"。
        -- 段序:1=码 2=想卖 3=可用 4=暂扣 5=已承诺。committed 是【第五段】——
        -- 第一版数错成第四段,读到的是暂扣的 0,于是这条断言在报一个假的失败。
        v_msg := SQLERRM;
        IF btrim(split_part(v_msg, '|', 5)) = '' THEN
            RAISE EXCEPTION 'FIXTURE 64H 失败:拒绝消息里没有第五段(committed):%', v_msg;
        END IF;
        IF split_part(v_msg, '|', 5)::numeric <> 30 THEN
            RAISE EXCEPTION 'FIXTURE 64H 失败:拒绝消息的 committed 段应当是 30,实得 %',
                split_part(v_msg, '|', 5);
        END IF;
    END;
    -- 另一个方向:部分预留的批次,在 available 之内照卖(ob1:available 65)
    SELECT derived_stock_qty(NULL, ob1, NULL, 'available') INTO v_avail;
    PERFORM record_output_sale(ob1, 5, 10, v_ccy, NULL, v_cust, d, NULL);
    SELECT derived_stock_qty(NULL, ob1, NULL, 'available') INTO v_qty;
    IF v_qty <> v_avail - 5 THEN
        RAISE EXCEPTION 'FIXTURE 64H 失败:销售应当只从 available 里扣(% → %),预期 %',
            v_avail, v_qty, v_avail - 5;
    END IF;
    SELECT derived_stock_qty(NULL, ob1, NULL, 'committed') INTO v_comm;
    IF v_comm <> 35 THEN
        RAISE EXCEPTION 'FIXTURE 64H 失败:销售【不该】动 committed,实得 %', v_comm;
    END IF;

    -- ══════════ I. 安全库存:预留把可用压到阈值以下 → 告警响 ═══════════════════
    -- m_saf 的阈值是 50,库里 60 —— 现在不响。
    SELECT count(*) INTO v_before FROM operations_now
     WHERE item_type = 'safety_stock_below' AND item_id = m_saf;
    IF v_before <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 64I 前提失败:60 > 阈值 50,此刻不该响,实得 % 行', v_before;
    END IF;

    PERFORM reserve_stock(L7, ob6, 20);   -- 可用 60 → 40,低于 50

    SELECT count(*) INTO v_after FROM operations_now
     WHERE item_type = 'safety_stock_below' AND item_id = m_saf;
    IF v_after <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 64I 失败:一次预留把可用压到阈值以下,安全库存告警应当响 —— SS-1 的口径是"还有多少【能用】的货",而许给别人的货不能用;实得 % 行', v_after;
    END IF;
    -- 物理侧没变,这正是本臂要说的话:货还在,但它不再是"能用的货"
    SELECT remaining_qty INTO v_rem FROM output_batches WHERE id = ob6;
    IF v_rem <> 60 THEN
        RAISE EXCEPTION 'FIXTURE 64I 失败:告警响了,而物理库存本该一克没动,实得 %', v_rem;
    END IF;

    -- ══════════ J. 转移:committed 整桶搬,预留行跟着走;搬不完按名拒 ═══════════
    PERFORM reserve_stock(L5, ob7, 12, loc_a);   -- ob7 在 loc_a 上有 20,预留 12
    BEGIN
        PERFORM create_stock_transfer(5, loc_b, NULL, ob7, loc_a, 'committed', NULL);
        RAISE EXCEPTION 'FIXTURE 64J 失败:committed 的部分转移不该通过';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'IOD_TRANSFER_COMMITTED_PARTIAL%' THEN RAISE; END IF;
    END;
    -- 整桶搬:12 全部过去,预留行的库位跟着改
    PERFORM create_stock_transfer(12, loc_b, NULL, ob7, loc_a, 'committed', NULL);
    SELECT derived_stock_qty(NULL, ob7, loc_a, 'committed') INTO v_avail;
    SELECT derived_stock_qty(NULL, ob7, loc_b, 'committed') INTO v_comm;
    IF v_avail <> 0 OR v_comm <> 12 THEN
        RAISE EXCEPTION 'FIXTURE 64J 失败:整桶转移之后 committed 应当是 loc_a=0 / loc_b=12,实得 % / %',
            v_avail, v_comm;
    END IF;
    SELECT count(*) INTO v_n FROM sales_order_reservations
     WHERE sales_order_line_id = L5 AND released_at IS NULL AND location_id = loc_b;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 64J 失败:预留行没有跟着搬到 loc_b —— 流水说货在 B、预留说在 A,两句话对不上';
    END IF;
    -- 一个坏状态不是一个坏数量(SO-2:此前它抛的是 STK_QTY_INVALID)
    BEGIN
        PERFORM create_stock_transfer(1, loc_b, NULL, ob7, loc_a, 'not_a_bucket', NULL);
        RAISE EXCEPTION 'FIXTURE 64J 失败:不认识的库存状态不该通过';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'IOD_TRANSFER_STATUS_INVALID%' THEN RAISE; END IF;
    END;

    -- ══════════ K. 角色 ══════════════════════════════════════════════════════
    -- ① 有 sales.edit 的预留得了(而他【没有】任何库存模块的码 —— 预留是一次
    --    销售行为,这一条正是那个跨模块决定的行为断言)
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_edit), true);
    PERFORM reserve_stock(L2, ob2, 5);

    -- ② 只有 sales.view 的被拒
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_view), true);
    BEGIN
        PERFORM reserve_stock(L2, ob2, 1);
        RAISE EXCEPTION 'FIXTURE 64K 失败:只有 sales.view 的人不该预留得了';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'PERMISSION_DENIED%' THEN RAISE; END IF;
    END;

    -- ③ 【没有 sales.view 的读者一行都看不见】——「缺席」,不是 0。
    -- README 第 6 条:fixture 以 postgres 跑,RLS 对超级用户不生效;不切角色
    -- 这一条就是空话(fixture 26 的第一版正是这么空转的)。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_view), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_before FROM sales_order_reservations;
    RESET ROLE;
    IF v_before = 0 THEN
        RAISE EXCEPTION 'FIXTURE 64K 失败:持 sales.view 的读者应当看得见预留,实得 0 —— 那说明下面那条"看不见"的断言在空转';
    END IF;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_inv), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_after FROM sales_order_reservations;
    RESET ROLE;
    IF v_after <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 64K 失败:没有 module.sales.view 的读者不该看见任何预留,实得 % 行', v_after;
    END IF;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ L. 注入:拿掉行天花板 → C④ 那条超额预留当场【通过】═════════════
    -- 【为什么注入的是这一条】五条拒绝里,四条的正向对照已经足以证明它们不是
    -- "永远拒绝"(换一个合法输入就通,而且拒绝按名 —— 换个理由拒会露出别的码)。
    -- 只有行天花板不同:它是一条【累计】判断,而一个只查桶余量、不查行的实现
    -- 在其余每一条上都通得过,却会把同一批货许给同一行两次 —— 屏幕上看不出来,
    -- 发货那天才炸。所以这一条要用注入证明它真的在挡。
    EXECUTE $inj$
        CREATE OR REPLACE FUNCTION public.reserve_stock(
            p_sales_order_line_id uuid, p_output_batch_id uuid,
            p_qty numeric, p_location_id uuid DEFAULT NULL)
         RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
         SET search_path TO 'public', 'pg_temp'
        AS $f$
        DECLARE
            v_pair uuid := gen_random_uuid();
            v_line record; v_res_id uuid;
        BEGIN
            PERFORM require_permission('module.sales.edit');
            SELECT l.id, l.line_no, o.id AS order_id, o.code AS order_code
              INTO v_line
              FROM sales_order_lines l JOIN sales_orders o ON o.id = l.sales_order_id
             WHERE l.id = p_sales_order_line_id;
            -- 【被拿掉的那一句】: 行天花板(已预留 + 本次 <= 行数量)
            INSERT INTO inventory_movements
                (output_batch_id, location_id, movement_type,
                 qty_delta, stock_status, pair_id, business_date, created_by)
            VALUES
                (p_output_batch_id, p_location_id, 'status_change_out',
                 -p_qty, 'available', v_pair, CURRENT_DATE, auth.uid()),
                (p_output_batch_id, p_location_id, 'status_change_in',
                  p_qty, 'committed', v_pair, CURRENT_DATE, auth.uid());
            INSERT INTO sales_order_reservations
                (sales_order_line_id, output_batch_id, location_id, qty, pair_id, created_by)
            VALUES (p_sales_order_line_id, p_output_batch_id, p_location_id, p_qty, v_pair, auth.uid())
            RETURNING id INTO v_res_id;
            RETURN jsonb_build_object('reservation_id', v_res_id, 'pair_id', v_pair);
        END;
        $f$;
    $inj$;

    -- L3 已经满了(20/20)。注入之后再预留 1 必须【通过】—— 那正好证明
    -- C④ 里那条拒绝是这一句在挡,不是别的东西顺带挡住的。
    v_ok := true;
    BEGIN
        PERFORM reserve_stock(L3, ob1, 1);
    EXCEPTION WHEN OTHERS THEN
        v_ok := false;
        v_msg := SQLERRM;
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 64L 失败:拿掉行天花板之后,超额预留【仍然】被拒(%)—— 说明 C④ 一直靠别的东西挡着,那条断言在空转', v_msg;
    END IF;
    SELECT COALESCE(sum(qty), 0) INTO v_qty FROM sales_order_reservations
     WHERE sales_order_line_id = L3 AND released_at IS NULL;
    IF v_qty <= 20 THEN
        RAISE EXCEPTION 'FIXTURE 64L 失败:注入之后 L3 的活预留应当超过行数量 20,实得 %', v_qty;
    END IF;
END $$;
ROLLBACK;
