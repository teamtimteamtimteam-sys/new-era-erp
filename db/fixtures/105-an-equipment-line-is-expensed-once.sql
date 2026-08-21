-- 105 一条设备行只报销一次 —— 而"一次"说的是【行】,不是【机器】
--
-- 【这份 fixture 自带全部数据】重建库里没有任何业务数据(线上 fixed_assets 也是
-- 0 行)。每一臂自己造供应商 / 物料 / 资产卡 / 采购单 / 支出,【不从别处借】,
-- 也不依赖别的臂留下的东西 —— 共享可变状态的用例会因为错的理由通过(README 第 2 条)。
--
-- 【每一臂建什么、钉什么】
-- F1 前提,先于一切派生量:
--    (a) 一笔【没有采购单行】的普通支出照旧过账 —— 建:供应商 + 一个 6xxx 支出;
--    (b) 材料的下单 → 收货链条一个字没变 —— 建:供应商 + 物料 + 材料单 + 收货。
--    前提若已经断了,后面每一条"照旧"都是空转。
-- F2 正路:建 供应商 + 资产卡(定金 30,000)+ 设备单(估价 100,000)+ 发票 70,000。
--    钉:链接落库、成本涨到 100,000、成本明细两行。
-- F3 D4:同上自建一套,然后
--    ① 第二笔按【码】拒(PO_LINE_ALREADY_EXPENSED,断言码本身,不是"失败了");
--    ② 冲销第一笔 → 那条行【重新可计费】(再记一笔,成功);
--    ③ 冲销镜像单的 purchase_order_line_id 【必须是 NULL】——
--       今天它是 NULL 只因为 reverse_expense 的列清单里没有这一列,而那份清单
--       【也漏着 employee_id】、且补齐它已经排着队。这一条断言把"NULL 是刻意的"
--       钉住,免得补 employee_id 的人顺手把这一列也补上、当场废掉 ②。
-- F4 D3 两个方向,并且【两层都钉】:
--    (a) 挂到材料行 —— 经 record_expense 按名拒(函数层);
--    (b) 同一件事【直插】—— 经 trg_expenses_po_line_kind 按名拒(表层)。
--        两层分开钉,因为 authenticated 对 expenses 有表级 INSERT,直插进得来。
--    (c) 支出的资产 ≠ 行上的资产 —— 按名拒。
-- F5 D2 的守卫,逐条按名:PO_NOT_FOUND(软删)/ PO_CANCELLED / PO_NOT_APPROVED /
--    EXPENSE_SUPPLIER_NOT_STATED / SUPPLIER_MISMATCH。
--    第四条是【主体可缺席】那一类:paid 的支出合法地没有供应商,那不是"不一致"。
-- F6 部分唯一索引:直插一条与在册支出撞行的记录,断言【索引名】——
--    推导是第一层,这一堵墙是第二层(并发下两笔同时通过推导时,只有一笔落得下)。
-- F7 报销过的采购单行【删不得】:直插 DELETE,按名拒 PO_LINE_HAS_EXPENSE。
--    设备行没有收货,所以既有的 PO_LINE_HAS_RECEIPTS 对它恒为假 —— 本刀加了这一半。
--
-- 【F3② 之后的成本是 100,000,而它曾经是 170,000 —— 这一行是被兑现的那张欠条】
-- 本 fixture 落地时(EQP-1b-ii)冲销【不退回】资本成本,于是这里断言的是
-- 30,000 + 70,000(冲了却没退)+ 70,000 = 170,000,并在消息里写明:
-- "修好那个缺陷的人会拿到一条红,正确的期望值是 100,000"。
-- EQP-1b-iii 修好了它,所以这一行按当时说好的改成了 100,000,
-- 那条 known-issue 也在同一次提交里退役 —— 一份活得比它的对象久的记录,
-- 正是本仓库反复点名的失败形状。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_ccy text; v_exp_acct text;
    v_sup uuid; v_sup2 uuid; v_mat uuid;
    v_asset uuid; v_asset_b uuid;
    v_po uuid; v_line uuid; v_line_mat uuid;
    v_res jsonb; v_res2 jsonb;
    v_exp1 uuid; v_exp2 uuid; v_mirror uuid;
    v_n int; v_msg text; v_denied boolean; v_hint text;
    v_cost numeric; v_est numeric; v_link uuid; v_status text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    SELECT code INTO v_exp_acct FROM accounts
     WHERE account_type = 'expense' AND is_active ORDER BY code LIMIT 1;
    -- 前提显式设定(README 第 5 条):期间锁是运行时状态,会动。
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-105', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ F1(a) · 没有采购单行的普通支出,照旧 ═══════════════════════
    RAISE NOTICE 'fixture 105 · 进入 %', 'F1(a)';
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX105-S1', 'fixture 105 supplier 1', 'SG', 'active', 'goods_supplier')
    RETURNING id INTO v_sup;

    v_res := record_expense(DATE '2027-01-05', v_exp_acct, 1234, v_ccy, NULL, 'unpaid',
        NULL, v_sup, NULL, 'fixture 105 ordinary expense', NULL, NULL);
    SELECT purchase_order_line_id, status INTO v_link, v_status
      FROM expenses WHERE id = (v_res->>'expense_id')::uuid;
    IF v_link IS NOT NULL OR v_status <> 'posted' THEN
        RAISE EXCEPTION 'FIXTURE 105F1a 失败:一笔没有采购单行的普通支出应当照旧过账、且链接为空,实得 link=% status=% —— 本刀若动了常态那条路,后面每一条都不必再看',
            COALESCE(v_link::text, '(null)'), v_status;
    END IF;
    IF (SELECT journal_entry_id FROM expenses WHERE id = (v_res->>'expense_id')::uuid) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 105F1a 失败:普通支出没有挂上分录';
    END IF;

    -- ══════════ F1(b) · 材料的下单 → 收货链条,照旧 ════════════════════════
    RAISE NOTICE 'fixture 105 · 进入 %', 'F1(b)';
    INSERT INTO materials (code, name, kind_code, may_be_processed)
    VALUES ('ZZFIX105-M', 'fixture 105 material', 'battery_material', true) RETURNING id INTO v_mat;
    v_res := create_purchase_order(v_sup, DATE '2027-01-10', DATE '2027-03-01', v_ccy, NULL,
        NULL, NULL, 'fixture 105 material PO',
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100,
                                             'estimated_unit_price', 10)));
    v_po := (v_res->>'purchase_order_id')::uuid;
    SELECT id INTO v_line_mat FROM purchase_order_lines WHERE purchase_order_id = v_po;
    PERFORM receive_inbound_batch_against_po(v_mat, v_sup, 40, DATE '2027-02-01',
        'fixture 105 receipt', v_po, v_line_mat, NULL, NULL);
    SELECT count(*) INTO v_n FROM inbound_batches
     WHERE purchase_order_line_id = v_line_mat AND deleted_at IS NULL;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 105F1b 失败:材料行照旧收得进货(应 1 个批次),实得 % —— 本刀不许动既有材料路径', v_n;
    END IF;

    -- ══════════ F2 · 正路:一条设备行,报销一次 ════════════════════════════
    RAISE NOTICE 'fixture 105 · 进入 %', 'F2';
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX105-S2', 'fixture 105 supplier 2', 'SG', 'active', 'goods_supplier')
    RETURNING id INTO v_sup2;

    -- 定金 30,000 建卡(新建模式)。【这一笔不可能带采购单行】—— 行上的 asset_id
    -- 是外键,资产必须先存在,行才建得出来。所以链接只可能落在【追加】那一笔上。
    v_res := record_expense(DATE '2027-01-05', '1500', 30000, v_ccy, NULL, 'unpaid', NULL,
        v_sup2, NULL, 'fixture 105 deposit',
        jsonb_build_object('description', 'fixture 105 press', 'useful_life_months', 120), NULL);
    SELECT id INTO v_asset FROM fixed_assets WHERE expense_id = (v_res->>'expense_id')::uuid;
    IF v_asset IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 105F2 前提失败:资本支出没有生成资产卡';
    END IF;

    v_res := create_purchase_order(v_sup2, DATE '2027-01-10', DATE '2027-03-01', v_ccy, NULL,
        NULL, NULL, 'fixture 105 equipment PO',
        jsonb_build_array(jsonb_build_object('asset_id', v_asset, 'quantity', 1,
                                             'estimated_unit_price', 100000)));
    v_po := (v_res->>'purchase_order_id')::uuid;
    SELECT id, estimated_amount_ccy INTO v_line, v_est
      FROM purchase_order_lines WHERE purchase_order_id = v_po;

    -- 发票 70,000,追加模式,挂在那条行上
    v_res := record_expense(DATE '2027-02-05', '1500', 70000, v_ccy, NULL, 'unpaid', NULL,
        v_sup2, NULL, 'fixture 105 machine invoice',
        jsonb_build_object('asset_id', v_asset), NULL, v_line);
    v_exp1 := (v_res->>'expense_id')::uuid;

    SELECT purchase_order_line_id INTO v_link FROM expenses WHERE id = v_exp1;
    IF v_link IS DISTINCT FROM v_line THEN
        RAISE EXCEPTION 'FIXTURE 105F2 失败:链接没有落库,实得 %', COALESCE(v_link::text, '(null)');
    END IF;
    SELECT cost_base INTO v_cost FROM fixed_assets WHERE id = v_asset;
    -- 【这个数怎么来的】30,000 定金 + 70,000 发票 = 100,000,而它也【必须】等于
    -- 这条设备行的估算金额(1 台 × 100,000)—— 两个来源同一个数,所以断的是
    -- 不变量("机器的成本 = 这条行订的金额"),不是一个写死的字面量。
    IF v_cost <> 100000 OR v_cost <> v_est THEN
        RAISE EXCEPTION 'FIXTURE 105F2 失败:资产成本应为 30,000 + 70,000 = 100,000 且等于行估算 %,实得 %', v_est, v_cost;
    END IF;
    SELECT count(*) INTO v_n FROM fixed_asset_cost_entries WHERE asset_id = v_asset;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 105F2 失败:成本明细应为 2 行(定金 + 发票),实得 %', v_n;
    END IF;

    -- ══════════ F3 · D4:第二笔拒;冲销之后【重新可计费】═══════════════════
    RAISE NOTICE 'fixture 105 · 进入 %', 'F3';
    -- ① 第二笔,按【码】拒
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_expense(DATE '2027-02-06', '1500', 70000, v_ccy, NULL, 'unpaid', NULL,
            v_sup2, NULL, 'fixture 105 duplicate invoice',
            jsonb_build_object('asset_id', v_asset), NULL, v_line);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('PO_LINE_ALREADY_EXPENSED' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 105F3① 失败:同一条设备行的第二笔支出应被 PO_LINE_ALREADY_EXPENSED 拒,实得 denied=% msg=% —— 没有这条推导,一台机器可以被资本化任意多次',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- ② 冲销第一笔 → 行重新可计费
    v_res := reverse_expense(v_exp1, 'fixture 105');
    v_mirror := (v_res->>'reversal_expense_id')::uuid;
    SELECT status INTO v_status FROM expenses WHERE id = v_exp1;
    IF v_status <> 'reversed' THEN
        RAISE EXCEPTION 'FIXTURE 105F3② 前提失败:冲销之后原单应为 reversed,实得 %', v_status;
    END IF;

    -- ③ 镜像单【不带】采购单行 —— 带了就会当场重新占住那条行,而 ② 会静默失效。
    -- 【故障注入实测到一件本刀设计时没想到的事,记在这里】给 reverse_expense
    -- 加上抄这一列的代码之后,索引【留着】时它当场就炸:镜像 INSERT 的那一刻
    -- 原单还是 'posted',两行一起落进 uq_expenses_live_po_line —— 冲销本身失败,
    -- 响亮、不静默。也就是说索引在这里【顺带】是第二道墙。
    -- 那这一臂还有什么用?把索引一起摘掉,它就是唯一红的那一条(实测:注入 B)。
    -- 索引挡的是"这一列已经被占着";这一臂挡的是"镜像单压根不该有这一列"——
    -- 后者是意图,前者是当下的实现,而意图要在实现挪动之后仍然站着。
    SELECT purchase_order_line_id INTO v_link FROM expenses WHERE id = v_mirror;
    IF v_link IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 105F3③ 失败:冲销镜像单的 purchase_order_line_id 必须为空,实得 % —— 镜像单是记录凭证,不是第二张账单;它一带上这一列,"冲销之后行重新可计费"就静默变成假的。补 reverse_expense 的 employee_id 时【不要】连这一列一起补',
            v_link;
    END IF;

    -- 行确实重新可计费:再记一笔,成功
    v_res := record_expense(DATE '2027-02-07', '1500', 70000, v_ccy, NULL, 'unpaid', NULL,
        v_sup2, NULL, 'fixture 105 re-billed invoice',
        jsonb_build_object('asset_id', v_asset), NULL, v_line);
    v_exp2 := (v_res->>'expense_id')::uuid;
    SELECT purchase_order_line_id INTO v_link FROM expenses WHERE id = v_exp2;
    IF v_link IS DISTINCT FROM v_line THEN
        RAISE EXCEPTION 'FIXTURE 105F3② 失败:冲销之后那条行应当重新可计费并挂上新支出,实得 link=%', COALESCE(v_link::text, '(null)');
    END IF;

    -- 【这个数怎么来的】30,000 定金 + 70,000 发票(已冲销 —— EQP-1b-iii 起
    -- 冲销会把它退回去)+ 70,000 重开 = 100,000,也就是这台机器真正的成本。
    SELECT cost_base INTO v_cost FROM fixed_assets WHERE id = v_asset;
    IF v_cost <> 100000 THEN
        RAISE EXCEPTION 'FIXTURE 105F3 失败:资产成本应为 30,000 + 70,000(冲销后退回)+ 70,000 = 100,000,实得 % —— 若实得 170,000,说明冲销又不退回成本了(EQP-1b-iii 修的正是这一条)', v_cost;
    END IF;

    -- ══════════ F4 · D3 两个方向,两层都钉 ═════════════════════════════════
    RAISE NOTICE 'fixture 105 · 进入 %', 'F4';
    -- (a) 挂到【材料行】—— 函数层按名拒
    -- 【两层抛的是同一个码,所以必须靠别的东西把它们分开】
    -- record_expense 那一层带 HINT,触发器那一层不带 —— 判据因此问的是
    -- "是谁拒的",而不只是"被拒了"。不分开的话:把函数里那段检查删掉,
    -- 触发器照样按同一个码拒,这一臂【依旧全绿】—— 它就证明不了自己那一层。
    -- (这一点是本刀做故障注入时发现的,不是设计时想到的,所以写在这里。)
    v_denied := false; v_msg := NULL; v_hint := NULL;
    BEGIN
        PERFORM record_expense(DATE '2027-02-08', '1500', 500, v_ccy, NULL, 'unpaid', NULL,
            v_sup, NULL, 'fixture 105 expense on a material line',
            jsonb_build_object('asset_id', v_asset), NULL, v_line_mat);
    EXCEPTION WHEN OTHERS THEN
        v_denied := true; v_msg := SQLERRM;
        GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT;
    END;
    IF NOT v_denied OR position('PO_LINE_NOT_EQUIPMENT' in v_msg) = 0
       OR position('材料行经收货计价' in COALESCE(v_hint, '')) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 105F4a 失败:挂到材料行的支出应被【record_expense 那一层】按 PO_LINE_NOT_EQUIPMENT 拒(判据含它的 HINT),实得 denied=% msg=% hint=% —— 材料经收货计价,再开一条费用路就是两条计费路而没有对账。若 msg 对而 hint 空,那是【触发器】拒的,函数那一层已经没了',
            v_denied, COALESCE(v_msg, '(收下了)'), COALESCE(v_hint, '(无)');
    END IF;

    -- (b) 同一件事,【直插】—— 表层(触发器)按名拒。
    --     函数层挡得住走门的人;这一层挡的是 authenticated 的表级 INSERT。
    v_denied := false; v_msg := NULL; v_hint := NULL;
    BEGIN
        INSERT INTO expenses (code, expense_date, account_code, amount_ccy, currency, fx_rate,
                              amount_base, payment_status, bank_account_code, purchase_order_line_id)
        VALUES ('ZZFIX105-DIRECT-1', DATE '2027-02-08', v_exp_acct, 500, v_ccy, 1, 500,
                'paid', '1000', v_line_mat);
    EXCEPTION WHEN OTHERS THEN
        v_denied := true; v_msg := SQLERRM;
        GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT;
    END;
    -- 直插【不经过】record_expense,所以拒它的只可能是触发器 —— 判据连同
    -- "没有 HINT" 一起断言,与 F4a 恰好互补:删掉函数那段检查只红 F4a,
    -- 摘掉触发器只红 F4b。两条注入各红各的,谁也不替谁作证。
    IF NOT v_denied OR position('PO_LINE_NOT_EQUIPMENT' in v_msg) = 0
       OR COALESCE(v_hint, '') <> '' THEN
        RAISE EXCEPTION 'FIXTURE 105F4b 失败:【直插】一条挂在材料行上的支出也应被 trg_expenses_po_line_kind 拒(触发器那一层不带 HINT),实得 denied=% msg=% hint=% —— 规矩只写在函数里,直插就绕过去了',
            v_denied, COALESCE(v_msg, '(收下了)'), COALESCE(v_hint, '(无)');
    END IF;

    -- (c) 支出的资产 ≠ 行上的资产
    v_res := record_expense(DATE '2027-01-06', '1500', 5000, v_ccy, NULL, 'unpaid', NULL,
        v_sup2, NULL, 'fixture 105 second machine',
        jsonb_build_object('description', 'fixture 105 machine B', 'useful_life_months', 60), NULL);
    SELECT id INTO v_asset_b FROM fixed_assets WHERE expense_id = (v_res->>'expense_id')::uuid;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_expense(DATE '2027-02-09', '1500', 900, v_ccy, NULL, 'unpaid', NULL,
            v_sup2, NULL, 'fixture 105 machine B invoice on machine A line',
            jsonb_build_object('asset_id', v_asset_b), NULL, v_line);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('EXPENSE_ASSET_MISMATCH' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 105F4c 失败:B 机器的发票挂到 A 机器的订单行上,应被 EXPENSE_ASSET_MISMATCH 拒,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    RAISE NOTICE 'fixture 105:F1–F4 通过';
END $$;

DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_ccy text; v_exp_acct text;
    v_sup uuid; v_sup_other uuid; v_asset uuid;
    v_po uuid; v_line uuid; v_res jsonb;
    v_msg text; v_denied boolean; v_exp uuid; v_n int;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    SELECT code INTO v_exp_acct FROM accounts
     WHERE account_type = 'expense' AND is_active ORDER BY code LIMIT 1;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-105b', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX105B-S', 'fixture 105b supplier', 'SG', 'active', 'goods_supplier')
    RETURNING id INTO v_sup;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX105B-S2', 'fixture 105b other supplier', 'SG', 'active', 'goods_supplier')
    RETURNING id INTO v_sup_other;

    -- ══════════ F5 · D2 的守卫,逐条按名 ═══════════════════════════════════
    RAISE NOTICE 'fixture 105 · 进入 %', 'F5';
    -- 每一条自己建一台机器 + 一张单,免得前一条的处置影响后一条。

    -- (1) SUPPLIER_MISMATCH:单是 v_sup 的,支出说的是 v_sup_other
    v_res := record_expense(DATE '2027-01-05', '1500', 100, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'f5-1 machine',
        jsonb_build_object('description', 'f5-1', 'useful_life_months', 60), NULL);
    SELECT id INTO v_asset FROM fixed_assets WHERE expense_id = (v_res->>'expense_id')::uuid;
    v_res := create_purchase_order(v_sup, DATE '2027-01-10', DATE '2027-03-01', v_ccy, NULL,
        NULL, NULL, 'f5-1 PO',
        jsonb_build_array(jsonb_build_object('asset_id', v_asset, 'quantity', 1,
                                             'estimated_unit_price', 100)));
    SELECT id INTO v_line FROM purchase_order_lines
     WHERE purchase_order_id = (v_res->>'purchase_order_id')::uuid;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_expense(DATE '2027-02-05', '1500', 100, v_ccy, NULL, 'unpaid', NULL,
            v_sup_other, NULL, 'f5-1 wrong supplier',
            jsonb_build_object('asset_id', v_asset), NULL, v_line);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('SUPPLIER_MISMATCH' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 105F5-1 失败:另一家供应商的支出挂到这张单上,应被 SUPPLIER_MISMATCH 拒,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- (2) EXPENSE_SUPPLIER_NOT_STATED:paid 的支出【合法地】没有供应商 ——
    --     那不是"不一致",是"没人说过";两件事,两个名字。
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_expense(DATE '2027-02-05', '1500', 100, v_ccy, NULL, 'paid', '1000',
            NULL, NULL, 'f5-2 no supplier',
            jsonb_build_object('asset_id', v_asset), NULL, v_line);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('EXPENSE_SUPPLIER_NOT_STATED' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 105F5-2 失败:挂在采购单行上而没有说出供应商的支出,应被 EXPENSE_SUPPLIER_NOT_STATED 拒(【不是】SUPPLIER_MISMATCH —— 拿 NULL 去比不是"不一致"),实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- (3) PO_NOT_APPROVED:自己建一套,把审批状态设成 pending
    v_res := record_expense(DATE '2027-01-05', '1500', 100, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'f5-3 machine',
        jsonb_build_object('description', 'f5-3', 'useful_life_months', 60), NULL);
    SELECT id INTO v_asset FROM fixed_assets WHERE expense_id = (v_res->>'expense_id')::uuid;
    v_res := create_purchase_order(v_sup, DATE '2027-01-10', DATE '2027-03-01', v_ccy, NULL,
        NULL, NULL, 'f5-3 PO',
        jsonb_build_array(jsonb_build_object('asset_id', v_asset, 'quantity', 1,
                                             'estimated_unit_price', 100)));
    v_po := (v_res->>'purchase_order_id')::uuid;
    SELECT id INTO v_line FROM purchase_order_lines WHERE purchase_order_id = v_po;
    -- 【前提要自己设成需要的样子】审批状态不走"修改"那条路(guard_po_amendable),
    -- 三个正当转换靠 po_status_ctx 放行 —— 这里就是在扮演那条转换。
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders SET approval_status = 'pending' WHERE id = v_po;
    PERFORM set_config('evoltrya.po_status_ctx', '0', true);
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_expense(DATE '2027-02-05', '1500', 100, v_ccy, NULL, 'unpaid', NULL,
            v_sup, NULL, 'f5-3 unapproved',
            jsonb_build_object('asset_id', v_asset), NULL, v_line);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('PO_NOT_APPROVED' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 105F5-3 失败:未获批的采购单不能计费,应被 PO_NOT_APPROVED 拒,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- (4) PO_CANCELLED:自己建一套,走真正的作废门
    v_res := record_expense(DATE '2027-01-05', '1500', 100, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'f5-4 machine',
        jsonb_build_object('description', 'f5-4', 'useful_life_months', 60), NULL);
    SELECT id INTO v_asset FROM fixed_assets WHERE expense_id = (v_res->>'expense_id')::uuid;
    v_res := create_purchase_order(v_sup, DATE '2027-01-10', DATE '2027-03-01', v_ccy, NULL,
        NULL, NULL, 'f5-4 PO',
        jsonb_build_array(jsonb_build_object('asset_id', v_asset, 'quantity', 1,
                                             'estimated_unit_price', 100)));
    v_po := (v_res->>'purchase_order_id')::uuid;
    SELECT id INTO v_line FROM purchase_order_lines WHERE purchase_order_id = v_po;
    PERFORM cancel_purchase_order(v_po, 'fixture 105 cancels it');
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_expense(DATE '2027-02-05', '1500', 100, v_ccy, NULL, 'unpaid', NULL,
            v_sup, NULL, 'f5-4 cancelled',
            jsonb_build_object('asset_id', v_asset), NULL, v_line);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('PO_CANCELLED' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 105F5-4 失败:已作废的采购单不能计费,应被 PO_CANCELLED 拒,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- (5) PO_NOT_FOUND:【"存在"= 没有被软删】。行还在,单已软删。
    v_res := record_expense(DATE '2027-01-05', '1500', 100, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'f5-5 machine',
        jsonb_build_object('description', 'f5-5', 'useful_life_months', 60), NULL);
    SELECT id INTO v_asset FROM fixed_assets WHERE expense_id = (v_res->>'expense_id')::uuid;
    v_res := create_purchase_order(v_sup, DATE '2027-01-10', DATE '2027-03-01', v_ccy, NULL,
        NULL, NULL, 'f5-5 PO',
        jsonb_build_array(jsonb_build_object('asset_id', v_asset, 'quantity', 1,
                                             'estimated_unit_price', 100)));
    v_po := (v_res->>'purchase_order_id')::uuid;
    SELECT id INTO v_line FROM purchase_order_lines WHERE purchase_order_id = v_po;
    -- 软删要走门(guard_soft_delete_provenance:直连 UPDATE 一律拒,且不许留空)。
    -- 这里扮演那扇门:设上下文 + 填齐 who/why —— 前提自己设,不指望默认值。
    PERFORM set_config('evoltrya.soft_delete_ctx', '1', true);
    UPDATE purchase_orders
       SET deleted_at = now(), deleted_by = v_user, delete_reason = 'fixture 105 soft-deletes it'
     WHERE id = v_po;
    PERFORM set_config('evoltrya.soft_delete_ctx', '0', true);
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_expense(DATE '2027-02-05', '1500', 100, v_ccy, NULL, 'unpaid', NULL,
            v_sup, NULL, 'f5-5 soft-deleted',
            jsonb_build_object('asset_id', v_asset), NULL, v_line);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('PO_NOT_FOUND' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 105F5-5 失败:已软删的采购单不能计费,应被 PO_NOT_FOUND 拒,实得 denied=% msg=% —— apply_prepayment 的那句 WHERE 也带着 deleted_at,少抄这一句就是少一道门',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- ══════════ F6 · 部分唯一索引 —— 按【索引名】断言 ══════════════════════
    RAISE NOTICE 'fixture 105 · 进入 %', 'F6';
    -- 自建一套并正常报销一次,然后【直插】一条撞行的支出。
    -- 直插绕过 record_expense 的推导,所以拒它的只可能是那条索引本身。
    v_res := record_expense(DATE '2027-01-05', '1500', 100, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'f6 machine',
        jsonb_build_object('description', 'f6', 'useful_life_months', 60), NULL);
    SELECT id INTO v_asset FROM fixed_assets WHERE expense_id = (v_res->>'expense_id')::uuid;
    v_res := create_purchase_order(v_sup, DATE '2027-01-10', DATE '2027-03-01', v_ccy, NULL,
        NULL, NULL, 'f6 PO',
        jsonb_build_array(jsonb_build_object('asset_id', v_asset, 'quantity', 1,
                                             'estimated_unit_price', 100)));
    v_po := (v_res->>'purchase_order_id')::uuid;
    SELECT id INTO v_line FROM purchase_order_lines WHERE purchase_order_id = v_po;
    v_res := record_expense(DATE '2027-02-05', '1500', 100, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'f6 invoice',
        jsonb_build_object('asset_id', v_asset), NULL, v_line);
    v_exp := (v_res->>'expense_id')::uuid;

    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO expenses (code, expense_date, account_code, amount_ccy, currency, fx_rate,
                              amount_base, payment_status, bank_account_code, purchase_order_line_id)
        VALUES ('ZZFIX105-DIRECT-2', DATE '2027-02-06', v_exp_acct, 100, v_ccy, 1, 100,
                'paid', '1000', v_line);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('uq_expenses_live_po_line' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 105F6 失败:直插一条与在册支出撞行的记录,应当撞上 uq_expenses_live_po_line,实得 denied=% msg=% —— 推导是第一层(可读),索引是第二层(正确);并发下两笔同时通过推导时,只有这一层拦得住',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- ══════════ F7 · 报销过的采购单行,删不得 ══════════════════════════════
    RAISE NOTICE 'fixture 105 · 进入 %', 'F7';
    -- 【为什么这一条必须有】设备行【没有收货】,所以既有的 PO_LINE_HAS_RECEIPTS
    -- 对它恒为假 —— 在本刀之前它一律删得掉;加了外键之后,删它会撞出一条【裸的】
    -- 23503。BEFORE DELETE 跑在外键之前,所以按名拒绝抢得到那个位置。
    v_denied := false; v_msg := NULL;
    BEGIN
        DELETE FROM purchase_order_lines WHERE id = v_line;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('PO_LINE_HAS_EXPENSE' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 105F7 失败:报销过的采购单行应被 PO_LINE_HAS_EXPENSE 拒,实得 denied=% msg=% —— 若这里报的是 23503 / foreign key,说明具名拒绝没有抢在外键前面,屏幕上会出现裸的约束违例',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- 冲销之后【仍然】删不得 —— 外键不认 status,判据必须与结构一致
    PERFORM reverse_expense(v_exp, 'fixture 105 F7');
    v_denied := false; v_msg := NULL;
    BEGIN
        DELETE FROM purchase_order_lines WHERE id = v_line;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('PO_LINE_HAS_EXPENSE' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 105F7b 失败:即便那笔支出已冲销,这条行仍然删不得(外键照样指着它),应被 PO_LINE_HAS_EXPENSE 拒,实得 denied=% msg=% —— 一条承诺得比外键多的判据,迟早会把 23503 打到人脸上',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    RAISE NOTICE 'fixture 105:F5–F7 通过';
END $$;
ROLLBACK;
