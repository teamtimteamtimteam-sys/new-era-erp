v1.4.36 — Workflow fixes: lines can now be added to a shipped sales order; a wrongly entered downtime period can be corrected or voided; purchase-order close and reopen reasons are kept in their own fields; the deep-discharge judgement on a purchase order can be saved; a processing run can record the machine used; the forwarder rates table always shows Remove; the KPI scoring page folds targets away until needed; and payroll reversal requests and leave records follow the same privacy rules as the rest of payroll and leave.

# U1-B — workflow fixes and the remaining leaks (UNBLOCK-1, second cut; 2026-10-05 → 06)

Tim answered UNBLOCK-1 Step 0 on 2026-10-05: every recommendation for Q14–Q25 accepted as stated
(`docs/surveys/UNBLOCK-1/STEP0-HANDBACK.md`), plus three items added at the U1-A close-out and MES-0 Q1 (the shared
throwaway-account helper). This cut builds all of them. **UNBLOCK-1 is closed. The next cut is MES-1.**

**Opening check:** this session's first command printed **2026-10-05 19:54:21 CST**. After `git fetch`: `HEAD` = `origin/main` =
`git ls-remote origin main` = **`4995f49b031e1e45c59e8bbef67ab855954479e1`**, the commit that pushed `docs/surveys/MES-0/README.md`
("MES-0: survey for the MES/MOM function group (stop gate)"). The tree was clean. Files were staged by explicit path only.

**Live state, before and after:** approvals ON (`finance` / `cfo` / 1,000) throughout; the 7 accounts enabled throughout, with the
same role each; one pending document before and after (CLM-2026-0004, decider tim@). No real auth account was created, disabled or
deleted. Harness throwaway accounts were created and reaped; §5 has the read-backs.

Every figure below is a script's own exit line or a query named with who ran it. "As postgres" means psql or the Management API as
`postgres` (`rolbypassrls = true`), reading base tables. Working logs are in `~/u1b-work/logs/` (outside the repo).
The session paused overnight at Tim's request (2026-10-05 21:05 → 2026-10-06 09:11); the migration was already applied, so the
broken window spans the pause (§5.1).

## §0 · Step 1 — Tim's MES-0 answers (docs only)

- `docs/surveys/MES-0/README.md` §12: "Tim's answers, 2026-10-05: all Q1–Q96 accepted as recommended."
- `docs/forward-queue.md` «⬜ ★ 下一刀:MES 组» (after UNBLOCK-1): the 15 cuts in the survey's order — MES-1 · MES-2 · MES-3a · MES-3b ·
  MES-4a · MES-4b · MES-5a · MES-5b · MES-6a · MES-6b · MES-7a · MES-7b · MES-8a · MES-8b · MES-9 — each with its functions and the survey's
  estimate (total ≈ 97 h 40 m – 174 h 45 m).
- **Q16, recorded as Tim's own action and a hard prerequisite:** the Supabase project moves to a paid plan before the first gateway
  connects — before MES-1's gateway path is used on live.
- **Q2:** scheduling is out of scope.

## §1 · Role-by-role reading table (live, measured)

**How it was measured:** `db/scripts/2026-10-05-u1b-live-role-table.sql` (`ROLETABLE_OWN_EXIT=0`, 63 cells, 2026-10-06 09:47:47 CST;
log `~/u1b-work/logs/role-table.log`) — **one transaction, ROLLBACK**, psql as postgres. For each of the **7 real accounts**, the
transaction switches to `authenticated` with that account's JWT — exactly what PostgREST does for each API request — and reads.
**API** = the base table (what a direct `GET /rest/v1/<table>` returns); **page · trail** = the masked view the page reads, or, for the
trail row, the change-log rule `record_trail` applies with that reader's JWT.
Live has **no** journal request, so the transaction creates its **own** payroll entry (`source_type = 'payroll'`, 4,677.00) and a
reversal request with its approval row; they vanish with the ROLLBACK. The medical claim is the real one, **MC-2026-0001**, approved and
paid through **EXP-2026-0008** (read only). Its decision reason and approval note are **empty on live**, so a reader who may see them
reads `(empty)` and a reader who may not reads `Restricted` — the masking is proved on real text by fixture 248 MC.

| reader (role) | reversal request amount — API / page | its approval row — API / page | trail rule | EXP-2026-0008 amount (API) | its note (API) | MC-2026-0001 amount — API / page | health text — API / page | decision reason — API / page | approval note — API / page |
|---|---|---|---|---|---|---|---|---|---|
| admin@ (admin) | 42501 / 4677 | 42501 / 4677 | visible | 30 SGD | Medical claim MC-2026-0001 (EMP-2026-0001) | 42501 / 30 | 42501 / shown (13 chars) | 42501 / (empty) | 42501 / (empty) |
| tim@ (cfo) | 42501 / 4677 | 42501 / 4677 | visible | 30 SGD | Medical claim MC-2026-0001 (EMP-2026-0001) | 42501 / 30 | 42501 / shown (13 chars) | 42501 / (empty) | 42501 / (empty) |
| chooer@ (finance) | 42501 / 4677 | 42501 / 4677 | visible | 30 SGD | Medical claim MC-2026-0001 (EMP-2026-0001) | 42501 / 30 | 42501 / shown (13 chars) | 42501 / (empty) | 42501 / (empty) |
| sandra@ (cco) | 42501 / 4677 | 42501 / 4677 | visible | 30 SGD | Medical claim MC-2026-0001 (EMP-2026-0001) | 42501 / 30 | 42501 / shown (13 chars) | 42501 / (empty) | 42501 / (empty) |
| phua@ (cto) | 42501 / Restricted | 42501 / Restricted | Restricted | 30 SGD | Medical claim MC-2026-0001 (EMP-2026-0001) | 42501 / Restricted | 42501 / Restricted | 42501 / Restricted | 42501 / Restricted |
| vince@ (gm) | 42501 / Restricted | 42501 / Restricted | Restricted | 30 SGD | Medical claim MC-2026-0001 (EMP-2026-0001) | 42501 / Restricted | 42501 / Restricted | 42501 / Restricted | 42501 / Restricted |
| fusheng@ (warehouse) | 42501 / no rows | 42501 / no rows | Restricted | no rows | no rows | 42501 / no rows | 42501 / no rows | 42501 / no rows | 42501 / no rows |

Codes behind the rows (as postgres, `role_permissions`): admin · cfo · finance · cco hold `data.view_pay` and `data.view_health`;
cto · gm hold `module.finance.view` and `module.hr.view` but neither data code; warehouse holds neither module code (it reads no rows).
**Reading the table:** the base columns are refused (42501) for every reader — the API never hands out the amount or the text; the page
and the trail say Restricted exactly where `data.view_pay` / `data.view_health` is missing; the medical expense's amount stays visible to
every finance reader (Tim's ruling) and its only text is the system note, which carries no health text.
**What the table cannot show:** the own-record branch on its own — MC-2026-0001 is chooer@'s own claim (EMP-2026-0001, measured as
postgres), but chooer@ also holds `data.view_health`, so the two reasons for "visible" coincide; fixture 248 MC3 proves the own-record
branch alone on the rebuild; the screen render of the journal-request panel (live has no request,
and creating one outside a rolled-back transaction would leave a document of mine — the panel's Restricted branch is pinned by code and
by the trail golden ⑭, not by a live render).

## §2 · Every item built, and every hand-back item closed without building

### Built

| item (Step 0 §) | what changed | proof |
|---|---|---|
| **Q14** shipped order, add lines (3.3) | `/sales/orders/[id]` draws the amend entry for `shipped` too, labelled "Add lines" with an add-only hint; the amend page and `amend_sales_order` already accepted it | live proof ①; trail golden ⑭ |
| **Q15** downtime correct / void, never delete (3.5) | per-row **Correct** (start, end when closed, reason — the table's UPDATE policy, old values kept in the change log) and **Void** with a reason (`void_equipment_downtime`); a voided period freezes, stops counting for overlap and as the open period, cannot be referenced by a new handover, and stays listed as "Voided" with its reason; **every DELETE is refused by name** (`guard_downtime_write`, statement-level) | fixture 248 DT1–DT4; live proof ② |
| **Q16** forwarder rates table (3.9) | the raw table is now the shared `DataTable` (phone: columns mode), Remove in an always-visible priority action cell with a confirm; `removeRateQuote` refuses a zero-row update | survey 390/1280 |
| **Q17** KPI scoring rows (3.10) | target, evidence, the month-3 / month-6 org targets and the provisional note sit behind a per-row "Show targets" (`<details>`); title, weight, the provisional tag and the score stay visible | §3 row heights |
| **Q18** admin break-glass (3.11 ②) | `docs/operations/admin-break-glass.md` — impersonal, declarative; no second holder; Tim keeps it | the document |
| **Q20** deep-discharge judgement (4.2) | `set_po_line_deep_discharge` (SECURITY DEFINER; `module.purchasing.edit`; not on a cancelled PO; never back to empty; unknown code refused); the control calls it, is gated visibly, and is read-only on a cancelled PO | fixture 248 DD1–DD3; live proof ③ |
| **Q21** machine on a processing run (4.3) | optional "Machine used" on `/operation/processing/new` from `equipment_usage` (disposed assets excluded; first option "Not recorded"); `p_equipment_id` passed | live proof ④ |
| **Q23** GHOST-GRANTS (3.7) | `mintThrowaway` in `scripts/ephemeral.mjs` (throwaway role `probe-<prefix>-<label>-<stamp>` with all codes / a list / a clone of a real role; refuses any `is_system` role); 37 scripts converted; smoke `--reach` clones each real role; `render-pdf-samples` takes the live-lock; sweeps know every prefix; `check-throwaway-grants` in `npm run build` | §4 |
| **MES-0 Q1** shared throwaway helper | the same `mintThrowaway`; `scripts/probe-throwaway.mjs` proves it live | §4 |
| **Q24** dead actions (4.4) | `deleteEmployee`, `updateQuoteHeader`, `softDeleteCommissionAgreement` deleted; the `rollback_processing_run` stub kept | `grep -rnw` (definitions only, before) |
| **Q25** PO close / reopen reasons (4.5) | `closed_by` · `close_reason` · `reopened_at` · `reopened_by` · `reopen_reason` (masked table: column + grant + `purchase_orders_masked` in one migration); Notes are no longer rewritten; history rows `closed` / `reopened` carry the reason; PO page shows a closed banner and a reopened line; "amended since issued" ignores close / reopen / cancel. The 2 live POs whose Notes already carry the old suffix are left as they are (Tim) | fixture 248 PO1–PO2; live proof ③ |
| expense claim with no other decider (3.6) | `submit_expense_claim` refuses `EXPENSE_CLAIM_NO_OTHER_DECIDER|<code>` when approvals are on and nobody but the submitter (and the claim's subject) can decide; new `assert_other_decider_for_subject` passes the subject, `assert_other_decider` now calls it with NULL | fixture 248 CL1–CL4 |
| `PERIOD_LOCKED` shared mapping (3.12) | `lib/machine-text.ts` maps `PERIOD_LOCKED|date|lock` and `YEAR_CLOSED|date|year_end` once, naming both dates and the next step; `refuseFromDriver` asks it first. Measured: 48 `*ErrorCodes.ts`, 37 without their own `PERIOD_LOCKED` — all covered now | build; code |
| month-end checklist + processing error codes (5.1) | `processing_runs_blocking_close` — the exact predicate `close_period` refuses on — read by both `close_period` and `/finance/month-end` (new blocking step; the stale-allocation step now counts only stale runs); `localizeProcessingError` maps the allocation, ledger-diverged and equipment codes | fixture 248 ME1–ME3 |
| payroll reversal request amounts (U1-A close-out) | `journal_requests.amount_base` revoked; `journal_requests_masked`; one judgement `journal_request_amount_visible` for the view, the approval-log amount, the change log (`jr_amount`) and the submit / decide return values; `/finance/journal` reads the view and prints Restricted | fixture 248 JR1–JR5; §1 |
| medical-claim expense (U1-A close-out) | **measured:** the expense carries no health text in its own columns or journal (system note "Medical claim MC-… (EMP-…)", payee name, account 6120). What reached its page was the claim's approve / reject reason through the page's audit trail, and the same text on the approval row, and in the self-approval report. `medical_claims.decision_notes` and `approval_log.note` (medical rows) now follow `data.view_health` or self; the amount stays visible to finance (Tim) | fixture 248 MC1–MC5; §1 |
| nine leave functions, NULL trap (U1-A close-out) | `COALESCE(p_employee_id = current_user_employee(), false)` in all nine | fixture 248 LV |

### Closed without building

| item | why |
|---|---|
| **Q19** payment-request withdrawal (`AT0-WITHDRAW-PAYMENT-REQUEST-NO-REQUESTER-CHECK`) | Not a defect. The siblings' check is "the raiser **or** any holder of the chain's code" (`withdraw_invoice_request.sql:3`); `withdraw_payment_request` requires `module.finance.edit`, which `submit_payment_request.sql:32` also requires — every raiser holds it, so both forms admit the same people. The entry's "the other five all have it" is corrected in place. Live: 0 payment requests |
| **Q22** reconcile "unreachable" (`BTN5B-RECONCILE-UNREACHABLE`) | Not a defect: live has no open statement; a soft-deleted statement now redirects to its detail page. Moved from 甲 to 丙; no row created to make it reachable |
| **Q26** the 8 unallocated runs | Tim's own data entry. The code half shipped (checklist + error codes). The `price_index` inconsistency is registered (`U1B-ALLOCATION-PRICE-INDEX-LEGS`; measured: 12 prices, every `price_index` NULL, 0 days with two indices) |
| 3.11 ① "dictionary-edit account without permission management does not exist" | Already satisfied (cco · cto · finance) — struck with ② in the 甲 row |
| 3.2 IOD-1 · 3.8 PayrollGrid | Already struck by U1-A |

## §3 · Pages — every changed route, with its file

| route | files | what changed |
|---|---|---|
| `/sales/orders/[id]` | `app/sales/orders/[id]/page.tsx` | add-lines entry on a shipped order (Q14) |
| `/finance/assets/[id]` | `…/DowntimePanel.tsx`, `…/page.tsx`, `…/actions.ts`, `app/finance/assets/equipmentErrorCodes.ts` | Correct / Void per row, voided rows marked, close refuses zero rows (Q15) |
| `/operation/equipment/[id]` | `app/operation/equipment/[id]/page.tsx` | voided periods marked, never "still down" |
| `/operation/handovers/new` · `/operation/handovers/[id]` | `…/new/page.tsx` · `…/[id]/page.tsx` | voided periods not offered; a later-voided reference is marked |
| `/logistics/forwarders/[id]` | `…/ForwarderPanels.tsx`, `…/page.tsx`, `…/actions.ts` | rates table on DataTable, Remove always visible (Q16) |
| `/hr/kpi/score` | `app/hr/kpi/score/ScoreEditor.tsx` | "Show targets" per row (Q17) |
| `/operation/processing/new` | `…/page.tsx`, `…/NewProcessingForm.tsx`, `…/actions.ts` | optional machine (Q21) |
| `/purchasing/orders/[id]` | `…/page.tsx`, `…/actions.ts`, `…/CloseReopenControls.tsx`, `…/DeepDischargeJudgementControl.tsx`, `…/PoLinesTable.tsx`, `app/purchasing/purchasingErrorCodes.ts` | closed banner, reopened line, reason wording, deep-discharge via the function (Q20 · Q25) |
| `/finance/month-end` | `app/finance/month-end/page.tsx` | blocking-runs step (5.1) |
| `/finance/journal` · `/finance/journal/[id]` | `…/page.tsx`, `…/JournalRequestsPanel.tsx`, `…/[id]/page.tsx` | requests read `journal_requests_masked`; Restricted amounts |
| `/finance/self-approved` | `…/page.tsx`, `…/SelfApprovedTable.tsx` | medical rows' amount / note Restricted without `data.view_health` |
| every page that refuses a period-locked write | `lib/machine-text.ts`, `lib/action-refusal.ts`, `app/operation/errorCodes.ts`, `app/finance/claims/claimErrorCodes.ts` | `PERIOD_LOCKED` / `YEAR_CLOSED` named with both dates; allocation / equipment / handover / claim codes |
| every page's audit trail | `lib/trail/render.ts`, `lib/trail/text.ts`, `lib/trail/catalogue.generated.ts` | §6 wording |
| (no route) | `app/hr/employees/actions.ts`, `app/sales/quotes/actions.ts`, `app/sales/commissions/actions.ts` | dead actions deleted (Q24) |

## §4 · Verification, in the brief's order

| # | step | result | source |
|---|---|---|---|
| 1 | offline gate | `GATE_OFFLINE_EXIT=0` (run 2, 75 s). Run 1 red on two things, both mine: fixture 233's setup read a leave balance **with no session** — the exact shape the NULL-trap fix closes (now reads as its HR user) — and the new `assert_other_decider_for_subject` was missing from the definer allowlist beside its twin | `logs/gate-off1.log`, `logs/gate-off2.log` |
| 2 | backup (background) | `BACKUP_EXIT=0` — `evoltrya-backup-2026-10-05-2026.dump`, 5.8 MB, TOC 7421 (previous 7324), done 20:41:55 | `logs/backup.log` |
| 3 | apply_migration | committed; **window start 2026-10-05 20:46:41 CST** (`db/migration-windows.tsv`; the script printed 20:44:44 at its start). A dry run first (COMMIT → ROLLBACK) on live: run 1 caught a name clash in the proof (`to_jsonb(d)` resolved to a before-table column `d` — invisible on the empty local copy), run 2 `DRY_OWN_EXIT=0` | `logs/dry.log`, `logs/dry2.log`, `logs/apply.log` |
| 4 | types | `TYPES_OWN_EXIT=0` (telemetry off); `lib/maskedTables.ts` regenerated (34 masked tables, `journal_requests` added) | `logs/types.log` |
| 5 | tsc | `TSC_OWN_EXIT=0` | `logs/tsc1.log` |
| 6 | build | `BUILD_EXIT=0` (run 4). Runs 1–3: a pinned font size in the new downtime actions column (`check-component-library`); the new throwaway checker's coverage assertion not in the shared `selfproof` form (`check-instrument-selfproof`); 42 unused-variable warnings left by the script conversion (`check-lint`) — all fixed, lint back to its baseline 41 / 83. **Rebuilt after the KPI change (§2): `BUILD_EXIT=0`** | `logs/build1–5.log` |
| 7 | full gate | `GATE_EXIT=0` — 可重建性 ✓ · 镜像 vs 线上 ✓ · 行为断言 ✓ (fixture 248 included) · 匿名面 ✓ (live ⊂ baseline 327); 455 s to the three verdicts | `logs/gate1.log` |
| 8 | i18n | `I18N_OWN_EXIT=0` (rerun after the KPI change) | `logs/i18n2.log` |
| 9 | error swallowing | `SWALLOW_OWN_EXIT=0` (rerun after the KPI change) | `logs/swallow2.log` |
| 10 | layout survey | **1280 px: 12 / 12 usable** (`SURVEY1280_EXIT=0`). **390 px: 10 / 12** (`SURVEY390_EXIT=0`): `/operation/processing/new` +177 px and `/finance/month-end` +6 px — **both already registered** (`DATEPICK1-390-FIVE-PAGES-OVERFLOW`, same figures, same culprits: a `<select>` and a table cell); U2 (clipped ledger) 12 / 12. Pages: the 12 changed routes with live data, concrete ids; `/operation/handovers/[id]` has no live handover to open | `logs/survey390.log`, `logs/survey1280.log` |
| 10b | KPI rows (Q17 acceptance) | `scripts/survey-controls.mjs --mode=drift` on `/hr/kpi/score?cycle=…`, **same tree**, HEAD's `ScoreEditor.tsx` swapped in for "before": desktop 1440 px max **504 → 108** px (median 370 → 82; target ≤ ~120 ✓); phone 390 px max **1,699 → 168** px (median 1,160 → 125; target ≤ 2 screen heights ✓). The "before" equals POLISH-1 r3's reading. A first "after" read 216 px on the 9 provisional rows — the provisional note stayed outside the fold; it moved inside (the tag stays). ⚠ The run's own coverage assertion exits 2 (0 controls in tables): the session sees the rows read-only, so the score box is not in the measured rows | `logs/kpi-*.log` |
| 11 | smoke (background) | `SMOKE_EXIT=0` — 260 ok · 9 skipped (no data) · **0 FAILED**; it ran on the new helper (`probe-smoke-all-<stamp>`, 73 codes) | `logs/smoke.log` |
| 12 | live verification | §1 (role table), §5 (proof, before / after) | |

**Smoke's scratch-cleanup reading:** `npm run check:scratch` before the smoke and after it report **the same 6** stale rows, all pre-existing
(`ZZ-SMOKE-PROBE` · `ZZ-SMOKE-M25` · `ZZ-SMOKE-NTF` · `ZZ-SMOKE-S25` · `ZZ-SMOKE-CJK` · `ZZ-SMOKE-IB25`, 810–1,453 h old; 5 still referenced,
"不要直接删"), `SCRATCH_OWN_EXIT=1` (its "stale rows exist" code) both times. As postgres after the smoke: `auth.users` like `%@test.local` **0** ·
`roles` like `probe-%` **0** · grants without an account **0** · `.ephemeral/` empty.

### Fault injection — every arm made to fail on purpose

**Fixture 248** (`db/fixtures/248-workflow-doors-and-the-last-leaks.sql`), 8 arms: DT · PO · DD · CL · LV · JR · MC · ME.
`db/scripts/2026-10-05-u1b-fixture-injections.py` on a local rebuild of the current mirrors: **clean run green, 19 injections, 0 wrong — each
red in the arm it names** (`INJECTIONS_OWN_EXIT=0`, `logs/inj2.log`). Two cells did not bite on the first run and each was information,
not noise: the ME3 check matched the function's *name* in a comment (now matches the call shape); the LV injection sat on `leave_balance`,
which delegates to the still-guarded `leave_balance_internal` (moved to the leaf `consumed_from_accrual`).

| arm | injection | went red with |
|---|---|---|
| DT | drop the statement-level delete guard | DT4: an authenticated delete did not refuse |
| DT | direct writes may void | DT2: a direct write voided a downtime period |
| DT | the open-period index counts voided rows | DT3: the voided open period still blocks a new one |
| DT | handover takes a voided period | DT3: a handover took a voided downtime period |
| PO | close stops writing `close_reason` | PO1: reason / who not in their own columns |
| PO | reopen rewrites Notes again | PO2: reopening rewrote the notes |
| DD | a cancelled PO takes a judgement | DD3 |
| DD | the judgement may go back to empty | DD2 |
| CL | submit stops asking for another decider | CL1 |
| CL | the claim's subject is not passed | CL4 (the R2 exception needs the subject) |
| LV | `consumed_from_accrual` back to the NULL trap | LV |
| JR | `amount_base` granted back | JR1: expected 42501 |
| JR | `journal_request_amount_visible` answers visible | JR2 |
| JR | approval amount of a journal request visible to all | JR3 |
| MC | `decision_notes` granted back | MC1: expected 42501 |
| MC | `medical_claims_masked` stops masking it | MC2 |
| MC | the self-approval report shows the note | MC5 |
| ME | the reader counts allocated runs | ME1 |
| ME | `close_period` stops asking the shared reader | ME3 |

**Trail wording:** `scripts/check-trail-wording.mjs` arm **⑭** (13 goldens: downtime voided / corrected / ended; PO closed / reopened /
closed with no reason; deep-discharge judgement; payroll reversal request Restricted and visible; medical decision reason Restricted and
visible, on the claim and on the expense page; a line added to a shipped order). Injection `TRAIL_WORDING_FAULT=wording-drift-u1b` →
red in ⑭ only.

**Throwaway helper:** `scripts/check-throwaway-grants.mjs` — clean (97 files scanned = 97 counted by `find`; 44 call sites in 38 files);
`--inject=all` turns red for **38 / 38** converted files; `--inject=blind` (coverage), `--inject=refusal-removed` both red.
`scripts/probe-throwaway.mjs` **on live**: clean `THROWAWAY_PROBE_EXIT=0` (3 throwaways — all codes · a clone of warehouse (27 codes) ·
`module.hr.view` + an employee; each role non-system with exactly its codes; each token's `current_user_permissions()` equals them;
`{realRole:'admin'}` refused before anything is created; nothing left after); `--inject=leftover` → 1 (names the leftover role, then
reaps it); `--inject=cleanup-hang` → 6 (each unconfirmed step named; the next run reaped the plan); `--inject=refusal-off` → 1.
Read-back as postgres afterwards: `auth.users` like `%@test.local` **0** · `roles` like `probe-%` **0** · grants without an account **0** ·
`ZZ-SMOKE-THROWAWAY%` employees **0** · `.ephemeral/` empty.

## §5 · Live verification — before and after

**Before** 2026-10-05 19:57:39 CST, **after** 2026-10-06 09:49:08 CST — `db/scripts/2026-10-05-u1b-live-readings.sql` (every public base
table: row count + digest, as postgres; plus accounts, approvals, pending documents).

**Inside one rolled-back transaction** — `db/scripts/2026-10-05-u1b-live-proof.sql`, psql as postgres acting with admin@'s JWT
(`PROOF_OWN_EXIT=0`, 2026-10-06 09:48:52 CST; runs 1–2 refused by live's GST rule — `TAX_CODE_REQUIRED|customer`, then `|supplier`, which
the empty local copy never asks — and rolled back whole):

| step | result |
|---|---|
| ① a shipped order of my own | SO-2026-0005 fully shipped (12/12), then a line added → **partially_shipped** |
| ② downtime on my own machine | recorded, corrected (start and reason), voided with a reason; DELETE → **`DOWNTIME_NEVER_DELETED`** |
| ③ a PO of my own | PO-2026-0012: deep-discharge judgement "not_assessed"; closed with a reason; reopened with a reason; Notes unchanged |
| ④ a processing run with a machine | PROC-2026-0711 recorded machine ZZ-U1B-A1 |

⚠ Said rather than hidden: to reach "fully shipped", invoicing and the shipping release would wait for the CFO with approvals on, so the
transaction switched approvals off (the approvals-policy context, as fixture 229 does), shipped, and switched them back on before adding the
line; both changes rolled back with everything else — live had approvals ON throughout (before / after readings). The document numbers above
(SO-2026-0005, PO-2026-0012, PROC-2026-0711, OUT-2026-0669/0670, INV-2026-0010, SHP-2026-0002) were drawn inside the rolled-back transaction;
gapless numbers come back with it, **sequence-backed ones do not** (a rollback never returns a sequence value), so the next real document of
those kinds may skip a number.

**The trails, read back and worded by the app's own renderer** — `db/scripts/2026-10-05-u1b-render-live-trails.mjs` feeds the
`record_trail` rows (read as admin@) through `fromRecordTrail` + `buildEntries`, the path `AuditTrail.tsx` takes (`RENDER_OWN_EXIT=0`,
9 / 9 checks). One transaction is one operation to the trail (it groups by txid), whereas each app action is its own transaction; the script
therefore splits the rows at the step boundaries the proof recorded (`clock_timestamp()`, compared to the microsecond — a first version
compared milliseconds and merged steps a few hundred microseconds apart). What the trail says:

| record | entries (newest first) |
|---|---|
| sales order | **Sales order amended · line added · Line 2** — Quantity: (empty) → 5 · Unit price: (empty) → 10.00 SGD · [Sales order status changed] Status: Shipped → Partially shipped · Reason: U1B proof: the customer wants 5 more |
| asset (downtime) | **Downtime voided** — Went down: 06/10/2026 05:48 · Reason: U1B proof: entered on the wrong machine · **Downtime corrected** — Reason: … belt snapped → … belt snapped on the feeder · Went down: 06:48 → 05:48 · **Downtime started** |
| purchase order | **Purchase order reopened** — Reason: … supplier found the stock · **Purchase order closed** — Reason: … supplier cannot deliver the rest · **Deep discharge judgement recorded** — [Line 1 · U1B proof gloves] (empty) → Not assessed · **Purchase order raised — waiting for approval** |
| processing run | **Processing completed** — … Equipment: ZZ-U1B-A1 · Operation: Manual disassembly |

The first live reading of the sales-order entry was titled "Sales order status changed" (the derived flip outranked the amendment);
the renderer now ranks a derived status change below an amendment in the same operation — §6 decision 14.

**Tables — 241 before, 241 after; every difference explained:**

| table | before → after | why |
|---|---|---|
| `document_types` | 41 → 41, digest changed | the migration: `medical_claim` no longer matches `decision_notes` |
| `purchase_orders` | 11 → 11, digest changed | the five new columns (all NULL) are part of the row text; **over the old column set the digest is unchanged** (`1fe26d4049c3` before and after) |
| `equipment_downtime` | 1 → 1, digest changed | the three void columns (NULL); **over the old column set the digest is unchanged** (`05da602b2d56`) |
| `cod_verification_failures` | 1 → 1, digest changed | the smoke's `/verify/cod/[token]` probe writes its rate-limit row by design (U1-A saw the same) |
| change log (`~summary`) | 5,815 rows / seq 6,874 → 7,623 / 8,700 | +1,808, every row after seq 6,874 accounted for (as postgres, `change_log` grouped by table and op): harness throwaways created and removed in pairs — `role_permissions` 842/842 · `roles` 18/18 · `user_roles` 18/18 · `employees` 11/11 · probation reviews 3 inserted / 3 updated / 3 deleted · the smoke's contract and its six term tables in pairs · the COD row 1/1 — and the migration's one `document_types` update |

Every other table — every pre-existing document — has the same row count and digest. **Accounts:** before and after,
`admin@=admin · chooer@=finance · fusheng@=warehouse · phua@=cto · sandra@=cco · tim@=cfo · vince@=gm`, 0 disabled, 0 throwaway, approvals ON,
0 grants without an account, 1 pending document (CLM-2026-0004 → tim@). Roles and grants unchanged (the migration's proof asserts no grant
moved). **Nothing of mine remains.**

### §5.1 · Broken window

| | value | source |
|---|---|---|
| start | **2026-10-05 20:46:41 CST** | `db/migration-windows.tsv` (`2026-10-05T20:46:41+0800	2026-10-05-u1b-workflow-fixes.sql	4995f49b`); `apply_migration.sh` printed 20:44:44 at its start |
| end | Tim's Vercel reading (to be recorded at the next close-out) | a report, not a measurement from this machine |

**Longer than any recent window, and why:** Tim paused the session overnight after the migration was applied (2026-10-05 ~21:05 →
2026-10-06 09:11). **What is broken inside it** (derived from the old code and the revoked grants, not measured on live):
`/finance/journal` selects `journal_requests.amount_base` from the base table → 42501 for every reader (the page errors; live has 0
requests, but the query is refused regardless). The old deep-discharge control still cannot save (it never could since APR-10). The old
close / reopen controls call the same functions, so the reason now lands in the new columns, which the old page does not show (Notes no
longer change). Nothing else reads a revoked column (measured: no app read of `medical_claims.decision_notes` or `approval_log.note`).

## §6 · Decisions taken without asking

1. **The claim-decider check uses a new function, `assert_other_decider_for_subject`, and `assert_other_decider` calls it with NULL** —
   changing the old signature would be an overload the pre-flight refuses; one judgement either way.
2. **A claim whose base amount cannot be computed (no FX rate) is not refused at submit** — deciding it is refused by `fx_rate_for` anyway;
   inventing a second refusal for the same fact would be a second wording of the FX rule.
3. **Tim's R2 self-exception counts** — the only level-2 holder may submit a claim for himself (he may decide his own claim); fixture CL4.
4. **Downtime correction stays a direct UPDATE under the existing policy** (Q15: no migration needed for it); only the void goes through a
   function, and a guard stops direct writes to the void columns.
5. **Every DELETE of a downtime period is refused by name, owner included, as a statement-level trigger** — a row trigger never fires for an
   authenticated DELETE (no DELETE policy → zero rows → silent success; measured in fixture 248's first run).
6. **A voided period freezes** (no correction afterwards), no longer counts for overlap or as the open period, cannot be newly referenced by a
   handover, and stays listed — handovers that referenced it before keep the reference, marked "voided later".
7. **Correct cannot close an open period or reopen a closed one** — closing stays with "Close this period" (app agent's call, kept).
8. **PO close / reopen columns describe the latest close and reopen**; reopening clears the close columns; the full history is in
   `purchase_order_history` (`closed` / `reopened` rows) and the change log. Close reason stays optional where it was optional before.
9. **The deep-discharge judgement can never go back to empty** (NULL means "older than this axis"); "not_assessed" is the honest unknown.
   A cancelled PO shows the judgement read-only; permission and status are not mixed into one boolean (DBLOCK-1).
10. **The machine picker leaves disposed assets out entirely** and is optional; "not yet acquired" is left to the server (it depends on the
    process date in the form).
11. **The medical-claim expense rule was applied where the health text actually travels**: `medical_claims.decision_notes` and
    `approval_log.note` (medical rows only), everywhere they are read — not only on the expense page, because the column rules are global
    and a mask on one page with the same text open next door is theatre. The expense's amount and its system note stay visible (Tim).
12. **The self-approval report (`self_approved_decisions`, gm · auditor) now asks the same two judgements** — it read the approval log as owner
    and handed medical amounts and notes to gm.
13. **A masked reason in the trail reads "Restricted"** (new `typedOrRestricted`) — it used to vanish, which reads as "no reason given".
14. **A derived status flip is ranked below an amendment in the same operation** (sales orders) — "Sales order amended · line added" is the
    event; "Shipped → Partially shipped" is its consequence (found by the live proof, pinned in ⑭).
15. **The KPI provisional note also folds**; the "Provisional" tag stays visible (measured: the note alone made 9 rows 216 px).
16. **`PERIOD_LOCKED` / `YEAR_CLOSED` are mapped once, in the shared fallback**, not added to the 37 localizers that lack them.
17. **The month-end lock step is also blocked by unallocated runs**, and the stale-allocation step counts only stale runs (app agent's call,
    kept — it now says exactly what `close_period` will say).
18. **Smoke `--reach` and the role-loop probes clone each real role's codes** into a throwaway role instead of granting the real role;
    `probe-u1a` and `probe-role-crash` clone admin too (an all-codes reader would hide exactly what they measure). No script needed a real
    role grant.
19. **`sweep-ghost-grants` deletes only accounts and `probe-` roles older than 2 h** (it now matches more prefixes, which made it a
    name-based sweep; AGENTS.md "report, don't sweep").
20. **The throwaway checker uses the shared `selfproof` assertions on its clean path** and keeps its own set-level coverage report (its
    `blind` injection reads it).
21. **Fixture 233's setup now reads as its HR user** — the no-session read it made is the NULL-trap shape the fix closes; no app or job path
    reads a leave balance without a session.
22. **The role table reads the 7 real accounts by JWT inside a rolled-back transaction**, with a payroll entry and reversal request of my own
    (live has none); the live proof switched approvals off and on inside its transaction to reach "fully shipped".
23. **Leave decision notes are registered, not masked** (`U1B-LEAVE-DECISION-NOTE-HEALTH-TEXT`) — same shape, outside Tim's expense ruling.
    An ordinary claim's description copied into its expense's notes is registered too (`U1B-EXPENSE-CLAIM-DESCRIPTION-IN-EXPENSE-NOTES`).

## §7 · Assertions in the brief (and in the repo) measured and found false or imprecise

1. **Brief: "the expense claim that can be left with no other decider"** — the R2 self-exception means the only level-2 holder claiming for
   himself is **not** stranded (he may decide it); the refusal applies to the raiser leg and to a subject without level 2 (fixture CL1–CL4).
2. **known-issues `AT0-WITHDRAW-PAYMENT-REQUEST-NO-REQUESTER-CHECK`: "the other five all have a requester check"** — they have "raiser **or**
   code holder", the same set `withdraw_payment_request` admits (Q19).
3. **known-issues `U1A-MEDICAL-EXPENSE-AMOUNT-ON-FINANCE-SIDE` framed the leak as the expense's amount** — Tim keeps the amount; what carried
   health text to the finance side was the claim's decision reason (through the expense page's trail) and the approval note.
4. **known-issues `U1A-SELF-GATE-NULL-TRAP`: "today nobody reaches it"** — true of people; fixture 233's no-session setup read did, and went
   red when the gate closed.
5. **Step 0 §3 5.1: "Live: every row is one index? NOT MEASURED"** — measured now: 12 prices, every `price_index` NULL, 0 days with two indices.
6. **A survey agent reported `scripts/render-pdf-samples.mjs` "the only script without a live-lock"** — true; and the agent's claim that
   `admin` "holds only 3 system codes" describes the bootstrap, not live (live admin holds 72 of 73, as postgres, `role_permissions`).

Matched on re-measurement: the three SHAs at the opening; 7 accounts, 0 disabled; approvals ON finance / cfo / 1,000; 101 mask rules before
the migration; 2 of 11 POs with the Notes suffix; 0 journal requests; 1 downtime row; KPI row heights before = POLISH-1 r3's.

## §8 · Docs updated

`docs/surveys/MES-0/README.md` (§12) · `docs/forward-queue.md` (MES group queued; item 35; UNBLOCK-1 ✅; 甲 rows struck; reconcile to 丙;
PERIOD-LOCK-RAW-CODE ✅) · `docs/known-issues.md` (12 entries closed in place; 3 new: `U1B-LEAVE-DECISION-NOTE-HEALTH-TEXT`,
`U1B-EXPENSE-CLAIM-DESCRIPTION-IN-EXPENSE-NOTES`, `U1B-ALLOCATION-PRICE-INDEX-LEGS`; the month-close entry noted) · `docs/change-log.md`
(new §11: masking and trail wording) · `docs/role-matrix.md` (the two data codes) · `docs/operations/admin-break-glass.md` (new).
