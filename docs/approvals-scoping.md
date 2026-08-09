# Approvals — scoping (Doc 2 Principle 6, Doc 3 Final Phase)

**Status: SCOPING ONLY. Nothing here is built.** Several decisions in it are Tim's, and they are
marked **DECISION** rather than answered. This file exists because the Phase 6 dashboard lost four
arms to a specification that lived only in a conversation.

**What the documents ask for**, so it is not re-derived:

* Doc 1 (Tim's hand): *"All value related actions should have an approval."* Two levels — requester
  raises, supervisor approves; **10k and above** goes to CFO. Also named: **configurable chains**,
  **delegation** when an approver is away, and an **audit trail** of who approved, rejected or
  countersigned, and when.
* Doc 2 Principle 6 names the actions: **purchase orders, payments, price changes, stock issue,
  expense claims**.
* Doc 1, the most painful part of procurement, verbatim: *"chasing for manual approvals and
  signatures."* That sentence is the acceptance test. A system that replaces paper chasing with
  screen chasing has not delivered it.

---

## 1 · What already exists

### The three HR chains

| | leave | medical claim | performance review |
|---|---|---|---|
| raise | `submit_leave_request` — self **or** `module.hr.edit` | `submit_medical_claim` — self **or** `module.hr.edit` | `submit_review` — `module.hr.edit` **or** `is_reviewer_of(row)` |
| decide | `decide_leave_request` — **`module.hr.edit` only** | `decide_medical_claim` — **`module.hr.edit` only** | `approve_review` — `module.hr.edit`, **plus** `SELF_APPROVAL_FORBIDDEN` |
| routing | **team queue** — any holder of the code | **team queue** | **per person** — `reviewer_employee_id` on the row |
| four-eyes | none | none | yes (cannot approve own) |
| audit | `decided_at`, `decided_by`, `decision_notes` | `decided_at`, `decided_by`, `decision_notes` | `submitted_at/by`, `approved_at/by`, `acknowledged_at` |
| gate on the amount | `INSUFFICIENT_ACCRUED_LEAVE` | `CLAIM_EXCEEDS_LIMIT` | n/a |

**Reviews are the only per-person routing in the database.** It works through
`reviewer_employee_id` + `is_reviewer_of()`, which resolves through
`current_user_employee()` → `employees.user_id = auth.uid()`. `open_review_cycle` defaults the
reviewer to the department manager (`departments.manager_employee_id`, then the parent
department's).

**Three findings that matter more than the table:**

1. **The audit trail is columns on the row, so it keeps only the LAST decision.** All three chains
   overwrite `decided_at`/`decided_by`. There is no append-only approval log anywhere in the
   schema. Doc 1 asks for *"who approved, rejected or countersigned, and when"* — **as built, a
   reject followed by a resubmit and an approve leaves no trace of the rejection.** The repo has
   the right precedent elsewhere (`pricing_formula_history`, `processing_cost_entry_history`,
   `employment_history` are append-only), just not here. **Doc 1's audit trail is not a reporting
   layer over the existing chains; it is a table that does not exist.**
2. **There is no "countersign" concept anywhere** — not a column, not a status. Doc 1 names it.
3. **Two of the three chains have no four-eyes rule.** A holder of `module.hr.edit` can submit a
   leave request on someone's behalf and approve it in the same session. Only reviews forbid it.

### The reserved and unbuilt

* **`purchase_orders.approval_status`** — `pending`/`approved`/`rejected`, **defaults to
  `'approved'`**, and `create_purchase_order` stamps `approved_at`/`approved_by` unconditionally.
  The mirror says so in as many words: *"结构在此,流程不在此"*. All 3 live POs are `approved`.
  This is the reserved interface and it is the right one — but note the default means **switching
  it on is a behaviour change for every existing row and every code path that reads it**, not a
  new column.
* **`action.*` permission category — exactly ONE code exists**: `action.manage_permissions`. The
  category is reserved and otherwise empty. It is the natural home for `action.approve.*`.
* **`employees.manager_id`** — self-referencing FK, cycle guard (`guard_manager_cycle`), and an
  index. **Populated on 0 of 1 live employee rows.**

### The fact that governs question 2

```
employees (not deleted) ........ 1        with manager_id ....... 0
                                          with user_id .......... 0
departments .................... 1        with a manager ........ 0
login accounts holding a role .. 14
```

**The org chart does not exist yet, and no employee row is linked to a login.** Fourteen people can
sign in and carry roles; one employee record exists and it is connected to nothing.

A consequence worth stating plainly: **the reviews chain — the one piece of per-person routing —
cannot currently route to anybody on live**, because `is_reviewer_of()` needs `employees.user_id`
and no row has one. It is correct code sitting on unpopulated data.

---

## 2 · Who is "the supervisor"? — **DECISION, not picked here**

| | **the org chart** (`employees.manager_id`) | **the role** |
|---|---|---|
| what it means | approval follows the reporting line | approval follows the function |
| supported today? | **no** — 0 managers set, 0 employee↔login links | **yes** — 14 accounts carry roles now |
| what it needs first | populate ~15 employee rows, set every `manager_id`, and set `user_id` on each so `current_user_employee()` resolves | nothing |
| strength | matches how people actually experience authority; delegation and absence are natural | works immediately; survives someone changing jobs |
| weakness | a 15-person company has a very flat chart — several people may report to Tim, making it identical to "Tim approves" but with more machinery. Breaks the moment an employee row is missing | the person who *should* approve a purchase may not be anyone's manager. A role queue has no notion of *your* approver |
| failure mode | approver resolves to NULL → the request has nowhere to go | everyone with the role sees everything → nobody feels responsible (the "team queue" problem the HR chains already have) |

**The honest reading:** the only thing the data supports today is **role-based routing**, and the
org-chart option is not a design choice so much as a **prerequisite project** — populating the
employee table, the reporting lines and the login links is real work with real decisions in it
(who reports to whom is an org decision, not a data-entry task).

A third shape exists and may fit fifteen people better than either: **routing by role for the first
level and by named person for the second** — the function decides who *can* approve, and a specific
human is named for the above-threshold step. It needs no org chart.

---

## 3 · Who is "CFO"? — **DECISION**

No such role exists. The ten are: `admin`, `gm`, `finance`, `procurement`, `sales`, `operations`,
`warehouse`, `hr`, `auditor`, `employee`.

| candidate | implies |
|---|---|
| **a new `cfo` role** | a seat in the org that may not be filled at fifteen people. Creates a role with one member, or none — and an approval step with no eligible approver is a queue that never drains |
| **`gm`** | already holds every `.edit` code including finance. Closest to "the person above the supervisor" without inventing a seat |
| **`admin`** | wrong on principle: `admin` is *system administration* (it is the only holder of `action.manage_permissions`). Making it an approval level conflates "can configure the system" with "can commit the company's money" |
| **a named person (Tim)** | matches reality at this size. **This is a different design**: the above-threshold approver is a *person*, not a role — which means the config table holds a `user_id`, and delegation (§8) becomes required rather than optional, because one named human going on holiday stops every large purchase |

**The size argument is real and should not be glossed:** at fifteen people, "escalate to the CFO"
almost certainly means "escalate to Tim". Building a `cfo` role to hold exactly one person adds a
layer of indirection whose only benefit is that it survives hiring a CFO later. That is a genuine
trade and it is Tim's to make.

---

## 4 · The threshold has no currency — **the comparison must sit on the BASE side**

Doc 1 says "10k" with no currency. **USD 9,000 ≈ SGD 11,300** — above the threshold in base
currency, below it in the document's own.

**This must be settled in the base currency, and the threshold itself must be stored with an
explicit currency.** Reasons, in order of force:

1. **Otherwise the control varies by an accident of the counterparty.** The same real commitment
   needs CFO approval when the supplier bills in SGD and not when they bill in USD. That is not a
   policy; it is a loophole, and a discoverable one.
2. **The repo has been bitten by this exact shape more than once.** FIN-0 flipped the base from USD
   to SGD and the constants left behind broke four screens over four sweeps; FIN-12 valued a
   base-currency payment at 0.00 and a USD one at 1:1; the FIN-18 `jsx-text` class found six places
   printing `USD` while holding the base currency in hand. `scripts/check-currency-literals.mjs`
   exists because of it. **A threshold written as `10000` with no currency is precisely the
   artefact that check was built to forbid.**
3. **`currencies.is_base` is data, never a literal** (AGENTS.md). A threshold stored as
   `(amount, currency_code)` and compared after conversion inherits that rule; a bare `10000` does
   not.

**Which rate, and as of when — a second decision inside the first.** The FX rule says any non-base
amount converts at the rate for that date and refuses if none exists.

* **Purchase orders already carry their own `fx_rate`**, recorded at order date, and
  `estimated_total_ccy` is explicitly *in the document's currency, unconverted* (FIN-28 renamed the
  column because `..._usd` was a lie). Using the document's own recorded rate means the approval
  level **cannot drift after the fact** — the level is decided once, by the document, and stays
  decided. Re-deriving it from today's rate would let a PO silently change approval level between
  being raised and being approved.
* **Payments and expenses already store `amount_base`.** No conversion needed; compare directly.

**Recommendation (not a decision):** store the threshold as an amount **plus** a currency code in
config; compare against the document's base-currency value computed with the document's own rate;
and — since a rate can be missing — the refusal path must say so by name rather than defaulting,
exactly as `fx_rate_for` does.

---

## 5 · What is "value" for an action with no amount?

| action | what a threshold would measure | can it carry one? |
|---|---|---|
| **purchase order** | `estimated_total_ccy × fx_rate` → base | **yes** — with one caveat below |
| **payment** | `amount_base`, already stored | **yes**, cleanly |
| **expense claim** | `amount_base`, already stored | **yes**, cleanly |
| **price change** (`pricing_formulas` edit, `reprice_inbound_batch`, `set_inbound_unit_price`) | nothing. A formula edit changes *future* amounts and has no amount of its own. A batch reprice *does* have a delta — but the formula edit behind it does not | **NO for formula edits.** A reprice of a specific batch could use the delta |
| **stock issue** (`post_stocktake`, `record_output_sale`, `commit_processing_run`, `rollback_processing_run`) | quantity — or quantity × unit cost, which requires a unit cost | **NO, not reliably.** OPS-20 measured it: **3 of 4 sold batches have no `unit_cost_base` at all.** A value threshold on stock movement would be NULL most of the time, and a NULL threshold comparison silently falls to one side |

**The two that cannot carry a threshold are exactly the two whose damage is largest and least
visible** — a formula edit changes every future quote off that formula, and a stock write-off
removes inventory. They need approval that is **unconditional** (every occurrence) rather than
**above a value**. That is a different rule shape, and pretending they fit the amount rule is how a
control ends up not applying.

**A caveat on the PO number:** `estimated_total_ccy` is an **estimate** (the column comment says so
— it is the sum of `quantity × estimated_unit_price` over the lines). Approving an estimate that
later moves is the normal case in this business, since final price depends on assay. **DECISION:
does an approved PO need re-approval when its value rises above the threshold, or is approval a
decision about the commitment as raised?** Both are defensible; only one can be built.

---

## 6 · Blocking or recording?

| action | must approval precede the effect? | what the code makes possible today |
|---|---|---|
| **payment** | **yes** — money leaves | `record_payment` is one `SECURITY DEFINER` function behind `module.finance.edit`. A status gate at its head is a small change |
| **purchase order** | **yes** — it is a commitment to a supplier | `create_purchase_order` already writes `approval_status`; flipping the default to `pending` and gating the *confirm* transition is structurally ready. **This is the one Doc 1 complains about by name** |
| **expense claim** | **yes** for payment; the *claim* is a record of something already spent | `expenses` has `payment_status` `paid`/`unpaid` — the natural gate is on paying an unpaid claim, not on recording it |
| **price change** | **yes** — before it takes effect | `pricing_formulas` is edited by **plain UPDATE**; there is no RPC to gate. FIN-27 had to add a *trigger* to log history for exactly this reason. **This action has no chokepoint** — it would need one built |
| **stock issue** | **yes** for write-off; movements from processing/sales are *consequences* of an already-approved act | `post_stocktake`, `commit_processing_run`, `record_output_sale`, `rollback_processing_run` are all RPCs — gateable. But approving each inventory movement would approve the same decision twice |

**The load-bearing distinction:** four of the five actions run through a single
`SECURITY DEFINER` function that can refuse. **Price changes do not** — the edit path is an ordinary
`UPDATE` on `pricing_formulas`, which is why FIN-27's history had to be a trigger. Any plan that
treats "price changes" as one more wired-up action is underestimating it by an RPC.

---

## 7 · Do the HR chains fold in? — **my read: no, not in the first cut**

**Fold them in** — one concept, one mechanism; the audit trail covers everything at once; Doc 1's
delegation applies to leave as much as to purchases.

**Leave them out** — three working chains, each with **domain rules the generic engine does not
have**: `INSUFFICIENT_ACCRUED_LEAVE` consults the accrual detail function, `CLAIM_EXCEEDS_LIMIT`
consults the annual medical limit, `approve_review` writes employment status, an employment-history
row and unlocks annual leave. **The approval is not the interesting part of any of them** — the
decision function is where the business rule lives, and a generic engine would have to call back
into it anyway.

**Read:** build the engine for the five Principle-6 actions. **Do not migrate the HR chains in the
first cut** — but make the **audit trail generic from day one** and have the HR decision functions
write to it. That gets the single thing that genuinely must be unified (Doc 1's "who approved,
rejected or countersigned, and when" across everything) without touching three working flows.

**The cost of that choice, stated:** for a while there are two mechanisms — HR decides in its own
functions, everything else goes through the engine. That is acceptable *because the audit trail is
shared*, which is what a reader actually needs. Revisit folding once the engine has survived a
quarter.

**Two things worth fixing in HR regardless**, both cheap and both found while scoping: the missing
four-eyes rule on leave and claims, and the overwritten decision history.

---

## 8 · Delegation — **first cut if the approver is a person, second if it is a role**

Doc 1 names it. Whether it is urgent depends entirely on §3:

* **If the above-threshold approver is a ROLE** (`gm`, or a new `cfo` with more than one member),
  delegation is a convenience. The queue drains because someone else holds the code.
* **If it is a NAMED PERSON (Tim)**, delegation is **required in the first cut**. One person on a
  plane stops every purchase over the threshold, and the workaround people will invent — handing
  over a password, or raising two POs under the threshold — is worse than no control at all.

**What it takes** (modest, and smaller than it sounds): a `from_user`, `to_user`, date range and
reason, plus resolution at the point of asking "who may approve this" rather than at the point of
raising. Two traps worth writing down now:

* **Delegation must be recorded in the audit trail as itself** — "approved by B **as delegate of
  A**", not "approved by B". Otherwise the trail says the wrong person committed the money, which
  is the failure the trail exists to prevent.
* **Delegation must not launder the four-eyes rule.** If A raises and delegates to B, B approving
  is fine; A approving as B's delegate is not.

---

## 9 · Proposed split

The dependency that decides the order: **the audit trail is needed by everything and depends on
nothing.** The engine depends on the §2/§3 decisions. Individual actions depend on the engine.
Price changes depend on a chokepoint that does not exist.

**Cut 1 — the record.** Append-only approval log; the four existing decision points
(`decide_leave_request`, `decide_medical_claim`, `approve_review`, and PO creation's implicit
auto-approval) write to it. **No behaviour changes, no gating.** Ships Doc 1's audit trail, is
independently useful, and cannot break anything because nothing reads it yet. Also the cheapest
place to discover the shape is wrong.

**Cut 2 — the engine, one action.** Requires the §2/§3/§4 decisions first. Config table (action,
threshold amount **and currency**, level-1 approver rule, level-2 approver), the resolution
function, and **purchase orders only** — the action Doc 1 names as the painful one, with the column
already reserved. Includes flipping `approval_status`' default and dealing with the existing rows.
Delegation lands here **if §3 chooses a person**.

**Cut 3 — payments and expense claims.** Both already carry `amount_base`; both already run through
one RPC. Little new thinking, mostly wiring, once cut 2 has proved the engine.

**Cut 4 — the two that do not fit the amount rule.** Stock write-off and price changes:
unconditional approval rather than threshold, and **price changes need a chokepoint built first**
(an RPC to replace the plain UPDATE, or a trigger-based hold). This is the cut most likely to
need its own scoping.

**Deliberately not scheduled:** folding the HR chains in (§7), and the org chart as a prerequisite
project (§2) — which becomes cut 0 if and only if §2 chooses org-chart routing.

---

## The decisions this document is waiting on

1. **§2** — supervisor by role, by org chart, or role-then-named-person?
2. **§3** — who is "CFO": new role, `gm`, or Tim by name? (Determines whether delegation is cut 2.)
3. **§4** — threshold amount **and its currency**; and confirmation that the document's own recorded
   rate is the right one to compare with.
4. **§5** — does a PO whose value rises past the threshold need re-approval?
5. **§7** — accept two mechanisms with one shared audit trail, or insist on one engine now?
