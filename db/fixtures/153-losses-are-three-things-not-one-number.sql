-- 153 损耗是三件事,不是一个数 —— PROC-BUILD-1 的第一件
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- 【每一臂钉什么】
-- F1 前提,先于一切派生量:**一张【不分类】的加工单照旧提交,loss_qty 照旧落到
--    它原来的值上**。少了这一半,一个"把所有人都拦住"的实现会全绿 ——
--    而且这一臂同时证明【loss_qty 这一列没有被本刀动过】,那是本刀的边界。
-- F2 三类各记一行,而且【金属去向不同】。这一臂断言的是那张字典存在的理由:
--    moisture 的金属留着、dust_spill 的金属走了 —— **一个数表达不了这个区别**。
-- F3 electrolyte_evaporation 【自成一类】,而且它的 metal_fate 是 unknown。
--    这一臂挡的是"顺手把它并进 moisture" —— 并进去等于免费送出一个
--    "金属留着"的断言,而线上产出批化验 0 条,没有人知道那是不是真的。
-- F4 residue_disposal 的 is_true_loss 为 **false**:它不是损耗,是一条带负价值的
--    产出,暂停在这里。这一臂挡的是把 W2-(iii) 的判决读丢。
-- F5 分类之和【不许超过】 loss_qty,按名拒;而【不相等是允许的】。
--    两个方向都测:只测拒绝的话,一个"总是拒"的实现照样绿。
-- F6 loss_qty 为 NULL 时【不拦】—— 空的意思是"没人记过总量",不是"总量为零"。
--    拿 0 去比会把没人填过读成上限为零(METAL-1 的 no_reference 那个错)。
-- F7 已解释 / 未解释:视图把差额说出来,而 loss_qty 为空时差额是 **NULL 不是 0**。
--
-- 日期:自带。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_ccy text;
    v_sup uuid; v_mat uuid; v_matB uuid;
    v_ib uuid; v_run uuid; v_run2 uuid;
    v_process date := DATE '2027-07-02';
    v_denied boolean; v_msg text;
    v_loss numeric; v_cat numeric; v_unexp numeric;
    v_fate text; v_true boolean; v_n int;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-153', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ153-S', 'fixture 153 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ153-M', 'f153 feed', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ153-MB', 'f153 out', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_matB;

    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ153-IB1', v_mat, v_sup, 1000, 1000, 'kg', v_process - 1) RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, v_ccy, NULL, 'f153 price');
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib, 'discharged_verified');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib;

    -- ══════════ F1 · 前提:不分类照旧,而且 loss_qty 没有被动过 ══════════
    RAISE NOTICE 'fixture 153 · 进入 F1';
    v_run := commit_processing_run(v_process, 'f153 run', 100,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 1000)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 900)), 'weight', NULL, NULL, 'manual_disassembly');
    IF v_run IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 153F1 失败:一张【不分类】的加工单必须照旧提交得了。本刀不动 loss_qty,也不要求分类';
    END IF;
    SELECT loss_qty INTO v_loss FROM processing_runs WHERE id = v_run;
    IF v_loss IS DISTINCT FROM 100 THEN
        RAISE EXCEPTION 'FIXTURE 153F1 失败:loss_qty 本应原样落成 100(调用方传什么就是什么,本刀一列没动)。实得「%」', COALESCE(v_loss::text, 'NULL');
    END IF;
    -- 【注入前先证明库是干净的】一条分类行都还没有。
    IF EXISTS (SELECT 1 FROM processing_run_losses WHERE run_id = v_run) THEN
        RAISE EXCEPTION 'FIXTURE 153F1 前置失败:此刻这张单本应【一条分类行都没有】—— 后面几臂证明的正是"记上去之后发生了什么"';
    END IF;

    -- ══════════ F2 · 三类各一行,而金属去向【不同】 ══════════
    RAISE NOTICE 'fixture 153 · 进入 F2';
    INSERT INTO processing_run_losses (run_id, loss_category_code, quantity)
    VALUES (v_run, 'moisture', 40), (v_run, 'dust_spill', 25);
    -- 【注入确实改变了东西】—— 先证明这一点,再断言它的后果。
    SELECT count(*) INTO v_n FROM processing_run_losses WHERE run_id = v_run;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 153F2 前置失败:两行分类本应真的写进去了。实得 % 行', v_n;
    END IF;
    SELECT metal_fate INTO v_fate FROM loss_categories WHERE code = 'moisture';
    IF v_fate <> 'stays' THEN
        RAISE EXCEPTION 'FIXTURE 153F2 失败:moisture 的金属【留着】(W2-i:质量走了、金属没走)。实得「%」', v_fate;
    END IF;
    SELECT metal_fate INTO v_fate FROM loss_categories WHERE code = 'dust_spill';
    IF v_fate <> 'leaves' THEN
        RAISE EXCEPTION 'FIXTURE 153F2 失败:dust_spill 的金属【走了】(W2-ii)。实得「%」', v_fate;
    END IF;
    -- **这就是那张字典存在的全部理由**:两类对"金属去哪了"的答案相反。
    IF (SELECT metal_fate FROM loss_categories WHERE code = 'moisture')
       = (SELECT metal_fate FROM loss_categories WHERE code = 'dust_spill') THEN
        RAISE EXCEPTION 'FIXTURE 153F2 失败:水与粉尘对"金属去哪了"的答案必须【相反】—— 它们相同的话,分类就没有意义,回收率照样算不对';
    END IF;

    -- ══════════ F3 · 电解液自成一类,金属去向是 unknown ══════════
    RAISE NOTICE 'fixture 153 · 进入 F3';
    IF NOT EXISTS (SELECT 1 FROM loss_categories WHERE code = 'electrolyte_evaporation') THEN
        RAISE EXCEPTION 'FIXTURE 153F3 失败:电解液挥发(R4)必须表示得出来 —— 它是第一条产线上【计划中】就有的一种损耗';
    END IF;
    SELECT metal_fate INTO v_fate FROM loss_categories WHERE code = 'electrolyte_evaporation';
    IF v_fate <> 'unknown' THEN
        RAISE EXCEPTION 'FIXTURE 153F3 失败:电解液的 metal_fate 必须是【unknown】。**不要把它并进 moisture** —— 那等于免费送出一个"金属留着"的断言,而线上产出批化验 0 条,没有人知道那是不是真的。实得「%」', v_fate;
    END IF;

    -- ══════════ F4 · 残渣送处置【不是】损耗 ══════════
    RAISE NOTICE 'fixture 153 · 进入 F4';
    SELECT is_true_loss INTO v_true FROM loss_categories WHERE code = 'residue_disposal';
    IF v_true IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 153F4 失败:residue_disposal 的 is_true_loss 必须是 false —— W2-(iii) 判过它【根本不是损耗】,它是一条带负价值的产出,归宿要等 U6。实得「%」', COALESCE(v_true::text, 'NULL');
    END IF;
    SELECT is_true_loss INTO v_true FROM loss_categories WHERE code = 'dust_spill';
    IF v_true IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 153F4 失败:dust_spill 才是那个【真的】损耗。两者必须分得开';
    END IF;

    -- ══════════ F5 · 之和不许超过总量;而不相等是允许的 ══════════
    RAISE NOTICE 'fixture 153 · 进入 F5';
    -- 方向一:40 + 25 = 65 < 100 —— **允许**,不要求凑平。
    SELECT sum(quantity) INTO v_cat FROM processing_run_losses WHERE run_id = v_run;
    IF v_cat <> 65 THEN
        RAISE EXCEPTION 'FIXTURE 153F5 前置失败:此刻已分类之和本应是 65。实得「%」', v_cat;
    END IF;
    -- 方向二:再加一行把和推到 110 > 100 —— **按名拒**。
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO processing_run_losses (run_id, loss_category_code, quantity)
        VALUES (v_run, 'residue_disposal', 45);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 153F5 失败:已分类之和(110)超过 loss_qty(100)必须被拒。**这条不等式守得住,因为它不需要知道真实配比** —— 与 OUTPUT_EXCEEDS_INPUT 同一个形状';
    END IF;
    IF v_msg NOT LIKE 'LOSS_CATEGORIES_EXCEED_LOSS_QTY|%' THEN
        RAISE EXCEPTION 'FIXTURE 153F5 失败:拒绝必须按名。实得「%」', v_msg;
    END IF;

    -- ══════════ F6 · loss_qty 为 NULL 时【不拦】 ══════════
    RAISE NOTICE 'fixture 153 · 进入 F6';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ153-IB2', v_mat, v_sup, 500, 500, 'kg', v_process - 1) RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, v_ccy, NULL, 'f153 price 2');
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib, 'discharged_verified');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib;
    v_run2 := commit_processing_run(v_process, 'f153 run2', NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 500)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 500)), 'weight', NULL, NULL, 'manual_disassembly');
    -- 投入 500、产出 500,于是默认损耗是 0;把它改成 NULL 才谈得上这一臂。
    UPDATE processing_runs SET loss_qty = NULL WHERE id = v_run2;
    IF (SELECT loss_qty FROM processing_runs WHERE id = v_run2) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 153F6 前置失败:这一臂要的是一张 loss_qty 为【空】的单 —— 注入本应生效';
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO processing_run_losses (run_id, loss_category_code, quantity)
        VALUES (v_run2, 'moisture', 7);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 153F6 失败:loss_qty 为空时【不许拦】。空的意思是"没有人记过总量",不是"总量是零" —— 拿 0 去比就是 METAL-1 的 no_reference 那个错。实得「%」', v_msg;
    END IF;

    -- ══════════ F7 · 已解释 / 未解释,而空不是零 ══════════
    RAISE NOTICE 'fixture 153 · 进入 F7';
    SELECT categorised_qty, unexplained_qty INTO v_cat, v_unexp
      FROM processing_run_loss_breakdown WHERE run_id = v_run;
    IF v_cat <> 65 OR v_unexp <> 35 THEN
        RAISE EXCEPTION 'FIXTURE 153F7 失败:100 的总量记了 65 类,还没解释的是 35。实得 已分类「%」未解释「%」', v_cat, COALESCE(v_unexp::text, 'NULL');
    END IF;
    SELECT unexplained_qty INTO v_unexp FROM processing_run_loss_breakdown WHERE run_id = v_run2;
    IF v_unexp IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 153F7 失败:loss_qty 为空时"还没解释多少"这个问题【不成立】,差额必须是 NULL。**0 会把它读成"全部解释完了"**。实得「%」', v_unexp;
    END IF;
END $$;
ROLLBACK;
