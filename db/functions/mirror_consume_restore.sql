CREATE OR REPLACE FUNCTION public.mirror_consume_restore(p_run_id uuid, p_inbound_batch_id uuid, p_output_batch_id uuid, p_expected_total numeric, p_business_date date, p_created_by uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_row record;
    v_sum numeric := 0;
BEGIN
    -- 【为什么必须逐行镜像,而不是按 drain 顺序倒推】
    -- 投料按"NULL 桶优先、再按库位 code"排空;还原若也按某条规则重新分配,
    -- 两者在一般情形下【并不相等】(中间可能发生过转移、暂扣、别的消耗)。
    -- 差额不会报错,它只会安静地把货放回错的库位。所以还原读的是事实:
    -- 这张加工单当初到底从哪几个桶里各拿走了多少。
    FOR v_row IN
        SELECT m.location_id, m.stock_status, -m.qty_delta AS qty
        FROM inventory_movements m
        WHERE m.run_id = p_run_id
          AND m.movement_type = 'processing_consume'
          AND m.inbound_batch_id IS NOT DISTINCT FROM p_inbound_batch_id
          AND m.output_batch_id  IS NOT DISTINCT FROM p_output_batch_id
        ORDER BY m.created_at, m.id
    LOOP
        INSERT INTO inventory_movements
            (inbound_batch_id, output_batch_id, location_id, movement_type,
             qty_delta, stock_status, run_id, business_date, created_by)
        VALUES (p_inbound_batch_id, p_output_batch_id, v_row.location_id, 'reversal_restore',
                v_row.qty, v_row.stock_status, p_run_id, p_business_date, p_created_by);
        v_sum := v_sum + v_row.qty;
    END LOOP;

    -- 【对不上就点名,不悄悄少写几行】还原总额与 remaining_qty 的回补必须一致,
    -- 否则台账与缓存当场分家(check_ledger_invariant 会在提交时抓到,但那时
    -- 报出来的是一句关于不变量的话,不是"还原对不上原始投料")。
    IF v_sum <> p_expected_total THEN
        RAISE EXCEPTION 'IOD_RESTORE_MISMATCH|%|%', p_expected_total, v_sum;
    END IF;
END;
$function$

;
