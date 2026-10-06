-- db/functions/set_ingest_settings.sql
-- MES-1(2026-10-06,MES-0 Q7;MES-1 Step 0 Q9 · Q13 · Q22):改采集层的传输上限 —— 那一行配置唯一的写入口。
--   持 action.manage_devices。p_fields 只认六个键(fail_budget · fail_window_s · global_reject_budget · max_payload_bytes ·
--   max_messages · clock_ahead_s),别的键按名拒(INGEST_SETTING_UNKNOWN|<键>);每一个值必须是正整数
--   (INGEST_SETTING_INVALID|<键>)。修改史 = 变更记录(Q22)。
-- MES-2(2026-10-06,MES-2 Step 0 Q26 · Q30,Tim):多认两个键,两者都可以给 null(= 清空):
--   require_calibrated_since  校准规则的开关 —— 'YYYY-MM-DD' 或 null(关)
--   calibration_lead_days     V8,校准到期前多少天开始提醒 —— 正整数或 null("Not yet set")
--   原来那六个键照旧只认正整数、不认 null。一个键没给 = 那一列不动。
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
    c_nullable constant text[] := ARRAY['require_calibrated_since', 'calibration_lead_days'];
    v_key text;
    f     jsonb := COALESCE(p_fields, '{}'::jsonb);
BEGIN
    PERFORM require_permission('action.manage_devices');
    FOR v_key IN SELECT jsonb_object_keys(f) LOOP
        IF v_key = ANY (c_keys) THEN
            IF COALESCE(f ->> v_key, '') !~ '^[1-9][0-9]{0,8}$' THEN
                RAISE EXCEPTION 'INGEST_SETTING_INVALID|%', v_key;
            END IF;
        ELSIF v_key = 'require_calibrated_since' THEN
            -- 一个不存在的日期(2026-13-40)在转换时就抛 —— 接住,按名拒;转回来逐字相同才算一个 YYYY-MM-DD
            IF jsonb_typeof(f -> v_key) <> 'null' THEN
                BEGIN
                    IF COALESCE(f ->> v_key, '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' OR (f ->> v_key)::date::text <> f ->> v_key THEN
                        RAISE EXCEPTION 'not a date';
                    END IF;
                EXCEPTION WHEN OTHERS THEN
                    RAISE EXCEPTION 'INGEST_SETTING_INVALID|%', v_key;
                END;
            END IF;
        ELSIF v_key = 'calibration_lead_days' THEN
            IF jsonb_typeof(f -> v_key) <> 'null' AND COALESCE(f ->> v_key, '') !~ '^[1-9][0-9]{0,4}$' THEN
                RAISE EXCEPTION 'INGEST_SETTING_INVALID|%', v_key;
            END IF;
        ELSE
            RAISE EXCEPTION 'INGEST_SETTING_UNKNOWN|%', v_key;
        END IF;
    END LOOP;
    UPDATE ingest_settings
       SET fail_budget          = COALESCE((f ->> 'fail_budget')::integer, fail_budget),
           fail_window_s        = COALESCE((f ->> 'fail_window_s')::integer, fail_window_s),
           global_reject_budget = COALESCE((f ->> 'global_reject_budget')::integer, global_reject_budget),
           max_payload_bytes    = COALESCE((f ->> 'max_payload_bytes')::integer, max_payload_bytes),
           max_messages         = COALESCE((f ->> 'max_messages')::integer, max_messages),
           clock_ahead_s        = COALESCE((f ->> 'clock_ahead_s')::integer, clock_ahead_s),
           require_calibrated_since = CASE WHEN f ? 'require_calibrated_since'
                                           THEN (f ->> 'require_calibrated_since')::date ELSE require_calibrated_since END,
           calibration_lead_days    = CASE WHEN f ? 'calibration_lead_days'
                                           THEN (f ->> 'calibration_lead_days')::integer ELSE calibration_lead_days END,
           updated_by           = auth.uid()
     WHERE id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INGEST_SETTINGS_MISSING';
    END IF;
END;
$function$;
