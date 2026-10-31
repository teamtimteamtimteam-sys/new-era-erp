-- db/views/whistleblowing_report_rows.sql
-- ESG-2(Tim 2026-10-31 Q11 – Q14):举报登记簿读的那一行 —— 一件举报,加上交的人的显示标签(系统里交的)、现在的状态(最后一个追加的状态,
--   没有 = received)与它的时刻、追加过几次。
--   【属主权限】行谓词就是 whistleblowing_report_readable(concerns_cco):涉及 CCO 的只给持 data.view_whistleblowing_escalated 的人,
--   别的只给持 data.view_whistleblowing 的人(Q13)。交的人读自己那几件走 my_concerns(),不走这里。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.

CREATE VIEW public.whistleblowing_report_rows WITH (security_invoker = off) AS
 SELECT r.id,
    r.source,
    r.concerns_cco,
    r.filed_by_employee_id,
    (e.code || ' · '::text) || COALESCE(e.preferred_name, e.legal_name) AS filed_by_label,
    r.reporter_name,
    r.received_via,
    r.received_on,
    r.subject,
    r.details,
    COALESCE(u.status, 'received'::text) AS status,
    COALESCE(u.recorded_at, r.recorded_at) AS status_at,
    ( SELECT count(*)::integer AS count
           FROM whistleblowing_updates x
          WHERE x.report_id = r.id) AS updates,
    r.recorded_at,
    r.recorded_by
   FROM whistleblowing_reports r
     LEFT JOIN employees e ON e.id = r.filed_by_employee_id
     LEFT JOIN LATERAL ( SELECT x.status,
            x.recorded_at
           FROM whistleblowing_updates x
          WHERE x.report_id = r.id
          ORDER BY x.id DESC
         LIMIT 1) u ON true
  WHERE whistleblowing_report_readable(r.concerns_cco);

COMMENT ON VIEW public.whistleblowing_report_rows IS
    'ESG-2(Q11–Q14):举报登记簿的一行 —— 举报 + 交的人标签 + 现在的状态。行谓词 = whistleblowing_report_readable(concerns_cco)(涉及 CCO 的只给 cfo 的码,别的只给 cco 的码)。';

REVOKE ALL ON public.whistleblowing_report_rows FROM authenticated, anon;
GRANT SELECT ON public.whistleblowing_report_rows TO authenticated;
