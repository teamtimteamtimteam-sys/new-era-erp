-- 197 PUR-1:采购单这张纸 —— 合同号、交货地点、逐行定价状态,而改单能改付款条款
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【每一臂钉什么,以及它【为什么】是这一臂而不是别的】
--
--  A 【交货地点走完一整圈】建单 → 打印 → 改单 → 打印 → 清空 → 打印。
--    ★ 三次都断言 po_document_data 的返回,而不是断言那一列的值 ★ ——
--      PDF 读的是那支函数,而不是那张表;断言表等于断言了一件与纸无关的事。
--    ★ 清空那一步是【第三种状态】★:'' 与 NULL 在 PDF 上说的是同一句话(不印),
--      但在"这次修改动没动它"这件事上完全不同 —— D 臂的档案会看见它。
--
--  B 【定价状态:选得动的方向与选不动的方向】
--    ★★ 本臂的要害是【不对称】★★:把一条没有公式的行标成 provisional 是真话;
--    把一条挂着公式的行标成 fixed 是一句**印在供应商纸上的假话**,按名拒。
--    四个既有状态一个都不许被这一列改坏 —— 所以 NULL(不选)那一行要断言它
--    印出来的东西与本刀之前【逐字相同】。
--    ★【两道闸都试】★ 写入那道(guard_po_line_price_status)按名拒;
--      而【读取那道】(po_document_data 的 CASE 排序)要单独证明:
--      本臂用一条直连 UPDATE 绕过守卫(先禁用触发器),把 price_status 写成
--      'fixed',再断言那张纸上印出来的【仍然】不是 FIXED。
--      **一道闸能被绕过的时候,第二道不是冗余** —— 这一句要有证据,不能只写在注释里。
--
--  C 【合同挂接的四条拒绝,逐条按【名】拒】
--    草稿 / 销售合同 / 另一家供应商 / 已经挂过。
--    ★ 这四条【不是本刀建的】—— CONTRACT-1 早就建好了(fixture 147 钉过其中两条)。
--      本刀建的是【屏幕】。所以这一臂的意义是:那扇新开的门通向的正是这四条,
--      而不是通向一个绕过它们的旁路。
--    ★ 还要断言【没挂合同的单印不出合同号】★ —— 一个空标签比不印更坏。
--    ★ 而合同号读的是【抄下来的那一份】★:挂上之后把 contracts.code 改掉,
--      再断言纸上印的仍是抄下来的那个 —— 一个"顺着外键回查"的实现在这里必定红。
--
--  D 【改单能改付款条款,而档案接得住 —— 本刀最要紧的一臂】
--    ★★ 三件事一起断言,少一件这一臂就会在真的坏掉时仍然通过 ★★:
--      ① 建单那一批期数【不进档案】(否则每张新单都先长出一份"全是新增"的历史);
--      ② 只改第二期,档案里【恰好】多出一行,而且是 payment_term_update / seq=2
--         —— 没动的第一、第三期【一行都不长】。这一条挡的是"整表删了重灌"那种实现;
--      ③ 那一行带着【理由】。理由是 PUR-2 立的规矩,付款条款照它办。
--    ★ 还要断言那道既有的定额腿闸【现在也管新传进来的计划】★。
--
--  E 【暂定价那一句的判据】一张全是定价的单,四个行状态里【没有】provisional_*;
--    一张有一条暂定价的单有。PDF 那一侧就是照这个布尔决定印不印
--    (hasProvisionalPrice)。★ 本臂不去读 TSX ★ —— 它钉的是喂给它的那份数据,
--    而措辞与位置由渲染出来的 PDF 去验(切次报告里那一条)。
--
--  F 【目录事实】新列、新 CHECK、新触发器、守卫函数是不是 SECURITY DEFINER。
--    查 pg_catalog,不 grep 源码 —— 注释里写一万遍也不会让一条约束存在。
--
--  G 【故障注入】两次,各打一条断言的要害;注入之后先断言【定义真的变了】,
--    变不了就当场报"这个注入什么也没删"。
--
-- 【自带数据】重建库里没有业务数据:自己建供应商、客户、物料、公式、合同、单据。
-- 日期落在 2027(README 第 4 条)。整段 ROLLBACK。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '180s';
DO $$
DECLARE
    v_user   uuid := gen_random_uuid();
    r_all    uuid;
    v_ccy    text;
    v_sup    uuid; v_sup2 uuid; v_cust uuid;
    v_mat    uuid; v_formula uuid;
    v_con_ok uuid; v_con_draft uuid; v_con_sell uuid; v_con_other uuid;
    v_po     uuid; v_po_plain uuid; v_po_terms uuid; v_po_fixed uuid;
    v_res    jsonb; v_doc jsonb;
    v_line   uuid; v_line_f uuid;
    v_denied boolean; v_msg text;
    v_n      integer; v_seq integer;
    v_def    text; v_def_after text;
    v_status text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-197', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- 【原样定义在任何注入之前取齐】(fixture 74/75 的教训)
    v_def := pg_get_functiondef('public.guard_po_line_price_status()'::regprocedure);

    -- 【默认税码要给】GST 注册着的时候,建单会按供应商的默认进项税码播种;
    -- 不给就撞 TAX_CODE_REQUIRED,而那是 fixture 190 钉的另一条规矩,不是本份要测的。
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, default_tax_code)
    VALUES ('ZZFIX197-S1', 'fixture 197 supplier one', 'SG', 'active', 'goods_supplier', 'TX')
    RETURNING id INTO v_sup;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, default_tax_code)
    VALUES ('ZZFIX197-S2', 'fixture 197 supplier two', 'SG', 'active', 'goods_supplier', 'TX')
    RETURNING id INTO v_sup2;
    INSERT INTO customers (code, legal_name, country, payment_terms_days)
    VALUES ('ZZFIX197-C1', 'fixture 197 customer', 'SG', 30) RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX197-M', 'fixture 197 material', 'battery_material', true,
            'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO pricing_formulas (code, name, direction, price_basis,
                                  treatment_charge_usd_per_tonne, flat_discount_pct, is_active)
    VALUES ('ZZFIX197-F', 'fixture 197 formula', 'purchase', 'spot', 200, 0, true)
    RETURNING id INTO v_formula;
    INSERT INTO pricing_formula_metals (formula_id, metal, payable_pct)
    VALUES (v_formula, 'ni', 70), (v_formula, 'co', 55);

    -- ══════════ A · 交货地点走完一整圈 ═════════════════════════════════════
    RAISE NOTICE 'fixture 197 · 进入 A(交货地点)';
    v_res := create_purchase_order(v_sup, DATE '2027-03-10', DATE '2027-05-01', v_ccy, NULL,
        'CIF', NULL, NULL,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100,
                                             'estimated_unit_price', 10)),
        '[]'::jsonb,
        'Workshop 3, 12 Tuas Avenue');
    v_po := (v_res->>'purchase_order_id')::uuid;

    v_doc := po_document_data(v_po);
    IF v_doc->>'delivery_location' IS DISTINCT FROM 'Workshop 3, 12 Tuas Avenue' THEN
        RAISE EXCEPTION 'FIXTURE 197A 失败:建单时给的交货地点应当出现在单据数据里,实得 %',
            COALESCE(v_doc->>'delivery_location', 'NULL');
    END IF;

    -- 改单改掉它
    PERFORM amend_purchase_order(v_po, '收货地点改到二号厂房',
        jsonb_build_object('delivery_location', 'Workshop 2, 12 Tuas Avenue'));
    v_doc := po_document_data(v_po);
    IF v_doc->>'delivery_location' IS DISTINCT FROM 'Workshop 2, 12 Tuas Avenue' THEN
        RAISE EXCEPTION 'FIXTURE 197A 失败:改单之后应当印新地点,实得 %',
            COALESCE(v_doc->>'delivery_location', 'NULL');
    END IF;
    -- 【档案接住了它】—— 与付款条款同一条规矩:改了商业字段而档案沉默,就是缺陷
    SELECT count(*) INTO v_n FROM purchase_order_history
     WHERE purchase_order_id = v_po AND change_type = 'header_update'
       AND old_delivery_location = 'Workshop 3, 12 Tuas Avenue'
       AND new_delivery_location = 'Workshop 2, 12 Tuas Avenue'
       AND amend_reason = '收货地点改到二号厂房';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 197A 失败:交货地点的改动应当在档案里【恰好】留下一行(带理由),实得 %', v_n;
    END IF;

    -- 【第三种状态:清空】'' 在函数里收成 NULL,纸上什么都不印
    PERFORM amend_purchase_order(v_po, '这一单不指定交货地点',
        jsonb_build_object('delivery_location', ''));
    v_doc := po_document_data(v_po);
    IF v_doc->>'delivery_location' IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 197A 失败:清空之后应当是 NULL(纸上整格不印),实得 %',
            v_doc->>'delivery_location';
    END IF;
    -- 【不传这个键 = 不动它】—— 与"传空串"必须分得开
    PERFORM amend_purchase_order(v_po, '只改预计到货,不碰交货地点',
        jsonb_build_object('expected_delivery_date', '2027-06-01'));
    IF (SELECT delivery_location FROM purchase_orders WHERE id = v_po) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 197A 失败:不传 delivery_location 这个键时不该动它';
    END IF;

    -- ══════════ B · 定价状态:两个方向不对称 ═══════════════════════════════
    RAISE NOTICE 'fixture 197 · 进入 B(定价状态)';
    -- 一张单四条行:①有价不选 ②有价标 provisional ③无价无公式不选 ④挂公式
    v_res := create_purchase_order(v_sup, DATE '2027-03-11', NULL, v_ccy, NULL, NULL, NULL, NULL,
        jsonb_build_array(
            jsonb_build_object('line_no', 1, 'material_id', v_mat, 'quantity', 10,
                               'estimated_unit_price', 5),
            jsonb_build_object('line_no', 2, 'material_id', v_mat, 'quantity', 10,
                               'estimated_unit_price', 5, 'price_status', 'provisional'),
            jsonb_build_object('line_no', 3, 'material_id', v_mat, 'quantity', 10),
            jsonb_build_object('line_no', 4, 'material_id', v_mat, 'quantity', 10,
                               'pricing_formula_id', v_formula)),
        '[]'::jsonb, NULL);
    v_po_plain := (v_res->>'purchase_order_id')::uuid;
    v_doc := po_document_data(v_po_plain);

    -- 【不选的那三行与本刀之前逐字相同】这一条挡的是"新列把既有行印坏了"
    IF (v_doc->'lines'->0->>'pricing_status') <> 'fixed' THEN
        RAISE EXCEPTION 'FIXTURE 197B 失败:有单价、没选状态的行应当仍然印 fixed,实得 %',
            v_doc->'lines'->0->>'pricing_status';
    END IF;
    IF (v_doc->'lines'->2->>'pricing_status') <> 'not_priced' THEN
        RAISE EXCEPTION 'FIXTURE 197B 失败:没价没公式的行应当仍然印 not_priced,实得 %',
            v_doc->'lines'->2->>'pricing_status';
    END IF;
    IF (v_doc->'lines'->3->>'pricing_status') <> 'provisional_committed' THEN
        RAISE EXCEPTION 'FIXTURE 197B 失败:挂公式的行建单时抄下了条款,应当印 provisional_committed,实得 %',
            v_doc->'lines'->3->>'pricing_status';
    END IF;
    -- ★【选得动的那个方向:一条没有公式的行,被人标成暂定价】★ 本刀补的就是它
    IF (v_doc->'lines'->1->>'pricing_status') <> 'provisional_uncommitted' THEN
        RAISE EXCEPTION 'FIXTURE 197B 失败:被标成 provisional 的行应当印暂定价,实得 % —— 这正是本刀补上的那个能力',
            v_doc->'lines'->1->>'pricing_status';
    END IF;

    -- ★【选不动的那个方向:按名拒】★ 建单这条路
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM create_purchase_order(v_sup, DATE '2027-03-12', NULL, v_ccy, NULL, NULL, NULL, NULL,
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 10,
                'pricing_formula_id', v_formula, 'price_status', 'fixed')),
            '[]'::jsonb, NULL);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'PO_LINE_PRICE_STATUS_CONFLICT%' THEN
        RAISE EXCEPTION 'FIXTURE 197B 失败:挂着公式的行标成 fixed 应当按名拒(PO_LINE_PRICE_STATUS_CONFLICT),实得 %',
            COALESCE(v_msg, '(没有拒绝)');
    END IF;

    -- 改单这条路也拒
    SELECT id INTO v_line_f FROM purchase_order_lines
     WHERE purchase_order_id = v_po_plain AND line_no = 4;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM amend_purchase_order(v_po_plain, '试着把公式行标成定价', NULL,
            jsonb_build_array(jsonb_build_object('id', v_line_f, 'quantity', 10,
                                                 'price_status', 'fixed')));
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'PO_LINE_PRICE_STATUS_CONFLICT%' THEN
        RAISE EXCEPTION 'FIXTURE 197B 失败:改单把公式行标成 fixed 也应当按名拒,实得 %',
            COALESCE(v_msg, '(没有拒绝)');
    END IF;

    -- 一个不认识的取值按名拒,而不是让表上那条 CHECK 吐一句裸约束
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM create_purchase_order(v_sup, DATE '2027-03-12', NULL, v_ccy, NULL, NULL, NULL, NULL,
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 10,
                'estimated_unit_price', 1, 'price_status', 'maybe')),
            '[]'::jsonb, NULL);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'PO_LINE_PRICE_STATUS_INVALID%' THEN
        RAISE EXCEPTION 'FIXTURE 197B 失败:不认识的定价状态应当按名拒,实得 %',
            COALESCE(v_msg, '(没有拒绝)');
    END IF;

    -- ★★【第二道闸:绕过守卫,那张纸上仍然印不出假的 FIXED】★★
    --   这一段【故意】把触发器停掉再直连写脏数据 —— 它模拟的是"比这道闸更老的行",
    --   以及将来任何一条新的写入路径。若 po_document_data 的 CASE 排序被人调换,
    --   这一条会当场变红,而那正是它存在的理由。
    -- 【先把延迟约束逼到 IMMEDIATE】本表上有一条 DEFERRABLE INITIALLY DEFERRED 的
    -- 混装守卫(EQP-1a),它排着的事件会让 ALTER TABLE 拒绝执行
    -- ("has pending trigger events")。这不是本臂要测的东西,清掉它再动。
    SET CONSTRAINTS ALL IMMEDIATE;
    ALTER TABLE purchase_order_lines DISABLE TRIGGER guard_po_line_price_status;
    UPDATE purchase_order_lines SET price_status = 'fixed' WHERE id = v_line_f;
    ALTER TABLE purchase_order_lines ENABLE TRIGGER guard_po_line_price_status;
    v_doc := po_document_data(v_po_plain);
    IF (v_doc->'lines'->3->>'pricing_status') <> 'provisional_committed' THEN
        RAISE EXCEPTION 'FIXTURE 197B 失败:【读取那道闸】没挡住 —— 一行已经抄下结算条款、price_status 被写成 fixed,纸上印的却是 %。CASE 里"有承诺/挂公式"两支必须排在 price_status 之前',
            v_doc->'lines'->3->>'pricing_status';
    END IF;
    -- 复原,免得后面的臂读到脏数据
    SET CONSTRAINTS ALL IMMEDIATE;
    ALTER TABLE purchase_order_lines DISABLE TRIGGER guard_po_line_price_status;
    UPDATE purchase_order_lines SET price_status = NULL WHERE id = v_line_f;
    ALTER TABLE purchase_order_lines ENABLE TRIGGER guard_po_line_price_status;
    SET CONSTRAINTS ALL DEFERRED;

    -- ══════════ C · 合同挂接:四条拒绝,以及抄不是引用 ══════════════════════
    RAISE NOTICE 'fixture 197 · 进入 C(合同)';
    INSERT INTO contracts (supplier_id, kind, title, effective_from, status,
                           currency, incoterm, payment_terms_days)
    VALUES (v_sup, 'supply', 'fixture 197 active supply', '2027-01-01', 'active',
            v_ccy, 'CIF', 45)
    RETURNING id INTO v_con_ok;
    INSERT INTO contracts (supplier_id, kind, title, effective_from, status)
    VALUES (v_sup, 'supply', 'fixture 197 draft supply', '2027-01-01', 'draft')
    RETURNING id INTO v_con_draft;
    INSERT INTO contracts (customer_id, kind, title, effective_from, status)
    VALUES (v_cust, 'offtake', 'fixture 197 offtake', '2027-01-01', 'active')
    RETURNING id INTO v_con_sell;
    INSERT INTO contracts (supplier_id, kind, title, effective_from, status)
    VALUES (v_sup2, 'supply', 'fixture 197 other supplier', '2027-01-01', 'active')
    RETURNING id INTO v_con_other;

    -- 【没挂合同的单印不出合同号】—— 一个空标签比不印更坏
    v_doc := po_document_data(v_po);
    IF v_doc->>'contract_code' IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 197C 失败:没挂合同的单据不该有合同号,实得 %', v_doc->>'contract_code';
    END IF;

    -- 拒绝一:草稿合同
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM link_document_to_contract('purchase_order', v_po, v_con_draft);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'CONTRACT_NOT_ACTIVE%' THEN
        RAISE EXCEPTION 'FIXTURE 197C 失败:草稿合同应当按名拒(CONTRACT_NOT_ACTIVE),实得 %',
            COALESCE(v_msg, '(没有拒绝)');
    END IF;

    -- 拒绝二:销售合同背不起采购单
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM link_document_to_contract('purchase_order', v_po, v_con_sell);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'CONTRACT_SIDE_MISMATCH%' THEN
        RAISE EXCEPTION 'FIXTURE 197C 失败:销售合同应当按名拒(CONTRACT_SIDE_MISMATCH),实得 %',
            COALESCE(v_msg, '(没有拒绝)');
    END IF;

    -- 拒绝三:另一家供应商的合同
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM link_document_to_contract('purchase_order', v_po, v_con_other);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'CONTRACT_COUNTERPARTY_MISMATCH%' THEN
        RAISE EXCEPTION 'FIXTURE 197C 失败:另一家供应商的合同应当按名拒(CONTRACT_COUNTERPARTY_MISMATCH),实得 %',
            COALESCE(v_msg, '(没有拒绝)');
    END IF;

    -- 挂得上的那一份:合同号出现在单据数据里
    PERFORM link_document_to_contract('purchase_order', v_po, v_con_ok);
    v_doc := po_document_data(v_po);
    IF v_doc->>'contract_code' IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 197C 失败:挂上合同之后单据数据里应当有合同号';
    END IF;
    v_msg := v_doc->>'contract_code';
    IF v_msg <> (SELECT code FROM contracts WHERE id = v_con_ok) THEN
        RAISE EXCEPTION 'FIXTURE 197C 失败:印出来的合同号应当是这一份合同的编号,实得 %', v_msg;
    END IF;

    -- 拒绝四:已经挂过就不改挂
    v_denied := false;
    BEGIN PERFORM link_document_to_contract('purchase_order', v_po, v_con_ok);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'DOCUMENT_ALREADY_UNDER_CONTRACT%' THEN
        RAISE EXCEPTION 'FIXTURE 197C 失败:重复挂接应当按名拒(DOCUMENT_ALREADY_UNDER_CONTRACT),实得 %',
            COALESCE(v_msg, '(没有拒绝)');
    END IF;

    -- ★★【抄不是引用:改掉合同编号,已挂单据印的仍是抄下来的那个】★★
    v_msg := (SELECT code FROM contracts WHERE id = v_con_ok);
    UPDATE contracts SET code = 'ZZFIX197-RENAMED' WHERE id = v_con_ok;
    v_doc := po_document_data(v_po);
    IF v_doc->>'contract_code' <> v_msg THEN
        RAISE EXCEPTION 'FIXTURE 197C 失败:合同改名之后,已挂单据印的应当仍是【抄下来的】那个编号 %,实得 % —— 一个顺着 contract_id 回查 contracts 的实现在这里必定红',
            v_msg, v_doc->>'contract_code';
    END IF;

    -- ══════════ D · 改单能改付款条款,而档案接得住 ═══════════════════════════
    RAISE NOTICE 'fixture 197 · 进入 D(付款条款)';
    v_res := create_purchase_order(v_sup, DATE '2027-04-01', NULL, v_ccy, NULL, NULL, NULL, NULL,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100,
                                             'estimated_unit_price', 10)),
        jsonb_build_array(
            jsonb_build_object('seq', 1, 'label', 'deposit',  'percentage', 30, 'trigger_event', 'on_order'),
            jsonb_build_object('seq', 2, 'label', 'delivery', 'percentage', 40, 'trigger_event', 'on_arrival'),
            jsonb_build_object('seq', 3, 'label', 'final',    'percentage', 30, 'trigger_event', 'post_assay')),
        NULL);
    v_po_terms := (v_res->>'purchase_order_id')::uuid;

    -- ① 建单那一批期数【不进档案】
    SELECT count(*) INTO v_n FROM purchase_order_history
     WHERE purchase_order_id = v_po_terms AND change_type LIKE 'payment_term_%';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 197D 失败:建单那一批期数不该进档案(否则每张新单都先长出一份"全是新增"的历史),实得 % 行', v_n;
    END IF;

    -- ② 只改第二期
    PERFORM amend_purchase_order(v_po_terms, '与供应商重谈:到货付 30%,尾款 40%', NULL, NULL,
        jsonb_build_array(
            jsonb_build_object('seq', 1, 'label', 'deposit',  'percentage', 30, 'trigger_event', 'on_order'),
            jsonb_build_object('seq', 2, 'label', 'delivery', 'percentage', 30, 'trigger_event', 'on_arrival'),
            jsonb_build_object('seq', 3, 'label', 'final',    'percentage', 40, 'trigger_event', 'post_assay')));

    -- 库里真的改了
    SELECT percentage INTO v_n FROM purchase_order_payment_terms
     WHERE purchase_order_id = v_po_terms AND seq = 2;
    IF v_n <> 30 THEN
        RAISE EXCEPTION 'FIXTURE 197D 失败:第二期应当已经改成 30%%,实得 %', v_n;
    END IF;

    -- ★ 档案里【恰好】两行(第二期与第三期各一次改动),第一期一行都不长 ★
    SELECT count(*) INTO v_n FROM purchase_order_history
     WHERE purchase_order_id = v_po_terms AND change_type = 'payment_term_update';
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 197D 失败:只改了第二、三期,档案里应当恰好两行 payment_term_update,实得 % —— 一个"整表删了重灌"的实现在这里会得到 6 行(3 删 3 增)', v_n;
    END IF;
    SELECT count(*) INTO v_n FROM purchase_order_history
     WHERE purchase_order_id = v_po_terms AND payment_term_seq = 1;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 197D 失败:没动过的第一期不该在档案里留下任何一行,实得 %', v_n;
    END IF;

    -- ③ 那一行带着理由,而且前后两份快照都在
    SELECT count(*) INTO v_n FROM purchase_order_history
     WHERE purchase_order_id = v_po_terms AND change_type = 'payment_term_update'
       AND payment_term_seq = 2
       AND (old_payment_term->>'percentage')::numeric = 40
       AND (new_payment_term->>'percentage')::numeric = 30
       AND amend_reason = '与供应商重谈:到货付 30%,尾款 40%';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 197D 失败:第二期那一行应当带着前后快照与理由,实得 % 行', v_n;
    END IF;

    -- 删掉一期 → payment_term_remove
    PERFORM amend_purchase_order(v_po_terms, '尾款并进到货款', NULL, NULL,
        jsonb_build_array(
            jsonb_build_object('seq', 1, 'label', 'deposit',  'percentage', 30, 'trigger_event', 'on_order'),
            jsonb_build_object('seq', 2, 'label', 'delivery', 'percentage', 70, 'trigger_event', 'on_arrival')));
    SELECT count(*) INTO v_n FROM purchase_order_history
     WHERE purchase_order_id = v_po_terms AND change_type = 'payment_term_remove'
       AND payment_term_seq = 3;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 197D 失败:删掉第三期应当留下一行 payment_term_remove,实得 %', v_n;
    END IF;

    -- 【那道既有的定额腿闸,现在也管新传进来的计划】
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM amend_purchase_order(v_po_terms, '试着塞一条对不上的定额腿', NULL, NULL,
            jsonb_build_array(jsonb_build_object('seq', 1, 'label', 'lump',
                'fixed_amount_ccy', 1, 'trigger_event', 'on_order')));
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'PO_PLAN_FIXED_MISMATCH%' THEN
        RAISE EXCEPTION 'FIXTURE 197D 失败:定额腿加不到订单总额时应当按名拒(PO_PLAN_FIXED_MISMATCH),实得 %',
            COALESCE(v_msg, '(没有拒绝)');
    END IF;

    -- 【不传这个参数 = 不动付款计划】—— 与传 [] 必须分得开
    PERFORM amend_purchase_order(v_po_terms, '只改数量,不碰付款计划', NULL,
        jsonb_build_array(jsonb_build_object(
            'id', (SELECT id FROM purchase_order_lines WHERE purchase_order_id = v_po_terms LIMIT 1),
            'quantity', 101)));
    SELECT count(*) INTO v_n FROM purchase_order_payment_terms WHERE purchase_order_id = v_po_terms;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 197D 失败:不传 p_payment_terms 时付款计划不该动,实得 % 期', v_n;
    END IF;

    -- ══════════ E · 暂定价那一句的判据 ═════════════════════════════════════
    RAISE NOTICE 'fixture 197 · 进入 E(暂定价那一句)';
    -- 全是定价的那一张:四个行状态里没有 provisional_*
    v_res := create_purchase_order(v_sup, DATE '2027-04-05', NULL, v_ccy, NULL, NULL, NULL, NULL,
        jsonb_build_array(
            jsonb_build_object('line_no', 1, 'material_id', v_mat, 'quantity', 10, 'estimated_unit_price', 5),
            jsonb_build_object('line_no', 2, 'material_id', v_mat, 'quantity', 10, 'estimated_unit_price', 7)),
        '[]'::jsonb, NULL);
    v_po_fixed := (v_res->>'purchase_order_id')::uuid;
    v_doc := po_document_data(v_po_fixed);
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_doc->'lines') l
     WHERE l->>'pricing_status' LIKE 'provisional%';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 197E 失败:一张全是定价的单不该有任何暂定价的行,实得 % 条 —— PDF 会据此印出一句不成立的陈述', v_n;
    END IF;
    -- 【非空由构造保证】:这张单真的有行,否则"零条暂定价"是一次空转
    IF jsonb_array_length(v_doc->'lines') <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 197E 失败:这张单应当有两行,否则上一条断言是空转';
    END IF;

    -- 有一条暂定价的那一张(B 臂那一张):恰好两条
    v_doc := po_document_data(v_po_plain);
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_doc->'lines') l
     WHERE l->>'pricing_status' LIKE 'provisional%';
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 197E 失败:那张单上应当恰好两条暂定价的行(一条被人标的、一条挂公式的),实得 %', v_n;
    END IF;

    -- ══════════ F · 目录事实(查目录,不 grep 源码)═══════════════════════════
    RAISE NOTICE 'fixture 197 · 进入 F(目录)';
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema='public' AND table_name='purchase_orders'
                      AND column_name='delivery_location') THEN
        RAISE EXCEPTION 'FIXTURE 197F 失败:purchase_orders.delivery_location 不存在'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname='purchase_order_lines_price_status_check') THEN
        RAISE EXCEPTION 'FIXTURE 197F 失败:price_status 的取值 CHECK 不存在 —— 注释里写一万遍也不会让它存在'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger
                    WHERE tgname='trg_purchase_order_payment_terms_history' AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'FIXTURE 197F 失败:付款计划的留痕触发器不存在 —— 那条改单路径会在档案里沉默'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger
                    WHERE tgname='guard_po_line_price_status' AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'FIXTURE 197F 失败:定价状态的守卫触发器不存在'; END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid='public.guard_po_line_price_status()'::regprocedure) THEN
        RAISE EXCEPTION 'FIXTURE 197F 失败:守卫函数应当是 SECURITY DEFINER —— 它要读 pricing_term_commitments'; END IF;
    -- 【两张遮蔽视图都要认得新列】加列 = 三件事(列 + 列级授权 + _masked),
    -- 少一件就"写得进、读不出",而且一个字的报错都不会有(KPI-1 付过这笔账)
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema='public' AND table_name='purchase_orders_masked'
                      AND column_name='delivery_location') THEN
        RAISE EXCEPTION 'FIXTURE 197F 失败:purchase_orders_masked 里没有 delivery_location'; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema='public' AND table_name='purchase_order_lines_masked'
                      AND column_name='price_status') THEN
        RAISE EXCEPTION 'FIXTURE 197F 失败:purchase_order_lines_masked 里没有 price_status'; END IF;

    -- ══════════ G · 故障注入 ═══════════════════════════════════════════════
    RAISE NOTICE 'fixture 197 · 进入 G(注入)';
    -- 注入一:把守卫函数掏空 —— B 臂那条"选不动的方向"必须当场变红
    EXECUTE $inj$
        CREATE OR REPLACE FUNCTION public.guard_po_line_price_status()
        RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
        SET search_path TO 'public','pg_temp'
        AS $f$ BEGIN RETURN NEW; END $f$;
    $inj$;
    v_def_after := pg_get_functiondef('public.guard_po_line_price_status()'::regprocedure);
    IF v_def_after = v_def THEN
        RAISE EXCEPTION 'FIXTURE 197G 失败:这个注入什么也没改 —— 一个什么都没注入的注入,长得和一个通过了的注入一模一样';
    END IF;
    v_denied := false;
    BEGIN
        PERFORM create_purchase_order(v_sup, DATE '2027-03-12', NULL, v_ccy, NULL, NULL, NULL, NULL,
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 10,
                'pricing_formula_id', v_formula, 'price_status', 'fixed')),
            '[]'::jsonb, NULL);
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 197G 失败:守卫被掏空之后那条拒绝【还在】—— 说明 B 臂拒的不是这道闸,断言指错了地方';
    END IF;
    -- 复原
    EXECUTE format('%s', v_def);
    IF pg_get_functiondef('public.guard_po_line_price_status()'::regprocedure) <> v_def THEN
        RAISE EXCEPTION 'FIXTURE 197G 失败:守卫函数没有复原';
    END IF;

    -- 注入二:把付款计划的留痕触发器停掉 —— D 臂必须当场变红
    ALTER TABLE purchase_order_payment_terms DISABLE TRIGGER trg_purchase_order_payment_terms_history;
    SELECT count(*) INTO v_n FROM purchase_order_history
     WHERE purchase_order_id = v_po_terms AND change_type LIKE 'payment_term_%';
    v_seq := v_n;
    PERFORM amend_purchase_order(v_po_terms, '注入期间的一次改动', NULL, NULL,
        jsonb_build_array(
            jsonb_build_object('seq', 1, 'label', 'deposit',  'percentage', 20, 'trigger_event', 'on_order'),
            jsonb_build_object('seq', 2, 'label', 'delivery', 'percentage', 80, 'trigger_event', 'on_arrival')));
    SELECT count(*) INTO v_n FROM purchase_order_history
     WHERE purchase_order_id = v_po_terms AND change_type LIKE 'payment_term_%';
    IF v_n <> v_seq THEN
        RAISE EXCEPTION 'FIXTURE 197G 失败:触发器停掉之后档案【还在长】—— 说明 D 臂断言的不是这支触发器';
    END IF;
    ALTER TABLE purchase_order_payment_terms ENABLE TRIGGER trg_purchase_order_payment_terms_history;

    RAISE NOTICE 'FIXTURE 197 全部通过:交货地点走完一圈 · 定价状态两个方向不对称(两道闸各证一次)· 合同四条拒绝按名 · 抄不是引用 · 改单改得了付款条款而档案按期接住 · 暂定价那一句的判据 · 目录事实 · 两次注入各打中一条断言';
END $$;
ROLLBACK;
