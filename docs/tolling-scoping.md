# Tolling — survey, 2026-08-30 (TOLL-0)

**Read-only survey. Nothing was built, nothing was migrated. This document is the whole deliverable.**

**Recommendation up front: BUILD NOTHING NOW — conditional on a trigger being watched, and the
watching is done by a person, not by the system.** §7 says exactly what that means and what risk it
carries. The reasoning is written out below rather than only the conclusion, so that a later reader
can tell a **considered non-build** from an oversight.

**Terms this survey was given (Tim):** tolling is a **future possibility** — no live tolling
business, no signed contract, no term sheet, and nobody has ruled on any commercial term. **Both
directions** are expected eventually: customer-owned material processed in our plant (we earn a
fee), and our material processed at a third party's plant (we pay a fee).

---

## 0 · A CORRECTION TO THIS SURVEY'S OWN FRAMING — dated 2026-08-30

**The brief that commissioned this survey assumed OWNERSHIP is the axis. That framing is wrong, and
it is corrected here so that a later reader does not meet it and re-derive it.**

The sentence this system cannot say today is **not** "this material is not ours". It is:

> **"This receipt does not create a debt to the person who delivered it."**

Ownership is a *consequence* of that sentence, not the primitive. The evidence is that receiving
welds two things together in one act — it records our inventory **and** it anchors a payable — and
the anchor sits on the batch itself (`inbound_batches.unit_price`, alongside `quantity`). So the
axis, if one is ever needed, is a property of the **receipt event**, not a label on the material.

**The candidate is NAMED here, not designed.** The measurement does **not** distinguish between:

1. a flag on `inbound_batches`;
2. a **receipt-kind** on the receiving event (purchase / tolling-in / return);
3. a **separate document type** — a tolling receipt that is simply not a purchase receipt at all.

**Choosing among those three is design work, and it needs a real contract to inform it.** This
document deliberately proposes **no column**. Anyone who later reads this and reaches for
`ALTER TABLE ... ADD COLUMN owned_by` should notice that they are choosing option 1 without the
evidence that would justify it over 2 or 3.

---

## 1 · WHAT WAS MEASURED, AND WHAT WAS ONLY CONFIRMED

**A prior survey already covered most of the accounting side.** `docs/proc-reality.md` surveyed
tolling as item **F** and queued it as **G28**. It ran the same search this survey ran
(`own|toll|consign`, zero hits) and concluded that receiving unconditionally records our inventory
and raises a payable, with the anchor `quantity × unit_price` unconditional, so *"「这批料不是我们
的」在今天说不出口"*.

**So §2 below CONFIRMS proc-reality rather than re-deriving it, and says so.** Restating an existing
survey as new findings would make this document look like more evidence than it is. The survey's real
weight is spent on the two areas proc-reality did **not** cover: **§3 regulatory** and **§4 outbound**.

---

## 2 · CONFIRMED (2a–2e) — proc-reality F/G28 re-checked against the code

Each row was re-read in the code today; the object is named so the claim can be re-checked.

| # | question | finding | object |
|---|---|---|---|
| 2a | what does receiving assume about ownership? | **Nothing records ownership.** Every column in the `public` schema was searched for `owner\|owned\|ownership\|title\|consign\|custody\|bailment\|third_party\|toll`: **zero** material-ownership columns. Every hit is a job/document *title* or an `owner_id` meaning a *responsible person* (`tasks.owner_id`, `suppliers.owner_id`). **Ownership is implied by the fact of receipt.** | `inbound_batches` (24 columns, none of them ownership) |
| 2b | do stock reports value customer-owned material as our asset? | **Quantity and value are separated today.** `stock_snapshot` carries **no value column** — it is quantities gated on `module.inventory.view`. Inventory *value* lives in the GL (1200/1220), written by `allocate_processing_costs`, `reprice_inbound_batch`, `record_output_sale`, `ship_order`, `record_freight_document`, `inventory_ledger_triggers`. So the wrong asset figure would arrive through the **ledger**, not through the stock screen. | `db/views/stock_snapshot.sql`; the six functions above |
| 2c | does cost allocation assume the input's cost is ours? | **Yes** — allocation writes to 1220 and relieves cost against batches with no notion that an input might not be ours. | `db/functions/allocate_processing_costs.sql` |
| 2d | would a tolling run produce a meaningful margin? | **No — it would produce a wrong one, if it produced anything.** `batch_margin` computes `revenue_base − unit_cost_base × qty_sold`. A tolling run earns a **fee** and sells nothing we own; the margin frame does not apply. | `db/views/batch_margin.sql` |
| 2e | does receiving post an entry that assumes ownership? | **Confirmed with one correction to how it is usually stated.** `create_inbound_batch` does **not** itself post a journal entry — it inserts the batch carrying `unit_price`. The ownership assumption is carried by that stored `unit_price` and by everything downstream that reads it. **The anchor is real; it is just not a posting inside the receive call.** Stating it as "receiving posts a payable" is close enough to mislead the next reader, so it is written precisely here. | `db/functions/create_inbound_batch.sql` |

---

## 3 · ★ REGULATORY (2f) — the area proc-reality did not cover, and the one where being wrong is exposure rather than arithmetic

**Finding: the regulatory model is built on CUSTODY, and the counterparty side of it is welded to
"the deliverer is a supplier".** Those are two different statements and both matter.

**(i) The regime itself is custody-shaped, which is good news.** `docs/compliance-scoping.md` records
that Basel / TFS movement documents are **transaction-scoped**: *"one document set per physical
shipment, with its own lifecycle (notification → consent → movement → confirmation of disposal)"*,
naturally keyed to the batch. A regime keyed to the **physical movement** does not need to know who
holds title — which is why tolling does not, on its face, break the regulatory model.

**(ii) But the counterparty's certificates have nowhere to live unless that counterparty is a
supplier.** Measured:

* `supplier_compliance.supplier_id uuid **NOT NULL** REFERENCES suppliers(id)` — a counterparty's
  Basel/NEA/hazardous certificates can only attach to a **supplier** row.
* The live intake gate is the view `supplier_receiving_blocked`, keyed on `sc.supplier_id`, and it is
  enforced at receiving by `trg_inbound_batches_po_receivable` on `inbound_batches`.
* `waste_classifications` is a controlled-waste dictionary that **deliberately excludes** Basel/UN/HS
  codes and jurisdiction (its own table comment defers those to `compliance-scoping.md`), so it does
  not carry ownership either.

**(iii) The consequence is a wrong answer about a PARTY, not about a number** — and it is the same
root as §5 below. A tolling deliverer is a **customer**. To be received from at all they would have
to be registered as a supplier, and their regulatory certificates would then be filed as a
*supplier's* certificates. **The regulatory record would name the wrong kind of relationship.**

**(iv) Note this fails LOUDLY, not silently — which matters for the axis test.** Receiving already
refuses by name when the counterparty does not supply goods:

```
RECEIPT_AGAINST_NON_GOODS_VENDOR|<code>|<name>
```

— raised by `guard_inbound_supplier_supplies_goods` (SUP-TYPE-1a). And `suppliers.supplies_goods` is
a **generated** column: `(counterparty_type = 'goods_supplier')`, so it cannot simply be set. A
first tolling receipt from a party correctly registered as a customer or `service_vendor` would be
**blocked at the gate**, by name, rather than quietly mis-posted. That is a missing feature, not a
silent wrong answer.

---

## 4 · ★ OUTBOUND (2g) — our material at a third party's plant

**Finding: there is no representation of material we own that is not on our site — and this is the
SAME open question `logistics-survey.md` A4.4 already asks, wearing different clothes.**

Measured:

* `inventory_movements.movement_type` is a **12-value CHECK**: `receipt`, `processing_consume`,
  `processing_produce`, `reversal_restore`, `reversal_void`, `sale`, `writeoff`, `adjustment`,
  `status_change_out/in`, `transfer_out/in`.
* `transfer_out`/`transfer_in` are **paired** (a CHECK ties those four types to `pair_id IS NOT
  NULL`) — an internal location-to-location move, both legs inside our own stock. **It is not
  "material left our custody but is still ours".**
* `storage_locations` has no off-site or third-party concept at all: `id, code, name, notes, zone,
  is_active`. **4 rows live, one of them active and real.**

**So today, material leaving our site can only be recorded as a `sale` (we no longer own it), a
`writeoff` (it is gone), or a `transfer` to another of our own locations.** Sending material out for
processing and getting it back has **no honest representation**.

**This is deliberately not opened as a second thread.** `docs/logistics-survey.md` A4.4 already asks:
*"货离开仓库、尚未被对方收到时,存货挂在哪里?"* — where does inventory sit once it has left us and
has not yet been received by the other side? **Outbound tolling is that same unanswered question.**
Answering it for tolling separately would create a second definition that drifts from the first.
**Whoever answers A4.4 should answer this at the same time**, and vice versa.

> **A note on the movement vocabulary, for whoever does answer it.** `movement_type` is a **CHECK
> constraint, not a dictionary table**. Adding a thirteenth value is a migration *plus* every reader
> that branches on the type — the same shape proc-reality flagged for `output_batches.state`
> (item H / G29: *"加第四个值要动每一个按 state 分支的读者"*). That is a real cost, and it is a cost of
> the **outbound** answer, not of tolling as such.

---

## 5 · THE PARTY PROBLEM — a wrong answer about WHO, recorded separately because it is not about a number

**`inbound_batches.supplier_id` is `NOT NULL`, and live it is populated on 23 of 23 rows.** A
tolling deliverer is a **customer** — we bill *them* a fee — yet the only way to receive material is
under a supplier. Combined with §3(iv), the shape is: **either the party is recorded wrongly, or the
receipt is refused.**

**Does COUNTERPARTY-ONE-PARTY subsume this?** — the deferred `parties`-master migration recorded in
`docs/known-issues.md`, whose trigger is bulk import. **Partly, and it is worth being precise about
which part:**

* **It would subsume the identity half.** A single party able to sit on both sides is exactly what
  lets one company be "the customer we toll for" without inventing a supplier row for them.
* **It would NOT subsume the receipt half.** Even with a parties master, `inbound_batches` would
  still have to say *which relationship this particular receipt is under* — a purchase from them, or
  a tolling delivery by them. That is §0's receipt-event axis again, and a parties master does not
  answer it.

**So they are related but separate problems, and neither one waiting on the other is a reason to
defer the other.**

---

## 6 · THE AXIS TEST

Applied to the candidate that the measurement actually points at — **the receipt-event axis** (§0),
not the ownership label the brief assumed.

**3a · Missing feature, or silent wrong answer?**
**Today: neither, because there is no tolling material.** On the day a first tolling receipt is
attempted, §3(iv) says it is **blocked by name** (`RECEIPT_AGAINST_NON_GOODS_VENDOR`) if the party is
registered honestly. It becomes a **silent wrong answer** only if someone works *around* that
refusal by registering the tolling customer as a goods supplier — at which point inventory, the
payable anchor and margin are all wrong at once. **The silent-wrong-answer path exists, but it runs
through a person deciding to bypass a named refusal.**

**3b · How expensive to add later? — measured, not asserted.** The whole material chain, live:

| table | rows |
|---|---|
| `inbound_batches` | **23** |
| `inventory_movements` | **105** |
| `processing_inputs` | **13** |
| `processing_outputs` | **17** |
| `output_batches` | **20** |
| `processing_runs` | **13** |
| `containers` | **17** |
| `storage_locations` | **4** |

**Under 220 rows in total.** The numbers are written out so a later reader can re-check the claim
rather than trust the word "small" — and can re-measure, because these will grow.

**3c · Can it be added later without a backfill judgement? — YES, and this is the decisive answer.**
**Every existing inbound batch is unambiguously ours**: all 23 have a `supplier_id` (zero nulls), and
there is no tolling business to make any of them ambiguous. A later backfill is a single assignment
with **no judgement in it**. There is no row whose correct value a future maintainer would have to
guess.

**3d · Does anything already carry this fact under another name? — NO.** Confirmed by the schema-wide
search in §2a: zero material-ownership columns under any spelling. The nearest neighbours —
`suppliers.counterparty_type`, `supplies_goods` (generated), `movement_type` — each carry *a*
dimension, but none of them carries "does this receipt create a debt".

> **★ TWO "EXPENSIVE" VERDICTS THAT ANSWER DIFFERENT QUESTIONS — do not conflate them ★**
>
> `proc-reality.md` grades tolling **EXPENSIVE**, and it is right — but it is grading **the cost of
> building the behaviour** (unwiring receipt-implies-payable, moving the anchor). That cost is the
> same whenever it is paid: today, or in a year.
>
> **The axis test asks a different question: is the axis expensive to *defer*?** And 3b + 3c answer
> that separately: under 220 rows, every one unambiguously ours, backfill carries no judgement.
>
> **The two answers point opposite ways, and the second one governs the timing decision.** A later
> reader meeting only the word "EXPENSIVE" would conclude this should have been built early. It
> should not have been. The behaviour is expensive whenever built; the axis is cheap to defer.

---

## 7 · ★ THE IRREVERSIBLE EDGE — the most important section in this document

**The question that would overturn "build nothing": is there a FACT that becomes unrecoverable if we
receive tolling material without an axis?** The repo has a precedent where the answer was yes — the
assay `party` axis, where *"whose assay was this"* is **unrecoverable after the fact**, which is why
it was built ahead of need.

**Tolling is not that case, with one exception.**

**The facts survive.** Which counterparty, what quantity, what date, which batch, which material —
all are recorded by the existing receiving path regardless of ownership. What would be wrong are
**derived numbers**: inventory value, the payable, margin. Those are **recomputable** once an axis
exists. Unlike the assay case, nothing about the physical event is lost.

**The exception, and it is the reason the recommendation is conditional rather than unqualified:**

> **A payable wrongly raised to a tolling customer is not merely a wrong number — it is a DOCUMENT
> THAT MAY HAVE BEEN ACTED ON.**
>
> A recomputation fixes the ledger. **It does not un-send a payment, and it does not un-net an
> offset against what that counterparty owes us.** Money that has moved has moved.

So the irreversible risk is **not** in the data model; it is in the window between a first tolling
receipt and someone noticing. That is why the recommendation below is conditional on a trigger.

### What "watched" means in practice — and the honest answer is: a person remembering

**Nothing in the system would notice a tolling receipt.** Measured, the state of the trigger today:

* There is **no** tolling flag, kind or document to fire on — that is the entire finding of §0/§2a.
* The nearest thing to a mechanical trigger is `guard_inbound_supplier_supplies_goods`'s refusal
  (§3(iv)) — and it fires only if whoever does the receiving registers the tolling counterparty
  **honestly**. It is a guard against a mistake, not against a decision.
* No dashboard arm, no report and no check anywhere asks "was any of this material not ours". It
  cannot: the question is unsayable (§0).

**So the deferral's safety rests on a person remembering, not on a mechanism.** This repository has a
standing lesson that *a note used where a mechanism was needed does not work* (OPS-7; `wait_for.sh`).
**That lesson applies here and is not being pretended away** — the difference is that here there is
nothing yet to attach a mechanism to, because the axis that a check would read is the very thing being
deferred.

**Tim is therefore accepting a memory-based deferral, not a mechanical one, and should know that is
which.** The concrete trigger is precise and it is *not* "when tolling is discussed":

> **The axis must exist BEFORE THE FIRST TOLLING RECEIPT — not before the first tolling
> conversation.** The moment of no return is a truck arriving with material we do not own.

**Carried forward by reference, not restated:** `proc-reality.md`'s standing instruction to future
cuts — *the next cut that touches receiving must not weld "receipt implies payable" one layer
deeper*. It is still the right instruction and it still lives there.

---

## 8 · THE (A) / (B) / (C) SPLIT

### (A) — must be added now: **EMPTY**

**No members.** The test is *"its absence is a silent wrong answer"* — a number produced that is
wrong. **No wrong number is produced today**: there is no tolling material, no tolling contract, and
all 23 inbound batches are unambiguously ours. Nothing can become wrong until a first tolling receipt,
and on that day it is the *first* receipt that is wrong, not a backlog of them (§6, 3c).

**This is stated plainly rather than padded.** Proposing work to justify the survey would be the
failure mode here.

### (B) — can wait: rows, screens and rules a real contract will specify

* the fee mechanism and its calculation (a rate is a row once the shape is known);
* the tolling document and its screens;
* the receipt-event axis itself — **cheap to defer** on the measured evidence (§6);
* the party arrangement — related to COUNTERPARTY-ONE-PARTY but not subsumed by it (§5);
* the outbound representation — **belongs to `logistics-survey.md` A4.4, not to a tolling cut** (§4).

### (C) — cannot be decided at all without a real contract

Everything in §9. These are **Tim rulings that need a real counterparty**, not design decisions, and
they are enumerated without answers or defaults below.

---

## 9 · THE QUESTIONS A REAL CONTRACT MUST ANSWER

**Enumerated, not answered. No defaults are proposed, and none should be inferred from the order.**
Each is a **Tim ruling that requires a real counterparty** — a design decision taken in their absence
would be a model fitted to imagination, which is the thing this repo's own rule forbids.

1. **How is the fee computed?** Per tonne of input, per tonne of *recovered metal*, against a
   guaranteed recovery rate, or as a share of value.
2. **Who bears processing loss?** The difference between input mass and recovered mass has to fall on
   somebody.
3. **Who bears risk while the material is on our site?** Insurance and loss/damage during custody.
4. **Does title transfer at any point, and if so when?** Including whether it transfers *and back*.
5. **Whose assay governs settlement — the customer's or ours?** (The machinery for a settling party
   exists — `contract_settlement_terms.settling_party`, PROC-6's `result_party` — but which party a
   tolling contract names is a term of that contract.)
6. **What happens to by-products and residues?** Who owns them, who pays to dispose of the ones with
   negative value.
7. **May the material be commingled with our own?** This one has consequences beyond commerce: if
   commingling is permitted, per-batch lineage and mass balance must still be answerable afterwards.
8. **Which party holds which regulatory obligation** for material we hold but do not own (§3).

---

## 10 · RECOMMENDATION

> ### BUILD NOTHING NOW.
>
> **Conditional on the trigger in §7 being watched — and the watching is done by a person, not by the
> system.**

**The reasons, in the order they actually carry weight:**

1. **(A) is empty.** No wrong number is produced today, and none can be until a first tolling receipt
   (§8).
2. **The axis is cheap to defer** — under 220 rows across the whole material chain, every existing row
   unambiguously ours, backfill with no judgement in it (§6, 3b/3c). This is the measurement that
   most directly opposes building now, and it is the one a later reader should re-check first.
3. **The behaviour is expensive whenever it is built**, so building early buys nothing on that side
   (§6, the two-verdicts note).
4. **The evidence does not yet distinguish the three possible shapes** of the axis (§0). Choosing one
   now would be design ahead of the contract that should inform it — and the wrong choice is *more*
   expensive than the delay.
5. **Failure is loud, not silent, on the honest path** — a first tolling receipt from a correctly
   registered counterparty is refused by name (§3(iv)).

**What would change this recommendation:**

* a signed tolling contract, or a real term sheet — at which point §9's questions become answerable
  and the axis's shape becomes decidable;
* a decision to receive tolling material before either exists — in which case **the axis must land
  first**, per §7;
* someone answering `logistics-survey.md` A4.4, which would settle the outbound half independently
  (§4).

**What this recommendation is NOT.** It is not "tolling is unimportant", and it is not "nothing was
found". Four things were found and are recorded above so they do not have to be rediscovered: the
axis is on the **receipt**, not the material (§0); the regulatory record would name the **wrong kind
of party** (§3); the outbound direction is **the same question as goods-in-transit** (§4); and the
one genuinely irreversible risk is **a payable that may have been acted on** (§7).
