-- db/views/company_policy_rows.sql
-- ESG-2(Tim 2026-10-31 Q10):制度登记簿读的那一行 —— 每一个版本,加上负责人的显示标签(员工号 · 名字;标签跟着单据走,四条常设裁定之三)、
--   它是不是「现在」的那一版(没被取代)与复审是不是逾期(现在那一版的复审日早于新加坡的今天)。
--   【属主权限】行谓词 = company_policies 的读策略(有员工档案的人,或持 action.manage_esg 的人);借来的只有负责人的名字。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.

CREATE VIEW public.company_policy_rows WITH (security_invoker = off) AS
 SELECT p.id,
    p.title,
    p.version,
    p.owner_employee_id,
    (e.code || ' · '::text) || COALESCE(e.preferred_name, e.legal_name) AS owner_label,
    p.effective_date,
    p.review_date,
    p.document_ref,
    p.supersedes_id,
    p.superseded_at,
    p.superseded_at IS NULL AS is_current,
    p.superseded_at IS NULL AND p.review_date < (now() AT TIME ZONE 'Asia/Singapore'::text)::date AS review_overdue,
    p.recorded_at,
    p.recorded_by
   FROM company_policies p
     JOIN employees e ON e.id = p.owner_employee_id
  WHERE current_user_employee() IS NOT NULL OR has_permission('action.manage_esg'::text);

COMMENT ON VIEW public.company_policy_rows IS
    'ESG-2(Q10):制度登记簿的每一个版本 + 负责人标签 + 是不是现在那一版 + 复审逾期。行谓词 = company_policies 的读策略(有员工档案的人,或持 action.manage_esg 的人)。';

REVOKE ALL ON public.company_policy_rows FROM authenticated, anon;
GRANT SELECT ON public.company_policy_rows TO authenticated;
