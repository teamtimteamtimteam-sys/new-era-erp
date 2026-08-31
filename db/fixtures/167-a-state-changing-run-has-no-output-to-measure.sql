-- 167 状态改变型工序【没有产出可测】—— 那是"不适用",不是"没测" · PROC-WIRE-1B-ii
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【它钉的那个区别,以及为什么现在钉】
-- recovery_blocked_by 此前对状态改变型工序说 'output_not_measured' ——
-- **今天它还不是假话**(两者都导向"回收率算不出来"),但它【不精确】:
--   · output_not_measured   → 下一步是【去把产出化验录进来】;
--   · output_not_applicable → 下一步是【什么都不用做,这道工序根本不产出】。
-- ★ 产出测量真正要紧的那一天,这两句话会分道 —— 而那时说错的那一句会
--   教人去补一份**根本不存在**的化验。
-- **趁它还只是不精确的时候修,比等它变成假话之后再修便宜。**
--
-- 【每一臂钉什么】
-- N1 ★ 状态改变型 + 没有产出腿 → output_not_applicable。
-- N2 对照:转化型、产出确实没测 → 仍然 output_not_measured(一个字没松)。
--    **没有这一臂,一个把所有缺席都叫"不适用"的实现会全绿** —— 而那会把
--    "该去录化验"这句话吃掉。
-- N3 ★ 没有工序类型的单 → 仍然 output_not_measured。
--    **说不出"不适用"的时候不许猜它。** 线上 13 张单没有工序类型。
-- N4 两个取值确实不同(它们没有被并成一句)。
--
-- 日期:自带。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_ccy text; v_sup uuid; v_mat uuid;
    v_ib uuid; v_ib2 uuid; v_ib3 uuid;
    v_run_sc uuid; v_run_tr uuid; v_run_no uuid;
    v_d date := DATE '2027-10-14';
    v_sc text; v_tr text; v_no text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-167', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ167-S', 'f', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
    VALUES ('ZZ167-M', 'f163 pack', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction')
    RETURNING id INTO v_mat;

    -- ══════════ N1 · ★ 状态改变型 → 不适用 ══════════
    RAISE NOTICE 'fixture 167 · 进入 N1';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ167-A', v_mat, v_sup, 100, 100, 'kg', v_d - 1) RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, v_ccy, NULL, 'f');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib, 'charged_not_discharged');
    -- 【投入侧必须测过】否则这一行会停在 input_not_measured 上,本臂测不到东西。
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source)
    VALUES (v_ib, 'co', 10, 'manual');

    v_run_sc := commit_processing_run(v_d, 'f163 discharge', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 10)),
        '[]'::jsonb, 'weight', NULL, NULL, 'deep_discharge');

    -- 【先证明前提成立】这道工序确实【不产出】,而这一行确实是投入测过、产出没有。
    IF (SELECT k.produces_outputs FROM operation_types ot JOIN operation_kinds k ON k.code = ot.kind_code
         WHERE ot.code = 'deep_discharge') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 167N1 前置失败:深度放电必须是【不产出】的那一类 —— 本臂的整个意义就在这里';
    END IF;
    SELECT recovery_blocked_by INTO v_sc FROM processing_metal_recovery_all
     WHERE run_id = v_run_sc AND metal = 'co';
    IF v_sc IS DISTINCT FROM 'output_not_applicable' THEN
        RAISE EXCEPTION 'FIXTURE 167N1 失败:状态改变型工序【按定义】没有产出腿 —— 没有东西可测,不是"忘了测"。说它"产出没测过"会教人去补一份根本不存在的化验。应得 output_not_applicable,实得「%」', COALESCE(v_sc, '(空)');
    END IF;

    -- ══════════ N2 · 对照:转化型 + 产出真的没测 → 仍然 output_not_measured ══════════
    RAISE NOTICE 'fixture 167 · 进入 N2';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ167-B', v_mat, v_sup, 100, 100, 'kg', v_d - 1) RETURNING id INTO v_ib2;
    PERFORM reprice_inbound_batch(v_ib2, 1, v_ccy, NULL, 'f');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib2;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib2, 'discharged_verified');
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source)
    VALUES (v_ib2, 'co', 10, 'manual');
    v_run_tr := commit_processing_run(v_d, 'f163 disassembly', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib2, 'quantity_consumed', 10)),
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 9)), 'weight',
        NULL, NULL, 'manual_disassembly');
    SELECT recovery_blocked_by INTO v_tr FROM processing_metal_recovery_all
     WHERE run_id = v_run_tr AND metal = 'co';
    IF v_tr IS DISTINCT FROM 'output_not_measured' THEN
        RAISE EXCEPTION 'FIXTURE 167N2 失败:**一个把所有缺席都叫"不适用"的实现在这里红。** 会产出的工序,产出没测就是【没测】—— 下一步是去把化验录进来,那句话不许被吃掉。应得 output_not_measured,实得「%」', COALESCE(v_tr, '(空)');
    END IF;

    -- ══════════ N3 · ★ 没有工序类型 → 不许猜"不适用" ══════════
    RAISE NOTICE 'fixture 167 · 进入 N3';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ167-C', v_mat, v_sup, 100, 100, 'kg', v_d - 1) RETURNING id INTO v_ib3;
    PERFORM reprice_inbound_batch(v_ib3, 1, v_ccy, NULL, 'f');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib3;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib3, 'discharged_verified');
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source)
    VALUES (v_ib3, 'co', 10, 'manual');
    v_run_no := commit_processing_run(v_d, 'f163 no op', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib3, 'quantity_consumed', 10)),
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 9)), 'weight');
    IF (SELECT operation_type_code FROM processing_runs WHERE id = v_run_no) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 167N3 前置失败:这一臂要的是一张【没有工序类型】的单 —— 线上 13 张都是这样';
    END IF;
    SELECT recovery_blocked_by INTO v_no FROM processing_metal_recovery_all
     WHERE run_id = v_run_no AND metal = 'co';
    IF v_no IS DISTINCT FROM 'output_not_measured' THEN
        RAISE EXCEPTION 'FIXTURE 167N3 失败:**说不出"不适用"的时候不许猜它。** 一张没有工序类型的单,没有任何东西能说它不产出 —— 它的答案必须一个字不变。应得 output_not_measured,实得「%」', COALESCE(v_no, '(空)');
    END IF;

    -- ══════════ N4 · 两个取值确实没有被并成一句 ══════════
    RAISE NOTICE 'fixture 167 · 进入 N4';
    IF v_sc = v_tr THEN
        RAISE EXCEPTION 'FIXTURE 167N4 失败:"不适用"与"没测"是两句话、两种下一步动作,不许并成一句';
    END IF;
END $$;
ROLLBACK;
