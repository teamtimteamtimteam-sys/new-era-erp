-- MES-5b-2 opening reading (2026-10-09) — read-only, BEGIN READ ONLY … ROLLBACK.
-- Identity: postgres (rolbypassrls = true) on base tables; the AP/AR reconciliation is read in tim@'s (cfo) session,
-- because list_ledger_reconciliation answers per caller (the owner has no JWT and would read a refusal, not a measurement).
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;

-- 1 · expenses by kind × settlement state
WITH k AS (
  SELECT e.*,
         CASE WHEN EXISTS (SELECT 1 FROM expenses o WHERE o.reversed_by_expense = e.id) THEN 'reversal_mirror'
              WHEN EXISTS (SELECT 1 FROM electricity_allocations a WHERE a.expense_id = e.id) THEN 'electricity_allocation'
              WHEN EXISTS (SELECT 1 FROM processing_cost_entries c WHERE c.relief_expense_id = e.id) THEN 'month_end_relief'
              WHEN EXISTS (SELECT 1 FROM fixed_assets fa WHERE fa.expense_id = e.id) THEN 'asset_birth'
              WHEN EXISTS (SELECT 1 FROM fixed_asset_cost_entries f WHERE f.expense_id = e.id) THEN 'asset_append'
              WHEN EXISTS (SELECT 1 FROM expense_claims x WHERE x.expense_id = e.id) THEN 'expense_claim'
              WHEN EXISTS (SELECT 1 FROM medical_claims x WHERE x.expense_id = e.id) THEN 'medical_claim'
              ELSE 'ordinary' END AS kind,
         COALESCE((SELECT sum(pa.allocated_ccy) FROM payment_allocations pa JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
                    WHERE pa.expense_id = e.id), 0) AS paid_through_payment,
         COALESCE((SELECT sum(ppa.amount_ccy) FROM prepayment_applications ppa WHERE ppa.expense_id = e.id), 0) AS prepaid
    FROM expenses e)
SELECT 'EXP|' || kind || '|' || status || '|' || st || '|n=' || count(*) || '|base=' || sum(amount_base) || '|codes=' || string_agg(code, ',' ORDER BY code)
  FROM (SELECT k.*, CASE WHEN payment_status = 'paid' THEN 'paid_at_posting'
            WHEN paid_through_payment > 0 AND paid_through_payment >= amount_ccy THEN 'settled_through_payment'
            WHEN paid_through_payment > 0 THEN 'part_settled_through_payment'
            WHEN prepaid > 0 THEN 'prepayment_applied'
            ELSE 'unpaid_open' END AS st FROM k) k2
 GROUP BY kind, status, st ORDER BY 1;

-- 2 · relief expenses and the estimates each relieved (including any reversed relief)
SELECT 'RELIEF|' || e.code || '|status=' || e.status || '|reversed_by=' || COALESCE((SELECT code FROM expenses m WHERE m.id = e.reversed_by_expense), '-')
       || '|amount=' || e.amount_base || '|pay=' || e.payment_status || '|date=' || e.expense_date
       || '|estimates=' || count(c.id) || '|accrued=' || sum(c.amount_base)
       || '|deleted=' || count(*) FILTER (WHERE c.deleted_at IS NOT NULL)
       || '|entries=' || string_agg(r.code || ':' || c.cost_type || ':' || c.amount_base || ':relieved_at=' || c.relieved_at, ',' ORDER BY r.code)
  FROM expenses e JOIN processing_cost_entries c ON c.relief_expense_id = e.id JOIN processing_runs r ON r.id = c.run_id
 WHERE NOT EXISTS (SELECT 1 FROM electricity_allocations a WHERE a.expense_id = e.id)
 GROUP BY e.id, e.code, e.status, e.reversed_by_expense, e.amount_base, e.payment_status, e.expense_date ORDER BY e.code;

-- 3 · electricity allocations and their lines
SELECT 'ALLOC|count=' || count(*) FROM electricity_allocations;
SELECT 'ALLOC_LINES|count=' || count(*) FROM electricity_allocation_lines;

-- 4 · cost entries by type × estimate × settlement mark
SELECT 'PCE|' || g || '|n=' || count(*) || '|base=' || sum(amount_base)
  FROM (SELECT cost_type || '|' || CASE WHEN is_estimate THEN 'estimate' ELSE 'actual' END || '|' ||
               CASE WHEN remitted_at IS NOT NULL THEN 'remitted' WHEN relieved_at IS NOT NULL THEN 'relieved' ELSE 'open' END || '|' ||
               CASE WHEN deleted_at IS NOT NULL THEN 'deleted' ELSE 'live' END AS g, amount_base FROM processing_cost_entries) z
 GROUP BY g ORDER BY g;
-- marks pointing at a reversed relief (the F2 orphan shape) today
SELECT 'ORPHAN_MARKS|' || count(*) FROM processing_cost_entries c JOIN expenses e ON e.id = c.relief_expense_id WHERE e.status = 'reversed';

-- 5 · standing state
SELECT 'ACCOUNTS|' || count(*) || '|disabled=' || count(*) FILTER (WHERE banned_until > now()) FROM auth.users WHERE email NOT LIKE '%@test.local';
SELECT 'THROWAWAY|' || count(*) FROM auth.users WHERE email LIKE '%@test.local';
SELECT 'APPROVALS_ON|' || approvals_enabled FROM finance_settings;
SELECT 'RCS|' || COALESCE(require_calibrated_since::text, 'NULL') FROM ingest_settings;
SELECT 'PENDING|' || count(*) || '|' || COALESCE(string_agg(to_jsonb(d)::text, ' ; '), '') FROM approval_pending_documents() d;
SELECT 'CHANGE_LOG|' || count(*) || '|max=' || max(seq) FROM change_log;
SELECT 'NOTIFICATIONS|' || count(*) FROM notifications;
SELECT 'PAYMENTS|' || count(*) || '|posted=' || count(*) FILTER (WHERE status = 'posted') FROM payments;
SELECT 'JOURNALS|' || count(*) FROM journal_entries;

-- 6 · reconciliation in tim@'s session
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT 'RECON|' || (s ->> 'side') || '|list=' || (s ->> 'list_base') || '|ledger=' || (s ->> 'ledger_base') || '|unexplained=' || (s ->> 'unexplained_base')
  FROM jsonb_array_elements(list_ledger_reconciliation() -> 'sides') s;
RESET ROLE;
ROLLBACK;
