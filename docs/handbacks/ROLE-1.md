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

---

# Batch 2b — contract terms to cco, metal prices to finance, direct sale to cco, assay application to cto (2026-09-24)

**Opening gate:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `b2038f3bdb4e45318d5d6e16ade14ab38c75024d` (ROLE-1 Batch 2a).
**Approvals were ON and stayed ON.** Every figure below is a script's own exit line or a query named with its identity.

## §W · Batch 2a's broken window — closed with bounds

Tim confirmed the Batch 2a deploy on 2026-09-24. **Start 19:37:12 CST** (`db/apply_migration.sh`'s own line).
The end lies **between 20:05:40 CST** (*measured*: `origin/main` → `b2038f3b` in git's remote-ref log,
`git reflog show refs/remotes/origin/main`) **and 20:15:55 CST** (*derived*: the first live read of this session,
database clock `now()` as `postgres`; Tim had confirmed the deploy before this session began). So the window lasted
**between 28 min 28 s and 38 min 43 s**. These are bounds, not a measurement.

## §0 · Step 0 (grilling) and Tim's answers

**What grilling found** (read as `postgres`, `rolbypassrls = t`, base tables, `relkind = 'r'` checked):
- **Contracts had no code of their own.** `contracts` and the seven term tables were written under `customers.edit` or
  `suppliers.edit` (policy and `enforce_write_permission`), so finance, cto and — since Batch 2a — warehouse could all create
  contracts. Live: **0 contracts, 0 term rows, 0 document links.** `/contracts/new` had no edit gate.
- **Metal prices:** 12 rows (10 live), all by admin@, last 2026-08-10; 2 indices; 0 calendar rows; `pricing_settings` last
  written 2026-09-03 with no recorded updater. `pricing.edit` holders: admin · cco · cto · finance · procurement · sales.
- **Direct sale:** 9 `sales_records` (8 by admin@, last 2026-08-26; 1 by an account that no longer exists). **All four
  writers are `SECURITY DEFINER`** (`record_output_sale` · `ship_order` · `attribute_sale_customer` · `allocate_processing_costs`,
  `pg_proc.prosecdef = t`); no screen writes the table. The UPDATE policy's only remaining use past `reject_sales_record_mutation`
  was forging `cogs_entry_id` (NULL → any entry).
- **Assay:** 4 applied inbound assays (all by admin@, last 2026-08-10), 0 output. **Warehouse held both `inbound.edit` and
  `output.edit`, so it could apply an assay — reprice a batch and post to 2000.** Two side doors bypassed the functions: the
  `assay_results` UPDATE policy let a recorder set `applied_at` / `applied_by` / `superseded_by`, and the metals tables accepted a
  direct row with `content_source = 'assay'` + `source_assay_id`.
- The "record and apply" button on the new-assay form runs both in one action.

**Tim's answers (all six as recommended):**

| Q | ruling | where it landed |
|---|---|---|
| Q1 | policy **and** `enforce_write_permission` → `action.contract_terms` on all eight tables; `/contracts/new` disabled control; `link_document_to_contract` unchanged | mirrors of the 8 tables; `NewContractForm` |
| Q2 | leave `pricing.edit` on the unheld procurement / sales roles; register | `docs/known-issues.md` § ROLE1B2B-UNHELD-PRICING-EDIT |
| Q3 | close both INSERT and UPDATE on `sales_records` | policies dropped; `guard_sales_record_direct_write` |
| Q4 | close both assay side doors, each by name | `guard_assay_applied_columns` · `guard_batch_metals_assay_source` |
| Q5 | "Record and apply" disabled with the reason; "Record" stays live | both new-assay forms |
| Q6 | `reprice_from_committed_terms` and its preview stay on `inbound.edit` (Batch 4) | untouched |
| fold-in | **admin keeps every code; every new code also to admin, same migration** (Tim, 2026-09-24, closed) | migration §7; `docs/role-matrix.md` §13 |

## §1 · What shipped

**Migration:** `db/migrations/2026-09-24-role1b2b-contracts-prices-direct-sale-and-assay.sql`, assembled from the mirrors by
`db/scripts/build_role1b2b_migration.py` (every policy and trigger is extracted verbatim from its mirror). One transaction.
**Its own proof block** rolls everything back if: the grants differ from "before + the ruled grants − exactly the two
`pricing.edit`"; admin lacks any new code or loses any code it had; `pricing.edit` holders are not `admin cco procurement sales`;
an edit code lacks its view; approvals are off; a pending document changed; `approval_log`, `journal_entries`, contracts, metal
prices, indices, sales records, assays or applied assays changed count; `sales_records` still has a write policy; or any pending
document has no decider.

**New codes:** `action.contract_terms` (cco) · `action.metal_prices` (finance) · `action.direct_sale` (cco) ·
`action.apply_assay` (cto) — **each also to `admin`**, together with Batch 2a's three (admin held none of them; read as
`postgres` from base `role_permissions` before the cut). `module.pricing.edit` and `module.output.edit` re-described.

- **(d) Contracts:** `contracts` insert/update and the seven term tables' write policy → `has_permission('action.contract_terms')`;
  their `enforce_write_permission` → the same code.
- **(e) Metal prices:** `metal_prices` (3 policies) · `metal_price_indices` · `index_market_calendar` · `pricing_settings` policies
  and triggers, and `upsert_metal_prices` → `action.metal_prices`. `pricing.edit` taken from finance and cto.
- **(f) Direct sale:** `record_output_sale` → `action.direct_sale`. `sales_records` INSERT and UPDATE policies dropped; the old
  `enforce_write_permission('module.finance.edit')` trigger replaced by a statement-level `trg_sales_records_direct_write`
  (`SALE_THROUGH_FUNCTION_ONLY`, fires on zero rows too — without it a direct UPDATE would be a silent no-op).
- **(g) Assay:** `apply_assay_result` · `apply_output_assay` · `unapply_assay_result` · `preview_assay_price` ·
  `preview_apply_output_assay` → `action.apply_assay`. Recording stays on `inbound.edit` / `output.edit`.
  `trg_assay_results_applied_columns` (`ASSAY_APPLY_THROUGH_FUNCTION_ONLY`) and `trg_{inbound,output}_batch_metals_assay_source`
  (`ASSAY_CONTENT_THROUGH_FUNCTION_ONLY`); owner paths pass.
- **Bootstrap:** `db/tables/role_permissions.sql` finance swaps `module.pricing.edit` for `action.metal_prices` — still its
  meaning. The bootstrap `admin` stays "system administration only": the live admin-holds-everything is Tim's ruling for testing,
  not a fresh install's start (say if that is wrong). cco / cto / cfo are still absent from the bootstrap
  (`ROLE1-BOOTSTRAP-MISSING-ROLES`).

**Screens** (DBLOCK-1: visible, disabled, naming the code):
- `/contracts/new`: Save gated on `action.contract_terms` (the page could not judge before — the code depended on the side;
  now there is one code).
- Metal prices: new / bulk / edit pages and the edit action → `action.metal_prices`. **The threshold panel used to hide its
  form from non-holders; it now shows it disabled with the reason.**
- Formula new / edit: Save and Delete gated on `module.pricing.edit` (closes `PAYREQB-FORMULA-PAGES-NO-DISABLED-GATE`).
- Output batch sale panel: the sell button gated on `action.direct_sale`.
- Inbound and output assay detail pages: Apply and Unapply gated on `action.apply_assay`; the preview is **not asked** for a
  non-holder and a "belongs to the CTO" line replaces it (never "no pricing formula" — that would be a data claim).
- Both new-assay forms: "Record and apply" gated; "Record only" becomes the primary button for non-holders.
- Copy (en + zh): `CONTRACT_NOT_PERMITTED` rewritten for the new code; `assay.previewRestricted(+Hint)`;
  `ASSAY_APPLY_THROUGH_FUNCTION_ONLY` · `ASSAY_CONTENT_THROUGH_FUNCTION_ONLY` · `SALE_THROUGH_FUNCTION_ONLY`.

**Fixtures:**
- **New: 217**, arms A–E, including two fault injections: with `trg_assay_results_applied_columns` disabled the direct
  `applied_at` write goes in; with `trg_sales_records_direct_write` disabled a direct UPDATE falls back to a silent zero-row no-op.
- **Updated because the gate moved (no assertion changed):** the selling role in 38, 39, 42, 44, 45, 46 (two roles), 47, 129,
  130 gains `action.direct_sale`; the applying role in 40 and 54 gains `action.apply_assay`.

**Decisions made during the build, not asked (say if any is wrong):**
- **admin never held `module.tasks.view_all`** (reading other people's personal tasks) — it was not among the 45 codes Tim
  restored. The ruling is "keep + every new code", so this cut did not add it; the migration asserts admin lacks nothing it did
  not already lack. Recorded in `docs/role-matrix.md` §13.
- Term-table write policies became plain `has_permission('action.contract_terms')` (the `EXISTS` on the parent contract was only
  there to pick the side's code). Policy names kept.
- The dry run showed one defect before it shipped: the first proof block asserted "admin holds every catalogue code" and failed
  on `module.tasks.view_all` (above).

## §2 · Verification — every figure is the script's own exit line

| step | result |
|---|---|
| `db/gate.py --offline` | first run `GATE_EXIT=4` (11 fixtures on the moved gates), then 4 (fixture 217's own check read `metal_prices.created_by`, which is not stamped), then **`GATE_EXIT=0`**; re-run after the screen changes, **`GATE_EXIT=0`** |
| dry run on live (migration with `ROLLBACK`) | `DRY_OWN_EXIT=0`; every pending document has a decider |
| rehearsal on live (migration + live proof in one transaction, `ROLLBACK`) | `REHEARSE_OWN_EXIT=0`, 32/32 cells |
| backup | `BACKUP_EXIT=0` — `evoltrya-backup-2026-09-24-2052.dump`, TOC 6138 (previous 6092, floor 5482) |
| `db/apply_migration.sh` | `APPLY_OWN_EXIT=0`. Pre-flight: 11 CREATE FUNCTION (7 replace · 4 new), 4 account codes all `is_system`, no columns. **Window start 2026-09-24 22:07:50 CST** (the script's "applied at" line reads 22:06:57) |
| `NOTIFY pgrst` + `npm run types:gen` | `TYPES_OWN_EXIT=0`; `lib/database.types.ts` byte-identical (no signature changed) |
| `npx tsc --noEmit` | `TSC_OWN_EXIT=0` |
| `npm run build` | `BUILD_OWN_EXIT=0` |
| `node scripts/check-i18n.mjs` | `I18N_OWN_EXIT=0` |
| `node scripts/check-error-swallowing.mjs` | `SWALLOW_OWN_EXIT=0` |
| `db/gate.py` (full) | **`GATE_EXIT=0`**, 513 s: rebuild ✓ · mirrors vs live ✓ (permissions seed 53/53, drift 0) · fixtures ✓ (217 included) · anon surface ✓ (baseline 327) |
| smoke (`db/run_detached.sh`, token SMOKE, `--timeout 2400`, started 22:21:17) | **`SMOKE_EXIT=0`**: 235 routes + probes, **253 ok · 7 skipped (no data) · 0 FAILED**; 228 timed routes, 777.8 s total, median 3,186 ms; the disposable session got the 53-code probe role. **Clean-up, read at 22:38:16 as `postgres` from base tables:** `smoke-%` users **0** · `probe-%` / `fixture-%` roles **0** · orphan grants **0** · `ZZ-SMOKE-%` employees **0**; `.ephemeral/` empty; no smoke process left. The scratch check reported 6 stale `ZZ-SMOKE-*` rows aged 535–1,177 h (5 still referenced) — they predate this cut; reported, not touched |

## §3 · Live proof

**Script:** `db/scripts/2026-09-24-role1b2b-live-proof.sql`. One transaction, `ROLLBACK`, run as `postgres` (`rolbypassrls = t`);
each cell sets `request.jwt.claims` to a real account and runs under `SET LOCAL ROLE authenticated`.
**Result:** `PROOF_OWN_EXIT=0`, **32 of 32 cells**, finished 22:08:26 CST (inside the window, right after the migration).
Leftovers afterwards, read as `postgres` from base tables: `ZZ-B2B%` contracts **0** · `ZZ-B2B%` formulas **0** ·
ASY-2026-0004 still applied by admin@ (the proof's unapply was rolled back). `journal_entries` numbering is MAX+1, so nothing
rolled back used up a number.

| account | cell | result |
|---|---|---|
| chooer@ · phua@ · fusheng@ | create a contract | `new row violates row-level security policy for table "contracts"` ×3 |
| sandra@ | create a contract; write a grade term on it | passes ×2 |
| chooer@ | write a grade term on sandra@'s contract | RLS refusal on `contract_grade_specs` |
| fusheng@ | edit that contract | `PERMISSION_DENIED|action.contract_terms` |
| admin@ | create a contract | passes (admin holds every new code) |
| phua@ · sandra@ | `upsert_metal_prices` | `PERMISSION_DENIED|action.metal_prices` ×2 |
| sandra@ | change the stale-quote threshold | `PERMISSION_DENIED|action.metal_prices` |
| chooer@ | `upsert_metal_prices`; change the threshold | passes ×2 |
| chooer@ · phua@ | create a pricing formula | RLS refusal ×2 |
| sandra@ | create a pricing formula | passes |
| chooer@ · phua@ · fusheng@ | `record_output_sale` | `PERMISSION_DENIED|action.direct_sale` ×3 |
| sandra@ | control: `record_output_sale` on an unknown batch | passes the gate → `OUTPUT_NOT_FOUND|…` |
| chooer@ | direct INSERT into `sales_records`; direct UPDATE touching zero rows | `SALE_THROUGH_FUNCTION_ONLY` ×2 |
| chooer@ · sandra@ · fusheng@ | unapply ASY-2026-0004 | `PERMISSION_DENIED|action.apply_assay` ×3 |
| chooer@ | `preview_assay_price` | `PERMISSION_DENIED|action.apply_assay` |
| fusheng@ | `preview_apply_output_assay` | `PERMISSION_DENIED|action.apply_assay` |
| fusheng@ | direct UPDATE setting `applied_at` | `ASSAY_APPLY_THROUGH_FUNCTION_ONLY` |
| fusheng@ | direct INSERT of an assay-sourced metal row | `ASSAY_CONTENT_THROUGH_FUNCTION_ONLY` |
| fusheng@ | control: record a lab result | passes |
| phua@ | unapply ASY-2026-0004 | passes |
| phua@ | re-apply ASY-2026-0004 | **passes `action.apply_assay` and the nested `inbound.edit` check in `reprice_inbound_batch`, then stops on data: `FX_RATE_MISSING|USD|2026-09-24|tt_sell`**. There is no USD selling rate for today on live (test data), so the reprice and its journal entry could not be shown; the proof does not invent a rate. `journal_entries` 82 → 82 inside the proof |

### Before / after

**Script:** `db/scripts/2026-09-24-role1b2b-readings.sql`, which states the identity for every part.
**Timing:** before at 20:47:34 CST; after at 22:08:41 CST.

| reading | identity · object | before | after |
|---|---|---:|---:|
| `approvals_enabled` / l1 / l2 / threshold | postgres · base `finance_settings` | t / finance / cfo / 1000 | **t / finance / cfo / 1000** |
| pending: claims submitted · leave · medical submitted · medical approved-unpaid · reviews · work orders · stocktakes · POs · payment requests | postgres · base | 1 · 2 · 0 · 1 · 0 · 0 · 5 · 0 · 0 | **the same** |
| `approval_log` rows · `journal_entries` | postgres · base | 14 · 82 | **14 · 82** |
| contracts · term rows · metal prices · indices · calendar · formulas · sales records · applied assays | postgres · base | 0 · 0 · 12 · 2 · 0 · 1 · 9 · 4 | **the same** |
| account 1100 · 2000 (debit − credit) | postgres · base `journal_lines` | 43,002.12 · −376,404.42 | **the same** |
| codes per role: **admin** · **cco** · cfo · cto · finance · gm · warehouse · operations | postgres · base `role_permissions` | 45 · 34 · 29 · 31 · 34 · 20 · 14 · 15 | **52 · 36** · 29 · 31 · 34 · 20 · 14 · 15 |
| unheld roles: auditor · employee · hr · procurement · sales | postgres · base | 19 · 0 · 7 · 15 · 16 | unchanged |
| `module.pricing.edit` held by | postgres · base | admin cco cto finance procurement sales | **admin cco procurement sales** |
| catalogue · what admin lacks | postgres · base | 49 · `customer_credit finance_settings supplier_approve tasks.view_all` | **53 · `module.tasks.view_all`** |
| `ap_open_items` n · Σ | tim@ · **view** | 16 · 416,988.32 | 16 · 416,988.32 |
| `ar_open_items` n · Σ | tim@ · **view** | 10 · 57,545.87 | 10 · 57,545.87 |
| list-vs-ledger AP: list / ledger / **unexplained** | tim@ · `list_ledger_reconciliation()` | 416,988.32 / 376,404.42 / **0.00** | 416,988.32 / 376,404.42 / **0.00** |
| list-vs-ledger AR: list / ledger / **unexplained** | tim@ · same | 57,545.87 / 43,002.12 / **0.00** | 57,545.87 / 43,002.12 / **0.00** |
| `current_user_permissions()`: admin@ · chooer@ · fusheng@ · phua@ · sandra@ · tim@ · vince@ | each account as itself | 45 · 34 · 14 · 31 · 34 · 29 · 20 | **52** · 34 · 14 · 31 · **36** · 29 · 20 |

cto and finance stay at 31 and 34: each gained one code and lost `module.pricing.edit`.

**Pending documents and their deciders** (the migration's proof, counted by person): CLM-2026-0004 → tim@ ·
LV-2026-0001 / 0003 → admin@, tim@ · MC-2026-0001 (pay) → admin@, chooer@ · ST-2026-0082…0086 → chooer@, fusheng@, phua@, sandra@.
**No pending document is left without a decider, and nothing new was left pending on live.**

## §4 · What each person can no longer do

- **Choo Er (finance):** create or edit contracts and their terms; create, edit or delete pricing formulas; sell directly from an
  output batch; apply or unapply assays or see their previews; insert or update `sales_records` directly. **Keeps and now owns**
  metal prices, indices, the market calendar and the stale-quote threshold (`action.metal_prices`). Still records lab results.
- **Phua (cto):** contracts; metal prices and the threshold; pricing formulas; direct sale. **Gains** applying and unapplying
  assays with their previews (`action.apply_assay`).
- **Sandra (cco):** metal prices and the threshold; applying or unapplying assays and their previews. **Gains** contracts and
  terms (`action.contract_terms`) and direct sale (`action.direct_sale`); keeps pricing formulas. Still records lab results.
- **Fu Sheng (warehouse):** contracts (held only since Batch 2a); direct sale; applying or unapplying assays — **which until now
  let the warehouse reprice a batch and post to the supplier payable**. Still records lab results.
- **Tim as admin@:** loses nothing; gains the four new codes and Batch 2a's three.
- **Tim as tim@, Vince:** no change.

## §5 · The broken window — started, end PENDING

**Start: 2026-09-24 22:07:50 CST** (`db/apply_migration.sh`'s own line, also in `db/migration-windows.tsv`; its "applied at"
line reads 22:06:57). ~~**End: PENDING — Tim reads it from Vercel.**~~
**Closed with bounds (PAYROLL-APR-1, 2026-09-24; Tim confirmed the deploy before that session began).** The end lies
**between 22:39:27 CST** (*measured*: `origin/main` → `a243831e` in git's remote-ref log, `git reflog show refs/remotes/origin/main`)
**and 23:01:11 CST** (*derived*: the first live read of the PAYROLL-APR-1 session, database clock `now()` as `postgres`).
So the window lasted **between 31 min 37 s and 53 min 21 s**. These are bounds, not a measurement.

What the old app does against the new database (approvals ON):
- **Nobody except admin@ can enter metal prices or change the threshold.** The old metal-price pages gate on `module.pricing.edit`,
  which finance no longer holds, so Choo Er gets the page-level refusal; Sandra still sees the pages and the form, and the database
  refuses her (`PERMISSION_DENIED|action.metal_prices`).
- **Refused with a raw or generic error, controls still pressable:** pricing formulas for Choo Er and Phua (the old formula pages
  had no gate — RLS refusal); contract creation for Choo Er, Phua and Fu Sheng (the rewritten `CONTRACT_NOT_PERMITTED` copy only
  ships with the deploy); the sell button for Choo Er, Phua and Fu Sheng; Apply / Unapply for Choo Er, Sandra and Fu Sheng.
  "Record and apply" by any of those three records the result and then shows the apply refusal on the detail page.
- **Assay previews** refuse anyone but Phua and admin@. On the inbound detail page the old localiser turns the refusal into
  「受限 / Restricted」 in the red box and, because a preview error blocks the button, the old Apply button goes disabled with no
  code named. The old new-assay forms show "impact unknown" (output) or the same restricted box (inbound).
- **Unaffected:** approvals of every kind, every posting path, Sandra's contract creation and direct sale, Phua's assays.
  Nothing in these areas is pending on live (0 contracts, no unapplied assays).

## §6 · Commit, push, three SHAs

Reported in the hand-back message: `HEAD`, `origin/main` and `git ls-remote origin main` as full 40-character SHAs
(a commit cannot carry its own hash). Deployment is Tim's to read; the window's end stays PENDING until he does.
Next cut: payroll-posting approval (`docs/forward-queue.md`).

---

# Batch 4 — Step 0, and Batch 4a: purchase prices are their own code; only finance prices a receipt (2026-09-25)

**Opening gate:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `5322fe4ddee380e01d8b0bbfd49d55712432bb4a`
(PAYROLL-APR-1). **Approvals were ON and stayed ON.** Every figure below is a script's own exit line or a query named with its
identity. The matrix lines are `docs/role-matrix.md` §8, §13, §14; the approvals effects are `docs/approvals.md` §3m.

## §W · PAYROLL-APR-1's broken window — closed with bounds, labelled by kind

Tim confirmed the PAYROLL-APR-1 deploy on 2026-09-25, before this session began.

| | time (CST) | kind |
|---|---|---|
| start | 2026-09-25 00:12:32 | `db/apply_migration.sh`'s own line (`db/migration-windows.tsv`) |
| end, lower bound | 00:51:49 | **measured**: the push moved `origin/main` → `5322fe4d` (`git reflog show --date=iso refs/remotes/origin/main`) — no deploy can precede it |
| end, upper bound | 01:14:12 | **derived**: this session's first live read, database clock `now()` as `postgres`, taken after Tim's "deployed" confirmation had arrived — **a relayed confirmation, not a measurement of Vercel** |

**Window: at least 39 min 17 s, at most 61 min 40 s.** Also written into `docs/handbacks/PAYROLL-APR-1.md` §5.

## §0 · Step 0 (grilling) and Tim's answers

**What grilling found** (read as `postgres`, `rolbypassrls = t`, base tables, `relkind = 'r'` checked; code read from the mirrors):
1. **One function does all the pricing.** `reprice_inbound_batch` is the only writer of `inbound_batches.unit_price` and
   `price_history`, and the only thing that posts a `purchase` entry. The desk form (`create_inbound_batch`), the pricing panel
   (`set_inbound_unit_price`), repricing from committed terms and applying an assay all call it. It posts
   (new − old) × the **whole** quantity (1200 in-stock share, 5000 consumed share, Cr 2000), dated the pricing day at that day's
   tt_sell. `receive_inbound_batch_against_po` never prices; unapplying an assay changes no price and reverses no entry.
2. **Four side doors were open:**
   * `price_history` had an INSERT policy on `module.inbound.edit` — live `has_table_privilege('authenticated','price_history','INSERT')`
     = t — and `inbound_unit_price_asof` rebuilds past prices from it, so a made-up row moved AP ageing as-of;
   * `reverse_journal_entry` did not refuse `purchase` entries (`reverse_journal_entry.sql:23-43`): reversing one takes 2000 away
     while `ap_open_items` still shows the debt;
   * `reprice_inbound_batch` and `set_inbound_unit_price` were both executable by `authenticated` (live, `has_function_privilege`);
   * a receipt's supplier, PO line and hand-entered metal content can be changed after pricing.
3. **A paid receipt can be repriced below what was paid** — repricing never reads payments or `pricing_status`, and a manual price
   can overwrite a `final` assay price.
4. **What warehouse actually gains is smaller than the ruling implies.** Warehouse holds none of `module.purchasing.view`,
   `module.pricing.view`, `module.finance.view`; `data.view_purchase_prices` changes only what it sees on receipt screens
   (unit price, price history, assay repricing old/new). POs, formulas and AP ageing stay closed to it until Batch 5.
5. **Landed cost already reaches warehouse, by design** (`inbound_batch_landed_unit_cost` lets `module.stocktakes.edit` through;
   the two cost readers answer anyone with `inbound.view`).
6. **An existing display bug:** the forwarder page and the container freight panel drew a masked freight amount as 0.00.
7. **It does not fit one session** — two cuts.

**Live readings at Step 0** (01:14–01:20 CST, `postgres`, base tables): 15 live receipts — 9 priced, 6 unpriced (IN-2026-0153,
0179, 0180, 0258, 0321, 0322), all created by admin@; 9 of 15 on `draft` suppliers; `price_history` 14 rows, last 2026-08-31;
`purchase` entries 10, last 2026-08-31; 4 inbound assays, all applied (last 2026-08-10), 0 waiting; 0 output assays;
`pricing_term_commitments` 1. Nothing about pricing was pending; nothing could be stranded.

**Tim accepted all thirteen recommendations (2026-09-25):**

| Q | ruling | where |
|---|---|---|
| Q1 | `action.price_receipts` to finance and admin, **with** `data.view_purchase_prices`, both checked in the database | 4a |
| Q2 | (A) `submitted → approved`, the CFO's approval posting at once; rejected, withdrawn; price frozen in its original currency; posted on the approval day at that day's rate; dry run at submit and approve; born approved with `auto_approved` when approvals are off | 4b |
| Q3 | the assay applies in full and raises a pricing request in the same transaction; `RECEIPT_PRICE_REQUEST_OPEN` if a manual request is open; unapplying withdraws that assay's open request | 4b |
| Q4 | the desk-form price box stays; a holder's price submits a request; for everyone else it is disabled with the reason; a non-holder's price is refused by name in the database | 4a (the refusal and the disabled box) · 4b (the request) |
| Q5 | while a request waits: supplier / PO / PO line / metal content / soft delete / a second request refused (`RECEIPT_PRICE_REQUEST_OPEN`); fingerprint re-checked at approval (`RECEIPT_PRICE_CHANGED_SINCE_REQUEST`); supplier approval status not checked | 4b |
| Q6 | refuse at submit and at approve: `RECEIPT_PRICE_BELOW_SETTLED` | 4b (registered: `ROLE1B4A-REPRICE-BELOW-SETTLED`) |
| Q7 | close (a) the `price_history` INSERT policy, (b) `purchase` reversal, (c) the engine's EXECUTE; register (d) the forgeable `purchase` journal and supplier change on a priced receipt | 4a |
| Q8 | engine registration as PAY-REQ-1 / PAYROLL-APR-1 (`require_approver_for(2)`, `blocks_disable`, `fixed_level = 2`, gate `module.inbound.view + data.view_purchase_prices`, raiser judged per person, no subject) | 4b |
| Q9 | pricing formulas masked **per row** (sale → `view_prices`; purchase / both → the purchase code) | 4a |
| Q10 | freight documents stay on `view_prices`; the 0.00 display reads "restricted" | 4a |
| Q11 | yes to every split; `inbound_batches_masked` and `prepayment_applications_masked` move together; rewrite the sales-order / quote note | 4a |
| Q12 | register the landed-cost exception; fix it in Batch 3 | registered |
| Q13 | **two cuts**: this session builds and ships 4a and stops at the push; **4b, the pricing-approval lifecycle, is the next cut**. Between the two, finance prices without approval (the usual [LC] interim) | — |
| standing | every new code also to `admin`, same migration | 4a |

## §1 · What 4a shipped

**Migration** `db/migrations/2026-09-25-role1b4a-purchase-prices-and-who-prices-a-receipt.sql`, assembled from the mirrors by
`db/scripts/build_role1b4a_migration.py`. One transaction. Its self-proof asserts, in the same transaction: the grants are exactly
"before + the ruled grants", nothing removed; every role holding `data.view_prices` holds the purchase code; warehouse holds the
purchase code and not `view_prices`; `action.price_receipts` is held by exactly `admin finance`; approvals still ON; pending documents
unchanged; `approval_log`, `journal_entries`, `price_history`, receipts and priced receipts unchanged; `price_history` has no write
policy; `authenticated` cannot execute the engine; the PO approval gate rows name the purchase code; both PO approval levels still have
a real decider; every pending document still has a decider who is not its own party.

| piece | what |
|---|---|
| codes | `data.view_purchase_prices` → admin · auditor · cco · cfo · cto · finance · gm · procurement · sales (every `view_prices` holder) + **warehouse**; `action.price_receipts` → finance · admin. `data.view_prices` renamed "View sales prices & costs" and re-described |
| 12 views → purchase code | `purchase_orders_masked` · `purchase_order_lines_masked` · `purchase_order_payment_terms_masked` · `payment_term_template_lines_masked` · `purchase_order_line_retentions_masked` · `purchase_order_retention_status` · `pricing_term_commitments_masked` · `pricing_term_commitment_metals_masked` · `inbound_batches_masked` · `inbound_batch_lookup` · `price_history_masked` · `prepayment_applications_masked` |
| per row (Q9) | `pricing_formulas_masked` · `pricing_formula_metals_masked` · `pricing_formula_history_masked` through one new judgement `pricing_formula_terms_visible(direction)`; `calculate_metal_price` asks by the formula's direction |
| per event | `batch_audit_trail`: `amount_restricted` asks the purchase code for `price_change`, `view_prices` for cost entries and sales |
| functions | `ap_aging_asof` · `approve_purchase_order` · `preview_reprice_inbound_batch` → purchase code; `approval_chain_gates` PO-approve rows → purchase code; `role_can_see_amounts` requires both codes; `list_ledger_reconciliation` asks per side (AP purchase, AR `view_prices`); `po_document_data` nulls its prices without the purchase code and says `prices_visible` (closes ROLE1-PO-DOCUMENT-DATA-PRICES) |
| who prices (Q1 · Q4) | `set_inbound_unit_price` · `reprice_from_committed_terms` · `preview_reprice_from_committed_terms` require `action.price_receipts` + `data.view_purchase_prices`; `create_inbound_batch` requires both **only when a price is given**, before anything is written; the engine `reprice_inbound_batch` drops its nested `module.inbound.edit` and asks `data.view_purchase_prices` of whoever pressed the button — so applying an assay also needs to see purchase prices |
| side doors (Q7) | (a) `price_history insert by permission` dropped; (b) `reverse_journal_entry` refuses `purchase` with `JE_REVERSE_USE_SOURCE_PATH`; (c) EXECUTE on `reprice_inbound_batch` revoked from `authenticated` (`db/views/zzz_function_grants.sql`) |
| bootstrap | `role_permissions` bootstrap: the five `view_prices` roles + warehouse get the purchase code; finance gets `action.price_receipts` |

**Screens (en + zh):**
- Receipt page: two flags instead of one — the landed-cost panel on `data.view_prices`, the pricing panel (unit price and history)
  on `data.view_purchase_prices`. The price form and "Reprice from content" are visible, disabled, naming the first missing code
  (`action.price_receipts`, then `data.view_purchase_prices`) — `receiptPricingGate()` in `lib/permissions.ts`.
- Desk form `/inbound/new`: the price box and currency are visible and disabled for non-holders; a line says Finance prices receipts
  and this one will be created without a price (a disabled input is not submitted, so the receipt is created unpriced).
- Assay detail (old / new price) and the PO page (retentions) read the purchase code.
- Forwarder page and container freight panel: a masked freight amount reads **Restricted**, and a currency total with a masked
  document reads Restricted instead of a confident smaller sum.
- Copy: `inbound.form.unitPriceFinancePrices`; `JE_REVERSE_USE_SOURCE_PATH` now names the pricing of a goods receipt and where to
  correct it.

**Fixtures:** new **219** (arms A–J, one fault injection: put the `price_history` INSERT policy back and the direct insert goes
through). **Updated because a gate moved (no assertion changed):** eighteen fixtures whose synthetic roles held `data.view_prices`
now also hold `data.view_purchase_prices` — 30 · 35 · 40 · 47 · 51 · 52 · 110 · 127 · 151 · 194 · 202 · 203 · 204 · 205 · 206 · 210 ·
211 · 218 (fixture 110's "no prices" reader now excludes both codes).

**Known issues:** closed ROLE1-PO-DOCUMENT-DATA-PRICES; rewrote ROLE1-SALES-ORDER-QUOTE-PRICES-UNMASKED; registered
ROLE1B4A-REPRICE-BELOW-SETTLED (4b) · ROLE1B4A-PURCHASE-JOURNAL-FORGEABLE (APR-6) · ROLE1B4A-RECEIPT-SUPPLIER-CHANGE-AFTER-PRICING
(Batch 3 / 4b) · ROLE1B4A-LANDED-COST-STOCKTAKE-EXCEPTION (Batch 3).

## §2 · Verification — every figure is the script's own exit line

| step | result |
|---|---|
| `db/gate.py --offline` (detached), run 1 | **`GATEOFF_EXIT=4`** — 18 fixtures red, every one because a synthetic role held `data.view_prices` but not the new code: 12 × `APPROVALS_LEVEL1_ROLE_CANNOT_SEE_AMOUNTS` (the switch now wants both codes), 30 `PERMISSION_DENIED\|data.view_purchase_prices`, 40 the preview refusal, 47 / 51 AP rows masked, 110C / 194D3 the reader shapes. 219 ✓ |
| `db/gate.py --offline`, run 2 (after the eighteen fixture updates) | **`GATEOFF_EXIT=0`** — pre-migration phase clean |
| dry run on live (`COMMIT` → probe `SELECT` + `ROLLBACK`) | **`DRY_OWN_EXIT=0`**; self-proof notices printed, every pending document with a decider; 12 new-code grants inside the transaction |
| backup (`db/run_detached.sh`, token BACKUP) | **`BACKUP_EXIT=0`** — `evoltrya-backup-2026-09-25-0143.dump`, 4.7 MB, TOC 6,186 (previous 6,148, floor 5,533); `pg_restore --list` 6,201 lines |
| rehearsal: migration + live proof in one transaction, `ROLLBACK` | **`REHEARSE_OWN_EXIT=0`**, 17 of 17 cells — the proof script tested before the real apply |
| `db/apply_migration.sh` | **`APPLY_OWN_EXIT=0`**. Pre-flight: 16 CREATE FUNCTION (14 replace · 2 new), 4 account codes all `is_system`, no columns added. **Window start 2026-09-25 01:58:16 CST** (the "applied at" line reads 01:57:30) |
| `NOTIFY pgrst, 'reload schema'` · `npm run types:gen` | `TYPES_OWN_EXIT=0`; one addition: `pricing_formula_terms_visible` |
| `npx tsc --noEmit` | `TSC_OWN_EXIT=0` |
| `npm run build` | `BUILD_OWN_EXIT=0` |
| `db/gate.py` full (detached) | **`GATE_EXIT=0`**, 496 s wall clock: rebuildable ✓ · mirrors vs live ✓ (`NO DIFFERENCES`) · fixtures ✓ (**222 passed, 0 failed**, 219 included) · anon surface ✓ (live ⊆ baseline, 327); B2 allowlist 9, 0 unchecked callable definers |
| `node scripts/check-i18n.mjs` | `I18N_OWN_EXIT=0` |
| `node scripts/check-error-swallowing.mjs` | `SWALLOW_OWN_EXIT=0` — 0 unallowed |
| smoke (`db/run_detached.sh`, token SMOKE, `--timeout 2400`, started 02:09:50) | **`SMOKE_EXIT=0`** at 02:20:38: 235 routes + probes, **253 ok · 7 skipped (no data) · 0 FAILED**; 228 timed routes, 505.5 s, median 2,086 ms. **Clean-up, read at 02:21:04 as `postgres` from base tables:** `smoke-%` users **0** · `probe-%` / `fixture-%` / `fx%` roles **0** · orphan grants (no user / no role) **0 / 0** · `ZZ-SMOKE-%` employees **0** · `idle in transaction` **0**; `.ephemeral/` empty; no smoke or `next dev` process left. The pre-run scratch-row report listed the same 6 stale `ZZ-SMOKE-*` rows as earlier cuts (report-only, pre-existing) |

## §3 · Live proof

**Script:** `db/scripts/2026-09-25-role1b4a-live-proof.sql`. One transaction, `ROLLBACK`, run as `postgres` (`rolbypassrls = t`);
each cell sets `request.jwt.claims` to a real account and runs under `SET LOCAL ROLE authenticated`.
**Result: `PROOF_OWN_EXIT=0`, 17 of 17 cells**, finished 02:21:15 CST (inside the window, after the smoke).

| account | cell | result |
|---|---|---|
| fusheng@ (warehouse) | `inbound_batches_masked` IN-2026-0011 (view) | unit price **150.0000** — visible since this cut |
| fusheng@ | `price_history_masked` IN-2026-0011 (view) | 1 of 1 rows carry a price |
| fusheng@ | `output_batch_valuation` (view) | 14 rows, **0** with a unit cost — valuation stays on `view_prices` |
| fusheng@ | price IN-2026-0153 · reprice from committed terms | `PERMISSION_DENIED\|action.price_receipts` ×2 |
| fusheng@ | desk receipt **with** a price | `PERMISSION_DENIED\|action.price_receipts`; receipts for that supplier 7 → 7 (nothing written) |
| sandra@ (cco) · phua@ (cto) | price IN-2026-0153 | `PERMISSION_DENIED\|action.price_receipts` ×2 |
| chooer@ (finance) | price IN-2026-0153 at 2 SGD | **JE-2026-0080**; 2000 credit +1,360.00 = 680 × 2 (inside the transaction) |
| chooer@ | `reverse_journal_entry` on that entry | `JE_REVERSE_USE_SOURCE_PATH\|JE-2026-0080\|purchase` |
| chooer@ | direct INSERT into `price_history` | `42501` row-level security |
| chooer@ | call `reprice_inbound_batch` directly | `42501 permission denied for function reprice_inbound_batch` |
| vince@ (gm) | `inbound_batches_masked` IN-2026-0011 (view) | 150.0000 — nobody sees one cell less |
| tim@ (cfo) | `list_ledger_reconciliation()` | `ap=answered ar=answered` |
| postgres | `approval_deciders` for `approve_purchase_order` | level 1: chooer@, tim@ · level 2: tim@ |

JE-2026-0080 existed only inside the rolled-back transaction (the same number PAYROLL-APR-1's proof consumed and rolled back).
**What this proof is and is not:** refusals and read-backs as the real accounts, inside a transaction that was rolled back. No human
walk has happened (the standing ruling: the whole chain is walked once after APR-6).

### Before / after

**Script:** `db/scripts/2026-09-25-role1b4a-readings.sql`, which states the identity for every part.
**Timing:** before at 01:43:08 CST; after at 02:21:28 CST (after the migration, the smoke and the proof's ROLLBACK).
**`diff` of the two outputs: only the read time, the two new codes' holders, and the eleven roles / seven accounts that gained them.**

| reading | identity · object | before | after |
|---|---|---:|---:|
| `approvals_enabled` / l1 / l2 / threshold | postgres · base `finance_settings` | t / finance / cfo / 1000 | **t / finance / cfo / 1000** |
| pending: claims submitted · leave · medical submitted · medical approved-unpaid · reviews · work orders · stocktakes · POs · payment requests · payroll requests | postgres · base | 1 · 2 · 0 · 1 · 0 · 0 · 5 · 0 · 0 · 0 | **the same — nothing new pending on live** |
| `approval_log` · `journal_entries` · payroll entries | postgres · base | 14 · 82 · 4 | **14 · 82 · 4** |
| account 1100 · 1200 · 2000 · 2200 · 2300 · 2400 · 5000 (debit − credit) | postgres · base `journal_lines` | 43,002.12 · 61,387.92 · −376,404.42 · −1,597.47 · 4,677.00 · 156.00 · 809.14 | **the same** |
| `price_history` · priced receipts / all receipts · `purchase` entries | postgres · base | 14 · 12 / 24 · 10 | **14 · 12 / 24 · 10** |
| `data.view_purchase_prices` holders | postgres · base `role_permissions` | (code absent) | admin auditor cco cfo cto finance gm procurement sales **warehouse** |
| `action.price_receipts` holders | postgres · base | (code absent) | **admin finance** |
| `data.view_prices` holders | postgres · base | admin auditor cco cfo cto finance gm procurement sales | **the same** |
| codes per role (n): admin · auditor · cco · cfo · cto · employee · finance · gm · hr · operations · procurement · sales · warehouse | postgres · base | 52 · 19 · 36 · 29 · 31 · 0 · 34 · 20 · 7 · 15 · 15 · 16 · 14 | **54 · 20 · 37 · 30 · 32 · 0 · 36 · 21 · 7 · 15 · 16 · 17 · 15** (employee, hr, operations md5 identical) |
| unrevoked grants | postgres · base `user_roles` | admin@ admin · chooer@ finance · fusheng@ warehouse · phua@ cto · sandra@ cco · tim@ cfo · vince@ gm | **the same** |
| `ap_open_items` n · Σ | tim@ · **view** | 16 · 416,988.32 | **16 · 416,988.32** |
| `ar_open_items` n · Σ | tim@ · **view** | 10 · 57,545.87 | **10 · 57,545.87** |
| list-vs-ledger AP: list / ledger / **unexplained** | tim@ · `list_ledger_reconciliation()` | 416,988.32 / 376,404.42 / **0.00** | 416,988.32 / 376,404.42 / **0.00** |
| list-vs-ledger AR: list / ledger / **unexplained** | tim@ · same | 57,545.87 / 43,002.12 / **0.00** | 57,545.87 / 43,002.12 / **0.00** |
| `current_user_permissions()`: admin@ · chooer@ · fusheng@ · phua@ · sandra@ · tim@ · vince@ | each account as itself | 52 · 34 · 14 · 31 · 36 · 29 · 20 | **54 · 36 · 15 · 32 · 37 · 30 · 21** |

**Pending documents and their deciders** (the migration's own proof, by person): CLM-2026-0004 → tim@ · LV-2026-0001 / 0003 →
admin@, tim@ · MC-2026-0001 (pay) → admin@, chooer@ · ST-2026-0082…0086 → chooer@, fusheng@, phua@, sandra@.
**No pending document is left without a decider, and nothing new is pending on live.**

## §4 · What each person gains and loses

- **Fu Sheng (warehouse):** **gains** the purchase code — receipt unit prices, price history and assay old / new prices on the
  receipt screens (POs, formulas and AP ageing stay closed: no purchasing / pricing / finance view code). **Loses** pricing and repricing
  receipts, reprice from committed terms, a desk receipt with a price (the box is now disabled with the reason) and the direct
  `price_history` insert. Still creates receipts without a price.
- **Sandra (cco) · Phua (cto):** lose pricing receipts (they had it through `inbound.edit`). Phua still applies assays — which still
  reprice and post, because he sees purchase prices; that price becomes a request in 4b.
- **Choo Er (finance):** gains `action.price_receipts`; prices exactly as before, in one step, **without approval until 4b**. Loses
  reversing a receipt-pricing entry from the journal screen and the direct `price_history` insert.
- **Tim as tim@ · Vince (gm) · the auditor role:** gain the purchase code; no visible change. **Tim as admin@:** gains both new codes.
- **Unheld procurement / sales roles:** gain the purchase code; procurement loses pricing (it held `inbound.edit`).

## §5 · The broken window — started, end PENDING

**Start: 2026-09-25 01:58:16 CST** (`db/apply_migration.sh`'s own line, also in `db/migration-windows.tsv`; its "applied at" line
reads 01:57:30). ~~**End: PENDING — Tim reads it from Vercel.**~~ **Closed with bounds in § Batch 4b §W:** end between 02:22:56
(measured, the push) and 07:37:43 (derived, first live read after Tim's confirmation) — **24 min 40 s to 5 h 39 min 27 s.**

What the old app does against the new database (approvals ON):
- **Only Choo Er (and admin@) can price a receipt.** The old pricing panel and desk form show their price inputs to everyone:
  Sandra, Phua and Fu Sheng get `PERMISSION_DENIED|action.price_receipts` in the shared fallback sentence; a desk receipt **with**
  a price from them is refused whole (nothing written) — leaving the box empty still creates it. "Reprice from content" the same.
- **Fu Sheng sees receipt prices** on the old receipt page too — the ruled outcome, arriving early: the data now comes back
  unmasked for him, and the old `MaskedValue` says "Restricted" only when the value is null, so the old panel shows the numbers.
- Reversing a receipt-pricing entry from the journal screen is refused by name; the old copy for `JE_REVERSE_USE_SOURCE_PATH`
  does not mention receipt pricing — the deployed copy does.
- **Unaffected:** approvals of every kind (no chain, switch or policy touched; nothing pending changed), every payment path,
  Phua's assay application, Choo Er's pricing, every other screen (the smoke above ran the new code against the new database).

## §6 · Commit, push, three SHAs

Reported in the hand-back message: `HEAD`, `origin/main` and `git ls-remote origin main` as full 40-character SHAs
(a commit cannot carry its own hash). Deployment is Tim's to read; the window's end stays PENDING until he does.
**Next cut: ROLE-1 Batch 4b — receipt-pricing approval** (`docs/forward-queue.md` item 6); then ROLE-1 Batch 3.

# Batch 4b — a receipt price reaches the ledger only when the CFO approves it (2026-09-25)

**Opening gate:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `273297d410cfab0459029cebf88106845c051b12`
(ROLE-1 Batch 4a). **Approvals were ON and stayed ON.** Every figure below is a script's own exit line or a query named with its
identity. The matrix lines are `docs/role-matrix.md` §8 (receipt pricing · assay application); the approvals effects are
`docs/approvals.md` §3n.

## §W · Batch 4a's broken window — closed with bounds, labelled by kind

Tim confirmed the Batch 4a deploy on 2026-09-25, before this session began, and has no tighter Vercel reading to add.

| | time (CST) | kind |
|---|---|---|
| start | 2026-09-25 01:58:16 | `db/apply_migration.sh`'s own line (`db/migration-windows.tsv`) |
| end, lower bound | 02:22:56 | **measured**: the push moved `origin/main` → `273297d4` (`git reflog show --date=iso refs/remotes/origin/main`) — no deploy can precede it |
| end, upper bound | 07:37:43 | **derived**: this session's first live read, database clock `now()` as `postgres`, taken after Tim's "deployed" confirmation had arrived — **a relayed confirmation, not a measurement of Vercel** |

**Window: at least 24 min 40 s, at most 5 h 39 min 27 s.** The upper bound is wide because this session began hours after the
deploy; it is a bound, not a measurement. Also written into § Batch 4a §5 above.

## §0 · Step 0 (grilling) and Tim's answers

The shape was ruled at the Batch 4 grilling (Q2–Q8, above); the Batch 4b grilling asked only what those rulings left open.
**What grilling found** (read as `postgres`, `rolbypassrls = t`, base tables, `relkind = 'r'` checked, 07:37–07:42 CST; code from
the mirrors):
1. **admin@ and tim@ are one person** (`account_person()` → `4737faa9…` for both), and tim@ is level 2's only real holder. admin@
   holds `action.price_receipts` and `action.apply_assay`, so a request it raised could never be decided — and, through
   `blocks_disable`, would keep approvals from being switched off. Nothing refused it at submit (`APPROVALS_CHAIN_HAS_NO_APPROVER`,
   the only decider refusal in `db/functions`, guards only the switch). Payroll requests have the same gap.
2. **The Q8 gate was written two ways** (the brief: `{data.view_purchase_prices}`; ROLE-1.md Q8: `module.inbound.view +
   data.view_purchase_prices`).
3. **"final" is the receipt's `pricing_status`**, promoted by `apply_assay_result` when the applied assay `is_final`; both
   `pricing_status` and `assay_results.is_final` were directly writable by any `module.inbound.edit` holder.
4. **Hand-entered metal content** lives in `inbound_batch_metals` (RLS write on `inbound.edit`; the only guard refused source
   `assay`); `committed_terms_price()` reads it live. Nothing froze supplier / PO / PO line either.
5. **The engine takes the rate on the day it runs** and refuses a supplied one — so |Δ| at submit is an estimate, and the posting
   uses the approval day's rate.
6. **Nothing writes `'unpriced'`**; the six unpriced live receipts read `provisional`, and the `batch_unpriced` reminder can never fire.
7. **Unapplying an assay leaves `pricing_status = 'final'`** (consistent with Q3's "leaves an approved price alone").
8. The 0.01 list-vs-ledger rounding gap on a repricing already existed; no UI gate on the edit form, metal panel or delete button.

**Live readings at Step 0:** 15 live receipts — 2 `final` (IN-2026-0156, 0181), 13 `provisional` of which 6 unpriced; 9 soft-deleted;
`price_history` 14 (last 2026-08-31); `purchase` entries 10; 4 inbound assays, all applied and `is_final`, 0 waiting; 0 output assays;
only IN-2026-0029 has payments (30,000.00 of 48,000.00); 0 payment requests, 0 payroll requests. **Nothing could be stranded.**

**Tim accepted all twelve recommendations (2026-09-25):**

| Q | ruling |
|---|---|
| Q1 | refuse at submit (and at the submit inside assay application) `RECEIPT_PRICE_NO_OTHER_DECIDER` when `approval_deciders` at level 2 minus the raiser's person is empty; no refusal when approvals are off; register the payroll gap |
| Q2 | gate `module.inbound.view + data.view_purchase_prices` |
| Q3 | `pricing_status` through functions only; `final` set only in the approve function; register the direct `is_final` edit for Batch 3 |
| Q4 | each log row at its own day's rate; below-settled judged at each day's rate; the fingerprint leaves the rate out |
| Q5 | a superseding assay withdraws the waiting assay request (logged) and raises its own, same transaction |
| Q6 | sources `manual` · `committed_terms` · `desk` · `assay`; every source except `assay` blocks applying an assay |
| Q7 | the raiser's person or any holder of `action.price_receipts` may withdraw; unapplying also withdraws an assay request |
| Q8 | rejecting an assay's request leaves the assay applied, the price unchanged; the page says "assay applied, its price was rejected" |
| Q9 | register the never-written `unpriced` and the dead reminder |
| Q10 | the reminder uses `data.view_purchase_prices` |
| Q11 | `receipt_price_requests`; statuses submitted / approved / rejected / withdrawn; label `IN-… · price #n`; no `code` column; one open per receipt; helpers revoked |
| Q12 | settled = posted allocations + prepayment applications; waiting payment requests not counted |
| standing | every new code also to admin — **this cut adds no permission code**, so there is nothing to grant |

**One build decision, stated for Tim:** "logged" for a system withdrawal (Q3 unapply, Q5 supersede) is written **on the request row**
(`withdrawn_at`, `withdrawn_by`, `withdraw_reason` naming the assay and why), not in `approval_log` — a withdrawal is not a decision
(the payment- and payroll-request rule), and `approval_log`'s decision CHECK has no `withdrawn`.

## §1 · What 4b shipped

**Migration** `db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql`, assembled from the mirrors by
`db/scripts/build_role1b4b_migration.py`. One transaction. Its self-proof asserts, in the same transaction: grants unchanged (no code
added or removed); approvals still ON; pending documents unchanged; `approval_log`, `journal_entries`, `price_history`, receipts
(priced / all / final), metal rows and applied assays unchanged; `receipt_price_requests` empty; both guard triggers present; the new
chain has exactly one row (level 2) and a real decider on live (1 — tim@); every pending document still has a decider who is not
its own party.

| piece | what |
|---|---|
| `receipt_price_requests` (new table) | source `manual` / `committed_terms` / `desk` / `assay`; `submitted → approved` (posted at once), `rejected` (reason), `withdrawn` (reason on the row); frozen `unit_price_ccy` + `currency` + `snapshot`; `amount_base` = \|Δ payable\| (submit-day estimate, rewritten to the posted amount at approval); label `IN-… · price #n`; one open per receipt (unique index); read on `module.inbound.view` + `data.view_purchase_prices`; **no write policy** |
| `receipt_price_submit_internal` | the one submit path: open-request refusal, `RECEIPT_PRICE_NO_OTHER_DECIDER` (approvals on), dry run, `RECEIPT_PRICE_BELOW_SETTLED`, log `submitted` — or, approvals off, post at once + `auto_approved` |
| `decide_receipt_price_request` | gate `module.inbound.view` + `data.view_purchase_prices`; `forbid_self_approval(created_by, NULL, …)`; `require_approver_for(2)`; reject needs a reason; approve re-checks the fingerprint, dry-runs, re-checks below-settled at today's rate, **posts**, logs `approved` with the posted \|Δ\| |
| `withdraw_receipt_price_request` | the raiser's person (`self_leg`) or `action.price_receipts` |
| `receipt_price_post_internal` · `receipt_price_request_dry_run` · `receipt_price_withdraw_internal` · `receipt_price_fingerprint` · `receipt_settled_base` | helpers; EXECUTE revoked from `authenticated` |
| `receipt_price_open` | the label of the waiting request; DEFINER, callable (two INVOKER guards ask it); in both DEFINER allowlists |
| doors | `set_inbound_unit_price` and `reprice_from_committed_terms` submit; `create_inbound_batch` creates unpriced + submits (`desk`); `apply_assay_result` applies in full, refuses under a non-assay request, supersedes a waiting assay request, submits (`assay`), no longer sets `pricing_status`; `unapply_assay_result` withdraws its assay's request; `soft_delete_inbound_batch` refuses while one waits |
| guards | `guard_inbound_batch_price_request` (supplier / PO / PO line / soft delete → `RECEIPT_PRICE_REQUEST_OPEN`; direct `pricing_status` → `PRICING_STATUS_VIA_FUNCTION`) · `guard_inbound_batch_metals_price_request` (any write while one waits) |
| engine | `approval_chain_gates` row · `approval_pending_documents` arm · `approval_log` CHECK + read branch · `record_approval_decision` branch · `operations_now` arm `receipt_price_request_pending` |
| unchanged | the engine `reprice_inbound_batch`; every grant; the switch and policy |

**Screens (en + zh):**
- Receipt page: a request panel inside the pricing section — the waiting request (price asked, current price, estimated change),
  Approve and post / Reject (reason) gated on `data.view_purchase_prices`, Withdraw gated on `action.price_receipts` (or the
  raiser's own account); earlier requests listed; "assay applied, its price was rejected" when the latest request came from the
  still-latest assay and was rejected. While one waits, the price form and "Reprice from content", the supplier field, the metal
  content panel stay visible, disabled, with the reason (the request label). The price button reads **Submit for CFO approval**.
- Inbound list: a "Waiting for the CFO" badge; Delete visible, disabled, with the reason.
- Desk form: the price hint now says the price is submitted to the CFO and the receipt is created unpriced until then.
- Assay detail: a line under Apply ("raises a price request for the CFO"), and the assay's request label and status once applied;
  the applied-price block recognises the new price-history note.
- Dashboard reminder `receipt_price_request_pending` → the receipt page; approvals log subject label "Receipt pricing".
- Refusal copy: every new code in the pricing, assay and deletion translators.

**Fixtures:** new **220** (arms A–N, one fault injection: disable the metal-content guard and the manual write goes through).
**Updated because a new chain needs a level-2 holder of its gate (no assertion changed):** 35 · 127 · 151 · 202 · 203 · 204 · 205 ·
206 · 210 · 211 · 218 (the PAYROLL-APR-1 eleven); 205's own-document-gap count 5 → 6; 111 lists the 38th reminder arm.
`docs/dashboard-arm-inventory.md` has the new arm's rows.

**Known issues:** closed ROLE1B4A-REPRICE-BELOW-SETTLED; updated ROLE1B4A-RECEIPT-SUPPLIER-CHANGE-AFTER-PRICING (frozen while a request
waits); registered ROLE1B4B-PAYROLL-RAISER-NO-DECIDER · ROLE1B4B-ASSAY-IS-FINAL-DIRECT-EDIT (Batch 3) · ROLE1B4B-UNPRICED-NEVER-WRITTEN.

## §2 · Verification — every figure is the script's own exit line

| step | result |
|---|---|
| `db/gate.py --offline` (detached), runs 1–3 | run 1 **`GATEOFF_EXIT=4`**: 13 fixtures red — 11 × `APPROVALS_CHAIN_HAS_NO_APPROVER\|decide_receipt_price_request` (level-2 roles lacked `module.inbound.view`), 111 (37 → 38 arms), 220 (`journal_lines.entry_id`, a column-name slip in the fixture). Run 2 **`GATEOFF_EXIT=4`**: 205 (own-document gaps 5 → 6). Run 3 **`GATEOFF_EXIT=0`** |
| dry run on live (`COMMIT` → probe `SELECT` + `ROLLBACK`) | **`DRY_OWN_EXIT=0`**; self-proof notices printed; 1 decider for the new chain; every pending document with a decider |
| rehearsal: migration + zzz grants + live proof, one transaction, `ROLLBACK` | run 1 **`REHEARSE_OWN_EXIT=0`**, but cell X1 printed NULLs — the check was not NULL-safe, and no assay request was raised (IN-2026-0181's 30-day average had no quotes: price −0.80 USD/kg ≤ 0). Proof fixed (NULL-safe checks; today's USD rate and ni/co/li quotes inserted inside the transaction). Run 2 **`REHEARSE_OWN_EXIT=0`**, 25 of 25 |
| `db/gate.py --offline`, run 4 (after the screens) | **`GATEOFF_EXIT=0`**, 50 s |
| backup (`db/run_detached.sh`, token BACKUP) | **`BACKUP_EXIT=0`** — `evoltrya-backup-2026-09-25-0923.dump`, 4.7 MB, TOC 6,187 (previous 6,186, floor 5,567); `pg_restore --list` 6,202 lines |
| `db/apply_migration.sh` | **`APPLY_OWN_EXIT=0`**. Pre-flight: 21 CREATE FUNCTION (9 replace · 12 new), no account codes, no masked columns. **Window start 2026-09-25 09:34:00 CST** (the "applied at" line reads 09:33:21) |
| `NOTIFY pgrst, 'reload schema'` · `npm run types:gen` | `TYPES_OWN_EXIT=0` (+228 lines) |
| `npx tsc --noEmit` | `TSC_OWN_EXIT=0` |
| `npm run build` | run 1 **`BUILD_OWN_EXIT=1`**: `check-auth-error-swallowing` — the receipt page read `auth.getUser()` inside a `Promise.all` without binding its `error`; run 2 **`BUILD_OWN_EXIT=1`**, same check (reading `.error` off the `Promise.all` result is not a form it recognises); moved the call out and destructured `error` (an unreadable session falls back to the permission for Withdraw) → run 3 **`BUILD_OWN_EXIT=0`**, `TSC_OWN_EXIT=0` |
| `db/gate.py` full (detached) | **`GATE_EXIT=0`**, 428 s: rebuildable ✓ · mirrors vs live ✓ (`NO DIFFERENCES`) · fixtures ✓ (**223 passed, 0 failed**, 220 included) · anon surface ✓ (live ⊆ baseline, 327); B2 allowlist 10 (adds `receipt_price_open`), 0 unchecked callable definers |
| `node scripts/check-i18n.mjs` | `I18N_OWN_EXIT=0` (two new enumerable prefixes read `receipt_price_requests`' CHECKs) |
| `node scripts/check-error-swallowing.mjs` | `SWALLOW_OWN_EXIT=0` — 0 unallowed |
| smoke (`db/run_detached.sh`, token SMOKE, `--timeout 2400`) | **`SMOKE_EXIT=0`**: 235 routes + probes, **253 ok · 7 skipped (no data) · 0 FAILED**; 228 timed routes, 509.2 s, median 2,053 ms. **Clean-up, read at 09:56:16 as `postgres` from base tables:** `smoke-%` users **0** · `probe-%` / `fixture-%` / `fx%` roles **0** · orphan grants (no user / no role) **0 / 0** · `ZZ-SMOKE-%` employees **0** · `idle in transaction` **0** · `receipt_price_requests` **0**; `.ephemeral/` empty; no smoke or `next dev` process left |

## §3 · Live proof

**Script:** `db/scripts/2026-09-25-role1b4b-live-proof.sql`. One transaction, `ROLLBACK`, run as `postgres` (`rolbypassrls = t`);
each cell sets `request.jwt.claims` to a real account and runs under `SET LOCAL ROLE authenticated`.
**Result: `PROOF_OWN_EXIT=0`, 25 of 25 cells**, started 09:56:28 CST (inside the window, after the smoke). Set-up inside the
transaction, gone with it: a USD `tt_sell` rate for today and ni / co / li quotes for today (live has neither; without them the
assay arm cannot price).

| account | cell | result |
|---|---|---|
| chooer@ | price IN-2026-0153 @ 2 SGD | **submitted** (IN-2026-0153 · price #1) |
| postgres · tim@ | while it waits | unit_price NULL · `journal_entries` 82 → 82 · 2000 unchanged · AP list 416,988.32 → 416,988.32 · ledger 376,404.42 → 376,404.42 (tim@, `list_ledger_reconciliation()`) |
| tim@ | `operations_now` (view) | 1 `receipt_price_request_pending` row |
| postgres | `approval_log` · `approval_deciders` | submitted, level 2, 1,360.00 SGD · deciders: **tim@ only** |
| chooer@ · sandra@ · fusheng@ · chooer@ | second request · direct supplier change · manual metal content · soft delete | `RECEIPT_PRICE_REQUEST_OPEN\|IN-2026-0153\|IN-2026-0153 · price #1` ×4 |
| chooer@ · admin@ · sandra@ · vince@ | approve | `SELF_APPROVAL_FORBIDDEN\|raiser` · `APPROVAL_NOT_AUTHORISED\|2\|cfo` ×3 |
| tim@ | reject without a reason | `RECEIPT_PRICE_REQUEST_REJECT_REASON_REQUIRED` |
| tim@ | approve after the frozen facts were changed (snapshot altered as postgres) | `RECEIPT_PRICE_CHANGED_SINCE_REQUEST`; `journal_entries` still 82 |
| tim@ | ★ **approve** | approved, **JE-2026-0080**, unit_price 2.0000 |
| postgres | balances (debit − credit) | 2000 −376,404.42 → **−377,764.42** · 1200 61,387.92 → 61,387.92 · 5000 809.14 → **2,169.14** (remaining 0, so the whole Δ is the consumed share) |
| tim@ | list vs ledger | AP list 416,988.32 → **418,348.32 (+1,360.00)** · ledger 376,404.42 → **377,764.42 (+1,360.00)** · unexplained **AP 0.00 · AR 0.00** |
| postgres | `approval_log` | approved, level 2, 1,360.00, `self_decided = false` |
| chooer@ | IN-2026-0029 @ 7 SGD | `RECEIPT_PRICE_BELOW_SETTLED\|IN-2026-0029\|28000.00\|30000.00` |
| admin@ | price IN-2026-0179 | `RECEIPT_PRICE_NO_OTHER_DECIDER\|IN-2026-0179` (tim@ is the same person) |
| sandra@ | direct `pricing_status` write | `PRICING_STATUS_VIA_FUNCTION\|IN-2026-0179` |
| phua@ | record + apply a new assay on IN-2026-0181 | content applied; **IN-2026-0181 · price #1 submitted @ 6.06 USD/kg**, raised by phua@; nothing posted; unit_price still 8.1152 |
| phua@ | unapply it | request **withdrawn**, reason "Assay ASY-2026-0005 unapplied: ROLE1B4B live proof" |

JE-2026-0080 and ASY-2026-0005 existed only inside the rolled-back transaction. **What this proof is and is not:** one full lifecycle
(submit → CFO approves → posted) plus refusals and read-backs as the real accounts, inside a transaction that was rolled back. No
human walk has happened (the standing ruling: the whole chain is walked once after APR-6).

### Before / after

**Script:** `db/scripts/2026-09-25-role1b4b-readings.sql`, which states the identity for every part.
**Timing:** before at 09:32:57 CST (after the backup, before the migration); after at 09:56:34 CST (after the migration, the smoke
and the proof's ROLLBACK). **`diff` of the two outputs: only the read time, `receipt_price_requests` appearing (relkind `r`), and its
two counts going from "absent" to 0 / 0.**

| reading | identity · object | before | after |
|---|---|---:|---:|
| `approvals_enabled` / l1 / l2 / threshold | postgres · base `finance_settings` | t / finance / cfo / 1000 | **t / finance / cfo / 1000** |
| pending: claims submitted · leave · medical submitted · medical approved-unpaid · reviews · work orders · stocktakes · POs · payment requests · payroll requests | postgres · base | 1 · 2 · 0 · 1 · 0 · 0 · 5 · 0 · 0 · 0 | **the same** |
| `receipt_price_requests` rows / pending | postgres · base | (table absent) | **0 / 0** — nothing pending on live |
| `approval_log` · `journal_entries` · payroll entries | postgres · base | 14 · 82 · 4 | **14 · 82 · 4** |
| account 1100 · 1200 · 2000 · 2200 · 2300 · 2400 · 5000 (debit − credit) | postgres · base `journal_lines` | 43,002.12 · 61,387.92 · −376,404.42 · −1,597.47 · 4,677.00 · 156.00 · 809.14 | **the same** |
| `price_history` · priced / all receipts · `purchase` entries | postgres · base | 14 · 12 / 24 · 10 | **the same** |
| live receipts by `pricing_status` (priced) · applied assays · metal rows | postgres · base | final 2 (2) · provisional 13 (7) · 4 · 19 | **the same** |
| codes per role (n): admin · auditor · cco · cfo · cto · employee · finance · gm · hr · operations · procurement · sales · warehouse | postgres · base `role_permissions` | 54 · 20 · 37 · 30 · 32 · 0 · 36 · 21 · 7 · 15 · 16 · 17 · 15 | **the same, md5 identical** |
| unrevoked grants | postgres · base `user_roles` | admin@ admin · chooer@ finance · fusheng@ warehouse · phua@ cto · sandra@ cco · tim@ cfo · vince@ gm | **the same** |
| `ap_open_items` n · Σ | tim@ · **view** | 16 · 416,988.32 | **16 · 416,988.32** |
| `ar_open_items` n · Σ | tim@ · **view** | 10 · 57,545.87 | **10 · 57,545.87** |
| list-vs-ledger AP: list / ledger / **unexplained** | tim@ · `list_ledger_reconciliation()` | 416,988.32 / 376,404.42 / **0.00** | 416,988.32 / 376,404.42 / **0.00** |
| list-vs-ledger AR: list / ledger / **unexplained** | tim@ · same | 57,545.87 / 43,002.12 / **0.00** | 57,545.87 / 43,002.12 / **0.00** |
| `current_user_permissions()`: admin@ · chooer@ · fusheng@ · phua@ · sandra@ · tim@ · vince@ | each account as itself | 54 · 36 · 15 · 32 · 37 · 30 · 21 | **the same, md5 identical** |

**Pending documents and their deciders** (the migration's own proof, by person): CLM-2026-0004 → tim@ · LV-2026-0001 / 0003 →
admin@, tim@ · MC-2026-0001 (pay) → admin@, chooer@ · ST-2026-0082…0086 → chooer@, fusheng@, phua@, sandra@.
**No pending document is left without a decider, and nothing is pending on live.**

## §4 · What each person gains and loses (approvals on)

- **Choo Er (finance):** the pricing panel, "Reprice from content" and the desk-form price now **submit a request**; the price reaches
  the ledger only when Tim approves. She can withdraw any waiting request; she can never approve one. While one waits on a receipt,
  she cannot change its price, supplier, metal content, or delete it.
- **Phua (cto):** applying an assay still updates content at once, but the price becomes a request waiting for Tim (raised by him);
  unapplying withdraws it; he can withdraw his own. Applying under a Finance request is refused.
- **Tim as tim@ (cfo):** gains the dashboard reminder and Approve and post / Reject on the receipt page — the only person who can
  decide a receipt price. **Tim as admin@:** cannot raise a receipt price or apply a priced assay while approvals are on
  (`RECEIPT_PRICE_NO_OTHER_DECIDER` — the same person as the only decider).
- **Sandra (cco) · Fu Sheng (warehouse):** nothing new to do; while a request waits on a receipt they cannot change its supplier or
  metal content, or delete it. Both see the waiting request (they hold the purchase code).
- **Vince (gm):** sees the waiting request and the reminder; cannot decide.

## §5 · The broken window — started, end PENDING

**Start: 2026-09-25 09:34:00 CST** (`db/apply_migration.sh`'s own line, also in `db/migration-windows.tsv`; its "applied at" line
reads 09:33:21). ~~**End: PENDING — Tim reads it from Vercel.**~~ **Closed with bounds in § Batch 3 §W:** end between 09:58:28
(measured, the push) and 10:37:46 (derived, first live read after Tim's confirmation) — **24 min 28 s to 1 h 03 min 46 s.**

What the old app does against the new database (approvals ON):
- **Choo Er's old pricing panel and desk form silently file a request** where she expects a posting: the old screen says the price
  was saved, reloads, and the receipt still shows no new price and the old page has no request panel to show why. Nothing is posted;
  the request waits for Tim. The same for "Reprice from content".
- **Phua's assay application stops posting:** content applies, a request waits; the old assay page shows no price change.
- **Nobody can approve from a screen:** the old app has no request panel — Tim can only decide once the new app is live. Requests
  raised in the window stay pending (not stranded: tim@ is their decider) and block switching approvals off until decided.
- Freeze refusals (supplier, metal content, delete, second price) arrive in the old copy as the raw code inside the generic
  save-error sentence; `PRICING_STATUS_VIA_FUNCTION` likewise.
- **Unaffected:** every other approval chain, every payment path, every other screen (the smoke above ran the new code against the
  new database).

## §6 · Commit, push, three SHAs

Reported in the hand-back message: `HEAD`, `origin/main` and `git ls-remote origin main` as full 40-character SHAs
(a commit cannot carry its own hash). Deployment is Tim's to read; the window's end stays PENDING until he does.
**Next cut: ROLE-1 Batch 3** (`docs/forward-queue.md` item 7).

# Batch 3 — Step 0, and Batch 3a: the counter never posts; four registered gaps close (2026-09-25)

**Opening gate:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `3f5217745172c0a21ecd32217fc7d5cabc89b82a`
(ROLE-1 Batch 4b). **Approvals were ON and stayed ON.** Every figure below is a script's own exit line or a query named with its
identity. The matrix lines are `docs/role-matrix.md` §8, §9, §10, §11, §13; the approvals effects are `docs/approvals.md` §3o.

## §W · Batch 4b's broken window — closed with bounds, labelled by kind

Tim confirmed the Batch 4b deploy on 2026-09-25, before this session began.

| | time (CST) | kind |
|---|---|---|
| start | 2026-09-25 09:34:00 | `db/apply_migration.sh`'s own line (`db/migration-windows.tsv`) |
| end, lower bound | 09:58:28 | **measured**: the push moved `origin/main` → `3f521774` (`git reflog show --date=iso refs/remotes/origin/main`) — no deploy can precede it |
| end, upper bound | 10:37:46 | **derived**: this session's first live read, database clock `now()` as `postgres`, taken after Tim's "deployed" confirmation had arrived — **a relayed confirmation, not a measurement of Vercel** |

**Window: at least 24 min 28 s, at most 1 h 03 min 46 s.** Also written into § Batch 4b §5 above.

**Recorded ruling (Tim, 2026-09-25):** Batch 4b's choice to record a request's withdrawal **on the request row** (`withdrawn_at` ·
`withdrawn_by` · `withdraw_reason`), not in `approval_log`, stands — consistent with payment and payroll requests.

## §0 · Step 0 (grilling) and Tim's answers

**What grilling found** (live read as `postgres`, `rolbypassrls = t`, base tables, `relkind = 'r'` checked, 10:37–10:52 CST; code read
from the mirrors by three surveys and spot-checked on live):
1. **The stocktake four-eyes rule could be walked around.** `stocktakes` / `stocktake_lines` carried INSERT and UPDATE policies on
   `module.stocktakes.edit`: any holder could write `status = 'posted'` directly, rewrite `created_by` (the leg four-eyes reads), and add
   or change lines on a posted stocktake (the open-status check lived only in `saveCount`).
2. **Nobody recorded who counted.** `stocktake_lines.created_by` had no default, came from the client, and a recount's upsert
   overwrote it with the last saver.
3. **The landed-cost exception was dead code; the real leak was elsewhere.** `post_stocktake` reads `_all`, the gated reader's only
   caller already required `data.view_prices`, and EXECUTE was revoked — but `batch_freight_base` / `batch_processing_cost_base` gave
   real numbers to anyone with `inbound.view`.
4. **Fixture 174 arm E never tested the mirror** — it re-installed its own copy of the function (with the `OR stocktakes.edit` branch)
   and asserted against that copy (found when the offline gate stayed green after the branch was removed).
5. **Processing had the same direct-write bypass**; warehouse lacks `module.materials.view` (processing pages read `materials`).
6. **COD void and shipping were already where the interim ruling wants them** (`action.issue_cod` = admin · warehouse;
   `module.sales.edit` = admin · cco · sales).
7. **The "nobody but the raiser can decide" gap was live for payment requests too** — admin holds `module.finance.edit`.
8. The brief omitted goods-receipt creation (matrix §8 says B3).

**Live readings at Step 0:** 5 open stocktakes (ST-2026-0082…0086), all opened by admin@, **0 lines each**; 4 posted, 1 cancelled;
`stocktake_lines` 4 (all on posted stocktakes). Work orders: WO-2026-0001 only, `released`, 1 live run, `created_by` not a current
account; **0 drafts**. Runs: 10 committed, 4 reversed. CODs: 2 issued, 1 pending. **9 priced live receipts, none with a waiting price
request** — every one could change supplier; of the 8 on a PO, **0** differ from the PO's supplier (no existing damage); IN-2026-0029
carries the only settlement (a prepayment application). Nothing could be stranded.

**Tim's answers (2026-09-25) — the recommendations, with Q1 changed:**

| Q | ruling | where |
|---|---|---|
| Q1 | goods-receipt creation → warehouse **is in scope**: `action.receive_goods` → warehouse · admin, gating `create_inbound_batch` and `receive_inbound_batch_against_po`; record who loses it | 3b |
| Q2 | (A) append-only `stocktake_counts`, `counted_by` set by the function; posting refuses the opener (`SELF_APPROVAL_FORBIDDEN\|raiser`) and every counter (`STOCKTAKE_COUNTER_CANNOT_POST\|<code>`), per person | 3a |
| Q3 | drop the direct policies; `open_stocktake` and `record_stocktake_count` as SECURITY DEFINER | 3a |
| Q4 | opening under `action.stocktake_count`; cancelling stays on `module.stocktakes.edit`; count → warehouse · admin, post → finance · admin | 3a |
| Q5 | remove the dead branch; the two cost readers return NULL without `data.view_prices`; the page says "Restricted"; flip fixture 174 E | 3a |
| Q6 | amend / cancel / close = `action.wo_create` or `processing.edit`; register "amending a released WO does not send it back" | 3b · registered |
| Q7 | close the processing direct writes, after confirming no screen inserts directly | 3b |
| Q8 | three pages read `material_lookup`; no `module.materials.view` | 3b |
| Q9 | `action.batch_write_off` · `action.processing_rollback` → warehouse · admin; no change for COD void and shipping | 3b |
| Q10 | always refuse a direct `is_final` change (`ASSAY_FINAL_THROUGH_FUNCTION_ONLY`) | 3a |
| Q11 | refuse by name on every path (`RECEIPT_PRICED_SOURCE_FROZEN\|<code>`); register a correction lifecycle | 3a · registered |
| Q12 | one shared helper in `submit_payroll_request` (`PAYROLL_NO_OTHER_DECIDER`) and the six payment-request submits; register POs and expense claims | 3a · registered |
| Q13 | **split**: this session builds and ships 3a and stops at the push; 3b is the next cut | — |
| standing | every new code also to `admin`, same migration | 3a |

# Batch 3a — shipped (2026-09-25)

## §1 · What 3a shipped

**Migration** `db/migrations/2026-09-25-role1b3a-the-counter-never-posts.sql`, assembled from the mirrors by
`db/scripts/build_role1b3a_migration.py`. One transaction. Its self-proof asserts: grants = before + exactly the four ruled rows;
`action.stocktake_count` held by exactly `admin warehouse`, `action.stocktake_post` by exactly `admin finance`; approvals still ON;
pending documents unchanged; `approval_log`, `journal_entries`, stocktakes, stocktake lines, receipts (priced / all), assays (final /
applied), payment and payroll requests unchanged; `stocktake_counts` empty; no stocktake write policy left; the four guard triggers
present; the landed-cost predicate no longer names `module.stocktakes.edit`; `post_stocktake` gated on `action.stocktake_post`; every
pending document still has a decider who is not its own party (the stocktake arm now asks `action.stocktake_post` minus opener and counters).

| piece | what |
|---|---|
| codes | `action.stocktake_count` → warehouse · admin; `action.stocktake_post` → finance · admin (catalogue 55 → 57). `module.stocktakes.edit` re-described: cancel only |
| `stocktake_counts` (new) | one row per count and recount: line, batch, book / counted qty, notes, `counted_by NOT NULL` (the function writes `auth.uid()`), `counted_at`; read on `module.stocktakes.view`; **append-only** (`guard_stocktake_count_append_only`, owner path too); no write policy; anon revoked |
| no direct writes | the four stocktake INSERT / UPDATE policies dropped; `guard_stocktake_direct_write` (statement-level, `row_security_active`) on `stocktakes` · `stocktake_lines` · `stocktake_counts` → `STOCKTAKE_THROUGH_FUNCTION_ONLY` |
| doors | `open_stocktake` (new, `action.stocktake_count`, opener = `auth.uid()`) · `record_stocktake_count` (new, `action.stocktake_count`; open only; one batch; qty ≥ 0; book qty at save time; upsert the line + append a count) · `post_stocktake` (`action.stocktake_post`; opener leg unchanged; counter leg over `stocktake_counts` ∪ line `created_by`) · `cancel_stocktake` unchanged (`module.stocktakes.edit`) |
| gap 1 (Q5) | `inbound_batch_landed_unit_cost`: `data.view_prices` only · `batch_freight_base` / `batch_processing_cost_base`: `data.view_prices AND (…the four codes)` → NULL otherwise · **build decision:** `allocate_processing_costs` reads `batch_freight_base_all` / `batch_processing_cost_base_all` — posted money must not depend on who pressed the button (the repo's own rule), instead of relying on finance happening to hold `view_prices` |
| gap 2 (Q10) | `guard_assay_applied_columns`: a direct UPDATE changing `is_final` → `ASSAY_FINAL_THROUGH_FUNCTION_ONLY` (inbound and output) |
| gap 3 (Q11) | `guard_inbound_batch_price_request` ③: `unit_price` set and supplier / PO / PO line changes → `RECEIPT_PRICED_SOURCE_FROZEN\|<code>`, direct and owner paths; the waiting-request refusal is checked first |
| gap 4 · Q12 | `assert_other_decider(subject, action_function, level, refusal)` (new, DEFINER, EXECUTE revoked, allowlisted in `check_mirrors`); called before any code is minted by `submit_payroll_request` (`PAYROLL_NO_OTHER_DECIDER\|<period>`) and `submit_payment_request` · `submit_payment_reversal_request` · `submit_bank_transfer_request` · `submit_bank_transfer_reversal_request` · `submit_wht_remittance_request` · `submit_wht_remittance_reversal_request` (`PAYMENT_REQUEST_NO_OTHER_DECIDER`). 4b's receipt-price copy is unchanged |

**Screens (en + zh):**
- `/stocktakes`: New stocktake is visible, disabled, naming `action.stocktake_count` for non-holders.
- Stocktake detail: both count lists gated on `action.stocktake_count`; Cancel gated on `module.stocktakes.edit`.
- Review page: Post gated on `action.stocktake_post`, plus a stated reason when the viewer opened or counted it ("You counted on this
  stocktake…"; judged per account on the page, per person in the database); a "Counted by" line lists every counter.
- The quick-count banner on receipt and output pages: gated on `action.stocktake_count`.
- Server actions: `createStocktake` → `open_stocktake`, `saveCount` → `record_stocktake_count` (no direct writes left).
- Receipt edit: the supplier field is locked with the reason once the receipt is priced; the edit action routes pricing-family refusals
  through `localizePricingError`.
- Copy: five stocktake refusals, `postBlockedOpener` / `postBlockedCounter` / `countedBy`, `supplierFrozenPriced`,
  `RECEIPT_PRICED_SOURCE_FROZEN`, `ASSAY_FINAL_THROUGH_FUNCTION_ONLY`, `PAYROLL_NO_OTHER_DECIDER`, `PAYMENT_REQUEST_NO_OTHER_DECIDER`.
- The landed-cost panel already rendered NULL as "Restricted" behind `data.view_prices` — no change needed.

**Fixtures:** new **221** (S1–S11, G2–G4; fault injection S11: drop the direct-write guard and the direct `status = 'posted'` becomes a
silent zero-row "success"). **Changed because a rule changed:** 163 (A/B readers also hold `view_prices`; new A2: an `inbound.view`-only
reader gets NULL; D rewritten — an allocator who reads NULL freight still allocates 750.00) · 174 E (saves the real definition with
`pg_get_functiondef` and restores it, instead of its own copy; E2 now expects a `stocktakes.edit` holder to be refused; the obsolete
E-inj-2 removed — **fault-injected**: putting the `OR stocktakes.edit` branch back turns the offline gate red on 174E2 only,
`GATEOFF_EXIT=4`, then restored) · 182 (receipt created unpriced before a PO is attached) · 204 (finance role gains `action.stocktake_post`) ·
218 (E0: the raiser whose other account is the only level-2 holder is refused at submit; then a second level-2 person is added so the
decide-time `|raiser` check stays tested) · 25 (the line's counter is someone else). `scripts/check-document-registry.mjs`: tables 229 → 230.

**Known issues:** closed ROLE1B4A-LANDED-COST-STOCKTAKE-EXCEPTION · ROLE1B4B-ASSAY-IS-FINAL-DIRECT-EDIT ·
ROLE1B4A-RECEIPT-SUPPLIER-CHANGE-AFTER-PRICING · ROLE1B4B-PAYROLL-RAISER-NO-DECIDER; registered ROLE1B3A-PRICED-RECEIPT-NO-CORRECTION ·
ROLE1B3A-NO-OTHER-DECIDER-PO-EXPENSE · ROLE1B3-AMEND-RELEASED-WO.

## §2 · Verification — every figure is the script's own exit line

| step | result |
|---|---|
| `db/gate.py --offline`, run 1 | **`GATEOFF_EXIT=2`** — the permissions mirror lost a `)` in the edit (a sliced string), replay failed |
| `db/gate.py --offline`, run 2 | **`GATEOFF_EXIT=4`** — 5 fixtures red, each because a rule changed: 163A (`inbound.view` reader now NULL) · 182 (`RECEIPT_PRICED_SOURCE_FROZEN`) · 204F (`PERMISSION_DENIED\|action.stocktake_post`) · 218 (`PAYROLL_NO_OTHER_DECIDER`) · 25 (`STOCKTAKE_COUNTER_CANNOT_POST`); 174 **stayed green** — which exposed finding 4 |
| `db/gate.py --offline`, run 3 | **`GATEOFF_EXIT=0`** (221 included) |
| fault injection on 174 E (offline) | **`GATEOFF_EXIT=4`**, 174E2 only; mirror restored (`cmp` identical) |
| dry run on live (`COMMIT` → probe + `ROLLBACK`) | **`DRY_OWN_EXIT=0`**; catalogue 57, 4 new grants inside the transaction; every pending document with a decider (ST-2026-0082…0086 → chooer@) |
| rehearsal: migration + zzz grants + live proof, one transaction, `ROLLBACK` | run 1: a PL/pgSQL `IF … CASE WHEN … THEN` parse error in the proof script (the IF took the CASE's THEN) → parenthesised; run 2 **`REHEARSE_OWN_EXIT=0`**, 23 of 23. ★ While it replayed the grants file it held the stocktake DDL locks for ~4 min (idle in transaction between round trips); and the proof's `open_stocktake` consumed **ST-2026-0087** from the sequence (sequences do not roll back) |
| backup (`db/run_detached.sh`, token BACKUP) | **`BACKUP_EXIT=0`** — `evoltrya-backup-2026-09-25-1123.dump`, 4.7 MB, TOC 6,231 (previous 6,187, floor 5,568); `pg_restore --list` 6,246 lines |
| `db/apply_migration.sh` | **`APPLY_OWN_EXIT=0`**. Pre-flight: 20 CREATE FUNCTION (14 replace · 6 new, one of them the proof's `pg_temp` helper), 13 account codes all `is_system`, no masked columns. **Window start 2026-09-25 11:31:10 CST** (the "applied at" line reads 11:30:29) |
| `NOTIFY pgrst, 'reload schema'` · `npm run types:gen` | `TYPES_OWN_EXIT=0` (+165 lines) |
| `npx tsc --noEmit` | `TSC_OWN_EXIT=0` |
| `npm run build` | run 1 **`BUILD_OWN_EXIT=2`**: `check-document-registry` — 230 tables declared 229 (the new table; the friction is deliberate); updated → run 2 **`BUILD_OWN_EXIT=0`** |
| `db/gate.py` full (detached) | **`GATE_EXIT=0`**, 431 s: rebuildable ✓ · mirrors vs live ✓ (`NO DIFFERENCES`) · fixtures ✓ (**224 passed, 0 failed**, 221 included) · anon surface ✓ (live ⊆ baseline 327); B2 allowlist 10, 0 unchecked callable definers |
| `node scripts/check-i18n.mjs` | `I18N_OWN_EXIT=0` |
| `node scripts/check-error-swallowing.mjs` | `SWALLOW_OWN_EXIT=0` — 0 unallowed |
| smoke (`db/run_detached.sh`, token SMOKE, `--timeout 2400`, 11:41:07–11:51:57) | **`SMOKE_EXIT=0`**: 235 routes + probes, **253 ok · 7 skipped (no data) · 0 FAILED**; 228 timed routes, 500.6 s, median 2,014 ms. **Clean-up, read at 11:52:32 as `postgres` from base tables:** `smoke-%` users **0** · `probe-%` / `fixture-%` / `fx%` roles **0** · orphan grants (no user / no role) **0 / 0** · `ZZ-SMOKE-%` employees **0** · `idle in transaction` **0** · `stocktake_counts` **0**; `.ephemeral/` empty; no smoke or `next dev` process left |

## §3 · Live proof

**Script:** `db/scripts/2026-09-25-role1b3a-live-proof.sql`. One transaction, `ROLLBACK`, as `postgres` (`rolbypassrls = t`); each cell
sets `request.jwt.claims` to a real account and runs under `SET LOCAL ROLE authenticated`.
**Result: `PROOF_OWN_EXIT=0`, 23 of 23 cells**, started 11:52:45 CST (inside the window, after the smoke).

| account | cell | result |
|---|---|---|
| fusheng@ · chooer@ · admin@ | holds count / post (`current_user_permissions()`) | true/false · false/true · true/true |
| sandra@ · phua@ · chooer@ | open a stocktake | `PERMISSION_DENIED\|action.stocktake_count` ×3 |
| fusheng@ | open **ST-2026-0088**, count IN-2026-0001 at 886 | opener fusheng@; 1 row in `stocktake_counts` |
| sandra@ · fusheng@ | direct `status = 'posted'` · direct line INSERT | `STOCKTAKE_THROUGH_FUNCTION_ONLY` ×2 |
| fusheng@ · sandra@ | post | `PERMISSION_DENIED\|action.stocktake_post` ×2 |
| admin@ | recount, then post | `STOCKTAKE_COUNTER_CANNOT_POST\|ST-2026-0088` (2 count rows) |
| admin@ | post ST-2026-0082 (opened by admin@) | `SELF_APPROVAL_FORBIDDEN\|raiser` |
| chooer@ | ★ **post** ST-2026-0088 | posted; IN-2026-0001 887 → 886; `journal_entries` 82 → 83; 1200 61,387.92 → 61,386.44; 5200 59,732.00 → 59,733.48 (1 × landed 1.48) |
| fusheng@ | count after posting | `STOCKTAKE_NOT_OPEN\|posted` |
| fusheng@ · chooer@ | freight / processing cost of IN-2026-0001 | **NULL** (restricted) · 0 / 0 |
| fusheng@ claims | `inbound_batch_landed_unit_cost` (asked with EXECUTE) | `LANDED_COST_PERMISSION_DENIED\|data.view_prices` |
| fusheng@ | direct `is_final` flip on ASY-2026-0004 | `ASSAY_FINAL_THROUGH_FUNCTION_ONLY` |
| fusheng@ | supplier change: priced IN-2026-0001 · unpriced IN-2026-0153 | `RECEIPT_PRICED_SOURCE_FROZEN\|IN-2026-0001` · OK |
| admin@ | payroll reversal request PAY-2026-0001 · payment request 10.00 to SUP-2026-0003 | `PAYROLL_NO_OTHER_DECIDER\|PAY-2026-0001` · `PAYMENT_REQUEST_NO_OTHER_DECIDER` |
| chooer@ | the same payment request | submitted (tim@ decides it) |
| tim@ | `list_ledger_reconciliation()` inside the transaction | unexplained AP 0.00 · AR 0.00 |

ST-2026-0088, JE-2026-0083 and the payment request existed only inside the rolled-back transaction; **the stocktake sequence moved**
(0087 by the rehearsal, 0088 by the proof) — the next real stocktake will be ST-2026-0089. **What this proof is and is not:** refusals,
one full count → post, and read-backs as the real accounts, inside a transaction that was rolled back. No human walk has happened.

### Before / after

**Script:** `db/scripts/2026-09-25-role1b3a-readings.sql`, which states the identity for every part.
**Timing:** before at 11:30:01 CST (after the backup, before the migration); after at 11:52:59 CST (after the migration, the smoke and
the proof's ROLLBACK). **`diff` of the two outputs: only the read time, `stocktake_counts` appearing (relkind `r`) with 0 rows, the
catalogue 55 → 57, the two new codes' holders, and admin / finance / warehouse gaining them (codes and md5).**

| reading | identity · object | before | after |
|---|---|---:|---:|
| `approvals_enabled` / l1 / l2 / threshold | postgres · base `finance_settings` | t / finance / cfo / 1000 | **t / finance / cfo / 1000** |
| pending: claims submitted · leave · medical submitted · medical approved-unpaid · reviews · WO draft · stocktakes open · POs · payment requests · payroll requests · receipt price requests | postgres · base | 1 · 2 · 0 · 1 · 0 · 0 · 5 · 0 · 0 · 0 · 0 | **the same — nothing new pending on live** |
| stocktakes by status · `stocktake_lines` · `stocktake_counts` | postgres · base | open 5 · posted 4 · cancelled 1 · 4 · (absent) | **the same · 4 · 0** |
| work orders by status | postgres · base | released 1 | **released 1** |
| `approval_log` · `journal_entries` · payroll entries | postgres · base | 14 · 82 · 4 | **14 · 82 · 4** |
| account 1100 · 1200 · 1220 · 2000 · 2200 · 2300 · 2400 · 5000 · 5200 (debit − credit) | postgres · base `journal_lines` | 43,002.12 · 61,387.92 · 134.86 · −376,404.42 · −1,597.47 · 4,677.00 · 156.00 · 809.14 · 59,732.00 | **the same** |
| assays final / applied · metal rows · `price_history` · priced / all receipts · `purchase` entries | postgres · base | 4 / 4 · 19 · 14 · 12 / 24 · 10 | **the same** |
| catalogue · `action.stocktake_count` · `action.stocktake_post` holders | postgres · base | 55 · (absent) · (absent) | **57 · admin warehouse · admin finance** |
| codes per role (n): admin · auditor · cco · cfo · cto · employee · finance · gm · hr · operations · procurement · sales · warehouse | postgres · base `role_permissions` | 54 · 20 · 37 · 30 · 32 · 0 · 36 · 21 · 7 · 15 · 16 · 17 · 15 | **56** · 20 · 37 · 30 · 32 · 0 · **37** · 21 · 7 · 15 · 16 · 17 · **16** (the other ten md5-identical) |
| unrevoked grants | postgres · base `user_roles` | admin@ admin · chooer@ finance · fusheng@ warehouse · phua@ cto · sandra@ cco · tim@ cfo · vince@ gm | **the same** |
| `ap_open_items` n · Σ | tim@ · **view** | 16 · 416,988.32 | **16 · 416,988.32** |
| `ar_open_items` n · Σ | tim@ · **view** | 10 · 57,545.87 | **10 · 57,545.87** |
| list-vs-ledger AP: list / ledger / **unexplained** | tim@ · `list_ledger_reconciliation()` | 416,988.32 / 376,404.42 / **0.00** | 416,988.32 / 376,404.42 / **0.00** |
| list-vs-ledger AR: list / ledger / **unexplained** | tim@ · same | 57,545.87 / 43,002.12 / **0.00** | 57,545.87 / 43,002.12 / **0.00** |
| `current_user_permissions()`: admin@ · chooer@ · fusheng@ · phua@ · sandra@ · tim@ · vince@ | each account as itself | 54 · 36 · 15 · 32 · 37 · 30 · 21 | **56 · 37 · 16** · 32 · 37 · 30 · 21 |

**Pending documents and their deciders** (the migration's own proof, by person): CLM-2026-0004 → tim@ · LV-2026-0001 / 0003 →
admin@, tim@ · MC-2026-0001 (pay) → admin@, chooer@ · **ST-2026-0082…0086 → chooer@** (admin@ opened them; before this cut: chooer@,
fusheng@, phua@, sandra@). **No pending document is left without a decider, and nothing is pending on live.**

## §4 · What each person gains and loses

- **Fu Sheng (warehouse):** **gains** `action.stocktake_count` — opens stocktakes and counts, recorded as the counter. **Loses**
  posting stocktakes (he could post any stocktake he had not opened), direct writes to the stocktake tables, and freight / processing
  cost and landed cost on the receipt page (now "Restricted"). Cannot change the supplier or PO of a priced receipt.
- **Choo Er (finance):** **gains** `action.stocktake_post` — the only non-admin who can post a stocktake, unless she counted on it or
  opened it. **Loses** opening and counting stocktakes (she held `stocktakes.edit`), and changing the supplier / PO of a priced receipt.
  Keeps cancelling.
- **Sandra (cco) · Phua (cto):** lose opening, counting and posting stocktakes; keep cancelling (`stocktakes.edit`). Lose changing the
  supplier / PO of a priced receipt. Phua still applies assays; `is_final` can no longer be flipped by editing.
- **Tim as tim@ (cfo):** nothing new to do; decides payroll and payment requests as before. **Tim as admin@:** gains both codes but
  cannot post a stocktake he opened or counted on, and cannot raise a payroll or payment request while approvals are on (he is the
  same person as the only level-2 approver).
- **Vince (gm):** no change.

## §5 · The broken window — started, end PENDING

**Start: 2026-09-25 11:31:10 CST** (`db/apply_migration.sh`'s own line, also in `db/migration-windows.tsv`; its "applied at" line
reads 11:30:29). **End: PENDING — Tim reads it from Vercel.**

What the old app does against the new database (approvals ON):
- **Nobody can open or count a stocktake from the old app.** Its `createStocktake` inserts directly and `saveCount` upserts directly —
  both are now refused by name (`STOCKTAKE_THROUGH_FUNCTION_ONLY`); New stocktake throws to the error boundary, a count shows the raw
  code inside "Save failed". Posting still works — for Choo Er (and admin@); Fu Sheng, Sandra and Phua get
  `PERMISSION_DENIED|action.stocktake_post`. Cancelling is unaffected.
- **The old receipt page** shows freight and processing cost as blank to Fu Sheng (the panel it sits in was already behind `view_prices`).
- **Changing the supplier of a priced receipt** from the old edit form is refused; the old copy shows the raw code inside the generic
  save-error sentence.
- **admin@ raising a payroll or payment request** is refused with the raw code in the old copy.
- **Unaffected:** every approval chain, the switch, everything pending, every payment path, pricing, assays, and every other screen
  (the smoke ran the new code against the new database).

## §6 · Commit, push, three SHAs

Reported in the hand-back message: `HEAD`, `origin/main` and `git ls-remote origin main` as full 40-character SHAs
(a commit cannot carry its own hash). Deployment is Tim's to read; the window's end stays PENDING until he does.
**Next cut: ROLE-1 Batch 3b** (`docs/forward-queue.md` item 8); then APR-5.
**Closed in § Batch 3b §W:** the window was at least 23 min 58 s and at most 27 min 12 s (end 11:55:08–11:58:22 CST).

# Batch 3b — the warehouse makes, finance releases: receipts, work orders, processing, write-off and rollback (2026-09-25)

**Opening gate:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `2d797b1e85ce5c59027052868d28d1010bf9ca35`
(ROLE-1 Batch 3a). **Approvals were ON and stayed ON.** Every figure below is a script's own exit line or a query named with its
identity. The matrix lines are `docs/role-matrix.md` §8 and §9 plus the codes table; the approvals effects are `docs/approvals.md` §3p.

## §W · Batch 3a's broken window — closed with bounds, labelled by kind

Tim confirmed the Batch 3a deploy on 2026-09-25, before this session began.

| | time (CST) | kind |
|---|---|---|
| start | 2026-09-25 11:31:10 | `db/apply_migration.sh`'s own line (`db/migration-windows.tsv`) |
| end, lower bound | 11:55:08 | **measured**: the push moved `origin/main` → `2d797b1e` (`git reflog show --date=iso refs/remotes/origin/main`) — no deploy can precede it |
| end, upper bound | 11:58:22 | **derived**: this session's first live read, database clock `now()` as `postgres` (`rolbypassrls = t`), taken after Tim's "deployed" confirmation had arrived — **a relayed confirmation, not a measurement of Vercel** |

**Window: at least 23 min 58 s, at most 27 min 12 s.** Batch 3a's §5 above keeps its "PENDING" wording; this row is the close.

**Recorded ruling (Tim, 2026-09-25):** Batch 3a's build decision stands — `allocate_processing_costs` reads the ungated readers
`batch_freight_base_all` / `batch_processing_cost_base_all`, so **the allocated amount never depends on who presses the button**
(and never on whether the allocator happens to hold `data.view_prices`).

## §0 · Step 0 (grilling) and Tim's answers

**What grilling found** (code read from the mirrors by two surveys and spot-checked; live read as `postgres`, `rolbypassrls = t`,
base tables, `relkind = 'r'` checked, 11:59–12:10 CST):
1. **The self-release rule already existed.** `release_work_order` has refused the creator per person since APR-2
   (`forbid_self_approval(created_by, NULL, 'work_order')`); only the code on the gate changes. There is no `released_by` column —
   the release is recorded in `work_order_history` (`changed_by`) and `approval_log`.
2. **No screen writes the processing tables directly** (every `.from('processing_runs' | '_outputs' | '_inputs')` in `app/`, `lib/`,
   `scripts/` is a read) — Q7 is safe. Beyond the ruling: DELETE policies on all three tables allowed a direct hard delete of a
   committed run; `processing_run_losses` and `processing_cost_entries` are written directly on `processing.edit`.
3. **Warehouse would commit runs but could not record their losses or hand over a shift.**
4. **Screens gated at view level**: the new-WO and new-run pages, Release / Close / Cancel (`processing.edit`), the rollback button
   (no gate), the receipt entry points and both write-off buttons (no gate — the database refused).
5. **Three pages read `materials`**: run entry, new work order, and run detail (embedded `materials ( name )`). `material_lookup`
   admitted warehouse only through `inbound.view`.
6. **Price at creation**: after Q1 Choo Er cannot create a receipt at all; she prices it afterwards through the panel.
7. **Four action paths showed "unexpected error (PERMISSION_DENIED)"** for a permission refusal (found while building):
   `localizeProcessingError`, the loss `localize()`, and both receipt actions through `localizeMaterialError` had no
   `PERMISSION_DENIED|<code>` branch. Each now routes to the single existing sentence (`common.actionMessage.permissionDenied`).

**Live readings at Step 0:** work orders: WO-2026-0001 only, `released`, created by `b093d6c0` (not a current account), **0 drafts**.
Runs: 10 committed (1 on WO-2026-0001, 9 ad hoc), 4 reversed; 17 outputs, 14 inputs, 0 losses, 10 cost entries, 0 handovers.
Receipts: 15 live, 9 written off; output batches 14 live, 6 written off. **Nothing stranded; no document ends up with only its creator
able to release it** (Fu Sheng creates → Choo Er or admin@; admin@ creates → Choo Er).

**Tim's answers (2026-09-25) — the recommendations, with Q2 decided differently:**

| Q | ruling |
|---|---|
| Q1 | drop the DELETE policies on `processing_runs` · `_outputs` · `_inputs` as well; keep the UPDATE policies with the ruled guard; register the UPDATE policies (`ROLE1B3B-PROCESSING-UPDATE-POLICIES`) |
| Q2 | **losses and handovers to warehouse** under a new code `action.processing_aftercare` (warehouse · admin), accepted alongside `module.processing.edit`; **processing cost entries stay on `module.processing.edit`** |
| Q3 | `create_work_order` refuses `WO_NO_OTHER_RELEASER` unless another person holds an unrevoked `action.wo_release`; the self-proof asserts every draft has a releaser |
| Q4 | `material_lookup`'s predicate gains `module.processing.view` |
| Q5 | accept: `receive_goods` is asked first so the refusal names it; the price arm keeps `price_receipts` + `view_purchase_prices`; recorded in §4 |
| Q6 | select `created_by`; Release disabled with the reason for non-holders and for the creator's own account |
| standing | every new code also to `admin`, same migration |

# Batch 3b — shipped (2026-09-25)

## §1 · What 3b shipped

**Migration** `db/migrations/2026-09-25-role1b3b-the-warehouse-makes-finance-releases.sql`, assembled from the mirrors by
`db/scripts/build_role1b3b_migration.py`. One transaction. Its self-proof asserts: grants = before + exactly the fifteen ruled rows;
each new code held by exactly its ruled roles; warehouse does **not** hold `module.materials.view`; approvals still ON; pending
documents unchanged; `approval_log`, `journal_entries`, work orders (all / released), runs (committed / reversed), outputs, inputs,
losses, receipts and output batches (all / written off), handovers unchanged; the five policies gone; the five guard triggers present;
the three loss write policies name `action.processing_aftercare`; `material_lookup` admits `module.processing.view`; each of the
thirteen functions carries its ruled gate; every pending document still has a decider who is not its own party (the work-order arm
now asks `action.wo_release` minus the creator).

| piece | what |
|---|---|
| codes (catalogue 57 → 64) | `action.receive_goods` · `action.batch_write_off` · `action.wo_create` · `action.processing_commit` · `action.processing_rollback` · `action.processing_aftercare` → warehouse · admin; `action.wo_release` → finance · admin; warehouse also gains `module.processing.view` (15 grant rows) |
| receipts (Q1 · Q5) | `create_inbound_batch` and `receive_inbound_batch_against_po` ask `action.receive_goods` first; the price arm still needs `action.price_receipts` + `data.view_purchase_prices` |
| write-off (Q9) | `soft_delete_inbound_batch` · `soft_delete_output_batch` → `action.batch_write_off` |
| work orders (Q6 · Q3) | `create_work_order` → `action.wo_create` + `WO_NO_OTHER_RELEASER` (a real holder — `real_role_grants` — of `action.wo_release` who is a different person, `self_leg = 'none'`; independent of the approvals switch, like the release-side rule) · `release_work_order` → `action.wo_release` (four-eyes leg unchanged) · `amend` / `cancel` / `close` → `action.wo_create` **or** `module.processing.edit`, refusal names `action.wo_create` |
| processing | `commit_processing_run` → `action.processing_commit` · `rollback_processing_run` → `action.processing_rollback` · `submit_shift_handover` / `acknowledge_shift_handover` → `action.processing_aftercare` or `module.processing.edit` · `processing_run_losses` INSERT / UPDATE / DELETE policies and its `enforce_write_permission` trigger accept both |
| no direct writes (Q7 · Q1) | INSERT policies on `processing_runs` · `processing_outputs` and DELETE policies on those two and `processing_inputs` dropped; `guard_processing_direct_write` (new, INVOKER, `row_security_active`) → `PROCESSING_THROUGH_FUNCTION_ONLY|<table>|<op>` on direct insert (runs, outputs), direct delete (all three, statement-level so a zero-row delete still raises) and a direct change of `status` / `work_order_id` on runs. Other columns still go through the UPDATE policies (registered) |
| materials (Q4 · Q8) | `material_lookup` predicate + `module.processing.view`; new WO, run entry and run detail read names from it (`app/operation/processing/materialNames.ts`) — no `module.materials.view` for warehouse |

**Screens (en + zh):**
- Receipts: `/inbound` (both entry buttons), the PO page's "Receive against", receive/done's "Receive next", the run-entry helper link,
  and the submit on `/inbound/new` and `/inbound/receive` — visible, disabled, naming `action.receive_goods`.
- Write-off buttons on `/inbound` and `/output` — inline gate on `action.batch_write_off`.
- Work orders: New work order (was hidden, now disabled with the code); the new-WO submit; Release gated on `action.wo_release`, and
  for the creator's own account disabled with "You created this work order — someone else must release it." (the page judges per
  account, the database per person); Amend / Close / Cancel on `action.wo_create` or `processing.edit`.
- Processing: new run and its submit on `action.processing_commit`; rollback on `action.processing_rollback`; the loss panel and
  handovers on `action.processing_aftercare` or `processing.edit` (the handover list button was hidden, now disabled).
- Copy: `processing.wo.blocked.releaseSelf`, `processing.errors.WO_NO_OTHER_RELEASER`, `processing.errors.PROCESSING_THROUGH_FUNCTION_ONLY`;
  the unused `processing.wo.needsEdit` removed. zh uses 放行 (the word every other work-order string on that screen uses).

**Fixtures:** new **222** (R1–R3 · W1–W2 · O1–O8 · P1–P5 · L1–L2 · M; fault injection P5: drop the delete guard on `processing_runs`
and a `processing.edit` holder's direct delete becomes a silent zero-row "success"; O7 / O8 remove `action.wo_release` from every
other role inside a sub-block, O8 leaving only the creator's own second account). **Changed because a rule changed:** 219 (warehouse
role gains `receive_goods`) · 220 (`batch_write_off` to the warehouse role; `receive_goods` to the finance role for the desk-with-price
arm) · 152 (`receive_goods`) · 179 · 30 · 74 · 75 · 79 (a standing real releaser before the first `create_work_order`) · 30 · 34 · 43 ·
45 · 47 · 51 · 54 (the processing actor gains the four operator codes) · 74 (the edit role gains `wo_create`) · 203 (the release actor
gains `wo_release`) · 204 (finance role gains `wo_release`).

**Known issues:** registered `ROLE1B3B-PROCESSING-UPDATE-POLICIES` (Q1) and `ROLE1B3B-RECEIVE-DONE-MATERIAL-NAME` (receive/done still
embeds `materials ( name )`, so warehouse sees "—" there — predates this cut). `ROLE1B3-AMEND-RELEASED-WO` stays open. Not converted:
`NewHandoverForm`'s own submit is ungated (its page comment says so on purpose); the loss panel's per-row delete column is still hidden
rather than disabled without the code (as before).

## §2 · Verification — every figure is the script's own exit line

| step | result |
|---|---|
| `db/gate.py --offline`, run 1 | **`GATEOFF_EXIT=2`** — the permissions mirror lost the `)` after `1070` in the edit (the same sliced-string slip 3a recorded) |
| run 2 | **`GATEOFF_EXIT=4`** — 11 fixtures red, each a hand-picked role missing a new code: 203 · 204 · 30 · 34 · 43 · 45 · 47 · 51 · 54 · 74, and 222 (its approval policy was not set) |
| run 3 · run 4 | **`GATEOFF_EXIT=4`** — 222 O7 then O8: revoking grants hit `LAST_ADMIN_PROTECTED`; rewritten to remove the code from roles inside the sub-block (O8: the creator's second account on its own role) |
| run 5 | **`GATEOFF_EXIT=0`** (222 included; its P5 fault injection bites) |
| dry run on live (`COMMIT` → grants + probe + `ROLLBACK`) | run 1 **`DRY_OWN_EXIT=3`** — the migration body and self-proof passed; my appended probe query was mis-quoted; run 2 **`DRY_OWN_EXIT=0`**: catalogue 64, exactly the 15 grants, approvals t |
| rehearsal: migration + grants + live proof, one transaction, `ROLLBACK` | run 1 **`REHEARSE_OWN_EXIT=3`** at P2 — `MATERIAL_NOT_PROCESSABLE|MAT-2026-0002|undecided` (the proof picked an undecided material); switched to ZZ-PROCCOST1-DEMO; run 2 **`REHEARSE_OWN_EXIT=0`** |
| `npm run build` (before the migration) | `BUILD_OWN_EXIT=0` |
| backup (`db/run_detached.sh`, token BACKUP) | **`BACKUP_EXIT=0`** — `evoltrya-backup-2026-09-25-1250.dump`, 4.7 MB, TOC 6,258 (previous 6,231, floor 5,607); `pg_restore --list` 6,273 lines |
| `db/apply_migration.sh` | **`APPLY_OWN_EXIT=0`**. Pre-flight: 15 CREATE FUNCTION (13 replace · 2 new — the guard and the proof's `pg_temp` helper), no account codes, no masked columns. **Window start 2026-09-25 13:01:19 CST** (the "applied at" line reads 13:00:40) |
| `NOTIFY pgrst, 'reload schema'` · `npm run types:gen` | `TYPES_OWN_EXIT=0` — **no diff** (no signature or column changed) |
| `npx tsc --noEmit` | `TSC_OWN_EXIT=0` |
| `npm run build` | `BUILD_OWN_EXIT=0` |
| `db/gate.py` full (detached) | **`GATE_EXIT=0`**, 434 s: rebuildable ✓ · mirrors vs live ✓ (`NO DIFFERENCES`) · fixtures ✓ (**225 passed, 0 failed**) · anon surface ✓ (live ⊆ baseline 327); B1 / B2 0 on both sides, B2 allowlist 10 |
| `node scripts/check-i18n.mjs` | `I18N_OWN_EXIT=0` |
| `node scripts/check-error-swallowing.mjs` | `SWALLOW_OWN_EXIT=0` — 0 unallowed |
| smoke (`db/run_detached.sh`, token SMOKE, `--timeout 2400`, 13:12:42 → `SMOKE_EXIT=0`) | **253 ok · 7 skipped (no data) · 0 FAILED**; 228 timed routes, 790.8 s, median 2,372 ms; the disposable session got the 64-code probe role. **Clean-up, read at 13:30:40 as `postgres` from base tables:** `smoke-%` users **0** · `probe-%` / `fixture-%` / `fx%` roles **0** · orphan grants (no user / no role) **0 / 0** · `ZZ-SMOKE-%` employees **0** · `idle in transaction` **0**; `.ephemeral/` empty; no smoke or `next dev` process left. The scratch check reported the same 6 stale `ZZ-SMOKE-*` rows as before (reported, not touched) |

## §3 · Live proof

**Script:** `db/scripts/2026-09-25-role1b3b-live-proof.sql`. One transaction, `ROLLBACK`, as `postgres` (`rolbypassrls = t`); each cell
sets `request.jwt.claims` to a real account and runs under `SET LOCAL ROLE authenticated`.
**Result: `PROOF_OWN_EXIT=0`, every cell matched**, started 13:30:52 CST (inside the window, after the smoke).

| account | cell | result |
|---|---|---|
| each of seven | which of the new / processing / materials codes they hold (`current_user_permissions()`) | fusheng@: the six warehouse codes + `processing.view` · chooer@: `wo_release` + both views · admin@: all seven + both processing codes · sandra@ · phua@: `processing.edit` + views · tim@ · vince@: views |
| sandra@ · phua@ · chooer@ | create a goods receipt | `PERMISSION_DENIED|action.receive_goods` ×3 |
| sandra@ | receive against a PO | `PERMISSION_DENIED|action.receive_goods` |
| fusheng@ | create IN-2026-0475 (unpriced) | created_by fusheng@ |
| sandra@ · phua@ | create a work order | `PERMISSION_DENIED|action.wo_create` ×2 |
| fusheng@ | create WO-2026-0002 | draft, created_by fusheng@ |
| fusheng@ · sandra@ · phua@ | release it | `PERMISSION_DENIED|action.wo_release` ×3 |
| admin@ | create a work order, then release it | `SELF_APPROVAL_FORBIDDEN|raiser` |
| chooer@ | ★ release WO-2026-0002 | released; `work_order_history` names chooer@ |
| sandra@ | amend it (`processing.edit`) | OK |
| sandra@ · phua@ | commit a run | `PERMISSION_DENIED|action.processing_commit` ×2 |
| fusheng@ | ★ commit PROC-2026-0709 against WO-2026-0002 (ZZ-PROCCOST1-DEMO −10 → ZZ-SMOKE-NTF +9, loss 1) | committed; `journal_entries` 82 → 82; 1200 61,387.92 → 61,387.92 · 1220 134.86 → 134.86 (a commit posts nothing; cost reaches the ledger at allocation) |
| sandra@ | direct INSERT a committed run · UPDATE status = reversed · DELETE the run | `PROCESSING_THROUGH_FUNCTION_ONLY|processing_runs|insert` · `…|update` · `…|delete` |
| fusheng@ | record a loss category on the run | OK |
| vince@ · fusheng@ | acknowledge a handover | `PERMISSION_DENIED|action.processing_aftercare` · past the gate (`HANDOVER_NOT_FOUND`) |
| phua@ · fusheng@ | roll the run back | `PERMISSION_DENIED|action.processing_rollback` · reversed; 1200 / 1220 unchanged |
| fusheng@ | close WO-2026-0002 | closed |
| chooer@ · sandra@ | write off an inbound and an output batch | `PERMISSION_DENIED|action.batch_write_off` ×2 each |
| fusheng@ | write off IN-2026-0475 and OUT-2026-0002 | both written off by fusheng@ |
| fusheng@ | `material_lookup` (**view**) · `materials` (**base table**, RLS) | 9 rows · 0 rows |
| tim@ | `list_ledger_reconciliation()` inside the transaction | unexplained AP 0.00 · AR 0.00 |

Everything above existed only inside the rolled-back transaction. **The code sequences moved** (they do not roll back): the dry runs,
the two rehearsals and the proof took IN-2026-0473…0475 and PROC-2026-0707…0709 among others; the next real receipt and run take
the numbers after those. **What this proof is and is not:** refusals, one full create → release → commit → rollback → close and two
write-offs, read back as the real accounts, inside a transaction that was rolled back. No human walk has happened.

### Before / after

**Script:** `db/scripts/2026-09-25-role1b3b-readings.sql`, which states the identity for every part.
**Timing:** before at 13:00:20 CST (after the backup, before the migration); after at 13:31:09 CST (after the migration, the smoke and
the proof's ROLLBACK). **`diff` of the two outputs: only the read time, the catalogue 57 → 64, the holders of the new codes (and
warehouse added to `module.processing.view`), and admin / finance / warehouse gaining them (codes and md5, on the role rows and on
the three accounts).**

| reading | identity · object | before | after |
|---|---|---:|---:|
| `approvals_enabled` / l1 / l2 / threshold | postgres · base `finance_settings` | t / finance / cfo / 1000 | **t / finance / cfo / 1000** |
| pending: claims submitted · leave · medical submitted · medical approved-unpaid · reviews · WO draft · stocktakes open · POs · payment requests · payroll requests · receipt price requests | postgres · base | 1 · 2 · 0 · 1 · 0 · 0 · 5 · 0 · 0 · 0 · 0 | **the same — nothing new pending on live** |
| work orders by status · runs committed (ad hoc / on WO) · reversed | postgres · base | released 1 (creator not an account) · 9 / 1 · 4 | **the same** |
| outputs · inputs · losses · cost entries · handovers | postgres · base | 17 · 14 · 0 · 10 · 0 | **the same** |
| receipts written off · output batches all / written off | postgres · base | 9 · 20 / 6 | **the same** |
| `approval_log` · `journal_entries` · payroll entries | postgres · base | 14 · 82 · 4 | **14 · 82 · 4** |
| account 1100 · 1200 · 1220 · 2000 · 2200 · 2300 · 2400 · 5000 · 5200 (debit − credit) | postgres · base `journal_lines` | 43,002.12 · 61,387.92 · 134.86 · −376,404.42 · −1,597.47 · 4,677.00 · 156.00 · 809.14 · 59,732.00 | **the same** |
| catalogue | postgres · base `permissions` | 57 | **64** |
| codes per role (n): admin · auditor · cco · cfo · cto · employee · finance · gm · hr · operations · procurement · sales · warehouse | postgres · base `role_permissions` | 56 · 20 · 37 · 30 · 32 · 0 · 37 · 21 · 7 · 15 · 16 · 17 · 16 | **63** · 20 · 37 · 30 · 32 · 0 · **38** · 21 · 7 · 15 · 16 · 17 · **23** (the other ten md5-identical) |
| unrevoked grants | postgres · base `user_roles` (`revoked_at IS NULL`) | admin@ admin · chooer@ finance · fusheng@ warehouse · phua@ cto · sandra@ cco · tim@ cfo · vince@ gm | **the same** |
| `ap_open_items` n · Σ | tim@ · **view** | 16 · 416,988.32 | **16 · 416,988.32** |
| `ar_open_items` n · Σ | tim@ · **view** | 10 · 57,545.87 | **10 · 57,545.87** |
| list-vs-ledger AP: list / ledger / **unexplained** | tim@ · `list_ledger_reconciliation()` | 416,988.32 / 376,404.42 / **0.00** | 416,988.32 / 376,404.42 / **0.00** |
| list-vs-ledger AR: list / ledger / **unexplained** | tim@ · same | 57,545.87 / 43,002.12 / **0.00** | 57,545.87 / 43,002.12 / **0.00** |
| `current_user_permissions()`: admin@ · chooer@ · fusheng@ · phua@ · sandra@ · tim@ · vince@ | each account as itself | 56 · 37 · 16 · 32 · 37 · 30 · 21 | **63 · 38 · 23** · 32 · 37 · 30 · 21 |

**Pending documents and their deciders** (the migration's own proof, by person): CLM-2026-0004 → tim@ · LV-2026-0001 / 0003 →
admin@, tim@ · MC-2026-0001 (pay) → admin@, chooer@ · ST-2026-0082…0086 → chooer@. **No draft work order exists; no pending
document is left without a decider, and nothing is pending on live.**

## §4 · What each person gains and loses (approvals on)

- **Fu Sheng (warehouse):** **gains** creating work orders (and amending, cancelling, closing them), committing runs, rolling runs back,
  recording a run's loss categories and shift handovers, and reading the whole processing module (`module.processing.view`; material
  names only through `material_lookup`, cost figures still behind `data.view_prices`). **Keeps** creating goods receipts and writing off
  inbound and output batches (now under their own codes). **Cannot** release a work order, least of all one he created.
- **Choo Er (finance):** **gains** releasing work orders — the only non-admin who can, and never one she created (she cannot create).
  **Loses** creating goods receipts, with or without a price (Q5: she prices a receipt after Fu Sheng creates it, through the panel as a
  request), and writing off inbound and output batches.
- **Sandra (cco) · Phua (cto):** **lose** creating goods receipts, both write-offs, creating and releasing work orders, committing and
  rolling back runs. **Keep** amending / cancelling / closing work orders, losses, cost entries and handovers through `processing.edit`.
- **Tim as tim@ (cfo):** no change (reads processing as before). **Tim as admin@:** gains all seven codes; still cannot release a work
  order he created, and a work order he creates is released by Choo Er.
- **Vince (gm):** no change.

## §5 · The broken window — started, end PENDING

**Start: 2026-09-25 13:01:19 CST** (`db/apply_migration.sh`'s own line, also in `db/migration-windows.tsv`; its "applied at" line
reads 13:00:40). **End: PENDING — Tim reads it from Vercel.**

What the old app does against the new database (approvals ON):
- **Nobody but admin@ can release a work order from the old app.** Choo Er gains the right, but the old page shows Release only to
  `processing.edit` holders; admin@ cannot release one he created. There are 0 drafts, so this only touches a work order created during
  the window.
- **Fu Sheng cannot create a work order or commit a run from the old app in practice:** the old New work order button is hidden from
  him (it asked `processing.edit`), and the old run-entry and new-WO pages read `materials`, which he cannot see — the material pickers
  are empty and material names on the old processing pages are blank. The old loss panel and handover button are hidden from him too.
- **Sandra, Phua and Choo Er** pressing New receipt / Receive, New work order, Commit, Roll back or Write-off in the old app are refused;
  the old receipt and processing copy shows "unexpected error (PERMISSION_DENIED)" (the branch this cut added is not deployed yet),
  write-off shows the generic "Restricted" sentence.
- **Unaffected:** every approval chain, the switch, everything pending, every payment path, pricing, assays, stocktakes, processing cost
  entries and allocation, and every other screen (the smoke ran the new code against the new database).

## §6 · Commit, push, three SHAs

Reported in the hand-back message: `HEAD`, `origin/main` and `git ls-remote origin main` as full 40-character SHAs
(a commit cannot carry its own hash). Deployment is Tim's to read; the window's end stays PENDING until he does.
**Next cut: APR-5** (`docs/forward-queue.md` item 9).
