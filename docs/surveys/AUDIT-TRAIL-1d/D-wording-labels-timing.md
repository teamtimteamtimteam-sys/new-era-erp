# AT-1d survey D: event wordings, field labels, timing calibration (2026-10-04, read-only)

Repo `new-era-erp` @ `0644806a`. No edits, no DB access. Scratch scripts (Step 0 scratchpad, not kept): `fields.mjs` (shown / hidden /
override counts from `TRAIL_FIELDS` + the generator's `OVERRIDES` / `HIDE`), `enums.mjs` (CHECK values vs `TRAIL_ENUMS`), `tl.py`
(transcript timeline: first/last message, user messages, gaps > 10 min), `steps.py` (Bash tool_use → tool_result times for backup / apply /
gate / smoke / probe / push), per-commit `OVERRIDES` evaluation (`git show <c>:scripts/gen-trail-catalogue.mjs`, `main()` replaced by an export).
Raw label dump: `fields.out` (447 lines).

M = Measured (command or file:line given), I = Inferred.

---

## 1. Event wordings

### 1.1 Rows in the catalogue (`docs/surveys/AUDIT-TRAIL-0/events.md` §5). Measured by grepping the last (source) column.

| Block | Rows | EXISTS | STATE | NEW | Status |
|---|--:|--:|--:|--:|---|
| G01–G06 leave (request / decide / cancel / grants / carry-forward) | 6 | 0 | 4 | 2 | AT-1d |
| G07–G11 medical claims | 5 | 2 | 3 | 0 | AT-1d |
| G16–G22 overtime | 7 | 1 | 3 | 3 | AT-1d |
| G23–G31 payroll requests / periods / payments | 9 | 0 | 5 | 4 | AT-1d. 1c-3 only did the *payroll-journal* list block on `/finance/payroll-payments` (`je.posted.payroll`, `listTrail.intro.payroll`) |
| G32–G35 salary change requests | 4 | 0 | 3 | 1 | AT-1d |
| G36–G44 employment history (hired … category change) | 9 | 3 | 6 | 0 | AT-1d |
| G45–G53 reviews + review cycles | 9 | 2 | 5 | 2 | AT-1d |
| G54–G55 KPI lock / KPI scored | 2 | 0 | 1 | 1 | AT-1d |
| G56–G58 attendance periods | 3 | 0 | 2 | 1 | AT-1d |
| G59–G60 extra login linked / unlinked | 2 | 0 | 0 | 2 | AT-1d |
| G61 personal data anonymised | 1 | 0 | 0 | 1 | AT-1d |
| **G subtotal** | **57** | **8** | **32** | **17** | |
| I03–I04 role granted / removed (`user_roles`) | 2 | 0 | 0 | 2 | AT-1d (per-account trail) |
| I05–I10 account create / delete / disable / enable (+ two `_FAILED`) | 6 | 6 | 0 | 0 | AT-1d. Keys exist since AT-1a (`account.ACCOUNT_*`, text.ts:52-57); only the summary page shows them today |
| I12 login linked to employee (`set_user_employee_link`) | 1 | 0 | 0 | 1 | AT-1d |
| F45–F48 approval policy (`set_approvals_policy`) | 4 | 0 | 2 | 2 | AT-1d (Tim's AT-1c Q2, `docs/forward-queue.md:6634`) |
| F97 master import (`import_batches`) | 1 | 0 | 0 | 1 | AT-1d |
| **AT-1d core** | **71** | **14** | **34** | **23** | |
| G12–G15 expense claims | 4 | | | | Done in 1c-3 (`exp.claim*`, text.ts:539-543; `/me` through M8) |
| G62–G63 shift handovers | 2 | | | | Done in 1b-1 (`ho.*`, text.ts:257-261) |
| I01–I02, I11 role permissions / role created / deactivated | 3 | | | | Done in AT-1a (`role.*`, text.ts:119-133) |
| F34–F44 period close, GST and other `finance_settings` columns | 11 | | | | Done in 1c-3 (`plock.*`, `gstset.*`, `yclose.*`) |
| K01–K04 generic fallback | 4 | 3 | 1 | 0 | Reused (`generic.*`, text.ts:47-50) |

Commands: `grep -E "^\| G[0-9]{2} \|" events.md | grep -vE "^\| G(1[2-5]|6[23]) \|"`, then the last column counted per sub-range; same for
`I`, `F4[5-8]`, `F97`.

**No catalogue row at all (M, by reading §5):**
- training records, departments, leave types, public holidays, the review rating scale, KPI position templates, positions, and the 6 dictionary
  tables (`substances`, `battery_chemistries`, `material_kinds`, `inbound_safety_states`, `laboratories`, `inbound_source_reasons`; the
  registry is `app/settings/dictionaries/registry.ts:77-155`). They fall to K01–K04 / `generic.*`;
- review goals added / changed / removed (`add_review_goal`, `update_review_goal`, `remove_review_goal` — a hard DELETE);
- KPI entries created by `assign_position_kpis` (bulk INSERT);
- overtime lines added / removed (`add_overtime_line`, `delete_overtime_line` — a hard DELETE);
- payroll recomputed (`upsert_payroll_period`, §1.4 #11);
- a self-assessment sent back (`open_for_self_assessment`, §1.4 #18);
- an employee deleted (`deleteEmployee`, `app/hr/employees/actions.ts:356-366`, `deleted_at` → H13/K04 shape).

**Rows that describe values nothing writes (M):**
- G05: `leave_grants.grant_type` ∈ {entitlement, pro_rata, adjustment} has no writer. The only `INSERT INTO leave_grants` is
  `carry_forward_annual_leave.sql:72`; the app only reads (`app/hr/leave/grants/page.tsx:29`);
- `medical_claims.status = 'paid'` (AT-0 finding 3);
- `kpi_cycles.status` (AT-0 finding 3).

### 1.2 The AT-0 wordings for the key HR / settings events (copied from events.md §5)

| ID | Wording | Detail line |
|---|---|---|
| G01 | Leave requested: {days} days of {type} | dates |
| G02 / G03 / G04 | Leave approved / Leave rejected / Leave cancelled — days returned | approver · balance after / reason / — |
| G06 | Unused leave carried forward: {days} days | expires on |
| G07–G11 | Medical claim submitted: {amount} / approved / rejected / withdrawn / Expense raised to pay the claim | clinic · date … expense {code} |
| G16–G22 | Overtime batch started / sent for approval: {hours} hours / taken back for changes / approved / sent back / reversed / discarded | period, lines, reason |
| G23–G31 | Payroll posting / unposting sent for approval · approved automatically · approved · rejected · withdrawn · Payroll posted for {month} · Payroll unposted for {month} · Salaries paid: {n} employees · CPF paid / Deductions paid | month · total · gross · CPF · net |
| G32–G35 | Salary change requested: {old} → {new} / approved / rejected / request withdrawn | effective date |
| G36–G44 | Hired · Confirmed after probation · Promoted to {position} · Transferred to {department} · Employment type changed to … · Employment status changed to … · Left the company (…) · Salary set to / changed from … to … · Work category changed to … | |
| G45–G53 | {Probation / Annual} review opened · Opened for self-assessment · Self-assessment submitted · Review submitted for approval · approved · acknowledged by the employee · voided · Review cycle opened: {n} reviews created · Review cycle closed | |
| G54–G55 | KPI scores locked by the {M3 / M6} gate · KPI scored: {score} | judged / computed |
| G56–G58 | Attendance period opened / completed / reopened | month · reason |
| G59–G61 | Extra login linked: {account} / unlinked · Personal data anonymised | |
| I03 / I04 / I12 | Role granted: {role} / Role removed: {role} · Login linked to {employee} / Login unlinked | granted by / reason |
| F45–F48 | Approvals switched on / off · Level {1/2} approver changed to {role} · Approval threshold changed from {old} to {new} | level roles · threshold |
| F97 | {n} {suppliers / materials / …} imported from a file | file name |

### 1.3 `lib/trail/text.ts` keys added per cut

Measured with `git show <c> -- lib/trail/text.ts | grep -E "^\+ *'[^']*':" | wc -l` (and `^-` for removals).

| Commit | Cut | Keys + / − |
|---|---|---|
| 77776f76 | AT-1a | +117 / 0 |
| e0e1a789 | 1b-1 | +123 / 0 |
| f8530f1d | 1b-2 | +114 / −1 |
| 24b913fd | 1b-3 | +54 / 0 |
| f2583028 | 1c-1 | +79 / 0 |
| e282b092 | 1c-2 | +65 / 0 |
| 6104635b | 1c-3 | +44 / 0 |
| **File total at HEAD** | | **595** (`grep -cE "^ *'[^']*':" lib/trail/text.ts`; equals the sum, net of the one removal) |

Keys per new subject (M for keys and subject counts, I for the rate): the subjects added are counted as distinct codes in
`git show <c>:db/functions/trail_subjects.sql` (3 → 10 → 21 → 29 → 36 → 44 → 56). That gives 1a 39, 1b-1 17.6, 1b-2 10.3, 1b-3 6.8,
1c-1 11.3, 1c-2 8.1 and 1c-3 3.7 keys per subject. 1c-3's subjects were mostly list blocks and settings panels.

**Keys already in the file that AT-1d can reuse (M, text.ts line numbers):**
- `approval.submitted / approved / approvedLevel / rejected / auto / other` (214-219). These are generic `{Thing}` sentences for leave requests,
  medical claims, overtime batches, payroll requests, salary change requests and reviews. **Caveat:** the overtime page says "Sent back" for
  `rejected` (G20, `overtime.status_rejected`), so the generic "{Thing} rejected" would contradict the page;
- `po.autoApproved` "Approved automatically (approvals were switched off)" (63). 1c-3 reused it; G24 needs the same line;
- `account.ACCOUNT_CREATE / _DELETE / _DISABLE / _DISABLE_FAILED / _ENABLE / _ENABLE_FAILED` (52-57): I05–I10;
- `role.*` (119-133, 15 keys). `role.lineAdded / lineRemoved / lineGiven / notKept` and `role.added / removed` fit "Roles changed" sub-lines
  (I03/I04);
- `generic.created / edited / deleted / truncated` (47-50): dictionaries, departments, training, leave types, holidays, rating scale;
- `banner.deleted* / withdrawn* / reversed* / voided*` (148-151, 402-403, 464-467, 552-553): deleted employee, withdrawn requests, reversed
  overtime, voided review;
- `who.anonymised` "A former employee" and `who.unlinked` (33-37), relevant to G61 and the account links;
- `value.*`, `reason`, `restricted`, `restrictedPart`, `summary.*`, `refusal.*`;
- models, not reuse: `exp.claim*` (539-543) for medical claims, `jr.*` (478-485, sent / approved / rejected / withdrawn × entry / reversal)
  for payroll post / unpost requests, `set.*` (459-461) for a settings panel, `bip.*` (667-669) for import mappings.

There are **no** keys today for leave, medical claims, overtime, attendance, payroll periods or requests, salary changes, employment
history, reviews, KPI, employees, account links, user roles, the approval policy or imports (M: `grep -niE
"payroll|leave|salary|employee|review|kpi|overtime|attendance|medical|import|grant|policy" lib/trail/text.ts` returns only
`je.posted.payroll`, `listTrail.intro.payroll`, `bst.imported`, `bip.*` and unrelated hits).

### 1.4 Estimate of new keys for AT-1d (I)

- 71 catalogue rows, 57 of them HR. EXISTS rows still need a key in `text.ts`, because the trail does not read `messages/en.ts`; 1c did the
  same for its EXISTS rows.
- Likely subjects are about **20–26**:
  - employee (+ employment history, salary change requests, training, the account links);
  - leave request, leave grants / carry-forward (list block), leave type, public holiday, medical claim, overtime batch, attendance period;
  - payroll period (+ lines, requests), performance review (+ goals), review cycle, rating scale, KPI cycle / entries, KPI template /
    position, department;
  - the `/me` own views (leave, medical claim, overtime, review: M8 shape);
  - account (per-account: `user_roles`, `employee_accounts`, ACCOUNT_* ops), `approval_policy`, dictionaries (×6, or one generic shape),
    import batch.
- At 1c's measured 3.7–11.3 keys per subject, plus about 1.2 keys per catalogue row: **about 110–160 new keys**. Reusing `approval.*`,
  `account.*`, `role.*` and `generic.*` saves about 25–35 against writing every sentence fresh.

---

## 2. Ambiguous wordings: one change, several events

Measured from function source (file named) unless marked. The rows already in events.md §6.1 are #4 (overtime → draft), #5 (payroll unpost),
#9 (deleted_at), #12 (auto-approved), #17 (employment change_type) and #19 (self-assessment vs submit). Everything else here is new.

| # | Field change / write | Possible meanings | How to tell them apart |
|--:|---|---|---|
| 1 | `leave_requests.status` →cancelled | withdrawn while pending (no days; the employee may do it) / cancelled after approval (HR only; days come back as `leave_consumption` `release` rows) | old status, or `release` rows in the same txid (`cancel_leave_request.sql`). **Cancel overwrites `decided_at`, `decided_by` and `decision_notes`**, so the approver's stamps vanish from the row; only `approval_log` and change_log keep them |
| 2 | `leave_requests` →approved | one UPDATE + one `leave_consumption` `draw` row per grant drawn | one entry, "Leave approved", with the balance as the detail. Consumption rows must not read "Leave consumption created" (`decide_leave_request.sql`) |
| 3 | `leave_grants` INSERT | carry-forward (`carry_forward_annual_leave`: one call, one grant **per employee**) / entitlement / pro-rata / adjustment (no writer, §1.1) | `grant_type`; a run is one operation across many employees (list block + op_key) |
| 4 | `medical_claims` "paid" | status `paid` is never written; `pay_medical_claim` sets `expense_id` and creates an expense (+ JE) in the same txid | render "Expense raised · EXP-…" on the claim (G11), with the expense side reading `exp.recorded`. `withdraw_medical_claim` sets `withdrawn_at` but **no `withdrawn_by`**: the who comes from the change_log actor |
| 5 | `overtime_batches.status` →draft | created (G16) / taken back from submitted (G18) | INSERT vs UPDATE. **The withdraw NULLs `submitted_at` / `submitted_by`** (`withdraw_overtime_batch.sql:26`), so the old value lives only in change_log |
| 6 | `overtime_batches` →discarded | discarded from draft / discarded after being sent back | old status. **Discard NULLs `decided_at` / `decided_by`** (`discard_overtime_batch.sql:30`), erasing the send-back stamp |
| 7 | `overtime_lines.voided_at` mass UPDATE | caused by a discard (G22) or a reversal (G21) | fold into the batch event; never "N lines voided" |
| 8 | `overtime_lines.day_kind` mass UPDATE | re-stamped on every submit **and** every decide (`submit_overtime_batch`, `decide_overtime_batch`) | noise: suppress it inside those events |
| 9 | `attendance_periods.status` →open | opened (INSERT, G56) / reopened (G58) | INSERT vs UPDATE. **Reopen NULLs `completed_at` / `completed_by` and overwrites `reopened_*` / `reopen_reason`**, so only the last reopen survives on the row (`reopen_attendance_period.sql:48`) |
| 10 | `complete_attendance_period` | period UPDATE + INSERT of missing lines + **two mass UPDATEs** of `attendance_lines` (`frozen_at`, `unpaid_days`, `active_from` / `to`, three OT-hour columns) | one entry, "Attendance period completed"; lines are not separate edits |
| 11 | `payroll_lines` DELETE + INSERT | `upsert_payroll_period` deletes every line and re-inserts it on each save or recompute | set difference by employee (the `set_role_permissions` pattern, AT-0 §6.2). Unchanged lines appear as delete + insert and must not show |
| 12 | `payroll_periods.status` posted→draft | always a reversal (§6.1 #5); `unpost_payroll_period_internal` also **appends `"[YYYY-MM-DD HH:MI unposted …]"` to `notes`** | fold the notes append into "Payroll unposted"; never "Notes edited" |
| 13 | `payroll_requests` | approval (`decide_payroll_request`) and execution (`post_payroll_period` / `unpost_payroll_period` → `executed`, period posted, JE) are **two operations**; INSERT as approved = auto (§6.1 #12) | two entries: "Payroll posting approved", then "Payroll posted for {month}". `kind` (post / reversal) picks the noun. **`label` is built as `code · <raw kind> #n`** (`submit_payroll_request.sql:69`), a machine word in a shown column |
| 14 | `employment_history` change_type `salary_change` | first salary (`set_initial_salary`) / approved change (`salary_change_execute_internal`) / review outcome (`approve_review`) | `old_monthly_salary IS NULL` → "Salary set to …"; writer or same-txid sibling (salary request vs review) |
| 15 | employee edit (`app/hr/employees/actions.ts:300-352`) | `set_user_employee_link` RPC, `employees` UPDATE and `employment_history` INSERT are **three separate requests, so three txids**; hire is two (`:241`, `:251`) | op_key (`'L' \|\| txid`) will **not** merge them. `inferChangeType` keeps one change_type when several change (dept + title → `transfer` only, `:66-74`). The history row's `notes` is a stored `describeChanges()` string built from department / position **codes** |
| 16 | `employees.employment_status` probation→active | app edit (inferred `confirmed`) / `approve_review` probation outcome | writer; a performance_reviews approval in the same txid wins (§6.1 #17) |
| 17 | `approve_review` | review UPDATE + approval_log + **up to 2** `employment_history` INSERTs (confirmed, salary_change) + `employees` (status, confirmation date, salary) | one entry on the review; on the employee, "Confirmed after probation (review …)" |
| 18 | `performance_reviews.status` →self_review | first opening (G46) / **sent back** to the employee (`open_for_self_assessment` clears a set `self_assessment_submitted_at`) | old `self_assessment_submitted_at` non-null → "Self-assessment sent back" (no catalogue row) |
| 19 | `save_self_assessment` | a draft save / the final submit: the same UPDATE, plus a mass UPDATE of `review_goals` | G47 only when `self_assessment_submitted_at` goes null→set; otherwise "Self-assessment edited" |
| 20 | `performance_reviews` direct app UPDATE (`saveHrDecision`, `app/hr/reviews/actions.ts:212`) and `review_cycles` →closed (`:279`) | HR decision fields / cycle closed | change_log only, no function. Wording comes from the columns |
| 21 | `open_review_cycle` | cycle UPDATE + N `performance_reviews` INSERTs | one operation across N review subjects: "Review cycle opened: {n} reviews created". Each review reads "Annual review opened (cycle …)". The guard `status <> 'open'` means a closed cycle can be opened again (I) |
| 22 | `score_kpi_entry` | first score / re-score | old `score` null vs set → "KPI scored" / "KPI re-scored from {a} to {b}" |
| 23 | `employees.user_id` →NULL | plain unlink (`p_employee_id` NULL) / login **moved** to another employee: `set_user_employee_link` NULLs it on A and sets it on B in one txid | same-txid sibling on another employee → "Login moved to {B}", not "Login unlinked" |
| 24 | `employee_accounts` INSERT / **hard DELETE** + `employee_account_history` INSERT | link / unlink (double record) | collapse to one entry. The history row's `employee_id` is **hidden** in the catalogue (`uuid_nofk`), so a history-only read loses whose login it was |
| 25 | `user_roles` INSERT + UPDATE `revoked_*` (`set_user_roles`) | grants and removals in one call (§6.2) | one "Roles changed" with sub-lines. **One `p_reason` is stamped on every revoke in the call.** A re-grant inserts a new row, so a role's rows read granted / removed / granted |
| 26 | account create (`app/settings/accounts/accountActions.ts:121-173`) | `ACCOUNT_CREATE` change_log row, then `set_user_employee_link`, then `set_user_roles`: three RPCs, three txids. `ACCOUNT_DELETE` = the creation rolled back | per-account trail groups by account, not by txid. Disable / enable write the event first and then a `_FAILED` row if the auth call fails (`:222-234`), so an `ACCOUNT_DISABLE` followed by `ACCOUNT_DISABLE_FAILED` means **not disabled**. Render the pair as one |
| 27 | `finance_settings` approval columns | `set_approvals_policy`: UPDATE of 4 columns + INSERT `finance_settings_history` (§6.2). A no-op returns `changed:false` and writes nothing (`set_approvals_policy.sql:51-55`) | one "Approval policy changed" listing each setting. **The history's four `*_approval_level{1,2}_role_code` columns are hidden as `text_code`** in the catalogue, and they are exactly F47's content |
| 28 | `master_import_apply` | dynamic `INSERT INTO <target>` (materials, suppliers, customers, employees, departments, storage_locations: `import_batches.sql:23-24`) for N rows + one `import_batches` row, one txid | on each imported record: "Imported from {file}", not "Created"; one operation across N records |
| 29 | `public_holidays` DELETE (`app/hr/leave/types/actions.ts:59`), `review_goals` / `overtime_lines` DELETE | hard deletes | only change_log DELETE (K03); the row's last values are the detail |
| 30 | `anonymise_employee` | `employees` personal columns → NULL / "ANONYMISED …" and `employment_history` old/new salary → NULL | one "Personal data anonymised" entry. **Never** render the salary NULLs as "Salary changed to —" or the names as edits |

---

## 3. Field labels on the AT-1d tables

Method (M): `lib/trail/catalogue.generated.ts` `TRAIL_FIELDS`. "Shown" means kind ∉ {technical, audit_std, own_key, text_code, uuid_nofk}
(`scripts/check-trail-wording.mjs:154`). "Override" means an entry in `OVERRIDES` (`scripts/gen-trail-catalogue.mjs:82`) at HEAD.
Tables in registry: `grep "'<t>'" db/functions/trail_subject_members.sql db/functions/trail_subjects.sql`.

### 3.1 Totals (M)

| Group | Tables | Columns | Shown | Hidden | Overrides |
|---|--:|--:|--:|--:|--:|
| The 35 tables in the brief (29 HR / settings + 6 dictionaries) | 35 | 491 | **369** | 122 | **0** |
| + `kpi_cycles` (G54), `positions` (KPI templates' parent) | 2 | 26 | 15 | 11 | 0 |
| `roles`, `role_permissions` (AT-1a, already a subject) | 2 | 18 | 9 | 9 | 10 (8 + 2) |
| `finance_settings` (1c-3, `finance_lock` / `finance_gst` root) | 1 | 16 | 13 | 3 | 13 |

Per table, shown / total columns:
- employees 35/40; employment_history 12/15; salary_change_requests 16/19; training_records 9/14; departments 8/13;
- leave_requests 17/22; leave_consumption 6/9; leave_grants 10/15; leave_types 13/19; public_holidays 8/13; medical_claims 14/19;
- overtime_batches 13/17; overtime_lines 7/10; attendance_periods 10/11; attendance_lines 12/13;
- payroll_periods 19/24; payroll_lines 10/12; payroll_requests 18/21;
- performance_reviews 23/28; review_goals 8/13; review_cycles 7/12; review_rating_scale 7/13; kpi_entries 22/27; kpi_position_templates 8/13;
- user_roles 7/8; employee_accounts 4/4; employee_account_history 4/7; finance_settings_history 6/11; import_batches 7/8;
- substances 5/7; battery_chemistries 4/6; material_kinds 6/8; inbound_safety_states 5/7; laboratories 4/6; inbound_source_reasons 5/7.

**None of the 35 tables is in `trail_subject_members` or `trail_subjects` today** (M: 0 grep hits each). Only `finance_settings` is: rows
163-164 and member 366. So no hand override exists on any of them. 1c-3's overrides on `finance_settings` already cover the four approval
columns ("Level-1 approver role", "Level-2 approver role (at or above the threshold)", "Approval threshold (base currency)", "Approvals are
in force"), and the `approval_policy` panel can use them as they are.

**Calibration (M; overrides evaluated from `OVERRIDES` / `ENUM_OVERRIDES` at each commit):**

| Cut | Shown columns (handback) | Overrides (cumulative → added) | Enum values (cumulative → added) |
|---|--:|--:|--:|
| AT-1a | 197 | 219 | 42 |
| 1b-1 | 385 | 310 (+91) | 85 (+43) |
| 1b-2 | 311 | 401 (+91) | 163 (+78) |
| 1b-3 | 145 | 463 (+62) | 209 (+46) |
| 1c-1 | 273 on 23 tables (`AUDIT-TRAIL-1c-1.md:310`) | 539 (+76) | 257 (+48) |
| 1c-2 | 357 on 36 tables (`AUDIT-TRAIL-1c-2.md:556`) | 654 (+115) | 319 (+62) |
| 1c-3 | 76 on 7 tables (`AUDIT-TRAIL-1c-3.md:516`) | 727 (+73) | 330 (+11) |

AT-1d's 369 (384 with `kpi_cycles` and `positions`) sits between 1b-2 and 1b-1. One difference from 1c-2: no `*_history` table here is
large. `finance_settings_history` has 6 shown columns and `employee_account_history` has 4.

### 3.2 Generated labels that read wrong (M from `TRAIL_FIELDS`; the judgment is mine)

**Button, badge or message text:**
- `leave_requests.decided_by` = "Decided by you (flagged)"
- `kpi_entries.employee_id` = "Employee not visible to you"
- `leave_consumption.leave_request_id` = "Request leave"
- `overtime_lines.batch_id` = "New batch"
- `performance_reviews.cycle_id` = "Open cycle"
- `review_goals.review_id` = "Reviews" (nav plural)
- `employee_account_history.action` = "Actions" (column-header plural; the same defect 1c fixed on `fx_rate_history.action`)

**Wrong meaning:**
- `employment_history.effective_date` = "First payroll month" (it is the date the change took effect)
- `public_holidays.holiday_key` = "Identity key" (a machine key; probably HIDE)
- `employees.work_pass_issue_date` = "Issued"
- `employees.user_id`, `user_roles.user_id`, `employee_accounts.user_id`, `employee_account_history.user_id` = "User" (it is a login account)
- `employee_account_history.actor_user_id` = "Actor user"
- `salary_change_requests.decided_via` = "Decided via". It holds a permission code (`action.approve_review` / `action.hr_reviews`,
  `salary_change_requests.sql:80-81`): a machine word, so HIDE it or give it a value map
- `payroll_requests.decision_notes` = "CFO's note" (other request tables say "Decision notes")

**Duplicates within one table (the trail cannot tell them apart):**
- `overtime_batches`: `decided_at` **and** `decided_by` = "Decided by"; `reversed_at` **and** `reversed_by` = "Reversed by"
- `leave_requests`: `is_exception` (boolean) **and** `exception_reason` = "Reason for the exception"

**State word where a timestamp is meant:**
- `kpi_cycles.locked_at` = "Locked"
- `training_records.completed_date` = "Completed" and `expiry_date` = "Expires" are dates, so the same shape

**Casing, abbreviation or language suffix:**
- "Ot normal hours", "Ot public holiday hours", "Ot rest day hours" (`attendance_lines`)
- "Amount SGD" (`medical_claims.amount_sgd`)
- "Certificate ref" (training, leave)
- "Is active" (`positions`) vs "Active" elsewhere
- "Is provisional" (`kpi_position_templates`) vs "Provisional target" (`kpi_entries`)
- "Self assessment submitted on" vs "Overall self-assessment"
- **"Name (EN)" / "Name (ZH)" / "Description (EN)" / "Description (ZH)": 24 columns on 10 tables** (departments, leave_types ×4,
  public_holidays, review_rating_scale ×4, and the 6 dictionaries). AT-1a's `roles` override says "Name (English)" / "(Chinese)". Two
  decisions are open: the suffix style, and whether `_zh` should be shown at all (1c-2 hid `gst_return_boxes.label_zh`, but those were
  machine-written; these are typed by people)

**Generic or raw:**
- `label` = "Label" on `salary_change_requests` and `overtime_batches` (earlier cuts overrode it to "Request" / the record name;
  `payroll_requests.label` already reads "Request")
- "Summary text", "Objective text", "Target text", "Employee result text", "Reviewer assessment text", "Reviewer employee", "Manager
  employee", "Source incumbent name", "Requires certificate after days"
- `import_batches`: "Code first", "Code last", "Row count", "Target table" (the last is an enum of table names with no map)
- `is_active` = "**Status**" (boolean) on all 6 dictionaries, which renders "Status: Yes"
- `employees.monthly_salary_set` = "Monthly salary set" (an internal flag; probably HIDE)
- `payroll_requests.result_journal_entry_id` = "Result journal entry" (1c named this jargon)

**Old / new pairs inconsistent:**
- `finance_settings_history`: "Old approval threshold" vs "New approval threshold (base currency)" vs "Previous approvals enabled" vs "New
  approvals enabled"
- its four role-code pairs are **hidden** (`text_code`, see §2 #27)

**Table names (`TRAIL_TABLES`):**
- "review rating scale" (each row is one rating)
- "employee account history", "finance settings history", "leave consumption" (history tables, which 1c rendered as old→new instead)

### 3.3 Enum columns with no English value map (M: `enums.mjs`, CHECK values in `db/tables/<t>.sql` vs `TRAIL_ENUMS`)

**7 columns, 24 values missing:**
- `medical_claims.status` 5/5 (submitted, approved, rejected, paid, withdrawn); the page uses `claims.state_*`
- `leave_grants.grant_type` 4/4
- `import_batches.target_table` 6/6 (table names; these want the record-type names)
- `employment_history.work_category` 2/2 (office, shopfloor; `employees.work_category` has the map, so it is inheritable)
- `leave_types.gender_restriction` 2/2
- `employee_account_history.action` 2/2 (linked, unlinked)
- `kpi_cycles.status` 3/3

**A further 9 enum / enum_like columns have no CHECK in the repo and no map**, so they would humanize:
- `employees.work_pass_type`
- `employment_history.employment_status` and `employment_type` (the `employees` columns have 4-value maps to inherit)
- `review_goals.unit`
- `kpi_entries.computed_basis`, `evidence_source` and `score_kind` (`score_kind`'s CHECK is live-only, AT-0 §0)
- `kpi_position_templates.evidence_source`
- `kpi_cycles.gate` (live-only CHECK)

### 3.4 Employee-id and JSON columns (M)

- **15 `fk_person` columns.** 12 are `employee_id` on employment_history, salary_change_requests, training_records, leave_requests,
  leave_grants, medical_claims, overtime_lines, attendance_lines, payroll_lines, performance_reviews, kpi_entries and employee_accounts. The
  other 3 are `employees.manager_id`, `departments.manager_employee_id` and `performance_reviews.reviewer_employee_id`. All of them go
  through `trail_ref_label` → `trail_actor` (1c-1 Q12: Restricted without `module.hr.view` unless it is the reader). That rule matters most
  in AT-1d, because every HR row names a person, and `/me` readers hold no `hr.view`.
- **Hidden employee reference:** `employee_account_history.employee_id` is `uuid_nofk`, so it is hidden.
- **31 `actor` columns**, 5 of them a login `user_id` (listed in §3.2).
- **JSON:** `salary_change_requests.snapshot` and `payroll_requests.snapshot` ("Snapshot", jsonb). These want HIDE or a summariser, as 1c did
  for its snapshots. `kpi_entries.org_codes` is an `array` ("Org codes", machine codes).
- **Pay figures:** `employees.monthly_salary`, `employment_history` old/new salary, `salary_change_requests` old/new, payroll period / line /
  request amounts, `performance_reviews.new_monthly_salary`, `medical_claims.amount_sgd`. Masking is survey D-masking's subject, not
  counted here.

---

## 4. Timing calibration

Sources:
- the handbacks' opening-check times;
- session transcripts `~/.claude/projects/-Users-timchen/<id>.jsonl` (`tl.py` / `steps.py`; UTC +8);
- `/tmp/claude-501/at1c*-launch.log` (`run_detached` wait lines, which include the script's own exit line);
- `db/migration-windows.tsv`;
- `git reflog show --date=iso refs/remotes/origin/main` (push times).

The AT-1a … 1b-3 rows are copied from 1c survey E §3.

### 4.1 Sessions (M)

| Cut | Session | Start (opening check) | Idle (user "pause" → "continue") | Backup launched | Apply committed (tsv) | Push (reflog) |
|---|---|---|---|---|---|---|
| AT-1a | fb669b61 | 09-29 11:08:58 | 15:12:18 → 18:20:35 (3 h 08 m 17 s) | 12:59:15 | 13:30:45 | 18:55:08 |
| 1b-1 | 7ccb027b | 19:12:26 (incl. Step 0) | waits only | 20:54:54 | 21:15:05 | 23:26:55 |
| 1b-2 | 76703917 | 23:40:07 (incl. close-out) | — | 00:45:20 | 01:06:27 | 02:57:40 |
| 1b-3 | 00569e2c | 10-03 09:17:57 (incl. close-out) | — | 10:12:15 | 10:31:01 | 12:24:10 |
| 1c Step 0 | 662405c4 | 12:27:47 (STEP0-HANDBACK.md:5) | — | — | — | 12:53:59 (`66a1b331`) |
| 1c-1 | 662405c4 (same session) | 12:58:07 (`AUDIT-TRAIL-1c-1.md:5`) | 13:21:31 → 14:41:10 (1 h 19 m 39 s; "Paused. I've stopped before running any gate") | 15:10:45 (`steps.py`) | 15:26:50 | 17:16:34 (`f2583028`) |
| 1c-2 | a7aabb47 | 17:20:24 (`AUDIT-TRAIL-1c-2.md:6`) | 17:22:12 → 23:57:08 (6 h 34 m 56 s; paused during the step-1 read) | 00:51:52 (first; red after 140 s, pooler closed); retry 00:58:46 → 01:15:48 (1,023 s) | 01:18:22 (+ fu1 01:31:04) | 10-04 03:11:04 (`e282b092`) |
| 1c-3 | d1b93f79 | 10-04 07:38:14 (`AUDIT-TRAIL-1c-3.md:6`) | 08:46:10 → 09:15:53 (29 m 43 s; "pause" typed by Tim, **while the full gate was running**) | 08:28:15 → 08:37:37 (562 s) | 08:39:15 | 10:43:28 (`6104635b`) |

Close-outs: 1c-1's close-out ran inside 1c-2's session, before its build (`AUDIT-TRAIL-1c-2.md` §1), and 1c-2's ran inside 1c-3's.
`0644806a` (1c-3 close-out) was pushed 10:52:39 from the session that launched this survey.

### 4.2 The per-cut table (M; the rate column is I)

| Cut | Start → push | Active (minus idle) | Before backup | Backup → push | Subjects added | Shown columns | text.ts keys | Overrides added | Active min / subject |
|---|---|---|---|---|--:|--:|--:|--:|--:|
| AT-1a | 7 h 46 m 10 s | 4 h 37 m 53 s | 1 h 50 m 17 s | 2 h 47 m 36 s | 3 (+ mechanism, summary page) | 197 | 117 | 219 | 92.6 |
| 1b-1 | 4 h 14 m 29 s | 3 h 36 m 40 s (build) | 1 h 04 m 39 s | 2 h 32 m 01 s | 7 | 385 | 123 | 91 | 31.0 |
| 1b-2 | 3 h 17 m 33 s | 3 h 03 m 58 s (build) | 51 m 38 s | 2 h 12 m 20 s | 11 | 311 | 113 | 91 | 16.7 |
| 1b-3 | 3 h 06 m 13 s | 3 h 06 m 13 s | 54 m 18 s | 2 h 11 m 55 s | 8 | 145 | 54 | 62 | 23.3 |
| 1c-1 | 4 h 18 m 27 s | **2 h 58 m 48 s** | 52 m 59 s | 2 h 05 m 49 s | 7 (+ M7, op_key, Q12) | 273 | 79 | 76 | 25.5 |
| 1c-2 | 9 h 50 m 40 s | **3 h 15 m 44 s** (incl. 1c-1 close-out) | 56 m 32 s | 2 h 19 m 12 s (incl. 6 m 54 s lost to the red first backup) | 8 | 357 | 65 | 115 | 24.5 |
| 1c-3 | 3 h 05 m 14 s | **2 h 35 m 31 s** (incl. 1c-2 close-out) | 50 m 01 s | 1 h 45 m 30 s (pause excluded; the stalled gate ran inside it) | 12 (mostly list blocks / panels) | 76 | 44 | 73 | 13.0 |

Subjects added are measured as distinct codes in `trail_subjects.sql` at each commit (3, 10, 21, 29, 36, 44, 56). Shown columns are
from each handback. Keys and overrides are from §1.3 and §3.1.

**Rates (I, from the M figures):**

| Cut | Keys / active h | Shown columns / active h | Before-backup min / subject |
|---|--:|--:|--:|
| 1b-1 | 34 | 107 | 9.2 |
| 1b-2 | 37 | 102 | 4.7 |
| 1b-3 | 17 | 47 | 6.8 |
| 1c-1 | 27 | 92 | 7.6 |
| 1c-2 | 20 | 109 | 7.1 |
| 1c-3 | 17 | 29 | 4.2 |

Across 1b-2 … 1c-3 the active time per cut has been 2 h 36 m – 3 h 16 m regardless of subject count (8 – 12): a cut costs about 3 h,
and the subject count moves the per-subject rate rather than the total.

### 4.3 Process steps in the 1c cuts (M: handback lines, launch logs, `steps.py`)

| Step | 1c-1 | 1c-2 | 1c-3 |
|---|---|---|---|
| Offline gate | **11 runs × ~70 s**, 14:46:58 → 15:02:31 (~15.5 min of fixture-241 iteration; `AUDIT-TRAIL-1c-1.md:65`) | 66 s (70 s launcher) | 67 s (08:26:55 → 08:28:03) |
| Backup | 842 s | 140 s **red** (pooler) + 1,023 s retry | 562 s |
| Dry run + apply | 92 s (tool) | 99 s; + fu1 85 s | 73 s |
| types:gen | 41 s (incl. a 15 s sleep) | 13 s | 12 s |
| tsc / build | build 64 s + 68 s | tsc 66 s; build2 51 s, red once (currency literal) | tsc 51 s; build ~55 s |
| Full gate | 425 s own (572 s launcher wait) | 441 s **red** (mirror ≠ live) → fu1 → 422 s own (571 s launcher) | **1,500 s timeout (`GATE_EXIT=124`, buffered output)** → rerun 368 s own (481 s launcher) |
| Layout survey 390 + 1280 | 321 s (12 pages) | 411 s (9 pages) | 391 s (16 pages) |
| Route smoke | ~1,261 s (15:48:04 → 16:09:05) | 1,304 s | 983 s |
| Page probe | 349 s for 2 runs; injections 17:03 → 17:15 (12 min) | to 03:08:57 (inside the rerun chain) | 216 s; injections 601 s |
| Live proof | 16:21 → 16:28 (several runs) | 15 s (02:46:38 → 02:46:53) | inside the rerun chain |
| Fix-and-rerun chain after the proof | **34 min** (16:29 → 17:03) | **21 min** (02:47:58 → 03:08:57) | **28 min** (10:10:43 → 10:38:46) |

**Floor numbers (M per step; sum is I):**
- Backup 9.4–17 min (1c) / 16–27 min (1b and 1a). 1c-3's 562 s is the fastest measured.
- Offline gate ~1.1 min.
- Dry run + apply 1.2–1.7 min.
- types + tsc + build ~2.5 min.
- Full gate 6–7.5 min (own time); 9.5 min of launcher wait.
- Survey 5.5–7 min.
- Smoke 16–22 min.
- Probe 3.5–6 min.
- Proof < 1 min (when green).
- Sum: about **50–65 min of pure process per migration cut**.
- Each 1c cut then needed a post-proof fix-and-rerun chain of **21–34 min**, plus a red step: 1c-1 eleven offline-gate runs, 1c-2 a red
  backup and a red gate + fu1 migration, 1c-3 a gate timeout. The measured backup → push is **1 h 46 m – 2 h 19 m** in 1c, against
  2 h 12 m – 2 h 48 m in 1b and 1a.

**Not estimated here:** AT-1d's hours. Per the brief, only the rates above and the floors are given.

---

## 5. Surprises worth a decision

1. **Employee edit and hire are not one transaction** (§2 #15). Two or three PostgREST calls means two or three txids, so op_key merging
   (Q16) cannot fold "employee edited + employment change recorded + login linked" into one entry. Account create is the same (§2 #26).
2. **Several writers erase stamps the trail would read off the row:**
   - leave cancel overwrites the decision;
   - overtime withdraw / discard NULL `submitted_*` / `decided_*`;
   - attendance reopen NULLs `completed_*` and keeps only the last reopen;
   - medical-claim withdraw has no `withdrawn_by`.
   The trail must take these from change_log old values, not the row. This is the AT-1b §9.5 / 1c Q9 pre-log question again.
3. **`finance_settings_history` hides the four approver-role columns** (`text_code`). Those columns are the content of "Level 1 approver
   changed to …" (F47).
4. **`payroll_requests.label` embeds the raw kind** ("· post #1" / "· reversal #1"), and `salary_change_requests.decided_via` is a permission
   code: two machine words in shown columns.
5. **Three duplicate-label pairs** (overtime ×2, leave ×1) and **seven button / message texts as labels**, all on tables with no override
   today.
6. **AT-1d has the most shown columns since 1b-1 (369) and zero overrides on them.** Every one needs the hand check that 1c gave its 706.
