# SYSTEM-MAP-3 — Step 0 readings (2026-10-27)

Brief: "SYSTEM-MAP-3 — the upstream/downstream bar on every document detail page (close-out of SYSTEM-MAP-2 first; grilling + survey, then STOP)".
Started from `899100a7dc9d063d002319ed8ebc10594440b672` (HEAD = origin/main). **No application code changed and no migration ran in Step 0.**

**Identity of every reading:** live counts and registry reads as `postgres` (`rolbypassrls = true`) on base tables, and `document_relations` (a view over `pg_catalog`, the same for every reader);
production pages through throwaway `sm2probe` cfo clones (GET only, nothing pressed); the reconciliation line as tim@ (cfo) in a rolled-back transaction.
One code-reading sub-agent re-checked §3.1. Its brief carried the LIVE SAFETY section verbatim, and it **did not connect to live** (no DSN, no keys, no scripts).
4 of its citations were spot-checked by this session and all 4 matched: `ReservationSection.tsx:174`, `processing/[id]/page.tsx:868`, `payments/[id]/page.tsx:330`, `inbound/[id]/edit/page.tsx:878`.

## Part 1 — SYSTEM-MAP-2 close-out

| Step | Reading |
|---|---|
| 1.1 | `db/scripts/2026-10-27-system-map-2-closeout-prod-check.mjs` → **`SM2_CLOSEOUT_EXIT=0`, 3/3** (`readings/sm2-closeout-prod-check.txt`). `/workbench` HTTP 200 with to-do rows, which v1.4.77 does not have, so **production serves 2e0d047 / 899100a**. |
| 1.2 | cfo clone: `/workbench` drew 2 rows (two unread notifications); the database, read as the clone, has 2. The home count is 2 and links to `/workbench`. On `/tools/reminders`, 10/10 CFO-level branches are under "restricted", each reading "Decided by the CFO-level approver." |
| read-back | `readings/readback-part1.txt` and, after the 390 px measurement, `readings/readback-after-bar390.txt` (both `READBACK_OWN_EXIT=0`): 7 users / 7 enabled; 0 throwaway users, 0 probe roles, 0 orphan grants; 1 active cfo grant; approvals ON `finance/cfo/1000`; `require_calibrated_since` NULL; 2 CODs; reconciliation AP 0.00 / AR 0.00 unexplained. |
| 1.3 | 64d-2 marked closed in `docs/forward-queue.md` (uncommitted; it goes into the cut's commit). |

## §3.1 re-measured against today's code

All 25 pairs are **unchanged**: 11 both ways · 5 one way · 9 neither. By chain: purchasing 2/4/1 · processing 3/0/1 · sales 6/0/4 · people 0/1/3.
`git diff --name-only 7fe1cd07 HEAD -- app lib` (62 files) touches no chain detail page.
No detail page links to `/related/` or `/documents/` (grep; only search, the two routes and `lib/search/*`).

## The database relationship behind each pair

`document_relations` is derived from single-column foreign keys between registered document tables (at most one non-document table between them). Read on live (`readings` query in this session):

| pair | relation on live | in `search_related_rows()` today? |
|---|---|---|
| PO ↔ inbound batch | FK `inbound_batches.purchase_order_id` | yes |
| batch ↔ assay | FK `assay_results.inbound_batch_id` | yes |
| assay ↔ pricing | pricing is a panel on the batch page (no table, no anchor) | the batch side, yes |
| pricing ↔ payable | the payable page is keyed by the batch id (`/finance/payables/[batchId]`) | n/a (same batch) |
| payable ↔ payment request | **none**: `payment_requests.allocations` is **jsonb**, no FK | **no** |
| payment request ↔ payment | FKs `payment_id`, `result_payment_id` | yes |
| payment ↔ bank reconciliation | **none in one hop**: payment → journal entry → `journal_lines` ← `bank_line_matches` → `bank_statement_lines` → `bank_statements` | **no** |
| work order ↔ run | FK `processing_runs.work_order_id` | yes |
| run ↔ input / output batch | bridges (`processing_inputs`, `processing_outputs`, `inventory_movements`, …) | yes |
| run ↔ cost allocation | `batch_processing_cost_allocations` (a bridge run ↔ inbound batch); the allocation is a section on the run page, no anchor | as a bridge, yes |
| quote ↔ SO | FK `quotes.converted_order_id` | yes |
| SO ↔ reservation | `sales_order_reservations` → `sales_order_lines` → SO (2 hops); a section on the SO page, no anchor | no (not a document type) |
| SO ↔ shipment | FK `shipments.sales_order_id` | yes |
| shipment ↔ container | FK `shipments.container_id` | yes |
| SO / shipment / container ↔ invoice | only SO ↔ invoice (FK `invoices.sales_order_id`); **no** shipment or container relation | SO ↔ invoice only |
| invoice ↔ receipt | bridge `payment_allocations` | yes |
| invoice ↔ credit note | FK `credit_notes.invoice_id` | yes |
| attendance / overtime ↔ payroll period | **none**: equal `period_month` only | **no**; overtime batches are not even a document type (no `code` column; label `OT YYYY-MM #n`) |
| leave ↔ payroll period | **none**: leave dates fall in the payroll month (leave reaches pay through `attendance_unpaid_days`) | **no** |
| payroll period ↔ payroll payment | polymorphic `journal_entries.source_type='payroll'`, `source_id` = period id (`payroll_payment_entries()`); `document_relations` excludes polymorphic columns by ruling (SEARCH-4 Q11) | **no** |

Link-target mismatch: `documentHref()` sends `inbound_batch` / `output_batch` (`list_q`) to a filtered list and `credit_note` (`list`) to the list. Their detail pages are `/inbound/[id]/edit`, `/output/[id]/edit` and `/finance/credit-notes/[id]`.

Live data, as `postgres` on base tables: PO 11 (max 4 batches on one) · batches 24 (10 with a PO) · assays 4 · **payment requests 0** · payments 13 · bank matches 1 · WO 1 · runs 14 (1 with a WO) · cost-allocation rows 1 · outputs 20 · quotes 3 (1 converted) · SO 6 · reservations 3 · shipments 3 · containers 19 · invoices 9 (2 with an SO) · credit notes 1 · **attendance periods 0 · overtime batches 0** · leave 6 · payroll periods 1 · payroll-sourced journal entries 4.

## 390 px — the eight-step purchasing chain

`docs/surveys/SYSTEM-MAP-3/bar-390.mjs` → **`BAR390_EXIT=0`** (`readings/bar-390.txt`). A prototype bar (label + one sample code per step) was injected into the DOM of `/purchasing/orders/<PO-2026-0003>` in the browser only.

| | 390 en | 390 zh | 1440 en | 1440 zh |
|---|--:|--:|--:|--:|
| content column | 326 | 326 | 960 | 960 |
| A one row, no wrap: width needed | 1,637 ✗ | 1,366 ✗ | 1,637 ✗ | 1,366 ✗ |
| B wrapping chips: lines / height | 7 / 196 px | 6 / 167 px | 2 / 53 px | 2 / 53 px |
| C vertical list: height / widest cell | 163 px / 110 | 163 px / 101 | — | — |

**Already true before this cut:** the PO detail page is **421 px wide at 390 in English** (`pageBefore` 421, layout viewport widened to 421), and 390 in Chinese.

---

# Step 1 — build readings (2026-10-27 19:04:58 CST → 2026-10-28)

**Identity of every reading:** live counts and dry runs as `postgres` (`rolbypassrls = true`); walks and reconciliation as tim@ (cfo) or a throwaway clone inside
rolled-back transactions; pages through `next start` on this tree against live, as throwaway `sm3probe` clones (GET only, nothing pressed). No sub-agent ran in Step 1.

| # | Step | Reading |
|---|---|---|
| 1 | offline gate | `GATE_EXIT=0` (`readings/gate-offline.txt`) — fixture 296 ✓ |
| 2 | backup | `BACKUP_EXIT=0`, 19:50:59 → 20:21, `evoltrya-backup-2026-10-27-1950.dump` + 20 change_log chunks, 90,347 rows = count (`readings/backup.txt`) |
| 3 | live dry run | `DRY_OWN_EXIT=0`: 7 new functions · 10 arms · 518 relation edges · 64 document types (16 with a detail route) · anon cannot run the walk · tim@ walks read correctly → ROLLBACK → 0 left (`readings/dry-run.txt`) |
| 4 | apply | `APPLY_OWN_EXIT=0`, pre-flight 2 replaced · 7 new; **broken window opens 2026-10-27 20:28:29 CST** (`readings/apply.txt`) |
| 5 | types | `TYPES_OWN_EXIT=0` (+67 lines) · `tsc` clean |
| 6 | layout survey | 390 px: 19 pages, PO page 0 px (was 421 px in English), first pass 18/19 — the inbound loading skeleton (`w-96`) overflowed 27 px while streaming; fixed (`max-w-full`), re-run 0 px; Chinese PO + batch 0 px; container 0 px; desktop 1440: 19/19 (`readings/layout-*.txt`) |
| 7 | live proof (first tries) | 3 aborted runs; the third (three readers in parallel) drove the database to UNHEALTHY (~22:38) — `docs/known-issues.md` § SM3-LIVE-PROOF-OUTAGE. Two findings fixed: the walk could hit the 8 s statement timeout (→ `-fu1`), a failed walk turned the page into a 500 (→ shown in the bar). One finding was the proof's own (seven readers in one browser context shared cookies). |
| 8 | `-fu1` | dry run `DRYFU1_OWN_EXIT=0` (same rows, faster on work order / sales order) · `APPLYFU1_OWN_EXIT=0` at **22:08:24** (`readings/dry-run-fu1.txt`, `apply-fu1.txt`) |
| 9 | restart | Tim's ruling 23:05; Management API restart **23:07:01** (HTTP 200); db and rest ACTIVE_HEALTHY 23:10:38; `REAP_OWN_EXIT=0` (1 plan, 21 steps, 0 failures); read-back clean; COD bytes equal to the baseline (`readings/reap.txt`, `readback-after-restart.txt`, `cod-bytes.txt`) |
| 10 | budget (before `-fu2`) | one reader, 19 pages, 5 s apart: worst walk 927.3 ms (work order), 879.4 ms (purchase order); `select 1` 0.02–0.03 ms inside the database, ~410 ms per round trip from this machine (`readings/perf-budget.txt`) |
| 11 | `-fu2` | a function-level `SET statement_timeout` measured **not** to cap a call (local: `pg_sleep(3)` under `'1s'` ran 3000 ms); the walk checks its own clock instead (`DOCUMENT_CHAIN_WALK_BUDGET`, 2 s; fixture 296 T arm). Dry run `DRYFU2_OWN_EXIT=0` (0 ms budget refused on live) · `APPLYFU2_OWN_EXIT=0` at **2026-10-28 10:07:19**. No new backup (function only; the 19:50 backup predates all three migrations). |
| 12 | budget (after `-fu2`) | `SM3_PERF_EXIT=0`, 0 warnings: worst walk **804.6 ms** (purchase order), `select 1` ≤ 0.063 ms inside the database, worst single round trip 1,359 ms (`readings/perf-budget-fu2.txt`) |

**Walk time per page after `-fu2`** (inside the database, one cfo clone): purchase order 804.6 · inbound batch 269.8 + 365.6 · assay 775.5 · payable 188.1 · payment 128.6 · bank statement 70.9 ·
work order 404.1 · processing run 313.8 · output batch 325.8 · quote 112.4 · sales order 295.9 · shipment 293.6 · container 29.6 · invoice 243.7 · receipt 78.8 · credit note 183.1 ·
leave 54.1 · payroll period 169.5 · payroll payment 738.3 ms. Payment request, attendance and overtime have 0 live rows — proved only by fixture 296.

## Live proof — one reader at a time (2026-10-28 13:12 → about 14:20, `readings/live-proof.txt`)

`db/scripts/2026-10-27-system-map-3-live-proof.mjs`, seven throwaway clones (`cloneOf` each real role; no realRole was needed — nothing here gates on a real holder), **one reader at a time**,
19 detail pages each (every step that has live data), `next start` on this tree against live, GET only. Abort rules: Tim 2026-10-28 10:40 + 11:25 (AGENTS.md "ONE-READER").
**`SM3_PROOF_EXIT=1` — 2,297 PASS · 1 FAIL · 0 aborts · 5 recorded warnings.** Read-back afterwards `READBACK_OWN_EXIT=0` (`readings/readback-after-proof.txt`).

- Per reader, before it started: median round trip / in-database `select 1` — admin 636 ms / 0.021 ms · cfo 512 / 0.038 · cco 457 / 0.028 · cto 922 / 0.041 · finance 453 / 0.028 · gm 459 / 0.030 · warehouse 512 / 0.026. db and rest healthy each time.
- Every chain drawn with all its steps, the reader's step marked; no step blank; 25 restricted steps shown as "Restricted — needs <code>" exactly where the reader lacks the code (warehouse 25 of them — the finance steps, e.g. payable · payment request · payment · bank reconciliation "needs module.finance.view"); 289 chain links checked (cached per reader and address); "All related records" opens on every page.
- 390 px (cfo, purchase order): collapsed "Purchasing chain · step 1 of 8 · Show chain", page 390 px wide; opened 8 steps, bar 235 px tall, page 390 px wide.
- **Recorded budget refusals** (`DOCUMENT_CHAIN_WALK_BUDGET`, Tim 11:25: record when the database signals are normal; the page rendered each time):
  admin · payroll payment (in-db `select 1` 0.031 ms) · cco · sales order (0.603 ms) · gm · payment (0.028 ms); db and rest healthy each time. → CHAIN-WALK-COST (64d-4), `docs/known-issues.md` § SM3-ADMIN-WALK-OVER-BUDGET.
- **Recorded single round trips over 1.5 s:** before cfo 1,593 ms · before cto 1,735 ms.
- **The FAIL is not this cut's:** warehouse → `/output/848d954a-…/edit` HTTP 500, `record_trail(output_batch)` hit the 8 s statement timeout (`AuditTrail.tsx:224`). Idle afterwards: warehouse 785.2 ms · cfo 265.9 ms; `record_trail` unchanged since v1.4.41. `docs/known-issues.md` § SM3-OUTPUT-TRAIL-TIMEOUT.

## Gate, checks and smoke (2026-10-28)

- Full gate on the final code: **`GATE_EXIT=0`** — every verdict green, the rebuild matches live (`readings/gate-full.txt`). i18n `I18N_OWN_EXIT=0` · error-swallowing `SWALLOW_OWN_EXIT=0`.
- Smoke, under a watchdog that measured the database side once a minute (`select 1` five round trips + in-database execution + Management API health; Tim's abort rules):
  - run 1 (14:46:50) and run 2 (15:23:04): each stopped on the script's own "fetch failed" — 334 routes (310 ok · 0 FAIL · 24 skip) and 78 routes (71 ok · 0 FAIL · 7 skip); no URL or cause printed (`readings/smoke-run1.txt`, `smoke-run2.txt`).
  - the script now retries a network-level failure (a rejected fetch, no HTTP status) up to twice with 1 s / 3 s backoff and prints `NETRETRY|` / `NETFAIL|` with the URL, the reader and the cause; HTTP statuses and page assertions are never retried (Tim 2026-10-28 15:55).
  - run 3 (15:59:48): **`SMOKE_EXIT=0` — 344 ok · 25 skipped (no data) · 0 FAILED · `NETRETRY_TOTAL=0`**, 318 routes timed, 1,693.9 s (`readings/smoke.txt`).
  - watchdog: never fired; in-database `select 1` ≤ 1.26 ms, db and rest healthy throughout; **recorded single round trips over 1.5 s:** run 1 1,689 · 1,723 ms; run 2 1,640 ms; run 3 1,693 · 6,169 ms (`readings/smoke-watchdog*.txt`).
- Read-back after smoke `READBACK_OWN_EXIT=0` (`readings/readback-after-smoke.txt`).

- Fresh clone of `5567a85ba2f4b22587f3e6cd36aad103b5a8fa93`, no `.env.local`, `npm ci && npm run build`: **`FRESH_OWN_EXIT=0`** (`readings/fresh-clone-build.txt`). The only change after that clone is this line and that log (docs only).
