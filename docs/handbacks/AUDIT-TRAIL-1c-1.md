# AUDIT-TRAIL-1c-1 — the ledger documents' audit trails (journals, invoices, credit notes, payments, payment requests, expenses, payables) and three mechanism changes (M7, the operation key, employee names in references) (2026-10-03)

Part of v1.4.33, not yet released.

**Opening gate:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `66a1b331cf92f3540e54b29d4cc82bd25c12277f` (AT-1c Step 0), measured at
**2026-10-03 12:58:07 CST** (this session's first command). **Approvals were ON and stayed ON** (finance / cfo / 1,000). Every figure
below is a script's own exit line, or a query named with who ran it: `postgres` (`rolbypassrls = true`) on base tables unless stated;
"as X" means `SET LOCAL ROLE authenticated` plus X's JWT.

Cut 1 of 3 of AT-1c (1c-1 → 1c-2 → 1c-3), built on Tim's answers to `docs/surveys/AUDIT-TRAIL-1c/STEP0-HANDBACK.md` (Q1–Q34, all
accepted as recommended, 2026-10-03). Reference for the mechanism: **`docs/change-log.md` §9** (§9.11 is new; §9.1 and §9.9 extended).

## §1 · Subjects covered

| hand-back subject (Step 0 §a) | covered in 1c-1? |
|---|---|
| `journal_entry` · `invoice` · `credit_note` · `payment` · `payment_request` (with bank transfers and WHT remittances as its results) · `expense` | ✅ (Q1's 1c-1) |
| `payable` (Q5) | ✅ — moved into 1c-1 by this block's brief |
| mechanism: M7 · the operation key (Q16) · employee names in references (Q12) · `ListTrail` takes any subject · the reversal Source links (Q15) · the 1b-3 defect-28 golden (Q34) | ✅ |
| `sale` · `freight` · `fixed_asset` · `bank_statement` · `gst_period` · `fx_rate` · `management_pack` · `contract` | ⬜ AT-1c-2 |
| `finance_lock` · `finance_gst` · `company_profile` · year closes · revaluation / depreciation runs · bulk FX · cash forecasts · payroll payments · processing settlement · WHT / transfer list blocks · claims · import profiles · journal requests | ⬜ AT-1c-3 |
| `approval_policy` (`/settings/approvals`) | ⬜ AT-1d (Q2, recorded in `docs/forward-queue.md`) |

## §2 · What was built

| ruling | built |
|---|---|
| Step 0 §a registry | seven subjects in `trail_subjects()` and 58 member rows in `trail_subject_members()` (counted: rows of the seven subjects in the mirror); every view code `module.finance.view` (the pages' `requireModule(MOD.finance)`) |
| Q5 | `payable`: root `inbound_batches`, root rule `page` (M3 — the batch's own read rule is `module.inbound.view`), `root_columns` = supplier, PO, quantity, unit, unit price, pricing status, arrival date, write-off columns (M6); a written-off batch on `/finance/payables/[batchId]` opens read-only with its banner |
| Q3 (M7) | `hop = 'all'`, `fk_column` NULL: under a single-row root, a whole table belongs (rows found by table and by log); ignored under any other parent; `trail_row_record` homes such a row to the singleton. No live user yet (1c-3's lock panel, AT-1d's approval policy) |
| Q16 | `record_trail` returns `op_key` (`'L' \|\| txid` / `'P' \|\| moment`); `ListTrail` merges rows of one operation across records into one entry and keeps a row read through two records once (`mergeKey`) — replacing the old "identical sentence" de-duplication |
| Q12 | `trail_ref_label` answers an employee reference through `trail_actor` (Restricted without `module.hr.view`, unless it is the reader); it still returns the name as `label` when visible (the summary page's Record column) |
| Q8 | `EndedBanner` gains `voided` and a link line; journals, payments and expenses: "Reversed on DD/MM/YYYY by <name>" + "Reversed by <code>" (who / when from the mirror's creation); invoices: "Voided on DD/MM/YYYY by <name>"; mirrors: "Reversal of <code>" (`ReversalOfBanner`) |
| Q9 | pre-log sources for the seven subjects' tables; `invoices.voided_at`, `payment_requests.paid_at`, `expense_claims.decided_at` registered as event stamps |
| Q13 | `trail_refs` resolves the document ids inside `payment_requests.allocations`; the renderer lists them by number |
| Q31 · Q32 · Q33 | a reversal is one sentence on both documents; a reversal journal is one linked line on the original and its lines are not members; requests raised with approvals off read "… approved" + "Approved automatically (approvals were switched off)" |
| Q15 | `app/finance/sourceLinkReversal.ts` + `resolveSourceHrefs`: a reversal journal's source is the original's source (journal page, journal list, ledger) |
| Q26 | the invoice page's "Earlier requests" list is gone (`InvoiceRequestPanel`); the payment-request decision block is kept (state, per Q26's recommendation) |
| Q27 · Q28 | **75 labels changed on 20 tables, 17 value maps added or corrected, 4 record-type names** — measured by diffing the committed catalogue (`git show HEAD:`) against the regenerated one; every shown column of the seven subjects' 23 tables checked against its page (§9) |
| Q34 | two goldens for 1b-3's defect 28 (§6); the 1b-3 hand-back corrected |

Migration: `db/migrations/2026-10-03-at1c1-trails-ledger-documents.sql` (built from the mirrors by `db/scripts/build_at1c1_migration.py`):
six functions replaced in place (same signatures), `record_trail` dropped and re-created in the same transaction (one more output
column), `NOTIFY pgrst`. No table, policy, grant on a table, trigger or permission code changed; no business row written. Fixture **241**.

## §3 · Pages — every new or changed route, with its file

| route | file(s) | change |
|---|---|---|
| `/finance/journal/[id]` | `app/finance/journal/[id]/page.tsx` | "Audit trail" at the bottom; Q8 banner (reversed: who, when, reason, link) and "Reversal of …" replace the two old banners |
| `/finance/invoices/[id]` | `app/finance/invoices/[id]/page.tsx`, `…/InvoiceRequestPanel.tsx` | "Audit trail" at the bottom; "Voided on … by …" banner (was a red line with date and reason, no who); the panel's "Earlier requests" list removed (Q26) |
| `/finance/credit-notes/[id]` | `app/finance/credit-notes/[id]/page.tsx` | "Audit trail" at the bottom |
| `/finance/payments/[id]` | `app/finance/payments/[id]/page.tsx` | "Audit trail"; Q8 banner on a reversed payment; "Reversal of …" on a mirror (it had none) |
| `/finance/payment-requests/[id]` | `app/finance/payment-requests/[id]/page.tsx` | "Audit trail" at the bottom |
| `/finance/expenses/[id]` | `app/finance/expenses/[id]/page.tsx` | "Audit trail"; Q8 banner; "Reversal of …" (English, shared component) |
| `/finance/payables/[batchId]` | `app/finance/payables/[batchId]/page.tsx` | "Audit trail" (`payable`); a written-off batch: banner + attachments read-only (Q5) |
| `/finance/journal` · `/finance/ledger/[account]` | `app/finance/sourceLinks.ts`, new `app/finance/sourceLinkReversal.ts` | reversal journals' Source links follow the original (Q15) |
| `/logistics/lanes` · `/purchasing/licences` | `app/components/trail/ListTrail.tsx` | one operation across records merges by `op_key` (same result on live today: 20 / 1 entries, surveyed) |
| every page above | `app/components/trail/AuditTrail.tsx` (seven subjects, `recordId`), `AuditTrailList.tsx` (linked values), `EndedBanner.tsx`, `lib/trail/render.ts` (`describeFinance`), `lib/trail/text.ts`, `lib/trail/catalogue.generated.ts` | shared pieces |

## §4 · Verification, in the brief's order

Each line is the script's own exit line from its own log (`/tmp/claude-501/at1c1-*.log`, or the scratchpad for the offline gate).

| # | step | result |
|---|---|---|
| 1 | offline gate `db/gate.py --offline` | **`GATE_OFFLINE_EXIT=0`**: the pre-migration phase is clean, fixture 241 included. It took 11 runs to get there, each red run caused by fixture 241 itself (§10, item 21) |
| 2 | backup `~/evoltrya-backups/backup.sh`, background | **`BACKUP_EXIT=0`** (842 s; `evoltrya-backup-2026-10-03-1510.dump`), finished before step 3 |
| 3 | `db/apply_migration.sh db/migrations/2026-10-03-at1c1-trails-ledger-documents.sql` | **`APPLY_OWN_EXIT=0`**. Applying started at 15:25:31 CST and committed at **15:26:50 CST**, which is where the window starts (`db/migration-windows.tsv`, `66a1b331`). The migration's own proof gave 36 subjects, and tim@ reads 141 records |
| 4 | `npm run types:gen` | **`TYPES_OWN_EXIT=0`** (`record_trail` gains `op_key`) |
| 5 | `npx tsc --noEmit` | **`TSC_OWN_EXIT=0`** (first run, and again at 16:29 after the late renderer fixes) |
| 6 | `npm run build` | first run **`BUILD_OWN_EXIT=0`**; rerun after the late fixes: see §4.1 |
| 7 | full gate `db/gate.py` | **`GATE_EXIT=0`**, three verdicts in 425 s:<br>• rebuildable ✓<br>• mirrors = live ✓<br>• every fixture passes, 241 included ✓<br>• anon surface ✓ (326 relations + 1 function ⊆ baseline of 327)<br>• `changelog` 242 tables / 238 logged / 4 exempt, no gaps<br>• `changemask` 27 / 81, no gaps<br>• `swallow` clean<br>• `definer` 0 without a caller check |
| 8 | i18n check (in the build) | "every key the code references (including enumerable dynamic keys) exists in en and zh"; no new hard-coded Chinese (baseline 18) |
| 9 | error-swallowing check (in the build) | "swallowed query errors: 0 unallowed, 0 queued, 9 allowlisted" |
| 10 | layout survey, desktop (1280) and 390 px: 9 record pages (two journals, voided invoice, credit note, reversed payment and its mirror, expense, written-off and live payable) + `/finance/journal`, `/logistics/lanes`, `/purchasing/licences` | 390 px: **`SURVEY390_EXIT=0`**, U1 pan-free 12/12, U2 clipped tables 0. 1280: **`SURVEY1280_EXIT=0`**, 12/12, 0. Touch targets under 44 px are reported, not judged (12/12 pages have some, as before). Rerun: §4.1 |
| 11 | route smoke `scripts/smoke-routes.mjs`, background | **`SMOKE_EXIT=0`**: 260 ok, 9 skipped (no data), 0 failed. The six trail pages carry trail assertions; `/finance/payment-requests/[id]` is skipped (0 requests on live). **Scratch reading:** the stale-row check reported the same 6 `ZZ-SMOKE-*` rows as before (4 still referenced, so not deleted); its own ephemeral account and grants were removed (the change-log trace in §6.2 shows every insert matched by a delete). Rerun: §4.1 |
| 12 | live verification | §6 |

**Files changed after build and full gate, and what was rerun.** The proof (§6.3) found two renderer defects (§6.3 end). The fixes
touched `lib/trail/render.ts`, `scripts/check-trail-wording.mjs` (two goldens) and `scripts/gen-trail-catalogue.mjs` →
`lib/trail/catalogue.generated.ts` (no label changed; the regenerated tables in §8–§9 are identical). **No file under `db/` changed
after the gate**, and the gate reads no app file, so the gate was not rerun. Everything that reads these files was rerun: §4.1.

### §4.1 · Rerun after the late fixes

One detached chain after the fixes: `/tmp/claude-501/at1c1-rerun.sh`, `RERUN_EXIT=0`, 16:29–17:03 CST. Each line is its own exit line.

| step | result |
|---|---|
| `npx tsc --noEmit` | **`TSC_OWN_EXIT=0`** |
| layout survey 390 px (`.next` removed first) | **`SURVEY390_EXIT=0`**: U1 12/12, U2 0 |
| layout survey 1280 | **`SURVEY1280_EXIT=0`**: U1 12/12, U2 0 |
| `npm run build` (i18n · error-swallowing · wording ①–⑧ · `next build`) | **`BUILD_OWN_EXIT=0`**:<br>• "every key the code references … exists in en and zh"<br>• "swallowed query errors: 0 unallowed, 0 queued, 9 allowlisted"<br>• `check-trail-wording` ①–⑧ ✓ |
| page probe | **`AT1C1_PROBE_EXIT=0`**: 24 passed · 0 failed · 0 skipped |
| route smoke (full) | **`SMOKE_OWN_EXIT=0`**: 260 ok, 9 skipped (no data), 0 failed. Scratch reading: the same 6 stale `ZZ-SMOKE-*` rows as before; the run removed its own ephemeral account |

The gate was not rerun because no `db/` file changed after it (see above).

## §5 · Fault injection

| what | how | result |
|---|---|---|
| fixture 241 | `db/scripts/2026-10-03-at1c1-fixture-injections.py`, against a local rebuild | **`INJECTIONS_OWN_EXIT=0 (20 injections, 0 wrong)`**: clean 241 green, then each injection red in its own arm. Arms covered: M7 ×3 (no expansion; log-only rows; summary-page home walk), Q16 (op_key per record instead of per operation), Q12 (employee names to anyone), Q33 (reversal lines leak), the reversal hop, Q32 (journal request trail), invoice requests, credit-note lines, payment allocations, Q31 ×2 (mirror payment, mirror expense), Q13 (settled documents not resolved), expense attachments, M3 (payable page read rule), M6 (payable sees whole row), payable price history, Q15 (payable reaches the reversal of its journal), Q9 (invoice void stamp) |
| wording check | `TRAIL_WORDING_FAULT=<name> node scripts/check-trail-wording.mjs`, 14 injections | **all 14 red**, each in the arm it names:<br>• blind-detector → ①<br>• raw-ref → ④⑥⑧<br>• raw-json → ④<br>• raw-null → ④⑥⑦<br>• raw-date → ④⑥⑦⑧<br>• raw-role → ④<br>• missing-key / dead-key / label-gap / enum-gap → ③<br>• wording-drift → ⑥<br>• wording-drift-1b3 → ⑦<br>• **wording-drift-1c1 → ⑧ (new)**<br>• registry-drift → ② |
| machine-token sweep over the seven new subjects | part of arm ④ / ⑧ | expected count computed from the catalogue (750 sentences), not remembered. raw-ref / raw-null / raw-date redden ⑧ |
| the two late goldens (§6.3) | each fix reverted by hand, check run, fix restored | both red while reverted, green when restored |
| Q34 (1b-3 defect 28) | the two new goldens, with 1b-3's defect re-introduced | 2 goldens red (recorded in `docs/handbacks/AUDIT-TRAIL-1b-3.md`) |
| page probe `scripts/probe-at1c1.mjs` | `--inject=source-raw · banner-noby · history-back · cjk` | all four red in their own checks, each with its own exit line (`PINJ_<name>_EXIT=1`, `AT1C1_PROBE_EXIT=1`, 17:03–17:15):<br>• source-raw → the 3 Q15 checks<br>• banner-noby → the Q8 reversed-journal check<br>• history-back → the Q26 check<br>• cjk → all 6 fold-in-3 checks<br>The un-injected run is 24/0/0 |

## §6 · Live verification

### §6.1 · Before / after readings

`db/scripts/2026-10-03-at1c1-live-readings.sql`, read as `postgres` (`rolbypassrls = true`), base tables. **Before** at 15:25:03
(before the migration); **after** at 16:26:29 (after the smoke, the probes and the rolled-back proof).

| reading | before | after |
|---|---|---|
| tables · every-row digest | 241 · `c8336b005507` | 241 · `de4e3c76a903` (§6.2) |
| change_log | 2560 rows, max seq 2642 | 2771 rows, max seq 2853 (§6.2) |
| accounts | 7, 0 disabled | 7, 0 disabled |
| approvals | ON | ON |
| pending documents · their digest | 8 · `c113de0d5542` | 8 · `c113de0d5542` |
| POs · journals · invoices · credit notes · payments · payment requests · expenses | 11 · 82 · 9 · 1 · 13 · 0 · 9 (last numbers PO-2026-0011, JE-2027-0003, INV-2026-0009, CN-2026-0001, RCPT-2026-0004, –, EXP-2026-0009) | identical |
| batches | 24, 9 written off | identical |
| 1c-1 rows | 0 journal requests · 0 invoice requests · 4 finance attachments · 7 allocations | identical |

**Reconciliation** (`list_ledger_reconciliation()` as tim@, `db/scripts/2026-10-03-at1c1-live-recon.sql`), read three times
(15:14 before the migration, 16:26 and 16:32 after). All three readings are identical:<br>
• AP: list 416,988.32 · ledger 376,404.42 · **unexplained 0.00** · agrees<br>
• AR: list 57,545.87 · ledger 43,002.12 · **unexplained 0.00** · agrees

### §6.2 · Why the digest and the change log moved

The change-log rows written since the before-reading (`seq > 2642`, 211 rows, read as `postgres`) were grouped by table and operation,
and then by row key.

**Every row key nets to zero except one.** The pairs that net to zero are:
- the smoke's, the survey's and the probes' ephemeral accounts: `user_roles` 11 / 11, `employees` 7 / 7, `performance_reviews` 3 + 3 updates / 3;
- the smoke's role: `roles` 1 / 1, `role_permissions` 72 / 72;
- the smoke's contract seed: `contracts` 2 / 2 and five child tables 1–2 / 1–2.

**The exception** is `cod_verification_failures`: row 142 deleted and row 143 inserted at 16:06:56, by an authenticated user. This is the smoke's
documented COD-verify probe (`scripts/smoke-routes.mjs:979`: the `not_found` branch rotates that table). 1b-3 traced the same
rotation. That row is the only net change on live, and it is what moved the every-row digest.

**The rolled-back proof left nothing behind.** It ran 16:23:47–16:24:16, and no change-log row falls in that span. No
pre-existing document changed: every count, last number and the pending digest are identical.

**Positive evidence that the proof wrote and then rolled back.** The change-log sequence has exactly one gap since the
session started:
- 293 numbers (seq 2854–3146) are missing, between 16:21:10 and 16:29:29.
- The proof is the only writer in that span.
- Sequences are not transactional, so those are the proof's own change-log rows: written, then discarded by its `ROLLBACK`.

**Final reading, 17:15:08**, after the §4.1 rerun and the probe injections (`/tmp/claude-501/at1c1-read-final.log`):
- Everything is identical to the before-reading except the digest (`795ac59ff3da`) and the change log (2986 rows, max seq 3361).
- All 426 change-log rows since the before-reading come from the two smokes, the two surveys, the probes and the probe injections.
- Every row key nets to zero except the two smokes' COD rotations (rows 142 → 143 → 144).
- `cod_verification_failures` holds 1 row, as it did before.

### §6.3 · Proof (`db/scripts/2026-10-03-at1c1-live-proof.sql`, `PROOF_OWN_EXIT=0`)

**A — read-only.** As tim@, `record_trail` for every record of the seven subjects: **138 records**, rendered by the real renderer
(`lib/trail/render.ts`, `buildEntries`) into **213 entries, 0 machine tokens**.
- Pre-log sources: the creation and stamp entries are shown, and nothing appears twice. A pre-log stamp and a logged change never both
  describe one event.
- Q15: the probe opened the 3 reversal journals that have a document source. JE-2026-0002 and JE-2026-0004 link to the original batches; JE-2026-0074
  links to the processing run. Each link points past the original journal and opens (HTTP 200).
- Q5: one written-off payable, IN-2026-0002, was opened. Its banner reads «Written off on 08/09/2026 by Tim», the page is read-only and the trail has entries.

**B — one rolled-back transaction.** It creates and changes each main document type. Who did what:
- chooer@ (finance) submits and pays;
- tim@ (cfo) decides;
- sandra@ (cco) creates the supplier, so that the decider is not the payee: `SOD_PAYEE_AND_PAY`;
- admin@ does the setup.

The records it creates:
- journal JE-2026-0080, requested, approved, then reversal-requested, approved and reversed;
- invoices INV-2026-0010 (voided through a request) and INV-2026-0011 (credited by CN-2026-0002);
- payments PMT-2026-0010 / 0011;
- payment requests PREQ-2026-0001 / 0002;
- expenses EXP-2026-0010 (paid, with an attachment) and EXP-2026-0011 (reversed);
- a batch ZZ-AT1C1-PROOF-IB.

It reads every trail as tim@ through the same JSON the pages read, then ends in `ROLLBACK`. **12 records, 0 machine tokens.**
One thing to read correctly: the whole proof is **one transaction**, so Q16 merges every event of one record into one
entry (one `op_key`). On live, each person's action is its own transaction and gets its own entry.

**Two renderer defects the proof found.** Both are fixed, and each has a golden that goes red when its fix is reverted:
1. A payment request decided by a person was also labelled "Approved automatically". The renderer took the auto-approval
   from "inserted already approved", and a same-operation decision looks like that once Q16 merges the insert with its update.
   Now only a request whose *insert* row is already `approved` reads as automatic, and the title follows the merged end status.
2. Batch prices on the payable trail (`inbound_batches.unit_price`, `price_history.old/new_unit_price`) were labelled in
   the batch's document currency. They are in the base currency (SGD). This also corrects 1b-3's batch trail, which shows the same columns.

### §6.4 · Page probe `scripts/probe-at1c1.mjs` (cfo and admin ephemeral accounts, port 3193)

**`AT1C1_PROBE_EXIT=0`: 24 passed · 0 failed · 0 skipped** (log `at1c1-probe-r2.log`). It covers:
- Q15 ×3 and Q8, on reversed and reversal journals, the voided invoice, and the reversed payment and its mirror;
- Q26: the invoice page has no "Earlier requests";
- Q5: the written-off payable;
- one record per subject: trail entries and no machine token, and fold-in 3 (the zh interface renders the same trail as en).

**Open, not explained.** On the first run, `/finance/journal/9aca7a6c…` failed fold-in 3: zh 667 characters vs en 683. Three later runs passed
with no change to the code in between, so it did not reproduce. The probe prints where the two first differ, but that first
run predates that print. It is recorded here, not in `docs/known-issues.md`, because nothing reproduces it.

## §7 · Broken window

- **Start:** 15:26:50 CST (commit, `apply_migration.sh`).
- **End:** the moment Tim sees the deployment Ready on Vercel. That reading comes from Tim; this machine does not query it.
- **What is broken inside it: nothing found.**
  - The old app ignores `record_trail`'s new `op_key` column.
  - The old app never asks for the seven new subjects.
  - `trail_ref_label`'s new answer for employees (`person`) is the shape the old renderer already reads first (`refVal` → `personVal`).
  - The invoice-line label and `href` are additions.
- The reversal journals' Source links stay wrong until the deploy, as they were before.

## §8 · New event wordings (English; `lib/trail/text.ts`, 79 new keys)

| key | wording |
|---|---|
| `banner.voided` | Voided on {date} by {who} |
| `banner.voidedDate` | Voided on {date} |
| `banner.reversedBy` | Reversed by {code} |
| `banner.reversalOf` | Reversal of {code} |
| `je.posted` | Journal posted |
| `je.reversalPosted` | Reversal journal posted |
| `je.reversed` | Journal reversed |
| `je.reversedOther` | Journal {code} reversed |
| `je.reversedByLine` | Reversed by |
| `je.reversesLine` | Reverses |
| `je.debit` | Debit {amount} |
| `je.credit` | Credit {amount} |
| `jr.sentEntry` | Manual journal sent for approval |
| `jr.sentReversal` | Reversal sent for approval |
| `jr.approvedEntry` | Manual journal approved |
| `jr.approvedReversal` | Reversal approved |
| `jr.rejectedEntry` | Manual journal rejected |
| `jr.rejectedReversal` | Reversal rejected |
| `jr.withdrawnEntry` | Manual journal request withdrawn |
| `jr.withdrawnReversal` | Reversal request withdrawn |
| `ir.sentVoid` | Void sent for approval |
| `ir.sentCredit` | Credit note sent for approval |
| `ir.approvedVoid` | Void approved |
| `ir.approvedCredit` | Credit note approved |
| `ir.rejectedVoid` | Void request rejected |
| `ir.rejectedCredit` | Credit note request rejected |
| `ir.withdrawnVoid` | Void request withdrawn |
| `ir.withdrawnCredit` | Credit note request withdrawn |
| `pr.sent.payment_out` | Payment sent for approval |
| `pr.sent.payment_reversal` | Payment reversal sent for approval |
| `pr.sent.bank_transfer` | Bank transfer sent for approval |
| `pr.sent.bank_transfer_reversal` | Bank transfer reversal sent for approval |
| `pr.sent.wht_remittance` | WHT remittance sent for approval |
| `pr.sent.wht_remittance_reversal` | WHT remittance reversal sent for approval |
| `pr.approved.payment_out` | Payment approved |
| `pr.approved.payment_reversal` | Payment reversal approved |
| `pr.approved.bank_transfer` | Bank transfer approved |
| `pr.approved.bank_transfer_reversal` | Bank transfer reversal approved |
| `pr.approved.wht_remittance` | WHT remittance approved |
| `pr.approved.wht_remittance_reversal` | WHT remittance reversal approved |
| `pr.rejected` | Request rejected |
| `pr.withdrawn` | Request withdrawn |
| `pr.done.payment_out` | Paid |
| `pr.done.payment_reversal` | Payment reversed |
| `pr.done.bank_transfer` | Bank transfer made |
| `pr.done.bank_transfer_reversal` | Bank transfer reversed |
| `pr.done.wht_remittance` | WHT remitted |
| `pr.done.wht_remittance_reversal` | WHT remittance reversed |
| `pr.changed` | Request changed |
| `pr.docCcy` | {amount} (document currency) |
| `inv.issued` | Invoice issued |
| `inv.voided` | Invoice voided |
| `inv.edited` | Invoice changed |
| `inv.lineChanged` | Invoice line changed |
| `inv.pdfIssued` | Invoice PDF issued · version {version} |
| `cnote.issued` | Credit note issued |
| `cnote.pdfIssued` | Credit note PDF issued · version {version} |
| `cnote.changed` | Credit note changed |
| `pay.recordedOut` | Payment recorded |
| `pay.recordedIn` | Receipt recorded |
| `pay.reversedOut` | Payment reversed |
| `pay.reversedIn` | Receipt reversed |
| `pay.reversingLine` | Reversing entry |
| `pay.changed` | Payment changed |
| `pay.allocated` | Allocated |
| `pay.allocatedTo` | Payment allocated |
| `pay.allocationRemoved` | Allocation removed |
| `exp.recorded` | Expense recorded |
| `exp.reversed` | Expense reversed |
| `exp.changed` | Expense changed |
| `exp.claimSubmitted` | Expense claim submitted |
| `exp.claimApproved` | Expense claim approved |
| `exp.claimRejected` | Expense claim rejected |
| `exp.claimWithdrawn` | Expense claim withdrawn |
| `exp.claimChanged` | Expense claim changed |
| `exp.capitalised` | Capitalised into an asset |
| `exp.prepaymentReleased` | Prepayment released against this bill |
| `pab.edited` | Payable details changed |
| `pab.priceSet` | Price set |

Reused, not new: `po.autoApproved` "Approved automatically (approvals were switched off)" (Q32), `value.sinceDeleted`,
`restricted`, the 1b attachment wordings.

## §9 · Field labels and values, all seven subjects (Q27 · Q28)

The tables below were regenerated from `lib/trail/catalogue.generated.ts` after the last change.
- **273 shown fields on 23 tables.** 70 more are hidden as technical, audit stamps, own keys, internal codes or unlinked ids.
- For `payable`, only the batch's 10 root columns are listed.
- Change against HEAD: **75 labels on 20 tables, 17 value maps, 4 record-type names.**

| record type | field (column) | label |
|---|---|---|
| bank transfer | amount_in | Amount in (destination currency) |
| bank transfer | amount_out | Amount out (source currency) |
| bank transfer | bank_reference | Bank reference |
| bank transfer | from_account | From account |
| bank transfer | journal_entry_id | Journal |
| bank transfer | notes | Notes |
| bank transfer | reversal_entry_id | Reversal journal |
| bank transfer | reversed_at | Reversed on |
| bank transfer | reversed_by | Reversed by |
| bank transfer | to_account | To account |
| bank transfer | transfer_date | Transfer date |
| credit note PDF issue | credit_note_id | Credit note |
| credit note PDF issue | issued_at | Issued on |
| credit note PDF issue | issued_by | Issued by |
| credit note line | amount | Amount |
| credit note line | credit_note_id | Credit note |
| credit note line | invoice_line_id | Invoice line |
| credit note line | kind | Credit type |
| credit note line | qty | Quantity |
| credit note line | tax_base | Tax (base currency) |
| credit note line | tax_code | Tax code |
| credit note line | tax_rate_pct | Tax rate % |
| credit note | code | Credit note number |
| credit note | currency | Currency |
| credit note | entry_id | Journal |
| credit note | fx_rate | FX rate |
| credit note | invoice_id | Against invoice |
| credit note | note_date | Credit note date |
| credit note | reason | Reason |
| expense claim | account_code | Account |
| expense claim | amount_ccy | Amount |
| expense claim | code | Expense claim number |
| expense claim | currency | Currency |
| expense claim | decided_at | Decided on |
| expense claim | decided_by | Decided by |
| expense claim | decision_notes | Decision notes |
| expense claim | description | Description |
| expense claim | employee_id | Employee |
| expense claim | expense_id | Expense |
| expense claim | no_receipt_reason | Why there is no receipt |
| expense claim | posting_date | Posting date |
| expense claim | spend_date | Spend date |
| expense claim | status | Status |
| expense claim | submitted_at | Submitted on |
| expense claim | tax_code | Tax code |
| expense claim | withdrawn_at | Withdrawn on |
| expense | account_code | Account |
| expense | amount_base | Amount (base currency) |
| expense | amount_ccy | Amount |
| expense | bank_account_code | Paid from |
| expense | code | Expense number |
| expense | currency | Currency |
| expense | employee_id | Employee |
| expense | expense_date | Expense date |
| expense | fx_rate | FX rate |
| expense | journal_entry_id | Journal |
| expense | notes | Notes |
| expense | payee_name | Payee |
| expense | payment_status | Payment status |
| expense | purchase_order_line_id | Purchase order line |
| expense | reversed_by_expense | Reversed by |
| expense | status | Status |
| expense | supplier_id | Supplier |
| expense | tax_base | Tax (base currency) |
| expense | tax_ccy | Tax |
| expense | tax_code | Tax code |
| expense | tax_rate_pct | Tax rate % |
| expense | wht_amount_ccy | WHT amount |
| expense | wht_nature | Nature of payment |
| expense | wht_payee_residence | WHT payee residence |
| expense | wht_rate_pct | WHT rate % |
| expense | wht_treaty_ref | Certificate of residence |
| finance attachment | claim_id | Claim |
| finance attachment | deleted_at | Deleted on |
| finance attachment | doc_type | Document type |
| finance attachment | expense_id | Expense |
| finance attachment | file_name | File name |
| finance attachment | inbound_batch_id | Inbound batch |
| finance attachment | notes | Notes |
| finance attachment | payment_id | Payment |
| finance attachment | sales_record_id | Sales record |
| asset cost entry | amount_base | Amount (base currency) |
| asset cost entry | amount_ccy | Amount |
| asset cost entry | asset_id | Asset |
| asset cost entry | currency | Currency |
| asset cost entry | expense_id | From expense |
| asset cost entry | fx_rate | FX rate |
| freight allocation | amount_base | Amount |
| freight allocation | basis_qty | Allocation basis (quantity) |
| freight allocation | freight_document_id | Freight document |
| freight allocation | in_stock_ratio | Share still in stock |
| freight allocation | inbound_batch_id | Inbound batch |
| inbound batch | arrival_date | Arrival date |
| inbound batch | delete_reason | Reason written off |
| inbound batch | deleted_at | Written off on |
| inbound batch | deleted_by | Written off by |
| inbound batch | pricing_status | Pricing |
| inbound batch | purchase_order_id | Purchase order |
| inbound batch | quantity | Quantity |
| inbound batch | supplier_id | Supplier |
| inbound batch | unit | Unit |
| inbound batch | unit_price | Unit price |
| invoice PDF issue | invoice_id | Invoice |
| invoice PDF issue | issued_at | Issued on |
| invoice PDF issue | issued_by | Issued by |
| invoice line | amount_base | Amount (base currency) |
| invoice line | amount_ccy | Amount |
| invoice line | description | Description |
| invoice line | invoice_id | Invoice |
| invoice line | invoice_voided | Invoice voided |
| invoice line | line_no | Line |
| invoice line | quantity | Quantity |
| invoice line | sales_order_line_id | Sales order line |
| invoice line | sales_record_id | Sale |
| invoice line | tax_base | Tax (base currency) |
| invoice line | tax_code | Tax code |
| invoice line | tax_rate_pct | Tax rate % |
| invoice line | unit | Unit |
| invoice line | unit_price | Unit price |
| invoice request | amount_base | Amount (base currency) |
| invoice request | decided_at | Decided on |
| invoice request | decided_by | Decided by |
| invoice request | decision_notes | Decision notes |
| invoice request | doc_date | Document date |
| invoice request | invoice_id | Invoice |
| invoice request | kind | Request type |
| invoice request | label | Request |
| invoice request | lines | Lines |
| invoice request | reason | Reason |
| invoice request | result_credit_note_id | Credit note issued |
| invoice request | result_journal_entry_id | Posted as |
| invoice request | status | Status |
| invoice request | withdraw_reason | Withdrawal reason |
| invoice request | withdrawn_at | Withdrawn on |
| invoice request | withdrawn_by | Withdrawn by |
| invoice | bill_to_snapshot | Bill-to details |
| invoice | code | Invoice number |
| invoice | currency | Currency |
| invoice | customer_id | Customer |
| invoice | due_date | Due date |
| invoice | entry_id | Journal |
| invoice | fx_rate | FX rate |
| invoice | issue_date | Issue date |
| invoice | kind | Invoice type |
| invoice | notes | Notes |
| invoice | payment_terms_days | Payment terms (days) |
| invoice | sales_order_id | Sales order |
| invoice | status | Status |
| invoice | subtotal_base | Subtotal (base currency) |
| invoice | tax_base | Tax (base currency) |
| invoice | tax_rate_pct | Tax rate % |
| invoice | terms_text | Terms |
| invoice | total_base | Total (base currency) |
| invoice | void_reason | Void reason |
| invoice | voided_at | Voided on |
| invoice | voided_by | Voided by |
| journal entry | code | Journal number |
| journal entry | entry_date | Entry date |
| journal entry | memo | Memo |
| journal entry | reversed_by | Reversed by |
| journal entry | source_type | Source |
| journal entry | status | Status |
| journal line | account_id | Account |
| journal line | amount_ccy | Amount (original currency) |
| journal line | credit | Credit |
| journal line | currency | Currency |
| journal line | debit | Debit |
| journal line | entry_id | Journal |
| journal line | fx_rate | FX rate |
| journal line | fx_rate_date | FX rate date |
| journal line | line_memo | Line memo |
| journal line | tax_code | Tax code |
| journal request | amount_base | Amount (sum of debits) |
| journal request | credits_bank | Pays out of a bank account |
| journal request | decided_at | Decided on |
| journal request | decided_by | Decided by |
| journal request | decision_notes | Decision notes |
| journal request | entry_date | Entry date |
| journal request | kind | Request type |
| journal request | label | Request |
| journal request | lines | Journal lines |
| journal request | memo | Memo |
| journal request | result_journal_entry_id | Posted as |
| journal request | status | Status |
| journal request | target_entry_id | Journal to reverse |
| journal request | withdraw_reason | Withdrawal reason |
| journal request | withdrawn_at | Withdrawn on |
| journal request | withdrawn_by | Withdrawn by |
| payment allocation | allocated_base | Allocated (base currency) |
| payment allocation | allocated_ccy | Allocated (document currency) |
| payment allocation | allocated_pay | Allocated (payment currency) |
| payment allocation | expense_id | Expense |
| payment allocation | freight_document_id | Freight document |
| payment allocation | inbound_batch_id | Inbound batch |
| payment allocation | invoice_id | Invoice |
| payment allocation | payment_id | Payment |
| payment allocation | purchase_order_id | Purchase order |
| payment allocation | sales_record_id | Sale |
| payment allocation | withheld_base | Withheld (base currency) |
| payment allocation | withheld_pay | Withheld (payment currency) |
| payment request | allocations | Documents to settle |
| payment request | amount_base | Amount (base currency) |
| payment request | amount_ccy | Amount |
| payment request | amount_in | Amount in (destination currency) |
| payment request | bank_account_code | Bank account |
| payment request | bank_reference | Bank reference |
| payment request | code | Payment request number |
| payment request | counterparty_type | Counterparty type |
| payment request | currency | Currency |
| payment request | customer_id | Customer |
| payment request | decided_at | Decided on |
| payment request | decided_by | Decided by |
| payment request | decision_notes | Decision note |
| payment request | employee_id | Employee |
| payment request | filed_reference | IRAS filing reference |
| payment request | fx_rate | FX rate |
| payment request | kind | Type |
| payment request | notes | Notes |
| payment request | paid_at | Paid on |
| payment request | paid_by | Paid by |
| payment request | payment_id | Payment to reverse |
| payment request | period_month | Withholding month |
| payment request | planned_date | Planned payment date |
| payment request | result_journal_entry_id | Posted as |
| payment request | result_payment_id | Payment made |
| payment request | result_transfer_id | Transfer made |
| payment request | status | Status |
| payment request | supplier_id | Supplier |
| payment request | to_account_code | To account |
| payment request | transfer_id | Transfer to reverse |
| payment request | wht_remittance_id | Remittance to reverse |
| payment request | withdrawn_at | Withdrawn on |
| payment request | withdrawn_by | Withdrawn by |
| payment | amount_base | Amount (base currency) |
| payment | amount_ccy | Amount |
| payment | bank_account_code | Bank account |
| payment | code | Payment number |
| payment | counterparty_type | Counterparty type |
| payment | currency | Currency |
| payment | customer_id | Customer |
| payment | direction | Direction |
| payment | employee_id | Employee |
| payment | fx_rate | FX rate |
| payment | journal_entry_id | Journal |
| payment | notes | Notes |
| payment | payment_date | Payment date |
| payment | reversed_by_payment | Reversed by |
| payment | status | Status |
| payment | supplier_id | Supplier |
| prepayment release | amount_base | Amount (base currency) |
| prepayment release | amount_ccy | Amount |
| prepayment release | currency | Currency |
| prepayment release | expense_id | Expense |
| prepayment release | inbound_batch_id | Inbound batch |
| prepayment release | journal_entry_id | Journal |
| prepayment release | notes | Notes |
| prepayment release | purchase_order_id | Purchase order |
| batch price change | currency | Currency |
| batch price change | fx_rate | FX rate |
| batch price change | inbound_batch_id | Inbound batch |
| batch price change | new_unit_price | New unit price |
| batch price change | notes | Notes |
| batch price change | old_unit_price | Previous unit price |
| batch price change | original_price | Original price |
| batch price change | rate_as_of | Rate as of |
| batch price change | rate_type | Rate type |
| WHT remittance | amount_base | Amount |
| WHT remittance | code | WHT remittance number |
| WHT remittance | filed_reference | IRAS filing reference |
| WHT remittance | journal_entry_id | Journal |
| WHT remittance | notes | Notes |
| WHT remittance | period_month | Withholding month |
| WHT remittance | remitted_on | Paid on |

**Values**

| field | values |
|---|---|
| bank_transfers · from_account | 1000 → Cash at Bank – SGD; 1010 → Cash at Bank – USD |
| bank_transfers · to_account | 1000 → Cash at Bank – SGD; 1010 → Cash at Bank – USD |
| credit_note_lines · kind | unshipped_cancel → Not delivered — cancelled; revenue_reduction → Price / quality adjustment |
| expense_claims · status | submitted → Waiting for approval; withdrawn → Withdrawn; approved → Approved; rejected → Rejected |
| expenses · bank_account_code | 1000 → Cash at Bank – SGD; 1010 → Cash at Bank – USD |
| expenses · payment_status | paid → Paid; unpaid → Unpaid |
| expenses · status | posted → Posted; reversed → Reversed |
| expenses · wht_payee_residence | resident → Singapore tax resident; non_resident → Non-resident |
| finance_attachments · doc_type | invoice → Invoice; contract → Contract; receipt → Receipt; bank_slip → Bank slip; weighbridge → Weighbridge ticket; other → Other |
| inbound_batches · pricing_status | unpriced → Unpriced; provisional → Provisional; final → Final |
| inbound_batches · unit | kg → kg; t → t; unit → units; units → units; pcs → pieces; l → litres |
| invoice_lines · unit | kg → kg; t → t; unit → units; units → units; pcs → pieces; l → litres |
| invoice_requests · kind | credit_note → Credit note; void → Void |
| invoice_requests · status | submitted → Waiting for the CFO; approved → Approved and posted; rejected → Rejected; withdrawn → Withdrawn |
| invoices · kind | sale → From a sale; order → From a sales order |
| invoices · status | issued → Issued; void → Void |
| journal_entries · source_type | manual → Manual; purchase → Purchase; sale → Sale; processing_cost → Processing cost; allocation → Allocation; stocktake → Stocktake; writeoff → Write-off; payment → Payment; fx → FX; expense → Expense; prepayment → Prepayment; payroll → Payroll; transfer → Transfer; revaluation → FX revaluation; depreciation → Depreciation; asset_disposal → Asset disposal; year_close → Year-end close; freight → Freight; invoice → Order invoice posting; shipment → Shipment (revenue); credit_note → Credit note; wht_remittance → Withholding tax remitted to IRAS |
| journal_entries · status | posted → Posted; reversed → Reversed |
| journal_requests · kind | entry → Manual journal; reversal → Reversal |
| journal_requests · status | submitted → Waiting for approval; approved → Approved and posted; rejected → Rejected; withdrawn → Withdrawn |
| payment_requests · bank_account_code | 1000 → Cash at Bank – SGD; 1010 → Cash at Bank – USD |
| payment_requests · counterparty_type | customer → Customer; supplier → Supplier; employee → Employee |
| payment_requests · kind | payment_out → Payment; payment_reversal → Payment reversal; bank_transfer → Bank transfer; bank_transfer_reversal → Bank transfer reversal; wht_remittance → Withholding tax remittance; wht_remittance_reversal → Withholding tax remittance reversal |
| payment_requests · status | submitted → Awaiting approval; withdrawn → Withdrawn; approved → Approved — ready to pay; rejected → Rejected; paid → Paid |
| payment_requests · to_account_code | 1000 → Cash at Bank – SGD; 1010 → Cash at Bank – USD |
| payments · bank_account_code | 1000 → Cash at Bank – SGD; 1010 → Cash at Bank – USD |
| payments · counterparty_type | customer → Customer; supplier → Supplier; employee → Employee |
| payments · direction | in → Receipt; out → Payment |
| payments · status | posted → Posted; reversed → Reversed |
| price_history · rate_type | tt_buy → TT buying rate; tt_sell → TT selling rate; mid → Mid rate |

## §10 · Decisions taken without asking

1. **`payable` root columns** (Q5/M6): supplier, PO, quantity, unit, unit price, pricing status, arrival date, and the three write-off
   columns. These are the batch's commercial facts. Assay, location and processing columns stay with the 1b batch trail.
2. **Home records for the summary page.**
   - A journal line, allocation, invoice line or credit-note line homes to its document.
   - A payment request's result homes to the request.
   - Price history and freight allocations home to the payable.
3. **Auto-approval is inferred, not stored.** No column says "approved automatically". The rule: a request whose insert row is already `approved`
   was raised with approvals off (Q32). The fix in §6.3 narrowed this.
4. **Label parts.** A request's trail entry is titled with its kind and the document it concerns, e.g.
   "Reversal approved · JE-2026-0080 · reversal #1". The number after `#` counts that document's requests of that kind.
5. **Reversal reasons.** The reason shown on a reversal is the reversal's own `reason`, with the system's "Reversal of …" prefix
   stripped from memos. A memo is shown only for manual-journal requests, so it is not repeated.
6. **Allocation amounts** show in the document's currency, with "(document currency)" (Q13). Journal lines show the base amount,
   with the original currency in brackets when it differs.
7. **Banners.**
   - "Reversed on … by …": who and when come from the mirror's creation (the reversal is the event). The reason comes from the mirror's notes or memo.
   - The voided-invoice banner takes `voided_by`.
   - A record with no person shows only the date, never a guessed name.
8. **`ListTrail` merges by `op_key`**, replacing 1b's "identical sentence" de-duplication. On live today this gives the same result:
   20 / 1 entries on `/logistics/lanes` and `/purchasing/licences`.
9. **`href` is generic.** Any `document_types` row with `link_mode = 'detail'` gets a link. It is not a list for the trail, so a new
   document type links with no trail change.
10. **Q15 is fixed for every caller** of `resolveSourceHrefs` (journal page, journal list, ledger), not only the journal page.
11. **`record_trail` is dropped and re-created** in the same transaction. PostgreSQL cannot add an output column with `CREATE OR REPLACE`.
    Its grants are replayed in the migration.
12. **Fixture 241 tests M7 with a temporary subject.** Live has no singleton subject yet, so the fixture renames the registry
    functions to `*_f241` and wraps them. Everything rolls back.
13. **1b-shown table labels hand-checked under Q27.** Tables the seven subjects share with 1b (attachments, batches, price history)
    were re-read against their pages. The base-currency fix in §6.3 also changes the 1b batch trail.
14. **Bank account codes 1000 / 1010 read "Cash at Bank – SGD / USD"**, the chart-of-accounts names.
15. **Claims and asset cost entries are members of `expense`.** Members: expense claims (approval of the same spend) and asset cost entries (capitalisation).
    Prepayment applications are members of the bill they release against.
16. **Credit-note text keys are `cnote.*`**, not `cn.*`. `check-i18n` reads `cn.` as an existing message prefix and refused.
17. **`/finance/payment-requests/[id]` is skipped in the smoke.** Live has 0 payment requests, so there is no row to open. The proof (§6.3) covers its trail.
18. **"Each subject's field edit" is covered in three different ways:**
    - **Journals and expenses:** fixture 241 attempts an edit and asserts it is refused (immutability).
    - **Invoices, credit notes and payments:** no edit path exists after issue, so the key events (void, credit, reversal) stand in.
    - **Payable:** a real field edit (unit price) is asserted.

    **Not covered: field edits on payment requests and credit notes.** The renderer has "Request changed" / "Credit note changed" /
    "Payment changed" / "Invoice changed" wordings for direct changes, but none of them has a golden. They are covered only by
    the machine-token sweep (arm ④ runs every column with sample values). This is a gap, recorded for 1c-2.
19. **The proof's setup choices**:
    - chooer@ submits because admin@ and tim@ are the same person (`JOURNAL_REQUEST_NO_OTHER_DECIDER`);
    - tax codes ZR / OP (live is GST-registered);
    - sandra@ creates the supplier (`SOD_PAYEE_AND_PAY`).
20. **The probe's one unexplained mismatch** (§6.4) is reported as open, not as a known issue.
21. **Fixture 241 needed 11 offline-gate runs.** Each red run was the fixture's own setup meeting a real rule
    (`CLOSE_IMMUTABLE`, `RECEIPT_AGAINST_NON_GOODS_VENDOR`, `CN_EXCEEDS_RELEASED`, `PAYMENT_REVERSAL_TAKES_NO_DATE`, `REVERSAL_BEFORE_ORIGINAL`,
    a check constraint on payment requests). No function changed for it. Where a Step 0 assumption was wrong (journal requests
    are inserted as submitted and then updated; one transaction has one txid), the assertion was rewritten to say what is true.

## §11 · Known issues and queue

- Added to `docs/known-issues.md`:
  - `AT1C1-PAYROLL-JOURNAL-SHOWS-INDIVIDUAL-PAY` (Q11; first item of UNBLOCK-1);
  - `AT1C1-UNRECONCILE-WRITES-TIMESTAMP-INTO-NOTES` (Q24);
  - `AT1C1-REQUEST-TARGETS-NOT-REACHABLE` (Q13's other half).
- `docs/forward-queue.md`: AT-1c split, 1c-1 ✅, 1c-2 and 1c-3 entries, AT-1d approval-policy panel (Q2), UNBLOCK-1 Q11 first.
- `docs/handbacks/AUDIT-TRAIL-1b-3.md`: Q34 correction.
