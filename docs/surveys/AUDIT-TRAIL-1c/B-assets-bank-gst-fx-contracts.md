# AT-1c survey B — assets & equipment (finance), bank, GST, FX, packs, contracts

Survey date 2026-10-03. Read-only: no repo edits, no DB writes.
Every live figure was read with the Supabase Management API (`POST /v1/projects/wvywpohbwkiinmipmuku/database/query`). It runs as
**`postgres`, `rolbypassrls = true`** (measured: `select current_user, rolbypassrls` → `postgres | true`). Only base tables were read, and every statement was a SELECT.
The change log began at `2026-09-28 23:58:11+08` (measured: `change_log_began_at()`).

**Labels:** **M** = measured (the query or grep is named), **I** = inferred.

---

## 0. Cross-cutting facts

| # | Fact | Status |
|---|---|---|
| 0.1 | All 27 tables in this slice carry `zzz_change_log` and `zzz_change_log_truncate`. | **M** (`pg_trigger` join, 27 rows) |
| 0.2 | **No root table here has a single change-log row since the log began.** Tables checked: fixed_assets, fixed_asset_history, equipment_*, bank_statements, fx_rates, gst_periods (0 rows). The only change-log rows in the slice are `contracts` and 6 of the `contract_*` tables (INSERT and DELETE pairs). They come from `smoke-routes.mjs`'s temporary contracts (`db_role = service_role`, `actor_kind = no_session`, 2026-09-29 to 2026-10-03; `scripts/smoke-routes.mjs:2055`). On live today, **every trail in this slice is therefore pre-log**, and contracts have none. | **M** (`change_log` group by table, op, hour) |
| 0.3 | Every PK is `PRIMARY KEY (id)` uuid. There are no composite keys and no boolean singletons, so **M5 is not needed anywhere**. | **M** (`pg_constraint contype='p'`; 0 rows ≠ `PRIMARY KEY (id)`) |
| 0.4 | Every actor column (`created_by`, `decided_by`, `withdrawn_by`, `filed_by`, `reconciled_by`, `produced_by`, `changed_by`, `linked_by`) is an **account** (`auth.uid()` default or set by an RPC). None of the writer RPCs call `current_user_employee()`, so **M2 is not needed**. | **M** (`information_schema.columns.column_default`; grep over 21 writer functions → 0 hits) |
| 0.5 | Live row counts: fixed_assets 2 (both active) · fixed_asset_history 2 (both `updated`, 2026-09-20) · cost entries 1 · depreciation 0 · anchors 0 · disposal requests 0 · maintenance 2 · downtime 1 · bank_statements 2 (BS-0001 open+**deleted** 2026-07-30; BS-0002 reconciled) · lines 4 · matches 1 · **bank_reconciliations 0** · variance items 0 · gst_periods 1 (GST-2026-Q3, open) · gst_return_boxes 0 · gst_filing_requests 0 · fx_rates 12 live, 0 withdrawn · **fx_rate_history 0** · management_packs 0 · contracts 0 · terms_requests 0 · contract_* term rows 0 · contract_document_terms 0 · approval_log 17 (0 of these are asset_disposal, gst_filing or terms_request). | **M** (count queries) |
| 0.6 | BS-2026-0002 is `reconciled` (reconciled_by set) but has **no `bank_reconciliations` row**. Its sign-off is visible pre-log only through the `bank_statements.reconciled_at/by` stamp. | **M** |
| 0.7 | All 12 fx_rates (created 2026-08-04 to 08-17) predate `fx_rate_history`, which has 0 rows. Their only pre-log source is `fx_rates.created_at/created_by` (0 rows with a null creator). | **M** |

---

## 1. Subjects and proposed registry entries

### 1.1 `fixed_asset`: a new subject, not a reuse of `equipment`

- **Host:** `/finance/assets/[id]` · `app/finance/assets/[id]/page.tsx`. Guard at `:46` is `const denied = await requireModule(MOD.finance)`, i.e. `module.finance.view`.
- **Why not reuse `equipment`:**
  - `equipment` is `ARRAY['module.processing.view'], 'fixed_assets', 'id', 'page'` (`db/functions/trail_subjects.sql:64`). A finance reader without processing.view would get `TRAIL_NOT_PERMITTED` at layer 1.
  - Widening it with M1 (adding finance.view) would break the rule that view_codes equal the page guard verbatim (`trail_subjects.sql:11`). It would also push the finance-only members (cost entries, depreciation, anchors, disposal requests, journals) onto `/operation/equipment/[id]`, where processing readers would see them as Restricted rows (I).
  - A second subject on the same root has precedent: `forwarder` and `supplier` both root on `suppliers` (`trail_subjects.sql`, 1b-2).
- **Registry row:** `('fixed_asset', ARRAY['module.finance.view'], 'fixed_assets', 'id', 'table', NULL)`.
  - **M3 is not needed.** The `fixed_assets` SELECT policy is `has_permission('module.finance.view')`, which equals the page guard (**M**, pg_policies).
- **Members.** All are `down` and shown. `home=false` where another subject already owns the table.

  | table | parent · fk | home | read rule (M) |
  |---|---|---|---|
  | fixed_asset_history | fixed_assets · fixed_asset_id | true | finance.view |
  | fixed_asset_cost_entries | fixed_assets · asset_id | true | finance.view |
  | fixed_asset_depreciation | fixed_assets · asset_id | true | finance.view |
  | fixed_asset_depreciation_anchors | fixed_assets · asset_id | true | finance.view |
  | asset_disposal_requests | fixed_assets · asset_id | true | finance.view |
  | approval_log `{"subject_type":"asset_disposal_request"}` | asset_disposal_requests · subject_id | true | finance.view (CASE branch) |
  | equipment_maintenance / equipment_downtime / equipment_service_intervals | fixed_assets · equipment_id | **false** (home stays `equipment`) | finance.view OR processing.view |
  | shift_handover_equipment_refs | equipment_downtime · downtime_id | false | as in equipment |
  | *(optional, M4)* journal_entries | `up` via fixed_assets.disposal_journal_id and fixed_asset_depreciation.journal_entry_id | false | the `AT1A-RUN-COST-JOURNALS-NOT-ON-TRAIL` question; leave to the journal decision |

- **Pre-log sources:**
  - Already registered: `fixed_assets` created (`trail_prelog_sources.sql:104`) and the three equipment tables (`:105-108`).
  - To add:
    - `fixed_asset_history` created (`changed_at`, `changed_by`, account). This follows the pricing_formula_history precedent in `trail_prelog_sources.sql:188`. It covers the 2 live rows (09-20).
    - `fixed_asset_cost_entries`, `fixed_asset_depreciation` and `fixed_asset_depreciation_anchors` created (`created_at`, `created_by`).
    - `asset_disposal_requests` created, plus a stamp `withdrawn_at`/`withdrawn_by` with `ARRAY['status','withdraw_reason']` (the terms_requests precedent, `:190-191`).
  - **Not** `fixed_assets.disposal_date`: the history row records the status move.
- **Renderer:** `EQ_TABLES` sends `fixed_assets` to the `equipment` family whatever the subject (`lib/trail/render.ts:887,910`), and `onPage = subject === 'equipment'` (`:1418`). Both must learn `fixed_asset`.

### 1.2 `bank_statement`

- **Host:** `/finance/bank/statements/[id]` · `app/finance/bank/statements/[id]/page.tsx`. Guard at `:39` is `requireModule(MOD.finance)`.
  - The `/reconcile` sub-route (`reconcile/page.tsx:34`) has the same guard and redirects reconciled statements back (`:54-55`). Host the trail on the detail page only (I).
- **Registry row:** `('bank_statement', ARRAY['module.finance.view'], 'bank_statements', 'id', 'table', NULL)`. Root policy is finance.view, which matches the guard, so no M3 (**M**).
- **Members:** bank_statement_lines (statement_id) → bank_line_matches (statement_line_id, a grandchild) · bank_reconciliations (statement_id) → bank_reconciliation_variance_items (reconciliation_id). All are finance.view (**M**).
- **Pre-log:**
  - bank_statements created (created_at, created_by).
  - Stamp `reconciled_at`/`reconciled_by` `['status']`. This is needed: see 0.6.
  - Stamp `deleted_at` with **no actor**: no deleted_by column exists.
  - bank_statement_lines created with **no actor** column. All 4 lines share the statement's `created_at`, so they fold (**M**).
  - bank_line_matches created (created_by).
  - bank_reconciliations created (`reconciled_at`, `reconciled_by`) and a stamp `superseded_at` with no actor `['superseded_reason']`.
  - variance items created.

### 1.3 `gst_period`

- **Host:** `/finance/gst/[periodId]` · `app/finance/gst/[periodId]/page.tsx`. Guard at `:23` is `requireModule(MOD.finance)`.
- **Registry row:** `('gst_period', ARRAY['module.finance.view'], 'gst_periods', 'id', 'table', NULL)`. No M3 (**M**).
- **Members:**
  - gst_return_boxes (period_id)
  - gst_filing_requests (period_id)
  - approval_log `{"subject_type":"gst_filing_request"}` (gst_filing_requests · subject_id)
  - **gst_periods (corrects_period_id, `down`)** so the original shows "correction raised". A self-member has precedent: `journal_entries`→`journal_entries` via reversed_by (`trail_subject_members.sql:95`).
    - Risk: with `shown=true` **every** later edit of the correction period also lands on the original. There is no column limit for members (M6 is root-only). Decide whether to show only its INSERT (renderer filter) or use a stepping stone (I).
- **Pre-log:**
  - gst_periods created, and a stamp `filed_at`/`filed_by` `['status','filed_on','filed_reference']`.
  - gst_filing_requests created, and a withdrawn stamp.
  - gst_return_boxes created (no actor). The boxes are written in the approval transaction (`gst_filing_execute_internal.sql:48`), so they fold with the approval.

### 1.4 `fx_rate`

- **Host:** `/finance/fx/[id]/edit` · `app/finance/fx/[id]/edit/page.tsx`. This is the rate's only page (Q2 precedent). Guard at `:20` is `requireModule(MOD.finance)`.
- **Registry row:** `('fx_rate', ARRAY['module.finance.view'], 'fx_rates', 'id', 'table', NULL)`. No M3 (**M**).
- **Members:** fx_rate_history (fx_rate_id).
- **Pre-log:**
  - fx_rates created.
  - fx_rate_history created (changed_at, changed_by).
  - **No** `deleted_at` stamp. `withdraw_fx_rate` writes the history row in the same transaction (`withdraw_fx_rate.sql:19-23`), so the history already records it (§9.6 step 3).
- **"One event, two rows" fold:** `record_fx_rate` writes both the rate and its history row.
- **Re-entry gets a new id.** `record_fx_rate` matches only `deleted_at IS NULL` (`record_fx_rate.sql:38`), so re-entering a withdrawn rate's key creates a new row and a new id. Each id has its own trail (I).

### 1.5 `management_pack`

- **Host:** `/finance/packs/[id]` · `app/finance/packs/[id]/page.tsx`. Guard at `:29` is `requireModule(MOD.finance)`.
- **Registry row:** `('management_pack', ARRAY['module.finance.view'], 'management_packs', 'id', 'table', NULL)`.
- **Members:** none.
  - Do **not** self-member via `superseded_by`. It would pull the predecessor's whole history onto the new pack (I).
  - The old pack's own `superseded_*` columns carry the event.
- **Pre-log:** created (`produced_at`, `produced_by`), and a stamp `superseded_at` with **no actor** `['superseded_by','superseded_reason']`.
  - The actor is really the next pack's `produced_by` (same transaction, `freeze_management_pack.sql:88-93`). The stamp would read "Not recorded".
- **Smoke:** 0 packs live. `/finance/packs/[id]` is on the smoke SKIP list (`scripts/smoke-routes.mjs:1153`), so the trail cannot be smoke-asserted there yet.

### 1.6 `contract`

- **Host:** `/contracts/[id]` · `app/contracts/[id]/page.tsx`. Guard at `:42` is `const denied = await requireModule(MOD.suppliers)`, i.e. `module.suppliers.view`.
- **Registry row:** `('contract', ARRAY['module.suppliers.view'], 'contracts', 'id', 'table', NULL)`.
- **M3 analysis (M, pg_policies):**
  - The root policy is `(customer_id NOT NULL AND customers.view) OR (supplier_id NOT NULL AND suppliers.view)`.
  - For a sell contract, a suppliers-only reader fails the root rule. The page already reads `contracts` under RLS and `notFound()`s first (`:50-55`), so `'table'` is consistent and M3 is not needed.
- **Members (`down`, contract_id):**
  - The 7 term tables in `termSpecs.ts:50-121`: contract_grade_specs, contract_insurance_obligations, contract_volume_commitments, contract_pricing_terms, contract_settlement_terms, contract_refining_charges, contract_penalty_elements.
  - terms_requests (contract_id), `home=true`. This is safe alongside pricing_formula's `home=true`, because `trail_row_record` only follows a home whose fk is non-null (`trail_row_record.sql:44-45`).
  - approval_log `{"subject_type":"terms_request"}` (terms_requests · subject_id), `home=false`.
  - contract_document_terms (contract_id), **`home=false`**. Its home is the PO/SO (`trail_subject_members.sql:33,178`). It is a snapshot taken at linking time, not a contract term.
- **Restricted rows:** the approval_log CASE gives `terms_request` → `module.pricing.view` (**M**). A contract reader without pricing.view sees the CFO decision rows as **Restricted**.
- **Pre-log:** contracts created and the 7 term tables created. terms_requests is already registered (`:190-191`) and contract_document_terms too (`:37`).

---

## 2. Ended records today

| Record | Page behaviour | who / when / reason columns | Status |
|---|---|---|---|
| Disposed asset | **Shown.** The asset query has no status filter, `.maybeSingle()` then `notFound()` only if the row is missing (`assets/[id]/page.tsx:76-80`). | fixed_assets: `disposal_date`, `disposal_journal_id`, **no disposer**. Who and why live in `asset_disposal_requests` (decided_by, reason, decision_notes, withdrawn_by/withdraw_reason) and `fixed_asset_history.changed_by`. 0 disposed live. | M |
| Deleted bank statement | **404.** The detail page filters `.is('deleted_at', null)` (`statements/[id]/page.tsx:54-58`, reconcile `:46-50`). The **list also hides it** (`statements/page.tsx:49`); the AT-0 survey's "list incl. deleted" is wrong. Not in `deleted_records` (`db/views/deleted_records.sql` kinds). | `deleted_at` only: **no deleted_by, no reason**. The delete is a direct `.update({deleted_at})` (`statements/[id]/actions.ts:19`). BS-2026-0001 was deleted 2026-07-30, before the log, so it is date-only. | M |
| Withdrawn FX rate | **404** (`fx/[id]/edit/page.tsx:33,38-39`). | `fx_rates.deleted_at`, `updated_by`. `fx_rate_history` holds action `withdrawn`, `reason` NOT NULL and `changed_by`. 0 live. | M |
| Superseded pack | **Shown** with a banner (`packs/[id]/page.tsx:84-87`). | `superseded_at`, `superseded_reason`, `superseded_by` (= the new pack's id, not a person). | M |
| Filed or corrected GST period | **Shown.** Filed periods read the snapshot. A correction period carries a banner (`gst/[periodId]/page.tsx:45-51,150-154`). The original stays `filed`; `correct_gst_return` inserts a new period (`correct_gst_return.sql:25`). | `filed_at`, `filed_by`, `filed_on`, `filed_reference`. A correction's reason is in `notes`. | M |
| Suspended / expired / terminated contract | **Shown** (filter is `deleted_at` only, `contracts/[id]/page.tsx:52`). Ended contracts get `contractDetail.lock.ended` and `endedNoActivation` (`:113,175`). | Suspension is a bare `.update({status:'suspended'})` (`termsRequestActions.ts:67`): only `updated_by`, no reason or stamp. **No UI or RPC sets `expired`/`terminated`**; they are only checked in `guard_contract_write` and `contract_terms_lock_reason`. **No UI sets `contracts.deleted_at`**, though the smoke harness hard-deletes its temporary contracts. | M (grep) |

**Q21 decision for Tim:**
- Withdrawn FX rates have a reason and are a business event, so they could open read-only for finance readers.
- A deleted bank statement is a plain soft delete, so it could open for `data.view_deleted` and join `deleted_records`.
- Otherwise these two trails are unreachable.

---

## 3. Existing history sections

| Section | file:line | Recommendation | Other consumers |
|---|---|---|---|
| Asset **HistoryPanel** (fixed_asset_history, 50 rows plus a count) | query `assets/[id]/page.tsx:233-246`, render `:523-528`; component `assets/[id]/HistoryPanel.tsx` | **Replace** (Q26 names it). | No other app page reads `fixed_asset_history` (**M**: grep app/lib). The following are tied to it and need care: `scripts/check-i18n.mjs:868-869` (`assets.history.type.*` / `assets.history.field.*`, read from `db/tables/fixed_asset_history.sql`), `messages/en.ts:9366` and `zh.ts:9135` keys, `HISTORY_SINCE` / `HISTORY_LIMIT`. Fixture 201 (DB-level) and the trigger `trg_fixed_assets_history` stay. Check `gen-trail-catalogue.mjs` before deleting the en.ts keys, because en.ts is a label source for the catalogue. |
| Disposal pending lookup (`asset_disposal_requests_visible`, p_recent 0) | `assets/[id]/page.tsx:56-59` | Keep. It only drives the disabled disposal button. | `/finance/assets/page.tsx:143` (panel) |
| Superseded reconciliation records | `statements/[id]/page.tsx:96-119,298-316` (view `bank_reconciliation_record`) | **Keep.** It is a working list with figures (Q26 "keep settlement/close lists"). | — |
| GST filing panel (open plus decided history, 10 recent) | `gst/[periodId]/page.tsx:79-107,265-275` | **Keep** (request panel). | `GstControls.tsx` |
| Contract TermsRequestsPanel (recent 50) | `contracts/[id]/page.tsx:103,46-…` | **Keep.** Precedent: the formula page keeps the panel and the trail (`tools/pricing/formulas/[id]/edit/page.tsx:138,161`). | `/contracts`, `/tools/pricing/formulas*` via `termsRequestsData.ts` |
| FX history | — | **None exists.** No page reads `fx_rate_history`; the AT-0 survey's "read on the fx pages" is wrong. The only mention is `UNREACHABLE_HISTORY_TABLES` in `app/components/audit/auditTrailTypes.ts:79`. | M |
| Pack superseded banner | `packs/[id]/page.tsx:84` | Keep (a banner, not a history). | — |

---

## 4. Mechanism risks and labels (`lib/trail/catalogue.generated.ts`, M)

**Wrong or awkward labels**
- `gst_return_boxes.label_en` reads **"Label en"** and `label_zh` reads **"Label zh"**. `label_zh` is machine-written Chinese, which Q8 says must not be shown. Recommend marking both technical and rendering "Box 1 · <label_en>" as the heading.
  - Each approval inserts one row per box in a single transaction (`gst_filing_execute_internal.sql:48`). Fold them into one "return snapshot" line.
- `payment_trigger_events.phrase_en` reads **"Phrase en"**.
- `fixed_asset_history`:
  - `new_expense_id` reads **"+ New Expense"** (button text).
  - `new_code` and `new_id` read **"New"**; `old_id` reads **"Previous iD"**.
  - `old_disposal_proceeds_base` reads "Old disposal proceeds", while its pair reads "New … (base currency)".
  - `fixed_asset_id` reads "Fixed assets" (plural).
- `fixed_assets.expense_id` and `fixed_asset_cost_entries.expense_id` read "Created by an expense", which sounds like an actor.
- `contract_pricing_terms.qp_months` reads **"M (the base month itself)"**. That is the option text from `messages/en.ts:2055`; the column label at `:6710` is "Quotational period (M+n)".
- `gst_periods`:
  - `filed_at` and `filed_on` **both** read "Filed on".
  - `code` reads "Gst period number".
  - `period_start` reads "Quarter starts" while `period_end` reads "Period end".
- `fx_rates`:
  - `rate_date` reads "Rate Date".
  - `deleted_at` reads "Deleted on"; the domain word is "Withdrawn".
  - `rate_type` reads "Side", while `fx_rate_history.rate_type` reads "Rate type".
- `fx_rate_history`: `action` reads "Actions"; `prev_rate` reads "Prev rate".
- `asset_disposal_requests#status` values are lowercase ("waiting", "approved"); other request enums are capitalised.

**Enum values missing from `TRAIL_ENUMS`, which `check-trail-wording` will fail on**
- `gst_periods#status`
- `fx_rate_history#action`
- `contract_insurance_obligations#insured_by`
- `contract_volume_commitments#committed_by_party` / `direction` / `period`
- `contract_settlement_terms#settling_party` / `refining_charge_basis` / `penalty_basis`
- `fixed_asset_history#changed_by_kind`
- `bank_statement_lines` / others are fine.

**`trail_ref_label` returns null for**
- `fx_rates`: no code, name or label. The Record column and the heading will be blank, so add `"USD tt_buy · DD/MM/YYYY"`.
- `bank_statement_lines`: add "BS-… line n", like `purchase_order_lines`.
- `gst_return_boxes`, `bank_reconciliations`, `fixed_asset_depreciation`.
- `fx_rates` is also not in `document_types`.

**Machine token in a typed column**
- `unreconcile_statement` appends `'UNRECONCILED ' || now()::text || ': ' || reason` to `bank_statements.notes` (`unreconcile_statement.sql:32`). A notes diff would show a raw timestamp. Treat it as machine-written, or hide the notes diff when `superseded_at` is in the same transaction.

**JSON columns** read "Details changed": `asset_disposal_requests.snapshot/estimate/result`, `gst_filing_requests.boxes`, `management_packs.payload`, `terms_requests.proposed/snapshot`.

**Same-transaction folds needed:** asset history ↔ fixed_assets · fx history ↔ fx_rates · statement ↔ its lines · new pack ↔ old pack superseded · approval ↔ gst boxes.
