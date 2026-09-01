-- 115 什么东西可以投料 —— PROC-1/PROC-2 记下的事实,现在是一条前置条件
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- 【每一臂钉什么】
-- F1 前提,先于一切派生量:**一批【可投料】的货照旧提交,而且这道闸【之前】的
--    拒绝顺序一个字没变**。少了这一半,一个"把所有人都拦住"的实现会全绿 ——
--    这个仓库为这件事付过账(fixture 112 F4 的原话:只测拒绝,铰链就没了)。
-- F2 D1 的三条拒绝,【一臂一条,按码断言】。它们分开不是洁癖:
--    "没有人记过"→ 去把它记下来;"这批货进过水"→ 去处理那批货;
--    "确定度是待识别"→ 等化验。三件不同的下一步动作,一个共用的码会把它藏起来。
-- F3 D2 合取,【两个方向】:一条可投料 + 一条不可投料 → 拒(而且【两条坏的都点名】);
--    全部可投料 → 过。只测一个方向,一个"只看第一条"的实现照样绿。
-- F4 D4:字典行被【停用】之后,已经贴着它的那批货【照样被拒】。
--    这一臂挡的是将来有人把守卫"简化"成顺手读一下 is_active。
-- F5 D5:一个【可加工、但没有状态轴】的种类,不带任何安全状态照样投得进去。
--    **这一臂最容易被漏掉**,而漏掉它只会在"哪天真的有这么一种料"那天才现形 ——
--    实测线上 ewaste 【今天就是】这一种(may_ever_be_processed=t, has_condition_axes=f),
--    所以它不是一个假想的分支。
--
-- 日期:自带(不依赖 public_holidays,不依赖 locked_before —— 自己设成 NULL)。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_ccy text;
    v_sup uuid;
    v_mat uuid; v_matB uuid; v_matNo uuid; v_matEw uuid;
    v_ib uuid; v_run uuid;
    v_process date := DATE '2027-07-01';
    v_denied boolean; v_msg text;
    v_remaining numeric; v_moves int; v_je int;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-115', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ115-S', 'fixture 115 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    -- 吃状态轴的种类(电池料)
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ115-M', 'f115 feed', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ115-MB', 'f115 out', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_matB;
    -- 【声明了不投料】的那一个 —— F1 用它钉拒绝顺序
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ115-MNO', 'f115 never fed', 'battery_material', false, 'black_mass', 'end_of_life') RETURNING id INTO v_matNo;
    -- 【可加工、但没有状态轴】—— F5 用它。ewaste 是线上真实的那一行,不是造出来的。
    INSERT INTO materials (code, name, kind_code, may_be_processed)
    VALUES ('ZZ115-MEW', 'f115 ewaste', 'ewaste', true) RETURNING id INTO v_matEw;

    -- ══════════ F1 · 前提:可投料的照旧,而闸【之前】的拒绝顺序没变 ══════════
    RAISE NOTICE 'fixture 115 · 进入 F1';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ115-IB1', v_mat, v_sup, 100, 100, 'kg', v_process - 1, 'other', 'fixture 115 自带数据') RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, v_ccy, NULL, 'f115 price');
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib, 'discharged_verified');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib;

    v_denied := false; v_msg := NULL;
    BEGIN
        v_run := commit_processing_run(v_process, 'f115 feedable run', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 100)), 'weight', NULL, NULL, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied OR v_run IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 115F1 失败:进入 F1 —— 一批可投料的货必须照旧提交。**这一臂是整份 fixture 的铰链**:只测拒绝的话,一个把所有人都拦住的实现会全绿。实得「%」', COALESCE(v_msg, '(提交返回了 NULL)');
    END IF;

    -- 【它真的过了账,不只是"没报错"】—— 消耗落到批次上、有库存流水、有分录。
    SELECT remaining_qty INTO v_remaining FROM inbound_batches WHERE id = v_ib;
    IF v_remaining <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 115F1 失败:进入 F1 —— 投完 100 之后余量应当是 0,实得 %。**一个"放行但什么都没做"的守卫会让上面那句 IS NULL 通过**,所以这里要看它真的动了账', v_remaining;
    END IF;
    SELECT count(*) INTO v_moves FROM inventory_movements
     WHERE inbound_batch_id = v_ib AND movement_type = 'processing_consume';
    IF v_moves < 1 THEN
        RAISE EXCEPTION 'FIXTURE 115F1 失败:进入 F1 —— 投料应当留下库存流水,实得 % 条', v_moves;
    END IF;
    -- 【这里【不】断言分录 —— 写下来免得下一个人"补上"它】
    -- 实测:`commit_processing_run` 一条分录都不写。成本是 `allocate_processing_costs`
    -- 后面才摊、才过账的。这一条本来写的是"应当过账",跑起来红了 ——
    -- **红的是断言,不是系统**,而它红得很好:一条断言错了的臂会在下一次
    -- 真有人改坏提交路径时被当成"又是那条老毛病"。
    SELECT count(*) INTO v_je FROM processing_inputs WHERE run_id = v_run;
    IF v_je <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 115F1 失败:进入 F1 —— 这一炉应当恰好留下 1 条投料腿,实得 %', v_je;
    END IF;

    -- 【拒绝顺序:PROC-1 那一条【先】于本刀这三条】
    -- 这一批货【既】是不许投料的种类,【又】一条安全状态都没记 —— 两个理由都成立。
    -- 必须报 MATERIAL_NOT_PROCESSABLE:种类答不上来就不必问批次,而"这种料根本
    -- 不能加工"是一个更靠前、也更便宜的答复。**把新检查插到它前面,这一臂会红。**
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ115-IBNO', v_matNo, v_sup, 50, 50, 'kg', v_process - 1, 'other', 'fixture 115 自带数据') RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, v_ccy, NULL, 'f115 price');
    v_denied := false; v_msg := NULL;
    BEGIN
        v_run := commit_processing_run(v_process, 'f115 order', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 50)),
            jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 50)), 'weight', NULL, NULL, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%MATERIAL_NOT_PROCESSABLE%' THEN
        RAISE EXCEPTION 'FIXTURE 115F1 失败:进入 F1 —— 这一批【两个理由都成立】(种类不许投料 + 一条安全状态都没记),而必须报靠前的那一条 MATERIAL_NOT_PROCESSABLE。实得 denied=%、msg=「%」', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;

    -- ══════════ F2 · D1 的三条拒绝,一臂一条,按码 ══════════════════════════
    RAISE NOTICE 'fixture 115 · 进入 F2';

    -- (a) 一条安全状态都没记 —— 【缺席】
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ115-IB2A', v_mat, v_sup, 100, 100, 'kg', v_process - 1, 'other', 'fixture 115 自带数据') RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, v_ccy, NULL, 'f115 price');
    v_denied := false; v_msg := NULL;
    BEGIN
        v_run := commit_processing_run(v_process, 'f115 no state', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
            jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 100)), 'weight', NULL, NULL, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%INPUT_SAFETY_STATE_NOT_RECORDED%' THEN
        RAISE EXCEPTION 'FIXTURE 115F2a 失败:进入 F2(a)—— 一条安全状态都没记的货必须按 INPUT_SAFETY_STATE_NOT_RECORDED 拒。**缺席与坏值是两条不同的拒绝**(D1):这一条的下一步是"去把它记下来",另一条是"去处理那批货"。实得 denied=%、msg=「%」', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;
    -- 【它【不能】报成坏值那一条】—— 合并两个码正是这一臂在防的事。
    -- 【PROC-SUPPORT-1:坏值那一条码现在叫 _NOT_ACCEPTED】工序必填之后,
    -- 受理由 operation_type_safety_states 回答,_NOT_FEEDABLE 那一支到不了了。
    IF v_msg LIKE '%INPUT_SAFETY_STATE_NOT_ACCEPTED%' THEN
        RAISE EXCEPTION 'FIXTURE 115F2a 失败:进入 F2(a)—— 缺席被报成了【坏值】那一条码。两者共用一个码,屏幕上就分不出"没人记过"与"记过、是坏的",而它们的下一步动作不同';
    END IF;

    -- (b) 记了,但那一条不可投料 —— 【坏值】
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib, 'water_exposed');
    v_denied := false; v_msg := NULL;
    BEGIN
        v_run := commit_processing_run(v_process, 'f115 bad state', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
            jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 100)), 'weight', NULL, NULL, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%INPUT_SAFETY_STATE_NOT_ACCEPTED%' THEN
        RAISE EXCEPTION 'FIXTURE 115F2b 失败:进入 F2(b)—— 带着不可投料状态的货必须按名拒。【PROC-SUPPORT-1 之后这条码从 _NOT_FEEDABLE 变成了 _NOT_ACCEPTED,而这一臂的【主语没变】】:工序在提交时已经必填,于是"这一批能不能投"的权威从 inbound_safety_states.may_be_fed(能不能投给【任何】工序)换成了 operation_type_safety_states(【这一道】工序受不受理)。人工拆解不受理"进过水"。实得 denied=%、msg=「%」', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;
    -- 【D6/N36:消息里要有那一条状态的【名字】,两种语言都要】
    -- 只报一个码,人得自己去翻是哪一条;而这一批身上可以同时挂着好几条。
    IF v_msg NOT LIKE '%进过水%' OR v_msg NOT LIKE '%Water-exposed%' THEN
        RAISE EXCEPTION 'FIXTURE 115F2b 失败:进入 F2(b)—— 拒绝消息里要点名那一条状态,而且【中英各带一份】(句子由 app 按读者的语言挑一份;把库里存的值原样塞进句子会出现英文里夹中文,AUDEL-3 实测过)。实得「%」', v_msg;
    END IF;

    -- (c) 确定度记成了一个不可投料的值 —— 而安全状态是干净的
    DELETE FROM inbound_batch_safety_states WHERE inbound_batch_id = v_ib;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib, 'discharged_verified');
    UPDATE inbound_batches SET chemistry_certainty_code = 'unknown_pending' WHERE id = v_ib;
    v_denied := false; v_msg := NULL;
    BEGIN
        v_run := commit_processing_run(v_process, 'f115 bad certainty', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
            jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 100)), 'weight', NULL, NULL, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%INPUT_CHEMISTRY_NOT_FEEDABLE%' THEN
        RAISE EXCEPTION 'FIXTURE 115F2c 失败:进入 F2(c)—— 确定度记成「待识别」的货必须按 INPUT_CHEMISTRY_NOT_FEEDABLE 拒,实得 denied=%、msg=「%」', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;

    -- 【D3:确定度【没记】必须【放行】—— 与上面那一条【故意】不对称】
    -- 这一臂是本刀最容易被"修"掉的地方:下一个人看见"坏值拒、缺席放"会觉得
    -- 不一致。理由在守卫的注释里(防火 vs 防算错),而这一臂是它的行为证明:
    -- **改成"缺席也拒",线上 23 批货会全部压在一家外部化验所后面。**
    UPDATE inbound_batches SET chemistry_certainty_code = NULL WHERE id = v_ib;
    v_denied := false; v_msg := NULL;
    BEGIN
        v_run := commit_processing_run(v_process, 'f115 no certainty is fine', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 100)), 'weight', NULL, NULL, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied OR v_run IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 115F2c 失败:进入 F2(c)—— 【没有记过确定度】的货必须照样投得进去。这与"安全状态缺席要拒"是【刻意的不对称】:安全状态防起火,确定度防算错,而算错由后面的化验回答,不靠停线回答。实得「%」', COALESCE(v_msg, '(提交返回了 NULL)');
    END IF;

    -- ══════════ F3 · D2 合取,两个方向 ══════════════════════════════════════
    RAISE NOTICE 'fixture 115 · 进入 F3';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ115-IB3', v_mat, v_sup, 100, 100, 'kg', v_process - 1, 'other', 'fixture 115 自带数据') RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, v_ccy, NULL, 'f115 price');
    -- 一条【可投料】+ 两条【不可投料】。合取:一条坏的就拒。
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib, 'discharged_verified'), (v_ib, 'water_exposed'), (v_ib, 'swollen_leaking');
    v_denied := false; v_msg := NULL;
    BEGIN
        v_run := commit_processing_run(v_process, 'f115 conjunctive', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
            jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 100)), 'weight', NULL, NULL, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%INPUT_SAFETY_STATE_NOT_ACCEPTED%' THEN
        RAISE EXCEPTION 'FIXTURE 115F3 失败:进入 F3 —— 【合取】:一批已放电的货【同时也进过水】,那它就是进过水的,放电不能把水抵消掉。一个"只要有一条被受理就放行"的实现在这里会通过。【PROC-SUPPORT-1:码从 _NOT_FEEDABLE 变成 _NOT_ACCEPTED,而合取这条不变式一个字没松】—— 它现在由 operation_type_safety_states 那一支保证,而那一支同样是"有一条不被受理就拒,并且一次点完"。实得 denied=%、msg=「%」', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;
    -- 【两条坏的【都】要点名 —— 否则人得跑第二趟】
    -- 清掉"进过水"再来,又撞上"鼓包漏液",而第二次本来可以在第一次就知道。
    IF v_msg NOT LIKE '%进过水%' OR v_msg NOT LIKE '%鼓包或漏液%' THEN
        RAISE EXCEPTION 'FIXTURE 115F3 失败:进入 F3 —— 两条不可投料的状态【都】要出现在消息里,让人一趟清完。只报第一条的实现会让人清掉一条再撞上下一条。实得「%」', v_msg;
    END IF;
    -- 【反面:全部可投料 → 过】少了这一半,一个"有两条以上就拒"的实现也能绿。
    DELETE FROM inbound_batch_safety_states
     WHERE inbound_batch_id = v_ib AND safety_state_code IN ('water_exposed','swollen_leaking');
    v_denied := false; v_msg := NULL;
    BEGIN
        v_run := commit_processing_run(v_process, 'f115 all feedable', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 100)), 'weight', NULL, NULL, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied OR v_run IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 115F3 失败:进入 F3 —— 全部可投料的那一批必须走得通(合取的另一半)。实得「%」', COALESCE(v_msg, '(提交返回了 NULL)');
    END IF;

    -- ══════════ F4 · D4:字典行被【停用】,已贴着它的货照样被拒 ══════════════
    RAISE NOTICE 'fixture 115 · 进入 F4';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ115-IB4', v_mat, v_sup, 100, 100, 'kg', v_process - 1, 'other', 'fixture 115 自带数据') RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, v_ccy, NULL, 'f115 price');
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib, 'water_exposed');
    -- 【把那一行停用】—— 这是一个看起来很轻的动作。
    UPDATE inbound_safety_states SET is_active = false WHERE code = 'water_exposed';
    v_denied := false; v_msg := NULL;
    BEGIN
        v_run := commit_processing_run(v_process, 'f115 deactivated still blocks', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
            jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 100)), 'weight', NULL, NULL, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%INPUT_SAFETY_STATE_NOT_ACCEPTED%' THEN
        RAISE EXCEPTION 'FIXTURE 115F4 失败:进入 F4 —— 【停用一个取值不等于撤回一条规则】。那批货进过水这件事,不会因为字典行被停用而改变。一个顺手 `AND d.is_active` 的实现在这里会放行,而那就是一条【无痕迹、且一次性对所有批次生效】的释放路径。实得 denied=%、msg=「%」', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;
    -- ════════════════════════════════════════════════════════════════════════
    -- 【真正该用的那个动词 —— ★ PROC-SUPPORT-1 之后它【换了一张表】★】
    -- 【这一半是 D4 的另一面,而且它证明规则是【现读】的】同一笔事务里改一行字典,
    -- 结论当场就动。少了它,"守卫不读 is_active" 会被读成"守卫什么都不读"。
    --
    -- ★【为什么不再是 UPDATE inbound_safety_states SET may_be_fed = true】★
    -- 工序在提交时已经必填,于是 guard_processing_input 里 `v_op IS NULL` 那一支
    -- **再也到不了** —— may_be_fed 在 PROC-SUPPORT-1 失去了它最后一个消费者。
    -- 照原样留着这一句,这一臂会【对着一条不再生效的规则变绿】,
    -- 而那正是本仓库反复付账的那一种 fixture。
    -- **撤规则的动词现在是:给这道工序补一行受理。** 事实(那批货进过水)照样不动。
    -- ════════════════════════════════════════════════════════════════════════
    UPDATE inbound_safety_states SET is_active = true WHERE code = 'water_exposed';
    INSERT INTO operation_type_safety_states (operation_type_code, safety_state_code, resolves, notes)
    VALUES ('manual_disassembly', 'water_exposed', false, 'fixture 115 F4:撤规则,留事实');
    v_denied := false; v_msg := NULL;
    BEGIN
        v_run := commit_processing_run(v_process, 'f115 rule withdrawn by may_be_fed', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 100)), 'weight', NULL, NULL, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied OR v_run IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 115F4 失败:进入 F4 —— 给这道工序补上一行受理之后,那一批必须投得进去。**两个动词,谁也替不了谁**:补一行 operation_type_safety_states 是【撤规则】(事实还留着,那一行 water_exposed 一个字没动),is_active 是【停选单】。实得「%」', COALESCE(v_msg, '(提交返回了 NULL)');
    END IF;
    -- 那条状态行【还在】—— 撤的是规则,不是事实。
    IF NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states
                    WHERE inbound_batch_id = v_ib AND safety_state_code = 'water_exposed') THEN
        RAISE EXCEPTION 'FIXTURE 115F4 失败:进入 F4 —— 撤回规则不该抹掉事实:那批货"进过水"这一行必须还在';
    END IF;
    DELETE FROM operation_type_safety_states
     WHERE operation_type_code = 'manual_disassembly' AND safety_state_code = 'water_exposed';

    -- ══════════ F5 · D5:可加工、但没有状态轴的种类,照样投得进去 ════════════
    RAISE NOTICE 'fixture 115 · 进入 F5';
    -- 【这一臂最容易被漏掉,而把适用性写反正是本刀最可能的那个缺陷】
    -- 一个"可加工就必须有安全状态"的守卫在这里会红 —— 而它在别处【全绿】,
    -- 因为今天几乎所有可加工的料都是电池料。ewaste 是线上真实存在的反例。
    IF (SELECT has_condition_axes FROM material_kinds WHERE code = 'ewaste') IS NOT FALSE
       OR (SELECT may_ever_be_processed FROM material_kinds WHERE code = 'ewaste') IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 115F5 前置失败:本臂要的是一个【可加工、但没有状态轴】的种类。ewaste 本应如此(may_ever_be_processed=true, has_condition_axes=false)—— 若这一行变了,换一个符合条件的种类,不要把这一臂删掉:它挡的是"把适用性写反"';
    END IF;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ115-IB5', v_matEw, v_sup, 100, 100, 'kg', v_process - 1, 'other', 'fixture 115 自带数据') RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, v_ccy, NULL, 'f115 price');
    -- 【一条安全状态都不给】—— 它身上根本没有这回事。
    v_denied := false; v_msg := NULL;
    BEGIN
        v_run := commit_processing_run(v_process, 'f115 no axes no problem', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 100)), 'weight', NULL, NULL, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied OR v_run IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 115F5 失败:进入 F5 —— 一个【可加工、但没有状态轴】的种类,不带任何安全状态也必须投得进去。**绝不能因为"它没有安全状态"而被拦住** —— 它身上根本没有这回事。实得「%」', COALESCE(v_msg, '(提交返回了 NULL)');
    END IF;
    -- 【而且它确实一条都没有】——若哪天有人给它插了一条,这一臂就不再证明原来那件事。
    IF EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE inbound_batch_id = v_ib) THEN
        RAISE EXCEPTION 'FIXTURE 115F5 前置失败:进入 F5 —— 这一批本应【一条安全状态都没有】,那才是这一臂要证明的东西';
    END IF;
END $$;
ROLLBACK;
