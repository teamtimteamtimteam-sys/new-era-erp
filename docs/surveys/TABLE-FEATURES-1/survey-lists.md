# TABLE-FEATURES Step 0 — list-page census (read-only survey, 2026-10-25)

Repo: `/Users/timchen/Documents/projects/new-era-erp`. Nothing edited, nothing built or run; no script under `scripts/` or `db/scripts` imported.
Measured with `find`/`grep` plus small Python parsers written into the scratchpad (they only read `.tsx/.ts` source text):
`dt.py` (parses every `<DataTable` / `<EditableTable` opening tag, skips `<T>` generics, extracts top-level prop names),
`pages.py` (for each route page: the page file + every file it imports from its own route directory, plus one hop into shared files under `app/`),
`money.py` (columns whose `exportAs` uses `xMoney`). Sanity-checked by hand: e.g. `sorting=` raw grep returns the same 8 sites; `columnToggle|pageSize=|filter={{|selection=` raw grep returns exactly Base1.tsx:106-108 and CostSettlePanel.tsx:150,177.

## 1. Which pages are list pages

**Universe:** `find app -name page.tsx` = **271** route pages. Minus any path with `[...]` (detail) and any `/new/` or `/edit/` segment = **148** candidates. Every one of the 148 is assigned to exactly one class below (the script asserts the five classes cover the 148 with no gaps or overlaps).

| Class | Count / 148 | Definition |
|---|---|---|
| **A. List page (record register in a table)** | **84** | main content is a register of records drawn as `<DataTable>` (incl. the `CellsTable` wrapper) or `<EditableTable>` |
| B. Record list without a table | 12 | a register drawn as cards / `<ul>` / div rows (notifications, change-history, accounts, portal lists …) |
| R. Report / computed table | 21 | statements, ageing, previews, mass balance, snapshots — rows are computed, not records |
| P. Action panel | 2 | `/finance/payroll-payments`, `/finance/processing-costs` (decision panels; the only `selection` users) |
| X. Not a list | 29 | 10 hubs, 3 auth, 10 forms/tools/bulk entry, 6 other (display board, brand-sampler, org chart, two calendars, task board) |

**How this differs from "114 list pages".** The 114 is a **file** count, not a route count: `docs/handbacks/TABLE-EXPORT-1.md:14` — "57 of the 114 list-page files … finance 34 · me 8 · settings 5 …" (me alone is 8 files on one route). The comparable file measure today: files with ≥1 real `<DataTable>` call site that are not under `[...]`, `/new/`, `/edit/`, `/amend/` or `app/components` = **112** (includes brand-sampler). By route, the register pages are **84** (A); A+R+P = 107 routes with any table; A+B = 96 if card lists count as lists.

Nav registry cross-check: `lib/modules.ts` holds 133 distinct `href`s; 82 of the 84 A pages are among them; the 2 not in the registry are `/me` and `/my-reviews` (reached from the user menu).

### B, R, P, X membership

| Class | Route | Note (file:line) |
|---|---|---|
| B | /notifications | card/ul list; cap 50 + RowCapNotice (page.tsx:19,37,75); occurred_at desc (page.tsx:36) |
| B | /settings/change-history | div rows; from/to date range (page.tsx:188,192) + area/type/record/who/key/show; "show older" capped at 500 |
| B | /hr/leave/grants | div rows; grant history latest 200 (page.tsx:42, TrailCapNotice); year filter |
| B | /hr/reviews/cycles | cycles as cards; the only <table> is a layout table inside each card (page.tsx:12,173); period_start desc (page.tsx:78) |
| B | /settings/accounts | UserRow div list; created_at asc (page.tsx:30) |
| B | /logistics/lanes | ul list (LanesPanel) |
| B | /logistics/shipping | ul list (ship queue) |
| B | /purchasing/discrepancies | div list; arrival_date desc (page.tsx:60) |
| B | /tools/reminders | ul lists grouped by type; JS sort by days waiting (page.tsx:186,190) |
| B | /portal/deliveries | ul list (customer/supplier portal) |
| B | /portal/documents | ul list (portal) |
| B | /portal/certificates | ul list (portal) |
| R | /finance/balance-sheet | hand <table> page.tsx:205, <tfoot> totals :224 |
| R | /finance/pnl | hand <table> page.tsx:190, subtotals |
| R | /finance/trial-balance | hand <table> page.tsx:174, <tfoot> totals :269 |
| R | /finance/cashflow | hand <table> page.tsx:177 + DataTable; date_from/to |
| R | /finance/cash-forecast | ForecastGrid hand <table> :240 (sticky first column :243,257) + 4 DT incl. frozen forecasts cap 20 |
| R | /finance/cost-variance | hand <table> page.tsx:52 |
| R | /finance/month-end | hand <table> page.tsx:304 (checklist) |
| R | /finance/list-vs-ledger | DT |
| R | /finance/price-exposure | DT ×2 |
| R | /finance/receivables | AR ageing, hand <table> :172, summary bar :138-141, group totals :310,320 |
| R | /finance/payables | AP ageing, hand <table> :176, summary bar :142-145, group totals :316,325 |
| R | /finance/revaluation | preview DT + history (limit 24) |
| R | /operation/balance | MassTable (DT) |
| R | /operation/yield | MassTable (DT) |
| R | /operation/equipment/reliability | CellsTable; from/to date range (page.tsx:108,112) |
| R | /inventory/reports/snapshot | DT ×2; total value bar page.tsx:63-66 |
| R | /inventory/reports/safety | DT |
| R | /inventory/reports/violations | DT ×2 |
| R | /inventory/storage-safety | DT ×3; computed "total" row (page.tsx:68) |
| R | /margin | DT; revenue coverage sentence (page.tsx:97-98,182-183) |
| R | /sales/customers/overlap | DT ×2 from rpc |
| P | /finance/payroll-payments | PayPanel (DT ×2), decision panel |
| P | /finance/processing-costs | CostSettlePanel (DT ×2, the only `selection` users) |
| X (hub) | /, /finance, /hr, /sales, /operation, /purchasing, /logistics, /tools/pricing, /inventory/reports, /portal | |
| X (auth) | /login, /set-password, /welcome | |
| X (form / tool / bulk entry) | /inbound/receive, /finance/company, /finance/settings, /tools/converter, /tools/pricing/calculator, /finance/bank/import, /finance/fx/bulk, /tools/pricing/metal-prices/bulk, /inventory/scan, /settings/approvals | |
| X (other) | /display, /brand-sampler, /hr/org, /hr/leave/calendar, /tools/calendar, /tools/tasks | |

## 2. Per list page: table kind, DataTable props, paging, filters, date range, default ORDER BY

**Denominator: the 84 A pages.**

| Measure | Count / 84 | How measured |
|---|---|---|
| Main table is `<DataTable>` directly | 73 | `<DataTable` call site in the page's import closure |
| … via the `CellsTable` wrapper (`app/operation/equipment/CellsTable.tsx:44`) | 8 | electricity, calibration, capture/inbox, capture, devices, equipment, weighbridge, pending-values. **CellsTable passes no sorting / filter / pageSize / footer — it cannot switch any of them on.** |
| `<EditableTable>` only | 3 | hr/kpi/score, hr/leave/types, hr/reviews/scale |
| Hand-built `<table>` as main table | **0** | (hand tables remain only on R pages and inside /hr/reviews/cycles cards) |
| DataTable `sorting` on | **7** (all `mode: 'server'`) | fx, inbound, materials, output, sales/customers, suppliers, metal-prices |
| `columnToggle` / `filter` (in-table search) / `pageSize` (client paging) / `footer` | **0 / 0 / 0 / 0** | |
| `selection` | 0 (the 2 sites are on P page /finance/processing-costs) | |
| Server paging `?page=` + `.range()` (all 20 rows/page except capture/inbox 200) | **19** | |
| "First N of M" cap + `RowCapNotice` (N = 20…1000) | **17** | |
| No paging, no cap (one read; PostgREST max_rows 1000 applies silently) | **48** | |
| Page has its own URL filter or date-range controls (any `searchParams` key other than page/sort/dir/trail) | 31 | incl. 3 borderline selectors: safety/environment `corrects`, settings/dictionaries `table`, hr/kpi/score `cycle` |
| **Date-range (from/to) filter** | **11** | expenses, invoices, journal, payments, purchasing/orders, inbound, output, operation/processing, hr/leave, inventory/reports/ledger, settings/deleted |

Outside A, date ranges also exist on B `/settings/change-history` (page.tsx:188,192) and R `/finance/cashflow` (CashflowToolbar.tsx:38,45), `/finance/pnl` (PnlToolbar.tsx:38,45), `/operation/equipment/reliability` (page.tsx:108,112). Single-date / month / year pickers (not ranges): finance/assets `date`, revaluation `date`, balance-sheet / receivables / payables `as_of`, compliance/packs, finance/packs, month-end, operation/balance, operation/yield `month`, hr/claims, hr/leave/grants, hr/leave/holidays `year`, finance/close `period`.

**Default-sort mismatches worth knowing:** /finance/payments filters `payment_date` but orders by `created_at` (paymentRows.ts:39-40 vs :56); /finance/journal filters `entry_date`, orders `created_at` (journalRows.ts:37-38 vs :55); inbound / output / processing filter by arrival/output/process date but default-sort `created_at`. /hr/leave re-sorts pending-first in JS *after* the 300-row cap was taken by `start_date desc` (leaveRows.ts:58-60 then :73), so an old pending request beyond the cap is not pulled to the top. /quality/ncr re-sorts open-first in JS (page.tsx:39). /inventory has no ORDER BY at all — JS `compareForSort` by name (page.tsx:310).

Paths below are relative to `app/`. "Sorting" = DataTable `sorting` prop.

| Route | Table(s) (call site) | Sorting | Paging / cap | URL filters | Date range | Default ORDER BY today |
|---|---|---|---|---|---|---|
| /compliance/packs | DataTable ×9 (compliance/packs/PacksTable.tsx:28, compliance/packs/PackSections.tsx:118, compliance/packs/PackSections.tsx:123 …) | — | cap 300 + RowCapNotice (packsRows.ts:18; page.tsx:76) | month | — | period_month desc, frozen_at desc, id (packsRows.ts:33-35) |
| /contracts | DataTable ×6 (components/pricing/TermsRequestsPanel.tsx:106, contracts/ContractsTables.tsx:94, contracts/ContractsTables.tsx:129 …) | — | none | — | — | effective_from desc (page.tsx:73); 6 tables, each own order (page.tsx:77,85,90) |
| /finance/assets | DataTable ×2 (finance/assets/AssetsTable.tsx:151, finance/assets/DepreciationPreviewTable.tsx:48) | — | none | date (as-of for depreciation preview) | — (single date) | code (page.tsx:102) |
| /finance/bank | DataTable ×1 (finance/bank/TransfersTable.tsx:107) | — | transfers cap 50 + RowCapNotice (transferRows.ts:18; page.tsx:237) | — | — | transfers: transfer_date desc, created_at desc, id (transferRows.ts:39-41); accounts are cards, not a table |
| /finance/bank/statements | DataTable ×1 (finance/bank/statements/StatementsTable.tsx:88) | — | ?page= 20/page (page.tsx:23,76; statementRows.ts:57 .range) | account, status | — | period_end desc, created_at desc, id (statementRows.ts:54-56) |
| /finance/claims | DataTable ×1 (finance/claims/ClaimDecisionPanel.tsx:283) — table is ClaimDecisionPanel | — | none | — | — | spend_date desc (page.tsx:51) |
| /finance/close | DataTable ×2 (finance/close/YearCloseHistoryTable.tsx:46, finance/close/CloseHistoryTable.tsx:95) | — | none | period | — | closed_at desc (page.tsx:83,88) |
| /finance/credit-notes | DataTable ×1 (finance/credit-notes/CreditNotesTable.tsx:96) | — | ?page= 20/page (page.tsx:23,56; creditNoteRows.ts:33) | — | — | note_date desc, code desc, id (creditNoteRows.ts:30-32) |
| /finance/electricity | CellsTable→DataTable — CellsTable ×2 (page.tsx:130,151) | — | none | — | — | period_from desc (page.tsx:48) |
| /finance/expenses | DataTable ×1 (finance/expenses/ExpensesTable.tsx:95) | — | ?page= 20/page (page.tsx:31,113; expenseRows.ts:91) | status, account | **date_from/date_to on expense_date** (ExpensesToolbar.tsx:39,46; expenseRows.ts:65-66) | expense_date desc, created_at desc, id (expenseRows.ts:88-90) |
| /finance/freight | DataTable ×1 (finance/freight/FreightTable.tsx:53) | — | cap 200 + RowCapNotice (freightRows.ts:17; page.tsx:47) | — | — | doc_date desc, id (freightRows.ts:39-40) |
| /finance/fx | DataTable ×1 (finance/fx/FxRatesTable.tsx:81) | server (FxRatesTable.tsx:88) | ?page= 20/page (fxQuery.ts:15; fxRows.ts:31) | currency, sort, dir | — | **server sort**, default rate_date desc then currency (fxQuery.ts:31,51-53) |
| /finance/gst | DataTable ×2 (finance/gst/GstPeriodsTable.tsx:63, finance/gst/GstTaxCodesTable.tsx:53) — 2 tables (periods, tax codes) | — | none | — | — | periods: period_start desc (page.tsx:32) |
| /finance/invoices | DataTable ×1 (finance/invoices/InvoicesTable.tsx:144) | — | ?page= 20/page (page.tsx:25,82; invoiceRows.ts:71,93) | state, status | **date_from/date_to on issue_date** (InvoicesToolbar.tsx:34,41; invoiceRows.ts:52-53) | issue_date desc, id (invoiceRows.ts:69-70,91-92) |
| /finance/journal | DataTable ×1 (finance/journal/JournalTable.tsx:82) | — | ?page= 20/page (page.tsx:26,83; journalRows.ts:57) | — | **date_from/date_to on entry_date** (JournalToolbar.tsx:32,39; journalRows.ts:37-38) | created_at desc, id (journalRows.ts:55-56) — filters entry_date but orders created_at |
| /finance/packs | DataTable ×3 (finance/packs/PacksHistoryTable.tsx:55, finance/packs/PackTables.tsx:74, finance/packs/PackTables.tsx:113) — 3 tables (pack body + history) | — | none | month | — (month) | period_month desc, produced_at desc (page.tsx:50) |
| /finance/payment-requests | DataTable ×1 (finance/payment-requests/PaymentRequestsTable.tsx:73) | — | ?page= 20/page (page.tsx:19,54; requestRows.ts:58) | status | — | created_at desc, id (requestRows.ts:56-57) |
| /finance/payments | DataTable ×1 (finance/payments/PaymentsTable.tsx:85) | — | ?page= 20/page (page.tsx:19,75; paymentRows.ts:58) | direction | **date_from/date_to on payment_date** (PaymentsToolbar.tsx:34,41; paymentRows.ts:39-40) | created_at desc, id (paymentRows.ts:56-57) — filters payment_date but orders created_at |
| /finance/self-approved | DataTable ×1 (finance/self-approved/SelfApprovedTable.tsx:59) | — | none | — | — | none in app — order is inside rpc self_approved_decisions (page.tsx:57) |
| /finance/supplier-statements | DataTable ×1 (finance/supplier-statements/StatementsTable.tsx:27) | — | cap 300 + RowCapNotice (statementRows.ts:17; page.tsx:38) | — | — | issued_at desc, id (statementRows.ts:31-32) |
| /finance/wht | DataTable ×3 (finance/wht/WhtTables.tsx:69, finance/wht/WhtTables.tsx:121, finance/wht/WhtTables.tsx:152) — 3 tables | — | none | — | — | period_month desc (page.tsx:50,53) |
| /hr/attendance | DataTable ×1 (hr/attendance/AttendanceTable.tsx:77) | — | none | — | — | period_month desc (page.tsx:36) |
| /hr/claims | DataTable ×1 (hr/claims/ClaimsTable.tsx:76) | — | cap 300 + RowCapNotice (claimsRows.ts:18; page.tsx:80) | status, employee, year | — (year) | claim_date desc, claim_id (claimsRows.ts:54-55) |
| /hr/departments | DataTable ×1 (hr/departments/DepartmentsTable.tsx:63) | — | none | — | — | code (page.tsx:31) |
| /hr/employees | DataTable ×1 (hr/employees/EmployeesTable.tsx:108) | — | ?page= 20/page (page.tsx:26,73; employeeRows.ts:85) | q, department, status, category | — | code, employee_id (employeeRows.ts:83-84) |
| /hr/kpi | DataTable ×1 (hr/kpi/KpiMatrixTable.tsx:57) — KPI matrix | — | none | — | — | position_code (page.tsx:50) |
| /hr/kpi/score | EditableTable (hr/kpi/score/ScoreEditor.tsx:243) — EditableTable | — | none | cycle | — | score desc (page.tsx:84), then JS compareForSort (page.tsx:138,151) |
| /hr/leave | DataTable ×1 (hr/leave/LeaveRequestsTable.tsx:76) | — | cap 300 + RowCapNotice (leaveRows.ts:18; page.tsx:107) | status, type, employee | **from/to: start_date ≥ from, end_date ≤ to** (page.tsx:96,100; leaveRows.ts:45-46) | start_date desc, id (leaveRows.ts:58-59), then JS pending-first re-sort (leaveRows.ts:73) — applied after the 300 cap |
| /hr/leave/balances | DataTable ×1 (hr/leave/balances/BalancesTable.tsx:61) | — | none | — | — | employee code (page.tsx:30) |
| /hr/leave/holidays | DataTable ×1 (hr/leave/holidays/HolidaysTable.tsx:98) | — | none | year | — (year) | holiday_date (page.tsx:30) |
| /hr/leave/types | EditableTable (hr/leave/types/LeaveTypesEditor.tsx:129) — EditableTable | — | none | — | — | sort_order (page.tsx:31) |
| /hr/overtime | DataTable ×1 (hr/overtime/BatchesTable.tsx:56) | — | none | — | — | period_month desc, seq desc (page.tsx:31-32) |
| /hr/payroll | DataTable ×1 (hr/payroll/PayrollPeriodsTable.tsx:122) | — | none | — | — | period_month desc (page.tsx:37) |
| /hr/reviews | DataTable ×1 (hr/reviews/ReviewsTable.tsx:86) | — | cap 200 + RowCapNotice (reviewsRows.ts:19; page.tsx:132) | cycle, type, status, employee | — | created_at desc, id (reviewsRows.ts:52-53) |
| /hr/reviews/scale | EditableTable (hr/reviews/scale/ScaleEditor.tsx:155) — EditableTable | — | none | — | — | sort_order (page.tsx:29) |
| /hr/training | DataTable ×1 (hr/training/TrainingTable.tsx:93) | — | none | category, expiry | — | completed_date desc (page.tsx:77) |
| /inbound | DataTable ×1 (inbound/InboundTable.tsx:199) | server (InboundTable.tsx:204) | ?page= 20/page (inboundQuery.ts:50; page.tsx:185; inboundRows.ts:73) | q, stage, supplier_id, material_id, pricing_status, sort, dir | **date_from/date_to on arrival_date** (InboundToolbar.tsx:136,143; inboundQuery.ts:173,176) | **server sort**, default created_at desc (inboundQuery.ts:82,200) + id tiebreak (inboundRows.ts:73) |
| /inventory | DataTable ×1 (inventory/InventoryTable.tsx:122) | — | none | — | — | no ORDER BY — JS compareForSort by material name (page.tsx:310) |
| /inventory/locations | DataTable ×1 (inventory/locations/LocationsTable.tsx:89) | — | none | — | — | code (page.tsx:52) |
| /inventory/reports/ledger | DataTable ×1 (inventory/reports/ledger/LedgerTable.tsx:58) | — | cap 1000 + RowCapNotice (ledgerQuery.ts:65; page.tsx:112) | material_id, batch, movement | **from/to on business_date, default last 90 days** (page.tsx:90,94; ledgerQuery.ts:101-102) | business_date desc nulls last, occurred_at desc, id (ledgerQuery.ts:113-115) |
| /logistics/containers | DataTable ×1 (logistics/containers/ContainersTable.tsx:73) | — | none | — | — | departure_date desc (page.tsx:30) |
| /logistics/forwarders | DataTable ×1 (logistics/forwarders/ForwardersTable.tsx:85) | — | none | — | — | legal_name (page.tsx:42) |
| /materials | DataTable ×1 (materials/MaterialsTable.tsx:154) | server (MaterialsTable.tsx:160) | ?page= 20/page (materialQuery.ts:27; page.tsx:70; materialRows.ts:30) | q, kind, sort, dir | — | **server sort**, default created_at desc (materialQuery.ts:51-52,89) |
| /me | DataTable ×10 (me/MyTrainingTable.tsx:66, me/MyPayslipsTable.tsx:94, me/MyReviewsPanel.tsx:132 …); EditableTable (me/MySelfAssessmentPanel.tsx:194) — 10 DataTables + 1 EditableTable | — | 3 panels cap 50 + RowCapNotice (meRows.ts:15; MyLeavePanel.tsx:241, MyClaimsPanel.tsx:128, MyExpenseClaimsPanel.tsx:326) | — | — | per panel: start_date desc / claim_date desc / spend_date desc (meRows.ts:35,46,57); training completed_date desc (page.tsx:149) |
| /my-reviews | DataTable ×1 (my-reviews/MyReviewsTable.tsx:76) | — | none | — | — | created_at desc (page.tsx:65) |
| /operation/blending | DataTable ×1 (operation/blending/BlendingPlansTable.tsx:46) | — | none | — | — | created_at desc (page.tsx:30) |
| /operation/calibration | CellsTable→DataTable — CellsTable | — | none | — | — | code (page.tsx:45) |
| /operation/capture | CellsTable→DataTable — CellsTable ×2 | — | pending cap 200, recent cap 50 + RowCapNotice (captureRows.ts:22-23; page.tsx:136,160) | — | — | pending: created_at, id (captureRows.ts:46); recent: captured_at desc, weighing_id (captureRows.ts:67) |
| /operation/capture/inbox | CellsTable→DataTable — CellsTable | — | ?page= 200/page (inboxRows.ts:20,45; page.tsx:55) | status | — | id desc (inboxRows.ts:45) |
| /operation/contamination | DataTable ×2 (operation/contamination/ContaminationChecksList.tsx:69, operation/contamination/ContaminationGrid.tsx:52) | — | grid cap 300, recent cap 50 + RowCapNotice (contaminationRows.ts:21-22; page.tsx:70,73) | — | — | process_date desc, shift_code, stream_code (contaminationRows.ts:38); id desc (:58) |
| /operation/devices | CellsTable→DataTable — CellsTable ×2 | — | none | — | — | code (page.tsx:51) |
| /operation/equipment | CellsTable→DataTable — CellsTable | — | none | — | — | equipment_code (page.tsx:40) |
| /operation/handovers | DataTable ×1 (operation/handovers/HandoversTable.tsx:70) | — | none | — | — | handover_date desc (page.tsx:46) |
| /operation/operation-types | DataTable ×1 (operation/operation-types/OperationTypesTable.tsx:47) | — | none | — | — | sort_order (page.tsx:31) |
| /operation/orders | DataTable ×1 (operation/orders/WorkOrdersTable.tsx:75) | — | none | — | — | created_at desc (page.tsx:42) |
| /operation/processing | DataTable ×1 (operation/processing/ProcessingTable.tsx:94) | URL only, no header links | ?page= 20/page (processingQuery.ts:17; page.tsx:70; processingRows.ts:29) | sort, dir (no UI control — see §4) | **date_from/date_to on process_date** (ProcessingToolbar.tsx:35,42; processingQuery.ts:51-52) | URL sort, default created_at desc (processingQuery.ts:33-34,53) |
| /operation/weighbridge | CellsTable→DataTable — CellsTable | — | cap 200 + RowCapNotice (ticketsRows.ts:14; page.tsx:72) | — | — | created_at desc, ticket_id (ticketsRows.ts:28) |
| /operation/wip | DataTable ×1 (operation/wip/WipTable.tsx:72) | — | none | — | — | batch_code (page.tsx:35) |
| /output | DataTable ×1 (output/OutputTable.tsx:126) | server (OutputTable.tsx:132) | ?page= 20/page (outputQuery.ts:45; page.tsx:134; outputRows.ts:62) | q, state, customer_id, material_id, sort, dir | **date_from/date_to on output_date** (OutputToolbar.tsx:121,128; outputQuery.ts:157,160) | **server sort**, default created_at desc (outputQuery.ts:76-77,180) + id |
| /purchasing/licences | DataTable ×1 (purchasing/licences/LicenceTable.tsx:83) | — | none | — | — | valid_until asc nulls last (page.tsx:72) |
| /purchasing/orders | DataTable ×1 (purchasing/orders/OrdersTable.tsx:148) | — | ?page= 20/page (page.tsx:26,65; orderRows.ts:108,137) | supplier, status | **date_from/date_to on order_date** (OrdersToolbar.tsx:36,43; orderRows.ts:66-67) | order_date desc, id (orderRows.ts:106-107,135-136) |
| /purchasing/payment-terms | DataTable ×1 (purchasing/payment-terms/TemplatesTable.tsx:65) | — | none | — | — | name (page.tsx:44) |
| /quality/coa | DataTable ×1 (quality/coa/CoaTable.tsx:86) | — | none | — | — | issued_at desc (page.tsx:24) |
| /quality/disputes | DataTable ×1 (quality/disputes/DisputesTable.tsx:50) | — | none | — | — | created_at desc (page.tsx:35) |
| /quality/ncr | DataTable ×1 (quality/ncr/NcrTable.tsx:57) | — | none | — | — | opened_at desc (page.tsx:34), then JS open-first (page.tsx:39) |
| /quality/samples | DataTable ×1 (quality/samples/SamplesTable.tsx:68) | — | none | — | — | created_at desc (page.tsx:40) |
| /safety/environment | DataTable ×1 (safety/environment/EnvironmentTable.tsx:35) | — | cap 300 + RowCapNotice (envRows.ts:17; page.tsx:92) | corrects | — | sampled_on desc, recorded_at desc, id (envRows.ts:36-38) |
| /safety/incidents | DataTable ×1 (safety/incidents/IncidentsTable.tsx:42) | — | none | — | — | occurred_at desc (page.tsx:40) |
| /safety/inspections | DataTable ×2 (safety/inspections/InspectionTables.tsx:36, safety/inspections/InspectionTables.tsx:58) — 2 tables | — | runs cap 200 + RowCapNotice (runRows.ts:16; page.tsx:85) | — | — | templates: is_active desc, code (page.tsx:39); runs: inspected_at desc, id (runRows.ts:31-32) |
| /sales/commissions | DataTable ×1 (sales/commissions/CommissionsTable.tsx:95) | — | none | — | — | valid_from desc (page.tsx:52) |
| /sales/customers | DataTable ×1 (sales/customers/CustomersTable.tsx:126) | server (CustomersTable.tsx:132) | ?page= 20/page (customerQuery.ts:18; page.tsx:77; customerRows.ts:31) | q, sort, dir | — | **server sort**, default created_at desc (customerQuery.ts:38-39,71) |
| /sales/orders | DataTable ×1 (sales/orders/SalesOrdersTable.tsx:43) | — | cap 200 + RowCapNotice (ordersRows.ts:17; page.tsx:41) | — | — | order_date desc, id (ordersRows.ts:33-34) |
| /sales/quotes | DataTable ×1 (sales/quotes/QuotesTable.tsx:92) | — | cap 200 + RowCapNotice (quotesRows.ts:14; page.tsx:44) | — | — | quote_date desc, quote_id (quotesRows.ts:23-24) |
| /settings/deleted | DataTable ×1 (settings/deleted/DeletedTable.tsx:86) | — | none | kind | **from/to on deleted_at** (page.tsx:230,232; :128,131) | deleted_at desc (page.tsx:126) |
| /settings/dictionaries | DataTable ×1 (settings/dictionaries/DictSection.tsx:180) | — | none | table, extras | — | sort_order (page.tsx:132) |
| /settings/import | DataTable ×1 (settings/import/ImportHistoryTable.tsx:48) — main content is the import form; the table is its history | — | history cap 20 + RowCapNotice (importRows.ts:18; page.tsx:83) | — | — | imported_at desc, id (importRows.ts:33-34) |
| /settings/pending-values | CellsTable→DataTable — CellsTable | — | none | — | — | value_code, item_code (page.tsx:30) |
| /settings/reference | DataTable ×1 (settings/reference/PermissionReferenceTable.tsx:59) | — | none | — | — | sort_order (page.tsx:45) |
| /settings/roles | DataTable ×1 (settings/roles/RolesTable.tsx:70) | — | none | — | — | sort_order (page.tsx:37) |
| /stocktakes | DataTable ×1 (stocktakes/StocktakesTable.tsx:55) | — | ?page= 20/page (page.tsx:17,56; stocktakeRows.ts:32) | — | — | created_at desc, id (stocktakeRows.ts:30-31) |
| /suppliers | DataTable ×1 (suppliers/SuppliersTable.tsx:108) | server (SuppliersTable.tsx:114) | ?page= 20/page (supplierQuery.ts:22; page.tsx:68; supplierRows.ts:40) | q, status, sort, dir | — | **server sort**, default created_at desc (supplierQuery.ts:47-48,86) |
| /suppliers/scorecards | DataTable ×1 (suppliers/scorecards/ScorecardsTable.tsx:32) | — | none | — | — | supplier_code (page.tsx:36) |
| /tools/pricing/formulas | DataTable ×2 (components/pricing/TermsRequestsPanel.tsx:106, tools/pricing/formulas/FormulasTable.tsx:100) | — | none | — | — | code desc (page.tsx:46) |
| /tools/pricing/metal-prices | DataTable ×1 (tools/pricing/metal-prices/MetalPricesTable.tsx:143) | server (MetalPricesTable.tsx:149) | ?page= 20/page (metalPricesQuery.ts:23; page.tsx:133; metalPricesRows.ts:45) | metal, sort, dir | — | **server sort**, default price_date desc then metal (metalPricesQuery.ts:43-44,73,77) |
### 2b. DataTable props across ALL call sites (second denominator)

Measured by `dt.py` over every `.tsx` under `app/`: an opening tag counts as a real call site when it has `rows=`/`columns=` (6 matches are inside comments).

| | 2026-10-23 queue entry (`docs/forward-queue.md:1578`) | Re-measured 2026-10-25 |
|---|---|---|
| Denominator | "183 files" | **235 real `<DataTable>` call sites in 182 files** (184 files contain the text `<DataTable`, 2 only in comments: `editable-table.tsx`, `input.tsx`) |
| sorting | ~8 | **8 sites / 8 files** — 7 `mode: 'server'`: `tools/pricing/metal-prices/MetalPricesTable.tsx:149`, `materials/MaterialsTable.tsx:160`, `suppliers/SuppliersTable.tsx:114`, `sales/customers/CustomersTable.tsx:132`, `output/OutputTable.tsx:132`, `inbound/InboundTable.tsx:204`, `finance/fx/FxRatesTable.tsx:88`; 1 `mode: 'client'`: `brand-sampler/Base1.tsx:105` |
| columnToggle | ~2 | **1** — `brand-sampler/Base1.tsx:108` |
| filter (in-table search) | ~1 | **1** — `brand-sampler/Base1.tsx:106` |
| pageSize (client paging) | ~1 | **1** — `brand-sampler/Base1.tsx:107` |
| selection | ~1 | **2 sites / 1 file** — `finance/processing-costs/CostSettlePanel.tsx:150,177` |
| footer | 0 | **0** |
| (others) exportSpec 223 · empty 179 · rowClassName 33 · className 19 · caption 1 (Base1) | | |

So outside the design sampler, the only switched-on capabilities in production code are server sorting (7) and selection (1 file). Every client-side capability (client sort, column toggle, search, client paging) is on only in `brand-sampler`.

EditableTable, for completeness: 28 real call sites in 25 files; `footer` 3 (`sales/quotes/[id]/QuoteLinesEditor.tsx:167`, `me/MySelfAssessmentPanel.tsx:194`, `hr/reviews/GoalsEditor.tsx:248` — note EditableTable's `footer` is the page's submit area drawn after `</table>`, `editable-table.tsx:235`); `totals` (EditableTable's totals row) 1 — `hr/payroll/PayrollGrid.tsx:429`. Hand-built `<table>`: 34 matches in 30 files repo-wide (some are comments).

## 3. Money lists

**Denominator: the 84 A pages.** A page counts when a column on its table(s) is a money amount: found by `exportAs: … xMoney(…)` / `xNum(…, 'money')` on the column (money.py), plus a read of CellsTable pages' export maps (`finance/electricity/page.tsx:77-82`). **26 / 84** — 24 with amounts, 2 with unit prices only (formulas, metal-prices).

Legend — Masked: column shows 「受限」 to some readers (MaskedValue / `xMasked` / `*_masked` view). Ccy: "per-row" = a row-level currency (can differ between rows on one screen), "base" = one currency for the column. Server-paged: the screen is a slice, so an on-screen sum is not the filtered total.

| Route | Amount column(s) (file:line) | Masked? | Currency | Paged / capped? | Existing total anywhere? |
|---|---|---|---|---|---|
| /contracts | settlements `amount` (ContractsTables.tsx:187) | **No** — page needs only `module.suppliers.view`; known side finding (docs/table-export.md, 2b side finding) | USD only | no | none |
| /finance/assets | `cost` (AssetsTable.tsx:96), `costBase` (:107), `accum` (:116), `nbv` (:121); preview `delta` (DepreciationPreviewTable.tsx:41) | No (data.view_prices gates only disposal decisions) | **per-row** cost ccy + base columns | no | preview has a total row (`isTotal`, DepreciationPreviewTable.tsx:36) |
| /finance/bank | transfers `out` (TransfersTable.tsx:79), `in` (:84) | No | **per-row** from/to ccy | cap 50 | none |
| /finance/bank/statements | `opening` (StatementsTable.tsx:59), `closing` (:64) | No | **per-row** | ?page= 20 | none |
| /finance/claims | `amount` (ClaimDecisionPanel.tsx:93) | No (canViewPrices gates deciding) | **per-row** | no | none |
| /finance/close | `debits` (CloseHistoryTable.tsx:61), `credits` (:65); year `netResult` (YearCloseHistoryTable.tsx:30) | No | base | no | none |
| /finance/credit-notes | `total` (CreditNotesTable.tsx:76) | customer name masked, amount not | **per-row** | ?page= 20 | none |
| /finance/electricity | `amount` bill, `runs`, `overhead` (page.tsx:77,81,82; columns :132-138) | **Yes** (`xMasked`, showPrices; `electricity_allocations_masked`) | base | no | none |
| /finance/expenses | `amount` (ExpensesTable.tsx:59) | No | **per-row** (amount_ccy) | ?page= 20 | **Yes — summary line "N items · total" of the whole filtered set in base ccy** (page.tsx:65-77, 132-137); computed from one unpaged read, so subject to the 1,000-row read limit (READ-ALL-STOPS-AT-1000) |
| /finance/freight | `amount` (FreightTable.tsx:44) | No | base | cap 200 | none |
| /finance/invoices | `total` (InvoicesTable.tsx:106), `settled` (:112), `open` (:117) | **Yes** total + open (`invoices_masked`, xMasked) | base | ?page= 20 | none |
| /finance/journal | `amount` (JournalTable.tsx:62) | **Yes** (MaskedValue; `journal_lines_masked`) | base (in header) | ?page= 20 | none |
| /finance/payment-requests | `amount` (PaymentRequestsTable.tsx:54) | No | **per-row** | ?page= 20 | none |
| /finance/payments | `amount` (PaymentsTable.tsx:58) | No | **per-row** | ?page= 20 | none |
| /finance/self-approved | `amount` (SelfApprovedTable.tsx:52) | **Yes** for health claims (`data.view_health`, xRestricted) | **per-row** | no | none |
| /finance/supplier-statements | `closing` (StatementsTable.tsx:22) | No | base | cap 300 | none |
| /finance/wht | `withheld` (WhtTables.tsx:38), `remitted` (:43), `unremitted` (:48), `amount` (:98) | No | base | no | none |
| /hr/claims | `amount` (ClaimsTable.tsx:57) | **Yes** (xMasked, data.view_health) | SGD fixed | cap 300 | none |
| /hr/payroll | `gross` (PayrollPeriodsTable.tsx:62), `net` (:68) | **Yes** (`payroll_periods_masked`, data.view_pay) | **per-row** (`currency` column :60) | no | none (columns are per-period totals) |
| /inventory | `avgPrice` (InventoryTable.tsx:85), `stockValue` (:91), `costValue` (:106), `marketValue` (:113) | **Yes** (data.view_prices) | base, except marketValue in USD | no | **Yes — valuation bar** (page.tsx:326-328 sums, :418-445 render; 「受限」 when masked; USD market value deliberately separated) |
| /logistics/forwarders | `owed` (ForwardersTable.tsx:73) | **Yes** (xRestricted) | **per-row** (owedCcy) | no | none |
| /me | claims `amount` SGD (MyClaimsPanel.tsx:51); expense claims `amount` (MyExpenseClaimsPanel.tsx:170); payslips gross/CPF/deductions/net (MyPayslipsTable.tsx:71-87) | own data via `*_masked` views | SGD / **per-row** | caps 50 | none |
| /purchasing/orders | `net` (OrdersTable.tsx:89), `tax` (:96), `gross` (:101), `prepaid` (:107) | **Yes** (`purchase_orders_masked`, data.view_purchase_prices) | **per-row** + prepaid base | ?page= 20 | none |
| /sales/commissions | `rate` = rate % **or** money amount in one column (CommissionsTable.tsx:70) | No | **per-row** | no | none |
| /tools/pricing/formulas | treatment charge USD/t (FormulasTable.tsx:66) — price | **Yes** (`pricing_formulas_masked`) | USD | no | none |
| /tools/pricing/metal-prices | `price_usd_per_tonne` (MetalPricesTable.tsx:74) — price | No | **per-row** quote ccy | ?page= 20 | none |

Roll-up over the 26: masked for some readers **10** (electricity, invoices, journal, self-approved, hr/claims, hr/payroll, inventory, forwarders, purchasing/orders, formulas; /me shows the reader's own rows through `*_masked` views); per-row currency possible **15** (assets, bank, bank/statements, finance/claims, credit-notes, expenses, payment-requests, payments, self-approved, hr/payroll, forwarders, me, purchasing/orders, commissions, metal-prices — 14 if the price-only metal-prices page is left out); server-paged `?page=` **9** (bank/statements, credit-notes, expenses, invoices, journal, payment-requests, payments, purchasing/orders, metal-prices) and capped **5** (bank 50, freight 200, supplier-statements 300, hr/claims 300, me 50) — **14** where an on-screen sum would not be the total of all matching rows; the other 12 read everything in one query, which silently stops at 1,000 rows; **already shows a total: 2** (expenses summary line, inventory valuation bar) + 1 preview total row (assets depreciation preview). No DataTable `footer` is used anywhere.

Money on non-A pages (for reference, not in the 26): R — balance-sheet / pnl / trial-balance (hand `<tfoot>` totals), receivables / payables (summary bar + per-counterparty total rows), cashflow, cash-forecast (cross-currency totals note, ForecastGrid.tsx:197), list-vs-ledger, price-exposure (InventoryExposureSection.tsx:44 total), revaluation, margin (coverage sentence page.tsx:182-183), sales/customers/overlap, inventory/reports/snapshot (total bar page.tsx:63-66); P — payroll-payments, processing-costs (masked).

## 4. Server-side sorting today

**8 / 84** list pages sort in the database from the URL; **7** of them expose it as DataTable header links (`sorting={{ mode: 'server', coverage: { shown, total }, active: { key: sort, dir }, href }}`).

Implementation (same shape on all 8): a `*_SORTABLE` whitelist in a `*Query.ts`; `parse…Params` accepts `?sort=` only if it is in the whitelist, else the default; `?dir=asc` else `desc`; `chain.order(sort, { ascending: dir === 'asc' })`; a stable tiebreak `.order('id')` in `*Rows.ts` before `.range()`. Columns marked `sortable: true` render as links built by the page's `href(key, dir)`.

| Route | Whitelist (file:line) | Default | Header links |
|---|---|---|---|
| /inbound | INBOUND_SORTABLE code, arrival_date, created_at, quantity, remaining_qty… (inboundQuery.ts:25) | created_at desc (:82-83) | InboundTable.tsx:204 |
| /output | OUTPUT_SORTABLE (outputQuery.ts:24) | created_at desc (:76-77) | OutputTable.tsx:132 |
| /materials | code, name, created_at (materialQuery.ts:13) | created_at desc (:51-52) | MaterialsTable.tsx:160 |
| /suppliers | legal_name, code, status, created_at (supplierQuery.ts:8) | created_at desc (:47-48) | SuppliersTable.tsx:114 |
| /sales/customers | legal_name, code, created_at (customerQuery.ts:8) | created_at desc (:38-39) | CustomersTable.tsx:132 |
| /finance/fx | rate_date, currency, rate_type, rate_sgd_per_unit (fxQuery.ts:6) | rate_date desc, then currency (:31, :53) | FxRatesTable.tsx:88 |
| /tools/pricing/metal-prices | price_date, metal, price_usd_per_tonne… (metalPricesQuery.ts:9) | price_date desc, then metal (:43, :77) | MetalPricesTable.tsx:149 |
| /operation/processing | process_date, created_at (processingQuery.ts:7) | created_at desc (:33-34) | **none** — ProcessingTable.tsx:6-8 says the toolbar owns sort, but ProcessingToolbar.tsx has no sort control (grep `sort` = 0 hits), so `?sort=` is reachable only by typing the URL |

`lib/sortCollation.ts` is **not** involved in server sorting — the database's collation orders those rows. It is used only for in-JS sorting: DataTable client mode (`data-table.tsx:64,459`), `/inventory` (page.tsx:14,310), `/hr/kpi/score` (page.tsx:18,139), `/operation/yield` (page.tsx:19), `/tools/calendar/sources.ts:41`; `lib/orgTree.ts:27-41` keeps a checked copy. Rule: always `'en'` collation regardless of UI language.

## 5. Print and sticky

- **Print stylesheet: none.** `@media print` 0 hits, Tailwind `print:` variants 0 hits, `window.print` 0 hits in `app/` / `lib/` / CSS. The only print call is the label printer's hidden-iframe `contentWindow.print()` (`app/components/labels/LabelPrinter.tsx:66`). Printing today goes through server PDF routes (13 `…/pdf/route.ts`, e.g. `inventory/reports/{ledger,snapshot,safety,violations}/pdf/route.ts`), not the browser.
- **Sticky table headers: none.** DataTable's `<thead>` (`data-table.tsx:606`) has no sticky class; `table-style.ts:32` says layout classes including `sticky` are the caller's job, and no caller adds one. The only sticky usages: top nav header (`TopNav.tsx:112,221`, `sticky top-0 z-50` — a sticky thead would need `top` = nav height, see `globals.css:365,452`), a sticky **first column** in the cash-forecast grid (`finance/cash-forecast/ForecastGrid.tsx:243,257`, `sticky left-0`) — the one existing "frozen first column" — the menu panel footer (`nav/MenuPanel.tsx:78`) and a stocktake detail save bar (`stocktakes/[id]/page.tsx:243`).
