-- db/functions/whistleblowing_report_file.sql
-- ESG-2(Tim 2026-10-31 Q11 · Q12 · Q13):一位员工在 /me 交一件举报(「提出一个关切」)。【任何一位登录的员工】—— 要有员工档案
--   (供应商门户的账号也是 authenticated,它交不了:WHISTLEBLOWING_EMPLOYEES_ONLY)。不要任何码。
--   保密,不是匿名(Q12):存下交的人是谁(filed_by_employee_id),只有读者看得见。p_concerns_cco 必须答(是 / 否,没有默认):
--   是 → 只有持 data.view_whistleblowing_escalated 的人读(cfo),cco 读不到(Q13)。收到日 = 新加坡的今天。
--   按名拒:WHISTLEBLOWING_EMPLOYEES_ONLY · WHISTLEBLOWING_SUBJECT_REQUIRED · WHISTLEBLOWING_DETAILS_REQUIRED · WHISTLEBLOWING_CONCERNS_CCO_REQUIRED。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.whistleblowing_report_file(p_subject text, p_details text, p_concerns_cco boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp uuid := current_user_employee();
    v_id  uuid;
BEGIN
    IF auth.uid() IS NULL OR v_emp IS NULL THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_EMPLOYEES_ONLY';
    END IF;
    IF p_subject IS NULL OR btrim(p_subject) = '' THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_SUBJECT_REQUIRED';
    END IF;
    IF p_details IS NULL OR btrim(p_details) = '' THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_DETAILS_REQUIRED';
    END IF;
    IF p_concerns_cco IS NULL THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_CONCERNS_CCO_REQUIRED';
    END IF;
    INSERT INTO whistleblowing_reports (source, concerns_cco, filed_by_employee_id, received_on, subject, details, recorded_by)
    VALUES ('in_system', p_concerns_cco, v_emp, (now() AT TIME ZONE 'Asia/Singapore')::date, btrim(p_subject), btrim(p_details), auth.uid())
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('id', v_id);
END;
$function$;
