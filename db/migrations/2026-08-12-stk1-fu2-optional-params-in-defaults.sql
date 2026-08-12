-- db/migrations/2026-08-12-stk1-fu2-optional-params-in-defaults.sql
-- STK-1 续:hold_stock / release_stock 的可选参数挪进默认值区
--
-- 【与 PROC-1b 对 record_assay_result 做的是同一件事,理由也一样】
-- 两个批次父是【二选一】(XOR 由函数把门),库位可以为空(今天线上【全部】
-- 流水都没有库位)。但它们原来都写在无默认值的位置上,于是:
--   * 调用方必须显式递 NULL 进去;
--   * 生成的 TS 类型把它们标成【必填 string】,而不是可选 —— 于是
--     `p_inbound_batch_id: x ?? undefined` 直接编译不过(本次 build 就是这么红的)。
-- 类型没说谎,是签名说错了话:一个语义上可空的参数,签名就该说它可空。
--
-- PostgreSQL 要求带默认值的参数排在后面,所以必填的 p_qty / p_reason 前移。
-- 【参数顺序不是接口】—— 全部调用方(动作、fixture)一律按名传参。
--
-- 镜像:db/functions/{hold_stock,release_stock}.sql;行为断言:fixture 56。

BEGIN;

DROP FUNCTION public.hold_stock(uuid, uuid, uuid, numeric, text);
DROP FUNCTION public.release_stock(uuid, uuid, uuid, numeric, text);

CREATE OR REPLACE FUNCTION public.hold_stock(
    p_qty numeric, p_reason text,
    p_inbound_batch_id uuid DEFAULT NULL::uuid,
    p_output_batch_id uuid DEFAULT NULL::uuid,
    p_location_id uuid DEFAULT NULL::uuid)
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
$function$;

CREATE OR REPLACE FUNCTION public.release_stock(
    p_qty numeric,
    p_inbound_batch_id uuid DEFAULT NULL::uuid,
    p_output_batch_id uuid DEFAULT NULL::uuid,
    p_location_id uuid DEFAULT NULL::uuid,
    p_note text DEFAULT NULL::text)
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
         qty_delta, stock_status, status_pair_id, business_date, notes, created_by)
    VALUES
        (p_inbound_batch_id, p_output_batch_id, p_location_id, 'status_change_out',
         -p_qty, 'on_hold',   v_pair, v_today, NULLIF(btrim(COALESCE(p_note, '')), ''), v_user),
        (p_inbound_batch_id, p_output_batch_id, p_location_id, 'status_change_in',
          p_qty, 'available', v_pair, v_today, NULLIF(btrim(COALESCE(p_note, '')), ''), v_user);

    RETURN jsonb_build_object('status_pair_id', v_pair, 'qty', p_qty,
                              'held_after', v_held - p_qty);
END;
$function$;

COMMIT;
