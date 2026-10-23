# Table export — Excel and CSV on every table (TABLE-EXPORT)

Tim 2026-10-20 (EXPENSE-MULTILINE-1 Step 0 Q15): every table in the system gets Excel (.xlsx) and CSV export as **one** unified
feature, hung off the shared table layer, not added page by page. Scheduled by Tim 2026-10-22; built in three cuts (Q15).

**Hard rules (Tim's brief, not questions):**
- An export never contains more than the reader can see on screen — the file is built from the rows the page itself read
  (`*_masked` views, the same guard), and from the table's own columns.
- Excel cells are typed: amounts and quantities are numbers, dates are real dates, not text.
- A new library is pinned to an exact version and its licence stated.

## The rulings — Tim 2026-10-22 (TABLE-EXPORT-1 Step 0)

| # | Ruling |
|---|---|
| Q1 | This round covers the **114 list pages** only. The 57 detail-page tables and the hand-built finance reports go to TABLE-EXPORT-3. |
| Q2 | Export the rows **as currently filtered and sorted**, every page of results (not only the page on screen), every column the table defines including ones hidden on a phone. Row selection does not narrow the export. |
| Q3 | Restricted columns stay in the file with each cell reading **"Restricted" / 「受限」**, exactly as on screen; never blank. (This also fixed the old `inbound/export`, which wrote a masked price as an empty cell.) |
| Q4 | **No export logging** in this round — `docs/pdpa.md:119-148` stands. |
| Q5 | The **9 plain list exports are replaced** by the unified export. The **5 special exports** (GST F5, general ledger, AR ageing, AP ageing, management pack) keep their layouts. The supplier and customer exports **keep their extra columns** (tax ID, payment terms, address) as a declared per-table extension. |
| Q6 | Headers and bilingual data labels follow the **user's interface language**. |
| Q7 | Timestamps in **Singapore time**, as real Excel date cells. This settles DATE1-CSV-UTC for the unified export only; the 5 special exports are unchanged in this respect. |
| Q8 | The server fetches in batches of **1,000 up to a cap of 50,000 rows**. Above the cap it refuses, states how many rows matched and asks for narrower filters. Never a silent truncation. |
| Q9 | File names: `<table-name-in-English>_<YYYY-MM-DD>_<HHmm>.xlsx / .csv`, Singapore time, ASCII only. |
| Q10 | **No separate export permission**: anyone who can see a table can export it. |
| Q11 | The export's columns are **the table's columns exactly**, except the supplier and customer extension in Q5. |
| Q12 | **No totals row.** The Excel file gets a second sheet **"About"** (table name, active filters, who exported, when); the CSV is pure data. |
| Q13 | **exceljs 4.4.0**, pinned exactly, MIT licence, loaded only when someone exports. |
| Q14 | Layout survey on a sample of 12 pages (one per module plus the paginated ones) at 390 px and desktop; the rest recorded as not measured. |
| Q15 | **Three cuts.** TABLE-EXPORT-1 (v1.4.67): the mechanism, writer, About sheet, build check, the 9 replaced exports, about half the list pages by whole modules, and the 5 special exports paging past 1,000 rows. TABLE-EXPORT-2: the remaining list pages. TABLE-EXPORT-3: detail-page tables and finance reports; the exemption list reaches zero. |

## The rulings — Tim 2026-10-22 (TABLE-EXPORT-2 Step 0)

TABLE-EXPORT-1's rulings Q2–Q13 apply unchanged to every table TABLE-EXPORT-2 converts. These ten are new.

| # | Ruling |
|---|---|
| Q1 | **Split**, because the whole scope does not fit one session. **TABLE-EXPORT-2a** (v1.4.68): every finance exemption entry not moved by Q7; the part B hard limits on finance pages (freight 200, supplier statements 300, bank transfers "recent" 50, frozen forecasts 20); part C as widened by Q9; Q8 on finance tables. **TABLE-EXPORT-2b** (v1.4.69): me, settings, safety, tools, compliance, my-reviews, contracts; part B on the modules TABLE-EXPORT-1 converted (sales, hr, inventory, operation, safety, compliance, /me); Q2's inbox paging and filter moves; Q4; Q8 on non-finance tables; Q10. 2b is queued directly after 2a, before TABLE-EXPORT-3. |
| Q2 | A page that shows only its first N rows gets a notice: **"Showing the first N of M — narrow the filters or export"**; its export fetches every matching row up to the 50,000 cap through a route that runs the page's own read without the limit. Two additions (both 2b): `/operation/capture/inbox` gets real paging instead of a notice; the filters that today run after the cut (hr claims status, `app/hr/claims/page.tsx:42`; inventory ledger material and batch, `ledgerQuery.ts:84-90`) move before the cut so narrowing recovers hidden rows. |
| Q3 | The general "a read with no paging stops at 1,000 rows" problem (fixed-asset net book value, payroll line counts, overtime totals, the expenses page total and the like) is **not** fixed in TABLE-EXPORT-2. Registered as one item in the go-live readiness group (`docs/forward-queue.md`) and in `docs/known-issues.md` § READ-ALL-STOPS-AT-1000, with one shared fix to be chosen then (read in pages, or warn when a read returns exactly 1,000 rows). |
| Q4 | `/settings/change-history`: no export in this round; "show older" gets a notice when it stops at 500 entries (2b). A future export requires a date range — registered under TABLE-EXPORT-3. |
| Q5 | `/me` tables are exported (2b). |
| Q6 | `brand-sampler` moves to a **permanent exemption** with its reason (temporary design reference, made-up data, not in navigation). The exemption list therefore ends TABLE-EXPORT-3 with this one `PERMANENT` entry, not empty. |
| Q7 | The 12 entries that are not record lists move to TABLE-EXPORT-3: previews and report bodies (depreciation preview, revaluation preview, cash-forecast grid, list-vs-ledger, management-pack body, price exposure, cash-flow detail, compliance-pack sections) go with the finance reports; forms and decision panels (bank import preview, electricity allocation preview, payroll-payments panel, processing-cost settle panel) go with the "should editable tables export" question. Dictionaries, the claims decided register and the WHT tables stay in TABLE-EXPORT-2. |
| Q8 | Wherever "—" or a blank stands where 「受限」 belongs, **both the screen and the export** show 「受限」 / "Restricted". Finance tables in 2a (the invoice list's total and open amount); the rest in 2b; the payroll-payments and settle panels follow Q7. |
| Q9 | Part C widened, all in 2a: `cpfDue` receives the raw month, so the unpaid CPF buttons on `/finance/payroll-payments` no longer throw (proven by running); Chinese October–December show 月 correctly; `/me` attendance sorts by date, not by month label; the `/hr/payroll/[id]/edit` month picker is checked and fixed. |
| Q10 | `/hr/reviews` shows a failed read as an error, not an empty list (2b). |

## The rulings — Tim 2026-10-23 (TABLE-EXPORT-2b Step 0)

TABLE-EXPORT-1's Q2–Q13 and TABLE-EXPORT-2's Q1–Q10 still apply. These six are new; the survey behind them is `docs/surveys/TABLE-EXPORT-2b/step0.md`.

| # | Ruling |
|---|---|
| Q1 | The three "recent" tables get the "first N of M" notice and a full export: settings import history (20) in 2b-1; capture "recently confirmed" (50) and contamination "recent checks" (50) in 2b-2. |
| Q2 | Notifications: notice only, no export (same treatment as change-history); the unread count becomes an exact count. 2b-2. |
| Q3 | `/hr/leave/grants` (200) and `/hr/reviews/cycles` (200) are added to part B. 2b-2. |
| Q4 | All 18 non-finance 「受限」 sites are fixed, screen and export, including the 7 that show a false value (PO payment-term amount 0.00, PO header "@ null", masked price as "Unpriced", inbound "unpriced" badge counting masked batches, inventory output and inbound totals 0.00). Pricing formulas' table in 2b-1; the other 17 in 2b-2. |
| Q5 | Edit forms that pre-fill a masked value as blank. Pricing formula edit: fixed in 2b-1 — saving without terms visibility must never turn a masked treatment charge or discount into 0; a masked field is sent as "unchanged"; proven with a rolled-back live test. Employee edit (`identity_no` pre-filled blank, saved as `|| null`): NOT fixed here — measured on a rebuild, recorded, and added to the go-live readiness group and `docs/known-issues.md`. |
| Q6 | **Split**, because the whole scope (about 17.6 h estimated) does not fit one session. **TABLE-EXPORT-2b-1** (v1.4.69): every `TABLE-EXPORT-2` exemption entry in me, settings, safety, tools, compliance, my-reviews and contracts; the part B limits on those modules (safety inspection runs 200, safety environment 300, compliance packs 300, `/me` leave, medical claims and expense claims 50 each, settings import history 20); the change-history 500 notice; `/hr/reviews` failed reads shown as errors on all three reads (Q10, lines 69–71); the formulas table 「受限」 (Q4); the pricing formula edit fix (Q5). **TABLE-EXPORT-2b-2** (v1.4.70): part B on sales, hr (including Q3), inventory and operation; `/operation/capture/inbox` real paging; the two filter moves; capture "recently confirmed" and contamination "recent checks" (Q1); the contamination "missing" count and the notifications unread count as exact counts; notifications (Q2); the other 17 「受限」 sites (Q4). |
| Side finding | Contracts settlement amounts come from `sales_settlements` with no column mask, on a page that needs only `module.suppliers.view`. Not changed in 2b; measured (which live roles hold `module.suppliers.view` without `data.view_prices`), recorded, and added to the go-live readiness group and `docs/known-issues.md`. |

**Where Q2 lives in code (2a):** `app/components/ui/row-cap-notice.tsx` (the notice; it draws nothing when the page shows every row);
each capped page has a `<page>Rows.ts` read module shared with an export route (`freight/export`, `supplier-statements/export`,
`bank/transfers/export`, `cash-forecast/frozen/export`). `lib/export/serverRows.ts` gained `inChunks` (id look-ups in batches of 100,
because an export can carry tens of thousands of ids into a URL) and `exportUnionResponse` (a table whose rows come from two reads:
the invoice list's "all" filter).

## How it works (where each ruling lives in code)

| Piece | File | Rulings |
|---|---|---|
| Typed cells (`xText`, `xNum`, `xMoney`, `xInt`, `xDate`, `xTime`, `xMasked`, `xRestricted`) | `lib/export/cells.ts` | hard rule 2, Q3 |
| Writer (`buildXlsx` with About sheet, `buildCsv`, `exportFileName`, Singapore time) | `lib/export/write.ts` | Q7, Q9, Q12, Q13 |
| Server paging (`fetchAllPages`, `exportRowsResponse` with the 50,000 cap, `exportDenied`) | `lib/export/serverRows.ts` | Q8, Q15 |
| The two buttons above the table | `app/components/ui/table-export.tsx` | Q2, Q10 |
| `exportSpec` on `<DataTable>`; columns become `ExportableColumn` (every column declares `exportAs`, or `false` for a control column) — enforced by `tsc` | `app/components/ui/data-table.tsx` | hard rule 1, Q11 |
| Build check: every table declares its export or is named on the exemption list; the list may only shrink | `scripts/check-table-export.mjs`, `scripts/table-export-exemptions.mjs` | Q15 |

**Where the rows come from.** A table that already holds every row (most of them) exports the rows it holds, sorted and filtered
as displayed, not paged. A server-paginated table (`serverRows`) asks a JSON route next to its page (`<page>/export/route.ts`)
that runs **the page's own read and row mapping** (extracted into a shared server-only module), guarded by the page's own
permission check, paged in batches of 1,000 with a unique tie-break order, refusing above 50,000. Both paths hand the same row
type to the same column definitions, so a column is defined once.

**Masking.** Each column's `exportAs` uses the same test the cell uses on screen: `xMasked(value, canView, xMoney)` is
`<MaskedValue>`'s rule (no permission and NULL → "Restricted"; permission and NULL → empty, because "no value" is a real state).

**The PostgREST row cap.** Live PostgREST has `max_rows = 1000` (measured 2026-10-22). Any read through it stops at 1,000 rows
silently. The paging loop stops on an **empty** page, not a short one, so it stays correct if `max_rows` is ever lowered
(`db/scripts/2026-10-22-table-export-1-paging-proof.mts` P2). Of the 5 special exports, the general ledger and the filed F5
snapshot read row sets and now page; AR ageing, AP ageing and the unfiled F5 return a single `jsonb` value and the management
pack reads one row, so the cap cannot cut them — fixture 291 pins those shapes.

**Currency travels with an amount when the screen writes it in the cell** (decision taken in TABLE-EXPORT-1, not a Tim ruling;
reported in the hand-back). A table whose amounts are in different currencies row by row (purchase orders) would otherwise
export bare numbers that lose the currency the screen shows beside them — the CCY family's "a number wearing the wrong name".
`xMoney(v, ccy)` and `xNum(v, kind, unit)` (the same for a quantity shown as "12 kg" in a column mixing units): in Excel the cell stays a number, with the currency or unit in its number format (`#,##0.00 "USD"`), so it still sums;
in CSV it is written `1234.5 USD`. Where the screen states the currency in the column header instead (most base-currency
tables, via `formatMoneyBare`), the header carries it and the cell is a bare number — exactly as on screen.

**What a cell cannot hold.** One cell holds one typed value, so a few screen cells that show two things export the main one:
a date range (`2026-01-01 → 2026-03-31`) exports as text built from the raw dates; a badge beside a value (expired, ⚠ unapplied
prepayment, "below expected") is not exported where the value it summarises is; composite cells (a progress line, a promise)
export as the text the screen shows. Each conversion names its choice in a comment beside the column.
