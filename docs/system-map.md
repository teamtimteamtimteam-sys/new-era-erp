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

## Open questions the measurement raised (for Tim before SYSTEM-MAP-1 Step 0; not rulings)

Measured in SYSTEM-MAP-0 Part 3 (`docs/surveys/SYSTEM-MAP-0/readings.md` §3). Listed here so SYSTEM-MAP-1 does not start on a guess:

1. **Default view when the last filter is cleared** — carried from TF-3 (`docs/known-issues.md` SAVED-VIEW-DEFAULT-RETURNS-WHEN-LAST-FILTER-CLEARED); ruling pending, to be asked before SYSTEM-MAP-1 starts.
2. **`/finance/claims` (the general expense-claim queue)** — 2.2 puts "claims (medical and general in one entry, two kinds)" under People and keeps Finance's "existing six groups", in which `/finance/claims` sits (Payables). Which menu holds the general-claims queue, and whether "one entry" means one page listing both kinds (today `/hr/claims` lists medical claims only), is not stated.
3. **Reliability, calibration and the capture inbox are not menu rows today** (`parent` entries: reliability under `/operation/equipment`, calibration and `/operation/capture/inbox` under `/operation/devices`). 2.2 names reliability and calibration as Equipment entries and "data capture" under Production — whether they become menu rows, and whether the capture inbox follows data capture (Production) or its current parent (Equipment), is not stated.
4. **Three 2.2 items have no list page today**: certificates of destruction (issued per inbound batch; only `/inbound/[id]/cod/pdf`), spare parts (a panel on `/operation/equipment/[id]`), supplier certificates overview (no page). Menu rows for them need a page; SYSTEM-MAP-1 is "no migration expected" but a new list page is new code.
5. **My workbench entries** — `/me`, `/my-reviews`, `/notifications` are not registry entries today (avatar menu and phone drawer only); the unified to-do page does not exist yet (SYSTEM-MAP-2).
