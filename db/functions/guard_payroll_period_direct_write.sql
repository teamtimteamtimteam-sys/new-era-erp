-- db/functions/guard_payroll_period_direct_write.sql
-- PAYROLL-APR-1(2026-09-24,grilling Q5):工资期的【状态】与【已冻结的数】只走函数。
--
-- 【Step 0 实测的侧门】payroll_periods 的 UPDATE / INSERT 策略开在 module.hr.edit 上,表上
-- 【没有】管 status 的守卫。以 chooer@ 在一笔回滚的事务里直连
-- `UPDATE payroll_periods SET status = 'draft', journal_entry_id = NULL` —— 1 行,成功。
-- 反过来写成 'posted' 同样成功:一期没有分录、没有批准的工资就"过了账",付款三支函数
-- (只看 status = 'posted')照样把钱付出去。**不关这扇门,"批之前什么都不过账"就是一句假话。**
--
-- 本守卫(直连写才判,row_security_active):
--   · INSERT:status 必须是 draft,五个"过账 / 汇款"列(journal_entry_id · cpf_paid_at ·
--     cpf_journal_entry_id · deductions_paid_at · deductions_journal_entry_id)必须为空
--     → 否则 PAYROLL_STATUS_THROUGH_FUNCTION_ONLY;
--   · UPDATE:改动 status 或那五列 → PAYROLL_STATUS_THROUGH_FUNCTION_ONLY;
--   · UPDATE:期间已过账或挂着未了结的申请(payroll_period_frozen)时,改动那组【被批的数】
--     (五个合计 · 发薪日 · 币种 · 汇率 · 月份)→ PAYROLL_LINES_FROZEN;
--   · UPDATE:挂着未了结的申请时软删 → PAYROLL_REQUEST_OPEN(已过账的软删另有
--     guard_payroll_period_delete 管)。
-- 备注、出处这几列照旧归 hr.edit。所有写函数都是 SECURITY DEFINER(row_security_active = false),
-- 本守卫看不见它们;迁移与 fixture 以属主身份写,也看不见。
--
-- 【为什么是 INVOKER】要分出直连写与属主路径(guard_assay_applied_columns 同一条)。
-- 期间是否冻结经 payroll_period_frozen 问(DEFINER)—— INVOKER 里直接读 payroll_requests,
-- 一个不持 hr.view 的写入者会读到零行而静默放行。
-- NOTE: introduced by db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql.

CREATE OR REPLACE FUNCTION public.guard_payroll_period_direct_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_state text;
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.status IS DISTINCT FROM 'draft'
           OR num_nonnulls(NEW.journal_entry_id, NEW.cpf_paid_at, NEW.cpf_journal_entry_id,
                           NEW.deductions_paid_at, NEW.deductions_journal_entry_id) > 0 THEN
            RAISE EXCEPTION 'PAYROLL_STATUS_THROUGH_FUNCTION_ONLY|%', NEW.code;
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status
       OR NEW.journal_entry_id IS DISTINCT FROM OLD.journal_entry_id
       OR NEW.cpf_paid_at IS DISTINCT FROM OLD.cpf_paid_at
       OR NEW.cpf_journal_entry_id IS DISTINCT FROM OLD.cpf_journal_entry_id
       OR NEW.deductions_paid_at IS DISTINCT FROM OLD.deductions_paid_at
       OR NEW.deductions_journal_entry_id IS DISTINCT FROM OLD.deductions_journal_entry_id THEN
        RAISE EXCEPTION 'PAYROLL_STATUS_THROUGH_FUNCTION_ONLY|%', OLD.code;
    END IF;

    v_state := payroll_period_frozen(OLD.id);
    IF v_state <> 'open' THEN
        IF NEW.gross_total IS DISTINCT FROM OLD.gross_total
           OR NEW.employer_cpf_total IS DISTINCT FROM OLD.employer_cpf_total
           OR NEW.employee_cpf_total IS DISTINCT FROM OLD.employee_cpf_total
           OR NEW.other_deductions_total IS DISTINCT FROM OLD.other_deductions_total
           OR NEW.net_pay_total IS DISTINCT FROM OLD.net_pay_total
           OR NEW.payment_date IS DISTINCT FROM OLD.payment_date
           OR NEW.currency IS DISTINCT FROM OLD.currency
           OR NEW.fx_rate IS DISTINCT FROM OLD.fx_rate
           OR NEW.period_month IS DISTINCT FROM OLD.period_month THEN
            RAISE EXCEPTION 'PAYROLL_LINES_FROZEN|%|%', OLD.code, v_state;
        END IF;
        IF v_state = 'requested' AND OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
            RAISE EXCEPTION 'PAYROLL_REQUEST_OPEN|%', OLD.code;
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_payroll_period_direct_write() IS
'PAYROLL-APR-1(Tim 的 Q5):直连写(row_security_active)payroll_periods —— INSERT 不是 draft 或带着过账 / 汇款列、UPDATE 改动 status 或那五列,按名拒 PAYROLL_STATUS_THROUGH_FUNCTION_ONLY;期间已过账或挂着未了结的申请时改动被批的数(合计 · 日期 · 币种 · 汇率 · 月份)拒 PAYROLL_LINES_FROZEN,软删拒 PAYROLL_REQUEST_OPEN。INVOKER,以分出直连写与属主路径;冻结状态经 payroll_period_frozen(DEFINER)问。';
