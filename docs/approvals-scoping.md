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

## 3 · Who is "CFO"? — **DECISION** — ⚠️ **SUPERSEDED 2026-08-30 (CHAIN-BUILD-1)**

> ⚠️ **SUPERSEDED — 2026-08-30, by Tim's ruling, implemented in CHAIN-BUILD-1.**
> **The ruling: BOTH approval levels point at a ROLE. Level 2 takes a role code
> (`finance_settings.approval_level2_role_code`); the `approval_level2_user_id`
> column has been RETIRED.** A `cfo` role is therefore expected, not avoided.
>
> **Why this section's argument no longer holds.** Its case against a `cfo` role
> rested on two legs, and **both are gone**:
> * *"a one-member role puts a fiction in the permission matrix"* — outweighed by
>   the ruling that the chain must never name a person, so that the chain survives
>   the person leaving;
> * *"naming a person is what **forces delegation to exist**"* — **this reason is
>   void**: delegation was considered and **deliberately ruled out** (no deputy, no
>   escalation, no break-glass). A justification whose whole force was "it makes us
>   build delegation" cannot survive the decision not to build delegation.
>
> **The original text below is kept, not deleted** — it is the record of what was
> decided on 2026-08-09 and why. Read it as history, not as instruction.
> The consequence that replaces it (approvals stall by design when a level has no
> able holder) is written in `docs/approvals.md`.


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

---

# THE FIVE DECISIONS — MADE 2026-08-09. Later cuts read these, they do not re-open them.

| # | question | **decision** |
|---|---|---|
| 1 | who is "the supervisor"? | ⚠️ **SUPERSEDED 2026-08-30 (CHAIN-BUILD-1)** — the mechanism (**routes by ROLE**) stands and is unchanged; what changed is that it is now **both** levels, not just this one. Original text: *"level 1 routes by ROLE. Not the org chart — see §2: it does not exist yet, and building it is a prerequisite project, not a design choice"* |
| 2 | who is "CFO"? | ⚠️ **SUPERSEDED 2026-08-30 (CHAIN-BUILD-1) — REVERSED.** **Level 2 now routes by ROLE**, via `approval_level2_role_code`; `approval_level2_user_id` is **retired**. Its stated reason is **void**: naming a person was justified by "it forces delegation to exist", and **delegation has since been deliberately ruled out** (no deputy, no escalation — see `docs/approvals.md`). Original text: *"level 2 routes to a NAMED PERSON, configured as a `user_id`. Not a new `cfo` role: a one-member role puts a fiction in the permission matrix. Naming a person is also what forces delegation to exist rather than leaving it optional"* |
| 3 | the threshold | lives in **`finance_settings`**, compared in **BASE currency** using **the document's OWN stored rate**. **Its value is still open** — the mechanism is decided, the number is not |
| 4 | an amendment that raises the amount past the threshold | **voids the approval and re-routes.** (Answers §5's open question: approval is a decision about a specific value, not about the document in general) |
| 5 | do the HR chains fold in? | **no — they keep their own engines, but they WRITE TO THIS LOG.** One trail, several engines |

**Consequence of decision 2 that must not be lost:** because level 2 is a person rather than a role,
**delegation is required in the cut that builds the engine (APR-2)**, not deferred. One named human
on a plane otherwise stops every above-threshold purchase, and the workarounds people invent —
sharing a password, or splitting a purchase into two under-threshold POs — are worse than no
control.

**Consequence of decision 3:** the threshold is a `(amount, currency)` pair in config, never a bare
number. See §4 for why the currency is not optional.

**Consequence of decision 4:** the engine needs to know an amount changed. For purchase orders that
means watching `estimated_total_ccy` — which moves when lines are edited — so the re-route trigger
is on the line total, not on the header.

---

# APR-1 — the approval log (BUILT 2026-08-09)

Nothing is gated and no behaviour changed. The log records; it does not decide.

## The subject: `(subject_type, subject_id)`, not a nullable-FK XOR — and what that costs

**Reported before choosing, as asked.** The repo's established pattern is a nullable-FK XOR with
`num_nonnulls(...) = 1`; `payment_allocations` runs it four ways
(`sales_record_id` / `inbound_batch_id` / `expense_id` / `purchase_order_id`).

This needs **at least six** now (leave request, medical claim, performance review, purchase order,
payment, expense) and **eight or more** once price changes and stock issue arrive.

| | nullable-FK XOR (8 columns) | `(subject_type, subject_id)` |
|---|---|---|
| referential integrity | **real** — the database refuses a log row pointing at a nonexistent subject | **none** — an orphaned or mistyped reference is undetectable by the FK machinery |
| adding an action | a migration: new column, rewrite the `CHECK`, update the mirror, extend indexes | **data** — one value in the `subject_type` enum |
| shape of a row | 8 columns of which **7 are NULL on every row** | 2 columns, both always populated |
| typo protection | inherent | recovered by `CHECK (subject_type IN (...))` |

**Chosen: the pair, with a `CHECK` enum on `subject_type`.** Three reasons, in order:

1. **At this width the XOR stops paying.** Four columns is a shape; eight columns of which seven are
   always NULL is a table fighting every future action, and every one of those migrations touches a
   mirror the gate compares byte-for-byte.
2. **The FK's main protection is weak HERE specifically.** Its value is catching dangling references
   after a delete — but Principle 7 means these subjects are **soft-deleted**, and the log is
   append-only, so the row it points at does not go away. This is a narrower claim than "FKs do not
   matter": it is that the failure the FK prevents is largely absent from this table's subjects.
3. **The realistic failure is a typo in `subject_type`, and the `CHECK` enum catches exactly that** —
   and it doubles as the resolver source for the UI labels, the same way `operations_now.item_type`
   feeds `check-i18n`.

**What is lost, stated rather than hidden:** nothing stops a `subject_id` that resolves to no row.
**The compensating control is that there is exactly one writer** —
`record_approval_decision()` — and it **verifies the subject exists in its named table before
inserting**, refusing by name if not. The door is narrow and it is guarded; but a direct `INSERT` by
a superuser bypasses it, which an FK would not. If the log ever grows past a few hundred rows, a
`gate.py` line asserting every `subject_id` resolves would convert the lost guarantee into a
measured one.

## The amount is frozen at the decision

`amount_ccy`, `currency`, `fx_rate` and `amount_base` are copied onto the log row **as at the moment
of the decision**, all-or-nothing (a `CHECK` forbids a half-populated set). Same reasoning as
FIN-27's committed pricing terms: the document changes afterwards, and the log must answer *"what
was this worth when it was approved"* without joining back to something that has since moved. Under
decision 4 this is also what makes a re-route detectable — the frozen figure is what the new amount
is compared against.

**Subjects with no money carry NULL**, deliberately. A leave request's "amount" is **days**, which
is not money and is not shoehorned into a currency column; a performance review has no amount at
all.

## §4 revisited — the backfill, and why the data argues against it

**The principle in the instruction is right: `decided_at` / `decided_by` are real recorded facts,
and reconstructing a terminal decision from them reads a record rather than inventing one.** What
would be false is any claim of completeness, since overwritten rejections are gone.

**It has almost nothing to act on.** Measured on live, 2026-08-09:

```
leave_requests with decided_at ....... 0   (0 rows in the table at all)
medical_claims with decided_at ....... 0   (0 rows)
performance_reviews submitted/approved 0   (0 rows)
purchase_orders with approved_at ..... 3   (3 of 3)
```

The three HR chains have **no history to reconstruct** — not because it was overwritten, but
because nothing has ever gone through them on live.

The only rows carrying an approval are the **3 purchase orders**, and theirs is **not a decision
anybody made**: `create_purchase_order` stamps `approval_status = 'approved'` plus `approved_at/by`
unconditionally, because the flow does not exist — the mirror says so in as many words. Backfilling
those as `approved` would fabricate a decision, which is the FIN-26 rule (*a fabricated provenance
record is worse than a blank*) and the reason `pricing_formula_history` declined to backfill.

**Resolution: backfill the 3 POs as `auto_approved`, `is_reconstructed = true`, with a note.** That
is neither fabrication nor silence — it records what actually happened (*the system stamped this;
nobody decided it*) and it answers the reader who sees "approved" on the PO screen and an otherwise
empty log. Silence there would read as a broken log.

## §5 — the reviews chain cannot route to anybody (REPORTED, not fixed here)

`is_reviewer_of()` resolves through `current_user_employee()` → `employees.user_id = auth.uid()`.
On live: **1 employee row, 0 with `user_id`, 0 with `manager_id`; 1 department with no manager;
against 14 login accounts holding roles.** The per-person routing is correct code sitting on
unpopulated data.

**An alert IS warranted, and `holiday_calendar_missing` is the right shape** — a missing
configuration that makes a feature silently do nothing, raised where the responsible role will see
it. Proposed for the HR-alerts arm, not built here:

* `employee_not_linked` — an in-register employee with no `user_id`. Severity `warning`; **`expired`
  when that employee is named as a reviewer on a non-terminal review**, because then it is not a
  gap in setup, it is a review that can never be submitted.
* The reason it belongs in `hr_alerts` rather than the dashboard: it is HR's data to fix, and
  `hr_alerts` already carries `system_start_not_set` and `holiday_calendar_missing`, which are the
  same "configuration missing → feature quietly inert" shape.

**Why the log makes this visible:** a decision cannot record an actor who does not exist. Once the
review chain writes to the log, an empty log beside a submitted review is the symptom.

## Not in this cut, and why

* **The missing four-eyes rule on leave and medical claims.** A `module.hr.edit` holder can submit
  on someone's behalf and approve it in the same session; only reviews forbid self-approval.
  Forbidding it needs **somewhere for the HR person's own leave to go** — which is decision 2's
  named approver. **It belongs with the engine (APR-2), not the log.**
* **`void_review`** is a decision that ends a review, and it is not wired to the log in this cut.
  Only the three points named for APR-1 were wired. It is additive whenever wanted.
* **Gating anything.** APR-1 changes no behaviour by construction.

## Two things APR-1 found that APR-2 must not inherit

**1 - `purchase_orders.fx_rate` defaulted to 1 (removed by FIN-35) - but the live PO's 1:1 was NOT the default leaking.** Decision 3 says the
threshold is compared in base currency **using the document's own stored rate**. PO-2026-0001 is
**USD 120,000 with `fx_rate = 1`** - its base value reads 120,000 when the USD mid rate on its order
date was 1.255, so the true figure is about 150,600. **FIN-35 traced it and the APR-1 diagnosis above
was wrong**: the PO is dated 2026-07-31, and FIN-0 flipped the base from USD to SGD on 2026-08-04 -
so its 1:1 was CORRECT when written. `create_purchase_order` has always derived the rate from
`fx_rate_for(..., 'tt_sell')` and refuses a caller-supplied one, so the DEFAULT never leaked into it.
What remains true: reading that row today under an SGD base gives the wrong base figure, so APR-2's
threshold must not treat a pre-FIN-0 document as if its stored rate were current.
**APR-2 must refuse or flag `fx_rate = 1` on a non-base-currency document rather than treating it as
a genuine 1:1**, exactly as `fx_rate_for` refuses a missing rate instead of defaulting. Also recorded
in `known-wrong-until-cutover.md`, because the row itself is test data.

**2 - `now()` cannot order an audit log.** Two decisions in one transaction share a `decided_at`, so
"rejected then approved" and "approved then rejected" are indistinguishable by timestamp - and that
ordering is the whole point of the table. `approval_log.seq` (an identity column) is the tiebreaker;
**read the log by `seq`, never by `decided_at`.** Same lesson as `batch_assay_status` using `code` to
break the tie its `created_at` cannot.

**A third, in the gate rather than the data:** `verify_rebuild` sorted its structural fingerprints
with `ORDER BY x` under the scratch cluster's collation (`C`, from `--no-locale`) while live runs
`en_US.UTF-8`. `approval_log` is the first table carrying both an uppercase-leading (`NOT
is_reconstructed ...`) and a lowercase-leading (`amount_ccy ...`) CHECK, so it was the first to make
two structurally identical tables compare unequal. Fixed to `ORDER BY x COLLATE "C"`; fault-injected
afterwards to confirm a genuine constraint difference is still caught and named.

---

# APR-2 — Part A: reported before building

## A1 · Which role approves at level 1? — **DECISION, not picked. The engine reads it from config.**

Routing is by role (decision 1), so a role must be named. `module.purchasing.edit` is held by
`admin`, `finance`, `gm` and `procurement` — and **`procurement` is the role that raises POs**, so it
cannot also be the approver without defeating the point.

| candidate | what it implies |
|---|---|
| **`finance`** | **segregation of duties**: the party that pays approves the commitment. The classic pattern, and it puts the person who feels the cash-flow consequence in the loop. Against it: finance may have no view on whether the material is *needed*, so approval becomes a budget check rather than a purchasing judgement |
| **`gm`** | closest to Doc 1's word, "supervisor". One person above the requester, judging the purchase on its merits. Against it: at fifteen people `gm` may be Tim, which collapses level 1 into level 2 and makes the two-level design decorative |
| **`admin`** | wrong on principle, for the same reason as §3: `admin` is system administration, not commercial authority |
| **a new `approver` role** | avoids overloading an existing seat, at the cost of another row in the matrix that must be granted to somebody real |

**How this is built without picking:** `finance_settings.approval_level1_role_code` is **NULL** and the
engine **refuses to route** until it is set — `APPROVAL_LEVEL1_ROLE_NOT_SET`. Same discipline as A2's
threshold: *an unset control is not permission to skip the control.*

## A2 · The threshold — the evidence, no proposal

Doc 1 says 10k, written before the scale was known. **Live purchase orders** (base currency, using
each document's own stored rate):

| order | document | base |
|---|---|---|
| PO-2026-0001 | USD 120,000 | 120,000.00 |
| PO-2026-0002 | USD 1,215 | 1,530.90 |
| PO-2026-0003 | USD 5,600 | 7,056.00 |

Three orders is too thin to choose on, so the better proxy is **what has actually been bought** —
the nine priced inbound batches, base currency:

```
2,041.20  2,069.12  2,100.00  7,104.00  10,000.00  13,300.00  30,000.00  40,000.00  48,000.00
```

| threshold | purchases at or above it | share |
|---|---|---|
| **10,000** | 5 of 9 | **56%** |
| **25,000** | 3 of 9 | 33% |
| **50,000** | 0 of 9 | 0% |

**Reading it:** at 10k, *the majority of material purchases* route to level 2 — which is the concern
in the prompt, and it is real rather than hypothetical. At 50k nothing routes to level 2 at all on
current data, so the second level would exist without ever being exercised. 25k puts a third of
purchases through the named approver.

Note the shape of the spend: the three cheapest purchases are ~2k consumables and the rest jump
straight to 7k–48k. **There is no dense middle**, so the threshold is not finely sensitive — anything
between roughly 14k and 29k gives the same 3-of-9 answer. That is worth knowing before agonising
over the number.

**Until it is set, the engine refuses**: `finance_settings.approval_threshold_base` is NULL and
routing raises `APPROVAL_THRESHOLD_NOT_SET`. Same shape as `SYSTEM_START_NOT_SET`.

## A3 · The draft state — a shape change, not a correction

Today `create_purchase_order` writes `status='confirmed'` and `approval_status='approved'`
unconditionally. `'draft'` is a legal value of the CHECK that **nothing has ever written**. So an
order is born confirmed and approved, and there is nowhere for "requester raises" to live.

**What the machine has to become:**

```
create_purchase_order  ->  status='draft'      approval_status='pending'   [log: submitted]
approve_purchase_order ->  status='confirmed'  approval_status='approved'  [log: approved, level]
reject_purchase_order  ->  status stays draft  approval_status='rejected'  [log: rejected]
first receipt          ->  status='receiving'   (advance_po_on_receipt, unchanged)
close / cancel / reopen                          (unchanged)
```

`advance_po_on_receipt` already keys on `status='confirmed'`, so it keeps working with no change —
the new `draft` state simply sits in front of it.

**The three existing rows are left alone.** They are `closed`, `receiving` and `receiving`, all
`approved` — and they are *genuinely* confirmed: goods were received against two of them and one is
closed. Rewriting them to `draft/pending` would assert that real, completed purchases are awaiting
approval. APR-1 already logged them as `auto_approved / is_reconstructed`, which is the honest
record of what happened.

## A4 · What approval actually gates — the question that decides control vs decoration

Three candidates, and they are not equally available:

| what | where the block sits | status |
|---|---|---|
| **Receiving against the order** | `guard_inbound_po_receivable` — a **BEFORE INSERT trigger that already exists** on `inbound_batches` and already refuses `cancelled`/`closed` orders | **GATED** — one predicate added, named `PO_NOT_APPROVED` |
| **Prepaying the order** | `apply_prepayment` and `record_payment`'s PO branch — both already load the PO and both already refuse `cancelled` | **GATED** — same predicate, same name |
| **Sending it to the supplier** | — | **NOTHING TO GATE: the action does not exist.** There is no PDF, no email, no export, no "issue" step anywhere in `app/purchasing`. The order is communicated to the supplier outside the system, which is precisely what Doc 1 complains about ("chasing for manual approvals and signatures") |

**The receiving gate is the one that matters**, and it needed checking rather than assuming:
**receiving is a plain `INSERT INTO inbound_batches` from the app — there is no RPC.** Had the
existing `guard_inbound_po_receivable` trigger not been there, this cut would have had to build a
chokepoint first, exactly as the scoping doc warned for price changes. It is there, so the gate is a
one-line extension of a guard that already has the right shape.

**Without these two, approval would be a status column with a nice screen.** With them, an
unapproved order cannot take delivery and cannot take money — which is the whole of what a purchase
order can do.

## Amendment does not exist — reported, as suspected

There is **no update path for a purchase order or its lines anywhere**: no RPC, no server action, no
form. `app/purchasing/orders/[id]/` offers cancel, close and reopen only. Doc 1 wants change
management with versioning; what exists is create-and-cancel.

So the "amendment past the threshold voids the approval" rule **cannot be triggered by any real path
today**. It is still built here — as a trigger on the amount, not as a hook in a non-existent edit
function — so that whoever builds amendment inherits the rule rather than having to remember it. The
fixture exercises it with a direct `UPDATE`, which is honest about what it is testing.

---

# APR-2 — Part C: reported, not folded in

## Delegation — **next cut, not this one, and the reason is that it is currently unreachable**

Decision 2 said naming a person forces delegation to exist, and that stands. But the condition that
makes it *urgent* is not met yet:

* `finance_settings.approval_level2_user_id` is **NULL** — no level-2 approver is configured, so
  level 2 currently refuses for everyone rather than blocking on one person's availability.
* There is **one human user** on the system. Delegation from Tim to Tim is not a workflow.
* Level 2 only engages above a threshold that is **also unset**. Until A2 is answered, no order
  routes to level 2 at all.

**So the failure delegation prevents — "Tim is on a plane and every large purchase stops" — cannot
happen until the threshold and the level-2 user are both configured AND a second person exists.**
Building it now would be building against a shape (who else can act for Tim) that the org chart
cannot yet express: recall §2's measurement — 1 employee row, 0 with `user_id`, 14 login accounts.

**The trigger to build it is explicit, so it is not left to memory:** *the day
`approval_level2_user_id` is set to a real person, delegation belongs in the very next cut.* Written
here rather than in a commit message because a commit message cannot be re-read by the person who
sets that column.

**What it must not do**, carried forward from §8 so the next cut does not re-derive it: record
"approved by B **as delegate of A**" rather than "approved by B", and never launder the four-eyes
rule — A raising and delegating to B is fine; A approving as B's delegate is not.

## The four-eyes rule on leave and medical claims — **next cut, and now it is unblocked**

A `module.hr.edit` holder can still submit a leave request on someone's behalf and approve it in the
same session. APR-1 deferred this because *forbidding self-approval needs somewhere for the HR
person's own leave to go*.

**That blocker is now removed in principle**: a level-2 named approver exists as a mechanism. But it
is removed in principle only — the column is NULL, so routing an HR person's own leave to the
level-2 approver would refuse today.

**Read: next cut, together with whatever configures the policy values.** Doing it here would mean
either shipping a rule that refuses in a system with one user, or wiring HR into the purchase-order
engine — and decision 5 says HR keeps its own engines. The honest sequencing is: Tim sets the three
policy values, delegation follows because level 2 becomes a real person, and HR four-eyes follows
because it can then route somewhere. All three are gated on the same decision.

**Cheap and worth doing in that cut, noted so it is not lost:** `approve_review` already has
`SELF_APPROVAL_FORBIDDEN` and `decide_leave_request` / `decide_medical_claim` do not. The rule is
three lines each; what it needs is the escape hatch, not the check.

---

# THE POLICY VALUES — DECIDED 2026-08-09, **PENDING CONFIGURATION**

**These are decisions, not proposals. They are deliberately NOT written into
`finance_settings` yet**, so that turning approvals on is one deliberate step rather than a
rediscovery six months from now.

| setting | **decided value** | why |
|---|---|---|
| `approval_level1_role_code` | **`finance`** | segregation of duties: the party that pays approves the commitment. `gm` would likely collapse to Tim, making both levels one person and the two-level design decorative |
| `approval_threshold_base` | **25,000** (base currency) | routes the three largest purchases to level 2; sits inside the flat 14k–29k region measured in §A2 so it carries slack; and avoids 10k's outcome, where **the majority of orders route to Tim — reproducing the very pain the control exists to remove** |
| `approval_level2_user_id` | Tim's `user_id` | decision 2: a named person, not a one-member role |
| `approvals_enabled` | **`false` today** | see below |

## Why the flag exists — three states, not two

**Four-eyes cannot operate with one user.** Tim holds `admin` and is the only human account, so
any requester-is-not-approver rule blocks him entirely. And APR-2's "refuse to route when
unconfigured" would then block purchasing outright. **NULL config plus a hard refusal is the same
outcome as an unusable system** — so "not yet in force" had to become a state the system can *say*,
rather than something disguised as missing configuration.

| state | behaviour |
|---|---|
| **off** (today) | POs are created `confirmed`/`approved`; the log records **`auto_approved`**, not `submitted`, because nobody decided; and **the screen says approvals are not in force** rather than being silently permissive |
| **on, policy unset** | refuse to route — an enabled control with no policy is a misconfiguration, not a state to muddle through |
| **on, policy set** | the engine as built in APR-2 |

**Turning it off does not retroactively approve anything.** Orders raised while approvals were in
force stay `pending` and stay unreceivable. Silently approving them would be a lie about who
decided what.

## What must be true before turning it on

Recorded in `docs/fresh-install-checklist.md` as well, because that is where someone standing up
the system will look:

1. **A second human user account exists.** With one account, four-eyes blocks the only person who
   can act.
2. **Someone holds `finance` who is not the person raising purchase orders.** `procurement` raises;
   if the same human holds both, `SELF_APPROVAL_FORBIDDEN` fires on every order and purchasing
   stops.
3. Then set all four values together — the three policy columns and the flag — in one change.
   Setting the flag without the policy is the "on, unset" state, which refuses.

---

# APR-3 — 上线前的勘察(2026-08-24)。**勘察归勘察,而 SOD-1 在同一天把它建掉了大半**

> **⚠ 本节抬头原本写着「只勘察,没有建任何东西 —— 停闸拦下了这一刀」。那句话已经作废。**
> Tim 在 REVISION 1 里裁定:停闸要拦的是【组合】(跨全库迁移 + 把审批打开),
> **不是任何一半**。于是**部门数据范围停在勘察,审批与职责分离照建** ——
> 见 `db/migrations/2026-08-24-sod1-*.sql`、`db/fixtures/127-*.sql`,
> 以及 `docs/known-issues.md` 里被改窄的四条。**审批【没有】被打开。**

**为什么这一节存在。** `docs/forward-queue.md` 阶段 3 的第 3 件写着「审批开关与职责分离」,
第 4 件写着「部门数据范围」,两件被合成一刀。第 4 件量出来是一次【跨全库的迁移】,
而停闸规定那种形状不许与「把审批打开」装进同一刀 —— **于是第 4 件停在勘察,
第 3 件由 SOD-1 建掉。** 两份勘察都在这里与 `docs/department-scope-survey.md`,
第 4 件的排期归 Tim。

**本节的每一个数字都是 2026-08-24 在【线上】量的,不是从上面几节抄的。**
上面几节写于 2026-08-09,而地面已经动过 —— 尤其是员工↔登录的关联。

## 一 · 审批:**引擎【已经建好了】,缺的是【操作员那一面】**

**这是本次勘察最要紧的一句,而它与队列里那条目的措辞不一致:**

> **「审批开关」不是一件待建的东西 —— APR-1 与 APR-2 已经把它整支建完了。
> 今天缺的是【一个人能不能用它】:批准与驳回这两支函数在 `app/` 里
> 【一个调用方都没有】。**

### 已经在库里的(逐个点名,读的是函数体与 `pg_policy`,不是记忆)

| | |
|---|---|
| `finance_settings` 四列 | `approvals_enabled`(NOT NULL,**默认 false,今天是 false**)· `approval_level1_role_code`(**NULL**)· `approval_threshold_base`(**NULL**)· `approval_level2_user_id`(**NULL**) |
| `approval_log` | 追加型,`(subject_type, subject_id)` 主体对,金额四列冻结在决定那一刻,`seq` 排序。**线上 8 行** |
| `approvals_enabled()` | 读那一列,`COALESCE(..., false)` |
| `approval_level_for(amount_base)` | 阈值未设 → `APPROVAL_THRESHOLD_NOT_SET`;金额为空 → `APPROVAL_AMOUNT_REQUIRED`;`>= 阈值` 归 2 级 |
| `require_approver_for(level)` | 1 级查配置的角色码(未设 → `APPROVAL_LEVEL1_ROLE_NOT_SET`;不持 → `APPROVAL_NOT_AUTHORISED\|1\|<role>`);2 级查具名 user_id(未设 → `APPROVAL_LEVEL2_USER_NOT_SET`;不是本人 → `APPROVAL_NOT_AUTHORISED\|2\|<uuid>`);其余 → `APPROVAL_LEVEL_INVALID` |
| `create_purchase_order` | **开关是它的一个分支**:开 → `status='draft'` / `approval_status='pending'`,日志记 `submitted`;关 → `confirmed`/`approved`,日志记 **`auto_approved`** 并写明「系统直接盖章,没有人做过这个决定」 |
| `approve_purchase_order` | 关着时 `APPROVALS_NOT_ENABLED` · 非 pending `PO_NOT_PENDING` · **四眼 `SELF_APPROVAL_FORBIDDEN`** · 按单据自存汇率折本位币定级 · 走 `require_approver_for` · 推 draft→confirmed · 写日志 |
| `reject_purchase_order` | 同上 + `REJECT_REASON_REQUIRED`,驳回也要走同一道授权 |
| `void_approval_on_amount_increase` | 金额涨过档 → 原审批作废、重新路由,日志记 `approval_voided`;**只在升级时作废**;关着时早退(否则阈值未设会让「改金额」在一个审批没开的库里失败) |
| `guard_po_amendable` | **`status` 与 `approval_status` 不走"修改"这条路** —— 除非 `evoltrya.po_status_ctx='1'`。这就是"一个能把 approval_status 设成 approved 的编辑表单 = 一条不经审批的审批路径"那条规矩的执行处 |
| 三道闸(APR-2 的 A4 + 后来多的一道) | **收货** `guard_inbound_po_receivable` → `PO_NOT_APPROVED`;**预付/付款** `apply_prepayment` / `record_payment` 的 PO 分支;**签发给供应商** `record_po_issue`(APR-2 当时写的是"这个动作不存在",**现在它存在了**,并且已经按名拒未获批的单) |

### 缺的那一面,三件,每一件都点名

1. **【没有批准/驳回的屏幕】—— 这是最硬的一条。**
   `grep -rl approve_purchase_order app/` 与 `reject_purchase_order` 的结果都是**空**。
   `app/purchasing/orders/[id]/page.tsx` 只调 `approvals_enabled()`,渲染一条
   「审批已生效 / 未生效」的状态条,**没有任何控件**。
   **后果说白:今天把开关打开,每一张新单都会停在 `draft/pending`,
   而屏幕上没有任何东西能把它推走** —— 它收不了货(`PO_NOT_APPROVED`)、
   收不了预付、签发不出去。**采购当场停摆。**
   这正是本仓库为「没有入口的页」付过四次账的那个形状,只是这一次
   连页都还没有。
2. **【十一条拒绝没有句子】。** `app/purchasing/purchasingErrorCodes.ts` 里有
   `PO_NOT_APPROVED`,**没有**:`APPROVALS_NOT_ENABLED` · `PO_NOT_PENDING` ·
   `SELF_APPROVAL_FORBIDDEN` · `REJECT_REASON_REQUIRED` ·
   `APPROVAL_THRESHOLD_NOT_SET` · `APPROVAL_AMOUNT_REQUIRED` ·
   `APPROVAL_LEVEL1_ROLE_NOT_SET` · `APPROVAL_LEVEL2_USER_NOT_SET` ·
   `APPROVAL_NOT_AUTHORISED` · `APPROVAL_LEVEL_INVALID` ·
   `APPROVAL_SUBJECT_TYPE_UNKNOWN` / `APPROVAL_SUBJECT_NOT_FOUND`。
   `messages/{en,zh}.ts` 里与审批有关的只有一条 `SELF_APPROVAL_FORBIDDEN`,
   **而它属于 `hr.reviews`,不是采购**。开关一开,操作员看到的是裸管道串。
   (这些码是从函数体里一条条数出来的,不是从撞到过的那几条数的。)
3. **【仪表盘那一格还是三态里的第一态】。** `docs/dashboard-arm-inventory.md`
   第 324 行那一节记着:开关关着时「待批 0」这个 0 的意思是**审批不在生效中**,
   不是"没有人在等" —— 这已经是"受限不是零"的第四件衣服。那一格**还没有建**,
   而它要的是三态,不是两态。

## 二 · 把开关打开会发生什么(**报告,不执行 —— 本刀没有打开它**)

**今天的实测状态:`approvals_enabled = false`,另外三列全是 NULL,
线上 7 张采购单,`approval_status='pending'` 的有 0 张,`approval_log` 8 行。**

**只把 `approvals_enabled` 设成 true 而不设那三列**,是文档里写的「on, policy unset」
那一态,而它的实际行为量出来是这样:

* 新建采购单**成功**,落成 `draft/pending`(`create_purchase_order` 不查阈值);
* **随后一切与它有关的动作全部失败**:批准/驳回会走到 `approval_level_for`,
  阈值为 NULL → `APPROVAL_THRESHOLD_NOT_SET`;
* 那张单**收不了货、收不了预付、签发不出去**(三道闸都要 `approved`);
* 而且**没有屏幕能批它**(见上面第 1 条)。
* **改一张已批单的金额也会失败** —— `void_approval_on_amount_increase` 会早退,
  这一条是安全的;但它早退的判据是 `approvals_enabled()`,一旦开了就不再早退,
  于是阈值未设时「改金额」也开始抛 `APPROVAL_THRESHOLD_NOT_SET`。

**四个值一起设(`docs/fresh-install-checklist.md` 第 8 条写的那一段)之后**:

* 1 级路由到 `finance`。**线上持 `finance` 的真人账号只有一个:`chef1949@126.com`,
  而它 `last_sign_in_at` 是 NULL —— 从来没有登录过。**
* 2 级路由到 `approval_level2_user_id` 那个具名的人(Tim)。
* **四眼会当场咬人:** `finance` 这个角色同时持 `module.purchasing.edit`,
  也就是说持 `finance` 的人**自己也能开单**;他开的单他自己批不了
  (`SELF_APPROVAL_FORBIDDEN`),而今天**没有第二个持 `finance` 的人**。
* `admin` 同时持采购与财务的编辑权,所以 Tim 用 admin 开的单,
  1 级也只能由 `finance` 批 —— 而那个人没登录过。

> **结论一句话:今天打开开关,采购会停摆,而停摆的第一因不是策略没配好,
> 是【没有那块屏幕】。** 先补屏幕与句子,再谈配置;配置本身还等着
> `docs/approvals-scoping.md` 上面那一节列的两个前置(第二个真人账号、
> 一个持 `finance` 而不开单的人)。

## 三 · 在飞的单据:**今天没有,而这正是现在动手最便宜的原因**

`approval_status='pending'` 的采购单 **0 张**。线上 7 张单全部是 `approved`
(其中 3 张由 APR-1 补记成 `auto_approved / is_reconstructed`)。
**所以"打开开关会不会把在飞的单据晾在半路"这个问题,今天的答案是不会** ——
没有在飞的。**这是一个会随时间变坏的答案**:同事账号一发、开始有人开单,
每一张新单都是一个潜在的在飞单据。

**反方向也要说清(文档已有的一句,勘察复核成立):关掉开关【不会】追认任何东西。**
开着的时候提的单仍然 `pending`、仍然收不了货。**要让它们走完,只有把开关再打开、
把策略配好、由人一张张批** —— 所以"先开一下试试再关掉"不是一次可回退的试验。

## 四 · 职责分离:**它【不是】审批开关的一个侧面,而是四件独立的事**

队列把两件写成一条「审批开关与职责分离」。勘察结论是**这条合并把后者说小了**:
审批引擎只答了下面第 1 行,其余三行**与审批引擎完全无关**,各自要各自的机制。

**测法:两个动作各自要哪一条权限码,以及【今天哪些角色同时持有它们】。**
角色→权限量自 `role_permissions`;人数量自 `user_roles`(真人账号 2 个:
`admin@swm-os.test` = admin,`chef1949@126.com` = finance;其余 70 个 admin
是冒烟/走查留下的一次性账号)。

| # | 一个人能不能从头做到尾 | 两端各要什么 | **今天同时持有的角色** | 判词 |
|---|---|---|---|---|
| 1 | **开单 → 批单** | `module.purchasing.edit` → 配置的 1 级角色 | admin · finance · gm · procurement 都持 `module.purchasing.edit` | **开关关着时:能,而且是【一个动作】** —— `create_purchase_order` 自己盖章。**开关开着时:不能** —— `SELF_APPROVAL_FORBIDDEN` + `require_approver_for`,而且 `guard_po_amendable` 堵死了绕过函数直接改 `approval_status` 的路 |
| 2 | **建供应商 → 付钱给他** | `module.suppliers.edit` → `module.finance.edit` | **admin · finance · gm** | **能,端到端,没有任何东西拦。** 而 `finance` 正是被裁定的 1 级审批角色 —— 也就是说未来那位审批人自己就能造一个收款人并付款 |
| 3 | **过账 → 关账** | `module.finance.edit` → `module.finance.edit`(`close_period` / `close_financial_year` 同一条码) | **admin · finance · gm** | **能。两端是同一条权限码**,`close_period` 除了「借贷平」「折旧已跑」之外没有任何"谁"的判据 |
| 4 | **工资过账 → 发工资** | `post_payroll_period` = `module.hr.edit` → `pay_payroll_lines` = `module.finance.edit` **OR** `module.hr.edit` | **hr 一个角色就够**(admin · gm 也够) | **能,而且只要一条 hr 权限。** 那个 `OR` 是这一行的全部原因 |
| 5 | **(附)提假条/报销 → 自己批** | `module.hr.edit` 两端 | **hr · admin · gm** | **能。** 三条 HR 链里只有绩效评估有四眼(`SELF_APPROVAL_FORBIDDEN`),请假与医疗报销没有 —— 这是 APR-1 就点过名、一直留到"下一刀"的那一条 |

### 这四件在【数据库里】拦得住吗 —— 逐条量过,答案是能,而且材料已经在

5.2 要求「不能只在屏幕上拦」,理由是 GO-2 实测过 `authenticated` 手里握着表权限,
一条直连的写入绕得过 server action。**本次复核了那句话,它仍然成立,而且更具体:**

```
authenticated 对这些表的表权限(information_schema.role_table_grants):
  purchase_orders   INSERT UPDATE DELETE        payments  INSERT UPDATE DELETE SELECT
  suppliers         INSERT UPDATE DELETE SELECT journal_lines / journal_entries 同上
  finance_settings  INSERT UPDATE DELETE SELECT approval_log INSERT UPDATE DELETE
```

**唯一挡在前面的是 RLS 与触发器,不是 server action。** 逐条查过 `pg_policy`:

* `purchase_orders` 有 UPDATE 策略 `has_permission('module.purchasing.edit')` ——
  **也就是说开单的人本来可以直连把 `approval_status` 改成 approved**;
  **拦住它的是 `guard_po_amendable`**,不是策略。这条已经建好了,复核通过。
* `approval_log` **没有 INSERT 策略**(RLS 默认拒),UPDATE/DELETE 由
  `guard_approval_log_append_only` 拒 —— 直连伪造一条审批记录走不通。**已经关上。**
* `payments` **没有 UPDATE/DELETE 策略** —— 已经关上。
* `finance_settings` 的四条策略全是 `module.finance.edit`。
  **所以持 `module.finance.edit` 的人可以直连把 `approvals_enabled` 改掉** ——
  包括把它关掉。**这是一处开着的口子,而且它开在这次要动的那个开关上。**
  它没有被本刀关上,因为关它要先裁一件事:**审批开关归谁改?**
  `action.manage_permissions`(今天只有 admin)是最像的答案,但那是一条
  【新规矩】,而不是一次补漏 —— 与 `JE-APPEND` 那一条不在 GO-2 里做是同一个理由。

**做第 2–5 行需要的"谁做的"那一列,库里【已经有了】**,所以它们不是数据结构问题:
`suppliers.created_by` · `payments.created_by` · `journal_entries.created_by` ·
`period_closes.closed_by` · `payroll_periods.created_by` ·
`leave_requests.created_by/decided_by` · `medical_claims.created_by/decided_by` ·
`purchase_orders.created_by/approved_by`。**每一条都在。**

### 但有一件必须先裁,否则第 2–5 行【建出来就是坏的】

> **今天只有两个真人账号。** 任何"A 做的事 B 才能做"的规矩,在两个人的系统里
> 都会立刻把某条路堵死 —— 这正是 `approvals_enabled` 这个开关当初被造出来的理由
> (「四眼在一个人的系统里没法运转」)。
>
> **所以第 2–5 行要么各自带一个开关,要么与审批共用同一个开关,要么等到
> 十三位同事的账号发下去之后再上。这是一个排期决定,归 Tim。**

## 五 · 十三位同事这件事,对本项【什么必须先成立、什么可以等】

| 必须在账号发出去【之前】 | 可以等 |
|---|---|
| **十一条拒绝的中英句子** —— 账号一发就有人会撞上采购的拒绝路径,而今天撞上就是裸管道串 | 委托(delegation):`approval_level2_user_id` 还是 NULL,2 级今天对所有人都拒,**没有"Tim 在飞机上"这个故障可以发生** |
| **批准/驳回那块屏幕** —— 只要开关有可能被打开,没有屏幕就是采购停摆 | 仪表盘那一格的三态 —— 它是可见性,不是可用性 |
| **决定审批开关归谁改**(见上,`finance_settings` 那处口子) | 第 2–5 行的职责分离机制本身,**只要它们的开关状态是被写下来的** |
| **HR 三链的四眼**?—— **不必须**:今天 hr 角色 0 人;它变成必须的那一刻,是第一个持 `module.hr.edit` 的同事拿到账号 | 部门数据范围(见另一份勘察,而且它被停闸拦下了) |

## 五之二 · 直连写入的探针 —— **实测,全部回滚(2026-08-24)**

上面第四节那张表里的判词,凡是与"绕过 server action 直连写"有关的,都不是从
`pg_policy` 推的,是**以一个真实的 `authenticated` 会话跑出来的**
(`SET LOCAL ROLE authenticated` + `chef1949@126.com` 的 `sub`,整支在一笔
必然回滚的事务里,`RAISE EXCEPTION 'PROBE_REPORT …'`)。

| 探针 | 结果 |
|---|---|
| **P1 · 直连把 `approvals_enabled` 从 false 改成 true** | **ALLOWED** —— 事务内读回 `true`。持 `module.finance.edit` 的人可以自己把审批打开,**也可以把它关掉** |
| **P2 · 直连把一张 `pending` 的采购单改成 `approved`** | **REFUSED** —— `PO_STATUS_NOT_AMENDABLE\|approval_status\|pending\|approved`。`guard_po_amendable` 顶住了 |
| **P2b · 直连改 `status`** | **REFUSED** —— `PO_STATUS_NOT_AMENDABLE\|status\|closed\|confirmed` |
| **P3 · 直连往 `approval_log` 插一条伪造的"已批准"** | **REFUSED** —— `new row violates row-level security policy for table "approval_log"`(没有 INSERT 策略 = 默认拒) |
| **P4 · 以 `finance` 建一个收款人** | **ALLOWED**,并且同一个会话读出 `module.suppliers.edit=true` · `module.finance.edit=true` · `module.purchasing.edit=true` · `module.hr.edit=false` |

> ### P2 第一次跑出来是【ALLOWED】,而那是一次问错了问题
>
> 第一版探针挑的是「最早的那张采购单」,而**它本来就已经是 `approved`** ——
> 于是 `NEW.approval_status IS DISTINCT FROM OLD.approval_status` 恒为假,
> 守卫**正确地**放行了一次什么都没改的更新,而探针把那个"放行"读成了"绕得过去"。
> **一个绿灯的判据,答的不是它标签上写的那个问题** —— 这与本仓库记过的
> `! pgrep`、`?sha=` 缩写、启动器的退出码是同一族。
> 第二版先把那张单**造成 `pending`** 再打,才问到了标签上写的那句话。
> **写下来是因为它差一点就变成一条"守卫形同虚设"的假结论。**

**P4 顺带撞出一件必须点名的事:被裁定为 1 级审批角色的 `finance`,
自己就持 `module.purchasing.edit`。** `docs/fresh-install-checklist.md` 第 8 条的
前置 2 说的是「持 `finance` 的人不能是开单的那个人」—— 那是一句关于**人**的话;
而**角色本身**有开单的权限,所以那条前置只能靠人事安排守住,守不住的时候
`SELF_APPROVAL_FORBIDDEN` 会替它挡下同一个人开又批的那一种,**但挡不住
「持 finance 的甲开单、持 finance 的乙批」这种同一职能内部的互批**。
这是不是可接受,是一个业务判断,**没有裁**。

## 六 · 本节【没有】做的事,以及为什么

**这一节【本身】一行代码都没有写 —— 它是勘察。** 而在它报上来之后,
Tim 裁定停闸拦的是【组合】,于是同一天的 SOD-1 按这份勘察把第 3 件建掉了。

**所以现在的分界是:**

* **本节 = 那一天的地面**(逐条实测,数字都是线上量的)。它【不】被改写成交付记录 ——
  一份勘察的价值正在于它记着"动手之前是什么样";
* **第 3 件已划掉**(`docs/forward-queue.md`),建成了什么写在那里与
  `docs/known-issues.md` 的四条里,**本节不复述**;
* **第 4 件仍未动手**,全文在 `docs/department-scope-survey.md`。

**本节点出来的三件,SOD-1 逐件的下落:**
① 批准/驳回没有屏幕 → **建了**;② 十一条拒绝没有句子 → **补了十九条**
(比这里数出来的多两条,差额的原因记在 `APPROVALS-NO-SENTENCES` 条);
③ 仪表盘那一格的三态 → **没建**,`/finance/settings` 上换成了一块只读的状态面板。
