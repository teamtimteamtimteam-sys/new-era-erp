-- db/tables/currencies.sql
-- Currency reference table (finance foundation). No audit columns — reference
-- data, rarely touched. Widen the code CHECK when adding currencies.
-- USD is the base currency (is_base); journal amounts are stored in USD.
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
    code    text PRIMARY KEY CHECK (code IN ('USD','SGD')),  -- 加币种时同步放宽此 CHECK
    name    text NOT NULL,
    is_base boolean NOT NULL DEFAULT false
);

INSERT INTO public.currencies (code, name, is_base) VALUES
    ('USD', 'US Dollar', true),
    ('SGD', 'Singapore Dollar', false);

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
