# AT-1c survey A: finance documents (journal, invoice, credit note, sale, payable, payment, payment request, expense, freight, attachments)

Survey date 2026-10-03. Read-only. Repo `/Users/timchen/Documents/projects/new-era-erp`.
Live queries: psql to the live pooler (~/.pgpass),
each inside `BEGIN READ ONLY … ROLLBACK`, **identity `postgres`, rolbypassrls = t** (measured in every script). Only base tables
(relkind `r`, measured for the 13 main tables). Scripts and output: `A_q1.sql/.out`, `A_q2.sql/.out`, `A_q3.sql`, `A_q4.sql` in this folder.
M = Measured (command/query or file:line read), I = Inferred.

---

## 0. Facts that hold for every subject below

| # | Fact | Status |
|---|---|---|
| 0.1 | All nine pages are guarded by `requireModule(MOD.finance)`; `MOD.finance` = `byId('/finance')` → `permission: 'module.finance.view'` (`lib/modules.ts:140,365,1007`). Lines: journal `app/finance/journal/[id]/page.tsx:44`, invoice `invoices/[id]/page.tsx:60`, credit note `credit-notes/[id]/page.tsx:30`, sale `receivables/[saleId]/page.tsx:44`, payable `payables/[batchId]/page.tsx:42`, payment `payments/[id]/page.tsx:43`, request `payment-requests/[id]/page.tsx:57`, expense `expenses/[id]/page.tsx:42`, freight `freight/[id]/page.tsx:41`. **view_codes = `['module.finance.view']` for every subject.** | M |
| 0.2 | **No finance page carries a trail today** (`grep -rln "AuditTrail\|ListTrail\|RecentTrail" app/finance app/contracts` → nothing). | M |
| 0.3 | **Zero change_log rows** for any of the 21 finance tables surveyed (`SELECT table_name,count(*) FROM change_log WHERE table_name = ANY(...)` → 0 rows; postgres/bypassrls). **Every finance row predates the log** (`created_at < change_log_began_at()` = total for every table, A_q1). So each new finance trail is, today, **100 % pre-log reconstruction** — `trail_prelog_sources` registration is the whole visible content at launch. | M |
| 0.4 | `approval_log` has **0 rows** for subject_type `journal_request`, `invoice_request`, `payment_request`, `payment`, `expense`, `expense_claim` (A_q1); `journal_requests`, `invoice_requests`, `payment_requests` each have **0 rows**; `bank_transfers` 0, `wht_remittances` 0. The approval branches will be registered but empty on live. | M |
| 0.5 | Every actor column in this slice holds an **account id** (`auth.uid()` defaults / function writes `auth.uid()`): journal_entries.created_by, invoices.created_by/voided_by, invoice_issues.issued_by, cn_issues.issued_by, credit_notes.created_by, payments.created_by, payment_requests.created_by/decided_by/withdrawn_by/paid_by, journal_requests & invoice_requests created_by/decided_by/withdrawn_by, expenses.created_by, freight_documents.created_by/reversed_by/updated_by, bank_transfers.created_by/reversed_by, wht_remittances.created_by, sales_attribution_log.attributed_by, finance_attachments.created_by, approval_log.actor_user_id. **No M2 (employee-id) need in part A.** Employee ids appear only as *subjects* (payments.employee_id, payment_requests.employee_id, expenses.employee_id, expense_claims.employee_id), never as actors. | M (table files) / I for function-written stamps not individually read |
| 0.6 | **Reversal journals point back by `source_id = original journal id`, not the document id**: 13 of 13 reversal pairs on live have `r.source_id = o.id`, `r.source_type = o.source_type`, `r.source_id ≠ o.source_id` (A_q3). Code: `reverse_journal_entry_internal.sql:59-70` (`post_journal_entry(…, v_orig.source_type, v_orig.id, …)` then `UPDATE … reversed_by`). ⇒ a document's reversal journal is reachable **only** via the original's `reversed_by` (M4 up hop, as `inbound_batch` ord 39 already does), never via `source_id = doc.id`. | M |
| 0.7 | Live permission matrix (A_q4): every role holding `module.finance.view` (admin, auditor, cco, cfo, cto, finance, gm) **also** holds inbound/output/processing/purchasing/logistics view and data.view_prices. So cross-module members would show **no Restricted rows to any current finance reader**; the per-row rule still matters structurally. FIX-2a's comment "cfo has no inbound.view" (`payables/[batchId]/page.tsx:55-57`) is **stale**. | M |
| 0.8 | Every root/child table here is keyed by `id uuid` (no composite, no non-text key) → **no M5 need**. `invoice_issues`/`cn_issues` have `UNIQUE(parent, version)` but PK `id`. | M |
| 0.9 | Amount columns on invoices / invoice_lines / sales_records are already in `change_log_mask_rules.sql:36-43,100-103` (`data.view_prices`). | M |

---

## 1. Journal entry — `/finance/journal/[id]`

**1. Registry.** New subject `journal_entry`, view `['module.finance.view']`, root `journal_entries.id`, root_rule `table` (policy `has_permission('module.finance.view')`, `db/tables/journal_entries.sql` policy block — **matches**, no M3).

| ord | table | parent | fk | hop | shown | home | note |
|---|---|---|---|---|---|---|---|
| 1 | journal_lines | journal_entries | entry_id | down | t | **t** | lines (finance.view) |
| 2 | journal_entries | journal_entries | reversed_by | **up** | t | f | the reversal of this entry (M4) |
| 3 | journal_entries | journal_entries | reversed_by | down | t | f | on a reversal's page: the entry it reversed |
| 4 | journal_lines | journal_entries | entry_id | down | t | t | (same table/parent as ord 1; re-run after 2/3 if reversal lines are wanted — I: probably not, the reversal's lines are mirror images; Tim to decide) |
| 5 | journal_requests | journal_entries | result_journal_entry_id | down | t | t | the manual-entry request that posted it / the reversal request whose result is this reversal |
| 6 | journal_requests | journal_entries | target_entry_id | down | t | f* | reversal requests aimed at this entry (incl. rejected / withdrawn) |
| 7 | approval_log | journal_requests | subject_id | down, match `{"subject_type":"journal_request"}` | t | t | |

`*` home for journal_requests: one membership only should be home; `trail_row_record` takes the first home row whose fk is non-null (`trail_row_record.sql` ② loop) — result_journal_entry_id is NULL until approved, so a pending reversal request would fall through to target_entry_id if that is also home. Suggest home on both (XOR-like by state) or Tim's call.

- polymorphic: `approval_log.subject_type = 'journal_request'` (`db/tables/approval_log.sql` CHECK list + policy branch `WHEN 'journal_request' THEN module.finance.view`). M
- M needed: **M4** (reversed_by up hop — self-reference). Not M1/M2/M3/M5/M6.
- Overlap: `journal_entries` is already a member (home=f) of inbound_batch (ords 34-39), output_batch (31-36), stocktake (4). `journal_entries` is already in `document_types` (key `journal_entry`, A_q4), so making it a root does not change `trail_row_record`. **New subject needed** (no existing subject is rooted on journals). Renderer already has a `journal` family (`lib/trail/render.ts:867,913,1061-1063`: "posted"/"reversal"/`journal.laterReversed`).
- Source document: do **not** hop to the source document (cross-subject; the journal page shows only a link). I.

**2. Ended record.** Reversed entry is **shown, not filtered**: query `.eq('id', id).single()` with no status filter (`page.tsx:55-59`), banners `entry.status === 'reversed' && reversedByRes.data` → "reversed by X" (`:151-160`), and "reversal of X" via `.eq('reversed_by', id)` (`:90,161-170`). Columns: `status ('posted','reversed')`, `reversed_by uuid` (FK to the reversal entry). **No reversed_at / who / reason columns on the original**; the who/when is the reversal entry's `created_at/created_by` and the reason its `memo` (`'REVERSAL: ' || p_memo`). Immutable except posted→reversed (`guard_journal_entry_mutation`). Live: 82 entries, **13 reversed** (A_q1). M

**3. History-like sections.** Only the two banners (`page.tsx:151-170`) — navigation/state, **keep**. No list of requests or approvals is shown; the open reversal request appears only as a label on `ReverseButton` (`:79-83,210-213`) — keep (working control). Nothing to replace. M

**4. Pre-log sources.** Registered already: `journal_entries created created_at/created_by` (`trail_prelog_sources.sql:83`). To add: `journal_lines created created_at, by NULL` (same tx as header → folds), `journal_requests created created_at/created_by`, `journal_requests stamp withdrawn_at/withdrawn_by extra [status, withdraw_reason]` (decisions are in approval_log — do not register `decided_at`). All account ids. Live: 82 journals all pre-log; `created_by IS NULL` = 0 for every source_type (A_q2). M

**5. Breakers.** Self-reference both ways (handled by M4 up + plain down on the same table). `journal_requests.lines` is JSONB (entry lines before posting) → "Details changed" only. **Side finding:** `app/finance/sourceLinks.ts:70-73` builds `purchase:<source_id>` → `/inbound/<id>/edit` and `allocation:` → `/operation/processing/<id>`; on a reversal entry `source_id` is the original journal id (0.6), so the "Source" link on the 2 purchase-reversal and 1 allocation-reversal entries (live, A_q2/A_q3) points to a non-existent batch/run (I: 404). Not a trail breaker, but a wrong link on this page.

---

## 2. Invoice — `/finance/invoices/[id]` (+ invoice requests, invoice issues)

**1. Registry.** New subject `invoice`, view `['module.finance.view']`, root `invoices.id`, root_rule `table` (`invoices select by permission` = finance.view — **matches**). Column grants on `invoices` withhold `subtotal_base/tax_base/total_base/fx_rate` from authenticated; the mask rules already cover those (0.9).

| ord | table | parent | fk | hop | shown | home |
|---|---|---|---|---|---|---|
| 1 | invoice_lines | invoices | invoice_id | down | t | **t** (today home=f under output_batch ord 15) |
| 2 | invoice_requests | invoices | invoice_id | down | t | t |
| 3 | approval_log | invoice_requests | subject_id, match `{"subject_type":"invoice_request"}` | down | t | t |
| 4 | invoice_issues | invoices | invoice_id | down | t | t |
| 5 | credit_notes | invoices | invoice_id | down | t | f (home = credit_note subject) |
| 6 | payment_allocations | invoices | invoice_id | down | t | f |
| 7 | journal_entries | invoices | entry_id | **up** | t | f | the order-kind invoice's posting |
| 8 | journal_entries | journal_entries | reversed_by | **up** | t | f | the void reversal |
| 9 | journal_entries | invoice_requests | result_journal_entry_id | up | t | f | (I: same row as 8 for a void; dedupe handles it) |

- polymorphic: `approval_log.subject_type='invoice_request'`. M
- M needed: **M4** (entry_id / reversed_by up hops). Possibly `sales_order_history` (`void_invoice_internal.sql:110-114` writes `invoice_voided` for order kind) — that row belongs to the sales_order subject; **do not** add it here (it would say the void twice). I.
- Existing overlap: `invoice_lines` is an output_batch member (home=f). **New subject.**

**2. Ended record.** Voided invoice **shown**: `invoices_masked … .eq('id', id).single()`, no status filter (`page.tsx:70-78`); red banner `isVoid` with `voided_at` and `void_reason` (`:440-447`) — the banner **does not name who** although `voided_by` exists. Columns: `status ('issued','void')`, `void_reason`, `voided_at`, `voided_by` (`db/tables/invoices.sql`). `voided_by = auth.uid()` of whoever runs `void_invoice_internal` (`void_invoice_internal.sql:103-108`) — after APR-5a that is the **approver/executor**, not the requester (I). Live: 9 invoices, **3 void** (INV-0001 sale, INV-0006 order, INV-0008 sale), all three have voided_at/voided_by/void_reason (A_q2), **0 invoice_requests** ⇒ all voids predate APR-5a. M

**3. History-like sections.**
- `InvoiceRequestPanel` "history" (`InvoiceRequestPanel.tsx:145-161`, fed by `page.tsx:206 invoiceRequestHistory`, rendered `:384-392`) — decided/withdrawn requests with status, date, notes: **pure change history → candidate to replace**. The open-request block (`:74-143`) is a working control — keep.
- Void banner (`page.tsx:440-447`) — ended-state banner, keep (could gain "by").
- Settlement table (`:532-575`) — working list (what paid it), keep.
- Issues list (`:583-624`) — versions with download links, keep (working list); also its issued_at/by are the trail's pre-log source.
- `CreditNoteSection` list (`CreditNoteSection.tsx:128-143`) — working list of linked documents, keep. M

**4. Pre-log sources** (none registered today except `invoice_lines created`, `trail_prelog_sources.sql:87`). Add: `invoices created created_at/created_by`; `invoices stamp voided_at/voided_by extra [status, void_reason]` — **the only source for the 3 live voids** (no request rows, no approval rows); after APR-5a the approval row and the stamp share a tx → fold, the stocktake `posted_at` precedent (Q11). `invoice_requests created` + `stamp withdrawn_at/withdrawn_by [status, withdraw_reason]`; `invoice_issues created issued_at/issued_by` (live 4 issues, issued_by NULL = 0). All account ids. M

**5. Breakers.** `invoice_requests.lines` JSONB ("Details changed"). Invoice row is immutable except the void flip; invoice_lines' `invoice_voided` flips in the same tx (`trg_invoices_propagate_void`) → one entry, N line edits (renderer should fold). None structural. I.

---

## 3. Credit note — `/finance/credit-notes/[id]`

**1. Registry.** New subject `credit_note`, view `['module.finance.view']`, root `credit_notes.id`, root_rule `table` (policy finance.view — matches).
Members: `credit_note_lines.credit_note_id` (down, home t), `cn_issues.credit_note_id` (down, home t), `invoice_requests.result_credit_note_id` (down, home f), `approval_log` under that invoice_request (match `invoice_request`, home f), `journal_entries` via `credit_notes.entry_id` (**up**, M4). M4 only. Immutable / append-only (`trg_credit_notes_append_only`). M

**2. Ended record.** No end state: no status/void/deleted column (`db/tables/credit_notes.sql`); "void is a parked concept" per table comment. `notFound()` only when missing (`page.tsx:46`). Live: 1 credit note, 1 cn_issue. M

**3. History-like.** Issues list (`page.tsx:166-190`) — version downloads, keep. Nothing to replace. M

**4. Pre-log.** Add `credit_notes created created_at/created_by`, `credit_note_lines created created_at (by NULL)`, `cn_issues created issued_at/issued_by`. M (columns)

**5. Breakers.** None. The page reads `invoices_masked`, `customer_lookup`, `journal_entries` (`page.tsx:49-61`) — display only.

---

## 4. Receivables sale — `/finance/receivables/[saleId]` (sales_records)

**1. Registry.** New subject `sale` (name TBD), view `['module.finance.view']`, root `sales_records.id`, root_rule `table` (`sales_records select by permission` = finance.view — matches; column grant withholds unit_price/fx_rate/amount_base, mask rules cover them).
Members: `sales_attribution_log.sales_record_id` (down), `finance_attachments.sales_record_id` (down), `payment_allocations.sales_record_id` (down), `invoice_lines.sales_record_id` (down), `sales_record_movements.sales_record_id` (down; I — the page does not show stock movements, Tim to decide), `journal_entries` source_id = sale (down; match `{"source_type":"sale"}` advisable), `journal_entries` via `cogs_entry_id` (**up**), `journal_entries.reversed_by` (**up**).
- **Overlap:** sales_records, sales_record_movements, sales_attribution_log, invoice_lines, payment_allocations are already **output_batch members** (ords 12-16; sales_records/movements/attribution home=**t**). The page could not reuse `output_batch` (root is the batch, view `module.output.view`). **New subject needed.**
- ⚠ **Home side effect:** `trail_row_record` skips its "walk up" step for any table that is a subject root (`trail_row_record.sql` first IF: `NOT EXISTS … trail_subjects() ts WHERE ts.root_table = p_table`). Making `sales_records` a root changes `/settings/change-history`'s Record column for sale rows from the output batch to the sale itself (and `sales_records` is **not** in `document_types`, A_q4 → no route/link). M (code) / I (effect).
- M needed: **M4** (cogs_entry_id, reversed_by).

**2. Ended record.** No end state: immutable (`reject_sales_record_mutation`; only customer_id NULL→value under `attribution_ctx`, and cogs_entry_id NULL→value). No status/deleted columns. Page reads `sales_records_masked` (view filters only `has_permission('module.finance.view')`, `db/views/sales_records_masked.sql:50-51`). Live 9 sales, 0 without customer; 1 attribution log row. M

**3. History-like.** "Settlement history" (`page.tsx:309-310`, `SettlementHistoryTable`) — working list of payments (reversed ones struck through), keep. Attachments panel (`:313`) working list, filters `deleted_at IS NULL` (`:101`) → removals only visible in the trail. **Attribution history is not shown anywhere on the page** (only `AttributeCustomerControl`) — the trail would add it. M

**4. Pre-log.** All already registered: `sales_records created`, `sales_record_movements created`, `sales_attribution_log created attributed_at/attributed_by`, `invoice_lines created`, `payment_allocations created (by NULL)`, `finance_attachments created + stamp deleted_at (by NULL)`, `journal_entries created` (`trail_prelog_sources.sql:79-87`). Gap: the customer attribution on the sale row itself is a column edit with no stamp; the log row covers it. M

**5. Breakers.** None structural. Page reads `output_batch_lookup`, `customer_lookup`, `material_lookup` (cross-module, via lookup views). M

---

## 5. Payables batch — `/finance/payables/[batchId]` (inbound_batches)

**1. Registry.** Root `inbound_batches.id`. **Root SELECT policy = `module.inbound.view`** (`db/tables/inbound_batches.sql:276-279`) ≠ page guard `module.finance.view` → structurally needs **M3** (`root_rule='page'`) — the exact `forwarder`/`equipment` shape. Today no finance reader lacks inbound.view (0.7), so nothing would actually be Restricted.
Options for Tim:
- (a) **Reuse `inbound_batch`** with M1 `view_codes ['module.inbound.view','module.finance.view']` **plus** M3 — but `inbound_batch` is the full warehouse story (assays, safety states, stocktakes, processing, CoD, PO amendments, 39 members); on an AP page that is mostly noise, and switching inbound_batch to root_rule `page` would weaken the inbound page's root check. Not recommended. I.
- (b) **New subject `payable`** (recommended, I): view `['module.finance.view']`, root `inbound_batches`, root_rule **`page` (M3)**, root_columns **M6** = the AP-relevant columns the page shows (`quantity, unit, unit_price, arrival_date, notes, deleted_at` + maybe `supplier_id`) so the batch's warehouse edits don't flood the AP trail. Members (all already inbound_batch members, home=f there): `payment_allocations.inbound_batch_id`, `freight_allocations.inbound_batch_id`, `prepayment_applications.inbound_batch_id`, `finance_attachments.inbound_batch_id`, `price_history.inbound_batch_id` (I — price changes drive the payable), `journal_entries` source_id = batch (`purchase`/`writeoff`), `journal_entries` source_id = prepayment_applications, `journal_entries.reversed_by` up.
- M needed: M3, M6, M4.

**2. Ended record.** Written-off (soft-deleted) batch is **shown without any indication**: page reads `inbound_batch_lookup` (`page.tsx:53-60`), which has **no deleted filter** (`db/views/inbound_batch_lookup.sql` WHERE is only the four view codes) and the page selects no `deleted_at`/`status`. Live: **9 of 24 inbound batches are deleted** (A_q1) and all open here as ordinary payables. Columns available: `deleted_at`, `deleted_by`, `delete_reason`, `status` (`inbound_batches.sql:46,112,306`). Surprise — a 1b-1-style ended banner would be needed. M

**3. History-like.** Settlement history (`:247-248`) keep; attachments (`:252`) keep; purchase journals query (`:89-93`) shown as links, keep. Nothing to replace. M

**4. Pre-log.** All registered for inbound_batch already (`inbound_batches created / stamp deleted_at deleted_by [delete_reason]`, freight_allocations, payment_allocations, prepayment_applications, finance_attachments, journal_entries — `trail_prelog_sources.sql:53-83`). With M6, note `record_trail` drops root stamps whose `at_column` is not in `root_columns` (`record_trail.sql:166`) — so `deleted_at` must be in root_columns for the write-off to appear. M (code)

**5. Breakers.** Payment **requests** targeting this batch live only in `payment_requests.allocations` JSONB (`inbound_batch_id` key, `payment-requests/[id]/page.tsx:28-33`) → **unreachable** by members until paid (then via payment_allocations). M

---

## 6. Payment — `/finance/payments/[id]`

**1. Registry.** New subject `payment`, view `['module.finance.view']`, root `payments.id`, root_rule `table` (policy finance.view — matches).

| ord | table | parent | fk | hop | shown | home |
|---|---|---|---|---|---|---|
| 1 | payment_allocations | payments | payment_id | down | t | **t** |
| 2 | finance_attachments | payments | payment_id | down | t | t |
| 3 | payments | payments | reversed_by_payment | **up** | t | f | the mirror (reversal) payment |
| 4 | payments | payments | reversed_by_payment | down | t | f | on the mirror: the original |
| 5 | payment_requests | payments | result_payment_id | down | t | f | the request that paid it (or the reversal request on the mirror) |
| 6 | payment_requests | payments | payment_id | down | t | f | reversal requests aimed at it (incl. rejected/withdrawn) |
| 7 | approval_log | payment_requests | subject_id, match `payment_request` | down | t | f |
| 8 | journal_entries | payments | journal_entry_id | up | t | f |
| 9 | journal_entries | journal_entries | reversed_by | up | t | f |

- polymorphic `payment_request` (and the never-written `payment` type, `approval_log.sql` comment "从来没有路径写它"). M
- M needed: **M4** (self-reference + journal). New subject (payment_allocations is an inbound/output member, home=f).

**2. Ended record.** Reversed payment **shown**: `.from('payments')… .eq('id', id)` no status filter (`page.tsx:55-61`); banner "reversed by <mirror>" (`:296-306`). **The mirror payment has no "reversal of" banner** (unlike journal and expense pages) — only its notes text `'REVERSAL: <code> — memo'` (`reverse_payment_internal.sql:49-57`). Columns: `status ('posted','reversed')`, `reversed_by_payment`; **no reversed_at / reversed_by-person / reason** — when/who = mirror's `created_at/created_by`, reason = mirror `notes` (and the reversal request's `notes`). Live: 13 payments, **4 reversed** (PMT-0003/0005/0007, RCPT-0002) with 4 mirrors (PMT-0004/0006/0008, RCPT-0003), A_q2. M

**3. History-like.** Reversed banner (keep), open-reversal-request link (`:312-321`, working control, keep), allocations table (working list, keep), attachments (keep). No pure history section. M

**4. Pre-log.** To add: `payments created created_at/created_by` (the mirror's creation *is* the reversal event pre-log). `payment_requests created` + stamps (see §7). `payment_allocations` / `finance_attachments` already registered. M

**5. Breakers.** Self-reference (M4 both directions). Page reads `sales_records`, `purchase_orders` (base table, purchasing RLS), `expenses`, `inbound_batch_lookup`, `output_batch_lookup`, `invoices_masked` for allocation labels (`page.tsx:103-130`) — cross-module, display only. M

---

## 7. Payment request — `/finance/payment-requests/[id]` (incl. bank_transfers, wht_remittances results)

**1. Registry.** New subject `payment_request`, view `['module.finance.view']`, root `payment_requests.id`, root_rule `table` (policy finance.view — matches).

| ord | table | parent | fk | hop | shown | home | note |
|---|---|---|---|---|---|---|---|
| 1 | approval_log | payment_requests | subject_id, match `payment_request` | down | t | **t** | |
| 2 | payments | payment_requests | result_payment_id | up | t? | f | paid result (payment_out / payment_reversal mirror) — Tim: show its creation, or stepping stone only |
| 3 | payments | payment_requests | payment_id | up | **f** (stepping stone) | f | the payment being reversed — its own history is not this request's |
| 4 | bank_transfers | payment_requests | result_transfer_id | up | t | **t** (no page of its own) | |
| 5 | bank_transfers | payment_requests | transfer_id | up | t | f | the transfer being reversed; its reversed_at/by stamp is the event |
| 6 | wht_remittances | payment_requests | wht_remittance_id | up | t | f | remittance being reversed (reversal = its journal reversed) |
| 7 | journal_entries | payment_requests | result_journal_entry_id | up | t | f | |
| 8 | wht_remittances | journal_entries | journal_entry_id | down | t | **t** | ★ the only route to the remittance a `wht_remittance` request created (see 5) |
| 9 | journal_entries | journal_entries | reversed_by | up | t | f | |

- M needed: **M4** (many up hops; stepping stone for the reversed payment).
- bank_transfers and wht_remittances have **no page** (ops-finance §2) — this request page is their natural home (`payment-requests/[id]/page.tsx:97-104` already reads them).

**2. Ended record.** No 404 on any status: `.eq('id', id)`, `notFound()` only when missing (`page.tsx:69-75`). States `submitted/withdrawn/approved/rejected/paid` (`db/tables/payment_requests.sql`). Columns: `decided_at/decided_by/decision_notes`, `withdrawn_at/withdrawn_by` (**no withdraw_reason column**, unlike journal/invoice requests), `paid_at/paid_by`, results. Live: **0 requests**. M

**3. History-like.** The "decision" block (`page.tsx:258-283`: decided_at, decision_notes, "approved automatically", withdrawn_at) — a **history-like readout, candidate to replace** (it never says *who* decided or withdrew although decided_by/withdrawn_by exist). Paid banner (`:224-243`, link to result) keep. `RequestActions` (`:285-294`) keep. Allocation table (`:297-301`) keep. M

**4. Pre-log.** Add: `payment_requests created created_at/created_by`; `stamp withdrawn_at/withdrawn_by [status]`; `stamp paid_at/paid_by [status, result_payment_id, result_transfer_id, result_journal_entry_id]` (no history table records payment execution; `pay_payment_request.sql:106-108`); **not** `decided_at` (approval_log has it). `bank_transfers created created_at/created_by` + `stamp reversed_at/reversed_by [reversal_entry_id]`; `wht_remittances created created_at/created_by`. All account ids. Live counts 0, so no visible effect yet. M (columns)

**5. Breakers.**
- **`allocations` JSONB** (`payment_requests.sql`, CHECK `jsonb_typeof = 'array'`): the targets (expense_id / inbound_batch_id / purchase_order_id / freight_document_id, `page.tsx:28-33`) are **not FKs** → (i) on this page the column renders only "Details changed" (§9.7); (ii) **no expense / batch / freight / PO trail can find a pending or rejected request** aimed at it. Only a paid request becomes reachable (payment_allocations → payments → payment_requests.result_payment_id). M
- `kind='wht_remittance'` has **no FK to the remittance it creates** (shape CHECK forces `wht_remittance_id` NULL for that kind; result link is `result_journal_entry_id`, `pay_payment_request.sql:20,91,106-108`) → needs the two-hop journal route (ord 7→8). M
- `withdraw_payment_request` has no `self_leg` (ops-finance finding 4) → the trail must name the withdrawer; `withdrawn_by` is recorded. M (column) / survey claim not re-read.

---

## 8. Expense — `/finance/expenses/[id]`

**1. Registry.** New subject `expense`, view `['module.finance.view']`, root `expenses.id`, root_rule `table` (policy finance.view — matches).
Members: `payment_allocations.expense_id` (down, home t), `finance_attachments.expense_id` (down, home t), `prepayment_applications.expense_id` (down, home t — today home under inbound_batch ord 8; prepayment rows have *either* inbound_batch_id or expense_id, so both can be home, `trail_row_record` picks the non-null fk), `journal_entries` via `prepayment_applications` source_id (down) , `expenses.reversed_by_expense` (**up**: the mirror) and (down: the original, on the mirror's page), `journal_entries` via `expenses.journal_entry_id` (up), `journal_entries.reversed_by` (up). Optional (Tim): `expense_claims.expense_id` (down; claim's approval via approval_log `expense_claim` — claims have no page, ops-finance §2), `fixed_asset_cost_entries.expense_id` (finance.view), `equipment_maintenance.capitalised_expense_id` (processing RLS; home=t under equipment), `processing_cost_entries.relief_expense_id` (processing RLS). M (columns) / I (selection)
- M needed: **M4**.

**2. Ended record.** Reversed expense **shown**: no status filter (`page.tsx:53-59`); banners "reversed by <mirror>" and, on the mirror, "reversal of <original>" via `.eq('reversed_by_expense', id)` (`:115-123,279-297`). Columns: `status ('posted','reversed')`, `reversed_by_expense`; **no reversed_at / who / reason** — mirror's created_at/created_by; reason only in the mirror's notes/journal memo. Live: **9 expenses, 0 reversed** (A_q2). M

**3. History-like.** Banners keep; settlement (`:356-357`) keep; `ReleasePrepaymentPanel` (`:342`) working control; attachments (`:362`) keep. Nothing to replace. M

**4. Pre-log.** Add `expenses created created_at/created_by`. Others already registered. If claims are members: `expense_claims` has `created_at/created_by` (account), `submitted_at`, `withdrawn_at` (**no withdrawn_by**), `decided_at/decided_by` (approval_log covers decisions). M

**5. Breakers.** Self-reference via `reversed_by_expense`. Pending payment requests against the expense are invisible (JSONB, §7). Page reads `purchase_order_lines` and `purchase_order_status` (purchasing; `:74-82`) — cross-module, display only. M

---

## 9. Freight — `/finance/freight/[id]`

**1. Registry.** New subject `freight`, view `['module.finance.view']`, root `freight_documents.id`, root_rule `table`. Root policy is `module.inbound.view OR module.finance.view` (SELECT) plus a **FOR ALL** policy `module.finance.edit` (`db/tables/freight_documents.sql:94-99`) — `trail_row_visible` evaluates SELECT **and ALL** permissive policies, so the effective rule is a superset of the page code → no M3. (document_types lists view `{inbound.view, finance.view}` — the page itself is finance-only.)
Members: `freight_allocations.freight_document_id` (down, home t; today home=f under inbound_batch ord 21), `payment_allocations.freight_document_id` (down), `journal_entries` via `journal_entry_id` (up) and via `reversal_entry_id` (up) — or `reversed_by` (up) from the posting journal (same row; dedupe). Optional: `inbound_batches` via freight_allocations (stepping stone — no need), `containers` via container_id (logistics; no need). M4 only.

**2. Ended record.** Reversed freight **shown** with an amber banner: reversed_at, reversal entry link, reversal_reason (`page.tsx:160-181`) — **does not show `reversed_by`** although the column exists (`freight_documents.sql`). **Deleted freight 404s**: `.is('deleted_at', null)` then `notFound()` (`page.tsx:54-59`). But `freight_documents` has `deleted_at` with **no deleted_by**, no writer in `db/functions` (grep `UPDATE freight_documents` → only record_* journal link and reverse) and **0 deleted rows** live (A_q1) → effectively dead. Live: **4 freight documents, all 4 reversed**, each with reversed_at/reversed_by/reason/entry (A_q2). M

**3. History-like.** Reversed banner — ended-state banner, keep (could add "by"). Allocations table (`:195-205`) keep. M

**4. Pre-log.** Add `freight_documents created created_at/created_by`; `stamp reversed_at/reversed_by [status, reversal_reason, reversal_entry_id]` (**only source** for the 4 live reversals). `freight_allocations created` registered. Note freight_documents also has `updated_at/updated_by` (technical; not shown). M

**5. Breakers.** None structural. Code numbering oddity: FRT-2027-0001..0003 exist with reversal journals JE-2026-0058..0060 (A_q3) — dates, not a mechanism problem. Page embeds `containers ( id, code )` and `suppliers` via PostgREST (`page.tsx:55`) — cross-module RLS on the embed. M

---

## 10. finance_attachments

- Not a page; a **child** of four parents through XOR FKs `sales_record_id / inbound_batch_id / payment_id / expense_id` (+ `claim_id`, `db/tables/finance_attachments.sql`). Already a member of `inbound_batch` (ord 23, home=f). Register under sale, payable, payment and expense subjects; give **home=t** to each of the four memberships (one fk is non-null per row, so `trail_row_record`'s first-match picks the right one). M (code) / I (recommendation)
- Soft delete: `deleted_at`, **no deleted_by** (only `updated_by`, which is NULL on all 4 live rows) — the change log after the boundary will carry who; pre-log the stamp is registered with by NULL ("Not recorded") (`trail_prelog_sources.sql:81-82`). All panels filter `deleted_at IS NULL` (sale `:101`, payable `:98`, expense/payment similarly) → a removed attachment appears **only** in the trail. Live: 4 rows (2 sale, 1 batch, 1 expense, 0 payment/claim), 0 deleted (A_q1/A_q2). M
- Policy: SELECT finance.view (matches every finance page). M

---

## 11. Re-verification of ops-finance.md claims (2026-09-29)

| claim | now |
|---|---|
| §3A journal row: approval_log `journal_request`; journal_entries.reversed_by | **holds**; add `journal_requests.result_journal_entry_id` (not just target) — M |
| §3A invoice: "journal via invoices.entry_id" | holds; plus void reversal via `reversed_by` (0.6) — M |
| §3A credit note: "invoice_requests.result_credit_note_id" | holds — M |
| §3A payables guard finance.view | holds; root policy inbound.view (M3) — M |
| §3A payment-requests: "Targets … JSONB, not an FK" | holds; plus wht_remittance result not FK-linked (new) — M |
| Finding 7: "approval_log 15 rows; journal_requests 0" | journal_requests 0 holds; finance subject types in approval_log = 0 rows today — M |
| Finding 8: "two domain trails exist (fixed_asset_history, fx_rate_history)" | not in part A scope |
| FIX-2a comment "cfo has no inbound.view" | **stale**: cfo holds module.inbound.view (A_q4) — M |
