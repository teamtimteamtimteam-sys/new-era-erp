-- 165 自产的料要回答与买来的料【同一个】安全问题 —— PROC-WIRE-1B-ii(R1 / M4)
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【它钉的那处不对称】此前 guard_processing_input 里 PROC-3 那一段
-- **只问 inbound_batch_id** —— 于是买进来的极片要过火闸,而自己产的极片
-- 【连问都问不到】。原注释自己写着理由:不是"不需要问",是【问不了】,
-- 因为安全状态那时只有进料批有。
-- ★ Tim 的 R1:**抬高产出这一侧,绝不放低进料那一侧。**
--
-- ★★【本 fixture 最要紧的一臂是 K5:那处与进料侧【刻意的分歧】】★★
-- 进料侧那道闸包在 `IF FOUND AND v_axes IS TRUE` 里(物料种类说"我没有状态轴"
-- 就不问)。产出侧【不能】照抄,理由是一次线上测量:**20 批产出,它们的物料
-- kind_code 全是 NULL**,于是 has_condition_axes 全 NULL —— 照抄那一行,
-- 这道闸会对【零】批货生效,而一份证明它生效的 fixture 会**对着空气变绿**。
-- K5 就是那份 fixture 的解药:它用一个【明说没有状态轴】的种类,断言闸照样问
-- (kind_code 为空的物料在重建库里构造不出来 —— materials_kind_stated 拦着新行;
--  两者落进的是同一个否定分支,所以这是可构造的等价物,而且更强)。
--
-- 【每一臂钉什么】
-- K1 对照:一批【记了可投料状态】的自产料,**真的投得进去**。
--    少了它,一个"把所有人都拦住"的实现会全绿(README 第 1 条同源)。
-- K2 ★ 缺席即拒:一条安全状态都没有的自产料 → PRODUCED_SAFETY_STATE_NOT_RECORDED。
--    **"没有行"的意思是【没有人记过】,不是"它安全"** —— 与进料侧同一个意思。
-- K3 ★ 反方向:记了一个【不可投料】的状态 → PRODUCED_SAFETY_STATE_NOT_FEEDABLE。
--    K1 + K3 就是"两个方向都测到了"。
-- K4 ★ 收紧不变式在产出侧同样成立:有工序类型时,**没写进受理清单的一律拒**,
--    哪怕 may_be_fed = true。一个"设了工序就放行"的实现在这里红。
-- K5 ★★ **与进料侧的刻意分歧**:物料种类说【没有状态轴】时,产出侧照样问。
--    一个照抄进料侧 has_condition_axes 那一行的实现在这里红 —— 而它会
--    悄悄地让整道闸对线上每一批产出都失效。
-- K6 ★ 判据读的是【那张表】:补一行受理,拒绝就消失(证明不是写死的码)。
-- K7 ★ 那条占位的拒绝【已经拆掉】:状态改变型工序现在收得下自产料,
--    而且**它真的把状态改了** —— 不是一炉什么都没改的放电。
-- K8 进料侧一个字没动(R1:绝不放低进料那一侧)。
--
-- 日期:自带。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_ccy text; v_sup uuid;
    v_mat uuid;        -- 有种类(battery_material,has_condition_axes = true)
    v_mat_noaxes uuid; -- ★ 种类明说"我没有状态轴" —— K5 的整个意义
    v_ib uuid; v_ob uuid; v_ob2 uuid; v_ob3 uuid; v_ob_nk uuid; v_ob_sc uuid;
    v_run uuid;
    v_d date := DATE '2027-10-12';
    v_msg text; v_denied boolean; v_n int;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-165', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ165-S', 'f', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;

    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ165-M', 'f161 cathode', 'battery_material', true, 'cathode_sheet', 'end_of_life')
    RETURNING id INTO v_mat;

    -- ★【一个【明说自己没有状态轴】的种类】K5 用它。
    -- 【为什么不用"种类为空"的物料 —— 一次撞上来的约束】线上 20 批产出的物料
    -- kind_code 全是 NULL,而那正是本臂要防的那个场景。但 materials_kind_stated
    -- 这条 CHECK(NOT VALID:只管新行,不管既有行)**不许再插入 kind_code 为空的
    -- 物料** —— 于是那个场景在重建库里【构造不出来】。
    -- 所以这里用**可构造的等价物,而且它更强**:一个 has_condition_axes = false
    -- 的种类。进料侧那道闸对它明确地【不问】,产出侧必须照样问 ——
    -- 一个照抄 `IF FOUND AND v_axes IS TRUE` 的实现在这里同样红。
    INSERT INTO materials (code, name, kind_code, may_be_processed)
    VALUES ('ZZ165-NA', 'f161 no axes', 'ewaste', true) RETURNING id INTO v_mat_noaxes;
    IF (SELECT mk.has_condition_axes FROM material_kinds mk WHERE mk.code = 'ewaste') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 165 前置失败:K5 要的是一个【明说没有状态轴】的种类 —— 换一个 has_condition_axes = false 的种类,不要把这一臂删掉';
    END IF;

    -- ══════════ K1 · 对照:记了可投料状态的自产料,投得进去 ══════════
    RAISE NOTICE 'fixture 165 · 进入 K1';
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, unit, output_date, state)
    VALUES ('ZZ165-OB1', v_mat, 100, 100, 'kg', v_d - 1, '库存中') RETURNING id INTO v_ob;
    INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code)
    VALUES (v_ob, 'discharged_verified');
    -- 【先证明起点不是空的】
    IF (SELECT count(*) FROM output_batch_safety_states WHERE output_batch_id = v_ob) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 165K1 前置失败:那一行安全状态没有落上去 —— 后面每一句都是空的';
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f161 ok', 0,
            jsonb_build_array(jsonb_build_object('output_batch_id', v_ob, 'quantity_consumed', 10)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 9)), 'weight', NULL, NULL, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 165K1 失败:**这是整份 fixture 的铰链** —— 一批记了【可投料】状态的自产料必须投得进去。没有它,一个"把自产料全拦住"的实现会全绿,而那不是抬高产出侧,是把产线停掉。实得「%」', v_msg;
    END IF;

    -- ══════════ K2 · ★ 缺席即拒 ★ ══════════
    RAISE NOTICE 'fixture 165 · 进入 K2';
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, unit, output_date, state)
    VALUES ('ZZ165-OB2', v_mat, 100, 100, 'kg', v_d - 1, '库存中') RETURNING id INTO v_ob2;
    -- 【先证明注入确实改变了东西】这一批【真的】一条状态都没有。
    IF (SELECT count(*) FROM output_batch_safety_states WHERE output_batch_id = v_ob2) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 165K2 前置失败:这一臂要的是一批【一条状态都没有】的料';
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f161 none', 0,
            jsonb_build_array(jsonb_build_object('output_batch_id', v_ob2, 'quantity_consumed', 10)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 9)), 'weight', NULL, NULL, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'PRODUCED_SAFETY_STATE_NOT_RECORDED|%' THEN
        RAISE EXCEPTION 'FIXTURE 165K2 失败:**一条安全状态都没有的意思是【没有人记过】,不是"它安全"。** 这与进料侧 INPUT_SAFETY_STATE_NOT_RECORDED 必须是同一个意思 —— 同一种"空"在两张表里若有相反的意思,就是本仓库反复付账的那一族。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ K3 · ★ 反方向:不可投料的状态被拒 ★ ══════════
    RAISE NOTICE 'fixture 165 · 进入 K3';
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, unit, output_date, state)
    VALUES ('ZZ165-OB3', v_mat, 100, 100, 'kg', v_d - 1, '库存中') RETURNING id INTO v_ob3;
    INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code)
    VALUES (v_ob3, 'charged_not_discharged');
    IF (SELECT may_be_fed FROM inbound_safety_states WHERE code = 'charged_not_discharged') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 165K3 前置失败:这一臂要的是一个【不可投料】的状态';
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f161 bad', 0,
            jsonb_build_array(jsonb_build_object('output_batch_id', v_ob3, 'quantity_consumed', 10)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 9)), 'weight');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'OPERATION_TYPE_REQUIRED%' THEN
        RAISE EXCEPTION 'FIXTURE 165K3 失败(PROC-SUPPORT-1):这一臂原本钉 PRODUCED_SAFETY_STATE_NOT_FEEDABLE,也就是产出侧【没有工序时】那条 may_be_fed 规则。工序必填之后那一支到不了了,于是这一臂改钉站在它原位上的那条拒绝:**产出侧的单同样必须说出工序**。
【为什么不是随手把它换成 _NOT_ACCEPTED】那会与 K4 变成同一臂(K4 已经钉了"有工序 → 没写进清单的一律拒",而且就在产出侧)。**两臂钉同一件事,等于少了一臂。** 产出侧"带着坏状态被拒"这件事由 K4 保着;这一臂保的是"连工序都没说的单进不来"。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ K4 · ★ 收紧不变式在产出侧同样成立 ★ ══════════
    -- 用一个 may_be_fed = true 的状态,去撞一道【没把它列进清单】的工序。
    RAISE NOTICE 'fixture 165 · 进入 K4';
    INSERT INTO operation_types (code, name_en, name_zh, kind_code, sort_order, notes)
    VALUES ('zz161_narrow', 'f161 narrow', 'f161 收紧', 'transforming', 98, 'fixture 165 K4');
    INSERT INTO operation_type_input_forms (operation_type_code, form_code)
    VALUES ('zz161_narrow', 'cathode_sheet');
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f161 narrow', 0,
            jsonb_build_array(jsonb_build_object('output_batch_id', v_ob, 'quantity_consumed', 10)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 9)), 'weight',
            NULL, NULL, 'zz161_narrow');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'PRODUCED_SAFETY_STATE_NOT_ACCEPTED|%' THEN
        RAISE EXCEPTION 'FIXTURE 165K4 失败:**声明一道工序只会把闸收紧,产出侧也一样。** 一个 may_be_fed = true 的状态,只要没被这道工序列进清单,就必须被拒。一个"设了工序就放行"的实现在这里绿。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ K5 · ★★ 与进料侧的刻意分歧:种类说"没有状态轴",照样问 ★★ ══════
    RAISE NOTICE 'fixture 165 · 进入 K5';
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, unit, output_date, state)
    VALUES ('ZZ165-NA', v_mat_noaxes, 100, 100, 'kg', v_d - 1, '库存中') RETURNING id INTO v_ob_nk;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f161 nokind', 0,
            jsonb_build_array(jsonb_build_object('output_batch_id', v_ob_nk, 'quantity_consumed', 10)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 9)), 'weight', NULL, NULL, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'PRODUCED_SAFETY_STATE_NOT_RECORDED|%' THEN
        RAISE EXCEPTION 'FIXTURE 165K5 失败:**这一臂是本 fixture 的解药。** 物料的种类明说【没有状态轴】时,产出侧【照样问】—— 一个照抄进料侧 has_condition_axes 那一行的实现在这里绿。而线上 20 批产出的物料 kind_code 全是 NULL(同样落进那一行的否定分支),于是整道闸会对【零】批货生效,别的臂全都对着空气变绿。对产出料,种类没分过 / 说了没有状态轴,意思都是**没有人回答过这个问题**,而那不是许可 —— 这是一道火闸。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ K6 · ★ 判据读的是【那张表】,不是写死的码 ══════════
    RAISE NOTICE 'fixture 165 · 进入 K6';
    INSERT INTO operation_type_safety_states (operation_type_code, safety_state_code, resolves)
    VALUES ('zz161_narrow', 'discharged_verified', false);
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f161 now ok', 0,
            jsonb_build_array(jsonb_build_object('output_batch_id', v_ob, 'quantity_consumed', 10)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 9)), 'weight',
            NULL, NULL, 'zz161_narrow');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 165K6 失败:受理清单是【数据】—— 补一行,拒绝就该消失。一个把码写死的实现在这里红。实得「%」', v_msg;
    END IF;

    -- ══════════ K7 · ★ 占位拒绝已拆,而且状态【真的】被改了 ══════════
    RAISE NOTICE 'fixture 165 · 进入 K7';
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, unit, output_date, state)
    VALUES ('ZZ165-SC', v_mat, 100, 100, 'kg', v_d - 1, '库存中') RETURNING id INTO v_ob_sc;
    INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code)
    VALUES (v_ob_sc, 'charged_not_discharged');
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f161 discharge', 0,
            jsonb_build_array(jsonb_build_object('output_batch_id', v_ob_sc, 'quantity_consumed', 10)),
            '[]'::jsonb, 'weight', NULL, NULL, 'deep_discharge');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 165K7 失败:那条占位的拒绝(STATE_CHANGE_OUTPUT_INPUT_UNSUPPORTED)自己写着"等 1B-ii 的 output_batch_safety_states"。表建好了,它就必须消失 —— **一道工序因为料是自己产的就拒绝它,正是 M4 那处不对称本身。** 实得「%」', v_msg;
    END IF;
    -- ★【它必须【真的】改了状态,不是一炉什么都没改的放电】
    IF EXISTS (SELECT 1 FROM output_batch_safety_states
                WHERE output_batch_id = v_ob_sc AND safety_state_code = 'charged_not_discharged') THEN
        RAISE EXCEPTION 'FIXTURE 165K7 失败:深度放电【解决】未放电这个状态 —— 它必须从这批自产料身上被删掉。不删的话,一批放完电的自产料会永远带着"未放电",下一道工序仍然拒绝它:那就是 1B-i 解掉的那个死锁,原样搬到产出批上复发。';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM output_batch_safety_states
                    WHERE output_batch_id = v_ob_sc AND safety_state_code = 'discharged_verified') THEN
        RAISE EXCEPTION 'FIXTURE 165K7 失败:放完电之后,结果状态(已放电并核验)必须写到这批自产料身上 —— 否则这一炉是一次静默的无操作。';
    END IF;

    -- ══════════ K8 · 进料侧一个字没动(R1) ══════════
    RAISE NOTICE 'fixture 165 · 进入 K8';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ165-IB', v_mat, v_sup, 100, 100, 'kg', v_d - 1, 'other', 'fixture 165 自带数据') RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, v_ccy, NULL, 'f');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f161 inbound', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 10)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 9)), 'weight', NULL, NULL, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'INPUT_SAFETY_STATE_NOT_RECORDED|%' THEN
        RAISE EXCEPTION 'FIXTURE 165K8 失败:**R1:抬高产出这一侧,绝不放低进料那一侧。** 进料侧那条拒绝必须一个字没变。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;
END $$;
ROLLBACK;
