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
CREATE POLICY "pricing_formula_metals select by permission"
    ON public.pricing_formula_metals
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.pricing.view'::text));

CREATE POLICY "pricing_formula_metals insert by permission"
    ON public.pricing_formula_metals
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.pricing.edit'::text));

CREATE POLICY "pricing_formula_metals update by permission"
    ON public.pricing_formula_metals
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.pricing.edit'::text)) WITH CHECK (has_permission('module.pricing.edit'::text));

CREATE POLICY "pricing_formula_metals delete by permission"
    ON public.pricing_formula_metals
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.pricing.edit'::text));

-- cut 2b 字段级遮蔽:收回原始敏感列。表级 SELECT 授权【蕴含所有列】,
-- 所以必须先整表收回,再把非敏感列逐列授回。敏感列只能经 pricing_formula_metals_masked 读取。
-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
REVOKE SELECT ON public.pricing_formula_metals FROM authenticated, anon;
GRANT SELECT (formula_id, metal, created_at, created_by, updated_at, updated_by)
    ON public.pricing_formula_metals TO authenticated;
