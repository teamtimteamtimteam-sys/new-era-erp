CREATE OR REPLACE FUNCTION public.rollback_processing_run(p_run_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_user_id uuid := auth.uid();
    v_run_deleted_at timestamptz;
    v_bad_output record;
    v_input record;
    v_new_remaining numeric;
    v_quantity numeric;
BEGIN
    -- 1. 锁定加工单，校验存在且未删除
    SELECT deleted_at INTO v_run_deleted_at
    FROM processing_runs
    WHERE id = p_run_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_run_id;
    END IF;

    IF v_run_deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_ALREADY_DELETED';
    END IF;

    -- 2. 安全检查：任何一个产出批次动过就拒绝
    SELECT ob.code, ob.state, ob.quantity, ob.remaining_qty
    INTO v_bad_output
    FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = p_run_id
      AND ob.deleted_at IS NULL
      AND (ob.state <> '库存中' OR ob.remaining_qty <> ob.quantity)
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION 'OUTPUT_CONSUMED|%|%|%|%',
            v_bad_output.code, v_bad_output.state, v_bad_output.remaining_qty, v_bad_output.quantity;
    END IF;

    -- 3. 还原进料：加回 remaining_qty，重判 stage
    FOR v_input IN
        SELECT pi.inbound_batch_id, pi.quantity_consumed
        FROM processing_inputs pi
        WHERE pi.run_id = p_run_id
    LOOP
        SELECT quantity INTO v_quantity
        FROM inbound_batches
        WHERE id = v_input.inbound_batch_id
        FOR UPDATE;

        IF NOT FOUND THEN
            CONTINUE;  -- 进料批次已被删，跳过
        END IF;

        v_new_remaining := LEAST(
            COALESCE((SELECT remaining_qty FROM inbound_batches WHERE id = v_input.inbound_batch_id), 0)
                + v_input.quantity_consumed,
            v_quantity
        );

        UPDATE inbound_batches
        SET remaining_qty = v_new_remaining,
            stage = CASE WHEN v_new_remaining >= v_quantity THEN '待加工' ELSE '加工中' END,
            updated_by = v_user_id,
            updated_at = now()
        WHERE id = v_input.inbound_batch_id;
    END LOOP;

    -- 4. 软删这张单生成的产出批次
    UPDATE output_batches
    SET deleted_at = now(),
        updated_by = v_user_id,
        updated_at = now()
    WHERE id IN (
        SELECT output_batch_id FROM processing_outputs WHERE run_id = p_run_id
    )
    AND deleted_at IS NULL;

    -- 5. 软删加工单本身（腿表保留作审计）
    UPDATE processing_runs
    SET status = 'reversed',
        deleted_at = now(),
        updated_by = v_user_id,
        updated_at = now()
    WHERE id = p_run_id;
END;
$function$
