-- db/tables/finance_settings.sql
-- Single-row finance settings. locked_before is the period lock: journal
-- entries dated before it are rejected by post_journal_entry (PERIOD_LOCKED).
-- The boolean-true PK enforces the single row.
--
-- NOTE: introduced by db/migrations/2026-07-05-phase3-cut1-finance-foundation.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.finance_settings (
    id            boolean PRIMARY KEY DEFAULT true CHECK (id),  -- 单行表:PK 恒为 true
    locked_before date,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    uuid DEFAULT auth.uid()
);

INSERT INTO public.finance_settings (id, locked_before) VALUES (true, NULL);

CREATE TRIGGER trg_finance_settings_updated_at
    BEFORE UPDATE ON public.finance_settings
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.finance_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on finance_settings"
    ON public.finance_settings AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);
