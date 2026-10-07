-- db/functions/record_manual_weighing_internal.sql
-- MES-4a(2026-10-07,规格 §3.2 规则 1;MES-0 Q22;MES-4a Step 0 Q24,Tim):【一次在提交那一刻敲进来的称重】—— 内层。
--   规格 §3.2:"weighing and recording occur within the same action"。操作员在提交加工单时给一条产出腿敲一个重量(没有现成的称重
--   可挑),这一支就走【正常的录入路径】落一条手工称重:收件箱 manual(录入人 = 本人)→ 同一个分派器、同一支转换器(transform_weighing_v1)
--   → 草稿 → 由录入人在同一步里确认(capture_confirm_internal)。与 submit_manual_capture 逐字同一条路,只是不再查 action.confirm_capture ——
--   调用方 commit_processing_run 已经查过 action.processing_commit,而这一磅就是那一次提交的一部分。
--   仪器可选:给了,就要是一台没停用的秤 / 地磅 / 电表 / 在线仪表(CAPTURE_DEVICE_INVALID);没给,这一磅标"没有记录仪器",照收。
--   转换没过 → 按转换器那一句码拒(整笔回滚)。返回新称重的 id。
--   【内层】不是 SECURITY DEFINER、没有调用者检查;EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.record_manual_weighing_internal(p_weight_kg numeric, p_device_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_payload jsonb;
    v_inbox   bigint;
    v_state   text;
    v_err     text;
    v_draft   uuid;
BEGIN
    IF p_device_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM devices d WHERE d.id = p_device_id AND d.retired_at IS NULL
               AND d.kind IN ('scale', 'weighbridge', 'meter', 'inline_instrument')) THEN
        RAISE EXCEPTION 'CAPTURE_DEVICE_INVALID|%', p_device_id;
    END IF;
    v_payload := jsonb_build_object('weight_kg', p_weight_kg);
    INSERT INTO ingest_inbox (source, entered_by, device_id, data_class, payload, payload_bytes, payload_sha256)
    VALUES ('manual', auth.uid(), p_device_id, 'weighing', v_payload, octet_length(v_payload::text),
            sha256(convert_to(v_payload::text, 'UTF8')))
    RETURNING id INTO v_inbox;
    v_state := ingest_transform_row(v_inbox);
    IF v_state <> 'transformed' THEN
        SELECT error_code INTO v_err FROM ingest_inbox WHERE id = v_inbox;
        RAISE EXCEPTION '%', COALESCE(v_err, 'CAPTURE_NOT_TRANSFORMED|' || v_state);
    END IF;
    SELECT id INTO v_draft FROM capture_drafts WHERE inbox_id = v_inbox;
    RETURN capture_confirm_internal(v_draft, '{}'::jsonb, '{}'::jsonb, '{}'::jsonb, NULL, NULL);
END;
$function$
