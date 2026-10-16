-- MES-7b-1 · LOCAL harness only (never live): data of my own on a fresh rebuild of this cut's mirrors, for the layout survey (desktop + 390px)
-- and the F14 check (a database with receipts and stock movements but NO processing run). Clones carry the seven real roles' codes as read
-- from live role_permissions after the migration (read-only, 2026-10-16). Run as postgres on the rebuild:  psql "<local dsn>" -f local-seed.sql
\set ON_ERROR_STOP 1
DO $r$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN CREATE ROLE authenticator LOGIN NOINHERIT; END IF; END $r$;
GRANT anon, authenticated, service_role TO authenticator;
CREATE FUNCTION pg_temp.as_(p uuid) RETURNS void LANGUAGE sql AS $f$ SELECT set_config('request.jwt.claims', CASE WHEN p IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p) END, false) $f$;

DO $c$ DECLARE r uuid; BEGIN
  INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES ('a0000000-0000-4000-8000-000000000001', 'clone-admin@test.local', now(), now());
  INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('probe-clone-admin', 'Clone admin', 'Clone admin', true) RETURNING id INTO r;
  INSERT INTO role_permissions (role_id, permission_code) SELECT r, x FROM unnest(ARRAY['action.anonymise_employee','action.apply_assay','action.approve_review','action.batch_write_off','action.bulk_import','action.confirm_capture','action.contract_terms','action.customer_credit','action.decide_hr_requests','action.direct_sale','action.finance_reopen','action.finance_settings','action.hr_reviews','action.issue_coa','action.issue_cod','action.manage_devices','action.manage_permissions','action.metal_prices','action.ncr_decide','action.overtime_approve','action.overtime_enter','action.price_receipts','action.processing_aftercare','action.processing_commit','action.processing_rollback','action.raise_po_consumables','action.raise_po_equipment','action.raise_po_office','action.receive_goods','action.request_shipping_release','action.ship_goods','action.stocktake_count','action.stocktake_post','action.supplier_approve','action.wo_create','action.wo_release','data.view_banking','data.view_change_log','data.view_deleted','data.view_health','data.view_identity','data.view_pay','data.view_prices','data.view_purchase_prices','data.view_reviews','data.view_sales','data.view_self_approvals','module.customers.edit','module.customers.view','module.finance.edit','module.finance.view','module.hr.edit','module.hr.view','module.inbound.edit','module.inbound.view','module.inventory.edit','module.inventory.view','module.logistics.view','module.materials.edit','module.materials.view','module.output.edit','module.output.view','module.pricing.edit','module.pricing.view','module.processing.edit','module.processing.view','module.purchasing.edit','module.purchasing.view','module.quality.edit','module.quality.view','module.safety.edit','module.safety.view','module.sales.edit','module.sales.view','module.stocktakes.edit','module.stocktakes.view','module.suppliers.edit','module.suppliers.view','module.tasks.edit','module.tasks.view','module.tasks.view_all']) x;
  INSERT INTO user_roles (user_id, role_id) VALUES ('a0000000-0000-4000-8000-000000000001', r);
  INSERT INTO employees (code, legal_name, preferred_name, employment_type, work_category, hire_date, user_id) VALUES ('CLONE-ADMIN', 'Clone admin legal', 'Clone admin', 'full_time', 'shopfloor', CURRENT_DATE - 400, 'a0000000-0000-4000-8000-000000000001');
  INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES ('a0000000-0000-4000-8000-000000000002', 'clone-cco@test.local', now(), now());
  INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('probe-clone-cco', 'Clone cco', 'Clone cco', true) RETURNING id INTO r;
  INSERT INTO role_permissions (role_id, permission_code) SELECT r, x FROM unnest(ARRAY['action.contract_terms','action.decide_hr_requests','action.direct_sale','action.hr_reviews','action.issue_coa','action.ncr_decide','action.raise_po_equipment','action.request_shipping_release','data.view_banking','data.view_deleted','data.view_health','data.view_pay','data.view_prices','data.view_purchase_prices','data.view_reviews','data.view_sales','module.customers.edit','module.customers.view','module.finance.view','module.hr.edit','module.hr.view','module.inbound.edit','module.inbound.view','module.inventory.edit','module.inventory.view','module.logistics.view','module.materials.edit','module.materials.view','module.output.edit','module.output.view','module.pricing.edit','module.pricing.view','module.processing.edit','module.processing.view','module.purchasing.edit','module.purchasing.view','module.quality.edit','module.quality.view','module.safety.view','module.sales.edit','module.sales.view','module.stocktakes.edit','module.stocktakes.view','module.suppliers.edit','module.suppliers.view','module.tasks.edit','module.tasks.view']) x;
  INSERT INTO user_roles (user_id, role_id) VALUES ('a0000000-0000-4000-8000-000000000002', r);
  INSERT INTO employees (code, legal_name, preferred_name, employment_type, work_category, hire_date, user_id) VALUES ('CLONE-CCO', 'Clone cco legal', 'Clone cco', 'full_time', 'shopfloor', CURRENT_DATE - 400, 'a0000000-0000-4000-8000-000000000002');
  INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES ('a0000000-0000-4000-8000-000000000003', 'clone-finance@test.local', now(), now());
  INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('probe-clone-finance', 'Clone finance', 'Clone finance', true) RETURNING id INTO r;
  INSERT INTO role_permissions (role_id, permission_code) SELECT r, x FROM unnest(ARRAY['action.decide_hr_requests','action.metal_prices','action.overtime_enter','action.price_receipts','action.raise_po_office','action.stocktake_post','action.wo_release','data.view_banking','data.view_deleted','data.view_health','data.view_identity','data.view_pay','data.view_prices','data.view_purchase_prices','data.view_sales','module.customers.edit','module.customers.view','module.finance.edit','module.finance.view','module.hr.edit','module.hr.view','module.inbound.edit','module.inbound.view','module.inventory.edit','module.inventory.view','module.logistics.view','module.materials.edit','module.materials.view','module.output.edit','module.output.view','module.pricing.view','module.processing.view','module.purchasing.edit','module.purchasing.view','module.quality.view','module.safety.view','module.sales.view','module.stocktakes.edit','module.stocktakes.view','module.suppliers.edit','module.suppliers.view','module.tasks.edit','module.tasks.view']) x;
  INSERT INTO user_roles (user_id, role_id) VALUES ('a0000000-0000-4000-8000-000000000003', r);
  INSERT INTO employees (code, legal_name, preferred_name, employment_type, work_category, hire_date, user_id) VALUES ('CLONE-FINANCE', 'Clone finance legal', 'Clone finance', 'full_time', 'shopfloor', CURRENT_DATE - 400, 'a0000000-0000-4000-8000-000000000003');
  INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES ('a0000000-0000-4000-8000-000000000004', 'clone-warehouse@test.local', now(), now());
  INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('probe-clone-warehouse', 'Clone warehouse', 'Clone warehouse', true) RETURNING id INTO r;
  INSERT INTO role_permissions (role_id, permission_code) SELECT r, x FROM unnest(ARRAY['action.batch_write_off','action.confirm_capture','action.issue_cod','action.overtime_approve','action.processing_aftercare','action.processing_commit','action.processing_rollback','action.raise_po_consumables','action.receive_goods','action.ship_goods','action.stocktake_count','action.wo_create','data.view_purchase_prices','module.inbound.edit','module.inbound.view','module.inventory.edit','module.inventory.view','module.logistics.view','module.output.edit','module.output.view','module.processing.view','module.purchasing.view','module.quality.view','module.safety.edit','module.safety.view','module.stocktakes.edit','module.stocktakes.view','module.suppliers.edit','module.suppliers.view','module.tasks.edit','module.tasks.view']) x;
  INSERT INTO user_roles (user_id, role_id) VALUES ('a0000000-0000-4000-8000-000000000004', r);
  INSERT INTO employees (code, legal_name, preferred_name, employment_type, work_category, hire_date, user_id) VALUES ('CLONE-WAREHOUSE', 'Clone warehouse legal', 'Clone warehouse', 'full_time', 'shopfloor', CURRENT_DATE - 400, 'a0000000-0000-4000-8000-000000000004');
  INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES ('a0000000-0000-4000-8000-000000000005', 'clone-cto@test.local', now(), now());
  INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('probe-clone-cto', 'Clone cto', 'Clone cto', true) RETURNING id INTO r;
  INSERT INTO role_permissions (role_id, permission_code) SELECT r, x FROM unnest(ARRAY['action.apply_assay','action.confirm_capture','action.manage_devices','action.ncr_decide','data.view_banking','data.view_deleted','data.view_prices','data.view_purchase_prices','data.view_reviews','data.view_sales','module.customers.edit','module.customers.view','module.finance.view','module.hr.view','module.inbound.edit','module.inbound.view','module.inventory.edit','module.inventory.view','module.logistics.view','module.materials.edit','module.materials.view','module.output.edit','module.output.view','module.pricing.view','module.processing.edit','module.processing.view','module.purchasing.edit','module.purchasing.view','module.quality.edit','module.quality.view','module.safety.edit','module.safety.view','module.sales.view','module.stocktakes.edit','module.stocktakes.view','module.suppliers.edit','module.suppliers.view','module.tasks.edit','module.tasks.view']) x;
  INSERT INTO user_roles (user_id, role_id) VALUES ('a0000000-0000-4000-8000-000000000005', r);
  INSERT INTO employees (code, legal_name, preferred_name, employment_type, work_category, hire_date, user_id) VALUES ('CLONE-CTO', 'Clone cto legal', 'Clone cto', 'full_time', 'shopfloor', CURRENT_DATE - 400, 'a0000000-0000-4000-8000-000000000005');
  INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES ('a0000000-0000-4000-8000-000000000006', 'clone-cfo@test.local', now(), now());
  INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('probe-clone-cfo', 'Clone cfo', 'Clone cfo', true) RETURNING id INTO r;
  INSERT INTO role_permissions (role_id, permission_code) SELECT r, x FROM unnest(ARRAY['action.approve_review','action.customer_credit','action.decide_hr_requests','action.finance_reopen','action.finance_settings','action.supplier_approve','data.view_banking','data.view_change_log','data.view_deleted','data.view_health','data.view_identity','data.view_pay','data.view_prices','data.view_purchase_prices','data.view_reviews','data.view_sales','data.view_self_approvals','module.customers.view','module.finance.view','module.hr.view','module.inbound.view','module.inventory.view','module.logistics.view','module.materials.view','module.output.view','module.pricing.view','module.processing.view','module.purchasing.view','module.quality.view','module.safety.view','module.sales.view','module.stocktakes.view','module.suppliers.view','module.tasks.view']) x;
  INSERT INTO user_roles (user_id, role_id) VALUES ('a0000000-0000-4000-8000-000000000006', r);
  INSERT INTO employees (code, legal_name, preferred_name, employment_type, work_category, hire_date, user_id) VALUES ('CLONE-CFO', 'Clone cfo legal', 'Clone cfo', 'full_time', 'shopfloor', CURRENT_DATE - 400, 'a0000000-0000-4000-8000-000000000006');
  INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES ('a0000000-0000-4000-8000-000000000007', 'clone-gm@test.local', now(), now());
  INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('probe-clone-gm', 'Clone gm', 'Clone gm', true) RETURNING id INTO r;
  INSERT INTO role_permissions (role_id, permission_code) SELECT r, x FROM unnest(ARRAY['data.view_banking','data.view_prices','data.view_purchase_prices','data.view_reviews','data.view_sales','data.view_self_approvals','module.customers.view','module.finance.view','module.hr.view','module.inbound.view','module.inventory.view','module.logistics.view','module.materials.view','module.output.view','module.pricing.view','module.processing.view','module.purchasing.view','module.safety.view','module.sales.view','module.stocktakes.view','module.suppliers.view','module.tasks.view']) x;
  INSERT INTO user_roles (user_id, role_id) VALUES ('a0000000-0000-4000-8000-000000000007', r);
  INSERT INTO employees (code, legal_name, preferred_name, employment_type, work_category, hire_date, user_id) VALUES ('CLONE-GM', 'Clone gm legal', 'Clone gm', 'full_time', 'shopfloor', CURRENT_DATE - 400, 'a0000000-0000-4000-8000-000000000007');
  INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES ('a0000000-0000-4000-8000-000000000008', 'clone-inj@test.local', now(), now());
  INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('probe-clone-inj', 'Clone inj', 'Clone inj', true) RETURNING id INTO r;
  INSERT INTO role_permissions (role_id, permission_code) SELECT r, x FROM unnest(ARRAY['module.tasks.view']) x;
  INSERT INTO user_roles (user_id, role_id) VALUES ('a0000000-0000-4000-8000-000000000008', r);
  INSERT INTO employees (code, legal_name, preferred_name, employment_type, work_category, hire_date, user_id) VALUES ('CLONE-INJ', 'Ah Seng (injured) legal', 'Ah Seng (injured)', 'full_time', 'shopfloor', CURRENT_DATE - 400, 'a0000000-0000-4000-8000-000000000008');
END $c$;

DO $d$
DECLARE
    wh uuid := 'a0000000-0000-4000-8000-000000000004'; cco uuid := 'a0000000-0000-4000-8000-000000000002'; adm uuid := 'a0000000-0000-4000-8000-000000000001';
    v_base text; d date := (now() AT TIME ZONE 'Asia/Singapore')::date - 3; t1 timestamptz := now(); t2 timestamptz := now() - interval '5 hours';
    sup uuid; bm uuid; om uuid; fa uuid; loc uuid; ib1 uuid; ib2 uuid; ib3 uuid; ob1 uuid; dt uuid; e_inj uuid; i_a uuid; i_b uuid; i_c uuid; lk bigint; v_items jsonb; e_out uuid; e_in uuid; v_shift text;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT id INTO e_inj FROM employees WHERE code = 'CLONE-INJ';
    SELECT id INTO e_out FROM employees WHERE code = 'CLONE-WAREHOUSE';
    SELECT id INTO e_in FROM employees WHERE code = 'CLONE-GM';
    SELECT code INTO v_shift FROM shifts WHERE is_active ORDER BY sort_order LIMIT 1;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type) VALUES ('ZZ-LL7B-S', 'Pack Recyclers Pte Ltd', 'SG', 'active', 'goods_supplier') RETURNING id INTO sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ-LL7B-MOD', 'EV battery modules, NMC, end of life', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO bm;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ-LL7B-BM', 'Black mass, NMC', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO om;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_ccy, currency, fx_rate, cost_base, useful_life_months, residual_base)
    VALUES ('ZZ-LL7B-SHRED', 'Primary shredder, line 1', 'equipment', d - 300, 0, v_base, 1, 0, 60, 0) RETURNING id INTO fa;
    INSERT INTO storage_locations (code, name, is_active) VALUES ('ZZ-LL7B-BAY1', 'Discharge bay 1 (north wall)', true) RETURNING id INTO loc;
    PERFORM pg_temp.as_(adm); SET ROLE authenticated;
    ib1 := (create_inbound_batch(bm, sup, 1250, 'kg', d, '待加工', p_location_id => loc, p_safety_states => ARRAY['discharged_verified'],
                                 p_source_reason_code => 'other', p_source_reason_note => 'local seed: modules at the bay') ->> 'batch_id')::uuid;
    ib2 := (create_inbound_batch(bm, sup, 830, 'kg', d, '待加工', p_location_id => loc, p_safety_states => ARRAY['discharged_verified'],
                                 p_source_reason_code => 'other', p_source_reason_note => 'local seed: second lot at the bay') ->> 'batch_id')::uuid;
    ib3 := (create_inbound_batch(bm, sup, 400, 'kg', d, '待加工', p_safety_states => ARRAY['discharged_verified'],
                                 p_source_reason_code => 'other', p_source_reason_note => 'local seed: picked by code') ->> 'batch_id')::uuid;
    ob1 := (create_output_batch(om, 120, 'kg', d) ->> 'batch_id')::uuid;
    RESET ROLE; PERFORM pg_temp.as_(NULL);
    INSERT INTO equipment_downtime (equipment_id, started_at, ended_at, reason, cause_code, source)
    VALUES (fa, t2 - interval '10 minutes', t2 + interval '40 minutes', 'Stopped after smoke from the cutting chamber', 'breakdown', 'manual') RETURNING id INTO dt;

    PERFORM pg_temp.as_(wh); SET ROLE authenticated;
    i_a := (record_incident('injury', t1, 'A swollen module vented while being moved off the pallet; electrolyte splashed onto the operator''s left forearm and the bay filled with a sweet solvent smell for about ten minutes.',
            'Operator moved to the eyewash and safety shower, area cordoned, module placed in the sand bin, ventilation on full.', true,
            p_responsible_name => 'Shift lead, day shift', p_location_id => loc, p_injured_employee_id => e_inj,
            p_injury_nature => 'Chemical burn, left forearm (about 6 cm)', p_injury_treatment => 'First aid, then outpatient at the polyclinic', p_days_lost => 2) ->> 'incident_id')::uuid;
    i_b := (record_incident('fire_smoke', t2, 'Smoke from the shredder cutting chamber during a run of end-of-life modules.', 'E-stop pressed, CO2 extinguisher on standby, chamber left closed for 30 minutes.', true,
            p_responsible_name => 'Maintenance lead', p_equipment_id => fa, p_downtime_id => dt, p_duration_min => 50) ->> 'incident_id')::uuid;
    i_c := (record_incident('near_miss', t1 - interval '2 days', 'A pallet of modules nearly slid off the top rack.', 'Re-stacked on the floor level; rack inspected.', false,
            p_responsible_name => 'Warehouse lead') ->> 'incident_id')::uuid;
    PERFORM link_incident_batch(i_a, 'location', p_inbound_batch_id => ib1);
    PERFORM link_incident_batch(i_a, 'location', p_inbound_batch_id => ib2);
    PERFORM link_incident_batch(i_b, 'picked', p_output_batch_id => ob1);
    PERFORM link_incident_batch(i_b, 'picked', p_inbound_batch_id => ib3);
    SELECT id INTO lk FROM incident_batches WHERE incident_id = i_b AND inbound_batch_id = ib3;
    PERFORM unlink_incident_batch(lk, 'Picked by mistake — that lot was in the other bay');
    PERFORM record_incident_update(i_a, 'nea_notified', t1, 'NEA hotline, reference 2026-10-14-0193');
    PERFORM record_incident_update(i_a, 'correction', p_field => 'immediate_action', p_new_value => 'Operator moved to the eyewash and safety shower within a minute, area cordoned, module placed in the sand bin, ventilation on full, WSH officer called.', p_reason => 'Added the call to the WSH officer');
    PERFORM record_incident_update(i_c, 'closed', p_summary => 'Top rack reserved for empty pallets; staff briefed at the toolbox talk.');
    SELECT jsonb_agg(jsonb_build_object('item_type_code', code, 'body', 'Shredder locked out until maintenance signs off; two modules in the sand bin.') ORDER BY sort_order) INTO v_items FROM handover_item_types WHERE is_active;
    PERFORM submit_shift_handover(v_shift, (now() AT TIME ZONE 'Asia/Singapore')::date, e_out, e_in, 'Smoke incident on the shredder; see the incidents.', v_items, ARRAY[dt], ARRAY[i_a, i_b]);
    RESET ROLE; PERFORM pg_temp.as_(NULL);
    PERFORM pg_temp.as_(cco); SET ROLE authenticated;
    PERFORM open_ncr('incident', 'Black mass from the smoke run: hold until the lab checks for burnt binder', p_output_batch_id => ob1, p_incident_id => i_b);
    RESET ROLE; PERFORM pg_temp.as_(NULL);
    RAISE NOTICE 'SEED|incidents %|links %|updates %|handover refs %|runs %|movements %', (SELECT count(*) FROM incidents), (SELECT count(*) FROM incident_batches),
        (SELECT count(*) FROM incident_updates), (SELECT count(*) FROM shift_handover_incident_refs), (SELECT count(*) FROM processing_runs), (SELECT count(*) FROM inventory_movements);
    RAISE NOTICE 'IDS|A %|B %|C %|ib1 %|ob1 %|fa %|ho %', i_a, i_b, i_c, ib1, ob1, fa, (SELECT handover_id FROM shift_handover_incident_refs LIMIT 1);
END $d$;
