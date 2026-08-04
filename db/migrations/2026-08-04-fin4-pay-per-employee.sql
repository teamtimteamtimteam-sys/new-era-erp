-- db/migrations/2026-08-04-fin4-pay-per-employee.sql
-- FIN-4:发薪逐人付,账要和对账单一行对一行。
-- 过账不再碰银行(净额挂新科目 2300 应付净薪);pay_payroll_lines 逐人贷银行,
-- 一人一条,各自认领自己的对账单行。周期已有已付行时不许冲销(先冲付款)。
BEGIN;

INSERT INTO public.accounts (code, name_en, name_zh, account_type, is_system, is_monetary) VALUES
    ('2300', 'Net Salary Payable', '应付净薪', 'liability', true, true);

ALTER TABLE public.payroll_lines ADD COLUMN paid_at timestamptz;
ALTER TABLE public.payroll_lines ADD COLUMN paid_journal_entry_id uuid REFERENCES public.journal_entries (id);
GRANT SELECT (paid_at, paid_journal_entry_id) ON public.payroll_lines TO authenticated;

CREATE POLICY "payroll_lines select for reconciliation"
    ON public.payroll_lines
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text) AND has_permission('data.view_pay'::text));

DROP VIEW IF EXISTS public.payroll_lines_masked CASCADE;

CREATE VIEW public.payroll_lines_masked WITH (security_invoker = off) AS
 SELECT id,
    payroll_period_id,
    employee_id,
        CASE
            WHEN has_permission('data.view_pay'::text) OR employee_id = current_user_employee() THEN gross_pay
            ELSE NULL::numeric
        END AS gross_pay,
        CASE
            WHEN has_permission('data.view_pay'::text) OR employee_id = current_user_employee() THEN employer_cpf
            ELSE NULL::numeric
        END AS employer_cpf,
        CASE
            WHEN has_permission('data.view_pay'::text) OR employee_id = current_user_employee() THEN employee_cpf
            ELSE NULL::numeric
        END AS employee_cpf,
        CASE
            WHEN has_permission('data.view_pay'::text) OR employee_id = current_user_employee() THEN other_deductions
            ELSE NULL::numeric
        END AS other_deductions,
        CASE
            WHEN has_permission('data.view_pay'::text) OR employee_id = current_user_employee() THEN net_pay
            ELSE NULL::numeric
        END AS net_pay,
    notes,
    created_at,
    paid_at,
    paid_journal_entry_id
   FROM payroll_lines
  WHERE has_permission('module.hr.view'::text) OR employee_id = current_user_employee() OR has_permission('module.finance.view'::text) AND has_permission('data.view_pay'::text);

CREATE VIEW public.employee_directory WITH (security_invoker = on) AS
 SELECT e.id AS employee_id,
    e.code,
    e.legal_name,
    e.preferred_name,
    e.department_id,
    d.name_en AS department_name_en,
    d.name_zh AS department_name_zh,
    e.job_title,
    e.manager_id,
    mgr.code AS manager_code,
    mgr.legal_name AS manager_name,
    e.employment_type,
    e.work_category,
    e.employment_status,
    e.hire_date,
    e.probation_end_date,
    e.annual_leave_rate_days,
    e.annual_leave_accrued_days,
    e.annual_leave_available_days,
    e.residency_status,
    e.work_pass_type,
    e.work_pass_expiry_date,
        CASE
            WHEN e.work_pass_expiry_date IS NULL THEN NULL::integer
            ELSE e.work_pass_expiry_date - CURRENT_DATE
        END AS days_to_work_pass_expiry,
        CASE
            WHEN e.work_pass_expiry_date IS NULL THEN NULL::text
            WHEN e.work_pass_expiry_date < CURRENT_DATE THEN 'expired'::text
            WHEN (e.work_pass_expiry_date - CURRENT_DATE) <= 30 THEN 'critical'::text
            WHEN (e.work_pass_expiry_date - CURRENT_DATE) <= 90 THEN 'warning'::text
            ELSE NULL::text
        END AS work_pass_alert,
    pay.gross_pay AS current_gross_pay,
    pay.period_month AS current_pay_period,
    COALESCE(tr.training_count, 0::bigint) AS training_count
   FROM employees_masked e
     LEFT JOIN departments d ON d.id = e.department_id
     LEFT JOIN employees_masked mgr ON mgr.id = e.manager_id
     LEFT JOIN LATERAL ( SELECT pl.gross_pay,
            pp.period_month
           FROM payroll_lines_masked pl
             JOIN payroll_periods pp ON pp.id = pl.payroll_period_id
          WHERE pl.employee_id = e.id AND pp.status = 'posted'::text AND pp.deleted_at IS NULL
          ORDER BY pp.period_month DESC
         LIMIT 1) pay ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS training_count
           FROM training_records t
          WHERE t.employee_id = e.id AND t.deleted_at IS NULL) tr ON true
  WHERE e.deleted_at IS NULL;

CREATE OR REPLACE FUNCTION public.post_payroll_period(p_payroll_period_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_p     record;
    v_bank  text;
    v_lines jsonb := '[]'::jsonb;
    v_je    jsonb;
    v_cpf   numeric;
BEGIN
    PERFORM require_permission('module.hr.edit');
    SELECT * INTO v_p FROM payroll_periods
    WHERE id = p_payroll_period_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(p_payroll_period_id::text, '?');
    END IF;
    IF v_p.status = 'posted' THEN
        RAISE EXCEPTION 'PAYROLL_ALREADY_POSTED|%', v_p.code;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM payroll_lines WHERE payroll_period_id = p_payroll_period_id) THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    -- FIN-4:过账【不碰银行】—— 钱还没出去。净额挂 2300 应付净薪,
    -- 逐人付款(pay_payroll_lines)时才贷银行,一人一条,各自对账。
    IF v_p.currency NOT IN ('SGD','USD') THEN
        RAISE EXCEPTION 'PAYROLL_CURRENCY_UNSUPPORTED|%', v_p.currency;
    END IF;

    -- 借 6100 工资薪金(服务商口径的 gross)
    IF v_p.gross_total > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '6100', 'side', 'debit', 'currency', v_p.currency,
            'amount_ccy', v_p.gross_total, 'fx_rate', v_p.fx_rate);
    END IF;
    -- 借 6110 公积金-雇主部分(公司成本,不从员工工资里出)
    IF v_p.employer_cpf_total > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '6110', 'side', 'debit', 'currency', v_p.currency,
            'amount_ccy', v_p.employer_cpf_total, 'fx_rate', v_p.fx_rate);
    END IF;
    -- 贷 2400 公积金应付:雇主 + 员工两侧合计,汇给公积金局之前都欠着
    v_cpf := round(COALESCE(v_p.employer_cpf_total, 0) + COALESCE(v_p.employee_cpf_total, 0), 2);
    IF v_cpf > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '2400', 'side', 'credit', 'currency', v_p.currency,
            'amount_ccy', v_cpf, 'fx_rate', v_p.fx_rate);
    END IF;
    -- 贷 2200 应计费用:服务商【代公司扣下】的其它款项,在汇出去之前挂在这里。
    -- 【注意区分】如果某项扣款本质上是"公司成本变少"(而不是替员工代扣代缴),
    -- 那它就不该出现在这里 —— 应该让服务商把它并进 gross 里去。
    IF v_p.other_deductions_total > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '2200', 'side', 'credit', 'currency', v_p.currency,
            'amount_ccy', v_p.other_deductions_total, 'fx_rate', v_p.fx_rate);
    END IF;
    -- 贷 2300 应付净薪:实发净额,付给每个人之前都欠着
    IF v_p.net_pay_total > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '2300', 'side', 'credit', 'currency', v_p.currency,
            'amount_ccy', v_p.net_pay_total, 'fx_rate', v_p.fx_rate);
    END IF;

    -- 期间锁在 post_journal_entry 内生效(PERIOD_LOCKED 原样上抛)
    v_je := post_journal_entry(
        v_p.payment_date,
        'Payroll ' || v_p.code,
        'payroll',
        v_p.id,
        v_lines
    );

    UPDATE payroll_periods
    SET status = 'posted', journal_entry_id = (v_je->>'entry_id')::uuid, updated_by = v_user
    WHERE id = p_payroll_period_id;

    RETURN jsonb_build_object(
        'payroll_period_id', p_payroll_period_id,
        'code', v_p.code,
        'journal_code', v_je->>'code',
        'gross_total', v_p.gross_total,
        'employer_cpf_total', v_p.employer_cpf_total,
        'employee_cpf_total', v_p.employee_cpf_total,
        'net_pay_total', v_p.net_pay_total
    );
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

CREATE OR REPLACE FUNCTION public.pay_payroll_lines(p_payroll_period_id uuid, p_line_ids uuid[], p_payment_date date DEFAULT NULL::date, p_bank_account text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p     payroll_periods%ROWTYPE;
    v_bank  text;
    v_date  date;
    v_total numeric := 0;
    v_lines jsonb := '[]'::jsonb;
    v_l     record;
    v_n     integer := 0;
    v_je    jsonb;
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
    IF p_line_ids IS NULL OR array_length(p_line_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    v_bank := COALESCE(p_bank_account, CASE v_p.currency WHEN 'SGD' THEN '1000' ELSE '1010' END);
    IF v_bank NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', v_bank;
    END IF;
    v_date := COALESCE(p_payment_date, CURRENT_DATE);

    FOR v_l IN
        SELECT pl.id, pl.net_pay, pl.paid_at, e.code AS emp_code, e.legal_name
        FROM payroll_lines pl
        JOIN employees e ON e.id = pl.employee_id
        WHERE pl.id = ANY (p_line_ids)
        ORDER BY e.code
        FOR UPDATE OF pl
    LOOP
        IF NOT EXISTS (SELECT 1 FROM payroll_lines x
                       WHERE x.id = v_l.id AND x.payroll_period_id = p_payroll_period_id) THEN
            RAISE EXCEPTION 'PAYROLL_LINE_INVALID|%', v_l.id;
        END IF;
        IF v_l.paid_at IS NOT NULL THEN
            RAISE EXCEPTION 'PAYROLL_LINE_ALREADY_PAID|%', v_l.emp_code;
        END IF;
        IF v_l.net_pay <= 0 THEN
            CONTINUE;  -- 净额为零的行没有转账,也没有对账单行
        END IF;
        -- 【一人一条银行行】备注带工号姓名,statement 上那一行就是这一条
        v_lines := v_lines || jsonb_build_object(
            'account_code', v_bank, 'side', 'credit', 'currency', v_p.currency,
            'amount_ccy', v_l.net_pay, 'fx_rate', 1,
            'line_memo', v_l.emp_code || ' ' || v_l.legal_name);
        v_total := round(v_total + v_l.net_pay, 2);
        v_n := v_n + 1;
    END LOOP;

    IF v_n = 0 THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    v_lines := jsonb_build_array(jsonb_build_object(
        'account_code', '2300', 'side', 'debit', 'currency', v_p.currency,
        'amount_ccy', v_total, 'fx_rate', 1,
        'line_memo', 'Salary run ' || v_p.code)) || v_lines;

    v_je := post_journal_entry(v_date, 'Salary payment ' || v_p.code, 'payroll',
                               p_payroll_period_id, v_lines);

    UPDATE payroll_lines
    SET paid_at = now(), paid_journal_entry_id = (v_je->>'entry_id')::uuid
    WHERE id = ANY (p_line_ids);

    RETURN jsonb_build_object('journal_code', v_je->>'code', 'entry_id', v_je->>'entry_id',
                              'lines_paid', v_n, 'total_paid', v_total);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.pay_payroll_lines(uuid, uuid[], date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pay_payroll_lines(uuid, uuid[], date, text) TO authenticated, service_role;

COMMIT;
