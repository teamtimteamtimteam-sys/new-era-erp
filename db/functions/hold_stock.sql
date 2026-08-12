CREATE OR REPLACE FUNCTION public.hold_stock(p_qty numeric, p_reason text, p_inbound_batch_id uuid DEFAULT NULL::uuid, p_output_batch_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_pair uuid := gen_random_uuid();
    v_avail numeric;
    v_today date := CURRENT_DATE;
BEGIN
    PERFORM require_permission('module.inventory.edit');

    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN
        RAISE EXCEPTION 'STK_ONE_BATCH';
    END IF;
    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'STK_QTY_INVALID|%', COALESCE(p_qty::text, '?');
    END IF;
    -- 暂扣要留下【为什么】—— 一次没有理由的扣货,过两天没人说得清该不该放
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'STK_REASON_REQUIRED';
    END IF;

    -- 【只能现算】remaining_qty 是批次级缓存,没有库位轴、更没有状态轴;
    -- 而暂扣发生在 批次 × 库位 × 状态 这个粒度上。
    v_avail := derived_stock_qty(p_inbound_batch_id, p_output_batch_id, p_location_id, 'available');
    IF p_qty > v_avail THEN
        RAISE EXCEPTION 'STK_HOLD_EXCEEDS_AVAILABLE|%|%', p_qty, v_avail;
    END IF;

    -- 成对:出 available、进 on_hold。物理总量按构造不动。
    INSERT INTO inventory_movements
        (inbound_batch_id, output_batch_id, location_id, movement_type,
         qty_delta, stock_status, status_pair_id, business_date, notes, created_by)
    VALUES
        (p_inbound_batch_id, p_output_batch_id, p_location_id, 'status_change_out',
         -p_qty, 'available', v_pair, v_today, btrim(p_reason), v_user),
        (p_inbound_batch_id, p_output_batch_id, p_location_id, 'status_change_in',
          p_qty, 'on_hold',   v_pair, v_today, btrim(p_reason), v_user);

    RETURN jsonb_build_object('status_pair_id', v_pair, 'qty', p_qty,
                              'available_after', v_avail - p_qty);
END;
$function$

;
