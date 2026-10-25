# TABLE-FEATURES Step 0 — infrastructure survey (read-only)

Repo: /Users/timchen/Documents/projects/new-era-erp · measured 2026-10-25 · grep/find/read only (no npm, gate, smoke, or script imports).
Two throwaway helper scripts in the scratchpad (`resolve.py`, `gates.py`) do a regex import-walk to depth 3. They only read files.

---

## A. Saved views per user

### A1. Is there a per-user preference table today? **No.**
- `ls db/tables` = 326 mirrors. `grep -liE "user_preferences|user_settings|preferences|saved_view|ui_prefs"` over db/tables, db/migrations and db/views returns **0 files**.
- `employees.sql`, `employee_accounts.sql` and `user_roles.sql` have **no json/jsonb column** (grep `jsonb|json\b` returns 0).
- **There is a precedent, and it was deleted:** `user_dock`.
  - Created by `db/migrations/2026-09-02-iabuild1-the-dock-is-personal-so-it-must-follow-the-person.sql`.
  - Shape: one row per person. `user_id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE`, `hrefs text[] NOT NULL DEFAULT '{}'`, `created_at`, `updated_at`. RLS has four own-row policies (`user_id = auth.uid()`) for select, insert, update and delete.
  - Its header (lines 4–8) records Tim's ruling A5. A **table, not a cookie or localStorage**, because "the only existing preference (language) is a cookie = per device, not per person". Tim wanted the dock to follow him from phone to desktop. That same argument applies to saved views.
  - The header also argues for "absence ≠ empty" (no row = never touched; empty array = deliberately cleared).
  - It was dropped by `db/migrations/2026-09-04-conv6-the-dock-is-deleted-so-the-table-goes-with-it.sql`. The UI went away, so the table went too. That migration also documents the ordering: deploy the code that no longer reads the table first, then drop the table, because the root layout read it on every page.
- Client-side preference storage that exists today:
  - The language cookie: `lib/i18n/actions.ts:9-10` (`cookieStore.set(LOCALE_COOKIE…)`).
  - Avatar-version cookie: `app/me/avatarActions.ts:96`, read in `app/components/TopNav.tsx:197`.
  - Home greeting cookie: `app/components/home/RememberGreeting.tsx:44` (`document.cookie`).
  - Idle cookie: `app/components/IdleWatcher.tsx:43`.
  - localStorage and sessionStorage are used **only for form drafts**: `lib/useFormDraft.ts:10-12,65`. Unrestricted drafts go to localStorage; restricted ones go to sessionStorage, which `app/login/ClearRestrictedDrafts.tsx` clears.
  - Nothing stores table or UI preferences (grep `localStorage|sessionStorage` over app/ and lib/ finds only those 2 files).

### A2. How list pages hold filters today
**Filters live in the URL. Table-internal state lives in client React state.**
- Filters are in the URL:
  - Toolbar/controls/filter files: `find app -name "*Toolbar*.tsx" -o -name "*Controls.tsx" -o -name "*Filter*.tsx"` gives 36 files. **21** of them use `useSearchParams` or `router.replace/push`. All the list toolbars are among the 21:
    - processing, orders (PO), output, inbound, materials, suppliers, customers, training, employees, journal, payments, invoices, fx, bank statements, expenses, cashflow, pnl, balance-sheet, packs, metal-prices, capture.
    - The other 15 are per-record action controls, not filters.
  - `<form method="get">` filter forms: **13 page.tsx files**, for example `app/hr/leave/page.tsx`, `app/finance/assets/page.tsx` and `app/inventory/reports/ledger/page.tsx`.
  - Shared date-range parser: `lib/dateFilter.ts:11` `parseDateRange({date_from, date_to})`, used by 10 files (the inbound/output/processing/PO/journal/payments/invoices/expenses query modules plus pnl and cashflow).
  - Server-side sort through URL links: `sorting={{ mode: 'server' … }}` on **7 tables**: MetalPricesTable:149, MaterialsTable:160, SuppliersTable:114, CustomersTable:132, OutputTable:132, InboundTable:205, FxRatesTable:89. Header hrefs come from `serverSort.href(...)` at `data-table.tsx:685`.
  - Scale: 271 page.tsx files in total; **152** render `<ListPage`, and **101** of those reference `searchParams`. Many of those references are flash/`set`/`error`/`trail` params rather than filters. Counting the toolbars and GET forms above, **about 34 list pages keep real filters in the URL (21 toolbars + 13 GET forms)**. For those, a "view" can be stored as a query string.
- Client state inside DataTable (lost on reload; a saved view would need to lift it to the URL or to stored state), at `app/components/ui/data-table.tsx:430-434`:
  - `useState` for `sort`, `q` (text filter), `page`, `hidden` (column visibility) and `open` (phone row expansion).
  - Usage today: built-in `filter` prop on **0** real pages (the only call site is `app/brand-sampler/Base1.tsx:106`); `columnToggle` on 1 call site; `pageSize` on 1; client sort (`mode: 'client'`) on 1.
  - Practically: the only client state that matters for views today is client sort, plus column visibility if column toggling spreads.
- DataTable call sites: 234 `<DataTable` and 37 `<EditableTable` outside components/ui.

### A3. What a new per-user table needs (repo rules)
1. **Migration** at `db/migrations/<system-date>-<cut>.sql`. The filename comes from the system date (AGENTS.md:2330). Wrap it in `BEGIN; … COMMIT;`.
2. **Backup before migrating** (AGENTS.md:1840 §"The backup runs BEFORE the migration"). Apply with `./db/apply_migration.sh db/migrations/<file>.sql` (AGENTS.md:2237-2248). That script runs `db/preflight_migration.py` and replays `db/views/zzz_function_grants.sql` inside the same transaction (AGENTS.md:2250-2285).
3. **Table mirror** `db/tables/<name>.sql` in the same commit (AGENTS.md:9). It is a first-run CREATE script with columns in live ordinal order and a `NOTE: introduced by …` header (see `db/tables/notification_reads.sql:4`).
4. **RLS:** `ENABLE ROW LEVEL SECURITY` plus own-row policies `user_id = auth.uid()` for select/insert/update/delete.
   - Template: `db/tables/notification_reads.sql:28-43`.
   - `db/check_norole.py:63-65` counts `auth.uid()` as a "judge function", so own-row policies do not trip verdict 7 (no-role surface).
   - Line 144 has a `user_roles` special case for own-row reads. Check whether a no-role session reading **its own** saved views needs a similar note.
5. **Grants:**
   - anon: `db/platform-prelude.sql:132-135` says it in plain words: live no longer gives new tables to anon (COD-2 `2026-09-08-cod2-the-verification-page.sql:59` `ALTER DEFAULT PRIVILEGES … REVOKE ALL ON TABLES FROM anon`), but the rebuild does. So the mirror must carry `REVOKE ALL ON public.<t> FROM anon;`. Otherwise `db/check_grants.py` (verdict 6, baseline `db/anon-grants-baseline.tsv`, which may only shrink) or rebuild drift goes red.
   - authenticated: still gets the full default ACL (`arwdDxtm`, see the memory note on default write grants). Consider `REVOKE TRUNCATE, REFERENCES, TRIGGER`; RLS covers the rest.
   - `supplier_portal` must not gain anything. `db/portal-grants-baseline.tsv` requires exact equality (verdict 8).
6. **change_log coverage (HISTORY-1):** every public table must be either bound to the `zzz_change_log` triggers or listed in `db/functions/change_log_exclusions.sql`.
   - `notification_reads` is excluded as "per-viewer screen state with no business meaning" (line 28). A saved-views table fits the same exclusion.
   - Touches: the function mirror, `scripts/check-change-log-coverage.mjs` (reads those VALUES), and **fixture 235**. It asserts `excluded = 9` exactly (`db/fixtures/235-an-account-is-disabled-not-deleted-and-every-table-is-covered.sql:134`), so it becomes 10.
   - The coverage function: `db/functions/change_log_coverage_gaps.sql`.
7. **Fixture** `db/fixtures/NNN-<sentence>.sql` (297 files; read `db/fixtures/README.md` and `_harness.md` first):
   - `BEGIN … ROLLBACK`, with a per-fixture role and uid harness (`_harness.md`).
   - RLS assertions must **RAISE**, never return a value. A blocked read gives NULL, and a blocked UPDATE is a successful no-op (AGENTS.md:2645-2660).
   - Rows that FK to `auth.users` need `auth.users` rows first (user_dock header).
8. **Generated types:** `npm run types:gen` → `lib/database.types.ts` (package.json:12). The gate compares bytes (AGENTS.md:141). After a DROP, run `NOTIFY pgrst, 'reload schema'` first; run with `DO_NOT_TRACK=1` per the Supabase CLI memory note.
9. **Gate green before push:** `python3 db/gate.py` (AGENTS.md:109-141, 2085). Also the i18n key check for any new strings (AGENTS.md:2289).

**Template to copy:**
- Shape: `user_dock` (one row per user, PK = user_id, FK auth.users ON DELETE CASCADE, four own-row policies). It is the closest to "my saved views".
- Mirror format: `notification_reads` (`db/tables/notification_reads.sql`, created in `db/migrations/2026-08-13-ntf1-notification-center.sql:127-155`). Note it predates COD-2: it still holds anon grants (`db/anon-grants-baseline.tsv:183`), so do not copy its grant posture.
- A saved-views table would more likely be one row per (user_id, list_key, name) with a `query text` column, keeping the same four policies.

---

## B. Sticky header / frozen first column

### B1. What `overflow-x-auto` does to sticky
- `app/components/ui/data-table.tsx:592` `<div className="w-full overflow-x-auto">` wraps the `<table>` (593-602). EditableTable is identical at `app/components/ui/editable-table.tsx:783`.
- CSS overflow rule: if one axis is not `visible`/`clip`, a `visible` value on the other axis computes to `auto`. So `overflow-x: auto` makes `overflow-y: auto` as well, and the div becomes a **scroll container on both axes**.
- `position: sticky` sticks relative to the **nearest ancestor scroll container**, which is now this div, not the viewport.
- The div has no height limit, so it never scrolls vertically. A `<thead>`/`<th>` with `top: 0` therefore **never sticks while the page scrolls**; it scrolls away with the page.
- **Horizontally it does work.** A `left: 0` sticky first column sticks inside this div, because it is the horizontal scroller.
  - There is already a live example: `app/finance/cash-forecast/ForecastGrid.tsx:234` (`overflow-x-auto` wrapper) with `sticky left-0` on th:243 and td:257.
  - Caveat: td:257 uses `bg-inherit`, and the rows have no background except the closing row, so scrolled cells show through. A frozen column needs an opaque background.
- Options for a sticky header:
  - (a) Give the wrapper a max height (for example `max-h-[calc(100dvh-<offset>)] overflow-auto`) so it is the vertical scroller too, then use `th { position: sticky; top: 0 }` inside it.
  - (b) `overflow-x: clip` does not create a scroll container, but it also removes horizontal scrolling. The scroll-mode phone tables rely on that scrolling (`data-table.tsx:160`).
  - (c) A JS-synced header clone.
- Also: the table is `border-collapse` (602, `table-style.ts:124`), and the header line is a `border-b-2` on the `<tr>` (`data-table.tsx:607`). With collapsed borders, a sticky `<th>` does not carry the row border, so a sticky header needs a box-shadow or a border on the th itself.

### B2. App shell scroll container
- The **window/document scrolls**; there is no inner overflow container.
  - `app/layout.tsx`: `<html className="… h-full">` and `<body className="min-h-full flex flex-col">`. Children render as siblings of `<AppChrome>`.
  - `app/components/AppChrome.tsx` renders `<div className="contents">`, which has no box.
  - `ListPage` (`app/components/ui/list-page.tsx:137`) is a plain `<div className="p-8 …">` with no overflow, transform or filter.
  - The `body` rule in globals.css (line 168) sets no overflow.
- Top bar: `app/components/TopNav.tsx:221` `<header className="sticky top-0 z-50 border-b …">` (also :112 for the indeterminate-auth variant).
  - Height: `py-2.5` plus 32px round buttons plus a 1px border, about **53px**. Measured "headerH=53px" in `docs/information-architecture.md:1626`; search box `h-8` at `app/components/nav/SearchShell.tsx:104`.
  - A sticky table header against the window would need `top: 53px` (or a CSS variable) and a z-index below 50.
- Breadcrumbs (`app/components/nav/Breadcrumbs.tsx:36`) are not sticky.
- The only other sticky elements in app/: `app/stocktakes/[id]/page.tsx:243` (`sticky bottom-0`) and `app/components/nav/MenuPanel.tsx:78`.

### B3. Glass / backdrop-filter ancestors
- `backdrop-filter` appears only on `.nav-glass` and `.nav-glass-underlay` (`app/globals.css:445-446, 459-460`), and those are only on floating layers (top bar underlay, dropdowns, drawer, DataTable's column-toggle popover at `data-table.tsx:562`).
- CHART-0 ① moved the glass off `<header>` onto an `absolute inset-0` child precisely so the header stops being a Backdrop Root and a containing block for fixed descendants (`globals.css:403-421`, `TopNav.tsx:213-219`). "Tables never get glass" (TopNav.tsx:210).
- **No glass, transform or filter ancestor sits around list tables.** In any case, containing blocks affect `fixed`; sticky is affected only by scroll containers. The only extra scroll-container risk is `Card` (`app/components/ui/card.tsx:15` `overflow-hidden`). Files that render both `<DataTable` and `<Card`/`<CardContent` = **0**.

### B4. Hand-built `<table>` remaining
- Method: `grep -rnE "<table[ >]"` plus `"<table\s*$"` over `app/**/*.tsx`, excluding `components/ui/{data-table,editable-table,table}.tsx`, then removing comment lines.
- Result: **10 real JSX `<table>` in 10 files**. 18 more grep hits are comments describing past conversions.
  - Finance statements/reports (8): trial-balance/page.tsx:174, receivables/page.tsx:172, payables/page.tsx:176, pnl/page.tsx:190, balance-sheet/page.tsx:205, cashflow/page.tsx:177, month-end/page.tsx:304 (the only one with an `overflow-x-auto` wrapper), cost-variance/page.tsx:52.
  - Plus `app/finance/cash-forecast/ForecastGrid.tsx:240` and `app/hr/reviews/cycles/page.tsx:173` (a layout table inside a card, per its header at :12).
  - All use `tableC.*` from `app/components/ui/table-style.ts`.
- The ratchet `scripts/check-component-library.mjs` has a baseline (`scripts/component-library-baseline.json` `table`) that still lists 35 files / 39. It is a stale upper bound, not today's count.
- The shadcn `<Table>` (`app/components/ui/table.tsx:11`, also `overflow-x-auto`) is used only by `app/brand-sampler/Variant.tsx`.

### B5. EditableTable wrapper (`app/components/ui/editable-table.tsx:776-790`)
```
<div className={cn('w-full', className)}>
  {exportSpec && exportCols && <div className="mb-2 flex …"><TableExportBar … rows={() => savedRows} /></div>}
  <div className="w-full overflow-x-auto">
    <table data-slot="editable-table" className="w-full caption-bottom border-collapse text-sm table-fixed sm:table-auto">
      <thead><tr className="border-b-2 border-[color:var(--brand-ocean)]"> …
```
This is the same structure and the same sticky problem as DataTable. The control strip sits above the scroller in both.

---

## C. Export buttons greyed out inside disabled fieldsets

### C0. Mechanism
- `EndedFieldset`: `app/components/trail/EndedBanner.tsx:93-100` renders `<fieldset disabled aria-describedby=… data-ended-readonly className="m-0 min-w-0 border-0 p-0">` when `ended`.
- `PermissionGate`: `app/components/ui/permission-gate.tsx:141` returns the children untouched when `allowed`; otherwise it wraps them in `<fieldset disabled className="contents">` (:162-164).
- `TaskEditGate`: `app/tools/tasks/TaskEditGate.tsx:61` uses the same mechanism.
- Ad-hoc conditional fieldsets:
  - `app/components/metals/MetalContentPanel.tsx:243` `disabled={!!lockedReason}` (closes at :309).
  - `app/inbound/[id]/edit/PricingPanel.tsx:206` `disabled={!!openRequestLabel}` (closes at :263).
- What `fieldset disabled` disables: every **button / input / select / textarea** descendant. Exception: those inside the fieldset's first `<legend>`.
- It does **not** disable `<a>`/`<Link>` (AGENTS.md:1718: "fieldset disabled does not disable links"; restated at `app/finance/invoices/[id]/page.tsx:343-346`). Nor `<details>/<summary>`.
- Export controls are all `<Button type="button">`, and the download happens in `onClick` (Blob):
  - `TableExportBar` at `app/components/ui/table-export.tsx:68`, buttons at ~:120/:123.
  - `ReportExportBar` / `FlatExportBar` at `app/components/ui/report-export.tsx:47/107`.
  - So **all export buttons die** inside a disabled fieldset.
- Inside DataTable the same fieldset also disables:
  - the search input (:545)
  - client-sort header `<button>`s (:715)
  - pager buttons (:900+)
  - selection checkboxes
  - the column-toggle checkboxes (the `<summary>` still opens)
- Server-sort header **links** keep working (:685).

### C1. Every EndedFieldset site, with exports inside
- Method: `scratchpad/resolve.py` takes each fieldset's line range, collects component tags, resolves their imports, and walks to depth 3, flagging files containing `exportSpec=` / `<TableExportBar` / `<ReportExportBar` / `<FlatExportBar`.
- Caveat: "the file contains an export" ≠ "this exact render path shows it". Conditional rendering is not modelled, and a file seen once per page is not re-reported.

| # | Site (fieldset lines) | Ended when | Export tables inside (component file:line of exportSpec) |
|---|---|---|---|
| 1 | `app/finance/payables/[batchId]/page.tsx:278-281` | payables batch written off (`writtenOff`) | FinanceAttachmentsPanel `app/components/finance/FinanceAttachmentsPanel.tsx:277` — **already registered** |
| 2 | `app/suppliers/[id]/edit/page.tsx:216-271` | supplier `deleted` | ContactsPanel `app/sales/customers/ContactsPanel.tsx:153`; CompliancePanel `app/suppliers/[id]/edit/CompliancePanel.tsx:210` (registered); ScorecardPanel>ReviewForm>MeasuresTable `app/suppliers/MeasuresTable.tsx:58`; AttachmentsPanel `app/suppliers/[id]/edit/AttachmentsPanel.tsx:244` (registered) |
| 3 | `app/materials/[id]/edit/page.tsx:124-135` | material `deleted` | AttachmentsPanel `app/materials/[id]/edit/AttachmentsPanel.tsx:237` (registered) |
| 4 | `app/sales/customers/[id]/page.tsx:254-368` | customer `deleted` (:130 `!!cust.deleted_at`) | StatementPanel `app/sales/customers/StatementPanel.tsx:227`; ContactsPanel `…/ContactsPanel.tsx:153`; OpenItemsTable `app/sales/customers/[id]/OpenItemsTable.tsx:72`; ChasePanel `app/sales/customers/ChasePanel.tsx:326` |
| 5 | `app/sales/quotes/[id]/page.tsx:149-283` | quote `deletedAt` | QuoteLinesEditor `app/sales/quotes/[id]/QuoteLinesEditor.tsx:175` |
| 6 | `app/sales/orders/[id]/page.tsx:145-293` | SO `deleted` | OrderLinesTable `app/sales/orders/[id]/OrderLinesTable.tsx:43` |
| 7 | `app/purchasing/orders/[id]/page.tsx:793-1196` | PO `deletedAt` | PoLinesTable `…/PoLinesTable.tsx:242`; PoPaymentTermsTable `…/PoPaymentTermsTable.tsx:144`; PoReceiptsTable `…/PoReceiptsTable.tsx:155` |
| 8 | `app/output/[id]/edit/page.tsx:348-583` | output batch deleted/reversed (:322 `!!batch.deleted_at`) | Direct exportSpec at page :540 (ContaminationChecksList call); RecoveryTable `app/output/[id]/edit/TraceabilityTables.tsx:144,281`; CoaTable `app/quality/coa/CoaTable.tsx:88`; OutputAssayRowsTable `…/OutputAssayRowsTable.tsx:119`; MetalContentPanel `app/components/metals/MetalContentPanel.tsx:258`; MovementTimelineTable `app/components/inventory/MovementTimelineTable.tsx:144`; ContaminationChecksList `app/operation/contamination/ContaminationChecksList.tsx:70`; ModuleCountPanel `app/components/batch/ModuleCountPanel.tsx:115` |
| 9 | `app/inbound/[id]/edit/page.tsx:711-1030` | inbound batch deleted (:635 `!!batch.deleted_at`) | PricingPanel `app/inbound/[id]/edit/PricingPanel.tsx:274`; InboundMarginTable `…/InboundMarginTable.tsx:38`; AssayRowsTable `…/AssayRowsTable.tsx:128`; PrepaymentPanel `…/PrepaymentPanel.tsx:194`; MetalContentPanel :258; MovementTimelineTable :144; ModuleCountPanel :115; RepriceFromContentPanel>AssayImpactPreview>PriceBreakdown `app/components/pricing/PriceBreakdown.tsx:220` |
| 10 | `app/hr/employees/[id]/page.tsx:455-500` | employee `deleted` (:56) | EmployeeReviewsTable / EmployeePayrollTable `app/hr/employees/[id]/EmployeeTables.tsx:94,155,245` |
| 11 | `app/settings/roles/[id]/page.tsx:77-99` | role `deleted` (:47) | PermissionMatrix `app/settings/roles/PermissionMatrix.tsx:331,341` |
| 12 | `app/tools/pricing/formulas/[id]/edit/page.tsx:139-163` (second fieldset; the first, 125-136, holds only buttons) | formula `deletedAt` | FormulaForm `app/tools/pricing/formulas/FormulaForm.tsx:483`; TermsRequestsPanel `app/components/pricing/TermsRequestsPanel.tsx:112` |
| — | `app/operation/processing/[id]/page.tsx:704-706` (run reversed or deleted, :200) | — | DeleteButton only, no export |
| — | `app/finance/bank/statements/[id]/page.tsx:402-404` | — | DeleteStatementButton only |
| — | `app/finance/fx/[id]/edit/page.tsx:68-73` (rate `withdrawnAt`) | — | EditFxRateForm only |
| — | `app/hr/training/[id]/edit/page.tsx:67-69`, `app/hr/departments/[id]/edit/page.tsx:66-71` | — | form only |
| — | `app/sales/customers/[id]/page.tsx:238-240` | — | one disabled edit Button |

**Totals:** 19 EndedFieldset blocks in 17 files. **12 of them wrap at least one export, about 38 export call sites in total** (file-level, before de-duplication across pages). The known-issue entry names only 3 pages and 4 panels.

Not wrapped today (all checked by `grep EndedFieldset`):
- voided invoices: `app/finance/invoices/[id]/page.tsx` has no EndedFieldset
- disposed assets
- closed periods
- cancelled POs (only *deleted* POs are wrapped)

So those do **not** grey their exports.

Registered at `docs/known-issues.md:11665-11671` and `docs/handbacks/TABLE-EXPORT-3c.md:99-100`. The fix directions already suggested there:
- move the export bar outside the fieldset, or
- have the fieldset exempt `data-slot="table-export"`. Spec trick: only a first `<legend>` is exempt, so in practice the bar has to move out, or `TableExportBar` has to be rendered outside, or `EndedFieldset` has to switch to per-control disabling.

### C2. Other disabled fieldsets that wrap exports
- `MetalContentPanel.tsx:243-309` `disabled={!!lockedReason}`: the DataTable with `exportSpec 'batch-metal-content'` (:258) is **inside**.
  - `lockedReason` is passed only by `app/inbound/[id]/edit/page.tsx:848` = `priceLockedReason`. That value is set while a receipt price request is open (:555-557).
  - So on an inbound batch with an open price request, the metal-content export is grey even on a live record.
- `PricingPanel.tsx:206-263`: the fieldset closes before the export at :274, so it is **not affected**.
- `TaskEditGate` (4 sites: `app/tools/tasks/[id]/page.tsx:268`, `TaskHeader.tsx:108`, `Participants.tsx:129`, `NodeTree.tsx:221`): no exports inside.

### C3. PermissionGate sites wrapping exports (greyed for a reader without the code)
- Method: `scratchpad/gates.py` scanned all **306** `<PermissionGate>`/`<TaskEditGate>` blocks across app/ with the same depth-3 walk, then each hit was checked by hand.
- Confirmed:
  1. `app/purchasing/payment-terms/TemplateForm.tsx:277-411`: gate `module.purchasing.edit` wraps the whole form, including the EditableTable whose `exportSpec` (`purchasing-payment-term-template-lines`) is at :354. Used by `app/purchasing/payment-terms/[id]/edit/page.tsx:77`, so a reader with view-only access gets a grey export.
  2. `app/hr/kpi/score/page.tsx:281-283`: gate `action.hr_reviews` wraps ScoreEditor, an EditableTable with `exportSpec 'hr-kpi-scores'` (`app/hr/kpi/score/ScoreEditor.tsx:250`).
  3. `app/sales/quotes/[id]/page.tsx:208-214`: gate `module.sales.edit` (only when `stateAllowsEdit`) wraps QuoteLinesEditor (`exportSpec` :175).
  4. `app/suppliers/[id]/edit/ReviewForm.tsx:58-109`: gate `action.supplier_review` wraps MeasuresTable (`app/suppliers/MeasuresTable.tsx:58`).
  5. `app/inbound/[id]/edit/page.tsx:901-903`: gate `pricingGate.code` wraps RepriceFromContentPanel → AssayImpactPreview → PriceBreakdown (`exportSpec` `app/components/pricing/PriceBreakdown.tsx:220`), and only when a preview is rendered.
- False positives removed:
  - `app/finance/invoices/[id]/page.tsx` (the gate at :350-353 wraps only the PDF button; the hit came from a comment).
  - `app/sales/customers/StatementPanel.tsx` (the gate at :203-216 closes before the export at :227).

---

## D. Calendar vs fiscal year
- A fiscal year is **configured**: `db/tables/finance_settings.sql:36-41`.
  - `fy_end_month int NOT NULL DEFAULT 12`, `fy_end_day int NOT NULL DEFAULT 31`, `first_fy_end date` (allows a long or short first year of up to 18 months).
  - Comments at :153-157 (FIN-23): "Singapore companies choose their FY; must not assume 12/31". The default 12/31 "is Tim's declared FYE" (:37).
  - Consumed by `db/functions/preview_close_financial_year.sql:6-7,37-42` and `db/functions/set_finance_settings.sql`.
- Period structures:
  - `finance_settings.locked_before date` = the period lock (:2, :25), with reopen guards at :80-89.
  - `db/tables/period_closes.sql:15-26` (monthly, `period_end` = month end).
  - `db/tables/year_closes.sql:11-22` (`year_end`).
  - `db/tables/gst_periods.sql:32-38`: GST quarters (`code 'GST-2025-Q1'`, `period_start/end`). GST quarters are their own filing calendar.
- **There is no accounting-periods table and no fiscal-quarter concept.** The existing date presets are **calendar** and computed in UTC:
  - `app/finance/pnl/page.tsx:73-79` (`thisMonth`, `lastMonth`, `thisYear = ${y}-01-01..${y}-12-31`, comment "UTC 口径")
  - `app/finance/cashflow/page.tsx:71,96-99` (keys identical to P&L)
  - No "this quarter" preset exists anywhere.
- Since FYE is 12/31 today, calendar year and FY coincide for now. A "this year" preset that stays correct if FYE changes should derive from `fy_end_month/day` (and `first_fy_end`) rather than hard-coding Jan–Dec. Note also that the home greeting uses Singapore time while these presets use UTC.
