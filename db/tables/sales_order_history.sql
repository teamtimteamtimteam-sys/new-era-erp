-- db/tables/sales_order_history.sql
-- SO-1:销售订单变更留痕,只增不改(形状取自 purchase_order_history)。
--
-- NOTE: introduced by db/migrations/2026-08-13-so1-sales-order-document.sql.
-- First-run script (plain CREATEs).

-- ═══ 3 · 历史(只增不改)════════════════════════════════════════════════════
CREATE TABLE public.sales_order_history (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sales_order_id uuid NOT NULL REFERENCES public.sales_orders (id),
    -- SO-2:'reserved' / 'released' —— 预留与释放【留在订单的历史里】,而不是
    -- 只留在库存流水里。看订单的人问的是"这张单许出去了什么、什么时候放回去的",
    -- 那个问题的答案不该要求他先去翻库存台账。
    change_type    text NOT NULL CHECK (change_type IN
                   ('created','confirmed','closed','cancelled','line_added','line_changed','line_removed','issued',
                    'reserved','released')),
    detail         text,
    changed_at     timestamptz NOT NULL DEFAULT now(),
    changed_by     uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.sales_order_history IS
    'SO-1:销售订单的变更留痕,只增不改(形状取自 purchase_order_history)。守卫【自己报名】抛 SO_HISTORY_IMMUTABLE,不靠外键顺带挡(FIN-31)。';

CREATE INDEX idx_sales_order_history_order ON public.sales_order_history (sales_order_id, changed_at DESC);

CREATE TRIGGER trg_sales_order_history_append_only
    BEFORE UPDATE OR DELETE ON public.sales_order_history
    FOR EACH ROW EXECUTE FUNCTION public.guard_sales_order_history_append_only();

ALTER TABLE public.sales_order_history ENABLE ROW LEVEL SECURITY;

-- 留痕与签发档【没有 INSERT 策略】:唯一写入口是属主权限的函数
-- (同 approval_log / notifications:留痕不该有第二个写法)。
CREATE POLICY "sales_order_history select by permission" ON public.sales_order_history
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.sales.view'::text));
