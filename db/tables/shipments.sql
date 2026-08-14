-- db/tables/shipments.sql
-- SO-3b:发货单头 —— 选项 C 的第二半:货离开台账,合同负债释放进收入。
--
-- NOTE: introduced by db/migrations/2026-08-15-so3b-shipment.sql.
-- First-run script (plain CREATEs).
--
-- 【一张发货单属于一张订单】订单流【先开票后发货】,所以发货这一步的前提写在
-- ship_order 里:每一行都必须坐在一张【在册且已过账】的订单流发票上。
-- 那是一条【派生】的检查(去 invoice_lines/invoices 里查),不是订单上的一个
-- 状态位 —— 状态位会与真相漂开,而这个问题每次都问得起。
--
-- 【发货单不可作废,也没有冲销】货发出去了就是发出去了:2500 已经释放进 4000、
-- 库存已经离开台账。更正走【贷项凭证】(credit note,sales_records 表头停放的
-- 未来概念)。这也是 void_invoice 在有发货之后按名拒的理由。

CREATE SEQUENCE public.shipment_code_seq;

CREATE TABLE public.shipments (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code           text NOT NULL UNIQUE,   -- 'SHP-YYYY-NNNN',无缝,自己的咨询锁
    sales_order_id uuid NOT NULL REFERENCES public.sales_orders (id),
    -- 【物理事件日,永不默认】货是哪天离开仓库的。补一个 CURRENT_DATE 会让
    -- "留空"比"填对"更容易通过,而这个日期同时决定收入落进哪个会计期间
    -- (AGENTS.md 的日期规矩;FIN-10 那一族的命名)。
    ship_date      date NOT NULL,
    notes          text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.shipments IS
    'SO-3b:发货单头(选项 C 的第二半)。一张发货单属于一张订单;每一行都必须坐在一张【在册且已过账】的订单流发票上 —— 那是一条派生检查(查 invoice_lines/invoices),不是订单上的状态位,因为状态位会与真相漂开。【不可作废、没有冲销】:货发出去了、负债已释放进收入、库存已离开台账,更正走贷项凭证(sales_records 表头停放的未来概念)。ship_date 是物理事件日,必填、永不默认 —— 它同时决定收入落进哪个会计期间。';

CREATE INDEX idx_shipments_order ON public.shipments (sales_order_id, ship_date);

-- 只增不改(函数在 db/functions/guard_shipment_append_only.sql)
CREATE TRIGGER trg_shipments_append_only
    BEFORE UPDATE OR DELETE ON public.shipments
    FOR EACH ROW EXECUTE FUNCTION public.guard_shipment_append_only();

ALTER TABLE public.shipments ENABLE ROW LEVEL SECURITY;

-- 【没有 INSERT / UPDATE / DELETE 策略,这是前提而不是遗漏】唯一写入口是
-- ship_order(DEFINER,module.sales.edit)。留一条客户端能直插的路,等于让人
-- 写出一张【没有对应流水、没有对应分录】的发货单 —— 而这张表存在的意义就是
-- 它与那两样说的是同一件事(建批次 IOD-1b / 建单 SO-2b 的同一条)。
CREATE POLICY "shipments select by permission" ON public.shipments
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.sales.view'::text));
