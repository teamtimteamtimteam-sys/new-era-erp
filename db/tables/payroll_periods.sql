-- db/tables/payroll_periods.sql
-- 工资周期(每月一张)。
--
-- 【工资是外包的】服务商算好一切发过来;本系统【只记录并过账】,自己不算 CPF、
-- 不算个税、不算一分钱。合计列是明细行的汇总,由 upsert_payroll_period 维护。
--
--   * period_month 存【当月 1 号】;在册周期一个月只能有一张(部分唯一索引);
--   * 金额都是 currency 的原币,USD 侧由分录按 fx_rate 换算;
--   * status 'posted' 后不能重导明细、不能软删(见 guard_payroll_period_delete
--     与 upsert_payroll_period 的 PAYROLL_POSTED)—— 总账已经认了这批数,
--     要改先 unpost_payroll_period(冲销分录并退回草稿)。
--   * source_note 记服务商文件/批次的出处,对账时要能追回原始文件。
--
-- NOTE: introduced by db/migrations/2026-08-01-hr1a-hr-core.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.payroll_periods (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                   text NOT NULL UNIQUE,  -- gapless 'PAY-YYYY-NNNN'
    period_month           date NOT NULL,         -- 当月 1 号
    payment_date           date NOT NULL,
    currency               text NOT NULL DEFAULT 'SGD' REFERENCES public.currencies (code),
    fx_rate                numeric NOT NULL CHECK (fx_rate > 0),
    status                 text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','posted')),
    gross_total            numeric NOT NULL DEFAULT 0,
    employer_cpf_total     numeric NOT NULL DEFAULT 0,
    employee_cpf_total     numeric NOT NULL DEFAULT 0,
    other_deductions_total numeric NOT NULL DEFAULT 0,
    net_pay_total          numeric NOT NULL DEFAULT 0,
    journal_entry_id       uuid REFERENCES public.journal_entries (id),
    source_note            text,
    notes                  text,
    deleted_at             timestamptz,
    created_at             timestamptz NOT NULL DEFAULT now(),
    created_by             uuid DEFAULT auth.uid(),
    updated_at             timestamptz NOT NULL DEFAULT now(),
    updated_by             uuid DEFAULT auth.uid()
);

CREATE UNIQUE INDEX idx_payroll_periods_month_live
    ON public.payroll_periods (period_month) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_payroll_periods_updated_at
    BEFORE UPDATE ON public.payroll_periods
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- 已过账的周期不能软删 —— 总账里已经有它了,删掉单据只会让账实不符
CREATE OR REPLACE FUNCTION public.guard_payroll_period_delete()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL AND OLD.status = 'posted' THEN
        RAISE EXCEPTION 'PAYROLL_POSTED|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_payroll_periods_no_delete_posted
    BEFORE UPDATE OF deleted_at ON public.payroll_periods
    FOR EACH ROW EXECUTE FUNCTION public.guard_payroll_period_delete();

ALTER TABLE public.payroll_periods ENABLE ROW LEVEL SECURITY;
CREATE POLICY "payroll_periods select by permission"
    ON public.payroll_periods
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text));

CREATE POLICY "payroll_periods insert by permission"
    ON public.payroll_periods
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'::text));

CREATE POLICY "payroll_periods update by permission"
    ON public.payroll_periods
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit'::text)) WITH CHECK (has_permission('module.hr.edit'::text));

CREATE POLICY "payroll_periods delete by permission"
    ON public.payroll_periods
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'::text));
