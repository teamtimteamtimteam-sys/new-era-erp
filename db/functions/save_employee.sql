-- db/functions/save_employee.sql
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 的 Q8):员工表单的【一次】保存 —— 员工那一行与它的任职履历,【一笔事务】。
--   以前是两次请求(app/hr/employees/actions.ts:先写 employees,再另起一次请求写 employment_history,线上实测相隔 0.5–0.9 秒),
--   于是一次"入职"在审计记录里是两条("Employee added"与"Hired"),而第二次请求失败时履历会安静地缺一行。
--   与 1b-3 Q13 的 save_storage_location 同一个处置:修写的那一头 —— 一次调用,只写变了的。
-- 【参数】p_id 为空 = 新建(返回新员工的 id);否则编辑那一名(返回同一个 id)。
--   p_fields:表单写的那 25 列(app/hr/employees/actions.ts 的 readForm,去掉 effective_date 与 user_id)。没给的列按 NULL 写 ——
--   表单每一次都交齐。
--   p_history:要补的那一行履历(change_type、生效日、职位文本、部门、类型、状态、说明),为空就不补 —— 推断哪一种变动、
--   说明怎么写仍在页面那一侧(inferChangeType / describeChanges),这里只负责让它与员工那一行【同生共死】。
-- 【账号关联不在这里】那是另一个权限(action.manage_permissions)的另一次调用(set_user_employee_link,它自己一笔事务)——
--   Step 0 的 Q8 照建议:关联仍是它自己的那一次。
-- 【SECURITY INVOKER】按调用者的身份跑:employees / employment_history 的读写策略与守卫(module.hr.edit;月薪只经
--   set_initial_salary,guard_employee_salary_write)照常管 —— 这支函数不放宽任何东西,它只把两次写入装进一笔。
--   ★ 但一开头先 require_permission('module.hr.edit'):被 RLS 的 USING 挡住的 UPDATE 不报错,它是一次【成功的空操作】
--     (AGENTS.md「写那一半更坏」)—— 不先问,一个没有编辑权的人点保存会得到一句"保存成功"。
-- 【一列都没变就不留痕】不在这里逐列比旧值:那要读几列被遮蔽的列(证件号、工作邮箱、月薪 —— 列级 SELECT 授权里没有它们),
--   调用者身份下读不得(实测 42501);而变更记录的触发器本来就不为"改了等于没改"写行(fixture 234 A3)—— 同一个结果,不多读一列。
CREATE OR REPLACE FUNCTION public.save_employee(p_id uuid, p_fields jsonb, p_history jsonb DEFAULT NULL::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    f    employees%ROWTYPE;
    v_id uuid := p_id;
BEGIN
    PERFORM require_permission('module.hr.edit');
    IF p_fields IS NULL OR jsonb_typeof(p_fields) <> 'object' THEN
        RAISE EXCEPTION 'EMPLOYEE_FIELDS_REQUIRED';
    END IF;
    f := jsonb_populate_record(NULL::employees, p_fields);
    IF v_id IS NULL THEN
        INSERT INTO employees (legal_name, first_name, last_name, preferred_name, department_id, position_id, manager_id,
                               employment_type, work_category, is_site_staff, hire_date, probation_end_date, employment_status,
                               separation_date, separation_type, separation_notes, work_email, work_phone, residency_status,
                               identity_no, work_pass_type, work_pass_no, work_pass_issue_date, work_pass_expiry_date, notes)
        VALUES (f.legal_name, f.first_name, f.last_name, f.preferred_name, f.department_id, f.position_id, f.manager_id,
                f.employment_type, f.work_category, COALESCE(f.is_site_staff, false), f.hire_date, f.probation_end_date, f.employment_status,
                f.separation_date, f.separation_type, f.separation_notes, f.work_email, f.work_phone, f.residency_status,
                f.identity_no, f.work_pass_type, f.work_pass_no, f.work_pass_issue_date, f.work_pass_expiry_date, f.notes)
        RETURNING id INTO v_id;
    ELSE
        UPDATE employees e SET
               (legal_name, first_name, last_name, preferred_name, department_id, position_id, manager_id,
                employment_type, work_category, is_site_staff, hire_date, probation_end_date, employment_status,
                separation_date, separation_type, separation_notes, work_email, work_phone, residency_status,
                identity_no, work_pass_type, work_pass_no, work_pass_issue_date, work_pass_expiry_date, notes)
             = (f.legal_name, f.first_name, f.last_name, f.preferred_name, f.department_id, f.position_id, f.manager_id,
                f.employment_type, f.work_category, COALESCE(f.is_site_staff, false), f.hire_date, f.probation_end_date, f.employment_status,
                f.separation_date, f.separation_type, f.separation_notes, f.work_email, f.work_phone, f.residency_status,
                f.identity_no, f.work_pass_type, f.work_pass_no, f.work_pass_issue_date, f.work_pass_expiry_date, f.notes)
         WHERE e.id = v_id;
        IF NOT FOUND AND NOT EXISTS (SELECT 1 FROM employees e WHERE e.id = v_id AND e.deleted_at IS NULL) THEN
            RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', v_id;
        END IF;
    END IF;
    IF p_history IS NOT NULL AND jsonb_typeof(p_history) = 'object' THEN
        INSERT INTO employment_history (employee_id, effective_date, change_type, job_title, department_id,
                                        employment_type, employment_status, notes)
        VALUES (v_id, NULLIF(p_history ->> 'effective_date', '')::date, p_history ->> 'change_type', p_history ->> 'job_title',
                NULLIF(p_history ->> 'department_id', '')::uuid, p_history ->> 'employment_type', p_history ->> 'employment_status',
                NULLIF(p_history ->> 'notes', ''));
    END IF;
    RETURN v_id;
END;
$function$;
