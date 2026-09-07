CREATE OR REPLACE FUNCTION public.cod_delivery_completion(p_inbound_batch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ib          record;
    v_consumed    numeric;
    v_completed   date;
    v_other_doors numeric;
    v_runs_total  integer;
    v_runs_dated  integer;
BEGIN
    SELECT ib.id, ib.code, ib.quantity, ib.remaining_qty, ib.unit, ib.deleted_at
      INTO v_ib FROM inbound_batches ib WHERE ib.id = p_inbound_batch_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('complete', false, 'reason', 'BATCH_NOT_FOUND');
    END IF;

    -- ① 【被注销的料没有被处理,它被报废了】实测:线上 11 张 remaining_qty = 0
    --    的进料批里,8 张是这一类。按 remaining_qty 签发就是替这 8 张撒谎。
    IF v_ib.deleted_at IS NOT NULL THEN
        RETURN jsonb_build_object('complete', false, 'reason', 'DELIVERY_WRITTEN_OFF',
                                  'batch_code', v_ib.code);
    END IF;

    -- ② 【有没有从别的门出去过】writeoff 只有一个写入者(软删),
    --    sale 是卖掉 —— 两者都不是"被我们处理掉了"。
    --    ★ adjustment 【刻意不在这个清单里】★ 见文件抬头:带壳过磅、拆壳后计量,
    --    账实差是常态;重数一遍不是拒发证书的理由,也不设任何阈值。
    SELECT COALESCE(sum(-m.qty_delta), 0) INTO v_other_doors
      FROM inventory_movements m
     WHERE m.inbound_batch_id = p_inbound_batch_id
       AND m.qty_delta < 0
       AND m.movement_type IN ('writeoff', 'sale');
    IF v_other_doors > 0 THEN
        RETURN jsonb_build_object('complete', false, 'reason', 'DELIVERY_LEFT_BY_ANOTHER_DOOR',
                                  'batch_code', v_ib.code, 'quantity', v_other_doors);
    END IF;

    -- ③ 【被【未冲销】的加工单吃掉了多少】冲销的单不算 —— 冲销说的是那次加工没发生。
    SELECT COALESCE(sum(pi.quantity_consumed), 0),
           max(r.process_date),
           count(*), count(r.process_date)
      INTO v_consumed, v_completed, v_runs_total, v_runs_dated
      FROM processing_inputs pi
      JOIN processing_runs r ON r.id = pi.run_id
     WHERE pi.inbound_batch_id = p_inbound_batch_id
       AND r.deleted_at IS NULL;

    -- ④ 【一克都没加工过的,不可能是"加工完了"】没有这一句,一张被盘点调整
    --    清零的批次会读成"完成",而它根本没进过产线。
    IF v_consumed <= 0 THEN
        RETURN jsonb_build_object('complete', false, 'reason', 'NOTHING_PROCESSED',
                                  'batch_code', v_ib.code);
    END IF;

    -- ⑤ 还有料在场 = 还没加工完。
    IF v_ib.remaining_qty > 0 THEN
        RETURN jsonb_build_object('complete', false, 'reason', 'DELIVERY_NOT_FULLY_PROCESSED',
                                  'batch_code', v_ib.code,
                                  'remaining', v_ib.remaining_qty, 'unit', v_ib.unit);
    END IF;

    -- ⑥ 【完成日期算不出来就拒绝,绝不拿今天顶上】process_date 可空(早期数据),
    --    而这个日期要印在一张法律文件上。与 FIN-10「永不默认入账日」同一条。
    IF v_completed IS NULL THEN
        RETURN jsonb_build_object('complete', false, 'reason', 'COMPLETION_DATE_UNKNOWN',
                                  'batch_code', v_ib.code, 'runs', v_runs_total);
    END IF;

    RETURN jsonb_build_object(
        'complete', true,
        'batch_code', v_ib.code,
        'completed_on', v_completed,
        'consumed', v_consumed,
        'runs_total', v_runs_total,
        'runs_dated', v_runs_dated);
END;
$function$;
