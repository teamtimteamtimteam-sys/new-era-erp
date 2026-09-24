-- db/scripts/2026-09-24-role1b2a-readings.sql
-- ROLE-1 · Batch 2a · 前后读数(只读;整支一笔事务,最后 ROLLBACK)。
--
-- 身份写在每一段的开头(AGENTS.md「一个 0 行的读数,先问它是谁读的」):
--   第一部分:以 postgres 连接,rolbypassrls = t,读的全部是【基表】(relkind = 'r',第一段自证);
--   第二部分:以 tim@(634c00f9…,cfo)的 JWT、SET LOCAL ROLE authenticated 读【视图】
--     (ap_open_items / ar_open_items 与 list_ledger_reconciliation() 的谓词问的是"你是谁" ——
--      以 postgres 读它们是 0 行,那不是测量);
--   第三部分:每一个真账号的 current_user_permissions(),各自以那个账号的 JWT 读。
\pset footer off
BEGIN;
SELECT '== part 1 · postgres · base tables' AS section;
SELECT current_user AS identity, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user) AS bypassrls, now() AS read_at;
SELECT string_agg(relname || '=' || relkind::text, ' ' ORDER BY relname) AS relkinds
  FROM pg_class WHERE relnamespace = 'public'::regnamespace
   AND relname IN ('finance_settings','expense_claims','leave_requests','medical_claims','performance_reviews',
                   'work_orders','stocktakes','purchase_orders','approval_log','journal_entries','journal_lines',
                   'accounts','role_permissions','roles','payment_requests','suppliers','customers','company_profile',
                   'ap_open_items','ar_open_items');
SELECT approvals_enabled, approval_level1_role_code AS l1, approval_level2_role_code AS l2,
       approval_threshold_base AS threshold, locked_before, gst_registered, gst_registration_no,
       fy_end_month, fy_end_day, default_allocation_basis FROM finance_settings;
SELECT (SELECT count(*) FROM expense_claims WHERE status = 'submitted') AS claims_submitted,
       (SELECT count(*) FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL) AS leave_pending,
       (SELECT count(*) FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL) AS medical_submitted,
       (SELECT count(*) FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL) AS medical_approved_unpaid,
       (SELECT count(*) FROM performance_reviews WHERE status = 'submitted') AS reviews_submitted,
       (SELECT count(*) FROM work_orders WHERE status = 'draft') AS work_orders_draft,
       (SELECT count(*) FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL) AS stocktakes_open,
       (SELECT count(*) FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL) AS po_pending,
       (SELECT count(*) FROM payment_requests WHERE status IN ('submitted','approved')) AS payment_requests_open,
       (SELECT count(*) FROM payment_requests) AS payment_requests_all;
SELECT (SELECT count(*) FROM approval_log) AS approval_log_rows,
       (SELECT count(*) FROM journal_entries) AS journal_entries;
SELECT status::text, count(*) FILTER (WHERE deleted_at IS NULL) AS live, count(*) FILTER (WHERE deleted_at IS NOT NULL) AS deleted
  FROM suppliers GROUP BY 1 ORDER BY 1;
SELECT count(*) FILTER (WHERE credit_limit_base IS NOT NULL) AS customers_with_limit,
       count(*) FILTER (WHERE credit_hold) AS customers_on_hold FROM customers WHERE deleted_at IS NULL;
SELECT a.code, round(COALESCE(sum(l.debit - l.credit), 0), 2) AS balance_debit_positive
  FROM accounts a LEFT JOIN journal_lines l ON l.account_id = a.id
 WHERE a.code IN ('1100', '2000') GROUP BY a.code ORDER BY a.code;
SELECT r.code AS role, count(rp.permission_code) AS n
  FROM roles r LEFT JOIN role_permissions rp ON rp.role_id = r.id GROUP BY r.code ORDER BY r.code;
SELECT r.code AS role, string_agg(rp.permission_code, ' ' ORDER BY rp.permission_code) AS codes
  FROM roles r JOIN role_permissions rp ON rp.role_id = r.id
 WHERE r.code IN ('cfo', 'warehouse') GROUP BY r.code ORDER BY r.code;

SELECT '== part 2 · tim@ (634c00f9…, cfo) · authenticated · views' AS section;
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) IS NOT NULL AS claims_set;
SET LOCAL ROLE authenticated;
SELECT auth.uid() AS reader, current_user AS db_role;
SELECT count(*) AS ap_rows, sum(open_base) AS ap_open_base FROM ap_open_items;
SELECT count(*) AS ar_rows, sum(open_base) AS ar_open_base FROM ar_open_items;
SELECT CASE WHEN s.id IS NULL THEN '(not a supplier)'
            WHEN s.deleted_at IS NOT NULL THEN 'deleted'
            ELSE s.status::text END AS supplier_state,
       count(*) AS items, sum(a.open_base) AS open_base
  FROM ap_open_items a LEFT JOIN suppliers s ON s.id = a.supplier_id GROUP BY 1 ORDER BY 1;
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
    SELECT count(*), string_agg(c, ',' ORDER BY c) FILTER (WHERE c IN ('action.finance_settings','action.customer_credit',
                   'action.supplier_approve','module.suppliers.view','module.suppliers.edit'))
      INTO v_n, v_new FROM unnest(current_user_permissions()) c;
    RETURN v_n || ' codes · of interest: ' || COALESCE(v_new, '-');
END $$;
SELECT email, pg_temp.codes_of(email) FROM auth.users
 WHERE email IN ('admin@swm-os.test','tim@evoltrya.test','chooer@evoltrya.test','sandra@evoltrya.test',
                 'phua@evolytra.test','fusheng@evoltrya.test','vince@evoltrya.test') ORDER BY email;
ROLLBACK;
