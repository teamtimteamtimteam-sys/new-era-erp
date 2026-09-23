-- db/functions/set_initial_salary.sql
-- ROLE-1(Tim 的矩阵 · Q7,2026-09-23):**一个人的第一份月薪,由财务录一次。**
--
-- 【规则,原样】调薪只走绩效评估或调薪申请(申请那一条是 [LC],未建),由 CFO 批;
-- 对 employees.monthly_salary 的直连写一律拒绝(guard_employee_salary_write)。
-- Step 0 量出那条拒绝会造出一堵墙:线上 6 名员工的 monthly_salary【全是 NULL】,
-- 评估 0 张 —— 拒绝落地之后,就再也没有任何一条路能录下第一份工资。
-- 于是 Tim 的 Q7:**NULL → 数值只许一次,由财务录,记进 employment_history。**
-- 之后的每一次变动走评估或 [LC] 的调薪申请。
--
-- 【门】module.hr.edit(ROLE-1 起只有 finance 持有它)**且** data.view_pay ——
-- 一个看不见工资的人不该能写工资,理由与"看不见价格的人不能定价"同一条。
--
-- 【拒绝】
--   SALARY_ALREADY_SET|<code>                 已有月薪 —— 之后的变动不走这里
--   SALARY_EFFECTIVE_DATE_REQUIRED            生效日决定它落在哪个工资期:必填,不给默认
--   SALARY_EFFECTIVE_IN_POSTED_PERIOD|<期>    与 approve_review 同一条:已过账的工资期不追改
--   SALARY_AMOUNT_INVALID                     NULL 或负数
--   EMPLOYEE_NOT_FOUND / PDPA_ALREADY_ANONYMISED|<日> / EMPLOYEE_SEPARATED|<code>
--
-- 【它是属主路径】写 employees 与 employment_history 时 row_security_active = false,
-- 所以两支"直连写薪资"守卫放它过去 —— 那两支守卫拦的正是【绕过本函数】的写法。
--
-- NOTE: introduced by db/migrations/2026-09-23-role1a-the-matrix-batch-1.sql.

CREATE OR REPLACE FUNCTION public.set_initial_salary(p_employee_id uuid, p_amount numeric, p_effective_date date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp    employees%ROWTYPE;
    v_period text;
BEGIN
    PERFORM require_permission('module.hr.edit');
    PERFORM require_permission('data.view_pay');

    IF p_amount IS NULL OR p_amount < 0 THEN
        RAISE EXCEPTION 'SALARY_AMOUNT_INVALID';
    END IF;
    IF p_effective_date IS NULL THEN
        RAISE EXCEPTION 'SALARY_EFFECTIVE_DATE_REQUIRED';
    END IF;

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
    IF v_emp.monthly_salary IS NOT NULL THEN
        RAISE EXCEPTION 'SALARY_ALREADY_SET|%', v_emp.code;
    END IF;

    -- 与 approve_review 逐字同一个问法:生效日落在一个已过账的工资期里 → 拒。
    SELECT p.code INTO v_period
      FROM payroll_periods p
     WHERE p.deleted_at IS NULL AND p.status = 'posted'
       AND p_effective_date >= p.period_month
       AND p_effective_date < (p.period_month + interval '1 month')::date
     ORDER BY p.period_month
     LIMIT 1;
    IF v_period IS NOT NULL THEN
        RAISE EXCEPTION 'SALARY_EFFECTIVE_IN_POSTED_PERIOD|%', v_period;
    END IF;

    UPDATE employees
       SET monthly_salary = p_amount, updated_by = auth.uid()
     WHERE id = v_emp.id;

    INSERT INTO employment_history
        (employee_id, effective_date, change_type, job_title, department_id,
         employment_type, employment_status, old_monthly_salary, new_monthly_salary, notes, created_by)
    SELECT e.id, p_effective_date, 'salary_change',
           (SELECT p.title FROM positions p WHERE p.id = e.position_id), e.department_id,
           e.employment_type, e.employment_status, NULL, p_amount,
           COALESCE(NULLIF(btrim(p_notes), ''), 'Initial monthly salary'),
           auth.uid()
      FROM employees e WHERE e.id = v_emp.id;

    RETURN jsonb_build_object(
        'employee_id', v_emp.id, 'employee_code', v_emp.code,
        'new_monthly_salary', p_amount, 'effective_date', p_effective_date);
END;
$function$;

COMMENT ON FUNCTION public.set_initial_salary(uuid, numeric, date, text) IS
'ROLE-1(Tim 的 Q7):一个人的第一份月薪 —— NULL → 数值只许一次,门是 module.hr.edit 且 data.view_pay(ROLE-1 起即 finance),记一行 employment_history salary_change(old = NULL)。已有月薪 → SALARY_ALREADY_SET;之后的变动走绩效评估或调薪申请([LC])。生效日必填,落在已过账工资期里拒绝。';
