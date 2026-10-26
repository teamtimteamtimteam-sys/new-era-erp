# SYSTEM-MAP-0 — readings (2026-10-26/27)

Brief: "SYSTEM-MAP-0 — TF-3 close-out, record Tim's structure rulings in the repo, then a read-only measurement". Started from `7fe1cd07daee698c8c30ea7e5f928c6c6ef667c1` (HEAD = origin/main = `git ls-remote origin main`, tree clean).
**No application code changed and no migration ran.** Rulings: `docs/system-map.md`. Readings and the scripts that made them: this folder.

**Identity of every reading** (AGENTS.md "a 0-row reading — ask who read it"):
- **Live, read-only, this session only:** as `postgres` (`rolbypassrls = true`) on **base tables** — `journal_requests`, `expense_claims`, `auth.users`, `roles`, `user_roles`, `role_permissions`, `finance_settings`, `ingest_settings`, `cod_issues`, `saved_views`; the reconciliation line as tim@ (`cfo`) inside a rolled-back transaction; the COD bytes through the Storage API (list + GET). Production pages through a throwaway `tf3probe` session (GET only, nothing pressed).
- **Local rebuild** (`python3 db/verify_rebuild.py --target <local> --skip-diff`, `REBUILD_EXIT=0`): everything in §3.2. Live role grants were copied in by one read-only query.
- **Code reading:** §3.1 and §3.3. Four sub-agents read code for §3.1 and one for §3.2's gate list; each brief carried the LIVE SAFETY section verbatim; **none connected to live** (no DSN, no keys, code only). Their citations were spot-checked by this session (8 of 8 matched, listed in §3.1).

## 1 · Part 1 — TF-3 close-out

| Step | Reading |
|---|---|
| 1.1 | HEAD = origin/main = ls-remote = `7fe1cd07daee698c8c30ea7e5f928c6c6ef667c1`; `git status --porcelain` 0 lines. |
| 1.2 production | `db/scripts/2026-10-27-table-features-3-closeout-prod-check.mjs` → **`TF3_CLOSEOUT_EXIT=0`, 3/3** (`readings/tf3-closeout-prod-check.txt`). `/finance/journal` HTTP 200 with the saved-views menu ("Plain list" + "Save view"), no redirect — **production serves 7fe1cd0**. |
| 1.2 journal panel | **Not observable on production.** Live holds **0 journal requests** (postgres, base table `journal_requests`, `relkind = r`), and the panel draws nothing at 0 (`app/finance/journal/JournalRequestsPanel.tsx:104`). Creating one is forbidden, so the check reads the **same component** (`BulkDecisionBar`) on `/finance/claims`, where live has 1 submitted claim: bulk bar + select-all + "Reject selected (0)", nothing pressed, no result list. |
| read-back | `readings/readback-closeout.txt`, `READBACK_OWN_EXIT=0`: 7 users / 7 enabled; **0 throwaway users** (`tf1probe`/`tf2probe`/`tf3probe`), 0 probe roles, 0 orphan grants; roles held admin · cco · cfo · cto · finance · gm · warehouse; 1 active `cfo` grant; approvals ON `finance/cfo/1000`; `require_calibrated_since` NULL; 2 CODs; 0 saved views; reconciliation AP 0.00 / AR 0.00 unexplained, both agree. |
| COD bytes | `readings/cod-bytes.txt`, `COD_OWN_EXIT=0`: 34,701 `ba299a4f…f42101` and 34,746 `717661f6…13a4f9`, equal to the AGENTS.md baseline and to `cod_issues.sha256`. |

## 3.1 · Document chains — does each detail page link to the next step and back?

Classification: **yes** = a direct link to that document's own page in the default view (conditions noted); **no**; **only via related-records page** — this applies to **no cell**: the related-records pages (`app/components/related/related-records.tsx:112`, routes `/related/[subject]/[id]/[target]` and `/documents/[key]`) are linked **only from the global search dropdown** (`app/components/search/SearchEntry.tsx:609-631`, hrefs from `lib/search/records.ts:198`). Measured: `grep -rlE "RelatedRecords|['\"\`]/related/|['\"\`]/documents/" app lib` → only the component, the two routes, search, and `lib/search/*`; no detail page.
Batch detail pages are `app/inbound/[id]/edit/page.tsx` and `app/output/[id]/edit/page.tsx` (no `page.tsx` directly under `[id]`).
Spot-checked by this session: `attendance/[id]/page.tsx:74` · `processing/[id]/page.tsx:754` · `sales/orders/[id]/page.tsx:155` · `sales/quotes/[id]/page.tsx:161` · `payments/[id]/page.tsx:330` · `payables/[batchId]/page.tsx` (0 × `payment-requests`) · `CostSettlePanel.tsx:112` · `sales/shipments/[id]/page.tsx` (0 × `invoices`) — 8/8 as reported.

### Purchasing: PO → inbound batch → assay → pricing → payable → payment request → payment → bank reconciliation

| Step A → B | forward A → B | back B → A | notes |
|---|---|---|---|
| PO → inbound batch | **yes** `app/purchasing/orders/[id]/PoReceiptsTable.tsx:82` (also `page.tsx:1153`) | **yes** `app/inbound/[id]/edit/page.tsx:743-748` | forward only when the order has receipts and the reader sees inbound (`page.tsx:1173-1177`); never on equipment orders (`:1086`) |
| inbound batch → assay | **yes** `app/inbound/[id]/edit/AssayRowsTable.tsx:64-65` | **yes** `app/inbound/[id]/assays/[assayId]/page.tsx:211,221` | forward only when assays exist |
| assay → pricing | **yes, to the batch page that hosts pricing** (`assays/[assayId]/page.tsx:211,221`; price-request label `:337`) | **no** from the pricing panel (`PricingPanel` / `RepriceFromContentPanel` / `ReceiptPriceRequestPanel`: no hrefs; assay code plain text `ReceiptPriceRequestPanel.tsx:34,80`) | pricing has no page: a panel on the batch page (`app/inbound/[id]/edit/page.tsx:878`); the batch page's assay table (above it) links each assay |
| pricing → payable | **no** (no href to `/finance/payables` anywhere on the batch page) | **yes, to the batch page** `app/finance/payables/[batchId]/page.tsx:205-206` | |
| payable → payment request | **no** (`payables/[batchId]/page.tsx` hrefs: list `:183`, batch `:206`, journal `:261`; settlements link payments, `SettlementHistoryTable.tsx:77-78`) | **yes** `app/finance/payment-requests/[id]/page.tsx:137` via `RequestAllocationsTable.tsx:26-27` | back only for allocations with an `inbound_batch_id` |
| payment request → payment | **yes** when paid `payment-requests/[id]/page.tsx:240` (reversal: `:209`) | **no** — the payment page links only an open reversal request (`app/finance/payments/[id]/page.tsx:330`) | a batch allocation on the payment links `/inbound/[id]/edit` (`:175`), not the payable |
| payment → bank reconciliation | **no** (`payments/[id]/page.tsx`: no `/finance/bank` href; journal `:351-352`) | **no** — matched statement lines link journal entries only (`StatementLinesTable.tsx:125-127`, `ReconcileWorkspace.tsx:289-291`) | no reconciliation document exists; the two meet only through the journal entry page |

### Processing: work order → processing run (input batches → output batches) → cost allocation

| Step A → B | forward A → B | back B → A | notes |
|---|---|---|---|
| work order → run | **yes** `app/operation/orders/[id]/WorkOrderTables.tsx:185` (href `page.tsx:161`) | **yes** `app/operation/processing/[id]/page.tsx:754` | back only when the run has a work order |
| run → input batch | **yes** `app/operation/processing/[id]/ProcessingTables.tsx:197` (href `page.tsx:637-639`) | **yes** `app/components/inventory/MovementTimelineTable.tsx:111` (on `inbound/[id]/edit/page.tsx:1028`); `app/components/batch/BatchBalancePanel.tsx:101` | back only on movements carrying a `run_id`; deleted / restricted inputs print no link |
| run → output batch | **yes** `ProcessingTables.tsx:281` (href `page.tsx:655`) | **yes** `app/output/[id]/edit/TraceabilityTables.tsx:84`; `MovementTimelineTable.tsx:111` (on `output/[id]/edit/page.tsx:581`) | traceability back link replaced by a named refusal when the report fails (`TraceabilitySection.tsx:119-123`) |
| run → cost allocation | **no** — no allocation page; costs are inline on the run page (`CostPanel` `page.tsx:801`, allocation section `:875-902`, committed runs only) | **no** — `/finance/processing-costs` prints the run as plain text (`app/finance/processing-costs/CostSettlePanel.tsx:112`) | the electricity share is the one linked pair: `EnergyPanel.tsx:47` ↔ `app/finance/electricity/[id]/page.tsx:103` |

### Sales: quote → sales order → reservation → shipment and container → invoice → receipt, plus credit notes

| Step A → B | forward A → B | back B → A | notes |
|---|---|---|---|
| quote → order | **yes** when converted `app/sales/quotes/[id]/page.tsx:161` | **yes** `app/sales/orders/[id]/page.tsx:155` | back only when the order came from a readable quote |
| order → reservation | same page — `ReservationSection` at `app/sales/orders/[id]/page.tsx:239` | same page | no reservation route |
| reservation → shipment | **no** — shipment code plain text (`ReservationSection.tsx:280`); only the delivery-note PDF is linked (`:284`) | **no** (shipment page links the order, `app/sales/shipments/[id]/page.tsx:144`) | |
| order → shipment | **yes** `app/sales/orders/[id]/ShippingSection.tsx:87` | **yes** `sales/shipments/[id]/page.tsx:144` | back needs `module.sales.view`, else the unfiltered `/logistics/shipping` list (`:148`) |
| shipment → container | **yes** when loaded `sales/shipments/[id]/page.tsx:178` | **yes** `app/logistics/containers/[id]/ContainerPanels.tsx:72` | |
| order → container | **no** | **no** — order column is plain text (`ContainerPanels.tsx:76`) | reachable via the shipment |
| shipment → invoice | **no** | **no** | the order invoices before it ships |
| container → invoice | **no** (only freight documents, `ContainerFreightPanel.tsx:197`) | **no** | |
| order → invoice | **yes** `app/sales/orders/[id]/OrderInvoiceSection.tsx:92` | **yes** `app/finance/invoices/[id]/page.tsx:440` | forward needs `module.finance.view`; back only for order-kind invoices |
| invoice → receipt | **yes** `app/components/finance/SettlementHistoryTable.tsx:77-78` (href `invoices/[id]/page.tsx:292`) | **yes** `app/finance/payments/[id]/PaymentAllocationsTable.tsx:66` (href `payments/[id]/page.tsx:150`) | only when allocations exist |
| invoice → credit note | **yes** `app/finance/invoices/[id]/CreditNoteSection.tsx:135` | **yes** `app/finance/credit-notes/[id]/page.tsx:155` | |

### People: attendance, overtime, leave → payroll period → payroll payment

| Step A → B | forward A → B | back B → A | notes |
|---|---|---|---|
| attendance period → payroll period | **no** (only the list, `app/hr/attendance/[id]/page.tsx:74`) | **no** (`app/hr/payroll/[id]/page.tsx` hrefs `:187` list, `:213` edit, `:249` journal, employee links) | a "locked by payroll" notice is plain text (`attendance/[id]/page.tsx:84-88`) |
| overtime batch → payroll period | **no** (only the list, `app/hr/overtime/[id]/page.tsx:98`) | **no** — overtime hours shown as numbers (`payroll/[id]/page.tsx:82-86`) | |
| leave → payroll period | **no** (only the list, `app/hr/leave/[id]/page.tsx:135`) | **no** | |
| payroll period → payroll payment | **no** — `:248-249` links the period's **accrual** entry, not a payment | **only conditional, to the period** from the payments **list** when a reversal request is open (`app/finance/payroll-payments/PayPanel.tsx:168`); a payment's journal page prints the source as text (`app/finance/sourceLinks.ts:80-100` has no payroll mapping) | no per-payment page: each payment is a journal entry |

**Count (pairs on the four chains, 25; `order ↔ reservation` is one page and not counted):** both ways 11 · one way 5 · neither 9 — purchasing 2 / 4 / 1 · processing 3 / 0 / 1 · sales 6 / 0 / 4 · people 0 / 1 / 3 (the one is the conditional link from the payroll-payments **list**).

## 3.2 · Per-role reach (live grants in a local rebuild)

Method: `readings/live-role-grants.sql` (live, postgres, base tables; `GRANTS_OWN_EXIT=0`: 7 roles, **1 holder each**, 310 grants) → `readings/load-grants-local.sql` (local only; `LOAD_OWN_EXIT=0`, counts equal) → `role-reach.mjs`: one synthetic local user per role, `current_user_permissions()` under its JWT (the function `lib/permissions.ts` calls), then `allows()` from `lib/modules.ts` over `menuFunctionsForModule()` and over `lib/reminders.ts` `specFor()` — the expressions `getModuleAccess()` and `app/tools/reminders/page.tsx` use (`REACH_OWN_EXIT=0`, `readings/role-reach.json`). Approval gates: `decide-matrix.sql` in the rebuild with the live policy (`set_approvals_policy(true,'finance','cfo',1000)`), each decision's own gate from its decide function — `has_permission()` on its codes and `require_approver_for(1|2)` (`DECIDE_OWN_EXIT=0`, 182 readings, `readings/decide-matrix.txt`). Gate sources (file:line per function) in the list below the table.

| role | codes | top-level open (of 10) | second-level open (of 112) | shown 「受限」 | reminder arms visible (of 72) | approvals it can decide (of 26 gates) | decides, but no reminder arm | reminder arm visible, cannot decide |
|---|---|---|---|---|---|---|---|---|
| admin | 86 | 10 | 112 | 0 | 72 + HR alerts | 12: salary change (both paths), review approval (both), leave, medical claim, overtime, supplier approve, NCR, capture draft, WO/blending release, stocktake post | overtime; WO/blending release | 10: every CFO-level request arm (payment, invoice, GST, journal, asset disposal, warehouse, payroll, terms, receipt price, shipping release) |
| cfo | 36 | 10 | 106 | 6: `/logistics/shipping` + 5 settings pages | 67 + HR alerts | 19: all ten CFO-level requests; expense claim both tiers; PO both tiers; salary change; review approval; leave; medical claim; supplier approve | **expense claims (both tiers); PO approval (both tiers)** | 2: `ncr_open`, `stocktake_open` |
| cco | 50 | 10 | 104 | 8: `/finance/self-approved`, `/logistics/shipping`, `/settings/change-history` + 5 settings | 68 + HR alerts | 5: salary change and review approval when the CFO is a party; leave; medical claim; NCR | — | 11: the ten CFO-level arms + `stocktake_open` |
| cto | 41 | 10 | 104 | 8: same as cco | 66 + HR alerts | 2: NCR; capture draft | — | 13: the ten CFO-level arms + leave, claim, review, stocktake |
| finance | 43 | 10 | 103 | 9: `/compliance/packs`, `/finance/self-approved`, `/logistics/shipping`, `/settings/change-history` + 5 settings | 66 + HR alerts | 6: expense claim < 1,000; PO < 1,000; leave; medical claim; WO/blending release; stocktake post | **expense claim < 1,000; PO < 1,000**; WO/blending release | 13: the ten CFO-level arms + NCR, review, salary change |
| gm | 23 | 10 | 100 | 12: `/logistics/shipping`, the four `/quality/*`, `/settings/deleted`, `/settings/change-history` + 5 settings | 59 + HR alerts | 0 | — | 13: the ten CFO-level arms + leave, claim, review |
| warehouse | 31 | 9 (Finance closed) | 50 | 62: all 38 Finance-menu entries, 11 of People, 4 of Sales, 6 of Settings, `/materials`, `/compliance/packs`, `/tools/pricing` | 44, no HR alerts | 2: overtime; capture draft | **overtime** | 3: `ncr_open`, `receipt_price_request_pending`, `stocktake_open` |

"5 settings" = `/settings/accounts · roles · reference · import · approvals` (`action.manage_permissions` / `action.bulk_import`). Every role reaches `/tools/tasks` and `/tools/reminders`; `/me`, `/my-reviews` and `/notifications` have no module gate (every signed-in role). **Notifications carry no approvals**: only `notify_landing_warnings` and `notify_class_violations` write `notifications`.

**What the table says, plainly:**
1. **The reminders page points the CFO at nothing it alone must do for expense claims and PO approvals** — those two have **no reminder arm** (`lib/reminders.ts`, matched name-for-name to `db/views/operations_now.sql` by `scripts/check-reminder-arms.mjs`), nor do overtime and WO/blending release. Expense claims and POs are two of the three gaps 2.4(9) absorbs.
2. **Reminder arms are wider than decide gates**: the ten CFO-level arms use `module.finance.view` / `module.sales.view` / `module.pricing.view` / `data.view_pay` / `data.view_purchase_prices`, and every decide function also requires the level-2 role (`require_approver_for(2)`). So admin, cco, cto, finance and gm see 10–13 arms each that only the cfo can act on.
3. **admin holds every code but no approval role**, so it decides none of the CFO-level requests.
4. Top-level reach is nearly flat today (10/10 for six roles) because Tools and Settings each hold an entry every role can open.

Decision gates (from each decide function; `require_approver_for(2)` = level-2 role `cfo`; level 1 = `finance` or `cfo`): payment / invoice / GST / journal / asset disposal / warehouse requests — `module.finance.view` + `data.view_prices` + level 2 (`db/functions/decide_payment_request.sql:40-41,55` · `decide_invoice_request.sql:28-29,43` · `decide_gst_filing_request.sql:24-25,39` · `decide_journal_request.sql:33-34,48` · `decide_asset_disposal_request.sql:24-25,39` · `decide_warehouse_request.sql:26-27,41`); payroll — `module.hr.view` + `data.view_pay` + level 2 (`decide_payroll_request.sql:40-41,55`); terms — five codes + level 2 (`decide_terms_request.sql:23-27,41`); receipt price — `module.inbound.view` + `data.view_purchase_prices` + level 2 (`decide_receipt_price_request.sql:39-40,54`); shipping release — `module.sales.view` + `data.view_prices` + level 2 (`decide_shipping_release.sql:28-29,43`); expense claim — finance view + prices + tier (`decide_expense_claim_items.sql:89-90,126-128`); PO — purchasing view + purchase prices + tier (`approve_purchase_order.sql:12,28,53-55`); salary change / review — `pay_decision_code` / `review_approval_code` (`decide_salary_change_request.sql:34-35`, `approve_review.sql:24`); leave / medical — `action.decide_hr_requests` (`decide_leave_request.sql:18`, `decide_medical_claim.sql:9`); overtime — `action.overtime_approve` (`decide_overtime_batch.sql:28`); supplier — `action.supplier_approve` (`set_supplier_status.sql:47-53`); NCR — `action.ncr_decide` (`decide_ncr.sql:28`); capture — `action.confirm_capture` (`confirm_capture_draft.sql:17`); WO / blending release — `action.wo_release` (`release_work_order.sql:57`, `release_blending_plan.sql:20`); stocktake post — `action.stocktake_post` (`post_stocktake.sql:68`). Four-eyes, the approvals switch and "the CFO is a party" are per-document conditions, not role reach, and are not in the table.

## 3.3 · For SYSTEM-MAP-1

### Registry entries whose module assignment changes (`readings/menu-moves.tsv`, `MOVES_OWN_EXIT=0`)
`menu-moves.py` exports `FUNCTIONS` from `lib/modules.ts` and maps each entry by a written rule (each override names its 2.2/2.3/2.4 sentence; 0 unmapped). **133 entries: 76 same home · 30 change only because Operation + Inventory merge into Production and warehouse and Logistics into Sales and logistics · 9 multi-module → one home · 18 relocated.**

| | entries |
|---|---|
| **relocated (18)** | Purchasing ← `/tools/pricing` + `/formulas` `/calculator` `/metal-prices` (2.4(3)) · Safety and compliance ← `/purchasing/licences`, `/inventory/storage-safety` (2.4(7)) · Quality ← `/quality/samples` `/disputes` `/ncr` `/coa`, `/operation/contamination` · Equipment ← `/operation/equipment`, `/operation/equipment/reliability`, `/operation/devices`, `/operation/calibration`, `/operation/operation-types` · My workbench ← `/tools/tasks`, `/tools/reminders` (2.4(11)) |
| **multi → single (9, 2.3)** | `/inbound`, `/inbound/receive`, `/output`, `/operation/weighbridge` → Production and warehouse · `/hr/overtime` → People · `/sales/commissions`, `/finance/freight` → Sales and logistics · `/finance/self-approved` → Finance · `/settings/change-history` → Settings |
| **merge only (30)** | the remaining `operation` (10) and `inventory` (10) entries → Production and warehouse; `logistics` (5) and `sales` (5) → Sales and logistics (ids or labels change; placement relative to siblings does not) |
| **not in the registry today** | My workbench: `/me`, `/my-reviews`, `/notifications` (avatar menu + phone drawer, `app/components/nav/AvatarMenu.tsx:192,217,224`); the unified to-do page (SYSTEM-MAP-2). Safety: certificates of destruction (per batch only, `app/inbound/[id]/cod/pdf/route.tsx`), supplier certificates overview (no page). Equipment: spare parts (a panel, `app/operation/equipment/[id]/SparePartsPanel.tsx`). |

### Pages whose own navigation or wording contradicts the new home (`readings/inpage-nav.txt`, `INPAGE_OWN_EXIT=0`; `readings/message-path-wording.txt`)
Breadcrumbs follow automatically: they are computed from the registry (`lib/navTrail.ts:186` `breadcrumbTrail` → `activeModuleForPath`); no page renders its own (`<Breadcrumbs>` only in `app/layout.tsx`). Scan: 1,364 files, the 27 moving entries; detector proven on two known positives below.
1. **`app/finance/company/page.tsx:80`** — `getFunctionAccess('purchasing').find(FN.licences.href)`: once licences leave Purchasing this finds nothing and the page draws "· Restricted" **for everyone** (a false refusal), beside the text `company.licence.movedToPurchasing` ("The licence register now lives under Purchasing", `messages/en.ts:9853`, `zh.ts:9638`).
2. **`app/operation/operation-types/page.tsx:65`** — back link to `/operation` (Operation's overview) on a page moving to Equipment.
3. **Message wording that names an old home** — 13 en / 12 zh lines: `Operations → Equipment` (en `:9184`, zh `:8966`) contradicts the move; `Operations → Processing` ×3 and `Inventory → Locations / Storage Locations` ×8 (zh `运营 → 加工` ×3, `库存 → 库位` ×8) name modules that merge; plus the licence line above.
4. Cross-links that stay valid but now cross modules (not contradictions): `/hr` overview → `/tools/reminders` (`app/hr/page.tsx:249`); `/inventory` table → `/inbound`, `/output` (`app/inventory/InventoryTable.tsx:93,115`, same new home).

### Estimate — SYSTEM-MAP-1 (menu reorganisation + single-home build check; no migration)
**Process floor (measured costs):** Step 0 questions (open items 1–5 in `docs/system-map.md`) ≈ 20 min · build ×2 ≈ 3 min (45–100 s each) · offline gate 140 s · layout survey ≈ 12 pages × 2 widths × 26 s ≈ 10 min · smoke ≈ 50 min (start-and-leave; the render layer changes) · fresh clone build ≈ 5 min · hand-back, docs, commit, push ≈ 30 min → **≈ 2 h** (no backup, no full gate, no window).
**Measured work:** registry — 3 new top-level modules (Workbench, Quality, Equipment), 2 merges, 57 entries reassigned, `BAR_MODULE_IDS`, `MODULE_GROUPS`, en + zh labels ≈ 1 h 30 · the single-home check (a new `scripts/check-*.mjs` in `npm run build`, with a fault injection) plus the multi-owner branches it retires (`lib/navTrail.ts` `activeModuleForPath`, `check-nav-routes.mjs`) ≈ 1 h · the 2 code contradictions + 25 message lines ≈ 45 min · Workbench rows for `/me` `/my-reviews` `/notifications` (registry + avatar menu / drawer de-duplication) ≈ 45 min · docs (`information-architecture.md`, `nav-registry.md`, `manual-walk-list.md`) ≈ 45 min → **≈ 4 h 45**.
**Sum ≈ 6 h 45 (range 5–8 h).** Not included: new list pages for COD / spare parts / supplier certificates and a combined claims page (open items 2 and 4) — each is new code, to be sized only if Tim puts it in SYSTEM-MAP-1. For calibration: TF-1 was estimated at ≈ 11 h and took ≈ 2.5 h.

## Assertions in the brief measured false, or not measurable
1. **"the bulk bar with select-all on the journal request panel"** — not observable on production: 0 journal requests on live; read on `/finance/claims` instead (§1).
2. **2.4(12) "built on the existing related-records pages"** — the related-records pages exist, but **no detail page links to them today** (§3.1); only global search does.
3. The other brief counts re-measured and true: 9 multi-module entries (2.3) — 9; 7 live roles — 7 with 1 holder each; offline gate ≈ 140 s and layout ≈ 26 s per page per width are taken from TF-1/TF-3 hand-backs (not re-run here: no code changed).
