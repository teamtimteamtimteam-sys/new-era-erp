CREATE OR REPLACE FUNCTION public.instantiate_container_documents(p_container_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_lane uuid; v_state text; v_n integer := 0;
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    SELECT lane_id INTO v_lane FROM containers WHERE id = p_container_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTAINER_NOT_FOUND|%', COALESCE(p_container_id::text, '?');
    END IF;
    IF v_lane IS NULL THEN
        RETURN jsonb_build_object('lane_state', 'no_lane', 'created', 0);
    END IF;

    SELECT checklist_state INTO v_state FROM lane_checklist_status WHERE lane_id = v_lane;

    -- 【三种状态原样传出去,不折叠成一个数字】。把 not_defined answer 成 created=0,
    -- 就是把"没人看过"说成"什么都不需要"。
    IF v_state = 'not_defined' THEN
        RETURN jsonb_build_object('lane_state', 'not_defined', 'created', 0);
    END IF;

    INSERT INTO container_documents (container_id, document_type, regime, from_lane)
    SELECT p_container_id, r.document_type, r.regime, true
      FROM lane_document_requirements r
     WHERE r.lane_id = v_lane AND r.deleted_at IS NULL
       AND NOT EXISTS (SELECT 1 FROM container_documents d
                        WHERE d.container_id = p_container_id
                          AND d.document_type = r.document_type
                          AND d.from_lane);
    GET DIAGNOSTICS v_n = ROW_COUNT;

    RETURN jsonb_build_object('lane_state', v_state, 'created', v_n);
END;
$function$

