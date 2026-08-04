-- db/tables/processing_outputs.sql
-- 加工产出腿:一行 = 某次加工产出了哪个批次多少量。allocated_cost_base /
-- unit_cost_base 由 allocate_processing_costs() 回填(分摊后的该腿成本与单位成本)。
-- ON DELETE RESTRICT:同 processing_inputs,产出史不允许硬删。
--
-- NOTE: 本表早于"迁移 + 镜像"约定(建库初期直接在 Supabase SQL Editor 建的),
-- 一直没有镜像文件;2026-07-31 镜像漂移审计后【按线上目录重建】了本文件。
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.processing_outputs (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id             uuid NOT NULL REFERENCES public.processing_runs (id) ON DELETE RESTRICT,
    output_batch_id    uuid NOT NULL REFERENCES public.output_batches (id),
    quantity_produced  numeric NOT NULL,
    created_at         timestamptz NOT NULL DEFAULT now(),
    allocated_cost_base numeric,
    unit_cost_base      numeric
);

ALTER TABLE public.processing_outputs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "processing_outputs select by permission"
    ON public.processing_outputs
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

CREATE POLICY "processing_outputs insert by permission"
    ON public.processing_outputs
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.processing.edit'::text));

CREATE POLICY "processing_outputs update by permission"
    ON public.processing_outputs
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.processing.edit'::text)) WITH CHECK (has_permission('module.processing.edit'::text));

CREATE POLICY "processing_outputs delete by permission"
    ON public.processing_outputs
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.processing.edit'::text));

-- cut 2b 字段级遮蔽:收回原始敏感列。表级 SELECT 授权【蕴含所有列】,
-- 所以必须先整表收回,再把非敏感列逐列授回。敏感列只能经 processing_outputs_masked 读取。
-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
REVOKE SELECT ON public.processing_outputs FROM authenticated, anon;
GRANT SELECT (id, run_id, output_batch_id, quantity_produced, created_at)
    ON public.processing_outputs TO authenticated;

-- FIN-1a:改名列的注释(说明写在数据库里,重建出来的库也带着)
COMMENT ON COLUMN public.processing_outputs.allocated_cost_base IS '本位币分摊成本(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 allocated_cost_usd)。';
COMMENT ON COLUMN public.processing_outputs.unit_cost_base IS '本位币单位成本(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 unit_cost_usd)。';
