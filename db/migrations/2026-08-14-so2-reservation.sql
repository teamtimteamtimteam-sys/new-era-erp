-- db/migrations/2026-08-14-so2-reservation.sql
-- SO-2:预留 —— committed 成为第三个库存桶,而【它终于有了写入者】
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这一刀补的是哪一句】inventory_movements.stock_status 的注释里,committed
-- 被明确地【拒绝过一次】,理由是"没有写入者的枚举值永远为空,而空枚举值会被
-- 下一个人读成'从来没有承诺过的库存',不是'系统还不知道承诺'"。SO-1 落地了
-- 销售订单,那条理由的前提就消失了。所以本刀做两件事,而且必须【同时】做:
--   ① 加上 committed;
--   ② 把那段【说它不该存在】的注释退役掉,换成一段说【谁写它】的注释。
-- 留着旧注释比不加这个值更坏:它会让下一个人相信这里仍然没有写入者。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【预留是什么,不是什么】
-- 预留 = 把一个桶里的货从 available 挪进 committed。物理总量按构造不动
-- (成对流水,一出一进),remaining_qty 一个字不变,批次的 state 也不变 ——
-- 【承诺不是销售】,一批全部被预留的货仍然是「库存中」。想看见"许出去了多少",
-- 看的是派生的三态分布,不是那一列。
--
-- 【三个桶之间允许走哪几条边 —— 逐条写出来,不是"除了 X 都行"】
--     available → on_hold      hold_stock
--     on_hold   → available    release_stock
--     available → committed    reserve_stock          ← 本刀
--     committed → available    release_reservation    ← 本刀
--     on_hold  ↔  committed    【不存在】
-- 最后一条是一个决定,不是遗漏:暂扣说的是"这批货现在不能动"(品控、争议、
-- 等复检),预留说的是"这批货许给了某张订单"。从一个直接跳到另一个,等于让
-- 系统替人回答"那个暂扣的理由还成不成立"—— 而它不知道。要走这条路,先释放,
-- 再预留;两步各自留下自己的理由。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本刀【不】做的三件事,写在会有人去加的那个位置】
--   * 发货消耗:cut 4 读预留(drain_stock 的 p_statuses 已经支持任意集合 ——
--     不需要改签名)。【但有一件事那一刀必须先决定】:drain_stock 的排空顺序
--     以 m.stock_status 结尾,那是【字母序】,不是策略;字母序下
--     available < committed < on_hold,于是它会先吃没被预留的货,把承诺挂在
--     那里。发货要的是相反的顺序。这句话写在这里,是因为 drain_stock 的函数头
--     已经说过"改这条顺序是改一个地方",而那个地方现在有了第二个理由。
--   * 报价 / 改单:归 SO-1b。
--   * closed 不释放预留:一张走完的订单,它的货是【发出去了】,不是【放回去了】。
--     释放只有两个来源:人手动释放(带理由),或作废自动释放。发货那一刀会把
--     "已发货"这条路补上。closed 状态下仍有活预留,是一个真实且可见的状态,
--     不是一个需要在这里悄悄清掉的脏数据。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【跨模块:一次销售动作写库存台账,而这是【想过之后】的答案】
-- reserve_stock 要 module.sales.edit,不要 module.inventory.edit。理由与
-- zzz_function_grants.sql 给 drain_stock 写的那一条同形:预留【就是一次销售
-- 行为】,做它的人是销售;给它挑一个"两个模块都满足"的码,只能挑一个比两者
-- 都松的,那不是把关,是把关的样子。
-- 【而台账的不变量并不依赖调用者是谁】:成对写入让物理总量按构造不动,
-- check_no_negative_bucket 是一条 DEFERRABLE 约束触发器 —— 它对 postgres、
-- 对 authenticated、对任何身份一视同仁。所以"销售能写库存流水"这件事,
-- 换不来任何一条账面上的松动。
--
-- 【一个真的坑,记在这里因为它写的时候就撞上了】reserve_stock 不能调
-- derived_stock_qty 去问"这个桶还有多少" —— 那个函数体里有
-- require_permission('module.inventory.view'),而 has_permission 解析的是
-- 【调用者】的 JWT,不是属主。DEFINER 换得了行的可见性,换不了函数体内那句
-- 对调用者的判断(AGENTS.md「属主权限视图替得了表,替不了函数的 EXECUTE」的
-- 近亲)。于是它像 record_output_sale 一样【就地求和】。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【顺带修掉的两处,它们不是新问题,是 committed 让它们变得够得着】
--   * stock_class_violations_all 此前只看 available。一次预留会让一批放在
--     【明确排除这一类】的库位上的货【从违规报表里消失】—— 而它还在那儿。
--     判据改成【物理存在】:所有状态一起算。违规讲的是货待在哪里,
--     与它许给了谁、扣没扣住毫无关系。
--   * record_output_sale 的拒绝此前只说得出 available 与 held 两个数。
--     多一个桶就要多说一个数,否则屏幕上会出现"可用 0、暂扣 0、可是卖不了"。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【已知问题:两处 pre-existing 的盘点缺陷,本刀让它们够得着,记进 known-issues】
--   post_stocktake 把盘点差异一律写进 available 桶(不给 stock_status,吃列
--   默认值),并把 remaining_qty 直接设成盘点数,而【不重算 state】。有预留之后
--   这两件事都变得容易撞上。它们【不在本刀里修】—— 盘点该怎么面对分桶的库存
--   是一个业务判断(点的是物理总量还是可用?差异该落在哪个桶?),不该在预留
--   这一刀里顺手替人决定。写进 docs/known-issues.md,带修法草案。
--
-- 镜像:db/tables/{inventory_movements,sales_order_reservations,sales_order_history}.sql、
--       db/functions/{reserve_stock,release_reservation,
--       guard_sales_order_reservation_append_only,set_sales_order_status,
--       emit_batch_writeoff_movement(在 inventory_ledger_triggers.sql 内),
--       create_stock_transfer,record_output_sale}.sql、
--       db/views/stock_class_violations_all.sql。
-- 行为断言:fixture 64(新),fixture 62 的 G 臂注入体同步。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 第三个桶 ═══════════════════════════════════════════════════════════
ALTER TABLE public.inventory_movements
    DROP CONSTRAINT inventory_movements_stock_status_check;
ALTER TABLE public.inventory_movements
    ADD CONSTRAINT inventory_movements_stock_status_check
    CHECK (stock_status IN ('available','on_hold','committed'));

COMMENT ON COLUMN public.inventory_movements.stock_status IS
    'STK-1:这一行进入/离开的是哪个库存桶(available / on_hold / committed)。状态是流水的属性,不是批次的字段 —— 一个批次同时可以有"60 可用、40 暂扣",一个字段答不了。【三个桶各自的写入者】:on_hold 由 hold_stock / release_stock 成对写;committed 由 reserve_stock / release_reservation 成对写(SO-2,销售订单预留)。【on_hold 与 committed 之间没有直达的边】—— 那是一个决定:暂扣说"现在不能动",预留说"许给了某张单",系统无从判断跳过去之后那个暂扣的理由还成不成立;要走这条路,先释放再预留,两步各留各的理由。【不要与 inbound_batches.status / output_batches.status 混淆】—— 那两列与库存无关(且无人写入),见 docs/known-issues.md。';

-- ═══ 2 · 留痕多两种事件 ═════════════════════════════════════════════════════
ALTER TABLE public.sales_order_history
    DROP CONSTRAINT sales_order_history_change_type_check;
ALTER TABLE public.sales_order_history
    ADD CONSTRAINT sales_order_history_change_type_check
    CHECK (change_type IN
        ('created','confirmed','closed','cancelled',
         'line_added','line_changed','line_removed','issued',
         -- SO-2:预留与释放【留在订单的历史里】,而不是只留在库存流水里。
         -- 看订单的人问的是"这张单许出去了什么、什么时候放回去的",
         -- 那个问题的答案不该要求他先去翻库存台账。
         'reserved','released'));

-- ═══ 3 · 预留行:一条【事实】,不是一个可变的数量 ═════════════════════════════
CREATE TABLE public.sales_order_reservations (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- 【挂在行上,不挂在单上】客户买的是这一行的物料;"这一行由哪几批货满足"
    -- 正是 sales_order_lines 的注释里说要等的那个多对多。它就在这里出生。
    sales_order_line_id uuid NOT NULL REFERENCES public.sales_order_lines (id),
    -- 【只能是产出批次】—— 不是保守,是结构性的:inventory_movements_side 把
    -- movement_type='sale' 钉在产出侧,record_output_sale 也只收产出批次。
    -- 允许预留一个进料批次,等于造出一批【任何销售都消耗不掉】的承诺库存。
    output_batch_id     uuid NOT NULL REFERENCES public.output_batches (id),
    -- 【桶的第三根轴:库位】。预留发生在 批次 × 库位 × 状态 这个粒度上,
    -- 与暂扣完全一样。NULL = 未指定库位,是一等状态而不是缺失(LOC-1/STK-1)。
    location_id         uuid REFERENCES public.storage_locations (id),
    qty                 numeric NOT NULL CHECK (qty > 0),
    -- 【承载这次预留的那一对流水】。有了它,"账上这 40kg committed 是谁造成的"
    -- 有一个可以走回去的指针,而不是靠时间戳猜。
    pair_id             uuid NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid DEFAULT auth.uid(),
    -- ── 释放:一次性写入的三列 ────────────────────────────────────────────
    -- 【为什么释放是"写这三列",而不是"把 qty 改小"】一行预留是一个【发生过的
    -- 事实】:某年某月某日,这一行订单许了这批货 40kg。把 qty 从 40 改成 25,
    -- 是在把历史改成"当初只许了 25",而那不是发生过的事。所以部分释放由
    -- release_reservation 做成【整行释放 + 就地重新预留剩余】—— 两行事实,
    -- 各自为真,合起来正好是发生过的经过。
    released_at         timestamptz,
    released_by         uuid,
    release_reason      text,
    release_pair_id     uuid,
    CONSTRAINT sales_order_reservations_release_complete CHECK (
        (released_at IS NULL     AND release_reason IS NULL     AND release_pair_id IS NULL)
     OR (released_at IS NOT NULL AND release_reason IS NOT NULL AND release_pair_id IS NOT NULL))
);

COMMENT ON TABLE public.sales_order_reservations IS
    'SO-2:销售订单的库存预留 —— 订单【行】与产出【批次】的多对多在这里出生(sales_order_lines 的注释里说要等的正是它)。一行 = 一次预留这个【事实】:某张单的某一行,在某个 批次 × 库位 桶里,许出去了多少。活预留 = released_at IS NULL。【只指向产出批次】:movement_type=''sale'' 被 inventory_movements_side 钉在产出侧,预留一个进料批次会造出永远消耗不掉的承诺库存。【释放不改 qty,而是写三列并整行作废】—— 把 40 改成 25 是在把历史改成"当初只许了 25";部分释放由 release_reservation 做成整行释放 + 就地重新预留剩余,于是每一行都仍然是一个真的事实。唯一写入口:reserve_stock / release_reservation(都要 module.sales.edit)。';

COMMENT ON COLUMN public.sales_order_reservations.location_id IS
    'SO-2:这次预留占用的是哪个库位的桶。NULL = 未指定库位(一等状态,不是缺失 —— LOC-1/STK-1)。【它是本表唯一一列可以在事后被改写的】:committed 的货整桶转移到别的库位时,create_stock_transfer 在 evoltrya.reservation_move_ctx 上下文里把它改过去。改的是"这批货现在放在哪",不是"当初许了什么" —— 后者(行、批次、数量)一个字都不能动。';

CREATE INDEX idx_so_reservations_line   ON public.sales_order_reservations (sales_order_line_id) WHERE released_at IS NULL;
CREATE INDEX idx_so_reservations_bucket ON public.sales_order_reservations (output_batch_id, location_id) WHERE released_at IS NULL;

-- ── 只增不改的守卫(自己报名,不靠外键顺带挡 —— FIN-31)────────────────────
CREATE OR REPLACE FUNCTION public.guard_sales_order_reservation_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_move text := current_setting('evoltrya.reservation_move_ctx', true);
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'SO_RESERVATION_IMMUTABLE|delete';
    END IF;

    -- 【放行的只有两种改动,逐条写出来】
    -- ① 一次性的释放:三列一起从空变成非空,其余一个字不动。
    IF OLD.released_at IS NULL AND NEW.released_at IS NOT NULL
       AND NEW.id                  IS NOT DISTINCT FROM OLD.id
       AND NEW.sales_order_line_id IS NOT DISTINCT FROM OLD.sales_order_line_id
       AND NEW.output_batch_id     IS NOT DISTINCT FROM OLD.output_batch_id
       AND NEW.location_id         IS NOT DISTINCT FROM OLD.location_id
       AND NEW.qty                 IS NOT DISTINCT FROM OLD.qty
       AND NEW.pair_id             IS NOT DISTINCT FROM OLD.pair_id
       AND NEW.created_at          IS NOT DISTINCT FROM OLD.created_at
       AND NEW.created_by          IS NOT DISTINCT FROM OLD.created_by
    THEN
        RETURN NEW;
    END IF;

    -- ② 整桶转移带着它换库位 —— 只在转移函数设下的上下文里,且【只有】库位变。
    IF v_move IS NOT NULL AND btrim(v_move) <> ''
       AND OLD.released_at IS NULL AND NEW.released_at IS NULL
       AND NEW.id                  IS NOT DISTINCT FROM OLD.id
       AND NEW.sales_order_line_id IS NOT DISTINCT FROM OLD.sales_order_line_id
       AND NEW.output_batch_id     IS NOT DISTINCT FROM OLD.output_batch_id
       AND NEW.qty                 IS NOT DISTINCT FROM OLD.qty
       AND NEW.pair_id             IS NOT DISTINCT FROM OLD.pair_id
       AND NEW.created_at          IS NOT DISTINCT FROM OLD.created_at
       AND NEW.created_by          IS NOT DISTINCT FROM OLD.created_by
    THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'SO_RESERVATION_IMMUTABLE|update';
END;
$function$;

CREATE TRIGGER trg_so_reservations_append_only
    BEFORE UPDATE OR DELETE ON public.sales_order_reservations
    FOR EACH ROW EXECUTE FUNCTION public.guard_sales_order_reservation_append_only();

ALTER TABLE public.sales_order_reservations ENABLE ROW LEVEL SECURITY;

-- 【没有 INSERT / UPDATE 策略,这是前提而不是遗漏】唯一写入口是下面两个
-- DEFINER 函数,它们各自 require_permission('module.sales.edit')。留一条
-- 客户端可以直接 POST 的路,等于让任何持 sales.edit 的人写出一行【与库存流水
-- 对不上】的预留 —— 而这张表存在的全部意义就是它与那对流水说的是同一件事。
-- (同 sales_order_history / notifications / approval_log:留痕与派生事实
-- 不该有第二个写法。)
CREATE POLICY "sales_order_reservations select by permission" ON public.sales_order_reservations
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.sales.view'::text));

-- ═══ 4 · reserve_stock —— committed 的写入者 ════════════════════════════════
CREATE OR REPLACE FUNCTION public.reserve_stock(
    p_sales_order_line_id uuid,
    p_output_batch_id uuid,
    p_qty numeric,
    p_location_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_pair     uuid := gen_random_uuid();
    v_today    date := CURRENT_DATE;
    v_line     record;
    v_batch    record;
    v_avail    numeric;
    v_already  numeric;
    v_res_id   uuid;
BEGIN
    -- 【为什么是 module.sales.edit,而不是 module.inventory.edit】
    -- 预留就是一次销售行为 —— 做它的人是销售。给它挑一个"销售与库存都满足"的
    -- 权限码,只能挑一个比两者都松的,那不是把关、是把关的样子(与
    -- zzz_function_grants 给 drain_stock 写的那条理由同形)。而台账的不变量
    -- 不依赖调用者是谁:成对写入让物理总量按构造不动,check_no_negative_bucket
    -- 是约束触发器,对任何身份一视同仁。
    PERFORM require_permission('module.sales.edit');

    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'SO_RESERVE_QTY_INVALID|%', COALESCE(p_qty::text, '?');
    END IF;

    SELECT l.id, l.quantity, l.material_id, l.line_no,
           o.id AS order_id, o.code AS order_code, o.status, o.deleted_at
      INTO v_line
      FROM sales_order_lines l
      JOIN sales_orders o ON o.id = l.sales_order_id
     WHERE l.id = p_sales_order_line_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_sales_order_line_id::text, '?');
    END IF;

    -- 【只有确认了的订单才预留】草稿是还没答应的事,给它扣住货,等于让一张
    -- 随手建的单据把库存冻起来,而没有任何人做过那个承诺。
    IF v_line.deleted_at IS NOT NULL OR v_line.status <> 'confirmed' THEN
        RAISE EXCEPTION 'SO_RESERVE_ORDER_NOT_CONFIRMED|%|%',
            v_line.order_code, COALESCE(v_line.status, '?');
    END IF;

    -- 【产出批次,且还在】—— 见本表注释:预留一个进料批次会造出永远消耗不掉的
    -- 承诺库存(movement_type='sale' 被 inventory_movements_side 钉在产出侧)。
    SELECT ob.id, ob.code, ob.material_id, ob.unit
      INTO v_batch
      FROM output_batches ob
     WHERE ob.id = p_output_batch_id AND ob.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_RESERVE_OUTPUT_ONLY|%', COALESCE(p_output_batch_id::text, '?');
    END IF;

    IF v_batch.material_id IS DISTINCT FROM v_line.material_id THEN
        RAISE EXCEPTION 'SO_RESERVE_MATERIAL_MISMATCH|%|%|%',
            v_batch.code,
            (SELECT code FROM materials WHERE id = v_batch.material_id),
            (SELECT code FROM materials WHERE id = v_line.material_id);
    END IF;

    -- 【行的天花板】一行订单最多只能许出它自己的数量。超过就是把同一批货
    -- 许给同一行两次 —— 屏幕上看不出来,发货时才炸。
    SELECT COALESCE(sum(r.qty), 0) INTO v_already
      FROM sales_order_reservations r
     WHERE r.sales_order_line_id = p_sales_order_line_id AND r.released_at IS NULL;
    IF v_already + p_qty > v_line.quantity THEN
        RAISE EXCEPTION 'SO_RESERVE_EXCEEDS_LINE|%|%|%', p_qty, v_line.quantity, v_already;
    END IF;

    -- 【就地求和,不调 derived_stock_qty】那个函数体里有
    -- require_permission('module.inventory.view'),而 has_permission 解析的是
    -- 【调用者】的 JWT —— DEFINER 换得了行的可见性,换不了函数体内那句对调用者
    -- 的判断。销售的人没有库存的码,调过去当场 PERMISSION_DENIED。
    -- record_output_sale 就地求和,同一个理由。
    SELECT COALESCE(sum(m.qty_delta), 0) INTO v_avail
      FROM inventory_movements m
     WHERE m.output_batch_id = p_output_batch_id
       AND m.inbound_batch_id IS NULL
       AND m.location_id IS NOT DISTINCT FROM p_location_id
       AND m.stock_status = 'available';
    IF p_qty > v_avail THEN
        RAISE EXCEPTION 'SO_RESERVE_EXCEEDS_AVAILABLE|%|%', p_qty, v_avail;
    END IF;

    -- 成对:出 available、进 committed。同批次、同库位。物理总量按构造不动,
    -- remaining_qty 一个字不变,批次的 state 也不变(承诺不是销售)。
    INSERT INTO inventory_movements
        (output_batch_id, location_id, movement_type,
         qty_delta, stock_status, pair_id, business_date, notes, created_by)
    VALUES
        (p_output_batch_id, p_location_id, 'status_change_out',
         -p_qty, 'available', v_pair, v_today,
         'reserved for ' || v_line.order_code || ' line ' || v_line.line_no, v_user),
        (p_output_batch_id, p_location_id, 'status_change_in',
          p_qty, 'committed', v_pair, v_today,
         'reserved for ' || v_line.order_code || ' line ' || v_line.line_no, v_user);

    INSERT INTO sales_order_reservations
        (sales_order_line_id, output_batch_id, location_id, qty, pair_id, created_by)
    VALUES (p_sales_order_line_id, p_output_batch_id, p_location_id, p_qty, v_pair, v_user)
    RETURNING id INTO v_res_id;

    INSERT INTO sales_order_history (sales_order_id, change_type, detail)
    VALUES (v_line.order_id, 'reserved',
            format('line %s · %s %s %s', v_line.line_no, v_batch.code, p_qty, v_batch.unit));

    RETURN jsonb_build_object(
        'reservation_id', v_res_id, 'pair_id', v_pair, 'qty', p_qty,
        'output_batch_id', p_output_batch_id, 'location_id', p_location_id,
        'available_after', v_avail - p_qty,
        'line_reserved_after', v_already + p_qty,
        'line_quantity', v_line.quantity);
END;
$function$;

-- ═══ 5 · release_reservation —— committed 回到 available ════════════════════
CREATE OR REPLACE FUNCTION public.release_reservation(
    p_reservation_id uuid,
    p_qty numeric DEFAULT NULL,
    p_reason text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_pair   uuid := gen_random_uuid();
    v_today  date := CURRENT_DATE;
    v_res    record;
    v_order  record;
    v_want   numeric;
    v_rest   numeric;
    v_new    jsonb := NULL;
BEGIN
    PERFORM require_permission('module.sales.edit');

    SELECT r.*, l.line_no, l.sales_order_id
      INTO v_res
      FROM sales_order_reservations r
      JOIN sales_order_lines l ON l.id = r.sales_order_line_id
     WHERE r.id = p_reservation_id
     FOR UPDATE OF r;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_RESERVATION_NOT_FOUND|%', COALESCE(p_reservation_id::text, '?');
    END IF;
    IF v_res.released_at IS NOT NULL THEN
        RAISE EXCEPTION 'SO_RESERVATION_ALREADY_RELEASED|%', p_reservation_id;
    END IF;

    -- 【释放要留下为什么,与暂扣同一条】一次没有理由的释放,过两天没人说得清
    -- 那批货为什么不再属于那张订单了。(hold_stock 的理由必填 / release_stock 的
    -- 备注可选,那处不对称是因为放开暂扣是"回到常态";这里不是 —— 撤回一个
    -- 已经做出的承诺【本身】就是一个需要解释的动作。)
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'SO_RELEASE_REASON_REQUIRED|%', p_reservation_id;
    END IF;

    v_want := COALESCE(p_qty, v_res.qty);
    IF v_want <= 0 OR v_want > v_res.qty THEN
        RAISE EXCEPTION 'SO_RELEASE_EXCEEDS|%|%', v_want, v_res.qty;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【部分释放 = 整行释放 + 就地重新预留剩余】
    -- 不是"把 qty 改小"。一行预留是一个发生过的事实(某日许了 40),把它改成
    -- 25 是在改写历史。整行释放之后再预留 15,留下的是两条都为真的事实,
    -- 合起来正好是发生过的经过 —— 而且流水侧一样对得上:先整笔 40 回到
    -- available,再 15 进 committed,净效果就是放回 25。
    -- 【重新预留走的是 reserve_stock 本身】,不是一段抄过来的插入:它会重新
    -- 走一遍订单状态、行天花板、桶余量三道检查。同一条规则,一个实现。
    -- ════════════════════════════════════════════════════════════════════════
    INSERT INTO inventory_movements
        (output_batch_id, location_id, movement_type,
         qty_delta, stock_status, pair_id, business_date, notes, created_by)
    VALUES
        (v_res.output_batch_id, v_res.location_id, 'status_change_out',
         -v_res.qty, 'committed', v_pair, v_today, btrim(p_reason), v_user),
        (v_res.output_batch_id, v_res.location_id, 'status_change_in',
          v_res.qty, 'available', v_pair, v_today, btrim(p_reason), v_user);

    UPDATE sales_order_reservations
       SET released_at     = now(),
           released_by     = v_user,
           release_reason  = btrim(p_reason),
           release_pair_id = v_pair
     WHERE id = p_reservation_id;

    v_rest := v_res.qty - v_want;
    IF v_rest > 0 THEN
        v_new := reserve_stock(v_res.sales_order_line_id, v_res.output_batch_id,
                               v_rest, v_res.location_id);
    END IF;

    INSERT INTO sales_order_history (sales_order_id, change_type, detail)
    VALUES (v_res.sales_order_id, 'released',
            format('line %s · %s · %s', v_res.line_no, v_want, btrim(p_reason)));

    RETURN jsonb_build_object(
        'reservation_id', p_reservation_id,
        'released_qty', v_want,
        'release_pair_id', v_pair,
        'rereserved_qty', v_rest,
        'rereserved', v_new);
END;
$function$;

-- ═══ 6 · 作废即释放 —— 【断言,不是假设】═══════════════════════════════════
CREATE OR REPLACE FUNCTION public.set_sales_order_status(p_order_id uuid, p_to text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_order sales_orders%ROWTYPE;
    v_cust  record;
    v_ok    boolean;
    v_res   record;
    v_freed numeric := 0;
    v_left  int;
BEGIN
    PERFORM require_permission('module.sales.edit');

    SELECT * INTO v_order FROM sales_orders WHERE id = p_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_order_id::text, '?');
    END IF;

    -- 【允许的去处,逐个状态写出来】
    v_ok := CASE v_order.status
        WHEN 'draft'     THEN p_to IN ('confirmed','cancelled')
        WHEN 'confirmed' THEN p_to IN ('closed','cancelled')
        WHEN 'closed'    THEN false      -- 终态
        WHEN 'cancelled' THEN false      -- 终态
        ELSE false
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'SO_TRANSITION_NOT_ALLOWED|%|%', v_order.status, p_to;
    END IF;

    IF p_to = 'cancelled' AND (p_reason IS NULL OR btrim(p_reason) = '') THEN
        RAISE EXCEPTION 'SO_CANCEL_REASON_REQUIRED|%', v_order.code;
    END IF;

    -- 【确认要看客户的信用冻结】一张确认了的订单是一个承诺;对一个被冻结的
    -- 客户做承诺,与 record_output_sale 拒绝给他发货是同一条判断,只是早一步。
    -- 【只看 credit_hold,不看额度】额度是随敞口变的,而订单还没产生敞口 ——
    -- 拿一个将来的数去拒绝一张今天的单,会把"可能超限"演成"已经超限"。
    IF p_to = 'confirmed' THEN
        SELECT credit_hold, code INTO v_cust FROM customers WHERE id = v_order.customer_id;
        IF v_cust.credit_hold THEN
            RAISE EXCEPTION 'SO_CUSTOMER_ON_HOLD|%', v_cust.code;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM sales_order_lines WHERE sales_order_id = p_order_id) THEN
            RAISE EXCEPTION 'SO_NO_LINES|%', v_order.code;
        END IF;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- SO-2:【作废即释放,而且在改状态【之前】做】
    -- 一张作废的订单不该继续扣着货 —— 那批货会以 committed 的身份留在账上,
    -- 谁也卖不掉、谁也投不了,而屏幕上没有任何东西解释为什么。
    -- 【为什么在 UPDATE 之前】释放走 release_reservation,它会重新读这一行;
    -- 放在后面就得让它面对一个已经作废的订单,那是给自己造一个例外。
    -- 放在前面,任何一条释放失败都会把整个作废一起回滚 —— 要么单据作废了、
    -- 货也放回来了,要么两件都没发生。
    -- 【closed 不释放,那是另一件事】走完的订单,它的货是发出去了,不是放回去了。
    -- ════════════════════════════════════════════════════════════════════════
    IF p_to = 'cancelled' THEN
        FOR v_res IN
            SELECT r.id, r.qty
              FROM sales_order_reservations r
              JOIN sales_order_lines l ON l.id = r.sales_order_line_id
             WHERE l.sales_order_id = p_order_id AND r.released_at IS NULL
             ORDER BY r.created_at
        LOOP
            PERFORM release_reservation(v_res.id, NULL, 'order cancelled: ' || btrim(p_reason));
            v_freed := v_freed + v_res.qty;
        END LOOP;

        -- 【断言,不是假设】上面那个循环跑完之后【不该】还剩活预留。
        -- 一条 release 悄悄没生效(将来有人给它加了一个提前 RETURN),
        -- 结果是一张作废的单还扣着货 —— 而那件事不会有任何东西报出来。
        SELECT count(*) INTO v_left
          FROM sales_order_reservations r
          JOIN sales_order_lines l ON l.id = r.sales_order_line_id
         WHERE l.sales_order_id = p_order_id AND r.released_at IS NULL;
        IF v_left <> 0 THEN
            RAISE EXCEPTION 'SO_CANCEL_RESERVATIONS_LEFT|%|%', v_order.code, v_left;
        END IF;
    END IF;

    -- 上下文标记:让冻结守卫知道是【转换函数】在动状态列(同 po_status_ctx)
    PERFORM set_config('evoltrya.so_status_ctx', '1', true);
    UPDATE sales_orders
       SET status       = p_to,
           confirmed_at = CASE WHEN p_to = 'confirmed' THEN now() ELSE confirmed_at END,
           closed_at    = CASE WHEN p_to = 'closed'    THEN now() ELSE closed_at END,
           cancelled_at = CASE WHEN p_to = 'cancelled' THEN now() ELSE cancelled_at END,
           cancel_reason= CASE WHEN p_to = 'cancelled' THEN p_reason ELSE cancel_reason END,
           updated_at   = now(),
           updated_by   = auth.uid()
     WHERE id = p_order_id;
    PERFORM set_config('evoltrya.so_status_ctx', '', true);

    INSERT INTO sales_order_history (sales_order_id, change_type, detail)
    VALUES (p_order_id, p_to, p_reason);

    RETURN jsonb_build_object('id', p_order_id, 'status', p_to,
                              'released_qty', v_freed);
END;
$function$;

-- ═══ 7 · 注销 / 冲销:有活预留就拒,点名并给出补救 ═══════════════════════════
CREATE OR REPLACE FUNCTION public.emit_batch_writeoff_movement()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ctx   text := current_setting('evoltrya.movement_ctx', true);
    v_run   uuid;
    v_value numeric;
    v_acct  text;
    v_amt   numeric;
    v_bd    date;      -- FIN-32:这条流水的【业务日】
    v_resn  int;
    v_orders text;
BEGIN
    -- ════════════════════════════════════════════════════════════════════════
    -- SO-2:【一批还许着人的货,不能就这么注销掉】
    -- 排空一律走 drain_stock 的 ARRAY['available','on_hold'] —— 那两个桶是
    -- 【没有外部账】的:暂扣只是一个理由字符串。committed 不同,它在
    -- sales_order_reservations 里有一行对应的事实,还挂在某张订单的某一行上。
    -- 把它排空,那一行预留会指着一批不存在的货,而订单页上什么都不会变。
    -- 【所以这里不是"把 committed 加进排空数组",而是拒绝】—— 补救写在消息里:
    -- 先释放(那一步会留下理由、会回到 available、会写进订单历史),再注销。
    -- 【一个决定,而不是一次保守】:注销是不可逆的,而释放是有主人的动作;
    -- 让系统替销售决定"这个承诺可以撤了",正是它不该做的事。
    -- 反过来说,drain 的两个数组【一个字都不用改】:committed 在这里就被挡住了,
    -- 排空永远见不到它。
    -- ════════════════════════════════════════════════════════════════════════
    IF TG_TABLE_NAME = 'output_batches' THEN
        SELECT count(*), string_agg(DISTINCT o.code, ', ' ORDER BY o.code)
          INTO v_resn, v_orders
          FROM sales_order_reservations r
          JOIN sales_order_lines l ON l.id = r.sales_order_line_id
          JOIN sales_orders o      ON o.id = l.sales_order_id
         WHERE r.output_batch_id = OLD.id AND r.released_at IS NULL;
        IF v_resn > 0 THEN
            RAISE EXCEPTION 'SO_BATCH_HAS_RESERVATIONS|%|%|%', OLD.code, v_resn, v_orders;
        END IF;
    END IF;

    IF OLD.remaining_qty > 0 THEN
        -- ════════════════════════════════════════════════════════════════════
        -- FIN-32:business_date =【这件事在业务上发生在哪一天】,与它被记进系统的
        -- 时刻是两回事。两类事,两个答案,不能共用一个:
        --
        --   * 注销(writeoff)是【真实发生的物理事件】—— 货报废了。发生在有人
        --     按下注销的那天,而那天就写在行上:deleted_at。取它的日期部分,
        --     是【读记录】而不是 CURRENT_DATE 那种【当场编一个】。
        --     (触发器只在 deleted_at 由空变非空时触发,所以它必然有值。)
        --
        --   * 冲销(reversal_void)【不是物理事件】—— 电池处理过了就处理过了,
        --     回滚是在更正一次【记错的加工单】。所以它的业务日是【原加工单的
        --     process_date】,不是今天:那样一错一改在同一天对消,中间那几天的
        --     库存历史不会凭空多出一批实际并不存在的货。
        --     会计侧的先例同向:reverse_journal_entry 把冲销日做成【显式入参】,
        --     从不假定 —— 这里没有入参可传,但答案同样来自记录(run.process_date),
        --     不来自时钟。
        --
        -- 【两个账会给出两个日期,这是知情的选择,不是疏漏】(FIN-32-fu1)
        -- 同一次更正:分录侧的冲销按【显式传入的冲销日】入账(它必须如此 ——
        -- 期间锁不许往已关闭的月份里塞东西),而这里的流水按【原加工日】。
        -- 于是一次更正在两个账里带着两个日期。这是两种账的性质不同:
        --   * 分录是【价值账,带锁】—— 它记的是"这笔更正在哪个会计期发生";
        --   * 流水是【数量账,无锁】—— 它记的是"那批货实际在不在库里"。
        -- 按日期把两个账对起来的人一定会撞上这处差异,所以写在这里:
        -- 撞上时该问的是"这两个日期各自回答的是哪个问题",不是"哪个错了"。
        -- ════════════════════════════════════════════════════════════════════
        IF TG_TABLE_NAME = 'inbound_batches' THEN
            -- IOD-1:注销排空【所有】桶,两种状态都算 —— 报废一批货,不会因为其中
            -- 一部分被扣住就留在账上。这也是三个消耗方里唯一一个必须动 on_hold 的。
            -- SO-2:committed 不在数组里,因为它【到不了这里】(上面已经拒了);
            -- 进料批次本来也不可能有 committed —— 预留只指向产出批次。
            PERFORM drain_stock(
                p_qty => OLD.remaining_qty, p_movement_type => 'writeoff',
                p_business_date => NEW.deleted_at::date, p_inbound_batch_id => OLD.id,
                p_statuses => ARRAY['available','on_hold'], p_created_by => NEW.updated_by);
        ELSE  -- output_batches
            IF v_ctx IS NOT NULL AND split_part(v_ctx, ':', 1) = 'reversal' THEN
                v_run := split_part(v_ctx, ':', 2)::uuid;
                SELECT process_date INTO v_bd FROM processing_runs WHERE id = v_run;
                PERFORM drain_stock(
                    p_qty => OLD.remaining_qty, p_movement_type => 'reversal_void',
                    p_business_date => v_bd, p_output_batch_id => OLD.id,
                    p_statuses => ARRAY['available','on_hold'], p_run_id => v_run,
                    p_created_by => NEW.updated_by);
            ELSE
                PERFORM drain_stock(
                    p_qty => OLD.remaining_qty, p_movement_type => 'writeoff',
                    p_business_date => NEW.deleted_at::date, p_output_batch_id => OLD.id,
                    p_statuses => ARRAY['available','on_hold'], p_created_by => NEW.updated_by);
            END IF;
        END IF;

        -- cut 2a:注销即入账(仅已计值批次,借 5200 / 贷 1200|1220)。
        -- processing 回滚(reversal_void)不入账:本 cut 不记加工产出/消耗分录,
        -- void 的产出从未入过 1220,无可冲销。未计值批次只出量不入账。
        IF v_ctx IS NULL OR split_part(v_ctx, ':', 1) <> 'reversal' THEN
            IF TG_TABLE_NAME = 'inbound_batches' THEN
                v_value := OLD.unit_price;
                v_acct := '1200';
            ELSE
                SELECT po.unit_cost_base INTO v_value
                FROM public.processing_outputs po
                WHERE po.output_batch_id = OLD.id
                LIMIT 1;
                v_acct := '1220';
            END IF;

            IF v_value IS NOT NULL THEN
                v_amt := round(OLD.remaining_qty * v_value, 2);
                IF v_amt <> 0 THEN
                    PERFORM post_journal_entry(
                        CURRENT_DATE,
                        'Write-off ' || OLD.code,
                        'writeoff', OLD.id,
                        jsonb_build_array(
                            jsonb_build_object('account_code', '5200', 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_amt),
                            jsonb_build_object('account_code', v_acct, 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_amt)));
                END IF;
            END IF;
        END IF;

        NEW.remaining_qty := 0;
    END IF;

    RETURN NEW;
END;
$function$;

-- ═══ 8 · 转移:committed 也搬得动,但【整桶搬,或者不搬】═══════════════════
CREATE OR REPLACE FUNCTION public.create_stock_transfer(p_qty numeric, p_to_location_id uuid, p_inbound_batch_id uuid DEFAULT NULL::uuid, p_output_batch_id uuid DEFAULT NULL::uuid, p_from_location_id uuid DEFAULT NULL::uuid, p_stock_status text DEFAULT 'available'::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_pair     uuid := gen_random_uuid();
    v_have     numeric;
    v_today    date := CURRENT_DATE;
    v_material uuid;
    v_warn     text[];
    v_reserved numeric;
BEGIN
    PERFORM require_permission('module.inventory.edit');

    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN
        RAISE EXCEPTION 'STK_ONE_BATCH';
    END IF;
    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'STK_QTY_INVALID|%', COALESCE(p_qty::text, '?');
    END IF;
    -- SO-2:【一个坏状态不是一个坏数量】。此前这里抛的是 STK_QTY_INVALID,
    -- 于是"你传了一个系统不认识的库存状态"会在屏幕上显示成"数量无效" ——
    -- 一条把人送去看错地方的消息。三个桶都在这里列出来。
    IF p_stock_status IS NULL OR p_stock_status NOT IN ('available','on_hold','committed') THEN
        RAISE EXCEPTION 'IOD_TRANSFER_STATUS_INVALID|%', COALESCE(p_stock_status, '?');
    END IF;
    -- 【源与目的相同】不是一次无害的空操作:它会写下两行互相抵消的流水,
    -- 把台账弄脏,而且几乎总是意味着操作的人选错了一边。
    IF p_from_location_id IS NOT DISTINCT FROM p_to_location_id THEN
        RAISE EXCEPTION 'IOD_TRANSFER_SAME_LOCATION';
    END IF;
    -- 目的地必须是一个【在用】的库位。停用的库位不该再收货(LOC-1 的停用语义)。
    IF p_to_location_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM storage_locations WHERE id = p_to_location_id AND is_active) THEN
        RAISE EXCEPTION 'IOD_TRANSFER_TO_INACTIVE|%', COALESCE(p_to_location_id::text, '?');
    END IF;

    -- 【同一粒度】对着派生桶比,与 STK-1 的暂扣/释放一模一样:
    -- remaining_qty 没有库位轴,在这个粒度上现算是唯一可能的来源。
    v_have := derived_stock_qty(p_inbound_batch_id, p_output_batch_id, p_from_location_id, p_stock_status);
    IF p_qty > v_have THEN
        RAISE EXCEPTION 'IOD_TRANSFER_EXCEEDS_BUCKET|%|%', p_qty, v_have;
    END IF;

    -- IOD-2:落闸,【只在入腿上】。物料从批次反查 —— 两种批次二选一(上面的
    -- XOR 已经保证恰好一个非空),两张表都有 material_id NOT NULL。
    -- 【出腿一个字都不查】:分类管的是货可以待在哪里,不是货能不能离开;拦住
    -- 一批放错地方的货【离开】,只会把它焊死在错的地方。
    v_material := COALESCE(
        (SELECT material_id FROM inbound_batches WHERE id = p_inbound_batch_id),
        (SELECT material_id FROM output_batches  WHERE id = p_output_batch_id));
    v_warn := check_location_class(p_to_location_id, v_material);
    -- NTF-1:告警留一份下来(入腿的库位/物料)。返回值那一份不变。
    PERFORM notify_landing_warnings(v_warn, p_to_location_id, v_material);

    -- 成对:出源库位、进目的库位。【状态原样带过去】—— 转移搬的是位置,
    -- 不是状态;一批被扣住的货换个货架仍然是被扣住的。
    INSERT INTO inventory_movements
        (inbound_batch_id, output_batch_id, location_id, movement_type,
         qty_delta, stock_status, pair_id, business_date, notes, created_by)
    VALUES
        (p_inbound_batch_id, p_output_batch_id, p_from_location_id, 'transfer_out',
         -p_qty, p_stock_status, v_pair, v_today, NULLIF(btrim(COALESCE(p_note,'')),''), v_user),
        (p_inbound_batch_id, p_output_batch_id, p_to_location_id, 'transfer_in',
          p_qty, p_stock_status, v_pair, v_today, NULLIF(btrim(COALESCE(p_note,'')),''), v_user);

    -- ════════════════════════════════════════════════════════════════════════
    -- SO-2:【committed 的货搬走了,预留行必须跟着走 —— 而且只允许整桶搬】
    --
    -- 预留行记的是 批次 × 库位 这个桶。桶里的货搬到别的库位,而预留行还写着
    -- 老库位,那两句话当场对不上:流水说这 40kg 在 B,预留说它在 A。
    --
    -- 【为什么只允许整桶】部分搬走就得回答"这 40 里哪 15 跟着走" —— 而预留行
    -- 是按订单行分的,没有任何东西能回答那个问题;系统替人挑一行,就是编造。
    -- 所以:整桶搬,预留行的 location_id 跟着改(那是"这批货现在放在哪",不是
    -- "当初许了什么");搬不完就点名拒绝,补救写在消息里 —— 先部分释放,
    -- 再搬,再重新预留。三步各自留下自己的痕迹。
    --
    -- 【改 location_id 是本表唯一允许的事后改写】,由 evoltrya.reservation_move_ctx
    -- 向守卫说明"这是转移在改",而不是让守卫对任何 UPDATE 都放行一列。
    -- ════════════════════════════════════════════════════════════════════════
    IF p_stock_status = 'committed' THEN
        SELECT COALESCE(sum(r.qty), 0) INTO v_reserved
          FROM sales_order_reservations r
         WHERE r.output_batch_id IS NOT DISTINCT FROM p_output_batch_id
           AND r.location_id IS NOT DISTINCT FROM p_from_location_id
           AND r.released_at IS NULL;

        IF v_reserved > 0 AND p_qty <> v_reserved THEN
            RAISE EXCEPTION 'IOD_TRANSFER_COMMITTED_PARTIAL|%|%', p_qty, v_reserved;
        END IF;

        IF v_reserved > 0 THEN
            PERFORM set_config('evoltrya.reservation_move_ctx', '1', true);
            UPDATE sales_order_reservations
               SET location_id = p_to_location_id
             WHERE output_batch_id IS NOT DISTINCT FROM p_output_batch_id
               AND location_id IS NOT DISTINCT FROM p_from_location_id
               AND released_at IS NULL;
            PERFORM set_config('evoltrya.reservation_move_ctx', '', true);
        END IF;
    END IF;

    RETURN jsonb_build_object('pair_id', v_pair, 'qty', p_qty,
                              'stock_status', p_stock_status,
                              'warnings', to_jsonb(v_warn));
END;
$function$;

-- ═══ 9 · 违规判据:讲的是【物理存在】,与它许给了谁无关 ═══════════════════════
CREATE OR REPLACE VIEW public.stock_class_violations_all WITH (security_invoker = off) AS
 WITH avail AS (
         SELECT mv.location_id,
            COALESCE(ib.material_id, ob.material_id) AS material_id,
            sum(mv.qty_delta) AS qty
           FROM inventory_movements mv
             LEFT JOIN inbound_batches ib ON ib.id = mv.inbound_batch_id
             LEFT JOIN output_batches ob ON ob.id = mv.output_batch_id
          WHERE mv.location_id IS NOT NULL
          GROUP BY mv.location_id, (COALESCE(ib.material_id, ob.material_id))
         HAVING sum(mv.qty_delta) > 0::numeric
        )
 SELECT a.material_id,
    m.code AS material_code,
    m.waste_classification_code AS class_code,
    a.location_id,
    sl.code AS location_code,
    a.qty
   FROM avail a
     JOIN materials m ON m.id = a.material_id
     JOIN storage_locations sl ON sl.id = a.location_id
  WHERE m.deleted_at IS NULL AND m.waste_classification_code IS NOT NULL AND (EXISTS ( SELECT 1
           FROM storage_location_allowed_classes c
          WHERE c.location_id = a.location_id)) AND NOT (EXISTS ( SELECT 1
           FROM storage_location_allowed_classes c
          WHERE c.location_id = a.location_id AND c.classification_code = m.waste_classification_code));

COMMENT ON VIEW public.stock_class_violations_all IS
    'RPT-1:分类违规的【唯一一处判据】(三态:未分类不算、未配置不算、配了且不含这一类才算)。两个消费者读同一处 —— notify_class_violations(NTF-1 的发射器,以属主身份直接读它)与 stock_class_violations(报表侧,在它之上加 has_permission 那道门)。【SO-2:所有库存状态一起算,不再只看 available】违规讲的是【这批货待在哪里】,与它扣没扣住、许给了谁毫无关系;只看 available 的话,一次暂扣或一次预留就能把一条真实存在的违规从报表里抹掉 —— 而货还在那个不该放它的库位上。【客户端读不到本视图】:REVOKE SELECT —— 它不带门,能读它就等于绕过那道门读全库违规。【为什么是视图而不是函数】属主权限视图对它引用的表/视图走属主替换,但视图体里调函数时 EXECUTE 仍按当前用户判 —— 前一版把判据放在被收权的函数里,authenticated 读报表当场 42501(冒烟查出来的)。';

-- ═══ 10 · 卖不掉的时候,把三个数都说出来 ═════════════════════════════════════
CREATE OR REPLACE FUNCTION public.record_output_sale(p_output_batch_id uuid, p_quantity numeric, p_unit_price numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_customer_id uuid DEFAULT NULL::uuid, p_sale_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_price_source text DEFAULT NULL::text, p_price_provenance jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user          uuid := auth.uid();
    v_deleted       timestamptz;
    v_remaining     numeric;
    v_code          text;
    v_new_remaining numeric;
    v_state         text;
    v_fx            numeric;
    v_amount_base    numeric;
    v_movement_id   uuid;
    v_movement_ids  uuid[];
    v_available     numeric;
    v_held          numeric;
    v_committed     numeric;
    v_sale_id       uuid;
    v_sale_date     date;
    v_unit_cost     numeric;
    v_cogs          numeric;
    v_je1           jsonb;
    v_je2           jsonb;
BEGIN
    PERFORM require_permission('module.output.edit');
    IF p_sale_date IS NULL THEN
        RAISE EXCEPTION 'SALE_DATE_REQUIRED';
    END IF;
    v_sale_date := p_sale_date;
    SELECT deleted_at, remaining_qty, code INTO v_deleted, v_remaining, v_code
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
    -- IOD-1:【可卖的是"可用",不是"物理剩余"】。被扣住的货仍在这批里,
    -- 但它不可动用 —— 所以拒绝必须同时说出两个数,否则人看着 remaining 够
    -- 却卖不掉,屏幕上没有任何东西解释为什么。
    -- SO-2:第三个桶,同一条理由 —— 【一个说不出 committed 的拒绝,会让人
    -- 看着"可用 0、暂扣 0"却卖不掉】,而真正的答案是"它许给了某张订单"。
    -- 消息里因此有三个数;哪一张订单由订单页与批次面板的预留清单回答。
    -- 【这一刀不从 committed 里卖】:发货消耗归 cut 4,它会带着订单行一起来。
    v_available := COALESCE((SELECT sum(qty_delta) FROM inventory_movements
                             WHERE output_batch_id = p_output_batch_id
                               AND stock_status = 'available'), 0);
    v_held := COALESCE((SELECT sum(qty_delta) FROM inventory_movements
                        WHERE output_batch_id = p_output_batch_id
                          AND stock_status = 'on_hold'), 0);
    v_committed := COALESCE((SELECT sum(qty_delta) FROM inventory_movements
                             WHERE output_batch_id = p_output_batch_id
                               AND stock_status = 'committed'), 0);
    IF p_quantity > v_available THEN
        RAISE EXCEPTION 'IOD_SALE_EXCEEDS_AVAILABLE|%|%|%|%',
            p_quantity, v_available, v_held, v_committed;
    END IF;

    IF p_unit_price IS NULL OR p_unit_price <= 0 THEN
        RAISE EXCEPTION 'SALE_PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0:本位币 SGD 免换算;外币按【交易日】的行方买入价(tt_buy)估值 ——
    -- 收入与应收是我们将来要【卖给银行】的外币。当日无牌价即拒(FX_RATE_MISSING),
    -- 不许悄悄用最近一天的。汇率不再由调用方递入:牌价属于 fx_rates,不属于表单。
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    v_fx := fx_rate_for(p_currency, v_sale_date, 'tt_buy');
    v_amount_base := round(p_quantity * p_unit_price * v_fx, 2);

    -- ── SAL-B:信用管控 —— 拦截【暂放在这里】,等销售订单存在就搬到下单处 ──────
    -- (docs/sales-scoping.md §6/§8:quote 无处挂、order 未建、发货是今天唯一的
    -- 咽喉。搬,不要在订单上再加第二道检查 —— 两道检查就是两份会漂的实现。)
    IF p_customer_id IS NOT NULL THEN
        DECLARE
            v_hold  boolean;
            v_limit numeric;
            v_cust_code text;
            v_exposure numeric;
        BEGIN
            SELECT credit_hold, credit_limit_base, code
            INTO v_hold, v_limit, v_cust_code
            FROM customers WHERE id = p_customer_id;
            -- 人工冻结:无论敞口多少都停发(争议发票时停货不是算术条件)
            IF v_hold THEN
                RAISE EXCEPTION 'CREDIT_HOLD|%', v_cust_code;
            END IF;
            -- 【NULL = 没设限额(放行);0 = 现款现货(任何赊销都拒)—— 相反,不是相近】
            -- 把 NULL 当 0 用会拒掉全部既有客户的销售;fixture 39A 两头钉死。
            IF v_limit IS NOT NULL THEN
                v_exposure := customer_ar_exposure_base(p_customer_id);
                -- 【本位币比较】,与审批阈值同理:单据币种比较会让 USD 客户越过
                -- SGD 客户越不过的限额(fixture 39B 用同一个判别形状钉住)
                IF v_exposure + v_amount_base > v_limit THEN
                    -- 【把数字说全】:限额、当前敞口、这一单 —— 只说"超限"等于
                    -- 让人去手算系统已经知道的三个数
                    RAISE EXCEPTION 'CREDIT_LIMIT_EXCEEDED|%|%|%|%',
                        v_cust_code, v_limit, v_exposure, v_amount_base;
                END IF;
            END IF;
        END;
    END IF;

    -- IOD-1:出货走 drain_stock —— 一次销售可能跨几个库位桶,于是写出【多行】流水。
    -- 顺序与规则收在 drain_stock 一处(见其函数头),销售这一层只说"拿这么多出来"。
    -- 【sales_records.movement_id 记第一行】:那一列是单值外键,而一次销售现在
    -- 可能对应多行。取第一行是有意的取舍,不是疏忽 —— 完整的行集合按
    -- (output_batch_id, movement_type='sale', business_date) 可取回;
    -- 真要一一对应,该做的是给 sales_records 建一张腿表,那是另一刀。
    v_movement_ids := drain_stock(
        p_qty => p_quantity, p_movement_type => 'sale', p_business_date => v_sale_date,
        p_output_batch_id => p_output_batch_id, p_statuses => ARRAY['available'],
        p_notes => p_notes, p_created_by => v_user);
    v_movement_id := v_movement_ids[1];

    -- customer_id 有效性由 FK 把关(可空:批次可能未指定客户)
    -- SAL-A(FIN-26 的卖方半边):出处是【记录】,不是从公式在不在推断。
    -- computed 必带依据;manual/NULL 不留依据 —— 空白好过编造。
    IF p_price_source IS NOT NULL AND p_price_source NOT IN ('computed', 'manual') THEN
        RAISE EXCEPTION 'PRICE_SOURCE_INVALID|%', p_price_source;
    END IF;
    IF p_price_source = 'computed' AND (p_price_provenance IS NULL OR jsonb_typeof(p_price_provenance) <> 'object') THEN
        RAISE EXCEPTION 'PROVENANCE_REQUIRED';
    END IF;

    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price, currency, fx_rate, amount_base, sale_date, notes, movement_id, created_by, price_source, price_provenance)
    VALUES (p_output_batch_id, p_customer_id, p_quantity, p_unit_price, p_currency, v_fx, v_amount_base, v_sale_date, p_notes, v_movement_id, v_user,
            p_price_source,
            CASE WHEN p_price_source = 'computed' THEN p_price_provenance END)
    RETURNING id INTO v_sale_id;

    -- cut 2a JE#1:收入 —— 借 1100 / 贷 4000,原币行(amount_ccy = qty × price,
    -- fx 原样),USD 侧由 post_journal_entry 折算,与 amount_base 同式同值。
    v_je1 := post_journal_entry(
        v_sale_date,
        'Sale ' || v_code,
        'sale', v_sale_id,
        jsonb_build_array(
            jsonb_build_object('account_code', '1100', 'side', 'debit',  'currency', p_currency, 'amount_ccy', p_quantity * p_unit_price, 'fx_rate', v_fx),
            jsonb_build_object('account_code', '4000', 'side', 'credit', 'currency', p_currency, 'amount_ccy', p_quantity * p_unit_price, 'fx_rate', v_fx)));

    -- cut 2a JE#2:COGS —— 有产出腿单位成本才挂;没有则只挂收入(cogs_journal 为
    -- null),等 allocate_processing_costs 补挂(见其 COGS catch-up)。
    SELECT po.unit_cost_base INTO v_unit_cost
    FROM processing_outputs po
    WHERE po.output_batch_id = p_output_batch_id
    LIMIT 1;

    IF v_unit_cost IS NOT NULL THEN
        v_cogs := round(p_quantity * v_unit_cost, 2);
        IF v_cogs <> 0 THEN
            v_je2 := post_journal_entry(
                v_sale_date,
                'COGS ' || v_code,
                'sale', v_sale_id,
                jsonb_build_array(
                    jsonb_build_object('account_code', '5000', 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_cogs),
                    jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_cogs)));
            UPDATE sales_records SET cogs_entry_id = (v_je2->>'entry_id')::uuid WHERE id = v_sale_id;
        END IF;
    END IF;

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
        'state', v_state,
        'sale_id', v_sale_id,
        'amount_base', v_amount_base,
        'revenue_journal', v_je1->>'code',
        'cogs_journal', v_je2->>'code'
    );
END;
$function$;

COMMIT;
