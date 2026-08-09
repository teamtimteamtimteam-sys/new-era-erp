# The purchase order document (PUR-1)

Doc 1's second named pain is *"disparate data — all over the place and disconnected."* Until this
cut a purchase order could not leave the system at all — no PDF, no export — so the supplier's copy
was produced somewhere else and nothing guaranteed it matched the record. This file is the
specification; the reports below were written **before** building.

## A1 · What the invoice PDF precedent provides, and what it does not

Read from `app/finance/invoices/[id]/pdf/` rather than assumed:

**Reusable as-is** (and reused, not copied):
* **The font machinery.** The precedent is *not* English-only in the mechanical sense — it embeds a
  subsetted Noto Sans SC (21 MB → 4.4 MB) precisely because a customer name or address can carry
  CJK characters, registers it from the repo filesystem (never a URL — a timeout would produce a
  silently font-less PDF), and hard-fails at module load if the files are missing. The PO document
  imports the same registration.
* **The CJK word-splitter.** textkit wraps on spaces only; a 69-character Chinese address measured
  wider than the page and was silently truncated. Exported from the invoice document and shared.
* **The coverage guard.** `lib/invoiceFontCoverage.ts` exposes the generic half
  (`PdfTextField` / `findUnrenderableText`) separately from the invoice-specific collector — the PO
  route builds its own collector over the same guard, so an unprintable character refuses the PDF
  by name instead of shipping blank glyphs to a supplier.
* **Logo handling** (download-and-embed as data URI, PNG/JPG only), the
  `Content-Disposition` filename escaping, and the missing-company-profile refusal.

**Invoice-specific, not carried over:** the GST block and `gst_registration_no`; the bank-details
block and therefore the `data.view_banking` whole-document gate (an invoice tells the customer where
to pay *us*; a PO does not tell the supplier where to pay anything); `bill_to_snapshot`;
`invoice_footer_text` (the column is invoice-named; the PO carries `terms_text` from the order
itself).

**Does `company_profile` carry everything a PO needs that an invoice does not?** Yes — the PO
needs *less* of it. It uses the identity block (legal name, registration no, address, contact) and
the logo, and deliberately omits the entire banking block. Nothing had to be added to the profile.

## A2 · What "send" means — generate and download; an ISSUE is recorded, a "sent" flag is not

The repo touches no network: no email provider, no webhook, nothing. The honest scope is
**generate → store → download**, with an **issue event recorded as a fact**: who generated it, when,
which version, and the SHA-256 of the exact bytes. There is **no "sent" flag** — the system cannot
know the document arrived, and recording what it cannot know is the `?? 0` family of lie.

**Supplier confirmation is deferred, deliberately.** Doc 1's flow has a confirmation step after
sending; that is a state a human records ("the supplier confirmed on the 14th"), not a
transmission, so it fits the system — but it belongs to the cut that extends the PO state machine
(the same one that builds amendment/versioning, which Doc 1 also wants). Bolting a `confirmed_at`
onto this cut would put one state of a workflow in place before the workflow has been designed.
Recorded here so it is a decision, not an omission.

**Issuing requires an approved order — unconditionally.** With approvals off, orders are born
approved, so this costs nothing; with approvals on, it closes the gap APR-2's A4 found ("sending to
the supplier: nothing to gate — the action does not exist"). The action now exists, so it is gated:
`PO_NOT_APPROVED`.

## A3 · What a PO shows that an invoice does not

Expected delivery date · Incoterm · the **payment schedule** (each instalment's label,
percentage or fixed amount **in the document currency**, trigger event, due date — FIN-29's
committed instalments, printed) · the **supplier's** details (legal name, address, country, tax id)
where the invoice shows a customer · per-line expected assay where present · and Part B's pricing
terms, which are the substantive difference.

## B · The pricing terms are on the document

FIN-27 copies terms at commitment because the supplier is committed under them. If the terms live
only in the database, the two parties are not committed to the same thing. So **each line states
its pricing status**, derived in SQL (`po_document_data`) so it is testable and single-sourced:

| line shape | status printed | what follows it |
|---|---|---|
| committed terms exist (`pricing_term_commitments` row) | **PROVISIONAL — PENDING ASSAY** | the committed terms verbatim: payable % per metal, price basis (spot / N-day average), treatment charge (USD/t — market convention), discount %, and the source formula code |
| **FIN-26's case: manual price with a formula attached** | **PROVISIONAL — PENDING ASSAY**, plus *"unit price shown is a manual estimate"* | same terms block. The estimate is what the reader was once misled by: the number is hand-typed, the settlement rule is the formula — the document says both, which is precisely the disambiguation FIN-26 introduced `price_source` to make possible |
| formula attached, **no commitment** (pre-FIN-27 legacy rows) | **PROVISIONAL — TERMS NOT COMMITTED** | no terms block — printing the formula's *current* terms would fabricate a commitment, the exact thing FIN-27 exists to prevent. The known-wrong entry for these rows already says they settle manually |
| price, no formula | **FIXED** | nothing — the unit price is the agreement |
| neither price nor formula | **PRICE NOT STATED** | nothing. Printed loudly rather than showing 0.00, which would read as "free" |

## C · The issued document is a record — the rendered bytes are stored

The repo has answered this shape twice (payment terms copied, pricing terms frozen) and the same
answer applies. **Stored: the rendered PDF bytes** in a private bucket (`po-documents`), one object
per issue, never overwritten — plus the SHA-256 in the issue row so the object can be verified
against the record.

Cost comparison, as asked:
* **Rendered bytes:** ~50–200 KB per issue; storage is the only cost. Reproduces *exactly* what the
  supplier holds, independent of every future change to the renderer, the fonts, the subset ranges,
  the company profile, or the document component.
* **Rendered-from data:** smaller (a few KB of JSON), but a regeneration still runs through the
  renderer — so "what did we issue" depends on the renderer not having changed since. The font
  subset alone has already changed once, and `@react-pdf` upgrades change line-breaking. That is a
  reproduction of the *data*, not of the *document*, and the dispute this record exists for is about
  the document.

The bytes win. (`po_document_data` exists anyway as the single source the renderer reads, so the
data half is not lost — it is just not the record.)

## D · Currency

The supplier's copy shows the **document currency only**. `po_document_data` carries no `fx_rate`
and no base-currency figure — asserted by fixture 36, not just intended. The base value is internal
(it decides the approval level and nothing else the supplier can see).
