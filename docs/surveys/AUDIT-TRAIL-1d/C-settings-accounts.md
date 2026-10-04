# AT-1d survey C: settings and accounts (Q24 per-account trail, approval policy, dictionaries, import, roles)

Read-only. HEAD `0644806a`. Live queries ran through the Management API as `postgres` (`rolbypassrls = true`, measured first: `current_user = postgres`, `bypass = true`, 2026-10-04 10:54 +08). Every live number below was read with that identity, from base tables, unless it says "as admin". "As admin" means a read-only `SELECT … FROM (SELECT set_config('request.jwt.claims', '{"sub":"<admin@ uuid>"}', true)) s, LATERAL record_trail(…)`: a transaction-local claim with no writes.

**M** = Measured (query or file:line). **I** = Inferred.

Helper: `(scratchpad, not kept) q.sh`.

---

## 0. Re-measure of AT-0 `ops-people-settings.md` §1e, §1f, §2, §4 (the tree moved)

| AT-0 claim | now | |
|---|---|---|
| S3 `accountsActions.ts:saveUserRoles` → set_user_roles, set_user_employee_link | still true: `app/settings/accountsActions.ts:56,71,81` | M |
| S1 createAccount: record_account_event, link, set_user_roles | still true: `app/settings/accounts/accountActions.ts:121` (CREATE), `:151` (DELETE on rollback), `:165` (link), `:173` (roles). These are **three separate RPCs, so three transactions**. A create therefore makes up to three trail entries (event, link, grant), not one | M |
| S5 set_role_permissions "delete-all + reinsert" | **stale.** It now deletes only the codes that are no longer wanted and inserts only the new ones (`db/functions/set_role_permissions.sql:62-67`, change-log §6) | M |
| §2 employee_account_history "3 rows live" | **1 row** (linked, 2026-09-23 15:01:53, tim@ → employee 4737faa9…, actor set) | M |
| §2 finance_settings_history "1 row live" | still 1 (2026-09-22 12:25:06; approvals false→true, finance/cfo/1000 unchanged) | M |
| §2 lib/modules.ts:843-846 "panel is read-only" comment is false | **fixed.** `lib/modules.ts:845-849` now says the page can change the policy. `docs/known-issues.md:9790` AT0-APPROVALS-COMMENT is closed (AT-1a) | M |
| §2 dictionaries registry says "these five" but holds 6 | **still** says 这五张 (`app/settings/dictionaries/registry.ts:26`), and the union lists 6 | M |
| §2 "12 live roles" | 13 rows: 12 active and not deleted, plus `operations` (inactive, deleted_at 2026-09-10 10:28, pre-log) | M |
| §4 auth.audit_log_entries = 0 | still 0 | M |
| §2 "admin no longer holds module.hr.view" (comment `accounts/page.tsx:31-34`) | **false live.** admin holds module.hr.view (role_permissions query) | M |

---

## A. Per-account trail (Q24)

### A1. Where each account event is recorded

| event | table / writer | key and shape | live (postgres) |
|---|---|---|---|
| account create / delete-on-rollback / disable / enable / *_FAILED | `change_log`, `table_name = 'auth.users'`, written by `record_account_event` (`db/functions/record_account_event.sql`, INSERT at the end of the body) | `row_key = {"id": <uuid>}`; `op` = one of 6 values (`ACCOUNT_CREATE`, `ACCOUNT_DELETE`, `ACCOUNT_DISABLE`, `ACCOUNT_DISABLE_FAILED`, `ACCOUNT_ENABLE`, `ACCOUNT_ENABLE_FAILED`); `old` is NULL; `new` = `{email}` plus p_detail (CREATE: `role_id`, `employee_id`; DELETE: `reason: create_rolled_back`); `changed_columns` NULL; actor = the caller's session | **0 rows.** No account event has ever been written. The 7 accounts were all created before the log, and the test accounts are made over the admin REST API with no event (change-log §2) | M |
| role grant / revoke | `user_roles` (row trigger). Grant = INSERT (`granted_at`, `granted_by`). Revoke = UPDATE `revoked_at`, `revoked_by`, `revoke_reason` (`set_user_roles.sql`, the `revoked` CTE). Soft revoke, never deleted by the app | `user_id uuid NOT NULL` with **no FK** (`db/tables/user_roles.sql`). `role_id` has an FK to roles | 9 rows (7 active, 2 revoked). **All 9 granted before the log.** The 2 revokes are pre-log too, with revoked_by set and revoke_reason NULL; 2 grants have granted_by NULL (admin@'s admin and cfo). change_log on user_roles: 148 INSERT + 148 DELETE, **all by `service_role`/`no_session` for test accounts no longer in auth.users**. 0 rows for the 7 real accounts | M |
| primary link | `employees.user_id` UPDATE via `set_user_employee_link` (`db/functions/set_user_employee_link.sql:41,46`) | FK `employees_user_id_fkey` → auth.users ON DELETE SET NULL (`db/tables/employees.sql:253`) | change_log employees rows touching user_id: 48 INSERT + 48 DELETE, all service_role test fixtures. 0 link edits on real employees. No link stamp exists (no `linked_at` on employees) | M |
| additional account | `employee_accounts` I/D (hard delete on unlink) + `employee_account_history` I, via `link_additional_account` / `unlink_additional_account` | `employee_accounts.user_id` is the PK, with an FK to auth.users. History `user_id` has no FK | 1 / 1 row, both 2026-09-23 (pre-log). 0 change_log rows | M |
| disabled state | `auth.users.banned_until` (not logged; only the event row is) | — | **7 accounts, 0 with banned_until set, 0 test.local.** All enabled. `deleted_at` is NULL on all 7 | M |

### A2. Can `record_trail` root on auth.users? No, not today (M)
- Root path: `trail_current_image('auth.users', {id})` → `to_regclass('public."auth.users"')` is NULL → image NULL → `TRAIL_NOT_PERMITTED` (`trail_current_image.sql`; `record_trail.sql:104-108`). Measured: `auth_img_null = true`.
- `trail_row_visible('auth.users', …)` → false. It only looks at `pg_class` rows in schema public with relkind `r` (`trail_row_visible.sql`, first SELECT). Measured: `false`.
- Member discovery hard-codes `FROM public.%I` (`record_trail.sql:125,149`), and `trail_pk_columns` is public-only. So auth.users cannot be a member either.
- `user_directory` (`db/views/user_directory.sql`) is a view: owner-rights (`security_invoker = off`), predicate `has_permission('action.manage_permissions')` in the body, key column `user_id`, not `id`. It cannot be the root:
  - trail_row_visible needs relkind `r`;
  - its change_log rows would be under `auth.users`, not `user_directory`;
  - its `trail_pk_columns` is NULL (M).
- Step ③ (`record_trail.sql`, the `JOIN change_log c ON c.table_name = u.t AND c.row_key = u.k`) **would** find the events if the root's table name were `'auth.users'`. Only the image and visibility steps block.

### A3. Proposed extension, "M9: a log-only root" (I)
- `trail_subjects` row `('account', ARRAY['action.manage_permissions'], 'auth.users', 'id', 'page', NULL)`.
- **Image:** `trail_current_image` special-cases `'auth.users'` with a **fixed safe projection**: `id, email, created_at, banned_until`. Without it the ctx would carry `encrypted_password` and six token columns (measured in information_schema). The function must not `to_jsonb(u)` the whole auth row.
- **Visibility:** a declared rule for the log-only table (`action.manage_permissions`, the same predicate as user_directory). Today, `root_rule='page'` makes the root's own rows go through `trail_row_visible`, which returns false. That would make every account event Restricted, even for admin (`record_trail.sql`, the `v_vis` line in loop ②). So M9 needs either a `trail_row_visible` branch for `auth.users` or a "log-only table rule" list.
- **Pre-log:** `trail_prelog_sources` row `('auth.users','created','created_at',NULL,…)`. It works once the image exists; actor "Not recorded".
- **Members** (all down-hops from key `id`, so `record_trail.sql:141` `u.k ->> 'id'` works):
  1. `user_roles` down `user_id` (no FK; fine, discovery is by column value). Pre-log: `created granted_at/granted_by` + `stamp revoked_at/revoked_by [revoke_reason]` (none registered today; grep of `trail_prelog_sources.sql`).
  2. `employee_accounts` down `user_id`. Pre-log `created linked_at/linked_by`.
  3. `employee_account_history` down `user_id`. Pre-log `created changed_at/actor_user_id`. Fold "one event, two rows" with employee_accounts: same transaction, same `linked_at = changed_at` (measured 15:01:53.992781 on both).
  4. `employees` down `user_id`, the primary link. **Gap:** this would put **every** HR edit of that employee on the account trail. It needs M6 on members ("member_columns = ['user_id']", the gap 1c already named for payroll). Log-only discovery `old @> {user_id}` catches unlinks.
- `home`: user_roles → `account` (or `role`, see E). employee_accounts / history → `account`.
- Wording: `lib/trail/text.ts:52-57` already has the six `account.*` sentences, and `describeGeneric` handles `ACCOUNT_*` (`lib/trail/render.ts:848-853`). `auth.users` is **not** in `TRAIL_TABLES` / `TRAIL_FIELDS` (catalogue, M). user_roles, employee_accounts and employee_account_history are labelled (`user_id` → "User", actor).
- `change_log_rows` already gives `auth.users` rows no refs and no Record (`change_log_rows.sql:105`). The summary page's Record column would need M9 too.

### A4. The employee-page mirror (I)
- The `/hr/employees/[id]` guard is `requireModule(MOD.hr)` (`app/hr/employees/[id]/page.tsx:32`), i.e. module.hr.view. Holders: **admin, auditor, cco, cfo, cto, finance, gm, hr** (live). The page shows no account information today (grep: no user_id, user_directory or employee_accounts read).
- **Option 1: a second subject `employee_account` on the employee page.** Root `employees` (M3 not needed). Members:
  - `employee_accounts` down `employee_id`;
  - `employee_account_history` down `employee_id`;
  - `auth.users` **up** `user_id` from employees, and up from employee_accounts (stepping stone or shown);
  - then `user_roles` down `user_id` from auth.users.
  - The up-hop calls `trail_current_image('auth.users', …)` (`record_trail.sql:133-139`), so it needs the same M9 image.
- Constraint: up-hops follow only the **current** `employees.user_id` (`record_trail.sql:133`). An account linked earlier and later unlinked would not be reached. It would only appear if the employees.user_id edit row were a shown member with M6-on-root.
- **What hr readers without manage_permissions would see** (all 7 non-admin hr.view roles):
  - user_roles rows: **visible** (policy `USING (true)`);
  - employee_accounts: visible (hr.view);
  - employee_account_history: **Restricted** (manage_permissions only);
  - account events: Restricted under the proposed rule.
  - **Decision for Tim:** is "who can log in as this person, and with which roles" an HR fact (show it) or an admin fact (Restricted)? Today the grants are readable by every login anyway.
- Only `admin` holds action.manage_permissions, and only `admin@swm-os.test` holds `admin`. So on live **one account** can read the /settings/accounts trail.

### A5. /settings/accounts readers and UI hook (M)
- Guard `requireManagePermissions()` (`app/settings/accounts/page.tsx:15`, `app/settings/guard.tsx:19`). The data comes from `user_directory` (`page.tsx:24`).
- `UserRow` is a client component (`UserRow.tsx:1`). `AuditTrail` is an async server component with a `compact` `<details>` mode (`app/components/trail/AuditTrail.tsx:109-123`). So the page must render a `<AuditTrail compact subject="account" id={user_id}>` per row and pass it into UserRow as a child or slot (I). The journal-request and claim cards are the precedent.

---

## B. Approval policy panel (/settings/approvals)

- **Writer (M):** `set_approvals_policy` UPDATEs exactly the four columns `approvals_enabled, approval_level1_role_code, approval_level2_role_code, approval_threshold_base`, plus `updated_by` (`db/functions/set_approvals_policy.sql:64-70`), and INSERTs one `finance_settings_history` row (`:76-87`), in the same transaction. It returns early when nothing changes (`:55`).
- The guard is `require_permission('action.manage_permissions')` (`:40`). The server action is `app/settings/approvals/actions.ts:69`. The page guard is `requireFunction(FN.approvals)` (`page.tsx:60`) = `/settings/approvals`, permission `P_MANAGE_PERMISSIONS` (`lib/modules.ts:850`, `:1023`).
- **Registered anywhere?** No. `finance_settings_history` appears in no trail_* function. Its readers are only `app/settings/approvals/page.tsx:78-82` (query, last 10) → `ApprovalsHistory` (`ApprovalsHistory.tsx:30`, rendered at `page.tsx:129`). The other hits are types, catalogue, fixtures 202/234, the build script and check-document-registry (M, grep).
- **M7 is ready:** `hop='all'` under an M5 root (`record_trail.sql:121-130`). change-log §9.9 already names "AT-1d's approval policy (`finance_settings_history`)". Proposed:
  - `('approval_policy', ARRAY['action.manage_permissions'], 'finance_settings', 'id', <rule>, ARRAY[4 cols])`;
  - member `('approval_policy',1,'finance_settings_history','finance_settings',NULL,'{}','all',true,true)`;
  - pre-log `('finance_settings_history','created','changed_at','changed_by',NULL,'account')`.
- **Read-rule mismatch (M):** finance_settings is read under `module.finance.view`, while the history and the page use `action.manage_permissions`. admin holds both today, so `'table'` works. A future manage_permissions holder without finance.view would get `TRAIL_NOT_PERMITTED`.
  - With `'page'` (M3), that holder would see the root UPDATE Restricted and the history row visible. Under the 1b-3 "one event, two rows" rule the change-log row speaks, so the sentence would be Restricted while its twin is readable.
  - **Tim to choose:** `'table'` (simple, correct today), or `'page'` plus "the history row speaks when the root row is hidden" (I).
- **Pre-log:** 1 history row (2026-09-22) and 0 change_log rows on finance_settings or its history. The trail today = one pre-log entry, "Approvals switched on". The settings row has no own stamp (1c-3 §9.13: nothing registered).
- **Labels (M):** the 4 columns are labelled in `lib/trail/catalogue.generated.ts`:
  - "Approvals are in force" (boolean);
  - "Level-1 approver role" (dict);
  - "Level-2 approver role (at or above the threshold)" (dict);
  - "Approval threshold (base currency)" (money).
  - The **history** columns are machine-generated and inconsistent: "New approval level1 role code" (`text_code`, not `dict`), "Old approval threshold" vs "Previous approvals enabled". They are only needed for the pre-log row. They need OVERRIDES that reuse the root labels, and role codes resolved as `dict`.
- Q26: `ApprovalsHistory` is a pure change history → **replace**. Its header comment (`ApprovalsHistory.tsx:9-10`) says the table "is empty after APR-1", which is stale: there is 1 row. The page note `finance.approvals.noConfigUi` (`messages/en.ts:7978`) says "Every change made here is recorded below". That stays true if the trail sits below.

## C. Dictionaries (/settings/dictionaries)

- The registry (`app/settings/dictionaries/registry.ts:75-157`) has 6 tables: substances, battery_chemistries, material_kinds, inbound_safety_states (view `module.materials.view`), laboratories, inbound_source_reasons (view `module.inbound.view`). Write is `module.materials.edit` for all 6 (M).
- The RLS matches: SELECT `true`, INSERT and UPDATE `materials.edit`, **no DELETE policy** on any of the 6 (pg_policies, M).
- Key: PK `code text` on all 6, with **no created/updated/deleted stamps** (pg_attribute, M). So no pre-log source is possible; the trails start at the log.
- Live rows: 7 / 8 / 5 / 5 / 1 / 4, 0 inactive, **0 change_log rows**. Every trail is empty today (`emptyOk`).
- Writes:
  - `addDictValue` INSERT (`actions.ts:86`);
  - `updateDictValue` UPDATE `.eq('code')`, which never changes `code` (`:118`);
  - `setDictActive` UPDATE `is_active` (`:136`).
  - Deactivation, never delete. Restore = reactivate.
- **Text key in record_trail (M + I):**
  - The root is `jsonb_build_object(root_key, p_id)`. `trail_current_image` compares `t.code::text = 'ni'`; measured, it returns the row. The M5 rebuild keeps a JSON string. change_log `row_key` for text keys is `{"code": "…"}` (measured on `permissions`). So a code-keyed root works.
  - But **no subject has `root_key <> 'id'` today** (trail_subjects query, M). This path has never run, so a fixture must cover it.
  - Limitation: down-hop members need the parent key named `id` (`record_trail.sql:141`), so nothing can hang under a code root. Dictionaries need no members.
- Shape (I): one subject per table (a subject has one root table): `substance`, `battery_chemistry`, … with root_key `code` and view codes from the registry. Then a **ListTrail per section** (5–8 records each; laboratories 1) with `records = rows of that section` (inactive included). "Deactivated / Reactivated" wording follows the 1b-3 `role.deactivated` precedent. `ListTrail` is typed by `TrailSubject` (`ListTrail.tsx:37`), so the six subjects get added there.
- `TRAIL_FIELDS` already label all six tables (`code` → own_key, `is_active` → Status) (M).

## D. Bulk import (/settings/import)

- `import_batches` (`db/tables/import_batches.sql`):
  - `target_table` ∈ {materials, suppliers, customers, employees, departments, storage_locations};
  - plus file_name, row_count, code_first, code_last, imported_at, imported_by.
  - RLS SELECT `action.bulk_import` (admin only). Only SELECT is granted to authenticated, so it has **no delete path**.
- `master_import_apply` inserts the rows (`master_import_apply.sql:228`) and then the batch row (`:297-302`) **in one transaction**. It returns `batch_id` (`:304`).
- **There is no batch id on target rows** (information_schema: no `*import*` column outside import_batches and inbound_batches, M). The table COMMENT forbids lineage outright: "「这一行是导入来的吗」不许从这里推导,也不许有任何东西按它去 JOIN 业务表" ("whether a row was imported" must not be derived from here, and nothing may JOIN business tables on it). That **conflicts with AT-0 §4's "created by import batch X"**.
- What is possible without lineage (I): after the log, the created rows and the batch row share a `txid`. The renderer could say "Created by bulk import · <file>" only if record_trail returned the batch row, and it has no key to reach it. Before the log, the shared timestamp is the only tie: supplier `created_at = imported_at` exactly, 2+2 rows (measured on the 2 live batches, both suppliers, 2026-08-24, codes ZZWALK15-SUP-1..2 and ZZWALK16-SUP-1..2, all still live). **Tim to rule** whether the comment's rule stands, which means no back-link.
- Today `ImportHistoryTable` (`app/settings/import/page.tsx:53-60` query, last 20; render `:84`; columns `ImportHistoryTable.tsx:25-29`) shows when, table, file, rows and code range, with **no "who"** (`imported_by` is not selected).
  - It is the log itself, a working list. **Keep** it; add "who" as a column, or a `ListTrail` of `import_batch` subjects (root import_batches, no members, pre-log `created imported_at/imported_by`).
  - Live: 2 batches, both pre-log, change_log 0.

## E. Role page grants (M)
- The `role` subject (`trail_subjects.sql:111`) has **one** member: `role_permissions` (`trail_subject_members.sql:46`). **user_roles is not a member.**
- As admin, `record_trail('role', <cto id>)` returned only role_permissions and roles rows. Phua's cto grant (2026-09-10) is absent.
- Pre-log sources exist for roles (created, deleted_at stamp) and role_permissions (created), at `trail_prelog_sources.sql:48-50`. role_permissions: 338 rows, all pre-log, 231 with created_by.
- Adding `('role', 2, 'user_roles', 'roles', 'role_id', …, 'down', true, <home?>)` works with no mechanism change (FK role_id). `user_roles` would then belong to both `role` and `account`, and **one must be `home`** (I: `account`, because the account is the thing granted to).

## F. Q21 for settings (M)
- `/settings/deleted` reads `deleted_records` (`app/settings/deleted/page.tsx:117`). It has **12 kinds**: inbound_batch, output_batch, processing_run, stocktake, purchase_order, sales_order, quote, customer, supplier, material, pricing_formula, bank_statement (`db/views/deleted_records.sql`). **Roles, dictionary values, import batches and accounts are not among them.**
- **Deleted roles:** soft delete (`softDeleteRole`, `accountsActions.ts:145`). The role page filters `.is('deleted_at', null)` and calls `notFound()` (`app/settings/roles/[id]/page.tsx:32,42`). The roles list filters the same way (`roles/page.tsx:36`). So a deleted role **404s**: the exact Q21 shape.
  - Live: 1 deleted role (`operations`, 2026-09-10, pre-log; the `deleted_at` stamp is registered, with no deleter column).
  - The test roles in change_log (19 I / 19 D by service_role, `probe-smoke-*`) are hard-deleted fixtures.
  - **Propose:** open a deleted role read-only for `data.view_deleted` holders with the trail, and add a `role` branch to `deleted_records`, following the 1b-3 pattern (I).
- **Deleted dictionary values:** impossible through the app (no DELETE policy). Deactivated values stay listed. Nothing to do.
- **Deleted import batches:** impossible (SELECT-only grant). The pre-go-live wipe clears them by owner, deliberately (table comment).
- **Accounts:** disabled, never deleted. A disabled account stays in user_directory with `disabled = true`, so its row and trail stay reachable.

## G. Settings sections: replace vs keep

| page | section | verdict |
|---|---|---|
| /settings/approvals | `ApprovalsHistory` (`page.tsx:129`) | **replace** with `approval_policy` trail (pure change history) |
| /settings/import | `ImportHistoryTable` (`page.tsx:84`) | keep (the batch log is the record list); add who |
| /settings/accounts | UserRow fields: created, last sign-in, roles, disabled badge | keep (current state); add per-row compact trail |
| /settings/roles/[id] | already `AuditTrail subject="role"` (`page.tsx:89`) | keep; add user_roles member (E) |
| /settings/roles | list with member / permission counts | keep, no trail |
| /settings/dictionaries | sections with "in use" counts | keep; add a ListTrail per section |
| /settings/reference | read-only matrix | no trail |
| /settings/change-history, /settings/deleted | readers | no trail (deleted gains role kind if F is accepted) |

## Open questions for Tim
1. M9 (log-only `auth.users` root): accept the safe-projection image plus a declared rule (`action.manage_permissions`)?
2. On the employee page, are account grants and events shown to hr readers or Restricted? Today `user_roles` is readable by every login.
3. Show the primary link (employees.user_id) on the account trail? That needs M6-on-members, or else every HR edit shows.
4. Account creation is 3 transactions, so 3 entries. Keep them, or merge by actor and time?
5. `user_roles` home: `account` or `role`?
6. Approval policy: root_rule `'table'` or `'page'` plus the history row speaking when the root row is hidden?
7. Import back-link: does the import_batches comment's "no lineage" rule stand?
8. Deleted roles: open read-only and list them on /settings/deleted?
