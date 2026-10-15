-- MES-6b-1 opening reading (2026-10-15) — read-only, BEGIN READ ONLY … ROLLBACK.
-- Identity: postgres (rolbypassrls = true) on base tables (relkind 'r'), so counts are real row counts, not a permission answer.
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f db/scripts/2026-10-15-mes6b1-opening-readings.sql
-- The reconciliation is read separately in tim@'s session: db/scripts/2026-10-05-at1d3-live-recon.sql.
-- Re-run unchanged as the "after" reading.
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';

-- 1 · contracts by side and status
SELECT 'CONTRACTS|all=' || count(*) || '|not deleted=' || count(*) FILTER (WHERE deleted_at IS NULL) FROM contracts;
SELECT 'CONTRACT|' || side || '|' || status || '|' || count(*) FROM contracts WHERE deleted_at IS NULL GROUP BY side, status ORDER BY side, status;
SELECT 'TERMS|settlement=' || (SELECT count(*) FROM contract_settlement_terms) || '|pricing=' || (SELECT count(*) FROM contract_pricing_terms)
    || '|penalty=' || (SELECT count(*) FROM contract_penalty_elements) || '|grade specs=' || (SELECT count(*) FROM contract_grade_specs)
    || '|quality limits table=' || (to_regclass('public.contract_quality_limits') IS NOT NULL);

-- 2 · assays
SELECT 'ASSAYS|all=' || count(*) || '|live=' || count(*) FILTER (WHERE deleted_at IS NULL)
    || '|inbound=' || count(*) FILTER (WHERE inbound_batch_id IS NOT NULL) || '|output=' || count(*) FILTER (WHERE output_batch_id IS NOT NULL)
    || '|output live=' || count(*) FILTER (WHERE output_batch_id IS NOT NULL AND deleted_at IS NULL)
    || '|with moisture=' || count(*) FILTER (WHERE moisture_pct IS NOT NULL) FROM assay_results;
SELECT 'ASSAY_LINES|metals=' || (SELECT count(*) FROM assay_result_metals) || '|indicators=' || (SELECT count(*) FROM assay_result_indicators);

-- 3 · reservations, held stock, disputes, blending
SELECT 'RESERVATIONS|all=' || count(*) || '|open=' || count(*) FILTER (WHERE released_at IS NULL AND consumed_at IS NULL)
    || '|released=' || count(*) FILTER (WHERE released_at IS NOT NULL) || '|consumed=' || count(*) FILTER (WHERE consumed_at IS NOT NULL)
  FROM sales_order_reservations;
SELECT 'ON_HOLD|movement rows=' || count(*) || '|net qty=' || COALESCE(sum(qty_delta), 0)
    || '|batches with net on_hold > 0=' || (SELECT count(*) FROM (SELECT COALESCE(inbound_batch_id, output_batch_id) b, sum(qty_delta) q FROM inventory_movements
                                            WHERE stock_status = 'on_hold' GROUP BY 1 HAVING sum(qty_delta) > 0) x)
  FROM inventory_movements WHERE stock_status = 'on_hold';
SELECT 'COMMITTED|movement rows=' || count(*) || '|net qty=' || COALESCE(sum(qty_delta), 0) FROM inventory_movements WHERE stock_status = 'committed';
SELECT 'DISPUTES|all=' || count(*) || '|open=' || count(*) FILTER (WHERE status = 'open') FROM assay_disputes;
SELECT 'BLENDING|' || COALESCE(string_agg(status || '=' || n, ',' ORDER BY status), 'none') FROM (SELECT status, count(*) n FROM blending_plans GROUP BY 1) x;
SELECT 'WAREHOUSE_REQUESTS|open=' || count(*) FILTER (WHERE status = 'submitted') || '|all=' || count(*) FROM warehouse_requests;

-- 4 · NCR registry state and the new code
SELECT 'NCR|table=' || (to_regclass('public.nonconformance_reports') IS NOT NULL)
    || '|code action.ncr_decide=' || (SELECT count(*) FROM permissions WHERE code = 'action.ncr_decide')
    || '|document type NCR=' || (SELECT count(*) FROM document_types WHERE prefix = 'NCR');
SELECT 'NCR_DECIDE_ROLES|' || COALESCE(string_agg(r.code, ',' ORDER BY r.code), 'none') FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
 WHERE rp.permission_code = 'action.ncr_decide';
SELECT 'QUALITY_EDIT_ROLES|' || COALESCE(string_agg(r.code, ',' ORDER BY r.code), 'none') FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
 WHERE rp.permission_code = 'module.quality.edit';

-- 5 · standing state
SELECT 'S|approvals_on=' || approvals_enabled || '|l1=' || COALESCE(approval_level1_role_code, '?') || '|l2=' || COALESCE(approval_level2_role_code, '?')
    || '|threshold=' || COALESCE(approval_threshold_base::text, '?') FROM finance_settings;
SELECT 'S|accounts=' || count(*) || '|disabled=' || count(*) FILTER (WHERE banned_until > now()) || '|deleted=' || count(*) FILTER (WHERE deleted_at IS NOT NULL)
  FROM auth.users WHERE email NOT LIKE '%@test.local';
SELECT 'S|account|' || u.email || '|banned_until=' || COALESCE(u.banned_until::text, '-') || '|' || string_agg(r.code, ',' ORDER BY r.code) FROM auth.users u
  JOIN user_roles ur ON ur.user_id = u.id AND ur.revoked_at IS NULL JOIN roles r ON r.id = ur.role_id
 WHERE u.email NOT LIKE '%@test.local' GROUP BY u.email, u.banned_until ORDER BY u.email;
SELECT 'S|role codes|' || string_agg(r.code || '=' || (SELECT count(*) FROM role_permissions rp WHERE rp.role_id = r.id), ',' ORDER BY r.code) FROM roles r;
SELECT 'S|throwaway accounts=' || count(*) FROM auth.users WHERE email LIKE '%@test.local';
SELECT 'S|require_calibrated_since=' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings LIMIT 1), 'NULL');
SELECT 'S|catalogue=' || (SELECT count(*) FROM permissions) || '|admin=' || (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'admin');
SELECT 'PENDING|' || count(*) || '|' || COALESCE(string_agg(to_jsonb(d)::text, ' ; '), '') FROM approval_pending_documents() d;
SELECT 'S|change_log rows=' || count(*) || '|max seq=' || max(seq) FROM change_log;
SELECT 'S|document_types=' || count(*) FROM document_types;
SELECT 'S|public base tables=' || count(*) FROM pg_tables WHERE schemaname = 'public';
ROLLBACK;
