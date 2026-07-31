-- db/tables/processing_inputs.sql
-- 加工投料腿:一行 = 某次加工从某个进料批次消耗了多少。remaining_qty 的扣减由
-- commit_processing_run() 完成(本表无触发器)。ON DELETE RESTRICT:加工只能整体
-- 冲销,不允许顺手硬删投料史。
--
-- NOTE: 本表早于"迁移 + 镜像"约定(建库初期直接在 Supabase SQL Editor 建的),
-- 一直没有镜像文件;2026-07-31 镜像漂移审计后【按线上目录重建】了本文件。
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.processing_inputs (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id            uuid NOT NULL REFERENCES public.processing_runs (id) ON DELETE RESTRICT,
    inbound_batch_id  uuid NOT NULL REFERENCES public.inbound_batches (id),
    quantity_consumed numeric NOT NULL,
    created_at        timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.processing_inputs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on processing_inputs"
    ON public.processing_inputs AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);
