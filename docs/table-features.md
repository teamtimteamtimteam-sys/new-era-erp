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

## The rulings — Tim 2026-10-26 (TABLE-FEATURES-2 Step 0), verbatim

Step 0: `docs/surveys/TABLE-FEATURES-2/step0.md` and its survey files (`survey-totals.md` · `survey-presets.md` · `survey-overflow.md`).

| # | Ruling |
|---|---|
| Q1 | No footer on bank statements, close, or supplier statements (their amount columns are balances or running totals). Footers go on the other 21 amount lists. Also no total on any other balance-type column you identified. |
| Q2 | Totals are net: a reversal cancels its original, so a reversed pair adds 0, agreeing with the ledger. |
| Q3 | Commissions: total only the fixed_amount rows, one total per currency. |
| Q4 | Payments list: two totals per currency, "received" and "paid", not netted. |
| Q5 | Add a small database function returning only fy_end_month and fy_end_day to any logged-in user, in the same migration as the totals functions. |
| Q6 | Presets end at the period end (month end, quarter end, year end), as the P&L does today. |
| Q7 | Allow max-w-full on filter dropdowns in list toolbars only, and record that exception in docs/variant-c-spec.md §4.1d in the same commit, with its cost (a long name is cut off in the closed box on a phone; the open picker shows the full name). /purchasing/orders and /inbound must then read 0 whole-page overflow at 390 px. |
| Q8 | /hr/leave showing only requests wholly inside the range: not changed here; register it in docs/known-issues.md. |
| Q9 | Fix the inventory ledger's 90-day default window (the UTC off-by-one between midnight and 08:00) in this cut. Register the other three (ledger "clear the dates" does nothing; balance sheet; StatementPanel) in docs/known-issues.md. |

Your own decisions are accepted: any hidden amount makes that currency's total read 「受限」; 「受限」 on lists where the reader cannot see some rows is decided per reader; labels stay "This year / 今年"; first_fy_end is respected as the year-close does; P&L and cash flow use the same four presets from the shared helper; the side findings are registered, not fixed. The existing expenses summary line and inventory valuation bar are replaced by the new database totals.

SPLIT: not split (Tim). Reason: the last cuts ran at well under their estimates (TF-1 estimated about 11 h, done in about 2.5 h). Safeguard: if midway it will not fit this session, finish the part in hand, queue the rest as TF-2b with the rulings copied verbatim, run the full verify chain on what is done, push, and say so plainly in the report.

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

## How TF-2 is built (v1.4.75)

- **Footer totals:** one database function per list (`db/functions/list_totals_*.sql`, 24 functions for the 21 pages: /me has three, /finance/wht two),
  plus `inventory_stock_by_material()` — /inventory's rows and footer now come from the same SQL (the old JS aggregation and the valuation bar are gone).
  Every function starts with `require_permission(<the page gate>)`, reads the relation the page reads (masked views; `journal_lines_masked`, never `journal_lines`),
  applies the page's own filters (including those the page used to apply in JS), and returns `(grp, currency, measure, total, restricted)`.
  The pattern and the per-page rules: `docs/surveys/TABLE-FEATURES-2/build-pattern.md`; per-page facts: `survey-totals.md`.
- **Date presets:** `lib/datePresets.ts` · `lib/datePresetsServer.ts` · `app/components/ui/date-presets.tsx` on the 11 from/to pages; P&L and cash flow use the same helper
  (four presets, Singapore time, "this year" = the financial year from `fiscal_year_end_setting()`). The three GET-form pages key their form on from/to so the uncontrolled date boxes remount.
- **Overflow:** `${CONTROL_SELECT} max-w-full` on the filter selects of `/purchasing/orders` and `/inbound` (Q7).
- **Decisions taken while building TF-2** are listed in `docs/handbacks/TABLE-FEATURES-2.md` §4.

## The rulings — Tim 2026-10-26 (TABLE-FEATURES-3 Step 0), verbatim

Step 0: `docs/surveys/TABLE-FEATURES-3/step0.md` (and `survey-lists.mjs` → `survey-lists.tsv`).

| # | Ruling (Tim 2026-10-26) |
|---|---|
| Q1 | Saved views on the 29 list pages that have filters in the address. The 55 sort-only lists get no saved views and no queue item; any list that later gains filters gets saved views through the same shared component. Moving browser sort into the address is needed only where those 29 pages sort in the browser (8 pages), each table with its own key. |
| Q2 | When a view is saved with dates that match a preset, store the preset name and compute the dates each time the view opens; a view with hand-typed dates keeps those dates. |
| Q3 | A default view applies only when the list is opened with nothing in the address; a link that carries its own parameters (from reminders, audit trails or elsewhere) is never overridden. The views menu always offers "plain list". |
| Q4 | Bulk-approve proof as you proposed: inside ONE rolled-back transaction, throwaway accounts from the shared helper; the approver is given the real cfo role as a NEW user_roles row that the rollback removes (Tim's explicit one-off exception to the rule that throwaways never hold system roles; no existing row is modified); three journal requests, one raised by the approver; the single-click decide function run on each in turn; expected two approved and one refused with SELF_APPROVAL_FORBIDDEN. Afterwards read back that 0 throwaway accounts exist and 0 user_roles rows grant cfo to anyone but the real cfo holder. The result list is proved in a local test with a mix of done and refused items; on live, only the bulk bar and select-all are shown, with nothing pressed. This exception is done by this session itself, never by a sub-agent. |
| — | Grilling changes accepted: card lists (journal, warehouse, asset disposal, expense-claim queue) get a checkbox per card; bulk is not added to the terms panel on /contracts/[id] or the formula edit page; the leave reject rule lives in the decide function, not a table constraint. |

**Correction recorded (measured while building, 2026-10-26):** the filter pages are **28**, not 29. Step 0's count used a two-pass regex that can leave one
non-filter key behind; it left `corrects` on `/safety/environment`, which pre-fills a correction form and filters nothing. Re-counted by splitting the keys:
28 pages with a real filter, 8 of them browser-sorted (19 tables), 56 sort-only. Q1 is built on the 28 — the ruling's subject ("the list pages that have filters
in the address"), not its count. Also: the terms panel's requests are **cards** (its DataTable is each request's change table), so 5 of the 7 bulk lists are card
lists and only the weighbridge drafts are a table.

## How TF-3 is built (v1.4.76)

### Saved views (Q3 · Q1–Q3)
* **Table** `saved_views` (`db/tables/saved_views.sql`): one row per (person, list, name), `query` = the address after `?`; at most one `is_default` per
  person per list (partial unique index); RLS own rows only (no write gate — like `notification_reads`); anon nothing; not in the change log (exclusion 10).
* **Shared parts:** `lib/savedViews.ts` (pure: `encodeViewQuery` drops paging and one-off keys and stores a matching quick range as `date_preset=<name>`;
  `resolveViewQuery` / `viewHref` turn it back into today's dates) · `lib/savedViewsServer.ts` `loadSavedViews` (reads the person's views; **redirects to the
  default only when the address is empty**) · `app/components/ui/saved-views.tsx` `<SavedViewsBar>` (views as links, current one bold, default ★,
  "Plain list" = `?view=plain`, "Save view", "Manage views": make default / remove default / delete) · `app/components/ui/saved-view-actions.ts`.
* **Each of the 28 pages:** `loadSavedViews` right after the client is made (before any other query — the default is a redirect); the 10 date pages pass
  `{ fromKey, toKey, presets }` (presets moved up from where TF-2 read them). **A list that gains filters later: the same two lines.**
* **Browser sort in the address (the 8 pages, 19 tables):** `sorting: { mode: 'client', coverage: 'complete', url: clientSortUrl(useSearchParams(), '<prefix>') }`
  on DataTable / EditableTable; clicking a header writes `<prefix>sort` / `<prefix>dir` with `history.replaceState` (Next 16 keeps `useSearchParams` in step).
  Prefixes: compliance pack sections `bal_ roll_ cat_ chk_ inc_ env_ ins_ find_` · assets `asset_ dep_` · close `close_ yclose_` · packs `hist_ recon_ split_` ·
  the four single-table pages none.

### Bulk actions (Q2 · Q4)
* `lib/bulkRun.ts` (pure): `runOneAtATime` calls the item's **own single-click action**, one item at a time, in screen order; a refusal or a thrown call is that
  item's outcome and the batch goes on. `toggleAllOnScreen` = select-all ticks only the rows on screen.
* `app/components/ui/bulk-decision-bar.tsx`: `<BulkDecisionBar>` (select all on screen · N selected · Approve selected · Reject selected with one reason for the
  batch · result list `data-slot="bulk-results"`, each item done or refused with its own reason) · `<BulkCheck>` per card · `<BulkScope>`/`<BulkScopeCheck>`/
  `<BulkScopeBar>` for the server-rendered weighbridge drafts table.
* Wired: journal · warehouse · asset disposal · terms (prop `bulk`, on `/contracts` and `/tools/pricing/formulas` only) — approve + reject; expense-claim queue ·
  weighbridge drafts — reject only. The bar sits inside the same `PermissionGate` as the single-item buttons.
* Proof: `scripts/check-bulk-run.mjs` (local, a done/refused/thrown mix, with a fault injection) · the Q4 rolled-back live arm in
  `db/scripts/2026-10-26-table-features-3-live-proof.mjs`.

### Reject reasons (Q11)
`decide_leave_request` / `decide_medical_claim` raise `LEAVE_REJECT_REASON_REQUIRED|<code>` / `MEDICAL_CLAIM_REJECT_REASON_REQUIRED|<code>` on a blank reason
(`btrim`, the same test as the twelve engine chains); the server actions refuse blank first; the Reject buttons on `/hr/leave/[id]` and `/hr/claims/[id]` are
ConfirmButtons with a required reason. Fixture 293.
