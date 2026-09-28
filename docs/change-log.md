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

**Reading goes through one function**, `change_log_rows()`, which requires the permission code **`data.view_change_log`**.
It is granted to `admin` and `cfo` only and bundled into no other role (Q10 · Q1). The only screen is
**Change history**, `/settings/change-history`. It sits under Settings and in the Finance **Reports** group, with one
registry entry and one code. Filters: date range, table, record (any value in the row key), who (an account, or
"no session"). Newest first, 50 per page.

**Masking follows the source screens.** A value the reader cannot see on its own screen is replaced by
`{"$restricted": true}` and rendered as **Restricted**. A value that is genuinely empty stays empty and renders blank.
The two are never confused.

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
