-- db/tables/payroll_lines.sql
-- 工资明细:一个周期里每名员工一行。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【受限访问列 / RESTRICTED-ACCESS COLUMNS】—— 本表的【所有金额列都是个人薪酬】
-- ════════════════════════════════════════════════════════════════════════════
--   gross_pay / employer_cpf / employee_cpf / other_deductions / net_pay
-- 受《个人数据保护法》(PDPA)与公司手册约束;employee_directory 视图派生出的
-- current_gross_pay / current_pay_period 同样受限。权限切次按这张单子设策略。
-- ════════════════════════════════════════════════════════════════════════════
--
-- 数字【全部来自外包服务商】;本系统记录并过账,从不自己算 CPF 或个税。
-- upsert_payroll_period 唯一做的算术是校验服务商给的行自洽
-- (net = gross − 员工CPF − 其它扣款,否则 LINE_NOT_BALANCED)——
-- 那不是在算工资,是在把录错/解析错的一行挡在总账之外。
-- 金额是【周期币种】的原币(见 payroll_periods.currency / fx_rate)。
-- ON DELETE CASCADE:明细依附于周期,重导时整批替换。
--
-- NOTE: introduced by db/migrations/2026-08-01-hr1a-hr-core.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.payroll_lines (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    payroll_period_id uuid NOT NULL REFERENCES public.payroll_periods (id) ON DELETE CASCADE,
    employee_id       uuid NOT NULL REFERENCES public.employees (id),
    gross_pay         numeric NOT NULL CHECK (gross_pay >= 0),                    -- RESTRICTED
    employer_cpf      numeric NOT NULL DEFAULT 0 CHECK (employer_cpf >= 0),       -- RESTRICTED
    employee_cpf      numeric NOT NULL DEFAULT 0 CHECK (employee_cpf >= 0),       -- RESTRICTED
    other_deductions  numeric NOT NULL DEFAULT 0 CHECK (other_deductions >= 0),   -- RESTRICTED
    net_pay           numeric NOT NULL CHECK (net_pay >= 0),                      -- RESTRICTED
    notes             text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (payroll_period_id, employee_id)
);

CREATE INDEX idx_payroll_lines_period ON public.payroll_lines (payroll_period_id);
CREATE INDEX idx_payroll_lines_employee ON public.payroll_lines (employee_id);

ALTER TABLE public.payroll_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "payroll_lines select by permission"
    ON public.payroll_lines
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text));

CREATE POLICY "payroll_lines insert by permission"
    ON public.payroll_lines
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'::text));

CREATE POLICY "payroll_lines update by permission"
    ON public.payroll_lines
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit'::text)) WITH CHECK (has_permission('module.hr.edit'::text));

CREATE POLICY "payroll_lines delete by permission"
    ON public.payroll_lines
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'::text));

-- cut 2b 字段级遮蔽:收回原始敏感列。表级 SELECT 授权【蕴含所有列】,
-- 所以必须先整表收回,再把非敏感列逐列授回。敏感列只能经 payroll_lines_masked 读取。
-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
REVOKE SELECT ON public.payroll_lines FROM authenticated, anon;
GRANT SELECT (id, payroll_period_id, employee_id, notes, created_at)
    ON public.payroll_lines TO authenticated;
