-- 19 再加工:回收率两路投入、成本两路解除、上游差额逐级传导、无价传染、
--    冲销守卫、自吞守卫
--
-- 为什么值得常设(FIN-25):再加工让链条变长(进料→产出→产出),每一环都可能
-- 静默错 —— 回收率高报(投入金属丢了产出边)、成本解错科目(1200 vs 1220)、
-- 上游价差不传导、无价的零悄悄流两层。六臂:
--   A 【优先】二段回收率,手算断言:stage2 投入金属 32.5 kg(产出边 22.5 +
--     进料边 10),回收率 92.31%。旧内联 join 丢产出边 → 投入只剩 10 →
--     回收率 300% —— 高报,而这是评判工艺的数字。对旧视图故障注入必须红。
--   B 成本两路:stage2 资本化贷 1200(进料 100)+ 贷 1220(再加工 62.50)。
--   C 上游差额传导:stage1 加费 80 → 重跑(在库 30 → 1220,被耗 50 → 5000 停车)
--     → stage2 过期(第三支)→ 重跑收回停车 → 5000 净变 0。一条边一步,不递归。
--   D 无价上游:stage1' 未分摊,stage2' 照样提交、照样分摊(不拒 —— 车间不等
--     财务),cost_incomplete 打标;stage1' 补分摊后 stage2' 过期,重跑清标。
--   E 冲销守卫:stage1 的产出已被 stage2 消耗 → rollback stage1 点名拒。
--   F 自吞守卫:裸 INSERT 拒(两种边都拒 —— 也堵进料边的既有直插洞);
--     函数上下文内的同单自吞边也拒。
-- FIN-36:commit_processing_run 多了一个【必填】的分摊基准参数。
-- 这里一律显式传 'metal_value' —— 那正是本 fixture 在 FIN-36 之前从 schema
-- 默认值拿到的值,所以语义一字未变,只是不再有人替它做这个选择。
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid(); v_role uuid;
    v_sup uuid; v_cust uuid; v_mat uuid; v_matB uuid; v_matC uuid;
    v_ib1 uuid; v_ib2 uuid; v_run1 uuid; v_run2 uuid; v_o1 uuid; v_o2 uuid;
    v_n numeric; v_n2 numeric; v_stale boolean; v_flag boolean;
    v_msg text; v_ok boolean; v_today date := CURRENT_DATE;
    v_b5000 numeric;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-19', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO suppliers (code, legal_name, country) VALUES ('FIXT-S19', 'Fixture Supplier 19', 'SG')
        RETURNING id INTO v_sup;
    INSERT INTO customers (code, legal_name, country) VALUES ('FIXT-C19', 'Fixture Customer 19', 'SG')
        RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, category) VALUES ('FIXT-M19', 'Fixture Raw 19', 'black_mass')
        RETURNING id INTO v_mat;
    INSERT INTO materials (code, name, category) VALUES ('FIXT-M19B', 'Fixture Mid 19', 'black_mass')
        RETURNING id INTO v_matB;
    INSERT INTO materials (code, name, category) VALUES ('FIXT-M19C', 'Fixture Fine 19', 'black_mass')
        RETURNING id INTO v_matC;

    -- ── stage1:进料 100kg @1(40% 镍 = 40kg),产出 O1 80kg(45% = 36kg)──────
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('FIXT-IB19A', v_mat, v_sup, 100, 100, 'kg', v_today) RETURNING id INTO v_ib1;
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct) VALUES (v_ib1, 'ni', 40);
    PERFORM reprice_inbound_batch(v_ib1, 1, 'SGD', NULL, 'fixture 19 stage1 price');
    v_run1 := commit_processing_run(v_today, 'fixture 19 stage1', 20,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib1, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 80)), 'metal_value');
    SELECT po.output_batch_id INTO v_o1 FROM processing_outputs po WHERE po.run_id = v_run1;
    INSERT INTO output_batch_metals (output_batch_id, metal, content_pct) VALUES (v_o1, 'ni', 45);
    PERFORM allocate_processing_costs(v_run1, 'weight');   -- O1: 100 → unit 1.25

    -- ── stage2:耗 O1 50kg【产出边】+ 进料2 50kg @2(20% = 10kg)【进料边】,
    --    产出 O2 60kg(50% = 30kg)────────────────────────────────────────────
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('FIXT-IB19B', v_mat, v_sup, 50, 50, 'kg', v_today) RETURNING id INTO v_ib2;
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct) VALUES (v_ib2, 'ni', 20);
    PERFORM reprice_inbound_batch(v_ib2, 2, 'SGD', NULL, 'fixture 19 stage2 price');
    v_run2 := commit_processing_run(v_today, 'fixture 19 stage2', 40,
        jsonb_build_array(
            jsonb_build_object('output_batch_id', v_o1, 'quantity_consumed', 50),
            jsonb_build_object('inbound_batch_id', v_ib2, 'quantity_consumed', 50)),
        jsonb_build_array(jsonb_build_object('material_id', v_matC, 'quantity', 60)), 'metal_value');
    SELECT po.output_batch_id INTO v_o2 FROM processing_outputs po WHERE po.run_id = v_run2;
    INSERT INTO output_batch_metals (output_batch_id, metal, content_pct) VALUES (v_o2, 'ni', 50);

    -- ════════ A. 回收率:投入 = 50×45% + 50×20% = 22.5 + 10 = 32.5 kg;
    --             产出 = 60×50% = 30 kg → 30/32.5 = 92.31% ═════════════════════
    SELECT input_metal_kg, recovery_pct INTO v_n, v_n2
    FROM processing_metal_recovery WHERE run_id = v_run2 AND metal = 'ni';
    IF v_n <> 32.5 THEN
        RAISE EXCEPTION 'FIXTURE 19A 失败:stage2 投入镍应 32.5 kg(产出边 22.5 + 进料边 10),实得 %(=10 → 旧内联 join 把产出边丢了)', v_n;
    END IF;
    IF v_n2 <> 92.31 THEN
        RAISE EXCEPTION 'FIXTURE 19A 失败:回收率应 92.31%%(30/32.5),实得 %(=300 → 投入被低报,回收率被高报)', v_n2;
    END IF;

    -- ════════ B. 成本两路:stage2 资本化贷 1200=100(进料)、贷 1220=62.50(再加工)══
    PERFORM allocate_processing_costs(v_run2, 'weight');
    SELECT round(COALESCE(SUM(CASE WHEN a.code='1200' THEN jl.credit END), 0), 2),
           round(COALESCE(SUM(CASE WHEN a.code='1220' THEN jl.credit END), 0), 2)
      INTO v_n, v_n2
    FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
    WHERE jl.entry_id = (SELECT capitalization_entry_id FROM processing_runs WHERE id = v_run2);
    IF v_n <> 100.00 OR v_n2 <> 62.50 THEN
        RAISE EXCEPTION 'FIXTURE 19B 失败:stage2 资本化应贷 1200=100.00(进料)、1220=62.50(再加工解除上游),实得 1200=% 1220=%', v_n, v_n2;
    END IF;

    -- ════════ C. 上游差额传导:stage1 +80 → 重跑 → stage2 过期 → 重跑收回停车 ══
    SELECT round(COALESCE(SUM(jl.debit) - SUM(jl.credit), 0), 2) INTO v_b5000
    FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id WHERE a.code = '5000';
    UPDATE processing_runs SET allocated_at = allocated_at - interval '2 second' WHERE id = v_run1;
    UPDATE processing_runs SET allocated_at = allocated_at - interval '1 second' WHERE id = v_run2;
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, created_by)
    VALUES (v_run1, 'labour', 80, false, v_uid);
    PERFORM allocate_processing_costs(v_run1, 'weight');
    -- O1 差额 80:在库 30/80 → 1220 30;被 stage2 耗 50/80 → 5000 停车 50
    SELECT is_stale INTO v_stale FROM processing_run_allocation_status WHERE run_id = v_run2;
    IF NOT COALESCE(v_stale, false) THEN
        RAISE EXCEPTION 'FIXTURE 19C 失败:上游重分摊后 stage2 应过期(状态视图第三支),实为 %', v_stale;
    END IF;
    PERFORM allocate_processing_costs(v_run2, 'weight');
    -- stage2 材料差额 = 50kg × (2.25 − 1.25) = 50 → 贷 5000 收回停车;O2 未售 → 全进 1220
    SELECT round(COALESCE(SUM(jl.debit) - SUM(jl.credit), 0), 2) - v_b5000 INTO v_n
    FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id WHERE a.code = '5000';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 19C 失败:传导完成后 5000 净变动应为 0(停车 50 被下游收回),实得 %', v_n;
    END IF;

    -- ════════ D. 无价上游:允许、打标、传染、补齐后清 ═══════════════════════
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('FIXT-IB19D', v_mat, v_sup, 30, 30, 'kg', v_today) RETURNING id INTO v_ib1;
    -- 不计价、不分摊 stage1' —— 直接投进 stage2'
    v_run1 := commit_processing_run(v_today, 'fixture 19 stage1-unpriced', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib1, 'quantity_consumed', 30)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 30)), 'metal_value');
    SELECT po.output_batch_id INTO v_o1 FROM processing_outputs po WHERE po.run_id = v_run1;
    v_run2 := commit_processing_run(v_today, 'fixture 19 stage2-unpriced', 0,
        jsonb_build_array(jsonb_build_object('output_batch_id', v_o1, 'quantity_consumed', 30)),
        jsonb_build_array(jsonb_build_object('material_id', v_matC, 'quantity', 30)), 'metal_value');
    PERFORM allocate_processing_costs(v_run2, 'weight');   -- 上游 unit_cost NULL → 计 0,不拒
    SELECT bool_or(cost_incomplete) INTO v_flag FROM processing_outputs WHERE run_id = v_run2;
    IF NOT COALESCE(v_flag, false) THEN
        RAISE EXCEPTION 'FIXTURE 19D 失败:无价上游被计 0 而产出没打 cost_incomplete —— 零静默了';
    END IF;
    -- 补齐:stage1' 计价 + 分摊 → stage2' 过期 → 重跑 → 标记清除
    PERFORM reprice_inbound_batch(v_ib1, 1, 'SGD', NULL, 'fixture 19 late price');
    UPDATE processing_runs SET allocated_at = allocated_at - interval '1 second' WHERE id = v_run2;
    PERFORM allocate_processing_costs(v_run1, 'weight');
    SELECT is_stale INTO v_stale FROM processing_run_allocation_status WHERE run_id = v_run2;
    IF NOT COALESCE(v_stale, false) THEN
        RAISE EXCEPTION 'FIXTURE 19D 失败:上游补分摊后 stage2 应过期,实为 %', v_stale;
    END IF;
    PERFORM allocate_processing_costs(v_run2, 'weight');
    SELECT bool_or(cost_incomplete) INTO v_flag FROM processing_outputs WHERE run_id = v_run2;
    IF COALESCE(v_flag, true) THEN
        RAISE EXCEPTION 'FIXTURE 19D 失败:上游补齐重跑后标记应清除,实为 %', v_flag;
    END IF;

    -- ════════ E. 冲销守卫:上游产出被下游耗过 → rollback 点名拒 ═══════════════
    v_ok := false; v_msg := NULL;
    BEGIN
        PERFORM rollback_processing_run(v_run1);
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'OUTPUT_CONSUMED%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 19E 失败:冲销已被下游消耗的 stage1 应 OUTPUT_CONSUMED 拒,实得:%', COALESCE(v_msg, '(没有报错)');
    END IF;

    -- ════════ F. 自吞守卫:裸 INSERT 拒;函数上下文内同单自吞边也拒 ═══════════
    v_ok := false; v_msg := NULL;
    BEGIN
        INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed)
        VALUES (v_run2, v_ib1, 1);
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'PROCESSING_INPUT_DIRECT_INSERT%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 19F 失败:裸 INSERT 投入腿应被拒(进料边的直插洞也要堵),实得:%', COALESCE(v_msg, '(没有报错 —— 直插洞还开着)');
    END IF;
    v_ok := false; v_msg := NULL;
    BEGIN
        PERFORM set_config('evoltrya.movement_ctx', 'processing:' || v_run2::text, true);
        INSERT INTO processing_inputs (run_id, output_batch_id, quantity_consumed)
        SELECT v_run2, po.output_batch_id, 1 FROM processing_outputs po WHERE po.run_id = v_run2;
        PERFORM set_config('evoltrya.movement_ctx', '', true);
    EXCEPTION WHEN OTHERS THEN
        PERFORM set_config('evoltrya.movement_ctx', '', true);
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'PROCESSING_INPUT_SELF_CONSUME%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 19F 失败:同单自吞边应 PROCESSING_INPUT_SELF_CONSUME 拒,实得:%', COALESCE(v_msg, '(没有报错)');
    END IF;
END $$;
ROLLBACK;
