-- db/tables/stocktakes.sql
-- Stocktake headers — table + code-gen trigger + updated_at trigger + RLS.
-- Each stocktake collects counted quantities per batch (stocktake_lines) and is
-- posted via post_stocktake() (reconciles remaining_qty with adjustment movements).
-- Conventions match existing tables:
--   * code auto-generated 'ST-YYYY-NNNN' by a BEFORE INSERT trigger (dynamic year, 4-digit LPAD)
--   * soft delete via deleted_at
--   * audit fields created_by/updated_by default auth.uid(), created_at/updated_at default now()
--   * updated_at auto-bumped by the shared update_updated_at() function (do NOT redefine it)
--   * RLS: authenticated-only full access
--
-- NOTE: introduced by db/migrations/2026-07-03-phase2-cut4-stocktake.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE SEQUENCE IF NOT EXISTS public.stocktake_code_seq;

CREATE OR REPLACE FUNCTION public.generate_stocktake_code()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := 'ST-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    LPAD(nextval('stocktake_code_seq')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TABLE public.stocktakes (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code        text NOT NULL,
    status      text NOT NULL DEFAULT 'open' CHECK (status IN ('open','posted','cancelled')),
    notes       text,
    started_at  timestamptz NOT NULL DEFAULT now(),
    posted_at   timestamptz,
    deleted_at  timestamptz,
    created_by  uuid DEFAULT auth.uid(),
    updated_by  uuid DEFAULT auth.uid(),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_generate_stocktake_code
    BEFORE INSERT ON public.stocktakes
    FOR EACH ROW EXECUTE FUNCTION public.generate_stocktake_code();

CREATE TRIGGER trg_stocktakes_updated_at
    BEFORE UPDATE ON public.stocktakes
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.stocktakes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on stocktakes"
    ON public.stocktakes AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);
