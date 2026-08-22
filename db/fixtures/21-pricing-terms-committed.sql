-- 21 计价条款的承诺:结算按【成交时抄下的副本】,新报价按【改后的公式】
--
-- 为什么值得常设(FIN-27):计价公式是普通 UPDATE 改的模板,而采购行上的公式
-- 引用是一份关于将来怎么结算的承诺。公式改了,已成交的单跟着改 —— 供应商按 70%
-- 可付比签的字,到货结算时按 60% 付款,而库里没有任何东西记得当时它说的是什么。
-- 四臂,前两臂是这一切的全部:
--   A 【承诺 → 改公式 → 结算】结算价必须由【承诺条款】算出:2.95 USD/kg
--     (可付 70%、处理费 200)。故障注入:同时用【活公式】(改后:可付 50%、
--     处理费 400)算一遍 = 1.85,断言结算价【不等于】它 —— 若哪天 apply_assay_result
--     退回去读活公式,这一臂当场红。两个数刻意隔开,不可能因为凑巧相等而过。
--   B 【改公式之后新下的单】必须按【新条款】:抄下的副本是 50 / 400,结算价 1.85。
--     没有这一臂,"永远用副本"与"什么都不更新"两种实现都能过 A。
--   C 【没有副本的引用】—— FIN-27 之前留下的行。点名拒
--     (PRICING_TERMS_NOT_COMMITTED),不悄悄退回去读活公式,也不回填一份猜测的
--     条款(D:编造的承诺比缺失的承诺更坏)。应用化验与手工重计价两条路都拒。
--   D 【公式编辑留痕】表头改动与逐金属改动各写一行,old/new 都在;
--     清空一个金属(界面用 DELETE 表达"不再计价")同样留痕 —— 只记表头的历史
--     对最激烈的一种编辑一言不发。
--
-- 【数字怎么来的】ni 行情 15,000 USD/t、批次 100 kg、化验 ni 30%:
--   承诺条款(payable 70%,处理费 200 USD/t,折扣 0):
--     gross = 100 × 30% × 70% × 15000/1000 = 315;treat = 100/1000 × 200 = 20;
--     net = 295 → 2.95 USD/kg;入库价 = 2.95 × fx(USD tt_sell 1.26) = 3.717
--   改后的活公式(payable 50%,处理费 400 USD/t):
--     gross = 225;treat = 40;net = 185 → 1.85 USD/kg → 2.331
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid(); v_role uuid;
    v_sup uuid; v_mat uuid; v_formula uuid;
    v_fx numeric := 1.26; v_today date := CURRENT_DATE;
    v_po jsonb; v_line uuid; v_line2 uuid; v_batch uuid; v_batch2 uuid; v_batch3 uuid;
    v_assay jsonb; v_commit uuid; v_c record;
    v_live numeric; v_price numeric; v_n integer;
    v_metals jsonb := jsonb_build_array(jsonb_build_object('metal','ni','content_pct',30));
    v_h record;
    v_msg text; v_ok boolean;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-21', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);
    -- 前提显式设定(README 第 5 条):期间不锁、牌价与行情自己插。
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO suppliers (code, legal_name, country, counterparty_type) VALUES ('FIXT-S21', 'Fixture Supplier 21', 'SG', 'goods_supplier')
        RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES ('FIXT-M21', 'Fixture Material 21', 'battery_material', true, 'black_mass', 'end_of_life')
        RETURNING id INTO v_mat;
    DELETE FROM fx_rates WHERE currency = 'USD' AND rate_date = v_today AND rate_type = 'tt_sell';
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES ('USD', v_today, 'tt_sell', v_fx);
    DELETE FROM metal_prices WHERE metal = 'ni' AND price_date = v_today;
    INSERT INTO metal_prices (metal, price_date, price_usd_per_tonne, source)
    VALUES ('ni', v_today, 15000, 'broker_quote');

    -- 本 fixture 自带公式(不借引导数据):可付 ni 70% / co 55%,处理费 200,折扣 0
    INSERT INTO pricing_formulas (code, name, direction, price_basis,
                                  treatment_charge_usd_per_tonne, flat_discount_pct, is_active)
    VALUES ('', 'Fixture Formula 21', 'purchase', 'spot', 200, 0, true)
    RETURNING id INTO v_formula;
    INSERT INTO pricing_formula_metals (formula_id, metal, payable_pct)
    VALUES (v_formula, 'ni', 70), (v_formula, 'co', 55);

    -- ════════ A. 承诺 → 改公式 → 结算按承诺条款 ═══════════════════════════════
    v_po := create_purchase_order(v_sup, v_today, NULL, 'USD', NULL, NULL, NULL, NULL,
        jsonb_build_array(jsonb_build_object(
            'line_no', 1, 'material_id', v_mat, 'quantity', 100, 'unit', 'kg',
            'pricing_formula_id', v_formula)),
        NULL);

    -- APR-2:采购单现在【生为 draft/pending】,而未获批的单收不了货。本 fixture 测的
    -- 不是审批流,所以直接把它置成已批 —— 与 fixture 26/30 为 fx_rate 显式给值同一
    -- 性质:把新增的前置条件明写出来,而不是让它悄悄挡住别的断言。
    -- (审批流本身由 db/fixtures/35 覆盖。)
    UPDATE purchase_orders SET approval_status = 'approved', status = 'confirmed'
     WHERE id = (v_po->>'purchase_order_id')::uuid;
    SELECT id INTO v_line FROM purchase_order_lines
    WHERE purchase_order_id = (v_po->>'purchase_order_id')::uuid AND line_no = 1;

    -- 下单即抄条款
    SELECT * INTO v_c FROM pricing_term_commitments WHERE purchase_order_line_id = v_line;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FIXTURE 21A 失败:下单没有抄下结算条款 —— 承诺时刻没落副本,后面全是空的';
    END IF;
    v_commit := v_c.id;
    IF v_c.treatment_charge_usd_per_tonne <> 200
       OR (SELECT payable_pct FROM pricing_term_commitment_metals
            WHERE commitment_id = v_commit AND metal = 'ni') <> 70 THEN
        RAISE EXCEPTION 'FIXTURE 21A 失败:副本抄错 —— 处理费 %(应 200)、ni 可付 %(应 70)',
            v_c.treatment_charge_usd_per_tonne,
            (SELECT payable_pct FROM pricing_term_commitment_metals
              WHERE commitment_id = v_commit AND metal = 'ni');
    END IF;

    -- 【公式在交易脚下被改】—— 这一步就是 FIN-27 的整个理由
    UPDATE pricing_formulas SET treatment_charge_usd_per_tonne = 400 WHERE id = v_formula;
    UPDATE pricing_formula_metals SET payable_pct = 50 WHERE formula_id = v_formula AND metal = 'ni';

    -- 收货 → 化验 → 应用
    INSERT INTO inbound_batches (material_id, supplier_id, quantity, remaining_qty, unit,
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES (v_mat, v_sup, 100, 100, 'kg', v_today,
            (v_po->>'purchase_order_id')::uuid, v_line)
    RETURNING id INTO v_batch;

    -- PROC-5:实验室现在是一张字典(laboratories),lab_name 指向它。
    -- 【自带数据的另一面:自带字典行】本支要用一个自己的实验室名,
    -- 那就自己加那一行 —— 而"加一行就能用"正是把它做成字典换来的东西。
    INSERT INTO laboratories (code, name_en, name_zh, sort_order)
    VALUES ('Fixture Lab', 'Fixture Lab', 'Fixture Lab', 99);
    v_assay := record_assay_result(p_assay_date => v_today, p_metals => v_metals, p_lab_name => 'Fixture Lab', p_inbound_batch_id => v_batch);
    PERFORM apply_assay_result((v_assay->>'assay_result_id')::uuid);

    SELECT unit_price INTO v_price FROM inbound_batches WHERE id = v_batch;
    -- 承诺条款:2.95 USD/kg × 1.26 = 3.717
    IF v_price IS DISTINCT FROM 3.717 THEN
        RAISE EXCEPTION 'FIXTURE 21A 失败:结算价应按【承诺条款】= 3.717(2.95 USD/kg × %),实得 %',
            v_fx, COALESCE(v_price::text, 'NULL');
    END IF;

    -- 【故障注入】同一批货、同一张化验,改用【活公式】算一遍(= FIN-27 之前的行为)。
    -- 断言结算价不是它 —— 两个数刻意隔开,这一臂不可能因为两种答案凑巧相等而通过。
    v_live := round(((calculate_metal_price_internal(v_formula, v_metals, 100, v_today))
                     ->>'unit_price_usd_per_kg')::numeric * v_fx, 4);
    IF v_live = v_price THEN
        RAISE EXCEPTION 'FIXTURE 21A 失败:活公式算出的价 % 与结算价相同 —— 这一臂失去了鉴别力(公式改动没有生效?)', v_live;
    END IF;
    IF v_live IS DISTINCT FROM 2.331 THEN
        RAISE EXCEPTION 'FIXTURE 21A 失败:活公式(改后:可付 50、处理费 400)应算出 2.331,实得 % —— 故障注入的对照值本身不对了', v_live;
    END IF;

    -- ════════ B. 改公式【之后】新下的单 —— 用新条款 ═════════════════════════
    -- 没有这一臂,"永远用副本"与"什么都不更新"两种实现都能过 A。
    v_po := create_purchase_order(v_sup, v_today, NULL, 'USD', NULL, NULL, NULL, NULL,
        jsonb_build_array(jsonb_build_object(
            'line_no', 1, 'material_id', v_mat, 'quantity', 100, 'unit', 'kg',
            'pricing_formula_id', v_formula)),
        NULL);

    -- APR-2:采购单现在【生为 draft/pending】,而未获批的单收不了货。本 fixture 测的
    -- 不是审批流,所以直接把它置成已批 —— 与 fixture 26/30 为 fx_rate 显式给值同一
    -- 性质:把新增的前置条件明写出来,而不是让它悄悄挡住别的断言。
    -- (审批流本身由 db/fixtures/35 覆盖。)
    UPDATE purchase_orders SET approval_status = 'approved', status = 'confirmed'
     WHERE id = (v_po->>'purchase_order_id')::uuid;
    SELECT id INTO v_line2 FROM purchase_order_lines
    WHERE purchase_order_id = (v_po->>'purchase_order_id')::uuid AND line_no = 1;

    SELECT * INTO v_c FROM pricing_term_commitments WHERE purchase_order_line_id = v_line2;
    IF v_c.treatment_charge_usd_per_tonne <> 400
       OR (SELECT payable_pct FROM pricing_term_commitment_metals
            WHERE commitment_id = v_c.id AND metal = 'ni') <> 50 THEN
        RAISE EXCEPTION 'FIXTURE 21B 失败:新单的副本应抄【改后】的条款(400 / 50),实得 % / %',
            v_c.treatment_charge_usd_per_tonne,
            (SELECT payable_pct FROM pricing_term_commitment_metals
              WHERE commitment_id = v_c.id AND metal = 'ni');
    END IF;

    INSERT INTO inbound_batches (material_id, supplier_id, quantity, remaining_qty, unit,
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES (v_mat, v_sup, 100, 100, 'kg', v_today,
            (v_po->>'purchase_order_id')::uuid, v_line2)
    RETURNING id INTO v_batch2;
    v_assay := record_assay_result(p_assay_date => v_today, p_metals => v_metals, p_lab_name => 'Fixture Lab', p_inbound_batch_id => v_batch2);
    PERFORM apply_assay_result((v_assay->>'assay_result_id')::uuid);

    SELECT unit_price INTO v_price FROM inbound_batches WHERE id = v_batch2;
    IF v_price IS DISTINCT FROM 2.331 THEN
        RAISE EXCEPTION 'FIXTURE 21B 失败:改公式之后新下的单应按【新条款】结算 = 2.331,实得 % —— 副本被抄成了旧条款,或者根本没有重新抄',
            COALESCE(v_price::text, 'NULL');
    END IF;

    -- ════════ C. 有公式引用、没有副本(FIN-27 之前的行)→ 点名拒 ═══════════
    -- 存量形状:批次上直接挂着公式,没有承诺记录 —— 正是升级前那些行的样子。
    INSERT INTO inbound_batches (material_id, supplier_id, quantity, remaining_qty, unit,
                                 arrival_date, pricing_formula_id)
    VALUES (v_mat, v_sup, 100, 100, 'kg', v_today, v_formula)
    RETURNING id INTO v_batch3;
    v_assay := record_assay_result(p_assay_date => v_today, p_metals => v_metals, p_lab_name => 'Fixture Lab', p_inbound_batch_id => v_batch3);

    v_ok := false; v_msg := NULL;
    BEGIN
        PERFORM apply_assay_result((v_assay->>'assay_result_id')::uuid);
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'PRICING_TERMS_NOT_COMMITTED%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 21C 失败:没有副本的引用应 PRICING_TERMS_NOT_COMMITTED 点名拒,实得:%',
            COALESCE(v_msg, '(没有报错 —— 多半是悄悄读了活公式)');
    END IF;
    -- 手工重计价这条路同样拒(它曾经是第三个读活公式的入口)
    v_ok := false; v_msg := NULL;
    BEGIN
        PERFORM reprice_from_committed_terms(v_batch3, v_today);
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'PRICING_TERMS_NOT_COMMITTED%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 21C 失败:手工重计价也应点名拒,实得:%',
            COALESCE(v_msg, '(没有报错)');
    END IF;
    -- 而且它没有被悄悄定价
    SELECT unit_price INTO v_price FROM inbound_batches WHERE id = v_batch3;
    IF v_price IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 21C 失败:被拒的批次却有了价格 % —— 拒必须是真的什么都没做', v_price;
    END IF;

    -- ════════ D. 公式编辑留痕:表头一行、逐金属一行,old/new 都在 ═══════════
    SELECT * INTO v_h FROM pricing_formula_history
    WHERE formula_id = v_formula AND change_type = 'update' ORDER BY changed_at DESC LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FIXTURE 21D 失败:改了处理费却没有编辑史 —— 模板改得,但不许不留痕';
    END IF;
    IF v_h.old_treatment_charge_usd_per_tonne <> 200 OR v_h.new_treatment_charge_usd_per_tonne <> 400 THEN
        RAISE EXCEPTION 'FIXTURE 21D 失败:表头留痕应是 200 → 400,实得 % → %',
            v_h.old_treatment_charge_usd_per_tonne, v_h.new_treatment_charge_usd_per_tonne;
    END IF;

    SELECT * INTO v_h FROM pricing_formula_history
    WHERE formula_id = v_formula AND change_type = 'metal_set' AND metal = 'ni'
      AND old_payable_pct IS NOT NULL ORDER BY changed_at DESC LIMIT 1;
    IF NOT FOUND OR v_h.old_payable_pct <> 70 OR v_h.new_payable_pct <> 50 THEN
        RAISE EXCEPTION 'FIXTURE 21D 失败:ni 可付比留痕应是 70 → 50,实得 % → %',
            COALESCE(v_h.old_payable_pct::text, '(无行)'), COALESCE(v_h.new_payable_pct::text, '?');
    END IF;

    -- 清空一个金属 = 界面表达"不再计价"的方式(DELETE 那一行)。
    -- 只记表头的历史对这一种编辑一言不发,而沉默读起来正好等于"什么都没改"。
    DELETE FROM pricing_formula_metals WHERE formula_id = v_formula AND metal = 'co';
    SELECT count(*) INTO v_n FROM pricing_formula_history
    WHERE formula_id = v_formula AND change_type = 'metal_clear' AND metal = 'co'
      AND old_payable_pct = 55;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 21D 失败:清空 co(55%%)应留一行 metal_clear,实得 % 行', v_n;
    END IF;

    -- 历史本身不许被改写
    v_ok := false; v_msg := NULL;
    BEGIN
        UPDATE pricing_formula_history SET new_payable_pct = 99 WHERE formula_id = v_formula;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'HISTORY_APPEND_ONLY%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 21D 失败:编辑史应只增不改(HISTORY_APPEND_ONLY),实得:%',
            COALESCE(v_msg, '(改成功了)');
    END IF;

    -- 副本本身也不许被改写 —— 否则"承诺"只是一次可以事后重写的记账
    v_ok := false; v_msg := NULL;
    BEGIN
        UPDATE pricing_term_commitments SET flat_discount_pct = 10 WHERE id = v_commit;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'PRICING_COMMITMENT_IMMUTABLE%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 21D 失败:承诺副本应不可变(PRICING_COMMITMENT_IMMUTABLE),实得:%',
            COALESCE(v_msg, '(改成功了)');
    END IF;
END $$;
ROLLBACK;
