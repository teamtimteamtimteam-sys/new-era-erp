-- db/functions/close_inspection_finding.sql
-- MES-7b-2(2026-10-16,MES-0 Q72;MES-7b Step 0 Q14,Tim):【关闭一条巡检发现】—— 写下做了什么。module.safety.edit。
--   找不到 → INSPECTION_FINDING_NOT_FOUND|<id> · 已经关了 → INSPECTION_FINDING_ALREADY_CLOSED · 没写做了什么 → INSPECTION_FINDING_CLOSE_NOTE_REQUIRED。
--   它那张任务(若有)【不】跟着关,关掉任务也【不】关闭它(Q14)—— 两件事,两个出口。返回 {finding_id, closed_at}。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql.
CREATE OR REPLACE FUNCTION public.close_inspection_finding(p_finding_id uuid, p_what_was_done text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_at timestamptz;
BEGIN
    PERFORM require_permission('module.safety.edit');

    IF p_finding_id IS NULL OR NOT EXISTS (SELECT 1 FROM inspection_findings WHERE id = p_finding_id) THEN
        RAISE EXCEPTION 'INSPECTION_FINDING_NOT_FOUND|%', COALESCE(p_finding_id::text, '?');
    END IF;
    IF EXISTS (SELECT 1 FROM inspection_finding_closures WHERE finding_id = p_finding_id) THEN
        RAISE EXCEPTION 'INSPECTION_FINDING_ALREADY_CLOSED';
    END IF;
    IF p_what_was_done IS NULL OR btrim(p_what_was_done) = '' THEN
        RAISE EXCEPTION 'INSPECTION_FINDING_CLOSE_NOTE_REQUIRED';
    END IF;

    INSERT INTO inspection_finding_closures (finding_id, what_was_done, closed_by)
    VALUES (p_finding_id, btrim(p_what_was_done), auth.uid())
    RETURNING closed_at INTO v_at;
    RETURN jsonb_build_object('finding_id', p_finding_id, 'closed_at', v_at);
END;
$function$;
