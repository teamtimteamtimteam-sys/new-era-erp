-- LOCAL harness only (never live): a finance clone added beside docs/surveys/MES-7a-2/local-seed.sql (which seeds admin · cco · warehouse · cfo
--   clones and the spare-part data), for the MES-7a-2 close-out item 1.3 b. Codes = live finance's 42 codes, read 2026-10-16 13:4x CST read-only
--   from live role_permissions (the other four roles' codes read at the same moment are identical to the ones in that seed).
\set ON_ERROR_STOP 1
DO $c$ DECLARE r uuid; BEGIN
  INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES ('a0000000-0000-4000-8000-000000000003', 'clone-finance@test.local', now(), now());
  INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('probe-clone-finance', 'Clone finance', 'Clone finance', true) RETURNING id INTO r;
  INSERT INTO role_permissions (role_id, permission_code) SELECT r, x FROM unnest(ARRAY['action.decide_hr_requests','action.metal_prices','action.overtime_enter','action.price_receipts','action.raise_po_office','action.stocktake_post','action.wo_release','data.view_banking','data.view_deleted','data.view_health','data.view_identity','data.view_pay','data.view_prices','data.view_purchase_prices','data.view_sales','module.customers.edit','module.customers.view','module.finance.edit','module.finance.view','module.hr.edit','module.hr.view','module.inbound.edit','module.inbound.view','module.inventory.edit','module.inventory.view','module.logistics.view','module.materials.edit','module.materials.view','module.output.edit','module.output.view','module.pricing.view','module.processing.view','module.purchasing.edit','module.purchasing.view','module.quality.view','module.sales.view','module.stocktakes.edit','module.stocktakes.view','module.suppliers.edit','module.suppliers.view','module.tasks.edit','module.tasks.view']) x;
  INSERT INTO user_roles (user_id, role_id) VALUES ('a0000000-0000-4000-8000-000000000003', r);
END $c$;
