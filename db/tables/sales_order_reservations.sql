-- db/tables/sales_order_reservations.sql
-- SO-2:销售订单的库存预留 —— 订单【行】与产出【批次】的多对多在这里出生。
--
-- NOTE: introduced by db/migrations/2026-08-14-so2-reservation.sql.
-- First-run script (plain CREATEs).
--
-- sales_order_lines 的表头写着"履约(行 ↔ 批次,多对多)归预留/发货那一刀"——
-- 就是这一张表。一行 = 一次预留这个【事实】:某张单的某一行,在某个
-- 批次 × 库位 桶里,许出去了多少。
-- 【活预留 = released_at IS NULL AND consumed_at IS NULL】(SO-3b 起两个条件)——
-- 一条预留有两种终局,而它们是【不同的事实】,不能挤进同一列:
--   * 释放(released_*):货【回到 available】,有一对反向流水(release_pair_id);
--   * 消耗(consumed_*):货【离开了台账】(发货),没有反向流水,对应的是一条
--     'sale' 出库腿与一行 shipment_lines。
-- 把消耗记成"释放"会让台账多出一对并不存在的回流,而那正是 release_pair_id
-- 那条 CHECK 会当场拒绝的东西 —— 约束替我们说明了为什么要第二组列。
--
-- 【它与 inventory_movements 说的是同一件事,而两边必须永远对得上】
-- 一次预留在流水里是一对 status_change(出 available、进 committed),在这里是
-- 一行;pair_id 把两边钉在一起。所以【本表没有面向客户端的 INSERT/UPDATE 策略】:
-- 留一条能直接 POST 的路,等于让人写出一行与流水对不上的预留,而这张表存在的
-- 全部意义就是它与那对流水说的是同一件事。唯一写入口:reserve_stock /
-- release_reservation(都是 SECURITY DEFINER,都要 module.sales.edit)。
--
-- 【为什么释放不是"把 qty 改小"】见 released_* 那几列旁边的注释。

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
    -- ── SO-3b 追加:第二种终局【消耗】(ALTER 加的列排在末尾)──────────────
    -- 发货把这一份 committed 的货取走了。没有反向流水 —— 它离开了台账。
    consumed_at         timestamptz,
    consumed_by         uuid,
    -- 【没有指回 shipment_lines 的外键 —— 这是一个决定,不是遗漏】
    -- shipment_lines.reservation_id 已经是 UNIQUE:映射是一对一的,反向
    -- 那个指针是【冗余】的。而两张表互指会让镜像之间出现【循环依赖】,
    -- 重建根本排不出建表顺序(verify_rebuild 当场报的就是这一条)。
    -- "这条预留被哪一行发货消耗了"由 shipment_lines.reservation_id 反查。
    CONSTRAINT sales_order_reservations_release_complete CHECK (
        (released_at IS NULL     AND release_reason IS NULL     AND release_pair_id IS NULL)
     OR (released_at IS NOT NULL AND release_reason IS NOT NULL AND release_pair_id IS NOT NULL)),
    -- 【两种终局互斥】一条预留不可能既回到 available 又离开台账。
    CONSTRAINT sales_order_reservations_one_ending CHECK (
        released_at IS NULL OR consumed_at IS NULL)
);

COMMENT ON TABLE public.sales_order_reservations IS
    'SO-2:销售订单的库存预留 —— 订单【行】与产出【批次】的多对多在这里出生(sales_order_lines 的注释里说要等的正是它)。一行 = 一次预留这个【事实】:某张单的某一行,在某个 批次 × 库位 桶里,许出去了多少。【活预留 = released_at IS NULL AND consumed_at IS NULL】(SO-3b):一条预留有两种终局 —— 释放(货回到 available,有一对反向流水)与消耗(发货,货离开台账,没有反向流水,对应一条 sale 出库腿与一行 shipment_lines)。把消耗记成释放会让台账多出一对并不存在的回流。【只指向产出批次】:movement_type=''sale'' 被 inventory_movements_side 钉在产出侧,预留一个进料批次会造出永远消耗不掉的承诺库存。【释放不改 qty,而是写三列并整行作废】—— 把 40 改成 25 是在把历史改成"当初只许了 25";部分释放由 release_reservation 做成整行释放 + 就地重新预留剩余,于是每一行都仍然是一个真的事实。唯一写入口:reserve_stock / release_reservation(都要 module.sales.edit)。';

COMMENT ON COLUMN public.sales_order_reservations.location_id IS
    'SO-2:这次预留占用的是哪个库位的桶。NULL = 未指定库位(一等状态,不是缺失 —— LOC-1/STK-1)。【它是本表唯一一列可以在事后被改写的】:committed 的货整桶转移到别的库位时,create_stock_transfer 在 evoltrya.reservation_move_ctx 上下文里把它改过去。改的是"这批货现在放在哪",不是"当初许了什么" —— 后者(行、批次、数量)一个字都不能动。';

COMMENT ON COLUMN public.sales_order_reservations.consumed_at IS
    'SO-3b:这条预留被【发货消耗】掉的时刻。与 released_* 并列而不是共用那三列 —— 释放是"货回到 available"(有一对反向流水),消耗是"货离开了台账"(没有反向流水,对应一条 sale 出库腿与一行 shipment_lines)。活预留 = released_at IS NULL AND consumed_at IS NULL。';

CREATE INDEX idx_so_reservations_line   ON public.sales_order_reservations (sales_order_line_id) WHERE released_at IS NULL AND consumed_at IS NULL;
CREATE INDEX idx_so_reservations_bucket ON public.sales_order_reservations (output_batch_id, location_id) WHERE released_at IS NULL AND consumed_at IS NULL;

-- 只增不改的守卫(函数在 db/functions/guard_sales_order_reservation_append_only.sql)
-- 它【自己报名】抛 SO_RESERVATION_IMMUTABLE,不靠外键顺带挡(FIN-31)。
CREATE TRIGGER trg_so_reservations_append_only
    BEFORE UPDATE OR DELETE ON public.sales_order_reservations
    FOR EACH ROW EXECUTE FUNCTION public.guard_sales_order_reservation_append_only();

ALTER TABLE public.sales_order_reservations ENABLE ROW LEVEL SECURITY;

-- 【没有 INSERT / UPDATE 策略,这是前提而不是遗漏】见文件抬头。
CREATE POLICY "sales_order_reservations select by permission" ON public.sales_order_reservations
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.sales.view'::text));

-- PROC-BUILD-1(R5):占用也拦 —— 圈定一批货就是准备发它。
CREATE TRIGGER trg_so_reservations_form_saleable
    BEFORE INSERT ON public.sales_order_reservations
    FOR EACH ROW EXECUTE FUNCTION public.guard_batch_form_saleable();
