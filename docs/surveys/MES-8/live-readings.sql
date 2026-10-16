-- MES-8 Step 0 — live readings, read-only (BEGIN READ ONLY … ROLLBACK), as postgres (rolbypassrls = true) on base tables and the catalog.
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/MES-8/live-readings.sql
BEGIN READ ONLY;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
SELECT 'SUPPLIERS|' || count(*) || '|' || string_agg(DISTINCT status::text, ',') || '|goods=' || count(*) FILTER (WHERE supplies_goods)
    || '|credit_rating_set=' || count(*) FILTER (WHERE NULLIF(btrim(credit_rating), '') IS NOT NULL) FROM suppliers WHERE deleted_at IS NULL;
SELECT 'SUPPLIER_STATUS|' || status || '|' || count(*) FROM suppliers WHERE deleted_at IS NULL GROUP BY status ORDER BY 1;
SELECT 'POS|' || count(*) || '|with_on_order_term=' || count(DISTINCT t.purchase_order_id) FILTER (WHERE t.trigger_event = 'on_order')
  FROM purchase_orders p LEFT JOIN purchase_order_payment_terms t ON t.purchase_order_id = p.id;
SELECT 'INBOUND|' || count(*) || '|suppliers=' || count(DISTINCT supplier_id) || '|priced_final=' || count(*) FILTER (WHERE pricing_status = 'final')
    || '|provisional=' || count(*) FILTER (WHERE pricing_status = 'provisional') FROM inbound_batches WHERE deleted_at IS NULL;
SELECT 'GRN_DISCREPANCIES|' || count(*) FROM grn_discrepancies;
SELECT 'GRADE_BREACHES|' || count(*) FROM contract_grade_breaches;
SELECT 'NCR|' || count(*) || '|DISPUTES|' || (SELECT count(*) FROM assay_disputes) FROM nonconformance_reports;
SELECT 'SUPPLIER_CERTS|' || count(*) || '|lapsed=' || count(*) FILTER (WHERE valid_until < CURRENT_DATE) FROM supplier_compliance;
SELECT 'AP_OPEN|' || count(*) || '|suppliers=' || count(DISTINCT counterparty_id) FILTER (WHERE counterparty_kind = 'supplier') FROM ap_open_items;
SELECT 'CUSTOMER_STATEMENTS|' || count(*) || '|issues=' || (SELECT count(*) FROM statement_issues) FROM customer_statements;
SELECT 'PACKS|' || count(*) || '|live=' || count(*) FILTER (WHERE superseded_at IS NULL) || '|' || COALESCE(string_agg(code, ',' ORDER BY code), '-') FROM management_packs;
SELECT 'LOCKED_BEFORE|' || COALESCE(locked_before::text, 'NULL') || '|system_start=' || COALESCE(system_start_date::text, 'NULL') FROM finance_settings;
SELECT 'OUTPUT|' || count(*) || '|sold_records=' || (SELECT count(*) FROM sales_records) || '|settlements=' || (SELECT count(*) FROM sales_settlements) FROM output_batches WHERE deleted_at IS NULL;
SELECT 'RUNS|' || count(*) || '|committed=' || count(*) FILTER (WHERE status = 'committed') || '|basis=' || string_agg(DISTINCT allocation_basis, ',') FROM processing_runs;
SELECT 'METAL_PRICES|' || count(*) || '|indexed=' || count(*) FILTER (WHERE price_index IS NOT NULL) || '|latest=' || COALESCE(max(price_date)::text, '-') FROM metal_prices;
SELECT 'BATCH_METALS|inbound=' || (SELECT count(DISTINCT inbound_batch_id) FROM inbound_batch_metals) || '|output=' || (SELECT count(DISTINCT output_batch_id) FROM output_batch_metals);
SELECT 'MARKET_CAL|' || count(*) FROM index_market_calendar;
SELECT 'LICENCES|' || count(*) || '|nea_categories=' || (SELECT count(*) FROM nea_waste_categories) || '|limits=' || (SELECT count(*) FROM licence_storage_limits) FROM company_compliance;
SELECT 'ROLES|' || string_agg(code, ',' ORDER BY code) FROM roles WHERE is_active;
SELECT 'CODES|' || count(*) || '|module=' || count(*) FILTER (WHERE code LIKE 'module.%') || '|action=' || count(*) FILTER (WHERE code LIKE 'action.%') || '|data=' || count(*) FILTER (WHERE code LIKE 'data.%') FROM permissions;
SELECT 'HOLDERS|' || p.code || '=' || COALESCE(string_agg(r.code, ',' ORDER BY r.code), '') FROM permissions p LEFT JOIN role_permissions rp ON rp.permission_code = p.code
  LEFT JOIN roles r ON r.id = rp.role_id WHERE p.code IN ('module.suppliers.view','module.suppliers.edit','module.finance.view','module.finance.edit','data.view_prices','data.view_purchase_prices','module.processing.view','action.supplier_approve')
 GROUP BY p.code ORDER BY 1;
SELECT 'DOCTYPES|' || count(*) FROM document_types;
SELECT 'PENDING_ARMS|' || (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), '''V[0-9]+''::text AS value_code', 'g'));
SELECT 'APPROVALS|enabled=' || approvals_enabled || '|l1=' || approval_level1_role_code || '|l2=' || approval_level2_role_code || '|threshold=' || approval_threshold_base FROM finance_settings;
SELECT 'TABLES|' || count(*) FROM pg_tables WHERE schemaname = 'public';
ROLLBACK;
