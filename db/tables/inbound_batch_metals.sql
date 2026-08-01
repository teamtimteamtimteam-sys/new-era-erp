-- db/tables/inbound_batch_metals.sql
-- Inbound batch metal content (assay results) — table + updated_at trigger + RLS.
-- One row per (inbound batch, metal); content_pct is the assayed percentage.
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
-- NOTE: introduced by db/migrations/2026-07-02-phase1-cut2-cost-metal-foundation.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

-- 1. Table
CREATE TABLE public.inbound_batch_metals (
    inbound_batch_id uuid    NOT NULL REFERENCES public.inbound_batches (id) ON DELETE CASCADE,
    metal            text    NOT NULL CHECK (metal IN ('ni','co','li','mn','cu','al','fe')),
    content_pct      numeric NOT NULL CHECK (content_pct >= 0 AND content_pct <= 100),
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid,
    PRIMARY KEY (inbound_batch_id, metal)
);

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
