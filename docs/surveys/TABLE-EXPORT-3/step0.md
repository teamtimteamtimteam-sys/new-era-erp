# TABLE-EXPORT-3 — Step 0 survey (2026-10-23)

Read-only, from source at `da33da46f3f7e38d5afcc64733a567c854271547`. No browser sweeps, no database reads except the Part 1.2 close-out check.
Counts are from `scripts/table-export-exemptions.mjs` imported and grouped by `cut` / `kind` (not `grep -c`, which also counts the JSDoc line at :14).

## 0 · The count

`TABLE-EXPORT-3` = **116 entries in 115 files** (`ForecastGrid.tsx` has a `DataTable` entry and a `table` entry) + 1 `PERMANENT` = 117 total.
Build check's own line: `豁免 117 条(TABLE-EXPORT-3 116 · PERMANENT 1)`. By kind: DataTable 78 · EditableTable 25 · hand-built `table` 13.

## 1 · Classification

| Kind | Entries | What |
|---|---|---|
| **A** detail-page tables and shared detail components | **70** (96 table instances) | document lines 23 · sub-lists 20 · history/trails 12 · computed panels 10 · attachments 4 · layout table 1 |
| **B** hand-built finance reports | **9** | trial balance · P&L · balance sheet · cash-flow summary · cost variance · month-end · payables · receivables · cash-forecast grid (`table`) |
| **C** Q7's 12 non-list entries | **12** | previews / report bodies 8: depreciation · revaluation · cash-forecast lines (`DataTable`) · list-vs-ledger · management pack · price exposure · cash-flow detail · compliance-pack sections; forms / panels 4: bank import · electricity new · payroll-payments · processing-cost settle |
| **E** editable (data-entry) tables — **not named in the brief** | **25** | 17 entry forms for a record not yet saved · 8 that are the only screen of a saved record |
| | **116** | |

### A · per module (files / table instances)

operation 12 / 25 · finance 13 / 17 · shared components 9 / 9 · hr 5 / 8 · inbound 5 / 5 · output 3 / 5 · quality 3 / 5 · logistics 3 / 4 · sales 4 / 4 ·
purchasing 3 / 3 · safety 2 / 3 · inventory 2 / 2 · stocktakes 2 / 2 · suppliers 2 / 2 · contracts 1 / 1 · materials 1 / 1. **Total 70 / 96.**

Effort (inferred from columns, cell kinds and data path): S 32 · M 28 · L 10.
L = `finance/supplier-statements/[id]/StatementDetailTables` (4 tables) · `hr/employees/[id]/EmployeeTables` · `hr/reviews/cycles/page.tsx` ·
`inbound/[id]/edit/PrepaymentPanel` · `logistics/containers/[id]/ContainerPanels` · `logistics/forwarders/[id]/page.tsx` · `operation/processing/[id]/DischargePanel` ·
`ProcessingTables` · `RunRecordPanels` · `components/related/RelatedTable` (keyset-paged 20 at a time, `related-records.tsx:108,260-267` — the only one needing a server route).

Facts that drive the cost:
- **Every other A table already holds all its rows in props**; no `.limit()` found on the reads feeding them.
- **Many rows carry only pre-formatted text** (`*Text` fields): EmployeeTables 11, ProcessingTables 10, PoLinesTable 8, PayrollLinesTable 6, PoReceipts / PoPaymentTerms / OutputBatches 5 each. Typed Excel cells (hard rule 2) mean feeding the raw numbers through from the page loader.
- **Four are hand-built `<table>`s** that must become `DataTable` before an `exportSpec` exists: PrepaymentPanel (:154), ContainerPanels (:128, :314), forwarders `page.tsx` (:211).
- **27 detail pages render 2+ of these tables**: `operation/processing/[id]` 14 · `inbound/[id]/edit` 8 · `output/[id]/edit` 6 · `finance/supplier-statements/[id]` 4 · nine pages with 3 · fourteen with 2.
- **`app/components/audit/BatchAuditTrailTable.tsx` is dead code**: its only importer `BatchAuditTrail.tsx` has no importer anywhere (`grep` over `app`/`lib`; the one hit is the unrelated `loadBatchAuditTrail` in `auditTrailQuery.ts:9`).
- **`hr/reviews/cycles/page.tsx`'s `<table>` is a layout table** inside a "no reviewer yet" warning, its second column a `<select>` that edits data (`page.tsx:10-17`); the page is a list of cards, not a detail page.
- `TermsRequestsPanel` and `PriceBreakdown` also render on non-detail pages (contracts list, pricing formulas, calculator).

### The 7 「受限」 files (queue 64b) — where each draws it

PoLinesTable :167 :190 · PoPaymentTermsTable :72 :81 · PoReceiptsTable :94 :106 :114 · PrepaymentPanel :84 (panel) :159-160 (cell) ·
EmployeeTables `paid()` :161 used :180-183 :191 · OutputBatchesTable :84 :85 · InboundBatchesTable :93. Each passes `null` text → `MaskedValue`, so the export maps it to `xRestricted`.
Other A files with masked cells: JournalLinesTable :79 :87 · LedgerRowsTable :133 · PayrollLinesTable :53 · PricingPanel :111 :125 :133 :166 · SparePartsPanel :122 · CostPanel :66 :177 · ProcessingTables :227 :233 · forwarders `page.tsx` :234.

### B · how each report is built

The writer makes **flat sheets only**: one sheet, bold header, plain rows, number formats (`lib/export/write.ts:104-143`); no per-row bold, indent, outline or second data sheet. exceljs supports all three. Ruling Q12 says "no totals row" (`docs/table-export.md:27`).

| Report | Built | Source | Layout | Inputs | Already exported? |
|---|---|---|---|---|---|
| Trial balance | hand-built (`trial-balance/page.tsx:150`) | `accounts` + `trial_balance_totals()` (:76-83) | heading row per account type (:171-178), grand total Σdr/Σcr (:245-266); no comparatives | `?all=1` only — **all-time, no period** (:60,73) | no |
| P&L | hand-built (`pnl/page.tsx:160`) | `pnl_statement(p_from,p_to)` (:82) | revenue / COGS / expense headings + section subtotals (:102-143), gross profit + margin % (:172-182), net profit (:185-195); account drill-down; no comparatives | `date_from`/`date_to` + presets | no |
| Balance sheet | hand-built (`balance-sheet/page.tsx:174`) | `balance_sheet(p_as_of)` (:81) | three sections + subtotals (:101-159), synthetic "current earnings" row (:138-149), totals footer (:194-209) | `as_of` | no |
| Cash flow | summary hand-built (`cashflow/page.tsx:150-171`) + detail DataTable (`CashflowEntriesTable.tsx:43-49`) | `cash_flow_statement(p_from,p_to)` (:74) | 7 fixed summary lines; detail = date, code+memo, section, net | `date_from`/`date_to` | no |
| Cost variance | hand-built pivot (`cost-variance/page.tsx:35`) | view `processing_cost_variance` (:26) | cost type × last 6 months, variance only; estimated / actual only in a hover (:43-53) | none | no |
| Month-end | hand-built (`month-end/page.tsx:292`) | ~12 reads | **a 14-step checklist**, not figures: step, link, state badge, detail sentence | `month` | no |
| Receivables | hand-built (`receivables/page.tsx:172`) | `ar_aging_asof` | grouped by customer + subtotals | `as_of` | **yes** — AR ageing CSV `receivables/export/route.ts`, linked :120 |
| Payables | hand-built (`payables/page.tsx`) | `ap_aging_asof` | same shape | `as_of` | **yes** — AP ageing CSV `payables/export/route.ts`, linked :130 |
| Cash-forecast grid | hand-built pivot per currency (`ForecastGrid.tsx:186-221`) | `cash_forecast_data()` | inflow / outflow / net / closing × 13 weeks, one grid per currency | none | only the frozen-forecast register |

C report bodies: management pack (`PackTables.tsx`, cells arrive as formatted strings, `PackBody.tsx:70-88`; **stored packs already exported** by `packs/[id]/export/route.ts` except split pairs as rows) ·
list-vs-ledger (7 fixed lines per side, formatted strings, `page.tsx:59`) · price exposure (flat, gated whole-section on `FN.margin`) ·
compliance pack (8 sections, 9 DataTables, kg/t, no money; only the pack register is exported).
Previews: **depreciation** — `preview_depreciate_fixed_assets(p_period_end)`, same arithmetic as the posting (`assets/page.tsx:111-117`), one row per asset, a bold synthetic total row (:119-126);
**revaluation** — `preview_revalue_foreign_balances(p_period_end)`, one row per account × currency, mixed currencies, total "net to 7110" (`revaluation/page.tsx:63-93`).
**Five tables pass amounts as pre-formatted strings** (PackTables, ListVsLedger, ForecastGrid lines :116, Exposure :15-17, and the reports above that format in JSX) — raw numbers have to be fed through.

### C · forms and decision panels

| Entry | What it shows | Fact |
|---|---|---|
| bank import (`ImportStatementForm.tsx:418`) | the parsed upload, **first 20 rows only** (`:419` `slice(0, 20)`) | an echo of the file the user just chose; nothing is saved yet |
| electricity new (`NewAllocationForm.tsx`) | preview of machines and runs before posting | the **posted** allocation's lines are already exported (`electricity/[id]/page.tsx:177`) |
| payroll payments (`PayPanel.tsx:201,211`) | per payroll run: lines to pay (with a selection) + payments made; amounts masked → `common.restricted` (:126) | the panel **is** the page `/finance/payroll-payments` — no other list of outstanding payroll payments |
| processing-cost settle (`CostSettlePanel.tsx:137,163`) | open actuals and open estimates, each with a selection | the panel **is** the page `/finance/processing-costs` |

### E · editable tables (25) — not in the brief's A/B/C

- **17 entry forms (nothing saved yet)**: NewFreightForm · BulkFxGrid · CreateCreditNoteControl · NewInvoiceForm · NewPaymentForm · PayrollGrid (`/hr/payroll/new`, `[id]/edit`) · AssayForm ·
  NewWorkOrderForm · OutputAssayForm · purchasing AmendOrderForm · NewOrderForm · TemplateForm · sales AmendOrderForm · NewQuoteForm · CalculatorForm · FormulaForm · BulkPricesForm.
  Each saved record already exports from its own list or detail page (e.g. payroll lines → `hr/payroll/[id]/PayrollLinesTable`, kind A).
- **8 that are the only screen of a saved record**: AttendanceGrid (`/hr/attendance/[id]`) · QuoteLinesEditor (`/sales/quotes/[id]`, the quote's lines) · GoalsEditor (`/hr/reviews/[id]`, `/my-reviews/[id]`) ·
  PermissionMatrix (`/settings/roles/[id]`) · LeaveTypesEditor (`/hr/leave/types`) · ScaleEditor (`/hr/reviews/scale`) · ScoreEditor (`/hr/kpi/score`) · MySelfAssessmentPanel (`/me`).

## 2 · D · `/settings/change-history`

- One read path: `change_log_rows` (SECURITY DEFINER, `db/functions/change_log_rows.sql:33-147`), called at `page.tsx:117-131`. Unit = one **operation** (transaction), up to 200 per call (rows_fn :43); keyset paging by `seq`.
- **A date range already exists**: `DatePicker name="from"` / `"to"` (`page.tsx:186-193`), optional, applied in the database (rows_fn :56-57, :86-87), end day inclusive.
  Filters `area`, `type`, `record`, `who` are applied in the database; **`key=1` (key events only) is applied in JS after the read** (`page.tsx:156-161`).
- Guard: `requireFunction(FN.changeHistory)` → `data.view_change_log` (`lib/modules.ts:426`), re-checked inside the function (rows_fn :50).
- **`change_log` holds raw unmasked old/new values** (`db/tables/change_log.sql:49-50`; writer `change_log_capture` uses `to_jsonb(NEW)`), no grants, RLS with no policy (:75-76).
  Masking happens only inside `change_log_rows`: `change_log_mask_row` per column (`{"$restricted": true}`), private tasks, and `trail_row_visible`. **An export must read through `change_log_rows`**, never the table.
- Screen: `AuditTrailList` (not a table) — one entry per operation, then one line per field "Label old → new", reason last; sentences built by `lib/trail/render.ts` `buildEntries` (:5556).
- Precedent for a required range: the GL export refuses without `from`/`to` (`app/finance/journal/export/route.ts:63-69`, HTTP 400) and the page hides the button with a reason (`journal/page.tsx:185-192`).
- There is no count function for these filters; `exportRowsResponse` wants a count first (`lib/export/serverRows.ts:63-66`). Reading operations until the 50,000-row cap is passed avoids a migration (inferred, not built).
- Size: 78,441 rows at TABLE-EXPORT-2 Step 0 (`docs/known-issues.md:11530`); 64,239 on 2026-10-19 (`docs/handbacks/MES-9b.md:57`). Growth ≈ 3–5k rows/day **inferred** from those points, mostly smoke and proof runs.
