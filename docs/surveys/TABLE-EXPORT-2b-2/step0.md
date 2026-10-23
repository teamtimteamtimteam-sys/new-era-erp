# TABLE-EXPORT-2b-2 — Step 0 survey (2026-10-23)

Read-only. Code read and grepped at `2249696e4c388cee970bf1fe0b306e33976bfd3e`; no browser sweeps. Live counts read as `postgres`
(`rolbypassrls = true`) through the Management API — `readings/partB-live-counts.json` (all 16 objects relkind `r`, so they are row counts)
and `readings/proof-data.json`. **`contamination_shift_status` is a view: its 0 read as `postgres` is not a row count.**

## A–E · every limit and count, re-measured

| scope | page | file:line | N | live base rows | finding |
|---|---|---|---|---|---|
| A | /sales/orders | app/sales/orders/page.tsx:38 | 200 | sales_orders 6 | as briefed |
| A | /sales/quotes | app/sales/quotes/page.tsx:28 | 200 | quotes 3 | as briefed |
| A, C | /hr/claims | app/hr/claims/page.tsx:38 · status filter :42 | 300 | medical_claims 1 | filter is `settlement_state`, a column of the view → `.eq()` before the limit |
| A | /hr/leave | app/hr/leave/page.tsx:61 | 300 | leave_requests 6 | as briefed |
| A | /hr/reviews | app/hr/reviews/page.tsx:**57** (brief/2b survey: 56) | 200 | performance_reviews 0 | line moved one in 2b-1 |
| A (Q3) | /hr/leave/grants | app/hr/leave/grants/page.tsx:38–41 | 200 | leave_grants 0 | **not a table** — the 200 picks the records fed to `<ListTrail>` (:69–71), the audit-history block; question 1 |
| A (Q3) | /hr/reviews/cycles | app/hr/reviews/cycles/page.tsx:95–98 | 200 | review_cycles 0 | **not a table** — same, `<ListTrail>` at :205–206; question 1 |
| A, C | /inventory/reports/ledger | app/inventory/reports/ledger/ledgerQuery.ts:65 · filter :86–89 | 2,000 written, **1,000 effective** (PostgREST `max_rows`) | inventory_movements 107 | the notice must say 1,000; the filter runs over two embeds (inbound or output batch) |
| A | /operation/capture waiting | app/operation/capture/page.tsx:55 | 200, oldest first | capture_drafts 0 | as briefed |
| D | capture "recently confirmed" | same :59 | 50 | weighings 0 | as briefed |
| B | /operation/capture/inbox | app/operation/capture/inbox/page.tsx:45 | 200 | **ingest_inbox 2,005** | the only page over its cap on live — brief's 2,005 re-measured, holds |
| A | /operation/weighbridge | app/operation/weighbridge/page.tsx:41 | 200 | weighbridge_tickets 0 | as briefed |
| A | /operation/contamination grid | app/operation/contamination/page.tsx:35 | 300 | (view) | as briefed |
| D | contamination recent checks | same :36 | 50 | contamination_checks 0 | as briefed |
| E | contamination "missing" | same :55 | counts the capped 300 | (view) | exact count = one head count on the view |
| E | /notifications unread | app/notifications/page.tsx:51 (PAGE_LIMIT :17, read :35) | counts the capped 50 | notifications 2 · reads 7 | exact = visible count − own reads joined `!inner` to visible notifications (FK `notification_reads.notification_id`) |
| E (adjacent) | top-nav bell | lib/notifications.ts:26 (`BELL_LIMIT = 10`), :52–73 | counts the newest 10 | — | **not in the brief**; question 3 |

## F · the 17 「受限」 sites, re-measured

All 17 are page-side: the masking already happens in the views (`purchase_orders_masked` :25/:29/:60 · `purchase_order_lines_masked` :28/:32 ·
`purchase_order_payment_terms_masked` :29 · `inbound_batches_masked` :44). **No migration.**

| # | site | file:line | today | export exists? |
|---|---|---|---|---|
| 1 | PO line unit price | app/purchasing/orders/[id]/page.tsx:474 | "—" | no — PoLinesTable is TABLE-EXPORT-3 |
| 2 | PO line amount | same :495 | blank | no (same) |
| 3 | PO net / tax / gross totals | same :515–537 | blank | no (same) |
| 4 | PO payment term fixed share | same :545 | "—" | no — PoPaymentTermsTable is TABLE-EXPORT-3 |
| 5 | **PO payment-term amount** | same :546–549 via `termAmount` :417–420 (`Number(null) × pct`) | **0.00** (false) | no (same) |
| 6 | **PO header "@ null"** | same :776 | **"USD @ null"** (false) | n/a (header) |
| 7 | **PO receipts unit price** | app/purchasing/orders/[id]/PoReceiptsTable.tsx:83–88 | **"Unpriced"** (false) | no — TABLE-EXPORT-3 |
| 8 | payment-term template fixed share | app/purchasing/payment-terms/page.tsx:72 | "—" | **yes** — TemplatesTable.tsx:67 (`termsSummary`) |
| 9–10 | **inbound "unpriced" badge** | app/inbound/page.tsx:88–92 (count `unit_price IS NULL` on the masked view) · :246–250 | **every batch** for a blind reader (false) | n/a (summary line). `pricing_status` is unmasked (view :57) and already drives the "awaiting final" count beside it |
| 11 | prepayment history amount | app/inbound/[id]/edit/PrepaymentPanel.tsx:154 | "—" | no — TABLE-EXPORT-3 |
| 12 | employee payroll amounts | app/hr/employees/[id]/page.tsx:241–245 | "—" | no — EmployeeTables is TABLE-EXPORT-3 |
| 13 | output unit cost / values | app/inventory/output/[materialId]/page.tsx:237–240 | "—" | no — OutputBatchesTable is TABLE-EXPORT-3 |
| 14–15 | **output cost / market totals** | same :265, :271 | **0.00** (false) | n/a (summary line) |
| 16 | inbound drill batch value | app/inventory/inbound/[materialId]/page.tsx:135–138 | "—" | no — InboundBatchesTable is TABLE-EXPORT-3 |
| 17 | **inbound drill stock value total** | same :161 | **0.00** (false) | n/a (summary line) |

The 7 false values Tim listed are #5, #6, #7, #9–10, #14–15 and #17 (output and inbound totals). Live data to prove them
(`readings/proof-data.json`): 6 non-base-currency POs (#6) · 9 POs with percentage terms (#5) · 9 priced inbound batches (#9–10, #17) · 4 priced receipts on PO lines (#7) · 14 output batches (#14–15).

## Migration

**None expected.** Masking is in the views already; exact counts are head counts; the ledger filter is two server-filtered reads
(inbound side and output side, each `!inner` on its batch and material) merged and cut once, with M = the two exact counts — no id lists in URLs.
