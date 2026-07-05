-- db/tables/journal_lines.sql
-- Journal lines: original currency (amount_ccy + fx_rate) plus converted USD
-- in debit/credit (= round(amount_ccy × fx_rate, 2)); exactly one side nonzero.
-- IMMUTABLE (INSERT+SELECT RLS only + trigger). Balance invariant: a DEFERRABLE
-- INITIALLY DEFERRED constraint trigger enforces per-entry Σdebit = Σcredit and
-- ≥ 2 lines at commit (JOURNAL_UNBALANCED|code|Σd|Σc).
--
-- NOTE: introduced by db/migrations/2026-07-05-phase3-cut1-finance-foundation.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.journal_lines (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    entry_id   uuid NOT NULL REFERENCES public.journal_entries (id) ON DELETE RESTRICT,
    account_id uuid NOT NULL REFERENCES public.accounts (id) ON DELETE RESTRICT,
    debit      numeric NOT NULL DEFAULT 0 CHECK (debit >= 0),
    credit     numeric NOT NULL DEFAULT 0 CHECK (credit >= 0),
    -- 恰好一边非零(单行不允许两边都记或都不记)
    CONSTRAINT journal_lines_one_side CHECK ((debit = 0) <> (credit = 0)),
    currency   text NOT NULL REFERENCES public.currencies (code),
    amount_ccy numeric NOT NULL CHECK (amount_ccy > 0),  -- 原币金额
    fx_rate    numeric NOT NULL CHECK (fx_rate > 0),     -- 使用的 rate_to_usd
    line_memo  text,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_journal_lines_entry ON public.journal_lines (entry_id);
CREATE INDEX idx_journal_lines_account ON public.journal_lines (account_id);

CREATE OR REPLACE FUNCTION public.reject_journal_line_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'JOURNAL_IMMUTABLE';
END;
$fn$;

CREATE TRIGGER trg_journal_lines_immutable
    BEFORE UPDATE OR DELETE ON public.journal_lines
    FOR EACH ROW EXECUTE FUNCTION public.reject_journal_line_mutation();

CREATE OR REPLACE FUNCTION public.check_journal_balance()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_count  integer;
    v_debit  numeric;
    v_credit numeric;
    v_code   text;
BEGIN
    SELECT count(*), COALESCE(sum(l.debit), 0), COALESCE(sum(l.credit), 0)
    INTO v_count, v_debit, v_credit
    FROM journal_lines l
    WHERE l.entry_id = NEW.entry_id;

    IF v_count < 2 OR v_debit <> v_credit THEN
        SELECT code INTO v_code FROM journal_entries WHERE id = NEW.entry_id;
        RAISE EXCEPTION 'JOURNAL_UNBALANCED|%|%|%', COALESCE(v_code, '?'), v_debit, v_credit;
    END IF;
    RETURN NULL;
END;
$fn$;

CREATE CONSTRAINT TRIGGER trg_journal_lines_balance
    AFTER INSERT ON public.journal_lines
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.check_journal_balance();

ALTER TABLE public.journal_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated select on journal_lines"
    ON public.journal_lines FOR SELECT TO authenticated USING (true);
CREATE POLICY "authenticated insert on journal_lines"
    ON public.journal_lines FOR INSERT TO authenticated WITH CHECK (true);
