# TABLE-EXPORT-2b — Step 0 survey (2026-10-23)

Read-only. Code surveyed by reading and grepping files only; no scripts were run except the Part 1.2 production check. Live counts were read as `postgres` (`rolbypassrls = true`) in `readings/partB-live-counts.json`.
**Views read as `postgres` return 0 because their predicates ask who the reader is, so those zeros are not row counts.** Only the base-table (`r`) counts are row counts.

## Part B — every limit in the brief matches the code

| page | file:line | N | source | today | exportSpec | filter after the cut |
|---|---|---|---|---|---|---|
| /sales/orders | app/sales/orders/page.tsx:38 | 200 | sales_orders (r, 6) | client DT | yes | — |
| /sales/quotes | app/sales/quotes/page.tsx:28 | 200 | quote_status (v) | client DT | yes | — |
| /hr/claims | app/hr/claims/page.tsx:38 | 300 | medical_claim_status (v; base medical_claims 1) | client DT | yes | status, :42 |
| /hr/leave | app/hr/leave/page.tsx:61 | 300 | leave_requests_masked (base 6) | client DT | yes | JS re-sort only (~:70-74) |
| /hr/reviews | app/hr/reviews/page.tsx:56 | 200 | performance_reviews_masked (base 0) | client DT | yes | — ; :69-71 read `.data` only (Q10) |
| /inventory/reports/ledger | ledgerQuery.ts:65 | 2000 (1,000 effective) | inventory_movements (r, 107) | client DT | yes | material and batch, :84-90 |
| /operation/capture waiting | app/operation/capture/page.tsx:55 | 200 | capture_drafts pending (r, 0), **oldest first** | client DT | yes | — |
| /operation/capture recently confirmed | same :59 | 50 | weighing_calibration (v) | client DT | yes | — |
| /operation/capture/inbox | app/operation/capture/inbox/page.tsx:45 | 200 | ingest_inbox (r, **2,005**) | CellsTable, no paging | yes | — |
| /operation/weighbridge | app/operation/weighbridge/page.tsx:41 | 200 | weighbridge_ticket_weights (v) | client DT | yes | — |
| /operation/contamination grid | app/operation/contamination/page.tsx:35 | 300 | contamination_shift_status (v) | client DT | yes | "missing" count at :55 counts the capped rows |
| contamination recent checks | same :36 | 50 | contamination_check_rows (v) | client DT | yes | — |
| /compliance/packs | app/compliance/packs/page.tsx:39 | 300 | compliance_packs (r, 0) | client DT | no (2b entry) | — |
| /safety/inspections runs | app/safety/inspections/page.tsx:43 | 200 | inspection_run_rows (v; base inspection_runs 0) | client DT | no (2b entry) | — |
| /safety/environment | app/safety/environment/page.tsx:41 | 300 | environmental_result_rows (v) | client DT | no (2b entry) | — |
| /me leave · medical · expense | app/me/page.tsx:165 · 170 · 177 | 50 each | leave_requests_masked · medical_claim_status · expense_claim_status (own rows) | client DT | no (2b entries) | — |
| /notifications | app/notifications/page.tsx:35 (PAGE_LIMIT :17) | 50 | notifications (r, 2) | **plain list, not a table** | no | unread count at :51 counts the capped 50 |
| /settings/import history | app/settings/import/page.tsx:66 | 20 | import_batches (r, 2) | client DT | no (2b entry) | — |
| /settings/change-history | page.tsx:41 MAX_SHOW 500, link hidden at :256 | 500 | change_log (r, **79,156**) | "show older" list | n/a (Q4) | — |

Caps the brief does not list: `/hr/leave/grants` (app/hr/leave/grants/page.tsx:40, 200) and `/hr/reviews/cycles` (cycles/page.tsx:96, 200).

## The 21 exemption entries: all shared `<DataTable>`, ~25 table components

compliance packs 1 · contracts **5** (ContractsTables) · /me 8 files, **10 tables** (Leave has 3), all on the single route app/me/page.tsx · my-reviews 1 (rendered twice) · safety environment 1, incidents 1, inspections **2** (RunsTable also on templates/[id]) · settings deleted 1, dictionaries 1 component rendered once per dictionary (dynamic columns, a dictionary editor, kept in 2 by Q7), import 1, reference 1, roles 1 · tools formulas 1, metal-prices 1.
Server-paged: **only metal-prices** (page.tsx:120-140, count + range), so it needs its own export route. The others hold all their rows on the client; the capped ones are listed above.
Rows arriving pre-formatted (export needs raw fields): MyPayslipsTable (5 money columns formatted on the server from payroll_lines_masked), Contracts settlements `amount`.
Masked on these tables: formulas treatment charge and discount (blank today; see Q8 below). DictSection already renders 「受限」 for an unreadable supplier.

## Q8 — masked values shown as "—", blank or a false value outside app/finance (18 sites)

See the report's question about scope. List table: formulas (FormulasTable.tsx:53, :55). The others are detail pages, headers and forms: purchasing/orders/[id] (:474, :495, :522-536, :545, :546-549 prints 0.00, :776 prints "@ null"), PoReceiptsTable.tsx:84-87 ("Unpriced"), purchasing/payment-terms:72, inbound/page.tsx:88-92/:246-249 (unpriced badge counts masked rows), PrepaymentPanel.tsx:154, hr/employees/[id]:241-245, inventory/output/[materialId]:237-238 and :265/:271-273 (total 0.00), inventory/inbound/[materialId]:138/:161 (`?? 0` total).
Edit forms that pre-fill a masked value as '': formulas/[id]/edit/page.tsx:75-76 → formulas/actions.ts:70-76 turns '' into **0** and submits a change request; EmployeeForm identity_no (:435), saved through actions.ts:131 `|| null` (whether the database keeps the old value is NOT measured).
