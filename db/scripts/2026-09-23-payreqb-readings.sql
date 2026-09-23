-- db/scripts/2026-09-23-payreqb-readings.sql
-- PAY-REQ-1 · Batch B · 前后读数(只读)。身份:以 postgres 连接,rolbypassrls = t,读的全部是【基表】
-- (relkind = 'r',第一段自证)—— 所以这些数是真行数,不是某个视图谓词对"没有 JWT 的人"的回答。
\pset footer off
SELECT current_user AS identity, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user) AS bypassrls, now() AS read_at;
SELECT string_agg(relname || '=' || relkind::text, ' ' ORDER BY relname) AS relkinds
  FROM pg_class WHERE relnamespace = 'public'::regnamespace
   AND relname IN ('finance_settings','expense_claims','leave_requests','medical_claims','performance_reviews',
                   'work_orders','stocktakes','purchase_orders','approval_log','journal_entries','journal_lines',
                   'accounts','role_permissions','roles','payments','payment_requests','bank_transfers','wht_remittances');
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
       (SELECT count(*) FROM payment_requests WHERE status IN ('submitted','approved')) AS payment_requests_open;
SELECT (SELECT count(*) FROM approval_log) AS approval_log_rows,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM payments) AS payments,
       (SELECT count(*) FROM bank_transfers) AS bank_transfers,
       (SELECT count(*) FROM wht_remittances) AS wht_remittances,
       (SELECT count(*) FROM payment_requests) AS payment_requests_all;
SELECT kind, status, count(*) FROM payment_requests GROUP BY 1, 2 ORDER BY 1, 2;
-- 余额:全部分录行(含已冲销的原件与它的冲销件 —— 两者相抵,AGENTS.md「汇总时不许按 status 过滤」)
SELECT a.code, round(COALESCE(sum(l.debit - l.credit), 0), 2) AS balance_base_debit_positive
  FROM accounts a LEFT JOIN journal_lines l ON l.account_id = a.id
 WHERE a.code IN ('1000', '1010', '2000', '2150') GROUP BY a.code ORDER BY a.code;
SELECT r.code AS role, count(rp.permission_code) AS n,
       md5(COALESCE(string_agg(rp.permission_code, ',' ORDER BY rp.permission_code), '')) AS list_md5
  FROM roles r LEFT JOIN role_permissions rp ON rp.role_id = r.id GROUP BY r.code ORDER BY r.code;
