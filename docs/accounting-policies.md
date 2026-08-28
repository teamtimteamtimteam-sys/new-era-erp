# Evoltrya OS — Accounting Policy Memorandum

**Entity:** Evoltrya (Singapore). **Functional and presentation currency:** Singapore Dollar (SGD).
**Prepared:** 2026-08-23. **Status:** current as at the date above.

## What this document is

This is a statement of the company's accounting policies. It is written for someone who has not seen
the accounting system — an external auditor, a new finance hire, or an adviser being asked whether a
treatment is appropriate.

The system is **evidence that a policy is followed**, not the subject of the policy. Every statement
below therefore carries an **enforcement point**: the specific database function, constraint or
automated test that makes the policy hold in practice. That column exists for two readers — an auditor
who wants to know whether a control is a rule or a habit, and an engineer who changes one of those
objects and needs to know a policy statement depends on it.

The memorandum is written in English, which is the reading language for statutory and audit purposes
in Singapore and the language of the company's founding design documents. Where the team's working
vocabulary is Chinese, the Chinese term appears in parentheses at first use.

## How to read the marks

Each statement carries one of three marks. **The marks are the most important feature of this
document**, because they distinguish what the company has decided from what the software happens to
do.

| Mark | Meaning |
|---|---|
| **SETTLED** | Someone decided this, and the decision is recorded. The entry names where. |
| **AS-BUILT** | The system behaves this way and **no one has ruled on it**. It is described here so it can be ruled on — not because it is endorsed. |
| **DIVERGES** | A founding design document records a decision, and the system does something else. The entry quotes the document, states what the system does, and stops. |

Two lists at the end collect these: **Needs a ruling** (every AS-BUILT) and **Needs reconciling**
(every DIVERGES). Nothing in this memorandum decides an AS-BUILT or a DIVERGES item.

---

# 1 · Currency

### 1.1 The functional and presentation currency is the Singapore Dollar. — **SETTLED**

Changed from US Dollar to Singapore Dollar on **2026-08-04**. Comparative figures presented before
that date were denominated in USD.

The base currency is held as **data, not as a constant in the code** — exactly one currency row is
flagged as base — so the currency cannot be changed in one place and missed in another.

> *Enforcement:* `currencies.is_base` (a single row carries `true`); migration
> `2026-08-04-fin0-sgd-base-and-fx-policy.sql`; `scripts/check-currency-literals.mjs` fails the build
> if a currency code is hard-coded in a comparison, branch, default or on-screen label; fixture 15.

### 1.2 A transaction in a foreign currency is translated at the rate for the transaction's own date. Where no rate exists, the system refuses to post and asks for one. — **SETTLED**

There is no fallback rate, no assumed parity and no substitution of today's date. This is deliberate:
a fabricated rate and a fabricated date produce a plausible figure with no error, which is materially
worse than a refusal.

> *Enforcement:* `fx_rate_for` / `fx_rate_asof` raise `FX_RATE_MISSING` naming the currency and date;
> eleven posting functions raise a named `*_DATE_REQUIRED` error rather than defaulting to the current
> date; fixture 09.

### 1.3 The side of the rate follows the purpose of the translation. — **SETTLED**

| Purpose | Rate side |
|---|---|
| Receipts from customers | `tt_buy` |
| Payments to suppliers | `tt_sell` |
| Market metal quotes converted to their USD basis | `mid` |
| Period-end revaluation of monetary balances | `mid` |

A market quote is a reference price rather than a dealt one, so a bank's spread has no place inside it.

> *Enforcement:* `record_payment` selects the side from the payment direction; `metal_quote_to_usd`;
> `revalue_foreign_balances`; `fx_rates.rate_type` admits exactly `mid` / `tt_buy` / `tt_sell`.

### 1.4 Where a bank actually converted, the rate used is the rate the bank dealt at. — **SETTLED**

Cross-currency settlement takes the **actual dealt rate** from the bank advice. The system refuses to
look up a board rate for these, because the money moved at a real price.

> *Enforcement:* `record_payment` requires the dealt rate on a cross-currency allocation; fixture 14, 18.

### 1.5 A rate may be carried back only across days on which no rate was published, and by no more than four calendar days. — **SETTLED**

A Saturday transaction properly uses Friday's rate, because the market did not publish on Saturday. **A
business day with no rate on file is refused.** The four-day cap is a backstop against a mis-maintained
holiday calendar. Where a carried-back rate is used, the screen shows the date the rate came from.

The published holiday calendar available to the system is Singapore's, while metal quotes follow London
and Chinese market days. The approximation is deliberate and its failure direction is a **refusal**,
never a silently wrong rate.

> *Enforcement:* `fx_rate_asof`, which returns the rate and the date it came from; `is_business_day`;
> fixture 09.

### 1.6 Exchange differences are split between realised and unrealised, and the two never share an account. — **SETTLED**

Realised differences post to 7100; unrealised revaluation differences post to 7110.

> *Enforcement:* `revalue_foreign_balances`; fixtures 02 and 06.

### 1.7 Deposits paid or received are carried at the weighted-average rate of the deposits outstanding. — **SETTLED**

When a deposit is applied against a payable, the deposit leg is translated at the weighted average
rate of the deposit pool rather than at the rate of any single deposit. Deposits are consumed
proportionally, so the average of the unapplied portion is arithmetically identical to the average of
the whole — which is why no consumption ledger is required. First-in-first-out was considered and
rejected on that basis.

> *Enforcement:* `apply_prepayment`; migration `2026-08-21-eqp1bi-the-release-learns-its-currency.sql`
> records the reasoning.

---

# 2 · Inventory and cost of sales

### 2.1 Stock is valued by specific identification at batch level (批次). — **SETTLED — 2026-08-23, ruled by Tim; reverses a decision in the founding documents**

**The policy.** Each inbound batch and each output batch carries its own cost. Cost of sales is the
cost of the specific batch sold. No average is struck across batches, and no cost flows from one batch
to another.

**The accounting reason.** Weighted-average costing is appropriate to inventories of items that are
**ordinarily interchangeable**. Battery scrap batches are not interchangeable: each carries its own
assay (化验) — its own metal content, moisture and impurity profile — and is bought and sold on the
strength of that assay. Two ten-tonne batches of black mass with different cobalt and nickel content
are different goods at different prices. Averaging cost across them severs the link between a lot's
cost and its metal content, and that link is the figure on which this business is priced and managed.
Accounting standards call for specific identification precisely where items are not ordinarily
interchangeable, and that is the case here.

**This reverses a recorded decision, and the reversal is deliberate.** Doc 1 put the question as an
explicit design decision — *"[DESIGN DECISION] Stock-valuation method? — Weighted average / FIFO /
Moving weighted average"* — and the tick was placed on **Moving weighted average**, annotated
*"Directly bears on the inventory value in financial statements; must align with accounting
standards."* Doc 3 then restated it as settled: *"Metal-content-based valuation. Stock valued on a
moving weighted-average basis"*, and *"Moving weighted-average valuation feeds finance (Phase 3)."*

On **2026-08-23** Tim ruled that **the system's treatment is the correct one** and that the founding
documents are the artefacts now out of date. The founding documents are not edited — they are the
record of what was planned and when — so the reversal is recorded in the divergence register instead.

> *Enforcement:* `record_output_sale` takes cost of sales from the sold output batch's own unit cost
> (`unit_cost_base` on the processing output leg); `output_batches` carries no average-cost column and
> no such column has ever existed; fixtures 18, 24 and 31.
> *Recorded at:* `docs/as-built-divergences.md` entry 6 — resolved in favour of the code.

### 2.2 A batch's cost is purchase price, plus inbound freight and handling, plus its allocated share of processing cost. — **SETTLED**

> *Enforcement:* `allocate_processing_costs`; `reprice_inbound_batch`; fixtures 18, 19, 24.

### 2.3 Inbound freight is capitalised into the batch it carried; the credit is recorded against the freight forwarder, not the material supplier. — **SETTLED**

The two halves matter equally. A posting that capitalises the cost but credits the material supplier
balances perfectly and puts the liability on the wrong counterparty.

> *Enforcement:* `record_freight_document`; fixture 51 asserts both the forwarder's payable and that
> the material supplier's payable is untouched.

### 2.4 Export freight is an expense of the period and never enters inventory, batch cost or gross margin. — **SETTLED**

Freight incurred to deliver goods to a customer is a cost of selling, not a cost of the goods.

> *Enforcement:* `record_export_freight_document` posts to 6300; fixture 101 asserts the *absence* of
> any capitalising entry, which is the arm that catches an implementation posting to 1200 as well.

### 2.5 The basis on which processing cost is allocated across output batches is chosen for each run and recorded on it. — **SETTLED**

Two bases exist: **weight** and **metal value**. The basis is recorded on the run, never inferred, and
the two give materially different answers — which is the point.

> *Enforcement:* `processing_runs.allocation_basis` constrained to `weight` / `metal_value`;
> fixture 34; fixture 18's metal-value arm separates the two numerically (62.50 against 27.50).

### 2.6 Re-allocating a run's costs posts the difference per output batch, routed by what has since happened to that batch. — **SETTLED**

The in-stock share adjusts inventory (1220), the sold share adjusts cost of sales (5000), and the
written-off share adjusts 5200.

> *Enforcement:* `allocate_processing_costs`; fixture 24.

### 2.7 Repricing an input batch flags every processing run that consumed it as stale; the money moves only when someone re-runs the allocation. — **SETTLED**

Staleness is surfaced rather than silently corrected, because a re-allocation is a posting and a
posting is a decision.

> *Enforcement:* `reprice_inbound_batch`; fixture 19, 24.

### 2.8 Where an output batch is sold before its cost is known, revenue is recognised at the sale and cost of sales is posted later, when the allocation runs. — **AS-BUILT**

The sale posts revenue immediately. If the output leg has no unit cost yet, **no cost of sales entry is
created at that time**; it is posted when `allocate_processing_costs` subsequently runs and catches up.
Between those two events the period carries revenue without its matching cost.

Nobody has ruled on this. It is stated here because it is a departure from matching that an auditor
would ask about, and because the length of the gap is not bounded by anything in the system.

> *Enforcement / evidence:* `record_output_sale` posts the cost-of-sales entry only where
> `unit_cost_base` is present; the catch-up path is in `allocate_processing_costs`.

### 2.9 A stocktake difference is posted as an inventory adjustment when the count is committed. — **AS-BUILT**

No materiality threshold, approval level or write-off policy is defined for count differences.

> *Enforcement / evidence:* `post_stocktake`; fixture 56.

---

# 3 · Revenue

### 3.1 Revenue on an order is recognised when the goods are shipped. — **SETTLED**

Amounts invoiced or received before shipment are carried as a contract liability (2500) and released
to revenue (4000) on shipment, together with the matching cost of sales. Receivables are created once
and only once along that chain.

> *Enforcement:* `ship_order`; `create_order_invoice`; fixture 68 asserts the contract liability
> reaches exactly zero on a non-unity exchange rate, and fixture 69 that a line remembers what it has
> already shipped.

### 3.2 A direct sale of an output batch recognises revenue at the point the sale is recorded. — **AS-BUILT**

The system carries two selling paths — the order-and-shipment cycle in 3.1, and a direct sale of an
output batch. The direct path recognises revenue when the sale is recorded, without a shipment event.
Whether the two paths should recognise revenue at the same moment has not been ruled on.

> *Enforcement / evidence:* `record_output_sale` posts Dr 1100 / Cr 4000 at the point of record.

### 3.3 A sale may be recorded without a customer, and the customer may be attached afterwards. — **SETTLED**

An ownerless sale is legitimate and is deliberately allowed; attaching the customer later is a logged,
one-way event that moves credit exposure at that point.

> *Enforcement:* `attribute_sale_customer`; fixtures 39 and 44.

### 3.4 A credit note reduces what is owed and nothing else. — **SETTLED**

> *Enforcement:* `create_credit_note`; fixture 71.

---

# 4 · Property, plant and equipment

### 4.1 Depreciation is straight-line, charged monthly from the date the asset is brought into service. — **SETTLED**

Not from the acquisition date. An asset bought in March and commissioned in July is not depreciated for
those four months.

**This is accounting depreciation. It is not a tax computation, and no tax depreciation is maintained
anywhere in the system.**

> *Enforcement:* `depreciate_fixed_assets`, idempotent by arithmetic (charge = target accumulated less
> accumulated to date) rather than by a flag; fixture 16.

### 4.2 Depreciation stops at cost less residual value. — **SETTLED**

> *Enforcement:* `depreciate_fixed_assets`; fixture 16.

### 4.3 An asset accumulates cost until it is commissioned; at commissioning depreciation begins, and the cost the charges so far were based on is frozen. — **SETTLED, QUALIFIED by 4.7 (2026-08-24), and BUILT (CAPEX-1, 2026-08-29)**

Freight, duty and installation on the same machine are additions to that asset, entered through the
same door as the machine itself, each translated at its own date's rate.

> **The word "frozen" is narrower than it used to read, and as of CAPEX-1 the code agrees with the
> narrower reading.** Until 2026-08-24 it meant *no cost may ever be added after commissioning*, and
> `record_expense` enforced exactly that with a blanket refusal (`ASSET_ALREADY_IN_SERVICE`).
> **4.7 ruled that subsequent expenditure IS permitted**, spread prospectively, and **CAPEX-1 built
> it (2026-08-29)**. So 4.3 means, and now only means: **the cost that the depreciation charged so
> far was based on is frozen** — history is never rewritten — not that the asset can never take
> another dollar.
>
> **The blanket refusal is gone; a narrower one took its place.** An in-service asset may take cost
> only through a maintenance record flagged as capitalised and carrying a reason; without one,
> `record_expense` refuses by name (`ASSET_IN_SERVICE_NEEDS_MAINTENANCE`) and says where to go.
> The judgement FIN-22 protected is still handed to a human — it just has somewhere to be written
> down now, instead of only somewhere to be turned away.

> *Enforcement:* `record_expense`'s capital branch requires an asset reference; fixtures 77, 105, 107.

### 4.4 Fixed assets are non-monetary and are never revalued. — **SETTLED**

They are invisible to period-end foreign currency revaluation, and there is no revaluation model.

> *Enforcement:* `fixed_assets` carries no revaluation column; `revalue_foreign_balances` covers
> monetary balances only; fixture 16.

### 4.5 On disposal, cost and accumulated depreciation are cleared and the gain or loss is recognised. — **SETTLED**

> *Enforcement:* `dispose_fixed_asset` clears 1500/1510 exactly; fixture 16.

### 4.6 Useful life is set per asset when the asset is created. — **AS-BUILT**

There is no table of standard useful lives by asset category, and no rule about what life a given class
of plant should carry. Each asset's life is whatever was typed on it.

> *Enforcement / evidence:* `fixed_assets.useful_life_months`.

### 4.7 Subsequent expenditure on an asset already in service is spread, together with the remaining un-depreciated cost, over the remaining useful life. Depreciation already posted is not touched. — **SETTLED — 2026-08-24, ruled by Tim**

**The rule.** When cost is capitalised onto an asset that is already in service, the addition and the
**remaining un-depreciated cost** are spread **together, in the same proportion, over the remaining
useful life**. Depreciation already posted is **neither reversed nor recomputed**.

**The reasoning that decides the shape:** an addition to a machine already running is a **new event**,
not the correction of an error. Nothing about the depreciation already charged was wrong when it was
charged — it was right for the cost the asset then had. A rule that recomputed history would be
asserting the opposite.

> **What this rules out, and why that is the point.** The existing monthly routine computes a
> **cumulative** target from the current cost base:
>
> ```
> target = LEAST(cost_base − residual, (cost_base − residual) / useful_life_months × months_in_service)
> delta  = target − everything ever posted
> ```
>
> Raise `cost_base` mid-life under that arithmetic and the target rises for **every month already
> elapsed**, so the whole catch-up lands in the current period — measured and recorded in
> `docs/phase4-survey.md` §6. **4.7 forbids exactly that back-charge.** The implementing cut must
> therefore stop re-deriving past months from a raised cost base and anchor the computation at the
> addition instead: from that month on, charge
> `(cost + addition − residual − accumulated) / remaining_months`.
> **This is a specification, not a question** — the cut is queued, not built here.

> **The asymmetry this inherits, stated so nobody reads the routine as symmetric.** The same routine
> floors a negative delta at zero (`IF v_delta < 0 THEN v_delta := 0`), so a **downward** cost
> revision is silently ignored by the monthly run and left to a manual correcting entry. **4.7
> imitates that same side:** the monthly routine never reaches backwards, in either direction.
> An upward change goes forward from now; a downward change is still a correction and still belongs
> in a manual entry. The two halves now agree, where before only one of them had been ruled on.

> *Enforcement:* **BUILT — CAPEX-1, 2026-08-29.** `fixed_asset_depreciation_anchors` +
> `preview_depreciate_fixed_assets`'s anchored branch + `record_expense`'s narrowed refusal;
> fixtures 77 and 144.
>
> **How the back-charge is prevented, in one sentence, because "a rule says not to" is not a
> mechanism:** the anchor stores the pre-anchor cumulative target as a **scalar**
> (`pre_anchor_target_base`), so the months before the addition are no longer *derived* from
> `cost_base` at all — **a raised cost base has nothing to multiply against them.** The old
> arithmetic could not have been made safe by a check; it had to stop being a multiplication.
>
> **The retirement that came with it** — the frozen-cost copy: **six** message keys, not the five
> `docs/phase4-survey.md` §6b counted (and two of those five were filed under the wrong namespace),
> plus `docs/manual-walk-list.md` §9's step that checks for them, plus the table comments on
> `fixed_asset_cost_entries` and `equipment_maintenance`, the asset-picker comments on the expense
> and purchase-order forms, `docs/fixed-asset-procedures.md` §四, and `docs/known-issues.md`'s entry
> for the unfillable `capitalised_expense_id`. All in this commit.
>
> ★ **What CAPEX-1 did NOT do, and it changes what an operator gets** ★ — **the useful life is not
> revised.** An overhaul is spread over the **OLD remaining months**, because that is what 4.7's
> formula says and 4.7 is the ruled policy. So a machine everyone agrees will now run five years
> longer **still finishes depreciating on its old schedule**, with a larger charge per month rather
> than the same charge over a longer life. That is a known, named limitation, not an oversight; the
> queued item and its trigger are in `docs/forward-queue.md` (**trigger: the first capitalisation
> whose justification is a life extension**). The right end state is a life revision that lands its
> own anchor with a new `remaining_months` — the anchor table was built to take one, which is why it
> allows `expense_id` and `maintenance_id` to be NULL.
>
> **Reversal after commissioning stays refused, for its OWN reason.** `reverse_expense`'s
> `ASSET_IN_SERVICE_COST_LOCKED` is untouched. **The two are not symmetric and must not be
> collapsed:** an addition is a new event and goes forward; a reversal asserts the original entry
> should never have existed, which is retrospective, and 4.7 authorises nothing retrospective. The
> same asymmetry the negative-delta floor already expresses.

---

# 5 · Purchases, pricing and commitments

### 5.1 Pricing terms are copied onto the record that commits them, and settlement is computed from the copy. — **SETTLED**

A pricing formula is a template that can be edited. A purchase order line's reference to it is a
promise about how that deal will settle. The terms are therefore **copied at commitment**; a later edit
to the formula does not reach back into a deal already struck, and a deal struck after the edit uses
the new terms. A commitment with no copy is refused by name rather than falling back to the live
formula.

> *Enforcement:* `commit_pricing_terms`; settlement reads the committed copy; fixtures 21 and 27,
> which compute the live-formula figure alongside and assert the two differ, so the test cannot pass by
> both answers agreeing.

### 5.2 A change to a pricing formula is recorded with its before and after, including the metals sub-table. — **SETTLED**

Removing a metal from a formula is expressed as deleting a row, which is the most drastic edit
available; a header-only history would be silent about exactly that.

> *Enforcement:* `pricing_formula_history`; fixture 27.

### 5.3 A metal quote is priced against a declared index, and an index whose currency has not been declared is refused. — **SETTLED**

The system does not assume a quote is in US dollars because most are.

> *Enforcement:* `calculate_metal_price` raises `INDEX_CURRENCY_NOT_STATED`; `metal_price_indices`.

### 5.4 A payment-term template carries its own currency, and it cannot be applied to an order in a different currency. — **SETTLED**

A payment term is a negotiated commitment, not a computed quantity, so it is refused rather than
converted. Percentage-only templates need no currency and are not required to invent one.

> *Enforcement:* `apply_payment_term_template`; guard triggers on both parent and child; fixture 22.

### 5.5 Every assay must state the weight basis it was measured on — as-received (湿基) or dry (干基). — **SETTLED**

The two are different numbers for the same material and cannot be reconstructed after the fact. A blank
basis means *nobody stated it* and is never defaulted.

> *Enforcement:* `guard_assay_basis_stated`; `assay_results.weight_basis`.

### 5.6 There is no company-wide rule fixing the weight basis on which purchases settle, or the basis on which sales settle. — **AS-BUILT**

The basis is recorded per assay (5.5), but **no pricing or settlement function branches on it** — only
the guard that requires it to be stated and the function that records it refer to the column at all.
In practice the basis is whatever each contract says and each assay records; the system neither
enforces nor reports a house convention, and a purchase settled on a dry basis and a sale settled on an
as-received basis would both post without comment.

This is the answer to "what is the purchase weight basis and what is the sale weight basis": **the
system records the question and does not answer it.**

> *Enforcement / evidence:* only `guard_assay_basis_stated` and `record_assay_result` reference
> `weight_basis`; no pricing path does.

---

# 6 · Period control and corrections

### 6.1 A closed accounting period cannot be posted into, and a closed financial year cannot be posted into. — **SETTLED**

The two locks are independent. A month may be reopened by a logged action, and reopening a month
**does not** unlock a year that has been closed. Where a date offends both, the year is reported,
because the year is the stronger fact.

**There is exactly one exception:** the year-end closing entry and its reversal, which must by their
nature be written into the year they close. The exception requires both that the entry declares itself
a year-close entry and that the year-close process is executing; neither alone opens it.

> *Enforcement:* `assert_posting_allowed`, raising `PERIOD_LOCKED` and `YEAR_CLOSED`; enforced both in
> the posting function and, since 2026-08-23, by triggers on the journal tables themselves, so a direct
> write cannot bypass it; fixture 122.

### 6.2 Corrections are made by reversal. A posted entry is never edited and never deleted. — **SETTLED**

> *Enforcement:* triggers reject any update or delete of a journal entry or journal line;
> `reverse_journal_entry`, `reverse_payment`, `reverse_expense`, `reverse_freight_document`,
> `reverse_bank_transfer`; fixture 32.

### 6.3 A reversal of a processing run takes the original run's business date, not the date of the correction. — **SETTLED**

A rollback corrects a mis-recording; it is not a physical event. Dating it to the original day makes
the error and its correction cancel on the same day, rather than showing stock absent for the days in
between. A write-off, by contrast, **is** a physical event and takes its own date.

> *Enforcement:* `inventory_movements.business_date`; fixture 25; FIN-32.

### 6.4 Closing the year moves profit or loss to retained earnings, derived from the account's type rather than from a range of account codes. — **SETTLED**

Reopening a closed year reverses the closing entry, records a reason, and restores the trial balance.

> *Enforcement:* `close_financial_year` / `reopen_financial_year`; fixture 17.

### 6.5 The date from which the books are complete is declared, not inferred. — **SETTLED**

Entitlements computed per period — leave accrual, medical limits — are bounded by that date, so a
rebuilt database does not grant a full year's entitlement for a year it did not cover.

> *Enforcement:* `finance_settings.system_start_date`; fixtures 11, 12, 24.

---

### 6.6 A monthly management pack is stored only for a month that is already closed. — **SETTLED — 2026-08-28, ruled by Tim (GLEXPORT-1)**

An open month can be previewed on screen and exported, but it is **not** stored. The reason is that
freezing, in this system, has always followed *something leaving the building* rather than someone
pressing "compute": a GST return freezes when it is **filed**, a customer statement when it is
**issued**, a bank reconciliation records an **event that happened**. A pack for a month that can
still be posted into has committed to nothing. Storing one would create a permanent, immutable
record of a figure everyone already knew was provisional.

So a stored pack means exactly one thing, and the system guarantees it rather than labelling it: the
month was closed when it was produced. `management_packs.locked_before_at_production` records the
lock as it stood at that moment, and a table CHECK requires it to be strictly later than the period
end. Re-producing a pack for the same month is a **new document** — the previous one is superseded,
with a reason — never an edit.

> *Enforcement:* `freeze_management_pack` (`PACK_MONTH_NOT_LOCKED`, `PACK_SUPERSEDE_REASON_REQUIRED`);
> `management_packs_month_was_locked`; `idx_management_packs_live_month`;
> `guard_management_pack_mutation` (`PACK_IMMUTABLE`); fixture 143 arms A, B and I.

### 6.7 The pack reconciles each control account to its subsidiary ledger, and reports the part of the difference nobody has accounted for. — **SETTLED — 2026-08-28 (GLEXPORT-1)**

Receivables (1100) and payables (2000) are each compared against the documents behind them
(`ar_aging_asof` / `ap_aging_asof`). **These are the only two figures in the pack whose sides are
independently derived** — one from the general ledger, the other from the documents. Profit and loss
against the balance sheet is *not* such a check: both read the same derivation with two switches, and
this memorandum's own §11 discipline plus the engineering record already mark the balance sheet's
`balanced` flag as structurally guaranteed.

A difference is normal and is not an error: FX revaluation moves the ledger and not the documents,
money received on account clears the ledger and no document, and documents raised before the system
started may never have been posted at all. Three named components account for those. **What is left
over is reported as unexplained**, and that figure is a finding rather than a decoration — the most
common cause is a manual journal posted straight to a control account.

> **Measured at 2026-08-28**, both sides reconcile with **nothing unexplained**: receivables differ by
> 14,440.88 (origination 20,247.13 + settlement 250.00 − revaluation 6,056.25) and payables by
> 57,587.58 (origination 62,175.68 + settlement 0.96 − revaluation 4,589.06). The largest single
> component is pre-cutover test data — one sale and five inbound batches that carry a value in the
> sub-ledger and no surviving posting in the ledger.

> *Enforcement:* `gl_control_reconciliation`; the pack prints both figures and the difference rather
> than asserting agreement (the disposition `reconcile_statement` established); fixture 143 arm D
> injects a manual journal into the control account and asserts the unexplained figure moves.

# 7 · Payroll

### 7.1 Payroll is prepared by an external provider. The system records and posts it; it does not compute pay or statutory contributions. — **SETTLED**

> *Enforcement:* `post_payroll_period`; `db/tables/payroll_periods.sql`.

### 7.2 Central Provident Fund contributions for a month are remitted in the following month, and the document carries both dates. — **SETTLED**

The period the contribution settles and the date it is paid are different months by design. **CPF is
not exempt from the period lock** and never has been; the payment date is subject to it like any other.

> *Enforcement:* `pay_payroll_cpf` posts through the ordinary posting path;
> `payroll_periods.cpf_paid_at`; fixture 122 asserts that no source type other than the year-close
> exception escapes the lock.

### 7.3 A payroll period that has already remitted CPF or deductions cannot be unposted until that remittance is reversed. — **SETTLED**

> *Enforcement:* `unpost_payroll_period` raises `PAYROLL_CPF_PAID`.

---

### 7.4 An employee expense claim recognises both the cost and the debt to the employee at the moment it is approved, dated the day the money was spent. — **SETTLED — 2026-08-28, ruled by Tim (CLAIM-1)**

Approval is the moment the company accepts the obligation, so it is the moment both sides are
recognised — there is no state in which a claim is approved and the books show nothing. The
expense is booked as **unpaid**, which makes it a payable to that named employee and puts it in
`ap_open_items` under their own name; the cash moves later through the ordinary payment path.

**The posting date is the day the money was spent**, because that is the period the cost belongs
to. Where that period is closed the approval **refuses by name** (`PERIOD_LOCKED`) and the
approver must supply a posting date deliberately. There is no automatic fall-back to the open
month: that is the shape FIN-10 removed everywhere else, where filling the date in correctly
raises an error while leaving it blank glides into the current period.

**Two consequences worth stating, because they are decisions rather than omissions:**

* **There is no petty cash float, by decision** (Tim, 2026-08-27). Expense claims and petty cash
  are two solutions to one problem and only one is built: everything is reimbursed after the
  fact, against what was actually spent. Nothing is advanced, no float balance is reconciled, and
  nothing has to be recovered when someone leaves. At six people, after-the-fact reimbursement is
  sufficient — and it carries an approval step by construction, where a float hands money over
  before anyone has seen a receipt.
* **The claimant cannot approve their own claim** (`EXPENSE_CLAIM_SELF_APPROVAL`, via
  `assert_segregated`). Note that `guard_payment_sod` deliberately exempts payments to employees,
  reasoning that HR creates the record and finance pays it — two modules, not one person end to
  end. CLAIM-1 opens a path where **the employee originates it themselves**, so that reasoning no
  longer covers the whole question and the control moved upstream to the decision. The payment-side
  exemption is unchanged and still correct for the HR-originated path.

### 7.5 A payroll period cannot be posted until somebody has stated that the month's attendance sheet is complete. — **SETTLED — 2026-08-28 (ATTEND-1)**

Because 7.1 holds — the system computes no pay — attendance is **not an input to a calculation**.
It is the record of *what the company told the provider*: overtime hours by when they fell, unpaid
leave, and who was on the books for part of the month. Before ATTEND-1 those numbers left no
trace at all, so no one could reconstruct why a payslip said what it said.

The sheet's status is **an assertion by a person, not an inference by the system**. The system
cannot know whether a month's attendance is complete; it can only know whether anybody has said so
— the same shape as `finance_settings.system_start_date` being a *declaration* rather than a
*derivation*. Posting is the moment the company commits to the provider's numbers, so that is
where the basis is required to exist. It is a refusal and not a warning: posting a month whose
absence is unknown silently treats it as full attendance, and a toothless warning on a
once-a-month closing action gets clicked past — this repository has already paid for teaching
people to ignore alerts.

**Two boundaries worth stating, because they are decisions rather than omissions:**

* **Overtime is recorded by *when it fell* (normal day / rest day / public holiday) and carries no
  multiplier column.** When it fell is a fact; what it multiplies by is an open question under the
  Employment Act, and no handbook or rate schedule exists in any document this repository can read.
  **No covered shopfloor worker exists yet:** measured 2026-08-28, `employees` holds 6 undeleted
  rows but only **2** carry a real `EMP-` code — 2/2 `office`, 2/2 `full_time`, 0 `shopfloor`;
  the other 4 are `ZZ-*` scratch rows the smoke run leaves behind. (A first draft of this section
  said "all six people on the books" — it counted the scratch rows as colleagues. The headcount
  matters here because *who* falls under Part IV is exactly the open question.) Recording the fact without inventing the
  rate leaves the multiplier to be settled once, by Tim, rather than guessed here — **that question
  is still open and is recorded, not answered.**
* **Unpaid-leave days are derived, never re-entered** — from approved `unpaid` leave requests via
  `calculate_leave_days`, which already understands working days and public holidays. At the moment
  the sheet is completed the derived values are **frozen onto the line**, so that a leave request
  cancelled afterwards cannot change what the sheet says we reported.

Once that month's payroll is posted, the sheet can no longer be reopened
(`ATTENDANCE_PERIOD_LOCKED_BY_PAYROLL`): a posted payslip cannot have its basis changed underneath
it. The way through is to unpost first, which carries its own guard under 7.3.

> *Enforcement:* `post_payroll_period` (`PAYROLL_ATTENDANCE_NOT_COMPLETE`);
> `complete_attendance_period` (`ATTENDANCE_PERIOD_INCOMPLETE` — a sheet that tolerates blanks is a
> checkbox, not a statement); `reopen_attendance_period`; `attendance_lines.recorded_at` is what
> separates *recorded as zero* from *nobody looked*; fixture 141 (twelve arms, 14/14 fault-injection).

# 8 · Withholding tax on payments to non-residents

**This is not GST, and the difference is the whole of this section.** GST is tax the company charges
and reclaims on its own account. Withholding tax is tax the company **holds back from somebody
else's money**: where the company owes a non-resident 10,000, it pays out 8,500 and remits 1,500 to
IRAS on that payee's behalf. The 1,500 never enters the company's profit or loss — it is the payee's
money, in the company's hands, on its way to the tax authority.

### 8.1 Whether a payment attracts withholding tax is a property of the OBLIGATION — not of the payee, and not of the cash payment. — **SETTLED — 2026-08-28, ruled by Tim (WHT-1)**

Three facts have to be true at once before any tax is withheld, and they live in three places:

* the **residence of the payee** — a property of the supplier, evidenced by a certificate of residence;
* the **nature of the payment** — interest, royalty, management fee, technical service fee — which in
  this system is a property of the document that records what was bought;
* the **act of withholding** — which happens at the payment, the only point at which the money splits.

The obligation is the level at which the first two are simultaneously known **and the amount is
known**, and it is the level IRAS's own tax point sits at: the earlier of the date the payment is due
and payable and the date it is actually paid. So the decision is recorded on the obligation, the
payee's residence is **copied onto it and frozen** at that moment, and the payment executes what the
obligation already decided and can never re-decide it.

**The two rejected levels are recorded with their reasons, because a later reader should meet the
reasoning rather than only the choice:**

* **Per payment is structurally wrong.** One payment can settle a consultancy invoice and a goods
  invoice together; a single flag on the payment can only give one answer for both.
* **Per payee is wrong in the other direction.** The same non-resident can sell goods in January
  (no withholding) and consultancy in February (withholding). An answer attached to the payee is
  wrong in one of those two months.

> *Enforcement:* `expenses.wht_payee_residence` / `wht_nature` / `wht_rate_pct` / `wht_amount_ccy`
> under one `expenses_wht_shape` CHECK; `record_expense`; `record_payment` reads the frozen rate and
> never re-resolves it; fixture 142 arm C, which changes the supplier's residence after the document
> is recorded and asserts the withholding still happens.

### 8.2 The payable is settled in full; the bank moves by the net; the difference is a liability to IRAS. — **SETTLED — 2026-08-28 (WHT-1)**

Withholding is **not a discount**. The supplier's account is discharged by the gross amount, so the
payable closes to exactly zero; the bank is credited with the net; the difference is credited to
**2150 Withholding Tax Payable**. That account is a liability, never a cost — treating it as an
expense would overstate cost and understate liabilities at the same time.

> *Enforcement:* `record_payment` (the 2150 leg, and `ALLOC_EXCEEDS_PAYMENT` now compares the amount
> that must actually leave the bank rather than the amount allocated); account 2150 is `is_system`;
> fixture 142 arm A asserts all three figures and first asserts they are pairwise different, so an
> implementation that pays gross and one that withholds nothing both fail.

### 8.3 A withholding rate is a statutory fact with a date. Where none is on file for that date, the system refuses. — **SETTLED — 2026-08-28 (WHT-1)**

Rates hang on effective-dated rows, exactly as GST rates do, and `wht_rate_for` refuses by name
rather than reaching for the nearest one. A treaty may **reduce** a rate but never increase it, and
claiming a reduced rate requires a certificate of residence to be recorded — without one IRAS
charges the statutory rate whatever the treaty says, and the shortfall becomes the company's own
cost.

> **★ The content of the rate table has NOT been verified by an accountant. ★** The shape of it is
> an engineering decision and it is finished. The six figures in it are not: they were seeded from
> the statutory references recorded against each row, and each carries a **baseline** start date
> rather than a researched commencement date. **Every row must be confirmed before the first real
> payment to a non-resident.** Until then the machine will compute, report and reconcile perfectly
> while being wrong, which is exactly the risk worth naming.

> *Enforcement:* `wht_rates`, `wht_rate_for` (`WHT_RATE_NOT_FOUND`);
> `WHT_TREATY_RATE_ABOVE_STATUTORY` and `WHT_TREATY_REF_REQUIRED` in `record_expense`;
> fixture 142 arm B straddles a rate boundary, so a nearest-match implementation fails it.

### 8.4 Tax withheld in a month is remitted to IRAS by the fifteenth of the following month, and the system reports the deadline rather than merely recording the payment. — **SETTLED — 2026-08-28 (WHT-1)**

What is owed is **derived** from the withholdings in the ledger; what has been remitted is
**recorded**. There is no "open the period" step, so a month cannot be missed because nobody opened
it. The dashboard raises `wht_due` from seven days before the deadline and keeps raising it after
it passes, and **the only thing that clears it is the money actually moving** — the alert reads the
outstanding balance, which falls only when `remit_wht` posts a real entry debiting 2150. There is no
dismiss button. This is the same disposition as the CPF alert, and the two deadlines are
deliberately **not** unified: CPF is the fourteenth, withholding tax the fifteenth, each from its own
statute.

> *Enforcement:* `wht_liability_by_month`; `wht_remittances` (append-only — a top-up is a second
> remittance, not an edit); `remit_wht`; `operations_now`'s `wht_due` arm; fixture 142 arm G, which
> remits, asserts the balance clears, then reverses the remittance entry and asserts it comes back.

### 8.5 Only supplier expense documents are in scope. Freight and prepayments to non-residents are refused by name, and two categories of payee are out of reach. — **AS-BUILT**

Goods purchases never attract withholding tax, so inbound batches are excluded structurally.
Two other paths **refuse by name** rather than passing silently, because each is waiting on a
judgement nobody has made:

* **Freight** — whether a payment to a non-resident carrier is exempt turns on whether the payee is a
  shipping or air line (exempt) or a forwarder providing agency services. The system cannot tell
  those apart from the document.
* **Prepayments** — a deposit to a non-resident consultant is itself a withholding event, and it
  happens before any expense document exists. This cut hangs the decision on the obligation, and on
  that path there is no obligation yet to hang it on.

**Two real categories of withholding are not modelled at all**, and they are named here rather than
left to be discovered: **non-resident directors' remuneration** and **non-resident professionals**.
Both are payments to *people*, and the payee in this design is a supplier — `employees` carries no
tax residence and payroll does not pass through this path at all. Seeding those natures into the
dictionary would put a category into the system that the system structurally cannot reach.

**Finally, one gap is deliberate and was measured before it was accepted.** A supplier whose tax
residence has never been stated is **not** asked the withholding question, and a payment to them
withholds nothing — including one that should have. Requiring the answer would have rewritten
sixteen fixtures for a risk with zero live instances (measured 2026-08-28: no service vendors and no
non-resident payees exist). The gap is therefore **counted on screen** — `/finance/wht` prints how
many suppliers have no residence on file — rather than hidden.

> *Enforcement:* `WHT_FREIGHT_NOT_SUPPORTED` / `WHT_PREPAYMENT_NOT_SUPPORTED` /
> `WHT_UNALLOCATED_PAYMENT_UNSUPPORTED` in `record_payment`;
> `WHT_ON_PAID_EXPENSE_UNSUPPORTED` in `record_expense`; `docs/known-issues.md`.

### 8.6 An expense that attracts withholding cannot be recorded as already paid. — **SETTLED — 2026-08-28, ruled by Tim (WHT-1)**

`record_expense` can post an expense straight against the bank, and that is its **default**. That
path creates no payable and no payment record, so it never reaches the one piece of code that knows
how to split a payment. Rather than teach it to split as well — two implementations of the same
arithmetic, which this project has paid for four times — the combination is refused by name, and the
refusal **states the route**: record it unpaid, then pay it. The cost is one extra step on a rare
transaction, bought deliberately.

> *Enforcement:* `record_expense` (`WHT_ON_PAID_EXPENSE_UNSUPPORTED`); fixture 142 arm E3.

---

# 9 · What is deliberately not here

An auditor discovering these by surprise is worse served than one who reads them.

### 9.1 The company is not registered for GST, and while it is unregistered nothing about tax accounting is reachable. — **REWRITTEN 2026-08-25 (GST-2)**

GST registration is recorded as **not registered**. The two GST accounts exist in the chart of accounts
and **have never carried a single posting** (nil movement, nil balance).

**What changed on 2026-08-25.** The sentence this section used to open with — *"there is no tax
accounting of any kind"* — is no longer true of the software, only of the company. GST-1 built the
machinery (tax codes, a statutory rate history, the F5, filing periods) and GST-2 wired the documents
into it: an invoice resolves its code and rate at issue, freezes both on the line, and posts the tax;
an expense does the same on the input side; the F5's output side derives from those invoices.

**The unregistered behaviour is unchanged, and that is not an assertion.** While
`gst_registered = false`, a row carrying a tax code **cannot be written at all** — refused on the
journal (`post_journal_entry`) and on each of the three document tables (`invoice_lines`, `expenses`,
`credit_note_lines`). So "no tax has been recorded" is a thing the database makes impossible, not a
thing that happens to be true.

**Tax depreciation is still not maintained (4.1), and there is still no deferred tax.**

**Who may turn it on, and what stops it (GST-3, 2026-08-26).** Until GST-3 the switch had **no
control anywhere in the application** — it could only be flipped by direct SQL, which meant the whole
of GST-1 and GST-2 was unreachable by a person. It now has a panel on `/finance/settings`, governed by
the same permission that governs the period lock (`module.finance.edit`), with a guard on the table in
both directions:

* **On** requires a GST registration number to be on file. IRAS requires it on a tax invoice, and the
  invoice PDF prints that line only when the number exists — so without this a registered company
  could send a customer an invoice charging 9% with no registration number on it.
* **Off** is refused while coded expenses exist (they would become impossible to reverse) or while
  live taxed invoices exist (the return would report supplies for a quarter the company says it was
  not registered for). Each refusal names the documents in the way.

> *Evidence:* `finance_settings.gst_registered = false`; accounts 1400 and 2100 carry zero journal
> lines; `guard_document_tax_code` on the three document tables; `guard_gst_switch` on
> `finance_settings`; fixture 129 arm F1 and fixture 130.

### 9.1a The seven invoices raised to date carry no tax code, and they are not backfilled. — **SETTLED — 2026-08-25**

All seven carry a nil tax rate and nil tax **because the company was not registered when they were
raised**. That is not a gap in the data; it is the data telling the truth. Backfilling a tax code onto
them would assert that a supply was standard-rated at a time when the company could not charge GST at
all — it would be manufacturing a tax point that never existed, and it would put figures into a return
that no customer was ever invoiced for.

They are therefore left exactly as they are, and this entry exists so that a later reader does not
read the absence as an oversight and "fix" it.

> *Enforcement:* nothing enforces this — it is a decision, and the only thing protecting it is this
> paragraph. The structural guard above prevents a tax code being written **while unregistered**; once
> the switch is on, nothing would stop someone updating those seven rows by hand. That is the correct
> shape: a rule about history cannot be a runtime check.

### 9.2 There is no multi-entity structure and no consolidation. — **DIVERGES**

> **Doc 3, Phase 3 definition of done:** *"the three statements and a multi-entity consolidation can be
> produced"*; **Doc 3, Phase 3:** finance *"performs multi-entity consolidation"*; **Doc 1:** *"Chart of
> accounts (two sets for SG/EU?)"*.

**As built:** there is one chart of accounts, one base currency and one set of books. No business table
is partitioned by entity. Consolidation is not a report that has yet to be written — it is a schema
change that would have to be made first.

This entry states both sides and stops.

> *Recorded at:* `docs/as-built-divergences.md` entry 1.

### 9.3 Fixed assets are never revalued. See 4.4.

### 9.4 Metal recovery rate is a management estimate, not an auditable measure.

The mechanism to record an output assay exists, and every metal content figure carries its source
(measured or entered by hand). What does **not** exist is a rule about **which metals must be measured
for an output assay to be considered complete** — that question is blank in the founding documents and
has not been decided. Until it is, a recovery percentage is a useful estimate whose denominator and
numerator may rest on different kinds of evidence, and it should not be presented to a third party as
a measured KPI.

The recovery view reports the provenance of each side separately, and a conservation warning is a
prompt, never a block — a measurement that contradicts expectation is evidence, and refusing to record
it would suppress exactly the evidence one wants.

> *Evidence:* `processing_metal_recovery` with per-side `content_source`;
> `docs/as-built-divergences.md`, the recovery-rate section.

### 9.5 There is no standard costing and no variance analysis.

Doc 3 lists *"Standard cost vs actual"* within Phase 3. Nothing of the kind is built: there is no
standard cost anywhere in the schema. All costs are actual. This is a planned feature not yet built
rather than a contradicted decision, so it is listed here as an absence rather than as a divergence.

### 9.6 Approval chains are largely not implemented.

Approval exists for purchase orders and for a small number of specific actions. The general
multi-level approval chain described in the founding documents is deferred by plan, not dropped.

> *Recorded at:* `docs/as-built-divergences.md` entry 3.

---

# 10 · Needs a ruling

**The six AS-BUILT statements above, collected — plus two open questions that sit inside policies
which are otherwise settled (1.5 and 8.3). These are not policies. They are what the software does in the
absence of one, and each is a question for Tim and, where marked, for the auditor.**

| # | Question |
|---|---|
| 2.8 | Where an output batch is sold before its cost is known, revenue is recognised now and cost of sales later. Is that acceptable, and should the gap be bounded or disclosed? |
| 2.9 | Stocktake differences post without a materiality threshold, approval level or write-off policy. What should each be? |
| 3.2 | The direct-sale path recognises revenue at the point of record; the order path recognises on shipment. Should both recognise at the same event? |
| 4.6 | Useful lives are set per asset with no standard lives by category. What are the standard lives, by class? |
| 5.6 | No house convention fixes the weight basis for purchase settlement or for sale settlement. Should there be one, and what is it? |
| 8.5 | Withholding is scoped to supplier expense documents. Freight to a non-resident carrier and prepayments to a non-resident both refuse by name, each waiting on a judgement: is the freight payee a shipping/air line (exempt) or a forwarder providing agency services? And a deposit to a non-resident consultant is a withholding event before any invoice exists — how should it be recorded? |
| 8.5b | Non-resident **directors' remuneration** and **non-resident professionals** are real withholding categories that this system cannot reach, because their payee is a person and the design's payee is a supplier. Should they be brought in, and through which document? |
| 8.5c | A supplier whose tax residence has never been stated is not asked the withholding question, so a payment to them withholds nothing. Accepted deliberately and counted on screen. Should it become a refusal once real non-resident vendors exist? |
| 8.3 | *(Open question, and the most consequential one in this table.)* **The six statutory withholding rates have not been confirmed by an accountant.** They were seeded from the statutory references recorded against each row, with baseline rather than researched start dates. Confirm every row before the first real payment to a non-resident — until then the machine computes and reconciles perfectly while possibly being wrong. |
| 1.5 | *(Open question, recorded but never put to anyone.)* Should a **reference** rate be allowed to reach back further than a **settlement** rate? They carry different risks: a stale settlement rate mis-states money that actually moved; a stale reference rate mis-states a quote that was already an approximation. |

# 11 · Needs reconciling

**Where a founding document records a decision and the system does something else, and the difference
is still open.**

| # | Difference |
|---|---|
| 9.2 | Doc 3 makes multi-entity consolidation part of Phase 3's definition of done. There is one chart of accounts, one base currency, one set of books, and no entity partition on any business table. See register entry 1. |

**Resolved, and recorded so it is not re-opened:** stock valuation (2.1). Doc 1 balloted *Moving
weighted average* and Doc 3 restated it; Tim ruled on 2026-08-23 that batch-level specific
identification is correct and the founding documents are out of date. See register entry 6.

---

# 12 · Maintaining this memorandum

> **This document is updated in the same commit that changes a policy it states.**

That rule is the whole of its reliability. A policy memorandum that outlives its subject is the most
repeated failure in this project's history, and this one is aimed at a reader **outside** the company
who has no way to check whether it is current.

Two practical consequences:

1. **Every statement above names an enforcement point.** If you are changing one of those functions,
   constraints or fixtures, search this file for its name before you commit. If the change alters what
   the company's policy *is* — not merely how it is implemented — this file changes in the same commit.
2. **A new policy decision adds a statement here**, with its mark, its reason and its enforcement
   point. A decision that resolves an AS-BUILT item moves it out of §9 and into the body as SETTLED,
   with the date and who ruled.

Divergences from the founding design documents are recorded in `docs/as-built-divergences.md`. The
founding documents themselves are never edited: they are the record of what was planned and when, and
rewriting them would destroy the only account of the plan.
