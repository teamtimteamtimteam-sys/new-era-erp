-- db/functions/set_ingest_settings.sql
-- MES-1(2026-10-06,MES-0 Q7;MES-1 Step 0 Q9 · Q13 · Q22):改采集层的传输上限 —— 那一行配置唯一的写入口。
--   持 action.manage_devices。p_fields 只认六个键(fail_budget · fail_window_s · global_reject_budget · max_payload_bytes ·
--   max_messages · clock_ahead_s),别的键按名拒(INGEST_SETTING_UNKNOWN|<键>);每一个值必须是正整数
--   (INGEST_SETTING_INVALID|<键>)。修改史 = 变更记录(Q22)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.set_ingest_settings(p_fields jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    c_keys constant text[] := ARRAY['fail_budget', 'fail_window_s', 'global_reject_budget', 'max_payload_bytes',
                                    'max_messages', 'clock_ahead_s'];
    v_key text;
    f     jsonb := COALESCE(p_fields, '{}'::jsonb);
BEGIN
    PERFORM require_permission('action.manage_devices');
    FOR v_key IN SELECT jsonb_object_keys(f) LOOP
        IF NOT v_key = ANY (c_keys) THEN
            RAISE EXCEPTION 'INGEST_SETTING_UNKNOWN|%', v_key;
        END IF;
        IF COALESCE(f ->> v_key, '') !~ '^[1-9][0-9]{0,8}$' THEN
            RAISE EXCEPTION 'INGEST_SETTING_INVALID|%', v_key;
        END IF;
    END LOOP;
    UPDATE ingest_settings
       SET fail_budget          = COALESCE((f ->> 'fail_budget')::integer, fail_budget),
           fail_window_s        = COALESCE((f ->> 'fail_window_s')::integer, fail_window_s),
           global_reject_budget = COALESCE((f ->> 'global_reject_budget')::integer, global_reject_budget),
           max_payload_bytes    = COALESCE((f ->> 'max_payload_bytes')::integer, max_payload_bytes),
           max_messages         = COALESCE((f ->> 'max_messages')::integer, max_messages),
           clock_ahead_s        = COALESCE((f ->> 'clock_ahead_s')::integer, clock_ahead_s),
           updated_by           = auth.uid()
     WHERE id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INGEST_SETTINGS_MISSING';
    END IF;
END;
$function$;
