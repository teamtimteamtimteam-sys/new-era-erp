-- 184 一张收货必须说得出它从哪来 —— 采购行或字典理由,永远不许两者皆无(RECV-SOURCE-1)
--
-- 【它守的是什么】审计轨迹的第一环:这批料从哪来。缺陷不是"没有 PO 的收货"
-- (退货/样品/盘盈都是正当的无单收货),而是【"本来就不该有 PO"与"没人填"
-- 在数据里一模一样】。R1:至少其一,永不两者皆无;R3:other 必须带书面说明;
-- R4:8 张历史行不回填、不冻结;3e:事后补的理由必须带谁、什么时候。
--
-- 【三条建批路径,三条都注】direct INSERT(postgres 直插 —— rolbypassrls 那条路,
-- RPC 够不着它,这正是规则放在触发器里的理由)、create_inbound_batch、
-- receive_inbound_batch_against_po。一条路上有效、另一条路上无效的规则不是规则。
--
-- 【E 臂是本 fixture 的要点,与 fixture 172 E 臂同形】历史行(两者皆无)必须
-- 【仍然改得动】—— 这正是不用 CHECK … NOT VALID 买到的东西(materials 那 7 行
-- 冻着的账)。只钉"新行被拒"的话,一个 NOT VALID 的实现也能通过;
-- 只有"历史行照常改"这一臂能把它拒之门外。历史态用 DISABLE TRIGGER 制造
-- (fixture 172 的先例:模拟"这一行早于本刀"),整份 fixture 最终 ROLLBACK。
--
-- 【每一臂先证注入改变了什么】拒绝臂断言行数没长;控制臂断言行真的建出来了。
-- 日期无关。自带数据(README 第 2 条)。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    v_user2 uuid := gen_random_uuid();
    r_all uuid;
    v_mat uuid; v_sup uuid;
    v_po uuid; v_line uuid;
    b_ctrl_po uuid; b_ctrl_reason uuid; b_other uuid; b_hist uuid;
    v_n int; v_msg text; v_denied boolean;
    v_by uuid; v_at timestamptz; v_code text; v_note text;
    d date := CURRENT_DATE;
BEGIN
    -- ══════════ 前提 ═════════════════════════════════════════════════════════
    -- recorded_by 有 FK 指向 auth.users(先例:fixtures 126/127/180)—— 两个人都要真的存在
    INSERT INTO auth.users (id) VALUES (v_user), (v_user2);
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-184', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all), (v_user2, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ184-M', 'fixture 184 material', 'battery_material', true, 'black_mass', 'end_of_life', 'kg')
    RETURNING id INTO v_mat;
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('ZZ184-S', 'fixture 184 supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status)
    VALUES ('ZZ184-PO', v_sup, d, 'USD', 1.3, 'receiving', 'approved') RETURNING id INTO v_po;
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
    VALUES (v_po, 1, v_mat, 1000, 'kg') RETURNING id INTO v_line;

    -- ══════════ A. 字典本身:4 行、规则列、other 要说明而其余不要 ═══════════════
    SELECT count(*) INTO v_n FROM inbound_source_reasons;
    IF v_n <> 4 THEN
        RAISE EXCEPTION 'FIXTURE 184A 失败:理由字典引导应为 4 行(return/sample/stocktake_gain/other),实得 %', v_n;
    END IF;
    IF NOT (SELECT requires_explanation FROM inbound_source_reasons WHERE code = 'other') THEN
        RAISE EXCEPTION 'FIXTURE 184A 失败:other 必须 requires_explanation(R3)';
    END IF;
    SELECT count(*) INTO v_n FROM inbound_source_reasons WHERE NOT requires_explanation;
    IF v_n <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 184A 失败:另外三个理由不该要求说明,实得 % 个不要求', v_n;
    END IF;

    -- ══════════ B. 两者皆无 → 三条路各自被【按名】拒 ═══════════════════════════
    -- B1 直插(postgres —— RLS 拦不住它,这一臂证明触发器拦得住)
    SELECT count(*) INTO v_n FROM inbound_batches;
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
        VALUES ('ZZ184-B1', v_mat, v_sup, 10, 10, 'kg', d);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE '%RECEIPT_SOURCE_REQUIRED%' THEN
        RAISE EXCEPTION 'FIXTURE 184B1 失败:直插一张两者皆无的收货应按名拒(RECEIPT_SOURCE_REQUIRED),实得:%',
            CASE WHEN v_denied THEN v_msg ELSE '(成功了 —— postgres 那条路没有被守住)' END;
    END IF;
    IF (SELECT count(*) FROM inbound_batches) <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 184B1 失败:拒绝之后不该多出行来';
    END IF;

    -- B2 create_inbound_batch
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM create_inbound_batch(v_mat, v_sup, 10, 'kg', d);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE '%RECEIPT_SOURCE_REQUIRED%' THEN
        RAISE EXCEPTION 'FIXTURE 184B2 失败:create_inbound_batch 两者皆无应按名拒,实得:%',
            CASE WHEN v_denied THEN v_msg ELSE '(成功了)' END;
    END IF;

    -- B3 receive_inbound_batch_against_po(名字带 PO,但 p_purchase_order_id 可空 ——
    --    它也建无单批,所以它也要被守住;一条路上有效的规则不是规则)
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM receive_inbound_batch_against_po(v_mat, v_sup, 10, d);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE '%RECEIPT_SOURCE_REQUIRED%' THEN
        RAISE EXCEPTION 'FIXTURE 184B3 失败:receive_inbound_batch_against_po 两者皆无应按名拒,实得:%',
            CASE WHEN v_denied THEN v_msg ELSE '(成功了)' END;
    END IF;

    -- ══════════ C. other 没有句子 → 拒;带句子 → 过(R3,读的是规则列)═══════════
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM create_inbound_batch(v_mat, v_sup, 10, 'kg', d,
              p_source_reason_code => 'other');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE '%SOURCE_REASON_EXPLANATION_REQUIRED%' THEN
        RAISE EXCEPTION 'FIXTURE 184C 失败:other 不带说明应按名拒(SOURCE_REASON_EXPLANATION_REQUIRED),实得:%',
            CASE WHEN v_denied THEN v_msg ELSE '(成功了 —— 一个没有句子的 other 什么都没说)' END;
    END IF;
    -- 【空白句子 = 没有句子】全空格的说明不算说了话
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM create_inbound_batch(v_mat, v_sup, 10, 'kg', d,
              p_source_reason_code => 'other', p_source_reason_note => '   ');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE '%SOURCE_REASON_EXPLANATION_REQUIRED%' THEN
        RAISE EXCEPTION 'FIXTURE 184C 失败:全空格的说明应等同于没有说明,实得:%',
            CASE WHEN v_denied THEN v_msg ELSE '(成功了)' END;
    END IF;
    -- 带句子的 other 必须过 —— 拒绝臂的对照,否则上面两条可能只是"什么都被拒"
    b_other := (create_inbound_batch(v_mat, v_sup, 10, 'kg', d,
                    p_source_reason_code => 'other',
                    p_source_reason_note => 'fixture 184:一句真的说明') ->> 'batch_id')::uuid;
    IF b_other IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 184C 失败:带说明的 other 应当成功';
    END IF;

    -- ══════════ D. 两个控制:有采购行的过,有理由的过(R1 是"至少其一")═════════
    b_ctrl_po := (receive_inbound_batch_against_po(v_mat, v_sup, 100, d, NULL, v_po, v_line)
                  ->> 'batch_id')::uuid;
    IF b_ctrl_po IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 184D 失败:对着采购行的收货应当成功(控制臂)';
    END IF;
    b_ctrl_reason := (create_inbound_batch(v_mat, v_sup, 20, 'kg', d,
                          p_source_reason_code => 'stocktake_gain') ->> 'batch_id')::uuid;
    IF b_ctrl_reason IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 184D 失败:带理由的无单收货应当成功(控制臂)';
    END IF;
    -- 收货当场给的理由:出处列必须是 NULL(= 当场说的,不是事后补的;R4 的区别)
    SELECT source_reason_recorded_by, source_reason_recorded_at INTO v_by, v_at
      FROM inbound_batches WHERE id = b_ctrl_reason;
    IF v_by IS NOT NULL OR v_at IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 184D 失败:收货当场给的理由不该带 recorded_by/at(那两列的意思是【事后】补记)';
    END IF;

    -- ══════════ H. 只挂单头不挂明细行 → 自己的具名拒绝(A3)═══════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
                                     unit, arrival_date, purchase_order_id)
        VALUES ('ZZ184-H', v_mat, v_sup, 10, 10, 'kg', d, v_po);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'PO_HEADER_WITHOUT_LINE|%' THEN
        RAISE EXCEPTION 'FIXTURE 184H 失败:只挂单头应按名拒(PO_HEADER_WITHOUT_LINE),且不与来源规则混同,实得:%',
            CASE WHEN v_denied THEN v_msg ELSE '(成功了)' END;
    END IF;

    -- ══════════ I. 当场的理由不许冒充事后记录 ═══════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
                                     unit, arrival_date, source_reason_code,
                                     source_reason_recorded_by, source_reason_recorded_at)
        VALUES ('ZZ184-I', v_mat, v_sup, 10, 10, 'kg', d, 'sample', v_user, now());
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE '%SOURCE_PROVENANCE_NOT_AT_INTAKE%' THEN
        RAISE EXCEPTION 'FIXTURE 184I 失败:INSERT 带 recorded_by/at 应按名拒 —— 放行它,"事后补的"与"当场说的"就分不开了,实得:%',
            CASE WHEN v_denied THEN v_msg ELSE '(成功了)' END;
    END IF;
    -- 同生同灭(pair CHECK):只有其中一个,说不出"谁补的"或"什么时候补的"
    v_denied := false; v_msg := NULL;
    BEGIN
        UPDATE inbound_batches SET source_reason_recorded_by = v_user WHERE id = b_ctrl_reason;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE '%inbound_source_recorded_pair%' THEN
        RAISE EXCEPTION 'FIXTURE 184I 失败:只有 recorded_by 没有 recorded_at 应被 pair 约束拒,实得:%',
            CASE WHEN v_denied THEN v_msg ELSE '(成功了)' END;
    END IF;

    -- ══════════ E. 历史行(两者皆无)活着、改得动、不被谁悄悄填上(R4)═══════════
    -- 与 fixture 172 E 臂同形:先合法建出、再关掉触发器把它变成历史态。
    -- 【先冲掉挂着的延迟触发器事件】否则 ALTER TABLE 报 pending trigger events。
    SET CONSTRAINTS ALL IMMEDIATE;
    ALTER TABLE inbound_batches DISABLE TRIGGER trg_inbound_batches_source_stated;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ184-HIST', v_mat, v_sup, 10, 10, 'kg', d) RETURNING id INTO b_hist;
    ALTER TABLE inbound_batches ENABLE TRIGGER trg_inbound_batches_source_stated;

    -- 【注入先证明了什么】没有 DISABLE 那一下,这张行根本建不出来(B1 刚证过);
    -- 它存在,本身就证明它只可能是"早于本刀"的形状。
    -- 历史行必须仍然改得动 —— NOT VALID 的实现在这里死(materials 那 7 行的账)。
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE inbound_batches SET notes = 'f184 历史行仍然改得动' WHERE id = b_hist;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 184E 失败:一张【本来就两者皆无】的历史行必须仍然改得动(R4:不回填,历史的缺失要活下来;七个函数要 UPDATE 本表),实得拒绝「%」—— 这正是把守卫写成 CHECK … NOT VALID 会造成的后果', v_msg;
    END IF;
    SELECT source_reason_code IS NULL AND purchase_order_line_id IS NULL INTO v_denied
      FROM inbound_batches WHERE id = b_hist;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 184E 失败:历史行的空不该被谁悄悄填上(未说明必须还是未说明)';
    END IF;

    -- ══════════ F. 事后补说明:必须走门、门记下谁与什么时候(3e)═══════════════
    -- F1 注入:直连 UPDATE 给理由、不带出处 → 按名拒(不盖章的断言不许落库)
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE inbound_batches SET source_reason_code = 'return' WHERE id = b_hist;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE '%SOURCE_PROVENANCE_REQUIRED%' THEN
        RAISE EXCEPTION 'FIXTURE 184F 失败:直连 UPDATE 补理由不带出处应按名拒(SOURCE_PROVENANCE_REQUIRED),实得:%',
            CASE WHEN v_denied THEN v_msg ELSE '(成功了 —— 一个没有作者的断言落了库)' END;
    END IF;
    -- F2 注入改变了什么:行还是未说明的
    IF (SELECT source_reason_code FROM inbound_batches WHERE id = b_hist) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 184F 失败:被拒之后理由不该已经写上了';
    END IF;
    -- F3 走门(换一个人补,证明记的是【补的人】,不是建行的人)
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user2), true);
    PERFORM explain_inbound_source(b_hist, 'return', '客户 X 退回的那一批 —— fixture 184');
    SELECT source_reason_code, source_reason_note, source_reason_recorded_by, source_reason_recorded_at
      INTO v_code, v_note, v_by, v_at FROM inbound_batches WHERE id = b_hist;
    IF v_code <> 'return' OR v_by IS DISTINCT FROM v_user2 OR v_at IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 184F 失败:事后补的说明必须记下【谁】(%)与【什么时候】(%),并落下理由(%)',
            COALESCE(v_by::text,'NULL'), COALESCE(v_at::text,'NULL'), COALESCE(v_code,'NULL');
    END IF;
    -- F4 事后补 other 不带句子:同一条 R3,走门也拒
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM explain_inbound_source(b_hist, 'other');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE '%SOURCE_REASON_EXPLANATION_REQUIRED%' THEN
        RAISE EXCEPTION 'FIXTURE 184F 失败:事后补 other 不带说明也应按名拒(R3 不分当场事后),实得:%',
            CASE WHEN v_denied THEN v_msg ELSE '(成功了)' END;
    END IF;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ G. 说明过的不许改回没说明(转移守卫)═══════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        UPDATE inbound_batches
           SET source_reason_code = NULL, source_reason_note = NULL,
               source_reason_recorded_by = NULL, source_reason_recorded_at = NULL
         WHERE id = b_hist;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'RECEIPT_SOURCE_REQUIRED|%' THEN
        RAISE EXCEPTION 'FIXTURE 184G 失败:已说明的收货改回两者皆无应按名拒(RECEIPT_SOURCE_REQUIRED|批号),实得:%',
            CASE WHEN v_denied THEN v_msg ELSE '(成功了 —— 新的缺失被制造出来了)' END;
    END IF;
    IF (SELECT source_reason_code FROM inbound_batches WHERE id = b_hist) IS DISTINCT FROM 'return' THEN
        RAISE EXCEPTION 'FIXTURE 184G 失败:被拒之后原说明不该被动过';
    END IF;

    RAISE NOTICE 'FIXTURE 184 ✓ 全部臂通过(A 字典 / B 三路拒 / C R3 / D 两控制 / H 单头 / I 出处 / E 历史活着 / F 事后盖章 / G 不许清)';
END $$;
ROLLBACK;
