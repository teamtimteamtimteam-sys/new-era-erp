-- MES-8b-1 — opening and closing live readings (2026-10-17), read-only: BEGIN READ ONLY … ROLLBACK.
-- Identity: postgres (rolbypassrls = true) on base tables (relkind 'r'), the catalog and two BASE views that carry no permission predicate
-- (batch_balance_tree_all, stock_rollforward_monthly_all — owner-rights, revoked from staff, no has_permission in their bodies), so counts are
-- real row counts, not a permission answer (AGENTS.md「一个『0 行』的读数,先问它是谁读的」). The reconciliations are read in tim@'s session
-- (634c00f9…, role cfo) switched to `authenticated`, because they resolve the reader's codes and postgres carries no JWT.
-- The fingerprint lines (md5 over each table's rows) are compared between the opening and the closing run: every pre-existing row unchanged.
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/MES-8b-1/live-readings.sql
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
-- inbound batches with downstream outputs and sales (the MES-5b attribution tree, base view)
SELECT 'INBOUND|' || count(*) || '|with_downstream_outputs=' || count(*) FILTER (WHERE EXISTS (SELECT 1 FROM batch_balance_tree_all t
         WHERE t.root_kind = 'inbound' AND t.root_id = b.id AND t.node_type = 'run_output'))
    || '|with_downstream_sales=' || count(*) FILTER (WHERE EXISTS (SELECT 1 FROM batch_balance_tree_all t JOIN sales_records sr ON sr.output_batch_id = t.batch_id
         WHERE t.root_kind = 'inbound' AND t.root_id = b.id AND t.node_type = 'run_output'))
  FROM inbound_batches b WHERE b.deleted_at IS NULL;
SELECT 'INBOUND_DOWNSTREAM|' || b.code || '|outputs=' || count(DISTINCT t.batch_id) || '|max_depth=' || max(t.depth)
    || '|sold_outputs=' || count(DISTINCT t.batch_id) FILTER (WHERE EXISTS (SELECT 1 FROM sales_records sr WHERE sr.output_batch_id = t.batch_id))
  FROM inbound_batches b JOIN batch_balance_tree_all t ON t.root_kind = 'inbound' AND t.root_id = b.id AND t.node_type = 'run_output'
 WHERE b.deleted_at IS NULL GROUP BY b.code ORDER BY b.code;
SELECT 'INBOUND_PRICING|' || pricing_status || '|' || count(*) FROM inbound_batches WHERE deleted_at IS NULL GROUP BY pricing_status ORDER BY 1;
-- outputs with and without unit cost; sales and settlements
SELECT 'OUTPUTS|' || count(*) || '|from_a_run=' || count(*) FILTER (WHERE po.id IS NOT NULL)
    || '|with_unit_cost=' || count(*) FILTER (WHERE po.unit_cost_base IS NOT NULL) || '|run_without_unit_cost=' || count(*) FILTER (WHERE po.id IS NOT NULL AND po.unit_cost_base IS NULL)
    || '|cost_incomplete=' || count(*) FILTER (WHERE po.cost_incomplete) || '|no_run=' || count(*) FILTER (WHERE po.id IS NULL)
  FROM output_batches ob LEFT JOIN processing_outputs po ON po.output_batch_id = ob.id WHERE ob.deleted_at IS NULL;
SELECT 'SALES|records=' || (SELECT count(*) FROM sales_records) || '|batches=' || (SELECT count(DISTINCT output_batch_id) FROM sales_records)
    || '|settlements=' || (SELECT count(*) FROM sales_settlements);
-- metal prices by metal and date; content on batches
SELECT 'PRICE|' || p.metal || '|' || s.role || '|rows=' || count(*) || '|latest=' || max(p.price_date) || '|indices=' || count(DISTINCT p.price_index)
    || '|unindexed=' || count(*) FILTER (WHERE p.price_index IS NULL)
  FROM metal_prices p JOIN substances s ON s.code = p.metal WHERE p.deleted_at IS NULL GROUP BY p.metal, s.role ORDER BY 1;
SELECT 'PRICE_LATEST|' || p.metal || '|' || p.price_date || '|' || p.price_usd_per_tonne || '|index=' || COALESCE(p.price_index, '-')
  FROM metal_prices p WHERE p.deleted_at IS NULL AND p.price_date = (SELECT max(q.price_date) FROM metal_prices q WHERE q.metal = p.metal AND q.deleted_at IS NULL AND q.price_date <= CURRENT_DATE)
 ORDER BY p.metal, p.price_index NULLS FIRST;
SELECT 'CONTENT|inbound_batches=' || (SELECT count(DISTINCT inbound_batch_id) FROM inbound_batch_metals) || '|inbound_rows=' || (SELECT count(*) FROM inbound_batch_metals)
    || '|output_batches=' || (SELECT count(DISTINCT output_batch_id) FROM output_batch_metals) || '|output_rows=' || (SELECT count(*) FROM output_batch_metals);
SELECT 'ON_HAND|' || x.kind || '|batches=' || count(*) || '|kg=' || COALESCE(sum(x.qty) FILTER (WHERE x.unit = 'kg'), 0) || '|not_kg=' || count(*) FILTER (WHERE x.unit <> 'kg')
  FROM (SELECT 'inbound' AS kind, b.unit, sum(m.qty_delta) AS qty FROM inventory_movements m JOIN inbound_batches b ON b.id = m.inbound_batch_id GROUP BY b.id, b.unit
        UNION ALL SELECT 'output', b.unit, sum(m.qty_delta) FROM inventory_movements m JOIN output_batches b ON b.id = m.output_batch_id GROUP BY b.id, b.unit) x
 WHERE x.qty <> 0 GROUP BY x.kind ORDER BY 1;
-- locked months
SELECT 'PERIODS|locked_before=' || COALESCE(locked_before::text, 'NULL') || '|system_start_date=' || COALESCE(system_start_date::text, 'NULL') FROM finance_settings;
SELECT 'MANAGEMENT_PACKS|' || count(*) FROM management_packs;
-- licences and ceiling checks
SELECT 'LICENCE|' || cert_type_code || '|' || COALESCE(cert_no, '-') || '|status=' || COALESCE(status, '-') || '|' || COALESCE(valid_from::text, '-') || '…' || COALESCE(valid_until::text, '-')
    || '|storage_limit_t=' || COALESCE(approved_storage_limit_tonnes::text, '-') || '|deleted=' || (deleted_at IS NOT NULL)
  FROM company_compliance ORDER BY cert_type_code, cert_no;
SELECT 'LICENCE_IN_FORCE_TODAY|' || COALESCE(storage_licence_in_force(CURRENT_DATE)::text, 'none');
SELECT 'NEA|categories=' || (SELECT count(*) FROM nea_waste_categories) || '|storage_limits=' || (SELECT count(*) FROM licence_storage_limits)
    || '|materials_with_category=' || (SELECT count(*) FROM materials WHERE nea_waste_category_code IS NOT NULL);
SELECT 'CEILING_CHECKS|' || to_char(checked_on, 'YYYY-MM') || '|' || outcome || '|' || count(*) FROM receipt_ceiling_checks GROUP BY to_char(checked_on, 'YYYY-MM'), outcome ORDER BY 1;
-- incidents, environmental results, inspections and open findings
SELECT 'SAFETY|incidents=' || (SELECT count(*) FROM incidents) || '|incident_updates=' || (SELECT count(*) FROM incident_updates)
    || '|env_parameters=' || (SELECT count(*) FROM environmental_parameters) || '|env_results=' || (SELECT count(*) FROM environmental_results)
    || '|templates=' || (SELECT count(*) FROM inspection_templates) || '|runs=' || (SELECT count(*) FROM inspection_runs)
    || '|findings=' || (SELECT count(*) FROM inspection_findings) || '|open_findings=' || (SELECT count(*) FROM inspection_findings f
         WHERE NOT EXISTS (SELECT 1 FROM inspection_finding_closures c WHERE c.finding_id = f.id));
-- codes Q17 names and the roles they go to
SELECT 'CATALOGUE|' || count(*) || '|module=' || count(*) FILTER (WHERE code LIKE 'module.%') || '|action=' || count(*) FILTER (WHERE code LIKE 'action.%')
    || '|data=' || count(*) FILTER (WHERE code LIKE 'data.%') FROM permissions;
SELECT 'Q17_CODES|module.compliance.view=' || (SELECT count(*) FROM permissions WHERE code = 'module.compliance.view')
    || '|action.compliance_pack=' || (SELECT count(*) FROM permissions WHERE code = 'action.compliance_pack')
    || '|holders=' || COALESCE((SELECT string_agg(r.code || ':' || rp.permission_code, ',') FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                WHERE rp.permission_code IN ('module.compliance.view', 'action.compliance_pack')), 'none');
SELECT 'Q17_ROLES|' || string_agg(r.code || '=' || CASE WHEN r.is_active THEN 'active' ELSE 'inactive' END, ',' ORDER BY r.code)
  FROM roles r WHERE r.code IN ('admin', 'auditor', 'cfo', 'cco', 'cto', 'gm');
SELECT 'HOLDERS|' || p.code || '=' || COALESCE(string_agg(r.code, ',' ORDER BY r.code), '')
  FROM permissions p LEFT JOIN role_permissions rp ON rp.permission_code = p.code LEFT JOIN roles r ON r.id = rp.role_id
 WHERE p.code IN ('data.view_prices', 'module.finance.view', 'module.processing.view', 'module.safety.view', 'module.inventory.view')
 GROUP BY p.code ORDER BY p.code;
-- MES-8b-1's objects (absent before the migration)
SELECT 'MES8B1_TABLES|' || COALESCE(string_agg(tablename, ',' ORDER BY tablename), 'none') FROM pg_tables
 WHERE schemaname = 'public' AND (tablename LIKE 'compliance_pack%' OR tablename = 'compliance_settings');
SELECT 'DOCTYPES|' || count(*) || '|CPK=' || count(*) FILTER (WHERE prefix = 'CPK') FROM document_types;
SELECT 'BUCKETS|' || string_agg(id || ':' || (SELECT count(*) FROM storage.objects o WHERE o.bucket_id = b.id), ',' ORDER BY id) FROM storage.buckets b;
SELECT 'BUCKET_COMPLIANCE|' || COALESCE((SELECT id || ':public=' || public FROM storage.buckets WHERE id = 'compliance-documents'), 'absent');
-- standing state
SELECT 'APPROVALS|enabled=' || approvals_enabled || '|l1=' || COALESCE(approval_level1_role_code, '-') || '|l2=' || COALESCE(approval_level2_role_code, '-')
    || '|threshold=' || COALESCE(approval_threshold_base::text, '-') FROM finance_settings;
SELECT 'ACCOUNTS_LOGIN|all=' || count(*) || '|disabled=' || count(*) FILTER (WHERE banned_until > now()) FROM auth.users WHERE email NOT LIKE '%@test.local';
SELECT 'ACCOUNT|' || u.email || '|' || string_agg(r.code, ',' ORDER BY r.code) FROM auth.users u
  JOIN user_roles ur ON ur.user_id = u.id AND ur.revoked_at IS NULL JOIN roles r ON r.id = ur.role_id
 WHERE u.email NOT LIKE '%@test.local' GROUP BY u.email ORDER BY u.email;
SELECT 'ROLECODES|' || string_agg(r.code || '=' || n, ' ' ORDER BY r.code)
  FROM (SELECT role_id, count(*) n FROM role_permissions GROUP BY role_id) x JOIN roles r ON r.id = x.role_id;
SELECT 'ROLEPERMS_MD5_EXCL_COMPLIANCE|' || md5(string_agg(r.code || ':' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code))
  FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE rp.permission_code NOT IN ('module.compliance.view', 'action.compliance_pack');
SELECT 'CALIB|require_calibrated_since=' || COALESCE(require_calibrated_since::text, 'NULL') FROM ingest_settings;
SELECT 'THROWAWAY|accounts=' || (SELECT count(*) FROM auth.users WHERE email LIKE '%@test.local')
    || '|probe roles=' || (SELECT count(*) FROM roles WHERE code LIKE 'probe-%' OR code LIKE 'mes8b1probe%');
SELECT 'PENDING|' || count(*) || '|' || COALESCE(string_agg(to_jsonb(d)::text, ' ; '), '') FROM approval_pending_documents() d;
SELECT 'COD|' || c.code || '|' || c.status || '|recorded sha256=' || COALESCE(i.sha256, '-') || '|path=' || COALESCE(i.file_path, '-')
    || '|snapshot md5=' || COALESCE(md5(c.snapshot::text), '-')
  FROM certificates_of_destruction c LEFT JOIN cod_issues i ON i.cod_id = c.id WHERE c.status = 'issued' ORDER BY c.code;
SELECT 'COD_ISSUES|' || count(*) || '|md5=' || COALESCE(md5(string_agg(to_jsonb(i)::text, '' ORDER BY id)), '-') FROM cod_issues i;
SELECT 'COD_BUCKET|objects=' || count(*) || '|' || COALESCE(string_agg(name || ':' || COALESCE(metadata ->> 'size', '?') || ':' || COALESCE(metadata ->> 'eTag', '?'), ',' ORDER BY name), '')
  FROM storage.objects WHERE bucket_id = 'cod-documents';
-- fingerprints of the pre-existing rows this cut reads (md5 over the whole table, ordered)
SELECT 'FP|' || t || '|' || n || '|' || h FROM (VALUES
    ('inbound_batches', (SELECT count(*) FROM inbound_batches), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM inbound_batches x)),
    ('output_batches', (SELECT count(*) FROM output_batches), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM output_batches x)),
    ('processing_runs', (SELECT count(*) FROM processing_runs), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM processing_runs x)),
    ('processing_inputs', (SELECT count(*) FROM processing_inputs), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM processing_inputs x)),
    ('processing_outputs', (SELECT count(*) FROM processing_outputs), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM processing_outputs x)),
    ('inventory_movements', (SELECT count(*) FROM inventory_movements), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM inventory_movements x)),
    ('sales_records', (SELECT count(*) FROM sales_records), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM sales_records x)),
    ('sales_settlements', (SELECT count(*) FROM sales_settlements), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM sales_settlements x)),
    ('metal_prices', (SELECT count(*) FROM metal_prices), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM metal_prices x)),
    ('inbound_batch_metals', (SELECT count(*) FROM inbound_batch_metals), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM inbound_batch_metals x)),
    ('output_batch_metals', (SELECT count(*) FROM output_batch_metals), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM output_batch_metals x)),
    ('company_compliance', (SELECT count(*) FROM company_compliance), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM company_compliance x)),
    ('receipt_ceiling_checks', (SELECT count(*) FROM receipt_ceiling_checks), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM receipt_ceiling_checks x)),
    ('incidents', (SELECT count(*) FROM incidents), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM incidents x)),
    ('environmental_results', (SELECT count(*) FROM environmental_results), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM environmental_results x)),
    ('inspection_runs', (SELECT count(*) FROM inspection_runs), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM inspection_runs x)),
    ('inspection_findings', (SELECT count(*) FROM inspection_findings), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM inspection_findings x)),
    ('management_packs', (SELECT count(*) FROM management_packs), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM management_packs x)),
    ('finance_settings', (SELECT count(*) FROM finance_settings), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM finance_settings x)),
    ('journal_entries', (SELECT count(*) FROM journal_entries), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM journal_entries x)),
    ('journal_lines', (SELECT count(*) FROM journal_lines), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM journal_lines x)),
    ('payments', (SELECT count(*) FROM payments), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM payments x)),
    ('expenses', (SELECT count(*) FROM expenses), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM expenses x)),
    ('suppliers', (SELECT count(*) FROM suppliers), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM suppliers x)),
    ('purchase_orders', (SELECT count(*) FROM purchase_orders), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM purchase_orders x)),
    ('materials', (SELECT count(*) FROM materials), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM materials x)),
    ('supplier_statements', (SELECT count(*) FROM supplier_statements), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM supplier_statements x)),
    ('customer_statements', (SELECT count(*) FROM customer_statements), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM customer_statements x))
) v(t, n, h) ORDER BY 1;
SELECT 'CHANGELOG|rows=' || count(*) || '|max seq=' || max(seq) FROM change_log;
SELECT 'VIEWS|' || count(*) || '|writable_pairs=' || (SELECT count(*) FROM pg_class c2 JOIN pg_namespace n2 ON n2.oid = c2.relnamespace
        CROSS JOIN (VALUES ('anon'), ('authenticated')) g(r) CROSS JOIN (VALUES ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) p(priv)
        WHERE n2.nspname = 'public' AND c2.relkind = 'v' AND has_table_privilege(g.r, c2.oid, p.priv))
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'v';
SELECT 'TABLES|' || count(*) FROM pg_tables WHERE schemaname = 'public';
SELECT 'PENDING_ARMS|' || (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g'))
    || '|REMINDER_ARMS=' || (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g'));
-- tim@'s session: the reconciliations
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) IS NOT NULL AS as_tim;
SET LOCAL ROLE authenticated;
SELECT 'RECON|' || (s ->> 'side') || '|list=' || (s ->> 'list_base') || '|ledger=' || (s ->> 'ledger_base') || '|unexplained=' || (s ->> 'unexplained_base')
  FROM jsonb_array_elements(list_ledger_reconciliation() -> 'sides') s;
SELECT 'INVCTL|' || (s ->> 'side') || '|ledger=' || (s ->> 'ledger_base') || '|subledger=' || (s ->> 'subledger_base') || '|unexplained='
    || COALESCE(s ->> 'unexplained_base', 'NULL') || '|reconciled=' || COALESCE(s ->> 'reconciled', 'NULL')
  FROM jsonb_array_elements(gl_control_reconciliation(CURRENT_DATE) -> 'sides') s WHERE s ->> 'side' LIKE 'inventory%';
RESET ROLE;
ROLLBACK;
