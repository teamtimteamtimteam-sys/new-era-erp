-- db/tables/material_attachments.sql
-- Material attachments module — table + updated_at trigger + RLS + index.
-- Links a material to files stored in the private Storage bucket "material-attachments".
-- Conventions match existing tables (suppliers/customers/materials/tasks/...):
--   * soft delete via deleted_at
--   * audit fields created_by/updated_by default auth.uid(), created_at/updated_at default now()
--   * updated_at auto-bumped by the shared update_updated_at() function (do NOT redefine it)
--   * RLS: authenticated-only full access (matches suppliers' policy)
--
-- Differences from tasks.sql by design:
--   * NO code-generation trigger/sequence — attachments are child records of a material
--     and don't need a human-facing CODE (no MAT-/TASK- style identifier).
--
-- NOTE: This is a first-run script (plain CREATEs). Re-running requires dropping
-- the objects first. Run in the Supabase SQL Editor.

-- 1. Table
CREATE TABLE public.material_attachments (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Owning material. Plain REFERENCES (ON DELETE NO ACTION): materials are soft-deleted
    -- (deleted_at), never hard-DELETEd, so we deliberately avoid ON DELETE CASCADE — we do
    -- not want a future hard delete to silently drop attachment rows (and orphan Storage
    -- objects). NO ACTION also blocks an accidental hard delete of a referenced material.
    material_id   uuid NOT NULL REFERENCES public.materials (id),
    -- Path/key of the file inside the material-attachments bucket, e.g. "{material_id}/{uuid}-{filename}".
    storage_path  text NOT NULL,
    -- Original filename as uploaded, for display, e.g. "spec-sheet-2026.pdf".
    file_name     text NOT NULL,
    -- MIME type, e.g. "application/pdf".
    file_type     text,
    -- Size in bytes.
    file_size     bigint,
    -- Optional document category (e.g. spec-sheet, msds, coa, other). Plain nullable text for
    -- now — no CHECK constraint until categories are defined.
    doc_category  text,
    notes         text,
    created_by    uuid DEFAULT auth.uid(),
    updated_by    uuid DEFAULT auth.uid(),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz
);

-- 2. BEFORE UPDATE trigger -> reuse the existing shared update_updated_at() (do NOT redefine it)
CREATE TRIGGER trg_material_attachments_updated_at
    BEFORE UPDATE ON public.material_attachments
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();

-- 3. RLS: authenticated-only full access (matches suppliers' policy)
ALTER TABLE public.material_attachments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "authenticated full access on material_attachments"
    ON public.material_attachments
    AS PERMISSIVE
    FOR ALL
    TO authenticated
    USING (true)
    WITH CHECK (true);

-- 4. Index: we always query attachments by their owning material.
CREATE INDEX idx_material_attachments_material_id
    ON public.material_attachments (material_id);
