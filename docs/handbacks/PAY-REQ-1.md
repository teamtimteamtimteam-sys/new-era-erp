# PAY-REQ-1 · Batch A — money leaves only after approval: payment request → CFO approve → pay (2026-09-23)

**Opening gate:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `8c962a927ca3018a8d5b1106fbf16d73bb948226`
(ROLE-1 Batch 1). **Approvals were ON and stayed ON.**

**Batch A** covers payments and their reversals. **Batch B** (bank transfers and their reversal, WHT remittance) is
queued in `docs/forward-queue.md` § PAY-REQ-1 Batch B. **Between the two batches, transfers and WHT still leave without
approval** (Tim, Q15).

---

## §0 · ROLE-1 Batch 1's broken window — closed with bounds, labelled by kind

| | time (CST) | kind |
|---|---|---|
| start | 2026-09-23 19:44:46 | `db/apply_migration.sh`'s own line (`db/migration-windows.tsv`) |
| end, lower bound | 20:14:40 | the push (`origin/main` reflog) — no deploy can precede it |
| end, upper bound | 20:24:02 | the first clock reading in this session, taken after Tim's "deployed" confirmation had arrived — **a relayed confirmation, not a measurement of Vercel** |

**Window: at least 29m54s, at most 39m16s.**

---

## §1 · Step 0 (grilling) and Tim's answers

Grilling found:
1. **PO retention release moves no money**: `release_purchase_order_retention` stamps a decision, posts nothing, and
   creates no payable (`docs/equipment-payment-milestones-and-retention.md:328`).
2. **"CFO approves every one"** fits the engine without a second routing definition: the decide function calls
   `require_approver_for(2)` directly. The **trap** it found: `APPROVALS_POLICY_WOULD_STRAND` re-tiers pending documents
   by amount, so a small request would be re-tiered to level 1 and pass unchecked. Hence `fixed_level`.
3. **Side doors** around `record_payment`: direct INSERT policies; `reverse_journal_entry` on a payment's entry;
   expenses and freight documents recorded as paid; manual journals crediting a bank.
4. **Paying an approved expense or medical claim** goes through `record_payment(out, employee)`, and a blanket gate would
   catch payments Tim exempted.
5. The CFO already held three decide codes, and `module.tasks.view` is not purely read-only.
6. The exact cause of the smoke leak.

**Tim accepted thirteen recommendations as written and decided two differently:**
- **Q2:** also close (c). Expenses and freight documents may no longer be recorded as paid at creation. (d) stays open for APR-6.
- **Q5:** drop PO retention release from the lifecycle.

The answers are recorded in `docs/approvals.md` §3j and `docs/role-matrix.md`.

---

## §2 · What shipped

**Migration** `db/migrations/2026-09-23-payreq1a-money-leaves-only-after-approval.sql`. It runs as one transaction and
proves itself before COMMIT, rolling back if any of these fails:
- approvals are still on;
- no pending document changed;
- `approval_log`, `journal_entries` and `payments` did not change;
- `payment_requests` is empty;
- the cfo code list equals the ruling;
- every chain, including the new one, has an approver.

| | change |
|---|---|
| new table | `payment_requests`: `submitted → approved → paid`, plus `rejected` (reason required) and `withdrawn`. Two kinds: `payment_out` (stores `record_payment`'s arguments, with a planned date) and `payment_reversal` (any posted payment, in or out; reason required). RLS read is `module.finance.view`; no write policy; `anon` revoked |
| lifecycle | `submit_payment_request` · `submit_payment_reversal_request` · `withdraw_payment_request` (submitted **or approved**; see the decisions below) · `decide_payment_request` (`require_approver_for(2)`, `forbid_self_approval`) · `pay_payment_request` (the only door that pays a request) |
| engines | the bodies of `record_payment` and `reverse_payment` moved unchanged into `record_payment_internal` and `reverse_payment_internal`, which are revoked from `authenticated` and have no caller check. `reverse_payment_internal` gained the missing `employee_id` on the mirror row: reversing an employee payment would previously have hit the shape CHECK (found by reading at Step 0) |
| shells | `record_payment`: receipts, plus the **Q1 exemption** (`payment_request_required()` = false). Every other outgoing payment gets `PAYMENT_REQUEST_REQUIRED\|payment_out`. `reverse_payment` always refuses with `PAYMENT_REQUEST_REQUIRED\|payment_reversal` |
| checks before money moves | `payment_request_dry_run`: the real engine runs in a sub-transaction that always rolls back, at submit and at approve. `payment_request_conflict`: a document may sit on only one open request at a time. `payment_request_payee_check`: blacklisted or suspended suppliers are refused at submit, approve and pay (Q4) |
| Q2 side doors | (a) policies `payments insert`, `bank_transfers insert`, `bank_transfers update` dropped. (b) `reverse_journal_entry` refuses `source_type` payment or transfer with `JE_REVERSE_USE_SOURCE_PATH`. (c) `record_expense`, `record_freight_document` and `record_export_freight_document` refuse `'paid'`; `record_expense`'s default changed from `'paid'` to `'unpaid'`. (d) is left open: `docs/known-issues.md` PAYREQ1-MANUAL-JOURNAL-CREDITS-BANK |
| engine wiring | `approval_chain_gates`: **one** row (level 2, `{finance.view, view_prices}`). `approval_pending_documents`: a new arm (`blocks_disable = true`) and a new column `fixed_level`. `guard_approvals_switch` reads `fixed_level`. `approval_log`: CHECK plus RLS branch for `payment_request`. `record_approval_decision`: a new branch (raiser = `created_by`, subject = payee employee) |
| CFO | +13 codes, 13 → 26: every `module.*.view` and `data.view_*` plus `module.tasks.view`. **Zero edit codes.** Comments superseded: Q6's identity note, "deleted records: admin and auditor only", and the self-approvals reader list |
| registry | `document_types`: `payment_request` / `PREQ`. `operations_now`: arm `payment_request_pending` |

**Screens** (DBLOCK-1 everywhere: controls stay visible, and are disabled with the code named when the viewer lacks it):
- `/finance/payments/new`: for 'out', the form asks `payment_request_required`. If yes, it submits a request and opens it; if no (exempt), it records as before. For 'out' it shows a notice, a "planned payment date" label, and a "Submit payment request" button.
- `/finance/payment-requests` is a new list (filter: open, submitted, approved, paid, rejected, withdrawn, all).
- `/finance/payment-requests/[id]` is a new detail page with Approve / Reject (reject requires a reason), Withdraw, and Pay (payment date required, optional dealt rate; reversals take neither).
- `/finance/payments/[id]`: "Reverse" is now "Request reversal" (reason required). A link to the open reversal request replaces the button when one exists.
- The expense, freight and asset-maintenance forms no longer offer "paid". The payee is required, with a hint that payment goes through a request.
- `/finance/journal/[id]`: Reverse is disabled with a reason for payment and transfer entries.
- Dashboard reminder; nav entry.
- New shared `app/components/finance/PaymentDateInput.tsx`. The native date input moved there so the date-format ratchet stays at 138.

**Smoke clean-up (Tim, 2026-09-23):** every exit path of `scripts/smoke-routes.mjs` now goes through
`exitAfterCleanup` (new in `scripts/ephemeral.mjs`). So do the three probes with the same defect: `probe-role-crash`,
`render-pdf-samples`, and `probe-permission-gate`, which never ran its clean-up plan at all. See §3 for the proof.

**Fixtures:**
- New: **210** (arms A–L). It asserts the self-approval refusal with no R2 exception, no tiering, the dry run's
  non-posting, the side doors, `WOULD_STRAND` on `fixed_level`, and RLS for two identities.
- Updated, 18 files:
  - 90 · 100a · 101b · 104 · 107 · 135 · 142 · 143 · 67: now call the engine directly. They test posting arithmetic, not approval, and a header note says so.
  - 122 · 129 · 130 · 51: were recording paid expenses or freight; now unpaid.
  - 142 E3/E8, 90I, 100B2: now assert the new refusal. **These are the rule reversals:** "a paid expense with no counterparty can be created" and "a paid freight document cannot be paid again" became "the paid path is closed".
  - 127 B: SOD arms run as owner with claims, plus a new B0 arm: `authenticated` INSERT is refused.
  - 100 · 101 · 111 · 205: counts moved by the new document type, arm and chain.
  - 203: a comment inside `approval_chain_gates` named `require_approver_for` and polluted 203E's catalog count, so it was reworded.

**Decisions made during the build, not asked (say so if any is wrong):**
- **Approved requests can be withdrawn too**, not only submitted ones as Q3 said. Otherwise an approved request whose
  document became unpayable would hold that document forever.
- **One open request per document** (`PAYMENT_REQUEST_TARGET_RESERVED`). This is the simplest rule that stops two requests
  over-allocating one bill. Parallel partial payments on one document cannot be queued at once
  (`docs/known-issues.md` PAYREQ1-OPEN-REQUEST-HOLDS-ITS-DOCUMENTS).
- **The Q1 exemption is narrow:** same currency, allocations summing exactly to the amount. One of the 4 live claims is USD
  (`select currency, count(*) from expense_claims group by 1`, as `postgres`, base table): if approved and paid
  cross-currency, it needs a request.
- **Blacklisted and suspended suppliers only.** `draft`, `pending_review`, `approved`, `active` and `archived` are not
  refused: all 9 live supplier payments went to `draft` suppliers (`select s.status, count(*) from payments p join
  suppliers s on s.id = p.supplier_id group by 1` → `draft|9`, as `postgres`, base tables), and 12 of 17 suppliers are `draft`.
- **Processing-fee payment** (`relieve_processing_accruals` with `'paid'`, `remit_processing_costs`) is untouched. The
  matrix exempts it and it never calls `record_expense`.
- The CFO's **three existing decide codes stay** (Q11).

---

## §3 · Verification — every figure is the script's own exit line

| step | result |
|---|---|
| `db/gate.py --offline` (last run before migrating) | `GATE_EXIT=0` (runs 1–3 went red and were fixed: 19 fixtures, then 5, then green) |
| backup | `BACKUP_EXIT=0`: `evoltrya-backup-2026-09-23-2155.dump`, TOC 6005 (floor 5385) |
| dry run on live (migration with `ROLLBACK`) | clean, twice (`DRY_EXIT=0`) |
| `db/apply_migration.sh` | `APPLY_EXIT=0`. Pre-flight: 22 CREATE FUNCTION (10 replaced, 12 new); 13 account codes, all `is_system`. **Window start 2026-09-23 22:15:37 CST** (`db/migration-windows.tsv`) |
| `NOTIFY pgrst` + `npm run types:gen` | `TYPES_EXIT=0`. The regenerated file equals the hand-written entries except one line-wrap (`withdraw_payment_request`), where the generated form is kept |
| `npx tsc --noEmit` | `TSC_EXIT=0` |
| `npm run build` | `BUILD_EXIT=0` |
| `db/gate.py` (full) | `GATE_EXIT=0`. 可重建性 ✓ · 镜像 vs 线上 ✓ · 行为断言 ✓ (all fixtures, 210 included) · 匿名面 ✓ (baseline 327). 695s |
| `node scripts/check-i18n.mjs` | `I18N_EXIT=0` |
| `node scripts/check-error-swallowing.mjs` | `SWALLOW_EXIT=0` |
| smoke (detached) | `SMOKE_EXIT=0`: 234 routes plus the content and nav probes; 227 timed, 903.2s. Clean-up afterwards, as `postgres` from base tables: `smoke-%` accounts **0**, `probe-%` roles **0**, ghost grants **0**, smoke grants **0**, `ZZ-SMOKE-%` employees **0**; `.ephemeral/` plans **0** |

**Smoke clean-up: forced-failure proof.** Each cell was run through `db/run_detached.sh`. Readings were taken as `postgres`
(`rolbypassrls = t`) from base tables, in the order accounts `smoke-%` / roles `probe-%` / ghost grants / smoke grants /
`ZZ-SMOKE-%` employees / their reviews, then `.ephemeral` plans and port 3199.

| cell | exit | after |
|---|---|---|
| `SMOKE_FORCE_FAIL_AT=after-grant` (fails after the all-codes role is granted) | `SMOKE_EXIT=1` | 0/0/0/0/0/0 · 0 plans · 3199 free |
| `dev-not-ready` | `SMOKE_EXIT=1` | the same |
| `in-finally` (the first delete throws) | `SMOKE_EXIT=1` | the same; clean-up carried on and recorded the failure |
| SIGTERM after the grant line (just before the signal: 2/1/1/3/1 live) | `SMOKE_EXIT=143` | the same |
| **control:** HEAD's old script with the same after-grant injection | `SMOKE_EXIT=1` | **1 account · 1 probe role · 1 grant** left, plus a plan file. Reaped by `node scripts/reap-ephemeral.mjs` (`REAP_EXIT=0`), then re-read as 0 |

---

## §4 · Live proof: refusals, read-backs, and one control lifecycle, all rolled back

`db/scripts/2026-09-23-payreq1-live-proof.sql` → `PROOF_EXIT=0`, **19 of 19 cells**. Identity: connected as `postgres`
(`rolbypassrls = t`); each cell sets `request.jwt.claims` to a real account and runs under `SET LOCAL ROLE authenticated`.
The whole script is one transaction ending in `ROLLBACK`.

| account | cell | result |
|---|---|---|
| chooer@ | `record_payment` out to SUP-2026-0002 | `PAYMENT_REQUEST_REQUIRED\|payment_out` |
| chooer@ | `reverse_payment(PMT-2026-0009)` | `PAYMENT_REQUEST_REQUIRED\|payment_reversal` |
| chooer@ | `record_expense(..., 'paid')` | `EXPENSE_PAID_AT_CREATION_REFUSED` |
| chooer@ | `reverse_journal_entry` on PMT-2026-0009's entry | `JE_REVERSE_USE_SOURCE_PATH\|JE-2026-0063\|payment` |
| chooer@ | direct `INSERT INTO payments` | `new row violates row-level security policy for table "payments"` |
| chooer@ | `record_payment_internal(...)` | `permission denied for function record_payment_internal` |
| chooer@ | **control:** pays her own approved claim CLM-2026-0002 (EXP-2026-0007, SGD 100) in full | posts (Q1 exemption) |
| tim@ | `submit_payment_request` | `PERMISSION_DENIED\|module.finance.edit` |
| tim@ | **control:** `payment_request_required('in', …)` | passes (false) |
| admin@ | `decide_payment_request` | `PERMISSION_DENIED\|module.finance.view` |
| tim@ | **control:** `decide_payment_request` on a random id | passes the gate → `PAYMENT_REQUEST_NOT_FOUND` |
| chooer@ | lifecycle: submit SGD 1.00 against EXP-2026-0001 | `PREQ-2026-0001`, submitted, `amount_base` 1.00 |
| chooer@ | approve her own | `SELF_APPROVAL_FORBIDDEN\|raiser` |
| chooer@ | pay before approval | `PAYMENT_REQUEST_NOT_APPROVED\|PREQ-2026-0001\|submitted` |
| tim@ | pay it himself | `PERMISSION_DENIED\|module.finance.edit` |
| tim@ | approve | approved; **the journal-entry count did not move through submit and approve** |
| chooer@ | pay | PMT-2026-0011 / JE-2026-0081: exactly one entry |
| tim@ vs admin@ | read `payment_requests` / `approval_log` (payment_request) | tim@ **1 / 2** · admin@ **0 / 0** (same session) |
| tim@ | `current_user_permissions()` | 26 codes: every `module.*.view` and `data.view_*`, **zero `.edit`** |

The first two runs stopped on the proof's own mistakes and rolled back:
- **Run 1** refused on `ALLOC_EXCEEDS|EXP-2026-0001|5|1.30`: the expense's face value is not its open amount. Now 1.00.
- **Run 2** stopped on the journal-count check: it counted the exemption payment twice. The reading itself, 83 → 83, was right.

### Before / after — as `postgres`, `rolbypassrls = t`, base tables (`db/scripts/2026-09-23-payreq1-readings.sql`)

Readings were taken before (21:00 CST, before the migration) and after (22:53 CST, after the smoke and the proof). All 16
relations read are `relkind = 'r'`.

| reading | before | after |
|---|---|---|
| `approvals_enabled` / l1 / l2 / threshold | t / finance / cfo / 1000 | **t / finance / cfo / 1000** |
| pending: claims submitted · leave · medical submitted · medical approved-unpaid · reviews · work orders · stocktakes · POs | 1 · 2 · 0 · 1 · 0 · 0 · 5 · 0 | **1 · 2 · 0 · 1 · 0 · 0 · 5 · 0** |
| payment requests open | n/a (table absent) | **0** |
| `approval_log` rows | 14 | **14** |
| `journal_entries` · `payments` | 82 · 13 | **82 · 13** |
| balance, debit positive, all lines: 1000 · 1010 · 2000 | −127,593.48 · −37,340.89 · −376,404.42 | **the same** |
| cfo codes | 13 | **26**: every `module.*.view` and `data.view_*`, plus `module.tasks.view`, plus the three decide codes it already held |

Nothing is pending on live, and no pending document is without a decider: the set is identical to ROLE-1's after-reading.

---

## §5 · The broken window — started, end PENDING

**Start: 2026-09-23 22:15:37 CST** (`db/apply_migration.sh`'s own line; `db/migration-windows.tsv`).
**End: PENDING. Tim reads it from Vercel.**

What is broken while production runs the old app against the new database (approvals ON):
- **Every outgoing payment from the old payment form is refused** with a raw `PAYMENT_REQUEST_REQUIRED|payment_out`.
  That includes supplier payments; the exempt claim payments still post. There is **no screen to raise a request** until
  the deploy lands, so no supplier can be paid on screen during the window.
- **"Reverse" on a payment** is refused with `PAYMENT_REQUEST_REQUIRED|payment_reversal`.
- **Recording an expense or freight document as "paid"** is refused with a raw code; recording it unpaid still works.
- **Reverse on a payment's journal entry** is refused with `JE_REVERSE_USE_SOURCE_PATH`.
- **Unaffected:** receipts, approvals and every other chain, bank transfers and WHT (Batch B), and the CFO's wider reading
  (the new codes take effect immediately; the old nav simply shows more entries unlocked).
- **Nothing is stranded:** no payment request existed before the migration, and none exists now.

---

## §6 · Commit, push, three SHAs

Reported in the hand-back message: `HEAD`, `origin/main` and `git ls-remote origin main` as full 40-character SHAs.
Deployment is Tim's to read; the window's end stays PENDING until he does.
