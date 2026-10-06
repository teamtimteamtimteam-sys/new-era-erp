-- db/functions/capture_confirm_internal.sql
-- MES-2(2026-10-06,规格 §6.3;MES-0 §3.6 · Q12;MES-2 Step 0 Q9 · Q11 · Q12 · Q16,Tim):【确认一张草稿 —— 内层】。
--   三个调用方各自查码、以属主身份调它:confirm_capture_draft(工位上确认网关送来的)· submit_manual_capture(手工录入,
--   同一步里由录入人确认)· correct_weighing(更正,新一行指回原行)。
--   ① 改值(p_overrides):只认【量出来的值】(weighing:weight_kg);设备、网关、流、序号、来源、现场时间、数据类 →
--      CAPTURE_FIELD_FIXED|<字段>(MES-0 Q12);别的键 → CAPTURE_FIELD_UNKNOWN|<字段>。合并之后【交给同一支转换器再验一次】
--      (一份验证器,两个调用方);确认值与 proposed 不同的每一格要有理由(CAPTURE_CHANGE_REASON_REQUIRED|<字段>),
--      并落一行 capture_draft_changes(原值 · 确认值 · 理由)。
--   ② 量程(Q12):这台仪器登记了量程,读数超过它 → WEIGHING_ABOVE_CAPACITY|<编号>|<量程 kg>。量程按设备登记的单位读
--      (kg · t · g;空 = kg);别的单位比不了,不判。没有登记量程 → 不判(V33 把它列在「待补的标准值」上)。
--   ③ 主语(p_subject,Q16):{} = 一次单独的净重;{"new_ticket": {"direction", "vehicle_reg", "notes"}} = 用这一磅开一张地磅单
--      (进厂第一磅是毛重,出厂第一磅是皮重);{"ticket_id"} = 这一磅完成那张开着的单(另一种角色)。更正时主语照抄原行。
--      主语不是"改":网关的 proposed 里没有它(Q7),所以选它不落 capture_draft_changes。
--   ④ 落 weighings(captured_at = 现场时间,没有就是确认时刻;更正照抄原行的 —— 它更正的是那一次读数),草稿标 confirmed。
--   ⑤ 一张单两磅都在 → 净重 = 毛重 − 皮重,≤ 0 按名拒(TICKET_NET_NOT_POSITIVE|<编号>|<毛>|<皮>);第一次凑齐时记 completed_at。
--   【内层】不是 SECURITY DEFINER、没有调用者检查,EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.capture_confirm_internal(p_draft_id uuid, p_overrides jsonb, p_reasons jsonb, p_subject jsonb, p_corrects uuid, p_correction_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    c_fixed    constant text[] := ARRAY['device', 'device_id', 'gateway', 'gateway_id', 'stream', 'seq', 'source', 'site_from',
                                        'site_to', 'site_dataset_ref', 'data_class', 'class'];
    c_measured constant text[] := ARRAY['weight_kg'];
    d          capture_drafts%ROWTYPE;
    b          ingest_inbox%ROWTYPE;
    v_orig     weighings%ROWTYPE;
    v_dev      devices%ROWTYPE;
    v_tk       weighbridge_tickets%ROWTYPE;
    v_ov       jsonb := COALESCE(p_overrides, '{}'::jsonb);
    v_sub      jsonb := COALESCE(p_subject, '{}'::jsonb);
    v_fn       text;
    v_out      jsonb;
    k          text;
    v_cap      numeric;
    v_role     text := 'net';
    v_ticket   uuid;
    v_dir      text;
    v_captured timestamptz;
    v_w        uuid;
    v_gross    numeric;
    v_tare     numeric;
BEGIN
    SELECT * INTO d FROM capture_drafts WHERE id = p_draft_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CAPTURE_DRAFT_NOT_FOUND|%', COALESCE(p_draft_id::text, '?');
    END IF;
    IF d.status <> 'pending' THEN
        RAISE EXCEPTION 'CAPTURE_DRAFT_DECIDED|%', d.status;
    END IF;
    IF d.data_class <> 'weighing' THEN
        RAISE EXCEPTION 'CAPTURE_CLASS_HAS_NO_RECORD|%', d.data_class;
    END IF;
    SELECT * INTO b FROM ingest_inbox WHERE id = d.inbox_id;

    -- ① 改值:只认量出来的值;合并之后同一支转换器再验
    IF jsonb_typeof(v_ov) <> 'object' THEN
        RAISE EXCEPTION 'CAPTURE_FIELD_UNKNOWN|overrides';
    END IF;
    FOR k IN SELECT jsonb_object_keys(v_ov) LOOP
        IF k = ANY (c_fixed) THEN
            RAISE EXCEPTION 'CAPTURE_FIELD_FIXED|%', k;
        END IF;
        IF NOT k = ANY (c_measured) THEN
            RAISE EXCEPTION 'CAPTURE_FIELD_UNKNOWN|%', k;
        END IF;
    END LOOP;
    SELECT c.transform_function INTO v_fn FROM ingest_data_classes c WHERE c.code = d.data_class;
    EXECUTE format('SELECT public.%I($1)', v_fn) INTO v_out USING (d.proposed || v_ov);
    FOR k IN SELECT jsonb_object_keys(v_ov) LOOP
        IF (v_out -> k) IS DISTINCT FROM (d.proposed -> k)
           AND btrim(COALESCE(p_reasons ->> k, '')) = '' THEN
            RAISE EXCEPTION 'CAPTURE_CHANGE_REASON_REQUIRED|%', k;
        END IF;
    END LOOP;

    -- ② 量程
    IF d.device_id IS NOT NULL THEN
        SELECT * INTO v_dev FROM devices WHERE id = d.device_id;
        IF v_dev.capacity IS NOT NULL THEN
            v_cap := v_dev.capacity * CASE lower(btrim(COALESCE(v_dev.unit, 'kg')))
                                          WHEN 'kg' THEN 1 WHEN 't' THEN 1000 WHEN 'g' THEN 0.001 END;
            IF v_cap IS NOT NULL AND (v_out ->> 'weight_kg')::numeric > v_cap THEN
                RAISE EXCEPTION 'WEIGHING_ABOVE_CAPACITY|%|%', v_dev.code, v_cap;
            END IF;
        END IF;
    END IF;

    -- ③ 主语
    IF p_corrects IS NOT NULL THEN
        SELECT * INTO v_orig FROM weighings WHERE id = p_corrects;
        v_ticket := v_orig.ticket_id;
        v_role := v_orig.role;
        v_captured := v_orig.captured_at;
    ELSIF v_sub ? 'new_ticket' THEN
        v_dir := v_sub -> 'new_ticket' ->> 'direction';
        IF v_dir IS NULL OR v_dir NOT IN ('inbound', 'outbound') THEN
            RAISE EXCEPTION 'TICKET_DIRECTION_INVALID|%', COALESCE(v_dir, '?');
        END IF;
        IF btrim(COALESCE(v_sub -> 'new_ticket' ->> 'vehicle_reg', '')) = '' THEN
            RAISE EXCEPTION 'TICKET_VEHICLE_REQUIRED';
        END IF;
        INSERT INTO weighbridge_tickets (direction, vehicle_reg, notes, created_by, updated_by)
        VALUES (v_dir, upper(btrim(v_sub -> 'new_ticket' ->> 'vehicle_reg')),
                NULLIF(btrim(COALESCE(v_sub -> 'new_ticket' ->> 'notes', '')), ''), auth.uid(), auth.uid())
        RETURNING id INTO v_ticket;
        v_role := CASE v_dir WHEN 'inbound' THEN 'gross' ELSE 'tare' END;
    ELSIF v_sub ? 'ticket_id' THEN
        SELECT * INTO v_tk FROM weighbridge_tickets WHERE id = (v_sub ->> 'ticket_id')::uuid FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'TICKET_NOT_FOUND|%', v_sub ->> 'ticket_id';
        END IF;
        IF v_tk.voided_at IS NOT NULL THEN
            RAISE EXCEPTION 'TICKET_VOIDED|%', v_tk.code;
        END IF;
        IF v_tk.completed_at IS NOT NULL THEN
            RAISE EXCEPTION 'TICKET_ALREADY_COMPLETE|%', v_tk.code;
        END IF;
        v_ticket := v_tk.id;
        v_role := CASE v_tk.direction WHEN 'inbound' THEN 'tare' ELSE 'gross' END;
    ELSIF v_sub <> '{}'::jsonb THEN
        RAISE EXCEPTION 'CAPTURE_SUBJECT_UNKNOWN';
    END IF;

    -- ④ 正式记录;改过的值;草稿标 confirmed
    INSERT INTO weighings (inbox_id, draft_id, device_id, source, weight_kg, role, ticket_id, site_from, site_to, site_dataset_ref,
                           captured_at, confirmed_by, corrects_id, correction_reason)
    VALUES (b.id, d.id, d.device_id, d.source, (v_out ->> 'weight_kg')::numeric, v_role, v_ticket, b.site_from, b.site_to,
            b.site_dataset_ref, COALESCE(v_captured, b.site_to, b.site_from, now()), auth.uid(), p_corrects,
            NULLIF(btrim(COALESCE(p_correction_reason, '')), ''))
    RETURNING id INTO v_w;
    FOR k IN SELECT jsonb_object_keys(v_ov) LOOP
        IF (v_out -> k) IS DISTINCT FROM (d.proposed -> k) THEN
            INSERT INTO capture_draft_changes (draft_id, field, original_value, confirmed_value, reason)
            VALUES (d.id, k, d.proposed -> k, v_out -> k, btrim(p_reasons ->> k));
        END IF;
    END LOOP;
    UPDATE capture_drafts SET status = 'confirmed', confirmed_at = now(), confirmed_by = auth.uid() WHERE id = d.id;

    -- ⑤ 两磅凑齐:净重 > 0;第一次凑齐时记 completed_at
    IF v_ticket IS NOT NULL THEN
        SELECT max(w.weight_kg) FILTER (WHERE w.role = 'gross'), max(w.weight_kg) FILTER (WHERE w.role = 'tare')
          INTO v_gross, v_tare
          FROM weighings w
         WHERE w.ticket_id = v_ticket AND NOT EXISTS (SELECT 1 FROM weighings x WHERE x.corrects_id = w.id);
        IF v_gross IS NOT NULL AND v_tare IS NOT NULL THEN
            IF v_gross - v_tare <= 0 THEN
                RAISE EXCEPTION 'TICKET_NET_NOT_POSITIVE|%|%|%', (SELECT t.code FROM weighbridge_tickets t WHERE t.id = v_ticket),
                    v_gross, v_tare;
            END IF;
            UPDATE weighbridge_tickets SET completed_at = now(), updated_by = auth.uid()
             WHERE id = v_ticket AND completed_at IS NULL;
        END IF;
    END IF;
    RETURN v_w;
END;
$function$;
