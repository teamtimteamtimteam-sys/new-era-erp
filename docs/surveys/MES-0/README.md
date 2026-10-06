# MES-0 — survey for the MES/MOM function group (2026-10-05)

**STOP GATE.** Read-only survey. No code edit, no migration, no live write. The only writes are the specification PDF
(renamed and committed alone, `78e549ff`) and the files in this directory. Waiting on Tim's answers to Q1–Q96 (§9).

**Opening check (19:0x CST).** U1-A is closed: `docs/forward-queue.md:255` (item 34, "✅ 工资与个人数据按角色可见 —— U1-A") and
`docs/handbacks/U1-A.md` exist. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
`c062ff3a610ee0a7f161e2b65257690261de7163`. Tree clean apart from the untracked specification PDF.

**Step 1.** `docs/Data capture and ERP integreation.pdf` renamed to `docs/Data_capture_and_ERP_integreation.pdf`, committed alone by
explicit path ("Docs: data-capture and ERP interface specification (Tim)", `78e549ff`), pushed. Read in full (11 pages, §1–§10).

**Live state (measured, read-only, as `postgres`, `rolbypassrls = true`, base tables, 19:16–19:45 CST; queries in
`live-readings.sql`, every one inside `BEGIN READ ONLY … ROLLBACK`):**
- 7 accounts in `auth.users`, 0 banned: tim@ cfo · admin@ admin · chooer@ finance · sandra@ cco · phua@ cto · vince@ gm · fusheng@ warehouse.
- `finance_settings`: `approvals_enabled = true`, level 1 `finance`, level 2 `cfo`, threshold `1000` (base currency).
- 242 public base tables; **238** carry the `zzz_change_log` capture trigger; `change_log` itself carries only its append-only guard;
  the other three (`festival_doodles`, `home_greetings`, `notification_reads`) carry neither.
- Nothing was written. No code, no migration.

**How the facts were gathered.** Seven read-only sub-agents read the mandated documents in full and mapped the repo
(forward queue in two halves; approvals / change log / role matrix; functions 1–14; functions 15–31; known issues and gateway
authentication; cut durations). Their working files are outside the repo; the two repo maps and the duration table are copied
beside this file (`evidence-functions-01-14.md`, `evidence-functions-15-31.md`, `cut-durations.md`) after being read in full.
Every claim this README rests on was either re-read at its cited location or re-measured live. Tags used throughout:
**[M]** measured (a file:line, a grep, or a named live query with its identity) · **[I]** inferred (code reading, not executed) ·
**[S]** read from the specification PDF.

---

## §0 · What the survey changed in the scope

1. **Several of the 31 functions are already partly built** and become completions, not new modules [M]:
   the licence storage limit and its refusal function exist (`company_compliance.approved_storage_limit_tonnes`,
   `licence_storage_within_limit()`), but the on-hand figure is hard-wired to NULL and nothing calls the check;
   sell-side assay arbitration is built (`splitting_limit_pct`, `RESULTS_EXCEED_SPLITTING_LIMIT` refusal = the settlement hold);
   contract penalty elements, sample-retention terms, batch QR labels, per-output-batch margin, sell-side price exposure,
   equipment downtime / maintenance / service intervals and the reminder view (`operations_now`, 46 arms) all exist.
2. **The specification's stage model and the live operation dictionary disagree** [M]. Live `electrode_line` is casing removal **and**
   electrode separation as **one** operation, by Tim's R2 interview ("开壳与极片分离是【一道】工序") — the specification makes them two
   stages on separate equipment (hard-case / pouch; wound / stacked). Powder stripping outputs are a single form `black_mass`; the
   specification requires cathode powder + aluminium foil + dust and anode powder + copper foil + dust. Q37.
3. **A defect inside the discharge path** [I, code read]: committing a deep-discharge run flips the **whole** batch to
   `discharged_verified` regardless of the quantity put through (`commit_processing_run.sql:354-363`). Per-module results (function 2)
   replace that rule.
4. **Gateway authentication cannot use a database login role or a Supabase auth user and still meet "zero read access"** on today's
   schema [M]: 44 SELECT/ALL policies grant `USING (true)` to `authenticated`; every function is executable by `authenticated` by default
   (`db/views/zzz_function_grants.sql:31`); the grant gates watch only `anon`/`authenticated`/`service_role`/`PUBLIC`. The design (§3)
   therefore uses one anonymous-executable SECURITY DEFINER function plus per-gateway hashed keys — the certificate-of-destruction
   precedent, which is the only anonymous business surface today (1 of 769 functions executable by `anon`, measured).
5. **The supplier portal is mostly a security sweep, not pages**: the same 44 `USING (true)` policies and the default `EXECUTE` grant
   mean an external account would read internal tables on day one. MES-9 carries an internal-only sweep (§7, Q86).
6. **No scheduler exists** (extensions: `pg_stat_statements pg_trgm pgcrypto plpgsql supabase_vault uuid-ossp` — no `pg_cron`) [M].
   A missing heartbeat is therefore derived on read and recorded as an outage when the gateway returns (§3.8).
7. **Two prior Tim rulings constrain two functions** [M]: thermal-runaway history must not become a batch safety state
   (`db/tables/inbound_safety_states.sql:44-50`) — function 24 marks batches through incident links instead; provisional purchase prices are
   negotiated per deal with no default (`docs/index-pricing-spec.md:174,187-188`) — function 25 can advise on price, not set it (Q77).
8. **"Derived" electrolyte loss must not be the balance residual** [I]: computing it as input − outputs − other losses makes every
   stage close by construction (the catch-all-bucket disease, AGENTS.md "一个带【兜底桶】的分项分解"). It needs an independent basis whose
   factor is a "Not yet set" value (Q51).
9. **Output-batch prefixes are not a one-row change** [M]: every output batch shares prefix `OUT` and one sequence
   (`db/tables/output_batches.sql:16,93-98`); three numbering functions truncate past 9,999 a year (`CODE-WIDTH-4`,
   `docs/known-issues.md:3260`). Function 14 needs a prefix-selection rule and the width fix.
10. **No new approval chain is needed** (§4): every new record is a record of an event (the house test, `docs/approvals.md:1090-1111`),
    and every money consequence already travels through an approved document.
11. **One of the vendor's twelve modules has no function among the 31**: scheduling. It maps only to existing work orders and to
    blending plans (Q2).
12. **Size.** About 60 new tables and 50 new pages. The recommended plan is **15 cuts**, estimated **≈ 98 h – 175 h** including
    floors; the previous survey's estimate ran 1.5–2.3× over the measured outcome (U1-A), so the low end is the better guide (§8).

---

## §1 · (a) The 31 functions, one by one

Columns: **Has** = what exists, with paths · **Missing** · **Touches** = existing records it changes or reads · **Cut**.
Full per-function evidence with every path:line is in `evidence-functions-01-14.md` and `evidence-functions-15-31.md`.

### 1.0 Shared foundation — the data ingestion layer

| | |
|---|---|
| **Has** [M] | Equipment = finance asset cards `fixed_assets` (2 live rows, both discharge machines) with `equipment_downtime`, `equipment_maintenance`, `equipment_service_intervals`, views `equipment_usage` (kg only), `equipment_service_status`. 30 route handlers, all GET exports/PDF/labels/verify; **no `app/api`, no `supabase/functions`**. Service-role key used only for `auth.admin` invitations (`lib/supabase/admin.ts:3-19` forbids business queries). Precedent for an anonymous, token-checked, rate-limited function: `cod_verification` (30 failures / 10 min, `db/functions/cod_verification.sql:19-24`). Append-only issue logs with sha256 (`*_issues`). |
| **Missing** [M] | Device registry, gateway identity, keys, inbox, transmission log, heartbeat, data-class registry, transformation layers, draft/confirm, manual-entry path through the same pipe. No device or integration permission code (73 codes live: 30 module, 32 action, 11 data). |
| **Touches** | `fixed_assets` (a device may point at an asset), `db/anon-grants-baseline.tsv`, `db/check_grants.py` `ANON_EXECUTE_ALLOWED`, `db/views/zzz_function_grants.sql`, `scripts/check-anon-grant-decision.mjs`, change-log exclusions. |
| **Cut** | MES-1 (entry point), MES-2 (draft/confirm) |

### 1.1 Data capture

| # | Has | Missing | Touches | Cut |
|---|---|---|---|---|
| **1 Weighbridge tickets** | Receipt weight is `inbound_batches.quantity` ("always belongs to the person on the scale", `app/inbound/receive/ReceiveForm.tsx:5,125,255`), `declared_qty`, `grn_discrepancies`. A photo slot exists only as `finance_attachments.doc_type = 'weighbridge'` behind finance permissions (`db/tables/finance_attachments.sql:38,62-77`). `sales_settlements.gross_weight_kg` is customer-side. `docs/logistics-survey.md` §B7 already names forwarder and customer weights "无处可存" [M] | Ticket entity; gross/tare/net anywhere (grep `tare\|net_weight\|皮重\|地磅` in `db/` → 0) [M]; vehicle; ticket → receipt/shipment link; floor-readable photo store; shipment weights | `inbound_batches`, `create_inbound_batch`, `receive_inbound_batch_against_po`, `shipments`/`shipment_lines`, `grn_discrepancies`, `document_types` | MES-2 |
| **2 Discharge per module** | `deep_discharge` operation (state-changing; fixtures 158–160); `deep_discharge_judgements` (can/cannot/not_assessed) on PO line and batch; safety-state facts; `battery_powder_line` accepts undischargeable stock [M] | Module identity (grep `serial_no\|module_no\|模组号` → 0) [M]; per-module voltage/verdict/duration/energy; channel→module map; failure disposition; re-discharge count. Whole-batch flip on partial discharge [I] | `commit_processing_run`, `inbound/output_batch_safety_states`, `operation_type_safety_states`, `storage_locations` | MES-5a |
| **3 Meters & electricity by use** | Electricity is a typed money line per run (`processing_cost_entries.cost_type = 'electricity'`, `is_estimate`), posted Dr 5110 / Cr 2200 (`allocate_processing_costs.sql:260`) [M] | Meter entity, readings, kWh anywhere (grep `meter\|kwh` in `db/` → 0) [M]; bill → runs allocation rule; operation ↔ machine link (`docs/forward-queue.md:1690` "今天根本不存在") | `processing_cost_entries` (+ history, settlement guards), `expenses`, `allocate_processing_costs`, accounts 5110/6200 | MES-5a |

### 1.2 Warehouse

| # | Has | Missing | Touches | Cut |
|---|---|---|---|---|
| **4 Ceilings per licence** | `company_compliance.approved_storage_limit_tonnes` (live: 1 licence row `gwdf`, 500, active — test data) [M]; `licence_storage_within_limit()` refuses to judge with three named codes; `hazardous_qty_on_hand_tonnes()` returns NULL unconditionally (waste classes are only `focused`/`non_focused`); fixture 152 [M] | Any caller (grep → only its own file and the mirror) [M]; per-licence × category limits; computable hazardous on-hand; refusal at receipt | `company_compliance`, `certificate_types`, `waste_classifications`, both receipt RPCs, `check_location_class` | MES-3a |
| **5 Dwell warnings** | Only the output-unsold arm, hard-coded 60 days (`db/views/operations_now.sql:277-285`) [M]; state facts carry `created_at` | Per-state thresholds; state history (states are deleted and re-inserted, `commit_processing_run.sql:354-363`) [M]; dwell arm. `docs/exec-views-plan.md:48` parks hazardous storage days until the NEA licence | `inbound_safety_states` (RUNTIME CONFIG), both state fact tables, `operations_now` | MES-3a |
| **6 Quarantine** | `storage_locations` (4 live rows, all test) with no type column; allowed classes keyed by waste class only; `swollen_leaking` exists as a state; the table comment records the storage half as an unbuilt to-do (`db/tables/inbound_safety_states.sql:36-40`) [M] | Location kind; state → location rule; gate. Processing outputs land with no location [I] | `storage_locations`, `check_location_class` (4 landing points), `hold_stock` | MES-3a |
| **7 Labels** | `/inbound/[id]/label`, `/output/[id]/label` (A6 HTML, QR → edit URL; `app/components/labels/labelHtml.ts`) [M] | Templates, print/reprint log, UN/DG data, shipment labels, thermal printers. Queue: "HS 编码与 UN 编号,以及 DG 申报(UN3480/3481,第 9 类)" before the first export (`docs/forward-queue.md:1682`) [M] | `materials`, label routes, issue-log pattern | MES-3b |
| **8 Scanning** | Phone camera reads the label QR and opens the batch page; stocktake quick-count banner (`app/stocktakes/StocktakeQuickCount.tsx`); 48 px touch controls [M] | In-app decoding (no BarcodeDetector/zxing; `package.json` has only the `qrcode` generator) [M]; scan-driven receipt/transfer/feed/shipment; scan log | `create_stock_transfer`, `commit_processing_run` input picker, shipping queue, receipt RPCs, QR payload | MES-3b |

### 1.3 Production

| # | Has | Missing | Touches | Cut |
|---|---|---|---|---|
| **9 Material balance** | `/inventory` lifetime plant totals, no date filter by convention (`app/inventory/page.tsx:11,325-400`); upward lineage `batch_lineage(_all)`; per-run loss breakdown; `cod_delivery_completion` (partial per-inbound consumption) [M] | Per-incoming-batch forward balance; monthly balance; any "in = out + loss" assertion (only output ≤ input, `commit_processing_run.sql:299`) [M]; attribution rule for multi-input runs [I] | `processing_inputs/outputs/run_losses`, `inventory_movements`, lineage views | MES-5b |
| **10 Yield** | `processing_metal_recovery(_all)` per run × metal; `work_order_fulfilment` [M] | Mass yield by any dimension; grouping by chemistry (chemistry is on materials: 2 of 9 have it, `docs/forward-queue.md:1692`) or supplier | `materials.chemistry`, `inbound_batches.supplier_id`, lineage | MES-5b |
| **11 Parameters & recipes** | Only `processing_runs.notes` [M] | Parameter schema per operation, recipe, values on runs (grep `recipe\|配方\|BOM\|setpoint` → 0 in db) [M]; queued "配方 / BOM 标准配比" (`docs/forward-queue.md:1862`) | `processing_runs`, `operation_types`, `commit_processing_run` | MES-4a |
| **12 Blending plans** | N-in-1-out runs; `contract_grade_specs` + `contract_grade_breaches` (report, not gate) [M] | Plan entity, targets, blending operation | `operation_types`, `processing_inputs`, `output_batch_metals`, assays | MES-5b |
| **13 New fields** | 13 material forms confirmed (live `material_forms` = 13) [M]; loss categories `moisture`, `dust_spill`, `residue_disposal`, `electrolyte_evaporation` [M]; `shifts` day/night with **times NULL by design** ("名字有出处,时刻没有") [M] | Construction (wound/stacked) anywhere [M]; hard-case/pouch counts and override count [M]; contamination per shift — runs carry a date only, no shift [M]; measured/estimated flag on losses (cost entries have `is_estimate`, losses do not) [M]; collected-dust form [M] | `inbound_batches`/`output_batches` (masked — column + grant + `_masked` view in one migration), `processing_run_losses`, `material_forms`, `loss_categories` | MES-4a / MES-4b |
| **14 Output prefixes** | `document_types`: 41 prefixes live [M]; `document_type_prefix()`; checks `check-search-registry.mjs` (EXPECTED_ROWS = 41), `check-document-registry.mjs`, fixtures 100/101/102/199 [M] | Per-product prefix; prefix selection by form; widths beyond 4 digits (`CODE-WIDTH-4`) [M] | `generate_output_code`, `output_code_seq`, search registry, fixture 100 | MES-4b |

### 1.4 Quality

| # | Has | Missing | Touches | Cut |
|---|---|---|---|---|
| **15 Samples** | `assay_results.sample_ref` free text (`db/tables/assay_results.sql:34`); contract retention terms `sample_retention_required/_days` (`contract_settlement_terms.sql:60-69`, comment "记的是合同要不要求留样,不是样品在哪") [M] | Sample entity, number, location, retain-until, recipient, chain of custody [M]. Known: "仲裁那条路有一个说出来的未满足前提" (`SETTLE-1`, `docs/known-issues.md:6489`) | `assay_results`, `storage_locations`, `laboratories`, `document_types` | MES-6a |
| **16 Arbitration** | Sell side: `result_party` ours/counterparty/umpire; `splitting_limit_pct` nullable, never auto-decides; `sale_settlement_compute.sql:150-186` refuses `RESULTS_IN_DISPUTE` / `RESULTS_EXCEED_SPLITTING_LIMIT` — the hold [M] | Purchase side reads none of it (`apply_assay_result`, `reprice_inbound_batch`: 0 hits) [M]; dispute record; prompt; fee and its split (N25 / G27 "记下来,不建"); laboratories as payees | `assay_results`, `contract_settlement_terms`, `sales_settlements`, `apply_assay_result`, `reprice_inbound_batch`, `expenses` | MES-6a |
| **17 NCR** | `contract_penalty_elements` (sell-side only consumer); `penalty_basis`; `contract_grade_breaches` "一个发现,不是一道闸"; `hold_stock` with free-text reason [M] | NCR entity (0 hits); quality hold G29 (open, `docs/forward-queue.md:1711-1719`); purchase-side penalty money | `contract_penalty_elements`, `contract_grade_breaches`, `hold_stock`, `receipt_price_requests`, `credit_notes` | MES-6b |
| **18 CoA** | Precedents: certificate of destruction (`certificates_of_destruction`, `cod_issues`, token, frozen snapshot, `/verify/cod`) and the traceability report (`traceability_report_issues`) [M]; queued "第一笔真实销售之前" (`docs/forward-queue.md:1681`) | CoA document, archive, route, code. The COD verify payload deliberately carries no assay content (`docs/anon-surface.md`) [M] | `output_batches`, `assay_results`, `document_types`, PDF layer | MES-6b |
| **19 F and Cl** | `substances` = 7 rows `ni co li mn cu al fe` (live) [M]; the table comment names F/Cl as the first additions (`db/tables/substances.sql:41-49`) [M]; 12 FK columns reference it | Rows; a role column (payable metal vs penalty element) — without it F/Cl appear in metal-price and pricing pickers [I]; `content_pct` is unconstrained `numeric` (live) so ppm fits as % [M] | 12 FK users, pickers, `processing_metal_recovery` | MES-6a |

### 1.5 Equipment

| # | Has | Missing | Touches | Cut |
|---|---|---|---|---|
| **20 Calibration** | Nothing instrument-shaped (grep `calibrat\|校准\|检定` → only unrelated senses) [M]. Gate precedent: `certificate_types.disposition` block/warn + `warn_lead_days` [M] | Register, events, certificates, valid-until, reading → instrument link, refusal on pricing/certificates | price-setting functions, `issue_cod`, CoA | MES-2 |
| **21 Spare parts** | `material_kinds` `consumable`, `spare_part` (`db/tables/material_kinds.sql:79-83`); `equipment_maintenance.expense_id`; PO category `consumables` [M] | Parts lines; an issue-to-maintenance movement (inventory is batch-only: CHECK `one_batch`, `db/tables/inventory_movements.sql:84`) [M] | `inventory_movements`, `equipment_maintenance`, `inbound_batches` | MES-7a |
| **22 MTBF/MTTR** | `equipment_downtime` with timestamps and generated duration; explicit refusal to compute availability until someone chooses the denominator (`db/tables/equipment_downtime.sql:58-63`) [M] | Failure vs planned classification (reason is free text); operating hours (runs have a date only) [M] | `equipment_downtime`, `processing_runs` | MES-7a |
| **23 Safety inspections** | Shapes only: `handover_item_types`, `lane_checklist_status`, service intervals [M] | Templates, runs, findings, corrective actions, WSH code | `employees`, `tasks`, `operations_now` | MES-7b |
| **24 Thermal runaway / emissions** | WSH register queued with trigger "第一个技师上岗" and the NEA duty "立即通报 … 两个工作日内提交书面报告" (`docs/forward-queue.md:1686`) [M]; `hold_stock`, `notifications`, `operations_now` | Incident register, alarm events, incident ↔ batch link, deadline arm, emission results | `hold_stock`, safety-state facts (barred by Tim's ruling), `public_holidays` | MES-7b |

### 1.6 Suppliers

| # | Has | Missing | Touches | Cut |
|---|---|---|---|---|
| **25 Scorecards** | `suppliers.credit_rating` free text; inputs `supplier_receipt_pattern` (deliberately no thresholds), `grn_discrepancies`, `contract_grade_breaches`, compliance; prepayment % on templates and PO terms; `inbound_batches.pricing_status` provisional [M] | Scorecard (0 hits); per-supplier sampling. **Conflict** with index-pricing ruling #2 [M] | `payment_term_templates`, `purchase_order_payment_terms`, `material_required_metals`, `create_purchase_order` | MES-8a |
| **26 Statements** | `ap_open_items`, `/finance/payables`, list-vs-ledger (AP-RECON-1); customer side `customer_statements` + `statement_issues` as the template [M] | Supplier statement either direction (0 hits) [M] | `ap_open_items`, `document_types`, issue archive | MES-8a |
| **27 Portal** | No external-user concept; `counterparty_contacts` has no login link; `PUBLIC_PATHS = ['/login','/verify/cod']` (`lib/loginRoute.ts:50`); idle logout 30 min (`lib/session.ts:22`) [M] | External identity, supplier-scoped reads, invitations, route group, internal-only sweep | every supplier-facing table's policies, `zzz_function_grants`, anon baselines | MES-9 |

### 1.7 Analysis and display

| # | Has | Missing | Touches | Cut |
|---|---|---|---|---|
| **28 Profit per incoming batch** | `batch_margin` per **output** batch, predicate `data.view_prices AND (finance.view OR processing.view)` (`db/views/batch_margin.sql:108`; AGENTS.md decision 2) [M]; `inbound_batch_valuation`; lineage | Per-inbound margin; revenue attribution back through multi-input runs [I] | `batch_margin`, `batch_lineage_all`, `/margin` | MES-8b |
| **29 Metal exposure** | `/finance/price-exposure` → `price_exposure_report()` sell-side only; purchase side `'modelled': false`; market calendar empty (`price_exposure_report.sql:141-170`) [M] | On-hand × content × price; currency ruling open (BLOCKERS-0 Q1/Q2, `docs/forward-queue.md:431-448`) | `inbound/output_batch_metals`, `metal_prices`, `stock_snapshot` | MES-8b |
| **30 Compliance pack** | Licence register; NULL hazardous on-hand; `management_packs` freeze precedent; queued regulatory balance (`docs/forward-queue.md:1720`) [M] | NEA return, filing calendar, EU recycling efficiency (0 hits for `2023/1542`), disposal leg [M] | lineage, losses, `management_packs` pattern | MES-8b |
| **31 Wall display** | `operations_now` rendered at `/tools/reminders` [M] | Kiosk route, auto-refresh (0 `setInterval`/polling hits); idle logout would sign a display out [M] | `lib/session.ts`, roles, `operations_now` | MES-8b |

---

## §2 · (b) The specification, clause by clause

Status: **C** covered · **P** partly covered · **N** new · **S** site layer or procurement — outside the system by the specification's own
design (the system holds only the record or the reserved interface). Clause IDs are the PDF's section numbers plus a running letter.

### §1 Purpose and scope

| ID | Clause [S] | Status | Repo evidence / disposition | Cut |
|---|---|---|---|---|
| 1a | Equipment data-interface openness and per-station weighing are fixed in procurement, not software | S | Recorded in the "to be supplied later" register (§5, device interfaces) | — |
| 1b | No threshold values are given; they come from vendors, regulation and work instructions | P | Matches Tim's ruling: every threshold is structure with an empty value (§5). The repo already follows it (`splitting_limit_pct` NULL never decides; `supplier_receipt_pattern` refuses thresholds) [M] | all |

### §2 Data layering

| ID | Clause [S] | Status | Repo evidence / disposition | Cut |
|---|---|---|---|---|
| 2a | Safety/interlock data stays at site; ERP receives exception events only | N | Data class `safety_alarm` → incident (§3.4) | MES-7b |
| 2b | Mass-balance data (per batch / per station) is core ERP data | P | Runs record totals and named losses; no per-station weighings | MES-2, MES-4a |
| 2c | Quality/assay records use the existing assay document | C | `assay_results` + `assay_result_metals` [M] | — |
| 2.1a | Millisecond data never enters the ERP database | N | Inbox accepts per-batch summaries only; payload size cap (Q7) | MES-1 |
| 2.1b | Raw waveforms stay at site; ERP holds a pointer (equipment id + time interval) | N | `site_device`, `site_from`, `site_to`, `site_dataset_ref` on every formal capture record (§3.9) | MES-1 |
| 2.1c | ERP is not a running dependency; data queues at site and arrives in sequence | N | Per-gateway sequence, idempotent re-send, outage record (§3.8) | MES-1 |

### §3.1 Deep discharge

| ID | Clause [S] | Status | Repo evidence / disposition | Cut |
|---|---|---|---|---|
| 3.1a | Outlet voltage per module, no averaging | N | No module identity [M] → `discharge_module_results` | MES-5a |
| 3.1b | Duration and curve terminal form | N | Duration per module; curve stays at site behind the pointer | MES-5a |
| 3.1c | Surface and cabinet temperature, rate of rise | S | Interlock at site; exceptions arrive as `safety_alarm` | MES-7b |
| 3.1d | Energy recovered | N | Per module and per run value | MES-5a |
| 3.1e | Channel → module mapping | N | `discharge_channel_assignments` | MES-5a |
| 3.1f | Voltage measured by the equipment; export permission is the issue | S | Register item: Bosch per-module export (§5) | — |
| 3.1g | Gas detection (electrolyte vapour, HF), hard-wired | S | Exceptions only (`safety_alarm`) | MES-7b |
| 3.1h | Per module: id, voltage, verdict, verdict time | N | `discharge_module_results` | MES-5a |
| 3.1i | Per batch: module count/mass in, duration, energy, failed count and disposition | P | Run header has mass; the rest is derived from module rows | MES-5a |
| 3.1j | Exceptions: time, type, duration, action, responsible person | N | `processing_run_events` | MES-4a |
| 3.1k | Failed-module disposition mandatory (re-discharge or quarantine), both generate a record | N | Required column; quarantine splits the modules into their own batch (Q23) | MES-5a |

### §3.2 Manual disassembly

| ID | Clause [S] | Status | Repo evidence / disposition | Cut |
|---|---|---|---|---|
| 3.2a | Module mass and count in | P | Input quantity exists; count does not (no count column on legs) [M] | MES-4a |
| 3.2b | Cell mass and **count** out | P | Output quantity exists; count is a run value | MES-4a |
| 3.2c | Structural parts / housing mass out | C | Output form `structural_parts`, `casing` (live routing) [M] | — |
| 3.2d | Harness, BMS board, busbar mass, separately | N | No form for it (13 forms) [M] → new form (Q55) | MES-4b |
| 3.2e | Cells damaged in disassembly (count) | N | Run value | MES-4a |
| 3.2f | Operator, start and end time | N | Runs carry a date only [M] → `started_at`, `ended_at`, operator | MES-4a |
| 3.2g | Weighing and recording in one action at the station | N | Workstation draft confirmation + weighing draft | MES-2 |
| 3.2h | Scales populate automatically; operator confirms and scans | N | Weighing class + scan class | MES-2, MES-3b |
| 3.2i | Next stage cannot start / next batch code cannot be generated until this stage's weighing exists | N | Output legs must reference a confirmed weighing (Q22) | MES-4a |

### §3.3 Casing removal

| ID | Clause [S] | Status | Repo evidence / disposition | Cut |
|---|---|---|---|---|
| 3.3a | Hard-case/pouch classification is a recorded item | N | Run values on the casing-removal operation | MES-4a |
| 3.3b | Visual: counts per batch and who judged | N | Values + run operator | MES-4a |
| 3.3c | Equipment: results + count needing manual adjudication | N | Values (`manual_adjudication_count`) | MES-4a |
| 3.3d | Misclassification occurrences | N | Value (`misclassification_count`) | MES-4a |
| 3.3e | Cell in / casing out / opened cell out, by hard-case and pouch | P | Legs exist; per-construction split as values | MES-4a |
| 3.3f | Scrap count by cause (cut-through, short, smoke, fire) | N | Values per cause | MES-4a |
| 3.3g | Cutting-station temperature and smoke | S | Exceptions only | MES-7b |
| 3.3h | Cumulative cut count per tool and replacement records | N | Controller value + maintenance part issue | MES-4a, MES-7a |
| 3.3i | Casing removal is a separate stage on separate equipment | **conflict** | Live `electrode_line` = casing removal + separation as one operation (Tim's R2) [M] (Q37) | MES-4a |

### §3.4 Electrode separation

| ID | Clause [S] | Status | Repo evidence / disposition | Cut |
|---|---|---|---|---|
| 3.4a | Wound/stacked construction as a **batch** attribute | N | Column on both batch tables (masked) | MES-4b |
| 3.4b | Cell mass, count and construction in | P | Mass yes; count and construction new | MES-4a/4b |
| 3.4c | Cathode / anode / separator mass out | C | Output forms `cathode_sheet`, `anode_sheet`, `separator` [M] | — |
| 3.4d | Cross-contamination rate, sampled, per shift or per batch, attached to batch | N | `contamination_checks` | MES-4b |
| 3.4e | Electrolyte recovered or evaporation loss, marked measured or derived | P | Category exists; flag missing [M]; derivation basis (Q51) | MES-4b |
| 3.4f | Run time, energy, unplanned stop count and duration from the controller | N | `controller_summary` class → run values + downtime | MES-4a |
| 3.4g | Cross-contamination sampled at least once per shift | N | Missing-check arm keyed on run shift | MES-4b |

### §3.5 Powder stripping

| ID | Clause [S] | Status | Repo evidence / disposition | Cut |
|---|---|---|---|---|
| 3.5a | Powder yield | N | Mass yield view | MES-5b |
| 3.5b | Residual powder on foil (assay) | P | Assay mechanism exists; an indicator code is new | MES-6a |
| 3.5c | Foil purity (assay) | P | Same | MES-6a |
| 3.5d | Moisture | P | `assay_results.moisture_pct` exists [M]; inline average is new | MES-6a |
| 3.5e | Particle size distribution | N | Inline/assay indicator | MES-6a |
| 3.5f | Dust collection mass in the balance | N | Form `collected_dust` as output | MES-4b |
| 3.5g | Energy and run time | N | Run values | MES-4a |
| 3.5h | Three output scales (powder, foil, dust) | S | Device register entries; reserved | MES-1 |
| 3.5i | Residual powder and purity by sampling, sample id bound to batch | N | Samples | MES-6a |
| 3.5j | Inline moisture: per-batch average to ERP | N | `inline_quality` class | MES-6a |
| 3.5k | Dust concentration hard-wired, not via ERP | S | Exceptions only | MES-7b |
| 3.5l | Cathode and anode stripped separately; products are cathode powder, anode powder, Al foil, Cu foil | **conflict** | Live `electrode_powder_line` outputs only `black_mass` [M] (Q37, Q55) | MES-4a/4b |

### §4 Batch tree and mass balance

| ID | Clause [S] | Status | Repo evidence / disposition | Cut |
|---|---|---|---|---|
| 4a | 8–9 output categories each with own batch number, destination, price | P | Output batches exist; one prefix `OUT` [M] | MES-4b |
| 4.1a | Input = Σ outputs + named losses at every branch point | P | Losses named but remainder "unexplained" allowed silently; only output ≤ input enforced [M] | MES-4a |
| 4.1b | Input and output weighed every batch, no sampling | N | Weighing-reference rule (Q22) | MES-4a |
| 4.1c | Loss reasons from a fixed list, no "other" | C | `loss_categories` dictionary, no "other" row (live) [M]; additions Q56 | MES-4b |
| 4.1d | Deviation bands per stage, enforced; outside needs recorded explanation | N | Tolerance per operation type + closure step (Q46–Q48) | MES-4a |
| 4.2a | Closed tree answers regulators | N | Per-inbound balance, compliance pack | MES-5b, MES-8b |
| 4.2b | Trace back to supplier and discharge records | P | Upward lineage exists [M]; discharge records new | MES-5a/5b |
| 4.2c | Process records append-only; corrections are new records referencing the original | P | Header append-only, losses and cost entries still editable; correction = whole-run reversal via CFO request [M] | MES-4a |

### §5 ERP record structure

| ID | Clause [S] | Status | Repo evidence / disposition | Cut |
|---|---|---|---|---|
| 5a | Inputs: source batches, mass, count, material type, construction | P | Batches and mass exist; count and construction new | MES-4a/4b |
| 5b | Outputs: new batch number, mass, count, type per stream | P | As above | MES-4a |
| 5c | Losses: mass, fixed-list reason, remarks | C | `processing_run_losses` [M] | — |
| 5d | Process indicators: start/end, equipment, run time, avg/peak temperature, energy, scrap | N | Run time columns + configurable values | MES-4a |
| 5e | Exception events | N | `processing_run_events` | MES-4a |
| 5f | Quality: sample id, assay record, key results | P | Assays exist; samples new | MES-6a |
| 5g | Raw data pointer | N | §3.9 | MES-1 |
| 5h | Operator, confirming person, creation time, confirmation time | N | Draft confirmation columns | MES-2 |
| 5.1a | Same numbering mechanism, prefix-year-sequence, > 30 prefixes | P | 41 prefixes [M]; format not universal — ATT/PACK/WHT use YYYY-MM, GST YYYY-Qn [M] | MES-4b |
| 5.1b | Output prefixes registered in one pass | N | Q54 | MES-4b |

### §6 Integration method

| ID | Clause [S] | Status | Repo evidence / disposition | Cut |
|---|---|---|---|---|
| 6.1a | Edge gateway captures from controllers | S | Device register, reserved | MES-1 |
| 6.1b | Local buffering, in-sequence transmission on restoration | S/N | Gateway side is site; ERP side: sequence + idempotency | MES-1 |
| 6.1c | Local aggregation; only aggregated results transmitted | S/N | Payload cap + summary-only classes | MES-1 |
| 6.2a | Summary at batch close | N | Class payloads | MES-1 |
| 6.2b | Exception events in real time | N | `safety_alarm` class | MES-1, MES-7b |
| 6.2c | Heartbeat; a missing heartbeat is an exception | N | §3.8 | MES-1 |
| 6.3a | Gateway data creates a draft; operator confirmation makes it formal | N | `capture_drafts` | MES-2 |
| 6.3b | Confirmation recorded: who, when, whether modified | N | Confirmation columns | MES-2 |
| 6.3c | Corrections at confirmation keep both values and need a reason | N | `capture_draft_changes` | MES-2 |
| 6.4a | Gateway writes only to a landing table | N | One function, one inbox (§3.2) | MES-1 |
| 6.4b | Format changes touch only the conversion layer | N | Versioned transform per class (§3.5) | MES-1 |
| 6.4c | Failed conversions stay in the landing table, visibly | N | Inbox status + page | MES-1 |

### §7 Security and access control

| ID | Clause [S] | Status | Repo evidence / disposition | Cut |
|---|---|---|---|---|
| 7a | Dedicated identity per gateway, no personnel or admin key | N | `gateway_keys` | MES-1 |
| 7b | Write-only: insert on the landing table, zero read | N | Narrower than the clause: no table privilege at all, one function (§3.3) | MES-1 |
| 7c | No reach into pay, contracts, customers, personal data | N | Function body writes four ingestion tables only | MES-1 |
| 7d | Individually revocable, replaceable without stopping the line | N | Revocation checked per call; two-key overlap for rotation | MES-1 |
| 7e | Encrypted in transit, server identity verified | N/S | HTTPS to the project endpoint; gateway verifies the certificate (register item) | MES-1 |
| 7f | Each transmission logged: gateway, time, volume; abnormal patterns identifiable | N | `ingest_transmissions` + anomaly view | MES-1 |
| 7g | No reverse channel; one-way flow | N | The function returns acknowledgements only | MES-1 |

### §8 Procurement-phase requirements

| ID | Clause [S] | Status | Repo evidence / disposition | Cut |
|---|---|---|---|---|
| 8.1a–f | Protocol, point list, sampling/timestamp precision, no charge, local retention, documentation | S | Register items per device (§5.2); the device page shows each contract term as a checklist with "Not yet confirmed" | MES-1 |
| 8.1g | Bosch per-module voltage export | S | Register; manual per-module entry until then (Q25) | MES-5a |
| 8.2a | Scales at six stations | S | Device register entries; "Not yet connected" | MES-1 |
| 8.2b | Scales with communication interfaces | S | Register | — |
| 8.2c | Precision and capacity matched to batch size | S/N | Device attributes `capacity`, `resolution` (values from vendor) | MES-1 |
| 8.2d | Dust and corrosion protection ratings | S | Device attribute text | MES-1 |
| 8.2e | Scheduled calibration, records held in the system | N | Calibration register + gate | MES-2 |

### §9 Appendix — 30 measurement points

| Stage | Point [S] | Lands in | Cut |
|---|---|---|---|
| Deep discharge | Outlet voltage per module | `discharge_module_results` | MES-5a |
| Deep discharge | Duration and curve terminal form | per-module duration + site pointer | MES-5a |
| Deep discharge | Surface/cabinet temperature, rate of rise | site; `safety_alarm` → incident | MES-7b |
| Deep discharge | Electrolyte vapour / HF | site; `safety_alarm` → incident | MES-7b |
| Deep discharge | Energy recovered | module rows + run value | MES-5a |
| Manual disassembly | Module mass and count in | input leg + count value | MES-4a |
| Manual disassembly | Cell mass and count out | output leg + count value | MES-4a |
| Manual disassembly | Structural, housing, harness, BMS mass | output legs (new harness form) | MES-4a/4b |
| Manual disassembly | Cells damaged | run value | MES-4a |
| Casing removal | Classification verdict and adjudication count | run values | MES-4a |
| Casing removal | Cell in, casing out, opened cell out | legs | MES-4a |
| Casing removal | Scrap count and cause | run values | MES-4a |
| Casing removal | Cutting-station temperature / smoke | site; `safety_alarm` | MES-7b |
| Casing removal | Cut count per tool, replacements | controller value + maintenance parts | MES-4a/7a |
| Electrode separation | Cell mass, count, construction in | legs + values + batch attribute | MES-4a/4b |
| Electrode separation | Cathode, anode, separator out | legs | — (exists) |
| Electrode separation | Cross-contamination, sampled | `contamination_checks` | MES-4b |
| Electrode separation | Electrolyte recovered / evaporation | loss row with basis | MES-4b |
| Electrode separation | Run time, energy, stops | run values + downtime | MES-4a/7a |
| Powder stripping | Powder mass out, cathode and anode | legs (new forms) | MES-4b |
| Powder stripping | Foil mass out, Cu and Al | legs (new forms) | MES-4b |
| Powder stripping | Dust collection mass | leg (`collected_dust`) | MES-4b |
| Powder stripping | Residual powder on foil | assay indicator | MES-6a |
| Powder stripping | Foil purity | assay indicator | MES-6a |
| Powder stripping | Moisture | assay / inline average | MES-6a |
| Powder stripping | Particle size distribution | assay / inline | MES-6a |
| Powder stripping | Dust concentration | site; `safety_alarm` | MES-7b |
| Powder stripping | Energy and run time | run values / meters | MES-4a/5a |
| Whole line | Operator, confirmer, start/end | run columns + confirmation | MES-2/4a |
| Whole line | Gateway heartbeat | §3.8 | MES-1 |

### §10 Implementation sequence

| ID | Clause [S] | Status | Disposition |
|---|---|---|---|
| 10a | Procurement terms and scale positions first | S | Register (§5.2) |
| 10b | Point lists checked against the appendix | S | The device page carries the appendix row each device serves |
| 10c | Prove the balance on paper before building | **superseded** | Tim's scope ruling; risk controlled by configurable tolerances, thresholds and parameters (§5) |
| 10d | ERP development after stable operation | **superseded** | Same |
| 10e | Gateway last, automating the verified manual process | **reshaped** | Manual entry and devices share one path from MES-1, so connecting a device later changes the source, not the record |

---

## §3 · (c) The ingestion layer — one design

### 3.1 Shape

```
gateway ──HTTPS──▶ ingest_submit(gateway, key, messages)   ← the only thing a gateway can call
                       │  (SECURITY DEFINER, EXECUTE: anon only)
                       ├─▶ ingest_transmissions   (every call, accepted or rejected)
                       ├─▶ devices.last_heartbeat_at / gateway_outages   (heartbeats)
                       └─▶ ingest_inbox            (one row per message; unique per gateway+seq)
                                 │
                       ingest_transform(inbox_id)  ← dispatcher, reads ingest_data_classes
                                 │   per class: transform_<class>_v<n>(payload) — validate, normalise
                                 ▼
                       capture_drafts (pending) ──confirm_capture_draft()──▶ formal record (append-only)
                                 ▲                                         (weighings, discharge_module_results,
staff UI ──submit_manual_capture()┘   same inbox, source = 'manual'          meter_readings, scan_events,
                                                                             processing_run_values, incidents …)
```

### 3.2 Tables (MES-1 unless noted)

- **`devices`** — every physical source, including gateways: `code` (registry prefix, Q53), `kind` (gateway · scale · weighbridge ·
  discharge_cabinet · controller · meter · workstation · scanner · inline_instrument · alarm_panel), `data_class`, `gateway_id`
  (which gateway carries it), `equipment_id → fixed_assets` (nullable), `station` (free text until a station dictionary is needed),
  `capacity`/`resolution`/`unit` (scales and instruments), `interface_status` (`reserved` · `manual_only` · `connected`), the §8.1
  contract-term checklist as columns with "Not yet confirmed", `heartbeat_interval_s` (gateways; NULL = Not yet set), `last_seen_at`,
  `last_heartbeat_at`, `last_seq`, `is_active`.
- **`gateway_keys`** — `gateway_id`, `key_prefix` (first 8 characters, displayable), `key_hash bytea` (SHA-256 via `pgcrypto.digest`; the
  secret itself is shown once at issue and never stored), `issued_at/by`, `revoked_at/by/reason`. At most two active keys per gateway.
- **`ingest_settings`** — one row: failure budget, payload cap, messages-per-call cap (Q7).
- **`ingest_data_classes`** — dictionary: `code` (weighing · discharge_module · controller_summary · meter_reading · workstation_event · scan ·
  inline_quality · safety_alarm), `transform_function` (current version), `target`, `manual_entry_code` (permission for manual entry),
  `is_active`. A class whose target is not built yet has `transform_function` NULL; its rows wait with status `awaiting_transform`.
- **`ingest_inbox`** — `id bigserial` (an orderable sequence, AGENTS.md "取最新那一行要先问…排得出先后吗"), `gateway_id` (NULL for manual),
  `seq bigint` (gateway-assigned, per gateway monotonic), `source` (`device` · `manual`), `entered_by` (manual), `device_id`, `data_class`,
  `payload jsonb`, `payload_bytes`, `site_from`, `site_to`, `site_dataset_ref`, `received_at`, `status` (`received` · `transformed` ·
  `failed` · `awaiting_transform` · `discarded`), `transform_version`, `error_code`, `attempts`, `draft_id`. Unique `(gateway_id, seq)`.
  Append-only except the status columns (guard trigger).
- **`ingest_transmissions`** — one row per data call: `gateway_code_presented`, `gateway_id` (NULL if unknown), `key_prefix_presented`,
  `received_at`, `bytes`, `message_count`, `first_seq`/`last_seq`, `result` (`accepted` · `unknown_gateway` · `bad_key` · `revoked_key` ·
  `too_large` · `throttled` · `malformed`), `client_address` (Q18). Heartbeat-only calls are counted in hourly bucket rows (Q6).
- **`gateway_outages`** — `gateway_id`, `silent_from`, `silent_to`, `recorded_at`, written when a heartbeat arrives after a silence longer
  than the gateway's interval.
- **`capture_drafts`** (MES-2) — `inbox_id`, `data_class`, `device_id`, `station`, `proposed jsonb`, `status` (`pending` · `confirmed` ·
  `rejected`), `confirmed_by/at`, `rejected_by/at/reason`, `record_table`, `record_id`.
- **`capture_draft_changes`** (MES-2) — `draft_id`, `field`, `original_value`, `confirmed_value`, `reason` (NOT NULL).

### 3.3 How a gateway authenticates, and why it can reach nothing but the inbox

1. The gateway sends `POST https://<project>.supabase.co/rest/v1/rpc/ingest_submit` with the project's public `apikey` header and a body
   `{ p_gateway, p_key, p_messages }`. Transport is HTTPS; the gateway verifies the server certificate against the public CA chain
   (certificate pinning is not recommended: Supabase rotates certificates).
2. `ingest_submit` is `SECURITY DEFINER`, `SET search_path = public`, `EXECUTE` granted to `anon` and **revoked from `authenticated`,
   `service_role` and `PUBLIC`**. It (i) checks the payload cap and the failure budget, (ii) hashes `p_key` and looks for an active
   `gateway_keys` row for `p_gateway`, (iii) writes the `ingest_transmissions` row **in every case**, (iv) on success inserts each message
   into `ingest_inbox` (`ON CONFLICT (gateway_id, seq) DO NOTHING`) and runs the class transform inside its own exception block, and
   (v) returns `{ok, accepted:[seq…], duplicates:[seq…]}` or `{ok:false, code}`. **It never raises on an authentication failure**,
   because a raise would roll back the log row — the same reason `cod_verification` returns rather than raises.
3. **Why nothing else is reachable.** The gateway holds two things. The public `apikey` is already in every browser and grants only what
   `anon` has: today exactly one function, `cod_verification` (measured: 1 of 769), plus legacy table grants that return no rows
   (ANON-0). The gateway key is not a session, cannot be exchanged for a JWT, and means something only as an argument to
   `ingest_submit`. That function's body writes `ingest_transmissions`, `ingest_inbox`, `devices.last_*` and `gateway_outages`, runs
   transforms that write drafts, and returns acknowledgements of the caller's own sequence numbers — no row of any table.
   Pay, contracts, customers and personal data are unreachable by construction: nothing in the call path selects them.
4. **Why not the alternatives** [M]:
   - a Postgres login role per gateway — the rebuild has no role management (`db/platform-prelude.sql` creates only the three Supabase
     roles) and `db/check_grants.py` watches only `anon`, so the gates would be blind to it;
   - a Supabase auth user per gateway — `authenticated` executes every function by default and 44 policies read `USING (true)`, so "zero read"
     fails on day one; a disabled user's token keeps working against the API for up to an hour (`HISTORY1-DISABLED-TOKEN-HOUR`,
     `docs/known-issues.md:9767`);
   - a Vercel route handler in front — adds a public path (`lib/loginRoute.ts:50`) and needs a database credential of its own, buying
     nothing the function does not already enforce;
   - an Edge Function — no repo tooling exists for it.
5. **Gates that must learn about it** (all in MES-1): one line in `db/anon-grants-baseline.tsv`, one entry in `ANON_EXECUTE_ALLOWED`
   (else B1 fails), a `REVOKE … FROM authenticated` line in `db/views/zzz_function_grants.sql`, an explicit anon decision on every new
   table (`scripts/check-anon-grant-decision.mjs`). Verdict 6 is fault-injected the way COD-2 did it.

### 3.4 Gateway identity, permissions and revocation

- A gateway is a `devices` row of kind `gateway`. Issuing a key (`issue_gateway_key`, new code `action.manage_devices`) returns the
  secret once. Revoking (`revoke_gateway_key(key_id, reason)`) takes effect on the next call, because the key is checked per call.
- **Rotation without stopping the line**: issue a second key, switch the gateway, revoke the first. Two active keys at most.
- **Revoking one gateway touches no other**: keys are per gateway. The plant does not stop either way: the gateway buffers locally (§6.1 [S]).

### 3.5 Transformation layers

- One function per data class and version: `transform_weighing_v1(payload) → normalised record or error code`. The dispatcher reads
  `ingest_data_classes.transform_function`. A device format change is a new version function and a registry update; business tables do not change.
- A failure sets `status = 'failed'`, `error_code`, `attempts`. The row stays; `/operation/capture/inbox` lists it with the payload; a holder of
  `action.manage_devices` may re-run (`retry_inbox_row`) after a transform fix, or discard with a reason (`discard_inbox_row`) — never delete.
- **Manual entry uses the same path**: `submit_manual_capture(data_class, payload)` inserts an inbox row with `source = 'manual'` and
  `entered_by`, then calls the same transform. The formal record carries `source = 'manual'`.

### 3.6 Draft and confirm

- A transformed device row becomes a `capture_drafts` row, shown on the station's queue (`/operation/capture`).
- `confirm_capture_draft(draft_id, overrides jsonb, reason)` re-validates the proposed values with the overrides through the same transform
  validator, writes the formal record, and for each overridden field writes a `capture_draft_changes` row with the original value, the confirmed
  value and the reason. **An override without a reason refuses** (`CAPTURE_CHANGE_REASON_REQUIRED`). Identity fields (device, gateway,
  sequence, site time range) are never overridable (Q12).
- `reject_capture_draft(draft_id, reason)` records a rejection; the inbox row stays.
- Manual entry is confirmed by its enterer in the same step (Q10): one action, `confirmed_by = entered_by`, no changes rows.

### 3.7 Append-only processing records and correction records

- Every formal capture record (weighings, module results, meter readings, scans, run values, events, contamination checks, inspections,
  incidents) has no UPDATE or DELETE policy and a guard trigger. A correction is a new row with `corrects_id` and a required `reason`;
  readers take the newest non-superseded row.
- **Processing runs**: quantities keep today's correction path (reversal request → CFO → new run), and the new run carries
  `corrects_run_id`. Losses become append-only (today editable after commit), and the open UPDATE policies on the processing tables
  (`ROLE1B3B-PROCESSING-UPDATE-POLICIES`, `docs/known-issues.md:186`) are dropped (Q49).

### 3.8 Heartbeats, missing heartbeats, ordered back-fill

- A heartbeat is a message type of `ingest_submit`; it updates `devices.last_heartbeat_at` and creates no inbox row.
- **A missing heartbeat is derived on read** (no scheduler exists): `gateway_health` computes `silent = now() − last_heartbeat_at >
  heartbeat_interval_s`. With the interval not set, the status reads "Not yet set — silence cannot be judged". The reminder view gains an
  arm for silent gateways, so the exception appears without anyone opening the device page.
- **The silence is also recorded**: when a heartbeat arrives after a silence longer than the interval, `gateway_outages` gets
  `(silent_from, silent_to)`. A failed gateway and an idle gateway are therefore distinguishable both now and afterwards.
- **Back-fill**: the gateway sends oldest first with its own `seq`; duplicates are acknowledged and ignored; gaps in `seq` per gateway are
  listed by a view (`ingest_sequence_gaps`) until the missing numbers arrive. Formal records keep the site time (`site_from`/`site_to`),
  not the arrival time, so a back-filled record lands at the moment it happened. A draft whose `received_at` is later than its `site_to`
  by more than the interval is flagged "back-filled".

### 3.9 The site-data pointer

Every formal capture record carries `site_device` (device id), `site_from`, `site_to`, `site_dataset_ref` (the gateway's own reference).
Pages show "Raw data at site: <device>, <from>–<to>, ref <…>". The ERP stores no waveform.

### 3.10 Permissions for the layer

| code (new) | what | holders proposed |
|---|---|---|
| `action.manage_devices` | register devices, issue/revoke keys, retry/discard inbox rows | admin, cto |
| `action.confirm_capture` | confirm/reject drafts, manual capture entry | warehouse, cto, admin |
| (reading) | devices, drafts, inbox status, transmissions | `module.processing.view` (no new code) |

The inbox payload may hold operator identifiers; no pay, contract, customer or personal data class exists in any payload (Q90).

---

## §4 · (d) Approvals, the change log and the audit trails

### 4.1 Approval engine

The engine registers a document when it **waits for someone**; a record whose creation is the act stays out (`docs/approvals.md:1090-1111`,
N2 `:521-529` — container loading, shipments, goods receipts and processing runs were dropped on that test) [M].

| new document | approval | reason |
|---|---|---|
| weighings, tickets, module results, meter readings, scans, run values/events, contamination checks, samples, inspections, incidents, label prints, calibrations | **none** | records of events; the operator's confirmation is the control (§6.3 [S]) |
| balance closure beyond tolerance | **none** — written explanation required | Tim's principle says "explanation", not approval (Q47) |
| quantity correction of a run | **existing** `warehouse_requests(kind='rollback')`, CFO level 2 | unchanged |
| NCR money consequence | **existing** receipt price request (CFO) or credit note | the money travels through an already-approved document |
| arbitration fee | **existing** expense / claim chain (tiered at 1,000) | |
| CoA void | new request, **CFO level 2, fixed** | same shape as the COD void (`submit_cod_void_request`) |
| blending plan release | **own code** like work orders (`action.wo_create` / `wo_release`) | a plan is a work order variant (Q58) |
| spare-part issue | none | an inventory movement, like a processing consume |
| supplier statement issue | none | customer statements precedent |
| gateway key issue/revoke, portal user invite | none (admin-only codes, change-logged) | security actions |

**Conclusion**: no new approval chain, no change to the 1,000 SGD threshold, one new fixed-level-2 request (CoA void) built by the
15-step checklist (`docs/approvals.md:1263-1271`; full list in the approvals evidence). Q89.

### 4.2 Change log

- Every new public table gets the two `zzz_change_log` triggers (`gen_change_log_bindings.py --only <t>`) or a reasoned
  `change_log_exclusions()` entry; otherwise `npm run build` (`check-change-log-coverage.mjs`), the gate's `changelog` line and fixtures
  234/235 fail [M].
- **Proposed exclusions** (Q14): `ingest_inbox`, `ingest_transmissions`, `gateway_outages` — each is itself an append-only log; logging it
  again doubles the volume the specification warns about (§2.1 [S]) and adds no fact. Their status changes are recorded on the row.
- **Masking** (`change_log_mask_rules()`): `gateway_keys.key_hash` — no reader (the trail shows "key issued, prefix ABCD1234");
  incident injury details → `code_or_self:data.view_health:employee_id`; supplier scores → `code:module.suppliers.view`; electricity
  allocation amounts → the existing processing-cost rule. Each masked column also goes into its `<table>_masked` view in the same migration
  (AGENTS.md three-changes rule; gate `changemask`).

### 4.3 Audit trails

New subjects, each registered by the seven steps (`docs/change-log.md:437-461`) and rendered on its page: `device`, `weighbridge_ticket`,
`weighing`, `capture_draft`, `calibration`, `label_print`, `scan_event`, `discharge_result`, `meter_reading`, `processing_run`
(extended: values, events, corrections, closure), `blending_plan`, `sample`, `assay_dispute`, `ncr`, `coa`, `maintenance_part_issue`,
`inspection_run`, `incident`, `supplier_scorecard`, `supplier_statement`, `portal_user`. New events: `capture_confirmed` (changed fields
and reason), `capture_rejected`, `correction_recorded`, `balance_closed` (with explanation), `key_issued`, `key_revoked`, `outage_recorded`,
`reprinted` (reason), `dispute_opened/resolved`, `ncr_disposed`, `coa_issued/voided`.

---

## §5 · (e) The "to be supplied later" register

Each value is a column or settings row left NULL. Its page shows **"Not yet set"**, names the supplier of the value and the trigger, and the
value is listed on one read-only page, `/settings/pending-values` (a view over every such NULL), and in `docs/mes-pending-values.md`
(created by MES-1 and extended by each cut). No value below is filled by this group.

### 5.1 Numeric values

| # | value | page showing "Not yet set" | supplied by | trigger | cut |
|---|---|---|---|---|---|
| V1 | Allowed balance variance per operation type (% of input) | operation-type settings; every run's closure panel | Tim with cto (process engineer) | end of commissioning of each stage | MES-4a |
| V2 | Stock ceiling per licence × waste category (t) | `/purchasing/licences` | NEA licence conditions | NEA licence issued | MES-3a |
| V3 | Dwell warning days per safety state | dictionary `inbound_safety_states`; dwell report | Tim with the WSH officer; licence storage conditions | NEA licence issued or first swollen/leaking receipt | MES-3a |
| V4 | Which safety states require quarantine (beyond swollen/leaking) | same dictionary | Tim / WSH officer | before the first receipt of damaged stock | MES-3a |
| V5 | Heartbeat interval per gateway | device page | integrator / device vendor | gateway commissioning | MES-1 |
| V6 | Working hours for transmission-anomaly listing | settings (uses `shifts.starts_at/ends_at`) | Tim | shift times decided | MES-1 |
| V7 | Shift start/end times | `shifts` dictionary (already NULL by design) | Tim | before line start | MES-4a |
| V8 | Calibration validity per instrument (certificate's own valid-until) and reminder lead days | device page | accredited calibration body / instrument vendor | instrument installation | MES-2 |
| V9 | Discharge pass voltage for manually entered verdicts | discharge settings | Bosch documentation | discharge commissioning | MES-5a |
| V10 | Electrolyte mass fraction of cells (for a derived electrolyte loss) | operation-type settings | cell supplier datasheets / process engineer | first electrode-separation batch | MES-4b |
| V11 | Contamination rate warning level | contamination report | Tim / first offtake customer's specification | first black-mass offtake contract | MES-4b |
| V12 | Tool replacement cut count per blade | device page | equipment vendor | casing-removal commissioning | MES-4a |
| V13 | Splitting limit per contract (exists, nullable) | contract editor | counterparty contract | contract signing | exists |
| V14 | Arbitration fee split rule per contract | contract editor | counterparty contract | contract signing | MES-6a |
| V15 | Penalty thresholds and rates for F and Cl (table exists) | contract editor | counterparty contract (U11) | first contract with a penalty structure | MES-6a |
| V16 | Internal sample retention days (non-contract samples) | samples settings | Tim / quality | first retained sample | MES-6a |
| V17 | Moisture and particle-size acceptance limits | contract grade specs | customer contract | first offtake contract | MES-6a |
| V18 | Inspection frequency and items per checklist | inspection templates | qualified safety engineering firm / WSH officer | before line start | MES-7b |
| V19 | Incident written-report deadline (repo records "two working days", `docs/forward-queue.md:1686`) | incident settings | confirmation against the NEA licence | NEA licence issued | MES-7b |
| V20 | Emission limits per monitored parameter | environmental monitoring | NEA licence | NEA licence issued | MES-7b |
| V21 | Spare-part minimum stock | spare-part material | cto / vendor | equipment acceptance | MES-7a |
| V22 | MTBF/MTTR operating-hours basis (the open "分母" ruling) | reliability report | Tim | Q71 | MES-7a |
| V23 | Scorecard measures' weights, grade thresholds, review period | scorecard settings | Tim with cco | first supplier review after go-live | MES-8a |
| V24 | Grade → prepayment ratio cap; grade → sampling level | scorecard settings | Tim with cco | same | MES-8a |
| V25 | Unmetered electricity treatment and shared-meter split | electricity allocation | Tim | first utility bill after meters connect | MES-5a |
| V26 | NEA return format and frequency | compliance pack | NEA | NEA licence issued | MES-8b |
| V27 | EU recycling-efficiency method and targets | compliance pack | EU regulation's implementing act / the EU buyer | first EU-bound sale | MES-8b |
| V28 | Wall-display refresh interval and tiles | display settings | Tim | display installed | MES-8b |
| V29 | Hazardous waste category of each material (for on-hand tonnage) | material editor | NEA licence categories | NEA licence issued | MES-3a |
| V30 | DG marking text, packing instruction, label size per DG code | DG dictionary | DG-qualified forwarder | first export | MES-3b |
| V31 | HS code per material | material editor | customs broker | first export | MES-3b |
| V32 | Ingestion failure budget, payload cap, messages per call (engineering) | `ingest_settings` | Tim (recommended values in Q7) | MES-1 | MES-1 |

### 5.2 Device interfaces (reserved; manual entry stands in)

Every device row starts `interface_status = 'reserved'` or `'manual_only'`; its page says **"Not yet connected — entered by hand"** and lists
the §8.1 contract terms as unchecked items.

| # | source | reserved interface | manual stand-in page | supplied by | trigger |
|---|---|---|---|---|---|
| D1 | 10–12 scales incl. weighbridge | `weighing` class | weighing entry, weighbridge ticket | scale vendor + integrator | line layout / scale selection |
| D2 | Bosch discharge cabinets | `discharge_module` class; per-module export (§8.1 [S]) | per-module result entry | Bosch | purchase contract |
| D3 | Controllers: case opening (hard, pouch), separation (wound, stacked), stripping | `controller_summary` class | run values entry | each equipment vendor | equipment selection (point list) |
| D4 | Electricity meters | `meter_reading` class | meter reading entry | electrical contractor | meter installation |
| D5 | Workstation terminals | `workstation_event` class (also a browser page) | the same page by hand | none — a tablet and a login | station set-up |
| D6 | Barcode scanners | keyboard-wedge or camera on the scan page; `scan` class for fixed readers | the scan page by typing | scanner vendor | scanner purchase |
| D7 | Inline moisture and particle size | `inline_quality` class | assay entry | instrument vendor | instrument installation |
| D8 | Safety alarm panel | `safety_alarm` class (event output via the gateway) | incident entry | safety engineering firm | alarm system commissioning |
| D9 | Gateways | heartbeat + `ingest_submit` | — (devices page shows silence) | integrator | gateway installation |
| D10 | Thermal label printers | ZPL or similar | browser print (A6 HTML) | printer vendor | printer purchase |

---

## §6 · (f) Overlap with UNBLOCK-1's U1-B

U1-B's scope is `docs/forward-queue.md:6735-6748` and Step 0 §7 (`docs/surveys/UNBLOCK-1/STEP0-HANDBACK.md:595-617`); Tim accepted every
Step 0 recommendation (`docs/handbacks/U1-A.md:4-5`) [M].

| U1-B item | relation to MES | disposition |
|---|---|---|
| 3.5 Downtime correct + void (Q15) | MES-7a adds cause/source to downtime and controller-sourced rows | **go ahead in U1-B**; MES-7a builds on the void columns |
| 4.2 Deep-discharge judgement function (Q20) | the purchase-time judgement; MES-5a records the actual per-module outcome | **go ahead**; independent |
| 4.3 Machine on processing runs, optional picker (Q21) | MES-4a links machines to operations and makes the machine required where an operation has machines (Q41) | **go ahead** as the optional picker; MES-4a tightens it |
| 5.1 Month-end checklist + processing error codes | MES-4a adds balance closure, which month-end lists (Q48) | **go ahead**; independent |
| 4.4 Delete three dead actions; keep the rollback stub | MES-4a's quantity corrections reuse the rollback request path | **go ahead** |
| 3.7 GHOST-GRANTS scripts (shared throwaway role helper) | every MES probe and the portal probe mint throwaway accounts | **go ahead first** — MES probes use the helper |
| extra (c) `U1A-SELF-GATE-NULL-TRAP` (nine leave functions open to accounts without an employee row) | a supplier portal account has no employee row | **go ahead first** — a precondition of MES-9 |
| 3.3 shipped add-lines · 3.6 expense other-decider · 4.5 PO close reason · 3.12 `PERIOD_LOCKED` mapping · 3.9 ForwarderPanels · 3.10 kpi/score rows · extras (a), (b) | none | **independent; go ahead** |

U1-B is built first and unchanged (Q1).

---

## §7 · (g) Overlap with existing queue items

| queue item | location | this group |
|---|---|---|
| CoA per batch, before the first real sale | `docs/forward-queue.md:1681` | **absorbed** (MES-6b) |
| HS and UN numbers, DG declaration, before the first export | `:1682` | **absorbed** (MES-3b; codes per Q38) |
| Basel full chain, before the first cross-border move | `:1683` | not absorbed |
| NEA licence conditions as data | `:1684` | **partly absorbed**: ceilings by category, storage conditions (dwell, quarantine), reporting duties as compliance-pack placeholders (MES-3a, MES-8b); waste codes ride with V29 |
| Disposal chain with by-products | `:1685` | not absorbed |
| WSH incident and near-miss register + NEA two-working-day duty | `:1686` | **absorbed** (MES-7b) |
| `may_be_fed` consumer or delete | `:1687` | not absorbed (housekeeping) |
| G8 — run duration, shift attribution | `:1688`, `:2075-2097` | **absorbed** (MES-4a) |
| "每吨" denominator ruling | `:1689` | **depends**: MES-5a electricity per tonne uses it (Q26) |
| Operation ↔ asset link | `:1690` | **absorbed** (MES-4a) |
| `form_code` required on new materials | `:1692` | **adjacent**: yield by chemistry needs Tim's material data (Q60) |
| Environmental monitoring when the line runs | `:1693` | **absorbed** (MES-7b) |
| ESG and quality report | `:1694` | not absorbed |
| Supplier due diligence | `:1695` | not absorbed (the scorecard reads compliance only) |
| Regulatory material balance | `:1720` | **absorbed** (MES-5b, MES-8b) |
| G29 quality hold, G22 rejection right | `:1711-1719` | G29 **absorbed** (MES-6b); G22 not |
| Retained samples (Stage 5 / event-driven) | `:1624`, `:1642-1645`, `:2926` section | **absorbed** (MES-6a) |
| Stage 2: non-batch inventory, consumables, spare parts | `:477-484` | **absorbed** for spare parts as batches (MES-7a, Q70) |
| Stage 7: recipes / BOM | `:1862` | **absorbed** (MES-4a) |
| Stage 7: G7 operation types, G9 heel, G13 un-weighed recycle streams | `:2075-2097` | G7 **absorbed** (Q37); G9 partly (equipment hold-up loss, Q56); G13 partly (sweepings, Q56) |
| Stage 7: barcodes and the mobile shop floor | `:2096` | **absorbed** (MES-3b) |
| `CODE-WIDTH-4` | `docs/known-issues.md:3260` | **absorbed** (MES-4b) |
| `SETTLE-1` gaps (sample, penalties, F/Cl) | `:6489` | **absorbed** (MES-6a/6b) |
| `CONTRACT-1` grade breach → hold | `:6354` | **absorbed** (MES-6b) |
| `AT1B-EQUIPMENT-LIST-EVERY-ASSET`, unmonitored machines, equipment tables without functions | `:9894`, `:4288`, `:4246` | **absorbed** (MES-1 registry, MES-7a) |
| PROC-3 §1: hazard-flag removal leaves no record | `:4349` | **absorbed** (MES-3a state history) |
| `HISTORY1-DISABLED-TOKEN-HOUR` | `:9767` | **designed around** (MES-9 checks revocation in its own functions) |
| Anonymous-surface shrink (waiting on Tim) | `docs/forward-queue.md` (乙 index) | independent; MES-1 adds exactly one anonymous function (Q95) |
| Verification domain before production certificates | `:1753-1767` | not absorbed; CoA raises its urgency (Q96) |
| LME auto-fetch, market calendar (`PRICE-1`) | `:2073`, `docs/known-issues.md:6422` | not absorbed; MES-8b uses recorded prices |

---

## §8 · (h) Cut plan

### 8.1 Calibration (measured; `cut-durations.md`)

- **Process floor** of a database cut today: **≈ 1 h 30 m clean** (AT-1d-1 1 h 28 m, AT-1d-3 1 h 37 m, U1-A 1 h 28 m) and **≈ 2 h 10 m –
  2 h 30 m with one rerun**; 12 of 37 database cuts needed a process retry (8 infrastructure). Floor used below: **1 h 30 m – 2 h 30 m**.
- **Work**: a new table with its functions, mirror and fixture ≈ **30–60 min** (median of seven one-table cuts ≈ 50 min); a new page
  ≈ **25–45 min**; named extras as stated per cut.
- **Bias**: U1-A, whose design a survey had pinned to file:line, took 3 h 39 m against 5 h 30 m – 8 h 15 m (0.44–0.66). The low ends below
  are the likelier outcome.
- **Growth**: gate and smoke grow with fixtures and routes (gate median 445 s now vs 310 s in AGENTS.md); 60 tables and 50 pages raise
  every later floor.

### 8.2 Recommended cuts (15)

Formula: work = tables × 30–60 m + pages × 25–45 m + extras; total = floor + work.

| cut | functions | contents | migration | tables / pages | extras | estimate (floor + work = total) |
|---|---|---|---|---|---|---|
| **MES-1 · Entry point** | foundation | `devices`, `gateway_keys`, `ingest_settings`, `ingest_data_classes`, `ingest_inbox`, `ingest_transmissions`, `gateway_outages`; `ingest_submit`, key issue/revoke, dispatcher, retry/discard, `gateway_health`, anomaly and gap views, silent-gateway arm; pages `/operation/devices`, `/operation/devices/[id]`, `/operation/capture/inbox`; `docs/mes-pending-values.md` + `/settings/pending-values` | one | 7 / 3 | anonymous-surface proof (baseline, B1, verdict 6 fault-injected), live HTTPS probe as a throwaway gateway (revoked, unknown, duplicate, gap, heartbeat, read attempt): 1–2 h | 1h30–2h30 + 5h45–11h15 = **7h15–13h45** |
| **MES-2 · Confirmation, weighing, calibration** | 1, 20, draft/confirm | `capture_drafts`, `capture_draft_changes`, `weighings`, `weighbridge_tickets` (+ links to receipts/shipments), `instrument_calibrations`, photo bucket; manual-capture path; weighing transform; calibration gate in price-setting functions and `issue_cod`; receipt and shipment forms pick a ticket | one | 6 / 4 | calibration gate regression in 3–4 existing functions: 1.5–2 h | 1h30–2h30 + 6h10–11h00 = **7h40–13h30** |
| **MES-3a · Storage safety** | 4, 5, 6 | `licence_storage_limits`; location kind; state → location rule and dwell days on `inbound_safety_states`; state history (close instead of delete); hazardous on-hand; refusal at receipt; quarantine gate at the four landing points; dwell arm and report | one | 3 / 3 | landing-point gates + commit-path state history: 1.5–3 h | 1h30–2h30 + 4h15–8h15 = **5h45–10h45** |
| **MES-3b · Labels and scanning** | 7, 8 | `label_templates`, `label_prints` (reprint reason), `dangerous_goods_codes`, material UN/HS columns, `scan_events` + scan transform; `/inventory/scan` (wedge + camera); label routes take templates | one | 4.5 / 3 | phone-width scan probe: 1 h | 1h30–2h30 + 4h30–7h45 = **6h00–10h15** |
| **MES-4a · Processing record** | 11, 13 (counts), §4.1 | `operation_type_fields` (parameters and indicators as configuration), `processing_run_values`, `process_recipes`, `processing_run_events`, `processing_run_corrections`, `operation_type_equipment`; run start/end/shift/operator; machine required where linked; tolerance per operation; closure step; losses append-only; UPDATE-policy debt closed; new operation types per Q37; controller and workstation transforms | one | 7 / 4 | `commit_processing_run` signature + regression: 2–3 h | 1h30–2h30 + 7h10–13h00 = **8h40–15h30** |
| **MES-4b · New fields and products** | 13 (fields), 14 | `cell_constructions`, `contamination_checks`; construction on both batch tables (masked: column + grant + view); loss `basis` (measured/derived) + basis factor; new forms and loss categories (data); per-product prefixes, `generate_output_code`, per-prefix sequences, `CODE-WIDTH-4` | one | 4 / 3 | numbering + fixture 100 anchors + search registry: 1–2 h | 1h30–2h30 + 4h15–8h15 = **5h45–10h45** |
| **MES-5a · Discharge and energy** | 2, 3 | `discharge_module_results`, `discharge_channel_assignments`, `meter_readings`, `electricity_allocations`; verdict → safety state by module; quarantine split of failed modules; allocation posts processing cost entries | one | 4 / 4 | commit path + GL posting proof: 2–3 h | 1h30–2h30 + 5h40–10h00 = **7h10–12h30** |
| **MES-5b · Balance, yield, blending** | 9, 10, 12 | per-inbound-batch and monthly balance views; yield views; `blending_plans`, `blending_plan_lines`, blending operation | one | 3.5 / 5 | attribution fixtures: 1 h | 1h30–2h30 + 4h50–8h15 = **6h20–10h45** |
| **MES-6a · Samples, arbitration, F/Cl** | 15, 16, 19 | `samples`, `assay_disputes`; `substances.role` + F, Cl rows; laboratory → supplier link; purchase-side hold in `apply_assay_result` / `reprice_inbound_batch`; inline quality transform | one | 3 / 3 | purchase-side hold regression: 1 h | 1h30–2h30 + 3h45–6h15 = **5h15–8h45** |
| **MES-6b · NCR, quality hold, CoA** | 17, 18 | `nonconformance_reports`, `certificates_of_analysis`, `coa_issues`; hold linked to NCR; CoA PDF, archive, void request | one | 3.5 / 4 | PDF + archive + CFO void chain: 1.5–2.5 h | 1h30–2h30 + 4h55–9h00 = **6h25–11h30** |
| **MES-7a · Spare parts and reliability** | 21, 22 | `maintenance_part_issues`, issue movement type, `downtime_causes`; downtime cause/source; MTBF/MTTR report | one | 2.5 / 2 | `inventory_movements` type change: 1–2 h | 1h30–2h30 + 3h05–6h00 = **4h35–8h30** |
| **MES-7b · Inspections and incidents** | 23, 24 | `inspection_templates`, `inspection_template_items`, `inspection_runs`, `inspection_results`, `incidents`, `incident_batches`, `environmental_monitoring_results`; alarm transform; report-deadline arm | one | 7 / 5 | working-day deadline + health masking: 1–2 h | 1h30–2h30 + 6h35–12h45 = **8h05–15h15** |
| **MES-8a · Supplier scorecards and statements** | 25, 26 | `supplier_score_rules`, `supplier_scores`, `supplier_statements`, `supplier_statement_issues`; effects per Q77 | one | 4 / 3 | effects at PO creation: 1 h | 1h30–2h30 + 4h15–7h15 = **5h45–9h45** |
| **MES-8b · Analysis and display** | 28, 29, 30, 31 | inbound-batch margin, inventory exposure, `compliance_packs` (freeze), wall display (role, idle exemption, refresh) | one | 2.5 / 4 | display role and idle exemption: 1–2 h | 1h30–2h30 + 3h55–7h30 = **5h25–10h00** |
| **MES-9 · Supplier portal** | 27 | `supplier_portal_users`, `portal_invitations`; `/portal` route group; internal-only sweep of the 44 `USING (true)` policies and of default `EXECUTE`; revocation checked inside portal functions | one | 2 / 5 | sweep + external-session probe: 3–5 h | 1h30–2h30 + 6h05–10h45 = **7h35–13h15** |

**Total ≈ 97 h 40 m – 174 h 45 m** (floors 22 h 30 m – 37 h 30 m of it). Order and dependencies:

```
U1-B ─▶ MES-1 ─▶ MES-2 ─┬─▶ MES-3a ─▶ MES-3b
                         └─▶ MES-4a ─▶ MES-4b ─▶ MES-5a ─▶ MES-5b
                                                   MES-6a ─▶ MES-6b      (6b needs 2's calibration gate)
                                                   MES-7a ─▶ MES-7b      (7b needs 1's alarm class, 3a's hold/quarantine)
                                                   MES-8a ─▶ MES-8b      (8a reads 6b's NCRs; 8b needs 5b's balance)
                                                                    ─▶ MES-9 (last)
```

### 8.3 Why these boundaries

- **MES-1 alone**: the only cut that adds to the anonymous surface; its proof is a security proof (who can call what, what is logged,
  what is refused). A red business fixture must not hold an anonymous-surface change in an open window, or the reverse.
- **MES-9 alone and last**: the first external login and the largest security surface (Tim's ruling); its sweep touches policies across
  the whole schema.
- **Pairs split (3a/3b, 4a/4b, 5a/5b, 6a/6b, 7a/7b, 8a/8b)**: each pair is one domain with two proof shapes — refusals at landing points vs
  printing and scanning; the commit path vs numbering and masked columns; safety admission and GL posting vs read-side reports and plans;
  internal quality records vs an external certificate; an inventory movement type vs a legal-duty register; supplier records vs
  cross-module analysis. Merged, every pair estimates above **10 h at its low end**, beyond the largest measured cut (AT-1c-2, 9 h 50 m).
- **Every cut leaves usable pages**: MES-1 the device register, keys and inbox; MES-2 weighing, tickets and the confirmation queue; each
  later cut its own pages; nothing waits on a device.

**Merge option** (Q3): the six pairs merged give **9 cuts** and save six floors (≈ 9 h – 15 h), at **10 h – 22 h per merged cut**.

---

## §9 · (i) Every open question, with a recommended answer and its evidence

Questions in one block are independent unless a question names another.

### A · Scope and order

❓ **Q1 — U1-B before MES-1, unchanged?**
U1-B fixes the leave NULL-trap a portal account would hit and builds the throwaway-role helper every MES probe needs (§6).
➡️ **Yes.** U1-B ships first exactly as ruled; MES-1 starts after its push.

❓ **Q2 — Scheduling, the twelfth vendor module.**
The 31 functions map to eleven of the twelve vendor modules; scheduling maps only to work orders (`scheduled_date`) and blending plans.
➡️ **Out of the 31; record it.** A machine × shift board is a separate function if Tim names it; nothing in the 31 depends on it.

❓ **Q3 — 15 cuts or the 9-cut merge.**
➡️ **15 cuts** (§8.3). The merge saves six floors but puts every merged cut beyond any measured run.

### B · Ingestion layer

❓ **Q4 — Gateway transport and authentication.**
(a) one anonymous-executable SECURITY DEFINER function + per-gateway hashed keys, called over HTTPS; (b) a Vercel route in front;
(c) a Supabase auth user per gateway; (d) a Postgres login role per gateway; (e) an Edge Function.
➡️ **(a)** (§3.3): the only option that meets "zero read" on today's schema and that today's gates can watch.

❓ **Q5 — Keys: hashed, shown once, two active per gateway?**
➡️ **Yes.** SHA-256 through `pgcrypto` (installed), prefix displayable, secret shown once; two active keys allow rotation without a stop.

❓ **Q6 — Heartbeat logging volume.**
Every call logged one row each grows with the heartbeat interval (one per minute ≈ 525,600 rows per gateway per year).
➡️ **Data calls one row each; heartbeat-only calls counted in hourly bucket rows** (gateway, hour, count, bytes, rejected). Every transmission
is still logged; the volume stays proportional to batches, as §2.1 of the specification asks.

❓ **Q7 — Engineering limits.**
➡️ **Failure budget 30 per 10 minutes per presented gateway code** (the `cod_verification` figure, `db/functions/cod_verification.sql:19-24`),
**payload cap 256 KB per call, 500 messages per call**, all in `ingest_settings`, editable by `action.manage_devices`. These are transport
limits, not business standards; if Tim prefers, they start NULL and the function refuses until set.

❓ **Q8 — Sequence gaps: block or record?**
➡️ **Record, never block.** Gaps list on the device page until the missing numbers arrive; transforms do not wait, because confirmation
already orders the record by site time.

❓ **Q9 — Missing heartbeat with no scheduler.**
➡️ **Derive the current silence on read, record past silences when the gateway returns** (§3.8). No `pg_cron` is installed and none is needed.

❓ **Q10 — Manual entry: does the enterer's own entry need a second confirmation?**
➡️ **No.** The enterer confirms in the same action; `source = 'manual'`; same transform.

❓ **Q11 — Who confirms gateway drafts?**
➡️ **New `action.confirm_capture`** held by warehouse, cto and admin. Any holder may confirm any station's draft; the station is shown.

❓ **Q12 — Which fields may change at confirmation?**
➡️ **Measured values and the subject they attach to (batch, run), each with a reason. Never** the device, gateway, sequence or site time range.

❓ **Q13 — Unconfirmed drafts.**
➡️ **Never expire.** A reminder arm lists drafts by age; rejection needs a reason; the inbox row stays.

❓ **Q14 — Change log on the ingestion logs.**
➡️ **Exclude `ingest_inbox`, `ingest_transmissions`, `gateway_outages`** with reasons in `change_log_exclusions()`; log everything else.

❓ **Q15 — Retention of inbox payloads.**
➡️ **Keep all.** Volume is per batch (≈ 331 business-document rows live today, measured); revisit only when a measured size says so.

❓ **Q16 — Supabase plan before the first gateway.**
The project is on the free tier with auto-pause and no point-in-time recovery (`docs/forward-queue.md:2958-2961`).
➡️ **Move to a paid plan before the first gateway connects.** Cost is Tim's call; until then the device page states the risk.

❓ **Q17 — Server identity on the gateway.**
➡️ **Standard certificate verification against public CAs, no pinning.** Recorded as an integrator requirement (D9).

❓ **Q18 — Recording the caller's address.**
Whether the project's REST layer passes the client address through to `request.headers` is not measured.
➡️ **MES-1 measures it with its live probe; if absent, the column reads "not available"** rather than a proxy address.

### C · Data capture

❓ **Q19 — Weighbridge ticket model.**
➡️ **A ticket pairs a gross and a tare weighing (in loaded / out empty, or the reverse), with vehicle registration and direction; net is
computed. One ticket may feed several receipts or shipment lines with explicit kg each; the sum is shown against net, not forced.**

❓ **Q20 — Ticket photo storage.**
➡️ **A new private bucket `capture-photos`, readable with `module.inbound.view` or `module.logistics.view`.** The finance attachment type
`weighbridge` stays for AP paperwork.

❓ **Q21 — Receipt quantity when a ticket is linked.**
➡️ **Defaults to the ticket's share; the person may change it with a reason**; the receipt keeps both.

❓ **Q22 — Must every output leg reference a weighing?** (specification §3.2 rule 3)
➡️ **Yes, for runs committed from MES-4a on.** A manual weighing counts. Older runs stay as they are.

❓ **Q23 — Discharge granularity and failure disposition.**
➡️ **One result row per module. A batch becomes `discharged_verified` only when every module's latest result passes. Disposition
`re_discharge` keeps the module in the batch (not yet verified); `quarantine` splits the failed modules into their own batch at a quarantine
location with state `charged_not_discharged`.**

❓ **Q24 — Today's whole-batch flip on a partial discharge.**
➡️ **Replace it in MES-5a with the Q23 rule** (`commit_processing_run.sql:354-363`); fixture both arms.

❓ **Q25 — Discharge evidence when the equipment cannot export** (§8.1 [S]).
➡️ **Per-module manual entry, `source = 'manual'`, with an optional screen photo; the batch shows "per-module data not exported".**

❓ **Q26 — Electricity allocation by measured use.** (depends on the "每吨" ruling, `docs/forward-queue.md:1689`)
➡️ **Split each period's bill across the runs in that period by metered kWh share; unmetered or shared remainder stays overhead (6200).
Allocation writes `processing_cost_entries(electricity, is_estimate = false)` and relieves estimates; manual entry stays for unmetered machines.**

❓ **Q27 — A meter feeding several machines.**
➡️ **The meter maps to a machine or to a shared pool; a shared pool is not spread until V25 is set.**

❓ **Q28 — Scanning technology.**
➡️ **Keyboard-wedge input on the scan page (any HID scanner) plus the browser's native `BarcodeDetector` where available; no new
dependency.** iOS without `BarcodeDetector` uses a wedge scanner or typing. A decoding library is a separate decision if needed.

❓ **Q29 — QR payload on labels.**
➡️ **Encode the batch code in a short URL (`/b/<code>`) resolved by code with the reader's permissions**, instead of an internal edit URL;
phone scanning keeps working and the code survives an id change.

❓ **Q30 — Calibration gate scope.**
➡️ **Refuse pricing and certificates when a reading names an instrument that was out of calibration at capture time. A reading with no
instrument is flagged "instrument not recorded", not refused, until the setting `require_calibrated_instrument` is turned on** (off until
scales exist). Lab assays are the laboratory's accreditation, out of scope.

❓ **Q31 — Calibration validity.**
➡️ **Each calibration record carries its certificate's own valid-until (required); a reminder lead is V8.**

### D · Warehouse

❓ **Q32 — Ceiling granularity.**
➡️ **Per licence × waste category, in tonnes, counting inbound and output batches of hazardous materials still on site.**

❓ **Q33 — Receipts while no ceiling is set.**
➡️ **Proceed and record "ceiling not set" on the receipt**; refuse only when a set ceiling would be exceeded. (An action may refuse; but
refusing on an unset value would stop every receipt today.)

❓ **Q34 — Which states require quarantine.**
➡️ **`swollen_leaking` from MES-3a (Tim's brief); `damaged_deformed`, `water_exposed`, `charged_not_discharged` stay "Not yet set" (V4).**

❓ **Q35 — Dwell clock.**
➡️ **From the time the state was recorded** (needs Q36), warning only, no refusal.

❓ **Q36 — Safety-state history.**
➡️ **Close a state (`ended_at`) instead of deleting it**, everywhere states change. This also closes PROC-3 §1.

❓ **Q37 — Stage model: the specification's five stages vs the live operation types.**
Live `electrode_line` joins casing removal and separation (Tim's R2); `electrode_powder_line` outputs `black_mass` only [M].
➡️ **Add `casing_removal` and `electrode_separation` as operation types; keep `electrode_line` active for the combined machine if one is
bought; add powder-stripping outputs as forms (Q55) on `electrode_powder_line`.** Operation types are dictionary rows: if the plant buys the
combined machine, configuration changes, not code.

### E · Labels and DG

❓ **Q38 — Which UN numbers.**
The brief names UN3480 / UN3090; the queue names UN3480 / UN3481 (`docs/forward-queue.md:1682`).
➡️ **A dictionary with UN3480, UN3481, UN3090, UN3091, class 9**; marking text and packing instruction per code are V30 (forwarder).

❓ **Q39 — HS codes ride along?**
➡️ **Yes**, nullable on materials (V31); the queue pairs them with UN numbers.

❓ **Q40 — Printing.**
➡️ **Browser print of templated A6/A5 HTML now; thermal printers are a reserved interface (D10).** Reprint needs a reason; anyone who may
print may reprint.

### F · Production

❓ **Q41 — Machines per operation.**
➡️ **A link table; a run of an operation with at least one linked active machine requires the machine.** (Tightens U1-B Q21's optional picker.)

❓ **Q42 — Run time and shift.**
➡️ **`started_at`, `ended_at` (timestamptz) and `shift_code` required on runs committed from MES-4a on**; historical runs stay NULL.
Shift is chosen, not derived, because shift times are not set (V7).

❓ **Q43 — Parameters and indicators: columns or configuration.**
➡️ **Configuration**: a per-operation field dictionary (`parameter` or `indicator`, unit, required) and values on the run. Counts in
function 13 (hard-case, pouch, manual adjudication, misclassification, damaged cells, scrap by cause, cut counts) are indicators.

❓ **Q44 — Recipes.**
➡️ **Named, versioned parameter presets per operation; the run stores its values and the recipe version used.**

❓ **Q45 — Construction attribute.**
➡️ **On both batch tables; required at electrode-separation input, optional at receipt; values `wound`, `stacked`, `unknown`.**

❓ **Q46 — Balance tolerance not set.**
➡️ **Any non-zero unexplained remainder needs a written explanation to close.** No number is assumed.

❓ **Q47 — Over-tolerance closure: explanation or second person.**
➡️ **Explanation only** (Tim's principle). The closure list is visible to cto.

❓ **Q48 — Month-end and unclosed balances.**
➡️ **Month-end lists them as a warning; it does not block.** Blocking would tie production closure to the finance close.

❓ **Q49 — Corrections.**
➡️ **Non-stock fields (values, events, losses, classifications): append-only correction rows with a reason. Quantities: today's reversal
request (CFO) plus a new run with `corrects_run_id`. Losses become append-only; the processing UPDATE policies are dropped.**

❓ **Q50 — Who closes a run's balance.**
➡️ **Holders of `action.processing_aftercare`** (today's loss editors).

❓ **Q51 — Derived electrolyte loss.**
➡️ **Derived = electrolyte mass fraction (V10) × cell input mass, marked `derived`; never the residual.** Without V10 the loss is either
measured or left unexplained.

❓ **Q52 — Contamination checks.**
➡️ **A check = sample mass and foreign-material mass per stream, attached to the output batch and to the run's shift; an arm lists each
shift with electrode separation and no check.**

❓ **Q53 — Device code prefix.**
➡️ **`DEV-` through `document_types`**, so devices are searchable; weighbridge tickets `WB-`; samples `SMP-`; NCR `NCR-`; CoA `COA-`;
incidents `INC-`; inspections `INS-`; supplier statements `SST-`. Weighings, scans and module results carry no code.

❓ **Q54 — Output prefixes.**
➡️ **One prefix per product family, chosen from the material form, each with its own sequence:** `CPW` cathode powder · `APW` anode powder ·
`CUF` copper foil · `ALF` aluminium foil · `SEP` separator · `DST` collected dust · `CEL` cells · `CSG` casing · `STR` structural parts ·
`HBB` harness/BMS/busbar · `CTS` cathode sheet · `ANS` anode sheet; `OUT` stays for anything else. Codes are Tim's to change.

❓ **Q55 — New forms.**
➡️ **Add `cathode_powder`, `anode_powder`, `copper_foil`, `aluminium_foil`, `collected_dust`, `harness_bms_busbar`** (13 → 19); saleability
per form is Tim's (`may_be_sold`).

❓ **Q56 — New loss categories.**
➡️ **Add `sampling_consumption`, `equipment_holdup`, `sweepings`** (the specification's list); no "other".

❓ **Q57 — Number width.**
➡️ **Widen to five digits for new sequences and fix the three truncating generators (`CODE-WIDTH-4`) in MES-4b.**

❓ **Q58 — Blending plans.**
➡️ **A plan = a target composition (from a contract grade spec or entered) + candidate batches with planned kg + the predicted composition
from batch metal content; executed as a `blending` run referencing the plan; gated like work orders.**

❓ **Q59 — Balance per incoming batch through multi-input runs.**
➡️ **By mass consumed** (a mass balance is a mass question). Monthly balance by `process_date` month, plant-wide and per operation.

❓ **Q60 — Yield by chemistry.**
Chemistry lives on materials and only 2 of 9 have it (`docs/forward-queue.md:1692`).
➡️ **Keep chemistry on materials; the report shows a "chemistry not recorded" group.** Filling it is Tim's data entry.

### G · Quality

❓ **Q61 — Samples.**
➡️ **Entity with code, source batch, kind (ours · counterparty · umpire · retained · contamination), location, retain-until (contract days or
V16), recipient, disposal; `assay_results.sample_id` added beside the free text.**

❓ **Q62 — Purchase-side arbitration.**
Buy-side contracts require no settlement terms (`contract_activation_missing.sql:3`).
➡️ **Prompt only where a splitting limit exists; otherwise the dispute shows "limit not set". While a dispute is open, final repricing of
that batch refuses.**

❓ **Q63 — Fee split.**
➡️ **A contract term (loser pays · equal · further-from-umpire pays · buyer · seller), V14; the fee is an expense through the existing chain;
the counterparty's share is a receivable or a deduction.**

❓ **Q64 — Laboratories as payees.**
➡️ **Link `laboratories` to `suppliers`** (Tim's earlier ruling, `db/tables/laboratories.sql:30`).

❓ **Q65 — NCR sources and disposition.**
➡️ **Sources: a grade-breach row, an inspection, a customer complaint, manual. Dispositions: accept, accept with penalty, reject, rework,
downgrade. New `action.ncr_decide` (cco, cto, admin).**

❓ **Q66 — Quality hold (G29).**
➡️ **An open NCR puts the batch on hold through `hold_stock`, linked to the NCR; disposition releases it.**

❓ **Q67 — CoA issue and void.**
➡️ **Per output batch, from the final governing result; frozen snapshot, sha256 archive, English; new `action.issue_coa` (cco, admin);
void through a CFO request like the COD. No public verify page in this group.**

❓ **Q68 — CoA preconditions.**
➡️ **A final result exists; no open NCR or hold; instruments behind inline readings were in calibration.**

❓ **Q69 — F and Cl.**
➡️ **Two rows plus `substances.role` (payable_metal · penalty_element · other); pickers filter by role; content stays in %
(`content_pct` is unconstrained `numeric`, live), shown in ppm for penalty elements.**

### H · Equipment and safety

❓ **Q70 — Spare parts as stock.**
➡️ **Received as batches of kind `spare_part`; issued by a new movement type linked to the maintenance record.** No non-batch inventory.

❓ **Q71 — MTBF/MTTR denominator.**
➡️ **Operating hours = the sum of run durations on that machine (from Q42); failure = downtime with a failure cause.** This answers the open
"分母" (`db/tables/equipment_downtime.sql:58-63`) for reliability only, not for availability or OEE.

❓ **Q72 — Inspections.**
➡️ **Templates with items (V18), runs by an inspector with pass/fail/N-A per item, findings raised as tasks.**

❓ **Q73 — Alarm → incident → batches.**
➡️ **One incident per alarm event; affected batches suggested from the location and machine at that time and confirmed by a person;
marking is a link (and optionally a hold), never a safety state** (Tim's ruling).

❓ **Q74 — The NEA written-report deadline.**
➡️ **A setting pre-filled "2 working days", citing `docs/forward-queue.md:1686`, flagged "to be confirmed against the licence" (V19).**
It is not an invented figure; it is the repo's record of the duty.

❓ **Q75 — Emissions.**
➡️ **Periodic results entered from an accredited lab with limits V20; an exceedance raises an incident. Continuous sensors arrive only as alarms.**

❓ **Q76 — Safety permission codes.**
➡️ **New `module.safety.view` / `module.safety.edit`; injury details behind `data.view_health`.**

### I · Suppliers

❓ **Q77 — Scorecard effects** (conflict with index-pricing ruling #2).
➡️ **Price: advisory display only. Prepayment: a cap per grade (V24) checked at PO creation as a warning. Sampling: a level per grade
(V24) adding required assays.** Tim may turn any warning into a refusal later by setting, not code.

❓ **Q78 — Scorecard measures.**
➡️ **Short-delivery counts, grade breaches, NCRs, disputes, discharge-judgement accuracy, certificate lapses; weights V23; rolling period V23.**

❓ **Q79 — Supplier statements.**
➡️ **An issued statement of account, frozen, PDF, archived — the customer-statement shape.** Reconciling the supplier's own statement is later.

### J · Analysis and display

❓ **Q80 — Profit per incoming batch.**
➡️ **Attribute each output batch's revenue back through each run by that run's own `allocation_basis` (weight or metal value); cost =
landed cost + allocated processing cost; NULL if any leg is unpriced; predicate = decision 2.**

❓ **Q81 — Exposure currency.**
➡️ **USD with each price's date; no conversion until BLOCKERS-0 Q1/Q2 are answered; unassayed content shows "not measured".**

❓ **Q82 — Compliance pack.**
➡️ **NEA return (V26), regulatory balance (MES-5b), EU recycling efficiency (V27), frozen per period like management packs.**

❓ **Q83 — Wall display login.**
➡️ **A `floor_display` role holding one code that reads one SECURITY DEFINER board function; one account per screen; that role alone is
exempt from the idle logout; refresh V28.** No anonymous display.

### K · Portal

❓ **Q84 — What a supplier sees.**
➡️ **Own POs, receipts (quantities, ticket net, status), final assay results that set its price, statements, certificates of destruction;
uploads of its compliance certificates.**

❓ **Q85 — Revocation.**
➡️ **Every portal function checks `supplier_portal_users.revoked_at`**, because a banned user's token still works for up to an hour.

❓ **Q86 — Internal-only sweep.**
➡️ **Before the first supplier login, every `authenticated` policy reading `USING (true)` (44 measured) and the default function grant are
narrowed to internal accounts; proof: a supplier session reads zero internal rows and every internal function refuses it.**

❓ **Q87 — Who invites suppliers.**
➡️ **New `action.manage_portal_users`: admin, cco.**

❓ **Q88 — Portal URL.**
➡️ **`/portal` in the same app with its own layout**; a separate domain is a later decision.

### L · Approvals, permissions, register

❓ **Q89 — No new approval chain.**
➡️ **Confirmed as §4.1**: one new CFO request (CoA void); everything else is an event record or already-approved money.

❓ **Q90 — New permission codes and holders.**
➡️ `action.manage_devices` (admin, cto) · `action.confirm_capture` (warehouse, cto, admin) · `module.quality.view` (cco, cto, finance, cfo,
admin, warehouse) / `module.quality.edit` (cco, cto, admin) · `action.ncr_decide` (cco, cto, admin) · `action.issue_coa` (cco, admin) ·
`module.safety.view` (every role holding `module.processing.view`, plus cfo) / `module.safety.edit` (cto, warehouse, admin) ·
`action.manage_portal_users` (admin, cco) · `data.view_floor_board` (`floor_display`, admin). Every code also to admin (standing ruling);
every view code also to cfo ("CFO reads everything").

❓ **Q91 — Masking.**
➡️ **As §4.2**: key hashes never shown; injury details by `data.view_health`; scores by `module.suppliers.view`.

❓ **Q92 — Where "Not yet set" values live.**
➡️ **In their owning tables, listed by one view (`/settings/pending-values`) and in `docs/mes-pending-values.md`.**

❓ **Q93 — Who sets each value.**
➡️ **The owning page's edit code, with a history table** (the `finance_settings_history` precedent).

❓ **Q94 — Existing test data.**
➡️ **No back-fill.** New structures start empty; historical runs keep NULL times; all live data is test data.

❓ **Q95 — Anonymous-surface shrink, still waiting on Tim.**
➡️ **Independent.** MES-1 adds exactly one anonymous function regardless of that decision.

❓ **Q96 — Verification domain before production certificates.**
➡️ **Stays its own pre-production item;** CoA has no public page in this group, so it does not block MES-6b.

---

## §10 · Assertions measured and found false or imprecise

1. **Brief: "Stage 6 and Stage 7 entries … for CoA, licence conditions, retained samples, WSH incidents, spare parts, barcodes."** Imprecise.
   CoA, licence conditions and WSH incidents are Stage 6 (`docs/forward-queue.md:1681-1686`); barcodes Stage 7 (`:2096`); **spare parts are
   Stage 2** (`:477-484`); **retained samples are Stage 5 and the event-driven list** (`:1624`, `:1642-1645`, section `:2926`).
2. **Brief, function 7: "UN3480 / UN3090".** The queue says UN3480/3481 (`:1682`). Not false — a difference; Q38 takes all four.
3. **Specification §5.1: "prefix-year-sequence format".** Not universal: ATT, PACK, WHT use `YYYY-MM`, GST `YYYY-Qn`, CON the effective year
   (`evidence-functions-01-14.md` §14). The "> 30 prefixes" holds: 41 live.
4. **Specification §3.3–§3.4 treat casing removal and electrode separation as two stages**; the live dictionary, by Tim's interview, has one
   (`electrode_line`, live notes). A conflict to rule (Q37), not an error in either document.
5. **A survey agent reported that the queue does not record Tim's answers to U1-B's Q14–Q25.** False: `docs/handbacks/U1-A.md:4-5` records
   every Q1–Q26 recommendation accepted.
6. **`AT0-RUN-EQUIPMENT-NOT-PASSED` and a repo doc say "14 runs".** True of all rows; **10 undeleted**, 0 with a machine (live, as postgres).
7. **AGENTS.md tool costs are out of date** (measured from hand-backs, `cut-durations.md` §6): full gate median 445 s (not 310 s), offline
   51–74 s (not 44 s), backup median 18 min (not ~10), smoke 11–35 min wall (not 765 s).
8. **"Every page carries an audit trail."** Not machine-enforced for new pages [I, from `docs/change-log.md`; not measured page by page].
   Every MES page carries one by design (§4.3).

Matched on re-measurement: U1-A closed; three SHAs equal; 7 accounts, 0 disabled; approvals ON finance / cfo / 1,000; 238 change-logged tables;
13 material forms; 41 prefixes (> 30); the specification's "three-figure number of business document rows" (331 rows across the 40 tables
behind `document_types`, live).

## §11 · Stop

No code edits and no migrations. Waiting on Tim's answers to Q1–Q96.

## §12 · Tim's answers

Tim's answers, 2026-10-05: all Q1–Q96 accepted as recommended.

Recorded by U1-B (`v1.4.36`), which also queued the 15 cuts in `docs/forward-queue.md` («⬜ ★ MES 组» after UNBLOCK-1): Q3 → 15 cuts in §8.2's
order; Q2 → scheduling out of scope; Q16 → the Supabase project moves to a paid plan before the first gateway connects — Tim's own action,
a hard prerequisite of MES-1's gateway path on live; Q1 → U1-B first, unchanged.
