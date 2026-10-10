-- MES-6a-2 opening reading (2026-10-10) — read-only, BEGIN READ ONLY … ROLLBACK.
-- Identity: postgres (rolbypassrls = true) on base tables (relkind 'r'), so counts are real row counts, not a permission answer.
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f db/scripts/2026-10-10-mes6a2-opening-readings.sql
-- The reconciliation is read separately in tim@'s session: db/scripts/2026-10-05-at1d3-live-recon.sql.
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
SELECT 'RELKIND|' || string_agg(relname || '=' || relkind::text, ',' ORDER BY relname) FROM pg_class
 WHERE relnamespace = 'public'::regnamespace AND relname IN ('substances', 'metal_prices', 'pricing_formula_metals', 'pricing_formula_history',
       'pricing_term_commitment_metals', 'contract_pricing_terms', 'contract_refining_charges', 'contract_penalty_elements', 'contract_grade_specs',
       'assay_result_metals', 'inbound_batch_metals', 'output_batch_metals', 'material_required_metals', 'blending_plan_targets', 'contracts');

-- 1 · the dictionary, row by row
SELECT 'SUBSTANCE|' || code || '|' || name_en || '|' || name_zh || '|symbol=' || COALESCE(symbol, '-') || '|active=' || is_active
    || '|sort=' || sort_order || '|columns=' || (SELECT string_agg(attname, ',' ORDER BY attnum) FROM pg_attribute
                                               WHERE attrelid = 'public.substances'::regclass AND attnum > 0 AND NOT attisdropped)
  FROM substances ORDER BY sort_order, code;
SELECT 'SUBSTANCES|n=' || count(*) || '|f=' || count(*) FILTER (WHERE code = 'f') || '|cl=' || count(*) FILTER (WHERE code = 'cl') FROM substances;

-- 2 · where each substance is referenced (all thirteen FK columns), live rows
SELECT 'REF|' || s.code
    || '|metal_prices=' || (SELECT count(*) FROM metal_prices x WHERE x.metal = s.code)
    || '(live ' || (SELECT count(*) FROM metal_prices x WHERE x.metal = s.code AND x.deleted_at IS NULL) || ')'
    || '|formula_metals=' || (SELECT count(*) FROM pricing_formula_metals x WHERE x.metal = s.code)
    || '|formula_history=' || (SELECT count(*) FROM pricing_formula_history x WHERE x.metal = s.code)
    || '|commitment_metals=' || (SELECT count(*) FROM pricing_term_commitment_metals x WHERE x.metal = s.code)
    || '|contract_pricing_terms=' || (SELECT count(*) FROM contract_pricing_terms x WHERE x.metal = s.code)
    || '|contract_refining_charges=' || (SELECT count(*) FROM contract_refining_charges x WHERE x.metal = s.code)
    || '|contract_penalty_elements=' || (SELECT count(*) FROM contract_penalty_elements x WHERE x.substance = s.code)
    || '|contract_grade_specs=' || (SELECT count(*) FROM contract_grade_specs x WHERE x.metal = s.code)
    || '|assay_result_metals=' || (SELECT count(*) FROM assay_result_metals x WHERE x.metal = s.code)
    || '|inbound_batch_metals=' || (SELECT count(*) FROM inbound_batch_metals x WHERE x.metal = s.code)
    || '|output_batch_metals=' || (SELECT count(*) FROM output_batch_metals x WHERE x.metal = s.code)
    || '|material_required_metals=' || (SELECT count(*) FROM material_required_metals x WHERE x.metal = s.code)
    || '|blending_plan_targets=' || (SELECT count(*) FROM blending_plan_targets x WHERE x.metal = s.code)
  FROM substances s ORDER BY s.sort_order, s.code;

-- 3 · contracts, and those with penalty elements
SELECT 'CONTRACTS|all=' || count(*) || '|live=' || count(*) FILTER (WHERE deleted_at IS NULL)
    || '|sell=' || count(*) FILTER (WHERE customer_id IS NOT NULL) || '|buy=' || count(*) FILTER (WHERE supplier_id IS NOT NULL) FROM contracts;
SELECT 'PENALTY_CONTRACTS|n=' || count(DISTINCT contract_id) || '|rows=' || count(*) FROM contract_penalty_elements;
SELECT 'PENALTY|' || c.code || '|' || p.substance || '|threshold=' || p.threshold_pct || '|rate=' || p.usd_per_tonne_per_pct_over
  FROM contract_penalty_elements p JOIN contracts c ON c.id = p.contract_id ORDER BY c.code, p.substance;
SELECT 'SETTLEMENT_TERMS|n=' || count(*) || '|per_element=' || count(*) FILTER (WHERE penalty_basis = 'per_element') FROM contract_settlement_terms;

-- 4 · assays and indicators-adjacent state
SELECT 'ASSAYS|all=' || count(*) || '|live=' || count(*) FILTER (WHERE deleted_at IS NULL)
    || '|inbound=' || count(*) FILTER (WHERE inbound_batch_id IS NOT NULL) || '|output=' || count(*) FILTER (WHERE output_batch_id IS NOT NULL)
    || '|with moisture=' || count(*) FILTER (WHERE moisture_pct IS NOT NULL) FROM assay_results;
SELECT 'INDICATOR_TABLES|assay_indicators=' || (to_regclass('public.assay_indicators') IS NOT NULL)
    || '|assay_result_indicators=' || (to_regclass('public.assay_result_indicators') IS NOT NULL);
SELECT 'INLINE_QUALITY|' || COALESCE((SELECT row_to_json(x)::text FROM (SELECT code, target_en, transform_function, is_active FROM ingest_data_classes WHERE code = 'inline_quality') x), 'none');

-- 5 · standing state
SELECT 'S|approvals_on=' || approvals_enabled || '|l1=' || COALESCE(approval_level1_role_code, '?') || '|l2=' || COALESCE(approval_level2_role_code, '?')
    || '|threshold=' || COALESCE(approval_threshold_base::text, '?') FROM finance_settings;
SELECT 'S|accounts=' || count(*) || '|disabled=' || count(*) FILTER (WHERE banned_until > now()) FROM auth.users WHERE email NOT LIKE '%@test.local';
SELECT 'S|account|' || u.email || '|' || string_agg(r.code, ',' ORDER BY r.code) FROM auth.users u
  JOIN user_roles ur ON ur.user_id = u.id AND ur.revoked_at IS NULL JOIN roles r ON r.id = ur.role_id
 WHERE u.email NOT LIKE '%@test.local' GROUP BY u.email ORDER BY u.email;
SELECT 'S|throwaway accounts=' || count(*) FROM auth.users WHERE email LIKE '%@test.local';
SELECT 'S|require_calibrated_since=' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings LIMIT 1), 'NULL');
SELECT 'S|catalogue=' || (SELECT count(*) FROM permissions) || '|admin=' || (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'admin');
SELECT 'PENDING|' || count(*) || '|' || COALESCE(string_agg(to_jsonb(d)::text, ' ; '), '') FROM approval_pending_documents() d;
SELECT 'S|change_log rows=' || count(*) || '|max seq=' || max(seq) FROM change_log;
SELECT 'S|document_types=' || count(*) FROM document_types;
ROLLBACK;
