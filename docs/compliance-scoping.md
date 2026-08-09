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
