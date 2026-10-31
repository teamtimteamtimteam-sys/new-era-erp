-- db/functions/whistleblowing_report_record_outside.sql
-- ESG-2(Tim 2026-10-31 Q11 · Q12 · Q13):读者登记一件在【系统之外】收到的举报(电邮、信、电话、当面、别的)。
--   p_reporter_name 空 = 匿名来源(outside_anonymous;Q12 —— 「匿名来源」只出现在这里)。
--   【谁】只能登记自己读得到的那一种:p_concerns_cco = 真要 data.view_whistleblowing_escalated,假要 data.view_whistleblowing
--     (whistleblowing_report_readable —— 一个登记了就再也读不到的人不该是登记它的人)。
--   按名拒:PERMISSION_DENIED|<那个码> · WHISTLEBLOWING_CONCERNS_CCO_REQUIRED · WHISTLEBLOWING_RECEIVED_ON_REQUIRED ·
--     WHISTLEBLOWING_RECEIVED_ON_IN_FUTURE · WHISTLEBLOWING_RECEIVED_VIA_INVALID · WHISTLEBLOWING_SUBJECT_REQUIRED · WHISTLEBLOWING_DETAILS_REQUIRED。
--   收到日必填、不许默认成今天(AGENTS.md)。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.whistleblowing_report_record_outside(p_received_on date, p_received_via text, p_reporter_name text, p_subject text, p_details text, p_concerns_cco boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id uuid;
BEGIN
    IF p_concerns_cco IS NULL THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_CONCERNS_CCO_REQUIRED';
    END IF;
    IF NOT whistleblowing_report_readable(p_concerns_cco) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|%', CASE WHEN p_concerns_cco THEN 'data.view_whistleblowing_escalated' ELSE 'data.view_whistleblowing' END;
    END IF;
    IF p_received_on IS NULL THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_RECEIVED_ON_REQUIRED';
    END IF;
    IF p_received_on > (now() AT TIME ZONE 'Asia/Singapore')::date THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_RECEIVED_ON_IN_FUTURE';
    END IF;
    IF p_received_via IS NULL OR p_received_via NOT IN ('email', 'letter', 'phone', 'in_person', 'other') THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_RECEIVED_VIA_INVALID';
    END IF;
    IF p_subject IS NULL OR btrim(p_subject) = '' THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_SUBJECT_REQUIRED';
    END IF;
    IF p_details IS NULL OR btrim(p_details) = '' THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_DETAILS_REQUIRED';
    END IF;
    INSERT INTO whistleblowing_reports (source, concerns_cco, reporter_name, received_via, received_on, subject, details, recorded_by)
    VALUES (CASE WHEN NULLIF(btrim(COALESCE(p_reporter_name, '')), '') IS NULL THEN 'outside_anonymous' ELSE 'outside_named' END,
            p_concerns_cco, NULLIF(btrim(COALESCE(p_reporter_name, '')), ''), p_received_via, p_received_on, btrim(p_subject), btrim(p_details), auth.uid())
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('id', v_id);
END;
$function$;
