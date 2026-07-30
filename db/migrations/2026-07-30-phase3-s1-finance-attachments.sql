-- db/migrations/2026-07-30-phase3-s1-finance-attachments.sql
-- Phase 3 supplement 1: finance document attachments.
-- One table (finance_attachments) serving three parents — AR documents (sales_records),
-- AP documents (priced inbound_batches) and payments — plus a private Storage bucket
-- 'finance-attachments', replicating the supplier-attachments pattern exactly
-- (private bucket, 4 storage.objects policies for the authenticated role; file-type
-- whitelist PDF/images/Word/Excel enforced in app code, not at the bucket level —
-- same as the existing attachment buckets).
--
-- XOR: exactly ONE of sales_record_id / inbound_batch_id / payment_id is non-null,
-- expressed as num_nonnulls(...) = 1. When the expense module lands (supplement 2),
-- expense_id joins this XOR — the num_nonnulls form makes that a one-line change.

BEGIN;

-- 1. Private Storage bucket (no bucket-level size/MIME limits — same as
--    supplier-attachments; the app whitelists PDF/PNG/JPEG/Word/Excel).
INSERT INTO storage.buckets (id, name, public)
VALUES ('finance-attachments', 'finance-attachments', false);

-- 2. storage.objects policies — same shape as the supplier-attachments quartet.
CREATE POLICY "authenticated read finance-attachments"
    ON storage.objects FOR SELECT TO authenticated
    USING (bucket_id = 'finance-attachments');

CREATE POLICY "authenticated upload finance-attachments"
    ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'finance-attachments');

CREATE POLICY "authenticated update finance-attachments"
    ON storage.objects FOR UPDATE TO authenticated
    USING (bucket_id = 'finance-attachments');

CREATE POLICY "authenticated delete finance-attachments"
    ON storage.objects FOR DELETE TO authenticated
    USING (bucket_id = 'finance-attachments');

-- 3. Table
CREATE TABLE public.finance_attachments (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Parent document (XOR). Plain REFERENCES (ON DELETE NO ACTION): finance rows are
    -- immutable/soft-deleted, never hard-DELETEd — an accidental hard delete of a
    -- referenced parent is blocked rather than silently dropping attachment rows.
    sales_record_id  uuid REFERENCES public.sales_records (id),
    inbound_batch_id uuid REFERENCES public.inbound_batches (id),
    payment_id       uuid REFERENCES public.payments (id),
    -- expense_id joins this list in supplement 2 (num_nonnulls(..., expense_id) = 1).
    CONSTRAINT finance_attachments_one_parent
        CHECK (num_nonnulls(sales_record_id, inbound_batch_id, payment_id) = 1),
    -- Original filename as uploaded, for display.
    file_name        text NOT NULL,
    -- Path/key inside the finance-attachments bucket, e.g. "{parent_id}/{uuid}-{filename}".
    file_path        text NOT NULL,
    file_size        bigint,
    mime_type        text,
    doc_type         text DEFAULT 'other'
        CHECK (doc_type IN ('invoice','contract','receipt','bank_slip','weighbridge','other')),
    notes            text,
    deleted_at       timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid DEFAULT auth.uid(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid
);

-- 4. BEFORE UPDATE trigger -> reuse the existing shared update_updated_at() (do NOT redefine it)
CREATE TRIGGER trg_finance_attachments_updated_at
    BEFORE UPDATE ON public.finance_attachments
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();

-- 5. RLS: authenticated-only full access (matches supplier_attachments' policy)
ALTER TABLE public.finance_attachments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "authenticated full access on finance_attachments"
    ON public.finance_attachments
    AS PERMISSIVE
    FOR ALL
    TO authenticated
    USING (true)
    WITH CHECK (true);

-- 6. Indexes: attachments are always queried by their owning document.
CREATE INDEX idx_finance_attachments_sale ON public.finance_attachments (sales_record_id);
CREATE INDEX idx_finance_attachments_inbound ON public.finance_attachments (inbound_batch_id);
CREATE INDEX idx_finance_attachments_payment ON public.finance_attachments (payment_id);

COMMIT;
