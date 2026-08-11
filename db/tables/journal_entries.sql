-- db/tables/journal_entries.sql
-- Journal entry headers. IMMUTABLE: no updated_at/deleted_at — corrections are
-- reversal entries (reverse_journal_entry). code is gapless 'JE-YYYY-NNNN',
-- assigned by post_journal_entry inside its transaction (max+1 per entry_date
-- year under an advisory lock; a rolled-back post releases its number) — NOT a
-- sequence trigger, so audit numbering has no gaps.
-- RLS: INSERT+SELECT only. UPDATE has no policy — the only mutation path is
-- reverse_journal_entry (SECURITY DEFINER), and the guard trigger allows solely
-- the posted→reversed status flip (column-by-column check).
--
-- NOTE: introduced by db/migrations/2026-07-05-phase3-cut1-finance-foundation.sql;
-- source_type 'payroll' added by db/migrations/2026-08-01-hr1a-hr-core.sql;
-- source_type 'depreciation' + 'asset_disposal' added by
-- db/migrations/2026-08-06-fin22-fixed-assets-and-depreciation.sql;
-- source_type 'prepayment' added by
-- db/migrations/2026-07-31-phase4-cut4a-purchase-orders.sql, which also corrected
-- this mirror's source_type list —— 'expense' 是 s2a 那一切加进库里的,但当时【漏了
-- 同步这份镜像】。照旧版镜像重建会把既有的 expense 分录判违约(实测 23514),故此处
-- 以库里的实际取值为准。
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.journal_entries (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code        text NOT NULL UNIQUE,
    entry_date  date NOT NULL,
    memo        text,
    source_type text CHECK (source_type IN ('manual','purchase','sale','processing_cost','allocation','stocktake','writeoff','payment','fx','expense','prepayment','payroll','transfer','revaluation','depreciation','asset_disposal','year_close','freight')),
    source_id   uuid,
    status      text NOT NULL DEFAULT 'posted' CHECK (status IN ('posted','reversed')),
    reversed_by uuid REFERENCES public.journal_entries (id),
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid DEFAULT auth.uid()
);

CREATE OR REPLACE FUNCTION public.guard_journal_entry_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'JOURNAL_IMMUTABLE';
    END IF;
    -- 除 status / reversed_by 外任何列变更 → 拒绝
    IF NEW.id          IS DISTINCT FROM OLD.id
       OR NEW.code        IS DISTINCT FROM OLD.code
       OR NEW.entry_date  IS DISTINCT FROM OLD.entry_date
       OR NEW.memo        IS DISTINCT FROM OLD.memo
       OR NEW.source_type IS DISTINCT FROM OLD.source_type
       OR NEW.source_id   IS DISTINCT FROM OLD.source_id
       OR NEW.created_at  IS DISTINCT FROM OLD.created_at
       OR NEW.created_by  IS DISTINCT FROM OLD.created_by
    THEN
        RAISE EXCEPTION 'JOURNAL_IMMUTABLE';
    END IF;
    -- status/reversed_by 也只认唯一合法迁移:posted → reversed 且首次挂上冲销单
    IF NOT (OLD.status = 'posted' AND NEW.status = 'reversed'
            AND OLD.reversed_by IS NULL AND NEW.reversed_by IS NOT NULL) THEN
        RAISE EXCEPTION 'JOURNAL_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_journal_entries_immutable
    BEFORE UPDATE OR DELETE ON public.journal_entries
    FOR EACH ROW EXECUTE FUNCTION public.guard_journal_entry_mutation();

-- OPS-16:【每一个期间问题都走 entry_date,而它此前没有索引】——
-- 损益表、资产负债表、现金流量表、试算平衡全都按 entry_date 圈期间;仪表盘一屏
-- 要问好几次,做期间对比再翻一倍。此前这张表上只有 pkey 与 code 的唯一索引。
CREATE INDEX idx_journal_entries_entry_date ON public.journal_entries (entry_date);

ALTER TABLE public.journal_entries ENABLE ROW LEVEL SECURITY;
CREATE POLICY "journal_entries select by permission"
    ON public.journal_entries
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

CREATE POLICY "journal_entries insert by permission"
    ON public.journal_entries
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));
