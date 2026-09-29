-- db/scripts/2026-09-29-at1b1-live-readings.sql
-- AUDIT-TRAIL-1b-1 · 活库的"之前 / 之后"读数 —— 只读。live verification 前后各跑一次,两份输出逐字相同 = 这一刀的验证什么都没留下、
--   在它之前就在的每一张单据一个字节都没变。以 postgres 跑(rolbypassrls = true,读的是基表的真行数)。
-- 跑法:psql "$DSN" -X -q -f db/scripts/2026-09-29-at1b1-live-readings.sql
DO $read$
DECLARE t record; d text; acc text := ''; n int := 0;
BEGIN
    -- 每一张 public 表(change_log 除外 —— 它由下面单独读)的每一行:按行的 md5 排序后整体再 md5
    FOR t IN SELECT c.relname FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
              WHERE ns.nspname = 'public' AND c.relkind = 'r' AND c.relname <> 'change_log' ORDER BY 1 LOOP
        EXECUTE format('SELECT md5(COALESCE(string_agg(md5(x::text), '''' ORDER BY md5(x::text)), '''')) FROM public.%I x', t.relname) INTO d;
        acc := acc || t.relname || ':' || d || ';';
        n := n + 1;
    END LOOP;
    RAISE NOTICE 'READING tables % · every-row digest %', n, left(md5(acc), 12);
END;
$read$;
SELECT 'READING' AS reading,
       (SELECT count(*) || ' rows, max seq ' || max(seq) FROM change_log) AS change_log,
       (SELECT count(*) || ' accounts, ' || count(*) FILTER (WHERE banned_until > now()) || ' disabled'
          FROM auth.users WHERE email NOT LIKE '%@test.local') AS accounts,
       (SELECT CASE WHEN approvals_enabled THEN 'ON' ELSE 'OFF' END FROM finance_settings) AS approvals,
       (SELECT count(*) || ' · ' || left(md5(string_agg(k || ':' || id, ',' ORDER BY k, id)), 12) FROM (
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted'
       ) p) AS pending_documents,
       (SELECT count(*) || ', last ' || max(code) FROM purchase_orders) AS purchase_orders,
       (SELECT count(*) FROM inbound_batches) || ' inbound · ' || (SELECT count(*) FROM output_batches) || ' output' AS batches,
       (SELECT count(*) FROM shift_handovers) AS handovers,
       (SELECT count(*) FROM warehouse_requests) AS warehouse_requests;
