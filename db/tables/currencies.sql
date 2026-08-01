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
CREATE POLICY "currencies select by permission"
    ON public.currencies
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);

CREATE POLICY "currencies insert by permission"
    ON public.currencies
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "currencies update by permission"
    ON public.currencies
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit'::text)) WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "currencies delete by permission"
    ON public.currencies
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.finance.edit'::text));
