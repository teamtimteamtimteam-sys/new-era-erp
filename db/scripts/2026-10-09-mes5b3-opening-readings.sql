-- MES-5b-3 opening reading (2026-10-09) — read-only, BEGIN READ ONLY … ROLLBACK.
-- Identity: postgres (rolbypassrls = true) on base tables (relkind 'r'), so counts are real row counts, not a permission answer.
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';

-- 1 · assays
SELECT 'ASSAYS|all=' || count(*) || '|inbound=' || count(*) FILTER (WHERE inbound_batch_id IS NOT NULL)
    || '|output=' || count(*) FILTER (WHERE output_batch_id IS NOT NULL) FROM assay_results;
SELECT 'ASSAY_METAL_ROWS|' || count(*) FROM assay_result_metals;

-- 2 · batches with metal content (by source)
SELECT 'IB_METALS|batches=' || count(DISTINCT inbound_batch_id) || '|rows=' || count(*)
    || '|assay=' || count(*) FILTER (WHERE content_source = 'assay') || '|manual=' || count(*) FILTER (WHERE content_source = 'manual')
    || '|unknown=' || count(*) FILTER (WHERE content_source IS NULL) FROM inbound_batch_metals;
SELECT 'OB_METALS|batches=' || count(DISTINCT output_batch_id) || '|rows=' || count(*)
    || '|assay=' || count(*) FILTER (WHERE content_source = 'assay') || '|manual=' || count(*) FILTER (WHERE content_source = 'manual')
  FROM output_batch_metals;

-- 3 · contract grade specs
SELECT 'GRADE_SPECS|' || count(*) || '|contracts=' || count(DISTINCT contract_id) FROM contract_grade_specs;

-- 4 · batches whose material form is a saleable powder (black_mass · cathode_powder · anode_powder; may_be_sold read from data)
SELECT 'FORMS|' || code || '|may_be_sold=' || may_be_sold || '|active=' || is_active FROM material_forms
 WHERE code IN ('black_mass', 'cathode_powder', 'anode_powder') ORDER BY code;
SELECT 'POWDER_IB|' || f.code || '|batches=' || count(b.id) || '|live=' || count(b.id) FILTER (WHERE b.deleted_at IS NULL)
    || '|with_metals=' || count(b.id) FILTER (WHERE EXISTS (SELECT 1 FROM inbound_batch_metals x WHERE x.inbound_batch_id = b.id))
  FROM material_forms f LEFT JOIN materials m ON m.form_code = f.code LEFT JOIN inbound_batches b ON b.material_id = m.id
 WHERE f.code IN ('black_mass', 'cathode_powder', 'anode_powder') GROUP BY f.code ORDER BY f.code;
SELECT 'POWDER_OB|' || f.code || '|batches=' || count(b.id) || '|live=' || count(b.id) FILTER (WHERE b.deleted_at IS NULL)
    || '|with_metals=' || count(b.id) FILTER (WHERE EXISTS (SELECT 1 FROM output_batch_metals x WHERE x.output_batch_id = b.id))
  FROM material_forms f LEFT JOIN materials m ON m.form_code = f.code LEFT JOIN output_batches b ON b.material_id = m.id
 WHERE f.code IN ('black_mass', 'cathode_powder', 'anode_powder') GROUP BY f.code ORDER BY f.code;
SELECT 'POWDER_MATERIALS|' || m.code || '|' || m.form_code || '|deleted=' || (m.deleted_at IS NOT NULL) FROM materials m
 WHERE m.form_code IN ('black_mass', 'cathode_powder', 'anode_powder') ORDER BY m.code;

-- 5 · work-order / blending permission holders (live holders only: revoked_at IS NULL, an auth.users row)
SELECT 'HOLDERS|' || rp.permission_code || '|' || string_agg(DISTINCT r.code || ':' || COALESCE(u.email, '(no holder)'), ', ')
  FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
  LEFT JOIN user_roles ur ON ur.role_id = r.id AND ur.revoked_at IS NULL
  LEFT JOIN auth.users u ON u.id = ur.user_id
 WHERE rp.permission_code IN ('action.wo_create', 'action.wo_release', 'action.processing_commit', 'module.processing.view',
                              'module.inbound.view', 'module.output.view', 'module.tasks.view_all')
 GROUP BY rp.permission_code ORDER BY rp.permission_code;

-- 6 · every role's codes; catalogue size; admin's gap
SELECT 'CATALOGUE|' || count(*) || '|action=' || count(*) FILTER (WHERE code LIKE 'action.%') FROM permissions;
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
    || '|accounts=' || (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local')
    || '|disabled=' || (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local' AND banned_until > now())
    || '|throwaway=' || (SELECT count(*) FROM auth.users WHERE email LIKE '%@test.local')
    || '|require_calibrated_since=' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings LIMIT 1), 'NULL')
    || '|change_log=' || (SELECT count(*) FROM change_log) || '|max_seq=' || (SELECT max(seq) FROM change_log)
    || '|notifications=' || (SELECT count(*) FROM notifications)
    || '|runs=' || (SELECT count(*) FROM processing_runs) || '|work_orders=' || (SELECT count(*) FROM work_orders);
SELECT 'PENDING|' || count(*) || '|' || COALESCE(string_agg(to_jsonb(d)::text, ' ; '), '') FROM approval_pending_documents() d;
SELECT 'OPS|' || code || '|' || kind_code || '|from_run_page=' || started_from_run_page FROM operation_types ORDER BY sort_order;
SELECT 'DOCTYPES|' || count(*) FROM document_types;
ROLLBACK;
