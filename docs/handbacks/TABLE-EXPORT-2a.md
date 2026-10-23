v1.4.68 — Every finance list page now has "Export Excel" and "Export CSV" (23 files, every row and every page, restricted cells reading "Restricted"); four finance pages that showed only their latest N rows now say so and export everything; the invoice list says 「受限」 where it said "—"; and the "Sep 202" bug is fixed with the three places it had spread to, one of which would have crashed the CPF button on the payroll-payments page.

# TABLE-EXPORT-2a — hand-back (2026-10-23)

Brief: "TABLE-EXPORT-2" (Step 0) and Tim's rulings Q1–Q10 of 2026-10-22, recorded at their source: `docs/table-export.md` § "The rulings — Tim 2026-10-22 (TABLE-EXPORT-2 Step 0)".
Started from `8373a498a123ef371c4ad92943a438e0c1d4801c` (HEAD = origin/main = ls-remote, tree clean). Readings: `docs/surveys/TABLE-EXPORT-2a/readings/`.
**No migration** — backup, dry run, apply and types were skipped; there is no broken window.

## 0 · Part 1 — TABLE-EXPORT-1 close-out

| Step | Reading |
|---|---|
| 1.1 | HEAD, origin/main and `git ls-remote origin main` all `8373a498a123ef371c4ad92943a438e0c1d4801c`; tree clean. |
| 1.2 COD bytes | `node docs/surveys/MES-8a/cod-bytes.mjs` (Storage API: list + GET only), `COD_OWN_EXIT=0`. COD-2026-0001 34,701 bytes `ba299a4f3488fc543cdd1f410fabf6523434d39caa0dc58d6f376309c1f42101`; COD-2026-0002 34,746 bytes `717661f6a8166b5f9342324586208e21f29c217aa5d3c047b009e00f2513a4f9` — both equal the MES-8a baseline and `cod_issues.sha256`. Recorded once, in full, in `AGENTS.md` § "两张已签发的 COD —— 字节基线【只记在这里】" (AGENTS.md has no section literally named "live safety"; the new section sits directly under "线上的每一行都是测试数据", the rule that live state keeps every safety rule). |
| 1.3 General ledger past 1,000 | **Unproven until live has more than 1,000 journal lines.** Read as `postgres` (`rolbypassrls = true`), `journal_lines` is a base table: **186 lines / 83 entries**. Added as `docs/manual-walk-list.md` §36.2. No throwaway account was made; readback (counts only, as postgres): 7 users, 0 throwaway-pattern users, 0 orphan grants. |
| 1.4 | TABLE-EXPORT-1 marked closed in `docs/forward-queue.md` item 64. |

## 1 · What changed, against each scope item and ruling

| Item | What | Proof |
|---|---|---|
| A · 23 finance files | Converted: assets · bank transfers · frozen forecasts · recurring lines · claims decided register · month-close and year-close history · freight · GST periods and tax codes · management-pack history · sell positions · self-approved · supplier statements · WHT (3 tables); and the 8 server-paged lists, each with an export route running the page's own read and mapping (shared `<page>Rows.ts`): invoices · journal entries (`/finance/journal/entries/export` — the list, not the general-ledger export) · payment requests · payments · bank statements · credit notes · expenses · FX rates. 25 tables; `check-table-export` 62 → 87 declared. | build check; live proof P1–P3 |
| B · finance hard limits (Q2) | Freight 200 · supplier statements 300 · bank transfers 50 · frozen forecasts 20: the page keeps its N rows; `RowCapNotice` above the table says "Showing the first N of M — narrow the filters or export" when M > N (draws nothing otherwise); the export goes to a route without the limit (`freight/export`, `supplier-statements/export`, `bank/transfers/export`, `cash-forecast/frozen/export`). | live proof B1 (see §3: not past the limit) |
| C · "Sep 202" (Q9) | Four places, one disease (a `formatMonth` display string used as data): ① `/hr/payroll` period cell no longer `.slice(0, 7)` (English "Sep 202"; Chinese Oct–Dec lost 月); ② `/finance/payroll-payments` `cpfDue` gets the raw month — **every unpaid CPF button threw `RangeError: Invalid time value`, in both languages**; ③ `/hr/payroll/[id]/edit` month box gets `toYearMonth` — in Chinese it was empty and save was refused with PERIOD_MONTH_INVALID; ④ `/me` attendance sorts by the raw month. `docs/known-issues.md` § PAYROLL-PERIOD-MONTH-SLICED closed with all four. | `CPF_PROOF_EXIT=0`, 25/25 (control arm bites on every old shape) |
| Q1 split | 2a done here; 2b queued as `docs/forward-queue.md` 64a-2 (v1.4.69) with its rulings verbatim, before TABLE-EXPORT-3. | — |
| Q3 | Registered, not fixed: `docs/known-issues.md` § READ-ALL-STOPS-AT-1000; go-live readiness group row 10. | — |
| Q4 | Registered: § CHANGE-HISTORY-NO-EXPORT; the date-range rule under TABLE-EXPORT-3 (64b). The "show older" notice is 2b. | — |
| Q5 | 2b. | — |
| Q6 | brand-sampler → `cut: 'PERMANENT'` with its reason; `check-table-export` accepts and counts PERMANENT. | build check |
| Q7 | 12 entries → TABLE-EXPORT-3 (11 finance + compliance pack sections), each with its reason. | build check |
| Q8 (finance) | Invoice list: total and open amount masked by `invoices_masked` (data.view_prices) now render 「受限」 via `MaskedValue` and export "Restricted"; a void invoice's "—" stays "—" (it genuinely has no settlement figure). Payroll-payments and settle panels follow Q7. | live proof P1 |
| Q10 | 2b. | — |

Exemption list at close: **TABLE-EXPORT-2 21** (me 8 · settings 5 · safety 3 · tools 2 · compliance 1 · my-reviews 1 · contracts 1) · **TABLE-EXPORT-3 116** · **PERMANENT 1**.

## 2 · Verify chain (every exit read from the script's own line)

| # | Step | Result |
|---|---|---|
| 1 | offline gate | `GATE_EXIT=0` (125 s) on the second run. Run 1 (`gate-offline-run1-swallow.txt`) was red on one line of this cut's own new helper (`inChunks`: `data ?? []` after the error check) — fixed so a missing `data` fails like `fetchAllPages`, not allowlisted. |
| 2–5 | backup · dry run · apply · types | **skipped — no migration** |
| 6 | tsc | `TSC_OWN_EXIT=0` |
| 7 | build | `BUILD_OWN_EXIT=0` on run 3. Run 1 (`build-run1-masked-reads.txt`): the void-invoice count moved into `invoiceRows.ts` read the `invoices` base table — switched to `invoices_masked` (same row predicate, no masked column read) and its own baseline entry tightened; the 11 other slack entries the tool listed predate this cut and were left. Run 2 (`build-run2-nav-routes.txt`): three export routes not ending in an action word looked like unnamed screens to `check-nav-routes` — renamed to `bank/transfers/export`, `cash-forecast/frozen/export`, `journal/entries/export`. |
| 8 | full gate | `GATE_EXIT=0` — verdicts wall-clock 956 s (whole run 00:19:48 → 00:39:30, 19 min 42 s; TABLE-EXPORT-1 measured 757 s): rebuild · mirrors vs live (incl. types) · all fixtures · anon (327) · no-role (126) · portal (42). |
| 9 | i18n · error-swallowing | `I18N_OWN_EXIT=0` · `SWALLOW_OWN_EXIT=0` |
| 10 | layout survey | 22 pages (every converted finance page that has a route of its own, `/finance/payroll-payments`, `/hr/payroll`, and all four part-B pages): 1280 px 22/22 usable, 0 overflow, 0 clipped (`SURVEY1280_OWN_EXIT=0`); 390 px 22/22, 0, 0 (`SURVEY390_OWN_EXIT=0`); self-test passed both times. First screen only; the notice was not on screen anywhere (no live page is past its limit). |
| 11 | smoke | **`SMOKE_EXIT=0` on the first run** — 315 routes + content / nav probes: 316 ok · 25 skipped (no data) · 0 failed (`readings/smoke.txt`, 00:52:50 → 01:32:24, 39 min 34 s; the brief's "about 25 min" is short of every measured run). |
| 12 | live proof | **`TE2A_PROOF_EXIT=0`, 41 / 41 PASS** (`PROOF_BASE` = `next start` on this tree against live; a real headless Chrome clicks the buttons, the downloaded CSV and Excel files are read back; `readings/live-proof.txt`, script `db/scripts/2026-10-23-table-export-2a-live-proof.mjs`). One check per masking family touched, both arms: **P1 prices** `/finance/invoices` "Total" (Q8): reader with `module.finance.view` only 6 / 6 "Restricted" in CSV and Excel, with `data.view_prices` 6 numbers (Excel Number) · **P2 pay** `/finance/journal` "Amount (SGD)": without `data.view_pay` the 4 Payroll rows of 83 are "Restricted" while the other 79 are numbers; with it 4 numbers · **P3 identity** `/finance/credit-notes` "Customer": without `module.customers.view` 1 / 1 "Restricted", with it the name. Excel date cells typed Date; file names per Q9; every About sheet names the reader. **B1** `/finance/freight/export` 4 rows = the CSV's 4 rows, no notice drawn (not past 200 — see §3). **G1** a reader without `module.finance.view` → 403 `EXPORT_DENIED` on `invoices/export`, `bank/transfers/export`, `journal/entries/export`. **C1** `/finance/payroll-payments` as a finance reader: 200, no error boundary. Run 1 (`readings/live-proof-run1-prefix-unregistered.txt`) stopped before creating anything: the shared helper refused the unregistered prefix `te2probe` (added to `THROWAWAY_EMAIL_PREFIXES`). |
| 13 | COD byte check | `COD_OWN_EXIT=0` after every live step (`readings/cod-bytes-after.txt`): COD-2026-0001 34,701 bytes `ba299a4f…c1f42101`, COD-2026-0002 34,746 bytes `717661f6…2513a4f9` — each full digest equal to the `AGENTS.md` baseline. |
| 14 | fresh clone, no `.env.local`: `npm ci && npm run build` | in the close report (it builds the commit that contains this file) |

**Read back as postgres after the live steps** (`readings/readback.json`, `readings/recon.json`): 7 users, 7 enabled, 0 throwaway-pattern users, 0 orphan grants,
role codes held = admin · cco · cfo · cto · finance · gm · warehouse (unchanged); approvals ON (`finance` / `cfo` / 1000); `require_calibrated_since` NULL; `cod_issues` 2 rows;
reconciliation as tim@ (rolled back): AP and AR agree, unexplained **0.00** / **0.00**.
The portal-access-token hook, the `portal-uploads` and `claim-receipts` buckets and their policies were not touched (no migration, no storage change).

## 3 · Not measured, handed to Tim

- **A part-B page exported past its old limit, on live.** Live has freight 4 · supplier statements 0 · bank transfers 0 · frozen forecasts 0 (as postgres, base tables) — none past 200 / 300 / 50 / 20. The proof shows the route returns every row and the page draws no notice when none is due; the notice text and "past the limit" are not observed on live.
- **The health family** (`/finance/self-approved` amount and note): live `approval_log` has 0 `self_decided` rows, so the table is empty for every reader.
- **The CPF button itself, pressed.** Live has no unpaid CPF (PAY-2026-0001's CPF 600.00 is paid), so the button that crashed does not render on live today; and that button calls `payCpf` with no confirmation — pressing it records a real payment, which the live-safety rules forbid for a proof. What stands instead: the exact function the button label calls, run old-shape vs new-shape (`db/scripts/2026-10-23-table-export-2a-cpf-due-proof.mts`), and `/finance/payroll-payments` loading with no error boundary on live (proof C1). Added to `docs/manual-walk-list.md` §36.3.
- Excel / Numbers on a phone for these files — same as §36.1.

## 4 · Assertions in the brief measured false

1. "/settings/change-history holds about 77,000 rows … does its export follow the 50,000 cap" — it has **78,441** rows (as postgres) and **no export at all**: it is a timeline (`AuditTrailList`), not on the exemption list. Ruled as Q4.
2. "57 at TABLE-EXPORT-1 close: finance 34, me 8, settings 5, safety 3, tools 2, compliance 2, my-reviews 1, contracts 1, brand-sampler 1" — **true** (`grep -c "cut: 'TABLE-EXPORT-2'"` = 58 minus the type-comment line; all `DataTable`).
3. The silent-caps register (`LIST-PAGES-SILENT-ROW-CAPS`) said no affected source table passed its cap — `/operation/capture/inbox` reads `ingest_inbox`, 2,005 rows, `.limit(200)`: it is cutting today (2b, real paging per Q2).
4. "Remove the throwaway account and report 0 remaining" (1.3) — no throwaway was needed (1.3 did not run); readback 0.

## 5 · Decisions taken without asking

1. **A row whose state the screen shows only by styling** (inactive recurring line, reversed freight, void invoice, superseded forecast) carries that state as a word appended to its identity cell in the export (`table.export.rowInactive` etc.) — Q11 keeps the columns exactly the table's, and without it a reversed or inactive row reads as live.
2. **One cell, one value**: a foreign-currency payment / expense exports its own-currency amount with its currency; the "= base" beside it is a derived figure and does not get a column. Date ranges, multi-rate cells and receipt lists export as the screen's text built from raw values. Status cells whose screen form is a button export the status text or empty.
3. **Credit notes' customer cell** was a server-built React node; it is now plain data (restricted flag, code, name) the table draws and exports — a node cannot travel through the JSON route. Customer column "Restricted" without `module.customers.view` (identity family).
4. **Reads this cut rewrote now fail loudly** where they were silent: the invoice list's three reads, the bank statement line counts, the credit-note / payment / FX / journal counts (`count ?? 0` → `mustCount`), the expenses filtered total. The statement line counts and journal amounts now page per batch, so they no longer stop at 1,000 lines.
5. **`lib/export/serverRows.ts`** gained `inChunks` (id look-ups in batches of 100) and `exportUnionResponse` (two reads end to end, the invoice list's "all" filter; count first, refuse above 50,000).
6. **`cpfDue` moved to its own file** (`app/finance/payroll-payments/cpfDue.ts`, body unchanged) so the proof can run it.
7. Registered, not fixed: § DISPLAY-TIMESTAMP-SLICED-AS-UTC (management-pack "produced" and frozen-forecast "frozen" show the UTC slice; the export is Singapore time per Q7, so the two can differ by a day before 08:00 SGT) and § INVOICE-LIST-ALL-APPENDS-VOIDS-TO-EVERY-PAGE.
8. Throwaway prefix `te2probe`.

## 6 · Close-out (TABLE-EXPORT-2b Part 1, 2026-10-23)

- **Deployment confirmed by Tim** 2026-10-23 14:41 CST (`025776a9c347cdecbd1ba04cbad08afbd13606be`). No migration, no broken window.
- **Read-only check on production** (`db/scripts/2026-10-23-table-export-2a-closeout-prod-check.mjs` against `https://new-era-erp.vercel.app`,
  `TE2A_CLOSEOUT_EXIT=0`, 5 / 5, `docs/surveys/TABLE-EXPORT-2b/readings/closeout-prod-check.txt`): a throwaway reader holding a copy of the
  `finance` role's 43 codes exported `/finance/invoices` as CSV and Excel — HTTP 200, 6 data rows each = the list's "Total: 6";
  `/finance/payroll-payments` HTTP 200 with no error boundary. Read back as `postgres` (counts only, `closeout-readback.json`): 7 users,
  0 throwaway users, 0 orphan grants, 0 throwaway roles; role codes held unchanged.
- **Measured costs, for the next estimate** (both from this cut's own runs, §2): **full gate 1,182 s** (19 min 42 s, whole run; verdicts 956 s) ·
  **smoke 39 min 34 s** (2,374 s, 315 routes) · offline gate 125–127 s.
