-- db/migrations/2026-08-15-so3b-fu4-comments-and-the-drain-note.sql
-- SO-3b 收尾:两条列注释 + drain_stock 的那段【互指】注释,都上线
--
-- 【判词【镜像 vs 线上】抓到的三处,全是文本】两条 COMMENT 只写进了迁移
-- (于是活在线上)却没写进表镜像;drain_stock 的注释反过来 —— 只改了镜像,
-- 没上线上。三处都不改行为,而门红得对:镜像与线上逐字不同,就意味着
-- 重建出来的库与线上不是同一个库。
--
-- 【方向:让两边都拿到那段解释】drain_stock 那段是载荷 —— 它说明"订单流发货
-- 为什么不走排空器",而下一个读 ship_order 的人一定会问这句。
-- 镜像:db/tables/{sales_order_reservations,sales_records}.sql(补 COMMENT)、
--       db/functions/drain_stock.sql(不变,本支向它对齐)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

COMMENT ON COLUMN public.sales_order_reservations.consumed_at IS
    'SO-3b:这条预留被【发货消耗】掉的时刻。与 released_* 并列而不是共用那三列 —— 释放是"货回到 available"(有一对反向流水),消耗是"货离开了台账"(没有反向流水,对应一条 sale 出库腿与一行 shipment_lines)。活预留 = released_at IS NULL AND consumed_at IS NULL。';

COMMENT ON COLUMN public.sales_records.sales_order_line_id IS
    'SO-3b:这一行是不是【订单流发货】产生的。非空 = 是,并指向它满足的那条订单行。后果就在本刀落地:这样的行【不产生应收】—— 那笔债在开票当刻已经记过(借 1100 / 贷 2500),发货只是把负债释放进收入。ar_open_items 的第一支与 customer_ar_exposure_base 的第一项都显式排除它,于是同一笔债不会被数两遍(选项 C 的核心不变量:应收只创建一次)。由 ship_order 在 INSERT 当刻写好,之后不可改(SALE_IMMUTABLE)。';

CREATE OR REPLACE FUNCTION public.drain_stock(p_qty numeric, p_movement_type text, p_business_date date, p_inbound_batch_id uuid DEFAULT NULL::uuid, p_output_batch_id uuid DEFAULT NULL::uuid, p_statuses text[] DEFAULT ARRAY['available'::text], p_run_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text, p_created_by uuid DEFAULT NULL::uuid)
 RETURNS uuid[]
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_left numeric := p_qty;
    v_take numeric;
    v_row  record;
    v_ids  uuid[] := ARRAY[]::uuid[];
    v_id   uuid;
BEGIN
    -- ═══════════════════════════════════════════════════════════════════════
    -- 【排空顺序是一条 POLICY,不是一条自然律】
    --   ① 先 NULL 桶(未指定库位),② 再按库位 code 升序。
    --   每碰一个桶写一行流水;所有行加起来【正好】等于 p_qty。
    --
    -- 为什么是这个顺序:未指定库位的货是"还没有人安置过"的货,先把它用掉,
    -- 库存就会自然朝"每一笔都有库位"收敛,而不是让 NULL 桶永远挂在那里。
    -- 库位之间按 code 升序,只是因为它【确定】—— 两次同样的消耗必须给出
    -- 同样的结果,否则台账不可复现。
    --
    -- ═══════════════════════════════════════════════════════════════════════
    -- 【SO-3b:它是给【没有地址】的消耗用的】销售直接卖、投料、注销 —— 那三条
    -- 路只说"拿 N 出来",没人指定该动哪一批、哪个库位,所以要有这条策略。
    -- 【订单流发货不走这里,而那不是漏用】预留【就是地址】(批次 × 库位 × 数量),
    -- ship_order 因此直接写那一条出库腿 —— 定址消耗。让它走这里,策略反而会
    -- 去猜一个已经知道的答案,并且可能取错桶(committed 有主人,而顺序里
    -- 没有"主人"这一维)。两边的函数头互相指着对方。
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- 【要改这条顺序(例如改成按转移日期 FIFO)需要动什么】改这个函数体一处,
    -- 外加 fixture 57 的排空顺序臂 —— 消耗的三个调用方(销售、投料、注销)
    -- 都不知道顺序,它们只说"拿 N 出来"。这是把顺序收在一处的全部理由:
    -- 换策略是改一个地方,不是改三个地方并祈祷它们一致。
    -- ═══════════════════════════════════════════════════════════════════════
    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'STK_QTY_INVALID|%', COALESCE(p_qty::text, '?');
    END IF;

    FOR v_row IN
        SELECT m.location_id, m.stock_status, sum(m.qty_delta) AS qty
        FROM inventory_movements m
        WHERE m.inbound_batch_id IS NOT DISTINCT FROM p_inbound_batch_id
          AND m.output_batch_id  IS NOT DISTINCT FROM p_output_batch_id
          AND m.stock_status = ANY (p_statuses)
        GROUP BY m.location_id, m.stock_status
        HAVING sum(m.qty_delta) > 0
        ORDER BY (m.location_id IS NOT NULL),                       -- NULL 桶在前
                 (SELECT l.code FROM storage_locations l WHERE l.id = m.location_id),
                 m.stock_status
    LOOP
        EXIT WHEN v_left <= 0;
        v_take := LEAST(v_left, v_row.qty);
        INSERT INTO inventory_movements
            (inbound_batch_id, output_batch_id, location_id, movement_type,
             qty_delta, stock_status, run_id, business_date, notes, created_by)
        VALUES (p_inbound_batch_id, p_output_batch_id, v_row.location_id, p_movement_type,
                -v_take, v_row.stock_status, p_run_id, p_business_date, p_notes, p_created_by)
        RETURNING id INTO v_id;
        v_ids := v_ids || v_id;
        v_left := v_left - v_take;
    END LOOP;

    -- 桶里凑不够 —— 调用方【应当】在调用之前就按自己的口径拒绝并说人话
    -- (销售说"可用不够"、投料说"这批投不了这么多")。走到这里说明那一层漏了,
    -- 所以这里点名报错,而不是少写几行了事:少写的那几行会让台账与缓存对不上。
    IF v_left > 0 THEN
        RAISE EXCEPTION 'IOD_DRAIN_INSUFFICIENT|%|%', p_qty, p_qty - v_left;
    END IF;

    RETURN v_ids;
END;
$function$;

COMMIT;
