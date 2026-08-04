-- db/tables/processing_cost_entries.sql
-- Processing cost entries — table + updated_at trigger + RLS + index.
-- Per-run process costs (labour/electricity/gas/etc). Raw material cost is NOT
-- stored here: it is computed from input legs × inbound unit_price by
-- allocate_processing_costs().
-- Conventions match existing tables (suppliers/tasks/...):
--   * soft delete via deleted_at
--   * audit fields created_by/updated_by, created_at/updated_at default now()
--   * updated_at auto-bumped by the shared update_updated_at() function (do NOT redefine it)
--   * RLS: authenticated-only full access (matches processing_runs' policy)
--
-- NOTE: introduced by db/migrations/2026-07-02-phase1-cut2-cost-metal-foundation.sql;
-- the two auto-journal triggers (trg_processing_cost_entries_journal_ins/_upd) were
-- added by db/migrations/2026-07-06-phase3-cut2a-auto-journal.sql —— 该切次【漏了
-- 同步本镜像】,2026-07-31 的镜像漂移审计发现后补正(动表的迁移必须在同一提交里
-- 更新镜像)。fin_journal_cost_entry() 本身镜像在 db/functions/finance_journal_triggers.sql。
-- This mirror is a first-run script (plain CREATEs). Re-running requires dropping
-- the objects first. Run in the Supabase SQL Editor.

-- 1. Table
CREATE TABLE public.processing_cost_entries (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Owning run. ON DELETE RESTRICT: runs are soft-deleted (reversed), never hard-DELETEd;
    -- RESTRICT blocks an accidental hard delete of a run that still has cost history.
    run_id      uuid        NOT NULL REFERENCES public.processing_runs (id) ON DELETE RESTRICT,
    cost_type   text        NOT NULL CHECK (cost_type IN
        ('labour','electricity','gas','depreciation','consumables','waste_treatment','other')),
    -- Deliberately no sign check: by-product / disposal offsets may be negative.
    amount_base  numeric     NOT NULL,
    is_estimate boolean     NOT NULL DEFAULT false,
    notes       text,
    deleted_at  timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid,
    -- ── FIN-6 追加(ALTER 加的列排在末尾)────────────────────────────────────
    -- 实际额行:汇付即结(remitted_*);估算行:真实发票冲抵即结(relieved_*)。
    -- 结过的行不许再改额/软删(guard_cost_entry_settled)—— 应计已被清,再动就是孤儿。
    remitted_at               date,
    remitted_journal_entry_id uuid REFERENCES public.journal_entries (id),
    relieved_at               date,
    relief_expense_id         uuid REFERENCES public.expenses (id)
);

-- 2. BEFORE UPDATE trigger -> reuse the existing shared update_updated_at() (do NOT redefine it)
CREATE OR REPLACE FUNCTION public.guard_cost_entry_settled()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF (OLD.remitted_at IS NOT NULL OR OLD.relieved_at IS NOT NULL)
       AND (NEW.amount_base IS DISTINCT FROM OLD.amount_base
            OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at
            OR NEW.cost_type IS DISTINCT FROM OLD.cost_type
            OR NEW.is_estimate IS DISTINCT FROM OLD.is_estimate) THEN
        RAISE EXCEPTION 'COST_ENTRY_SETTLED|%', OLD.cost_type;
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_processing_cost_entries_settled_guard
    BEFORE UPDATE ON public.processing_cost_entries
    FOR EACH ROW EXECUTE FUNCTION public.guard_cost_entry_settled();

CREATE TRIGGER trg_processing_cost_entries_updated_at
    BEFORE UPDATE ON public.processing_cost_entries
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();

-- 2b. 自动过账触发器(phase3 cut 2a):录入/改动加工成本即产生对应分录。
--     函数 fin_journal_cost_entry 见 db/functions/finance_journal_triggers.sql
--     (软删除 = UPDATE deleted_at,也走 _upd 触发器 —— 冲销分录由函数内部判断)。
CREATE TRIGGER trg_processing_cost_entries_journal_ins
    AFTER INSERT ON public.processing_cost_entries
    FOR EACH ROW
    EXECUTE FUNCTION fin_journal_cost_entry();

CREATE TRIGGER trg_processing_cost_entries_journal_upd
    AFTER UPDATE ON public.processing_cost_entries
    FOR EACH ROW
    EXECUTE FUNCTION fin_journal_cost_entry();

-- 3. RLS: authenticated-only full access (matches processing_runs' policy)
ALTER TABLE public.processing_cost_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY "processing_cost_entries select by permission"
    ON public.processing_cost_entries
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

CREATE POLICY "processing_cost_entries insert by permission"
    ON public.processing_cost_entries
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.processing.edit'::text));

CREATE POLICY "processing_cost_entries update by permission"
    ON public.processing_cost_entries
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.processing.edit'::text)) WITH CHECK (has_permission('module.processing.edit'::text));

CREATE POLICY "processing_cost_entries delete by permission"
    ON public.processing_cost_entries
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.processing.edit'::text));

-- 4. Index: we always query cost entries by their owning run.
CREATE INDEX idx_processing_cost_entries_run
    ON public.processing_cost_entries (run_id);

-- cut 2b 字段级遮蔽:收回原始敏感列。表级 SELECT 授权【蕴含所有列】,
-- 所以必须先整表收回,再把非敏感列逐列授回。敏感列只能经 processing_cost_entries_masked 读取。
-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
REVOKE SELECT ON public.processing_cost_entries FROM authenticated, anon;
-- 【加列必改这一行】列清单 SELECT 授权不会自动延伸到 ALTER 加的新列(表级
-- INSERT/UPDATE 会)。FIN-6 加的四列结算列漏在清单外,页面因此 42501 且静默空白。
-- db/gate.py 的【列权限缺口】判据现在会当场点名,别再靠人点开页面发现。
GRANT SELECT (id, run_id, cost_type, is_estimate, notes, deleted_at, created_at, created_by, updated_at, updated_by,
              remitted_at, remitted_journal_entry_id, relieved_at, relief_expense_id)
    ON public.processing_cost_entries TO authenticated;

-- FIN-1a:改名列的注释(说明写在数据库里,重建出来的库也带着)
COMMENT ON COLUMN public.processing_cost_entries.amount_base IS '本位币金额(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 amount_usd)。';
