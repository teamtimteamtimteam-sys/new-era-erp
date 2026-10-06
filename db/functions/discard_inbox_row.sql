-- db/functions/discard_inbox_row.sql
-- MES-1(2026-10-06,规格 §6.4;MES-0 §3.5):带理由丢弃收件箱里一行失败的或待转换的 —— 【永远不删】。
--   持 action.manage_devices;要写理由(INBOX_DISCARD_REASON_REQUIRED);只收 failed / awaiting_transform
--   (INBOX_NOT_DISCARDABLE|<状态>)。丢弃之后那一行冻住,留在收件箱里,标着谁、何时、为什么;失败的那个码留着。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.discard_inbox_row(p_id bigint, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_status text;
BEGIN
    PERFORM require_permission('action.manage_devices');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'INBOX_DISCARD_REASON_REQUIRED';
    END IF;
    SELECT status INTO v_status FROM ingest_inbox WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOX_ROW_NOT_FOUND|%', p_id;
    END IF;
    IF v_status NOT IN ('failed', 'awaiting_transform') THEN
        RAISE EXCEPTION 'INBOX_NOT_DISCARDABLE|%', v_status;
    END IF;
    PERFORM set_config('evoltrya.ingest_ctx', 'inbox_process', true);
    UPDATE ingest_inbox
       SET status = 'discarded', discarded_at = now(), discarded_by = auth.uid(),
           discard_reason = btrim(p_reason)
     WHERE id = p_id;
    PERFORM set_config('evoltrya.ingest_ctx', '', true);
END;
$function$;
