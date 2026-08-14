CREATE OR REPLACE FUNCTION public.create_stock_transfer(p_qty numeric, p_to_location_id uuid, p_inbound_batch_id uuid DEFAULT NULL::uuid, p_output_batch_id uuid DEFAULT NULL::uuid, p_from_location_id uuid DEFAULT NULL::uuid, p_stock_status text DEFAULT 'available'::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_pair     uuid := gen_random_uuid();
    v_have     numeric;
    v_today    date := CURRENT_DATE;
    v_material uuid;
    v_warn     text[];
    v_reserved numeric;
BEGIN
    PERFORM require_permission('module.inventory.edit');

    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN
        RAISE EXCEPTION 'STK_ONE_BATCH';
    END IF;
    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'STK_QTY_INVALID|%', COALESCE(p_qty::text, '?');
    END IF;
    -- SO-2:【一个坏状态不是一个坏数量】。此前这里抛的是 STK_QTY_INVALID,
    -- 于是"你传了一个系统不认识的库存状态"会在屏幕上显示成"数量无效" ——
    -- 一条把人送去看错地方的消息。三个桶都在这里列出来。
    IF p_stock_status IS NULL OR p_stock_status NOT IN ('available','on_hold','committed') THEN
        RAISE EXCEPTION 'IOD_TRANSFER_STATUS_INVALID|%', COALESCE(p_stock_status, '?');
    END IF;
    -- 【源与目的相同】不是一次无害的空操作:它会写下两行互相抵消的流水,
    -- 把台账弄脏,而且几乎总是意味着操作的人选错了一边。
    IF p_from_location_id IS NOT DISTINCT FROM p_to_location_id THEN
        RAISE EXCEPTION 'IOD_TRANSFER_SAME_LOCATION';
    END IF;
    -- 目的地必须是一个【在用】的库位。停用的库位不该再收货(LOC-1 的停用语义)。
    IF p_to_location_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM storage_locations WHERE id = p_to_location_id AND is_active) THEN
        RAISE EXCEPTION 'IOD_TRANSFER_TO_INACTIVE|%', COALESCE(p_to_location_id::text, '?');
    END IF;

    -- 【同一粒度】对着派生桶比,与 STK-1 的暂扣/释放一模一样:
    -- remaining_qty 没有库位轴,在这个粒度上现算是唯一可能的来源。
    v_have := derived_stock_qty(p_inbound_batch_id, p_output_batch_id, p_from_location_id, p_stock_status);
    IF p_qty > v_have THEN
        RAISE EXCEPTION 'IOD_TRANSFER_EXCEEDS_BUCKET|%|%', p_qty, v_have;
    END IF;

    -- IOD-2:落闸,【只在入腿上】。物料从批次反查 —— 两种批次二选一(上面的
    -- XOR 已经保证恰好一个非空),两张表都有 material_id NOT NULL。
    -- 【出腿一个字都不查】:分类管的是货可以待在哪里,不是货能不能离开;拦住
    -- 一批放错地方的货【离开】,只会把它焊死在错的地方。
    v_material := COALESCE(
        (SELECT material_id FROM inbound_batches WHERE id = p_inbound_batch_id),
        (SELECT material_id FROM output_batches  WHERE id = p_output_batch_id));
    v_warn := check_location_class(p_to_location_id, v_material);
    -- NTF-1:告警留一份下来(入腿的库位/物料)。返回值那一份不变。
    PERFORM notify_landing_warnings(v_warn, p_to_location_id, v_material);

    -- 成对:出源库位、进目的库位。【状态原样带过去】—— 转移搬的是位置,
    -- 不是状态;一批被扣住的货换个货架仍然是被扣住的。
    INSERT INTO inventory_movements
        (inbound_batch_id, output_batch_id, location_id, movement_type,
         qty_delta, stock_status, pair_id, business_date, notes, created_by)
    VALUES
        (p_inbound_batch_id, p_output_batch_id, p_from_location_id, 'transfer_out',
         -p_qty, p_stock_status, v_pair, v_today, NULLIF(btrim(COALESCE(p_note,'')),''), v_user),
        (p_inbound_batch_id, p_output_batch_id, p_to_location_id, 'transfer_in',
          p_qty, p_stock_status, v_pair, v_today, NULLIF(btrim(COALESCE(p_note,'')),''), v_user);

    -- ════════════════════════════════════════════════════════════════════════
    -- SO-2:【committed 的货搬走了,预留行必须跟着走 —— 而且只允许整桶搬】
    --
    -- 预留行记的是 批次 × 库位 这个桶。桶里的货搬到别的库位,而预留行还写着
    -- 老库位,那两句话当场对不上:流水说这 40kg 在 B,预留说它在 A。
    --
    -- 【为什么只允许整桶】部分搬走就得回答"这 40 里哪 15 跟着走" —— 而预留行
    -- 是按订单行分的,没有任何东西能回答那个问题;系统替人挑一行,就是编造。
    -- 所以:整桶搬,预留行的 location_id 跟着改(那是"这批货现在放在哪",不是
    -- "当初许了什么");搬不完就点名拒绝,补救写在消息里 —— 先部分释放,
    -- 再搬,再重新预留。三步各自留下自己的痕迹。
    --
    -- 【改 location_id 是本表唯一允许的事后改写】,由 evoltrya.reservation_move_ctx
    -- 向守卫说明"这是转移在改",而不是让守卫对任何 UPDATE 都放行一列。
    -- ════════════════════════════════════════════════════════════════════════
    IF p_stock_status = 'committed' THEN
        SELECT COALESCE(sum(r.qty), 0) INTO v_reserved
          FROM sales_order_reservations r
         WHERE r.output_batch_id IS NOT DISTINCT FROM p_output_batch_id
           AND r.location_id IS NOT DISTINCT FROM p_from_location_id
           AND r.released_at IS NULL AND r.consumed_at IS NULL;

        IF v_reserved > 0 AND p_qty <> v_reserved THEN
            RAISE EXCEPTION 'IOD_TRANSFER_COMMITTED_PARTIAL|%|%', p_qty, v_reserved;
        END IF;

        IF v_reserved > 0 THEN
            PERFORM set_config('evoltrya.reservation_move_ctx', '1', true);
            UPDATE sales_order_reservations
               SET location_id = p_to_location_id
             WHERE output_batch_id IS NOT DISTINCT FROM p_output_batch_id
               AND location_id IS NOT DISTINCT FROM p_from_location_id
               AND released_at IS NULL AND consumed_at IS NULL;
            PERFORM set_config('evoltrya.reservation_move_ctx', '', true);
        END IF;
    END IF;

    RETURN jsonb_build_object('pair_id', v_pair, 'qty', p_qty,
                              'stock_status', p_stock_status,
                              'warnings', to_jsonb(v_warn));
END;
$function$

;
