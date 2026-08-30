CREATE OR REPLACE FUNCTION public.set_output_batch_purpose(p_output_batch_id uuid, p_purpose_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_code    text;
    v_deleted timestamptz;
    v_old     text;
BEGIN
    PERFORM public.require_permission('module.processing.edit');

    SELECT code, deleted_at, purpose_code INTO v_code, v_deleted, v_old
      FROM public.output_batches WHERE id = p_output_batch_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', p_output_batch_id;
    END IF;
    IF v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'OUTPUT_DELETED|%', v_code;
    END IF;

    -- 【停用的用途不许再被指派上去,但既有的行不动】—— 与 is_active 在别处
    -- 的意思一致:停用是"以后别再选它",不是"把历史改掉"。
    IF NOT EXISTS (SELECT 1 FROM public.output_batch_purposes
                    WHERE code = p_purpose_code AND is_active) THEN
        RAISE EXCEPTION 'BATCH_PURPOSE_UNKNOWN|%', COALESCE(p_purpose_code, '(null)');
    END IF;

    UPDATE public.output_batches
       SET purpose_code = p_purpose_code,
           updated_by   = v_user,
           updated_at   = now()
     WHERE id = p_output_batch_id;

    RETURN jsonb_build_object(
        'output_batch_id', p_output_batch_id,
        'code', v_code,
        'purpose_from', v_old,
        'purpose_to', p_purpose_code);
END;
$function$
