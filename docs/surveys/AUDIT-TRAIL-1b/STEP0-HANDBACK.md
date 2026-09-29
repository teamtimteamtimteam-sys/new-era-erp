# AUDIT-TRAIL-1b · Step 0 hand-back (stop gate)

Part of v1.4.33, not yet released.

**Opening check passed:** the tree was clean. `HEAD` = `origin/main` = `ls-remote` = `039ff877d7000433f84ae405cbcc7381ea0911a4`. I made no edits, migrations or commits; the only files written are in my scratchpad.

**How it was measured:**
- **Repo facts** come from four read-only survey agents: commercial, production, batch trail, and equipment/handovers/fold-ins. Each fact cites a file and line in the notes below.
- **Live figures** come from read-only queries through the Management API, running as `postgres` (`rolbypassrls = true`) on base tables. The query files are `scratchpad/at1b/m1.sql` to `m4.sql`.
- **Live state:** 7 accounts, 0 disabled. `change_log` holds 752 rows (max seq 759), the same as AT-1a's after-reading.

---

## 1. What grilling changed in this scope

1. **The AT-1a registry cannot express this part as written.** Six mechanism extensions are needed (M1–M6 in §g). The largest is the batch trail: **45 of its 292 live rows (15%)** reach the batch only through an upward hop (batch → run / PO / stocktake → the event). The AT-1a registry only walks downward (`member.fk = parent.id`). "Keep all 20 kinds, nothing lost" therefore needs an upward ("via") hop in `record_trail` (Q4).
2. **A new migration is needed.** It changes 6–8 functions, 2 read policies and one view, all additive or compatible (§h).
3. **The batch pages are `/inbound/[id]/edit` and `/output/[id]/edit`.** No `/inbound/[id]` detail page exists. Both 404 a written-off batch: **9 of 24 inbound and 6 of 20 output batches today**. A reversed run 404s too (**4 of 14**). Q21 is therefore a real fix on 19 records, not an edge case.
4. **The equipment trail as ruled is refused for the people Q22 names.** Its root, `fixed_assets`, can be read only with finance access. The `warehouse` role holds processing access without finance, which is exactly Q22's reader. Needs M3.
5. **Three singleton settings rows (the threshold panels) would show an empty trail with no error.** Their key is `id boolean`, and `record_trail` compares it as text. This is the "empty list reads as nothing happened" failure. Fix in M5.
6. **Lanes, ports and company licences have no detail page, and `/inventory` needs a list-level block.** `record_trail` reads one record at a time (Q12).
7. **`/settings/deleted` lists only 7 kinds.** Customers, suppliers, materials and formulas are not among them, so a deleted master record has no way in even for `data.view_deleted` holders. Its sales-order and quote links 404 (Q9).
8. **Customers, suppliers, materials and metal prices never recorded who deleted them.** They have no `deleted_by`, so a Q21 banner cannot always name a person (Q8).
9. **Size.** This is about 25 subjects and about 700 field labels. AT-1a was 3 subjects and 197 labels. The work estimate is **20–26 h**, so the part needs splitting (Q1, §i).

**Assertions I measured as false or out of date**
- Survey: "`/settings/deleted` is the home for deleted customers and suppliers." **False**, see item 7.
- Survey: stocktake adjustments are an `inventory_movements` child. **False**: they are linked only by a `notes = 'stocktake CODE'` text, with no foreign key.
- Survey: "the work-order history shows who". **False**: it never selects `changed_by`.
- Survey: `data.view_deleted` holders. The two survey agents disagreed. **Measured:** admin, auditor, cco, cfo, cto, finance (`role_permissions`, as `postgres`).
- Survey: "3 reversed runs". **Measured 4** (`processing_runs.status = 'reversed'`).
- AT-1a decision 22. It concerns only `/settings/change-history`; the three record pages have no translated text in the trail section (§e).

**Measured true:** the three SHAs · 7 accounts, 0 disabled · the old batch trail has 292 rows over 44 batches, 18 kinds live · `approval_log` has no `warehouse_request`, `receipt_price_request` or `terms_request` rows.

---

## a. Registry: every subject (root · members · host)

Unless marked, a member is linked by `member.fk = parent.id`. **Only** pages are the only page that record has.

| subject | host route · file | view code (page guard) | root | members (parent · fk) |
|---|---|---|---|---|
| `quote` | `/sales/quotes/[id]` · `app/sales/quotes/[id]/page.tsx` | module.sales.view | quotes | quote_lines (quote_id; lines are hard-deleted) · qt_issues · quote_history |
| `sales_order` | `/sales/orders/[id]` · `app/sales/orders/[id]/page.tsx` | module.sales.view | sales_orders | sales_order_lines · sales_order_reservations (via lines) · shipping_releases · shipping_release_lines (via releases) · approval_log {subject_type: shipping_release} (via releases) · so_issues · sales_order_history · contract_document_terms (sales_order_id) |
| `shipment` | `/sales/shipments/[id]` · `app/sales/shipments/[id]/page.tsx` | **module.sales.view OR action.ship_goods** (M1) | shipments | shipment_lines · shipment_issues |
| `customer` | `/sales/customers/[id]` · `app/sales/customers/[id]/page.tsx` | module.customers.view | customers | counterparty_contacts (customer_id) · customer_attachments · customer_credit_history · customer_statements · collection_chases · collection_chase_documents (via chases) · collection_promises (via chases). The last four need finance access, otherwise the row reads Restricted |
| `commission_agreement` | `/sales/commissions/[id]/edit` (only) · `…/edit/page.tsx` | module.suppliers.view | commission_agreements | — (0 live rows) |
| `supplier` | `/suppliers/[id]/edit` (only) · `app/suppliers/[id]/edit/page.tsx` | module.suppliers.view | suppliers | supplier_compliance · supplier_attachments · counterparty_contacts (supplier_id) · supplier_status_history · approval_log {subject_type: supplier} |
| `container` | `/logistics/containers/[id]` · `…/page.tsx` | module.logistics.view | containers | container_milestones · container_documents |
| `forwarder` | `/logistics/forwarders/[id]` · `…/page.tsx` | module.logistics.view, but the root rule is suppliers.view (M3) | suppliers | forwarder_details (key supplier_id; leaf) · forwarder_rate_quotes |
| `lane` / `port` | `/logistics/lanes` (list only) · `app/logistics/lanes/page.tsx` | module.logistics.view | lanes / ports | lane_document_requirements (under lane) · lanes under port by origin_port_id **and** destination_port_id (two rows) |
| `company_licence` | `/purchasing/licences` (list only) · `…/page.tsx` | module.suppliers.view (the table's rule; the page guard is purchasing.view) | company_compliance | — |
| `inbound_batch` | `/inbound/[id]/edit` (only) · `app/inbound/[id]/edit/page.tsx` | module.inbound.view | inbound_batches | §b |
| `output_batch` | `/output/[id]/edit` (only) · `app/output/[id]/edit/page.tsx` | module.output.view | output_batches | §b |
| `work_order` | `/operation/orders/[id]` · `…/page.tsx` | module.processing.view | work_orders | work_order_lines · work_order_expected_outputs · work_order_history · approval_log {work_order} |
| `processing_run` (AT-1a, extended) | `/operation/processing/[id]` | module.processing.view | processing_runs | + warehouse_requests (run_id) · approval_log {warehouse_request} (via requests) |
| `stocktake` | `/stocktakes/[id]` · `app/stocktakes/[id]/page.tsx` | module.stocktakes.view | stocktakes | stocktake_lines · stocktake_counts · approval_log {stocktake} · journal_entries {source_type: stocktake} (finance, otherwise Restricted) |
| `storage_location` | `/inventory/locations/[id]/edit` (only) | module.inventory.view | storage_locations | storage_location_allowed_classes |
| `material` | `/materials/[id]/edit` (only) | module.materials.view | materials | material_attachments · material_required_metals (composite key, leaf) |
| `metal_price` | `/tools/pricing/metal-prices/[id]/edit` (only) | action.metal_prices | metal_prices | — |
| `pricing_formula` | `/tools/pricing/formulas/[id]/edit` (only) | module.pricing.view | pricing_formulas | pricing_formula_metals (leaf) · pricing_formula_history · terms_requests (needs price codes, otherwise Restricted) · approval_log {terms_request} (via requests) |
| `task` | `/tools/tasks/[id]` · `…/page.tsx` | module.tasks.view (+ task privacy through the tasks read rule) | tasks | task_nodes · task_participants · task_history |
| `equipment` (new page) | `/operation/equipment/[id]` · new `app/operation/equipment/[id]/page.tsx` | module.processing.view (M3) | fixed_assets | equipment_maintenance · equipment_downtime · equipment_service_intervals · shift_handover_equipment_refs (via downtime) |
| `shift_handover` (new page) | `/operation/handovers/[id]` · new `app/operation/handovers/[id]/page.tsx` | module.processing.view | shift_handovers | shift_handover_items · shift_handover_equipment_refs |
| `processing_settings` / `pricing_settings` / `receiving_settings` | under WoThresholdPanel (`/operation/orders`), ThresholdPanel (`/tools/pricing/metal-prices`), ReceivingThresholdPanel (`/purchasing/discrepancies`) | processing.view / pricing.view / **inbound.view** (the receiving panel's own branch) | the singleton row (M5) | — ; only the columns each panel edits (M6) |
| warehouse requests | on their subject's page (batch, run; COD void via certificates_of_destruction → requests) + a block on `/inventory` | — | members, not a subject | + list block (Q12) |

**Not rolled up, deliberately** (each has its own page or belongs to a later part): shipments and invoices on the sales order; runs on the work order; contracts on customers and suppliers; freight documents on containers; the run's own edits on the batch (only the events that touch the batch, §b).

**Existing history sections replaced (Q26):**
- quote history: `quotes/[id]/page.tsx:257-268`;
- sales-order history: `orders/[id]/page.tsx:268-290`. Its query stays, narrowed, because it also feeds "amended since issued" (`:86-91`) and the "From quote" link (`:97-102`);
- work-order history: `operation/orders/[id]/page.tsx:276-291`;
- task change history: `tasks/[id]/page.tsx:248-258`;
- the batch Audit Trail on both edit pages.

**Pre-log merge (Q1):** every subject's history table and lifecycle stamps are listed. Where two sources record the same event, I keep one:
- `quote_history` over `qt_issues`;
- `sales_order_history` over `so_issues` and the order and reservation stamps;
- `work_order_history` over the closed and cancelled stamps;
- `pricing_formula_history` over the formula create and delete;
- `approval_log` over the `decided_at` stamps.

Where one transaction writes both (supplier status history + approval_log; work-order create + history; release + approval), the renderer folds them into one entry.

---

## b. The batch trail: 20 kinds → unified trail

**Members for `inbound_batch`:**
- inbound_batch_metals, assay_results → assay_result_metals, inbound_batch_safety_states;
- price_history, receipt_price_requests → approval_log, prepayment_applications, pricing_term_commitments (+ _metals);
- inventory_movements, stocktake_lines, stocktake_counts;
- processing_inputs, batch_processing_cost_allocations;
- certificates_of_destruction → cod_issues, and → warehouse_requests (COD void);
- warehouse_requests → approval_log;
- freight_allocations, payment_allocations, finance_attachments;
- journal_entries by source_id (purchase, writeoff) and via prepayment_applications, plus reversals (journal → its reversing journal).

**Members for `output_batch`:** metals, assays, safety states, movements, processing_outputs, processing_inputs, stocktake lines and counts, warehouse requests, sales_records → sales_record_movements / sales_attribution_log / invoice_lines / payment_allocations / journals (sale, shipment), sales_order_reservations, shipment_lines, traceability_report_issues, sales_settlements, and write-off journals.

| old kind (live rows) | unified source | kept? |
|---|---|---|
| receipt (24) · output_created (20) | root insert / pre-log created | yes |
| movement (107) | inventory_movements | yes |
| price_change (14) | price_history | yes (and fixes the wrong-code sentence: masking is `data.view_purchase_prices`) |
| run_input (14) · run_output (17) | processing_inputs / _outputs | yes. Run number through references. "Run later rolled back" needs the via hop (M4) |
| cost_allocation (1) | batch_processing_cost_allocations | yes |
| **cost_entry_change (7)** | processing_cost_entry_history **via the run** | **only with M4** |
| sale (9) · sale_movement (9) · attribution (1) | sales_records and grandchildren | yes |
| reservation (3) · shipment (1) | reservations / shipment_lines | yes |
| stocktake_line (4) | stocktake_lines + **stocktake_counts** (new; 0 live rows yet) | yes, plus the pre-post counts |
| report_issued (1) | traceability_report_issues | yes |
| **approval (11: PO 10, WO 1)** | approval_log **via the PO / work order** | **only with M4** |
| **work_order_change (2)** · po_change (0) · so_change (0) | history tables **via the WO / PO / SO line** | **only with M4** |
| journal_entry (47: purchase 10, sale 9, writeoff 3 kept directly; **processing_cost 19, allocation 5, stocktake 1 via the run or stocktake**) | journal_entries | 22 direct; **25 only with M4** |

**Added kinds (Q33):**
- assays and assay metals;
- metal content (batch metals);
- safety states;
- requests: receipt price, warehouse;
- COD issues and certificates;
- pre-post stocktake counts (`stocktake_counts`);
- prepayments, freight and payment allocations, attachments, commitments.

**How nothing is lost:** a new fixture reads the old view and the new reader for the same batches and asserts that every old row's source row appears in the new trail (the "port 181–183 intents" arm, plus this one). The live verification repeats it read-only on one existing batch.

**The 11 warnings:**
- **Become native:** actor_unrecorded / actor_unresolvable → "Not recorded" / "Removed account". has_masked_amount / amount_restricted → a Restricted value. no_policy_admits → a Restricted row. reversed / is_reversal → the reversal's own entry.
- **Dropped:** polymorphic_source, which describes how rows were found, not the batch.
- **Kept as a note line inside the entry:** no_purchase_order ("Not received against a purchase order"), no_cogs_entry ("No cost-of-sales journal"), run_voided ("This processing was later rolled back"). → Q5.

**Fixtures 181–183, ported:**
- 181: a reversal is reached structurally, never by the memo.
- 182: no-PO, rolled-back run and indirect-link notes.
- 183: A, B, D, E, F map directly (row_hidden = no values; refusal raises). **183C, "name the missing permission", has no equivalent** → Q6.

**Old-trail defects that the replacement fixes:**
- 39 dead `/processing/{id}` links (the new links come from `document_types`);
- output write-off journals never joined (0 live rows today);
- `no_policy_admits` out of date for work-order approvals;
- possible duplicate rows for multi-input runs.

**Views** `batch_audit_trail` / `_all` stay, unused (Q32). The `check-i18n` entry that reads their kinds stays until they are dropped.

---

## c. Equipment and handover pages

**`/operation/equipment/[id]`** → `app/operation/equipment/[id]/page.tsx`, `requireModule(MOD.processing)`, `notFound()` when missing.

Content (read-only), from sources a processing reader can already read:
- **header:** code, description, status, acquisition and in-service dates, run count and kg totals (`equipment_usage`);
- **service intervals and due state** (`equipment_service_status`);
- **servicing:** date, kind, description, performer, capitalised yes/no; no amounts;
- **downtime:** start, end, duration, reason, notes;
- **recent runs** (`processing_runs_masked`);
- **a cross-link** to `/finance/assets/[id]` for finance holders;
- **the trail.**

It must **not** read `equipment_maintenance_advice`, which exposes asset cost and work cost to processing readers today. That is registered as a known issue (Q14).

Entry points (hand-checked):
- ① the two reminder links in `lib/reminders.ts:199-203`, which today send processing users to `/finance/assets/[id]`, a page they cannot open;
- ② downtime references on the handover page;
- ③ an equipment cell on the run page (0 of 14 runs have equipment set, AT0-RUN-EQUIPMENT-NOT-PASSED);
- ④ a list page → Q10.

**`/operation/handovers/[id]`** → `app/operation/handovers/[id]/page.tsx`, `requireModule(MOD.processing)`.

Content:
- date and shift;
- outgoing and incoming person (`handover_people`, readable without HR);
- the acknowledgement state; the Acknowledge button visible behind `PermissionGate` (`action.processing_aftercare`);
- notes;
- items grouped by type (localised type names);
- referenced downtime with the machine and a link to the equipment page;
- the trail.

Entry points: the date cell in `HandoversTable.tsx` becomes a link, and after submit the form lands on the new record instead of the list. Live: 0 handovers, so it is verified inside the rolled-back proof.

Navigation: no new top-level item. Handovers already sit under Operation; equipment is Q10.

---

## d. Q21 pages

| record | today | change | banner (English, `DD/MM/YYYY`) | who may open |
|---|---|---|---|---|
| reversed run (4) | `.is('deleted_at', null)` → 404 (`processing/[id]/page.tsx:104,132`); the list hides it; change-history links 404 | drop the filter; the run's existing read-only branches (`:510`) become reachable | "Reversed on 10/08/2026 by Tim" + "Reason: …" (`deleted_at`, `deleted_by`, `delete_reason`) | normal readers (processing.view) |
| written-off batch (9 + 6) | `/edit` filters `deleted_at` → 404 (inbound `:137-141,181`; output `:91-95,178`) | load it; every form is disabled with the banner as the reason (`<fieldset disabled>`, the DBLOCK pattern) | "Written off on … by …" + reason | normal readers (inbound.view / output.view) |
| deleted customer (4) · supplier (8) · material (4) · formula (0) | filtered → 404 | load for `data.view_deleted` holders; everyone else gets a named refusal, not a 404 | "Deleted on …", plus "by <name>" when known (from the change log; these tables have no `deleted_by`) | data.view_deleted |

Entry to deleted master data: `/settings/deleted` → Q9. Banner language → Q8.

---

## e. The three fold-ins

1. **Actor names → "Restricted"** follows the ActorName rule (`app/components/ActorName.tsx:63,158-163`): a name is shown only to readers with `module.hr.view`, or when it is the reader's own person.
   - Lands in `trail_actor` (one change, both readers: page trails and the summary page).
   - "System (automatic)", "Removed account" and "Not recorded" are not names and stay visible.
   - **Measured effect:** only the `warehouse` role (and the unused `procurement` / `sales` roles) lacks hr.view. The summary page's readers (admin, cfo) both hold it, so the summary page does not change today.
   - It also covers the Q21 banner's "by <name>".
2. **Paging.** AT-1a decision 21 was the **summary page's** "25 operations per page, Newest / Older" (`change-history/page.tsx:36,228-237`). The record pages already show 20 then "Show older entries".
   - The change: the summary page shows 20 operations, then "Show older entries", which extends the list (20 → 40 → …, the same cap of 500 as page trails).
   - "Newest" and "Older" go away. The filters are kept in the link.
3. **What decision 22 meant.** It meant **the summary page's** own text: its title, intro, mask note, filter labels, empty states, paging note and paging links go through `t()`, so they turn Chinese.
   - **The three record pages' trail sections have no translated text** (`AuditTrail.tsx` / `AuditTrailList.tsx` import no i18n; `Refusal` and `Button` have no default text).
   - The one literal that is not in the catalogue is the screen-reader "changed to" (`AuditTrailList.tsx:66`); it moves into the catalogue.
   - The change on the summary page: everything inside the trail section (column row, entries, empty states, paging note, "Show older entries") becomes English. The page title, intro and filter panel stay bilingual as page chrome → Q7.

---

## f. New wordings and labels

- **Event wordings.**
  - The AT-0 catalogue lists **141** events for these areas: B receiving/processing/stock 41, C stocktake 6, D sales 48, E logistics 14, H suppliers/customers/licences 14, J tasks 18.
  - A crude count gives about 53 of them marked NEW; the rest reuse an existing state word turned into a sentence.
  - Add about **35–45** for subjects the catalogue has no section for: equipment servicing and downtime, handovers, storage locations, materials, metal prices, thresholds, warehouse requests, COD, the three batch notes, and the Q21 banners.
  - **Estimate: 175–190 new keys** in `lib/trail/text.ts` (AT-1a: 117).
  - Every one is listed in the build handback for review.
- **Field labels.**
  - About **333** columns for the commercial subjects, **241** for production, and about **120** for batch-only tables: roughly **690–700**.
  - All already have a generated label (the catalogue covers all 238 tables), but none of these tables has a hand-checked override. The build hand-checks every one, as AT-1a did for 197.
  - **Generated labels found wrong** (fixed in the build):
    - counterparty_contacts.name = "File"
    - task_nodes / task_participants.task_id = "Make this a team task"
    - metal_prices.source = "Choose a source"
    - warehouse_requests.cod_id = "Codes"
    - containers.code and container_number both "Container number"
    - commission_agreements.valid_to = "Valid"
    - shipment_lines.location_id = "Unspecified location"
    - customer_statements.base_currency = "By currency"
    - "Wo input overrun %", "Notes en"
    - Title Case on the customer, supplier and compliance tables
- **Enums with no English yet** (the wording check will require them): quotes / sales_orders / suppliers / stocktakes status, `*_lines.price_source`, suppliers.counterparty_type / tax_residence, container_documents.status / document_type, lane_document_requirements.document_type, counterparty_contacts.role, attachments doc_category / file_type, supplier_status_history from/to, work_order_expected_outputs.basis, pricing_formulas.price_basis, pricing_formula_history.change_type. Existing but reading as button text or fragments: warehouse_requests.kind ("Request write-off" for both kinds), terms_requests.status ("waiting").
- **Ambiguous wordings to settle by the old value or the writer:**
  - a supplier status move with or without an approval row;
  - a stocktake "posted" before or after 22/09 (stamp versus approval);
  - material required metals written as delete-all + insert in one transaction (read as "changed", netted);
  - storage-location classes rewritten in three separate transactions (Q13);
  - a container "detached" milestone whose note is machine text (`'detached SHP-…: reason'`, rendered as "Detached from shipment SHP-…").

---

## g. Conflicts with Q1–Q43 or with how AT-1a built the mechanism

| # | conflict | where | proposed resolution |
|---|---|---|---|
| M1 | One view code per subject; the shipment page accepts `sales.view OR ship_goods` | `record_trail.sql:66` | `trail_subjects` gains an "any of" list, the same shape as the page guard |
| M2 | Pre-log actor columns are assumed to be login accounts; the task tables store **employee** ids, which would all read "Removed account" | `record_trail.sql:136` | `trail_prelog_sources` gains an actor-kind column (account / employee) |
| M3 | The root row must pass its own table's read rule. Equipment (fixed_assets = finance only) and forwarder (suppliers = suppliers.view) fail for their page's readers | `record_trail.sql:71` | a per-subject setting: the page's view code admits the page, and the root row's own events are then shown or Restricted like any child row (Q4) |
| M4 | Members only walk downward; 45 / 292 old batch rows need an upward hop | `trail_subject_members` | a "via" member: a stepping-stone table that is not shown itself, whose events are limited to those that touch this batch (§b) → Q4 |
| M5 | Boolean singleton keys never match the log (`{"id":"true"}` versus `{"id":true}`); the trail comes back empty with no error | `record_trail.sql:26,69,143` | build the root key from the typed row image; plus a fixture arm |
| M6 | No per-subject column filter; a threshold panel's trail would show other panels' columns (Q25's rule) | — | subjects may declare their columns |
| — | A table shared by two subjects (processing_inputs belongs to both run and batch); the renderer picks wording by table name alone | `render.ts:765-771`, `check-trail-wording.mjs:65-75` | wording is chosen per subject + table (code only; no question) |
| — | Pre-log "never twice" relies on the change log only; history-table versus stamp duplicates must be avoided by registering one source | §9.6 step 3 | settled per subject in §a; the stocktake `posted` stamp is the one exception, because posts before 22/09 have no other record, and the renderer folds it with the approval row → Q11 |
| — | Personal tasks: the task page deliberately shows no history for personal tasks, but a trail would | `tasks/[id]/page.tsx:87-89` | → Q3 |
| — | Warehouse requests can be read only with finance access (the table's rule), while `/inventory` shows them to inventory readers through a definer function; the trail would show every request as Restricted to warehouse staff | `warehouse_requests.sql:123` | → Q12 |

---

## h. Migration and broken window

**One migration, functions and policies only, no table lock.**

**Functions changed:**
- `trail_subjects` (+ view-code list, root rule, columns);
- `trail_subject_members` (+ via members);
- `trail_prelog_sources` (+ actor kind);
- `record_trail` (M1–M6);
- `trail_actor` (fold-in 1);
- `change_log_rows` (paging for fold-in 2, if the keyset needs a count; otherwise unchanged);
- `deleted_records` (Q9);
- `change_log_mask_rules` (only if Q12 masks `amount_base`).

**Policies changed (Q12 only):** the `warehouse_requests` read rule, plus approval_log's `warehouse_request` branch, plus the three-part mask change on `amount_base`.

- Signatures stay compatible (defaulted additions), so the preflight's overload check is not triggered.
- No index. No table is added, so no new change-log binding is needed.

**Broken window, from commit to your deploy reading:**
- **During it:** the old app keeps working. It calls `record_trail` for the three AT-1a subjects with the same arguments, the old batch views are untouched, and `change_log_rows`' old parameters are all still accepted.
- **The one visible difference:** if fold-in 1 is on, the warehouse account sees "Restricted" in place of names on the three AT-1a trails before the new app lands. That is the intended end state, arriving early.
- **Nothing breaks.**

---

## i. Time estimate: two numbers, calibrated on AT-1a

**AT-1a measured** (transcript `fb669b61…`, SGT): start 11:08 → dry run 12:14 → backup (one `EXIT=124` at the cap, rerun) → apply 13:30:45 → types / build 13:33–13:38 (both retried) → layout survey 14:07–14:21 → smoke #1 15:12 (red) → fix → smoke #2 green → live proof 18:51 → commit 18:55.
- **Total: 7 h 47 m** for the mechanism, 3 subjects, the summary page and the date change.
- **Of that, verification-and-retry: about 2.5–3 h** (backup about 27 min + one timeout; gate 611 s; two smokes of about 35 min each; two survey widths; dry run 185 s; proof).
- **Work: about 4.75–5.25 h.**

| | AT-1b |
|---|---|
| **Process floor per migration cut** | **2.5–3.5 h** (AT-1a actual about 2.5–3 h with its retries; the smoke gains about 20 trail pages; the layout survey grows from 4 to about 24 pages at 2 widths, about +40 min) |
| **Work** | **20–26 h**, broken down below |

Work breakdown:
- mechanism M1–M6 + fold-ins: 3–4 h;
- 25 subjects × registry / wording / labels / fixture arm at about 25–35 min each: 11–14 h;
- the batch trail + ported fixtures + nothing-lost arm: 2.5–3 h;
- two new pages: 1.5–2 h;
- Q21 on 7 kinds: 1.5–2 h;
- the `/inventory` block and list-page trails: 1 h.

**One session cannot hold it** (AT-1a: about 5 h of work in 7 h 47 m) → Q1.

---

## Open questions: all of them, each with my recommendation

❓ **Q1 — Split AT-1b?** The work is 20–26 h, 4–5× AT-1a's.
➡️ **Split into three cuts, each with its own migration and floor, all inside v1.4.33:**
- **1b-1:** mechanism M1–M6, the three fold-ins, the batch trail, runs (Q21 + warehouse requests), work orders, stocktakes, equipment, handovers, the `/inventory` block (about 9–11 h work);
- **1b-2:** quotes, sales orders, shipments, customers, commissions, suppliers, containers, forwarders, lanes / ports, licences (about 6–8 h);
- **1b-3:** materials, locations, metal prices, formulas + terms requests, tasks, the three threshold panels, and the Q21 master-data pages + `/settings/deleted` (about 5–7 h).

Total: 20–26 h work + 3 × (2.5–3.5) h floor.

❓ **Q2 — Where does the trail go on records whose only page is `/edit`?** This covers batches, suppliers, materials, metal prices, formulas, locations and commissions.
➡️ **At the bottom of the `/edit` page.** No new detail pages beyond Q22 and Q23.

❓ **Q3 — Personal tasks.** Today their page deliberately shows no change history, but the change log records their edits.
➡️ **Show the trail on personal tasks too.** Only readers who can already open the task see it (the owner, or `tasks.view_all`), and masking already applies task privacy.

❓ **Q4 — Upward hops for the batch trail (M4).** Without them, 45 of 292 existing rows disappear: 25 run / stocktake journals, 11 PO / WO approvals, 7 cost-entry changes, 2 work-order changes.
➡️ **Add "via" members, limited to events that touch this batch.**
- Keep: the run's cost entries and journals when the run consumed or produced this batch; the PO's approvals and amendments for the PO this batch was received against; the WO's history for runs that used this batch.
- Not the run's or PO's other edits.
- This is the only way to keep your "nothing lost" ruling.

❓ **Q5 — The batch trail's state warnings.** "No purchase order", "no cost-of-sales journal" and "run later rolled back" describe a state, not an event.
➡️ **A grey note line inside the entry they belong to** (under "Goods received", "Sold", "Used in processing …"). Drop "reached through an indirect link" (it describes how rows were found, not the batch).

❓ **Q6 — Fixture 183C: the old trail named the permission a restricted row needs.** The new trail shows only "Restricted" (your Q4).
➡️ **Accept "Restricted" without naming the permission**, consistent with every other trail. The permission is still named on the page's own refusal.

❓ **Q7 — Fold-in 3 on the summary page.** Which text becomes English?
➡️ **Everything inside the trail section is English:** column row, entries, empty states, the paging note and "Show older entries". The page title, intro and filter panel stay bilingual as page chrome, like every other page's title. The three record pages need no change beyond the screen-reader "changed to".

❓ **Q8 — Q21 banner wording and language, when the person is unknown.** Customers, suppliers, materials and metal prices never recorded a deleter; deletions before 28/09 have no log.
➡️ Wording:
- "Reversed on DD/MM/YYYY by <name>" / "Written off on DD/MM/YYYY by <name>" / "Deleted on DD/MM/YYYY by <name>", with "Reason: …" when one exists.
- The name follows fold-in 1.
- **When the person is unknown: "Deleted on DD/MM/YYYY"**, with no "by" and no guess from `updated_by`.
- **English only**, like the trail.

❓ **Q9 — The way in to deleted master data.** `/settings/deleted` lists 7 kinds, and its sales-order and quote links 404.
➡️ **Add customers, suppliers, materials and formulas to `/settings/deleted` with links**, and make deleted sales orders and quotes open read-only with the banner (for `data.view_deleted`). Deleted POs (an AT-1a page) get the same treatment in this part, since their link 404s too.

❓ **Q10 — An equipment list?** The brief asks only for `/operation/equipment/[id]`. Its entry points are reminders, handover downtime and the run page (0 of 14 runs have equipment).
➡️ **Add a small read-only `/operation/equipment` list** under Operation (processing access). Point the two reminder links there, and cross-link to and from `/finance/assets/[id]`.

❓ **Q11 — Stocktake "posted" before 22/09 has no record except the stamp**, which breaks the "don't register a stamp a history already records" rule.
➡️ **Register the stamp.** The renderer folds it with the approval row when both exist (same transaction).

❓ **Q12 — Warehouse requests are readable only with finance access, but `/inventory` shows them to warehouse staff.**
➡️ **Align the table's read rule with what `/inventory` already shows** (the `warehouse_requests_visible()` predicate), and mask `amount_base` behind `data.view_prices` (column grant + masked view + mask rule, one migration). The `/inventory` block then lists the recent request events through the same reader.
Alternative: leave the rule, and warehouse staff see every request as Restricted.

❓ **Q13 — Storage-location classes are rewritten as three separate saves**, and unchanged classes read as "removed" and "added".
➡️ **Fix the writer to change only what changed, in one call.**

❓ **Q14 — `equipment_maintenance_advice` shows asset cost and work cost to processing readers today.**
➡️ **Register it in `docs/known-issues.md`; the new page does not read it.** Fixing the view is a separate decision.

---

**Stopped at the gate.** I'm waiting on your answers to Q1–Q14 before any edit or migration.

---

## Tim's answers, 2026-09-29: all Q1–Q14 accepted as recommended; split into 1b-1, 1b-2, 1b-3 inside v1.4.33.

Every recommendation Q1–Q14 is accepted exactly as stated, as are the scope changes (points 1–10 of §1) and the six
mechanism extensions M1–M6. AT-1b is split into three cuts, all inside v1.4.33, in the order 1b-1 → 1b-2 → 1b-3:

- **1b-1:** M1–M6 (all six built now, so later cuts only add registry entries), the three fold-ins, inbound and output
  batches, runs with warehouse requests, work orders, stocktakes, equipment (list + page), handovers, the `/inventory`
  warehouse-request block, and Q21 for written-off batches and reversed runs.
- **1b-2:** quotes, sales orders, shipments, customers, commissions, suppliers, containers, forwarders, lanes and ports,
  licences.
- **1b-3:** materials, locations (including the Q13 save change), metal prices, formulas and terms requests, tasks (Q3),
  the three threshold panels, deleted master data and `/settings/deleted` (Q9).
