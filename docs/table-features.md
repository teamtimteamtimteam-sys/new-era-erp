# Table features — sorting, sticky header, totals, presets, saved views, bulk actions (TABLE-FEATURES)

Queue entry `docs/forward-queue.md` 64c (Tim 2026-10-23). Step 0: `docs/surveys/TABLE-FEATURES-1/step0.md` and its three survey files.
Split into three cuts by Tim (Q13): **TF-1** (v1.4.74) · **TF-2** (v1.4.75) · **TF-3** (v1.4.76).

## The rulings — Tim 2026-10-25 (TABLE-FEATURES Step 0), verbatim

| # | Ruling | Cut |
|---|---|---|
| Q1 | Footer totals on the 24 amount lists (not /tools/pricing/formulas or /tools/pricing/metal-prices); on commissions, total only the rows that hold an amount. A footer totals every row matching the filters, calculated by the database. One total per currency. If any amount in the set is hidden from the reader, the total reads 「受限」/"Restricted". | TF-2 |
| Q2 | Bulk actions: Approve and Reject on the 5 request panels (journal, warehouse, terms on 2 pages, asset disposal); Reject only on the expense-claim queue and weighbridge capture drafts. No bulk withdraw, no bulk export. One reject reason for the batch, written to each item. Items run one at a time through the same action as a single click, so four-eyes, CFO levels and refusals apply per item; the result names every item as done or refused with its own reason. Select-all ticks only the rows on screen. Leave, medical claims, payment requests, POs, overtime and reviews: queued as a follow-up that first adds decisions to their lists. | TF-3 |
| Q3 | Saved views: per user only (sharing later); a view stores the page's filters and sort as the URL query string; one optional default view per user per list; a new table, so a migration. | TF-3 |
| Q4 | Desktop: sticky header on, using a bounded table box, only on tables taller than the screen. 390 px phone: sticky header off. Frozen first column: not built. | TF-1 |
| Q5 | Date presets: this month, last month, this quarter, this year; calendar month and quarter in Singapore time; "this year" reads the configured year end (finance_settings.fy_end_month/day); on all 11 pages with a from/to filter; correct the P&L and cash-flow presets to Singapore time. | TF-2 |
| Q6 | Printing a list: not built. | — |
| Q7 | Default sort unchanged everywhere, except payments, journal, inbound, output and processing sort by their document date, with created time and id as tie-breaks. Approval panels keep oldest-pending first. | TF-1 |
| Q8 | "Every list page" = the 84 table list pages, including the 8 CellsTable pages and the 3 editable tables; the 12 card lists are out. | TF-1 |
| Q9 | The 48 unpaged lists sort in the browser, with sorting switched off whenever a load returns exactly 1,000 rows; the 36 paged or capped lists sort in the database; /operation/processing gets its missing sort control. | TF-1 |
| Q10 | Every table's read-only controls (export, sort, search, page buttons) stay usable on ended records and inside blocks greyed for missing permission: all 12 ended blocks, the 5 permission-greyed tables and the 1 live record. Ships with sorting. | TF-1 |
| Q11 | Leave and medical-claim rejects require a reason, enforced by the database with a named error. | TF-3 |
| Q12 | Fix the /hr/leave ordering (pending requests lifted to the top before the 300-row cap is taken) in TF-1. Register the other three (PO list cannot show or filter approval status; expense claims missing from /tools/reminders; payment-requests default filter mixing awaiting-approval with approved) in docs/known-issues.md and attach them to SYSTEM-MAP-0 (64d) as unified to-do findings. | TF-1 / register |
| Q13 | SPLIT into three cuts. Reason: about 28 h estimated does not fit one session. TF-1 (v1.4.74): sorting (Q7, Q8, Q9), sticky header (Q4), the read-only-controls fix (Q10), the leave ordering fix (Q12). TF-2 (v1.4.75): footer totals (Q1), date presets (Q5). TF-3 (v1.4.76): saved views (Q3), bulk actions (Q2), reject reasons (Q11). Safeguard for TF-1: if midway it will not fit this session, finish the module in hand, queue the rest as TF-1b with the rulings copied verbatim, run the full verify chain on what is done, push, and say so plainly in the report. | — |

**Corrections recorded (Tim 2026-10-25):** list pages are **84** (112 files), not 114; the ended-record issue covers **12 blocks**, not 3 pages;
the queue's feature counts are as re-measured in Step 0 (DataTable call sites 235 in 182 files: sorting 8 files · column toggle 1 · search 1 · client paging 1 · selection 1 file / 2 sites · footer 0; the three 1s only in brand-sampler).

## How TF-1 is built

### Shared parts
- `app/components/ui/data-table.tsx` — client sort takes each column's **export value** as its compare value (`sortKeyFromCell`): numbers as numbers, dates as dates,
  text in the English collation (`lib/sortCollation.ts`, COPY-1-SORT-COLLATION); a 「受限」 cell is `null` and always sorts last, so sorting never reveals a hidden value's size.
  `sortable: false` opts a column out; control columns (`exportAs: false`) never sort. Client sort switches off and says so when a load holds `READ_ROW_LIMIT` (1,000) rows or more.
- Sticky header (desktop only): the table box gets a bounded height (`sm:max-h-[calc(100dvh-6rem)]`) so only tables taller than the screen scroll inside it and their header sticks;
  each `<th>` draws its own 2 px line. Phone: no bound, no sticky. Same in `editable-table.tsx`.
- `app/components/ui/disabled-block.tsx` — every `<fieldset disabled>` goes through `<DisabledBlock>` (build check `scripts/check-disabled-block.mjs`), which tells the tables inside
  that they are in a disabled block; export, client sort, page buttons and the phone expand button then render as `<span role="button">`, which a fieldset cannot disable.
  Write controls are untouched. **Not achievable:** the table's own text search box is an `<input>` and stays grey inside a disabled block (0 production tables use it) — registered as TABLE-SEARCH-IN-DISABLED-BLOCK.
- `lib/listSort.ts` (`parseListSort`, `applyListSort`, `setSortParams`) + `app/components/ui/use-sort-href.ts` for database sorting; `CellsTable` takes `sorting="client"` or a server description.
- `editable-table.tsx` sorts in the browser (Q8 amends CONV-2's Q4 for sorting only); sorting waits while a row is being edited or has unsaved changes, and rows keep their original index for `rowKey`.

### Rules every converted list follows
1. **Browser sort** (the page holds every row from one read): `sorting={{ mode: 'client', coverage: 'complete' }}`. Nothing else is needed — columns sort by their export value.
   Add `sortable: false` only where sorting a column would mislead (e.g. a column mixing a rate and an amount).
2. **Database sort** (the page pages with `?page=` or shows only the first N rows): sort keys are whitelisted (column key → column of the relation the page reads) in the page's rows module;
   the default stays today's ORDER BY (Q7) except the five document-date lists; every order ends with a stable tie-break; the export route reads the same `sort`/`dir`;
   the page's paging links keep `sort`/`dir`; changing sort drops the page number.
3. **Only columns stored on the relation the page reads can sort in the database.** A name looked up elsewhere, a computed figure or composed text is not sortable on a database-sorted list.
4. **A masked value sorts by the masked relation's column** (NULL for a reader who cannot see it), never by a base-table column the reader cannot see.
5. **Money in per-row currencies sorts by its base-currency amount** where the row has one (database: the base column; browser: `sortValue: (r) => r.<baseAmount>`); where the row has no base amount the column is `sortable: false` (database lists simply leave it out of the whitelist) — raw amounts in different currencies do not order meaningfully.
6. Two database-sorted tables on one page use a parameter prefix (`parseListSort(sp, keys, dflt, 'pending_')` / `useSortHref('pending_')`).
7. **A quantity column whose rows can carry different units** (kg, pieces) sorts only while every row on screen shares one unit (`/inventory`, `/operation/wip`); otherwise it is not sortable — the same reasoning as rule 5.

### The checks that keep it true
- `scripts/check-list-sorting.mjs` (in `npm run build`): every `<DataTable>` / `<EditableTable>` / `<CellsTable>` opening tag in the files of the 84 list routes carries `sorting`.
  Exemptions are verified, not trusted: a *detail* panel that lives in a list folder must not be rendered by any file of that list route; a *prop* table must have its list-page caller pass the sorting prop.
  Fault-injected three ways (env `CHECK_LIST_SORTING_FAULT=inject`; sorting removed from `/hr/departments`; a detail panel rendered on `/operation/devices`; `clientSort` removed from `/quality/coa`) — each went red and named the file.
- `scripts/check-disabled-block.mjs` (in `npm run build`): the only hand-written `<fieldset disabled>` is inside `disabled-block.tsx`. Fault-injected (env inject; the old MetalContentPanel fieldset restored) — red, named `MetalContentPanel.tsx:243`.

### Decisions taken while building TF-1 (not asked; reported in the hand-back)
- Sorting a status / type column orders by the stored code, not the translated label (as the pre-existing server-sorted pages already did).
- Columns that show composed text or a looked-up name are not sortable on database-sorted lists; on browser-sorted lists they sort by the text on screen (their export value).
- A capped list keeps its "first N of M" notice; the table's own "sorted over all rows" line now also shows when the screen holds fewer rows than the total, and disappears when it holds them all.
- Detail-page tables were not in scope (Q8 is list pages) with one exception: the batch movement trail (`MovementTimelineTable`) sorts in the browser on both batch edit pages, because it sits inside the ended block of a deleted batch and Q10's "sort stays usable on ended records" needed a sortable table there to mean anything (the live proof runs on it). The CoA, inspection-run and contamination-check tables are shared with detail pages and sort only where the list page passes the prop.

