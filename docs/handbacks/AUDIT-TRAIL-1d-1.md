# AUDIT-TRAIL-1d-1 — mechanism, settings and employees: M9–M12, Q13, `save_employee`, a trail per account (mirrored on the employee page), grants on the role page, the approval-policy panel, six dictionaries and the import list, employees, departments and training records, and read-only pages for what was deleted (2026-10-04)

Part of v1.4.33, not yet released.

**Opening check:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `6cc55398` (the AT-1d Step 0 hand-back), measured at
**2026-10-04 11:41:03 CST**. **Approvals were ON and stayed ON.** All 7 real accounts were enabled before and after. No auth account was created,
disabled or deleted on live by this cut's own work. The only accounts that came and went were the smoke and probe harnesses' throwaway
accounts, each removed by its own ephemeral plan (see §7.1). That is my reading of the brief, which requires the smoke and its scratch-cleanup
reading.

Every figure below is either a script's own exit line or a query named with who ran it. Unless stated otherwise, the reader is `postgres`
(`rolbypassrls = true`) reading base tables. "As X" means `SET LOCAL ROLE authenticated` plus X's JWT.

This is cut 1 of the 3 AT-1d cuts (**1d-1** → 1d-2 → 1d-3). It is built on Tim's answers to
`docs/surveys/AUDIT-TRAIL-1d/STEP0-HANDBACK.md`: Q1–Q38 were all accepted as recommended on 2026-10-04, plus the privacy-group ruling.
**1d-2 and 1d-3 are untouched.** That covers `/me`, reviews, KPI, leave, overtime, attendance, payroll, medical claims, holidays and the
other HR settings collections. The mechanism reference is **`docs/change-log.md` §9**: §9.14 is new, and M9–M12 are in its mechanism table.

## §1 · Subjects covered (12 new; 56 → 68)

| subject | root | read rule | members (home = this subject unless noted) |
|---|---|---|---|
| `account` | `auth.users` (M9: log-only root, safe projection `id, email, created_at, banned_until`) | `action.manage_permissions` | `user_roles` (home) · `employee_accounts` (home) · `employee_account_history` (home) · `employees` limited to `user_id` (M10, not home) |
| `role` (extended) | `roles` | unchanged | + `user_roles` (Q22: shown here, home is the account) |
| `approval_policy` | `finance_settings`, own columns only (M6): `approvals_enabled`, `approval_threshold_base`, `approval_level1_role_code`, `approval_level2_role_code` | `action.manage_permissions` (Q23) | `finance_settings_history` (M7, whole table) |
| `employee` | `employees` | `module.hr.view` | `employment_history` · `salary_change_requests` · `approval_log` of salary change requests · `training_records` (shown, home is the training record) · `employee_accounts` · `employee_account_history` · `auth.users` up through `employees.user_id` and through `employee_accounts.user_id` · `user_roles` down from those accounts (Q21 mirror; each row keeps its own rule, so an HR reader without `manage_permissions` sees them as Restricted) |
| `department` | `departments` | `module.hr.view` | — |
| `training_record` | `training_records` | `module.hr.view` | — |
| `import_batch` | `import_batches` | `action.bulk_import` | — (Q24: no lineage link; the table forbids one) |
| `dictionary_substances` · `dictionary_battery_chemistries` · `dictionary_material_kinds` · `dictionary_inbound_safety_states` | the dictionary table, `'collection'` (M11), id `all` | `module.materials.view` | — |
| `dictionary_laboratories` · `dictionary_inbound_source_reasons` | the same | `module.inbound.view` | — |

**Mechanism added:**
- **M9: a log-only root** (`trail_log_only_tables()`). The root lives outside `public`. Its current image is read only through a declared
  safe projection, and its rows are visible only under a declared permission (`trail_current_image`, `trail_row_visible`).
- **M10: declared member columns** (`trail_member_columns()`). The account's `employees` member contributes `user_id` and nothing else.
  M6 is generalised from the root to any member row (`record_trail`'s `v_icols`).
- **M11: the collection subject.** Root rule `'collection'`, root key `code`, id `all`. Every row of the table is the root.
- **M12: a gate narrower than the table rule** (`'gate:<name>'`, `trail_root_gate()`). It is a closed set: one gate (`reviewer` on
  `performance_reviews`), and any unknown gate refuses. **No 1d-1 subject uses it yet** (the reviewer page is 1d-2). The fixture proves it
  with a temporary subject.
- **Q13: `change_log_rows` re-checks row rules.** A row whose table rule the reader fails now comes back restricted (`row_restricted = true`,
  values masked) instead of in full.
- **Q8: `save_employee(p_id, p_fields, p_history)`.** One call and one transaction for the employee row and its history row. The hire and
  edit forms now call it.

## §2 · What was built

### Database (`db/functions/`, `db/views/`)
- New: `trail_log_only_tables.sql`, `trail_member_columns.sql`, `trail_root_gate.sql`, `save_employee.sql`.
- Changed:
  - `record_trail.sql`: per-row column lists, collection expansion, the gate, and the pre-log creation check that recognises `ACCOUNT_CREATE`.
  - `trail_subjects.sql`, `trail_subject_members.sql`, `trail_current_image.sql`, `trail_row_visible.sql`.
  - `trail_prelog_sources.sql`:
    - auth users created
    - user_roles created and revoked stamps
    - employee_accounts
    - employee_account_history
    - finance_settings_history
    - import_batches
    - employees created, deleted and anonymised
    - employment_history
    - salary_change_requests created and withdrawn
    - departments and training records created and deleted
  - `trail_ref_label.sql`: an account's label is the person's name when known; training records → training name; imports → file name.
  - `change_log_rows.sql` (Q13).
  - `db/views/deleted_records.sql`: adds role, employee, department and training record branches.
  - `db/views/zzz_function_grants.sql`: `trail_root_gate` is service_role only.
- Migration: `db/migrations/2026-10-04-at1d1-trails-accounts-settings-and-employees.sql`, built by
  `db/scripts/build_at1d1_migration.py`, 2,523 lines.
  - Its precondition is 56 subjects.
  - Section 1b grants the four new functions explicitly, because the grants file replays after the in-migration proof.
  - Its proof, run as admin@, reads every new record and checks the cto grant and that no account is disabled.

### Renderer (`lib/trail/`)
- `render.ts`:
  - Five describers (access, hr, policy, dict, import), wired into `SUBJECT_TABLES` and `PAGE_FAMILY`.
  - A pairing pre-pass so an `ACCOUNT_*_FAILED` event reads beside the attempt it failed.
  - Salaries are shown in the base currency.
  - Restricted salary lines are kept.
  - Q10 machine notes are recognised and said in words.
- `text.ts`: 53 new keys (§8).
- `catalogue.generated.ts`: regenerated, with the 1d-1 table labels (§8.2).

### App
- §4 lists the pages.
- `app/hr/employees/actions.ts`: create and update go through `supabase.rpc('save_employee', …)`.
- `app/settings/approvals/ApprovalsHistory.tsx`: deleted (Q27); its 7 message keys were removed from `messages/en.ts` and `messages/zh.ts`.
- Two stale comments fixed, as the brief asked:
  - `app/settings/accounts/page.tsx`
  - `app/settings/dictionaries/registry.ts`: "five" → six.

## §3 · Fixtures

**`db/fixtures/244-accounts-settings-and-employees-trails-m9-m12-q13-save-employee.sql`**: arms A (M9), C (M10), E (Q21 · Q24), R (Q22),
K (M11), G (M12), Q (Q13), S (Q8), P (M6 · M7), I (import), D (Q25 · Q26) and N (Q30).

| arm | proves |
|---|---|
| A | an account's trail shows its projection only; the account's creation, disabling, a failed disable (`ACCOUNT_DISABLE_FAILED`), re-enabling and a rolled-back creation (`ACCOUNT_DELETE`, reason `create_rolled_back`) are all on it. Their sentences, "Account could not be disabled" and "Account removed (it was never finished)", are pinned in the wording check's arm ⑪; nothing is readable without `action.manage_permissions`; the pre-log creation is not said twice beside `ACCOUNT_CREATE` |
| C | the employee member under an account brings `user_id` only |
| E | the employee-page mirror: an HR reader without `manage_permissions` gets the account rows Restricted, and a reader with it gets them in words |
| R | "Role granted to <name>" on the role page; the grant's home is the account |
| K | a dictionary as a collection: every row is a root, and a change reads as "{Thing} changed" |
| G | M12: the reviewed employee is refused the reviewer gate, the reviewer passes it, and an unknown gate refuses everyone |
| Q | Q13: a summary reader without the table rule gets the row restricted |
| S | `save_employee`: a hire reads as **one** entry, an edit reads as **one** entry, the history row is written in the same call, and a reader without `module.hr.edit` is refused (not a silent no-op) |
| P | the approval-policy panel shows its own four fields and the history; it does not show the rest of the settings row |
| I | the import-batch list block and its who column |
| D | deleted roles, employees, departments and training records in `deleted_records` and readable |
| N | anonymisation: "Personal data anonymised" and the actor rendered as "A former employee" |

`db/fixtures/234-…sql`: the synthetic readers `r_m` and `r_pp` were given `module.purchasing.view` and `module.pricing.view`. Q13 now
re-checks row rules, and those readers were reading rows whose table rule they lacked. There is a comment at the change.

## §4 · Pages — every new or changed route, with its file

| route | file(s) | what changed |
|---|---|---|
| `/settings/accounts` | `app/settings/accounts/page.tsx`, `app/settings/accounts/UserRow.tsx` | a compact trail per account (`subject="account"`) |
| `/settings/roles/[id]` | `app/settings/roles/[id]/page.tsx` | grants on the role trail (Q22); a deleted role opens read-only with the ended banner (Q25) |
| `/settings/approvals` | `app/settings/approvals/page.tsx` (`ApprovalsHistory.tsx` deleted) | the approval-policy trail replaces the history table (Q27) |
| `/settings/dictionaries` | `app/settings/dictionaries/page.tsx`, `registry.ts` | a compact trail per dictionary section (anchor `dict-trail-<table>`) |
| `/settings/import` | `app/settings/import/page.tsx`, `ImportHistoryTable.tsx` | a "Who" column; a list block of import-batch trails, record label `Import <stamp>` |
| `/settings/deleted` | `app/settings/deleted/page.tsx` | role, employee, department and training-record kinds link to their pages |
| `/hr/employees/[id]` | `app/hr/employees/[id]/page.tsx`, `app/hr/employees/SalaryChangePanel.tsx` | the employee trail at the bottom (Q28 members); the salary panel's "recently settled" list is removed (Q27); a deleted employee opens read-only with its actions hidden |
| `/hr/employees/[id]/edit` | `app/hr/employees/[id]/edit/page.tsx` | a deleted employee redirects to its detail page |
| `/hr/departments/[id]/edit` | `app/hr/departments/[id]/edit/page.tsx` | department trail; read-only when deleted |
| `/hr/training/[id]/edit` | `app/hr/training/[id]/edit/page.tsx` | training-record trail; read-only when deleted |

Shared components: `app/components/trail/AuditTrail.tsx` (12 subjects), `ListTrail.tsx` (`importBatches` intro) and `EndedBanner.tsx`
(4 kinds).

## §5 · Verification, in the brief's order

| # | check | result |
|---|---|---|
| 1 | offline gate | `GATE_OFFLINE_EXIT=0` (72 s; fixtures 234 and 244 ✓) |
| 2 | backup (background) | `BACKUP_EXIT=0`, 15:27 → 15:33, `evoltrya-backup-2026-10-04-1527.dump`, 5.7 MB |
| 3 | apply | preflight passed with 1 warning (the `trail_current_image` signature was not parsed; it is unchanged); dry run `DRY_OWN_EXIT=0` (55 records read as admin@); `APPLY_OWN_EXIT=0`, **committed 15:35:59 CST** (`db/migration-windows.tsv`) |
| 4 | generate types | `TYPES_OWN_EXIT=0` (`save_employee` added) |
| 5 | tsc | `TSC_OWN_EXIT=0`; rerun after the last app change: `TSC2_OWN_EXIT=0` |
| 6 | build | `BUILD_OWN_EXIT=0`; rerun after the import-page change (from a clean `.next`, after the survey): `BUILD2_OWN_EXIT=0` |
| 7 | full gate | `GATE_EXIT=0`, 341 s. Rebuild ✓, mirrors ✓, fixtures ✓. B1/B2: 0 on both sides. Changelog: 242 tables, 238 recorded, 4 exempt. Changemask: 27 tables / 81 columns. Anon surface: 326 relations + 1 function ⊆ baseline 327 |
| 8 | i18n | ✓ inside the build |
| 9 | error swallowing | ✓ inside the build (0 unallowed, 9 allowlisted) |
| 10 | layout survey, 12 paths at 390 px and 1280 px | first run: `SURVEY390_EXIT=0`, `SURVEY1280_EXIT=0`, 12/12 U1 and U2; rerun after the import-page change: `SURVEY390B_OWN_EXIT=0`, `SURVEY1280B_OWN_EXIT=0`, 12/12 U1 and U2 at both widths |
| 11 | smoke | first run: `SMOKE_EXIT=1` (259 ok, 9 skipped, 1 failed: the `/settings/import` record column carried a file name, which the detector reads as a dotted code; fixed by labelling the record `Import <stamp>`). Rerun: `SMOKE_EXIT=0`, 260 ok, 9 skipped (no data), 0 failed. Scratch cleanup reading: the same 6 stale `ZZ-SMOKE-*` rows as before (materials PROBE/M25/NTF, supplier S25, customer CJK, inbound batch IB25; 5 still referenced, report-only, none deleted). After the run, read as postgres: 7 accounts · 0 disabled · 9 grants · 0 scratch employees · 0 leftover ephemeral plans |
| 12 | live verification | §7 |

**Wording check** (`scripts/check-trail-wording.mjs`): `TW_OWN_EXIT=0`, rerun `TW2_OWN_EXIT=0`. Arm ⑪ is new. It pins 41 goldens, checks the
"A former employee" rendering, and sweeps the 13 subjects.

**Page probe** (`scripts/probe-at1d1.mjs`, port 3190): `AT1D1_PROBE_EXIT=0`, 45 passed. It renders:
- every live employee in both interfaces, identical;
- every account, with the account list read from the auth admin API;
- the cto role page;
- the approval-policy panel.

## §6 · Fault injection

**Fixture 244** (`db/scripts/2026-10-04-at1d1-fixture-injections.py`, on the local rebuild):
`INJECTIONS_OWN_EXIT=0 (18 injections, 0 wrong)`. Every injection went red in the arm it names:

1. M9 safe projection widened
2. M9 read rule ignored
3. M9 pre-log creation said twice
4. M10 member not limited
5. M11 collections not expanded
6. M12 gate not consulted
7. M12 unknown gate admits everyone
8. Q13 row rules not re-checked
9. `save_employee` history not written in the same call
10. `save_employee` with no permission check and no write guard
11. Q22 grants missing from the role page
12. Q22 grant's home not the account
13. mirror grants dropped
14. M6 policy panel sees the whole row
15. M7 history not a member
16. import gated wrongly
17. Q25 deleted roles missing
18. Q30 an anonymised person read by name

Two injections did not bite on the first try, because each property is guarded twice:
- the `save_employee` one now also disables the `enforce_write_permission` trigger;
- the import one also switches the rule to `'page'`.

**Wording check:**
- `wording-drift-1d1` → ⑪ only.
- `raw-ref`, `raw-null` and `raw-date` → ④ ⑥ … ⑪ red.
- `blind-detector` → ① (exit 3).

**Page probe:**
- `mirror-leak` → Q21 red only.
- `no-grant` → Q22 only. The first run also had transient HTTP 500/503 on three employee pages; the rerun showed only Q22 red, `INJ2_EXIT=1`.
- `refusal-wrong` → Q26 only.
- `cjk` → all 17 identical-output checks red.

**Machine tokens:** every new subject is scanned by the wording check (arm ⑪), the smoke (real HTML) and the proof render (§7.2).

## §7 · Live verification

### §7.1 · Before / after readings (`db/scripts/2026-10-04-at1d1-live-readings.sql`, as postgres; recon as tim@)

| reading | before (15:27:45) | after (16:33:21) |
|---|---|---|
| accounts | 7 accounts, 0 disabled · `ababff588d2a` | **same** |
| roles held | 9 grants · 7 live · `abfbe072ced1` | **same** |
| approvals | ON | ON |
| pending documents | 8 · `c113de0d5542` | **same** |
| settings row / company profile | `b1ec28c2d2ce` / `b6afa17e8445` | **same** |
| 1d-1 rows | 22 employees (last ZZ-V2-326924) · 3 history · 1 department · 1 training · 1 extra login · 2 imports · 0 salary requests | **same** |
| dictionaries | 7/8/5/5/1/4 | **same** |
| AP recon | 416,988.32 / 376,404.42, unexplained **0.00**, true | **same** |
| AR recon | 57,545.87 / 43,002.12, unexplained **0.00**, true | **same** |
| change_log | 3,820 rows, max seq 4,623 | 4,039 rows, max seq 4,987 |
| every-row digest (241 public tables, change_log excluded) | `8c9005a73d27` | `55215b00ecf1` |

**The two readings that moved are fully explained:**
- **change_log +219.** All 219 have `seq > 4623`; the 3,820 rows that existed before are untouched. Every one is half of a create/delete
  pair:
  - the smoke and probe ephemeral fixtures, 15:46–16:02 and the probe-injection reruns up to 16:30: 7 employees, 3 reviews (+3 updates),
    1 role with 72 permissions, 15 user_roles, 2 contracts with their 10 term rows;
  - one `cod_verification_failures` rotation at 16:01:29 (1 DELETE + 1 INSERT, the smoke's COD check, the same as in 1c-3).
- **Digest.** I compared every table without a change_log trigger against the 15:27 backup by sorted `COPY` md5:
  - `festival_doodles`, `home_greetings` and `notification_reads` are identical;
  - `cod_verification_failures` differs, and that is the one rotation above.
  - Every other table is change_log-tracked, and its only new rows are the paired creates and deletes above. So the digest move is the COD
    rotation.
- **auth.users:** 7, 0 banned. The harness accounts (`smoke-*@test.local`, `probe-*`) were removed by their plans. The scratch-cleanup reading
  is in §5 row 11.

### §7.2 · Proof (`db/scripts/2026-10-04-at1d1-live-proof.sql`, one transaction, ROLLBACK; `PROOF_OWN_EXIT=0`)

- **A** (read-only, as admin@): *"41 records read as admin@, none refused; cto shows 1 grant(s); cfo sees the account rows Restricted"*.
  - Every account has its creation.
  - Every employee has its creation.
  - No auth column outside the projection appears.
  - No row shows twice.
  - phua@'s cto grant is on the cto role trail.
  - The approval-policy trail shows only its four columns.
  - As tim@ (cfo: hr.view, no manage_permissions), an employee with a login shows no account event, and the account rows are Restricted.
- **B** (rolled back, as admin@): *"hired EMP-2026-0007, granted auditor to fusheng@, laboratory ZZ-AT1D1 added and renamed"*.
  - The hire and the edit go through `save_employee`.
  - The role is granted to an existing account.
  - One dictionary value is added and renamed; no existing value is touched.
  - The trails are read back as admin@.
- **Render** (scratchpad `render-proof-1d1.mjs`, the production renderer over the proof's rows): `RENDER_OWN_EXIT=0` —
  *"records 45 · entries 117 · machine tokens 0"*.
  - In B, the hire and the edit land in **one** entry: "Employee added", then [Hired], [Confirmed after probation] and
    [Employee details changed]. That is because the proof did both in one transaction. In fixture 244, where they are separate saves, each is
    one entry.
  - The account reads "Role granted: Read-only Auditor".
  - The role reads "Role granted to Fu Sheng".
  - The dictionary reads "Laboratory added · ZZ proof lab" then [Laboratory changed].
  - The first render run counted 2 "machine tokens". Both were an import's **file name** in the entry's title part, which the renderer marks
    as typed text. The smoke's rule (Q8) does not scan typed text, but my render script scanned it there. I fixed the script, not the
    product.

### §7.3 · Broken window

| | value | source |
|---|---|---|
| start | **2026-10-04 15:35:59 CST** | `db/migration-windows.tsv` |
| end | Tim's Vercel reading of the deployment of this commit | **to be supplied by Tim**, not measured here |

**What was broken inside the window (old app + new database):**
- The old `/settings/approvals` still read `finance_settings_history` directly, which still works.
- The old hire and edit forms wrote directly, which still works: `save_employee` is additive.
- Q13 made the summary reader restrict rows whose table rule the reader lacks. That is the intended change, and it applies to old and new
  code alike.
- Nothing was found to raise an error.

## §8 · New wordings and labels

### §8.1 · Event wordings (English; `lib/trail/text.ts`, 53 new keys)

- **Accounts and grants:**
  - `acct.roleGranted` "Role granted: {role}"
  - `acct.roleRemoved` "Role removed: {role}"
  - `acct.grantedTo` "Role granted to {who}"
  - `acct.removedFrom` "Role removed from {who}"
  - `acct.extraLinked` "Additional login linked"
  - `acct.extraUnlinked` "Additional login unlinked"
  - `acct.primaryLinked` "Login linked to employee {code}"
  - `acct.primaryUnlinked` "Login unlinked from employee {code}"
  - `acct.primaryLinkedAny` "Login linked to an employee"
  - `acct.primaryUnlinkedAny` "Login unlinked from an employee"
  - The account events themselves reuse the existing `account.*` wordings: "Account created", "Account removed (it was never finished)",
    "Account disabled", "Account could not be disabled", "Account re-enabled", "Account could not be re-enabled". The actor rendering
    "A former employee" is the existing `who.anonymised`.
- **Approval policy:**
  - `pol.switchedOn` "Approvals switched on"
  - `pol.switchedOff` "Approvals switched off"
  - `pol.changed` "Approval policy changed"
- **Employees:**
  - `emp.added` "Employee added"
  - `emp.edited` "Employee details changed"
  - `emp.deleted` "Employee deleted"
  - `emp.anonymised` "Personal data anonymised"
  - `emp.loginLinked` "Login account linked"
  - `emp.loginUnlinked` "Login account unlinked"
  - `emp.hired` "Hired"
  - `emp.confirmed` "Confirmed after probation"
  - `emp.promotion` "Promoted"
  - `emp.transfer` "Transferred"
  - `emp.typeChange` "Employment type changed"
  - `emp.statusChange` "Employment status changed"
  - `emp.separated` "Left the company"
  - `emp.categoryChange` "Work category changed"
  - `emp.salarySet` "Salary set"
  - `emp.salaryChanged` "Salary changed"
  - `emp.historyRecorded` "Employment change recorded"
  - `emp.historyChanged` "Employment record corrected"
  - `emp.noteReview` "Confirmed through a performance review"
  - `emp.noteSalaryRequest` "Salary change request"
- **Salary change requests:**
  - `scr.requested` "Salary change requested"
  - `scr.approved` "Salary change approved"
  - `scr.rejected` "Salary change rejected"
  - `scr.withdrawn` "Salary change request withdrawn"
  - `scr.changed` "Salary change request changed"
- **Training and departments:**
  - `trn.added` "Training recorded"
  - `trn.changed` "Training record changed"
  - `trn.deleted` "Training record deleted"
  - `dept.created` "Department created"
  - `dept.changed` "Department changed"
  - `dept.deactivated` "Department deactivated"
  - `dept.reactivated` "Department reactivated"
  - `dept.deleted` "Department deleted"
- **Dictionaries:**
  - `dictv.added` "{Thing} added"
  - `dictv.changed` "{Thing} changed"
  - `dictv.deactivated` "{Thing} deactivated"
  - `dictv.reactivated` "{Thing} reactivated"
- **Imports:**
  - `imp.imported.one` "1 {thing} imported from a file"
  - `imp.imported.many` "{n} {thing} records imported from a file"
  - `listTrail.intro.importBatches` "Bulk imports · newest first · Singapore time"

Messages (`messages/en.ts` · `messages/zh.ts`):
- `import.col.who` "Who" / "谁"
- `deleted.kind.role` · `deleted.kind.employee` · `deleted.kind.department` · `deleted.kind.training_record`
- removed: the 7 `ApprovalsHistory` keys (`historyUnset` kept) and `salaryChange.history`

### §8.2 · Field labels on the tables 1d-1 first shows (`scripts/gen-trail-catalogue.mjs` OVERRIDES)

- **employees:**
  - Employee number
  - Legal name · First name · Last name · Preferred name · Greeting name
  - Department · Position · Manager
  - Employment type · Category · Site staff
  - Hire date · Probation ends · Confirmation date · Employment status
  - Separation date · Separation type · Separation notes
  - Work email · Work phone
  - Residency status · Identity number
  - Work pass type · Work pass number · Work pass issued on · Work pass expires on
  - Notes · Monthly salary · Exempt from reviews · Login account
  - Deleted on · Anonymised on · Anonymised by
- **employment_history:** Employee · Effective date · Change · Job title · Department · Employment type · Employment status · Category ·
  Previous monthly salary · New monthly salary · Notes · Anonymised on
- **salary_change_requests:**
  - Employee · Request
  - Current monthly salary · New monthly salary · Effective date · Reason · Status
  - Decided on · Decided by · Decision notes · Applied on
  - Withdrawn on · Withdrawn by · Reason for withdrawing
- **training_records:** Employee · Training · Category · Completed on · Expires on · Provider · Certificate reference · Notes · Deleted on
- **departments:** Code · Name (English) · Name (Chinese) · Parent department · Manager · Active · Notes · Deleted on
- **user_roles:** Login account · Role · Granted on · Granted by · Removed on · Removed by · Reason for removing
- **employee_accounts:** Login account · Employee · Linked on · Linked by
- **employee_account_history:** Login account · Employee · Change · Changed on · Changed by
- **finance_settings_history:**
  - Changed on · Changed by
  - Approvals were in force · Approvals are in force
  - Previous approval threshold (base currency) · Approval threshold (base currency)
  - Previous level-1 approver role · Level-1 approver role
  - Previous level-2 approver role · Level-2 approver role (at or above the threshold)
- **import_batches:** Imported into · File · Rows · First number · Last number · Imported on · Imported by
- **auth.users** (the M9 projection): ID (technical) · Email · Created on · Disabled until
- **The six dictionaries:** Name (English) · Name (Chinese) · Notes · Active, plus their own columns:
  - substances: Symbol
  - material kinds: Has condition axes · Can ever be processed
  - safety states: Can be fed to processing
  - source reasons: Needs an explanation
- **Table names** (in sentences): additional login change · approval policy change · salary change request · training record · department ·
  bulk import

### §8.3 · English for enumerated values

- **Employment status** (employees and history): On probation · Active · Serving notice · Left.
- **Employment type:** Full-time · Part-time · Internship · Contract.
- **Work category:** Office · Shopfloor.
- **Salary request status:** Waiting for approval · Approved · Rejected · Withdrawn.
- **Link action:** Linked · Unlinked.
- **Import target:** Materials · Suppliers · Customers · Employees · Departments · Storage locations.

## §9 · Decisions taken without asking

1. **M10 is a side registry** (`trail_member_columns()`), not a new column on `trail_subject_members()`. It keeps the member function's
   signature, and with it every earlier subject, byte-identical.
2. **M11 keys a collection by `code` with the id `all`.** The dictionaries have no other stable key that the page also shows.
3. **M12 is a closed set**, and an unknown gate refuses. No 1d-1 subject uses a gate, so fixture 244 proves it with a temporary subject
   (`reviewer` on `performance_reviews`). 1d-2 will use it for real.
4. **`save_employee` is SECURITY INVOKER** and calls `require_permission('module.hr.edit')` first. An RLS-blocked UPDATE is a silent no-op
   (AGENTS.md "写那一半更坏"), so asking first is the only way a refusal can be loud. It does **not** compare old and new values, because that
   comparison reads masked columns (identity number, work email, salary) that the caller cannot select (42501). The change-log trigger already
   writes nothing for an unchanged row (fixture 234 A3).
5. **Grants are written into the migration (section 1b)**, not left to the grants file, because the in-migration proof runs before
   `zzz_function_grants` replays.
6. **Fixture 234's synthetic readers were given module codes** (Q13 made them read rows they had no table rule for).
7. **The dictionary wording prefix is `dictv.`**, not `dict.`, because `dict` is a top-level messages namespace and `check-i18n` would read
   the key as a UI key.
8. **The `/settings/import` record column says `Import <date time>`**, not the file name. A file name such as `good.csv` is read as a dotted
   machine code. The file name still appears in the entry as typed text.
9. **A primary login link reads "Login linked to employee {code}"** by employee code, not name. The account page is read under
   `manage_permissions`, which does not include hr.view.
10. **Salaries render in the base currency**, and a Restricted salary line is kept rather than dropped, so a reader sees that something
    changed even when they may not see what.
11. **Throwaway smoke and probe accounts on live** are treated as allowed (see the opening paragraph).
12. **Q36 (`document_types` links) was not applied in 1d-1.** None of its three rows (medical claim, attendance period, overtime batch) is a
    1d-1 subject; it goes with 1d-2.
13. **`scripts/check-employee-names.mjs` now recognises `.rpc('save_employee')` as a write position.** Without it, the build went red on the
    new write path.
14. **A deleted employee's edit page redirects to its read-only detail page** rather than 404ing or opening an editable form.
15. **`ApprovalsHistory.tsx` was deleted, not hidden** (Q27 "replace").
16. **Q13's visible effect for cfo:** on the global change-history page, `auth.users` and `cod_verification_failures` rows now read
    Restricted for tim@, whose role lacks those table rules. That is the ruling working, and it is noted here because it is a visible change.
17. **The transient 500/503s in the first `no-grant` probe injection** were judged environmental (the rerun had none). I have no
    measurement of their cause.
18. **The B proof's edit sends an explicit field payload.** As `authenticated`, it cannot select the masked columns of the row it is
    editing. That is the same reason the form sends its own fields.

## §10 · Known issues and queue

- `docs/known-issues.md` registers 9 new entries:
  - `AT1D1-MACHINE-TEXT-IN-HUMAN-COLUMNS` (Q10 writers)
  - `AT1D1-KPI-OPEN-CYCLE-SCORES-SELF-READABLE` (Q16)
  - `AT1D1-HR-NOTES-SELF-READABLE` (Q17)
  - `AT1D1-HEALTH-TEXT-AND-PERIOD-TOTALS-BEHIND-HR-VIEW-ONLY` (Q18)
  - `AT1D1-ME-READS-HR-ONLY-PERIOD-TABLES` (Q19)
  - `AT1D1-OVERTIME-APPROVER-NAMES-PAGE-VS-TRAIL` (Q20)
  - `AT1D1-ANONYMISATION-LEAVES-OTHER-TABLES-UNREDACTED` (Q30)
  - `AT1D1-SALARY-EXECUTION-HISTORY-NAMES-THE-RAISER` (Q31)
  - `AT1D1-STEP0-SIDE-FINDINGS` (Q38)
- `docs/forward-queue.md`:
  - AT-1d is split, with 1d-1 ✅ and 1d-2 / 1d-3 pending.
  - The **privacy group (Q16 · Q17 · Q18 · Q30)** sits in UNBLOCK-1 directly after its first item, the payroll-journal leak.
- `docs/change-log.md` §9: the intro, the table rows, M9–M12, and the new §9.14.
