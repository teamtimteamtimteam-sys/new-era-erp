-- db/functions/approve_review.sql
-- 批准评估 =【一次原子事务】:批准 + 试用期转正 + 调薪。
-- 顺序刻意是「先转正、后校验调薪」,好让「调薪失败必须把转正一起撤掉」成为一条
-- 真的会被走到的路径,而不是一句注释(fixture 第 7 条证明)。
--
-- 【假期台账一个字都不写】年假的「转正才解锁」是读时按 employment_status 派生的
-- (submit_leave_request 的 PROBATION_NO_ANNUAL_LEAVE),不是账上的一行。在这里补一笔
-- 授予就是 HR-2a 结转重复计数的翻版 —— 同一份年假会被算两次。
--
-- 【not_confirm 什么都不改】不把在职状态改成 separated、不触发任何离职逻辑。
-- 离职是手工流程:人一旦 separated 就掉出工资表,而最后一个月的工资还没录进去。
--
-- 【没有 'confirmed' 这个在职状态】转正后是 'active';「转正」这个事件记在
-- employment_history.change_type = 'confirmed'。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3a-performance-reviews.sql.

CREATE OR REPLACE FUNCTION public.approve_review(p_review_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r        performance_reviews%ROWTYPE;
    v_emp      employees%ROWTYPE;
    v_period   text;
    v_old_sal  numeric;
    v_conf     date;
    v_confirmed boolean := false;
    v_salaried  boolean := false;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;

    -- 【提交人不能自批】四眼原则。与"评估人不能是本人"是两条不同的规则:
    -- 一条防自我评价,这一条防自我批准。
    IF v_r.submitted_by IS NOT NULL AND v_r.submitted_by = auth.uid() THEN
        RAISE EXCEPTION 'SELF_APPROVAL_FORBIDDEN';
    END IF;

    SELECT * INTO v_emp FROM employees WHERE id = v_r.employee_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    UPDATE performance_reviews
    SET status = 'approved', approved_at = now(), approved_by = auth.uid()
    WHERE id = p_review_id;

    -- ── 试用期转正 ────────────────────────────────────────────────────────
    IF v_r.review_type = 'probation' AND v_r.probation_outcome = 'confirm' THEN
        IF v_emp.employment_status = 'separated' THEN
            RAISE EXCEPTION 'EMPLOYEE_SEPARATED|%', v_emp.code;
        END IF;
        v_conf := COALESCE(v_emp.probation_end_date, CURRENT_DATE);

        UPDATE employees
        SET employment_status = 'active',      -- 【没有 'confirmed' 这个状态,见文件头 (2)】
            confirmation_date = v_conf
        WHERE id = v_emp.id;

        -- 【恰好一行】履历。
        INSERT INTO employment_history
            (employee_id, effective_date, change_type, job_title, department_id,
             employment_type, employment_status, notes)
        VALUES (v_emp.id, v_conf, 'confirmed', v_emp.job_title, v_emp.department_id,
                v_emp.employment_type, 'active',
                format('Probation confirmed by performance review %s', p_review_id));

        -- 【假期台账一个字都不写】年假的解锁是读时按 employment_status 派生的
        -- (submit_leave_request 的 PROBATION_NO_ANNUAL_LEAVE)。在这里补一笔授予
        -- 就是 HR-2a 结转重复计数的翻版。见文件头 (1)。
        v_confirmed := true;
    END IF;

    -- ── 不予转正:【什么都不改】 ──────────────────────────────────────────
    -- 决定记在评估单据上,提醒由 hr_alerts 的 probation_not_confirmed 一支发出。
    -- 【绝不把在职状态改成 separated,也绝不触发任何离职逻辑】——
    -- 离职是手工流程:人一旦 separated 就掉出工资表,而最后一个月的工资还没录。
    -- 先掉出去,那笔钱就再也发不出来了。

    -- ── 调薪 ──────────────────────────────────────────────────────────────
    IF v_r.new_monthly_salary IS NOT NULL THEN
        -- payroll_periods 没有起止两列:周期就是 period_month 那个整月(见文件头 (4))
        SELECT p.code INTO v_period
        FROM payroll_periods p
        WHERE p.deleted_at IS NULL AND p.status = 'posted'
          AND v_r.salary_effective_date >= p.period_month
          AND v_r.salary_effective_date < (p.period_month + interval '1 month')::date
        ORDER BY p.period_month
        LIMIT 1;

        IF v_period IS NOT NULL THEN
            -- 【连同上面的转正一起回滚】总账已经认了那个月的工资,
            -- 追改一个已过账周期里的薪酬会让账实不符。
            RAISE EXCEPTION 'SALARY_EFFECTIVE_IN_POSTED_PERIOD|%', v_period;
        END IF;

        v_old_sal := v_emp.monthly_salary;

        UPDATE employees SET monthly_salary = v_r.new_monthly_salary WHERE id = v_emp.id;

        INSERT INTO employment_history
            (employee_id, effective_date, change_type, job_title, department_id,
             employment_type, employment_status, old_monthly_salary, new_monthly_salary, notes)
        SELECT e.id, v_r.salary_effective_date, 'salary_change', e.job_title, e.department_id,
               e.employment_type, e.employment_status, v_old_sal, v_r.new_monthly_salary,
               format('Salary change approved with performance review %s', p_review_id)
        FROM employees e WHERE e.id = v_emp.id;

        v_salaried := true;
    END IF;

    RETURN jsonb_build_object(
        'review_id', p_review_id, 'status', 'approved',
        'employee_code', v_emp.code,
        'review_type', v_r.review_type,
        'probation_outcome', v_r.probation_outcome,
        'confirmed', v_confirmed,
        'confirmation_date', v_conf,
        'salary_changed', v_salaried,
        'old_monthly_salary', v_old_sal,
        'new_monthly_salary', v_r.new_monthly_salary,
        'salary_effective_date', v_r.salary_effective_date);
END;
$function$
;