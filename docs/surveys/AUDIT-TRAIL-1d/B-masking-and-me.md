# B — HR masking, own-row rules and `/me` (read-only survey, AT-1d Step 0, 2026-10-04)

HEAD `0644806a`. No code or data was changed.

**How this was measured.** Live queries went through the Management API (`POST /v1/projects/wvywpohbwkiinmipmuku/database/query`). They ran as
**`postgres`, with `rolbypassrls = true`** (measured: `select current_user, rolbypassrls`). RLS therefore did not filter any count below. Every
count is a whole-table count as postgres.
Tags: **M** means measured, by a query or at a file:line. **I** means inferred.

---

## 0. Headline

- **M** `change_log_mask_gaps()` returns `{"gaps": [], "examined_tables": 27, "examined_columns": 81}` (as postgres), and `change_log_mask_rules()` has 81 rows.
  The gate is clean, but only because it compares rules with **`_masked` views**, not with what is on screen or what the row policies allow (change_log_mask_gaps.sql:16-41).
- **M** **The AT-0 salary gap is still open at column level and closed at row level.**
  - `salary_change_requests.old_monthly_salary`, `new_monthly_salary` and `snapshot` have **no** mask rule (change_log_mask_rules.sql:23-103), no `_masked` view, and a whole-table SELECT grant.
  - The table's only read policy is `module.hr.view AND data.view_pay` (salary_change_requests.sql:91). `record_trail` re-checks every member row with `trail_row_visible`, so a reader without `view_pay` (live: cto, gm) gets the **whole row Restricted**, not a leak.
  - **The global reader `change_log_rows()` does not re-check row policies.** It calls only `change_log_mask_row` (change_log_rows.sql:101-105). So it would show the salary figures to any `data.view_change_log` holder who lacks `view_pay`. Live, the holders are admin and cfo, and both hold `view_pay`, so there is **no leak today; the leak is latent**.
  - The same latent hole applies to `performance_reviews`, `review_goals` and `kpi_entries` text for a holder without `data.view_reviews`. Again, admin and cfo both hold it today.
- **M** **There is no bank-detail column on any HR table.** None exists on any table except `company_profile` (§2).
- **M** **There are three own-row hazards for `/me` trails under M8** (§4):
  1. A reviewer's draft edits become visible to the subject once the review is approved.
  2. `employees.notes` and `separation_notes` are not shown on `/me`, but the self policy lets the employee read them.
  3. KPI scores are hidden by `my_kpi_entries` until the cycle closes, but the self policy on `kpi_entries` has no cycle condition.
- **M** **The ActorName rule and `/me` disagree.** `/me` prints the decider, the overtime approver and the manager **by name** to any employee (`my_document_decisions`, `my_overtime_lines`, `my_profile.manager_name`). A `/me` trail would say Restricted for those same people to the one live account without `module.hr.view` (warehouse).

---

## 1. Columns masked on the HR tables

Data codes, live from `permissions` where `code LIKE 'data.%'` (M): `data.view_banking`, `data.view_change_log`, `data.view_deleted`, `data.view_identity`,
`data.view_pay`, `data.view_prices`, `data.view_purchase_prices`, **`data.view_reviews`**, `data.view_sales` and `data.view_self_approvals`.
There is no `data.view_health` or `data.view_banking_employee`.

### 1a. Column masking: column grant + `_masked` view + mask rule (all M)

| table | columns hidden from `authenticated` (column grant) | `_masked` view CASE | mask rule | code |
|---|---|---|---|---|
| employees | work_email, work_phone, identity_no, work_pass_no | employees_masked.sql:36-53 | rules.sql:28-31 | `code_or_self:data.view_identity:id` |
| employees | monthly_salary | employees_masked.sql:64-67 | rules.sql:32 | `code_or_self:data.view_pay:id` |
| employment_history | old_monthly_salary, new_monthly_salary | employment_history_masked.sql:21-28 | rules.sql:33-34 | `code_or_self:data.view_pay:employee_id` |
| payroll_lines | gross_pay, employer_cpf, employee_cpf, other_deductions, net_pay | payroll_lines_masked.sql:13-32 | rules.sql:45-49 | `code_or_self:data.view_pay:employee_id` |
| performance_reviews | new_monthly_salary | performance_reviews_masked.sql:25-28 | rules.sql:50 | `code_or_self:data.view_pay:employee_id` |

- The grant column comes from `has_column_privilege('authenticated', …)` per column. All other HR tables have a whole-table SELECT grant: salary_change_requests, payroll_periods, review_goals, kpi_entries, medical_claims, leave_requests, overtime_lines, attendance_lines, training_records, employee_accounts, employee_account_history, leave_grants and leave_consumption (M).
- **M** There are 13 `code_or_self` rules, all on these 4 tables. That is unchanged since AT-0. AT-0 said there were 80 rules in total; there are now 81, and the extra rule is outside HR.

### 1b. Gated by row policy, not by column (all M)

| table | read rule (live `pg_policies`) | how a trail behaves for a reader who fails it |
|---|---|---|
| salary_change_requests | `hr.view AND view_pay` (salary_change_requests.sql:91) | whole row Restricted in `record_trail`; **unmasked in `change_log_rows`** |
| performance_reviews | `(hr.view AND view_reviews)` OR reviewer OR (self AND status ∈ approved, acknowledged) (performance_reviews.sql:130/134/140) | Restricted / refused |
| review_goals | the same three, through EXISTS on the review (review_goals.sql:49/53/59) | Restricted |
| kpi_entries | `(hr.view AND view_reviews)` OR self (kpi_entries.sql:99/108) | Restricted |
| payroll_lines | hr.view OR (finance.view AND view_pay) OR self (payroll_lines.sql:49/56/85) | Restricted; amounts masked for hr.view holders without view_pay |
| approval_log `salary_change_request` | `hr.view AND view_pay` (approval_log.sql:218) | Restricted |

### 1c. Unmasked columns that look sensitive (M that they are unmasked; whether they should be masked is a question for Tim)

- **employees.** `residency_status`, `work_pass_type`, `work_pass_issue_date`, `work_pass_expiry_date`, `legal_name`, `first_name`, `last_name`, `preferred_name`, `greeting_name`, `notes`, `separation_notes` and `separation_type` are plain in `employees_masked`. The row filter is `hr.view OR self` (employees_masked.sql:44, 49, 54-57, 97). AT-0's claim still holds.
- **salary_change_requests.** `old_monthly_salary`, `new_monthly_salary` and `snapshot` hold `{monthly_salary, employment_status}` (per the column comment). `reason` and `decision_notes` are row-gated only (§0).
- **payroll_periods.** `gross_total`, `employer_cpf_total`, `employee_cpf_total`, `other_deductions_total` and `net_pay_total` are under `hr.view` only (payroll_periods.sql:86). `/hr/payroll/[id]` prints them without a `view_pay` check (page.tsx:139-143, 266-270).
  - **I** With **1 payroll line live** (as postgres), a one-line period's total *is* one person's pay. cto and gm have hr.view without view_pay, so they could read it on screen and in any future period trail.
- **Health-adjacent text, under hr.view only.** `medical_claims.description` and `amount_sgd`, and `leave_requests.reason`, `certificate_ref` and `exception_reason`. 6 of the 7 live accounts hold hr.view (§5).
- **I, by AT-1c precedent.** `review_goals.reviewer_assessment_text` and `kpi_entries.feedback_note` / `evidence_note` are covered by the row rules, not by column rules.

### 1d. Anything hidden on screen by `can()` but not masked in the trail?

- `/hr/employees/[id]` checks `can('data.view_pay')` (page.tsx:88, 436). It hides the salary panel and the salary-change requests, which it reads through `salary_change_requests_visible`, which itself needs hr.view + view_pay (page.tsx:106-128).
  - **M** In `record_trail` this matches the row rule, so there is no leak.
  - **M** In `change_log_rows` it does not match, but there is no live holder affected (§0).
- `/hr/reviews/[id]` checks `can('data.view_pay')` (page.tsx:69). That hides `new_monthly_salary`, which is masked by a rule. No leak.
- `/hr/kpi/score` checks `can('data.view_reviews')` (page.tsx:72). That matches the row rule on `kpi_entries`. No leak.
- `/hr/payroll/[id]` checks `can('data.view_pay')` (page.tsx:68). Lines come through the masked view; the period totals are not gated (1c).
- **Conclusion (M).** No HR column is hidden on screen behind `can()` while visible in `record_trail`. The only mismatches are:
  - the global reader ignoring row rules (latent);
  - screen-only omissions where the self policy is wider than the `/me` screen (§4).

## 2. Banking and identity

- **M** A regex over every public column for `bank|iban|swift|account_no|birth|dob|address|emergency|nationality|passport|phone|mobile|nric|next_of_kin|gender|marital|race|religion` finds on HR tables only `employees.work_phone`.
  - The other hits are `company_profile` bank columns, address and phone; GL `bank_account_code` columns; and `customers.address`, `suppliers.address` and `counterparty_contacts.phone`.
  - There is **no employee bank account, date of birth, home address, personal phone/email or emergency-contact column or table** (the table-name search for `employee|emergency|contact|dependant|bank_acc` found only the employees, account and directory objects and `counterparty_contacts`).
- **M** Masked under `data.view_identity`, with self allowed: `work_email`, `work_phone`, `identity_no` and `work_pass_no`.
  - Holders: admin, cfo, finance (and the `hr` role, which has 0 holders).
  - cco, cto and gm hold hr.view without view_identity.
- **M** Not masked: names, residency, work-pass type and dates.
- **M** `my_profile` returns all identity columns to self (view definition). `export_my_personal_data` returns them too (export_my_personal_data.sql:38-50).

## 3. Own-row read policies (all M, live `pg_policies` = repo)

| table | own-row policy (file:line) | predicate | can an employee read their own rows without hr.view? |
|---|---|---|---|
| employees | "employees select own row" (employees.sql:234) | `id = current_user_employee()` | **yes, every granted column, including `notes` and `separation_notes`** |
| employment_history | "… select own rows" (employment_history.sql:121) | `employee_id = cue()` | yes |
| payroll_lines | "… select own rows" (payroll_lines.sql:85) | `employee_id = cue()` | yes, **with no period-status condition** (draft lines too) |
| leave_requests | "… select own rows" (leave_requests.sql:64) | `employee_id = cue()` | yes |
| medical_claims | "… select own rows" (medical_claims.sql:61) | `employee_id = cue()` | yes |
| leave_grants | "… select own rows" (leave_grants.sql:41) | `employee_id = cue()` | yes |
| training_records | "… select own rows" (training_records.sql:57) | `employee_id = cue()` | yes |
| attendance_lines | single policy (attendance_lines.sql:48) | `hr.view OR employee_id = cue()` | yes |
| kpi_entries | "kpi_entries select own" (kpi_entries.sql:108) | `employee_id = cue()` | **yes, with no cycle-closed condition** |
| performance_reviews | "… select own approved" (performance_reviews.sql:140) | self AND status ∈ approved, acknowledged | only after approval |
| review_goals | "… select own approved" (review_goals.sql:59) | EXISTS review: self AND approved/acknowledged | only after approval |
| employee_accounts | "employee_accounts select" (employee_accounts.sql:46) | hr.view OR manage_permissions OR `user_id = auth.uid()` | yes (own link) |
| expense_claims | (expense_claims.sql:80) | finance.view OR self | yes (the M8 precedent) |
| **overtime_lines** | none (overtime_lines.sql:41) | hr.view OR overtime_enter OR overtime_approve | **no** (`/me` uses the DEFINER function `my_overtime_lines`) |
| salary_change_requests, payroll_periods, leave_consumption, attendance_periods, overtime_batches, kpi_cycles, review_cycles, positions, departments, payroll_requests | none | hr.view (+view_pay), or hr.view / overtime codes | **no** |
| employee_account_history | none (employee_account_history.sql:38) | manage_permissions | no |

- `cue()` stands for `current_user_employee()`, which is `account_person(auth.uid())`: the primary or an additional account (live function definition).
- `code_or_self` rules: the 13 listed in §1a. All of them let the employee see their own salary, identity and pay columns in a trail.

## 4. `/me`

### 4a. What `/me` reads (app/me/page.tsx, M)

| line | source | what the employee sees |
|---|---|---|
| 59 | `my_profile` (DEFINER view, own row) | name, code, job title, employment type/category/status, hire and probation dates, leave rate/accrued/available, residency, work pass (type, no., dates), identity_no, work email/phone, department, **manager name and code**, training count, latest posted payroll, position, greeting name. **Not shown:** `notes`, `separation_*`, `monthly_salary`, `review_exempt` |
| 64 | `my_kpi_entries` (DEFINER view) | entries and targets always; score, kind, basis, evidence and override **only when the cycle is closed**; `feedback_note` **never** |
| 135-138 | `payroll_lines_masked` | own five amounts, all lines including unposted periods |
| 139-144 | `training_records` | own, not deleted |
| 145-149 | `employment_history` | date, change type, title, type, status, `notes` (no salary columns selected) |
| 154 | `leave_balance()` rpc | annual balance |
| 155-158 | `leave_requests` | own, including `decision_notes` |
| 163 | `medical_claim_status` (DEFINER view; hr.view OR self) | own claims, settlement state |
| 165 | `medical_claim_balance()` | |
| 170 | `expense_claim_status` | own claims; the only `/me` trail today is `my_expense_claim` (line 471) |
| 174 | `my_document_decisions()` (DEFINER) | **the decider by name**, the time and the notes for leave, medical and expense (DecisionCell.tsx:24-35) |
| 189 | `my_overtime_lines()` (DEFINER) | approved lines with **the approver by name** (MyOvertimePanel.tsx:29) |
| 190 | `employees_masked.is_site_staff` | |
| 207-216 | `attendance_lines` + `attendance_periods` | own lines. **The periods read is hr.view only** (attendance_periods.sql:46-48), although the comment at page.tsx:205-206 says it lets self in. **I:** a non-HR employee gets "—" codes |
| 238-239 | `my_self_assessment(_goals)` | only while status = self_review |
| 240-245 | `performance_reviews_masked` (REVIEW_COLUMNS, reviewShared.ts:45-50) | approved/acknowledged reviews: rating, summary, self-assessment, probation outcome, new salary. **Not `notes`** |
| 250-257 | `review_goals` | including `reviewer_assessment_text` |
| 263-266 | `payroll_periods` | **hr.view only**. **I:** a non-HR employee's payslips lose code and month |

### 4b. Could each own record have a trail under M8?

M8 means empty `view_codes` and `root_rule = 'table'`. The root row's own policy is evaluated on its **current** image (record_trail.sql:94-107). After that, **every logged change of the root row is shown** (record_trail.sql:179: `i = 1 AND root_rule = 'table'` makes the root visible), and every member row is judged on its current image too.

| own record (root) | M8 possible? | members that would read Restricted to a non-HR employee | hazards |
|---|---|---|---|
| employees (profile) | **yes** | employment_history: visible. approval_log: none. employee_accounts: own only | **`notes` and `separation_notes` are HR-internal on screen** (/hr/employees/[id] page.tsx:372-375 shows notes; my_profile omits them), but the self policy lets them through and there is no mask rule. `monthly_salary` changes are visible to self by `code_or_self` although `/me` never prints salary. `manager_id` and person references resolve through `trail_actor`, so they read **Restricted** while `/me` prints the manager by name |
| employment_history | yes (or as a member of employees) | none | `notes` is already shown on `/me`. **M:** old/new salary are visible to self by rule but not selected on `/me` |
| payroll_lines (payslip) | yes | payroll_periods (hr.view only) **Restricted**; journals finance | **Churn:** `upsert_payroll_period` deletes and re-inserts every line on re-import (upsert_payroll_period.sql:78, 118), so a line's id changes and its trail begins at the last import. A trail keyed on the line shows "created" only. **I:** a period-keyed own trail is impossible (periods are hr.view). Draft lines are visible to self (no status condition) |
| leave_requests | yes | approval_log `leave_request` (hr.view) **Restricted**; leave_consumption (hr.view) **Restricted**; leave_grants own visible | **Who decided:** `decided_by` goes through `trail_actor`, so it reads **Restricted** for a non-HR employee, while DecisionCell prints the name. HR can submit on someone's behalf with `is_exception` / `exception_reason` (submit_leave_request.sql:41, 117-120). That text is visible to self, which is **I** fine |
| medical_claims | yes | approval_log `medical_claim` **Restricted**; expense/payment (finance) **Restricted** | same decider mismatch. `description` is health text, self-visible, which is correct |
| expense_claims | **already live** (`my_expense_claim`) | approval and expense Restricted (AT-1c-3 Q4) | same decider mismatch, already accepted in 1c-3 |
| overtime_lines | **no**: no own-row policy, so TRAIL_NOT_PERMITTED | — | would need a self policy, or M3-style `root_rule` handling. `/me` shows only approved lines through a DEFINER function |
| attendance_lines | yes | attendance_periods (hr.view) Restricted | — |
| performance_reviews + review_goals | **yes, but only once approved/acknowledged**; before that it is refused | approval_log `performance_review` (hr.view) Restricted | **The reviewer's draft edits leak.** Visibility is decided on today's status, so after approval every earlier change (draft `summary_text`, `rating_code`, edits to `reviewer_assessment_text` during draft/self_review/submitted, `void_reason`) and the HR-only `notes` column (not in REVIEW_COLUMNS) are shown to the subject. Live: **0 reviews** (as postgres); the change_log holds 144 performance_reviews rows, all fixture insert/update/delete |
| kpi_entries | yes | kpi_cycles (hr.view) Restricted | **Score leak:** `score`, `score_kind`, `evidence_note`, `override_*` and `feedback_note` changes during an open cycle would show, while `my_kpi_entries` hides them until close. **M:** the same columns are already readable today by a self API call (whole-table grant + self policy). Live: 30 entries, all cycles open, 0 scored (as postgres) |
| training_records | yes | none | `notes` is not shown on `/me` (MyTrainingTable selects no notes); **I** low risk |
| leave_grants | yes (own) | — | `notes` is HR-written; **I** low risk |

**What HR sees instead.** Holders of hr.view (+ view_pay + view_reviews where needed) see every member, every name, salary requests and review drafts. finance holds hr.view but not view_reviews, so it sees review rows as Restricted. cto and gm hold hr.view but not view_pay, so they see salary requests Restricted and pay masked (M, §5).

**Precedent.** `export_my_personal_data` already gives the employee every `change_log` row of their own `employees` row, **including `notes`** (only account keys are removed). It names the changer **without** any hr.view check (export_my_personal_data.sql:71-83). It deliberately omits review text (line 84).

## 5. ActorName rule and live roles (M, `user_roles.revoked_at IS NULL`, active and non-deleted roles; postgres)

| role | holders | hr.view | hr.edit | view_pay | view_identity | view_reviews | view_change_log | manage_perm | decide_hr | other |
|---|---|---|---|---|---|---|---|---|---|---|
| admin | 1 | Y | Y | Y | Y | Y | Y | Y | Y | approve_review, hr_reviews, overtime_* |
| cfo | 1 | Y | – | Y | Y | Y | Y | **–** | Y | approve_review |
| cco | 1 | Y | Y | Y | – | Y | – | – | Y | hr_reviews |
| finance | 1 | Y | Y | Y | Y | **–** | – | – | Y | overtime_enter |
| cto | 1 | Y | – | **–** | – | Y | – | – | – | |
| gm | 1 | Y | – | **–** | – | Y | – | – | – | |
| warehouse | 1 | **–** | – | – | – | – | – | – | – | overtime_approve |
| auditor, hr, employee, procurement, sales | 0 | | | | | | | | | |

- There are 7 auth accounts; all 7 are linked to a person (`account_person`). There are 22 employees: 7 live and 15 soft-deleted.
- **Only the warehouse account lacks `module.hr.view`.**
- `trail_actor` (trail_actor.sql:27, 44-46) returns `restricted` for anyone other than the reader when the reader lacks hr.view. `trail_ref_label` routes `employees.id` references through it (trail_ref_label.sql:61-68).
- **Confirmed (M, code; I, for the effect).** For the warehouse employee, a `/me` trail would show the leave decider, the overtime approver, the reviewer and the manager as **Restricted**. The same page shows those names in DecisionCell, MyOvertimePanel and the manager field.
- Every other live account sees names in HR trails.
- The warehouse account also holds `action.overtime_approve`, so it can read **everyone's** `overtime_lines` and `overtime_batches` (overtime_lines.sql:41). In such a trail every name would read Restricted (**I**).

## 6. `auth.users` rows in the change log

- **M** **0 rows** with `table_name LIKE 'auth.%'` (as postgres; 3,820 change_log rows in total). There is no trigger on `auth.users`. Rows come only from `record_account_event()` (HISTORY-1 migration :969-1048), which needs `action.manage_permissions`; it stores `new = {email, …detail}`.
- **M** **Readers.**
  - `change_log_rows()` needs `data.view_change_log` (admin, cfo). There is no mask rule for `auth.users`, so **the email is unmasked**. It renders as an "Email" line (lib/trail/render.ts:848-852).
  - The same function also returns `actor_email` for every row (change_log_rows.sql:61, 67). The UI does not render it, but a direct RPC call returns it.
  - **cfo holds view_change_log without manage_permissions.** That contradicts AT-0's "only manage_permissions readers should see them". There is no practical leak today, because cfo holds view_identity.
- **M** `record_trail` cannot reach these rows. No member is `auth.%` (count 0), and `trail_row_visible` returns false for a non-public table (trail_row_visible.sql:28-33). `change_log_rows` also skips refs and record for them (change_log_rows.sql:105).

## 7. Rules or decisions AT-1d needs (I, recommendations)

1. **Make `change_log_rows` re-check row policies** (`trail_row_visible`, with `row_hidden` as on page trails), **or** add column rules for `salary_change_requests` (`code_or_self:data.view_pay:employee_id` on old, new and snapshot). The row re-check also closes the reviews/KPI gap for the global reader. Neither has an effect on live today.
2. **Reviews on `/me`.** Either root the trail in a way that excludes pre-approval rows (for example, show only rows from `approved_at` onward plus the lifecycle stamps), or rule that pre-approval edits stay hidden. A new mechanism is needed: "visible as of when", not "visible now". Hide `notes` with a new rule form, or drop it from the subject's columns (M6 `root_columns`).
3. **KPI on `/me`.** Hide score and evidence columns until the cycle closes, through a new rule (for example `kpi_closed`) or `root_columns`. Also consider tightening the `kpi_entries select own` policy (an existing API-level exposure).
4. **The employee profile on `/me`.** Exclude `notes`, `separation_notes` and `review_exempt` (M6 `root_columns`), or rule that self may see them (the export already does).
5. **Names on `/me`.** Decide whether trails on `/me` follow ActorName (Restricted) or the EMP-SELF-1 exception (the decider, approver and manager by name). It affects only warehouse today.
6. **Payslips.** A trail per payroll line is meaningless with delete-and-reinsert. Either no trail, or key on (period, employee).
7. **Overtime.** There is no own-row policy, so there can be no M8 trail without a new self policy.

## 8. Questions for Tim

- Q-B1: Should the global change-history reader follow row rules (record_trail parity), or should `salary_change_requests` get column rules?
- Q-B2: Should the subject see the reviewer's pre-approval edits and the HR `notes` in a review trail? (Recommended: no.)
- Q-B3: The KPI self policy exposes open-cycle scores through the API. Tighten it now or leave it to AT-1d?
- Q-B4: `/me` trails: Restricted names (ActorName) or names (as DecisionCell)?
- Q-B5: Should health text (medical description, leave reason) and the single-line payroll period totals stay hr.view-only, with no data code?
- Q-B6: Side finding: `attendance_periods` and `payroll_periods` are hr.view only, but `/me` reads them for non-HR staff. The comment at page.tsx:205-206 says self is allowed. Is this a bug?
