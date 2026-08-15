-- db/tables/quote_lines.sql
-- SO-4a:报价行 —— 与 sales_order_lines 同形,转换时原样抄过去。
--
-- NOTE: introduced by db/migrations/2026-08-15-so4a-quotation-engine.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.quote_lines (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    quote_id    uuid NOT NULL REFERENCES public.quotes (id) ON DELETE CASCADE,
    line_no     integer NOT NULL CHECK (line_no >= 1),
    -- 【行指向物料,不指向批次】与订单行逐字同一条:客户买的是"一种产品"。
    -- 报价更是如此 —— 报的时候那批货可能还没生产出来。
    material_id uuid NOT NULL REFERENCES public.materials (id),
    quantity    numeric NOT NULL CHECK (quantity > 0),
    unit_price  numeric NOT NULL CHECK (unit_price > 0),
    -- FIN-26 的形状,与订单行【逐字同一条约束】:出处记录、不事后推断,
    -- 要么都有要么都没有。转换时这两列【原样抄】进订单行 —— 一次转换不该
    -- 把"这个价是算出来的"变成"这个价是手敲的"。
    price_source     text CHECK (price_source IN ('computed','manual')),
    price_provenance jsonb,
    notes       text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (quote_id, line_no),
    CONSTRAINT quote_lines_provenance_pairing CHECK (
        (price_source IS NULL AND price_provenance IS NULL)
        OR (price_source IS NOT NULL AND price_provenance IS NOT NULL)
    )
);

COMMENT ON TABLE public.quote_lines IS
    'SO-4a:报价行 —— 与 sales_order_lines 同形(指向物料不指向批次;price_source/price_provenance 按 FIN-26 成对)。转换时这几列【原样抄】进订单行:一次转换不该把"这个价是算出来的"改写成"手敲的",也不该重算任何一个数 —— 那等于系统替人重新谈了一次。【draft/issued 的行可以自由增删改】(报价就是谈判过程),但父报价一旦 converted 就整个冻住。';

CREATE INDEX idx_quote_lines_quote ON public.quote_lines (quote_id, line_no);

CREATE TRIGGER trg_quote_lines_converted_immutable
    BEFORE INSERT OR UPDATE OR DELETE ON public.quote_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_quote_line_converted_immutable();

-- 【改一行明细,把父报价的 updated_at 顶上去】"签发之后又改过"那个信号比的是
-- quotes.updated_at 与最新一版 issued_at。改行而表头不动,信号就会对最常见的
-- 一种改动视而不见 —— 一个看漏了的信号比没有信号更坏。
CREATE TRIGGER trg_quote_lines_touch_parent
    AFTER INSERT OR UPDATE OR DELETE ON public.quote_lines
    FOR EACH ROW EXECUTE FUNCTION public.trg_quote_line_touches_parent();

ALTER TABLE public.quote_lines ENABLE ROW LEVEL SECURITY;

CREATE POLICY "quote_lines select by permission" ON public.quote_lines
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.sales.view'::text));
CREATE POLICY "quote_lines insert by permission" ON public.quote_lines
    AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (has_permission('module.sales.edit'::text));
CREATE POLICY "quote_lines update by permission" ON public.quote_lines
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.sales.edit'::text)) WITH CHECK (has_permission('module.sales.edit'::text));
CREATE POLICY "quote_lines delete by permission" ON public.quote_lines
    AS PERMISSIVE FOR DELETE TO authenticated USING (has_permission('module.sales.edit'::text));
