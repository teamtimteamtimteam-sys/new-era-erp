# AUDIT-TRAIL-0 · Reader, masking, summary page, existing trail, detail-page bottoms

Scope: read-only survey. Live DB read as **postgres (rolbypassrls = true)** in `BEGIN READ ONLY … ROLLBACK` sessions;
query files `at0/rm_q1.sql … rm_q17.sql`. Every finding is marked **Measured** (with its query/file) or **Inferred**.
Raw mock-up data is in `at0/mockup-data.md`.

---

## 1. The reader: `change_log_rows()` and its helpers

### 1.1 Table and indexes — Measured (`pg_indexes`, rm_q1; `db/tables/change_log.sql`)
`change_log(seq bigint identity PK, occurred_at, txid, table_name, row_key jsonb, op, actor_account, actor_employee,
actor_kind, db_role, changed_columns text[], old jsonb, new jsonb, redacted_at)`. Live indexes (5):
`change_log_pkey (seq)` · `idx_change_log_occurred (occurred_at DESC)` · `idx_change_log_table_key (table_name, row_key)` ·
`idx_change_log_actor (actor_account)` · `idx_change_log_actor_employee (actor_employee)`. No GIN, no expression index.
`REVOKE ALL … FROM PUBLIC, anon, authenticated, service_role`, RLS on with zero policies. Live: **180 rows, seq 1–180,
240 kB** (postgres, unfiltered). By table: role_permissions 146, employees 6, contract_* 16, performance_reviews 3,
cod_verification_failures 2, user_roles 2, roles 2, permissions 1. actor_kind: no_session 176, user 4.

**What an image contains** — Measured (`db/functions/change_log_capture.sql:37-55`): INSERT → `new` = full row;
DELETE → `old` = full row; UPDATE → `old`/`new` = **only the changed columns** (and no row if nothing changed).
`row_key` = the PK columns (from TG_ARGV). ★ This matters for child look-ups (§1.7).

### 1.2 Authorisation — Measured (`db/functions/change_log_rows.sql:23`, `change_log_filters.sql:12`)
Both are `SECURITY DEFINER`, `STABLE`, `search_path public,pg_temp`, and start with
`PERFORM require_permission('data.view_change_log')` → PERMISSION_DENIED otherwise. The code is granted only to
**admin** and **cfo** (change_log seq 2/3: INSERT role_permissions for role_id of admin "System Administrator" and cfo
"CFO", 2026-09-28 23:58:11, rm_q16). Route: `lib/modules.ts:886` `/settings/change-history`, permission
`P_VIEW_CHANGE_LOG`, two owners (settings + finance reports group). DEFINER is needed because nothing is granted on
change_log and it joins `auth.users` for the email.

### 1.3 Masking, per reader, per row — Measured (`change_log_rows.sql:64-84`, `change_log_rule_visible.sql`, `change_log_mask_rules.sql`)
For each row returned:
1. **Task privacy first**: if `table_name ∈ {tasks, task_nodes, task_participants, task_history}` and
   `change_log_task_visible()` is false → `old` and `new` are wholly replaced (`change_log_restrict(img, NULL)`) and
   `row_restricted = true`. Seq/time/actor/table/key/op/**changed_columns names** stay visible.
   `change_log_task_visible`: task id from key or image (via `change_log_field`); task still exists →
   `can_view_task(id)`; task gone → `module.tasks.view AND (view_all OR last-known task_type='team' OR last-known
   owner_id = current_user_employee())`; no task id at all → only `module.tasks.view_all`.
2. **Otherwise column masking**: for each rule of this table in `change_log_mask_rules()` (a constant `VALUES` list,
   **80 rules over 26 tables** — Measured live, rm_q17: `count(*), count(distinct table_name) FROM change_log_mask_rules()`;
   `change_log_mask_gaps()` live = `{"gaps": [], "examined_tables": 26, "examined_columns": 80}`), if the column is
   non-null in old or new and `change_log_rule_visible(rule,…)` is false, the column is added to a hidden list;
   `change_log_restrict(img, hidden)` replaces those keys. Rule forms:
   * `code:<perm>` → `has_permission(perm)` (e.g. `purchase_orders.fx_rate` → `data.view_purchase_prices`).
   * `code_or_self:<perm>:<col>` → `has_permission(perm) OR change_log_field(…, col) = current_user_employee()`
     (employees identity/pay, payroll_lines, employment_history, performance_reviews salary).
   * `pft:direction` → `pricing_formula_terms_visible(row.direction)`.
   * `pft:formula_id` → visible iff the parent formula's direction is visible.
   * `pft3` (pricing_formula_history) → formula's current direction AND `old_direction` AND `new_direction` (null → 'both').
   * Anything unrecognised → **false** (fail closed).
   `change_log_field()` (not DEFINER, EXECUTE revoked from authenticated) finds a criterion field that a partial UPDATE
   image lacks: this row's new/old/key → the live row today (dynamic `SELECT to_jsonb(t) … WHERE to_jsonb(t) @> key`,
   run as owner) → the latest earlier change_log image of the same row.
3. **Drift gate**: `change_log_mask_gaps()` regex-reads every `*_masked` view (`END AS <col>` where col is a real base
   column) and diffs against the rule list (missing_rule / stale_rule), reporting examined tables/columns; gate fails if
   < 20 tables examined; fixture 234 injects a deleted rule.
   ★ Scope note (Inferred): masking copies **column** masks from `_masked` views only. **Row-level** RLS
   (e.g. `leave_requests select own rows`, `payroll_lines select own rows`, `performance_reviews select as reviewer`)
   is **not** reproduced except for tasks — acceptable today because only admin/cfo read it; **not acceptable** for a
   trail open to every page reader (§1.6).

### 1.4 "Restricted" vs genuinely empty — Measured
* DB: `change_log_restrict` replaces a hidden value with `{"$restricted": true}` **only if the value is not JSON null**;
  null stays null (`change_log_restrict.sql:13-16`). Whole-row task restriction → every non-null key becomes the marker,
  plus `row_restricted = true`.
* UI: `fieldValue.tsx:10-21` — marker → `<Refusal>{t('common.restricted')}</Refusal>` pill; null/undefined → grey `∅`;
  anything else → `String()` or `JSON.stringify()`. Notice text: `changeHistory.maskNote` "Restricted means the value
  exists but your permissions do not show it. A blank means the value was genuinely empty…".
* Caveat (Inferred): a key **absent** from a partial UPDATE image and a key that is JSON null both render `∅`; the UPDATE
  branch only iterates `changed_columns`, so this is not hit there, but it is for INSERT/DELETE images.

### 1.5 Filters and paging — Measured (`change_log_rows.sql:37-45`, `page.tsx:76-103`)
Filters: date from/to (as `::timestamptz` in DB time zone; `to` inclusive via `+1 day`), exact `table_name`,
`p_record` = **any value in row_key equals the text** (`EXISTS jsonb_each_text(row_key)`), actor = account OR employee
uuid, "no session only". Paging: `ORDER BY seq DESC`, keyset `seq < p_before`, `LIMIT clamp(p_limit,1,200)` (default
50); page asks for 51 to know if "Older" exists; only "Newest" and "Older" links (no "Newer"). Masking runs **after**
LIMIT, row by row in PL/pgSQL (`FOR r IN … LOOP`, plus one `change_log_mask_rules()` scan per row).
Plan for the record filter — Measured (rm_q1): `Index Scan Backward using change_log_pkey … Filter: EXISTS(SubPlan)
Rows Removed by Filter: 180` → it is a scan of the whole log (180/180 rows) — O(N) at scale.

### 1.6 Serving a PER-RECORD trail readable by anyone who can open the page
**(b) Reuse `change_log_rows` with a widened permission — reject.** Measured reasons: its authorisation is a single
global code; once granted, `p_table/p_record` are client-chosen, so any holder can read *any* table's history (all
salaries' existence, every leave request's content where not column-masked, every role change). Masking reproduces
column masks only; row-level own-row policies (16 SELECT policies on 13 tables key on `current_user_employee()`,
rm_q15) are not applied. Widening it turns the log into a cross-module read path — the AUD-1 error in reverse.

**(a) New `SECURITY DEFINER record_trail(p_subject text, p_id text)` — recommend**, with these properties (Inferred design):
1. **`p_subject` is a registry key, not a table name.** A server-side registry (SQL function/table, like
   `change_log_mask_rules`) maps subject → root table, root PK column, the **page's own view code**
   (e.g. `purchase_order` → `module.purchasing.view`), and the **child tables + FK column** that make up "this record"
   (e.g. purchase_order_lines.purchase_order_id, purchase_order_payment_terms.purchase_order_id,
   purchase_order_line_retentions…, purchase_order_history.purchase_order_id). The client can only say "which record";
   it can never name a table. Unknown subject → error.
2. **Authorise by the same predicate the page uses, at two levels**:
   * the view code (`require_permission(<registry code>)`), *and*
   * the root row's own RLS SELECT predicate. SET ROLE is impossible inside a SECURITY DEFINER function, so evaluate
     the table's policy expression dynamically: `EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I WHERE %I = $1
     AND (%s))', tbl, pk, <OR of pg_policies.qual for cmd SELECT/ALL>)`. This is sound because the predicates resolve
     the caller from the JWT, not from `current_user`: Measured (rm_q14/15) — 287 SELECT/ALL policies on 240 tables;
     **0 restrictive**, **0 null qual**, all apply to authenticated/public; the 16 matches for
     `current_user|session_user|current_role` are all `current_user_employee()` (auth.uid-based), i.e. **0 use the DB
     role**. Caveat: a qual that contains `EXISTS (SELECT … FROM other_table)` (review_goals → performance_reviews)
     would be evaluated without the other table's RLS inside DEFINER — equivalent only if that sub-select is itself
     fully explicit (it is, for the 2 found). A deleted root: evaluate the qual against the last full image with
     `FROM jsonb_populate_record(NULL::public.<tbl>, <image>) AS <tbl>` (alias = table name so qualified column refs
     resolve).
3. **Children are filtered per child row by the child table's own predicate too** — not by the parent's. Otherwise a
   reader who sees a payroll run (via own-row policy) would get other employees' payroll_lines trail. Same
   `jsonb_populate_record` trick for deleted child rows.
4. **Then mask with the same `change_log_mask_rules()` / `change_log_task_visible()` path** — factor the loop body of
   change_log_rows (lines 64-84) into one function both readers call, so there is one masking implementation.
5. **Return no table names / uuids / column codes** that the UI would need to print raw; return a subject-relative role
   ("the order", "line 1", "payment term 2") computed server-side from the registry and images, and let the app
   humanise.

**How to prove "nothing outside the page's own record and child lines is exposed"** (Inferred, fixture design):
* **Scope proof by construction + injection**: the function's only row source is
  `change_log WHERE (table_name, row_key) IN (<root key> ∪ <child keys derived from the registry>)`. Fixture: seed two
  sibling records (PO A and PO B, each with lines and terms) and one unrelated table write in the same transaction;
  assert `record_trail('purchase_order', A)` returns exactly the seqs of A's root+children (set equality, both
  directions), and that B's seqs are absent. Inject a fault (registry child FK pointed at the wrong column, or a
  child key derived from the client) → must go red.
* **Authorisation parity**: for a matrix of personas (no role; module view only; own-row employee; admin) × every
  registry subject, compare the DEFINER verdict with an invoker-side `SELECT EXISTS` through RLS (run the fixture with
  `SET LOCAL ROLE authenticated` + `request.jwt.claims`). Any disagreement → red. Include one deleted root.
* **Mask parity**: reuse `change_log_mask_gaps()` unchanged, plus a fixture that a persona without
  `data.view_purchase_prices` sees `{"$restricted":true}` for estimated_unit_price in a PO line UPDATE and `null` stays
  null.
* **No-leak on refusal**: a caller who fails step 2 gets an error (or a refusal row), never an empty list — an empty
  list would read as "nothing happened" (the AUD-1 wrong good news).
* **Registry coverage gate**: every subject's children must be tables that have the `zzz_change_log` trigger (238
  tables today, Measured rm_q14) — and a gate listing detail pages without a registry subject.

### 1.7 Query cost — Measured on the live 180-row log (rm_q1, rm_q3), then Inferred for 1M rows
| Lookup | Plan (live) | Time | Buffers |
|---|---|---|---|
| root by `(table_name,row_key)` — roles `{"id":926c…}` (2 rows) | Index Scan `idx_change_log_table_key`, both columns as Index Cond | 4.5 ms exec (cold plan 1.9 ms) | shared hit 4 |
| root miss — role_permissions composite key | same index | 1.0 ms | hit 2 |
| child by `new->>'purchase_order_id' OR old->>…` on purchase_order_lines (0 such rows in log) | Index Scan on table_key, **Index Cond table_name only**, jsonb Filter | 0.04 ms | hit 2 |
| child by `new->>'contract_id' OR old->>…` on contract_grade_specs (2 of 4 rows match) | same: Index Cond table_name, Filter removes 2 | 0.10 ms | hit 6 |
| child by `row_key->>'role_id'` on role_permissions (144 of 146 match) | **Seq Scan**, Filter, 36 removed | 0.15 ms | hit 11 |
| change_log_rows `p_record='cco'` | Index Scan Backward on pkey + EXISTS filter, 180 removed | 1.2 ms | hit 14 |

★ **Correctness before speed (Measured from capture code)**: a child lookup by `new->>'parent_id'` finds only the
child's INSERT and DELETE rows (full images) — **UPDATE rows carry only changed columns, so a price edit on a PO line has
no `purchase_order_id` in its image** and would be silently dropped. The child set must be built as keys first:
(live child rows `WHERE fk = X`) ∪ (INSERT/DELETE images whose `coalesce(new,old)->>fk = X`), then all rows
`WHERE (table_name,row_key) IN (keys)`. Exception: tables whose FK is in the PK (role_permissions.role_id).

**At 1M rows (Inferred)**: the root lookup is already served by `idx_change_log_table_key` (btree on
`(table_name, row_key)`; jsonb equality) — fine. Child key discovery needs one of:
* a partial GIN: `CREATE INDEX … ON change_log USING gin (coalesce(new, old) jsonb_path_ops) WHERE op IN ('INSERT','DELETE')`
  queried as `table_name = 'purchase_order_lines' AND coalesce(new,old) @> '{"purchase_order_id":"<X>"}'` (one index for
  every FK; `table_name` filters after) — or `btree_gin` with `(table_name, coalesce(new,old) jsonb_path_ops)`;
* or, cleaner and cheaper to read, a written-at-capture **`parent_key`** (e.g. `parent_table`, `parent_id` from the same
  registry passed via TG_ARGV) with a btree on `(parent_table, parent_id)`; this also covers UPDATE rows. Needs a
  capture change + backfill of the 180 rows.
* Also: `p_record` in change_log_rows should become `row_key @> jsonb_build_object(...)` or be dropped; the
  `jsonb_each_text` EXISTS form cannot use any index.
The per-row PL/pgSQL masking loop (one `change_log_mask_rules()` scan + possible dynamic `change_log_field` query per
masked column) is the other cost; for one record's trail (tens–hundreds of rows) it is small (Inferred).

---

## 2. The summary page `/settings/change-history` (Measured, files read in full)
Files: `app/settings/change-history/page.tsx` (265 lines), `ChangeHistoryTable.tsx` (34), `fieldValue.tsx` (30).
* **Guard**: `requireFunction(FN.changeHistory)`; RPCs via `mustOne`/`mustRows` (failure is not drawn as "no changes").
* **Filters** (GET form, shareable URL): From, To (`DateFilterInput`), Table (select of `filters.tables`), Record (free
  text ≤200 chars), Who (Everyone / "No session (migrations, system jobs)" / each account). Buttons Filter, "Clear filters".
* **Columns** (`ChangeHistoryTable.tsx:24-31`): When · Who · Table (`font-mono`) · Record (`font-mono break-all`) ·
  Change (priority) · Fields (before → after) (priority). Phone mode `columns` keeps Change + Fields.
* **Paging**: "Newest first, 50 per page." + Newest / Older links.

**Every place it shows machine language** (quoted):
1. Table dropdown options are raw relnames + `'auth.users'`: `<option key={x} value={x}>{x}</option>` (page.tsx:210-214).
2. Table column prints `r.table_name` in mono: `render: (r) => r.table` (ChangeHistoryTable.tsx:27). The page header even
   says `// 【表名是技术名】Tim 的 Q15:238 张表的显示名是登记在案的后续一项` (page.tsx:14).
3. Record column = `rowKeyLabel(r.row_key)` → `` `${k}=${v}` `` joined by ` · ` (fieldValue.tsx:25-29), e.g.
   `role_id=926c9811-c1ee-49ab-9ab8-f6686d92b6f9 · permission_code=action.apply_assay` — uuids and codes.
4. Record filter placeholder "Record key (e.g. an id or a code)" — asks the user for a uuid.
5. Field names in mono: `<span className="font-mono …">{c}</span>` for UPDATE (page.tsx:130) and `{k}` for full
   images (page.tsx:150) — column codes like `reviewer_employee_id`, `updated_at`.
6. Values: `JSON.stringify(value)` for objects/arrays and `String(value)` otherwise (fieldValue.tsx:20) — raw uuids for
   every FK (`reviewer_employee_id: 0f794998-…`), ISO timestamps (`2026-09-29T00:27:37.402773+08:00`), enum codes
   (`status: draft`), jsonb blobs (payment terms, price_provenance). `∅` glyph for null.
7. INSERT/DELETE print **every column** of the row, including `created_at/created_by/updated_*` uuids.
8. Who: `t('changeHistory.noSession', { role: r.db_role })` → **"No session · service_role"** / "No session · postgres"
   (page.tsx:109; en.ts `noSession: 'No session · {role}'`).
9. Who for users: account **email** + `EMP-code — name` or "no employee record"; unknown account → "account no longer
   exists" (page.tsx:111-117). Actor dropdown: `(a.email ?? a.account) + ' — ' + employee_code` (page.tsx:234) — falls
   back to the raw account uuid.
10. Op labels are English ("Created/Edited/Deleted/Table emptied/Account …") — the one humanised column.
11. Notices "Private task — the details are restricted", "Personal fields redacted on {date}" are plain English.

---

## 3. The existing inbound/output batch "Audit Trail" (AUDIT-1)
Files: `app/components/audit/{auditTrailTypes.ts, auditTrailQuery.ts, BatchAuditTrail.tsx, BatchAuditTrailTable.tsx}`;
views `db/views/batch_audit_trail_all.sql` (553 lines, no grants) and `db/views/batch_audit_trail.sql` (84 lines,
`security_invoker = off`, `GRANT SELECT TO authenticated`). ★ There is **no reader function** — the reader is the
outer **view** (`auditTrailQuery.ts` reads `.from('batch_audit_trail').eq(batch_kind).eq(batch_id).order(occurred_at)`);
Measured: 0 functions named `*batch_audit*` in funcs.csv.
* **Authorisation (two layers)**: outer `WHERE has_any_permission([8 module view codes])` = admission; per row
  `may_view = has_permission(module_code)` where module_code was copied from each source table's own SELECT policy.
  Restricted rows keep the row but null `actor_id, source_id, source_code, href, detail`.
* **Row kinds** — 20 declared `event_kind`s (auditTrailTypes.ts:10-30): receipt, output_created, movement,
  price_change, run_input, run_output, cost_allocation, cost_entry_change, sale, sale_movement, attribution,
  reservation, shipment, stocktake_line, report_issued, approval, work_order_change, po_change, so_change, journal_entry.
  Live counts (rm_q4, `batch_audit_trail_all`, postgres unfiltered; **292 rows over 44 batches**): movement 107,
  journal_entry 47, receipt 24, output_created 20, run_output 17, run_input 14, price_change 14, approval 11, sale 9,
  sale_movement 9, cost_entry_change 7, stocktake_line 4, reservation 3, work_order_change 2, report_issued 1,
  shipment 1, cost_allocation 1, attribution 1; **po_change 0, so_change 0** (18 of 20 kinds present).
  Largest: IN-2026-0001's batch 33 rows.
* **Seams** — 11 declared (types:36-47): no_purchase_order, actor_unrecorded, actor_unresolvable, polymorphic_source,
  reversed, is_reversal, run_voided, has_masked_amount, amount_restricted, no_policy_admits, no_cogs_entry. Live
  (rm_q4, base view only, so the two reader-computed ones — amount_restricted, actor_unresolvable — are not counted):
  polymorphic_source 47, has_masked_amount 30, **actor_unrecorded 29** (11 movements, 9 sale_movement, 3 receipt,
  3 output_created, 2 run_output, 1 run_input), run_voided 22, no_purchase_order 14, no_cogs_entry 7, reversed 3,
  is_reversal 3, no_policy_admits 1.
* **Columns**: When (priority; + "Business date: …" line when it differs) · What (priority; `auditTrail.kind.*`) ·
  Detail (priority; summary or "Restricted (needs: <module_code>)" + ⚠ seam sentences) · Who (`<ActorName>`, server
  rendered; 4 phrasings, never a bare uuid) · Source (link to `href` with `source_code`, else `source_table`).
  Restricted rows get `bg-gray-50`.
* **Machine language still in it** (Measured, quoted): `needsModuleText: \`(${t('auditTrail.needsModule')}: ${r.module_code})\``
  → "(needs: module.finance.view)"; seam text `amount_restricted: 'Amounts withheld — you do not hold data.view_prices.'`;
  footer `UNREACHABLE_HISTORY_TABLES.join(…)` → "quote_history, task_history, customer_credit_history,
  employment_history, fx_rate_history, pricing_formula_history"; `sourceText: r.source_code ?? r.source_table` (table
  name fallback); `summarise()` prints raw `change_type`, `decision`, `memo`, bare `amount_base` with no currency.
* **Layout**: a `<section className="mt-8 pt-8 border-t">` with h2 "Audit Trail", intro, spine note, the DataTable,
  footer note. Placed **last** on `/inbound/[id]/edit` (page line 957 of 960) and `/output/[id]/edit` (508 of 511),
  after `MovementTimeline`. Desktop: 5 columns. 390px: `phone={{mode:'columns'}}` keeps When/What/Detail, Who+Source go
  into the row expander (BatchAuditTrailTable.tsx header). Pre-conversion measurement recorded in that header: 390px
  horizontal drag 281px (/inbound) · 301px (/output), row height up to 261px; desktop 1280px already scrolled 31/51px.
  Post-conversion overflow is **not recorded there** — not re-measured here (no screenshots, per brief).
* **Fixtures** (docs/batch-audit-trail.md §十): **181** reversed entry shows both posting and reversal (fault: missing
  reversed_by → reversal absent; memo without "REVERSAL" → still present); **182** seams named on the row (fault: link a
  PO line → no_purchase_order must disappear); **183** restricted reader gets named Restricted, not an empty section
  (fault: add module.finance.view → restricted disappears; per-column assertion that restricted rows carry no source
  values; 183G caught default-privilege grants on the inner view). Files: `db/fixtures/181-…`, `182-…`, `183-…`.

---

## 4. Detail-page template and existing history sections

### 4.1 Shared components a trail table would use (Measured, files read)
* `app/components/ui/data-table.tsx` (client, 875 lines): `DataTable<T>` with `Column{key, header, render, priority,
  phoneLabel, className, align}`, **required** `phone` prop (`{mode:'columns'}` needs ≥1 priority column or it throws
  `DATATABLE_NO_PHONE_COLUMNS`; `{mode:'scroll', why}` alternative), `empty`, `rowClassName`, `footer`, `pageSize`,
  `filter`, `selection`, `columnToggle`. Because `render` is a function, each use needs a `'use client'` table file
  fed with server-flattened rows (pattern: BatchAuditTrailTable, ChangeHistoryTable).
* `app/components/ui/record-header.tsx` (server): the header box (`fields`, `actions`) only — not relevant to the
  bottom region.
* `app/components/ActorName.tsx` + `loadActorNames` — the single way to name an actor (4 phrasings).
* `lib/dates.formatAuditStamp`, `app/components/ui/refusal` (`<Refusal>` "Restricted" pill).

### 4.2 Is there a common bottom region? — **No** (Measured)
`docs/detail-page-template.md` defines only `RecordHeader` + `DataTable`/`EditableTable` + `state` always 'ok'; it names
no footer/bottom slot for detail pages (headings grep: §①–⑬, none about a bottom region). Pages end differently:
the batch trail is a bordered `<section mt-8 pt-8 border-t>`; PO history is a `border rounded p-4` box in the
**middle** (line 855 of 1126, followed by notes/terms and more); sales/quotes/work-order history are `<h2 mt-8>` blocks
near the end; request panels put an `<h3>` history inside their own panel.

### 4.3 Detail pages that render a history/timeline section today
Method (Measured): 63 `page.tsx` under a `[param]` segment (`find app -name page.tsx -path '*\[*'`); for each, all
`*.tsx` in its directory with `//`-comment lines stripped, grep for `<…History…|Timeline|AuditTrail` components,
`_history` reads, and `t('…history|timeline|auditTrail…')`; then each hit checked for an actual heading (`<h2>/<h3>`).
**16 of 63 detail pages render one or more history sections** (2 further hits — `finance/fx/[id]/edit`,
`inbound/[id]/assays/[assayId]` — only read a `_history` table for other purposes, excluded):

| Page | Section (heading key / component) | Where in file |
|---|---|---|
| app/inbound/[id]/edit/page.tsx | `<MovementTimeline>`, `<BatchAuditTrail>`; PricingPanel `inbound.pricing.historyTitle`; ReceiptPriceRequestPanel `inbound.priceRequest.history`; PrepaymentPanel `purchasing.appliedHistory` | trail at 957/960 |
| app/output/[id]/edit/page.tsx | `<MovementTimeline>`, `<BatchAuditTrail>` | 508/511 |
| app/purchasing/orders/[id]/page.tsx | `purchasing.amend.historyTitle` (purchase_order_history; no actor shown) | 857/1126 (middle) |
| app/sales/orders/[id]/page.tsx | `sales.history` h2; ShippingReleasePanel `sales.release.history` h3 | 268/294 |
| app/sales/quotes/[id]/page.tsx | `sales.history` h2 | 257/271 |
| app/operation/orders/[id]/page.tsx | `processing.wo.history` h2 | 277/294 |
| app/hr/employees/[id]/page.tsx | `hr.historyTitle` h2 (employment_history) | 382/474 |
| app/finance/assets/[id]/page.tsx | `HistoryPanel` `assets.history.title` (fixed_assets history) | 523/540 |
| app/tools/tasks/[id]/page.tsx | `<ChangeHistory>` `tasks.history.heading` | 250/295 (participants follow) |
| app/finance/bank/statements/[id]/page.tsx | `bank.record.history` h2 | 300/403 |
| app/finance/gst/[periodId]/page.tsx | GstFilingPanel `gstFiling.history` h3 | panel |
| app/hr/payroll/[id]/page.tsx | PostControls `hr.payrollRequest.history` h3 | panel |
| app/finance/invoices/[id]/page.tsx | `<SettlementHistoryTable>`; InvoiceRequestPanel `finance.invoiceRequest.history` | — |
| app/finance/expenses/[id]/page.tsx | `<SettlementHistoryTable>` `finance.settlementHistory` | — |
| app/finance/payables/[batchId]/page.tsx | `<SettlementHistoryTable>` | — |
| app/finance/receivables/[saleId]/page.tsx | `<SettlementHistoryTable>` | — |

Non-`[param]` pages with a history section (same grep, Measured): settings/approvals (`<ApprovalsHistory>`),
settings/import (`<ImportHistoryTable>`), settings/change-history, finance/close (`CloseHistoryTable`,
`YearCloseHistoryTable`), finance/packs (`PacksHistoryTable`), me (`me.history`), and request-history lists on
inventory, hr/employees, finance/journal, finance/assets (10 pages). Approval-log readers: app/me, finance/self-approved,
purchasing/orders/[id], suppliers/[id]/edit (statusActions), tools/calendar (grep `approval_log`, code+comments).

---

## 5. Findings that contradict the brief or HISTORY-0
1. **No PO has line changes** in purchase_order_history: 10 rows / 6 POs / 0 line rows / 0 payment-term rows (Measured, rm_q6).
2. **Permission labels come from the DB (`permissions.name_en`), not `messages/en.ts`** (PermissionMatrix.tsx:88-95, :329; 72/72 labelled).
3. **The richest run has no losses and no approvals**: 0 `processing_run_losses` rows across all 14 runs; 0 approval_log rows for runs.
4. **The "cco rewrite" is unrecoverable history**: 41 grants all stamped 2026-09-28 19:00:35 by Tim, ~5 h before change_log began; what it replaced is not recorded anywhere.
5. **The 4 `user` rows belong to a deleted smoke account** (not in auth.users; no employee) — the log has no real human actor yet; and no ACCOUNT_* rows exist (smoke bypassed the accounts screen).
6. **Child lookup by jsonb FK misses UPDATE rows** (partial images) — a design constraint for AUDIT-TRAIL-1.
7. `batch_audit_trail` has **no reader function**; the reader is a view.
