-- db/functions/split_failed_modules_to_quarantine.sql
-- MES-5a-1(2026-10-08,规格 §3.1;MES-0 Q23;MES-5a Step 0 Q11,Tim):【把放电失败、处置为隔离的模组拆成另一批,放进隔离库位】
--   —— 从放电那一炉的页面上起。一笔事务里:
--     ① 判:那一炉是没回滚的 verifies_by_unit 工序;这一批是它的投料;每一个点名的模组在这一批上的最新结论是"失败 · 隔离"、还没被拆走
--        (DISCHARGE_SPLIT_MODULE_NOT_QUARANTINE|<模组>);至少点一个、不重复(DISCHARGE_SPLIT_MODULES_REQUIRED);
--        库位是一个在用的隔离库位(QUARANTINE_LOCATION_REQUIRED|charged_not_discharged|<库位编号或 unspecified> —— MES-3a 那条码,
--        同一句话;没有任何隔离库位时永远拒)。
--     ② 记一炉 discharge_quarantine_split(经 commit_processing_run —— 它照旧判 action.processing_commit、开始 / 结束 / 班次、称重、
--        火闸):原批消耗拆出去的那几个模组称出来的重量(p_weight_kg 敲一个 → 一条手工称重;或 p_weighing_id 挑一条),
--        产出同一物料的一批,重量就是那一次称重。
--     ③ 记下是哪几个模组(discharge_module_splits);新批的模组数 = 点名的个数;新批照抄原批此刻开着的安全状态
--        (它们是同一批模组 —— 原批没核实,所以那里面一定有"带电未放电"),记 created_by_run_id = 拆分那一炉(回滚拆分就把它们结束)。
--     ④ 把新批整批转进那个隔离库位(create_stock_transfer_internal —— 与库存转移同一份;门是本函数的码)。
--     ⑤ 照规则重判原批(拆走的模组算已处置;凑满了就核实,记下是拆分那一炉)。
--   码:action.processing_aftercare(Tim 的 Q10);记那一炉本身照旧还要 action.processing_commit(每一炉都要)——线上两码同一批人持。
--   返回 {split_run_id, split_run_code, batch_id, batch_code, modules, parent_verified}。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE OR REPLACE FUNCTION public.split_failed_modules_to_quarantine(p_discharge_run_id uuid, p_kind text, p_batch_id uuid, p_module_refs text[], p_process_date date, p_started_at timestamp with time zone, p_ended_at timestamp with time zone, p_shift_code text, p_location_id uuid, p_weight_kg numeric DEFAULT NULL::numeric, p_weighing_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_run      processing_runs%ROWTYPE;
    v_by_unit  boolean;
    v_refs     text[];
    v_ref      text;
    v_cur      record;
    v_material uuid;
    v_code     text;
    v_loc      storage_locations%ROWTYPE;
    v_qty      numeric;
    v_split    uuid;
    v_new      uuid;
    v_new_code text;
    v_ok       boolean;
BEGIN
    PERFORM require_permission('action.processing_aftercare');

    SELECT * INTO v_run FROM processing_runs WHERE id = p_discharge_run_id;
    IF NOT FOUND OR v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', COALESCE(v_run.code, COALESCE(p_discharge_run_id::text, '?'));
    END IF;
    SELECT ot.verifies_by_unit INTO v_by_unit FROM operation_types ot WHERE ot.code = v_run.operation_type_code;
    IF v_by_unit IS NOT TRUE THEN
        RAISE EXCEPTION 'DISCHARGE_RUN_NOT_BY_UNIT|%|%', v_run.code, COALESCE(v_run.operation_type_code, '?');
    END IF;
    IF p_kind = 'inbound' THEN
        SELECT b.material_id, b.code INTO v_material, v_code FROM inbound_batches b WHERE b.id = p_batch_id AND b.deleted_at IS NULL;
        IF NOT EXISTS (SELECT 1 FROM processing_inputs pi WHERE pi.run_id = v_run.id AND pi.inbound_batch_id = p_batch_id) THEN
            RAISE EXCEPTION 'DISCHARGE_BATCH_NOT_INPUT|%', v_run.code;
        END IF;
    ELSIF p_kind = 'output' THEN
        SELECT b.material_id, b.code INTO v_material, v_code FROM output_batches b WHERE b.id = p_batch_id AND b.deleted_at IS NULL;
        IF NOT EXISTS (SELECT 1 FROM processing_inputs pi WHERE pi.run_id = v_run.id AND pi.output_batch_id = p_batch_id) THEN
            RAISE EXCEPTION 'DISCHARGE_BATCH_NOT_INPUT|%', v_run.code;
        END IF;
    ELSE
        RAISE EXCEPTION 'BATCH_KIND_UNKNOWN|%', COALESCE(p_kind, '?');
    END IF;

    SELECT array_agg(DISTINCT x ORDER BY x) INTO v_refs
      FROM unnest(COALESCE(p_module_refs, ARRAY[]::text[])) r(y), LATERAL (SELECT NULLIF(btrim(r.y), '') AS x) z
     WHERE z.x IS NOT NULL;
    IF v_refs IS NULL OR cardinality(v_refs) = 0
       OR cardinality(v_refs) <> (SELECT count(*) FROM unnest(p_module_refs) y WHERE NULLIF(btrim(y), '') IS NOT NULL) THEN
        RAISE EXCEPTION 'DISCHARGE_SPLIT_MODULES_REQUIRED';
    END IF;
    FOREACH v_ref IN ARRAY v_refs LOOP
        SELECT * INTO v_cur FROM discharge_module_current_all c WHERE c.batch_id = p_batch_id AND c.module_ref = v_ref;
        IF NOT FOUND OR v_cur.split_out OR v_cur.verdict <> 'fail' OR v_cur.disposition IS DISTINCT FROM 'quarantine' THEN
            RAISE EXCEPTION 'DISCHARGE_SPLIT_MODULE_NOT_QUARANTINE|%', v_ref
              USING HINT = '只能拆最新一条结论是"失败、处置为隔离"、而且还没被拆走的模组。';
        END IF;
    END LOOP;

    SELECT * INTO v_loc FROM storage_locations l WHERE l.id = p_location_id AND l.is_active AND l.is_quarantine;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'QUARANTINE_LOCATION_REQUIRED|charged_not_discharged|%',
            COALESCE((SELECT l.code FROM storage_locations l WHERE l.id = p_location_id), 'unspecified')
          USING HINT = '拆出来的失效模组只能进一个在用的隔离库位。还没有隔离库位,先在库位编辑器里标一个。';
    END IF;

    IF p_weighing_id IS NOT NULL THEN
        SELECT w.weight_kg INTO v_qty FROM weighings w WHERE w.id = p_weighing_id;
    ELSE
        v_qty := p_weight_kg;
    END IF;
    IF v_qty IS NULL OR v_qty <= 0 THEN
        RAISE EXCEPTION 'OUTPUT_WEIGHING_REQUIRED|1'
          USING HINT = '拆出去的那几个模组要称一次:敲一个重量,或挑一条现成的称重。';
    END IF;

    v_split := commit_processing_run(
        p_process_date, COALESCE(NULLIF(btrim(COALESCE(p_notes, '')), ''), 'Quarantine split of ' || array_to_string(v_refs, ', ') || ' from ' || v_run.code),
        NULL,
        jsonb_build_array(CASE WHEN p_kind = 'inbound'
                               THEN jsonb_build_object('inbound_batch_id', p_batch_id, 'quantity_consumed', v_qty)
                               ELSE jsonb_build_object('output_batch_id', p_batch_id, 'quantity_consumed', v_qty) END),
        jsonb_build_array(CASE WHEN p_weighing_id IS NOT NULL
                               THEN jsonb_build_object('material_id', v_material, 'weighing_id', p_weighing_id)
                               ELSE jsonb_build_object('material_id', v_material, 'weight_kg', v_qty) END),
        'weight', NULL, NULL, 'discharge_quarantine_split', p_started_at, p_ended_at, p_shift_code, NULL, NULL, NULL);

    SELECT po.output_batch_id, ob.code INTO v_new, v_new_code
      FROM processing_outputs po JOIN output_batches ob ON ob.id = po.output_batch_id WHERE po.run_id = v_split;

    INSERT INTO discharge_module_splits (split_run_id, discharge_run_id, inbound_batch_id, output_batch_id, module_ref, new_output_batch_id)
    SELECT v_split, v_run.id, CASE WHEN p_kind = 'inbound' THEN p_batch_id END, CASE WHEN p_kind = 'output' THEN p_batch_id END, r, v_new
      FROM unnest(v_refs) r;

    UPDATE output_batches SET module_count = cardinality(v_refs) WHERE id = v_new;

    IF p_kind = 'inbound' THEN
        INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code, created_by_run_id)
        SELECT v_new, s.safety_state_code, v_split FROM inbound_batch_safety_states s
         WHERE s.inbound_batch_id = p_batch_id AND s.ended_at IS NULL;
    ELSE
        INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code, created_by_run_id)
        SELECT v_new, s.safety_state_code, v_split FROM output_batch_safety_states s
         WHERE s.output_batch_id = p_batch_id AND s.ended_at IS NULL;
    END IF;

    PERFORM create_stock_transfer_internal(v_qty, v_loc.id, NULL, v_new, NULL, 'available',
                                           'Quarantine split ' || (SELECT pr.code FROM processing_runs pr WHERE pr.id = v_split));

    v_ok := discharge_verify_batch(p_kind, p_batch_id, v_split, 'failed modules split to quarantine');

    RETURN jsonb_build_object('split_run_id', v_split, 'split_run_code', (SELECT pr.code FROM processing_runs pr WHERE pr.id = v_split),
                              'batch_id', v_new, 'batch_code', v_new_code, 'modules', to_jsonb(v_refs), 'parent_verified', v_ok,
                              'parent_code', v_code);
END;
$function$
