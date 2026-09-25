-- db/scripts/2026-09-25-role1b3b-readings.sql
-- ROLE-1 Batch 3b · 前后读数(只读;整支一笔事务,最后 ROLLBACK)。与 Batch 3a 那一支同形,多读:
-- 七个新码的持有人、加工单按状态、产出 / 投料 / 损耗 / 交接班行数、进料与产出批次(全部 / 已注销)、
-- 工单按状态与建单人。本刀新增七个码,所以码表要证明【只多了裁定的那十五行】。
--
-- 身份写在每一段的开头(AGENTS.md「一个 0 行的读数,先问它是谁读的」):
--   第一部分:以 postgres 连接,rolbypassrls = t,读的全部是【基表】(relkind = 'r',第一段自证);
--     payroll_requests 在迁移之前不存在 —— 第一段用 to_regclass 读它,不存在就印 NULL,不报错;
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
   AND relname IN ('processing_runs','processing_outputs','processing_inputs','processing_run_losses','processing_cost_entries',
                   'shift_handovers','output_batches','material_lookup','finance_settings','expense_claims','leave_requests','medical_claims','performance_reviews',
                   'work_orders','stocktakes','purchase_orders','approval_log','journal_entries','journal_lines',
                   'accounts','role_permissions','roles','user_roles','payment_requests','payroll_periods',
                   'payroll_lines','payroll_requests','receipt_price_requests','attendance_periods','assay_results','inbound_batch_metals','ap_open_items','ar_open_items',
                   'price_history','inbound_batches','permissions','stocktake_lines','stocktake_counts');
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
-- payroll_requests:迁移之前不存在(NULL = 表不在),之后是行数
SELECT CASE WHEN to_regclass('public.receipt_price_requests') IS NULL THEN NULL
            ELSE (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM public.receipt_price_requests', false, true, '')))[1]::text
       END AS receipt_price_requests_rows,
       CASE WHEN to_regclass('public.receipt_price_requests') IS NULL THEN NULL
            ELSE (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM public.receipt_price_requests WHERE status = ''submitted''', false, true, '')))[1]::text
       END AS receipt_price_requests_pending,
       (SELECT count(*) FROM payroll_requests WHERE status IN ('submitted', 'approved')) AS payroll_requests_open;
SELECT pricing_status, count(*) FILTER (WHERE deleted_at IS NULL) AS live, count(*) FILTER (WHERE deleted_at IS NULL AND unit_price IS NOT NULL) AS live_priced
  FROM inbound_batches GROUP BY 1 ORDER BY 1;
SELECT status, count(*) FILTER (WHERE deleted_at IS NULL) AS stocktakes_live FROM stocktakes GROUP BY 1 ORDER BY 1;
SELECT (SELECT count(*) FROM stocktake_lines) AS stocktake_lines,
       CASE WHEN to_regclass('public.stocktake_counts') IS NULL THEN NULL
            ELSE (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM public.stocktake_counts', false, true, '')))[1]::text
       END AS stocktake_counts_rows;
SELECT w.status, count(*) AS work_orders,
       string_agg(DISTINCT COALESCE(u.email::text, 'not-an-account:' || left(w.created_by::text, 8)), ' ') AS created_by
  FROM work_orders w LEFT JOIN auth.users u ON u.id = w.created_by GROUP BY 1 ORDER BY 1;
SELECT status, (deleted_at IS NOT NULL) AS deleted, (work_order_id IS NOT NULL) AS on_wo, count(*) AS processing_runs
  FROM processing_runs GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;
SELECT (SELECT count(*) FROM processing_outputs) AS processing_outputs,
       (SELECT count(*) FROM processing_inputs) AS processing_inputs,
       (SELECT count(*) FROM processing_run_losses) AS processing_run_losses,
       (SELECT count(*) FROM processing_cost_entries) AS processing_cost_entries,
       (SELECT count(*) FROM shift_handovers) AS shift_handovers;
SELECT (SELECT count(*) FROM inbound_batches WHERE deleted_at IS NOT NULL) AS receipts_written_off,
       (SELECT count(*) FROM output_batches) AS outputs_all,
       (SELECT count(*) FROM output_batches WHERE deleted_at IS NOT NULL) AS outputs_written_off;
SELECT (SELECT count(*) FROM assay_results WHERE is_final AND deleted_at IS NULL) AS assays_final,
       (SELECT count(*) FROM assay_results WHERE applied_at IS NOT NULL AND deleted_at IS NULL) AS assays_applied,
       (SELECT count(*) FROM inbound_batch_metals) AS metal_rows;
SELECT CASE WHEN to_regclass('public.payroll_requests') IS NULL THEN NULL
            ELSE (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM public.payroll_requests', false, true, '')))[1]::text
       END AS payroll_requests_rows;
SELECT (SELECT count(*) FROM approval_log) AS approval_log_rows,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_entries WHERE source_type = 'payroll') AS payroll_journal_entries;
SELECT p.code, p.status, p.gross_total, p.net_pay_total, p.journal_entry_id IS NOT NULL AS has_je,
       p.cpf_paid_at, p.deductions_paid_at,
       (SELECT count(*) FROM payroll_lines l WHERE l.payroll_period_id = p.id) AS lines,
       (SELECT count(*) FROM payroll_lines l WHERE l.payroll_period_id = p.id AND l.paid_at IS NOT NULL) AS lines_paid
  FROM payroll_periods p ORDER BY p.period_month;
SELECT (SELECT count(*) FROM attendance_periods) AS attendance_periods;
-- 库存(1200 进料 · 1220 产出)与相关科目(借减贷,本位币)
SELECT a.code, round(COALESCE(sum(l.debit - l.credit), 0), 2) AS balance_debit_positive
  FROM accounts a LEFT JOIN journal_lines l ON l.account_id = a.id
 WHERE a.code IN ('1100', '1200', '1220', '2000', '2200', '2300', '2400', '5000', '5200') GROUP BY a.code ORDER BY a.code;
SELECT (SELECT count(*) FROM price_history) AS price_history_rows,
       (SELECT count(*) FROM inbound_batches WHERE unit_price IS NOT NULL) AS receipts_priced,
       (SELECT count(*) FROM inbound_batches) AS receipts_all,
       (SELECT count(*) FROM journal_entries WHERE source_type = 'purchase') AS purchase_entries;
SELECT (SELECT count(*) FROM permissions) AS catalogue;
SELECT p.code, string_agg(r.code, ' ' ORDER BY r.code) AS holders
  FROM permissions p LEFT JOIN role_permissions rp ON rp.permission_code = p.code LEFT JOIN roles r ON r.id = rp.role_id
 WHERE p.code IN ('module.inbound.edit', 'module.output.edit', 'module.processing.edit', 'module.processing.view',
                  'module.materials.view', 'action.receive_goods', 'action.batch_write_off', 'action.wo_create',
                  'action.wo_release', 'action.processing_commit', 'action.processing_rollback',
                  'action.processing_aftercare', 'action.issue_cod', 'module.sales.edit')
 GROUP BY p.code ORDER BY p.code;
SELECT r.code AS role, count(rp.permission_code) AS n,
       md5(COALESCE(string_agg(rp.permission_code, ',' ORDER BY rp.permission_code), '')) AS codes_md5
  FROM roles r LEFT JOIN role_permissions rp ON rp.role_id = r.id GROUP BY r.code ORDER BY r.code;
SELECT r.code AS role, string_agg(rp.permission_code, ' ' ORDER BY rp.permission_code) AS codes
  FROM roles r JOIN role_permissions rp ON rp.role_id = r.id GROUP BY r.code ORDER BY r.code;
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
