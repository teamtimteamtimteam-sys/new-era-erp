-- db/tables/pricing_formula_metals.sql
-- 计价公式的逐金属可付比例(payable%,通常 60~80%,按交易对手谈定)。
-- 【不在本表里的金属完全不计价(payable 0)】—— 沉默即"这个金属不付钱";
-- calculate_metal_price 会把这类金属列进返回值的 unpaid_metals,与
-- skipped_metals(有条款但当天没有行情)区分开:一个是没谈价,一个是没行情。
-- 随公式级联删除(ON DELETE CASCADE):条款行脱离公式没有意义。
-- 金属集合与 metal_prices / inbound_batch_metals / output_batch_metals 共享,
-- 新增金属时要一起放宽所有这些 CHECK。
--
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut1a-pricing-engine.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.pricing_formula_metals (
    formula_id  uuid NOT NULL REFERENCES public.pricing_formulas (id) ON DELETE CASCADE,
    metal       text NOT NULL CHECK (metal IN ('ni','co','li','mn','cu','al','fe')),
    payable_pct numeric NOT NULL CHECK (payable_pct >= 0 AND payable_pct <= 100),
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid DEFAULT auth.uid(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid DEFAULT auth.uid(),
    PRIMARY KEY (formula_id, metal)
);

CREATE TRIGGER trg_pricing_formula_metals_updated_at
    BEFORE UPDATE ON public.pricing_formula_metals
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.pricing_formula_metals ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on pricing_formula_metals"
    ON public.pricing_formula_metals AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);
