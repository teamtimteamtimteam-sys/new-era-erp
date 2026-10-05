> Supporting evidence for `docs/surveys/MES-0/README.md`. Written by a read-only survey sub-agent on 2026-10-05 and re-read in full by the survey author. Tags as in that file.

# MES-0 · repo survey B: functions 15–31, plus the nav registry and the route tree

Repo: `~/Documents/projects/new-era-erp`. This was a read-only survey: no repo file was edited and the database was not touched.
Tags: **[M]** means measured from the repo (file or grep, cited by path:line). **[I]** means inferred.
Zero-hit greps are reported as [M] absences. They cover db/tables, db/functions, db/views, app, lib and docs, with English and Chinese terms.

---

## 0 · Placement reference

### 0.1 `lib/modules.ts` (1045 lines). The nav registry
- `SCOPES` (line 99, [M]) holds route-prefix → permission pairs:
  `/suppliers`→module.suppliers.view · `/purchasing`→module.purchasing.view · `/sales/customers`→module.customers.view · `/materials`→module.materials.view · `/tools/pricing`→module.pricing.view · `/inbound`→module.inbound.view · `/output`→module.output.view · `/operation`→module.processing.view · `/inventory`→module.inventory.view · `/stocktakes`→module.stocktakes.view · `/sales`→module.sales.view · `/finance`→module.finance.view · `/tools/tasks`→module.tasks.view · `/hr`→module.hr.view · `/logistics`→module.logistics.view.
- `MODULES` (line 168) lists the 9 top-level modules. **They carry no permission and no href.** Access is derived from their second-level entries. The modules are purchasing, logistics, operation, sales, finance, inventory, hr, tools and settings.
- `FUNCTIONS` (line 400) lists the second-level entries as `{href, navKey, modules[], permission, group?, parent?}`. Permission constants are at lines 355–398.
  - **purchasing**: /purchasing, /purchasing/orders, /purchasing/discrepancies, /purchasing/payment-terms (P_PURCHASING); /suppliers, /contracts, /purchasing/licences (module.suppliers.view)
  - **logistics**: /logistics, /logistics/forwarders, /lanes, /containers (module.logistics.view); /logistics/shipping (action.ship_goods)
  - **operation**: /operation, /operation/orders, /processing, /wip, /handovers, /equipment (all module.processing.view; line 449–455)
  - **sales**: /sales, /sales/quotes, /sales/orders (module.sales.view); /sales/customers (+parent /overlap) (module.customers.view)
  - **finance** (groups reports/entries/receivables/payables/periodEnd/config): trial-balance, pnl, balance-sheet, cashflow, cash-forecast, **price-exposure** (line 502), **/margin** (line 524, `{all:['data.view_prices'], any:[finance.view, processing.view]}`), journal(+new), receivables, invoices, credit-notes, payables, payment-requests, payments, expenses, claims, assets, month-end, list-vs-ledger, payroll-payments, processing-costs, revaluation, cost-variance, close, gst, wht, packs, bank(+statements), settings, company, fx (all module.finance.view unless stated otherwise)
  - **inventory**: /inventory, /inventory/locations, /inventory/reports(+snapshot/violations/safety/ledger) (module.inventory.view); /stocktakes; /materials
  - **hr**: overview, employees, departments, attendance, payroll, leave(+balances/calendar/grants/types/holidays), claims, training, reviews(+cycles/scale), kpi(+score), org (module.hr.view)
  - **tools**: /tools/tasks (module.tasks.view); /tools/calendar, /tools/converter, /tools/reminders (`{all:[]}`, which lets any login in); /tools/pricing(+formulas/calculator/metal-prices) (module.pricing.view)
  - **settings**: accounts, roles, reference, approvals (action.manage_permissions); dictionaries (`any: materials.view|inbound.view`); import (action.bulk_import); deleted (data.view_deleted); change-history (data.view_change_log, also listed under finance)
  - **cross-module**: /sales/commissions; /inbound(+/receive) (purchasing, inventory, operation; module.inbound.view); /output (operation, inventory); /finance/freight (logistics, finance); /finance/self-approved; /hr/overtime (`any: hr.view|overtime_enter|overtime_approve`)
- Rule from AGENTS.md "standing decision 4" ([M] AGENTS.md ~1040): permission evaluation happens **only** in `allows()` (lib/modules.ts:74). This is enforced by `scripts/check-permission-predicate.mjs`. A new page also needs an entry here, or `check-nav-routes.mjs` will flag it ([I] from the script name).

### 0.2 `app/` tree, two levels deep [M]
brand-sampler · components/{audit,calendar,charts,dictionaries,finance,forms,home,inventory,labels,metals,nav,overview,pdf,pricing,receiving,related,search,trail,ui} · contracts/{[id],new} · documents/[key] · finance/{assets,balance-sheet,bank,cash-forecast,cashflow,claims,close,collections,company,cost-variance,credit-notes,expenses,freight,fx,gst,invoices,journal,ledger,list-vs-ledger,month-end,packs,payables,payment-requests,payments,payroll-payments,pnl,price-exposure,processing-costs,receivables,revaluation,self-approved,settings,statements,trial-balance,wht} · hr/{attendance,claims,departments,employees,kpi,leave,org,overtime,payroll,reviews,training} · inbound/{[id],export,new,receive} · inventory/{inbound,locations,output,reports} · login · logistics/{containers,forwarders,lanes,shipping} · logout · margin · materials/{[id],export,new} · me/avatar · my-reviews/[id] · notifications · operation/{equipment,handovers,orders,processing,wip} · output/{[id],export,new} · purchasing/{discrepancies,licences,orders,payment-terms} · related/[subject] · sales/{commissions,customers,orders,quotes,shipments} · set-password · settings/{accounts,approvals,change-history,deleted,dictionaries,import,reference,roles} · stocktakes/[id] · suppliers/{[id],export,new} · tools/{calendar,converter,pricing,reminders,tasks} · verify/cod · welcome.
There is no `app/api`. No `supabase/functions` directory exists, so there is no external ingestion endpoint [M].

### 0.3 Cross-cutting obligations for any new table [M]
- A code-bearing table must be registered in `document_types` or `document_type_exceptions`. This is enforced by `db/fixtures/102-…` and `scripts/check-document-registry.mjs`.
- Change-log trigger bindings for each new table are generated into `db/views/zzz_change_log_triggers.sql` by `db/scripts/gen_change_log_bindings.py`. They are checked by `scripts/check-change-log-coverage.mjs`.
- Writes go through the SILENT-1 `enforce_write_permission` statement trigger, following the pattern on every dictionary table.
- Dictionaries are "RUNTIME CONFIG" tables: you add a row, and `check_mirrors` does not compare their contents (substances.sql:1-6).
- Roles mirror seed (db/tables/roles.sql): admin, gm, finance, procurement, sales, operations, warehouse, hr, auditor, employee. Migrations also reference `cfo` and `cco`, e.g. 2026-09-01-eqppay1-a-the-cfo-grant.sql:39. [I] Those role rows are created by migration and are not in the seed list.
- Permission codes [M] (db/tables/permissions.sql): module.{suppliers,customers,materials,pricing,purchasing,inbound,output,processing,inventory,stocktakes,finance,hr,tasks,sales}.{view,edit}, module.tasks.view_all, module.logistics.view, data.{view_prices,view_purchase_prices,view_pay,view_health,view_identity,view_banking,view_sales,view_deleted,view_reviews,view_self_approvals,view_change_log}, action.{manage_permissions,bulk_import,issue_cod,finance_reopen,approve_review,decide_hr_requests,hr_reviews,anonymise_employee,finance_settings,customer_credit,supplier_approve,contract_terms,metal_prices,direct_sale,apply_assay,price_receipts,stocktake_count,stocktake_post,receive_goods,batch_write_off,wo_create,wo_release,processing_commit,processing_rollback,processing_aftercare,request_shipping_release,ship_goods,raise_po_consumables,raise_po_equipment,raise_po_office,overtime_enter,overtime_approve}. **There is no quality, lab, safety, WSH, maintenance or compliance permission code.**

---

## 15 · Sample management

**HAVE**
- [M] `assay_results.sample_ref text` is free text (db/tables/assay_results.sql:34). It is written by `record_assay_result(p_sample_ref)` (db/functions/record_assay_result.sql:6,71). Forms: app/inbound/[id]/assays/new/AssayForm.tsx:292 and app/output/[id]/assays/new/OutputAssayForm.tsx:249. Display: app/inbound/[id]/assays/[assayId]/page.tsx:268 and the output equivalent at :222. It is also a search column in `document_types` (db/tables/document_types.sql:115).
- [M] The contract records a **retention obligation**: `contract_settlement_terms.sample_retention_required boolean NOT NULL` and `sample_retention_days integer` (db/tables/contract_settlement_terms.sql:60-69). The comment says explicitly: "这里记的是合同要不要求留样,不是样品在哪". The /contracts page renders this as a named unmet prerequisite (app/contracts/page.tsx:398-400). It is editable through app/contracts/[id]/termSpecs.ts:104.
- [M] The source batch can be derived from the assay's parent, `assay_results.inbound_batch_id XOR output_batch_id`.
- [M] Storage location: the `storage_locations` table exists (code, name, zone, is_active) and is used by inventory only.
- [M] Lab dictionary: `laboratories` (code PK, seeded with one row, 'FRL'; db/tables/laboratories.sql:44-47).
- [M] `batch_required_assay_gaps` already models "sampleable = remaining_qty > 0", meaning a sample can only be taken while material remains (db/views/batch_required_assay_gaps.sql:18-21).
- [M] Docs: proc-reality N26/N28 (docs/proc-reality.md:902-930) say sample retention and the sampling protocol are the *same* topic as the "lab workflow", and that the protocol belongs on the sample, not on the assay. The doc rates it CHEAP (proc-reality.md:983). forward-queue lists sample retention under "事件驱动,不排队" (forward-queue.md:2926 section). known-issues.md:6519 says "仲裁那条路有一个说出来的未满足前提" (no physical sample model).

**MISSING** [M]
- No sample entity: no sample number or sequence, no link to a storage location, no retain-until/disposal date, no recipient or chain of custody (sent to lab X on date Y), no split or retained or umpire sample split.
- `inbound_source_reasons` 'sample' means a *free goods sample from a supplier* (db/tables/inbound_source_reasons.sql:48). That is a different concept and must not be reused.

**TOUCHES**
assay_results (sample_ref would become an FK, or the free text stays alongside an FK), contract_settlement_terms.sample_retention_days (drives the retain-until date), storage_locations, laboratories / counterparty_contacts (recipient), inbound_batches/output_batches (source), document_types (new code, e.g. "SMP-"), and the assay forms. Permission: today assays follow the parent batch's module, module.inbound.* or module.output.* (assay_results.sql RLS). [I] Samples would follow the same split.

## 16 · Assay arbitration (splitting limit → arbitration, fee split, settlement hold)

**HAVE** (sell side, mostly built) [M]
- `assay_results.result_party` takes 'ours' | 'counterparty' | 'umpire', is NOT NULL, and has no default (assay_results.sql:79-81; record_assay_result.sql:66).
- `contract_settlement_terms.settling_party` takes 'ours' | 'counterparty'. 'umpire' is deliberately excluded because "仲裁是一次升级" (contract_settlement_terms.sql:47-50). `splitting_limit_pct numeric` is nullable, in the range 0–100 (line 57). Its comment says NULL never becomes a decision and the system never auto-picks a result.
- `sale_settlement_compute` (db/functions/sale_settlement_compute.sql:150-186) compares the max element difference between our result and the counterparty's. It raises `RESULTS_IN_DISPUTE` (no limit declared) or `RESULTS_EXCEED_SPLITTING_LIMIT|a|b|diff|lim`, with the hint "按合同该送第三方复检,并用仲裁结果结算". An umpire result is always settleable (:153). **This refusal is the settlement hold.**
- `sales_settlements.settling_party_used` takes ours/counterparty/umpire (sales_settlements.sql:46-47). `assay_result_id` FK and `terms_snapshot` record which result was used. The table records the settlement only: "一分钱不进总账" (proc-reality G23, :1009).
- A terms snapshot is copied onto the document at link time: `contract_document_terms.settlement_terms jsonb` (contract_document_terms.sql:65). Contract terms are frozen while a contract is active or pending (TERMS-EDIT-1: `guard_contract_terms_frozen`, db/scripts/2026-09-27-terms-edit1-live-proof.sql P5–P9). Writing terms requires `action.contract_terms` (cco).
- UI: /contracts shows the splitting limit and recorded settlements (app/contracts/page.tsx:49,104,113,208,396). The contract editor is at app/contracts/[id]/termSpecs.ts. Error codes are in app/contracts/contractErrorCodes.ts.
- Fixtures: 118-what-basis-and-whose-result, 149-settlement-refuses-…, 230-a-contract-is-filled-in-…

**MISSING** [M]
- **Purchase side**: `apply_assay_result` and `reprice_inbound_batch` never read result_party, settling_party or splitting_limit (zero grep hits). Buy-side contracts require no terms at activation (`contract_activation_missing.sql:3`, "只对卖方合同有要求"; live-proof P10). So inbound arbitration has no detection at all.
- **No dispute or arbitration record**: no case linking the 2–3 results, no status, no "prompt", no reminder arm in operations_now.
- **Fee split / who pays**: proc-reality N25 "记下来,不建" (proc-reality.md:895-899) and G27 "仲裁费与条件付款方 — 无" (:1016). The convention is that the party further from the umpire result pays. `laboratories` is not a payee; the plan is to link it to a supplier on the forwarder_details pattern (laboratories.sql:30, "Tim 裁定如此").
- No settlement UI: there is no page that calls `record_sale_settlement`. The only app references are in /contracts and the converter (tools/converter/actions.ts).
- Physical umpire sample: see 15.

**TOUCHES**
assay_results, assay_result_metals, contract_settlement_terms (and its snapshot in contract_document_terms), sales_settlements, sale_settlement_compute (the refusal stays the hold), apply_assay_result / reprice_inbound_batch / price_history (purchase side; proc-reality N24 says the same reprice path can be reused with a "which result governs" pointer, :886-893), expenses (fee), laboratories → suppliers, operations_now (a dispute arm).

## 17 · Non-conformance reports linked to contract penalty elements

**HAVE** [M]
- `contract_penalty_elements` (contract_id, substance FK→substances, threshold_pct, usd_per_tonne_per_pct_over; unique per contract+substance; db/tables/contract_penalty_elements.sql:24-38). One rate shape only; the comment says "Tim 没有给条款清单". It is charged per settlement tonne and consumed only by `sale_settlement_compute` (sell side).
- `contract_settlement_terms.penalty_basis` takes 'none_agreed' | 'per_element'. When it is 'per_element' and no rows exist, activation refuses with `penalty_elements` (contract_activation_missing.sql:39-41).
- `contract_grade_breaches` view (db/views/contract_grade_breaches.sql) covers the **purchase side**: PO → contract_document_terms.grade_specs snapshot → inbound batch → non-superseded assay → below_min/above_max. It is described as "一个发现,不是一道闸", and it says it becomes a gate when G29 (quality hold) lands. It is shown on /contracts (page.tsx:77).
- `grn_discrepancies` / `supplier_receipt_pattern` cover quantity, not quality (/purchasing/discrepancies).
- Inventory hold: `hold_stock()` / `release_stock()` with a required reason; stock_status available/on_hold/committed (compliance-scoping.md CMPL-1 §2).

**MISSING** [M]
- No NCR / non-conformance / quality-claim / 质量索赔 entity (zero hits).
- G29 "质量暂扣 / 不合格状态" is open (proc-reality.md:1018; forward-queue.md:1710-1718). `output_batch_states` holds sales states only.
- G22 "拒收权 (规格上限)" is open (proc-reality.md:1011).
- Penalty elements are not applied on the **purchase** side; contract_grade_breaches does not compute money.
- F and Cl cannot be penalised today because they are not in `substances` (see 19).

**TOUCHES**
contract_penalty_elements, contract_grade_specs / contract_document_terms.grade_specs, contract_grade_breaches (an NCR would be raised from its rows), assay_results, inbound_batches/output_batches, hold_stock (no FK from a hold to its cause, only free-text `inventory_movements.notes`), sales_settlements.penalty_usd, purchase-side price_history/receipt_price_requests, credit_notes (sell-side claims), suppliers (supplier claims → AP).

## 18 · Certificates of Analysis (CoA)

**HAVE** [M]
- Precedent, COD-1 certificate of destruction: `certificates_of_destruction` (pending/issued/void, code minted at issue, `verification_token uuid`, frozen `snapshot jsonb`, replaced_by; db/tables/certificates_of_destruction.sql). Supporting tables: `cod_issues` (byte archive), `cod_verification_failures`. Functions: issue_cod, void_cod(+_internal, submit_cod_void_request → CFO), refresh_cod_for_batch, cod_certificate_data, cod_delivery_completion, cod_governing_licence, cod_verification (the **only** anon-executable function), next_cod_code, guard_cod_*. Routes: app/inbound/[id]/cod/pdf/route.tsx and public app/verify/cod/[token]/route.ts. Public paths are `PUBLIC_PATHS = ['/login','/verify/cod']` (lib/loginRoute.ts:50). Permission: action.issue_cod. Fixtures: 196 (stranger with token) and 226.
- Precedent, AUD-1 traceability report: `traceability_report_issues` (output_batch_id, code, version, sha256, append-only; db/tables/traceability_report_issues.sql). Supporting objects: traceability_report_data, record_traceability_report_issue, next_traceability_report_code. Route: /output/[id]/traceability/pdf, audience customer + auditor (docs/pdf-documents.md:12-31). Fixture 83.
- PDF layer: app/components/pdf/{DocumentChrome,Stamp,Wordmark,fonts,company,noSignature,theme}.tsx. Language policy: external commercial documents are always English (pdf-documents.md:43-53).
- Output assays exist: `apply_output_assay`, `preview_apply_output_assay`, fixture 54.
- `material_attachments.doc_category` 'coa' is an attachment slot for a supplier-provided CoA, not a generated one (app/materials/[id]/edit/AttachmentsPanel.tsx:37).
- Queue: forward-queue.md:1681, "第一笔真实销售之前 | 每批次的化验证书(CoA)" (phase 6), paired with G29.

**MISSING** [M]
- No CoA document, issue archive, route or code. docs/anon-surface.md:291-315 says the COD verify payload contains "no assay content" and the page must not reach assay_results. A CoA verify page would therefore be a new anon-surface decision.
- The verification domain is still `new-era-erp.vercel.app` (forward-queue.md:1753-1765). It has a hard deadline before production certificates are issued.

**TOUCHES**
output_batches, assay_results (+result_party, weight_basis, moisture_pct, is_final), assay_result_metals, laboratories, output_batch_metals, document_types, issue-archive pattern (so_issues/cn_issues/cod_issues family), anon grants (db/check_grants.py, db/anon-grants-baseline.tsv, scripts/check-anon-grant-decision.mjs), lib/loginRoute.ts PUBLIC_PATHS, calibration (20).

## 19 · Fluorine and chlorine in the substance list

**HAVE** [M]
- Dictionary `public.substances` (code PK, name_en, name_zh, symbol, is_active, sort_order, notes). Mirror: db/tables/substances.sql. Introduced by db/migrations/2026-08-22-proc4-the-metal-list-becomes-a-dictionary.sql:101.
- **All 7 existing entries**, seeded at db/tables/substances.sql:89-96 and identically in the migration at :101: `ni` Nickel 镍 Ni (1) · `co` Cobalt 钴 Co (2) · `li` Lithium 锂 Li (3) · `mn` Manganese 锰 Mn (4) · `cu` Copper 铜 Cu (5) · `al` Aluminium 铝 Al (6) · `fe` Iron 铁 Fe (7). No other seed exists in db/, supabase/ or scripts/. Fixtures 116, 119 and 244 insert scratch rows (e.g. 'FX244') inside rolled-back transactions.
- The table comment **names F and Cl as the first additions** ("氟/氯 —— 惩罚元素。今天它们连记都记不下来"). Their **return condition** is "第一份写明惩罚结构的承购/供货条款" (U11) (substances.sql:41-49). contract_penalty_elements.sql:5-7 and its table comment call their absence "一个具名的缺席". proc-reality G21 says the same (:1008).
- 12 FK columns reference substances [M]: assay_result_metals.metal, inbound_batch_metals.metal, output_batch_metals.metal, metal_prices.metal, material_required_metals.metal, pricing_formula_metals.metal, pricing_formula_history.metal, pricing_term_commitment_metals.metal, contract_grade_specs.metal, contract_pricing_terms.metal, contract_refining_charges.metal, contract_penalty_elements.substance.
- Writes require module.materials.edit (substances.sql RLS). It is edited at /settings/dictionaries (app/settings/dictionaries/registry.ts:78). App readers use `app/tools/pricing/metal-prices/substanceQuery.ts` (loadSubstances, `is_active` only, ordered by sort_order).

**MISSING / hazards**
- [M] No rows for F or Cl, and graphite and plastic are also absent by design.
- [M] There is **no kind/role column** to distinguish payable metal from penalty element from recoverable stream. Every active substance appears in every picker: metal-prices new/edit/bulk, the pricing calculator, formulas, and assay forms ([M] the inbound and output assay forms also read substances). Adding F and Cl as plain rows would offer "fluorine price per tonne" and payable pricing terms for F. [I] A role column, or a per-use filter, is needed before or alongside the rows.
- [M] registry.ts:83-91 `referencedBy` lists only 8 of the 12 FK users; the four contract_* tables are missing. Usage counts on the dictionary page would undercount.
- [M] The 623-site rename `metal → substance_code` is deferred (substances.sql:37-41; docs/known-issues.md).
- [I] `assay_result_metals.content_pct` is a percentage, 0–100. F and Cl are often reported in ppm, so a unit question arises.

**TOUCHES**
substances (2 rows plus a role column), contract_penalty_elements (becomes fillable), assay forms, metal-price pickers, recovery views (processing_metal_recovery would start reporting F/Cl "recovery" unless filtered [I]), contract_activation_missing, sale_settlement_compute penalty arithmetic.

## 20 · Calibration of measuring instruments

**HAVE** [M]: nothing instrument-shaped. `calibrat|校准|检定|标定|instrument` hits only unrelated senses: work-order basis 'calibrated' for yield estimates (app/operation/orders/new/NewWorkOrderForm.tsx:210; docs/processing-support-scoping.md:548), and the KPI rubric. 'weighbridge' appears only as a finance attachment type (app/components/finance/financeAttachmentTypes.ts:59). docs/cod-survey.md:277 says "no weighbridge ticket" anywhere.
- Weights enter as bare numbers: inbound_batches.quantity/declared_qty, processing legs, stocktake_counts.

**MISSING**
Instrument register, calibration events and certificates, valid-until, and a link from any reading (weight, assay) to an instrument. Nothing blocks pricing or certificates on an out-of-calibration reading.
**Precedent to copy** [M]: certificate_types.disposition block/warn/ignore + warn_lead_days, gating via a trigger (`supplier_receiving_blocked`; compliance-scoping.md CMPL-1). `equipment_service_intervals` provides a due/lead structure (interval_days, lead_days, disposition warn|ignore).
**TOUCHES** fixed_assets (instruments could be assets [I]), inbound_batches (weight capture), assay_results / laboratories (lab accreditation), apply_assay_result / issue_cod / CoA (gate points), operations_now (due arm).

## 21 · Spare parts & consumables issued during maintenance

**HAVE** [M]
- `equipment_maintenance` (equipment_id→fixed_assets, performed_on, kind service|repair, description, performer employee|supplier|name, downtime_id, **expense_id**, capitalised + reason + capitalised_expense_id; db/tables/equipment_maintenance.sql:21-61). Money flows only through `record_expense` (:3-6). UI: app/finance/assets/[id]/{MaintenancePanel,DowntimePanel,ServiceIntervalPanel}.tsx (module.processing.edit writes). The read-only operation view is /operation/equipment/[id].
- `material_kinds` seeds 'consumable' (耗材辅料) and 'spare_part' (备件), with may_ever_be_processed=false (db/tables/material_kinds.sql:79-83). The spare_part comment says: "挂在一台机器上、有关键度,而且不按批次追溯 —— 并进耗材会在保养模块接上它之前就把那条链丢掉".
- PO category 'consumables' → action.raise_po_consumables (warehouse) (purchase_orders.sql:80, po_category_raise_code.sql:18). Processing cost type 'consumables' → account 5140 (processing_cost_entries.sql:27; finance_journal_triggers.sql:20).

**MISSING** [M]
- No maintenance-parts lines (part, qty, from-location).
- Inventory is **batch-only**: `inventory_movements` requires an inbound or output batch (CHECK one_batch, :84). Movement types are receipt, processing_consume/produce, reversal_*, sale, writeoff, adjustment, status_change_*, transfer_*. There is **no issue-to-maintenance movement type** (:22-27).
- No min-stock, criticality, or machine↔part link. The safety-stock arm exists for batches (fixture 60).

**TOUCHES**
equipment_maintenance, inventory_movements (new movement type and an FK to maintenance), inbound_batches (how a consumable is held: a batch per receipt [I]), materials/material_kinds, expenses/5140 vs capitalisation, maintenance_settings.

## 22 · MTBF / MTTR

**HAVE** [M]
- `equipment_downtime` (equipment_id, started_at/ended_at timestamptz, reason text NOT NULL, generated `duration` interval; one open period per machine via uq_equipment_downtime_open; db/tables/equipment_downtime.sql:28-47).
- `equipment_maintenance.kind` service|repair and `downtime_id` link.
- `equipment_usage` view gives kg only; no hours are derivable (db/views/equipment_usage.sql:4-8).
- `equipment_service_status` / `equipment_service_intervals` (kg/day intervals), plus `equipment_maintenance_advice` (capitalisation advice only).
- **Explicit refusal on record**: "本刀刻意不算可用率,也不算 OEE … 分母没有人选过 … 返回条件:有人把分母定下来的那一天" (equipment_downtime.sql:58-63; equipment_service_status.sql:16,166; migration 2026-08-21-eqp2c…:346-352). Fixture 108 tests duration.

**MISSING**
- [M] Downtime has no failure-vs-planned classification; `reason` is free text.
- [M] No operating-hours source. processing_runs has only process_date, and G8 is open (forward-queue.md:1688).
- [I] MTTR is computable today as the mean `duration` over repair-linked downtime. MTBF is blocked by the same denominator ruling that blocks availability/OEE.

**TOUCHES** equipment_downtime (+ a cause/kind dictionary), equipment_maintenance, fixed_assets, processing_runs (hours, G8), shifts.

## 23 · Safety inspection checklists

**HAVE** [M]
- No inspection or checklist entity for safety. Near-shapes:
  - `handover_item_types`, a runtime-config checklist dictionary with is_required (db/tables/handover_item_types.sql), plus shift_handovers and `acknowledge_shift_handover`.
  - `lane_document_requirements` + `lane_checklist_status` (not_defined/defined_empty/defined).
  - `equipment_service_intervals` provides recurring due dates.
  - `training_records` (/hr/training).
- KPI O5 names "inspection logs, corrective-action register, HSE register, drill reports" as evidence (docs/kpi-framework.md:107-115; kpi_organisation.sql:119-120). They are evidence names only.

**MISSING** [M] Inspection templates, items, runs, findings, corrective actions, due/overdue arms, and a WSH/HSE permission code.
**TOUCHES** employees (inspector), storage_locations / fixed_assets (subject), operations_now (overdue arm), tasks (corrective actions could be tasks [I]), document_types.

## 24 · Thermal-runaway / emission monitoring → incident → affected batches

**HAVE** [M]
- No incident, alarm, sensor or emission entity: zero hits for incident/WSH/事故/alarm/emission/排放/热失控 in db objects except comments.
- The **WSH incident & near-miss register is queued** with trigger "第一个技师上岗". It carries the NEA duty "工伤或火灾事故须立即通报,并在两个工作日内提交书面报告" (forward-queue.md:1686; docs/processing-support-as-built.md:338-351, "法定时限只能有一个载体"). shift_handovers deliberately keeps **no** incident column (shift_handovers.sql:4,41).
- **A Tim decision constrains the design**: thermal-runaway *history* as a batch safety state "被考虑过,并且 Tim 决定不要 … 要加,先去问 Tim" (db/tables/inbound_safety_states.sql:44-50).
- Batch marking tools that exist:
  - `inbound_batch_safety_states` (multi-valued per batch; codes charged_not_discharged, discharged_verified, damaged_deformed, water_exposed, swollen_leaking; inbound_safety_states.sql:66-77).
  - `hold_stock(qty, reason, batch, location)` (inventory_movements stock_status on_hold, reason only as free-text notes).
  - `notifications` (event_type, subject_type/id/code, payload).
  - `operations_now` arms, rendered at /tools/reminders.
- There is no external ingestion path: no app/api and no supabase/functions (§0.2).

**MISSING** Incident register, alarm events, sensor/emission readings, an incident↔batch link, the NEA 2-working-day deadline arm, and an ingestion endpoint.
**TOUCHES** inbound_batches/output_batches + storage_locations (affected stock by location), hold_stock/inventory_movements, inbound_batch_safety_states (blocked by Tim's ruling), processing_runs, fixed_assets/equipment_downtime, company_compliance (licence), notifications, operations_now, public_holidays (working-day maths).

## 25 · Supplier scorecards → provisional price, prepayment ratio, sampling

**HAVE** [M]
- `suppliers.credit_rating text` is free text, used only in the new/export forms (app/suppliers/new/NewSupplierForm.tsx:212, export/route.ts:14). Other supplier facts: status + supplier_status_history + approval (action.supplier_approve), supplies_goods.
- Inputs for a scorecard:
  - `supplier_receipt_pattern` (short-delivery counts with denominators; deliberately **no** boolean and no percentage: "给原始计数,判断留给读的人", supplier_receipt_pattern.sql:26-28)
  - `grn_discrepancies`, `contract_grade_breaches`, `supplier_compliance` + `supplier_receiving_blocked` (certificate_types.disposition)
  - assay-vs-declared data
- Prepayment: `payment_term_templates` / `payment_term_template_lines.percentage` and `purchase_order_payment_terms.percentage` per trigger_event. `po_prepayment_applicable` view and `apply_prepayment` (module.finance.edit).
- Provisional price: `inbound_batches.pricing_status` unpriced|provisional|final (inbound_batches.sql:57-58). Pricing formulas plus `receipt_price_requests` → CFO.
- Sampling: `material_required_metals` holds required assay metals **per material**, not per supplier (ASY-P1). `batch_required_assay_gaps` exists.

**MISSING / conflicts**
- [M] No scorecard (zero hits).
- [M] **Ruling conflict**: docs/index-pricing-spec.md:174,187-188, ruling #2: "暂定价逐笔谈 —— 不设固定折扣,也不设合同级默认值 … 没有默认值可猜". A scorecard that sets the provisional price contradicts this. That spec is sell-side oriented; the purchase-side index linkage is "§9, open with Tim" (price_exposure_report.sql:144-150).
- [M] supplier_receipt_pattern's design refuses thresholds that nobody has chosen. A scorecard grade needs Tim to set thresholds.
- [M] No per-supplier sampling frequency.

**TOUCHES** suppliers, payment_term_templates / purchase_order_payment_terms (prepayment %), pricing_formulas / receipt_price_requests / inbound_batches.pricing_status, material_required_metals (or a supplier override), supplier_receipt_pattern, contract_grade_breaches, operations_now.

## 26 · Supplier statements

**HAVE** [M]
- `ap_open_items` view (inbound + expense open items, owner rights, module.finance.view; db/views/ap_open_items.sql). Pages: /finance/payables (+export route). `list_ledger_residue` plus /finance/list-vs-ledger, the AP-RECON-1 Batch B standing list-vs-ledger check (docs/handbacks/AP-RECON-1.md §0). AP-RECON-0 reconciled the list to account 2000 per supplier (docs/handbacks/AP-RECON-0.md §R "Per supplier").
- Customer-side precedent: `customer_statements` (frozen at issue) + `statement_issues` (8th member of the issue-archive family). Supporting objects: issue_customer_statement, next_statement_code, /finance/statements/[id]/pdf.

**MISSING** [M]
- No supplier statement in either direction: neither an *issued* AP statement nor a *received* supplier statement with a reconcile-against-ap_open_items step (zero hits).
- [M] Known residue: AP view vs ledger differences in docs/known-wrong-until-cutover.md (AP-RECON-1).

**TOUCHES** ap_open_items, payments/payment_allocations, prepayment_applications, expenses, suppliers, counterparty_contacts (recipient), document_types, issue-archive pattern, list_ledger_residue (explained differences).

## 27 · Supplier portal (external login)

**HAVE** [M]
- **There is no external-user concept.** Every account is an internal staff login. Roles: user_roles(user_id, role_id). Optional employee link: employee_accounts(user_id PK → employees). `has_permission()` is role/permission based, with no row scoping by counterparty.
- `counterparty_contacts` (supplier_id/customer_id, name, email, phone) has no auth link.
- Public surface: `PUBLIC_PATHS = ['/login','/verify/cod']`; `/set-password` is bare chrome (lib/loginRoute.ts:50,74). Idle timeout is 30 min (lib/session.ts:22).
- ANON-0 measured "anon may execute 1 of 492 functions (cod_verification)". All 25 `*_masked` views are granted to anon (owner rights), and the class is not closed (docs/anon-surface.md:53-100). The grants are guarded by db/check_grants.py, db/anon-grants-baseline.tsv and scripts/check-anon-grant-decision.mjs. `role 'employee'` is "unused" (roles.sql:105).
- app/me/avatar/route.ts:13 and lib/avatar.ts:25 note a reopen condition: "哪天有了对外的门户,就重开这一条" (avatar caching).

**MISSING** External identity (user↔supplier binding), supplier-scoped RLS on every relevant table, an invitation flow for externals, and a portal route group.
**TOUCHES** auth.users, user_roles/roles (new external role), every supplier-facing table's RLS (purchase_orders, inbound_batches, assay_results, ap_open_items, certificates_of_destruction, statements), lib/loginRoute.ts, proxy.ts/middleware, anon-grant baselines, change_log masking.

## 28 · Profit per incoming batch

**HAVE** [M]
- `batch_margin` view is per **output** batch: revenue from sales_records minus processing_outputs.unit_cost_base × qty_sold. Margin is NULL when cost is missing, and it carries cost_incomplete/is_stale/cogs_differs flags. The predicate is owner rights + `data.view_prices AND (finance.view OR processing.view)` (db/views/batch_margin.sql:1-49,108). This is AGENTS.md standing decision #2 (AGENTS.md:1024). Page /margin (app/margin/{page,MarginTable}.tsx); nav lib/modules.ts:524. Fixture 31.
- Cost side for inbound: `inbound_batch_valuation` (landed_unit_cost = purchase + freight + capitalised processing; INV-VAL-1). `batch_processing_cost_allocations`, `allocate_processing_costs`.
- Lineage: `batch_lineage` / `batch_lineage_all` (recursive, output → ancestors, quantity_consumed).

**MISSING** [M] No per-inbound-batch margin; the only per-batch margin is per output batch.
[I] Building one requires a **revenue attribution rule** from output back to multiple inputs (by mass consumed? by metal value?). No such rule exists, and per repo practice that is a Tim ruling, not a default. The reprocessing chain lengthens lineage (FIN-25).

**TOUCHES** batch_margin (extend or add a sibling), batch_lineage_all, processing_inputs/outputs, inbound_batch_valuation, sales_records, the same permission predicate (decision #2), /margin page or a new tab.

## 29 · Metal-price exposure of inventory

**HAVE** [M]
- /finance/price-exposure (COMM-1) → RPC `price_exposure_report()` (db/functions/price_exposure_report.sql). It covers sell-side contract positions only. Purchase side `'modelled': false`, and "0 would be a lie" (:141-153). QP calendar: `index_market_calendar` is empty, so averages refuse (:155-170). Fixture 150.
- Ingredients: inbound_batch_metals / output_batch_metals (content_pct with provenance content_source/source_assay_id), remaining_qty, metal_prices (+price_index, quote_delayed, anomaly_check), metal_price_indices, stock_snapshot, inbound_batch_valuation (cost).
- docs/metal-quote-staleness-report.md exists.

**MISSING** [M] No view or function multiplies on-hand quantity × content × market price. There is no NRV / lower-of-cost-and-NRV; it is mentioned only as a write-down judgement in docs/inventory-valuation-scoping.md:617.
[I] Content provenance matters: 19 legacy inbound content rows have NULL content_source (batch_required_assay_gaps.sql:9-11).
**TOUCHES** price_exposure_report (add an inventory section), inbound_batch_metals/output_batch_metals, metal_prices, derived_stock_qty / stock_snapshot, inbound_batch_valuation.

## 30 · Compliance report pack (NEA returns, material balance, EU recycling efficiency)

**HAVE** [M]
- docs/compliance-scoping.md says regulatory filing is "calendar-scoped", with nothing built (§D, :132-148). CMPL-1 built:
  - `company_compliance` with licence fields: cert_type_code→certificate_types, issue_date, status, approved_storage_limit_tonnes, document_path.
  - `licence_storage_within_limit()` raises 3 named codes.
  - `hazardous_qty_on_hand_tonnes()` **returns NULL by design** (D2: `waste_classifications` holds only focused/non_focused and is_controlled has zero consumers).
  - Fixture 152.
  - certificate_types seeds: basel, article_18, tfs, nea_import (block), gwdf, gwc, iso, other, insurance.
- Material balance: the /inventory page shows input/output/loss totals (app/inventory/page.tsx:325-377). `processing_metal_recovery` view: per run × metal recovery_pct, NULL ≠ 0, input/output source. `processing_run_loss_breakdown`; `loss_categories` (moisture, dust_spill, residue_disposal, electrolyte_evaporation); `loss_metal_fates` (stays/leaves/unknown). Queued: "监管口径的物料平衡" (forward-queue.md:1720; proc-reality item I, :702, "缺的是处置那一半"). Trigger: "拿到 NEA 的物料平衡报表格式那一天" (docs/proc-loss-and-saleability.md:139).
- Pack precedents: `management_packs` (frozen at month close) + freeze_management_pack / management_pack_data, page /finance/packs; gst_return_boxes (frozen at filing).

**MISSING** [M] No NEA return template, filing calendar or submission record. No EU Battery Regulation / recycling-efficiency calculation (zero hits for recycling efficiency / 2023/1542). No disposal leg in the material ledger. Phase-6 "ESG 与质量报告" (customer requirement) has no support (forward-queue.md:1694).
**TOUCHES** company_compliance, certificate_types, waste_classifications, processing_runs/outputs/losses, loss_categories, batch_lineage, management_packs pattern, document_types, operations_now (due arm), public_holidays.

## 31 · Shop-floor wall display (kiosk/TV)

**HAVE** [M]
- `operations_now` view (one UNION branch per waiting state, 46 UNION ALL branches; db/views/operations_now.sql) is rendered at /tools/reminders. That page was moved off the home page by CONV-7 and redrawn to rank items by days waiting (app/tools/reminders/page.tsx:1-30). It is also consumed by /operation and /finance overviews and lib/notifications.ts.
- The home page (app/page.tsx) is now only a search shell (CONV-6 ②③).
- docs/dashboard-arm-inventory.md is the arm spec (3 properties plus a destination); docs/exec-views-plan.md has four exec "first screens" (decided as permission bundles + arm-level predicates, not a new module). docs/kpi-framework.md has O1–O5; kpi_* tables exist at /hr/kpi.
- `/operation` overview is registry-derived links only, "不做经营内容" (lib/modules.ts:448).

**MISSING / constraints** [M]
- No kiosk, wall or TV route; no auto-refresh (zero setInterval or polling hits).
- The 30-min idle logout (lib/session.ts:22; IdleWatcher) would log a display out.
- The only unauthenticated paths are /login and /verify/cod. An anonymous display would widen an anon surface that ANON-0/COD-2 deliberately locked down.
- [I] A display account with a dedicated read-only role plus an idle exemption is the likely shape. It is a Tim decision.

**TOUCHES** operations_now, processing_wip / equipment_service_status / stock_by_status (tiles), lib/session.ts, middleware idle logic, roles/permissions (display role), lib/modules.ts.
