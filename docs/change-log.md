# The change log (HISTORY-1, 2026-09-28)

Every insert, edit and delete in the system is written to one append-only table, `public.change_log`, with who made it
and what the row was before. Admin and the CFO read it on **Change history** (`/settings/change-history`). This page is
the reference for what is recorded, what is not, who can read it, and the rule every new table must follow.

Survey: `docs/surveys/HISTORY-0.md`. Rulings: Tim's answers to HISTORY-0 Q1–Q30 and HISTORY-1 Step 0 Q1–Q15 (2026-09-28),
recorded in `docs/handbacks/HISTORY-1.md`.

---

## 1. What is recorded

One trigger function, `change_log_capture()`, is attached to **238 of the 242 public tables** (two triggers each):

| trigger | fires | writes |
|---|---|---|
| `zzz_change_log` | `AFTER INSERT OR UPDATE OR DELETE … FOR EACH ROW` | one row per changed row |
| `zzz_change_log_truncate` | `AFTER TRUNCATE … FOR EACH STATEMENT` | one row per `TRUNCATE` |

The bindings live in one generated file, `db/views/zzz_change_log_triggers.sql` (generator:
`db/scripts/gen_change_log_bindings.py`). The names start with `zzz` because a table's AFTER triggers fire in name
order, so the change log sees the row last.

Each row holds:

| column | meaning |
|---|---|
| `seq` | the order of record (identity). `now()` ties inside one transaction; `seq` never does |
| `occurred_at` | `clock_timestamp()` — the moment of the write, not the start of the transaction |
| `txid` | the transaction, so several rows written together can be grouped |
| `table_name`, `row_key` | the table and the row's primary key as `{column: value}`. 19 tables have composite keys and 43 have a non-uuid key, so this is not a single id |
| `op` | `INSERT` · `UPDATE` · `DELETE` · `TRUNCATE`, or an account event (§6) |
| `actor_account` | the login account (`auth.uid()`) |
| `actor_employee` | the employee that account belonged to **at the moment of the write** (`account_person()`), frozen. tim@ and admin@ are one person on two accounts; this answers both "which login" and "which human", and a later change to the link does not rewrite history |
| `actor_kind` | `user`, or `no_session` for writes with no login (migrations, fixtures, the service role). Never a blank actor |
| `db_role` | the database role of the write: `authenticated`, `service_role`, or `postgres`. Read from the `role` setting, not `current_user` (inside the SECURITY DEFINER trigger `current_user` is always the owner) |
| `changed_columns`, `old`, `new` | **edit**: only the columns that changed, before and after. **insert**: the full new row. **delete**: the full old row. An edit that changes nothing writes no row |
| `redacted_at` | set when anonymisation redacted this row (§5) |

The 17 domain history tables (`approval_log`, `purchase_order_history`, `task_history`, …) are **kept as they are**
alongside the log (Tim's Q3). They carry meaning a row diff cannot: a reason, an approval level, an event name. The log
also covers them, so an insert into a history table is itself recorded.

## 2. What is not recorded, and why

**Excluded tables.** The list lives in one place, `change_log_exclusions()` (`db/functions/change_log_exclusions.sql`),
each entry with its reason:

| table | reason |
|---|---|
| `change_log` | the log itself; a trigger on it would record its own writes |
| `festival_doodles` | home-screen holiday artwork; screen decoration with no business meaning |
| `home_greetings` | home-screen greeting text; screen decoration with no business meaning |
| `notification_reads` | per-viewer "seen" marks on notifications; screen state with no business meaning |

**TRUNCATE captures the fact, not the rows.** A `TRUNCATE` on a covered table writes one row (`op = 'TRUNCATE'`,
`row_key` null, with the actor), but **the rows it removed are not recorded**. Row triggers do not fire for `TRUNCATE`.
No application path truncates a business table today.

**Storage uploads are not logged themselves** (Q28). Every bucket upload has a metadata row in a public table
(`*_attachments`, `finance_attachments`), and that row is logged.

**The auth schema is not ours to trigger.** Account lifecycle is recorded by the application instead (§6).

**Test accounts are outside the account rules.** The smoke test, the probes and `sweep-ghost-grants` create and delete
throwaway `*@test.local` accounts over the admin REST API. They are not real login accounts, and they keep being
**deleted**, not disabled; disabling them would leave hundreds of dead accounts behind (Q4). Their writes to public
tables are logged by the trigger like any other.

**Rolled-back transactions leave nothing.** A fixture run against live inside `BEGIN … ROLLBACK` writes log rows and
rolls them back with everything else (Q29).

## 3. Protection

| against | what happens |
|---|---|
| `anon`, `authenticated`, `service_role` | **no privilege at all** on `change_log` — `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE` all refused (`permission denied`). RLS is on with no policy, as a second lock |
| the owner (`postgres`) or a SECURITY DEFINER function | `UPDATE` and `DELETE` raise `CHANGE_LOG_IMMUTABLE` (row trigger); `TRUNCATE` raises the same (statement trigger). The one `UPDATE` allowed is the redaction shape (§5) |
| the 17 history tables | `TRUNCATE` refused on all 17 (`HISTORY_TRUNCATE_FORBIDDEN`). `task_history` and `work_order_history` now also refuse `UPDATE` / `DELETE` (`TASK_HISTORY_IMMUTABLE`, `WORK_ORDER_HISTORY_IMMUTABLE`), like the other 15 |

**Known limit — the owner can bypass this** (`docs/known-issues.md` `HISTORY1-OWNER-BYPASS`). `postgres` owns the tables
and can `ALTER TABLE … DISABLE TRIGGER` or set `session_replication_role = replica`. The log is append-only for every
**application** role, not for the owner. Tamper evidence against the owner (a hash chain, or an off-database export) is
a registered later cut (Tim's Q14).

## 4. Who can read it, and what they see

**The global reader is one function**, `change_log_rows()`, which requires the permission code **`data.view_change_log`**.
It is granted to `admin` and `cfo` only and bundled into no other role (Q10 · Q1). Its screen is
**Change history**, `/settings/change-history`. It sits under Settings and in the Finance **Reports** group, with one
registry entry and one code.

**Since AUDIT-TRAIL-1a (v1.4.33) the page reads in plain English**, in the same words as the per-page audit trails (§9):
one line per operation (database transaction), columns When · Who · Record · What happened, times `DD/MM/YYYY HH:MM`
Singapore time. Filters: date range · Area · Record type (English names from `lib/trail/catalogue.generated.ts`) ·
Record (a document number or a name, found by `change_log_find_records()`) · Who (a person, "System (automatic)",
"Removed account") · Key events only. Newest first: 20 operations, then "Show older entries" extends the list by 20 (up to
500) — the same shape as every page trail since AUDIT-TRAIL-1b-1 (Tim's fold-in 2, replacing AT-1a's 25-per-page
Newest / Older). Everything inside the list section — columns, entries, empty states, the paging note, "Show older
entries" — is English; the page title, intro and filters follow the interface language (fold-in 3, Q7). It still lists
every write (Q31).
Each page's own trail is a **different** reader, `record_trail()` (§9) — the global reader was not widened.

**Masking follows the source screens.** A value the reader cannot see on its own screen is replaced by
`{"$restricted": true}` and rendered as **Restricted**. A value that is genuinely empty stays empty and renders as
**(empty)** (a blank before AUDIT-TRAIL-1a). The two are never confused. Since AUDIT-TRAIL-1a the masking is **one step**,
`change_log_mask_row()`, called by both readers (§9.3).

- The rules are one list, `change_log_mask_rules()`: one row per column, ~~80 columns on 26 tables~~ **101 columns on 33
  tables since U1-A** (2026-10-05, §10). They were copied from the `CASE WHEN … END AS <column>` of every `<table>_masked`
  view, plus the new `purchase_order_history_masked`.
- Rule forms:
  - `code:<data code>`;
  - `code_or_self:<code>:<column>`, where the reader's own employee row counts, as in `employees_masked`;
  - `pft:direction` and `pft:formula_id`, where a sales formula asks `data.view_prices` and anything else asks
    `data.view_purchase_prices`;
  - `pft3`, for `pricing_formula_history`;
  - `pay_journal:<code>` (U1-A): visible with the code, or when the line's journal entry is not a payroll entry
    (`journal_lines_masked`);
  - `apr_amount` (U1-A): `approval_log_amount_visible(subject_type, subject_id)` — the same function the view calls
    (`approval_log_masked`).
- **Keeping the list in step is enforced:** `change_log_mask_gaps()` compares the list against the catalogue's
  actually-masked columns. A missing rule (the log would leak what the screen hides) or a stale rule fails the gate
  (`changemask` line, live and rebuild) and fixture 234.

**`purchase_order_history` prices are now masked** (Q20). Estimated unit price, amount, total, FX rate and the payment-term
snapshot are hidden behind `data.view_purchase_prices`, like the purchase-order lines. The base-table SELECT on those
columns is revoked. `/purchasing/orders/[id]` reads `purchase_order_history_masked`.

**Private tasks are private here too** (Q6). For the four task tables (`tasks`, `task_nodes`, `task_participants`,
`task_history`), a row is shown only to a reader who passes `can_view_task`. Admin and the CFO do not hold
`module.tasks.view_all`, so someone else's personal task shows only when, who and what kind of change, with every field
Restricted.

## 5. Anonymisation and redaction

`anonymise_employee` (code `action.anonymise_employee`) is the **one** path that can change a log row. After its own
updates, in the same transaction, it calls `change_log_redact_employee`, which:

- nulls, in every log row for that employee's `employees` row **and** for their `employment_history` rows, exactly the
  fields anonymisation clears (`change_log_redactable_columns()`). These include `greeting_name`, which anonymisation now
  also clears (Q9);
- **since U1-A (2026-10-05, Tim's UNBLOCK-1 Q11)** also nulls, in the log rows of that employee's
  `salary_change_requests`, `payroll_lines`, `leave_requests` and `medical_claims`, the **free text** on them — reasons,
  descriptions, notes, decision notes, certificate and receipt references — and **never an amount** (§10.4);
- stamps `redacted_at`;
- must run **after** the anonymisation `UPDATE`, because that update is itself logged and its `old` image holds every
  personal field. Fixture 234 pins this.

The guard proves nothing else changed, by the **shape** of the update, not a session flag:
- `redacted_at` goes from null to set;
- every column except `old` / `new` / `redacted_at` is unchanged, compared as the whole row, so a column added later
  falls on the refused side;
- in `old` and `new` the key set is identical, and every changed key is on the allow-list and now null.

Any other update raises `CHANGE_LOG_IMMUTABLE`.

**The personal-data export** (`export_my_personal_data`) now includes `my_record_changes`: every log row about the
requester's own `employees` row, with time, operation, changed fields, before and after. The actor is given as an
employee name only. Keys that hold login account ids (`user_id`, `created_by`, `updated_by`, `anonymised_by`) are
removed (Q12 · Q10).

## 6. Accounts: disabled, not deleted

Accounts are **disabled** (Supabase `ban_duration`, which sets `auth.users.banned_until`), never deleted from the
accounts screen (Q22). There is no delete control. Every account event is written to the log with `table_name = 'auth.users'`
by `record_account_event()`, called with the signed-in admin's own session, so the actor is the person who pressed the
button (Q23):

| event | when |
|---|---|
| `ACCOUNT_CREATE` | right after the account is created, before linking and role assignment |
| `ACCOUNT_DELETE` | only when a half-created account is rolled back (`reason: create_rolled_back`); the account must already be gone |
| `ACCOUNT_DISABLE` / `ACCOUNT_ENABLE` | recorded **before** the ban is applied or lifted |
| `ACCOUNT_DISABLE_FAILED` / `ACCOUNT_ENABLE_FAILED` | the auth step failed after the event was recorded |

Refusals, all decided in the database: `CANNOT_DISABLE_SELF`, `ACCOUNT_ALREADY_DISABLED`, `ACCOUNT_NOT_DISABLED`,
`LAST_ADMIN_PROTECTED` (the same test as `guard_last_admin`: `real_role_grants` on an active `is_system` role,
excluding this account). How long an already-issued access token keeps working after a disable was measured on live;
see `docs/handbacks/HISTORY-1.md` and `docs/known-issues.md`.

`set_role_permissions` now changes only the codes that differ (Q16), so one save of a role logs exactly the codes added
and removed.

## 7. The rule: every new table must be covered

> **Every new public table either gets the two change-log triggers, or an entry in `change_log_exclusions()` with a
> written reason. Nothing else passes.**

When you add a table:

1. In the migration, add its two triggers. Generate them with
   `python3 db/scripts/gen_change_log_bindings.py --only <table>` (run it after the table exists, or copy the shape;
   the arguments are the primary-key column names).
2. Add the same two lines to `db/views/zzz_change_log_triggers.sql`.
3. **Or** add a line to `change_log_exclusions()` with the reason. A screen-state table with no business meaning is the
   only accepted kind so far.
4. If the table is **masked** (a `<table>_masked` view), add its masked columns to `change_log_mask_rules()` in the
   same commit.

Two checks enforce it, and each has been fault-injected:

| check | reads | when |
|---|---|---|
| `scripts/check-change-log-coverage.mjs` (in `npm run build`) | the repository: `db/tables/*.sql`, the bindings file, the exclusion list | as soon as the mirror is written, before anything touches live. Injects three failures into itself on every run |
| `db/gate.py` line `changelog` | the live catalogue **and** the local rebuild, via `change_log_coverage_gaps()` | at the gate. Also catches a trigger that is present but **disabled**. Fails if it saw fewer than 200 tables |
| `db/gate.py` line `changemask` | the same two sides, via `change_log_mask_gaps()` | at the gate. Fails if it saw fewer than 20 masked tables |

Fixtures 234 and 235 pin the behaviour. Every arm was fault-injected and went red; the matrix is in the handback.

## 8. Cost

- Trigger cost, measured on a local PG 17 with 20,000 rows each:
  - +6.4 µs per inserted row;
  - +21 µs per updated row;
  - +6.6 µs per deleted row.
- The offline gate went from 58 s to 61 s, with 238 bindings and two new fixtures.
- The live database had written 103,579 rows over its whole life when this landed. There is no retention limit; the
  log is kept whole (Q15).

## 9. Audit trails on each page (AUDIT-TRAIL-1a, 2026-09-29)

Every page where something is done, or whose record it affects, carries an **"Audit trail"** section at the bottom:
when, who and what happened, in plain English, newest first. AUDIT-TRAIL-1a (v1.4.33) built the mechanism and the first
three pages; AUDIT-TRAIL-1b-1 (part of v1.4.33) added six registry extensions (M1–M6, §9.9), the batch, work-order,
stocktake, equipment, handover and warehouse-request subjects, and three corrections to AT-1a (§9.7, §9.4); AUDIT-TRAIL-1b-2
(part of v1.4.33) added the commercial half — quotes, sales orders, shipments, customers, commission agreements, suppliers,
forwarders, containers, lanes and ports, company licences — and replaced the quote and sales-order "History" sections;
AUDIT-TRAIL-1b-3 (part of v1.4.33) added master data and tools — materials, storage locations, metal prices, pricing formulas and
their terms requests, tasks (personal tasks too), the three threshold panels — replaced the task "Change history" section, and
made deleted master data and deleted sales orders, quotes and purchase orders open read-only for `data.view_deleted` holders
(§9.10). That completes AT-1b. AUDIT-TRAIL-1c-1 (part of v1.4.33) added the ledger documents — journals, invoices, credit
notes, payments, payment requests, expenses and the payable view of an inbound batch — and three mechanism changes (M7, the
operation key, employee names in references; §9.9, §9.11). AUDIT-TRAIL-1c-2 (part of v1.4.33) added the rest of the documents
and contracts — sales, freight documents, fixed assets (the finance page), bank statements, GST periods, FX rates, management packs and
contracts — replaced the asset page's "Change history" panel, and made deleted bank statements and withdrawn FX rates open read-only
(§9.12). AUDIT-TRAIL-1c-3 (part of v1.4.33) added period-end, settings and the list homes — the period-lock and GST panels on the
shared settings row (each showing only its own columns; the lock's trail also shows month close and reopen), `/finance/close`, the company
profile, and list-level blocks for year closes, revaluation and depreciation runs, bulk FX, cash forecasts and recurring lines, payroll
journals, processing-cost settlement, WHT remittances, bank transfers, import mappings and deleted statements; a trail per journal request
and per expense claim, and the claimant's own claim on `/me` (§9.13, M8 in §9.9). That completes AT-1c. AUDIT-TRAIL-1d-1 (part of
v1.4.33) built the last four mechanism pieces — M9 (a log-only root: login accounts), M10 (a member limited to declared columns), M11 (a
collection subject), M12 (a gate narrower than the table's rule) — made `/settings/change-history` re-check each row's read rule (Q13), and
added accounts (per account on `/settings/accounts`, mirrored on the employee page), role grants on the role page, the approval-policy panel,
the six dictionaries, the import-batch block, employees, departments and training records, with deleted roles, employees, departments and
training records opening read-only (§9.14). AUDIT-TRAIL-1d-2 (part of v1.4.33) added leave and time — leave requests, leave grants, leave types
and public holidays (collections, a deleted holiday included), medical claims (reachable from the expense that pays them), overtime batches,
attendance periods, and the employee's own leave requests and medical claims on `/me` (§9.15). AUDIT-TRAIL-1d-3 (the last part of
v1.4.33) added pay and performance — payroll periods (pay lines paired by employee, the request history replaced), performance reviews and the
reviewer's own page (`/my-reviews/[id]`, the first M12 subject), review cycles, the rating scale and KPI entries — and fixed Q19: an employee
without `module.hr.view` now reads the code and month of the periods their own attendance line or payslip belongs to (§9.16). That completes
AT-1d, and with it AUDIT-TRAIL-1 (v1.4.33).
Rulings: AUDIT-TRAIL-0 Q1–Q43 (`docs/surveys/AUDIT-TRAIL-0/README.md`), AT-1b Step 0 Q1–Q14 + M1–M6
(`docs/surveys/AUDIT-TRAIL-1b/STEP0-HANDBACK.md`) and AT-1c Step 0 Q1–Q34 (`docs/surveys/AUDIT-TRAIL-1c/STEP0-HANDBACK.md`),
all accepted as recommended; AT-1d Step 0 Q1–Q38 (`docs/surveys/AUDIT-TRAIL-1d/STEP0-HANDBACK.md`), all accepted as recommended.

| page | subject | view code | what rolls up into its trail |
|---|---|---|---|
| `/purchasing/orders/[id]` | `purchase_order` | `module.purchasing.view` | the order · lines · payment terms · retentions · committed pricing terms · PO issues · contract terms · approval decisions · amendment history |
| `/operation/processing/[id]` | `processing_run` | `module.processing.view` | the run · inputs · outputs · cost entries and their history · cost allocations · losses |
| `/settings/roles/[id]` | `role` | `action.manage_permissions` | the role · its permissions (added / removed, named from `permissions.name_en`) |
| `/inbound/[id]/edit` | `inbound_batch` | `module.inbound.view` | the batch · metal content · assays and their metals · safety states · price changes · receipt price requests and their approvals · prepayments · pricing terms and their metals · stock movements · stocktake lines and every count · processing use · cost allocations · certificates of destruction and their PDFs · warehouse requests (write-off, certificate void) and their approvals · freight and payment allocations · finance attachments · journals (pricing, write-off, prepayment) — and, one hop up (M4), the approvals and amendments of the purchase order it was received against, the cost changes, cost and allocation journals and work-order history and approvals of the runs that consumed it, the journals of the stocktakes that counted it, and every reversal of those journals |
| `/output/[id]/edit` | `output_batch` | `module.output.view` | the same shape for an output batch, plus its sales (sale records, their stock movements, attributions, invoice lines, payment allocations, COGS journals), reservations, shipment lines, traceability reports and settlements; one hop up: the runs that produced or consumed it and the sales-order history of the order lines it was sold against |
| `/operation/orders/[id]` | `work_order` | `module.processing.view` | the work order · input lines · expected outputs · its history · release approvals |
| `/stocktakes/[id]` | `stocktake` | `module.stocktakes.view` | the stocktake · its lines · every count · its posting approval · its posting journal (finance readers) |
| `/operation/equipment/[id]` | `equipment` | `module.processing.view` (root rule `page`, M3) | the asset card (finance readers only; Restricted for the rest) · servicing and repairs · downtime · service intervals · handovers that referenced a downtime |
| `/operation/handovers/[id]` | `shift_handover` | `module.processing.view` | the handover · its items · the downtime it referenced |
| `/inventory` (a block) | `warehouse_request` | `module.inventory.view` **or** `module.finance.view` (M1) | the request · its approvals — read per request and merged by `app/components/trail/RecentTrail.tsx` |
| `/operation/processing/[id]` (1b-1 addition) | `processing_run` | — | + its rollback requests and their approvals |
| `/sales/quotes/[id]` (1b-2) | `quote` | `module.sales.view` | the quote · its lines · its PDF issues · its history (created, issued, declined, converted) — replaces the page's "History" section (Q26) |
| `/sales/orders/[id]` (1b-2) | `sales_order` | `module.sales.view` | the order · its lines · the lines' reservations · shipping releases, their lines and approvals · PDF issues · its history (created, confirmed, issued, reserved, released, invoiced, invoice voided, shipped, credit note, amendments, converted from a quote) · contract terms — replaces the page's "History" section (Q26); the page keeps a narrowed history query for "amended since issued" and the "From quote" link |
| `/sales/shipments/[id]` (1b-2) | `shipment` | `module.sales.view` **or** `action.ship_goods` (M1) | the shipment · its lines · its delivery-note issues |
| `/sales/customers/[id]` (1b-2) | `customer` | `module.customers.view` | the customer · contacts · attachments · credit history · statements and their PDF issues · payment chases, the documents they name and the promises (the last five are finance-only: Restricted rows for other readers, Q4) |
| `/sales/commissions/[id]/edit` (1b-2, its only page, Q2) | `commission_agreement` | `module.suppliers.view` | the agreement |
| `/suppliers/[id]/edit` (1b-2, its only page, Q2) | `supplier` | `module.suppliers.view` | the supplier · compliance certificates · attachments · contacts · status history · approval decisions |
| `/logistics/containers/[id]` (1b-2) | `container` | `module.logistics.view` | the container · milestones (a detachment is a milestone whose note carries the reason) · document checklist |
| `/logistics/forwarders/[id]` (1b-2) | `forwarder` | `module.logistics.view` (root rule `page`, M3) | the forwarder's supplier row (suppliers.view readers only; Restricted for the rest) · logistics details · rate quotes |
| `/logistics/lanes` (1b-2, a list-level block) | `lane` · `port` | `module.logistics.view` | each lane · its document requirements; each port · the lanes leaving and arriving at it (two foreign keys, two members) — read per record and merged by `app/components/trail/ListTrail.tsx` |
| `/purchasing/licences` (1b-2, a list-level block) | `company_licence` | `module.suppliers.view` (the table's rule; the block sits in the page's suppliers.view branch) | each licence — read per record by `ListTrail` |
| `/materials/[id]/edit` (1b-3, its only page, Q2) | `material` | `module.materials.view` | the material · its attachments · its assay requirement (which metals a batch must be assayed for; written delete-all + insert, netted to what changed) |
| `/inventory/locations/[id]/edit` (1b-3, its only page) | `storage_location` | `module.inventory.view` | the location · its allowed material classes — saved by `save_storage_location`, one call that writes only what changed (Q13) |
| `/tools/pricing/metal-prices/[id]/edit` (1b-3, its only page) | `metal_price` | `action.metal_prices` (the edit page's guard) | the quote |
| `/tools/pricing/formulas/[id]/edit` (1b-3, its only page) | `pricing_formula` | `module.pricing.view` | the formula · its payable metals · its history · its terms requests and their approvals (requests need the price codes: Restricted rows for other readers, Q4) |
| `/tools/tasks/[id]` (1b-3) | `task` | `module.tasks.view` + the task's own read rule (team, own, or `module.tasks.view_all`) | the task · its steps · its participants · its history — personal tasks too (Q3); replaces the page's "Change history" section (Q26) |
| `/operation/orders` (1b-3, under the panel) | `processing_settings` | `module.processing.view` | the variance-threshold panel's two columns only (M5 · M6) |
| `/tools/pricing/metal-prices` (1b-3, under the panel) | `pricing_settings` | `module.pricing.view` | the price-anomaly panel's one column only (M5 · M6) |
| `/purchasing/discrepancies` (1b-3, under the panel) | `receiving_settings` | `module.inbound.view` (the panel's own branch) | the discrepancy-threshold panel's three columns only (M5 · M6) |
| `/finance/journal/[id]` (1c-1) | `journal_entry` | `module.finance.view` | the entry · its lines · its reversal (one hop up through `reversed_by` — **one linked line**, its lines stay on its own page, Q33) · on a reversal's page the entry it reversed · the manual-journal or reversal requests and their approvals |
| `/finance/invoices/[id]` (1c-1) | `invoice` | `module.finance.view` | the invoice · its lines · PDF issues · void / credit-note requests and their approvals · credit notes it carries · payments allocated to it · its journal and that journal's reversal — replaces the invoice-request "history" list (Q26) |
| `/finance/credit-notes/[id]` (1c-1) | `credit_note` | `module.finance.view` | the credit note · its lines · PDF issues · the request that issued it and its approval · its journal |
| `/finance/payments/[id]` (1c-1) | `payment` | `module.finance.view` | the payment · its allocations · attachments · the payment that reversed it (one hop up) / on a reversal, the payment it reversed · the requests that paid or reversed it and their approvals · its journal and reversal |
| `/finance/payment-requests/[id]` (1c-1) | `payment_request` | `module.finance.view` | the request · its approvals · the payment it made · bank transfers and WHT remittances it made or reversed (they have no page of their own, Q17) · the journals posted |
| `/finance/expenses/[id]` (1c-1) | `expense` | `module.finance.view` | the expense · allocations · attachments · prepayments released against it · the expense that reversed it / that it reversed · the expense claim that posted it · asset cost it capitalised · its journals |
| `/finance/payables/[batchId]` (1c-1) | `payable` | `module.finance.view` (root rule `page`, M3; `root_columns` = the payable columns, M6) | the batch's money side only — supplier, PO, quantity, unit price, pricing status, arrival date, write-off · payment and freight allocations · prepayments · finance attachments · price changes · purchase / write-off / prepayment journals and their reversals. The warehouse side (assays, safety states, stock moves) stays on `/inbound/[id]/edit` |
| `/finance/receivables/[saleId]` (1c-2) | `sale` | `module.finance.view` | the sale · its stock issue · the customer attributed to it (and the attribution note) · the invoice line that bills it · payments allocated to it · finance attachments · its revenue journal, its cost-of-sales journal and their reversals (Q14: the summary page's Record column names the sale "OUT-… sale DD/MM/YYYY" and links here) |
| `/finance/freight/[id]` (1c-2) | `freight` | `module.finance.view` | the freight document · its apportionment to batches · payments allocated to it · its posting journal · its reversal journal |
| `/finance/assets/[id]` (1c-2) | `fixed_asset` | `module.finance.view` (the same root as `equipment`; a second subject, Q10) | the asset card · its history (`fixed_asset_history` before the log; the card's own change-log rows after) · cost entries · depreciation charges and re-basings · disposal requests and their approvals · the disposal and depreciation journals · servicing, downtime and service intervals (their home stays `equipment`) — replaces FA-HIST-1's "Change history" panel (Q26) |
| `/finance/bank/statements/[id]` (1c-2) | `bank_statement` | `module.finance.view` | the statement · its lines and each line's match · its reconciliation records and their explained differences (a deleted statement opens read-only for `data.view_deleted`, Q6) |
| `/finance/gst/[periodId]` (1c-2) | `gst_period` | `module.finance.view` | the period · its filing requests and their approvals · the boxes locked at approval (folded into that entry, English only — Q23). A correction period is **not** linked into the original (Q22) |
| `/finance/fx/[id]/edit` (1c-2, its only page) | `fx_rate` | `module.finance.view` | the rate · its history (recorded, corrected with a reason, withdrawn with a reason) — a withdrawn rate opens read-only (Q7) |
| `/finance/packs/[id]` (1c-2) | `management_pack` | `module.finance.view` | the pack (produced; replaced by a later pack, which is a link) — no members (Q25) |
| `/contracts/[id]` (1c-2) | `contract` | `module.suppliers.view` (the page guard; the root's own rule is side-dependent) | the contract · its seven term tables · its activation requests and the CFO's decisions (Restricted for a reader without `module.pricing.view`, Q21) · the purchase or sales orders it was linked to |
| `/finance/settings`, under the lock form; `/finance/close`, under close history (1c-3) | `finance_lock` | `module.finance.view` (M5 · M6: `locked_before` only) | every lock move · every month close and reopen (`period_closes`, the whole table — M7), the close's notes and totals, the reopen reason |
| `/finance/settings`, under the GST panel (1c-3) | `finance_gst` | `module.finance.view` (M5 · M6: `gst_registered`, `gst_registration_no`) | the registration switch and number only. The six columns no panel owns (`gst_rate_pct`, `system_start_date`, the three financial-year columns, `default_allocation_basis`) are on no panel's trail — only on `/settings/change-history` (Q4); the four approval-policy columns are AT-1d's (Q2) |
| `/finance/company` (1c-3) | `company_profile` | `module.finance.view` (M5, whole row) | the company profile (the five bank columns Restricted without `data.view_banking`) |
| `/finance/close`, year-close block (1c-3, `ListTrail`) | `year_close` | `module.finance.view` | each year close and reopen · its closing and reversal journals (lines of the sentence) |
| `/finance/journal`, inside each request card (1c-3, Q17) | `journal_request` | `module.finance.view` | the request · its approval · the journal it posted. The request and its approval now home on the request on `/settings/change-history` |
| `/finance/claims`, one per claim (1c-3, Q20) | `expense_claim` | `module.finance.view` | the claim · its approval · its receipts · the expense it recorded |
| `/me`, one per own claim (1c-3, Q20) | `my_expense_claim` | **none** (M8: the claim's own read rule — finance, or the claim is yours) | the same rows; the approval and the expense are Restricted to a claimant without finance (Q4) |
| `/finance/bank` (1c-3, `ListTrail`) | `bank_transfer` | `module.finance.view` | each transfer · its journal and reversal journal · the requests that made and reversed it, and their approvals |
| `/finance/wht` (1c-3, `ListTrail`) | `wht_remittance` | `module.finance.view` | each remittance · its journal · its reversal ("WHT remittance reversed", Q30) · the requests that made and reversed it, and their approvals |
| `/finance/cash-forecast` (1c-3, `ListTrail`) | `cash_forecast` · `cash_forecast_line` | `module.finance.view` | each frozen forecast (frozen; replaced by a later one — one operation with the new freeze, Q16) · each recurring line |
| `/finance/bank/import` (1c-3, `ListTrail`) | `bank_import_profile` | `module.finance.view` | each import mapping, deleted ones included |
| `/finance/revaluation`, `/finance/assets`, `/finance/payroll-payments`, `/finance/processing-costs`, `/finance/fx`, `/finance/bank/statements` (1c-3, `ListTrail`) | `journal_entry` · `expense` · `fx_rate` · `bank_statement` | `module.finance.view` (the statements block: `data.view_deleted` too, as the statement's page) | revaluation, depreciation (each asset a line) and payroll journals; processing-cost remittance journals and relief expenses (Q19); the rates on the page and every withdrawn rate (a bulk save is one entry, Q16); deleted statements — each record links to its own page |
| `/settings/accounts`, one per account row (1d-1, Q24, compact) | `account` | `action.manage_permissions` (root `auth.users` — M9: a safe projection and a declared read code) | account created / disabled / could not be disabled / re-enabled / removed (a creation rolled back) · the roles granted to it and removed from it (home here, Q22) · it as an additional login of an employee and that link's history · it as an employee's primary login (`employees.user_id` only — M10) |
| `/settings/roles/[id]` (AT-1a, extended in 1d-1) | `role` | `action.manage_permissions` | + who the role was granted to and removed from (`user_roles`, not home — "Role granted to <name>", Q22) |
| `/settings/approvals` (1d-1, Q25) | `approval_policy` | `action.manage_permissions` (M5 · M6: the four policy columns; root rule `table`, so the reader needs `module.finance.view` too — Q23) | approvals switched on / off, level-1 / level-2 approver role, threshold · its history `finance_settings_history` (M7) — replaces `ApprovalsHistory` (Q27) |
| `/settings/dictionaries`, one per section (1d-1, Q4, compact) | `dictionary_substances` … `dictionary_inbound_source_reasons` (six) | each section's view code (`module.materials.view` ×4, `module.inbound.view` ×2) | M11: every value of that dictionary — added, changed, deactivated, reactivated. Dictionaries have no timestamps, so nothing before the log |
| `/settings/import` (1d-1, `ListTrail`, Q24) | `import_batch` | `action.bulk_import` | each batch: who, when, file, rows, first and last number. Imported records carry no link back to their batch (the `import_batches` table comment, Q24) |
| `/hr/employees/[id]` (1d-1, Q28) | `employee` | `module.hr.view` | the employee · employment history · salary change requests and their approvals (Restricted without `data.view_pay`) · training records (home: the training record) · additional logins and their history · the account mirror (Q24 · Q21): the primary and additional login accounts (up, M9) and their role grants — account events and the link history are Restricted to a reader without `action.manage_permissions`; grants are visible (every login reads `user_roles`) |
| `/hr/departments/[id]/edit` · `/hr/training/[id]/edit` (1d-1, their only pages) | `department` · `training_record` | `module.hr.view` | the department · the training record |
| `/hr/leave/[id]` (1d-2) | `leave_request` | `module.hr.view` | the request · its decision or cancellation · the days drawn from or returned to the balance (`leave_consumption`) · its approval rows (folded into the decision) |
| `/me`, one per own leave request and medical claim (1d-2, Q14, compact) | `my_leave_request` · `my_medical_claim` | **none** (M8: the row's own rule — HR, or it is yours) | the same rows; approvals, draws and the finance side are Restricted to the employee (Q4); names follow the ActorName rule (Q15) |
| `/hr/leave/grants` (1d-2, `ListTrail`, the selected leave year) | `leave_grant` | `module.hr.view` | each grant; one carry-forward run reads as one entry, "Unused leave carried forward · N people" (Q16) |
| `/hr/leave/types` · `/hr/leave/holidays` (1d-2, one block per page) | `leave_types` · `public_holidays` | `module.hr.view` | M11: every leave type / every public holiday — added, changed, deactivated, and (holidays) hard-deleted, said with its last values |
| `/hr/claims/[id]` (1d-2) | `medical_claim` | `module.hr.view` | the claim · its decision (approval folded in) · its withdrawal · the expense raised to pay it, that expense's journal, allocations and reversal (finance only — Restricted for an HR-only reader) |
| `/finance/expenses/[id]` (1c-1, extended in 1d-2, Q37) | `expense` | `module.finance.view` | + the medical claim that the expense pays (not home) |
| `/hr/overtime/[id]` (1d-2) | `overtime_batch` | `module.hr.view` **or** `action.overtime_enter` **or** `action.overtime_approve` (M1) | the batch · its lines (removed lines from their last image) · sent for approval / taken back / approved / "Overtime sent back" (Q35) / reversed / discarded, with the approval rows folded in |
| `/hr/attendance/[id]` (1d-2) | `attendance_period` | `module.hr.view` | the period · opened (people) · joiners added · each line recorded · completed (one sentence for the mass updates) · reopened with its reason |
| `/hr/payroll/[id]` (1d-3) | `payroll_period` | `module.hr.view` | the period · its pay lines (deleted and re-inserted on every save, paired by employee — Q11) · posting and unposting requests and their approvals · the period's journals (posting, salaries, CPF, deductions — by `source_id`, not by `journal_entry_id`, which an unpost clears) and their reversals (finance only — Restricted for an HR-only reader). Replaces the request panel's "Earlier requests" list (Q27) |
| `/hr/reviews/[id]` (1d-3) | `performance_review` | `module.hr.view` (root rule `table`: hr.view and `data.view_reviews`, or the reviewer, or the employee once approved) | the review (opened — an annual one with its cycle, Q6 · self-assessment · conclusion · reviewer · HR decision · submitted · approved with its outcome, Q7 · acknowledged · voided) · its goals (removed goals from their last image) · its approval rows (folded in) |
| `/my-reviews/[id]` (1d-3, Q5) | `my_review` | **none** (M8 + M12 `gate:reviewer`: the reviewer only — not the reviewed employee, who can read the approved row) | the same rows; the approval rows are Restricted to a reviewer without `module.hr.view` (Q4) |
| `/hr/reviews/cycles` (1d-3, `ListTrail`) | `review_cycle` | `module.hr.view` | each cycle: created · opened · closed. The reviews opening creates are not members (Q6) — each review's own trail opens with "Annual review opened (cycle …)" |
| `/hr/reviews/scale` (1d-3, one block) | `review_rating_scale` | `module.hr.view` | M11: every rating — added, changed, deactivated, reactivated |
| `/hr/kpi/score?cycle=…` (1d-3, `ListTrail`, only where scores are visible) | `kpi_entry` | `module.hr.view` (root rule `table`: hr.view and `data.view_reviews`, or own) | each entry of the chosen month: generated (one generation is one entry) · scored · re-scored. No KPI or review trail on `/me` (Q14 · Q16) |

### 9.1 The reader: `record_trail(subject, id, entries)`

- **The page names a subject, never a table.** `trail_subjects()` maps each subject to its root table and the page's own
  view codes (**any one of them admits**, M1 — the same shape as a page guard that accepts either of two codes);
  an unknown subject raises **`TRAIL_SUBJECT_UNKNOWN`**.
- **Authorisation, three layers.** (1) The page's view codes (`has_any_permission`; since AUDIT-TRAIL-1c-3 a subject may declare **no**
  code — M8, §9.9 — and then only layer (2) applies). (2) The root row's own read rule — the
  table's permissive SELECT/ALL policies re-evaluated on that row (`trail_row_visible`), or on its last image if it was
  hard-deleted. A subject whose `root_rule` is `page` (M3; today only `equipment`, whose root `fixed_assets` is
  finance-only while the page is for processing) skips this layer: the page's code is the gate, and the root row's own
  events are then shown or Restricted exactly like a child row's. (3) **Every child or related row is re-checked against its own table's read rule**, not the parent's (Q4).
  A failure at (1) or (2), including a record that does not exist, raises **`TRAIL_NOT_PERMITTED`**.
  **Refusals always raise; the reader never returns an empty list for a refusal** — an empty list reads as "nothing ever
  happened". Re-evaluating policies inside a SECURITY DEFINER function is sound because all 287 read policies resolve the
  caller from the login (`has_permission`, `current_user_employee`), none from the database role, and none is restrictive
  (measured, AUDIT-TRAIL-0 `reader-masking.md` §1.6); restrictive policies would be ANDed in if they ever appear.
- **Every row carries its operation (`op_key`, AUDIT-TRAIL-1c-1, Q16):** `'L' || txid` after the log began, `'P' || <moment>` before
  it. `entry_no` orders the entries of **one** record; when a list block merges several records (`ListTrail`), rows of the same
  operation are merged into one entry by `op_key` — a bulk FX save is one entry, not N; the same row read through two records is
  kept once (`mergeKey`: its `seq`, or table · key · op · moment · columns before the log).
- **A row the reader cannot see** keeps its place and its time; everything else (what, who, values, keys) is null and
  `row_hidden` is true. The page prints "Restricted" in place of what happened and who (Q4). When only part of an operation
  is hidden, the entry adds "Part of this change is restricted."

### 9.2 Which rows belong to a record (Q3 · Q6)

`trail_subject_members()` lists each subject's child and related tables: `table.fk_column = parent_table.id`, plus a fixed
condition for polymorphic tables (`approval_log.subject_type = 'purchase_order'`). Grandchildren name a child as parent
(retentions hang off PO lines). Since AUDIT-TRAIL-1b-1 each member row also says:
- **`hop`** — `down` (the member points at its parent) or **`up`** (M4: the parent points at the member — a batch's
  `purchase_order_id`, a processing input's `run_id`, a journal's `reversed_by`);
- **`shown`** — `false` makes the member a **stepping stone**: it is used to reach the rows below it, but its own changes
  are not part of the record, it is not visibility-checked and it has no pre-log rows (Q4: "only the events that touch
  this batch" — a batch shows the cost changes and journals of the runs that consumed it, never the run's own edits);
- **`home`** — the one membership `trail_row_record()` (the summary page's Record column) follows when a table belongs to
  several subjects (a processing input is both a run child and a batch member; its home is the run). The walk also
  honours `match`, so an `approval_log` row goes to the document its `subject_type` names. Rows are found **at read time**, in two steps, because an edit stores only the changed
columns (a price edit on a PO line carries no `purchase_order_id`):
1. collect the **keys** of every row that belongs: live rows by foreign key, plus rows known only from the log
   (`COALESCE(new, old) @> {fk: parent}` for inserts/deletes/re-parenting, `old @> {fk: parent}` for edits that moved a row
   away) — two GIN partial indexes, `idx_change_log_image` and `idx_change_log_update_old`;
2. fetch **every** log row for those `(table_name, row_key)` pairs.
No parent key is written at capture time — that would have meant rebinding the 238 triggers (Q6).

### 9.3 Masking — one step for both readers (Q5)

`change_log_mask_row()` is the loop body that used to live inside `change_log_rows()`: task privacy first, then HISTORY-1's
`change_log_mask_rules()` per column. **Both readers call it**; no rule was added. The row's current image (`ctx`, used for
"Line 1 · <material>" headings) goes through the same step.

### 9.4 One entry per operation, paging

Rows are grouped by `txid` (Q2) and numbered newest first (`entry_no`, by the highest `seq` in each transaction). The page
shows 20 entries, then "Show older entries" (`?trail=40`, Q29). The summary page pages by transaction too
(`change_log_rows(p_by_entry => true)`): since AUDIT-TRAIL-1b-1 it shows 20 operations and "Show older entries" (`?show=40`,
up to 500), reading in chunks of 200 with the function's own keyset (`p_before` = the highest `seq` of the oldest
operation read so far) — the same shape as a page trail (fold-in 2).

### 9.5 History from before the log began (Q1)

The log began at **2026-09-28 23:58:11 Singapore time** (`change_log_began_at()`, declared, not inferred). For earlier
history, `record_trail` rebuilds rows from the sources `trail_prelog_sources()` lists per table:
- `created`: the row itself is the event (a history-table row, an approval decision, a PO issue, a grant, a record's
  `created_at/created_by`) — rebuilt as an INSERT whose image is the row as it is **today** (`AT1A-PRELOG-SHOWS-TODAYS-VALUES`);
- `stamp`: a lifecycle stamp pair (closed, deleted, allocated, released …) — rebuilt as an edit with only the new values.

Only timestamps before the boundary are used, and **nothing is shown twice**: a `created` source is skipped when the log
holds that row's INSERT, a `stamp` when the log holds a change to that column. Rows written in one transaction share
`now()`, so pre-log rows are grouped by exact timestamp. They always sort after every logged entry and carry
`prelog = true`; the page draws a divider above them: "Before 28/09/2026 23:58, only key steps and amendments were kept;
single-field edits were not."
- **`by_kind`** (M2, AUDIT-TRAIL-1b-1) says whose id the `by_column` holds: `account` (a login, `auth.uid()` — almost every
  table) or `employee` (`current_user_employee()` — the handover's `acknowledged_by`; 1b-3's task tables). An employee id
  read as an account would resolve to "Removed account", a false statement rather than an unknown one.
- **Quotes and sales orders (AUDIT-TRAIL-1b-2).** A document's own creation (`quotes.created_at`, `sales_orders.created_at`)
  **and** its history's `created` row are both registered: they are written in one transaction (measured row by row on live:
  `created_at` = `changed_at`), so they rebuild with the same timestamp, group into one entry, and the renderer folds them into
  one "created" sentence. That also gives a creation entry to the orders that have no history at all (two live test orders).
  The PDF issue tables (`qt_issues`, `so_issues`) are **not** registered — the history's `issued` row already records each issue
  (Step 0 §a); nor are the order's `confirmed_at` / `closed_at` / `cancelled_at` stamps. The reservation stamps (1b-1, for the
  batch pages) share their timestamps with the order history's `reserved` / `released` / `shipped` rows, so on the order page
  they fold into those entries and are not said twice. Measured consequence: QT-2026-0001's second PDF issue (v2) has no history
  row, so the quote's pre-log trail shows version 1 only; the page's own "Issued versions" list still shows both.
- **Suppliers.** `approved_at` is registered as a stamp: suppliers approved before ROLE-1 Batch 2a (2026-09-24) have no status
  history or approval row, only that stamp.
- **Pricing formulas and tasks (AUDIT-TRAIL-1b-3).** Their history tables (`pricing_formula_history`, `task_history`) are the main
  line. A formula's own creation and its payable metals are registered too (1b-2's quote / order precedent: the history row is
  written by an AFTER trigger in the same transaction, so they fold into one sentence; the one live formula predates its history
  table). Task history is written only on **team** tasks (`trg_tasks_history`), so a personal task's earlier trail comes from the
  task's and its steps' creation, the steps' tick stamp (`done_at`) and the task's `deleted_at`; on a team task the step's creation
  and `node_added`, the tick and `node_done`, share a timestamp and the renderer says each once (fixture 240 N). Participants are
  not registered before the log — the history records every arrival and departure except the owner's own first row, which is
  deliberately unrecorded. Task tables hold **employee** ids (M2).
- **Materials, locations, metal prices** have no history table: creation and the deletion stamp only. None of these tables, nor
  customers or suppliers, ever recorded **who** deleted a row.
- **One exception to "no stamp a history already records" (Tim's Q11):** a stocktake's `posted_at`. Posts before
  22/09/2026 have nothing else (posting did not write `approval_log` yet); later posts write both in one transaction, so
  they share a timestamp, group into one entry, and the renderer folds the approval into the posting as one line.

### 9.6 Adding a subject (what AT-1b, AT-1c and AT-1d do per page)

1. `db/functions/trail_subjects.sql` — one row: subject, the page's exact view code, root table, root key.
2. `db/functions/trail_subject_members.sql` — its child and related tables (parents before children).
3. `db/functions/trail_prelog_sources.sql` — where its pre-log history lives (history tables, lifecycle stamps). Do not
   add a stamp that a history table already records — that would show twice.
4. `lib/trail/render.ts` — the subject's event wording (a `describe…` function and its table set); new sentences go in
   `lib/trail/text.ts` (English only). `scripts/check-trail-wording.mjs` fails until the SQL registry and the render-side
   table set agree, every column of every registered table has an English label, and every enum value has English.
5. Labels for new columns: `scripts/gen-trail-catalogue.mjs` (`OVERRIDES` for page wording), then `--write`.
6. The page: `<AuditTrail subject="…" id={…} show={trailCount(searchParams.trail)} />` at the very bottom, and a smoke
   `MUST_CONTAIN` entry `{ trail: 'audit-trail' }`. Add the subject to `TrailSubject` / `TRAIL_SUBJECT_ROOTS`
   (`AuditTrail.tsx`) and its shown tables to `SUBJECT_TABLES` (`lib/trail/render.ts`) — `check-trail-wording` compares
   both with the SQL registry.
   **A record with no page of its own** (lanes, ports, company licences — 1b-2) gets a block at the bottom of its list page:
   `<ListTrail records={[{ subject, id, label }…]} intro="listTrail.intro.…" show={…} />`. It reads `record_trail` once per
   record (deleted records included — "removed" is part of the record), merges the entries newest first with a Record column,
   and drops an entry shown identically by two records (a lane's creation also belongs to both its ports).
   A page that carries two trails (1c-3: `/finance/settings`, `/finance/close`) gives each its own `anchor`; a trail inside a card or a row
   (1c-3: journal requests, expense claims) is `compact` — collapsed, no heading; a list record with a page of its own passes `href` to
   `ListTrail` and its Record column links.
   A panel that owns only some columns of a shared row (1b-3's threshold panels) sets `root_columns` (M6): the trail then
   shows only those columns and drops the changes that touch none of them. A single-row settings table keyed by `id
   boolean` works as a root (M5): the reader rebuilds the root key from the row's own typed value.
7. A fixture arm per event wording that matters, with a fault injection that turns it red.

### 9.7 Wording rules

- **English only**, also when the interface is Chinese (Q7). The sentences live in `lib/trail/text.ts`, not in
  `messages/en.ts`; `check-trail-wording` checks both directions (every key used, every used key present).
- **Field labels** (Q11): the page's own label first, then similar wording elsewhere in `en.ts`, then the labels proposed in
  `docs/surveys/AUDIT-TRAIL-0/labels.csv`; the three subjects' tables carry hand-checked overrides.
- **Values** (Q12 · Q13 · Q40): the database resolves ids to document numbers, names and dictionary labels
  (`trail_refs` / `trail_ref_label`); the app writes the sentences. Created/updated stamps, technical columns and raw JSON
  never show; JSON columns say "Details changed". Enums in English, booleans Yes / No, dates `DD/MM/YYYY`, money with its
  currency. A referenced record that was hard-deleted reads "PO-2026-0010 (since deleted)", or "a supplier that has since
  been deleted" when not even its image is left.
- **Who** (Q14 · Q17 · Q18): the person's preferred name, else legal name; "System (automatic)" for every write with no
  login (migrations included); "Removed account" when neither the account nor a person is left; a disabled account shows
  the plain name; "A former employee" after anonymisation; "Not recorded" for pre-log rows whose table kept no actor.
  **Since AUDIT-TRAIL-1b-1 (Tim's fold-in 1, overturning AT-1a decision 1)** a reader who would see "Restricted" in place
  of a name on the system's other pages sees "Restricted" in the trail too — the `ActorName` rule, decided in
  `trail_actor`: without `module.hr.view` a reader recognises only himself; everyone else (including anonymised people and
  accounts with no person) is Restricted. "System (automatic)", "Removed account" and "Not recorded" are not names and
  stay visible. Both readers and every person-valued field ("Approved by …") go through the same function.
- **Machine-written text** is never shown as a reason: the automatic-approval notes and the notes `post_stocktake` and
  `release_work_order` write into `approval_log` are Chinese sentences written by the database, not by a person
  (`MACHINE_NOTE_SUBJECTS` in `lib/trail/render.ts`).
- **State notes on a batch** (Q5): "Not received against a purchase order", "No cost-of-sales journal" and "This
  processing was later rolled back" are grey lines inside the entry they belong to; they read the row's current value (and,
  for a run, `trail_ref_label`'s `ended`).
- **Typed text in a title** (AUDIT-TRAIL-1b-2): a file name, a contact's name, a document type or a certificate number that a
  person typed is never spliced into the fixed wording. It is the entry's `titlePart` (or a heading's `part`), rendered inside the
  same `data-trail-typed` span as typed values — shown as written (Q8) and exempt from the smoke's machine-token scan. Measured
  reason: a supplier attachment is named "Screenshot 2026-06-28 at 5.49.23 PM.png", and the detector rightly reads that date as
  a machine token when it sits in a title.
- **History `detail` strings** (quote and sales-order history, 1b-2) are composed by the database ("SHP-2026-0001 · 12/12",
  "INV-2026-0006 · wrong price"). A leading document number goes into the title ("Goods shipped · SHP-2026-0001"); the rest is
  a "Details" line (or the reason, for a voided invoice or a cancellation), shown as written. A `created` row's detail is the
  document's own number, or on SO-2026-0001 a back-fill note the database wrote in Chinese — neither is shown.
- **Several events in one operation** (1b-2, found by the live proof, which writes everything in one transaction): a line added or
  changed in the same operation as a quote's or order's creation is listed under the creation ("Line changed · Line 1 · …"); a
  line block carries its line in its title, never as a bare "Line 1" sub-heading (a block's title is its sub-heading when another
  event heads the entry); a supplier's status history is one block per step, and when one operation takes several steps each
  step's note is a line of its own, not a single shared reason.
- **Machine-written Chinese** (Q8): typed text is shown as written; values the system wrote in Chinese are shown in English
  (`messages/trail-machine-values.ts` for `inbound_batches.stage` and — 1b-3 — `materials.unit`, whose dropdown stores 吨 / 克 / 件;
  quantity units read that map too; automatic-approval notes are replaced by "Approved automatically (approvals were switched off)").
- **One event, two rows (AUDIT-TRAIL-1b-3).** A formula change and a team-task change each leave the row's own change-log entry
  **and** a history-table row in the same transaction. After the log began the change-log row speaks (it has every column) and
  the history row is not said again; before the log only the history row exists and it speaks. For tasks the match is per thing:
  the task header, a step (by its id), a participant (by the employee). A step's name for a history row that carries only the
  step id comes from anywhere on the page (`buildEntries`' page-wide step-title map, the reversal-journal precedent).
- **Terms requests** read "New pricing formula sent to the CFO" / "Change to the pricing formula sent to the CFO" / "CFO approved
  the terms" (the page's own "Send to the CFO"), with the request label as typed text; the approval row folds into the decision.
- **A deletion keeps the other changes made with it (AUDIT-TRAIL-1b-3, found by the live proof).** An UPDATE that sets
  `deleted_at` and other columns in the same operation is one "… deleted" block whose lines list those other columns
  (before → after); the deletion is never allowed to swallow them. A deleted task step lists its target date and whether it was
  ticked ("Step was ticked: No"), from the step row or, before the log, from the history row's `old_node_*` columns.
- **A replaced set is said in the order it happened (AUDIT-TRAIL-1b-3, found by the live proof).** Rows of a set (a location's
  allowed classes, a formula's metals) deleted and re-inserted with the same value in one operation net to nothing **only** when
  the DELETE came before the INSERT (a save that rewrote the set); a value inserted and later removed in the same operation is
  shown. When an operation adds to a set and then removes from it, the block splits at the first removal, so "1 added, 1
  removed" never hides which came first.

### 9.8 Checks

AUDIT-TRAIL-1b-1 adds fixtures **237** (M1–M6, fold-in 1 on the purchase-order, processing-run, role and summary readers)
and **238** (the batch trail against the retired views row for row — including the upward-hop kinds — the added kinds,
hidden rows, reversals, state-note inputs, written-off batches and reversed runs, the stocktake fold, the
warehouse-request block), fault-injected by `db/scripts/2026-09-29-at1b1-fixture-injections.py` (20 injections, each red
in its own arm). The smoke `trail` assertion now also covers `/inbound/[id]/edit`, `/output/[id]/edit`,
`/operation/orders/[id]`, `/stocktakes/[id]`, `/operation/equipment/[id]` and `/operation/handovers/[id]`.
AUDIT-TRAIL-1b-2 adds fixture **239** (every new subject's field edit, child-line change and key event; M1 on shipments; M3 on
forwarders; the list-level lanes, ports and licences; the replaced quote and sales-order histories row for row; the pre-log merge
and "never twice"), fault-injected by `db/scripts/2026-09-30-at1b2-fixture-injections.py` (17 injections, each red in its own
arm); a sixth arm in `scripts/check-trail-wording.mjs`, **⑥ 商务样例**, which renders a field edit, a child-line change and a key
event for every new subject and compares the English word for word (injection `wording-drift`), plus a key-event sweep over
every sales-order and quote history value, every supplier status move, credit, detachment and document state; the smoke `trail`
assertion on the nine 1b-2 pages; and `scripts/probe-at1b2.mjs` (a real warehouse account — `action.ship_goods` without
`module.sales.view` — opens a shipment and its trail; the old History sections are gone; typed text stays typed; the Chinese
interface leaves the trail untouched).

AUDIT-TRAIL-1b-3 adds fixture **240** (every new subject's field edit, child-line change and key event; Q13's save writing only
what changed — counted in change-log rows **and** in row versions, because the change log does not record a no-op update; personal
tasks visible to their owner and to `module.tasks.view_all`, refused to everyone else; every task-history row on the trail; the
pre-log task merge with employee actors (M2); the three panels under M5 and M6; `deleted_records` taking "who" from the change log
and leaving it empty for deletions before the log), fault-injected by `db/scripts/2026-10-03-at1b3-fixture-injections.py`
(20 injections, each red in its own arm); a seventh arm in `scripts/check-trail-wording.mjs`, **⑦ 主数据样例** (golden wording for
every 1b-3 subject, plus a machine-token sweep over every task-history and formula-history `change_type`, which ④ cannot reach
because the column is hidden; injection `wording-drift-1b3`); smoke `trail` assertions on the eight 1b-3 pages (the three panels
with `emptyOk` — their settings rows have no change-log entries on live yet); and `scripts/probe-at1b3.mjs` (a real `auditor`
opens each deleted record read-only with its banner; a real `gm` — every module, no `data.view_deleted` — gets the named refusal,
not a 404; `/settings/deleted` lists the new kinds with working links; the task page's old section is gone).

| check | reads | fails on |
|---|---|---|
| `scripts/check-trail-wording.mjs` (in `npm run build`) | the repository | a machine token in any sentence built for any column, value, actor or event of every logged table; a registry mismatch; a missing or unused catalogue key; a subject column without an English label or value. Eleven named fault injections (`TRAIL_WORDING_FAULT`) |
| `scripts/smoke-routes.mjs` `{ trail }` content assertion | the three trail pages and `/settings/change-history`, rendered | a section that is not `entries`; a uuid, column or table name, raw code, JSON, "null" or database role name in its text (typed text excluded). Injection: `SMOKE_TRAIL_FAULT=1` |
| fixture 236 | the rebuilt database | grouping, discovery, masking, hidden rows, refusals, pre-log merge, actors, deleted references, summary reader; 30 fault injections (`db/scripts/2026-09-29-at1a-fixture236-injections.py`) |

Both machine-token checks use one detector, `lib/trail/machineTokens.ts`, which proves itself on every run (known-bad
samples must all be caught, a known-good sentence must pass).

### 9.9 The six registry extensions (AUDIT-TRAIL-1b-1, M1–M6)

| | what | where | first user |
|---|---|---|---|
| M1 | a subject is admitted by **any one** of several view codes | `trail_subjects.view_codes`, `has_any_permission` | `warehouse_request` (inventory or finance); `shipment` (sales or ship_goods — 1b-2; live reader: the warehouse account) |
| M2 | a pre-log actor column may hold an **employee** id | `trail_prelog_sources.by_kind` | the handover's acknowledgement; the task steps and task history (1b-3) |
| M3 | the page's code admits the reader even where the root table's own rule does not; the root row's events are then per-row | `trail_subjects.root_rule = 'page'` | `equipment` (root `fixed_assets` is finance-only); `forwarder` (root `suppliers` is suppliers.view; the page is logistics.view — 1b-2) |
| M4 | a member may be reached by an **upward** hop, and may be a **stepping stone** that is not shown | `trail_subject_members.hop` / `shown` | the batch trail (45 of the 292 old rows live were upward) |
| M5 | a root keyed by a non-text value (`id boolean`) is matched by its typed value | `record_trail` rebuilds the root key from the row | the three threshold panels (1b-3; the page passes `'true'`) |
| M6 | a root may be limited to the **columns a panel owns** | `trail_subjects.root_columns` | the three threshold panels (1b-3): processing 2 columns, pricing 1, receiving 3 |
| **M7** (1c-1) | a member with **no foreign key** under a single-row root: every row of that table, and every log row of it (`match` filtered), belongs to the singleton (`hop = 'all'`, `fk_column` NULL). Ignored unless the parent is the subject's root table. `trail_row_record` gives such a row the singleton as its home | `trail_subject_members.hop = 'all'` | `finance_lock` (1c-3: `period_closes` — a month close reads "Finance settings" in the summary page's Record column); AT-1d's approval policy (`finance_settings_history`) |
| **M9** (1d-1) | a **log-only root** outside `public`: `trail_log_only_tables()` names the table (`auth.users`), the **safe projection** it may be read through (`id, email, created_at, banned_until` — never the whole auth row, which carries the password hash and six token columns) and a **declared read code** (`action.manage_permissions`) that stands in for its policies. `trail_current_image` and `trail_row_visible` consult it; its creation after the log is an `ACCOUNT_CREATE` row, so the pre-log creation is skipped when either that or an `INSERT` exists | `trail_log_only_tables()` | `account` on `/settings/accounts`; the account mirror on `/hr/employees/[id]` (up hops to `auth.users`) |
| **M10** (1d-1) | a **member limited to declared columns** (M6 on a member): `trail_member_columns()` gives `(subject, ord) → columns`; a change touching none is dropped, the rest keep only those columns, and a column-limited member contributes no pre-log creation | `trail_member_columns()` (a side registry — changing `trail_subject_members`' return type would break every fixture that redefines it) | the account trail's employee row (`user_id` only — an HR edit of that person is not the account's business) |
| **M11** (1d-1) | `root_rule = 'collection'`: **no root row**; every current row of the table and every log row of it belong to the record, each checked against its own read rule. `p_id` is ignored (pages pass `'all'`) | `trail_subjects.root_rule` | the six dictionaries; AT-1d-2: public holidays (hard-deleted) and leave types; AT-1d-3: the rating scale (`review_rating_scale`) |
| **M12** (1d-1) | `root_rule = 'gate:<name>'`: the root row must pass its table's read rule **and** `trail_root_gate(<name>, …)` — a closed set (`reviewer`: the review's `reviewer_employee_id` is the reader); an unknown name admits nobody. May be combined with M8 (no page code) | `trail_root_gate()` | `my_review` on `/my-reviews/[id]` (AT-1d-3, with M8); first proved with a temporary subject in fixture 244, then by fixture 246 MR |
| **M8** (1c-3) | a subject with **no page code**: `view_codes` is an empty array, and the root row's own read rule is the only gate. Allowed only with `root_rule = 'table'` — `'page'` with no code would open the record to everyone, so `record_trail` refuses it (`TRAIL_NOT_PERMITTED`); `NULL` codes are still refused | `trail_subjects.view_codes = ARRAY[]::text[]` | `my_expense_claim` on `/me` (the claimant reads their own claim; `expense_claims`' read rule is finance or own) |

The retired batch views `batch_audit_trail` / `batch_audit_trail_all` stay in place, unread by any page (Q32); fixture 238
reads them as the reference its row-for-row check compares against, and their i18n entry in `scripts/check-i18n.mjs` stays
until they are dropped.

### 9.10 Deleted records open read-only (AUDIT-TRAIL-1b-3, Tim's Q9 · Q21 · Q8)

- **Which records:** deleted customers, suppliers, materials and pricing formulas, and deleted sales orders, quotes and purchase
  orders. Their pages used to filter `deleted_at` and 404 — including the links on `/settings/deleted`.
- **Who may open them:** holders of `data.view_deleted` (measured 2026-10-03: admin, auditor, cco, cfo, cto, finance). They see the
  page read-only (`<EndedFieldset>`: every control disabled, links usable) with a banner and the audit trail. **Everyone else gets
  a named refusal** (`requireDeletedAccess` in `app/components/moduleGuard.tsx`: "This record has been deleted." + which permission
  opens it) — never a 404, because "not found" reads as "never existed". The page's own module guard runs first, unchanged.
- **The banner** (English only, `lib/trail/text.ts`): "Deleted on DD/MM/YYYY by <name>", "Reason: …" when one was recorded. The
  name follows the `ActorName` rule (Restricted to a reader without HR). **Where no person was recorded, the date only** — never a
  guess from `updated_by`. Customers, suppliers, materials and formulas never stored a deleter; `deleted_records` takes the person
  from the change-log entry that set `deleted_at`, so deletions before 28/09/2026 23:58 read date-only (all of them on live today).
- **One source for "who / when / why":** the banner reads the same `deleted_records` row `/settings/deleted` lists
  (`DeletedBanner` in `app/components/trail/EndedBanner.tsx`).
- **`/settings/deleted`** lists the four new kinds and links every kind to its page (written-off batches and reversed runs too,
  which 1b-1 made openable).
- **Actions on a deleted record** are disabled inside the fieldset (customer's edit link becomes a disabled button; the formula's
  deactivate / delete buttons stay visible and unpressable). The purchase order's action row — mostly links, which a fieldset
  cannot disable — is not drawn for a deleted order (the page's own rule: a question that does not apply is not asked).

### 9.11 The ledger documents (AUDIT-TRAIL-1c-1, Tim's AT-1c Q1–Q34)

- **One describer for the seven finance pages.** On `journal_entry`, `invoice`, `credit_note`, `payment`, `payment_request`, `expense` and
  `payable` every row is worded by `describeFinance` (`lib/trail/render.ts`). The same tables on the batch, order and summary pages keep
  their 1b wording (fixtures 238–240 and arms ⑥ ⑦ unchanged).
- **A reversal is one sentence (Q31 · Q33).** The original flips to `reversed` and a new opposite document (the mirror) is created in
  one transaction: "Payment reversed · PMT-…" / "Expense reversed · EXP-…" / "Journal reversed" with **one linked line**, "Reversing
  entry: PMT-…" or "Reversed by: JE-…" (the link's path comes from `document_types`, via `trail_ref_label`'s `href`). Before the log only
  the mirror's creation exists, and it says the same sentence. A reversal journal's own lines are not members of the original (Q33);
  on the reversal's own page it reads "Reversal journal posted · JE-…", "Reverses: JE-…" and its lines. A reversal's memo /
  notes ("REVERSAL: <code> — <words>") gives only the person's words as the reason.
- **Requests.** "… sent for approval", "… approved", "… rejected", "Request withdrawn", and for payment requests the six kinds' own
  words (Q30's "WHT remittance reversal sent for approval"; "Paid", "Payment reversed", "Bank transfer made", "WHT remitted" …). A request
  raised with approvals off reads "… approved" plus the note "Approved automatically (approvals were switched off)" (Q32). A request
  raised and changed in the same operation (the submit functions write the amount, or flip to approved, right after inserting) is
  one sentence. Approval rows fold into the request's sentence. A payment request's `allocations` (JSONB) are named by document number
  (`trail_refs`, Q13) — "EXP-2026-0004 · 300.00 (document currency)".
- **Before the log (Q9):** three stamps are the only record of their event and are registered as sources — `invoices.voided_at`,
  `payment_requests.paid_at`, `expense_claims.decided_at` — next to the documents' creation stamps (journals' lines, requests,
  issues, credit notes, payments, transfers, remittances, expenses, claims, asset cost entries).
- **Employee names in references (Q12).** `trail_ref_label` answers an employee reference through `trail_actor`: a reader without
  `module.hr.view` sees only himself by name, everyone else Restricted — the same rule as "who" (§9.7). It also returns `label` when the
  name is visible, so `/settings/change-history`'s Record column still names employees for its readers (admin, cfo — both hold hr.view).
- **Banners (Q8).** "Voided on DD/MM/YYYY by <name>" (invoice: `voided_at` / `voided_by`), "Reversed on DD/MM/YYYY by <name>"
  (journal, payment, expense: who and when are the mirror's creation) with a third line linking to the reversing document; a mirror
  carries "Reversal of …". A written-off batch on the payables page opens read-only with "Written off on … by …" (Q5), the person and
  reason from `deleted_records`.
- **The payable (Q5).** A second subject on `inbound_batches` (the `supplier` / `forwarder` precedent): the page's code is the gate
  (M3 — the batch's own read rule is `module.inbound.view`), and only the payable columns of the batch row are shown (M6).
- **Source links (Q15).** A reversal journal's `source_id` is the original journal, not the document (`reverse_journal_entry_internal`),
  so the journal page's "Source" link pointed at a journal id as if it were a batch or run. `app/finance/sourceLinkReversal.ts` swaps a
  reversal's source for the original's before `resolveSourceHrefs` builds the link (journal page, journal list, ledger).
- **Checks.** Fixture **241** (M7 · Q16 · Q12 · every subject's child line and key event · reversals · Q32 · Q13 · M3 / M6 on the payable ·
  Q9 · the Q15 data shape), fault-injected by `db/scripts/2026-10-03-at1c1-fixture-injections.py` (20 injections, each red in its own arm).
  `scripts/check-trail-wording.mjs` arm **⑧ 账上的单据** (golden wording for every subject, Q12, Q16's merge, Q15's mapping, and 1b-3's
  defect 28 — Q34) plus a machine-token sweep over every table of the seven subjects with the page's own subject (750 sentences, the
  number computed from the registry); injection `wording-drift-1c1`. Smoke `trail` assertions on six of the seven pages
  (`/finance/payment-requests/[id]` stays on the skip list: no live request).

### 9.12 The rest of the documents and contracts (AUDIT-TRAIL-1c-2, Tim's AT-1c Q1–Q34)

- **Eight subjects, one describer.** `sale`, `freight`, `fixed_asset`, `bank_statement`, `gst_period`, `fx_rate`, `management_pack` and `contract`
  join the finance family: every row on these pages goes through `describeFinance`, which hands the tables 1c-2 first shows to
  `describeLedger2` (`lib/trail/render.ts`). Journals, allocations, attachments and approvals keep 1c-1's wording.
- **The sale is a subject root (Q14).** The summary page's Record column for a sale row — and for the rows that hang off it (its stock issue,
  its attribution note) — is now the sale, named "OUT-2026-0186 sale 01/08/2026" and linked to `/finance/receivables/<id>`
  (`trail_ref_label`, `trail_row_record`; the output batch's `sales_records` membership is no longer home). `sales_records` has no `code`
  column, so it is **not** added to `document_types`: global search builds `SELECT code` for every registered table and would fail; the
  name and the link come from the two trail functions instead, in the same shape a document gets.
- **One event, two rows (the 1b-3 rule) for the asset card and FX rates.** `fixed_asset_history` and `fx_rate_history` are written in the same
  transaction as the row's own change. After the log began the change-log row speaks (it has every column) and the history row adds only what
  the row cannot say (an FX correction's or withdrawal's reason); before the log the history row speaks — the asset history's `old_` / `new_`
  pairs are labelled after the card's own columns (generated, not hand-copied) and resolved through the card's foreign keys (`trail_refs`).
- **Before the log (Q9):** the last two of Step 0's five stamps are registered as event sources — `freight_documents.reversed_at` (all four
  live freight documents were reversed before the log) and `bank_statements.reconciled_at` (BS-2026-0002 was reconciled with no reconciliation
  record). Where a reconciliation record exists it shares the moment and is said once.
- **Ended records (Q8 · Q6 · Q7).** A reversed freight document carries "Reversed on DD/MM/YYYY by <name>" + "Reason" + a link to the reversal
  journal (it used to omit who). A **deleted bank statement** opens read-only for `data.view_deleted` holders ("Deleted on DD/MM/YYYY" — nobody
  was recorded; everyone else gets the named refusal, not a 404) and is listed on `/settings/deleted` (`deleted_records` gains a
  `bank_statement` branch; "who" from the change log). A **withdrawn FX rate** opens read-only for the page's normal readers with
  "Withdrawn on DD/MM/YYYY by <name>" and the reason, both from its `withdrawn` history row (the rate keeps no withdrawer); the form is
  disabled because `record_fx_rate` would otherwise create a new rate rather than edit the withdrawn one.
- **GST (Q22 · Q23).** A correction period is not a member of the original — its own trail opens with "Correction opened for GST-…"; the
  original page keeps its existing link. The boxes copied at approval fold into the filing entry ("GST return locked · N boxes", one line per box,
  `label_en` only; `label_zh` is machine-written Chinese and is never shown).
- **Undoing a reconciliation (Q24).** `unreconcile_statement` appends "UNRECONCILED <timestamp>: <reason>" to the notes; the renderer recognises
  that machine suffix and says "Reconciliation undone" with the person's reason, never the notes diff (`unreconcileReason`). The writer is
  registered in `docs/known-issues.md` (`AT1C1-UNRECONCILE-WRITES-TIMESTAMP-INTO-NOTES`).
- **Contracts (Q21).** Terms requests read as on the formula page ("Contract activation sent to the CFO", "CFO approved the terms"); the
  approval rows follow `approval_log`'s terms-request branch, which asks `module.pricing.view` even for a contract, so a contract reader without
  it sees the decisions as Restricted. Term rows read "<Section> added / changed / removed · <metal>".
- **A column that comes back is not a change (all subjects).** `mergeUpdates` folds several edits of one row inside one operation into one
  (first old value, last new value). Since AT-1a it kept a column that ended where it started, so a statement reconciled and undone in the
  same transaction printed "Status: Open → Open" and "Reconciled on: (empty) → (empty)" (seen in the rolled-back live proof). Merged rows
  now drop such columns, and a merged row left with none says nothing. A single edit is untouched. Golden "bank statement · reconciled
  and undone in one operation" in arm ⑨; with the filter removed in a scratch copy it goes red printing exactly those lines.
- **Checks.** Fixture **242** (each subject's field edit, child-line change and key event — or, where none exists, that a direct edit is refused
  by name; Q6 · Q7 · Q9 · Q10 · Q14 · Q21 · Q22 · Q23 · Q24 · Q25; the 1c-1 gap: payment-request and credit-note field edits), fault-injected by
  `db/scripts/2026-10-04-at1c2-fixture-injections.py` (25 injections, each red in its own arm). `scripts/check-trail-wording.mjs` arm
  **⑨ 其余的单据与合同** (44 goldens, hand-checked: every subject plus the payment-request, credit-note, payment and invoice field edits 1c-1 left
  without one, and the round-trip above) plus a machine-token sweep over every table of the eight subjects with the page's own subject; injection `wording-drift-1c2`.
  Smoke `trail` assertions on seven of the eight pages (`/finance/packs/[id]` stays on the skip list: no live pack). `scripts/probe-at1c2.mjs`:
  the deleted statement read-only for admin and refused by name for `gm`; the freight banner; the asset page without its old panel; every live
  record of the eight subjects in both interfaces, plus one AT-1a, one AT-1b and one AT-1c-1 page.

### 9.13 Period-end, settings and the list homes (AUDIT-TRAIL-1c-3, Tim's AT-1c Q1–Q34)

- **One settings row, two panels (Q25 · Q4).** `finance_settings` holds the period lock, the GST registration, the approval policy and six
  columns no screen edits. `finance_lock` and `finance_gst` are two subjects on that one row (M5), each limited to its own columns (M6), so
  the lock panel never shows a GST change and the GST panel never shows a lock move; the six unowned columns are on neither (they stay on
  `/settings/change-history`, the complete record); the approval-policy panel is AT-1d's (Q2). The lock's trail also carries `period_closes`
  through M7, so it reads "Month closed up to DD/MM/YYYY" (the close row and the lock move are one operation; the lock move is a line,
  "Period locked before: old → new", the page's own label) and "Month reopened from DD/MM/YYYY" (the first day of the reopened month);
  a lock moved on its own reads "Period lock moved / set / removed". Before the log the lock panel has exactly one source, the close row
  itself (`period_closes.closed_at`, and the reopen stamp); the settings row and the company profile keep only shared `updated_*` stamps,
  so nothing is registered for them and their trails start at the log.
- **List homes (Q16 · Q17 · Q18 · Q19 · Q20 · Q29 · Q30).** Records with no page of their own get a block on their list page (`ListTrail`),
  read per record and merged by operation (`op_key`): one bulk FX save is "Exchange rates recorded · N rates", one freeze that replaces the
  week's earlier forecast is one entry. Runs that have no table of their own (revaluation, depreciation, payroll, processing-cost
  remittance) are their journals, read through `journal_entry` (and the relief expenses through `expense`); on a journal's own page and in
  these blocks such a journal reads by its source ("FX revaluation posted", "Depreciation posted" with each asset as a line, "Payroll journal
  posted", "Year-end closing journal posted"). A list record that has a page of its own links from the Record column. Journal requests and
  expense claims are action cards, so each card carries its own collapsed trail; the claimant reads the same claim on `/me` through
  `my_expense_claim` (M8), where the approval and the expense it recorded read Restricted (Q4) — who decided and why is already in the
  `/me` table's Decision column.
- **Wording corrections in the shared renderer.** A bank transfer's two legs now take each account's own currency (the incoming leg used to
  carry the source currency); a transfer's own edit reads "Bank transfer changed" (it used to borrow "Request changed"); a WHT remittance's
  reversal reads "WHT remittance reversed" with the reversal journal as a line, merged with the paying request's sentence (Q30).
  Found by the rolled-back live proof (it writes everything in one transaction) and fixed, each with a golden that goes red when the fix is
  removed: a month close's totals and a year close's net result are in the base currency (the lock row and those tables have no currency
  column, so the live lock trail printed "Total debits: 757,013.37"); an operation whose every row nets to nothing (a lock moved and moved
  back) says nothing — it used to read "Restricted", a false statement, since nothing was hidden; a remittance created and reversed in one
  operation keeps its own "WHT remitted" sentence; a deletion that also renamed an import mapping keeps the rename.
- **Entry points.** `/finance/fx` lists withdrawn rates (they open read-only, 1c-2's Q7) and its block links every rate;
  `/finance/bank/statements` has a block of deleted statements for `data.view_deleted` holders, each linked to its read-only page — the
  same gate as that page; everyone else sees a named refusal there, not an empty block.
- **Checks.** Fixture **243** (each subject's field edit and key event, or the named refusal where a record cannot change; M6 on both panels,
  M7 and the pre-log close, Q4; M8 including the `'page'` edge; Q16 within and before the log; Q30; the summary page's homes), fault-injected
  by `db/scripts/2026-10-04-at1c3-fixture-injections.py` (24 injections, each red in its own arm). `scripts/check-trail-wording.mjs` arm
  **⑩ 期末、设置与清单页** (39 goldens plus the Q16 merges through `mergeByOperation`, and a machine-token sweep over the twelve subjects'
  tables with the page's own subject); injection `wording-drift-1c3`. Smoke `trail` assertions on fourteen 1c-3 pages (by `anchor` where a
  page carries two trails; `emptyOk` where live has no record yet). `scripts/probe-at1c3.mjs`: the two panels each only their own columns,
  the close page, a trail per claim, the deleted-statements block (admin reads it; `gm` gets the named refusal), and every trail section on
  every 1c-3 page in both interfaces.

### 9.14 Accounts, settings and employees (AUDIT-TRAIL-1d-1, Tim's AT-1d Q1–Q38)

- **The summary page re-checks every row (Q13).** `change_log_rows` now asks each row's own table read rule through `trail_row_visible`
  — the same judgement `record_trail` makes — and returns a row the reader cannot read as wholly restricted (`row_restricted`, the
  task-privacy shape). Until now it masked only by column rules, so a `data.view_change_log` holder without `data.view_pay` would have read
  every salary-change figure, and one without `data.view_reviews` review and KPI text. Today's two holders (admin, cfo) hold both, so
  nobody had read them — a latent hole, not a leak. Visible consequence: account events (`auth.users`, 0 rows on live) and the COD
  verification counter are restricted for cfo (no `action.manage_permissions` / no read policy).
- **Accounts (M9 · Q24 · Q9 · Q22).** One compact trail per account on `/settings/accounts`. Disabling writes the event first and a
  `_FAILED` row if the auth call fails — two calls; the renderer joins that pair into the one sentence "Account could not be disabled".
  A creation rolled back reads "Account removed (it was never finished)". A role grant reads "Role granted: CFO" on the account and
  "Role granted to <name>" on the role page; the grant's home (the summary page's Record column) is the account. Before the log: the
  account's own `created_at` (no person — "Not recorded"), `user_roles.granted_*` / `revoked_*`, the additional-login link.
- **The employee page (Q28 · Q21 · Q10 · Q30 · Q31).** The employee, employment history ("Hired", "Transferred", "Confirmed after
  probation", "Salary set / changed" …), salary change requests (the approval folds into "Salary change approved"), training, additional
  logins and the account mirror. Three machine-written notes in `employment_history.notes` are recognised: a review's
  "Probation confirmed by performance review <uuid>" reads "Confirmed through a performance review"; "Salary change approved with request
  <label>" becomes a "Salary change request: <label>" line; the employee form's own "status: a → b; department: X → Y" summary is not
  said (the row's own columns say it). Salaries are base currency. Anonymisation reads "Personal data anonymised" and nothing else — the
  cleared values are never said; the person reads "A former employee". After the log, the person who executed a salary change is the
  change log's actor (the history row's own `created_by` names the raiser — registered in `docs/known-issues.md`, Q31).
- **One save for the employee (Q8).** `save_employee` (SECURITY INVOKER) writes the employee row and its history row in one call, so a hire
  is one transaction (one entry) and a failed history row takes the employee row with it. It refuses by name without `module.hr.edit`
  (the table's statement-level guard does too — fixture 244's injection had to remove both to go red). It no longer compares old values
  before updating: that read masked columns the caller cannot select (42501), and the change log does not record a no-op update anyway.
  The account link stays its own call (`set_user_employee_link`, a different permission).
- **The approval-policy panel (Q25 · Q23 · Q27).** Only its four columns (M6) and its history (M7); after the log the settings row speaks
  and the history row is not said again, before the log the history row speaks (role codes resolved to role names through `trail_refs`).
  It replaces `ApprovalsHistory`, which named the actor by e-mail.
- **Dictionaries (M11 · Q4 · Q32).** Each section of `/settings/dictionaries` carries the whole dictionary's trail; values read
  "<Thing> added / changed / deactivated / reactivated"; both names are shown ("Name (English)" / "Name (Chinese)" — people typed them).
- **Import (Q24).** A block of batches and a "Who" column; imported records have no link back (the table comment stands).
- **Deleted records (Q25 · Q26).** Deleted roles, employees, departments and training records open read-only for `data.view_deleted`
  holders ("Deleted on DD/MM/YYYY", the person from the change log when there is one) and give everyone else a named refusal; the deleted
  employee's edit page sends back to its page; `deleted_records` and `/settings/deleted` list the four kinds with links.
- **Checks.** Fixture **244** (M9 incl. the safe projection and the "said twice" edge · M10 · M11 · M12 incl. an unknown gate · Q13 ·
  `save_employee` atomicity, no-op and named refusal · the account mirror for an HR reader · role grants and their home · the approval policy
  (M6 · M7) · the import block · the four deleted kinds · anonymisation), fault-injected by `db/scripts/2026-10-04-at1d1-fixture-injections.py`
  (18 injections, each red in its own arm). Fixture 234's synthetic readers gained the module codes of the three tables they read (its arms
  ask about column masking; the row rule is now asked too). `scripts/check-trail-wording.mjs` arm **⑪ 账号、设置与员工** (41 goldens + the
  "A former employee" check + a machine-token sweep over the thirteen subjects with the page's own subject; injection `wording-drift-1d1`).
  Smoke `trail` assertions on seven pages. `scripts/probe-at1d1.mjs`: a trail per account, the mirror Restricted for `gm`, the cto grant
  on its role page, the policy panel, six dictionary sections, the import block, the deleted role and employee (read-only for admin, a named
  refusal for `gm`), `/settings/deleted`, and zh = en on every 1d-1 page.

### 9.15 Leave and time (AUDIT-TRAIL-1d-2, Tim's AT-1d Q1–Q38)

- **A decision is one sentence (Q12 · Q2).** Approving leave writes the request's status and decision stamp, an approval row and one draw per
  source of days in one transaction: "Leave approved", the days taken as a line, the approver's note as the reason. A cancellation reads "Leave
  cancelled" with the days returned. Medical claims ("Medical claim approved / rejected / withdrawn") and overtime ("Overtime sent for approval: N
  hours", "Overtime taken back for changes", "Overtime approved", "Overtime sent back" — the page's own words, Q35 — "Overtime reversed",
  "Overtime batch discarded") work the same way; their approval rows fold into the sentence and, on their own (before the log), say the same words.
- **Stamps that are the only record (Q12).** Before the log, the leave decision stamp is read by the request's **current** status: approved and
  rejected fold with the approval row written at the same moment; cancelled is the cancellation (cancelling overwrites the stamp — the two live
  self-cancellations have nothing else). Because the stamp carries today's `decision_notes`, a cancellation before the log names that column
  ("Decision notes: …") rather than presenting it as the cancellation's reason. Overtime `reversed_*` and `discarded_*` fold with the lines'
  `voided_at`. Attendance `completed_*` folds with the lines' `frozen_at`; reopening clears the completion and overwrites the last reopen, so the
  trail says "Only the latest completion and reopening of this month were kept before the log began." A medical claim's withdrawal recorded no
  person: "Not recorded", never `updated_by`.
- **Machine text (Q10).** With approvals off, `decide_overtime_batch` appends a Chinese sentence to the approver's note; the renderer strips it
  (`stripOvertimeMachineNote`) and keeps the person's words. On the claim page, the note `pay_medical_claim` writes into the expense ("Medical
  claim MC-… (EMP-…)") is not presented as a reason. The writers are unchanged (`docs/known-issues.md`).
- **Side effects are not events.** Submitting and approving overtime restamp every line's day kind; reversing and discarding void every line;
  completing attendance freezes every line's derived figures. None of these is said line by line.
- **Collections (M11).** Leave types and public holidays are one block each. A holiday is hard-deleted; the trail finds it in the change log and
  says "Public holiday deleted · <name>" with its last date. `holiday_key` (a machine key) is hidden (Q33).
- **`/me` (Q14 · Q15).** Only the two request kinds the employee raises carry a trail on `/me`, under M8. The approval rows, the leave draws and the
  finance side of a claim are Restricted there; the decider is named by the ActorName rule (Restricted to an employee without hr.view; the
  `/me` table's Decision column already names who decided).
- **Overtime (M1 · Q20).** The batch is readable by any of the page's three codes. The warehouse approver, who holds `action.overtime_approve`
  but not `module.hr.view`, sees the employees on the lines and the people who acted as Restricted in the trail, while the page shows him the
  line names — the registered difference (`AT1D1-OVERTIME-APPROVER-NAMES-PAGE-VS-TRAIL`).
- **Links (Q36 · Q37).** `document_types`: medical claims and attendance periods link to their detail pages. Overtime batches have no `code` column
  and stay out of `document_types` (global search builds `SELECT code`); their label and link come from `trail_ref_label` / `trail_row_record`,
  the same shape as sales (1c-2). The expense subject gains `medical_claims` as a member (not home), so an expense raised for a claim shows it.
- **Working lists kept (Q27).** The leave consumption table and the overtime "Started by / Submitted by / Decided by / Reversed by" list stay.
- **Checks.** Fixture **245** (each subject's field edit and key event; the pre-log leave fold and the self-cancellation; M8 on `/me` with ActorName;
  one carry-forward run; both collections and a hard-deleted holiday; Q37; the claim's withdrawal "Not recorded"; M1 and Q20 on overtime; the
  pre-log discard, reversal, reopen ("latest only") and completion folds; Q12 and Q36 registrations), fault-injected by
  `db/scripts/2026-10-04-at1d2-fixture-injections.py` (16 injections, each red in its own arm). `scripts/check-trail-wording.mjs` arm
  **⑫ 请假与考勤** (47 goldens, plus a machine-token sweep over the nine subjects with the page's own subject, every approval decision and every
  overtime status; injection `wording-drift-1d2`). Smoke `trail` assertions on the seven 1d-2 pages (the overtime and attendance detail pages stay
  on the skip list: none on live). `scripts/probe-at1d2.mjs`: every live leave request, medical claim, its expense (Q37), the leave-type, holiday
  and grant pages, in both interfaces.

### 9.16 Pay and performance (AUDIT-TRAIL-1d-3, Tim's AT-1d Q1–Q38)

- **Pay lines are paired by employee (Q11).** `upsert_payroll_period` deletes every line and re-inserts it on each save (new ids). Within one
  operation a delete and an insert for the same employee are one line: an unchanged pair says nothing; a changed pair reads
  "Line · <name> · Gross pay: a → b" (one line per changed figure); a person who left or joined the sheet reads "Line removed / added · <name>".
  For a reader who cannot see pay (no `data.view_pay`: the five figures are masked), whether a line changed is itself pay data, so that save says
  one line, "Pay lines · N people: Restricted", instead of guessing per person.
- **Machine text in the payroll columns (Q10).** Unposting appends "[YYYY-MM-DD HH:MI unposted] <reason>" to the period's notes: that line is
  "Payroll unposted" with its reason, never "Notes changed", and its timestamp never reaches the screen; a later save compares only the
  person-written part of the notes. Deciding a request appends a bilingual "this period includes the approver's own pay line: EMP-…" line to the
  approval note: it is stripped and said in English as its own line. A request's `label` ("PAY-… · post #1") is not shown — the title says
  posting or unposting; elsewhere the request is named "PAY-… posting request". The automatic-approval note is "Approved automatically".
- **The period's journals are found by `source_id` (`source_type = 'payroll'`), not by `journal_entry_id`**, which an unpost sets to NULL; a
  reversal's `source_id` is the original journal, so reversals are an up hop through `reversed_by`. Which step a journal is (posting · salaries ·
  CPF · deductions · reversal) is read from structure — the period's journal columns, the lines' `paid_journal_entry_id`, the requests'
  `result_journal_entry_id`, the page-wide reversal set — never from the memo. A journal written with its step folds into that step's sentence
  ("Payroll posted", "Salaries paid · N people", "CPF paid", "Deductions paid", "Payroll unposted"); before the log, the journal alone says the
  same sentence. The journal number is shown only to a reader who can see the journal (the page's own rule: Restricted without finance).
- **Reviews (Q6 · Q7 · Q5).** An annual review's trail opens with "Annual review opened (cycle <name>)"; the cycle's own block says only
  "Review cycle created / opened / closed" — opening a cycle creates one review per employee in the same operation, and those reviews are not
  members of the cycle. Approval also writes the employee row and employment history (confirmation, salary); they carry no key back to the
  review and are not members, so "Review approved" states the outcome from the review's own columns — rating, probation outcome, new monthly
  salary (masked as today: Restricted without `data.view_pay`), effective date. Before the log only the approval row is left; the outcome then
  comes from the review as it is today (approval freezes those columns). `/my-reviews/[id]` is `my_review`: M8 + M12, the reviewer only; the
  approval rows are Restricted to a reviewer without `module.hr.view`. The page words: "Opened for self-assessment", "Self-assessment reopened",
  "Self-assessment finalised" (Q35). A voided review opens with "Voided on DD/MM/YYYY by <name>" and its reason (`EndedBanner`).
- **Stamps that are the only record (Q12).** `payroll_requests.withdrawn_*` (withdrawing writes no approval row) and
  `performance_reviews.voided_*` (voiding writes none) are pre-log sources, the void reason with them; this cut also registers
  `kpi_entries.scored_*` (scoring writes nothing else and a re-score overwrites it). Not registered: the lines' `paid_at` (the salary journal's
  creation says it) and `self_assessment_submitted_at` (reopening clears it, and it records no person).
- **KPI entries.** A list block on `/hr/kpi/score` for the chosen month, drawn only where scores are visible (`data.view_reviews`). One
  generation (`assign_position_kpis`, five entries) is one entry, "KPI entries generated · 5"; "KPI scored: 4" / "KPI re-scored: 4 → 5" with
  how it was scored, the evidence, the feedback and any cap. There is no review or KPI trail on `/me` (Q14 · Q16).
- **Q19 fixed.** `my_period_labels()` (SECURITY DEFINER, no arguments) returns the attendance and payroll periods the caller's own attendance
  lines and payslips belong to — kind, id, code and month, nothing else; `/me` reads the code and month from it. The two period tables stay
  `module.hr.view` only when read directly (a self-read policy would have let the whole row through, totals included).
- **One renderer fix outside these pages.** `approve_review` writes "Salary change approved with performance review <uuid>" into
  `employment_history.notes`; the employee page now says "Changed through a performance review" instead of printing the note (1d-1 recognised
  only the probation sentence).
- **Checks.** Fixture **246** (PP: recorded, re-saved, posted, unposted, withdrawn, paid, CPF; masked figures; hidden journals · PQ: the pre-log
  withdrawal · RV: Q7 · MR: M12 and Q5 · CY: Q6 · RX: the void, after and before the log · SC: M11 · KP: Q14 · Q16 and the pre-log score ·
  Q: Q19 · R: registrations), fault-injected by `db/scripts/2026-10-05-at1d3-fixture-injections.py` (21 injections, each red in its own arm).
  `scripts/check-trail-wording.mjs` arm **⑬ 工资与评审** (53 goldens, two contract checks for the note splitters, and a machine-token sweep over
  the six subjects with the page's own subject, every approval decision of both kinds, every request and review status; injection
  `wording-drift-1d3`). Smoke `trail` assertions on the payroll, review, cycle and scale pages, and on `/my-reviews/[id]` in the reviewer-session
  request. `scripts/probe-at1d3.mjs`: every live payroll period (and Q27), every review, the cycle, scale and KPI blocks, the `/me` subjects, and
  zh = en on every 1d-3 page plus a 1d-2 and a 1d-1 page.

## 10. Pay and personal data follow each role (U1-A, v1.4.35, 2026-10-05)

Tim's UNBLOCK-1 rulings Q1–Q13 (Step 0 hand-back `docs/surveys/UNBLOCK-1/STEP0-HANDBACK.md`; hand-back `docs/handbacks/U1-A.md`).
Every masked value reads **Restricted** — on the page, through the masked view, in each page's audit trail and on the
change history; a genuinely empty value still reads **(empty)**.

### 10.1 Payroll journals (Q1 · Q2 · Q3)

- **What is pay:** every line of every journal entry with `source_type = 'payroll'` — the posting, the pay run, CPF,
  deductions, and their reversals (a reversal copies `source_type`). Only `data.view_pay` holders see the amounts.
- **The API** (`journal_lines` through PostgREST): a RESTRICTIVE policy, `"amounts: payroll journal lines need
  data.view_pay"`, removes those rows for everyone else. Standing decision 1 (no column masking on the ledger) is kept:
  nothing was revoked on `journal_lines`.
- **The pages** read `journal_lines_masked` (owner rights, `module.finance.view`): the line is there, the account and the
  line memo (employee code and name, Q3) are there, `debit` · `credit` · `amount_ccy` are null, `amounts_restricted` is
  true, and `side` says which side the line is on.
- **No report, balance or reconciliation changes for any reader** — every read that would have silently lost those rows
  now reads as the owner: `trial_balance_totals()` (trial balance), `journal_close_preview()` (month close),
  `journal_export_lines()` (GL CSV, the three amount cells read `Restricted`), `bank_book_balance_asof()` (now SECURITY
  DEFINER), and the views `bank_unmatched_journal_lines`, `fx_rate_gaps`, `fx_month_end_readiness` (now owner rights, each
  with its own `module.finance.view` arm). `account_ledger()` masks the per-line amounts; its period total is unchanged.
- **The trail follows the screen, not the API.** `trail_row_visible()` skips restrictive policies whose name starts with
  `amounts:` — they hide whole rows on the API only because PostgREST cannot mask a column per row. On the trail the line
  is present and its amounts are masked by the `pay_journal` rule. A trail line whose amounts are restricted renders
  `Restricted` (it used to render `Credit 0.00 SGD`).

### 10.2 Payroll period totals, requests and approval amounts (Q9 · Q10)

`payroll_periods`' five totals, `payroll_requests`' `snapshot` · `gross_total` · `amount_base`, and `approval_log`'s
`amount_ccy` · `amount_base` on payroll-request rows are behind `data.view_pay` (base columns revoked; `_masked` views;
rules `code:data.view_pay` and `apr_amount`). The approval-log read rule became one function, `approval_log_readable()`,
called by both the policy and `approval_log_masked`.

### 10.3 Health details (Q8) and HR's notes (Q6 · Q7)

- New code **`data.view_health`** (admin · hr · cco · cfo · finance). It gates `medical_claims.description` and
  `amount_sgd` and `leave_requests.reason` · `certificate_ref` · `exception_reason` (rule
  `code_or_self:data.view_health:employee_id` — the employee keeps their own), `medical_claim_status`, the medical-claim
  rows' approval amounts, and `medical_claim_balance()`.
- `employees.notes` and `separation_notes`: rule `code:module.hr.view`, not self. **The personal-data export
  (`export_my_personal_data`, `my_record_changes`) still gives the employee the history of those notes** — Tim's PDPA
  ruling, the one deliberate exception (Q7).
- Search no longer matches or labels by a masked column (`document_types`: employee `notes`; leave `reason` and
  `certificate_ref`; medical `description`).

### 10.4 Redaction scope (Q11)

Anonymisation erases the free text on the person's salary-change requests (`reason`, `decision_notes`,
`withdraw_reason`), payroll lines (`notes`), leave requests (`reason`, `certificate_ref`, `decision_notes`,
`exception_reason`) and medical claims (`description`, `receipt_ref`, `decision_notes`) — in the tables (null, or
`ANONYMISED` where a constraint forbids null) and in their log rows (JSON null, through the same guarded redaction, once
per row). **Amounts are kept**: they are accounting records with statutory retention, and once the person is anonymised
they belong to "a former employee". Fixture 247 AN arm pins it.
