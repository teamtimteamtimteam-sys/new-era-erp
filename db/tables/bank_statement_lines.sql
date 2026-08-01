-- db/tables/bank_statement_lines.sql
-- 对账单行:金额【带符号】,正 = 入账(银行借方),负 = 出账(银行贷方),
-- 金额以报表本币记(= 账户本币),不可为 0。line_no 按导入数组顺序编号,
-- (statement_id, line_no) 唯一。
-- match_status 就是整个工作流:unmatched → matched(match_bank_line)
-- 或 → ignored(ignore_bank_line,须给理由);对账要求全部离开 unmatched。
-- 因此 RLS 给全权限(需要 UPDATE),状态迁移的合法性由函数把关。
--
-- NOTE: introduced by db/migrations/2026-07-30-phase3-s3a-bank-reconciliation.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.bank_statement_lines (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    statement_id  uuid NOT NULL REFERENCES public.bank_statements (id) ON DELETE RESTRICT,
    line_no       integer NOT NULL,
    line_date     date NOT NULL,
    description   text,
    reference     text,
    amount        numeric NOT NULL CHECK (amount <> 0),
    match_status  text NOT NULL DEFAULT 'unmatched' CHECK (match_status IN ('unmatched','matched','ignored')),
    ignore_reason text,
    notes         text,
    created_at    timestamptz DEFAULT now(),
    UNIQUE (statement_id, line_no)
);

CREATE INDEX idx_bank_statement_lines_statement ON public.bank_statement_lines (statement_id);
CREATE INDEX idx_bank_statement_lines_date ON public.bank_statement_lines (line_date);
CREATE INDEX idx_bank_statement_lines_status ON public.bank_statement_lines (match_status);

ALTER TABLE public.bank_statement_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "bank_statement_lines select by permission"
    ON public.bank_statement_lines
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

CREATE POLICY "bank_statement_lines insert by permission"
    ON public.bank_statement_lines
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "bank_statement_lines update by permission"
    ON public.bank_statement_lines
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit'::text)) WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "bank_statement_lines delete by permission"
    ON public.bank_statement_lines
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.finance.edit'::text));
