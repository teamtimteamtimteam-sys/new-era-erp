-- db/functions/submit_manual_capture.sql
-- MES-2(2026-10-06,规格 §6.3 · §10;MES-0 Q10;MES-1 Q14;MES-2 Step 0 Q13–Q15,Tim):【手工录入】—— 走网关那一条路,一步确认。
--   ① 这一类要允许手工录入(manual_entry_code 不为空、creates_draft 为真),否则 CAPTURE_NO_MANUAL_ENTRY|<类>;
--      持它的 manual_entry_code(称重:action.confirm_capture,Q15)。
--   ② 仪器可选(Q14):给了,就要是一台没停用的秤 / 地磅 / 电表 / 在线仪表(CAPTURE_DEVICE_INVALID);没给,这次称重标
--      "instrument not recorded",照收。
--   ③ 收件箱落一行(source = manual,录入人 = 本人)→ 【同一个分派器、同一支转换器】→ 草稿 → 同一步里由录入人确认
--      (confirmed_by = entered_by,不落改值行)。
--   ④ 转换没过(Q13):按转换器那一句码拒,【整笔回滚 —— 什么都不留】。收件箱里失败的行是给没人看着的机器的;
--      站在这里的人当场就能改。
--   返回 {inbox_id, draft_id, weighing_id}。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.submit_manual_capture(p_data_class text, p_payload jsonb, p_device_id uuid DEFAULT NULL::uuid, p_site_from timestamptz DEFAULT NULL::timestamptz, p_site_to timestamptz DEFAULT NULL::timestamptz, p_subject jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_class ingest_data_classes%ROWTYPE;
    v_inbox bigint;
    v_state text;
    v_err   text;
    v_draft uuid;
    v_w     uuid;
BEGIN
    SELECT * INTO v_class FROM ingest_data_classes WHERE code = p_data_class;
    IF NOT FOUND OR NOT v_class.is_active THEN
        RAISE EXCEPTION 'CAPTURE_CLASS_UNKNOWN|%', COALESCE(p_data_class, '?');
    END IF;
    IF v_class.manual_entry_code IS NULL OR NOT v_class.creates_draft THEN
        RAISE EXCEPTION 'CAPTURE_NO_MANUAL_ENTRY|%', p_data_class;
    END IF;
    PERFORM require_permission(v_class.manual_entry_code);
    IF p_device_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM devices d WHERE d.id = p_device_id AND d.retired_at IS NULL
               AND d.kind IN ('scale', 'weighbridge', 'meter', 'inline_instrument')) THEN
        RAISE EXCEPTION 'CAPTURE_DEVICE_INVALID|%', p_device_id;
    END IF;
    IF p_payload IS NULL THEN
        RAISE EXCEPTION 'CAPTURE_PAYLOAD_REQUIRED';
    END IF;
    IF p_site_from IS NOT NULL AND p_site_to IS NOT NULL AND p_site_from > p_site_to THEN
        RAISE EXCEPTION 'CAPTURE_SITE_RANGE_INVALID';
    END IF;

    INSERT INTO ingest_inbox (source, entered_by, device_id, data_class, payload, payload_bytes, payload_sha256, site_from, site_to)
    VALUES ('manual', auth.uid(), p_device_id, p_data_class, p_payload, octet_length(p_payload::text),
            sha256(convert_to(p_payload::text, 'UTF8')), p_site_from, p_site_to)
    RETURNING id INTO v_inbox;

    v_state := ingest_transform_row(v_inbox);
    IF v_state <> 'transformed' THEN
        SELECT error_code INTO v_err FROM ingest_inbox WHERE id = v_inbox;
        RAISE EXCEPTION '%', COALESCE(v_err, 'CAPTURE_NOT_TRANSFORMED|' || v_state);
    END IF;
    SELECT id INTO v_draft FROM capture_drafts WHERE inbox_id = v_inbox;
    v_w := capture_confirm_internal(v_draft, '{}'::jsonb, '{}'::jsonb, p_subject, NULL, NULL);
    RETURN jsonb_build_object('inbox_id', v_inbox, 'draft_id', v_draft, 'weighing_id', v_w);
END;
$function$;
