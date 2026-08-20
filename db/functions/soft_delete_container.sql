CREATE OR REPLACE FUNCTION public.soft_delete_container(p_container_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_user uuid := auth.uid(); v_code text;
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    -- 【理由必填,拒绝按名】—— AUDEL 家族那一条:没有理由的注销,事后没人答得出为什么。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'DELETE_REASON_REQUIRED|containers|%',
            COALESCE((SELECT code FROM containers WHERE id = p_container_id), '?');
    END IF;
    SELECT code INTO v_code FROM containers
     WHERE id = p_container_id AND deleted_at IS NULL FOR UPDATE;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'CONTAINER_NOT_FOUND|%', COALESCE(p_container_id::text, '?');
    END IF;
    UPDATE containers
       SET deleted_at = now(), deleted_by = v_user, delete_reason = btrim(p_reason),
           updated_by = v_user
     WHERE id = p_container_id;
    RETURN jsonb_build_object('id', p_container_id, 'code', v_code, 'deleted_by', v_user);
END;
$function$

