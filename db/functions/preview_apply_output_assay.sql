CREATE OR REPLACE FUNCTION public.preview_apply_output_assay(p_output_batch_id uuid, p_assay_result_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_assay   record;
    v_batch   record;
    v_run     record;
    v_current jsonb;
    v_next    jsonb := NULL;
BEGIN
    -- 试算给要按"应用"的人看 —— 权限同 apply_output_assay
    PERFORM require_permission('module.output.edit');

    SELECT * INTO v_batch FROM output_batches
    WHERE id = p_output_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', COALESCE(p_output_batch_id::text, '?');
    END IF;

    IF p_assay_result_id IS NOT NULL THEN
        SELECT * INTO v_assay FROM assay_results
        WHERE id = p_assay_result_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_assay_result_id::text, '?');
        END IF;
        -- 与 apply_output_assay 同一串拒绝,同一串码(试算在应用会拒的地方同样拒)
        IF v_assay.output_batch_id IS NULL THEN
            RAISE EXCEPTION 'ASSAY_IS_INBOUND|%', v_assay.code;
        END IF;
        IF v_assay.output_batch_id <> p_output_batch_id THEN
            -- 挂在别的产出批上:对这个批次而言它不存在
            RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', v_assay.code;
        END IF;
        IF v_assay.applied_at IS NOT NULL THEN
            RAISE EXCEPTION 'ASSAY_ALREADY_APPLIED|%', v_assay.code;
        END IF;

        SELECT jsonb_agg(jsonb_build_object('metal', arm.metal, 'content_pct', arm.content_pct)
                         ORDER BY arm.metal)
        INTO v_next
        FROM assay_result_metals arm
        WHERE arm.assay_result_id = p_assay_result_id;
    END IF;

    -- 当前含量,带出处 —— "被顶掉的是谁说的数"是这个预览存在的一半理由
    SELECT jsonb_agg(jsonb_build_object(
               'metal', obm.metal,
               'content_pct', obm.content_pct,
               'content_source', obm.content_source,
               'source_assay_code', src.code)
           ORDER BY obm.metal)
    INTO v_current
    FROM output_batch_metals obm
    LEFT JOIN assay_results src ON src.id = obm.source_assay_id
    WHERE obm.output_batch_id = p_output_batch_id;

    -- 产出它的加工单与过期后果。谓词与过期视图第六源同一条判断
    -- (metal_value 限定);fixture 54 的 I/D 臂把两者钉在一起。
    SELECT r.id, r.code, r.allocated_at, r.allocation_basis INTO v_run
    FROM processing_outputs po
    JOIN processing_runs r ON r.id = po.run_id AND r.deleted_at IS NULL
    WHERE po.output_batch_id = p_output_batch_id
    LIMIT 1;

    RETURN jsonb_build_object(
        'output_batch_id', p_output_batch_id,
        'batch_code', v_batch.code,
        'current_metals', COALESCE(v_current, '[]'::jsonb),
        'assay_metals', v_next,
        'producing_run_id', v_run.id,
        'producing_run_code', v_run.code,
        'producing_run_allocated_at', v_run.allocated_at,
        'producing_run_basis', v_run.allocation_basis,
        'will_flag_stale', v_run.allocated_at IS NOT NULL
                           AND v_run.allocation_basis = 'metal_value'
    );
END;
$function$
;
