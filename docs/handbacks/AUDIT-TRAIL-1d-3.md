v1.4.33 — Every page now ends with a plain-English audit trail showing who did what and when — including approvals, key production steps, finance postings, HR changes and settings — on-screen dates now read day/month/year, and ended or deleted records open read-only with a banner instead of a missing page (date entry boxes switch to day/month/year in the next update).

# AUDIT-TRAIL-1d-3 — pay and performance: payroll periods, performance reviews and the reviewer's page, review cycles, the rating scale, KPI entries; the Q19 fix (2026-10-05)

This is the last cut of v1.4.33 (AT-1a → 1b → 1c → 1d-1 → 1d-2 → **1d-3**). With it AT-1d is complete, and AUDIT-TRAIL-1 is complete as
**v1.4.33**; the release line is the first line of this file. DATE-PICK-1 (v1.4.34) is next.

**Opening check:** measured at **2026-10-04 23:56:44 CST** (this session's first command). The tree was clean apart from Tim's untracked
`docs/Data capture and ERP integreation.pdf`, which I did not touch. After `git fetch`, `HEAD` = `origin/main` = `ls-remote` =
`cb8c87c956ea570658b37feefe9ea9f0388cbc63`. **Approvals were ON and stayed ON** (finance / cfo / 1,000). All 7 real accounts were enabled before and
after. No real auth account was created, disabled or deleted; the smoke's and the probe's throwaway accounts came and went through their own
ephemeral plans (§7.1).

Every figure below is either a script's own exit line or a query named together with who ran it. Unless stated otherwise, the reader is `postgres`
(`rolbypassrls = true`) reading base tables. "As X" means `SET LOCAL ROLE authenticated` plus X's JWT. The mechanism reference is
**`docs/change-log.md` §9**, which has a new §9.16.

## §1 · Step 1 — the 1d-2 close-out, item by item

**The broken window** is recorded in `docs/forward-queue.md` item 31 (the 1d-1 format), committed with this cut:

| | value | source |
|---|---|---|
| start | **2026-10-04 19:00:10 CST** | `db/migration-windows.tsv` (`2026-10-04T19:00:10+0800	2026-10-04-at1d2-trails-leave-and-time.sql`) |
| end, lower bound | **2026-10-04 21:16:28 CST** | `git reflog show --date=iso refs/remotes/origin/main`: `cb8c87c9 refs/remotes/origin/main@{2026-10-04 21:16:28 +0800}: update by push` |
| end, upper bound | **2026-10-04 23:56:44 CST** | this session's first command (`date`). It rests on Tim's "deployed", **not** on a Vercel reading |
| window | **at least 2 h 16 min 18 s, at most 4 h 56 min 34 s** | the upper bound is wide because 2 h 40 min passed between the push and this close-out |

**Read-only verification of what the 1d-2 report did not mention** (all re-read this session):

| | item | verdict | evidence |
|---|---|---|---|
| a | Q12 stamps for 1d-2 | ✅ | `db/functions/trail_prelog_sources.sql:321` `('leave_requests', 'stamp', 'decided_at', 'decided_by', ARRAY['status', 'decision_notes'], 'account')`, `:328` `('medical_claims', 'stamp', 'withdrawn_at', NULL, ARRAY['status'], …)` (no person column), `:330` `('overtime_batches', 'stamp', 'reversed_at', 'reversed_by', ARRAY['status', 'reverse_reason'], …)`, `:331` `('overtime_batches', 'stamp', 'discarded_at', 'discarded_by', ARRAY['status'], …)`. Fixture 245 (green in this cut's offline gate: `fixture 245-leave-and-time-… ✓`): **leave decision stamp folds with its approval row** — arm P `:196-201` (`IF NOT (v_r ->> 'op_key' = v_r2 ->> 'op_key' AND v_r ->> 'op_key' = v_r3 ->> 'op_key') THEN RAISE … 'the stamp, the approval row and the draw must be one operation'`); **self-cancellation read from the stamp** — arm X `:205-210` (prelog UPDATE `decided_at` with `{"status": "cancelled"}`, actor `Emp`, and no approval row); **overtime reversed_\* and discarded_\*** — arm D `:343-348` (discard and its voided line one `op_key`; reversal with `reverse_reason`); **medical-claim withdrawal "Not recorded"** — arm C `:289-291` (`IF v_r -> 'actor' ->> 'state' <> 'unknown' THEN RAISE … 'never updated_by'`) |
| b | Q20: overtime trails follow the ActorName rule | ✅ | Fixture 245 arm O `:321-328`: as `u_wh` (only `action.overtime_approve`), the line's employee `refs … person … state` must be `restricted` and the batch's `actor` `restricted`. The rule itself: `db/functions/trail_actor.sql:27` `v_hide boolean := NOT has_permission('module.hr.view');`. Renderer: `lib/trail/render.ts:4143` (a Restricted employee on an overtime line becomes an "Employee: Restricted" line, never a name in the title) |
| c | Q27: leave consumption ledger and overtime stamp list kept | ✅ | `app/hr/leave/[id]/page.tsx:170-176` (`{consumptionRows.length > 0 && (… <ConsumptionTable rows={consumptionRows} /> …)}`) above the trail at `:188`; `app/hr/overtime/[id]/page.tsx:109-131` (the `<dl>` with `overtime.createdBy` · `submittedBy` · `decidedBy` · `reversedBy`) above the trail at `:160` |
| d | a hard-deleted public holiday stays in the holidays collection trail | ✅ | `app/hr/leave/holidays/page.tsx:74` `<AuditTrail subject="public_holidays" id="all" … />`; `db/functions/record_trail.sql:128` (an M11 collection also takes every key found only in `change_log` — `FROM change_log c WHERE c.table_name = s.root_table AND c.row_key IS NOT NULL`); `lib/trail/render.ts:3939` (the DELETE is said with its last values). Fixture 245 arm H `:253-264`: insert, change, **hard delete**, then `IF NOT EXISTS (… op = 'DELETE' AND e -> 'old' ->> 'name_en' = 'FX245 Day') THEN RAISE … 'a hard-deleted holiday must stay on the trail'` |
| e | Q36: medical_claim and attendance_period link to their detail pages | ✅ | Mirror `db/tables/document_types.sql:120` (`'medical_claim', 'MC', … '/hr/claims', 'detail'`), `:142` (`'attendance_period', 'ATT', … '/hr/attendance', 'detail'`). Live, read-only, as `postgres` (session `SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY`, `transaction_read_only = on`): `select key, table_name, route, link_mode from document_types where key in ('medical_claim','attendance_period','overtime_batch') or table_name='overtime_batches'` → `attendance_period | attendance_periods | /hr/attendance | detail` · `medical_claim | medical_claims | /hr/claims | detail` (2 rows; no `overtime_batch` row — 1d-2 decision 1, accepted) |
| f | docs | ✅ | `docs/change-log.md` §9.15 "Leave and time (AUDIT-TRAIL-1d-2 …)" (now at line 764) plus the intro paragraph and the nine table rows; `docs/forward-queue.md:6676` `✅ AT-1d-2(2026-10-04)· 请假与考勤`; `docs/known-issues.md:10068` `AT1D1-ME-READS-HR-ONLY-PERIOD-TABLES`, its measured result at `:10073` ("AT-1d-2 量过了 … 以 fusheng@ …": 0 own lines and 0 of 1 payroll periods today; 1 own attendance line and 0 of its period in the rolled-back proof) |
| g | 1d-2's self-taken decisions (`AUDIT-TRAIL-1d-2.md` §9, titles) | listed | 1. `overtime_batch` was not added to `document_types`. 2. Leave types and public holidays are M11 collections, one block per page. 3. Leave grants are a list block over the selected leave year. 4. The leave decision stamp is read by the request's current status. 5. "Leave cancelled" does not say "by the employee". 6. Approval rows of leave, medical claims and overtime use their page's words. 7. Overtime side effects are silent. 8. The two pre-log "latest only" stamps share one sentence. 9. On the claim page, the expense's system note is not a reason. 10. Medical claim amounts are in the base currency. 11. Years print without a thousands separator. 12. The `/me` trails sit in a list under each panel's table. 13. The Q38 side findings on the touched pages were not fixed. 14. Arm ⑫'s goldens were generated, read one by one, and pinned. 15. The Q19 probe is a database-level reading as fusheng@. 16. The proof's first-run `/me` assertion was wrong and was corrected. 17. The migration's proof allows exactly the two `document_types` change-log rows. 18. The build's first run failed on Google Fonts and was retried once. 19. The smoke was rerun after the last renderer change. 20. The fixture builds a local scratch rebuild for iterating |

**Nothing in a–f was missing or partial, so step 2 went ahead.**

**Live state in the brief, re-measured** before anything was written (`db/scripts/2026-10-05-at1d3-live-readings.sql`, 00:47:50 CST, as `postgres`):
7 accounts, 0 disabled; approvals ON; 8 pending documents (`c113de0d5542`); `change_log` 4,831 rows, max seq 5,817; every-row digest `2bd9126fef81` —
the same as 1d-2's last after-reading (21:15), so nothing moved between the two sessions. Reconciliation as tim@ (cfo): AP 416,988.32 / 376,404.42 and AR
57,545.87 / 43,002.12, unexplained **0.00** on both sides.

## §2 · Subjects covered (6 new; 77 → 83)

| subject | page | root (rule) | members (home = this subject unless noted) |
|---|---|---|---|
| `payroll_period` | `/hr/payroll/[id]` | `payroll_periods` (hr.view) | `payroll_lines` · `payroll_requests` · `approval_log` {payroll_request} (under the requests) · `journal_entries` by `source_id` + `{"source_type": "payroll"}` (not home) · their reversals through `reversed_by` (up, not home) |
| `performance_review` | `/hr/reviews/[id]` | `performance_reviews` (table: hr.view and view_reviews, or the reviewer, or the employee once approved) | `review_goals` · `approval_log` {performance_review} |
| `my_review` | `/my-reviews/[id]` | `performance_reviews`, **M8 + M12** (no page code; `gate:reviewer` — the reviewer only) | the same two, not home |
| `review_cycle` | `/hr/reviews/cycles` (`ListTrail`, every cycle) | `review_cycles` (hr.view) | — (Q6: the reviews opening creates are not members) |
| `review_rating_scale` | `/hr/reviews/scale` | **M11** collection, root key `code` | — |
| `kpi_entry` | `/hr/kpi/score?cycle=…` (`ListTrail`, the chosen month, only where scores are visible) | `kpi_entries` (table: hr.view and view_reviews, or own) | — |

**Q12 pre-log stamps registered** (`db/functions/trail_prelog_sources.sql`, the 1d-3 block): `payroll_requests` `stamp withdrawn_at/withdrawn_by [status]` ·
`performance_reviews` `stamp voided_at/voided_by [status, void_reason]` — the two the Step 0 hand-back assigned here — and, taken by this cut,
`kpi_entries` `stamp scored_at/scored_by [score, score_kind]` (decision §9 #5). Creations: `payroll_periods`, `payroll_lines` (no person column → "Not
recorded"), `payroll_requests`, `performance_reviews`, `review_goals`, `review_cycles`, `review_rating_scale`, `kpi_entries`. Decisions already in
`approval_log` (payroll submit / decide, review submit / approve / acknowledge) are not registered twice.

**Q19 fixed (Tim's fold-in):** a new `my_period_labels()` gives the caller the code and month of the periods their own attendance lines and payslips
belong to, and nothing else; `/me` reads them from it (§3, §7.2).

**Not in this cut, by the brief:** DATE-PICK-1 and UNBLOCK-1 (the payroll-journal leak and the privacy group Q16 · Q17 · Q18 · Q30).

## §3 · What was built

### Database
- Changed (`db/functions/`, same signatures, replaced in place): `trail_subjects.sql` (6 rows), `trail_subject_members.sql` (9 rows),
  `trail_prelog_sources.sql` (11 rows), `trail_ref_label.sql` (a review's name "Annual review 01/01/2026–31/12/2026" with a link to `/hr/reviews/<id>`;
  a payroll request's name "PAY-… posting request" without the raw kind; a KPI entry's "F1 · <title>"), `trail_row_record.sql` (a review's Record
  column links to `/hr/reviews/<id>`). `record_trail` is unchanged.
- New: `db/functions/my_period_labels.sql` — `RETURNS TABLE(kind text, period_id uuid, code text, period_month date)`, SQL, `STABLE SECURITY DEFINER`,
  no arguments; rows limited by `current_user_employee()` (NULL for anon → 0 rows), columns limited by its return table. EXECUTE for `authenticated`
  and `service_role` only.
- No table DDL, no policy, no grant on a table, no trigger, no seed row, no business row.
- Migration: `db/migrations/2026-10-05-at1d3-trails-pay-and-performance.sql` (1,793 lines), built by `db/scripts/build_at1d3_migration.py` from the
  mirrors. Its precondition is 77 subjects and no `my_period_labels()`; its proof (same transaction) checks grants unchanged, approvals ON, pending
  documents unchanged, `change_log` not moved by a single row, 83 subjects, every root and shown member table carries the change-log trigger, execute
  rights (`my_period_labels()` included), no disabled account; then reads every live payroll period, review, cycle and KPI entry and the rating scale as
  admin@ (none refused, none empty), every review as its reviewer, and calls `my_period_labels()` as every linked account (only their own periods).

### Renderer (`lib/trail/`)
- `render.ts`: a new section for pay and performance — `describePay` (periods, pay lines paired by employee, requests, approval rows, the period's
  journals by role), `describeReview` (reviews, goals, approval rows, cycles), `describeKpi`; a page-wide `hrContext` (which step each journal is,
  how many lines a salary journal paid, each review's current outcome); two exported note splitters, `splitPayrollDecisionNote` and
  `splitPayrollUnpostNote` (Q10). The rating scale uses the dictionary family (M11). `historyNote` (1d-1) now also recognises approve_review's
  salary sentence. Families `pay` · `review` · `kpi`; `SUBJECT_TABLES` and `PAGE_FAMILY` for the six subjects; `new_monthly_salary` is base currency.
- `text.ts`: 57 new keys (§8.1). `catalogue.generated.ts`: regenerated with the 1d-3 labels (§8.2).

### App
§4 lists the pages. Shared components: `app/components/trail/AuditTrail.tsx` (6 subjects), `ListTrail.tsx` (`reviewCycles` and `kpiEntries` intros).
`app/hr/reviews/reviewShared.ts` reads `voided_by` (the void banner's "by"). Two message keys that only the replaced sections used were deleted from
both `messages/en.ts` and `messages/zh.ts`: `hr.payrollRequest.history` and `reviews.voidBanner`.

## §4 · Pages — every new or changed route, with its file

| route | file(s) | what changed |
|---|---|---|
| `/hr/payroll/[id]` | `app/hr/payroll/[id]/page.tsx`, `app/hr/payroll/[id]/PostControls.tsx` | the period's trail at the bottom; the request panel's "Earlier requests" list removed — the trail replaces it (Q27); the open request and the post / unpost controls stay |
| `/hr/reviews/[id]` | `app/hr/reviews/[id]/page.tsx`, `app/hr/reviews/reviewShared.ts` | the review's trail at the bottom; a voided review's banner now reads "Voided on DD/MM/YYYY by <name>" with the reason (`EndedBanner`; it used to give the reason only) |
| `/my-reviews/[id]` | `app/my-reviews/[id]/page.tsx` | the reviewer's trail (`my_review`) at the bottom |
| `/hr/reviews/cycles` | `app/hr/reviews/cycles/page.tsx` | a list block of every review cycle |
| `/hr/reviews/scale` | `app/hr/reviews/scale/page.tsx` | one trail for the whole rating scale (M11) |
| `/hr/kpi/score?cycle=…` | `app/hr/kpi/score/page.tsx` | a list block of the chosen month's KPI entries, only in the branch where scores are visible (`data.view_reviews`); the employee read now includes `code` (the block's Record column says "<employee code> · <KPI>") |
| `/me` | `app/me/page.tsx` | Q19: the attendance and payslip tables take the period code and month from `my_period_labels()`; the period status (attendance) and currency (payslips) are still read directly, as before (empty for an employee without `module.hr.view` — registered, §10). No review or KPI trail (Q14 · Q16) |

## §5 · Verification, in the brief's order

Each verdict is the script's own exit line, read from its log (never the launcher's code).

| # | step | result |
|---|---|---|
| 1 | offline gate (`db/gate.py --offline`) | `GATE_OFFLINE_EXIT=0` (67 s), fixture 246 ✓ among all fixtures; it does not touch live and does not hold the lock |
| 2 | backup (background, `run_detached`) | `BACKUP_EXIT=0`, 00:47 → 01:12 CST, `evoltrya-backup-2026-10-05-0047.dump` 5.7 MB, `pg_restore --list` reads 7,321 TOC entries. The migration ran only after that line |
| 3 | `apply_migration.sh` | dry run first (COMMIT → ROLLBACK on live, `DRY_OWN_EXIT=0`: 35 records as admin@, 0 reviews as a reviewer, 6 linked accounts through `my_period_labels()`). Then preflight ✓ (7 `CREATE FUNCTION`: 5 replaced — `trail_subjects`, `trail_subject_members`, `trail_prelog_sources`, `trail_ref_label`, `trail_row_record` — plus `my_period_labels()` and the migration's own `pg_temp` pending-approver check; no account codes; no columns added), `APPLY_OWN_EXIT=0`, **committed 2026-10-05 01:14:31 CST** — the window's start, written to `db/migration-windows.tsv` |
| 4 | `npm run types:gen` | `TYPES_OWN_EXIT=0`; the generated `lib/database.types.ts` is byte-identical to the hand-added `my_period_labels` type |
| 5 | `npx tsc --noEmit` | `TSC_OWN_EXIT=0` |
| 6 | `npm run build` | `BUILD_OWN_EXIT=0` (all static checks, then `next build`) |
| 7 | full gate (`db/gate.py`) | `GATE_EXIT=0` (731 s): rebuildability ✓ · mirrors vs live ✓ (structure, seeds, bootstraps, integrity, definer: 0 unchecked) · behavioural assertions ✓ (246 ✓) · anon surface ✓ (live ⊆ the 327-line baseline) |
| 8 | i18n check | `I18N_OWN_EXIT=0` (220 dynamic prefixes, all enumerable) |
| 9 | error-swallowing check | `SWALLOW_OWN_EXIT=0` (0 unallowed, 9 allowlisted) |
| 10 | layout survey, 390 px and 1280 px | **7 pages, 0 page overflow, 0 clipped tables, at both widths** (`SURVEY390_EXIT=0`, `SURVEY1280_EXIT=0`, then `SURVEY390B_EXIT=0`, `SURVEY1280B_EXIT=0`): `/hr/payroll/<PAY-2026-0001>`, `/hr/reviews/cycles`, `/hr/reviews/scale`, `/me`, `/hr/kpi/score?cycle=<2026-09>`, and `/hr/reviews/[id]` + `/my-reviews/[id]` on the survey's own throwaway probation review (seeded and removed by the survey; live has no review). The first pass filed the KPI address as "redirected" to itself — a survey defect, not a page one (decision 24); after the fix it was measured in the second pass |
| 11 | smoke (background) | `SMOKE_EXIT=0`: 243 routes + the reviewer-view check (`/my-reviews/[id]`'s trail) + the content probes — **260 ok, 9 skipped (no data), 0 failed** (skipped: packs ×2, payment requests, statements PDF, attendance period, overtime batch, handover, output assay, commission). Scratch cleanup reading: the same 6 stale `ZZ-SMOKE-*` rows as in 1d-1 and 1d-2 (materials PROBE / M25 / NTF, supplier S25, customer CJK, inbound batch IB25; 5 still referenced; report-only, none deleted). Read back as postgres afterwards: 0 `@test.local` accounts, 7 accounts / 0 disabled, 0 `probe-*` roles, 0 grants without an account, 0 `ZZ-SMOKE*` employees (22 employees, as before), 0 reviews, 0 cycles, 0 plans in `.ephemeral/` |
| 12 | live verification | §7 |
| — | the 1d-3 probe (`scripts/probe-at1d3.mjs`) | `AT1D3_PROBE_EXIT=0`: 20 passed, 0 failed, 1 skipped (no review on live — fixture 246 RV · MR · RX, the smoke's throwaway review and the rolled-back proof cover it) |
| — | wording check (`check-trail-wording.mjs`) | `TW_OWN_EXIT=0`, arm ⑬ green (53 goldens; the splitter contracts; the SUBS13 sweep over all 6 subjects with its coverage assertion) |
| — | rerun after files changed post-build | two files changed after the build and the full gate: `scripts/survey-phone.mjs` (decision 24) and `db/scripts/2026-10-05-at1d3-live-proof.sql` (the proof's month, §7.2). Neither is read by the gate or by `next build`; the static checks that read them were rerun: eslint freeze `LINT2_OWN_EXIT=0` and `LINT3_OWN_EXIT=0`, every static check of `npm run build` `STATIC2_OWN_EXIT=0` |

## §6 · Fault injection — every arm made to fail on purpose

- **Fixture 246** (`db/scripts/2026-10-05-at1d3-fixture-injections.py`): `INJECTIONS_OWN_EXIT=0 (21 injections, 0 wrong)` — the clean fixture is green,
  and each injection goes red **in its own arm**:
  PP — the pay lines dropped (Q11) · the journals found through `journal_entry_id` instead of `source_id` · the pay figures unmasked for a reader without
  `data.view_pay` (Q4) · the payroll requests dropped; PQ — the withdrawal stamp unregistered · the stamp losing its person (Q12);
  RV — the approval rows dropped · the employee row hung on the review · the new salary unmasked (Q7); MR — the reviewer gate switched off (M12) · the
  goals dropped; CY — the cycle's reviews hung on the cycle (Q6); RX — the void stamp unregistered (Q12); SC — the scale no longer a collection (M11);
  KP — the entry opened to its own employee (Q14 · Q16) · the scoring stamp unregistered (Q12); Q — the labels reaching periods with none of the caller's
  lines · carrying more than code and month · uncallable by the employee (Q19); R — a payroll request named with its raw kind (Q10) · a goal losing its
  review's link.
- **Wording arm ⑬** (`TRAIL_WORDING_FAULT=wording-drift-1d3`): `TWINJ_OWN_EXIT=1`, red in ⑬ only ("⑬ 工资与评审:1 处").
- **The probe** — each injection exits 1 and reds exactly its own assertion:
  `q27-history` (`PINJ_Q27_HISTORY_EXIT=1`: "the old history section is still drawn") · `me-review-trail` (`PINJ_ME_REVIEW_TRAIL_EXIT=1`: "subjects on
  /me: …, my_review") · `machine` (`PINJ_MACHINE_EXIT=1`: the uuid found on all 6 pages) · `cjk` (`PINJ_CJK_EXIT=1`: the Chinese interface parts from
  the English one on all 6 pages, "受限").
- **Machine-token checks cover every new subject:** arm ⑬'s SUBS13 sweep runs all six subjects through the renderer and asserts the sweep reached each
  of them; the probe checks every 1d-3 page plus a leave page and an employee page; the rendered proof (§7.2) counts tokens over 39 records.

## §7 · Live verification

### §7.1 · Before and after

Read as `postgres` (`rolbypassrls = true`, base tables) with `db/scripts/2026-10-05-at1d3-live-readings.sql`; reconciliation read as tim@ (cfo) with
`db/scripts/2026-10-05-at1d3-live-recon.sql`. **Before: 00:47:50 CST** (before the backup and the migration). **After: 02:18:59 CST** (after the survey,
the smoke, the probe and its injections, and the proof).

| reading | before | after |
|---|---|---|
| accounts | 7, 0 disabled · `ababff588d2a` | **same** |
| approvals | ON | **ON** |
| pending documents | 8 · `c113de0d5542` | **same** (every one keeps an eligible approver other than its submitter — the migration's own `pg_temp` check, before and after) |
| payroll periods / lines / requests | 1 · `73d3a0085395` / 1 · `bb63452e7faf` / 0 | **same** |
| reviews / goals / cycles | 0 / 0 / 0 | **same** |
| rating scale | 4 · `34810068de14` | **same** (the proof's changed description is back) |
| KPI entries / KPI months | 30 · `f1a2b1e05d5a` / 6 · `012f82990343` | **same** |
| attendance periods / lines | 0 / 0 | **same** |
| employees | 22 · `e07f3bc5a8af` | **same** |
| approval log · document types | 17 · `038da2ec130b` · 41 · `2215acb0b2b1` | **same** |
| every other column (purchase orders … overtime; 48 columns compared by script) | as recorded | **same, column for column** (only `change_log` differs) |
| AP recon | 416,988.32 / 376,404.42, unexplained **0.00**, agrees | **same** |
| AR recon | 57,545.87 / 43,002.12, unexplained **0.00**, agrees | **same** |
| change_log | 4,831 rows, max seq 5,817 | 5,074, max seq 6,060 (**+243**, explained below) |
| every-row digest (241 public tables, change_log excluded) | `2bd9126fef81` | `775615b1491a` (explained below) |

**The +243 change-log rows, grouped by table and operation (seq > 5,817):** every row key is a create/delete pair of a throwaway — the four survey
runs' and the smoke's seeded reviewers and reviews (employees 11 + 11, reviews 5 inserts + 5 updates + 5 deletes), the grants of the survey's, the
smoke's and the probe's throwaway accounts (user_roles 20 + 20, the last removed at 02:16:12), the smoke's all-codes role
(roles 1 + 1, role_permissions 72 + 72) and its contract probe (contracts 2 + 2 and its six term tables) — **except one `cod_verification_failures`
rotation** (1 delete + 1 insert at 02:00:14, the smoke's COD check). That rotation is the only net change, and it is what moves the digest: the three
public tables with no change-log trigger (`festival_doodles`, `home_greetings`, `notification_reads`) show 0 rows written or read after 00:47. **The
rolled-back proof left nothing:** no change-log row falls inside 02:16:37–02:17:52. The migration itself writes no table row.

### §7.2 · Proof (`db/scripts/2026-10-05-at1d3-live-proof.sql`, one transaction, ROLLBACK; `PROOF_OWN_EXIT=0`, 02:17:41 → 02:17:52 CST)

- **A** (read-only, as admin@): *"32 records read as admin@, none refused, every one with its creation; 40 pre-log row(s); nothing twice"* — the payroll
  period, every review cycle and review (0 on live), every KPI entry (30) and the rating scale.
- **B** (rolled back): *"payroll PAY-2026-0002 saved and re-saved, attendance ATT-2026-09 opened, cycle opened and closed, review of Choo Er approved, a
  rating changed"*:
  - admin@ recorded a payroll period for 09/2026 with two lines (Choo Er, Fu Sheng), then re-saved it with Choo Er unchanged and Fu Sheng changed (Q11);
  - admin@ opened that month's attendance;
  - admin@ created, opened and closed a review cycle ("ZZ AT1D3 proof cycle"; opening made one review per active employee — Q6);
  - on Choo Er's review admin@ named Fu Sheng the reviewer, added a goal and wrote the conclusion; fusheng@ submitted it, and admin@ approved it (Q7);
  - admin@ changed the "Meets Expectations" description;
  - trails were read as admin@ (period, cycle, scale, review), vince@ (gm: hr.view and view_reviews, no view_pay — the period and the review),
    fusheng@ (the reviewer's `my_review`: readable, the approval rows not — Q5) and chooer@ (the reviewed employee: refused `my_review` — M12);
    fusheng@ is also refused the HR subject `performance_review`.
  - My first run stopped on my own setup assertion and rolled back whole (`PROOF_OWN_EXIT=3`, 02:16:37): I had picked 08/2026, and Fu Sheng was hired
    on 01/09/2026, so August's attendance has no line for that employee ("0 / 1"). I moved the proof to 09/2026, which has no payroll or attendance
    period on live either (asserted inside the proof), and reran it.
- **Q19** (in B, as fusheng@ — the only real account without `module.hr.view`): *"/me reads 1 own attendance line(s) and 1 payslip(s);
  my_period_labels() gives attendance ATT-2026-09 2026-09-01 · payroll PAY-2026-0002 2026-09-01; the period tables read directly: 0 rows"*.
  1d-2 measured the same identity reading 0 of their periods; the code and month now arrive, and nothing else of the period does. The known issue is closed (§10).
- **Render** (scratchpad `render-proof-1d3.mjs`, the production renderer over the proof's rows): `RENDER_OWN_EXIT=0` — *"records 39 · entries 44 ·
  machine tokens 0"*. Read as admin@:
  - "Payroll recorded · 2 people" — Month 01/09/2026, Payment date 30/09/2026, Currency SGD, Gross total 7,200.00 SGD, Net total 5,760.00 SGD, Source;
  - "Annual review opened (cycle ZZ AT1D3 proof cycle)" — Employee Choo Er, the period, Reviewer Fu Sheng — then "[Review approved] Rating: Meets
    Expectations" and "[Goal added · ZZ AT1D3 close the month on time] Target 12 · Unit months";
  - "Review cycle created · ZZ AT1D3 proof cycle" with "[Review cycle closed · …]";
  - "Rating changed · Meets Expectations — Description (English): … → … (ZZ AT1D3 proof)", above the pre-log "Rating added" block for all four ratings.

  Read as vince@: the same period and review (pay totals shown — the page's own rule, Q18 in UNBLOCK-1). Read as fusheng@ on `my_review`: "Employee:
  Restricted" and "Part of this change is restricted." (the approval rows withheld — Q5); the employee-name difference from the reviewer page is
  registered (`AT1D3-REVIEWER-PAGE-NAMES-VS-TRAIL`).
- **What is a proof artifact, not a product defect:** one transaction is one operation, so the re-save folds into "Payroll recorded" (its totals show
  the re-saved figures), the cycle's opening folds into its creation, fusheng@'s submission folds into the approval, and the folded entry carries one
  actor (fusheng@'s read shows "Fu Sheng" for it, admin@'s shows "Tim"). In the product these are separate operations; fixture 246 PP · CY · RV and arm
  ⑬'s goldens pin each one separately ("Payroll changed · Line · <name> · Gross pay a → b", "Review cycle opened", "Review submitted"). The pre-log
  "Rating added" block showing today's description is the registered pre-log rule (`AT1A-PRELOG-SHOWS-TODAYS-VALUES`), seen here because the change
  was made inside the same transaction.

### §7.3 · Broken window

- **Start: 2026-10-05 01:14:31 CST** (`apply_migration.sh`'s commit line, also in `db/migration-windows.tsv`).
- **End: supplied by Tim** — the moment the Vercel deployment of this commit reads Ready. This machine does not query the deployment (AGENTS.md); the
  close-out of the next cut records it.
- **What is broken inside it: nothing, by construction (inferred from what the migration changed, not observed on production).** The migration
  adds six subjects and their registry rows, extends the pre-log, reference-label and row-record functions with rows for tables no old page asks about,
  and adds `my_period_labels()`, which the old app never calls. The old `/me` keeps reading the period tables directly, as it did before (the Q19
  gap stays visible until the deploy, as it was).
- **Visible early:** a reference to a review, a payroll request or a KPI entry in an existing trail would read with its new label before the
  deploy; live has 0 reviews and 0 payroll requests, so none can appear.

## §8 · New wordings and labels

### §8.1 · Event wordings (English; `lib/trail/text.ts`, 57 new keys)
- **Payroll period:**
  - `prl.recorded` "Payroll recorded" (+ " · {n} people" — `prl.people.one` "1 person" / `prl.people.many` "{n} people")
  - `prl.changed` "Payroll changed"
  - `prl.posted` "Payroll posted" · `prl.unposted` "Payroll unposted"
  - `prl.salariesPaid` "Salaries paid" (+ " · {n} people") · `prl.cpfPaid` "CPF paid" · `prl.deductionsPaid` "Deductions paid"
  - lines: `prl.journal` "Journal" · `prl.reversalJournal` "Reversal journal"
  - pay lines (Q11): `prl.lineHeading` "Line · {name}" (a changed figure reads "Line · <name> · Gross pay: a → b") · `prl.lineAdded` "Line added · {name}" ·
    `prl.lineRemoved` "Line removed · {name}" · `prl.linesRestricted` "Pay lines · {people}" (with "Restricted") · `prl.linesSaved` "Pay lines saved"
- **Posting and unposting requests** (the page's "Request posting" / "Request unposting"):
  - `prl.sentPost` "Payroll posting sent for approval" · `prl.sentUnpost` "Payroll unposting sent for approval"
  - `prl.approvedPost` "Payroll posting approved" · `prl.approvedUnpost` "Payroll unposting approved"
  - `prl.rejectedPost` "Payroll posting rejected" · `prl.rejectedUnpost` "Payroll unposting rejected"
  - `prl.withdrawnPost` "Payroll posting request withdrawn" · `prl.withdrawnUnpost` "Payroll unposting request withdrawn"
  - `prl.requestChanged` "Payroll request changed"
  - `prl.ownLine` "This period includes the approver's own pay line: {code}" (Q10, the stripped suffix said in English)
- **Reviews** (Q6 · Q7 · Q35):
  - `rv.openedAnnual` "Annual review opened (cycle {cycle})" · `rv.openedAnnualNoCycle` "Annual review opened" · `rv.openedProbation` "Probation review opened"
  - `rv.openedForSelf` "Opened for self-assessment" · `rv.selfReopened` "Self-assessment reopened" · `rv.selfSaved` "Self-assessment saved" ·
    `rv.selfFinalised` "Self-assessment finalised"
  - `rv.submitted` "Review submitted for approval" · `rv.approved` "Review approved" · `rv.acknowledged` "Review acknowledged by the employee" ·
    `rv.voided` "Review voided"
  - `rv.reviewerChanged` "Reviewer changed" · `rv.conclusionChanged` "Review conclusion changed" · `rv.hrDecisionChanged` "HR decision changed" ·
    `rv.changed` "Review changed"
  - goals: `rv.goalHeading` "Goal {n}" · `rv.goalAdded` "Goal added" · `rv.goalChanged` "Goal changed" · `rv.goalRemoved` "Goal removed"
- **Review cycles:** `rcy.created` "Review cycle created" · `rcy.opened` "Review cycle opened" · `rcy.closed` "Review cycle closed" ·
  `rcy.changed` "Review cycle changed" · `listTrail.intro.reviewCycles` "Review cycles · newest first · Singapore time"
- **KPI entries:** `kpe.generated` "KPI entries generated · {n}" · `kpe.generatedOne` "KPI entry generated" · `kpe.scored` "KPI scored: {score}" ·
  `kpe.rescored` "KPI re-scored: {from} → {to}" · `kpe.changed` "KPI entry changed" ·
  `listTrail.intro.kpiEntries` "KPI entries for this month · newest first · Singapore time"
- **Employee page (approve_review's other note):** `emp.noteReviewSalary` "Changed through a performance review"
- **Rating scale** reuses the dictionary wordings: "Rating added / changed / deactivated / reactivated" (the table noun is "rating").
- **Reused:** "Approved automatically (approvals were switched off)" (`po.autoApproved`); "Payroll journal posted" (`je.posted.payroll`, for a payroll
  journal whose step cannot be read from structure); the void banner "Voided on DD/MM/YYYY by <name>" (`banner.voided`).

No new `messages/en.ts` / `zh.ts` keys; two deleted (`hr.payrollRequest.history`, `reviews.voidBanner`).

### §8.2 · Field labels on the tables 1d-3 first shows (`scripts/gen-trail-catalogue.mjs` OVERRIDES)
- **payroll_periods:** Payroll number · Month · Payment date · Currency · FX rate · Status · Gross total · Employer CPF total · Employee CPF total ·
  Deductions total · Net total · Journal · Source · Notes · Deleted on · CPF paid on · CPF journal · Deductions paid on · Deductions journal.
  `code` is hidden (it is on the page header).
- **payroll_lines:** Payroll period · Employee · Gross pay · Employer CPF · Employee CPF · Deductions · Net pay · Notes · Paid on · Payment journal
- **payroll_requests:** Payroll period · Request (kind: "Post" / "Unpost", the page's own words) · Status · Currency · FX rate · Gross total ·
  Amount (base currency) · Reason · Decided on · Decided by · Decision notes · Withdrawn on · Withdrawn by · Carried out on · Carried out by · Journal.
  `label` (raw kind, Q10) and `snapshot` (JSON) are hidden.
- **performance_reviews:** Employee · Review type · Cycle · Period start · Period end · Reviewer · Status · Rating · Written summary · Self-assessment ·
  Probation outcome · New monthly salary · Effective from · Submitted on · Submitted by · Approved on · Approved by · Acknowledged on ·
  Reason for voiding · Voided on · Voided by · Notes · Self-assessment finalised on
- **review_goals:** Review · Objective · Employee result · Reviewer assessment · Target · Actual · Unit. `sequence` is hidden ("Goal N" says it).
- **review_cycles:** Name · Period start · Period end · Due date · Status · Notes · Deleted on
- **review_rating_scale:** Name (English) · Name (Chinese) · Description (English) · Description (Chinese) · Active · Usually passes probation · Notes.
  `sort_order` is hidden.
- **kpi_entries:** Month · Employee · Position · KPI · Title · Weight % · Target · Measurement / evidence · Provisional target · Why provisional ·
  Supports organization KPIs · Score (0–5) · How it was scored · Computed from · Evidence · Scored by · Scored on · Safety / regulatory cap ·
  Reason for the cap · Feedback. `org_codes`, `source_template_id` and `source_template_version` are hidden.
- **kpi_cycles** (Q33 · Q34, named in the brief): Name · Period start · Period end · Due date · Status · Gate · Notes · Deleted on · Locked on · Locked by
- **Table names (in sentences):** payroll period · pay line · payroll request · review goal · review cycle · rating · KPI entry · KPI month
- **Kinds corrected:** `review_goals.unit`, `kpi_entries.computed_basis` and `evidence_source` are typed text (they were read as enum-like).

### §8.3 · English for enumerated values (Q34)
- **`kpi_cycles.status`:** Draft · Open · Closed. **`kpi_cycles.gate`:** Month 3 gate · Month 6 gate.
- **`kpi_entries.score_kind`:** Judged · Computed.
- **Already had English** (from the pages' own option labels, unchanged): payroll period status (Draft · Posted), payroll request kind (Post ·
  Unpost) and status (Waiting for approval · Approved · Rejected · Withdrawn · Done), review type, review status, probation outcome, review cycle status.

## §9 · Decisions taken without asking

1. **KPI scoring is registered as a pre-log stamp (`kpi_entries.scored_at/scored_by` with score and kind).** Step 0's Q12 list gave 1d-3 two stamps
   (payroll request withdrawal, review void); scoring has the same property — it writes nothing else and a re-score overwrites it — so it is the only
   record of that scoring before the log. Fixture 246 KP pins it; the injection that drops it goes red.
2. **Two stamps are deliberately not registered:** the pay lines' `paid_at` (the salary journal's own creation says "Salaries paid") and
   `self_assessment_submitted_at` (reopening clears it, and it records no person).
3. **A re-save read without `data.view_pay` says one line, "Pay lines · N people: Restricted".** Whether a person's line changed is itself pay data
   (both sides are masked), so the renderer does not guess per person; notes changes, which are not masked, are still said per line.
4. **The period's journals are named by structure, never by their memo** (the period's journal columns, the lines' `paid_journal_entry_id`, the
   requests' `result_journal_entry_id`, the page-wide reversal set). A payroll journal whose step cannot be read that way says the 1c-3 sentence
   "Payroll journal posted · JE-…".
5. **A journal's number is shown only to a reader who can see that journal.** In "Payroll posted" / "CPF paid" / "Payroll unposted" the
   "Journal: …" line reads "Restricted" when the journal row is hidden from the reader — the payroll page's own header rule
   (`hr.payrollEntryRestrictedHint`), not a new one.
6. **The approver's-own-pay-line suffix (Q10) is stripped and said again in English** as its own line ("This period includes the approver's own pay
   line: EMP-…"), not dropped: it carries a fact the approval record is meant to keep.
7. **A payroll request's `label` is hidden; elsewhere a request is named "PAY-… posting request" / "unposting request".** Q10 said "the label
   without its kind"; the period code alone would read as the period itself, so the kind is said in English instead of as the raw token.
8. **The request kind's value labels stay the page's words, "Post" / "Unpost"** (they already came from `hr.payrollRequest.kind`); I first wrote
   "Posting / Unposting" and took it back (Q35).
9. **"Payroll recorded" lists the month, payment date, currency, totals and source, and counts the people — not each person's line.** A creation
   with a dozen lines would otherwise be a dozen lines long; the lines are on the page.
10. **Before the log, "Review approved" states the outcome from the review as it is today.** The approval row is the only pre-log record of the
    approval, and the outcome columns are frozen once submitted (`guard_performance_review_write`), so today's values are that day's values.
11. **A review's name in references is its type and period ("Annual review 01/01/2026–31/12/2026")** — never the employee's name, which would
    bypass the ActorName rule (`trail_ref_label`).
12. **The void banner on `/hr/reviews/[id]` became the shared `EndedBanner`** ("Voided on DD/MM/YYYY by <name>", reason on a second line,
    English like every banner — Step 0 §f). It replaced the bilingual "Voided: {reason}" message (key deleted). `/my-reviews/[id]` had no void
    banner and still has none.
13. **The KPI block is drawn only in the branch where scores are visible**, over the chosen month's entries, each labelled "<employee code> ·
    <KPI>" (the leave-grants precedent: codes, not names). A reader without `data.view_reviews` already sees the page's named "Restricted".
14. **The review-cycle block reads every cycle (up to 200), deleted ones included** — the list-block precedent ("removed" is part of a record).
15. **Q19's fix is a SECURITY DEFINER function, not a self-read policy.** A policy admits the whole row (a period total is one person's pay when
    a period has one line — Q18). Status (attendance) and currency (payslips) are still read directly and stay empty for an employee without
    `module.hr.view`; the currency half is registered (`AT1D3-ME-PAYSLIP-CURRENCY-NEEDS-HR-VIEW`) because the brief said "code and month only".
16. **The migration grants `my_period_labels()` explicitly** (REVOKE from PUBLIC and anon, GRANT to authenticated and service_role) so that its
    own proof can check the rights before `apply_migration.sh` replays `zzz_function_grants.sql`; the end state is the same as the replay's.
17. **approve_review's salary sentence is now recognised on the employee page too** ("Changed through a performance review"). 1d-1 recognised only
    the probation sentence; the salary one would have printed a uuid as a note. A renderer fix outside the 1d-3 pages, pinned by a ⑬ golden.
18. **Two message keys were deleted with the sections they served** (`hr.payrollRequest.history`, `reviews.voidBanner`) rather than left dead.
19. **The smoke checks `/my-reviews/[id]`'s trail inside its reviewer-session request**, not through `MUST_CONTAIN`: the admin pass gets 404 there
    by contract.
20. **`/hr/kpi/score` is not in the smoke's `MUST_CONTAIN`.** The smoke opens it without `?cycle=`, where the block is absent by design (no default
    month). The probe opens every month that has entries.
21. **Q19 at page level is proved by identity, not by a page load.** A throwaway account has no employee record, and giving it an attendance line
    or a payslip means writing a month of attendance or payroll on live. The rolled-back proof reads, as fusheng@ (the real warehouse account), the
    same rows `/me` reads and `my_period_labels()` (§7.2); the probe asserts from source that `/me` carries only the three own-request trails.
22. **The live proof makes its own payroll period and review rather than editing existing ones.** PAY-2026-0001 is posted (a save is refused) and
    has one line; there is no review on live. Both are made, changed and approved inside the rolled-back transaction, for a month (09/2026) that has
    neither a payroll nor an attendance period on live. The approved review carries no new salary: no live employee has a salary, and approving one
    would write the employee row.
23. **The live proof changes one rating's description** (a setting, as the brief asked); the after-reading shows it back to its old value.
24. **Two fixes to `scripts/survey-phone.mjs` for addresses with a query string.** The `--paths=` parser split on `=`, which cut
    `/hr/kpi/score?cycle=<id>` to `/hr/kpi/score?cycle` and would have measured a different page; and its "where did we land" reading took the
    pathname only, so the KPI address was filed as "redirected" to itself and left the denominator (first survey pass). It now compares pathname +
    query. Tool fixes, made after the build; the lint freeze and every static check were rerun (`LINT3_OWN_EXIT=0`, `STATIC2_OWN_EXIT=0`) and the KPI
    page was measured in a second pass.
25. **Fixture 246's stamp-actor assertions accept any recorded account** ("not Not recorded"): the fixture's acting account has no person, so it
    reads "An account with no person linked" — still a recorded actor, which is what Q12 asks.
26. **KPI generation lines read "F1: Stocktake accuracy (30%)"** — the reference as the label, the copied title as typed text.
27. **The rating scale's table noun is "rating"** ("Rating added · Outstanding"), the Step 0 §h suggestion.
28. **The wording prefixes are `prl.` / `rv.` / `rcy.` / `kpe.`** — `pay.` belongs to payments, and `payroll.` / `reviews.` / `kpi.` are message namespaces
    that check-i18n would read as interface keys (the 1d-2 `dictv.` reasoning).
29. **The Q38 side finding "a closed review cycle can be reopened" was measured false and struck** in `docs/known-issues.md`
    (`open_review_cycle` raises `CYCLE_CLOSED`).
30. **The 1d-3 window start in `docs/forward-queue.md` is filled from `db/migration-windows.tsv`** (01:14:31 CST); its end is Tim's, at the next close-out.

## §10 · Known issues and queue

- `docs/known-issues.md`:
  - `AT1D1-ME-READS-HR-ONLY-PERIOD-TABLES` (**Q19**): **closed** — fixed by `my_period_labels()`, read back as fusheng@ (§7.2); kept as a dated record.
  - `AT1D1-MACHINE-TEXT-IN-HUMAN-COLUMNS`: the payroll decision suffix, the unpost note, the automatic-approval note, the request label and
    approve_review's salary sentence are now recognised; the writers are unchanged.
  - `AT1D1-STEP0-SIDE-FINDINGS`: the "closed cycle can be reopened" inference measured false (struck).
  - New: `AT1D3-ME-PAYSLIP-CURRENCY-NEEDS-HR-VIEW` (payslip amounts carry no currency for an employee without hr.view — Tim to choose);
    `AT1D3-REVIEWER-PAGE-NAMES-VS-TRAIL` (the Q20 shape on `/my-reviews`).
- `docs/forward-queue.md`: item 31 records 1d-2's window; item 32 records this cut (window start 01:14:31 CST, end at the next close-out);
  ✅ AT-1d-3, ✅ AT-1d, ✅ "AUDIT-TRAIL 的后几刀" = AUDIT-TRAIL-1 complete as `v1.4.33`; DATE-PICK-1 marked next as `v1.4.34`.
- `docs/change-log.md` §9: the intro (1d-3 and "That completes AT-1d, and with it AUDIT-TRAIL-1 (v1.4.33)"), six table rows, M11's and M12's users,
  and the new §9.16.

**Not done here, by the brief:** DATE-PICK-1; UNBLOCK-1 (the payroll-journal leak and the privacy group Q16 · Q17 · Q18 · Q30).

