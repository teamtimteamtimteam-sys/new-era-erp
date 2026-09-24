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

> **Q8 reversed by Tim himself — 2026-09-23 23:33:27 CST** (recorded by AP-RECON-0).
> - Signed in as admin@, Tim restored **all 45 codes** to the `admin` role.
> - Re-read as `postgres` from base table `role_permissions`: 45 rows, every `created_at` at 23:33:27.
> - Claude recommended going back to system administration only:
>   - admin@ and tim@ are one person, so a request raised on admin@ cannot be approved on tim@;
>   - a compromised admin password now carries every power.
> - **Tim has not ruled on reverting. The role stays as it is and is not raised again unless Tim raises it.**

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

---

# Batch 2 — Step 0 done, build split in two (2026-09-23, with PAY-REQ-1 Batch B)

Batch 2 was grilled in the same Step 0 as PAY-REQ-1 Batch B. **Tim accepted all sixteen recommendations** (Q1–Q16; Q1–Q4
and Q16 belong to Batch B, see `docs/handbacks/PAY-REQ-1.md` § Batch B). **Nothing in Batch 2 was built in that session.**
The build is split (Q1): **Batch 2a** next session, **Batch 2b** the one after — `docs/forward-queue.md` § ROLE-1.

## What grilling found (read from the code; live figures read as `postgres`, `rolbypassrls = t`, from base tables unless named)
1. **The CFO holds no `.edit` code.** So, for the three CFO-only splits, changing which code a gate checks is not enough —
   row-level security would still refuse the CFO. Each needs its own function plus a column guard.
2. **Tables that mix a moving part with a staying part:**
   * `finance_settings`: the lock stays with finance; the approval columns are already admin-only.
   * `customers`: only the credit columns move.
   * `suppliers`: the status moves are split.
   * inbound/output metal content: manual entry stays; assay application moves.
3. **The creator-may-not-approve rule has three holes today:**
   * a direct INSERT can set `created_by` to anyone;
   * a direct UPDATE can rewrite `created_by` or set it to NULL;
   * a direct INSERT can create an `approved` or `active` supplier, because the transition trigger skips inserts.
4. **Applying an assay reprices the batch and posts to 2000** (`apply_assay_result` → `reprice_inbound_batch`, a
   journal entry dated today). The nested check inside `reprice_inbound_batch` looks at the caller, so it collides with Batch 4.
5. **Found in passing; registered in `docs/known-issues.md`, not fixed:**
   * `PAYREQB-COMPANY-ASSETS-BUCKET-UNGATED`
   * `PAYREQB-FORMULA-PAGES-NO-DISABLED-GATE`
   * `PAYREQB-SALES-RECORDS-FINANCE-INSERT`
   * `PAYREQB-AP-VIEW-DISAGREES-WITH-GL-2000`, which Tim wants surveyed read-only straight after Batch B.

## The unapproved-supplier rule on live (read at Step 0, 2026-09-23 ~23:05 CST)
* **Suppliers:** 8 live `draft`, 1 live `approved` (SUP-2026-0003), 0 live `active`; 4 deleted `draft`, 4 deleted `active`.
  Query: `select status, count(*) filter (where deleted_at is null) … from suppliers group by status`.
* **Payments:** all 9 outgoing supplier payments went to `draft` suppliers (6 posted, SGD 153,970.68).
* **What stops being payable** (read from `ap_open_items`, a view, as tim@ under `SET LOCAL ROLE authenticated`):
  10 open items, 377,164.50 in total, across three drafts:
  * SUP-0002 Acme — 97,063.52
  * SUP-0095 Bosch — 280,000.00
  * SUP-0445 Ever Higher — 100.00
* **Open POs to draft suppliers:** PO-0002 and PO-0005 (receiving), PO-0007 and PO-0011 (confirmed).
* **Who can approve them:** 7 of the 8 live drafts have `created_by = NULL`, and SUP-0445 was created by chooer@, so tim@
  can approve all of them.

## Tim's answers (all as recommended)
* **Q5.** Payable means `approved` or `active`, and not deleted. The check runs at submit, approve and pay; payment reversals
  are exempt.
* **Q6.** The migration approves nobody. After the deploy, Choo Er submits the three suppliers and Tim approves them. Until
  then, 377,164.50 cannot be paid, and the Batch 2a report says so in its window section.
* **Q7.** New POs to an unapproved supplier are refused. Open POs keep receiving, and receipts and expenses are not refused.
* **Q8.** The CFO owns `→ approved`, `→ rejected`, `→ blacklisted`, and `blacklisted → archived` (the "restore").
  `suppliers.edit` owns every other move. `created_by` is immutable, a direct INSERT must be `draft`, and the rule compares
  people, not accounts.
* **Q9.** Supplier approval is not an approval-engine chain: it gets an `approved_by/at` stamp, an `operations_now` entry,
  and `supplier` in `approval_log`.
* **Q10.** The code is named `action.finance_settings`. `set_finance_settings` plus a column guard;
  `accounts` / `currencies` / `company_profile` swap their policy and trigger; the bucket gets gated; no new screens.
* **Q11.** `set_customer_credit` plus a column guard. The edit form stops sending the credit fields, and bulk import can no
  longer set them.
* **Q12.** Linking a document to a contract is not "contract terms".
* **Q13.** `metal_price_indices` goes with metal prices (finance). `pricing.edit` goes to cco only, and the formula pages get
  their gate.
* **Q14.** `action.direct_sale` (cco). The `sales_records` INSERT is closed if the build confirms nothing legitimate writes there.
* **Q15.** **Tim confirms cto applies assays, knowing it reprices and posts to the supplier payable.** Applying and
  unapplying (inbound and output, previews included) move to cto; recording a lab result stays where it is.

---

# Batch 2a — CFO-only finance settings, customer credit and supplier approval; no payment or new PO to an unapproved supplier (2026-09-24)

**Opening gate:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `3397eb894df5d267ea20f1a329440bada514ce1d` (CLAIM-GST-1).
**Approvals were ON and stayed ON.** Every figure below is a script's own exit line or a query named with its identity.

## ★ In plain words: what cannot be paid right now, and what unlocks it

**Until the CFO approves them, three suppliers cannot be paid.** Their open payables total **377,173.50 SGD**:
- **Acme** (SUP-2026-0002): 97,064.50
- **Bosch** (SUP-2026-0095): 280,000.00
- **Ever Higher** (SUP-2026-0445): 109.00

A fourth **500.00** belongs to the **deleted** supplier ZZ1B-GDS (`ZZ-PROCCOST1-DEMO`). It can never be paid; see `docs/known-wrong-until-cutover.md`.

- **Total unpayable today: 377,673.50 SGD.** Read as tim@ from the view `ap_open_items`, grouped by supplier status, at 18:31 and 19:14 CST. The query is in `db/scripts/2026-09-24-role1b2a-readings.sql`, part 2.
- The brief said "about 377,164.50". That figure came from Batch 2 Step 0 (2026-09-23 23:05). Re-measured today, Acme reads 97,064.50 and Ever Higher 109.00.
- **No payment request was in flight**, so nothing already raised is stuck: `payment_requests` has 0 rows (base table, `postgres`).
- **New POs** to Acme and Bosch are also refused until they are approved.
- **Receiving against open POs is not affected**: PO-2026-0002/0005 (Acme) and PO-0007/0011 (Bosch).

### After the deploy — Tim and Choo Er, step by step
1. **Choo Er** (chooer@) opens **Suppliers → SUP-2026-0002 Acme**. In the status panel she presses **Submit for Review**. She does the same for **SUP-2026-0095 Bosch** and **SUP-2026-0445 Ever Higher**.
2. **Tim, as tim@ (not admin@)**, opens **Tools → Reminders**. Each of the three is listed under **"Suppliers awaiting approval"**. He opens each one and presses **Approve** in the status panel.
   - Ever Higher was created by Choo Er, so Tim may approve it.
   - Acme and Bosch have no recorded creator, so the self-approval rule does not apply to them.
3. From then on, **Choo Er raises payment requests** to them as before, and **Tim approves each request** as today.

## §0 · Step 0 (grilling) and Tim's answers

**What grilling found:**
- The unpayable figure is 377,673.50 (above).
- **Supplier status had no function.** The old status panel wrote `suppliers.status` directly, and the transition trigger checked no permission.
- **`created_by` could be forged or rewritten.** The creator stamp only fills a NULL, and nothing stopped an UPDATE. A direct INSERT could also create an `active` supplier.
- **`purchase_orders` still has a direct-INSERT RLS policy** (`purchasing.edit`), so a check inside `create_purchase_order` alone could be bypassed.
- **CLAIM-GST-1's broken window** was closed with bounds, recorded in `docs/handbacks/CLAIM-GST-1.md` §W: 28 min 14 s to 3 h 22 min 59 s.
- **CLM-2026-0004** was recorded in `known-wrong`: it can be approved by nobody (`EXPENSE_CLAIM_NO_EVIDENCE`). Test data; left as it is.

> **★ Correction to Step 0 finding 2, measured in this build:** Step 0 said "admin@ holds the `cfo` role". **That was wrong.**
> - admin@'s `cfo` row in `user_roles` has `revoked_at = 2026-09-23 15:00:48 CST`. Read as `postgres` from the base table:
>   `select u.email, r.code, ur.revoked_at from user_roles ur join roles r … join auth.users u …`.
> - The Step 0 query did not filter `revoked_at`.
> - `current_user_permissions()` as admin@ returns 45 codes, which are the `admin` role's, and does **not** include `action.supplier_approve`.
> - So **admin@ does not receive the three new codes.** Live proof cell S13 shows it: admin@ approving a supplier gets `PERMISSION_DENIED|action.supplier_approve`.
> - Tim said he would decide separately whether to revoke `cfo` from admin@. **There is nothing to revoke: it already is.** This cut did not touch `user_roles`.

**Tim's answers (all as recommended):**

| Q | ruling | where it landed |
|---|---|---|
| Q1 | a BEFORE INSERT trigger on `purchase_orders`, every path | `trg_purchase_orders_supplier_approved` → `guard_po_supplier_approved` |
| Q2 | `set_supplier_status(id, to, note)`, SECURITY DEFINER; a direct client status UPDATE is refused by name; per-button gates | `set_supplier_status` · `guard_supplier_direct_write` · `StatusPanel` |
| Q3 | `approval_log` records submit / approve / reject; an append-only history records every move | `approval_log.subject_type` + `'supplier'` · `supplier_status_history` |
| Q4 | stamp `approved_by/at` on approve only; clear on return to draft | in `validate_supplier_status_transition` (every path) |
| Q5 | warehouse gets `module.suppliers.view` + `.edit` | grant + bootstrap |
| Q7 | the 500.00 to deleted ZZ1B-GDS: record, leave | `known-wrong-until-cutover.md` |
| Q8 | leave "edits after approval"; register it | `docs/forward-queue.md` |
| defaults | guards skip owner paths (except `created_by`, which is immutable everywhere); bucket read stays open; queue gated on `action.supplier_approve`; payee refusal keeps its name; `set_finance_settings` covers the GST / start / FY / allocation columns | as built |

## §1 · What shipped

**Migration:** `db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql`.
- It is assembled from the mirrors by `db/scripts/build_role1b2a_migration.py` and runs as one transaction.
- **Its own proof block** rolls everything back if any of these fails:
  - the grants differ from "before + exactly five";
  - the `admin` role received a new code;
  - approvals are off;
  - a pending document changed;
  - `approval_log` or `journal_entries` changed;
  - any supplier changed, or carries an approval stamp;
  - a customer's credit changed;
  - the transition map is not the ruled 18 steps (5 of them CFO steps);
  - any pending document has no decider.

**New codes** (all held by `cfo` only; **not** given to `admin`):
- `action.finance_settings`
- `action.customer_credit`
- `action.supplier_approve`

**What changed, by area:**

- **(a) Finance settings**
  - `accounts` / `currencies` / `company_profile`: the write policies and `enforce_write_permission` move from `module.finance.edit` to `action.finance_settings`.
  - `finance_settings`: the policy is unchanged, because the period lock stays with finance. A new column guard, `guard_finance_settings_cfo_columns`, refuses a direct write to any column except the period lock, the four approval columns and the update stamps: `FINANCE_SETTINGS_THROUGH_FUNCTION_ONLY|<col>`. It is written as "everything except", so a new column defaults to CFO.
  - New function `set_finance_settings(p_changes jsonb)`: CFO only. It sets only the keys sent. The lock and approval keys are refused by name, and `guard_gst_switch` still fires.
  - `company-assets` bucket: upload, update and delete need `action.finance_settings`. Read is unchanged. This closes `PAYREQB-COMPANY-ASSETS-BUCKET-UNGATED`, and its entry is removed from `docs/known-issues.md`.
- **(b) Customer credit**
  - `guard_customer_credit_write` refuses a direct write that *changes* `credit_limit_base` or `credit_hold`. Writing them back unchanged still passes.
  - New function `set_customer_credit(id, limit, hold)`: CFO only. History is still written by the existing trigger.
  - `master_import_forbidden_columns` gains the two credit columns, plus `approved_by` / `approved_at`.
- **(c) Suppliers**
  - `supplier_status_moves()` is the single definition of the transition map and of the code each step needs. The trigger, the function and the page all read it; the TypeScript copy is gone.
  - `set_supplier_status` enforces the moves and the per-person self-approval check on approve and reject. It writes `approval_log` (subject `supplier`) and `supplier_status_history`. It is not an approval-engine chain.
  - `guard_supplier_direct_write`:
    - `created_by` can never change, on any path;
    - a client INSERT must be `draft`, must not forge its creator, and must not carry an approval stamp;
    - a client UPDATE cannot change the status or the stamp.
  - `operations_now` gains `supplier_pending_approval` (36th entry), gated on `action.supplier_approve`.
- **Unapproved-supplier rule**
  - `payment_request_payee_check`: payable means `approved` or `active`, and not deleted. Anything else is refused as `PAYMENT_REQUEST_SUPPLIER_BLOCKED|<code>|<status or deleted>`. It runs at submit, approve and pay; reversals are exempt.
  - `guard_po_supplier_approved` refuses a new PO with `PO_SUPPLIER_NOT_APPROVED|<code>|<status or deleted>`.
- **Grants:** cfo gets the three codes (26 → 29). warehouse gets `module.suppliers.view` + `.edit` (12 → 14).
- **Bootstrap:** `db/tables/role_permissions.sql` gives warehouse the two supplier codes, which is still its meaning (a fresh install's start). `cfo` is still absent from the bootstrap (`ROLE1-BOOTSTRAP-MISSING-ROLES`), so in a fresh install the three new codes have no holder — the same situation as `action.finance_reopen`.

**Screens.** Controls are visible but disabled, and name the code they need.
- **Supplier status panel:** the moves come from the database, each button carries its own code, and the approval date is shown. If a person can take no step at all, a panel-level line names the code(s).
- **`/finance/settings`:** now has two gates. The lock stays on `module.finance.edit`; the GST panel moves to `action.finance_settings` and calls `set_finance_settings`.
- **`/finance/company`:** gated on `action.finance_settings`. Its Save button had **no gate** before; it now has one. Refusals are localised instead of printing the raw error string.
- **Customer page:** new **credit panel** for the CFO, disabled with the reason for everyone else.
- **Customer edit form:** no longer shows or sends the credit fields; a note says where they moved.
- **Reminders:** a "Suppliers awaiting approval" entry.
- **Copy:** new en and zh text for every new refusal; the payment-refusal wording is updated.

**Fixtures:**
- **New: 216**, arms A–K. It includes self-approval across two accounts of one person (C) and a forged `created_by` (A2). Fault injection J shows the direct-write guard is load-bearing: with the guard disabled, the forged insert succeeds.
- **Updated because a rule changed:**
  - **21 fixtures** now give their PO or payment supplier `status 'active'` (owner path): 20, 21, 22, 30, 33, 35, 36, 84, 85, 87, 88, 97, 100 (receiving clerk), 127, 147, 168, 169, 184, 204, 206, 210.
  - **210 I** now walks only active → blacklisted.
  - **111**: 35 → 36 entries.
  - **195 J2** copies the warehouse role without the supplier codes.
  - **100 C** is inverted: warehouse **now reads** suppliers (Q5).
- `scripts/check-document-registry.mjs`: `EXPECTED_TABLES` 226 → 227 (`supplier_status_history` has no code column).

**Two defects caught before they shipped (both caught by checks, not by review):**
1. The first draft of `master_import_forbidden_columns` had no comma after `'monthly_salary'`, so SQL merged two adjacent literals into `'monthly_salarycredit_limit_base'`. Fixture 209 F6 caught it in the offline gate.
2. The new table had no anon decision (`check-anon-grant-decision`, which runs in the build). Fixed with `REVOKE ALL … FROM anon` in the mirror.

## §2 · Verification — every figure is the script's own exit line

| step | result |
|---|---|
| `db/gate.py --offline` (last run before migrating) | `GATE_EXIT=0`. The first run was `GATE_EXIT=4` (24 fixtures, the expected rule changes and the comma above), then 4 again (1 fixture), then 0 |
| dry run on live (migration + grants file, `ROLLBACK`) | clean; every pending document has a decider |
| backup | `BACKUP_EXIT=0`: `evoltrya-backup-2026-09-24-1918.dump`, TOC 6092 (previous 6091, floor 5481) |
| `db/apply_migration.sh` | `APPLY_OWN_EXIT=0`. Pre-flight: 15 CREATE FUNCTION (4 replace · 11 new), no account codes, 2 columns added (0 on a masked table). **Window start 2026-09-24 19:37:12 CST** |
| `NOTIFY pgrst` + `npm run types:gen` | `TYPES_OWN_EXIT=0`. The generated file equals the hand-written entries except the new table's relationship list |
| `npx tsc --noEmit` | `TSC_OWN_EXIT=0` |
| `npm run build` | `BUILD_EXIT=0` |
| `db/gate.py` (full) | `GATE_EXIT=0`, 516 s: rebuild ✓ · mirrors vs live ✓ (permissions seed 49/49, drift 0) · fixtures ✓ · anon surface ✓ (baseline 327) |
| `node scripts/check-i18n.mjs` | `I18N_OWN_EXIT=0` |
| `node scripts/check-error-swallowing.mjs` | `SWALLOW_OWN_EXIT=0` |
| smoke (`db/run_detached.sh`, token SMOKE, `--timeout 2400`, started 19:50) | **`SMOKE_EXIT=0`**, around 20:04. 235 routes + probes: **253 ok · 7 skipped (no data) · 0 FAILED**; 228 timed routes, 686.6 s total, median 2,826 ms. The disposable session got the 49-code probe role (`probe-smoke-all-*`). **Clean-up, read at 20:04:56 as `postgres` from base tables:** `smoke-%` users **0** · `probe-%` roles **0** · orphan grants **0** · `ZZ-SMOKE-%` employees **0**. `.ephemeral/` is empty. No smoke or `next dev` process from this repo is left (the only `next dev` running belongs to `~/art-copilot`, started 19:13) |

## §3 · Live proof

**Script:** `db/scripts/2026-09-24-role1b2a-live-proof.sql`. One transaction, `ROLLBACK`, run as `postgres` (`rolbypassrls = t`). Each cell sets `request.jwt.claims` to a real account and runs under `SET LOCAL ROLE authenticated`.

**Result:** `PROOF_OWN_EXIT=0`, **45 of 45 cells**, started 19:39:28 CST.

- **The first run stopped at cell S13** with `PROOF_EXIT=3`. It expected admin@ to be refused as a self-approver, but admin@ was refused for permission. That is how the admin@/`cfo` correction above was found. Only the cell's expectation changed.
- **Leftovers afterwards**, read as `postgres` from base tables: `payment_requests` 0 · `ZZ-B2A-%` suppliers 0 · `supplier_status_history` 0 · `storage.objects` `logo/zz-b2a%` 0.
- PREQ numbering is gapless, so the rolled-back PREQ-2026-0001 used up no number.

| account | cell | result |
|---|---|---|
| chooer@ | submit Acme | passes |
| chooer@ | approve Acme | `PERMISSION_DENIED|action.supplier_approve` |
| chooer@ / tim@ | read `operations_now` `supplier_pending_approval` | 0 rows / **1 row** |
| tim@ | approve Acme (creator NULL) | passes; `approved_by` = tim@; tim@ reads 2 `approval_log` supplier rows |
| chooer@ → tim@ | submit, then approve Ever Higher (created by chooer@) | passes |
| admin@ | direct INSERT of a draft supplier | passes, `created_by` = admin@ |
| admin@ | submit it | passes |
| **tim@** | **approve / reject admin@'s supplier (same person, EMP-2026-0002)** | **`SELF_APPROVAL_FORBIDDEN|raiser`** ×2 |
| admin@ | approve it | `PERMISSION_DENIED|action.supplier_approve` (see the correction) |
| chooer@ | direct INSERT with `created_by` = tim@ | `SUPPLIER_CREATED_BY_FORGED` |
| chooer@ | direct INSERT as `active` | `SUPPLIER_INSERT_MUST_BE_DRAFT|active` |
| chooer@ | direct UPDATE of `created_by` | `SUPPLIER_CREATED_BY_IMMUTABLE` |
| chooer@ | direct status UPDATE | `SUPPLIER_STATUS_THROUGH_FUNCTION_ONLY` |
| fusheng@ | warehouse creates a draft supplier | passes (Q5) |
| chooer@ | **submit** a payment request to Bosch (draft) | `PAYMENT_REQUEST_SUPPLIER_BLOCKED|SUP-2026-0095|draft` |
| chooer@ | submit to Acme (approved), 1.00 on EXP-2026-0001 | passes (PREQ-2026-0001, rolled back) |
| chooer@ → tim@ | suspend Acme; tim@ **approves** the request | `PAYMENT_REQUEST_SUPPLIER_BLOCKED|SUP-2026-0002|suspended` |
| chooer@ → tim@ | reactivate; tim@ approves | passes |
| chooer@ / tim@ | blacklist Acme | `PERMISSION_DENIED|action.supplier_approve` / passes |
| chooer@ | **pay** the approved request | `PAYMENT_REQUEST_SUPPLIER_BLOCKED|SUP-2026-0002|blacklisted` |
| chooer@ / tim@ | restore (blacklisted → archived) | `PERMISSION_DENIED|action.supplier_approve` / passes; 6 history rows |
| sandra@ | `create_purchase_order` to Bosch | `PO_SUPPLIER_NOT_APPROVED|SUP-2026-0095|draft` |
| sandra@ | direct INSERT of a PO to Bosch | `PO_SUPPLIER_NOT_APPROVED|SUP-2026-0095|draft` |
| sandra@ | control: direct PO to SUP-2026-0003; edit existing PO-2026-0007 | passes / passes |
| chooer@ | direct UPDATE of the GST number | `FINANCE_SETTINGS_THROUGH_FUNCTION_ONLY|gst_registration_no` |
| chooer@ | `set_finance_settings` | `PERMISSION_DENIED|action.finance_settings` |
| chooer@ | control: write the period lock | passes |
| chooer@ | UPDATE `company_profile`; UPDATE `accounts` | `PERMISSION_DENIED|action.finance_settings` ×2 |
| chooer@ | upload to `company-assets` | `new row violates row-level security policy for table "objects"` |
| tim@ | `set_finance_settings`; UPDATE `company_profile`; upload to `company-assets` | passes ×3 |
| tim@ | `set_finance_settings({locked_before})` | `FINANCE_SETTINGS_KEY_NOT_HERE|locked_before` |
| sandra@ | direct change of the credit limit | `CUSTOMER_CREDIT_THROUGH_FUNCTION_ONLY` |
| sandra@ | control: save the customer with credit unchanged | passes |
| chooer@ | `set_customer_credit` | `PERMISSION_DENIED|action.customer_credit` |
| tim@ | `set_customer_credit` (CUS-2026-0003 → 1,500) | passes; +1 `customer_credit_history` row by tim@ |
| — | `journal_entries` inside the proof | 82 = before |

### Before / after

**Script:** `db/scripts/2026-09-24-role1b2a-readings.sql`, which states the identity for every part.

**Timing:** before at 19:14 and again at 19:35:52 CST (identical); after at 19:41:04 CST.

| reading | identity · object | before | after |
|---|---|---:|---:|
| `approvals_enabled` / l1 / l2 / threshold | postgres · base `finance_settings` | t / finance / cfo / 1000 | **t / finance / cfo / 1000** |
| pending: claims submitted · leave · medical submitted · medical approved-unpaid · reviews · work orders · stocktakes · POs · payment requests | postgres · base | 1 · 2 · 0 · 1 · 0 · 0 · 5 · 0 · 0 | **the same** |
| `approval_log` rows · `journal_entries` | postgres · base | 14 · 82 | **14 · 82** |
| suppliers live draft / approved / active · deleted draft / active | postgres · base | 8 / 1 / 0 · 4 / 4 | **the same** (the migration approved nobody, Q6) |
| customers with a limit · on hold | postgres · base | 1 · 0 | **1 · 0** |
| account 1100 · 2000 (debit − credit) | postgres · base `journal_lines` | 43,002.12 · −376,404.42 | **the same** |
| codes per role: admin · cco · **cfo** · cto · finance · gm · **warehouse** · operations | postgres · base `role_permissions` | 45 · 34 · 26 · 31 · 34 · 20 · 12 · 15 | **45 · 34 · 29 · 31 · 34 · 20 · 14 · 15** |
| unheld roles: auditor · employee · hr · procurement · sales | postgres · base | 19 · 0 · 7 · 15 · 16 | unchanged |
| `ap_open_items` n · Σ | tim@ · **view** | 16 · 416,988.32 | 16 · 416,988.32 |
| `ar_open_items` n · Σ | tim@ · **view** | 10 · 57,545.87 | 10 · 57,545.87 |
| AP by supplier state: draft · approved · deleted · not a supplier | tim@ · view | 377,173.50 · 39,173.12 · 500.00 · 141.70 | the same |
| list-vs-ledger AP: list / ledger / **unexplained** | tim@ · `list_ledger_reconciliation()` | 416,988.32 / 376,404.42 / **0.00** | 416,988.32 / 376,404.42 / **0.00** |
| list-vs-ledger AR: list / ledger / **unexplained** | tim@ · same | 57,545.87 / 43,002.12 / **0.00** | 57,545.87 / 43,002.12 / **0.00** |
| `current_user_permissions()`: admin@ · chooer@ · fusheng@ · phua@ · sandra@ · **tim@** · vince@ | each account as itself | 45 · 34 · 12 · 31 · 34 · 26 · 20 | 45 · 34 · **14** · 31 · 34 · **29** · 20 |

**Pending documents and their deciders.** The migration's proof listed these, counted by person:
- CLM-2026-0004 → tim@ (still blocked by its own missing evidence; see known-wrong)
- LV-2026-0001 / 0003 → admin@, tim@
- MC-2026-0001 (pay) → admin@, chooer@
- ST-2026-0082…0086 → chooer@, fusheng@, phua@, sandra@

**No pending document is left without a decider, and nothing new was left pending on live.**

## §4 · What each person can no longer do

- **Choo Er (finance)** can no longer:
  - switch GST registration or change any finance setting except the period lock;
  - edit the company profile (name, address, invoice footer, bank details, logo);
  - change customer credit limits or holds;
  - approve, reject, blacklist or restore a supplier;
  - request or pay money to an unapproved supplier.

  She keeps the period lock, submit/withdraw, suspend, reactivate, archive, and every other customer and supplier field.
- **Sandra (cco)** and **Phua (cto)** can no longer:
  - change customer credit;
  - approve, reject, blacklist or restore suppliers;
  - raise a new PO to an unapproved supplier.
- **Tim as admin@** (the `admin` role, 45 codes; its `cfo` grant is revoked) loses:
  - finance settings, company profile, accounts and currencies (the `admin` role holds `finance.edit`, which no longer opens them);
  - customer credit;
  - supplier approve, reject, blacklist and restore.

  **Business decisions go through tim@.**
- **Tim as tim@:** loses nothing. **Gains** finance settings (GST, company profile, bank details, logo), customer credit, and supplier decisions.
- **Fu Sheng (warehouse):** **gains** supplier creation and editing (view + edit), including submit, suspend, reactivate and archive.
- **Vince (gm):** no change.

## §5 · The broken window — started, end PENDING

**Start: 2026-09-24 19:37:12 CST.** This is `db/apply_migration.sh`'s own line, also in `db/migration-windows.tsv`; the script's "applied at" line reads 19:36:22.
**End: PENDING — Tim reads it from Vercel.**

What the old app does against the new database (approvals ON):
- **No supplier can change status from the old status panel.** It writes `suppliers.status` directly, which is now refused by name (`SUPPLIER_STATUS_THROUGH_FUNCTION_ONLY`); the old screen shows the raw code. That includes Choo Er's submit and every approval. **Nothing needs doing before the deploy.** tim@ has no supplier controls in the old app anyway.
- **The 377,673.50 cannot be paid, and new POs to Acme and Bosch are refused**, with a message written for the old rule ("blocked"). No payment request exists, so nothing in flight is stuck. Receipts against the open POs still work.
- **Choo Er's GST switch** is refused by name (`FINANCE_SETTINGS_THROUGH_FUNCTION_ONLY|…`). **Her company-profile Save and logo upload** are refused (`PERMISSION_DENIED|action.finance_settings` / a storage RLS error), and the old page shows the raw text. **tim@ has no controls for these until the deploy.**
- **The old customer edit form** still sends `credit_limit_base` and `credit_hold`. A save that leaves them unchanged passes. Changing either is refused by name, and the old form prints it inside "Save failed: …".
- **Unaffected:** approvals of every other kind, the reminders page (the old app doesn't list the new entry, which is harmless), and every posting path.
