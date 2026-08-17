CREATE OR REPLACE FUNCTION public.soft_delete_output_batch(p_batch_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_code text;
BEGIN
    PERFORM require_permission('module.output.edit');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'DELETE_REASON_REQUIRED|output_batches|%',
            COALESCE((SELECT code FROM output_batches WHERE id = p_batch_id), '?');
    END IF;

    SELECT code INTO v_code FROM output_batches
     WHERE id = p_batch_id AND deleted_at IS NULL FOR UPDATE;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', COALESCE(p_batch_id::text, '?');
    END IF;

    PERFORM set_config('evoltrya.soft_delete_ctx', '1', true);
    UPDATE output_batches
       SET deleted_at = now(), deleted_by = v_user, delete_reason = btrim(p_reason),
           updated_by = v_user, updated_at = now()
     WHERE id = p_batch_id;
    PERFORM set_config('evoltrya.soft_delete_ctx', '', true);

    RETURN jsonb_build_object('id', p_batch_id, 'code', v_code, 'deleted_by', v_user);
END;
$function$;
