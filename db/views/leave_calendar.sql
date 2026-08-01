-- db/views/leave_calendar.sql
-- 请假日历。HR 看全部,员工看自己的 —— 谓词写在视图体里。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.

CREATE VIEW public.leave_calendar WITH (security_invoker = off) AS
 SELECT r.id AS request_id,
    r.code,
    r.employee_id,
    e.code AS employee_code,
    e.legal_name,
    e.department_id,
    r.leave_type_code,
    lt.name_en AS leave_type_en,
    lt.name_zh AS leave_type_zh,
    r.start_date,
    r.end_date,
    r.start_half_day,
    r.end_half_day,
    r.days,
    r.status
   FROM leave_requests r
     JOIN employees e ON e.id = r.employee_id
     JOIN leave_types lt ON lt.code = r.leave_type_code
  WHERE r.deleted_at IS NULL AND (r.status = ANY (ARRAY['pending'::text, 'approved'::text])) AND (has_permission('module.hr.view'::text) OR r.employee_id = current_user_employee());
