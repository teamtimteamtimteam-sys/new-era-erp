-- db/functions/correct_weighing.sql
-- MES-2(2026-10-06,规格 §4.2;MES-0 §3.7;MES-2 Step 0 Q11,Tim):【更正一次已确认的称重】—— 不改原行,落一条新的。
--   持 action.confirm_capture;理由必填(WEIGHING_CORRECTION_REASON_REQUIRED);一行只更正一次(WEIGHING_SUPERSEDED|<id>:
--   要再改,改最新的那一行);值没变按名拒(WEIGHING_CORRECTION_SAME_VALUE)。
--   新的那一次走手工录入的同一条路(收件箱 manual → 同一支转换器 → 草稿 → 一步确认),仪器、现场时间、主语(地磅单与角色)
--   都照抄原行 —— 它更正的是【那一次读数】,不是一次新的过磅。新行 corrects_id 指回原行;地磅单从此读最新的,
--   两磅凑齐时净重照样要 > 0(TICKET_NET_NOT_POSITIVE)。已经分出去的份与收货单的数量一个字都不动(收货单数量不可改),
--   差多少在单上照直显示。返回新那一行的 id。
--
--   ★ MES-4a(2026-10-07,Q26):挂在一条加工产出腿上的称重不再更正 → WEIGHING_IN_USE|<加工单>。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.correct_weighing(p_weighing_id uuid, p_weight_kg numeric, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig    weighings%ROWTYPE;
    v_payload jsonb;
    v_inbox   bigint;
    v_state   text;
    v_err     text;
    v_draft   uuid;
BEGIN
    PERFORM require_permission('action.confirm_capture');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'WEIGHING_CORRECTION_REASON_REQUIRED';
    END IF;
    SELECT * INTO v_orig FROM weighings WHERE id = p_weighing_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WEIGHING_NOT_FOUND|%', COALESCE(p_weighing_id::text, '?');
    END IF;
    IF EXISTS (SELECT 1 FROM weighings x WHERE x.corrects_id = v_orig.id) THEN
        RAISE EXCEPTION 'WEIGHING_SUPERSEDED|%', v_orig.id;
    END IF;
    -- MES-4a(MES-0 Q49;MES-4a Step 0 Q26):一次已经给一条加工产出腿用了的称重不再更正 —— 那条腿的数量就是它;
    -- 数量的更正是回滚申请(CFO)+ 一张新单(corrects_run_id)。
    IF EXISTS (SELECT 1 FROM processing_outputs po WHERE po.weighing_id = v_orig.id) THEN
        RAISE EXCEPTION 'WEIGHING_IN_USE|%', (SELECT r.code FROM processing_outputs po JOIN processing_runs r ON r.id = po.run_id
                                               WHERE po.weighing_id = v_orig.id);
    END IF;
    IF v_orig.ticket_id IS NOT NULL AND EXISTS (SELECT 1 FROM weighbridge_tickets t WHERE t.id = v_orig.ticket_id AND t.voided_at IS NOT NULL) THEN
        RAISE EXCEPTION 'TICKET_VOIDED|%', (SELECT t.code FROM weighbridge_tickets t WHERE t.id = v_orig.ticket_id);
    END IF;
    IF p_weight_kg IS NOT DISTINCT FROM v_orig.weight_kg THEN
        RAISE EXCEPTION 'WEIGHING_CORRECTION_SAME_VALUE';
    END IF;
    v_payload := jsonb_build_object('weight_kg', p_weight_kg);

    INSERT INTO ingest_inbox (source, entered_by, device_id, data_class, payload, payload_bytes, payload_sha256, site_from, site_to,
                              site_dataset_ref)
    VALUES ('manual', auth.uid(), v_orig.device_id, 'weighing', v_payload, octet_length(v_payload::text),
            sha256(convert_to(v_payload::text, 'UTF8')), v_orig.site_from, v_orig.site_to, v_orig.site_dataset_ref)
    RETURNING id INTO v_inbox;
    v_state := ingest_transform_row(v_inbox);
    IF v_state <> 'transformed' THEN
        SELECT error_code INTO v_err FROM ingest_inbox WHERE id = v_inbox;
        RAISE EXCEPTION '%', COALESCE(v_err, 'CAPTURE_NOT_TRANSFORMED|' || v_state);
    END IF;
    SELECT id INTO v_draft FROM capture_drafts WHERE inbox_id = v_inbox;
    RETURN capture_confirm_internal(v_draft, '{}'::jsonb, '{}'::jsonb, '{}'::jsonb, v_orig.id, p_reason);
END;
$function$;
