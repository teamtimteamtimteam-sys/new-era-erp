> Supporting evidence for `docs/surveys/MES-0/README.md`. Written by a read-only survey sub-agent on 2026-10-05 and re-read in full by the survey author. Tags as in that file.

# MES-0 · repo-a — what the repo already has, per function

Repo: `~/Documents/projects/new-era-erp` (read-only survey, 2026-10-05). DB not touched.
Markers: **[M]** = measured by reading repo files (path:line given) · **[I]** = inferred from code reading, not executed.
Live row counts quoted are the repo docs' own measurements (dated), not re-measured here.

---

## 0 · The current processing-record model (concise)

**Tables [M]**
- `processing_runs` (db/tables/processing_runs.sql:2-31) — header: `code` (PROC-YYYY-NNNN, trigger `generate_processing_code`, :112-121), `process_date date` (only world-side time; no start/end/shift), `total_input`, `total_output`, `loss_qty`, `notes`, `status ∈ {committed, reversed}`, `allocation_basis ∈ {weight, metal_value}` (chosen, no default), cost columns (`material/process/total/capitalized_cost_base`, `allocation_snapshot jsonb`, `allocated_at/by`, `capitalization_entry_id`), `work_order_id` (nullable = unplanned), `equipment_id → fixed_assets` (nullable = "unattributed"), `operation_type_code → operation_types` (required for new rows via NOT VALID CHECK `processing_runs_operation_type_required` + RPC `OPERATION_TYPE_REQUIRED`), soft-delete trio `deleted_at/by/delete_reason`.
- `processing_inputs` (db/tables/processing_inputs.sql) — one row per batch consumed: `run_id`, `inbound_batch_id` XOR `output_batch_id` (re-processing, FIN-25), `quantity_consumed`. Guard `guard_processing_input` enforces: function-context only (`PROCESSING_INPUT_DIRECT_INSERT`), no self-consume, `materials.may_be_processed`, per-operation safety-state acceptance (`operation_type_safety_states`), chemistry certainty `may_be_fed`.
- `processing_outputs` — `run_id`, `output_batch_id` (NOT NULL), `quantity_produced`, `allocated_cost_base`, `unit_cost_base`, `cost_incomplete`.
- `processing_run_losses` (PROC-BUILD-1) — PK (run_id, loss_category_code), `quantity > 0`, `notes`; Σ ≤ `loss_qty` (`LOSS_CATEGORIES_EXCEED_LOSS_QTY`); difference = "unexplained" (view `processing_run_loss_breakdown`). Editable after commit by `module.processing.edit` or `action.processing_aftercare`.
- `processing_cost_entries` (db/tables/processing_cost_entries.sql) — per-run money lines, `cost_type ∈ {labour, electricity, gas, depreciation, consumables, waste_treatment, other}`, `amount_base`, `is_estimate`, remitted/relieved settlement columns (FIN-6); history table `processing_cost_entry_history`; journal posted at entry (e.g. electricity Dr 5110 / Cr 2200, allocate_processing_costs.sql:260).
- `batch_processing_cost_allocations` (carrier rows for state-changing runs whose cost stays on the input batch).
- Dictionaries: `operation_types` (5 rows: deep_discharge [state_changing], manual_disassembly, electrode_line, electrode_powder_line, battery_powder_line [transforming]) db/tables/operation_types.sql seed; `operation_kinds` (transforming / state_changing); `operation_type_input_forms` / `_output_forms` (N×M routing; **only read by UI** app/operation/processing/new/page.tsx — no DB function enforces it [M by grep]); `operation_type_safety_states` (acceptance + `resolves`).
- Planning: `work_orders` (draft/released/closed/cancelled), `work_order_lines` (planned by material), `work_order_expected_outputs` (+ `basis`, `basis_reference`), `processing_settings` (WO overrun/shortfall %), view `work_order_fulfilment`.
- Shift: `shifts` (day/night, times NULL), `shift_handovers`, `shift_handover_items`, `shift_handover_equipment_refs`, `handover_item_types`. **No link from a run to a shift** (process_date is a date).

**Write path [M]** — single atomic RPC `commit_processing_run(p_process_date, p_notes, p_loss_qty, p_inputs jsonb, p_outputs jsonb, p_allocation_basis, p_work_order_id, p_equipment_id, p_operation_type_code)` (db/functions/commit_processing_run.sql:1). Validates (NO_INPUTS, NO_OUTPUTS / OPERATION_PRODUCES_NO_OUTPUTS, OUTPUT_EXCEEDS_INPUT, IOD_CONSUME_EXCEEDS_AVAILABLE, EQUIPMENT_NOT_ACQUIRED/DISPOSED, WO_NOT_RELEASED, STATE_CHANGE_LOSS_NOT_ZERO…), inserts header + legs, writes `inventory_movements` (processing_consume / processing_produce), creates output batches. `loss_qty = COALESCE(p_loss_qty, input − output)` (:299) — the only mass-balance assertion is the inequality output ≤ input. State-changing ops (deep discharge) don't consume stock: total_output := total_input, loss = 0, and they **delete resolved safety states and insert the resulting state on the whole batch** (:354-363).
- Permission: `action.processing_commit` to commit; `module.processing.view/edit`; `action.processing_aftercare` (losses + handovers); `action.processing_rollback`.
- Cost: `allocate_processing_costs(p_run_id)` (separate button, app/operation/processing/[id]/allocationActions.ts:13) splits material + process cost onto output legs by `allocation_basis`; staleness tracked by `processing_run_allocation_status.is_stale`.

**Editability / corrections [M]**
- Header + legs are effectively **append-only**: `guard_processing_direct_write` blocks direct INSERT/DELETE on runs/outputs/inputs and UPDATE of `status`/`work_order_id` (db/tables/processing_runs.sql:219-227). UPDATE policy remains for other header columns (registered debt `ROLE1B3B-PROCESSING-UPDATE-POLICIES`) — **[I]** so notes/allocation_basis/equipment_id could be changed by an edit-holder via direct UPDATE; allocation_basis change is stamped (`trg_processing_runs_basis_changed`).
- Quantities can't be edited. Correction = **whole-run reversal**: `rollback_processing_run` now refuses (`WAREHOUSE_NEEDS_APPROVED_REQUEST|rollback|code`, db/functions/rollback_processing_run.sql:15); path is `submit_rollback_request` → `warehouse_requests(kind='rollback')` → CFO approval → `rollback_processing_run_internal` (status=reversed, deleted_at, reversal movements). Then re-commit a new run.
- Post-commit editable satellites: `processing_run_losses`, `processing_cost_entries` (with history; settled rows locked by `guard_cost_entry_settled`).
- Status lifecycle: `committed → reversed` only. No draft / in-progress / partial. (docs/operation-model-scoping.md:177-191).

**Live reality (from docs, dated)**: 13–14 runs, all test residue; `fixed_assets` = 2 rows, both discharge machines not in service (operation-model-scoping.md:104-123, 230-247).

---

## Foundation · data-ingestion layer (devices, gateways, IoT, inbox, API, machine identity)

**HAVE [M]**
- Equipment registry = `fixed_assets` (category 'equipment'|'vehicle'|'office'|'other', code FA-YYYY-NNNN) — a finance asset card, not a device registry (db/tables/fixed_assets.sql). Satellites: `equipment_downtime` (started_at/ended_at timestamptz, reason, generated duration), `equipment_maintenance`, `equipment_service_intervals` (interval_kg / interval_days), `maintenance_settings`; views `equipment_usage` (kg-based from runs), `equipment_service_status`, `equipment_maintenance_advice`. UI: /operation/equipment, /operation/equipment/[id], /finance/assets/[id] (DowntimePanel, MaintenancePanel, ServiceIntervalPanel).
- Route handlers exist only as GET exports/PDF/labels/verify (`find app -name route.ts`: 30 routes — exports, pdf, label, /verify/cod/[token], /me/avatar). **No `app/api/` directory.**
- Service-role key used **only** for `auth.admin` invites: lib/supabase/admin.ts (header says "do not do business queries here"), consumer app/settings/accounts/accountActions.ts. Verify/avatar routes explicitly avoid service_role.
- Storage buckets (private): finance-attachments, supplier-/customer-/material-attachments, po-/so-/qt-/shipment-/invoice-/cn-/statement-/cod-/traceability-documents, company-assets.
- `*_issues` tables (po_issues, shipment_issues, cod_issues, traceability_report_issues…) = append-only "issued version" logs (version, file_path, sha256, issued_at/by) — a precedent shape for any print/reprint log.

**MISSING [M by grep]**
- `supabase/functions/` does not exist (supabase/ holds only `.temp`). No webhooks, heartbeats, IoT/gateway/sensor/PLC/MQTT/Modbus terms in db/app/lib. No device/machine-identity table, no API keys, no landing/inbox (staging) table, no ingestion RPC callable by a non-human principal. No equipment→operation_type link ("工序 ↔ 资产的关联 … 今天根本不存在", docs/forward-queue.md ~1688, processing_runs.equipment_id comment).
- No run start/end timestamps → no hours (equipment_usage.sql header).

**TOUCHES** fixed_assets (would need device identity/meter children), processing_runs (time columns), RLS model (every table uses `has_permission(...)` on `authenticated`; a machine writer needs a defined principal), db/anon-grants-baseline.tsv, check_mirrors/gate, document registry if new code-bearing tables.

---

## 1 · Weighbridge tickets (gross/tare/net, photo; carried into receipts & shipments)

**HAVE [M]**
- Receipt quantity = our scale weight in `inbound_batches.quantity` (+ `remaining_qty`, `unit` default kg), `declared_qty` (supplier-declared, NULL=not recorded), `arrival_date` (db/tables/inbound_batches.sql). Discrepancy view `grn_discrepancies` (declared vs received, states not refuses); `supplier_receipt_pattern`.
- Receipt RPCs: `create_inbound_batch`, `receive_inbound_batch_against_po` (field receiving /inbound/receive → app/inbound/receive/actions.ts:102; perm `action.receive_goods`). ReceiveForm comments: quantity "always belongs to the person on the scale" (ReceiveForm.tsx:5,125,255).
- Photo: `finance_attachments.doc_type` includes `'weighbridge'` (db/tables/finance_attachments.sql:38) with parent XOR incl. `inbound_batch_id` — but RLS = `module.finance.view/edit` (:62-77), i.e. an AP document attachment, not a floor record.
- Outbound: `shipments` (code SHP, ship_date, container_id), `shipment_lines.qty` (= reserved qty) + `location_id`; `containers` (no weights); `sales_settlements.gross_weight_kg`, `moisture_pct`, `settlement_weight_kg`, `weight_basis_used ∈ {as_received, dry}` (customer-side settlement, db/tables/sales_settlements.sql:50).
- Docs already name the gap: logistics-survey.md §B7 (~:230-240) "货代磅单量 无处可存 / 客户回称量 无处可存"; cod-survey.md:277 "no weighbridge ticket"; proc-loss-and-saleability.md:152-156 "称重差异没有位置 … 归属:称重与对账那一刀".

**MISSING [M]** no weighbridge ticket entity; no gross/tare/net columns anywhere (grep `tare|net_weight|皮重|地磅` → none in db); no vehicle/ticket number; no link ticket→receipt/shipment; no floor-accessible photo store for receipts; no shipment weights.

**TOUCHES** inbound_batches (quantity provenance), receive RPCs (2), finance_attachments (existing 'weighbridge' doc_type — overlap/duplication risk), shipments/shipment_lines, sales_settlements.gross_weight_kg, grn_discrepancies, document_types (new prefix if ticket gets a code).

---

## 2 · Discharge records per module (failed module → re-discharge / quarantine)

**HAVE [M]**
- Discharge is an operation: `operation_types.deep_discharge` (state_changing, resulting state `discharged_verified`), accepts `charged_not_discharged` (resolves=true) per `operation_type_safety_states`; inputs whole_pack/module/loose_cells/mixed_unsorted. Built PROC-WIRE-1B-i (docs/proc-operations-wired.md §0-3). Fixtures 158 (deep-discharge-can-actually-run), 159, 160 (discharge leaves cost on batch; rollback takes it back).
- Capability judgement: `deep_discharge_judgements` (can / cannot / not_assessed) on PO line and `inbound_batches.deep_discharge_actual_code` (PROC-1B-iii); difference surfaced by `grn_discrepancies`.
- Safety-state facts: `inbound_batch_safety_states`, `output_batch_safety_states` (multi-valued; dictionary `inbound_safety_states`: charged_not_discharged, discharged_verified, damaged_deformed, water_exposed, swollen_leaking).
- Alternative route for undischargeable: `battery_powder_line` accepts charged_not_discharged, damaged_deformed, swollen_leaking (operation_type_safety_states.sql:58-64).
- Machines: FA-2026-0001 Bosch Deep Discharging Machine, FA-2026-0002 Mobile Discharging Solution (not in service) — doc measurement.

**MISSING**
- Granularity is the **batch**, not the module: no serial/module identity anywhere (grep `serial_no|module_no|序列号|模组号` → none in db). [M]
- No per-item discharge outcome (pass/fail, voltage before/after, duration), no "failed" result state, no destination routing for failures, no re-discharge count. [M]
- **[I] Partial-quantity discharge flips the whole batch**: commit deletes the resolved state and inserts `discharged_verified` for the batch regardless of `quantity_consumed` vs remaining (commit_processing_run.sql:354-363); no check that the whole batch was put through.
- Quarantine: see §6 (no location type).

**TOUCHES** processing_inputs (per-module child rows or split batches), inbound/output_batch_safety_states, operation_type_safety_states, deep_discharge_judgements, commit_processing_run, batch_processing_cost_allocations, storage locations.

---

## 3 · Equipment meter readings; cost allocation by actual electricity

**HAVE [M]**
- Electricity is a **money line typed per run**: `processing_cost_entries.cost_type='electricity'`, `amount_base`, `is_estimate` (+ relieved by a real expense, FIN-6); journal Dr 5110 / Cr 2200 at entry (allocate_processing_costs.sql:260; accounts 5110 "Processing – Electricity", 6200 "Utilities").
- Run → outputs allocation by `allocation_basis` weight|metal_value (`allocate_processing_costs`).
- Equipment usage measured in kg only (`equipment_usage`), service intervals by kg/days.
- Per-operation cost per tonne query is possible but denominator (total_input vs total_output) is an open Tim ruling; shared costs across operations have "no carrier" (docs/processing-support-as-built.md:148-180, 458-470).

**MISSING [M]** no meter entity, no reading table, no kWh/units anywhere (grep `meter|kwh` → no db hits), no period utility-bill → runs/equipment allocation rule, no equipment↔operation link, no run duration to apportion by.

**TOUCHES** processing_cost_entries (+history, settlement guards, journal triggers `finance_journal_triggers`), allocate_processing_costs, expenses (utility bill → relief), fixed_assets/equipment_usage, accounts 5110/6200.

---

## 4 · Stock ceilings per licence; receipt over ceiling refused

**HAVE [M]**
- `company_compliance` (cert_type_code, cert_no, valid_from/until, status active/suspended/revoked, **`approved_storage_limit_tonnes`**) (db/tables/company_compliance.sql); UI /purchasing/licences (LicencePanel.tsx:38,217).
- `licence_storage_within_limit()` — refuses to judge with 3 distinct codes (LICENCE_STORAGE_LIMIT_NOT_SET / HAZARDOUS_QTY_NOT_COMPUTABLE / LICENCE_STORAGE_INPUTS_BOTH_MISSING); takes max limit across active licences, single plant-wide number.
- `hazardous_qty_on_hand_tonnes()` **unconditionally returns NULL** (waste classification can't express NEA approved categories yet).
- Fixture 152 (an-unset-limit-refuses-to-judge…).
- COD licence gate: `cod_governing_licence` / `issue_cod` (COD_LICENCE_NOT_RECORDED etc.) — governs certificates of destruction, not receipts.
- Location-class gate at receipt: `check_location_class` called by create_inbound_batch, receive_inbound_batch_against_po, create_output_batch, create_stock_transfer (allowed classes by `waste_classifications`).

**MISSING [M]** `licence_storage_within_limit` has **no caller** (grep: only its own file + company_compliance mirror) — no receipt refusal; no per-licence/per-category/per-location ceilings; hazardous tonnage not computable; licence "conditions as data" queued (forward-queue.md ~1684 "NEA 牌照下来时").

**TOUCHES** company_compliance, certificate_types, waste_classifications / materials.waste_classification_code, the two receipt RPCs + create_output_batch + transfer, check_location_class, storage_locations.

---

## 5 · Dwell-time warnings per safety state

**HAVE [M]**
- "AGING-1" in this repo is **AP/AR aging** (`ap_aging_asof`, `ar_aging_asof`, `aging_bucket`) — forward-queue.md:1029-1050 — not inventory aging.
- Inventory aging: `operations_now` arm `output_unsold_aging` hard-coded **60 days** on output batches (db/views/operations_now.sql:277-285). exec-views-plan.md:48 "危废存储天数 vs 牌照时限 — PARKED (NEA licence not held)"; :65 warns not to merge the 60-day number with the compliance limit.
- Timestamps available: `inbound_batches.arrival_date`, `inbound_batch_safety_states.created_at` / `output_batch_safety_states.created_at` (when a state was recorded).

**MISSING [M]** no per-safety-state dwell threshold (no column on `inbound_safety_states`), no state-entered-at history (states are deleted/inserted — current set only), no arm/notification for hazardous dwell.

**TOUCHES** inbound_safety_states (RUNTIME CONFIG — threshold column), safety-state fact tables, operations_now (new arm, fixture 30 per-arm), notifications.

---

## 6 · Quarantine locations (swollen / leaking)

**HAVE [M]**
- `storage_locations` (code "SG-…" by convention, name, zone free text "display only", is_active) — **no type/purpose column**. `storage_location_allowed_classes` keyed by `waste_classifications` only. UI /inventory/locations, `app/components/inventory/LocationPicker.tsx` (used in ReceiveForm, NewInboundForm, NewOutputForm).
- Location carried on `inventory_movements.location_id`; `evoltrya.location_ctx` set by receipt/output RPCs (inventory_ledger_triggers.sql:39-65). Views `stock_class_violations(_all)`, report /inventory/reports/violations (+pdf/export). Hold bucket `on_hold` via `hold_stock`/`release_stock` (status, not place).
- Safety states `swollen_leaking`, `damaged_deformed`, `water_exposed` exist; inbound_safety_states table comment: "它决定什么:能不能投料,以及怎么存放。存放那一半今天【没有落点】… 记成一条待办" (db/tables/inbound_safety_states.sql:36-40).
- Note: "/inventory/reports/safety" is **safety-stock (min qty)**, not hazard safety.

**MISSING** no quarantine location kind, no state→location rule/gate, no SoH/condition fields beyond the safety-state set. **[I]** processing outputs land with NULL location (commit_processing_run never sets location_ctx — grep "location" in it: no hits).

**TOUCHES** storage_locations (+allowed-classes analogue keyed by safety state), check_location_class (4 landing points), inventory_movements, safety-state fact tables, stock_class_violations, hold_stock.

---

## 7 · Labels: templates, printing, reprint log, UN3480/UN3090

**HAVE [M]**
- Batch QR labels: GET `app/inbound/[id]/label/route.ts` and `app/output/[id]/label/route.ts` (60 lines each) → self-contained HTML A6 148×105mm, `window.print()`; builder `app/components/labels/labelHtml.ts` (code, material, qty+unit, supplier|purity, bilingual fixed). QR (npm `qrcode`) encodes `/inbound/{id}/edit` (authenticated). Links: InboundTable.tsx:172, receive/done/[id]/page.tsx:107, OutputTable.tsx:101, output/[id]/edit/page.tsx:327.
- PDF stack: `@react-pdf/renderer`, 12 documents (docs/pdf-documents.md §1); issued-version logs `*_issues` (sha256) for external documents.
- UN/DG: only `forwarder_details` free-text DG classes; forward-queue.md:1682 queues "物料上的 HS 编码与 UN 编号,以及 DG 申报(UN3480/3481,第 9 类)" — trigger "第一次真实出口之前". material-classification-scoping.md:63.

**MISSING [M]** no label templates table, no printer config, no print/reprint log (label route writes nothing), no UN number / DG class / hazard marks on materials or labels, no label for containers/shipments, no ZPL/thermal printer integration.

**TOUCHES** materials (UN number/DG class columns), labelHtml.ts + 2 routes, issue-log pattern, document_types (if labels get codes), output/inbound batches.

---

## 8 · Scanning: receipt / transfer / feed / shipment

**HAVE [M]**
- Scan = phone camera reads label QR → opens the batch edit page (URL); during an open stocktake that page shows `StocktakeQuickCount` "扫码即点" (app/stocktakes/StocktakeQuickCount.tsx, inbound/[id]/edit/page.tsx:168, output/[id]/edit/page.tsx:119).
- UI sizing for "phone or scan gun" (`size="touch"` 48px; ReceiveForm.tsx:59; variant-c-spec.md).
- Search by code exists (`search_documents`, document_types match_columns) — a scan-gun keyboard wedge into a search box would work **[I]**.

**MISSING [M]** no in-app camera/barcode decoding (no BarcodeDetector/getUserMedia/zxing/html5-qrcode; package.json has only `qrcode` generator), no scan-driven flows for receipt, transfer (`create_stock_transfer`), feed (commit_processing_run inputs), or shipment (ship from queue), no scan event log.

**TOUCHES** create_stock_transfer, commit_processing_run (input picker), ship_goods flow (shipments), receive RPCs, label QR payload (currently an edit URL, not a code).

---

## 9 · Material balance per incoming batch & per month

**HAVE [M]**
- /inventory "物料平衡" = plant-wide **lifetime** Σ total_input / total_output / loss_qty / run count (app/inventory/page.tsx:325-329, 377-400); "快照页,不做日期筛选(既定约定)" (:11).
- Upward lineage `batch_lineage(_all)` (output → its parents, recursive); traceability report per **output** batch (`traceability_report_data`, /output/[id]/traceability/pdf, issues logged).
- Ledger `/inventory/reports/ledger` (inventory_movements by business_date range, material, batch code) — movement-level.
- Loss breakdown per run (`processing_run_loss_breakdown`); `cod_delivery_completion` computes how much of an inbound batch was consumed by un-reversed runs (for COD).
- Monthly period infra exists for finance (period_closes) but not for material balance.

**MISSING** no per-incoming-batch forward balance (in → outputs/losses/remaining), no monthly material balance, no "in = out + loss + stock" assertion (only output ≤ input) [M]. **[I]** multi-input runs give no per-input attribution of outputs/losses → a per-inbound-batch balance needs a proportional rule (a decision, not data). No home for weighing differences / un-weighed recycle streams (proc-reality.md:161; operation-model-scoping.md §2b, "heel", "不过磅的循环流").

**TOUCHES** processing_inputs/outputs/run_losses, inventory_movements, batch_lineage, cod_delivery_completion (already a partial per-batch consumption calc), /inventory page.

---

## 10 · Yield analysis per chemistry / supplier

**HAVE [M]**
- `processing_metal_recovery(_all)` per run × metal (input/output metal kg, recovery_pct only when both sides measured, `recovery_blocked_by` reasons); shown on app/operation/processing/[id]/page.tsx.
- `work_order_fulfilment` (plan vs actual, overrun/shortfall % from processing_settings).
- Chemistry dictionary `battery_chemistries` (NMC, NCA, LFP, LCO, LMO, LTO, 钠离子, 混合) — **on materials** (`materials.chemistry`), not on batches; batch has `chemistry_certainty_code`. Supplier on `inbound_batches.supplier_id`.
- Doc: "新物料必填 form_code … 按 NMC/LFP 分组比较收率今天分不出组" (forward-queue.md ~1690; only 2 of 9 materials have chemistry).

**MISSING** no yield view grouped by chemistry or supplier; no mass yield (output/input kg) view by any dimension [M]; no standard/target yields ("标准回收率仍然要等真实炉次"). Output assays 0 live (doc).

**TOUCHES** materials.chemistry/form_code, inbound_batches.supplier_id, processing_metal_recovery, batch_lineage.

---

## 11 · Process parameters & recipes saved with each processing record

**HAVE [M]** only `processing_runs.notes` (free text); `work_order_expected_outputs.basis/basis_reference` (where an expected number came from).
**MISSING [M]** no parameter/setpoint/recipe/BOM table (grep `recipe|配方|BOM|setpoint|process_param` → none in db except WO comment; proc-reality §4 "没有配方/BOM"); forward-queue.md:1862 lists "配方 / BOM 标准配比" as unbuilt.
**TOUCHES** processing_runs (child param rows keyed to operation_type), operation_types (parameter schema per op), commit_processing_run signature.

---

## 12 · Blending plans (black mass to spec)

**HAVE [M]** N-in-1-out runs structurally are blending (proc-reality.md:168); spec bounds live on contracts: `contract_grade_specs` (contract, material, metal→substances, min_pct/max_pct) + `contract_grade_breaches` view (report, not gate; frozen terms snapshot via contract_document_terms). Content per batch: `inbound_batch_metals` / `output_batch_metals` / `assay_results`.
**MISSING [M]** no blend plan entity, no target/tolerance on a run, no "is blending an operation" ruling (proc-reality.md:606 G11 note: "加工单上仍然没有「配到这个目标」的动作"); no blending operation_type.
**TOUCHES** operation_types (+blend op), processing_inputs, output_batch_metals, contract_grade_specs, assays.

---

## 13 · New fields

- **Material dictionary forms — VERIFIED 13 [M]** (db/tables/material_forms.sql:51-64; cols code, name_en, name_zh, implies_dismantling, may_be_sold, sort_order, notes): 1 whole_pack 整包 · 2 module 模组 · 3 loose_cells 散电芯 (not saleable) · 4 electrode_scrap 极片废料 · 5 black_mass 黑粉 · 6 mixed_unsorted 混合未分选 · 7 de_cased_cell 已开壳电芯 (not saleable) · 8 cathode_sheet 正极片 · 9 anode_sheet 负极片 (not saleable) · 10 separator 隔膜 · 11 casing 壳体 · 12 structural_parts 结构件 · 13 electrolyte 电解液. (Older doc count "6" in operation-model-scoping.md:122 is pre-PROC-WIRE.) Form is a **material** attribute (`materials.form_code`), not a batch attribute. Other material axes: kind (5), source (3), size_format (5), chemistry (8).
- **Wound/stacked construction**: none anywhere (grep pouch/prismatic/cylindrical/wound/stacked/卷绕/叠片 → only unrelated "stacked" letterhead variant) [M]. Batch-level attribute slots that exist: safety states, chemistry_certainty_code, deep_discharge_actual_code, source_reason.
- **Hard-case/pouch judgement + manual override count**: none [M]. Nearest pattern = judgement + actual with discrepancy (deep_discharge_judgements on PO line vs batch, grn_discrepancies).
- **Cross-contamination rate per shift**: none [M]; runs cannot be attributed to a shift (date only; processing-support-as-built.md §3.3).
- **Electrolyte loss measured/estimated**: loss category `electrolyte_evaporation` (metal_fate unknown, is_true_loss) exists; `processing_run_losses` has **no measured/estimated flag** (cost entries have `is_estimate`, losses don't) [M]. Electrolyte also a form (13) "planned to evaporate".
- **Dust collected in balance**: loss category `dust_spill` (metal leaves) exists; **no form/material for collected dust** (bag-filter dust as a recovered stream) — would be an output batch of some form [M/I].

**TOUCHES** inbound_batches / output_batches (new attribute columns ⇒ masked views + column grants: "遮蔽表加一列 = 三件事" inbound_batches.sql:308), material_forms/loss_categories (RUNTIME CONFIG seeds), processing_run_losses, shifts.

---

## 14 · Output-batch number prefixes via the existing numbering mechanism

**HAVE [M]**
- Registry table `document_types` (db/tables/document_types.sql): key PK, `prefix` UNIQUE, `table_name`, `numbering ∈ {gapless, gapped}`, `sequence_name`, `route`, `link_mode`, `label_column`, `match_columns`, `view_permission`. Migration-only (no write policy; "加一种单据是迁移级动作"). Reader `document_type_prefix(key)` raises `DOCUMENT_TYPE_PREFIX_MISSING` (db/functions/document_type_prefix.sql). 48 function/table files call it.
- **41 rows / 41 prefixes** (spec's ">30" holds): ASY, CHASE, COD, CTR, CN, EMP, CLM, FA, FCST, LV, MC, PAY, PF, PO, QT, SO, SHP, STMT, TRC, WO, CON, CUS, IN, MAT, OUT, PROC, ST, SUP, TASK, INV, PACK, BS, ATT, GST, JE, EXP, FRT, WHT, RCPT, PMT, PREQ.
- Format: mostly `PREFIX-YYYY-NNNN` (LPAD 4). **Not universal**: ATT-YYYY-MM, PACK-YYYY-MM, WHT-YYYY-MM (period-keyed), GST-YYYY-Qn, CON uses effective_from year. Gapped = nextval (9 types, 1,177 numbers burnt live); gapless = MAX+1 per year.
- **All output batches share one prefix `OUT` and one sequence `output_code_seq`** (output_batches.sql:16,93-98). Precedent for two prefixes on one table: `payment_receipt` RCPT + `payment_out` PMT both on `payments`.
- Registration/validation: migration inserts row (+mirror); `scripts/check-search-registry.mjs` (EXPECTED_ROWS = 41, route/link_mode checks); `scripts/check-document-registry.mjs` (every code-bearing table registered or in `document_type_exceptions` with reason; EXPECTED table counts); fixtures 100 (every code still mints identically, per prefix), 101, 102, 124, 199; `check_mirrors` SEED_TABLES row-compares it.

**MISSING** no per-form/per-product prefix for output batches; no mechanism choosing prefix by material/form [M]. **[I]** Adding e.g. BM-/CS- prefixes means new document_types rows (keys) all pointing at `output_batches`, a prefix-selection branch in `generate_output_code`, decisions on shared vs per-prefix sequence, bumping EXPECTED_ROWS and fixture 100 anchors, and search routing (`list_q` on /output matches by code).

**TOUCHES** document_types, generate_output_code trigger, output_code_seq, search_documents/search_recents, check-search-registry.mjs, check-document-registry.mjs, fixture 100.

---

## Cross-cutting permission codes (existing) [M]
module.processing.view/edit, module.inbound.view/edit, module.output.view/edit, module.inventory.view/edit, module.logistics.view, module.suppliers.view/edit (licences), action.processing_commit, action.processing_rollback, action.processing_aftercare, action.receive_goods, action.ship_goods, action.stocktake_count/post, action.batch_write_off, action.issue_cod, data.view_prices. No device/integration/machine permission.

## Key doc pointers
docs/proc-reality.md (Part 1 model; GAP LIST G-numbers), docs/operation-model-scoping.md (§2a-2g measurements; Q1-Q9), docs/proc-operations-wired.md (discharge), docs/proc-wire-1b-ii.md (output safety states, WIP), docs/proc-loss-and-saleability.md (losses/forms/saleability; weighing gap §152), docs/processing-support-as-built.md (op required, shifts, named gaps §5), docs/forward-queue.md (工艺路线 ~368-420; 阶段 6 compliance table ~1676-1700), docs/exec-views-plan.md:48,65 (dwell parked), docs/logistics-survey.md §B7 (which weight counts), docs/pdf-documents.md §1.
