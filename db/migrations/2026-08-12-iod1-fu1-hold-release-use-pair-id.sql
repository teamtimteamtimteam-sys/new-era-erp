-- db/migrations/2026-08-12-iod1-fu1-hold-release-use-pair-id.sql
-- IOD-1 续:hold_stock / release_stock 改用 pair_id
--
-- 【这是重命名列必然要付的账,记下来因为它不会自己冒出来】
-- ALTER TABLE ... RENAME COLUMN 会改表、改约束、改索引,**但不会改函数体** ——
-- plpgsql 的 body 就是一段文本,里面写死的 status_pair_id 在重命名之后
-- 变成了一个不存在的列。而它【不在迁移时报错】,要等到有人真的调用
-- hold_stock 才炸(fixture 57 的 E 臂当场撞上,这一条就是这么发现的)。
--
-- 所以:重命名一个被函数体引用的列,必须在同一次改动里把每一个引用它的
-- 函数一并 CREATE OR REPLACE。查法是 pg_proc.prosrc LIKE '%旧列名%',
-- 不是搜仓库 —— 线上跑的是线上那份 body。
--
-- 镜像:db/functions/{hold_stock,release_stock}.sql。

BEGIN;

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
         qty_delta, stock_status, pair_id, business_date, notes, created_by)
    VALUES
        (p_inbound_batch_id, p_output_batch_id, p_location_id, 'status_change_out',
         -p_qty, 'available', v_pair, v_today, btrim(p_reason), v_user),
        (p_inbound_batch_id, p_output_batch_id, p_location_id, 'status_change_in',
          p_qty, 'on_hold',   v_pair, v_today, btrim(p_reason), v_user);

    RETURN jsonb_build_object('pair_id', v_pair, 'qty', p_qty,
                              'available_after', v_avail - p_qty);
END;
$function$;

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
$function$;

COMMIT;
