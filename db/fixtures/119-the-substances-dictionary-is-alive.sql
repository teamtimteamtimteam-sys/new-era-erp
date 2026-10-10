-- 119 那张物质字典【真的活着】—— 加一行,然后把每一条吃物质码的路都走一遍
--
-- 【这一臂是 PROC-4 本该有的那一臂】
-- PROC-4 报"残留的写死清单 0",而那句话只对【约束】成立 —— 它的 S1 没有查函数体。
-- 于是往 substances 加一行之后,**外键会放行它,而三支函数按 METAL_INVALID 拒掉**,
-- 那张字典只活了一半,而没有任何东西说过这件事。
--
-- 【为什么证明必须是一份 fixture 而不是一次 diff】
-- "我把三处都改了"是一句关于【我做过什么】的话;而"加一行之后每一条路都走得通"
-- 是一句关于【系统是什么样】的话。前者会漏掉第四处,后者不会 ——
-- 因为它不问副本在哪儿,它问结果。
--
-- ★ MES-6a-2(2026-10-10,MES-6a Step 0 Q26 · Q27,Tim)改写了这一支 —— 字典上多了 role,于是"每一条路都收"不再是对的:
--   【一个可计价的】新物质照旧每一条路都走得通(F2,含定价那几条);【一个惩罚元素】在化验、含量、必测项、品位规格、
--   惩罚条款上收,在定价的每一条路上按名拒 SUBSTANCE_NOT_PAYABLE(F2P)。原来的 F2 断言一条没减:它们现在由那个可计价的新物质走。
--
-- 【每一臂钉什么】
-- F1 前提:既有的七个码在每一条路上都照旧走得通(先于一切派生量)。
-- F2 **本刀的意义**:事务里加一行【可计价】物质(role = payable_metal),然后逐条走 ——
--    化验(record_assay_result)· 物料必测项(set_material_required_metals)·
--    行情(upsert_metal_prices)· 计价(calculate_metal_price_from_terms)·
--    直插各张 metal 子表(两张含量表、公式、承诺副本、合同的计价条款与精炼费)。**一条都不许拒。**
-- F2P ★ MES-6a-2:加一行【惩罚元素】(role = penalty_element)——
--    收:化验 · 两张含量表 · 物料必测项 · 合同品位规格 · 合同惩罚条款;
--    拒(SUBSTANCE_NOT_PAYABLE|<码>,逐条按名):行情 · 计价引擎(含量清单与条款两头)· 公式的计价金属 · 承诺副本 ·
--    合同计价条款 · 合同精炼费。一个可计价的金属写进惩罚条款 → SUBSTANCE_NOT_PENALTY_ELEMENT。
-- F3 反面:一个【不在字典里】的码,在每一条路上都要被拒 ——
--    否则 F2 可以由"把校验全删了"来通过。
--
-- 日期无关。自带全部数据(README 第 2 条)。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_ccy text;
    v_sup uuid; v_mat uuid; v_ib uuid; v_ob uuid; v_formula uuid; v_commit uuid; v_cust uuid; v_con uuid;
    v_res jsonb; v_n int;
    v_denied boolean; v_msg text;
    v_day date := DATE '2026-03-03';
    NEW_CODE text := 'ZZ119_P';         -- 一个虚构的【可计价】物质(F2)
    PEN_CODE text := 'ZZ119_F';         -- 一个虚构的【惩罚元素】(F2P;氟本身从 MES-6a-2 起是真的一行)
    v_path text;
    v_case record;
BEGIN
    UPDATE finance_settings SET locked_before = NULL;
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-119', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    SELECT code INTO v_ccy FROM currencies WHERE is_base;

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ119-S', 'fixture 119 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, chemistry)
    VALUES ('ZZ119-M', 'f119 feed', 'battery_material', true, 'black_mass', 'end_of_life', 'NMC')
    RETURNING id INTO v_mat;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ119-IB', v_mat, v_sup, 1000, 1000, 'kg', v_day, 'other', 'fixture 119 自带数据') RETURNING id INTO v_ib;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZ119-OB', v_mat, 10, 10, v_day) RETURNING id INTO v_ob;
    INSERT INTO pricing_formulas (code, name) VALUES ('ZZ119-PF', 'f119 formula')
    RETURNING id INTO v_formula;
    INSERT INTO pricing_term_commitments (source_formula_code, price_basis, treatment_charge_usd_per_tonne, flat_discount_pct, inbound_batch_id)
    VALUES ('ZZ119-PF', 'spot', 0, 0, v_ib) RETURNING id INTO v_commit;
    INSERT INTO customers (code, legal_name, country) VALUES ('ZZ119-C', 'fixture 119 customer', 'SG') RETURNING id INTO v_cust;
    INSERT INTO contracts (customer_id, kind, title, effective_from, status)
    VALUES (v_cust, 'offtake', 'fixture 119', DATE '2026-01-01', 'draft') RETURNING id INTO v_con;

    -- ══════════ F1 · 前提:既有的码在每一条路上都照旧 ═══════════════════════
    RAISE NOTICE 'fixture 119 · 进入 F1';
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM upsert_metal_prices(v_day,
            jsonb_build_array(jsonb_build_object('metal','ni','price_usd_per_tonne',16000)),
            NULL, 'broker_quote');
        PERFORM set_material_required_metals(v_mat, ARRAY['ni','co']);
        v_res := record_assay_result(p_assay_date => v_day,
            p_metals => jsonb_build_array(jsonb_build_object('metal','ni','content_pct',10)),
            p_inbound_batch_id => v_ib, p_weight_basis => 'dry', p_result_party => 'ours');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 119F1 失败:进入 F1 —— 既有的七个码必须在每一条路上照旧走得通。**改判据不许缩小既有的接受集合**,而本刀只该把它变大。实得「%」', v_msg;
    END IF;
    -- ★ MES-6a-2:既有的七个都是可计价的(迁移把它们改成 payable_metal,引导里逐行写明)
    SELECT count(*) INTO v_n FROM substances WHERE code IN ('ni','co','li','mn','cu','al','fe') AND role = 'payable_metal';
    IF v_n <> 7 THEN
        RAISE EXCEPTION 'FIXTURE 119F1 失败:进入 F1 —— 既有的七个金属都该是 payable_metal,实得 % 个', v_n;
    END IF;

    -- ══════════ F2 · 加一行【可计价】物质,然后【每一条路】都走一遍 ═══════════════
    RAISE NOTICE 'fixture 119 · 进入 F2';
    INSERT INTO substances (code, name_en, name_zh, symbol, sort_order, notes, role)
    VALUES (NEW_CODE, 'Fixture payable (119)', '可计价(fixture 119)', 'Zp', 97,
            'fixture 119:证明这张字典真的活着', 'payable_metal');

    -- 【逐条走。每一条都单独包起来,红的时候说得出【是哪一条路】拒的】——
    -- 一个笼统的"某处失败了"会让人从头找起,而这份 fixture 存在的理由正是
    -- "第四份副本藏在哪儿"这个问题不该由人去找。
    v_path := 'upsert_metal_prices(行情)';
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM upsert_metal_prices(v_day,
            jsonb_build_array(jsonb_build_object('metal', NEW_CODE, 'price_usd_per_tonne', 5)),
            NULL, 'broker_quote');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 119F2 失败:进入 F2 —— 加了一行字典之后,【%】这条路仍然拒它。**外键放行而函数拒绝,就是那张字典只活了一半** —— PROC-4 漏掉的正是这一类(它的 S1 只查了约束,没查函数体)。实得「%」', v_path, v_msg;
    END IF;

    v_path := 'set_material_required_metals(物料必测项)';
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM set_material_required_metals(v_mat, ARRAY['ni', NEW_CODE]);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 119F2 失败:进入 F2 —— 【%】这条路仍然拒新物质。实得「%」', v_path, v_msg;
    END IF;

    v_path := 'record_assay_result(化验)';
    v_denied := false; v_msg := NULL;
    BEGIN
        v_res := record_assay_result(p_assay_date => v_day,
            p_metals => jsonb_build_array(jsonb_build_object('metal', NEW_CODE, 'content_pct', 0.4)),
            p_inbound_batch_id => v_ib, p_weight_basis => 'dry', p_result_party => 'ours');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 119F2 失败:进入 F2 —— 【%】这条路仍然拒新物质。实得「%」', v_path, v_msg;
    END IF;

    v_path := 'calculate_metal_price_from_terms(计价)';
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM calculate_metal_price_from_terms(
            jsonb_build_object('price_basis','spot','treatment_charge_usd_per_tonne',0,
                               'flat_discount_pct',0,
                               'payables', jsonb_build_object(NEW_CODE, 50)),
            jsonb_build_array(jsonb_build_object('metal', NEW_CODE, 'content_pct', 0.4)),
            1000, v_day);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied AND (v_msg LIKE '%METAL_INVALID%' OR v_msg LIKE '%SUBSTANCE_NOT_PAYABLE%') THEN
        RAISE EXCEPTION 'FIXTURE 119F2 失败:进入 F2 —— 【%】这条路拒了一个可计价的新物质。实得「%」', v_path, v_msg;
    END IF;
    -- (这条路可能因为【没有行情】之类的别的理由拒,那与本刀无关 ——
    --  所以这一臂只断言它【不是】因为"不认识这个码 / 不可计价"而拒。)

    v_path := '直插各张 metal 子表';
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source)
        VALUES (v_ib, NEW_CODE, 0.4, 'manual');
        INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source)
        VALUES (v_ob, NEW_CODE, 0.2, 'manual');
        INSERT INTO pricing_formula_metals (formula_id, metal, payable_pct)
        VALUES (v_formula, NEW_CODE, 50);
        INSERT INTO pricing_term_commitment_metals (commitment_id, metal, payable_pct)
        VALUES (v_commit, NEW_CODE, 50);
        INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct)
        VALUES (v_con, NEW_CODE, 'assay_complete', 0, 'LME', 50);
        INSERT INTO contract_refining_charges (contract_id, metal, usd_per_tonne_of_metal)
        VALUES (v_con, NEW_CODE, 10);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 119F2 失败:进入 F2 —— 【%】仍然拒一个可计价的新物质(那几条外键 PROC-4 已经接上了;MES-6a-2 的守卫只拒不计价的)。实得「%」', v_path, v_msg;
    END IF;

    -- 【走完之后,那个新码确实在库里留下了东西】—— 否则"没有拒绝"可能只是没做事。
    SELECT count(*) INTO v_n FROM (
        SELECT 1 FROM metal_prices WHERE metal = NEW_CODE
        UNION ALL SELECT 1 FROM material_required_metals WHERE metal = NEW_CODE
        UNION ALL SELECT 1 FROM assay_result_metals WHERE metal = NEW_CODE
        UNION ALL SELECT 1 FROM inbound_batch_metals WHERE metal = NEW_CODE
        UNION ALL SELECT 1 FROM output_batch_metals WHERE metal = NEW_CODE
        UNION ALL SELECT 1 FROM pricing_formula_metals WHERE metal = NEW_CODE
        UNION ALL SELECT 1 FROM pricing_term_commitment_metals WHERE metal = NEW_CODE
        UNION ALL SELECT 1 FROM contract_pricing_terms WHERE metal = NEW_CODE
        UNION ALL SELECT 1 FROM contract_refining_charges WHERE metal = NEW_CODE) x;
    IF v_n < 9 THEN
        RAISE EXCEPTION 'FIXTURE 119F2 失败:进入 F2 —— 九条路都该在库里留下这个新码的一行,实得 % 行。**"没有报错"不等于"做了事"**', v_n;
    END IF;

    -- ══════════ F2P · ★ MES-6a-2:一个【惩罚元素】—— 记得下、点得进惩罚条款,定价的每一条路按名拒 ═════════════
    RAISE NOTICE 'fixture 119 · 进入 F2P';
    INSERT INTO substances (code, name_en, name_zh, symbol, sort_order, notes, role)
    VALUES (PEN_CODE, 'Fixture penalty element (119)', '惩罚元素(fixture 119)', 'Zf', 98,
            'fixture 119:惩罚元素只在它该在的地方', 'penalty_element');
    -- 收的那几条:化验 · 两张含量表 · 物料必测项 · 合同品位规格 · 合同惩罚条款
    v_denied := false; v_msg := NULL;
    BEGIN
        v_path := 'record_assay_result(化验)';
        v_res := record_assay_result(p_assay_date => v_day,
            p_metals => jsonb_build_array(jsonb_build_object('metal','ni','content_pct',10),
                                          jsonb_build_object('metal', PEN_CODE, 'content_pct', 0.005)),
            p_inbound_batch_id => v_ib, p_weight_basis => 'dry', p_result_party => 'ours');
        v_path := 'inbound_batch_metals';
        INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source) VALUES (v_ib, PEN_CODE, 0.005, 'manual');
        v_path := 'output_batch_metals';
        INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source) VALUES (v_ob, PEN_CODE, 0.003, 'manual');
        v_path := 'set_material_required_metals(物料必测项)';
        PERFORM set_material_required_metals(v_mat, ARRAY['ni', PEN_CODE]);
        v_path := 'contract_grade_specs';
        INSERT INTO contract_grade_specs (contract_id, metal, max_pct) VALUES (v_con, PEN_CODE, 0.01);
        v_path := 'contract_penalty_elements';
        INSERT INTO contract_penalty_elements (contract_id, substance, threshold_pct, usd_per_tonne_per_pct_over) VALUES (v_con, PEN_CODE, 0.002, 5);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 119F2P 失败:进入 F2P —— 一个惩罚元素在【%】这条路上应当记得下(Q27:任意一种都收的地方),实得「%」', v_path, v_msg;
    END IF;
    -- 拒的那几条:每一条单独包起来,【按名】断言 —— 不是"报了个错"就算
    FOR v_case IN SELECT * FROM (VALUES
        ('upsert_metal_prices(行情)',
         format($q$SELECT upsert_metal_prices(%L, jsonb_build_array(jsonb_build_object('metal', %L, 'price_usd_per_tonne', 5)), NULL, 'broker_quote')$q$, v_day, PEN_CODE)),
        ('calculate_metal_price_from_terms(含量清单)',
         format($q$SELECT calculate_metal_price_from_terms(jsonb_build_object('price_basis','spot','treatment_charge_usd_per_tonne',0,'flat_discount_pct',0,'payables','{}'::jsonb), jsonb_build_array(jsonb_build_object('metal', %L, 'content_pct', 0.4)), 1000, %L)$q$, PEN_CODE, v_day)),
        ('calculate_metal_price_from_terms(条款)',
         format($q$SELECT calculate_metal_price_from_terms(jsonb_build_object('price_basis','spot','treatment_charge_usd_per_tonne',0,'flat_discount_pct',0,'payables', jsonb_build_object(%L, 50)), jsonb_build_array(jsonb_build_object('metal','ni','content_pct', 10)), 1000, %L)$q$, PEN_CODE, v_day)),
        ('pricing_formula_metals(公式)',
         format($q$INSERT INTO pricing_formula_metals (formula_id, metal, payable_pct) VALUES (%L, %L, 50)$q$, v_formula, PEN_CODE)),
        ('pricing_term_commitment_metals(承诺副本)',
         format($q$INSERT INTO pricing_term_commitment_metals (commitment_id, metal, payable_pct) VALUES (%L, %L, 50)$q$, v_commit, PEN_CODE)),
        ('contract_pricing_terms(合同计价条款)',
         format($q$INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct) VALUES (%L, %L, 'assay_complete', 0, 'LME', 50)$q$, v_con, PEN_CODE)),
        ('contract_refining_charges(合同精炼费)',
         format($q$INSERT INTO contract_refining_charges (contract_id, metal, usd_per_tonne_of_metal) VALUES (%L, %L, 10)$q$, v_con, PEN_CODE))
    ) AS c(path, sql) LOOP
        v_denied := false; v_msg := NULL;
        BEGIN
            EXECUTE v_case.sql;
        EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
        IF NOT v_denied OR v_msg IS DISTINCT FROM 'SUBSTANCE_NOT_PAYABLE|' || PEN_CODE THEN
            RAISE EXCEPTION 'FIXTURE 119F2P 失败:进入 F2P —— 一个惩罚元素在【%】这条定价的路上必须按名拒 SUBSTANCE_NOT_PAYABLE|%,实得「%」', v_case.path, PEN_CODE, COALESCE(v_msg, '(通过了)');
        END IF;
    END LOOP;
    -- 反过来:一个可计价的金属写进惩罚条款 → 按名拒
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO contract_penalty_elements (contract_id, substance, threshold_pct, usd_per_tonne_per_pct_over) VALUES (v_con, 'cu', 0.5, 5);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg IS DISTINCT FROM 'SUBSTANCE_NOT_PENALTY_ELEMENT|cu' THEN
        RAISE EXCEPTION 'FIXTURE 119F2P 失败:进入 F2P —— 一个可计价的金属写进惩罚条款必须按名拒 SUBSTANCE_NOT_PENALTY_ELEMENT|cu(Q27:惩罚条款只收惩罚元素),实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ F3 · 反面:字典【外】的码,每一条路都要拒 ═════════════════
    RAISE NOTICE 'fixture 119 · 进入 F3';
    -- 少了这一半,一个"把所有校验都删掉"的实现能让 F2 全绿。
    v_denied := false;
    BEGIN
        PERFORM upsert_metal_prices(v_day,
            jsonb_build_array(jsonb_build_object('metal','ZZ119-NOSUCH','price_usd_per_tonne',1)),
            NULL, 'broker_quote');
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 119F3 失败:进入 F3 —— 字典【外】的码在行情这条路上必须被拒。**这一半是那个铰链**:只测"新码走得通",一个把校验全删了的实现也会全绿';
    END IF;
    v_denied := false;
    BEGIN PERFORM set_material_required_metals(v_mat, ARRAY['ZZ119-NOSUCH']);
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 119F3 失败:进入 F3 —— 字典外的码在物料必测项这条路上必须被拒';
    END IF;
    v_denied := false;
    BEGIN
        PERFORM record_assay_result(p_assay_date => v_day,
            p_metals => jsonb_build_array(jsonb_build_object('metal','ZZ119-NOSUCH','content_pct',1)),
            p_inbound_batch_id => v_ib, p_weight_basis => 'dry', p_result_party => 'ours');
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 119F3 失败:进入 F3 —— 字典外的码在化验这条路上必须被拒';
    END IF;
    v_denied := false;
    BEGIN
        INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source)
        VALUES (v_ib, 'ZZ119-NOSUCH', 1, 'manual');
    EXCEPTION WHEN foreign_key_violation THEN v_denied := true; WHEN OTHERS THEN NULL; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 119F3 失败:进入 F3 —— 字典外的码在直插子表这条路上必须被外键拒';
    END IF;
    -- ★ MES-6a-2:守卫不替外键说话 —— 字典外的码写进一张只收可计价金属的表,照旧是外键拒,不是 SUBSTANCE_NOT_PAYABLE
    v_denied := false;
    BEGIN
        INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct)
        VALUES (v_con, 'ZZ119-NOSUCH', 'assay_complete', 0, 'LME', 50);
    EXCEPTION WHEN foreign_key_violation THEN v_denied := true; WHEN OTHERS THEN NULL; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 119F3 失败:进入 F3 —— 字典外的码在合同计价条款上必须被【外键】拒(角色守卫不认识它,就该让外键说话)';
    END IF;
    RAISE NOTICE 'FIXTURE 119 全部通过: F1 · F2 · F2P · F3';
END $$;
ROLLBACK;
