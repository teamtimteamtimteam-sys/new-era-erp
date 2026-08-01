-- db/tables/bank_line_matches.sql
-- 报表行 ↔ 分录行的匹配。一条报表行可配多条分录行(合并入账/批量付款),
-- 但【一条分录行终生只能被认领一次】—— journal_line_id UNIQUE,这正是
-- bank_reconciliation_status / bank_unmatched_journal_lines 里"未匹配分录行"
-- 判定的依据。matched_amount = 从该分录行认领的原币金额(当前实现 = 整行
-- amount_ccy;将来若要支持部分认领,放开 UNIQUE 并在此累计)。
-- 解除匹配 = 删本表行(unmatch_bank_line),故 ON DELETE CASCADE 挂在报表行侧;
-- 分录行侧 RESTRICT —— 分录不可删,别让匹配成为漏洞。
--
-- NOTE: introduced by db/migrations/2026-07-30-phase3-s3a-bank-reconciliation.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.bank_line_matches (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    statement_line_id uuid NOT NULL REFERENCES public.bank_statement_lines (id) ON DELETE CASCADE,
    journal_line_id   uuid NOT NULL UNIQUE REFERENCES public.journal_lines (id) ON DELETE RESTRICT,
    matched_amount    numeric NOT NULL CHECK (matched_amount > 0),
    created_at        timestamptz DEFAULT now(),
    created_by        uuid DEFAULT auth.uid()
);

CREATE INDEX idx_bank_line_matches_statement_line ON public.bank_line_matches (statement_line_id);

ALTER TABLE public.bank_line_matches ENABLE ROW LEVEL SECURITY;
CREATE POLICY "bank_line_matches select by permission"
    ON public.bank_line_matches
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

CREATE POLICY "bank_line_matches insert by permission"
    ON public.bank_line_matches
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "bank_line_matches update by permission"
    ON public.bank_line_matches
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit'::text)) WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "bank_line_matches delete by permission"
    ON public.bank_line_matches
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.finance.edit'::text));
