-- 69 行的天花板(SO-3b fu5):一条行【记得】自己已经发掉了多少
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉住的三件事】
--   ① 探针的【原序列】:开票 → 预留 → 发货 → 再预留,最后那一步必须【按名拒】。
--      这是线上实测出来的缺陷本身:天花板此前只数【活预留】,而发货正是把预留
--      移出那个集合,于是发满的行天花板重新变回满额 —— 12 kg 的行发掉 12 之后
--      又预留 12、又发一次,24 kg 出库、2500 落成净借方 120、收入 240 对着一张
--      120 的发票。B 臂。
--   ② 【边界】:12 的行发掉 8,剩下的正好是 4 —— 不是 12,也不是 0。
--      一个"发过就整行封死"的实现和一个"发过就当没发过"的实现,都会在 B 臂上
--      通过而在这里露馅。C 臂,两个方向都走(4 通、5 拒)。
--   ③ 【释放的不算】释放把货放回 available,那一份没有再许给谁 —— 所以它必须
--      从"已许出去"里退出来。D 臂。少了这一条,一个"只加不减"的实现照样过前两臂,
--      而它会让每一次释放都永久吃掉行的额度。
--
-- 各臂:
--   A 前提 + 目录(line_spoken_for 在;对 authenticated 收权;天花板确实读它)
--   B 探针原序列:发满之后再预留 → SO_RESERVE_EXCEEDS_LINE|12|12|12(三段都验)
--     并且这张单的 2500 精确归零 —— 负债只释放了一次
--   C 边界:发 8 → 正好剩 4(5 拒 / 4 通 / 再 1 拒)
--   D 释放的不算(反向);未动过的行 spoken_for = 0
--   E 注入:把 line_spoken_for 换回【只数活预留】→ 双重发货当场走通,
--     24 kg 出库、2500 不再归零 —— 证明 B 臂那条拒绝是这一处推导在挡
--
-- 【注入臂放在最后】fixture 64 付过这笔账:注入臂种下的行会污染后面各臂的数字。
-- 期间锁显式设 NULL(README 第 5 条)。自带数据(第 2 条)。
-- 汇率取【非 1】的 1.25(第 4 条的精神:两边一致时"归零"这种断言什么都不证明)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid;
    v_cust uuid; v_mat uuid;
    soB uuid; soC uuid; soD uuid; soE uuid;
    LB uuid; LB2 uuid; LC uuid; LC2 uuid; LD uuid; LD2 uuid; LE uuid; LE2 uuid;
    obB uuid; obC uuid; obD uuid; obE uuid;
    resB uuid; resC uuid; resD uuid; resE uuid;
    v_msg text; v_n int; v_qty numeric; v_2500 numeric; v_ok boolean;
    d date := CURRENT_DATE;
    FX constant numeric := 1.25;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-69', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZ69-C1', 'fixture 69 customer', 'SG') RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZFIX69-M', 'f69 material', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO v_mat;

    obB := (create_output_batch(v_mat, 100, 'kg', d, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;
    obC := (create_output_batch(v_mat, 100, 'kg', d, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;
    obD := (create_output_batch(v_mat, 100, 'kg', d, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;
    obE := (create_output_batch(v_mat, 100, 'kg', d, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;

    -- 每张单【两行】:第二行永远不动,单据因此停在 partially_shipped 而不是
    -- shipped —— 这正是缺陷的可达条件(shipped 的单连预留都进不去,单行单
    -- 因此撞不到它)。这不是布景,是前提。
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d), v_cust, d, 'USD', FX) RETURNING id INTO soB;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soB, 1, v_mat, 12, 10) RETURNING id INTO LB;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soB, 2, v_mat, 20, 10) RETURNING id INTO LB2;
    PERFORM set_sales_order_status(soB, 'confirmed');

    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d), v_cust, d, 'USD', FX) RETURNING id INTO soC;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soC, 1, v_mat, 12, 10) RETURNING id INTO LC;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soC, 2, v_mat, 20, 10) RETURNING id INTO LC2;
    PERFORM set_sales_order_status(soC, 'confirmed');

    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d), v_cust, d, 'USD', FX) RETURNING id INTO soD;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soD, 1, v_mat, 12, 10) RETURNING id INTO LD;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soD, 2, v_mat, 20, 10) RETURNING id INTO LD2;
    PERFORM set_sales_order_status(soD, 'confirmed');

    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d), v_cust, d, 'USD', FX) RETURNING id INTO soE;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soE, 1, v_mat, 12, 10) RETURNING id INTO LE;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soE, 2, v_mat, 20, 10) RETURNING id INTO LE2;
    PERFORM set_sales_order_status(soE, 'confirmed');

    -- ══════════ A. 前提 + 目录 ═══════════════════════════════════════════════
    IF to_regprocedure('public.line_spoken_for(uuid)') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 69A 失败:line_spoken_for 不在 —— 这一处推导就是本刀的全部';
    END IF;
    -- 【内层算子:靠调不到】没有调用者检查,所以 authenticated 必须调不动它。
    -- 它逐行吐露别人订单的发货进度,而那是 module.sales.view 的东西。
    IF has_function_privilege('authenticated', 'public.line_spoken_for(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 69A 失败:line_spoken_for 对 authenticated 可执行 —— 它没有调用者检查,靠的就是调不到';
    END IF;
    -- 【天花板确实读它,而不是自己再数一遍】这一条是"一处推导"本身的断言:
    -- 一个把同样算术抄进 reserve_stock 的实现,B/C/D 三臂全过,而 SO-1b 的
    -- 改单下限会读到另一份。
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'reserve_stock') NOT LIKE '%line_spoken_for(%' THEN
        RAISE EXCEPTION 'FIXTURE 69A 失败:reserve_stock 的天花板没有读 line_spoken_for';
    END IF;
    IF line_spoken_for(LB) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 69A 失败:什么都没做的行,已许出去应当是 0,实得 %', line_spoken_for(LB);
    END IF;

    -- ══════════ B. 探针的原序列 ══════════════════════════════════════════════
    PERFORM create_order_invoice(soB, d, NULL, NULL, NULL, ARRAY[LB]);
    resB := (reserve_stock(LB, obB, 12) ->> 'reservation_id')::uuid;
    PERFORM ship_order(soB, d, jsonb_build_array(jsonb_build_object('reservation_id', resB)));

    -- 前提:单据确实停在 partially_shipped(否则下面那次预留会被【状态】挡住,
    -- 而不是被天花板挡住 —— 那样这一臂就在空转)
    IF (SELECT status FROM sales_orders WHERE id = soB) <> 'partially_shipped' THEN
        RAISE EXCEPTION 'FIXTURE 69B 失败:这张单应当停在 partially_shipped(否则下一步是被状态挡的,不是被天花板挡的),实得 %',
            (SELECT status FROM sales_orders WHERE id = soB);
    END IF;
    IF line_spoken_for(LB) <> 12 THEN
        RAISE EXCEPTION 'FIXTURE 69B 失败:发满之后已许出去应当是 12,实得 %', line_spoken_for(LB);
    END IF;

    -- 缺陷本身:同一行再预留 12
    v_msg := NULL;
    BEGIN
        PERFORM reserve_stock(LB, obB, 12);
        RAISE EXCEPTION 'FIXTURE 69B 失败:一条已经发满 12 的行【又预留了 12】—— 这正是线上探到的双重发货';
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        IF v_msg NOT LIKE 'SO_RESERVE_EXCEEDS_LINE%' THEN RAISE; END IF;
    END;
    -- 【三段都验】第三段的含义正是本刀改掉的东西:它现在是"已许出去"(已发 +
    -- 活预留),而不是"已预留"。此刻活预留是 0,所以一个还在数活预留的实现
    -- 会在这里吐出 0,而不是 12 —— 这一句就是那个分水岭。
    IF split_part(v_msg, '|', 2) <> '12' OR split_part(v_msg, '|', 3) <> '12'
       OR split_part(v_msg, '|', 4) <> '12' THEN
        RAISE EXCEPTION 'FIXTURE 69B 失败:拒绝消息应当是 SO_RESERVE_EXCEEDS_LINE|12|12|12(要预留|行数量|已许出去),实得 %', v_msg;
    END IF;

    -- 【钱这一侧】负债只释放了一次:这张单的 2500 精确归零
    -- (开票贷 120 USD × 1.25 = 150;发货借 150。第二次发货若走通,这里会是净借 150)
    SELECT COALESCE(sum(jl.debit - jl.credit), 0) INTO v_2500
      FROM journal_lines jl
      JOIN accounts a ON a.id = jl.account_id
      JOIN journal_entries je ON je.id = jl.entry_id
     WHERE a.code = '2500'
       AND (je.source_id IN (SELECT id FROM shipments WHERE sales_order_id = soB)
            OR je.source_id IN (SELECT id FROM invoices WHERE sales_order_id = soB));
    IF v_2500 <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 69B 失败:整行发完之后合同负债应当精确归零,实得 %', v_2500;
    END IF;

    -- ══════════ C. 边界:发 8 → 正好剩 4 ═════════════════════════════════════
    PERFORM create_order_invoice(soC, d, NULL, NULL, NULL, ARRAY[LC]);
    resC := (reserve_stock(LC, obC, 12) ->> 'reservation_id')::uuid;
    -- 部分发货 8(预留 12):ship_order 先把预留拆开,4 回到 available
    PERFORM ship_order(soC, d, jsonb_build_array(
        jsonb_build_object('reservation_id', resC, 'qty', 8)));

    IF line_spoken_for(LC) <> 8 THEN
        RAISE EXCEPTION 'FIXTURE 69C 失败:发掉 8 之后已许出去应当是 8(拆开的 4 已回到可用),实得 %', line_spoken_for(LC);
    END IF;
    -- 5 要不到 —— 只剩 4
    BEGIN
        PERFORM reserve_stock(LC, obC, 5);
        RAISE EXCEPTION 'FIXTURE 69C 失败:发掉 8 之后只剩 4,5 不该预留得了';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_RESERVE_EXCEEDS_LINE%' THEN RAISE; END IF;
        IF split_part(SQLERRM, '|', 4) <> '8' THEN
            RAISE EXCEPTION 'FIXTURE 69C 失败:第三段应当是已许出去的 8,实得 %', SQLERRM;
        END IF;
    END;
    -- 【正向:4 正好通】—— 一个"发过就整行封死"的实现死在这一句上
    PERFORM reserve_stock(LC, obC, 4);
    IF line_spoken_for(LC) <> 12 THEN
        RAISE EXCEPTION 'FIXTURE 69C 失败:8 已发 + 4 已预留 = 12,实得 %', line_spoken_for(LC);
    END IF;
    -- 满了:再要 1 就该拒
    BEGIN
        PERFORM reserve_stock(LC, obC, 1);
        RAISE EXCEPTION 'FIXTURE 69C 失败:8 已发 + 4 已预留,行已经满了,还能再预留 1';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_RESERVE_EXCEEDS_LINE%' THEN RAISE; END IF;
    END;

    -- ══════════ D. 释放的不算 ════════════════════════════════════════════════
    -- 【为什么必须有这一臂】"已许出去"若只加不减,B/C 两臂照样全过,而每一次
    -- 释放都会永久吃掉行的额度 —— 一条被释放的预留没有再许给任何人。
    resD := (reserve_stock(LD, obD, 12) ->> 'reservation_id')::uuid;
    IF line_spoken_for(LD) <> 12 THEN
        RAISE EXCEPTION 'FIXTURE 69D 失败:预留 12 之后应当是 12,实得 %', line_spoken_for(LD);
    END IF;
    PERFORM release_reservation(resD, NULL, 'fixture 69 D');
    IF line_spoken_for(LD) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 69D 失败:整笔释放之后已许出去应当回到 0,实得 %', line_spoken_for(LD);
    END IF;
    -- 而且额度真的回来了(不是只有数字好看)
    PERFORM reserve_stock(LD, obD, 12);

    -- ══════════ E. 注入(最后一臂)══════════════════════════════════════════
    -- 把 line_spoken_for 换回【只数活预留】—— 也就是本刀之前的判据。
    -- 双重发货必须当场走通;走不通就说明 B 臂一直靠别的东西挡着,那条断言在空转。
    EXECUTE $inj$
        CREATE OR REPLACE FUNCTION public.line_spoken_for(p_sales_order_line_id uuid)
         RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER
         SET search_path TO 'public', 'pg_temp'
        AS $f$
            -- 【被换掉的那一半】:已发不算
            SELECT COALESCE((SELECT sum(r.qty) FROM sales_order_reservations r
                              WHERE r.sales_order_line_id = p_sales_order_line_id
                                AND r.released_at IS NULL
                                AND r.consumed_at IS NULL), 0);
        $f$;
    $inj$;

    PERFORM create_order_invoice(soE, d, NULL, NULL, NULL, ARRAY[LE]);
    resE := (reserve_stock(LE, obE, 12) ->> 'reservation_id')::uuid;
    PERFORM ship_order(soE, d, jsonb_build_array(jsonb_build_object('reservation_id', resE)));

    v_ok := true;
    BEGIN
        resE := (reserve_stock(LE, obE, 12) ->> 'reservation_id')::uuid;
        PERFORM ship_order(soE, d, jsonb_build_array(jsonb_build_object('reservation_id', resE)));
    EXCEPTION WHEN OTHERS THEN
        v_ok := false;
        v_msg := SQLERRM;
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 69E 失败:把判据换回【只数活预留】之后,双重发货【仍然】走不通(%)—— 说明 B 臂一直靠别的东西挡着,那条断言在空转', v_msg;
    END IF;
    SELECT COALESCE(sum(sl.qty), 0) INTO v_qty
      FROM shipment_lines sl JOIN shipments s ON s.id = sl.shipment_id
     WHERE s.sales_order_id = soE AND sl.sales_order_line_id = LE;
    IF v_qty <> 24 THEN
        RAISE EXCEPTION 'FIXTURE 69E 失败:注入之后这条 12 的行应当发出 24,实得 %', v_qty;
    END IF;
    -- 而且账上看得见:2500 变成【净借方】—— 负债被释放了两次
    SELECT COALESCE(sum(jl.debit - jl.credit), 0) INTO v_2500
      FROM journal_lines jl
      JOIN accounts a ON a.id = jl.account_id
      JOIN journal_entries je ON je.id = jl.entry_id
     WHERE a.code = '2500'
       AND (je.source_id IN (SELECT id FROM shipments WHERE sales_order_id = soE)
            OR je.source_id IN (SELECT id FROM invoices WHERE sales_order_id = soE));
    IF v_2500 <= 0 THEN
        RAISE EXCEPTION 'FIXTURE 69E 失败:注入之后合同负债应当被释放两次(净借方 > 0),实得 %', v_2500;
    END IF;
END $$;
ROLLBACK;
