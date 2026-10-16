-- LOCAL harness only (never live): MES-7a-2 layout on states live has none of — spare-part batches (priced, unpriced, on hold), issues and a return
--   on a maintenance record, a reprice that sent the issued share to 6800, V21 listed. Data of my own on a rebuild of the mirrors (this cut's tree).
--   Clones carry the four roles' live codes (read 2026-10-16 12:1x CST from live role_permissions, read-only).
\set ON_ERROR_STOP 1
DO $r$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN CREATE ROLE authenticator LOGIN NOINHERIT; END IF; END $r$;
GRANT anon, authenticated, service_role TO authenticator;
DO $c$ DECLARE r uuid; BEGIN
  INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES ('a0000000-0000-4000-8000-000000000001', 'clone-admin@test.local', now(), now());
  INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('probe-clone-admin', 'Clone admin', 'Clone admin', true) RETURNING id INTO r;
  INSERT INTO role_permissions (role_id, permission_code) SELECT r, x FROM unnest(ARRAY['action.anonymise_employee','action.apply_assay','action.approve_review','action.batch_write_off','action.bulk_import','action.confirm_capture','action.contract_terms','action.customer_credit','action.decide_hr_requests','action.direct_sale','action.finance_reopen','action.finance_settings','action.hr_reviews','action.issue_coa','action.issue_cod','action.manage_devices','action.manage_permissions','action.metal_prices','action.ncr_decide','action.overtime_approve','action.overtime_enter','action.price_receipts','action.processing_aftercare','action.processing_commit','action.processing_rollback','action.raise_po_consumables','action.raise_po_equipment','action.raise_po_office','action.receive_goods','action.request_shipping_release','action.ship_goods','action.stocktake_count','action.stocktake_post','action.supplier_approve','action.wo_create','action.wo_release','data.view_banking','data.view_change_log','data.view_deleted','data.view_health','data.view_identity','data.view_pay','data.view_prices','data.view_purchase_prices','data.view_reviews','data.view_sales','data.view_self_approvals','module.customers.edit','module.customers.view','module.finance.edit','module.finance.view','module.hr.edit','module.hr.view','module.inbound.edit','module.inbound.view','module.inventory.edit','module.inventory.view','module.logistics.view','module.materials.edit','module.materials.view','module.output.edit','module.output.view','module.pricing.edit','module.pricing.view','module.processing.edit','module.processing.view','module.purchasing.edit','module.purchasing.view','module.quality.edit','module.quality.view','module.sales.edit','module.sales.view','module.stocktakes.edit','module.stocktakes.view','module.suppliers.edit','module.suppliers.view','module.tasks.edit','module.tasks.view','module.tasks.view_all']) x;
  INSERT INTO user_roles (user_id, role_id) VALUES ('a0000000-0000-4000-8000-000000000001', r);
  INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES ('a0000000-0000-4000-8000-000000000002', 'clone-cco@test.local', now(), now());
  INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('probe-clone-cco', 'Clone cco', 'Clone cco', true) RETURNING id INTO r;
  INSERT INTO role_permissions (role_id, permission_code) SELECT r, x FROM unnest(ARRAY['action.contract_terms','action.decide_hr_requests','action.direct_sale','action.hr_reviews','action.issue_coa','action.ncr_decide','action.raise_po_equipment','action.request_shipping_release','data.view_banking','data.view_deleted','data.view_health','data.view_pay','data.view_prices','data.view_purchase_prices','data.view_reviews','data.view_sales','module.customers.edit','module.customers.view','module.finance.view','module.hr.edit','module.hr.view','module.inbound.edit','module.inbound.view','module.inventory.edit','module.inventory.view','module.logistics.view','module.materials.edit','module.materials.view','module.output.edit','module.output.view','module.pricing.edit','module.pricing.view','module.processing.edit','module.processing.view','module.purchasing.edit','module.purchasing.view','module.quality.edit','module.quality.view','module.sales.edit','module.sales.view','module.stocktakes.edit','module.stocktakes.view','module.suppliers.edit','module.suppliers.view','module.tasks.edit','module.tasks.view']) x;
  INSERT INTO user_roles (user_id, role_id) VALUES ('a0000000-0000-4000-8000-000000000002', r);
  INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES ('a0000000-0000-4000-8000-000000000004', 'clone-warehouse@test.local', now(), now());
  INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('probe-clone-warehouse', 'Clone warehouse', 'Clone warehouse', true) RETURNING id INTO r;
  INSERT INTO role_permissions (role_id, permission_code) SELECT r, x FROM unnest(ARRAY['action.batch_write_off','action.confirm_capture','action.issue_cod','action.overtime_approve','action.processing_aftercare','action.processing_commit','action.processing_rollback','action.raise_po_consumables','action.receive_goods','action.ship_goods','action.stocktake_count','action.wo_create','data.view_purchase_prices','module.inbound.edit','module.inbound.view','module.inventory.edit','module.inventory.view','module.logistics.view','module.output.edit','module.output.view','module.processing.view','module.purchasing.view','module.quality.view','module.stocktakes.edit','module.stocktakes.view','module.suppliers.edit','module.suppliers.view','module.tasks.edit','module.tasks.view']) x;
  INSERT INTO user_roles (user_id, role_id) VALUES ('a0000000-0000-4000-8000-000000000004', r);
  INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES ('a0000000-0000-4000-8000-000000000006', 'clone-cfo@test.local', now(), now());
  INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('probe-clone-cfo', 'Clone cfo', 'Clone cfo', true) RETURNING id INTO r;
  INSERT INTO role_permissions (role_id, permission_code) SELECT r, x FROM unnest(ARRAY['action.approve_review','action.customer_credit','action.decide_hr_requests','action.finance_reopen','action.finance_settings','action.supplier_approve','data.view_banking','data.view_change_log','data.view_deleted','data.view_health','data.view_identity','data.view_pay','data.view_prices','data.view_purchase_prices','data.view_reviews','data.view_sales','data.view_self_approvals','module.customers.view','module.finance.view','module.hr.view','module.inbound.view','module.inventory.view','module.logistics.view','module.materials.view','module.output.view','module.pricing.view','module.processing.view','module.purchasing.view','module.quality.view','module.sales.view','module.stocktakes.view','module.suppliers.view','module.tasks.view']) x;
  INSERT INTO user_roles (user_id, role_id) VALUES ('a0000000-0000-4000-8000-000000000006', r);
END $c$;
-- a second decider for the NCR (a quality decider who is not the opener)
DO $q$ DECLARE r uuid; BEGIN
  INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES ('a0000000-0000-4000-8000-000000000099', 'clone-qd@test.local', now(), now());
  INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('probe-clone-qd', 'Clone qd', 'Clone qd', true) RETURNING id INTO r;
  INSERT INTO role_permissions (role_id, permission_code) VALUES (r, 'action.ncr_decide'), (r, 'module.quality.view');
  INSERT INTO user_roles (user_id, role_id) VALUES ('a0000000-0000-4000-8000-000000000099', r);
END $q$;
UPDATE finance_settings SET locked_before = NULL;
DO $d$
DECLARE adm uuid := 'a0000000-0000-4000-8000-000000000001'; v_base text; d date := (now() AT TIME ZONE 'Asia/Singapore')::date - 3;
  sup uuid; sp uuid; sp2 uuid; fa uuid; m1 uuid; m2 uuid; ibp uuid; ibu uuid; ibh uuid; iss uuid;
BEGIN
  SELECT code INTO v_base FROM currencies WHERE is_base;
  PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', adm), false);
  INSERT INTO suppliers (code, legal_name, country, status, counterparty_type) VALUES ('ZZ-LL-S', 'Harness spares vendor Pte Ltd', 'SG', 'active', 'goods_supplier') RETURNING id INTO sup;
  INSERT INTO materials (code, name, kind_code, may_be_processed, unit) VALUES ('ZZ-LL-BLADE', 'Shredder blade, hardened, 400 mm', 'spare_part', false, 'pcs') RETURNING id INTO sp;
  INSERT INTO materials (code, name, kind_code, may_be_processed, unit) VALUES ('ZZ-LL-BEARING', 'Main shaft bearing 6312-2RS', 'spare_part', false, 'pcs') RETURNING id INTO sp2;
  INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_ccy, currency, fx_rate, cost_base, useful_life_months, residual_base)
  VALUES ('FA-2026-0091', 'Harness two-shaft shredder', 'equipment', d - 90, 0, v_base, 1, 0, 60, 0) RETURNING id INTO fa;
  ibp := (create_inbound_batch(sp, sup, 12, 'pcs', d, '待加工', p_source_reason_code => 'other', p_source_reason_note => 'harness') ->> 'batch_id')::uuid;
  ibu := (create_inbound_batch(sp2, sup, 6, 'pcs', d, '待加工', p_source_reason_code => 'other', p_source_reason_note => 'harness unpriced') ->> 'batch_id')::uuid;
  ibh := (create_inbound_batch(sp, sup, 4, 'pcs', d, '待加工', p_source_reason_code => 'other', p_source_reason_note => 'harness held') ->> 'batch_id')::uuid;
  PERFORM reprice_inbound_batch(ibp, 85.5, v_base, NULL, 'harness price');
  PERFORM reprice_inbound_batch(ibh, 85.5, v_base, NULL, 'harness price');
  m1 := (record_equipment_maintenance(p_equipment_id => fa, p_performed_on => d + 1, p_kind => 'repair', p_description => 'Replaced two worn shredder blades on the lower shaft',
         p_performed_by_name => 'Ali (fitter)') ->> 'maintenance_id')::uuid;
  m2 := (record_equipment_maintenance(p_equipment_id => fa, p_performed_on => d + 2, p_kind => 'repair', p_description => 'Gearbox overhaul',
         p_performed_by_name => 'Vendor engineer', p_capitalised => true, p_capitalisation_reason => 'Extends the life of the gearbox by three years') ->> 'maintenance_id')::uuid;
  iss := ((issue_spare_parts(m1, d + 1, jsonb_build_array(jsonb_build_object('inbound_batch_id', ibp, 'quantity', 3))) -> 'lines' -> 0) ->> 'issue_id')::uuid;
  PERFORM return_spare_parts(iss, 1, d + 2, 'One blade was not needed — the third one was still sharp');
  PERFORM issue_spare_parts(m1, d + 2, jsonb_build_array(jsonb_build_object('inbound_batch_id', ibh, 'quantity', 1)));
  PERFORM reprice_inbound_batch(ibp, 92, v_base, NULL, 'harness reprice after the issue');
  PERFORM open_ncr('manual', 'Chipped edges on two blades in this lot', p_inbound_batch_id => ibh);
  RAISE NOTICE 'SEED|fa=%|ibp=%|ibh=%|ibu=%|m1=%', fa, ibp, ibh, ibu, m1;
END $d$;

