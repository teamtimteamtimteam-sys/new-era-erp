CREATE OR REPLACE FUNCTION public.record_output_sale(p_output_batch_id uuid, p_quantity numeric, p_sale_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_user      uuid := auth.uid();
    v_deleted   timestamptz;
    v_remaining numeric;
    v_new_remaining numeric;
    v_state     text;
BEGIN
    SELECT deleted_at, remaining_qty INTO v_deleted, v_remaining
    FROM output_batches WHERE id = p_output_batch_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', p_output_batch_id;
    END IF;
    IF v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'OUTPUT_DELETED';
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'SALE_QTY_INVALID';
    END IF;
    IF p_quantity > v_remaining THEN
        RAISE EXCEPTION 'SALE_EXCEEDS_REMAINING|%|%', p_quantity, v_remaining;
    END IF;

    INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date, notes, created_by)
    VALUES (p_output_batch_id, 'sale', -p_quantity, COALESCE(p_sale_date, CURRENT_DATE), p_notes, v_user);

    v_new_remaining := v_remaining - p_quantity;
    v_state := CASE WHEN v_new_remaining = 0 THEN '已售罄' ELSE '部分售出' END;

    UPDATE output_batches
    SET remaining_qty = v_new_remaining,
        state = v_state,
        updated_by = v_user,
        updated_at = now()
    WHERE id = p_output_batch_id;

    RETURN jsonb_build_object(
        'output_batch_id', p_output_batch_id,
        'sold', p_quantity,
        'remaining_qty', v_new_remaining,
        'state', v_state
    );
END;
$function$
