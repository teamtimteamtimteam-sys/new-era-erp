-- db/tables/processing_outputs.sql
-- 加工产出腿:一行 = 某次加工产出了哪个批次多少量。allocated_cost_usd /
-- unit_cost_usd 由 allocate_processing_costs() 回填(分摊后的该腿成本与单位成本)。
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
    allocated_cost_usd numeric,
    unit_cost_usd      numeric
);

ALTER TABLE public.processing_outputs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on processing_outputs"
    ON public.processing_outputs AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);
