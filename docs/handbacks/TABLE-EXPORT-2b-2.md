v1.4.70 — Sales, HR, inventory and operation list pages that showed only their first N rows now say so and export every row; the data inbox pages through all of its messages; two filters that ran after the cut now run before it; the notification count is exact on the page and the bell; and seventeen places that showed a blank, 0.00, "@ null" or "Unpriced" to someone who cannot see prices now say 「受限」/"Restricted".

# TABLE-EXPORT-2b-2 — hand-back (2026-10-23)

Brief: "TABLE-EXPORT-2b-2" (Step 0 then Step 1, 2026-10-23) and Tim's rulings of the same day, recorded at their source:
`docs/table-export.md` § "The rulings — Tim 2026-10-23 (TABLE-EXPORT-2b-2 Step 0)". Queue entry `docs/forward-queue.md` 64a-3.
Started from `2249696e4c388cee970bf1fe0b306e33976bfd3e` (HEAD = origin/main = ls-remote, tree clean). Readings: `docs/surveys/TABLE-EXPORT-2b-2/readings/`;
Step 0 survey: `docs/surveys/TABLE-EXPORT-2b-2/step0.md`. **No migration** — every mask already lives in the views; no backup, no window.

## 0 · Part 1 — TABLE-EXPORT-2b-1 close-out

| Step | Reading |
|---|---|
| 1.1 | HEAD, origin/main, `git ls-remote origin main` all `2249696e4c388cee970bf1fe0b306e33976bfd3e`; tree clean. |
| 1.2 | 2b-1's broken window recorded in its hand-back: 2026-10-23 15:55:48 → 18:10 CST (2 h 14 min 12 s; the end is Tim's report, not a reading this machine took). |
| 1.3 | Production, `TE2B1_CLOSEOUT_EXIT=0`, 6 / 6 (`readings/closeout-prod-check.txt`, script `db/scripts/2026-10-23-table-export-2b1-closeout-prod-check.mjs`): a throwaway with `module.pricing.view` + `data.view_prices` and **without** `data.view_purchase_prices` opened `/tools/pricing/formulas` — the one formula's treatment and discount read "Restricted"; a throwaway employee opened `/me` (HTTP 200, 8 export bars) and its three export routes answered HTTP 200. Read back as `postgres`, counts only: 7 users, 7 enabled, **0** throwaway users / roles / employees, 0 orphan grants. |
| 1.4 | 2b-1 marked closed (`docs/forward-queue.md` 64a-2). |
| 1.5 | SYSTEM-MAP-0 registered as `docs/forward-queue.md` 64d, Tim's text verbatim, after TABLE-FEATURES and before the go-live readiness group (also noted in the group's header). |
| 1.6 | "Pages too slow to use" → go-live readiness row 13 and `docs/known-issues.md` § PAGES-TOO-SLOW-TO-USE. Tim's later correction (the 15 s reading) recorded beside the measured readings — see §5. |

## 1 · Against each scope item and ruling

| Item | Result |
|---|---|
| A · hard row limits | `/sales/orders` 200 · `/sales/quotes` 200 · `/hr/claims` 300 · `/hr/leave` 300 · `/hr/reviews` 200 · `/inventory/reports/ledger` 1,000 · `/operation/capture` pending 200 · `/operation/weighbridge` 200 · `/operation/contamination` grid 300: each keeps its N rows, says "Showing the first N of M — narrow the filters or export" when M > N, and exports every matching row (≤ 50,000) through a route running the page's own read and filters (`<page>Rows.ts` + `export/route.ts`). |
| A · Q3 pages (ruling Q1) | `/hr/leave/grants` and `/hr/reviews/cycles`: their 200 picks the records fed to the history section; a notice "History below covers the latest 200 of M" when there are more, no export (`app/components/trail/TrailCapNotice.tsx`). |
| B · inbox | `/operation/capture/inbox` pages (`?page=`, 200 a page, "Page 1 of 11 · 2,005 messages"); its export takes every matching row. **Proven live past the old limit** (§3, I1–I4). |
| C · filter moves | `/hr/claims` status is now part of the query (before the cut, and in the count). Ledger material and batch: two reads filtered in the database (inbound side, output side — `inventory_movements_one_batch` makes them disjoint), merged in one order, cut once; M = the two exact counts. Verified read-only against live as the service role (RLS bypassed, base table): MAT-2026-0002 25 = 25, MAT-2026-0001 52 = 52, batch "2026-0" 102 = 102, of 107. |
| D · two "recent" tables | capture "recently confirmed" 50 and contamination "recent checks" 50: notice + full export. |
| E · exact counts | contamination "missing" = one `count(exact)` on `check_state = 'missing'` (the view yields exactly three states, never NULL). Notifications: one function `countUnread` (`lib/notifications.ts`) = visible notifications − own reads joined `!inner` to visible ones; the page now states "N unread"; notice "first 50 of M"; no export (2b Q2). |
| Q3 · bell | The top-bar bell reads the same `countUnread`; still "9+" above 9. Proven live = database (§3, N1–N2). |
| F · 17 「受限」 sites | All 17 fixed on screen — PO detail: line unit price, line amount, net/tax/gross totals, term fixed share, **term amount (was 0.00)**, **header "@ null"**; **receipt "Unpriced"**; payment-term template summary (screen **and** export, Q2); **inbound "unpriced" badge** ("Unpriced batches: Restricted"); prepayment history amount; employee payroll amounts; output unit cost and cost value; **output cost total (was 0.00)**; inbound drill batch value; **inbound drill stock value total (was 0.00)**. Five of the seven false values proven live (§3, R1–R5). |
| Q2 · TABLE-EXPORT-3 | Recorded in `docs/forward-queue.md` 64b: when those detail tables get exports, every cell the screen draws as 「受限」 exports "Restricted". **Seven** entries listed by file — see §6 item 1 for why it is 7, not 15. |
| Split | Not split; everything fitted. No TABLE-EXPORT-2b-3 queued. |
| Correction (15 s) | Recorded — see §5 item 2. |

**After this cut no `TABLE-EXPORT-2` work remains.** `scripts/table-export-exemptions.mjs`: **117 `TABLE-EXPORT-3` · 1 `PERMANENT` · 0 `TABLE-EXPORT-2`.**

## 2 · Verify chain (in order)

| # | Step | Reading |
|---|---|---|
| 1 | offline gate | `GATE_EXIT=0` (140 s). Re-run after the route split (§6 item 5): `GATE_EXIT=0` (`gate-offline-run2.txt`). |
| 2 | migration | none needed — no backup, dry run, apply or types. |
| 3 | tsc | `TSC_OWN_EXIT=0`; again after the route split (`tsc-run2.txt`). |
| 4 | build | run 1 red: `check-masked-reads` named two new `employees` reads in `leaveRows.ts` / `reviewsRows.ts` → changed to `employees_masked` (id, code, name only); run 2 `BUILD_OWN_EXIT=0` (97 s); run 3 red after the route split: `check-nav-routes` reads a route as an export only when its last segment is `export` → renamed; run 4 `BUILD_OWN_EXIT=0`. |
| 5 | full gate | `GATE_EXIT=0` — 20:22:07 start, verdict at 1,043 s (verdicts 810 s); 298 fixtures. Ran on the tree **before** three app-only changes (notifications "N unread" label, the `te2b2probe` prefix, the export-route split); none touches the database, and offline gate run 2 + build run 4 cover the final tree. |
| 6 | i18n | `I18N_OWN_EXIT=0` |
| 7 | error-swallowing | `SWALLOW_OWN_EXIT=0` (0 unallowed). |
| 8 | layout survey | 20 touched pages (every capped page, both Q1 pages, notifications, `/inbound`, payment terms, and the 5 detail pages with 「受限」 sites). **390 px: 19 / 20** — `/inbound` +59 px, culprit a toolbar `select`; **the same page from HEAD reads the same +59 px** (`layout-390-inbound-before.txt`), so it is not this cut (registered, §4). 0 clipped. **1280 px: 20 / 20**, 0 / 0, self-test passed — on the third run: run 1 `fetch failed` at start, run 2 the probe's self-test failed on a class-less `<body>` (registered, §4). |
| 9 | smoke | run 1 `SMOKE_EXIT=1`: 332 ok, 2 failed — `/operation/capture/export` and `/operation/contamination/export` answered 400 without `?table=` → split into one route per table (§6 item 5). **Run 2 `SMOKE_EXIT=0`: 336 ok, 25 skipped (no data), 0 failed**, 43 min 57 s. |
| 10 | live proof | **`TE2B2_PROOF_EXIT=0`, 23 / 23** (§3). Run 1 kept (`live-proof-run1-criteria.txt`): 22 / 26 — my criteria read the inbox `#id` from the first cell (it is the row-expand control) and expected "2,005"; the pager printed "2005", which is now formatted like every other cap notice. |
| 11 | COD byte check | before and after, `COD_OWN_EXIT=0`: COD-2026-0001 34,701 bytes `ba299a4f3488fc543cdd1f410fabf6523434d39caa0dc58d6f376309c1f42101`; COD-2026-0002 34,746 bytes `717661f6a8166b5f9342324586208e21f29c217aa5d3c047b009e00f2513a4f9` — equal to the `AGENTS.md` baseline. |
| 12 | fresh clone, no `.env.local`: `npm ci && npm run build` | in the close report (it builds the commit that contains this file). |

## 3 · Live proof (`readings/live-proof.txt`; `next start` on this tree against live; real headless Chrome; files read back)

- **I · inbox** — live `ingest_inbox` 2,005 rows (as `postgres`, base table) → 11 pages. Page 1: 200 rows, pager "Page 1 of 11 · 2,005 messages"; page 2: 200 other rows, newest #1805 < page 1's oldest #1806; page 11: 5 rows (= 2,005 − 2,000). Export pressed on page 2: CSV **2,005** rows, Excel **2,005** rows (count 2,005 before and after).
- **R · a reader without the price codes** (purchasing / inbound / inventory view codes only) vs a control holding `data.view_purchase_prices` + `data.view_prices`, on PO-2026-0001 (USD, percentage terms, a priced receipt): **R1** header "USD @ Restricted" (control "USD @ 1") · **R2** term amounts Restricted ×3 (control 84,000.00 / 24,000.00 / 12,000.00) · **R3** receipt unit price Restricted (control 12.0000) · **R4** `/inbound` "Unpriced batches: Restricted" (control: no such line) · **R5** `/inventory/output/<material>` cost value total "Restricted" (control 253.34).
- **N · unread** — as the throwaway reader in a rolled-back transaction: 2 visible, 0 read → 2 unread; the page says "2 unread", the bell shows "2".

**Read back after the live steps** (`readback.json`, `recon.txt`): 7 users, 7 enabled, 0 throwaway users / roles, 0 orphan grants; role codes held admin · cco · cfo · cto · finance · gm · warehouse (unchanged); approvals ON (`finance` / `cfo` / 1000); `require_calibrated_since` NULL; 2 CODs. Reconciliation as tim@ (rolled back): AP and AR agree, unexplained **0.00 / 0.00**.
Not touched: the portal access-token hook, the `portal-uploads` and `claim-receipts` buckets and their policies. Nothing committed on live except the throwaway accounts and grants, removed by the shared helper's plan.

## 4 · Registered, not fixed (`docs/known-issues.md`)

- **INBOUND-TOOLBAR-390-OVERFLOW** — `/inbound` +59 px at 390 px, a toolbar `select`; same on HEAD; most likely live option text (inferred, not measured per option).
- **SURVEY-SELFTEST-CLASSLESS-BODY** — one 1280 px self-test failure on a page that was not the app's root layout; did not recur; the diagnostic should print `location.href` and `document.title`.
- **LEDGER-EMBED-OUT-OF-MASKED-READS-SIGHT** — the ledger's select is now composed from constants, so `check-masked-reads` no longer sees its (unchanged) `inbound_batches` embed; the baseline was **not** tightened.
- **PAGES-TOO-SLOW-TO-USE** (Part 1.6).

## 5 · Assertions in the briefs measured false

1. **Step 0 report (mine), quoted in ruling Q2:** "15 of the 17 sites sit on exempt tables". Measured: 10 sites on 7 exempt tables, 6 in headers / summary lines, 1 on the exported templates table. TABLE-EXPORT-3 lists the 7 files.
2. **The 15 s correction's source:** Tim wrote "the PAYROLL-PAY-REVERSAL-1 close-out production check … recorded in the TABLE-EXPORT-1 session's Part 1 reading". The line is `docs/surveys/CLAIM-RECEIPTS-1/readings/closeout-production-check-2.txt:3` — **CLAIM-RECEIPTS-1's** close-out check, run in the PAYROLL-PAY-REVERSAL-1 session's Part 1 (2026-10-22 09:51 CST); the PPR-1 close-out reading in TABLE-EXPORT-1's readings has no dictionaries line. Both recorded.
3. **Original brief:** "/settings/dictionaries took 15–45 s" — at Step 0 no 15 s reading was found; it exists (item 2).
4. Line numbers: `/hr/reviews` limit at :57 (brief :56); ledger filter :86–89 (brief 84–90). The inbox's 2,005 held.

## 6 · Decisions taken without asking

1. **Each capped `CellsTable` page exports through a route that returns rows carrying only their typed `exports`**, built by the same server function the page uses (`CellsExport.serverRows`).
2. **Ledger:** the notice and code say 1,000 (what PostgREST actually returned for `.limit(2000)`); the PDF reads the same first 1,000.
3. **Leave keeps "pending first"** — applied by the shared mapping to the page's 300 and to the full export alike.
4. **Notifications page now states the number** ("N unread", `data-unread-count`) — before, the count only decided whether "Mark all read" showed, so there was nothing on the page to match against the database.
5. **One export route per table** (`/operation/capture/{pending,recent}/export`, `/operation/contamination/{grid,checks}/export`) instead of one route with `?table=` — smoke showed the shared route answering 400 when called bare.
6. **Inbox page size 200** — the same first screen as before.
7. **Three reads that fed a fixed site moved from `?? []` / `.data` to `mustRows`** (employee payroll, inbound drill valuation, payment-term template lines): a failed read is an error page, not "no rows".
8. **The inbound badge for a reader without the price code says "Unpriced batches: Restricted"** (new key `inbound.unpricedBadgeRestricted`); the `pricing_status` count beside it is unchanged.
9. Throwaway prefix `te2b2probe` (added to `scripts/ephemeral.mjs`); the 2b-1 close-out reused `te2b1probe`.

## 7 · Measured costs, for the next estimate

offline gate 140 s · full gate 1,043 s (verdicts 810 s) · build ~97 s · smoke 2,637 s (run 2; run 1 42 min) · layout ~190 s per width for 20 pages · live proof ~6 min · no backup (no migration).
