# AUDIT-TRAIL-0 · Operation map: production and warehouse slice

Slice: `app/inbound/**`, `app/output/**`, `app/inventory/**`, `app/operation/**`, `app/materials/**`, `app/stocktakes/**`, `app/tools/**`, plus the `app/components/**` server actions these pages call (`inventory/stockActions.ts`, `inventory/warehouseRequestActions.ts`, `metals/metalContentActions.ts`, `pricing/termsRequestActions.ts`). Equipment actions in `app/finance/assets/[id]/actions.ts` are also mapped, because they record production steps (§3).
Survey date: 2026-09-29. Read-only. Every live query ran as `postgres` (rolbypassrls = true) inside `BEGIN READ ONLY … ROLLBACK`.

## 0. Method and headline counts

| # | Count | Value | Method / denominator | Status |
|---|---|---|---|---|
| 0.1 | `'use server'` files in the slice | **41** | `grep -rl "^.use server"` over the 7 slice dirs | Measured |
| 0.2 | Exported server actions in those files | **83** | `grep -cE "^export async function"` summed over the 41 files | Measured |
| 0.3 | …of which read-only (preview/quote/calc/download) | **7** | by reading each action: `repricePreview`, `previewAssayPrice`, `previewRepriceFromCommittedTerms`, `quoteSalePrice`, `getAttachmentDownloadUrl`, `convertBasis`, `calculatePrice` (their RPCs have empty `all` in fnmap.json) | Measured |
| 0.4 | Writing actions in the slice's own files | **76** | 83 − 7 | Measured |
| 0.5 | Component actions reached from slice pages | **13** writing | stockActions 3 + warehouseRequestActions 3 + metalContentActions 4 + termsRequestActions 3 (decide, withdraw, deactivateFormula). `submitContractActivation` and `suspendContract` are called only from `app/contracts/**`, which is outside this slice | Measured (grep of callers) |
| 0.6 | POST route handlers that write | **2** | `app/inbound/[id]/cod/pdf/route.tsx` (issue_cod + record_cod_issue), `app/output/[id]/traceability/pdf/route.tsx` (record_traceability_report_issue) | Measured |
| 0.7 | Equipment writing actions (finance/assets/[id]) | **7** | `grep "^export async function"` app/finance/assets/[id]/actions.ts | Measured |
| 0.8 | User-level operations in the map below | **106** writing rows (#1–#106; #50 and #52 are cross-reference rows, so **104** distinct writing operations) + 6 non-writing rows (#107–#112) | numbered rows in §1 (one row per user-distinguishable operation; an action that branches gets two rows, e.g. updateFormula → #80/#81) | Measured (row numbering of this file) |
| 0.9 | Pages in the slice (`page.tsx`) | **53** | `find … -name page.tsx` | Measured |
| 0.10 | Tables written (direct + transitive) by slice operations | **63** | union of `direct` and `all` in fnmap.json for every RPC above, plus direct `.from().insert/update/delete/upsert` targets and the trigger closure of those tables | Measured |
| 0.11 | …of those 63, how many carry the generic `change_log_capture` trigger | **63/63** | triggers.csv lookup | Measured |
| 0.12 | processing_runs on live | 14 total: 10 `committed`, 4 `reversed` | `select count(*), count(*) filter (where status=…) from processing_runs` (postgres, bypassrls) | Measured |
| 0.13 | processing_runs with `equipment_id` set | **0/14**. With `operation_type_code`: 1/14. With `work_order_id`: 1/14 | same query (postgres, bypassrls) | Measured |
| 0.14 | batch_audit_trail_all rows on live | **292** rows over **44** batches (24 inbound + 20 output batches exist, deleted ones included) | `select count(*), count(distinct (batch_kind,batch_id)) from batch_audit_trail_all` (postgres, bypassrls) | Measured |

Conventions used in the tables:
- **Perm** is the permission code the database enforces. For an RPC it comes from `require_permission` / `has_any_permission` in its source (funcs.csv). For a direct table write it comes from the table's RLS policy (db/tables/*.sql). Server actions in this slice do **no** permission check of their own: no `requireFunction`/`can()` occurs in any of the 41 files (Measured: perl scan found 0). Pages only gate the controls.
- **Direct** tables are written by the RPC body itself, or by the action's own `.from()` call. **Transitive** tables come from fnmap `all` minus `direct`, or from the trigger closure of a directly written table. `change_log` is left out everywhere, because every table has it. `all` is an upper bound; branches were not evaluated.
- **Kind**: **EVENT** = a business event the trail should name as one sentence. **EDIT** = a plain field edit (before/after rendering is enough). **SETTING** = a configuration singleton.
- Letters after a table name: I = insert, U = update, D = delete.

---

## 1. Operation map (grouped the way a user thinks)

### 1A. Receiving goods (inbound batch birth)

| # | Operation (user words) | UI entry (route · file · control) | Server action | RPC | Perm | Tables, direct | Tables, transitive | Primary record | Trail page | Kind |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Receive a batch against a PO (field receipt) | `/inbound/receive` · app/inbound/receive/page.tsx · `ReceiveForm` | app/inbound/receive/actions.ts:`createFieldReceipt` | `receive_inbound_batch_against_po` | action.receive_goods | inbound_batches:I | inbound_batch_safety_states:DI, inventory_movements:I (receipt), purchase_orders:U, purchase_order_history:I, approval_log:I, journal_entries/lines:I, notifications:I | inbound_batches | `/inbound/[id]/edit` | EVENT |
| 2 | Record a receipt (office form, optionally priced) | `/inbound/new` · app/inbound/new/page.tsx · `NewInboundForm` | app/inbound/new/actions.ts:`createInbound` | `create_inbound_batch` | action.receive_goods (+ action.price_receipts & data.view_purchase_prices when priced) | inbound_batches:I | as #1, plus price_history:I, receipt_price_requests:IU | inbound_batches | `/inbound/[id]/edit` | EVENT |

### 1B. Batch facts on an inbound batch (all on `/inbound/[id]/edit` · app/inbound/[id]/edit/page.tsx)

| # | Operation | Control | Server action | RPC / direct | Perm | Direct | Transitive | Primary | Trail page | Kind |
|---|---|---|---|---|---|---|---|---|---|---|
| 3 | Edit batch details (material, supplier, unit, arrival date, stage, notes) | `EditInboundForm` | edit/actions.ts:`updateInbound` | direct `inbound_batches.update` | RLS module.inbound.edit | inbound_batches:U | trigger closure: inventory_movements, journal_*, purchase_orders/_history, approval_log (guards only fire on price/qty) | inbound_batches | `/inbound/[id]/edit` | EDIT |
| 4 | Set intake condition / safety states (e.g. "swollen", "leaking") | `IntakeConditionPanel` | edit/intakeConditionActions.ts:`setIntakeCondition` | direct `inbound_batches.update` + `set_inbound_safety_states` | module.inbound.edit | inbound_batches:U, inbound_batch_safety_states:DI | — | inbound_batches | `/inbound/[id]/edit` | EVENT (hazard declared) |
| 5 | Record the deep-discharge actual | `DeepDischargePanel` | edit/deepDischargeActions.ts:`setDeepDischargeActual` | direct `inbound_batches.update` | RLS module.inbound.edit | inbound_batches:U | — | inbound_batches | `/inbound/[id]/edit` | EVENT (a production step with no document) |
| 6 | Save import diligence | `ImportDiligencePanel` | edit/importDiligenceActions.ts:`saveImportDiligence` | direct `inbound_batches.update` | RLS module.inbound.edit | inbound_batches:U | — | inbound_batches | `/inbound/[id]/edit` | EDIT |
| 7 | Explain the source (why there is no PO) | `SourceReasonPanel` | edit/sourceReasonActions.ts:`explainSource` | `explain_inbound_source` | module.inbound.edit | inbound_batches:U | inventory_movements, journal_*, purchase_orders/_history, approval_log | inbound_batches | `/inbound/[id]/edit` | EDIT |

### 1C. Weigh / metal content / assays

| # | Operation | UI entry | Server action | RPC / direct | Perm | Direct | Transitive | Primary | Trail page | Kind |
|---|---|---|---|---|---|---|---|---|---|---|
| 8 | Enter or change a metal-content line on an inbound batch | `/inbound/[id]/edit` · `MetalContentPanel` | app/components/metals/metalContentActions.ts:`saveInboundMetal` | direct `inbound_batch_metals.upsert` | RLS module.inbound.edit | inbound_batch_metals:IU | — | inbound_batches (child) | `/inbound/[id]/edit` | EDIT |
| 9 | Delete an inbound metal-content line | same | `deleteInboundMetal` | direct `inbound_batch_metals.delete` | RLS module.inbound.edit | inbound_batch_metals:D | — | inbound_batches | `/inbound/[id]/edit` | EDIT |
| 10 | Enter or change a metal line on an output batch | `/output/[id]/edit` · `MetalContentPanel` | `saveOutputMetal` | direct `output_batch_metals.upsert` | RLS module.output.edit | output_batch_metals:IU | — | output_batches | `/output/[id]/edit` | EDIT |
| 11 | Delete an output metal line | same | `deleteOutputMetal` | direct `.delete` | RLS module.output.edit | output_batch_metals:D | — | output_batches | `/output/[id]/edit` | EDIT |
| 12 | Record an assay (inbound); optionally "apply now" | `/inbound/[id]/assays/new` · assays/new/page.tsx · `AssayForm` | app/inbound/[id]/assays/actions.ts:`submitAssay` | `record_assay_result` (+ `apply_assay_result` if apply ticked) | module.inbound.edit (+ action.apply_assay) | assay_results:I, assay_result_metals:I | if applied: see #13 | assay_results | `/inbound/[id]/assays/[assayId]` and `/inbound/[id]/edit` | EVENT |
| 13 | Apply an assay to the batch (replaces metal content, reprices) | `/inbound/[id]/assays/[assayId]` · `ApplyAssayControls` | `applyAssay` | `apply_assay_result` | action.apply_assay | assay_results:U, inbound_batch_metals:DI, inbound_batches:U | price_history:I, pricing_term_commitments(+_metals):I, receipt_price_requests:IU, inventory_movements:I, journal_*:I, purchase_orders:U, purchase_order_history:I, approval_log:I | assay_results → inbound_batches | both pages | EVENT |
| 14 | Un-apply an assay | same | `unapplyAssay` | `unapply_assay_result` | action.apply_assay | assay_results:U | receipt_price_requests:U | assay_results | both pages | EVENT |
| 15 | Record an assay (output) | `/output/[id]/assays/new` · `OutputAssayForm` | app/output/[id]/assays/actions.ts:`submitOutputAssay` | `record_assay_result` (+ `apply_output_assay`) | module.output.edit (+ action.apply_assay) | assay_results:I, assay_result_metals:I | if applied: output_batch_metals:DI | assay_results | `/output/[id]/assays/[assayId]`, `/output/[id]/edit` | EVENT |
| 16 | Apply an output assay | `/output/[id]/assays/[assayId]` · `OutputApplyControls` | `applyOutputAssayAction` | `apply_output_assay` | action.apply_assay | assay_results:U, output_batch_metals:DI | — | assay_results → output_batches | both | EVENT |
| 17 | Un-apply an output assay | same | `unapplyOutputAssayAction` | `unapply_assay_result` | action.apply_assay | assay_results:U | receipt_price_requests:U | assay_results | both | EVENT |

Weighing: there is no separate "weigh" action. Quantity is fixed when the batch is received (`reject_quantity_change` trigger on inbound/output batches), and it only changes afterwards through movements: holds, transfers, stocktake adjustments, consumption. (Inferred from the trigger list plus the absence of any quantity-update action.)

### 1D. Pricing a receipt

| # | Operation | UI entry | Server action | RPC | Perm | Direct | Transitive | Primary | Trail page | Kind |
|---|---|---|---|---|---|---|---|---|---|---|
| 18 | Set or change a batch's unit price (may raise a price request if approvals are on) | `/inbound/[id]/edit` · `PricingPanel` | edit/pricingActions.ts:`setInboundPrice` | `set_inbound_unit_price` | action.price_receipts + data.view_purchase_prices | — | inbound_batches:U, price_history:I, receipt_price_requests:IU, approval_log:I, inventory_movements:I, journal_*:I, purchase_orders:U, purchase_order_history:I | inbound_batches | `/inbound/[id]/edit` | EVENT |
| 19 | Approve or reject a receipt price request | `ReceiptPriceRequestPanel` | `decideReceiptPriceRequest` | `decide_receipt_price_request` | module.inbound.view + data.view_purchase_prices (+ approval level) | receipt_price_requests:U | as #18 | receipt_price_requests → inbound_batches | `/inbound/[id]/edit` | EVENT |
| 20 | Withdraw my price request | same | `withdrawReceiptPriceRequest` | `withdraw_receipt_price_request` | action.price_receipts | — | receipt_price_requests:U | receipt_price_requests | `/inbound/[id]/edit` | EVENT |
| 21 | Reprice from committed contract terms / current content | `RepriceFromContentPanel` | app/inbound/[id]/assays/actions.ts:`repriceFromCurrentContent` | `reprice_from_committed_terms` | action.price_receipts + data.view_purchase_prices | — | as #18 | inbound_batches | `/inbound/[id]/edit` | EVENT |
| 22 | Apply a supplier prepayment to the batch | `PrepaymentPanel` | edit/prepaymentActions.ts:`applyPrepayment` | `apply_prepayment` | module.finance.edit | prepayment_applications:I | journal_entries/lines:I | prepayment_applications → inbound_batches | `/inbound/[id]/edit` | EVENT |

### 1E. Stock status on a batch (StockStatusPanel on `/inbound/[id]/edit` and `/output/[id]/edit`)

| # | Operation | Control | Server action | RPC | Perm | Direct | Transitive | Primary | Trail page | Kind |
|---|---|---|---|---|---|---|---|---|---|---|
| 23 | Put stock on hold | `HoldReleaseControls` | app/components/inventory/stockActions.ts:`holdStockAction` | `hold_stock` | module.inventory.edit | inventory_movements:I | — | inventory_movements → batch | batch page | EVENT |
| 24 | Release a hold | `HoldReleaseControls` | `releaseStockAction` | `release_stock` | module.inventory.edit | inventory_movements:I | — | same | batch page | EVENT |
| 25 | Move stock to another location | `TransferControl` | `transferStockAction` | `create_stock_transfer` | module.inventory.edit | inventory_movements:I, sales_order_reservations:U | notifications:I | same | batch page (also the storage location) | EVENT |
| 26 | Quick-count a batch (stocktake) | `StocktakeQuickCount` on both batch pages | app/stocktakes/actions.ts:`saveCount` | `record_stocktake_count` | action.stocktake_count | stocktake_counts:I, stocktake_lines:I, stocktakes:U | — | stocktakes | `/stocktakes/[id]` and batch page | EVENT |

### 1F. Write off a batch, roll back a run, void a COD (the warehouse-request family)

| # | Operation | UI entry | Server action | RPC | Perm | Direct | Transitive | Primary | Trail page | Kind |
|---|---|---|---|---|---|---|---|---|---|---|
| 27 | Write off an inbound batch directly (when no request is needed) | `/inbound` list · app/inbound/InboundTable.tsx → `DeleteButton` (ConfirmButton + reason) | app/inbound/actions.ts:`softDeleteInbound` | `soft_delete_inbound_batch` | action.batch_write_off | — | inbound_batches:U (deleted_at/by/reason), inventory_movements:I (write-off), journal_*:I, certificates_of_destruction:DIU, purchase_orders:U, purchase_order_history:I, approval_log:I | inbound_batches | **none today** (see §3) | EVENT |
| 28 | Write off an output batch directly | `/output` list · OutputTable → `DeleteButton` | app/output/actions.ts:`softDeleteOutput` | `soft_delete_output_batch` | action.batch_write_off | — | output_batches:U, inventory_movements:I, journal_*:I | output_batches | **none today** | EVENT |
| 29 | Request an inbound write-off | `DeleteButton` → `WarehouseRequestButton kind=write_off_inbound` | app/components/inventory/warehouseRequestActions.ts:`submitWarehouseRequest` | `submit_inbound_write_off_request` | action.batch_write_off | — | warehouse_requests:IU, approval_log:I; if approvals are off it executes at once (as #27) | warehouse_requests | subject batch page + `/inventory` | EVENT |
| 30 | Request an output write-off | same, kind=write_off_output | same | `submit_output_write_off_request` | action.batch_write_off | — | as #29 | warehouse_requests | subject + `/inventory` | EVENT |
| 31 | **Roll back a processing run** (request) | `/operation/processing/[id]` · `DeleteButton` → `WarehouseRequestButton kind=rollback` | same | `submit_rollback_request` | action.processing_rollback | — | warehouse_requests:IU, approval_log:I; if approvals are off: executes `rollback_processing_run_internal` | warehouse_requests → processing_runs | `/operation/processing/[id]` | EVENT |
| 32 | Request a COD void | `/inbound/[id]/edit` · `CertificatePanel` → `WarehouseRequestButton kind=cod_void` | same | `submit_cod_void_request` | action.issue_cod | — | warehouse_requests:IU, certificates_of_destruction:U (void) | warehouse_requests → certificates_of_destruction | `/inbound/[id]/edit` | EVENT |
| 33 | Approve or reject a warehouse request (this executes the write-off / rollback / void) | `/inventory` · app/inventory/page.tsx · `WarehouseRequestsPanel` | `decideWarehouseRequest` | `decide_warehouse_request` → `warehouse_request_execute_internal` | module.finance.view + data.view_prices (+ approval level) | warehouse_requests:U | inbound_batches:U, output_batches:U, processing_runs:U (status→reversed), inventory_movements:I, journal_entries:IU, journal_lines:I, certificates_of_destruction:DIU, purchase_orders:U, purchase_order_history:I, approval_log:I | warehouse_requests → subject | subject page + `/inventory` | EVENT |
| 34 | Withdraw my warehouse request | same panel | `withdrawWarehouseRequest` | `withdraw_warehouse_request` | raiser only; re-checks the kind's action code | warehouse_requests:U | — | warehouse_requests | subject + `/inventory` | EVENT |

### 1G. Certificates and reports that are issued

| # | Operation | UI entry | Handler | RPC | Perm | Direct | Primary | Trail page | Kind |
|---|---|---|---|---|---|---|---|---|---|
| 35 | Issue a Certificate of Destruction (stores the PDF bytes and records a version) | `/inbound/[id]/edit` · `CertificatePanel` → `fetch POST /inbound/[id]/cod/pdf` | app/inbound/[id]/cod/pdf/route.tsx | `issue_cod`, `record_cod_issue` (plus a storage upload) | action.issue_cod | certificates_of_destruction:U (pending→issued), cod_issues:I | certificates_of_destruction → inbound_batches | `/inbound/[id]/edit` | EVENT |
| 36 | Issue a traceability report | `/output/[id]/edit` · `TraceabilitySection` → `IssuePanel` → `POST /output/[id]/traceability/pdf` | app/output/[id]/traceability/pdf/route.tsx | `record_traceability_report_issue` | module.sales.edit OR module.processing.edit | traceability_report_issues:I | output_batches | `/output/[id]/edit` | EVENT |

### 1H. Output batches

| # | Operation | UI entry | Server action | RPC / direct | Perm | Direct | Transitive | Primary | Trail page | Kind |
|---|---|---|---|---|---|---|---|---|---|---|
| 37 | Create an output batch by hand | `/output/new` · `NewOutputForm` | app/output/new/actions.ts:`createOutput` | `create_output_batch` | module.output.edit | output_batches:I | inventory_movements:I, journal_*:I, notifications:I | output_batches | `/output/[id]/edit` | EVENT |
| 38 | Edit output details (material, customer, unit, date, purity, notes) | `/output/[id]/edit` · `EditOutputForm` | edit/actions.ts:`updateOutput` | direct `output_batches.update` | RLS module.output.edit | output_batches:U | trigger closure: inventory_movements, journal_* | output_batches | `/output/[id]/edit` | EDIT |
| 39 | Add a safety state to an output batch | `SafetyStatePanel` | edit/safetyActions.ts:`addOutputSafetyState` | direct insert | RLS module.output.edit | output_batch_safety_states:I | — | output_batches | `/output/[id]/edit` | EVENT |
| 40 | Remove a safety state | same | `removeOutputSafetyState` | direct delete | RLS module.output.edit | output_batch_safety_states:D | — | output_batches | `/output/[id]/edit` | EVENT |
| 41 | **Decide an output's purpose after processing** (sell / reprocess / dispose …) | `PurposePanel` | edit/purposeActions.ts:`setOutputBatchPurpose` | `set_output_batch_purpose` | module.processing.edit | output_batches:U | inventory_movements:I, journal_*:I | output_batches | `/output/[id]/edit` (+ source run page) | EVENT (production step, no document) |
| 42 | Record a direct sale of an output batch | `SalePanel` | edit/saleActions.ts:`recordSale` | `record_output_sale` | action.direct_sale | output_batches:U, sales_records:IU, sales_record_movements:I | inventory_movements:I, journal_*:I | sales_records → output_batches | `/output/[id]/edit` | EVENT |

### 1I. Processing runs (the production core). processing_runs.status ∈ {`committed`, `reversed`} only

| # | Operation | UI entry | Server action | RPC / direct | Perm | Direct | Transitive | Primary | Trail page | Kind |
|---|---|---|---|---|---|---|---|---|---|---|
| 43 | **Start / commit a processing run** (inputs consumed, outputs produced, operation type, optional work order) | `/operation/processing/new` · new/page.tsx · `NewProcessingForm` | app/operation/processing/new/actions.ts:`commitProcessingRun` | `commit_processing_run` | action.processing_commit | processing_runs:I (status `committed`), processing_inputs:I, processing_outputs:I, output_batches:IU, inbound_batches:U, inbound_batch_safety_states:DI, output_batch_safety_states:DI | inventory_movements:I (processing_consume / produce), journal_*:I, certificates_of_destruction:DIU (disposal), purchase_orders:U, purchase_order_history:I, approval_log:I | processing_runs | `/operation/processing/[id]` | EVENT |
| 44 | Add a processing cost entry (labour, electricity …) | `/operation/processing/[id]` · `CostPanel` | [id]/costActions.ts:`addCostEntry` | direct insert | RLS module.processing.edit | processing_cost_entries:I | processing_cost_entry_history:I (log_cost_entry_change), journal_*:I (fin_journal_cost_entry) | processing_runs (child) | `/operation/processing/[id]` | EVENT |
| 45 | Change a cost entry | `CostPanel` | `updateCostEntry` | direct update | RLS module.processing.edit | processing_cost_entries:U | processing_cost_entry_history:I, journal_*:I | same | same | EDIT (kept history) |
| 46 | Void a cost entry | `CostPanel` | `softDeleteCostEntry` | direct update (deleted_at) | RLS module.processing.edit | processing_cost_entries:U | history:I, journal_*:I | same | same | EVENT |
| 47 | **Record a run loss** (category, qty, metal fate) | `LossPanel` | [id]/lossActions.ts:`saveRunLoss` | direct upsert | RLS module.processing.edit OR action.processing_aftercare | processing_run_losses:IU | — | processing_runs | same | EVENT (no document) |
| 48 | Delete a run loss line | `LossPanel` | `deleteRunLoss` | direct delete | same | processing_run_losses:D | — | processing_runs | same | EVENT |
| 49 | **Allocate processing costs** (capitalise into outputs) | `AllocateButton` | [id]/allocationActions.ts:`runAllocation` | `allocate_processing_costs` | module.finance.edit | processing_runs:U (allocation_snapshot, allocated_at/by, cost bases), processing_outputs:U, batch_processing_cost_allocations:DI, sales_records:U | journal_entries:IU, journal_lines:I | processing_runs | same | EVENT |
| 50 | **Roll back a run**: request | see #31 | | | | | | | | EVENT |
| 51 | **Roll back a run**: approved and executed (status `committed`→`reversed`, deleted_at/by/delete_reason set, inputs restored, outputs removed, capitalisation undone) | see #33 (`/inventory` panel) | `decideWarehouseRequest` | `decide_warehouse_request` → `warehouse_request_execute_internal` → `rollback_processing_run_internal` | module.finance.view + data.view_prices | processing_runs:U, inbound_batches:U, output_batches:U | inventory_movements:I, journal_entries:IU, journal_lines:I, … | processing_runs | `/operation/processing/[id]`, which **hides reversed runs** (see §3) | EVENT |
| 52 | Set output purpose on a run's output | see #41 | | | | | | | | EVENT |

**Every status change and step of a processing run.** Measured: fnmap `direct` has `processing_runs` for exactly 3 functions. Their SET clauses were read from funcs.csv.

| Step | Where the state lives | Function that changes it | UI |
|---|---|---|---|
| Created as `committed` | processing_runs.status (CHECK `status IN ('committed','reversed')`, db/tables/processing_runs.sql:25) | `commit_processing_run` (INSERT) | #43 |
| Costs recorded / changed / voided | processing_cost_entries (+ processing_cost_entry_history; `guard_cost_entry_settled` locks them after allocation) | direct writes | #44–46 |
| Losses recorded | processing_run_losses | direct writes | #47–48 |
| Allocated / re-allocated (derived "allocated", "stale" via view processing_run_allocation_status; staleness sources include allocation_basis_changed_at) | processing_runs.allocated_at, allocation_snapshot, capitalization_entry_id | `allocate_processing_costs` (4 UPDATEs, no status literal) | #49 |
| Rollback requested (derived "rollback pending") | warehouse_requests(kind=rollback,status=submitted) | `submit_rollback_request` → `warehouse_request_submit_internal` | #31 |
| `committed` → `reversed` (+ deleted_at, deleted_by, delete_reason; capitalization cleared) | processing_runs.status | `rollback_processing_run_internal`, reached **only** from `warehouse_request_execute_internal`. `rollback_processing_run` exists but has **0 callers** in fnmap | #33/#51 |
| Output purpose decided | output_batches.purpose | `set_output_batch_purpose` | #41 |
| Equipment used | processing_runs.equipment_id → fixed_assets | `commit_processing_run(p_equipment_id)`, but **no app code passes `p_equipment_id`** (grep: 0 hits in app/ and lib/), and live shows 0/14 runs with equipment | none |

### 1J. Work orders (`/operation/orders/**`). work_orders.status ∈ {draft, released, closed, cancelled}

| # | Operation | UI entry | Server action | RPC / direct | Perm | Direct | Transitive | Primary | Trail page | Kind |
|---|---|---|---|---|---|---|---|---|---|---|
| 53 | Create a work order (status draft) | `/operation/orders/new` · `NewWorkOrderForm` | app/operation/orders/actions.ts:`createWorkOrder` | `create_work_order` | action.wo_create | work_orders:I, work_order_lines:I, work_order_expected_outputs:I, work_order_history:I (`created`) | — | work_orders | `/operation/orders/[id]` | EVENT |
| 54 | Release a work order (draft→released; approval when approvals are on) | `/operation/orders/[id]` · `WorkOrderActions` | `releaseWorkOrder` | `release_work_order` | action.wo_release | work_orders:U, work_order_history:I | approval_log:I | work_orders | same | EVENT |
| 55 | Close a work order (released→closed, reason required) | `WorkOrderActions` | `closeWorkOrder` | `close_work_order` | action.wo_create OR module.processing.edit | work_orders:U, work_order_history:I | — | work_orders | same | EVENT |
| 56 | Cancel a work order (draft/released→cancelled, reason required) | `WorkOrderActions` | `cancelWorkOrder` | `cancel_work_order` | same | work_orders:U, work_order_history:I | — | work_orders | same | EVENT |
| 57 | Amend lines or expected outputs (reason required) | `AmendLinesControl` | `amendWorkOrder` | `amend_work_order` | same | work_orders:U, work_order_lines:DIU, work_order_expected_outputs:DIU, work_order_history:I | — | work_orders | same | EVENT |
| 58 | Change work-order variance thresholds | `/operation/orders` · `WoThresholdPanel` | orders/thresholdActions.ts:`updateWoThresholds` | direct `processing_settings.update` | RLS module.processing.edit | processing_settings:U | — | processing_settings (singleton) | **no page of its own** (§3) | SETTING |

### 1K. Shift handovers

| # | Operation | UI entry | Server action | RPC | Perm | Direct | Primary | Trail page | Kind |
|---|---|---|---|---|---|---|---|---|---|
| 59 | Submit a shift handover (items, equipment-downtime references) | `/operation/handovers/new` · `NewHandoverForm` | app/operation/handovers/actions.ts:`submitShiftHandover` | `submit_shift_handover` | action.processing_aftercare OR module.processing.edit | shift_handovers:I, shift_handover_items:I, shift_handover_equipment_refs:I | shift_handovers | **no detail page** (§3) | EVENT |
| 60 | Acknowledge a handover (incoming shift only) | `/operation/handovers` · HandoversTable → `AcknowledgeButton` | `acknowledgeShiftHandover` | `acknowledge_shift_handover` | same | shift_handovers:U | shift_handovers | none | EVENT |

### 1L. Stocktakes. stocktakes.status ∈ {open, posted, cancelled}

| # | Operation | UI entry | Server action | RPC | Perm | Direct | Transitive | Primary | Trail page | Kind |
|---|---|---|---|---|---|---|---|---|---|---|
| 61 | Open a stocktake | `/stocktakes` · app/stocktakes/page.tsx (form) | app/stocktakes/actions.ts:`createStocktake` | `open_stocktake` | action.stocktake_count | stocktakes:I | — | stocktakes | `/stocktakes/[id]` | EVENT |
| 62 | Count a batch (list) | `/stocktakes/[id]` · `CountList` | `saveCount` | `record_stocktake_count` | action.stocktake_count | stocktake_counts:I, stocktake_lines:I, stocktakes:U | — | stocktakes | `/stocktakes/[id]` | EVENT |
| 63 | Cancel a stocktake | `/stocktakes/[id]` · `CancelStocktakeButton` | `cancelStocktake` | `cancel_stocktake` | module.stocktakes.edit | stocktakes:U | — | stocktakes | `/stocktakes/[id]` | EVENT |
| 64 | Post a stocktake (adjusts stock) | `/stocktakes/[id]/review` · `PostButton` | `postStocktake` | `post_stocktake` | action.stocktake_post | stocktakes:U, inventory_movements:I, inbound_batches:U, output_batches:U | journal_*:I, purchase_orders:U, purchase_order_history:I, approval_log:I | stocktakes | `/stocktakes/[id]` (+ each batch) | EVENT |
| (26) | Quick-count from a batch page | see #26 | | | | | | | | |

### 1M. Materials (`/materials/**`)

| # | Operation | UI entry | Server action | RPC / direct | Perm | Direct | Transitive | Primary | Trail page | Kind |
|---|---|---|---|---|---|---|---|---|---|---|
| 65 | Create a material | `/materials/new` · `NewMaterialForm` | app/materials/new/actions.ts:`createMaterial` | direct insert | RLS module.materials.edit | materials:I | notifications:I | materials | `/materials/[id]/edit` | EVENT |
| 66 | Edit a material (name, kind, processable, axes, waste class, safety stock …) | `EditMaterialForm` | [id]/edit/actions.ts:`updateMaterial` | direct update | RLS module.materials.edit | materials:U | notifications:I (trg_notify_material_reclassified) | materials | same | EDIT (reclassification = EVENT) |
| 67 | Delete a material | `/materials` · MaterialsTable → `DeleteButton` | app/materials/actions.ts:`softDeleteMaterial` | direct update (deleted_at) | RLS module.materials.edit | materials:U | — | materials | **none**; the page only shows live rows. /settings/deleted is admin-only | EVENT |
| 68 | Set required metals | `RequiredMetalsPanel` | requiredMetalsActions.ts:`saveRequiredMetals` | `set_material_required_metals` | module.materials.edit | material_required_metals:DI | — | materials | `/materials/[id]/edit` | EDIT |
| 69 | Attach a file (storage upload in the client, then record) | `AttachmentsPanel` | attachmentActions.ts:`recordAttachment` | direct insert | RLS module.materials.edit | material_attachments:I | — | materials | same | EVENT |
| 70 | Remove an attachment | `AttachmentsPanel` | `deleteAttachment` | direct update (soft) | RLS module.materials.edit | material_attachments:U | — | materials | same | EVENT |

### 1N. Storage locations (`/inventory/locations/**`)

| # | Operation | UI entry | Server action | Direct | Perm | Direct tables | Transitive | Primary | Trail page | Kind |
|---|---|---|---|---|---|---|---|---|---|---|
| 71 | Create a location (with allowed waste classes) | `/inventory/locations/new` · `LocationForm` | app/inventory/locations/actions.ts:`createLocation` | insert + allowed-classes insert | RLS module.inventory.edit | storage_locations:I, storage_location_allowed_classes:I | notifications:I | storage_locations | `/inventory/locations/[id]/edit` | EVENT |
| 72 | Edit a location / its allowed classes | `/inventory/locations/[id]/edit` · `LocationForm` | `updateLocation` | update + delete/insert classes | same | storage_locations:U, storage_location_allowed_classes:DI | notifications:I | storage_locations | same | EDIT |
| 73 | Activate / deactivate a location | LocationsTable and edit page · `LocationActiveToggle` | `setLocationActive` | update | same | storage_locations:U | — | storage_locations | same | EVENT |

### 1O. Pricing tools (`/tools/pricing/**`)

| # | Operation | UI entry | Server action | RPC / direct | Perm | Direct | Transitive | Primary | Trail page | Kind |
|---|---|---|---|---|---|---|---|---|---|---|
| 74 | Enter a metal price | `/tools/pricing/metal-prices/new` · `NewMetalPriceForm` | metal-prices/new/actions.ts:`createMetalPrice` | direct insert (+ read `metal_price_anomaly`) | RLS action.metal_prices | metal_prices:I | — | metal_prices | `/tools/pricing/metal-prices/[id]/edit` | EVENT |
| 75 | Edit a metal price | `[id]/edit` · `EditMetalPriceForm` | [id]/edit/actions.ts:`updateMetalPrice` | direct update | same | metal_prices:U | — | metal_prices | same | EDIT |
| 76 | Delete a metal price | `[id]/edit` · `DeleteButton` | `softDeleteMetalPrice` | direct update (deleted_at) | same | metal_prices:U | — | metal_prices | **none after delete** (edit page filters deleted_at) | EVENT |
| 77 | Bulk-enter metal prices | `/tools/pricing/metal-prices/bulk` · `BulkPricesForm` | bulk/actions.ts:`saveBulkPrices` | `upsert_metal_prices` | action.metal_prices | metal_prices:I | — | many metal_prices | list page `/tools/pricing/metal-prices` (one event, many rows) | EVENT |
| 78 | Change the price-anomaly threshold | `/tools/pricing/metal-prices` · `ThresholdPanel` | metal-prices/thresholdActions.ts:`updateAnomalyThreshold` | direct `pricing_settings.update` | RLS action.metal_prices | pricing_settings:U | — | pricing_settings | **no page of its own** | SETTING |
| 79 | Propose a new pricing formula | `/tools/pricing/formulas/new` · `FormulaForm` | formulas/actions.ts:`createFormula` | `submit_formula_create_request` | module.pricing.edit | pricing_formulas:I, pricing_formula_metals:I | terms_requests:IU, pricing_formula_history:I, contracts:U, approval_log:I | pricing_formulas | `/tools/pricing/formulas/[id]/edit` | EVENT |
| 80 | Propose a change to an active formula | `[id]/edit` · `FormulaForm` | `updateFormula` (isActive) | `submit_formula_change_request` | module.pricing.edit | — | terms_requests:IU, pricing_formulas:U, pricing_formula_metals:DI, pricing_formula_history:I, contracts:U, approval_log:I | pricing_formulas | same | EVENT |
| 81 | Propose reactivating a formula | same | `updateFormula` (inactive) | `submit_formula_reactivate_request` | module.pricing.edit | — | as #80 | pricing_formulas | same | EVENT |
| 82 | Deactivate a formula | `[id]/edit` · `DeactivateFormulaButton` | app/components/pricing/termsRequestActions.ts:`deactivateFormula` | `deactivate_pricing_formula` | module.pricing.edit | pricing_formulas:U | pricing_formula_history:I | pricing_formulas | same | EVENT |
| 83 | Delete a formula | `[id]/edit` · `DeleteFormulaButton` | formulas/actions.ts:`deleteFormula` | `delete_pricing_formula` | module.pricing.edit | pricing_formulas:U | pricing_formula_history:I | pricing_formulas | **none after delete** (edit page filters deleted_at) | EVENT |
| 84 | Approve or reject a terms request | `/tools/pricing/formulas` and `[id]/edit` · `TermsRequestsPanel` | termsRequestActions.ts:`decideTermsRequest` | `decide_terms_request` | module.pricing.view + data.view_prices + data.view_purchase_prices + module.customers/suppliers.view (+ approval level) | terms_requests:U | pricing_formulas:U, pricing_formula_metals:DI, pricing_formula_history:I, contracts:U, approval_log:I | terms_requests → pricing_formulas | formula page | EVENT |
| 85 | Withdraw my terms request | same panel | `withdrawTermsRequest` | `withdraw_terms_request` | raiser only | terms_requests:U | — | terms_requests | formula page | EVENT |

### 1P. Tasks (`/tools/tasks/**`)

| # | Operation | UI entry | Server action | RPC / direct | Perm | Direct | Transitive | Primary | Trail page | Kind |
|---|---|---|---|---|---|---|---|---|---|---|
| 86 | Create a task | `/tools/tasks` · `TaskModal` | app/tools/tasks/actions.ts:`createTask` | direct insert | RLS can_write_task | tasks:I | task_history:I, task_participants:IU | tasks | `/tools/tasks/[id]` | EVENT |
| 87 | Move a task on the board (todo/in_progress/done) | `TaskBoard` | `updateTaskStatus` | direct update | RLS can_write_task | tasks:U | task_history:I | tasks | same | EVENT |
| 88 | Edit task header (title, dates, owner …) | `/tools/tasks/[id]` · `TaskHeader` | [id]/actions.ts:`updateTaskHeader` | direct update | RLS can_write_task | tasks:U | task_history:I | tasks | same | EDIT |
| 89 | Delete a task | `TaskHeader` | `softDeleteTask` | direct update | RLS | tasks:U | task_history:I | tasks | none after delete | EVENT |
| 90 | **Record a task node** (add step) | `NodeTree` | `addNode` | direct insert | RLS can_write_task | task_nodes:I | task_history:I | tasks | same | EVENT |
| 91 | Rename node | `NodeTree` | `renameNode` | update | same | task_nodes:U | task_history:I | tasks | same | EDIT |
| 92 | Set node date | `NodeTree` | `setNodeDate` | update | same | task_nodes:U | task_history:I | tasks | same | EDIT |
| 93 | Tick a node done / undone | `NodeTree` | `setNodeDone` | update | same | task_nodes:U | task_history:I | tasks | same | EVENT |
| 94 | Remove a node | `NodeTree` | `removeNode` | delete | same | task_nodes:D | task_history:I | tasks | same | EVENT |
| 95 | Move / reorder a node | `NodeTree` | `moveNode` | update + `rebalance_task_nodes` | same | task_nodes:U | task_history:I | tasks | same | EDIT |
| 96 | Add participant | `Participants` | `addParticipant` | insert | RLS can_edit_task | task_participants:I | task_history:I | tasks | same | EVENT |
| 97 | Remove participant | `Participants` | `removeParticipant` | update | same | task_participants:U | task_history:I | tasks | same | EVENT |
| 98 | Promote a personal task to a team task | `Participants` | `promoteToTeam` | `promote_task_to_team` | inside the function (can_edit_task) | tasks:U | task_history:I, task_participants:IU | tasks | same | EVENT |
| 99 | Correct task type | `Participants` / page | `correctType` | `correct_task_type` | same | tasks:U | task_history:I, task_participants:IU | tasks | same | EVENT |

### 1Q. Equipment (production steps whose only UI is under Finance: app/finance/assets/[id]/actions.ts)

| # | Operation | UI entry | Server action | RPC / direct | Perm | Direct | Transitive | Primary | Trail page | Kind |
|---|---|---|---|---|---|---|---|---|---|---|
| 100 | **Service equipment** (record maintenance) | `/finance/assets/[id]` · `MaintenancePanel` | `recordMaintenance` | direct insert | RLS module.processing.edit | equipment_maintenance:I | — | fixed_assets | `/finance/assets/[id]` (gated module.finance.view) | EVENT |
| 101 | Capitalise a maintenance into the asset | `MaintenancePanel` | `capitaliseMaintenance` | `record_expense` | module.finance.edit | equipment_maintenance:U, expenses:I, fixed_asset_cost_entries:I, fixed_assets:IU, fixed_asset_depreciation_anchors:I | fixed_asset_history:I, journal_*:I | fixed_assets | same | EVENT |
| 102 | Open downtime (machine stopped) | `DowntimePanel` | `openDowntime` | direct insert | RLS module.processing.edit | equipment_downtime:I | — | fixed_assets | same (+ referenced by handovers) | EVENT |
| 103 | Close downtime | `DowntimePanel` | `closeDowntime` | direct update | same | equipment_downtime:U | — | fixed_assets | same | EVENT |
| 104 | Set a service interval | `ServiceIntervalPanel` | `saveServiceInterval` | insert/update | same | equipment_service_intervals:IU | — | fixed_assets | same | SETTING |
| 105 | Delete a service interval | `ServiceIntervalPanel` | `deleteServiceInterval` | delete | same | equipment_service_intervals:D | — | fixed_assets | same | SETTING |
| 106 | Set planned in-service date | `AssetActions` | `setPlannedInService` | `set_asset_planned_in_service` | module.finance.edit | fixed_assets:U | fixed_asset_history:I | fixed_assets | same | EDIT |

### 1R. Operations that write nothing (listed so they are not mistaken for gaps)

| # | Operation | Action | Why no trail |
|---|---|---|---|
| 107 | Preview reprice (assay page) | `repricePreview` → preview_reprice_inbound_batch | fnmap `all` = {} |
| 108 | Preview assay price | `previewAssayPrice` → preview_assay_price | {} |
| 109 | Preview reprice from terms | `previewRepriceFromCommittedTerms` | {} |
| 110 | Quote a sale price | `quoteSalePrice` → price_output_sale | {} |
| 111 | Convert weight/grade basis (`/tools/converter`) | `convertBasis` → convert_weight_basis / convert_grade_basis | {} |
| 112 | Metal price calculator (`/tools/pricing/calculator`) | `calculatePrice` → calculate_metal_price | {} |
| — | Attachment download URL | `getAttachmentDownloadUrl` | read only |
| — | `/tools/reminders`, `/tools/calendar`, `/operation`, `/operation/wip`, `/inventory/reports/**`, `/inventory/{inbound,output}/[materialId]` | no actions | computed or read-only views. Reminders have **no table**; they are computed in lib/reminders.ts |

---

## 2. Pages that should carry a trail: primary tables, child roll-ups, and access check

Join paths are the live FKs (`pg_constraint`, query saved in at0/live_fk_children.txt). Access is the page-level check found by grep (`requireModule(MOD.x)` = `module.x.view` from lib/modules.ts).

| Page (route · file) | Access check | Primary | Children that roll up (join) | Existing history UI today |
|---|---|---|---|---|
| `/inbound/[id]/edit` · app/inbound/[id]/edit/page.tsx | requireModule(MOD.inbound) = module.inbound.view; controls gated by can(module.inbound.edit / action.price_receipts / action.issue_cod / action.stocktake_count / module.finance.edit …) | inbound_batches (read via inbound_batches_masked, **`deleted_at IS NULL`**) | inbound_batch_metals.inbound_batch_id; assay_results.inbound_batch_id → assay_result_metals.assay_result_id; inbound_batch_safety_states.inbound_batch_id; price_history.inbound_batch_id; receipt_price_requests.inbound_batch_id; prepayment_applications.inbound_batch_id; pricing_term_commitments(+_metals); inventory_movements.inbound_batch_id; stocktake_lines / stocktake_counts.inbound_batch_id; processing_inputs.inbound_batch_id → processing_runs; batch_processing_cost_allocations.inbound_batch_id; certificates_of_destruction.inbound_batch_id → cod_issues.cod_id; warehouse_requests.inbound_batch_id; freight_allocations, payment_allocations, finance_attachments .inbound_batch_id; journal_entries.source_id; purchase_order_history via purchase_order_id; approval_log (subject_type/subject_id) | **BatchAuditTrail** (§4), MovementTimeline, price history table (PricingPanel), receipt-price-request history, prepayment history |
| `/inbound/[id]/assays/[assayId]` · …/assays/[assayId]/page.tsx | requireModule(MOD.inbound); can(action.apply_assay), canViewPurchasePrices() | assay_results | assay_result_metals.assay_result_id; inbound_batch_metals.source_assay_id; receipt_price_requests.assay_result_id; assay_results.superseded_by | none |
| `/output/[id]/edit` · app/output/[id]/edit/page.tsx | requireModule(MOD.output) = module.output.view; can(module.output.edit / module.processing.edit / action.direct_sale / action.stocktake_count …) | output_batches (**`deleted_at IS NULL`**) | output_batch_metals; assay_results.output_batch_id → assay_result_metals; output_batch_safety_states; inventory_movements; processing_outputs / processing_inputs .output_batch_id → processing_runs; sales_records.output_batch_id → sales_record_movements, sales_attribution_log, payment_allocations, invoice_lines, shipment_lines; sales_order_reservations; shipment_lines; traceability_report_issues; stocktake_lines/counts; warehouse_requests; sales_settlements | **BatchAuditTrail**, MovementTimeline |
| `/output/[id]/assays/[assayId]` | requireModule(MOD.output); can(action.apply_assay) | assay_results | assay_result_metals; output_batch_metals.source_assay_id | none |
| `/operation/processing/[id]` · app/operation/processing/[id]/page.tsx | requireModule(MOD.processing) = module.processing.view; can(module.processing.edit / action.processing_aftercare / action.processing_rollback / module.finance.edit) | processing_runs (via processing_runs_masked, **`deleted_at IS NULL`**, so reversed runs 404) | processing_inputs.run_id; processing_outputs.run_id; processing_cost_entries.run_id → processing_cost_entry_history.entry_id/run_id; processing_run_losses.run_id; batch_processing_cost_allocations.run_id; inventory_movements.run_id; warehouse_requests.run_id; journal_entries.source_id (run or cost entry); parent work_orders via work_order_id; fixed_assets via equipment_id; approval_log (warehouse_request subject) | only "last edited by" names on cost entries (loadActorNames on updated_by). **No trail** |
| `/operation/orders/[id]` · app/operation/orders/[id]/page.tsx | requireModule(MOD.processing); can(action.wo_create / action.wo_release / module.processing.edit) | work_orders | work_order_lines, work_order_expected_outputs, work_order_history (.work_order_id); processing_runs.work_order_id; approval_log (subject_type work_order) | work_order_history table (change_type + detail + who) |
| `/stocktakes/[id]` (+ `/stocktakes/[id]/review`) · app/stocktakes/[id]/page.tsx | requireModule(MOD.stocktakes) = module.stocktakes.view; can(action.stocktake_count / module.stocktakes.edit / action.stocktake_post) | stocktakes | stocktake_lines.stocktake_id → stocktake_counts.stocktake_line_id; inventory_movements (stocktake adjustments); journal_entries.source_id | only a "cancelled by" name |
| `/materials/[id]/edit` · app/materials/[id]/edit/page.tsx | requireModule(MOD.materials) = module.materials.view | materials | material_attachments, material_required_metals (.material_id) | none |
| `/inventory/locations/[id]/edit` | requireModule(MOD.inventory) = module.inventory.view | storage_locations | storage_location_allowed_classes.location_id; (inventory_movements.location_id: movements are location events, too many to roll up; link rather than roll up) | none |
| `/tools/pricing/metal-prices/[id]/edit` | requireEditPermission('action.metal_prices'). A viewer without the edit code **cannot open the detail page at all** | metal_prices | — | none |
| `/tools/pricing/formulas/[id]/edit` | requireModule(MOD.pricing); can(module.pricing.edit) | pricing_formulas (`deleted_at IS NULL`) | pricing_formula_metals.formula_id; pricing_formula_history.formula_id; terms_requests.formula_id; approval_log | TermsRequestsPanel (open and decided requests) |
| `/tools/tasks/[id]` | requireModule(MOD.tasks); can(TASKS_EDIT) | tasks | task_nodes, task_participants, task_history (.task_id) | **ChangeHistory** (task_history) |
| `/finance/assets/[id]` (outside slice; equipment host) | requireModule(MOD.finance) = module.finance.view; can(module.processing.edit) for the equipment panels | fixed_assets | equipment_maintenance, equipment_downtime, equipment_service_intervals (.equipment_id); fixed_asset_history; fixed_asset_cost_entries; processing_runs.equipment_id; shift_handover_equipment_refs → equipment_downtime | **HistoryPanel** (fixed_asset_history only; maintenance/downtime are not in it) |

List pages where operations happen but the record has **no detail page**:

| List page | Access | Records without a detail page | Operations launched there |
|---|---|---|---|
| `/operation/handovers` · app/operation/handovers/page.tsx | requireModule(MOD.processing) | shift_handovers (+ items, equipment refs) | #59 (from /new), #60 |
| `/inventory` · app/inventory/page.tsx (WarehouseRequestsPanel) | requireModule(MOD.inventory); can(module.finance.view, data.view_prices, …) | warehouse_requests | #33, #34 |
| `/operation/orders` (WoThresholdPanel) | requireModule(MOD.processing) | processing_settings (singleton) | #58 |
| `/tools/pricing/metal-prices` (ThresholdPanel, bulk) | requireModule(MOD.pricing) + requireFunction(FN.metalPrices) | pricing_settings (singleton); bulk batches of metal_prices | #77, #78 |
| `/inbound`, `/output`, `/materials` lists | module view | the row's own page exists, but write-off / delete happen here and the row's page then 404s | #27–30, #67 |
| `/stocktakes` | requireModule(MOD.stocktakes) | — (detail exists) | #61 |

Pages with **no access check** (by design, per header comments): `/tools/calendar`, `/tools/converter`, `/tools/reminders`. None writes.

---

## 3. Operations with no fitting page to host their trail

| Operation(s) | Why there is no fitting page (evidence) | Recommended home | Why |
|---|---|---|---|
| **Equipment**: service (#100), capitalise (#101), downtime open/close (#102–103), service intervals (#104–105) | The only equipment detail page is `/finance/assets/[id]`, gated `requireModule(MOD.finance)` = module.finance.view. But the writers are **module.processing.edit** (RLS on equipment_maintenance / equipment_downtime / equipment_service_intervals; read = finance.view OR processing.view). An operator with processing rights but not finance cannot open the page where these steps are recorded or shown. HistoryPanel shows fixed_asset_history only, not maintenance or downtime. Live counts (postgres, bypassrls): maintenance 2, downtime 1, service intervals 1 | an operation-side equipment page, e.g. `/operation/equipment/[id]`, gated module.processing.view, carrying the trail of maintenance, downtime, intervals, runs on this machine and handover refs; the finance page keeps the cost/depreciation trail | Tim's rule: key production steps with no document must leave a readable record where the production people look |
| **Equipment used on a run** | `commit_processing_run` has `p_equipment_id`, but no app code passes it (0 grep hits). Live: 0/14 runs have equipment_id | the run page (`/operation/processing/[id]`), once it is captured | there is nothing to trail yet; flag it as a capture gap, not a trail gap |
| **Roll back a run** (#31, #33/#51) | `/operation/processing/[id]` loads `processing_runs_masked … .is('deleted_at', null)`; rollback sets deleted_at, so the run's own page 404s exactly when its rollback needs to be read. The decision happens on `/inventory` (panel, no detail) | keep `/operation/processing/[id]` reachable for reversed runs (read-only, with a "reversed" banner) and host the trail there | the run is the primary record of the rollback |
| **Write off a batch** (#27–30, #33) | `/inbound/[id]/edit` and `/output/[id]/edit` filter `deleted_at IS NULL`, so the batch page (and its BatchAuditTrail) disappears after the write-off. `/settings/deleted` exists but is admin-only (action.manage_permissions) | same fix: read-only view of the written-off batch with the trail | same |
| **Warehouse requests** (submit / decide / withdraw) | no detail page; the list panel sits on `/inventory` | trail rows on the **subject** page (batch / run / COD's batch), plus a short "request history" block on `/inventory` | the user thinks "what happened to this batch", not "what happened to request #3" |
| **Shift handovers** (#59–60) | list only, no `[id]` page. Live: 0 handovers | `/operation/handovers/[id]` (a detail page showing items, equipment refs, and the ack trail); a row-level trail on the list is the lighter alternative | handovers are the textbook "no document" production record |
| **Storage locations** (#71–73) | have `/inventory/locations/[id]/edit`, so this is fine | that page | — |
| **Processing thresholds** (#58) and **price-anomaly threshold** (#78) | singletons edited from a panel on a list page | a small "setting changed" trail directly under each panel (or on a settings page if one is made) | SETTING rows; the page that edits them is the natural host |
| **Metal prices** (#74–77) | edit page exists but requires action.metal_prices to open (viewers can't); deleted prices 404; bulk upsert has no single record | trail on the list page `/tools/pricing/metal-prices` (by date/metal), with per-row trail on `[id]/edit` | prices are read by many and edited by few |
| **Pricing formulas** deleted (#83) | edit page filters deleted_at | read-only formula page for deleted ones | same pattern as batches |
| **Materials** deleted (#67) | edit page shows only live rows (the list does too) | same pattern | — |
| **Tasks** | detail page `/tools/tasks/[id]` already has ChangeHistory over task_history | extend that page | fits already |
| **Reminders** | computed from other tables (lib/reminders.ts); no reminders table, no writes | nothing to host | — |
| **Dictionaries used by production**: shifts, operation_types, handover_item_types, loss_categories, maintenance_settings, output_batch_states | no UI writer anywhere in app/ (grep: they are only *read* in operation/finance pages; app/settings/dictionaries/registry.ts covers substances, battery_chemistries, material_kinds, inbound_safety_states, laboratories, inbound_source_reasons) | none needed until a writer exists; changes arrive by migration | — |

---

## 4. What the existing "Audit Trail" on `/inbound/[id]/edit` and `/output/[id]/edit` shows today

**Code path (Measured by reading files).**
- `app/inbound/[id]/edit/page.tsx:603` and `app/output/[id]/edit/page.tsx:291` call `loadBatchAuditTrail(kind, id)` (app/components/audit/auditTrailQuery.ts). It reads the view **`batch_audit_trail`**, filtered by `batch_kind`/`batch_id` and ordered by `occurred_at`. `mustRows`: if the query fails, the page fails. It is rendered at the bottom by `BatchAuditTrail.tsx` → `BatchAuditTrailTable.tsx` (DataTable).
- `batch_audit_trail` (db/views/batch_audit_trail.sql) is `security_invoker = off` over `batch_audit_trail_all`. The outer WHERE is `has_any_permission(module.inbound/output/inventory/processing/finance/sales/purchasing/stocktakes .view)`. Per row it sets `may_view = has_permission(module_code)`. When a row is not viewable, it NULLs actor_id, source_id, source_code, href and detail. It adds the seam **`amount_restricted`** when `has_masked_amount` is present and the reader lacks data.view_purchase_prices (for price_change) or data.view_prices (for all other kinds). It adds **`actor_unresolvable`** when actor_id matches no employees.user_id or employee_accounts.user_id.
- `batch_audit_trail_all` (db/views/batch_audit_trail_all.sql, 553 lines) is 20 `UNION ALL` arms and is REVOKEd from authenticated and anon. Every arm has `actor_space = 'auth'` (20/20; 0 arms use 'employee').

**The 20 arms (event_kind → source table · module_code · built-in seams · href):**

| event_kind (English label) | Source | module_code | Seams set in the arm | href |
|---|---|---|---|---|
| receipt ("Received") | inbound_batches (creation only) | module.inbound.view | no_purchase_order, actor_unrecorded | /inbound/{id}/edit |
| output_created ("Output batch created") | output_batches (creation only) | module.output.view | actor_unrecorded | /output/{id}/edit |
| movement ("Stock movement") | inventory_movements | module.inventory.view | actor_unrecorded, run_voided | NULL |
| price_change ("Price change") | price_history | module.inbound.view | has_masked_amount, actor_unrecorded | /inbound/{id}/edit |
| run_input ("Consumed by processing run") | processing_inputs ⋈ processing_runs | module.processing.view | run_voided, actor_unrecorded | **/processing/{run_id}** |
| run_output ("Produced by processing run") | processing_outputs ⋈ processing_runs | module.processing.view | run_voided, actor_unrecorded | **/processing/{run_id}** |
| cost_allocation | batch_processing_cost_allocations | module.processing.view | actor_unrecorded | **/processing/{run_id}** |
| cost_entry_change | processing_cost_entry_history ⋈ processing_inputs | module.processing.view | has_masked_amount, actor_unrecorded | **/processing/{run_id}** |
| sale ("Sold") | sales_records | module.finance.view | has_masked_amount, no_cogs_entry | /output/{id}/edit |
| sale_movement | sales_record_movements | module.finance.view | **always** actor_unrecorded (actor hard-coded NULL) | NULL |
| attribution ("Credit attribution") | sales_attribution_log | module.finance.view | — | NULL |
| reservation | sales_order_reservations | module.sales.view | — | NULL |
| shipment ("Shipped") | shipment_lines ⋈ shipments | module.sales.view | — | NULL |
| stocktake_line ("Counted in stocktake") | stocktake_lines | module.stocktakes.view | — | /stocktakes/{id} |
| report_issued ("Traceability report issued") | traceability_report_issues | module.processing.view | — | /output/{id}/edit |
| approval ("Approval decision") | approval_log, **only subject_type purchase_order (via the batch's PO) or work_order (via runs that consumed the batch)** | purchasing.view / … | no_policy_admits when subject ≠ purchase_order | NULL |
| work_order_change | work_order_history ⋈ runs ⋈ inputs | module.processing.view | — | NULL |
| po_change | purchase_order_history ⋈ inbound_batches.purchase_order_id | module.purchasing.view | — | NULL |
| so_change | sales_order_history ⋈ sales_records | module.sales.view | — | NULL |
| journal_entry | journal_entries reached via source_id (inbound batch, sales record, cost entry, run, stocktake) + reversed_by | module.finance.view | polymorphic_source, reversed, is_reversal | /finance/journal/{id} |

**Seams (11, from auditTrailTypes.ts):** no_purchase_order, actor_unrecorded, actor_unresolvable, polymorphic_source, reversed, is_reversal, run_voided, has_masked_amount, amount_restricted, no_policy_admits, no_cogs_entry. Each is rendered as a "⚠ sentence" under the row. The footer names 6 history tables that cannot be reached from a batch: quote_history, task_history, customer_credit_history, employment_history, fx_rate_history, pricing_formula_history.

**What the screen prints per row:** When · (Business date if it differs) · What (`auditTrail.kind.*`) · Detail · Who (`ActorName`) · Source (source_code, falling back to source_table, as a link when href is set). Detail comes from `summarise()`, which prints these detail keys raw and joined with " · ": movement_type (translated), qty_delta, quantity_consumed, quantity_produced, amount_base, memo, **change_type** (raw, e.g. `create`), **decision** (raw, e.g. `auto_approved`), shipment_code, stocktake_code.

**Live distribution (Measured; postgres, bypassrls, file at0/live_audit_counts.txt).** 292 rows over 44 batches. Inbound: movement 56, journal_entry 26, receipt 24, price_change 14, run_input 13, approval 11, cost_entry_change 7, stocktake_line 4, work_order_change 2, cost_allocation 1. Output: movement 51, journal_entry 21, output_created 20, run_output 17, sale 9, sale_movement 9, reservation 3, shipment/run_input/attribution/report_issued 1 each. Seams: polymorphic_source 47, has_masked_amount 30, actor_unrecorded 29, run_voided 22, no_purchase_order 14, no_cogs_entry 7, reversed 3, is_reversal 3, no_policy_admits 1. (`amount_restricted` and `actor_unresolvable` are added by the outer view per reader and do not appear in `_all`.)

**Sample: live output of `batch_audit_trail_all` for IN-2026-0152** (id d719cc6e-…; the inbound batch with the most distinct kinds, 11 rows / 7 kinds). The base view needs no JWT, so this is the full un-gated content. The outer `batch_audit_trail` needs `auth.uid()` for has_permission, so it was **not** run; as postgres with no JWT every has_permission would be false. Actor shown as the first 8 hex digits.

| occurred_at | kind | module | actor | source_table · code | href | detail (truncated) | seams |
|---|---|---|---|---|---|---|---|
| 2026-08-05 12:20 | approval | purchasing.view | 321f1819 | approval_log · PO-2026-0002 | — | decision auto_approved, subject purchase_order | — |
| 12:21 | receipt | inbound.view | 321f1819 | inbound_batches · IN-2026-0152 | /inbound/…/edit | unit kg, stage 已加工完, status draft, quantity 405 | — |
| 12:21 | movement | inventory.view | 321f1819 | inventory_movements · (no code) | — | qty_delta 405, receipt, available | — |
| 12:23 | price_change | inbound.view | 321f1819 | price_history · (no code) | /inbound/…/edit | currency USD | has_masked_amount |
| 12:23 | journal_entry | finance.view | 321f1819 | JE-2026-0025 | /finance/journal/… | memo "Pricing IN-2026-0152", posted | polymorphic_source |
| 12:24 | movement | inventory.view | 321f1819 | inventory_movements | — | qty_delta −405, processing_consume | — |
| 12:24 | run_input | processing.view | 321f1819 | processing_inputs · PROC-2026-0107 | **/processing/4796d43a-…** | quantity_consumed 405, operation_type_code null | — |
| 12:26 | cost_entry_change | processing.view | 321f1819 | PROC-2026-0107 | **/processing/…** | change_type create, labour | has_masked_amount |
| 12:26 | journal_entry | finance.view | 321f1819 | JE-2026-0026 | /finance/journal/… | "Cost PROC-2026-0107 labour" | polymorphic_source |
| 12:26 | journal_entry | finance.view | 321f1819 | JE-2026-0027 | /finance/journal/… | "Cost PROC-2026-0107 electricity" | polymorphic_source |
| 12:26 | cost_entry_change | processing.view | 321f1819 | PROC-2026-0107 | **/processing/…** | change_type create, electricity | has_masked_amount |

The same batch has 1 assay_result and 6 inbound_batch_metals rows (postgres, bypassrls). **Neither appears in its trail.**

**Gaps and defects in today's trail (Measured unless marked):**
1. **Dead links.** 4 arms (run_input, run_output, cost_allocation, cost_entry_change) link to `/processing/{id}`. No `app/processing` route exists, and next.config.ts and proxy.ts contain no redirect for it (grep: 0 hits). The real route is `/operation/processing/[id]`. Live: 13 + 1 + 17 + 1 + 7 = 39 such rows carry this href.
2. **Machine tokens reach the screen.** When source_code is NULL (every movement and price_change row), the Source column prints the raw table name (`inventory_movements`, `price_history`). Detail prints raw `change_type` (`create`) and `decision` (`auto_approved`). The `receipt` detail carries `status: draft` and the Chinese `stage` value. The approval detail shows subject_type raw. (Inferred from summarise() plus the sample.)
3. **Only the creation of a batch is an event.** None of these produce a row: field edits (#3, #38), intake condition / safety states (#4, #39–40), deep discharge (#5), import diligence (#6), source reason (#7), metal content (#8–11), **assays recorded / applied / unapplied (#12–17)**, receipt price requests (#18–20, except through price_history), prepayment (#22), output purpose (#41), run losses (#47), warehouse requests themselves (#29–34; only their movement and journal effects appear), COD issue (#35; cod_issues has no arm), stocktake counts before posting (stocktake_counts has no arm). The `approval` arm reaches only purchase_order and work_order subjects, not receipt_price_request, warehouse_request or terms_request approvals.
4. The `amount_restricted` sentence always says "you do not hold data.view_prices", even for price_change rows, where the view actually checks data.view_purchase_prices (en.ts `auditTrail.seam.amount_restricted` vs the view's CASE).
5. After a write-off the whole trail is unreachable, because both edit pages filter `deleted_at IS NULL` (§3).
6. `change_log` (HISTORY-1) is not used by the trail at all. The trail is built only from domain tables and history tables.
