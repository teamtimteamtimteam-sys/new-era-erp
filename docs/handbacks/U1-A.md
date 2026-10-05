v1.4.35 — Pay and personal data are now protected to match each person's role: individual pay in payroll journals, payroll period totals and payroll requests are visible only to those with pay access; health details in medical claims and leave reasons are visible only to HR and HR decision-makers (and to the employee for their own); employees no longer see HR's notes about them or open-cycle KPI scores; anonymising a former employee now also erases their free-text records; and payslips on My profile show their own currency.

# U1-A — pay and personal data (UNBLOCK-1, first cut; 2026-10-05)

Tim answered UNBLOCK-1 Step 0 on 2026-10-05: every recommendation for Q1–Q26 accepted as stated
(`docs/surveys/UNBLOCK-1/STEP0-HANDBACK.md`). This cut builds **Q1–Q13 plus the trail "0.00" trap**. U1-B (Q14–Q25,
`v1.4.36`) is next; Q26 is Tim's own data entry. The mechanism reference is **`docs/change-log.md` §10** (new).

**Opening check:** this session's first command printed **2026-10-05 15:26:55 CST**. The tree was clean apart from Tim's untracked
`docs/Data capture and ERP integreation.pdf`, which I did not touch. `HEAD` = `origin/main` = `ls-remote` =
`05e26c459b65b8b98bfd7c71fa362240f4a688cf`. **Approvals were ON before and after** (live-readings `~summary`, 16:18:10 and 19:01:48 CST).
All 7 real accounts were enabled before and after, with the same role each. No real auth account was created, disabled or deleted.

Every figure below is either a script's own exit line or a query named with who ran it. "As postgres" means the Management API
or psql as `postgres` (`rolbypassrls = true`), reading base tables. Working logs are in `~/u1a-work/logs/` (outside the repo).

## §1 · Role-by-role reading table (live, measured)

**How it was measured:** `scripts/probe-u1a.mjs` (`U1A_PROBE_EXIT=0`, 107 passed · 0 failed · 0 skipped, run 18:44–18:47 CST; log
`~/u1a-work/logs/probe.log`). Eight throwaway accounts, one per real role (`admin` · `cfo` · `finance` · `cco` · `cto` · `gm` · `warehouse`,
the role each of the 7 live accounts holds) plus a **plain employee** (no role, a throwaway `ZZ-SMOKE-U1A-…` employee row). Each reads
the same live rows two ways: **API** = its own JWT straight at PostgREST; **screen** = its own session on `next start` (English).
Subjects (read as postgres): pay run **JE-2026-0018** (2 lines, memo «EMP-2026-0001 Choo Er Teh», 4,677.00) · period **PAY-2026-0001** ·
**0** payroll requests on live · claim **MC-2026-0001** · leave **LV-2026-0006** · **2** maintenance rows.

Codes each role holds on live (as postgres, `role_permissions`, 19:0x CST):

| role | data.view_pay | data.view_health | module.finance.view | module.hr.view | module.processing.view |
|---|---|---|---|---|---|
| admin · cfo · finance · cco | ✓ | ✓ | ✓ | ✓ | ✓ |
| cto · gm | — | — | ✓ | ✓ | ✓ |
| warehouse | — | — | — | — | ✓ |
| plain employee | — | — | — | — | — |

| reader | item | API | screen |
|---|---|---|---|
| admin | Payroll journal (pay run) | 2 lines with amounts | amount 4,677.00 · memo shown |
| admin | Journal list (summary) | — | amount 4,677.00 |
| admin | Payroll period totals | masked view: totals 5000 · base column refused (42501) | totals 5,000.00 |
| admin | Payroll request | live has 0 · masked view 0 rows · base snapshot refused (42501) | no request on live to open |
| admin | Medical claim | masked view: description text, amount 30 · base refused (42501) | description shown |
| admin | Leave request reason | masked view: reason text · base refused (42501) | reason shown |
| admin | Equipment maintenance advice | 2 row(s), costs shown | asset page (finance) shows the costs |
| admin | Own /me | my_period_labels: 0 row(s) | opens (HTTP 200) |
| cfo | Payroll journal (pay run) | 2 lines with amounts | amount 4,677.00 · memo shown |
| cfo | Journal list (summary) | — | amount 4,677.00 |
| cfo | Payroll period totals | masked view: totals 5000 · base column refused (42501) | totals 5,000.00 |
| cfo | Payroll request | live has 0 · masked view 0 rows · base snapshot refused (42501) | no request on live to open |
| cfo | Medical claim | masked view: description text, amount 30 · base refused (42501) | description shown |
| cfo | Leave request reason | masked view: reason text · base refused (42501) | reason shown |
| cfo | Equipment maintenance advice | 2 row(s), costs shown | asset page (finance) shows the costs |
| cfo | Own /me | my_period_labels: 0 row(s) | opens (HTTP 200) |
| finance | Payroll journal (pay run) | 2 lines with amounts | amount 4,677.00 · memo shown |
| finance | Journal list (summary) | — | amount 4,677.00 |
| finance | Payroll period totals | masked view: totals 5000 · base column refused (42501) | totals 5,000.00 |
| finance | Payroll request | live has 0 · masked view 0 rows · base snapshot refused (42501) | no request on live to open |
| finance | Medical claim | masked view: description text, amount 30 · base refused (42501) | description shown |
| finance | Leave request reason | masked view: reason text · base refused (42501) | reason shown |
| finance | Equipment maintenance advice | 2 row(s), costs shown | asset page (finance) shows the costs |
| finance | Own /me | my_period_labels: 0 row(s) | opens (HTTP 200) |
| cco | Payroll journal (pay run) | 2 lines with amounts | amount 4,677.00 · memo shown |
| cco | Journal list (summary) | — | amount 4,677.00 |
| cco | Payroll period totals | masked view: totals 5000 · base column refused (42501) | totals 5,000.00 |
| cco | Payroll request | live has 0 · masked view 0 rows · base snapshot refused (42501) | no request on live to open |
| cco | Medical claim | masked view: description text, amount 30 · base refused (42501) | description shown |
| cco | Leave request reason | masked view: reason text · base refused (42501) | reason shown |
| cco | Equipment maintenance advice | 2 row(s), costs shown | asset page (finance) shows the costs |
| cco | Own /me | my_period_labels: 0 row(s) | opens (HTTP 200) |
| cto | Payroll journal (pay run) | 0 lines (base) · masked view 2 lines, amounts null | Restricted · memo shown |
| cto | Journal list (summary) | — | Restricted |
| cto | Payroll period totals | masked view: totals null · base column refused (42501) | Restricted |
| cto | Payroll request | live has 0 · masked view 0 rows · base snapshot refused (42501) | no request on live to open |
| cto | Medical claim | masked view: description null, amount null · base refused (42501) | Restricted |
| cto | Leave request reason | masked view: reason null · base refused (42501) | Restricted |
| cto | Equipment maintenance advice | 2 row(s), costs shown | asset page (finance) shows the costs |
| cto | Own /me | my_period_labels: 0 row(s) | opens (HTTP 200) |
| gm | Payroll journal (pay run) | 0 lines (base) · masked view 2 lines, amounts null | Restricted · memo shown |
| gm | Journal list (summary) | — | Restricted |
| gm | Payroll period totals | masked view: totals null · base column refused (42501) | Restricted |
| gm | Payroll request | live has 0 · masked view 0 rows · base snapshot refused (42501) | no request on live to open |
| gm | Medical claim | masked view: description null, amount null · base refused (42501) | Restricted |
| gm | Leave request reason | masked view: reason null · base refused (42501) | Restricted |
| gm | Equipment maintenance advice | 2 row(s), costs shown | asset page (finance) shows the costs |
| gm | Own /me | my_period_labels: 0 row(s) | opens (HTTP 200) |
| warehouse | Payroll journal (pay run) | 0 rows (no finance) | no finance access |
| warehouse | Payroll period totals | 0 rows (no HR) | no HR access (page refuses) |
| warehouse | Payroll request | live has 0 · masked view 0 rows · base snapshot refused (42501) | no request on live to open |
| warehouse | Medical claim | 0 rows (no HR) · base 42501 | no HR access |
| warehouse | Leave request reason | 0 rows (no HR) · base 42501 | no HR access |
| warehouse | Equipment maintenance advice | 2 row(s), costs null | — |
| warehouse | Own /me | my_period_labels: 0 row(s) | opens (HTTP 200) |
| employee | Payroll journal (pay run) | 0 rows (no finance) | no finance access |
| employee | Payroll period totals | 0 rows (no HR) | no HR access (page refuses) |
| employee | Payroll request | live has 0 · masked view 0 rows · base snapshot refused (42501) | no request on live to open |
| employee | Medical claim | 0 rows (no HR) · base 42501 | no HR access |
| employee | Leave request reason | 0 rows (no HR) · base 42501 | no HR access |
| employee | Equipment maintenance advice | 0 row(s), — | — |
| employee | HR notes on own record | base column refused (42501) · own row via employees_masked: notes null | — |
| employee | Own /me | my_period_labels: 0 row(s) | opens (HTTP 200) |

**What the table cannot show, said rather than implied:**
- **The employee's own records.** None of the throwaway accounts owns the claim, the leave request or a payslip, so every
  "own" row here is a "not mine" row. The own-record branch (an employee reads their own health text and their payslip's currency;
  never HR's notes; KPI scores only after close) is proven by **fixture 247** arms HL · EN · CU · KP on the rebuild, and their
  fault injections (§4). Logging in as a real account would have needed its password; I did not.
- **Payroll requests.** Live has 0, so the screen column has nothing to open; the API column proves the base `snapshot` column is
  refused for every reader. The masked view's behaviour is fixture 247 arm PT.
- **The hr role** is not on any live account, so it is not a row. Its codes are in `docs/role-matrix.md`.

## §2 · Pages — every changed route, with its file

| route | files | what changed |
|---|---|---|
| `/finance/journal/[id]` | `app/finance/journal/[id]/page.tsx`, `JournalLinesTable.tsx` | reads `journal_lines_masked`; a restricted amount and the total row read **Restricted**; memo shown |
| `/finance/journal` | `app/finance/journal/page.tsx`, `JournalTable.tsx` | an entry with restricted lines shows its amount as Restricted, never 0.00 |
| `/finance/journal/export` | `app/finance/journal/export/route.ts` | `journal_export_lines()`; amount cells print `Restricted` |
| `/finance/trial-balance` | `app/finance/trial-balance/page.tsx` | `trial_balance_totals()` (owner rights) — same totals for every reader |
| `/finance/close` | `app/finance/close/page.tsx` | `journal_close_preview()` (owner rights) |
| `/finance/ledger/[account]` | `app/finance/ledger/[account]/page.tsx`, `LedgerRowsTable.tsx` | per-line amounts Restricted; period total unchanged |
| `/finance/bank/statements/[id]` | `app/finance/bank/statements/[id]/page.tsx` | matched journal lines read through `journal_lines_masked` |
| `/finance/bank/statements/[id]/reconcile` | `…/reconcile/page.tsx`, `ReconcileWorkspace.tsx` | same; a restricted candidate amount renders Restricted |
| `/hr` | `app/hr/page.tsx` | reads the masked payroll / leave views |
| `/hr/payroll` | `app/hr/payroll/page.tsx`, `PayrollPeriodsTable.tsx` | period totals behind `data.view_pay` |
| `/hr/payroll/new`, `/hr/payroll/[id]/edit` | `app/hr/payroll/loadGridData.ts`, `app/hr/payroll/[id]/edit/page.tsx` | read `payroll_periods_masked` |
| `/hr/payroll/[id]` | `app/hr/payroll/[id]/page.tsx`, `PayrollLinesTable.tsx`, `PostControls.tsx` | totals and the posting preview Restricted without `data.view_pay` |
| `/hr/leave` | `app/hr/leave/page.tsx` | reads `leave_requests_masked` |
| `/hr/leave/[id]` | `app/hr/leave/[id]/page.tsx` | reason · certificate · exception reason Restricted without `data.view_health` (own excepted) |
| `/hr/claims` | `app/hr/claims/page.tsx`, `ClaimsTable.tsx` | amount Restricted without `data.view_health` |
| `/hr/claims/[id]` | `app/hr/claims/[id]/page.tsx` | description · amount · the year's balance Restricted without `data.view_health` (own excepted) |
| `/hr/employees/[id]` | `app/hr/employees/[id]/page.tsx` | embeds `payroll_periods_masked` |
| `/me` | `app/me/page.tsx` | payslip currency from `my_period_labels()` (Q12); leave via `leave_requests_masked`; KPI only via `my_kpi_entries` |
| every page's audit trail | `lib/trail/render.ts` | a restricted journal line reads `…: Restricted` (was `Credit 0.00 SGD`); restricted leave text reads Restricted; `vline` keeps a restricted value instead of dropping the line |

## §3 · Verification, in the brief's order

| # | step | result | source |
|---|---|---|---|
| 1 | offline gate | `GATE_OFFLINE_EXIT=0` (4th run; runs 1–3 red, see §6 d19–d21) | `logs/gate-off4.log` |
| 2 | backup (background) | `BACKUP_EXIT=0` — `evoltrya-backup-2026-10-05-1623.dump`, TOC 7324 (previous 7321) | `logs/backup.log` |
| 3 | apply_migration | committed; **window start 2026-10-05 16:40:23 CST** (`db/migration-windows.tsv`). Attempts 1 (16:36:38) and 2 (16:37:31) failed in their proof and rolled back whole | `logs/apply{,2,3}.log` |
| 4 | types | `TYPES_OWN_EXIT=0` | `logs/types.log` |
| 5 | tsc | `TSC_OWN_EXIT=0` | `logs/tsc4.log` |
| 6 | build | `BUILD_EXIT=0` (3rd run; run 1 `check-masked-reads` named 7 reads, run 2 the eslint freeze named an unused variable in the new probe). **Rebuilt after the probe gained three checks, and again after the docs: `BUILD_EXIT=0` both times.** The gate's inputs (mirrors, fixtures, migration) did not change after the gate | `logs/build3.log`, `logs/build4.log`, `logs/build5.log` |
| 7 | full gate | `GATE_EXIT=0` — 可重建性 ✓ · 镜像 vs 线上 ✓ · 行为断言 ✓ (fixture 247 included) · 匿名面 ✓ (live 326 ⊂ baseline 327); 419 s | `logs/gate.log` |
| 8 | i18n | `I18N_OWN_EXIT=0` (rerun after the gate) | `logs/i18n2.log` |
| 9 | error swallowing | `SWALLOW_OWN_EXIT=0` — 0 unallowed (rerun after the gate) | `logs/swallow2.log` |
| 10 | layout survey | **1280 px: 18/18 usable**; **390 px: 15/15**, plus the three concrete pages (pay-run journal, MC-2026-0001, LV-2026-0006) **3/3** at 390. 0 overflow, 0 clipped. Two routes redirect (no open statement to reconcile; PAY-2026-0001 not editable) | `logs/survey{1280,390,390b}.log` |
| 11 | smoke (background) | `SMOKE_EXIT=0` — 260 ok · 9 skipped (no data) · **0 FAILED** | `logs/smoke.log` |
| 12 | live verification | §1 (probe), §5 (proof, before/after) | |

**Smoke's scratch-cleanup reading:** the check reported the same **6** stale rows before and after the run, all pre-existing
(`ZZ-SMOKE-PROBE` · `ZZ-SMOKE-M25` · `ZZ-SMOKE-NTF` · `ZZ-SMOKE-S25` · `ZZ-SMOKE-CJK` · `ZZ-SMOKE-IB25`, 794–1437 h old; 5 still referenced,
"不要直接删"); `npm run check:scratch` after the smoke → the same 6 (`SCRATCH_OWN_EXIT=1`, its "stale rows exist" code). As postgres after
every harness run: `auth.users` like `%@test.local` **0** · their `user_roles` **0** · `roles` like `probe-%` **0** · `ZZ-SMOKE-U1A%` employees **0**.

**Survey limit:** the survey signs in as an ephemeral admin, so it measured each page with the amounts shown. The Restricted
rendering is checked as text by the probe (§1), not as layout.

## §4 · Fault injection — every arm made to fail on purpose

**Fixture 247** (`db/fixtures/247-pay-and-personal-data-follow-each-role.sql`), 11 arms: JA · JM · JT · JR · PT · KP · EN · HL · CU · EQ · AN.
`db/scripts/2026-10-05-u1a-fixture-injections.py` on a local rebuild of the current mirrors (`REBUILD_OWN_EXIT=0`):
**clean run green, 19 injections, 0 wrong — each red in the arm it names** (`INJECTIONS_OWN_EXIT=0`, `logs/inj3.log`):

| arm | injection | went red with |
|---|---|---|
| JA | drop the restrictive policy | a reader without data.view_pay reads 17 payroll journal line(s) through the API |
| JM | masked view stops masking | every payroll amount must be Restricted, 0 of 17 |
| JT | `trial_balance_totals` → invoker | trial_balance_totals … differs from the ledger |
| JT | `bank_book_balance_asof` → invoker | the 1000 bank book … is 0.00 — the ledger says -13530.00 |
| JT | `journal_close_preview` → invoker | journal_close_preview … differs from the ledger |
| JR | `trail_row_visible` applies `amounts:` policies | the pay-run lines must be on the trail … 0 lines |
| JR | `pay_journal` rule answers visible | … 3 lines, 0 restricted |
| PT | grant `gross_total` back | expected 42501, got {"gross_total": 12000.00} |
| PT | approval amount of a payroll request visible | an approval row of a payroll request must not carry its amount |
| KP | restore the kpi self-read policy | the employee must not read their own KPI entries through the base table |
| EN | grant `employees.notes` back | expected 42501, got {"notes": …} |
| EN | `employees_masked` gives the employee their notes | the employee reads their own row with HR's notes withheld |
| HL | `medical_claims_masked` keyed on hr.view | health text must be Restricted to a reader without data.view_health |
| HL | grant leave `reason` back | expected 42501, got {"reason": …} |
| HL | `medical_claim_balance` back to the NULL-trap gate | the claim balance … is refused by name to a reader without data.view_health |
| CU | `my_period_labels` drops the currency | … reads the payslip's own currency (USD), got <NULL> |
| EQ | the advice view unmasks repair spend | a processing-only reader reads the advice without the repair spend … |
| AN | anonymisation keeps the leave reason | anonymisation erases the free text and keeps the amounts in the four tables |
| AN | redaction skips medical descriptions | 3 change-log row(s) of the person still carry free text … |

**Trail goldens:** `scripts/check-trail-wording.mjs` gained two goldens (a leave request read without view_health; a payroll
journal read without view_pay). With the renderer fix backed out they went red — ⑧ (the payroll journal) and ⑫ (the leave request), 1 each (`logs/tw-inj.log`) — and are green now.

**Probe** — three injections, each red on exactly the check it names, everything else green (106 passed · 1 failed each):
`--inject=cto-sees-pay` → `journal [cto] API` · `--inject=screen-zero` → `journal [cto] screen` · `--inject=warehouse-cost` →
`maintenance advice [warehouse] API` (`logs/probe-inj-*.log`).
**One injection run's cleanup was hit by network timeouts:** the `cto-sees-pay` run could not confirm three throwaway grant revokes
(`PINJ_EXIT=6`, plan left in `.ephemeral/62638.json`). The next run reaped that plan before it began (`收割上一次没跑完的清理 … 17 步`).
Measured as postgres afterwards: 0 throwaway accounts, 0 grants, `.ephemeral/` empty.

## §5 · Live verification — before and after

**Before** 2026-10-05 16:18:10 CST, **after** 19:01:48 CST — `db/scripts/2026-10-05-u1a-live-readings.sql` (every public base table: row
count + digest, as postgres) and `db/scripts/2026-10-05-u1a-live-reports.sql` (one rolled-back transaction, **as each live account
holding module.finance.view**, by JWT).

**Reports — identical for every reader:** 24 of 24 readings equal, digest for digest (6 finance readers × trial balance · P&L 2026 ·
balance sheet · AP/AR recon). AP/AR: `ap 416988.32/376404.42 unexplained 0.00 agrees true · ar 57545.87/43002.12 unexplained 0.00
agrees true` before and after, for every reader. (The before trial balance summed `journal_lines` as the reader — the page's old
read; the after reading calls `trial_balance_totals()` — the page's new read.)

**Tables — 243 before, 243 after; every difference explained:**

| table | before → after | why |
|---|---|---|
| `permissions` | 72 → 73 | `data.view_health` (Q8) |
| `role_permissions` | 338 → 343 | `data.view_health` to admin · hr · cco · cfo · finance |
| `document_types` | 41 → 41, digest changed | 3 rows' search columns (§6 d12) |
| `cod_verification_failures` | 1 → 1, digest changed | the rate-limit log of the public COD-verify page: smoke's `/verify/cod/[token]` probe writes one failure by design (row stamped 17:24:14; the smoke ended 17:26:04). Not a document |
| change log (`~summary`) | 5495 rows / seq 6545 → 5815 / 6874 | +320, every row after seq 6545 accounted for (as postgres, `change_log` grouped by table and op): harness throwaways created and removed in pairs — `user_roles` 47/47 · `employees` 17/17 · seeded probation reviews 5 inserted, 5 updated, 5 deleted · smoke's contract and its terms 9/9 · smoke's ephemeral role 1/1 with its 73 codes 73/73; the migration — `permissions` +1, `role_permissions` +5, `document_types` 3 updates; the COD row pair 1/1 |

Every other table — every pre-existing document — has the same row count and digest. **Accounts:** before and after,
`admin@=admin · chooer@=finance · fusheng@=warehouse · phua@=cto · sandra@=cco · tim@=cfo · vince@=gm`, 0 disabled, 0 throwaway,
approvals ON, 0 grants without an account. Roles unchanged apart from the `data.view_health` grants.

**Anonymisation proof** — `db/scripts/2026-10-05-u1a-live-proof.sql`, psql as postgres, **one transaction, ROLLBACK**
(`PROOF_OWN_EXIT=0`, 19:01:30 → 19:01:36 CST). It builds its own separated employee (`ZZ-U1A-PROOF`) with a salary request, a
payroll line in its own period, a leave request and a medical claim, each carrying `U1A-PROOF-SECRET`, changes each once,
then anonymises as admin@ — and asserts:

| reading | value |
|---|---|
| change-log rows of the four documents | 12 |
| change-log rows still carrying text or unredacted | **0** |
| kept in the log | leave `days 1` · medical `amount_sgd 120` · payroll `gross_pay 3300` · salary `new_monthly_salary 3300` |
| table text erased, amounts kept | yes |

It touched no pre-existing document; the one existing row it changed (`hr_settings.personal_data_retention_months`) is a setting,
and it rolled back with the rest.

### §5.1 · Broken window

| | value | source |
|---|---|---|
| start | **2026-10-05 16:40:23 CST** | `db/migration-windows.tsv` (`2026-10-05T16:40:23+0800	2026-10-05-u1a-pay-and-personal-data.sql	05e26c45`) |
| end | Tim's Vercel reading (to be recorded at the next close-out) | a report, not a measurement from this machine |

**What is broken inside it (derived from the old code and the revoked grants, not measured on live):** pages that read a revoked column
directly — payroll periods (list and detail), payroll requests, leave requests (list and detail), medical claims (list and detail),
the payroll periods embedded in an employee page, and /me's leave — fail with 42501 for everyone; the journal page, trial balance, month
close, GL export and ledger silently lose the payroll journal lines for readers without `data.view_pay` (cto · gm) until the new code
reads the masked view and the owner-rights totals. The window is longer than a cut's usual because the live verification ran inside it.

## §6 · Decisions taken without asking

1. **"What is pay" is decided by `source_type = 'payroll'`** on the entry. Reversals copy `source_type`, so they are covered with no
   second rule (Q2).
2. **The API hides payroll lines whole; the screen and the trail show them masked.** PostgREST cannot null a column per row, so the base
   table gets a RESTRICTIVE policy and pages read `journal_lines_masked`. To keep the trail matching the screen, `trail_row_visible()`
   skips restrictive policies whose name starts with **`amounts:`** — a naming convention, written in the function and in change-log §10.1.
3. **Owner-rights reads beyond the four named in Step 0.** Measuring for silent row-drops found four more: `bank_book_balance_asof()` (now
   SECURITY DEFINER), and the views `bank_unmatched_journal_lines`, `fx_rate_gaps`, `fx_month_end_readiness` (owner rights, each with a
   `module.finance.view` arm). Without them cto's bank book and FX checks would have shrunk. Fixture 247 JT pins the bank book.
4. **`account_ledger()` masks each line's amounts; its period total is unchanged** — the total is the account's, not a person's.
5. **The GL export prints `Restricted` in the three amount cells** rather than leaving them blank (a blank reads as zero in a spreadsheet).
6. **The bank statement pages read matched journal lines through the masked view** (two steps: matches → `journal_lines_masked` →
   entries). The statement's own copy of the transfer is out of scope (Q4) — `UNBLOCK1-BANK-STATEMENT-SHOWS-PAY`.
7. **`approval_log`'s amounts are masked too.** They carried a payroll request's total and a medical claim's amount to anyone who can read
   the approval row. New `approval_log_amount_visible()`: payroll request → `data.view_pay`; medical claim → `data.view_health` or own;
   anything else unchanged. The policy's read rule became `approval_log_readable()`, shared with `approval_log_masked`.
8. **`medical_claim_status` masks the same health fields**, and **`medical_claim_balance()` is gated on `data.view_health` or own** —
   a year's claimed total is a health amount.
9. **Fixed a pre-existing NULL-trap in that gate.** `IF NOT (has OR p_employee = current_user_employee())` let a reader with **no
   employee record** through (NULL). Now `COALESCE(…, false)`; injected in §4. **Nine leave functions have the same shape; not fixed here
   — registered as `U1A-SELF-GATE-NULL-TRAP` for U1-B** (they gate writes, not visibility).
10. **HR's notes are gated on `module.hr.view`, not `data.view_health`** — they are HR's working notes, not health data (Q6).
11. **The PDPA exception is written beside the code** (`db/functions/export_my_personal_data.sql` header) and in known-issues
    `U1A-EXPORT-KEEPS-HR-NOTES` (Q7). The function body is unchanged.
12. **Search no longer matches or labels documents by a masked column** (`document_types`: employee by legal / preferred name only; leave and
    medical match decision notes and receipt ref, with no label column). Otherwise a search for a diagnosis would find the claim for
    anyone. Cost registered as `U1A-SEARCH-NO-HEALTH-OR-NOTES`.
13. **Anonymisation writes `ANONYMISED` where a constraint forbids null** (salary request `reason`; `decision_notes` of a rejected
    request; `exception_reason` of an exception leave) and null everywhere else; log rows get JSON null.
14. **The table-level REVOKEs name `anon` beside `authenticated`** on `approval_log`, `employees`, `medical_claims`, `leave_requests`,
    `payroll_periods` (RLS already gave anon 0 rows; the column GRANTs go to `authenticated` only). Live is a strict subset of the anon baseline (326 ⊂ 327); I did **not** tighten
    `db/anon-grants-baseline.tsv` — it is a ceiling and still holds.
15. **Bootstrap grants for `data.view_health`** go to the bootstrap `finance` and `hr` roles in `db/tables/role_permissions.sql`; the bootstrap admin is system-only by
    Tim's ROLE-1 ruling, and the live admin gets every new code in the migration itself (the standing rule in that file). Live got
    admin · hr · cco · cfo · finance, as Tim ruled.
16. **Equipment advice: the three cost columns read null** without `module.finance.view`; the rows stay (Q13 offered null-the-columns or
    close-the-view; nulling keeps the maintenance advice useful to processing).
17. **The journal page's total row is Restricted if any line is** — a total over hidden lines is the hidden amount.
18. **`my_period_labels()` gained a column, so the migration DROPs and re-CREATEs it** (a return type cannot change in place); its
    grants are replayed.
19. **Three existing fixtures changed with the rules they test:** 218 C3 writes `gross_total = 1` as a constant (it had read the revoked
    column); 246 Q19 expects the fifth key `currency`; 32's decider role gets `data.view_health` (it decides a medical claim).
20. **The offline gate's first three reds** were those fixtures plus 100/8 and 199F (their `document_types` expectations). Fixed in the
    mirrors/fixtures, not by relaxing a check.
21. **Two failed apply attempts:** the precondition expected 79 mask rules, live had 81 (my miscount); then the proof's temp table needed
    a grant to `authenticated`. Both rolled back whole; the third committed. Only the committed attempt is in `migration-windows.tsv`.
22. **The live role table uses throwaway accounts holding the real roles**, not the 7 real accounts (no passwords; real accounts untouched).
23. **Two self-found leaks are registered, not fixed:** a payroll journal's reversal request carries the entry's amounts
    (`U1A-PAYROLL-REVERSAL-REQUEST-SHOWS-AMOUNT`), and the expense a medical claim generates shows its amount on the finance side
    (`U1A-MEDICAL-EXPENSE-AMOUNT-ON-FINANCE-SIDE`). Both are new shapes (a request table; a finance document), outside Q1–Q13.
24. **Stale queue rows struck:** `docs/forward-queue.md`'s IOD-1 and PayrollGrid rows (Step 0 §5), and known-issues IOD-1 closed in place.
25. **The probe gained three checks after the first build** (journal list summary "never 0.00"; no bare 0.00 on the pay-run page; the
    employee's own HR notes refused on the base table) — the brief names the summary page and the employee's notes. The build was rerun.

## §7 · Docs updated

`docs/role-matrix.md` (the code row and five visibility rows) · `docs/change-log.md` (§4 counts and forms, §5 redaction scope, new §10) ·
`docs/known-issues.md` (7 UNBLOCK-1 entries and IOD-1 closed in place; new: `UNBLOCK1-BANK-STATEMENT-SHOWS-PAY` (Q4),
`U1A-EXPORT-KEEPS-HR-NOTES` (Q7), `U1A-PAYROLL-REVERSAL-REQUEST-SHOWS-AMOUNT`, `U1A-MEDICAL-EXPENSE-AMOUNT-ON-FINANCE-SIDE`,
`U1A-SELF-GATE-NULL-TRAP`, `U1A-SEARCH-NO-HEALTH-OR-NOTES`) · `docs/forward-queue.md` (item 34: U1-A closed, window start; the UNBLOCK-1
section split into U1-A ✅ and **U1-B next**).
