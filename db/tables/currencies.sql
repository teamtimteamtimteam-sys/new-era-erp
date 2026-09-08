-- db/tables/currencies.sql
-- Currency reference table (finance foundation). No audit columns — reference
-- data, rarely touched. Widen the code CHECK when adding currencies.
-- SGD is the base currency since FIN-0 (is_base); journal amounts are stored in SGD.
--
-- NOTE: introduced by db/migrations/2026-07-05-phase3-cut1-finance-foundation.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

-- ═══════════════════════════════════════════════════════════════════════════
-- 【安装种子 / INSTALL SEED —— 逐行跟踪线上,check_mirrors.py 逐行比对】
-- 界面里【没有任何地方写这张表】:app/finance/fx/* 只是读它来填下拉框,写的是 fx_rates。
-- 而且两个币种都是代码点名的常量 —— 'SGD' 出现 9 次、'USD' 出现 38 次,散落在
-- post_journal_entry、record_payment、payroll_periods 的默认值等 19 个镜像文件里。
-- 【本表是迁移专属的】db/scripts/ 下的数据脚本永远不许写它。
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE public.currencies (
    code    text PRIMARY KEY CHECK (code IN ('USD','SGD','CNY')),  -- 加币种时同步放宽此 CHECK
    name    text NOT NULL,
    is_base boolean NOT NULL DEFAULT false
);

-- FIN-0:本位币改为 SGD(新加坡公司,账本记新元;USD 成了外币,带汇率敞口)
INSERT INTO public.currencies (code, name, is_base) VALUES
    ('USD', 'US Dollar', false),
    ('SGD', 'Singapore Dollar', true),
    -- METAL-3:CNY 进来是为了【报价换算】,不是为了交易。SMM 以 CNY/吨发布,
    -- 而本函数族的报价基准是 USD,所以换算需要一条 CNY 的中间价。
    -- 【它不可交易,而这一点今天靠的是"没有路径把它送过去"】:界面上的币种下拉
    -- 全是写死的 <option>,getCurrencyCodes() 无人调用,重估按 journal_lines 走。
    -- 真要让它可交易,先看 lib/currencyMap.ts —— bankAccountFor 对未知币种回退
    -- '1010'(美元账户),那会把一笔 CNY 付款悄悄记到美元账上。
    ('CNY', 'Chinese Yuan', false);

ALTER TABLE public.currencies ENABLE ROW LEVEL SECURITY;
CREATE POLICY "currencies select by permission"
    ON public.currencies
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);

CREATE POLICY "currencies insert by permission"
    ON public.currencies
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "currencies update by permission"
    ON public.currencies
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit'::text)) WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "currencies delete by permission"
    ON public.currencies
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.finance.edit'::text));

-- ── SILENT-1(2026-09-08)· 被拒绝的写要抛,不许是一次"成功的空操作" ──────────
-- 本表的写策略是 `USING (p) WITH CHECK (p)`,两侧同一个谓词:不满足 p 的人卡在
-- USING 上,那一行根本没进语句的视野,WITH CHECK 永远没机会抛 —— 零行、不报错。
-- 这支语句级触发器零行也照样触发,抛 PERMISSION_DENIED|<码>。
-- 它由 row_security_active() 守着,所以属主 / SECURITY DEFINER 那些路一律放行。
-- 【它不动任何策略,所以读权限不可能因它变窄。】详见迁移文件抬头。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.currencies
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');
