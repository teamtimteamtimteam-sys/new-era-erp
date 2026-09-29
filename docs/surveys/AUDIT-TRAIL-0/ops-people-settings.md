# AUDIT-TRAIL-0 — Operation map: People (HR, /me, /my-reviews) + Settings + auth/notifications

Slice: app/hr/**, app/me/**, app/my-reviews/**, app/settings/**, app/notifications/**, app/login/**, app/logout/**,
app/set-password/**, app/welcome/**, app/verify/**, app/page.tsx, 'use server' files under app/components/**.
Survey date 2026-09-29. Read-only. Live queries ran as `postgres` (rolbypassrls = true) inside `BEGIN READ ONLY … ROLLBACK`.

## 0. Counts and method

| Number | What | Method | Status |
|---|---|---|---|
| 24 | 'use server' files in slice (incl. app/components/search/actions.ts) | `grep -rlE "^['\"]use server['\"]"` over the slice dirs | Measured |
| 90 | exported async functions in those 24 files | `grep -cE "^export async function"` over the same files | Measured |
| 84 | of the 90 that write something (DB row, auth, storage) | 90 minus 6 non-writers read by hand: searchEverything, localizeKpiError, localizeLeaveError, previewLeaveDays, landingAfterSetPassword, previewImport (dry run: master_import_apply p_dry_run=true always RAISEs → rolled back) | Measured (by reading) |
| 1 | writing export with NO caller: `deleteEmployee` (app/hr/employees/actions.ts:358) | `grep -rn deleteEmployee app` → only the definition | Measured |
| 83 | writing exports reachable from a UI control | 84 − 1 | Measured |
| +2 | foreign actions invoked from /me: `submitClaim`, `withdrawClaim` (app/finance/claims/actions.ts → submit_expense_claim / withdraw_expense_claim) | imports in app/me/MyExpenseClaimsPanel.tsx:30 | Measured |
| +1 | non-action write: GET /verify/cod/[token] → rpc cod_verification (writes cod_verification_failures D/I, rate limiter) | app/verify/cod/[token]/route.ts:65 + fnmap.json | Measured |
| 6 | other 'use server' files under app/components (finance attachment, inventory stock, warehouse request, metals content, pricing terms, search) — 5 belong to other modules, search is read-only | same grep on app/components | Measured |
| 54 | page.tsx files in slice (hr, me, my-reviews, settings, notifications, login, set-password, welcome) | `find … -name page.tsx \| wc -l` | Measured |
| 0 | writes on app/page.tsx (home) and app/welcome/page.tsx | grep for rpc/from/actions imports: none | Measured |
| 57 | distinct writing RPCs called from the slice (incl. cod_verification; excl. finance-owned set_finance_settings, submit/withdraw_expense_claim) | hand list of every `.rpc(` in the slice's writers, `wc -w`; tables from at0/fnmap.json `direct`/`all` | Measured |
| 180 | change_log rows on live; of those in this slice's tables: employees 6, performance_reviews 3, role_permissions 146, roles 2, user_roles 2, permissions 1, cod_verification_failures 2 | `SELECT table_name, op, count(*) FROM change_log GROUP BY 1,2` (as postgres, bypasses RLS) | Measured |
| 0 | rows in auth.audit_log_entries (login/logout/password leave no trace anywhere) | `SELECT count(*) FROM auth.audit_log_entries` (as postgres) | Measured |
| 0 | triggers on public.notification_reads → mark-read is NOT in change_log | at0/triggers.csv | Measured |

Legend: **EVENT** = key business event (state transition / approval / money / access); **edit** = plain field edit.
"CL" = the table carries the generic change_log trigger (at0/triggers.csv, name contains change_log). Every public table
written below carries CL **except notification_reads** (Measured). `approval_log` I rows come from `record_approval_decision`
(fnmap `all`). Permission code = DB-side gate (require_permission in the RPC, or the table's RLS + enforce_write_permission
trigger arg read from `pg_get_triggerdef`); page gates listed in §3.

---

## 1. Operation map (grouped as the user thinks)

### 1a. Employees and organisation

| # | User words | UI entry (route · control file) | Server action | RPC(s) | Permission | Tables written | PRIMARY RECORD | Trail page | Kind |
|---|---|---|---|---|---|---|---|---|---|
| E1 | Hire / add an employee | /hr/employees/new · app/hr/employees/EmployeeForm.tsx | app/hr/employees/actions.ts:createEmployee | set_user_employee_link (if account chosen) | module.hr.edit (RLS+trigger on employees, RLS on employment_history); link: action.manage_permissions | employees I, employment_history I (change_type 'hired'), employees U (user_id link) | employees row | /hr/employees/[id] (app/hr/employees/[id]/page.tsx) | EVENT (hired) |
| E2 | Edit employee details | /hr/employees/[id]/edit · EmployeeForm.tsx | actions.ts:updateEmployee | set_user_employee_link (link/unlink account) | module.hr.edit; link: action.manage_permissions | employees U; employment_history I when dept/position/type/status changed (inferChangeType) | employees row | /hr/employees/[id] | edit; EVENT when dept/position/status change (transfer, promotion, separation) or account link changes |
| E3 | Remove (soft-delete) an employee | none — `deleteEmployee` has no caller | actions.ts:deleteEmployee | — | module.hr.edit | employees U deleted_at | employees | /hr/employees/[id] | EVENT (dead code) |
| E4 | Set starting salary | /hr/employees/[id] · InitialSalaryForm.tsx | actions.ts:setInitialSalary | set_initial_salary | module.hr.edit + data.view_pay | employees U (monthly_salary), employment_history I | employees | /hr/employees/[id] | EVENT (pay) |
| E5 | Propose a salary change | /hr/employees/[id] · SalaryChangePanel.tsx | salaryChangeActions.ts:submitSalaryChange | submit_salary_change_request | module.hr.edit + data.view_pay | salary_change_requests I, approval_log I | salary_change_requests row | /hr/employees/[id] | EVENT |
| E6 | Approve / reject a salary change (executes it) | /hr/employees/[id] · SalaryChangePanel.tsx | salaryChangeActions.ts:decideSalaryChange | decide_salary_change_request | module.hr.view + data.view_pay (+ SoD) | salary_change_requests U, approval_log I, employees U (salary), employment_history I | salary_change_requests (child effect on employees) | /hr/employees/[id] | EVENT (approval + pay) |
| E7 | Withdraw a salary change | same | salaryChangeActions.ts:withdrawSalaryChange | withdraw_salary_change_request | module.hr.edit + data.view_pay | salary_change_requests U | salary_change_requests | /hr/employees/[id] | EVENT |
| E8 | Add / edit a department | /hr/departments/new, /[id]/edit · DepartmentForm.tsx | departments/actions.ts:saveDepartment | — (direct insert/update) | module.hr.edit | departments I/U | departments row | /hr/departments (no detail page; edit page /hr/departments/[id]/edit) | edit |
| E9 | Delete a department | /hr/departments · DeleteDepartmentButton.tsx | departments/actions.ts:deleteDepartment | — | module.hr.edit | departments U deleted_at | departments | /hr/departments/[id]/edit (row gone from list) → also /settings/deleted | EVENT |
| E10 | Record / edit a training | /hr/training/new, /[id]/edit · TrainingForm.tsx | training/actions.ts:saveTraining | — | module.hr.edit | training_records I/U | training_records row | /hr/training/[id]/edit and roll-up on /hr/employees/[id] | edit |
| E11 | Delete a training record | /hr/training · DeleteTrainingButton.tsx | training/actions.ts:deleteTraining | — | module.hr.edit | training_records U deleted_at | training_records | /hr/employees/[id] (roll-up) | EVENT |
| E12 | Anonymise an employee (PDPA) | **no UI** — RPC `anonymise_employee` exists, no app caller (grep: only comments in employees/actions.ts:215,279) | — | anonymise_employee → change_log_redact_employee | action.anonymise_employee | employees U, employment_history U, **change_log U** (redaction) | employees | /hr/employees/[id] (when a UI exists) | EVENT — note it rewrites change_log itself |
| E13 | Bulk-import employees / departments (and customers, suppliers, materials, storage locations) | /settings/import · ImportForm.tsx | settings/import/actions.ts:commitImport | master_import_apply (dynamic INSERT; target tables inferred from string literals) | action.bulk_import | target table I, import_batches I | import_batches row (one per file) | /settings/import (ImportHistoryTable already lists batches) | EVENT |

### 1b. Leave, claims, overtime, attendance

| # | User words | UI entry | Server action | RPC(s) | Permission | Tables written | PRIMARY RECORD | Trail page | Kind |
|---|---|---|---|---|---|---|---|---|---|
| L1 | Apply for leave (HR for someone, or self on /me) | /hr/leave/new · LeaveForm.tsx; /me · MyLeavePanel.tsx (embeds LeaveForm) | hr/leave/actions.ts:submitLeave | submit_leave_request | module.hr.edit OR self (current_user_employee) | leave_requests I | leave_requests row | /hr/leave/[id] | EVENT |
| L2 | Approve / reject leave | /hr/leave/[id] · DecideControls.tsx | leave/actions.ts:decideLeave | decide_leave_request | action.decide_hr_requests (+ forbid_self_approval) | leave_requests U, leave_consumption I, approval_log I | leave_requests | /hr/leave/[id] | EVENT |
| L3 | Cancel leave | /hr/leave/[id] · DecideControls.tsx; /me · MyLeavePanel.tsx | leave/actions.ts:cancelLeave | cancel_leave_request | module.hr.edit OR self | leave_requests U, leave_consumption I | leave_requests | /hr/leave/[id] | EVENT |
| L4 | Carry forward annual leave for a year | /hr/leave/grants · GrantRunner.tsx | leave/actions.ts:runCarryForward | carry_forward_annual_leave | module.hr.edit | leave_grants I (many employees) | a year-run with no document (N leave_grants rows) | /hr/leave/grants (run-level trail) + per-employee roll-up | EVENT (batch, no document) |
| L5 | Change a leave type's rules | /hr/leave/types · LeaveTypesEditor.tsx | leave/types/actions.ts:saveLeaveType | — | module.hr.edit | leave_types U (by code) | leave_types row (collection setting) | /hr/leave/types | edit (setting) |
| L6 | Add / edit / delete a public holiday | /hr/leave/holidays · HolidaysEditor.tsx, HolidaysTable.tsx | leave/types/actions.ts:saveHoliday, deleteHoliday | — | module.hr.edit | public_holidays I/U/**D (hard delete)** | public_holidays row | /hr/leave/holidays | edit (setting); delete is hard |
| C1 | Submit a medical claim (HR, or self on /me) | /hr/claims/new · ClaimForm.tsx; /me · MyClaimsPanel.tsx (embeds ClaimForm) | hr/claims/actions.ts:submitClaim | submit_medical_claim | module.hr.edit OR self | medical_claims I | medical_claims row | /hr/claims/[id] | EVENT |
| C2 | Approve / reject a medical claim | /hr/claims/[id] · ClaimControls.tsx | hr/claims/actions.ts:decideClaim | decide_medical_claim | action.decide_hr_requests | medical_claims U, approval_log I | medical_claims | /hr/claims/[id] | EVENT |
| C3 | Withdraw my medical claim | /me · MyClaimsPanel.tsx | hr/claims/actions.ts:withdrawMedicalClaim | withdraw_medical_claim | module.hr.edit OR self | medical_claims U | medical_claims | /hr/claims/[id] | EVENT |
| C4 | Pay a medical claim (creates expense + journal) | /hr/claims/[id] · ClaimControls.tsx | hr/claims/actions.ts:payClaim | pay_medical_claim | module.finance.edit | medical_claims U; expenses I, journal_entries I, journal_lines I (+ fnmap upper bound adds fixed_asset*, equipment_maintenance via expense path) | medical_claims (child: the expense + journal) | /hr/claims/[id]; also the expense page in finance | EVENT (money) |
| C5 | Submit / withdraw an expense claim from /me | /me · MyExpenseClaimsPanel.tsx | **app/finance/claims/actions.ts**:submitClaim, withdrawClaim (finance-owned) | submit_expense_claim, withdraw_expense_claim | fn checks has_permission / self | expense_claims I / U | expense_claims row | finance claims detail page (finance slice) | EVENT |
| O1 | Start an overtime batch for a month | /hr/overtime · NewBatchForm.tsx | hr/overtime/actions.ts:createOvertimeBatch | create_overtime_batch | action.overtime_enter | overtime_batches I | overtime_batches row | /hr/overtime/[id] | EVENT |
| O2 | Add / remove an overtime line | /hr/overtime/[id] · BatchDetail.tsx | addOvertimeLine, deleteOvertimeLine | add_overtime_line, delete_overtime_line | action.overtime_enter | overtime_lines I / **D (hard)** | overtime_batches (child overtime_lines) | /hr/overtime/[id] | edit |
| O3 | Submit / withdraw / discard / reverse a batch | same | submitOvertimeBatch, withdrawOvertimeBatch, discardOvertimeBatch, reverseOvertimeBatch | submit_/withdraw_/discard_/reverse_overtime_batch | action.overtime_enter | overtime_batches U, overtime_lines U, approval_log I (submit) | overtime_batches | /hr/overtime/[id] | EVENT |
| O4 | Approve / reject overtime | same | decideOvertimeBatch | decide_overtime_batch | action.overtime_approve | overtime_batches U, overtime_lines U, approval_log I | overtime_batches | /hr/overtime/[id] | EVENT |
| A1 | Open an attendance month | /hr/attendance · OpenPeriodForm.tsx | hr/attendance/actions.ts:openAttendancePeriod | open_attendance_period | module.hr.edit | attendance_periods I, attendance_lines I | attendance_periods row | /hr/attendance/[id] | EVENT |
| A2 | Record attendance for a person | /hr/attendance/[id] · AttendanceGrid.tsx | recordAttendance | record_attendance | module.hr.edit | attendance_lines U | attendance_periods (child line) | /hr/attendance/[id] | edit |
| A3 | Sync staff into the month | same | syncAttendancePeriod | sync_attendance_period | module.hr.edit | attendance_lines I | attendance_periods | /hr/attendance/[id] | edit (system-ish) |
| A4 | Complete / reopen the month | same | completeAttendancePeriod (may call sync), reopenAttendancePeriod (reason) | complete_/reopen_attendance_period | module.hr.edit | attendance_periods U, attendance_lines IU | attendance_periods | /hr/attendance/[id] | EVENT |

### 1c. Payroll

| # | User words | UI entry | Server action | RPC(s) | Permission | Tables written | PRIMARY RECORD | Trail page | Kind |
|---|---|---|---|---|---|---|---|---|---|
| P1 | Prepare / edit a payroll run | /hr/payroll/new, /[id]/edit · PayrollGrid.tsx | hr/payroll/actions.ts:savePayrollPeriod | upsert_payroll_period | module.hr.edit | payroll_periods I/U, payroll_lines **D + I (lines replaced wholesale)** | payroll_periods row | /hr/payroll/[id] | edit (line diffs appear as delete+insert pairs) |
| P2 | Submit payroll for approval | /hr/payroll/[id] · PostControls.tsx | submitPayrollRequest | submit_payroll_request | module.hr.edit | payroll_requests I, approval_log I (+ posts when approvals off: payroll_periods U, journal_entries/lines I) | payroll_periods (child payroll_requests) | /hr/payroll/[id] | EVENT |
| P3 | Approve / reject payroll | same | decidePayrollRequest | decide_payroll_request | module.hr.view + data.view_pay (+ SoD, approvals_enabled) | payroll_requests U, approval_log I, on approve payroll_periods U + journal I | payroll_periods | /hr/payroll/[id] | EVENT (money) |
| P4 | Withdraw payroll request | same | withdrawPayrollRequest | withdraw_payroll_request | module.hr.edit | payroll_requests U | payroll_periods | /hr/payroll/[id] | EVENT |
| P5 | Post / unpost payroll (run payroll into the books) | same | postPayroll, unpostPayroll | post_payroll_period, unpost_payroll_period | module.hr.edit | payroll_periods U, payroll_requests U, journal_entries I(U), journal_lines I | payroll_periods | /hr/payroll/[id] (+ journal page) | EVENT (money) |

### 1d. Performance reviews and KPI

| # | User words | UI entry | Server action (app/hr/reviews/actions.ts unless noted) | RPC(s) | Permission | Tables written | PRIMARY RECORD | Trail page | Kind |
|---|---|---|---|---|---|---|---|---|---|
| R1 | Create a review cycle | /hr/reviews/cycles · CycleForm.tsx | createCycle | — (direct insert) | action.hr_reviews | review_cycles I | review_cycles row | /hr/reviews/cycles (no cycle detail page) | EVENT |
| R2 | Open a cycle (creates reviews for everyone) | /hr/reviews/cycles · CycleActions.tsx | openCycle | open_review_cycle | action.hr_reviews | review_cycles U, performance_reviews I (many) | review_cycles | /hr/reviews/cycles | EVENT (batch) |
| R3 | Close a cycle | same | closeCycle | — (direct update status) | action.hr_reviews | review_cycles U | review_cycles | /hr/reviews/cycles | EVENT |
| R4 | Raise a probation review | /hr/employees/[id] · RaiseProbationReview.tsx | raiseProbationReview | open_probation_review | action.hr_reviews | performance_reviews I | performance_reviews row | /hr/reviews/[id] (+ roll-up /hr/employees/[id]) | EVENT |
| R5 | Assign / change the reviewer | /hr/reviews/[id] · SetReviewerControl.tsx | setReviewer | set_review_reviewer | action.hr_reviews | performance_reviews U | performance_reviews | /hr/reviews/[id] | EVENT |
| R6 | Add / edit / remove goals; record actuals; assess goals | /hr/reviews/[id] and /my-reviews/[id] · GoalsEditor.tsx | addGoal, updateGoal, removeGoal, setGoalActual, setGoalAssessment | add_/update_/remove_review_goal, set_goal_actual_value, set_goal_assessment | reviewer-of (require_reviewer_of, status draft/self_review); set_goal_actual_value: action.hr_reviews | review_goals I/U/**D (hard)** | performance_reviews (child review_goals) | /hr/reviews/[id] and /my-reviews/[id] | edit |
| R7 | Write the conclusion / rating | same · ConclusionForm.tsx | setConclusion | set_review_conclusion | reviewer-of | performance_reviews U | performance_reviews | same | edit |
| R8 | Open for self-assessment / submit / approve / void | /hr/reviews/[id], /my-reviews/[id] · ReviewActions.tsx | openSelfAssessment, submitReview, approveReview, voidReview | open_for_self_assessment, submit_review, approve_review, void_review | action.hr_reviews (open/submit/void); approve: review_approval_code(submitter, subject) + forbid_self_approval | performance_reviews U, approval_log I; approve also employees U + employment_history I (confirmation / salary) | performance_reviews | /hr/reviews/[id] (+ /my-reviews/[id]) | EVENT (approve may change pay/status) |
| R9 | HR decision on probation (outcome, new salary, effective date) | /hr/reviews/[id] · HrDecisionForm.tsx | saveHrDecision | — (direct update) | action.hr_reviews (+ guard_performance_review_write trigger) | performance_reviews U (probation_outcome, new_monthly_salary, salary_effective_date) | performance_reviews | /hr/reviews/[id] | edit (pay-bearing) |
| R10 | Write my self-assessment | /me · MySelfAssessmentPanel.tsx | saveSelfAssessment | save_self_assessment | self (subject only) | performance_reviews U, review_goals U | performance_reviews | /hr/reviews/[id] (HR/reviewer); subject sees own on /me | EVENT (submit) / edit (draft) |
| R11 | Acknowledge my review | /me · MyReviewsPanel.tsx | acknowledgeReview | acknowledge_review | self (subject only) | performance_reviews U, approval_log I | performance_reviews | /hr/reviews/[id]; subject on /me | EVENT |
| R12 | Edit the rating scale | /hr/reviews/scale · ScaleEditor.tsx | scale/actions.ts:saveRatingScale | — | action.hr_reviews | review_rating_scale I/U (by code) | review_rating_scale row (collection setting) | /hr/reviews/scale | edit (setting) |
| K1 | Generate missing KPI entries for a person+cycle | /hr/kpi/score · GenerateMissing.tsx | kpi/score/actions.ts:generateKpiEntries | assign_position_kpis | action.hr_reviews | kpi_entries I | kpi_entries (per employee × cycle) | /hr/kpi/score (no per-entry page) | EVENT (batch) |
| K2 | Score a KPI entry | /hr/kpi/score · ScoreEditor.tsx | kpi/score/actions.ts:scoreKpiEntry | score_kpi_entry | action.hr_reviews | kpi_entries U | kpi_entries row | /hr/kpi/score (+ subject on /me) | edit |

### 1e. Accounts, roles, permissions (settings)

| # | User words | UI entry | Server action | RPC / admin call | Permission | Tables written | PRIMARY RECORD | Trail page | Kind |
|---|---|---|---|---|---|---|---|---|---|
| S1 | Create a login account (optionally linked to an employee, with roles) | /settings/accounts · CreateAccountPanel.tsx | app/settings/accounts/accountActions.ts:createAccount | service-role `auth.admin.createUser` (+ `deleteUser` on rollback), record_account_event('ACCOUNT_CREATE' / 'ACCOUNT_DELETE'), set_user_employee_link, set_user_roles | action.manage_permissions | auth.users I; change_log I (table_name 'auth.users', op = event); employees U (user_id); user_roles I | the account (auth.users id) | /settings/accounts — no per-account page exists | EVENT (access) |
| S2 | Disable / enable an account | /settings/accounts · UserRow.tsx | accountActions.ts:disableAccount, enableAccount | record_account_event (DISABLE/ENABLE, *_FAILED on ban failure), `auth.admin.updateUserById(ban_duration)` | action.manage_permissions (+ CANNOT_DISABLE_SELF, LAST_ADMIN_PROTECTED) | change_log I; auth.users U (banned_until) | account | /settings/accounts | EVENT |
| S3 | Grant / revoke roles to an account; link the account to an employee | /settings/accounts · UserRow.tsx | app/settings/accountsActions.ts:saveUserRoles | set_user_roles, set_user_employee_link | action.manage_permissions (+ guard_last_admin) | user_roles I/U (revoked_at, revoke_reason), employees U (user_id) | account (user_roles by user_id) | /settings/accounts; also the role page /settings/roles/[id] (members) and /hr/employees/[id] (link) | EVENT (access) |
| S4 | Link / unlink an additional account to an employee | /settings/accounts · UserRow.tsx | accountsActions.ts:linkAdditionalAccount, unlinkAdditionalAccount | link_additional_account, unlink_additional_account | action.manage_permissions | employee_accounts I / D, employee_account_history I | employee_accounts (account ↔ employee) | /settings/accounts and /hr/employees/[id] | EVENT |
| S5 | Change a role's permissions | /settings/roles/[id] · PermissionMatrix.tsx | accountsActions.ts:saveRolePermissions | set_role_permissions (delete-all + reinsert) | action.manage_permissions | role_permissions D+I | roles row (child role_permissions) | /settings/roles/[id] | EVENT (access) — diffs arrive as delete/insert pairs (live: 72 D / 74 I) |
| S6 | Create / rename / edit a role | /settings/roles/new, /[id] · RoleForm.tsx | accountsActions.ts:createRole, updateRole | — (direct) | action.manage_permissions (+ guard_system_role) | roles I/U | roles row | /settings/roles/[id] | edit |
| S7 | Delete a role | /settings/roles/[id] · RoleForm.tsx | accountsActions.ts:softDeleteRole | — | action.manage_permissions | roles U (deleted_at, is_active=false) | roles | /settings/roles/[id] + /settings/deleted | EVENT |

### 1f. Other settings

| # | User words | UI entry | Server action | RPC | Permission | Tables written | PRIMARY RECORD | Trail page | Kind |
|---|---|---|---|---|---|---|---|---|---|
| S8 | Change the approval policy (on/off, level-1/level-2 role, threshold) | /settings/approvals · ApprovalsForm.tsx | app/settings/approvals/actions.ts:setApprovalsPolicy | set_approvals_policy | action.manage_permissions | finance_settings U, finance_settings_history I | finance_settings (singleton, id = true) — approval columns | /settings/approvals (ApprovalsHistory.tsx already renders finance_settings_history) | EVENT (setting) |
| S9 | Add / edit / (de)activate a dictionary value | /settings/dictionaries · DictSection.tsx | app/settings/dictionaries/actions.ts:addDictValue, updateDictValue, setDictActive | — (direct, table chosen from registry) | per registry: module.materials.edit for all 6 | one of the 6 dictionary tables I/U (by code) | the dictionary row (table, code) | /settings/dictionaries (per section) | edit (setting) |
| S10 | Lock the books before a date (period lock) | **/finance/settings** · app/finance/settings/LockForm.tsx (finance-owned) | app/finance/settings/actions.ts:setPeriodLock | — (direct update finance_settings.locked_before) | module.finance.edit | finance_settings U | finance_settings singleton — `locked_before` | /finance/settings | EVENT (setting) |
| S11 | Close / reopen a month; close / reopen a financial year (also moves the lock) | /finance/close (finance-owned) | app/finance/close/actions.ts:closePeriod, reopenPeriod, closeFinancialYear, reopenFinancialYear | close_period, reopen_period, close_financial_year, reopen_financial_year | finance codes | period_closes I/U, finance_settings U | period_closes row | /finance/close (CloseHistoryTable exists) | EVENT |
| S12 | Turn GST registration on/off, set GST no. | **/finance/settings** · GstPanel.tsx (finance-owned) | app/finance/settings/gstActions.ts:setGstRegistration | set_finance_settings | action.finance_settings (CFO) | finance_settings U (gst_registered, gst_registration_no) | finance_settings singleton — GST columns | /finance/settings | EVENT (setting) |

### 1g. Self-service, auth, notifications

| # | User words | UI entry | Server action | Call | Permission | Written | PRIMARY RECORD | Trail page | Kind |
|---|---|---|---|---|---|---|---|---|---|
| U1 | Change my avatar / remove it | /me · AvatarPanel.tsx; TopNav.tsx menu | app/me/avatarActions.ts:uploadAvatar, removeAvatar | storage bucket AVATAR_BUCKET, object avatarObjectName(user id) upload(upsert)/remove | own session | storage.objects (not public schema → no change_log) | the account | none (see §4) | edit |
| U2 | Mark a notification read / mark all read | /notifications · MarkReadButtons.tsx | app/notifications/actions.ts:markRead, markAllRead | direct upsert | RLS own row (user_id = auth.uid()) | notification_reads upsert — **no change_log trigger** | notification_reads | none (see §4) | edit (noise) |
| U3 | Log in | /login · login/page.tsx | app/login/actions.ts:login | auth.signInWithPassword | — | auth sessions only | account | none | EVENT (security) |
| U4 | Log out | AvatarMenu.tsx, /set-password | app/logout/actions.ts:logout | auth.signOut | — | auth sessions | account | none | EVENT (security) |
| U5 | Set my password (first login / forced change) | /set-password · SetPasswordForm.tsx | app/set-password/actions.ts:setPassword | auth.updateUser({password, data.must_change_password=false}) | own session | auth.users U | account | none | EVENT (security) |
| U6 | Public verification of a COD certificate (anonymous) | GET /verify/cod/[token] | route handler (not an action) | cod_verification | anon | cod_verification_failures D/I (rate limit) | the COD certificate | none — do not host (see §4) | system noise |

---

## 2. Settings pages: what "that setting" is

| Settings page | Route + file | Rows that constitute "that setting" | Shape | Domain history today | Notes |
|---|---|---|---|---|---|
| Approval settings | /settings/approvals · app/settings/approvals/page.tsx (ApprovalsForm, ApprovalsHistory) | finance_settings (id = true) columns approvals_enabled, approval_level1_role_code, approval_level2_role_code, approval_threshold_base | ONE record (singleton row, 4 columns of it) | finance_settings_history (old/new of exactly those 4 columns; 1 row live, as postgres) | **Measured contradiction**: lib/modules.ts:843-846 comment says "this panel is read-only, the system has no UI to configure approval chains" — false today: ApprovalsForm.tsx:85 calls setApprovalsPolicy → set_approvals_policy. |
| Period lock | **/finance/settings** · app/finance/settings/page.tsx:132 (LockForm) | finance_settings.locked_before (+ updated_by/at) | ONE record, one column | none dedicated (period_closes records month closes, not raw lock moves) | Lives under finance, not /settings. Also moved by close_period / reopen_period (/finance/close). Trail must filter change_log for finance_settings where locked_before changed. |
| GST settings | **/finance/settings** · app/finance/settings/page.tsx:145 (GstPanel) | finance_settings.gst_registered, gst_registration_no (gst_rate_pct exists but no UI writer found in slice) | ONE record, two columns | none | Under finance. GST periods/filing are /finance/gst (documents, finance slice). |
| (other finance_settings columns) | — | system_start_date, fy_end_month/day, first_fy_end, default_allocation_basis | ONE record | none | No writer in this slice; finance agent to confirm. All finance_settings changes share ONE change_log row stream (table finance_settings, row_key id=true) → each settings panel must filter by the columns it owns. |
| Roles and permissions | /settings/roles (list) · app/settings/roles/page.tsx; /settings/roles/[id] · roles/[id]/page.tsx | roles row + role_permissions (role_id) + user_roles (role_id, members) | COLLECTION (12 live roles, as postgres); per-role page is the record | none (change_log only) | role_permissions is delete-all/reinsert → trail must net D/I pairs into "added X, removed Y". |
| Accounts | /settings/accounts · accounts/page.tsx (UserRow, CreateAccountPanel) | auth.users (via user_directory), user_roles by user_id, employees.user_id, employee_accounts | COLLECTION of accounts; no per-account page | employee_account_history (3 rows live); account events in change_log as table_name 'auth.users' | See §4 — needs a per-account trail surface. |
| Dictionaries | /settings/dictionaries · dictionaries/page.tsx, registry app/settings/dictionaries/registry.ts | 6 tables (registry DICTIONARIES): substances, battery_chemistries, material_kinds, inbound_safety_states, laboratories, inbound_source_reasons; key = code | COLLECTION of collections — one section per table; trail per section (or per row) | none | Registry comment says "these five" but the array has 6 (Measured, registry.ts). Write code module.materials.edit for all 6; view code materials.view (4) / inbound.view (2). |
| Leave types | /hr/leave/types · app/hr/leave/types/page.tsx | leave_types rows (key code) | COLLECTION (setting-like, lives in HR) | none | |
| Public holidays | /hr/leave/holidays · holidays/page.tsx | public_holidays rows (hard delete) | COLLECTION | none | Deleted holidays only survive in change_log `old`. |
| Rating scale | /hr/reviews/scale · scale/page.tsx | review_rating_scale rows (key code) | COLLECTION | none | |
| Bulk import | /settings/import · import/page.tsx | import_batches rows | COLLECTION (log) | import_batches IS the log | Trail = the batch list already shown. |
| Permission reference | /settings/reference | read-only view of permissions/role_permissions | — | — | No writes (grep). Shows no trail of its own; link to roles. |
| Change history / Deleted records | /settings/change-history, /settings/deleted | read-only | — | — | Reader pages, not trail hosts. |

---

## 3. Pages that should carry a trail (primary + roll-up)

| Page | File | Primary table(s) | Child tables rolled up (join path) | Access check (page) |
|---|---|---|---|---|
| /hr/employees/[id] | app/hr/employees/[id]/page.tsx | employees (id) | employment_history.employee_id; training_records.employee_id; salary_change_requests.employee_id; performance_reviews.employee_id (+ review_goals.review_id); payroll_lines.employee_id; employee_accounts.employee_id + employee_account_history.employee_id; user_roles via employees.user_id; leave_requests / leave_grants / leave_consumption / medical_claims / kpi_entries / attendance_lines / overtime_lines .employee_id (candidate roll-ups — the page does not show these today) | requireModule(MOD.hr); pay parts can('data.view_pay'); edit can('module.hr.edit'); reviews can('action.hr_reviews') |
| /hr/employees/[id]/edit | …/[id]/edit/page.tsx | employees | — (show same trail as detail, or none) | requireModule(MOD.hr) |
| /hr/departments (list) + /[id]/edit | app/hr/departments/page.tsx, [id]/edit/page.tsx | departments | — | requireModule(MOD.hr) |
| /hr/training/[id]/edit | app/hr/training/[id]/edit/page.tsx | training_records | — | requireModule(MOD.hr) |
| /hr/leave/[id] | app/hr/leave/[id]/page.tsx | leave_requests | leave_consumption.leave_request_id (Inferred key name); approval_log (doc_type 'leave_request', doc id) | requireModule(MOD.hr); decide can('action.decide_hr_requests') |
| /hr/leave/grants | app/hr/leave/grants/page.tsx | leave_grants (per year run) | — | requireModule(MOD.hr) |
| /hr/leave/types | …/leave/types/page.tsx | leave_types | — | requireModule(MOD.hr) |
| /hr/leave/holidays | …/leave/holidays/page.tsx | public_holidays | — | requireModule(MOD.hr) |
| /hr/claims/[id] | app/hr/claims/[id]/page.tsx | medical_claims | approval_log ('medical_claim'); expenses via medical_claims.expense_id; journal via expense | requireModule(MOD.hr); can('action.decide_hr_requests'), can('module.finance.edit') |
| /hr/overtime/[id] | app/hr/overtime/[id]/page.tsx | overtime_batches | overtime_lines.batch_id; approval_log | requireFunction(FN.overtime); can('action.overtime_enter'/'action.overtime_approve') |
| /hr/attendance/[id] | app/hr/attendance/[id]/page.tsx | attendance_periods | attendance_lines.period_id | requireModule(MOD.hr) |
| /hr/payroll/[id] | app/hr/payroll/[id]/page.tsx | payroll_periods | payroll_lines.payroll_period_id; payroll_requests.payroll_period_id; approval_log; journal_entries (source link) | requireModule(MOD.hr); can('data.view_pay'), can('module.hr.edit'), can('module.finance.view') |
| /hr/reviews/[id] | app/hr/reviews/[id]/page.tsx | performance_reviews | review_goals.review_id; approval_log ('performance_review') | requireModule(MOD.hr); can('action.hr_reviews'), can(review_approval_code), can('data.view_pay') |
| /my-reviews/[id] | app/my-reviews/[id]/page.tsx | performance_reviews (as reviewer) | review_goals | **no requireModule** — reviewer-of via my_review_subjects; can('action.hr_reviews'), can(approveCode) |
| /hr/reviews/cycles | …/reviews/cycles/page.tsx | review_cycles | performance_reviews.cycle_id (count only) | requireModule(MOD.hr) |
| /hr/reviews/scale | …/reviews/scale/page.tsx | review_rating_scale | — | requireModule(MOD.hr) |
| /hr/kpi/score | app/hr/kpi/score/page.tsx | kpi_entries | — | requireModule(MOD.hr); can('action.hr_reviews'), can('data.view_reviews') |
| /settings/roles/[id] | app/settings/roles/[id]/page.tsx | roles | role_permissions.role_id; user_roles.role_id | requireManagePermissions() |
| /settings/accounts | app/settings/accounts/page.tsx | auth.users (change_log 'auth.users') | user_roles.user_id; employees.user_id; employee_accounts.user_id + employee_account_history.user_id | requireManagePermissions() |
| /settings/approvals | app/settings/approvals/page.tsx | finance_settings (approval columns) | finance_settings_history | requireFunction(FN.approvals) = action.manage_permissions |
| /settings/dictionaries | app/settings/dictionaries/page.tsx | 6 dictionary tables | — | per section can(d.viewPermission) / can(d.permission) |
| /settings/import | app/settings/import/page.tsx | import_batches | the imported rows (target table, code_first..code_last) | can('action.bulk_import') |
| /finance/settings (finance slice) | app/finance/settings/page.tsx | finance_settings (locked_before; GST columns) | — | requireModule(MOD.finance); edit can('module.finance.edit') / can('action.finance_settings') |
| /me | app/me/page.tsx | the viewer's employees row | see §5 | none beyond login (self via my_profile / current_user_employee) |

Pages with no trail needed (read-only, no own record): /hr (dashboard), /hr/org, /hr/kpi, /hr/leave (list), /hr/leave/balances, /hr/leave/calendar, /hr/claims, /hr/overtime, /hr/attendance, /hr/payroll, /hr/reviews, /hr/training, /hr/employees (lists; list rows link to detail trails), /my-reviews, /notifications, /settings/reference, /settings/change-history, /settings/deleted, /, /welcome, /login, /set-password. Form-only pages (…/new) host no trail (record doesn't exist yet).

---

## 4. Operations with NO fitting page to host their trail

| Operation | Why no page | Recommended home | Why |
|---|---|---|---|
| Account created / deleted / disabled / enabled (+ _FAILED) — change_log table_name 'auth.users' | /settings/accounts is a list; no per-account page | A per-account trail (expandable row or drawer) on /settings/accounts, keyed by user id; also mirror on /hr/employees/[id] when the account is linked | Access events belong with the account; manage_permissions holders are the only audience. |
| Roles granted/revoked to an account (user_roles by user_id) | same | same account trail on /settings/accounts; also the role's member list on /settings/roles/[id] (by role_id) | One event, two natural readers: "who got role X" and "what can account Y do". |
| employee_accounts link/unlink, employees.user_id link | account ↔ employee | /hr/employees/[id] trail (employee side) and the account trail | employee_account_history already exists (3 rows). |
| Login / logout / set password | Supabase auth, nothing recorded (auth.audit_log_entries = 0 rows, measured) | Not hostable today. If wanted: record_account_event-style 'PASSWORD_SET' into change_log, shown on the account trail | No data exists to show; Tim to decide. |
| Avatar upload/remove | storage.objects, not public schema → outside change_log | Nowhere (recommend: do not trail) or a one-liner on the account trail | Cosmetic, self-owned. |
| Notification read / mark all read | notification_reads has no change_log trigger | Do not trail | Pure UI state; high volume. |
| COD public verification failures (cod_verification_failures D/I; 2 change_log rows live) | anonymous rate-limit counter | Do not trail; consider excluding table from change_log | Noise; anon actor. |
| Annual-leave carry-forward run (leave_grants I for many employees) | No document; /hr/leave/grants is a list | /hr/leave/grants as a "runs" trail (one entry per year run: who, when, N grants); each employee's /hr/employees/[id] rolls up its own grant | Production step with no document. |
| Review cycle open (bulk performance_reviews I) / close; KPI generate | No cycle detail page | /hr/reviews/cycles trail per cycle row; /hr/kpi/score for KPI generation | |
| Bulk import (rows into employees/departments/customers/suppliers/materials/storage_locations) | Rows land on other modules' pages | /settings/import (batch = operation) + each created record's own trail shows "created by import batch X" | |
| Department add/edit/delete | No department detail page | /hr/departments/[id]/edit (or a list-row trail on /hr/departments) | |
| Anonymise employee | No UI at all; and it UPDATEs change_log (change_log_redact_employee) | /hr/employees/[id] once a UI exists; trail must show "personal data anonymised" without the redacted values | The trail itself is rewritten by this op — AUDIT-TRAIL-1 must not treat change_log as immutable for employees. |
| Expense claim from /me | finance-owned record | Finance claims detail page; /me shows only the requester's own view | |

---

## 5. Privacy — what the employee sees about themself on /me

/me reads (app/me/page.tsx, grep of from()/rpc()): my_profile, employment_history, payroll_lines_masked, payroll_periods,
training_records, leave_requests, leave_types, leave_balance(), medical_claim_status, medical_claim_balance(),
expense_claim_status, my_document_decisions(), my_overtime_lines(), attendance_lines/periods, my_kpi_entries,
my_self_assessment(_goals), performance_reviews_masked, review_goals, review_rating_scale, employees_masked.
Writes from /me: submitLeave, cancelLeave, submitClaim (medical), withdrawMedicalClaim, submitClaim/withdrawClaim (expense,
finance), saveSelfAssessment, acknowledgeReview, uploadAvatar/removeAvatar.

Trails the employee could see about their own records (if /me gets per-record trails):

| Own record | Trail content suitable for self | Hide from self |
|---|---|---|
| employees (my profile) | job/department/status changes, hire, confirmation | who edited notes; `notes` column (HR internal) — Inferred, not in mask rules |
| employment_history | already shown on /me (me.history) | — (salary columns code_or_self → visible to self) |
| payroll_lines (my payslips) | posted / unposted | line delete+insert churn from upsert_payroll_period (noise) |
| leave_requests / medical_claims / expense_claims / overtime_lines | submitted, approved/rejected (by whom, notes), cancelled/withdrawn, paid | — |
| performance_reviews + review_goals | opened for self-assessment, submitted, approved, acknowledged | reviewer's drafting edits before release (Inferred: status draft/self_review edits by reviewer) |
| kpi_entries | scored | — |

Mask rules (change_log_mask_rules(), live, 80 rules total; 13 are `code_or_self`, all in this slice — Measured):

| Table | Columns | Rule |
|---|---|---|
| employees | work_email, work_phone, identity_no, work_pass_no | code_or_self:data.view_identity:id |
| employees | monthly_salary | code_or_self:data.view_pay:id |
| employment_history | old_monthly_salary, new_monthly_salary | code_or_self:data.view_pay:employee_id |
| payroll_lines | gross_pay, employer_cpf, employee_cpf, other_deductions, net_pay | code_or_self:data.view_pay:employee_id |
| performance_reviews | new_monthly_salary | code_or_self:data.view_pay:employee_id |

Gaps (Measured against live columns via information_schema; the rule list has no entry for them):
- **salary_change_requests.old_monthly_salary, new_monthly_salary, snapshot** — NOT masked. Any per-page trail on
  /hr/employees/[id] would leak pay to module.hr.view holders without data.view_pay. Must add
  `code_or_self:data.view_pay:employee_id` rules before AUDIT-TRAIL-1 ships (the page itself gates the panel on
  can('data.view_pay') — the trail must match).
- employees.residency_status, work_pass_type, work_pass_issue/expiry_date, legal/first/last names — not masked
  (identity-adjacent; Inferred judgement, Tim to rule).
- medical_claims.description / amount_sgd, leave_requests reason text — health-adjacent, not masked (Inferred risk).
- change_log rows for 'auth.users' carry email in `new` — only manage_permissions readers should see them.

---

## 6. Findings that contradict the brief / HISTORY-0

1. Approval policy IS editable (ApprovalsForm → set_approvals_policy, writes finance_settings + finance_settings_history);
   lib/modules.ts:843-846 comment claims the panel is read-only. **Measured.**
2. Period lock and GST settings do not live under /settings: both are on **/finance/settings** (LockForm → direct
   finance_settings.locked_before update, module.finance.edit; GstPanel → set_finance_settings, action.finance_settings).
   Month/year close also moves the lock (/finance/close). **Measured.**
3. finance_settings_history covers only the 4 approval columns; lock and GST changes have no domain history — only
   change_log, and all finance_settings panels share one change_log row stream (row_key id=true). **Measured** (columns).
4. anonymise_employee UPDATEs change_log (via change_log_redact_employee) — change_log is not strictly append-only for
   employee data. No UI caller. **Measured** (fnmap.json `all`, grep).
5. role_permissions (set_role_permissions) and payroll_lines (upsert_payroll_period) are rewritten delete-all/re-insert,
   so change_log shows D+I pairs, not updates (live: role_permissions 72 D / 74 I). **Measured.**
6. deleteEmployee is dead code (no caller). **Measured.**
7. Dictionary registry: 6 tables, comment says 5. **Measured.**
8. salary_change_requests pay columns are missing from change_log_mask_rules(). **Measured.**
