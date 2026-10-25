v1.4.74 — Every list page sorts (36 in the database, 48 in the browser, the 3 editable tables included); payments, journal, inbound, output and processing sort by their document date; /operation/processing gets its sort control; /hr/leave lifts pending requests to the top before the 300 cap; table headers stick on desktop for tables taller than the screen; export, sort and paging keep working on ended records and inside permission-greyed blocks.

# TABLE-FEATURES-1 — hand-back (2026-10-25)

Brief: "TABLE-FEATURES-1" (Step 0, 2026-10-25) and Tim's rulings Q1–Q13 of 2026-10-25, recorded verbatim at their source:
`docs/table-features.md` § "The rulings — Tim 2026-10-25". Queue entry `docs/forward-queue.md` 64c (TF-2 = 64c-2, TF-3 = 64c-3, both with the rulings verbatim).
Started from `f156ee129225648523e27a8ddcbe898e2bf91f78` (HEAD = origin/main = ls-remote, tree clean). Step 0: `docs/surveys/TABLE-FEATURES-1/step0.md` and its three survey files;
readings: `docs/surveys/TABLE-FEATURES-1/readings/`. **No migration**, so no backup, no dry run and no window.

## 0 · Part 1 — TABLE-EXPORT-3c close-out (2026-10-25)

- Run 1 (20:17 CST): HTTP 200 on both pages but 0 export pairs — production was not yet serving f156ee1 (`closeout-prod-check-run1-no-export-bars.txt`). Waited 10 minutes as the brief says.
- Run 2 (20:31 CST): `TE3C_CLOSEOUT_EXIT=0`, 6 / 6 (`closeout-prod-check.txt`, script `db/scripts/2026-10-25-table-export-3c-closeout-prod-check.mjs`): PROC-2026-0001 draws 7 export pairs;
  its outputs table exports 2 rows (Excel and CSV) = 2 on screen; `/related/processing_run/<PROC-2026-0001>/output_batch` exports 2 rows = 2 on screen = `data-related-total` 2.
- After both runs 0 throwaway users, roles and orphan grants (`readback-run1.txt`, `readback-closeout.txt`). 3c marked closed in the queue.

## 1 · Against each scope item and ruling

| Item | Result |
|---|---|
| Q8 · which pages | The 84 table list pages, each table on them sorts — `scripts/check-list-sorting.mjs` (in the build): 84 routes · 300 files · 125 table tags, every one with `sorting` (6 detail-only panels and 5 prop-driven tables are verified exemptions). |
| Q9 · database sort | 36 pages (19 paged + 17 capped): 8 already sorted (kept); 28 converted to `lib/listSort.ts` — whitelist to the column of the relation the page reads (masked views included), stable tie-break, export routes read the same `sort`/`dir`, the order is taken before the cap. |
| Q9 · browser sort | 48 pages: columns compare by their export value (`sortKeyFromCell`); 「受限」 sorts last; sorting switches off with a sentence at 1,000 rows (`READ_ROW_LIMIT`, one definition in `lib/listSort.ts`; the ruling says "exactly 1,000", the code uses ≥ so a table merged from two reads is covered too). |
| Q9 · /operation/processing | Header links added; sortable code, date, totals, loss, status. |
| Q7 · default sort | Payments, journal, inbound, output, processing: document date desc → created_at desc → id. Everything else unchanged; approval panels keep their order. |
| Q8 · editable tables | `/hr/kpi/score`, `/hr/leave/types`, `/hr/reviews/scale` (and /me's self-assessment) sort in the browser; sorting waits while a row is edited or has unsaved changes; rows keep their original index for `rowKey`. This amends CONV-2's Q4 for sorting only (comment rewritten in `editable-table.tsx`, reason kept). |
| Q4 · sticky header | Desktop: bounded table box (`sm:max-h-[calc(100dvh-6rem)]`), only tables taller than the screen scroll in it and their header sticks; 390 px: no bound, not sticky. DataTable and EditableTable. Frozen column not built. |
| Q10 · read-only controls | Every `<fieldset disabled>` now goes through `app/components/ui/disabled-block.tsx` (EndedFieldset, PermissionGate, TaskEditGate, MetalContentPanel, PricingPanel); export (lists and reports), client sort, page buttons and the phone expand button render as `<span role="button">` inside a disabled block; write controls stay disabled. `scripts/check-disabled-block.mjs` (in the build) refuses any other disabled fieldset. **Search box: not achievable** (an `<input>` cannot escape a disabled fieldset; 0 production tables use it) — registered TABLE-SEARCH-IN-DISABLED-BLOCK. |
| Q12 · /hr/leave | Default order is pending first (read before the cap), then start_date desc; the export follows the same order; a column click is a plain database sort. |
| Q12 · three findings | Registered in `docs/known-issues.md` (PO-LIST-NO-APPROVAL-STATUS · EXPENSE-CLAIMS-MISSING-FROM-REMINDERS · PAYMENT-REQUESTS-FILTER-MIXES-QUEUES) and attached to 64d. |
| Q1 · footer totals | **TF-2** (queued 64c-2). |
| Q5 · date presets | **TF-2** (queued 64c-2). |
| Q2 · bulk actions | **TF-3** (queued 64c-3); the follow-up for leave, medical claims, payment requests, POs, overtime and reviews is noted there. |
| Q3 · saved views | **TF-3** (queued 64c-3). TF-1 measured what TF-3 inherits: browser sort state lives in React, not the URL. |
| Q11 · reject reasons | **TF-3** (queued 64c-3; registered LEAVE-MEDICAL-REJECT-NO-REASON). |
| Q6 · printing | Not built. |
| Q13 · split | Three cuts; TF-1 fit this session — no TF-1b. |
| Corrections | Recorded in `docs/table-features.md` and queue 64c: 84 list pages (112 files), 12 ended blocks, the re-measured feature counts. |

## 2 · Verify chain (in order)

| # | Step | Reading |
|---|---|---|
| 1 | offline gate | `GATE_EXIT=0` (21:16:59 → 21:19:19, 140 s; `gate-offline.txt`). |
| 2 | migration | none. |
| 3 | tsc | `TSC_OWN_EXIT=0` (3 s, incremental after the conversion agents' runs; `tsc.txt`). |
| 4 | build | Run 1 `BUILD_OWN_EXIT=1`: `check-datatable-phone` could not see `priority` on the two contamination tables (a mapped column array) — columns now marked in place (`build-run1.txt`). Run 2 **`BUILD_OWN_EXIT=0`** (97 s). |
| — | layout survey | Before the proof build (the probe refuses to run on a built tree). 15 touched pages incl. a tall table and an ended record. **1280 px 15 / 15 at 0 overflow, 0 clipped.** **390 px 14 / 15**: `/purchasing/orders` +59 px, culprit the supplier filter `<select>` — **pre-existing**: the same probe on an untouched f156ee1 worktree reads +59 px, same culprit (`layout-390-baseline-f156ee1-purchasing-orders.txt`); registered PURCHASING-ORDERS-390-SUPPLIER-SELECT. `/hr/kpi/score` drew no table without a cycle — re-measured with `?cycle=`: 1 table, 0 / 0 at both widths (`layout-kpi-score-concrete.txt`). **Not measured:** `/me` (the survey account is not an employee, no tables). Self-test passed every run. |
| — | proof dry run | Before the gate. Run 1 `TF1_PROOF_EXIT=1`: a proof fault (the export bar was looked up from the new table box, which also carries `w-full`; `live-proof-run1.txt`); run 2 `TF1_PROOF_EXIT=0`. |
| 5 | full gate | **`GATE_EXIT=0`** on the final code (21:59:14 → 22:18:07, ≈ 1,133 s; `gate-full.txt`), every verdict green. Only this hand-back changed after it. |
| 6 | i18n | `I18N_OWN_EXIT=0` (two new keys: `table.sortOffAtLimit`, `table.sortHeldWhileEditing`). |
| 7 | error-swallowing | `SWALLOW_OWN_EXIT=0`. |
| 8 | smoke | **`SMOKE_EXIT=0`: 338 ok, 25 skipped (no data), 0 failed** (22:18:24 → ≈ 23:03). It reported 6 stale scratch rows from earlier cuts; reported, not swept. |
| 9 | live proof | Build `BUILD_OWN_EXIT=0` (100 s), then **`TF1_PROOF_EXIT=0`, 11 / 11 PASS** (23:05:23 → 23:11:27; `live-proof.txt`, §3). |
| 10 | COD byte check | `COD_OWN_EXIT=0`: COD-2026-0001 34,701 bytes `ba299a4f3488fc543cdd1f410fabf6523434d39caa0dc58d6f376309c1f42101`; COD-2026-0002 34,746 bytes `717661f6a8166b5f9342324586208e21f29c217aa5d3c047b009e00f2513a4f9`. Both equal the `AGENTS.md` baseline. |
| 11 | fresh clone, no `.env.local` | In the close report. |

## 3 · Live proof (`readings/live-proof.txt`; `next start` on this tree against live; real headless Chrome; files read back)

Throwaways (prefix `tf1probe`, shared helper): `finance` (`module.finance.view`) · `inventory` (`module.inventory.view`) · `output` (`module.output.view` + `module.inventory.view`).
Counts and orders read as `postgres` on base tables.

- **J · database sort both ways across pages:** `/finance/journal` by code — ascending over 5 pages = 92 rows (= 92 `journal_entries`), in order, JE-2026-0001 … JE-2027-0003; descending over 5 pages is exactly the ascending list reversed; the CSV exported from the descending view has the 92 codes in the screen's order.
- **B · browser sort:** `/inventory/locations` by code — ascending then descending, each in order and each the other reversed.
- **E · ended record:** deleted output batch OUT-2026-0248 — its block is a disabled fieldset; the movement table's sort header and both export buttons are `<span role="button">`; sorting by time reverses the 5 rows (= 5 movements); Excel and CSV each have 5 rows; the block's 38 write controls are all still disabled.
- **S · sticky header:** desktop 1280×800 — header `position: sticky`, box max-height 704 px, the table is taller than its box, after scrolling the box 188 px the header sits 0 px from the box top; 390×844 — header `static`, box max-height `none`.
- **P · payments by document date:** default order on screen = `payment_date desc, created_at desc, id` from the database (13 rows). The arm discriminates: the old `created_at` order differs in the last three rows (`live-proof-P-discrimination.txt`).

Read back after the live steps (`readback.txt`, as `postgres`, counts only): 7 users, 7 enabled; 0 throwaway users and roles; 0 orphan grants; role codes admin · cco · cfo · cto · finance · gm · warehouse;
approvals ON (`finance` / `cfo` / 1000); `require_calibrated_since` NULL; 2 CODs; reconciliation as tim@ (rolled back) AP and AR 0.00 / 0.00 unexplained.
Not touched: the portal access-token hook, `portal-uploads`, `claim-receipts`.

## 4 · Decisions taken without asking

1. **Sticky header implementation:** the bounded box is `100dvh − 6rem` on desktop; inner scrolling replaces page scrolling only for tables taller than that.
2. **Mixed units and currencies:** money in per-row currencies sorts by its base amount or is not sortable; a quantity column sorts only while every row on screen shares one unit (`/inventory`, `/operation/wip`; live materials are all kg today).
3. **Status / type columns** sort by the stored code, not the translated label (as the 8 pre-existing pages did).
4. **Looked-up and composed columns** are not sortable on database-sorted lists (e.g. counterparty, employee, supplier on POs, customer on invoices).
5. **Detail-page tables** were not converted, except the batch movement trail, which sits in the ended block of a deleted batch and carries the ended-record proof.
6. **"Sorted over all rows" line** now hides when the screen already holds every row; capped lists still show their "first N of M" notice beside it.
7. **Prefixes** on pages with two database-sorted tables: capture (`recent_`), contamination (`checks_`), /me (`leave_`, `mc_`, `exp_`).
8. Throwaway prefix `tf1probe` added to `scripts/ephemeral.mjs`; `check-datatable-footer` now loads `disabled-block.tsx`, `data-table.tsx` and `lib/listSort.ts` for real.

## 5 · Assertions measured false

1. Step 0 brief: "114 list pages" — 84 pages (112 files). The ended-record issue: "3 pages" — 12 blocks (+5 permission blocks, +1 live record).
2. The queue's 2026-10-23 counts "8, 2, 1, 1, 1, 0 of 183" — 8, 1, 1, 1, 1, 0 of 182 files (235 call sites); the three 1s only in brand-sampler.
3. `data-table.tsx`'s comment "client sort has only one call site" — no longer true; comment updated.

## 6 · Registered, not fixed

- TABLE-SEARCH-IN-DISABLED-BLOCK · PURCHASING-ORDERS-390-SUPPLIER-SELECT (pre-existing) · PO-LIST-NO-APPROVAL-STATUS · EXPENSE-CLAIMS-MISSING-FROM-REMINDERS ·
  PAYMENT-REQUESTS-FILTER-MIXES-QUEUES · LEAVE-MEDICAL-REJECT-NO-REASON (TF-3). EXPORT-DISABLED-ON-ENDED-RECORDS marked fixed.

## 7 · Measured costs, for the next estimate

| Step | Cost |
|---|---|
| offline gate | 140 s |
| tsc | 3 s (incremental) |
| build | 93–100 s |
| full gate | ≈ 1,133 s |
| layout | 165 s (390, 15 pages) · 155 s (1280, 15 pages) · baseline worktree 13 s + copy |
| smoke | ≈ 2,700 s |
| live proof | ≈ 364 s |
| conversion | five parallel agents on disjoint modules, 351–606 s each (each agent's own measured duration; they ran concurrently) |

No backup.
