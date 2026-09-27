-- db/functions/salary_change_execute_internal.sql
-- APR-9(2026-09-27):让一张调薪申请【生效】—— 只从 decide_salary_change_request 的批准那一支调用。
--   1. 员工行上锁;fingerprint 再比(Q6)—— 月薪、在职状态、清空、删除有一样变了 → SALARY_CHANGED_SINCE_REQUEST|label,
--      整笔回滚,申请仍在等(CFO 驳回,或财务撤回再提)。
--   2. 生效日再判一次(Q5):提交之后那一期可能已经过账,或挂上了一张在途工资申请。
--   3. 写 employees.monthly_salary 与一行 employment_history salary_change(effective_date = 申请上的生效日;
--      old / new 两个数;created_by = 提单人 —— 说"这个人要调薪"的那个人,APR-7 Q6 同一条;批的人在申请行与留痕上)。
-- 它是属主路径:两支"直连写薪资"守卫(row_security_active = false)放它过去。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.salary_change_execute_internal(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r     salary_change_requests%ROWTYPE;
    v_emp   employees%ROWTYPE;
    v_block text;
BEGIN
    SELECT * INTO v_r FROM salary_change_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SALARY_CHANGE_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    SELECT * INTO v_emp FROM employees WHERE id = v_r.employee_id FOR UPDATE;

    IF salary_change_fingerprint(v_r.employee_id) IS DISTINCT FROM v_r.snapshot THEN
        RAISE EXCEPTION 'SALARY_CHANGED_SINCE_REQUEST|%', v_r.label;
    END IF;
    v_block := salary_effective_period_block(v_r.effective_date);
    IF v_block IS NOT NULL THEN
        RAISE EXCEPTION '%', v_block;
    END IF;

    UPDATE employees SET monthly_salary = v_r.new_monthly_salary WHERE id = v_emp.id;

    INSERT INTO employment_history
        (employee_id, effective_date, change_type, job_title, department_id,
         employment_type, employment_status, old_monthly_salary, new_monthly_salary, notes, created_by)
    SELECT e.id, v_r.effective_date, 'salary_change',
           (SELECT p.title FROM positions p WHERE p.id = e.position_id), e.department_id,
           e.employment_type, e.employment_status, v_r.old_monthly_salary, v_r.new_monthly_salary,
           format('Salary change approved with request %s', v_r.label),
           v_r.created_by
      FROM employees e WHERE e.id = v_emp.id;

    RETURN jsonb_build_object('employee_code', v_emp.code,
                              'old_monthly_salary', v_r.old_monthly_salary,
                              'new_monthly_salary', v_r.new_monthly_salary,
                              'effective_date', v_r.effective_date);
END;
$function$;
