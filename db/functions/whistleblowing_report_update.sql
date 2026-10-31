-- db/functions/whistleblowing_report_update.sql
-- ESG-2(Tim 2026-10-31 Q14):给一件举报追加一个状态(收到确认 · 调查中 · 结案),每一个都带一句说明。追加,不改、不删。
--   【谁】读得到那一件的人(whistleblowing_report_readable(concerns_cco));读不到的人得到的是「找不到」(WHISTLEBLOWING_NOT_FOUND)——
--     不告诉他那一件存不存在。结案之后不再收(WHISTLEBLOWING_CLOSED)。
--   按名拒:WHISTLEBLOWING_NOT_FOUND · WHISTLEBLOWING_CLOSED · WHISTLEBLOWING_STATUS_INVALID · WHISTLEBLOWING_NOTE_REQUIRED。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.whistleblowing_report_update(p_report_id uuid, p_status text, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r  whistleblowing_reports%ROWTYPE;
    v_id bigint;
BEGIN
    SELECT * INTO v_r FROM whistleblowing_reports WHERE id = p_report_id;
    IF NOT FOUND OR NOT whistleblowing_report_readable(v_r.concerns_cco) THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_NOT_FOUND';
    END IF;
    IF EXISTS (SELECT 1 FROM whistleblowing_updates u WHERE u.report_id = v_r.id AND u.status = 'closed') THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_CLOSED';
    END IF;
    IF p_status IS NULL OR p_status NOT IN ('acknowledged', 'investigating', 'closed') THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_STATUS_INVALID';
    END IF;
    IF p_note IS NULL OR btrim(p_note) = '' THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_NOTE_REQUIRED';
    END IF;
    INSERT INTO whistleblowing_updates (report_id, status, note, recorded_by)
    VALUES (v_r.id, p_status, btrim(p_note), auth.uid())
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('update_id', v_id, 'status', p_status);
END;
$function$;
