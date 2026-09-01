-- 178 一张加工单必须说出工序,而那句话【打开四道闸】 · PROC-SUPPORT-1
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【它钉什么】
-- A  ★ 没有工序 → OPERATION_TYPE_REQUIRED,而且是【它自己那一条码】。
--    先注入证明:同一份载荷【点名工序】就提交得了 —— 否则这一臂可能只是因为
--    别的原因被拒,而 fixture 会因为错的理由变绿。
-- B  ★ 表上那条 NOT VALID 的 CHECK 拦得住【裸 INSERT】—— 函数不是唯一的门:
--    processing_runs 有一条 "insert by permission" 的 RLS 策略。
-- C  ★ 那 14 张历史单【不被回填】,而且约束【保持 NOT VALID】。
--    先注入证明:一张没有工序的历史单确实【插得进去】(照着约束不生效的样子),
--    再断言它还在、且 operation_type_code 仍然是空的。
-- D1 闸①【产出有无由工序说了算】—— 点名 deep_discharge + 带产出 → 按名拒。
-- D2 闸②【状态改变型损耗必须为零】—— 点名 deep_discharge + 损耗 3 → 按名拒。
-- D3 闸③【逐工序安全状态受理】—— 一个 may_be_fed = true 却没被这道工序受理的
--    状态 → 按名拒。★ 这一臂同时钉住那句【更正】:闸③在没有工序时是【降级】,
--    不是【敞开】,而它降级成的那条规则(may_be_fed)今天恰好与它重合。
-- D4 闸④【工序必须存在且启用】—— 一个不存在的码 → 按名拒。
-- E  ★ 四条拒绝【互不相同】。合并任何两条,屏幕上就有一句话对应两个去处。
--
-- 【为什么每一臂都先注入】README 第 3 条的同一条精神:一个"把所有单都拒掉"的
-- 实现会让 A/D1/D2/D3/D4 全绿。每一臂因此都配一个【必须通过】的对照。
--
-- 日期:自带。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_ccy text; v_sup uuid; v_mat uuid;
    v_ib uuid; v_ib2 uuid; v_ib3 uuid; v_ib4 uuid;
    v_run uuid; v_hist uuid;
    v_d date := DATE '2027-12-01';
    v_msg text; v_denied boolean;
    v_a text; v_b text; v_c text; v_e text;
    v_valid boolean; v_op_after text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    -- README 第 5 条:前提显式设定,即便默认值恰好合用。
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-178', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ178-S', 'f', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
    VALUES ('ZZ178-M', 'f178 pack', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction')
    RETURNING id INTO v_mat;

    -- ══════════ A · ★ 没有工序 → 按名拒,而且是自己那一条码 ★ ══════════
    RAISE NOTICE 'fixture 178 · 进入 A';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ178-A', v_mat, v_sup, 100, 100, 'kg', v_d - 1) RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, v_ccy, NULL, 'f');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib, 'discharged_verified');

    -- 【先证明注入确实改变了东西】同一份载荷,点名工序就走得通。
    -- 少了这一句,一个"把所有单都拒掉"的实现会让 A 变绿。
    v_run := NULL; v_msg := NULL;
    BEGIN
        v_run := commit_processing_run(v_d, 'f178 A control', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 10)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 9)), 'weight',
            NULL, NULL, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_run IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 178A 前置失败:**同一份载荷点名工序必须提交得了。** 少了这一句,一个把所有加工单都拒掉的实现会让本臂变绿,而那不是"工序必填",那是"加工停摆"。实得「%」', COALESCE(v_msg, '(返回空)');
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f178 A', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 10)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 9)), 'weight');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    v_a := split_part(COALESCE(v_msg, ''), '|', 1);
    IF NOT v_denied OR v_a <> 'OPERATION_TYPE_REQUIRED' THEN
        RAISE EXCEPTION 'FIXTURE 178A 失败:一张【没有说出工序】的加工单必须被按名拒,而且是 OPERATION_TYPE_REQUIRED —— 不是 NO_INPUTS,也不是安全状态那几条。**下一步动作是"回去选一道工序"**,而只有这条码说得出这句话。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ B · ★ 裸 INSERT 也进不去 —— 函数不是唯一的门 ★ ══════════
    RAISE NOTICE 'fixture 178 · 进入 B';
    -- 【先证明这条路本来是通的】带着工序的裸 INSERT 必须插得进去,
    -- 否则下面那一句"被拦住"可能只是因为 RLS 根本不让写。
    v_msg := NULL;
    BEGIN
        INSERT INTO processing_runs (process_date, status, allocation_basis,
                                     total_input, total_output, loss_qty, operation_type_code)
        VALUES (v_d, 'committed', 'weight', 0, 0, 0, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 178B 前置失败:**带着工序的裸 INSERT 本来就该插得进去** —— 少了这一句,下面那一臂可能只是因为 RLS 不让写而变绿,与那条 CHECK 毫无关系。实得「%」', v_msg;
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO processing_runs (process_date, status, allocation_basis,
                                     total_input, total_output, loss_qty)
        VALUES (v_d, 'committed', 'weight', 0, 0, 0);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%processing_runs_operation_type_required%' THEN
        RAISE EXCEPTION 'FIXTURE 178B 失败:**函数里那条拒绝不是唯一的门。** processing_runs 有一条 "insert by permission" 的 RLS 策略,于是任何拿到 module.processing.edit 的人都能直接插一张加工单绕开 commit_processing_run —— 而那张单会永远落在"未归属"里,没有任何报表能把它归给谁。表上那条 NOT VALID 的 CHECK 就是为这条路准备的。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ C · ★ 历史单不回填,而约束保持 NOT VALID ★ ══════════
    RAISE NOTICE 'fixture 178 · 进入 C';
    -- 【注入:造一张"历史"单 —— 它必须是【绕过约束】造出来的】
    -- 这正是线上那 14 张单当初的样子。用 NOT VALID 的语义:先把约束丢掉、
    -- 插进去、再原样加回来(NOT VALID),重放一遍线上的历史。
    ALTER TABLE processing_runs DROP CONSTRAINT processing_runs_operation_type_required;
    INSERT INTO processing_runs (process_date, status, allocation_basis,
                                 total_input, total_output, loss_qty)
    VALUES (v_d - 100, 'committed', 'weight', 10, 9, 1) RETURNING id INTO v_hist;
    ALTER TABLE processing_runs
        ADD CONSTRAINT processing_runs_operation_type_required
        CHECK (operation_type_code IS NOT NULL) NOT VALID;

    -- 【先证明注入确实改变了东西】那张单真的在,而且真的没有工序。
    SELECT operation_type_code INTO v_op_after FROM processing_runs WHERE id = v_hist;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FIXTURE 178C 前置失败:那张"历史"单没造出来,后面每一句都是空的';
    END IF;
    IF v_op_after IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 178C 前置失败:这一臂要的是一张【没有工序】的历史单,实得「%」', v_op_after;
    END IF;

    -- ★ 约束必须【仍然是 NOT VALID】★ 一次顺手的 VALIDATE 会去检查这些行,
    --   而让它通过的唯一办法是给它们猜一个工序 —— 正是本刀在防的那个错误。
    SELECT convalidated INTO v_valid FROM pg_constraint
     WHERE conname = 'processing_runs_operation_type_required';
    IF v_valid IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 178C 失败:**那条约束必须保持 NOT VALID,而且永远不要 VALIDATE 它。** 线上 14 张(10 张未软删)没有工序的加工单是【测试残留】,不是待修的破损;VALIDATE 会去检查它们,而唯一能让它通过的办法是给它们【猜一个工序】—— 猜出来的工序与真的工序长得一模一样,会流进设备用量、回收率、工单实绩,并且会让那四道闸【看起来对这些单生效过】,而它们从未生效过。';
    END IF;

    -- ══════════ D1 · 闸①:产出有无由工序说了算 ══════════
    RAISE NOTICE 'fixture 178 · 进入 D1';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ178-B', v_mat, v_sup, 100, 100, 'kg', v_d - 1) RETURNING id INTO v_ib2;
    PERFORM reprice_inbound_batch(v_ib2, 1, v_ccy, NULL, 'f');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib2;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib2, 'charged_not_discharged');
    -- 前提:深度放电确实是【不产出】的那一类,否则这一臂测不到东西。
    IF (SELECT k.produces_outputs FROM operation_types ot JOIN operation_kinds k ON k.code = ot.kind_code
         WHERE ot.code = 'deep_discharge') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 178D1 前置失败:深度放电必须是【不产出】的那一类 —— 本臂的整个意义在这里';
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f178 D1', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib2, 'quantity_consumed', 10)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 9)), 'weight',
            NULL, NULL, 'deep_discharge');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    v_b := split_part(COALESCE(v_msg, ''), '|', 1);
    IF NOT v_denied OR v_b <> 'OPERATION_PRODUCES_NO_OUTPUTS' THEN
        RAISE EXCEPTION 'FIXTURE 178D1 失败(闸①):一张"深度放电还产出了黑粉"的单必须被拒。**在工序必填之前,这一闸对没有工序的单整个不生效** —— v_produces 默认 true,于是走的是"照旧"那一支。线上量过:同一份载荷不给工序时提交成功(PROC-2026-0588)。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ D2 · 闸②:状态改变型损耗必须为零 ══════════
    RAISE NOTICE 'fixture 178 · 进入 D2';
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f178 D2', 3,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib2, 'quantity_consumed', 10)),
            '[]'::jsonb, 'weight', NULL, NULL, 'deep_discharge');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    v_c := split_part(COALESCE(v_msg, ''), '|', 1);
    IF NOT v_denied OR v_c <> 'STATE_CHANGE_LOSS_NOT_ZERO' THEN
        RAISE EXCEPTION 'FIXTURE 178D2 失败(闸②):放电【不带走任何质量】,所以它的损耗只能是 0。**在工序必填之前,不给工序的单连"状态改变型"这个概念都没有主语** —— 线上量过:同一份载荷不给工序时,提交成功并记下了 loss_qty = 3,也就是一炉放电报告它毁掉了 3 公斤。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ D3 · 闸③:逐工序安全状态受理(★ 降级,不是敞开 ★)══════════
    RAISE NOTICE 'fixture 178 · 进入 D3';
    -- ════════════════════════════════════════════════════════════════════════
    -- ★★【这一臂同时钉住一句【更正】,请不要把它简化掉】★★
    -- PROC-SUPPORT-1 的 brief 原话说:没有工序会【绕过】这道闸。**不对。**
    -- 没有工序时闸【仍然在】,只是换了一条更弱的规则:inbound_safety_states
    -- .may_be_fed(能不能投给【任何】工序),而不是 operation_type_safety_states
    -- (【这一道】工序受不受理)。**是降级,不是敞开。**
    -- 而今天的种子行让这两条规则【恰好重合】:may_be_fed = true 的状态只有
    -- discharged_verified 一个,而它被【全部五道】工序受理。
    -- **那是巧合,不是构造上的保证** —— 所以这一臂自己造一个"一般可投、但这道
    -- 工序不收"的状态,把那个机制量出来,并把巧合本身也断言下来。
    -- 【为什么这个区别值得一整段】把一处降级说成一处敞开是它自己的一种伤害:
    -- 下一个人会照着那句夸大的话校准,要么高估了历史数据的危险,要么在发现
    -- "其实没那么糟"之后连真的那一半也不信了。
    -- ════════════════════════════════════════════════════════════════════════
    INSERT INTO inbound_safety_states (code, name_en, name_zh, may_be_fed, sort_order, notes)
    VALUES ('zz178_state', 'f178 probe', 'f178 探针', true, 99, 'fixture 178 D3');

    -- 【先把那个巧合断言下来】今天 may_be_fed = true 的状态里(除去本臂造的这一行),
    -- 没有任何一个是"某道启用的工序不受理"的。这句话哪天不成立了,
    -- 说明字典长出了一个真正的缺口 —— 那时这一行会红,而它【应该】红。
    IF (SELECT count(*) FROM inbound_safety_states s
         WHERE s.may_be_fed AND s.code <> 'zz178_state'
           AND EXISTS (SELECT 1 FROM operation_types ot WHERE ot.is_active
                        AND NOT EXISTS (SELECT 1 FROM operation_type_safety_states a
                                         WHERE a.operation_type_code = ot.code
                                           AND a.safety_state_code = s.code))) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 178D3 提示:字典里出现了一个【一般可投、但某道启用的工序不受理】的安全状态。这不是缺陷,是本臂上面那一整段说的那件事发生了:两条规则不再重合。请重读那一段,再决定这一行断言该改成什么 —— **不要直接删掉它**。';
    END IF;

    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ178-C', v_mat, v_sup, 100, 100, 'kg', v_d - 1) RETURNING id INTO v_ib3;
    PERFORM reprice_inbound_batch(v_ib3, 1, v_ccy, NULL, 'f');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib3;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib3, 'zz178_state');

    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f178 D3', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib3, 'quantity_consumed', 10)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 9)), 'weight',
            NULL, NULL, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    v_e := split_part(COALESCE(v_msg, ''), '|', 1);
    IF NOT v_denied OR v_e <> 'INPUT_SAFETY_STATE_NOT_ACCEPTED' THEN
        RAISE EXCEPTION 'FIXTURE 178D3 失败(闸③):一个【一般可投、但这道工序没把它列进清单】的安全状态必须被拒。这正是"降级"与"敞开"的差别所在:不给工序时,may_be_fed = true 会让它【溜过去】。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;
    -- 【反面:把它列进清单就走得通】—— 少了这一半,一个"把所有状态都拒掉"的
    -- 实现也会绿,而那不是收紧,是停线。
    INSERT INTO operation_type_safety_states (operation_type_code, safety_state_code, resolves, notes)
    VALUES ('manual_disassembly', 'zz178_state', false, 'fixture 178 D3 反面');
    v_run := NULL; v_msg := NULL;
    BEGIN
        v_run := commit_processing_run(v_d, 'f178 D3 control', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib3, 'quantity_consumed', 10)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 9)), 'weight',
            NULL, NULL, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_run IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 178D3 失败(闸③反面):把这个状态写进这道工序的受理清单之后,那一批必须投得进去。**规则是现读的** —— 同一笔事务里加一行字典,结论当场就动。实得「%」', COALESCE(v_msg, '(返回空)');
    END IF;

    -- ══════════ D4 · 闸④:工序必须存在且启用 ══════════
    RAISE NOTICE 'fixture 178 · 进入 D4';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ178-D', v_mat, v_sup, 100, 100, 'kg', v_d - 1) RETURNING id INTO v_ib4;
    PERFORM reprice_inbound_batch(v_ib4, 1, v_ccy, NULL, 'f');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib4;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib4, 'discharged_verified');
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f178 D4', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib4, 'quantity_consumed', 10)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 9)), 'weight',
            NULL, NULL, 'zz_no_such_operation');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'OPERATION_TYPE_UNKNOWN|%' THEN
        RAISE EXCEPTION 'FIXTURE 178D4 失败(闸④):一个不存在的工序码必须被拒。**NULL 曾经是唯一一个绕开字典的取值** —— 旧代码把整段字典查询包在 IF ... IS NOT NULL 里,于是不给工序时这道闸【整个不发生】。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ E · ★ 四条拒绝互不相同 ★ ══════════
    RAISE NOTICE 'fixture 178 · 进入 E';
    IF v_a = v_b OR v_a = v_c OR v_a = v_e OR v_b = v_c OR v_b = v_e OR v_c = v_e THEN
        RAISE EXCEPTION 'FIXTURE 178E 失败:这四条拒绝必须【互不相同】。下一步动作完全不一样 —— 没选工序 → 回去选一个;单据形状与工序矛盾 → 改单或改工序;损耗填错 → 改那一栏;这批料这道工序不收 → 换一道工序。**合并任何两条,屏幕上就会有一句话对应两个去处,而操作员会走错门。** 实得 A=%、D1=%、D2=%、D3=%', v_a, v_b, v_c, v_e;
    END IF;

END $$;
ROLLBACK;
