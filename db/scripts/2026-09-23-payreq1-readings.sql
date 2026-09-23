-- db/scripts/2026-09-23-payreq1-readings.sql
-- PAY-REQ-1 · 前后读数(只读)。身份:以 postgres 连接,rolbypassrls = t,读的全部是【基表】
-- (relkind = 'r',第一段自证)—— 所以这些数是真行数,不是某个视图谓词对"没有 JWT 的人"的回答。
\pset footer off
SELECT current_user AS identity, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user) AS bypassrls;
SELECT string_agg(relname || '=' || relkind::text, ' ' ORDER BY relname) AS relkinds
  FROM pg_class WHERE relnamespace = 'public'::regnamespace
   AND relname IN ('finance_settings','expense_claims','leave_requests','medical_claims','performance_reviews',
                   'work_orders','stocktakes','purchase_orders','approval_log','journal_entries','journal_lines',
                   'accounts','role_permissions','roles','payments','payment_requests');
SELECT approvals_enabled, approval_level1_role_code AS l1, approval_level2_role_code AS l2,
       approval_threshold_base AS threshold FROM finance_settings;
SELECT (SELECT count(*) FROM expense_claims WHERE status = 'submitted') AS claims_submitted,
       (SELECT count(*) FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL) AS leave_pending,
       (SELECT count(*) FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL) AS medical_submitted,
       (SELECT count(*) FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL) AS medical_approved_unpaid,
       (SELECT count(*) FROM performance_reviews WHERE status = 'submitted') AS reviews_submitted,
       (SELECT count(*) FROM work_orders WHERE status = 'draft') AS work_orders_draft,
       (SELECT count(*) FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL) AS stocktakes_open,
       (SELECT count(*) FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL) AS po_pending,
       CASE WHEN to_regclass('public.payment_requests') IS NULL THEN 'n/a (table absent)'
            ELSE (xpath('/row/c/text()', query_to_xml(
                  'SELECT count(*) AS c FROM payment_requests WHERE status IN (''submitted'',''approved'')', false, true, '')))[1]::text
       END AS payment_requests_open;
SELECT (SELECT count(*) FROM approval_log) AS approval_log_rows,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM payments) AS payments;
-- 余额:全部分录行(含已冲销的原件与它的冲销件 —— 两者相抵,AGENTS.md「汇总时不许按 status 过滤」)
SELECT a.code, round(sum(l.debit - l.credit), 2) AS balance_base_debit_positive
  FROM journal_lines l JOIN accounts a ON a.id = l.account_id
 WHERE a.code IN ('1000', '1010', '2000') GROUP BY a.code ORDER BY a.code;
SELECT count(*) AS cfo_codes, string_agg(rp.permission_code, ',' ORDER BY rp.permission_code) AS cfo_code_list
  FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'cfo';
