-- db/migrations/2026-08-13-iod2-fu1-named-date-errors.sql
-- IOD-2 续:三个建批次 RPC 的日期【按名拒绝】—— 而不是把 FIN-32 的约束原文漏出去
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这一条是手走查出来的,而它查出来的不是"app 的守卫坏了"】
-- 手走 /output/new 留空产出日,屏幕上出现的是:
--     Save failed: new row for relation inventory_movements violates
--     check constraint inventory_movements_business_date_required
-- 也就是【把一句数据库约束原文端到了操作员面前】—— 与 IOD-1b 那次
-- "IOD_RECEIPT_LOCATION_INACTIVE|SG-A1" 是同一种缺陷,只是这一次连码都不是,
-- 是一句英文的表约束名。
--
-- 【复现之后,app 那一层的守卫是好的】直接调 action 模块本身:
--     createOutput({}, fd) → {"fieldErrors":{"output_date":"Output date is required …"}}
-- 它拦住了。所以这一支迁移【不是在修那道守卫】,它修的是另一件事:
--
-- 【守卫成对的那一对里,只有一只手在】AGENTS.md 的日期规矩要求两道:界面禁用
-- 提交,服务端【独立】拒空。今天服务端那一道住在 app 的 action 里 —— 而
-- **RPC 自己没有任何一道**。于是任何不经过那个 action 的调用者(curl、别的
-- 页面、将来的导入脚本、以及一个装着旧 action id 的浏览器)都会一路走到
-- FIN-32 的 CHECK 上,拿到上面那句原文。实测三个入口全部如此:
--     create_inbound_batch / receive_inbound_batch_against_po / create_output_batch
--     不传日期 → HTTP 400 · 23514 · "violates check constraint ..."
--
-- 【为什么这不是行为改变】这三种调用【今天本来就失败】,FIN-32 的
-- inventory_movements_business_date_required 已经把它们挡住了。这一支只是把
-- 一句"约束原文"换成一个【可以翻成人话的名字】。允许通过的集合一行不变。
--
-- 【为什么不给默认值】—— 补一个 CURRENT_DATE 会让"留空"比"填对"更容易通过,
-- 那条路专门奖励留空(AGENTS.md 的日期规矩,FIN-10 已经把 11 个函数的
-- CURRENT_DATE 默认值拆掉过一轮)。命名与那一轮一致:*_DATE_REQUIRED。
--
-- 镜像:db/functions/{create_inbound_batch,receive_inbound_batch_against_po,
--       create_output_batch}.sql。
-- 行为断言:fixture 25(业务日那一份)新增 F 臂 —— 三个入口各断言一次按名拒绝。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 建进料批次 ═════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.create_inbound_batch(p_material_id uuid, p_supplier_id uuid, p_quantity numeric, p_unit text DEFAULT 'kg'::text, p_arrival_date date DEFAULT NULL::date, p_stage text DEFAULT '待加工'::text, p_unit_price numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_warn text[];
BEGIN
    PERFORM require_permission('module.inbound.edit');

    -- IOD-2-fu1:到货日【按名】必填。不写这一句,漏出去的是 FIN-32 的约束原文。
    -- 【不给默认值】:CURRENT_DATE 会让留空比填对更容易通过。
    IF p_arrival_date IS NULL THEN
        RAISE EXCEPTION 'ARRIVAL_DATE_REQUIRED';
    END IF;

    -- 【顺序要紧】库位先校验再落库:拒绝必须发生在写入之前,否则一次被拒的
    -- 收货会留下半个批次(单事务会回滚,但错误信息的语义也该是"什么都没发生")。
    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- IOD-2:落闸。同样在写入之前 —— 它可能抛 IOD_CLASS_EXCLUDED。
    v_warn := check_location_class(p_location_id, p_material_id);

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
    -- IOD-2:返回值从 uuid 变成 jsonb —— 告警要有地方回去。batch_id 仍在里面。
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn));
END;
$function$;

-- ═══ 2 · 凭采购单收货 ═══════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.receive_inbound_batch_against_po(p_material_id uuid, p_supplier_id uuid, p_quantity numeric, p_arrival_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_warn text[];
BEGIN
    PERFORM require_permission('module.inbound.edit');

    -- IOD-2-fu1:同上 —— 现场收货这条路一样进得到 FIN-32 的约束。
    IF p_arrival_date IS NULL THEN
        RAISE EXCEPTION 'ARRIVAL_DATE_REQUIRED';
    END IF;

    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- IOD-2:落闸,写入之前。
    v_warn := check_location_class(p_location_id, p_material_id);

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
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn));
END;
$function$;

-- ═══ 3 · 建产出批次 ═════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.create_output_batch(p_material_id uuid, p_quantity numeric, p_unit text DEFAULT 'kg'::text, p_output_date date DEFAULT NULL::date, p_state text DEFAULT '库存中'::text, p_customer_id uuid DEFAULT NULL::uuid, p_purity text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_location_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_warn text[];
BEGIN
    PERFORM require_permission('module.output.edit');

    -- IOD-2-fu1:产出日【按名】必填 —— 手走就是在这一条上看见了约束原文。
    IF p_output_date IS NULL THEN
        RAISE EXCEPTION 'OUTPUT_DATE_REQUIRED';
    END IF;

    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- IOD-2:落闸,写入之前。
    v_warn := check_location_class(p_location_id, p_material_id);

    INSERT INTO output_batches (
        material_id, customer_id, quantity, unit, remaining_qty, output_date,
        state, purity, notes, created_by, updated_by)
    VALUES (
        p_material_id, p_customer_id, p_quantity, COALESCE(p_unit,'kg'), p_quantity, p_output_date,
        COALESCE(p_state,'库存中'), p_purity, p_notes, v_user, v_user)
    RETURNING id INTO v_id;

    PERFORM set_config('evoltrya.location_ctx', '', true);
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn));
END;
$function$;

COMMIT;
