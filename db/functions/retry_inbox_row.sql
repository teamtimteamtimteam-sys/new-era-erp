-- db/functions/retry_inbox_row.sql
-- MES-1(2026-10-06,MES-0 §3.5):重试收件箱里一行失败的或待转换的 —— 例如一支转换器修好了、或一类刚接上了转换器之后。
--   持 action.manage_devices。只收 failed / awaiting_transform(INBOX_NOT_RETRIABLE|<状态>);返回这一次的结果状态。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.retry_inbox_row(p_id bigint)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_status text;
BEGIN
    PERFORM require_permission('action.manage_devices');
    SELECT status INTO v_status FROM ingest_inbox WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOX_ROW_NOT_FOUND|%', p_id;
    END IF;
    IF v_status NOT IN ('failed', 'awaiting_transform') THEN
        RAISE EXCEPTION 'INBOX_NOT_RETRIABLE|%', v_status;
    END IF;
    RETURN ingest_transform_row(p_id);
END;
$function$;
