-- db/scripts/2026-09-25-apr5b-readings.sql
-- APR-5b · 前后读数(只读;整支一笔事务,最后 ROLLBACK)。与 APR-5a 那一支同形,换成本刀的对象:
-- 销售订单按状态、活预留、冻结的客户、发货 / 发货行 / 发货单档、shipping_releases(迁移之前不存在)、
-- 三张发货表的读策略、ship_order / record_shipment_issue 的门、两个新码的持有人。
-- 本刀新增两个码,所以码表要证明【之前 + 裁定的四行,别无其他】(cco · admin 拿 request_shipping_release;
-- warehouse · admin 拿 ship_goods)。
--
-- 身份写在每一段的开头(AGENTS.md「一个 0 行的读数,先问它是谁读的」):
--   第一部分:以 postgres 连接,rolbypassrls = t,读的全部是【基表】与目录(relkind 第一段自证);
--     invoice_requests 在迁移之前不存在 —— 用 to_regclass 读它,不存在就印 NULL,不报错;
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
   AND relname IN ('invoices','invoice_lines','credit_notes','credit_note_lines','shipments','shipment_lines','sales_orders',
                   'sales_records','invoice_requests','finance_settings','expense_claims','leave_requests','medical_claims',
                   'performance_reviews','work_orders','stocktakes','purchase_orders','approval_log','journal_entries',
                   'journal_lines','accounts','role_permissions','roles','user_roles','payment_requests','payroll_requests',
                   'receipt_price_requests','permissions','ap_open_items','ar_open_items');
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
       (SELECT count(*) FROM payment_requests WHERE status IN ('submitted','approved')) AS payment_requests_open,
       (SELECT count(*) FROM payroll_requests WHERE status IN ('submitted','approved')) AS payroll_requests_open,
       (SELECT count(*) FROM receipt_price_requests WHERE status = 'submitted') AS receipt_price_requests_pending;
-- shipping_releases:迁移之前不存在(NULL = 表不在),之后是行数与在等的张数
SELECT CASE WHEN to_regclass('public.shipping_releases') IS NULL THEN NULL
            ELSE (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM public.shipping_releases', false, true, '')))[1]::text
       END AS shipping_releases_rows,
       CASE WHEN to_regclass('public.shipping_releases') IS NULL THEN NULL
            ELSE (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM public.shipping_releases WHERE status = ''submitted''', false, true, '')))[1]::text
       END AS shipping_releases_pending,
       (SELECT count(*) FROM invoice_requests WHERE status = 'submitted') AS invoice_requests_pending;
SELECT kind, status, count(*) AS invoices, round(sum(total_base), 2) AS total_base FROM invoices GROUP BY 1, 2 ORDER BY 1, 2;
SELECT (SELECT count(*) FROM invoice_lines) AS invoice_lines,
       (SELECT count(*) FROM invoice_lines WHERE invoice_voided) AS invoice_lines_voided,
       (SELECT count(*) FROM credit_notes) AS credit_notes,
       (SELECT count(*) FROM credit_note_lines) AS credit_note_lines,
       (SELECT count(*) FROM shipments) AS shipments,
       (SELECT count(*) FROM shipment_lines) AS shipment_lines,
       (SELECT count(*) FROM shipment_issues) AS shipment_issues,
       (SELECT count(*) FROM sales_records) AS sales_records,
       (SELECT count(*) FROM sales_order_reservations WHERE released_at IS NULL AND consumed_at IS NULL) AS reservations_live,
       (SELECT count(*) FROM customers WHERE credit_hold AND deleted_at IS NULL) AS customers_on_hold;
SELECT status, count(*) FILTER (WHERE deleted_at IS NULL) AS sales_orders_live FROM sales_orders GROUP BY 1 ORDER BY 1;
SELECT (SELECT count(*) FROM approval_log) AS approval_log_rows,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_entries WHERE source_type IN ('invoice', 'credit_note')) AS invoice_cn_entries;
-- 应收、库存(1200 进料 · 1210 在制 · 1220 产出)与相关科目(借减贷,本位币;全部行,不按 posted 过滤 —— AGENTS.md)
SELECT a.code, round(COALESCE(sum(l.debit - l.credit), 0), 2) AS balance_debit_positive
  FROM accounts a LEFT JOIN journal_lines l ON l.account_id = a.id
 WHERE a.code IN ('1100', '1200', '1210', '1220', '2000', '2100', '2500', '4000', '5000', '5200') GROUP BY a.code ORDER BY a.code;
-- 三张发货表的读策略(本刀放宽到 module.sales.view 或 action.ship_goods)与两扇门的码
SELECT tablename, cmd, qual FROM pg_policies
 WHERE schemaname = 'public' AND tablename IN ('shipments', 'shipment_lines', 'shipment_issues') ORDER BY 1, 2;
SELECT p.proname, substring(p.prosrc from 'require_permission\(''([a-z_.]+)''\)') AS gate
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
   AND p.proname IN ('ship_order', 'record_shipment_issue', 'release_reservation', 'reserve_stock') ORDER BY 1;
SELECT (SELECT count(*) FROM permissions) AS catalogue;
SELECT p.code, string_agg(r.code, ' ' ORDER BY r.code) AS holders
  FROM permissions p LEFT JOIN role_permissions rp ON rp.permission_code = p.code LEFT JOIN roles r ON r.id = rp.role_id
 WHERE p.code IN ('module.finance.edit', 'module.finance.view', 'data.view_prices', 'module.sales.edit', 'module.sales.view',
                  'action.request_shipping_release', 'action.ship_goods')
 GROUP BY p.code ORDER BY p.code;
SELECT r.code AS role, count(rp.permission_code) AS n,
       md5(COALESCE(string_agg(rp.permission_code, ',' ORDER BY rp.permission_code), '')) AS codes_md5
  FROM roles r LEFT JOIN role_permissions rp ON rp.role_id = r.id GROUP BY r.code ORDER BY r.code;
SELECT r.code AS role, string_agg(rp.permission_code, ' ' ORDER BY rp.permission_code) AS codes
  FROM roles r JOIN role_permissions rp ON rp.role_id = r.id GROUP BY r.code ORDER BY r.code;
SELECT u.email, string_agg(r.code, ' ') AS roles_unrevoked
  FROM user_roles ur JOIN roles r ON r.id = ur.role_id JOIN auth.users u ON u.id = ur.user_id
 WHERE ur.revoked_at IS NULL GROUP BY 1 ORDER BY 1;
-- 在途清单(DEFINER 函数,以 postgres 调;它不问"你是谁")
SELECT subject_type, count(*) AS pending, round(sum(amount_base), 2) AS amount_base,
       count(*) FILTER (WHERE blocks_disable) AS blocks_disable
  FROM approval_pending_documents() GROUP BY 1 ORDER BY 1;

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
DECLARE v uuid; v_n int; v_md5 text;
BEGIN
    SELECT id INTO v FROM auth.users WHERE email = p_email;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
    SELECT count(*), md5(string_agg(c, ',' ORDER BY c)) INTO v_n, v_md5 FROM unnest(current_user_permissions()) c;
    RETURN v_n || ' codes · md5 ' || v_md5;
END $$;
SELECT email, pg_temp.codes_of(email) FROM auth.users
 WHERE email IN ('admin@swm-os.test','tim@evoltrya.test','chooer@evoltrya.test','sandra@evoltrya.test',
                 'phua@evolytra.test','fusheng@evoltrya.test','vince@evoltrya.test') ORDER BY email;
ROLLBACK;
