# Compliance — scoping (CMP-1: company and supplier qualifications, with expiry)

**Status: REPORT ONLY. Nothing is built — A3 is Tim's question and it gates the build.**
First piece of Phase 5, chosen because it is the only remaining gap that waits on neither headcount
nor scale: a licence expiring stops the business at any size.

---

## A1 · What `supplier_compliance` actually holds today

**The table** (predates the migration+mirror convention; mirror reconstructed from live 2026-07-31):

```
supplier_id  → suppliers (ON DELETE CASCADE — note: the only CASCADE onto a business table)
cert_type    text NOT NULL   — FREE TEXT, no CHECK. The UI offers: Basel Convention /
                               Article 18 / NEA Import Permit / GWDF Licence / TFS Document / 其他
cert_no, issuing_body, valid_from, valid_until   — all nullable
document_id  uuid            — NO foreign key, and NOTHING writes it: the compliance form
                               has no upload; supplier_attachments exists (2 rows) but the
                               two are not connected
notes, soft delete, audit columns
```

Doc 2's five instruments (Basel / Article 18 / TFS / NEA / GWDF) appear **only as UI dropdown
options** — the database accepts any string.

**Live contents: three rows, one in-register.**

| cert_type | valid_until | state |
|---|---|---|
| Basel Convention | — (never set) | soft-deleted |
| Basel Convention | 2027-06-02 | soft-deleted |
| **Article 18** (Shanghai Yidong Battery Recycle Co.) | **2024-03-02** | **in register, EXPIRED ~2.5 years** |

**What `valid_until` is doing: nothing.** It has a partial index (`idx_compliance_valid_until WHERE
deleted_at IS NULL`) and **no reader** — no view, no alert, no dashboard arm, no screen except the
supplier-edit panel that displays the raw rows. The dashboard scoping's finding is confirmed and
can be sharpened: **the one in-register certificate on live has been expired since March 2024 and
nothing anywhere says so.** That is the exact defect this cut exists for, already present in the
data.

Also worth carrying into the build: `cert_type` free text means an expiry rule keyed by type
("block when *Article 18* is expired") is currently unenforceable — `"article 18"`, `"Art. 18"` and
`"其他"` are all legal. A CHECK (or a reference table) comes with CMP-1.

## A2 · Company qualifications do not exist — confirmed, and they need their own table

Checked, not assumed: no table in `public` matches licence/qualification/permit/certificate except
the supplier ones; `company_profile` (1 row) carries identity, contact, banking and the logo — no
licence-shaped column anywhere; no settings table holds one.

**Own table, agreeing with the read in the brief.** A licence has a number, an issuer, a validity
window, a scope and a document — none of which is profile-shaped, and `company_profile` is a
single-row table where a company holds **several** licences (hazardous-waste storage, NEA
collector/transporter classes, fire safety, …). Squeezing a one-to-many with expiry into a
single-row profile would repeat the mistake `supplier_compliance` avoided.

The natural shape is `company_compliance` mirroring `supplier_compliance` minus `supplier_id`, with
two corrections learned from the older table: **a typed `cert_type`** (CHECK or reference table)
and **a real attachment link** (the `document_id`-points-nowhere defect not copied). Same
module-permission question as Part C, because no compliance module exists.

## A3 · The unanswered question — what would blocking attach to? **TIM'S DECISION**

Doc 1 asks: *"For hazardous-waste intake, what hard requirements apply to supplier qualifications?
Should the system block a purchase order when qualifications are expired?"* Four attachment points
exist in the code today, and they mean different things in practice:

| attach to | chokepoint (exists today) | what it means in practice |
|---|---|---|
| **raising** the order | `create_purchase_order` | the earliest gate: you cannot even record the intention. Harshest — it also blocks orders placed *during* a renewal that will complete before delivery, which is the normal case for annual permits |
| **approving** it | `approve_purchase_order` | the human decision point — the natural place for *judgement* (approve knowing the permit renews next week). **Caveat: this gate is currently inert** — `approvals_enabled` is off, so a rule attached only here blocks nothing today |
| **issuing** the document | `record_po_issue` | blocks the commitment from reaching the supplier. Meaningful if the regulator cares about what was *contracted* |
| **receiving** against it | `guard_inbound_po_receivable` (BEFORE INSERT trigger — receiving is a bare INSERT, this is the only choke) | the physical intake — the only gate whose wording matches Doc 1's own ("hazardous-waste **intake**"). Blocks the truck at the gate, regardless of when the order was raised and regardless of the approvals flag |
| *(a fifth, for completeness)* payment | `record_payment` / `apply_prepayment` | money is not intake; listed only because APR-2 gated these — probably not the regulator's concern |

**The trade stated plainly, no pick:** gates early in the chain (raise/approve) prevent *planning*
around a renewal in progress; the receive gate is the only one that maps onto the physical event a
regulator inspects, and the only one that catches a qualification that expires **between** ordering
and delivery — which, with annual permits and multi-week shipments, is the realistic failure. But a
receive-only block means the refusal arrives at the worst moment logistically (goods at the door).
Blocking at two points (warn early, hard-stop at receive) is a legitimate answer too.

**The answer also differs by instrument** — which is why this is not pickable here: an expired
*import permit* (NEA) plausibly hard-stops intake; an expired *quality* certificate (ISO) plausibly
warns and never blocks. So the decision is not one switch but a per-`cert_type` disposition:
**block / warn / ignore, per instrument** — one more reason `cert_type` must become typed (A1).

## B · The alert shape — the precedent transfers cleanly

`hr_alerts` is the template: **warning at a distance, escalating as the date approaches, clearing
when fixed.** `work_pass_expiry` / `training_expiry` are literally this rule for a different
document class (30/90-day windows, `expired` grace of −30 days, only in-register rows).
`holiday_calendar_missing` adds the "configuration absent" variant, which maps to *"this supplier
has NO Basel certificate at all"* — absence, not expiry, and it needs its own arm exactly as
`awaiting_assay` is distinct from `assay_unapplied`.

Two lessons to carry, both already paid for:

* **OPS-14's permanent light:** `system_start_not_set` false-alarmed forever for the `hr` role
  because the row that could clear it was invisible to the reader. The compliance alert must be
  readable by the role that can *fix* it (whoever edits supplier records — `module.suppliers.edit`
  holders), and its clearing condition must be observable to the same reader.
* **The −30-day floor:** `work_pass_expiry` drops off after 30 days overdue — "that is no longer a
  reminder but history". For a *blocking* instrument that floor is wrong: an expired Article 18 is
  not history while intake from that supplier is still possible. Live proves it — the one
  in-register certificate is 2.5 years expired and would have aged out of a work-pass-shaped alert
  long ago. Blocking instruments need `probation_overdue`'s no-floor treatment instead.

## C · The dashboard arm and its permission

**Correcting the premise first:** the arm inventory file does **not** currently name supplier
certificates — the candidate lived in the conversation-era scoping that OPS-19 existed to stop
relying on. A candidate row is added to `docs/dashboard-arm-inventory.md` alongside this report so
the gap closes the way that file prescribes.

**Permission: `module.suppliers.view`** — not a new compliance module. Reasons:

* **The guard follows the data's own RLS** (OPS-15's rule): `supplier_compliance` is gated on
  `module.suppliers.view` today, so an arm claiming any other code would show/hide the tile out of
  step with what the reader can actually open.
* Holders are `admin`, `auditor`, `finance`, `gm`, `procurement` — procurement being exactly who
  chases a supplier for a renewed certificate.
* **Doc 2's Compliance Officer was never built** (the ten live roles have no compliance seat), and
  inventing `module.compliance.*` for one arm would put a fictional module in the catalogue — the
  same reasoning that rejected a one-member `cfo` role. If Phase 5 later builds a compliance
  module, the arm's permission is one line to change, and the arm inventory records exactly that.
* Company qualifications (A2) have no RLS home yet; when the table is built its SELECT policy
  should name the same code unless a compliance module has materialised by then — recorded so the
  build does not have to re-derive it.

## D · The shape of what Phase 5 still needs (report, not a plan)

Four remaining pieces, and they are **three different shapes** — which is what makes CMP-1 a first
piece rather than an isolated feature:

| piece | shape | attaches to |
|---|---|---|
| **Qualifications with expiry** (this cut) | **master-data-scoped**: a validity window on a counterparty or on the company itself | suppliers / company; alerts + (per A3) gates |
| **Basel / TFS movement documents** | **transaction-scoped**: one document set per physical shipment, with its own lifecycle (notification → consent → movement → confirmation of disposal) | inbound batches / future outbound shipments — the natural FK is the batch, and `po_issues` (PUR-1) is the record-not-view precedent for anything issued |
| **Customs declarations** | transaction-scoped likewise: one declaration per import/export, keyed to shipment + permit numbers drawn from the qualifications built here | same spine |
| **Regulatory filing** (periodic returns to NEA etc.) | **calendar-scoped**: recurring obligations with due dates — the `cpf_due` / `holiday_calendar_next_year` shape, not the expiry shape | a filing calendar; alerts escalate to due date, clear on recorded submission |
| **Regulation library** | **reference-scoped**: documents with versions, no dates driving behaviour | storage + a reading screen; nothing gates on it |

The dependency that makes CMP-1 first: movement documents and customs declarations both *cite*
permit numbers and validity — the qualifications table is the registry they will reference. Nothing
in Phase 5 is blocked on scale or headcount except the Compliance Officer seat, which is a role
grant, not a build.

---

## What CMP-1 builds once A3 is answered (so the build is a checklist, not a re-derivation)

1. Type `cert_type` (CHECK or reference table) with a per-type disposition column once A3 says
   block/warn/ignore per instrument.
2. `company_compliance` (A2's shape), with a real attachment link; fix `supplier_compliance`'s
   dangling `document_id` while touching it.
3. Expiry + absence alerts in the `hr_alerts` shape — no −30-day floor for blocking instruments;
   readable by `module.suppliers.view`.
4. The dashboard arm(s) per the inventory row added today.
5. The gate at whichever chokepoint(s) A3 names, refusing by name
   (`SUPPLIER_QUALIFICATION_EXPIRED|supplier|cert_type|valid_until`), with the fixture asserting
   both directions and the disposition distinction (a warn-type expiry must NOT block).

---

# CMPL-1 (2026-08-30) — own-licence limits, import due diligence, and three named deferrals

## The specimen, and what it was allowed to be

Tim supplied **two NEA licences belonging to another company (Se-cure Waste Management Pte Ltd)**
as a **specimen of what fields a licence carries**. They are **not Evoltrya's licences**.

> ★ **The specimen supplied FIELDS ONLY. Not one specimen VALUE was entered anywhere** — not as a
> default, not as an example row, not as a placeholder, not as an "e.g." in a comment, and not in a
> fixture. The fixture uses obviously-scratch values (`ZZ-FIX152`, limits of 4/10/100) that could not
> be mistaken for real licence data.

**Evoltrya holds no licence yet, and `company_compliance` is 0 rows on live.** ★ **Empty is the
EXPECTED state, not missing data** ★ — that was already the position in that table's own comment
("空着是预期状态 —— 公司尚未运营"), and this cut did not change it. The screen says so in words
rather than rendering a silent blank.

## What was NOT built, and why — read this before looking for it

**1 · No new licence register.** `company_compliance` (CMP-1) already *is* one: `cert_type_code` →
`certificate_types` (so the licence **kind was already a dictionary row**), plus number, issuing
body, validity and document. Its own comment already said the first real licence would need **no
schema change**. Building a second table would have been a second answer to "where do our licences
live". This cut is a **narrow extension**: `issue_date`, `status`, and the storage limit.

**2 · No quality hold.** ★ **It was found already working** ★ — and the objects are named here so a
later reader can tell this from an oversight:

| what | object |
|---|---|
| placing a hold, with a **required** reason | `hold_stock()` — refuses `STK_REASON_REQUIRED`, `STK_HOLD_EXCEEDS_AVAILABLE` |
| releasing it | `release_stock()` |
| processing **blocked**, refusing by name | `commit_processing_run` → `IOD_CONSUME_EXCEEDS_AVAILABLE\|consumed\|available\|held` |
| sale **blocked**, refusing by name | `record_output_sale`, naming available/held/committed |
| the status axis | `inventory_movements.stock_status ∈ (available, on_hold, committed)` |

So the brief's "every blocked path must refuse by name" was **already true**. The residual gap is the
one `proc-reality.md` item H already named: the existing mechanism is an **inventory action**
(a quantity moved to `on_hold`), not a **quality conclusion** (a judgement about the batch). That is
queued, **not built**, because there are **zero assay records on output batches** — there is nothing
to conclude quality *from*, and a `quarantine` state nobody can populate would be worse than none.

**3 · No hazardous-quantity-on-hand derivation.** See the deferral below — it is the most important
thing in this section.

## The three named deferrals

| # | deferred | trigger | why not now |
|---|---|---|---|
| **D1** | **Design capacity (tonnes/day)** on the licence | **the Phase 7 operation model** | It needs reliable *daily throughput*, which Phase 7 has not built. Modelling it now would mean inventing the denominator. (R3) |
| **D2** | **Hazardous quantity on hand** — the derivation | **the classification dictionary can express NEA's approved waste-type categories** | See below. This is the input the storage-limit check is missing. |
| **D3** | **Quality conclusion** at batch level (distinct from the inventory hold) | **the first real assay on an output batch** | Nothing to conclude quality from today. |

### D2 in full, because a later reader will otherwise assume the dictionary is wired up

To judge "are we over the approved storage limit" you need **how many tonnes of hazardous material
are on site**. That number **cannot be computed today**, and the reason is not effort:

* `waste_classifications` holds **two rows on live: `focused` and `non_focused`**;
* its `is_controlled` column has **ZERO consumers** — it is read by no view and no function anywhere
  in the repository;
* neither row corresponds to NEA's *approved waste type* vocabulary.

Mapping `is_controlled` onto NEA categories would be **invention, not modelling**. So
`hazardous_qty_on_hand_tonnes()` exists and **returns NULL**, and ★ **NULL means "cannot be
computed", not "zero tonnes"** ★. An implementation that read it as 0 would let every limit check
pass — which is exactly the manufactured confidence R2 forbids.

## R2 in practice: the check refuses, and the three "missings" never collapse

`licence_storage_within_limit()` **raises** rather than returning a convenient answer — the same
shape as the PDPA retention period (`anonymise_employee` raising `PDPA_RETENTION_PERIOD_NOT_SET`
when `hr_settings.personal_data_retention_months` is unset), which is the precedent R2 cites.

★ **Three different missing states, three different codes — deliberately never merged:**

| state | code |
|---|---|
| tonnage computable, **no limit recorded** | `LICENCE_STORAGE_LIMIT_NOT_SET` |
| limit recorded, **tonnage not computable** | `HAZARDOUS_QTY_NOT_COMPUTABLE` |
| **both missing** — *this is today's live state* | `LICENCE_STORAGE_INPUTS_BOTH_MISSING` |

Merging them would repeat the defect CHAIN-BUILD-1 had just fixed: two different "zeroes" rendering
alike, sending the operator to fix the wrong one. Here it would send them to record a limit when the
thing actually missing is a derivation that does not exist. Pinned by `db/fixtures/152` (arms A1–A3,
a succeeding control in **both** directions, and a fault injection that merges the branches and
asserts the arm goes blind).

**A note on `scope`, and why it was demoted in the same change.** The storage limit used to live
inside that free-text column — its old comment modelled a tonnage *inside a sentence*. Now that the
figure has a real column, `scope` is **explicitly demoted to prose that no check reads**, which is
recorded in its column comment. Leaving both readable would have created two sources for one fact —
the LOG-5a lesson (`free_time_terms` free text vs `free_days` integer) applied again.

## Import due diligence: what the licence text actually requires

Both specimen licences state that the licensee shall not receive hazardous or other waste **imported
into Singapore** except from a person who, **at the point of import**, held an import permit under
the Hazardous Waste (Control of Export, Import and Transit) Act 1997.

**Modelled as a recorded human verification on the batch** — `imported`, `import_permit_ref`,
`import_permit_verified_by`, `import_permit_verified_at` — with two constraints: verification fields
are only permitted when `imported IS TRUE`, and verifier and timestamp live and die together.

★ **Four states that must never render alike**, and `NULL` is the one most easily lost:

| state | meaning |
|---|---|
| `imported IS NULL` | **nobody has said yet** — ★ this is NOT "not imported" ★ |
| `imported = false` | recorded as not imported; the condition does not apply |
| `true`, no verification | imported, **permit not yet verified** — raises the dashboard arm |
| `true`, verified | imported, verified, by whom and when |

### Why this WARNS and does not REFUSE

The repo's standard is: **decidable now may refuse; not-yet-knowable may only warn.**

* **The decidable half already refuses, and this cut did not touch it.** `certificate_types` already
  carries `nea_import` ("NEA Import Permit") with `disposition = 'block'`, and an expired one already
  blocks receiving through `supplier_receiving_blocked` → `trg_inbound_batches_po_receivable`.
  Adding a second refusal beside it would have been a second definition of the same gate.
* **This half is not decidable by the system.** "Did the deliverer hold a permit *at the point of
  import*" is a fact about the **past**, about a **specific consignment**. The system holds no record
  of that moment — only a person's assertion that they checked.

**Both directions of being wrong, stated:** a wrongly refused truck at the gate costs more than that
truck — it **creates pressure to bypass the guard**, and a guard that gets routed around is worse
than no guard. A wrongly accepted import breaches our own licence condition — but the decidable half
already blocks that, and this half leaves an auditable record of who verified what and when.

## Unqueued: due-diligence items with no source document

**These are NOT queued, and that is deliberate.** The licence text supports the import-permit duty
and nothing further. Each of the following would need a **Tim ruling with a source document**, and
inventing them from a specimen licence that says nothing about them would be modelling imagination:

* **sanctions / restricted-party screening** — no source document yet;
* **financial standing checks on counterparties** — no source document yet;
* **supplier site audits** (frequency, scope, who signs off) — no source document yet.

## 2c — should the 60-day unsold arm point at a licence-derived limit instead? Not in this cut.

`output_unsold_aging` fires on finished output sitting **≥ 60 days**, and the arm inventory records
that 60 was chosen **to discriminate** (2 of 7 batches), is explicitly "a proposal", and that
changing it is a one-line migration.

**It cannot be pointed at a licence-derived limit today, and the blocker is D2, not the arm.** The
two measure different things: the arm measures **age of unsold finished goods**; a licence storage
limit measures **tonnes of hazardous material on site**. Repointing it would need (a) the hazardous
tonnage derivation (D2) and (b) a ruling that finished output counts toward the licensed storage
limit at all — which is a question about our licence's wording that nobody has answered. **Later
cut, gated on D2.**
