-- db/tables/inbound_batch_metals.sql
-- Inbound batch metal content — table + updated_at trigger + RLS.
-- One row per (inbound batch, metal); content_pct is the current-best percentage.
-- Conventions match existing tables:
--   * audit fields created_by/updated_by, created_at/updated_at default now()
--   * updated_at auto-bumped by the shared update_updated_at() function (do NOT redefine it)
--   * RLS: authenticated-only full access
--
-- Differences by design:
--   * Attribute rows, NOT audit legs: ON DELETE CASCADE from the batch, and hard
--     delete is allowed. Batch soft-delete (deleted_at) covers history.
--   * Composite PRIMARY KEY (inbound_batch_id, metal) — no surrogate id, no soft delete.
--   * Shared metal set with output_batch_metals / metal_prices; when adding a metal,
--     widen ALL those CHECKs together.
--
-- PROC-1(2026-08-12):含量带出处 —— content_source('assay'/'manual')+
-- source_assay_id。出处是【记录】的,绝不从"有没有化验"推断(FIN-26)。
-- 既有行保持 NULL = 出处未知(两个写入口都存在已久,哪行出自哪口不可证明;
-- 生产重建不带这些行);新行必填,由 NOT VALID 约束强制(FIN-32 的形状)。
--
-- NOTE: introduced by db/migrations/2026-07-02-phase1-cut2-cost-metal-foundation.sql;
-- provenance columns by db/migrations/2026-08-12-proc1-output-assays.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

-- 1. Table
CREATE TABLE public.inbound_batch_metals (
    inbound_batch_id uuid    NOT NULL REFERENCES public.inbound_batches (id) ON DELETE CASCADE,
    metal            text    NOT NULL REFERENCES public.substances (code),
    content_pct      numeric NOT NULL CHECK (content_pct >= 0 AND content_pct <= 100),
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid,
    -- PROC-1(ALTER 加列,留在末尾)
    content_source  text CHECK (content_source IN ('assay', 'manual')),
    source_assay_id uuid REFERENCES public.assay_results (id),
    PRIMARY KEY (inbound_batch_id, metal),
    CONSTRAINT inbound_batch_metals_source_consistent CHECK (
        (content_source = 'assay'  AND source_assay_id IS NOT NULL)
     OR (content_source = 'manual' AND source_assay_id IS NULL)
     OR (content_source IS NULL    AND source_assay_id IS NULL))
);

-- 新行必填、老行放过(FIN-32 的形状):19 行既有进料含量【出处未知】,不回填
ALTER TABLE public.inbound_batch_metals
    ADD CONSTRAINT inbound_batch_metals_content_source_required
    CHECK (content_source IS NOT NULL) NOT VALID;

COMMENT ON COLUMN public.inbound_batch_metals.content_source IS
    'PROC-1:这行含量【是谁说的】—— assay(实验室,source_assay_id 指向那份单据)或 manual(人填的)。出处是【记录】的,绝不从"有没有化验"推断(FIN-26)。NULL = PROC-1 之前写入,出处未知 —— 不回填,界面读作「未知」;新行由 NOT VALID 约束强制必填。';

-- 2. BEFORE UPDATE trigger -> reuse the existing shared update_updated_at() (do NOT redefine it)
CREATE TRIGGER trg_inbound_batch_metals_updated_at
    BEFORE UPDATE ON public.inbound_batch_metals
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();

-- 3. RLS: authenticated-only full access
ALTER TABLE public.inbound_batch_metals ENABLE ROW LEVEL SECURITY;

CREATE POLICY "inbound_batch_metals select by permission"
    ON public.inbound_batch_metals
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inbound.view'::text));

CREATE POLICY "inbound_batch_metals insert by permission"
    ON public.inbound_batch_metals
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.inbound.edit'::text));

CREATE POLICY "inbound_batch_metals update by permission"
    ON public.inbound_batch_metals
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.inbound.edit'::text)) WITH CHECK (has_permission('module.inbound.edit'::text));

CREATE POLICY "inbound_batch_metals delete by permission"
    ON public.inbound_batch_metals
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.inbound.edit'::text));
