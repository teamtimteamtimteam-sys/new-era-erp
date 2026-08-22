CREATE OR REPLACE FUNCTION public.record_assay_result(
    p_assay_date date,
    p_metals jsonb,
    p_lab_name text DEFAULT NULL::text,
    p_certificate_ref text DEFAULT NULL::text,
    p_sample_ref text DEFAULT NULL::text,
    p_is_final boolean DEFAULT true,
    p_notes text DEFAULT NULL::text,
    p_inbound_batch_id uuid DEFAULT NULL::uuid,
    p_output_batch_id uuid DEFAULT NULL::uuid,
    -- ── PROC-6 追加(尾部,带默认,与 PROC-2c 的做法一致)────────────────────
    -- 【两个都默认 NULL,而"必填"由别处执行】
    --   weight_basis  → 触发器(旧行补不出来,所以只管新行)
    --   result_party  → 本函数里具名拒绝 + 列上 NOT NULL 兜底
    -- 这里【不】给业务默认值:默认会让"忘了填"静静变成一个可以拿去算钱的答案。
    p_weight_basis text DEFAULT NULL::text,
    p_moisture_pct numeric DEFAULT NULL::numeric,
    p_result_party text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_id    uuid := gen_random_uuid();
    v_code  text;
    v_el    jsonb;
    v_metal text;
    v_pct   numeric;
    v_seen  text[] := ARRAY[]::text[];
    v_count integer := 0;
BEGIN
    -- PROC-1:两个父【二选一】。记录、编号、取代共享一张表一条序列;
    -- 权限跟着父走 —— 进料化验挂 inbound 模块,产出化验挂 output 模块。
    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN
        RAISE EXCEPTION 'ASSAY_ONE_PARENT';
    END IF;
    IF p_inbound_batch_id IS NOT NULL THEN
        PERFORM require_permission('module.inbound.edit');
        IF NOT EXISTS (
            SELECT 1 FROM inbound_batches WHERE id = p_inbound_batch_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
        END IF;
    ELSE
        PERFORM require_permission('module.output.edit');
        IF NOT EXISTS (
            SELECT 1 FROM output_batches WHERE id = p_output_batch_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', COALESCE(p_output_batch_id::text, '?');
        END IF;
    END IF;
    IF p_assay_date IS NULL OR p_assay_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'ASSAY_DATE_INVALID|%', COALESCE(p_assay_date::text, '?');
    END IF;
    IF p_metals IS NULL OR jsonb_typeof(p_metals) <> 'array' OR jsonb_array_length(p_metals) = 0 THEN
        RAISE EXCEPTION 'NO_METALS';
    END IF;

    -- PROC-6:出具方必须明说。**在这里具名拒绝,而不是等列上的 NOT NULL 抛机器话** ——
    -- 一个具名码翻得成人话,一个 null-value violation 翻不成。
    IF p_result_party IS NULL THEN
        RAISE EXCEPTION 'ASSAY_RESULT_PARTY_REQUIRED'
          USING HINT = '这一份结果是我们出的、对手方出的、还是仲裁实验室出的?没有默认值 —— 默认会让"忘了改"变成"这是我们测的"。';
    END IF;

    v_code := next_assay_code(p_assay_date);
    INSERT INTO assay_results (id, code, inbound_batch_id, output_batch_id, assay_date, lab_name,
                               certificate_ref, sample_ref, is_final, notes,
                               weight_basis, moisture_pct, result_party,
                               created_by, updated_by)
    VALUES (v_id, v_code, p_inbound_batch_id, p_output_batch_id, p_assay_date, p_lab_name,
            p_certificate_ref, p_sample_ref, p_is_final, p_notes,
            p_weight_basis, p_moisture_pct, p_result_party,
            v_user, v_user);

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_metals)
    LOOP
        v_metal := v_el->>'metal';
        -- 【PROC-6 顺手修的一处 PROC-4 漏网】这里原本写着
        --     v_metal NOT IN ('ni','co','li','mn','cu','al','fe')
        -- —— **那是那份金属清单的第九个副本**,而 PROC-4 声称已经清干净了。
        -- 它没有:PROC-4 的 S1 只查了 pg_constraint,【没有查函数体】。
        -- 线上实测函数体里还有四份(见 docs/known-issues.md),本刀只修它正在
        -- 重建的这一支 —— 另外三支按名排期,不在这一刀里顺手动。
        -- 现在它读字典,于是"加一种物质"真的只要一行。
        IF v_metal IS NULL OR NOT EXISTS (SELECT 1 FROM substances WHERE code = v_metal) THEN
            RAISE EXCEPTION 'METAL_INVALID|%', COALESCE(v_metal, '?');
        END IF;
        IF v_metal = ANY (v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_METAL|%', v_metal;
        END IF;
        v_seen := v_seen || v_metal;
        v_pct := (v_el->>'content_pct')::numeric;
        IF v_pct IS NULL OR v_pct < 0 OR v_pct > 100 THEN
            RAISE EXCEPTION 'CONTENT_INVALID|%|%', v_metal, COALESCE((v_el->>'content_pct'), '?');
        END IF;
        INSERT INTO assay_result_metals (assay_result_id, metal, content_pct)
        VALUES (v_id, v_metal, v_pct);
        v_count := v_count + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'assay_result_id', v_id,
        'code', v_code,
        'metal_count', v_count
    );
END;
$function$

;
