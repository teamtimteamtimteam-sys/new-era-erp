-- MES-6a-1 opening reading (2026-10-09) — read-only, BEGIN READ ONLY … ROLLBACK.
-- Identity: postgres (rolbypassrls = true) on base tables (relkind 'r'), so counts are real row counts, not a permission answer.
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f db/scripts/2026-10-09-mes6a1-opening-readings.sql
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';

-- 1 · assays by batch side, by party, by applied / superseded state
SELECT 'ASSAYS|all=' || count(*) || '|live=' || count(*) FILTER (WHERE deleted_at IS NULL)
    || '|inbound=' || count(*) FILTER (WHERE inbound_batch_id IS NOT NULL)
    || '|output=' || count(*) FILTER (WHERE output_batch_id IS NOT NULL)
    || '|applied=' || count(*) FILTER (WHERE applied_at IS NOT NULL)
    || '|superseded=' || count(*) FILTER (WHERE superseded_by IS NOT NULL)
    || '|final=' || count(*) FILTER (WHERE is_final)
    || '|sample_ref_set=' || count(*) FILTER (WHERE btrim(COALESCE(sample_ref, '')) <> '') FROM assay_results;
SELECT 'ASSAY_BY|' || side || '|party=' || result_party || '|applied=' || applied || '|superseded=' || superseded || '|deleted=' || deleted
    || '|n=' || count(*)
  FROM (SELECT CASE WHEN inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END AS side, result_party,
               (applied_at IS NOT NULL) AS applied, (superseded_by IS NOT NULL) AS superseded, (deleted_at IS NOT NULL) AS deleted
          FROM assay_results) a
 GROUP BY side, result_party, applied, superseded, deleted ORDER BY 1;
SELECT 'ASSAY|' || code || '|' || CASE WHEN inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END || '|' || result_party
    || '|applied=' || (applied_at IS NOT NULL) || '|superseded=' || (superseded_by IS NOT NULL) || '|final=' || is_final
  FROM assay_results ORDER BY code;

-- 2 · laboratories
SELECT 'LAB|' || code || '|active=' || is_active || '|name=' || COALESCE(name_en, '') FROM laboratories ORDER BY code;

-- 3 · contracts, and settlement terms by side
SELECT 'CONTRACTS|all=' || count(*) || '|live=' || count(*) FILTER (WHERE deleted_at IS NULL)
    || '|sell=' || count(*) FILTER (WHERE side = 'sell') || '|buy=' || count(*) FILTER (WHERE side = 'buy') FROM contracts;
SELECT 'TERMS|side=' || COALESCE(c.side, '?') || '|rows=' || count(t.id)
    || '|splitting_limit_set=' || count(t.id) FILTER (WHERE t.splitting_limit_pct IS NOT NULL)
    || '|retention_days_set=' || count(t.id) FILTER (WHERE t.sample_retention_days IS NOT NULL)
  FROM contract_settlement_terms t JOIN contracts c ON c.id = t.contract_id GROUP BY c.side ORDER BY 1;
SELECT 'TERMS_TOTAL|' || count(*) FROM contract_settlement_terms;

-- 4 · open price requests sourced from assays (and all requests by source / status)
SELECT 'PRICE_REQ|source=' || source || '|status=' || status || '|n=' || count(*) FROM receipt_price_requests GROUP BY source, status ORDER BY 1;
SELECT 'PRICE_REQ_OPEN_ASSAY|' || count(*) FROM receipt_price_requests WHERE source = 'assay' AND status = 'submitted';

-- 5 · expenses by state (with reversals)
SELECT 'EXPENSES|all=' || count(*) || '|posted=' || count(*) FILTER (WHERE status = 'posted')
    || '|reversed=' || count(*) FILTER (WHERE status = 'reversed')
    || '|mirrors=' || count(*) FILTER (WHERE reversed_by_expense IS NOT NULL)
    || '|other=' || count(*) FILTER (WHERE status NOT IN ('posted', 'reversed')) FROM expenses;
SELECT 'EXPENSE_STATUS|' || status || '|payment=' || COALESCE(payment_status, 'NULL') || '|n=' || count(*) FROM expenses GROUP BY status, payment_status ORDER BY 1;
SELECT 'ELEC_REVERSALS|' || count(*) FROM electricity_allocation_reversals;

-- 6 · every role's codes; catalogue size; admin's gap
SELECT 'CATALOGUE|' || count(*) || '|action=' || count(*) FILTER (WHERE code LIKE 'action.%')
    || '|quality=' || count(*) FILTER (WHERE code LIKE '%quality%') FROM permissions;
SELECT 'ROLE|' || r.code || '|codes=' || count(rp.permission_code) || '|holders=' ||
       COALESCE((SELECT string_agg(u.email, ',' ORDER BY u.email) FROM user_roles ur JOIN auth.users u ON u.id = ur.user_id
                  WHERE ur.role_id = r.id AND ur.revoked_at IS NULL), '-')
  FROM roles r LEFT JOIN role_permissions rp ON rp.role_id = r.id GROUP BY r.id, r.code ORDER BY r.code;
SELECT 'ADMIN_MISSING|' || COALESCE(string_agg(p.code, ','), '(none)') FROM permissions p
 WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'admin' AND rp.permission_code = p.code);
SELECT 'ROLECODES|' || r.code || '|' || string_agg(rp.permission_code, ',' ORDER BY rp.permission_code)
  FROM roles r JOIN role_permissions rp ON rp.role_id = r.id GROUP BY r.code ORDER BY r.code;

-- 7 · standing state
SELECT 'STATE|approvals_on=' || (SELECT approvals_enabled FROM finance_settings)
    || '|l1=' || (SELECT COALESCE(approval_level1_role_code, '?') FROM finance_settings)
    || '|l2=' || (SELECT COALESCE(approval_level2_role_code, '?') FROM finance_settings)
    || '|threshold=' || (SELECT COALESCE(approval_threshold_base::text, '?') FROM finance_settings)
    || '|accounts=' || (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local')
    || '|disabled=' || (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local' AND banned_until > now())
    || '|throwaway=' || (SELECT count(*) FROM auth.users WHERE email LIKE '%@test.local')
    || '|require_calibrated_since=' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings LIMIT 1), 'NULL')
    || '|change_log=' || (SELECT count(*) FROM change_log) || '|max_seq=' || (SELECT max(seq) FROM change_log)
    || '|notifications=' || (SELECT count(*) FROM notifications);
SELECT 'PENDING|' || count(*) || '|' || COALESCE(string_agg(to_jsonb(d)::text, ' ; '), '') FROM approval_pending_documents() d;
SELECT 'DOCTYPES|' || count(*) || '|SMP=' || count(*) FILTER (WHERE prefix = 'SMP') FROM document_types;
ROLLBACK;
