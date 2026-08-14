-- db/tables/shipment_lines.sql
-- SO-3b:发货单行 —— 一行 = 一次【消耗掉一条预留】。
--
-- NOTE: introduced by db/migrations/2026-08-15-so3b-shipment.sql.
-- First-run script (plain CREATEs).
--
-- 【为什么一行对一条预留,而不是对一条订单行】预留才带着【地址】:
-- 哪一批货、哪个库位。发货要从 committed 桶里精确地取走那一份,而不是
-- 让排空策略去猜 —— 所以行的主语是预留。一条订单行分两批发,就是两行。
--
-- 【ship_order 只消耗【整条】预留】部分发货在函数里先把预留拆开
-- (release_reservation 的"整笔释放 + 就地重新预留剩余"那一手,一处实现),
-- 于是这里永远是 qty = 那条预留的全部数量。这条不变量让"committed 桶 =
-- Σ 活预留"始终成立 —— create_stock_transfer 的整桶搬正是靠它。

CREATE TABLE public.shipment_lines (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    shipment_id         uuid NOT NULL REFERENCES public.shipments (id) ON DELETE RESTRICT,
    sales_order_line_id uuid NOT NULL REFERENCES public.sales_order_lines (id),
    -- 被消耗掉的那条预留。UNIQUE:一条预留只能被发一次 —— 没有它,同一份
    -- committed 的货可以被两张发货单各取走一遍,而桶只会在提交时才炸。
    reservation_id      uuid NOT NULL UNIQUE REFERENCES public.sales_order_reservations (id),
    -- 冗余但【必要】:预留行的 location_id 会随整桶转移改写,而发货单要记的是
    -- 【发货当刻货在哪】。两者日后可以不同,那正是两个不同的事实。
    output_batch_id     uuid NOT NULL REFERENCES public.output_batches (id),
    location_id         uuid REFERENCES public.storage_locations (id),
    qty                 numeric NOT NULL CHECK (qty > 0),
    -- 这一行产生的销售记录(收入与 COGS 都挂在它上面)
    sales_record_id     uuid NOT NULL REFERENCES public.sales_records (id),
    created_at          timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.shipment_lines IS
    'SO-3b:发货单行 —— 一行 = 一次【消耗掉一条预留】。主语是预留而不是订单行,因为只有预留带着地址(哪一批货、哪个库位);发货要从 committed 桶里精确取走那一份,不让排空策略去猜。ship_order 只消耗【整条】预留(部分发货先用 release_reservation 那一手把预留拆开),于是 qty 恒等于那条预留的全部数量 —— 这条不变量让"committed 桶 = Σ 活预留"始终成立。location_id 是【发货当刻】的库位,与预留行上那个可能不同(整桶转移会改写后者),两者是两个事实。';

CREATE INDEX idx_shipment_lines_shipment ON public.shipment_lines (shipment_id);
CREATE INDEX idx_shipment_lines_order_line ON public.shipment_lines (sales_order_line_id);

CREATE TRIGGER trg_shipment_lines_append_only
    BEFORE UPDATE OR DELETE ON public.shipment_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_shipment_append_only();

ALTER TABLE public.shipment_lines ENABLE ROW LEVEL SECURITY;

CREATE POLICY "shipment_lines select by permission" ON public.shipment_lines
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.sales.view'::text));
