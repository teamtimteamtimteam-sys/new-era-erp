-- db/functions/whistleblowing_report_readable.sql
-- ESG-2(Tim 2026-10-31 Q13):一件举报【当前读者】读不读得到 —— 判据只有这一份(两张举报表的读策略、四支举报函数、举报页都问它)。
--   concerns_cco = true(交的人勾了「这件事涉及 CCO」)→ 只认 data.view_whistleblowing_escalated(cfo);cco 持的 data.view_whistleblowing 不算。
--   concerns_cco = false → 只认 data.view_whistleblowing(cco)。两个码都不授 admin(db/tables/role_permissions.sql)。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.whistleblowing_report_readable(p_concerns_cco boolean)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE WHEN p_concerns_cco THEN has_permission('data.view_whistleblowing_escalated')
                ELSE has_permission('data.view_whistleblowing') END;
$function$;
