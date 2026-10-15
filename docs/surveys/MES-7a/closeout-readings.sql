-- MES-6b-2 close-out + MES-7a Step 0 opening reading (2026-10-15) — read-only, BEGIN READ ONLY … ROLLBACK.
-- Identity: postgres (rolbypassrls = true) on base tables (relkind 'r') and the catalog, so counts are real row counts, not a permission answer.
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/MES-7a/closeout-readings.sql
-- Item c (MES6B2-ISSUED-WITHOUT-BYTES): every live account holding action.issue_coa through an unrevoked role grant, the person it resolves to
-- (account_person: the primary account first, then employee_accounts — the same resolution issue_coa uses through current_user_employee), and the
-- name and position issue_coa would print: COALESCE(NULLIF(btrim(preferred_name), ''), legal_name) and NULLIF(btrim(positions.title), '')
-- (db/functions/issue_coa.sql:44-47). The glyph check against the PDF font stack is done outside SQL, on the ISSUER| lines.
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';

-- c · who can issue a CoA today, and what the certificate would print for them
SELECT 'ISSUER|' || u.email || '|role=' || r.code
    || '|employee=' || COALESCE(e.code, '-')
    || '|name=' || COALESCE(COALESCE(NULLIF(btrim(e.preferred_name), ''), e.legal_name), '<no employee>')
    || '|position=' || COALESCE(NULLIF(btrim(p.title), ''), '<none>')
  FROM auth.users u
  JOIN user_roles ur ON ur.user_id = u.id AND ur.revoked_at IS NULL
  JOIN roles r ON r.id = ur.role_id
  JOIN role_permissions rp ON rp.role_id = r.id AND rp.permission_code = 'action.issue_coa'
  LEFT JOIN employees e ON e.id = account_person(u.id)
  LEFT JOIN positions p ON p.id = e.position_id
 ORDER BY u.email, r.code;
SELECT 'ISSUE_COA_ROLES|' || COALESCE(string_agg(r.code, ',' ORDER BY r.code), '') FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
 WHERE rp.permission_code = 'action.issue_coa';

-- standing state (the brief's live-state claims, re-measured)
SELECT 'APPROVALS|enabled=' || approvals_enabled || '|l1=' || COALESCE(approval_level1_role_code, '-') || '|l2=' || COALESCE(approval_level2_role_code, '-')
    || '|threshold=' || COALESCE(approval_threshold_base::text, '-') FROM finance_settings;
SELECT 'ACCOUNTS|all=' || count(*) || '|disabled=' || count(*) FILTER (WHERE banned_until > now()) || '|deleted=' || count(*) FILTER (WHERE deleted_at IS NOT NULL)
  FROM auth.users WHERE email NOT LIKE '%@test.local';
SELECT 'ACCOUNT|' || u.email || '|banned_until=' || COALESCE(u.banned_until::text, '-') || '|' || string_agg(r.code, ',' ORDER BY r.code) FROM auth.users u
  JOIN user_roles ur ON ur.user_id = u.id AND ur.revoked_at IS NULL JOIN roles r ON r.id = ur.role_id
 WHERE u.email NOT LIKE '%@test.local' GROUP BY u.email, u.banned_until ORDER BY u.email;
SELECT 'ROLECODES|' || string_agg(r.code || '=' || n, ' ' ORDER BY r.code)
  FROM (SELECT role_id, count(*) n FROM role_permissions GROUP BY role_id) x JOIN roles r ON r.id = x.role_id;
SELECT 'CATALOGUE|codes=' || (SELECT count(*) FROM permissions)
    || '|admin=' || (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'admin');
SELECT 'HOLDERS|' || p.code || '=' || COALESCE(string_agg(r.code, ',' ORDER BY r.code), '')
  FROM permissions p LEFT JOIN role_permissions rp ON rp.permission_code = p.code LEFT JOIN roles r ON r.id = rp.role_id
 WHERE p.code IN ('action.ncr_decide', 'action.issue_coa') GROUP BY p.code ORDER BY p.code;
SELECT 'CALIB|require_calibrated_since=' || COALESCE(require_calibrated_since::text, 'NULL') FROM ingest_settings;
SELECT 'MINE|contracts=' || (SELECT count(*) FROM contracts) || '|quality_limits=' || (SELECT count(*) FROM contract_quality_limits)
    || '|ncrs=' || (SELECT count(*) FROM nonconformance_reports) || '|coas=' || (SELECT count(*) FROM certificates_of_analysis)
    || '|coa_issues=' || (SELECT count(*) FROM coa_issues)
    || '|coa_void_requests=' || (SELECT count(*) FROM warehouse_requests WHERE kind = 'coa_void');
SELECT 'COA_BUCKET|objects=' || count(*) FROM storage.objects WHERE bucket_id = 'coa-documents';
SELECT 'OUTPUT|not deleted=' || (SELECT count(*) FROM output_batches WHERE deleted_at IS NULL)
    || '|output assays=' || (SELECT count(*) FROM assay_results WHERE output_batch_id IS NOT NULL)
    || '|output final assays=' || (SELECT count(*) FROM assay_results WHERE output_batch_id IS NOT NULL AND is_final AND deleted_at IS NULL);
SELECT 'CODS|all=' || (SELECT count(*) FROM certificates_of_destruction) || '|issued=' || (SELECT count(*) FROM certificates_of_destruction WHERE status = 'issued')
    || '|cod_issues=' || (SELECT count(*) FROM cod_issues);
SELECT 'THROWAWAY|accounts=' || (SELECT count(*) FROM auth.users WHERE email LIKE '%@test.local')
    || '|probe roles=' || (SELECT count(*) FROM roles WHERE code LIKE 'probe-%');
SELECT 'PENDING|' || count(*) || '|' || COALESCE(string_agg(to_jsonb(d)::text, ' ; '), '') FROM approval_pending_documents() d;
SELECT 'CHANGELOG|rows=' || count(*) || '|max seq=' || max(seq) FROM change_log;
ROLLBACK;
