# NOROLE-SURFACE Step 0 — what a signed-in session holding no role can reach (2026-10-19)

**STOP GATE.** Read-only survey and grilling. No code edit, no migration, no live write. Waiting on Tim's answers to Q1–Q20 (§12).

Tags: **[M]** measured (file:line, a grep, or a named live query with its identity) · **[I]** inferred · **[R]** a standing ruling · **[D]** vendor documentation.

**Live readings** (all `BEGIN READ ONLY … ROLLBACK`, over the pooler as `postgres`, `rolbypassrls = true`):
- `signup-readings.sql` — `auth.users` (base table), 11:46:15 CST, `READ_OWN_EXIT=0`.
- `norole-reach-readings.sql` — part 1 catalog; part 2 reads **every** relation `authenticated` may SELECT (456: 286 tables, 170 views) twice: as `postgres` with no
  claims (the total) and as **`authenticated` with the JWT of a random uuid that has no account, no role, no employee** (RLS applies; `current_user_permissions()` = 0
  codes, `current_user_employee()` = null), one savepoint per relation; coverage asserted (≥ 200 relations or it raises). 11:50 CST, `READ_OWN_EXIT=0`.
- `role-code-readings.sql` — `roles` / `role_permissions` / `user_roles` base tables, 11:54:41 CST, `READ_OWN_EXIT=0`.
- `dependency-readings.sql` — catalog only (`pg_depend`, `pg_proc`, `pg_policies`): who inside the database reads the objects proposed for a predicate.
- Two small ad-hoc catalog reads quoted inline where used (issue-table policies, object `updated_at`, definer flags of reader functions).
- Public `GET /auth/v1/settings` with the anon key; Management API `GET /v1/projects/<ref>/postgrest` (exposed schemas).
- Code call sites: a read-only sub-agent sweep of `app/`, `lib/`, `scripts/` (grep / read only, no script run), checked against the files cited.

---

## Step 1 — sign-up closed (recorded: `docs/known-issues.md` `MES9-PUBLIC-SIGNUP-OPEN`, closed; `docs/fresh-install-checklist.md` step 6; commit `a6f03e3f`)

- **Opening check:** tree clean; after `git fetch`, `HEAD` = `origin/main` = `git ls-remote origin main` = `b1cd65a2ed3e736d9ef5b1102a2d840ad3fb4004`; no git command refused.
- **1.1** anon key → `https://wvywpohbwkiinmipmuku.supabase.co/auth/v1/settings` (11:45:44 CST): **`disable_signup: true`**, `mailer_autoconfirm: true` (no longer reachable —
  sign-up is closed), `anonymous_users: false`, only `email: true` among providers.
- **1.2** `auth.users` = **7**, 0 banned, 0 deleted, 0 anonymous, `auth.identities` 7 × `email`, newest created 2026-09-23, **0 created since MES-9 Step 0's reading**:
  admin@swm-os.test (admin) · chooer@evoltrya.test (finance) · fusheng@evoltrya.test (warehouse) · phua@evolytra.test (cto) · sandra@evoltrya.test (cco) ·
  tim@evoltrya.test (cfo) · vince@evoltrya.test (gm). All known, all enabled.
- **1.3** staff accounts are created by the service-role admin API: `app/settings/accounts/accountActions.ts:107` `admin.auth.admin.createUser({ … email_confirm: true … })`,
  `admin` from `createAdminClient()` (`:90`; `lib/supabase/admin.ts:22-35`, `SUPABASE_SERVICE_ROLE_KEY`). `disable_signup` governs the public `/signup` endpoint, not
  the admin API [D]. `signUp` appears 0 times in `app/` and `lib/` [M]. Not proved by creating an account (a live write outside this block).
- Nothing stopped step 3.

## Step 2 — Tim's MES-9 rulings recorded

`docs/forward-queue.md` (the MES-8b-2 item and the MES-group table: rows 15-0 NOROLE-SURFACE · 15a · 15b · 15c, old row 15 struck) and `docs/surveys/MES-9/STEP0-HANDBACK.md`
§15: Q1 three cuts · Q2 `supplier_portal` role via the hook replacing Q86, MES-9a opens with a live dry run of the hook, Q86 the fallback · Q4 / Q30 NOROLE-SURFACE first,
before MES-9a · Q12 build and prove on Free with throwaway suppliers, paid plan before the first real supplier account · Q23 no MFA in MES-9a · every other recommendation
accepted as stated (Q9 thereby closes SESSION-1 ① as decided — noted on that entry in `docs/known-issues.md`) · before the first real supplier account: domain (Q13), V38,
V39, V40, paid plan. Committed and pushed `b1cd65a2..a6f03e3f` "Sign-up closed + MES-9 rulings" (docs only, no file outside `docs/`, so no fresh-clone build).

---

## §0 · What grilling changed in NOROLE-SURFACE's scope

1. **The reachable surface is smaller and sharper than "≈1,100 objects", and it is now enumerated, not sampled** [M]. Of 456 relations `authenticated` may SELECT,
   a no-role session gets rows from **46**: 43 `USING (true)` tables, `company_profile_masked`, `document_relations`, and `storage.objects` (**38 of 40** objects, 13 buckets).
   It writes nowhere in `public` except its own `notification_reads` rows (every other write policy carries a permission predicate; 0 tables have RLS off). It
   **uploads into 13 buckets and updates / deletes in 4**. Of 549 non-trigger functions it may EXECUTE, **0 write without a permission or self check** (§1 a.3).
2. **The brief's list is right, and two neighbours belong with it**: `metal_price_indices` and `pricing_settings` (the same pricing family as `metal_prices`), and
   `permissions` (the code catalogue, read only on `/settings`). Q1.
3. **Step 0's "6 owner-rights views with no predicate" is really 1** [M]: `collection_promise_status` has none; `approval_log_masked` (`approval_log_readable`),
   `task_participant_directory` (`can_view_task`), `attendance_period_status` and `inbound_batch_valuation` (shells that RAISE `PERMISSION_DENIED`) gate through functions
   the regex did not name; `document_relations` is foreign-key metadata from `pg_constraint` (502 rows, no business data). §13.
4. **Nothing in the app reads `user_roles` / `roles` / `role_permissions` / `permissions` for every user** [M]: every session's codes come from
   `rpc('current_user_permissions')` (SECURITY DEFINER, `lib/permissions.ts:49-53`); every direct read is a `/settings/*` page behind `action.manage_permissions`. So these
   four close with **no loss for any of the 7 live roles** (Q3).
5. **No app code change is needed** [M + I]: every page that reads a proposed object is already behind the code proposed for it, and every caller-rights reader inside the
   database (`journal_activity_lines`, `index_period_average`, `metal_price_anomaly`, `reprice_split`, `trail_ref_label`, `overtime_other_approver_exists`, …) is reached only
   through SECURITY DEFINER callers or through pages gated by the same code (§2 e). The cut is one migration + mirrors + a gate verdict + fixtures — **the broken window has
   no old-app / new-database mismatch** (§9).
6. **Storage is in no mirror and in no install step** [M]: `db/platform-prelude.sql`, `db/gate.py`, `db/check_mirrors.py` contain 0 references to the storage schema
   (only `storage_locations`, a table); there is no `db/storage/`; `docs/fresh-install-checklist.md` mentions no bucket. **A fresh install from the repo today gets none of
   the 19 buckets and none of the 53 storage policies.** A storage baseline therefore needs a storage mirror (Q11).
7. **Three PDF routes clean up an orphan object that no policy lets them delete** [M]: `cod` / `po` / `traceability` routes call `storage.remove()` when recording the issue
   fails (`app/inbound/[id]/cod/pdf/route.tsx:209`, `app/purchasing/orders/[id]/pdf/route.ts:192`, `app/output/[id]/traceability/pdf/route.tsx:167`), but those buckets have
   no DELETE policy — the cleanup is a silent no-op today. Q9.
8. **The wall-display role is a second "no-role" shape** [M]: `floor_display` holds one data code and no module code; under the recommended predicates it reaches none of
   these objects either. The permanent check should enumerate both identities (Q12, Q20).
9. **Size: ≈ 2 h 20 – 5 h 20** (§11), one cut, not split.

---

## §1 · (a) The complete list a no-role session reaches today

### a.1 · Relations with rows (as the no-role JWT; totals as `postgres` without claims) — 46 of 456 examined

| Object | Kind | Rows no-role / total | Policy | In this cut? |
|---|---|---|---|---|
| `user_roles` | table | 9 / 9 | `USING (true)` | **yes** (Q3) |
| `roles` | table | 14 / 14 | `USING (true)` | **yes** |
| `role_permissions` | table | 388 / 388 | `USING (true)` | **yes** |
| `permissions` | table | 85 / 85 | `USING (true)` | **yes** (Q1) |
| `metal_prices` | table | 12 / 12 | `USING (true)` | **yes** (Q4) |
| `metal_price_indices` | table | 2 / 2 | `USING (true)` | **yes** (Q1, Q4) |
| `pricing_settings` | table | 1 / 1 | `USING (true)` | **yes** (Q1, Q4) |
| `accounts` (chart of accounts) | table | 46 / 46 | `USING (true)` | **yes** (Q5) |
| `storage.objects` | table | **38 / 40** (cn 1 · cod 2 · company-assets 1 · customer-att 2 · finance-att 4 · invoice 4 · material-att 2 · po 11 · qt 3 · shipment 3 · so 2 · supplier-att 2 · traceability 1; the 2 avatars are own-only) | 35 bucket-only policies | **yes** (§3) |
| `company_profile_masked` | owner view | 1 / 1 | base `company_profile` `USING (true)` (the table itself has no table-level SELECT grant) | no — Q16 |
| `document_relations` | owner view | 502 / 502 | none; body reads `pg_constraint` / `document_types` | no — Q17 |
| `hr_settings` 1 · `laboratories` 1 · `leave_types` 13 · `public_holidays` 26 · `currencies` 3 · `document_types` 63 · `document_type_exceptions` 49 · `document_relation_exceptions` 9 · `home_greetings` 72 · `festival_doodles` 23 · `review_rating_scale` 4 · `kpi_score_rubric` 6 · `shifts` 2 · `substances` 9 · `certificate_types` 9 · `waste_classifications` 2 · `battery_chemistries` 8 · `handover_item_types` 1 · `deep_discharge_judgements` 3 · `inbound_chemistry_certainties` 3 · `inbound_safety_states` 5 · `inbound_source_reasons` 4 · `loss_categories` 7 · `loss_metal_fates` 3 · `material_forms` 19 · `material_kinds` 5 · `material_size_formats` 5 · `material_sources` 3 · `operation_kinds` 2 · `operation_types` 9 · `operation_type_input_forms` 23 · `operation_type_output_forms` 28 · `operation_type_safety_states` 14 · `output_batch_purposes` 2 · `output_batch_states` 3 | 35 tables | all = no-role (all rows) | `USING (true)` | no — Q16 |

Plus rows that are **empty today but open by shape**: `collection_promise_status` (owner view, no predicate; 0 rows only because `collection_promises` is empty — **yes**, Q6).
Self-row policies (`employees` own row, leave / payroll / medical / training own rows, reviews as subject or reviewer, `notification_reads` own) return 0 for the probe
identity (no employee, no account) and are correct by design for a real account.

**Refused** (not reached): the other 406 relations returned 0 with rows present, or raised (`attendance_period_status`, `bank_reconciliation_record`,
`bank_reconciliation_status`, `inbound_batch_valuation` → `P0001 PERMISSION_DENIED|<code>`). `storage.buckets` 0 visible.

### a.2 · Writes

- **`public` tables:** `authenticated` holds INSERT / UPDATE / DELETE on 315 of 321 tables, RLS on all 321 (`TBL_RLS_OFF` 0 lines). Every INSERT / UPDATE / DELETE / ALL policy
  carries a permission predicate, **except** `notification_reads` (own `user_id = auth.uid()` — correct). Policies whose predicate is OR-ed (`TBL_WRITE_DOOR`, `OR_BRANCH` lines:
  assay results, tasks, task nodes / participants) OR together permission codes or `can_*_task` functions that themselves start from `has_permission('module.tasks.*')`
  (`db/functions/can_view_task.sql:7`, `can_edit_task.sql:7`) — none passes with zero codes. **0 no-role write doors in `public`.**
- **Storage:** INSERT into **13** buckets (cn, cod, customer-att, finance-att, invoice, material-att, po, qt, shipment, so, statement, supplier-att, traceability);
  UPDATE and DELETE in **4** (customer-, finance-, material-, supplier-attachments); own avatar only in `avatars`.
- **Not reachable through the API, named so a green line is not over-read:** sequences (53, USAGE + UPDATE → `setval`) and TRUNCATE (315 tables, bypasses RLS) need a SQL
  connection, which `authenticated` does not have — PostgREST exposes only `public, graphql_public` (Management API `/postgrest`, `db_schema`), `pg_graphql` is absent, the
  realtime publication carries 0 tables. `extensions.pg_stat_statements` is SELECT-granted but its schema is not exposed. `storage.s3_multipart_*` / `buckets_*` are
  reached only through the Storage API, which applies the `storage.objects` policies.

### a.3 · Functions (549 non-trigger functions EXECUTE-able by `authenticated`)

| Class (by body) | Count | What a no-role session gets |
|---|---|---|
| invoker | 111 | bounded by the RLS of what they touch (a.1, a.2) |
| definer with a permission check (`has_permission` / `require_*` / …) | 415 | refusal |
| definer whose only judge is `auth.uid()` / `current_user_employee()` | 13 | its own rows (`my_*`, `export_my_personal_data`, `current_user_*`, `acknowledge_review`, `save_self_assessment`) — and 4 PO writers (`amend` / `cancel` / `close` / `reopen_purchase_order`) that call `assert_po_manager` (`db/functions/assert_po_manager.sql`; raiser or category code) → refusal |
| definer with no recognised check | 10 | `apply_payment_term_template` → `assert_po_manager` → refusal; `cod_verification(token)` (the anon `/verify/cod` path, by design); 8 read-only status helpers that answer about a uuid the caller must already know: `approvals_enabled`, `contract_terms_lock_reason`, `journal_entry_reversal_route`, `payroll_period_frozen`, `period_close_floor`, `receipt_price_open`, `review_approval_code`, `storage_licence_in_force` |

The classification is a regex over bodies [M]; it mis-files callers of `assert_*` helpers (the 5 PO functions), so every non-"permission check" row was read by hand. The
8 helpers are Q17.

---

## §2 · (b, d, e, f) For each object: who uses it, the proposed predicate, and the 7 roles

Codes each live role holds: `role-code-readings.sql` `HOLDS` lines. "Loss" means a legitimate path a role uses today that the predicate would close.

### Role × proposed predicate (Y = the role holds a code that passes)

| Object · operation | Proposed predicate | admin | cco | cfo | cto | finance | gm | warehouse |
|---|---|---|---|---|---|---|---|---|
| `user_roles` all rows | `action.manage_permissions` **OR `user_id = auth.uid()`** | Y | own | own | own | own | own | own |
| `roles` · `role_permissions` · `permissions` | `action.manage_permissions` | Y | – | – | – | – | – | – |
| `metal_prices` | any of `module.pricing.view` · `module.suppliers.view` · `module.inventory.view` · `module.materials.view` | Y | Y | Y | Y | Y | Y | Y |
| `metal_price_indices` | any of `module.pricing.view` · `module.suppliers.view` · `action.metal_prices` | Y | Y | Y | Y | Y | Y | Y |
| `pricing_settings` (read) | any of `module.pricing.view` · `module.inventory.view` | Y | Y | Y | Y | Y | Y | Y |
| `accounts` | `module.finance.view` | Y | Y | Y | Y | Y | Y | – |
| `collection_promise_status` | `module.finance.view` in the view body | Y | Y | Y | Y | Y | Y | – |

**Every "–" is a role that has no page, action or function reading that object today** (below), so **loss = 0 for all 7 roles**. `floor_display` (0 holders) passes none.

### d · `user_roles`, `roles`, `role_permissions`, `permissions`

- **What every signed-in session needs:** its own codes — `rpc('current_user_permissions')`, SECURITY DEFINER, joins the three tables as owner
  (`db/functions/current_user_permissions.sql`; `lib/permissions.ts:49-53`; callers: root `app/layout.tsx:49,54`, `app/settings/layout.tsx`, `app/page.tsx:130`, every page guard,
  `lib/floorDisplay.ts:20`). `has_permission` is `p_code = ANY (current_user_permissions())`, also definer [M, `FN_HAS_PERMISSION`]. **Unaffected by any predicate on the tables.**
- **Direct reads** (all session client, all behind `action.manage_permissions`): `app/settings/roles/page.tsx:34,38,39` (guard `:25`) · `app/settings/roles/[id]/page.tsx:31,36,39,40`
  (`:22`) · `app/settings/accounts/page.tsx:31` (`:20`) · `app/settings/accounts/accountActions.ts:98` (`canManagePermissions()` `:73`) · `app/settings/approvals/page.tsx:79`
  (`FN.approvals` `:67`) · `app/settings/reference/page.tsx:43,47,48` (`:34`). Writes: `app/settings/accountsActions.ts:122,144,155` (no app guard — RLS write policy is
  `action.manage_permissions`; unchanged).
- **In the database:** owner views `user_directory`, `pending_values`, `deleted_records` (read as owner — unaffected); invoker `trail_subject_members` /
  `trail_prelog_sources` / `trail_subjects` name the tables as strings only (no FROM); `overtime_other_approver_exists` (invoker, not executable by `authenticated`) and
  `trail_row_visible` are reached only from definer callers (`create_overtime_batch`, `submit_overtime_batch`, `record_trail`, `change_log_rows`) [M].
- **Own `user_roles` row:** no current reader needs it (the app uses the RPC); recommended anyway so a session can always see its own grant (the self-row shape every HR table
  already has). Q3.

### e · Metal prices and the chart of accounts

**`metal_prices`** — readers: `app/tools/pricing/metal-prices/page.tsx:125,137` · `formulas/new/page.tsx:41` · `formulas/[id]/edit/page.tsx:94` (`module.pricing.view`);
`…/metal-prices/bulk/page.tsx:68` · `[id]/edit/page.tsx:48` (`action.metal_prices`; finance and admin, both hold `module.pricing.view`); `app/contracts/page.tsx:93`
(`module.suppliers.view`); `app/inventory/page.tsx:173` · `app/inventory/output/[materialId]/page.tsx:81` (`module.inventory.view`); `app/settings/dictionaries/page.tsx:147`
(a HEAD count from the substances section, `module.materials.view`). In the database: owner views `fx_rate_gaps`, `operations_arms_all`; invoker `index_period_average`
(callers `calculate_metal_price_from_terms`, `price_exposure_report` — definer — and `sale_settlement_compute`, invoker, called only by definer `record_sale_settlement`),
`metal_price_anomaly` / `preview_metal_price_anomalies` (invoker, called from the `action.metal_prices` actions `…/new/actions.ts:78`, `[id]/edit/actions.ts:67`,
`bulk/actions.ts:68`). **Effect on every page: none** — each is already behind one of the four codes. **`metal_price_indices`**: `indexQuery.ts:14` (pricing pages and
`action.metal_prices` pages), `metal-prices/page.tsx:138` embed, `app/contracts/[id]/page.tsx:84` (`module.suppliers.view`). **`pricing_settings`**: read
`metal-prices/page.tsx:149` (pricing), `app/inventory/page.tsx:171`, `inventory/output/[materialId]/page.tsx:79` (inventory); written by
`thresholdActions.ts:37` (RLS update policy already reads `metal_prices`-family permission — unchanged).
*Not decided here, named:* warehouse reads raw metal prices through `/inventory` while it lacks `data.view_prices`; whether that is right is a price-visibility question
(AGENTS.md standing decision 1), not a no-role one. Q4.

**`accounts`** — readers: all `module.finance.view` pages — `app/finance/journal/page.tsx:156`, `journal/new/page.tsx:23`, `trial-balance/page.tsx:75`,
`journal/[id]/page.tsx:88`, `bank/page.tsx:109`, `expenses/page.tsx:121`, `expenses/new/page.tsx:29,95`, `expenses/[id]/page.tsx:106`, `assets/page.tsx:193`,
`claims/page.tsx:50`. In the database: owner views `bank_unmatched_journal_lines`, `batch_margin`, `fx_month_end_readiness`; invoker `journal_activity_lines`, reached only from
definer callers (`account_ledger`, `balance_sheet`, `pnl_statement`, `bank_book_balance_asof`, `bank_reconciliation_rows`, `gl_control_reconciliation`,
`inventory_control_reconciliation`, `journal_export_lines`, `preview_revalue_foreign_balances`, `remit_wht_internal`) and invoker `reprice_split` (callers
`reprice_inbound_batch`, `preview_reprice_inbound_batch` — definer); `trail_ref_label` (invoker, not executable, reached through definer `record_trail` / `change_log_rows`);
19 definer functions (posting, spare-part issue to 6800, …) read as owner. **Warehouse: no page or callable path reads `accounts` as warehouse** — loss 0. Q5.

### f · `collection_promise_status`

Owner view (`postgres`, bypasses RLS), body joins `collection_promises` · `collection_chases` · `customers` with **no predicate**, SELECT-granted to `authenticated`; base
tables are `module.finance.view` [M, `ISSUE_SEL` lines]. **0 call sites in `app/`, `lib/`, `scripts/`** [M]. Proposed: `WHERE has_permission('module.finance.view')` in the body
(the same predicate its base tables carry). Effect: none on any page; a finance reader sees the same rows; a reader without the code sees 0 instead of every promise —
the base tables' answer. Zero rows here is a real "not permitted" rather than an owned NULL, so a WHERE (not a RAISE shell) is enough. Q6.

---

## §3 · (c) Storage: each private bucket, its codes, and how the policy reads the path

**Who issues and who reads each document is already decided in the database** — the issue table's SELECT policy and the `record_*_issue` function's check [M]. The
proposal copies those codes onto the bucket, so storage says exactly what the record says. Object paths are always `<record id>/<sha256 or uuid>[-name].<ext>` and the
table column holding them is named below (sub-agent sweep, each route cited).

| Bucket (objects) | Path · column | Read (= issue table SELECT) | Upload (= writer's check) | Update | Delete |
|---|---|---|---|---|---|
| cn-documents (1) | `${creditNoteId}/${sha}.pdf` · `cn_issues.file_path` | `module.finance.view` | `module.finance.edit` (`record_cn_issue`) | none | none (route never removes) |
| cod-documents (2) | `${codId}/${uuid}.pdf` · `cod_issues.file_path` | `action.issue_cod` | `action.issue_cod` (`record_cod_issue`, `issue_cod`) | none | **unrecorded only, by `action.issue_cod`** (Q9) |
| invoice-documents (4) | `${invoiceId}/${sha}.pdf` · `invoice_issues.file_path` | `module.finance.view` (route also requires `data.view_banking`, `route.ts:197`) | `module.finance.edit` (`record_invoice_issue`) | none | none |
| po-documents (11) | `${poId}/${uuid}.pdf` · `po_issues.file_path` | `module.purchasing.view` | `module.purchasing.edit` (`record_po_issue`) | none | **unrecorded only, by `module.purchasing.edit`** (Q9) |
| qt-documents (3) | `${quoteId}/${sha}.pdf` · `qt_issues.file_path` | `module.sales.view` | `module.sales.edit` | none | none |
| shipment-documents (3) | `${shipmentId}/${sha}.pdf` · `shipment_issues.file_path` | `module.sales.view` OR `action.ship_goods` | `action.ship_goods` | none | none |
| so-documents (2) | `${soId}/${sha}.pdf` · `so_issues.file_path` | `module.sales.view` | `module.sales.edit` | none | none |
| statement-documents (0) | `${statementId}/${sha}.pdf` · `statement_issues.file_path` | `module.finance.view` | `module.finance.edit` | none | none |
| traceability-documents (1) | `${outputBatchId}/${uuid}.pdf` · `traceability_report_issues.file_path` | `module.sales.view` OR `module.processing.view` | `module.sales.edit` OR `module.processing.edit` (`record_traceability_report_issue:15`) | none | **unrecorded only, by the upload codes** (Q9) |
| material-attachments (2) | `${materialId}/${uuid}-${name}` · `material_attachments.storage_path` | `module.materials.view` | `module.materials.edit` | **dropped** (Q8) | **unrecorded only, by `module.materials.edit`** |
| supplier-attachments (2) | `${supplierId}/${uuid}-${name}` · `supplier_attachments.storage_path` | `module.suppliers.view` | `module.suppliers.edit` | dropped | unrecorded only, by `module.suppliers.edit` |
| customer-attachments (2) | `${customerId}/${uuid}-${name}` · `customer_attachments.storage_path` | `module.customers.view` | `module.customers.edit` | dropped | unrecorded only, by `module.customers.edit` |
| finance-attachments (4) | `${parentId}/${uuid}-${name}` · `finance_attachments.file_path` | `module.finance.view` | `module.finance.edit` | dropped | unrecorded only, by `module.finance.edit` |
| company-assets (1) | `logo/${uuid}.png\|jpg` · `company_profile.logo_path` | any of the codes of the routes that print the logo (Q10) | `action.finance_settings` (exists) | `action.finance_settings` (exists) | `action.finance_settings` (exists) |

Unchanged (already predicate-gated): `avatars` (own), `capture-photos`, `coa-documents`, `compliance-documents`, `supplier-statement-documents`. **Total after the cut: 0
bucket-only policies** (53 → 52 storage policies: 35 dropped; 34 created — 14 read · 13 upload · 7 delete-unrecorded; 18 untouched).

**How the policy reads the path:** read and upload are decided by **bucket + code** only, the shape the five newer buckets already use — the path is not parsed, because
the record table, not the path, is what says which document exists, and every route reads the record under RLS before it downloads. The path is read in exactly one place,
**delete**: `NOT EXISTS (SELECT 1 FROM <issue / attachment table> i WHERE i.<column> = objects.name)` — the `coa-documents` pattern (`remove unrecorded by issue_coa`) — so an
object that has become a record can never be deleted through Storage, and the routes' orphan cleanup finally works. The alternative, read = `EXISTS` of a visible record row
(record-backed), is exact but costs a sub-query per object and differs from the five newer buckets (Q7).

**Loss check** (computed from `role-code-readings.sql` `HOLDS`; Y = holds a passing code):

| Bucket · op | admin | cco | cfo | cto | finance | gm | warehouse |
|---|---|---|---|---|---|---|---|
| cn / invoice / statement / finance-att · read | Y | Y | Y | Y | Y | Y | – |
| cn / invoice / statement / finance-att · upload (finance.edit) | Y | – | – | – | Y | – | – |
| cod · read + upload | Y | – | – | – | – | – | Y |
| po · read / upload | Y / Y | Y / Y | Y / – | Y / Y | Y / Y | Y / – | Y / – |
| qt / so · read / upload | Y / Y | Y / Y | Y / – | Y / – | Y / – | Y / – | – / – |
| shipment · read / upload | Y / Y | Y / – | Y / – | Y / – | Y / – | Y / – | Y / Y |
| traceability · read / upload | Y / Y | Y / Y | Y / – | Y / Y | Y / – | Y / – | Y / – |
| material-att · read / write | Y / Y | Y / Y | Y / – | Y / Y | Y / Y | Y / – | – / – |
| supplier-att · read / write | Y / Y | Y / Y | Y / – | Y / Y | Y / Y | Y / – | Y / Y |
| customer-att · read / write | Y / Y | Y / Y | Y / – | Y / Y | Y / Y | Y / – | – / – |
| company-assets · read | Y | Y | Y | Y | Y | Y | Y |

Every bucket's "–" roles are roles that cannot read the issue table today, so the
route already refused them before touching storage. Upload "–" roles are refused by `record_*_issue` today. **Upserts** (`cn`, `invoice`, `qt`, `shipment`, `so`, `statement`
routes upload with `upsert: true`): their buckets have no UPDATE policy today, so behaviour is unchanged. **Updates:** 0 of 38 objects outside `avatars` were ever updated
(`updated_at > created_at`), and no call site updates an object [M] — the 4 UPDATE policies serve nothing.

---

## §4 · (g) The permanent check: verdict 7 【无角色面】

A new script `db/check_norole.py`, called by `db/gate.py`, exit **7** on failure (the verdict-6 shape: "anon reaches more" and "a role-less staff session reaches more" are
two diseases, two fixes). It enumerates, every run, from the catalog and from a session:

1. **Rows:** every relation `authenticated` may SELECT, read as a no-role JWT **and as a `floor_display`-only JWT** (Q20) — any relation with rows must be in the baseline
   (on live; on the rebuild after fixtures seed it is the same loop over an empty database, so the shape lines below carry the weight there).
2. **Shapes** (both live and rebuild): every policy (public **and** storage) that applies to `authenticated` / `public` with no permission predicate in its expression;
   every table with an `authenticated` grant and RLS off; every owner-rights view readable by `authenticated` whose body names no predicate function; every SECURITY DEFINER
   function executable by `authenticated` whose body names no check. The predicate-function list is one constant (`has_permission`, `has_any_permission`,
   `require_permission`, `require_*`, `current_user_permissions`, `approval_log_readable`, `can_view_task`, `assert_*`, …) — a new gating helper must be added there or its
   callers are named.
3. **Storage objects** visible to the no-role JWT (live only — storage is not in the rebuild): must be 0 outside the baseline (`avatars` own).

Compared with `db/norole-surface-baseline.tsv` (`kind · object · reason`, every line with a written reason): **live ⊄ baseline → red, naming the object**; baseline ⊄ live → named,
not red (a deliberate narrowing must not hold the gate red — the `check_grants.py` rule). **Fault cells, both ways:** (i) in a rolled-back transaction on the rebuild, create a
probe table with `GRANT SELECT … TO authenticated` and a `USING (true)` policy → must be named (always-on self-test, the `viewwrite` probe shape); (ii)
`GATE_NOROLE_FAULT=policy` on the rebuild: add `USING (true)` to `accounts` → red naming it; (iii) remove one baseline line → red; (iv) always-on: an unreadable baseline
path raises (never read as empty); a blinded query (universe 0) is red. **Coverage asserted:** relations examined ≥ 400, policies ≥ 400, functions ≥ 500 — "a zero must be a
measurement".

Supabase's default ACL keeps granting every future table / view / function to `authenticated` (Step 0 `DEFAULT_ACL`); this verdict is what turns that into a named red line
instead of a silent door.

---

## §5 · (h) Fixtures, approvals, audit trails, change log, masking

- **Fixture 274** (rebuild): sessions with no role, `floor_display` only, each relevant code alone, and `action.manage_permissions`: no-role reads 0 rows of the nine objects
  and its own `user_roles` row; each code in each predicate opens exactly its object; `collection_promise_status` empty without `module.finance.view` with seeded promises;
  the definer path (`current_user_permissions`, `has_permission`, `journal_activity_lines` via `balance_sheet`, `index_period_average` via `calculate_metal_price_from_terms`)
  still answers for a session that cannot read the tables. Injections: put back `USING (true)` per object → the named arm red. **MES-9's planned fixtures 274–276 become 275–277.**
- **Live fixture 266** (`db/live-fixtures/`, read-only, run by the gate against live — storage is not in the rebuild): each bucket's policies equal the table in §3 (by text),
  a no-role JWT lists 0 objects outside its own avatar, a clone of each code reads / is refused per bucket.
- **Approvals:** untouched; stay ON, finance / cfo / 1,000 [R].
- **Audit trails / change log:** no new table, no new trail subject; policy changes are DDL (not change-logged) and are recorded by the migration, the storage mirror (Q11) and
  this verdict. Exclusions stay at 8.
- **Masking:** no column changes; `accounts`, `metal_prices` carry no masked columns; the GL's lack of masking stays accepted (AGENTS.md decision 1).
- **Action ⇒ view rule (MES-5b-1) / no view grants a write (F16):** no code is granted or moved; no view gains a grant — both hold unchanged.

## §6 · Not changed, named

The 35 `USING (true)` reference tables, `company_profile_masked`, `document_relations` (Q16, Q17), the 8 status helpers (Q17), sequences / TRUNCATE / `pg_stat_statements`
(not API-reachable, §1 a.2). Each becomes a baseline line with its reason. Observed but outside this cut: several server actions have no app-side guard and rely on RLS
(`app/settings/accountsActions.ts:122,144,155`, metal-price and dictionary actions) — RLS refuses them for a no-role session today (0 write doors), so nothing is open; not changed.

## §7 · Supplier portal

Unaffected by construction: MES-9a's `supplier_portal` role is not a member of `authenticated` (Q2 [R]). The portal's own storage policies (`TO supplier_portal` on `po-documents`,
`cod-documents`, `supplier-statement-documents`) are additive and come in MES-9b.

## §8 · Platform

Free plan; no paid feature needed. Backup gate before the migration as usual (`~/evoltrya-backups/backup.sh`, `BACKUP_EXIT=0` from its own log). Note from this survey:
the Management API's `GET /v1/projects/<ref>/postgrest` returns the project's **JWT secret** in its body; it was read once for `db_schema`, not written anywhere. A gate or
script that reads that endpoint must strip it.

## §9 · (i) Migration shape and the broken window

One migration `db/migrations/2026-10-XX-norole-surface.sql`, COMMIT → ROLLBACK dry run on live first, inside it a self-proof that reads each object as a clone of each of the 7
roles' code sets and as a no-role JWT (READ after the DDL, inside the same rolled-back transaction):
`DROP POLICY` ×35 on `storage.objects`, `CREATE POLICY` 34 (§3) · replace the SELECT policy on `user_roles`, `roles`, `role_permissions`, `permissions`, `metal_prices`,
`metal_price_indices`, `pricing_settings`, `accounts` · `CREATE OR REPLACE VIEW collection_promise_status` with the predicate (columns identical; `REVOKE ALL … GRANT SELECT`
re-stated per F16). Mirrors: 8 table mirrors, 1 view mirror, the new storage mirror (Q11). No function changes. No back-fill.

**What each role might lose during the window:** nothing that is in use — **the app needs no change**, so old and new code are identical and the window is "new database +
the same app". The only exposure is a reader this survey missed; the dry run's per-role reads and fixture 274 are the guard. **Order:** code-free → docs, mirrors, gate,
fixtures, build, `gate --offline` → backup → dry run → apply → full gate (verdict 7 green against live) → live proof → fresh-clone build → push.

## §10 · Live proof (after apply)

One throwaway no-role account and one throwaway clone per live role (the `mintThrowaway` path, prefix `noroleprobe`), over HTTP against the deployed app's Supabase:
PostgREST reads of the nine objects (no-role: 0 rows; each clone: the rows its codes allow); Storage list / download / upload / remove per bucket (no-role: 0 / 403; clones per
§3; an upload by a clone whose code passes, then its removal as unrecorded); the pages in §2 e open with data for their roles. Cleanup by plan, residue read back.

## §11 · (j) Time estimate

**Calibration [M]** (sub-agent, read-only, transcripts `~/.claude/projects/-Users-timchen/*.jsonl`, the MES-7a classifier unchanged; method re-verified on MES-7b-2 and MES-7b-1,
reproducing the recorded 2h33 / 1h16 / 1h17 and 2h34 / 1h25 / 1h09): MES-8a **2h58** (floor 1h36 · work 1h21), MES-8b-1 **2h41** (1h19 · 1h22), MES-8b-2 **2h04** (1h31 · 0h32;
one 43 h gap ending in a `/login` excluded). Over all **22** measured cuts MES-1 → MES-8b-2: median active **2h42**, median floor **1h24**, actual work ÷ estimated work-low
**0.40**; last five (7b-1 · 7b-2 · 8a · 8b-1 · 8b-2): median floor **1h25**, ratio **0.19** (0.14–0.19). (MES-9 Step 0 §11's "last five 1h40" was stale; it is 1h25.)

| Part | Raw work |
|---|---|
| Migration (35 storage policies → 34, 8 table policies, 1 view) with its in-transaction per-role self-proof | 1h00 – 1h45 |
| Storage mirror + fresh-install step + rebuild/prelude note (Q11) | 0h30 – 1h00 |
| Verdict 7: script, baseline with reasons, gate hookup, four fault cells | 2h00 – 3h00 |
| Fixture 274 + live fixture 266 + injections | 1h00 – 1h45 |
| Live HTTP proof (no-role + 7 clones, PostgREST + Storage) | 1h00 – 1h30 |
| **Total raw** | **5h30 – 9h00** |

**Process floor: 1h15 – 1h45** (median 1h24 / last five 1h25; includes backup, live dry run, full gate, live proof run, fresh-clone build; no smoke or layout survey —
no render change). **Work, calibrated: 1h03 (×0.19) – 3h36 (×0.40).** **Floor + work: 2 h 18 – 5 h 21.**

---

## §12 · Every open question, with a recommended answer and its evidence

One round: none depends on another's answer except Q12 (needs Q11 for the storage half) and Q20 (needs Q12) — both have a recommended answer that holds either way.

❓ **Q1 — Scope.** The brief's set (35 bucket-only storage policies; `user_roles`, `roles`, `role_permissions`; metal prices; the chart of accounts;
`collection_promise_status`) plus three neighbours: `permissions` (code catalogue, read only on `/settings`), `metal_price_indices` and `pricing_settings` (same pricing family).
➡️ **These 9 relations + 35 storage policies; everything else in §6 stays and is baselined with a reason.**

❓ **Q2 — Predicate style.** (a) per object, the union of the codes of the pages / functions that read it today (no loss by construction, §2); (b) one "staff session"
predicate (holds any code) for everything. ➡️ **(a)** — it is least privilege, it matches how every other policy in the schema is written, and §2 shows no role loses a path.

❓ **Q3 — `user_roles`, `roles`, `role_permissions`, `permissions`.** The app reads its own codes only through the definer RPC; every direct read is behind
`action.manage_permissions` (§2 d). ➡️ **`user_roles`: `action.manage_permissions` OR own rows (`user_id = auth.uid()`); `roles`, `role_permissions`, `permissions`:
`action.manage_permissions` only.** Loss: none (admin is the only holder and the only reader).

❓ **Q4 — Metal prices.** ➡️ **`metal_prices`: any of `module.pricing.view` · `module.suppliers.view` · `module.inventory.view` · `module.materials.view`;
`metal_price_indices`: any of `module.pricing.view` · `module.suppliers.view` · `action.metal_prices`; `pricing_settings` read: any of `module.pricing.view` ·
`module.inventory.view`.** All 7 roles keep every page (§2 e). Whether warehouse should see raw metal prices on `/inventory` without `data.view_prices` is registered as a
separate price-visibility question (`NOROLE-WAREHOUSE-RAW-METAL-PRICES`), not changed here.

❓ **Q5 — Chart of accounts.** ➡️ **`module.finance.view`.** Warehouse is the only live role without it and reads `accounts` on no page and through no caller-rights path
(§2 e). Account names inside trails are resolved by definer code (`trail_ref_label` via `record_trail` / `change_log_rows`), so trails keep their labels.

❓ **Q6 — `collection_promise_status`.** ➡️ **`WHERE has_permission('module.finance.view')` in the view body** (the base tables' predicate; 0 call sites; a WHERE, not a RAISE
shell — no owned NULL).

❓ **Q7 — How a storage policy decides.** (a) bucket + the record's code (the five newer buckets' shape); (b) read = `EXISTS` of a record row the caller can see.
➡️ **(a)**, with the path read only for delete (unrecorded objects) — §3.

❓ **Q8 — Storage UPDATE on the 4 attachment buckets.** 0 objects ever updated; no call site updates. ➡️ **Drop them; no bucket outside `avatars` and `company-assets`
keeps an UPDATE policy** (documents are frozen; upsert routes already have none).

❓ **Q9 — Storage DELETE.** Today: any signed-in session deletes any attachment; the `cod` / `po` / `traceability` routes' orphan cleanup silently no-ops (no DELETE policy).
➡️ **Delete = "unrecorded objects only, by the upload code" on the 4 attachment buckets and on `cod-documents`, `po-documents`, `traceability-documents`** (the `coa-documents`
pattern); none on the 6 document buckets whose routes never remove. A recorded document or attachment can then never be deleted through Storage.

❓ **Q10 — `company-assets` read (the logo).** It is printed by PDF routes that warehouse, sales and finance readers all use. ➡️ **Any of `module.finance.view` ·
`module.purchasing.view` · `module.sales.view` · `action.ship_goods` · `action.issue_cod` · `module.processing.view` · `module.output.view` · `module.compliance.view`** —
every live role holds one; a no-role or display-only session does not.

❓ **Q11 — Put storage into the repo.** A fresh install from the repo today gets no buckets and no storage policies (§0.6). ➡️ **Yes, in this cut: one mirror
`db/storage/buckets-and-policies.sql` (19 buckets, every policy), a fresh-install checklist step that applies it, and verdict 7 comparing live with it (live-only, the
verdict-6 precedent). The rebuild keeps not modelling the storage schema (prelude unchanged).**

❓ **Q12 — The permanent check.** ➡️ **Verdict 7 【无角色面】 (`db/check_norole.py`, exit 7), baseline `db/norole-surface-baseline.tsv` with a reason per line, live ⊄
baseline → red, four fault cells and coverage floors as §4; it runs in the full gate, and its shape half also in `--offline`.**

❓ **Q13 — Fixtures.** ➡️ **Fixture 274 (rebuild) + live fixture 266 (storage, read-only) as §5; MES-9's fixtures renumber to 275–277.**

❓ **Q14 — Live proof.** ➡️ **As §10: one no-role throwaway + one clone per live role, PostgREST + Storage, cleanup by plan, residue read back; no real account touched.**

❓ **Q15 — Order and window.** ➡️ **One migration, no app code; dry run (with per-role reads) → apply → gate → live proof → push; window = migration → deploy of a
docs-and-mirrors commit, nothing in use expected to break.**

❓ **Q16 — The other 35 `USING (true)` reference tables and `company_profile_masked`.** They are vocabularies (forms, kinds, states, holidays, leave types, greetings,
company name / address) read by many roles' pages and by `/me` and `/` for any employee (`app/me/page.tsx:165,258`, `lib/homeGreeting.ts:148`, `lib/festivalDoodle.ts:77`,
`app/tools/calendar/sources.ts:160`). ➡️ **Stay readable by any signed-in session; one baseline line each, reason "reference vocabulary, no money / people / security
data".** (Alternative: "holds any code" for all of them — +1 h raw, no benefit once sign-up is closed.)

❓ **Q17 — `document_relations` and the 8 definer status helpers.** ➡️ **Stay; baselined** — `document_relations` is foreign-key metadata (no rows of business data); the
helpers answer one fact about a uuid the caller must already hold, and a no-role session can enumerate none.

❓ **Q18 — `cod_verification(token)` and `notification_reads`.** ➡️ **Stay; baselined** (the public COD verification path by design; own notification marks).

❓ **Q19 — Approvals, change log, masking.** ➡️ **No change** (§5): approvals ON, finance / cfo / 1,000; exclusions 8; no masked column.

❓ **Q20 — Is a `floor_display`-only session checked as "no role"?** It holds `data.view_floor_board` only and passes none of the proposed predicates. ➡️ **Yes: verdict 7
and fixture 274 run both identities; the display's baseline = the no-role baseline + `floor_board()`.**

---

## §13 · Assertions measured and found false or imprecise

1. MES-9 Step 0 §0.3: "170 readable views (6 owner-rights with no predicate in their body)" — **1** has none (`collection_promise_status`); 4 gate through functions the regex
   did not list; `document_relations` is catalog metadata (§0.3).
2. MES-9 Step 0 §0.3: "787 functions executable by `authenticated`" — true including triggers; **549** non-trigger functions are callable, and none writes for a no-role
   session without a check (§1 a.3).
3. MES-9 Step 0 §11: "last five 1h40" — stale; **1h25** (§11).
4. Brief: "35 storage policies letting any signed-in session read 14 private buckets, upload into 13, and update or delete in 4; a no-role session reading 38 of 40 stored
   files, user_roles, roles, role_permissions, metal prices and the chart of accounts" — **true** (re-measured, §1). Incomplete by three neighbours (§0.2).
5. Brief: "collection_promise_status with no predicate" — **true**; its 0 rows are an empty base table, not a refusal.
6. AGENTS.md "存储桶与它的策略【不在镜像里】" — still **true** (0 references in prelude / gate / mirrors), and it extends to installs: the checklist creates no bucket (§0.6).
7. `lib/supabase/admin.ts:4` comment "只用于 auth.admin.*(目前只有邀请)" — imprecise: it is used for `createUser`, `deleteUser`, `updateUserById` (`accountActions.ts`), no
   invitation exists (C-1). Not changed (code comment; no code edits in this block).
8. Zero found false among the brief's other facts (7 accounts; approvals finance / cfo / 1,000 — not re-read this block beyond the account list).

## §14 · Stop

No code edits and no migrations. Waiting on Tim's answers to Q1–Q20.
