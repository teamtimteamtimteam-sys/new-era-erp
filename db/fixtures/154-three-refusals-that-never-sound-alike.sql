-- 154 三种拒绝,一种都不许长得像另一种 —— PROC-BUILD-1 的可售性(R5)
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- 【每一臂钉什么】
-- F1 前提,先于一切:**正极片【卖得掉】** —— 这是对照臂。少了它,一个
--    "把所有人都拦住"的实现会全绿,而这个仓库为这件事付过账(fixture 112 F4)。
-- F2 R5 的三个不可售形态,【一臂一个,按码断言】:电芯 / 已开壳电芯 / 负极片。
--    三个都测,不抽样 —— 一个"只拦第一个"的实现在抽样下照样绿。
-- F3 **加工产出 + 形态没设 → 拒,而且是【另一条】码**(SALE_FORM_NOT_SET)。
--    这一臂钉的是那条拒绝【不说】"这个东西不许卖" —— 那是另一句话,而且会是假的。
--    ★ 那个行形今天【造不出来】(materials_kind_stated 要求新行必须说种类,
--      而说了种类之后形态要么必填要么必须为空)—— 所以本臂【特意】把那条
--      NOT VALID 的 CHECK 摘掉、复刻线上那八行历史物料的行形、再装回去。
--      这条拒绝真正保护的就是那八行,详见 docs/proc-loss-and-saleability.md。
-- F4 **买进来的料、以及形态没设的料,照旧卖得掉** —— A2 那条刻意的不对称。
--    没有这一臂,一个"NULL 一律拦"的实现会全绿,而它会停掉线上每一笔销售。
-- F4b(fu1)**【不适用】不是【没设】** —— 一个可加工、但【没有状态轴】的种类,
--    它的形态必须为空(那是"不适用"),所以它的加工产出【照旧卖得掉】。
--    线上 ewaste 今天就是这一种,不是假想分支(与 fixture 115 F5 同一个理由)。
-- F5 三种拒绝【互不相同】:不可售 / 判断不了 / 库存不够,三条码三句话。
--    这一臂直接断言三者两两不等 —— 把它们合并过的实现在这里红。
-- F6 四层入口全覆盖:报价行 · 订单行 · 占用 · 出货与直销共用的那个门。
--    **一个只拦三层的实现比不拦更糟,因为它制造信心** —— 所以四层逐个测。
--
-- 日期:自带。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_ccy text;
    v_sup uuid; v_cust uuid;
    v_mat_cat uuid; v_mat_cell uuid; v_mat_decased uuid; v_mat_anode uuid;
    v_mat_noform uuid; v_mat_bought uuid;
    v_ib uuid; v_run uuid;
    v_ob_cat uuid; v_ob_anode uuid; v_ob_noform uuid; v_ob_bought uuid;
    v_q uuid; v_so uuid; v_line uuid;
    v_process date := DATE '2027-07-03';
    v_denied boolean; v_msg text;
    v_msg_notsaleable text; v_msg_notset text; v_msg_stock text;
    v_form text; v_sale jsonb;
    v_codes text[] := ARRAY['loose_cells', 'de_cased_cell', 'anode_sheet'];
    v_code text; v_matx uuid; v_n int;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-154', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ154-S', 'fixture 154 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO customers (code, legal_name, country, status)
    VALUES ('ZZ154-C', 'fixture 154 customer', 'SG', 'active') RETURNING id INTO v_cust;

    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ154-CAT', 'f154 cathode sheet', 'battery_material', true, 'cathode_sheet', 'end_of_life') RETURNING id INTO v_mat_cat;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ154-ANO', 'f154 anode sheet', 'battery_material', true, 'anode_sheet', 'end_of_life') RETURNING id INTO v_mat_anode;
    -- ════════════════════════════════════════════════════════════════════════
    -- 【形态没设】的那一个 —— F3/F4 用它。**它必须被【特意造出来】,而那件事
    -- 本身就是本 fixture 最要紧的一条发现:**
    --
    --   * `materials_kind_stated`(CHECK,NOT VALID)要求新行【必须说出种类】;
    --   * 种类【有】状态轴 → `guard_material_condition_axes` 要求形态【必填】;
    --   * 种类【没有】状态轴 → 同一个守卫要求形态【必须为空】,而那是"不适用"。
    --
    -- 三条合起来:**今天【造不出】一行"说了种类、却没有形态"的物料。**
    -- 于是 SALE_FORM_NOT_SET 这条拒绝真正保护的是【线上那八行前 PROC-2 的历史物料】
    -- —— 它们种类为空、形态为空,而 Tim 裁定的那 11 批产出批就坐在它们身上。
    --
    -- 【所以这里把那条 NOT VALID 的 CHECK 摘掉,复刻那个行形,再装回去】
    -- 这不是绕过判据,这是**注入那个真实存在、但已经不能再被新建的行形**。
    -- 摘掉→复刻→装回,全部在这个会回滚的事务里。
    -- ════════════════════════════════════════════════════════════════════════
    ALTER TABLE materials DROP CONSTRAINT materials_kind_stated;
    INSERT INTO materials (code, name)
    VALUES ('ZZ154-NOF', 'f154 legacy pre-axis material') RETURNING id INTO v_mat_noform;
    ALTER TABLE materials
        ADD CONSTRAINT materials_kind_stated
        CHECK (kind_code IS NOT NULL AND may_be_processed IS NOT NULL) NOT VALID;
    -- 【注入确实造出了那个行形】—— 先证明这一点,再断言它的后果。
    IF (SELECT kind_code FROM materials WHERE id = v_mat_noform) IS NOT NULL
       OR (SELECT form_code FROM materials WHERE id = v_mat_noform) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 154 前置失败:这一行本应【种类与形态都为空】—— 那正是线上八行历史物料的行形';
    END IF;
    -- 而那条 CHECK 确实装回去了 —— 否则后面几臂跑在一个被削弱的库上。
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'materials_kind_stated'
                     AND conrelid = 'public.materials'::regclass) THEN
        RAISE EXCEPTION 'FIXTURE 154 前置失败:materials_kind_stated 必须被装回去 —— 少了它,后面每一臂都跑在一个被削弱的库上';
    END IF;

    -- ══════════ F1 · 对照臂:正极片【卖得掉】 ══════════
    RAISE NOTICE 'fixture 154 · 进入 F1';
    SELECT may_be_sold INTO v_denied FROM material_forms WHERE code = 'cathode_sheet';
    IF v_denied IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 154F1 前置失败:R5 说【正极片可以卖】。这一臂是整份 fixture 的铰链 —— 没有它,一个"全拦"的实现会全绿';
    END IF;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, unit, output_date, state)
    VALUES ('ZZ154-OBC', v_mat_cat, 100, 100, 'kg', v_process, '库存中') RETURNING id INTO v_ob_cat;
    v_sale := record_output_sale(v_ob_cat, 10, 5, v_ccy, NULL, v_cust, v_process, 'f154 cathode control', NULL, NULL);
    IF v_sale IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 154F1 失败:正极片必须卖得掉(R5)';
    END IF;

    -- ══════════ F2 · 三个不可售形态,一个一臂 ══════════
    RAISE NOTICE 'fixture 154 · 进入 F2';
    FOREACH v_code IN ARRAY v_codes LOOP
        IF (SELECT may_be_sold FROM material_forms WHERE code = v_code) IS NOT FALSE THEN
            RAISE EXCEPTION 'FIXTURE 154F2 前置失败:R5 点名【%】不可售,而字典说它可售', v_code;
        END IF;
        -- 【要拆解的形态还要说出规格尺寸】guard_material_condition_axes 的第三条 ——
        -- 电芯与已开壳电芯都 implies_dismantling = true,负极片不是。让数据回答,别写死。
        INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
        VALUES ('ZZ154-B-' || v_code, 'f154 ' || v_code, 'battery_material', true, v_code, 'end_of_life',
                CASE WHEN (SELECT implies_dismantling FROM material_forms WHERE code = v_code)
                     THEN 'ev_traction' ELSE NULL END)
        RETURNING id INTO v_matx;
        INSERT INTO output_batches (code, material_id, quantity, remaining_qty, unit, output_date, state)
        VALUES ('ZZ154-OB-' || v_code, v_matx, 100, 100, 'kg', v_process, '库存中') RETURNING id INTO v_ob_anode;

        v_denied := false; v_msg := NULL;
        BEGIN
            PERFORM record_output_sale(v_ob_anode, 10, 5, v_ccy, NULL, v_cust, v_process, 'f154 blocked', NULL, NULL);
        EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
        IF NOT v_denied THEN
            RAISE EXCEPTION 'FIXTURE 154F2 失败:形态【%】在法律上不许卖(R5),而这一笔成交了', v_code;
        END IF;
        IF v_msg NOT LIKE 'SALE_FORM_NOT_SALEABLE|' || v_code || '|%' THEN
            RAISE EXCEPTION 'FIXTURE 154F2 失败:拒绝必须按名【并点出是哪一个形态】。形态「%」实得「%」', v_code, v_msg;
        END IF;
        IF v_code = 'anode_sheet' THEN v_msg_notsaleable := v_msg; END IF;
    END LOOP;

    -- ══════════ F3 · 加工产出 + 形态没设 → 【另一条】拒绝 ══════════
    RAISE NOTICE 'fixture 154 · 进入 F3';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ154-IB', v_mat_cat, v_sup, 500, 500, 'kg', v_process - 1) RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, v_ccy, NULL, 'f154 price');
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib, 'discharged_verified');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib;
    v_run := commit_processing_run(v_process, 'f154 run', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 500)),
        jsonb_build_array(jsonb_build_object('material_id', v_mat_noform, 'quantity', 500)), 'weight', NULL, NULL, 'manual_disassembly');
    SELECT po.output_batch_id INTO v_ob_noform FROM processing_outputs po WHERE po.run_id = v_run;
    -- 【注入确实改变了东西】这一批确实是加工出来的,而它的物料确实没有形态。
    IF NOT EXISTS (SELECT 1 FROM processing_outputs WHERE output_batch_id = v_ob_noform) THEN
        RAISE EXCEPTION 'FIXTURE 154F3 前置失败:这一批本应是【加工产出】的 —— 那正是这一臂与 F4 的分界';
    END IF;
    IF (SELECT form_code FROM materials WHERE id = v_mat_noform) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 154F3 前置失败:这一种物料本应【没有形态】';
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_output_sale(v_ob_noform, 10, 5, v_ccy, NULL, v_cust, v_process, 'f154 no form', NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 154F3 失败:一批【加工产出而形态没设】的货,可售性【判断不了】,必须拒';
    END IF;
    IF v_msg NOT LIKE 'SALE_FORM_NOT_SET|%' THEN
        RAISE EXCEPTION 'FIXTURE 154F3 失败:这条拒绝必须是【另一条码】。它说的是"判断不了",【不是】"这个东西不许卖" —— 后者是另一句话,而且会是假的。实得「%」', v_msg;
    END IF;
    v_msg_notset := v_msg;

    -- ══════════ F4 · 买进来的 / 形态没设的,照旧卖得掉 ══════════
    RAISE NOTICE 'fixture 154 · 进入 F4';
    -- 同一种【没有形态】的物料,但这一批【不是加工出来的】。
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, unit, output_date, state)
    VALUES ('ZZ154-OBN', v_mat_noform, 100, 100, 'kg', v_process, '库存中') RETURNING id INTO v_ob_bought;
    IF EXISTS (SELECT 1 FROM processing_outputs WHERE output_batch_id = v_ob_bought) THEN
        RAISE EXCEPTION 'FIXTURE 154F4 前置失败:这一批本应【不是】加工产出的 —— 那正是它与 F3 的唯一区别';
    END IF;
    v_sale := record_output_sale(v_ob_bought, 10, 5, v_ccy, NULL, v_cust, v_process, 'f154 pre-axis sells', NULL, NULL);
    IF v_sale IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 154F4 失败:【不是加工产出】的货,形态为空照旧卖得掉。空的意思是"这条轴比这行料还年轻",不是"有人漏填了"。**拦掉它等于停掉线上每一笔销售**';
    END IF;

    -- ══════════ F4b(fu1)· 【不适用】不是【没设】 ══════════
    -- 一个【可加工、但没有状态轴】的种类,形态**必须为空**
    -- (guard_material_condition_axes 拦着不许填)。对它喊"去把形态设上"
    -- 既是假话又是死锁 —— 所以它的加工产出**照旧卖得掉**。
    -- 【线上 ewaste 今天就是这一种】,不是一个假想分支(与 fixture 115 F5 同一个理由)。
    RAISE NOTICE 'fixture 154 · 进入 F4b';
    IF (SELECT has_condition_axes FROM material_kinds WHERE code = 'ewaste') IS NOT FALSE
       OR (SELECT may_ever_be_processed FROM material_kinds WHERE code = 'ewaste') IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 154F4b 前置失败:本臂要的是一个【可加工、但没有状态轴】的种类。ewaste 本应如此 —— 若那一行变了,换一个符合条件的种类,不要把这一臂删掉:它挡的是"把【不适用】读成【没设】"';
    END IF;
    INSERT INTO materials (code, name, kind_code, may_be_processed)
    VALUES ('ZZ154-EW', 'f154 ewaste', 'ewaste', true) RETURNING id INTO v_matx;
    IF (SELECT form_code FROM materials WHERE id = v_matx) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 154F4b 前置失败:这一类物料的形态本应【必须为空】';
    END IF;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ154-IBE', v_mat_cat, v_sup, 100, 100, 'kg', v_process - 1) RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, v_ccy, NULL, 'f154 ew');
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib, 'discharged_verified');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib;
    v_run := commit_processing_run(v_process, 'f154 ewaste run', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_matx, 'quantity', 100)), 'weight', NULL, NULL, 'manual_disassembly');
    SELECT po.output_batch_id INTO v_ob_anode FROM processing_outputs po WHERE po.run_id = v_run;
    v_sale := record_output_sale(v_ob_anode, 10, 5, v_ccy, NULL, v_cust, v_process, 'f154 ewaste sells', NULL, NULL);
    IF v_sale IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 154F4b 失败:一个【没有状态轴】的种类,它的加工产出必须照旧卖得掉 —— 形态为空对它的意思是【不适用】,不是【没人决定过】';
    END IF;

    -- ══════════ F5 · 三种拒绝互不相同 ══════════
    RAISE NOTICE 'fixture 154 · 进入 F5';
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_output_sale(v_ob_cat, 100000, 5, v_ccy, NULL, v_cust, v_process, 'f154 no stock', NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 154F5 前置失败:卖超库存本应被拒 —— 这一臂要的是那第三种句子';
    END IF;
    v_msg_stock := v_msg;
    IF split_part(v_msg_notsaleable, '|', 1) = split_part(v_msg_notset, '|', 1)
       OR split_part(v_msg_notsaleable, '|', 1) = split_part(v_msg_stock, '|', 1)
       OR split_part(v_msg_notset, '|', 1) = split_part(v_msg_stock, '|', 1) THEN
        RAISE EXCEPTION 'FIXTURE 154F5 失败:三种拒绝必须是三条【不同】的码。不可售「%」/ 判断不了「%」/ 库存「%」',
            split_part(v_msg_notsaleable, '|', 1), split_part(v_msg_notset, '|', 1), split_part(v_msg_stock, '|', 1);
    END IF;

    -- ══════════ F6 · 四层入口全覆盖 ══════════
    RAISE NOTICE 'fixture 154 · 进入 F6';
    -- ① 报价行
    INSERT INTO quotes (code, customer_id, quote_date, valid_until, currency, fx_rate, status)
    VALUES ('ZZ154-Q', v_cust, v_process, v_process + 30, v_ccy, 1, 'draft') RETURNING id INTO v_q;
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO quote_lines (quote_id, line_no, material_id, quantity, unit_price)
        VALUES (v_q, 1, v_mat_anode, 10, 5);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'SALE_FORM_NOT_SALEABLE|anode_sheet|%' THEN
        RAISE EXCEPTION 'FIXTURE 154F6① 失败:【报价行】必须拒 —— 一份卖不了的东西的报价,是一个太晚才会被发现的承诺。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;
    -- 对照:正极片报得出去
    INSERT INTO quote_lines (quote_id, line_no, material_id, quantity, unit_price)
    VALUES (v_q, 1, v_mat_cat, 10, 5);

    -- ② 订单行
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate, status)
    VALUES ('ZZ154-SO', v_cust, v_process, v_ccy, 1, 'draft') RETURNING id INTO v_so;
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
        VALUES (v_so, 1, v_mat_anode, 10, 5);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'SALE_FORM_NOT_SALEABLE|anode_sheet|%' THEN
        RAISE EXCEPTION 'FIXTURE 154F6② 失败:【订单行】必须拒 —— 一份永远履行不了的承诺。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (v_so, 1, v_mat_cat, 10, 5) RETURNING id INTO v_line;

    -- ③ 占用 —— 用【加工产出而形态没设】那一批,同时钉住第二条码走得到这一层
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO sales_order_reservations (sales_order_line_id, output_batch_id, qty)
        VALUES (v_line, v_ob_noform, 1);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'SALE_FORM_NOT_SET|%' THEN
        RAISE EXCEPTION 'FIXTURE 154F6③ 失败:【占用】必须拒 —— 圈定一批货是准备发它。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ④ 出货与直销共用的那个门:sales_records
    -- F2/F3 已经经由 record_output_sale 走过它;这里直接钉住【那个门本身】,
    -- 因为 ship_order 与 record_output_sale 共用它,而共用正是它值得单独钉的理由。
    SELECT count(*) INTO v_n FROM information_schema.triggers
     WHERE trigger_schema = 'public' AND event_object_table = 'sales_records'
       AND trigger_name = 'trg_sales_records_form_saleable';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 154F6④ 失败:sales_records 上必须有那一个门。**record_output_sale 与 ship_order 两条路共用它** —— 拦一条放一条比不拦更糟,因为它制造信心';
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price, currency, fx_rate, amount_base, sale_date)
        VALUES (v_ob_noform, v_cust, 1, 5, v_ccy, 1, 5, v_process);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'SALE_FORM_NOT_SET|%' THEN
        RAISE EXCEPTION 'FIXTURE 154F6④ 失败:直插 sales_records 也必须被拦 —— **触发器对每一个写入者成立,包括直连 psql**。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;
END $$;
ROLLBACK;
