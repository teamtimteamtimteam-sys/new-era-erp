-- db/tables/purchase_order_lines.sql
-- 采购订单明细行:一行 = 一种料的下单量与估价。
--
-- estimated_amount_usd = round(quantity × estimated_unit_price, 2);没给估价则为 0
-- (公式定价的料下单时常常没有单价 —— 那不是错误,是常态)。
-- pricing_formula_id 记的是【谈定用哪张公式结算】,到货计价时照它算;可空。
--
-- expected_assay:谈定/预期的金属含量 [{metal, content_pct}]。这是【预期值】——
-- 最终计价一律以【到货批次的实际化验值】(inbound_batch_metals)为准。两者对不上
-- 是正常的商务现实,本表不做任何强制,也【不参与】任何金额计算。
--
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut4a-purchase-orders.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.purchase_order_lines (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    purchase_order_id    uuid NOT NULL REFERENCES public.purchase_orders (id) ON DELETE CASCADE,
    line_no              integer NOT NULL,
    material_id          uuid NOT NULL REFERENCES public.materials (id),
    quantity             numeric NOT NULL CHECK (quantity > 0),
    unit                 text NOT NULL DEFAULT 'kg',
    pricing_formula_id   uuid REFERENCES public.pricing_formulas (id),
    estimated_unit_price numeric CHECK (estimated_unit_price IS NULL OR estimated_unit_price >= 0),
    estimated_amount_usd numeric NOT NULL DEFAULT 0,
    expected_assay       jsonb,
    notes                text,
    created_at           timestamptz NOT NULL DEFAULT now(),
    created_by           uuid DEFAULT auth.uid(),
    UNIQUE (purchase_order_id, line_no)
);

CREATE INDEX idx_purchase_order_lines_po ON public.purchase_order_lines (purchase_order_id);

ALTER TABLE public.purchase_order_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "purchase_order_lines select by permission"
    ON public.purchase_order_lines
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.purchasing.view'::text));

CREATE POLICY "purchase_order_lines insert by permission"
    ON public.purchase_order_lines
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.purchasing.edit'::text));

CREATE POLICY "purchase_order_lines update by permission"
    ON public.purchase_order_lines
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.purchasing.edit'::text)) WITH CHECK (has_permission('module.purchasing.edit'::text));

CREATE POLICY "purchase_order_lines delete by permission"
    ON public.purchase_order_lines
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.purchasing.edit'::text));
