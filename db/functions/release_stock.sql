CREATE OR REPLACE FUNCTION public.release_stock(p_qty numeric, p_inbound_batch_id uuid DEFAULT NULL::uuid, p_output_batch_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_pair uuid := gen_random_uuid();
    v_held numeric;
    v_today date := CURRENT_DATE;
BEGIN
    PERFORM require_permission('module.inventory.edit');

    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN
        RAISE EXCEPTION 'STK_ONE_BATCH';
    END IF;
    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'STK_QTY_INVALID|%', COALESCE(p_qty::text, '?');
    END IF;
    -- 【释放的备注是可选的,而这不对称是有意的】扣住货需要理由(它限制别人),
    -- 放开只是让事情回到常态。强制一个没人真想写的字段,换来的是一堆 "ok"。

    v_held := derived_stock_qty(p_inbound_batch_id, p_output_batch_id, p_location_id, 'on_hold');
    IF p_qty > v_held THEN
        RAISE EXCEPTION 'STK_RELEASE_EXCEEDS_HELD|%|%', p_qty, v_held;
    END IF;

    INSERT INTO inventory_movements
        (inbound_batch_id, output_batch_id, location_id, movement_type,
         qty_delta, stock_status, pair_id, business_date, notes, created_by)
    VALUES
        (p_inbound_batch_id, p_output_batch_id, p_location_id, 'status_change_out',
         -p_qty, 'on_hold',   v_pair, v_today, NULLIF(btrim(COALESCE(p_note, '')), ''), v_user),
        (p_inbound_batch_id, p_output_batch_id, p_location_id, 'status_change_in',
          p_qty, 'available', v_pair, v_today, NULLIF(btrim(COALESCE(p_note, '')), ''), v_user);

    RETURN jsonb_build_object('pair_id', v_pair, 'qty', p_qty,
                              'held_after', v_held - p_qty);
END;
$function$

;
