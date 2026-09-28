# LEAVE-BAL-1 + NAME-1 — leave cannot be booked beyond the balance; employees have a first and a last name (2026-09-28)

**Tester line — v1.4.31:** Leave can no longer be booked beyond what is available — pending requests now count against the balance,
/me shows Pending and Available to book, and the employee form has First name and Last name fields.

**Opening gate:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `b636a05042acd7f65f794adb359f570b7fdc26f4` (OVERTIME-1 close-out).
**Approvals were ON and stayed ON** (L1 finance · L2 cfo · 1,000). Every figure below is a script's own exit line or a query named
with its identity (`postgres`, `rolbypassrls = t`, base tables unless a view is named; "as X" = `SET LOCAL ROLE authenticated` + X's
JWT, `auth.uid()` asserted).

## §1 · Fold-in: the Supabase CLI

- **How it was installed:** Homebrew, from the **`supabase/tap`** tap (`brew info supabase`: "From: …/supabase/homebrew-tap"), not
  homebrew/core and not npm. `/opt/homebrew/bin/supabase` → `Cellar/supabase/2.107.0`; `codesign -v` → "invalid signature";
  `supabase --version` → exit 137.
- **Reinstalled the same way:** `HOMEBREW_NO_AUTO_UPDATE=1 brew reinstall supabase/tap/supabase` → **2.108.0** (the tap's current
  formula; brew's cleanup removed 2.107.0). `codesign -v` passes; `supabase --version` exit 0 from `/opt/homebrew/bin`; no scratch copy on PATH.
- **`npm run types:gen` uses it:** exit 0 and byte-identical to the committed `lib/database.types.ts` before this cut; after the
  migration it regenerated with exactly the two new columns (+12 lines). The very first run after the reinstall exited 1 with no
  stderr and did not reproduce; no keychain prompt was seen by me.

## §2 · Step 0 and Tim's answers

`mattpocock-skills:grilling` was run; the Step 0 hand-back put 22 questions with recommendations. **Tim accepted every one, Q1–Q22,
as stated (2026-09-28).** Q10 was the one that refined his earlier ruling: **at submit** available = entitlement − approved −
pending; **at approval** available = entitlement − approved (other pending requests do not count).

**Facts in the brief that I measured as false (and one of my own Step 0 statements that was false):**
1. The pending leave requests are **LV-2026-0004, 0005, 0006** — LV-0001 and LV-0003 are `cancelled`.
2. ★ **My Step 0 said "tim@ has no employee record". That was wrong** — see §6.
3. "22 existing employees" = 22 rows: **7 live + 15 soft-deleted**; one live row is the tool leftover `ZZ-2BL-186301` (§7).
4. There already was a balance check — annual only, and it did not count pending requests.

## §3 · What was built

| Q | ruling | built |
|---|---|---|
| Q1 | every type with an entitlement is checked; only `unpaid` is not; `infant_care` is | `leave_balance_internal` → `balance_checked` = annual (`is_accrued`) or `default_days_per_year` set |
| Q2 | compassionate 3 · marriage 3 · examination 2 enforced as they stand | **no value changed. HR changes them at `/hr/leave/types`** |
| Q5 · Q7 · Q9 | annual = accrued to the start date + grants; other types = full `default_days_per_year` for the start date's calendar year; a request spanning two years is charged to its start year; pending = same person, type and start year | new "yearly allowance" source in `leave_balance_internal`; new keys `pending`, `bookable` (= available − pending) |
| Q8 | **no advance leave** | unchanged: **annual leave accrues at month end, so no new annual leave shows in January until January is complete** (carry-forward grants excepted, which HR runs by hand) |
| Q10 | submit counts pending; approval counts approved only | `submit_leave_request` compares `bookable`; `decide_leave_request` compares `available`, for every checked type |
| Q11 | HR exceptions are checked; no override | the exception path passes the same check; help text and the column comment now say the excess is a separate unpaid-leave request |
| Q12 | signed-in users lose INSERT/UPDATE/DELETE on `leave_requests`; three write policies dropped | `REVOKE ALL … FROM authenticated; GRANT SELECT` (precedent `import_batches`) |
| Q13 | lock the employee row in submit and approve | `FOR UPDATE` on `employees` in both |
| Q14 | codes unchanged; the submit message says pending counts | annual `INSUFFICIENT_ACCRUED_LEAVE\|avail\|req`, others `INSUFFICIENT_BALANCE\|avail\|req`; `annual_leave_available_from` now compares `bookable`, so its "enough from" date accounts for pending |
| Q15 | show Pending and Available to book | `/me` and `/hr/leave/balances`; `/hr/leave/[id]` draws the balance for every checked type (it used to draw only annual) and shows Pending |
| Q17–Q21 | First name (required on save, no DB constraint) and Last name (optional) before Preferred name; 22 rows stay empty; display elsewhere unchanged; same visibility as legal name | `employees.first_name` / `last_name` + grant + `employees_masked`; PDPA export includes them; `anonymise_employee` blanks them; `lib/employeeNames.ts` + `createEmployee` / `updateEmployee` |
| Q3 · Q4 · Q6 · Q16 | not built | `docs/known-issues.md` LEAVEBAL1-CALENDAR-WEEK-UNITS · -HOSPITALISATION-INCLUDES-SICK · -NO-NEW-HIRE-PRORATING · -HALF-DAY-QUIRKS; Q6 also in `docs/forward-queue.md` |

**Messages (en / zh):**
- `leave.errInsufficientBookable` (submit, non-annual): "Not enough leave: {0} days available to book (your pending requests already
  count against the balance), {1} requested." / 「假期不足:可请 {0} 天(待审批的申请已计入),申请 {1} 天。」
- `leave.errInsufficient` (approval) unchanged: "Not enough leave: {0} days available, {1} requested."
- `leave.errInsufficientFrom` / `errInsufficientNever` (submit, annual) now say "available to book … (pending requests count against it)".
- `leave.pending` Pending / 待审批 · `leave.bookable` Available to book / 可请 · `leave.grantType_yearly_entitlement` Yearly allowance / 每年额度.
- `hr.colFirstName` First name / 名字 · `hr.colLastName` Last name / 姓氏 · `hr.errFirstNameRequired` First name is required. / 名字必填。

## §4 · Pages — every new or changed route, with its file

| route | file(s) | change | permission |
|---|---|---|---|
| `/me` | `app/me/MyLeavePanel.tsx` (form: `app/hr/leave/LeaveForm.tsx`, action `submitLeave` in `app/hr/leave/actions.ts`) | balance card adds Pending and Available to book; submit refusals count pending | self |
| `/hr/leave/new` | `app/hr/leave/new/page.tsx` → `LeaveForm` → `submitLeave` | HR record and exceptions are balance-checked | `module.hr.edit` |
| `/hr/leave/[id]` | `app/hr/leave/[id]/page.tsx` → `DecideControls` → `decideLeave` | balance card for every checked type, with Pending; approval re-check | `action.decide_hr_requests` |
| `/hr/leave/balances` | `app/hr/leave/balances/page.tsx`, `BalancesTable.tsx` | Pending and Available to book columns | `module.hr.view` |
| `/hr/employees/new` | `app/hr/employees/EmployeeForm.tsx`, `app/hr/employees/actions.ts` (`createEmployee`) | First name (required), Last name | `module.hr.edit` |
| `/hr/employees/[id]/edit` | same (`updateEmployee`) | same; a legacy record without a first name must get one on its next save | `module.hr.edit` |

No new route. No new permission code (so nothing to grant to admin).

## §5 · Verification (in the order the brief set)

| # | step | verdict (the script's own line) |
|---|---|---|
| 1 | offline gate `db/gate.py --offline` | **`GATE_OFFLINE_EXIT=0`** (58 s; 236 fixtures incl. 233) |
| 2 | backup `~/evoltrya-backups/backup.sh` (background, `run_detached`) | **`BACKUP_EXIT=0`** — `evoltrya-backup-2026-09-28-1814.dump`, 6,676 TOC entries (previous 6,604, floor 5,943), `pg_restore --list` verified |
| 3 | `db/apply_migration.sh` | **`APPLY_OWN_EXIT=0`**; preflight clean; committed **2026-09-28 18:34:31 CST** (`db/migration-windows.tsv`); in-transaction self-proof passed (grants unchanged, approvals ON, pending set unchanged, every leave row's fingerprint unchanged, new name columns empty, `leave_requests` SELECT-only for `authenticated` with exactly its two read policies, signatures unchanged, every pending document has a decider who is not its own party) |
| 4 | `npm run types:gen` (CLI 2.108.0 from `/opt/homebrew/bin`) | **`TYPES_OWN_EXIT=0`**, +12 lines (`first_name` / `last_name` on `employees` and `employees_masked`) |
| 5 | `npx tsc --noEmit` | **`TSC_OWN_EXIT=0`** |
| 6 | `npm run build` | **`BUILD_OWN_EXIT=0`** (includes the new `check-employee-names.mjs`) |
| 7 | full gate `db/gate.py` | **`GATE_EXIT=0`** (502 s): rebuildable ✓ · mirrors = live ✓ (incl. generated types) · fixtures ✓ · anon surface ✓. Tree unchanged from gate start to after the checks below. |
| 8 | `node scripts/check-i18n.mjs` | **`I18N_OWN_EXIT=0`** |
| 9 | `node scripts/check-error-swallowing.mjs` | **`SWALLOW_OWN_EXIT=0`** (0 unallowed) |
| 10 | smoke `scripts/smoke-routes.mjs` (background) | **`SMOKE_EXIT=0`** — 257 ok, 8 skipped (no data), 0 FAILED; 231 routes timed, 1,303.0 s total, median 5,479 ms (slower than the 765 s measured 2026-09-05; `next-server` was busy compiling throughout, not stalled) |
| 11 | live proof `db/scripts/2026-09-28-leavebal1-live-proof.sql` (one transaction, ROLLBACK) | **`LIVEPROOF_OWN_EXIT=0`** — see below |

**Scratch cleanup reading** (`npm run check:scratch`, exit 1 = "stale rows reported"): **6 stale rows, all pre-existing** (627–1,270 h old,
five still referenced) — `ZZ-SMOKE-PROBE` · `ZZ-SMOKE-M25` · `ZZ-SMOKE-NTF` · `ZZ-SMOKE-S25` · `ZZ-SMOKE-CJK` · `ZZ-SMOKE-IB25`; none from
this session. The smoke's one-off account/role/grant were removed: `auth.users` 7 → 7, unrevoked `user_roles` identical before and
after, `.ephemeral/` empty, no smoke or dev-server process left.

**Fixture 233** (`db/fixtures/233-leave-cannot-be-booked-beyond-the-balance-and-a-name-has-a-first-part.sql`) — arms:
A0 self-service annual over balance refused `|6|7` · A1 within accepted · **A2 pending counted at submit** `|2|3` · **A3 exactly equal
accepted** (2 = 2) · A4 HR record over refused `|0|1` · **B1 half day stored 0.5** (pending 0.5, bookable 4.5) · B2 sick within accepted ·
B3 self-service sick over `INSUFFICIENT_BALANCE|0.5|1` · B4 HR record sick over · **B5 HR exception over refused** `|0.5|3` · **C1 unpaid
not checked** (20 days accepted) · **C2 infant_care checked** `|3|4` · **D1/D2 approval counts approved only: first approved, second
refused `INSUFFICIENT_ACCRUED_LEAVE|0|2`** · D3/D4 same on sick `|1|3` · **W1–W3 direct INSERT / UPDATE / DELETE by a `module.hr.edit`
holder → `permission denied for table leave_requests`** · M1 first/last name readable like legal name (column grant + `employees_masked`)
· **N1 PDPA export carries both** (last_name key present, null) · **N2 `anonymise_employee` blanks both**.
**Fault injection** (`db/scripts/2026-09-28-leavebal1-fixture233-injections.py`, local rebuild on 127.0.0.1:55433, never live):
control green, then **19 injections, each red on the arm it names — `INJECT233_BAD=0 of 19`** (A0 · A2 · A3 · A4 · B1 · B3 · B4 · B5 · C1 ·
C2 · D1 · D4 · D2 · W1 · W2 · W3 · M1 · N1 · N2). ★ One cell worth reading: removing only the approval re-check turns **D4** (sick)
red but **not D2** (annual) — annual leave is held a second time by the draw loop's own `INSUFFICIENT_ACCRUED_LEAVE`. D2 goes red only
when both are removed. That is a measured second guard, not a blind injection.

**"First name required on create and on update; last name optional; blank stored as NULL"** is an app-level rule (Tim Q17: no
database constraint), so its fixture is `scripts/check-employee-names.mjs` (in `npm run build`): it imports `lib/employeeNames.ts` and
runs it, and reads the AST of `app/hr/employees/actions.ts` and `EmployeeForm.tsx` — both actions ask `firstNameMissing` **before**
their `.insert` / `.update`, `readForm` passes both fields through `normaliseName`, `first_name` is `required` and `last_name` is not
(15 assertions, count pinned). **Fault injection: 7 of 7 red** — update path loses the guard · create checks after the insert · blank
not stored as NULL · first_name not required · last_name made required · readForm bypasses the helper (exit 1) · checker blinded by
renaming `updateEmployee` (exit 2, coverage assertion). Control green after restore.

**Live proof** — `postgres` builds two temporary employees and two directly-written pending rows (`created_by NULL`); each arm runs
as a real account (`SET LOCAL ROLE authenticated` + JWT). Accrual for a 2020 office hire by 2026-12-01 (system start 2026-08-01): **8**.
- ① admin@ records all of December (22 days) → **`INSUFFICIENT_ACCRUED_LEAVE|8|22`**
- ② admin@ records 2026-12-07 (1 day) → **OK**; balance then `available 8 · pending 1 · bookable 7`
- ③ two pending rows, 8 days + 1 day: **tim@ approves the first → OK, approved**; **the second → `INSUFFICIENT_ACCRUED_LEAVE|0|1`**, stays pending
- ④ admin@ direct `UPDATE leave_requests` → **`permission denied for table leave_requests`**
- ⑤ admin@ inserts and then saves an employee with first name `Ann` and no last name → `employees_masked` reads `Ann` / `NULL`
- inside the transaction the 6 pre-existing leave rows' whole-row fingerprint is still `e4334e8c…`; then **ROLLBACK**.
- Two earlier runs stopped before the end and rolled back whole: (1) the direct rows had taken `created_by` = admin@ from the JWT, and
  four eyes correctly refused tim@ as the same person (`SELF_APPROVAL_FORBIDDEN|raiser`); (2) my final guard counted the proof's own
  `LV-2026-0007` as pre-existing. Both were defects in the proof script, fixed as recorded in its comments.

**Before / after readings** (`db/scripts/2026-09-28-leavebal1-readings.sql`; before 18:19:49 — before the migration — after 19:22:28 —
after smoke and the live proof). Identical except for what this cut changes, plus one change that is not this cut's:
- identical: 6 leave requests, whole-row md5 `e4334e8c873c6aa55670381f388a50d4` (LV-2026-0004 / 0005 / 0006 still pending, untouched) ·
  `leave_consumption` 1 row, md5 unchanged · `leave_grants` 0 · `leave_types` md5 unchanged · 22 employees (7 live), md5 without the two
  new columns unchanged · approval_log 14 · journal 82 / 184 / debit 1,636,102.89 · pending registry (CLM-2026-0004; LV-0004/0005/0006;
  MC-2026-0001; ST-2026-0082…0086) · 7 auth users · unrevoked role holdings · **AP unexplained 0.00, AR unexplained 0.00** (as tim@).
- this cut: employees with a first or last name `absent → 0` · `authenticated` on `leave_requests` all privileges → `SELECT` · policies
  5 → the 2 read ones · the six functions' definitions (new md5s; still SECURITY DEFINER, authenticated yes, anon no).
- ★ **not this cut: `cco` 39 → 41 codes (sandra@).** `role_permissions` shows the whole `cco` set rewritten at **2026-09-28
  19:00:35 CST by `admin@swm-os.test`** (41 rows, one timestamp — the role editor's save), adding **`module.hr.edit` and
  `action.decide_hr_requests`**. Nothing in this session wrote as admin@ at that time (the smoke uses its own one-off account; the
  live proof ran at 19:21 and rolled back). **Left as found.** Consequence for leave: sandra@ can now decide leave requests (another
  eligible approver) and record leave for others.

## §6 · tim@ reconciliation (read-only, nothing changed)

**How tim@ resolves to an employee:** `current_user_employee()` → `account_person(auth.uid())`
(`db/functions/account_person.sql`), which first looks for `employees.user_id = <account>` and, finding none, falls back to
**`employee_accounts`** (the additional-account table from APR-ROUTE-1 Batch B). Measured as `postgres`:

| table | row |
|---|---|
| `employees.user_id = 634c00f9…` (tim@) | **none** |
| `employee_accounts` | `user_id 634c00f9… → employee_id 4737faa9… (EMP-2026-0002)`, linked 2026-09-23 15:01:53 by `321f1819…` (admin@) |
| `account_person('634c00f9…')` | `4737faa9…` = **EMP-2026-0002** |

So **OVERTIME-1's Step 0 was right** (tim@ is an additional account of EMP-2026-0002, the same person as admin@), and **my
LEAVE-BAL-1 Step 0 statement "tim@ has no employee record" was wrong**: I read only `employees.user_id`, which is the primary-account
branch. All 7 accounts resolve to an employee. It changed no answer in this cut (tim@ is a decider of leave through `cfo`, and is not
a party to any leave request); the live proof below uses tim@ as the approver precisely because he resolves to EMP-2026-0002 and is
not a party to the proof's requests.

## §7 · ZZ-2BL-186301 — NOT removed

Checked every foreign key into `employees` (33 columns, catalog walk as `postgres`): **`equipment_maintenance.performed_by_employee_id`
references it (1 row)** — the same row `docs/accounts-roles-and-permissions.md` recorded when the other three `ZZ-2BL-*` rows were
removed and this one kept. Per the brief, **nothing was removed**. It stays under `SMOKE-SCRATCH-ROWS-STALE` in `docs/known-issues.md`.
Removing it needs a decision about that maintenance row first.

## §8 · Broken window

**Start: 2026-09-28 18:34:31 CST** (measured: `db/apply_migration.sh` commit, `db/migration-windows.tsv`). **End: the Vercel
"Ready" of the push below — read by Tim, not by this machine** (AGENTS.md: the terminal work ends at the push).

What old code + new database does in the window (nothing is broken):
- Submit / approve: the functions keep their signatures; the refusal codes are the two the old app already translates, so an
  over-balance request is refused with the old wording (which does not mention pending).
- `/me` and `/hr/leave/balances` keep showing `available` (unchanged meaning); the new `pending` / `bookable` keys are ignored.
- `/hr/leave/[id]` keeps drawing the balance only for annual leave.
- Employee create / edit: the old form does not send `first_name`; both columns are nullable, so saves work and leave them NULL.
- Nothing in the old app wrote `leave_requests` directly, so the revoke breaks no screen.

## §9 · Decisions I took without asking

1. **`available` keeps its meaning** (entitlement − approved); I added `pending`, `bookable` and `balance_checked` instead of
   redefining it, so `employees_masked.annual_leave_available_days`, `/me`, `/hr/leave/balances` and `/hr/leave/[id]` keep reading
   the same number, and approval (Q10) compares exactly that field.
2. **Refusal numbers never go below 0** (`GREATEST(avail, 0)`): an over-committed legacy balance reads "0 available", as your
   fixture case asked, not a negative number.
3. **A separate submit-time message key** (`leave.errInsufficientBookable`), because the same code carries a different number at
   submit (after pending) and at approval (approved only); the approval wording is unchanged.
4. **Non-annual types write no `leave_consumption`** on approval; "approved" for them is the approved requests starting in that
   calendar year. `leave_grants` of those types still add to the entitlement (there are 0 grants on live).
5. **Lock order** in `decide_leave_request`: the request row, then the employee row; submit locks only the employee row.
6. **The approval check reads `leave_balance`**, which asks for `module.hr.view` or self. Every current holder of
   `action.decide_hr_requests` (admin, cfo, finance — and since 19:00:35, cco) has `module.hr.view`.
7. **`leave_requests`: `REVOKE ALL … FROM authenticated; GRANT SELECT`** (the `import_batches` shape), and kept the SILENT-1
   `enforce_write_permission` trigger as a second layer. `anon`'s grants on the table were left as they are (RLS gives anon nothing;
   they are tracked by the anon-surface baseline, which stayed green).
8. **The first-name rule lives in a new pure module `lib/employeeNames.ts`** and is proved by a new build-chain check
   `scripts/check-employee-names.mjs` (`npm run check:names`), because a SQL fixture cannot see a server-action rule.
9. **`/me` balance card went from 4 to 3 columns per row** (6 cells), with **Available to book** as the large figure; I did not run
   the phone layout probe (`survey-phone.mjs`) — it was not in the brief's order; the card is a plain responsive grid.
10. **`/hr/leave/[id]` shows a Pending line** in its balance card (the approval check ignores it, but the approver can see it).
11. **Types were generated by CLI 2.108.0** (the reinstall moved 2.107.0 → 2.108.0); output before the migration was byte-identical.
12. **The live proof ran as admin@ (record, direct write, employee save) and tim@ (approve)**, with its two pending rows written
    directly by `postgres` with `created_by NULL`, all inside one rolled-back transaction.
13. **The migration is built from the mirrors by `db/scripts/build_leavebal1_migration.py`** (OVERTIME-1's shape), reusing its
    pending-decider check.
14. **Not removed: ZZ-2BL-186301** (§7) and **not touched: the `cco` role change** (§5).
