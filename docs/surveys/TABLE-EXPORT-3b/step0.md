# TABLE-EXPORT-3b — Step 0 survey (2026-10-24)

Read-only, from source at `f5f6054b233a929c87c43976f4841bb861e8c62e`. No browser sweeps; no database reads except Part 1.2 (`readings/closeout-prod-check.txt`, `readings/readback-closeout.txt`).
Counts come from importing `scripts/table-export-exemptions.mjs` and grouping by `cut` and path. They are not `grep -c`.

## 0 · The count

At start: `TABLE-EXPORT-3` **93**, `PERMANENT` **7** (100 entries), matching the 3a hand-back.
3b owns **56** entries, and 3c keeps the other **37**:

| Group | Entries (files) | Table instances |
|---|---|---|
| A finance | 13 | 17 (StatementDetailTables 4, GstTables 2) |
| A purchasing | 3 | 3 |
| A sales | 4 | 4 |
| A inbound | 5 | 5 (PrepaymentPanel is a hand-built `<table>`) |
| A inventory | 2 | 2 |
| A hr | 4 | 7 (EmployeeTables 3, LeaveDetailTables 2) |
| E: export (Q8) | 8 | 8 components; MySelfAssessmentPanel draws one per open review |
| E: PERMANENT (Q8) | 17 | n/a |
| **3b total** | **56** | 38 A instances + 8 E |

If everything lands as ruled, the end state is `TABLE-EXPORT-3` 37 (all 3c) and `PERMANENT` 24.

## 1 · Facts that drive the build (file:line)

- **Every A table gets its complete row set in props.** None of the reads behind these tables uses `.limit` / `.range` / keyset paging.
  The only cap nearby is PO history `.limit(50)` at `purchasing/orders/[id]/page.tsx:152`, which feeds a different section.
  The ledger drill-down reads all lines in one `jsonb_agg` with no LIMIT (`db/functions/account_ledger.sql:66-88`).
- **Most rows arrive as pre-formatted strings** (`*Text`, built in each `page.tsx`). Typed cells (hard rule 2) mean passing the raw numbers and currency through as well.
  Rows that already carry raw values: ExpenseLinesTable, GstFilingPanel, StatementDetailTables, OrderLinesTable, InboundMarginTable, AssayRowsTable, BatchDetail.
- **Seven tables push total rows as data:**

  | Table | Total rows | Where |
  |---|---|---|
  | bank statement lines | total | `bank/statements/[id]/page.tsx:182` |
  | credit-note lines | total | `credit-notes/[id]/page.tsx:113` |
  | journal lines | total | `journal/[id]/page.tsx:156-157` (restricted if any line is) |
  | ledger rows | total | `ledger/[account]/page.tsx:201-233` |
  | payment allocations | total | `payments/[id]/page.tsx:214-233` |
  | PO lines | net / tax / gross | `purchasing/orders/[id]/page.tsx:527-536` |
  | payroll lines | total | `hr/payroll/[id]/page.tsx:142-171` |

  The PO tax line is the header value `po.tax_total_ccy`, so it cannot be recomputed from the lines. → Q1.
- **`EditableTable` has no export path.** It takes no `exportSpec` (`app/components/ui/editable-table.tsx:438-482`).
  `scripts/check-table-export.mjs:130-143` accepts a `DataTable` with `exportSpec=` or a hand-built `<table` whose own file renders an export bar; it accepts nothing for `EditableTable`.
  3b therefore adds `exportSpec` to `EditableTable` and teaches the check to accept it.
- **The 7 「受限」 tables** and where they draw 「受限」: PoLinesTable :167 :190 and the three total rows (`page.tsx:525`) · PoPaymentTermsTable :72 :81 · PoReceiptsTable :94 :106 :114 ·
  PrepaymentPanel :159-160 · EmployeeTables :161 · OutputBatchesTable :84 :85 · InboundBatchesTable :93.
  InboundBatchesTable's unit price shows a text reason (`priceRestricted`, `page.tsx:140`); the export writes "Restricted" there too.
  Other masked cells in 3b: JournalLinesTable :79 :87 (also inside `ccyText`, `page.tsx:138`) · LedgerRowsTable :133 · PayrollLinesTable :53 · PricingPanel :111 :125 :133. The pay cells are masked by `data.view_pay`; PricingPanel by `data.view_purchase_prices`.
- **History trails in 3b's own files:** PricingPanel (price history, comment :4) · PrepaymentPanel (applications) · EmployeeTables pay history · LeaveDetailTables consumption ledger.
  AssayRowsTable and CostEntriesTable also keep superseded and reversed rows on purpose.
  The two shared trails that appear on 3b pages, `SettlementHistoryTable` (finance) and `MovementTimelineTable` (inbound / output), are **shared components → 3c** under Q12; 3b leaves them.
- **The 8 editable record screens:**

  | Component | Shape | Effort |
  |---|---|---|
  | AttendanceGrid | one row per employee; only `note` editable | S |
  | QuoteLinesEditor | the quote's lines | S |
  | GoalsEditor | same columns in every state; used by `/hr/reviews/[id]` and `/my-reviews/[id]` | S |
  | LeaveTypesEditor | a catalogue page | S |
  | ScaleEditor | a catalogue page | S |
  | ScoreEditor | employee × KPI for one cycle; `orgTargets` nested inside `<details>` | M |
  | MySelfAssessmentPanel | one table per open review on `/me` | M |
  | PermissionMatrix | **one role × modules** (view / edit checkboxes); the ~51 `data.*` / `action.*` codes are cards, not table rows | M → Q2 |

  Every one holds saved values in its rows; the export writes the saved values, not unsaved typing.
- **The 17 entry forms: "the saved record exports from its own page" is false for three** → Q3:
  - `tools/pricing/calculator/CalculatorForm.tsx` saves nothing: the result comes from `calculate_metal_price` (`calculator/actions.ts:100`).
  - `purchasing/payment-terms/TemplateForm.tsx` is also the saved template's only detail screen (`payment-terms/[id]/edit/page.tsx`). The list export carries its terms only as one summary text cell.
  - `tools/pricing/formulas/FormulaForm.tsx` is the saved formula's only screen (`formulas/[id]/edit/page.tsx`). Its per-metal payable rows are in no export: FormulasTable's columns are at `FormulasTable.tsx:40-88`.

  For two other forms the statement becomes true only at 3c: NewWorkOrderForm → `WorkOrderTables`, and OutputAssayForm → `AssayTables`.
  PayrollGrid's `/hr/payroll/[id]/edit` is a saved, unposted period; its lines export from `/hr/payroll/[id]` (`PayrollLinesTable`, in 3b).
- **The EmployeeTables pay history has no `.order`** (`hr/employees/[id]/page.tsx:86-89`), so rows come back in arbitrary order. 3b orders it by period start, newest first, so screen and file agree.

## 2 · Assertions measured false

1. Brief / Q8: "17 entry forms … the saved record exports from its own page." False for three (above).
2. A sub-survey reported "ScoreEditor score cells are blank for readers without `data.view_reviews`." False: those readers get no rows at all, because `kpi_entries` is `(module.hr.view AND data.view_reviews) OR own row` (`hr/kpi/score/page.tsx:69-74`). There is no blank-for-「受限」 cell to fix.
3. A sub-survey reported "TemplateForm is also imported by safety templates." False: safety imports `app/safety/inspections/TemplateForm.tsx`, a different file.
