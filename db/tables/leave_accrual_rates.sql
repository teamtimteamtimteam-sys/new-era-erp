-- db/tables/leave_accrual_rates.sql
-- 年假的【每月累积费率】。类别费率与员工 override 同住一张表,都是生效日期式的。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【运行期配置 / RUNTIME CONFIG —— 下面的种子是"全新安装的默认值",不是线上快照】
-- HR 会在界面上加 override 行(一份谈定的年假是合同条款),所以线上与本文件不一致
-- 是【正常的】,check_mirrors.py 不把本表与线上比对。
-- ═══════════════════════════════════════════════════════════════════════════
--
-- 【为什么必须是生效日期式的】按月累积要按【那个月当时】适用的费率算:
--   * 一个人 7 月从车间转到办公室 → 前 6 个月 1.5、后 6 个月 2.0;
--   * 手册把办公室从 24 改到 30 → 改之前的月份保留 2.0。
-- 没有 effective_from,这两件事都只能靠"拿现在的数乘 12",那正是 HR-2c 要消灭的错。
--
-- 【没有 effective_to】某个月适用的是"生效日 <= 该月首日"里最新的那一条。
-- 于是不存在空档,也不存在重叠 —— 少一个字段,少一整类 bug。
--
-- 【存年额,不是月额】25 天/年若存成 2.0833,十二个月加起来是 24.9996,向下取到 0.5
-- 就变成 24.5 —— 合同写 25 的人只能请 24.5。24 与 18 能被 12 整除所以看不出来,
-- 而 override 存在的意义恰恰是那些除不尽的数字。累积按 Σ(年额 × 区间月数 / 12) 算。
--
-- 【生效了就不能再改】effective_from <= 今天 的行,UPDATE 与 DELETE 一律拒绝
-- (guard_effective_accrual_rate)。改费率 = 插一条更晚生效的行;更正历史 = 同样是插入。
-- 少了这道守卫,B3 那句"改之前的月份保留旧费率"就只靠没人去改历史 —— 一条 UPDATE
-- 能把每个人从入职日到今天重算一遍,没有痕迹,而且本表是运行期配置、刻意不做逐行比对。
-- 未来生效的行仍可改:它还没影响过任何人的余额。
--
-- 【员工行的 days_per_year 可以是 NULL】含义是"从这天起回到类别费率"。
-- 没有这条就没有回头路:一个当年谈了 1.5 的人后来转到办公室,会永远比同事少。
--
-- 【不在数据库里强制法定下限】《雇佣法》的适用范围取决于 workman 认定与薪资门槛,
-- 本系统并没有完整建模这些;一个半对的守卫比没有守卫更糟。下限是合同审阅的事。
--
-- NOTE: introduced by db/migrations/2026-08-06-hr2c-monthly-accrual.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.leave_accrual_rates (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    work_category   text CHECK (work_category IN ('office','shopfloor')),
    employee_id     uuid REFERENCES public.employees (id),
    days_per_year   numeric,
    effective_from  date NOT NULL,
    reason          text,
    notes           text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid DEFAULT auth.uid(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    updated_by      uuid DEFAULT auth.uid(),

    -- 二选一:类别行 或 员工行
    CONSTRAINT leave_accrual_rates_target_shape CHECK (
        (work_category IS NOT NULL AND employee_id IS NULL)
        OR (work_category IS NULL AND employee_id IS NOT NULL)),
    CONSTRAINT leave_accrual_rates_days_non_negative CHECK (
        days_per_year IS NULL OR days_per_year >= 0),
    -- 类别行是兜底,兜底不能是空的
    CONSTRAINT leave_accrual_rates_category_rate_required CHECK (
        employee_id IS NOT NULL OR days_per_year IS NOT NULL),
    -- override 必须说明为什么 —— 合同条款要有痕迹(created_by 记的是谁)
    CONSTRAINT leave_accrual_rates_override_reason CHECK (
        employee_id IS NULL OR (reason IS NOT NULL AND btrim(reason) <> ''))
);

CREATE UNIQUE INDEX idx_leave_accrual_rates_category
    ON public.leave_accrual_rates (work_category, effective_from) WHERE work_category IS NOT NULL;
CREATE UNIQUE INDEX idx_leave_accrual_rates_employee
    ON public.leave_accrual_rates (employee_id, effective_from) WHERE employee_id IS NOT NULL;

-- 【生效即不可改】与 employment_history 的不可变守卫、accounts 的 is_system 守卫同一类。
-- 触发器名里的 immutable 排在 updated_at 之前,所以拒绝发生在盖时间戳之前。
CREATE OR REPLACE FUNCTION public.guard_effective_accrual_rate()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.effective_from <= CURRENT_DATE THEN
            RAISE EXCEPTION 'RATE_IN_EFFECT_IMMUTABLE|%', OLD.effective_from;
        END IF;
        RETURN OLD;
    END IF;
    -- 【未来生效的行仍可改】它还没影响过任何人的余额。
    IF OLD.effective_from <= CURRENT_DATE THEN
        RAISE EXCEPTION 'RATE_IN_EFFECT_IMMUTABLE|%', OLD.effective_from;
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_leave_accrual_rates_immutable
    BEFORE UPDATE OR DELETE ON public.leave_accrual_rates
    FOR EACH ROW EXECUTE FUNCTION public.guard_effective_accrual_rate();

CREATE TRIGGER trg_leave_accrual_rates_updated_at
    BEFORE UPDATE ON public.leave_accrual_rates
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.leave_accrual_rates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "leave_accrual_rates select by permission"
    ON public.leave_accrual_rates AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));
CREATE POLICY "leave_accrual_rates select own rows"
    ON public.leave_accrual_rates AS PERMISSIVE FOR SELECT TO authenticated
    USING (employee_id = current_user_employee());
CREATE POLICY "leave_accrual_rates insert by permission"
    ON public.leave_accrual_rates AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "leave_accrual_rates update by permission"
    ON public.leave_accrual_rates AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "leave_accrual_rates delete by permission"
    ON public.leave_accrual_rates AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'));

-- 引导默认值:手册的办公室 24 / 车间 18,换算成每月。
INSERT INTO public.leave_accrual_rates (work_category, days_per_year, effective_from, notes) VALUES
    ('office',    24, '2000-01-01', 'Handbook: 24 days per year for office staff.'),
    ('shopfloor', 18, '2000-01-01', 'Handbook: 18 days per year for shopfloor staff.');

COMMENT ON COLUMN public.leave_accrual_rates.days_per_year IS
    '【年额】,不是月额。累积按 Σ(年额 × 区间月数 / 12) 算,最后只除一次 12 —— 存月额的话,25 天/年要写 2.0833,十二个月加起来 24.9996,向下取整后合同写 25 的人只能请 24.5。员工行为 NULL 表示"从 effective_from 起回到类别费率"。类别行不许为 NULL。';
COMMENT ON COLUMN public.leave_accrual_rates.effective_from IS
    '生效日。【没有 effective_to】:某个月适用的是"生效日 <= 该月首日"里最新的那一条。于是不存在空档与重叠,也让"费率改了,改之前的月份保留旧费率"成为自动的结果。';
