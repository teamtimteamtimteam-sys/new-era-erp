-- db/migrations/2026-08-13-iod1b-batch-creation-rpcs.sql
-- IOD-1b:建批次收归三个 RPC —— 收货库位因此进得来,而门从此只有一扇
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【为什么必须是 RPC,而不是在 app 里 set_config 一下】
-- IOD-1 把库位读取那一半做完了:收货触发器读 evoltrya.location_ctx。但没有
-- 任何东西设得了它 —— app 那三处是 PostgREST 插入,每一次调用都是【独立的
-- HTTP 请求、独立的会话与事务】,`is_local => true` 的 GUC 在上一个请求结束
-- 时就没了;而 set_config 本身也不可调(住在 pg_catalog,PostgREST 只暴露
-- public)。实测:POST /rest/v1/rpc/set_config → 404 PGRST202。
--
-- 把插入搬进函数,这两个问题一起消失:set_config 与 INSERT 在同一个函数、
-- 同一个事务里 —— 这正是 commit_processing_run 早就在用、且一直有效的那套。
--
-- 【刻意的副作用:这三个 RPC 从此是建批次的【唯一】入口】
-- 下面同时撤掉两张批次表面向客户端的 INSERT 策略。这不是顺手收紧,是这一刀
-- 想要的东西:IOD-2 要在"货落进哪个库位"上设闸,而**一个留着侧门的卡口不是
-- 卡口**。今天先把门收成一扇,IOD-2 只需在这一扇门上加判断,不必再去追
-- 有没有第二条路径绕过它。
--
-- commit_processing_run 不受影响 —— 它是 SECURITY DEFINER,以属主身份执行,
-- RLS 的 authenticated 策略对它本就不适用。【这一条是验证过的,不是假定的】:
-- fixture 58 的 D 臂在撤策略之后仍然跑通一整张加工单。
-- ═══════════════════════════════════════════════════════════════════════════
--
-- 镜像:db/functions/{create_inbound_batch,receive_inbound_batch_against_po,
--       create_output_batch,resolve_receipt_location}.sql、
--       db/tables/{inbound_batches,output_batches}.sql;
-- 行为断言:fixture 58,以及 fixture 57 B 臂改走 RPC(同一扇门)。

BEGIN;

-- ═══ 0 · 库位校验:三个 RPC 共用一处 ════════════════════════════════════════
-- 【为什么单独一个函数】三处各写一遍就是三份会漂开的判断。它只做一件事:
-- 把"用户选的库位"翻译成"可以写进流水的库位",不合格的当场点名。
--
-- 【拒绝在函数里,不在表单里】表单的下拉只列在用状态的库位,那是【便利】;
-- 而这三个 RPC 是卡口,便利挡不住直接调 RPC 的人。所以判断落在这里。
CREATE OR REPLACE FUNCTION public.resolve_receipt_location(p_location_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    v_active boolean;
BEGIN
    -- 不选就是不选 —— "未指定库位"是一等状态(LOC-1/STK-1),不是缺失。
    IF p_location_id IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT code, is_active INTO v_code, v_active
    FROM storage_locations WHERE id = p_location_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'IOD_RECEIPT_LOCATION_UNKNOWN';
    END IF;
    -- 停用的库位不该再收货(LOC-1 的停用语义:新单据不再提供它)
    IF NOT v_active THEN
        RAISE EXCEPTION 'IOD_RECEIPT_LOCATION_INACTIVE|%', v_code;
    END IF;

    RETURN p_location_id;
END;
$function$;

-- ═══ 1 · 建进料批(手工)═══════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.create_inbound_batch(
    p_material_id uuid, p_supplier_id uuid, p_quantity numeric,
    p_unit text DEFAULT 'kg'::text,
    p_arrival_date date DEFAULT NULL::date,
    p_stage text DEFAULT '待加工'::text,
    p_unit_price numeric DEFAULT NULL::numeric,
    p_notes text DEFAULT NULL::text,
    p_purchase_order_id uuid DEFAULT NULL::uuid,
    p_purchase_order_line_id uuid DEFAULT NULL::uuid,
    p_location_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
BEGIN
    PERFORM require_permission('module.inbound.edit');

    -- 【顺序要紧】库位先校验再落库:拒绝必须发生在写入之前,否则一次被拒的
    -- 收货会留下半个批次(单事务会回滚,但错误信息的语义也该是"什么都没发生")。
    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    INSERT INTO inbound_batches (
        material_id, supplier_id, quantity, unit, remaining_qty, arrival_date,
        stage, unit_price, notes, purchase_order_id, purchase_order_line_id,
        created_by, updated_by)
    VALUES (
        p_material_id, p_supplier_id, p_quantity, COALESCE(p_unit,'kg'), p_quantity, p_arrival_date,
        COALESCE(p_stage,'待加工'), p_unit_price, p_notes, p_purchase_order_id, p_purchase_order_line_id,
        v_user, v_user)
    RETURNING id INTO v_id;

    -- 用毕即清 —— 同 commit_processing_run 的 movement_ctx:免得同事务内后续的
    -- 插入把这个库位当成自己的(那正是 ctx 这种机制唯一的锋利处)。
    PERFORM set_config('evoltrya.location_ctx', '', true);
    RETURN v_id;
END;
$function$;

-- ═══ 2 · 按采购单收货 ═══════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.receive_inbound_batch_against_po(
    p_material_id uuid, p_supplier_id uuid, p_quantity numeric,
    p_arrival_date date DEFAULT NULL::date,
    p_notes text DEFAULT NULL::text,
    p_purchase_order_id uuid DEFAULT NULL::uuid,
    p_purchase_order_line_id uuid DEFAULT NULL::uuid,
    p_location_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
BEGIN
    PERFORM require_permission('module.inbound.edit');

    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- 单位固定 kg、stage 用默认值 —— 与收货表单今天的行为逐字一致。
    -- 【采购单侧的那一串拒绝(PO_NOT_RECEIVABLE / PO_LINE_MISMATCH /
    --  PO_NOT_APPROVED / SUPPLIER_QUALIFICATION_EXPIRED)仍由表上的触发器抛出】,
    -- 这个函数一个字都不重复它们 —— 重复一遍就是第二份会漂开的判断。
    INSERT INTO inbound_batches (
        material_id, supplier_id, quantity, remaining_qty, unit, arrival_date,
        notes, purchase_order_id, purchase_order_line_id, created_by, updated_by)
    VALUES (
        p_material_id, p_supplier_id, p_quantity, p_quantity, 'kg', p_arrival_date,
        p_notes, p_purchase_order_id, p_purchase_order_line_id, v_user, v_user)
    RETURNING id INTO v_id;

    PERFORM set_config('evoltrya.location_ctx', '', true);
    RETURN v_id;
END;
$function$;

-- ═══ 3 · 建产出批(手工)═══════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.create_output_batch(
    p_material_id uuid, p_quantity numeric,
    p_unit text DEFAULT 'kg'::text,
    p_output_date date DEFAULT NULL::date,
    p_state text DEFAULT '库存中'::text,
    p_customer_id uuid DEFAULT NULL::uuid,
    p_purity text DEFAULT NULL::text,
    p_notes text DEFAULT NULL::text,
    p_location_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
BEGIN
    PERFORM require_permission('module.output.edit');

    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    INSERT INTO output_batches (
        material_id, customer_id, quantity, unit, remaining_qty, output_date,
        state, purity, notes, created_by, updated_by)
    VALUES (
        p_material_id, p_customer_id, p_quantity, COALESCE(p_unit,'kg'), p_quantity, p_output_date,
        COALESCE(p_state,'库存中'), p_purity, p_notes, v_user, v_user)
    RETURNING id INTO v_id;

    PERFORM set_config('evoltrya.location_ctx', '', true);
    RETURN v_id;
END;
$function$;

-- ═══ 4 · 关上侧门 ══════════════════════════════════════════════════════════
-- 【一个留着侧门的卡口不是卡口】上面三个 RPC 从此是建批次的唯一入口。
-- 客户端的 INSERT 策略撤掉:直接 POST /rest/v1/inbound_batches 会被 RLS 拒。
--
-- 【为什么现在做,而不是等 IOD-2】IOD-2 要在"货落进哪个库位"上设闸。如果那时
-- 还有第二条写入路径,IOD-2 就得在两处各写一遍判断 —— 而两处判断迟早漂开,
-- 那正是这个仓库反复付过账的形状。先把门收成一扇,IOD-2 只需在门上加判断。
--
-- 【commit_processing_run 不受影响,而这是验证过的】它是 SECURITY DEFINER,
-- 以属主身份执行,RLS 面向 authenticated 的策略对它不适用。fixture 58 的 D 臂
-- 在撤策略之后仍然跑通一整张加工单(建产出批 + 投料 + 产出流水)。
DROP POLICY "inbound_batches insert by permission" ON public.inbound_batches;
DROP POLICY "output_batches insert by permission" ON public.output_batches;

COMMIT;
