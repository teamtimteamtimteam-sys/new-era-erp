CREATE OR REPLACE FUNCTION public.traceability_report_data(p_output_batch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ob     record;
    v_chain  jsonb;
    v_runs   jsonb;
    v_rec    jsonb;
    v_depth  integer;
BEGIN
    -- 【OR,不是 AND】理由与实测的角色矩阵写在本迁移抬头。
    IF NOT has_any_permission(ARRAY['module.sales.view', 'module.processing.view']) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED';
    END IF;

    IF p_output_batch_id IS NULL THEN
        RAISE EXCEPTION 'BATCH_REQUIRED';
    END IF;

    SELECT ob.id, ob.code, ob.quantity, ob.remaining_qty, ob.unit, ob.output_date,
           m.code AS material_code, m.name AS material_name
      INTO v_ob
      FROM output_batches ob
      LEFT JOIN materials m ON m.id = ob.material_id
     WHERE ob.id = p_output_batch_id AND ob.deleted_at IS NULL;

    IF NOT FOUND THEN
        -- 【三条拒绝是【有序】的,而顺序本身是内容】先分清"这个 id 根本不是一个
        -- 批次"与"它是个批次、但不是产出批":后者是拿进料批的 id 来要报告 ——
        -- 一个可以理解的错,而它值得一句说得清的话,不是一句 NOT_FOUND。
        IF EXISTS (SELECT 1 FROM inbound_batches ib WHERE ib.id = p_output_batch_id) THEN
            RAISE EXCEPTION 'NOT_AN_OUTPUT_BATCH|%',
                (SELECT ib.code FROM inbound_batches ib WHERE ib.id = p_output_batch_id);
        END IF;
        RAISE EXCEPTION 'BATCH_NOT_FOUND|%', COALESCE(p_output_batch_id::text, '?');
    END IF;

    -- ── 血缘:读【基视图】,绝不第二次递归 ──────────────────────────────────
    -- 供应商与到货日是在链条【末端的进料批】上 join 出来的,不是又一次递归:
    -- "供应商批次 → 收货" 那两格就住在 inbound_batches 那一行上。
    -- 【供应商名是随单据走的展示标签】(AGENTS.md 常设决定 3),不另设一道门 ——
    -- 何况这份东西的用途就是交到客户手里。
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'depth', l.depth,
               'via_run_id', l.via_run_id,
               'via_run_code', l.via_run_code,
               'parent_kind', l.parent_kind,
               'parent_batch_id', l.parent_batch_id,
               'parent_code', l.parent_code,
               'quantity_consumed', l.quantity_consumed,
               -- 只有进料父才有供应商与到货日;产出父是上一段的产物。
               'supplier_name', sup.legal_name,
               'supplier_code', sup.code,
               'arrival_date', ib.arrival_date,
               'material_code', im.code)
               ORDER BY l.depth, l.via_run_code, l.parent_code), '[]'::jsonb),
           max(l.depth)
      INTO v_chain, v_depth
      FROM batch_lineage_all l
      LEFT JOIN inbound_batches ib ON ib.id = l.parent_batch_id AND l.parent_kind = 'inbound'
      LEFT JOIN suppliers sup ON sup.id = ib.supplier_id
      LEFT JOIN materials im ON im.id = ib.material_id
     WHERE l.output_batch_id = p_output_batch_id;

    -- 【没有血缘 = 没有可报的东西,而它有一个真实的成因】线上四个产出批正是这样:
    -- 生产它们的加工单被冲销并软删,而血缘刻意不看已回滚的单。
    -- 这时候【不能】发一份"来源不详"的报告去糊弄审计 —— 空表比空报告诚实。
    IF jsonb_array_length(v_chain) = 0 THEN
        RAISE EXCEPTION 'NOTHING_TO_REPORT|%', v_ob.code;
    END IF;

    -- ── 涉及的加工单(链条上的每一支,不只是最后那一支)──────────────────
    SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_object(
               'run_id', l.via_run_id, 'run_code', l.via_run_code)), '[]'::jsonb)
      INTO v_runs
      FROM batch_lineage_all l
     WHERE l.output_batch_id = p_output_batch_id;

    -- ── 每支加工单 × 金属的回收行,【逐列原样带走】────────────────────────
    -- 【报告【携带】这些列,绝不重算】input_source / output_source /
    -- recovery_blocked_by / conservation_warning 是那张视图对"它除的是哪一种数"
    -- 的判词(REC-1 与 PROC-1 的全部要点)。在这里重算一遍,就是让同一件事有了
    -- 第二份实现,而这个仓库为这个形状付过四次学费。
    -- 【NULL 的回收率带着它的具名原因走】—— 绝不用一个数字替代它。
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'run_id', r.run_id,
               'run_code', r.run_code,
               'process_date', r.process_date,
               'metal', r.metal,
               'input_metal_kg', r.input_metal_kg,
               'output_metal_kg', r.output_metal_kg,
               'input_measured', r.input_measured,
               'output_measured', r.output_measured,
               'recovery_pct', r.recovery_pct,
               'recovery_blocked_by', r.recovery_blocked_by,
               'conservation_warning', r.conservation_warning,
               'run_recovery_computable', r.run_recovery_computable,
               'input_source', r.input_source,
               'output_source', r.output_source)
               ORDER BY r.run_code, r.metal), '[]'::jsonb)
      INTO v_rec
      FROM processing_metal_recovery_all r
     WHERE r.run_id IN (SELECT DISTINCT l.via_run_id
                          FROM batch_lineage_all l
                         WHERE l.output_batch_id = p_output_batch_id);

    RETURN jsonb_build_object(
        'output_batch', jsonb_build_object(
            'id', v_ob.id, 'code', v_ob.code,
            'material_code', v_ob.material_code, 'material_name', v_ob.material_name,
            'quantity', v_ob.quantity, 'remaining_qty', v_ob.remaining_qty,
            'unit', v_ob.unit, 'output_date', v_ob.output_date),
        'chain', v_chain,
        'chain_depth', v_depth,
        'runs', v_runs,
        'recovery', v_rec,
        'chain_row_count', jsonb_array_length(v_chain),
        'recovery_row_count', jsonb_array_length(v_rec)
    );
END;
$function$;
