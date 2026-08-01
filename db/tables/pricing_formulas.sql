-- db/tables/pricing_formulas.sql
-- 计价公式:一张公式 = 一个交易对手谈定的商务条款存档。
--   price = Σ(quantity × content% × payable% × market price) − treatment charge − flat discount
-- payable%(逐金属)存在 pricing_formula_metals;这里放公式级参数。
-- price_basis:'spot' 取参考日之前最近一条行情;'average' 取近 average_days 天均值
-- (故 average 必须给天数,CHECK 强制)。
-- 交易对手绑定(supplier_id / customer_id,至多一个)只是后续切次"默认带出哪张公式"
-- 的便利,不是限制 —— 任何公式都能套用到任何一笔交易。
-- 无缝编号 'PF-YYYY-NNNN':BEFORE INSERT 触发器调 next_pricing_formula_code(),
-- 咨询锁串行化取号(同 JE/收付款/开支/对账单),回滚即释放号码。
--
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut1a-pricing-engine.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.pricing_formulas (
    id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                        text NOT NULL UNIQUE,  -- gapless 'PF-YYYY-NNNN'
    name                        text NOT NULL,
    direction                   text NOT NULL DEFAULT 'both'
                                CHECK (direction IN ('purchase','sale','both')),
    price_basis                 text NOT NULL DEFAULT 'spot'
                                CHECK (price_basis IN ('spot','average')),
    average_days                integer CHECK (average_days IS NULL OR average_days BETWEEN 1 AND 365),
    treatment_charge_usd_per_tonne numeric NOT NULL DEFAULT 0
                                CHECK (treatment_charge_usd_per_tonne >= 0),
    flat_discount_pct           numeric NOT NULL DEFAULT 0
                                CHECK (flat_discount_pct >= 0 AND flat_discount_pct <= 100),
    supplier_id                 uuid REFERENCES public.suppliers (id),
    customer_id                 uuid REFERENCES public.customers (id),
    notes                       text,
    is_active                   boolean NOT NULL DEFAULT true,
    deleted_at                  timestamptz,
    created_at                  timestamptz NOT NULL DEFAULT now(),
    created_by                  uuid DEFAULT auth.uid(),
    updated_at                  timestamptz NOT NULL DEFAULT now(),
    updated_by                  uuid DEFAULT auth.uid(),
    CONSTRAINT pricing_formulas_average_days_required CHECK (
        price_basis <> 'average' OR average_days IS NOT NULL
    ),
    CONSTRAINT pricing_formulas_one_counterparty CHECK (
        num_nonnulls(supplier_id, customer_id) <= 1
    )
);

CREATE INDEX idx_pricing_formulas_supplier ON public.pricing_formulas (supplier_id);
CREATE INDEX idx_pricing_formulas_customer ON public.pricing_formulas (customer_id);

CREATE OR REPLACE FUNCTION public.assign_pricing_formula_code()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := next_pricing_formula_code(CURRENT_DATE);
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_pricing_formulas_code
    BEFORE INSERT ON public.pricing_formulas
    FOR EACH ROW EXECUTE FUNCTION public.assign_pricing_formula_code();

CREATE TRIGGER trg_pricing_formulas_updated_at
    BEFORE UPDATE ON public.pricing_formulas
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.pricing_formulas ENABLE ROW LEVEL SECURITY;
CREATE POLICY "pricing_formulas select by permission"
    ON public.pricing_formulas
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.pricing.view'::text));

CREATE POLICY "pricing_formulas insert by permission"
    ON public.pricing_formulas
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.pricing.edit'::text));

CREATE POLICY "pricing_formulas update by permission"
    ON public.pricing_formulas
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.pricing.edit'::text)) WITH CHECK (has_permission('module.pricing.edit'::text));

CREATE POLICY "pricing_formulas delete by permission"
    ON public.pricing_formulas
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.pricing.edit'::text));

-- cut 2b 字段级遮蔽:收回原始敏感列。表级 SELECT 授权【蕴含所有列】,
-- 所以必须先整表收回,再把非敏感列逐列授回。敏感列只能经 pricing_formulas_masked 读取。
-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
REVOKE SELECT ON public.pricing_formulas FROM authenticated, anon;
GRANT SELECT (id, code, name, direction, price_basis, average_days, supplier_id, customer_id, notes, is_active, deleted_at, created_at, created_by, updated_at, updated_by)
    ON public.pricing_formulas TO authenticated;
