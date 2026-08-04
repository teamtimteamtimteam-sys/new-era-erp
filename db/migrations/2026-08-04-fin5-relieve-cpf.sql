-- db/migrations/2026-08-04-fin5-relieve-cpf.sql
-- FIN-5:2400 CPF 应付与 2200 里的代扣款终于借得动了。
-- 全类扫描(A3)结论:2000 健康(payment/prepayment 借);2100 无自动过账(GST 引擎未建);
-- 2300 自带借方(FIN-4);2400 与 2200(payroll 侧)= 同一缺陷,本切修;
-- 2200 的加工成本应计【同样无结算路径】—— 点名留档,另切(要先定供应商/发票形状)。
-- 形状规则(与 FIN-4 相反而一致):照着对账单记 —— CPF 一笔汇款一行银行行。
BEGIN;

ALTER TABLE public.payroll_periods ADD COLUMN cpf_paid_at date;
ALTER TABLE public.payroll_periods ADD COLUMN cpf_journal_entry_id uuid REFERENCES public.journal_entries (id);
ALTER TABLE public.payroll_periods ADD COLUMN deductions_paid_at date;
ALTER TABLE public.payroll_periods ADD COLUMN deductions_journal_entry_id uuid REFERENCES public.journal_entries (id);


CREATE OR REPLACE FUNCTION public.pay_payroll_cpf(p_payroll_period_id uuid, p_payment_date date DEFAULT NULL::date, p_bank_account text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p    payroll_periods%ROWTYPE;
    v_cpf  numeric;
    v_bank text;
    v_date date;
    v_je   jsonb;
BEGIN
    IF NOT (has_permission('module.finance.edit') OR has_permission('module.hr.edit')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.edit';
    END IF;
    SELECT * INTO v_p FROM payroll_periods WHERE id = p_payroll_period_id FOR UPDATE;
    IF NOT FOUND OR v_p.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(p_payroll_period_id::text, '?');
    END IF;
    IF v_p.status <> 'posted' THEN
        RAISE EXCEPTION 'PAYROLL_NOT_POSTED|%', v_p.code;
    END IF;
    IF v_p.cpf_paid_at IS NOT NULL THEN
        RAISE EXCEPTION 'PAYROLL_CPF_ALREADY_PAID|%', v_p.code;
    END IF;
    v_cpf := round(COALESCE(v_p.employer_cpf_total, 0) + COALESCE(v_p.employee_cpf_total, 0), 2);
    IF v_cpf <= 0 THEN
        RAISE EXCEPTION 'PAYROLL_NOTHING_TO_PAY|%', v_p.code;
    END IF;
    v_bank := COALESCE(p_bank_account, '1000');
    IF v_bank NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', v_bank;
    END IF;
    v_date := COALESCE(p_payment_date, CURRENT_DATE);

    v_je := post_journal_entry(v_date, 'CPF ' || v_p.code, 'payroll', v_p.id,
        jsonb_build_array(
            jsonb_build_object('account_code', '2400', 'side', 'debit',
                'currency', 'SGD', 'amount_ccy', v_cpf, 'fx_rate', 1,
                'line_memo', 'CPF for ' || v_p.code),
            jsonb_build_object('account_code', v_bank, 'side', 'credit',
                'currency', 'SGD', 'amount_ccy', v_cpf, 'fx_rate', 1,
                'line_memo', 'CPF Board')));

    UPDATE payroll_periods
    SET cpf_paid_at = v_date, cpf_journal_entry_id = (v_je->>'entry_id')::uuid
    WHERE id = v_p.id;

    RETURN jsonb_build_object('journal_code', v_je->>'code', 'cpf_paid', v_cpf,
                              'period', v_p.code, 'paid_on', v_date);
END;
$function$;

CREATE OR REPLACE FUNCTION public.pay_payroll_deductions(p_payroll_period_id uuid, p_payment_date date DEFAULT NULL::date, p_bank_account text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p    payroll_periods%ROWTYPE;
    v_amt  numeric;
    v_bank text;
    v_date date;
    v_je   jsonb;
BEGIN
    IF NOT (has_permission('module.finance.edit') OR has_permission('module.hr.edit')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.edit';
    END IF;
    SELECT * INTO v_p FROM payroll_periods WHERE id = p_payroll_period_id FOR UPDATE;
    IF NOT FOUND OR v_p.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(p_payroll_period_id::text, '?');
    END IF;
    IF v_p.status <> 'posted' THEN
        RAISE EXCEPTION 'PAYROLL_NOT_POSTED|%', v_p.code;
    END IF;
    IF v_p.deductions_paid_at IS NOT NULL THEN
        RAISE EXCEPTION 'PAYROLL_DEDUCTIONS_ALREADY_PAID|%', v_p.code;
    END IF;
    v_amt := round(COALESCE(v_p.other_deductions_total, 0), 2);
    IF v_amt <= 0 THEN
        RAISE EXCEPTION 'PAYROLL_NOTHING_TO_PAY|%', v_p.code;
    END IF;
    v_bank := COALESCE(p_bank_account, '1000');
    IF v_bank NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', v_bank;
    END IF;
    v_date := COALESCE(p_payment_date, CURRENT_DATE);

    v_je := post_journal_entry(v_date, 'Payroll deductions ' || v_p.code, 'payroll', v_p.id,
        jsonb_build_array(
            jsonb_build_object('account_code', '2200', 'side', 'debit',
                'currency', 'SGD', 'amount_ccy', v_amt, 'fx_rate', 1,
                'line_memo', 'Deductions for ' || v_p.code),
            jsonb_build_object('account_code', v_bank, 'side', 'credit',
                'currency', 'SGD', 'amount_ccy', v_amt, 'fx_rate', 1)));

    UPDATE payroll_periods
    SET deductions_paid_at = v_date, deductions_journal_entry_id = (v_je->>'entry_id')::uuid
    WHERE id = v_p.id;

    RETURN jsonb_build_object('journal_code', v_je->>'code', 'deductions_paid', v_amt,
                              'period', v_p.code, 'paid_on', v_date);
END;
$function$;

CREATE OR REPLACE FUNCTION public.unpost_payroll_period(p_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_p    record;
    v_je   jsonb;
BEGIN
    PERFORM require_permission('module.hr.edit');
    SELECT * INTO v_p FROM payroll_periods
    WHERE id = p_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(p_id::text, '?');
    END IF;
    IF v_p.status <> 'posted' THEN
        RAISE EXCEPTION 'PAYROLL_NOT_POSTED|%', v_p.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;
    -- FIN-4:已有工资行付了钱,冲销周期会让那些结算变孤儿 —— 拒绝,先冲付款
    IF EXISTS (SELECT 1 FROM payroll_lines
               WHERE payroll_period_id = p_id AND paid_at IS NOT NULL) THEN
        RAISE EXCEPTION 'PAYROLL_LINES_PAID|%', v_p.code;
    END IF;
    -- FIN-5:CPF / 代扣款已汇出的期间同理 —— 先冲那笔汇款
    IF v_p.cpf_paid_at IS NOT NULL THEN
        RAISE EXCEPTION 'PAYROLL_CPF_PAID|%', v_p.code;
    END IF;
    IF v_p.deductions_paid_at IS NOT NULL THEN
        RAISE EXCEPTION 'PAYROLL_DEDUCTIONS_PAID|%', v_p.code;
    END IF;

    -- 冲销分录(冲销日 = 今天);原分录留在账上并被标记为已冲销 —— 不删账
    v_je := reverse_journal_entry_internal(v_p.journal_entry_id, CURRENT_DATE, 'Payroll reversal ' || v_p.code);

    UPDATE payroll_periods
    SET status = 'draft',
        journal_entry_id = NULL,
        notes = COALESCE(notes || E'\n', '')
                || '[' || to_char(now(), 'YYYY-MM-DD HH24:MI') || ' unposted] ' || btrim(p_reason),
        updated_by = v_user
    WHERE id = p_id;

    RETURN jsonb_build_object(
        'payroll_period_id', p_id,
        'code', v_p.code,
        'status', 'draft',
        'reversal_journal_code', v_je->>'code'
    );
END;
$function$;

CREATE OR REPLACE VIEW public.hr_alerts
WITH (security_invoker = on) AS
 SELECT 'work_pass_expiry'::text AS alert_type,
        CASE
            WHEN e.work_pass_expiry_date < CURRENT_DATE THEN 'expired'::text
            WHEN (e.work_pass_expiry_date - CURRENT_DATE) <= 30 THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    COALESCE(e.work_pass_type, 'Work pass'::text) AS subject,
    e.work_pass_expiry_date AS due_date,
    e.work_pass_expiry_date - CURRENT_DATE AS days_remaining
   FROM employees e
  WHERE e.deleted_at IS NULL AND e.employment_status <> 'separated'::text AND e.work_pass_expiry_date IS NOT NULL AND (e.work_pass_expiry_date - CURRENT_DATE) <= 90 AND (e.work_pass_expiry_date - CURRENT_DATE) >= '-30'::integer
UNION ALL
 SELECT 'probation_ending'::text AS alert_type,
        CASE
            WHEN (e.probation_end_date - CURRENT_DATE) <= 14 THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    'Probation'::text AS subject,
    e.probation_end_date AS due_date,
    e.probation_end_date - CURRENT_DATE AS days_remaining
   FROM employees e
  WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text AND e.probation_end_date IS NOT NULL AND e.probation_end_date >= CURRENT_DATE AND (e.probation_end_date - CURRENT_DATE) <= 30 AND NOT (EXISTS ( SELECT 1
           FROM performance_reviews r
          WHERE r.employee_id = e.id AND r.review_type = 'probation'::text AND (r.status = ANY (ARRAY['approved'::text, 'acknowledged'::text])) AND r.probation_outcome = 'confirm'::text))
UNION ALL
 SELECT 'probation_overdue'::text AS alert_type,
    'expired'::text AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    'Probation ended without a decision'::text AS subject,
    e.probation_end_date AS due_date,
    e.probation_end_date - CURRENT_DATE AS days_remaining
   FROM employees e
  WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text AND e.probation_end_date IS NOT NULL AND e.probation_end_date < CURRENT_DATE AND NOT (EXISTS ( SELECT 1
           FROM performance_reviews r
          WHERE r.employee_id = e.id AND r.review_type = 'probation'::text AND (r.status = ANY (ARRAY['approved'::text, 'acknowledged'::text])) AND r.probation_outcome IS NOT NULL))
UNION ALL
 SELECT 'probation_not_confirmed'::text AS alert_type,
    'expired'::text AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    'Probation not confirmed — separation is a manual decision'::text AS subject,
    COALESCE(e.probation_end_date, r.approved_at::date) AS due_date,
    COALESCE(e.probation_end_date, r.approved_at::date) - CURRENT_DATE AS days_remaining
   FROM employees e
     JOIN performance_reviews r ON r.employee_id = e.id
  WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text AND r.review_type = 'probation'::text AND (r.status = ANY (ARRAY['approved'::text, 'acknowledged'::text])) AND r.probation_outcome = 'not_confirm'::text
UNION ALL
 SELECT 'salary_not_set'::text AS alert_type,
        CASE
            WHEN e.employment_status = 'notice'::text THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    'Monthly fixed gross not set — leave encashment cannot be computed'::text AS subject,
    NULL::date AS due_date,
    NULL::integer AS days_remaining
   FROM employees e
  WHERE e.deleted_at IS NULL AND (e.employment_status = ANY (ARRAY['probation'::text, 'active'::text, 'notice'::text])) AND NOT e.monthly_salary_set
UNION ALL
 SELECT 'review_no_reviewer'::text AS alert_type,
    'critical'::text AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    COALESCE(c.name, 'Probation review'::text) || ' — no reviewer assigned'::text AS subject,
    c.due_date,
    c.due_date - CURRENT_DATE AS days_remaining
   FROM performance_reviews r
     JOIN employees e ON e.id = r.employee_id
     LEFT JOIN review_cycles c ON c.id = r.cycle_id
  WHERE r.reviewer_employee_id IS NULL AND (r.status <> ALL (ARRAY['approved'::text, 'acknowledged'::text, 'void'::text])) AND e.deleted_at IS NULL
UNION ALL
 SELECT 'review_cycle_overdue'::text AS alert_type,
    'critical'::text AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    c.name AS subject,
    c.due_date,
    c.due_date - CURRENT_DATE AS days_remaining
   FROM performance_reviews r
     JOIN review_cycles c ON c.id = r.cycle_id
     JOIN employees e ON e.id = r.employee_id
  WHERE c.deleted_at IS NULL AND c.status = 'open'::text AND c.due_date < CURRENT_DATE AND (r.status = ANY (ARRAY['draft'::text, 'self_review'::text]))
UNION ALL
 SELECT 'cpf_due'::text AS alert_type,
        CASE
            WHEN (date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date < CURRENT_DATE THEN 'expired'::text
            WHEN ((date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date - CURRENT_DATE) <= 3 THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    NULL::uuid AS employee_id,
    p.code AS employee_code,
    'CPF'::text AS employee_name,
    'CPF contribution unpaid — due 14th of the following month, late payment attracts interest'::text AS subject,
    (date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date AS due_date,
    (date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date - CURRENT_DATE AS days_remaining
   FROM payroll_periods p
  WHERE p.deleted_at IS NULL AND p.status = 'posted'::text AND p.cpf_paid_at IS NULL AND (COALESCE(p.employer_cpf_total, 0::numeric) + COALESCE(p.employee_cpf_total, 0::numeric)) > 0::numeric AND ((date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date - CURRENT_DATE) <= 7
UNION ALL
 SELECT 'training_expiry'::text AS alert_type,
        CASE
            WHEN t.expiry_date < CURRENT_DATE THEN 'expired'::text
            WHEN (t.expiry_date - CURRENT_DATE) <= 30 THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    t.training_name AS subject,
    t.expiry_date AS due_date,
    t.expiry_date - CURRENT_DATE AS days_remaining
   FROM training_records t
     JOIN employees e ON e.id = t.employee_id
  WHERE t.deleted_at IS NULL AND e.deleted_at IS NULL AND e.employment_status <> 'separated'::text AND t.expiry_date IS NOT NULL AND (t.expiry_date - CURRENT_DATE) <= 90 AND (t.expiry_date - CURRENT_DATE) >= '-30'::integer;

REVOKE EXECUTE ON FUNCTION public.pay_payroll_cpf(uuid, date, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.pay_payroll_deductions(uuid, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pay_payroll_cpf(uuid, date, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.pay_payroll_deductions(uuid, date, text) TO authenticated, service_role;

COMMIT;
