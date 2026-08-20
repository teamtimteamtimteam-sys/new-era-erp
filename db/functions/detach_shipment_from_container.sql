CREATE OR REPLACE FUNCTION public.detach_shipment_from_container(p_shipment_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_ship text; v_old uuid;
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    -- 【拆箱要理由】。装错箱与改主意是两件事,而事后只有理由分得开它们。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'DETACH_REASON_REQUIRED|%',
            COALESCE((SELECT code FROM shipments WHERE id = p_shipment_id), '?');
    END IF;
    SELECT code, container_id INTO v_ship, v_old FROM shipments WHERE id = p_shipment_id FOR UPDATE;
    IF v_ship IS NULL THEN
        RAISE EXCEPTION 'SHIPMENT_NOT_FOUND|%', COALESCE(p_shipment_id::text, '?');
    END IF;
    IF v_old IS NULL THEN
        RAISE EXCEPTION 'SHIPMENT_NOT_IN_A_CONTAINER|%', v_ship;
    END IF;

    UPDATE shipments SET container_id = NULL WHERE id = p_shipment_id;
    -- 理由留在箱子的里程碑上 —— 这一层的留痕就在那里,不另开一张表
    INSERT INTO public.container_milestones (container_id, milestone, event_date, note, recorded_by)
    VALUES (v_old, 'other', CURRENT_DATE,
            'detached ' || v_ship || ': ' || btrim(p_reason), auth.uid());
    RETURN jsonb_build_object('shipment', v_ship, 'detached_from', v_old);
END;
$function$

