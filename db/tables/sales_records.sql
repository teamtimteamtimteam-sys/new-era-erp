-- db/tables/sales_records.sql
-- Sales facts (quantity + price + currency + USD amount), written only by
-- record_output_sale alongside the 'sale' inventory movement (movement_id link).
-- IMMUTABLE (INSERT+SELECT RLS only + trigger): sales are facts; corrections go
-- through a future credit-note concept, not edits.
--
-- NOTE: introduced by db/migrations/2026-07-05-phase3-cut1-finance-foundation.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.sales_records (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    output_batch_id uuid NOT NULL REFERENCES public.output_batches (id) ON DELETE RESTRICT,
    customer_id     uuid REFERENCES public.customers (id),
    quantity        numeric NOT NULL CHECK (quantity > 0),
    unit_price      numeric NOT NULL CHECK (unit_price > 0),
    currency        text NOT NULL REFERENCES public.currencies (code),
    fx_rate         numeric NOT NULL CHECK (fx_rate > 0),
    amount_usd      numeric NOT NULL,  -- round(quantity × unit_price × fx_rate, 2)
    sale_date       date NOT NULL,
    notes           text,
    movement_id     uuid REFERENCES public.inventory_movements (id),
    created_at      timestamptz DEFAULT now(),
    created_by      uuid DEFAULT auth.uid()
);

CREATE INDEX idx_sales_records_batch ON public.sales_records (output_batch_id);

CREATE OR REPLACE FUNCTION public.reject_sales_record_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'SALE_IMMUTABLE';
END;
$fn$;

CREATE TRIGGER trg_sales_records_immutable
    BEFORE UPDATE OR DELETE ON public.sales_records
    FOR EACH ROW EXECUTE FUNCTION public.reject_sales_record_mutation();

ALTER TABLE public.sales_records ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated select on sales_records"
    ON public.sales_records FOR SELECT TO authenticated USING (true);
CREATE POLICY "authenticated insert on sales_records"
    ON public.sales_records FOR INSERT TO authenticated WITH CHECK (true);
