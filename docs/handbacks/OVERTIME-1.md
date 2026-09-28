# OVERTIME-1 — site-staff overtime, entered by month and approved by the batch (2026-09-28)

**Tester line — v1.4.30:** Overtime for site staff can now be entered by month under HR → Overtime and approved by the warehouse
lead; no one is marked as site staff yet, so the page shows where to mark them.

**Opening gate:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `726afff47274fdb0be735989fbb5df0a740ae811` (EMP-SELF-1).
**Approvals were ON and stayed ON** (L1 finance · L2 cfo · 1,000). Every figure below is a script's own exit line or a query named
with its identity (`postgres`, `rolbypassrls = t`, base tables unless a view is named; "as X" = `SET LOCAL ROLE authenticated` + X's
JWT, `auth.uid()` asserted each time).

## §W · EMP-SELF-1's broken window — closed with bounds, labelled by kind

Tim confirmed EMP-SELF-1 deployed (OVERTIME-1 brief), with no Vercel "Ready" time.

| | time (CST) | kind |
|---|---|---|
| start | 2026-09-27 21:38:32 | **measured**: `db/migration-windows.tsv` |
| end, lower bound | 2026-09-27 22:43:06 | **measured**: the push moved `origin/main` → `726afff4` (`git reflog show --date=iso refs/remotes/origin/main`) |
| end, upper bound | 2026-09-28 11:32:30 | **derived**: this session's first read of `now()` as `postgres`, taken with Tim's "deployed" already in hand — a relayed confirmation, not a measurement of Vercel |

**Window: at least 1 h 04 min 34 s, at most 13 h 53 min 58 s.** Written into `docs/forward-queue.md` item 17.
**EMP-SELF-1's three build decisions:** 1 (expense Withdraw hidden) — overridden by Q21 and fixed here; 2 and 3 — accepted by Tim (2026-09-28).

## §0 · Step 0 (grilling) and Tim's answers

`mattpocock-skills:grilling` was run on the scope; the Step 0 hand-back put 23 questions with recommended answers.
**Tim accepted every recommendation, Q1–Q23, as stated (2026-09-28).** The ones that shaped the build:

| Q | ruling | built |
|---|---|---|
| Q1 · Q2 | the OS reports **hours, never money**; rate, multiplier and base stay with the payroll provider (policy 7.1 unchanged) | approved hours are fixed into `attendance_lines` when `complete_attendance_period` runs; `/hr/payroll/[id]` shows them read-only |
| Q3 | reuse `attendance_periods` / `attendance_lines` | `record_attendance` keeps its signature, refuses non-zero hours (`ATTENDANCE_OT_THROUGH_OVERTIME`); the attendance grid shows approved hours read-only |
| Q4 | public holiday → `public_holiday`; Sunday → `rest_day` for everyone; else `weekday` | `overtime_day_kind`; public holiday judged first; per-person rest days deferred (known-issues C-2-OT) |
| Q5 | the switch does not govern overtime; raiser = submitter, subject = every employee in the batch, by person; R2 never; no CFO override | `decide_overtime_batch` (see `docs/approvals.md` §3x) |
| Q6 | one open batch per month; a supplementary batch after approval | partial unique index + `OVERTIME_BATCH_OPEN_EXISTS` |
| Q8 | no arrears; a completed month refuses create, submit, approve, reverse; completion refused while a batch is open | `overtime_assert_month_open` · `OVERTIME_BATCH_OPEN_FOR_MONTH` |
| Q10 | whole-batch reject with a note; finance withdraws a waiting batch; a wrong approved batch is reversed whole while the month is open | `withdraw_` / `reverse_overtime_batch` |
| Q11 | `employees.is_site_staff`, default false, nobody flagged; set by `module.hr.edit` on both employee forms | done |
| Q12 | `action.overtime_enter` → finance + admin; `action.overtime_approve` → warehouse + admin | done (see "the admin rule" below) |
| Q14 | a site employee sees their own approved overtime on `/me` | `my_overtime_lines()` + "My overtime" panel |
| Q15 | one line per employee per day | partial unique index + `OVERTIME_DUPLICATE_DAY` |
| Q17 | the empty-state wording, both languages | verbatim in `overtime.noSiteStaff` |
| Q19 – Q21 | the three fold-ins | done (§1) |
| Q22 | queue items 18 and 19 in Tim's words; this cut is v1.4.30 | written verbatim in `docs/forward-queue.md` |
| Q23 | EMP-SELF-1 decisions 2 and 3 accepted; 1 overridden by Q21 | recorded (§W) |

**The admin rule (fold-in 6).** Rule applied: **the standing ruling of 2026-09-24 — `admin` holds every code and receives every new
code in the same migration.** It is `docs/role-matrix.md` §1, **line 149**; Tim's reply cited line 147, which is the row that *says*
"system admin only" (the superseded one). Per Tim's instruction, every place that repeated "admin is system-admin only" is now
corrected: role-matrix line 23 (the positions line) and line 147 (struck through, pointing at 148–149), `docs/approvals.md` §3i
heading (struck with a note), and the comment above admin's bootstrap in `db/tables/role_permissions.sql`. Live `admin` held 68 of 69
codes before this cut (it has never held `module.tasks.view_all`); it holds 70 of 71 after.

**Statements measured false in the build brief:** one — the line number above (147 vs 149). Everything else the brief asserted was
re-measured and held (SHA, approvals ON with finance / cfo / 1,000, attendance tables 0 rows, no site staff on live).

## §1 · What shipped

**Database** — one migration, `db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql`, built by
`db/scripts/build_overtime1_migration.py` from the mirrors:
- `employees.is_site_staff boolean NOT NULL DEFAULT false` (appended) — with its column grant and `employees_masked` in the same
  migration (the masked-table rule). **Nobody is flagged**; the migration's own proof asserts 0.
- Codes `action.overtime_enter` (finance · admin) and `action.overtime_approve` (warehouse · admin).
- Tables `overtime_batches` (a month's batch: `draft → submitted → approved | rejected`, `rejected → submitted`, `submitted → draft`,
  `approved → reversed`, `draft | rejected → discarded`; label `OT <YYYY-MM> #n`, no code column) and `overtime_lines` (employee ·
  date · hours `numeric(4,2)` > 0 ≤ 24 · day type · note · `voided_at`). Read policies only; every write goes through a function.
- New functions: `create_overtime_batch` · `add_overtime_line` · `delete_overtime_line` · `submit_overtime_batch` ·
  `withdraw_overtime_batch` · `decide_overtime_batch` · `reverse_overtime_batch` · `discard_overtime_batch` (writes, DEFINER, each
  checks its code) · `overtime_month_hours` · `overtime_batch_lines` · `overtime_site_staff` · `my_overtime_lines` (readers, DEFINER)
  · `overtime_day_kind` (plain) · `overtime_approved_hours` · `overtime_assert_month_open` · `overtime_other_approver_exists`
  (internal, EXECUTE revoked from `authenticated`).
- Replaced: `record_attendance` (same signature; refuses non-zero hours) · `complete_attendance_period` (open batch → refuse; freeze
  approved hours; the frozen total must equal the approved total, else `OVERTIME_HOURS_OFF_ROSTER`) · `attendance_period_status_rows`
  (open months read approved hours live) · `record_approval_decision` (`overtime_batch` branch) · `approval_pending_documents`
  (`overtime_batch`, `blocks_disable = false`). `approval_log`: subject type `overtime_batch` and the same-named read branch.
- **Fixture 232** (E · A · O · S · K · V · D · M · F · R · X · L · C · P · Y · Q) — every arm Tim listed, plus the Q20 R2 arm.
  **Fixture 141 changed:** its B and G arms typed 2 and 4 overtime hours through `record_attendance`; they now record zero (both arms
  test "has someone recorded this line", not the hours) — the rule they relied on is the one Q3 closed.

**Screens** — en and zh for everything:
- **New `/hr/overtime`** (HR and Operations menus; open to `module.hr.view`, `action.overtime_enter` or `action.overtime_approve`):
  the batch register and "New batch". With nobody marked as site staff (live today) the button is visible and disabled, beside Tim's
  sentence: *"No employee is currently marked as site staff, so there is no one to record overtime for. Mark an employee on their
  record: HR → Employees → the employee → Edit → "Site staff"."* / 「目前没有员工被标为现场员工,所以没有可以记录加班的人。请在员工档案里标记:人事 → 员工 → 该员工 → 编辑 →「现场员工」。」
- **New `/hr/overtime/[id]`**: the lines (date · employee · day type · hours · note), totals by day type, add / remove lines, submit,
  withdraw, discard, approve / reject (note required), reverse (reason required). Missing codes → `<PermissionGate>`; the submitter's
  or an included employee's own account sees Approve / Reject disabled with the reason.
- **Employee create and edit** (`/hr/employees/new`, `/hr/employees/[id]/edit`): a "Site staff" checkbox beside Category, with a line
  saying it is separate from Category. The employee page shows it.
- **`/hr/attendance/[id]`**: the three overtime columns are read-only and show approved hours (fixed once the month is complete); a
  line says where they come from. **`/hr/payroll/[id]`**: a read-only "Approved OT hours" column and a line saying they are hours,
  not pay. **`/me`**: a "My overtime" panel for site staff (approved lines, who approved, when).
- **Fold-in 3:** the avatar menu row is "My profile" / 「我的档案」 again (still `/me`); "My leave" and "My claims" removed with their
  keys. The `/me` anchors stay.
- **Fold-in 5:** `/me` expense claims — an approved claim's Withdraw is visible, disabled, with "Already decided — only a claim that
  is still submitted can be withdrawn."; rejected and withdrawn rows have no control (the medical panel's precedent).
- **Fold-in 4 (R2):** fixture 232 arm Q (a level-2 holder decides their own expense claim and medical claim → `approval_log.self_decided`
  and `my_document_decisions().self_decided` both true) and live cell 5 (§3).

**Build decisions taken without asking — say if any is wrong:**
1. **A "Discard batch" action** (draft or sent-back → discarded, lines voided). Without it an unwanted draft would block that month's
   attendance completion — and so payroll — for ever, because Q8 refuses completion while a batch is open.
2. **A sent-back (`rejected`) batch counts as open** — it blocks a second batch for the month and blocks completion, like draft and
   submitted (Tim named "draft or submitted"; a rejected batch is a draft waiting to be fixed).
3. **Editing a line = remove it and add it again.** No in-place edit.
4. **Withdraw, discard and reverse write no `approval_log` row** — they are not decisions; the batch row records who and when (and the
   reversal reason). The approval row stays as the record of what was decided.
5. **One extra refusal at completion, `OVERTIME_HOURS_OFF_ROSTER`:** if the hours fixed into the sheet do not equal the approved total
   (someone with approved overtime is not on the roster), completion refuses rather than lose the hours.
6. **Month and day are dropdowns, not native date controls** — the build's date check allows the native-control count only to fall
   (135). The month list is this month and the 11 before it; the day list is the batch's month, narrowed to the chosen person's
   employment dates.
7. **"My overtime" on `/me` shows only for site staff or someone with approved overtime** — for office staff it would always be empty.
8. **Not built: a reminder** telling the warehouse lead a batch is waiting (registered `OVERTIME1-NO-REMINDER-ARM`).

**One environment finding, not a code change:** the Homebrew Supabase CLI (`/opt/homebrew/Cellar/supabase/2.107.0/bin/supabase`)
now fails `codesign -v` ("invalid signature") and macOS kills it on launch (exit 137, even for `--version`) — it worked at 21:40
yesterday. I did **not** touch it. Types were generated, and the full gate's type check ran, with an ad-hoc-signed **copy** in this
session's scratchpad put first on `PATH`. `brew reinstall supabase` is probably the fix; that is yours to run.

## §2 · Verify — in Tim's order; every figure is the script's own line

| step | result |
|---|---|
| 1 · `db/gate.py --offline` | first run `GATE_OFFLINE_EXIT=4`: **fixture 141 red** — it typed overtime hours through `record_attendance` (`ATTENDANCE_OT_THROUGH_OVERTIME`), the path Q3 closes; the two arms now record zero (§1). Re-run: **`GATE_OFFLINE_EXIT=0`** (58 s), 232 ✓, 141 ✓ |
| fault injection | `db/scripts/2026-09-28-overtime1-fixture232-injections.py` on a local rebuild: an uninjected control run is green, then **26 injections, one per arm — each turns fixture 232 red on the arm it names: `INJECT232_BAD=0 of 26`** (E1 · A1 · A4 · O1 · S1 · S2 · S3 · K2 · V5 · D1 · M2 · F2 · F1 · R1 · R6 · X1 · X5 · L1 · C1 · C2 · C8 · C4 · C7 · P1 · Y1 · Q4) |
| before readings | `READINGS_OWN_EXIT=0` (12:54:48, `db/scripts/2026-09-28-overtime1-readings.sql`) |
| dry run of the migration on live (`COMMIT` → probe + `ROLLBACK`) | `DRY_OWN_EXIT=0`; probe: 2 codes, grants `admin:approve admin:enter finance:enter warehouse:approve`, 0 flagged, table and `decide_overtime_batch` present; every proof assertion passed; 9 pending documents each with a decider |
| 2 · backup (detached, `nohup`) | **`BACKUP_EXIT=0`** — `evoltrya-backup-2026-09-28-1257.dump` (5.1 MB, TOC 6,604; previous 6,600, floor 5,940), done 13:18 (≈ 21 min; `pg_stat_activity` showed the dump's COPY in progress at 17 min) |
| 3 · `db/apply_migration.sh` | **`APPLY_OWN_EXIT=0`**; preflight: 22 `CREATE FUNCTION` — 5 replaced · 17 new (16 + the proof's `pg_temp` helper); 1 column added on a masked table; every proof assertion passed. **Window start 13:22:35 CST** |
| 4 · types | the Homebrew Supabase CLI is killed on launch (invalid code signature, §1); with an ad-hoc-signed scratch copy first on `PATH`: **`TYPES_OWN_EXIT=0`** (+286 lines), byte-identical to a second generation |
| 5 · `npx tsc --noEmit` | **`TSC_OWN_EXIT=0`** (first run, and again after the date-control change) |
| 6 · `npm run build` | run 1 `BUILD_EXIT=1` — the deep-route list was stale (regenerated, `lib/deepRoutes.generated.ts`); run 2 `BUILD_EXIT=1` — a new `auth.getUser()` that ignored its error (now handled: no hint when unknown); run 3 `BUILD_EXIT=1` — two new native date controls (135 → 137, may only fall) and a hand-rolled date formatter (both replaced by server-built dropdowns from `lib/dates`); run 4 **`BUILD_EXIT=0`**; no tracked file regenerated |
| 7 · `db/gate.py` (full, detached, signed CLI on `PATH`) | **`GATE_EXIT=0`** (496 s) — rebuild ✓ · mirrors vs live ✓ (structure, seeds, bootstrap, self-consistency, definer) · generated types ✓ · fixtures ✓ (235, incl. 232 and 141) · anonymous surface ✓ (baseline 327) |
| 8 · `node scripts/check-i18n.mjs` | **`I18N_OWN_EXIT=0`** |
| 9 · `node scripts/check-error-swallowing.mjs` | **`SWALLOW_OWN_EXIT=0`** (0 new) |
| 10 · smoke (detached) | **`SMOKE_EXIT=0`** — **257 ok, 8 skipped (no data), 0 failed** (239 routes + probes; 231 timed, 1,491.9 s, median 6,168 ms). `/hr/overtime` passed its content check (the empty-state marker `data-overtime-state="no-site-staff"`); `/hr/overtime/[id]` skipped — no batches on live (registered in `EXPECTED_SKIPS`). **Clean-up read back** as `postgres`, base tables, 14:35:14: `.ephemeral/` 0 plans; `auth.users` 7 (0 `smoke-%`); `roles` 13 (0 `probe-%` / `fixture-%`); unrevoked `user_roles` 7; `ZZ-SMOKE%` employees 0; overtime batches / lines 0; flagged 0; attendance periods 0. The scratch report listed 6 **pre-existing** ZZ-SMOKE rows (622–1,265 h old, 5 still referenced) — report-only, not this run's |
| 11 · live proof | **`PROOF_OWN_EXIT=0`** on the second run (§3). The first run stopped by name at cell 2 (`PROOF_OWN_EXIT=3`, nothing committed): it used 2026-08, and **EMP-2026-0005 was hired 2026-09-01**, so `create_overtime_batch` rightly refused `OVERTIME_NO_SITE_STAFF|2026-08`. The expectation was wrong, not the rule; the proof now uses 2026-09 |
| after the full gate | only `db/scripts/…-live-proof.sql` and docs changed; the gate check that reads `db/` text was re-run on the final tree: **`CCY_OWN_EXIT=0`**. Neither `next build` nor the full gate reads those files otherwise |

## §3 · Live proof and the before / after readings

Script `db/scripts/2026-09-28-overtime1-live-proof.sql`, one transaction, `ROLLBACK` at the end — **nothing was left on live**
(`PROOF_OWN_EXIT=0`, rolled back 2026-09-28 14:37:19 CST). Connection `postgres` (`rolbypassrls = t`); each cell switches to the real
account's JWT under `authenticated` and first asserts `auth.uid()` and `current_user`.

| cell | who | what | result |
|---|---|---|---|
| P0 | postgres | preconditions | approvals on · 0 flagged · 0 batches · no 2026-09 attendance |
| P1 | chooer@ | the empty state | `overtime_site_staff()` **0 rows**; create → **`OVERTIME_NO_SITE_STAFF\|2026-09`** |
| 1 | postgres | flag EMP-2026-0005 (Phua) as site staff, inside the transaction | chooer@ now reads exactly EMP-2026-0005 |
| 2 | chooer@ (finance) | create, 4 lines, submit | fusheng@ cannot create (`PERMISSION_DENIED\|action.overtime_enter`); **OT 2026-09 #1** with 09-06 = rest day, 09-07 · 09-08 = weekday, 09-13 = rest day; duplicate 09-08 → `OVERTIME_DUPLICATE_DAY\|EMP-2026-0005\|2026-09-08\|OT 2026-09 #1`; Fu Sheng → `OVERTIME_NOT_SITE_STAFF\|EMP-2026-0006`; 09-30 → `OVERTIME_DATE_FUTURE`; submitted → the pending registry lists `overtime_batch:OT 2026-09 #1:false`; fusheng@ reads the 4 lines through `overtime_batch_lines()` |
| 3 | fusheng@ (warehouse) | approve | chooer@ and tim@ → `PERMISSION_DENIED\|action.overtime_approve` (no CFO override); **fusheng@ approves**; `approval_log`: `submitted/-/false approved/-/false` |
| 4 | chooer@ | complete 2026-09 attendance | the sheet refuses typed hours (`ATTENDANCE_OT_THROUGH_OVERTIME\|EMP-2026-0005`); before completion `overtime_month_hours` = **live 11.25**; completed; **fixed into Phua's line 4.25 / 7.00 / 0 (weekday / rest / PH)**; **sheet total 11.25 = approved lines total 11.25** (two separate sums); after completion **fixed 11.25**; the month now refuses a new batch and a reversal (`OVERTIME_MONTH_COMPLETE\|ATT-2026-09\|2026-09`); phua@ reads his 4 approved lines on `/me`'s reader, **"by Fu Sheng"** |
| 5 | tim@ (cfo) | Q20 — decides his own expense claim | submits a claim for EMP-2026-0002 and rejects it himself → **`approval_log.self_decided = true`** and **`my_document_decisions()` → `self_decided = true`, decider "Tim"** — what `/me` renders as "Decided by you (flagged)" |
| K | postgres | end of transaction | journal entries 82 → 82; `approval_log` 14 → 17 inside the transaction (2 overtime + 1 claim), all rolled back |

**Before and after readings** — `db/scripts/2026-09-28-overtime1-readings.sql` (part 1 as `postgres`, base tables, `relkind` printed;
part 2 as tim@ on views; part 3 each account as itself). Before at 12:54:48 (before the backup), after at 14:37:40 (after the migration,
the smoke and the proof); `READINGS_OWN_EXIT=0` both times. Diffed:
- **identical:** approvals on (L1 finance, L2 cfo, 1000, locked before 2026-08-01, system start 2026-08-01); employees 7 live, same
  md5; attendance periods 0, lines 0; `approval_log` 14 (overtime 0); journal entries 82, lines 184, Σ debits 1,636,102.89; balances
  1000 −127,593.48 · 1100 43,002.12 · 1200 61,387.92 · 1400 18.00 · 2000 −376,404.42 · 2100 −102.87; every other role's code count and
  md5; 7 unrevoked grants; 7 `auth.users`; pending registry = 1 expense claim (1,000.00, `blocks_disable` 0); as tim@: AP list
  416,988.32 / ledger 376,404.42, AR list 57,545.87 / ledger 43,002.12, **unexplained 0.00 on both sides**.
- **changed, as intended:** `overtime_batches` / `overtime_lines` absent → **0 rows**; `is_site_staff` absent → **0 flagged**; the
  `approval_log` subject check gains `overtime_batch`; the five replaced functions' md5s changed (DEFINER and ACL unchanged); the 16 new
  functions present (12 DEFINER, `authenticated` yes, `anon` no; the three internal ones `authenticated` no); catalogue 69 → 71;
  `admin` 68 → 70, `finance` 39 → 40, `warehouse` 26 → 27 (the four grants, nothing else).
- **changed, NOT by this cut:** a new pending leave request **LV-2026-0006** — created at 14:20:45 CST by **fusheng@'s own account**
  through the app (annual leave 2026-10-02, "Personal leave, out of town."), while the smoke was running. It is a colleague using live,
  not a row this cut wrote; left untouched. Its deciders (`action.decide_hr_requests`, not its own party) are chooer@, tim@ and admin@.
  (LV-2026-0004 / 0005 were likewise created by chooer@ at 12:02 / 12:06, before the first reading.)

## §4 · Who can do what now (approvals on)

- **Finance (chooer@) and admin@** — `action.overtime_enter`: start a month's batch, add / remove lines (site staff only, one line per
  person per day, a date in that month, employed that day), submit, withdraw, discard, reverse an approved batch while the month is
  open. **Mark an employee as site staff** on the create / edit forms (`module.hr.edit`, unchanged).
- **Warehouse (fusheng@) and admin@** — `action.overtime_approve`: approve or reject (with a note) a whole submitted batch, reached from
  **Operations → Overtime** (warehouse has no `module.hr.view`). **Refused:** a batch they submitted (`|raiser`) or one containing their
  own overtime (`|subject`), by person. The approvals switch does not matter.
- **CFO (tim@)** — reads `/hr/overtime` (holds `module.hr.view`); **no** approve code and no override.
- **HR readers (`module.hr.view`)** — read batches, lines, the attendance sheet's approved hours and the payroll page's hours column.
- **Every site employee with an account** — "My overtime" on `/me`. None exist on live.
- **Newly refused for everyone:** typing overtime hours into the attendance sheet (`ATTENDANCE_OT_THROUGH_OVERTIME`); completing a
  month's attendance while it has an open overtime batch.
- **Nothing left pending by this cut; every pending document still has a decider who is not its own party** (the migration printed
  each: CLM-2026-0004 → tim@; LV-2026-0004 / 0005 → admin@, tim@; MC-2026-0001 (pay) → admin@, chooer@; ST-2026-0082…0086 → chooer@). One pending document appeared later and is not this cut's: **LV-2026-0006** (Fu Sheng's own leave, raised by fusheng@ at 14:20:45) — decidable by the holders of `action.decide_hr_requests` (roles admin · cfo · finance → admin@, tim@, chooer@; read from `role_permissions` in the after readings), none of whom is its own party.

## §5 · Findings closed and registered

- **Closed:** "overtime rate is an open legal question" (ATTEND-1) — ruled by Tim (Q1 · Q2): hours only, the rate stays with the
  provider; struck with a closing note. EMP-SELF-1's open broken window (§W).
- **Updated:** `C-2-OT` — the day-type rule now exists (Sunday for everyone); per-person rest days deferred (Q4).
- **Registered:** `OVERTIME1-NO-REMINDER-ARM` (no "a batch is waiting for you" reminder) · `OVERTIME1-ME-ATTENDANCE-READS-FROZEN-ONLY`
  (`/me`'s attendance panel reads only frozen hours; "My overtime" on the same page is complete).
- **Queue:** items 18 and 19 in Tim's words; item 20 done; the two old overtime-rate rows annotated in place.

## §6 · Page list — every new or changed route, with its file

| route | what changed | file(s) |
|---|---|---|
| `/hr/overtime` | **new** — batch register, "New batch", the empty state | `app/hr/overtime/page.tsx` · `NewBatchForm.tsx` · `BatchesTable.tsx` · `actions.ts` |
| `/hr/overtime/[id]` | **new** — lines, add / remove, submit, withdraw, discard, approve / reject, reverse | `app/hr/overtime/[id]/page.tsx` · `[id]/BatchDetail.tsx` · `app/hr/overtime/actions.ts` |
| HR menu · Operations menu | **new** entry "Overtime" (both modules) | `lib/modules.ts` (`FN.overtime`) |
| `/hr/employees/new` | "Site staff" checkbox | `app/hr/employees/EmployeeForm.tsx` · `app/hr/employees/actions.ts` |
| `/hr/employees/[id]/edit` | "Site staff" checkbox | same |
| `/hr/employees/[id]` | shows "Site staff" | `app/hr/employees/[id]/page.tsx` |
| `/hr/attendance/[id]` | overtime columns read-only, approved hours; the save records no hours | `app/hr/attendance/[id]/page.tsx` · `[id]/AttendanceGrid.tsx` · `app/hr/attendance/actions.ts` |
| `/hr/payroll/[id]` | read-only "Approved OT hours" column | `app/hr/payroll/[id]/page.tsx` · `[id]/PayrollLinesTable.tsx` |
| `/me` | "My overtime" panel; expense Withdraw disabled-with-reason on approved claims | `app/me/page.tsx` · `app/me/MyOvertimePanel.tsx` · `app/me/MyExpenseClaimsPanel.tsx` |
| avatar menu (every page) | "My profile" / 「我的档案」; two rows removed | `app/components/nav/AvatarMenu.tsx` |
| error copy (every HR screen) | 27 new refusal codes, en + zh | `app/hr/hrErrorCodes.ts` · `messages/en.ts` · `messages/zh.ts` |

## §7 · The broken window — started, end PENDING

**Start: 2026-09-28 13:22:35 CST** (`db/apply_migration.sh`'s own "the database is new" line, also in `db/migration-windows.tsv`;
its "applied at" line reads 13:19:38). **End: PENDING — Tim reads it from Vercel.**

What the old app does against the new database (approvals ON):
- **Attendance sheet:** the old grid sends its three typed hour fields to `record_attendance`. Zeros work exactly as before; any
  non-zero value is now refused `ATTENDANCE_OT_THROUGH_OVERTIME` — the old copy has no sentence for it, so it shows the generic text.
  **No live impact:** there are 0 attendance periods on live, so nobody reaches that grid without opening a month first.
- **Completing attendance:** the new checks (open overtime batch; freeze approved hours; totals equal) all pass trivially — there are
  no batches — so completion behaves as before.
- **Employee create / edit:** the old forms do not send `is_site_staff`; a new employee gets the default (false) and an edit leaves
  the column untouched. Nothing breaks.
- **Overtime:** the old app has no overtime screens; the new functions and tables exist but nothing calls them. The approval
  registry, the switch guard and the log gain an `overtime_batch` branch with no rows behind it.
- **Unchanged:** everything else — `/me`, the avatar menu (still the EMP-SELF-1 rows until the deploy), payroll, every decision screen,
  the switch, everything pending.

## §8 · Commit, push, three SHAs

Reported in the hand-back message: `HEAD`, `origin/main` and `git ls-remote origin main` as full 40-character SHAs (a commit cannot
carry its own hash). Deployment is Tim's to read; the window's end stays PENDING until he does.
