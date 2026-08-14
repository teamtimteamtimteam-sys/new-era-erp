-- SO-3b fu5(2026-08-15):行的天花板漏掉了【已发】—— 同一行发得了两次
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【缺陷,实测出来的,不是读出来的】reserve_stock 的行天花板就地对【活预留】
-- 求和(released_at 与 consumed_at 都为空)。而发货【正是】把 consumed_at 填上 ——
-- 于是一条发满的行,它已经许出去的那部分从判据里整个消失,天花板重新变回满额。
--
-- 探针(线上,全程回滚,用的是真的 create_order_invoice / reserve_stock / ship_order):
--     发票 INV-…  12 kg × 10 = 120         ← 第 1 行只开这一张
--     第一次发货 SHP-…  收入 120.00  订单状态 partially_shipped
--     二次预留   ✗ 通过了                   ← 同一行,又许出去 12
--     第二次发货 ✗ 通过了  收入 120.00
--     结果:第 1 行已订 12,【已发 24】;2500 净借方 120.00;4000 收入 240.00
-- 也就是:24 kg 出库、合同负债落成【负数】、收入是发票的两倍,而应收仍是 120。
-- 对照臂证明探针不空转:第一条预留还活着时,同一次调用被按名拒
--     SO_RESERVE_EXCEEDS_LINE|12|12|12
--
-- 【可达条件】订单停在 partially_shipped(多行单,一行发完、另一行没发)。
-- reserve_stock 与 create_order_invoice 都收 partially_shipped —— 那是 SO-3b fu1
-- 有意放开的(只认 confirmed 会让任何多行订单在第一次发货之后走不下去)。
-- 单行单发完即 shipped,预留会被状态那一关挡住,所以单行单不可达。
--
-- 【修法:一处推导,两个消费方】
-- line_spoken_for(行) = Σ 已发 + Σ 活预留 —— "这一行已经许出去多少"。
-- 今天由 reserve_stock 的天花板读;SO-1b 的改单【下限】读【同一个函数】,
-- 而不是另写一遍(两份推导会在写下的那天一致,此后各自漂移 —— 这个仓库
-- 已经为这条付过四次账:验资影响预览、GrantRunner、重估预览、/finance/payments)。
--
-- 【为什么已发那一半读 shipment_lines,而不是"已消耗的预留"】两者今天恒等:
-- shipment_lines.reservation_id 是 NOT NULL UNIQUE,ship_order 在同一个事务里
-- 写发货行、并把那条预留标成 consumed。选 shipment_lines 是因为它是【货真的
-- 离开了】的记录,而 consumed_at 只是预留的终局标记 —— 判据该长在事实上。
--
-- 【第三个数的含义变了】SO_RESERVE_EXCEEDS_LINE|要预留|行数量|已许出去
-- 第三段此前是"已预留",现在是"已发 + 活预留"。两个语言的句子同步改掉 ——
-- 一条把 12 说成"已经预留 12"、而屏幕上一条活预留都没有的消息,比不说更糟。
--
-- 【没有 schema 改动】—— 两个函数,一条 REVOKE(由 apply_migration.sh 重放
-- zzz_function_grants.sql 在同一个事务里落实,OPS-7)。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 一处推导 ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.line_spoken_for(p_sales_order_line_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- SO-3b fu5:【这一行已经许出去多少】= 已发 + 活预留。
    --
    -- 【这是唯一一处推导】两个消费方:
    --   ① reserve_stock 的行天花板(许出去的 + 本次 ≤ 行数量);
    --   ② SO-1b 改单的【下限】—— 一条已经许出去 N 的行改不到 N 以下,
    --      读的是【同一个函数】,不另写一遍。
    -- 两份推导会在写下的那天一致,此后各自漂移;这条缺陷本身就是"活预留"这
    -- 一个口径被当成两个意思用出来的。
    --
    -- 【已发读 shipment_lines,不读"已消耗的预留"】两者恒等
    -- (shipment_lines.reservation_id 是 NOT NULL UNIQUE,ship_order 同一个事务里
    -- 写发货行并把预留标成 consumed),取前者是因为它是【货真的离开了】的记录。
    -- 也因此不会重复计数:一条预留要么还活着,要么已经变成一条发货行。
    --
    -- 【释放了的不算】释放把货放回 available,那一份没有再许给任何人。
    SELECT COALESCE((SELECT sum(sl.qty) FROM shipment_lines sl
                      WHERE sl.sales_order_line_id = p_sales_order_line_id), 0)
         + COALESCE((SELECT sum(r.qty) FROM sales_order_reservations r
                      WHERE r.sales_order_line_id = p_sales_order_line_id
                        AND r.released_at IS NULL
                        AND r.consumed_at IS NULL), 0);
$function$;

-- ── 天花板读它 ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.reserve_stock(p_sales_order_line_id uuid, p_output_batch_id uuid, p_qty numeric, p_location_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_pair     uuid := gen_random_uuid();
    v_today    date := CURRENT_DATE;
    v_line     record;
    v_batch    record;
    v_avail    numeric;
    v_already  numeric;
    v_res_id   uuid;
BEGIN
    -- 【为什么是 module.sales.edit,而不是 module.inventory.edit】
    -- 预留就是一次销售行为 —— 做它的人是销售。给它挑一个"销售与库存都满足"的
    -- 权限码,只能挑一个比两者都松的,那不是把关、是把关的样子(与
    -- zzz_function_grants 给 drain_stock 写的那条理由同形)。而台账的不变量
    -- 不依赖调用者是谁:成对写入让物理总量按构造不动,check_no_negative_bucket
    -- 是约束触发器,对任何身份一视同仁。
    PERFORM require_permission('module.sales.edit');

    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'SO_RESERVE_QTY_INVALID|%', COALESCE(p_qty::text, '?');
    END IF;

    SELECT l.id, l.quantity, l.material_id, l.line_no,
           o.id AS order_id, o.code AS order_code, o.status, o.deleted_at
      INTO v_line
      FROM sales_order_lines l
      JOIN sales_orders o ON o.id = l.sales_order_id
     WHERE l.id = p_sales_order_line_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_sales_order_line_id::text, '?');
    END IF;

    -- 【只有确认了的订单才预留】草稿是还没答应的事,给它扣住货,等于让一张
    -- 随手建的单据把库存冻起来,而没有任何人做过那个承诺。
    -- 【SO-3b:partially_shipped 同样算数】一张发了一部分的单【仍然是活的】——
    -- 剩下的行还要预留、还要发。只认 confirmed 会让任何多行订单在第一次发货
    -- 之后就再也走不下去(fixture 68 第一次跑就撞上了这个)。
    IF v_line.deleted_at IS NOT NULL OR v_line.status NOT IN ('confirmed', 'partially_shipped') THEN
        RAISE EXCEPTION 'SO_RESERVE_ORDER_NOT_CONFIRMED|%|%',
            v_line.order_code, COALESCE(v_line.status, '?');
    END IF;

    -- 【产出批次,且还在】—— 见本表注释:预留一个进料批次会造出永远消耗不掉的
    -- 承诺库存(movement_type='sale' 被 inventory_movements_side 钉在产出侧)。
    SELECT ob.id, ob.code, ob.material_id, ob.unit
      INTO v_batch
      FROM output_batches ob
     WHERE ob.id = p_output_batch_id AND ob.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_RESERVE_OUTPUT_ONLY|%', COALESCE(p_output_batch_id::text, '?');
    END IF;

    IF v_batch.material_id IS DISTINCT FROM v_line.material_id THEN
        RAISE EXCEPTION 'SO_RESERVE_MATERIAL_MISMATCH|%|%|%',
            v_batch.code,
            (SELECT code FROM materials WHERE id = v_batch.material_id),
            (SELECT code FROM materials WHERE id = v_line.material_id);
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【行的天花板 —— 判据是"这一行已经许出去多少"】一行订单最多只能许出它
    -- 自己的数量。超过就是把同一行答应了两遍 —— 屏幕上看不出来,发货那天才炸。
    --
    -- 【SO-3b fu5:此前这里只数【活预留】,而发货会把预留移出那个集合】
    -- 于是一条发满的行,天花板重新变回满额:实测 12 kg 的行发掉 12 之后又预留
    -- 了 12、又发了一次,24 kg 出库、2500 落成净借方、收入是发票的两倍。
    -- 判据换成 line_spoken_for()(已发 + 活预留),而那是【唯一一处推导】——
    -- SO-1b 改单的下限读同一个函数,不另写一遍。
    -- 第三个数的含义随之变了:它现在是"已许出去",不是"已预留"(两种语言的
    -- 句子同步改过)。
    -- ════════════════════════════════════════════════════════════════════════
    v_already := line_spoken_for(p_sales_order_line_id);
    IF v_already + p_qty > v_line.quantity THEN
        RAISE EXCEPTION 'SO_RESERVE_EXCEEDS_LINE|%|%|%', p_qty, v_line.quantity, v_already;
    END IF;

    -- 【就地求和,不调 derived_stock_qty】那个函数体里有
    -- require_permission('module.inventory.view'),而 has_permission 解析的是
    -- 【调用者】的 JWT —— DEFINER 换得了行的可见性,换不了函数体内那句对调用者
    -- 的判断。销售的人没有库存的码,调过去当场 PERMISSION_DENIED。
    -- record_output_sale 就地求和,同一个理由。
    SELECT COALESCE(sum(m.qty_delta), 0) INTO v_avail
      FROM inventory_movements m
     WHERE m.output_batch_id = p_output_batch_id
       AND m.inbound_batch_id IS NULL
       AND m.location_id IS NOT DISTINCT FROM p_location_id
       AND m.stock_status = 'available';
    IF p_qty > v_avail THEN
        RAISE EXCEPTION 'SO_RESERVE_EXCEEDS_AVAILABLE|%|%', p_qty, v_avail;
    END IF;

    -- 成对:出 available、进 committed。同批次、同库位。物理总量按构造不动,
    -- remaining_qty 一个字不变,批次的 state 也不变(承诺不是销售)。
    INSERT INTO inventory_movements
        (output_batch_id, location_id, movement_type,
         qty_delta, stock_status, pair_id, business_date, notes, created_by)
    VALUES
        (p_output_batch_id, p_location_id, 'status_change_out',
         -p_qty, 'available', v_pair, v_today,
         'reserved for ' || v_line.order_code || ' line ' || v_line.line_no, v_user),
        (p_output_batch_id, p_location_id, 'status_change_in',
          p_qty, 'committed', v_pair, v_today,
         'reserved for ' || v_line.order_code || ' line ' || v_line.line_no, v_user);

    INSERT INTO sales_order_reservations
        (sales_order_line_id, output_batch_id, location_id, qty, pair_id, created_by)
    VALUES (p_sales_order_line_id, p_output_batch_id, p_location_id, p_qty, v_pair, v_user)
    RETURNING id INTO v_res_id;

    INSERT INTO sales_order_history (sales_order_id, change_type, detail)
    VALUES (v_line.order_id, 'reserved',
            format('line %s · %s %s %s', v_line.line_no, v_batch.code, p_qty, v_batch.unit));

    RETURN jsonb_build_object(
        'reservation_id', v_res_id, 'pair_id', v_pair, 'qty', p_qty,
        'output_batch_id', p_output_batch_id, 'location_id', p_location_id,
        'available_after', v_avail - p_qty,
        -- 【改名,因为含义改了】此前叫 line_reserved_after,而它现在含【已发】。
        -- 一个名字说着旧含义、值是新含义,比改名更贵(今天没有任何消费方读它,
        -- 现在改是最便宜的时刻)。
        'line_spoken_for_after', v_already + p_qty,
        'line_quantity', v_line.quantity);
END;
$function$;

COMMIT;
