-- 103 采购单装得下一台机器 —— 而门是【移动】了,不是【拓宽】了
--
-- 【这份 fixture 自带全部数据】线上 fixed_assets / fixed_asset_cost_entries /
-- fixed_asset_depreciation 三张表都是 0 行,而重建库【连业务数据都没有】。
-- 所以每一臂都自己造:一家供货商 + 一个物料 + 一台资产(经 record_expense 的
-- 资本分支,科目 1500 + p_asset)+ 各自的采购单。**不从任何地方借**。
--
-- 【六臂,以及每一臂钉的是什么】
-- F1 XOR 两个方向:都不给 → 拒;都给 → 拒。**按约束名断言**,不只是"失败了"。
-- F2 对设备行收货 → 按名拒 PO_LINE_EQUIPMENT_NOT_RECEIVABLE(断言那个码本身)。
-- F3 门【移动】不是【拓宽】:普通材料行照旧建得出、收得进。
--    **先断言前提再断言派生量** —— 材料路径若本来就断了,后面每一条都是空转。
-- F4 N1 混装两个【顺序】都要拒:材料单上加设备行、设备单上加材料行。
--    对称性才是证明 —— 单一方向可能因为别的理由碰巧通过。
-- F5 po_document_data 要【返回】设备行。**先断言那一行在,再断言它的内容** ——
--    被钉的缺陷是"整行消失",而对着空结果做内容断言恒真。
-- F6 门移动不是拓宽(第二半):既有材料单的【改单】与【单据】原样。
--
-- 【N1 是延迟的约束触发器】所以要 SET CONSTRAINTS ALL IMMEDIATE 才会在块内触发
-- (README 第 3 条那一句);用毕还原。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid;
    v_sup uuid; v_mat uuid; v_ccy text;
    v_asset uuid; v_res jsonb;
    po_mat uuid; po_eqp uuid; po_a4 uuid; line_mat uuid; line_eqp uuid;
    v_n int; v_msg text; v_denied boolean; v_doc jsonb;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-103', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX103-S', 'fixture 103 supplier', 'SG', 'active', 'goods_supplier')
    RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, category)
    VALUES ('ZZFIX103-M', 'fixture 103 material', 'other') RETURNING id INTO v_mat;

    -- 一台【已经建了卡】的资产 —— D1:行引用它,行不创建它
    v_res := record_expense(DATE '2027-01-05', '1500', 50000, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'fixture 103 machine',
        jsonb_build_object('description', 'fixture 103 press', 'useful_life_months', 120), NULL);
    SELECT id INTO v_asset FROM fixed_assets WHERE expense_id = (v_res->>'expense_id')::uuid;
    IF v_asset IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 103 前提失败:资本支出没有生成资产卡 —— 后面每一臂都无从谈起';
    END IF;

    -- ══════════ F1 · XOR 两个方向 ═══════════════════════════════════════════
    v_res := create_purchase_order(v_sup, DATE '2027-01-10', DATE '2027-03-01', v_ccy, NULL,
        NULL, NULL, 'fixture 103 material PO',
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100,
                                             'estimated_unit_price', 10)));
    po_mat := (v_res->>'purchase_order_id')::uuid;
    SELECT id INTO line_mat FROM purchase_order_lines WHERE purchase_order_id = po_mat;

    -- 【都不给】—— 直插,因为要证明的是【表】上的拒绝,不是 RPC 的拒绝
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO purchase_order_lines (purchase_order_id, line_no, quantity, unit)
        VALUES (po_mat, 90, 1, 'unit');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('purchase_order_lines_material_xor_asset' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 103F1 失败:两列都空的行应当被 purchase_order_lines_material_xor_asset 拒,实得 denied=% msg=% —— XOR 若只写在应用里,直插就绕过去了',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- 【都给】
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, asset_id, quantity, unit)
        VALUES (po_mat, 91, v_mat, v_asset, 1, 'unit');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('purchase_order_lines_material_xor_asset' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 103F1 失败:两列都给的行也应当被同一条约束拒,实得 denied=% msg=% —— 只钉一个方向的 XOR 不是 XOR',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- ══════════ F3 · 门【移动】不是【拓宽】(第一半:建单 + 收货)═══════════
    -- 【先断言前提】材料路径本来就得是通的,否则下面"照旧"证明不了任何事。
    SELECT count(*) INTO v_n FROM purchase_order_lines
     WHERE purchase_order_id = po_mat AND material_id = v_mat AND asset_id IS NULL;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 103F3 前提失败:普通材料行应当照旧建得出来(1 行),实得 % 行', v_n;
    END IF;
    UPDATE purchase_orders SET status = 'confirmed' WHERE id = po_mat;
    v_res := receive_inbound_batch_against_po(v_mat, v_sup, 40, DATE '2027-02-01',
        'fixture 103 receipt', po_mat, line_mat, NULL, NULL);
    SELECT count(*) INTO v_n FROM inbound_batches
     WHERE purchase_order_line_id = line_mat AND deleted_at IS NULL;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 103F3 失败:材料行照旧收得进货(应 1 个批次),实得 % —— 这一刀不许动既有材料行的行为', v_n;
    END IF;

    -- ══════════ F4 · N1 混装,两个顺序都拒 ══════════════════════════════════
    -- 【延迟的约束触发器,所以要让它在块内触发】
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO purchase_order_lines (purchase_order_id, line_no, asset_id, quantity, unit)
        VALUES (po_mat, 92, v_asset, 1, 'unit');
        SET CONSTRAINTS ALL IMMEDIATE;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    SET CONSTRAINTS ALL DEFERRED;
    IF NOT v_denied OR position('PO_LINES_MIXED_KINDS' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 103F4 失败(材料单 → 加设备行):应当按名拒 PO_LINES_MIXED_KINDS,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- 【反方向】设备单上加材料行 —— 对称性才是证明
    v_res := create_purchase_order(v_sup, DATE '2027-01-11', DATE '2027-06-01', v_ccy, NULL,
        NULL, NULL, 'fixture 103 equipment PO',
        jsonb_build_array(jsonb_build_object('asset_id', v_asset, 'quantity', 1,
                                             'unit', 'unit', 'estimated_unit_price', 50000)));
    po_eqp := (v_res->>'purchase_order_id')::uuid;
    SELECT id INTO line_eqp FROM purchase_order_lines WHERE purchase_order_id = po_eqp;
    IF line_eqp IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 103F4 前提失败:设备采购单没建出来 —— 受支持的门必须造得出设备行(否则这一列没有门)';
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
        VALUES (po_eqp, 93, v_mat, 5, 'kg');
        SET CONSTRAINTS ALL IMMEDIATE;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    SET CONSTRAINTS ALL DEFERRED;
    IF NOT v_denied OR position('PO_LINES_MIXED_KINDS' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 103F4 失败(设备单 → 加材料行):反方向也必须按名拒,实得 denied=% msg=% —— 单一方向可能因为别的理由碰巧通过',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- ══════════ F2 · 设备行不可收货,按名拒 ═════════════════════════════════
    UPDATE purchase_orders SET status = 'confirmed' WHERE id = po_eqp;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM receive_inbound_batch_against_po(v_mat, v_sup, 1, DATE '2027-06-05',
            'fixture 103 machine receipt', po_eqp, line_eqp, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('PO_LINE_EQUIPMENT_NOT_RECEIVABLE' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 103F2 失败:对设备行收货应当按名拒 PO_LINE_EQUIPMENT_NOT_RECEIVABLE,实得 denied=% msg=% —— 机器到货不是一次入库',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- ══════════ F5 · 采购单上【印得出】那台机器 ═════════════════════════════
    v_doc := po_document_data(po_eqp);
    -- 【先断言那一行在】被钉的缺陷是"整行消失",对着空结果做内容断言恒真
    SELECT jsonb_array_length(v_doc->'lines') INTO v_n;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 103F5 失败:设备采购单的单据应当有 1 行,实得 % 行 —— INNER JOIN materials 会让设备行从打印出来的采购单上整行消失,而单据其余部分照常成立(没有错误、没有空行)',
            v_n;
    END IF;
    -- 行在了,才谈得上内容
    IF (v_doc->'lines'->0->>'material_name') IS DISTINCT FROM 'fixture 103 press' THEN
        RAISE EXCEPTION 'FIXTURE 103F5 失败:那一行的名字应当回退到资产描述,实得 %',
            COALESCE(v_doc->'lines'->0->>'material_name', '(空)');
    END IF;

    -- ══════════ A · EQP-1a-TAIL:两条【约定】现在是【规则】 ═════════════════
    -- 【这一段钉的是"忘了填"这件事】此前 quantity = 1 / unit = 'unit' 只活在
    -- 这份 fixture 里,而 unit 的列默认值是 'kg' —— 一条省略了 unit 的设备行会
    -- 【无声地变成公斤】,再被 ordered_qty 那个不看单位的 sum 加进去。
    -- 约定挡不住"忘了填",CHECK 挡得住。三臂都用【直插】,因为要证的是
    -- 【表】上的拒绝,不是 RPC 的拒绝(RPC 那一层另有具名拒绝,见迁移 T3)。

    -- A4 · 【前提先立】材料行照旧:'kg' + 任意数量,插得进去
    -- 【自己一张单】—— 第一版往 po_mat 上加行,把 F6 那条"单据恰一行"的前提搅了
    -- (README 第 2 条:用例之间不共享可变状态,否则会因为错的理由红/绿)。
    v_res := create_purchase_order(v_sup, DATE '2027-01-12', DATE '2027-04-01', v_ccy, NULL,
        NULL, NULL, 'fixture 103 A4 material PO',
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 250,
                                             'unit', 'kg', 'estimated_unit_price', 3)));
    po_a4 := (v_res->>'purchase_order_id')::uuid;
    SELECT count(*) INTO v_n FROM purchase_order_lines
     WHERE purchase_order_id = po_a4 AND unit = 'kg' AND quantity = 250;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 103A4 前提失败:材料行应当照旧插得进(kg + 任意数量),实得 % —— 前提不成立的话,下面两条拒绝证明不了"只拦设备行"',
            v_n;
    END IF;

    -- A1 · 设备行【省略 unit】→ 落到列默认值 'kg' → 必须被拒(本刀的全部理由)
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO purchase_order_lines (purchase_order_id, line_no, asset_id, quantity)
        VALUES (po_eqp, 81, v_asset, 1);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('purchase_order_lines_equipment_unit' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 103A1 失败:省略 unit 的设备行必须被 purchase_order_lines_equipment_unit 拒,实得 denied=% msg=% —— 不拒就是【无声变成公斤】,而那正是这一刀存在的理由',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- A2 · 设备行 quantity <> 1 → 必须被拒
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO purchase_order_lines (purchase_order_id, line_no, asset_id, quantity, unit)
        VALUES (po_eqp, 82, v_asset, 5, 'unit');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('purchase_order_lines_equipment_qty_one' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 103A2 失败:quantity <> 1 的设备行必须被 purchase_order_lines_equipment_qty_one 拒,实得 denied=% msg=% —— 四台机器是四条行,各有各的资产卡与投用日',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- ══════════ F6 · 门移动不是拓宽(第二半:改单 + 单据)═══════════════════
    v_res := amend_purchase_order(po_mat, 'fixture 103:改数量',
        NULL, jsonb_build_array(jsonb_build_object('id', line_mat, 'quantity', 120)));
    SELECT quantity INTO v_n FROM purchase_order_lines WHERE id = line_mat;
    IF v_n <> 120 THEN
        RAISE EXCEPTION 'FIXTURE 103F6 失败:既有材料行的改单应当照旧生效(120),实得 %', v_n;
    END IF;
    v_doc := po_document_data(po_mat);
    IF jsonb_array_length(v_doc->'lines') <> 1
       OR (v_doc->'lines'->0->>'material_name') IS DISTINCT FROM 'fixture 103 material' THEN
        RAISE EXCEPTION 'FIXTURE 103F6 失败:材料单的单据应当原样印出那一行,实得 %',
            COALESCE(v_doc->'lines'->0->>'material_name', '(空)');
    END IF;
END $$;
ROLLBACK;
