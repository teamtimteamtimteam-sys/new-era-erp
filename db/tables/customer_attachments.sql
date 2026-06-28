-- db/tables/customer_attachments.sql
-- Customer attachments module — table + updated_at trigger + RLS + index.
-- Links a customer to files stored in the private Storage bucket "customer-attachments".
-- Conventions match existing tables (suppliers/customers/tasks/...):
--   * soft delete via deleted_at
--   * audit fields created_by/updated_by default auth.uid(), created_at/updated_at default now()
--   * updated_at auto-bumped by the shared update_updated_at() function (do NOT redefine it)
--   * RLS: authenticated-only full access (matches suppliers' policy)
--
-- Differences from tasks.sql by design:
--   * NO code-generation trigger/sequence — attachments are child records of a customer
--     and don't need a human-facing CODE (no CUS-/TASK- style identifier).
--
-- NOTE: This is a first-run script (plain CREATEs). Re-running requires dropping
-- the objects first. Run in the Supabase SQL Editor.

-- 1. Table
CREATE TABLE public.customer_attachments (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Owning customer. Plain REFERENCES (ON DELETE NO ACTION): customers are soft-deleted
    -- (deleted_at), never hard-DELETEd, so we deliberately avoid ON DELETE CASCADE — we do
    -- not want a future hard delete to silently drop attachment rows (and orphan Storage
    -- objects). NO ACTION also blocks an accidental hard delete of a referenced customer.
    customer_id   uuid NOT NULL REFERENCES public.customers (id),
    -- Path/key of the file inside the customer-attachments bucket, e.g. "{customer_id}/{uuid}-{filename}".
    storage_path  text NOT NULL,
    -- Original filename as uploaded, for display, e.g. "waste-permit-2026.pdf".
    file_name     text NOT NULL,
    -- MIME type, e.g. "application/pdf".
    file_type     text,
    -- Size in bytes.
    file_size     bigint,
    -- Optional document category (e.g. hazardous-waste-permit, import-license, basel-document,
    -- contract, other). Plain nullable text for now — no CHECK constraint until categories are defined.
    doc_category  text,
    notes         text,
    created_by    uuid DEFAULT auth.uid(),
    updated_by    uuid DEFAULT auth.uid(),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz
);

-- 2. BEFORE UPDATE trigger -> reuse the existing shared update_updated_at() (do NOT redefine it)
CREATE TRIGGER trg_customer_attachments_updated_at
    BEFORE UPDATE ON public.customer_attachments
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();

-- 3. RLS: authenticated-only full access (matches suppliers' policy)
ALTER TABLE public.customer_attachments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "authenticated full access on customer_attachments"
    ON public.customer_attachments
    AS PERMISSIVE
    FOR ALL
    TO authenticated
    USING (true)
    WITH CHECK (true);

-- 4. Index: we always query attachments by their owning customer.
CREATE INDEX idx_customer_attachments_customer_id
    ON public.customer_attachments (customer_id);
