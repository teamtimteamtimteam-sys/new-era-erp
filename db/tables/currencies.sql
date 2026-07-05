-- db/tables/currencies.sql
-- Currency reference table (finance foundation). No audit columns — reference
-- data, rarely touched. Widen the code CHECK when adding currencies.
-- USD is the base currency (is_base); journal amounts are stored in USD.
--
-- NOTE: introduced by db/migrations/2026-07-05-phase3-cut1-finance-foundation.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.currencies (
    code    text PRIMARY KEY CHECK (code IN ('USD','SGD')),  -- 加币种时同步放宽此 CHECK
    name    text NOT NULL,
    is_base boolean NOT NULL DEFAULT false
);

INSERT INTO public.currencies (code, name, is_base) VALUES
    ('USD', 'US Dollar', true),
    ('SGD', 'Singapore Dollar', false);

ALTER TABLE public.currencies ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on currencies"
    ON public.currencies AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);
