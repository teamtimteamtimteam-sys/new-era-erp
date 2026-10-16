-- MES-7a-2 — opening and closing live readings (2026-10-16), read-only: BEGIN READ ONLY … ROLLBACK.
-- Identity: postgres (rolbypassrls = true) on base tables (relkind 'r') and the catalog, so counts are real row counts, not a permission answer.
-- The reconciliations (AP / AR list = ledger; inventory control 1200 / 1220) resolve the reader's codes, and postgres carries no JWT — so they are
-- read in the same transaction as tim@ (634c00f9…, role cfo), switched to `authenticated` with that sub (read only, no write possible).
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/MES-7a-2/opening-readings.sql
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
-- chart of accounts around 6800, and every system account
SELECT 'ACCT6|' || code || '|' || name_en || '|' || account_type || '|system=' || is_system || '|active=' || COALESCE(is_active::text, '-')
  FROM accounts WHERE code BETWEEN '6000' AND '6999' ORDER BY code;
SELECT 'ACCT6800|' || CASE WHEN EXISTS (SELECT 1 FROM accounts WHERE code = '6800') THEN 'PRESENT' ELSE 'absent' END
    || '|named like repair=' || (SELECT count(*) FROM accounts WHERE name_en ILIKE '%repair%' OR name_en ILIKE '%maint%' OR name_zh LIKE '%维修%');
SELECT 'SYSTEM|' || count(*) || '|' || string_agg(code, ',' ORDER BY code) FROM accounts WHERE is_system;
SELECT 'ACCOUNTS|' || count(*) FROM accounts;
-- spare-part materials and their batches
SELECT 'KINDS|' || string_agg(COALESCE(kind_code, '<none>') || '=' || n, ' ' ORDER BY kind_code)
  FROM (SELECT kind_code, count(*) n FROM materials WHERE deleted_at IS NULL GROUP BY kind_code) x;
SELECT 'SPARE_MATERIALS|' || count(*) || '|safety stock set=' || count(*) FILTER (WHERE safety_stock_qty IS NOT NULL)
  FROM materials WHERE kind_code = 'spare_part';
SELECT 'SPARE_BATCHES|' || count(*) FROM inbound_batches b JOIN materials m ON m.id = b.material_id WHERE m.kind_code = 'spare_part';
SELECT 'KIND_NOTE|spare_part|' || left(COALESCE(notes, ''), 120) FROM material_kinds WHERE code = 'spare_part';
-- maintenance records
SELECT 'MAINT|' || a.code || '|' || m.performed_on || '|' || m.kind || '|capitalised=' || m.capitalised
    || '|capitalised_expense=' || (m.capitalised_expense_id IS NOT NULL) || '|row=' || md5(to_jsonb(m)::text)
  FROM equipment_maintenance m JOIN fixed_assets a ON a.id = m.equipment_id ORDER BY m.performed_on;
-- movement types: the CHECK and live counts
SELECT 'MVCHECK|' || conname || '|' || left(pg_get_constraintdef(oid), 400) FROM pg_constraint
 WHERE conrelid = 'public.inventory_movements'::regclass AND contype = 'c' ORDER BY conname;
SELECT 'MVTYPES|' || string_agg(movement_type || '=' || n, ' ' ORDER BY movement_type)
  FROM (SELECT movement_type, count(*) n FROM inventory_movements GROUP BY movement_type) x;
SELECT 'MOVEMENTS|' || count(*) || '|max created=' || to_char(max(created_at) AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI') FROM inventory_movements;
SELECT 'PARTS_TABLE|' || CASE WHEN to_regclass('public.maintenance_part_issues') IS NULL THEN 'absent' ELSE 'present' END;
-- ledger fingerprint and standing state
SELECT 'JOURNAL|entries=' || (SELECT count(*) FROM journal_entries) || '|lines=' || (SELECT count(*) FROM journal_lines)
    || '|md5 entries=' || (SELECT md5(string_agg(to_jsonb(e)::text, '' ORDER BY id)) FROM journal_entries e);
SELECT 'BATCHES|' || count(*) || '|md5=' || md5(string_agg(to_jsonb(b)::text, '' ORDER BY id)) FROM inbound_batches b;
SELECT 'MATERIALS|' || count(*) || '|md5=' || md5(string_agg(to_jsonb(m)::text, '' ORDER BY id)) FROM materials m;
SELECT 'COD|' || c.code || '|' || c.status || '|recorded sha256=' || COALESCE(i.sha256, '-') || '|snapshot md5=' || COALESCE(md5(c.snapshot::text), '-')
  FROM certificates_of_destruction c LEFT JOIN cod_issues i ON i.cod_id = c.id WHERE c.status = 'issued' ORDER BY c.code;
SELECT 'COD_BUCKET|objects=' || count(*) || '|' || COALESCE(string_agg(name || ':' || COALESCE(metadata ->> 'size', '?'), ',' ORDER BY name), '')
  FROM storage.objects WHERE bucket_id = 'cod-documents';
SELECT 'APPROVALS|enabled=' || approvals_enabled || '|l1=' || COALESCE(approval_level1_role_code, '-') || '|l2=' || COALESCE(approval_level2_role_code, '-')
    || '|threshold=' || COALESCE(approval_threshold_base::text, '-') FROM finance_settings;
SELECT 'ACCOUNTS_LOGIN|all=' || count(*) || '|disabled=' || count(*) FILTER (WHERE banned_until > now()) FROM auth.users WHERE email NOT LIKE '%@test.local';
SELECT 'ACCOUNT|' || u.email || '|' || string_agg(r.code, ',' ORDER BY r.code) FROM auth.users u
  JOIN user_roles ur ON ur.user_id = u.id AND ur.revoked_at IS NULL JOIN roles r ON r.id = ur.role_id
 WHERE u.email NOT LIKE '%@test.local' GROUP BY u.email ORDER BY u.email;
SELECT 'ROLECODES|' || string_agg(r.code || '=' || n, ' ' ORDER BY r.code)
  FROM (SELECT role_id, count(*) n FROM role_permissions GROUP BY role_id) x JOIN roles r ON r.id = x.role_id;
SELECT 'HOLDERS|' || p.code || '=' || COALESCE(string_agg(r.code, ',' ORDER BY r.code), '')
  FROM permissions p LEFT JOIN role_permissions rp ON rp.permission_code = p.code LEFT JOIN roles r ON r.id = rp.role_id
 WHERE p.code IN ('module.inventory.edit', 'module.materials.view', 'action.issue_coa', 'action.ncr_decide') GROUP BY p.code ORDER BY p.code;
SELECT 'CALIB|require_calibrated_since=' || COALESCE(require_calibrated_since::text, 'NULL') FROM ingest_settings;
SELECT 'THROWAWAY|accounts=' || (SELECT count(*) FROM auth.users WHERE email LIKE '%@test.local')
    || '|probe roles=' || (SELECT count(*) FROM roles WHERE code LIKE 'probe-%');
SELECT 'PENDING|' || count(*) || '|' || COALESCE(string_agg(to_jsonb(d)::text, ' ; '), '') FROM approval_pending_documents() d;
SELECT 'CHANGELOG|rows=' || count(*) || '|max seq=' || max(seq) FROM change_log;
SELECT 'TABLES|' || count(*) FROM pg_tables WHERE schemaname = 'public';
-- reconciliations in tim@'s session
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) IS NOT NULL AS as_tim;
SET LOCAL ROLE authenticated;
SELECT 'RECON|' || (s ->> 'side') || '|list=' || (s ->> 'list_base') || '|ledger=' || (s ->> 'ledger_base') || '|unexplained=' || (s ->> 'unexplained_base')
  FROM jsonb_array_elements(list_ledger_reconciliation() -> 'sides') s;
SELECT 'INVCTL|' || (s ->> 'side') || '|ledger=' || (s ->> 'ledger_base') || '|subledger=' || (s ->> 'subledger_base') || '|unexplained='
    || COALESCE(s ->> 'unexplained_base', 'NULL') || '|reconciled=' || COALESCE(s ->> 'reconciled', 'NULL')
  FROM jsonb_array_elements(gl_control_reconciliation(CURRENT_DATE) -> 'sides') s WHERE s ->> 'side' LIKE 'inventory%';
RESET ROLE;
ROLLBACK;
