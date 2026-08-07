-- db/tables/purchase_order_lines.sql
-- 采购订单明细行:一行 = 一种料的下单量与估价。
--
-- estimated_amount_ccy = round(quantity × estimated_unit_price, 2);没给估价则为 0
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
    estimated_amount_ccy numeric NOT NULL DEFAULT 0,
    expected_assay       jsonb,
    notes                text,
    created_at           timestamptz NOT NULL DEFAULT now(),
    created_by           uuid DEFAULT auth.uid(),
    UNIQUE (purchase_order_id, line_no),
    -- ── FIN-26 追加(ALTER 加的列排在末尾)──────────────────────────────────
    -- 行价出处:记录,不从 expected_assay 推断。NULL = FIN-26 之前的行,不回填。
    price_source         text CHECK (price_source IN ('computed', 'manual')),
    price_provenance     jsonb,
    CONSTRAINT po_lines_provenance_pairing
        CHECK ((price_source = 'computed') = (price_provenance IS NOT NULL))
);

COMMENT ON COLUMN public.purchase_order_lines.price_source IS
    '行价的出处(FIN-26):computed = 估算按钮产出(必带 price_provenance);manual = 手填。NULL = FIN-26 之前的行,当时没记 —— 【不回填猜测】,界面画"未知"。不要从 expected_assay 推断。';
COMMENT ON COLUMN public.purchase_order_lines.price_provenance IS
    'computed 行的重导出依据(FIN-26):化验、逐金属行情与日期、汇率与 as-of、公式参数快照(公式可编辑,行上的 id 指不住当时的样子)。不能重导出的出处只是标签。';

COMMENT ON COLUMN public.purchase_order_lines.estimated_amount_ccy IS
    '行估算金额 = round(quantity × estimated_unit_price, 2),以【所属单据自己的币种】计 —— 不换算。FIN-28 前列名 estimated_amount_usd。';

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

-- cut 2b 字段级遮蔽:收回原始敏感列。表级 SELECT 授权【蕴含所有列】,
-- 所以必须先整表收回,再把非敏感列逐列授回。敏感列只能经 purchase_order_lines_masked 读取。
-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
REVOKE SELECT ON public.purchase_order_lines FROM authenticated, anon;
GRANT SELECT (id, purchase_order_id, line_no, material_id, quantity, unit, pricing_formula_id, expected_assay, notes, created_at, created_by, price_source)
    ON public.purchase_order_lines TO authenticated;
