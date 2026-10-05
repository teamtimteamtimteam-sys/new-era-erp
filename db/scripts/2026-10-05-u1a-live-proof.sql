-- db/scripts/2026-10-05-u1a-live-proof.sql
-- U1-A · 线上的匿名化证明(Tim 的 UNBLOCK-1 Q11)—— 一笔事务、整笔 ROLLBACK,只动它自己建的那一个员工与他的四类单据。
--   在这笔事务里:建一个已离职的测试员工(ZZ-U1A-PROOF),给他一张调薪申请、一行工资(在一个本支自建的工资期里)、一张请假单、一张医疗报销,
--   每一样都带一段只属于他的字(U1A-PROOF-SECRET),再各改一次(让变更记录里有 INSERT 与 UPDATE 两种影像);保留期设成 12 个月;
--   以 admin@ 的会话(持 action.anonymise_employee)匿名化他 —— 然后断言:表里那几段字擦掉了、金额一分不动;变更记录里那几行
--   一个 "U1A-PROOF-SECRET" 都不剩、金额还在、redacted_at 都盖上了。断言失败 = 抛;最后一句 SELECT 把读数带回来;整笔回滚。
-- ★ 不碰任何一张在这之前就有的单据(Tim 的常设约束,连回滚的事务里也不许):每一个被写的行都是本支在这笔事务里建的;
--   唯一改动的既有行是 hr_settings 的保留期(一个设置,不是单据)—— 随回滚消失。
-- 以 postgres 跑(Management API);匿名化那一句切成 admin@ 的 JWT(has_permission 读 JWT)。
BEGIN;
CREATE TEMP TABLE u1a_proof (k text, v text) ON COMMIT DROP;
DO $proof$
DECLARE
    v_admin uuid := '321f1819-8449-48f7-9ae0-78b2c4b50f35';   -- admin@swm-os.test(admin,持 action.anonymise_employee)
    e uuid := gen_random_uuid(); pp uuid; pl uuid; scr uuid; lv uuid; mc uuid; v_n int; v_m date; v_ccy text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    -- 一个没有任何工资期的月份(往回找),给这一行工资用
    FOR v_n IN 30..60 LOOP
        v_m := (date_trunc('month', CURRENT_DATE) - make_interval(months => v_n))::date;
        EXIT WHEN NOT EXISTS (SELECT 1 FROM payroll_periods WHERE date_trunc('month', period_month)::date = v_m);
    END LOOP;
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, employment_status, separation_date, separation_type, monthly_salary)
        VALUES (e, 'ZZ-U1A-PROOF', 'ZZ U1A Proof Person', 'full_time', 'office', v_m - 400, 'separated', v_m + 60, 'resignation', 3300);
    INSERT INTO salary_change_requests (employee_id, label, old_monthly_salary, new_monthly_salary, effective_date, reason, status, created_by, snapshot)
        VALUES (e, 'ZZ-U1A-SCR', 3000, 3300, v_m, 'U1A-PROOF-SECRET raise', 'submitted', v_admin, '{"monthly_salary": 3000}') RETURNING id INTO scr;
    UPDATE salary_change_requests SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = v_admin, withdraw_reason = 'U1A-PROOF-SECRET withdrawn' WHERE id = scr;
    INSERT INTO payroll_periods (code, period_month, payment_date, currency, fx_rate, status, notes)
        VALUES ('ZZ-U1A-PAY', v_m, v_m + 27, v_ccy, 1, 'draft', 'u1a proof') RETURNING id INTO pp;
    INSERT INTO payroll_lines (payroll_period_id, employee_id, gross_pay, employer_cpf, employee_cpf, other_deductions, net_pay, notes)
        VALUES (pp, e, 3300, 0, 0, 0, 3300, 'U1A-PROOF-SECRET pay note') RETURNING id INTO pl;
    UPDATE payroll_lines SET notes = 'U1A-PROOF-SECRET pay note (2)' WHERE id = pl;
    INSERT INTO leave_requests (code, employee_id, leave_type_code, start_date, end_date, days, reason, certificate_ref, status, decided_at, decided_by, decision_notes)
        VALUES ('ZZ-U1A-LV', e, 'unpaid', v_m + 3, v_m + 3, 1, 'U1A-PROOF-SECRET reason', 'U1A-PROOF-SECRET-CERT', 'approved', now(), v_admin, 'U1A-PROOF-SECRET note')
        RETURNING id INTO lv;
    UPDATE leave_requests SET reason = 'U1A-PROOF-SECRET reason (2)' WHERE id = lv;
    INSERT INTO medical_claims (code, employee_id, claim_date, claim_year, amount_sgd, description, receipt_ref, status, decided_at, decided_by, decision_notes)
        VALUES ('ZZ-U1A-MC', e, v_m + 3, extract(year from v_m + 3)::int, 120, 'U1A-PROOF-SECRET diagnosis', 'U1A-PROOF-SECRET-RC', 'approved', now(), v_admin, 'U1A-PROOF-SECRET claim note')
        RETURNING id INTO mc;
    UPDATE medical_claims SET description = 'U1A-PROOF-SECRET diagnosis (2)' WHERE id = mc;
    UPDATE hr_settings SET personal_data_retention_months = 12;

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_admin), true);
    PERFORM anonymise_employee(e, 'U1-A live proof (rolled back)');
    PERFORM set_config('request.jwt.claims', '', true);

    -- 表里
    IF EXISTS (SELECT 1 FROM salary_change_requests WHERE id = scr AND (reason <> 'ANONYMISED' OR withdraw_reason IS NOT NULL))
       OR EXISTS (SELECT 1 FROM payroll_lines WHERE id = pl AND notes IS NOT NULL)
       OR EXISTS (SELECT 1 FROM leave_requests WHERE id = lv AND (reason IS NOT NULL OR certificate_ref IS NOT NULL OR decision_notes IS NOT NULL))
       OR EXISTS (SELECT 1 FROM medical_claims WHERE id = mc AND (description IS NOT NULL OR receipt_ref IS NOT NULL OR decision_notes IS NOT NULL)) THEN
        RAISE EXCEPTION 'U1A_LIVE_PROOF|free text left in a table';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM salary_change_requests WHERE id = scr AND old_monthly_salary = 3000 AND new_monthly_salary = 3300)
       OR NOT EXISTS (SELECT 1 FROM payroll_lines WHERE id = pl AND gross_pay = 3300 AND net_pay = 3300)
       OR NOT EXISTS (SELECT 1 FROM leave_requests WHERE id = lv AND days = 1)
       OR NOT EXISTS (SELECT 1 FROM medical_claims WHERE id = mc AND amount_sgd = 120) THEN
        RAISE EXCEPTION 'U1A_LIVE_PROOF|an amount moved';
    END IF;
    -- 记录里
    SELECT count(*) INTO v_n FROM change_log c
     WHERE (c.table_name, c.row_key ->> 'id') IN (('salary_change_requests', scr::text), ('payroll_lines', pl::text), ('leave_requests', lv::text), ('medical_claims', mc::text));
    INSERT INTO u1a_proof VALUES ('change-log rows of the four documents', v_n::text);
    IF v_n < 8 THEN RAISE EXCEPTION 'U1A_LIVE_PROOF|expected at least 8 change-log rows, found %', v_n; END IF;
    SELECT count(*) INTO v_n FROM change_log c
     WHERE (c.table_name, c.row_key ->> 'id') IN (('salary_change_requests', scr::text), ('payroll_lines', pl::text), ('leave_requests', lv::text), ('medical_claims', mc::text))
       AND (position('U1A-PROOF-SECRET' in COALESCE(c.old::text, '') || COALESCE(c.new::text, '')) > 0 OR c.redacted_at IS NULL);
    INSERT INTO u1a_proof VALUES ('change-log rows still carrying text or unredacted', v_n::text);
    IF v_n <> 0 THEN RAISE EXCEPTION 'U1A_LIVE_PROOF|% change-log row(s) still carry the text or were not redacted', v_n; END IF;
    INSERT INTO u1a_proof
    SELECT 'kept in the log: ' || c.table_name, string_agg(DISTINCT
             CASE c.table_name WHEN 'medical_claims' THEN 'amount_sgd ' || (c.new ->> 'amount_sgd')
                               WHEN 'payroll_lines' THEN 'gross_pay ' || (c.new ->> 'gross_pay')
                               WHEN 'salary_change_requests' THEN 'new_monthly_salary ' || (c.new ->> 'new_monthly_salary')
                               ELSE 'days ' || (c.new ->> 'days') END, ', ')
      FROM change_log c
     WHERE (c.table_name, c.row_key ->> 'id') IN (('salary_change_requests', scr::text), ('payroll_lines', pl::text), ('leave_requests', lv::text), ('medical_claims', mc::text))
       AND c.op = 'INSERT'
     GROUP BY c.table_name;
    INSERT INTO u1a_proof VALUES ('table text erased, amounts kept', 'yes');
END;
$proof$;
SELECT k, v FROM u1a_proof ORDER BY k;
ROLLBACK;
