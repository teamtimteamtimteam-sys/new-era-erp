-- db/functions/submit_salary_change_request.sql
-- APR-9(2026-09-27):财务提一张调薪申请。批准之前月薪一分不动(Tim 的矩阵 §5;grilling Q1–Q6)。
--
-- 【门】module.hr.edit + data.view_pay(Q4 —— 第一份月薪那扇门的同一对码:看不见工资的人不写工资)。
-- 【拒绝,按这个顺序】
--   EMPLOYEE_NOT_FOUND · PDPA_ALREADY_ANONYMISED|<日> · EMPLOYEE_SEPARATED|<code>
--   SALARY_CHANGE_OWN_REFUSED|<code>             给自己提(按人认:tim@ 与 admin@ 是同一个人)
--   SALARY_NOT_SET_USE_INITIAL|<code>            月薪还是 NULL —— 第一份月薪只经 set_initial_salary
--   SALARY_AMOUNT_INVALID                        NULL 或负数
--   SALARY_CHANGE_NO_CHANGE|<code>               与现在的月薪一样
--   SALARY_EFFECTIVE_DATE_REQUIRED               生效日必填,不给默认
--   SALARY_EFFECTIVE_IN_POSTED_PERIOD|<期> / SALARY_EFFECTIVE_IN_REQUESTED_PERIOD|<期>|<申请>
--   SALARY_CHANGE_REASON_REQUIRED|<code>
--   SALARY_CHANGE_OPEN|<code>|<那一张>           已有一张在途的调薪(申请,或带调薪的已提交评估)
--   SALARY_CHANGE_NO_OTHER_DECIDER|<label>       提单人之外没人批得动(pay_decision_code 路由之后)
-- 【不看审批开关】(Q3)生下来永远是 submitted;"没人批得动"也照样判(开关关着时 CFO 仍要批)。
-- 留痕:submitted,level NULL(不在按级的名册里,performance_review 同形)。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.submit_salary_change_request(p_employee_id uuid, p_new_monthly_salary numeric, p_effective_date date, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp    employees%ROWTYPE;
    v_block  text;
    v_open   text;
    v_n      integer;
    v_label  text;
    v_id     uuid := gen_random_uuid();
BEGIN
    PERFORM require_permission('module.hr.edit');
    PERFORM require_permission('data.view_pay');

    SELECT * INTO v_emp FROM employees
     WHERE id = p_employee_id AND deleted_at IS NULL
     FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;
    IF v_emp.anonymised_at IS NOT NULL THEN
        RAISE EXCEPTION 'PDPA_ALREADY_ANONYMISED|%', v_emp.anonymised_at::date;
    END IF;
    IF v_emp.employment_status = 'separated' THEN
        RAISE EXCEPTION 'EMPLOYEE_SEPARATED|%', v_emp.code;
    END IF;
    IF self_leg(NULL, v_emp.id, auth.uid()) = 'subject' THEN
        RAISE EXCEPTION 'SALARY_CHANGE_OWN_REFUSED|%', v_emp.code;
    END IF;
    IF v_emp.monthly_salary IS NULL THEN
        RAISE EXCEPTION 'SALARY_NOT_SET_USE_INITIAL|%', v_emp.code;
    END IF;
    IF p_new_monthly_salary IS NULL OR p_new_monthly_salary < 0 THEN
        RAISE EXCEPTION 'SALARY_AMOUNT_INVALID';
    END IF;
    IF p_new_monthly_salary = v_emp.monthly_salary THEN
        RAISE EXCEPTION 'SALARY_CHANGE_NO_CHANGE|%', v_emp.code;
    END IF;
    IF p_effective_date IS NULL THEN
        RAISE EXCEPTION 'SALARY_EFFECTIVE_DATE_REQUIRED';
    END IF;
    v_block := salary_effective_period_block(p_effective_date);
    IF v_block IS NOT NULL THEN
        RAISE EXCEPTION '%', v_block;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'SALARY_CHANGE_REASON_REQUIRED|%', v_emp.code;
    END IF;
    v_open := salary_change_open(v_emp.id);
    IF v_open IS NOT NULL THEN
        RAISE EXCEPTION 'SALARY_CHANGE_OPEN|%|%', v_emp.code, v_open;
    END IF;

    SELECT count(*) + 1 INTO v_n FROM salary_change_requests q WHERE q.employee_id = v_emp.id;
    v_label := v_emp.code || ' · salary change #' || v_n::text;

    IF NOT EXISTS (SELECT 1 FROM salary_change_deciders(auth.uid(), v_emp.id)) THEN
        RAISE EXCEPTION 'SALARY_CHANGE_NO_OTHER_DECIDER|%', v_label;
    END IF;

    INSERT INTO salary_change_requests (id, status, label, employee_id, old_monthly_salary, new_monthly_salary,
                                        effective_date, reason, snapshot, created_by)
    VALUES (v_id, 'submitted', v_label, v_emp.id, v_emp.monthly_salary, p_new_monthly_salary,
            p_effective_date, btrim(p_reason), salary_change_fingerprint(v_emp.id), auth.uid());

    PERFORM record_approval_decision('salary_change_request', v_id, 'submitted', NULL, NULL);

    RETURN jsonb_build_object('request_id', v_id, 'label', v_label, 'status', 'submitted',
                              'decided_via', pay_decision_code(auth.uid(), v_emp.id));
END;
$function$;
