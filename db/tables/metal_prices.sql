-- db/tables/metal_prices.sql
-- Metal prices (USD per tonne) — table + updated_at trigger + RLS.
-- Manual entry for now; a future LME feed only changes the `source` and the data
-- pipeline, not this shape. allocate_processing_costs() picks the most recent row
-- (deleted_at IS NULL) with price_date <= run.process_date for each metal.
-- Conventions match existing tables:
--   * soft delete via deleted_at
--   * audit fields created_by/updated_by, created_at/updated_at default now()
--   * updated_at auto-bumped by the shared update_updated_at() function (do NOT redefine it)
--   * RLS: authenticated-only full access
--   * Shared metal set with inbound/output_batch_metals; when adding a metal, widen ALL those CHECKs together.
--
-- NOTE: introduced by db/migrations/2026-07-02-phase1-cut2-cost-metal-foundation.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

-- 1. Table
CREATE TABLE public.metal_prices (
    id                  uuid    PRIMARY KEY DEFAULT gen_random_uuid(),
    metal               text    NOT NULL CHECK (metal IN ('ni','co','li','mn','cu','al','fe')),
    price_usd_per_tonne numeric NOT NULL CHECK (price_usd_per_tonne > 0),
    price_date          date    NOT NULL,
    source              text    NOT NULL DEFAULT 'manual',
    notes               text,
    deleted_at          timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid,
    -- At most one price per metal per day (soft-deleted rows still occupy the slot;
    -- correct a price by updating the row, not inserting a duplicate).
    UNIQUE (metal, price_date)
);

-- 2. BEFORE UPDATE trigger -> reuse the existing shared update_updated_at() (do NOT redefine it)
CREATE TRIGGER trg_metal_prices_updated_at
    BEFORE UPDATE ON public.metal_prices
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();

-- 3. RLS: authenticated-only full access
ALTER TABLE public.metal_prices ENABLE ROW LEVEL SECURITY;

CREATE POLICY "authenticated full access on metal_prices"
    ON public.metal_prices
    AS PERMISSIVE
    FOR ALL
    TO authenticated
    USING (true)
    WITH CHECK (true);
