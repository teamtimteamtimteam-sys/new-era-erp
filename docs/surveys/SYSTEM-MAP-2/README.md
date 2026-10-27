# SYSTEM-MAP-2 — Step 0 readings (2026-10-27, before any build)

Brief: "SYSTEM-MAP-2 — My workbench: one list of what is waiting for the reader". Started from `b8a4beac1423f3231d80122ced97ec641766470e` (HEAD = origin/main).
**Identity of every reading:** live reads as `postgres` (`rolbypassrls`) on base tables and the catalog (`readings/live-*.sql` beside their `.txt`); the reconciliation line as tim@ (`cfo`) in a rolled-back transaction;
production pages through one throwaway cfo clone (`sm1probe`, shared helper, GET + opening menus only). Code reading: two sub-agents, each brief carrying the LIVE SAFETY section verbatim, **neither connected to live** (code only);
six of their citations re-read by this session and matched (`approval_pending_documents.sql:74`, `approve_purchase_order.sql:53-55`, `ClaimDecisionPanel.tsx:190-195`, `requestRows.ts:22-23`, `decide_overtime_batch.sql:28`, `approval_deciders.sql` header).

## Part 1 — SYSTEM-MAP-1 close-out
- Production: `db/scripts/2026-10-27-system-map-1-closeout-prod-check.mjs` → **`SM1_CLOSEOUT_EXIT=0`, 4/4** (`readings/sm1-closeout-prod-check.txt`): bar = 9 buttons, Workbench first (v1.4.76 has no such bar → production serves b89219c/b8a4bea);
  People › Claims → `/claims`, 5 rows (database 5); avatar menu identity · Notifications · settings · language · Log out — no /me, no /my-reviews. Only menus opened.
- Read-back (`readings/readback-part1.txt`, `READBACK_OWN_EXIT=0`): 7 users / 7 enabled, **0 throwaway users**, 0 probe roles, 0 orphan grants, roles admin·cco·cfo·cto·finance·gm·warehouse, 1 active cfo grant,
  approvals ON finance/cfo/1000, `require_calibrated_since` NULL, 2 CODs, AP 0.00 / AR 0.00 unexplained.

## 0.2 · Every decision type today

Roles = live roles whose codes and approval level pass the gate (rows 13–14 corrected in Step 1: admin holds `action.approve_review`, so it decides both — fixture 295's matrix measured it; the Step 0 report said cfo only) (`readings/live-survey.txt` role_codes; level 1 = finance + cfo by APR-ROUTE-1 R1, level 2 = cfo). Four-eyes (`forbid_self_approval` / `self_leg`) applies per document on top. "bulk" = `BulkDecisionBar` / `BulkScopeBar` today. Live pending = `readings/live-pending.txt`.

| # | type | waiting row | gate (file:line) | decided on | roles | bulk | live pending |
|---|---|---|---|---|---|---|---|
| 1 | purchase-order approval | `purchase_orders.approval_status='pending'`; since = approval_log 'submitted' / 'approval_voided' | `approve_purchase_order.sql:12,28,53-55` (tier at 1,000) · reject `reject_purchase_order.sql` | `/purchasing/orders/[id]` | finance < 1,000 · cfo | none | 0 |
| 2 | general expense claim | `expense_claims.status='submitted'`, `submitted_at` | `decide_expense_claim_items.sql:89-90,117-128` | `/finance/claims#claim-<id>` | finance < 1,000 · cfo | reject only | **1** |
| 3–12 | the ten CFO-level requests: payment · payroll · receipt price · invoice · shipping release · journal · warehouse · terms · asset disposal · GST filing | `<x>_requests.status='submitted'`, `created_at` | `require_approver_for(2)` in each `decide_*` (e.g. `decide_payment_request.sql:55`) | parent pages; journal/warehouse/terms/asset cards carry `jr-`/`wr-`/`tr-`/`adr-` ids | cfo | approve+reject: journal, warehouse, terms, asset disposal | 0 each |
| 13 | salary change | `salary_change_requests.status='submitted'` | `decide_salary_change_request.sql:34-35` (`pay_decision_code`) | `/hr/employees/[id]` | admin · cfo (cco when the cfo is a party) | none | 0 |
| 14 | performance-review approval | `performance_reviews.status='submitted'` | `approve_review.sql:24` (`review_approval_code`) | `/hr/reviews/[id]` | admin · cfo (cco when the cfo is a party) | none | 0 |
| 15 | overtime batch | `overtime_batches.status='submitted'` | `decide_overtime_batch.sql:28` | `/hr/overtime/[id]` | admin · warehouse | none | 0 |
| 16 | leave | `leave_requests.status='pending'` | `decide_leave_request.sql:18` | `/hr/leave/[id]` | admin · cco · cfo · finance | none | 0 |
| 17 | medical claim | `medical_claims.status='submitted'` | `decide_medical_claim.sql:9` | `/hr/claims/[id]` | admin · cco · cfo · finance | none | 0 |
| 18 | NCR disposition | `nonconformance_reports.status='open'` | `decide_ncr.sql:28` | `/quality/ncr/[id]` | admin · cco · cto | none | 0 |
| 19–20 | work-order / blending-plan release | `status='draft'` | `release_work_order.sql:57`, `release_blending_plan.sql:20` | own pages | admin · finance | none | 0 |
| 21 | supplier approval | `suppliers.status='pending_review'` | `set_supplier_status.sql:53` | `/suppliers/[id]/edit` | admin · cfo | none | 0 |
| 22 | capture draft | `capture_drafts.status='pending'` | `confirm_capture_draft.sql:17` | `/operation/capture` | admin · cto · warehouse | reject only | 0 |
| 23 | stocktake post | `stocktakes.status='open'` (= still counting) | `post_stocktake.sql:68` | `/stocktakes/[id]/review` | admin · finance | none | **6** |
| 24 | portal certificate submission | `portal_certificate_submissions.status='submitted'` | `portal_submission_accept.sql:23` | `/suppliers/[id]/edit` | admin · cco · cto · finance · warehouse (+ procurement, unheld) | none | 0 |
| — | pay an approved payment request (not a decision) | `payment_requests.status='approved'` | `pay_payment_request.sql:38` (`module.finance.edit`) | `/finance/payment-requests/[id]` | admin · finance | none | 0 |

The "can decide this document" rule already exists once for 16 of these: `approval_pending_documents()` (types 1–14 minus review, plus overtime) × `approval_deciders()` / `approval_chain_gates()` / `salary_change_deciders()` (APR-ROUTE-1).

## Reminders today (`lib/reminders.ts`, `db/views/operations_arms_all.sql`, 72 arms)
Approval arms gate on a read code, not the decide gate: the ten CFO-level arms on finance / sales / pricing view, `data.view_pay`, `data.view_purchase_prices`, so admin · cco · cto · finance · gm see them and only cfo decides (SYSTEM-MAP-0 §3.2).
No arm: PO approval, general expense claims, overtime, WO / blending release, **portal certificate submissions** (new in this survey). Exceptions arms (expiring, overdue, stock…) are company-wide by read code. Pinned by fixtures 111 (72-name list), 30, 47, 273 and `scripts/check-reminder-arms.mjs`.

## Notifications
`notifications` (`db/tables/notifications.sql`) has **no recipient column**: rows are events shown to whoever holds the module code of `subject_type` (material → materials.view, storage_location → inventory.view); unread = no row in `notification_reads` for the reader.
Two writers, both inventory: `notify_landing_warnings`, `notify_class_violations`. Live: 2 rows (both landing warnings), 7 read marks. No approval writes one.

## Supplier-certificate rule
Reminder `qualification_expiring` (`operations_arms_all.sql:338`): `disposition <> 'ignore' AND valid_until <= CURRENT_DATE + warn_lead_days`. Receiving block (`supplier_receiving_blocked.sql:17`): `disposition='block' AND valid_until < CURRENT_DATE`.
Live: 9 certificate types (6 block / 3 warn / 0 ignore), 1 certificate (block, 126 days left).

---

# Step 1 — build readings (2026-10-27, v1.4.78, after Tim's rulings Q1–Q7)

**Identity of every reading:** local rebuild for the fixture, the fault injection and the bulk proof (`python3 db/verify_rebuild.py --skip-diff` into a cluster on a unix socket);
live as `postgres` for counts on base tables and for the dry run (rolled back); the live proof read the database as each throwaway reader (`SET LOCAL ROLE authenticated` + that
account's claims, every transaction rolled back) and its pages through `next start` on this tree against live. **No sub-agent connected to live or to the local rebuild** (the two
Step 0 sub-agents read code only; none was started in Step 1).

## Verify chain (each verdict is the script's own exit line)

| # | step | reading |
|---|---|---|
| 1 | offline gate | `GATE_EXIT=0`, 141 s (`readings/gate-offline.txt`) — fixture 295 ✓ |
| 2 | backup | `BACKUP_EXIT=0`, 16:25:41 → 16:48 CST, `evoltrya-backup-2026-10-27-1625.dump` + 20 change_log chunks (89,360 rows = count) (`readings/backup.txt`) |
| 3 | live dry run | `DRY_OWN_EXIT=0`: 9 new functions, 78 branches, 22 approval branches, `purchase_order_status.approval_status`, grants (self_approval_allows revoked; waiting_for_me authenticated-only; the new view SELECT-only), tim@ (cfo) to-do 5 → ROLLBACK → 0 new functions left (`readings/dry-run.txt`) |
| 4 | apply | `APPLY_OWN_EXIT=0`; pre-flight: 1 replaced + 9 new functions; **broken window opens 2026-10-27 17:04:48 CST** (`readings/apply.txt`, `db/migration-windows.tsv`) |
| 5 | types | `TYPES_OWN_EXIT=0` (regenerated from live; +143 lines) |
| 6 | tsc · build | `TSC_OWN_EXIT=0` · `BUILD_OWN_EXIT=0` (`readings/tsc.txt`, `readings/build.txt`); single-home 141 entries |
| 7 | full gate | `GATE_EXIT=0`, 766 s, every verdict ✓ (`readings/gate-full.txt`) |
| 8 | i18n · error-swallowing | `I18N_OWN_EXIT=0` · `SWALLOW_OWN_EXIT=0` |
| 9 | layout survey | `/workbench` `/` `/tools/reminders` `/purchasing/orders` `/finance/payment-requests` `/compliance/supplier-certificates`: **390 px 6/6 at 0 overflow, 0 clipped; 1280 px 6/6 at 0 / 0**; the four list pages each drew 1 table (`/workbench` included), `/` and `/tools/reminders` have none by design (`readings/layout-*.txt` / `.json`) |
| 10 | smoke | `SMOKE_EXIT=0`: 342 routes (+1: `/workbench`) + probes, 343 ok, 25 skipped (no data), 0 failed (`readings/smoke.txt`) |
| 11 | live proof | `SM2_PROOF_EXIT=0`, **92 PASS, 0 FAIL** (`readings/live-proof.txt`, `.json`) |
| 12 | read-back | `READBACK_OWN_EXIT=0`: 7 users / 7 enabled, roles admin·cco·cfo·cto·finance·gm·warehouse, **1 active cfo grant**, 0 throwaway users / roles / orphan grants, approvals ON finance/cfo/1000, `require_calibrated_since` NULL, reconciliation AP 0.00 / AR 0.00 (`readings/readback.txt`) |
| 13 | COD bytes | `COD_OWN_EXIT=0`: 34,701 `ba299a4f…f42101` · 34,746 `717661f6…13a4f9` = AGENTS.md baseline = `cod_issues.sha256` (`readings/cod-bytes.txt`) |
| 14 | fresh clone, no `.env.local` | see the end of this file |

## Fixture 295 — 24 types × the seven live roles (local rebuild, every cell rolled back)

189 cells (7 roles × 27 documents: 23 approval kinds + approved-to-pay, expense claims at both tiers and the two self-exception claims): **shown on `waiting_decisions()` ⇔ the real
decide function accepts it, in every cell.** Arms: N (every kind decidable by someone) · R (the raiser, given admin's codes and the cfo role, is never listed and is refused
`SELF_APPROVAL_FORBIDDEN`; for the approved payment the supplier's creator is refused `SOD_PAYEE_AND_PAY` and not listed — this arm found that rule, now in `waiting_decisions`) ·
X (R2 self exception both ways) · S (no open stocktake listed) · O (Reminders approval rows = the reader's to-do rows, both directions) · C (home count = rows) · T (tasks, reviews,
notifications) · **B (bulk, local only): cfo rejects every bulk-capable row one at a time — 8 done, his own request refused `SELF_APPROVAL_FORBIDDEN|raiser`, the rest unaffected;
cto rejects the capture draft.** Per-role decisions in the matrix: admin 12 kinds, cfo 17 (incl. both claim tiers), finance 8, cco 4, cto 3, warehouse 3, gm 0.
**Fault injection** (`readings/fixture-295-injection.txt`): `decision_gate_code('medical_claim')` widened to `module.hr.view` → `INJECTED_FIXTURE_EXIT=3`, naming cto and gm on
medical_claim; restored → `CLEAN_FIXTURE_EXIT=0`. Five existing fixtures followed the ruling: 30 / 47 (an all-codes reader no longer sees three approval branches it cannot
decide), 111 (78 branch names), 225 / 229 (the raiser no longer sees its own request on Reminders; the CFO does).

## Live proof — per role (live test data: 1 submitted expense claim ≥ 1,000, 2 notifications, 6 open stocktakes, 2 open tasks of real employees)

| role (throwaway) | to-do rows = home count | rows | CFO-level kinds decidable | Reminders: CFO-level branches "decided by the CFO-level approver" |
|---|---|---|---|---|
| admin (clone) | 2 | 2 notifications | 0/10 | 10/10 |
| cfo (realRole) | 3 | the expense claim + 2 notifications | **10/10** | 0/10 (cfo decides them) |
| cco (realRole) | 2 | 2 notifications | 0/10 | 10/10 |
| cto (realRole) | 2 | 2 notifications | 0/10 | 9/10 (the 10th needs a read code cto lacks: shown with its code) |
| finance (realRole) | 2 | 2 notifications (the claim is ≥ 1,000: CFO level) | 0/10 | 10/10 |
| gm (realRole) | 2 | 2 notifications | 0/10 | 9/10 |
| warehouse (realRole) | 1 | 1 notification (inventory only) | 0/10 | 1/10 (the rest need read codes it lacks) |

Every row matches the survey table's expectation computed from the pending documents (no pending document was raised by a throwaway); no stocktake on any list; the expense-claim
Reminders branch is "waiting" exactly where the claim is on the to-do list (cfo); `/workbench` drew the same rows, each linked; cfo's claim row has a checkbox and the bulk bar
offers **Reject only**; nothing was pressed; `/workbench` at 390 px no sideways scroll for all seven. The two open tasks belong to real employees, so no throwaway lists them
(task rows are proven in fixture 295 T). CFO-level requests: **0 pending on live**, so "appear for cfo only" is proven on live as reach (10/10 vs 0/10) and on the rebuild as rows.

## Assertions in the brief measured false, or not measurable
1. Step 0's table said salary change and review approval are decided by cfo (cco when cfo is a party); the matrix measured **admin too** (it holds `action.approve_review`) — corrected above.
2. Bulk approve on the to-do page is not proven with live data: live holds 0 journal / warehouse / terms / disposal requests; fixture 295 B proves the reject path locally; approve goes through the same single-item actions TF-3 proved.
3. "the open tasks" per role (Q7): the two open tasks on live belong to real employees; throwaway readers have none (shown as 0 task rows), so task rows are proven in fixture 295 T.

## Fresh clone and the final tree
Fresh clone of `2e0d0477126b5573faa8718606d617f1b6ff4bc8`, no `.env.local`, `npm ci && npm run build`: **`FRESH_OWN_EXIT=0`** (`readings/fresh-clone-build.txt`).
The full gate (`GATE_EXIT=0`, 766 s) ran on the same code: nothing but readings and this README changed after it (no code, mirror, migration or fixture).
The only change after that clone is this section and that log (docs only).
