-- db/migrations/2026-08-12-stk1-stock-status.sql
-- STK-1:库存的状态维度 —— 可用 / 暂扣,从流水派生,物理总量按构造不动
--
-- Phase 2 的台账只有数量,没有状态:"这 100 kg 里有 40 kg 被扣住了"这件事
-- 今天在系统里说不出来。这一刀把状态加到【流水】上,而不是加到批次上 ——
-- 批次上的数量本来就是台账的缓存,状态同理:它是流水的聚合,不是另一个要维护的字段。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【为什么叫 stock_status,而不是复用 status】
-- `inbound_batches.status` 与 `output_batches.status` 已经各自占着 `status` 这个词
-- (两列都是 text DEFAULT 'draft'、没有 CHECK、全库【没有任何写入者】、线上 16/17 行
-- 一律 'draft')。它们与库存状态毫无关系,但名字已经被占了 —— 在同一批表上让
-- 同一个词表示两件事,是下一个人必然读错的那种设计。**本刀一个字都不碰它们**;
-- 它们该不该退役,记在 docs/known-issues.md,单独一刀处理。
--
-- 【为什么状态挂在流水上,而不是挂在批次上】
-- 挂在批次上就得回答"这批 100 kg 是什么状态" —— 而真实答案是"60 可用、40 暂扣",
-- 一个字段答不了。挂在流水上,状态是每一次移动【进入哪个桶】的属性,
-- 任意时刻的分布由聚合得出,不需要任何人去维护一致性。
--
-- 【第三种状态要加在哪里 —— 以及两个【已经想过、明确不放这里】的】
-- 加第三种状态就是往下面的 CHECK 里加一个值,并想清楚它由谁写。但有两个
-- 看起来该在这里、其实不该的:
--
--   * **awaiting_assay(待化验)不是库存状态,它是【派生】的。** 今天它由
--     `db/views/operations_now.sql` 的 awaiting_assay 支给出,判据是
--     `batch_assay_status.assay_count = 0` —— 也就是"这批货有没有化验单"这件事
--     本身就存在 assay_results 里,现算即可。把它变成一个【存下来的】状态,
--     等于给一个已经有唯一真相的事实开第二个副本,而两份副本迟早会不一致 ——
--     那正是 `?? 0` / COALESCE 那一类病的反向版本:不是把缺失伪装成零,
--     而是把【算得出来的】固化成【要维护的】。
--   * **committed(已承诺)没有写入者。** 它要表达的是"这批货已经许给某张销售单",
--     而销售单这个东西今天还不存在(只有事后记录的 sales_records)。
--     没有写入者的状态就是一个永远为空的枚举值,而空枚举值会被下一个人读成
--     "从来没有承诺过的库存",不是"这个系统还不知道承诺"。等销售单落地那一刀再加。
--
-- 【本刀不做拦截】storage_location_allowed_classes 仍然只是记录:没有任何东西
-- 因为"这个库位不许放这类物料"而拒绝一次移动。落闸归出入库单据那一刀(LOC-1 有账)。
-- ═══════════════════════════════════════════════════════════════════════════
--
-- 镜像:db/tables/inventory_movements.sql、
--       db/functions/{check_no_negative_bucket,derived_stock_qty,hold_stock,release_stock}.sql、
--       db/views/stock_by_status.sql;
-- 行为断言:fixture 56。

BEGIN;

-- ═══ 0 · 两个新列 ═══════════════════════════════════════════════════════════
-- stock_status:这一行【进入/离开的是哪个桶】。
-- 【DEFAULT 'available' 是有意的,而且是语义正确的】:既有的五个写入者
-- (收货、加工消耗/产出、销售、盘点调整、冲销)动的都是可用库存 —— 一笔销售
-- 本来就不该动得了被扣住的货。给默认值因此不是为了省事,是因为"物理移动作用于
-- 可用库存"就是这些路径一直以来的语义;它们一个字都不用改。
--
-- 既有 68 行一并落到 'available'。**这不是猜**:在这一刀之前,系统里【不存在】
-- "暂扣"这个概念 —— 没有任何一行流水、任何一个字段、任何一处界面表达过它。
-- 所以"这 68 行全都是可用库存"正是系统这段时间一直在断言的事情,把它写下来
-- 只是让一句一直为真的话第一次可以被查询到。
ALTER TABLE public.inventory_movements
    ADD COLUMN stock_status text NOT NULL DEFAULT 'available'
        CHECK (stock_status IN ('available','on_hold')),
    ADD COLUMN status_pair_id uuid;

COMMENT ON COLUMN public.inventory_movements.stock_status IS
    'STK-1:这一行进入/离开的是哪个库存桶(available / on_hold)。状态是流水的属性,不是批次的字段 —— 一个批次同时可以有"60 可用、40 暂扣",一个字段答不了。既有 68 行回填 available:本刀之前系统里根本不存在"暂扣"概念,所以那是它一直在断言的事,不是猜测。【不要与 inbound_batches.status / output_batches.status 混淆】—— 那两列与库存无关(且无人写入),见 docs/known-issues.md。';

COMMENT ON COLUMN public.inventory_movements.status_pair_id IS
    'STK-1:状态变更是【成对】的两行(出一个桶、进另一个桶,同批次同库位、数量相反),这一列把它们绑在一起。只有 status_change_out / status_change_in 带它,其余类型必须为空 —— 由 inventory_movements_status_pair 强制。成对是【结构性】的保证:物理总量 = Σ qty_delta,一出一进相加为零,所以一次状态变更按构造改不动物理总量,不需要任何人记得。';

-- ═══ 1 · 两个新的流水类型:状态变更的两条腿 ═════════════════════════════════
-- 【为什么是 out/in 两个类型,而不是 hold/release 两个类型】
-- 一次暂扣是"出 available、进 on_hold",一次释放是"出 on_hold、进 available" ——
-- 两者的【形状完全相同】,不同的只是每条腿带哪个 stock_status。用 hold/release
-- 命名会把方向编码两遍(既在类型里、又在状态里),而两处编码同一件事就会有
-- 对不上的那一天。
ALTER TABLE public.inventory_movements
    DROP CONSTRAINT inventory_movements_movement_type_check;
ALTER TABLE public.inventory_movements
    ADD CONSTRAINT inventory_movements_movement_type_check CHECK (movement_type IN
        ('receipt','processing_consume','processing_produce','reversal_restore',
         'reversal_void','sale','writeoff','adjustment',
         'status_change_out','status_change_in'));

-- 符号跟着类型走,与既有八种同一条规矩
ALTER TABLE public.inventory_movements DROP CONSTRAINT inventory_movements_sign;
ALTER TABLE public.inventory_movements
    ADD CONSTRAINT inventory_movements_sign CHECK (CASE movement_type
        WHEN 'receipt' THEN qty_delta > 0
        WHEN 'processing_produce' THEN qty_delta > 0
        WHEN 'reversal_restore' THEN qty_delta > 0
        WHEN 'processing_consume' THEN qty_delta < 0
        WHEN 'reversal_void' THEN qty_delta < 0
        WHEN 'sale' THEN qty_delta < 0
        WHEN 'writeoff' THEN qty_delta < 0
        WHEN 'status_change_out' THEN qty_delta < 0
        WHEN 'status_change_in' THEN qty_delta > 0
        ELSE true END);

-- 配对列【当且仅当】是状态变更行才有值 —— 两个方向都管:
-- 状态变更行漏了配对 id,与普通行误带配对 id,都是同一条 CHECK 拒绝。
ALTER TABLE public.inventory_movements
    ADD CONSTRAINT inventory_movements_status_pair CHECK (
        (movement_type IN ('status_change_out','status_change_in'))
        = (status_pair_id IS NOT NULL));

CREATE INDEX idx_inventory_movements_status_pair ON public.inventory_movements (status_pair_id);
CREATE INDEX idx_inventory_movements_bucket
    ON public.inventory_movements (inbound_batch_id, output_batch_id, location_id, stock_status);

-- ═══ 2 · 新的守卫:任何一个桶都不许为负 ═════════════════════════════════════
-- 与 check_ledger_invariant 同一种形状(DEFERRABLE INITIALLY DEFERRED):
-- 成对写入的两行必须一起看,分开看必有一瞬为负。
--
-- 【它挡住的是什么】过量暂扣、过量释放,以及"把已扣住的货卖掉" ——
-- 最后这一条不是这一刀专门写的规则,而是桶不许为负【自动带来的】结果:
-- 销售扣的是 available,扣穿了就撞这条守卫。
CREATE OR REPLACE FUNCTION public.check_no_negative_bucket()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_qty numeric;
    v_code text;
BEGIN
    SELECT COALESCE(sum(m.qty_delta), 0) INTO v_qty
    FROM inventory_movements m
    WHERE m.stock_status = NEW.stock_status
      AND m.inbound_batch_id IS NOT DISTINCT FROM NEW.inbound_batch_id
      AND m.output_batch_id  IS NOT DISTINCT FROM NEW.output_batch_id
      AND m.location_id      IS NOT DISTINCT FROM NEW.location_id;

    IF v_qty < 0 THEN
        SELECT COALESCE(ib.code, ob.code) INTO v_code
        FROM (SELECT 1) x
        LEFT JOIN inbound_batches ib ON ib.id = NEW.inbound_batch_id
        LEFT JOIN output_batches  ob ON ob.id = NEW.output_batch_id;
        RAISE EXCEPTION 'STK_NEGATIVE_BUCKET|%|%|%',
            COALESCE(v_code, '?'), NEW.stock_status, v_qty;
    END IF;
    RETURN NULL;
END;
$function$;

CREATE CONSTRAINT TRIGGER trg_inventory_movements_no_negative_bucket
    AFTER INSERT ON public.inventory_movements
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.check_no_negative_bucket();

-- ═══ 3 · 派生仓位:唯一的取数口 ═════════════════════════════════════════════
-- 【为什么不能读 remaining_qty】remaining_qty 是批次级的缓存,它【没有库位轴】,
-- 更没有状态轴。而暂扣是按 批次 × 库位 × 状态 发生的,所以在这个粒度上,
-- 现算 Σ qty_delta 是唯一可能的来源 —— 不是"更严谨的选择",是唯一的选择。
CREATE OR REPLACE FUNCTION public.derived_stock_qty(
    p_inbound_batch_id uuid, p_output_batch_id uuid,
    p_location_id uuid, p_stock_status text)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(sum(m.qty_delta), 0)
    FROM inventory_movements m
    WHERE m.stock_status = p_stock_status
      AND m.inbound_batch_id IS NOT DISTINCT FROM p_inbound_batch_id
      AND m.output_batch_id  IS NOT DISTINCT FROM p_output_batch_id
      AND m.location_id      IS NOT DISTINCT FROM p_location_id;
$function$;

-- ═══ 4 · 暂扣 / 释放 ═══════════════════════════════════════════════════════
-- 两个函数,同一种形状:检查【派生仓位】,再写【成对】的两行。
-- 拒绝一律具名,数量对着派生仓位比 —— 不是对着 remaining_qty(它没有库位轴)。
CREATE OR REPLACE FUNCTION public.hold_stock(
    p_inbound_batch_id uuid, p_output_batch_id uuid,
    p_location_id uuid, p_qty numeric, p_reason text)
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
    p_inbound_batch_id uuid, p_output_batch_id uuid,
    p_location_id uuid, p_qty numeric, p_note text DEFAULT NULL::text)
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

-- ═══ 5 · 视图:批次 × 库位 × 状态 ═══════════════════════════════════════════
-- 【属主权限】—— 跨模块借了批次与库位的标签(OPS-14 的 remedy (a):借的是
-- 派生事实与显示标签,不是钱),谓词写在体内。
-- 【库位为 NULL 不是缺陷,今天它是全部】线上 68 行流水一行都没有库位,
-- 所以每一个批次都会落在"未指定库位"上。视图照直把 NULL 传出去,
-- 由界面渲染成【未指定库位】—— 不折叠进任何一个真库位,也不隐藏。
CREATE OR REPLACE VIEW public.stock_by_status WITH (security_invoker = off) AS
 SELECT m.inbound_batch_id,
    m.output_batch_id,
    COALESCE(ib.code, ob.code) AS batch_code,
    COALESCE(ib.unit, ob.unit) AS unit,
    m.location_id,
    l.code AS location_code,
    l.name AS location_name,
    m.stock_status,
    sum(m.qty_delta) AS qty
   FROM inventory_movements m
     LEFT JOIN inbound_batches ib ON ib.id = m.inbound_batch_id
     LEFT JOIN output_batches  ob ON ob.id = m.output_batch_id
     LEFT JOIN storage_locations l ON l.id = m.location_id
  WHERE has_permission('module.inventory.view'::text)
  GROUP BY m.inbound_batch_id, m.output_batch_id, COALESCE(ib.code, ob.code),
           COALESCE(ib.unit, ob.unit), m.location_id, l.code, l.name, m.stock_status
 HAVING sum(m.qty_delta) <> 0;

COMMENT ON VIEW public.stock_by_status IS
    'STK-1:按 批次 × 库位 × 状态 的库存分布,全部由流水聚合得出(没有任何一处存下来)。location_id 为 NULL = 未指定库位 —— 线上今天【全部】流水都是这样(LOC-1 之前没有库位这个轴),界面必须把它渲染成一个可读的"未指定库位",既不隐藏也不折叠进真库位。HAVING <> 0 只是不列出已经走空的桶;它不改变任何总量。';

GRANT SELECT ON public.stock_by_status TO authenticated;

COMMIT;
