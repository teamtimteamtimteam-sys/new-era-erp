-- 157 第四条拒绝,而它【不许】说"这个东西不许卖" —— PROC-WIRE-1A 的工序投料指定
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- 【为什么被测的一定是【正极片】】这条轴唯一非冗余的活儿,就是【形态可售、
-- 却又要往下走】的那些。电芯 / 已开壳电芯 / 负极片 PROC-BUILD-1 已经按形态
-- 拒掉了,对它们本轴一点用都没有。cathode_sheet 的种子注释自己写着
-- 「它可以进极片粉料线,也可以卖」——【同一个形态,两种角色】。
-- **拿一个本来就不可售的形态来测这条轴,会因为错的理由通过。**
--
-- 【每一臂钉什么】
-- G1 前提 + 对照:正极片 may_be_sold = true,而且【未指定时真的卖得掉】。
--    少了它,一个"把所有人都拦住"的实现会全绿(fixture 112 F4 / 154 F1 同一条)。
-- G2 指定之后被拒,按名。★ 先证明注入确实改变了东西(用途真的变了)。
-- G3 **释放之后又卖得掉** —— 可释放性【就是】它与"法律不许卖"的分界。
--    一个把它实现成"永久不可售"的版本在这里红。
-- G4 **拒绝的措辞不许说"这个东西不许卖"** —— 这一臂直接断言:被拒的那一刻,
--    这个形态的 may_be_sold 仍然是 true。那句话如果被说出口,就是假话。
-- G5 四条拒绝互不相同 —— 不可售 / 判断不了 / 库存不够 / 已许给工序。
-- G6 批次级的两层入口(预留 · sales_records)逐个测。
--    **报价行与订单行拿的是【物料】,批次级的指定在那两层结构上就看不见** ——
--    所以这里【只有两层】,而那不是漏测:它是这条轴是批次级的直接后果。
-- G7 权限:设定/释放要的是【工序】编辑权,不是销售权。
-- G8 规则读的是【字典那一列】,不是写死的码 —— 加一种不可售用途不必改代码。
--
-- 日期:自带。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    v_weak uuid := gen_random_uuid();
    r_all uuid; r_weak uuid; v_ccy text; v_cust uuid;
    v_mat uuid; v_mat_ano uuid; v_ob uuid; v_line uuid; v_so uuid;
    v_d date := DATE '2027-08-04';
    v_denied boolean; v_msg text; v_sale jsonb;
    v_m_earmark text; v_m_notsaleable text; v_m_notset text; v_m_stock text;
    v_n int;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-157', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO customers (code, legal_name, country, status)
    VALUES ('ZZ157-C', 'f157 customer', 'SG', 'active') RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ157-CAT', 'f157 cathode sheet', 'battery_material', true, 'cathode_sheet', 'end_of_life')
    RETURNING id INTO v_mat;

    -- ══════════ G1 · 前提 + 对照:正极片,未指定,【卖得掉】 ══════════
    RAISE NOTICE 'fixture 157 · 进入 G1';
    IF (SELECT may_be_sold FROM material_forms WHERE code = 'cathode_sheet') IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 157G1 前置失败:本份 fixture 的整个意义在于【一个可售的形态】。正极片若变成不可售,这条轴就测不出东西来 —— 换一个 may_be_sold 为真、且会进下一道工序的形态,不要把这一臂删掉';
    END IF;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, unit, output_date, state)
    VALUES ('ZZ157-OB', v_mat, 100, 100, 'kg', v_d, '库存中') RETURNING id INTO v_ob;
    IF (SELECT purpose_code FROM output_batches WHERE id = v_ob) <> 'saleable_stock' THEN
        RAISE EXCEPTION 'FIXTURE 157G1 前置失败:新建批次的默认用途必须是【可售库存】—— 那是现状,不是一个猜测';
    END IF;
    -- 【"必须成交"的臂要自己接住异常】record_output_sale 被拒时是 RAISE,不是返回空 ——
    -- 只写 IF v_sale IS NULL 那一句【永远不会执行】,而 fixture 会以一条原始报错
    -- 死掉:门照样是红的,但它说不出【是哪一臂、为什么】。实测撞过(注入 I8)。
    v_denied := false; v_msg := NULL;
    BEGIN v_sale := record_output_sale(v_ob, 10, 5, v_ccy, NULL, v_cust, v_d, 'f157 control', NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied OR v_sale IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 157G1 失败:未指定的正极片必须卖得掉。**这是整份 fixture 的铰链** —— 没有它,一个"全拦"的实现会全绿。实得「%」', COALESCE(v_msg, '(返回空)');
    END IF;

    -- ══════════ G2 · 指定之后被拒 ══════════
    RAISE NOTICE 'fixture 157 · 进入 G2';
    PERFORM set_output_batch_purpose(v_ob, 'process_feed');
    -- 【先证明注入确实改变了东西】
    IF (SELECT purpose_code FROM output_batches WHERE id = v_ob) <> 'process_feed' THEN
        RAISE EXCEPTION 'FIXTURE 157G2 前置失败:指定没有落到那一行上 —— 后面每一句断言都是空的';
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_output_sale(v_ob, 10, 5, v_ccy, NULL, v_cust, v_d, 'f157 earmarked', NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 157G2 失败:被指定为下游工序投料的批次【不是可售库存】,这一笔必须被拒';
    END IF;
    IF v_msg NOT LIKE 'SALE_BATCH_EARMARKED|%' THEN
        RAISE EXCEPTION 'FIXTURE 157G2 失败:必须按名拒,实得「%」', v_msg;
    END IF;
    v_m_earmark := v_msg;

    -- ══════════ G3 · 释放之后又卖得掉 ★ 与"法律不许卖"的分界 ══════════
    RAISE NOTICE 'fixture 157 · 进入 G3';
    PERFORM set_output_batch_purpose(v_ob, 'saleable_stock');
    v_denied := false; v_msg := NULL;
    BEGIN v_sale := record_output_sale(v_ob, 10, 5, v_ccy, NULL, v_cust, v_d, 'f157 released', NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied OR v_sale IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 157G3 失败:释放指定之后必须又卖得掉。**可释放性就是这条轴与形态那条的分界** —— 形态那条没有旁路,这一条有。把它实现成"永久不可售"的版本在这里红。实得「%」', COALESCE(v_msg, '(返回空)');
    END IF;
    PERFORM set_output_batch_purpose(v_ob, 'process_feed');

    -- ══════════ G4 · 那句话不许被说出口 ══════════
    RAISE NOTICE 'fixture 157 · 进入 G4';
    -- 被拒的这一刻,这个形态【仍然是可售的】。所以任何"这个东西不许卖"的措辞
    -- 都是【假话】,而一条说假话的拒绝会教人去改一个根本没错的地方。
    IF (SELECT mf.may_be_sold FROM materials m JOIN material_forms mf ON mf.code = m.form_code
         WHERE m.id = v_mat) IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 157G4 失败:被本轴拒掉的这一批,它的形态必须仍然是【可售】的 —— 那正是这条拒绝不许说"这个东西不许卖"的原因';
    END IF;
    IF v_m_earmark LIKE 'SALE_FORM_NOT_SALEABLE%' THEN
        RAISE EXCEPTION 'FIXTURE 157G4 失败:这条拒绝【不许】复用"法律不许卖"那条码 —— 对正极片那是假话';
    END IF;

    -- ══════════ G5 · 四条拒绝互不相同 ══════════
    RAISE NOTICE 'fixture 157 · 进入 G5';
    -- 不可售:负极片(R5 点名)
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ157-ANO', 'f157 anode', 'battery_material', true, 'anode_sheet', 'end_of_life')
    RETURNING id INTO v_mat_ano;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, unit, output_date, state)
    VALUES ('ZZ157-OBA', v_mat_ano, 100, 100, 'kg', v_d, '库存中') RETURNING id INTO v_line;
    BEGIN PERFORM record_output_sale(v_line, 1, 5, v_ccy, NULL, v_cust, v_d, 'x', NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_m_notsaleable := SQLERRM; END;
    -- 库存不够:拿【可售且未指定】的另一批来撞,才撞得到库存那条
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, unit, output_date, state)
    VALUES ('ZZ157-OBS', v_mat, 10, 10, 'kg', v_d, '库存中') RETURNING id INTO v_line;
    BEGIN PERFORM record_output_sale(v_line, 999999, 5, v_ccy, NULL, v_cust, v_d, 'x', NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_m_stock := SQLERRM; END;
    -- 【三条都必须真的发生过】少了这一句,一条没被触发的拒绝会留下 NULL,
    -- 而 NULL 参与的比较结果是 NULL —— 下面那个 IF 于是【永远不成立】,
    -- 整臂静静地通过。这正是 FIN-30 第三臂空转过的那个病。
    IF v_m_earmark IS NULL OR v_m_notsaleable IS NULL OR v_m_stock IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 157G5 失败:三条拒绝必须都【真的被触发过】才谈得上比较。已许给工序「%」/ 不可售「%」/ 库存「%」—— 其中为空的那一条根本没有发生',
            COALESCE(v_m_earmark,'(没有发生)'), COALESCE(v_m_notsaleable,'(没有发生)'), COALESCE(v_m_stock,'(没有发生)');
    END IF;
    IF split_part(v_m_earmark,'|',1) = split_part(v_m_notsaleable,'|',1)
       OR split_part(v_m_earmark,'|',1) = split_part(v_m_stock,'|',1)
       OR split_part(v_m_notsaleable,'|',1) = split_part(v_m_stock,'|',1) THEN
        RAISE EXCEPTION 'FIXTURE 157G5 失败:三条码必须互不相同。已许给工序「%」/ 不可售「%」/ 库存「%」',
            split_part(v_m_earmark,'|',1), split_part(v_m_notsaleable,'|',1), split_part(v_m_stock,'|',1);
    END IF;

    -- ══════════ G6 · 批次级的两层入口 ══════════
    RAISE NOTICE 'fixture 157 · 进入 G6';
    -- ① 预留
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate, status)
    VALUES ('ZZ157-SO', v_cust, v_d, v_ccy, 1, 'draft') RETURNING id INTO v_so;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (v_so, 1, v_mat, 10, 5) RETURNING id INTO v_line;
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO sales_order_reservations (sales_order_line_id, output_batch_id, qty)
        VALUES (v_line, v_ob, 1);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'SALE_BATCH_EARMARKED|%' THEN
        RAISE EXCEPTION 'FIXTURE 157G6① 失败:【预留】必须拒 —— 圈定一批货是准备发它,而这一批已经许给了产线。实得「%」', COALESCE(v_msg,'(通过了)');
    END IF;
    -- ② 出货与直销共用的那个门:sales_records
    SELECT count(*) INTO v_n FROM information_schema.triggers
     WHERE trigger_schema = 'public' AND event_object_table = 'sales_records'
       AND trigger_name = 'trg_sales_records_form_saleable';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 157G6② 失败:sales_records 上必须有那一个门 —— record_output_sale 与 ship_order 共用它';
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price, currency, fx_rate, amount_base, sale_date)
        VALUES (v_ob, v_cust, 1, 5, v_ccy, 1, 5, v_d);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'SALE_BATCH_EARMARKED|%' THEN
        RAISE EXCEPTION 'FIXTURE 157G6② 失败:直插 sales_records 也必须被拦 —— 触发器对每一个写入者成立,包括直连 psql。实得「%」', COALESCE(v_msg,'(通过了)');
    END IF;

    -- ══════════ G7 · 权限:工序编辑权,不是销售权 ══════════
    RAISE NOTICE 'fixture 157 · 进入 G7';
    -- 一个【有销售/产出权、但没有工序编辑权】的人:改不动这条轴。
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-157-weak', 'f', 'f', true) RETURNING id INTO r_weak;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_weak, code FROM permissions WHERE code <> 'module.processing.edit';
    INSERT INTO user_roles (user_id, role_id) VALUES (v_weak, r_weak);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_weak), true);
    -- 【先证明注入确实改变了东西】这个人确实没有那条权限,却确实有产出编辑权。
    IF has_permission('module.processing.edit') OR NOT has_permission('module.output.edit') THEN
        RAISE EXCEPTION 'FIXTURE 157G7 前置失败:本臂要的是一个【有产出编辑权、没有工序编辑权】的人 —— 否则它测不出"这件事挂在哪条权限上"';
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM set_output_batch_purpose(v_ob, 'saleable_stock');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'PERMISSION_DENIED|module.processing.edit%' THEN
        RAISE EXCEPTION 'FIXTURE 157G7 失败:把一批货许给产线是一个【工序】决定 —— 光有产出编辑权不该改得动它。实得「%」', COALESCE(v_msg,'(通过了)');
    END IF;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ G8 · 规则读的是字典那一列,不是写死的码 ══════════
    RAISE NOTICE 'fixture 157 · 进入 G8';
    -- 加一种【新的】不可售用途,不改一行代码,拒绝必须照样发生。
    INSERT INTO output_batch_purposes (code, name_en, name_zh, is_saleable_stock, sort_order, notes)
    VALUES ('zz157_quarantine', 'f157 held', 'f157 暂扣', false, 99, 'fixture 157 G8');
    PERFORM set_output_batch_purpose(v_ob, 'zz157_quarantine');
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_output_sale(v_ob, 1, 5, v_ccy, NULL, v_cust, v_d, 'f157 new purpose', NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'SALE_BATCH_EARMARKED|%' THEN
        RAISE EXCEPTION 'FIXTURE 157G8 失败:第四条拒绝必须读【is_saleable_stock 那一列】,不是写死的 process_feed。一个把码写死的实现在这里绿不了 —— 而那正是"加一种是加一行"这句话的全部内容。实得「%」', COALESCE(v_msg,'(通过了)');
    END IF;
    -- 反过来:一种【可售】的新用途不该拦
    INSERT INTO output_batch_purposes (code, name_en, name_zh, is_saleable_stock, sort_order, notes)
    VALUES ('zz157_ok', 'f157 ok', 'f157 可售', true, 98, 'fixture 157 G8 对照');
    PERFORM set_output_batch_purpose(v_ob, 'zz157_ok');
    v_denied := false; v_msg := NULL;
    BEGIN v_sale := record_output_sale(v_ob, 1, 5, v_ccy, NULL, v_cust, v_d, 'f157 new saleable purpose', NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied OR v_sale IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 157G8 失败:一种【可售】的用途不该被拦 —— 否则这条规则读的不是那一列,而是"有没有被指定过"。实得「%」', COALESCE(v_msg, '(返回空)');
    END IF;
END $$;
ROLLBACK;
