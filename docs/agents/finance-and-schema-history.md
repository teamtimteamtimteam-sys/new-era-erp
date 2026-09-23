# Finance and schema history — text moved verbatim out of AGENTS.md by AGENTS-TRIM-1 (2026-09-23); each ↩ heading names the section it came from.

## ↩ F01 · from AGENTS.md § Adding a column to a masked table: extend the grant, or it is invisible (old lines 986–998)

The documentation above was already there and already clear; what was missing was
a check that fires at the right *time*. **That pre-flight scan now exists (CHECK-1,
2026-08-31) — the QUEUED note that stood here is retired.**

`db/preflight_migration.py` prints a **`masked`** line and **refuses (exit 2)** when
a migration `ADD COLUMN`s onto a table that has a `_masked` companion on live without
putting the column into that view in the same migration. Historical replay, run before
trusting it: the two defective main-cut migrations
(`procwire1bi`, `proc1biii`) are refused and all three columns named, while both `fu1`
migrations pass. Sweeping all 33 migrations dated 2026-08-30/31 refuses **three** and
passes the other 30 — and the third is a **fourth occurrence nobody had counted**:
`cmpl1` added four columns to `inbound_batches` and `cmpl1-fu2` cleaned up after it.
So the tally in this section is **four in three days, not three**.

## ↩ F02 · from AGENTS.md § `colgrant` asked half the question — `colreader` asks the other half (OPS-13) (old lines 1059–1062)

`processing_cost_variance` was exactly this, and had never worked since the day it
shipped: the page returned a clean HTTP 200 with an empty table, because the
page's `?? []` swallowed the error and the route smoke test asserts 2xx. Three
checks looked straight at it and saw nothing.

## ↩ F03 · from AGENTS.md § `colreader` asked about COLUMNS — `xmodule` asks about ROWS (OPS-14) (old lines 1119–1139)

The survey found **11 of 15** invoker views spanning modules, and **five were
already wrong on live** (all probed, all rolled back):

* `processing_run_allocation_status` — `safe_to_reallocate` was `true` as postgres
  and **`NULL` as `operations`**; the run page branches on that boolean and `NULL`
  is falsy, so a run that was perfectly safe wore the **red** "cannot re-allocate"
  banner. And `price_history` is `module.inbound.view` — it is one of three
  staleness sources, so `is_stale` **under-reported**: a stale run read as fresh.
* `purchase_order_status` — PO prepayment read **35,000.00** as `admin` and
  **0.00** as `procurement`.
* `ap_open_items` — a payable 30,000 settled read as **0 settled / fully open** to
  `procurement`.
* `hr_alerts` — `system_start_not_set` is written `NOT EXISTS (SELECT 1 FROM
  finance_settings …)`. The row vanishes for a non-finance reader, so the condition
  is **vacuously true**: the date *was* set, and the `hr` role saw a permanent false
  alarm **it could never clear**, because the table driving it was unreadable.
  Note the direction — a vanishing row produced a **false positive** here and a
  false negative above. Same disease, both ways.
* `batch_assay_status` — `INNER JOIN suppliers`: **10 rows as `admin`, 0 as
  `warehouse`**, who can see all 10 batches. The inbound list uses it for the
  "unapplied assay" badge, so those roles were never told.

## ↩ F04 · from AGENTS.md § 拒绝要用哪个值表示 —— 判据是【NULL 有没有主】,不是返回类型(CLEANUP-A,2026-08-31) (old lines 1166–1176)

实测出来的三个「NULL 已经有主」:

| 对象 | 它的 `NULL` 本来是什么意思 | 谁在读那个意思 |
|---|---|---|
| `inbound_batch_landed_unit_cost` | 「这批货真的没有金额」 | `inbound_batch_valuation.unpriced` **就定义为**它 `IS NULL` |
| `resolve_review_reviewer` | 「解析不出评估人」 | `hr_alerts` 的 `review_no_reviewer` 一支专门等它 |
| `previewLeaveDays`(前端) | 「两头日期还没填全」 | `LeaveForm` 把它印成 `—` |

「NULL 没有主」的那一类,`NULL` 才是可用的"受限"信号 —— `bank_book_balance_asof`
与 `attendance_unpaid_days` 都 `COALESCE(…, 0)`,今天**根本产生不出 `NULL`**,
所以那个值是空着的,可以拿来用。

## ↩ F05 · from AGENTS.md § 拒绝要用哪个值表示 —— 判据是【NULL 有没有主】,不是返回类型(CLEANUP-A,2026-08-31) (old lines 1214–1228)

**Measured, so the gap is a size rather than a worry (2026-08-09).** Six views reach
a module *only* through another view: `employee_directory` (hr → hides finance),
`ap_open_items` (hides inbound), `batch_assay_status` (hides purchasing+pricing),
`po_prepayment_applicable`, `po_receivable_lines` and `purchase_order_status` (each
hides purchasing+inbound). **Five of the six are owner rights after OPS-14, so they
are immune by construction** — the disease needs invoker semantics. The one that is
still `security_invoker` is `employee_directory`, and it was probed rather than
assumed: an `hr`-only reader gets **the row, with `current_gross_pay` NULL** — that
is `data.view_pay` masking working correctly, not row loss — and a
`finance+view_pay` reader gets zero rows because `employees_masked` gates on
`module.hr.view`. Its hidden finance branch is an `OR` that only *widens*. So the
blind spot is **bounded at one view today and that view is not defective — but the
mechanism is general**: any new invoker view over a `_masked` view inherits it.
The cheap defence is to prefer owner rights for anything cross-module, which is what
the remedy table above already says.

## ↩ F06 · from AGENTS.md § A fixture can be thorough about a rule and blind to the case where the rule's SUBJECT IS ABSENT (old lines 1246–1258)

`db/fixtures/39` tests the credit limit from every angle that occurred to its author: NULL limit
versus zero limit, base currency versus document currency, cumulative exposure, hold with no
exposure, the history rows, the dashboard arm. **Every one of its arms passes an explicit
customer.** None asks what happens when there is no customer at all — and the answer was that
`record_output_sale` skips the entire credit block (`IF p_customer_id IS NOT NULL THEN`), so an
ownerless sale of any size is never checked. A 1,397 sale against a 1,000 limit went through, and
the fixture stayed green because the situation it created was one the fixture never described.

**This is not the empty-set vacuity already listed above.** There, the set was empty and the
assertion looped over nothing. Here the set is full, the arithmetic is exercised, the refusals fire
— and the *subject the rule is about* is missing, so the rule is not reached at all. A test suite
shaped entirely around "the rule applies, does it apply correctly?" cannot see "does the rule apply
at all?".

## ↩ F07 · from AGENTS.md § A fixture can be thorough about a rule and blind to the case where the rule's SUBJECT IS ABSENT (old lines 1266–1268)

The same question applies to the fix: SAL-C's `attribute_sale_customer` exists precisely because
the subject can be absent and later become known, and its fixture arms cover *both* the absence
(recorded without a check) and the transition (attached, logged, exposure moves, one-way).

## ↩ F08 · from AGENTS.md § The same disease inside a REPORT: a self-check that compares a number with itself (old lines 1467–1478)

**The survey OPS-17 ran, so the class is bounded rather than worried about
(2026-08-09).** Every comparison of this shape in `db/functions` and `db/views`:

| site | two sides independent? | can it fail? |
|---|---|---|
| `cash_flow_statement.ties` | **now yes** — `balance_sheet()` is a separate function | yes, fault-injected |
| `preview_close_financial_year.trial_balanced` | yes — `SUM(debit)` vs `SUM(credit)`, different columns | **no, structurally**: `trg_journal_lines_balance` is a DEFERRABLE constraint trigger enforcing Σd=Σc per entry at commit, so committed data cannot fail it |
| `balance_sheet.balanced` | yes — assets vs liabilities+equity+earnings, disjoint account sets | **no, structurally**: same trigger, same reason (the identity follows from Σ(debit−credit)=0 over all accounts) |
| `allocate_processing_costs` → `ALLOCATION_LEDGER_DIVERGED` | yes — a stored `capitalized_cost_base` vs the capitalisation entry's **status in the GL** | yes; it is the one remaining red by design |
| `preview_close_financial_year.revaluation_level` / `.depreciation_level` | n/a — **not comparisons**: readiness flags read off one derivation | n/a |
| `revalue_foreign_balances`, `close_financial_year`, `depreciate_fixed_assets` calling their previews | n/a — **one implementation, two callers**, which is the intended pattern | n/a — there is no second derivation to drift |


## ↩ F09 · from AGENTS.md § Entitlement is DERIVED; consumption is RECORDED — so a fresh database gives everything away (old lines 1545–1554)

Instances found so far, all the same shape:

* **annual leave carry-forward** — accrual runs from hire date whether or not
  this database was operating that year, so a 2020 hire gets a full year
  conjured out of a year that never happened here (HR-5, now refuses);
* **medical claim limit** — the annual allowance is derived from
  `hr_settings`, consumption comes from `medical_claims` rows, so pre-cutover
  claims are invisible and the *entire* allowance becomes available again.
  Worse than display: `decide_medical_claim` gates approval on that figure, so
  it approves claims it should refuse (HR-6, now bounded);

## ↩ F10 · from AGENTS.md § The third verdict: db/fixtures — does the rebuilt database WORK (old lines 1601–1710)

Twenty-five fixtures, ~128 assertions, on the paths where a silent break costs money:
settlement closing to exactly zero (including cross-currency), revaluation
idempotence, confirmation not touching leave, accrual not applying a category
change retroactively, one bank line per employee, realised 7100 never crossing
unrealised 7110, period lock, over-allocation in both currency spaces, the
bounded FX reach-back, the three `system_start_date` bounds, the database's
"today" being Singapore's today (config + semantics + both walk-observed
symptoms; a fixture cannot move the server clock, so the config arm is the
24-hour guard and the behaviour arms gain full discrimination during the
00:00–08:00 SG window), and a fully
allocated payment leaving **exactly zero** on account even when the rate moved
between booking and settlement (FIN-18 — that one asserts the *old* formula
differs too, so it cannot pass by both answers agreeing), and fixed assets
(FIN-22: depreciation from the in-service date not the acquisition date,
idempotent by arithmetic, capped at cost minus residual, non-monetary and
invisible to revaluation, disposal clearing 1500/1510 exactly, locked periods
refused by name), and year-end close (FIN-23: P&L accounts derived by
account_type never a code range — the FX arm posts to 7100 and a 4000-6999
implementation fails it; balance-sheet accounts untouched as one snapshot;
idempotent by arithmetic; the closed year's P&L still reproducible — the
report EXCLUDES year_close entries while the balance sheet INCLUDES them,
deliberately asymmetric, comments cross-referenced in both queries; the
YEAR_CLOSED guard in post_journal_entry is independent of locked_before, so
month-level reopen_period cannot pierce a closed year — the fixture's E arm
walks exactly that path; reopen reverses the closing entry with a reason and
restores the trial balance to the cent), and allocation's delta split
(FIN-24: re-allocation posts target-minus-recorded per OUTPUT BATCH — in-stock
share to 1220, sold-with-COGS share to 5000, written-off share to 5200 — the
material delta credits 5000 where repricing parks the consumed share, so the
two mechanisms compose instead of double-counting; repricing an input now
flags consuming runs stale; the one remaining red is a manually-reversed
capitalization entry, ALLOCATION_LEDGER_DIVERGED), and re-processing (FIN-25:
output batches feed further runs — two-sourced recovery arithmetic asserted
against hand-computed figures, cost relieved from 1220 not 1200, upstream
deltas propagating one edge per re-allocation through the stale flags with no
recursion, unpriced upstreams allowed but marked cost_incomplete and never
silent, reversal and self-consumption guards, and the metal_value arm on
fixture 18 that numerically separates per-batch from run-level ratios —
62.50 vs 27.50 — where the weight basis provably cannot), and PO price
provenance (FIN-26: price_source is RECORDED, never inferred from
expected_assay; a computed line carries enough to re-derive the number and
the fixture actually re-derives it; existing rows stay NULL and display as
unknown — a fabricated provenance record is worse than a blank), and committed
pricing terms (FIN-27: a formula referenced by a deal cannot change under it,
because the terms are COPIED onto the committing record and settlement reads the
copy — the fixture commits, edits the formula, settles, and asserts the
*committed* number, with the live-formula number computed alongside and asserted
to differ, so the arm cannot pass by both answers agreeing; a deal raised AFTER
the same edit uses the NEW terms, which is what stops "never update anything"
from passing too; a reference with no copy is refused BY NAME on both settlement
paths rather than silently falling back to the live formula; and a formula edit
writes an append-only history row with old and new — including the metals
sub-table, where the UI expresses "no longer payable" by DELETING the row, so a
header-only history would be silent about the most drastic edit there is).
and a payment term
template's fixed instalment (FIN-29: a template belongs to no order, so its fixed
amount had no currency at all — and `apply_payment_term_template` copies
VERBATIM, no rate is consulted, so "deposit 10,000" landed as 10,000 on a USD
order and on an SGD one alike and read correct on both. The template now declares
its own currency and a different-currency order is refused BY NAME rather than
converted — a payment term is a negotiated commitment, not a computed quantity,
the same reasoning as FIN-27. The declaration is CONDITIONAL: percentage-only
templates need no currency and must not be forced to invent one, which is what
the third arm holds — a "currency always required" implementation passes the
other three. Enforced by a guard trigger on BOTH parent and child, because the
rule spans two tables and a CHECK cannot see another table; and the validation
runs BEFORE the delete, so "refused means nothing was written" is structural
rather than a rollback artifact — the second arm asserts the order's own plan
survives the refusal intact).
and the cash flow statement (FIN-30: the hard part is
not the arithmetic, it is what counts as a cash flow. 1010 is revalued each
period end — its BASE-currency carrying value moves while no money does, and a
statement derived from base-currency movements prints that as a phantom cash
flow that balances perfectly. Revaluation is therefore a separate reconciling
line below the three sections, keyed off the entry's DECLARED source_type;
year_close is excluded, manual entries carry nothing so they are shown as their
own "unclassified" line rather than assumed operating, and which accounts are
cash / investing / financing is DECLARED on the account (`is_cash`,
`cash_flow_section`) instead of hardcoded — the year-close code-range defect
again. Self-checking: opening + sections + FX = closing, AND closing equals the
balance-sheet cash figure — **which was NOT "computed independently" until OPS-17,
though this paragraph said it was.** Both sides came out of the same function body
and the same arithmetic, so `ties` moved with the defect and could never report
false; live returned `ties=true` for all five probed periods, including one that
split a reversal pair across the period boundary. OPS-17 pointed it at
`balance_sheet(p_to)` — a different function, a different aggregation path — so the
sentence is now true. When they disagree the page says so instead of printing a
number that does not tie. Note the third arm was
VACUOUS on first write — a realistic year-close touches no cash, so it could
never enter the "entries that moved cash" set and the exclusion was untested;
deleting the filter left the fixture green. It now also posts a MALFORMED
cash-touching year-close and asserts the statement reports ties=false, which is
what makes the filter load-bearing).
and the inventory ledger's business date (FIN-32:
`business_date` is the day the thing HAPPENED, not the day it was keyed in — and
it was 58% empty, in a pattern: writeoff / reversal_void / reversal_restore were
100% empty because those paths never wrote it, and receipts were 80% empty
because they copy a nullable `arrival_date`. Both ends closed. The decision worth
knowing is the reversal's date: a rollback is NOT a physical event — batteries
that were processed stay processed — it corrects a mis-recorded run, so it takes
the ORIGINAL run's `process_date`, which makes the error and its correction
cancel on the same day and stops the intervening days showing stock that was
never really absent. Writeoff is the opposite — a real physical event — so it
takes `deleted_at::date`, read from the row rather than the clock. New rows are
required via `CHECK (...) NOT VALID`, which enforces on insert while leaving the
15 historical nulls untouched: they are history, not a bug, and backfilling them
would invent a fact nobody recorded).
Deliberately small: every retained fixture is
maintenance on every schema move, and the HR-2c accrual change already cost one
round of "is this staleness or regression?" judgement.

## ↩ F11 · from AGENTS.md § Filtering journal entries to `status='posted'`: wrong when SUMMING, right when testing ONE entry (old lines 1752–1771)

**Four occurrences of the aggregate mistake so far, and it keeps coming back:**

| | where | found | state |
|---|---|---|---|
| ① | `cash_flow_statement` | OPS-17 | fixed |
| ② | `f5_return` / `f5_box_detail` | GST-2 | fixed, with the reasoning left in the function body |
| ③ | `bank_reconciliation_status.ledger_balance` | BANK-REC (2026-08-26) | fixed — **and it had been wrong on the live bank page the whole time** |
| ④ | `preview_revalue_foreign_balances` (**two** filters, not one) | BANK-REC, while fixing ③ | fixed by FXREV-1 (2026-08-27) — **and it had already posted a wrong entry: SGD 56,532.48** |

**③ was measured, not inferred (2026-08-26):** account `1010` carries 2 reversed
journal lines, so the bank page was showing **−31,338.70 where the ledger actually
says −29,753.70 — out by USD 1,585.00 in production.** `1000` happened to have no
reversals and was correct by luck, which is why nobody saw it.

**④ is the one that reached the ledger, and it is worth knowing how far.** The
misstatement was **SGD 56,532.48** on `JE-2026-0024` (FX revaluation as at
2026-07-31) — an overstated unrealised FX loss, posted because two reversed
originals on `2000` were dropped while their reversals were kept. It was
corrected forward by `JE-2026-0070` on 2026-08-27; July itself stays as it was.
Full record: `docs/fx-revaluation-misstatement-2026-07.md`.

## ↩ F12 · from AGENTS.md § THE FX RULE — one rule, of which the rest are instances (old lines 1817–1834)

  > **How FIN-13 was wrong, because the shape recurs.** It said "every day
  > *strictly between* the rate and the transaction must be a non-business
  > day" and implemented `generate_series(v_when + 1, p_date - 1)`. For
  > **consecutive dates that interval is empty**, so the condition is
  > vacuously true and *every* business day silently accepted yesterday's
  > rate. That is the exact silent nearest-date lookup FIN-0 removed from
  > `pay_medical_claim`, reintroduced with a blessing on it — and it read as
  > a strict rule, which is why nobody re-derived it. Live proof: 5 Aug had a
  > rate, 6 Aug did not, and a 6 Aug receipt booked at 5 Aug's 1.24.
  > **A guard phrased over the interior of a range is vacuous at the
  > boundary. State such conditions over the closed range and check the
  > endpoint explicitly.** The fix was one token; finding it took a human
  > noticing a number on a screen.
  >
  > Note this also made the London/Singapore bullet below *true for the first
  > time*: before FIN-19, a UK bank holiday that SG treats as a business day
  > did not produce a conservative refusal — it silently took the previous
  > day's rate whenever one existed.

## ↩ F13 · from AGENTS.md § Currency codes are data, not constants (old lines 1986–1991)

Why a check and not care: FIN-0 changed the base from USD to SGD, and the
constants left behind broke four screens over four separate sweeps —
`/finance/payments` valued a base-currency payment at 0.00 and a USD one at
1:1 (FIN-12), and manual journal entry demanded an FX rate for base-currency
lines. Two full manual sweeps each missed a site. The check found 32 in one
run, including one I had just written myself.

## ↩ F14 · from AGENTS.md § Currency codes are data, not constants (old lines 2004–2012)

**76 instances were already there** (en 40, zh 36), so it is a **ratchet, not a
wall**: `scripts/currency-messages-baseline.json` holds today's count per
⟨file · key⟩ and the 77th turns it red — the same medicine `check-masked-reads`
took for its 71, and for the same reason (a check that reddens 76 lines on day one
teaches people to skip the gate). The report groups them **by shape** so a later
reader can tell the disease from the truth without re-deriving it: **36 `label`**
(currency baked into a column header — the FIN-0 disease), **20 `unit`**
(`USD/t`, `USD/kg`, `USD/吨` — genuinely dollars), **16 `prose`**, **4
`account-name`**. Full list in `docs/known-issues.md` under CHECK-1-MSG.

## ↩ F15 · from AGENTS.md § A failed query must fail — never `?? []` (old lines 2215–2221)

**The two live instances are on the books, and the shape of that record matters.**
They are in the script's `QUEUED` list, **not** its `ALLOWLIST`, and the two mean
opposite things: `ALLOWLIST` asserts *this is not a defect*; `QUEUED` asserts
*this is a defect, just not fixed in this cut* and must name where it goes.
**Recording something uncertified as allowlisted is how the next reader comes to
believe someone checked it.** Queued entries print on every run with their reason
and destination (cleanup A — permissions and error handling).
