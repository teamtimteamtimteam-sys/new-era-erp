-- db/scripts/2026-09-24-role1b2b-readings.sql
-- ROLE-1 · Batch 2b · 前后读数(只读;整支一笔事务,最后 ROLLBACK)。与 Batch 2a 那一支同形,加上本刀的对象。
--
-- 身份写在每一段的开头(AGENTS.md「一个 0 行的读数,先问它是谁读的」):
--   第一部分:以 postgres 连接,rolbypassrls = t,读的全部是【基表】(relkind = 'r',第一段自证);
--   第二部分:以 tim@(634c00f9…,cfo)的 JWT、SET LOCAL ROLE authenticated 读【视图】
--     (ap_open_items / ar_open_items 与 list_ledger_reconciliation() 的谓词问的是"你是谁" ——
--      以 postgres 读它们是 0 行,那不是测量);
--   第三部分:每一个真账号的 current_user_permissions(),各自以那个账号的 JWT 读。
-- 角色持有一律读【未撤销】的授权(ur.revoked_at IS NULL)。
\pset footer off
BEGIN;
SELECT '== part 1 · postgres · base tables' AS section;
SELECT current_user AS identity, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user) AS bypassrls, now() AS read_at;
SELECT string_agg(relname || '=' || relkind::text, ' ' ORDER BY relname) AS relkinds
  FROM pg_class WHERE relnamespace = 'public'::regnamespace
   AND relname IN ('finance_settings','expense_claims','leave_requests','medical_claims','performance_reviews',
                   'work_orders','stocktakes','purchase_orders','approval_log','journal_entries','journal_lines',
                   'accounts','role_permissions','roles','user_roles','payment_requests','contracts',
                   'contract_grade_specs','metal_prices','metal_price_indices','index_market_calendar',
                   'pricing_settings','pricing_formulas','sales_records','assay_results',
                   'ap_open_items','ar_open_items');
SELECT approvals_enabled, approval_level1_role_code AS l1, approval_level2_role_code AS l2,
       approval_threshold_base AS threshold, locked_before FROM finance_settings;
SELECT (SELECT count(*) FROM expense_claims WHERE status = 'submitted') AS claims_submitted,
       (SELECT count(*) FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL) AS leave_pending,
       (SELECT count(*) FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL) AS medical_submitted,
       (SELECT count(*) FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL) AS medical_approved_unpaid,
       (SELECT count(*) FROM performance_reviews WHERE status = 'submitted') AS reviews_submitted,
       (SELECT count(*) FROM work_orders WHERE status = 'draft') AS work_orders_draft,
       (SELECT count(*) FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL) AS stocktakes_open,
       (SELECT count(*) FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL) AS po_pending,
       (SELECT count(*) FROM payment_requests WHERE status IN ('submitted','approved')) AS payment_requests_open;
SELECT (SELECT count(*) FROM approval_log) AS approval_log_rows,
       (SELECT count(*) FROM journal_entries) AS journal_entries;
SELECT (SELECT count(*) FROM contracts) AS contracts,
       (SELECT count(*) FROM contract_grade_specs) + (SELECT count(*) FROM contract_insurance_obligations)
     + (SELECT count(*) FROM contract_penalty_elements) + (SELECT count(*) FROM contract_pricing_terms)
     + (SELECT count(*) FROM contract_refining_charges) + (SELECT count(*) FROM contract_settlement_terms)
     + (SELECT count(*) FROM contract_volume_commitments) AS term_rows,
       (SELECT count(*) FROM metal_prices) AS metal_prices, (SELECT count(*) FROM metal_price_indices) AS indices,
       (SELECT count(*) FROM index_market_calendar) AS calendar, (SELECT count(*) FROM pricing_formulas) AS formulas,
       (SELECT count(*) FROM sales_records) AS sales_records,
       (SELECT count(*) FROM assay_results WHERE applied_at IS NOT NULL AND deleted_at IS NULL) AS assays_applied;
SELECT a.code, round(COALESCE(sum(l.debit - l.credit), 0), 2) AS balance_debit_positive
  FROM accounts a LEFT JOIN journal_lines l ON l.account_id = a.id
 WHERE a.code IN ('1100', '2000') GROUP BY a.code ORDER BY a.code;
SELECT r.code AS role, count(rp.permission_code) AS n
  FROM roles r LEFT JOIN role_permissions rp ON rp.role_id = r.id GROUP BY r.code ORDER BY r.code;
SELECT rp.permission_code, string_agg(r.code, ' ' ORDER BY r.code) AS held_by
  FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
 WHERE rp.permission_code IN ('action.contract_terms','action.metal_prices','action.direct_sale','action.apply_assay',
                              'action.finance_settings','action.customer_credit','action.supplier_approve',
                              'module.pricing.edit')
 GROUP BY 1 ORDER BY 1;
SELECT (SELECT count(*) FROM permissions) AS catalogue,
       (SELECT string_agg(p.code, ' ') FROM permissions p WHERE NOT EXISTS (
            SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
             WHERE r.code = 'admin' AND rp.permission_code = p.code)) AS admin_lacks;
SELECT u.email, string_agg(r.code, ' ') AS roles_unrevoked
  FROM user_roles ur JOIN roles r ON r.id = ur.role_id JOIN auth.users u ON u.id = ur.user_id
 WHERE ur.revoked_at IS NULL GROUP BY 1 ORDER BY 1;

SELECT '== part 2 · tim@ (634c00f9…, cfo) · authenticated · views' AS section;
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) IS NOT NULL AS claims_set;
SET LOCAL ROLE authenticated;
SELECT auth.uid() AS reader, current_user AS db_role;
SELECT count(*) AS ap_rows, sum(open_base) AS ap_open_base FROM ap_open_items;
SELECT count(*) AS ar_rows, sum(open_base) AS ar_open_base FROM ar_open_items;
SELECT side->>'side' AS side, side->>'list_base' AS list, side->>'ledger_base' AS ledger,
       side->>'unexplained_base' AS unexplained, side->>'agrees' AS agrees
  FROM jsonb_array_elements(list_ledger_reconciliation()->'sides') side;
RESET ROLE;

SELECT '== part 3 · current_user_permissions() per real account, each as itself' AS section;
CREATE FUNCTION pg_temp.codes_of(p_email text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v uuid; v_n int; v_new text;
BEGIN
    SELECT id INTO v FROM auth.users WHERE email = p_email;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
    SELECT count(*), string_agg(c, ',' ORDER BY c) FILTER (WHERE c IN ('action.contract_terms','action.metal_prices',
                   'action.direct_sale','action.apply_assay','module.pricing.edit',
                   'action.finance_settings','action.customer_credit','action.supplier_approve'))
      INTO v_n, v_new FROM unnest(current_user_permissions()) c;
    RETURN v_n || ' codes · of interest: ' || COALESCE(v_new, '-');
END $$;
SELECT email, pg_temp.codes_of(email) FROM auth.users
 WHERE email IN ('admin@swm-os.test','tim@evoltrya.test','chooer@evoltrya.test','sandra@evoltrya.test',
                 'phua@evolytra.test','fusheng@evoltrya.test','vince@evoltrya.test') ORDER BY email;
ROLLBACK;
