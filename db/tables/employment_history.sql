-- db/tables/employment_history.sql
-- 任职履历:员工【当前】的状态住在 employees 那一行,这张表是"怎么走到今天"的
-- 轨迹 —— 应用在改动实质字段(职务/部门/用工类型/在职状态)时补一行。
-- 不可变(INSERT+SELECT RLS + 守卫触发器):写错了靠再补一行更正,不靠改历史。
-- ON DELETE RESTRICT:员工是软删的,硬删会带走履历,拦下。
--
-- NOTE: introduced by db/migrations/2026-08-01-hr1a-hr-core.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.employment_history (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id       uuid NOT NULL REFERENCES public.employees (id) ON DELETE RESTRICT,
    effective_date    date NOT NULL,
    change_type       text NOT NULL
                      CHECK (change_type IN ('hired','confirmed','promotion','transfer','type_change','status_change','separated')),
    job_title         text,
    department_id     uuid REFERENCES public.departments (id),
    employment_type   text,
    employment_status text,
    notes             text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid DEFAULT auth.uid()
);

CREATE INDEX idx_employment_history_employee ON public.employment_history (employee_id);

CREATE OR REPLACE FUNCTION public.reject_employment_history_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'EMPLOYMENT_HISTORY_IMMUTABLE';
END;
$fn$;

CREATE TRIGGER trg_employment_history_immutable
    BEFORE UPDATE OR DELETE ON public.employment_history
    FOR EACH ROW EXECUTE FUNCTION public.reject_employment_history_mutation();

ALTER TABLE public.employment_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated select on employment_history"
    ON public.employment_history FOR SELECT TO authenticated USING (true);
CREATE POLICY "authenticated insert on employment_history"
    ON public.employment_history FOR INSERT TO authenticated WITH CHECK (true);
