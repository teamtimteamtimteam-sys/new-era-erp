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
$function$

;
