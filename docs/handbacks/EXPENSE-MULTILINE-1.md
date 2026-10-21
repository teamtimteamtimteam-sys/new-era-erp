v1.4.64 — Multi-line expenses and itemised claims: an expense is a header plus lines, each line with its own account and tax code, posting as one journal entry and owed as one payable; a capital purchase stays a single line; an expense claim is a purpose plus items, and approving it gives finance an account and tax code per item and creates one expense with one line per item; the expense form's line grid restores from a draft whole or not at all; the expense list shows "N accounts" and filters by any line's account.

# EXPENSE-MULTILINE-1 — hand-back (2026-10-20) · expenses become header + lines, expense claims become header + items

The brief "EXPENSE-MULTILINE-1" with Tim's rulings on Step 0 (Q1–Q16) and Step 0b (Q1–Q10), both 2026-10-20. Part 1 closed FIN-CHAIN-1
(`docs/handbacks/FIN-CHAIN-1.md` §5). Started from `2157a340f09e6e58e42a8b2777de4c9d09c71830` (HEAD = origin/main = ls-remote, tree clean).
Survey: `docs/surveys/EXPENSE-MULTILINE-1/step0-survey.md`. Readings: `docs/surveys/EXPENSE-MULTILINE-1/readings/`.

## 1 · What changed

| Item | What | Proof |
|---|---|---|
| Expense = header + lines | New `expense_lines` (account · tax code · rate · net · tax · base amounts · notes), insert-only. `expenses` loses `account_code` / `tax_code` / `tax_rate_pct`; its four totals stay and are forced equal to the sum of its lines, at least one line (`guard_expense_totals`, deferred constraint triggers on both tables). | fixture 285 A · F; migration self-proof; dry run |
| One writer | `record_expense_document(header…, p_lines)` — per-line account checks, per-line GST (claimable → 1400, blocked → the line's own account), rounded per line (Q16); one journal entry with per-line legs (each line balances in base); one payable. `record_expense` keeps its exact signature as a one-line wrapper (Q11) — its 140 fixture calls and the asset / maintenance / claim / medical callers unchanged. | fixture 285 A · B · H |
| Capital = one line (Q1) | 1500, `p_asset`, a PO line or a maintenance id on a multi-line document → `EXPENSE_CAPITAL_SOLE_LINE`. Asset / PO-line / maintenance links unchanged. Per-line capitalisation parked in the queue. | fixture 285 C; live proof T2 |
| WHT (Q2, Q12) | One nature and rate per document, on the sum of line nets; any taxed line on a withholding document → `EXPENSE_WHT_WITH_GST`. | fixture 285 E |
| Reversal (Q4) | Whole document; the mirror carries the original's lines (net, no tax code), header = its lines. | fixture 285 G |
| System writers | `post_electricity_allocation` and `relieve_processing_accruals` write their one line. `relieve_processing_accruals`' `paid` default registered, not fixed (Q14, `known-issues` § RELIEVE-PAID-AT-CREATION). | full gate (fixtures that drive them) |
| Expense form | Line grid (account · tax code · net · notes, add / remove, no limit — Q7); capital locks the grid to one line; whole grid travels in one hidden `lines_json`; `useFormDraft` gained an optional `onRestore` and the form uses it to rebuild the grid and its controlled header — restore is whole or nothing, with a banner when nothing could be restored (Q8; this form only). | build; layout survey; ⚠ restore not walked in a browser (see §4) |
| Expense list / detail (Q9) | One row per document; account column shows the account or "N accounts"; account filter = any line on that account; with the filter on, the total adds only those lines. Detail page gains a lines table. GST page counts coded lines. | live proof H2 · H3; layout survey |
| Claim = header + items (Step 0b) | New `expense_claim_items` (date · receipt amount · description · no-receipt reason · account and tax code set at approval, once). `expense_claims` loses `account_code` / `tax_code` / `no_receipt_reason`; its amount = sum of items, its date = the latest item (`guard_expense_claim_totals`). `submit_expense_claim_items` (one currency, Q4; one calendar month, foreign currency one date — Q5, both refused by name; required purpose — Q7); `decide_expense_claim_items` (account and tax code per item, nothing pre-selected — Q1; evidence per item; rejection whole-claim — Q3; one expense, one line per item). Old `submit_expense_claim` / `decide_expense_claim` are one-item wrappers; a multi-item claim through the old decide → `EXPENSE_CLAIM_HAS_ITEMS` (Q8). Approval roster now names `decide_expense_claim_items` (the function that enforces the level). Search reads the purpose only (`document_types`, Q7). Medical claims untouched (Q6). | fixture 286; live proof T3–T5 |
| Claim screens | `/me`: purpose + currency + item grid (no draft — Q10). `/finance/claims`: each item with its facts, evidence and its own account / tax selects. | layout survey (first render); live proof H4 |
| Trail | `expense_lines` and `expense_claim_items` are members of the expense / claim subjects; header lines no longer print the account. | `check-trail-wording` (golden case updated, new line case) |
| Converted data (Q5, Step 0b Q9) | The 10 live expenses → one line each, the 4 live claims → one item each, copied verbatim; journals, payments, assets, prepayments and attachments untouched. Listed in `known-wrong-until-cutover.md`. | migration self-proof ②; dry run |
| Queue / registry | CLAIM-RECEIPTS-1 (62b, next cut), TABLE-EXPORT, per-line capitalisation (parked); `known-issues` EXPENSE-CLAIM-NO-RECEIPT-UPLOAD and RELIEVE-PAID-AT-CREATION; `known-wrong` :226 corrected (it pointed at a receipt upload that does not exist); rulings recorded in `forward-queue.md` item 62 and `accounting-policies.md` (4.3 note, 7.4 note). | `git diff docs/` |

## 2 · Verify chain (every exit read from the script's own line)

| # | Step | Result |
|---|---|---|
| 1 | offline gate | `GATE_EXIT=0` (125 s). Three runs: the first red on 19 existing fixtures (moved columns; 77's injection now targets the writer; 203E roster) plus one B2 finding of mine — the `submit_expense_claim` wrapper was owner-rights with no caller check of its own; it is now an invoker function. Second red on 3 (140J, 203E — my own comment in `approval_chain_gates` contained the literal the catalogue counts; 205R4b). Third green. |
| 1b | fixture fault injections | 4/4 bite (`readings/fixture-injections.txt`) |
| 2 | backup | `BACKUP_EXIT=0` — `evoltrya-backup-2026-10-20-2201.dump` (TOC 9,782, previous 9,779) + 17 change_log chunks, 74,039 rows = count; 22:01:50 → 22:32 CST |
| 3 | live dry run COMMIT→ROLLBACK | `DRY_OWN_EXIT=0` — inside: 327 tables, 10 lines, 4 items, the three writers, authenticated executes / anon does not, header columns 0 left, deferred totals guards forced immediate and passed; after rollback: 325 tables, no `expense_lines`, header columns back |
| 4 | apply | `APPLY_OWN_EXIT=0`; pre-flight 19 functions (11 replaced · 8 new), 9 account codes all system; **broken window start 2026-10-20 22:54:25 CST** (`db/migration-windows.tsv`) |
| 5 | types | `TYPES_OWN_EXIT=0` (after a 20 s wait for the PostgREST cache — columns were dropped) |
| 6 | tsc | `TSC_OWN_EXIT=0` |
| 7 | build | `BUILD_OWN_EXIT=0` |
| 8 | full gate | `GATE_EXIT=0` (931 s), first run: rebuild · mirrors vs live (incl. generated types) · all fixtures · anon (327) · no-role (126) · portal (42) |
| 9 | i18n | `I18N_OWN_EXIT=0` |
| 10 | error-swallowing | `SWALLOW_OWN_EXIT=0` |
| 11 | layout survey, 5 touched pages | 390 px: 5/5 pan-free, 0 clipped; 1280 px: 5/5, 0 overflow, 0 clipped (`/finance/expenses/new`, `/finance/expenses`, an expense detail, `/finance/claims`, `/me`) |
| 12 | smoke | `SMOKE_EXIT=0` — 304 ok · 25 skipped (no data) · 0 failed; the stale `ZZ-SMOKE` rows reported as before (not mine, not touched) |
| 13 | live proof | `EM1_PROOF_EXIT=0` (first run; `PROOF_BASE` = `next start` on this commit, against live): H1–H4 over HTTP as finance / cfo copies; T1–T6 inside one rolled-back transaction (two-line expense EXP-2026-0011 and three-item claim CLM-2026-0005 existed only inside it). Read back as postgres afterwards: approvals ON (finance / cfo / 1,000); 7 real accounts, 0 disabled, roles admin · finance · warehouse · cto · cco · cfo · gm unchanged; throwaway users 0 · roles 0 · orphan grants 0 (the level-1 throwaway held the real `finance` role during the proof — removed by its plan; `finance` holders back to 1); 2 COD rows; `require_calibrated_since` NULL; list-vs-ledger ap 0.00 · ar 0.00 (read as tim@); `expense_lines` 10 · `expense_claim_items` 4 |
| 14 | fresh clone, no `.env.local`: `npm ci && npm run build` | recorded in the close report (it builds the commit that contains this file) |

**Broken window — what is broken in it (derived):** the old app's expense list and expense detail select `expenses.account_code` (dropped) → those two
pages error; `/finance/claims` and the claims block on `/me` read `expense_claim_status.no_receipt_reason / account_code / tax_code` (dropped) → error;
the GST page's coded-expense count reads `expenses.tax_code` → error. Recording still works through the old pages: the expense form calls
`record_expense`, `/me` calls `submit_expense_claim`, the decision panel calls `decide_expense_claim` — all wrappers with unchanged signatures.
The end of the window is Tim's reading on Vercel.

## 3 · Corrections to my own Step 0 / 0b reports

- The Step 0 estimate assumed 2 full-gate runs; one was needed (931 s, not 787 s). The offline gate ran 3 times (estimate 4).
- Step 0's survey listed asset / cost-entry / anchor line references and a reversal loop; Tim's Q1 made capital one-line, so none of those were built.

## 4 · Registered, not fixed / not measured

- **Draft restore of the expense grid was not walked in a browser** — this machine has no Chrome for an interactive walk; the evidence is the code path
  (`onRestore` returns false → nothing written), `tsc` and the build. Stated, not counted as a measurement.
- The layout survey measures **first render**: the expense form with one line, `/me` without the claim form open (it opens on a click and needs an
  employee profile). Multi-line / multi-item layouts at 390 px are not measured.
- `relieve_processing_accruals` / `post_electricity_allocation` can still write a `paid` expense (Q14, registered).
- Receipts cannot be uploaded to claims until CLAIM-RECEIPTS-1 (registered; next cut).

## 5 · Close-out (CLAIM-RECEIPTS-1 Part 1, 2026-10-21)

- **Pushed commit:** `7636a66ca0c1079fcc8741b74962b10b409dcb68` (`v1.4.64`); HEAD = origin/main = `git ls-remote origin main`, tree clean, re-read at the start of CLAIM-RECEIPTS-1.
- **Broken window: opened 2026-10-20 22:54:25 CST** (migration committed; printed by `apply_migration.sh`, `db/migration-windows.tsv`) — **closed 2026-10-21 00:58 CST**
  (Tim confirmed the deployment on Vercel; **this end point is Tim's report, not a reading this machine took**). **Length ≈ 2 h 04 min** (22:54:25 → 00:58; Tim's end point is to the minute, so the seconds are not known).
  **Why it was this long:** auto mode refused the `git push` from this session, so the cut stopped with the commit made and printed the push line; Tim ran it himself. The wait for that hand-off is inside the window.
  **Broken in it:** as derived in §2 — the expense list, the expense detail, `/finance/claims`, the claims block on `/me` and the GST page's coded-expense count errored; recording through the three wrapper functions kept working.
- **Read-only check on production (2026-10-21 10:16 CST, after Tim's confirmation)** — `docs/surveys/CLAIM-RECEIPTS-1/readings/closeout-production-check.txt`, `CLOSEOUT_CHECK_EXIT=0`,
  script `db/scripts/2026-10-21-expense-multiline-1-closeout-check.mjs`: a finance-clone throwaway (`em1probe`, shared helper) opened on `https://new-era-erp.vercel.app`
  `/finance/expenses` (HTTP 200, table rendered, EXP-2026-0007 in it), the EXP-2026-0007 detail page (HTTP 200, lines table, its line on 6120) and `/finance/claims`
  (HTTP 200, table rendered, CLM-2026-0004 drawn item by item). GET only. Read back as `postgres` afterwards: `em1probe` accounts 0 · throwaway roles 0 · grants without a user 0.
- **Not measured, handed to Tim's own browser** (`docs/manual-walk-list.md` §33): the draft restore of a multi-line expense, and the expense form with three or four lines at 390 px.
- **EXPENSE-MULTILINE-1 is closed** (`docs/forward-queue.md` item 62).
