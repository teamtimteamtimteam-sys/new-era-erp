-- db/views/employees_masked.sql
-- 遮蔽伴生视图:employees 的每一列都在,敏感列按 has_permission() 置空。
--   遮蔽的列:identity_no → data.view_identity, work_email → data.view_identity, work_pass_no → data.view_identity, work_phone → data.view_identity
--
-- 【属主权限,不是 SECURITY INVOKER】。invoker 视图以调用者身份读基表,于是任何
-- 强到能挡住原始列的机制(收紧行策略、或收回列权限)同样会挡住视图本身 —— 实测
-- 分别得到 0 行与 42501。因此这里用属主权限,并【把模块谓词原样加回视图体】:
--     WHERE has_permission('module.hr.view')
-- cut 2a 的 SELECT 策略恰好就是这同一个布尔量(与行内容无关,整表要么全可见要么
-- 全不可见),所以这与调用者的 RLS 逐行等价 —— 视图【不放宽任何行访问】。
--
-- NOTE: introduced by db/migrations/2026-08-01-perm2b-field-masking.sql.

CREATE VIEW public.employees_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    legal_name,
    preferred_name,
    department_id,
    job_title,
    manager_id,
    employment_type,
    work_category,
    hire_date,
    probation_end_date,
    employment_status,
    separation_date,
    separation_type,
    separation_notes,
    annual_leave_days,
        CASE
            WHEN has_permission('data.view_identity'::text) THEN work_email
            ELSE NULL::text
        END AS work_email,
        CASE
            WHEN has_permission('data.view_identity'::text) THEN work_phone
            ELSE NULL::text
        END AS work_phone,
    residency_status,
        CASE
            WHEN has_permission('data.view_identity'::text) THEN identity_no
            ELSE NULL::text
        END AS identity_no,
    work_pass_type,
        CASE
            WHEN has_permission('data.view_identity'::text) THEN work_pass_no
            ELSE NULL::text
        END AS work_pass_no,
    work_pass_issue_date,
    work_pass_expiry_date,
    user_id,
    notes,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by
   FROM employees
  WHERE has_permission('module.hr.view'::text);
