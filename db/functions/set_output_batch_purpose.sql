CREATE OR REPLACE FUNCTION public.set_output_batch_purpose(p_output_batch_id uuid, p_purpose_code text, p_awaiting_operation_type_code text DEFAULT NULL::text)
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
    v_saleable boolean;
    v_await   text;
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
    SELECT is_saleable_stock INTO v_saleable FROM public.output_batch_purposes
     WHERE code = p_purpose_code AND is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'BATCH_PURPOSE_UNKNOWN|%', COALESCE(p_purpose_code, '(null)');
    END IF;

    -- 【释放指定就把"在等哪一道"一并清掉】留着它会造出一个自相矛盾行,
    -- 而守卫会把这次释放整个拒掉 —— 那等于让"释放"这个动作莫名其妙地失败。
    -- **清掉是这扇门的责任,不是调用者要记得的一步。**
    v_await := CASE WHEN v_saleable THEN NULL ELSE p_awaiting_operation_type_code END;

    IF v_await IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.operation_types
                        WHERE code = v_await AND is_active) THEN
        RAISE EXCEPTION 'WIP_OPERATION_UNKNOWN|%', v_await
          USING HINT = '没有这一道工序,或者它已经停用了。到【设置 → 工序】看一眼有哪些。';
    END IF;

    UPDATE public.output_batches
       SET purpose_code = p_purpose_code,
           awaiting_operation_type_code = v_await,
           updated_by   = v_user,
           updated_at   = now()
     WHERE id = p_output_batch_id;

    RETURN jsonb_build_object(
        'output_batch_id', p_output_batch_id,
        'code', v_code,
        'purpose_from', v_old,
        'purpose_to', p_purpose_code,
        'awaiting_operation', v_await);
END;
$function$
