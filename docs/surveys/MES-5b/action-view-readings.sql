-- MES-5b Step 0 · read-only: every action code held by a live role, against the view codes of the pages that use it
-- (mapping from a static read of app/ — page.tsx gates resolved through lib/modules.ts; see STEP0-HANDBACK.md §1 f).
-- "any_of" = the role can enter at least one page where the code is used. Codes whose page is gated by the code itself
-- (bulk_import, manage_permissions, ship_goods, metal_prices, overtime_*) pass by construction and are listed as 'self'.
-- postgres (rolbypassrls = true), base tables only; BEGIN READ ONLY … ROLLBACK.
BEGIN READ ONLY;
WITH map(action_code, view_codes) AS (VALUES
    ('action.apply_assay',              ARRAY['module.inbound.view','module.output.view']),
    ('action.batch_write_off',          ARRAY['module.inbound.view','module.inventory.view','module.output.view']),
    ('action.bulk_import',              ARRAY['self']),
    ('action.confirm_capture',          ARRAY['module.processing.view','module.inbound.view','module.logistics.view']),
    ('action.contract_terms',           ARRAY['module.suppliers.view']),
    ('action.customer_credit',          ARRAY['module.customers.view']),
    ('action.decide_hr_requests',       ARRAY['module.hr.view']),
    ('action.direct_sale',              ARRAY['module.output.view']),
    ('action.finance_reopen',           ARRAY['module.finance.view']),
    ('action.finance_settings',         ARRAY['module.finance.view']),
    ('action.hr_reviews',               ARRAY['module.hr.view']),
    ('action.approve_review',           ARRAY['module.hr.view']),
    ('action.issue_cod',                ARRAY['module.inbound.view','module.inventory.view']),
    ('action.manage_devices',           ARRAY['module.processing.view']),
    ('action.manage_permissions',       ARRAY['self']),
    ('action.metal_prices',             ARRAY['self']),
    ('action.overtime_enter',           ARRAY['self']),
    ('action.overtime_approve',         ARRAY['self']),
    ('action.price_receipts',           ARRAY['module.inbound.view']),
    ('action.processing_aftercare',     ARRAY['module.processing.view']),
    ('action.processing_commit',        ARRAY['module.inbound.view','module.processing.view','module.output.view']),
    ('action.processing_rollback',      ARRAY['module.inventory.view','module.processing.view']),
    ('action.receive_goods',            ARRAY['module.inbound.view','module.processing.view','module.purchasing.view','module.logistics.view']),
    ('action.request_shipping_release', ARRAY['module.sales.view']),
    ('action.ship_goods',               ARRAY['self']),
    ('action.stocktake_count',          ARRAY['module.inbound.view','module.output.view','module.stocktakes.view']),
    ('action.stocktake_post',           ARRAY['module.stocktakes.view']),
    ('action.supplier_approve',         ARRAY['module.suppliers.view']),
    ('action.wo_create',                ARRAY['module.processing.view']),
    ('action.wo_release',               ARRAY['module.processing.view']),
    ('action.raise_po_consumables',     ARRAY['module.purchasing.view']),
    ('action.raise_po_equipment',       ARRAY['module.purchasing.view']),
    ('action.raise_po_office',          ARRAY['module.purchasing.view'])),
live_roles AS (
    SELECT r.id, r.code FROM roles r
     WHERE r.is_active AND r.deleted_at IS NULL
       AND EXISTS (SELECT 1 FROM user_roles ur WHERE ur.role_id = r.id AND ur.revoked_at IS NULL)),
held AS (
    SELECT lr.code AS role, m.action_code, m.view_codes,
           (m.view_codes = ARRAY['self'] OR EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.role_id = lr.id AND rp.permission_code = ANY (m.view_codes))) AS any_of
      FROM live_roles lr JOIN role_permissions rp0 ON rp0.role_id = lr.id JOIN map m ON m.action_code = rp0.permission_code)
SELECT (SELECT count(*) FROM held) AS pairs,
       (SELECT count(*) FROM held WHERE any_of) AS pairs_ok,
       (SELECT COALESCE(jsonb_agg(jsonb_build_object('role', role, 'code', action_code, 'needs_any_of', view_codes)), '[]') FROM held WHERE NOT any_of) AS violations,
       (SELECT count(*) FROM permissions WHERE category = 'action') AS action_codes_in_catalogue,
       (SELECT count(*) FROM map) AS action_codes_mapped,
       (SELECT jsonb_agg(code) FROM permissions WHERE category = 'action' AND code NOT IN (SELECT action_code FROM map)) AS unmapped;
ROLLBACK;
