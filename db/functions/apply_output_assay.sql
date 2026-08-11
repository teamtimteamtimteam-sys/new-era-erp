CREATE OR REPLACE FUNCTION public.apply_output_assay(p_assay_result_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_assay record;
    v_batch record;
    v_prior uuid;
    v_count integer;
    v_run   record;
BEGIN
    PERFORM require_permission('module.output.edit');
    SELECT * INTO v_assay FROM assay_results
    WHERE id = p_assay_result_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_assay_result_id::text, '?');
    END IF;
    -- 进料化验不走这条路:它的应用【就是】重算应付,少了那一半不叫应用。
    IF v_assay.output_batch_id IS NULL THEN
        RAISE EXCEPTION 'ASSAY_IS_INBOUND|%', v_assay.code;
    END IF;
    IF v_assay.applied_at IS NOT NULL THEN
        RAISE EXCEPTION 'ASSAY_ALREADY_APPLIED|%', v_assay.code;
    END IF;

    SELECT * INTO v_batch FROM output_batches
    WHERE id = v_assay.output_batch_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', v_assay.output_batch_id;
    END IF;

    -- 批次含量 = 本化验的含量(删后重插,同进料侧)。行带出处;updated_at/created_at
    -- 因此更新 —— 过期视图的第六个来源读的就是它,这一写【就是】举旗动作本身。
    DELETE FROM output_batch_metals WHERE output_batch_id = v_batch.id;
    INSERT INTO output_batch_metals (output_batch_id, metal, content_pct,
                                     content_source, source_assay_id, created_by, updated_by)
    SELECT v_batch.id, arm.metal, arm.content_pct, 'assay', p_assay_result_id, v_user, v_user
    FROM assay_result_metals arm
    WHERE arm.assay_result_id = p_assay_result_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;

    -- 取代链:与进料侧同一条规则,按【产出批】成链(进料链与产出链互不相扰)
    SELECT id INTO v_prior FROM assay_results
    WHERE output_batch_id = v_batch.id AND id <> p_assay_result_id
      AND applied_at IS NOT NULL AND superseded_by IS NULL AND deleted_at IS NULL
    ORDER BY applied_at DESC, code DESC LIMIT 1;
    IF v_prior IS NOT NULL THEN
        UPDATE assay_results SET superseded_by = p_assay_result_id, updated_by = v_user
        WHERE id = v_prior;
    END IF;

    UPDATE assay_results
    SET applied_at = now(), applied_by = v_user, updated_by = v_user
    WHERE id = p_assay_result_id;

    -- 产出它的那张加工单:若已分摊,这次应用让 metal_value 拆分过期(过期视图
    -- 自己会说;这里把"哪张单、有没有分摊过"报出来,界面不用再拼)。
    SELECT r.id, r.code, r.allocated_at INTO v_run
    FROM processing_outputs po
    JOIN processing_runs r ON r.id = po.run_id AND r.deleted_at IS NULL
    WHERE po.output_batch_id = v_batch.id
    LIMIT 1;

    RETURN jsonb_build_object(
        'assay_result_id', p_assay_result_id,
        'code', v_assay.code,
        'output_batch_id', v_batch.id,
        'batch_code', v_batch.code,
        'metal_count', v_count,
        'superseded_prior', v_prior IS NOT NULL,
        'producing_run_code', v_run.code,
        'producing_run_allocated_at', v_run.allocated_at,
        'allocation_now_stale', v_run.allocated_at IS NOT NULL
    );
END;
$function$
;
