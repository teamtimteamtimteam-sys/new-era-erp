# MANUAL-0 — Survey for the operations manual

**Cut** MANUAL-0 · **Date** 2026-09-07 · **HEAD at survey** `4fef88a` (BTN-6, on `origin/main`, tree clean)
**No version number, no release note** — this cut takes neither.

This is a **working document for the writing cut**, not prose for readers. Dense, sourced
and complete beats readable. It does not contain manual text and must not be read as a draft.

---

## 0 · Method, and what binds it

Tim's rulings from grilling round 1 (R1–R7) are closed and bind this survey. The two that
shape almost every number below:

* **R3** — the manual describes the system **after production cutover**, not live as it stands.
  So S2 and S3 derive from **code, mirrors and RPCs only**. Live is queried for exactly two
  things: the role/permission mappings (S5), and confirming a feature has ever actually run.
* **R5** — **re-derive** routes, permissions, refusals and state machines (a reader follows
  those as instructions). **Cite** existing docs for rationale and history.

`--reach` was **not run** (AGENTS.md:553 forbids it; 63 min/role). Everything below is static
or a `SELECT`.

### Where my own measurements were blind, and how I know

This survey's counts come from scripts I wrote this session. Three of them were **wrong on
the first pass**, and each was caught by making coverage itself an assertion (AGENTS.md:3133):

| Pass | Blind spot | How it surfaced | Corrected |
|---|---|---|---|
| Titles | Only read `page.tsx`; missed server shells that delegate to a sibling client component | 42 "unknown" titles, several on core pages | → 21, then all 21 explained (dynamic titles) |
| Permissions | Knew `requireModule`, not `requireEditPermission` / `requireManagePermissions` | 18 pages looked unguarded — including write pages | → 9, and those 9 are exactly the documented public/personal set |
| Refusals | Prefix regex matched `+ code`, not `+ match[1]` | 275 codes looked to have no English sentence | → 7, then 0 (see S4) |

**None of those three was a defect in the product.** Each was a defect in my measurement.
They are written down because a survey that reports its own blind spots as findings would
put phantom defects into the manual — the exact failure S6 exists to prevent.

---

## 3.5 · Counts, with method

| Thing | Count | Method |
|---|---:|---|
| Routes (pages a person can reach) | **199** | `find app -name page.tsx`; no route groups exist on this tree, so path → pattern is 1:1. Matches `lib/deepRoutes.generated.ts` header, which independently measured 199. |
| — static | 141 | of the 199, patterns with no `[…]` segment |
| — dynamic (patterns, per R4) | 58 | of the 199, patterns with a `[…]` segment |
| Navigation entries | **84** | `FUNCTIONS` in `lib/modules.ts` (83 single-line + 1 multi-line `/margin`, `lib/modules.ts:472`) |
| Routes in **no** navigation | **115** | 199 − 84; decomposed exactly in S1 |
| Access scopes (page guards) | **15** | `SCOPES` in `lib/modules.ts` |
| Capabilities | **39** | `SELECT count(*) FROM permissions` (live) |
| Roles defined | **12** | `SELECT count(*) FROM roles` (live) |
| Roles with ≥1 holder | **7** | `user_roles` joined to `roles` |
| Distinct people holding a role | **6** | `SELECT count(DISTINCT user_id) FROM user_roles` — **this is the "six"** |
| Role→capability grants | **211** | `SELECT count(*) FROM role_permissions` (live) |
| Document types (R6 rule) | **22** | S3; rule and near-misses published there |
| Distinct DB refusal codes | **852** | `RAISE EXCEPTION '<CODE>` across `db/functions`, `db/tables`, `db/views`, deduped |
| Distinct app-registered refusal codes | **744** | all 43 `tsSet(...)` sets registered in `scripts/check-i18n.mjs` |
| Refusals **with** an English sentence | **744** | S4 half one — two independent methods union to exactly this |
| Refusals **without** one | **0 app-side / 121 DB-side** | S4 half two — the split matters, see S4 |
| ErrorCodes files | **38** | `find app -name '*ErrorCodes.ts'` |
| English catalogue | 7,534 lines | `messages/en.ts` |

---

## S1 · Route inventory

### The decomposition — it is exact, not approximate

199 routes decompose with **no remainder**:

| Class | Count | What reaches it |
|---|---:|---|
| In the navigation registry | **84** | `ModuleBar` second-level menu |
| Documented exceptions | **8** | intentionally outside the nav — `scripts/check-nav-routes.mjs:106-118` names each with its reason |
| Covered by a nav entry's prefix | **106** | detail / `new` / `edit` / sub-pages under a registry `href` |
| Under the `/my-reviews` exception | **1** | `/my-reviews/[id]` |

84 + 8 + 106 + 1 = **199**. ✔

**Every one of the 84 registry entries resolves to a real `page.tsx`** — there are zero dead
nav links. That is enforced by `scripts/check-nav-routes.mjs` arm ①, which is green in
`npm run build`.

### The 8 exceptions (`scripts/check-nav-routes.mjs:106-118`)

`/` · `/login` · `/set-password` · `/welcome` · `/me` · `/my-reviews` · `/notifications` ·
`/brand-sampler`. (`/logout` is a ninth in that file but is a `route.ts`, not a page, so it
is not among the 199.)

These are also **the only 9 routes with no capability guard** (the 8 above plus
`/my-reviews/[id]`). Every other one of the 199 has one. That is a clean result, not a gap:

* **Only `/login` is truly public** — `PUBLIC_PATHS = ['/login']`, `lib/loginRoute.ts:34`.
  Everything else requires a session, enforced in `lib/supabase/middleware.ts:200`.
* `/set-password` requires a session but renders **no application chrome**
  (`BARE_CHROME_PATHS`, `lib/loginRoute.ts:57`) — deliberately, so a person who has not yet
  changed a handed-over password is not shown which modules the account lacks.
* `/welcome` is where a signed-in person **holding no module at all** lands.
* `/me`, `/my-reviews`, `/notifications` are "my own things", gated by ownership rather than
  by a capability.

### ★ The 20 pages with no menu entry that are not detail pages

This is S1's highest-value finding for the manual. Strip the `[id]`, `new` and `edit` pages
out of the 106 prefix-covered routes and **20 real features remain that no menu will ever
show you**. A reader who does not already know they exist cannot find them.

| Route | Reached from | Note |
|---|---|---|
| `/inbound/receive` | `app/inbound/page.tsx` | ★ **a core process step** — receiving against a PO. See S2. |
| `/finance/bank/import` | `app/finance/bank/page.tsx`, `.../statements/page.tsx` | |
| `/finance/bank/statements` | `app/finance/bank/page.tsx` | |
| `/finance/fx/bulk` | `app/finance/fx/page.tsx` | |
| `/hr/leave/balances` | `app/hr/leave/LeaveSubnav.tsx` | tab strip inside HR leave |
| `/hr/leave/calendar` | `app/hr/leave/LeaveSubnav.tsx` | |
| `/hr/leave/grants` | `app/hr/leave/LeaveSubnav.tsx` | |
| `/hr/leave/holidays` | `app/hr/leave/LeaveSubnav.tsx` | |
| `/hr/leave/types` | `app/hr/leave/LeaveSubnav.tsx` | |
| `/hr/reviews/cycles` | `app/hr/reviews/page.tsx` | |
| `/hr/reviews/scale` | `app/hr/reviews/page.tsx` | |
| `/inventory/reports/ledger` | `app/inventory/reports/page.tsx` | |
| `/inventory/reports/safety` | `app/inventory/reports/page.tsx` | |
| `/inventory/reports/snapshot` | `app/inventory/reports/page.tsx`, `app/sales/orders/[id]/ReservationSection.tsx` | |
| `/inventory/reports/violations` | `app/inventory/reports/page.tsx` | |
| `/sales/customers/overlap` | `app/sales/customers/page.tsx` | |
| `/tools/pricing/calculator` | `app/tools/pricing/page.tsx` | |
| `/tools/pricing/formulas` | `app/tools/pricing/page.tsx` | |
| `/tools/pricing/metal-prices` | `app/tools/pricing/page.tsx` | |
| `/tools/pricing/metal-prices/bulk` | `app/tools/pricing/metal-prices/page.tsx` | |

**`/hr/leave/*` has its own tab strip** (`LeaveSubnav.tsx`) — a second-level navigation that
lives inside the page, not in `ModuleBar`. The manual needs to say so, because the module
menu gives no hint that five more pages sit there.

### Titles

Resolved statically per R4. 178 of 199 resolve to a fixed English string via
`navKey` → `messages/en.ts` (registry entries) or the page's own `t('…')` key.

The remaining 21 are **not "unknown"** — they are **dynamic by design**: the heading is the
record's own code or name, rendered through `RecordHeader` / `ListPage`. Examples, each read
from the handler:

| Route | Heading expression | Source |
|---|---|---|
| `/sales/orders/[id]` | `{o.code}` | `app/sales/orders/[id]/page.tsx:105` |
| `/logistics/containers/[id]` | `{head.data.code}` | `app/logistics/containers/[id]/page.tsx` |
| `/logistics/forwarders/[id]` | `{sup.data.legal_name}` | `app/logistics/forwarders/[id]/page.tsx` |
| `/sales/customers/[id]` | `{cust.legal_name}` | `app/sales/customers/[id]/page.tsx` |
| `/hr/attendance/[id]` | `{period.code}` | `app/hr/attendance/[id]/page.tsx` |
| `/finance/credit-notes/[id]` | `RecordHeader title={<span className="font-mono">{cn.code}</span>}` | `app/finance/credit-notes/[id]/page.tsx:125` |
| `/hr/reviews/[id]` | `{subject ? subject.legal_name : t('reviews.detailTitle')}` | `app/hr/reviews/[id]/page.tsx` |

Two genuine exceptions: **`/`** (the home dashboard, no `<h1>`) and **`/brand-sampler`**
(heading is Chinese — it is a development page, see S6).

### Full table

Columns: route · English title · title source · nav group / owner module · in nav · gating
capability · where that gate was read.


| Route | English title | Title from | Group / owner | In nav | Capability | Gate read at |
|---|---|---|---|---|---|---|
| `/` | _(dynamic — record code/name)_ | — | — | no | _(none — public/personal)_ | unknown |
| `/brand-sampler` | _(dynamic — record code/name)_ | — | — | no | _(none — public/personal)_ | unknown |
| `/contracts` | Contracts | navKey | purchasing | yes | `module.suppliers.view` | registry |
| `/finance` | Overview | navKey | finance | yes | `module.finance.view` | registry |
| `/finance/assets` | Fixed assets | navKey | finance/finance.group.payables | yes | `module.finance.view` | registry |
| `/finance/assets/[id]` | Stop monitoring this kind of work? | sibling ServiceIntervalPanel.tsx | — | no | `module.finance.view` | requireModule(MOD.finance) |
| `/finance/assets/new` | Register a machine | page t() | — | no | `module.finance.view` | requireModule(MOD.finance) |
| `/finance/balance-sheet` | Balance Sheet | navKey | finance/finance.group.reports | yes | `module.finance.view` | registry |
| `/finance/bank` | Bank | navKey | finance/finance.group.periodEnd | yes | `module.finance.view` | registry |
| `/finance/bank/import` | Import Bank Statement | page t() | — | no | `module.finance.view` | requireModule(MOD.finance) |
| `/finance/bank/statements` | Bank Statements | page t() | — | no | `module.finance.view` | requireModule(MOD.finance) |
| `/finance/bank/statements/[id]` | Bank Statement | page t() | — | no | `module.finance.view` | requireModule(MOD.finance) |
| `/finance/bank/statements/[id]/reconcile` | Bank Reconciliation | page t() | — | no | `module.finance.view` | requireModule(MOD.finance) |
| `/finance/cash-forecast` | Cash forecast | navKey | finance/finance.group.reports | yes | `module.finance.view` | registry |
| `/finance/cashflow` | Cash flow | navKey | finance/finance.group.reports | yes | `module.finance.view` | registry |
| `/finance/claims` | Expense claims | navKey | finance/finance.group.payables | yes | `module.finance.view` | registry |
| `/finance/close` | Close | navKey | finance/finance.group.periodEnd | yes | `module.finance.view` | registry |
| `/finance/company` | Company | navKey | finance/finance.group.config | yes | `module.finance.view` | registry |
| `/finance/cost-variance` | Cost variance | navKey | finance/finance.group.periodEnd | yes | `module.finance.view` | registry |
| `/finance/credit-notes` | Credit notes | navKey | finance/finance.group.receivables | yes | `module.finance.view` | registry |
| `/finance/credit-notes/[id]` | _(dynamic — record code/name)_ | — | — | no | `module.finance.view` | requireModule(MOD.finance) |
| `/finance/expenses` | Expenses | navKey | finance/finance.group.payables | yes | `module.finance.view` | registry |
| `/finance/expenses/[id]` | Expense | page t() | — | no | `module.finance.view` | requireModule(MOD.finance) |
| `/finance/expenses/new` | + New Expense | page t() | — | no | `module.finance.view` | requireModule(MOD.finance) |
| `/finance/freight` | Freight | navKey | logistics+finance/finance.group.payables | yes | `module.finance.view` | registry |
| `/finance/freight/[id]` | Reverse this freight document? | sibling ReverseFreightControl.tsx | — | no | `module.finance.view` | requireModule(MOD.finance) |
| `/finance/freight/new` | Record a freight invoice | sibling NewFreightForm.tsx | — | no | `module.finance.edit` | requireEditPermission |
| `/finance/fx` | FX Rates | navKey | finance/finance.group.config | yes | `module.finance.view` | registry |
| `/finance/fx/[id]/edit` | Edit FX Rate | page t() | — | no | `module.finance.view` | requireModule(MOD.finance) |
| `/finance/fx/bulk` | Enter a week of rates | page t() | — | no | `module.finance.view` | requireModule(MOD.finance) |
| `/finance/fx/new` | Add FX Rate | page t() | — | no | `module.finance.view` | requireModule(MOD.finance) |
| `/finance/gst` | GST | navKey | finance/finance.group.periodEnd | yes | `module.finance.view` | registry |
| `/finance/gst/[periodId]` | _(dynamic — record code/name)_ | — | — | no | `module.finance.view` | requireModule(MOD.finance) |
| `/finance/invoices` | Invoices | navKey | finance/finance.group.receivables | yes | `module.finance.view` | registry |
| `/finance/invoices/[id]` | Reversal date — decides which period the reversal posts into; never defaulted. | sibling VoidInvoiceControl.tsx | — | no | `module.finance.view` | requireModule(MOD.finance) |
| `/finance/invoices/new` | New Invoice | page t() | — | no | `module.finance.view` | requireModule(MOD.finance) |
| `/finance/journal` | Journal | navKey | finance/finance.group.entries | yes | `module.finance.view` | registry |
| `/finance/journal/[id]` | Journal Entry | page t() | — | no | `module.finance.view` | requireModule(MOD.finance) |
| `/finance/journal/new` | New Entry | navKey | finance/finance.group.entries | yes | `module.finance.view` | registry |
| `/finance/ledger/[account]` | _(dynamic — record code/name)_ | — | — | no | `module.finance.view` | requireModule(MOD.finance) |
| `/finance/month-end` | Month-end | navKey | finance/finance.group.periodEnd | yes | `module.finance.view` | registry |
| `/finance/packs` | Monthly pack | navKey | finance/finance.group.periodEnd | yes | `module.finance.view` | registry |
| `/finance/packs/[id]` | _(dynamic — record code/name)_ | — | — | no | `module.finance.view` | requireModule(MOD.finance) |
| `/finance/payables` | Payables | navKey | finance/finance.group.payables | yes | `module.finance.view` | registry |
| `/finance/payables/[batchId]` | Payable Document | page t() | — | no | `module.finance.view` | requireModule(MOD.finance) |
| `/finance/payments` | Payments | navKey | finance/finance.group.payables | yes | `module.finance.view` | registry |
| `/finance/payments/[id]` | Payments | page t() | — | no | `module.finance.view` | requireModule(MOD.finance) |
| `/finance/payments/new` | Record Payment | page t() | — | no | `module.finance.view` | requireModule(MOD.finance) |
| `/finance/payroll-payments` | Salary payments | navKey | finance/finance.group.periodEnd | yes | `module.finance.view` | registry |
| `/finance/pnl` | P&L | navKey | finance/finance.group.reports | yes | `module.finance.view` | registry |
| `/finance/price-exposure` | Price exposure | navKey | finance/finance.group.reports | yes | `module.finance.view` | registry |
| `/finance/processing-costs` | Cost settlement | navKey | finance/finance.group.periodEnd | yes | `module.finance.view` | registry |
| `/finance/receivables` | Receivables | navKey | finance/finance.group.receivables | yes | `module.finance.view` | registry |
| `/finance/receivables/[saleId]` | Receivable Document | page t() | — | no | `module.finance.view` | requireModule(MOD.finance) |
| `/finance/revaluation` | Revaluation | navKey | finance/finance.group.periodEnd | yes | `module.finance.view` | registry |
| `/finance/settings` | Settings | navKey | finance/finance.group.config | yes | `module.finance.view` | registry |
| `/finance/trial-balance` | Trial Balance | navKey | finance/finance.group.reports | yes | `module.finance.view` | registry |
| `/finance/wht` | Withholding tax | navKey | finance/finance.group.periodEnd | yes | `module.finance.view` | registry |
| `/hr` | Overview | navKey | hr | yes | `module.hr.view` | registry |
| `/hr/attendance` | Attendance | navKey | hr | yes | `module.hr.view` | registry |
| `/hr/attendance/[id]` | _(dynamic — record code/name)_ | — | — | no | `module.hr.view` | requireModule(MOD.hr) |
| `/hr/claims` | Claims | navKey | hr | yes | `module.hr.view` | registry |
| `/hr/claims/[id]` | HR | page t() | — | no | `module.hr.view` | requireModule(MOD.hr) |
| `/hr/claims/new` | HR | page t() | — | no | `module.hr.view` | requireModule(MOD.hr) |
| `/hr/departments` | Departments | navKey | hr | yes | `module.hr.view` | registry |
| `/hr/departments/[id]/edit` | Departments | page t() | — | no | `module.hr.view` | requireModule(MOD.hr) |
| `/hr/departments/new` | + New Department | page t() | — | no | `module.hr.view` | requireModule(MOD.hr) |
| `/hr/employees` | Employees | navKey | hr | yes | `module.hr.view` | registry |
| `/hr/employees/[id]` | _(dynamic — record code/name)_ | — | — | no | `module.hr.view` | requireModule(MOD.hr) |
| `/hr/employees/[id]/edit` | Employee | page t() | — | no | `module.hr.view` | requireModule(MOD.hr) |
| `/hr/employees/new` | + New Employee | page t() | — | no | `module.hr.view` | requireModule(MOD.hr) |
| `/hr/kpi` | KPI | navKey | hr | yes | `module.hr.view` | registry |
| `/hr/kpi/score` | KPI scoring | navKey | hr | yes | `module.hr.edit` | registry |
| `/hr/leave` | Leave | navKey | hr | yes | `module.hr.view` | registry |
| `/hr/leave/[id]` | HR | page t() | — | no | `module.hr.view` | requireModule(MOD.hr) |
| `/hr/leave/balances` | HR | page t() | — | no | `module.hr.view` | requireModule(MOD.hr) |
| `/hr/leave/calendar` | HR | page t() | — | no | `module.hr.view` | requireModule(MOD.hr) |
| `/hr/leave/grants` | HR | page t() | — | no | `module.hr.view` | requireModule(MOD.hr) |
| `/hr/leave/holidays` | HR | page t() | — | no | `module.hr.view` | requireModule(MOD.hr) |
| `/hr/leave/new` | HR | page t() | — | no | `module.hr.view` | requireModule(MOD.hr) |
| `/hr/leave/types` | HR | page t() | — | no | `module.hr.view` | requireModule(MOD.hr) |
| `/hr/org` | Organisation chart | navKey | hr | yes | `module.hr.view` | registry |
| `/hr/payroll` | Payroll | navKey | hr | yes | `module.hr.view` | registry |
| `/hr/payroll/[id]` | Post this payroll to the ledger? These accounts will move: | sibling PostControls.tsx | — | no | `module.hr.view` | requireModule(MOD.hr) |
| `/hr/payroll/[id]/edit` | Payroll Period | page t() | — | no | `module.hr.view` | requireModule(MOD.hr) |
| `/hr/payroll/new` | + New Payroll Period | page t() | — | no | `module.hr.view` | requireModule(MOD.hr) |
| `/hr/reviews` | Reviews | navKey | hr | yes | `module.hr.view` | registry |
| `/hr/reviews/[id]` | _(dynamic — record code/name)_ | — | — | no | `module.hr.view` | requireModule(MOD.hr) |
| `/hr/reviews/cycles` | HR | page t() | — | no | `module.hr.view` | requireModule(MOD.hr) |
| `/hr/reviews/scale` | HR | page t() | — | no | `module.hr.view` | requireModule(MOD.hr) |
| `/hr/training` | Training | navKey | hr | yes | `module.hr.view` | registry |
| `/hr/training/[id]/edit` | Training Records | page t() | — | no | `module.hr.view` | requireModule(MOD.hr) |
| `/hr/training/new` | + Record Training | page t() | — | no | `module.hr.view` | requireModule(MOD.hr) |
| `/inbound` | Inbound | navKey | purchasing+inventory+operation | yes | `module.inbound.view` | registry |
| `/inbound/[id]/assays/[assayId]` | Assay Result | page t() | — | no | `module.inbound.view` | requireModule(MOD.inbound) |
| `/inbound/[id]/assays/new` | Record Assay Result | page t() | — | no | `module.inbound.view` | requireModule(MOD.inbound) |
| `/inbound/[id]/edit` | Edit Inbound | page t() | — | no | `module.inbound.view` | requireModule(MOD.inbound) |
| `/inbound/new` | Add Inbound | page t() | — | no | `module.inbound.view` | requireModule(MOD.inbound) |
| `/inbound/receive` | Field Receiving | page t() | — | no | `module.inbound.view` | requireModule(MOD.inbound) |
| `/inbound/receive/done/[id]` | Received | page t() | — | no | `module.inbound.view` | requireModule(MOD.inbound) |
| `/inventory` | Overview | navKey | inventory | yes | `module.inventory.view` | registry |
| `/inventory/inbound/[materialId]` | _(dynamic — record code/name)_ | — | — | no | `module.inventory.view` | requireModule(MOD.inventory) |
| `/inventory/locations` | Storage locations | navKey | inventory | yes | `module.inventory.view` | registry |
| `/inventory/locations/[id]/edit` | Edit Storage Location | page t() | — | no | `module.inventory.view` | requireModule(MOD.inventory) |
| `/inventory/locations/new` | New Storage Location | page t() | — | no | `module.inventory.view` | requireModule(MOD.inventory) |
| `/inventory/output/[materialId]` | _(dynamic — record code/name)_ | — | — | no | `module.inventory.view` | requireModule(MOD.inventory) |
| `/inventory/reports` | Reports | navKey | inventory | yes | `module.inventory.view` | registry |
| `/inventory/reports/ledger` | Movement ledger | page t() | — | no | `module.inventory.view` | requireModule(MOD.inventory) |
| `/inventory/reports/safety` | Safety stock | page t() | — | no | `module.inventory.view` | requireModule(MOD.inventory) |
| `/inventory/reports/snapshot` | Stock snapshot | page t() | — | no | `module.inventory.view` | requireModule(MOD.inventory) |
| `/inventory/reports/violations` | Class violations | page t() | — | no | `module.inventory.view` | requireModule(MOD.inventory) |
| `/login` | Your session has ended | page t() | — | no | _(none — public/personal)_ | unknown |
| `/logistics` | Overview | navKey | logistics | yes | `module.logistics.view` | registry |
| `/logistics/containers` | Containers | navKey | logistics | yes | `module.logistics.view` | registry |
| `/logistics/containers/[id]` | _(dynamic — record code/name)_ | — | — | no | `module.logistics.view` | requireModule(MOD.logistics) |
| `/logistics/forwarders` | Forwarders | navKey | logistics | yes | `module.logistics.view` | registry |
| `/logistics/forwarders/[id]` | _(dynamic — record code/name)_ | — | — | no | `module.logistics.view` | requireModule(MOD.logistics) |
| `/logistics/lanes` | Lanes and document checklists | navKey | logistics | yes | `module.logistics.view` | registry |
| `/margin` | Batch Gross Margin | navKey | finance | yes | `{ all: [data.view_prices], any: [P_FINANCE, P_PROCESSING]` | registry |
| `/materials` | Materials | navKey | inventory | yes | `module.materials.view` | registry |
| `/materials/[id]/edit` | Edit Material | page t() | — | no | `module.materials.view` | requireModule(MOD.materials) |
| `/materials/new` | Add Material | sibling NewMaterialForm.tsx | — | no | `module.materials.view` | requireModule(MOD.materials) |
| `/me` | My profile | page t() | — | no | _(none — public/personal)_ | unknown |
| `/my-reviews` | Reviews I conduct | page t() | — | no | _(none — public/personal)_ | unknown |
| `/my-reviews/[id]` | _(dynamic — record code/name)_ | — | — | no | _(none — public/personal)_ | unknown |
| `/notifications` | Notifications | page t() | — | no | _(none — public/personal)_ | unknown |
| `/operation` | Overview | navKey | operation | yes | `module.processing.view` | registry |
| `/operation/handovers` | Shift handover | navKey | operation | yes | `module.processing.view` | registry |
| `/operation/handovers/new` | New shift handover | sibling NewHandoverForm.tsx | — | no | `module.processing.view` | requireModule(MOD.processing) |
| `/operation/orders` | Work orders | navKey | operation | yes | `module.processing.view` | registry |
| `/operation/orders/[id]` | _(dynamic — record code/name)_ | — | — | no | `module.processing.view` | requireModule(MOD.processing) |
| `/operation/orders/new` | New work order | sibling NewWorkOrderForm.tsx | — | no | `module.processing.view` | requireModule(MOD.processing) |
| `/operation/processing` | Processing runs | navKey | operation | yes | `module.processing.view` | registry |
| `/operation/processing/[id]` | Processing Run Detail | page t() | — | no | `module.processing.view` | requireModule(MOD.processing) |
| `/operation/processing/new` | Add Processing Run | page t() | — | no | `module.processing.view` | requireModule(MOD.processing) |
| `/operation/wip` | Work in progress | navKey | operation | yes | `module.processing.view` | registry |
| `/output` | Output | navKey | operation+inventory | yes | `module.output.view` | registry |
| `/output/[id]/assays/[assayId]` | Assay Result | page t() | — | no | `module.output.view` | requireModule(MOD.output) |
| `/output/[id]/assays/new` | Record Assay Result | page t() | — | no | `module.output.view` | requireModule(MOD.output) |
| `/output/[id]/edit` | Edit Output | page t() | — | no | `module.output.view` | requireModule(MOD.output) |
| `/output/new` | Add Output | page t() | — | no | `module.output.view` | requireModule(MOD.output) |
| `/purchasing` | Overview | navKey | purchasing | yes | `module.purchasing.view` | registry |
| `/purchasing/discrepancies` | Receiving discrepancies | navKey | purchasing | yes | `module.purchasing.view` | registry |
| `/purchasing/licences` | Licences | navKey | purchasing | yes | `module.suppliers.view` | registry |
| `/purchasing/orders` | Purchase orders | navKey | purchasing | yes | `module.purchasing.view` | registry |
| `/purchasing/orders/[id]` | Approve this purchase order? | sibling ApprovalControls.tsx | — | no | `module.purchasing.view` | requireModule(MOD.purchasing) |
| `/purchasing/orders/[id]/amend` | _(dynamic — record code/name)_ | — | — | no | `module.purchasing.edit` | requireEditPermission |
| `/purchasing/orders/new` | + New Purchase Order | page t() | — | no | `module.purchasing.view` | requireModule(MOD.purchasing) |
| `/purchasing/payment-terms` | Payment terms | navKey | purchasing | yes | `module.purchasing.view` | registry |
| `/purchasing/payment-terms/[id]/edit` | Payment Term Templates | page t() | — | no | `module.purchasing.view` | requireModule(MOD.purchasing) |
| `/purchasing/payment-terms/new` | + New Template | page t() | — | no | `module.purchasing.view` | requireModule(MOD.purchasing) |
| `/sales` | Overview | navKey | sales | yes | `module.sales.view` | registry |
| `/sales/commissions` | Commissions | navKey | purchasing+sales | yes | `module.suppliers.view` | registry |
| `/sales/commissions/[id]/edit` | Edit commission agreement | page t() | — | no | `module.suppliers.view` | requireModule(MOD.suppliers) |
| `/sales/commissions/new` | New commission agreement | page t() | — | no | `module.suppliers.view` | requireModule(MOD.suppliers) |
| `/sales/customers` | Customers | navKey | sales | yes | `module.customers.view` | registry |
| `/sales/customers/[id]` | _(dynamic — record code/name)_ | — | — | no | `module.customers.view` | requireModule(MOD.customers) |
| `/sales/customers/[id]/edit` | Edit Customer | page t() | — | no | `module.customers.view` | requireModule(MOD.customers) |
| `/sales/customers/new` | Add Customer | sibling NewCustomerForm.tsx | — | no | `module.customers.view` | requireModule(MOD.customers) |
| `/sales/customers/overlap` | Counterparty overlap | page t() | — | no | `module.customers.view` | requireModule(MOD.customers) |
| `/sales/orders` | Orders | navKey | sales | yes | `module.sales.view` | registry |
| `/sales/orders/[id]` | _(dynamic — record code/name)_ | — | — | no | `module.sales.view` | requireModule(MOD.sales) |
| `/sales/orders/[id]/amend` | _(dynamic — record code/name)_ | — | — | no | `module.sales.edit` | requireEditPermission |
| `/sales/orders/new` | New sales order | sibling NewOrderForm.tsx | — | no | `module.sales.view` | requireModule(MOD.sales) |
| `/sales/quotes` | Quotations | navKey | sales | yes | `module.sales.view` | registry |
| `/sales/quotes/[id]` | _(dynamic — record code/name)_ | — | — | no | `module.sales.view` | requireModule(MOD.sales) |
| `/sales/quotes/new` | New quotation | sibling NewQuoteForm.tsx | — | no | `module.sales.edit` | requireEditPermission |
| `/sales/shipments/[id]` | _(dynamic — record code/name)_ | — | — | no | `module.sales.view` | requireModule(MOD.sales) |
| `/set-password` | Set your password | page t() | — | no | _(none — public/personal)_ | unknown |
| `/settings/accounts` | Accounts | navKey | settings | yes | `action.manage_permissions` | registry |
| `/settings/approvals` | Approvals | navKey | settings | yes | `action.manage_permissions` | registry |
| `/settings/deleted` | Deleted records | navKey | settings | yes | `data.view_deleted` | registry |
| `/settings/dictionaries` | Dictionaries | navKey | settings | yes | `{ all: [], any: [module.materials.view, module.inbound.view] }` | registry |
| `/settings/import` | Bulk import | navKey | settings | yes | `action.bulk_import` | registry |
| `/settings/reference` | Permission reference | navKey | settings | yes | `action.manage_permissions` | registry |
| `/settings/roles` | Roles | navKey | settings | yes | `action.manage_permissions` | registry |
| `/settings/roles/[id]` | Permissions | page t() | — | no | `action.manage_permissions` | requireManagePermissions |
| `/settings/roles/new` | Permissions | page t() | — | no | `action.manage_permissions` | requireManagePermissions |
| `/stocktakes` | Stocktakes | navKey | inventory | yes | `module.stocktakes.view` | registry |
| `/stocktakes/[id]` | Stocktake | page t() | — | no | `module.stocktakes.view` | requireModule(MOD.stocktakes) |
| `/stocktakes/[id]/review` | Review Differences | page t() | — | no | `module.stocktakes.view` | requireModule(MOD.stocktakes) |
| `/suppliers` | Suppliers | navKey | purchasing | yes | `module.suppliers.view` | registry |
| `/suppliers/[id]/edit` | Edit Supplier | page t() | — | no | `module.suppliers.view` | requireModule(MOD.suppliers) |
| `/suppliers/new` | Add Supplier | page t() | — | no | `module.suppliers.view` | requireModule(MOD.suppliers) |
| `/tools/calendar` | Calendar | navKey | tools | yes | `{ all: []` | registry |
| `/tools/converter` | Unit converter | navKey | tools | yes | `{ all: []` | registry |
| `/tools/pricing` | Pricing | navKey | tools | yes | `module.pricing.view` | registry |
| `/tools/pricing/calculator` | Price Calculator | page t() | — | no | `module.pricing.view` | requireModule(MOD.pricing) |
| `/tools/pricing/formulas` | Pricing Formulas | page t() | — | no | `module.pricing.view` | requireModule(MOD.pricing) |
| `/tools/pricing/formulas/[id]/edit` | Pricing Formulas | page t() | — | no | `module.pricing.view` | requireModule(MOD.pricing) |
| `/tools/pricing/formulas/new` | + New Formula | page t() | — | no | `module.pricing.view` | requireModule(MOD.pricing) |
| `/tools/pricing/metal-prices` | Metal Prices | page t() | — | no | `module.pricing.view` | requireModule(MOD.pricing) |
| `/tools/pricing/metal-prices/[id]/edit` | Edit Metal Price | page t() | — | no | `module.pricing.edit` | requireEditPermission |
| `/tools/pricing/metal-prices/bulk` | Daily Metal Prices | page t() | — | no | `module.pricing.edit` | requireEditPermission |
| `/tools/pricing/metal-prices/new` | Add Metal Price | sibling NewMetalPriceForm.tsx | — | no | `module.pricing.edit` | requireEditPermission |
| `/tools/reminders` | Reminders | navKey | tools | yes | `{ all: []` | registry |
| `/tools/tasks` | Tasks | navKey | tools | yes | `module.tasks.view` | registry |
| `/tools/tasks/[id]` | Title | page t() | — | no | `module.tasks.view` | requireModule(MOD.tasks) |
| `/welcome` | Your account is ready | page t() | — | no | _(none — public/personal)_ | unknown |

---

## S2 · Business processes, end to end

Derived from code, mirrors and RPCs only (R3). Live was **not** used to infer any step.

Each step gives: the page, the document it creates, what it does to inventory or the ledger,
and **what the next step requires from it** — that last column is what fills the process
line's "what happens if the previous step is incomplete" slot.

### P1 · Receiving a load through to stock

| # | Step | Page | Document / effect | Next step requires |
|---|---|---|---|---|
| 1 | Raise the purchase order | `/purchasing/orders/new` | `purchase_orders` via `create_purchase_order` | PO must exist and not be `cancelled`/`closed` |
| 2 | Receive against the PO | ★ `/inbound/receive` (**no menu entry**) | `inbound_batches` via `receive_inbound_batch_against_po`; writes an `inventory_movements` receipt row | needs `module.inbound.edit`; **arrival date is mandatory** (`ARRIVAL_DATE_REQUIRED`) |
| 2a | Or receive with no PO | `/inbound/new` | `inbound_batches` via `create_inbound_batch` | a stated source reason (`guard_receipt_source_stated`) |
| 3 | Apply the assay | `/inbound/[id]/assays/new` | `assay_results`; `apply_assay_result` updates the batch | settlement needs committed pricing terms, else `PRICING_TERMS_NOT_COMMITTED` |
| 4 | Price the batch | `/inbound/[id]/edit` | `reprice_inbound_batch` / `set_inbound_unit_price` | `pricing_status` moves `unpriced → provisional → final` |

**The load is stock the moment step 2 succeeds** — the receipt row is written by the same RPC
that creates the batch. Assay and pricing change its *value*, not its existence.

★ **The page that does step 2 is not in any menu.** It is reached only from
`app/inbound/page.tsx`. For the manual's most common process, that is the single most
important navigation fact in this survey.

### P2 · Purchase from order to payment

| # | Step | Page | Document / effect | Next step requires |
|---|---|---|---|---|
| 1 | Create | `/purchasing/orders/new` | `create_purchase_order` — refuses `ORDER_DATE_REQUIRED`, `SUPPLIER_NOT_FOUND`, `CURRENCY_INVALID`, `FX_RATE_NOT_ACCEPTED`, `NO_LINES` | at least one line |
| 2 | *(optional)* Approve | `/purchasing/orders/[id]` | `approve_purchase_order` sets `approval_status='approved'`, and `status draft → confirmed` | **only runs if approvals are switched on** — else `APPROVALS_NOT_ENABLED` (see S6) |
| 3 | Receive | `/inbound/receive` | as P1 | — |
| 4 | Record the expense | `/finance/expenses/new` | `record_expense`; posts to the ledger | — |
| 5 | Pay | `/finance/payments/new` | `payments`; `status posted` | — |
| 6 | Close | `/purchasing/orders/[id]` | `close_purchase_order` | refuses if `PO_CANCELLED` / `PO_ALREADY_CLOSED`; requires `CLOSE_NOTES_REQUIRED` |

**Cancelling is narrow, and that is deliberate**: `cancel_purchase_order` refuses with
`PO_HAS_RECEIPTS` once anything has been received, and `PO_HAS_APPLIED_PREPAYMENTS` once a
prepayment has been applied. A reason is mandatory (`PO_CANCEL_REASON_REQUIRED`).

### P3 · Processing a batch through to output

`commit_processing_run` (`db/functions/commit_processing_run.sql`) is the one door. It needs
`module.processing.edit` and refuses, in order: `PROCESS_DATE_REQUIRED`,
`ALLOCATION_BASIS_REQUIRED`, `OPERATION_TYPE_REQUIRED`, `OPERATION_TYPE_UNKNOWN`,
`INVALID_BASIS`, `WO_NOT_FOUND`, `WO_NOT_RELEASED`, `EQUIPMENT_NOT_FOUND`,
`EQUIPMENT_NOT_ACQUIRED`, `EQUIPMENT_DISPOSED`, `NO_INPUTS`, `NO_OUTPUTS`,
`OPERATION_PRODUCES_NO_OUTPUTS`.

Two facts the manual must carry:

* **A work order must be `released`, not `draft`** — `WO_NOT_RELEASED`. Releasing happens on
  `/operation/orders/[id]` via `release_work_order`, which itself refuses `WO_NOT_DRAFT`.
* **Costs are a separate, later step.** `commit_processing_run` produces output batches;
  `allocate_processing_costs` is what puts cost onto them. A run can sit committed and
  unallocated indefinitely — and **month-end close refuses while any run is in that state**
  (`PROCESSING_COSTS_UNALLOCATED`, see P6).

### P4 · Sale from quote to shipment to invoice to cash

The sales order state machine is **explicitly enumerated** in one place —
`db/functions/set_sales_order_status.sql:31-39`:

```
draft             → confirmed | cancelled
confirmed         → cancelled
partially_shipped → (nothing)   -- corrections go via credit note
shipped           → closed
closed            → (final)
cancelled         → (final)
```

| # | Step | Page | Document / effect | Next step requires |
|---|---|---|---|---|
| 1 | Quote | `/sales/quotes/new` | `quotes`, `status draft → issued` | `convert_quote` refuses unless `issued`: `QT_NOT_ISSUED`, `QT_ALREADY_CONVERTED`, `QT_DECLINED`, `QT_EXPIRED`, `QT_NO_LINES` |
| 2 | Convert to order | `/sales/quotes/[id]` | `sales_orders` (`draft`) + `converted_order_id` back-link; quote becomes `converted` and **is frozen** | confirm before shipping |
| 3 | Confirm | `/sales/orders/[id]` | `set_sales_order_status` → `confirmed`; refuses `SO_CUSTOMER_ON_HOLD`, `SO_NO_LINES` | stock must be reserved |
| 4 | Invoice | `/finance/invoices/new` | `invoices` `status issued`; **posts to the ledger** | `ship_order` refuses `SO_SHIP_NOT_INVOICED` unless an `issued` invoice exists |
| 5 | Ship | `/sales/orders/[id]` | `shipments`; moves stock out; order → `partially_shipped` or `shipped` | refuses `SO_SHIP_ORDER_NOT_SHIPPABLE` unless status is `confirmed`/`partially_shipped`; also `SO_SHIP_NOT_RESERVED`, `SO_SHIP_EXCEEDS_RESERVATION`, `SHIP_DATE_REQUIRED` |
| 6 | Cash | `/finance/receivables/[saleId]` | receipt settles the invoice | — |

★ **Invoice before shipment, not after — and per line.** `ship_order` looks up, for **each
order line being shipped**, an `invoice_lines` row joined to an invoice with
`kind='order' AND status='issued' AND NOT il.invoice_voided`, and refuses
`SO_SHIP_NOT_INVOICED|<order>|<line_no>` if there is none
(`db/functions/ship_order.sql:97-105`). **This is the opposite of the order named in the
brief** ("quote to shipment to invoice to cash"). Per the brief's own instruction, the code
wins and the difference is a finding. Note the granularity: invoicing *part* of an order
lets you ship only that part.

★ **Once shipped, there is no way back.** `partially_shipped` transitions to nothing;
`void_invoice` refuses `INVOICE_SHIPPED_NOT_VOIDABLE` and `INVOICE_HAS_SETTLEMENTS`. The only
correction is a **credit note**, which is itself immutable once issued
(`CREDIT_NOTE_IMMUTABLE`). The manual's "how to undo a mistake" slot for this process is
"you do not undo it — you issue a credit note".

### P5 · Stocktake

`/stocktakes/[id]/review` → `post_stocktake` writes the adjusting `inventory_movements` rows
and sets `status open → posted`. `cancel_stocktake` sets `cancelled`. Both are final;
`posted` has no transition out.

### P6 · Month-end close

`close_period` (`db/functions/close_period.sql`) needs `module.finance.edit` and refuses in
this order — **this list is the whole of "what must be finished before close"**:

| Refusal | Meaning |
|---|---|
| `NOT_MONTH_END` | the date given is not a month end |
| `ALREADY_CLOSED` | that period is already closed |
| `DEPRECIATION_OUTSTANDING` | depreciation has not been run for the period |
| `PROCESSING_COSTS_UNALLOCATED` | a committed processing run still has no cost allocation (P3) |
| `TRIAL_BALANCE_UNBALANCED` | the trial balance does not balance |

On success it inserts `period_closes`. `close_financial_year` is a separate, later door with
its own preview (`preview_close_financial_year`).


---

## S3 · Document state machines

### The rule that defines "document" (R6), published so Tim can overrule it

A **document** is a record with all three of:

1. a human-facing code prefix (`PO-`, `SO-`, `INV-`, `CN-`, `QT-`, `SHP-`, `WO-`, `IN-`,
   `OUT-`, `PROC-`, `JE-`, `PMT-`, `EXP-`, `FA-`, `ST-`, `LV-`, `CLM-`, `MC-`, …);
2. a status a **person** changes;
3. a page of its own.

That yields **22 document types**, below.

**Near-misses, reported separately so the boundary is a decision and not a discovery:**

| Record | Why it misses | Comment |
|---|---|---|
| `customers` | has `code` + `status`, but the status is **free text with no state machine** | `db/tables/customers.sql:4` says so in as many words: *"status 自由文本…无状态机"* |
| `materials` | same shape: `status text NOT NULL DEFAULT 'draft'` with **no CHECK** | master data, not a document |
| `contracts` | has a real machine (`draft/active/suspended/expired/terminated`) and a page — **but no RPC writes its status**; nothing in `db/functions` updates `contracts.status` | **Open question — see Q9.** It may be a document whose transitions are unimplemented. |
| `employees` | `employment_status` is an HR attribute, not a document lifecycle | |
| `bank_reconciliation_status`, `attendance_period_status` | status-shaped **views/derived rows**, nobody transitions them | |
| `tasks` | `todo/in_progress/done` and a page, but no code prefix on screen | **borderline** — included below anyway, since a reader will look for it |

### The 22 documents

**★ Transitions are read from where they are enforced — the RPC — not from the CHECK
constraint.** The CHECK lists *legal values*; the RPC decides *legal moves*. Where they
disagree, **the RPC wins at runtime**, and the disagreement is recorded.

| Document | States (CHECK) | Enforced transitions | Final | Delete means |
|---|---|---|---|---|
| Purchase order `PO-` | `draft, confirmed, receiving, closed, cancelled` | `approve_purchase_order` (draft→confirmed), `close_purchase_order`, `reopen_purchase_order` (closed→prior), `cancel_purchase_order`, `amend_purchase_order` (refuses when closed/cancelled) | `cancelled` | soft (`deleted_at`) |
| — its `approval_status` | `pending, approved, rejected` | `approve_purchase_order` / `reject_purchase_order`, both refuse unless `pending` | `approved`, `rejected` | — |
| Sales order `SO-` | `draft, confirmed, partially_shipped, shipped, closed, cancelled` | **enumerated in one place**, `set_sales_order_status.sql:31-39`; `ship_order` drives `→partially_shipped/shipped` | `closed`, `cancelled`; `partially_shipped` has **no legal move** | soft |
| Quote `QT-` | `draft, issued, declined, converted` | `decline_quote` (issued→declined), `convert_quote` (issued→converted) | `converted` (frozen: `QT_CONVERTED_IMMUTABLE`), `declined` | soft |
| Invoice `INV-` | `issued, void` | `void_invoice` only; refuses `INVOICE_HAS_SETTLEMENTS`, `INVOICE_SHIPPED_NOT_VOIDABLE` | `void` | **hard-blocked** — `INVOICE_IMMUTABLE` |
| Credit note `CN-` | *(no status column)* | none — **immutable from creation** | n/a | **hard-blocked** — `BEFORE UPDATE OR DELETE` → `guard_credit_note_append_only` |
| Shipment `SHP-` | *(no status column)* | none | n/a | **hard-blocked** — `guard_shipment_append_only`; also **no INSERT/UPDATE/DELETE policy at all**, the only writer is `ship_order` |
| Work order `WO-` | `draft, released, closed, cancelled` | `release_work_order` (refuses `WO_NOT_DRAFT`), `close_work_order`, `cancel_work_order`, `amend_work_order` | `closed`, `cancelled` | **no `deleted_at`**; no write policy — `commit_processing_run` etc. are the only doors |
| Stocktake `ST-` | `open, posted, cancelled` | `post_stocktake`, `cancel_stocktake` | both | soft |
| Processing run `PROC-` | `committed, reversed` | `rollback_processing_run` (committed→reversed); `allocate_processing_costs` writes cost, not status | `reversed` | soft |
| Journal entry `JE-` | `posted, reversed` | `reverse_journal_entry_internal` | `reversed` | **hard-blocked** — `JOURNAL_IMMUTABLE` |
| Payment `PMT-` | `posted, reversed` | `reverse_payment` | `reversed` | **hard-blocked** — `PAYMENT_IMMUTABLE` |
| Expense `EXP-` | `payment_status: paid, unpaid` | `reverse_expense` | — | **hard-blocked** — `EXPENSE_IMMUTABLE` |
| Fixed asset `FA-` | `active, disposed` | `set_asset_in_service`, `set_asset_acceptance`, `dispose_fixed_asset` | `disposed` | no `deleted_at` |
| Leave request `LV-` | `pending, approved, rejected, cancelled` | `decide_leave_request`, `cancel_leave_request` | `approved`/`rejected`/`cancelled` | soft |
| Expense claim `CLM-` | `submitted, withdrawn, approved, rejected` | `decide_expense_claim`, `withdraw_expense_claim` | `approved`/`rejected`/`withdrawn` | no `deleted_at` |
| Medical claim `MC-` | `submitted, approved, rejected, paid` | `decide_medical_claim`, `pay_medical_claim` | `paid`, `rejected` | soft |
| Payroll period | `draft, posted` | `post_payroll_period`, `unpost_payroll_period` (**reversible**) | — | soft |
| GST period | `open, filed` | `file_gst_return`; `open_gst_period` creates | `filed` | no `deleted_at` |
| Bank statement `STMT-` | `open, reconciled` | `reconcile_statement`, `unreconcile_statement` (**reversible**) | — | soft |
| Inbound batch `IN-` | `pricing_status: unpriced, provisional, final` | `reprice_inbound_batch`, `reprice_from_committed_terms`, `apply_assay_result` | — | soft (`soft_delete_inbound_batch`) |
| Output batch `OUT-` | **two axes** — see below | `set_output_batch_purpose`; `state` written by `record_output_sale` / `ship_order` | — | soft (`soft_delete_output_batch`) |
| Task | `todo, in_progress, done` | `promote_task_to_team`, `correct_task_type` | — | soft |

### ★ Two disagreements worth the manual's attention

**1 · The output batch carries two independent state axes, and one is machine-written.**
`output_batches` has **both** `status` (`draft`, no CHECK) **and** `state` (FK →
`output_batch_states`). `state` answers only "how much of this has been sold" and is written
by `record_output_sale` / `ship_order` as `CASE WHEN remaining_qty = 0 THEN 已售罄 ELSE 部分售出 END`
(`db/tables/output_batch_states.sql`). A person picks it **only once**, when creating the batch.
The dictionary's own comment is explicit that *"已售罄 means sold out, NOT none left"* — a batch
consumed by a downstream process also reaches zero but does **not** get this state.

**2 · Immutability is the norm in finance, and it is enforced at the table, not the page.**
22 distinct guards: `ALLOCATION_IMMUTABLE`, `CLOSE_IMMUTABLE`, `EMPLOYMENT_HISTORY_IMMUTABLE`,
`EXPENSE_IMMUTABLE`, `FX_RATE_HISTORY_IMMUTABLE`, `HISTORY_APPEND_ONLY`, `INVOICE_IMMUTABLE`,
`JOURNAL_IMMUTABLE`, `LEAVE_CONSUMPTION_IMMUTABLE`, `MOVEMENT_IMMUTABLE`,
`NOTIFICATION_IMMUTABLE`, `PAYMENT_IMMUTABLE`, `PREPAYMENT_APPLICATION_IMMUTABLE`,
`PRICE_HISTORY_IMMUTABLE`, `PRICING_COMMITMENT_IMMUTABLE`, `RECONCILIATION_IMMUTABLE`,
`SALE_IMMUTABLE`, `SO_HISTORY_IMMUTABLE`, `SO_ISSUE_IMMUTABLE`, `VARIANCE_ITEM_IMMUTABLE`,
`YEAR_CLOSE_IMMUTABLE`, plus the credit-note and shipment append-only triggers.

**For the manual's "how to undo a mistake" slot this is the single most important fact in the
system:** for ledger documents there is **no undo**. There is only a **reversal** (a second,
opposite document) or a **credit note**. `inventory_movements` is append-only — a `BEFORE DELETE`
raises `MOVEMENT_IMMUTABLE` — so stock history can never be edited, only added to.


---

## S4 · Refusal paths ★ (bounded per R2)

### Half one — refusals that have an English sentence: **744**

Every one is listed in the table below with its **exact English sentence**, its message key,
and the file whose set registers it.

**The count was reached by two independent methods that converge exactly:**

| Method | Distinct codes |
|---|---:|
| A — scan all 38 `*ErrorCodes.ts`, detect each file's own key prefix, resolve against `messages/en.ts` | 672 |
| B — read the 80 registered `prefix → tsSet(file, set)` pairs out of `scripts/check-i18n.mjs` | 611 |
| **A ∪ B** | **744** |

744 is also, independently, the number of distinct codes across all 43 `tsSet(...)` sets
registered in `check-i18n.mjs`. Neither method alone is complete — A misses sets that live
outside the `*ErrorCodes.ts` files, B misses sets registered through `union(...)`. The union
matching the registry total is the check that the enumeration is closed.

### Half two — refusals with **no** English sentence

**App-side: zero. This is guaranteed, not observed.**
`scripts/check-i18n.mjs` reads each registered code set **at build time** and fails the build
if any member lacks a sentence in **both** locales. It is in `npm run build` and it is green
at `4fef88a`. So "an app-registered refusal code with no English sentence" is a state this
repo cannot be in.

**DB-side: 121 codes that no app code references at all.** This is the real defect list.

852 distinct `RAISE EXCEPTION` codes exist in `db/`. Against the 744 registered app-side:

| | Count | Meaning |
|---|---:|---|
| DB codes with a registered app-side handler | 689 | localised through the standard mechanism |
| DB codes handled by a **hand-written `switch`** | 42 | ★ see below — works, but ungated |
| DB codes with **no app reference at all** | **121** | if raised, the raw code reaches the screen |

★ **There are three refusal-localisation mechanisms, not one, and only the first is gated.**

1. **Registered set + `<prefix>.errors.<CODE>`** — 744 codes, build-gated by `check-i18n`.
2. **Hand-written `switch` in an `actions.ts`** with bespoke keys — e.g.
   `app/hr/leave/actions.ts:19-26` maps `INSUFFICIENT_ACCRUED_LEAVE` → `leave.errInsufficient`,
   `PROBATION_NO_ANNUAL_LEAVE` → `leave.errProbation`, `OVERLAPPING_REQUEST` → `leave.errOverlap`.
   **These have sentences but `check-i18n` does not know they exist**, so adding a new code
   there and forgetting the sentence is silent. 42 codes are in this shape. This is the
   "second hand-copied list" pattern the repo has paid for repeatedly (AGENTS.md:3133).
3. **Nothing** — 121 codes.

Of the 121, by shape: 29 immutability/append-only guards, 9 `_NOT_FOUND`, 9 `_REQUIRED`,
9 `_INVALID`/`_MISMATCH`, 65 other. Most are guards behind guards that no ordinary path
reaches — which is exactly why R2 declined to enumerate all 852. But **several look
person-reachable** and are the ones worth a decision (Q6):

`EQUIPMENT_DISPOSED` · `EQUIPMENT_NOT_ACQUIRED` · `CONTRACT_NOT_ACTIVE` · `LEAVE_TYPE_INACTIVE` ·
`BATCH_PROMISED_TO_CUSTOMER` · `ASSET_ACCEPTANCE_IN_FUTURE` · `ASSET_ACCEPTANCE_BEFORE_ACQUISITION` ·
`KPI_ORG_WEIGHTS_NOT_100` · `CLAIM_EXCEEDS_LIMIT` · `CLAIM_NOT_APPROVED` · `CLAIM_NOT_SUBMITTED` ·
`CERTIFICATE_REQUIRED` · `ACCEPTANCE_DATE_REQUIRED` · `INSUFFICIENT_ACCRUED_LEAVE`

(The last four **do** have sentences via mechanism 2 — they are listed here because they are
invisible to the gate, not because they are unlocalised.)

### On the "remedy" column

The repo's convention is that a refusal states its own way out — `IOD_CLASS_EXCLUDED` is the
model: *"…so nothing was saved. Pick another location, add non_focused to that location under
Inventory → Storage Locations, or correct this material's classification…"*.

A keyword heuristic finds **565 of 744** sentences with no explicit remedy phrase. **That
number is a worklist for the writing cut, not a defect count** — sampling shows many imply
the remedy perfectly well (`ALLOC_CURRENCY_MISMATCH`: *"{0} is a {1} document — settle it with
a {1} payment (got {2})"*). The writing cut should walk the table and supply the remedy where
the sentence alone does not carry it. I did not classify all 744 by hand; saying I had would
be the unsourced-claim failure 3.1 exists to prevent.

### The 744

| Code | Exact English sentence | Message key | Registered in |
|---|---|---|---|
| `ACCOUNT_INACTIVE` | Account inactive: {0} | `finance.errors.ACCOUNT_INACTIVE` | `app/finance/financeErrorCodes.ts` |
| `ACCOUNT_NOT_EXPENSE` | Account {0} is not an expense account | `expense.errors.ACCOUNT_NOT_EXPENSE` | `app/finance/expenseErrorCodes.ts` |
| `ACCOUNT_NOT_FOUND` | Account not found: {0} | `finance.errors.ACCOUNT_NOT_FOUND` | `app/finance/financeErrorCodes.ts` |
| `AGING_AS_OF_FUTURE` | Ageing cannot be asked for {0}, which is later than today ({1}) — that day has not happened yet. | `pack.errors.AGING_AS_OF_FUTURE` | `app/finance/packErrorCodes.ts` |
| `ALLOC_CURRENCY_MISMATCH` | {0} is a {1} document — settle it with a {1} payment (got {2}) | `finance.errors.ALLOC_CURRENCY_MISMATCH` | `app/finance/paymentErrorCodes.ts` |
| `ALLOC_EXCEEDS` | Allocation to {0} ({1}) exceeds its open amount ({2}) | `finance.errors.ALLOC_EXCEEDS` | `app/finance/paymentErrorCodes.ts` |
| `ALLOC_EXCEEDS_PAYMENT` | Total allocated ({0}) exceeds the payment amount ({1}) | `finance.errors.ALLOC_EXCEEDS_PAYMENT` | `app/finance/paymentErrorCodes.ts` |
| `ALLOC_UNPRICED` | Document {0} has no unit price yet | `finance.errors.ALLOC_UNPRICED` | `app/finance/paymentErrorCodes.ts` |
| `ALLOC_WRONG_PARTY` | Document {0} belongs to a different counterparty | `purchasing.errors.ALLOC_WRONG_PARTY` | `app/purchasing/purchasingErrorCodes.ts` |
| `ALLOC_WRONG_SIDE` | Allocation targets the wrong document type for this direction | `finance.errors.ALLOC_WRONG_SIDE` | `app/finance/paymentErrorCodes.ts` |
| `ALLOCATION_BASIS_REQUIRED` | Pick a cost allocation basis — it decides each output batch's reported gross margin, so it is a choice, never a default. | `processing.errors.ALLOCATION_BASIS_REQUIRED` | `app/operation/errorCodes.ts` |
| `ALREADY_CLOSED` | Period already closed (locked before {0}) | `finance.errors.ALREADY_CLOSED` | `app/finance/financeErrorCodes.ts` |
| `ALREADY_INVOICED` | Sale {0} is already on invoice {1} | `invoice.errors.ALREADY_INVOICED` | `app/finance/invoiceErrorCodes.ts` |
| `ALREADY_REOPENED` | This period has already been reopened | `finance.errors.ALREADY_REOPENED` | `app/finance/financeErrorCodes.ts` |
| `AMOUNT_INVALID` | Amount must be greater than 0 | `purchasing.errors.AMOUNT_INVALID` | `app/purchasing/purchasingErrorCodes.ts` |
| `APPROVAL_AMOUNT_REQUIRED` | This document has no base-currency amount, so it cannot be routed by value | `purchasing.errors.APPROVAL_AMOUNT_REQUIRED` | `app/purchasing/purchasingErrorCodes.ts` |
| `APPROVAL_LEVEL_INVALID` | Approval level {0} does not exist in this system | `purchasing.errors.APPROVAL_LEVEL_INVALID` | `app/purchasing/purchasingErrorCodes.ts` |
| `APPROVAL_LEVEL1_ROLE_NOT_SET` | The level-1 approver role is not set, so this order cannot be routed. Set it in Finance → Settings. | `purchasing.errors.APPROVAL_LEVEL1_ROLE_NOT_SET` | `app/purchasing/purchasingErrorCodes.ts` |
| `APPROVAL_LEVEL2_USER_NOT_SET` | The level-2 approver is not set, so an above-threshold order cannot be routed. Set it in Finance → Settings. | `purchasing.errors.APPROVAL_LEVEL2_USER_NOT_SET` | `app/purchasing/purchasingErrorCodes.ts` |
| `APPROVAL_NOT_AUTHORISED` | You are not the level-{0} approver ({1}) | `purchasing.errors.APPROVAL_NOT_AUTHORISED` | `app/purchasing/purchasingErrorCodes.ts` |
| `APPROVAL_SUBJECT_NOT_FOUND` | No {0} exists with id {1} — nothing to record a decision against | `purchasing.errors.APPROVAL_SUBJECT_NOT_FOUND` | `app/purchasing/purchasingErrorCodes.ts` |
| `APPROVAL_SUBJECT_TYPE_UNKNOWN` | "{0}" is not a kind of thing this system records approvals for | `purchasing.errors.APPROVAL_SUBJECT_TYPE_UNKNOWN` | `app/purchasing/purchasingErrorCodes.ts` |
| `APPROVAL_THRESHOLD_NOT_SET` | The approval threshold is not set, so this order cannot be routed to a level. Set it in Finance → Settings. | `purchasing.errors.APPROVAL_THRESHOLD_NOT_SET` | `app/purchasing/purchasingErrorCodes.ts` |
| `APPROVALS_CANNOT_DISABLE_WITH_PENDING` | Approvals cannot be switched off while {0} purchase order(s) still await approval: {1}. Switching off would strand them — they could never be approved, and goods could never be received against them. Approve or reject them first. | `finance.errors.APPROVALS_CANNOT_DISABLE_WITH_PENDING` | `app/finance/financeErrorCodes.ts` |
| `APPROVALS_LEVEL1_ROLE_UNHELD` | No real login account holds the level-1 approver role "{0}", so every request would queue with nobody able to approve it. Grant that role to someone first. | `finance.errors.APPROVALS_LEVEL1_ROLE_UNHELD` | `app/finance/financeErrorCodes.ts` |
| `APPROVALS_LEVEL2_USER_UNKNOWN` | The level-2 approver ({0}) is not a real login account. Choose someone who can actually sign in. | `finance.errors.APPROVALS_LEVEL2_USER_UNKNOWN` | `app/finance/financeErrorCodes.ts` |
| `APPROVALS_NOT_ENABLED` | Approvals are not in force, so there is nothing to approve — this order was stamped by the system when it was raised; nobody decided it. | `purchasing.errors.APPROVALS_NOT_ENABLED` | `app/purchasing/purchasingErrorCodes.ts` |
| `APPROVALS_POLICY_INCOMPLETE` | Approvals cannot be switched on until the policy is complete — still unset: {0}. Set the level-1 role, the threshold and the level-2 approver in one change, then switch it on. | `finance.errors.APPROVALS_POLICY_INCOMPLETE` | `app/finance/financeErrorCodes.ts` |
| `APPROVALS_POLICY_LOCKED_WHILE_ON` | {0} cannot be cleared while approvals are in force — an enabled control with no policy refuses every request. Switch approvals off first, then change the policy. | `finance.errors.APPROVALS_POLICY_LOCKED_WHILE_ON` | `app/finance/financeErrorCodes.ts` |
| `ARRIVAL_DATE_REQUIRED` | The arrival date is required — the stock movement records the day the goods actually arrived, and it is never filled in for you. Nothing was saved. Enter the date and submit again. | `stock.errors.ARRIVAL_DATE_REQUIRED` | `app/components/inventory/stockErrorCodes.ts` |
| `AS_OF_REQUIRED` | A date is needed. | `pack.errors.AS_OF_REQUIRED` | `app/finance/packErrorCodes.ts` |
| `ASSAY_ALREADY_APPLIED` | Assay {0} has already been applied | `assay.errors.ASSAY_ALREADY_APPLIED` | `app/inbound/assayErrorCodes.ts` |
| `ASSAY_BASIS_REQUIRED` | Say which weight this assay was reported on - as-received (wet) or dry. A figure whose basis nobody stated cannot be interpreted later: 30% dry and 30% as-received are different numbers, and how different depends on the moisture. | `assay.errors.ASSAY_BASIS_REQUIRED` | `app/inbound/assayErrorCodes.ts` |
| `ASSAY_DATE_INVALID` | Assay date {0} is invalid or in the future | `assay.errors.ASSAY_DATE_INVALID` | `app/inbound/assayErrorCodes.ts` |
| `ASSAY_IS_INBOUND` | Assay {0} belongs to an inbound batch — apply it with the inbound-assay action, which also restates the payable from the assayed content. | `assay.errors.ASSAY_IS_INBOUND` | `app/inbound/assayErrorCodes.ts` |
| `ASSAY_IS_OUTPUT` | Assay {0} belongs to an output batch — apply it with the output-assay action. Applying an inbound assay means restating the payable, and an output batch has no payable to restate. | `assay.errors.ASSAY_IS_OUTPUT` | `app/inbound/assayErrorCodes.ts` |
| `ASSAY_NOT_FOUND` | Assay result not found | `assay.errors.ASSAY_NOT_FOUND` | `app/inbound/assayErrorCodes.ts` |
| `ASSAY_ONE_PARENT` | An assay needs exactly one parent — an inbound batch or an output batch, not both, not neither | `assay.errors.ASSAY_ONE_PARENT` | `app/inbound/assayErrorCodes.ts` |
| `ASSAY_RESULT_PARTY_REQUIRED` | Say whose result this is - ours, the counterparty's, or an umpire's. There is deliberately no default: defaulting to "ours" would let a forgotten field become a claim that we measured it. | `assay.errors.ASSAY_RESULT_PARTY_REQUIRED` | `app/inbound/assayErrorCodes.ts` |
| `ASSET_ACQUISITION_DATE_REQUIRED` | An acquisition date is required — it is the earliest date the machine may be put into service. | `finance.errors.ASSET_ACQUISITION_DATE_REQUIRED` | `app/finance/paymentErrorCodes.ts` |
| `ASSET_ALREADY_DISPOSED` | Asset {0} has already been disposed. | `finance.errors.ASSET_ALREADY_DISPOSED` | `app/finance/paymentErrorCodes.ts` |
| `ASSET_ALREADY_IN_SERVICE` | Asset {0} has already been commissioned, on {1} — commissioning happens once. Moving that date would overturn every depreciation period already posted, which is a correction: post a manual journal entry under Finance → Journal. (Adding cost to a running machine is a different thing and it is now allowed — see the machine’s maintenance record.) | `finance.errors.ASSET_ALREADY_IN_SERVICE` | `app/finance/paymentErrorCodes.ts` |
| `ASSET_CATEGORY_INVALID` | Category {0} is not one of: {1} | `finance.errors.ASSET_CATEGORY_INVALID` | `app/finance/paymentErrorCodes.ts` |
| `ASSET_COST_LEDGER_DIVERGED` | Asset {0}: the recorded cost {1} does not equal the sum of its live cost entries {2}. The reversal was refused rather than write a figure that does not tie. | `expense.errors.ASSET_COST_LEDGER_DIVERGED` | `app/finance/expenseErrorCodes.ts` |
| `ASSET_DESCRIPTION_REQUIRED` | The asset needs a description | `finance.errors.ASSET_DESCRIPTION_REQUIRED` | `app/finance/paymentErrorCodes.ts` |
| `ASSET_DISPOSED` | Asset {0} has been disposed — no further cost can be added to it. | `finance.errors.ASSET_DISPOSED` | `app/finance/paymentErrorCodes.ts` |
| `ASSET_HAS_NO_COST` | Asset {0} has no cost yet. A card is created when we commit to acquiring a machine; its cost arrives with the invoice. Record the invoice against this card first. | `finance.errors.ASSET_HAS_NO_COST` | `app/finance/paymentErrorCodes.ts` |
| `ASSET_IN_SERVICE_BEFORE_ACQUISITION` | In-service date {0} is before the acquisition date {1} | `expense.errors.ASSET_IN_SERVICE_BEFORE_ACQUISITION` | `app/finance/expenseErrorCodes.ts` |
| `ASSET_IN_SERVICE_COST_LOCKED` | Expense {0} was capitalised into asset {1}, which went into service on {2}. Its cost cannot be reversed — depreciation has already been computed from that cost base. This needs a finance decision. | `expense.errors.ASSET_IN_SERVICE_COST_LOCKED` | `app/finance/expenseErrorCodes.ts` |
| `ASSET_IN_SERVICE_IN_FUTURE` | You entered {0} as the in-service date, and that day has not arrived. Commissioning is something that HAPPENED. If you are recording that the line will be commissioned then, that is the planned date - it locks nothing and drives nothing. | `equipment.errors.ASSET_IN_SERVICE_IN_FUTURE` | `app/finance/assets/equipmentErrorCodes.ts` |
| `ASSET_IN_SERVICE_NEEDS_MAINTENANCE` | Machine {0} has been running since {1}, so adding cost to it is a capitalisation — and that judgement (a capitalised improvement, or this period’s expense) is yours, not the system’s. Record the work as a maintenance record on the machine first, mark it capitalised with your reason, then capitalise against it. | `equipment.errors.ASSET_IN_SERVICE_NEEDS_MAINTENANCE` | `app/finance/assets/equipmentErrorCodes.ts` |
| `ASSET_LIFE_EXHAUSTED` | Machine {0} has reached the end of its {1}-month useful life, so there is no remaining life to spread an addition over. This spend is either this period’s expense, or it needs a revision of the useful life first — and that act does not exist yet. | `equipment.errors.ASSET_LIFE_EXHAUSTED` | `app/finance/assets/equipmentErrorCodes.ts` |
| `ASSET_LIFE_INVALID` | Useful life (months) must be a positive whole number, got {0} | `finance.errors.ASSET_LIFE_INVALID` | `app/finance/paymentErrorCodes.ts` |
| `ASSET_NOT_FOUND` | No asset card {0}. A purchase-order line references a machine that already exists; it does not create one. | `purchasing.errors.ASSET_NOT_FOUND` | `app/purchasing/purchasingErrorCodes.ts` |
| `ASSET_REQUIRES_CAPITAL_ACCOUNT` | Asset details were given but the account is {0} — capital expenditure posts to 1500 | `expense.errors.ASSET_REQUIRES_CAPITAL_ACCOUNT` | `app/finance/expenseErrorCodes.ts` |
| `ASSET_RESIDUAL_INVALID` | Residual value {0} must be ≥ 0 and below cost {1} | `expense.errors.ASSET_RESIDUAL_INVALID` | `app/finance/expenseErrorCodes.ts` |
| `ATTENDANCE_HOURS_INVALID` | Overtime hours cannot be negative (normal {0}, rest day {1}, public holiday {2}) | `hr.errors.ATTENDANCE_HOURS_INVALID` | `app/hr/hrErrorCodes.ts` |
| `ATTENDANCE_LINE_NOT_FOUND` | Attendance line not found ({0}) | `hr.errors.ATTENDANCE_LINE_NOT_FOUND` | `app/hr/hrErrorCodes.ts` |
| `ATTENDANCE_MONTH_FUTURE` | {0} has not finished yet (today is {1}) — a month cannot be complete before it ends | `hr.errors.ATTENDANCE_MONTH_FUTURE` | `app/hr/hrErrorCodes.ts` |
| `ATTENDANCE_MONTH_REQUIRED` | Pick a month | `hr.errors.ATTENDANCE_MONTH_REQUIRED` | `app/hr/hrErrorCodes.ts` |
| `ATTENDANCE_PERIOD_EXISTS` | That month already has a sheet ({0}) | `hr.errors.ATTENDANCE_PERIOD_EXISTS` | `app/hr/hrErrorCodes.ts` |
| `ATTENDANCE_PERIOD_INCOMPLETE` | {0} still has {1} line(s) nobody has recorded — a sheet that tolerates blanks is a checkbox, not a statement | `hr.errors.ATTENDANCE_PERIOD_INCOMPLETE` | `app/hr/hrErrorCodes.ts` |
| `ATTENDANCE_PERIOD_LOCKED_BY_PAYROLL` | Payroll {1} for {0} is already posted — unpost it first; a posted payslip cannot have its basis changed underneath it | `hr.errors.ATTENDANCE_PERIOD_LOCKED_BY_PAYROLL` | `app/hr/hrErrorCodes.ts` |
| `ATTENDANCE_PERIOD_NOT_COMPLETE` | {0} is {1}, not complete — there is nothing to reopen | `hr.errors.ATTENDANCE_PERIOD_NOT_COMPLETE` | `app/hr/hrErrorCodes.ts` |
| `ATTENDANCE_PERIOD_NOT_FOUND` | Attendance period not found ({0}) | `hr.errors.ATTENDANCE_PERIOD_NOT_FOUND` | `app/hr/hrErrorCodes.ts` |
| `ATTENDANCE_PERIOD_NOT_OPEN` | {0} is {1} — a completed sheet is what we reported, so it cannot be edited. Reopen it first. | `hr.errors.ATTENDANCE_PERIOD_NOT_OPEN` | `app/hr/hrErrorCodes.ts` |
| `ATTENDANCE_REOPEN_REASON_REQUIRED` | Give a reason for reopening {0} | `hr.errors.ATTENDANCE_REOPEN_REASON_REQUIRED` | `app/hr/hrErrorCodes.ts` |
| `BALANCE_DISAGREES` | The bank and your books do not agree. Bank closing balance {0}, book balance {1} — a difference of {2}. Either finish correcting the books, or record what the difference is made of below and reconcile with it stated. | `bank.errors.BALANCE_DISAGREES` | `app/finance/bankErrorCodes.ts` |
| `BANK_ACCOUNT_REQUIRED` | A paid freight invoice needs the bank account it was paid from. | `finance.freight.errors.BANK_ACCOUNT_REQUIRED` | `app/finance/freightErrorCodes.ts` |
| `BANK_INVALID` | Invalid bank account: {0} | `bank.errors.BANK_INVALID` | `app/finance/bankErrorCodes.ts` |
| `BATCH_DELETED` | Batch {0} has been deleted | `stocktakes.errors.BATCH_DELETED` | `app/stocktakes/stocktakeErrorCodes.ts` |
| `BATCH_NO_HARD_DELETE` | Batch {0} cannot be permanently deleted — use delete (which keeps the record and writes a write-off movement). | `deletion.errors.BATCH_NO_HARD_DELETE` | `app/components/inventory/deletionErrorCodes.ts` |
| `BATCH_NOT_FOUND` | That batch does not exist, or has been deleted: {0} | `traceability.errors.BATCH_NOT_FOUND` | `app/output/traceabilityErrorCodes.ts` |
| `BATCH_PURPOSE_UNKNOWN` | Unknown or inactive purpose "{0}". Inactive means "do not pick it again", not "rewrite history". | `output.purpose.errors.BATCH_PURPOSE_UNKNOWN` | `app/output/[id]/edit/purposeErrorCodes.ts` |
| `BATCH_REQUIRED` | No batch was given. | `traceability.errors.BATCH_REQUIRED` | `app/output/traceabilityErrorCodes.ts` |
| `CAPITAL_REQUIRES_ASSET` | Account 1500 requires asset details — a fixed-asset debit cannot exist without its register entry | `expense.errors.CAPITAL_REQUIRES_ASSET` | `app/finance/expenseErrorCodes.ts` |
| `CARRY_FORWARD_BEFORE_SYSTEM_START` | Leave year {0} ended before this database started operating ({1}). Those months are not recorded here, so carrying them forward would invent a balance. Enter historical balances as leave grants instead. | `hr.errors.CARRY_FORWARD_BEFORE_SYSTEM_START` | `app/hr/hrErrorCodes.ts` |
| `CHASE_ALREADY_SUPERSEDED` | Chase {0} was already superseded on {1}. Correct the record that replaced it, not this one. | `chases.errors.CHASE_ALREADY_SUPERSEDED` | `app/finance/collections/chaseErrorCodes.ts` |
| `CHASE_CHANNEL_INVALID` | “{0}” is not a channel this system knows. | `chases.errors.CHASE_CHANNEL_INVALID` | `app/finance/collections/chaseErrorCodes.ts` |
| `CHASE_CONTACT_WITHOUT_REACH` | You recorded that nobody was reached, but named {0} as the person spoken to. | `chases.errors.CHASE_CONTACT_WITHOUT_REACH` | `app/finance/collections/chaseErrorCodes.ts` |
| `CHASE_DATE_FUTURE` | A chase cannot have happened on {0} — that is in the future, and today is {1}. A conversation that has not happened is a plan, not a record. | `chases.errors.CHASE_DATE_FUTURE` | `app/finance/collections/chaseErrorCodes.ts` |
| `CHASE_DATE_REQUIRED` | A chase needs the date it actually happened. There is deliberately no default — a date that decides what a record means is never filled in for you. | `chases.errors.CHASE_DATE_REQUIRED` | `app/finance/collections/chaseErrorCodes.ts` |
| `CHASE_DOCUMENT_KIND_UNKNOWN` | “{0}” is not a kind of document a chase can reference. | `chases.errors.CHASE_DOCUMENT_KIND_UNKNOWN` | `app/finance/collections/chaseErrorCodes.ts` |
| `CHASE_DOCUMENT_NOT_THIS_CUSTOMER` | That {0} ({1}) does not belong to this customer. A chase claiming to have discussed someone else’s document is a statement nobody would think to check. | `chases.errors.CHASE_DOCUMENT_NOT_THIS_CUSTOMER` | `app/finance/collections/chaseErrorCodes.ts` |
| `CHASE_NOT_FOUND` | No chase with id {0}. | `chases.errors.CHASE_NOT_FOUND` | `app/finance/collections/chaseErrorCodes.ts` |
| `CHASE_REACHED_REQUIRED` | Say whether you actually reached someone. “We tried three times and nobody answered” and “he promised three times” are different stories, and only one of them is a reason to stop chasing. | `chases.errors.CHASE_REACHED_REQUIRED` | `app/finance/collections/chaseErrorCodes.ts` |
| `CHASE_SUMMARY_REQUIRED` | Record what was said. A chase with no content is only a timestamp — and what the other side said is the whole reason this record exists. | `chases.errors.CHASE_SUMMARY_REQUIRED` | `app/finance/collections/chaseErrorCodes.ts` |
| `CHASE_SUPERSEDE_OUTCOME_RECORDED` | Chase {0} carries a promise whose outcome is already recorded as “{1}”. Correcting the note would erase a fact about the world — whether the money arrived. Record a new chase instead. | `chases.errors.CHASE_SUPERSEDE_OUTCOME_RECORDED` | `app/finance/collections/chaseErrorCodes.ts` |
| `CHASE_SUPERSEDE_REASON_REQUIRED` | Correcting chase {0} replaces it with a new record and marks this one superseded, so a reason is required. The original stays on file. | `chases.errors.CHASE_SUPERSEDE_REASON_REQUIRED` | `app/finance/collections/chaseErrorCodes.ts` |
| `CLAIM_YEAR_BEFORE_SYSTEM_START` | Claim year {0} ended before this database began holding a complete record ({1}). Claims from that year are not recorded here, so any remaining allowance shown would be invented. | `hr.errors.CLAIM_YEAR_BEFORE_SYSTEM_START` | `app/hr/hrErrorCodes.ts` |
| `CLOSE_NOT_FOUND` | No close found for this period | `finance.errors.CLOSE_NOT_FOUND` | `app/finance/financeErrorCodes.ts` |
| `CLOSE_NOTES_REQUIRED` | This order has {0} of unapplied prepayment — a note explaining how it is resolved is required to close | `purchasing.errors.CLOSE_NOTES_REQUIRED` | `app/purchasing/purchasingErrorCodes.ts` |
| `CN_BALANCE_MISSING` | The balance for invoice {0} could not be read, so no ceiling could be applied and nothing was saved. Report this rather than retrying. | `cn.errors.CN_BALANCE_MISSING` | `app/finance/creditNoteErrorCodes.ts` |
| `CN_BASIS_MISMATCH` | The credit note’s {0} ({2}) does not match the invoice’s ({1}). A credit note always copies both from the invoice — reversing at any other basis invents an FX gain out of nothing. | `cn.errors.CN_BASIS_MISMATCH` | `app/finance/creditNoteErrorCodes.ts` |
| `CN_EXCEEDS_OPEN` | That credit ({0}) is more than invoice still has open ({1}). A credit note cannot take an invoice below zero — the excess would be a refund, which this system does not model yet. | `cn.errors.CN_EXCEEDS_OPEN` | `app/finance/creditNoteErrorCodes.ts` |
| `CN_EXCEEDS_RELEASED` | Line {0}: {1} cannot be credited as a price adjustment — only {2} of that line has been delivered and not already credited. For goods not delivered, cancel them instead; the two post to different accounts. | `cn.errors.CN_EXCEEDS_RELEASED` | `app/finance/creditNoteErrorCodes.ts` |
| `CN_EXCEEDS_UNRELEASED` | Line {0}: {1} cannot be cancelled as undelivered — at most {2} on that line has not been delivered. For goods that WERE delivered, use a price/quality adjustment instead; the two post to different accounts. | `cn.errors.CN_EXCEEDS_UNRELEASED` | `app/finance/creditNoteErrorCodes.ts` |
| `CN_INVOICE_FULLY_SETTLED` | Invoice {0} has nothing open: it is fully paid or already fully credited. Giving money back is a refund, which this system does not model yet. | `cn.errors.CN_INVOICE_FULLY_SETTLED` | `app/finance/creditNoteErrorCodes.ts` |
| `CN_INVOICE_NOT_FOUND` | That invoice no longer exists. Reload and try again. | `cn.errors.CN_INVOICE_NOT_FOUND` | `app/finance/creditNoteErrorCodes.ts` |
| `CN_INVOICE_NOT_ORDER_KIND` | Invoice {0} is a {1}-kind invoice, and credit notes apply to order-flow invoices only. A {1}-kind invoice posts nothing on its own, so there is no entry to credit — void it, or reverse the receipt, instead. | `cn.errors.CN_INVOICE_NOT_ORDER_KIND` | `app/finance/creditNoteErrorCodes.ts` |
| `CN_INVOICE_VOID` | Invoice {0} is void — there is nothing left to credit. | `cn.errors.CN_INVOICE_VOID` | `app/finance/creditNoteErrorCodes.ts` |
| `CN_LINE_INVALID` | Line {0}: {1} is not usable. Nothing was saved. | `cn.errors.CN_LINE_INVALID` | `app/finance/creditNoteErrorCodes.ts` |
| `CN_LINE_WRONG_INVOICE` | Line {0} does not belong to this invoice. Reload the page and try again. | `cn.errors.CN_LINE_WRONG_INVOICE` | `app/finance/creditNoteErrorCodes.ts` |
| `CN_LINES_LOST` | The credit note was not written completely ({0} lines sent, {1} stored), so nothing was saved. Report this rather than retrying. | `cn.errors.CN_LINES_LOST` | `app/finance/creditNoteErrorCodes.ts` |
| `CN_NO_LINES` | A credit note against {0} needs at least one line. Nothing was saved. | `cn.errors.CN_NO_LINES` | `app/finance/creditNoteErrorCodes.ts` |
| `CN_NOT_FOUND` | That credit note no longer exists. | `cn.errors.CN_NOT_FOUND` | `app/finance/creditNoteErrorCodes.ts` |
| `CN_NOTE_DATE_REQUIRED` | The credit note date is required — it decides which accounting period the reversal lands in, and it is never defaulted. | `cn.errors.CN_NOTE_DATE_REQUIRED` | `app/finance/creditNoteErrorCodes.ts` |
| `CN_REASON_REQUIRED` | A credit note needs a reason. Without one, three months from now nobody can say why the customer was credited. | `cn.errors.CN_REASON_REQUIRED` | `app/finance/creditNoteErrorCodes.ts` |
| `COMMISSION_AGENT_NOT_SERVICE_VENDOR` | Supplier {0} is not a service vendor, so a commission cannot be agreed with it. The payee of a commission is a third party who provides a service — change that counterparty’s type, or create the agent as a service vendor. | `commissions.errors.COMMISSION_AGENT_NOT_SERVICE_VENDOR` | `app/sales/commissions/commissionErrorCodes.ts` |
| `COMMISSION_AUTH_UNAVAILABLE` | The sign-in service could not be reached, so this was not saved. This does NOT mean you are signed out — it means the system could not tell. Try again in a moment. | `commissions.errors.COMMISSION_AUTH_UNAVAILABLE` | `app/sales/commissions/commissionErrorCodes.ts` |
| `COMMISSION_BASIS_FIELDS` | A percentage agreement carries a rate and no amount; a per-tonne or fixed agreement carries an amount and a currency. One row cannot say both, because nobody could tell which one counts. | `commissions.errors.COMMISSION_BASIS_FIELDS` | `app/sales/commissions/commissionErrorCodes.ts` |
| `COMMISSION_NOT_PERMITTED` | You do not have permission to change commission agreements. Viewing them needs supplier access; changing them needs supplier edit rights. | `commissions.errors.COMMISSION_NOT_PERMITTED` | `app/sales/commissions/commissionErrorCodes.ts` |
| `COMMISSION_TRIGGER_REQUIRED` | Say when the obligation arises. It is a term of this agreement and it has no default, because it decides which period the cost belongs to. | `commissions.errors.COMMISSION_TRIGGER_REQUIRED` | `app/sales/commissions/commissionErrorCodes.ts` |
| `COMMISSION_VALIDITY_ORDER` | The end of the validity window cannot fall before its start. | `commissions.errors.COMMISSION_VALIDITY_ORDER` | `app/sales/commissions/commissionErrorCodes.ts` |
| `COMMISSION_VALIDITY_REQUIRED` | Give the agreement a start and an end date. An agreement with no validity window cannot be said to be in force on any particular day. | `commissions.errors.COMMISSION_VALIDITY_REQUIRED` | `app/sales/commissions/commissionErrorCodes.ts` |
| `COMMITMENT_TARGET_INVALID` | A commitment attaches to exactly one record: an order line or a batch | `purchasing.errors.COMMITMENT_TARGET_INVALID` | `app/purchasing/purchasingErrorCodes.ts` |
| `CONSUMED_EXCEEDS_REMAINING` | Consumed quantity ({0}) exceeds inbound remaining ({1}) | `processing.errors.CONSUMED_EXCEEDS_REMAINING` | `app/operation/errorCodes.ts` |
| `CONTACT_DELETED` | That contact has been removed from the list (id {0}). Add a new one rather than editing a removed one — the removed row is kept so that older records naming that person still make sense. | `contacts.errors.CONTACT_DELETED` | `app/sales/customers/contactErrorCodes.ts` |
| `CONTACT_NAME_REQUIRED` | Give this person a name. A contact with no name reads as "nobody" in the list. | `contacts.errors.CONTACT_NAME_REQUIRED` | `app/sales/customers/contactErrorCodes.ts` |
| `CONTACT_NOT_FOUND` | That contact no longer exists (id {0}). Someone may have removed it while this page was open — reload and try again. | `contacts.errors.CONTACT_NOT_FOUND` | `app/sales/customers/contactErrorCodes.ts` |
| `CONTACT_OWNER_REQUIRED` | A contact belongs to exactly one counterparty — either a customer or a supplier, not both and not neither. | `contacts.errors.CONTACT_OWNER_REQUIRED` | `app/sales/customers/contactErrorCodes.ts` |
| `CONTACT_UNREACHABLE` | Leave at least one way to reach {0} — an email or a phone number. A contact with only a name helps nobody when an invoice has to go out or a payment is late. | `contacts.errors.CONTACT_UNREACHABLE` | `app/sales/customers/contactErrorCodes.ts` |
| `CONTAINER_DEPARTURE_DATE_REQUIRED` | Give the day the vessel actually sails. The system cannot know it, so it is never filled in for you. | `logistics.opErrors.CONTAINER_DEPARTURE_DATE_REQUIRED` | `app/logistics/logisticsErrorCodes.ts` |
| `CONTAINER_DOC_NA_REASON_REQUIRED` | Say why {0} does not apply. A "not applicable" with no reason looks exactly like a document someone forgot. | `logistics.opErrors.CONTAINER_DOC_NA_REASON_REQUIRED` | `app/logistics/logisticsErrorCodes.ts` |
| `CONTAINER_FORWARDER_NOT_A_FORWARDER` | That company is not a forwarder, so it cannot be the carrier on a container. | `logistics.opErrors.CONTAINER_FORWARDER_NOT_A_FORWARDER` | `app/logistics/logisticsErrorCodes.ts` |
| `CONTAINER_LANE_REQUIRED` | Choose the lane this container runs on — the document checklist and the milestones both hang off it. | `logistics.opErrors.CONTAINER_LANE_REQUIRED` | `app/logistics/logisticsErrorCodes.ts` |
| `CONTAINER_MILESTONE_IMMUTABLE` | Milestones are never edited. Record a new one and say in its note what it corrects. | `logistics.opErrors.CONTAINER_MILESTONE_IMMUTABLE` | `app/logistics/logisticsErrorCodes.ts` |
| `CONTAINER_NOT_FOUND` | That container does not exist, or it has been written off. | `logistics.opErrors.CONTAINER_NOT_FOUND` | `app/logistics/logisticsErrorCodes.ts` |
| `CONTENT_INVALID` | Content % for {0} is invalid: {1} | `pricing.errors.CONTENT_INVALID` | `app/tools/pricing/pricingErrorCodes.ts` |
| `COST_ENTRY_ALREADY_SETTLED` | This {0} cost entry has already been settled | `processing.errors.COST_ENTRY_ALREADY_SETTLED` | `app/operation/errorCodes.ts` |
| `COST_ENTRY_INVALID` | Cost entry not found or deleted | `processing.errors.COST_ENTRY_INVALID` | `app/operation/errorCodes.ts` |
| `COST_ENTRY_IS_ESTIMATE` | {0} is an estimate — it is relieved by the real invoice, not remitted | `processing.errors.COST_ENTRY_IS_ESTIMATE` | `app/operation/errorCodes.ts` |
| `COST_ENTRY_NOT_ESTIMATE` | {0} is an actual cost — remit it, invoices only relieve estimates | `processing.errors.COST_ENTRY_NOT_ESTIMATE` | `app/operation/errorCodes.ts` |
| `COST_ENTRY_SETTLED` | A settled {0} cost entry can no longer be changed or deleted | `processing.errors.COST_ENTRY_SETTLED` | `app/operation/errorCodes.ts` |
| `COUNTERPARTY_AMBIGUOUS` | An expense is owed to a supplier or to an employee, not to both | `expense.errors.COUNTERPARTY_AMBIGUOUS` | `app/finance/expenseErrorCodes.ts` |
| `COUNTERPARTY_NOT_FOUND` | Counterparty not found | `finance.errors.COUNTERPARTY_NOT_FOUND` | `app/finance/paymentErrorCodes.ts` |
| `COUNTERPARTY_REQUIRED_FOR_UNPAID` | An unpaid expense must say who it is owed to — a supplier or an employee | `expense.errors.COUNTERPARTY_REQUIRED_FOR_UNPAID` | `app/finance/expenseErrorCodes.ts` |
| `CREDIT_HOLD` | Customer {0} is on credit hold — no sales can be recorded until the hold is lifted on the customer record. The hold is a person’s decision, so nothing here can override it. | `output.sale.errors.CREDIT_HOLD` | `app/output/[id]/edit/saleErrorCodes.ts` |
| `CREDIT_LIMIT_EXCEEDED` | Credit limit reached for customer {0}. Limit {1}, already outstanding {2}, this sale {3} — all in the base currency. Raise the limit on the customer, or take payment before releasing the goods. | `output.sale.errors.CREDIT_LIMIT_EXCEEDED` | `app/output/[id]/edit/saleErrorCodes.ts` |
| `CREDIT_NOTE_IMMUTABLE` | A credit note cannot be changed or deleted ({0}) — it is a posted document that may already have been sent. | `cn.errors.CREDIT_NOTE_IMMUTABLE` | `app/finance/creditNoteErrorCodes.ts` |
| `CURRENCY_INVALID` | Currency {0} is not one this system knows. | `quotes.errors.CURRENCY_INVALID` | `app/sales/quotes/quoteErrorCodes.ts` |
| `CUSTOMER_NOT_FOUND` | That customer no longer exists ({0}). | `contacts.errors.CUSTOMER_NOT_FOUND` | `app/sales/customers/contactErrorCodes.ts` |
| `CUSTOMER_PAYMENT_TERMS_NOT_SET` | This invoice has no due date to stand on: customer {0} ({1}) has no payment terms on file, and none was given for this invoice. Set "Payment terms (days)" under Customers → Edit, or state the terms on the invoice itself. The system no longer assumes 30 days — an invented due date feeds ageing, statements, chases and the cash forecast, and it looks authoritative in all four. | `invoice.errors.CUSTOMER_PAYMENT_TERMS_NOT_SET` | `app/finance/invoiceErrorCodes.ts` |
| `CYCLE_CLOSED` | Cycle {0} is closed | `reviews.errors.CYCLE_CLOSED` | `app/hr/reviews/reviewErrorCodes.ts` |
| `CYCLE_NOT_FOUND` | Review cycle not found | `reviews.errors.CYCLE_NOT_FOUND` | `app/hr/reviews/reviewErrorCodes.ts` |
| `DATE_REQUIRED` | A date is required | `finance.errors.DATE_REQUIRED` | `app/finance/financeErrorCodes.ts` |
| `DELETE_REASON_REQUIRED` | A reason is required to delete {1} — a deletion nobody can explain later is worse than the record it removed. (Table: {0}) | `deletion.errors.DELETE_REASON_REQUIRED` | `app/components/inventory/deletionErrorCodes.ts` |
| `DEPARTMENT_CYCLE` | A department cannot be its own parent | `hr.errors.DEPARTMENT_CYCLE` | `app/hr/hrErrorCodes.ts` |
| `DEPRECIATION_ANCHOR_IMMUTABLE` | A depreciation anchor records a change in estimate that happened, and cannot be edited ({0}). Add another anchor instead. | `equipment.errors.DEPRECIATION_ANCHOR_IMMUTABLE` | `app/finance/assets/equipmentErrorCodes.ts` |
| `DEPRECIATION_NOT_RUN` | Depreciation has not been run level for {0} | `finance.errors.DEPRECIATION_NOT_RUN` | `app/finance/financeErrorCodes.ts` |
| `DEPRECIATION_OUTSTANDING` | Depreciation for the period ending {0} has not been posted yet ({1} outstanding). Post it before locking — once the period is locked, the charge can only be made after reopening it. | `finance.errors.DEPRECIATION_OUTSTANDING` | `app/finance/paymentErrorCodes.ts` |
| `DETACH_REASON_REQUIRED` | Say why {0} is coming out of this container. Loaded by mistake and changed our mind are different things, and only the reason tells them apart later. | `logistics.opErrors.DETACH_REASON_REQUIRED` | `app/logistics/logisticsErrorCodes.ts` |
| `DIRECTION_INVALID` | Invalid direction: {0} | `finance.errors.DIRECTION_INVALID` | `app/finance/paymentErrorCodes.ts` |
| `DISPOSAL_BEFORE_ACQUISITION` | A disposal date of {0} is before the asset was acquired ({1}). | `finance.errors.DISPOSAL_BEFORE_ACQUISITION` | `app/finance/paymentErrorCodes.ts` |
| `DOWNTIME_END_IN_FUTURE` | That downtime ends at {0}, which has not happened yet. Record the end when the machine actually comes back; leaving it open is what "still down" looks like. | `equipment.errors.DOWNTIME_END_IN_FUTURE` | `app/finance/assets/equipmentErrorCodes.ts` |
| `DOWNTIME_END_REQUIRED` | Enter when the machine came back. | `equipment.errors.DOWNTIME_END_REQUIRED` | `app/finance/assets/equipmentErrorCodes.ts` |
| `DOWNTIME_OVERLAPS` | This period overlaps one already recorded for this machine: {0} to {1}. A machine cannot be down twice over the same minutes. Close or correct that period first. (Two periods MAY touch - one ending exactly when the next begins.) | `equipment.errors.DOWNTIME_OVERLAPS` | `app/finance/assets/equipmentErrorCodes.ts` |
| `DOWNTIME_REASON_REQUIRED` | Say why the machine went down. | `equipment.errors.DOWNTIME_REASON_REQUIRED` | `app/finance/assets/equipmentErrorCodes.ts` |
| `DOWNTIME_START_IN_FUTURE` | That downtime starts at {0}, which has not happened yet. A downtime period records something that DID happen - if you are planning a future window, that is a plan, and this column cannot hold one. | `equipment.errors.DOWNTIME_START_IN_FUTURE` | `app/finance/assets/equipmentErrorCodes.ts` |
| `DOWNTIME_START_REQUIRED` | Enter when the machine went down. | `equipment.errors.DOWNTIME_START_REQUIRED` | `app/finance/assets/equipmentErrorCodes.ts` |
| `DUPLICATE_EMPLOYEE` | Employee {0} appears more than once | `hr.errors.DUPLICATE_EMPLOYEE` | `app/hr/hrErrorCodes.ts` |
| `DUPLICATE_INPUT` | The same inbound batch cannot be added more than once | `processing.errors.DUPLICATE_INPUT` | `app/operation/errorCodes.ts` |
| `DUPLICATE_METAL` | Metal {0} appears more than once | `pricing.errors.DUPLICATE_METAL` | `app/tools/pricing/pricingErrorCodes.ts` |
| `DUPLICATE_SALE` | Sale {0} appears more than once | `invoice.errors.DUPLICATE_SALE` | `app/finance/invoiceErrorCodes.ts` |
| `EMPLOYEE_NOT_FOUND` | Employee not found: {0} | `hr.errors.EMPLOYEE_NOT_FOUND` | `app/hr/hrErrorCodes.ts` |
| `EMPLOYEE_NOT_ON_PROBATION` | {0} is not on probation (status: {1}), so there is no probation to confirm. A probation review can only be raised for someone currently on probation — approving one changes employment status and writes a confirmation date. | `reviews.errors.EMPLOYEE_NOT_ON_PROBATION` | `app/hr/reviews/reviewErrorCodes.ts` |
| `EMPLOYEE_SEPARATED` | Employee {0} has left the company | `reviews.errors.EMPLOYEE_SEPARATED` | `app/hr/reviews/reviewErrorCodes.ts` |
| `EXCEEDS_OPEN` | Open payable on the batch is {0}; requested {1} | `purchasing.errors.EXCEEDS_OPEN` | `app/purchasing/purchasingErrorCodes.ts` |
| `EXPECTED_DATE_IN_PAST` | An expected date of {0} is in the past — today is {1}. That is not an estimate, it is an estimate nobody has revisited. {2} keeps this one. | `cashForecast.errors.EXPECTED_DATE_IN_PAST` | `app/finance/cashForecastErrorCodes.ts` |
| `EXPECTED_DATE_NOT_APPLICABLE` | An instalment triggered by “{0}” does not take an expected date — it already has a real one. Putting a guess beside a fact only makes someone choose between them. | `cashForecast.errors.EXPECTED_DATE_NOT_APPLICABLE` | `app/finance/cashForecastErrorCodes.ts` |
| `EXPENSE_ALREADY_REVERSED` | Expense already reversed | `expense.errors.EXPENSE_ALREADY_REVERSED` | `app/finance/expenseErrorCodes.ts` |
| `EXPENSE_ASSET_MISMATCH` | This expense capitalises asset {0}, but that order line bought asset {1} — one machine’s invoice cannot be capitalised against another machine’s order line. | `expense.errors.EXPENSE_ASSET_MISMATCH` | `app/finance/expenseErrorCodes.ts` |
| `EXPENSE_CLAIM_ACCOUNT_REQUIRED` | Approving {0} needs an account — the cost has to land somewhere, and guessing one is worse than asking. | `expenseClaims.errors.EXPENSE_CLAIM_ACCOUNT_REQUIRED` | `app/finance/claims/claimErrorCodes.ts` |
| `EXPENSE_CLAIM_AMOUNT_INVALID` | {0} is not an amount anyone can have spent. | `expenseClaims.errors.EXPENSE_CLAIM_AMOUNT_INVALID` | `app/finance/claims/claimErrorCodes.ts` |
| `EXPENSE_CLAIM_CURRENCY_UNKNOWN` | “{0}” is not a currency this system holds. | `expenseClaims.errors.EXPENSE_CLAIM_CURRENCY_UNKNOWN` | `app/finance/claims/claimErrorCodes.ts` |
| `EXPENSE_CLAIM_DESCRIPTION_REQUIRED` | Say what it was for. It is the only thing the approver has to judge by. | `expenseClaims.errors.EXPENSE_CLAIM_DESCRIPTION_REQUIRED` | `app/finance/claims/claimErrorCodes.ts` |
| `EXPENSE_CLAIM_NO_EVIDENCE` | Claim {0} has neither a receipt nor a reason there isn’t one. Approving it would be approving nothing in particular. | `expenseClaims.errors.EXPENSE_CLAIM_NO_EVIDENCE` | `app/finance/claims/claimErrorCodes.ts` |
| `EXPENSE_CLAIM_NOT_FOUND` | No expense claim with id {0}. | `expenseClaims.errors.EXPENSE_CLAIM_NOT_FOUND` | `app/finance/claims/claimErrorCodes.ts` |
| `EXPENSE_CLAIM_NOT_SUBMITTED` | Claim {0} is {1}, so there is nothing to decide or withdraw. | `expenseClaims.errors.EXPENSE_CLAIM_NOT_SUBMITTED` | `app/finance/claims/claimErrorCodes.ts` |
| `EXPENSE_CLAIM_REJECT_REASON_REQUIRED` | Rejecting {0} needs a reason — without one the claimant cannot tell whether to fix something and resubmit, or drop it. | `expenseClaims.errors.EXPENSE_CLAIM_REJECT_REASON_REQUIRED` | `app/finance/claims/claimErrorCodes.ts` |
| `EXPENSE_CLAIM_SELF_APPROVAL` | You submitted claim {0}, so you cannot be the one who approves it. | `expenseClaims.errors.EXPENSE_CLAIM_SELF_APPROVAL` | `app/finance/claims/claimErrorCodes.ts` |
| `EXPENSE_CLAIM_SPEND_DATE_FUTURE` | You cannot claim for {0} — that is in the future, and today is {1}. Money that has not been spent yet would be an advance, and there is no float here by decision. | `expenseClaims.errors.EXPENSE_CLAIM_SPEND_DATE_FUTURE` | `app/finance/claims/claimErrorCodes.ts` |
| `EXPENSE_CLAIM_SPEND_DATE_REQUIRED` | A claim needs the date the money was actually spent. There is deliberately no default — a date that decides which period a cost lands in is never filled in for you. | `expenseClaims.errors.EXPENSE_CLAIM_SPEND_DATE_REQUIRED` | `app/finance/claims/claimErrorCodes.ts` |
| `EXPENSE_CLAIM_TAX_CODE_REQUIRED` | Approving {0} needs a tax code. An employee has no default one, so somebody has to decide whether the input tax is claimable (TX) or blocked (BL) — that is a finance judgement, not something to default. | `expenseClaims.errors.EXPENSE_CLAIM_TAX_CODE_REQUIRED` | `app/finance/claims/claimErrorCodes.ts` |
| `EXPENSE_CREATES_ASSET` | Line {0} already names an existing asset card — this expense must be added to it (append mode: pass the asset id), not create a second card for the same machine. | `expense.errors.EXPENSE_CREATES_ASSET` | `app/finance/expenseErrorCodes.ts` |
| `EXPENSE_DATE_REQUIRED` | An expense date is required — it decides which accounting period the payment posts to. | `hr.errors.EXPENSE_DATE_REQUIRED` | `app/hr/hrErrorCodes.ts` |
| `EXPENSE_HAS_ASSET` | Expense {0} carries a fixed asset — dispose the asset first, or correct by manual journal | `expense.errors.EXPENSE_HAS_ASSET` | `app/finance/expenseErrorCodes.ts` |
| `EXPENSE_IS_REVERSAL_MIRROR` | Expense {0} is the record of a reversal, not a payable in its own right. | `purchasing.errors.EXPENSE_IS_REVERSAL_MIRROR` | `app/purchasing/purchasingErrorCodes.ts` |
| `EXPENSE_NOT_CAPITAL` | Line {0} orders a machine, so the expense paying for it must be capital expenditure — account 1500 with asset details. You sent account {1}. | `expense.errors.EXPENSE_NOT_CAPITAL` | `app/finance/expenseErrorCodes.ts` |
| `EXPENSE_NOT_FOUND` | Expense {0} does not exist. | `purchasing.errors.EXPENSE_NOT_FOUND` | `app/purchasing/purchasingErrorCodes.ts` |
| `EXPENSE_NOT_PAYABLE` | Expense {0} was already paid — that money left the bank at the time, so there is no payable for a deposit to settle. | `purchasing.errors.EXPENSE_NOT_PAYABLE` | `app/purchasing/purchasingErrorCodes.ts` |
| `EXPENSE_NOT_POSTED` | Expense {0} is {1}, so it carries no payable to settle. | `purchasing.errors.EXPENSE_NOT_POSTED` | `app/purchasing/purchasingErrorCodes.ts` |
| `EXPENSE_SUPPLIER_NOT_STATED` | An expense linked to purchase order {0} must name the supplier that issued the invoice | `expense.errors.EXPENSE_SUPPLIER_NOT_STATED` | `app/finance/expenseErrorCodes.ts` |
| `EXPORT_FREIGHT_CONTAINER_NOT_FOUND` | That container does not exist, or has been written off. A document pointing at it would carry a provenance nobody can follow back — leave the container blank instead. | `finance.freight.errors.EXPORT_FREIGHT_CONTAINER_NOT_FOUND` | `app/finance/freightErrorCodes.ts` |
| `EXPORT_FREIGHT_HAS_NO_ALLOCATIONS` | Export freight ({0}) is an expense and is never apportioned across batches, so it cannot have apportionment lines at all. | `finance.freight.errors.EXPORT_FREIGHT_HAS_NO_ALLOCATIONS` | `app/finance/freightErrorCodes.ts` |
| `FINAL_PERIOD_NOT_CLOSED` | The final month of the year ending {0} is not closed (lock at {1}) — close December first | `finance.errors.FINAL_PERIOD_NOT_CLOSED` | `app/finance/financeErrorCodes.ts` |
| `FORECAST_SUPERSEDE_REASON_REQUIRED` | Forecast {0} already covers the week of {1}. Re-freezing replaces it, so a reason is required — the earlier one stays on file, because it is what later weeks are measured against. | `cashForecast.errors.FORECAST_SUPERSEDE_REASON_REQUIRED` | `app/finance/cashForecastErrorCodes.ts` |
| `FORECAST_WEEK_START_NOT_MONDAY` | A forecast week starts on a Monday; {0} is not one. | `cashForecast.errors.FORECAST_WEEK_START_NOT_MONDAY` | `app/finance/cashForecastErrorCodes.ts` |
| `FORMULA_DIRECTION` | Formula {0} is a {1} formula and cannot be used to quote a sale — a purchase formula prices what we pay, not what we charge. | `output.sale.errors.FORMULA_DIRECTION` | `app/output/[id]/edit/saleErrorCodes.ts` |
| `FORMULA_INACTIVE` | Formula {0} is inactive | `pricing.errors.FORMULA_INACTIVE` | `app/tools/pricing/pricingErrorCodes.ts` |
| `FORMULA_NOT_FOUND` | Pricing formula not found | `pricing.errors.FORMULA_NOT_FOUND` | `app/tools/pricing/pricingErrorCodes.ts` |
| `FORWARDER_DETAILS_NOT_A_FORWARDER` | This company is not a forwarder, so logistics details cannot be attached to it. | `logistics.opErrors.FORWARDER_DETAILS_NOT_A_FORWARDER` | `app/logistics/logisticsErrorCodes.ts` |
| `FORWARDER_RATE_QUOTE_OVERLAP` | This forwarder already has a quote for that lane whose validity overlaps the dates you entered. Close or re-date the existing one first — two prices for the same day cannot be resolved. | `logistics.opErrors.FORWARDER_RATE_QUOTE_OVERLAP` | `app/logistics/logisticsErrorCodes.ts` |
| `FREIGHT_ALREADY_REVERSED` | {0} has already been reversed. | `finance.freight.errors.FREIGHT_ALREADY_REVERSED` | `app/finance/freightErrorCodes.ts` |
| `FREIGHT_AMOUNT_INVALID` | The amount must be greater than zero. | `finance.freight.errors.FREIGHT_AMOUNT_INVALID` | `app/finance/freightErrorCodes.ts` |
| `FREIGHT_BASIS_INVALID` | Unknown apportionment basis {0}. | `finance.freight.errors.FREIGHT_BASIS_INVALID` | `app/finance/freightErrorCodes.ts` |
| `FREIGHT_BASIS_ZERO` | The {0} basis totals zero across these batches — nothing to apportion by. | `finance.freight.errors.FREIGHT_BASIS_ZERO` | `app/finance/freightErrorCodes.ts` |
| `FREIGHT_BATCH_UNPRICED` | Batch {0} has no price yet, so a value-based split cannot include it. Price the batch, or use weight or stated amounts — a zero share would quietly push its freight onto the other batches. | `finance.freight.errors.FREIGHT_BATCH_UNPRICED` | `app/finance/freightErrorCodes.ts` |
| `FREIGHT_DATE_REQUIRED` | A document date is required — it decides the period and the FX rate. | `finance.freight.errors.FREIGHT_DATE_REQUIRED` | `app/finance/freightErrorCodes.ts` |
| `FREIGHT_DUPLICATE_BATCH` | The same batch was listed twice. | `finance.freight.errors.FREIGHT_DUPLICATE_BATCH` | `app/finance/freightErrorCodes.ts` |
| `FREIGHT_GST_NOT_CAPITALISABLE` | GST of {0} cannot be capitalised into inventory — import GST is recoverable input tax and belongs to the GST account. Record it separately. | `finance.freight.errors.FREIGHT_GST_NOT_CAPITALISABLE` | `app/finance/freightErrorCodes.ts` |
| `FREIGHT_HAS_SETTLEMENT` | {0} has already been paid against ({1} settled), so it cannot be reversed — reverse the payment first, then this document. | `finance.freight.errors.FREIGHT_HAS_SETTLEMENT` | `app/finance/freightErrorCodes.ts` |
| `FREIGHT_MIXED_UNITS` | These batches are measured in different units ({0}), so splitting by weight has no meaning. Use value or stated amounts. | `finance.freight.errors.FREIGHT_MIXED_UNITS` | `app/finance/freightErrorCodes.ts` |
| `FREIGHT_NO_BATCHES` | Pick at least one batch to apportion this freight to. | `finance.freight.errors.FREIGHT_NO_BATCHES` | `app/finance/freightErrorCodes.ts` |
| `FREIGHT_NOT_FOUND` | That freight document no longer exists. | `finance.freight.errors.FREIGHT_NOT_FOUND` | `app/finance/freightErrorCodes.ts` |
| `FREIGHT_PAYMENT_STATUS_INVALID` | Payment status must be paid or unpaid. | `finance.freight.errors.FREIGHT_PAYMENT_STATUS_INVALID` | `app/finance/freightErrorCodes.ts` |
| `FREIGHT_REVERSAL_REASON_REQUIRED` | Give a reason for reversing {0} — a reversal with no reason leaves nobody able to answer why, later. | `finance.freight.errors.FREIGHT_REVERSAL_REASON_REQUIRED` | `app/finance/freightErrorCodes.ts` |
| `FREIGHT_STATED_AMOUNT_INVALID` | Stated amount for batch {0} cannot be negative. | `finance.freight.errors.FREIGHT_STATED_AMOUNT_INVALID` | `app/finance/freightErrorCodes.ts` |
| `FREIGHT_STATED_AMOUNT_REQUIRED` | Stated basis: enter the amount for batch {0}. | `finance.freight.errors.FREIGHT_STATED_AMOUNT_REQUIRED` | `app/finance/freightErrorCodes.ts` |
| `FREIGHT_STATED_SUM_MISMATCH` | The stated amounts total {0}, but the document is {1}. They must match exactly — the invoice already answered the question. | `finance.freight.errors.FREIGHT_STATED_SUM_MISMATCH` | `app/finance/freightErrorCodes.ts` |
| `FREIGHT_STATUS_NO_DIRECT_UPDATE` | The status of {0} can only be changed by reversing it, which records the reason, who did it, and mirrors the journal entry back to zero. | `finance.freight.errors.FREIGHT_STATUS_NO_DIRECT_UPDATE` | `app/finance/freightErrorCodes.ts` |
| `FREIGHT_SUPPLIER_NOT_A_FORWARDER` | {0} is not a forwarder. Freight is always owed to a forwarder — booking it against a material supplier keeps the entry balanced while putting the money in the wrong person’s name. | `finance.freight.errors.FREIGHT_SUPPLIER_NOT_A_FORWARDER` | `app/finance/freightErrorCodes.ts` |
| `FREIGHT_SUPPLIER_REQUIRED` | Choose the forwarder. | `finance.freight.errors.FREIGHT_SUPPLIER_REQUIRED` | `app/finance/freightErrorCodes.ts` |
| `FX_CURRENCY_INVALID` | "{0}" is not a currency this system knows | `finance.fxPage.errors.FX_CURRENCY_INVALID` | `app/finance/fxErrorCodes.ts` |
| `FX_CURRENCY_IS_BASE` | {0} is the base currency — it has no rate against itself | `finance.fxPage.errors.FX_CURRENCY_IS_BASE` | `app/finance/fxErrorCodes.ts` |
| `FX_RATE_DATE_IN_FUTURE` | You cannot enter a rate for {0}: that day has not happened yet, so no bank has published a rate for it. Entering one would be inventing it. | `finance.fxPage.errors.FX_RATE_DATE_IN_FUTURE` | `app/finance/fxErrorCodes.ts` |
| `FX_RATE_DATE_REQUIRED` | A rate date is required — a rate is a fact about a particular day. | `finance.fxPage.errors.FX_RATE_DATE_REQUIRED` | `app/finance/fxErrorCodes.ts` |
| `FX_RATE_EXISTS` | A rate for {0} on {1} ({2}) already exists — it is {3}. This screen only fills gaps. To change an existing rate, open it and say why. | `finance.fxPage.errors.FX_RATE_EXISTS` | `app/finance/fxErrorCodes.ts` |
| `FX_RATE_HISTORY_IMMUTABLE` | Rate history cannot be edited or deleted. | `finance.fxPage.errors.FX_RATE_HISTORY_IMMUTABLE` | `app/finance/fxErrorCodes.ts` |
| `FX_RATE_INVALID` | FX rate must be greater than 0 (got {0}) | `hr.errors.FX_RATE_INVALID` | `app/hr/hrErrorCodes.ts` |
| `FX_RATE_MISSING` | No {0} board rate on file for {1} ({2}) — enter the day’s rate under Finance → FX first. | `purchasing.errors.FX_RATE_MISSING` | `app/purchasing/purchasingErrorCodes.ts` |
| `FX_RATE_NOT_ACCEPTED` | A manual rate is not accepted here — foreign amounts are valued at the day’s board rate automatically. | `purchasing.errors.FX_RATE_NOT_ACCEPTED` | `app/purchasing/purchasingErrorCodes.ts` |
| `FX_RATE_NOT_FOUND` | That rate no longer exists | `finance.fxPage.errors.FX_RATE_NOT_FOUND` | `app/finance/fxErrorCodes.ts` |
| `FX_RATE_REQUIRED` | Exchange rate required for {0} | `output.sale.errors.FX_RATE_REQUIRED` | `app/output/[id]/edit/saleErrorCodes.ts` |
| `FX_RATE_TYPE_INVALID` | "{0}" is not one of the three sides (buy, sell, mid) | `finance.fxPage.errors.FX_RATE_TYPE_INVALID` | `app/finance/fxErrorCodes.ts` |
| `FX_RATE_VIA_FUNCTION` | A rate cannot be changed or removed directly ({0}) — it must go through the recorded path, so the change leaves a trail. | `finance.fxPage.errors.FX_RATE_VIA_FUNCTION` | `app/finance/fxErrorCodes.ts` |
| `FX_REASON_REQUIRED` | Say why this rate is being withdrawn — a rate that vanishes without a reason cannot be explained later. | `finance.fxPage.errors.FX_REASON_REQUIRED` | `app/finance/fxErrorCodes.ts` |
| `GOAL_ID_REQUIRED` | Goal id is required | `reviews.errors.GOAL_ID_REQUIRED` | `app/hr/reviews/reviewErrorCodes.ts` |
| `GOAL_NOT_FOUND` | Goal not found | `reviews.errors.GOAL_NOT_FOUND` | `app/hr/reviews/reviewErrorCodes.ts` |
| `GOAL_NOT_IN_REVIEW` | That goal does not belong to this review | `reviews.errors.GOAL_NOT_IN_REVIEW` | `app/hr/reviews/reviewErrorCodes.ts` |
| `GOAL_RESULTS_NOT_ARRAY` | Goal results must be a list | `reviews.errors.GOAL_RESULTS_NOT_ARRAY` | `app/hr/reviews/reviewErrorCodes.ts` |
| `GOALS_REQUIRED` | At least one goal is required before submitting | `reviews.errors.GOALS_REQUIRED` | `app/hr/reviews/reviewErrorCodes.ts` |
| `GST_BOX_NOT_DRILLABLE` | Box {0} cannot be opened: it is a total of other boxes, or a declaration rather than a figure derived from the ledger. Open the boxes it is made of instead. | `finance.errors.GST_BOX_NOT_DRILLABLE` | `app/finance/financeErrorCodes.ts` |
| `GST_BOX_REQUIRED` | Which box do you want to open? | `finance.errors.GST_BOX_REQUIRED` | `app/finance/financeErrorCodes.ts` |
| `GST_CANNOT_CORRECT_UNFILED` | GST period {0} has not been filed, so there is nothing to correct. Edit it instead. | `finance.errors.GST_CANNOT_CORRECT_UNFILED` | `app/finance/financeErrorCodes.ts` |
| `GST_CANNOT_DISABLE_WITH_CODED_EXPENSES` | GST cannot be switched off while {0} expense(s) still carry a tax code: {1}. Reversing one copies its tax code onto the reversing entry, and an unregistered company cannot write a tax code anywhere — so once GST is off those expenses can never be reversed. Reverse them first, while GST is still on, then switch off. | `finance.errors.GST_CANNOT_DISABLE_WITH_CODED_EXPENSES` | `app/finance/financeErrorCodes.ts` |
| `GST_CANNOT_DISABLE_WITH_TAXED_INVOICES` | GST cannot be switched off while {0} live invoice(s) carry tax: {1}. These can still be voided — that is not the problem. The problem is the state it leaves: the return would report supplies for a quarter in which the company says it was not registered. Void them first, or leave GST on. | `finance.errors.GST_CANNOT_DISABLE_WITH_TAXED_INVOICES` | `app/finance/financeErrorCodes.ts` |
| `GST_CORRECTION_REASON_REQUIRED` | A reason is required to raise a correction — a correction with no stated reason cannot be defended later. | `finance.errors.GST_CORRECTION_REASON_REQUIRED` | `app/finance/financeErrorCodes.ts` |
| `GST_FILED_DATE_REQUIRED` | The date the return was actually filed is required for period {0} — this system records what was filed, it does not submit it. | `finance.errors.GST_FILED_DATE_REQUIRED` | `app/finance/financeErrorCodes.ts` |
| `GST_NOT_REGISTERED` | A tax code ({0}) was given, but this company is not registered for GST. While it is unregistered the system behaves exactly as it did before GST was built — a tagged line cannot be written at all. | `finance.errors.GST_NOT_REGISTERED` | `app/finance/financeErrorCodes.ts` |
| `GST_PERIOD_ALREADY_FILED` | GST period {0} was already filed on {1}. A filed return is a record of what was filed and is never edited — to change it, raise a correction. | `finance.errors.GST_PERIOD_ALREADY_FILED` | `app/finance/financeErrorCodes.ts` |
| `GST_PERIOD_DATES_REQUIRED` | A start and end date are required for a GST period. | `finance.errors.GST_PERIOD_DATES_REQUIRED` | `app/finance/financeErrorCodes.ts` |
| `GST_PERIOD_EXISTS` | A GST period already starts on {0}. | `finance.errors.GST_PERIOD_EXISTS` | `app/finance/financeErrorCodes.ts` |
| `GST_PERIOD_NOT_A_QUARTER` | A GST period must be a whole calendar quarter. {0} to {1} is not one. | `finance.errors.GST_PERIOD_NOT_A_QUARTER` | `app/finance/financeErrorCodes.ts` |
| `GST_PERIOD_NOT_FOUND` | No GST period with id {0}. | `finance.errors.GST_PERIOD_NOT_FOUND` | `app/finance/financeErrorCodes.ts` |
| `GST_PERIOD_NOT_LOCKED` | GST period {0} ends on {1}, but the books are only closed up to {2}. A filed return whose underlying entries can still change is not a record of anything — close every month in the quarter first. | `finance.errors.GST_PERIOD_NOT_LOCKED` | `app/finance/financeErrorCodes.ts` |
| `GST_PERIOD_WINDOW_INVALID` | The period end ({1}) is before its start ({0}). | `finance.errors.GST_PERIOD_WINDOW_INVALID` | `app/finance/financeErrorCodes.ts` |
| `GST_REGISTRATION_NO_REQUIRED` | A GST registration number is required before registration can be switched on. IRAS requires it on a tax invoice, and the invoice PDF prints that line only when the number is on file — with it blank, an invoice carrying 9% GST would go to the customer with no registration number on it at all. It is free text: enter it here and switch on in the same action. | `finance.errors.GST_REGISTRATION_NO_REQUIRED` | `app/finance/financeErrorCodes.ts` |
| `GST_RETURN_IMMUTABLE` | Box {0} belongs to a return that has been filed. What was filed does not change when the underlying data does — a correction is a new return, not an edit. | `finance.errors.GST_RETURN_IMMUTABLE` | `app/finance/financeErrorCodes.ts` |
| `GST_UNALLOCATED_RECEIPT_UNSUPPORTED` | This receipt of {0} {1} is not allocated to any document. Singapore’s time of supply is the earlier of invoice or payment, so money received before an invoice is itself a tax point — and at this moment nothing says which supply it relates to, so no tax code, rate or box can be resolved. Raise the invoice first, then allocate the receipt to it. Nothing was saved. | `finance.errors.GST_UNALLOCATED_RECEIPT_UNSUPPORTED` | `app/finance/financeErrorCodes.ts` |
| `HANDOVER_ACK_NO_EMPLOYEE` | An acknowledgement has to land on an employee, and this login has no employee record. Acknowledging is something a person does, not something an account does. | `processing.errors.HANDOVER_ACK_NO_EMPLOYEE` | `app/operation/errorCodes.ts` |
| `HANDOVER_ACK_NOT_INCOMING` | Only the incoming person named on this handover can acknowledge it. If someone else signs, the field is just a timestamp, and the question it exists to answer — did the next shift actually read this? — has no answer. If the incoming person changed, change the handover first. | `processing.errors.HANDOVER_ACK_NOT_INCOMING` | `app/operation/errorCodes.ts` |
| `HANDOVER_ALREADY_ACKNOWLEDGED` | This handover was already acknowledged at {0}. Acknowledgement is not a repeatable action — overwriting it would erase who signed first and when. | `processing.errors.HANDOVER_ALREADY_ACKNOWLEDGED` | `app/operation/errorCodes.ts` |
| `HANDOVER_DATE_REQUIRED` | A handover must say which day it happened on. | `processing.errors.HANDOVER_DATE_REQUIRED` | `app/operation/errorCodes.ts` |
| `HANDOVER_EMPLOYEE_NOT_FOUND` | A named employee is not on file. | `processing.errors.HANDOVER_EMPLOYEE_NOT_FOUND` | `app/operation/errorCodes.ts` |
| `HANDOVER_ITEM_BODY_REQUIRED` | An empty handover item is the same as no item at all, yet it would pass for "filled in" in any count. | `processing.errors.HANDOVER_ITEM_BODY_REQUIRED` | `app/operation/errorCodes.ts` |
| `HANDOVER_ITEM_TYPE_UNKNOWN` | Unknown or inactive handover item type "{0}". | `processing.errors.HANDOVER_ITEM_TYPE_UNKNOWN` | `app/operation/errorCodes.ts` |
| `HANDOVER_NOT_FOUND` | That handover does not exist. | `processing.errors.HANDOVER_NOT_FOUND` | `app/operation/errorCodes.ts` |
| `HANDOVER_PEOPLE_REQUIRED` | Both the outgoing and the incoming person must be named — a handover that cannot say who handed to whom passes no responsibility to anyone. | `processing.errors.HANDOVER_PEOPLE_REQUIRED` | `app/operation/errorCodes.ts` |
| `HANDOVER_REQUIRED_ITEM_MISSING` | "{0}" is a required kind of handover content, and this handover has none of it. | `processing.errors.HANDOVER_REQUIRED_ITEM_MISSING` | `app/operation/errorCodes.ts` |
| `HANDOVER_SAME_PERSON` | The outgoing and incoming person are the same — such a "handover" passes nothing to anyone. | `processing.errors.HANDOVER_SAME_PERSON` | `app/operation/errorCodes.ts` |
| `HANDOVER_SHIFT_REQUIRED` | A handover must say which shift it is for. | `processing.errors.HANDOVER_SHIFT_REQUIRED` | `app/operation/errorCodes.ts` |
| `HANDOVER_SHIFT_UNKNOWN` | Unknown or inactive shift "{0}". | `processing.errors.HANDOVER_SHIFT_UNKNOWN` | `app/operation/errorCodes.ts` |
| `IMPORT_CODE_ALREADY_EXISTS` | These codes already exist in the system: {detail}. The whole file is refused rather than skipping them — "already there" and "deliberately left alone" must not look the same, and updating them would be a merge, which has not been decided. | `import.errors.IMPORT_CODE_ALREADY_EXISTS` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_CODE_DUPLICATED_IN_FILE` | The file uses the same code more than once: {detail}. Every row needs its own code. | `import.errors.IMPORT_CODE_DUPLICATED_IN_FILE` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_CODE_NUMBER_TOO_HIGH` | These codes number above 9999: {detail}. Materials, suppliers and customers use a four-digit code, and importing a higher number would push the automatic numbering past what that format can hold — the next code the app generated would be silently truncated and then collide. Renumber below 9999, or raise the code width first (that is a separate change, because it alters the shape of every existing code). | `import.errors.IMPORT_CODE_NUMBER_TOO_HIGH` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_CODE_REQUIRED` | Row {row}: the code column is empty. Codes come from the file so that a re-run can be recognised and legacy identifiers are kept. | `import.errors.IMPORT_CODE_REQUIRED` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_COLUMN_FORBIDDEN` | Row {row}: the column "{column}" can never be imported — it is set by the database or governed by its own rule. | `import.errors.IMPORT_COLUMN_FORBIDDEN` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_COLUMN_UNKNOWN` | Row {row}: the column "{column}" does not exist on this table. It was not silently ignored — check the template header. | `import.errors.IMPORT_COLUMN_UNKNOWN` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_CSV_UNPARSEABLE` | The file could not be read as CSV. {detail} | `import.errors.IMPORT_CSV_UNPARSEABLE` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_EMPLOYEE_CODE_SHAPE` | Row {row}: "{detail}" starts like a system employee code (EMP-year-) but does not end in digits. That shape breaks the next automatic code. Use a different prefix for legacy codes. | `import.errors.IMPORT_EMPLOYEE_CODE_SHAPE` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_FILE_EMPTY` | The file has no data rows. That is not the same as a file that failed to parse — this one was read successfully and contained nothing. | `import.errors.IMPORT_FILE_EMPTY` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_NEAR_DUPLICATE_NOT_ACKNOWLEDGED` | Some names look like companies already on file. Read the list and tick the acknowledgement before committing. | `import.errors.IMPORT_NEAR_DUPLICATE_NOT_ACKNOWLEDGED` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_NO_FILE` | No file was chosen. | `import.errors.IMPORT_NO_FILE` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_NOT_CSV` | That is not a .csv file ({detail}). Export as CSV from your spreadsheet first. | `import.errors.IMPORT_NOT_CSV` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_NOT_PERMITTED` | You do not have permission to import master data. | `import.errors.IMPORT_NOT_PERMITTED` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_REFERENCE_NOT_FOUND` | Row {row}, column {column}: "{detail}" does not match anything on file. References are given by code, not by id — load the table it points at first. | `import.errors.IMPORT_REFERENCE_NOT_FOUND` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_ROW_BAD_SYNTAX` | Row {row}: a value is not in the shape this column expects — most often a date that is not YYYY-MM-DD, or a number with a stray character. {detail} | `import.errors.IMPORT_ROW_BAD_SYNTAX` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_ROW_CHECK` | Row {row}: a value in this row is not one the column accepts ({column}). The template’s third line lists the accepted values for every restricted column. | `import.errors.IMPORT_ROW_CHECK` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_ROW_EMPTY` | Row {row} has no usable columns. | `import.errors.IMPORT_ROW_EMPTY` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_ROW_FK` | Row {row}, column {column}: this value points at something that is not on file. References are given by code — load the table it points at first. | `import.errors.IMPORT_ROW_FK` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_ROW_GENERATED` | Row {row}, column {column}: the database calculates this column itself and refuses a supplied value. Delete the column from your file — a current template does not contain it. | `import.errors.IMPORT_ROW_GENERATED` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_ROW_NOT_NULL` | Row {row}, column {column}: this column cannot be left blank — the database requires a value and there is no default. Fill it in, or remove the column from the file if it does not apply. | `import.errors.IMPORT_ROW_NOT_NULL` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_ROW_NUMERIC_RANGE` | Row {row}: a number is outside the range this column allows. {detail} | `import.errors.IMPORT_ROW_NUMERIC_RANGE` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_ROW_REFUSED` | Row {row}: this row was refused, and the column involved is {column}. The database’s own words, quoted: "{detail}" — that wording is not our message; if it is unclear, report it and it will get a sentence. | `import.errors.IMPORT_ROW_REFUSED` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_ROW_TOO_LONG` | Row {row}: a value is longer than the column allows. {detail} | `import.errors.IMPORT_ROW_TOO_LONG` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_ROW_UNIQUE` | Row {row}: this row duplicates one already on file ({column}). Nothing was written. | `import.errors.IMPORT_ROW_UNIQUE` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_ROWS_NOT_AN_ARRAY` | The file could not be turned into rows. {detail} | `import.errors.IMPORT_ROWS_NOT_AN_ARRAY` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_TABLE_NOT_IMPORTABLE` | That table cannot be imported into. Only the six master-data tables in the picker are importable. | `import.errors.IMPORT_TABLE_NOT_IMPORTABLE` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_TAX_ID_REQUIRED` | Row {row}: a registration number is required when importing a counterparty. It is what identifies a company here; the name is only a hint. (Rows already in the system are not affected by this rule.) | `import.errors.IMPORT_TAX_ID_REQUIRED` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_TEMPLATE_EMPTY` | The template came back with no columns. That is not an empty table — something is wrong with the template source. Please report it rather than filling a file by hand. | `import.errors.IMPORT_TEMPLATE_EMPTY` | `app/settings/import/importErrorCodes.ts` |
| `IMPORT_TEMPLATE_UNAVAILABLE` | The template could not be produced just now — the database could not be reached. This does NOT mean the table cannot be imported; try again shortly. | `import.errors.IMPORT_TEMPLATE_UNAVAILABLE` | `app/settings/import/importErrorCodes.ts` |
| `IN_SERVICE_BEFORE_ACQUISITION` | An in-service date of {0} is before the asset was acquired ({1}). | `finance.errors.IN_SERVICE_BEFORE_ACQUISITION` | `app/finance/paymentErrorCodes.ts` |
| `INBOUND_CONDITION_NOT_APPLICABLE` | A {1} has no safety state and no chemistry certainty. To record those, change the material's kind first. | `materials.errors.INBOUND_CONDITION_NOT_APPLICABLE` | `app/materials/materialErrorCodes.ts` |
| `INBOUND_NOT_FOUND` | Inbound batch {0} does not exist. | `materials.errors.INBOUND_NOT_FOUND` | `app/materials/materialErrorCodes.ts` |
| `INBOUND_UNPRICED` | Batch {0} has not been priced yet | `purchasing.errors.INBOUND_UNPRICED` | `app/purchasing/purchasingErrorCodes.ts` |
| `INDEX_CURRENCY_NOT_STATED` | Index {0} has no quote currency on record, so nothing can be priced against it yet. State the currency under Pricing → Metal prices — the figures are not assumed to be US dollars. | `pricing.errors.INDEX_CURRENCY_NOT_STATED` | `app/tools/pricing/pricingErrorCodes.ts` |
| `INPUT_CHEMISTRY_NOT_FEEDABLE` | Batch {0} has its chemistry certainty recorded as "{2}", which may not be fed. Either change it at Inbound → open that batch → "Condition on arrival", or wait for the assay that settles what this load actually is. | `processing.errors.INPUT_CHEMISTRY_NOT_FEEDABLE` | `app/operation/errorCodes.ts` |
| `INPUT_QTY_INVALID` | Input quantity must be greater than 0 | `processing.errors.INPUT_QTY_INVALID` | `app/operation/errorCodes.ts` |
| `INPUT_SAFETY_STATE_NOT_ACCEPTED` | {1} does not accept the safety states batch {0} is carrying: {3}. This is NOT the same sentence as "may not be fed" — another operation may well accept it: charged material goes through Deep discharge first, and packs that cannot be discharged go to the Battery processing line. | `processing.errors.INPUT_SAFETY_STATE_NOT_ACCEPTED` | `app/operation/errorCodes.ts` |
| `INPUT_SAFETY_STATE_NOT_FEEDABLE` | Batch {0} carries safety states that may not be fed: {2}. Every one of them has to be cleared — a load that is discharged AND water-exposed is still water-exposed, and discharge does not cancel water. Change them at Inbound → open that batch → "Condition on arrival". | `processing.errors.INPUT_SAFETY_STATE_NOT_FEEDABLE` | `app/operation/errorCodes.ts` |
| `INPUT_SAFETY_STATE_NOT_RECORDED` | Batch {0} has NO recorded safety state. That means NOBODY HAS RECORDED ONE — it does not mean the load is safe. Record it at Inbound → open that batch → "Condition on arrival", then commit the run again. | `processing.errors.INPUT_SAFETY_STATE_NOT_RECORDED` | `app/operation/errorCodes.ts` |
| `INTERVAL_NOTHING_STATED` | State an interval in kilograms, in days, or both — at least one is required. | `equipment.errors.INTERVAL_NOTHING_STATED` | `app/finance/assets/equipmentErrorCodes.ts` |
| `INV_NO_LINES` | Invoice {0} has no lines — issuing it would send the customer a blank page to pay against. | `invoice.errors.INV_NO_LINES` | `app/finance/invoiceErrorCodes.ts` |
| `INV_PROFILE_INCOMPLETE` | Your company details are not filled in yet, so this invoice has no letterhead. Fill them in at /finance/company before issuing — a recorded version without a company name makes the record itself untrue. | `invoice.errors.INV_PROFILE_INCOMPLETE` | `app/finance/invoiceErrorCodes.ts` |
| `INV_VOIDED_NOT_ISSUABLE` | Invoice {0} is {1} — a voided invoice cannot be issued again. The versions already issued stay on file and remain downloadable; corrections after voiding go through a new invoice or a credit note. | `invoice.errors.INV_VOIDED_NOT_ISSUABLE` | `app/finance/invoiceErrorCodes.ts` |
| `INVALID_BASIS` | Invalid allocation basis: {0} | `processing.errors.INVALID_BASIS` | `app/operation/errorCodes.ts` |
| `INVOICE_ALREADY_VOID` | Invoice {0} is already void | `invoice.errors.INVOICE_ALREADY_VOID` | `app/finance/invoiceErrorCodes.ts` |
| `INVOICE_DATE_REQUIRED` | The issue date is required — it decides which accounting period the posting lands in, and it is never filled in for you. Nothing was saved. | `invoice.errors.INVOICE_DATE_REQUIRED` | `app/finance/invoiceErrorCodes.ts` |
| `INVOICE_HAS_SETTLEMENTS` | Invoice {0} has {1} live settlement(s) against it. Reverse the receipt first (Finance → Payments → Reverse), then void — the other order leaves live allocations pointing at a voided document. | `invoice.errors.INVOICE_HAS_SETTLEMENTS` | `app/finance/invoiceErrorCodes.ts` |
| `INVOICE_IMMUTABLE` | An issued invoice cannot be edited — void it and reissue | `invoice.errors.INVOICE_IMMUTABLE` | `app/finance/invoiceErrorCodes.ts` |
| `INVOICE_LINE_KIND_MISMATCH` | An invoice line must match its header: a {0}-kind invoice takes the other line source. Nothing was saved. | `invoice.errors.INVOICE_LINE_KIND_MISMATCH` | `app/finance/invoiceErrorCodes.ts` |
| `INVOICE_NOT_FOUND` | Invoice not found | `invoice.errors.INVOICE_NOT_FOUND` | `app/finance/invoiceErrorCodes.ts` |
| `INVOICE_SHIPPED_NOT_VOIDABLE` | Invoice {0} has already had goods shipped against it — the liability it posted is partly released, so a clean reversal no longer exists. Corrections after shipment go through a credit note. | `invoice.errors.INVOICE_SHIPPED_NOT_VOIDABLE` | `app/finance/invoiceErrorCodes.ts` |
| `IOD_CLASS_EXCLUDED` | Location {0} is configured to hold specific material classes, and {1} is not one of them — so nothing was saved. Pick another location, add {1} to that location under Inventory → Storage Locations, or correct this material's classification in the material dictionary. | `stock.errors.IOD_CLASS_EXCLUDED` | `app/components/inventory/stockErrorCodes.ts` |
| `IOD_CLASS_UNCONFIGURED_LOCATION` | Saved. Note: nobody has configured which material classes location {0} may hold, so nothing could be checked. Set its allowed classes under Inventory → Storage Locations to make this check mean something. | `stock.warnings.IOD_CLASS_UNCONFIGURED_LOCATION` | `app/components/inventory/stockErrorCodes.ts` |
| `IOD_CONSUME_EXCEEDS_AVAILABLE` | Cannot consume {0} — only {1} is available. {2} is on hold and cannot be processed until released. | `stock.errors.IOD_CONSUME_EXCEEDS_AVAILABLE` | `app/components/inventory/stockErrorCodes.ts` |
| `IOD_DRAIN_INSUFFICIENT` | Only {1} of the {0} requested could be drawn from stock. Nothing was written — reload the page and try again. | `stock.errors.IOD_DRAIN_INSUFFICIENT` | `app/components/inventory/stockErrorCodes.ts` |
| `IOD_MATERIAL_UNCLASSIFIED` | Saved. Note: material {0} has no waste classification, so it could not be checked against this location. Classify it in the material dictionary — unclassified is not the same as unrestricted; it means nobody has decided yet. | `stock.warnings.IOD_MATERIAL_UNCLASSIFIED` | `app/components/inventory/stockErrorCodes.ts` |
| `IOD_RECEIPT_LOCATION_INACTIVE` | Location {0} has been deactivated, so stock cannot be received into it. Pick another location, or leave it unspecified and assign one later by transfer. | `stock.errors.IOD_RECEIPT_LOCATION_INACTIVE` | `app/components/inventory/stockErrorCodes.ts` |
| `IOD_RECEIPT_LOCATION_UNKNOWN` | That storage location no longer exists. Reload the form and pick again, or leave it unspecified and assign one later by transfer. | `stock.errors.IOD_RECEIPT_LOCATION_UNKNOWN` | `app/components/inventory/stockErrorCodes.ts` |
| `IOD_RESTORE_MISMATCH` | Rollback could not restore exactly what was consumed ({0} expected, {1} mirrored). Nothing was changed. | `stock.errors.IOD_RESTORE_MISMATCH` | `app/components/inventory/stockErrorCodes.ts` |
| `IOD_SALE_EXCEEDS_AVAILABLE` | Cannot sell {0} — only {1} is available. {2} is on hold, and {3} is committed to a sales order. Held stock becomes sellable when released (Release, on the stock panel above); committed stock when the order that reserved it releases it or ships. | `stock.errors.IOD_SALE_EXCEEDS_AVAILABLE` | `app/components/inventory/stockErrorCodes.ts` |
| `IOD_TRANSFER_EXCEEDS_BUCKET` | Cannot move {0} — only {1} is in this bucket. A transfer moves stock that is already there; it does not create any. | `stock.errors.IOD_TRANSFER_EXCEEDS_BUCKET` | `app/components/inventory/stockErrorCodes.ts` |
| `IOD_TRANSFER_SAME_LOCATION` | Source and destination are the same location — nothing would move. Pick a different destination. | `stock.errors.IOD_TRANSFER_SAME_LOCATION` | `app/components/inventory/stockErrorCodes.ts` |
| `IOD_TRANSFER_TO_INACTIVE` | That destination location is not active, so stock cannot be moved into it. Reactivate it under Inventory → Storage Locations, or pick another. | `stock.errors.IOD_TRANSFER_TO_INACTIVE` | `app/components/inventory/stockErrorCodes.ts` |
| `JE_ALREADY_REVERSED` | Entry already reversed | `finance.errors.JE_ALREADY_REVERSED` | `app/finance/financeErrorCodes.ts` |
| `JE_LINE_INVALID` | A required field is missing or invalid: {0} | `expense.errors.JE_LINE_INVALID` | `app/finance/expenseErrorCodes.ts` |
| `JE_NOT_FOUND` | Entry not found | `finance.errors.JE_NOT_FOUND` | `app/finance/financeErrorCodes.ts` |
| `JL_ALREADY_MATCHED` | That journal line is already matched to another statement line | `bank.errors.JL_ALREADY_MATCHED` | `app/finance/bankErrorCodes.ts` |
| `JL_ENTRY_REVERSED` | That journal entry has been reversed | `bank.errors.JL_ENTRY_REVERSED` | `app/finance/bankErrorCodes.ts` |
| `JL_NOT_FOUND` | Journal line not found | `bank.errors.JL_NOT_FOUND` | `app/finance/bankErrorCodes.ts` |
| `JL_WRONG_ACCOUNT` | That journal line does not belong to this bank account | `bank.errors.JL_WRONG_ACCOUNT` | `app/finance/bankErrorCodes.ts` |
| `JL_WRONG_CURRENCY` | That journal line is in {1}, not the statement currency | `bank.errors.JL_WRONG_CURRENCY` | `app/finance/bankErrorCodes.ts` |
| `JL_WRONG_DIRECTION` | That journal line runs the opposite way to this statement line | `bank.errors.JL_WRONG_DIRECTION` | `app/finance/bankErrorCodes.ts` |
| `JOURNAL_UNBALANCED` | Entry does not balance ({1} vs {2}) | `finance.errors.JOURNAL_UNBALANCED` | `app/finance/financeErrorCodes.ts` |
| `LATER_YEAR_CLOSED` | A later year is still closed — reopen years newest-first (requested {0}) | `finance.errors.LATER_YEAR_CLOSED` | `app/finance/financeErrorCodes.ts` |
| `LICENCE_AUTH_UNAVAILABLE` | The sign-in service could not be reached, so this was not saved. This does NOT mean you are signed out — the system could not tell. | `company.licence.errors.LICENCE_AUTH_UNAVAILABLE` | `app/purchasing/licences/licenceErrorCodes.ts` |
| `LICENCE_KIND_REQUIRED` | Choose the licence kind. It is what tells the rest of the system how to treat this record, including when to warn that it is about to expire. | `company.licence.errors.LICENCE_KIND_REQUIRED` | `app/purchasing/licences/licenceErrorCodes.ts` |
| `LICENCE_NOT_PERMITTED` | You do not have permission to change compliance records. Viewing them needs supplier access; changing them needs supplier edit rights. | `company.licence.errors.LICENCE_NOT_PERMITTED` | `app/purchasing/licences/licenceErrorCodes.ts` |
| `LICENCE_STATUS_INVALID` | A licence standing must be active, suspended or revoked. Expiry is NOT one of them — it is derived from the validity dates, so storing it here would be a second copy of the same fact. | `company.licence.errors.LICENCE_STATUS_INVALID` | `app/purchasing/licences/licenceErrorCodes.ts` |
| `LICENCE_STORAGE_LIMIT_INVALID` | The approved storage limit must be greater than zero. Leave it blank if no limit has been recorded — blank and zero are different answers. | `company.licence.errors.LICENCE_STORAGE_LIMIT_INVALID` | `app/purchasing/licences/licenceErrorCodes.ts` |
| `LINE_AMOUNT_INVALID` | Line {0}: invalid amount | `bank.errors.LINE_AMOUNT_INVALID` | `app/finance/bankErrorCodes.ts` |
| `LINE_DATE_OUT_OF_RANGE` | Line {0}: date {1} is outside the statement period | `bank.errors.LINE_DATE_OUT_OF_RANGE` | `app/finance/bankErrorCodes.ts` |
| `LINE_NOT_BALANCED` | Employee {0}: net pay should be {1} but the file says {2} | `hr.errors.LINE_NOT_BALANCED` | `app/hr/hrErrorCodes.ts` |
| `LINE_NOT_FOUND` | Statement line not found | `bank.errors.LINE_NOT_FOUND` | `app/finance/bankErrorCodes.ts` |
| `LINE_NOT_IGNORED` | This line is not ignored (it is {0}) | `bank.errors.LINE_NOT_IGNORED` | `app/finance/bankErrorCodes.ts` |
| `LINE_NOT_MATCHED` | This line is not matched (it is {0}) | `bank.errors.LINE_NOT_MATCHED` | `app/finance/bankErrorCodes.ts` |
| `LINE_NOT_UNMATCHED` | This line is no longer unmatched (it is {0}) | `bank.errors.LINE_NOT_UNMATCHED` | `app/finance/bankErrorCodes.ts` |
| `LINE_QTY_INVALID` | Line {0}: quantity must be greater than 0 | `purchasing.errors.LINE_QTY_INVALID` | `app/purchasing/purchasingErrorCodes.ts` |
| `LINES_OUTSTANDING` | {0} line(s) still need matching or ignoring | `bank.errors.LINES_OUTSTANDING` | `app/finance/bankErrorCodes.ts` |
| `LOC_CODE_EXISTS` | Location code {0} is already in use. Codes identify a physical place, so two locations cannot share one — pick another code, or reactivate the existing location instead. | `locations.errors.LOC_CODE_EXISTS` | `app/inventory/locations/locationErrorCodes.ts` |
| `LOCATION_NO_HARD_DELETE` | Location {0} cannot be deleted. Stock movements refer to it by name, so deleting it would leave that history pointing at nothing — deactivate it instead, which stops it being offered on new documents while leaving the history intact. | `locations.errors.LOCATION_NO_HARD_DELETE` | `app/inventory/locations/locationErrorCodes.ts` |
| `LOSS_CATEGORIES_EXCEED_LOSS_QTY` | Run {0} has categorised losses totalling {1}, which exceeds its loss total of {2}. The two need NOT be equal (leaving part unexplained is normal), but the categories may not exceed the total. | `processing.loss.errors.LOSS_CATEGORIES_EXCEED_LOSS_QTY` | `app/operation/processing/[id]/lossErrorCodes.ts` |
| `LOSS_NEGATIVE` | Loss cannot be negative | `processing.errors.LOSS_NEGATIVE` | `app/operation/errorCodes.ts` |
| `MAINT_DATE_REQUIRED` | Enter the date the work was done. It is never filled in for you — a date quietly set to today would push the whole service schedule back with nothing to show for it. | `equipment.errors.MAINT_DATE_REQUIRED` | `app/finance/assets/equipmentErrorCodes.ts` |
| `MAINT_DESCRIPTION_REQUIRED` | Say what was done. | `equipment.errors.MAINT_DESCRIPTION_REQUIRED` | `app/finance/assets/equipmentErrorCodes.ts` |
| `MAINT_PERFORMER_REQUIRED` | Say who did this work — an employee, a supplier, or a name you type. | `equipment.errors.MAINT_PERFORMER_REQUIRED` | `app/finance/assets/equipmentErrorCodes.ts` |
| `MAINT_REASON_REQUIRED` | Capitalising needs a reason — say what was extended or improved. | `equipment.errors.MAINT_REASON_REQUIRED` | `app/finance/assets/equipmentErrorCodes.ts` |
| `MAINTENANCE_ALREADY_CAPITALISED` | Maintenance record {0} has already been capitalised, by expense {1}. One overhaul is capitalised once. | `equipment.errors.MAINTENANCE_ALREADY_CAPITALISED` | `app/finance/assets/equipmentErrorCodes.ts` |
| `MAINTENANCE_ASSET_MISMATCH` | That maintenance record ({1}) belongs to a different machine, not {0}. | `equipment.errors.MAINTENANCE_ASSET_MISMATCH` | `app/finance/assets/equipmentErrorCodes.ts` |
| `MAINTENANCE_NOT_APPLICABLE` | Machine {0} is not in service yet, so cost goes straight onto it — no maintenance record is needed. (Passing one would have had no effect, so it is refused rather than ignored.) | `equipment.errors.MAINTENANCE_NOT_APPLICABLE` | `app/finance/assets/equipmentErrorCodes.ts` |
| `MAINTENANCE_NOT_CAPITALISED` | Maintenance record {0} has not been marked as capitalised. Mark it capitalised on the machine’s page, with the reason, before capitalising against it — the reason is what makes this a judgement on record rather than a number that appeared. | `equipment.errors.MAINTENANCE_NOT_CAPITALISED` | `app/finance/assets/equipmentErrorCodes.ts` |
| `MAINTENANCE_NOT_FOUND` | No such maintenance record ({0}). | `equipment.errors.MAINTENANCE_NOT_FOUND` | `app/finance/assets/equipmentErrorCodes.ts` |
| `MANAGER_CYCLE` | An employee cannot report to themselves, directly or indirectly | `hr.errors.MANAGER_CYCLE` | `app/hr/hrErrorCodes.ts` |
| `MATCH_AMOUNT_MISMATCH` | The statement line is {0} but the selected journal lines total {1} | `bank.errors.MATCH_AMOUNT_MISMATCH` | `app/finance/bankErrorCodes.ts` |
| `MATERIAL_CONDITION_AXES_REQUIRED` | This kind of material must state its form and its source. Neither is ever filled in for you. | `materials.errors.MATERIAL_CONDITION_AXES_REQUIRED` | `app/materials/materialErrorCodes.ts` |
| `MATERIAL_KIND_HAS_NO_CONDITION_AXES` | A {0} has no form, source or size format. To record those, change its kind first. | `materials.errors.MATERIAL_KIND_HAS_NO_CONDITION_AXES` | `app/materials/materialErrorCodes.ts` |
| `MATERIAL_KIND_NOT_FOUND` | Kind "{0}" does not exist. | `materials.errors.MATERIAL_KIND_NOT_FOUND` | `app/materials/materialErrorCodes.ts` |
| `MATERIAL_KIND_NOT_PROCESSABLE` | A {1} can never be fed to a processing run. Change the kind, or change that kind's own rule. | `materials.errors.MATERIAL_KIND_NOT_PROCESSABLE` | `app/materials/materialErrorCodes.ts` |
| `MATERIAL_NOT_FOUND` | That material does not exist (or has been deleted): {0} | `materials.assayPolicy.errors.MATERIAL_NOT_FOUND` | `app/materials/materialPolicyErrorCodes.ts` |
| `MATERIAL_REQUIRED` | No material was given. | `materials.assayPolicy.errors.MATERIAL_REQUIRED` | `app/materials/materialPolicyErrorCodes.ts` |
| `MATERIAL_SIZE_FORMAT_NOT_APPLICABLE` | A {0} needs no dismantling, so there is no application it came from. Leave the size format empty. | `materials.errors.MATERIAL_SIZE_FORMAT_NOT_APPLICABLE` | `app/materials/materialErrorCodes.ts` |
| `MATERIAL_SIZE_FORMAT_REQUIRED` | A {0} needs dismantling, so it must say which application it came from - that is what decides the effort. | `materials.errors.MATERIAL_SIZE_FORMAT_REQUIRED` | `app/materials/materialErrorCodes.ts` |
| `METAL_DUPLICATED` | The same metal was listed twice: {0} | `materials.assayPolicy.errors.METAL_DUPLICATED` | `app/materials/materialPolicyErrorCodes.ts` |
| `METAL_INVALID` | Unknown metal: {0} | `pricing.errors.METAL_INVALID` | `app/tools/pricing/pricingErrorCodes.ts` |
| `METAL_PRICE_MISSING` | No price on file for {0} on {1} under index {2} — enter that market’s quote under Pricing → Metal prices. Another index may well carry a price for this metal; it is not used, because this deal settles on {2}. A quote is never sent with a metal priced at zero. | `output.sale.errors.METAL_PRICE_MISSING` | `app/output/[id]/edit/saleErrorCodes.ts` |
| `METAL_UNKNOWN` | Unknown metal: {0} | `materials.assayPolicy.errors.METAL_UNKNOWN` | `app/materials/materialPolicyErrorCodes.ts` |
| `MIXED_CURRENCY` | All lines must share one currency ({0} vs {1}) | `invoice.errors.MIXED_CURRENCY` | `app/finance/invoiceErrorCodes.ts` |
| `NO_INPUTS` | At least one input (inbound) is required | `processing.errors.NO_INPUTS` | `app/operation/errorCodes.ts` |
| `NO_JOURNAL_LINES` | Select at least one journal line to match | `bank.errors.NO_JOURNAL_LINES` | `app/finance/bankErrorCodes.ts` |
| `NO_LINES` | Add at least one line | `purchasing.errors.NO_LINES` | `app/purchasing/purchasingErrorCodes.ts` |
| `NO_METAL_CONTENT` | Batch {0} has no metal content recorded — a quote cannot be priced without an assay. Enter the content on the batch first. | `output.sale.errors.NO_METAL_CONTENT` | `app/output/[id]/edit/saleErrorCodes.ts` |
| `NO_METAL_VALUE` | No priced metal content on any output batch — record assay results, or add a price for at least one contained metal in Metal Prices (or allocate by weight) | `processing.errors.NO_METAL_VALUE` | `app/operation/errorCodes.ts` |
| `NO_METALS` | Enter at least one metal content | `pricing.errors.NO_METALS` | `app/tools/pricing/pricingErrorCodes.ts` |
| `NO_OUTPUTS` | At least one output is required | `processing.errors.NO_OUTPUTS` | `app/operation/errorCodes.ts` |
| `NO_PRICES` | No prices submitted | `pricing.errors.NO_PRICES` | `app/tools/pricing/pricingErrorCodes.ts` |
| `NOT_AN_OUTPUT_BATCH` | {0} is an inbound (supplier) batch, not an output batch — audit reports are issued for what we produced. | `traceability.errors.NOT_AN_OUTPUT_BATCH` | `app/output/traceabilityErrorCodes.ts` |
| `NOT_LATEST_ASSAY` | Only the most recently applied assay can be unapplied ({0} is not) | `assay.errors.NOT_LATEST_ASSAY` | `app/inbound/assayErrorCodes.ts` |
| `NOT_MONTH_END` | {0} is not a month-end date | `finance.errors.NOT_MONTH_END` | `app/finance/financeErrorCodes.ts` |
| `NOT_REVIEW_REVIEWER` | Only this review’s reviewer (or HR) can do that | `reviews.errors.NOT_REVIEW_REVIEWER` | `app/hr/reviews/reviewErrorCodes.ts` |
| `NOT_REVIEW_SUBJECT` | Only the person being reviewed can do that | `reviews.errors.NOT_REVIEW_SUBJECT` | `app/hr/reviews/reviewErrorCodes.ts` |
| `NOTHING_TO_REPORT` | No ancestry on record for {0}: nothing consumed it and no processing run produced it, so there is nothing to trace. A report is not issued rather than one that says “origin unknown”. | `traceability.errors.NOTHING_TO_REPORT` | `app/output/traceabilityErrorCodes.ts` |
| `OBJECTIVE_REQUIRED` | The objective text cannot be empty | `reviews.errors.OBJECTIVE_REQUIRED` | `app/hr/reviews/reviewErrorCodes.ts` |
| `OPERATION_PRODUCES_NO_OUTPUTS` | {0} produces no new batch by definition (same batch in, same batch out, state changed), so this run cannot be committed with outputs. Either the wrong operation was picked, or the wrong run. | `processing.errors.OPERATION_PRODUCES_NO_OUTPUTS` | `app/operation/errorCodes.ts` |
| `OPERATION_TYPE_REQUIRED` | This run has not said which operation it ran. It cannot be left blank: whether there are outputs, whether a state-changing loss may be non-zero, whether this operation accepts this batch, and whether the operation exists at all — four gates all read this field. | `processing.errors.OPERATION_TYPE_REQUIRED` | `app/operation/errorCodes.ts` |
| `OPERATION_TYPE_UNKNOWN` | Unknown or inactive operation "{0}". Inactive means "do not pick it again", not "rewrite history". | `processing.errors.OPERATION_TYPE_UNKNOWN` | `app/operation/errorCodes.ts` |
| `ORDER_DATE_REQUIRED` | The order date is required — it is the day the customer accepted, and it is never filled in for you. | `quotes.errors.ORDER_DATE_REQUIRED` | `app/sales/quotes/quoteErrorCodes.ts` |
| `OUTPUT_BATCH_NOT_FOUND` | Output batch not found: {0} | `output.sale.errors.OUTPUT_BATCH_NOT_FOUND` | `app/output/[id]/edit/saleErrorCodes.ts` |
| `OUTPUT_CONSUMED` | Cannot delete: output batch {0} has already been touched (state={1}, remaining {2}/{3}); goods have shipped, the processing run cannot be rolled back | `processing.errors.OUTPUT_CONSUMED` | `app/operation/errorCodes.ts` |
| `OUTPUT_DATE_REQUIRED` | The output date is required — the stock movement records the day the goods were actually produced, and it is never filled in for you. Nothing was saved. Enter the date and submit again. | `stock.errors.OUTPUT_DATE_REQUIRED` | `app/components/inventory/stockErrorCodes.ts` |
| `OUTPUT_DELETED` | Batch has been deleted | `output.sale.errors.OUTPUT_DELETED` | `app/output/[id]/edit/saleErrorCodes.ts` |
| `OUTPUT_EXCEEDS_INPUT` | Total output ({0}) cannot exceed total input ({1}) | `processing.errors.OUTPUT_EXCEEDS_INPUT` | `app/operation/errorCodes.ts` |
| `OUTPUT_NO_MATERIAL` | Output must have a material selected | `processing.errors.OUTPUT_NO_MATERIAL` | `app/operation/errorCodes.ts` |
| `OUTPUT_NOT_FOUND` | Output batch not found | `output.sale.errors.OUTPUT_NOT_FOUND` | `app/output/[id]/edit/saleErrorCodes.ts` |
| `OUTPUT_QTY_INVALID` | Output quantity must be greater than 0 | `processing.errors.OUTPUT_QTY_INVALID` | `app/operation/errorCodes.ts` |
| `PACK_IMMUTABLE` | A stored pack is a thing that was produced and cannot be edited ({0}). Produce another one instead — it supersedes this. | `pack.errors.PACK_IMMUTABLE` | `app/finance/packErrorCodes.ts` |
| `PACK_MONTH_NOT_LOCKED` | The month {0} is not closed (the books are locked before {1}), so a pack for it cannot be stored. Preview and export it instead, or close the period first. | `pack.errors.PACK_MONTH_NOT_LOCKED` | `app/finance/packErrorCodes.ts` |
| `PACK_PERIOD_REQUIRED` | Choose the month this pack covers. | `pack.errors.PACK_PERIOD_REQUIRED` | `app/finance/packErrorCodes.ts` |
| `PACK_SUPERSEDE_REASON_REQUIRED` | This month already has a stored pack ({0}). Producing another one requires a reason. | `pack.errors.PACK_SUPERSEDE_REASON_REQUIRED` | `app/finance/packErrorCodes.ts` |
| `PAYMENT_ALREADY_REVERSED` | Payment {0} has already been reversed — a reversal reverses the original once, and reversing it twice would restore the amount it removed. | `finance.errors.PAYMENT_ALREADY_REVERSED` | `app/finance/paymentErrorCodes.ts` |
| `PAYMENT_DATE_REQUIRED` | A payment date is required | `hr.errors.PAYMENT_DATE_REQUIRED` | `app/hr/hrErrorCodes.ts` |
| `PAYMENT_NOT_FOUND` | Payment {0} does not exist. | `finance.errors.PAYMENT_NOT_FOUND` | `app/finance/paymentErrorCodes.ts` |
| `PAYMENT_STATUS_INVALID` | Invalid payment status: {0} | `expense.errors.PAYMENT_STATUS_INVALID` | `app/finance/expenseErrorCodes.ts` |
| `PAYMENT_TERM_NOT_FOUND` | No payment instalment with id {0}. | `cashForecast.errors.PAYMENT_TERM_NOT_FOUND` | `app/finance/cashForecastErrorCodes.ts` |
| `PAYROLL_ALREADY_POSTED` | Payroll period {0} has already been posted | `hr.errors.PAYROLL_ALREADY_POSTED` | `app/hr/hrErrorCodes.ts` |
| `PAYROLL_ATTENDANCE_NOT_COMPLETE` | Nobody has said the {1} attendance sheet is complete, so {0} cannot be posted — posting it would silently treat unknown absence as full attendance | `hr.errors.PAYROLL_ATTENDANCE_NOT_COMPLETE` | `app/hr/hrErrorCodes.ts` |
| `PAYROLL_CPF_ALREADY_PAID` | CPF for period {0} has already been paid | `hr.errors.PAYROLL_CPF_ALREADY_PAID` | `app/hr/hrErrorCodes.ts` |
| `PAYROLL_CPF_PAID` | Period {0} has had its CPF paid — reverse that payment first | `hr.errors.PAYROLL_CPF_PAID` | `app/hr/hrErrorCodes.ts` |
| `PAYROLL_CURRENCY_UNSUPPORTED` | No bank account is configured for {0} payroll | `hr.errors.PAYROLL_CURRENCY_UNSUPPORTED` | `app/hr/hrErrorCodes.ts` |
| `PAYROLL_DEDUCTIONS_ALREADY_PAID` | Deductions for period {0} have already been remitted | `hr.errors.PAYROLL_DEDUCTIONS_ALREADY_PAID` | `app/hr/hrErrorCodes.ts` |
| `PAYROLL_DEDUCTIONS_PAID` | Period {0} has had its deductions remitted — reverse that first | `hr.errors.PAYROLL_DEDUCTIONS_PAID` | `app/hr/hrErrorCodes.ts` |
| `PAYROLL_LINE_ALREADY_PAID` | {0} has already been paid | `hr.errors.PAYROLL_LINE_ALREADY_PAID` | `app/hr/hrErrorCodes.ts` |
| `PAYROLL_LINE_INVALID` | Line does not belong to this payroll period | `hr.errors.PAYROLL_LINE_INVALID` | `app/hr/hrErrorCodes.ts` |
| `PAYROLL_LINES_PAID` | Period {0} has paid salary lines — reverse the payments first | `hr.errors.PAYROLL_LINES_PAID` | `app/hr/hrErrorCodes.ts` |
| `PAYROLL_NOT_FOUND` | Payroll period not found | `hr.errors.PAYROLL_NOT_FOUND` | `app/hr/hrErrorCodes.ts` |
| `PAYROLL_NOT_POSTED` | Payroll period {0} is not posted | `hr.errors.PAYROLL_NOT_POSTED` | `app/hr/hrErrorCodes.ts` |
| `PAYROLL_NOTHING_TO_PAY` | Period {0} has nothing to pay here | `hr.errors.PAYROLL_NOTHING_TO_PAY` | `app/hr/hrErrorCodes.ts` |
| `PAYROLL_POSTED` | Payroll period {0} is already posted — unpost it before making changes | `hr.errors.PAYROLL_POSTED` | `app/hr/hrErrorCodes.ts` |
| `PERIOD_INVALID` | Invalid statement period: {0} to {1} | `bank.errors.PERIOD_INVALID` | `app/finance/bankErrorCodes.ts` |
| `PERIOD_LOCKED` | Period is closed: {0} is before the lock date {1} | `assay.errors.PERIOD_LOCKED` | `app/inbound/assayErrorCodes.ts` |
| `PERIOD_MONTH_INVALID` | Period must be a whole month (got {0}) | `hr.errors.PERIOD_MONTH_INVALID` | `app/hr/hrErrorCodes.ts` |
| `PERIOD_REQUIRED` | A from and to date are needed. | `pack.errors.PERIOD_REQUIRED` | `app/finance/packErrorCodes.ts` |
| `PERMISSION_DENIED` | You do not have permission to edit contacts for this counterparty ({0}). Contacts follow the side they belong to: customer contacts need customer edit rights, supplier contacts need supplier edit rights. | `contacts.errors.PERMISSION_DENIED` | `app/sales/customers/contactErrorCodes.ts` |
| `PO_ALREADY_CLOSED` | Purchase order {0} is already closed | `purchasing.errors.PO_ALREADY_CLOSED` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_AMEND_REASON_REQUIRED` | An amendment must say why — the reason is kept on the order history. | `purchasing.errors.PO_AMEND_REASON_REQUIRED` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_CANCEL_REASON_REQUIRED` | A reason is required to cancel purchase order {0}. | `purchasing.errors.PO_CANCEL_REASON_REQUIRED` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_CANCELLED` | Purchase order {0} is cancelled | `purchasing.errors.PO_CANCELLED` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_HAS_APPLIED_PREPAYMENTS` | Purchase order {0} already has a deposit released against it — cancelling it would leave that release pointing at a void order. Reverse the release first. | `purchasing.errors.PO_HAS_APPLIED_PREPAYMENTS` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_HAS_RECEIPTS` | Cannot cancel: {0} inbound batch(es) are linked to this order | `purchasing.errors.PO_HAS_RECEIPTS` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_HEADER_WITHOUT_LINE` | Receipt {0} names a purchase order but no order line — a header alone cannot say which line this material came against. | `purchasing.errors.PO_HEADER_WITHOUT_LINE` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_LINE_ALREADY_EXPENSED` | Line {0} has already been expensed on {1} — one equipment line is expensed once. If the order’s estimate does not match the invoice, amend the order line; do not record a second expense. If the invoice itself was wrong, reverse {1} and enter it again — possible only while the machine is not yet in service. | `expense.errors.PO_LINE_ALREADY_EXPENSED` | `app/finance/expenseErrorCodes.ts` |
| `PO_LINE_BELOW_RECEIVED` | Line {0} has already received {1} — its quantity cannot be cut to {2}. The goods are already in the yard; the order may not claim we ordered less than arrived. | `purchasing.errors.PO_LINE_BELOW_RECEIVED` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_LINE_EQUIPMENT_NOT_RECEIVABLE` | Receipt {0} is against an equipment line. A machine arriving is not a stock receipt — it creates no batch, has no assay and enters no location. Its arrival is recorded as the in-service date on the asset card. | `purchasing.errors.PO_LINE_EQUIPMENT_NOT_RECEIVABLE` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_LINE_EQUIPMENT_QTY` | Line {0} orders one machine, so its quantity must be 1 — you sent {1}. Four machines are four lines: each has its own asset card, its own in-service date and its own depreciation. | `purchasing.errors.PO_LINE_EQUIPMENT_QTY` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_LINE_EQUIPMENT_UNIT` | Line {0} orders a machine, so its unit is "unit" — you sent "{1}". Leave it out and it is filled in for you; sending kg would add that machine into a kilogram total. | `purchasing.errors.PO_LINE_EQUIPMENT_UNIT` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_LINE_HAS_EXPENSE` | Line {0} cannot be removed — it was expensed on {1} (status: {2}). A reversed expense still keeps the line on the order, because the record of that bill points at it. To make the line go away, cancel the order; to change the price, edit the line instead of removing it. | `purchasing.errors.PO_LINE_HAS_EXPENSE` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_LINE_HAS_RECEIPTS` | Line {0} has already received {1} — it cannot be removed. Reduce it to what was received instead, so the receipt still has a line to point at. | `purchasing.errors.PO_LINE_HAS_RECEIPTS` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_LINE_KIND_INVALID` | Line {0} must order either a material or one machine that already has an asset card — not both, and not neither. | `purchasing.errors.PO_LINE_KIND_INVALID` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_LINE_MISMATCH` | Batch {0}: the selected line belongs to a different purchase order | `purchasing.errors.PO_LINE_MISMATCH` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_LINE_NOT_EQUIPMENT` | Line {0} orders a material, not equipment. A material line is billed through goods receipt, never through an expense — otherwise the same material has two billing paths and nothing reconciles them. | `expense.errors.PO_LINE_NOT_EQUIPMENT` | `app/finance/expenseErrorCodes.ts` |
| `PO_LINE_NOT_FOUND` | Purchase order line not found: {0} | `expense.errors.PO_LINE_NOT_FOUND` | `app/finance/expenseErrorCodes.ts` |
| `PO_LINE_QUANTITY_INVALID` | Line {0}: quantity must be greater than 0. | `purchasing.errors.PO_LINE_QUANTITY_INVALID` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_LINE_REMOVE_NEEDS_ID` | A line can only be removed by its id — the amendment payload named none. | `purchasing.errors.PO_LINE_REMOVE_NEEDS_ID` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_LINES_MIXED_KINDS` | Purchase order {0} would end up holding {1} material line(s) and {2} equipment line(s). One order is either all material or all equipment — mixing them makes its ordered quantity a number that adds kilograms to machines. | `purchasing.errors.PO_LINES_MIXED_KINDS` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_NO_HARD_DELETE` | Purchase order {0} cannot be permanently deleted — cancel it instead, which records who and why. | `deletion.errors.PO_NO_HARD_DELETE` | `app/components/inventory/deletionErrorCodes.ts` |
| `PO_NOT_AMENDABLE` | Purchase order {0} is {1} — only a live order can be amended. Cancel it and raise a new one instead. | `purchasing.errors.PO_NOT_AMENDABLE` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_NOT_APPROVED` | Purchase order {0} is not approved yet (approval status: {1}) — goods cannot be received against it | `purchasing.errors.PO_NOT_APPROVED` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_NOT_CLOSED` | Purchase order {0} is not closed | `purchasing.errors.PO_NOT_CLOSED` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_NOT_FOUND` | Purchase order not found | `purchasing.errors.PO_NOT_FOUND` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_NOT_PENDING` | Purchase order {0} is not awaiting approval (approval status: {1}) | `purchasing.errors.PO_NOT_PENDING` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_NOT_RECEIVABLE` | Purchase order {0} is {1} and cannot receive goods — reopen it first | `purchasing.errors.PO_NOT_RECEIVABLE` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_PLAN_FIXED_MISMATCH` | The payment plan’s fixed instalments total {0} {1}, which does not match the order total {2}. | `purchasing.errors.PO_PLAN_FIXED_MISMATCH` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_TERM_EVENT_NOT_APPLICABLE` | Payment milestone “{2}” does not apply to a {3} order (order {0}, instalment {1}). A machine is never assayed. | `purchasing.errors.PO_TERM_EVENT_NOT_APPLICABLE` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_TERM_KIND_UNKNOWN` | Order {0} has no lines yet, so it cannot be told whether it is a material or an equipment order — add the lines before the payment schedule. | `purchasing.errors.PO_TERM_KIND_UNKNOWN` | `app/purchasing/purchasingErrorCodes.ts` |
| `PO_VENDOR_IS_A_FORWARDER` | A forwarder cannot be a purchase-order vendor — freight goes on a freight document, not a purchase order. | `logistics.opErrors.PO_VENDOR_IS_A_FORWARDER` | `app/logistics/logisticsErrorCodes.ts` |
| `PREPAY_DESTINATION_INVALID` | A prepayment release settles exactly one document — either a received batch or an expense invoice. This call named {0}. | `purchasing.errors.PREPAY_DESTINATION_INVALID` | `app/purchasing/purchasingErrorCodes.ts` |
| `PREPAY_EXCEEDS_ESTIMATE` | Prepayments on {0} would total {1}, above the cap of {2} (150% of the estimated total — deliberate slack for price movement) | `purchasing.errors.PREPAY_EXCEEDS_ESTIMATE` | `app/purchasing/purchasingErrorCodes.ts` |
| `PREPAY_INSUFFICIENT` | Unapplied prepayment is {0}; requested {1} | `purchasing.errors.PREPAY_INSUFFICIENT` | `app/purchasing/purchasingErrorCodes.ts` |
| `PREPAY_TWO_FOREIGN_CURRENCIES` | The deposit is held in {0} and the payable is billed in {1} — two different foreign currencies. Releasing between them would need a conversion this system does not perform, so ask for the invoice in {1} or in the base currency instead. | `purchasing.errors.PREPAY_TWO_FOREIGN_CURRENCIES` | `app/purchasing/purchasingErrorCodes.ts` |
| `PRICE_DATE_REQUIRED` | A price date is required | `pricing.errors.PRICE_DATE_REQUIRED` | `app/tools/pricing/pricingErrorCodes.ts` |
| `PRICE_INDEX_UNKNOWN` | Unknown or inactive price index {0}. | `pricing.errors.PRICE_INDEX_UNKNOWN` | `app/tools/pricing/pricingErrorCodes.ts` |
| `PRICE_INVALID` | Price for {0} is invalid: {1} | `pricing.errors.PRICE_INVALID` | `app/tools/pricing/pricingErrorCodes.ts` |
| `PRICE_NOT_POSITIVE` | The committed terms value this batch at or below zero ({0}/kg) — handle the price manually | `assay.errors.PRICE_NOT_POSITIVE` | `app/inbound/assayErrorCodes.ts` |
| `PRICE_SOURCE_INVALID` | Line {0}: price source {1} is not computed/manual | `purchasing.errors.PRICE_SOURCE_INVALID` | `app/purchasing/purchasingErrorCodes.ts` |
| `PRICING_COMMITMENT_IMMUTABLE` | Committed settlement terms cannot be edited or deleted — the copy is the record | `purchasing.errors.PRICING_COMMITMENT_IMMUTABLE` | `app/purchasing/purchasingErrorCodes.ts` |
| `PRICING_TERMS_ALREADY_COMMITTED` | {0} already settles under committed terms ({1}) | `purchasing.errors.PRICING_TERMS_ALREADY_COMMITTED` | `app/purchasing/purchasingErrorCodes.ts` |
| `PRICING_TERMS_NOT_COMMITTED` | {0} references pricing formula {1} with no settlement terms recorded at the time — settlement refuses rather than reading the formula as it stands today | `purchasing.errors.PRICING_TERMS_NOT_COMMITTED` | `app/purchasing/purchasingErrorCodes.ts` |
| `PROBATION_END_DATE_NOT_SET` | {0} has no probation end date on file, and this system will not invent one — that date is what the confirmation decision turns on, and it is what the reminders count down to. Set it on the employee record first, then raise the review. | `reviews.errors.PROBATION_END_DATE_NOT_SET` | `app/hr/reviews/reviewErrorCodes.ts` |
| `PROBATION_OUTCOME_REQUIRED` | A probation review needs the confirmation decision recorded before submitting | `reviews.errors.PROBATION_OUTCOME_REQUIRED` | `app/hr/reviews/reviewErrorCodes.ts` |
| `PROBATION_PERIOD_INVALID` | {0} has a probation end date ({2}) earlier than the hire date ({1}), so there is no period to review. Correct the employee record first. | `reviews.errors.PROBATION_PERIOD_INVALID` | `app/hr/reviews/reviewErrorCodes.ts` |
| `PROBATION_REVIEW_EXISTS` | {0} already has a probation review (currently {1}). There is only ever one per person — open the existing one, or void it first if it needs to start again. | `reviews.errors.PROBATION_REVIEW_EXISTS` | `app/hr/reviews/reviewErrorCodes.ts` |
| `PROCEEDS_INVALID` | Proceeds cannot be negative. Scrapping with nothing received is proceeds of 0. | `finance.errors.PROCEEDS_INVALID` | `app/finance/paymentErrorCodes.ts` |
| `PROCESS_DATE_REQUIRED` | A process date is required — it decides the movement date and which metal prices the allocation uses. | `processing.errors.PROCESS_DATE_REQUIRED` | `app/operation/errorCodes.ts` |
| `PROMISE_AMOUNT_INVALID` | {0} is not an amount anyone can promise to pay. | `chases.errors.PROMISE_AMOUNT_INVALID` | `app/finance/collections/chaseErrorCodes.ts` |
| `PROMISE_AMOUNT_REQUIRED` | A promise needs an amount. | `chases.errors.PROMISE_AMOUNT_REQUIRED` | `app/finance/collections/chaseErrorCodes.ts` |
| `PROMISE_CHASE_SUPERSEDED` | The chase this promise came from ({0}) has been superseded, so the promise no longer stands. There is nothing to settle. | `chases.errors.PROMISE_CHASE_SUPERSEDED` | `app/finance/collections/chaseErrorCodes.ts` |
| `PROMISE_CURRENCY_UNKNOWN` | “{0}” is not a currency this system holds. | `chases.errors.PROMISE_CURRENCY_UNKNOWN` | `app/finance/collections/chaseErrorCodes.ts` |
| `PROMISE_DATE_BEFORE_CHASE` | The promised date {0} is before the call on {1}. That is a typo, not a promise. | `chases.errors.PROMISE_DATE_BEFORE_CHASE` | `app/finance/collections/chaseErrorCodes.ts` |
| `PROMISE_DATE_REQUIRED` | A promise needs a date. An amount with no date is not a commitment. | `chases.errors.PROMISE_DATE_REQUIRED` | `app/finance/collections/chaseErrorCodes.ts` |
| `PROMISE_NOT_FOUND` | No promise with id {0}. | `chases.errors.PROMISE_NOT_FOUND` | `app/finance/collections/chaseErrorCodes.ts` |
| `PROMISE_OUTCOME_ALREADY_RECORDED` | This promise was already settled as “{0}” on {1}. An outcome is a fact about what happened; it is not revised. | `chases.errors.PROMISE_OUTCOME_ALREADY_RECORDED` | `app/finance/collections/chaseErrorCodes.ts` |
| `PROMISE_OUTCOME_INVALID` | “{0}” is not an outcome this system knows. | `chases.errors.PROMISE_OUTCOME_INVALID` | `app/finance/collections/chaseErrorCodes.ts` |
| `PROMISE_REQUIRES_CONTACT` | You recorded that nobody was reached, and also that they promised to pay. Both cannot be true. | `chases.errors.PROMISE_REQUIRES_CONTACT` | `app/finance/collections/chaseErrorCodes.ts` |
| `PROVENANCE_REQUIRED` | Line {0}: a computed price must carry the data to re-derive it — provenance is missing | `purchasing.errors.PROVENANCE_REQUIRED` | `app/purchasing/purchasingErrorCodes.ts` |
| `QT_ALREADY_CONVERTED` | Quotation {0} already became sales order {1}. Open that order rather than converting again. | `quotes.errors.QT_ALREADY_CONVERTED` | `app/sales/quotes/quoteErrorCodes.ts` |
| `QT_CONVERT_LINES_LOST` | The conversion did not copy every line ({0} sent, {1} created), so nothing was saved. Report this rather than retrying. | `quotes.errors.QT_CONVERT_LINES_LOST` | `app/sales/quotes/quoteErrorCodes.ts` |
| `QT_CONVERTED_IMMUTABLE` | Quotation {1} became a sales order and can no longer be changed ({0}) — the offer and the order it produced must not drift apart. | `quotes.errors.QT_CONVERTED_IMMUTABLE` | `app/sales/quotes/quoteErrorCodes.ts` |
| `QT_DECLINE_REASON_REQUIRED` | Recording a decline needs a reason — three months from now nobody will remember why this one did not close. | `quotes.errors.QT_DECLINE_REASON_REQUIRED` | `app/sales/quotes/quoteErrorCodes.ts` |
| `QT_DECLINED` | Quotation {0} was declined, so it cannot be converted. Raise a new one if the customer comes back. | `quotes.errors.QT_DECLINED` | `app/sales/quotes/quoteErrorCodes.ts` |
| `QT_EXPIRED` | Quotation {0} expired on {1}, so it cannot be converted. Change the validity date and issue a new version — the customer should be looking at a price that is still on offer. | `quotes.errors.QT_EXPIRED` | `app/sales/quotes/quoteErrorCodes.ts` |
| `QT_HISTORY_IMMUTABLE` | Quotation history is append-only and cannot be changed. | `quotes.errors.QT_HISTORY_IMMUTABLE` | `app/sales/quotes/quoteErrorCodes.ts` |
| `QT_NO_LINES` | Quotation {0} has no lines, so there is nothing to convert. | `quotes.errors.QT_NO_LINES` | `app/sales/quotes/quoteErrorCodes.ts` |
| `QT_NOT_FOUND` | That quotation no longer exists. Reload the list and try again. | `quotes.errors.QT_NOT_FOUND` | `app/sales/quotes/quoteErrorCodes.ts` |
| `QT_NOT_ISSUABLE` | Quotation {0} is {1}, so it can no longer be issued — that state means this one is finished. | `quotes.errors.QT_NOT_ISSUABLE` | `app/sales/quotes/quoteErrorCodes.ts` |
| `QT_NOT_ISSUED` | Quotation {0} is a {1} — only an issued quotation can be converted or declined. Issue it first. | `quotes.errors.QT_NOT_ISSUED` | `app/sales/quotes/quoteErrorCodes.ts` |
| `QUANTITY_INVALID` | Quantity must be greater than 0 | `pricing.errors.QUANTITY_INVALID` | `app/tools/pricing/pricingErrorCodes.ts` |
| `QUOTE_SOURCE_INDEX_REQUIRED` | A published-index quote must say which index (LME or SMM) — the two are quoted in different currencies | `pricing.errors.QUOTE_SOURCE_INDEX_REQUIRED` | `app/tools/pricing/pricingErrorCodes.ts` |
| `QUOTE_SOURCE_INVALID` | Unrecognised quote source: {0} | `pricing.errors.QUOTE_SOURCE_INVALID` | `app/tools/pricing/pricingErrorCodes.ts` |
| `QUOTE_SOURCE_REQUIRED` | Say where this quote came from — a published index, a broker quotation, or an internal estimate | `pricing.errors.QUOTE_SOURCE_REQUIRED` | `app/tools/pricing/pricingErrorCodes.ts` |
| `QUOTE_SOURCE_UNKNOWN_NOT_ALLOWED_FOR_NEW` | "Not recorded" is only for quotes entered before provenance was tracked — a new quote must say where it came from | `pricing.errors.QUOTE_SOURCE_UNKNOWN_NOT_ALLOWED_FOR_NEW` | `app/tools/pricing/pricingErrorCodes.ts` |
| `RATE_QUOTE_VENDOR_NOT_A_FORWARDER` | Quotes can only belong to a forwarder, and this company is not one. | `logistics.opErrors.RATE_QUOTE_VENDOR_NOT_A_FORWARDER` | `app/logistics/logisticsErrorCodes.ts` |
| `RATING_NOT_FOUND` | No active rating level {0} | `reviews.errors.RATING_NOT_FOUND` | `app/hr/reviews/reviewErrorCodes.ts` |
| `RATING_REQUIRED` | A rating is required before submitting | `reviews.errors.RATING_REQUIRED` | `app/hr/reviews/reviewErrorCodes.ts` |
| `REASON_REQUIRED` | A reason is required | `purchasing.errors.REASON_REQUIRED` | `app/purchasing/purchasingErrorCodes.ts` |
| `RECEIPT_SOURCE_REQUIRED` | A receipt must say where it came from — either a purchase order line, or a reason (return / sample / stocktake gain / other). Never neither. | `purchasing.errors.RECEIPT_SOURCE_REQUIRED` | `app/purchasing/purchasingErrorCodes.ts` |
| `RECONCILIATION_IMMUTABLE` | A reconciliation record cannot be edited or deleted. Reopen the statement and reconcile again — that writes a new record and keeps the old one. | `bank.errors.RECONCILIATION_IMMUTABLE` | `app/finance/bankErrorCodes.ts` |
| `REFERENCE_DATE_REQUIRED` | A reference date is required — it decides which metal prices are quoted. | `pricing.errors.REFERENCE_DATE_REQUIRED` | `app/tools/pricing/pricingErrorCodes.ts` |
| `REJECT_REASON_REQUIRED` | A reason is required to reject an order | `purchasing.errors.REJECT_REASON_REQUIRED` | `app/purchasing/purchasingErrorCodes.ts` |
| `RELEASE_DATE_REQUIRED` | A release date is required — it decides which period the release posts into, so it is never filled in for you. | `purchasing.errors.RELEASE_DATE_REQUIRED` | `app/purchasing/purchasingErrorCodes.ts` |
| `RELIEF_MIXED_COST_TYPES` | One invoice relieves one cost type ({0} vs {1}) — a bill is per type | `processing.errors.RELIEF_MIXED_COST_TYPES` | `app/operation/errorCodes.ts` |
| `RETENTION_ALREADY_RELEASED` | The retention on {0} has already been confirmed. | `purchasing.errors.RETENTION_ALREADY_RELEASED` | `app/purchasing/purchasingErrorCodes.ts` |
| `RETENTION_ANCHOR_HAS_NO_DATE` | “{0}” is not an event this system records a date for, so a maturity date could not be derived from it. | `purchasing.errors.RETENTION_ANCHOR_HAS_NO_DATE` | `app/purchasing/purchasingErrorCodes.ts` |
| `RETENTION_CLOCK_NOT_STARTED` | The retention on {0} has not started: this machine has no acceptance date yet. | `purchasing.errors.RETENTION_CLOCK_NOT_STARTED` | `app/purchasing/purchasingErrorCodes.ts` |
| `RETENTION_NOT_AN_EQUIPMENT_LINE` | Retention applies to equipment only — a material line has no acceptance to start the clock from ({0}). | `purchasing.errors.RETENTION_NOT_AN_EQUIPMENT_LINE` | `app/purchasing/purchasingErrorCodes.ts` |
| `RETENTION_NOT_FOUND` | Retention record not found ({0}). | `purchasing.errors.RETENTION_NOT_FOUND` | `app/purchasing/purchasingErrorCodes.ts` |
| `RETENTION_NOT_MATURE` | The retention on {0} is not due until {1} — releasing it early would defeat the point of holding it. | `purchasing.errors.RETENTION_NOT_MATURE` | `app/purchasing/purchasingErrorCodes.ts` |
| `RETENTION_RELEASE_AMOUNT_NEGATIVE` | Released and withheld amounts cannot be negative ({0} / {1}). | `purchasing.errors.RETENTION_RELEASE_AMOUNT_NEGATIVE` | `app/purchasing/purchasingErrorCodes.ts` |
| `RETENTION_RELEASE_AMOUNTS_REQUIRED` | State both how much is released and how much is withheld — neither is defaulted. | `purchasing.errors.RETENTION_RELEASE_AMOUNTS_REQUIRED` | `app/purchasing/purchasingErrorCodes.ts` |
| `RETENTION_RELEASE_DOES_NOT_BALANCE` | Released plus withheld must equal the retention exactly ({0}: {1} against {2}). | `purchasing.errors.RETENTION_RELEASE_DOES_NOT_BALANCE` | `app/purchasing/purchasingErrorCodes.ts` |
| `RETENTION_WITHHOLDING_NEEDS_REASON` | Say why the retention on {0} is being withheld — an unexplained deduction cannot be answered for later. | `purchasing.errors.RETENTION_WITHHOLDING_NEEDS_REASON` | `app/purchasing/purchasingErrorCodes.ts` |
| `REVALUATION_NOT_RUN` | Period-end revaluation has not been run level for {0} | `finance.errors.REVALUATION_NOT_RUN` | `app/finance/financeErrorCodes.ts` |
| `REVERSAL_DATE_NOT_ACCEPTED` | Invoice {0} posted nothing, so there is nothing to reverse — a reversal date has no meaning here and accepting one silently would be lying about what this action does. | `invoice.errors.REVERSAL_DATE_NOT_ACCEPTED` | `app/finance/invoiceErrorCodes.ts` |
| `REVERSAL_DATE_REQUIRED` | A reversal date is required — it decides which accounting period the reversal posts to. | `bank.errors.REVERSAL_DATE_REQUIRED` | `app/finance/bankErrorCodes.ts` |
| `REVIEW_ALREADY_VOID` | This review is already void | `reviews.errors.REVIEW_ALREADY_VOID` | `app/hr/reviews/reviewErrorCodes.ts` |
| `REVIEW_BAD_STATUS` | Not possible in the review’s current state ({0}) | `reviews.errors.REVIEW_BAD_STATUS` | `app/hr/reviews/reviewErrorCodes.ts` |
| `REVIEW_NOT_FOUND` | Review not found | `reviews.errors.REVIEW_NOT_FOUND` | `app/hr/reviews/reviewErrorCodes.ts` |
| `REVIEWER_REQUIRED` | Assign a reviewer first | `reviews.errors.REVIEWER_REQUIRED` | `app/hr/reviews/reviewErrorCodes.ts` |
| `REVIEWER_SEPARATED` | Reviewer {0} has left the company | `reviews.errors.REVIEWER_SEPARATED` | `app/hr/reviews/reviewErrorCodes.ts` |
| `ROLLBACK_REASON_REQUIRED` | A reason is required to roll back processing run {0} — it soft-deletes the output batches and reverses the ledger. | `processing.errors.ROLLBACK_REASON_REQUIRED` | `app/operation/errorCodes.ts` |
| `RUN_ALREADY_DELETED` | This processing run is already deleted; no action needed | `processing.errors.RUN_ALREADY_DELETED` | `app/operation/errorCodes.ts` |
| `RUN_NOT_COMMITTED` | Only committed runs can be allocated (status: {0}) | `processing.errors.RUN_NOT_COMMITTED` | `app/operation/errorCodes.ts` |
| `RUN_NOT_FOUND` | Processing run not found (id={0}) | `processing.errors.RUN_NOT_FOUND` | `app/operation/errorCodes.ts` |
| `SAFETY_STATES_BATCH_REQUIRED` | Which batch? Recording safety states needs a batch to record them against. | `materials.errors.SAFETY_STATES_BATCH_REQUIRED` | `app/materials/materialErrorCodes.ts` |
| `SALARY_EFFECTIVE_IN_POSTED_PERIOD` | The salary effective date falls in posted payroll period {0} | `reviews.errors.SALARY_EFFECTIVE_IN_POSTED_PERIOD` | `app/hr/reviews/reviewErrorCodes.ts` |
| `SALE_BATCH_EARMARKED` | Batch {0} is earmarked as {2}, so it is not saleable stock and can be neither reserved nor shipped — this is NOT a statement that the thing may not be sold. Release the earmark on the output batch page, or use a different batch. | `sales.errors.SALE_BATCH_EARMARKED` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SALE_DATE_REQUIRED` | A sale date is required — it decides the FX rate, the movement date, and the period both journals post to. | `output.sale.errors.SALE_DATE_REQUIRED` | `app/output/[id]/edit/saleErrorCodes.ts` |
| `SALE_EXCEEDS_REMAINING` | Quantity ({0}) exceeds remaining stock ({1}) | `output.sale.errors.SALE_EXCEEDS_REMAINING` | `app/output/[id]/edit/saleErrorCodes.ts` |
| `SALE_FORM_NOT_SALEABLE` | The form "{2}" may not be sold under the law, so it cannot be quoted — a quote for something that can never lawfully be sold is a promise discovered too late (R5). | `quotes.errors.SALE_FORM_NOT_SALEABLE` | `app/sales/quotes/quoteErrorCodes.ts` |
| `SALE_FORM_NOT_SET` | This batch came out of processing and its material has no form set, so saleability cannot be determined — this is NOT a statement that it may not be sold. Set the form under Materials first. | `quotes.errors.SALE_FORM_NOT_SET` | `app/sales/quotes/quoteErrorCodes.ts` |
| `SALE_NOT_ATTRIBUTED` | Sale on batch {0} belongs to no customer, so it cannot be invoiced to one — an invoice states that a named customer owes this money, and the sale itself does not record that. Attach a customer to the sale first (Finance → Receivables → open the sale). | `invoice.errors.SALE_NOT_ATTRIBUTED` | `app/finance/invoiceErrorCodes.ts` |
| `SALE_NOT_FOUND` | Sale not found: {0} | `invoice.errors.SALE_NOT_FOUND` | `app/finance/invoiceErrorCodes.ts` |
| `SALE_PRICE_INVALID` | Unit price must be greater than 0 | `output.sale.errors.SALE_PRICE_INVALID` | `app/output/[id]/edit/saleErrorCodes.ts` |
| `SALE_QTY_INVALID` | Invalid sale quantity | `output.sale.errors.SALE_QTY_INVALID` | `app/output/[id]/edit/saleErrorCodes.ts` |
| `SALE_WRONG_CUSTOMER` | Sale {0} belongs to a different customer | `invoice.errors.SALE_WRONG_CUSTOMER` | `app/finance/invoiceErrorCodes.ts` |
| `SELF_APPROVAL_FORBIDDEN` | Segregation of duties: the person who raised a purchase order cannot approve it. Ask another holder of the approver role. | `purchasing.errors.SELF_APPROVAL_FORBIDDEN` | `app/purchasing/purchasingErrorCodes.ts` |
| `SELF_ASSESSMENT_LOCKED` | The self-assessment was finalised ({0}); ask the reviewer to reopen it | `reviews.errors.SELF_ASSESSMENT_LOCKED` | `app/hr/reviews/reviewErrorCodes.ts` |
| `SELF_REVIEW_FORBIDDEN` | People cannot review themselves | `reviews.errors.SELF_REVIEW_FORBIDDEN` | `app/hr/reviews/reviewErrorCodes.ts` |
| `SHIP_DATE_REQUIRED` | The ship date is required — it is the day the goods physically left, and it decides which period the revenue lands in. It is never filled in for you. Nothing was saved. | `sales.errors.SHIP_DATE_REQUIRED` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SHIPMENT_IMMUTABLE` | A shipment is a record of goods that physically left; it can never be edited, voided or deleted. Corrections go through a credit note. | `sales.errors.SHIPMENT_IMMUTABLE` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SHIPMENT_NOT_FOUND` | That shipment no longer exists. Reload and try again. | `sales.errors.SHIPMENT_NOT_FOUND` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SHIPMENT_NOT_IN_A_CONTAINER` | {0} is not in a container, so there is nothing to detach. | `logistics.opErrors.SHIPMENT_NOT_IN_A_CONTAINER` | `app/logistics/logisticsErrorCodes.ts` |
| `SO_AMEND_LINE_INVALID` | Line {0}: {1} is not usable. Quantity and unit price must both be greater than 0, and a new line needs a material. Nothing was saved. | `sales.errors.SO_AMEND_LINE_INVALID` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_AMEND_LINE_INVOICED` | Line {0} sits on live invoice {1}, so its quantity and price are frozen — the invoice already posted the debt, and changing the order line will not move it. Two ways out: void {1} first if the figure is wrong, or add a NEW line if the customer wants more. | `sales.errors.SO_AMEND_LINE_INVOICED` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_AMEND_REASON_REQUIRED` | Amending order {0} needs a reason. Without one the history is just a row saying a number changed, and three months from now nobody can say why. | `sales.errors.SO_AMEND_REASON_REQUIRED` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_BATCH_HAS_RESERVATIONS` | Batch {0} still has {1} live reservation(s) on order(s) {2} — release them first. | `deletion.errors.SO_BATCH_HAS_RESERVATIONS` | `app/components/inventory/deletionErrorCodes.ts` |
| `SO_CANCEL_REASON_REQUIRED` | Cancelling order {0} needs a reason — three months from now nobody will remember why it was cancelled. | `sales.errors.SO_CANCEL_REASON_REQUIRED` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_CANCEL_RESERVATIONS_LEFT` | Order {0} still has {1} active reservation(s) after cancelling, so nothing was changed. That should be impossible — report it rather than retrying. | `sales.errors.SO_CANCEL_RESERVATIONS_LEFT` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_CONFIRMED_IMMUTABLE` | This order is confirmed, so {0} can no longer be changed. Amending a confirmed order is a separate action that does not exist yet — cancel and raise a new one. | `sales.errors.SO_CONFIRMED_IMMUTABLE` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_CREATE_CUSTOMER_INVALID` | That customer no longer exists, so the order could not be created. | `quotes.errors.SO_CREATE_CUSTOMER_INVALID` | `app/sales/quotes/quoteErrorCodes.ts` |
| `SO_CREATE_FX_INVALID` | The FX rate {0} is not usable — it must be greater than 0. | `quotes.errors.SO_CREATE_FX_INVALID` | `app/sales/quotes/quoteErrorCodes.ts` |
| `SO_CREATE_LINE_INVALID` | Line {0} is not usable: {1}. Nothing was saved. | `quotes.errors.SO_CREATE_LINE_INVALID` | `app/sales/quotes/quoteErrorCodes.ts` |
| `SO_CREATE_LINES_LOST` | The order was not written completely ({0} lines sent, {1} stored), so nothing was saved. Report this rather than retrying. | `quotes.errors.SO_CREATE_LINES_LOST` | `app/sales/quotes/quoteErrorCodes.ts` |
| `SO_CREATE_NO_LINES` | The order needs at least one line. Nothing was saved. | `quotes.errors.SO_CREATE_NO_LINES` | `app/sales/quotes/quoteErrorCodes.ts` |
| `SO_CUSTOMER_ON_HOLD` | Customer {0} is on credit hold, so this order cannot be confirmed. Lift the hold under Customers, or leave the order as a draft. | `sales.errors.SO_CUSTOMER_ON_HOLD` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_HISTORY_IMMUTABLE` | Order history is append-only and cannot be changed. | `sales.errors.SO_HISTORY_IMMUTABLE` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_INVOICE_LINE_INVALID` | {1} of the requested lines do not belong to order {0}. Nothing was saved — reload and pick again. | `invoice.errors.SO_INVOICE_LINE_INVALID` | `app/finance/invoiceErrorCodes.ts` |
| `SO_INVOICE_NOTHING_TO_BILL` | Every line of order {0} is already on a live invoice — there is nothing left to bill. Void the existing invoice first if it is wrong. | `invoice.errors.SO_INVOICE_NOTHING_TO_BILL` | `app/finance/invoiceErrorCodes.ts` |
| `SO_INVOICE_ORDER_NOT_CONFIRMED` | Order {0} is a {1}, so it cannot be invoiced. A draft is not yet a commitment — confirm the order first. | `invoice.errors.SO_INVOICE_ORDER_NOT_CONFIRMED` | `app/finance/invoiceErrorCodes.ts` |
| `SO_ISSUE_IMMUTABLE` | Issued versions are a record and cannot be changed or deleted. Re-issue instead — that appends a new version. | `sales.errors.SO_ISSUE_IMMUTABLE` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_LINE_ALREADY_INVOICED` | Order line {0} is already on invoice {1}. One line, one live invoice — void that invoice first if it is wrong. | `invoice.errors.SO_LINE_ALREADY_INVOICED` | `app/finance/invoiceErrorCodes.ts` |
| `SO_LINE_BELOW_RESERVED` | Line {0} still has {1} reserved on top of what has shipped, so it cannot be amended down to {2}. Release that reservation first — the system will not release it for you, because giving up a promise is a decision that has to carry someone’s name. | `sales.errors.SO_LINE_BELOW_RESERVED` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_LINE_BELOW_SHIPPED` | Line {0} has already shipped {1}, so it cannot be amended down to {2} — the goods have left, and the order cannot claim we promised less than we sent. The floor is {1} itself, not one above it. (Amending down to exactly {1} does not trip this rule, but a shipped line is also on a live invoice that freezes the quantity outright: closing a short shipment needs a credit note, which this system does not have yet.) | `sales.errors.SO_LINE_BELOW_SHIPPED` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_LINE_HAS_INVOICE` | Line {0} is on live invoice {1}, so it cannot be removed. Void the invoice first — until then that line is what the customer has been billed for. | `sales.errors.SO_LINE_HAS_INVOICE` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_LINE_HAS_RECORD` | Line {0} can no longer be removed: {1} document record(s) still point at it — a released reservation or a voided invoice line is a record of something that actually happened, and removing the line would destroy it or leave it pointing at nothing. Amend the quantity down instead. | `sales.errors.SO_LINE_HAS_RECORD` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_LINE_HAS_RESERVATIONS` | Line {0} still holds {1} in reserved stock, so it cannot be removed. Release the reservation first — otherwise that stock would stay committed to a line that no longer exists. | `sales.errors.SO_LINE_HAS_RESERVATIONS` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_LINE_HAS_SHIPMENTS` | Line {0} has {1} shipped against it, so it cannot be removed — the goods left the ledger and the order would have nothing to explain them. Amend the quantity down to what shipped instead. | `sales.errors.SO_LINE_HAS_SHIPMENTS` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_LINE_NOT_FOUND` | That order line ({0}) is not on this order any more. Reload the page and try again. | `sales.errors.SO_LINE_NOT_FOUND` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_LINE_REMOVE_NEEDS_ID` | A line can only be removed by id, and none was sent for order {0}. Nothing was saved. | `sales.errors.SO_LINE_REMOVE_NEEDS_ID` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_NO_LINES` | Order {0} has no lines — an order with nothing on it cannot be confirmed. | `sales.errors.SO_NO_LINES` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_NOT_AMENDABLE` | Order {0} is {1}, so it cannot be amended. A closed or cancelled order is a final state — raise a new order instead. (A fully shipped order still accepts a NEW line; nothing else.) | `sales.errors.SO_NOT_AMENDABLE` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_NOT_FOUND` | That sales order no longer exists. Reload the list and try again. | `sales.errors.SO_NOT_FOUND` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_NOT_ISSUABLE` | Order {0} is a {1} — a draft is not a commitment, so there is nothing to issue yet. | `sales.errors.SO_NOT_ISSUABLE` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_RELEASE_EXCEEDS` | Cannot release {0} — this reservation is for {1}. Leave the quantity blank to release all of it. | `sales.errors.SO_RELEASE_EXCEEDS` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_RELEASE_REASON_REQUIRED` | Releasing a reservation needs a reason. Taking back a promise that was already made is exactly the kind of thing nobody can reconstruct later. | `sales.errors.SO_RELEASE_REASON_REQUIRED` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_RESERVATION_ALREADY_RELEASED` | That reservation has already been released — nothing more to give back. | `sales.errors.SO_RESERVATION_ALREADY_RELEASED` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_RESERVATION_ALREADY_SHIPPED` | That reservation has already been shipped — goods that have left cannot be released back. A correction after shipment goes through a credit note. | `sales.errors.SO_RESERVATION_ALREADY_SHIPPED` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_RESERVATION_IMMUTABLE` | A reservation is a record of what was promised; it can be released but never edited or deleted. | `sales.errors.SO_RESERVATION_IMMUTABLE` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_RESERVATION_NOT_FOUND` | That reservation no longer exists. Reload the order and try again. | `sales.errors.SO_RESERVATION_NOT_FOUND` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_RESERVE_EXCEEDS_AVAILABLE` | Cannot reserve {0} — only {1} is available in that batch and location. Reserving does not create stock; it only sets aside what is already there. | `sales.errors.SO_RESERVE_EXCEEDS_AVAILABLE` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_RESERVE_EXCEEDS_LINE` | Cannot reserve {0} — this line is for {1} and {2} is already spoken for (shipped plus reserved). Reserving more would promise the same line twice. | `sales.errors.SO_RESERVE_EXCEEDS_LINE` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_RESERVE_MATERIAL_MISMATCH` | Batch {0} is {1}, but this order line is for {2}. Pick a batch of the line’s own material. | `sales.errors.SO_RESERVE_MATERIAL_MISMATCH` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_RESERVE_ORDER_NOT_CONFIRMED` | Order {0} is a {1}, so stock cannot be reserved against it. A draft is not yet a promise — confirm the order first. | `sales.errors.SO_RESERVE_ORDER_NOT_CONFIRMED` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_RESERVE_OUTPUT_ONLY` | Only an output batch can be reserved, and {0} is not one (or has been written off). Sales draw from output batches; incoming material has to be processed first. | `sales.errors.SO_RESERVE_OUTPUT_ONLY` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_RESERVE_QTY_INVALID` | The quantity {0} is not usable — it must be a positive number. | `sales.errors.SO_RESERVE_QTY_INVALID` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_SHIP_EXCEEDS_RESERVATION` | Cannot ship {0} — that reservation is for {1}. Reserve more first, or ship what is reserved. | `sales.errors.SO_SHIP_EXCEEDS_RESERVATION` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_SHIP_LINES_LOST` | The shipment was not written completely ({0} sent, {1} stored), so nothing was saved. Report this rather than retrying. | `sales.errors.SO_SHIP_LINES_LOST` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_SHIP_NO_LINES` | Nothing was selected to ship on order {0}. | `sales.errors.SO_SHIP_NO_LINES` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_SHIP_NOT_INVOICED` | Line {1} of order {0} is not on a live posted invoice. Order flow is invoice-before-shipment: raise the invoice first. Nothing was shipped. | `sales.errors.SO_SHIP_NOT_INVOICED` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_SHIP_NOT_RESERVED` | That reservation is not available to ship — it does not exist on this order, or it has already been released or shipped. Reload the order and pick again. | `sales.errors.SO_SHIP_NOT_RESERVED` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_SHIP_ORDER_NOT_SHIPPABLE` | Order {0} is a {1}, so it cannot be shipped. Only a confirmed or partially shipped order can. | `sales.errors.SO_SHIP_ORDER_NOT_SHIPPABLE` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_STATUS_NOT_EDITABLE` | The status cannot be edited directly ({0} → {1}); use the transition buttons on the order page. | `sales.errors.SO_STATUS_NOT_EDITABLE` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SO_TRANSITION_NOT_ALLOWED` | An order in state {0} cannot move to {1}. The allowed moves are listed on the order page. | `sales.errors.SO_TRANSITION_NOT_ALLOWED` | `app/sales/orders/salesOrderErrorCodes.ts` |
| `SOD_PAYEE_AND_PAY` | Segregation of duties: you created supplier {0}, so you cannot be the one to pay it. Ask another holder of Finance (edit) to record this payment. | `finance.errors.SOD_PAYEE_AND_PAY` | `app/finance/financeErrorCodes.ts` |
| `SOD_POST_AND_CLOSE` | Segregation of duties: you posted a manual journal entry in the period ending {0}, so you cannot be the one to close it. Ask another holder of Finance (edit) to close this period. | `finance.errors.SOD_POST_AND_CLOSE` | `app/finance/financeErrorCodes.ts` |
| `SOFT_DELETE_NO_DIRECT_UPDATE` | This record can only be deleted through the deletion function, which records who and why. {1} ({0}) was not. | `deletion.errors.SOFT_DELETE_NO_DIRECT_UPDATE` | `app/components/inventory/deletionErrorCodes.ts` |
| `SOURCE_PROVENANCE_NOT_AT_INTAKE` | A reason given at receiving does not carry recorded-by/recorded-at — those two columns mean “explained AFTER the fact”, and the intake’s own provenance is created-by. | `purchasing.errors.SOURCE_PROVENANCE_NOT_AT_INTAKE` | `app/purchasing/purchasingErrorCodes.ts` |
| `SOURCE_PROVENANCE_REQUIRED` | Explaining a receipt after the fact is a new statement about the past — it must record who and when. Use the source panel on the batch page; do not update the row directly. (Batch {0}) | `purchasing.errors.SOURCE_PROVENANCE_REQUIRED` | `app/purchasing/purchasingErrorCodes.ts` |
| `SOURCE_REASON_EXPLANATION_REQUIRED` | The reason “{0}” requires a written explanation — an unexplained “other” says nothing. | `purchasing.errors.SOURCE_REASON_EXPLANATION_REQUIRED` | `app/purchasing/purchasingErrorCodes.ts` |
| `STATE_CHANGE_LOSS_NOT_ZERO` | {0} removes no mass, so its loss can only be 0, but {1} was entered. Either the wrong operation was picked, or this run is really a transforming one. | `processing.errors.STATE_CHANGE_LOSS_NOT_ZERO` | `app/operation/errorCodes.ts` |
| `STATE_CHANGE_OUTPUT_INPUT_UNSUPPORTED` | {0} currently accepts inbound batches only. Safety states are recorded for inbound batches alone — the output-side table does not exist yet — so "change the state" has nowhere to be written on an output batch, and letting it through would produce a run that changed nothing. | `processing.errors.STATE_CHANGE_OUTPUT_INPUT_UNSUPPORTED` | `app/operation/errorCodes.ts` |
| `STATEMENT_ALREADY_RECONCILED` | Statement {0} is already reconciled | `bank.errors.STATEMENT_ALREADY_RECONCILED` | `app/finance/bankErrorCodes.ts` |
| `STATEMENT_DOES_NOT_TIE` | The statement for {0} does not tie: opening + charges − credits − receipts applied is {1} away from the closing balance of {2}. It has not been issued. The discrepancy is in our own arithmetic — sending it would turn an internal error into a customer dispute. | `statements.errors.STATEMENT_DOES_NOT_TIE` | `app/finance/statements/statementErrorCodes.ts` |
| `STATEMENT_NOT_BALANCED` | Opening plus the line total comes to {0}, but the closing balance you entered is {1} | `bank.errors.STATEMENT_NOT_BALANCED` | `app/finance/bankErrorCodes.ts` |
| `STATEMENT_NOT_FOUND` | Statement not found | `bank.errors.STATEMENT_NOT_FOUND` | `app/finance/bankErrorCodes.ts` |
| `STATEMENT_NOT_RECONCILED` | Statement {0} is not reconciled | `bank.errors.STATEMENT_NOT_RECONCILED` | `app/finance/bankErrorCodes.ts` |
| `STATEMENT_PERIOD_FUTURE` | A statement cannot end on {0} — that is in the future, and today is {1}. A statement of a period that has not happened is a projection, not a record. | `statements.errors.STATEMENT_PERIOD_FUTURE` | `app/finance/statements/statementErrorCodes.ts` |
| `STATEMENT_PERIOD_INVALID` | The period runs backwards: {0} to {1}. | `statements.errors.STATEMENT_PERIOD_INVALID` | `app/finance/statements/statementErrorCodes.ts` |
| `STATEMENT_PERIOD_REQUIRED` | A statement needs both a start and an end date. | `statements.errors.STATEMENT_PERIOD_REQUIRED` | `app/finance/statements/statementErrorCodes.ts` |
| `STATEMENT_RECONCILED` | This statement is already reconciled | `bank.errors.STATEMENT_RECONCILED` | `app/finance/bankErrorCodes.ts` |
| `STATEMENT_SUPERSEDE_REASON_REQUIRED` | Statement {0} already covers this period for {1}. Re-issuing replaces it with a new statement, so a reason is required — the earlier one stays on file marked superseded. | `statements.errors.STATEMENT_SUPERSEDE_REASON_REQUIRED` | `app/finance/statements/statementErrorCodes.ts` |
| `STATEMENT_SUPERSEDED` | Statement {0} has been superseded ({1}), so no further version of it can be issued. Earlier versions remain readable — superseded means this one is finished, not that it never happened. | `statements.errors.STATEMENT_SUPERSEDED` | `app/finance/statements/statementErrorCodes.ts` |
| `STK_HOLD_EXCEEDS_AVAILABLE` | Cannot hold {0} — only {1} is available at this location. Holding does not create stock; it only reserves what is already there. | `stock.errors.STK_HOLD_EXCEEDS_AVAILABLE` | `app/components/inventory/stockErrorCodes.ts` |
| `STK_NEGATIVE_BUCKET` | This would take {2} of {1} stock on batch {0} below zero. The ledger refuses to let any status bucket go negative. | `stock.errors.STK_NEGATIVE_BUCKET` | `app/components/inventory/stockErrorCodes.ts` |
| `STK_ONE_BATCH` | A hold applies to exactly one batch. | `stock.errors.STK_ONE_BATCH` | `app/components/inventory/stockErrorCodes.ts` |
| `STK_QTY_INVALID` | The quantity {0} is not usable — it must be a positive number. | `stock.errors.STK_QTY_INVALID` | `app/components/inventory/stockErrorCodes.ts` |
| `STK_REASON_REQUIRED` | A reason is required to hold stock. | `stock.errors.STK_REASON_REQUIRED` | `app/components/inventory/stockErrorCodes.ts` |
| `STK_RELEASE_EXCEEDS_HELD` | Cannot release {0} — only {1} is on hold at this location. | `stock.errors.STK_RELEASE_EXCEEDS_HELD` | `app/components/inventory/stockErrorCodes.ts` |
| `STOCKTAKE_CANCEL_REASON_REQUIRED` | A reason is required to cancel stocktake {0}. | `stocktakes.errors.STOCKTAKE_CANCEL_REASON_REQUIRED` | `app/stocktakes/stocktakeErrorCodes.ts` |
| `STOCKTAKE_NO_HARD_DELETE` | Stocktake {0} cannot be permanently deleted — cancel it instead, which records who and why. | `deletion.errors.STOCKTAKE_NO_HARD_DELETE` | `app/components/inventory/deletionErrorCodes.ts` |
| `STOCKTAKE_NOT_FOUND` | Stocktake not found | `stocktakes.errors.STOCKTAKE_NOT_FOUND` | `app/stocktakes/stocktakeErrorCodes.ts` |
| `STOCKTAKE_NOT_OPEN` | Stocktake is not open (status: {0}) | `stocktakes.errors.STOCKTAKE_NOT_OPEN` | `app/stocktakes/stocktakeErrorCodes.ts` |
| `SUMMARY_REQUIRED` | A written summary is required before submitting | `reviews.errors.SUMMARY_REQUIRED` | `app/hr/reviews/reviewErrorCodes.ts` |
| `SUPPLIER_MISMATCH` | Batch {1} belongs to a different supplier than order {0} | `purchasing.errors.SUPPLIER_MISMATCH` | `app/purchasing/purchasingErrorCodes.ts` |
| `SUPPLIER_NOT_FOUND` | That supplier no longer exists ({0}). | `contacts.errors.SUPPLIER_NOT_FOUND` | `app/sales/customers/contactErrorCodes.ts` |
| `SUPPLIER_QUALIFICATION_EXPIRED` | Receiving from supplier {0} is blocked: certificate {1} expired on {2}. Renew it under Suppliers → Compliance | `purchasing.errors.SUPPLIER_QUALIFICATION_EXPIRED` | `app/purchasing/purchasingErrorCodes.ts` |
| `SUPPLIER_REQUIRED_FOR_UNPAID` | A supplier is required for unpaid expenses | `expense.errors.SUPPLIER_REQUIRED_FOR_UNPAID` | `app/finance/expenseErrorCodes.ts` |
| `SYSTEM_START_NOT_SET` | The system start date has not been set, so the first financial year cannot be worked out. Set it under Settings → Finance. | `hr.errors.SYSTEM_START_NOT_SET` | `app/hr/hrErrorCodes.ts` |
| `TASK_CREATOR_NOT_AN_EMPLOYEE` | Your login is not linked to an employee record, so {0} would have no owner. Link the account under HR first. | `tasks.opErrors.TASK_CREATOR_NOT_AN_EMPLOYEE` | `app/tools/tasks/taskErrorCodes.ts` |
| `TASK_HARD_DELETE_REFUSED` | Tasks are not hard-deleted — {0} is removed by soft delete, so the change history keeps pointing at something real. | `tasks.opErrors.TASK_HARD_DELETE_REFUSED` | `app/tools/tasks/taskErrorCodes.ts` |
| `TASK_NODE_HAS_CHILDREN` | "{0}" has {1} sub-step(s). Delete those first — they will not be removed along with it. | `tasks.opErrors.TASK_NODE_HAS_CHILDREN` | `app/tools/tasks/taskErrorCodes.ts` |
| `TASK_NODE_SHAPE_REFUSED` | A step can only sit under a top-level step of the same task — steps go one level deep, and cannot move to another task. | `tasks.opErrors.TASK_NODE_SHAPE_REFUSED` | `app/tools/tasks/taskErrorCodes.ts` |
| `TASK_OWNER_CANNOT_LEAVE` | The owner cannot leave their own task — that would be a transfer of ownership. | `tasks.opErrors.TASK_OWNER_CANNOT_LEAVE` | `app/tools/tasks/taskErrorCodes.ts` |
| `TASK_OWNER_NOT_AN_EMPLOYEE` | The owner of {0} has no employee record with a login, so nobody would be able to edit it once it became a team task. | `tasks.opErrors.TASK_OWNER_NOT_AN_EMPLOYEE` | `app/tools/tasks/taskErrorCodes.ts` |
| `TASK_PARTICIPANT_NO_LOGIN` | That employee has no login account yet, so they could be shown on this task and still never be able to open it. Link their account in HR first. | `tasks.opErrors.TASK_PARTICIPANT_NO_LOGIN` | `app/tools/tasks/taskErrorCodes.ts` |
| `TASK_PARTICIPANT_REMOVE_DENIED` | Only the owner, or whoever added them, can take someone off this task. | `tasks.opErrors.TASK_PARTICIPANT_REMOVE_DENIED` | `app/tools/tasks/taskErrorCodes.ts` |
| `TASK_PARTICIPANT_REMOVER_NOT_ON_TASK` | You have left this task, so you can no longer take others off it. | `tasks.opErrors.TASK_PARTICIPANT_REMOVER_NOT_ON_TASK` | `app/tools/tasks/taskErrorCodes.ts` |
| `TASK_TYPE_LOCKED_PARTICIPANTS` | {1} other person/people have been on {0}. Making it personal would leave them unable to read what they worked on. | `tasks.opErrors.TASK_TYPE_LOCKED_PARTICIPANTS` | `app/tools/tasks/taskErrorCodes.ts` |
| `TASK_TYPE_TRANSITION_UNKNOWN` | Unrecognised task type change ({0} → {1}). | `tasks.opErrors.TASK_TYPE_TRANSITION_UNKNOWN` | `app/tools/tasks/taskErrorCodes.ts` |
| `TAX_CODE_INACTIVE` | Tax code {0} has been retired and cannot be put on new documents. Existing documents keep it — what was filed under it does not change. | `finance.errors.TAX_CODE_INACTIVE` | `app/finance/financeErrorCodes.ts` |
| `TAX_CODE_REQUIRED` | A tax code is required — a rate alone cannot say whether 0% means zero-rated, exempt or out of scope, and those go in different boxes of the return. | `finance.errors.TAX_CODE_REQUIRED` | `app/finance/financeErrorCodes.ts` |
| `TAX_CODE_UNKNOWN` | There is no tax code "{0}". Pick one from the tax code list. | `finance.errors.TAX_CODE_UNKNOWN` | `app/finance/financeErrorCodes.ts` |
| `TAX_CODE_WRONG_SIDE` | Tax code {0} is not an {1}-side code. An input code on a sales document (or an output code on a purchase) still computes a figure — it just puts it in a box it does not belong in. | `finance.errors.TAX_CODE_WRONG_SIDE` | `app/finance/financeErrorCodes.ts` |
| `TAX_DATE_REQUIRED` | A date is required to resolve the rate for tax code {0} — GST rates change by statute, so the rate depends on the document’s own date. | `finance.errors.TAX_DATE_REQUIRED` | `app/finance/financeErrorCodes.ts` |
| `TAX_RATE_NOT_FOUND` | No GST rate is on file for tax code {0} on {1}. The system will not guess a rate or fall back to the nearest one — enter the rate that applied on that date. | `finance.errors.TAX_RATE_NOT_FOUND` | `app/finance/financeErrorCodes.ts` |
| `TEMPLATE_CURRENCY_MISMATCH` | Template {0} is in {1}, this order is in {2}. A fixed instalment is a negotiated amount, not a converted one — it is not restated at today’s rate. Use a template in {2}, or enter the plan on the order directly | `purchasing.errors.TEMPLATE_CURRENCY_MISMATCH` | `app/purchasing/purchasingErrorCodes.ts` |
| `TEMPLATE_CURRENCY_REQUIRED` | Template {0} has a fixed-amount instalment, so it must declare a currency — a template belongs to no order, so nothing else can tell you what that amount is in | `purchasing.errors.TEMPLATE_CURRENCY_REQUIRED` | `app/purchasing/purchasingErrorCodes.ts` |
| `TEMPLATE_CURRENCY_UNDECLARED` | Template {0} has a fixed-amount instalment but no declared currency, so there is nothing to copy — declare the currency on the template, or use percentages | `purchasing.errors.TEMPLATE_CURRENCY_UNDECLARED` | `app/purchasing/purchasingErrorCodes.ts` |
| `TEMPLATE_NOT_FOUND` | Payment term template not found or inactive | `purchasing.errors.TEMPLATE_NOT_FOUND` | `app/purchasing/purchasingErrorCodes.ts` |
| `TERMS_EVENT_UNKNOWN` | Instalment {0}: unknown payment milestone “{1}”. | `purchasing.errors.TERMS_EVENT_UNKNOWN` | `app/purchasing/purchasingErrorCodes.ts` |
| `TERMS_INVALID` | Invalid payment terms: {0} | `invoice.errors.TERMS_INVALID` | `app/finance/invoiceErrorCodes.ts` |
| `TERMS_PCT_EXCEEDS` | Instalment percentages total {0}% — more than 100% | `purchasing.errors.TERMS_PCT_EXCEEDS` | `app/purchasing/purchasingErrorCodes.ts` |
| `TERMS_SEQ_INVALID` | Instalments must be numbered consecutively from 1 | `purchasing.errors.TERMS_SEQ_INVALID` | `app/purchasing/purchasingErrorCodes.ts` |
| `TRANSFER_ALREADY_REVERSED` | This transfer is already reversed | `finance.errors.TRANSFER_ALREADY_REVERSED` | `app/finance/paymentErrorCodes.ts` |
| `TRANSFER_AMOUNTS_UNEQUAL` | A same-currency transfer must have equal sides (got {0} and {1}) | `finance.errors.TRANSFER_AMOUNTS_UNEQUAL` | `app/finance/paymentErrorCodes.ts` |
| `TRANSFER_NOT_FOUND` | Transfer not found | `finance.errors.TRANSFER_NOT_FOUND` | `app/finance/paymentErrorCodes.ts` |
| `TRANSFER_SAME_ACCOUNT` | Source and destination are the same account ({0}) | `finance.errors.TRANSFER_SAME_ACCOUNT` | `app/finance/paymentErrorCodes.ts` |
| `TRIAL_BALANCE_UNBALANCED` | Trial balance does not balance ({0} vs {1}) | `finance.errors.TRIAL_BALANCE_UNBALANCED` | `app/finance/financeErrorCodes.ts` |
| `UNIT_NOT_KG` | Batch {0} is not in kg — allocation assumes kg | `processing.errors.UNIT_NOT_KG` | `app/operation/errorCodes.ts` |
| `VARIANCE_AMOUNT_INVALID` | Item {0}: the amount must be a number and cannot be zero | `bank.errors.VARIANCE_AMOUNT_INVALID` | `app/finance/bankErrorCodes.ts` |
| `VARIANCE_ITEM_IMMUTABLE` | A recorded explanation cannot be edited or deleted. Reopen the statement and reconcile again. | `bank.errors.VARIANCE_ITEM_IMMUTABLE` | `app/finance/bankErrorCodes.ts` |
| `VARIANCE_ITEMS_INVALID` | The variance items were not sent as a list | `bank.errors.VARIANCE_ITEMS_INVALID` | `app/finance/bankErrorCodes.ts` |
| `VARIANCE_KIND_INVALID` | Item type "{0}" is not one this system knows | `bank.errors.VARIANCE_KIND_INVALID` | `app/finance/bankErrorCodes.ts` |
| `VARIANCE_NOT_APPLICABLE` | The bank and your books already agree, so there is no difference to explain. Remove the items. | `bank.errors.VARIANCE_NOT_APPLICABLE` | `app/finance/bankErrorCodes.ts` |
| `VARIANCE_NOTE_REQUIRED` | Item {0}: say what this item is | `bank.errors.VARIANCE_NOTE_REQUIRED` | `app/finance/bankErrorCodes.ts` |
| `VARIANCE_UNEXPLAINED` | The difference is {0} but the items you listed come to {1}. Every item is kept — what is missing is {0} minus {1}. List the rest, or correct an amount. | `bank.errors.VARIANCE_UNEXPLAINED` | `app/finance/bankErrorCodes.ts` |
| `WHT_DATE_REQUIRED` | A date is needed to resolve the rate for {0}. | `wht.errors.WHT_DATE_REQUIRED` | `app/finance/whtErrorCodes.ts` |
| `WHT_FILED_REFERENCE_REQUIRED` | Enter the IRAS reference for this filing ({0}). A remittance that cannot say where it came from cannot be reconciled later. | `wht.errors.WHT_FILED_REFERENCE_REQUIRED` | `app/finance/whtErrorCodes.ts` |
| `WHT_FREIGHT_NOT_SUPPORTED` | Whether freight paid to a non-resident is withheld from depends on whether the payee is a shipping or air line (exempt) or a forwarder providing agency services. Nobody has made that judgement, so this path refuses rather than guessing ({0}). | `wht.errors.WHT_FREIGHT_NOT_SUPPORTED` | `app/finance/whtErrorCodes.ts` |
| `WHT_NATURE_INACTIVE` | This nature of payment is no longer in use: {0}. | `wht.errors.WHT_NATURE_INACTIVE` | `app/finance/whtErrorCodes.ts` |
| `WHT_NATURE_REQUIRED` | This payee is a non-resident, so the nature of this payment must be stated. If withholding genuinely does not apply, choose "Not subject to withholding" — do not leave it blank. | `wht.errors.WHT_NATURE_REQUIRED` | `app/finance/whtErrorCodes.ts` |
| `WHT_NATURE_UNKNOWN` | Unknown nature of payment: {0}. | `wht.errors.WHT_NATURE_UNKNOWN` | `app/finance/whtErrorCodes.ts` |
| `WHT_NOTHING_TO_REMIT` | There is nothing outstanding for {0}. It may already have been remitted — a top-up is a new remittance, not an edit to the old one. | `wht.errors.WHT_NOTHING_TO_REMIT` | `app/finance/whtErrorCodes.ts` |
| `WHT_ON_PAID_EXPENSE_UNSUPPORTED` | An expense that attracts withholding tax cannot be recorded as already paid. Record it as unpaid, then pay it — the withholding happens at the payment, where there is exactly one implementation of the split. | `wht.errors.WHT_ON_PAID_EXPENSE_UNSUPPORTED` | `app/finance/whtErrorCodes.ts` |
| `WHT_PAYEE_IS_RESIDENT` | This supplier is recorded as a Singapore tax resident, so no tax is withheld from payments to them ({1}). | `wht.errors.WHT_PAYEE_IS_RESIDENT` | `app/finance/whtErrorCodes.ts` |
| `WHT_PAYEE_NOT_A_SUPPLIER` | A withholding decision can only be recorded against a supplier on file. Employee reimbursements and free-text payees are outside this path ({0}). | `wht.errors.WHT_PAYEE_NOT_A_SUPPLIER` | `app/finance/whtErrorCodes.ts` |
| `WHT_PERIOD_REQUIRED` | Choose the withholding month being remitted. | `wht.errors.WHT_PERIOD_REQUIRED` | `app/finance/whtErrorCodes.ts` |
| `WHT_PREPAYMENT_NOT_SUPPORTED` | A deposit to a non-resident is itself a withholding event, and it happens before any expense document exists. That path is not built ({0}). | `wht.errors.WHT_PREPAYMENT_NOT_SUPPORTED` | `app/finance/whtErrorCodes.ts` |
| `WHT_RATE_NOT_FOUND` | No withholding rate is on file for {0} on {1}. Rates are statutory facts with dates — the system refuses rather than reaching for the nearest one. | `wht.errors.WHT_RATE_NOT_FOUND` | `app/finance/whtErrorCodes.ts` |
| `WHT_REMIT_BANK_NOT_BASE` | IRAS is paid in the base currency, and account {0} is held in {1}. Convert first — that conversion is its own transaction. | `wht.errors.WHT_REMIT_BANK_NOT_BASE` | `app/finance/whtErrorCodes.ts` |
| `WHT_REMIT_DATE_BEFORE_PERIOD` | The payment date {0} is before the withholding month {1} — tax that has not been withheld yet cannot be remitted. | `wht.errors.WHT_REMIT_DATE_BEFORE_PERIOD` | `app/finance/whtErrorCodes.ts` |
| `WHT_REMIT_DATE_REQUIRED` | State the day the money was paid to IRAS ({0}). | `wht.errors.WHT_REMIT_DATE_REQUIRED` | `app/finance/whtErrorCodes.ts` |
| `WHT_REMITTANCE_IMMUTABLE` | A remittance is a thing that happened and cannot be edited ({0}). To correct one, reverse its journal entry. | `wht.errors.WHT_REMITTANCE_IMMUTABLE` | `app/finance/whtErrorCodes.ts` |
| `WHT_RESIDENCE_NOT_STATED` | This supplier has not stated a tax residence. Set it on the supplier record first, then record this document. | `wht.errors.WHT_RESIDENCE_NOT_STATED` | `app/finance/whtErrorCodes.ts` |
| `WHT_TREATY_RATE_ABOVE_STATUTORY` | A treaty rate can only reduce, never increase: {1}% was given for {0}, and the statutory rate is {2}%. | `wht.errors.WHT_TREATY_RATE_ABOVE_STATUTORY` | `app/finance/whtErrorCodes.ts` |
| `WHT_TREATY_RATE_INVALID` | A treaty rate cannot be negative ({0}). | `wht.errors.WHT_TREATY_RATE_INVALID` | `app/finance/whtErrorCodes.ts` |
| `WHT_TREATY_REF_REQUIRED` | Claiming {1}% for {0} instead of the statutory {2}% needs a certificate of residence — without one, IRAS charges the statutory rate regardless of what the treaty says. | `wht.errors.WHT_TREATY_REF_REQUIRED` | `app/finance/whtErrorCodes.ts` |
| `WHT_TREATY_REF_WITHOUT_RATE` | A certificate of residence was given without a treaty rate ({0}). Give both, or neither. | `wht.errors.WHT_TREATY_REF_WITHOUT_RATE` | `app/finance/whtErrorCodes.ts` |
| `WHT_UNALLOCATED_PAYMENT_UNSUPPORTED` | This non-resident payee has obligations that attract withholding, and a payment on account cannot say what its nature is or how much to withhold. Record the expense first, then settle it ({0} {1}). | `wht.errors.WHT_UNALLOCATED_PAYMENT_UNSUPPORTED` | `app/finance/whtErrorCodes.ts` |
| `WIP_AWAITING_ON_SALEABLE_BATCH` | Batch {0} is currently SALEABLE STOCK ({1}), and saleable stock is not waiting for any operation. To make it wait for one, first change its purpose to feed for a downstream operation. | `output.purpose.errors.WIP_AWAITING_ON_SALEABLE_BATCH` | `app/output/[id]/edit/purposeErrorCodes.ts` |
| `WIP_OPERATION_UNKNOWN` | There is no operation "{0}", or it has been deactivated. Check Settings → Operations. | `output.purpose.errors.WIP_OPERATION_UNKNOWN` | `app/output/[id]/edit/purposeErrorCodes.ts` |
| `WO_AMEND_NO_CHANGES` | Nothing changed on {0}. A silent no-op would read as though the edit had taken. | `processing.errors.WO_AMEND_NO_CHANGES` | `app/operation/errorCodes.ts` |
| `WO_AMEND_REASON_REQUIRED` | Changing the plan for {0} needs a reason. | `processing.errors.WO_AMEND_REASON_REQUIRED` | `app/operation/errorCodes.ts` |
| `WO_CANCEL_REASON_REQUIRED` | Cancelling {0} needs a reason. | `processing.errors.WO_CANCEL_REASON_REQUIRED` | `app/operation/errorCodes.ts` |
| `WO_CLOSE_REASON_REQUIRED` | Closing {0} needs a reason — closing short is legal, but the reason is what makes the variance readable later. | `processing.errors.WO_CLOSE_REASON_REQUIRED` | `app/operation/errorCodes.ts` |
| `WO_DUPLICATE_EXPECTED` | Material {0} has two expected-output rows. One per material. | `processing.errors.WO_DUPLICATE_EXPECTED` | `app/operation/errorCodes.ts` |
| `WO_DUPLICATE_MATERIAL` | Material {0} appears twice. One line per material — otherwise "planned 5t, consumed 3t and 2.5t" has no single reading. | `processing.errors.WO_DUPLICATE_MATERIAL` | `app/operation/errorCodes.ts` |
| `WO_EXPECTED_BASIS_REQUIRED` | Every expected output must say where it came from: a planner’s estimate, seeded from industry experience, or calibrated against real production. There is no default — a missed entry is a failure, not a quietly supplied value that looks like an answer. | `processing.errors.WO_EXPECTED_BASIS_REQUIRED` | `app/operation/errorCodes.ts` |
| `WO_EXPECTED_MATERIAL_NOT_FOUND` | Expected-output material {0} does not exist. | `processing.errors.WO_EXPECTED_MATERIAL_NOT_FOUND` | `app/operation/errorCodes.ts` |
| `WO_EXPECTED_NOT_FOUND` | There is no expected-output row for material {0}. | `processing.errors.WO_EXPECTED_NOT_FOUND` | `app/operation/errorCodes.ts` |
| `WO_EXPECTED_QTY_INVALID` | An expected quantity must be greater than zero. To record no expectation, leave the row out entirely — that is not the same as expecting zero. | `processing.errors.WO_EXPECTED_QTY_INVALID` | `app/operation/errorCodes.ts` |
| `WO_HAS_RUNS` | Work order {0} already has {1} processing run(s) against it, so it cannot be cancelled — close it instead. Cancelling would say it never happened, and the material really did move. | `processing.errors.WO_HAS_RUNS` | `app/operation/errorCodes.ts` |
| `WO_LINE_BELOW_CONSUMED` | Material {0}: you are setting the plan to {1}, but linked runs have already consumed {2}. A plan cannot be moved below what has already happened — reverse the run if it was recorded in error. | `processing.errors.WO_LINE_BELOW_CONSUMED` | `app/operation/errorCodes.ts` |
| `WO_LINE_NOT_FOUND` | There is no planned line for material {0}. | `processing.errors.WO_LINE_NOT_FOUND` | `app/operation/errorCodes.ts` |
| `WO_LINE_QTY_INVALID` | A planned quantity must be greater than zero. | `processing.errors.WO_LINE_QTY_INVALID` | `app/operation/errorCodes.ts` |
| `WO_MATERIAL_NOT_FOUND` | Material {0} does not exist. | `processing.errors.WO_MATERIAL_NOT_FOUND` | `app/operation/errorCodes.ts` |
| `WO_NO_LINES` | A work order needs at least one planned line — otherwise it plans nothing. | `processing.errors.WO_NO_LINES` | `app/operation/errorCodes.ts` |
| `WO_NOT_AMENDABLE` | Work order {0} is {1} — the plan can no longer be changed. | `processing.errors.WO_NOT_AMENDABLE` | `app/operation/errorCodes.ts` |
| `WO_NOT_CANCELLABLE` | Work order {0} is {1} — it has already ended. | `processing.errors.WO_NOT_CANCELLABLE` | `app/operation/errorCodes.ts` |
| `WO_NOT_DRAFT` | Work order {0} is {1} — only a draft can be released. | `processing.errors.WO_NOT_DRAFT` | `app/operation/errorCodes.ts` |
| `WO_NOT_FOUND` | Work order {0} does not exist. | `processing.errors.WO_NOT_FOUND` | `app/operation/errorCodes.ts` |
| `WO_NOT_RELEASED` | Work order {0} is {1} — only a RELEASED order can be worked against. A draft has not been agreed yet; a closed or cancelled one has already ended. | `processing.errors.WO_NOT_RELEASED` | `app/operation/errorCodes.ts` |
| `YEAR_CLOSED` | The financial year is closed: {0} falls in the year ended {1}. Reopen the YEAR first (year-end close panel) — reopening the month is not enough. | `finance.errors.YEAR_CLOSED` | `app/finance/financeErrorCodes.ts` |
| `YEAR_END_INVALID` | {0} is not the next financial year to close (expected {1}) — years close in order or retained earnings breaks | `finance.errors.YEAR_END_INVALID` | `app/finance/financeErrorCodes.ts` |

---

## S5 · Permissions

All figures below are **live**, read-only, 2026-09-07.

### The 39 capabilities

Two kinds, by the `permissions.kind` column: `module.*` (what part of the system) and
`data.*` / `action.*` (what class of value or operation).

`action.bulk_import` · `action.manage_permissions` · `data.view_banking` · `data.view_deleted` ·
`data.view_identity` · `data.view_pay` · `data.view_prices` · `data.view_reviews` ·
`data.view_sales` · `module.customers.{view,edit}` · `module.finance.{view,edit}` ·
`module.hr.{view,edit}` · `module.inbound.{view,edit}` · `module.inventory.{view,edit}` ·
`module.logistics.view` · `module.materials.{view,edit}` · `module.output.{view,edit}` ·
`module.pricing.{view,edit}` · `module.processing.{view,edit}` · `module.purchasing.{view,edit}` ·
`module.sales.{view,edit}` · `module.stocktakes.{view,edit}` · `module.suppliers.{view,edit}` ·
`module.tasks.{view,edit,view_all}`

Note `module.logistics` has **view only** — there is no `module.logistics.edit`.

### The 12 roles

| Role code | English name | Capabilities | Holders | System | Active |
|---|---|---:|---:|---|---|
| `admin` | System Administrator | 38 | 1 | **yes** | yes |
| `gm` | General Manager | 33 | 1 | no | yes |
| `cco` | Commercial & People | 28 | 1 | no | yes |
| `cfo` | CFO | 5 | 1 | no | yes |
| `finance` | Finance | 25 | 1 | no | yes |
| `procurement` | Procurement | 15 | 0 | no | yes |
| `sales` | Sales | 16 | 0 | no | yes |
| `operations` | Operations Supervisor | 15 | 1 | no | yes |
| `warehouse` | Warehouse & Field | 11 | 1 | no | yes |
| `hr` | Human Resources | 7 | 0 | no | yes |
| `auditor` | Read-only Auditor | 18 | 0 | no | yes |
| `employee` | Employee (unused) | **0** | 0 | no | yes |

`SELECT count(*) FROM roles` = 12 · `role_permissions` = 211 grants · `user_roles` = 7 rows
over **6 distinct people**. **That 6 is where the brief's "six roles" came from** — it is the
headcount, not the role count (R1).

Only `admin` is `is_system`, and `guard_system_role` (`db/tables/roles.sql:43`) refuses to
delete it, deactivate it, soft-delete it, or strip the flag — all four raise
`SYSTEM_ROLE_PROTECTED`. `guard_last_admin` on `user_roles` guards the matching failure mode:
the system can never be left with no living administrator.

### ★ Two capability findings

**1 · `module.tasks.view_all` is held by no role — not even `admin`.**
```sql
SELECT p.code FROM permissions p
 WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.permission_code = p.code);
-- → module.tasks.view_all
```
It is a real, working, fixture-tested capability (`db/functions/can_view_task.sql:14`,
fixtures 92 and 95) meaning *"read other people's personal tasks"*. It is **also absent from
the fresh-install bootstrap** (`db/tables/role_permissions.sql` has no line for it), so a new
production system starts the same way. **Not a phantom** — an administrator can grant it
through the interface. It is a decision nobody has made (Q3).

**2 · `admin` holds 38 of 39** — the missing one is exactly the above.

### Page → capability

Given in full in the S1 table (`Capability` and `Gate read at` columns). Summary of how the
gate is expressed:

| Guard form | Pages | Meaning |
|---|---:|---|
| registry `permission` | 84 | nav entry and page share **one** expression (`lib/modules.ts` §一) |
| `requireModule(MOD.x)` | via 15 scopes | the module's view code |
| `requireEditPermission('<code>.edit', …)` | write pages | edit code, checked server-side |
| `requireManagePermissions()` | `/settings/roles*` | `action.manage_permissions` |
| none | 9 | the public/personal set (S1) |

### ★ Visible page, invisible values — the distinction the manual needs

This system deliberately separates *"you cannot open this page"* from *"you can open it but
this number is withheld"*. The second is rendered as a **`<Refusal>` pill** or a
**`<RefusalBlock>`**, never as a blank or a zero (`docs/refusal-convergence.md` ①).

The most common case: `data.view_prices`. A person can hold `module.purchasing.view` and open
`/purchasing/orders`, and see the **amount column masked** — because the money is gated by a
separate `data.*` capability. `/margin` needs `data.view_prices` **and** either
`module.finance.view` or `module.processing.view` (`lib/modules.ts:472`).

`docs/refusal-convergence.md` also records a deliberate exception the manual must not
flatten: `ActorName` has four states, and *"this account has no employee record"* is a
**statement about data**, not a permission answer — it is deliberately **not** drawn as a
refusal. Teaching a reader that a data gap and a permission wall look alike would undo that.


---

## S6 · Reality check — what must NOT go in the manual

**Standard applied (R3 / S6):** "cannot be used" means *cannot be used in a **fresh production
system***. A thing that merely has no data in today's live is **not** an S6 entry — it is a
thing nobody has done yet. The two lists are kept apart below, because merging them would
delete working features from the manual.

### A · Genuine phantoms — do not document these

| # | Thing | Evidence | Verdict |
|---|---|---|---|
| **A1** | **`/brand-sampler`** | `app/brand-sampler/page.tsx:2` — *"临时页 · BRAND-1 · 用完即删"*. Not in the nav (`check-nav-routes.mjs:116` lists it as a deliberate exception), excluded from the smoke walk (`smoke-routes.mjs:95`), **connects to no database** (sample data in `./data.ts`), and its `<h1>` is Chinese. `docs/base-components.md:299` records the standing instruction to delete the whole directory. | **Omit entirely.** It is a development scratch page. |
| **A2** | **`/contracts` — nothing in the interface can create a contract** | The route is a **menu entry** (`lib/modules.ts`, `nav.contracts`, gated `module.suppliers.view`). But `app/contracts/` contains only `page.tsx` and `ContractsTables.tsx` — **no `actions.ts`, no `.insert(`, no `.update(`, no `.rpc(`**. No `INSERT INTO contracts` exists anywhere in `db/functions` or `app/` — only in fixtures 147–150. Contracts are **not** in `lib/importTables.ts`. The only contract-related RPC is `link_document_to_contract`, which attaches an *existing* contract to a document. The table *does* have an INSERT RLS policy (`db/tables/contracts.sql:120`), so the database would permit it — **there is simply no door**. Live: 0 rows. | **A menu entry leading to a page that can never have content.** The manual must not describe creating or managing a contract. See Q1 — this is the survey's most serious finding. |
| **A3** | **The `employee` role** | `name_en = 'Employee (unused)'`, **0 capabilities**, 0 holders. Holding it grants nothing; a person with only this role lands on `/welcome`. | Per R1 it is an S6 finding, **not** a Part 4 entry. |

### B · Built and usable — merely never used yet. **These belong in the manual.**

| Thing | Live rows | Why it is not a phantom |
|---|---:|---|
| Bank import & reconciliation | `bank_statements` = **2** | ★ see below |
| Expense claims (`CLM-`) | 0 | `decide_expense_claim` / `withdraw_expense_claim` exist; pages exist; RLS in place |
| Medical claims (`MC-`) | 0 | `decide_medical_claim` / `pay_medical_claim` exist |
| Leave requests (`LV-`) | 0 | `submit_leave_request` / `decide_leave_request` / `cancel_leave_request` exist, with the richest refusal set in HR |
| `module.tasks.view_all` | granted to 0 roles | working capability; an administrator can grant it (S5) |

★ **The brief's own S6 example does not survive its own standard.** The brief says *"routes
with no reachable data (the bank reconcile route is one already on record)"*. Measured:
`/finance/bank/import` renders a real import form backed by `lib/bankCsv.ts`;
`preview_reconcile_statement`, `reconcile_statement` and `unreconcile_statement` all exist in
`db/functions`; and live holds **2 bank statements**, so the feature **has actually run**.
It is a working feature and belongs in the manual. Recording this because R3 was introduced
precisely to stop "today's live has little data here" from being read as "this does not work".

### C · Built but switched off — document it **with its precondition**

**Two-level purchase approval.** `approvals_enabled` defaults to **`false`**
(`db/tables/finance_settings.sql:56`), and `approvals_enabled()` returns
`COALESCE(…, false)`. While off, `approve_purchase_order` and `reject_purchase_order` refuse
with **`APPROVALS_NOT_ENABLED`** — deliberately, so nobody believes an approval flow is running
when it is not (`db/functions/approve_purchase_order.sql:29-32`).

Live is configured but off: `approvals_enabled = false`, level 1 = `finance`, level 2 = `cfo`,
threshold = 1000. In a fresh production system it is off with nothing configured, and
`purchase_orders.approval_status` defaults to `'approved'` — i.e. **every PO is born approved
until somebody turns approvals on**.

The manual must state the precondition rather than describing approval as a normal step. This
is the clearest case in the survey of a feature that is neither a phantom nor simply unused.

### D · Not S6, but the manual must not promise it

**`partially_shipped` sales orders have no manual way out** (S3/P4) and **`/finance/bank`,
`/inventory/reports/*`, `/tools/pricing/*` and `/hr/leave/*` sub-pages have no menu entry**
(S1). Both are real behaviour to be documented, not omissions.


---

## S7 · Terminology

All strings below are read from `messages/en.ts` — never from the interface, never translated
back from `zh.ts` (as required).

The catalogue holds **6,516 English string entries** across 93 top-level namespaces.

### ★ Finding 1 — 77 concepts are rendered with more than one casing or spelling

This is the finding that most directly threatens rule **1.3** ("interface names are quoted
verbatim so a reader can match the manual to the screen one-to-one"). If the manual writes
*click "Balance Sheet"* and the menu says *Balance sheet*, one-to-one matching fails.

Method: flatten the catalogue, group entries by lower-cased value, report groups holding more
than one distinct surface form. Restricted to strings of 3–40 characters (labels, not prose).

The ones that are genuine on-screen labels, and therefore need Tim's ruling before the writing
cut (Q7):

| Concept | Forms in the catalogue | Example keys |
|---|---|---|
| Balance sheet | `Balance sheet` / `Balance Sheet` | `finance.subnav.balanceSheet`, `pack.bsHeading`, `finance.bsTitle` |
| Metal prices | `Metal prices` / `Metal Prices` | `nav.metalPrices`, `metalPrices.listTitle`, `breadcrumb.metal-prices` |
| Payment terms | `Payment terms` / `Payment Terms` | `purchasing.subnav.templates`, `suppliers.form.paymentTerms`, `logistics.colPaymentTerms` |
| Output batch | `Output batch` / `Output Batch` | `margin.colBatch`, `processing.detail.colOutputBatch` |
| Net profit | `Net profit` / `Net Profit` | `finance.netProfit`, `pack.netProfit` |
| Total assets | `Total assets` / `Total Assets` | `finance.totalAssets`, `pack.totalAssets` |
| Journal entry | `journal entry` / `Journal entry` / `Journal Entry` | `gst.docKind.journal_entry`, `assay.journalLink`, `auditTrail.kind.journal_entry` |
| Credit note | `credit note` / `Credit note` | `gst.docKind.credit_note`, `cn.badge`, `cn.colCode` |
| Valid from | `Valid from` / `Valid From` | `suppliers.compliance.validFrom`, `logistics.quoteValidFrom` |
| Superseded by {code} | `superseded by {code}` / `Superseded by {code}` | `pack.supersededBy`, `assay.supersededBy` |

A further ~67 pairs are **status words** appearing both capitalised (as a badge) and lower-case
(mid-sentence): `Active/active`, `Pending/pending`, `Posted/posted`, `Reversed/reversed`,
`Done/done`, `Outstanding/outstanding`, `Current/current`, `Superseded/superseded`,
`Input/input`, `Output/output`, `Inbound/inbound`, `Deactivated/deactivated`. **Most of those
are correct** — a badge and a sentence legitimately differ. They are counted here so the
writing cut knows the 77 is not 77 defects, and so nobody re-derives the distinction.

### ★ Finding 2 — the output batch state is stored in Chinese and shown in English

`output_batches.state` stores the literal values **`库存中` / `部分售出` / `已售罄`**, which are the
primary keys of `output_batch_states` (`db/tables/output_batch_states.sql`). English is a
display column (`name_en`: `In stock` / `Partially sold` / `Sold out`), reached through
`output.state.inStock` etc. (`app/inbound/options.ts:15`).

**The CSV export writes the raw stored value, not the English one** —
`csvCell(r.state)` at `app/output/export/route.ts:112`, with the comment
*"state 导出规范存储值(机器可读)"*. The default on the create form is the literal `'库存中'`
(`app/output/new/actions.ts:34`, `NewOutputForm.tsx:184`).

**Consequence for an English-only manual:** the screen says *In stock*, and the file the
reader downloads from the same screen says *库存中*. The manual cannot quote one string for
both. This needs Tim's ruling (Q4). The mirror's own header notes changing the codes would
mean touching six places, so this is a real decision, not an oversight.

### ★ Finding 3 — two concepts carry a second name in exactly one place each

| Standard term | Occurrences | The outlier | Where |
|---|---:|---|---|
| **Supplier** | 52 | **`Equipment vendor`** | `messages/en.ts:1338`, key `…equipmentVendor` |
| **Customer** | 47 | **`Client audit report`** | `messages/en.ts:5297` and `:5309` (`pdfTitle`) — a **printed document title**, so it reaches the customer |

**Deliberately excluded — not a finding.** Keys `duplicateInputClient`, `consumeExceedsClient`,
`outputExceedsInputClient`, `lossInvalidClient` (`en.ts:2812-2816`) contain "Client" only in the
**key name**, meaning *client-side validation*. Their user-visible strings never say "client".
Reporting them would have been a false positive of exactly the kind 3.4 forbids.

### Finding 4 — **six** module roots are all labelled "Overview", through **four** different keys

| Route | Key | Renders |
|---|---|---|
| `/purchasing` | `nav.moduleOverview` | Overview |
| `/logistics` | `nav.moduleOverview` | Overview |
| `/sales` | `nav.moduleOverview` | Overview |
| `/operation` | `processing.subnav.overview` | Overview |
| `/finance` | `finance.subnav.overview` | Overview |
| `/hr` | `hr.subnav.overview` | Overview |

The shared label is intentional (`docs/nav-registry.md`, CONV-6 ⑨) — each answers *"what is
the state of this module"*. **That four keys produce one string is not** — it means changing
the wording requires finding all four, and three of them are not named `nav.*`. The manual
must disambiguate by module, since "Overview" alone names six different screens (Q7).


---

## Section 5 finding · Can a role genuinely be created without code?

### Verdict: **YES — fully, with no code change and no migration.** One caveat, one defect.

The claim Part 4 wants to make is **true**. Evidence, in the order it settles the question:

**1 · Roles are data, and the policies never name them.**
`db/tables/roles.sql:2` states the design outright: *"这是数据,不是枚举 —— 加一个角色、改一个名字、
调一次授权,都应该是界面上的 INSERT/UPDATE… 策略里永远不出现角色名"*. Every RLS policy in the
system asks `has_permission('<code>')`, which resolves through
`user_roles → role_permissions`. **No policy anywhere tests a role name**, so a new role is
indistinguishable from a built-in one to every gate in the system.

**2 · Granting is data too.** `db/tables/role_permissions.sql:2` — *"授权是数据 —— 重新分配权限
就是这张表上的 INSERT/DELETE,永远不需要改代码或做迁移"*.

**3 · Every step has a working interface path.**

| Step | Where | Mechanism |
|---|---|---|
| Create the role | `/settings/roles/new` | `createRole()` → `INSERT INTO roles` (`app/settings/accountsActions.ts:84-100`) |
| Give it capabilities | `/settings/roles/[id]` (`PermissionMatrix.tsx`) | `saveRolePermissions()` → RPC `set_role_permissions` (`accountsActions.ts:69-82`) |
| Rename / reorder / deactivate | `/settings/roles/[id]` | `updateRole()` (`accountsActions.ts:102-119`) |
| Retire it | `/settings/roles` | `softDeleteRole()` — sets `deleted_at` **and** `is_active = false` (`accountsActions.ts:121-134`) |
| Assign it to a person | `/settings/accounts` | `user_roles` |

All of it is gated by the single capability **`action.manage_permissions`**
(`requireManagePermissions()`, `app/settings/guard.tsx`), which today only `admin` holds.

### What a person would actually do, step by step

1. Sign in as someone holding `action.manage_permissions` (today: the `admin` role).
2. Go to **Settings → Roles** (`/settings/roles`) and choose to add a role.
3. Fill in the role's **code** (a stable identifier — the form states it cannot be changed
   afterwards, and `updateRole` deliberately omits it), **English name**, **Chinese name**,
   optional descriptions, and a sort order.
4. Save. The role now exists with **zero** capabilities and grants nothing.
5. Open the new role and tick capabilities in the permission matrix, then save. This calls
   `set_role_permissions`, which enforces **`EDIT_REQUIRES_VIEW`** — you cannot grant
   `module.x.edit` without `module.x.view`. The refusal is by name, not a silent fix.
6. Go to **Settings → Accounts** and assign the role to a person.

**No developer is required at any step.** No migration, no deploy, no code change.

### Caveat — the one thing a person cannot do

**The `admin` role itself cannot be created, renamed away, deactivated or deleted.**
`guard_system_role` (`db/tables/roles.sql:43-58`) raises `SYSTEM_ROLE_PROTECTED` on delete, on
deactivation, on soft-delete, and on any attempt to clear `is_system`. Paired with
`guard_last_admin` on `user_roles`, this makes "a system with no living administrator"
unreachable. `is_system` is not settable through the interface, so **a person cannot mint a
second protected role** — they can only make ordinary ones. That is a deliberate floor, not a
missing feature, and the manual should say so.

### ★ Defect found while verifying this — `createRole` returns a raw database error

`app/settings/accountsActions.ts:96-98`:
```ts
const { data, error } = await supabase.from('roles').insert({ ...form }).select('id').single()
if (error) return { error: error.message }        // ← raw
```
Compare its two siblings in the same file, which both localise:
```ts
if (error) return { error: await localize(error.message) }   // updateRole:116, softDeleteRole:130
```
**Consequence:** creating a role with a duplicate `code` (the column is `UNIQUE`) shows the
operator a raw Postgres unique-violation string instead of a sentence. This is precisely the
failure mode `docs/manual-walk-list.md` §1 exists to catch, on a path that list does not cover.
Reported, not fixed — this cut is read-only. See Q2.


---

## Section 9 · Questions for Tim — all of them

Not triaged. Each carries a recommended answer and its evidence, per the brief.

### Q1 ★ — Contracts: a menu entry to a page nothing can fill. Which way does it go?

**Evidence.** `/contracts` is a nav entry (`lib/modules.ts`, gated `module.suppliers.view`).
`app/contracts/` has no `actions.ts` and no write call. No `INSERT INTO contracts` exists in
`db/functions` or `app/` — only fixtures 147–150. Not in `lib/importTables.ts`. Live: 0 rows.
The table *does* carry an INSERT policy and a full state machine
(`draft/active/suspended/expired/terminated`), so the schema is finished and the door is missing.
Contracts are load-bearing elsewhere: `link_document_to_contract` attaches documents to them,
and pricing refuses with `PRICING_TERMS_NOT_COMMITTED` against contract terms.
**Question.** Is the contracts feature (a) unfinished and to be omitted from the manual,
(b) unfinished and to be built before the manual ships, or (c) intended to be populated by a
developer/import only?
**Recommend (a) for this manual, and log it as a build gap.** Documenting a create flow that
does not exist is the exact S6 failure. The manual can describe the read-only register once
contracts exist; today it would teach a reader to look for a button that is not there.

### Q2 — `createRole` shows a raw database error. Fix before or after the manual?

**Evidence.** `app/settings/accountsActions.ts:96-98` returns `error.message` unlocalised,
while `updateRole` (:116) and `softDeleteRole` (:130) both `await localize(...)`. `roles.code`
is `UNIQUE`, so a duplicate code shows a raw Postgres string.
**Recommend: fix it in a later cut, and do not document the error text.** It is a one-line
change of exactly the shape `docs/manual-walk-list.md` §1 was written for. Out of scope here
(read-only).

### Q3 — `module.tasks.view_all` is granted to no role at all. Should any role hold it?

**Evidence.** Held by 0 of 12 roles, including `admin`; also absent from the fresh-install
bootstrap. Fully implemented (`can_view_task.sql:14`) and fixture-tested (92, 95). It means
"read other people's **personal** tasks" — fixture 92B's message calls it *"the key kept for
things like a departed employee's tasks"*.
**Recommend: grant to nobody by default, and document it as an administrator-grantable
capability with that stated purpose.** It is a privacy boundary; the current state looks
deliberate. But it needs your word, because right now nobody can read a departed colleague's
tasks and no screen says why.

### Q4 ★ — The output batch state reads English on screen and Chinese in the export. Which does the manual quote?

**Evidence.** `output_batches.state` stores `库存中` / `部分售出` / `已售罄` (the PKs of
`output_batch_states`); English lives in `name_en`. `app/output/export/route.ts:112` exports the
**raw stored value** deliberately. The create form defaults to the literal `'库存中'`.
**Recommend: quote the English on screen, and add one sentence warning that the CSV contains
the Chinese codes.** Changing the stored codes touches six places by the mirror's own count —
too big to ride along with a manual. But an English-only manual that silently omits this will
be contradicted by the first file anyone downloads.

### Q5 — Approvals are off by default. How prominent should that be?

**Evidence.** `approvals_enabled` defaults `false`; `approve_purchase_order` refuses
`APPROVALS_NOT_ENABLED`; `purchase_orders.approval_status` defaults `'approved'`. Live is
configured (level 1 `finance`, level 2 `cfo`, threshold 1000) but **switched off**.
**Recommend: document approval as an optional control with its switch named, not as a step in
the purchase process.** Writing it into P2's normal path would teach every reader to expect an
approval that will not happen.

### Q6 — 121 database refusals have no app-side handler. Localise which?

**Evidence.** 852 DB codes vs 744 registered app-side; 689 overlap, 42 handled by a
hand-written `switch`, **121 unreferenced**. Of those, ~29 are immutability guards no ordinary
path reaches. Person-reachable-looking ones are listed in S4.
**Recommend: localise the ~14 named in S4 in a later cut; leave the structural guards.** For
the manual: do not document any of the 121 — if one fires today the reader sees a raw code,
and a manual quoting a raw code teaches people to expect it.

### Q7 ★ — 77 concepts have two surface forms, and six pages are all called "Overview". Rule?

**Evidence.** S7 Findings 1 and 4. Rule 1.3 requires verbatim quoting.
**Recommend: the manual quotes whatever the screen says today, verbatim, even where that is
inconsistent — and this survey's list becomes a separate tidy-up cut.** Silently normalising
"Balance Sheet" to "Balance sheet" in the manual would break the one-to-one match that 1.3
exists to guarantee. For "Overview", always write it as *"Purchasing → Overview"*.

### Q8 — 20 real features have no menu entry. Manual content, or a navigation bug?

**Evidence.** S1. Includes `/inbound/receive` — a core process step — plus all of
`/inventory/reports/*`, `/tools/pricing/*`, `/finance/bank/*` and five `/hr/leave/*` pages.
**Recommend: document them with their entry point ("from Inbound, choose …"), and raise the
navigation question separately.** They are reachable and working, so they are manual content.
But a reader who loses the parent page cannot find them again, and that is worth your view.

### Q9 — Nothing transitions `contracts.status`. Dead machine, or unbuilt?

**Evidence.** A five-state CHECK exists; no RPC and no app code writes the column. Distinct
from Q1: even a contract created by SQL could never change state through the interface.
**Recommend: treat as part of Q1's answer.**

### Q10 — The real sales sequence is invoice **before** shipment. Confirm the manual says so.

**Evidence.** `ship_order` refuses `SO_SHIP_NOT_INVOICED` per line unless an issued,
non-voided `kind='order'` invoice line exists (`ship_order.sql:97-105`). The brief's ordering
("quote to shipment to invoice to cash") is the reverse.
**Recommend: document the code's order.** Flagging it because the brief stated the other one,
and a reader following the brief's order would be stopped by a refusal at step 5.

### Q11 — 42 refusals are localised by hand-written `switch` blocks the build gate cannot see.

**Evidence.** `app/hr/leave/actions.ts:19-26` and similar. `check-i18n.mjs` gates only
registered sets, so a new code added to a `switch` without a sentence fails silently.
**Recommend: register them in a later cut.** No manual impact today (they do have sentences);
recording it because it is the "second hand-copied list" shape this repo has paid for before.

### Q12 — The `employee` role: delete it, or document it?

**Evidence.** 0 capabilities, 0 holders, `name_en = 'Employee (unused)'`.
**Recommend: soft-delete it, and omit from the manual.** Per R1 it is an S6 finding. A role
that grants nothing is a trap for whoever assigns it first.

### Q13 — `partially_shipped` has no legal transition. State that as final?

**Evidence.** `set_sales_order_status.sql:34` — `WHEN 'partially_shipped' THEN false`, with the
comment that corrections go via credit note.
**Recommend: yes, state it plainly**, and put the credit-note route in the "how to undo a
mistake" slot. This is the single most likely place for a reader to get stuck.

### Q14 — `/brand-sampler` is still on the tree. Delete before the manual ships?

**Evidence.** Marked "用完即删" since BRAND-1; `docs/base-components.md:299` lists the deletion
steps. It renders a Chinese heading in an English product.
**Recommend: delete it in a later cut; omit from the manual either way.**

### Q15 — Part 4 covers all 12 roles (R1). Should the 5 unheld roles be marked as such?

**Evidence.** `procurement`, `sales`, `hr`, `auditor` have capabilities but no holders;
`employee` has neither.
**Recommend: yes — list all 12, and mark which are in use today.** R1 settled that unheld
roles are documented; marking them costs one column and stops a reader assuming a colleague
already holds one.

### Q16 — `customers.status` and `materials.status` are free text with no state machine.

**Evidence.** `db/tables/customers.sql:4` says so explicitly; neither column has a CHECK.
**Recommend: do not present either as a document status.** They are master-data attributes.
Excluded from S3's 22 for this reason.

### Q17 — Every purchase order is born `approved`. Intended?

**Evidence.** `purchase_orders.approval_status` defaults `'approved'`; `status` defaults
`'confirmed'` (not `draft`).
**Recommend: intended, given Q5 — with approvals off, "approved" is the only honest default.**
Raising it because the manual will otherwise describe a `draft` PO that the system does not
create by default.

### Q18 — "Equipment vendor" and "Client audit report" against "Supplier" and "Customer".

**Evidence.** S7 Finding 3. The second is a **printed PDF title**, so it reaches customers.
**Recommend: rename both to the standard terms in a later cut; quote them as-is for now.**


---

## What remains unsurveyed

Stated plainly so the writing cut knows the edges of this document.

| Gap | Why | What would settle it |
|---|---|---|
| The **remedy** for 565 of 744 refusals | Only a keyword heuristic was applied; classifying all 744 by hand was not done, and claiming otherwise would breach 3.1 | The writing cut walks the S4 table and writes the remedy where the sentence does not carry it |
| **Field-level labels** | S7 covers page titles, headings, status values, buttons and the label conflicts. The full field-label inventory across ~199 pages was not enumerated | A per-page extraction pass, if the writing cut needs it; the catalogue is the source either way |
| **Section-heading inventory per page** | Same reason | As above |
| Which of the **121 unhandled DB refusals** are truly reachable from a form | Establishing reachability per code means tracing each RPC to a caller; the shape-based grouping in S4 is as far as this cut went | Q6, then a targeted pass |
| **`/hr/*` process traces** | S2 covers the six flows the brief named. HR (leave, claims, payroll, reviews, attendance) has documents and refusals catalogued in S3/S4 but **no end-to-end process trace** | A follow-up pass, if Part 2 is to cover HR processes |
| Anything requiring a **running app** | `--reach` is forbidden and no browser walk was run (1.5 also forbids screenshots) | `docs/manual-walk-list.md`, by a human |

**S1–S4 — the spine — are complete.** S5, S6, S7 and the section 5 finding are complete
within the scope set by R2/R3/R5/R6.

---

## Sources

Code and mirrors at `4fef88a`. Live queried read-only on 2026-09-07 via the Management API
(`SELECT` only) for: role list and metadata, capability list, `role_permissions` counts,
`user_roles` counts, `finance_settings` approval configuration, and per-table row counts used
only to answer "has this feature ever run" (R3).

Cited for rationale, not re-derived (R5): `docs/nav-registry.md`,
`docs/refusal-convergence.md`, `docs/known-wrong-until-cutover.md`,
`docs/base-components.md`, `docs/manual-walk-list.md`, `AGENTS.md`.
