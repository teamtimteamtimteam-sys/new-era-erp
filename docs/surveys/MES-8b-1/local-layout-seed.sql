-- docs/surveys/MES-8b-1/local-layout-seed.sql — LOCAL harness only (never live): the margin / exposure / compliance-pack scenery the MES-8b-1 layout survey
-- ran on (co8a, a local rebuild of the mirrors). Helpers are fixture 271's own (copied verbatim), then one seed block; committed, not rolled back.
BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f271_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

CREATE FUNCTION pg_temp.f271_do(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM pg_temp.f271_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f271_as(NULL);
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f271_as(NULL);
    RETURN SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f271_get(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.f271_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f271_as(NULL);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f271_as(NULL);
    RAISE;
END;
$f$;

CREATE FUNCTION pg_temp.f271_user(p_label text, p_codes text[]) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE u uuid := gen_random_uuid(); r uuid;
BEGIN
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES (u, 'fx271-' || p_label || '@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx271-' || p_label, 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r, c FROM unnest(p_codes) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);
    RETURN u;
END;
$f$;

CREATE FUNCTION pg_temp.f271_expect(p_arm text, p_got text, p_like text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    IF (p_got IS NULL OR p_got NOT LIKE p_like) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 271 % expected % got %', p_arm, p_like, COALESCE(p_got, '<null>');
    END IF;
END;
$f$;

-- 一批进料(直写):带安全状态;p_price 不为空就按它定价(落地单价 = p_price)
CREATE FUNCTION pg_temp.f271_ib(p_code text, p_mat uuid, p_sup uuid, p_qty numeric, p_price numeric, p_unit text DEFAULT 'kg') RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v uuid; v_ccy text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES (p_code, p_mat, p_sup, p_qty, p_qty, p_unit, CURRENT_DATE - 30, 'other', 'fixture 271 自带数据') RETURNING id INTO v;
    IF (SELECT k.has_condition_axes FROM materials mm JOIN material_kinds k ON k.code = mm.kind_code WHERE mm.id = p_mat) THEN
        INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) VALUES (v, 'discharged_verified');
    END IF;
    IF p_price IS NOT NULL THEN
        PERFORM reprice_inbound_batch(v, p_price, v_ccy, NULL, 'f271');
    END IF;
    RETURN v;
END;
$f$;

-- 一炉(直写):表头、投料腿与它们的消耗流水
CREATE FUNCTION pg_temp.f271_run(p_code text, p_d date, p_in numeric, p_out numeric) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v uuid;
BEGIN
    INSERT INTO processing_runs (code, status, allocation_basis, operation_type_code, process_date, total_input, total_output, started_at, ended_at, shift_code)
    VALUES (p_code, 'committed', 'weight', 'manual_disassembly', p_d, p_in, p_out, p_d::timestamptz + interval '9 hours',
            p_d::timestamptz + interval '11 hours', 'day') RETURNING id INTO v;
    RETURN v;
END;
$f$;
CREATE FUNCTION pg_temp.f271_leg(p_run uuid, p_kind text, p_b uuid, p_q numeric, p_d date) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    IF p_kind = 'inbound' THEN
        INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed) VALUES (p_run, p_b, p_q);
        INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, run_id, business_date) VALUES (p_b, 'processing_consume', -p_q, p_run, p_d);
    ELSE
        INSERT INTO processing_inputs (run_id, output_batch_id, quantity_consumed) VALUES (p_run, p_b, p_q);
        INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, run_id, business_date) VALUES (p_b, 'processing_consume', -p_q, p_run, p_d);
    END IF;
END;
$f$;
-- 一条产出(直写):产出批(它的产出流水由触发器写)与它的单位成本
CREATE FUNCTION pg_temp.f271_out(p_run uuid, p_code text, p_mat uuid, p_q numeric, p_unit_cost numeric, p_incomplete boolean, p_d date) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v uuid;
BEGIN
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date) VALUES (p_code, p_mat, p_q, p_q, p_d) RETURNING id INTO v;
    INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code) VALUES (v, 'discharged_verified');
    INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced, allocated_cost_base, unit_cost_base, cost_incomplete)
    VALUES (p_run, v, p_q, round(p_q * p_unit_cost, 2), p_unit_cost, p_incomplete);
    RETURN v;
END;
$f$;
-- 一笔销售(直写):sales_records 一行与它的销售流水
CREATE FUNCTION pg_temp.f271_sell(p_ob uuid, p_cust uuid, p_q numeric, p_amount numeric, p_d date) RETURNS void
LANGUAGE plpgsql AS $f$
DECLARE v_ccy text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price, currency, fx_rate, amount_base, sale_date)
    VALUES (p_ob, p_cust, p_q, round(p_amount / p_q, 6), v_ccy, 1, p_amount, p_d);
    INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date) VALUES (p_ob, 'sale', -p_q, p_d);
END;
$f$;


DO $$
DECLARE
    u_all uuid; D date := DATE '2026-10-05'; v_mat uuid; s uuid; cust uuid; ia uuid; ib uuid; ic uuid; r1 uuid; r2 uuid; r3 uuid;
    o1 uuid; o2 uuid; o3 uuid; o4 uuid; M date := DATE '2026-09-01'; v_j jsonb; tpl uuid; rn uuid; e1 uuid; lic uuid; v_cat text := 'LOC8B1-CAT';
BEGIN
    UPDATE finance_settings SET system_start_date = DATE '2026-08-01', locked_before = DATE '2026-08-01';
    u_all := pg_temp.f271_user('seed', ARRAY(SELECT code FROM permissions));
    PERFORM pg_temp.f271_as(u_all);
    INSERT INTO nea_waste_categories (code, name_en, name_zh, is_active, sort_order) VALUES (v_cat, 'Spent lithium-ion batteries and black mass', 'f', true, 1) ON CONFLICT DO NOTHING;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, nea_waste_category_code)
    VALUES ('LOC8B1-BM', 'Black mass NMC (local harness)', 'battery_material', true, 'black_mass', 'end_of_life', v_cat) RETURNING id INTO v_mat;
    INSERT INTO suppliers (code, legal_name, country, counterparty_type) VALUES ('LOC8B1-S', 'Harness Battery Collection Pte. Ltd.', 'SG', 'goods_supplier') RETURNING id INTO s;
    INSERT INTO customers (code, legal_name, country) VALUES ('LOC8B1-C', 'Harness Refinery Customer Co., Ltd.', 'SG') RETURNING id INTO cust;
    ia := pg_temp.f271_ib('LOC8B1-IN-A', v_mat, s, 1000, 1);
    ib := pg_temp.f271_ib('LOC8B1-IN-B', v_mat, s, 500, 1);
    ic := pg_temp.f271_ib('LOC8B1-IN-C', v_mat, s, 100, NULL);
    r1 := pg_temp.f271_run('LOC8B1-R1', D, 800, 800);
    PERFORM pg_temp.f271_leg(r1, 'inbound', ia, 600, D);
    PERFORM pg_temp.f271_leg(r1, 'inbound', ib, 200, D);
    o1 := pg_temp.f271_out(r1, 'LOC8B1-OUT-0001', v_mat, 500, 1.2, false, D);
    o2 := pg_temp.f271_out(r1, 'LOC8B1-OUT-0002', v_mat, 300, 1.0, false, D);
    r2 := pg_temp.f271_run('LOC8B1-R2', D + 2, 400, 380);
    PERFORM pg_temp.f271_leg(r2, 'output', o1, 400, D + 2);
    o3 := pg_temp.f271_out(r2, 'LOC8B1-OUT-0003', v_mat, 380, 1.5, false, D + 2);
    PERFORM pg_temp.f271_sell(o2, cust, 100, 250, D + 5);
    PERFORM pg_temp.f271_sell(o3, cust, 200, 600, D + 6);
    r3 := pg_temp.f271_run('LOC8B1-R3', D, 100, 90);
    PERFORM pg_temp.f271_leg(r3, 'inbound', ic, 100, D);
    o4 := pg_temp.f271_out(r3, 'LOC8B1-OUT-0004', v_mat, 90, 2, true, D);
    PERFORM pg_temp.f271_sell(o4, cust, 10, 50, D + 5);
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source) VALUES (ia, 'ni', 10, 'manual'), (ia, 'co', 5, 'manual');
    INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source) VALUES (o3, 'ni', 20, 'manual');
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source) VALUES ('ni', 15000, DATE '2026-10-14', 'broker_quote'), ('mn', 2000, DATE '2026-10-12', 'broker_quote');
    -- 九月:执照、上限、一件工伤、两条监测、一次巡检 —— 然后锁九月、冻两份
    INSERT INTO company_compliance (cert_type_code, cert_no, issuing_body, valid_from, valid_until, status, approved_storage_limit_tonnes)
    VALUES ('gwdf', 'LOC8B1-WDL-21-2-5380', 'NEA', DATE '2026-07-01', DATE '2028-09-01', 'active', 500) RETURNING id INTO lic;
    INSERT INTO licence_storage_limits (licence_id, category_code, limit_tonnes) VALUES (lic, v_cat, 1.5);
    e1 := gen_random_uuid();
    INSERT INTO employees (id, code, legal_name, preferred_name, employment_type, work_category, hire_date)
    VALUES (e1, 'LOC8B1-E1', 'Harness Inspector', 'Harness Inspector', 'full_time', 'office', DATE '2020-01-01');
    v_j := record_incident('injury', (M + 10)::timestamptz + interval '10 hours', 'a cell vented', 'first aid', true,
                           p_responsible_name => 'Lead', p_injured_person_name => 'Visitor', p_injury_nature => 'burn', p_injury_treatment => 'clinic', p_days_lost => 3);
    PERFORM record_incident_update((v_j ->> 'incident_id')::uuid, 'nea_notified', (M + 10)::timestamptz + interval '12 hours', 'NEA-REF');
    PERFORM record_incident('near_miss', (M + 18)::timestamptz + interval '10 hours', 'forklift near miss', 'briefing', false, p_responsible_name => 'Lead');
    INSERT INTO laboratories (code, name_en, name_zh) VALUES ('LOC8B1LAB', 'Harness laboratory', 'f') ON CONFLICT DO NOTHING;
    INSERT INTO environmental_parameters (code, name_en, name_zh, unit, limit_value, limit_basis, is_active) VALUES ('loc8b1_pm', 'Stack particulates (PM10)', 'f', 'mg/m3', 10, 'max', true) ON CONFLICT DO NOTHING;
    PERFORM record_environmental_result('loc8b1_pm', 'Stack 1 (shredder line)', M + 5, 'LOC8B1LAB', 'R-1', 5);
    PERFORM record_environmental_result('loc8b1_pm', 'Stack 1 (shredder line)', M + 6, 'LOC8B1LAB', 'R-2', 12, true, 'fan reset');
    tpl := (save_inspection_template(NULL, 'LOC8B1-T', 'Weekly fire and spill checklist', 'Warehouse', '["Extinguishers in date", "Spill kit stocked", "Exit signage lit"]'::jsonb) ->> 'template_id')::uuid;
    rn := (record_inspection_run(tpl, (M + 3)::timestamptz + interval '10 hours', e1,
           '[{"position": 1, "result": "pass"}, {"position": 2, "result": "fail", "note": "kit opened"}, {"position": 3, "result": "na"}]'::jsonb) ->> 'run_id')::uuid;
    PERFORM record_inspection_finding(rn, 2, 'Restock the spill kit and add a tamper seal', e1, DATE '2026-10-10');
    UPDATE finance_settings SET locked_before = DATE '2026-10-01';
    PERFORM pg_temp.f271_as('a0000000-0000-4000-8000-000000000001');
    PERFORM freeze_compliance_pack(M, 'First freeze for the harness');
    PERFORM freeze_compliance_pack(M, NULL, 'A near miss was recorded after the first freeze');
    PERFORM pg_temp.f271_as(NULL);
    INSERT INTO compliance_pack_issues (pack_id, version, file_path, sha256)
    SELECT id, 1, id::text || '/' || repeat('a', 64) || '.pdf', repeat('a', 64) FROM compliance_packs WHERE code = 'CPK-2026-09-2';
    RAISE NOTICE 'SEED|A %|C %|pack %', ia, ic, (SELECT id FROM compliance_packs WHERE code = 'CPK-2026-09-2');
END
$$;
UPDATE inbound_batches b SET remaining_qty = x.q FROM (SELECT inbound_batch_id, sum(qty_delta) q FROM inventory_movements WHERE inbound_batch_id IS NOT NULL GROUP BY 1) x
 WHERE x.inbound_batch_id = b.id AND b.code LIKE 'LOC8B1-%';
UPDATE output_batches b SET remaining_qty = x.q FROM (SELECT output_batch_id, sum(qty_delta) q FROM inventory_movements WHERE output_batch_id IS NOT NULL GROUP BY 1) x
 WHERE x.output_batch_id = b.id AND b.code LIKE 'LOC8B1-%';
COMMIT;
