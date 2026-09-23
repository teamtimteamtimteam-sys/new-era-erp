# ROLE-1 · Batch 1 — Tim's role and approval matrix: the keys that change hands without a new lifecycle (2026-09-23)

**Opening gate:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `f2ae12ae36d63202f15ae6c863a5d79619ad8cd2`
(ROLE-MATRIX-0). **Approvals were ON and stayed ON.**

The matrix, as Tim's ruling, is `docs/role-matrix.md` — every line marked ✅ done, B2–B5, or [LC].
Batches 2–5 and the [LC] queue: `docs/forward-queue.md` § ROLE-1. Approvals effects: `docs/approvals.md` §3i.

---

## §0 · Step 0 (grilling) and Tim's answers

Step 0 was handed back before any build. What grilling changed:
1. It does not fit one session → **five batches** (Q13); this cut is Batch 1.
2. Choo Er's two pending leave requests would have had **no decider** unless the CFO could decide HR requests (Q4 → yes).
3. Choo Er's reviewer is Tim (`employees.manager_id`), so the CFO **submits** her review → review approval goes to cco when
   the CFO is the submitter **or** the subject (Q5).
4. Refusing direct salary writes with all six salaries NULL would have left **no way to set a first salary** (Q7).
5. `data.view_prices` masks **sales** prices too; `data.view_sales` is dead → warehouse purchase-price visibility needs a new code (Q9, Batch 4).
6. Month reopen had a **side door** (the settings lock form moving `locked_before` backwards) — closed here.
7. "CTO keeps assay; other writes move" vs "lower-consequence: status quo" → only main-table actions move, through dedicated codes (Q2).

**Tim accepted all thirteen recommendations** (Q1–Q13, recorded in `docs/role-matrix.md` where each applies).

---

## §1 · What shipped

**Migration** `db/migrations/2026-09-23-role1a-the-matrix-batch-1.sql` (one transaction; its own proof block rolls everything
back if any held role's code list differs from the ruling, if approvals are off, if a pending document changed, if
`approval_log` changed, or if any pending document has no decider).

| | change |
|---|---|
| new codes | `action.finance_reopen` · `action.approve_review` · `action.decide_hr_requests` · `action.hr_reviews` · `action.anonymise_employee`; `module.hr.edit` re-described (no longer reviews/KPI) |
| finance | `reopen_period` · `close_financial_year` · `reopen_financial_year` → `action.finance_reopen`; **new guard `guard_lock_reopen_path`**: a direct write that moves `locked_before` back past the latest live month close (or clears it) → `REOPEN_THROUGH_CLOSE_ONLY|<date>`; undoing a manual lock that crosses no close is still allowed. `allocate_processing_costs` → `module.finance.edit`; `release_purchase_order_retention` → `module.finance.edit` |
| HR | 10 review/KPI functions + 6 review/KPI tables (17 policies, 6 write triggers) → `action.hr_reviews`; `approve_review` gates on `review_approval_code()` (new, the single definition); `decide_leave_request` / `decide_medical_claim` → `action.decide_hr_requests`; `anonymise_employee` → `action.anonymise_employee` |
| R2 | `self_approval_exception` + `approval_log_self_decided_scope` + `self_approved_decisions()` cover the CFO's own **leave** |
| salary | `guard_employee_salary_write` (direct INSERT with a salary / UPDATE that changes it → `SALARY_DIRECT_WRITE_REFUSED`); `guard_employment_history_salary_write` (direct salary-history rows refused); **`set_initial_salary`** (finance: `module.hr.edit` + `data.view_pay`, NULL → value once, writes a `salary_change` history row); `master_import_forbidden_columns` gains `monthly_salary` |
| lookup | `employee_lookup` also admits `action.manage_permissions` (names only) — `/settings/accounts` must still list people to link |
| grants | admin → 3 system codes · cco −`manage_permissions` −`bulk_import` −`hr.edit` −`view_identity` +`hr_reviews` · cto −`bulk_import` −`issue_cod` −`view_identity` · finance −`bulk_import` +`hr.edit` +`view_identity` +`decide_hr_requests` · cfo +`finance_reopen` +`approve_review` +`decide_hr_requests` +`hr.view` +`view_reviews` +`suppliers.view` +`customers.view` +`view_banking` |
| comment only | `batch_freight_base`: its in-body note said allocation's caller "must hold processing.edit" — now false; the load-bearing whitelist entry is `finance.view` |

**Screens** (DBLOCK-1: visible, disabled, naming the code):
- The month-close page: close stays on `module.finance.edit`; reopen and year close/reopen are now on `action.finance_reopen`.
- The cost-allocation button had **no gate at all**; it is now gated on `module.finance.edit`.
- The PO retention release is now gated on `module.finance.edit`.
- The review and KPI screens are gated on `action.hr_reviews`. The approve button asks `review_approval_code` which code applies.
- The leave and medical decide buttons had no gate; they are now gated on `action.decide_hr_requests`.
- The employee page has a **Monthly salary** block: the figure with a note that changes go through a review; «受限» when the viewer cannot see pay; or, when no salary is set, the first-salary form behind two gates (`data.view_pay`, then `module.hr.edit`).
- `/settings/accounts` reads `employee_lookup` instead of `employees`.
- The self-approved report links leave rows. Its explanation no longer says leave is never covered.
- New error copy in English and Chinese: `REOPEN_THROUGH_CLOSE_ONLY` and the salary refusals.

**Fixtures:**
- New: `209` (arms A–G). It includes a fault injection: with the salary guard disabled, the same direct UPDATE succeeds.
- Updated because they encoded the old codes: 32, 34, 54, 146, 163, 203, 205, 206, 127.
- **Two of those updates reverse a rule, not a code name:**
  - **127 A5** used to assert "moving the lock back is free". It now asserts the named refusal plus the route through `reopen_period`.
  - **205 R2e/R2g** used to assert "leave is never covered". R2e now asserts the CFO's own leave is allowed and flagged. R2e′ (new) asserts a non-CFO decider is still refused on their own leave. R2g moved to `performance_review`.
- **163 D was re-aimed.** The injection now removes the whitelist entry that is load-bearing today (`finance.view`), not the old `processing.edit`.

**Decisions made during the build, not asked (say so if any is wrong):**
- **First-salary "effective date" is a month picker (`<select>`), not a date box.** `check-date-format` forbids any new
  native `<input type="date|month">` (138 → 139 failed the build). Payroll is monthly and the posted-period check is by month;
  the date sent is the 1st of the chosen month. I did not work around the ratchet with a wrapper component.
- **The lock guard's line is "don't cross a formally closed month"**, not "never move the lock back": finance can still undo
  its own manual lock (the matrix gives period lock to finance).
- **The smoke's disposable session no longer borrows `admin`.** After Q8 that session would walk all 218 routes as a
  restricted reader and still exit 0. It now makes a disposable all-codes role (`probe-smoke-all-<stamp>`, like fixtures'
  `r_all`) — deliberately **not** `finance`/`cfo`, which are approval roles and would make the scratch account a real approver.
- **Unheld roles** (`hr`, `procurement`, `sales`, `auditor`, `employee`) were not touched. The `hr` role therefore lost reviews and
  leave/medical decisions — recorded as `ROLE1-UNHELD-HR-ROLE-LOST-REVIEWS`.
- **`data.view_identity` removed from cto too** (Q6 said "finance only"; cto held it without `hr.view`).
- Bootstrap (`db/tables/role_permissions.sql`, runtime config): `admin` → the three codes; `finance` takes HR. **Still correct
  in meaning**; `cfo`/`cco`/`cto` remain absent (`ROLE1-BOOTSTRAP-MISSING-ROLES`).

---

## §2 · Verification — every figure is the script's own exit line

| step | result |
|---|---|
| `db/gate.py --offline` (last run before migrating) | `GATE_EXIT=0` |
| backup | `BACKUP_EXIT=0` — `evoltrya-backup-2026-09-23-1932.dump`, TOC 5984 (floor 5385) |
| dry run on live (migration with `ROLLBACK`) | clean, twice |
| `db/apply_migration.sh` | `APPLY_EXIT=0` · pre-flight: 30 CREATE FUNCTION (23 replace · 7 new), 12 account codes all `is_system` · **window start 2026-09-23 19:44:46 CST** |
| `NOTIFY pgrst` + `npm run types:gen` | regenerated file == the hand-written entries (3 functions) |
| `npx tsc --noEmit` | `TSC_EXIT=0` |
| `npm run build` | `BUILD_EXIT=0` |
| `db/gate.py` (full) | `GATE_EXIT=0` — mirrors vs live ✓ (permissions seed 46/46, drift 0) · fixtures ✓ · anon surface ✓ |
| `node scripts/check-i18n.mjs` | `I18N_EXIT=0` |
| `node scripts/check-error-swallowing.mjs` | `SWALLOW_EXIT=0` |
| smoke, run 1 (detached) | `SMOKE_EXIT=1` — **aborted in its own setup, before any route**: its disposable session used the `admin` role, which after Q8 cannot run `open_probation_review` (`PERMISSION_DENIED|action.hr_reviews`). Not a route failure; it left 2 disposable accounts (one with an `admin` grant) whose cleanup plan stayed on disk |
| smoke, run 2 (detached, after the fix in §1) | `SMOKE_EXIT=0` — 226 routes timed; it **reaped run 1's plan first** (pid 55911, 4 steps) |
| leftover disposable rows after run 2 | as `postgres`, base tables: `smoke-%` accounts **0** · `probe-%`/`fixture-%` roles **0** · grants to missing accounts **0** · `.ephemeral/` plans **0** · each held role has exactly its one real holder |

---

## §3 · Live proof — refusals and read-backs only, one transaction, `ROLLBACK`

**Identity:** connected as `postgres` (`rolbypassrls = t`); each cell sets `request.jwt.claims` to a real account and runs
under `SET LOCAL ROLE authenticated`. Script: `db/scripts/2026-09-23-role1-live-proof.sql` → `PROOF_EXIT=0`,
**17 of 17 cells**:

| account | cell | result |
|---|---|---|
| sandra@ | `set_user_roles` | `PERMISSION_DENIED|action.manage_permissions` |
| sandra@ | decide LV-2026-0001 | `PERMISSION_DENIED|action.decide_hr_requests` |
| sandra@ | `allocate_processing_costs` | `PERMISSION_DENIED|module.finance.edit` |
| sandra@ | `master_import_apply` | `PERMISSION_DENIED|action.bulk_import` |
| sandra@ | control: `void_review` | passes the gate → `REVIEW_NOT_FOUND` |
| chooer@ | `reopen_period(2026-07-31)` | `PERMISSION_DENIED|action.finance_reopen` |
| chooer@ | direct `UPDATE finance_settings SET locked_before = NULL` | `REOPEN_THROUGH_CLOSE_ONLY|2026-07-31` |
| chooer@ | decide her own LV-2026-0001 | `SELF_APPROVAL_FORBIDDEN|raiser` |
| chooer@ | direct `UPDATE employees SET monthly_salary` | `SALARY_DIRECT_WRITE_REFUSED` |
| chooer@ | control: decide leave | passes the gate → `REQUEST_NOT_FOUND` |
| tim@ | control: decide leave | passes the gate → `REQUEST_NOT_FOUND` |
| tim@ | control: `reopen_period(2026-06-30)` | passes the gate → `CLOSE_NOT_FOUND` |
| tim@ | `create_purchase_order` | `PERMISSION_DENIED|module.purchasing.edit` (the approver still cannot raise) |
| admin@ | decide leave | `PERMISSION_DENIED|action.decide_hr_requests` |
| admin@ | `reverse_payment` | `PERMISSION_DENIED|module.finance.edit` |
| admin@ | control: `anonymise_employee` | passes the gate → `PDPA_REASON_REQUIRED` |
| phua@ | `master_import_apply` | `PERMISSION_DENIED|action.bulk_import` |

Read-backs, same session, as `authenticated`:
- admin@ reads **7** rows from `employee_lookup`, so account linking still works.
- admin@ reads **0** rows from `invoices_masked`; chooer@, the same-session control, reads **9**.
- `current_user_permissions()` per real account:
  - admin@ has 3 codes.
  - tim@ has 13 codes.
  - Choo Er, Sandra, Phua, Fu Sheng and Vince: exactly the ruling (full lists in the script output).

### Before / after — as `postgres`, `rolbypassrls = t`, base tables

| reading | before (19:30 CST) | after (19:56 CST) |
|---|---|---|
| `approvals_enabled` / l1 / l2 / threshold | t / finance / cfo / 1000 | **t / finance / cfo / 1000** |
| pending: expense claims · leave · medical submitted · medical approved-unpaid · reviews · work orders · stocktakes · POs | 1 · 2 · 0 · 1 · 0 · 0 · 5 · 0 | **1 · 2 · 0 · 1 · 0 · 0 · 5 · 0** |
| `approval_log` rows | 14 | **14** |
| codes per role: admin · cco · cfo · cto · finance · gm · warehouse | 40 · 37 · 5 · 34 · 32 · 20 · 12 | **3 · 34 · 13 · 31 · 34 · 20 · 12** |
| unheld roles: auditor · employee · hr · procurement · sales | 19 · 0 · 7 · 15 · 16 | unchanged |

**The nine pending items — deciders by person, before → after** (`approval_deciders` for the tiered chain; the same parts
against each decision function's real gate for the rest):

| item | before | after |
|---|---|---|
| CLM-2026-0004 (Choo Er's own, SGD 1,000 → L2) | tim@ | tim@ |
| LV-2026-0001, LV-2026-0003 (Choo Er's own leave) | admin@, sandra@ | **tim@** |
| MC-2026-0001 (approved, payment) | admin@, chooer@ | chooer@ |
| ST-2026-0082 … 0086 (raised by admin@) | chooer@, fusheng@, phua@, sandra@ | the same |

**No pending document is left without a decider.** The migration asserted the same inside its own transaction.

---

## §4 · Everything each person can no longer do (as built in Batch 1)

- **Tim, as admin@:**
  - Loses every business action: finance, HR decisions, stocktake posting, work-order release, POs, receipts, COD.
  - Loses all business reading: finance, HR, inventory, sales, deleted records, the self-approved report. **Tim reads and decides as tim@.**
  - Keeps: permissions, accounts, roles, account links, the approvals switch and policy, bulk import, anonymisation.
- **Tim, as tim@:** loses nothing. **Gains:**
  - reopen month, year close and reopen year;
  - approve reviews, except his own and those he submitted;
  - decide any leave or medical claim, and his own flagged;
  - reading HR (not identity numbers), reviews, suppliers, customers and bank details.
  - ⚠ tim@ still cannot read inventory, inbound, output, processing, sales orders, stocktakes, materials, pricing or tasks. admin@ used to read them all. **Business reading through tim@ is therefore narrower than it was through admin@.** Q3 limited the CFO's new read codes to what its decisions need. Say if you want more.
- **Sandra (cco):**
  - Loses: roles, accounts, the approvals switch and policy, greetings and doodles (`manage_permissions`), bulk import.
  - Loses all non-review HR: employee records, payroll periods, posting and unposting, payroll payments, attendance, leave types, holidays, departments, training.
  - Loses leave and medical decisions, identity numbers, and cost allocation.
  - Loses review approval, except when Tim is the submitter or subject.
  - Keeps: running reviews and KPI, and everything outside the main table.
- **Phua (cto):** loses bulk import, COD, identity numbers and cost allocation.
- **Choo Er (finance):** loses bulk import. **Gains** non-review HR and payroll, leave and medical decisions, identity numbers, first salary, cost allocation and PO retention release.
- **Fu Sheng, Vince:** no change.

---

## §5 · The broken window — started, end PENDING

**Start: 2026-09-23 19:44:46 CST** (`db/apply_migration.sh`'s own line; also in `db/migration-windows.tsv`).
**End: PENDING — Tim reads it from Vercel.**

What is broken while production runs the old app against the new database (approvals ON):
- **cco cannot run reviews or KPI on screen.** The old pages gate on `module.hr.edit`, which she no longer holds, so the controls show disabled although the database would accept her.
- **Review approval is unreachable on screen for everyone.** The old approve button gates on `module.hr.edit`, which only finance now holds, and the database refuses finance (`action.approve_review`). **0 reviews are submitted on live, so nothing waits on it.**
- **`/settings/accounts` shows only Tim's own employee in the linking list for admin@.** The old page reads `employees`, which now needs `hr.view`. The list goes short silently.
- **Controls that are pressable but refused by name** (the database still says no):
  - finance on month reopen and year close;
  - cco and cto on cost allocation;
  - cco on PO retention release;
  - cco on the leave and medical decide buttons, which had no gate.
- **Pending approvals still work:** tim@ can open Choo Er's two leave requests and decide them (the old decide buttons have no gate, and tim@ now has `hr.view`). CLM-2026-0004 is unaffected.

---

## §6 · Commit, push, three SHAs

Reported in the hand-back message: `HEAD`, `origin/main` and `git ls-remote origin main` as full 40-character SHAs
(a commit cannot carry its own hash). Deployment is Tim's to read; the window's end stays PENDING until he does.
