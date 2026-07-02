-- db/tables/processing_cost_entries.sql
-- Processing cost entries — table + updated_at trigger + RLS + index.
-- Per-run process costs (labour/electricity/gas/etc). Raw material cost is NOT
-- stored here: it is computed from input legs × inbound unit_price by
-- allocate_processing_costs().
-- Conventions match existing tables (suppliers/tasks/...):
--   * soft delete via deleted_at
--   * audit fields created_by/updated_by, created_at/updated_at default now()
--   * updated_at auto-bumped by the shared update_updated_at() function (do NOT redefine it)
--   * RLS: authenticated-only full access (matches processing_runs' policy)
--
-- NOTE: introduced by db/migrations/2026-07-02-phase1-cut2-cost-metal-foundation.sql.
-- This mirror is a first-run script (plain CREATEs). Re-running requires dropping
-- the objects first. Run in the Supabase SQL Editor.

-- 1. Table
CREATE TABLE public.processing_cost_entries (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Owning run. ON DELETE RESTRICT: runs are soft-deleted (reversed), never hard-DELETEd;
    -- RESTRICT blocks an accidental hard delete of a run that still has cost history.
    run_id      uuid        NOT NULL REFERENCES public.processing_runs (id) ON DELETE RESTRICT,
    cost_type   text        NOT NULL CHECK (cost_type IN
        ('labour','electricity','gas','depreciation','consumables','waste_treatment','other')),
    -- Deliberately no sign check: by-product / disposal offsets may be negative.
    amount_usd  numeric     NOT NULL,
    is_estimate boolean     NOT NULL DEFAULT false,
    notes       text,
    deleted_at  timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid
);

-- 2. BEFORE UPDATE trigger -> reuse the existing shared update_updated_at() (do NOT redefine it)
CREATE TRIGGER trg_processing_cost_entries_updated_at
    BEFORE UPDATE ON public.processing_cost_entries
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();

-- 3. RLS: authenticated-only full access (matches processing_runs' policy)
ALTER TABLE public.processing_cost_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY "authenticated full access on processing_cost_entries"
    ON public.processing_cost_entries
    AS PERMISSIVE
    FOR ALL
    TO authenticated
    USING (true)
    WITH CHECK (true);

-- 4. Index: we always query cost entries by their owning run.
CREATE INDEX idx_processing_cost_entries_run
    ON public.processing_cost_entries (run_id);
