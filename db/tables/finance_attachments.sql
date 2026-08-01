-- db/tables/finance_attachments.sql
-- Finance document attachments — one table serving four parents (XOR):
--   * AR documents  → sales_record_id  (sales_records row)
--   * AP documents  → inbound_batch_id (priced inbound batch)
--   * payments      → payment_id
--   * expenses      → expense_id (supplement 2a)
-- Files live in the private Storage bucket "finance-attachments" (created alongside,
-- same pattern as supplier-attachments: private, 4 authenticated storage.objects
-- policies, file-type whitelist PDF/images/Word/Excel enforced in app code).
-- Conventions match supplier_attachments: soft delete via deleted_at, audit fields,
-- shared update_updated_at() trigger, authenticated-only full-access RLS.
--
-- NOTE: introduced by db/migrations/2026-07-30-phase3-s1-finance-attachments.sql;
-- expense_id + widened XOR by db/migrations/2026-07-30-phase3-s2a-expenses.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

-- 1. Table
CREATE TABLE public.finance_attachments (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Parent document (XOR). Plain REFERENCES (ON DELETE NO ACTION): finance rows are
    -- immutable/soft-deleted, never hard-DELETEd — an accidental hard delete of a
    -- referenced parent is blocked rather than silently dropping attachment rows.
    sales_record_id  uuid REFERENCES public.sales_records (id),
    inbound_batch_id uuid REFERENCES public.inbound_batches (id),
    payment_id       uuid REFERENCES public.payments (id),
    -- expense_id 在列序末尾(s2a 用 ALTER ADD COLUMN 追加;镜像按线上 attnum 排)
    CONSTRAINT finance_attachments_one_parent
        CHECK (num_nonnulls(sales_record_id, inbound_batch_id, payment_id, expense_id) = 1),
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
    updated_by       uuid,
    expense_id       uuid REFERENCES public.expenses (id)
);

-- 2. BEFORE UPDATE trigger -> reuse the existing shared update_updated_at() (do NOT redefine it)
CREATE TRIGGER trg_finance_attachments_updated_at
    BEFORE UPDATE ON public.finance_attachments
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();

-- 3. RLS: authenticated-only full access (matches supplier_attachments' policy)
ALTER TABLE public.finance_attachments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "finance_attachments select by permission"
    ON public.finance_attachments
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

CREATE POLICY "finance_attachments insert by permission"
    ON public.finance_attachments
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "finance_attachments update by permission"
    ON public.finance_attachments
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit'::text)) WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "finance_attachments delete by permission"
    ON public.finance_attachments
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.finance.edit'::text));

-- 4. Indexes: attachments are always queried by their owning document.
CREATE INDEX idx_finance_attachments_sale ON public.finance_attachments (sales_record_id);
CREATE INDEX idx_finance_attachments_inbound ON public.finance_attachments (inbound_batch_id);
CREATE INDEX idx_finance_attachments_payment ON public.finance_attachments (payment_id);
CREATE INDEX idx_finance_attachments_expense ON public.finance_attachments (expense_id);
