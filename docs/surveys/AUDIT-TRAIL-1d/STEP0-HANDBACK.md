# AUDIT-TRAIL-1d · Step 0 hand-back (stop gate)

Part of v1.4.33, not yet released.

**Opening check passed** at **2026-10-04 10:50:20 CST** (this session's first command): tree clean; `HEAD` = `origin/main` =
`ls-remote` = `6104635bffb712006a8353f5ea2a20a541b3a5db`. Step 1 then committed one docs change (`0644806a`, "AT-1c-3 close-out: window
closed"). Step 0 itself made no code edit, no migration and no database write.

**How it was measured.** Four read-only survey agents; their notes are kept next to this file:
- `A-hr-records.md` — employees, departments, training, leave, holidays, medical claims, overtime, attendance, payroll, reviews, KPI;
- `B-masking-and-me.md` — masked columns, own-row rules, what `/me` reads, the ActorName rule, account emails in the log;
- `C-settings-accounts.md` — the per-account trail (Q24), the approval-policy panel (Q25), dictionaries, import, role grants, Q21 for settings;
- `D-wording-labels-timing.md` — event wordings, field labels, enum values, and the measured run times of AT-1a … 1c-3.

Every live figure was read as **`postgres` (`rolbypassrls = true`) on base tables**, SELECT only, through the Management API. Survey C's
`record_trail` readings "as admin" set admin@'s claim transaction-locally inside one SELECT and wrote nothing. Each claim in the notes is
marked Measured (query or file:line) or Inferred. I re-read the load-bearing ones myself (§2 lists which).

---

## 1. Step 1 — the 1c-3 close-out, item by item

**The broken window** is recorded in `docs/forward-queue.md` item 29 (the 1c-2 format), committed and pushed as `0644806a`:

| | value | source |
|---|---|---|
| start | **2026-10-04 08:39:15 CST** | `db/migration-windows.tsv` (last row, `2026-10-04-at1c3-trails-period-end-settings-and-lists.sql`) |
| end, lower bound | **2026-10-04 10:43:28 CST** | `git reflog show --date=iso refs/remotes/origin/main`: `6104635b … {2026-10-04 10:43:28 +0800}: update by push` |
| end, upper bound | **2026-10-04 10:50:20 CST** | this session's first command (`date` printed it). It rests on your "deployed", **not** on a Vercel reading |
| window | **at least 2 h 04 min 13 s, at most 2 h 11 min 05 s** | |

**Your processing-costs ruling** is recorded in `docs/handbacks/AUDIT-TRAIL-1c-3.md` under §10 decision 11 (the decision it answers) and
in §11's last paragraph: the page keeps its "Restricted" notice; `processing_cost_entry_lookup` is not widened.

**The 1c-2 close-out results (1c-3 hand-back §1, items a–i), with their evidence lines:**

| | item | verdict | evidence (as the 1c-3 hand-back records it) |
|---|---|---|---|
| a | the eight 1c-2 subjects; Q10 | ✅ | `trail_subjects.sql:131-138` one row each for sale, freight, fixed_asset, bank_statement, gst_period, fx_rate, management_pack, contract, beside `:93 equipment` (two subjects on `fixed_assets`); every host page draws it (`receivables/[saleId]/page.tsx:319` … `contracts/[id]/page.tsx:232`); `grep -rn HistoryPanel app lib messages` → 0 |
| b | Q6: deleted statements read-only for `data.view_deleted`; `/settings/deleted` lists BS-2026-0001 with label and link | ✅ | `bank/statements/[id]/page.tsx:64-67,210,391-393`; `deleted_records.sql:202-216`; `settings/deleted/page.tsx:95,152`; `messages/en.ts:7078`; probe log `at1c2-probe2.log:8,11` |
| c | Q7: withdrawn FX rates read-only for normal readers, with who and reason | ✅ | `fx/[id]/edit/page.tsx:24,39-46,50-51,66,68-73`; `text.ts:552-553`; `at1c2-fixture-inj.log:21` |
| d | Q21: contract approvals Restricted without pricing view | ✅ | `approval_log.sql:275`; `trail_subject_members.sql:356-357`; fixture 242 arm C `:401-406` |
| e | Q22, Q23 | ✅ | `trail_subject_members.sql:340-342` (three members, no `corrects_period_id`); `render.ts:3227,3242-3250`; generator `:446` hides `label_zh` |
| f | field-edit arms and goldens for payment requests and credit notes | ✅ (credit notes: the arm is the immutability — `credit_notes.sql:51-53` refuses every update) | fixture 242 arms P `:440-450`, `:422-431`; golden ⑨; `X_OWN_EXIT=0`, injection `X_OWN_EXIT=1` |
| g | the Chinese / English identical-output check | ✅ | `probe-at1c2.mjs:205-229` (`zt === et`, `:227`); `at1c2-probe2.log` 33 fold-in-3 ✓; injection `cjk` → 33 ✗, `AT1C2_PROBE_EXIT=1` |
| h | change-log §9 covers 1c-2; the queue marks 1c-2 complete | ✅ | `change-log.md:273-280`, §9.12; `forward-queue.md:6590` |
| i | 1c-2's self-taken decisions | ✅ listed (19) | `AUDIT-TRAIL-1c-2.md` §10 |

**Read-only checks the 1c-3 report did not mention** (all re-read this session):

**a — the subjects 1c-3 covered.** ✅ `db/functions/trail_subjects.sql:163-175`: `finance_lock` (`root_columns ARRAY['locked_before']`),
`finance_gst`, `company_profile`, `year_close`, `journal_request`, `expense_claim`, `my_expense_claim` (`ARRAY[]::text[]`, M8),
`bank_transfer`, `wht_remittance`, `cash_forecast`, `cash_forecast_line`, `bank_import_profile` — twelve. M7 member:
`trail_subject_members.sql:366 ('finance_lock', 1, 'period_closes', 'finance_settings', NULL, '{}'::jsonb, 'all', true, true)`.

**b — each settings panel only its own fields; the lock trail includes month close and reopen (fixture on the rebuilt copy).** ✅
- Pages: `app/finance/settings/page.tsx:149` `<AuditTrail subject="finance_lock" id="true" … anchor="lock-trail" />`, `:157` `subject="finance_gst" … anchor="gst-trail"`.
- Fixture 243 (`db/fixtures/243-…sql`), run on the local rebuild by the gate: arm G `:157-167` — the GST trail carries the number edit and
  both switches, and `IF NOT v_cols <@ ARRAY['gst_registered','gst_registration_no'] THEN RAISE … 'FIXTURE 243 G (M6): the GST panel''s trail
  shows columns it does not own'`, plus "a month close reached the GST panel" raises. Arm L `:170-206` — `close_period(m_end, …)` then
  `reopen_period(m_end, …)`; `f243_need('L (key event: month closed — the close row)' … 'period_closes', 'INSERT' …)`, `'L (key event: month
  reopened — the stamp)' … 'period_closes', 'UPDATE', 'reopened_at'`, the pre-log close, `v_cols <@ ARRAY['locked_before']`, one `op_key`
  for the close and its lock move, nothing twice; then G re-read after L (`:199-202`).
- Its run: `/tmp/claude-501/at1c3-fx243.log` → `NOTICE: FIXTURE 243 全部通过:G(M6)· L(M6 · M7 · Q4 · Q25 · Q29)· …` and `F243_OWN_EXIT=0`;
  in the full gate `/tmp/claude-501/at1c3-gate2.log:222` `fixture 243-… ✓`, `:314 GATE_EXIT=0`. No file under `db/` changed since.

**c — the year-close list block on `/finance/close`.** ✅ `app/finance/close/page.tsx:340-342`
`<ListTrail anchor="year-close-trail" intro="listTrail.intro.yearCloses" … records={yearCloses.map((c) => ({ subject: 'year_close' …,
label: \`Year ending ${formatDate(c.year_end, 'en')}${c.reopened_at ? ' (reopened)' : ''}\` }))} />`; the lock trail under close history at `:293`.

**d — every finance list home named in the 1c-3 brief carries its block.** ✅ (`grep -rn "<AuditTrail\|<ListTrail"`)

| route | file:line | block |
|---|---|---|
| `/finance/settings` | `app/finance/settings/page.tsx:149,157` | lock · GST |
| `/finance/close` | `app/finance/close/page.tsx:293,340` | lock · year closes |
| `/finance/company` | `app/finance/company/page.tsx:101` | company profile |
| `/finance/revaluation` | `app/finance/revaluation/page.tsx:126` | revaluation journals |
| `/finance/assets` | `app/finance/assets/page.tsx:255` | depreciation journals |
| `/finance/fx` | `app/finance/fx/page.tsx:347` | rates + withdrawn |
| `/finance/cash-forecast` | `app/finance/cash-forecast/page.tsx:85` | forecasts + recurring lines |
| `/finance/payroll-payments` | `app/finance/payroll-payments/page.tsx:56` | payroll journals |
| `/finance/processing-costs` | `app/finance/processing-costs/page.tsx:74` | remittance journals + relief expenses (`refused={!canSeeEntries}`) |
| `/finance/wht` | `app/finance/wht/page.tsx:237` | remittances |
| `/finance/bank` | `app/finance/bank/page.tsx:266` | transfers |
| `/finance/bank/import` | `app/finance/bank/import/page.tsx:61` | import mappings |
| `/finance/bank/statements` | `app/finance/bank/statements/page.tsx:205` | deleted statements |

**e — claims.** ✅ `app/finance/claims/page.tsx:74-76` passes `trails={…<AuditTrail subject="expense_claim" id={r.claim_id} … compact />}` to
`ClaimDecisionPanel`, which draws one per pending card (`ClaimDecisionPanel.tsx:190`) and per decided-register row (`:221`). The claimant:
`app/me/page.tsx:471` `<AuditTrail … subject="my_expense_claim" id={r.claim_id} … compact />`.

**f — journal requests, a trail per row.** ✅ `app/finance/journal/page.tsx:197-199` (`subject="journal_request"`, `anchor={\`jr-trail-${r.id}\`}`,
`compact`) → `JournalRequestsPanel.tsx:199` (open cards) and `:224` (decided lines). New-entry and reversal requests both.

**g — Q16: list blocks merge one operation across records.** ✅ `ListTrail.tsx:29,100` (`mergeByOperation(dict, merged)`), `render.ts:3839-3842`
(`const k = row.opKey ?? …`); fixture 243 arm F `:387-390` (freeze + supersede one `op_key`, before the log `:413-415`) and arm X `:455-466`
(one bulk save, one `op_key`); wording check arm ⑩ golden "Exchange rates recorded · 3 rates" (`check-trail-wording.mjs:2102,2174`) and
"[Cash forecast replaced · FCST-2026-0001]" (`:2048`).

**h — the Chinese / English identical-output check includes 1c-3 subjects.** ✅ `scripts/probe-at1c3.mjs:162` (`NEXT_LOCALE=${locale}`),
`:223` (`if (INJECT === 'cjk') zt += ' 受限'`), `:226` (`zt === et`). Rerun log `/tmp/claude-501/at1c3-probe2.log:15-41`: fold-in 3 ✓ on all
fourteen 1c-3 pages, plus four controls (`:43-49`); `:52` `42 passed · 0 failed · 1 skipped`, `:53` `AT1C3_PROBE_EXIT=0`.
*One note:* the hand-back §7.3 quotes the **first** probe's character counts (`/finance/settings` 478, `/finance/close` 481, revaluation 928);
the rerun after the four fixes reads 494 / 497 / 948 — the base currency now printed on the close totals. Both runs matched zh = en.

**i — docs.** ✅ `docs/known-issues.md:9997` `AT1C3-LIVE-MONTH-CLOSE-BLOCKED-BY-UNALLOCATED-RUNS` (8 committed runs with no allocation) and
`:10005` `GATE-TYPES-CLI-HAS-NO-TIMEOUT` (the stalled gate); also `:9985` `AT1C3-LIST-BLOCKS-READ-A-BOUNDED-WINDOW`. `docs/change-log.md` §9
intro (1c-3 paragraph), the table rows for the 1c-3 subjects, §9.9 M8, §9.13. `docs/forward-queue.md:6605` `✅ AT-1c … 三刀都做完了(1c-3,2026-10-04)`
and `:6623` `✅ AT-1c-3(2026-10-04)`.

**j — the decisions 1c-3 took without asking** (`docs/handbacks/AUDIT-TRAIL-1c-3.md` §10, titles only):
1. M8, a subject with no page code.
2. Two subjects on one claim, not one.
3. A journal request and its approval now home on the request.
4. The lock-move wording keeps §4's title and the page's label.
5. Year-close wording follows the month's.
6. Batch journals say what they are, on journal pages and list blocks only.
7. A depreciation run's per-asset charges are members of its journal.
8. Bulk FX reads as one sentence when one operation inserted several rates.
9. The withdrawn-rate entry point.
10. Deleted statements are a block on the statements list.
11. The processing-cost block reads the entries through `processing_cost_entries_masked` (→ your ruling, recorded).
12. List blocks read a bounded window.
13. Per-row trails are collapsed.
14. Q8 as state markers.
15. Two corrections in the shared renderer.
16. `finance_settings` labels, all sixteen, are fixed in 1c-3.
17. `company_profile.logo_path` is hidden.
18. Record-type names.
19. The payroll block lists every `payroll` journal.
20. Journal-request trails on both kinds.
21. The live proof does not close or reopen a month, nor close a year.
22. The proof's claimant is fusheng@.
23. `/me` is not probed at page level.
24. Fixture 243 writes two prerequisites directly as `postgres`.
25. Two blind assertions in fixture 243 were found by its own injections and fixed.
26. The wording check's registry parser now reads M7 and M8 rows.
27. The migration's own read check accepts an empty GST and company-profile trail.
28. The proof takes the foreign currency from `currencies`.
29. Four rendering defects found by the rolled-back proof were fixed in this cut.
30. The full gate was rerun once, immediately.
31. The gate was not rerun after the late fixes.

**Nothing in a–i was missing or partial, so step 2 went ahead.**

**Live-state assertions in the brief:** approvals ON (finance / cfo / 1,000) and 7 accounts — survey C read `auth.users` as postgres:
**7 accounts, `banned_until` NULL on all 7, `deleted_at` NULL on all 7** (all enabled). Approvals: `finance_settings_history` and the 1c-3
after-reading say ON; not re-read beyond that. "238 tables recorded" — survey A: every HR table carries the change-log trigger
(`pg_trigger` `tgname ilike '%change_log%'`, 32 / 32).

---

## 2. What grilling changed in this scope

1. **HR trails launch almost entirely before the log.** Every row of every HR table predates 28/09/2026 23:58 except one `leave_consumption`
   row. `change_log` holds 230 `employees` rows and 144 `performance_reviews` rows, **all the smoke script's temporary rows**; the real HR
   events in the log are **5 rows** (two leave decisions on 29/09). Live data is tiny: 6 real employees, 6 leave requests, 1 medical claim,
   1 payroll period with 1 line, 30 KPI entries; **0** reviews, overtime batches, attendance periods, salary change requests, leave grants,
   review cycles. (A §0.3–0.4.) So `trail_prelog_sources` is again what anyone will see at launch.
2. **The per-account trail (Q24) cannot be built on the current mechanism.** `auth.users` is outside `public`: `trail_current_image`
   returns NULL (`trail_current_image.sql:16,22` — `public.%I` only), `trail_row_visible` looks only at `nspname = 'public'`
   (`trail_row_visible.sql:29-30`), member discovery is `FROM public.%I` (`record_trail.sql:125,149`). → **M9** (Q2). And there are
   **0 account events** in the log today (C §A1): all 9 grants, 2 revokes and the one additional-account link predate it.
3. **The approval-policy panel needs no new mechanism.** `set_approvals_policy` writes exactly the four columns plus
   `finance_settings_history` in one transaction (`set_approvals_policy.sql:64-87`); M7 is ready; `finance_settings_history` is read only by
   `ApprovalsHistory` (`app/settings/approvals/page.tsx:79`).
4. **Three writers make one user action into two or three transactions**, so the operation key cannot fold them: hire / edit an employee
   (`employees` then `employment_history` then the account link — `app/hr/employees/actions.ts:239,251`, measured 0.5–0.9 s apart on live)
   and create an account (event, link, roles). (Q8, Q9.)
5. **Writers erase the stamps a pre-log trail would read.** Leave cancel overwrites `decided_at / decided_by / decision_notes`
   (`cancel_leave_request.sql:47-48`); overtime withdraw / discard clear `submitted_*` / `decided_*`; attendance reopen clears completion and
   keeps only the latest reopen; a medical-claim withdrawal records no withdrawer. Before the log only the last state survives. (Q12.)
6. **`/me` under M8 has real hazards.** M8 judges the root row on its *current* image: once a review is approved the subject could read
   every earlier reviewer draft edit and the HR-only `notes`; KPI scores in an open cycle would show although `/me` hides them until
   close; `employees.notes` / `separation_notes` are HR-internal on screen but self-readable by policy; payslips are deleted and re-inserted
   on every save, so a line's trail starts at the last import; overtime lines have no own-row policy at all. (B §4; Q14.)
7. **`/my-reviews/[id]` needs its own subject**, and M8 alone would let the reviewed employee in after approval. (Q5.)
8. **Records that lose their page:** deleted employees, departments, training records and roles 404 and are not in `deleted_records`
   (`app/hr/employees/[id]/page.tsx:44`, `departments/[id]/edit/page.tsx:31`, `training/[id]/edit/page.tsx:30`,
   `settings/roles/[id]/page.tsx:32,42`). AT-0's "department delete → `/settings/deleted`" is false. Every HR record ended by a business
   event (cancelled leave, withdrawn claim, reversed overtime, void review, unposted payroll) already opens. (Q25, Q26.)
9. **Hard deletes in settings collections:** public holidays are hard-deleted (`leave/types/actions.ts:59`), so a per-row list block cannot
   enumerate them; leave types, the rating scale and the 6 dictionaries are keyed by `code text`, a path no subject has exercised. → one
   collection extension covers all nine (Q4).
10. **The global summary reader ignores row rules.** `change_log_rows` calls only `change_log_mask_row` (0 hits for `trail_row_visible`
    in `change_log_rows.sql`), and `salary_change_requests`' salary columns have **no** mask rule (0 hits in `change_log_mask_rules.sql`).
    No live holder is affected (admin and cfo hold `view_pay` and `view_reviews`), so it is latent. (Q13.)
11. **The role page misses grants.** The `role` subject has one member, `role_permissions` (`trail_subject_members.sql:46`); `user_roles` is
    not on any trail, so phua@'s cto grant is absent as admin. (Q22.)
12. **Size.** About **30 subjects** (6 of them dictionaries), **384** shown columns with **0** hand overrides, **24 + 9** enum gaps, **110–160**
    new wordings, 4 new mechanism pieces. → Q1.

**Assertions I measured as false or out of date**
- AT-0 `ops-people-settings.md` S5: "`set_role_permissions` delete-all + reinsert" — **stale**, it changes only what changed
  (`set_role_permissions.sql:62-67`).
- AT-0 §2: `employee_account_history` "3 rows" — **1**.
- AT-0 E9: department delete reaches `/settings/deleted` — **false** (`deleted_records` has no HR branch).
- AT-0 §4: imported records can say "created by import batch X" — **contradicted** by the `import_batches` table comment, which forbids
  any lineage link (C §D). → Q24.
- AT-0 §5 salary gap — **still open** at column level; covered on page trails by the row rule only.
- `app/settings/accounts/page.tsx:31-34` comment "admin no longer holds module.hr.view" — **false live** (admin holds it).
- Survey A's "auditor" and "hr" roles hold the hr codes but have **0 holders** live (B §5) — so "who is affected" counts are by account.
- Measured true: `deleteEmployee` still has no caller; `anonymise_employee` still has no UI; `lib/modules.ts:845-849` approvals comment
  is fixed; 7 accounts all enabled.

**Re-read by me** (beyond the agents): items 2, 4, 5 (`cancel_leave_request.sql:47-48`), 8 (all five filters), 10 (both greps), 11, and
the `finance_settings_history` readers.

---

## a. Registry: every subject (root · members · host · extensions)

View code is `module.hr.view` (`requireModule(MOD.hr)`, `lib/modules.ts:142`) unless stated. Full member tables, keys and pre-log sources
are in A §1–13 and C §A–F.

**HR records**

| subject | host route · file | root (rule) | members | needs |
|---|---|---|---|---|
| `employee` | `/hr/employees/[id]` · `app/hr/employees/[id]/page.tsx` (guard `:32`) | employees (`table`: hr.view OR own) | employment_history · salary_change_requests (rule hr.view AND view_pay → Restricted to cto, gm) → approval_log {salary_change_request} · training_records (home `training_record`) · employee_accounts · employee_account_history (manage_permissions only → Restricted) · the account mirror (Q21) | M9 for the mirror · Q8 · Q10 · Q28 |
| `department` | `/hr/departments/[id]/edit` (its only page, `:19`) | departments | — | Q26 |
| `training_record` | `/hr/training/[id]/edit` (its only page, `:18`) | training_records (hr.view OR own) | — | Q26 · Q29 |
| `leave_request` | `/hr/leave/[id]` · `app/hr/leave/[id]/page.tsx` (`:28`) | leave_requests | leave_consumption · approval_log {leave_request} | status-aware wording (cancel reuses the decision stamps) · Q12 |
| `leave_grant` (list block) | `/hr/leave/grants` | leave_grants | — | ListTrail + op_key ("carried forward · N people"); 0 live |
| `leave_types` · `public_holidays` · `review_rating_scale` (collections) | `/hr/leave/types`, `/hr/leave/holidays`, `/hr/reviews/scale` | the table (`code` / `id` / `code`) | — | **M11** (Q4) |
| `medical_claim` | `/hr/claims/[id]` (`:29`) | medical_claims | approval_log {medical_claim} · the expense (up) · its journal (up) · payment allocations · the expense's reversal and its journal (up) — finance rows Restricted to an hr-only reader | M4 · Q37 |
| `overtime_batch` | `/hr/overtime/[id]` | overtime_batches | overtime_lines (hard-deleted lines found from the DELETE image) · approval_log {overtime_batch} | **M1** (`hr.view` / `overtime_enter` / `overtime_approve`, `lib/modules.ts:945-946`) · Q20 · Q35 |
| `attendance_period` | `/hr/attendance/[id]` (`:17`) | attendance_periods | attendance_lines (completion's mass updates folded into one sentence) | — ; 0 live |
| `payroll_period` | `/hr/payroll/[id]` (`:32`) | payroll_periods | payroll_lines (delete + reinsert — Q11) · payroll_requests → approval_log {payroll_request} · journals by **`source_id`** + `{"source_type":"payroll"}` (not an up hop on `journal_entry_id`, which unpost sets to NULL — `unpost_payroll_period_internal.sql:50-54`) · their reversals (up, `reversed_by`) | M4 · Q10 · Q11 |
| `performance_review` | `/hr/reviews/[id]` (`:27`) | performance_reviews (`table`: hr.view AND view_reviews, or reviewer, or own once approved) | review_goals (hard-deleted goals from the DELETE image) · approval_log {performance_review} | Q7 · Q10 |
| `my_review` | `/my-reviews/[id]` (guard: reviewer-of, `my-reviews/[id]/page.tsx:38,40`) | performance_reviews | the same | **M12** (Q5) |
| `review_cycle` (list block) | `/hr/reviews/cycles` | review_cycles | — | Q6 |
| `kpi_entry` (list block, scores branch only) | `/hr/kpi/score` (`canSeeScores`, `score/page.tsx:72,232`) | kpi_entries (hr.view AND view_reviews, or own) | — | ListTrail + op_key ("KPI entries generated · N") |
| `my_leave_request` · `my_medical_claim` | `/me` (one per own request, compact) | leave_requests / medical_claims, no page code | as the HR subjects; approval rows and finance rows Restricted | M8 · Q14 · Q15 |

Not subjects (no UI writer): `kpi_position_templates`, `kpi_cycles`, `kpi_organisation`, `kpi_score_rubric`, `positions`, `leave_accrual_rates`
(A §13).

**Settings and accounts**

| subject | host | root (rule) | members | needs |
|---|---|---|---|---|
| `account` | `/settings/accounts`, one compact trail per `UserRow` (guard `requireManagePermissions()`, `page.tsx:15`) | `auth.users` — log-only, safe projection `id, email, created_at, banned_until`, declared rule `action.manage_permissions` | user_roles (`user_id`, no FK; home) · employee_accounts · employee_account_history · employees by `user_id` limited to the `user_id` column | **M9** · **M10** (Q3) · Q9 · Q22 |
| `employee_account` (the mirror) | `/hr/employees/[id]`, a second section or rows on the employee trail | employees | employee_accounts · employee_account_history · auth.users (up, M9) · user_roles below it | M9 · Q21 |
| `role` (AT-1a, extended) | `/settings/roles/[id]` | roles | + `user_roles` (`role_id`, down; not home) | Q22 · Q25 |
| `approval_policy` | `/settings/approvals`, replacing `ApprovalsHistory` (`page.tsx:129`) | finance_settings `'true'` (M5), `root_columns` the four approval columns (M6) | finance_settings_history, the whole table (`hop = 'all'`, M7) | M5 · M6 · M7 · Q23 |
| dictionaries ×6 (collections) | `/settings/dictionaries`, one block per section | the table (`code text`) | — | **M11** (Q4) |
| `import_batch` (list block) | `/settings/import` | import_batches | — | Q24 |

---

## b. Mechanism extensions beyond M1–M8

| | what | why (measured cause) | where |
|---|---|---|---|
| **M9** | **a log-only root outside `public`**: `auth.users` as a root or an up-hop target, with a fixed safe projection as its image (`id, email, created_at, banned_until` — never `to_jsonb` of the auth row, which carries `encrypted_password` and six token columns) and a declared read rule (`action.manage_permissions`) instead of the table's policies | Q24 per-account trail; `trail_current_image.sql:16,22`, `trail_row_visible.sql:29-30`, `record_trail.sql:125,149` are public-only | `trail_current_image`, `trail_row_visible`, `record_trail`, `trail_row_record`, `change_log_rows` (Record column) |
| **M10** | **M6 for members**: a member limited to declared columns (rows that change none of them are dropped) | the account trail must show `employees.user_id` link changes without every HR edit of that employee (C §A3) | `trail_subject_members` (+ column list), `record_trail` |
| **M11** | **a collection subject**: no root row; every row and every log row of one table belongs (M7's `hop = 'all'`, without a singleton parent) | hard-deleted holidays cannot be listed per row; `code`-keyed leave types, rating scale and 6 dictionaries would otherwise each need the untested text-key path | `trail_subjects` (root key NULL), `record_trail` discovery, `trail_row_record` home |
| **M12** | **a subject-specific gate narrower than the table's read rule** (here: the reviewer only) | `/my-reviews/[id]` — M8 alone admits the reviewed employee once approved (`performance_reviews` "select own approved" policy) | `trail_subjects` (+ gate function name), `record_trail` layer 2 |
| renderer | machine-text recognition (Q10), natural-key pairing of a replaced set (Q11), status-aware wording for cancel / withdraw / discard / reopen, one entry for the attendance completion's mass updates | A §4, §8–10; D §2 | `lib/trail/render.ts` (code only) |
| writer | one RPC for the employee save (Q8) | A §0.11 | new `save_employee` function |

**Not needed:** M2 (every HR actor column holds an account id — A §0.6); a same-transaction "co-display" (A's X6 — Q7); an inserts-only
member (A's X3 — Q6).

---

## c. HR masking, own rows, and `/me` versus HR

**Columns masked today** (B §1a; rule = `code_or_self:<code>:<employee column>`, the employee always sees their own):

| table | columns | code |
|---|---|---|
| employees | work_email, work_phone, identity_no, work_pass_no | `data.view_identity` |
| employees | monthly_salary | `data.view_pay` |
| employment_history | old / new monthly salary | `data.view_pay` |
| payroll_lines | gross, employer CPF, employee CPF, other deductions, net | `data.view_pay` |
| performance_reviews | new_monthly_salary | `data.view_pay` |

**Gated by row rule, not column** (page trails Restrict the whole row): `salary_change_requests` (hr.view AND view_pay), reviews and goals
(hr.view AND view_reviews, reviewer, or own once approved), `kpi_entries` (hr.view AND view_reviews, or own), `payroll_lines`
(hr.view, finance.view AND view_pay, or own), `employee_account_history` (manage_permissions).

**Banking:** no HR table holds an employee bank account, date of birth, home address or emergency contact (B §2, column regex over every
public column). **Identity:** the four columns above; names, residency, work-pass type and dates are unmasked (as on screen).

**No HR column is hidden on screen behind `can()` while visible in `record_trail`** (B §1d). The mismatches are the global reader (Q13) and
`/me` screens that are narrower than the self policies (Q14, Q16, Q17).

**Who holds what** (live accounts, `user_roles.revoked_at IS NULL`): every account but warehouse holds `module.hr.view`; `data.view_pay` —
admin, cco, cfo, finance (not cto, gm); `data.view_reviews` — admin, cco, cfo, cto, gm (not finance); `data.view_identity` — admin, cfo,
finance; `action.manage_permissions` — admin only; `action.overtime_approve` — admin, warehouse.

**`/me` versus HR:** HR sees every member, name, salary request and review draft their codes allow. The employee reads their own rows
through the own-row policies (B §3) but `/me` deliberately shows less: no `notes`, no salary, KPI scores only once the cycle closes,
reviews only once approved. A trail on `/me` judged by those policies would show **more** than the page → Q14 limits `/me` trails to the
two request kinds where the policy and the page agree.

---

## d. The per-account trail (Q24)

| what | recorded where | live (as postgres) |
|---|---|---|
| account created / deleted-on-rollback / disabled / enabled / `_FAILED` | `change_log`, `table_name = 'auth.users'`, `row_key {"id": …}`, op = the event, `new = {email, …}` (`record_account_event`) | **0 rows** |
| role granted / removed | `user_roles` INSERT; UPDATE `revoked_at / revoked_by / revoke_reason` (soft) | 9 rows, all pre-log (2 revoked); 0 log rows for real accounts |
| primary link | `employees.user_id` UPDATE (`set_user_employee_link`) — no stamp | 0 log rows for real employees |
| additional account | `employee_accounts` I / hard D + `employee_account_history` I (`link_ / unlink_additional_account`) | 1 + 1, pre-log |

**Mirrored on the employee page** through the same rows reached from the employee: `employee_accounts` and `employee_account_history`
down by `employee_id`, the account up through `employees.user_id` (M9), `user_roles` under it. An up hop follows only the **current**
link, so an account linked earlier and since unlinked is reached through the `employees.user_id` log rows (M10 on the root column).
Each row keeps its own read rule (Q21).

**The UI hook:** `UserRow` is a client component (`UserRow.tsx:1`); the page renders one `<AuditTrail compact subject="account" …>` per row and
passes it in, the journal-request / claim precedent.

---

## e. The approval-policy panel (Q25, moved to AT-1d by 1c Q2)

It owns **`approvals_enabled`, `approval_threshold_base`, `approval_level1_role_code`, `approval_level2_role_code`** — exactly the
columns `set_approvals_policy` writes (`:64-70`), plus its history table through M7. Its trail never shows the lock, GST or the six
unowned columns (M6). Pre-log: one `finance_settings_history` row (22/09/2026, approvals switched on). `ApprovalsHistory` is replaced; the
page note "Every change made here is recorded below" (`messages/en.ts:7978`) stays true. The history table's four role-code pairs are
hidden in the catalogue today (`text_code`) although they are F47's content → unhidden and labelled (Q33).

---

## f. Q21 pages for HR and settings records

| record (live) | today | proposal | banner (English, `DD/MM/YYYY`) | who may open |
|---|---|---|---|---|
| deleted employee (15, all `ZZ-*` test rows) | 404 (`employees/[id]/page.tsx:44`; edit `:52`) | open read-only (`<EndedFieldset>`); add to `deleted_records` and `/settings/deleted` | "Deleted on DD/MM/YYYY" (no deleter column; the change log's person when there is one) | `data.view_deleted` (Q26) |
| deleted department (0) | 404 (`departments/[id]/edit/page.tsx:31`) | same | same | `data.view_deleted` |
| deleted training record (0) | 404 (`training/[id]/edit/page.tsx:30`) and drops off the employee page | same | same | `data.view_deleted` |
| deleted role (1, `operations`, 10/09/2026) | 404 (`settings/roles/[id]/page.tsx:32,42`) | same | "Deleted on 10/09/2026" | `data.view_deleted` (Q25) |
| cancelled leave · withdrawn claim · reversed / discarded overtime · void review · unposted payroll | open | unchanged; trail added; the void review's banner gains who and when (`voided_by / voided_at` exist, `reviews/[id]/page.tsx:158-161` shows only the reason) | "Voided on DD/MM/YYYY by <name>" + reason | normal readers |
| disabled account | stays listed (`user_directory.disabled`) | unchanged | — | — |
| dictionary values · import batches | cannot be deleted (no DELETE policy / SELECT-only grant) | — | — | — |

The name follows the ActorName rule, as in §9.10.

---

## g. Existing history sections

| section | file:line | verdict |
|---|---|---|
| `ApprovalsHistory` | `app/settings/approvals/page.tsx:78-82,129` | **replace** (Q25 names it); no other reader of `finance_settings_history` |
| `SalaryChangePanel` "recently settled" list | `app/hr/employees/[id]/SalaryChangePanel.tsx:229-249` (fed `page.tsx:126-129,452`, `salary_change_requests_visible(p_recent 5)`) | **replace** — decided / withdrawn requests with who and notes; the open-request block above it is a control, kept |
| payroll `PostControls` request history | `app/hr/payroll/[id]/PostControls.tsx:264-280` (fed `page.tsx:108`) | **replace** — every non-open request with status and notes; the open request and the post / unpost controls stay |
| employment history timeline | `app/hr/employees/[id]/page.tsx:382-405`; also read by `/me` (`app/me/page.tsx:145-149`) | **keep** — the effective-dated career record (Q26's own words); it is also the pre-log source |
| leave consumption table | `app/hr/leave/[id]/page.tsx:167-173` | keep (a balance ledger) |
| overtime stamp list (created / submitted / decided / reversed by) | `app/hr/overtime/[id]/page.tsx:110-136` | keep (the request's current state, the 1c payment-request precedent); the trail adds discards and earlier decisions it loses |
| `ImportHistoryTable` | `app/settings/import/page.tsx:84` | keep (the batch log is the record list); it gains "who" (Q24) |
| reviews, payslips, training tables on the employee page; `/me` tables | — | keep (working lists) |

Q26 (AT-0) said "keep request panels"; the two replacements are the **history lists inside** two request panels, not the panels — the same
call 1c-1 made for the invoice-request history list (Q27).

---

## h. New wordings and labels

- **Event wordings** (D §1): **71** AT-0 catalogue rows for AT-1d — 14 existing, 34 "state word as a sentence", 23 new. HR 57 (G01–G11,
  G16–G61), accounts I03–I10 · I12, approval policy F45–F48, import F97. No catalogue row at all for training, departments, leave types,
  holidays, the scale, dictionaries, review goals, KPI generation, overtime lines, payroll recompute, a self-assessment sent back, an
  employee deleted. Reusable: `approval.*`, `po.autoApproved`, `account.ACCOUNT_*`, `role.*`, `generic.*`, `banner.*`, `who.*`.
  **Estimate: 110–160 new keys** (per cut so far: 117 · 123 · 113 · 54 · 79 · 65 · 44; total 595).
- **Ambiguous** (D §2: 30 cases; the ones that matter): a leave UPDATE to `cancelled` is a cancellation, not a decision, and "by the
  employee" when the actor is the subject; overtime → `draft` is created or taken back (by INSERT vs UPDATE); `rejected` reads "Sent back"
  as the overtime page says (Q35); attendance → `open` is opened or reopened; payroll unpost appends a machine note to `notes`; a payroll
  request is approved and then executed in **two** operations; `employment_history` `salary_change` is a first salary, an approved change
  or a review outcome (writer / `old_monthly_salary IS NULL`); `performance_reviews` → `self_review` is a first opening or a sent-back
  self-assessment; `save_self_assessment` is a draft save or the final submit; a KPI re-score; a login **moved** between employees in one
  transaction is "moved", not "unlinked"; `ACCOUNT_DISABLE` followed by `ACCOUNT_DISABLE_FAILED` means **not** disabled; `anonymise_employee`
  NULLs are "Personal data anonymised", never edits.
- **Field labels** (D §3): **369** shown columns on the 35 tables (+15 on `kpi_cycles`, `positions`), **0** hand overrides. Wrong today:
  button / message text ("Decided by you (flagged)", "Employee not visible to you", "Request leave", "New batch", "Open cycle", "Reviews",
  "Actions"); wrong meaning (`employment_history.effective_date` "First payroll month", `holiday_key` "Identity key", "User" for login
  accounts, "Actor user", `decided_via` — a permission code, "CFO's note"); **duplicates** (overtime `decided_at` and `decided_by` both "Decided
  by", `reversed_*` both "Reversed by"; leave `is_exception` and `exception_reason`); states for dates ("Locked", "Completed", "Expires");
  casing ("Ot normal hours", "Amount SGD", "Certificate ref"); **"Name (EN) / (ZH)" on 24 columns of 10 tables** (Q32);
  `finance_settings_history`'s inconsistent old / new pairs and four hidden role-code pairs (Q33); `payroll_requests.label` embeds the raw
  kind ("post #1"); JSON `snapshot` ×2.
- **Enums** (D §3.3): **24** values on 7 columns with no English (`medical_claims.status`, `leave_grants.grant_type`,
  `import_batches.target_table`, `employment_history.work_category`, `leave_types.gender_restriction`, `employee_account_history.action`,
  `kpi_cycles.status`), plus **9** columns with no CHECK and no map (Q34).

---

## i. Conflicts with the standing rulings or with how AT-1a … 1c built the mechanism

| # | conflict | where | proposed resolution |
|---|---|---|---|
| 1 | AT-0 Q24 (per-account trail, mirrored on the employee page) cannot be expressed: the root is outside `public` | §2 item 2 | M9 (Q2) |
| 2 | §9.7 ActorName ("without hr.view you recognise only yourself") vs pages that print names: `/me` (decider, overtime approver, manager) and the overtime page for the warehouse approver | B §4–5 | Q15, Q20 |
| 3 | M8 (1c-3) judges the root on its current image — admits the reviewed employee to pre-approval drafts | `record_trail.sql:179` | M12 for `/my-reviews` (Q5); no review trail on `/me` (Q14) |
| 4 | AT-0 §4 "created by import batch X" vs the `import_batches` comment forbidding lineage | C §D | Q24 |
| 5 | AT-0 Q26 "keep request panels" vs two pure history lists inside request panels | §g | Q27 |
| 6 | Q16 (one entry per operation) vs writers that split one action over two or three transactions | §2 item 4 | Q8, Q9 |
| 7 | 1b §9.5 / 1c Q9 "no stamp a history already records" — several HR stamps are the only record, and some are overwritten | §2 item 5 | Q12 |
| 8 | §9.10 / Q21 — four kinds 404 and are missing from `deleted_records` | §f | Q25, Q26 |
| 9 | `record_trail`'s down hop reads only a parent key named `id` (`record_trail.sql:141-143`); no subject has used a text root key | §2 item 9 | M11 (Q4) avoids it |
| 10 | AT-1a's `role` subject omits `user_roles` | `trail_subject_members.sql:46` | Q22 |
| 11 | The one-reader rule of §9.3 ("both readers call the same masking step") vs `change_log_rows` not re-checking row rules as `record_trail` does | §2 item 10 | Q13 |

No conflict found with the 1b fold-ins (paging, the all-English trail section) or with "a label belongs to the cut that first shows its
table" (no AT-1d table has a label override from an earlier cut; `finance_settings`' approval columns were already fixed in 1c-3).

---

## j. Migration shape and broken window

**One migration per cut, functions and views only** (plus seed rows):
- replaced in place, same signature: `trail_subjects`, `trail_subject_members`, `trail_prelog_sources`, `trail_ref_label`, `trail_row_record`,
  `trail_current_image` and `trail_row_visible` (M9), `record_trail` (M9–M12, return columns unchanged — so `CREATE OR REPLACE` works);
- `change_log_rows` (Q13; same signature);
- `deleted_records` view (+ employee, department, training record, role branches — Q25, Q26);
- new function `save_employee` (Q8) — EXECUTE granted, anon revoked by `apply_migration.sh`'s ACL replay;
- `document_types`: link mode `detail` for `medical_claim` and `attendance_period`, a row for `overtime_batch` (Q36) — a seed table, mirror and
  `check_mirrors` seed comparison in the same commit;
- no table DDL, no policy, no grant on a table, no trigger, no permission code; no business row written.

**Broken window (old app + new database):**
- **Nothing that writes breaks.** `save_employee` is new; the old app keeps its direct `employees` / `employment_history` writes, which the
  table policies still allow.
- The old app calls `record_trail` only for the 1a–1c subjects, with the same arguments and return shape.
- **Visible early, and intended:** `/settings/deleted` lists the new kinds with a raw key label and no link until the deploy (the 1b-3 and
  1c-2 shape); the role page's trail gains grant rows (the new member) in the old app; `/settings/change-history` rows for `user_roles`,
  `employee_accounts` and settings collections name their new home; Q13 changes nothing visible for live readers (admin and cfo hold both
  codes).

---

## k. Time estimate — two numbers, calibrated on AT-1a … 1c-3

**Measured** (D §4, transcripts, `db/migration-windows.tsv`, push times):

| cut | start → push | active | before backup | backup → push | subjects | min / subject |
|---|---|---|---|---|---|---|
| AT-1a | 7 h 46 m | 4 h 38 m | 1 h 50 m | 2 h 48 m | 3 + mechanism | 92.6 |
| 1b-1 | 4 h 14 m | 3 h 37 m | 1 h 05 m | 2 h 32 m | 7 | 31.0 |
| 1b-2 | 3 h 18 m | 3 h 04 m | 52 m | 2 h 12 m | 11 | 16.7 |
| 1b-3 | 3 h 06 m | 3 h 06 m | 54 m | 2 h 12 m | 8 | 23.3 |
| 1c-1 | 4 h 18 m | 2 h 59 m | 53 m | 2 h 06 m | 7 + M7, op_key, Q12 | 25.5 |
| 1c-2 | 9 h 51 m | 3 h 16 m | 57 m | 2 h 19 m | 8 | 24.5 |
| 1c-3 | 3 h 05 m | 2 h 36 m | 50 m | 1 h 46 m | 12 (mostly list blocks) | 13.0 |

Per-step, 1c: backup 9.4–17 min; offline gate ~1.1 min; dry run + apply 1.2–1.7 min; types + tsc + build ~2.5 min; full gate 6–7.5 min
(own); layout survey 5.5–7 min; smoke 16–22 min; probe 3.5–6 min; proof < 1 min. **Every 1c cut also ran a 21–34 min fix-and-rerun chain
after the proof and had one red step** (eleven offline-gate runs; a red backup and a red gate + fu1; a gate timeout).

| | AT-1d |
|---|---|
| **Process floor per migration cut** | **50–65 min** pure (the step sum above); **1 h 45 m – 2 h 20 m** as every 1c cut actually ran it (backup → push, fix chain and one red step included) |
| **Work** | **6 – 9 h** for the whole scope (inferred): ~30 subjects (6 of them dictionaries, which M11 makes one shape) at the 1c rates — 13–25.5 active min per subject including floor, i.e. about 1 h 35 m – 2 h 15 m of writing per 1c cut of 7–12 subjects — gives 4.5–7 h; plus M9–M12, `save_employee`, the renderer pieces, Q13 and four Q21 kinds, about 1.5–2 h (1c-1 built M7 + op_key + Q12 inside its 2 h of writing) |

**One session cannot hold it**: no session has held more than about 3 h 40 m of build, and since 1b-2 every cut has cost **2 h 36 m – 3 h 16 m**
active regardless of subject count. Work 6–9 h + three floors ≈ 9–12 h active → **three cuts** (Q1).

---

## Open questions — all of them, each with my recommendation

**Shape**

❓ **Q1 — Split AT-1d?** Work 6–9 h, ~30 subjects, four new mechanism pieces.
➡️ **Three cuts inside v1.4.33, each with its own migration and floor, each leaving usable pages; the v1.4.33 release line is written when
the last closes:**
- **1d-1 · mechanism, settings and the employee:** M9–M12 (all four built now, so later cuts add only registry rows — the 1b-1 precedent),
  Q13, `save_employee` (Q8); `account` on `/settings/accounts` + the mirror on the employee page, `user_roles` on the role page, deleted
  roles; `approval_policy` (replaces `ApprovalsHistory`); the six dictionaries; import batches; `employee` (+ salary-change history list
  replaced), `department`, `training_record` and their Q21 pages. About 2.5–3 h work.
- **1d-2 · leave and time:** `leave_request`, leave grants, leave types, public holidays, `medical_claim`, `overtime_batch`, `attendance_period`,
  and `/me`'s `my_leave_request` / `my_medical_claim`. About 1.5–2.5 h.
- **1d-3 · pay and performance:** `payroll_period` (request history replaced), `performance_review`, `my_review`, review cycles, the rating
  scale, KPI entries. About 2–3 h.
Why this order: 1d-1 carries every mechanism risk while the pages it touches are few and admin-only; each later cut is registry, wording
and labels on a finished mechanism.

**Mechanism**

❓ **Q2 — The per-account trail needs a root outside `public` (`auth.users`).**
➡️ **M9: a log-only root** with a fixed safe projection as its image (`id, email, created_at, banned_until` — never the whole auth row) and a
declared rule `action.manage_permissions` (the same predicate as `user_directory`). Account creation (`created_at`) is its pre-log source.

❓ **Q3 — The primary link (`employees.user_id`) on the account trail** would bring every HR edit of that employee with it.
➡️ **M10: a member limited to declared columns** (`['user_id']`). The alternative — leave the primary link off the account trail and show only
additional accounts and grants — loses the most common link event.

❓ **Q4 — Settings collections:** holidays are hard-deleted (a per-row block cannot list them); leave types, the rating scale and the six
dictionaries are keyed by `code text`, a path no subject has run.
➡️ **M11: a collection subject** — one trail per settings page (per dictionary section), every row and log row of the table belongs (M7
without a singleton parent). One shape for nine collections; no text-key path needed.

❓ **Q5 — `/my-reviews/[id]`** (the reviewer's page, no module guard) needs its own subject; M8 alone would also admit the reviewed employee
once the review is approved, including the reviewer's drafting edits.
➡️ **`my_review` with M12: a gate narrower than the table's rule** — the reviewer (`reviewer_employee_id = current_user_employee()`) only.
Approval rows read Restricted to a reviewer without hr.view (Q4).

❓ **Q6 — Review cycles:** opening a cycle inserts one review per employee in the same operation; a member would pull every later review edit
into the cycle block.
➡️ **No extension.** The cycle block says "Review cycle opened" / "Review cycle closed" from the cycle row; each review's own trail opens with
"Annual review opened (cycle …)". The count stays on the page's existing cycle table.

❓ **Q7 — Review approval writes `employees` and `employment_history`** (confirmation, salary) with no key back to the review.
➡️ **No extension.** The review trail words the outcome from the review's own columns (`probation_outcome`, `new_monthly_salary`, masked as
today); the employee trail words its history row as "Confirmed after probation" / "Salary changed …", recognising the writer's note (Q10).

**Writers that split one action**

❓ **Q8 — Hiring or editing an employee is two or three transactions** (`employees`, then `employment_history`, then the link — `actions.ts:239,251`),
so the trail shows "Employee added" and "Hired" as two entries.
➡️ **One RPC, `save_employee`, for the row and its history** (the 1b-3 Q13 `save_storage_location` precedent: fix the writer, one call, only
what changed). The account link stays its own call — it is a different permission (`action.manage_permissions`).

❓ **Q9 — Creating an account is three transactions** (the event, the link, the roles); the auth user is created over the service API and
cannot share a database transaction.
➡️ **Keep three entries** on the account trail — each is a real step, and an `ACCOUNT_DELETE` (creation rolled back) must stay visible.
`ACCOUNT_DISABLE` + `ACCOUNT_DISABLE_FAILED` render as one "Disabling failed" line.

**Renderer**

❓ **Q10 — Machine text inside human columns:** the overtime approver's note gets a Chinese suffix with approvals off
(`decide_overtime_batch.sql:67-69`); payroll decisions get a bilingual "own pay line" suffix (`decide_payroll_request.sql:62-66`); payroll
unpost appends "[… unposted …]" to `notes`; `employment_history.notes` holds "Probation confirmed by performance review <uuid>"
(`approve_review.sql:68,118`); `payroll_requests.label` embeds the raw kind; `salary_change_requests.decided_via` holds a permission code.
➡️ **Recognise each in the renderer and say it in English** (the 1c-2 "Reconciliation undone" precedent): strip the suffixes, word the unpost
note as "Payroll unposted", the review note as "Confirmed after probation (review)", the label without its kind; hide `decided_via`. Register
the writers in `docs/known-issues.md`; changing what they write is separate.

❓ **Q11 — Payroll lines are deleted and re-inserted with new ids on every save** (`upsert_payroll_period.sql:78,118`), so an unchanged line
reads "removed" and "added", a changed one as two lines.
➡️ **Pair a delete + insert in one operation by employee** → "Line · <name> · Gross pay a → b"; an unchanged pair says nothing (the 1b-3
netting rule, keyed by the natural key instead of the value).

**Before the log**

❓ **Q12 — Stamps that are the only record of an event, some overwritten by later writers.**
➡️ **Register them as pre-log stamps, the Q11 / 1c Q9 exception:** `leave_requests.decided_at/by` (status-aware: the only record of the two live
self-cancellations; folds with the approval row where one exists), `overtime_batches.reversed_*` and `discarded_*`, `attendance_periods.completed_*`
and `reopened_*` (latest only — said so), `performance_reviews.voided_*`, `medical_claims.withdrawn_at` (no person — "Not recorded", never
`updated_by`), `salary_change_requests.withdrawn_*`, `payroll_requests.withdrawn_*`, `user_roles.granted_*` / `revoked_*`,
`employee_accounts.linked_*`, `finance_settings_history`, `auth.users.created_at`, `import_batches.imported_*`. Decisions already in
`approval_log` are not registered twice.

**Masking and `/me`**

❓ **Q13 — The global reader (`/settings/change-history`) does not re-check row rules**, so a `data.view_change_log` holder without `view_pay`
would see salary-change figures, and one without `view_reviews` review and KPI text. No live holder is affected.
➡️ **Make `change_log_rows` re-check each row's read rule (`trail_row_visible`) and return it Restricted**, as `record_trail` does — one rule
for both readers (§9.3), and it closes the salary, review and KPI cases at once. Column rules for `salary_change_requests` would close only
one.

❓ **Q14 — Which own records get a trail on `/me`?**
➡️ **Only the two request kinds the employee raises, besides the expense claims 1c-3 did: leave requests and medical claims** (`my_leave_request`,
`my_medical_claim`, M8 — the own-row policy and the page agree there). **No `/me` trail** for the profile and employment history (HR-internal
`notes`), payslips (re-created on every save), reviews (pre-approval drafts) or KPI entries (open-cycle scores). HR's pages carry those.

❓ **Q15 — Names on `/me` trails.** `/me` prints the decider by name; the ActorName rule would print "Restricted" to an employee without hr.view
(today only the warehouse account).
➡️ **Follow the ActorName rule, as `my_expense_claim` does** (1c-3): the approval rows are Restricted anyway (their rule is hr.view), and the
`/me` table's Decision column already names who decided. One rule everywhere.

❓ **Q16 — KPI scores in an open cycle are readable today through the API** (the `kpi_entries` own-row policy has no cycle condition; `/me`
hides them until close).
➡️ **Register in `docs/known-issues.md` as a separate decision.** Q14 adds no KPI trail on `/me`, so AT-1d adds no new exposure.

❓ **Q17 — `employees.notes` and `separation_notes` are HR-internal on screen but self-readable by policy** (the personal-data export already
returns notes changes).
➡️ **Register in `docs/known-issues.md`**; Q14 adds no profile trail on `/me`.

❓ **Q18 — Health text (medical description, leave reason) and payroll period totals sit behind `module.hr.view` only** — with one payroll line,
a period total is one person's pay; cto and gm read it on screen.
➡️ **The trail follows the page; no new data code in AT-1d.** Register the period-total point in `docs/known-issues.md` for you.

❓ **Q19 — `/me` reads `attendance_periods` and `payroll_periods`, which are hr.view only** — a non-HR employee likely sees blank period codes and
months (`app/me/page.tsx:205-206` comment says otherwise; inferred, not seen on a page).
➡️ **Register as a defect in `docs/known-issues.md` and check it in 1d-2's probe** (the warehouse account); the fix is not a trail change.

❓ **Q20 — The warehouse account approves overtime** and the overtime page shows it each employee's name (`overtime_batch_lines()`); the trail would
show them Restricted.
➡️ **The trail follows the ActorName rule** (1b fold-in 1). Register the page / trail difference; if an approver must see names, that is a
change to the rule for overtime approvers, decided once for both.

❓ **Q21 — The account trail mirrored on the employee page,** read by HR readers who lack `action.manage_permissions`.
➡️ **Each row keeps its own read rule (Q4):** grants (`user_roles`, readable by every login) and additional-account links visible; account
events and `employee_account_history` Restricted. No special rule.

**Settings**

❓ **Q22 — `user_roles` belongs to two trails** (the account and the role); today it is on neither, so the role page misses grants.
➡️ **Add it to both; home = the account** (it is what was granted to). The role page shows "Role granted to <name>".

❓ **Q23 — The approval policy's gate.** The page and history are `action.manage_permissions`; the settings row's own rule is `module.finance.view`.
➡️ **View code `action.manage_permissions`, root rule `table`.** Correct for every live reader (admin holds both). A future
manage_permissions holder without finance would be refused, by name — registered.

❓ **Q24 — Import lineage.** AT-0 §4 proposed "created by import batch X"; the `import_batches` table comment forbids any link from imported rows
to their batch.
➡️ **The comment's rule stands.** `/settings/import` gets a list block of import batches (who, when, file, rows, codes) and the table gains a
"who" column; imported records' own trails say "created" as they do today.

❓ **Q25 — Deleted roles 404** (1 live, `operations`).
➡️ **Open read-only for `data.view_deleted` with "Deleted on DD/MM/YYYY" and the trail; add roles to `deleted_records` and `/settings/deleted`** —
the §9.10 pattern.

❓ **Q26 — Deleted employees, departments and training records 404** and are missing from `/settings/deleted` (15 deleted employees, all `ZZ-*`).
➡️ **The same §9.10 pattern for all three**, the person from the change log, date only where none was recorded. `deleteEmployee` stays without a
caller (no UI is added).

**Pages and sections**

❓ **Q27 — Sections to replace.**
➡️ **Replace** `ApprovalsHistory`, the salary-change "recently settled" list and the payroll request history (pure decision histories inside
request panels — the 1c-1 invoice-request precedent); **keep** the employment history, the leave consumption ledger, the overtime stamp list,
`ImportHistoryTable` and every working table (§g).

❓ **Q28 — What rolls up into the employee's trail?**
➡️ **The employee, employment history, salary change requests and their approvals, training records and the account links** — not leave,
claims, reviews, payslips, KPI, overtime or attendance, which have their own pages and would flood it.

❓ **Q29 — Training records.**
➡️ **A `training_record` subject on its edit page** (its only page), and a member of the employee (home = the training record).

❓ **Q30 — Anonymisation.** `anonymise_employee` has no UI, rewrites the change log for `employees` / `employment_history` only, and leaves
salary requests, payroll lines, leave reasons and medical descriptions unredacted.
➡️ **Wording and a fixture only** ("Personal data anonymised", never the NULLs as edits; the person "A former employee"). Register the
redaction gap in `docs/known-issues.md`; no UI.

❓ **Q31 — A salary change's history row names the person who raised the request as its author**, not the approver who executed it
(`salary_change_execute_internal.sql:42-47`).
➡️ **The trail takes "who" from the change log (the approver) after the log**; before the log there are 0 such rows live. Register the writer in
`docs/known-issues.md`.

**Wording and labels**

❓ **Q32 — "Name (EN) / Name (ZH)" on 24 columns of 10 tables**, and whether the Chinese one shows at all.
➡️ **"Name (English)" / "Name (Chinese)"** (AT-1a's `roles` wording), **both shown** — people typed them (Q8); 1c-2 hid `label_zh` only because the
system wrote it.

❓ **Q33 — Field labels.** 384 shown columns, 0 hand overrides; the defects in §h.
➡️ **Hand-check every one against its page** (page label, then `en.ts`, then `labels.csv`); unhide and label `finance_settings_history`'s four
role-code pairs (as role names); hide `decided_via`, `holiday_key`, `monthly_salary_set` and the two `snapshot` columns (or "Details changed");
list every label in each cut's hand-back.

❓ **Q34 — Enum values.** 24 missing on 7 columns; 9 columns with no CHECK.
➡️ **English for every value from the pages' own option labels** (inherit `employees`' maps for the `employment_history` copies); import targets
read as record-type names.

❓ **Q35 — Page words over generic sentences.** The overtime page says "Sent back" for `rejected`; the generic `approval.rejected` would say
"rejected".
➡️ **Each subject uses its page's words** ("Overtime sent back"), the 1c precedent ("Send to the CFO").

❓ **Q36 — `document_types`:** `medical_claim` and `attendance_period` link to their **list** although detail pages exist; `overtime_batch` has no row.
➡️ **Set both to `detail` and add `overtime_batch`**, so references and the summary page's Record column link to the record.

❓ **Q37 — The expense page cannot reach the medical claim that raised it.**
➡️ **Add `medical_claims` (by `expense_id`, not home) to the `expense` subject**, as 1c-3 did for expense claims.

❓ **Q38 — Side findings, none of them trail work.** The leave page prints a uuid fragment (`leave_grant_id.slice(0,8)`); dead `deleted_at`
filters on leave requests and payroll periods (no writer); a closed review cycle can be reopened (guard `status <> 'open'`, inferred);
the dictionaries registry comment says "five" for six; `ApprovalsHistory`'s header says the table is empty (it has 1 row);
`app/settings/accounts/page.tsx:31-34` says admin lacks hr.view (it holds it); the medical claim page links its expense to the list.
➡️ **Register all in `docs/known-issues.md`; fix only the two stale comments in the cut that touches their files** (the AT-0 Q34 shape).

---

**Stopped at the gate.** No code edit and no migration before your answers to Q1–Q38.
