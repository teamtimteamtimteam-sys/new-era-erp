-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 303 —— 结算金额与合同条款上的价格是价格(GOLIVE-1 第 12 行,Tim 2026-10-25 TABLE-EXPORT-3c Q3 · 2026-10-29 Q9)
-- ═══════════════════════════════════════════════════════════════════════════
-- 【钉的事】五张表的价格列从此只经 <表>_masked 读,按【合同那一侧】置空(客户 → data.view_prices,供应商 → data.view_purchase_prices;
--   结算是销售那一侧,只问 data.view_prices):
--   A  只持销售价格码的读者(customers.view + suppliers.view + data.view_prices):客户合同的 payable_pct · 精炼费 · 罚则费率 · 保险最低金额
--      与结算的六列钱看得见;供应商合同的保险最低金额是 NULL(受限)
--   B  只持采购价格码的读者(… + data.view_purchase_prices):反过来 —— 客户那一侧全是 NULL、结算的钱是 NULL(重量照给),
--      供应商合同的保险最低金额看得见;list_totals_settlements 回一行 restricted
--   C  基表:任何 authenticated 读者直接 SELECT 价格列 → 42501(列级授权里没有它);不是钱的列照读得到
--   D  行的门没有因为属主权限而丢:只持 suppliers.view 的读者在客户合同的伴生视图里 0 行、在结算伴生视图里 0 行;
--      供应商合同那一行他读得到,而保险最低金额是 NULL(他不持 data.view_purchase_prices)
--   E  变更记录的遮蔽规则:change_log_mask_gaps() 没有缺口;contract_price 规则对 B 答 false、对 A 答 true(同一支 contract_terms_price_visible)
--   F  ★ 故障注入(每次都跑):子事务里把 contract_refining_charges_masked 的判据换成 true,B 的判据必须读出精炼费;子事务回滚
-- 自带数据:角色、授予、客户、供应商、物料、产出批次、化验、销售单、两份合同与它们的条款、一行结算全部本支自造。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '120s';

CREATE FUNCTION pg_temp.f303_read(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN jsonb_build_object('error', SQLSTATE || ' ' || SQLERRM);
END;
$f$;

DO $f303$
DECLARE
    u_p  uuid := '00000000-0000-4000-8000-0000030300a1';   -- 销售价格码
    u_u  uuid := '00000000-0000-4000-8000-0000030300a2';   -- 采购价格码
    u_s  uuid := '00000000-0000-4000-8000-0000030300a3';   -- 只有 suppliers.view
    v_cust uuid; v_sup uuid; v_mat uuid; v_ob uuid; v_as uuid; v_so uuid; v_cc uuid; v_sc uuid; v_rc uuid;
    v jsonb;
    q_cust text;
    v_def text;
BEGIN
    INSERT INTO roles (code, name_en, name_zh) VALUES ('zz-fx303-p', 'ZZ 303 p', 'ZZ 303 p'), ('zz-fx303-u', 'ZZ 303 u', 'ZZ 303 u'), ('zz-fx303-s', 'ZZ 303 s', 'ZZ 303 s');
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r.id, c FROM roles r, unnest(ARRAY['module.customers.view', 'module.suppliers.view']) c WHERE r.code IN ('zz-fx303-p', 'zz-fx303-u');
    INSERT INTO role_permissions (role_id, permission_code) SELECT id, 'data.view_prices' FROM roles WHERE code = 'zz-fx303-p';
    INSERT INTO role_permissions (role_id, permission_code) SELECT id, 'data.view_purchase_prices' FROM roles WHERE code = 'zz-fx303-u';
    INSERT INTO role_permissions (role_id, permission_code) SELECT id, 'module.suppliers.view' FROM roles WHERE code = 'zz-fx303-s';
    INSERT INTO user_roles (user_id, role_id) SELECT u_p, id FROM roles WHERE code = 'zz-fx303-p';
    INSERT INTO user_roles (user_id, role_id) SELECT u_u, id FROM roles WHERE code = 'zz-fx303-u';
    INSERT INTO user_roles (user_id, role_id) SELECT u_s, id FROM roles WHERE code = 'zz-fx303-s';

    INSERT INTO laboratories (code, name_en, name_zh, is_active, sort_order) VALUES ('ZZ303-LAB', 'Fixture 303 lab', '示例实验室', true, 903);
    INSERT INTO customers (code, legal_name, country, payment_terms_days) VALUES ('ZZ303-C1', 'Fixture 303 Customer', 'SG', 30) RETURNING id INTO v_cust;
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type) VALUES ('active', 'ZZ303-S1', 'Fixture 303 Supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
        VALUES ('ZZ303-M1', 'Fixture 303 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date) VALUES ('ZZ303-OB1', v_mat, 1000, 1000, DATE '2026-09-14') RETURNING id INTO v_ob;
    INSERT INTO assay_results (code, output_batch_id, assay_date, is_final, weight_basis, moisture_pct, result_party, lab_name)
        VALUES ('ZZ303-AS1', v_ob, DATE '2026-09-15', true, 'dry', 10, 'ours', 'ZZ303-LAB') RETURNING id INTO v_as;
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate) VALUES ('ZZ303-SO1', v_cust, DATE '2026-09-10', 'SGD', 1) RETURNING id INTO v_so;

    INSERT INTO contracts (customer_id, kind, title, effective_from, status) VALUES (v_cust, 'offtake', 'Fixture 303 sell', DATE '2026-01-01', 'draft') RETURNING id INTO v_cc;
    INSERT INTO contracts (supplier_id, kind, title, effective_from, status) VALUES (v_sup, 'supply', 'Fixture 303 buy', DATE '2026-01-01', 'draft') RETURNING id INTO v_sc;
    INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct) VALUES (v_cc, 'ni', 'assay_complete', 0, 'LME', 70);
    INSERT INTO contract_refining_charges (contract_id, metal, usd_per_tonne_of_metal) VALUES (v_cc, 'ni', 100) RETURNING id INTO v_rc;
    INSERT INTO contract_penalty_elements (contract_id, substance, threshold_pct, usd_per_tonne_per_pct_over) VALUES (v_cc, 'f', 0.5, 50);
    INSERT INTO contract_insurance_obligations (contract_id, insured_by, cover_type, min_amount, currency) VALUES
        (v_cc, 'us', 'cargo', 1000, 'SGD'), (v_sc, 'counterparty', 'cargo', 2000, 'SGD');
    INSERT INTO sales_settlements (sales_order_id, output_batch_id, assay_result_id, settling_party_used, weight_basis_used,
                                   gross_weight_kg, settlement_weight_kg, metal_value_usd, refining_charge_usd, penalty_usd, amount_usd, breakdown, terms_snapshot)
        VALUES (v_so, v_ob, v_as, 'ours', 'dry', 1000, 1000, 5000, 100, 25, 4875, '{"ni": 1}', '{"refining": 100}');

    q_cust := format($q$SELECT jsonb_build_object(
        'payable', (SELECT payable_pct FROM contract_pricing_terms_masked WHERE contract_id = %1$L),
        'rc', (SELECT usd_per_tonne_of_metal FROM contract_refining_charges_masked WHERE contract_id = %1$L),
        'pen', (SELECT usd_per_tonne_per_pct_over FROM contract_penalty_elements_masked WHERE contract_id = %1$L),
        'ins_c', (SELECT min_amount FROM contract_insurance_obligations_masked WHERE contract_id = %1$L),
        'ins_s', (SELECT min_amount FROM contract_insurance_obligations_masked WHERE contract_id = %2$L),
        'amount', (SELECT amount_usd FROM sales_settlements_masked WHERE sales_order_id = %3$L),
        'breakdown', (SELECT breakdown FROM sales_settlements_masked WHERE sales_order_id = %3$L),
        'weight', (SELECT settlement_weight_kg FROM sales_settlements_masked WHERE sales_order_id = %3$L),
        'rows_c', (SELECT count(*) FROM contract_refining_charges_masked WHERE contract_id = %1$L) + (SELECT count(*) FROM contract_pricing_terms_masked WHERE contract_id = %1$L),
        'rows_settle', (SELECT count(*) FROM sales_settlements_masked WHERE sales_order_id = %3$L))$q$, v_cc, v_sc, v_so);

    -- A
    v := pg_temp.f303_read(u_p, q_cust);
    IF v ->> 'payable' IS DISTINCT FROM '70' OR v ->> 'rc' IS DISTINCT FROM '100' OR v ->> 'pen' IS DISTINCT FROM '50' OR v ->> 'ins_c' IS DISTINCT FROM '1000'
       OR v ->> 'amount' IS DISTINCT FROM '4875' OR v -> 'breakdown' IS DISTINCT FROM '{"ni": 1}'::jsonb OR v -> 'ins_s' IS DISTINCT FROM 'null'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 303 A: a sales-price reader — %', v;
    END IF;
    -- B
    v := pg_temp.f303_read(u_u, q_cust);
    IF v -> 'payable' <> 'null'::jsonb OR v -> 'rc' <> 'null'::jsonb OR v -> 'pen' <> 'null'::jsonb OR v -> 'ins_c' <> 'null'::jsonb
       OR v -> 'amount' <> 'null'::jsonb OR v -> 'breakdown' <> 'null'::jsonb OR v ->> 'weight' IS DISTINCT FROM '1000' OR v ->> 'ins_s' IS DISTINCT FROM '2000'
       OR (v ->> 'rows_c')::int <> 2 OR (v ->> 'rows_settle')::int <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 303 B: a purchase-price reader — %', v;
    END IF;
    v := pg_temp.f303_read(u_u, 'SELECT to_jsonb(t) FROM list_totals_settlements() t');
    IF (v ->> 'restricted')::boolean IS DISTINCT FROM true OR v -> 'total' <> 'null'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 303 B: the settlements footer for a reader without data.view_prices should be one restricted row — %', v;
    END IF;
    v := pg_temp.f303_read(u_p, 'SELECT to_jsonb(t) FROM list_totals_settlements() t');
    IF (v ->> 'restricted')::boolean IS DISTINCT FROM false OR v ->> 'total' IS DISTINCT FROM '4875.00' THEN
        RAISE EXCEPTION 'FIXTURE 303 B: the settlements footer for a sales-price reader — %', v;
    END IF;
    -- C
    v := pg_temp.f303_read(u_p, 'SELECT to_jsonb(count(usd_per_tonne_of_metal)) FROM contract_refining_charges');
    IF v ->> 'error' NOT LIKE '42501%' THEN RAISE EXCEPTION 'FIXTURE 303 C: the base table still hands out the refining charge — %', v; END IF;
    v := pg_temp.f303_read(u_p, 'SELECT to_jsonb(count(amount_usd)) FROM sales_settlements');
    IF v ->> 'error' NOT LIKE '42501%' THEN RAISE EXCEPTION 'FIXTURE 303 C: the base table still hands out the settlement amount — %', v; END IF;
    v := pg_temp.f303_read(u_p, format('SELECT to_jsonb(count(*)) FROM contract_refining_charges WHERE contract_id = %L AND metal = ''ni''', v_cc));
    IF v IS DISTINCT FROM '1'::jsonb THEN RAISE EXCEPTION 'FIXTURE 303 C: the non-price columns should still read — %', v; END IF;
    -- D
    v := pg_temp.f303_read(u_s, q_cust);
    IF (v ->> 'rows_c')::int <> 0 OR (v ->> 'rows_settle')::int <> 0 OR v -> 'ins_s' IS DISTINCT FROM 'null'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 303 D: a suppliers-only reader — %', v;
    END IF;
    -- E
    IF jsonb_array_length(change_log_mask_gaps() -> 'gaps') <> 0 THEN RAISE EXCEPTION 'FIXTURE 303 E: mask gaps %', change_log_mask_gaps(); END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_u), true);
    IF change_log_rule_visible('contract_price', 'contract_refining_charges', jsonb_build_object('id', v_rc), NULL, jsonb_build_object('contract_id', v_cc)) THEN
        RAISE EXCEPTION 'FIXTURE 303 E: the change-history rule shows a customer-contract rate to a purchase-price reader';
    END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_p), true);
    IF NOT change_log_rule_visible('contract_price', 'contract_refining_charges', jsonb_build_object('id', v_rc), NULL, jsonb_build_object('contract_id', v_cc)) THEN
        RAISE EXCEPTION 'FIXTURE 303 E: the change-history rule hides a customer-contract rate from a sales-price reader';
    END IF;
    PERFORM set_config('request.jwt.claims', '', true);
    -- F · 故障注入
    v_def := pg_get_viewdef('public.contract_refining_charges_masked'::regclass);
    BEGIN
        EXECUTE 'CREATE OR REPLACE VIEW public.contract_refining_charges_masked WITH (security_invoker = off) AS '
             || replace(rtrim(v_def, '; ' || chr(10)), 'contract_terms_price_visible(t.contract_id)', 'true');
        v := pg_temp.f303_read(u_u, q_cust);
        IF v ->> 'rc' IS DISTINCT FROM '100' THEN
            RAISE EXCEPTION 'FIXTURE 303 F: with the predicate removed arm B still read % — it does not measure the predicate', v ->> 'rc';
        END IF;
        RAISE EXCEPTION 'f303 injection ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'f303 injection ok' THEN RAISE; END IF;
    END;
    IF pg_get_viewdef('public.contract_refining_charges_masked'::regclass) <> v_def THEN RAISE EXCEPTION 'FIXTURE 303 F: the injection did not roll back'; END IF;
    RAISE NOTICE 'FIXTURE 303 全部通过: 销售价格码看得见客户合同与结算的钱、看不见供应商那一侧(A);采购价格码反过来、表尾受限(B);基表的价格列 42501(C);行的门还在(D);遮蔽规则无缺口、contract_price 判得对(E);判据拿掉,B 读得到精炼费(F)';
END
$f303$;
ROLLBACK;
