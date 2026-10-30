-- fixture 304 —— 合同条款的冻结副本按【副本自己那一侧】遮价格;条款申请的快照整份受限;结算的算术只由记录那一支调(GOLIVE-2,v1.4.84)
-- ═══════════════════════════════════════════════════════════════════════════
-- Tim 2026-10-30 Q4 · Q5 · Q6。数据自带(两份合同、一张销售单、一张采购单,经 link_document_to_contract 真的挂上去冻出两份副本)。
-- 【读者】p = 客户 + 供应商两个模块码 + data.view_prices;u = 同两个模块码 + data.view_purchase_prices;
--        e = 客户模块编辑码 + 产出 · 质量 · 定价的读码(结算的算术要读计价期均价),没有 data.view_prices(Q5 的那一位)。
-- 【A】p 读 contract_document_terms_masked:销售单那一份三样价格都在(payable 70 · 精炼费 100 · 罚则 50);采购单那一份三样都是 null,
--      品位规格与质量限值照旧在(Q4:只遮三样)。
-- 【B】u 反过来:销售单那一份三样 null、采购单那一份三样都在;两份的行都读得到(行门是模块码,不是价格码)。
-- 【C】基表 contract_document_terms 的 pricing_terms / settlement_terms 对 authenticated 是 42501;不带价格的列照读(/contracts 与采购单页读的那几列)。
-- 【D】变更记录:cdt_price 规则按副本那一侧判得对(p 看销售单那份、看不见采购单那份,u 反过来);change_log_mask_gaps() 无缺口。
-- 【E】条款申请(Q6):一张合同申请,u(不持客户合同那一侧的 data.view_prices)从 terms_requests_visible 读到的 snapshot 是 NULL、p 读到原样;
--      terms_requests_masked 同一个答案;基表的 snapshot 列 42501;tr_snapshot 规则同一个答案。
-- 【F】Q5:以 authenticated 直接调 sale_settlement_compute → 在【函数】上 42501(不是一个算出来的数);record_sale_settlement 对 e 写下结算、返回的六样钱
--      是 {"$restricted": true},而 sales_settlements 里存的是真数;对 p(补上 customers.edit)返回真数。
-- 【G】故障注入:在子事务里把 contract_document_terms_masked 的判据换成 true —— u 必须读到销售单那份的 payable 70(判据真的在量);
--      再把 sale_settlement_compute 的 EXECUTE 授回 authenticated —— 直接调必须不再在函数上被拒(那一格量的是函数的授权,不是别的门)。两者回滚后核对还原。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '120s';

CREATE FUNCTION pg_temp.f304_read(p_user uuid, p_sql text) RETURNS jsonb
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
    RETURN jsonb_build_object('error', SQLSTATE || ' ' || split_part(SQLERRM, '|', 1));
END;
$f$;

DO $f304$
DECLARE
    u_p uuid := '00000000-0000-4000-8000-0000030400a1';
    u_u uuid := '00000000-0000-4000-8000-0000030400a2';
    u_e uuid := '00000000-0000-4000-8000-0000030400a3';
    u_x uuid := '00000000-0000-4000-8000-0000030400a4';   -- 造数据的那一位:挂合同要两侧的编辑码
    v_cust uuid; v_sup uuid; v_mat uuid; v_ob uuid; v_as uuid; v_ob2 uuid; v_as2 uuid; v_so uuid; v_po uuid; v_cc uuid; v_sc uuid; v_tr uuid;
    v jsonb; q text; v_def text;
BEGIN
    INSERT INTO roles (code, name_en, name_zh) VALUES ('zz-fx304-p', 'ZZ 304 p', 'ZZ 304 p'), ('zz-fx304-u', 'ZZ 304 u', 'ZZ 304 u'), ('zz-fx304-e', 'ZZ 304 e', 'ZZ 304 e');
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r.id, c FROM roles r, unnest(ARRAY['module.customers.view', 'module.suppliers.view']) c WHERE r.code IN ('zz-fx304-p', 'zz-fx304-u', 'zz-fx304-e');
    INSERT INTO role_permissions (role_id, permission_code) SELECT id, 'data.view_prices' FROM roles WHERE code = 'zz-fx304-p';
    INSERT INTO role_permissions (role_id, permission_code) SELECT id, 'data.view_purchase_prices' FROM roles WHERE code = 'zz-fx304-u';
    INSERT INTO role_permissions (role_id, permission_code) SELECT id, c FROM roles, unnest(ARRAY['module.customers.edit', 'module.output.view', 'module.quality.view', 'module.pricing.view']) c WHERE code = 'zz-fx304-e';
    INSERT INTO user_roles (user_id, role_id) SELECT u_p, id FROM roles WHERE code = 'zz-fx304-p';
    INSERT INTO user_roles (user_id, role_id) SELECT u_u, id FROM roles WHERE code = 'zz-fx304-u';
    INSERT INTO user_roles (user_id, role_id) SELECT u_e, id FROM roles WHERE code = 'zz-fx304-e';
    INSERT INTO roles (code, name_en, name_zh) VALUES ('zz-fx304-x', 'ZZ 304 x', 'ZZ 304 x');
    INSERT INTO role_permissions (role_id, permission_code) SELECT id, c FROM roles, unnest(ARRAY['module.customers.edit', 'module.suppliers.edit', 'module.customers.view', 'module.suppliers.view']) c WHERE code = 'zz-fx304-x';
    INSERT INTO user_roles (user_id, role_id) SELECT u_x, id FROM roles WHERE code = 'zz-fx304-x';

    INSERT INTO index_market_calendar (index_code, calendar_date, is_trading_day, note)
    SELECT 'LME', d::date, EXTRACT(ISODOW FROM d) < 6, 'fixture 304' FROM generate_series(DATE '2026-09-01', DATE '2026-09-30', interval '1 day') d
        ON CONFLICT DO NOTHING;
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source, price_index)
    SELECT 'ni', 10000, c.calendar_date, 'published_index', 'LME' FROM index_market_calendar c WHERE c.index_code = 'LME' AND c.is_trading_day
       AND c.calendar_date BETWEEN DATE '2026-09-01' AND DATE '2026-09-30';
    INSERT INTO laboratories (code, name_en, name_zh, is_active, sort_order) VALUES ('ZZ304-LAB', 'Fixture 304 lab', '示例实验室', true, 904);
    INSERT INTO customers (code, legal_name, country, payment_terms_days) VALUES ('ZZ304-C1', 'Fixture 304 Customer', 'SG', 30) RETURNING id INTO v_cust;
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type) VALUES ('active', 'ZZ304-S1', 'Fixture 304 Supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
        VALUES ('ZZ304-M1', 'Fixture 304 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date) VALUES ('ZZ304-OB1', v_mat, 10000, 10000, DATE '2026-09-14') RETURNING id INTO v_ob;
    INSERT INTO assay_results (code, output_batch_id, assay_date, is_final, weight_basis, moisture_pct, result_party, lab_name)
        VALUES ('ZZ304-AS1', v_ob, DATE '2026-09-15', true, 'dry', 10, 'ours', 'ZZ304-LAB') RETURNING id INTO v_as;
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct) VALUES (v_as, 'ni', 20), (v_as, 'f', 2.5);
    -- 第二批:一张单、一批只许一份在册的结算(sales_settlements_one_live_per_order_batch),所以 p 那一次结算另一批
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date) VALUES ('ZZ304-OB2', v_mat, 10000, 10000, DATE '2026-09-14') RETURNING id INTO v_ob2;
    INSERT INTO assay_results (code, output_batch_id, assay_date, is_final, weight_basis, moisture_pct, result_party, lab_name)
        VALUES ('ZZ304-AS2', v_ob2, DATE '2026-09-15', true, 'dry', 10, 'ours', 'ZZ304-LAB') RETURNING id INTO v_as2;
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct) VALUES (v_as2, 'ni', 20), (v_as2, 'f', 2.5);

    INSERT INTO contracts (customer_id, kind, title, effective_from, status) VALUES (v_cust, 'offtake', 'Fixture 304 sell', DATE '2026-01-01', 'active') RETURNING id INTO v_cc;
    INSERT INTO contracts (supplier_id, kind, title, effective_from, status) VALUES (v_sup, 'supply', 'Fixture 304 buy', DATE '2026-01-01', 'active') RETURNING id INTO v_sc;
    INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct) VALUES (v_cc, 'ni', 'assay_complete', 0, 'LME', 70), (v_sc, 'ni', 'assay_complete', 0, 'LME', 80);
    INSERT INTO contract_settlement_terms (contract_id, sale_weight_basis, settling_party, sample_retention_required, refining_charge_basis, penalty_basis)
        VALUES (v_cc, 'dry', 'ours', false, 'per_metal', 'per_element'), (v_sc, 'dry', 'ours', false, 'per_metal', 'per_element');
    INSERT INTO contract_refining_charges (contract_id, metal, usd_per_tonne_of_metal) VALUES (v_cc, 'ni', 100), (v_sc, 'ni', 200);
    INSERT INTO contract_penalty_elements (contract_id, substance, threshold_pct, usd_per_tonne_per_pct_over) VALUES (v_cc, 'f', 0.5, 50), (v_sc, 'f', 0.5, 60);
    INSERT INTO contract_grade_specs (contract_id, metal, min_pct, max_pct) VALUES (v_cc, 'ni', 10, 30), (v_sc, 'ni', 10, 30);
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate) VALUES ('ZZ304-SO1', v_cust, DATE '2026-06-10', 'SGD', 1) RETURNING id INTO v_so;
    INSERT INTO purchase_orders (code, supplier_id, order_date, status, currency, fx_rate, category)
        VALUES ('ZZ304-PO1', v_sup, DATE '2026-06-10', 'confirmed', 'SGD', 1, 'equipment_goods') RETURNING id INTO v_po;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_x), true);
    PERFORM link_document_to_contract('sales_order', v_so, v_cc);
    PERFORM link_document_to_contract('purchase_order', v_po, v_sc);
    PERFORM set_config('request.jwt.claims', '', true);

    q := format($q$SELECT jsonb_build_object(
        'so_pay', (SELECT pricing_terms -> 0 -> 'payable_pct' FROM contract_document_terms_masked WHERE sales_order_id = %1$L),
        'so_rc',  (SELECT settlement_terms -> 'refining_charges' -> 0 -> 'usd_per_tonne_of_metal' FROM contract_document_terms_masked WHERE sales_order_id = %1$L),
        'so_pen', (SELECT settlement_terms -> 'penalty_elements' -> 0 -> 'usd_per_tonne_per_pct_over' FROM contract_document_terms_masked WHERE sales_order_id = %1$L),
        'so_grade', (SELECT grade_specs -> 0 -> 'max_pct' FROM contract_document_terms_masked WHERE sales_order_id = %1$L),
        'so_thr', (SELECT settlement_terms -> 'penalty_elements' -> 0 -> 'threshold_pct' FROM contract_document_terms_masked WHERE sales_order_id = %1$L),
        'po_pay', (SELECT pricing_terms -> 0 -> 'payable_pct' FROM contract_document_terms_masked WHERE purchase_order_id = %2$L),
        'po_rc',  (SELECT settlement_terms -> 'refining_charges' -> 0 -> 'usd_per_tonne_of_metal' FROM contract_document_terms_masked WHERE purchase_order_id = %2$L),
        'po_pen', (SELECT settlement_terms -> 'penalty_elements' -> 0 -> 'usd_per_tonne_per_pct_over' FROM contract_document_terms_masked WHERE purchase_order_id = %2$L),
        'po_grade', (SELECT grade_specs -> 0 -> 'max_pct' FROM contract_document_terms_masked WHERE purchase_order_id = %2$L),
        'rows', (SELECT count(*) FROM contract_document_terms_masked WHERE sales_order_id = %1$L OR purchase_order_id = %2$L))$q$, v_so, v_po);
    -- A
    v := pg_temp.f304_read(u_p, q);
    IF v ->> 'so_pay' IS DISTINCT FROM '70' OR v ->> 'so_rc' IS DISTINCT FROM '100' OR v ->> 'so_pen' IS DISTINCT FROM '50'
       OR v -> 'po_pay' <> 'null'::jsonb OR v -> 'po_rc' <> 'null'::jsonb OR v -> 'po_pen' <> 'null'::jsonb
       OR v ->> 'po_grade' IS DISTINCT FROM '30' OR v ->> 'so_grade' IS DISTINCT FROM '30' OR (v ->> 'rows')::int <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 304 A: a sales-price reader — %', v;
    END IF;
    -- B
    v := pg_temp.f304_read(u_u, q);
    IF v -> 'so_pay' <> 'null'::jsonb OR v -> 'so_rc' <> 'null'::jsonb OR v -> 'so_pen' <> 'null'::jsonb OR v ->> 'so_thr' IS DISTINCT FROM '0.5'
       OR v ->> 'po_pay' IS DISTINCT FROM '80' OR v ->> 'po_rc' IS DISTINCT FROM '200' OR v ->> 'po_pen' IS DISTINCT FROM '60'
       OR v ->> 'so_grade' IS DISTINCT FROM '30' OR (v ->> 'rows')::int <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 304 B: a purchase-price reader — %', v;
    END IF;
    -- C
    v := pg_temp.f304_read(u_p, 'SELECT to_jsonb(count(pricing_terms)) FROM contract_document_terms');
    IF v ->> 'error' NOT LIKE '42501%' THEN RAISE EXCEPTION 'FIXTURE 304 C: the base pricing_terms column should be 42501 — %', v; END IF;
    v := pg_temp.f304_read(u_p, 'SELECT to_jsonb(count(settlement_terms)) FROM contract_document_terms');
    IF v ->> 'error' NOT LIKE '42501%' THEN RAISE EXCEPTION 'FIXTURE 304 C: the base settlement_terms column should be 42501 — %', v; END IF;
    v := pg_temp.f304_read(u_u, format('SELECT to_jsonb(count(*)) FROM contract_document_terms WHERE contract_code IS NOT NULL AND linked_at IS NOT NULL AND (sales_order_id = %L OR purchase_order_id = %L)', v_so, v_po));
    IF v::text <> '2' THEN RAISE EXCEPTION 'FIXTURE 304 C: the unpriced columns should still read — %', v; END IF;
    -- D
    IF jsonb_array_length(change_log_mask_gaps() -> 'gaps') <> 0 THEN RAISE EXCEPTION 'FIXTURE 304 D: mask gaps %', change_log_mask_gaps(); END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_p), true);
    IF NOT change_log_rule_visible('cdt_price', 'contract_document_terms', NULL, NULL, jsonb_build_object('sales_order_id', v_so))
       OR change_log_rule_visible('cdt_price', 'contract_document_terms', NULL, NULL, jsonb_build_object('purchase_order_id', v_po)) THEN
        RAISE EXCEPTION 'FIXTURE 304 D: cdt_price for a sales-price reader';
    END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_u), true);
    IF change_log_rule_visible('cdt_price', 'contract_document_terms', NULL, NULL, jsonb_build_object('sales_order_id', v_so))
       OR NOT change_log_rule_visible('cdt_price', 'contract_document_terms', NULL, NULL, jsonb_build_object('purchase_order_id', v_po)) THEN
        RAISE EXCEPTION 'FIXTURE 304 D: cdt_price for a purchase-price reader';
    END IF;
    PERFORM set_config('request.jwt.claims', '', true);
    -- E · 一张合同申请(数据自带;快照是一个带价格的对象)
    INSERT INTO terms_requests (kind, label, reason, snapshot, fingerprint, contract_id, created_by)
        VALUES ('contract_activate', 'ZZ304 activate', 'fixture 304', '{"current": {"pricing_terms": [{"payable_pct": 70}]}}', 'x', v_cc, u_p) RETURNING id INTO v_tr;
    v := pg_temp.f304_read(u_u, format('SELECT jsonb_build_object(''vis'', (SELECT to_jsonb(t.snapshot) FROM terms_requests_visible(p_contract_id => %1$L) t), ''masked'', (SELECT to_jsonb(snapshot) FROM terms_requests_masked WHERE id = %2$L), ''n'', (SELECT count(*) FROM terms_requests_masked WHERE id = %2$L))', v_cc, v_tr));
    IF v -> 'vis' <> 'null'::jsonb OR v -> 'masked' <> 'null'::jsonb OR (v ->> 'n')::int <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 304 E: a reader without the customer-side price code should read the snapshot as Restricted — %', v;
    END IF;
    v := pg_temp.f304_read(u_p, format('SELECT jsonb_build_object(''vis'', (SELECT to_jsonb(t.snapshot) FROM terms_requests_visible(p_contract_id => %1$L) t), ''masked'', (SELECT to_jsonb(snapshot) FROM terms_requests_masked WHERE id = %2$L))', v_cc, v_tr));
    IF v #>> '{vis,current,pricing_terms,0,payable_pct}' IS DISTINCT FROM '70' OR v #>> '{masked,current,pricing_terms,0,payable_pct}' IS DISTINCT FROM '70' THEN
        RAISE EXCEPTION 'FIXTURE 304 E: a sales-price reader should read the snapshot — %', v;
    END IF;
    v := pg_temp.f304_read(u_p, 'SELECT to_jsonb(count(snapshot)) FROM terms_requests');
    IF v ->> 'error' NOT LIKE '42501%' THEN RAISE EXCEPTION 'FIXTURE 304 E: the base snapshot column should be 42501 — %', v; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_u), true);
    IF change_log_rule_visible('tr_snapshot', 'terms_requests', jsonb_build_object('id', v_tr), NULL, jsonb_build_object('contract_id', v_cc)) THEN
        RAISE EXCEPTION 'FIXTURE 304 E: tr_snapshot shows a customer-contract snapshot to a purchase-price reader';
    END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_p), true);
    IF NOT change_log_rule_visible('tr_snapshot', 'terms_requests', jsonb_build_object('id', v_tr), NULL, jsonb_build_object('contract_id', v_cc)) THEN
        RAISE EXCEPTION 'FIXTURE 304 E: tr_snapshot hides a customer-contract snapshot from a sales-price reader';
    END IF;
    PERFORM set_config('request.jwt.claims', '', true);
    -- F · Q5
    v := pg_temp.f304_read(u_p, format('SELECT sale_settlement_compute(%L, %L, %L)', v_so, v_ob, v_as));
    IF v ->> 'error' NOT LIKE '42501 permission denied for function sale_settlement_compute%' THEN
        RAISE EXCEPTION 'FIXTURE 304 F: a direct call to sale_settlement_compute should be refused on the function itself (42501) — %', v;
    END IF;
    v := pg_temp.f304_read(u_e, format('SELECT record_sale_settlement(%L, %L, %L)', v_so, v_ob, v_as));
    IF v ? 'error' OR v -> 'amount_usd' <> '{"$restricted": true}'::jsonb OR v -> 'metal_value_usd' <> '{"$restricted": true}'::jsonb
       OR v -> 'refining_charge_usd' <> '{"$restricted": true}'::jsonb OR v -> 'penalty_usd' <> '{"$restricted": true}'::jsonb
       OR v -> 'breakdown' <> '{"$restricted": true}'::jsonb OR v -> 'terms_snapshot' <> '{"$restricted": true}'::jsonb
       OR v ->> 'settlement_weight_kg' IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 304 F: record_sale_settlement for a caller without data.view_prices — %', v;
    END IF;
    IF (SELECT amount_usd FROM sales_settlements WHERE id = (v ->> 'settlement_id')::uuid) IS NULL
       OR (SELECT amount_usd FROM sales_settlements WHERE id = (v ->> 'settlement_id')::uuid) <= 0 THEN
        RAISE EXCEPTION 'FIXTURE 304 F: the stored settlement should hold the real amount';
    END IF;
    INSERT INTO role_permissions (role_id, permission_code) SELECT id, c FROM roles, unnest(ARRAY['module.customers.edit', 'module.output.view', 'module.quality.view', 'module.pricing.view']) c WHERE code = 'zz-fx304-p';
    v := pg_temp.f304_read(u_p, format('SELECT record_sale_settlement(%L, %L, %L)', v_so, v_ob2, v_as2));
    IF v ? 'error' THEN
        RAISE EXCEPTION 'FIXTURE 304 F: record_sale_settlement for a sales-price reader — %', v;
    END IF;
    IF jsonb_typeof(v -> 'amount_usd') <> 'number' THEN RAISE EXCEPTION 'FIXTURE 304 F: a sales-price reader should read the amount — %', v; END IF;
    -- G · 故障注入
    v_def := pg_get_viewdef('public.contract_document_terms_masked'::regclass);
    BEGIN
        EXECUTE 'CREATE OR REPLACE VIEW public.contract_document_terms_masked WITH (security_invoker = off) AS '
             || replace(rtrim(v_def, '; ' || chr(10)), 'contract_copy_price_visible(t.sales_order_id, t.purchase_order_id)', 'true');
        v := pg_temp.f304_read(u_u, q);
        IF v ->> 'so_pay' IS DISTINCT FROM '70' THEN
            RAISE EXCEPTION 'FIXTURE 304 G: with the predicate removed reader u still read % — the arm does not measure the predicate', v ->> 'so_pay';
        END IF;
        RAISE EXCEPTION 'f304 injection ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'f304 injection ok' THEN RAISE; END IF;
    END;
    IF pg_get_viewdef('public.contract_document_terms_masked'::regclass) <> v_def THEN RAISE EXCEPTION 'FIXTURE 304 G: the view injection did not roll back'; END IF;
    BEGIN
        GRANT EXECUTE ON FUNCTION public.sale_settlement_compute(uuid, uuid, uuid) TO authenticated;
        v := pg_temp.f304_read(u_p, format('SELECT sale_settlement_compute(%L, %L, %L)', v_so, v_ob, v_as));
        -- 授回之后它不再在【函数】上被拒(它会接着撞上副本的价格列 —— 那是另一道门,也是它为什么只能由属主身份的那一支调)
        IF COALESCE(v ->> 'error', '') LIKE '42501 permission denied for function sale_settlement_compute%' THEN
            RAISE EXCEPTION 'FIXTURE 304 G: with EXECUTE granted back the direct call is still refused on the function — arm F measured something else';
        END IF;
        RAISE EXCEPTION 'f304 grant injection ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'f304 grant injection ok' THEN RAISE; END IF;
    END;
    IF has_function_privilege('authenticated', 'public.sale_settlement_compute(uuid,uuid,uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 304 G: the grant injection did not roll back';
    END IF;
    RAISE NOTICE 'FIXTURE 304 全部通过: 冻结副本按它自己那一侧遮三样价格、品位与质量限值照旧(A/B);基表价格列 42501、别的列照读(C);cdt_price 判得对、无遮蔽缺口(D);合同申请的快照对不持那一侧价格码的人整份受限(E);sale_settlement_compute 直接调 42501、record_sale_settlement 对不持 data.view_prices 的人把六样钱读成受限而库里存真数(F);判据拿掉 u 读得到 70、授权补回直调不再 42501(G)';
END
$f304$;
ROLLBACK;
