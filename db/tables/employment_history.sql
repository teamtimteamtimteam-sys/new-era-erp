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
                      -- HR-3a 加了 'salary_change';HR-2c 加了 'category_change'。
                      CHECK (change_type IN ('hired','confirmed','promotion','transfer','type_change','status_change','separated','salary_change','category_change')),
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
    -- ── HR-2c 追加 ───────────────────────────────────────────────────────────
    -- 这次变动之后的工种类别。按月累积要按【那个月当时的类别】取费率,所以类别变更必须留痕。
    work_category      text CHECK (work_category IN ('office','shopfloor')),
    -- ── PDPA-1-fu 追加 ───────────────────────────────────────────────────────
    -- 这一行的薪资两列与备注被覆盖掉的时刻。**它有两个身份**:既是留痕,也是
    -- 下面那条 salary_shape 与不可变守卫【认得出匿名化】的凭据。
    anonymised_at      timestamptz,
    -- 调薪行必须说得出新数字(old 可为 NULL:首次录入合同月薪时本来就没有旧值)
    -- 【PDPA-1-fu 多了一个析取项】已匿名化的行**有权不说** —— 它的新薪资被
    -- 依法覆盖掉了。原样保留"调薪行必须说得出新数字",只给匿名化一条有名字的出口。
    CONSTRAINT employment_history_salary_shape CHECK (
        change_type <> 'salary_change'
        OR new_monthly_salary IS NOT NULL
        OR anonymised_at IS NOT NULL
    ),
    CONSTRAINT employment_history_category_shape CHECK (
        change_type <> 'category_change' OR work_category IS NOT NULL
    )
);

CREATE INDEX idx_employment_history_employee ON public.employment_history (employee_id);

-- 【PDPA-1-fu:一条例外,由【形状】定义,不由开关定义】
-- 匿名化必须动得了这张表(薪资与备注是个人数据),而"不可变"不能因此变成"可改"。
-- 于是唯一放过的 UPDATE 是匿名化那一个形状:留痕列从 NULL 变成非 NULL、三个个人
-- 数据列全部变 NULL、**其余每一列逐个断言一字不动**。DELETE 永远拒绝。
-- 刻意【不】用会话标志(那会让任何人在声称自己在匿名化时改历史);也刻意写成
-- 白名单(否则将来加一列,新列会默认落在"允许改"的一侧)。证据在 fixture 126 的 I 臂。
CREATE OR REPLACE FUNCTION public.reject_employment_history_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    -- 【DELETE 永远拒绝】匿名化不删行 —— 原则 7 的可审计靠的正是那些行还在。
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'EMPLOYMENT_HISTORY_IMMUTABLE';
    END IF;

    -- 【唯一允许的 UPDATE:匿名化的那个形状】
    -- 白名单式:每一个不该动的列都逐一断言没动过。刻意【不】写成"只要没动这几列
    -- 就放过" —— 那样将来加一列,新列会默认落在允许改的一侧。
    IF  OLD.anonymised_at IS NULL AND NEW.anonymised_at IS NOT NULL
        AND NEW.old_monthly_salary IS NULL
        AND NEW.new_monthly_salary IS NULL
        AND NEW.notes             IS NULL
        AND NEW.id                = OLD.id
        AND NEW.employee_id       = OLD.employee_id
        AND NEW.effective_date    = OLD.effective_date
        AND NEW.change_type       = OLD.change_type
        AND NEW.created_at        = OLD.created_at
        AND NEW.job_title         IS NOT DISTINCT FROM OLD.job_title
        AND NEW.department_id     IS NOT DISTINCT FROM OLD.department_id
        AND NEW.employment_type   IS NOT DISTINCT FROM OLD.employment_type
        AND NEW.employment_status IS NOT DISTINCT FROM OLD.employment_status
        AND NEW.work_category     IS NOT DISTINCT FROM OLD.work_category
        AND NEW.created_by        IS NOT DISTINCT FROM OLD.created_by
    THEN
        RETURN NEW;
    END IF;

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
-- PDPA-1-fu:anonymised_at 授回 —— 它不是薪资,是"这一行还保不保有薪资"。
GRANT SELECT (id, employee_id, effective_date, change_type, job_title, department_id,
              employment_type, employment_status, notes, created_at, created_by, work_category,
              anonymised_at)
    ON public.employment_history TO authenticated;
COMMENT ON COLUMN public.employment_history.anonymised_at IS
    '这一行的薪资与备注被覆盖掉的时刻。NULL = 从来没有匿名化过。

**它有两个身份,这是刻意的:**既是留痕,也是 `employment_history_salary_shape`
与不可变守卫【认得出匿名化】的凭据 —— 一条 salary_change 行在匿名化之后
说不出新薪资,而它有权不说,因为这一列在。';
COMMENT ON COLUMN public.employment_history.work_category IS
    '这次变动之后的工种类别(office/shopfloor)。按月累积要按【那个月当时的类别】取费率,所以类别的变更必须留痕。历史行没填时,解析器回落到最早一条有值的记录,再回落到 employees 当前值。';
