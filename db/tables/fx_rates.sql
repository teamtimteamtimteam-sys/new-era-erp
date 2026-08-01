-- db/tables/fx_rates.sql
-- Manual FX rates. Semantics: 1 unit of currency = rate_to_usd USD; USD itself
-- needs no rows. Conventions match existing tables (soft delete, audit fields,
-- shared update_updated_at trigger, authenticated-full-access RLS).
--
-- NOTE: introduced by db/migrations/2026-07-05-phase3-cut1-finance-foundation.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.fx_rates (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    currency    text NOT NULL REFERENCES public.currencies (code),
    rate_to_usd numeric NOT NULL CHECK (rate_to_usd > 0),
    rate_date   date NOT NULL,
    source      text NOT NULL DEFAULT 'manual',
    notes       text,
    deleted_at  timestamptz,
    created_by  uuid DEFAULT auth.uid(),
    updated_by  uuid DEFAULT auth.uid(),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (currency, rate_date)
);

CREATE TRIGGER trg_fx_rates_updated_at
    BEFORE UPDATE ON public.fx_rates
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.fx_rates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "fx_rates select by permission"
    ON public.fx_rates
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

CREATE POLICY "fx_rates insert by permission"
    ON public.fx_rates
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "fx_rates update by permission"
    ON public.fx_rates
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit'::text)) WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "fx_rates delete by permission"
    ON public.fx_rates
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.finance.edit'::text));
