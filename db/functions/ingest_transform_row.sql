-- db/functions/ingest_transform_row.sql
-- MES-1(2026-10-06,规格 §6.4;MES-0 §3.5;MES-1 Step 0 Q11 · Q12 · Q15,Tim):【分派器】—— 收件箱的一行交给它那一类的转换器。
--   读 ingest_data_classes.transform_function:为空 → awaiting_transform(这一类还没有转换器,行看得见、不丢);
--   不为空 → 调 public.<名>(jsonb)(名字的形状由表上的 CHECK 钉成 transform_<类>_v<版本>,函数不存在就记
--   TRANSFORM_FUNCTION_MISSING|<名>)。成功 → transformed(记下用的是哪一支、结果);转换器 RAISE → failed + error_code
--   (一句机器码原样留下;别的错误记 TRANSFORM_UNEXPECTED|<SQLSTATE>)。每一次都 attempts + 1 并记下是谁、何时。
--   一行转换器的错只回滚它自己(子事务),不碰同一批里的别的行。
--   【内层】不是 SECURITY DEFINER、没有调用者检查,EXECUTE 从 authenticated 收回 —— 只由 ingest_process_pending ·
--   retry_inbox_row · submit_manual_capture · correct_weighing 调(它们各自查码,以属主身份调它)。状态只在它设的事务级标记下改得动(守卫)。
-- MES-2(2026-10-06,MES-2 Step 0 Q4,Tim):【草稿由分派器落】—— 转换器是 IMMUTABLE、只吃 payload,落不了任何东西;
--   所以这一类若 creates_draft 为真(MES-2:weighing),分派器在把这一行标成 transformed 的同一次里落一张 capture_drafts
--   (proposed = 转换器的输出,原样;工位 = 设备登记的 station)。inbox_id 唯一 —— 一行收件箱最多一张草稿。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.ingest_transform_row(p_id bigint)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    r       ingest_inbox%ROWTYPE;
    v_fn    text;
    v_draft boolean;
    v_out   jsonb;
    v_err   text;
    v_state text;
BEGIN
    SELECT * INTO r FROM ingest_inbox WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOX_ROW_NOT_FOUND|%', p_id;
    END IF;
    IF r.status NOT IN ('received', 'failed', 'awaiting_transform') THEN
        RAISE EXCEPTION 'INBOX_ROW_FROZEN|%', p_id;
    END IF;
    SELECT c.transform_function, c.creates_draft INTO v_fn, v_draft FROM ingest_data_classes c WHERE c.code = r.data_class;

    PERFORM set_config('evoltrya.ingest_ctx', 'inbox_process', true);
    IF v_fn IS NULL THEN
        v_state := 'awaiting_transform';
        UPDATE ingest_inbox
           SET status = v_state, error_code = NULL, attempts = attempts + 1,
               last_attempt_at = clock_timestamp(), last_attempt_by = auth.uid()
         WHERE id = p_id;
    ELSIF to_regprocedure('public.' || v_fn || '(jsonb)') IS NULL THEN
        v_state := 'failed';
        UPDATE ingest_inbox
           SET status = v_state, error_code = 'TRANSFORM_FUNCTION_MISSING|' || v_fn, attempts = attempts + 1,
               last_attempt_at = clock_timestamp(), last_attempt_by = auth.uid()
         WHERE id = p_id;
    ELSE
        BEGIN
            EXECUTE format('SELECT public.%I($1)', v_fn) INTO v_out USING r.payload;
            v_state := 'transformed';
        EXCEPTION WHEN OTHERS THEN
            v_err := SQLERRM;
            IF v_err !~ '^[A-Z][A-Z0-9_]*(\|.*)?$' THEN
                v_err := 'TRANSFORM_UNEXPECTED|' || SQLSTATE;
            END IF;
            v_state := 'failed';
        END;
        UPDATE ingest_inbox
           SET status = v_state,
               transformed_with = CASE WHEN v_state = 'transformed' THEN v_fn END,
               transform_result = CASE WHEN v_state = 'transformed' THEN v_out END,
               error_code = CASE WHEN v_state = 'failed' THEN left(v_err, 200) END,
               attempts = attempts + 1, last_attempt_at = clock_timestamp(), last_attempt_by = auth.uid()
         WHERE id = p_id;
        -- MES-2:这一类要人确认 → 同一次里落草稿
        IF v_state = 'transformed' AND v_draft THEN
            INSERT INTO capture_drafts (inbox_id, data_class, source, device_id, station, proposed)
            VALUES (p_id, r.data_class, r.source, r.device_id,
                    (SELECT d.station FROM devices d WHERE d.id = r.device_id), v_out);
        END IF;
    END IF;
    PERFORM set_config('evoltrya.ingest_ctx', '', true);
    RETURN v_state;
END;
$function$;
