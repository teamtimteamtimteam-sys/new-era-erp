-- 159 那道【起火】闸:声明一道工序只许把它【收紧】,不许默认放宽
--     PROC-WIRE-1B-i
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- 【它钉的是 Tim 的那条硬要求】受理是一张【逐工序的、明写的清单】,
-- **绝不是"状态改变型工序一律放行"那种按 kind 的旁路**。
-- 一个按 kind 放行的实现会让一块鼓包漏液的电池进放电机,而放电机解决不了它 ——
-- 这是全系统唯一一道失败后果是【起火】而不是【数字算错】的闸。
--
-- 【每一臂钉什么】
-- F1 ★ 不变式的一半:**没有工序类型 → may_be_fed 仍然是答案**(行为不变)。
-- F2 ★ 不变式的另一半:**有工序类型 → 没写进清单的一律拒,哪怕 may_be_fed = true**。
--   这一臂用一个【可投料】的状态去撞一道【没有把它列进清单】的工序。
--   一个"设了工序就放行"的实现在这里红,而它正是本 fixture 最要防的那种实现。
-- F3 ★ **深度放电不受理损坏状态。** 按 kind 放行的实现在这里红。
-- F4 转化型 + 零产出 → 仍然 NO_OUTPUTS(一个字没松)。
-- F5 状态改变型 + 带产出 → 另一条拒绝(只放松一侧会让"放电还产出黑粉"悄悄成立)。
-- F6 状态改变型 + 非零损耗 → 拒(它不带走质量)。
-- F7 状态改变型的分摊 → 按名拒,而【不是】静默地什么都不分摊。
-- F8 受理清单读的是【那张表】,不是写死的码 —— 加一行,拒绝就消失。
--
-- 日期:自带。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_ccy text; v_sup uuid; v_mat uuid;
    v_ib uuid; v_ib2 uuid; v_ib3 uuid; v_run uuid;
    v_d date := DATE '2027-09-06';
    v_msg text; v_denied boolean;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-159', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ159-S', 'f', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
    VALUES ('ZZ159-M', 'f159 pack', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction')
    RETURNING id INTO v_mat;

    -- ══════════ F1 · 没有工序类型 → 今天的行为 ══════════
    RAISE NOTICE 'fixture 159 · 进入 F1';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ159-A', v_mat, v_sup, 100, 100, 'kg', v_d - 1) RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, v_ccy, NULL, 'f');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib, 'charged_not_discharged');
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f159 none', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 10)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 10)), 'weight');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'INPUT_SAFETY_STATE_NOT_FEEDABLE|%' THEN
        RAISE EXCEPTION 'FIXTURE 159F1 失败:【没有工序类型 → may_be_fed 仍然是答案】。这是那条不变式的一半,也是"本刀没有动今天的行为"的证据。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ F2 · ★ 有工序类型 → 没写进清单的一律拒 ★ ══════════
    -- 用一个【可投料】的状态,去撞一道【没把它列进清单】的工序。
    RAISE NOTICE 'fixture 159 · 进入 F2';
    -- 前提:water_exposed 没有被【人工拆解】列进清单
    IF EXISTS (SELECT 1 FROM operation_type_safety_states
                WHERE operation_type_code = 'manual_disassembly' AND safety_state_code = 'water_exposed') THEN
        RAISE EXCEPTION 'FIXTURE 159F2 前置失败:本臂要的是一个【没有被这道工序列进清单】的状态';
    END IF;
    -- 而且它必须是【不可投料】以外的理由才有说服力 —— 这里换一个思路:
    -- 用 discharged_verified(may_be_fed = true)去撞一道【没有列它】的工序。
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ159-B', v_mat, v_sup, 100, 100, 'kg', v_d - 1) RETURNING id INTO v_ib2;
    PERFORM reprice_inbound_batch(v_ib2, 1, v_ccy, NULL, 'f');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib2;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib2, 'discharged_verified');
    -- 造一道【什么都不受理】的工序 —— 它是"声明只会收紧"最纯粹的证据
    INSERT INTO operation_types (code, name_en, name_zh, kind_code, sort_order, notes)
    VALUES ('zz159_narrow', 'f159 narrow', 'f159 收紧', 'transforming', 99, 'fixture 159 F2');
    INSERT INTO operation_type_input_forms (operation_type_code, form_code)
    VALUES ('zz159_narrow', 'whole_pack');
    IF (SELECT may_be_fed FROM inbound_safety_states WHERE code = 'discharged_verified') IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 159F2 前置失败:这一臂要的是一个【may_be_fed = true】的状态 —— 否则它证明不了"清单比 may_be_fed 更严"';
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f159 narrow', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib2, 'quantity_consumed', 10)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 10)), 'weight',
            NULL, NULL, 'zz159_narrow');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'INPUT_SAFETY_STATE_NOT_ACCEPTED|%' THEN
        RAISE EXCEPTION 'FIXTURE 159F2 失败:**声明一道工序只会把闸收紧。** 一个 may_be_fed = true 的状态,只要没被这道工序列进清单,就必须被拒。一个"设了工序就放行"的实现在这里绿 —— 而那正是本 fixture 最要防的那一种。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ F3 · ★ 深度放电不受理损坏状态 ★ ══════════
    RAISE NOTICE 'fixture 159 · 进入 F3';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ159-C', v_mat, v_sup, 100, 100, 'kg', v_d - 1) RETURNING id INTO v_ib3;
    PERFORM reprice_inbound_batch(v_ib3, 1, v_ccy, NULL, 'f');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib3;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib3, 'charged_not_discharged');
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib3, 'swollen_leaking');
    -- 【先证明注入确实改变了东西】深度放电确实【没有】把这个状态列进清单。
    IF EXISTS (SELECT 1 FROM operation_type_safety_states
                WHERE operation_type_code = 'deep_discharge' AND safety_state_code = 'swollen_leaking') THEN
        RAISE EXCEPTION 'FIXTURE 159F3 前置失败:深度放电【不许】受理鼓包漏液 —— 那是 Tim 的硬要求,而字典里竟然有这一行';
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f159 dmg', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib3, 'quantity_consumed', 10)),
            '[]'::jsonb, 'weight', NULL, NULL, 'deep_discharge');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'INPUT_SAFETY_STATE_NOT_ACCEPTED|%' THEN
        RAISE EXCEPTION 'FIXTURE 159F3 失败:**放电机解决不了鼓包漏液,所以深度放电不受理它。** 一个按 kind 放行(状态改变型一律放行)的实现在这里绿,而它会把一块漏液的电池送进放电机。这是全系统唯一一道失败后果是【起火】的闸。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ F4 · 转化型 + 零产出 → 仍然 NO_OUTPUTS ══════════
    RAISE NOTICE 'fixture 159 · 进入 F4';
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f159 noout', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib2, 'quantity_consumed', 10)),
            '[]'::jsonb, 'weight', NULL, NULL, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'NO_OUTPUTS%' THEN
        RAISE EXCEPTION 'FIXTURE 159F4 失败:**会产出的工序少了产出,照旧 NO_OUTPUTS —— 一个字没松。** 本刀放松的只有"不产出的那一类"。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ F5 · 状态改变型 + 带产出 → 另一条拒绝 ══════════
    RAISE NOTICE 'fixture 159 · 进入 F5';
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f159 scout', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib2, 'quantity_consumed', 10)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 10)), 'weight',
            NULL, NULL, 'deep_discharge');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'OPERATION_PRODUCES_NO_OUTPUTS|%' THEN
        RAISE EXCEPTION 'FIXTURE 159F5 失败:只放松一侧会让一张"放电还产出了黑粉"的单悄悄成立。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ F6 · 状态改变型 + 非零损耗 → 拒 ══════════
    RAISE NOTICE 'fixture 159 · 进入 F6';
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f159 scloss', 5,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib2, 'quantity_consumed', 10)),
            '[]'::jsonb, 'weight', NULL, NULL, 'deep_discharge');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'STATE_CHANGE_LOSS_NOT_ZERO|%' THEN
        RAISE EXCEPTION 'FIXTURE 159F6 失败:状态改变型不带走质量,损耗只能是 0。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ F7 · 分摊按名拒,而不是静默无操作 ══════════
    RAISE NOTICE 'fixture 159 · 进入 F7';
    v_run := commit_processing_run(v_d, 'f159 sc ok', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib2, 'quantity_consumed', 10)),
        '[]'::jsonb, 'weight', NULL, NULL, 'deep_discharge');
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM allocate_processing_costs(v_run, 'weight');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'ALLOCATION_STATE_CHANGING_UNRESOLVED|%' THEN
        RAISE EXCEPTION 'FIXTURE 159F7 失败:状态改变型没有产出腿,按【重量】基准分摊会得到"什么都没做、还返回成功" —— 那是一个假绿灯。它必须【按名拒绝】,把那个开着的会计问题说出来。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ F8 · 规则读的是【那张表】,不是写死的码 ══════════
    RAISE NOTICE 'fixture 159 · 进入 F8';
    -- 把鼓包漏液加进那道收紧工序的清单,拒绝必须消失 —— 证明判据读的是数据。
    INSERT INTO operation_type_safety_states (operation_type_code, safety_state_code, resolves)
    VALUES ('zz159_narrow', 'discharged_verified', false);
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f159 now ok', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib2, 'quantity_consumed', 10)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 10)), 'weight',
            NULL, NULL, 'zz159_narrow');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 159F8 失败:受理清单是【数据】—— 加一行,拒绝就该消失。一个把码写死的实现在这里红。实得「%」', v_msg;
    END IF;
END $$;
ROLLBACK;
