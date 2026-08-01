-- db/tables/output_batch_metals.sql
-- Output batch metal content (assay results) — table + updated_at trigger + RLS.
-- One row per (output batch, metal); content_pct is the assayed percentage.
-- Mirror of inbound_batch_metals on the output side.
-- Conventions match existing tables:
--   * audit fields created_by/updated_by, created_at/updated_at default now()
--   * updated_at auto-bumped by the shared update_updated_at() function (do NOT redefine it)
--   * RLS: authenticated-only full access
--
-- Differences by design:
--   * Attribute rows, NOT audit legs: ON DELETE CASCADE from the batch, and hard
--     delete is allowed. Batch soft-delete (deleted_at) covers history.
--   * Composite PRIMARY KEY (output_batch_id, metal) — no surrogate id, no soft delete.
--   * Shared metal set with inbound_batch_metals / metal_prices; when adding a metal,
--     widen ALL those CHECKs together.
--
-- NOTE: introduced by db/migrations/2026-07-02-phase1-cut2-cost-metal-foundation.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

-- 1. Table
CREATE TABLE public.output_batch_metals (
    output_batch_id uuid    NOT NULL REFERENCES public.output_batches (id) ON DELETE CASCADE,
    metal           text    NOT NULL CHECK (metal IN ('ni','co','li','mn','cu','al','fe')),
    content_pct     numeric NOT NULL CHECK (content_pct >= 0 AND content_pct <= 100),
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid,
    PRIMARY KEY (output_batch_id, metal)
);

-- 2. BEFORE UPDATE trigger -> reuse the existing shared update_updated_at() (do NOT redefine it)
CREATE TRIGGER trg_output_batch_metals_updated_at
    BEFORE UPDATE ON public.output_batch_metals
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();

-- 3. RLS: authenticated-only full access
ALTER TABLE public.output_batch_metals ENABLE ROW LEVEL SECURITY;

CREATE POLICY "output_batch_metals select by permission"
    ON public.output_batch_metals
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.output.view'::text));

CREATE POLICY "output_batch_metals insert by permission"
    ON public.output_batch_metals
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.output.edit'::text));

CREATE POLICY "output_batch_metals update by permission"
    ON public.output_batch_metals
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.output.edit'::text)) WITH CHECK (has_permission('module.output.edit'::text));

CREATE POLICY "output_batch_metals delete by permission"
    ON public.output_batch_metals
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.output.edit'::text));
