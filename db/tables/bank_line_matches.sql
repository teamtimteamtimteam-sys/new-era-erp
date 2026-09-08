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

-- ── SILENT-1(2026-09-08)· 被拒绝的写要抛,不许是一次"成功的空操作" ──────────
-- 本表的写策略是 `USING (p) WITH CHECK (p)`,两侧同一个谓词:不满足 p 的人卡在
-- USING 上,那一行根本没进语句的视野,WITH CHECK 永远没机会抛 —— 零行、不报错。
-- 这支语句级触发器零行也照样触发,抛 PERMISSION_DENIED|<码>。
-- 它由 row_security_active() 守着,所以属主 / SECURITY DEFINER 那些路一律放行。
-- 【它不动任何策略,所以读权限不可能因它变窄。】详见迁移文件抬头。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.bank_line_matches
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');
