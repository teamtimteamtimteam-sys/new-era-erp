CREATE OR REPLACE FUNCTION public.submit_shift_handover(p_shift_code text, p_handover_date date, p_outgoing_employee_id uuid, p_incoming_employee_id uuid, p_notes text DEFAULT NULL::text, p_items jsonb DEFAULT NULL::jsonb, p_downtime_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_elem jsonb;
    v_bad  text;
BEGIN
    PERFORM require_permission('module.processing.edit');

    -- 【世界侧日期不给默认值】与 FIN-10「永不给日期默认值」同一条:
    -- 交接班发生在哪一天是一件世界里的事实,不是 now() 的一个副产品。
    IF p_handover_date IS NULL THEN
        RAISE EXCEPTION 'HANDOVER_DATE_REQUIRED';
    END IF;
    IF p_shift_code IS NULL THEN
        RAISE EXCEPTION 'HANDOVER_SHIFT_REQUIRED';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shifts WHERE code = p_shift_code AND is_active) THEN
        RAISE EXCEPTION 'HANDOVER_SHIFT_UNKNOWN|%', p_shift_code
          USING HINT = '未知或已停用的班次。停用的意思是"以后别再排它",不是"把历史改掉"。';
    END IF;
    -- 【交与接【两个人都要有名有姓】】一次说不出是谁交的班,不是一次交接班。
    IF p_outgoing_employee_id IS NULL OR p_incoming_employee_id IS NULL THEN
        RAISE EXCEPTION 'HANDOVER_PEOPLE_REQUIRED'
          USING HINT = '交班的人与接班的人都要点名 —— 一次说不出是谁交给谁的交接班,没有传递任何责任。';
    END IF;
    IF p_outgoing_employee_id = p_incoming_employee_id THEN
        RAISE EXCEPTION 'HANDOVER_SAME_PERSON'
          USING HINT = '交班人与接班人是同一个人 —— 那样的"交接"没有把任何东西传给任何人。';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM employees WHERE id = p_outgoing_employee_id AND deleted_at IS NULL)
       OR NOT EXISTS (SELECT 1 FROM employees WHERE id = p_incoming_employee_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'HANDOVER_EMPLOYEE_NOT_FOUND';
    END IF;

    -- 【条目的类型必须是字典里的】—— 加第七类内容是【加一行字典】,
    -- 而不是在这里放行一个自由字符串。
    IF p_items IS NOT NULL AND jsonb_typeof(p_items) = 'array' THEN
        SELECT elem->>'item_type_code' INTO v_bad
          FROM jsonb_array_elements(p_items) elem
         WHERE NOT EXISTS (SELECT 1 FROM handover_item_types t
                            WHERE t.code = elem->>'item_type_code' AND t.is_active)
         LIMIT 1;
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION 'HANDOVER_ITEM_TYPE_UNKNOWN|%', v_bad;
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) elem
                    WHERE btrim(COALESCE(elem->>'body','')) = '') THEN
            RAISE EXCEPTION 'HANDOVER_ITEM_BODY_REQUIRED'
              USING HINT = '一条内容为空的条目与没有这条条目是同一件事,而它会在计数里冒充"填过了"。';
        END IF;
    END IF;

    -- 【必填的那几类:字典说了算,不是代码说了算】
    SELECT t.name_zh INTO v_bad
      FROM handover_item_types t
     WHERE t.is_active AND t.is_required
       AND NOT EXISTS (
           SELECT 1 FROM jsonb_array_elements(COALESCE(p_items,'[]'::jsonb)) elem
            WHERE elem->>'item_type_code' = t.code
              AND btrim(COALESCE(elem->>'body','')) <> '')
     LIMIT 1;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'HANDOVER_REQUIRED_ITEM_MISSING|%', v_bad;
    END IF;

    INSERT INTO shift_handovers (shift_code, handover_date, outgoing_employee_id,
                                 incoming_employee_id, notes, submitted_by, created_by, updated_by)
    VALUES (p_shift_code, p_handover_date, p_outgoing_employee_id, p_incoming_employee_id,
            NULLIF(btrim(COALESCE(p_notes,'')), ''), v_user, v_user, v_user)
    RETURNING id INTO v_id;

    IF p_items IS NOT NULL AND jsonb_typeof(p_items) = 'array' THEN
        INSERT INTO shift_handover_items (handover_id, item_type_code, body, sort_order, created_by)
        SELECT v_id, elem->>'item_type_code', btrim(elem->>'body'),
               COALESCE((elem->>'sort_order')::integer, ord::integer), v_user
          FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(elem, ord);
    END IF;

    -- R5:设备状态是一条【引用】。这里存 downtime_id,绝不抄一份 reason。
    IF p_downtime_ids IS NOT NULL AND array_length(p_downtime_ids, 1) > 0 THEN
        IF EXISTS (SELECT 1 FROM unnest(p_downtime_ids) d
                    WHERE NOT EXISTS (SELECT 1 FROM equipment_downtime e WHERE e.id = d)) THEN
            RAISE EXCEPTION 'HANDOVER_DOWNTIME_NOT_FOUND';
        END IF;
        INSERT INTO shift_handover_equipment_refs (handover_id, downtime_id, created_by)
        SELECT v_id, d, v_user FROM unnest(p_downtime_ids) d
        ON CONFLICT DO NOTHING;
    END IF;

    RETURN v_id;
END;
$function$

