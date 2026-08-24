# Phase 4 (CFO tools) — survey

**Status: SURVEY ONLY (FIN4-0, 2026-08-24). Read-only. Nothing was built, nothing was written to
live, no migration, no backup, no deploy.**

Tim was walking `docs/manual-walk-list.md` §16 on production while this ran, so this cut
deliberately did **not** run the route smoke (it starts a dev server and writes scratch rows to
live), did **not** run `db/gate.py` (its `check_mirrors` half replays into a scratch schema **in
live** and takes the live lock), and started no dev server.

The queue entry this surveys is `docs/forward-queue.md` § 阶段 4. **This file does not restate it**;
it measures it.

---

## 0 · Two numbering corrections, before anything else

**The queue's Phase 4 list has ELEVEN bullets, and none of them is the capitalisation item.**
"Capitalising subsequent expenditure on a machine already in service" is recorded in
`docs/known-issues.md` § 大修资本化【今天走不通】, reached from the EQP-2b row of the queue's
Phase 1 table. It is a CFO item and it belongs in this phase's sequencing, so this survey treats
the set as **eleven queue bullets + that one = twelve**, and numbers them as §4 below.

**The issue mechanism has SEVEN members, not six.** The queue calls a statement of account its
"seventh member". Measured: `qt_issues`, `so_issues`, `po_issues`, `invoice_issues`, `cn_issues`,
`shipment_issues`, `traceability_report_issues`. A statement would be the **eighth**.

---

## 1 · A measurement trap this survey fell into, recorded because the next reader will too

Querying `ap_open_items` / `ar_open_items` as `postgres` **with no JWT claims** returns
**zero rows** — and the ledger is not empty. Both views gate on `has_permission()`, which resolves
`request.jwt.claims`; with no claims it is false and every row vanishes silently.

```
no claims  →  ap_open_items 0 rows,  ar_open_items 0 rows
with claims →  ap_open_items 13 rows / 429,537.62 base
               ar_open_items  8 rows /  56,300.00 base
```

**A survey that had reported "AP and AR are empty" would have been a wrong premise under the whole
forecast item.** This is the same shape `AGENTS.md` records under `xmodule` and `restRows`: a
question asked wrong returns an empty set, and an empty set reads as an answer. **Set the claims.**

---

## 2 · The thirteen-week cashflow forecast — per source

The question that matters is not "does the data exist" but **"does it carry a date that can be put
in a week, and is that date a promise or a guess."**

| source | exists? | carries a week-buckettable DATE? | promise or guess |
|---|---|---|---|
| **AP open items** | **yes** — `ap_open_items`, 13 rows, 429,537.62 base | **NO due date.** Columns are `doc_date`, `days_outstanding`, `bucket`. Ageing is computed `CURRENT_DATE - doc_date` | the doc date is a fact; **a payment date does not exist** |
| **AR open items** | **yes** — `ar_open_items`, 8 rows, 56,300.00 base | **NO due date.** `sale_date`, `days_outstanding`, `bucket`, same basis | same |
| **Supplier / customer payment terms** (the only way to derive a due date) | columns exist: `suppliers.payment_terms`, `customers.payment_terms`, `customers.payment_terms_days` | — | **0 of 8 suppliers and 0 of 3 customers have any of them filled.** A due date cannot even be derived |
| **Confirmed POs not yet invoiced** | **yes** — 4 in `confirmed`/`receiving` | `purchase_orders.order_date`, `expected_delivery_date` | delivery date is an expectation |
| **PO payment plan** — the real commitment | **yes** — `purchase_order_payment_terms`, **15 rows** | **`due_date` is nullable and 0 of 15 are filled.** `trigger_event` is **NOT NULL** and all 15 are set | **★ the plan is EVENT-anchored, not date-anchored** — see below |
| **Sales orders not yet invoiced** | **yes** — 6 open | `order_date` only. **No expected invoice or delivery date column** | nothing to bucket |
| **Payroll obligations** | `payroll_periods`, 1 row, `payment_date` filled | **yes**, `payment_date` | a promise, and the most reliable date in the set |
| **Recurring costs** | **NO TABLE AT ALL.** Zero tables matching `%recurring%` / `%schedule%` / `%subscription%` | — | — |
| **Bank balances** | GL only — `accounts.is_cash`, **2 cash accounts**. Also `bank_statements.closing_balance` per imported statement | balance is as-of-now from the ledger | fact, but see §3 |

### ★ The finding that reframes this item

**All 15 payment-term rows are percentage-based and anchored to an event, not a date:**

```
trigger_event   rows   with due_date   pct-based   fixed-amount
on_shipment       5          0             5            0
on_arrival        5          0             5            0
post_assay        5          0             5            0
```

This is not neglect — it is how this business actually contracts, and FIN-29 built the currency
rules around it. But it means **the commitments are recorded and are real, while their dates are
not knowable from the record**: `on_arrival` depends on shipping, `post_assay` on lab turnaround.

### So: how much of the next thirteen weeks is knowable today?

**Knowable from what is recorded:** payroll (`payment_date`), and the opening cash balance.
Essentially one row and one number.

**Not knowable without new input:** every AP and AR item (no due date, and none derivable because
terms are 100% unfilled); every PO instalment (event-anchored); every sales order; all recurring
cost (no table).

> **A thirteen-week forecast built today would be a data-entry screen with a chart on top.**
> That is not an argument against building it — it is an argument about **what** to build:
> the missing thing is not a report, it is **a date on a promise**. Two candidate sources exist
> and are cheap relative to the forecast: fill `payment_terms` on counterparties (a master-data
> task, not code), and give `purchase_order_payment_terms` an *expected* date beside its
> `trigger_event` — explicitly an estimate, never presented as a fact.

---

## 3 · Bank reconciliation — the queue's premise is STALE, and the real gap is elsewhere

**The queue says 「今天【没有银行对账单这个实体】,所以"已对账"根本不是一个状态」. That is no
longer true.** Measured:

| table | what it carries |
|---|---|
| `bank_statements` | `code, bank_account_code, currency, period_start, period_end, **opening_balance, closing_balance**, file_name, **status, reconciled_at, reconciled_by**, notes` |
| `bank_statement_lines` | `statement_id, line_no, line_date, description, reference, amount, **match_status**, ignore_reason, notes` |
| `bank_line_matches` | `statement_line_id, **journal_line_id**, matched_amount` |
| `bank_import_profiles` | `bank_account_code, mapping` — column mapping per bank |

So the entity exists, "reconciled" **is** a state, and lines match against **journal lines**.

### What is actually missing — and it is the part that makes a reconciliation a reconciliation

`reconcile_statement` asserts exactly one thing:

```
count(*) FILTER (WHERE match_status = 'unmatched') > 0  →  RAISE 'LINES_OUTSTANDING|%'
then  status='reconciled', reconciled_at=now(), reconciled_by=auth.uid()
```

**It checks that every line has been dealt with. It never checks that the bank's
`closing_balance` agrees with the book balance of that cash account at `period_end`.**

So today a statement can be `reconciled` while the bank and the ledger disagree — the flag asserts
*line coverage*, not *balance agreement*. The queue asked for 「银行余额、账面余额、差额、说明」:
the bank balance is there (`closing_balance`); **the book balance, the difference, and the
explanation of the difference have no home at all** — no column, no table, no computation.

**Shape of the cut:** not "build bank reconciliation" — it exists. It is: compute the book balance
of `bank_account_code` as at `period_end` from the GL, store it beside `closing_balance`, store the
difference, require the difference to be itemised (timing items are legitimate; an unexplained
difference is not), and make `reconcile_statement` refuse on an unexplained variance the same way
it already refuses on an outstanding line. **That is one named refusal added to a function that
already has the right shape.**

---

## 4 · AP ageing — parity confirmed; what is missing is BOTH, and they differ in kind

**Parity is real.** `/finance/payables/page.tsx` and `/finance/receivables/page.tsx` both import
`BUCKETS, bucketPillClass` from the shared `app/finance/agingBuckets.ts`. `ap_open_items` computes
`days_outstanding` and `bucket` (`b0_30` / `b31_60` / `b61_90` / `b90_plus`) itself, over all three
document kinds. The queue's correction to its own text is accurate.

**The queue then asks: as-at-a-date report, export, or both? Measured answer: both.**

**As at a past date — structurally impossible from these views, for two independent reasons:**

1. `CURRENT_DATE` is **baked into the view body**: `CURRENT_DATE - doc_date AS days_outstanding`,
   and every bucket boundary is `(CURRENT_DATE - doc_date) <= n`. A view takes no parameter, so
   there is nowhere to put an as-of date.
2. **Even parameterising the date would not be enough.** `settled_base` / `open_base` are computed
   from allocations **as they stand now**. An ageing as at 30 June must ignore settlements made in
   July — that is a different computation, not a different argument. This is the harder half and
   it is the reason this is a new function rather than an edit.

**Export — simply absent.** There are nine export routes in the tree (`customers`, `materials`,
`suppliers`, `output`, `inbound`, and four under `inventory/reports`), and **none under
`app/finance/` except PDF routes**. AP/AR ageing is the report a CFO most wants in a spreadsheet
and it is the one report family with no CSV.

**Shape:** the export is small and has nine precedents to copy. The as-at report is a new
`ap_aging_as_of(p_as_of date)` / `ar_aging_as_of(...)` pair whose real content is
"which allocations existed on that date".

> **One thing worth stating because the word "ageing" hides it:** these buckets measure **days
> since the document date**, not **days past due** — because there is no due date (§2). An invoice
> on 60-day terms sitting at 45 days is not overdue, but it renders in `b31_60`. Nobody has been
> misled yet because terms are unfilled, but a due date and an ageing report are the same missing
> fact seen twice.

---

## 5 · Statements of account — the mechanism exists; what an eighth member costs

**The mechanism is real and uniform.** All seven `*_issues` tables share one shape:
`<subject>_id, version, file_path, sha256, issued_at, issued_by` (`traceability_report_issues`
additionally carries its own `code`). Versioning, byte-hashing and issuer are already the house
pattern, and SO-4b proved on production that a re-issued document does not mutate the earlier
version's bytes.

**What every existing family has, that a statement would need:**

| component | note for a statement |
|---|---|
| an `<x>_issues` table + RLS + grants + mirror | mechanical, seven precedents |
| a `record_<x>_issue` function | mechanical |
| a storage bucket | one per family today |
| a PDF render route | **the only genuinely new work** — a statement's body is *not* one record but *a range*: opening balance, documents in the period, payments, closing balance |
| a preview + issue control on a detail page | **a statement has no detail page today** — it is per-customer-per-period, so the entry point must be invented, not extended |
| bilingual refusals | mechanical |

**The recorded company-block finding is confirmed verbatim** (`docs/known-issues.md`, EQP-1c-b-fu2):
`company.*` reference counts are **purchase order 7, invoice 21, quote 0, delivery note 0, credit
note 0, sales order 0** — two of six outward documents print our own address, and that entry
deliberately reports the numbers without concluding whether the four are deliberate.

**Consequence for a statement, stated because it is the one document where it is not arguable:**
a statement of account is a demand for money sent to a customer. **It must carry the company
block.** Building it makes the "two copies of the address block, no shared layout" finding
load-bearing rather than latent — a statement would become the **third** copy unless the Phase 8
outward-document-format cut lands first, or this one adopts `lib/companyAddress.ts` deliberately.

---

## 6 · Item 11 (capitalising subsequent expenditure) — premise CONFIRMED, with one correction

**Confirmed, verbatim from the code.**

`record_expense` refuses the append once the asset is in service:

```
IF v_target.in_service_date IS NOT NULL THEN
    RAISE EXCEPTION 'ASSET_ALREADY_IN_SERVICE|%|%', v_target.code, v_target.in_service_date;
```

`preview_depreciate_fixed_assets` computes a **cumulative** target and subtracts everything ever
posted:

```
v_target := LEAST(cost_base - residual_base,
                  (cost_base - residual_base) / useful_life_months * months_in_service)
v_posted := SUM(fixed_asset_depreciation.amount_base)  -- for this asset, all time
v_delta  := target - posted
```

**So the back-charging is real and it is arithmetic, not policy:** raise `cost_base` mid-life and
`v_target` rises for **every month already elapsed**, and the entire catch-up lands in the
**current** period's `delta_base`. That is exactly the difficulty the known-issues entry names, and
it is why the refusal is correct rather than lazy.

**The correction — the same wall has a second side, and it is asymmetric:**

```
IF v_delta < 0 THEN v_delta := 0; END IF;
```

A **downward** revision is silently ignored by the monthly routine (documented in-line as
deliberate: a reduction is a correction and belongs in a manual entry, not in a routine that
quietly reverses). So an increase would back-charge and a decrease does nothing — **the routine is
not symmetric**, and any design for this item must say which of the two it is imitating.

### 6b · The commissioning copy — half of the brief's premise is FALSE

**"The sentence is still there" — confirmed, and there are FIVE of them, not one**, en/zh at parity:

| key | says |
|---|---|
| `assets.readyToCommission` | "commissioning FREEZES the cost — nothing can be added afterwards" |
| `assets.commissionWhy` | "…FREEZES the cost — no further cost can be added to this asset afterwards" |
| `equipment.…existingAssetHint` | "Once a machine is commissioned its cost is frozen" |
| `finance.errors.ASSET_ALREADY_IN_SERVICE` | 成本已冻结、折旧已开始 |
| `equipment.errors.ASSET_ALREADY_IN_SERVICE` | 从那天起它的成本就冻住了 |

**"It is flagged for retirement in the same commit that closes this gap" — NOT TRUE. Nothing
flags it anywhere.** Grepped across `docs/`: the known-issues entry cautions about the *column*
(`capitalised_expense_id`) and the table comment repeats it, but **no document says these five
strings must be retired when the path opens**. `docs/manual-walk-list.md` §9 goes further and
**asserts the copy should be on screen** — so when the gap closes, a walk item will be checking for
a sentence that has become false.

> **This is the "a note describing a hazard that no longer exists" defect, pre-loaded.** It is
> recorded here now so the closing commit inherits it: **five message keys and one walk-list step
> retire together with the refusal.**

---

## 7 · Recommended sequence, with a reason per position

The twelve, in the order the measured dependencies support. **Merged by default; splits are named.**

| # | item | why here |
|---|---|---|
| **1** | **GST readiness — SURVEY ONLY (queue item 9)** | Measure-only, independent of everything, and its trigger is a **turnover threshold that arrives at the busiest moment**. The whole value is knowing the conversion size *before* that day. Cheapest item in the phase and the only one whose value decays with delay. **Stays a survey — see §8.** |
| **2** | **Bank reconciliation completion (item 2)** | Independent of the AP/AR spine, and it is what makes the **cash balance trustworthy** — which is the one number a forecast cannot do without. Small: one computation and one named refusal on a function that already exists. |
| **3** | **The as-at spine + export (item 3)** — *merged* | `ap_aging_as_of` / `ar_aging_as_of` + CSV export for both. **Merged because they are one report growing up**, and because as-at-a-date is the single computation that items 4, 5 and 7 all need. Doing it once here is why the rest get cheaper. |
| **4** | **Statements of account + collection records (items 4 and 5)** — *merged* | A statement is "as at date X, here is what you owe" — it **consumes** #3 directly. Chasing records are the log of the conversation that a statement starts; they share the customer, the period and the screen. **Merging is the default and there is no reason to split them.** |
| **5** | **13-week cashflow forecast (item 1)** | **Deliberately not first — see below.** By this point AP/AR carry an as-at computation (#3) and the cash balance is trustworthy (#2). |
| **6** | **Expense claims + petty cash (item 6)** — *merged* | Two halves of one thing: HR has only medical today. Independent of the reporting spine; it extends the existing `expenses` machinery. |
| **7** | **Attendance (item 11 in the queue)** | Independent of the finance spine — it **feeds payroll**, which is why the queue folded it here. Can move earlier if payroll accuracy becomes urgent; nothing above depends on it. |
| **8** | **Withholding tax on non-resident payments (item 10)** | Event-triggered: the first non-resident service payment. Independent. Build when that event is in sight. |
| **9** | **GL / journal export (item 8)** | The queue already says fold it into the queued year-end export. **Merged there, not a cut of its own.** |
| **10** | **Monthly management report pack (item 7)** | **Last of the reporting group by construction** — it consumes ageing, cash, bank reconciliation and the forecast. Building it earlier means building it twice. |
| **11** | **Capitalising subsequent expenditure (the known-issues item)** | **BLOCKED on an accounting decision**, not on engineering. See §8. |

### On item 1's position — Tim REORDERED IT on this evidence (2026-08-24)

> **Recorded so no later reader mistakes this for drift.** Tim originally proposed the thirteen-week
> forecast first. **On the measurement below he moved it**, and the reordering is his decision taken
> on that evidence — not a survey quietly overriding a stated preference.
>
> **Bank reconciliation also moved out of this cut** and is the next one: it shares nothing with
> GST, and GST at full scope is a module rather than an item.

### The measurement that produced that reordering

**The forecast's inputs do not exist as dates today** (§2): no due date on AP or AR, no derivable
one (terms 0% filled), payment plans anchored to events, no recurring-cost table. Built first, a
thirteen-week forecast is a hand-entry screen whose only recorded inputs are one payroll date and
a cash balance — and the cash balance itself is not yet trustworthy, because a statement can be
`reconciled` while bank and book disagree (§3).

**Placing it after #2 and #3 changes what gets built rather than merely when:** the forecast then
reads a cash balance that has been agreed to the bank, and an ageing that can be asked "as at".
**It also does not need to be later than that** — nothing in #4–#10 feeds it.

**If Tim wants the forecast first regardless, the honest version of that is to build the missing
dates first**: fill counterparty payment terms as master data, and add an *expected* date beside
`trigger_event`. Those are cheap and they are the actual prerequisite. That is a business
sequencing call, not a technical objection.

---

## 8 · Items that need a business answer before their shape can be decided

**Two. The other ten have none** — their shape follows from what is already recorded.

**① Capitalising subsequent expenditure.** The question is already stated in
`docs/known-issues.md` and this survey does not restate it: what happens to depreciation already
posted when cost is added mid-life — ① new basis prospectively, ② recompute and true up,
③ only allow it inside an unlocked period. **The three produce different journals, different
periods and different vouchers**, so the shape cannot be chosen without the answer. Its recorded
return condition is the first real overhaul, which supplies the amount, the machine and the period.

**② ~~The thirteen-week forecast's event→date bridge.~~ — ANSWERED (Tim, 2026-08-24).**

~~To place them in a week, someone must say what an expected date for each is and **who owns that
estimate**.~~ **The owners are named:**

| trigger event | who owns the expected date |
|---|---|
| `on_shipment` | **Sandra Yap** |
| `on_arrival` | **Fu Sheng Wong** |
| `post_assay` | **Fu Sheng Wong** |

**This is recorded against the forecast item, and the column is NOT built here** — FIN4-1 builds
GST. The point of recording it now is that the forecast cut inherits an owner per event instead of
re-opening the question.

> **A PROPOSAL on `post_assay`, awaiting Tim — recorded as a proposal, not a decision.**
> Default the `post_assay` date by **adding a fixed number of days to the expected arrival date**,
> and let it be **overridden per consignment**. **The number of days is unset** — that is the part
> still needing an answer.
>
> **The reason for a default-plus-override rather than either extreme:** a purely manual date goes
> stale — somebody types it once and nobody revisits it, and a forecast built on stale dates is
> worse than one that admits it is estimating. A purely automatic date is wrong the first time a
> third-party lab takes a month, and there is no way for the person who knows that to correct it.
> **The override is what keeps the automatic default honest**, and the default is what stops the
> manual date from rotting.
>
> This repo has ruled the same shape before: a value that is computed but visible and changeable is
> a choice; one that is computed and silent is a wrong answer.

**Explicitly none** for: bank reconciliation, the as-at spine and export, statements, collection
records, expense claims and petty cash, management pack, GL export, GST survey, withholding tax,
attendance.

### ~~GST readiness stays a survey~~ — **OVERRULED TWICE, AND THIS SECTION WAS WRONG**

> **Left standing, struck through, because being wrong in a recorded way is the point of this file.**
> GST-1 (2026-08-24) built the machinery; GST-2 (2026-08-25) wired the documents into it. Tim
> overruled this recommendation both times, and the reasoning below is where it went wrong:
>
> * *"Building GST machinery before registration means carrying untested tax code through every cut
>   that touches money"* — **this assumed the code would be live.** It is not: while
>   `gst_registered = false`, a row carrying a tax code **cannot be written at all**. The cost of
>   carrying it is therefore near zero, and the survey priced it as if it were a live feature.
> * *"the switch exists"* — the switch existed and **did nothing**, which is worse than no switch:
>   `gst_rate_pct` was a **scalar**, and a scalar cannot express a rate history (2022 is 7%, 2023 is
>   8%, 2024 is 9%) or tell zero-rated from exempt from out-of-scope. Reading the switch's existence
>   as readiness was the actual error.
> * The one thing the survey got right is the trigger: it arrives at the **busiest moment**. That was
>   offered as a reason to *defer*; Tim read the same fact as the reason to **build now**, and that
>   reading is the better one.
>
> **What was genuinely still open was never the code — it was a statutory ruling** (is a supply
> reported in the invoice period or the sale period), and no amount of surveying would have produced
> it. See `docs/forward-queue.md` phase 4 and `docs/accounting-policies.md` 8.1.

The queue says 「只测量改造量,什么都不建」and this survey endorses it without qualification.
The company is **not registered**; the trigger is a turnover threshold. Building GST machinery
before registration means carrying untested tax code through every cut that touches money, and
`finance_settings` already holds `gst_registered` / `gst_rate_pct` / `gst_registration_no` — the
switch exists. **The deliverable is a number (how much changes) and a list (what changes), not a
feature.**
