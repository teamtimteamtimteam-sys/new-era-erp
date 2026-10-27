# System map — Tim's structure rulings (2026-10-26)

This file is the repository's record of Tim's structure rulings of 2026-10-26 (SYSTEM-MAP-0). Tim's working copy is a Claude Docs document; **this file is what later cuts read**. The rulings below are copied verbatim from the SYSTEM-MAP-0 brief, Part 2. Measurements behind the three queued cuts: `docs/surveys/SYSTEM-MAP-0/readings.md`.

Queue: `docs/forward-queue.md` entry 64d (SYSTEM-MAP-1 · SYSTEM-MAP-2 · SYSTEM-MAP-3, directly before the go-live readiness group).

---

## 2.1 Ruled principles

- The menu is reorganised by seven business processes (procure-to-pay; receive-process-output; order-to-cash; record-to-report; hire-to-pay; safety and compliance; equipment and maintenance). Page URLs do not change; only menu placement changes (navigation and permission scopes are already separate, so page guards are untouched).
- EVERY SECOND-LEVEL PAGE HAS EXACTLY ONE PLACE IN THE MENU (Tim, 2026-10-26). No menu entry may belong to more than one top-level module; other modules reach it through links on related document pages. A build check enforces it: any registry entry declaring two or more modules fails the build.

## 2.2 Target top level (nine modules plus My workbench; Tools keeps only calendar and unit converter; Settings unchanged)

- My workbench (new): unified to-do, my tasks, my reviews, notifications, /me.
- Purchasing: purchase orders, suppliers, scorecards, contracts (purchase and sale, one place, list filterable by side), payment terms, receipt discrepancies, pricing (formulas, metal prices, calculator).
- Production and warehouse: inbound, inbound receive, weighbridge, inventory, locations, scan, stocktakes, materials, work orders, processing runs, WIP, handovers, blending, output, material balance, yield, data capture.
- Quality: assays, samples, COA, NCR, disputes, contamination checks.
- Sales and logistics: quotes, sales orders, shipments, customers, commissions, containers, forwarders, lanes, shipping, freight documents.
- Finance: the existing six groups including self-approved; freight documents leave the finance menu.
- People: employees, organisation, attendance, overtime, leave, payroll, claims (medical and general in one entry, two kinds; approval rules unchanged), training, reviews, KPI.
- Safety and compliance: incidents, inspections, environment, compliance packs, company licences, storage safety, certificates of destruction, supplier certificates overview.
- Equipment: equipment register, reliability, instruments and gateways, calibration, operation types, spare parts. Fixed assets stay in Finance; the two keep their existing cross-links.

## 2.3 The nine entries that today belong to several modules, and their single home

/inbound and /inbound/receive, /output, /operation/weighbridge -> Production and warehouse; /hr/overtime -> People; /sales/commissions and /finance/freight -> Sales and logistics; /finance/self-approved -> Finance; /settings/change-history -> Settings. Pricing appears only under Purchasing (sales reaches it from quotes and orders); contracts only under Purchasing (sales contracts reached from customer and sales-order pages); freight only under Sales and logistics (payables and payments link to it).

## 2.4 The twelve rulings (all as proposed)

(1) reorganise the menu as above, URLs unchanged; (2) Quality is its own top-level module; (3) pricing moves from Tools to Purchasing only; (4) one contracts module under Purchasing; (5) medical and general claims share one entry with two kinds; (6) freight documents move to Sales and logistics only; (7) company licences and storage safety move to Safety and compliance; (8) Equipment is its own top-level module, fixed assets stay in Finance; (9) a new My workbench lists only what is waiting for the reader (all approval types in one list, role reminders, my tasks, reviews due, unread notifications), supports bulk actions, and absorbs three registered gaps (PO list cannot show approval status; general expense claims missing from reminders; payment-requests default filter mixing awaiting-approval with approved); (10) the home page stays quiet and adds only a to-do count linking to the workbench; (11) the reminders page stays as a company-wide exceptions overview, moved under My workbench; (12) every document detail page gets an upstream/downstream bar covering four chains, built on the existing related-records pages:
   - purchasing: purchase order -> inbound batch -> assay -> pricing -> payable -> payment request -> payment -> bank reconciliation
   - processing: work order -> processing run (input batches -> output batches) -> cost allocation
   - sales: quote -> sales order -> reservation -> shipment and container -> invoice -> receipt, plus credit notes
   - people: attendance, overtime, leave -> payroll period -> payroll payment

Queue, in this order, directly before the go-live readiness group: SYSTEM-MAP-1 menu reorganisation and the single-home build check (no migration expected; carries the open default-view question from 1.3); SYSTEM-MAP-2 My workbench (a "waiting for whom" query, migration expected); SYSTEM-MAP-3 the upstream/downstream bar (scope set by Part 3's measurement).

---

## Open questions the measurement raised (SYSTEM-MAP-0) — ✅ all five answered on 2026-10-27, see the next section (1 → D1, 2 → D2/Q2, 3 → D3, 4 → D4/Q3/Q4, 5 → built as Workbench entries in SYSTEM-MAP-1)

Measured in SYSTEM-MAP-0 Part 3 (`docs/surveys/SYSTEM-MAP-0/readings.md` §3). Listed here so SYSTEM-MAP-1 does not start on a guess:

1. **Default view when the last filter is cleared** — carried from TF-3 (`docs/known-issues.md` SAVED-VIEW-DEFAULT-RETURNS-WHEN-LAST-FILTER-CLEARED); ruling pending, to be asked before SYSTEM-MAP-1 starts.
2. **`/finance/claims` (the general expense-claim queue)** — 2.2 puts "claims (medical and general in one entry, two kinds)" under People and keeps Finance's "existing six groups", in which `/finance/claims` sits (Payables). Which menu holds the general-claims queue, and whether "one entry" means one page listing both kinds (today `/hr/claims` lists medical claims only), is not stated.
3. **Reliability, calibration and the capture inbox are not menu rows today** (`parent` entries: reliability under `/operation/equipment`, calibration and `/operation/capture/inbox` under `/operation/devices`). 2.2 names reliability and calibration as Equipment entries and "data capture" under Production — whether they become menu rows, and whether the capture inbox follows data capture (Production) or its current parent (Equipment), is not stated.
4. **Three 2.2 items have no list page today**: certificates of destruction (issued per inbound batch; only `/inbound/[id]/cod/pdf`), spare parts (a panel on `/operation/equipment/[id]`), supplier certificates overview (no page). Menu rows for them need a page; SYSTEM-MAP-1 is "no migration expected" but a new list page is new code.
5. **My workbench entries** — `/me`, `/my-reviews`, `/notifications` are not registry entries today (avatar menu and phone drawer only); the unified to-do page does not exist yet (SYSTEM-MAP-2).

---

## SYSTEM-MAP-1 rulings (Tim, 2026-10-27) — verbatim

From the SYSTEM-MAP-1 brief, scope D:

- D1. Default view: when the last filter is cleared, the list shows the plain list and does not return to the reader's default view (all 28 saved-view toolbars).
- D2. Claims: one "Claims" entry under People with two kinds, medical and general (ruling 5 of 2026-10-26). /hr/claims and /finance/claims keep their URLs and approval rules; the entry is a page that lists both kinds, each row linking to its existing detail and decision page. Finance approvers reach general claims from People until SYSTEM-MAP-2's workbench lists them.
- D3. Reliability and calibration become menu entries under Equipment; the capture inbox becomes a menu entry under Production and warehouse next to data capture.
- D4. Build the four list pages the new menu needs, in this cut: the combined claims page (D2), a certificates-of-destruction list, a spare-parts list, and a supplier-certificates overview. Each is a read-only list on the shared table with sorting and Excel/CSV export (TABLE-EXPORT and TABLE-FEATURES rules apply), masking per the existing views, and links to the existing detail pages.

From Tim's reply to SYSTEM-MAP-1 Step 0:

- Correction accepted: eight business modules + My workbench = nine bar buttons; Tools and Settings stay as drawer sections. The contracts side filter (with its saved-views bar) is in scope.
- Q1 - Accepted. Short labels in the bar and the drawer, the full process name as the hover title and as each module's page heading. Workbench first. en: Workbench · Purchasing · Production · Quality · Sales · Finance · People · Safety · Equipment; zh: 工作台 · 采购 · 生产 · 质量 · 销售 · 财务 · 人事 · 安全 · 设备. Added: measure the bar at 1024, 1280 and 1440 in both languages. At no width may the page scroll horizontally; where the row does not fit, keep or apply the existing fallback and report which one applies at each width.
- Q2 - Accepted as recommended: /claims under People, visible with hr.view or finance.view; /hr/claims and /finance/claims keep their URLs and approval rules but leave the menu, still registered as children of /claims for search and breadcrumbs. Medical rows -> /hr/claims/[id]; submitted or rejected general claims -> /finance/claims#claim-<id> (the row must actually scroll into view and be highlighted; prove it); approved general claims -> /finance/expenses/[id]. Medical amounts stay masked without data.view_health, shown as 「受限」/"Restricted", never blank, never 0.00.
- Q3 - NO migration in this cut. The supplier-certificates overview shows the expiry dates only, sorted soonest-expiring first, with no computed status. (Status column queued under SYSTEM-MAP-2 in `docs/forward-queue.md`.)
- Q4 - Accepted: the COD list keeps action.issue_cod (admin, warehouse); other roles see 「受限」. (Separate permission question queued in `docs/forward-queue.md`.) Do not change the permission now.
- Q5 - Accepted: remove the /me and /my-reviews rows from the avatar menu; keep the notifications bell with its unread count as a status indicator.
- Split - Do NOT split.

## What SYSTEM-MAP-1 built (v1.4.77)

Readings: `docs/surveys/SYSTEM-MAP-1/` (README + `readings/`). Registry: `lib/modules.ts`; the full module → entry table is `docs/surveys/SYSTEM-MAP-1/readings/module-table.md` (generated from the registry).

- **Top level** (`MODULES`, `BAR_MODULE_IDS`): Workbench · Purchasing · Production · Quality · Sales · Finance · People · Safety · Equipment on the bar; Tools (calendar, unit converter) and Settings as named sections. Short labels (`nav.mod.*`), full process name as hover title (`nav.modFull.*`) and as the heading of `/purchasing`, `/operation`, `/sales`, `/finance`, `/hr`.
- **Single home**: 140 registry entries, 120 menu rows + 20 children, each with exactly one module; `scripts/check-single-home.mjs` in `npm run build` (fault-injected: a second module on `/inbound` stops the build — `readings/single-home-injection.txt`). Children whose URL is not under their parent (`/hr/claims`, `/finance/claims` under `/claims`) resolve to the parent's module (`lib/navTrail.ts` `detachedChildFor`; `check-nav-routes` arm ⑧ keeps child and parent in one home).
- **Bar fallback (Q1 added)**: the module row shows from 1280 px (`xl`); below that the existing Menu button + full-height drawer (with the Tools and Settings sections) is used. Measured on a page with the search box: 1280 → last button ends 871 px, right group starts 976 px; 1024 → forcing the row would put the last English button at 871 px over a right group starting at 760 px. No horizontal page scroll at 390 / 1024 / 1280 / 1440 in English and Chinese.
- **D1**: `filteredListHref` (`lib/savedViews.ts`) — 16 toolbars, four server-built filter links on three pages (payment requests, capture inbox, deleted records) and the new contracts filter write `?view=plain` when the last filter is cleared. Lists filtered by GET forms already kept empty keys and never re-applied the default.
- **D2/Q2**: `/claims` (`app/claims/`); `/finance/claims` rows carry `id="claim-<id>"` (pending cards and the decided table via the shared table's new `rowAnchor`), and `<HashTarget>` scrolls the row into view and highlights it after a soft navigation.
- **D3**: `/operation/equipment/reliability` and `/operation/calibration` are Equipment menu rows; `/operation/capture/inbox` is a Production menu row next to Confirm readings.
- **D4**: `/compliance/cod` (gate `action.issue_cod`), `/compliance/supplier-certificates` (gate `module.suppliers.view`, dates only, soonest expiry first), `/operation/spare-parts` (gate `module.inventory.view`, `spare_part_stock`, no money). All on the shared table, browser-sorted, Excel/CSV export; added to `scripts/check-list-sorting.mjs` (84 → 88).
- **Contradictions fixed**: `/finance/company` finds the licence entry through its own home (it had searched Purchasing and would have drawn "Restricted" for everyone); `/operation/operation-types` lost its back link to `/operation`; 25 message lines that named an old home plus 9 more "HR → …" lines and 4 "HR module" / 人力资源 phrases now name the new homes; HR pages' heading `hr.title` reads People / 人事.
- **Q5**: avatar menu = identity · notifications (with unread count) · settings · language · log out.
