-- db/views/leave_requests_masked.sql
-- U1-A(UNBLOCK-1 Q8,2026-10-05):请假单的遮蔽伴生视图。reason · certificate_ref · exception_reason 是健康数据
--   (请假的事由、病假单号、例外的理由),要 data.view_health,【对本人让路】。
-- 行谓词 = 基表的两条读策略(module.hr.view,或本人)。每一列都在这里(colgrant)。
-- 判据与 change_log_mask_rules 的 code_or_self:data.view_health:employee_id 逐字同一个。

CREATE VIEW public.leave_requests_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    employee_id,
    leave_type_code,
    start_date,
    end_date,
    start_half_day,
    end_half_day,
    days,
        CASE
            WHEN has_permission('data.view_health'::text) OR employee_id = current_user_employee() THEN reason
            ELSE NULL::text
        END AS reason,
        CASE
            WHEN has_permission('data.view_health'::text) OR employee_id = current_user_employee() THEN certificate_ref
            ELSE NULL::text
        END AS certificate_ref,
    status,
    decided_at,
    decided_by,
    decision_notes,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    is_exception,
        CASE
            WHEN has_permission('data.view_health'::text) OR employee_id = current_user_employee() THEN exception_reason
            ELSE NULL::text
        END AS exception_reason
   FROM leave_requests
  WHERE has_permission('module.hr.view'::text) OR employee_id = current_user_employee();

COMMENT ON VIEW public.leave_requests_masked IS
    'U1-A(UNBLOCK-1 Q8):请假单的遮蔽伴生视图。reason / certificate_ref / exception_reason 要 data.view_health 或本人;行谓词 = 基表的读策略(module.hr.view 或本人)。';

GRANT SELECT ON public.leave_requests_masked TO authenticated;
