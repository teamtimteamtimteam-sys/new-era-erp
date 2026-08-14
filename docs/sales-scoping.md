# Sales cycle — scoping (SAL-1)

**Status: REPORT ONLY. Nothing is built — question 1 is an accounting decision with an auditor on
the other end, and it gates everything that touches the ledger.** Decisions marked **TIM'S** are
his and are not picked here.

**What the documents settle** (not re-derived): output is priced on LME or SMM; sales is both spot
and long-contract "according to contract"; sales is product-focused; the named pain is *"different
pricing models should be integrated into this module"*; and Tim moved **invoicing before
shipment** on the printed flow — inquiry/quote → sales order → approval → invoicing → shipment →
collection.

---

## 1 · When is revenue recognised? — **TIM'S (with his auditor), and it gates the flow**

**What the code does today:** there is no separate shipment step. `record_output_sale` is one
atomic act at `sale_date`: the inventory movement (goods out), the `sales_records` row, **JE#1 —
Dr 1100 AR / Cr 4000 revenue** in the document currency, and **JE#2 — Dr 5000 COGS / Cr 1220** in
base when the batch has a unit cost. So today **revenue recognition = shipment = the sale event,
one instant**. The invoice is a *derived document created afterwards* — it groups already-posted
`sales_records` into a bill; AR exists before and without it, and `invoice_status` derives its
settled amount from allocations against the sales records, not against the invoice.

**The four live sales records:**

| date | batch | customer | qty × price | base | COGS posted | invoiced |
|---|---|---|---|---|---|---|
| 2026-07-05 | OUT-2026-0007 | Test Customer | 55 × 500 SGD | 20,350.00 | no | INV-2026-0001 |
| 2026-07-31 | OUT-2026-0001 | ST Engineering | 2000 × 12 USD | 24,000.00 | no | INV-2026-0002 |
| 2026-08-05 | OUT-2026-0119 | Test Customer | 200 × 7 USD | 1,736.00 | no | INV-2026-0003 |
| 2026-08-05 | OUT-2026-0120 | ST Engineering | 500 × 12 USD | 7,440.00 | no | INV-2026-0004 |

All four follow today's order: sale first, invoice after. **None carries COGS** (their batches
have no allocated unit cost — OPS-20's margin finding, same rows). All revenue is recognised.

**Doc 1's flow breaks the coupling**: an invoice issued *before* shipment has no `sales_records`
to group — under current machinery it cannot exist. The options:

| recognise at | what it means | machinery consequence |
|---|---|---|
| **invoice** | issuing the invoice posts revenue + AR; shipment becomes a later goods movement | the invoice stops being derived and becomes a posting document; "invoiced, not yet shipped" needs a liability/in-transit treatment the chart does not have; COGS and revenue post at different moments |
| **shipment** (today's point) | the pre-shipment invoice is a *commercial document* (pro-forma), not a posting one; recognition stays exactly where it is | smallest change: Doc 1's flow is delivered by adding a printable pre-shipment invoice **document** (PUR-1's issue machinery is the precedent) while the ledger keeps working as proven. The word "invoice" then means two things, which must be said on screen |
| **transfer of control** (Incoterm) | EXW recognises at handover, CIF/DDP at destination — `customers.incoterm` already exists as a column | most correct under FRS 115 and most machinery: recognition decouples from *both* documents and needs a recognition event per sale |

**Not picked.** But one observation that is fact, not judgement: option "shipment" is the only one
that changes no posting that already works, and it still delivers the printed flow — the decision
is therefore *whether the pre-shipment invoice is a posting document or a commercial one*, which
is exactly the auditor question.

## 2 · What happens to `record_output_sale`?

**It becomes the fulfilment step; it is not replaced.** It is the only writer of the sale
primitive (movement + record + revenue + COGS in one transaction) and five things stand on it:
COGS posting (inside it), invoice grouping (`invoice_lines.sales_record_id`), the margin view
(`batch_margin` reads `sales_records`), `ar_open_items` (open amount per sales record), and
payment allocation (`payment_allocations.sales_record_id`). A replacement orphans all five plus
the four live rows; an extension adds an **optional `sales_order_line_id`** so a fulfilment can
draw down an order — nullable, so the four existing records simply predate orders, exactly as
inbound batches without a `purchase_order_id` predate POs today.

One mechanical note for whoever builds it: `sales_records` is immutable by trigger
(`SALE_IMMUTABLE`, column-by-column). Adding the link column needs the same one-way relaxation
`cogs_entry_id` already got (NULL → set once, never changed).

## 3 · Reservation — **BUILT (SO-2, 2026-08-14)**

**This section used to say hard reservation was blocked, and recommended a derived soft check
instead. Both statements are retired here, in the cut that closed them** — a note describing a gap
that no longer exists costs a reader the same wrong belief as a comment asserting a hazard that
cannot occur, and no gate will ever catch it.

What unblocked it was STK-1: the "unbuilt Phase 2 status-differentiated stock" this section was
waiting on shipped on 2026-08-12 (`inventory_movements.stock_status`, paired movements, a
non-negative-bucket constraint trigger). SO-2 added the third bucket, `committed`, and its writer.

**The shape, so nobody re-derives it:**

* reserving writes a **status-change pair** — out of `available`, into `committed`, same batch and
  same location bucket. `remaining_qty` never moves, so the physical ledger never lies; the
  DEFERRABLE invariant holds by construction because the pair nets to zero.
* `output_batches.state` is **not** touched. A fully reserved batch is still 「库存中」 —
  **a promise is not a sale.** How much is promised is read off the derived three-bucket split,
  never off that column (which still has exactly one UPDATE writer, `record_output_sale`).
* the order-line ↔ batch **many-to-many** that `sales_order_lines` parked lives in
  `sales_order_reservations`, one row per reservation *fact* — released rather than edited, so a
  partial release is "release the whole row, re-reserve the remainder" rather than a quantity edit.
* reservation is a **sales** act: `reserve_stock` / `release_reservation` require
  `module.sales.edit`, not `module.inventory.edit` (reasoning in the migration header, same shape
  as `drain_stock`'s in `zzz_function_grants.sql`).
* cancelling an order releases every active reservation, and **asserts** afterwards that none is
  left. Closing does not: a closed order's goods went out, they were not handed back.
* a batch with active reservations **cannot be written off** — named refusal, remedy in the
  message. That is why the writeoff/reversal drains still pass `ARRAY['available','on_hold']`
  unchanged: `committed` is blocked upstream and never reaches them.

**Still not built: consumption at shipment.** `record_output_sale` draws from `available` only, and
refuses beyond it while naming all three buckets. Cut 4 reads the reservation. One thing that cut
must decide first: `drain_stock`'s emptying order ends with `m.stock_status`, which is **alphabetical**
(`available` < `committed` < `on_hold`) and therefore incidental rather than a policy — for
fulfilment it is backwards, since shipping against an order should relieve *that order's*
reservation rather than eat unreserved stock and leave the promise dangling.

## 4 · The pricing models — what the engine already does, sell-side

The engine (`calculate_metal_price` → content × market price × payable% − treatment charge −
discount) is **direction-agnostic arithmetic**; `pricing_formulas.direction` already admits
`'sale'` and `'both'` (live: one `'both'` formula). Coverage:

| model | covered? | notes |
|---|---|---|
| **formula-priced** (payables on content) | **yes, as built** | spot and N-day-average bases both exist; this is the engine's home ground |
| **spot at market** | **yes, degenerately** | a formula with 100% payable, zero TC, zero discount. Works today; worth a named "market price" preset so nobody hand-builds it wrong |
| **fixed contract price** | **yes, trivially** | `record_output_sale` takes a plain `unit_price` now — that *is* fixed pricing |
| **index-linked with quotational periods** (e.g. LME average of M+1) | **NO — two real gaps** | ① bases reach *backward* only (spot / N-day average before reference date); a quotational period reaching *forward* (month following delivery) does not exist and forces settlement to wait for the period to close — a genuinely different settlement flow. ② `metal_prices` is **one price series per metal** (`source` is a free-text label, not a second series): "LME **or** SMM", Doc 1's own words, is not modelled — pricing against SMM for China sales and LME elsewhere needs the series keyed by source |

**FIN-27 extension — confirmed, and it is reuse.** A long-term sales contract priced on a formula
has *exactly* the purchase-side disease: the formula can change under a deal already struck.
`pricing_term_commitments` is purchase-shaped only in its two FK columns
(`purchase_order_line_id`, `inbound_batch_id`; zero rows live) — the mechanism (copy terms at
commitment, settle from the copy, refuse an uncommitted reference **by name**, history on edit)
transfers verbatim by adding `sales_order_line_id` to the XOR. The one asymmetry worth naming:
**the FX side flips.** Purchase estimates convert at `tt_sell`; money coming *in* converts at
`tt_buy` (record_payment already encodes "the side is part of the rate") — a sell-side quote path
must not inherit the buy-side's rate side.

## 5 · Approval — wire into APR-2's engine, not a second one

The engine is generic where it matters: `approval_level_for` takes an amount, `approval_log` takes
a subject. What a sales order needs that a purchase order did not:

* **A subject type** — `approval_log.subject_type` CHECK gains `'sales_order'` (one line) and
  `record_approval_decision` gains its lookup arm.
* **A threshold question — TIM'S:** same `approval_threshold_base` for both directions, or a
  sell-side threshold? Committing to buy 25k and agreeing to sell 25k are different risks (one is
  cash out, the other is credit exposure — which §6 handles separately, arguing for *same
  threshold* here rather than double-counting credit risk into approval).
* **A level-1 role question — TIM'S:** finance was chosen for purchases as "the party that pays".
  The sell-side symmetric reading is still finance ("the party extending credit"); the
  supervisor reading is a sales manager, which at current headcount is the `sales` role approving
  its own work — the collapse problem again.
* **Four-eyes has the same one-user problem, already solved:** the `approvals_enabled` tri-state
  covers sales orders for free if they route through the same flag. A separate flag would let
  purchase approvals run while sales approvals are off — plausible during rollout; **TIM'S**, but
  the default assumption is one flag until someone asks for two.

## 6 · Credit control — self-contained, and the earliest useful block

Present: `customers.payment_terms_days`, `credit_rating` (free text), and `ar_open_items` already
computing per-customer exposure (`open_base` per record; sum is a GROUP BY away). Absent: any
**limit** to compare against, and any **freeze** state.

What it takes: `customers.credit_limit_base` (nullable = no limit — NULL must mean "unlimited by
decision", never a zero that blocks everyone, the FIN-35 distinction), a `credit_hold` boolean
(freeze is an act, not a rating), exposure = Σ open AR + (once orders exist) open unshipped
orders. **Where the block attaches:** quote — nothing to attach to yet; order — right place once
orders exist; **shipment (`record_output_sale`) — attachable TODAY**, which makes over-limit
blocking buildable before any of the rest of the cycle: the check refuses by name
(`CREDIT_LIMIT_EXCEEDED|customer|exposure|limit`) exactly where goods leave. Alert side: two
`operations_now` arms (`credit_over_limit`, and approaching at N% — the qualification-arms shape).

## 7 · Contracts — one pattern, mirrored, sharing the commitment machinery

Shape: a **framework header** (counterparty, validity window, committed pricing terms via FIN-27,
optional total/period quantity, delivery cadence) that operational documents **draw down against**
— sales orders on the sell side, purchase orders against the blanket PO Doc 1 also names (also
unbuilt). The two are mirror images with different fulfilment (outbound vs inbound) and different
credit posture.

**Share the pattern and the commitment machinery, not the table.** The repo's precedent is
`ap_open_items` / `ar_open_items`: same idea, two views, because the joins differ. One
`trade_agreements` table with a direction column would put a fictional symmetry over genuinely
different lifecycles (a sales contract cares about credit and reservation; a blanket PO cares
about qualification expiry and receiving). What they *must* share: FIN-27 commitments (the terms
frozen at contract signature, drawn by every call-off), and the drawdown arithmetic
(open = committed − Σ called-off), which can be one SQL shape used twice.

## 8 · The split, ordered by dependency — earliest visible improvement first

Today Tim sells by creating an output batch with a customer, calling `record_output_sale` from the
output edit screen at a hand-computed price, and grouping an invoice afterwards. The two pains
reachable *without* the ledger question: the price is computed outside the system (his named
pain), and nothing watches credit.

| cut | contents | depends on | improves today's flow? |
|---|---|---|---|
| **SAL-A** | **sell-side pricing integration**: price an output batch for a customer on a formula (direction-aware — `tt_buy` for money in), a "market price" preset, feed the result into `record_output_sale` instead of a hand-typed number | nothing — the engine exists | **immediately**: the named pain, on the flow Tim uses today |
| **SAL-B** | **credit control**: limit + hold on customers, exposure from `ar_open_items`, block inside `record_output_sale`, two dashboard arms | nothing | immediately: today's flow gains a guardrail |
| **SAL-C** | **the sales order**: document + draft state, APR-2 wiring (subject type, Tim's two answers from §5), soft availability check (§3), `record_output_sale` learns `sales_order_line_id` | A (orders carry priced lines), B (order-time credit check) | order tracking; today's direct-sale path keeps working as the orderless case |
| **SAL-D** | **FIN-27 on sales order lines**: commitments for formula-priced contract sales | C | contract sales become drift-proof |
| **SAL-E** | **framework contracts + drawdown** (and the blanket-PO mirror when wanted) | C, D | long-contract half of Doc 1 |
| **SAL-F** | **the invoice/shipment flow** — whichever answer §1 gets; if "shipment", this is a pre-shipment invoice *document* on PUR-1's issue machinery; if "invoice", it is a recognition rework | **§1 answered** | last, deliberately: it is the only cut that can break postings that already work |
| **SO-2** *(done, 2026-08-14)* | **hard reservation** — `committed` as the third `stock_status`, `sales_order_reservations` (the line ↔ batch many-to-many), manual per-line reserve/release on confirmed orders, auto-release on cancel, write-off refused while reserved | STK-1 (status-differentiated stock, 2026-08-12), SO-1 | reserved stock is visible on the floor and cannot be sold or processed out from under an order |
| *(next)* | consumption at shipment — the sale relieves its own reservation | SO-2 | — |
| *(parked)* | index-linked pricing (QP, LME/SMM series) | `metal_prices` keyed by source + forward-window settlement | its own scoping when a contract needs it |

SAL-A and SAL-B are independent, each one cut, each visible on the screen Tim already uses.
Nothing in A–E touches revenue recognition, so the auditor question gates only F.
