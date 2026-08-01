-- db/tables/stocktake_lines.sql
-- Stocktake lines — one counted quantity per batch within a stocktake.
-- No updated_at: a re-count replaces the line via upsert on the (stocktake, batch) key.
-- book_qty is the remaining_qty snapshot at count time; post_stocktake() recomputes the
-- delta against the CURRENT remaining_qty (count wins), so book_qty is informational.
--
-- The two UNIQUE constraints use the default NULLS DISTINCT: because each line has exactly
-- one batch FK (XOR CHECK), the null side never collides, giving partial-unique semantics
-- (unique per stocktake+inbound_batch, and per stocktake+output_batch) — no partial index needed.
--
-- NOTE: introduced by db/migrations/2026-07-03-phase2-cut4-stocktake.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.stocktake_lines (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    stocktake_id     uuid NOT NULL REFERENCES public.stocktakes (id) ON DELETE RESTRICT,
    inbound_batch_id uuid REFERENCES public.inbound_batches (id) ON DELETE RESTRICT,
    output_batch_id  uuid REFERENCES public.output_batches (id) ON DELETE RESTRICT,
    book_qty         numeric NOT NULL,
    counted_qty      numeric NOT NULL CHECK (counted_qty >= 0),
    notes            text,
    counted_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    CONSTRAINT stocktake_lines_one_batch CHECK ((inbound_batch_id IS NULL) <> (output_batch_id IS NULL)),
    UNIQUE (stocktake_id, inbound_batch_id),
    UNIQUE (stocktake_id, output_batch_id)
);

CREATE INDEX idx_stocktake_lines_stocktake ON public.stocktake_lines (stocktake_id);

ALTER TABLE public.stocktake_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "stocktake_lines select by permission"
    ON public.stocktake_lines
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.stocktakes.view'::text));

CREATE POLICY "stocktake_lines insert by permission"
    ON public.stocktake_lines
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.stocktakes.edit'::text));

CREATE POLICY "stocktake_lines update by permission"
    ON public.stocktake_lines
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.stocktakes.edit'::text)) WITH CHECK (has_permission('module.stocktakes.edit'::text));

CREATE POLICY "stocktake_lines delete by permission"
    ON public.stocktake_lines
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.stocktakes.edit'::text));
