-- 52 采购单修改:守卫挡得住【直连那条路】,审批被重新路由,条款与签发档不受牵连
--
-- 【本 fixture 的前提是一句调查结论】PUR-2 之前,purchase_orders 只有两个触发器、
-- purchase_order_lines 【一个都没有】,而 RLS 允许任何持 module.purchasing.edit 的人
-- UPDATE。也就是说商业字段从来只是【够不着】(应用里没那个按钮),不是【被保护】。
-- 所以本 fixture 的 C 臂【故意走直连的 UPDATE,而不是走 RPC】—— 那是唯一能证明
-- 守卫是触发器、而不是写入函数里的一句客气话的办法。
--
-- 【D 臂必须先把审批打开,否则它什么也没断言】approvals_enabled() 今天是 false,
-- 而 void_approval_on_amount_increase 的第一句就是"没开就早退"。不打开的话,
-- 这一臂会安安静静地通过,而它要测的那件事根本没发生 —— 与 fixture 26 的空转、
-- FIN-30 的第三臂同一种病。所以打开审批、设好阈值,是这一臂的【一部分】。
--
-- 【H 臂钉的是【顺序】,不只是结果】estimated_total_ccy 是作废触发器盯着的那一列。
-- 若总额不是与明细在同一条语句里算完,触发器判断时依据的就是一个与产生它的那批行
-- 已经不一致的数字 —— 那会产生一个看起来完全正常、却基于陈旧数字的审批决定。
-- 判别法:构造一次【新的行合计越过阈值、而旧总额没有】的修改。总额算对了,
-- 审批被打回 pending;总额是陈旧的,它就还是 approved。两种实现给出不同的答案。
--
-- 日期落在 2027,自带数据(README 第 4/5 条)。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    -- 【四眼:下单的人不能批自己的单】(approve_purchase_order 的 SELF_APPROVAL_FORBIDDEN)
    -- 所以 D 臂需要第二个人 —— 那不是 fixture 的麻烦,那是被测的规则。
    v_approver uuid := gen_random_uuid();
    r_all uuid;
    v_sup uuid; v_sup2 uuid; v_mat uuid; v_po uuid; v_line uuid; v_line2 uuid;
    v_po_fixed uuid; v_line_fixed uuid; v_po_pct uuid; v_line_pct uuid;
    v_po_term uuid; v_line_term uuid; v_formula uuid; v_commit_before jsonb;
    v_res jsonb; v_msg text; v_denied boolean;
    v_ccy text; v_n int; v_status text; v_total numeric; v_sum numeric;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-52', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_all, unnest(ARRAY['module.purchasing.view','module.purchasing.edit',
        'module.inbound.view','module.inbound.edit','module.finance.view','data.view_prices']);
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all), (v_approver, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX52-S', 'fixture 52 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    -- 【第二个供应商是有意的】C 臂要试"把供应商换成【另一个真实存在的】供应商"。
    -- 拿一个随机 uuid 去试,外键会先一步拒绝 —— 那样即使守卫被拿掉,这一臂也照样红,
    -- 于是它测的是外键,不是守卫。故障注入时正是这么暴露的。
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX52-S2', 'fixture 52 other supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup2;
    INSERT INTO materials (code, name, kind_code, may_be_processed)
    VALUES ('ZZFIX52-M', 'fixture 52 material', 'battery_material', true) RETURNING id INTO v_mat;

    -- ══════════ A. 已收下限:砍到已收之下拒,等于已收放行(边界在内)═══════════
    v_po := (create_purchase_order(v_sup, DATE '2027-03-01', NULL, v_ccy, NULL, NULL, NULL, NULL,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 1000, 'estimated_unit_price', 10)), NULL)->>'purchase_order_id')::uuid;
    SELECT id INTO v_line FROM purchase_order_lines WHERE purchase_order_id = v_po;
    -- 收 400
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('ZZFIX52-IB', v_mat, v_sup, 400, 400, DATE '2027-03-05', v_po, v_line);

    v_denied := false;
    BEGIN
        PERFORM amend_purchase_order(v_po, '砍到已收之下', NULL,
            jsonb_build_array(jsonb_build_object('id', v_line, 'quantity', 300)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> 'PO_LINE_BELOW_RECEIVED|1|400|300' THEN
        RAISE EXCEPTION 'FIXTURE 52A 失败:订量砍到已收(400)之下应点名拒,实得 denied=% msg=% —— 货已经在院子里了,单据不能宣称我们订的比到的还少',
            v_denied, COALESCE(v_msg, '(放行了)');
    END IF;
    -- 【边界在内】改成【正好等于】已收:允许
    PERFORM amend_purchase_order(v_po, '改成正好等于已收', NULL,
        jsonb_build_array(jsonb_build_object('id', v_line, 'quantity', 400)));
    IF (SELECT quantity FROM purchase_order_lines WHERE id = v_line) <> 400 THEN
        RAISE EXCEPTION 'FIXTURE 52A 失败:改成正好等于已收应当放行 —— 下限是"已收",不是"已收再多一点"';
    END IF;

    -- ══════════ B. 收过货的行删不掉;没收过的删得掉 ══════════════════════════
    PERFORM amend_purchase_order(v_po, '加一行没收过货的', NULL,
        jsonb_build_array(jsonb_build_object('line_no', 2, 'material_id', v_mat,
            'quantity', 50, 'estimated_unit_price', 2)));
    SELECT id INTO v_line2 FROM purchase_order_lines
     WHERE purchase_order_id = v_po AND line_no = 2;

    v_denied := false;
    BEGIN
        PERFORM amend_purchase_order(v_po, '删掉收过货的行', NULL,
            jsonb_build_array(jsonb_build_object('id', v_line, 'remove', true)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'PO_LINE_HAS_RECEIPTS|1|%' THEN
        RAISE EXCEPTION 'FIXTURE 52B 失败:收过货的行应当删不掉,实得 denied=% msg=% —— 那批货真的到了,单据上却会没有它的出处',
            v_denied, COALESCE(v_msg, '(删掉了)');
    END IF;
    PERFORM amend_purchase_order(v_po, '删掉没收过货的行', NULL,
        jsonb_build_array(jsonb_build_object('id', v_line2, 'remove', true)));
    IF EXISTS (SELECT 1 FROM purchase_order_lines WHERE id = v_line2) THEN
        RAISE EXCEPTION 'FIXTURE 52B 失败:没收过货的行应当删得掉';
    END IF;

    -- ══════════ C. 身份字段:【走直连的 UPDATE】,证明守卫是触发器 ════════════
    -- 【这一臂故意不走 RPC】RLS 今天就允许 module.purchasing.edit 的人直接 UPDATE。
    -- 守卫若只写在 amend_purchase_order 里,这一臂会全部放行 —— 而那正是 PUR-2
    -- 之前的真实状态:商业字段只是够不着,不是被保护。
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false;
    BEGIN UPDATE purchase_orders SET supplier_id = v_sup2 WHERE id = v_po;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    RESET ROLE;
    IF NOT v_denied OR v_msg NOT LIKE 'PO_FIELD_IMMUTABLE|supplier_id|%' THEN
        RAISE EXCEPTION 'FIXTURE 52C 失败:直连改供应商应被【触发器】挡住,实得 denied=% msg=% —— 换对手方就是另一笔交易:应付、预付、签发档全挂在这一张上',
            v_denied, COALESCE(v_msg, '(改成功了)');
    END IF;

    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE purchase_orders SET currency = 'USD' WHERE id = v_po;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    RESET ROLE;
    IF NOT v_denied OR v_msg NOT LIKE 'PO_FIELD_IMMUTABLE|currency|%' THEN
        RAISE EXCEPTION 'FIXTURE 52C 失败:直连改币种应被挡,实得 denied=% msg=%', v_denied, COALESCE(v_msg,'(改成功了)');
    END IF;

    -- 审批状态不走"修改"这条路 —— 【要真的改变它】才测得到(approved → pending)
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE purchase_orders SET approval_status = 'pending' WHERE id = v_po;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    RESET ROLE;
    IF NOT v_denied OR v_msg NOT LIKE 'PO_STATUS_NOT_AMENDABLE|approval_status|%' THEN
        RAISE EXCEPTION 'FIXTURE 52C 失败:直连改审批状态应被挡,实得 denied=% msg=% —— 一个能把 approval_status 设成 approved 的路径,就是一条不经审批的审批路径',
            v_denied, COALESCE(v_msg, '(改成功了)');
    END IF;
    -- 而【状态转换本身】仍然可用(守卫认上下文标记,不是一律禁止)
    PERFORM close_purchase_order(v_po, 'fixture 52:转换仍然可用');
    IF (SELECT status FROM purchase_orders WHERE id = v_po) <> 'closed' THEN
        RAISE EXCEPTION 'FIXTURE 52C 失败:close_purchase_order 应当仍然可用 —— 守卫挡的是"经修改改状态",不是状态转换本身';
    END IF;
    -- 【标记用完即清】跑过状态 RPC 之后,直连改状态必须仍然被挡
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE purchase_orders SET status = 'cancelled' WHERE id = v_po;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    RESET ROLE;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 52C 失败:跑过一次状态 RPC 之后,直连改状态仍然应当被挡 —— set_config(..., true) 是【事务】局部而不是语句局部,只在函数开头设一次,守卫会在整个事务余下的时间里一直关着(fu2 修的正是这个)';
    END IF;

    -- ══════════ D+H. 审批重新路由 + 【总额与明细同语句】═══════════════════════
    -- 【先把审批打开,否则这一臂什么也没断言】approvals_enabled() 默认 false,
    -- 而作废触发器第一句就是"没开就早退"。
    UPDATE finance_settings SET approvals_enabled = true,
        approval_level1_role_code = 'fixture-52',
        approval_threshold_base = 10000,
        approval_level2_user_id = v_approver;

    v_po := (create_purchase_order(v_sup, DATE '2027-04-01', NULL, v_ccy, NULL, NULL, NULL, NULL,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100, 'estimated_unit_price', 50)), NULL)->>'purchase_order_id')::uuid;
    SELECT id INTO v_line FROM purchase_order_lines WHERE purchase_order_id = v_po;
    -- 5,000:阈值之下。先让它成为 approved —— 【由另一个人批】(四眼规则)
    IF (SELECT approval_status FROM purchase_orders WHERE id = v_po) = 'pending' THEN
        PERFORM set_config('request.jwt.claims',
            format('{"sub":"%s","role":"authenticated"}', v_approver), true);
        PERFORM approve_purchase_order(v_po);
        PERFORM set_config('request.jwt.claims',
            format('{"sub":"%s","role":"authenticated"}', v_user), true);
    END IF;
    IF (SELECT approval_status FROM purchase_orders WHERE id = v_po) <> 'approved' THEN
        RAISE EXCEPTION 'FIXTURE 52D 前置失败:这张单应当先处于 approved,实得 %',
            (SELECT approval_status FROM purchase_orders WHERE id = v_po);
    END IF;

    -- 【负例先跑】仍在阈值之下的修改:审批不该被打掉
    PERFORM amend_purchase_order(v_po, '仍在阈值之下', NULL,
        jsonb_build_array(jsonb_build_object('id', v_line, 'quantity', 120)));
    IF (SELECT approval_status FROM purchase_orders WHERE id = v_po) <> 'approved' THEN
        RAISE EXCEPTION 'FIXTURE 52D 失败:6,000 仍在 10,000 阈值之下,原审批应当依然成立,实得 % —— 金额没越级还要求重批是空转',
            (SELECT approval_status FROM purchase_orders WHERE id = v_po);
    END IF;

    -- 【正例:越过阈值】数量 120 → 400,总额 20,000 > 10,000
    -- 【H 臂的判别力在这里】总额若不是与明细同语句算完(比如用了改动之前的那个数),
    -- 触发器看到的就是 6,000 → 6,000,级别没变,审批不会被打回 —— 于是这一臂红。
    PERFORM amend_purchase_order(v_po, '越过阈值', NULL,
        jsonb_build_array(jsonb_build_object('id', v_line, 'quantity', 400)));

    SELECT approval_status, estimated_total_ccy INTO v_status, v_total
      FROM purchase_orders WHERE id = v_po;
    SELECT COALESCE(SUM(estimated_amount_ccy), 0) INTO v_sum
      FROM purchase_order_lines WHERE purchase_order_id = v_po;

    IF v_total <> v_sum THEN
        RAISE EXCEPTION 'FIXTURE 52H 失败:修改之后总额(%)必须等于明细合计(%)—— 两者不等说明总额不是与明细在同一条语句里算完的,而作废触发器盯的正是这一列',
            v_total, v_sum;
    END IF;
    IF v_status <> 'pending' THEN
        RAISE EXCEPTION 'FIXTURE 52D 失败:金额越过阈值(总额 %)应当作废原审批并重新路由,实得 % —— 而这同时是【顺序】的断言:总额若是陈旧的,触发器会看到"没越级"而放行,产生一个看起来完全正常、却基于陈旧数字的审批决定',
            v_total, v_status;
    END IF;
    SELECT count(*) INTO v_n FROM approval_log
     WHERE subject_id = v_po AND decision = 'approval_voided';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 52D 失败:作废应当在 approval_log 里留一行(approval_voided),实得 % 行 —— "批过又没批"读不出来的话,留痕就没有意义', v_n;
    END IF;

    -- ══════════ E. FIN-27:改数量不碰已抄下的条款 ════════════════════════════
    INSERT INTO pricing_formulas (code, name, direction, price_basis,
        treatment_charge_usd_per_tonne, flat_discount_pct)
    VALUES ('ZZFIX52-PF', 'fixture 52 formula', 'both', 'spot', 100, 5) RETURNING id INTO v_formula;
    INSERT INTO pricing_formula_metals (formula_id, metal, payable_pct) VALUES (v_formula, 'cu', 70);
    v_po_term := (create_purchase_order(v_sup, DATE '2027-05-01', NULL, v_ccy, NULL, NULL, NULL, NULL,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100, 'pricing_formula_id', v_formula)), NULL)->>'purchase_order_id')::uuid;
    SELECT id INTO v_line_term FROM purchase_order_lines WHERE purchase_order_id = v_po_term;
    SELECT to_jsonb(c) INTO v_commit_before FROM pricing_term_commitments c
     WHERE c.purchase_order_line_id = v_line_term;
    IF v_commit_before IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 52E 前置失败:公式定价的行下单时就该抄下条款(FIN-27)—— 没抄的话这一臂在拿空比空';
    END IF;

    PERFORM amend_purchase_order(v_po_term, '改数量,条款不该动', NULL,
        jsonb_build_array(jsonb_build_object('id', v_line_term, 'quantity', 250)));

    IF (SELECT to_jsonb(c) FROM pricing_term_commitments c
         WHERE c.purchase_order_line_id = v_line_term) IS DISTINCT FROM v_commit_before THEN
        RAISE EXCEPTION 'FIXTURE 52E 失败:改数量【一个字都不该动】抄下来的条款 —— 条款是成交那一刻谈定的,改数量改的是它作用的量,不是它本身(FIN-27 抄副本的全部理由)';
    END IF;

    -- ══════════ F. 定额腿拒绝 / 比例腿跟着走 ═════════════════════════════════
    -- 定额:订单 1,000(100 × 10),计划一条定额 1,000
    v_po_fixed := (create_purchase_order(v_sup, DATE '2027-06-01', NULL, v_ccy, NULL, NULL, NULL, NULL,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100, 'estimated_unit_price', 10)), jsonb_build_array(jsonb_build_object('seq', 1, 'label', '定金', 'fixed_amount_ccy', 1000, 'trigger_event', 'on_order')))->>'purchase_order_id')::uuid;
    SELECT id INTO v_line_fixed FROM purchase_order_lines WHERE purchase_order_id = v_po_fixed;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM amend_purchase_order(v_po_fixed, '改金额,定额腿加不上了', NULL,
            jsonb_build_array(jsonb_build_object('id', v_line_fixed, 'quantity', 80)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> 'PO_PLAN_FIXED_MISMATCH|800.00|1000.00|200.00' THEN
        RAISE EXCEPTION 'FIXTURE 52F 失败:定额腿加不上应当【点名拒绝并报出三个数】(订单 800 / 计划 1000 / 差 200),实得 denied=% msg=% —— 悄悄按比例缩放等于系统替操作员重新谈了一次条款,而没有任何人被告知',
            v_denied, COALESCE(v_msg, '(放行了)');
    END IF;

    -- 比例:同样的修改,按构造跟着走 —— 不该拒
    v_po_pct := (create_purchase_order(v_sup, DATE '2027-06-02', NULL, v_ccy, NULL, NULL, NULL, NULL,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100, 'estimated_unit_price', 10)), jsonb_build_array(jsonb_build_object('seq', 1, 'label', '定金', 'percentage', 100, 'trigger_event', 'on_order')))->>'purchase_order_id')::uuid;
    SELECT id INTO v_line_pct FROM purchase_order_lines WHERE purchase_order_id = v_po_pct;
    PERFORM amend_purchase_order(v_po_pct, '同样的修改,比例计划', NULL,
        jsonb_build_array(jsonb_build_object('id', v_line_pct, 'quantity', 80)));
    IF (SELECT estimated_total_ccy FROM purchase_orders WHERE id = v_po_pct) <> 800 THEN
        RAISE EXCEPTION 'FIXTURE 52F 失败:比例计划下同样的修改应当放行(总额 800),实得 % —— 百分比的意思就是"订单的这一份",它按构造跟着总额走;只有定额需要被拦住。两种计划给出【不同】的答案,正是这一臂的判别力',
            (SELECT estimated_total_ccy FROM purchase_orders WHERE id = v_po_pct);
    END IF;

    -- ══════════ G. 留痕:表头改动与【删行】各留一行,old/new 都在 ═════════════
    SELECT count(*) INTO v_n FROM purchase_order_history
     WHERE purchase_order_id = v_po_term AND change_type = 'line_update'
       AND old_quantity = 100 AND new_quantity = 250;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 52G 失败:改数量应当留一行 line_update(100 → 250),实得 % 行', v_n;
    END IF;
    -- 【删行是最激烈的一种编辑,也最容易被漏记】界面表达"这一行不要了"就是删掉它,
    -- 只记表头的历史对它一言不发,而沉默读起来正好等于"什么都没改"。
    SELECT count(*) INTO v_n FROM purchase_order_history
     WHERE change_type = 'line_remove' AND old_quantity = 50;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 52G 失败:删行应当留一行 line_remove 并记下它当时的数量(50),实得 % 行 —— 只记表头的历史对最激烈的那种编辑一言不发', v_n;
    END IF;
    -- 理由必填,而且要真的落到留痕上
    SELECT count(*) INTO v_n FROM purchase_order_history
     WHERE purchase_order_id = v_po_term AND amend_reason = '改数量,条款不该动';
    IF v_n < 1 THEN
        RAISE EXCEPTION 'FIXTURE 52G 失败:修改理由应当落在留痕行上 —— 一行"数字变了"而没有"为什么",日后读不出任何东西';
    END IF;
    -- 留痕只增不改
    v_denied := false;
    BEGIN
        UPDATE purchase_order_history SET amend_reason = '篡改'
         WHERE purchase_order_id = v_po_term;
    EXCEPTION WHEN OTHERS THEN v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 52G 失败:留痕被 UPDATE 成功 —— 能改写的留痕不是留痕';
    END IF;
END $$;
ROLLBACK;
