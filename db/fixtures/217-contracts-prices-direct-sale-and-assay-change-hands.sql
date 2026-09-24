-- 217 ROLE-1 · Batch 2b:合同条款归 cco · 金属行情归财务 · 直接销售归 cco · 应用化验归 cto
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(Tim 的 Batch 2 grilling Q12–Q15 + Batch 2b grilling Q1–Q6)
--   A  ★★ 合同(Q12 · Q1):只持 suppliers.edit 的人直连建一份采购合同 → RLS 拒;
--        改一份已有合同(零行也拒)→ PERMISSION_DENIED|action.contract_terms;写一条品位条款 → RLS 拒;
--        持 action.contract_terms 的人建合同、写条款、改合同 → 成功
--   B  ★★ 金属行情(Q13):只持 pricing.edit 的人调 upsert_metal_prices → PERMISSION_DENIED|action.metal_prices;
--        直连插一条行情 → RLS 拒;改报价阈值 → PERMISSION_DENIED|action.metal_prices;
--        持 action.metal_prices 的人插行情、改阈值 → 成功,而建定价公式 → RLS 拒(公式仍归 pricing.edit);
--        只持 pricing.edit 的人建公式 → 成功
--   C  ★★ 直接销售(Q14 · Q3):只持 output.edit 的人调 record_output_sale → PERMISSION_DENIED|action.direct_sale;
--        持 action.direct_sale 的人 → 过门(撞上 OUTPUT_NOT_FOUND 一类的数据拒绝,不是权限);
--        持 finance.edit 的人直连 INSERT / UPDATE / DELETE sales_records → SALE_THROUGH_FUNCTION_ONLY
--        (UPDATE 与 DELETE 是【零行】也要抛 —— 没有写策略时它们本来是静默的空操作)
--   D  ★★ 化验(Q15 · Q4):只持 inbound.edit / output.edit 的人:应用 · 撤销应用 · 两种试算 →
--        PERMISSION_DENIED|action.apply_assay;记录一份化验 → 成功(记录仍归它们);
--        直连把 applied_at 写上 / 把 superseded_by 写上 / INSERT 一份带 applied_at 的 → ASSAY_APPLY_THROUGH_FUNCTION_ONLY;
--        直连改备注 → 成功;直连写一行出处 assay 的含量 → ASSAY_CONTENT_THROUGH_FUNCTION_ONLY;手工含量 → 成功;
--        持 action.apply_assay 的人撤销应用 → 成功(属主路径,守卫看不见它)
--   E  ★ 故障注入:摘掉 trg_assay_results_applied_columns,D 那一次直连写 applied_at 就写得进去;
--        摘掉 trg_sales_records_direct_write,C 那一次直连 UPDATE 就退回成一次【不报错】的空操作 ——
--        两支守卫都是承重的
--
-- 自带数据(README 第 2 条);锁期自己设(README 第 4 条)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';
DO $$
DECLARE
    u_sup   uuid := gen_random_uuid();   -- 只持 suppliers.edit(+view):今天的仓库 / 财务 / cto 那一种
    u_cco   uuid := gen_random_uuid();   -- action.contract_terms · action.direct_sale · pricing.edit
    u_price uuid := gen_random_uuid();   -- 只持 pricing.edit(+view):今天的 cto 那一种
    u_fin   uuid := gen_random_uuid();   -- action.metal_prices · finance.edit · output.edit · inbound.edit(记录化验)
    u_cto   uuid := gen_random_uuid();   -- action.apply_assay · inbound.edit
    r_sup uuid; r_cco uuid; r_price uuid; r_fin uuid; r_cto uuid;
    v_sup uuid; v_mat uuid; v_b uuid; v_assay uuid; v_c uuid; v_c2 uuid; v_rec jsonb;
    v_n integer; v_msg text; v_denied boolean; v_mp uuid;
    rep jsonb := '{}'::jsonb;
BEGIN
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;

    -- ══════════════════════ 布景 ══════════════════════
    INSERT INTO auth.users (id, email_confirmed_at)
    VALUES (u_sup, now()), (u_cco, now()), (u_price, now()), (u_fin, now()), (u_cto, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx217-sup','f','f',true)   RETURNING id INTO r_sup;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx217-cco','f','f',true)   RETURNING id INTO r_cco;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx217-price','f','f',true) RETURNING id INTO r_price;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx217-fin','f','f',true)   RETURNING id INTO r_fin;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx217-cto','f','f',true)   RETURNING id INTO r_cto;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_sup, 'module.suppliers.edit'), (r_sup, 'module.suppliers.view'),
        (r_sup, 'module.customers.edit'), (r_sup, 'module.customers.view'),
        (r_cco, 'action.contract_terms'), (r_cco, 'action.direct_sale'),
        (r_cco, 'module.suppliers.view'), (r_cco, 'module.customers.view'),
        (r_cco, 'module.pricing.edit'), (r_cco, 'module.pricing.view'),
        (r_cco, 'module.output.view'), (r_cco, 'data.view_prices'),
        (r_price, 'module.pricing.edit'), (r_price, 'module.pricing.view'),
        (r_fin, 'action.metal_prices'), (r_fin, 'module.pricing.view'),
        (r_fin, 'module.finance.edit'), (r_fin, 'module.finance.view'),
        (r_fin, 'module.output.edit'), (r_fin, 'module.output.view'),
        (r_fin, 'module.inbound.edit'), (r_fin, 'module.inbound.view'), (r_fin, 'data.view_prices'),
        (r_cto, 'action.apply_assay'), (r_cto, 'module.inbound.edit'), (r_cto, 'module.inbound.view'),
        (r_cto, 'data.view_prices');
    INSERT INTO user_roles (user_id, role_id)
    VALUES (u_sup, r_sup), (u_cco, r_cco), (u_price, r_price), (u_fin, r_fin), (u_cto, r_cto);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX217-S', 'fixture 217 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX217-M', 'fixture 217 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
                                 arrival_date, unit_price, source_reason_code, source_reason_note)
    VALUES ('ZZFIX217-IB', v_mat, v_sup, 100, 100, CURRENT_DATE, 5, 'other', 'fixture 217 自带数据') RETURNING id INTO v_b;
    -- 一份【已应用】的化验,属主路径写好(守卫看不见属主路径 —— 那正是它该有的样子)
    INSERT INTO assay_results (code, inbound_batch_id, assay_date, is_final, weight_basis, result_party,
                               applied_at, applied_by)
    VALUES ('ZZFIX217-AR', v_b, CURRENT_DATE, true, 'as_received', 'ours', now(), u_cto) RETURNING id INTO v_assay;
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct) VALUES (v_assay, 'ni', 40);
    -- 一份既有合同,属主路径建
    INSERT INTO contracts (supplier_id, kind, title, effective_from, status)
    VALUES (v_sup, 'supply', 'fixture 217 existing', CURRENT_DATE, 'active') RETURNING id INTO v_c;

    -- ══════════════ A · 合同 ══════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_sup), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false;
    BEGIN
        INSERT INTO contracts (supplier_id, kind, title, effective_from, status)
        VALUES (v_sup, 'supply', 'fixture 217 A1', CURRENT_DATE, 'draft');
    EXCEPTION WHEN insufficient_privilege THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 217A1 失败:只持 suppliers.edit 的人建得了合同 —— 合同条款该只归 action.contract_terms'; END IF;
    v_denied := false;
    BEGIN
        UPDATE contracts SET notes = 'A2' WHERE id = v_c;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg <> 'PERMISSION_DENIED|action.contract_terms' THEN
        RAISE EXCEPTION 'FIXTURE 217A2 失败:只持 suppliers.edit 的人改合同该按名拒 PERMISSION_DENIED|action.contract_terms,实得 %',
            CASE WHEN v_denied THEN v_msg ELSE '(成功了,或静默零行)' END; END IF;
    v_denied := false;
    BEGIN
        INSERT INTO contract_grade_specs (contract_id, metal, min_pct) VALUES (v_c, 'ni', 18);
    EXCEPTION WHEN insufficient_privilege THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 217A3 失败:只持 suppliers.edit 的人写得了品位条款'; END IF;
    EXECUTE 'RESET ROLE';

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cco), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO contracts (supplier_id, kind, title, effective_from, status)
    VALUES (v_sup, 'supply', 'fixture 217 A4', CURRENT_DATE, 'draft') RETURNING id INTO v_c2;
    INSERT INTO contract_grade_specs (contract_id, metal, min_pct) VALUES (v_c2, 'ni', 18);
    UPDATE contracts SET notes = 'A4' WHERE id = v_c;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    EXECUTE 'RESET ROLE';
    IF v_n <> 1 OR (SELECT count(*) FROM contract_grade_specs WHERE contract_id = v_c2) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 217A4 失败:持 action.contract_terms 的人建合同 / 写条款 / 改合同没有全部落地'; END IF;
    rep := rep || jsonb_build_object('A_contracts', 'ok');

    -- ══════════════ B · 金属行情 ══════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_price), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false;
    BEGIN
        PERFORM upsert_metal_prices(CURRENT_DATE, '[{"metal":"ni","price":20000}]'::jsonb);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg <> 'PERMISSION_DENIED|action.metal_prices' THEN
        RAISE EXCEPTION 'FIXTURE 217B1 失败:只持 pricing.edit 的人调 upsert_metal_prices 该按名拒,实得 %',
            CASE WHEN v_denied THEN v_msg ELSE '(成功了)' END; END IF;
    v_denied := false;
    BEGIN
        INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source)
        VALUES ('ni', 20000, CURRENT_DATE, 'broker_quote');
    EXCEPTION WHEN insufficient_privilege THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 217B2 失败:只持 pricing.edit 的人直连插得进行情'; END IF;
    v_denied := false;
    BEGIN
        UPDATE pricing_settings SET metal_quote_stale_days = metal_quote_stale_days;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg <> 'PERMISSION_DENIED|action.metal_prices' THEN
        RAISE EXCEPTION 'FIXTURE 217B3 失败:只持 pricing.edit 的人改报价阈值该按名拒,实得 %',
            CASE WHEN v_denied THEN v_msg ELSE '(成功了,或静默零行)' END; END IF;
    -- 公式仍归 pricing.edit
    INSERT INTO pricing_formulas (code, name, direction, price_basis, treatment_charge_usd_per_tonne, flat_discount_pct)
    VALUES ('ZZFIX217-PF1', 'fixture 217 formula by pricing.edit', 'purchase', 'spot', 0, 0);
    EXECUTE 'RESET ROLE';

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source)
    VALUES ('ni', 20000, CURRENT_DATE, 'broker_quote') RETURNING id INTO v_mp;
    UPDATE pricing_settings SET metal_quote_stale_days = metal_quote_stale_days;
    v_denied := false;
    BEGIN
        INSERT INTO pricing_formulas (code, name, direction, price_basis, treatment_charge_usd_per_tonne, flat_discount_pct)
        VALUES ('ZZFIX217-PF2', 'fixture 217 formula by metal_prices', 'purchase', 'spot', 0, 0);
    EXCEPTION WHEN insufficient_privilege THEN v_denied := true; END;
    EXECUTE 'RESET ROLE';
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 217B4 失败:只持 action.metal_prices 的人建得了定价公式 —— 公式该只归 pricing.edit'; END IF;
    IF v_mp IS NULL OR NOT EXISTS (SELECT 1 FROM metal_prices WHERE id = v_mp)
       OR NOT EXISTS (SELECT 1 FROM pricing_formulas WHERE code = 'ZZFIX217-PF1') THEN
        RAISE EXCEPTION 'FIXTURE 217B5 失败:持 action.metal_prices 的行情 / 持 pricing.edit 的公式没有落地'; END IF;
    rep := rep || jsonb_build_object('B_metal_prices', 'ok');

    -- ══════════════ C · 直接销售 ══════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false;
    BEGIN
        PERFORM record_output_sale(gen_random_uuid(), 1, 1, 'USD', NULL, NULL, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg <> 'PERMISSION_DENIED|action.direct_sale' THEN
        RAISE EXCEPTION 'FIXTURE 217C1 失败:只持 output.edit 的人直接销售该按名拒,实得 %',
            CASE WHEN v_denied THEN v_msg ELSE '(成功了)' END; END IF;
    FOREACH v_msg IN ARRAY ARRAY['insert', 'update', 'delete'] LOOP
        v_denied := false;
        BEGIN
            IF v_msg = 'insert' THEN
                INSERT INTO sales_records (output_batch_id, quantity, unit_price, currency, fx_rate, amount_base, sale_date)
                VALUES (gen_random_uuid(), 1, 1, 'USD', 1, 1, CURRENT_DATE);
            ELSIF v_msg = 'update' THEN
                UPDATE sales_records SET notes = notes WHERE id = gen_random_uuid();
            ELSE
                DELETE FROM sales_records WHERE id = gen_random_uuid();
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_denied := SQLERRM = 'SALE_THROUGH_FUNCTION_ONLY';
            IF NOT v_denied THEN
                RAISE EXCEPTION 'FIXTURE 217C2 失败:finance.edit 直连 % sales_records 该按名拒 SALE_THROUGH_FUNCTION_ONLY,实得 %', v_msg, SQLERRM;
            END IF;
        END;
        IF NOT v_denied THEN
            RAISE EXCEPTION 'FIXTURE 217C2 失败:finance.edit 直连 % sales_records 没有抛(零行静默也算失败)', v_msg; END IF;
    END LOOP;
    EXECUTE 'RESET ROLE';

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cco), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_msg := NULL;
    BEGIN
        PERFORM record_output_sale(gen_random_uuid(), 1, 1, 'USD', NULL, NULL, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    EXECUTE 'RESET ROLE';
    IF v_msg IS NULL OR v_msg LIKE 'PERMISSION_DENIED%' THEN
        RAISE EXCEPTION 'FIXTURE 217C3 失败:持 action.direct_sale 的人该过门、撞上数据拒绝,实得 %', COALESCE(v_msg, '(成功了 —— 一个不存在的批次卖出去了)'); END IF;
    rep := rep || jsonb_build_object('C_direct_sale', 'ok', 'C3_holder_reaches', split_part(v_msg, '|', 1));

    -- ══════════════ D · 化验 ══════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    FOREACH v_msg IN ARRAY ARRAY['apply', 'apply_output', 'unapply', 'preview', 'preview_output'] LOOP
        v_denied := false;
        BEGIN
            IF v_msg = 'apply' THEN PERFORM apply_assay_result(v_assay);
            ELSIF v_msg = 'apply_output' THEN PERFORM apply_output_assay(v_assay);
            ELSIF v_msg = 'unapply' THEN PERFORM unapply_assay_result(v_assay, 'fixture 217');
            ELSIF v_msg = 'preview' THEN PERFORM preview_assay_price(v_b, '[{"metal":"ni","content_pct":40}]'::jsonb, CURRENT_DATE);
            ELSE PERFORM preview_apply_output_assay(gen_random_uuid());
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_denied := SQLERRM = 'PERMISSION_DENIED|action.apply_assay';
            IF NOT v_denied THEN
                RAISE EXCEPTION 'FIXTURE 217D1 失败:只持 inbound/output.edit 的人 % 该按名拒 PERMISSION_DENIED|action.apply_assay,实得 %', v_msg, SQLERRM;
            END IF;
        END;
        IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 217D1 失败:只持 inbound/output.edit 的人 % 成功了', v_msg; END IF;
    END LOOP;
    -- 记录仍归 inbound.edit
    v_rec := record_assay_result(p_inbound_batch_id => v_b, p_assay_date => CURRENT_DATE,
        p_metals => '[{"metal":"ni","content_pct":41}]'::jsonb, p_weight_basis => 'as_received', p_result_party => 'ours');
    IF v_rec->>'assay_result_id' IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 217D2 失败:持 inbound.edit 的人记录化验没有落地:%', v_rec; END IF;
    -- 侧门一:应用标记
    FOREACH v_msg IN ARRAY ARRAY['applied_at', 'superseded_by', 'insert_applied'] LOOP
        v_denied := false;
        BEGIN
            IF v_msg = 'applied_at' THEN
                UPDATE assay_results SET applied_at = now(), applied_by = u_fin WHERE id = (v_rec->>'assay_result_id')::uuid;
            ELSIF v_msg = 'superseded_by' THEN
                UPDATE assay_results SET superseded_by = (v_rec->>'assay_result_id')::uuid WHERE id = v_assay;
            ELSE
                INSERT INTO assay_results (code, inbound_batch_id, assay_date, is_final, weight_basis, result_party, applied_at)
                VALUES ('ZZFIX217-AR3', v_b, CURRENT_DATE, true, 'as_received', 'ours', now());
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_denied := SQLERRM = 'ASSAY_APPLY_THROUGH_FUNCTION_ONLY';
            IF NOT v_denied THEN
                RAISE EXCEPTION 'FIXTURE 217D3 失败:直连 % 该按名拒 ASSAY_APPLY_THROUGH_FUNCTION_ONLY,实得 %', v_msg, SQLERRM;
            END IF;
        END;
        IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 217D3 失败:直连 % 成功了 —— 应用标记可以不经 action.apply_assay 写上', v_msg; END IF;
    END LOOP;
    UPDATE assay_results SET notes = 'fixture 217 D4' WHERE id = v_assay;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 217D4 失败:记录的人改不了化验备注(% 行)', v_n; END IF;
    -- 侧门二:出自化验的含量
    v_denied := false;
    BEGIN
        INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source, source_assay_id)
        VALUES (v_b, 'co', 5, 'assay', v_assay);
    EXCEPTION WHEN OTHERS THEN
        v_denied := SQLERRM = 'ASSAY_CONTENT_THROUGH_FUNCTION_ONLY';
        IF NOT v_denied THEN
            RAISE EXCEPTION 'FIXTURE 217D5 失败:直连写一行出处 assay 的含量该按名拒,实得 %', SQLERRM; END IF;
    END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 217D5 失败:直连写一行出处 assay 的含量成功了'; END IF;
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source)
    VALUES (v_b, 'co', 5, 'manual');
    EXECUTE 'RESET ROLE';

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cto), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM unapply_assay_result(v_assay, 'fixture 217 D6');
    EXECUTE 'RESET ROLE';
    IF (SELECT applied_at FROM assay_results WHERE id = v_assay) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 217D6 失败:持 action.apply_assay 的人撤销应用没有落地'; END IF;
    rep := rep || jsonb_build_object('D_assay', 'ok');

    -- ══════════════ E · 故障注入 ══════════════
    ALTER TABLE assay_results DISABLE TRIGGER trg_assay_results_applied_columns;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE assay_results SET applied_at = now(), applied_by = u_fin WHERE id = v_assay;
    EXECUTE 'RESET ROLE';
    ALTER TABLE assay_results ENABLE TRIGGER trg_assay_results_applied_columns;
    IF (SELECT applied_by FROM assay_results WHERE id = v_assay) IS DISTINCT FROM u_fin THEN
        RAISE EXCEPTION 'FIXTURE 217E1 失败:注入没有生效 —— 摘掉守卫之后直连写 applied_at 应当写得进去'; END IF;

    ALTER TABLE sales_records DISABLE TRIGGER trg_sales_records_direct_write;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_msg := NULL;
    BEGIN
        UPDATE sales_records SET notes = notes WHERE id = gen_random_uuid();
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    EXECUTE 'RESET ROLE';
    ALTER TABLE sales_records ENABLE TRIGGER trg_sales_records_direct_write;
    IF v_msg IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 217E2 失败:注入没有生效 —— 摘掉守卫之后直连 UPDATE 应当是一次静默的空操作,实得 %', v_msg; END IF;
    rep := rep || jsonb_build_object('E_guards_are_load_bearing', true);

    RAISE NOTICE 'FIXTURE 217 全部通过 %', rep::text;
END $$;
ROLLBACK;
