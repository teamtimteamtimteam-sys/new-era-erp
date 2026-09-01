-- 156 销售状态变成字典之后,行为一个字没变 —— 而它仍然【只】答销售那个问题
--     PROC-WIRE-1A(R5 活下来的那一半)
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- 【每一臂钉什么】
-- A 字典【正好】是原来那三个取值 —— 不多不少。本刀是【结构】变更,不是语义变更,
--   而"顺手多加一个取值"正是这类改动最容易夹带的东西。
-- B 三个取值仍然存得进去 —— 行为不变的正面证据。
-- C **一个不在字典里的取值仍然被拒**,而且现在是【外键】拒。
--   ★ 先证明注入确实改变了东西:那个值确实不在字典里(否则这一臂在测空气)。
-- D 销售路仍然按 remaining_qty 写状态:卖一部分 → 部分售出,卖光 → 已售罄。
--   这一臂钉的是【谁在写这一列】—— 换成字典没有把这件事挪走。
-- E ★★ **消耗【不是】卖光** —— 一批被下游工序吃光的产出批,remaining_qty 归零
--   而 state 仍然是「库存中」。**这一臂是整份 fixture 存在的理由**:它用实测
--   证明了"工序投料"为什么【不能】是这条轴上的第四个取值 —— 那样就得再造一个
--   「已消耗」销售取值,而合并两条轴的实现会在这里红。
--
-- 日期:自带。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_ccy text; v_sup uuid; v_cust uuid;
    v_mat uuid; v_ob uuid; v_ob2 uuid; v_ib uuid; v_run uuid;
    v_d date := DATE '2027-08-03';
    v_n int; v_denied boolean; v_msg text; v_state text; v_rem numeric;
    v_codes text[] := ARRAY['库存中','部分售出','已售罄'];
    v_code text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-156', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ156-S', 'f156 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO customers (code, legal_name, country, status)
    VALUES ('ZZ156-C', 'f156 customer', 'SG', 'active') RETURNING id INTO v_cust;
    -- 正极片:可售(PROC-BUILD-1 的 R5),所以 D 臂那笔销售不会被别的判据拦下来。
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ156-CAT', 'f156 cathode sheet', 'battery_material', true, 'cathode_sheet', 'end_of_life')
    RETURNING id INTO v_mat;

    -- ══════════ A · 字典正好是那三个取值 ══════════
    RAISE NOTICE 'fixture 156 · 进入 A';
    SELECT count(*) INTO v_n FROM output_batch_states;
    IF v_n <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 156A 失败:本刀是【结构】变更 —— 取值集合必须仍然正好是三个,实得 %。多一个取值是一次语义变更,要单独裁定,不许夹带。', v_n;
    END IF;
    FOREACH v_code IN ARRAY v_codes LOOP
        IF NOT EXISTS (SELECT 1 FROM output_batch_states WHERE code = v_code) THEN
            RAISE EXCEPTION 'FIXTURE 156A 失败:原有取值【%】不在字典里 —— 那不是结构变更,那是把线上的数据变成非法值', v_code;
        END IF;
    END LOOP;

    -- ══════════ B · 三个取值仍然存得进去 ══════════
    RAISE NOTICE 'fixture 156 · 进入 B';
    FOREACH v_code IN ARRAY v_codes LOOP
        INSERT INTO output_batches (code, material_id, quantity, remaining_qty, unit, output_date, state)
        VALUES ('ZZ156-B-' || v_code, v_mat, 10, 10, 'kg', v_d, v_code);
    END LOOP;

    -- ══════════ C · 字典外的取值被拒(而且是外键在拒)══════════
    RAISE NOTICE 'fixture 156 · 进入 C';
    -- 【先证明注入确实改变了东西】这个值确实不在字典里 —— 否则本臂在测空气。
    IF EXISTS (SELECT 1 FROM output_batch_states WHERE code = '已消耗') THEN
        RAISE EXCEPTION 'FIXTURE 156C 前置失败:本臂要的是一个【不在字典里】的取值,而「已消耗」竟然在。**如果有人真的加了这一行,那正是本刀反对的那件事** —— 见 E 臂';
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO output_batches (code, material_id, quantity, remaining_qty, unit, output_date, state)
        VALUES ('ZZ156-BAD', v_mat, 10, 10, 'kg', v_d, '已消耗');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 156C 失败:字典外的状态必须被拒。CHECK 换成外键之后【拦不住】的话,这一列就从"三选一"变成了自由文本 —— 那是 F7 记过账的那种退化';
    END IF;

    -- ══════════ D · 销售路仍然按 remaining_qty 写状态 ══════════
    RAISE NOTICE 'fixture 156 · 进入 D';
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, unit, output_date, state)
    VALUES ('ZZ156-OBD', v_mat, 100, 100, 'kg', v_d, '库存中') RETURNING id INTO v_ob;
    -- 【"必须成交"的臂要自己接住异常】被拒时 record_output_sale 是 RAISE ——
    -- 不接住的话 fixture 会以一条原始报错死掉:门是红的,却说不出是哪一臂。
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM record_output_sale(v_ob, 40, 5, v_ccy, NULL, v_cust, v_d, 'f156 partial', NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 156D 失败:这一批是可售形态、未被指定,这笔销售必须成交 —— 实得「%」', v_msg;
    END IF;
    SELECT state INTO v_state FROM output_batches WHERE id = v_ob;
    IF v_state <> '部分售出' THEN
        RAISE EXCEPTION 'FIXTURE 156D 失败:卖掉一部分之后必须是【部分售出】,实得「%」—— 换成字典没有把"谁在写这一列"挪走', v_state;
    END IF;
    PERFORM record_output_sale(v_ob, 60, 5, v_ccy, NULL, v_cust, v_d, 'f156 rest', NULL, NULL);
    SELECT state, remaining_qty INTO v_state, v_rem FROM output_batches WHERE id = v_ob;
    IF v_state <> '已售罄' OR v_rem <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 156D 失败:卖光之后必须是【已售罄】且余量为 0,实得「%」/ %', v_state, v_rem;
    END IF;

    -- ══════════ E · 消耗【不是】卖光 ★ 本刀的设计判据 ══════════
    RAISE NOTICE 'fixture 156 · 进入 E';
    -- 造一批产出批,再让它整批被下一道工序吃掉(FIN-25 的回炉路)。
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ156-IB', v_mat, v_sup, 200, 200, 'kg', v_d - 1, 'other', 'fixture 156 自带数据') RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, v_ccy, NULL, 'f156 price');
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib, 'discharged_verified');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib;
    v_run := commit_processing_run(v_d, 'f156 run 1', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 200)),
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 200)), 'weight', NULL, NULL, 'manual_disassembly');
    SELECT po.output_batch_id INTO v_ob2 FROM processing_outputs po WHERE po.run_id = v_run;

    -- 【先证明注入确实改变了东西】吃之前它是「库存中」且有余量。
    SELECT state, remaining_qty INTO v_state, v_rem FROM output_batches WHERE id = v_ob2;
    IF v_state <> '库存中' OR v_rem <> 200 THEN
        RAISE EXCEPTION 'FIXTURE 156E 前置失败:这一批本应是「库存中」/ 200,实得「%」/ %', v_state, v_rem;
    END IF;

    -- 【PROC-WIRE-1B-ii:自产的料要先记安全状态,才投得进去】
    -- 这不是本臂要测的东西,而是那道火闸【新拦下来的一件事】:产出批与进料批
    -- 现在被问同一个安全问题(R1 / M4)。一条状态都没有的意思是【没有人记过】,
    -- 不是"它安全" —— 于是这里必须像上面给进料批那样,明写一行。
    -- **这正是那条"不回填"的决定在测试里落下来的样子**:没有人替这一批
    -- 编造过一次核验,所以要用它,就得有人先记。
    INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code)
    VALUES (v_ob2, 'discharged_verified');

    -- 整批吃光它。
    v_run := commit_processing_run(v_d, 'f156 run 2', 0,
        jsonb_build_array(jsonb_build_object('output_batch_id', v_ob2, 'quantity_consumed', 200)),
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 200)), 'weight', NULL, NULL, 'manual_disassembly');

    SELECT state, remaining_qty INTO v_state, v_rem FROM output_batches WHERE id = v_ob2;
    IF v_rem <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 156E 前置失败:整批被吃掉之后余量必须是 0,实得 % —— 注入没有生效,后面那句断言就是空的', v_rem;
    END IF;
    IF v_state <> '库存中' THEN
        RAISE EXCEPTION
            'FIXTURE 156E 失败:一批被下游工序【吃光】的产出批,余量归零而销售状态必须仍然是「库存中」,实得「%」。'
            '**这一臂是 PROC-WIRE-1A 的设计判据**:它是【被用掉了】,不是【卖光了】,'
            '而这条轴表示"没有了"的取值只有「已售罄」—— 那句话会凭空认下一笔从来没发生过的收入。'
            '把"这批是干什么用的"合并进这条销售轴的实现,会在这里红。', v_state;
    END IF;
END $$;
ROLLBACK;
