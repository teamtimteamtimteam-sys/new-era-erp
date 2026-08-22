-- 83 可追溯报告【携带】那些判词,不重算它们 —— 而链条要走满两段
--
-- 【为什么这份 fixture 必须自己造两段链】AUD-1 的地面普查发现:**线上没有两段链。**
-- batch_lineage 上每个产出批的 max(depth) 都是 1。唯一那条再加工边确实存在
-- (PROC-2026-0143 耗了 OUT-2026-0159),**但那两支加工单都已 reversed 且软删**,
-- 而 batch_lineage 的两个 join 都带 pr.deleted_at IS NULL —— 于是它在在册数据里不存在。
-- 拿线上当样本会让这一臂在【一段链】上通过,而两段正是"血缘要递归"的全部理由。
--
-- 【本 fixture 钉住的四件事】
--   A 链条逐行与 batch_lineage 一致,而且【深度到 2】—— 报告不做第二次递归;
--   B 出处三列【逐值】原样带走(不是"有这个键就算过"):input_source /
--     output_source / recovery_blocked_by;
--   C 算不出的回收率带着它的【具名原因】走,绝不用数字替代;
--   D 三条拒绝各自【只欠自己那一个前提】—— 一条拒绝如果同时欠着两件事,
--     它证明不了自己是被哪一件挡住的。
--
-- 【前提全部自建】自己的物料、供应商、批次、加工单与台账行。库存恒等式由
-- DEFERRABLE 约束触发器强制(remaining_qty = Σ qty_delta),所以每个批次都自带
-- 配套的 inventory_movements 行。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    v_sales uuid := gen_random_uuid();   -- 只有 module.sales.view
    v_hr    uuid := gen_random_uuid();   -- 两个模块都没有
    r_all uuid; r_sales uuid; r_hr uuid;
    v_mat uuid; v_sup uuid;
    ib uuid;                 -- 进料批(链条起点)
    asy_in uuid; asy_out uuid;   -- 出处指向的化验单(content_source='assay' 要求它非空)
    ob1 uuid; ob2 uuid;      -- 第一段产出、第二段产出
    run1 uuid; run2 uuid;
    v_rep jsonb; rec record; el jsonb;
    v_denied boolean; v_msg text;
    q_in  numeric := 100;    -- 进料批数量
    q_c1  numeric := 60;     -- run1 消耗
    q_o1  numeric := 40;     -- run1 产出 → ob1
    q_c2  numeric := 30;     -- run2 消耗 ob1
    q_o2  numeric := 20;     -- run2 产出 → ob2
    n_chain int; n_rec int;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-83-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-83-sales', 'f', 'f', true) RETURNING id INTO r_sales;
    -- 【只有 sales.view】—— 这一臂要证明 OR 那一支【真的成立】:
    -- 一个 AND 的实现会在这里给出零行,而那正是本刀不选 AND 的理由。
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_sales, 'module.sales.view');
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-83-none', 'f', 'f', true) RETURNING id INTO r_hr;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_hr, 'module.hr.view');
    INSERT INTO user_roles (user_id, role_id)
    VALUES (v_user, r_all), (v_sales, r_sales), (v_hr, r_hr);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FX83-SUP', 'fixture 83 supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('FX83-M', 'fixture 83 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;

    -- ── 进料批:只测过 cu(li 从来没测过 —— C 臂靠它)───────────────────────
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty, arrival_date)
    VALUES ('FX83-IN', v_mat, v_sup, q_in, 'kg', q_in - q_c1, '2026-05-01') RETURNING id INTO ib;
    INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date)
    VALUES (ib, 'receipt', q_in, '2026-05-01'), (ib, 'processing_consume', -q_c1, '2026-05-01');
    -- 【出处逐值断言的对象之一】投入侧写 'assay'。
    -- content_source='assay' 由 CHECK 强制 source_assay_id 非空 —— 出处是【记录】的,
    -- 指不出那份单据就不能自称实验室结论(PROC-1)。所以这里真的建一份。
    INSERT INTO assay_results (code, inbound_batch_id, assay_date, applied_at, weight_basis, result_party)
    VALUES ('FX83-ASY-IN', ib, '2026-05-01', now(), 'as_received', 'ours') RETURNING id INTO asy_in;
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct) VALUES (asy_in, 'cu', 20);
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source, source_assay_id)
    VALUES (ib, 'cu', 20, 'assay', asy_in);

    -- ── 第一段:run1 耗进料批 → ob1 ─────────────────────────────────────────
    INSERT INTO processing_runs (code, status, process_date, allocation_basis)
    VALUES ('FX83-RUN1', 'committed', '2026-05-02', 'weight') RETURNING id INTO run1;
    INSERT INTO output_batches (code, material_id, quantity, unit, remaining_qty, output_date)
    VALUES ('FX83-OUT1', v_mat, q_o1, 'kg', q_o1 - q_c2, '2026-05-02') RETURNING id INTO ob1;
    INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date)
    VALUES (ob1, 'processing_produce', q_o1, '2026-05-02'),
           (ob1, 'processing_consume', -q_c2, '2026-05-03');
    -- PROC-3:这一支要投料,所以它的电池料批次得带一条【可投料】的安全状态。
    -- 【为什么是一条带 JOIN 的 SELECT,而不是逐个批次写死】本支里哪些批次【吃】
    -- 状态轴,由 material_kinds 回答 —— 实测 ewaste 可加工却【没有】状态轴,
    -- 所以"可加工"并不蕴含"有状态轴"。而没有状态轴的批次插安全状态会被
    -- PROC-2c 的适用性守卫按名拒,所以这个过滤不是优化,是正确性。
    -- 【它出现在每一次投料之前,而不是只在开头一次】批次是各臂【边跑边造】的,
    -- 开头那一次覆盖不到后面才出生的批次。NOT EXISTS 让它重复执行也不撞主键。
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT ib.id, 'discharged_verified'
      FROM inbound_batches ib
      JOIN materials m       ON m.id   = ib.material_id
      JOIN material_kinds mk ON mk.code = m.kind_code
     WHERE mk.has_condition_axes
       AND NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states s
                        WHERE s.inbound_batch_id = ib.id);
    INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed)
    VALUES (run1, ib, q_c1);
    INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced)
    VALUES (run1, ob1, q_o1);
    -- 产出侧写 'manual' —— 于是 input_source='assay' / output_source='manual',
    -- 两个值【不同】,B 臂才分得出"带走"与"碰巧都一样"。
    INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source)
    VALUES (ob1, 'cu', 25, 'manual');

    -- ── 第二段:run2 耗 ob1 → ob2(这就是那第二段)──────────────────────────
    INSERT INTO processing_runs (code, status, process_date, allocation_basis)
    VALUES ('FX83-RUN2', 'committed', '2026-05-03', 'weight') RETURNING id INTO run2;
    INSERT INTO output_batches (code, material_id, quantity, unit, remaining_qty, output_date)
    VALUES ('FX83-OUT2', v_mat, q_o2, 'kg', q_o2, '2026-05-03') RETURNING id INTO ob2;
    INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date)
    VALUES (ob2, 'processing_produce', q_o2, '2026-05-03');
    -- PROC-3:同上 —— 这一臂之前又造了新批次,补上可投料的安全状态。
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT ib.id, 'discharged_verified'
      FROM inbound_batches ib
      JOIN materials m       ON m.id   = ib.material_id
      JOIN material_kinds mk ON mk.code = m.kind_code
     WHERE mk.has_condition_axes
       AND NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states s
                        WHERE s.inbound_batch_id = ib.id);
    INSERT INTO processing_inputs (run_id, output_batch_id, quantity_consumed)
    VALUES (run2, ob1, q_c2);
    INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced)
    VALUES (run2, ob2, q_o2);
    -- 【ob2 只测 li,而投入(ob1)只测过 cu】—— 于是 run2 有两行金属:
    --   cu:投入测了、产出没测  → recovery_blocked_by = 'output_not_measured'
    --   li:投入没测、产出测了  → recovery_blocked_by = 'input_not_measured'
    -- C 臂钉的就是这两个具名原因。
    INSERT INTO assay_results (code, output_batch_id, assay_date, applied_at, weight_basis, result_party)
    VALUES ('FX83-ASY-OUT', ob2, '2026-05-03', now(), 'as_received', 'ours') RETURNING id INTO asy_out;
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct) VALUES (asy_out, 'li', 5);
    INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source, source_assay_id)
    VALUES (ob2, 'li', 5, 'assay', asy_out);

    v_rep := traceability_report_data(ob2);

    -- ══════════ A. 链条逐行与 batch_lineage 一致,而且深度到 2 ════════════════
    IF (v_rep->>'chain_depth')::int <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 83A 失败:链条深度应为 2(进料→第一段→第二段),实得 % —— 深度 1 说明递归那一步没走,而递归正是血缘存在的理由',
            v_rep->>'chain_depth';
    END IF;
    -- 【与 batch_lineage 逐行比,不是"看起来差不多"】报告不做第二次递归,
    -- 所以这两个集合必须【逐字】相等;不等就说明有人在报告里另写了一份。
    SELECT count(*) INTO n_chain FROM batch_lineage l WHERE l.output_batch_id = ob2;
    IF (v_rep->>'chain_row_count')::int <> n_chain THEN
        RAISE EXCEPTION 'FIXTURE 83A 失败:报告 % 行,batch_lineage % 行 —— 报告在自己重算血缘',
            v_rep->>'chain_row_count', n_chain;
    END IF;
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_rep->'chain') c
        WHERE NOT EXISTS (
            SELECT 1 FROM batch_lineage l
             WHERE l.output_batch_id = ob2
               AND l.depth = (c->>'depth')::int
               AND l.via_run_code = c->>'via_run_code'
               AND l.parent_kind = c->>'parent_kind'
               AND l.parent_code = c->>'parent_code'
               AND l.quantity_consumed = (c->>'quantity_consumed')::numeric))
    THEN
        RAISE EXCEPTION 'FIXTURE 83A 失败:报告里有 batch_lineage 里没有的链条行';
    END IF;
    -- 链条末端必须带出【供应商与到货日】—— 那是"从哪来"的答案,
    -- 而它是 join 出来的,不是第二次递归。
    SELECT c INTO el FROM jsonb_array_elements(v_rep->'chain') c
     WHERE c->>'parent_kind' = 'inbound' LIMIT 1;
    IF el IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 83A 失败:链条里没有任何进料父 —— 那条链没有走到供应商';
    END IF;
    IF el->>'supplier_name' <> 'fixture 83 supplier' OR el->>'arrival_date' <> '2026-05-01' THEN
        RAISE EXCEPTION 'FIXTURE 83A 失败:进料父应带出供应商与到货日,实得 %', el;
    END IF;

    -- ══════════ B. 出处三列【逐值】原样带走 ═══════════════════════════════════
    -- 【断言的是值,不是"这个键存在"】—— 一个把 input_source 恒填 'assay' 的实现,
    -- 只检查存在性的断言照样通过。这里 run1 的两侧【故意不同】(assay vs manual)。
    SELECT r INTO el FROM jsonb_array_elements(v_rep->'recovery') r
     WHERE r->>'run_code' = 'FX83-RUN1' AND r->>'metal' = 'cu';
    IF el IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 83B 失败:报告里没有 FX83-RUN1 × cu 这一行';
    END IF;
    IF el->>'input_source' <> 'assay' OR el->>'output_source' <> 'manual' THEN
        RAISE EXCEPTION 'FIXTURE 83B 失败:出处应为 input=assay / output=manual,实得 input=% output=% —— 报告在重算出处,而不是带走它',
            el->>'input_source', el->>'output_source';
    END IF;
    -- 【第二个 input_source,取值【不同】—— 这一条是被故障注入逼出来的】
    -- 上面那一行的真值恰好就是 'assay',所以一个把 input_source 硬编成 'assay' 的
    -- 实现【照样通过】(实测:注入之后本臂全绿)。RUN2 的投入是 ob1,它的含量是
    -- 手敲的,所以那一行的 input_source 必须是 'manual' —— 两行取值不同,
    -- 硬编任何一个都会被抓住。
    SELECT r INTO el FROM jsonb_array_elements(v_rep->'recovery') r
     WHERE r->>'run_code' = 'FX83-RUN2' AND r->>'metal' = 'cu';
    IF el->>'input_source' <> 'manual' THEN
        RAISE EXCEPTION 'FIXTURE 83B 失败:RUN2×cu 的投入来自手敲含量的 ob1,input_source 应为 manual,实得 % —— 出处被硬编了,不是带走的',
            el->>'input_source';
    END IF;
    SELECT r INTO el FROM jsonb_array_elements(v_rep->'recovery') r
     WHERE r->>'run_code' = 'FX83-RUN1' AND r->>'metal' = 'cu';

    -- 与那张视图【逐值】对齐(报告携带,视图裁定)
    SELECT * INTO rec FROM processing_metal_recovery v
     WHERE v.run_id = run1 AND v.metal = 'cu';
    IF (el->>'recovery_pct')::numeric IS DISTINCT FROM rec.recovery_pct
       OR (el->>'input_metal_kg')::numeric IS DISTINCT FROM rec.input_metal_kg
       OR (el->>'output_metal_kg')::numeric IS DISTINCT FROM rec.output_metal_kg
       OR (el->>'conservation_warning')::boolean IS DISTINCT FROM rec.conservation_warning THEN
        RAISE EXCEPTION 'FIXTURE 83B 失败:报告与 processing_metal_recovery 对不上 —— 报告 %,视图 recovery_pct=% in=% out=% warn=%',
            el, rec.recovery_pct, rec.input_metal_kg, rec.output_metal_kg, rec.conservation_warning;
    END IF;

    -- ══════════ C. 算不出的回收率带着【具名原因】走,绝不用数字替代 ═══════════
    SELECT r INTO el FROM jsonb_array_elements(v_rep->'recovery') r
     WHERE r->>'run_code' = 'FX83-RUN2' AND r->>'metal' = 'cu';
    IF el IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 83C 失败:报告里没有 FX83-RUN2 × cu 这一行 —— 算不出的金属被整行丢掉了,而"算不出"本身就是要报的内容';
    END IF;
    IF el->>'recovery_pct' IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 83C 失败:产出侧没测过 cu,回收率必须是 NULL,实得 % —— 一个凭空出现的数字比空白坏得多',
            el->>'recovery_pct';
    END IF;
    IF el->>'recovery_blocked_by' <> 'output_not_measured' THEN
        RAISE EXCEPTION 'FIXTURE 83C 失败:cu 的原因应为 output_not_measured,实得 %', el->>'recovery_blocked_by';
    END IF;
    SELECT r INTO el FROM jsonb_array_elements(v_rep->'recovery') r
     WHERE r->>'run_code' = 'FX83-RUN2' AND r->>'metal' = 'li';
    IF el IS NULL OR el->>'recovery_blocked_by' <> 'input_not_measured' THEN
        RAISE EXCEPTION 'FIXTURE 83C 失败:li 的原因应为 input_not_measured,实得 %', el;
    END IF;
    -- 两个原因【必须不同】,否则一个恒返回同一个字符串的实现照样通过
    IF (SELECT count(DISTINCT r->>'recovery_blocked_by')
          FROM jsonb_array_elements(v_rep->'recovery') r
         WHERE r->>'run_code' = 'FX83-RUN2') < 2 THEN
        RAISE EXCEPTION 'FIXTURE 83C 失败:RUN2 两种金属的原因应当不同(一个投入没测、一个产出没测)—— 相同说明原因是硬编出来的';
    END IF;

    -- ══════════ D. 三条拒绝,各自只欠自己那一个前提 ═══════════════════════════
    -- 【只欠一个】是这一臂的全部要求:一条同时欠着两件事的拒绝,证明不了自己
    -- 是被哪一件挡住的(fixture 40 那条"预览拒在提交拒的地方"同一条纪律)。
    v_denied := false;
    BEGIN PERFORM traceability_report_data(gen_random_uuid());
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'BATCH_NOT_FOUND%' THEN
        RAISE EXCEPTION 'FIXTURE 83D 失败:不存在的 id 应报 BATCH_NOT_FOUND,实得 %', COALESCE(v_msg, '(通过了)');
    END IF;

    -- 拿【进料批】的 id 来要报告 —— 它存在、有血缘价值、只差"不是产出批"这一件。
    v_denied := false;
    BEGIN PERFORM traceability_report_data(ib);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'NOT_AN_OUTPUT_BATCH%' THEN
        RAISE EXCEPTION 'FIXTURE 83D 失败:进料批 id 应报 NOT_AN_OUTPUT_BATCH,实得 % —— 报成 BATCH_NOT_FOUND 会让人以为自己打错了号',
            COALESCE(v_msg, '(通过了)');
    END IF;

    -- 一个【真的产出批】,只差"没有任何血缘"这一件(它的生产单被软删)。
    -- 【线上的真实同类是 OUT-2026-0001 / OUT-2026-0002:在册、零支生产单】——
    -- 而那四个 reversed+软删的批次(0005/0006/0159/0160)撞的是 BATCH_NOT_FOUND,
    -- 因为它们【自己】也是软删的。两件事分得开,值得分开测。
    -- AUDEL-1b:这里不是在测软删,是在【造一个没有血缘的批次】。软删要走门,
    -- 而 processing_runs 没有门(它只被 rollback_processing_run 软删)——
    -- 所以自己设标记并填两列,与将来那扇门做同一件事。
    PERFORM set_config('evoltrya.soft_delete_ctx', '1', true);
    UPDATE processing_runs SET deleted_at = now(), deleted_by = v_user,
           delete_reason = 'fixture:造一个无血缘的批次' WHERE id = run2;
    PERFORM set_config('evoltrya.soft_delete_ctx', '', true);
    v_denied := false;
    BEGIN PERFORM traceability_report_data(ob2);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'NOTHING_TO_REPORT%' THEN
        RAISE EXCEPTION 'FIXTURE 83D 失败:没有血缘的产出批应报 NOTHING_TO_REPORT,实得 % —— 发一份"来源不详"的报告去糊弄审计,比不发坏得多',
            COALESCE(v_msg, '(通过了)');
    END IF;
    UPDATE processing_runs SET deleted_at = NULL WHERE id = run2;   -- 还原,后面还要用

    -- ══════════ E. 权限:OR 的两侧【各自】够用,两侧都没有才拒 ════════════════
    -- 【这一臂是本刀不选 AND 的证据】只持 module.sales.view 的读者必须读得到 ——
    -- 线上的 sales 角色正是这个形状(processing.view = false),而客户是向他要
    -- 这份东西的。一个 AND 的实现会在这里报 PERMISSION_DENIED。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_sales), true);
    v_rep := traceability_report_data(ob2);
    IF (v_rep->>'chain_row_count')::int <> n_chain THEN
        RAISE EXCEPTION 'FIXTURE 83E 失败:只持 sales.view 的读者拿到 % 行链条,应为 % —— 判据还留在内层视图里,属主权限替不了它',
            v_rep->>'chain_row_count', n_chain;
    END IF;
    SELECT count(*) INTO n_rec FROM jsonb_array_elements(v_rep->'recovery');
    IF n_rec = 0 THEN
        RAISE EXCEPTION 'FIXTURE 83E 失败:只持 sales.view 的读者拿到零行回收 —— 同上,那是"行静默消失"而不是拒绝';
    END IF;

    -- 两个模块都没有 → 按名拒
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_hr), true);
    v_denied := false;
    BEGIN PERFORM traceability_report_data(ob2);
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 83E 失败:两个模块都没有的主体读到了报告';
    END IF;

    -- ══════════ F. 单据机器:号、版本、不可改 ═════════════════════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    v_rep := record_traceability_report_issue(ob2, 'p/1.pdf', repeat('a', 64));
    IF v_rep->>'code' NOT LIKE 'TRC-%' OR (v_rep->>'version')::int <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 83F 失败:第一版应是 TRC-… v1,实得 %', v_rep;
    END IF;
    v_msg := v_rep->>'code';
    -- 【重发沿用同一个号】客户引用的是那个号,重发一版不该让他手里的引用失效。
    v_rep := record_traceability_report_issue(ob2, 'p/2.pdf', repeat('b', 64));
    IF v_rep->>'code' <> v_msg OR (v_rep->>'version')::int <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 83F 失败:第二版应沿用 % 并成为 v2,实得 %', v_msg, v_rep;
    END IF;
    -- 【签发档不可改】
    v_denied := false;
    BEGIN UPDATE traceability_report_issues SET sha256 = repeat('c', 64) WHERE output_batch_id = ob2;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'TRACEABILITY_REPORT_ISSUE_IMMUTABLE%' THEN
        RAISE EXCEPTION 'FIXTURE 83F 失败:改签发档应被具名拒,实得 %', COALESCE(v_msg, '(改成功了)');
    END IF;
    -- 【记档案那条路也要拒得住 NOTHING_TO_REPORT,而且它不自己重判】
    -- AUDEL-1b:这里不是在测软删,是在【造一个没有血缘的批次】。软删要走门,
    -- 而 processing_runs 没有门(它只被 rollback_processing_run 软删)——
    -- 所以自己设标记并填两列,与将来那扇门做同一件事。
    PERFORM set_config('evoltrya.soft_delete_ctx', '1', true);
    UPDATE processing_runs SET deleted_at = now(), deleted_by = v_user,
           delete_reason = 'fixture:造一个无血缘的批次' WHERE id = run2;
    PERFORM set_config('evoltrya.soft_delete_ctx', '', true);
    v_denied := false;
    BEGIN PERFORM record_traceability_report_issue(ob2, 'p/3.pdf', repeat('d', 64));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'NOTHING_TO_REPORT%' THEN
        RAISE EXCEPTION 'FIXTURE 83F 失败:没有可报内容时记档案应报 NOTHING_TO_REPORT,实得 %',
            COALESCE(v_msg, '(通过了)');
    END IF;
END $$;
ROLLBACK;
