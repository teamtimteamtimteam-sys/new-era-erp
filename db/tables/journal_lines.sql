-- db/tables/journal_lines.sql
-- Journal lines: original currency (amount_ccy + fx_rate) plus converted BASE
-- amounts in debit/credit (= round(amount_ccy × fx_rate, 2)); exactly one side
-- nonzero. Base currency is SGD since FIN-0 (was USD); fx_rate is the rate to SGD.
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
    fx_rate    numeric NOT NULL CHECK (fx_rate > 0),     -- 折 SGD 的汇率(FIN-0 前是折 USD)
    line_memo  text,
    created_at timestamptz NOT NULL DEFAULT now(),
    -- ── FIN-13 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 该行汇率取自牌价表的哪一天(可能早于分录日 —— 周末取上一个发布日)。
    -- NULL = 非牌价来源:本位币行,或跨币种结算里水单上的实际成交价。
    fx_rate_date date
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
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$;

CREATE CONSTRAINT TRIGGER trg_journal_lines_balance
    AFTER INSERT ON public.journal_lines
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.check_journal_balance();

ALTER TABLE public.journal_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "journal_lines select by permission"
    ON public.journal_lines
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

CREATE POLICY "journal_lines insert by permission"
    ON public.journal_lines
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));

COMMENT ON COLUMN public.journal_lines.fx_rate_date IS
    '该行汇率取自牌价表的哪一天(可能早于分录日:周末取上一个发布日)。NULL = 非牌价来源(本位币,或实际成交价)。';
