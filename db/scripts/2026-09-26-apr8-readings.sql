-- db/scripts/2026-09-26-apr8-readings.sql
-- APR-8 · 前后读数(只读;整支一笔事务,最后 ROLLBACK)。与 APR-7 那一支同形,换成本刀的对象:
-- terms_requests(迁移之前不存在)、公式 / 比例 / 公式历史 / 承诺 / 合同 / 条款 / 挂接的计数、
-- 公式两张表的写策略数、十支守卫、新门与内层算子对 authenticated 的 EXECUTE。
-- 本刀【不新增任何码】(grilling Q6),所以每一个角色的码表与 md5 必须前后逐字相同。
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
                   'receipt_price_requests','permissions','ap_open_items','ar_open_items','journal_requests','shipping_releases',
                   'warehouse_requests','terms_requests','pricing_formulas','pricing_formula_metals','pricing_formula_history',
                   'pricing_term_commitments','contracts','contract_pricing_terms','contract_document_terms');
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
SELECT (SELECT count(*) FROM journal_requests WHERE status = 'submitted') AS journal_requests_pending;
SELECT (SELECT count(*) FROM warehouse_requests WHERE status = 'submitted') AS warehouse_requests_pending;
-- terms_requests:迁移之前不存在(NULL = 表不在),之后是行数与在等的张数
SELECT CASE WHEN to_regclass('public.terms_requests') IS NULL THEN NULL
            ELSE (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM public.terms_requests', false, true, '')))[1]::text
       END AS terms_requests_rows,
       CASE WHEN to_regclass('public.terms_requests') IS NULL THEN NULL
            ELSE (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM public.terms_requests WHERE status = ''submitted''', false, true, '')))[1]::text
       END AS terms_requests_pending;
-- 分录按 source_type(基表,全部行)
SELECT source_type, count(*) AS entries FROM journal_entries GROUP BY 1 ORDER BY 1;
-- 公式、比例、历史、承诺、合同、条款、挂接(基表)
SELECT (SELECT count(*) FROM pricing_formulas) AS formulas,
       (SELECT count(*) FROM pricing_formulas WHERE is_active AND deleted_at IS NULL) AS formulas_in_use,
       (SELECT string_agg(code || ':' || CASE WHEN is_active THEN 'active' ELSE 'inactive' END, ' ' ORDER BY code)
          FROM pricing_formulas WHERE deleted_at IS NULL) AS formula_states,
       (SELECT count(*) FROM pricing_formula_metals) AS formula_metals,
       (SELECT count(*) FROM pricing_formula_history) AS formula_history,
       (SELECT count(*) FROM pricing_term_commitments) AS commitments;
SELECT (SELECT count(*) FROM contracts) AS contracts,
       (SELECT (SELECT count(*) FROM contract_grade_specs) + (SELECT count(*) FROM contract_insurance_obligations)
             + (SELECT count(*) FROM contract_volume_commitments) + (SELECT count(*) FROM contract_pricing_terms)
             + (SELECT count(*) FROM contract_settlement_terms) + (SELECT count(*) FROM contract_refining_charges)
             + (SELECT count(*) FROM contract_penalty_elements)) AS contract_term_rows,
       (SELECT count(*) FROM contract_document_terms) AS contract_links;
-- 公式两张表的写策略(迁移之前 6 条,之后 0 条);十支守卫
SELECT count(*) AS formula_write_policies FROM pg_policies
 WHERE schemaname = 'public' AND tablename IN ('pricing_formulas', 'pricing_formula_metals') AND cmd <> 'SELECT';
SELECT count(*) AS apr8_guards FROM pg_trigger WHERE NOT tgisinternal
   AND (tgname IN ('trg_pricing_formulas_direct_write', 'trg_pricing_formula_metals_direct_write', 'trg_contracts_guard_write')
        OR tgname LIKE 'trg_contract_%_frozen');
-- 新门与内层算子对 authenticated 的 EXECUTE(迁移之前不存在的对象读成 NULL)
SELECT s AS fn, CASE WHEN to_regprocedure(s) IS NULL THEN NULL
                     ELSE has_function_privilege('authenticated', s::regprocedure, 'EXECUTE') END AS authenticated_can_execute
  FROM unnest(ARRAY['public.submit_formula_create_request(jsonb, text)', 'public.submit_formula_change_request(uuid, jsonb, text)',
                    'public.submit_formula_reactivate_request(uuid, jsonb, text)', 'public.submit_contract_activation_request(uuid, text)',
                    'public.decide_terms_request(uuid, boolean, text)', 'public.withdraw_terms_request(uuid, text)',
                    'public.deactivate_pricing_formula(uuid)', 'public.delete_pricing_formula(uuid)',
                    'public.terms_request_execute_internal(uuid)', 'public.terms_request_submit_internal(text, uuid, jsonb, text)']) s;
SELECT (SELECT count(*) FROM approval_log) AS approval_log_rows,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total;
-- 银行 1000、应收 1100、存货 1200、应付 2000(借减贷,本位币;全部行,不按 posted 过滤 —— AGENTS.md)
SELECT a.code, round(COALESCE(sum(l.debit - l.credit), 0), 2) AS balance_debit_positive
  FROM accounts a LEFT JOIN journal_lines l ON l.account_id = a.id
 WHERE a.code IN ('1000', '1100', '1200', '2000') GROUP BY a.code ORDER BY a.code;
SELECT (SELECT count(*) FROM permissions) AS catalogue;
SELECT p.code, string_agg(r.code, ' ' ORDER BY r.code) AS holders
  FROM permissions p LEFT JOIN role_permissions rp ON rp.permission_code = p.code LEFT JOIN roles r ON r.id = rp.role_id
 WHERE p.code IN ('action.contract_terms', 'module.pricing.edit', 'module.pricing.view', 'data.view_prices',
                  'data.view_purchase_prices', 'module.suppliers.view', 'module.customers.view')
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
