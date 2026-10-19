-- MES-9b — opening and closing live readings (2026-10-19), read-only: BEGIN READ ONLY … ROLLBACK. Copied from
-- docs/surveys/MES-9a/live-readings.sql; MES-9b adds the mes9bprobe residue lines, the download log, the portal's storage reach
-- (schema USAGE · storage.objects SELECT · its one policy), the storage policy names, and fingerprints of every table the live proof
-- writes into (inside its rolled-back transaction, or committed and removed afterwards): supplier_portal_users, supplier_statements,
-- cod_issues, certificates_of_destruction, weighbridge_tickets, weighbridge_ticket_shares.
-- Identity: postgres (rolbypassrls = true) on base tables (relkind 'r'), storage.objects and the catalog, so counts are real row counts.
-- The two reconciliations resolve the reader's codes, so they run as tim@ (634c00f9…, role cfo) switched to `authenticated` — a READ,
-- in a read-only transaction, the MES-8b-2 precedent (no write, nothing acted on). Adapted from docs/surveys/MES-8b-2/live-readings.sql.
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/MES-9b/live-readings.sql
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
SELECT 'APPROVALS|enabled=' || approvals_enabled || '|l1=' || COALESCE(approval_level1_role_code, '-') || '|l2=' || COALESCE(approval_level2_role_code, '-')
    || '|threshold=' || COALESCE(approval_threshold_base::text, '-') FROM finance_settings;
SELECT 'ACCOUNTS_LOGIN|all=' || count(*) || '|disabled=' || count(*) FILTER (WHERE banned_until > now()) || '|test_local=' || count(*) FILTER (WHERE email LIKE '%@test.local') FROM auth.users;
SELECT 'ACCOUNT|' || u.email || '|banned=' || COALESCE((u.banned_until > now())::text, 'false') || '|' || COALESCE(string_agg(r.code, ',' ORDER BY r.code), '-') FROM auth.users u
  LEFT JOIN user_roles ur ON ur.user_id = u.id AND ur.revoked_at IS NULL LEFT JOIN roles r ON r.id = ur.role_id
 GROUP BY u.email, u.banned_until ORDER BY u.email;
SELECT 'ROLECODES|' || string_agg(r.code || '=' || n, ' ' ORDER BY r.code)
  FROM (SELECT role_id, count(*) n FROM role_permissions GROUP BY role_id) x JOIN roles r ON r.id = x.role_id;
SELECT 'ROLEPERMS_MD5|' || md5(string_agg(r.code || ':' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code)) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
SELECT 'CALIB|require_calibrated_since=' || COALESCE(require_calibrated_since::text, 'NULL') FROM ingest_settings;
SELECT 'THROWAWAY|probe roles=' || (SELECT count(*) FROM roles WHERE code LIKE 'probe-%' OR code LIKE 'zz-mes9%')
    || '|test.local accounts=' || (SELECT count(*) FROM auth.users WHERE email LIKE '%@test.local')
    || '|mes9a/9b probe accounts=' || (SELECT count(*) FROM auth.users WHERE email LIKE 'mes9aprobe%' OR email LIKE 'mes9bprobe%' OR email LIKE 'anonymised-%@portal.invalid')
    || '|ZZ-PROBE mes9 suppliers=' || (SELECT count(*) FROM suppliers WHERE legal_name LIKE 'ZZ-PROBE mes9%')
    || '|mes9 probe contacts=' || (SELECT count(*) FROM counterparty_contacts WHERE email LIKE 'mes9%probe%' OR name LIKE 'ZZ-PROBE%')
    || '|ZZ-PROBE-MES9B rows=' || ((SELECT count(*) FROM supplier_statements WHERE code LIKE 'ZZ-PROBE-MES9B%') + (SELECT count(*) FROM purchase_orders WHERE code LIKE 'ZZ-PROBE-MES9B%')
                                   + (SELECT count(*) FROM inbound_batches WHERE code LIKE 'ZZ-PROBE-MES9B%') + (SELECT count(*) FROM weighbridge_tickets WHERE code LIKE 'ZZ-PROBE-MES9B%'))
    || '|grants without an account=' || (SELECT count(*) FROM user_roles ur WHERE NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = ur.user_id));
SELECT 'PORTAL|role supplier_portal=' || EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supplier_portal')
    || '|links=' || CASE WHEN to_regclass('public.supplier_portal_users') IS NULL THEN 'no table' ELSE ((xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM supplier_portal_users', false, true, '')))[1])::text END
    || '|account_settings=' || CASE WHEN to_regclass('public.account_settings') IS NULL THEN 'no table'
                                    ELSE ((xpath('/row/v/text()', query_to_xml('SELECT COALESCE(initial_password_valid_days::text, ''NULL'') || ''/'' || COALESCE(password_min_length::text, ''NULL'') AS v FROM account_settings', false, true, '')))[1])::text END
    || '|code action.manage_portal_users holders=' || COALESCE((SELECT string_agg(r.code, ',' ORDER BY r.code) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                   WHERE rp.permission_code = 'action.manage_portal_users'), '-');
SELECT 'PORTAL_9B|download log=' || CASE WHEN to_regclass('public.portal_document_downloads') IS NULL THEN 'no table'
             ELSE ((xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM portal_document_downloads', false, true, '')))[1])::text END
    || '|storage USAGE=' || has_schema_privilege('supplier_portal', 'storage', 'USAGE')
    || '|storage.objects SELECT=' || has_table_privilege('supplier_portal', 'storage.objects', 'SELECT')
    || '|portal storage policies=' || (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage' AND 'supplier_portal' = ANY (roles))
    || '|portal functions=' || (SELECT string_agg(p.proname, ',' ORDER BY p.proname) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                                 WHERE n.nspname = 'public' AND has_function_privilege('supplier_portal', p.oid, 'EXECUTE'))
    || '|change-log exclusions=' || (change_log_coverage_gaps() ->> 'excluded');
SELECT 'STORAGE_POLICY_NAMES|md5=' || md5(string_agg(policyname || ':' || cmd || ':' || roles::text || ':' || COALESCE(qual, '') || ':' || COALESCE(with_check, ''), '|' ORDER BY policyname))
  FROM pg_policies WHERE schemaname = 'storage' AND NOT ('supplier_portal' = ANY (roles));
SELECT 'FP_CONTACTS|' || count(*) || '|' || md5(COALESCE(string_agg((to_jsonb(x) - 'anonymised_at')::text, '' ORDER BY (to_jsonb(x) - 'anonymised_at')::text), ''))
  FROM counterparty_contacts x;
SELECT 'PENDING|' || count(*) || '|' || COALESCE(string_agg(to_jsonb(d)::text, ' ; '), '') FROM approval_pending_documents() d;
SELECT 'COD|' || c.code || '|' || c.status || '|recorded sha256=' || COALESCE(i.sha256, '-') || '|path=' || COALESCE(i.file_path, '-')
    || '|snapshot md5=' || COALESCE(md5(c.snapshot::text), '-')
  FROM certificates_of_destruction c LEFT JOIN cod_issues i ON i.cod_id = c.id WHERE c.status = 'issued' ORDER BY c.code;
-- every stored file: bucket · name · size · eTag · updated_at (the "every bucket holds exactly what it held" reading)
SELECT 'OBJ|' || bucket_id || '|' || name || '|' || COALESCE(metadata ->> 'size', '?') || '|' || COALESCE(metadata ->> 'eTag', '?') || '|' || updated_at
  FROM storage.objects ORDER BY bucket_id, name;
SELECT 'OBJ_TOTAL|' || count(*) || '|md5=' || md5(string_agg(bucket_id || '/' || name || ':' || COALESCE(metadata ->> 'eTag', '?') || ':' || updated_at, ',' ORDER BY bucket_id, name)) FROM storage.objects;
SELECT 'BUCKETS|' || string_agg(id || ':' || public, ',' ORDER BY id) FROM storage.buckets;
SELECT 'STORAGE_POLICIES|' || count(*) FROM pg_policies WHERE schemaname = 'storage';
-- fingerprints of the pre-existing rows (md5 over the whole table, ordered)
SELECT 'FP|' || t || '|' || n || '|' || h FROM (VALUES
    ('role_permissions', (SELECT count(*) FROM role_permissions), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM role_permissions x)),
    ('permissions', (SELECT count(*) FROM permissions), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM permissions x)),
    ('metal_price_indices', (SELECT count(*) FROM metal_price_indices), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM metal_price_indices x)),
    ('pricing_settings', (SELECT count(*) FROM pricing_settings), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM pricing_settings x)),
    ('accounts', (SELECT count(*) FROM accounts), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM accounts x)),
    ('collection_promises', (SELECT count(*) FROM collection_promises), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM collection_promises x)),
    ('collection_chases', (SELECT count(*) FROM collection_chases), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM collection_chases x)),
    ('company_profile', (SELECT count(*) FROM company_profile), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM company_profile x)),
    ('cn_issues', (SELECT count(*) FROM cn_issues), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM cn_issues x)),
    ('invoice_issues', (SELECT count(*) FROM invoice_issues), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM invoice_issues x)),
    ('po_issues', (SELECT count(*) FROM po_issues), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM po_issues x)),
    ('qt_issues', (SELECT count(*) FROM qt_issues), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM qt_issues x)),
    ('shipment_issues', (SELECT count(*) FROM shipment_issues), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM shipment_issues x)),
    ('so_issues', (SELECT count(*) FROM so_issues), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM so_issues x)),
    ('statement_issues', (SELECT count(*) FROM statement_issues), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM statement_issues x)),
    ('traceability_report_issues', (SELECT count(*) FROM traceability_report_issues), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM traceability_report_issues x)),
    ('material_attachments', (SELECT count(*) FROM material_attachments), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM material_attachments x)),
    ('supplier_attachments', (SELECT count(*) FROM supplier_attachments), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM supplier_attachments x)),
    ('customer_attachments', (SELECT count(*) FROM customer_attachments), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM customer_attachments x)),
    ('finance_attachments', (SELECT count(*) FROM finance_attachments), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM finance_attachments x)),
    ('coa_issues', (SELECT count(*) FROM coa_issues), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM coa_issues x)),
    ('compliance_pack_issues', (SELECT count(*) FROM compliance_pack_issues), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM compliance_pack_issues x)),
    ('supplier_statement_issues', (SELECT count(*) FROM supplier_statement_issues), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM supplier_statement_issues x)),
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
    ('material_kinds', (SELECT count(*) FROM material_kinds), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM material_kinds x)),
    ('roles', (SELECT count(*) FROM roles), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM roles x)),
    ('user_roles', (SELECT count(*) FROM user_roles), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM user_roles x)),
    ('compliance_packs', (SELECT count(*) FROM compliance_packs), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM compliance_packs x)),
    ('pending_documents', (SELECT count(*) FROM approval_pending_documents()), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM approval_pending_documents() x)),
    ('supplier_compliance', (SELECT count(*) FROM supplier_compliance), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM supplier_compliance x)),
    ('employees', (SELECT count(*) FROM employees), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM employees x)),
    ('employee_accounts', (SELECT count(*) FROM employee_accounts), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM employee_accounts x)),
    ('supplier_portal_users', (SELECT count(*) FROM supplier_portal_users), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM supplier_portal_users x)),
    ('cod_issues', (SELECT count(*) FROM cod_issues), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM cod_issues x)),
    ('certificates_of_destruction', (SELECT count(*) FROM certificates_of_destruction), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM certificates_of_destruction x)),
    ('weighbridge_tickets', (SELECT count(*) FROM weighbridge_tickets), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM weighbridge_tickets x)),
    ('weighbridge_ticket_shares', (SELECT count(*) FROM weighbridge_ticket_shares), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM weighbridge_ticket_shares x)),
    ('counterparty_contacts', (SELECT count(*) FROM counterparty_contacts), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM counterparty_contacts x)),
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
