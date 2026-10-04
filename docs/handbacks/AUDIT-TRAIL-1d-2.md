# AUDIT-TRAIL-1d-2 — leave and time: leave requests, leave grants, leave types, public holidays, medical claims, overtime batches, attendance periods, and the employee's own leave and claims on `/me` (2026-10-04)

Part of v1.4.33, not yet released.

**Opening check:** measured at **2026-10-04 16:59:37 CST** (this session's first command). The tree was clean apart from Tim's untracked
`docs/Data capture and ERP integreation.pdf`, which I did not touch. After `git fetch`, `HEAD` = `origin/main` = `ls-remote` =
`a228de72866184729eea80064ecfaf7ea95c4418`. **Approvals were ON and stayed ON** (finance / cfo / 1,000). All 7 real accounts were enabled before and after.
No auth account was created, disabled or deleted by this cut's own work. The smoke and probe harnesses' throwaway accounts came and went
through their own ephemeral plans (§7.1).

Every figure below is either a script's own exit line or a query named together with who ran it. Unless stated otherwise, the reader is `postgres`
(`rolbypassrls = true`) reading base tables. "As X" means `SET LOCAL ROLE authenticated` plus X's JWT.

This is cut 2 of the 3 AT-1d cuts (1d-1 → **1d-2** → 1d-3). It is built on Tim's answers to `docs/surveys/AUDIT-TRAIL-1d/STEP0-HANDBACK.md`
(Q1–Q38, all accepted as recommended on 2026-10-04). **1d-3 (pay and performance) and DATE-PICK-1 are untouched.** The payroll, review,
review-cycle, rating-scale and KPI pages are exactly as they were. The mechanism reference is **`docs/change-log.md` §9**, which has a new §9.15.

## §1 · Step 1 — the 1d-1 close-out, item by item

**The broken window** is recorded in `docs/forward-queue.md` item 30 (the 1c-3 format) and in `docs/handbacks/AUDIT-TRAIL-1d-1.md` §7.3:

| | value | source |
|---|---|---|
| start | **2026-10-04 15:35:59 CST** | `db/migration-windows.tsv` |
| end, lower bound | **2026-10-04 16:55:17 CST** | `git reflog show --date=iso refs/remotes/origin/main`: `a228de72 refs/remotes/origin/main@{2026-10-04 16:55:17 +0800}: update by push` |
| end, upper bound | **2026-10-04 16:59:37 CST** | this session's first command (`date`). It rests on Tim's "deployed", **not** on a Vercel reading |
| window | **at least 1 h 19 min 18 s, at most 1 h 23 min 38 s** | |

**Read-only verification of what the 1d-1 report did not mention:**

| | item | verdict | evidence |
|---|---|---|---|
| a | Q10 renderer recognitions for the 1d-1 tables | ✅ | `lib/trail/render.ts:3667-3676` (`APP_CHANGE_NOTE`, `historyNote`): `/^Probation confirmed by performance review [0-9a-fA-F-]{36}$/` → `emp.noteReview`; `/^Salary change approved with request (.+)$/` → a "Salary change request: <label>" line; the form's own "status: a → b; department: …" summary → not said. `decided_via`: `scripts/gen-trail-catalogue.mjs:511` `salary_change_requests: { snapshot: 'technical', decided_via: 'technical' }`, also skipped at `render.ts:3812`. The hand-back's other Q10 writers (overtime, payroll) belong to 1d-2 / 1d-3 |
| b | Q12 pre-log stamps | ✅ | `db/functions/trail_prelog_sources.sql:293-299`: `('auth.users','created','created_at',NULL…)` · `('user_roles','created','granted_at','granted_by'…)` · `('user_roles','stamp','revoked_at','revoked_by',ARRAY['revoke_reason']…)` · `('employee_accounts','created','linked_at','linked_by'…)` · `('employee_account_history','created','changed_at','actor_user_id'…)` · `('finance_settings_history','created','changed_at','changed_by'…)` · `('import_batches','created','imported_at','imported_by'…)` |
| c | Q30 wording and its fixture arm; Q31 | ✅ | `lib/trail/text.ts:704` `'emp.anonymised': 'Personal data anonymised'`, `:36` `'who.anonymised': 'A former employee'`; `render.ts:3763`. Fixture 244 arm N `:340-355` (`anonymise_employee`, then "the anonymised name is still on the trail" raises, and `trail_actor(...) ->> 'state'` must be `anonymised`). Wording arm ⑪ `check-trail-wording.mjs:2723-2728` (who = "A former employee"). Q31: after the log, "who" is the change log's actor (`change-log.md` §9.14); the writer is registered at `docs/known-issues.md:10080` `AT1D1-SALARY-EXECUTION-HISTORY-NAMES-THE-RAISER` |
| d | Q32 "Name (English) / Name (Chinese)"; Q33, Q34 labels and enum English on the 1d-1 subjects; Q35 page words | ✅ | `gen-trail-catalogue.mjs:409-476` (overrides for employees, employment_history, salary_change_requests, training_records, departments `:443` "Name (English)" / "Name (Chinese)", user_roles, employee_accounts, employee_account_history, finance_settings_history, import_batches, the six dictionaries `:465-475`), each commented against its page; enums `:796-803` (employment status, type, category, salary request status, link action, import target). Q35 page words on the 1d-1 subjects: "Role granted to …", "Login linked to employee …" (`text.ts`, §8 of the 1d-1 hand-back). Q32's remaining tables (leave types, holidays, rating scale) belong to 1d-2 / 1d-3 by the "first cut that shows the table" ruling |
| e | known-issues and the privacy group | ✅ | `docs/known-issues.md:10017` Q10 writers · `:10033` Q16 · `:10041` Q17 · `:10049` Q18 · `:10057` Q19 · `:10064` Q20 · `:10071` Q30 · `:10080` Q31 · `:10087` Q38 side findings. `docs/forward-queue.md:6656-6669`: UNBLOCK-1, first item the payroll-journal leak, then "隐私组 … Q16 · Q17 · Q18 · Q30 一起排在第一条之后" with the four entries |
| f | the two stale Q38 comments | ✅ | `app/settings/accounts/page.tsx:39-40` ("这里以前写着'系统管理员账号不再持 module.hr.view'—— 线上量过,admin 持着它"); `app/settings/dictionaries/registry.ts:26` ("这六张字典本身(… 这里以前写着'五张' …)"). **One note:** the same file's header (lines 1–11, DICT-ADMIN) still says "五张字典" and "2/5". That is DICT-ADMIN's dated record of 2026-08-23 (`git log` of the file: `7f6f97b3 DICT-ADMIN:五张字典有门了`), when there were five; the sixth arrived on 2026-09-01 (`22c22f05`). Step 0 named line 26, and that line is fixed. I left the dated header alone |
| g | the employee-page account mirror for a reader without `action.manage_permissions` | ✅ | Fixture 244 arm E `:191-202` (grant visible to HR; `row_hidden` present; no `auth.users` row readable). **Live, read-only, as vince@ (gm: hr.view, no manage_permissions), rolled back**, `record_trail('employee', EMP-2026-0002, 100)` grouped: `(hidden)` × 3 · `employee_accounts INSERT` × 1 (the additional login, visible) · `user_roles INSERT` × 3 and `UPDATE` × 1 (grants, visible) · `employees INSERT` · `employment_history INSERT`. Policies: `employee_accounts.sql:46-51` (hr.view OR manage_permissions OR own), `employee_account_history.sql:38-41` (manage_permissions only), `user_roles.sql:95-98` (`USING (true)`) |
| h | the identical-output check includes a 1d-1 subject; change-log §9 covers M9–M12, Q13 and the 1d-1 subjects | ✅ | `scripts/probe-at1d1.mjs:160` (`NEXT_LOCALE=${locale}`), `:251` (cjk injection), `:254` (`zt === et`) over every live employee page and the other 1d-1 pages. `docs/change-log.md`: intro `:234-239`, table rows `:303-309`, M9–M12 `:545-548`, §9.14 `:700-743` (Q13 first bullet) |
| i | 1d-1's self-taken decisions (`AUDIT-TRAIL-1d-1.md` §9, titles) | listed | 1. M10 is a side registry. 2. M11 keys a collection by `code` with the id `all`. 3. M12 is a closed set. 4. `save_employee` is SECURITY INVOKER. 5. Grants are written into the migration. 6. Fixture 234's synthetic readers were given module codes. 7. The dictionary wording prefix is `dictv.`. 8. The import record column says `Import <date time>`. 9. A primary login link reads by employee code. 10. Salaries render in the base currency; a Restricted salary line is kept. 11. Throwaway smoke and probe accounts on live are allowed. 12. Q36 was not applied in 1d-1. 13. `check-employee-names.mjs` recognises `.rpc('save_employee')`. 14. A deleted employee's edit page redirects. 15. `ApprovalsHistory.tsx` was deleted, not hidden. 16. Q13's visible effect for cfo. 17. The transient 500/503s were judged environmental. 18. The B proof's edit sends an explicit field payload |

**Nothing in a–h was missing or partial, so step 2 went ahead.**

**Live state in the brief, re-measured:** 7 accounts, 0 disabled; approvals ON; 8 pending documents (`db/scripts/2026-10-04-at1d2-live-readings.sql`,
§7.1). Every pending document still has a decider other than itself (the migration's own proof, ⑥). One reading moved before this session wrote
anything: `change_log` held **4,234** rows at 18:47 against the 4,039 in 1d-1's after-reading (16:33). My statements up to then were reads only
(the two read-only measurements above and the before-readings), so those 195 rows were written by someone else between 16:33 and 18:47. I did not investigate them.

## §2 · Subjects covered (9 new; 68 → 77) and one member added

| subject | page | root (rule) | members (home = this subject unless noted) |
|---|---|---|---|
| `leave_request` | `/hr/leave/[id]` | `leave_requests` (hr.view) | `leave_consumption` · `approval_log` {leave_request} |
| `my_leave_request` | `/me`, one per own request (compact) | `leave_requests`, **M8** (no page code: HR or own) | the same two, not home |
| `leave_grant` | `/hr/leave/grants` (`ListTrail`, the selected leave year) | `leave_grants` (hr.view) | — |
| `leave_types` | `/hr/leave/types` | **M11** collection, root key `code` | — |
| `public_holidays` | `/hr/leave/holidays` | **M11** collection, root key `id` (hard deletes found in the log) | — |
| `medical_claim` | `/hr/claims/[id]` | `medical_claims` (hr.view) | `approval_log` {medical_claim} · `expenses` (up, M4) · its `journal_entries` (up) · `payment_allocations` · the reversing `expenses` (up) · their `journal_entries` reversals (up) — all not home |
| `my_medical_claim` | `/me`, one per own claim (compact) | `medical_claims`, **M8** | the same six, not home |
| `overtime_batch` | `/hr/overtime/[id]` | `overtime_batches`, **M1**: `module.hr.view` · `action.overtime_enter` · `action.overtime_approve` (the page guard's codes) | `overtime_lines` · `approval_log` {overtime_batch} |
| `attendance_period` | `/hr/attendance/[id]` | `attendance_periods` (hr.view) | `attendance_lines` |
| `expense` (extended, Q37) | `/finance/expenses/[id]` | unchanged | + `medical_claims` by `expense_id` (not home) |

**Q12 pre-log stamps registered** (`db/functions/trail_prelog_sources.sql`, the 1d-2 block): `leave_requests` created and `stamp decided_at/decided_by
[status, decision_notes]` (status-aware; it folds with the approval row written at the same moment) · `leave_consumption` created · `leave_grants`
created and `deleted_at` · `leave_types` and `public_holidays` created · `medical_claims` created and `stamp withdrawn_at` with **no person column**
(→ "Not recorded") · `overtime_batches` created, `stamp reversed_at/reversed_by [status, reverse_reason]`, `stamp discarded_at/discarded_by [status]` ·
`overtime_lines` created and `voided_at` · `attendance_periods` created (`opened_at/opened_by`), `stamp completed_at/completed_by [status]`,
`stamp reopened_at/reopened_by [reopen_reason]` (latest only, and the trail says so) · `attendance_lines` `recorded_at/recorded_by [note]` and
`frozen_at`. Decisions already in `approval_log` (overtime submit / decide, medical decide) are not registered twice.

**Q36:** `document_types.medical_claim` and `.attendance_period` now link to their detail pages. **`overtime_batch` was not added** (decision §9 #1).

## §3 · What was built

### Database
- Changed (`db/functions/`, same signatures, replaced in place): `trail_subjects.sql`, `trail_subject_members.sql`, `trail_prelog_sources.sql`,
  `trail_ref_label.sql` (a leave grant's label "<leave type> <year>"; an overtime batch's link to `/hr/overtime/<id>`), `trail_row_record.sql`
  (an overtime row's Record column links to its batch). `record_trail` is unchanged.
- `db/tables/document_types.sql`: the two seed rows' `link_mode`.
- Migration: `db/migrations/2026-10-04-at1d2-trails-leave-and-time.sql` (1,661 lines), built by `db/scripts/build_at1d2_migration.py` from the
  mirrors. Its precondition is 68 subjects; its proof (in the same transaction) checks grants unchanged, approvals ON, pending documents
  unchanged, `change_log` grown by exactly the two `document_types` updates, 77 subjects, execute rights, no disabled account, then reads every
  new record as admin@ and every own leave request and claim as its employee (none refused), and the Q36 rows.

### Renderer (`lib/trail/`)
- `render.ts`: a new `describeTime` family (leave, grants, medical claims, overtime, attendance, and the approval rows of those three kinds);
  leave types and public holidays use the dictionary family (M11), whose `describeDict` now says a hard delete with its last values;
  `stripOvertimeMachineNote` (Q10); medical claims are worded by `describeTime` on the expense page too (Q37); on a claim page the expense,
  journal and allocation rows go through `describeFinance`; years print without a thousands separator; medical claim amounts are in the base
  currency; an expense's system note ("Medical claim MC-… (EMP-…)") is not shown as a reason on the claim page.
- `text.ts`: 43 new keys (§8.1). `catalogue.generated.ts`: regenerated with the 1d-2 labels (§8.2).

### App
§4 lists the pages. The Q38 side findings on these pages (the uuid fragment in the leave consumption table; the claim page's expense link to the
list) were **not** changed — Tim's Q38 ruling was "fix only the two stale comments".

## §4 · Pages — every new or changed route, with its file

| route | file(s) | what changed |
|---|---|---|
| `/hr/leave/[id]` | `app/hr/leave/[id]/page.tsx` | the leave request's trail at the bottom; the consumption ledger stays (Q27) |
| `/hr/leave/grants` | `app/hr/leave/grants/page.tsx` | a list block of the selected leave year's grants (record label `<employee code> · <year>`) |
| `/hr/leave/types` | `app/hr/leave/types/page.tsx` | one trail for the whole leave-type table (M11) |
| `/hr/leave/holidays` | `app/hr/leave/holidays/page.tsx` | one trail for the whole public-holiday table, all years (M11; hard deletes) |
| `/hr/claims/[id]` | `app/hr/claims/[id]/page.tsx` | the medical claim's trail at the bottom |
| `/hr/overtime/[id]` | `app/hr/overtime/[id]/page.tsx` | the batch's trail at the bottom; the stamp list stays (Q27) |
| `/hr/attendance/[id]` | `app/hr/attendance/[id]/page.tsx` | the period's trail at the bottom |
| `/me` | `app/me/page.tsx`, `app/me/MyLeavePanel.tsx`, `app/me/MyClaimsPanel.tsx` | a collapsed trail per own leave request and per own medical claim (the expense-claim precedent) |
| `/finance/expenses/[id]` | (no file change) | its trail now includes the medical claim the expense pays (Q37, a registry member) |

Shared components: `app/components/trail/AuditTrail.tsx` (9 subjects), `ListTrail.tsx` (`leaveGrants` intro).

## §5 · Verification, in the brief's order

| # | check | result |
|---|---|---|
| 1 | offline gate | `GATE_OFFLINE_EXIT=0` (71 s; fixtures 244 and 245 ✓). An earlier run while I was writing fixture 245 was `GATE_OFFLINE_EXIT=4` on fixture 245 itself (two overtime lines on the same day — `OVERTIME_DUPLICATE_DAY`); fixed in the fixture before the run above |
| 2 | backup (background) | `BACKUP_EXIT=0`, 18:46 → 18:57, `evoltrya-backup-2026-10-04-1846.dump`, 5.7 MB, TOC 7,321 |
| 3 | apply | dry run (COMMIT → ROLLBACK, on live): first `DRY_OWN_EXIT=3` — the migration's own proof refused because the two `document_types` updates are themselves logged (+2 change-log rows, and the proof allowed none); the proof now allows exactly those two. Second dry run `DRY_OWN_EXIT=0`. Pre-flight passed. `APPLY_OWN_EXIT=0`, **committed 19:00:10 CST** (`db/migration-windows.tsv`; the script printed 18:59:02 at the start of the transaction). In-migration proof: 14 records read as admin@, 7 own records read as their employee, none refused |
| 4 | generate types | `TYPES_OWN_EXIT=0`, no change (no signature moved) |
| 5 | tsc | `TSC_OWN_EXIT=0` |
| 6 | build | `BUILD_OWN_EXIT=1`: every static check passed; `next build` could not fetch Google Fonts (network: "Failed to fetch `Geist` from Google Fonts"). Retried once immediately (AGENTS.md: retry once, no waiting): `fonts.googleapis.com` answered HTTP 200, `BUILD2_OWN_EXIT=0`. Rerun after the last renderer change: `BUILD3_OWN_EXIT=0` |
| 7 | full gate | `GATE_EXIT=0` (414 s for the three verdicts). Rebuild ✓ ("NO DIFFERENCES — the rebuild matches live"), mirrors ✓, fixtures ✓ (245 ✓). B1/B2: 0 on both sides. Changelog: 242 tables, 238 recorded, 4 exempt. Changemask: 27 tables / 81 columns. Anon surface: 326 relations + 1 function ⊆ baseline 327 |
| 8 | i18n | ✓ inside the build (`check-i18n`) |
| 9 | error swallowing | ✓ inside the build: "0 unallowed, 0 queued, 9 allowlisted" |
| 10 | layout survey, 8 paths at 390 px and 1280 px | `SURVEY390_OWN_EXIT=0`, `SURVEY1280_OWN_EXIT=0`: 8/8 U1 and U2 at both widths (two leave requests, the medical claim, its expense, leave types, holidays, grants, `/me`). Rerun after the field-order fix: `SURVEY390B_OWN_EXIT=0`, `SURVEY1280B_OWN_EXIT=0`, 8/8 again. **Not surveyed:** `/hr/overtime/[id]` and `/hr/attendance/[id]` — there is no live overtime batch or attendance period to open |
| 11 | smoke | `SMOKE_EXIT=0`: 243 routes, 9 skipped for no data (packs ×2, payment requests, statements PDF, attendance period, overtime batch, handover, output assay, commission). Scratch cleanup reading: the same 6 stale `ZZ-SMOKE-*` rows as in 1d-1 (materials PROBE / M25 / NTF, supplier S25, customer CJK, inbound batch IB25; 5 still referenced; report-only, none deleted). Rerun after the renderer change: **`SMOKE_EXIT=6`** — the Supabase API stopped answering mid-run ("fetch failed", timeouts): 18 routes failed with 503 marked by the smoke itself as "auth unreachable, not this page", `/hr/leave/new` returned 500 after 77.5 s, and **cleanup could not finish** (its plan stayed in `.ephemeral/24433.json`: the throwaway admin account, its grant and all-codes role, a reviewer account, a ZZ-SMOKE employee, a review, a contract). Once the API answered again (measured: HTTP response in 2.0 s), `npm run reap:ephemeral` → `REAP_OWN_EXIT=0` ("收割 1 份 · 补删失败 0 份"), and live read back as postgres: 0 `@test.local` accounts, 7 accounts / 0 disabled, 0 `probe-*` roles, 0 `ZZ-SMOKE*` employees, 0 grants without an account, 0 reviews, 0 contracts. Retried once immediately (AGENTS.md): **`SMOKE_EXIT=0`, 260 ok, 9 skipped (no data), 0 failed** (`/hr/leave/new` included); scratch cleanup reading unchanged (the same 6 stale rows) |
| 12 | live verification | §7 |

**Wording check** (`scripts/check-trail-wording.mjs`): `TW_OWN_EXIT=0`; after the two renderer fixes `TW2_OWN_EXIT=0`. Arm ⑫ is new: 47 goldens,
a `stripOvertimeMachineNote` contract check, and a sweep of the nine subjects (plus every approval decision and every overtime status) with
each page's own subject.

**Page probe** (`scripts/probe-at1d2.mjs`, port 3189): `AT1D2_PROBE_EXIT=0`, 38 passed, 2 skipped (no live overtime batch or attendance period).
It renders every live leave request (6), the medical claim and its expense (Q37), the leave-type, holiday and grant pages, an employee and a purchase
order, each in both interfaces, identical. Rerun after the renderer fixes: `AT1D2_PROBE_EXIT=0`, 38 passed.

## §6 · Fault injection

**Fixture 245** (`db/scripts/2026-10-04-at1d2-fixture-injections.py`, on a local rebuild of the mirrors): `INJECTIONS_OWN_EXIT=0 (16 injections,
0 wrong)`; the clean run is green and every injection went red in the arm it names:

1. L: the approval rows dropped from the leave request
2. P (Q12): the leave decision stamp not registered
3. X (Q12): the decision stamp loses its person
4. M (Q15): the ActorName rule switched off
5. G: leave grants' creation not registered
6. T (M11): leave types no longer a collection
7. H: a collection ignores rows that are only in the change log (the hard-deleted holiday)
8. C (Q37): the medical claim dropped from the expense
9. C (Q12): the withdrawal guesses its person from `updated_by`
10. O (M1): the overtime batch admits hr.view only
11. O: overtime lines dropped from the batch
12. D (Q12): the voided-line stamp not registered
13. A (Q12): the reopen stamp not registered
14. A: the frozen-line stamp not registered
15. R (Q36): the medical claim links to its list again
16. R (Q36): overtime lines lose their batch link

**Wording check:** `wording-drift-1d2` → ⑫ only (`TW2INJ_OWN_EXIT=1`, 3 findings in ⑫, every other arm green).

**Page probe:** `q37-missing` → only the Q37 check red (`AT1D2_PROBE_EXIT=1`, 37 passed · 1 failed); `cjk` → the identical-output checks red;
`machine` → the machine-token checks red. Each exit 1.

**Machine tokens:** every new subject is scanned by the wording check (arm ⑫), the smoke (real HTML), the probe (real HTML, both interfaces) and the
proof render (§7.2).

## §7 · Live verification

### §7.1 · Before / after readings (`db/scripts/2026-10-04-at1d2-live-readings.sql`, as postgres; recon as tim@)

| reading | before migration (18:47:02) | before the proof (19:59:14) | after the proof (20:01:44) |
|---|---|---|---|
| accounts | 7 accounts, 0 disabled · `ababff588d2a` | same | **same** |
| roles held | 9 grants · 7 live · `abfbe072ced1` | same | **same** |
| approvals | ON | ON | ON |
| pending documents | 8 · `c113de0d5542` | same | **same** |
| site staff | 0 | 0 | **0** |
| leave requests / consumption / grants | 6 · `1aa0d70e05af` / 3 · `9772e8bdd261` / 0 | same | **same** |
| leave types / public holidays | 13 · `087f68637407` / 26 · `9df7fcb251dc` | same | **same** |
| medical claims / overtime batches / lines / attendance periods | 1 · `49034e3c2478` / 0 / 0 / 0 | same | **same** |
| approval log | 17 · `038da2ec130b` | same | **same** |
| settings row / company profile | `b1ec28c2d2ce` / `b6afa17e8445` | same | **same** |
| document_types | 41 · `0f2a82f796f4` | 41 · `2215acb0b2b1` (the migration's two `link_mode` rows) | **same as before the proof** |
| AP recon | 416,988.32 / 376,404.42, unexplained **0.00**, true | same | **same** |
| AR recon | 57,545.87 / 43,002.12, unexplained **0.00**, true | same | **same** |
| change_log | 4,234 rows, max seq 5,191 | 4,455, max seq 5,416 | **4,455, max seq 5,416** |
| every-row digest (241 public tables, change_log excluded) | `023ae13f5552` | `c668bd88cc87` | **`c668bd88cc87`** |

**The rolled-back proof left nothing:** the after-reading equals the reading just before it, column for column (diff empty).
**After the two later smoke runs (21:15:00):** every column is the same again except `change_log` (4,831 rows, max seq 5,817) and the digest
(`2bd9126fef81`); every one of those 376 new rows is half of a smoke create/delete pair, plus one more `cod_verification_failures` rotation (the
untracked table that moves the digest). 0 `@test.local` accounts, 0 ephemeral plans.
After it: 0 accounts with an `@test.local` address, 0 employees flagged as site staff, 0 ephemeral plans in `.ephemeral/`.

**The move from 18:47 to 19:59 is fully explained** (the migration, the smoke and the probe ran in between):
- **change_log +221.** Every row has `seq > 5191`. Grouped by table and operation: the migration's **2** `document_types` UPDATEs (18:59:09);
  one `cod_verification_failures` rotation (1 DELETE + 1 INSERT, 19:39:55, the smoke's COD check); and the rest are create/delete pairs of the
  smoke and probe throwaway fixtures (72 + 72 `role_permissions`, 15 + 15 `user_roles`, 7 + 7 `employees`, 3 + 3 + 3 `performance_reviews`,
  2 + 2 `contracts` with their term rows, 1 + 1 `roles`).
- **Digest.** `document_types` moved by its two rows. For the four tables without a change-log trigger, I compared live against the 18:46
  backup (sorted `COPY` md5): `festival_doodles`, `home_greetings` and `notification_reads` are identical; `cod_verification_failures` differs —
  the rotation above. Every other table is change-log-tracked and its only new rows are the paired creates and deletes above.

### §7.2 · Proof (`db/scripts/2026-10-04-at1d2-live-proof.sql`, one transaction, ROLLBACK; `PROOF_OWN_EXIT=0`)

- **A** (read-only): *"17 records read, none refused; 2 pre-log leave decision(s) fold with their approval row"*. As admin@: every leave request, the
  medical claim, the leave-type and holiday collections, the claim's expense (it reaches the claim — Q37); every record has its creation; no row shows
  twice. As **each employee** on their own leave requests and claims (`my_*`, M8): readable; for an employee without `module.hr.view` the approval
  rows are not readable.
  - My first run of A stopped on my own assertion. LV-2026-0002 belongs to admin@'s employee record, and admin@ holds `module.hr.view`, so the
    approval row is rightly readable there. I corrected the assertion to the rule as written (Restricted to an employee **without** hr.view); the
    whole run was rolled back.
- **B** (rolled back): *"leave LV-2026-0007 approved, claim MC-2026-0002 changed, overtime OT 2026-09 #1 sent back, a leave type and a holiday changed,
  a ZZ holiday added and deleted, period ATT-2026-09 opened"*:
  - fusheng@ (warehouse) requested a day of unpaid leave and admin@ approved it;
  - fusheng@ submitted a medical claim and admin@ changed its description;
  - sandra (EMP-2026-0004) was temporarily flagged as site staff, admin@ (`overtime_enter`) opened a batch for last month, added two lines and
    submitted it, and fusheng@ (`overtime_approve`) sent it back;
  - the examination leave type's standard days were changed, the last public holiday's note was changed, and a ZZ holiday was added and
    hard-deleted;
  - last month's attendance was opened;
  - the trails were read back as admin@, and as fusheng@ for his own leave, his own claim and the overtime batch (M1).
- **Q19** (in B, as fusheng@): *"/me reads 1 own attendance line(s) and 0 of their period(s)"* (§10).
- **Render** (scratchpad `render-proof-1d2.mjs`, the production renderer over the proof's rows): `RENDER_OWN_EXIT=0` —
  *"records 26 · entries 47 · machine tokens 0"*. Read as admin@:
  - "Leave requested: 1 day of Unpaid Leave" with "[Leave approved]";
  - "Medical claim submitted: 40.00 SGD", then "[Medical claim changed] Description: … → …";
  - "Overtime batch started", then "[Overtime sent back]", "[Overtime line added · Sandra]", and Reason "ZZ proof: Friday hours look doubled";
  - "Leave type changed · Examination Leave · Standard days: 2 → 3";
  - "Public holiday added / deleted · ZZ AT1D2 Day" (the deletion listing its last values) and "[Public holiday changed · Christmas Day]";
  - "Attendance period opened · People: 7".

  Read as fusheng@:
  - the overtime lines' employee reads "Employee: Restricted" (Q20);
  - his own leave reads "[Leave approved]" plus "Part of this change is restricted." (M8 · Q14).
- **Two defects found by the render, both fixed in this cut, each pinned by a golden:**
  1. With a request and its decision in one operation, the approval row folded into the *request* block, so "Leave approved" was said twice
     (and "Overtime sent for approval / sent back" appeared as notes under "Overtime batch started"). Request, submit and start blocks no
     longer carry the record id the approval folds into (`render.ts`, comment above `TIME_TABLES`).
  2. Holiday and leave-type values were listed in stored order ("Date" last). They now follow the page (`FIELD_ORDER`); the two holiday goldens
     were re-pinned.
- **What is still a proof artifact, not a product defect:** because the proof writes everything in one transaction, a submit and a send-back on
  the same batch merge into one status change. That reads as "Overtime sent back" alone, and an entry carries one reason (the request's, not the
  approver's). In the product these are separate operations; arm ⑫ pins each one separately. 1d-1 recorded the same shape (§7.2 there).

### §7.3 · Broken window

| | value | source |
|---|---|---|
| start | **2026-10-04 19:00:10 CST** | `db/migration-windows.tsv` |
| end | Tim's Vercel reading of this commit's deployment | **to be supplied by Tim**, not measured here |

**What was broken inside the window (old app + new database):**
- Nothing that writes. The five functions were replaced in place with the same signatures, `record_trail` is unchanged, and the old app does not
  call the nine new subjects.
- **Visible early, and intended:**
  - the old expense page's trail gains the medical-claim rows (the new member) and words them generically ("Medical claim edited");
  - the summary page's Record column links overtime rows to their batch;
  - global search opens medical claims and attendance periods on their detail pages (both pages already existed).
- Nothing was found to raise an error.

## §8 · New wordings and labels

### §8.1 · Event wordings (English; `lib/trail/text.ts`, 43 new keys)
- **Leave:**
  - `lv.requested` "Leave requested: {days} of {type}" (`lv.days.one` "1 day" / `lv.days.many` "{n} days")
  - `lv.approved` "Leave approved"
  - `lv.rejected` "Leave rejected"
  - `lv.cancelled` "Leave cancelled"
  - `lv.changed` "Leave request changed"
  - `lv.daysTaken` "Days taken from the balance"
  - `lv.daysReturned` "Days returned to the balance"
  - `lv.exception` "Days entered by hand (exception)"
- **Leave grants:**
  - `lgr.carried` "Unused leave carried forward: {days}"
  - `lgr.carriedMany` "Unused leave carried forward · {n} people"
  - `lgr.granted` "Leave granted: {days}"
  - `lgr.changed` "Leave grant changed"
  - `lgr.removed` "Leave grant removed"
  - `listTrail.intro.leaveGrants` "Leave grants for this leave year · newest first · Singapore time"
- **Leave types and public holidays** reuse the dictionary wordings: "{Thing} added / changed / deactivated / reactivated", plus "{Thing} deleted"
  for a hard-deleted holiday. Things: "Leave type", "Public holiday".
- **Medical claims:**
  - `mc.submitted` "Medical claim submitted: {amount}"
  - `mc.approved` "Medical claim approved"
  - `mc.rejected` "Medical claim rejected"
  - `mc.withdrawn` "Medical claim withdrawn"
  - `mc.expenseRaised` "Expense raised to pay the claim"
  - `mc.changed` "Medical claim changed"
- **Overtime:**
  - `ot.started` "Overtime batch started"
  - `ot.submitted` "Overtime sent for approval"
  - `ot.submittedHours` "Overtime sent for approval: {hours} hours"
  - `ot.withdrawn` "Overtime taken back for changes"
  - `ot.approved` "Overtime approved"
  - `ot.sentBack` "Overtime sent back" (Q35)
  - `ot.reversed` "Overtime reversed"
  - `ot.discarded` "Overtime batch discarded"
  - `ot.changed` "Overtime batch changed"
  - `ot.lineAdded` "Overtime line added"
  - `ot.lineRemoved` "Overtime line removed"
  - `ot.lineChanged` "Overtime line changed"
- **Attendance:**
  - `attp.opened` "Attendance period opened"
  - `attp.completed` "Attendance period completed"
  - `attp.reopened` "Attendance period reopened"
  - `attp.frozen` "Attendance figures frozen"
  - `attp.joinersAdded` "New joiners added to the sheet"
  - `attp.recorded` "Attendance recorded"
  - `attp.changed` "Attendance period changed"
  - `attp.people` "People"
  - `attp.latestOnly` "Only the latest completion and reopening of this month were kept before the log began."
- **Reused:**
  - "Approved automatically (approvals were switched off)" (`po.autoApproved`), for an auto-approved leave or claim;
  - "Expense recorded · EXP-…" and "Journal posted · JE-…" on the claim page (`describeFinance`);
  - on the expense page, "Medical claim submitted / approved … · MC-…".

No new `messages/en.ts` / `zh.ts` keys.

### §8.2 · Field labels on the tables 1d-2 first shows (`scripts/gen-trail-catalogue.mjs` OVERRIDES)
- **leave_requests:**
  - Leave request number · Employee · Leave type
  - Start · End · Half day on the first day · Half day on the last day · Days
  - Reason · Medical certificate · Status
  - Decided on · Decided by · Decision notes
  - Deleted on · Days entered by hand (exception) · Reason for the exception
- **leave_consumption:** Leave request · Leave grant · Entry · Days · Notes · Accrual year
- **leave_grants:** Employee · Leave type · Leave year · Days · Granted on · Lapses on · Source · Carried forward from · Notes · Deleted on
- **leave_types:**
  - Name (English) · Name (Chinese) · Description (English) · Description (Chinese)
  - Paid · Accrues · Standard days · Certificate after (days)
  - Needs approval · Half days · Only for · Active · Notes
- **public_holidays:** Date · Name (English) · Name (Chinese) · Country · Active · Notes · Holiday in lieu (of a Sunday). `holiday_key` is hidden.
- **medical_claims:**
  - Claim number · Employee · Date · Amount (in the base currency) · Description · Receipt reference
  - Status · Decided on · Decided by · Decision notes · Expense · Deleted on · Withdrawn on
  - `claim_year` is hidden.
- **overtime_batches:**
  - Batch · Month · Status
  - Submitted on · Submitted by · Decided on · Decided by · Approver's note
  - Reversed on · Reversed by · Reason for reversing · Discarded on · Discarded by
  - `seq` is hidden.
- **overtime_lines:** Batch · Employee · Date · Hours · Day · Note · Voided on
- **attendance_periods:**
  - Sheet · Month · Status
  - Opened on · Opened by · Completed on · Completed by
  - Reopened on · Reopened by · Reason for reopening
- **attendance_lines:**
  - Attendance period · Employee
  - OT normal (hours) · OT rest day (hours) · OT public holiday (hours)
  - Note · Recorded on · Recorded by · Unpaid days · Employed from · Employed to · Frozen on
- **Table names (in sentences):** leave balance entry · leave grant · leave type · medical claim · overtime batch · overtime line · attendance period ·
  attendance line

### §8.3 · English for enumerated values (Q34)
- **Medical claim status:** Waiting for approval · Approved · Rejected · Paid · Withdrawn.
- **Leave grant source:** Entitlement · Carried forward · Adjustment · Pro-rated.
- **Leave type "Only for":** Women · Men.
- **Already had English** (from the pages' own option labels, unchanged):
  - leave status;
  - leave entry (Drawn · Released);
  - overtime status (… "Sent back");
  - overtime day kind;
  - attendance status.
- **Years** (`leave_year`, `accrual_year`) now print as "2027", not "2,027" (`formatValue`, any integer column named `*_year`).

## §9 · Decisions taken without asking

1. **`overtime_batch` was not added to `document_types` (Q36's third part).** Overtime batches have no `code` column, and global search builds
   `SELECT code` for every registered table (the 1c-2 sales precedent, written in `trail_ref_label`'s header), so a row would have broken
   search. The batch's label and link come from `trail_ref_label` / `trail_row_record` instead (doc key `overtime_batch`, route `/hr/overtime`),
   which is what Q36 was for: references and the summary page's Record column link to the batch. The other two rows were changed as ruled.
2. **Leave types and public holidays are M11 collections, one block per page**, worded by the dictionary family. The holiday block covers all
   years, not the page's year filter, because a hard-deleted holiday has no year left to filter on.
3. **Leave grants are a list block over the selected leave year** (`ListTrail`, up to 200 grants, each labelled by employee code and year — the
   page reads `employees_masked` for codes only). A carry-forward run merges into one entry by its operation (Q16).
4. **The leave decision stamp is read by the request's current status (Q12).** Before the log, a cancellation's `decision_notes` is today's value,
   which may still be the approver's note, so it is shown under its field label ("Decision notes: …") rather than as the cancellation's reason.
5. **"Leave cancelled" does not say "by the employee".** The Who column already names the person; telling self from HR by name comparison would
   be a guess. Days returned are a line.
6. **Approval rows of leave requests, medical claims and overtime batches are worded in their page's words** ("Leave approved", "Overtime sent
   back") everywhere, including `/settings/change-history`, which names the document ("· LV-…", "· OT 2026-10 #1").
7. **Overtime side effects are silent:** the `day_kind` restamp on submit and approve, and the voiding of every line on reverse and discard.
   Attendance completion's mass updates are one sentence with a "People: N" line.
8. **The two pre-log "latest only" stamps share one sentence**, "Only the latest completion and reopening of this month were kept before the log
   began.", shown on both pre-log completion and pre-log reopen entries.
9. **On the claim page, the expense's system note is not shown as a reason** (`pay_medical_claim` writes "Medical claim MC-… (EMP-…)"). On the
   expense page it stays as 1c-1 shows it. Registered with the Q10 writers.
10. **Medical claim amounts are in the base currency.** The column is `amount_sgd`, and the page takes the currency from a message parameter;
    no currency literal was added.
11. **Years print without a thousands separator.** This is a shared renderer change for every integer column named `*_year`; no earlier
    golden moved.
12. **The `/me` trails sit in a list under each panel's table**, the expense-claims precedent: code, then a collapsed trail. They are not inside
    the table rows.
13. **The Q38 side findings on the pages I touched were not fixed** (the uuid fragment in the leave consumption table; the claim page's link to
    the expense list). Tim's ruling was "fix only the two stale comments"; the known-issues entry now says so.
14. **Arm ⑫'s goldens were generated by the renderer, read one by one, and pinned.** Three readings were wrong and were fixed before pinning: the
    year separator, a post-log reopen without `reopened_at` in the image, and the expense's system note shown as a reason on the claim page.
15. **The Q19 probe is a database-level reading as fusheng@'s identity**, not a page load. A throwaway account cannot have an employee record
    without writing a link onto a real employee, and the probe must not do that. The rolled-back proof gave the concrete reading (1 own line,
    0 periods).
16. **The proof's first-run assertion about `/me` was wrong** (§7.2) and was corrected to the rule as written; the product was not changed.
17. **The migration's proof allows exactly the two `document_types` change-log rows.** The first dry run refused on them; nothing was committed.
18. **The build's first run failed on Google Fonts (network)** and was retried once immediately, green. I have no measurement of the outage
    beyond that one failed fetch and the HTTP 200 seconds later.
19. **The smoke was rerun after the last renderer change** (the render layer changed). Its first rerun hit an API outage and could not clean
    up; I reaped its plan, read live back, and retried once — green. I did not investigate the outage (no measurement beyond the failures and
    the later 2.0 s response).
20. **The fixture builds a local scratch rebuild for iterating** (`/tmp/pg245`, port 55445), outside the gate. The gate's own rebuild ran 245 as
    well (offline and full).

## §10 · Known issues and queue

- `docs/known-issues.md`:
  - `AT1D1-ME-READS-HR-ONLY-PERIOD-TABLES` (**Q19 measured**): as fusheng@ today, 0 own lines and 0 of 1 payroll periods visible. In the rolled-back
    proof, 1 own attendance line and 0 of its period, so `/me` would print "—" for the code and month. Not fixed here (the brief).
  - `AT1D1-MACHINE-TEXT-IN-HUMAN-COLUMNS`: the overtime suffix is now recognised; `pay_medical_claim`'s expense note is added as the same family.
  - `AT1D1-OVERTIME-APPROVER-NAMES-PAGE-VS-TRAIL` (Q20): built, measured in fixture 245 O and in the proof. The difference stays registered.
  - `AT1D1-STEP0-SIDE-FINDINGS`: the leave-page uuid fragment and the claim page's list link are not changed (Q38); `document_types` is done (Q36).
- `docs/forward-queue.md`:
  - item 30 records 1d-1's window;
  - AT-1d-2 is marked ✅, with this cut's window start (19:00:10 CST) to be closed at the next close-out;
  - AT-1d-3 stays pending.
- `docs/change-log.md` §9: the intro, nine table rows and the expense row, M11's users, and the new §9.15.

**Not done here, by the brief:** 1d-3 (payroll, reviews, review cycles, rating scale, KPI), DATE-PICK-1, any fix for Q19.
