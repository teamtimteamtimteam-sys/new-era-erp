-- db/functions/soft_delete_output_batch_internal.sql
-- APR-7(2026-09-25):注销一张产出批 —— ROLE-1 Batch 3b 的 soft_delete_output_batch 的函数体原样搬进来,
-- 只拿掉了码的检查、加了 p_deleted_by(grilling Q6:deleted_by = 提单人;不给 = 调用者本人)。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.soft_delete_output_batch_internal(p_batch_id uuid, p_reason text, p_deleted_by uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := COALESCE(p_deleted_by, auth.uid());
    v_code text;
BEGIN
    -- ★ APR-7:本支是注销那一步【本身】,不问码 —— 调用者见 soft_delete_inbound_batch_internal 同一句。
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
