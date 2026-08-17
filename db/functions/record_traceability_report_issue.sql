CREATE OR REPLACE FUNCTION public.record_traceability_report_issue(p_output_batch_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ob    record;
    v_data  jsonb;
    v_next  integer;
    v_code  text;
BEGIN
    -- 【记档案这个动作要 edit,而读报告要 view】两件事,两道门。
    -- 取 OR 的 edit 侧,理由与读那一侧相同(见本迁移抬头的角色矩阵)。
    IF NOT has_any_permission(ARRAY['module.sales.edit', 'module.processing.edit']) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED';
    END IF;

    SELECT ob.id, ob.code INTO v_ob
      FROM output_batches ob
     WHERE ob.id = p_output_batch_id AND ob.deleted_at IS NULL
     FOR UPDATE;

    -- ── 三条拒绝,有序:先分清"不是批次" / "不是产出批" / "没有可报的东西" ──
    IF NOT FOUND THEN
        IF EXISTS (SELECT 1 FROM inbound_batches ib WHERE ib.id = p_output_batch_id) THEN
            RAISE EXCEPTION 'NOT_AN_OUTPUT_BATCH|%',
                (SELECT ib.code FROM inbound_batches ib WHERE ib.id = p_output_batch_id);
        END IF;
        RAISE EXCEPTION 'BATCH_NOT_FOUND|%', COALESCE(p_output_batch_id::text, '?');
    END IF;

    -- 【第三条不自己重判,而是问推导本身】"有没有可报的东西"只有那个函数说了算;
    -- 在这里再写一遍判据,就是让同一件事有两处实现(而它们迟早各说各话)。
    -- 它抛的 NOTHING_TO_REPORT 原样往上走 —— 那正是要说的那句话。
    v_data := traceability_report_data(p_output_batch_id);

    -- 【版本由数据库裁决】对象键不含版本号,并发安全靠这把每批次一把的咨询锁
    -- (与另外六个族逐字同一套)。
    PERFORM pg_advisory_xact_lock(hashtext('traceability_report_' || p_output_batch_id::text)::bigint);
    SELECT COALESCE(MAX(version), 0) + 1, MIN(code)
      INTO v_next, v_code
      FROM traceability_report_issues WHERE output_batch_id = p_output_batch_id;

    -- 第 1 版铸号;之后沿用 —— 客户引用的是那个号。
    IF v_code IS NULL THEN
        v_code := next_traceability_report_code();
    END IF;

    INSERT INTO traceability_report_issues
        (output_batch_id, code, version, file_path, sha256, issued_by)
    VALUES (p_output_batch_id, v_code, v_next, p_file_path, p_sha256, auth.uid());

    RETURN jsonb_build_object(
        'output_batch_id', p_output_batch_id,
        'batch_code', v_ob.code,
        'code', v_code,
        'version', v_next,
        'chain_row_count', v_data->'chain_row_count',
        'recovery_row_count', v_data->'recovery_row_count');
END;
$function$;
