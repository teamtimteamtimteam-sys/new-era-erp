-- db/scripts/2026-09-25-apr6-readings.sql
-- APR-6 · 前后读数(只读;整支一笔事务,最后 ROLLBACK)。与 APR-5b 那一支同形,换成本刀的对象:
-- 分录按 source_type、手工凭证是谁记的(职责分离那条规矩的读数)、journal_requests(迁移之前不存在)、
-- 两张分录表的策略与守卫、post_journal_entry 对 authenticated 的 EXECUTE、银行 1000 / 1010 与 2000 / 1100。
-- 本刀【不新增任何码】,所以每一个角色的码表与 md5 必须前后逐字相同。
--
-- 身份写在每一段的开头(AGENTS.md「一个 0 行的读数,先问它是谁读的」):
--   第一部分:以 postgres 连接,rolbypassrls = t,读的全部是【基表】与目录(relkind 第一段自证);
--     journal_requests 在迁移之前不存在 —— 用 to_regclass 读它,不存在就印 NULL,不报错;
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
                   'receipt_price_requests','permissions','ap_open_items','ar_open_items','journal_requests','shipping_releases');
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
SELECT (SELECT count(*) FROM invoice_requests WHERE status = 'submitted') AS invoice_requests_pending,
       (SELECT count(*) FROM shipping_releases WHERE status = 'submitted') AS shipping_releases_pending;
-- journal_requests:迁移之前不存在(NULL = 表不在),之后是行数与在等的张数
SELECT CASE WHEN to_regclass('public.journal_requests') IS NULL THEN NULL
            ELSE (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM public.journal_requests', false, true, '')))[1]::text
       END AS journal_requests_rows,
       CASE WHEN to_regclass('public.journal_requests') IS NULL THEN NULL
            ELSE (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM public.journal_requests WHERE status = ''submitted''', false, true, '')))[1]::text
       END AS journal_requests_pending;
-- 分录按 source_type(基表,全部行)
SELECT source_type, count(*) AS entries FROM journal_entries GROUP BY 1 ORDER BY 1;
-- 手工凭证是谁记的(职责分离那条规矩的读数;COALESCE 之前与之后都应当是 chooer@)
SELECT je.code, je.entry_date, u.email AS created_by FROM journal_entries je LEFT JOIN auth.users u ON u.id = je.created_by
 WHERE je.source_type = 'manual' ORDER BY je.code;
SELECT (SELECT string_agg(u.email, ' ' ORDER BY u.email) FROM unnest(sod_manual_posters_in(NULL, '9999-12-31'::date)) p(uid)
          JOIN auth.users u ON u.id = p.uid) AS sod_manual_posters_all_time;
-- 两张分录表的策略与守卫;过账核心对 authenticated 的 EXECUTE
SELECT tablename, cmd, policyname FROM pg_policies WHERE schemaname = 'public'
   AND tablename IN ('journal_entries', 'journal_lines') ORDER BY 1, 2;
SELECT tgname FROM pg_trigger WHERE tgname IN ('trg_journal_entries_direct_write', 'trg_journal_lines_direct_write') ORDER BY 1;
SELECT has_function_privilege('authenticated', 'public.post_journal_entry(date, text, text, uuid, jsonb)', 'EXECUTE') AS auth_can_post_journal_entry;
SELECT (SELECT count(*) FROM approval_log) AS approval_log_rows,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total;
-- 银行 1000 / 1010、应收 1100、应付 2000 与相关科目(借减贷,本位币;全部行,不按 posted 过滤 —— AGENTS.md)
SELECT a.code, round(COALESCE(sum(l.debit - l.credit), 0), 2) AS balance_debit_positive
  FROM accounts a LEFT JOIN journal_lines l ON l.account_id = a.id
 WHERE a.code IN ('1000', '1010', '1100', '1300', '2000', '6200', '6400') GROUP BY a.code ORDER BY a.code;
SELECT (SELECT count(*) FROM permissions) AS catalogue;
SELECT p.code, string_agg(r.code, ' ' ORDER BY r.code) AS holders
  FROM permissions p LEFT JOIN role_permissions rp ON rp.permission_code = p.code LEFT JOIN roles r ON r.id = rp.role_id
 WHERE p.code IN ('module.finance.edit', 'module.finance.view', 'data.view_prices')
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
