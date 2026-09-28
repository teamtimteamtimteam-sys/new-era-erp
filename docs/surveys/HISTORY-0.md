# HISTORY-0 — history and audit-trail survey (2026-09-28)

Read-only survey. No database change and no code change was made. Every live query ran inside
`BEGIN READ ONLY … ROLLBACK` over direct psql to the pooler, **as `postgres` (`rolbypassrls = true`, `rolsuper = false`)**,
so row counts on base tables are true counts, not what a signed-in reader would see. The query shapes are in §M at the end.

Each finding is marked **Measured** (a query, grep or file read produced it; the source is named) or **Inferred**
(reasoned from measured facts; not observed directly).

Starting point: `HEAD` = `origin/main` = `git ls-remote origin main` = `12bb0d174983956bd3f13d63c06bbf748d4b59ab`.

---

## 0. Summary

* **17 tables record change history, not 16.** The count 16 comes from AUDIT-1 (`docs/batch-audit-trail.md`, 2026-09-01),
  which counted a different set (it included business ledgers such as `inventory_movements` and `sales_records`, and has
  18 rows in its own table). Under the definition used here there are 17 (§A.1). Four of the 17 postdate AUDIT-1.
* **All 17 record an actor.** The claim "most do not record the actor" does not hold. What differs is the actor's
  **identity space** (16 store an auth account id, `task_history` stores an employee id) and whether the id **still
  resolves**: 18 of the 85 auth-id actor values (9 distinct accounts) point at auth accounts that no longer exist (§C).
* **Before values are uneven.** 13 tables store a before value for at least some columns (paired `old_`/`new_`, `prev_rate`,
  or `from_`/`to_`); 3 store only an event or an after-state (`quote_history`, `employee_account_history`,
  `sales_attribution_log`); `approval_log` stores a decision, which has no "before" (§A.2).
* **Across all 241 public base tables:** 47 traced, 141 partly traced, 35 untraced, 18 have no writer outside migrations
  (§B). **All 35 untraced tables can be changed through the app.**
* **`set_role_permissions` loses the previous code list: confirmed.** It is one of **15** functions that delete a set
  of child rows and re-insert them. **69** tables accept an authenticated `DELETE` with no delete guard (§D).
* **Recommendation (§F): one generic append-only change log, filled by one trigger function on every base table, kept
  alongside the existing 17 tables.** The existing readers keep working unchanged, and the migration opens no broken window.
  `fixed_asset_history` already uses this diff mechanism for one table.

---

## A. The history tables

### A.1 Definition and count

**Definition:** a public base table whose purpose is to record a change, decision or event about rows of *another*
table, written as a side effect of that change.

**Enumeration, two independent paths (Measured, `pg_class`/`pg_attribute`/`pg_trigger`):**

1. By name: `relname ~ '(hist|log|audit|event|change|trail|revision|version|journal|snapshot|timeline|activity|trace)'`
   → 24 tables. Of these, 7 are not history in the sense above: `journal_entries` and `journal_lines` (the ledger itself),
   `journal_requests` and `salary_change_requests` (request workflows),
   `payment_trigger_events` and `payment_event_owners` (dictionaries), and `traceability_report_issues` (an issuance register).
2. By structure: tables with `old_*`/`prev_*`/`from_*` columns or `changed_at`/`changed_by` → 19. The three outside the name set are `bank_transfers`, `container_documents` and `receipt_price_requests` (a `from_`/`old_` column on a
   business row, not a history). Triggers whose function inserts into another table → 18 trigger bindings, all landing
   in tables already found, plus `inventory_movements` (a ledger).

**Both paths converge on the same 17.** Adjacent tables that record events but are the business record itself, and so are
not counted: `inventory_movements`, `sales_record_movements`, `journal_entries`/`journal_lines`, the `*_issues` document
registers (`cn_issues`, `cod_issues`, `qt_issues`, `so_issues`, `shipment_issues`, `statement_issues`, `invoice_issues`,
`po_issues`, `traceability_report_issues`), and the request tables (`*_requests`, `shipping_releases`, `warehouse_requests`,
`terms_requests`, `asset_disposal_requests`).

**Since AUDIT-1 (2026-09-01):** `employee_account_history`, `finance_settings_history`, `fixed_asset_history`
and `supplier_status_history` were added. The other 13 all appear in AUDIT-1's table (`docs/batch-audit-trail.md` §二).

### A.2 Per table — what, actor, before value, time, writer, reader

Row counts: `SELECT count(*)` per table, as `postgres`. The actor column is always a bare `uuid` with **no foreign key**,
except `task_history.changed_by → employees(id)`.

| Table | Rows | Records | Source table(s) | Actor column → space | Before / after | Timestamp | Writer (DB) | App / DB readers |
|---|--:|---|---|---|---|---|---|---|
| `approval_log` | 15 | An approval decision on a subject (`decision`, `level`, `note`, amount, FX) | 13 subject types, polymorphic `subject_type`/`subject_id` | `actor_user_id` → auth account | neither (decision record); `seq bigint` orders rows | `decided_at` / `created_at` DEFAULT `now()` | `record_approval_decision` (SD) | `self_approved_decisions`, `batch_audit_trail_all`; readers in `app/me`, `app/finance/self-approved`, `app/purchasing/orders/[id]` go through those functions (grep: no direct `.from('approval_log')` outside comments) |
| `customer_credit_history` | 1 | Credit limit / hold change | `customers` (2 of 17 columns) | `changed_by` → auth account | both (paired) | `changed_at` DEFAULT `now()` | trigger `log_customer_credit_change` (SD) | **no reader** (listed only in `UNREACHABLE_HISTORY_TABLES`, `app/components/audit/auditTrailTypes.ts:77`) |
| `employee_account_history` | 1 | Link / unlink of an extra login account to an employee | `employee_accounts` | `actor_user_id` → auth account | event (`action`); the row is the fact; `seq` orders rows | `changed_at` DEFAULT `now()` | `link_additional_account`, `unlink_additional_account` (SD) | **no reader** |
| `employment_history` | 3 | Position, status and salary events | `employees` (1 of 35 columns paired: salary; others as snapshot of the new state) | `created_by` → auth account (DEFAULT `auth.uid()`) | salary: both; other fields: after only | `created_at` DEFAULT `now()` | `approve_review`, `salary_change_execute_internal`, `set_initial_salary` (SD); direct app insert `app/hr/employees/actions.ts:251,340` under an INSERT policy | `app/hr/employees/[id]/page.tsx:64`, `app/me/page.tsx:144`, `export_my_personal_data`, `employee_work_category_at`, `employment_history_masked` |
| `finance_settings_history` | 1 | Approval-policy change | `finance_settings` (**4 of 13 columns**) | `changed_by` → auth account | both (paired) | `changed_at` DEFAULT `now()` | `set_approvals_policy` (SD) | `app/settings/approvals/page.tsx:79` |
| `fixed_asset_history` | 2 | Any column change (generic diff) | `fixed_assets` (all columns) | `changed_by` → auth account, plus `changed_by_kind` (`user` / `no_session`) | both, all columns, `changed_columns text[]` | `changed_at` = `now()` passed by trigger | trigger `trg_fixed_assets_history` (SD), jsonb diff + `jsonb_populate_record` | `app/finance/assets/[id]/page.tsx:234–242` |
| `fx_rate_history` | 0 | Rate recorded / withdrawn | `fx_rates` | `changed_by` → auth account (DEFAULT `auth.uid()`) | snapshot + `prev_rate` | `changed_at` DEFAULT `now()` | `record_fx_rate`, `withdraw_fx_rate` (SD) | **no reader** (comment only in `EditFxRateForm.tsx:69`) |
| `price_history` | 14 | Unit-price change on a receipt | `inbound_batches` (1 of 29 columns) | `created_by` → auth account (DEFAULT `auth.uid()`) | both | `created_at` DEFAULT `now()` | `reprice_inbound_batch` (SD) | `app/inbound/[id]/edit/page.tsx:175,543`, `app/inbound/[id]/assays/[assayId]/page.tsx:118,128`, `inbound_unit_price_asof`, `batch_margin`, `batch_audit_trail_all`, `price_history_masked` |
| `pricing_formula_history` | 0 | Formula / formula-metal change | `pricing_formulas` (7 of 13), `pricing_formula_metals` | `changed_by` → auth account | both (paired) | `changed_at` DEFAULT `now()` | triggers `log_pricing_formula_change`, `log_pricing_formula_metal_change` (SD) | `pricing_formula_history_masked`; no screen (`registry.ts:88` reads only its `metal` column for a delete check) |
| `processing_cost_entry_history` | 7 | Cost-entry amount / type / estimate change | `processing_cost_entries` (3 of 10) | `changed_by` → auth account | both (paired) | `changed_at` DEFAULT `now()` | trigger `log_cost_entry_change` (SD) | `processing_cost_entry_history_masked`, `batch_audit_trail_all`; no screen |
| `purchase_order_history` | 10 | Header / line / payment-term amendment, cancel | `purchase_orders` (8 of 25), `purchase_order_lines` (6 of 18), `purchase_order_payment_terms` | `changed_by` → auth account (DEFAULT `auth.uid()`) | both (paired) + `amend_reason` | `changed_at` DEFAULT `now()` | triggers `trg_po_history_header/line/payment_term`, `cancel_purchase_order` (SD) | `app/purchasing/orders/[id]/page.tsx:130,199`, `batch_audit_trail_all` |
| `quote_history` | 6 | Lifecycle event (created, issued, converted, declined) | `quotes` (0 of 14 paired) | `changed_by` → auth account (DEFAULT `auth.uid()`) | neither (event + free-text `detail`) | `changed_at` DEFAULT `now()` | `trg_quote_history_created`, `record_qt_issue`, `convert_quote`, `decline_quote` (SD) | `app/sales/quotes/[id]/page.tsx:67,69` |
| `sales_attribution_log` | 1 | A sale attributed to a customer, with exposure after | `sales_records` | `attributed_by` → auth account | after only | `attributed_at` DEFAULT `now()` | `attribute_sale_customer` (SD) | `batch_audit_trail_all` only |
| `sales_order_history` | 22 | Lifecycle events + note / terms / line qty-price amendments | `sales_orders` (2 of 16), `sales_order_lines` (3 of 8) | `changed_by` → auth account (DEFAULT `auth.uid()`) | events: neither; amendments: both | `changed_at` DEFAULT `now()` | 12 functions incl. `ship_order`, `create_order_invoice`, triggers `trg_so_history_header/line` (SD) | `app/sales/orders/[id]/page.tsx:63,67`, `batch_audit_trail_all` |
| `supplier_status_history` | 0 | Supplier status transition | `suppliers` (1 of 21) | `changed_by` → auth account | both (`from_status`/`to_status`) | `changed_at` DEFAULT `now()` | trigger `log_supplier_status_change` (SD) | `operations_now` view; no screen |
| `task_history` | 46 | Task, node and participant changes | `tasks`, `task_nodes`, `task_participants` | `changed_by` → **employee id** (FK `employees`) | both (paired), near-complete | `changed_at` DEFAULT `now()` | triggers `trg_tasks_history`, `trg_task_nodes_history`, `trg_task_participants_history`, `trg_tasks_type_transition`, `ensure_task_owner_participant` (SD) | `app/tools/tasks/[id]/page.tsx:93` |
| `work_order_history` | 2 | Lifecycle events + schedule / note / qty amendments | `work_orders` (2 of 10), `work_order_lines`, `work_order_expected_outputs` | `changed_by` → auth account (DEFAULT `auth.uid()`) | events: neither; amendments: both | `changed_at` DEFAULT `now()` | `create_work_order`, `amend_work_order`, `release_work_order`, `close_work_order`, `cancel_work_order` (SD) | `app/operation/orders/[id]/page.tsx:78,81`, `batch_audit_trail_all` |

"SD" = `SECURITY DEFINER`. All 17 writers are SECURITY DEFINER functions or triggers; only `employment_history` also
accepts a direct app insert. Column-coverage figures ("2 of 17") count source columns other than
`id`/`created_*`/`updated_*` that have an `old_`/`prev_`/`from_` twin in the history table (Measured, `pg_attribute`).
Status columns such as `purchase_orders.status` are not paired, but their transitions are recorded as `change_type`
events.

### A.3 Mutability, access and personal data

**Write access.** All 17 carry table-level `INSERT/UPDATE/DELETE/TRUNCATE` grants to `authenticated` (13 also to `anon`)
— the platform default. RLS is enabled on all 17, and **no policy admits INSERT, UPDATE or DELETE except
`employment_history insert by permission`**. So through PostgREST a user can insert only into `employment_history`, and
cannot update or delete anything (Measured, `information_schema.role_table_grants`, `pg_policy`).

**Append-only guards (Measured, `pg_trigger`):**

| Guard | Tables |
|---|---|
| BEFORE UPDATE/DELETE row trigger that always raises | 14: all except the three below |
| Raises, except one whitelisted anonymisation UPDATE shape | `employment_history` (`reject_employment_history_mutation`) |
| **No guard at all** | **`task_history`**, **`work_order_history`** |
| TRUNCATE guard | **none of the 17** (no statement-level TRUNCATE trigger exists on any of them) |

`pg_stat_user_tables` shows `task_history` with `n_tup_upd = 2` and `n_tup_del = 6` over the statistics lifetime.
These counters include rolled-back transactions, so they do not prove a committed mutation. They do show that
mutating statements reached this unguarded table (Measured counters; cause Inferred to be rolled-back fixtures run
against live, not established).

Every guard is a trigger, and `postgres` (the owner, `rolbypassrls = true`) can `ALTER TABLE … DISABLE TRIGGER` or
set `session_replication_role = replica`. **No history table is immutable for the owner.** It is immutable against
`authenticated`, `anon` and `service_role` for UPDATE and DELETE only (Inferred from catalog facts; not exercised).

**Delete cascades.** No history table's foreign key cascades on delete of its source. Two use `ON DELETE RESTRICT`
(`employment_history → employees`, `fx_rate_history → fx_rates`), and the rest use `NO ACTION`. Deleting a source row that has
history therefore fails, and several source tables also carry no-hard-delete guards (Measured, `pg_constraint`).

**Read access (Measured, `pg_policy` SELECT predicates):** module-view codes (`module.purchasing.view`,
`module.sales.view`, …), `action.manage_permissions` for `employee_account_history` and `finance_settings_history`,
`can_view_task(task_id)` for `task_history`, own rows for `employment_history`, and a `CASE` on `subject_type` for
`approval_log`.

**Masking.** 6 of the 17 are masked (column-list SELECT grant, 28 masked tables in total): `approval_log`,
`employment_history`, `price_history`, `pricing_formula_history`, `processing_cost_entry_history` (and their
`_masked` views). **`purchase_order_history` is not masked, but it holds `old/new_estimated_unit_price`,
`old/new_estimated_amount_ccy` and `old/new_estimated_total_ccy` — the columns `purchase_order_lines_masked` hides
behind `data.view_purchase_prices`.** Today all 9 roles that hold `module.purchasing.view` also hold
`data.view_purchase_prices`, so nobody can currently read more than the masked view shows. The gap is latent: 6 history
rows carry prices, and a future role with purchasing view but no price code would read them (Measured,
`role_permissions`; the read path itself not exercised as a session).

**Personal and restricted data.**

| Table | Holds | `anonymise_employee` reaches it | `export_my_personal_data` reads it |
|---|---|---|---|
| `employment_history` | salary (old/new), job title, notes | **yes** (the whitelisted UPDATE nulls salary and notes) | yes |
| `task_history` | employee ids, free-text titles and descriptions | no | no |
| `employee_account_history` | account ↔ employee links | no | no |
| `approval_log` | amounts, free-text `note` on HR subjects (leave, medical claim, review) | no | no |
| `price_history`, `pricing_formula_history`, `processing_cost_entry_history`, `purchase_order_history`, `sales_order_history`, `fixed_asset_history` | commercial prices / costs (restricted class, not personal) | — | — |

`anonymise_employee` writes only `employees` and `employment_history`, and `export_my_personal_data` reads `employees`,
`employment_history`, `leave_requests`, `medical_claims`, `payroll_lines`, `performance_reviews` and `positions`
(Measured, regex over `pg_get_functiondef`).

### A.4 An existing cross-table reader

`batch_audit_trail_all` (AUDIT-1) already unions seven of the 17 into one batch-centred timeline with named seams
(`actor_unrecorded`, `actor_unresolvable`, `amount_restricted`, …). It is read through `app/components/audit/`
(`auditTrailQuery.ts`, `BatchAuditTrail.tsx`) on `/inbound/[id]/edit` and `/output/[id]/edit`. The six tables with no
path to a batch are named in `UNREACHABLE_HISTORY_TABLES`. Any unified mechanism has to keep this reader working.

---

## B. Global write census (241 public base tables)

### B.1 Method

* Timestamp and actor columns: `pg_attribute` (Measured).
* History coverage: from §A, split into **full** (every user-editable column) and **partial** (Measured column
  coverage, §A.2).
* Write paths, three kinds, each Measured:
  * **fn** — a function whose `pg_get_functiondef` text contains `INSERT INTO / UPDATE / DELETE FROM <table>` and that
    is **reachable from the app**. Reachable means an RPC the app calls (291 names from `.rpc('…')` in `app/ lib/`,
    all 291 resolve to a `public` function), a trigger function, or anything they call transitively (690 of 723
    functions reachable). Two functions write through dynamic SQL: `master_import_apply` (import targets) and
    `set_finance_settings` (`UPDATE finance_settings SET %s`).
  * **app** — a direct `.from('<table>').insert/update/delete/upsert` in `app/` or `lib/` (a scanner over 1,099
    files, comments stripped: 1,042 `.from()` literals; an independent grep without stripping: 1,046 — the difference
    is commented code). Non-literal `.from(<variable>)` exists in `app/settings/dictionaries/actions.ts` (dictionary
    registry) and `app/components/related/related-records.tsx` (read only). The dictionary tables it writes also carry
    authenticated write policies, so the rls column catches them.
  * **rls** — an RLS policy admitting `authenticated` for INSERT (`a`), UPDATE (`w`), DELETE (`d`) or ALL (`*`). With
    the platform-default table grants, such a policy makes the table writable directly through PostgREST.
* **Scheduled jobs: none.** No `cron` schema, no `pg_cron`/`pg_net` extension, no `vercel.json`, no `app/api`, and no
  `.github/workflows` (Measured).
* **Service role:** used in three files only — `app/settings/accounts/accountActions.ts` (`auth.admin.createUser` /
  `deleteUser`, auth schema), `app/verify/cod/[token]/route.ts` (the public CoD verification RPC) and
  `app/me/avatar/route.ts` (storage). Every other public-schema write carries the signed-in user's JWT (Measured, grep).

### B.2 Classification

* **traced** — actor and before value both recoverable: the 17 history tables themselves; 8 tables whose history
  covers every user-editable column; or a table with no UPDATE/DELETE path that carries an actor column (each row is
  its own trace).
* **partly traced** — some but not all: partial history, or an actor column with no before value, or append-only
  with no actor column.
* **untraced** — changeable, with no actor column and no history.
* **seed-only** — no writer found outside migrations (no reachable function, no app write, no write policy). This is
  Inferred from text matching; a writer using a name form the regex does not match would be missed.

| Class | Count | Members |
|---|--:|---|
| traced — history tables | 17 | §A |
| traced — full history | 8 | `employee_accounts` `fixed_assets` `fx_rates` `pricing_formula_metals` `pricing_formulas` `task_nodes` `task_participants` `tasks` |
| traced — append-only with actor | 22 | `bank_reconciliation_variance_items` `cn_issues` `cod_issues` `container_milestones` `contract_document_terms` `credit_notes` `fixed_asset_cost_entries` `fixed_asset_depreciation` `fixed_asset_depreciation_anchors` `import_batches` `inventory_movements` `leave_consumption` `prepayment_applications` `pricing_term_commitments` `qt_issues` `shipment_issues` `so_issues` `statement_issues` `stocktake_counts` `stocktake_lines` `traceability_report_issues` `wht_remittances` |
| partly — history covers some columns | 15 | `customers` `employees` `finance_settings` `inbound_batches` `processing_cost_entries` `purchase_order_lines` `purchase_order_payment_terms` `purchase_orders` `quotes` `sales_order_lines` `sales_orders` `sales_records` `suppliers` `work_order_lines` `work_orders` |
| partly — mutable, `updated_by` (last writer only, no before value) | 64 | see §B.4 |
| partly — mutable, creator / decider only, no before value | 52 | see §B.4 (includes `role_permissions`, `user_roles`, `journal_entries`, all request tables) |
| partly — append-only, no actor column | 10 | `collection_chase_documents` `credit_note_lines` `gst_return_boxes` `journal_lines` `notifications` `payment_allocations` `pricing_term_commitment_metals` `sales_record_movements` `shipment_lines` `shipping_release_lines` |
| **untraced** | **35** | §B.3 |
| seed-only | 18 | `document_relation_exceptions` `document_type_exceptions` `document_types` `kpi_organisation` `kpi_position_templates` `kpi_template_org_links` `list_ledger_residue` `operation_kinds` `output_batch_states` `payment_event_owners` `payment_trigger_events` `permissions` `positions` `sales_settlements` `tax_codes` `tax_rates` `wht_natures` `wht_rates` |
| **Total** | **241** | 47 traced · 141 partly · 35 untraced · 18 seed-only |

Timestamp and actor columns across the 241 (Measured): `created_at` on 160, `updated_at` on 86; `created_by` and
`updated_by` both on 71, `created_by` only on 54, `updated_by` only on 10, neither on 106.

A column coverage figure is not the same as tracing. `finance_settings` is "partly" because `set_finance_settings`
changes `locked_before` (the period lock), `gst_rate_pct`, `gst_registered` and `system_start_date`, and **none of those
four has a before value anywhere**. Only the approval columns reach `finance_settings_history`.

### B.3 Untraced tables that users can change through the app (35 of 35)

| Table | Rows | Write paths |
|---|--:|---|
| `assay_result_metals` | 14 | fn:I(1) rls:adw |
| `bank_statement_lines` | 4 | fn:I/U(5) rls:adw |
| `battery_chemistries` | dict | rls:aw |
| `certificate_types` | dict | rls:aw |
| `cod_verification_failures` | 1 | fn:I/D(1) |
| `currencies` | dict | rls:adw |
| `deep_discharge_judgements` | dict | rls:* |
| `handover_item_types` | dict | rls:* |
| `home_greetings` | 72 | rls:adw |
| `inbound_chemistry_certainties` | dict | rls:aw |
| `inbound_safety_states` | dict | rls:aw |
| `inbound_source_reasons` | dict | rls:aw |
| `invoice_lines` | 9 | fn:I/U(3) |
| `kpi_score_rubric` | dict | rls:adw |
| `laboratories` | dict | rls:aw |
| `loss_categories` | dict | rls:aw |
| `loss_metal_fates` | dict | rls:aw |
| `material_forms` | dict | rls:aw |
| `material_kinds` | dict | rls:aw |
| `material_size_formats` | dict | rls:aw |
| `material_sources` | dict | rls:aw |
| `notification_reads` | — | app:upsert rls:ad |
| `operation_type_input_forms` | dict | rls:* |
| `operation_type_output_forms` | dict | rls:* |
| `operation_type_safety_states` | dict | rls:* |
| `operation_types` | dict | rls:* |
| `output_batch_purposes` | dict | rls:* |
| `payment_term_template_lines` | — | app:delete/insert rls:adw |
| `payroll_lines` | 1 | fn:I/U/D(2) rls:adw |
| `processing_inputs` | 14 | fn:I(1) rls:aw |
| `processing_outputs` | 17 | fn:I/U(2) rls:w |
| `quote_lines` | 3 | app:delete/insert/update rls:adw |
| `shifts` | dict | rls:* |
| `substances` | dict | rls:aw |
| `work_order_expected_outputs` | 1 | fn:I/U/D(2) |

"dict" = a dictionary / reference table; exact row counts are in §B.4. `fn:I/U(5)` means 5 reachable functions insert or
update the table.

### B.4 The full census

Generated from the catalog queries in §M. Columns: row count; ✓/· for `created_at`, `created_by`, `updated_at`,
`updated_by`; other `*_by` columns; history coverage; write paths as defined in §B.1; class.

<!-- BEGIN CENSUS TABLE -->
| Table | Rows | created_at | created_by | updated_at | updated_by | Other actor columns | History coverage | Write paths | Class |
|---|--:|:-:|:-:|:-:|:-:|---|---|---|---|
| `accounts` | 45 | ✓ | ✓ | ✓ | ✓ | — | - | rls:adw | partly |
| `approval_log` | 15 | ✓ | · | · | · | — | (is history) | fn:I(1) | traced |
| `assay_result_metals` | 14 | ✓ | · | · | · | — | - | fn:I(1) rls:adw | **untraced** |
| `assay_results` | 4 | ✓ | ✓ | ✓ | ✓ | applied_by,superseded_by | - | fn:I/U(4) rls:adw | partly |
| `asset_disposal_requests` | 0 | ✓ | ✓ | · | · | decided_by,withdrawn_by | - | fn:I/U(3) | partly |
| `attendance_lines` | 0 | · | · | · | · | recorded_by | - | fn:I/U(4) | partly |
| `attendance_periods` | 0 | · | · | · | · | opened_by,completed_by,reopened_by | - | fn:I/U(3) | partly |
| `bank_import_profiles` | 0 | ✓ | ✓ | ✓ | ✓ | — | - | app:insert/update rls:adw | partly |
| `bank_line_matches` | 1 | ✓ | ✓ | · | · | — | - | fn:I/D(2) rls:adw | partly |
| `bank_reconciliation_variance_items` | 0 | ✓ | ✓ | · | · | — | (append-only, row carries actor) | fn:I(1) | traced |
| `bank_reconciliations` | 0 | ✓ | · | · | · | reconciled_by | - | fn:I/U(2) | partly |
| `bank_statement_lines` | 4 | ✓ | · | · | · | — | - | fn:I/U(5) rls:adw | **untraced** |
| `bank_statements` | 2 | ✓ | ✓ | ✓ | ✓ | reconciled_by | - | fn:I/U(3) app:update rls:adw | partly |
| `bank_transfers` | 0 | ✓ | ✓ | · | · | reversed_by | - | fn:I/U(2) | partly |
| `batch_processing_cost_allocations` | 1 | ✓ | ✓ | · | · | — | - | fn:I/D(1) rls:* | partly |
| `battery_chemistries` | 8 | · | · | · | · | — | - | rls:aw | **untraced** |
| `cash_forecast_lines` | 0 | ✓ | ✓ | ✓ | ✓ | — | - | app:insert/update rls:* | partly |
| `cash_forecasts` | 0 | · | · | · | · | frozen_by,superseded_by | - | fn:I/U(1) | partly |
| `certificate_types` | 9 | · | · | · | · | — | - | rls:aw | **untraced** |
| `certificates_of_destruction` | 3 | ✓ | · | · | · | issued_by,voided_by | - | fn:I/U/D(3) | partly |
| `cn_issues` | 1 | · | · | · | · | issued_by | (append-only, row carries actor) | fn:I(1) | traced |
| `cod_issues` | 2 | · | · | · | · | issued_by | (append-only, row carries actor) | fn:I(1) | traced |
| `cod_verification_failures` | 1 | · | · | · | · | — | - | fn:I/D(1) | **untraced** |
| `collection_chase_documents` | 0 | ✓ | · | · | · | — | - | fn:I(1) | partly |
| `collection_chases` | 0 | ✓ | · | · | · | chased_by,superseded_by | - | fn:I/U(1) | partly |
| `collection_promises` | 0 | ✓ | ✓ | · | · | outcome_recorded_by | - | fn:I/U(2) | partly |
| `commission_agreements` | 0 | ✓ | ✓ | ✓ | ✓ | — | - | app:insert/update rls:* | partly |
| `company_compliance` | 1 | ✓ | ✓ | ✓ | ✓ | — | - | app:insert/update rls:aw | partly |
| `company_profile` | 1 | · | · | ✓ | ✓ | — | - | app:update rls:adw | partly |
| `container_documents` | 1 | ✓ | ✓ | ✓ | ✓ | — | - | fn:I(1) app:insert/update rls:* | partly |
| `container_milestones` | 17 | · | · | · | · | recorded_by | (append-only, row carries actor) | fn:I(1) app:insert rls:a | traced |
| `containers` | 18 | ✓ | ✓ | ✓ | ✓ | deleted_by | - | fn:I(1) app:update rls:* | partly |
| `contract_document_terms` | 0 | · | · | · | · | linked_by | (append-only, row carries actor) | fn:I(1) | traced |
| `contract_grade_specs` | 0 | ✓ | ✓ | ✓ | ✓ | — | - | rls:* | partly |
| `contract_insurance_obligations` | 0 | ✓ | ✓ | ✓ | ✓ | insured_by | - | rls:* | partly |
| `contract_penalty_elements` | 0 | ✓ | ✓ | ✓ | ✓ | — | - | rls:* | partly |
| `contract_pricing_terms` | 0 | ✓ | ✓ | ✓ | ✓ | — | - | rls:* | partly |
| `contract_refining_charges` | 0 | ✓ | ✓ | ✓ | ✓ | — | - | rls:* | partly |
| `contract_settlement_terms` | 0 | ✓ | ✓ | ✓ | ✓ | — | - | rls:* | partly |
| `contract_volume_commitments` | 0 | ✓ | ✓ | ✓ | ✓ | — | - | rls:* | partly |
| `contracts` | 0 | ✓ | ✓ | ✓ | ✓ | — | - | fn:U(1) app:insert/update rls:aw | partly |
| `counterparty_contacts` | 1 | ✓ | ✓ | ✓ | ✓ | — | - | fn:I/U(2) | partly |
| `credit_note_lines` | 1 | ✓ | · | · | · | — | - | fn:I(1) | partly |
| `credit_notes` | 1 | ✓ | ✓ | · | · | — | (append-only, row carries actor) | fn:I(1) | traced |
| `currencies` | 3 | · | · | · | · | — | - | rls:adw | **untraced** |
| `customer_attachments` | 2 | ✓ | ✓ | ✓ | ✓ | — | - | app:insert/update rls:adw | partly |
| `customer_credit_history` | 1 | · | · | · | · | changed_by | (is history) | fn:I(1) | traced |
| `customer_statements` | 0 | ✓ | · | · | · | issued_by,superseded_by | - | fn:I/U(1) | partly |
| `customers` | 7 | ✓ | ✓ | ✓ | ✓ | — | customer_credit_history | fn:U(1) app:insert/update rls:adw | partly |
| `deep_discharge_judgements` | 3 | · | · | · | · | — | - | rls:* | **untraced** |
| `departments` | 1 | ✓ | ✓ | ✓ | ✓ | — | - | app:insert/update rls:adw | partly |
| `document_relation_exceptions` | 6 | · | · | · | · | — | (no app/function/RLS writer found) | none | seed-only |
| `document_type_exceptions` | 36 | · | · | · | · | — | (no app/function/RLS writer found) | none | seed-only |
| `document_types` | 41 | · | · | · | · | — | (no app/function/RLS writer found) | none | seed-only |
| `employee_account_history` | 1 | · | · | · | · | — | (is history) | fn:I(2) | traced |
| `employee_accounts` | 1 | · | · | · | · | linked_by | employee_account_history | fn:I/D(2) | traced |
| `employees` | 22 | ✓ | ✓ | ✓ | ✓ | anonymised_by | employment_history | fn:U(4) app:insert/update rls:adw | partly |
| `employment_history` | 3 | ✓ | ✓ | · | · | — | (is history) | fn:I(3) app:insert rls:a | traced |
| `equipment_downtime` | 1 | ✓ | ✓ | ✓ | ✓ | — | - | app:insert/update rls:aw | partly |
| `equipment_maintenance` | 2 | ✓ | ✓ | ✓ | ✓ | — | - | fn:U(1) app:insert rls:aw | partly |
| `equipment_service_intervals` | 1 | ✓ | ✓ | ✓ | ✓ | — | - | app:delete/insert/update rls:adw | partly |
| `expense_claims` | 4 | ✓ | ✓ | · | · | decided_by | - | fn:I/U(3) | partly |
| `expenses` | 9 | ✓ | ✓ | · | · | — | - | fn:I/U(3) rls:a | partly |
| `festival_doodles` | 23 | ✓ | ✓ | ✓ | ✓ | — | - | rls:adw | partly |
| `finance_attachments` | 4 | ✓ | ✓ | ✓ | ✓ | — | - | app:insert/update rls:adw | partly |
| `finance_settings` | 1 | · | · | ✓ | ✓ | — | finance_settings_history | fn:U(4) app:update rls:adw | partly |
| `finance_settings_history` | 1 | · | · | · | · | changed_by | (is history) | fn:I(1) | traced |
| `fixed_asset_cost_entries` | 1 | ✓ | ✓ | · | · | — | (append-only, row carries actor) | fn:I(1) | traced |
| `fixed_asset_depreciation` | 0 | ✓ | ✓ | · | · | — | (append-only, row carries actor) | fn:I(1) | traced |
| `fixed_asset_depreciation_anchors` | 0 | ✓ | ✓ | · | · | — | (append-only, row carries actor) | fn:I(1) | traced |
| `fixed_asset_history` | 2 | · | · | · | · | changed_by,old_created_by,new_created_by | (is history) | fn:I(1) | traced |
| `fixed_assets` | 2 | ✓ | ✓ | · | · | — | fixed_asset_history | fn:I/U(6) | traced |
| `forwarder_details` | 0 | ✓ | ✓ | ✓ | ✓ | — | - | app:upsert rls:* | partly |
| `forwarder_rate_quotes` | 11 | ✓ | ✓ | · | · | — | - | app:insert/update rls:* | partly |
| `freight_allocations` | 1 | ✓ | ✓ | · | · | — | - | fn:I/U(1) rls:* | partly |
| `freight_documents` | 4 | ✓ | ✓ | ✓ | ✓ | reversed_by | - | fn:I/U(3) rls:* | partly |
| `fx_rate_history` | 0 | · | · | · | · | changed_by | (is history) | fn:I(2) | traced |
| `fx_rates` | 12 | ✓ | ✓ | ✓ | ✓ | — | fx_rate_history | fn:I/U(2) rls:adw | traced |
| `gst_filing_requests` | 0 | ✓ | ✓ | · | · | decided_by,withdrawn_by | - | fn:I/U(3) | partly |
| `gst_periods` | 1 | ✓ | ✓ | · | · | filed_by | - | fn:I/U(4) | partly |
| `gst_return_boxes` | 0 | ✓ | · | · | · | — | - | fn:I(1) | partly |
| `handover_item_types` | 1 | · | · | · | · | — | - | rls:* | **untraced** |
| `home_greetings` | 72 | ✓ | · | ✓ | · | — | - | rls:adw | **untraced** |
| `hr_settings` | 1 | · | · | ✓ | ✓ | — | - | rls:w | partly |
| `import_batches` | 2 | · | · | · | · | imported_by | (append-only, row carries actor) | fn:I(1) | traced |
| `inbound_batch_metals` | 19 | ✓ | ✓ | ✓ | ✓ | — | - | fn:I/D(1) app:delete/upsert rls:adw | partly |
| `inbound_batch_safety_states` | 1 | ✓ | ✓ | · | · | — | - | fn:I/D(2) rls:ad | partly |
| `inbound_batches` | 24 | ✓ | ✓ | ✓ | ✓ | deleted_by,import_permit_verified_by,source_reason_recorded_by | price_history | fn:I/U(10) app:update rls:dw | partly |
| `inbound_chemistry_certainties` | 3 | · | · | · | · | — | - | rls:aw | **untraced** |
| `inbound_safety_states` | 5 | · | · | · | · | — | - | rls:aw | **untraced** |
| `inbound_source_reasons` | 4 | · | · | · | · | — | - | rls:aw | **untraced** |
| `index_market_calendar` | 0 | ✓ | ✓ | ✓ | ✓ | — | - | rls:* | partly |
| `inventory_movements` | 107 | ✓ | ✓ | · | · | — | (append-only, row carries actor) | fn:I(10) rls:a | traced |
| `invoice_issues` | 4 | · | · | · | · | issued_by | - | fn:I(1) app:update | partly |
| `invoice_lines` | 9 | ✓ | · | · | · | — | - | fn:I/U(3) | **untraced** |
| `invoice_requests` | 0 | ✓ | ✓ | · | · | decided_by,withdrawn_by | - | fn:I/U(3) | partly |
| `invoices` | 9 | ✓ | ✓ | · | · | voided_by | - | fn:I/U(3) | partly |
| `journal_entries` | 82 | ✓ | ✓ | · | · | reversed_by | - | fn:I/U(2) | partly |
| `journal_lines` | 184 | ✓ | · | · | · | — | - | fn:I(1) | partly |
| `journal_requests` | 0 | ✓ | ✓ | · | · | decided_by,withdrawn_by | - | fn:I/U(3) | partly |
| `kpi_cycles` | 6 | ✓ | ✓ | ✓ | ✓ | locked_by | - | rls:aw | partly |
| `kpi_entries` | 30 | ✓ | ✓ | ✓ | ✓ | scored_by | - | fn:I/U(2) | partly |
| `kpi_organisation` | 5 | ✓ | · | ✓ | · | — | (no app/function/RLS writer found) | none | seed-only |
| `kpi_position_templates` | 30 | ✓ | · | ✓ | · | — | (no app/function/RLS writer found) | none | seed-only |
| `kpi_score_rubric` | 6 | ✓ | · | ✓ | · | — | - | rls:adw | **untraced** |
| `kpi_template_org_links` | 41 | · | · | · | · | — | (no app/function/RLS writer found) | none | seed-only |
| `laboratories` | 1 | · | · | · | · | — | - | rls:aw | **untraced** |
| `lane_document_requirements` | 1 | ✓ | ✓ | · | · | — | - | app:insert/update rls:* | partly |
| `lanes` | 7 | ✓ | ✓ | · | · | — | - | app:insert/update rls:* | partly |
| `leave_accrual_rates` | 2 | ✓ | ✓ | ✓ | ✓ | — | - | rls:adw | partly |
| `leave_consumption` | 2 | ✓ | ✓ | · | · | — | (append-only, row carries actor) | fn:I(2) rls:a | traced |
| `leave_grants` | 0 | ✓ | ✓ | ✓ | ✓ | — | - | fn:I(1) rls:adw | partly |
| `leave_requests` | 6 | ✓ | ✓ | ✓ | ✓ | decided_by | - | fn:I/U(3) | partly |
| `leave_types` | 13 | ✓ | ✓ | ✓ | ✓ | — | - | app:update rls:adw | partly |
| `list_ledger_residue` | 7 | · | · | · | · | — | (no app/function/RLS writer found) | none | seed-only |
| `loss_categories` | 4 | · | · | · | · | — | - | rls:aw | **untraced** |
| `loss_metal_fates` | 3 | · | · | · | · | — | - | rls:aw | **untraced** |
| `maintenance_settings` | 1 | · | · | ✓ | ✓ | — | - | rls:w | partly |
| `management_packs` | 0 | · | · | · | · | produced_by,superseded_by | - | fn:I/U(1) | partly |
| `material_attachments` | 2 | ✓ | ✓ | ✓ | ✓ | — | - | app:insert/update rls:adw | partly |
| `material_forms` | 13 | · | · | · | · | — | - | rls:aw | **untraced** |
| `material_kinds` | 5 | · | · | · | · | — | - | rls:aw | **untraced** |
| `material_required_metals` | 0 | ✓ | ✓ | · | · | — | - | fn:I/D(1) | partly |
| `material_size_formats` | 5 | · | · | · | · | — | - | rls:aw | **untraced** |
| `material_sources` | 3 | · | · | · | · | — | - | rls:aw | **untraced** |
| `materials` | 9 | ✓ | ✓ | ✓ | ✓ | — | - | app:insert/update rls:adw | partly |
| `medical_claims` | 1 | ✓ | ✓ | ✓ | ✓ | decided_by | - | fn:I/U(4) rls:adw | partly |
| `metal_price_indices` | 2 | ✓ | · | ✓ | ✓ | — | - | rls:* | partly |
| `metal_prices` | 12 | ✓ | ✓ | ✓ | ✓ | — | - | fn:I(1) app:insert/update rls:adw | partly |
| `notification_reads` | 7 | · | · | · | · | — | - | app:upsert rls:ad | **untraced** |
| `notifications` | 2 | ✓ | · | · | · | — | - | fn:I(2) | partly |
| `operation_kinds` | 2 | · | · | · | · | — | (no app/function/RLS writer found) | none | seed-only |
| `operation_type_input_forms` | 14 | · | · | · | · | — | - | rls:* | **untraced** |
| `operation_type_output_forms` | 9 | · | · | · | · | — | - | rls:* | **untraced** |
| `operation_type_safety_states` | 9 | · | · | · | · | — | - | rls:* | **untraced** |
| `operation_types` | 5 | · | · | · | · | — | - | rls:* | **untraced** |
| `output_batch_metals` | 6 | ✓ | ✓ | ✓ | ✓ | — | - | fn:I/D(1) app:delete/upsert rls:adw | partly |
| `output_batch_purposes` | 2 | · | · | · | · | — | - | rls:* | **untraced** |
| `output_batch_safety_states` | 1 | ✓ | ✓ | · | · | — | - | fn:I/D(1) app:delete/insert rls:ad | partly |
| `output_batch_states` | 3 | · | · | · | · | — | (no app/function/RLS writer found) | none | seed-only |
| `output_batches` | 20 | ✓ | ✓ | ✓ | ✓ | deleted_by | - | fn:I/U(8) app:update rls:dw | partly |
| `overtime_batches` | 0 | ✓ | ✓ | · | · | submitted_by,decided_by,reversed_by,discarded_by | - | fn:I/U(6) | partly |
| `overtime_lines` | 0 | ✓ | ✓ | · | · | — | - | fn:I/U/D(6) | partly |
| `payment_allocations` | 7 | ✓ | · | · | · | — | - | fn:I(1) rls:a | partly |
| `payment_event_owners` | 3 | · | · | ✓ | ✓ | — | (no app/function/RLS writer found) | none | seed-only |
| `payment_requests` | 0 | ✓ | ✓ | · | · | decided_by,withdrawn_by,paid_by | - | fn:I/U(9) | partly |
| `payment_term_template_lines` | 3 | ✓ | · | · | · | — | - | app:delete/insert rls:adw | **untraced** |
| `payment_term_templates` | 1 | ✓ | ✓ | ✓ | ✓ | — | - | app:insert/update rls:adw | partly |
| `payment_trigger_events` | 8 | ✓ | · | · | · | — | (no app/function/RLS writer found) | none | seed-only |
| `payments` | 13 | ✓ | ✓ | · | · | — | - | fn:I/U(2) | partly |
| `payroll_lines` | 1 | ✓ | · | · | · | — | - | fn:I/U/D(2) rls:adw | **untraced** |
| `payroll_periods` | 1 | ✓ | ✓ | ✓ | ✓ | — | - | fn:I/U(5) rls:adw | partly |
| `payroll_requests` | 0 | ✓ | ✓ | · | · | decided_by,withdrawn_by,executed_by | - | fn:I/U(5) | partly |
| `performance_reviews` | 0 | ✓ | ✓ | ✓ | ✓ | submitted_by,approved_by,voided_by | - | fn:I/U(10) app:update rls:adw | partly |
| `period_closes` | 1 | · | · | · | · | closed_by,reopened_by | - | fn:I/U(2) rls:aw | partly |
| `permissions` | 71 | · | · | · | · | — | (no app/function/RLS writer found) | none | seed-only |
| `po_issues` | 10 | · | · | · | · | issued_by | - | fn:I(1) app:update | partly |
| `ports` | 14 | ✓ | ✓ | · | · | — | - | app:insert rls:* | partly |
| `positions` | 6 | ✓ | ✓ | ✓ | ✓ | — | (no app/function/RLS writer found) | none | seed-only |
| `prepayment_applications` | 2 | ✓ | ✓ | · | · | — | (append-only, row carries actor) | fn:I(1) rls:a | traced |
| `price_history` | 14 | ✓ | ✓ | · | · | — | (is history) | fn:I(1) | traced |
| `pricing_formula_history` | 0 | · | · | · | · | changed_by | (is history) | fn:I(2) | traced |
| `pricing_formula_metals` | 3 | ✓ | ✓ | ✓ | ✓ | — | pricing_formula_history | fn:I/D(2) | traced |
| `pricing_formulas` | 1 | ✓ | ✓ | ✓ | ✓ | — | pricing_formula_history | fn:I/U(4) | traced |
| `pricing_settings` | 1 | · | · | ✓ | ✓ | — | - | app:update rls:w | partly |
| `pricing_term_commitment_metals` | 3 | · | · | · | · | — | - | fn:I(1) | partly |
| `pricing_term_commitments` | 1 | · | · | · | · | committed_by | (append-only, row carries actor) | fn:I(1) | traced |
| `processing_cost_entries` | 10 | ✓ | ✓ | ✓ | ✓ | — | processing_cost_entry_history | fn:U(2) app:insert/update rls:adw | partly |
| `processing_cost_entry_history` | 7 | · | · | · | · | changed_by | (is history) | fn:I(1) | traced |
| `processing_inputs` | 14 | ✓ | · | · | · | — | - | fn:I(1) rls:aw | **untraced** |
| `processing_outputs` | 17 | ✓ | · | · | · | — | - | fn:I/U(2) rls:w | **untraced** |
| `processing_run_losses` | 0 | ✓ | ✓ | · | · | — | - | app:delete/upsert rls:adw | partly |
| `processing_runs` | 14 | ✓ | ✓ | ✓ | ✓ | allocated_by,deleted_by | - | fn:I/U(3) rls:w | partly |
| `processing_settings` | 1 | · | · | ✓ | ✓ | — | - | app:update rls:w | partly |
| `public_holidays` | 26 | ✓ | ✓ | ✓ | ✓ | — | - | app:delete/insert/update rls:adw | partly |
| `purchase_order_history` | 10 | · | · | · | · | changed_by | (is history) | fn:I(4) | traced |
| `purchase_order_line_retentions` | 0 | ✓ | ✓ | · | · | released_by | - | fn:I/U(2) | partly |
| `purchase_order_lines` | 11 | ✓ | ✓ | · | · | — | purchase_order_history | fn:I/U/D(2) app:update | partly |
| `purchase_order_payment_terms` | 24 | ✓ | · | · | · | expected_date_set_by | purchase_order_history | fn:I/U/D(3) | partly |
| `purchase_orders` | 11 | ✓ | ✓ | ✓ | ✓ | approved_by,deleted_by,cancelled_by | purchase_order_history | fn:I/U(9) | partly |
| `qt_issues` | 3 | · | · | · | · | issued_by | (append-only, row carries actor) | fn:I(1) | traced |
| `quote_history` | 6 | · | · | · | · | changed_by | (is history) | fn:I(4) | traced |
| `quote_lines` | 3 | ✓ | · | · | · | — | - | app:delete/insert/update rls:adw | **untraced** |
| `quotes` | 3 | ✓ | ✓ | ✓ | ✓ | deleted_by | quote_history | fn:U(4) app:insert/update rls:aw | partly |
| `receipt_price_requests` | 0 | ✓ | ✓ | · | · | decided_by,withdrawn_by | - | fn:I/U(3) | partly |
| `receiving_settings` | 1 | · | · | ✓ | ✓ | — | - | app:update rls:w | partly |
| `review_cycles` | 0 | ✓ | ✓ | ✓ | ✓ | — | - | fn:U(1) app:insert/update rls:adw | partly |
| `review_goals` | 0 | ✓ | ✓ | ✓ | ✓ | — | - | fn:I/U/D(6) rls:adw | partly |
| `review_rating_scale` | 4 | ✓ | ✓ | ✓ | ✓ | — | - | app:insert/update rls:adw | partly |
| `role_permissions` | 336 | ✓ | ✓ | · | · | — | - | fn:I/D(1) rls:adw | partly |
| `roles` | 13 | ✓ | ✓ | ✓ | ✓ | — | - | app:insert/update rls:adw | partly |
| `salary_change_requests` | 0 | ✓ | ✓ | · | · | decided_by,withdrawn_by | - | fn:I/U(3) | partly |
| `sales_attribution_log` | 1 | · | · | · | · | attributed_by | (is history) | fn:I(1) | traced |
| `sales_order_history` | 22 | · | · | · | · | changed_by | (is history) | fn:I(12) | traced |
| `sales_order_lines` | 6 | ✓ | · | · | · | — | sales_order_history | fn:I/U/D(2) rls:dw | partly |
| `sales_order_reservations` | 3 | ✓ | ✓ | · | · | released_by,consumed_by | - | fn:I/U(4) | partly |
| `sales_orders` | 6 | ✓ | ✓ | ✓ | ✓ | deleted_by | sales_order_history | fn:I/U(5) rls:w | partly |
| `sales_record_movements` | 9 | ✓ | · | · | · | — | - | fn:I(2) | partly |
| `sales_records` | 9 | ✓ | ✓ | · | · | — | sales_attribution_log | fn:I/U(4) | partly |
| `sales_settlements` | 0 | · | · | · | · | superseded_by,computed_by | (no app/function/RLS writer found) | none | seed-only |
| `shift_handover_equipment_refs` | 0 | ✓ | ✓ | · | · | — | - | fn:I(1) rls:* | partly |
| `shift_handover_items` | 0 | ✓ | ✓ | · | · | — | - | fn:I(1) rls:* | partly |
| `shift_handovers` | 0 | ✓ | ✓ | ✓ | ✓ | submitted_by,acknowledged_by | - | fn:I/U(2) rls:* | partly |
| `shifts` | 2 | ✓ | · | ✓ | · | — | - | rls:* | **untraced** |
| `shipment_issues` | 3 | · | · | · | · | issued_by | (append-only, row carries actor) | fn:I(1) | traced |
| `shipment_lines` | 1 | ✓ | · | · | · | — | - | fn:I(1) | partly |
| `shipments` | 3 | ✓ | ✓ | · | · | — | - | fn:I/U(3) | partly |
| `shipping_release_lines` | 0 | ✓ | · | · | · | — | - | fn:I(1) | partly |
| `shipping_releases` | 0 | ✓ | ✓ | · | · | decided_by,withdrawn_by | - | fn:I/U(3) | partly |
| `so_issues` | 2 | · | · | · | · | issued_by | (append-only, row carries actor) | fn:I(1) | traced |
| `statement_issues` | 0 | · | · | · | · | issued_by | (append-only, row carries actor) | fn:I(1) | traced |
| `stocktake_counts` | 0 | · | · | · | · | counted_by | (append-only, row carries actor) | fn:I(1) | traced |
| `stocktake_lines` | 4 | · | ✓ | · | · | — | (append-only, row carries actor) | fn:I(1) | traced |
| `stocktakes` | 10 | ✓ | ✓ | ✓ | ✓ | deleted_by,cancelled_by | - | fn:I/U(4) | partly |
| `storage_location_allowed_classes` | 1 | ✓ | ✓ | · | · | — | - | app:delete/insert rls:adw | partly |
| `storage_locations` | 4 | ✓ | ✓ | ✓ | ✓ | — | - | app:insert/update rls:aw | partly |
| `substances` | 7 | · | · | · | · | — | - | rls:aw | **untraced** |
| `supplier_attachments` | 2 | ✓ | ✓ | ✓ | ✓ | — | - | app:insert/update rls:adw | partly |
| `supplier_compliance` | 4 | ✓ | ✓ | ✓ | ✓ | — | - | app:insert/update rls:adw | partly |
| `supplier_status_history` | 0 | · | · | · | · | changed_by | (is history) | fn:I(1) | traced |
| `suppliers` | 17 | ✓ | ✓ | ✓ | ✓ | approved_by | supplier_status_history | fn:U(1) app:insert/update rls:adw | partly |
| `task_history` | 46 | · | · | · | · | changed_by | (is history) | fn:I(5) | traced |
| `task_nodes` | 4 | ✓ | ✓ | ✓ | ✓ | done_by | task_history | fn:U(1) app:delete/insert/update rls:adw | traced |
| `task_participants` | 11 | · | · | · | · | added_by,removed_by | task_history | fn:I/U(1) app:insert/update rls:aw | traced |
| `tasks` | 20 | ✓ | ✓ | ✓ | ✓ | — | task_history | fn:U(2) app:insert/update rls:adw | traced |
| `tax_codes` | 9 | · | · | · | · | — | (no app/function/RLS writer found) | none | seed-only |
| `tax_rates` | 13 | ✓ | · | · | · | — | (no app/function/RLS writer found) | none | seed-only |
| `terms_requests` | 0 | ✓ | ✓ | · | · | decided_by,withdrawn_by | - | fn:I/U(3) | partly |
| `traceability_report_issues` | 1 | · | · | · | · | issued_by | (append-only, row carries actor) | fn:I(1) | traced |
| `training_records` | 1 | ✓ | ✓ | ✓ | ✓ | — | - | app:insert/update rls:adw | partly |
| `user_roles` | 9 | · | · | · | · | granted_by,revoked_by | - | fn:I/U(1) rls:adw | partly |
| `warehouse_requests` | 0 | ✓ | ✓ | · | · | decided_by,withdrawn_by | - | fn:I/U(3) | partly |
| `waste_classifications` | 2 | ✓ | · | ✓ | ✓ | — | - | rls:* | partly |
| `wht_natures` | 7 | · | · | · | · | — | (no app/function/RLS writer found) | none | seed-only |
| `wht_rates` | 7 | ✓ | · | · | · | — | (no app/function/RLS writer found) | none | seed-only |
| `wht_remittances` | 0 | ✓ | ✓ | · | · | — | (append-only, row carries actor) | fn:I(1) | traced |
| `work_order_expected_outputs` | 1 | ✓ | · | · | · | — | - | fn:I/U/D(2) | **untraced** |
| `work_order_history` | 2 | · | · | · | · | changed_by | (is history) | fn:I(5) | traced |
| `work_order_lines` | 2 | ✓ | · | · | · | — | work_order_history | fn:I/U/D(2) | partly |
| `work_orders` | 1 | ✓ | ✓ | ✓ | ✓ | closed_by,cancelled_by | work_order_history | fn:I/U(5) | partly |
| `year_closes` | 0 | · | · | · | · | closed_by,reopened_by | - | fn:I/U(2) | partly |
<!-- END CENSUS TABLE -->

---

## C. Actor identity

**How the database learns who is acting (Measured, `pg_get_functiondef`):** from the request JWT. `auth.uid()` reads
`request.jwt.claim.sub` or `request.jwt.claims ->> 'sub'`, which PostgREST sets per request. 205 public functions call
`auth.uid()`, and 34 call `current_user_employee()` (= `account_person(auth.uid())`). One function sets a session setting
(`rebalance_task_nodes`), and none passes the actor as a parameter.

| Write origin | What `auth.uid()` returns | What gets recorded |
|---|---|---|
| Signed-in user through PostgREST or an RPC, including a SECURITY DEFINER function | the caller's account id (definer rights do not change the GUC) | the account id; `task_history` records the person via `current_user_employee()` |
| `postgres` — migrations, `db/apply_migration.sh`, Management API, fixtures | `NULL` (no JWT) | `NULL`; `fixed_asset_history` also writes `changed_by_kind = 'no_session'`; `task_history` has 8 rows with `NULL` actor |
| `service_role` — the three call sites in §B.1 | `NULL` unless the call forwards a JWT | none of the three writes a history table (Inferred from what they call) |
| Scheduled job | — | none exists |

**Recorded actors today (Measured, join to `auth.users` and `account_person`):**

| History table(s) | Actor values | Resolve to an auth account | Resolve to a person |
|---|--:|--:|--:|
| 11 tables storing auth ids, excluding the three below | 81 | 67 | 67 |
| `fixed_asset_history` | 2 | 0 | 0 |
| `work_order_history` | 2 | 0 | 0 |
| `task_history` (employee ids) | 38 non-null + 8 null | n/a | 38 (all EMP-2026-0002) |

The 18 unresolvable rows (9 distinct ids) were written on 2026-08-14/15/16 and 2026-09-20. Their `auth.users` rows no longer exist.
They are consistent with ephemeral smoke/probe accounts that the cleanup deleted (Inferred; the deleted rows cannot be
read back). **Deleting an auth account leaves every history row it wrote pointing at nothing**, because no actor
column has a foreign key to `auth.users` and no row stores a name or email.

**Account lifecycle is not recorded at all.** `auth.audit_log_entries` holds **0 rows** (Measured). The creation and
deletion of login accounts leave no trace in the database. Role grants do leave one: `user_roles` keeps `granted_by`
and `revoked_by`/`revoked_at` (soft revoke).

**The admin@ / tim@ case (Measured).** `admin@swm-os.test` (`321f1819…`) is `employees.user_id` of EMP-2026-0002.
`tim@evoltrya.test` (`634c00f9…`) reaches the same employee through `employee_accounts` (linked 2026-09-23 by admin@).
`account_person()` resolves both to EMP-2026-0002.

* The 16 auth-id tables record **the account**, so they tell the two apart: 62 of the resolvable rows are admin@,
  5 are sandra@, and tim@ has written none yet.
* `task_history` records **the person**. All 38 non-null rows are EMP-2026-0002, so it cannot tell which of the two
  accounts acted.
* A mechanism that stores the account id and resolves the person at read time answers both questions. It also needs
  the person frozen at write time, because `employee_accounts` links change (`unlink_additional_account` deletes the link).

---

## D. Known gaps — delete-and-reinsert and hard deletes

### D.1 `set_role_permissions` — confirmed

Body (Measured, `pg_proc.prosrc`): after its guards it runs `DELETE FROM role_permissions WHERE role_id = p_role_id;`
and then `INSERT INTO role_permissions (role_id, permission_code, created_by) SELECT p_role_id, c, auth.uid() FROM unnest(v_codes) c;`.
`role_permissions` has only `enforce_write_permission` on it, and no history trigger. After a save, every row carries
the saver and the save time, and the previous code list is gone. On 2026-09-28 at 19:00:35 CST, all 41 `cco` rows were
rewritten with one `created_at`, as the queue item records. The code count 41 was re-measured today.

### D.2 The same shape elsewhere — 15 functions

Functions that `DELETE FROM t` and `INSERT INTO t` on the same table (Measured, regex over function bodies):

| Function | Table(s) rewritten | Captured by a history trigger |
|---|---|---|
| `set_role_permissions` | `role_permissions` | **no** |
| `amend_purchase_order` | `purchase_order_lines`, `purchase_order_payment_terms` | yes — both carry I/D/U history triggers |
| `amend_sales_order` | `sales_order_lines` | yes (I/D/U trigger) |
| `amend_work_order` | `work_order_lines`, `work_order_expected_outputs` | partly — `work_order_history` rows are written by the function, not a trigger |
| `terms_request_execute_internal` | `pricing_formula_metals` | yes (I/D/U trigger) |
| `apply_payment_term_template` | `purchase_order_payment_terms` | yes |
| `allocate_processing_costs` | `batch_processing_cost_allocations` | no |
| `apply_assay_result` | `inbound_batch_metals` | no |
| `apply_output_assay` | `output_batch_metals` | no |
| `commit_processing_run` | `inbound_batch_safety_states`, `output_batch_safety_states` | no |
| `set_inbound_safety_states` | `inbound_batch_safety_states` | no |
| `set_material_required_metals` | `material_required_metals` | no |
| `upsert_payroll_period` | `payroll_lines` | no |
| `refresh_cod_for_batch` | `certificates_of_destruction` | no |
| `cod_verification` | `cod_verification_failures` | no |

Four more functions delete without re-inserting: `delete_overtime_line` (`overtime_lines`), `remove_review_goal`
(`review_goals`), `unmatch_bank_line` (`bank_line_matches`) and `unlink_additional_account` (`employee_accounts`,
recorded in `employee_account_history`).

App-side delete + re-insert or delete (Measured, scanner, §B.1): `inbound_batch_metals`, `output_batch_metals`
(`app/components/metals/metalContentActions.ts`), `equipment_service_intervals`, `public_holidays`,
`storage_location_allowed_classes`, `processing_run_losses`, `output_batch_safety_states`,
`payment_term_template_lines`, `quote_lines` and `task_nodes` (the last has history).

### D.3 Hard deletes permitted to users

90 tables have an RLS policy admitting `authenticated` for DELETE. On **69** of them no BEFORE DELETE trigger other
than `enforce_write_permission` exists (Measured). The 21 guarded ones match names like `no_hard_delete`, `frozen` or `floor`,
and some of those guards are conditional, so "guarded" means "has a delete guard", not "can never be deleted". 27 of the 69 also carry a `deleted_at`/`archived_at` column, which suggests the screens soft-delete while the policy still
permits a hard delete (Inferred). A hard delete on any of the 69 erases the row with no trace.

---

## E. Constraints on a unified mechanism

1. **Masking.** 28 tables are masked. A generic log that stores row images copies masked values (prices, salary,
   amounts) into a table whose readers the source's column grants do not govern. The log therefore must have **no direct
   grant to `authenticated`**, and every reader must redact the columns that the source's `_masked` view hides unless the
   reader holds the data code. This rule is the one `batch_audit_trail_all` already follows (`amount_restricted`). The
   `purchase_order_history` gap in §A.3 is the existing instance of a history table that does not follow it.
2. **PDPA.** `anonymise_employee` today reaches `employment_history` only, and `export_my_personal_data` reads no history
   table other than `employment_history`. A log of `employees` changes would hold identity numbers, work-pass numbers,
   contact fields and names in `old`/`new` images. So an append-only log needs **one sanctioned redaction path** that
   `anonymise_employee` calls — the same shape `reject_employment_history_mutation` already allows. The export also
   has to decide whether changes to the person's own record are part of "their data".
3. **Immutability.** It is achievable against `authenticated`, `anon` and `service_role` (no grant plus UPDATE/DELETE row
   triggers plus a TRUNCATE statement trigger). It is **not** achievable against `postgres`, the owner that migrations
   run as, because the owner can disable triggers. On this platform `postgres` is not a superuser, but it owns `public`
   and can alter its tables. A later tamper-evidence layer (a hash chain, or periodic export off the database) is the
   only way to detect owner-level edits (Inferred).
4. **Volume and performance.** 57 MB database, 2,112 live rows across all 241 tables (Measured). Lifetime counters: 86,227 inserts, 10,195
   updates and 7,157 deletes, dominated by `role_permissions` (39,977 inserts, 3,121 deletes, 336 live). Those counters
   include rolled-back fixture transactions, so they overstate committed churn. The largest table has 336 rows.
   Trigger cost is not a constraint at this size (Inferred). The main source of log noise would be the delete-and-reinsert
   functions: one `set_role_permissions` save writes 2 × N rows, which is a reason to make that function diff-aware.
5. **Ordering.** Writers take their time from `DEFAULT now()`, the transaction start. Only `approval_log` and
   `employee_account_history` have a `seq`. `clock_timestamp()` is used by 5 functions, none of them history writers.
   AGENTS.md (AGING-1) records the consequence: rows from one transaction tie, and a random uuid in `ORDER BY` hides it.
   A unified log needs a `bigserial` sequence (or identity) as the order of record.
6. **The broken window.** Adding a log table and AFTER triggers is additive: no existing column, function signature or
   policy changes, so old app code runs unchanged against the new database. The window is open but nothing breaks inside it
   (Inferred). Converting domain history tables into views would be the opposite: every reader, the masked views, `batch_audit_trail_all` and its fixtures
   would change at once.
7. **Existing readers.** The readers that must keep working are the app files and DB functions/views listed in §A.2,
   `batch_audit_trail_all` with its three fixtures (`docs/batch-audit-trail.md` §十), and the typed pairing that
   `fixed_asset_history` relies on (fixture 201 pins "every column paired").
8. **The mirror and gate rules apply.** A new table needs its `db/tables` mirror, `colgrant`/`masked-columns` must
   accept it, the new trigger function needs a byte-exact function mirror, and B1 (anon execute) applies to it. A trigger
   on all 241 tables touches every table's trigger list, and `check_mirrors` compares trigger lists, so the migration has
   to be generated rather than hand-written (Inferred from AGENTS.md mirror rules).
9. **Deleted accounts.** Actor ids have no foreign key and no snapshot (§C). Whatever the log stores, an account
   deletion should not turn its rows into "unknown".

---

## F. Candidate shapes and the recommendation

| Shape | Covers | Costs | Breaks |
|---|---|---|---|
| **F1 — one generic append-only log, alongside.** `audit.row_changes` (or `public.change_log`): `seq bigserial`, `occurred_at clock_timestamp()`, `txid`, `table_name`, `row_id`, `op`, `actor_account` (`auth.uid()`), `actor_person` (frozen `account_person()` at write time), `actor_kind` (`user` / `no_session` + `current_user`), `changed_columns`, `old` (jsonb, changed columns on UPDATE, full row on DELETE), `new` (jsonb, changed columns on UPDATE, full row on INSERT). One AFTER ROW trigger function on every base table. The 17 domain tables stay. | Every write on all 241 tables, including direct PostgREST writes, delete-and-reinsert, hard deletes, `finance_settings` locks and migration-time changes (as `no_session`) | 1 table + 1 trigger function + 241 trigger bindings (generated) + a redaction path for PDPA + a reader function with masking. Low runtime cost at this size | Nothing existing. Adds a second record for tables that already have domain history (by design: the log is the fact of change, and the domain table carries the meaning — reason, level, event name) |
| F2 — generic log, domain tables become views over it | Same as F1 | F1's cost plus rewriting 17 tables into views, their masked views, `batch_audit_trail_all`, the app readers in §A.2, 47 writer functions and the fixtures that pin them | Domain fields that are not row diffs — `approval_log.level`/`decision`, `amend_reason`, `change_type` events like `issued`/`reserved`, `sales_attribution_log.exposure_after`, `price_history.fx_rate`/`rate_as_of` — have no source in a row diff and would be lost or need side-channels. The whole migration lands inside one broken window |
| F3 — one typed paired-column history table per source table (the `fixed_asset_history` pattern, everywhere) | Every table, typed | ~220 new tables, each with a mirror, grants, a masked twin where the source is masked, and a pairing fixture; every `ALTER TABLE ADD COLUMN` needs a twin `ALTER` on its history table | Nothing existing, but schema size roughly doubles, and the mirror/colgrant burden grows with every future column |
| F4 — gap-filling only (a history for `role_permissions`, `finance_settings` locks, and the untraced tables one at a time) | What is chosen | Small per cut | Nothing. It does not meet the stated goal that every write leaves a trace, and each new table repeats today's divergence of shapes |
| F5 — database statement logging (pgaudit / platform logs) | Statements, not row images | Platform-dependent; not queryable from the app; retention outside this database | No before values; no join to rows; cannot be masked or anonymised per row |

**Recommendation: F1.** The evidence:

* It is the only shape that reaches the 35 untraced tables, the 116 "mutable, no before value" tables, the 69
  unguarded hard deletes and the 15 delete-and-reinsert functions without touching any of them (§B, §D).
* It changes no existing reader, so `batch_audit_trail_all`, its fixtures and the app readers in §A.2 keep working (§E.7).
  The migration is additive, so the broken window has nothing in it that breaks (§E.6).
* The diff mechanism is already in production and pinned by a fixture: `trg_fixed_assets_history` builds the change set
  by jsonb difference with no column names in its body (§A.2). F1 generalises it to jsonb storage, which drops the one
  thing that makes F3 expensive: typed paired columns that must track every `ADD COLUMN`.
* Recording the account and freezing the person at write time answers both "which login" and "which human" (§C). No
  current table does both.
* F2's appeal (one store) costs the domain meaning that the 17 tables exist to hold. Those fields are not row diffs
  (§F table), and converting them would put the whole system inside one broken window.

What F1 requires in the same cut, from §E: no direct grant and a masking reader; a sanctioned PDPA redaction path;
UPDATE/DELETE/TRUNCATE refusal for every role except that path; a `bigserial` order; a generated migration with
generated mirrors. What it leaves for later: per-record history panels on screens, making `set_role_permissions`
diff-aware, and tamper evidence against the owner.

**Nothing was built.**

---

## G. Questions for Tim

Every question has a recommended answer and the evidence for it. They are not triaged.

**G1 — The count.** Should the history set be taken as the 17 tables in §A.1, not 16?
*Recommended:* yes. *Evidence:* two independent enumerations (name and structure) converge on 17. The 16 is
AUDIT-1's count of a different set, and four history tables were added after it (§A.1).

**G2 — The shape.** Should HISTORY-1 build F1 (one generic append-only change log plus one trigger function on every
base table, alongside the existing tables)?
*Recommended:* yes. *Evidence:* §F. It is the only shape that covers every write path without changing an existing
reader, and it is already proven on `fixed_assets`.

**G3 — The existing 17.** Should they stay as they are, and not be converted into views over the log?
*Recommended:* stay. *Evidence:* their domain fields are not row diffs (§F, F2 row), and the app readers,
`batch_audit_trail_all` and its fixtures read them (§A.2, §A.4).

**G4 — Coverage.** Should the log cover all 241 base tables, including the 18 seed-only tables, whose only writer is a
migration?
*Recommended:* all 241, with a short named exclusion list (G5). *Evidence:* migrations change permissions and settings
(`permissions` has 30 updates and 143 deletes in its lifetime counters), and a migration-time change is exactly what an
auditor asks about later. Those rows record `actor_kind = no_session` with the database role.

**G5 — Exclusions.** Which tables stay out of the log?
*Recommended:* only per-viewer UI state with no business meaning — `notification_reads`, `home_greetings` and
`festival_doodles`. The log itself is excluded by construction. *Evidence:* these tables hold no business fact, and they
are the likeliest source of volume (§E.4).

**G6 — Actor.** Should the log record the account (`auth.uid()`) **and** the person resolved at write time?
*Recommended:* yes. *Evidence:* admin@ and tim@ are one person on two accounts (§C). Account-only history cannot say who
the human was after a link changes, and person-only history (`task_history`) cannot say which login acted.

**G7 — Writes with no session.** How should migration, fixture and service-role writes appear?
*Recommended:* `actor_kind = 'no_session'` plus `current_user` (`postgres` / `service_role`), never a guessed person.
*Evidence:* `fixed_asset_history.changed_by_kind` already does this, and 8 `task_history` rows today have a `NULL` actor
with no reason recorded (§C).

**G8 — Before and after values.** Should UPDATE store only the changed columns (old and new), and INSERT and DELETE store
the full row?
*Recommended:* yes. *Evidence:* that is exactly what `trg_fixed_assets_history` does, including skipping no-op
UPDATEs. A full row on DELETE is the only way to recover a hard-deleted row (§D.3).

**G9 — Ordering.** Should the log's order of record be a `bigserial` sequence, with `clock_timestamp()` as the time?
*Recommended:* yes. *Evidence:* every current writer uses `now()`, which ties within a transaction. Only two tables
have a `seq`. AGENTS.md (AGING-1) records the wrong-answer failure this causes (§E.5).

**G10 — Who reads the log, and how masking applies.** Should the log carry no direct grant, with the first reader a
SECURITY DEFINER function for `admin` and `auditor` that redacts each source table's masked columns unless the reader
holds the matching data code?
*Recommended:* yes. *Evidence:* 28 tables are masked, and a log of their rows would otherwise bypass the column grants
(§E.1). `batch_audit_trail_all` already redacts this way (`amount_restricted`).

**G11 — PDPA anonymisation.** Should `anonymise_employee` redact the log rows about that employee through one
sanctioned path, which is the only exception to append-only?
*Recommended:* yes. It should null the personal fields in `old`/`new` and stamp `anonymised_at`, the same shape
`reject_employment_history_mutation` permits. *Evidence:* today it reaches only `employment_history` (§A.3). A log of
`employees` changes would otherwise keep identity and work-pass numbers after anonymisation.

**G12 — PDPA access and export.** Should `export_my_personal_data` include log rows about changes to the requester's own
employee record?
*Recommended:* yes, with field-level redaction of other people's data. *Evidence:* the export already includes
`employment_history` (§A.3), and the log is its superset for the `employees` row.

**G13 — Immutability.** Should the log refuse UPDATE, DELETE and TRUNCATE for every role except the anonymisation path,
with the owner-level bypass recorded as a known limit?
*Recommended:* yes. *Evidence:* none of the 17 current guards covers TRUNCATE (§A.3). The owner can disable any trigger,
so the honest statement is "immutable to every application role" (§E.3).

**G14 — Tamper evidence against the owner.** Should a hash chain or an off-database export be part of HISTORY-1?
*Recommended:* no, a later cut. *Evidence:* no requirement today names it. It adds cost to every write path, and the
append-only guarantee against application roles is the property the stated goal needs (§E.3).

**G15 — Retention.** Should the log be kept indefinitely?
*Recommended:* yes, until a measured volume says otherwise. *Evidence:* the database is 57 MB, with 2,112 live rows in
total (§E.4).

**G16 — `set_role_permissions`.** Should it be made diff-aware (delete only removed codes, insert only added ones) in
HISTORY-1?
*Recommended:* yes. *Evidence:* the log alone would still record every save as N deletes plus N inserts, burying the one
code that actually changed. The function is the queue item that opened this family (§D.1).

**G17 — The other 14 delete-and-reinsert functions.** Should they be converted too?
*Recommended:* no. Rely on the log's DELETE and INSERT images. *Evidence:* four of them are already fully covered by history triggers and one partly (§D.2), and the rest rewrite derived or child rows whose meaning is the whole set (safety states,
metal content, allocations), where a full before/after image is the useful record.

**G18 — Guards on `task_history` and `work_order_history`.** Should HISTORY-1 add the append-only guard the other 15
have?
*Recommended:* yes. *Evidence:* they are the only two without one, and `task_history` shows `n_tup_upd = 2`,
`n_tup_del = 6` (§A.3).

**G19 — TRUNCATE on the 17.** Should a statement-level TRUNCATE guard be added to all 17?
*Recommended:* yes, in the same migration. *Evidence:* no current guard covers TRUNCATE (§A.3).

**G20 — `purchase_order_history` prices.** Should its price columns be masked the way `purchase_order_lines_masked`
masks them?
*Recommended:* yes, in HISTORY-1, before any role gains `module.purchasing.view` without `data.view_purchase_prices`.
*Evidence:* the table holds six price columns behind only `module.purchasing.view`. Today all 9 holders also hold the
price code, so the gap is latent, not live (§A.3).

**G21 — Hard deletes.** Should the 69 unguarded hard-delete tables be left as they are once the log records full
deleted rows?
*Recommended:* yes for HISTORY-1. Revisit per table later. *Evidence:* with the log, a hard delete is recoverable and
attributable. Closing 69 policies is a separate product decision about which deletions should exist at all (§D.3).

**G22 — Deleted accounts.** Should real login accounts be disabled instead of deleted, so their history stays
attributable?
*Recommended:* yes. The log's frozen `actor_person` covers the person side either way. *Evidence:* 18 recorded actor values (9 accounts) point at deleted accounts (§C), and `auth.audit_log_entries` is empty, so no other record of those accounts exists.

**G23 — Account lifecycle.** Should account creation and deletion (auth schema) be recorded?
*Recommended:* yes, from `app/settings/accounts/accountActions.ts` into the log as an application event, because the
auth schema is not ours to trigger. *Evidence:* `auth.audit_log_entries` holds 0 rows (§C), so today no record exists
that an account was created or deleted.

**G24 — `task_history` actor space.** Should `task_history.changed_by` move from employee id to account id?
*Recommended:* no. Leave it. The log records both for the same writes. *Evidence:* changing it would rewrite 38 rows of an
append-only table, and its reader resolves employee ids today (§A.2, §C).

**G25 — `finance_settings` locks and GST.** Should HISTORY-1 add columns to `finance_settings_history`, or rely on the
log?
*Recommended:* rely on the log. *Evidence:* the four untraced columns (`locked_before`, `gst_rate_pct`,
`gst_registered`, `system_start_date`) are all written by `set_finance_settings` through one UPDATE, which the generic
trigger captures (§B.2).

**G26 — A screen.** Should HISTORY-1 include one read screen for admin and auditor (filter by table, row, actor and
date), with per-record history panels left for later?
*Recommended:* yes. *Evidence:* a mechanism nobody can read repeats the "complete in the database, no screen" shape this
repo has recorded three times (the KPI scoring and approval-configuration entries in `docs/forward-queue.md`). Per-record
panels touch every detail page.

**G27 — Split.** Should HISTORY-1 be split into 1a (log, trigger, guards, masking reader, PDPA path, G18–G20) and 1b
(the screen, the `set_role_permissions` diff, account events)?
*Recommended:* yes. *Evidence:* 1a is one generated migration with no app change. 1b is app-side and can be walked
separately. Each half then carries its own gate.

**G28 — Storage objects.** Should file uploads and deletions in storage buckets be logged?
*Recommended:* no, not in HISTORY-1. *Evidence:* every bucket upload has a metadata row in a public table
(`*_attachments`, `finance_attachments`), which the log captures, and the storage schema is outside the mirrors
(AGENTS.md, UI-1d).

**G29 — Fixture rows on live.** Should rolled-back fixtures run through the Management API be expected to leave log rows?
*Recommended:* no action. *Evidence:* a rolled-back transaction leaves no committed log row. The gate replays fixtures
against a local rebuild, not live.

**G30 — The `/deleted` question.** The queue's event-driven list has "whether `/deleted` is absorbed by a history
mechanism". Should that stay out of HISTORY-1?
*Recommended:* yes, stay out. Soft-deleted rows remain in their tables, and the log adds the moment and actor of the
soft delete. Absorbing the screen is a UI decision for after 1b. *Evidence:* 27 of the 69 hard-deletable tables and
most business tables carry `deleted_at` (§D.3).

---

## Assertions in the brief measured and found false

1. "The system has 16 tables that record change history" → **17** under the definition in §A.1. The 16 is AUDIT-1's
   count of a different set.
2. "If most do not record the actor" → **all 17 record an actor**. The defect is two identity spaces plus 18 unresolvable actor values from 9 deleted accounts (§C).
3. Measured and found **true**: HEAD = origin/main = ls-remote = `12bb0d17…`, and it is QUEUE-READ's docs commit (its
   message reads "Docs: cco HR permissions (Tim), queue role-change history"). Also true: approvals ON with finance / cfo /
   1000; 7 live accounts; tim@ → EMP-2026-0002 through `employee_accounts`; cco holds `module.hr.edit` and
   `action.decide_hr_requests` (41 codes); and `set_role_permissions` deletes and re-inserts.
4. The "(file conflict)" labels are not in `docs/forward-queue.md` (grep: 0 hits). They were labels in the QUEUE-READ
   chat report. Every one of them was resolved against the file (`docs/forward-queue.md`, fold-in of 2026-09-28).

---

## M. Method — the queries

All ran as `postgres` inside `BEGIN READ ONLY; … ROLLBACK;` over
`host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres`.

* Candidate tables by name / structure: `pg_class` × `pg_attribute`, `relkind='r'`, regexes as in §A.1.
* Trigger writers: `pg_trigger` × `pg_proc` where `pg_get_functiondef ~* 'INSERT INTO'`.
* Row counts: a `DO` block running `SELECT count(*) FROM public.<t>` for each of the 241 tables.
* Grants: `information_schema.role_table_grants` / `column_privileges` for `authenticated`, `anon`.
* Policies: `pg_policy` (`polcmd`, `polroles`, `pg_get_expr(polqual)`).
* Guards: `pg_trigger.tgtype` bits (ROW 1, BEFORE 2, INSERT 4, DELETE 8, UPDATE 16, TRUNCATE 32).
* Foreign keys: `pg_constraint` (`contype='f'`, `confdeltype`).
* Actor resolution: per table, `count(*) FILTER (WHERE <actor> IN (SELECT id FROM auth.users))`,
  `… IN (SELECT id FROM employees)`, and `account_person(<actor>) IS NOT NULL`.
* Function write map: every `public` function body exported (`\copy … to csv`, 723 functions, comments stripped),
  regex `INSERT INTO|UPDATE|DELETE FROM <table>`, plus a call graph by name for reachability from the 291 app RPCs and
  212 trigger functions.
* App writes: a Node scanner over `app/ lib/ scripts/` for `.from('<t>')` followed by
  `.insert|.update|.delete|.upsert(`. Coverage was cross-checked by an independent grep count (1,042 vs 1,046).
* Masking: `NOT has_table_privilege('authenticated', oid, 'SELECT')` with column-level SELECT present → 28 tables.
* Volumes: `pg_stat_user_tables`, `pg_database_size`.
* Auth audit: `SELECT count(*) FROM auth.audit_log_entries` → 0.
