-- MES-3a Step 0 live readings (2026-10-06). Read-only: the session runs with default_transaction_read_only = on,
-- and the block is BEGIN READ ONLY … ROLLBACK. Run as postgres (rolbypassrls = true) over psql to the pooler; base tables.
BEGIN READ ONLY;
\pset pager off
\pset format unaligned
SELECT 'identity', current_user, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user),
       current_setting('transaction_read_only'), (now() AT TIME ZONE 'Asia/Singapore')::text;
-- (h) the receipt-pricing codes, by role
SELECT 'code_holders', rp.permission_code, string_agg(r.code, ' · ' ORDER BY r.code)
  FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
 WHERE rp.permission_code IN ('action.price_receipts', 'data.view_purchase_prices', 'module.inbound.view',
                              'module.inbound.edit', 'data.view_prices', 'action.receive_goods', 'action.apply_assay')
 GROUP BY rp.permission_code ORDER BY rp.permission_code;
-- (h) by account (active grants only)
SELECT 'accounts', u.email,
       coalesce(string_agg(r.code, ',' ORDER BY r.code) FILTER (WHERE ur.revoked_at IS NULL), '-') AS active_roles,
       coalesce(string_agg(r.code, ',' ORDER BY r.code) FILTER (WHERE ur.revoked_at IS NOT NULL), '-') AS revoked_roles,
       (u.banned_until IS NOT NULL AND u.banned_until > now()) AS disabled
  FROM auth.users u LEFT JOIN user_roles ur ON ur.user_id = u.id LEFT JOIN roles r ON r.id = ur.role_id
 GROUP BY u.email, u.banned_until ORDER BY u.email;
SELECT 'account_codes', u.email,
       bool_or(rp.permission_code = 'action.price_receipts')     AS price_receipts,
       bool_or(rp.permission_code = 'data.view_purchase_prices') AS view_purchase_prices,
       bool_or(rp.permission_code = 'module.inbound.view')       AS inbound_view
  FROM auth.users u JOIN user_roles ur ON ur.user_id = u.id AND ur.revoked_at IS NULL
  JOIN role_permissions rp ON rp.role_id = ur.role_id
 GROUP BY u.email ORDER BY u.email;
SELECT 'finance_settings', row_to_json(f)::text FROM finance_settings f;
-- (f) MES-2 rows on live and the switch
SELECT 'mes2_rows', (SELECT count(*) FROM weighings) AS weighings, (SELECT count(*) FROM weighbridge_tickets) AS tickets,
       (SELECT count(*) FROM weighbridge_ticket_shares) AS shares, (SELECT count(*) FROM capture_drafts) AS drafts,
       (SELECT count(*) FROM instrument_calibrations) AS calibrations,
       (SELECT coalesce(require_calibrated_since::text, 'NULL') FROM ingest_settings WHERE id) AS switch;
-- (b)(c)(d) licences, waste classes, locations, safety states, batches
SELECT 'company_compliance', row_to_json(c)::text FROM company_compliance c WHERE deleted_at IS NULL;
SELECT 'certificate_types', row_to_json(c)::text FROM certificate_types c;
SELECT 'waste_classifications', row_to_json(w)::text FROM waste_classifications w;
SELECT 'storage_locations', row_to_json(s)::text FROM storage_locations s;
SELECT 'inbound_safety_states', row_to_json(s)::text FROM inbound_safety_states s;
SELECT 'inbound_batch_safety_states', safety_state_code, count(*) FROM inbound_batch_safety_states GROUP BY 2 ORDER BY 2;
SELECT 'output_batch_safety_states', safety_state_code, count(*) FROM output_batch_safety_states GROUP BY 2 ORDER BY 2;
SELECT 'inbound_batches', count(*), count(*) FILTER (WHERE deleted_at IS NULL) FROM inbound_batches;
SELECT 'output_batches', count(*), count(*) FILTER (WHERE deleted_at IS NULL) FROM output_batches;
SELECT 'operations_now_types', count(DISTINCT item_type) FROM operations_now;
ROLLBACK;

-- (h) second reading: for each account as the RAISER of a receipt price request, who can decide it at level 2
-- (approval_deciders is STABLE; the same call receipt_price_submit_internal makes, with the live level roles).
BEGIN READ ONLY;
\pset pager off
\pset format unaligned
SELECT 'deciders_for_raiser', r.email AS raiser,
       coalesce((SELECT string_agg(u2.email || CASE WHEN d.via_self_exception THEN '(self-exception)' ELSE '' END, ', ' ORDER BY u2.email)
                   FROM approval_deciders('receipt_price_request', 'decide_receipt_price_request', 2::smallint, r.id, NULL,
                                          f.approval_level1_role_code, f.approval_level2_role_code) d
                   JOIN auth.users u2 ON u2.id = d.user_id), '— none: RECEIPT_PRICE_NO_OTHER_DECIDER') AS deciders
  FROM auth.users r CROSS JOIN finance_settings f
 WHERE r.email IN ('admin@swm-os.test', 'chooer@evoltrya.test', 'phua@evolytra.test')
 ORDER BY r.email;
SELECT 'receipt_price_requests', status, count(*) FROM receipt_price_requests GROUP BY status ORDER BY status;
ROLLBACK;

-- (b) third reading: what is physically on site today (Σ qty_delta per batch = remaining, all statuses),
-- by batch kind × unit × the material's waste classification; and where it sits.
BEGIN READ ONLY;
\pset pager off
\pset format unaligned
SELECT 'on_site', k.kind, k.unit, coalesce(m.waste_classification_code, '(unclassified)') AS class,
       count(*) AS batches, sum(k.qty) AS qty
  FROM (SELECT 'inbound' AS kind, ib.unit, ib.material_id, sum(mv.qty_delta) AS qty
          FROM inventory_movements mv JOIN inbound_batches ib ON ib.id = mv.inbound_batch_id
         GROUP BY ib.id, ib.unit, ib.material_id
        UNION ALL
        SELECT 'output', ob.unit, ob.material_id, sum(mv.qty_delta)
          FROM inventory_movements mv JOIN output_batches ob ON ob.id = mv.output_batch_id
         GROUP BY ob.id, ob.unit, ob.material_id) k
  JOIN materials m ON m.id = k.material_id
 WHERE k.qty <> 0
 GROUP BY 2, 3, 4 ORDER BY 2, 3, 4;
SELECT 'on_site_by_location', location, count(*) AS batch_buckets_with_stock, sum(qty) AS qty
  FROM (SELECT coalesce(l.code, '(unspecified)') AS location, coalesce(mv.inbound_batch_id, mv.output_batch_id) AS batch, sum(mv.qty_delta) AS qty
          FROM inventory_movements mv LEFT JOIN storage_locations l ON l.id = mv.location_id
         GROUP BY 1, 2 HAVING sum(mv.qty_delta) <> 0) x
 GROUP BY location ORDER BY location;
SELECT 'materials_classified', coalesce(waste_classification_code, '(unclassified)'), count(*) FROM materials GROUP BY 2 ORDER BY 2;
SELECT 'allowed_classes', count(*) FROM storage_location_allowed_classes;
ROLLBACK;
