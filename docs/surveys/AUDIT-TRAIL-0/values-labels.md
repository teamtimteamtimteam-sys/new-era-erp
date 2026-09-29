# AUDIT-TRAIL-0 · Readable values and field labels

Survey date 2026-09-29. The survey was read-only. Live reads ran as `postgres` (rolbypassrls = true) inside `BEGIN READ ONLY … ROLLBACK`.
Per-column detail: `at0/labels.csv` (2962 rows). FK target table: `at0/fk_targets.csv` (103 rows). Scripts: `at0/classify.py`, `at0/fkev.py`.
Inputs exported from live: `cols.csv`, `allcols.csv`, `fks_all.csv`, `policies.csv`, `harddel.csv`, `doctypes.txt`. The flattened message catalogue is `en_flat.json`, produced by importing `messages/en.ts` under `node --experimental-strip-types` (8225 strings).

## 0. The closed space (Measured)

* **238 tables, 2962 columns.** Method: live `pg_trigger` rows with `tgname='zzz_change_log'` calling `change_log_capture`, joined to `pg_attribute`, with dropped and system columns excluded (`q_cols.sql` → `cols.csv`). This agrees with `db/views/zzz_change_log_triggers.sql` (476 CREATE TRIGGER = 238×2) and with the 4 exclusions in `change_log_exclusions()`.
* The FK, CHECK and PK flags per column come from live `pg_constraint`. I used the live catalogue rather than the parsed `db/tables/*.sql` mirrors because the catalogue is exact. The mirrors are checked against it by check_mirrors.
* Types: text 965 · uuid 848 · timestamptz 433 · numeric 292 · date 149 · boolean 115 · integer/bigint/smallint 104 · jsonb 43 · arrays 10 · other 3.

## 1. Classification by resolution kind (Measured; the classifier is heuristic where noted)

Each column gets exactly one kind. The first matching rule wins, in this order: created/updated stamp → PK → FK → bare uuid → CHECK enum → boolean → date/time → numeric → jsonb/array → text.

| kind | cols | what the trail shows | how |
|---|---:|---|---|
| audit_std (`created_at/by`, `updated_at/by`) | 446 | **hide**, because the trail entry already says who and when | name rule |
| technical (uuid/int PK, seq, hash, path, sort_order, pair_id, version…) | 248 | **hide** | PK flag + name regex |
| fk_document (FK to one of the 41 `document_types` tables) | 226 | document number `code` (for customers/suppliers `legal_name`, for materials `name`) | FK target ∈ `document_types` |
| dict (FK to a table with `name_en`) | 79 | `name_en` | FK target has `name_en` |
| fk_other (FK to line/child/other tables) | 63 | a composed description, e.g. "PO-2026-0012 line 2: <material>" (see `fk_targets.csv`) | FK |
| currency (FK to `currencies` 34 + text `currency` 5) | 39 | the ISO code, as every page shows it | FK / name |
| fk_person (FK to `employees`, not an actor name) | 25 | person name | FK target employees |
| actor (`*_by`, `owner_id`, `user_id`…) | 127 | person name | FK to auth.users/employees (11) or bare uuid (111) + 5 other |
| enum (single-column CHECK list, + enum type `supplier_status`) | 164 | message keys (§1.3) | CHECK parsed from `pg_get_constraintdef` |
| enum_like (text named `*status/*type/*kind/*unit…` with no single-column CHECK) | 50 | needs a value→words map | name regex (Inferred) |
| boolean | 108 | words | type |
| date | 148 | date format (§1.4) | type |
| timestamp_audit (`*_at` that is not created/updated) | 191 | audit stamp format (§1.4) | type + name |
| money | 166 | `formatAmount(n, ccy)` (§1.5) | numeric + name regex (Inferred) |
| number (qty, kg, %, rate, days, line_no…) | 173 | number with its unit | numeric, not money |
| own_key (text PK such as dictionary `code`) | 45 | show as-is | PK |
| text (free text, names, notes, references) | 570 | verbatim | default |
| jsonb | 43 | **no generic rendering**. Needs a per-column renderer or must be hidden | type |
| uuid_nofk (polymorphic or soft refs) | 23 | resolve through the paired type column, else hide | uuid without FK or actor name |
| text_code (`*_code` text with no FK or CHECK) | 16 | resolve via its dictionary where one exists | name |
| array 9 · time/interval 3 | 12 | joined list / HH:MM | type |

### 1.1 FK → display value (Measured count; the evidence column is a heuristic first hit)

* 444 FK columns point at **103 target tables**: 37 document tables, 31 dictionaries, 34 other tables, and auth.users.
* After the created/updated rule, the FK columns split as fk_document 226 · dict 79 · fk_other 63 · currency 34 · fk_person 25 · actor 11 · hidden audit_std 6.
* `fk_targets.csv` lists each target with its display rule, the detail route (from `document_types`), whether it is hard-deletable, and one file:line where the app already selects that display column.
  * That file:line was found for 93 of the 103 targets by `fkev.py`, which takes the first embedded `tgt(…col…)` or `.from('tgt')…col` hit.
  * No hit for 10: lanes, kpi_position_templates, laboratories, bank_reconciliations, expense_claims, loss_metal_fates, battery_chemistries, operation_kinds, sales_settlements, stocktake_lines.

Largest targets:

| target | FK cols | display | where the app resolves it |
|---|---:|---|---|
| currencies | 34 | code | lib/currency.ts:19 |
| employees | 33 | `preferred_name \|\| legal_name` | app/components/ActorName.tsx:49 (`loadActorNames`, employee space); db/views/employee_lookup.sql for readers without hr.view |
| journal_entries | 30 | code (JE-) | app/hr/payroll/page.tsx:66 |
| inbound_batches / output_batches | 17 / 14 | code (IN-/OUT-) | app/inbound/page.tsx:150, app/output/page.tsx:115 |
| suppliers / customers | 17 / 15 | legal_name (code) | app/suppliers/page.tsx:63, app/output/page.tsx:118 |
| substances | 12 | name_en | app/tools/pricing/metal-prices/substanceQuery.ts:38 |
| expenses | 12 | code | app/finance/expenses/page.tsx:94 |
| contracts / materials | 11 / 11 | code + title / name (code) | app/contracts/page.tsx:71, app/output/page.tsx:117 |
| auth.users | 9 (+ bare) | account → employee name | ActorName.tsx:49 |

**Actors (people).** There are 309 bare-uuid actor columns with no FK: 198 are created_by/updated_by and 111 are other `*_by`. Another 17 actor columns have an FK to auth.users or employees, and 25 non-actor person references point at employees. All of them resolve through **one existing helper**, `loadActorNames` + `<ActorName>` (app/components/ActorName.tsx:49,119). It covers four states: name, no employee record, unrecorded, and restricted. Its `space` parameter separates account uuids from employee uuids. It also recognises additional accounts through `employee_accounts`.
- ⚠ **Contradiction:** `user_directory` (db/views/user_directory.sql) exposes `legal_name` only. ActorName prints `preferred_name || legal_name`. The current /settings/change-history page shows `employee_code — employee_name`, taken from change_log_rows. So the repo has **three name renderings**, and the trail must pick ActorName's.
- The change_log row itself carries `actor_employee` frozen at write time (`account_person()`), so the trail's own "who" needs no account lookup.

### 1.2 Dictionaries

* 79 FK columns point at the 31 dictionary tables that have `name_en`.
* The existing resolver is `app/components/dictionaries/dictionaryQuery.ts:56` (`dictLabeller`, which returns the code unchanged if the lookup misses). It reads inactive rows as well.
* 16 `*_code` text columns have no FK (listed in `labels_stats.json → text_code`), for example `payment_requests.bank_account_code`, `finance_settings_history.*_role_code`, `fixed_asset_history.*_depreciation_account_code`. Each needs its dictionary named explicitly.

### 1.3 Enums → message keys (Measured)

* **Authoritative source:** `scripts/check-i18n.mjs` already registers message prefix ↔ SQL enum pairs and checks them in the build. It has 232 `kind:'enum'` entries, and 80 of those are backed by a table CHECK (`i18n_enum_registry.json`).
* Of the 164 enum columns:
  * **79 have a registered prefix**, for example `purchasing.approvalState.<v>`, `hr.employmentStatus.<v>`, `leave.status_<v>`.
  * 69 more have a prefix that covers every value, found by suffix search over the catalogue (`.v`, `.camelV`, `_v`, `PascalV`). 44 of those prefixes are used on a page that reads the table; 25 only exist as keys somewhere.
  * 7 have partial coverage.
  * **9 have none:** approval_log.decision, document_types.numbering and document_types.link_mode, fx_rate_history.action, inbound_batches.stage (CJK values 待加工/加工中/已加工完), kpi_cycles.gate, leave_types.gender_restriction, pricing_formula_history.change_type, processing_cost_entry_history.change_type.
* Accuracy check against the registry: where both exist, the unregistered inference agreed on 68 of 77. The 9 misses were generic prefixes such as `claims.state_` being reused for `warehouse_requests.status`, where the registry says `warehouseRequest.status.`. **So the 25 "key exists, not seen on a page" inferences are candidates, not answers.**
* The 50 enum_like columns have no CHECK. Many are history mirrors (`task_history.old_status`, `purchase_order_history.old_unit`…) that can reuse the parent column's keys.

### 1.4 Dates: the current format and the conflict (Measured from lib/dates.ts)

| column family | cols | function | prints today |
|---|---:|---|---|
| `date` (document dates) | 148 | `formatDate` lib/dates.ts:193 | en **`01 Sep 2026`**, zh `2026年9月1日` (DATE-1 ruling D4) |
| document timestamptz | — | `formatDateTime` lib/dates.ts:211 | `01 Sep 2026 14:33` |
| audit stamps `*_at` | 191 (+242 hidden created/updated) | `formatAuditStamp` lib/dates.ts:251 | **`2026-09-01 14:33`** in both languages (DATE-1 ruling D2) |
| CSV | — | `formatCsvTimestamp` lib/dates.ts:309 | `YYYY-MM-DD HH:MM` **UTC** (D3; known issue DATE1-CSV-UTC) |

* **No formatter in the repo prints DD/MM/YYYY.**
* **QUESTION for Tim:** DATE-1 ruled `01 Sep 2026` for display and `YYYY-MM-DD HH:MM` for audit stamps, and the audit trail is exactly the audit-stamp family. His new DD/MM/YYYY requirement was stated for date *inputs*. Should the trail (a) keep the D2/D4 display rules, (b) switch every date it shows to `01/09/2026`, which reverses D4 and D2 for the trail only, or (c) change `formatDate` globally?
* Note that `<input type="date">` renders in the browser's locale and must be fed `toYmd()`, so a DD/MM/YYYY *input* does not require changing any display formatter.

### 1.5 Money (Inferred classification: the name regex is over numeric columns)

* 166 money columns. All go through `formatAmount(n, ccy)` (lib/format.ts:32). The currency comes from:
  * `row.currency`;
  * a one-hop FK parent's `currency` (for example `purchase_order_lines` → `purchase_orders.currency`);
  * `_base` → `getBaseCurrency()` (lib/currency.ts:16);
  * `_usd`/`_sgd` in the column name;
  * `*_usd_per_tonne` → USD per tonne.
* **14 have no currency column on the row or one FK hop away** (Measured). Every one is determinable by an existing convention:
  * base currency, by what the screens do: `employees.monthly_salary`, `employment_history.old/new_monthly_salary`, `performance_reviews.new_monthly_salary`, `salary_change_requests.old/new_monthly_salary` (app/hr/employees/[id]/page.tsx:431 uses `baseCurrency`); `period_closes.total_debits/total_credits`, `year_closes.net_result` (app/finance/close/page.tsx:114,296);
  * `bank_transfers.amount_out/amount_in` → `currencyOfBank(from_account/to_account)` (lib/currencyMap.ts:14; app/finance/bank/page.tsx:109);
  * `purchase_order_line_retentions.fixed/released/withheld_amount_ccy` → two hops, `purchase_order_lines` → `purchase_orders.currency`.
* **So 0 are truly undeterminable. However, the 6 salary columns rest on a screen convention, not on data.**

### 1.6 jsonb, arrays, technical (proposal)

* **jsonb (43): never print raw JSON.**
  * Snapshots/payloads, for example `*_requests.snapshot`, `management_packs.payload`, `notifications.payload`, `cash_forecasts.*`, `customer_statements.lines`: show "details recorded" plus a link to the document. Hide the body.
  * Terms/provenance, for example `*.price_provenance`, `contract_document_terms.*_terms`, `purchase_order_history.old/new_payment_term`, `purchase_order_lines.expected_assay`, `sales_settlements.breakdown`: these need a dedicated renderer. If no renderer exists, write "changed" without the values.
* **uuid_nofk (23):**
  * polymorphic pairs resolved by their type column: `approval_log.subject_type/subject_id` (keys `finance.approvals.subject_<v>`, 23/23), `collection_chase_documents`, `notifications`, `journal_entries.source_id`;
  * pair ids and tokens: hide;
  * history line ids, for example `purchase_order_history.purchase_order_line_id`: show "line N" via `line_no`.
* **Hide:** all 248 technical columns and the 446 created/updated columns (694 in total).

## 2. Referenced record since hard-deleted (Measured)

* **69 hard-deletable tables.** Method: RLS policy for `authenticated`/PUBLIC with cmd `d`/`*` (90 tables), minus those that have a BEFORE DELETE trigger other than `enforce_write_permission` (`q3.sql` → `harddel.csv`). This reproduces HISTORY-0 §D.3. 3 of the 69 are change-log-excluded tables (festival_doodles, home_greetings, notification_reads), so **66 are in the trail's space**.
* **165 FK columns (of 444) in the 238 tables point at 29 of those tables.**
  * By ON DELETE: NO ACTION 123 · RESTRICT 30 · CASCADE 12.
  * Top targets: currencies 34, employees 33, suppliers 17, customers 15, materials 11, assay_results 6, metal_price_indices 6.
  * For NO ACTION and RESTRICT, a *current* reference blocks the delete. The exposure is **historical values**: the `old` image of an UPDATE, a DELETE image, or a reference that was re-pointed before the target was deleted.
  * For CASCADE, the child rows vanish too, and each writes its own DELETE log row.
* **How to resolve a deleted target:** read the latest `change_log` row for (`table_name`, `row_key`) with `op='DELETE'`. Its `old` holds the full last row image, so the code or name can be recovered.
  * Live today: 88 DELETE rows out of 180 in total (postgres, bypassrls). Only 6 carry a `code` key, because they are mostly smoke-test rows.
  * **Gaps:** (1) anything deleted before HISTORY-1 went live (2026-09-28 23:58 CST) has no DELETE row; (2) employee names are in `change_log_redactable_columns('employees')`, so an anonymised person's image is redacted by design; (3) masked columns come back `{"$restricted":true}` (the display columns code, legal_name and name_en are not in the mask rules).
  * Soft-deleted rows (`deleted_at`, 27 of the 69 have it) are still readable by id. The trail should suffix "(deleted)".
* **Proposed wording:**
  * "PO-2026-0012 (since deleted)" when the DELETE image gives the code;
  * "a supplier that has since been deleted" when there is no image;
  * for people, keep ActorName's `actor.employeeGone` and the anonymised wording "a former employee".
  * Never print the uuid.

## 3. Field labels (Measured counts; method heuristic, precision sampled)

Method (`classify.py`, `find_label`):

1. **Scope.** For each table, the scope is the app and lib files that quote the table name (`'tbl'`, `tbl_masked`, `tbl_lookup`), plus the other files in the same directories.
2. **Proximity match.** Find every non-comment, non-`.select(` line that contains the column name or its camelCase form. Take each `t('key')` within ±5 lines. Excluded: keys whose text has `{…}` placeholders, and keys whose last segment looks like a hint/title/placeholder/error/button.
3. **Score.** Score = the share of the column's tokens found in the key segment or text. Labels over 6 words are penalised, and so is each line of distance.
   * **high:** score ≥ 0.95.
   * **medium:** score ≥ 0.66 and a label of ≤ 4 words.
4. **Fallback (text-only).** A catalogue string whose token set equals the column's. This proves the wording exists but **not** that a page uses it for this column.

Results over 2962 columns:

| result | cols | sampled precision (my reading) |
|---|---:|---|
| page-proven label, high | 595 | 36/40 usable (e.g. `purchasing.colEstimatedTotal`). Misses: "Select customer", "(deleted)", "created by an expense" |
| page-proven label, medium | 45 | 17/20 usable |
| text exists elsewhere (text-only) | 738 | ~33/40 usable wording, but the key's namespace is arbitrary (e.g. `changeHistory.op.DELETE` "Deleted" for `deleted_at`) |
| **no label found**: proposal written | 890 | column `proposed_label_if_missing` (plain English from the name: `_id`/`_code` dropped, `old_`/`new_` → "Previous …/New …", `_base` → "(base currency)", `code` on a document table → "<Document> number") |
| hidden (technical + created/updated) | 694 | n/a |

**Headline:**

* Of the 2268 columns the trail would show, **640 (28%) have a label a page demonstrably uses next to that column**, 738 (33%) only have matching wording elsewhere, and **890 (39%) have none**.
* Weakest kinds: actor 105/127 have none (pages print "Approved by" inline in sentences); own_key 44/45; number 111/173; money 64/166.
* **Confidence note:** the proximity method misses labels that pages render through an embedded relation (`po.suppliers.legal_name` next to `t('…colSupplier')`). That is why fk_document is only 29 page-proven of 226, even though every document page clearly shows these fields. The true page-label coverage for FKs is higher than measured.

**Existing per-field label maps (the only precedents):**

* `assets.history.field.<col>` (23 keys, app/finance/assets/[id]/HistoryPanel.tsx:128);
* `contractDetail.field.<table>.<col>` (38 keys, app/contracts/[id]/page.tsx:120);
* `termsRequest.field.<k>` (app/components/pricing/termsRequestsData.ts:76).

**Recommendation:** add one `<ns>.field.<table>.<col>` map (like contractDetail) and seed it from `labels.csv`, with check-i18n extended to require one key per shown column.

## 4. Resolver registry: the single place (Inferred recommendation, facts Measured)

**`public.document_types`** (db/tables/document_types.sql; 41 rows live) is the existing registry, and it should be the anchor. It already maps `table_name` → `prefix` → `route` + `link_mode` (detail / list / list_q / type_list) → `label_column`.

It is consumed by:

* `lib/search/documentHref.ts` (`documentHref()`: table row → URL, 3 callers);
* `lib/search/records.ts:111`;
* `db/views/document_relations.sql` (the FK graph between documents; it already classifies `*_by` → employees as "actor, not a relation");
* `scripts/check-search-registry.mjs` and `scripts/check-document-registry.mjs` (build gates).

Other resolvers the registry should call rather than duplicate:

* **people:** `app/components/ActorName.tsx` (`loadActorNames`);
* **dictionaries:** `app/components/dictionaries/dictionaryQuery.ts` (`dictLabeller`), where code → name_en is generic for any table with `name_en`;
* **enums:** the enum map in `scripts/check-i18n.mjs`, which today lives only in the build script. It would need to move into a shared module for runtime use;
* **masking:** `lib/maskedTables.ts` (generated) together with `change_log_mask_rules()`.

What is missing:

* the 34 non-document, non-dictionary FK targets (lines, lanes, fx_rates, reservations…), which need a composed-description rule each (proposals in `fk_targets.csv`);
* the per-column label map (§3);
* the 43 jsonb renderers.

`app/components/related/*` renders document_relations and is not itself a registry. `app/components/audit/*` is the batch-only audit trail with 20 hand-written event kinds.

## Contradictions / flags

1. The three person-name renderings disagree (ActorName: preferred‖legal; user_directory: legal only; change-history page: code — name). §1.1
2. No DD/MM/YYYY formatter exists, and DATE-1's D2/D4 conflict with the new requirement if it applies to display. §1.4
3. Unregistered enum-key inference was wrong on 9 of the 77 columns that could be checked, so only the check-i18n registry (79 columns) is safe to use as-is. §1.3
4. The current /settings/change-history renders raw column names, raw JSON and `∅` (app/settings/change-history/fieldValue.tsx:19-21). Every row there currently breaks the "no machine tokens" rule.
