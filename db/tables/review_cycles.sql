-- db/tables/review_cycles.sql
-- 一轮有名字的年度评估。open_review_cycle 按它铺出每人一份草稿,
-- 期间(period_start / period_end)由那个函数原样抄进每一份评估。
--
-- 【试用期评估不属于任何一轮】—— 它跟着人走,不跟着年度走。
-- performance_reviews_cycle_shape 那条 check 是这句话在数据上的样子。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3a-performance-reviews.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.review_cycles (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name         text NOT NULL,
    period_start date NOT NULL,
    period_end   date NOT NULL,
    due_date     date NOT NULL,
    status       text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','open','closed')),
    notes        text,
    deleted_at   timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT auth.uid(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid DEFAULT auth.uid(),
    CONSTRAINT review_cycles_period_shape CHECK (period_end >= period_start)
);

CREATE UNIQUE INDEX idx_review_cycles_name_live
    ON public.review_cycles (name) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_review_cycles_updated_at
    BEFORE UPDATE ON public.review_cycles
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.review_cycles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "review_cycles select by permission"
    ON public.review_cycles AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));
CREATE POLICY "review_cycles insert by permission"
    ON public.review_cycles AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "review_cycles update by permission"
    ON public.review_cycles AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "review_cycles delete by permission"
    ON public.review_cycles AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'));

-- ── SILENT-1(2026-09-08)· 被拒绝的写要抛,不许是一次"成功的空操作" ──────────
-- 本表的写策略是 `USING (p) WITH CHECK (p)`,两侧同一个谓词:不满足 p 的人卡在
-- USING 上,那一行根本没进语句的视野,WITH CHECK 永远没机会抛 —— 零行、不报错。
-- 这支语句级触发器零行也照样触发,抛 PERMISSION_DENIED|<码>。
-- 它由 row_security_active() 守着,所以属主 / SECURITY DEFINER 那些路一律放行。
-- 【它不动任何策略,所以读权限不可能因它变窄。】详见迁移文件抬头。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.review_cycles
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.hr.edit');
