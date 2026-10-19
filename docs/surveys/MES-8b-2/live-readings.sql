-- MES-8b-2 — opening and closing live readings (2026-10-17), read-only: BEGIN READ ONLY … ROLLBACK.
-- Identity: postgres (rolbypassrls = true) on base tables (relkind 'r') and the catalog, so counts are real row counts, not a permission answer
-- (AGENTS.md「一个『0 行』的读数,先问它是谁读的」). Three reads run in a session instead, because they resolve the reader's codes and postgres
-- carries no JWT: inventory_metal_exposure() as admin@ (321f1819…, role admin — the F18 before/after) and the two reconciliations as tim@
-- (634c00f9…, role cfo), each switched to `authenticated`.
-- Copied from docs/surveys/MES-8b-1/live-readings.sql (its standing-state, fingerprint and reconciliation blocks unchanged); the head is this cut's.
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/MES-8b-2/live-readings.sql
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
-- F18: materials and the stock on hand by whether the material's kind is stated (and whether it may be processed)
SELECT 'MATERIALS|' || count(*) || '|no_kind=' || count(*) FILTER (WHERE kind_code IS NULL) || '|deleted=' || count(*) FILTER (WHERE deleted_at IS NOT NULL) FROM materials;
SELECT 'KINDS|' || string_agg(code || ':' || may_ever_be_processed, ',' ORDER BY code) FROM material_kinds;
SELECT 'ON_HAND_BY_KIND|' || x.kind || '|' || x.kstate || '|batches=' || count(*) || '|kg=' || COALESCE(sum(x.qty) FILTER (WHERE x.unit = 'kg'), 0)
    || '|not_kg=' || count(*) FILTER (WHERE x.unit <> 'kg') || '|with_payable_content=' || count(*) FILTER (WHERE x.has_content)
  FROM (SELECT 'inbound' AS kind, b.unit, sum(mv.qty_delta) AS qty,
               CASE WHEN m.kind_code IS NULL THEN 'kind_not_stated' WHEN k.may_ever_be_processed THEN 'processable' ELSE 'not_processable' END AS kstate,
               EXISTS (SELECT 1 FROM inbound_batch_metals c JOIN substances s ON s.code = c.metal AND s.role = 'payable_metal' WHERE c.inbound_batch_id = b.id) AS has_content
          FROM inventory_movements mv JOIN inbound_batches b ON b.id = mv.inbound_batch_id JOIN materials m ON m.id = b.material_id
          LEFT JOIN material_kinds k ON k.code = m.kind_code WHERE b.deleted_at IS NULL GROUP BY b.id, b.unit, m.kind_code, k.may_ever_be_processed
        UNION ALL
        SELECT 'output', b.unit, sum(mv.qty_delta),
               CASE WHEN m.kind_code IS NULL THEN 'kind_not_stated' WHEN k.may_ever_be_processed THEN 'processable' ELSE 'not_processable' END,
               EXISTS (SELECT 1 FROM output_batch_metals c JOIN substances s ON s.code = c.metal AND s.role = 'payable_metal' WHERE c.output_batch_id = b.id)
          FROM inventory_movements mv JOIN output_batches b ON b.id = mv.output_batch_id JOIN materials m ON m.id = b.material_id
          LEFT JOIN material_kinds k ON k.code = m.kind_code WHERE b.deleted_at IS NULL GROUP BY b.id, b.unit, m.kind_code, k.may_ever_be_processed) x
 WHERE x.qty > 0 GROUP BY x.kind, x.kstate ORDER BY x.kind, x.kstate;
SELECT 'PRICE_LATEST|' || p.metal || '|' || p.price_date || '|' || p.price_usd_per_tonne
  FROM metal_prices p WHERE p.deleted_at IS NULL AND p.price_date = (SELECT max(q.price_date) FROM metal_prices q WHERE q.metal = p.metal AND q.deleted_at IS NULL AND q.price_date <= CURRENT_DATE)
 ORDER BY p.metal;
-- the wall display: role, code, settings, pending arm — all absent before the migration
SELECT 'FLOOR|role=' || (SELECT count(*) FROM roles WHERE code = 'floor_display') || '|code=' || (SELECT count(*) FROM permissions WHERE code = 'data.view_floor_board')
    || '|holders=' || COALESCE((SELECT string_agg(r.code, ',' ORDER BY r.code) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE rp.permission_code = 'data.view_floor_board'), 'none')
    || '|floor_accounts=' || (SELECT count(*) FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE r.code = 'floor_display' AND ur.revoked_at IS NULL)
    || '|settings_table=' || COALESCE(to_regclass('public.floor_board_settings')::text, 'absent')
    || '|arms_view=' || COALESCE(to_regclass('public.operations_arms_all')::text, 'absent')
    || '|floor_board=' || COALESCE(to_regprocedure('public.floor_board()')::text, 'absent');
SELECT 'CATALOGUE|' || count(*) || '|module=' || count(*) FILTER (WHERE code LIKE 'module.%') || '|action=' || count(*) FILTER (WHERE code LIKE 'action.%')
    || '|data=' || count(*) FILTER (WHERE code LIKE 'data.%') FROM permissions;
SELECT 'ROLES|' || string_agg(code || '=' || CASE WHEN is_active THEN 'active' ELSE 'inactive' END || CASE WHEN is_system THEN '/system' ELSE '' END, ',' ORDER BY code) FROM roles WHERE deleted_at IS NULL;
SELECT 'DOCTYPES|' || count(*) FROM document_types;
SELECT 'PERIODS|locked_before=' || COALESCE(locked_before::text, 'NULL') || '|system_start_date=' || COALESCE(system_start_date::text, 'NULL') FROM finance_settings;
-- standing state
SELECT 'APPROVALS|enabled=' || approvals_enabled || '|l1=' || COALESCE(approval_level1_role_code, '-') || '|l2=' || COALESCE(approval_level2_role_code, '-')
    || '|threshold=' || COALESCE(approval_threshold_base::text, '-') FROM finance_settings;
SELECT 'ACCOUNTS_LOGIN|all=' || count(*) || '|disabled=' || count(*) FILTER (WHERE banned_until > now()) FROM auth.users WHERE email NOT LIKE '%@test.local';
SELECT 'ACCOUNT|' || u.email || '|' || string_agg(r.code, ',' ORDER BY r.code) FROM auth.users u
  JOIN user_roles ur ON ur.user_id = u.id AND ur.revoked_at IS NULL JOIN roles r ON r.id = ur.role_id
 WHERE u.email NOT LIKE '%@test.local' GROUP BY u.email ORDER BY u.email;
SELECT 'ROLECODES|' || string_agg(r.code || '=' || n, ' ' ORDER BY r.code)
  FROM (SELECT role_id, count(*) n FROM role_permissions GROUP BY role_id) x JOIN roles r ON r.id = x.role_id;
SELECT 'ROLEPERMS_MD5_EXCL_FLOOR|' || md5(string_agg(r.code || ':' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code))
  FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE rp.permission_code <> 'data.view_floor_board' AND r.code <> 'floor_display';
SELECT 'CALIB|require_calibrated_since=' || COALESCE(require_calibrated_since::text, 'NULL') FROM ingest_settings;
SELECT 'THROWAWAY|accounts=' || (SELECT count(*) FROM auth.users WHERE email LIKE '%@test.local')
    || '|probe roles=' || (SELECT count(*) FROM roles WHERE code LIKE 'probe-%' OR code LIKE 'mes8b2probe%');
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
    ('material_kinds', (SELECT count(*) FROM material_kinds), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM material_kinds x)),
    ('roles', (SELECT count(*) FROM roles), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM roles x WHERE code <> 'floor_display')),
    ('user_roles', (SELECT count(*) FROM user_roles), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM user_roles x)),
    ('compliance_packs', (SELECT count(*) FROM compliance_packs), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM compliance_packs x)),
    ('pending_documents', (SELECT count(*) FROM approval_pending_documents()), (SELECT md5(COALESCE(string_agg(to_jsonb(x)::text, '' ORDER BY to_jsonb(x)::text), '')) FROM approval_pending_documents() x)),
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
-- admin@'s session: F18 — inventory_metal_exposure() as the page reads it
SELECT set_config('request.jwt.claims', '{"sub":"321f1819-8449-48f7-9ae0-78b2c4b50f35","role":"authenticated"}', true) IS NOT NULL AS as_admin;
SET LOCAL ROLE authenticated;
SELECT 'EXPO|value_usd_priced=' || (e ->> 'value_usd_priced') || '|complete=' || (e ->> 'complete') || '|not_measured=' || jsonb_array_length(e -> 'not_measured')
    || '|not_measured_kg=' || (e ->> 'not_measured_kg') || '|unit_not_kg=' || jsonb_array_length(e -> 'unit_not_kg')
    || '|kind_not_stated=' || COALESCE(jsonb_array_length(e -> 'kind_not_stated')::text, 'absent') || '|kind_not_stated_kg=' || COALESCE(e ->> 'kind_not_stated_kg', 'absent')
  FROM (SELECT inventory_metal_exposure() AS e) x;
SELECT 'EXPO_METAL|' || (l ->> 'metal') || '|' || (l ->> 'state') || '|kg=' || (l ->> 'material_kg') || '|metal_kg=' || (l ->> 'metal_kg') || '|value=' || COALESCE(l ->> 'value_usd', 'NULL')
  FROM jsonb_array_elements(inventory_metal_exposure() -> 'metals') l;
SELECT 'EXPO_KNS|' || (k ->> 'kind') || '|' || (k ->> 'code') || '|' || COALESCE(k ->> 'kg', k ->> 'qty' || ' ' || (k ->> 'unit'))
  FROM jsonb_array_elements(COALESCE(inventory_metal_exposure() -> 'kind_not_stated', '[]'::jsonb)) k;
RESET ROLE;
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
