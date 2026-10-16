-- MES-8a — opening and closing live readings (2026-10-16), read-only: BEGIN READ ONLY … ROLLBACK.
-- Identity: postgres (rolbypassrls = true) on base tables (relkind 'r') and the catalog, so counts are real row counts, not a permission answer
-- (AGENTS.md「一个『0 行』的读数,先问它是谁读的」). Three things are read in tim@'s session (634c00f9…, role cfo), switched to `authenticated`
-- with that sub (read only, no write possible), because they resolve the reader's codes and postgres carries no JWT: ap_open_items (a view with
-- a has_permission predicate) and the two reconciliations.
-- GL 2000 per supplier is attributed through each journal line's ENTRY SOURCE, original entry first (a reversal's source_id names the original
-- entry, not the document — AGENTS.md「source_id 在冲销件上指的是原分录」): purchase → inbound_batches.supplier_id · expense → expenses.supplier_id
-- (employee_id → 'employee') · freight → freight_documents.supplier_id · payment → payments.supplier_id (employee_id → 'employee') ·
-- prepayment → prepayment_applications → purchase_orders.supplier_id. Every other source type is reported by name as not attributable.
-- COD stored-byte hashes are measured by docs/surveys/MES-8a/cod-bytes.mjs (downloads the two objects, GET only); this file reads the recorded hash.
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/MES-8a/live-readings.sql
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
-- suppliers by status and kind
SELECT 'SUPPLIERS|' || s.status || '|' || s.counterparty_type || '|' || count(*) FROM suppliers s WHERE s.deleted_at IS NULL GROUP BY s.status, s.counterparty_type ORDER BY 1;
SELECT 'SUPPLIERS_DELETED|' || count(*) FROM suppliers WHERE deleted_at IS NOT NULL;
-- purchase orders with prepayments (an on_order term), and prepayment applications
SELECT 'PO|' || count(*) || '|with_on_order_term=' || count(*) FILTER (WHERE EXISTS (SELECT 1 FROM purchase_order_payment_terms t
         WHERE t.purchase_order_id = p.id AND t.trigger_event = 'on_order')) FROM purchase_orders p;
SELECT 'PO_PREPAY|' || p.code || '|' || s.code || '|' || p.status || '|on_order_pct=' || COALESCE((SELECT sum(t.percentage)::text FROM purchase_order_payment_terms t
         WHERE t.purchase_order_id = p.id AND t.trigger_event = 'on_order'), '-') || '|on_order_fixed=' || COALESCE((SELECT sum(t.fixed_amount_ccy)::text
         FROM purchase_order_payment_terms t WHERE t.purchase_order_id = p.id AND t.trigger_event = 'on_order'), '-')
  FROM purchase_orders p JOIN suppliers s ON s.id = p.supplier_id
 WHERE EXISTS (SELECT 1 FROM purchase_order_payment_terms t WHERE t.purchase_order_id = p.id AND t.trigger_event = 'on_order') ORDER BY p.code;
SELECT 'PREPAY_APPLICATIONS|' || count(*) || '|sum_base=' || COALESCE(sum(amount_base), 0) FROM prepayment_applications;
-- receipts and their pricing state per supplier
SELECT 'RECEIPTS|' || s.code || '|' || b.pricing_status || '|' || count(*) || '|unit_price_null=' || count(*) FILTER (WHERE b.unit_price IS NULL)
  FROM inbound_batches b JOIN suppliers s ON s.id = b.supplier_id WHERE b.deleted_at IS NULL GROUP BY s.code, b.pricing_status ORDER BY 1;
-- NCRs, disputes and certificates per supplier
SELECT 'NCR|' || COALESCE(s.code, '(no inbound batch)') || '|' || n.status || '|' || COALESCE(n.disposition, '-') || '|' || count(*)
  FROM nonconformance_reports n LEFT JOIN inbound_batches b ON b.id = n.inbound_batch_id LEFT JOIN suppliers s ON s.id = b.supplier_id
 GROUP BY s.code, n.status, n.disposition ORDER BY 1;
SELECT 'NCR_TOTAL|' || count(*) FROM nonconformance_reports;
SELECT 'DISPUTES|' || COALESCE(s.code, '(no inbound batch)') || '|' || d.status || '|' || count(*)
  FROM assay_disputes d LEFT JOIN inbound_batches b ON b.id = d.inbound_batch_id LEFT JOIN suppliers s ON s.id = b.supplier_id GROUP BY s.code, d.status ORDER BY 1;
SELECT 'DISPUTES_TOTAL|' || count(*) FROM assay_disputes;
SELECT 'CERTS|' || s.code || '|' || c.cert_type_code || '|valid_until=' || COALESCE(c.valid_until::text, 'NULL') || '|lapsed=' || (c.valid_until < CURRENT_DATE)::text
  FROM supplier_compliance c JOIN suppliers s ON s.id = c.supplier_id WHERE c.deleted_at IS NULL ORDER BY s.code, c.cert_type_code;
-- GL 2000 per supplier (base table journal_lines, attributed by source; see the header)
WITH l AS (
    SELECT jl.credit - jl.debit AS amt, COALESCE(o.source_type, je.source_type) AS st, COALESCE(o.source_id, je.source_id) AS sid
      FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id AND a.code = '2000'
      JOIN journal_entries je ON je.id = jl.entry_id
      LEFT JOIN journal_entries o ON o.reversed_by = je.id
), att AS (
    SELECT l.amt, l.st, CASE l.st
        WHEN 'purchase'   THEN (SELECT 'S:' || s.code FROM inbound_batches b JOIN suppliers s ON s.id = b.supplier_id WHERE b.id = l.sid)
        WHEN 'expense'    THEN (SELECT CASE WHEN e.employee_id IS NOT NULL THEN 'employee' ELSE 'S:' || s.code END FROM expenses e LEFT JOIN suppliers s ON s.id = e.supplier_id WHERE e.id = l.sid)
        WHEN 'freight'    THEN (SELECT 'S:' || s.code FROM freight_documents f JOIN suppliers s ON s.id = f.supplier_id WHERE f.id = l.sid)
        WHEN 'payment'    THEN (SELECT CASE WHEN p.employee_id IS NOT NULL THEN 'employee' ELSE 'S:' || s.code END FROM payments p LEFT JOIN suppliers s ON s.id = p.supplier_id WHERE p.id = l.sid)
        WHEN 'prepayment' THEN (SELECT 'S:' || s.code FROM prepayment_applications pa JOIN purchase_orders po ON po.id = pa.purchase_order_id JOIN suppliers s ON s.id = po.supplier_id WHERE pa.id = l.sid)
        END AS who FROM l)
SELECT 'GL2000|' || COALESCE(who, 'not attributable: ' || st) || '|' || round(sum(amt), 2) || '|lines=' || count(*) FROM att GROUP BY COALESCE(who, 'not attributable: ' || st) ORDER BY 1;
SELECT 'GL2000_TOTAL|' || round(sum(jl.credit - jl.debit), 2) FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id AND a.code = '2000';
-- customer statements (the precedent) and their issues
SELECT 'CUSTOMER_STATEMENTS|' || count(*) || '|live=' || count(*) FILTER (WHERE superseded_at IS NULL) || '|issues=' || (SELECT count(*) FROM statement_issues) FROM customer_statements;
SELECT 'STATEMENT_BUCKET|' || COALESCE((SELECT id || ':public=' || public FROM storage.buckets WHERE id = 'statement-documents'), 'absent')
    || '|objects=' || (SELECT count(*) FROM storage.objects WHERE bucket_id = 'statement-documents');
SELECT 'BUCKETS|' || string_agg(id || ':' || (SELECT count(*) FROM storage.objects o WHERE o.bucket_id = b.id), ',' ORDER BY id) FROM storage.buckets b;
-- MES-8a's objects (absent before the migration)
SELECT 'MES8A_TABLES|' || COALESCE(string_agg(tablename, ',' ORDER BY tablename), 'none') FROM pg_tables
 WHERE schemaname = 'public' AND (tablename LIKE 'supplier_score%' OR tablename LIKE 'supplier_statement%');
SELECT 'DOCTYPES|' || count(*) || '|SST=' || count(*) FILTER (WHERE prefix = 'SST') FROM document_types;
-- codes and their holders
SELECT 'CATALOGUE|' || count(*) || '|module=' || count(*) FILTER (WHERE code LIKE 'module.%') || '|action=' || count(*) FILTER (WHERE code LIKE 'action.%')
    || '|data=' || count(*) FILTER (WHERE code LIKE 'data.%') FROM permissions;
SELECT 'HOLDERS|' || p.code || '=' || COALESCE(string_agg(r.code, ',' ORDER BY r.code), '')
  FROM permissions p LEFT JOIN role_permissions rp ON rp.permission_code = p.code LEFT JOIN roles r ON r.id = rp.role_id
 WHERE p.code IN ('module.suppliers.view', 'module.suppliers.edit', 'module.finance.view', 'module.finance.edit', 'action.supplier_approve',
                  'action.supplier_review', 'data.view_purchase_prices')
 GROUP BY p.code ORDER BY p.code;
-- standing state
SELECT 'APPROVALS|enabled=' || approvals_enabled || '|l1=' || COALESCE(approval_level1_role_code, '-') || '|l2=' || COALESCE(approval_level2_role_code, '-')
    || '|threshold=' || COALESCE(approval_threshold_base::text, '-') FROM finance_settings;
SELECT 'ACCOUNTS_LOGIN|all=' || count(*) || '|disabled=' || count(*) FILTER (WHERE banned_until > now()) FROM auth.users WHERE email NOT LIKE '%@test.local';
SELECT 'ACCOUNT|' || u.email || '|' || string_agg(r.code, ',' ORDER BY r.code) FROM auth.users u
  JOIN user_roles ur ON ur.user_id = u.id AND ur.revoked_at IS NULL JOIN roles r ON r.id = ur.role_id
 WHERE u.email NOT LIKE '%@test.local' GROUP BY u.email ORDER BY u.email;
SELECT 'ROLECODES|' || string_agg(r.code || '=' || n, ' ' ORDER BY r.code)
  FROM (SELECT role_id, count(*) n FROM role_permissions GROUP BY role_id) x JOIN roles r ON r.id = x.role_id;
SELECT 'ROLEPERMS_MD5|' || md5(string_agg(r.code || ':' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code))
  FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
SELECT 'ROLEPERMS_MD5_EXCL_REVIEW|' || md5(string_agg(r.code || ':' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code))
  FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE rp.permission_code <> 'action.supplier_review';
SELECT 'CALIB|require_calibrated_since=' || COALESCE(require_calibrated_since::text, 'NULL') FROM ingest_settings;
SELECT 'THROWAWAY|accounts=' || (SELECT count(*) FROM auth.users WHERE email LIKE '%@test.local')
    || '|probe roles=' || (SELECT count(*) FROM roles WHERE code LIKE 'probe-%');
SELECT 'PENDING|' || count(*) || '|' || COALESCE(string_agg(to_jsonb(d)::text, ' ; '), '') FROM approval_pending_documents() d;
SELECT 'COD|' || c.code || '|' || c.status || '|recorded sha256=' || COALESCE(i.sha256, '-') || '|path=' || COALESCE(i.file_path, '-')
    || '|snapshot md5=' || COALESCE(md5(c.snapshot::text), '-')
  FROM certificates_of_destruction c LEFT JOIN cod_issues i ON i.cod_id = c.id WHERE c.status = 'issued' ORDER BY c.code;
SELECT 'COD_ISSUES|' || count(*) || '|md5=' || COALESCE(md5(string_agg(to_jsonb(i)::text, '' ORDER BY id)), '-') FROM cod_issues i;
SELECT 'COD_BUCKET|objects=' || count(*) || '|' || COALESCE(string_agg(name || ':' || COALESCE(metadata ->> 'size', '?') || ':' || COALESCE(metadata ->> 'eTag', '?'), ',' ORDER BY name), '')
  FROM storage.objects WHERE bucket_id = 'cod-documents';
SELECT 'JOURNAL|entries=' || (SELECT count(*) FROM journal_entries) || '|lines=' || (SELECT count(*) FROM journal_lines)
    || '|md5 entries=' || (SELECT md5(string_agg(to_jsonb(e)::text, '' ORDER BY id)) FROM journal_entries e);
SELECT 'SUPPLIERS_MD5|' || count(*) || '|' || md5(string_agg(to_jsonb(s)::text, '' ORDER BY id)) FROM suppliers s;
SELECT 'PO_MD5|' || count(*) || '|' || md5(string_agg(to_jsonb(p)::text, '' ORDER BY id)) FROM purchase_orders p;
SELECT 'PO_TERMS_MD5|' || count(*) || '|' || md5(string_agg(to_jsonb(t)::text, '' ORDER BY id)) FROM purchase_order_payment_terms t;
SELECT 'BATCHES|' || count(*) || '|md5=' || md5(string_agg(to_jsonb(b)::text, '' ORDER BY id)) FROM inbound_batches b;
SELECT 'PAYMENTS|' || count(*) || '|md5=' || md5(string_agg(to_jsonb(p)::text, '' ORDER BY id)) FROM payments p;
SELECT 'EXPENSES|' || count(*) || '|md5=' || md5(string_agg(to_jsonb(e)::text, '' ORDER BY id)) FROM expenses e;
SELECT 'CERTS_MD5|' || count(*) || '|' || md5(string_agg(to_jsonb(c)::text, '' ORDER BY id)) FROM supplier_compliance c;
SELECT 'CHANGELOG|rows=' || count(*) || '|max seq=' || max(seq) FROM change_log;
SELECT 'VIEWS|' || count(*) || '|writable_pairs=' || (SELECT count(*) FROM pg_class c2 JOIN pg_namespace n2 ON n2.oid = c2.relnamespace
        CROSS JOIN (VALUES ('anon'), ('authenticated')) g(r) CROSS JOIN (VALUES ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) p(priv)
        WHERE n2.nspname = 'public' AND c2.relkind = 'v' AND has_table_privilege(g.r, c2.oid, p.priv))
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'v';
SELECT 'TABLES|' || count(*) FROM pg_tables WHERE schemaname = 'public';
SELECT 'PENDING_ARMS|' || (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), '''V[0-9]+''::text AS value_code', 'g'));
-- tim@'s session: AP open items per supplier, and the reconciliations
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) IS NOT NULL AS as_tim;
SET LOCAL ROLE authenticated;
SELECT 'AP_OPEN|' || counterparty_kind || '|' || COALESCE((SELECT code FROM suppliers WHERE id = a.supplier_id), counterparty_name) || '|' || doc_kind
    || '|' || count(*) || '|open_base=' || sum(open_base) FROM ap_open_items a GROUP BY counterparty_kind, a.supplier_id, counterparty_name, doc_kind ORDER BY 1;
SELECT 'AP_OPEN_TOTAL|' || count(*) || '|' || COALESCE(sum(open_base), 0) FROM ap_open_items;
SELECT 'RECON|' || (s ->> 'side') || '|list=' || (s ->> 'list_base') || '|ledger=' || (s ->> 'ledger_base') || '|unexplained=' || (s ->> 'unexplained_base')
  FROM jsonb_array_elements(list_ledger_reconciliation() -> 'sides') s;
SELECT 'INVCTL|' || (s ->> 'side') || '|ledger=' || (s ->> 'ledger_base') || '|subledger=' || (s ->> 'subledger_base') || '|unexplained='
    || COALESCE(s ->> 'unexplained_base', 'NULL') || '|reconciled=' || COALESCE(s ->> 'reconciled', 'NULL')
  FROM jsonb_array_elements(gl_control_reconciliation(CURRENT_DATE) -> 'sides') s WHERE s ->> 'side' LIKE 'inventory%';
RESET ROLE;
ROLLBACK;
