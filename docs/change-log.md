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
"Removed account") · Key events only. Newest first, 25 operations per page. It still lists every write (Q31).
Each page's own trail is a **different** reader, `record_trail()` (§9) — the global reader was not widened.

**Masking follows the source screens.** A value the reader cannot see on its own screen is replaced by
`{"$restricted": true}` and rendered as **Restricted**. A value that is genuinely empty stays empty and renders as
**(empty)** (a blank before AUDIT-TRAIL-1a). The two are never confused. Since AUDIT-TRAIL-1a the masking is **one step**,
`change_log_mask_row()`, called by both readers (§9.3).

- The rules are one list, `change_log_mask_rules()`: one row per column, 80 columns on 26 tables. They were copied from
  the `CASE WHEN … END AS <column>` of every `<table>_masked` view, plus the new `purchase_order_history_masked`.
- Rule forms:
  - `code:<data code>`;
  - `code_or_self:<code>:<column>`, where the reader's own employee row counts, as in `employees_masked`;
  - `pft:direction` and `pft:formula_id`, where a sales formula asks `data.view_prices` and anything else asks
    `data.view_purchase_prices`;
  - `pft3`, for `pricing_formula_history`.
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
three pages; the rest follow in AT-1b, AT-1c and AT-1d (`docs/forward-queue.md`, "HISTORY family").
Rulings: AUDIT-TRAIL-0 Q1–Q43, all accepted as recommended (`docs/surveys/AUDIT-TRAIL-0/README.md`).

| page | subject | view code | what rolls up into its trail |
|---|---|---|---|
| `/purchasing/orders/[id]` | `purchase_order` | `module.purchasing.view` | the order · lines · payment terms · retentions · committed pricing terms · PO issues · contract terms · approval decisions · amendment history |
| `/operation/processing/[id]` | `processing_run` | `module.processing.view` | the run · inputs · outputs · cost entries and their history · cost allocations · losses |
| `/settings/roles/[id]` | `role` | `action.manage_permissions` | the role · its permissions (added / removed, named from `permissions.name_en`) |

### 9.1 The reader: `record_trail(subject, id, entries)`

- **The page names a subject, never a table.** `trail_subjects()` maps each subject to its root table and the page's own
  view code; an unknown subject raises **`TRAIL_SUBJECT_UNKNOWN`**.
- **Authorisation, three layers.** (1) The page's view code (`has_permission`). (2) The root row's own read rule — the
  table's permissive SELECT/ALL policies re-evaluated on that row (`trail_row_visible`), or on its last image if it was
  hard-deleted. (3) **Every child or related row is re-checked against its own table's read rule**, not the parent's (Q4).
  A failure at (1) or (2), including a record that does not exist, raises **`TRAIL_NOT_PERMITTED`**.
  **Refusals always raise; the reader never returns an empty list for a refusal** — an empty list reads as "nothing ever
  happened". Re-evaluating policies inside a SECURITY DEFINER function is sound because all 287 read policies resolve the
  caller from the login (`has_permission`, `current_user_employee`), none from the database role, and none is restrictive
  (measured, AUDIT-TRAIL-0 `reader-masking.md` §1.6); restrictive policies would be ANDed in if they ever appear.
- **A row the reader cannot see** keeps its place and its time; everything else (what, who, values, keys) is null and
  `row_hidden` is true. The page prints "Restricted" in place of what happened and who (Q4). When only part of an operation
  is hidden, the entry adds "Part of this change is restricted."

### 9.2 Which rows belong to a record (Q3 · Q6)

`trail_subject_members()` lists each subject's child and related tables: `table.fk_column = parent_table.id`, plus a fixed
condition for polymorphic tables (`approval_log.subject_type = 'purchase_order'`). Grandchildren name a child as parent
(retentions hang off PO lines). Rows are found **at read time**, in two steps, because an edit stores only the changed
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
(`change_log_rows(p_by_entry => true)`, keyset on the highest `seq`).

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
   `MUST_CONTAIN` entry `{ trail: 'audit-trail' }`.
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
- **Who** (Q14 · Q17 · Q18): the person's preferred name, else legal name, for every reader of the trail (the trail adds no
  masking rule of its own); "System (automatic)" for every write with no login (migrations included); "Removed account"
  when neither the account nor a person is left; a disabled account shows the plain name; "A former employee" after
  anonymisation; "Not recorded" for pre-log rows whose table kept no actor.
- **Machine-written Chinese** (Q8): typed text is shown as written; values the system wrote in Chinese are shown in English
  (`messages/trail-machine-values.ts` for `inbound_batches.stage`; automatic-approval notes are replaced by
  "Approved automatically (approvals were switched off)").

### 9.8 Checks

| check | reads | fails on |
|---|---|---|
| `scripts/check-trail-wording.mjs` (in `npm run build`) | the repository | a machine token in any sentence built for any column, value, actor or event of every logged table; a registry mismatch; a missing or unused catalogue key; a subject column without an English label or value. Eleven named fault injections (`TRAIL_WORDING_FAULT`) |
| `scripts/smoke-routes.mjs` `{ trail }` content assertion | the three trail pages and `/settings/change-history`, rendered | a section that is not `entries`; a uuid, column or table name, raw code, JSON, "null" or database role name in its text (typed text excluded). Injection: `SMOKE_TRAIL_FAULT=1` |
| fixture 236 | the rebuilt database | grouping, discovery, masking, hidden rows, refusals, pre-log merge, actors, deleted references, summary reader; 30 fault injections (`db/scripts/2026-09-29-at1a-fixture236-injections.py`) |

Both machine-token checks use one detector, `lib/trail/machineTokens.ts`, which proves itself on every run (known-bad
samples must all be caught, a known-good sentence must pass).

