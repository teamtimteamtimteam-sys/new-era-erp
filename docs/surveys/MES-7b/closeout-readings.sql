-- MES-7a-2 close-out (MES-7b Step 0 brief, step 1) — live readings. Read-only (BEGIN READ ONLY … ROLLBACK) as postgres (rolbypassrls = true),
-- base tables and the catalog; the two reconciliations in tim@'s session switched to authenticated (both functions filter by the reader's codes).
-- MES-7a-2's window opened 2026-10-16 12:30:24 CST (= 04:30:24 UTC); the push that moved origin/main to c5d4cf67 was 13:24:18 CST (05:24:18 UTC);
-- this session's first command 13:31:34 CST (05:31:34 UTC). The page probe of item b ran 13:36:40–13:38:39 CST (its throwaways are read back here).
-- ★ The change log records writes that happened; a write the database refused leaves no row anywhere.
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/MES-7b/closeout-readings.sql
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
-- what MES-7a-2 created, and what landed on it inside the window
SELECT 'ACCT6800|' || code || '|' || name_en || '|' || name_zh || '|' || account_type || '|system=' || is_system || '|active=' || is_active FROM accounts WHERE code = '6800';
SELECT 'W|part issues=' || (SELECT count(*) FROM maintenance_part_issues)
    || '|maintenance movements=' || (SELECT count(*) FROM inventory_movements WHERE movement_type IN ('maintenance_issue', 'maintenance_return'))
    || '|maintenance_part entries=' || (SELECT count(*) FROM journal_entries WHERE source_type = 'maintenance_part')
    || '|6800 lines=' || (SELECT count(*) FROM journal_lines l JOIN accounts a ON a.id = l.account_id WHERE a.code = '6800')
    || '|spare-part materials=' || (SELECT count(*) FROM materials WHERE kind_code = 'spare_part' AND deleted_at IS NULL)
    || '|spare-part batches=' || (SELECT count(*) FROM inbound_batches b JOIN materials m ON m.id = b.material_id WHERE m.kind_code = 'spare_part')
    || '|movements in window=' || (SELECT count(*) FROM inventory_movements WHERE created_at >= '2026-10-16 04:30:24+00')
    || '|maintenance rows=' || (SELECT count(*) FROM equipment_maintenance)
    || '|maintenance changed in window=' || (SELECT count(*) FROM equipment_maintenance WHERE created_at >= '2026-10-16 04:30:24+00' OR updated_at >= '2026-10-16 04:30:24+00');
-- F12: the live spare_part note today (RUNTIME CONFIG; the mirror carries the new wording)
SELECT 'NOTE|spare_part|' || COALESCE(notes, 'NULL') FROM material_kinds WHERE code = 'spare_part';
SELECT 'CL|' || w || '|' || table_name || '/' || op || '=' || count(*)
  FROM (SELECT CASE WHEN occurred_at < '2026-10-16 05:24:18+00' THEN 'a: window → push'
                    WHEN occurred_at < '2026-10-16 05:31:34+00' THEN 'b: push → this session'
                    ELSE 'c: this session (page probe)' END AS w, table_name, op
          FROM change_log WHERE occurred_at >= '2026-10-16 04:30:24+00') x
 GROUP BY w, table_name, op ORDER BY w, table_name, op;
SELECT 'CLT|' || w || '|first=' || to_char(min(occurred_at) AT TIME ZONE 'Asia/Singapore', 'HH24:MI:SS') || '|last='
    || to_char(max(occurred_at) AT TIME ZONE 'Asia/Singapore', 'HH24:MI:SS') || '|rows=' || count(*)
  FROM (SELECT CASE WHEN occurred_at < '2026-10-16 05:24:18+00' THEN 'a' WHEN occurred_at < '2026-10-16 05:31:34+00' THEN 'b' ELSE 'c' END AS w, occurred_at
          FROM change_log WHERE occurred_at >= '2026-10-16 04:30:24+00') x GROUP BY w ORDER BY w;
-- standing state
SELECT 'COD|' || c.code || '|' || c.status || '|recorded sha256=' || COALESCE(i.sha256, '-')
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
SELECT 'CATALOGUE|' || count(*) FROM permissions;
SELECT 'HOLDERS|' || p.code || '=' || COALESCE(string_agg(r.code, ',' ORDER BY r.code), '')
  FROM permissions p LEFT JOIN role_permissions rp ON rp.permission_code = p.code LEFT JOIN roles r ON r.id = rp.role_id
 WHERE p.code IN ('module.inventory.edit', 'action.issue_coa', 'action.ncr_decide') GROUP BY p.code ORDER BY p.code;
SELECT 'CALIB|require_calibrated_since=' || COALESCE(require_calibrated_since::text, 'NULL') FROM ingest_settings;
SELECT 'THROWAWAY|accounts=' || (SELECT count(*) FROM auth.users WHERE email LIKE '%@test.local')
    || '|probe roles=' || (SELECT count(*) FROM roles WHERE code LIKE 'probe-%');
SELECT 'PENDING|' || count(*) || '|' || COALESCE(string_agg(to_jsonb(d)::text, ' ; '), '') FROM approval_pending_documents() d;
SELECT 'CHANGELOG|rows=' || count(*) || '|max seq=' || max(seq) FROM change_log;
SELECT 'TABLES|' || count(*) FROM pg_tables WHERE schemaname = 'public';
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) IS NOT NULL AS as_tim;
SET LOCAL ROLE authenticated;
SELECT 'RECON|' || (s ->> 'side') || '|list=' || (s ->> 'list_base') || '|ledger=' || (s ->> 'ledger_base') || '|unexplained=' || (s ->> 'unexplained_base')
  FROM jsonb_array_elements(list_ledger_reconciliation() -> 'sides') s;
SELECT 'INVCTL|' || (s ->> 'side') || '|ledger=' || (s ->> 'ledger_base') || '|subledger=' || (s ->> 'subledger_base') || '|unexplained='
    || COALESCE(s ->> 'unexplained_base', 'NULL') || '|reconciled=' || COALESCE(s ->> 'reconciled', 'NULL')
  FROM jsonb_array_elements(gl_control_reconciliation(CURRENT_DATE) -> 'sides') s WHERE s ->> 'side' LIKE 'inventory%';
RESET ROLE;
ROLLBACK;
