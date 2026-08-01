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
