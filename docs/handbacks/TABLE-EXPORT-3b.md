v1.4.72 — Every table on the detail pages of finance, purchasing, sales, inbound, inventory and hr exports to Excel and CSV, total rows included; masked cells and masked totals write "Restricted"; the attendance grid, quote lines, review goals, permission matrix (plus a list of every data and action code), leave types, rating scale, KPI scores, the /me self-assessment and the payment-term template and pricing formula edit pages export their saved values; the 14 entry forms and the calculator are permanent exemptions.

# TABLE-EXPORT-3b — hand-back (2026-10-25)

Brief: "TABLE-EXPORT-3b" (Step 0, 2026-10-24) and Tim's rulings Q1–Q4 of 2026-10-25, recorded at their source:
`docs/table-export.md` § "The rulings — Tim 2026-10-25 (TABLE-EXPORT-3b Step 0)". Queue entry `docs/forward-queue.md` 64b-2.
Started from `f5f6054b233a929c87c43976f4841bb861e8c62e` (HEAD = origin/main = ls-remote, tree clean). Step 0 survey: `docs/surveys/TABLE-EXPORT-3b/step0.md`;
readings: `docs/surveys/TABLE-EXPORT-3b/readings/`. **No migration**, so no backup, no dry run and no window.

## 0 · Part 1 — TABLE-EXPORT-3a close-out (2026-10-24)

- **Production check:** `db/scripts/2026-10-24-table-export-3a-closeout-prod-check.mjs` → `TE3A_CLOSEOUT_EXIT=0`, 5 / 5 (`readings/closeout-prod-check.txt`, 16:28 CST).
  - A throwaway finance account exported the P&L as Excel. The page returned HTTP 200, and the file's net profit (−44718.53, a number cell) equals the screen's −44,718.53.
  - A reader without `data.view_pay` sees "Restricted" on `/finance/payroll-payments`.
  - Afterwards: 0 throwaway accounts, roles or orphan grants (`readback-closeout.txt`).
- **Ruling recorded (Tim 2026-10-24):** the change-history export moved into go-live readiness row 13, with the Q7 text verbatim and the 3a measurement. It is in that row and in `docs/known-issues.md` § CHANGE-HISTORY-NO-EXPORT; 64b is marked closed.

## 1 · Against each scope item and ruling

| Item | Result |
|---|---|
| A · finance (13 files, 17 tables) | Exported: asset cost entries · bank statement lines · credit-note lines · expense lines · freight allocations · GST filing-request boxes (one pair per open request) · F5 boxes + box detail · invoice lines · journal lines · account ledger · payment-request allocations · payment allocations · supplier statement (4 tables). |
| A · purchasing (3) | PO lines · PO payment terms · PO receipts. |
| A · sales (4) | Customer attachments · customer open items · order lines · shipment lines. |
| A · inbound (5) | Assay metals · assays · batch margin · prepayment applications (**rebuilt as a DataTable**, accepted decision) · price history. |
| A · inventory (2) | Inbound and output material batches. |
| A · hr (4 files, 7 tables) | Employee training / reviews / pay history · leave grant breakdown + consumption · overtime batch lines · payroll period lines. |
| The 7 「受限」 tables | Every cell the screen draws as 「受限」 writes "Restricted" (`xMasked` or `xRestricted` under the screen's own condition). **Proven live** for PO lines, output batches and employee pay history (§3 R1–R3). No screen fix was needed: every masked cell in 3b already drew 「受限」. |
| Q6 · history trails | Price history, prepayment applications, pay history and leave consumption exported. Price history **proven live** (§3 T). The shared `SettlementHistoryTable` and `MovementTimelineTable` stay in 3c (accepted decision). |
| Q1 (2026-10-25) · total rows | Exported as the last rows, exactly as on screen: credit note, journal, ledger, payment allocations, PO net / tax / gross, payroll lines, **and the bank statement**, which Q1's list leaves out but its rule covers (noted under the ruling in `docs/table-export.md`). A masked total writes "Restricted" (journal; PO, **proven live** §3 R1; payroll). The ledger total is not masked on screen (`account_ledger.sql`, "合计不遮"), so it exports as a number. |
| E · the 8 editable tables (Q8) | Exported from their saved values: attendance grid · quote lines · review goals (both pages) · permission matrix · leave types · rating scale · KPI scores · /me self-assessment (one pair per open review). **Leave types proven live** (§3 E). Attendance not measurable (live has 0 attendance periods, as `postgres`, base table). |
| Q2 (2026-10-25) · permission matrix | Two pairs: the module matrix (Module · View · Edit) and every card code (Permission · Code · Granted). Both read the saved grants (`initial`), never unsaved ticks. **Proven live**: the finance role's card export lists `data.view_pay` · Yes (§3 M). |
| Q3 (2026-10-25) | TemplateForm and FormulaForm export on their **edit pages only** (the spec is passed only when a saved record exists), writing the saved lines. Masked template amounts and formula terms write "Restricted". CalculatorForm is PERMANENT, "calculator; nothing is saved". |
| The 14 entry forms | PERMANENT, "entry form; the saved record exports from its own page". |
| Mechanism | `EditableTable` takes `exportSpec` + `exportRows` (saved rows for page-owned tables); each column declares `exportAs` (runtime refusal by name otherwise). `scripts/check-table-export.mjs` accepts an `EditableTable` whose own props carry `exportSpec=` (accepted decision). |
| Pay history order (accepted decision) | **Already sorted newest first in the loader** (`hr/employees/[id]/page.tsx:195-197`). My Step 0 statement that it was unordered was false (§5); nothing changed. |
| Q4 | Not split; the whole scope fit. |

**Exemption list at close** (`node scripts/check-table-export.mjs`): **TABLE-EXPORT-3 37 · PERMANENT 22** (59 entries). 93 − 41 converted − 15 made PERMANENT = 37.
All 37 are 3c: operation 12 · shared components 8 · logistics 3 · output 3 · quality 3 · safety 2 · stocktakes 2 · suppliers 2 · contracts 1 · materials 1.
PERMANENT = the 7 from 3a + 14 entry forms + CalculatorForm.

## 2 · Verify chain (in order)

| # | Step | Reading |
|---|---|---|
| 1 | offline gate | `GATE_EXIT=0` (`gate-offline.txt`). |
| 2 | migration | none. |
| 3 | tsc | `TSC_OWN_EXIT=0` (17 s). |
| 4 | build | Run 1 `BUILD_OWN_EXIT=1`: the lint ratchet named one new unused variable in the new proof script (`build-run1-unused-var.txt`); removed. **Run 2 `BUILD_OWN_EXIT=0`** (96 s). |
| — | proof dry run | Before the gate, so that a fix to its criteria would land before the gate rather than after it: `TE3B_PROOF_EXIT=0`, 30 / 30 (`live-proof-run1.txt`). Nothing changed after it. |
| 5 | full gate on the final code | `GATE_EXIT=0` (15:25:58 → 15:43:48, ≈ 1,070 s; `gate-full.txt`). Only docs changed after it: this hand-back and the queue line. |
| 6 | i18n | `I18N_OWN_EXIT=0` (four new keys: `permissions.grantedCol`, `purchasing.appliedHistoryCol.{amount,at,journal}`). |
| 7 | error-swallowing | `SWALLOW_OWN_EXIT=0`. |
| 8 | layout survey | One detail page per 3b module + every editable-table page + both edit pages = 16 measurable. **1280 px: 16 / 16, 0 overflow, 0 clipped. 390 px: 15 / 16 at 0; `/sales/quotes/[id]` at +8 px**: culprit the add-line material `<select>`, the **pre-existing** `AT1B2-QUOTE-PAGE-390-OVERFLOW` (same 8 px, same culprit, `docs/known-issues.md:10345`). Not caused here. `/hr/attendance/[id]` not measurable: 0 attendance periods on live (`layout-390-run1-attendance-not-measurable.txt`). Self-test passed both times. |
| 9 | smoke | **`SMOKE_EXIT=0`: 336 ok, 25 skipped (no data), 0 failed** (15:59 → 16:38, ≈ 39 min). |
| 10 | live proof | **`TE3B_PROOF_EXIT=0`, 30 / 30** (`live-proof.txt`, §3). |
| 11 | COD byte check | `COD_OWN_EXIT=0`: COD-2026-0001 34,701 bytes `ba299a4f3488fc543cdd1f410fabf6523434d39caa0dc58d6f376309c1f42101`; COD-2026-0002 34,746 bytes `717661f6a8166b5f9342324586208e21f29c217aa5d3c047b009e00f2513a4f9`. Both equal the `AGENTS.md` baseline. |
| 12 | fresh clone, no `.env.local` | In the close report. |

## 3 · Live proof (`readings/live-proof.txt`; `next start` on this tree against live; real headless Chrome; files read back)

Throwaways (prefix `te3bprobe`, shared helper):

| Account | Codes |
|---|---|
| `poblind` | `module.purchasing.view` |
| `posees` | `module.purchasing.view` + `data.view_purchase_prices` + `data.view_prices` |
| `invblind` | `module.inventory.view` |
| `hrblind` | `module.hr.view` |
| `inbsees` | `module.inbound.view` + both price codes |
| `perms` | `action.manage_permissions` |

- **R1 · PO-2026-0009** (taxed, 1 line):
  - For `poblind` the screen shows "Restricted". The Excel and CSV files each hold 4 rows: the line, with unit price and amount Restricted, then "Subtotal (excl. GST)", "GST" and "Total payable (incl. GST)", all three **Restricted**.
  - For `posees` the same three rows are numbers (333049.5 · 29974.46 · 363023.96; CSV "… SGD"), and nothing in the file reads Restricted.
- **R2 · MAT-2026-0001 output batches:** for `invblind` the screen shows "Restricted", and 6 batch rows carry 2 Restricted cells each (unit cost, cost value) in Excel and CSV.
- **R3 · EMP-2026-0001 pay history:** for `hrblind` the screen shows "Restricted", and the one pay row reads `2026-07 · Restricted ×5 · Posted` in Excel and CSV.
- **T · IN-2026-0001 price history** (a trail): 2 rows in the file = 2 `price_history` rows in the database (as `postgres`, base table), with number cells in each row.
- **E · /hr/leave/types** (editable): 13 rows on screen = 13 rows in Excel and in CSV.
- **M · finance role:** the module matrix exports 18 rows (Module · View · Edit). The card-code export has 51 rows, every one `data.*` / `action.*`, and includes `View pay · data.view_pay · Yes`, in Excel and CSV.

Read back after the live steps (`readback.txt`, as `postgres`, counts only):
- 7 users, 7 enabled; 0 throwaway users and 0 throwaway roles; 0 orphan grants; 0 clean-up plans.
- Role codes admin · cco · cfo · cto · finance · gm · warehouse (unchanged).
- Approvals ON (`finance` / `cfo` / 1000); `require_calibrated_since` NULL; 2 CODs.
- Reconciliation as tim@ (rolled back): AP and AR agree, unexplained **0.00 / 0.00**.
- Not touched: the portal access-token hook, `portal-uploads`, `claim-receipts`.

## 4 · Decisions taken without asking

1. **Bank statement total row** exported under Q1's rule (its list omits it); noted at the ruling.
2. **A PO payment-terms read fixed:** the query never selected `id` or `expected_date`, so the expected date always showed "—" and the date control got no term id. Both columns are now read; both are in `purchase_order_payment_terms_masked`. Visible change: expected dates appear.
3. **Currency where the screen states it only in a page header** (PO lines and terms, bank statement, template fixed amounts): the file carries the document currency in the number format, since a file has no header card.
4. **Composite cells** export the main value, with the choice commented beside the column. Examples: the journal's foreign amount without its rate; price history's original price without its rate and as-of date; ScoreEditor's KPI cell as "title · weight · target". Reversed or voided rows say so in their main cell (precedent `rowInactive`).
5. **One export pair per rendered table**, including one per open GST filing request and one per open self-assessment review.
6. Throwaway prefix `te3bprobe` (added to `scripts/ephemeral.mjs`).

## 5 · Assertions measured false

1. **Step 0 (mine): "the pay-history query has no `.order`, so rows come back in arbitrary order."** The query has no order, but the loader sorts newest first (`hr/employees/[id]/page.tsx:195-197`). The accepted "sort by period" decision needed no change.
2. Brief / Q8: "17 entry forms … the saved record exports from its own page": false for three (Step 0 §2). Ruled in Q3.
3. Two sub-survey claims, already in the Step 0 report: ScoreEditor blank cells, and the shared TemplateForm.

## 6 · Registered, not fixed

- **PAYMENT-TERM-TEMPLATE-EDIT-MASKED-AMOUNT-BLANK** (`docs/known-issues.md`): on the template edit page a masked fixed amount is an empty input box, not 「受限」; saving could send it back as empty. Same family as EMPLOYEE-EDIT-CLEARS-MASKED-IDENTITY.
  Today: 0 roles hold `module.purchasing.edit` without `data.view_prices`, and 0 template lines carry a fixed amount (as `postgres`). The export is unaffected (it writes Restricted).

## 7 · Measured costs, for the next estimate

| Step | Cost |
|---|---|
| offline gate | (`gate-offline.txt`) |
| tsc | 17 s |
| build | 96 s |
| full gate | ≈ 1,070 s |
| layout | ~173 s (390) / ~180 s (1280) for 16 pages |
| smoke | ≈ 2,350 s |
| live proof | ~5 min |

No backup. The per-table work ran as five parallel conversion agents on disjoint files (wall clock not measured).
