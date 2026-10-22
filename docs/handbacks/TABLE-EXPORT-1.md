v1.4.67 — Every list page in 13 modules gets "Export Excel" and "Export CSV" above its table: the rows as filtered and sorted (every page, not just the one on screen), the table's own columns, restricted cells reading "Restricted", amounts and dates as real Excel numbers and dates in Singapore time, with an "About" sheet saying who exported what and when. The nine old CSV exports are replaced; the five special exports (GST F5, general ledger, AR / AP ageing, management pack) no longer stop at 1,000 rows.

# TABLE-EXPORT-1 — hand-back (2026-10-22)

The brief "TABLE-EXPORT-1" with Tim's rulings on Step 0 (Q1–Q15), 2026-10-22, recorded at their source: `docs/table-export.md`.
Part 1 closed PAYROLL-PAY-REVERSAL-1 (`docs/handbacks/PAYROLL-PAY-REVERSAL-1.md` §6).
Started from `daec5c952939f0ca9aaa5a4335fa188d473ce321` (HEAD = origin/main = ls-remote, tree clean). Readings: `docs/surveys/TABLE-EXPORT-1/readings/`.
**No migration** — Q4 (no logging) and Q10 (no export permission) need none — so backup, dry run, apply and types were skipped, and there is no broken window.

## 1 · What changed, against each ruling

| Ruling | What | Proof |
|---|---|---|
| Q1 / Q15 scope | Converted by whole module: materials 1 · suppliers 3 · sales 8 · output 1 · inbound 1 · inventory 7 · hr 12 · operation 12 · purchasing 4 · quality 4 · margin 1 · stocktakes 1 · logistics 2 = **57 of the 114 list-page files**. The other 57 (finance 34 · me 8 · settings 5 · safety 3 · tools 2 · compliance 2 · my-reviews 1 · contracts 1 · brand-sampler 1) are named on `scripts/table-export-exemptions.mjs` as TABLE-EXPORT-2; the 104 detail / editable / hand-built tables as TABLE-EXPORT-3. **Wider than ruled, see §5 decision 1:** the shared `CellsTable` / `MassTable` now require an export, so their callers on detail pages and in settings, safety and finance/electricity got one too. | `check-table-export` (in the build) |
| Q2 rows | A table that holds every row exports the rows it holds, sorted and filtered as displayed, not paged. Nine server-paginated pages (materials · suppliers · customers · output · inbound · hr/employees · operation/processing · purchasing/orders · stocktakes) got a JSON route next to the page that runs **the page's own read and row mapping** (extracted to a shared server-only module) in batches of 1,000 with a unique tie-break order. Every column exports, phone-hidden ones included; selection does not narrow it. | live proof F1 (server route), F2–F4 (client rows) |
| Q3 restricted | Each column's `exportAs` uses the cell's own test (`xMasked` = `<MaskedValue>`'s rule) → "Restricted" / 「受限」, never blank. Purchase-order totals now also render 「受限」 on screen (they rendered "—", the same as "tax never calculated"). **`inbound` has no unit-price column on screen, so under Q11 its export has none either** — the old empty cell is gone with the column, not turned into "Restricted". | live proof F1–F4, both arms |
| Q4 logging | None. `docs/pdpa.md:119-148` unchanged. | — |
| Q5 the 14 exports | Nine replaced: materials, suppliers, customers, output, inbound rewritten as JSON row routes; the four inventory report routes deleted with their buttons. Suppliers and customers keep short name, tax ID, payment terms, incoterm, credit rating and address as a declared `extension` (the check allows `extension` on those two tables only). The five special exports keep their layouts. | build check ④ |
| Q6 language | Headers are the table's own `t()` headers; row labels were already localized per interface language. | — |
| Q7 time | Timestamps → Singapore wall-clock as real Excel date cells (`yyyy-mm-dd hh:mm`), CSV `YYYY-MM-DD HH:mm:ss`; calendar dates → date cells. DATE1-CSV-UTC noted as closed for the unified export only. | writer probe; live proof (Date cells) |
| Q8 cap | `exportRowsResponse`: count first; above 50,000 → HTTP 413 `EXPORT_TOO_MANY_ROWS` with the count, the page says "This table has N matching rows; one export is limited to 50,000…". Paging stops on an empty page, not a short one. | paging proof P1–P4 |
| Q9 names | `exportFileName`: `<slug>_<YYYY-MM-DD>_<HHmm>.<ext>` in Singapore time; a non-ASCII slug is refused. | writer probe; live proof (file names) |
| Q10 permission | None. Each JSON route checks the page's own `canEnter(<same permission>)` → 403 `EXPORT_DENIED`. | live proof G1 |
| Q11 columns | Exactly the table's columns (control columns `exportAs: false`), plus the Q5 extension. | — |
| Q12 About | Second sheet "About": table, filters (the page's query parameters, or the filters the page states), rows, exported by (email; "could not be read" if the session check does not answer), exported at (SGT), language. CSV is data only. No totals row. | live proof (About "Exported by") |
| Q13 library | `exceljs` **4.4.0** pinned exactly, **MIT**; loaded by `await import('exceljs')` only on click. Its dependency tree: 194 packages — 172 MIT, 13 ISC, 2 Apache-2.0, 2 BSD-3-Clause, `jszip` (MIT or GPL-3.0, used as MIT), `pako` (MIT and Zlib), `big-integer` (Unlicense), `chainsaw` (MIT/X11) and **`buffers@0.1.1`, which declares no licence at all** (pulled in through exceljs's xlsx reader `unzipper`; it is in the installed tree, so it is reported). | §4 |
| Q14 layout | 13 pages (one per converted module, all nine paginated pages among them) at 390 px and 1280 px. | §2 step 9 |
| Q15 special exports | General ledger and the filed F5 snapshot read row sets → now `fetchAllPages` (ordered by `line_id` / `box`). AR ageing, AP ageing and the unfiled F5 return one `jsonb` value, the management pack reads one row — the cap cannot cut them; fixture 291 pins those shapes and proves the GL source returns 1,002 of 1,002 rows on a rebuild while a 1,000-row read returns 1,000. | fixture 291 (+ 4 injections), paging proof P5 |
| also | Registered, not fixed (Tim): `docs/known-issues.md` § SPECIAL-EXPORTS-NO-MODULE-CHECK. Queued TABLE-EXPORT-2 and -3 as items 64a / 64b, before the go-live readiness group. | — |

## 2 · Verify chain (every exit read from the script's own line)

| # | Step | Result |
|---|---|---|
| 1 | offline gate | `GATE_EXIT=0` (127 s, first run; fixture 291 ✓) |
| 1b | fixture 291 fault injections | **4 / 4** bite + baseline, `INJ_OWN_EXIT=0` (`db/scripts/2026-10-22-table-export-1-fixture-injections.py`). First run 3 / 4: the harness appended a function mirror without its terminating `;` (mirrors are exact `pg_get_functiondef` bytes) — a harness bug, fixed, not a fixture miss. |
| 1c | paging proof | `PAGING_PROOF_EXIT=0` (P1–P5, `db/scripts/2026-10-22-table-export-1-paging-proof.mts`); injecting "stop on a short page" turns P2 red (500 of 2,500). |
| 2–4 | backup · dry run · apply | **skipped — no migration** |
| 5 | types | **skipped — no migration** (schema unchanged; the full gate's types comparison is green) |
| 6 | tsc | `TSC_OWN_EXIT=0` (third run: the first two were red only in stale `.next/types` and `.next/dev/types` that still pointed at the four deleted report routes; the build regenerated the first, the second was a stale `next dev` cache and was removed) |
| 7 | build | `BUILD_OWN_EXIT=0`, first run (all static checks incl. the new `check-table-export`) |
| 8 | full gate | `GATE_EXIT=0` (757 s), first run: rebuild · mirrors vs live (incl. types) · all fixtures (291 ✓) · anon (327) · no-role (126) · portal (42) |
| 9 | i18n · error-swallowing | `I18N_OWN_EXIT=0` · `SWALLOW_OWN_EXIT=0` |
| 10 | layout survey, 13 pages | 1280 px: 13 / 13 usable, 0 overflow, 0 clipped (`SURVEY1280_OWN_EXIT=0`). 390 px: first run **void** — the instrument's own self-test failed (an injected 900 px div read 0), so it measured nothing (`readings/layout-390-run1-selftest-failed.txt`); retried once immediately: self-test passed, 13 / 13 usable, 0 overflow, 0 clipped (`SURVEY390_OWN_EXIT=0`). The other 44 converted list pages and every CellsTable / MassTable caller: **not measured**. |
| 11 | smoke | **`SMOKE_EXIT=0` on the third run** — 303 routes + content / nav probes: 304 ok · 25 skipped (no data) · 0 failed (`readings/smoke.txt`, 39 min). Run 1 (`readings/smoke-run1.txt`, 42 min): 302 ok, 2 failed — `/sales/orders/[id]` HTTP 503 from `ConnectTimeoutError` to the Supabase auth host, and `/settings/change-history` HTTP 500 from a statement timeout reading `change_log_rows`; neither file is touched by this cut. Run 2, retried immediately (`readings/smoke-run2-aborted.txt`): aborted at route 93 with `fetch failed` (82 ok, 0 failed before it). Before run 3 the auth host was measured answering in 0.6–1.3 s; run 3 passed both routes. Each run's cleanup read back 0 throwaway users, 0 orphan grants. |
| 12 | live proof | **`TE1_PROOF_EXIT=0`, 44 / 44 PASS** (`PROOF_BASE` = `next start` on this tree against live; a real headless Chrome clicks the buttons and the downloaded files are read back; `readings/live-proof.txt`, script `db/scripts/2026-10-22-table-export-1-live-proof.mjs`). One check per masking family present on a converted list table, both arms: **F1 purchase prices** `/purchasing/orders` (server route) "Subtotal (excl. GST)": restricted reader 7 / 7 "Restricted" in CSV and Excel, permitted reader 7 numbers (Excel Number) · **F2 prices** `/inventory` "Stock Value (SGD)": 4 / 4 vs 3 numbers (the fourth row has no price) · **F3 pay** `/hr/payroll` "Gross total": 1 / 1 vs 1 number · **F4 health** `/hr/claims` "Amount": 1 / 1 vs 1 number; Excel date cells typed Date on F1 / F3 / F4; every file name matches Q9; every About sheet names the reader. **G1** a reader without `module.purchasing.view` → `/purchasing/orders/export` HTTP 403 `EXPORT_DENIED`. Read-only: nothing committed on live but the throwaway accounts (prefix `te1probe`), removed by the plan. First run printed every PASS but **no verdict line** — its exit hook was async and the shared helper does not await it (`readings/live-proof-run1-no-verdict-line.txt`); fixed (browser closed before the hook) and re-run. |
| 13 | fresh clone, no `.env.local`: `npm ci && npm run build` | in the close report (it builds the commit that contains this file) |

**Read back as postgres after the live steps** (`readings/readback.txt`): approvals ON; 7 real accounts enabled, roles admin · finance · warehouse · cto · cco · cfo · gm unchanged;
throwaway users 0 · orphan grants 0; `require_calibrated_since` NULL; reconciliation as tim@ (rolled back): AP and AR agree, unexplained **0.00**.
**The two CODs:** 2 rows; **not byte-compared** — this session took no before-hash, and the previous readback's identifiers are not a hash I can reproduce.
What stands instead: this cut has no code path that touches `cod_issues` (0 occurrences in the diff or the new files), and the only live writes were throwaway accounts.
The portal-access-token hook, the `portal-uploads` and `claim-receipts` buckets and their policies were not touched (no migration, no storage change).

## 3 · Not measured, handed to Tim

- **An export opened in real Excel / Numbers on a phone** (`docs/manual-walk-list.md` §36) — the live proof reads the files back with exceljs and a CSV parser, which checks types and values, not how Excel shows them (currency in the number format, column widths, the About sheet).
- **The 413 refusal on a real table** — no live table has more than 50,000 matching rows; it is proven against a stub (P3).
- **The four masking families with no restricted column on a converted list table** — identity, banking, reviews, sales records: nothing to check in this cut.

## 4 · Assertions in the brief measured false

1. "About 19 places in app/ have their own hand-written CSV export" — **14** (`find app -type d -name export`; 10 hand-rolled their CSV, 4 used `lib/csv.ts`). Recorded in Step 0.
2. Q3 "this also fixes inbound/export's empty cell" — the inbound table shows no unit price, so under Q11 the export carries no unit-price column at all (see §1 Q3).
3. Q15 "a fixture or proof shows each one returning more than 1,000 rows on a rebuild" — the 1,000-row cap belongs to PostgREST, which the rebuild does not have (no `postgrest` or `docker` on this machine, measured), and live may not hold committed proof documents. What was proven instead: fixture 291 on the rebuild (GL source 1,002 / 1,002; the four value sources are single values), the paging code against a 1,000-cap stub (2,500 / 2,500), and the routes' read shapes statically (P5).

## 5 · Decisions taken without asking

1. **CellsTable / MassTable require `exportSpec`**, so every caller (17 pages beyond the 12 operation files — operation detail pages, `/settings/pending-values`, `/safety/inspections/[id]`, `/finance/electricity` and its detail) got an export now. The text check cannot see a wrapper's call sites; a required prop makes `tsc` see every one. This pulls some TABLE-EXPORT-3 detail tables into this cut.
2. **A money / quantity cell carries the currency or unit the screen writes inside the cell** (`xMoney(v, ccy)`, `xNum(v, kind, unit)`): Excel keeps a summable number with the word in its number format; CSV writes `1234.5 USD`. Where the header names it ("Value (SGD)", "(kg)"), the cell stays bare. 34 cells in 20 files carry one; purchase orders carry each order's own currency.
3. **A cell the screen shows as two things exports one**: date ranges as text from the raw dates; badges (expired, ⚠ unapplied prepayment, below expected) dropped where the value they summarise is exported; composite cells (work-order progress, a chase promise) as the screen's text.
4. **The four inventory report routes are deleted**, not rewritten — those pages are not paginated, so the table already holds every row.
5. **Two page reads that swallowed their error became `mustRows`** (purchase orders, hr employees — both silently drew an empty table on a failed read at HEAD) — the refactor made them visible to `check-error-swallowing`.
6. **Pages with a silent row cap export what they show** (sales orders / quotes 200, claims / leave 300, reviews 200; ledger and storage safety stop at 1,000) — registered as LIST-PAGES-SILENT-ROW-CAPS, not fixed. Also registered: PAYROLL-PERIOD-MONTH-SLICED ("Sep 202" on `/hr/payroll`).
7. **Throwaway prefix `te1probe`**; fixture 291; message key `units.hour` added for MTBF / MTTR.
