-- db/views/payroll_lines_masked.sql
-- 遮蔽伴生视图:payroll_lines 的每一列都在,敏感列按 has_permission() 置空。
--   遮蔽的列:employee_cpf → data.view_pay, employer_cpf → data.view_pay, gross_pay → data.view_pay, net_pay → data.view_pay, other_deductions → data.view_pay
--
-- 【属主权限,不是 SECURITY INVOKER】。invoker 视图以调用者身份读基表,于是任何
-- 强到能挡住原始列的机制(收紧行策略、或收回列权限)同样会挡住视图本身 —— 实测
-- 分别得到 0 行与 42501。因此这里用属主权限,并【把模块谓词原样加回视图体】:
--     WHERE has_permission('module.hr.view')
-- cut 2a 的 SELECT 策略恰好就是这同一个布尔量(与行内容无关,整表要么全可见要么
-- 全不可见),所以这与调用者的 RLS 逐行等价 —— 视图【不放宽任何行访问】。
--
-- NOTE: introduced by db/migrations/2026-08-01-perm2b-field-masking.sql.

CREATE VIEW public.payroll_lines_masked WITH (security_invoker = off) AS
 SELECT id,
    payroll_period_id,
    employee_id,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN gross_pay
            ELSE NULL::numeric
        END AS gross_pay,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN employer_cpf
            ELSE NULL::numeric
        END AS employer_cpf,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN employee_cpf
            ELSE NULL::numeric
        END AS employee_cpf,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN other_deductions
            ELSE NULL::numeric
        END AS other_deductions,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN net_pay
            ELSE NULL::numeric
        END AS net_pay,
    notes,
    created_at
   FROM payroll_lines
  WHERE has_permission('module.hr.view'::text);
