-- db/tables/employment_history.sql
-- 任职履历:员工【当前】的状态住在 employees 那一行,这张表是"怎么走到今天"的
-- 轨迹 —— 应用在改动实质字段(职务/部门/用工类型/在职状态)时补一行。
-- 不可变(INSERT+SELECT RLS + 守卫触发器):写错了靠再补一行更正,不靠改历史。
-- ON DELETE RESTRICT:员工是软删的,硬删会带走履历,拦下。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【受限访问列 / RESTRICTED-ACCESS COLUMNS】(HR-3a 追加)
-- ════════════════════════════════════════════════════════════════════════════
--   old_monthly_salary / new_monthly_salary   调薪留痕 —— 归 data.view_pay。
-- 只能经 employment_history_masked 读取(遮蔽机制沿用 cut 2b)。
-- 【为什么加两列而不是塞进 notes】"这个人当时涨到多少"是个应当查得出来的事实,
-- 不该只以自由文本存在、要靠解析字符串才能回答。
-- ════════════════════════════════════════════════════════════════════════════
--
-- NOTE: introduced by db/migrations/2026-08-01-hr1a-hr-core.sql;
--       updated by db/migrations/2026-08-03-hr3a-performance-reviews.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.employment_history (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id       uuid NOT NULL REFERENCES public.employees (id) ON DELETE RESTRICT,
    effective_date    date NOT NULL,
    change_type       text NOT NULL
                      -- HR-3a 加了 'salary_change';既有七个值一个不动。
                      CHECK (change_type IN ('hired','confirmed','promotion','transfer','type_change','status_change','separated','salary_change')),
    job_title         text,
    department_id     uuid REFERENCES public.departments (id),
    employment_type   text,
    employment_status text,
    notes             text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid DEFAULT auth.uid(),
    -- ── HR-3a 追加的两列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    old_monthly_salary numeric,   -- RESTRICTED
    new_monthly_salary numeric,   -- RESTRICTED
    -- 调薪行必须说得出新数字(old 可为 NULL:首次录入合同月薪时本来就没有旧值)
    CONSTRAINT employment_history_salary_shape CHECK (
        change_type <> 'salary_change' OR new_monthly_salary IS NOT NULL
    )
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
CREATE POLICY "employment_history select by permission"
    ON public.employment_history
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text));

CREATE POLICY "employment_history insert by permission"
    ON public.employment_history
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'::text));

-- cut 4 员工自助:【追加】一条 PERMISSIVE 策略,与既有模块策略【或】起来。
-- 自助是行级的 —— 给普通员工 module.hr.view 会让他看见所有人,那恰好是反的。
CREATE POLICY "employment_history select own rows"
    ON public.employment_history AS PERMISSIVE FOR SELECT TO authenticated
    USING (employee_id = current_user_employee());

-- HR-3a 字段级遮蔽:表级 SELECT 授权【蕴含所有列】,所以先整表收回,再把非敏感列
-- 逐列授回。调薪两列只能经 employment_history_masked 读取。
-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
REVOKE SELECT ON public.employment_history FROM authenticated, anon;
GRANT SELECT (id, employee_id, effective_date, change_type, job_title, department_id,
              employment_type, employment_status, notes, created_at, created_by)
    ON public.employment_history TO authenticated;
