-- db/tables/sales_orders.sql
-- SO-1:销售订单单据头。
--
-- NOTE: introduced by db/migrations/2026-08-13-so1-sales-order-document.sql.
-- First-run script (plain CREATEs).
--
-- 【与 sales_records 是两件事】订单是"答应卖给某人",销售记录是"已经卖了"。
-- customer_id NOT NULL —— 订单的主语就是那个客户;无客户的销售仍走直接销售那条路。
-- 【履约/发货状态归发货那一刀】,加在这里之前先读 status 那一列的注释。
-- 【权限 module.sales.*】(SO-1-fu)销售是一个真模块,订单先于财务 ——
-- 财务拥有的是事后那条链(sales_records / invoices / AR)。三条理由写在
-- db/migrations/2026-08-13-so1-fu1-sales-module-permission.sql。

-- ═══ 1 · 单据头 ═════════════════════════════════════════════════════════════
CREATE TABLE public.sales_orders (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code          text NOT NULL UNIQUE,
    -- 【NOT NULL,与 sales_records 刻意不同】一条销售【记录】可以没有客户
    -- (货先卖了、客户还没登记,SAL-C 事后归属);但一张【订单】是"答应卖给某人"——
    -- 没有那个人,这张单据就没有主语。无客户的那条路仍然走直接销售,不走订单。
    customer_id   uuid NOT NULL REFERENCES public.customers (id),
    -- 【物理事件日,永不默认】(AGENTS.md 的日期规矩、FIN-32 同形):
    -- 补一个 CURRENT_DATE 会让"留空"比"填对"更容易通过。
    order_date    date NOT NULL,
    status        text NOT NULL DEFAULT 'draft'
                  CHECK (status IN ('draft','confirmed','closed','cancelled')),
    currency      text NOT NULL REFERENCES public.currencies (code),
    fx_rate       numeric NOT NULL CHECK (fx_rate > 0),
    notes         text,
    terms_text    text,
    confirmed_at  timestamptz,
    closed_at     timestamptz,
    cancelled_at  timestamptz,
    cancel_reason text,
    deleted_at    timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid DEFAULT auth.uid(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    uuid,
    -- 作废必须给理由(与采购单同形):一张没有理由的作废单,三个月后没有人
    -- 说得出它为什么作废。
    CONSTRAINT sales_orders_cancel_reason_required
        CHECK (status <> 'cancelled' OR cancel_reason IS NOT NULL)
);

COMMENT ON TABLE public.sales_orders IS
    'SO-1:销售订单单据头。【与 sales_records 是两件事】:订单是"答应卖给某人",销售记录是"已经卖了"(record_output_sale 同事务扣库存、记收入与 COGS)。customer_id NOT NULL —— 订单的主语就是那个客户;无客户的销售仍走直接销售那条路(SAL-C 的事后归属只对销售记录成立)。状态机今天只有 draft/confirmed/closed/cancelled:【履约/发货那几个状态归发货那一刀】,加在这里之前先读那一刀的注释。确认即冻结商业字段(guard_sales_order_confirmed_immutable),改单归 SO-1b。';

COMMENT ON COLUMN public.sales_orders.status IS
    'SO-1:单据状态。draft 可编辑;confirmed 之后商业字段冻结(按名拒 SO_CONFIRMED_IMMUTABLE|<字段>);closed 是这张单走完了;cancelled 必须带理由。【发货/履约状态不在这里】—— partially_shipped / shipped 之类要等发货那一刀,而那一刀要一并回答"部分发货怎么算"。在此之前不加空状态:一个没有写入者的状态会被读成"从来没发生过",而不是"系统还不知道"(与 stock_status 拒绝 committed 同一条)。';

COMMENT ON COLUMN public.sales_orders.fx_rate IS
    'SO-1:本单据成立时的折本位币汇率。【没有默认值,这是有意的 —— FIN-35】:汇率的默认值只能是一个假设,而假设出来的 1:1 在非本位币单据上永远是错的,还看起来完全正常。';

CREATE INDEX idx_sales_orders_customer ON public.sales_orders (customer_id, order_date DESC);

CREATE INDEX idx_sales_orders_status   ON public.sales_orders (status);

CREATE TRIGGER trg_sales_orders_confirmed_immutable
    BEFORE UPDATE ON public.sales_orders
    FOR EACH ROW EXECUTE FUNCTION public.guard_sales_order_confirmed_immutable();

-- ═══ 9 · RLS —— 跟着 sales_records 自己的那一对码 ═══════════════════════════
ALTER TABLE public.sales_orders        ENABLE ROW LEVEL SECURITY;

CREATE POLICY "sales_orders select by permission" ON public.sales_orders
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.sales.view'::text));

-- 【没有 INSERT 策略,这是刻意的】(SO-2b,2026-08-14)
-- 建单只有一扇门:create_sales_order —— 它是 SECURITY DEFINER,同一个事务里写
-- 单头 + 单行 + 'created' 留痕。撤掉这条策略是那扇门的【前提】,不是一次顺手
-- 收紧:留着侧门,下一个人照样可以插一张【没有留痕】的单,而那正是这一刀要
-- 关掉的缺陷 —— SO-1 的建单就是三条客户端直插,第三条被 RLS 拒且错误被丢弃,
-- 于是线上 SO-2026-0001 从来没有 created 那一行。形状取自建批次(IOD-1b)。

CREATE POLICY "sales_orders update by permission" ON public.sales_orders
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.sales.edit'::text)) WITH CHECK (has_permission('module.sales.edit'::text));
