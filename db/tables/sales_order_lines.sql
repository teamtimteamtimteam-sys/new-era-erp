-- db/tables/sales_order_lines.sql
-- SO-1:销售订单行 —— 指向物料,不指向批次。
--
-- NOTE: introduced by db/migrations/2026-08-13-so1-sales-order-document.sql.
-- First-run script (plain CREATEs).
--
-- 【履约(行 ↔ 批次,多对多)归预留/发货那一刀】今天加一个批次外键,等于替那一刀
-- 先做了一个几乎肯定错的一对一决定。

-- ═══ 2 · 单据行 ═════════════════════════════════════════════════════════════
CREATE TABLE public.sales_order_lines (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sales_order_id uuid NOT NULL REFERENCES public.sales_orders (id) ON DELETE CASCADE,
    line_no        integer NOT NULL CHECK (line_no >= 1),
    -- 【行指向物料,不指向批次】客户买的是"一种产品",不是"那一箱货"。
    -- 【履约(行 ↔ 批次,多对多)归预留/发货那一刀】—— 那时才需要回答
    -- "一行由哪几批货满足"。今天加一个批次外键,等于替那一刀先做了一个
    -- 一对一的决定,而它几乎肯定不是一对一。
    material_id    uuid NOT NULL REFERENCES public.materials (id),
    quantity       numeric NOT NULL CHECK (quantity > 0),
    unit_price     numeric NOT NULL CHECK (unit_price > 0),
    -- FIN-26 的形状:出处【记录,不推断】,而且成对出现或都不出现。
    price_source     text CHECK (price_source IN ('computed','manual')),
    price_provenance jsonb,
    notes          text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (sales_order_id, line_no),
    CONSTRAINT sales_order_lines_provenance_pairing CHECK (
        (price_source IS NULL AND price_provenance IS NULL)
        OR (price_source IS NOT NULL AND price_provenance IS NOT NULL)
    )
);

COMMENT ON TABLE public.sales_order_lines IS
    'SO-1:销售订单行。【指向物料,不指向批次】—— 客户买的是一种产品;"这一行由哪几批货满足"是【履约】,是多对多,归预留/发货那一刀(今天加一个批次外键就是替那一刀先做了一个几乎肯定错的一对一决定)。price_source/price_provenance 按 FIN-26 成对:出处记录、不事后推断,要么都有要么都没有(约束 sales_order_lines_provenance_pairing)。【承诺价不在这里】:pricing_term_commitments 的主体今天只有采购两列,销售侧要用它是一次形状决定(见本刀迁移抬头)。';

CREATE INDEX idx_sales_order_lines_order ON public.sales_order_lines (sales_order_id, line_no);

CREATE TRIGGER trg_sales_order_lines_confirmed_immutable
    BEFORE INSERT OR UPDATE OR DELETE ON public.sales_order_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_sales_order_line_confirmed_immutable();

ALTER TABLE public.sales_order_lines   ENABLE ROW LEVEL SECURITY;

CREATE POLICY "sales_order_lines select by permission" ON public.sales_order_lines
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.sales.view'::text));

CREATE POLICY "sales_order_lines insert by permission" ON public.sales_order_lines
    AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (has_permission('module.sales.edit'::text));

CREATE POLICY "sales_order_lines update by permission" ON public.sales_order_lines
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.sales.edit'::text)) WITH CHECK (has_permission('module.sales.edit'::text));

CREATE POLICY "sales_order_lines delete by permission" ON public.sales_order_lines
    AS PERMISSIVE FOR DELETE TO authenticated USING (has_permission('module.sales.edit'::text));
