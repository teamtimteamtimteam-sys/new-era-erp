-- 176 一台机器永远不会被化验 —— 而"用不上的选项"必须在【两道闸】上都拒
--
-- 【钉的是 Tim 用系统时发现的那个缺陷】开一张设备采购单,付款里程碑的下拉里
-- 给的是材料那一套,其中 AFTER ASSAY 【选得中】。一个用不上的选项比一个缺失的
-- 更糟,正因为它选得中。
--
-- 【这份 fixture 自带全部数据】重建库没有任何业务数据。供货商、物料、资产卡
-- (经 record_expense 的资本分支)、两张采购单,全部自己造。
--
-- 【七臂,以及每一臂钉的是什么】
-- A 门上那一道:设备单 + post_assay → 按名拒 PO_TERM_EVENT_NOT_APPLICABLE。
-- B ★【判别力】★ 同一个 post_assay 放在【材料单】上 —— 必须【收下】。
--   没有这一臂,一道"什么都拒"的闸会照样通过 A。**它是这份 fixture 的支点。**
-- C 表上那一道:绕过 create_purchase_order,直插 purchase_order_payment_terms。
--   一个禁用掉的下拉不是控制,而只写在函数里的校验挡不住直连 PostgREST。
-- D 反方向:设备专属的里程碑(installation/acceptance/training)放在【材料单】
--   上要拒。一部字典若只在一个方向上生效,它就只做了一半。
-- E 设备单收得下设备里程碑 —— 【先断言正路通,再断言歧路堵】。
--   正路若本来就断了,C/D 的"拒绝"证明不了任何事。
-- F 主语缺席:一张没有行的单判不出种类 → 拒(PO_TERM_KIND_UNKNOWN),
--   不许当作"判不出就放行"。
-- G 字典本身:post_assay 对设备为 false,而 on_shipment 对设备【为 true】——
--   排除的判据是"这件事会不会发生在它身上",不是"清单上有没有列"。
--   一份把设备里程碑砍成 R4 那五个的实现会在这一臂上红。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid;
    v_sup uuid; v_mat uuid; v_ccy text; v_asset uuid; v_res jsonb;
    po_mat uuid; po_eqp uuid; po_empty uuid;
    v_msg text; v_denied boolean; v_n int; v_b boolean;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-174', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, default_tax_code)
    VALUES ('ZZFIX176-S', 'fixture 176 supplier', 'SG', 'active', 'goods_supplier', 'TX')
    RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX176-M', 'fixture 176 material', 'battery_material', true, 'black_mass', 'end_of_life')
    RETURNING id INTO v_mat;

    v_res := record_expense(DATE '2027-01-05', '1500', 400000, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'fixture 176 machine',
        jsonb_build_object('description', 'fixture 176 discharger', 'useful_life_months', 120), NULL);
    SELECT id INTO v_asset FROM fixed_assets WHERE expense_id = (v_res->>'expense_id')::uuid;
    IF v_asset IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 176 前提失败:资本支出没有生成资产卡';
    END IF;

    -- ══════════ G · 字典本身 ════════════════════════════════════════════════
    SELECT applies_to_equipment INTO v_b FROM payment_trigger_events WHERE code = 'post_assay';
    IF v_b IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FIXTURE 176G 失败:post_assay 对设备应当不适用,实得 %', v_b;
    END IF;
    -- ★ 一台进口机器【会装运】—— 凭装运单据付款是设备进口的常规。
    --   把设备里程碑砍成"下单/到货/安装/验收/培训/固定日"六个的实现在这里红。
    SELECT applies_to_equipment INTO v_b FROM payment_trigger_events WHERE code = 'on_shipment';
    IF v_b IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FIXTURE 176G 失败:on_shipment 对设备【应当适用】(机器要装运),实得 %', v_b;
    END IF;
    SELECT count(*) INTO v_n FROM payment_trigger_events WHERE applies_to_material;
    IF v_n <> 5 THEN
        RAISE EXCEPTION 'FIXTURE 176G 失败:材料里程碑应当仍是 5 种(本刀不动材料那一侧),实得 %', v_n;
    END IF;

    -- ══════════ B · 判别力:post_assay 在【材料单】上必须收下 ════════════════
    -- 【先跑这一臂】它证明闸是有判别力的,而不是一律拒绝。
    v_res := create_purchase_order(v_sup, DATE '2027-01-10', DATE '2027-03-01', v_ccy, NULL,
        NULL, NULL, 'fixture 176 material PO',
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100,
                                             'estimated_unit_price', 10)),
        jsonb_build_array(jsonb_build_object('seq', 1, 'label', '化验后', 'percentage', 100,
                                             'trigger_event', 'post_assay')));
    po_mat := (v_res->>'purchase_order_id')::uuid;
    IF (v_res->>'order_kind') <> 'material' THEN
        RAISE EXCEPTION 'FIXTURE 176B 失败:材料单应当判为 material,实得 %', v_res->>'order_kind';
    END IF;
    SELECT count(*) INTO v_n FROM purchase_order_payment_terms
     WHERE purchase_order_id = po_mat AND trigger_event = 'post_assay';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 176B 失败:post_assay 在材料单上【应当收下】,实得 % 行 —— 这一臂红了说明闸没有判别力,它在一律拒绝', v_n;
    END IF;

    -- ══════════ A · 门上那一道:设备单 + post_assay → 按名拒 ═════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        v_res := create_purchase_order(v_sup, DATE '2027-01-11', DATE '2027-04-01', v_ccy, NULL,
            NULL, NULL, 'fixture 176 equipment PO (bad milestone)',
            jsonb_build_array(jsonb_build_object('asset_id', v_asset)),
            jsonb_build_array(jsonb_build_object('seq', 1, 'label', '化验后', 'percentage', 100,
                                                 'trigger_event', 'post_assay')));
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('PO_TERM_EVENT_NOT_APPLICABLE' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 176A 失败:设备单上的 post_assay 应当按名拒 PO_TERM_EVENT_NOT_APPLICABLE,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- ══════════ E · 正路要通:设备单收得下设备里程碑 ═════════════════════════
    -- Tim 的真实条款:50% 预付 / 40% 交付 / 10% 培训完成。
    v_res := create_purchase_order(v_sup, DATE '2027-01-12', DATE '2027-04-01', v_ccy, NULL,
        NULL, NULL, 'fixture 176 equipment PO',
        jsonb_build_array(jsonb_build_object('asset_id', v_asset)),
        jsonb_build_array(
            jsonb_build_object('seq', 1, 'label', '预付',     'percentage', 50, 'trigger_event', 'on_order'),
            jsonb_build_object('seq', 2, 'label', '交付',     'percentage', 40, 'trigger_event', 'on_arrival'),
            jsonb_build_object('seq', 3, 'label', '培训完成', 'percentage', 10, 'trigger_event', 'training_complete')));
    po_eqp := (v_res->>'purchase_order_id')::uuid;
    IF (v_res->>'order_kind') <> 'equipment' THEN
        RAISE EXCEPTION 'FIXTURE 176E 失败:设备单应当判为 equipment,实得 %', v_res->>'order_kind';
    END IF;
    SELECT count(*) INTO v_n FROM purchase_order_payment_terms WHERE purchase_order_id = po_eqp;
    IF v_n <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 176E 失败:设备单的三期应当都收下,实得 % —— 正路断了,C/D 的拒绝证明不了任何事', v_n;
    END IF;

    -- ══════════ C · 表上那一道:绕过函数,直插 ═══════════════════════════════
    -- 【这一臂是 R5 的全部要点】一个禁用掉的下拉选项不是控制。
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO purchase_order_payment_terms
            (purchase_order_id, seq, label, percentage, trigger_event)
        VALUES (po_eqp, 9, '偷偷加一期化验后', 5, 'post_assay');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('PO_TERM_EVENT_NOT_APPLICABLE' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 176C 失败:直插一期 post_assay 到设备单上,应当由【表上的触发器】按名拒,实得 denied=% msg=% —— 只写在函数里的校验挡不住直连 PostgREST',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- ══════════ D · 反方向:设备专属里程碑放在材料单上要拒 ═══════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO purchase_order_payment_terms
            (purchase_order_id, seq, label, percentage, trigger_event)
        VALUES (po_mat, 9, '一吨废料的安装完成', 5, 'installation_complete');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('PO_TERM_EVENT_NOT_APPLICABLE' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 176D 失败:installation_complete 在材料单上应当按名拒(一吨废料不安装),实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- ══════════ F · 主语缺席:没有行的单判不出种类 → 拒 ══════════════════════
    -- 【判不出就放行】正是本仓库记过的那条病(守卫对主语缺席这一格是瞎的)。
    po_empty := gen_random_uuid();
    INSERT INTO purchase_orders (id, code, supplier_id, order_date, currency, fx_rate,
                                 estimated_total_ccy, status, approval_status)
    VALUES (po_empty, 'ZZFIX176-PO-EMPTY', v_sup, DATE '2027-01-13', v_ccy, 1, 0,
            'draft', 'approved');
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO purchase_order_payment_terms
            (purchase_order_id, seq, label, percentage, trigger_event)
        VALUES (po_empty, 1, '判不出种类的单', 100, 'on_order');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('PO_TERM_KIND_UNKNOWN' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 176F 失败:一张没有行的单判不出种类,应当按名拒 PO_TERM_KIND_UNKNOWN,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    RAISE NOTICE 'FIXTURE 176 ✓ 设备单拒 after-assay(门与表两道),材料单照收;反方向亦然';
END $$;
ROLLBACK;
