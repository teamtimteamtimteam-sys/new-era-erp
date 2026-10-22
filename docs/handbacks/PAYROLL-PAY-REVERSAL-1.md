v1.4.66 — A wrong salary, CPF or deductions payment can now be reversed: finance asks from the payroll payments page, the CFO approves, finance carries it out with the date the money came back; the period stays posted and the payment can be made again. A payment already matched to a bank statement line is not reversed until it is unmatched — on the payroll, payment, bank-transfer and withholding-tax reversals alike. New starters get sick, hospitalisation, childcare and parental leave by length of service, and /me shows every kind of leave's balance.

# PAYROLL-PAY-REVERSAL-1 — hand-back (2026-10-22)

The brief "PAYROLL-PAY-REVERSAL-1" with Tim's rulings on Step 0 (Q1–Q13), 2026-10-22. Part 1 closed CLAIM-RECEIPTS-1 (`docs/handbacks/CLAIM-RECEIPTS-1.md` §6).
Started from `5709a2c06aea49d54105b7ffbb4bba56fa316bf7` (HEAD = origin/main = ls-remote, tree clean).
Survey: `docs/surveys/PAYROLL-PAY-REVERSAL-1/step0-survey.md`. Readings: `docs/surveys/PAYROLL-PAY-REVERSAL-1/readings/`.

## 1 · What changed, against each ruling

| Ruling | What | Proof |
|---|---|---|
| Q1 the request | `payroll_requests` gets a third kind `payment_reversal` with `target_entry_id` (the payment entry). Raise: `submit_payroll_payment_reversal_request(entry, reason)` (`module.hr.edit`, reason required). Decide: the unchanged `decide_payroll_request` (CFO, level 2, no threshold, raiser can never approve). Execute: `reverse_payroll_payment(request, date)` (`module.hr.edit`, raiser may). Approvals off → born approved with `auto_approved`. One open request per period and the period freeze apply unchanged. | fixture 288 A · D · G · L; live proof T1 · T2 |
| Q2 whole entry | The unit is the journal entry one pay call posted (or the CPF / deductions remittance); no per-line reversal exists. | 288 I |
| Q3 date at execution | The date is given only to `reverse_payroll_payment`; required in the form (button disabled while empty), in the action and in the database (`REVERSAL_DATE_REQUIRED`). | 288 H2 |
| Q4 date rules | Not after today (`DOCUMENT_DATE_IN_FUTURE\|payroll_payment_reversal`, the six cash doors' rule); not before the payment (`REVERSAL_BEFORE_ORIGINAL`, the ledger's own); inside a locked period → `PERIOD_LOCKED`. The original stays in its (closed) month. | 288 H3–H5, I1; live proof T3 |
| Q5 after | Period stays `posted`; the lines whose `paid_journal_entry_id` is the entry (net-zero lines included) lose `paid_at` and the link; CPF / deductions lose that remittance's date and link. Can be paid again; with no payment left the unpost request's dry run passes. | 288 I2–I4, J, K2–K4 |
| Q6 bank match | `assert_entry_not_bank_matched` refuses `REVERSAL_BANK_MATCHED\|entry\|statement\|open\|reconciled` inside the four reversal engines (payroll payment · `reverse_payment_internal` · `reverse_bank_transfer_internal` · `reverse_wht_remittance_internal`); submit and approve dry-run the same engine, so raise / approve / execute all refuse. No automatic unmatching. Registered and struck: `docs/known-issues.md` § REVERSAL-OF-A-BANK-MATCHED-ENTRY. | 288 F1 · F2 · H6 · K0; 289 (one arm per path); live proof T4 |
| Q7 one kind | `payroll_payment_entry_kind(entry)` reads the stamps (`salary` / `cpf` / `deductions`); the engine clears the matching stamps. | 288 B · K1 |
| Q8 generic route | `journal_entry_reversal_route` answers `payroll_payment` for payment entries and their reversals (recognised by the stamps, or — once the stamps are cleared — by the payment-reversal request that targeted them); `reverse_journal_entry`, the journal reversal request's submit and post refuse `JE_REVERSE_USE_PAYROLL_PAYMENT_REVERSAL`. The voucher page's button is visible, unpressable, and links to the payroll payments page. | 288 C · I5 · I6; live proof T1, H2 |
| Q9 pay while pending | The period fingerprint never contained the paid stamps, so other unpaid lines can still be paid while a payment reversal waits. | 288 E |
| Q10 service | Completed months from `hire_date` to the leave's start date (`age()`, a part-month does not count). | 290 C |
| Q11 per-type rules | Four columns on `leave_types` (`qualifying_service_months` · `service_rule` full / steps / prorate_first_year · `service_steps` · `prorate_minimum_days`), values = the ruling; `leave_service_entitlement` computes; `leave_balance_internal` reads it for every non-annual quota type (submit and approval both pass the start date). | 290 A · B · B2 · D; live proof T5 |
| Q12 /me | `leave_balances(employee)` — one call, every active quota type (12, annual first), each with `gender_restriction`; `/me` draws "Every leave type" (Taken · Available), maternity / paternity marked "Depends on eligibility"; annual's six figures and breakdown still drawn from the same call. | 290 E; live proof H3 · H4 |
| Q13 | Not done (separate cut, LEAVE-BAL-1 Q4). | — |

**The childcare proration, in one paragraph for HR (Tim's instruction):** for childcare leave (6 days a year) and extended childcare leave (2 days a year), an employee gets nothing until 3 completed months of service; from then until 12 completed months they get the year's days × completed months ÷ 12, rounded to the nearest whole day with an exact half rounded up; childcare leave is never less than 2 days once eligible; from 12 completed months, the full year. Completed months are counted from the hire date to the first day of the leave, and a part-month does not count. That gives childcare 2 · 2 · 3 · 3 · 4 · 4 · 5 · 5 · 6 days at 3 … 11 months and extended childcare 1 · 1 · 1 · 1 · 1 · 1 · 2 · 2 · 2. **Measured consequence:** with 6 days a year the 2-day minimum never changes an answer (3 months already gives 1.5 → 2); the first injection matrix proved it (removing the minimum left fixture 290 green), so 290 B2 tests the column with a 2-day quota. HR's check against MOM's own calculator is `docs/manual-walk-list.md` §35.1 and Tim's d1 item 47.

## 2 · Verify chain (every exit read from the script's own line)

| # | Step | Result |
|---|---|---|
| 1 | offline gate | `GATE_EXIT=0` (126 s, fourth run; `readings/gate-offline.txt`). Run 1 red: fixture 288 had no level-1 holder; 289 called two engines without a session; the definer check named `reverse_payroll_payment_internal` (now allowlisted with its reason in `db/check_mirrors.py`, EXECUTE revoked). Run 2 red: 289 passed a date to a payment reversal (`PAYMENT_REVERSAL_TAKES_NO_DATE`). Run 3 green; run 4 after fixture 290 gained arm B2, green. |
| 1b | fixture fault injections | **27 / 27** bite, `INJ_OWN_EXIT=0` (`readings/fixture-injections.txt`, `db/scripts/2026-10-22-payroll-pay-reversal-1-fixture-injections.py`). First run 23 / 27; three misses were layered refusals (the journal request's post re-refuses after its submit; the engine re-refuses an unknown entry after submit; `leave_balances`' gate is repeated in `leave_balance_internal` and in three annual-accrual readers) — each cell now lifts every layer; the fourth was the childcare minimum above (fixture arm added). |
| 2 | backup | `BACKUP_EXIT=0` — `evoltrya-backup-2026-10-22-1042.dump` + 17 change_log chunks, 76,376 rows = count, seq 1 / 83,823; 10:42 → 11:05 CST |
| 3 | live dry run COMMIT→ROLLBACK | `DRY_OWN_EXIT=0` — inside: 328 tables, `target_entry_id` on the table and the masked view, submit executable / engine not / anon not, JE-2026-0017 `source_path` and 0018 / 0019 / 0020 `payroll_payment`, leave rules = the ruling, exclusions 9, gaps []; after rollback: no column, no function, 0018–0020 back to `request` |
| 4 | apply | `APPLY_OWN_EXIT=0`; pre-flight 18 CREATE FUNCTION (9 replaced · 9 new, incl. the self-proof's pg_temp helper), 4 account codes all system; **broken window start 2026-10-22 11:15:48 CST** (`db/migration-windows.tsv`) |
| 5 | types | `TYPES_OWN_EXIT=0` (after the migration's `NOTIFY pgrst` and 20 s) |
| 6 | tsc | `TSC_OWN_EXIT=0` (second run; first red on nullable period ids from `payroll_period_lookup`) |
| 7 | build | `BUILD_OWN_EXIT=0`, first run (the trail catalogue needed the five new columns in `docs/surveys/AUDIT-TRAIL-0/labels.csv` first — caught by `check-trail-wording` ③ before the build) |
| 8 | full gate | `GATE_EXIT=0` (743 s), first run: rebuild · mirrors vs live (incl. types) · all fixtures (288 · 289 · 290 ✓) · anon (327) · no-role (126) · portal (42) |
| 9 | i18n | `I18N_OWN_EXIT=0` |
| 10 | error-swallowing | `SWALLOW_OWN_EXIT=0` |
| 11 | layout survey, 4 touched pages | 390 px: 4 / 4 usable, 0 overflow, 0 clipped; 1280 px: 4 / 4, 0, 0 (`/finance/payroll-payments`, PAY-2026-0001, JE-2026-0018, `/me`) |
| 12 | smoke | **`SMOKE_EXIT=0`** — 303 routes + the content / nav probes: 304 ok · 25 skipped (no data) · 0 failed (`readings/smoke.txt`). The build for `next start` that followed hit Google Fonts once (`Failed to fetch Geist`, a network failure); retried once immediately, green (fonts answered 200 in 1.7 s). |
| 13 | live proof | **`PPR1_PROOF_EXIT=0`**, first run (`PROOF_BASE` = `next start` on this tree, against live; `readings/live-proof.txt`): H1–H4 over HTTP / PostgREST (payments table with three entries and their buttons; the voucher page's pointer; `/me`'s "Every leave type" for a throwaway new starter; `leave_balances` 12 items, sick 0, another employee refused); T1–T5 inside one rolled-back transaction with real session claims (generic route refused; a finance copy raises a reversal of JE-2026-0018; a throwaway holder of the real `cfo` role approves; execution refuses a date before the payment and tomorrow, then reverses today — 1 line unpaid again, period still posted, CPF untouched; a CPF payment matched to a statement line is refused at raise; a new starter's sick leave is 0 and a request is refused). After rollback the three payments, every stamp, payroll requests (0), journal entries (83), bank statements (2) and leave requests (6) were unchanged. |
| 14 | fresh clone, no `.env.local`: `npm ci && npm run build` | in the close report (it builds the commit that contains this file) |

**Read back as postgres after the live steps** (`readings/readback.txt`): approvals ON (finance / cfo / 1,000); 7 real accounts, 0 disabled, roles admin · finance · warehouse · cto · cco · cfo · gm unchanged; throwaway users 0 · roles 0 · employees 0 · orphan grants 0; both CODs (`ba299a4f…`, `717661f6…`) unchanged; `require_calibrated_since` NULL; JE-2026-0017–0020 all posted, payroll requests 0, bank statements 2; `portal-uploads` bucket and its 3 policies untouched, `claim-receipts` 0 objects; reconciliation (as tim@) AP 0.00 · AR 0.00 unexplained.

**Broken window — what is broken in it (derived):** the old voucher page still offers "Request reversal" on a payroll payment entry; pressing it is refused by the database with the new code, which the old app does not know (it shows the raw text). The old `/me` asks `leave_balance` for annual leave only (signature unchanged) — unaffected. The old payroll payments page has no reversal; nothing it calls changed signature. Sick / hospitalisation / childcare / parental balances drop to 0 for live employees under 3 months (all six today), in both old and new app — that is the ruling taking effect, not breakage (0 non-annual leave requests on live). The end of the window is Tim's reading on Vercel.

## 3 · Not measured, handed to Tim

- **One real payroll payment reversal on production** — the live proof cannot commit; `docs/manual-walk-list.md` §35.3.
- **HR's check of the childcare proration against MOM's calculator** — §35.1, d1 item 47.
- **`/me` with a real employee profile at 390 px** — the layout survey's session has all codes but no employee profile, so `/me` was measured in its no-profile state; §35.2.

## 4 · Assertions in the brief measured false

One: the brief points to "docs/known-issues.md … the /me leave-balance entry" — there is none; that item lived only in `docs/forward-queue.md` (LEAVE-BAL-1 Q15), where it is now closed.

## 5 · Decisions taken without asking

1. **A new submit function** (`submit_payroll_payment_reversal_request(entry, reason)`) rather than a new parameter on `submit_payroll_request` — a new parameter is a signature change the pre-flight refuses as an overload; the request's period comes from the entry.
2. **A reason is required** on a payment reversal (the same check constraint as the period reversal) — the CFO reads it and it goes on the reversing entry's memo.
3. **The approval log's amount stays the period's gross** (N4; the chain is not tiered). The payment's own amount is shown on the payroll payments page and the request panel.
4. **Submit / approve dry-run with today as the probe date** (`reversal_date_for`); the real date is judged at execution.
5. **Execution lives on the payroll period page** beside the other two kinds' execute buttons; raising lives on the payroll payments page, where Q8's refusal points.
6. **The payroll payments page shows only payments still standing**; a reversed one leaves the table (its history is the trail and the reversed entry).
7. **`payroll_payment_entries(period ids)`** — one reader for the page and the request panel (amounts NULL without `data.view_pay`, gate finance.view or hr.view).
8. **`leave_service_entitlement` as its own function** with the rules as `leave_types` columns; `service_steps` is a small JSON map (month → days).
9. **"At least 2 days" applies to childcare only**, not extended childcare (the ruling names childcare leave); recorded so HR can say otherwise.
10. **The bank-match refusal is one code with the statement's state as a parameter**; the sentence tells both steps (unmatch; unreconcile first if reconciled).
11. **Throwaway prefix `ppr1probe`**; fixtures 288 · 289 · 290.
12. **The leave-type editor (`/hr/leave/types`) does not edit the four new columns** — they change by migration; the trail names them if they change.

## 6 · Close-out (TABLE-EXPORT-1 Part 1, 2026-10-22)

- **Pushed commit:** `daec5c952939f0ca9aaa5a4335fa188d473ce321` (`v1.4.66`); HEAD = origin/main = `git ls-remote origin main`, tree clean, re-read at the start of TABLE-EXPORT-1.
- **Broken window: opened 2026-10-22 11:15:48 CST** (migration committed; printed by `apply_migration.sh`, `db/migration-windows.tsv`) — **closed 2026-10-22 19:07 CST**
  (Tim confirmed the deployment on Vercel; **this end point is Tim's report, not a reading this machine took**). **Length ≈ 7 h 51 min** (11:15:48 → 19:07; the seconds of the end are not known).
  **The length is the gap before Tim saw the report, not a failure** — the deployment itself was not observed failing. Broken in it: as derived in §2 (the old voucher page offered "Request reversal" on a payroll payment and showed the database's raw refusal if pressed).
- **A `.next` delete ran although the tool call showed as rejected** (Tim's report, during this cut's session). This machine did not observe it; it is recorded here as Tim stated it. Per the TABLE-EXPORT-1 brief, a recurrence stops the cut and is reported.
- **Read-only check on production (2026-10-22 ≈ 19:10 CST, after Tim's confirmation)** — `docs/surveys/TABLE-EXPORT-1/readings/ppr1-closeout-production-check.txt`, `CLOSEOUT_CHECK_EXIT=0`,
  script `db/scripts/2026-10-22-payroll-pay-reversal-1-closeout-check.mjs`: one finance-clone throwaway (`ppr1probe`, shared helper, with an employee profile hired 2026-09-01) opened on `https://new-era-erp.vercel.app`
  the voucher of JE-2026-0018 (HTTP 200 in 7.7 s; "Request reversal" rendered `disabled`, the line pointing to `/finance/payroll-payments` drawn) and `/me` (HTTP 200 in 8.9 s; "Every leave type" table drawn). GET only.
  Read back as `postgres` (`rolbypassrls`) at 19:11:14 CST: `ppr1probe` accounts 0 · roles created in the last 30 min 0 · `ZZ-PROBE-PPR1*` employees 0 · grants without a user 0 · cleanup plans in `.ephemeral/` 0.
- **PAYROLL-PAY-REVERSAL-1 is closed** (`docs/forward-queue.md` item 63). §3's three items are still Tim's (`docs/manual-walk-list.md` §35).
