# Department data scope — SURVEY ONLY, and the answer is: this is a phase, not a cut

**Status: SURVEYED 2026-08-24 (APPROVALS-SOD). Nothing is built. Nothing should be built until
the sequencing decision below is made.**

This document exists because the survey's answer changed the shape of the work. Doc 2 describes
the ownership dimension as **already carried by the data layer**, and Doc 3's Final Phase is
written on top of that sentence — "activated through the RLS hooks already in place". The measured
answer is that **there are no hooks**, and the difference between "activate a dormant dimension"
and "add a dimension to every business table" is the difference between a cut and a phase.

`docs/as-built-divergences.md` §1 is the register entry for the divergence itself and states the
verdict (**DOCUMENT WRONG**). **This file is the sizing**, and it does not restate §1's argument.

---

## 1 · The measurement

Taken against the live catalog on **2026-08-24**, all read-only.

| question | measured |
|---|---|
| RLS policies on live | **447** |
| …that reference a department in `USING` or `WITH CHECK` | **0** |
| Base tables in `public` | **148** |
| …with RLS enabled | **148** |
| Soft-deletable business tables (`deleted_at` present) | **40** |
| …that carry `department_id` | **1** — `employees` |
| Tables carrying `created_by` | **98** |
| `departments` rows on live | **1** |
| Employees with a `department_id` set | **1 of 6** |
| Columns named `entity`, anywhere in the schema | **0** |

**Where `department_id` actually appears**, in full, so the number above is a list rather than a
count: base tables `employees` and `employment_history`; views `employees_masked`,
`employment_history_masked`, `employee_directory`, `leave_calendar`. **Every one of them is HR.**
It is an org-chart field consumed by HR and by review routing. **No RLS policy anywhere filters on
it**, which is the whole finding.

**The 40 business tables**, named rather than counted, because "40 tables" is a number somebody
will argue with and a list is a thing somebody can check:

> assay_results · bank_import_profiles · bank_statements · company_compliance · containers ·
> customer_attachments · customers · departments · employees · finance_attachments ·
> forwarder_rate_quotes · freight_documents · fx_rates · inbound_batches ·
> lane_document_requirements · lanes · leave_grants · leave_requests · material_attachments ·
> materials · medical_claims · metal_prices · output_batches · payment_term_templates ·
> payroll_periods · ports · pricing_formulas · processing_cost_entries · processing_runs ·
> purchase_orders · quotes · review_cycles · roles · sales_orders · stocktakes ·
> supplier_attachments · supplier_compliance · suppliers · tasks · training_records

---

## 2 · Why this is a phase and not a cut — four costs, each measured rather than felt

**1 · It is a migration across every business table.** Not "add a column": a column, a backfill
policy, an RLS predicate, a mirror update, and a `check_mirrors` byte-comparison **per table**.
The repo's own rule — *any migration that touches a table must update that table's mirror in the
same commit* — means the mirror work scales with the table count, not with the idea.

**2 · The dimension has one row, so there is nothing to scope BY.** `departments` holds **1**
record and **1 of 6** employees points at it. A scoping dimension with one value partitions
nothing: every predicate would evaluate to the same answer for every row, and the first honest
test of the feature would be indistinguishable from the feature being absent. **Populating the org
structure is a prerequisite project with real decisions in it** (which departments exist, who is
in them, what a row's department *means* when the row is a purchase order rather than a person) —
the same shape §2 of `docs/approvals-scoping.md` found for the reporting line, and reached the same
conclusion about.

**3 · The hardest question is not technical and has not been asked.** For `employees`, a row's
department is obvious. **For a purchase order, a batch, a journal line or a stocktake it is a
policy question**: is the owning department the one that raised it, the one that consumes the
material, the one that carries the cost, or the one that holds the counterparty relationship?
Those four answers disagree on real rows, and **the schema cannot be designed until the question
is answered**, because a column called `department_id` that means a different thing on each table
is worse than no column at all.

**4 · The blast radius is every read path, and the failure mode is silent.** `AGENTS.md` records
this disease at length under `xmodule`: a row-scoping predicate that drops rows does not raise an
error — an inner join loses the row, an outer join nulls it, an aggregate counts it as zero.
**Five invoker views were already wrong on live for exactly this reason before OPS-14**, and that
was without any department predicate existing. Adding a second row-scoping dimension across 40
tables multiplies that surface rather than adding to it.

---

## 3 · What this does NOT say

* **It does not say the dimension is a bad idea.** Doc 1 selected ownership by department/function
  and that selection is not being reopened here.
* **It does not say nothing can be scoped before it.** Approvals and segregation of duties are
  both **independent** of it — neither needs a department predicate. **Note what that sentence
  does not claim: this cut built neither.** The stop-gate below fired first, so both items are
  surveyed and unbuilt; the approvals/SoD survey is `docs/approvals-scoping.md` §APR-3.
* **It does not say the work is large because the code is bad.** The code is consistent; the plan
  simply recorded a foundation that was never poured, and every later plan stood on it.

---

## 4 · The forcing fact, and what it does and does not force

**Roughly thirteen colleagues receive accounts before cutover.** That is what pulled this item
forward out of "event-driven" in the first place.

**What it forces:** the question *who sees which rows* becomes live the day those accounts exist,
because until now the system has effectively had two human users.

**What it does NOT force:** it does not force *this* answer. Module access (`module.<x>.view|edit`)
plus column masking by data class already answers "may you enter this module" and "may you see this
column" for all thirteen. **Row scoping answers a third question — "is this row yours" — and
nothing measured says that question must be answered before cutover** rather than after. Deciding
that it must is a business call, and it is the call this document exists to inform.

**Stated plainly, because it is the sentence a reader wants:** thirteen people can be given correct
module-and-column access today with no department dimension at all. What they cannot be given is
*departmental* separation within a module — a purchasing person seeing only their own department's
orders. **Whether that is required at fifteen people is Tim's judgement, not a measurement.**

---

## 4b · The stop-gate fired (2026-08-24) — **and it stopped THIS item only**

The APPROVALS-SCOPE cut carried an explicit gate: *if department scope measures as a cross-table
migration rather than a contained change, stop and report both surveys before building either;
do not start a migration across every business table inside a cut that also turns approvals on.*

**It measures as a cross-table migration** — §1 and §2 are the evidence — **so the gate fired.**

> **What the gate stopped, corrected 2026-08-24 (REVISION 1).** This section first read "so nothing
> was built, in EITHER item". **Tim ruled that the hazard the gate names is the COMBINATION** — "do
> not start a migration across every business table *inside a cut that also turns approvals on*" —
> **not either half on its own.** So: **department scope stops here, at the survey. Approvals and
> segregation of duties were built** (SOD-1, 2026-08-24), and they touch no department predicate.
> The sentence is corrected rather than annotated, because this is the file a reader trusts on the
> sequencing.

Consequences for **this** item, stated so no one reads this file as a plan that was executed:

* **No migration toward a department dimension was written or applied.** SOD-1's migrations exist and
  are unrelated to it: they add a segregation-of-duties predicate and two guards on the approvals
  switch, and not one of them references a department.
* **`docs/forward-queue.md` Phase 3 item 4 is NOT struck** (item 3 *is* — SOD-1 built it). Striking an item that was only
  surveyed would be the "a strike-through hiding a live item" defect the queue's own rules name.
* **The approvals switch was NOT flipped.** `finance_settings.approvals_enabled` is still `false`
  and the three policy columns are still NULL.

### The scale, in the two numbers that decide it

| | |
|---|---|
| RLS policies that would have to be re-asked | **447**, of which **362** are `has_permission(...)` predicates |
| RLS policies that mention a department today | **0** — measured by scanning the whole of `pg_policy`, so the zero is a measurement, not an absence |

### The five decisions this is waiting on — **none of them made**

1. **Sequencing.** Before the thirteen accounts, or after? (Survey's reading: after — §4 and §5.)
2. **Semantics.** Is a department a **wall** (you cannot see other departments' rows) or a
   **default filter** (you see yours first, and may widen)? The two differ by an order of magnitude
   in cost and are not the same feature.
3. **What a row's department MEANS, per table family** — §2's question 3, which is the one that
   cannot be deferred past step 0.
4. **Rows with no department**: visible to everyone, or to no one? Getting this default wrong fails
   in one of two total directions — an empty system, or a dimension that does nothing.
5. **The exception list** — which tables are deliberately NOT scoped (the general ledger? the
   dictionaries? the permission matrix? the sequences?). A list a person writes, not a rule.

---

## 5 · If and when it is scheduled — the order the measurement implies

Recorded so the next reader inherits the sequencing rather than re-deriving it. **This is not a
plan being proposed for now; it is the shape the survey found.**

0. **Answer §2's question 3** — what a row's department *means*, per table family. Without this
   there is nothing to migrate toward.
1. **Populate the org structure** — departments, and every employee's place in one. Prerequisite,
   not a design choice.
2. **One table family, end to end** — column, predicate, mirror, view, fixture, screen — chosen so
   the answer to §2.3 is least ambiguous there. Prove the shape before repeating it 39 times.
3. **The remaining families**, and only then.
4. **The entity/multi-entity dimension is a SEPARATE and larger question** and must not be folded
   in: `entity` exists on **zero** tables, there is one chart of accounts and one base currency,
   so Doc 3 Phase 3's "two sets, SG/EU" is a schema change before it is a report.
