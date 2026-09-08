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
    metal       text NOT NULL REFERENCES public.substances (code),
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

-- FIN-27:金属条款的编辑同样进 pricing_formula_history。【为什么它也要】界面表达
-- "这个金属不再计价"的方式是 DELETE 掉那一行(actions.ts 的 clears),而本表没有
-- 软删 —— 只记表头的历史,对最激烈的一种编辑一言不发,而沉默读起来正好等于
-- "什么都没改"。函数在 db/functions/log_pricing_formula_metal_change.sql。
CREATE TRIGGER trg_pricing_formula_metals_history
    AFTER INSERT OR UPDATE OR DELETE ON public.pricing_formula_metals
    FOR EACH ROW EXECUTE FUNCTION public.log_pricing_formula_metal_change();

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

-- ── SILENT-1(2026-09-08)· 被拒绝的写要抛,不许是一次"成功的空操作" ──────────
-- 本表的写策略是 `USING (p) WITH CHECK (p)`,两侧同一个谓词:不满足 p 的人卡在
-- USING 上,那一行根本没进语句的视野,WITH CHECK 永远没机会抛 —— 零行、不报错。
-- 这支语句级触发器零行也照样触发,抛 PERMISSION_DENIED|<码>。
-- 它由 row_security_active() 守着,所以属主 / SECURITY DEFINER 那些路一律放行。
-- 【它不动任何策略,所以读权限不可能因它变窄。】详见迁移文件抬头。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.pricing_formula_metals
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.pricing.edit');
