-- db/views/medical_claims_masked.sql
-- U1-A(UNBLOCK-1 Q8,2026-10-05):医疗报销的遮蔽伴生视图。description(看病的事由)与 amount_sgd(金额)要 data.view_health,
--   【对本人让路】(行谓词与列遮蔽两处都带 OR employee_id = current_user_employee() —— payroll_lines_masked 同一个形状)。
-- 行谓词 = 基表的两条读策略(module.hr.view,或本人)。每一列都在这里(colgrant)。
-- 判据与 change_log_mask_rules 的 code_or_self:data.view_health:employee_id 逐字同一个。

CREATE VIEW public.medical_claims_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    employee_id,
    claim_date,
    claim_year,
        CASE
            WHEN has_permission('data.view_health'::text) OR employee_id = current_user_employee() THEN amount_sgd
            ELSE NULL::numeric
        END AS amount_sgd,
        CASE
            WHEN has_permission('data.view_health'::text) OR employee_id = current_user_employee() THEN description
            ELSE NULL::text
        END AS description,
    receipt_ref,
    status,
    decided_at,
    decided_by,
    decision_notes,
    expense_id,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    withdrawn_at
   FROM medical_claims
  WHERE has_permission('module.hr.view'::text) OR employee_id = current_user_employee();

COMMENT ON VIEW public.medical_claims_masked IS
    'U1-A(UNBLOCK-1 Q8):医疗报销的遮蔽伴生视图。description 与 amount_sgd 要 data.view_health 或本人;行谓词 = 基表的读策略(module.hr.view 或本人)。';

GRANT SELECT ON public.medical_claims_masked TO authenticated;
