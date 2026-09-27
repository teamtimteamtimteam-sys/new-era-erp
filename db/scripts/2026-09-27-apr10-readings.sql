-- db/scripts/2026-09-27-apr10-readings.sql
-- APR-10 · 前后读数(只读;整支一笔事务,最后 ROLLBACK)。与 APR-9 那一支同形,换成本刀的对象:
-- gst_filing_requests(迁移之前不存在 —— 读成 NULL)、GST 期间与快照、1400 / 2100、采购单(品类列迁移之前不存在)、
-- 三个开单码的持有人、六支守卫、新门与内层算子对 authenticated 的 EXECUTE、四张采购表上的写策略。
-- 本刀【新增三个码】(每一个也给 admin)并给 warehouse 加 module.purchasing.view,所以 admin / cco / finance / warehouse
-- 的码表与 md5 前后【应当】不同,其余角色逐字相同。
--
-- 身份写在每一段的开头(AGENTS.md「一个 0 行的读数,先问它是谁读的」):
--   第一部分:以 postgres 连接,rolbypassrls = t,读的全部是【基表】与目录(relkind 第一段自证);
--   第二部分:以 tim@(634c00f9…,cfo)的 JWT、SET LOCAL ROLE authenticated 读【视图】
--     (ap_open_items / ar_open_items 与 list_ledger_reconciliation() 的谓词问的是"你是谁");
--   第三部分:每一个真账号的 current_user_permissions(),各自以那个账号的 JWT 读。
-- 角色持有一律读【未撤销】的授权(ur.revoked_at IS NULL)。
\pset footer off
BEGIN;
SELECT '== part 1 · postgres · base tables' AS section;
SELECT current_user AS identity, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user) AS bypassrls, now() AS read_at;
SELECT string_agg(relname || '=' || relkind::text, ' ' ORDER BY relname) AS relkinds
  FROM pg_class WHERE relnamespace = 'public'::regnamespace
   AND relname IN ('gst_periods','gst_return_boxes','gst_filing_requests','purchase_orders','purchase_order_lines',
                   'purchase_order_payment_terms','purchase_order_line_retentions','journal_entries','journal_lines',
                   'accounts','approval_log','role_permissions','roles','user_roles','finance_settings','permissions',
                   'ap_open_items','ar_open_items');
SELECT approvals_enabled, approval_level1_role_code AS l1, approval_level2_role_code AS l2,
       approval_threshold_base AS threshold, locked_before FROM finance_settings;
-- 申请表:迁移之前不存在(NULL = 表不在),之后是行数与在等的张数
SELECT t AS request_table,
       CASE WHEN to_regclass('public.' || t) IS NULL THEN NULL
            ELSE (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM public.' || t, false, true, '')))[1]::text END AS rows,
       CASE WHEN to_regclass('public.' || t) IS NULL THEN NULL
            ELSE (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM public.' || t || ' WHERE status = ''submitted''', false, true, '')))[1]::text END AS pending
  FROM unnest(ARRAY['gst_filing_requests']) t;
-- GST 期间与快照(基表)
SELECT code, period_start, period_end, status, filed_on, filed_reference FROM gst_periods ORDER BY period_start, code;
SELECT count(*) AS gst_return_boxes FROM gst_return_boxes;
-- 采购单(基表):状态 × 审批 × 品类(品类列迁移之前不存在 —— 读成 '(no column)')
SELECT status, approval_status,
       CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                          AND table_name = 'purchase_orders' AND column_name = 'category')
            THEN 'see next line' ELSE '(no column)' END AS category_col, count(*)
  FROM purchase_orders WHERE deleted_at IS NULL GROUP BY 1, 2, 3 ORDER BY 1, 2;
SELECT CASE WHEN to_regclass('public.purchase_orders') IS NOT NULL
             AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                          AND table_name = 'purchase_orders' AND column_name = 'category')
            THEN (xpath('/row/c/text()', query_to_xml('SELECT string_agg(category || '':'' || n, '' '' ORDER BY category) AS c FROM (SELECT category, count(*) n FROM public.purchase_orders GROUP BY 1) x', false, true, '')))[1]::text
            END AS po_by_category;
SELECT md5(string_agg(code || ':' || status || ':' || approval_status || ':' || estimated_total_ccy::text || ':' || COALESCE(updated_at::text, '-'), ',' ORDER BY code)) AS po_digest,
       (SELECT count(*) FROM purchase_order_lines) AS po_lines, (SELECT count(*) FROM purchase_order_history) AS po_history
  FROM purchase_orders;
-- 守卫与写策略
SELECT count(*) AS apr10_guards FROM pg_trigger WHERE NOT tgisinternal
   AND tgname IN ('trg_gst_filing_lock', 'trg_purchase_orders_direct_write', 'trg_purchase_order_lines_direct_write',
                  'trg_purchase_order_payment_terms_direct_write', 'trg_purchase_order_line_retentions_direct_write',
                  'trg_purchase_order_lines_category');
SELECT tablename, count(*) AS write_policies FROM pg_policies
 WHERE schemaname = 'public' AND cmd <> 'SELECT'
   AND tablename IN ('gst_filing_requests', 'purchase_orders', 'purchase_order_lines', 'purchase_order_payment_terms',
                     'purchase_order_line_retentions')
 GROUP BY 1 ORDER BY 1;
-- 新门与内层算子对 authenticated 的 EXECUTE(迁移之前不存在的对象读成 NULL)
SELECT s AS fn, CASE WHEN to_regprocedure(s) IS NULL THEN NULL
                     ELSE has_function_privilege('authenticated', s::regprocedure, 'EXECUTE') END AS authenticated_can_execute
  FROM unnest(ARRAY['public.submit_gst_filing_request(uuid, text)', 'public.decide_gst_filing_request(uuid, boolean, text)',
                    'public.withdraw_gst_filing_request(uuid, text)', 'public.record_gst_filing(uuid, date, text)',
                    'public.file_gst_return(uuid, date, text)', 'public.gst_filing_execute_internal(uuid)',
                    'public.po_may_manage(uuid)', 'public.assert_po_manager(uuid)',
                    'public.create_purchase_order(uuid, date, date, text, numeric, text, text, text, jsonb, jsonb, text)',
                    'public.create_purchase_order(uuid, date, date, text, numeric, text, text, text, jsonb, jsonb, text, text)']) s;
SELECT (SELECT count(*) FROM approval_log) AS approval_log_rows,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total;
-- 银行 1000、应收 1100、存货 1200、应付 2000(借减贷,本位币;全部行,不按 posted 过滤 —— AGENTS.md)
SELECT a.code, round(COALESCE(sum(l.debit - l.credit), 0), 2) AS balance_debit_positive
  FROM accounts a LEFT JOIN journal_lines l ON l.account_id = a.id
 WHERE a.code IN ('1000', '1100', '1200', '1400', '2000', '2100') GROUP BY a.code ORDER BY a.code;
SELECT (SELECT count(*) FROM permissions) AS catalogue;
SELECT p.code, string_agg(r.code, ' ' ORDER BY r.code) AS holders
  FROM permissions p LEFT JOIN role_permissions rp ON rp.permission_code = p.code LEFT JOIN roles r ON r.id = rp.role_id
 WHERE p.code IN ('module.purchasing.edit', 'module.purchasing.view', 'data.view_purchase_prices',
                  'action.raise_po_consumables', 'action.raise_po_equipment', 'action.raise_po_office',
                  'module.finance.edit', 'module.finance.view', 'data.view_prices')
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
