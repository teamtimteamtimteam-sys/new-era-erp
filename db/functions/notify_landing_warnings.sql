CREATE OR REPLACE FUNCTION public.notify_landing_warnings(p_warn text[], p_location_id uuid, p_material_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    w        text;
    v_code   text;
    v_loc    text;
    v_mat    text;
    v_actor  uuid := auth.uid();
BEGIN
    IF p_warn IS NULL OR array_length(p_warn, 1) IS NULL THEN
        RETURN;
    END IF;

    SELECT code INTO v_loc FROM storage_locations WHERE id = p_location_id;
    SELECT code INTO v_mat FROM materials         WHERE id = p_material_id;

    FOREACH w IN ARRAY p_warn LOOP
        v_code := split_part(w, '|', 1);

        IF v_code = 'IOD_CLASS_UNCONFIGURED_LOCATION' THEN
            INSERT INTO notifications (event_type, subject_type, subject_id, subject_code, payload, actor_user_id)
            VALUES ('iod_class_unconfigured_location', 'storage_location', p_location_id, v_loc,
                    jsonb_build_object('code', v_code,
                                       'location_id', p_location_id, 'location_code', v_loc,
                                       'material_id', p_material_id, 'material_code', v_mat,
                                       'fingerprint', 'landing|' || v_code || '|' || COALESCE(p_location_id::text,'') || '|' || COALESCE(p_material_id::text,'')),
                    v_actor);

        ELSIF v_code = 'IOD_MATERIAL_UNCLASSIFIED' THEN
            INSERT INTO notifications (event_type, subject_type, subject_id, subject_code, payload, actor_user_id)
            VALUES ('iod_material_unclassified', 'material', p_material_id, v_mat,
                    jsonb_build_object('code', v_code,
                                       'location_id', p_location_id, 'location_code', v_loc,
                                       'material_id', p_material_id, 'material_code', v_mat,
                                       'fingerprint', 'landing|' || v_code || '|' || COALESCE(p_location_id::text,'') || '|' || COALESCE(p_material_id::text,'')),
                    v_actor);
        END IF;
        -- 【未知的码不发通知,也不抛】:告警码的集合会长,而一次收货不该因为
        -- 通知这一侧没跟上而失败。漏发是看得见的(码在 warnings 里照样上屏)。
    END LOOP;
END;
$function$

;
