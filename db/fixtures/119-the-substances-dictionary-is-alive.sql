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
-- 【每一臂钉什么】
-- F1 前提:既有的七个码在每一条路上都照旧走得通(先于一切派生量)。
-- F2 **本刀的意义**:事务里加一行物质,然后逐条走 ——
--    化验(record_assay_result)· 物料必测项(set_material_required_metals)·
--    行情(upsert_metal_prices)· 计价(calculate_metal_price_from_terms)·
--    以及直插各张 metal 子表的那几条边。**一条都不许拒。**
-- F3 反面:一个【不在字典里】的码,在每一条路上都要被拒 ——
--    否则 F2 可以由"把校验全删了"来通过。
--
-- 日期无关。自带全部数据(README 第 2 条)。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_ccy text;
    v_sup uuid; v_mat uuid; v_ib uuid; v_ob uuid; v_formula uuid;
    v_res jsonb; v_n int;
    v_denied boolean; v_msg text;
    v_day date := DATE '2026-03-03';
    NEW_CODE text := 'ZZ119_F';         -- 氟:排在第一位的真实需求,今天还记不下来
    v_path text;
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
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ119-IB', v_mat, v_sup, 1000, 1000, 'kg', v_day) RETURNING id INTO v_ib;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZ119-OB', v_mat, 10, 10, v_day) RETURNING id INTO v_ob;
    INSERT INTO pricing_formulas (code, name) VALUES ('ZZ119-PF', 'f119 formula')
    RETURNING id INTO v_formula;

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

    -- ══════════ F2 · 加一行,然后【每一条路】都走一遍 ═══════════════════════
    RAISE NOTICE 'fixture 119 · 进入 F2';
    INSERT INTO substances (code, name_en, name_zh, symbol, sort_order, notes)
    VALUES (NEW_CODE, 'Fluorine (fixture)', '氟(fixture)', 'F', 97,
            'fixture 119:证明这张字典真的活着');

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
                               'metals', jsonb_build_array(
                                   jsonb_build_object('metal', NEW_CODE, 'payable_pct', 50))),
            jsonb_build_array(jsonb_build_object('metal', NEW_CODE, 'content_pct', 0.4)),
            1000, v_day);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied AND v_msg LIKE '%METAL_INVALID%' THEN
        RAISE EXCEPTION 'FIXTURE 119F2 失败:进入 F2 —— 【%】这条路按 METAL_INVALID 拒了新物质。实得「%」', v_path, v_msg;
    END IF;
    -- (这条路可能因为【没有行情】之类的别的理由拒,那与本刀无关 ——
    --  所以这一臂只断言它【不是】因为"不认识这个码"而拒。)

    v_path := '直插各张 metal 子表';
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source)
        VALUES (v_ib, NEW_CODE, 0.4, 'manual');
        INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source)
        VALUES (v_ob, NEW_CODE, 0.2, 'manual');
        INSERT INTO pricing_formula_metals (formula_id, metal, payable_pct)
        VALUES (v_formula, NEW_CODE, 50);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 119F2 失败:进入 F2 —— 【%】仍然拒新物质(那几条外键 PROC-4 已经接上了,若这里红说明外键也退化了)。实得「%」', v_path, v_msg;
    END IF;

    -- 【走完之后,那个新码确实在库里留下了东西】—— 否则"没有拒绝"可能只是没做事。
    SELECT count(*) INTO v_n FROM (
        SELECT 1 FROM metal_prices WHERE metal = NEW_CODE
        UNION ALL SELECT 1 FROM material_required_metals WHERE metal = NEW_CODE
        UNION ALL SELECT 1 FROM assay_result_metals WHERE metal = NEW_CODE
        UNION ALL SELECT 1 FROM inbound_batch_metals WHERE metal = NEW_CODE
        UNION ALL SELECT 1 FROM output_batch_metals WHERE metal = NEW_CODE
        UNION ALL SELECT 1 FROM pricing_formula_metals WHERE metal = NEW_CODE) x;
    IF v_n < 6 THEN
        RAISE EXCEPTION 'FIXTURE 119F2 失败:进入 F2 —— 六条路都该在库里留下这个新码的一行,实得 % 行。**"没有报错"不等于"做了事"**', v_n;
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
END $$;
ROLLBACK;
