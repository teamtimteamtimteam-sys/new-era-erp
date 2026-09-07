# COD-0 · Survey for the Certificate of Destruction

**Documentation only.** No code, no migration, no dependency was installed by this cut.
Every number below was read from the repository or measured against the live database
on 2026-09-07. Where something could not be measured, it says so and says why.

The owner's rulings from the grilling gate are taken as settled and are not re-opened.
Where a ruling meets a reality in the code that contradicts it, the contradiction is
reported, not resolved.

---

## 0 · Two words, fixed before anything else

**"Supplier", never "customer."** The certificate follows the material *backwards* to
whoever handed it over. In this system that party is `inbound_batches.supplier_id` — a
row in `suppliers`. The word "customer" in the original scope block is to be read as
"supplier" throughout, and this survey does so. `output_batches.customer_id` exists but
means something else entirely: whoever *buys the finished product*. In a recycling
business those are usually two different companies, and conflating them would put the
wrong name on the document.

**"Processing batch" = a processing run** (`processing_runs`, `PROC-YYYY-NNNN`), per the
owner's ruling. Section S1 measures what that choice costs against the alternative.

---

## S1 · Whose material is in one processing run?

### Can one run consume input batches from more than one supplier?

**Yes. Nothing forbids it.**

`commit_processing_run()` (`db/functions/commit_processing_run.sql`) takes `p_inputs` as a
JSON array and loops over it. Reading the whole function, the checks applied to that array
are: each element names exactly one parent (`INPUT_PARENT_INVALID`), no batch appears
twice (`DUPLICATE_INPUT`), each quantity is positive (`INPUT_QTY_INVALID`), each has enough
available stock (`IOD_CONSUME_EXCEEDS_AVAILABLE`), and each passes the material and safety
gates in `guard_processing_input()`.

**There is no check anywhere that the inputs share a supplier.** There is no column, no
constraint and no trigger that would notice. Mixing two suppliers into one run is a
first-class, fully supported operation today.

### Has it happened in the data?

**No — and the data is thinner than it looks.**

| Measurement | Value |
|---|---|
| Processing runs | 14 |
| Of those, reversed and soft-deleted | 4 |
| Rows in `processing_inputs` | 14 |
| **Runs with more than one input** | **0** |
| **Runs drawing from more than one supplier** | **0** |
| Runs whose single input is an inbound batch (has a supplier) | 13 |
| Runs whose single input is an *output* batch (re-processing) | 1 — `PROC-2026-0143`, reversed and deleted |

Every run in the database has exactly one input. So the mixed case has never occurred, and
the data can say nothing about it. The count is also unrepresentative in another way that
matters: `commit_processing_run` now requires an operation type, and its own refusal text
records why the history is empty of them — *"历史上那 14 张没有工序的单是测试残留,刻意不
回填"* (the 14 runs with no operation type are test residue, deliberately not backfilled).
**All 14 live runs are test residue.** Only one carries an operation type at all
(`PROC-2026-0494`, `deep_discharge`), and it is reversed and deleted.

The honest reading: the data cannot answer "does mixing happen", because nothing real has
been processed yet. The code's answer — *permitted, unrestricted* — is the one to build
against.

### What ties an output batch back to a supplier?

**A run-level list, and nothing finer.**

The chain is `output_batches` ← `processing_outputs` ← `processing_runs` →
`processing_inputs` → `inbound_batches` → `suppliers`.

Look at what `commit_processing_run` writes in step 6: for each output it inserts an
`output_batches` row and a `processing_outputs` row carrying `run_id` and
`quantity_produced`. **No output row references any input row.** The two legs hang off the
run independently.

So the link is a **list, not a quantity**. For a single-input run the list has one member
and the attribution is unambiguous by luck, not by structure. For a two-supplier run the
system would be able to say *"this output came from a run that consumed A's material and
B's material"* and would have **no basis whatsoever** for saying how much of the output
came from which. There is no split, no proportion, no allocation of mass.

(Cost allocation does divide value across outputs — `allocation_basis` is `weight` or
`metal_value`, and `allocation_snapshot` records the result. That is money, not mass, and
it divides *cost across outputs*, not *inputs across outputs*. It cannot be borrowed to
answer the physical question.)

### The lineage walker already exists

`db/views/batch_lineage_all.sql` is a `WITH RECURSIVE` view that walks from an output
batch up through every ancestor: depth, via which run, parent kind (`inbound` or
`output`), parent code, quantity consumed. `db/views/batch_lineage.sql` is the same thing
with the `module.processing.view` predicate applied on the outside.

`traceability_report_data()` already joins supplier name, supplier code, arrival date and
material at the inbound leaves of that walk. **The question "whose material is in this
output batch" is already answered by working code.** See S13.

Measured lineage depth today: **max depth 1, 13 rows** across the whole database. The one
re-processing run that would have produced depth 2 is reversed and deleted, and the view
deliberately ignores reversed runs.

### What a certificate could truthfully say in the mixed case

Given only data that exists, a certificate generated from a run that consumed material
from suppliers A and B could truthfully state:

- that this run consumed batch `IN-2026-xxxx` from A, of quantity *q₁*, arrived on *d₁*;
- that this run consumed batch `IN-2026-yyyy` from B, of quantity *q₂*, arrived on *d₂*;
- that this run produced output batches `OUT-…` totalling *Q*, on date *p*;
- that the run's declared loss was *L*.

It could **not** truthfully state that any particular part of any particular output came
from A. If A's certificate is to name the outputs at all, it can only name *the outputs of
the run A's material went into* — which are also B's outputs. Whether that is acceptable
is a question for the owner (Q1 below).

### The quantity problem, which is larger than the mixing problem

**Measured: 9 of the 13 inbound consumptions are partial.** Only 4 consumed the whole
inbound batch. 13 consumptions draw on just **7 distinct inbound batches**, and only **3**
inbound batches have reached stage `已加工完`.

That is the real shape of this business in the data: *one delivery is fed into several
runs over time.* Under "one certificate per run", a supplier who made one delivery of
1,000 kg receives **several certificates**, each covering the slice consumed by one run,
and none of them can say "your delivery has been processed" until the last one. The
certificate states what they gave — but a run only ever sees a portion of it.

This is a consequence of the per-run ruling, not an argument against it. It is reported
here because it changes what the document can honestly claim (Q2).

### Cost of the alternative, as instructed

| | Per processing run (ruled) | Per output batch |
|---|---|---|
| Documents per run | 1 | 1 per output — measured: 4 of 14 runs produced 2 output batches each |
| Covers "every finished product"? | Yes, natively | No — one product each; the supplier gets several |
| Mixed-supplier attribution | Same problem | Same problem |
| Partial-delivery problem | Present | Present, and worse (an output batch may descend from several deliveries) |
| Existing machinery reusable | Lineage view runs *from* an output batch; a per-run certificate must aggregate across `processing_outputs` first | Directly reusable — `traceability_report_data()` already takes an output batch id |
| Collides with the traceability report | No — different grain, clearly a different document | Yes — same grain, same subject, two documents about one batch |

The per-run choice costs one aggregation step that does not exist yet. It buys a document
whose grain is different from the traceability report's, which is the clearer outcome.

---

## S2 · What date is "processing completed"?

### Does a batch pass through more than one operation?

**Yes, by design, and the design is explicit about it.**

`operation_types` seeds five operations (`db/tables/operation_types.sql`):

| Code | Name | Kind |
|---|---|---|
| `deep_discharge` | Deep discharge | state_changing |
| `manual_disassembly` | Manual disassembly | transforming |
| `electrode_line` | Automatic foil separating line | transforming |
| `electrode_powder_line` | Foil processing line | transforming |
| `battery_powder_line` | Battery processing line | transforming |

`operation_kinds` splits them in two: `transforming` consumes input and produces outputs;
`state_changing` does neither — *"料【穿过】工序,库存一克不动"* (the material passes
through the operation; not one gram of stock moves).

A realistic path is therefore: deep discharge → manual disassembly → electrode line →
electrode powder line. Four runs, one delivery.

### Is there a recorded date meaning "this material's processing finished"?

**No. There is no such column anywhere.**

`processing_runs.process_date` is exactly what its name says: the date one operation ran.
It is required (`PROCESS_DATE_REQUIRED`) and it drives the accounting period. It does not
mean completion.

What does exist is a *stage*, not a date. In `commit_processing_run` step 5:

```sql
UPDATE inbound_batches
SET remaining_qty = v_new_remaining,
    stage = CASE WHEN v_new_remaining <= 0 THEN '已加工完' ELSE '加工中' END,
```

So `inbound_batches.stage` flips to `已加工完` ("finished processing") the moment
`remaining_qty` reaches zero. **No timestamp is written when that happens.** The date is
*derivable* — it is the `process_date` of the run that drove the remainder to zero — but it
is not *stored*, and deriving it requires a query over `processing_inputs` ordered by the
run's process date.

### What marks the last run?

Nothing marks it directly. The last run for an inbound batch is the one after which
`remaining_qty <= 0`. That is recoverable from `processing_inputs` joined to
`processing_runs`, but only for inbound batches — and only if no run was later reversed.

**Two further gaps worth naming:**

1. **State-changing runs are invisible to the lineage view.** `batch_lineage_all` starts
   its recursion at `processing_outputs`. A deep-discharge run produces no
   `processing_outputs` rows at all (that is the definition of `state_changing`). So the
   deep discharge a batch went through **does not appear in the lineage chain**. A
   certificate built from the lineage view would silently omit an entire operation the
   material passed through.

2. **Measured: no live run has an operation type.** All 14 are test residue. So the
   multi-operation path exists in the dictionary and in the code, and has never once been
   exercised in the data.

---

## S3 · What does the certificate's content already exist as?

For a certificate generated from a **processing run**:

| Field | Where it lives | Reachable from a run? |
|---|---|---|
| Material name | `materials.name` (and `materials.code`) via `inbound_batches.material_id` | Yes — run → `processing_inputs` → `inbound_batches` → `materials` |
| Quantity | Two different numbers, see below | Yes, but the choice is a ruling |
| Date received | `inbound_batches.arrival_date` (`date`, nullable) | Yes, same path |
| Date processing completed | **Does not exist as a column.** Derivable only (S2) | No — requires a derivation |
| Who processed it | Two readings, see below | Partly |
| Facility | `company_profile.address_lines` / `city` / `postal_code` / `country` | Yes, via `loadDocumentCompany()` |
| Licence number | `company_compliance.cert_no` where `cert_type_code = 'gwdf'` — **table is empty** | No, see S4 |
| Batch reference for the supplier's own records | Only Evoltrya's own codes exist, see below | Yes, but it is *our* reference, not theirs |

### Quantity — two numbers, and they mean different things

- `inbound_batches.quantity` — what the supplier handed over.
- `processing_inputs.quantity_consumed` — what this run took from it.

The scope says the certificate states *what they gave*. That is `inbound_batches.quantity`.
But a per-run certificate can only honestly attest to what *this run* processed, which is
`quantity_consumed` — and measured, **9 of 13 consumptions are partial**. Printing the
delivered quantity on a document that covers one slice of it would overstate what has been
destroyed. Printing the consumed quantity is honest but is not the number the supplier has
in their own records. (Q2.)

There is also `inbound_batches.declared_qty` — what the supplier said they were sending,
as against what was weighed in. Not currently used for anything on documents.

### "Who processed it" — two readings

1. **The company.** `company_profile.legal_name`, already printed on all eight outbound
   documents via `loadDocumentCompany()`. This is almost certainly what the certificate
   means: *Evoltrya processed it, at this facility, under this licence.*
2. **The individual operator.** `processing_runs.created_by` (a `uuid`, `auth.uid()` at
   commit time). Resolving that uuid to a human name goes through `user_directory`, whose
   view body ends `WHERE has_permission('action.manage_permissions')` — a capability held
   by admin only. A Warehouse & Field user cannot resolve it. `employee_directory` has no
   such predicate but is keyed by employee, and `employees.user_id` is the join.

Reading 1 needs nothing new. Reading 2 needs a permission decision. (Q3.)

### The batch reference the supplier could recognise

**Measured: there is no supplier-side reference recorded anywhere.**

`inbound_batches` has 30 columns. The identifiers among them are:

- `code` — `IN-YYYY-NNNN`, generated by trigger. **Ours, not theirs.**
- `purchase_order_id` / `purchase_order_line_id` — links to `purchase_orders`, whose code
  is `PO-YYYY-NNNN`. **Also ours**, though a supplier who received the PO would recognise
  it.
- `import_permit_ref` — free text, but that is an NEA import permit reference, a
  regulatory document, not a delivery reference.

There is **no** delivery-order number, no supplier's own reference, no weighbridge ticket
number, no consignment note field. A grep across `db/tables/inbound_batches.sql` for
delivery/reference-shaped columns returns nothing.

So today the only code that could go on the certificate is `IN-2026-NNNN`, possibly
alongside `PO-2026-NNNN`. Of the two, **the PO code is the one the supplier has actually
seen** — it was on the purchase order sent to them. The inbound batch code has never left
the building. Whether that is enough for a supplier to tie the certificate to their own
records is a question for the owner (Q4).

---

## S4 · Company details — contradiction report

The ruling under survey was: *"Licence number, processing address and registered address
all live on the company details page."*

**Measured, all three parts are wrong, in three different ways.**

### Registered address vs processing address

`company_profile` (`db/tables/company_profile.sql`) holds **one** address:
`address_lines`, `city`, `postal_code`, `country`. There is no second address and no
registered/processing distinction.

**Per the owner's ruling of 2026-09-07, this is not a gap.** The registered address and the
processing address will be the same address. The single existing field is correct as it
stands; the certificate prints it as the registered address; no schema change is required.
Recorded here so a later reader does not "fix" it.

### The licence number is not on that page, and it does not exist

The licence lives in a **different table**: `company_compliance`, column `cert_no`, one row
per certificate type, with `cert_type_code` referencing `certificate_types`. The GWDF
licence is a seeded type: `('gwdf', 'GWDF Licence', 'GWDF 执照', 'block', 90, 5, …)`.

`company_compliance` also carries `issuing_body`, `scope`, `valid_from`, `valid_until`,
`issue_date`, `status` (`active` / `suspended` / `revoked`), `document_path` and
`approved_storage_limit_tonnes`. Its own header comment says the emptiness is expected:
*"【空着是预期状态】—— 公司尚未运营"*.

**Measured: `company_compliance` has zero rows in the live database.**

**Measured: the string `WDL-88-88-8888` appears nowhere in the repository.** Not in code,
not in a seed, not in a document. A grep for `WDL-` returns nothing; the only GWDF hits are
the certificate-type seed and two scoping documents.

So the placeholder whose presence was supposed to trigger the refusal-to-issue has never
existed. **Per the owner's ruling, the trigger changes and no placeholder is to be
invented:** issuing is refused when `company_compliance` holds no `active` GWDF row with a
non-empty `cert_no`. That condition is checkable today against real columns.

One detail the refusal will have to decide: `status` is nullable, and `NULL` means "nobody
said". A row with `cert_no` filled and `status` NULL is not an `active` row. Reading NULL as
"active" would be exactly the failure this repository writes about at length
(`approved_storage_limit_tonnes`: *"NULL 不表示『没有上限』,表示『没有人录过上限』"*).
(Q5.)

There is a second reason this matters. `company_compliance`'s RLS is:

```sql
USING (has_permission('module.suppliers.view'))
```

Its own table comment flags this as a borrowed door: *"合规没有自己的模块……将来建合规
模块时这里是要改的那一行"*. **Warehouse & Field does not hold `module.suppliers.view`**, so
a warehouse user cannot read the licence row — which means they cannot read the very
condition that decides whether they may issue. The refusal will have to be evaluated
server-side with owner rights, not by reading the table as the user. (Q6.)

### How the letterhead is decided today — the helper to use

**`loadDocumentCompany()` in `app/components/pdf/company.ts`.** This is the single
implementation, introduced by PDF-1 precisely to stop three copies becoming eight. It:

1. reads `company_profile_masked` (the masked companion view — banking columns are nulled
   unless the reader holds `data.view_banking`; the header fields are readable by any
   authenticated user, since `company_profile`'s row policy is `USING (true)`);
2. **refuses** if `legal_name` is empty, with `COMPANY_MISSING_MESSAGE` — a refusal that
   names the page to go and fix it (`/finance/company`). The reasoning is stated in the
   file: *"一张【不知道是谁开的】对外单据比没有这张纸更糟"*;
3. downloads the logo bytes from the private `company-assets` bucket and inlines them as a
   data URI, rather than handing the renderer a URL.

**The certificate must use this helper.** It is document number nine in a family of eight.

**One consequence that matters for S8:** the same file records that
`@react-pdf/renderer`'s `Image` **does not support SVG**, and that the wordmark is
therefore drawn as vector primitives by `Wordmark.tsx` rather than loaded as a file.

---

## S5 · Numbering

### How gapless numbering works

Named function, one per family. `db/functions/next_credit_note_code.sql` is
representative:

```sql
PERFORM pg_advisory_xact_lock(hashtext('credit_note_code_' || v_year::text)::bigint);
SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
  FROM credit_notes WHERE code LIKE 'CN-' || v_year::text || '-%';
RETURN 'CN-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
```

Three properties, and each is deliberate:

- **A transaction-scoped advisory lock, one per family per year.** Its comment states why
  it is not shared: *"共用一把锁会让贷项凭证烧掉发票的号"* — a shared lock lets one document
  family burn another's number, and gapless means no holes.
- **The next number is `MAX(existing) + 1`, computed from the rows themselves.** There is
  no sequence object. This is what makes it gapless: a transaction that aborts leaves no
  row, so its number is simply recomputed and reused by the next caller.
- The number is parsed back out with `split_part(code, '-', 3)`, so the format
  `PREFIX-YYYY-NNNN` is load-bearing, not cosmetic.

The functions in the repository following this shape: `next_credit_note_code`,
`next_quote_code`, `next_sales_order_code`, `next_shipment_code`, `next_purchase_order_code`,
`next_statement_code`, `next_traceability_report_code`, plus a dozen others for HR and
assets. Invoices are numbered by the same inline logic inside `create_invoice()`
(`db/functions/create_invoice.sql:108`) rather than by a separate function.

A COD would add `next_cod_code()`, on its own lock, `COD-YYYY-NNNN`.

### Can a document be created with no number and take one later?

**Yes, and there is exact precedent for the certificate's case.**

`traceability_report_issues` is the model. The document itself — the traceability report —
has **no row anywhere until it is issued**. It is assembled on demand around an output
batch by `traceability_report_data()`. Its table comment states the design directly:

> *"【与另外六份唯一的不同:它有 code】另外六个族的号在【单据本身】上……而可追溯报告
> 没有一张『单据』—— 它是围着一个产出批临时组装出来的。所以报告号住在这里。"*

And the number's ownership rule:

> *"code 属于『这个批次的报告』,不属于每一版:第 1 版铸号,重发沿用同一个号。"*

`record_traceability_report_issue()` implements it: take the per-batch advisory lock,
compute `MAX(version) + 1`, and mint a code **only if `MIN(code)` is NULL** — i.e. only on
version 1. Re-issues reuse it, so the customer's reference never goes stale.

**Cost:** essentially nil, and lower than the alternative. The number lives on the issue
record, not on the entity. Nothing needs a nullable `code` column, no partial unique index
is needed, and an unissued certificate is simply the absence of a row. This is precisely
the three-state model the owner ruled: NOT ISSUED = no row; ISSUED = a row with a number.

The one thing it does not give for free is the **INTERNAL EXPORT** state. In the
traceability report that state is `GET` with no version parameter — render from current
data, open inline, write nothing. The COD needs the same, plus a visible "internal record,
not issued" marking on the page itself. (Q7.)

---

## S6 · Freezing the data at issue

**Two freezing mechanisms already exist in this system, and they are different from each
other. The COD needs both. That combination is the departure.**

### Mechanism A — freeze the bytes

Eight tables share one shape: `so_issues`, `po_issues`, `shipment_issues`, `cn_issues`,
`qt_issues`, `invoice_issues`, `statement_issues`, `traceability_report_issues`.

Columns: parent id, `version integer CHECK (version >= 1)`, `file_path text NOT NULL`,
`sha256 text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$')`, `issued_at`, `issued_by`,
`UNIQUE (parent_id, version)`. An append-only trigger on `BEFORE UPDATE OR DELETE`. RLS
select by permission, and **no INSERT policy at all** — the single write path is a
`SECURITY DEFINER` function, deliberately: *"档案不该有第二个写法"* (an archive should not
have a second way to write to it).

The philosophy is stated plainly on `traceability_report_issues`:

> *"【快照就是那份字节】—— 不另存一份推导结果:报告的每一个输入(血缘、回收率、含量
> 出处)都可能随后续录入而变,而客户手里那一份必须停在发出去的那一刻。"*

The snapshot *is* the bytes. No derived copy is kept. On retrieval, the stored file is
streamed back and checked against `sha256`; a tampered object is refused.

Two details worth carrying over. `qt_issues.issued_at` uses `clock_timestamp()`, not
`now()`, because it is one side of an "issued, then edited afterwards" comparison and
`now()` is constant within a transaction. And the storage object key is
`${id}/${crypto.randomUUID()}.pdf` — explicitly *not* the sha, because two versions can be
byte-identical and a sha-keyed object would let version 2 overwrite version 1.

### Mechanism B — copy the data

A second, equally established family copies values at a moment:

- **`contract_document_terms`** (CONTRACT-1) — when a document is linked to a contract, the
  terms in force are **copied onto the document**: `contract_code`, `incoterm`, `currency`,
  `payment_terms_days`, `grade_specs`. `contract_id` answers only *which contract*, and the
  table comment forbids reading terms back through it: *"任何读取路径都不许拿它回查条款
  内容 —— 一旦那么写,抄就退化成了引用,而退化是静悄悄的."*
- **`pricing_term_commitments`** (FIN-27) — copies the formula id, code, name *and the
  actual numbers at that moment*; settlement reads the copy.
- **`invoices.bill_to_snapshot jsonb NOT NULL`** (PARTY-1) — the customer's letterhead as
  it stood at invoicing: code, legal name, short name, country, tax id, address, payment
  terms, incoterm. Its stated purpose is exactly the certificate's: *"客户资料日后变更,
  几年后重打这张发票仍显示当时寄出的内容."*
- **GST-2** — the tax rate frozen at invoicing.

The rule these share: *"一张单据当时是按哪些条款开出去的,是一件【已经发生】的事……
合同后来改了条款,不该回头改写那张单据当时依据的东西 —— 那不是『更新』,那是改历史."*

And its enforcement half, inherited from FIN-27: **a record that referenced a source but
left no copy must be refused by name, never silently fall back to reading the live source.**
That is why `contract_document_terms.contract_code` is `NOT NULL`.

### The departure, stated in the owner's words

The owner ruled: freeze the PDF bytes exactly as the existing issue families do, **and**
freeze a data row sufficient to render the verification page years later with no live-row
dependency. **This is a deliberate departure from precedent** — not because either half is
novel (each has four to eight precedents), but because **no document family in this system
does both.** The eight issue families deliberately keep no derived copy; the four
data-copy precedents keep no bytes.

The reason the COD needs both is structural and worth writing down: a PDF blob plus a hash
**cannot be rendered into a web page**. The verification page is the original and the paper
is the copy — so the server must be able to *display* the certificate's content, and a
sha-checked blob only lets it *re-serve a file*. The bytes prove the paper; the row renders
the page.

### What the frozen row must hold

To render the verification page years later with no dependency on any live row, the frozen
row must carry every value that appears on the paper, resolved to text and numbers — never
as a foreign key. From the fields established in S3:

**Identity of the certificate**
- certificate number (`COD-YYYY-NNNN`), version, issued-at, issuer's display name
- the random verification token (S10)

**The issuer, as it stood at issue**
- company legal name, registration number, the single address (`address_lines`, `city`,
  `postal_code`, `country`), phone, email, website
- **the licence number, the issuing body and the licence validity dates** — copied, not
  referenced. A licence renewed next year must not rewrite a certificate issued this year.

**The waste owner, as they stood at issue**
- supplier legal name, supplier code, and whichever address the certificate prints
- (this is `bill_to_snapshot`'s shape, applied to a supplier)

**The material and the event**
- for each input consumed by the run: inbound batch code, purchase order code if any,
  material code and name, quantity consumed and unit, `arrival_date`
- for each output produced: output batch code, material code and name, quantity, unit
- the run code, its `process_date`, its operation type name **as text at that moment**
  (the dictionary can be deactivated or renamed — `operation_types` already carries a
  note that a code and its English name deliberately disagree), and the declared loss
- the derived "processing completed" date, if the certificate carries one (S2) — since it
  is derived, it *must* be frozen; it cannot be recomputed once a later run is reversed

**A voiding marker**
- void status, void reason, voided-at, voided-by, and the number of the certificate that
  replaced it (S9)

Two rules inherited from the precedent, which the build should honour by name:

1. Store display text, not ids, for everything that appears on the paper. Ids may be kept
   alongside to answer *which row this came from*, but no read path may use them to fetch
   content — that is the silent degradation `contract_document_terms` warns about.
2. If any required value is missing at issue time, **refuse by name.** Do not fall back to
   the live row, and do not print a blank.

---

## S7 · Permissions

### What Warehouse & Field holds today

From `db/tables/role_permissions.sql`, the `warehouse` role (role code `warehouse`, display
"Warehouse & Field" / 仓储现场, sort order 70) holds exactly **eleven** capabilities:

```
module.inbound.edit     module.inbound.view
module.inventory.edit   module.inventory.view
module.output.edit      module.output.view
module.stocktakes.edit  module.stocktakes.view
module.tasks.edit       module.tasks.view
module.logistics.view
```

The role description reads: *"Receiving, output and stock counts on the floor; no
commercial data."*

### Does it hold any data capability?

**No — and the seed says so on purpose.** The comment above the grant:

> *"warehouse(10):现场收货、产出、盘点。【不给任何数据类权限】—— 过磅的人不需要看见
> 价格,也不需要看见别人的身份信息。"*

The seven `data.*` capabilities are `data.view_prices`, `data.view_sales`,
`data.view_identity`, `data.view_pay`, `data.view_reviews`, `data.view_banking`,
`data.view_deleted`. Warehouse holds none of them.

Note also that the role holds **no `module.processing.view`** — that belongs to
`operations`, not `warehouse`. A warehouse user cannot open a processing run today at all.

### Can a warehouse user read the supplier?

**No. Measured.**

`suppliers` RLS: `USING (has_permission('module.suppliers.view'))`. Warehouse does not hold
it, so a warehouse user gets **zero rows**, not an error.

Exactly which certificate fields they could not see today:

| Field | Blocked by |
|---|---|
| **Supplier legal name** — the subject of the document | `module.suppliers.view` on `suppliers` |
| **Supplier code** | same |
| **The licence number** | `module.suppliers.view` on `company_compliance` (borrowed door, S4) |
| **The run's process date, run code, inputs and outputs** | `module.processing.view` on `processing_runs` / `processing_inputs` / `processing_outputs` |
| **The lineage chain** | `module.processing.view` on `batch_lineage` |
| **Who processed it, as a person's name** | `action.manage_permissions` on `user_directory` |

Readable by them today: the company letterhead (`company_profile`'s row policy is
`USING (true)`), the inbound batch (`module.inbound.view`), the output batch
(`module.output.view`), and materials.

So the gap is wider than the supplier's name alone: **a warehouse user can read neither
the supplier nor the processing run.** A certificate assembled entirely from tables they
can read would be missing its subject *and* its event.

There is a precedent for the cure the owner chose. `traceability_report_data()` is
`SECURITY DEFINER` with its own single door — `module.sales.view OR module.processing.view`
— and it returns the supplier's name to anyone who passes that door, with this stated
reason:

> *"【供应商名是随单据走的展示标签】,不另设一道门 —— 何况这份东西的用途就是交到客户
> 手里。"*

AGENTS.md line 1097 records the general form: derived facts — a count, a boolean, a
timestamp, **a display label** — are computed with owner rights, with the reader's own
module predicate in the function body.

Applied to the COD, cure (i) is: a `SECURITY DEFINER` function that checks the new
capability and returns the assembled certificate — supplier name included as a display
label — while `suppliers` itself stays shut. **No supplier list, no prices, no other
identity data.** The AUD-1 pattern is the one to copy, including its warning: any view the
function reads must be the **predicate-free base view** (`batch_lineage_all`), never the
gated one, or a reader without `module.processing.view` gets zero rows — and zero rows
here means "this batch has no origin", a false good-news answer that AUD-1 hit and fixed.

### Cost of both cures, as instructed

| | (i) Narrow data capability — **ruled** | (ii) Move issuing to a role holding `module.suppliers.view` |
|---|---|---|
| Migration | 1 permission row + 1 role grant + a `SECURITY DEFINER` assembler | 1 permission row + 1 role grant |
| New code | The assembler function, which is needed anyway to reach `processing_runs` | The assembler is still needed — warehouse is not the only role missing `module.processing.view`; `sales` lacks it too |
| Risk | The assembler becomes a second door onto supplier names. Its predicate must be exactly one capability, and it must never accept a supplier id as a parameter — only a run id — or it becomes a supplier lookup | None new |
| Effect on the floor | Warehouse keeps issuing, as ruled | Warehouse loses issuing; the document is issued by someone not present at the process |
| Roles affected | warehouse + admin | operations or sales + admin |

Cure (i) costs one function that would exist regardless, and one carefully-worded
predicate. The material extra risk is the parameter shape, and it is controllable.

### How a new capability is added

Three places, and the last one is free:

1. **The migration** inserts into `permissions` — `code`, `category`, `name_en`, `name_zh`,
   `description_en`, `description_zh`, `sort_order` — and into `role_permissions` by
   joining `roles` on code. Existing rows are the template
   (`db/tables/permissions.sql:49`ff, `db/tables/role_permissions.sql`). Both mirror files
   must be updated in the same commit; `role_permissions.sql` additionally runs a
   `DO $bootstrap_check$` self-test asserting that every `edit` is accompanied by the same
   module's `view`.

2. **The permission matrix** at `app/settings/roles/PermissionMatrix.tsx` — the screen where
   grants are toggled.

3. **The Permission reference page picks it up automatically.** `app/settings/reference/page.tsx`
   queries `permissions` and `role_permissions` live and joins them at render time. Its own
   header states the point: *"它【不可能与现实脱节】—— 页面直接读 permissions 与
   role_permissions,而不是读一份需要有人记得更新的文档."* No code change.

**One useful finding: the reference page already knows a third category, `action`.**
`CATEGORY_KEY` maps `module`, `data` **and `action`**. Two `action.*` capabilities exist
today — `action.manage_permissions` and `action.bulk_import`, the latter described as
*"the only action that can insert hundreds of rows at once"*. An issuing capability is an
**action**, not a module and not a data capability, and the category is already built,
already translated and already rendered. (Q8.)

---

## S8 · The stamp asset

**`evoltrya-stamp-navy.svg` is not in the repository.** A search across the whole tree
(excluding `node_modules`) for any file with `stamp` in its name returns three unrelated
SQL files about accounting basis stamps and supplier-creator stamps. `public/brand/`
contains `evoltrya-os-black.svg`, `evoltrya-sphere.svg`, `evoltrya-wordmark.svg`, and a
`festivals/` directory. No stamp, navy or otherwise. **No file has been substituted.** The
owner will supply it.

**One thing the build will hit when it arrives:** `@react-pdf/renderer`'s `Image`
component does not support SVG. This is recorded in `app/components/pdf/company.ts`, which
rejects SVG logos at both the upload end and the render end for exactly this reason, and it
is why the wordmark is drawn as vector primitives in `Wordmark.tsx` rather than loaded from
the `.svg` file. A navy SVG stamp will therefore need either the same hand-drawn treatment
or a raster conversion — supplying the file does not by itself make it printable. (Q9.)

---

## S9 · Voiding and reissuing

`void_invoice(p_invoice_id, p_reason, p_reversal_date)` — `SECURITY DEFINER`,
`db/functions/void_invoice.sql`. The mechanism, in the order it runs:

**What it checks before allowing a void**

1. `require_permission('module.finance.edit')` — the capability, first.
2. `SELECT … FOR UPDATE` — the row is locked for the duration.
3. `status <> 'issued'` → `INVOICE_ALREADY_VOID`. **A void is only possible from the issued
   state**, and voiding is not idempotent.
4. `p_reason` null or blank → `REASON_REQUIRED`. **A void with no reason cannot be
   recorded.**
5. A reversal date is required where there is an entry to reverse → `REVERSAL_DATE_REQUIRED`,
   *"永不默认"* — never defaulted, because it decides the accounting period, and a locked
   period must refuse by name rather than silently move the entry to today.
6. **Downstream-consumption checks, each derived rather than stored:**
   - live settlements exist → `INVOICE_HAS_SETTLEMENTS`, with the count in the message;
   - goods have shipped against its lines → `INVOICE_SHIPPED_NOT_VOIDABLE`.
   The comment on the second is the transferable rule: *"判据是【派生】的……不设状态位 ——
   状态位会与真相漂开,而这个问题每次都问得起."* The test is a query, not a flag.
7. Where the state cannot be reversed, the caller is refused rather than corrected — the
   correction route is a credit note, a *new document*, not an edit to the old one.
8. A parameter that cannot apply is refused rather than ignored →
   `REVERSAL_DATE_NOT_ACCEPTED`, on the ground that accepting and discarding it lies to the
   caller.

**What it leaves behind**

- The invoice row **stays**. `status = 'void'`, plus `void_reason`, `voided_at`,
  `voided_by`. Nothing is deleted.
- The lines stay, *"保留供审计"* — kept for audit — and a trigger propagates the void flag
  to them so the underlying order lines become invoiceable again.
- The accounting is reversed by a **new** journal entry linked to the original, not by
  editing it.
- A history row is appended (`sales_order_history`, `change_type = 'invoice_voided'`,
  carrying the code and the reason).
- The issue archive (`invoice_issues`) is **untouched** — the append-only trigger forbids
  updating or deleting it. The bytes that were sent remain retrievable and verifiable after
  the void.

**The mechanism the COD should follow**, transposed:

`void_certificate(p_cod_id, p_reason)` — check the issuing capability; lock the row;
require status `issued`; require a non-blank reason; set `status='void'`, `void_reason`,
`voided_at`, `voided_by`; leave the frozen row and the frozen bytes exactly as they are;
append a history entry. Then issue a new certificate with a **new number** — never reuse
the voided one, since `next_cod_code()` takes `MAX + 1` and the voided row keeps its
number, which is what makes the series gapless and what lets a recipient holding the old
paper still find it.

Two decisions the invoice mechanism forces into the open:

- There is **no reversal date** for a certificate — nothing is posted. The COD's void
  function should therefore take no date parameter at all, rather than accept and ignore
  one (rule 8 above).
- The invoice's downstream check has no direct analogue: nothing consumes a certificate.
  But the *verification page* does — a voided certificate's URL must keep resolving and
  must say plainly that it was voided, and by which certificate it was replaced. A void
  that made the page 404 would turn a document somebody is holding into a thing that never
  existed, which is the failure `traceability_report_issues` names when it explains why a
  re-issue keeps the original number. (Q10.)

---

## S10 · The verification URL

### Does the system generate random identifiers anywhere?

**Yes, in two forms, and one of them is exactly the right generator.**

- **In the database:** `gen_random_uuid()` is the default on essentially every primary key,
  including all eight `*_issues` tables.
- **In the application:** `crypto.randomUUID()` at seven sites, all of them storage object
  keys — `app/output/[id]/traceability/pdf/route.tsx:155`,
  `app/purchasing/orders/[id]/pdf/route.ts:157`, `app/finance/company/actions.ts:130`, and
  four attachment panels.

There is **no slug generator, no short-token generator and no `gen_random_bytes` usage.**
So the mechanism exists, but it has only ever been used for object keys, never for a public
identifier. A `uuid` in the URL would satisfy the ruling — 122 random bits, unguessable,
and changing one digit yields a value that does not exist rather than somebody else's
certificate. Whether a 36-character URL is acceptable on printed paper next to a QR code is
a presentation question, not a security one. (Q11.)

### Is any route reachable without authentication today?

**One: `/login`. That is the entire list.**

`lib/loginRoute.ts` holds the predicate, deliberately in one place:

```ts
export const PUBLIC_PATHS = ['/login'] as const
export function isPublicPath(pathname: string): boolean { return matches(PUBLIC_PATHS, pathname) }
```

The file's header explains that this constant exists because the predicate previously had
two copies, and that both copies were security predicates. It also carries a warning that
is directly about the kind of change the verification page requires:

> *"照字面做,就是把 '/set-password' 加进这个数组 —— 于是同一次改动顺手宣布【没有会话也
> 能打开设密码页】。那不是复用,那是把一条安全判据改宽,而改宽的地方看起来只是排版。"*

Widening this array looks like formatting and is not.

`proxy.ts` applies the middleware to every path except static image extensions
(`svg|png|jpg|jpeg|gif|webp|avif`), `_next/static`, `_next/image` and `favicon.ico`. Its
comment records the bug that produced that list: an AVIF background was auth-gated, so the
one audience that needed it — people not yet signed in — got a blank, while a
status-code-only assertion stayed green because the 307 to `/login` returned a 200 HTML
page. **The lesson applies directly here:** an assertion that the verification page "works"
must check its bytes, not its status code.

`lib/supabase/middleware.ts` distinguishes three outcomes rather than two — signed in,
definitely not signed in, and *authentication service unreachable* — and refuses to
degrade the third into a redirect to `/login`.

`BARE_CHROME_PATHS` is a superset of `PUBLIC_PATHS`, enforced in code by spreading the
latter into the former, so anything added to the public list automatically renders without
the application shell. The verification page gets that for free.

### What would have to change, and what a careless change would expose

Three things must change together:

1. **`PUBLIC_PATHS` gains a second entry.** Immediate, and the smallest part.
2. **The page must query as `anon`**, or through a route handler using a service path — a
   signed-out browser carries the anon key, not a user session.
3. **Rate limiting**, which does not exist anywhere in this application today. No
   middleware, no route handler and no database function implements one. This is new
   ground, not a pattern to copy.

**And here is the measured exposure, which is the part that needs care:**

| Measurement (live, 2026-09-07) | Value |
|---|---|
| Tables in `public` | 214 |
| **Tables with RLS disabled** | **0** |
| RLS policies whose role list includes `anon` or `public` | **1** |
| Views in `public` | 116 |
| Table-level grants to `anon` in `public` | **2,258** |
| Table-level grants to `authenticated` in `public` | 2,252 |
| **Views readable by `anon`, running with owner rights, with no permission predicate in the body** | **11** |

Read those last rows together. **`anon` holds more grants in this schema than
`authenticated` does.** That is Supabase's default privileges at work: every relation
created in `public` is granted to both roles automatically. Nothing is exposed today *only
because the middleware never lets an unauthenticated request reach a query* — the gate is
the routing layer, not the grants.

RLS carries most of the weight behind it: all 214 tables have it enabled, and the policies
are written `TO authenticated`, which does not apply to `anon` — so with RLS on and no
matching policy, `anon` gets zero rows from tables.

**The 11 views are the hole.** A view with `security_invoker = off` runs with its owner's
rights, so the base tables' RLS does not apply; the pattern in this codebase is to put a
`has_permission(...)` predicate in the view body instead. These eleven have owner rights,
are granted to `anon`, and have **no such predicate**:

```
attendance_period_status      collection_promise_status    expense_claim_status
inbound_batch_valuation       my_kpi_entries               my_leave_balance
my_profile                    my_review_subjects           my_self_assessment
my_self_assessment_goals      task_participant_directory
```

Most of the `my_*` views are scoped by `current_user_employee()`, which resolves through
`auth.uid()` and would return nothing for an anonymous caller — so their practical
exposure is likely nil. But `inbound_batch_valuation` is not a `my_*` view, and its name
says what it holds. **This survey did not verify what any of the eleven return to an
anonymous caller; that requires an actual anon-key request, which is a different kind of
test than the ones run here.**

This repository has already been bitten by exactly this class of drift, and recorded it in
`db/views/batch_lineage_all.sql`: a `REVOKE` present in the migration was never copied into
the mirror, so *"线上收着,重建出来的库开着"* — live is closed, a rebuild is open — and
nothing caught it, because `check_mirrors.py` states at line 59 that it **does not compare
GRANTs**. *"它不是被漏看,是没有人在看."*

**So the honest answer to "what would a careless change expose" is: unknown, and currently
unmeasured, across 11 views and 2,258 grants that no automated check inspects.** Opening
one public route converts a routing-layer gate into a per-relation grants-and-RLS question
for the whole schema, and this system has one tool that answers that question — reading —
and one that explicitly does not. (Q12.)

---

## S11 · QR codes

**`qrcode ^1.5.4` is already a dependency, and it is already in use.** Nothing to install.

Two routes generate QR codes today: `app/output/[id]/label/route.ts` and
`app/inbound/[id]/label/route.ts`. Both are self-contained printable batch labels served as
`text/html`. Both make the same call:

```ts
const url = request.nextUrl.origin + `/output/${id}/edit`
const qrDataUrl = await QRCode.toDataURL(url, { width: 480, margin: 1 })
```

and hand the data URI to `buildLabelHtml()` (`app/components/labels/labelHtml.ts`).

So the generator, the call shape and the "QR encodes an absolute in-app URL" pattern all
exist and work. **Two differences the COD introduces, both worth stating plainly:**

1. **These QR codes point at authenticated pages.** `/output/${id}/edit` requires a
   session; the label route itself returns 401 to a signed-out caller. The certificate's QR
   points at the one page in the system that must resolve *without* a session. The
   generator does not care, but the reviewer should not read "we already do QR codes" as
   "we already do public QR codes".

2. **These labels are HTML, not PDF.** Embedding a QR in a PDF has not been done here yet.
   It should be straightforward — `QRCode.toDataURL()` returns a PNG data URI, and
   `@react-pdf/renderer`'s `Image` accepts PNG data URIs (it is SVG it refuses, S8) — but it
   is untried in this repository.

## S12 · Where the certificate would live

### Module candidates

The application's route directories are: `contracts`, `finance`, `hr`, `inbound`,
`inventory`, `logistics`, `margin`, `materials`, `me`, `my-reviews`, `notifications`,
`operation`, `output`, `purchasing`, `sales`, `settings`, `stocktakes`, `suppliers`,
`tools`. Processing lives at **`app/operation/processing`** — there is no top-level
`app/processing`.

| Candidate | Route | Permission implied | Navigation | Against |
|---|---|---|---|---|
| **Processing** (recommended by the shape) | `app/operation/processing/[id]/cod/…` | `module.processing.*` — which **Warehouse & Field does not hold** | Sits on the run's own page, where the document is generated from | Requires either granting warehouse `module.processing.view` (widens well beyond the certificate) or reaching it through the `SECURITY DEFINER` assembler of S7 |
| **Output** | `app/output/[id]/…` | `module.output.*` — warehouse **does** hold it | Already where the traceability report lives | Wrong grain: the ruling is one certificate per run, and a run has several outputs. Would also put two different documents on one page |
| **Inbound** | `app/inbound/[id]/…` | `module.inbound.*` — warehouse **does** hold it | The supplier's delivery is the certificate's subject | Wrong grain again, and worse: one delivery spans several runs (measured: 9 of 13 consumptions partial), so an inbound page would have to list several certificates |
| **Suppliers** | `app/suppliers/[id]/…` | `module.suppliers.*` — warehouse does **not** hold it | The recipient's own file | Closes the door the whole design is trying to keep shut |

The grain of the ruling points at **Processing**, and the permission problem is the one
already answered by S7's cure (i): the page is reached by capability, and the content is
assembled by an owner-rights function. Putting it on the run page and gating the *page* on
the new action capability — rather than on `module.processing.view` — is consistent with
both the ruling and the existing pattern. (Q13.)

### What the manual says about certificates

**Essentially nothing.** `docs/manual-draft.md` is 2,043 lines. Searching it for
certificate / destruction / 销毁 / 证明 / traceability returns three hits, and none of them
is about this document:

- line 1008 — suppliers hold "compliance certificates and attachments";
- lines 1615 and 1622 — medical certificates, in the HR leave chapter;
- line 1904 — the permission table row `module.processing.view / .edit → "Processing runs
  and traceability"`.

**The traceability report itself is not documented in the manual either**, despite
shipping. So the COD is not replacing or contradicting anything written; it is adding to a
chapter that does not exist yet, and the traceability report needs the same treatment.
(Q14.)

---

## S13 · The traceability report (AUD-1) — the sibling that already ships

Added to this survey by the owner's ruling: AUD-1's traceability report **is** the recovery
report referred to in the scope block. The COD is built as its sibling and copies its
shapes. Reported here verbatim.

### What it is

A per-**output-batch**, customer-and-auditor-facing PDF, assembled on demand, numbered and
versioned only when issued. Introduced by
`db/migrations/2026-08-17-aud1-traceability-report.sql` (data layer) and AUD-2 (routes).

### Its data — `traceability_report_data(p_output_batch_id uuid) → jsonb`

`STABLE SECURITY DEFINER`. Door: `has_any_permission(ARRAY['module.sales.view',
'module.processing.view'])` — **OR, not AND**, because AND would shut out both sales and
operations.

Three ordered refusals, and the order is itself content: `NOT_AN_OUTPUT_BATCH` (you passed
an inbound batch id — a comprehensible mistake that deserves its own sentence),
`BATCH_NOT_FOUND`, and `NOTHING_TO_REPORT`.

That last one is the design decision most worth carrying over. Four live output batches
have no lineage, because the runs that produced them were reversed and soft-deleted, and
the lineage view deliberately ignores reversed runs. Rather than emit a report saying
"origin unknown", the function refuses: *"这时候【不能】发一份『来源不详』的报告去糊弄
审计 —— 空表比空报告诚实."* An empty table is more honest than an empty report.

The returned object:

| Key | Contents |
|---|---|
| `output_batch` | id, code, material code and name, quantity, remaining, unit, output date |
| `chain` | one entry per lineage edge: depth, via_run_id, via_run_code, parent_kind, parent_batch_id, parent_code, quantity_consumed — **plus, at inbound leaves only:** `supplier_name`, `supplier_code`, `arrival_date`, `material_code` |
| `chain_depth` | max depth |
| `runs` | every run on the chain, not just the last |
| `recovery` | per run × metal: input/output kg, measured flags, recovery %, `recovery_blocked_by`, `conservation_warning`, `input_source`, `output_source` — **carried verbatim from `processing_metal_recovery_all`, never recomputed** |
| `chain_row_count`, `recovery_row_count` | counts |

Two rules stated in its body that the COD must obey too:

1. **Read the predicate-free base view.** It reads `batch_lineage_all`, not `batch_lineage`.
   Owner rights substitute for table privileges but **not** for a `has_permission` call
   inside a view body, which resolves against the *caller*. AUD-1 measured the failure: a
   reader holding only `module.sales.view`, going through this function to the gated view,
   got **zero rows** — and zero rows here reads as "this batch has no origin", a false
   good-news answer. Fixture 83 turned red on that arm.
2. **Carry, never recompute.** The recovery columns are copied verbatim because
   recomputing them would create a second implementation of the same judgement: *"这个仓库
   为这个形状付过四次学费."*

### Its numbering — `next_traceability_report_code()`

`TRC-YYYY-NNNN`. Own advisory lock (`'traceability_report_code_' || year`), `MAX + 1` over
`traceability_report_issues`. The S5 shape exactly.

### Its issue record — `traceability_report_issues`

```sql
id uuid PK, output_batch_id uuid NOT NULL REFERENCES output_batches,
code text NOT NULL, version integer NOT NULL CHECK (version >= 1),
file_path text NOT NULL, sha256 text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
issued_at timestamptz NOT NULL DEFAULT now(), issued_by uuid,
UNIQUE (output_batch_id, version), UNIQUE (code, version)
```

- Append-only trigger `guard_traceability_report_issue_append_only` on `BEFORE UPDATE OR DELETE`.
- RLS select: `has_any_permission(ARRAY['module.sales.view','module.processing.view'])`.
- **No INSERT policy** — the sole write path is `record_traceability_report_issue()`,
  `SECURITY DEFINER`, gated on `module.sales.edit OR module.processing.edit`. *"档案不该有
  第二个写法."*
- **`code` belongs to the batch's report, not to a version.** Version 1 mints it; re-issues
  reuse it. Reason given: a re-issue that invalidated the customer's reference *"是把一份已经
  寄出去的文件变成查无此物"*.
- **No "sent" flag** — the system does not know whether it arrived.

`record_traceability_report_issue()` does not re-judge whether there is anything to report;
it calls `traceability_report_data()` and lets `NOTHING_TO_REPORT` propagate, on the ground
that a second implementation of a judgement will eventually disagree with the first.

### Its routes — `app/output/[id]/traceability/pdf/route.tsx`

Three entry points, and **these are precisely the COD's three states**:

| Method | Behaviour | COD equivalent |
|---|---|---|
| `GET` | Render from **current** data, open inline, **write nothing** | NOT ISSUED → INTERNAL EXPORT |
| `GET ?version=N` | Stream the stored bytes from the bucket and **verify against `sha256`** — refuse if the object was altered | Retrieve an issued certificate |
| `POST` | Render → upload to bucket → `record_traceability_report_issue()` | ISSUE |

Implementation details worth copying verbatim:

- Bucket `traceability-documents`; object key `${id}/${crypto.randomUUID()}.pdf`,
  explicitly **not** the sha, because two versions can be byte-identical and a sha key would
  let version 2 overwrite version 1 — leaving two archive rows pointing at one file and no
  answer to "what did version 1 say".
- If `record_…` fails after upload, the orphan object is deleted: *"桶里不该留一份没有档案
  的『签发件』."*
- It calls `loadDocumentCompany()` and **refuses** without a company legal name. Its comment
  labels it *"CONV-0 ②f:八份对外单据里的第八份"* — the eighth of eight outbound documents.
  **The COD is the ninth.**
- **Language follows the interface language**, not the invoices' "always English" rule. The
  stated reason: invoices and purchase orders are commercial documents issued to outsiders,
  whereas the traceability report is *"应某个人的要求、在他面前生成的一份说明"*. The
  document header prints which language it was rendered in, and a re-issue in another
  language is a new version. **Which rule the COD follows is a question** (Q15) — it is
  arguably a legal document issued to an outsider, which would put it with the invoices.

### Measured usage

**One row in `traceability_report_issues`.** The feature ships and has been exercised once.

### What this means for the COD build

The COD's shape is not a design problem. It is: `next_cod_code()` (copy
`next_traceability_report_code`), `cod_issues` (copy `traceability_report_issues`, plus the
frozen data row of S6 and the void columns of S9), `cod_report_data()` (copy
`traceability_report_data`, keyed on a **run** instead of an output batch, reading
predicate-free base views), `record_cod_issue()` (copy `record_traceability_report_issue`),
and a three-entry-point route (copy the AUD-2 route). What is genuinely new is: the frozen
data row, the void-and-reissue function, the licence refusal, the narrow capability, the
verification token, and the public page.

---

## Contradictions with the rulings, collected

Reported, not resolved.

1. **The licence number is not on the company details page and does not exist.** It is
   `company_compliance.cert_no` with `cert_type_code='gwdf'`; that table has **zero rows**;
   `WDL-88-88-8888` appears nowhere in the repository. *(Ruling already amended by the owner
   on 2026-09-07; recorded so the amendment is traceable.)*

2. **"The certificate names the customer" (S7 of the scope) contradicts "the original waste
   owner" (orientation).** In this system those are different tables. *(Ruled: supplier.)*

3. **Warehouse & Field cannot read the certificate's subject *or* its event.** Beyond the
   supplier name identified at the gate, the role also lacks `module.processing.view`, so it
   cannot read `processing_runs`, `processing_inputs`, `processing_outputs` or
   `batch_lineage`. The cure must cover both, not only the supplier name.

4. **"The whole of its data is COPIED AND FROZEN" is not what the eight issue families do.**
   They freeze *bytes* and explicitly keep no derived copy. A separate four-member family
   (`contract_document_terms`, `pricing_term_commitments`, `bill_to_snapshot`, GST-2) does
   copy data. **No family does both**; the COD doing both is the departure. *(Ruled: both.)*

5. **"Assembled automatically per processing batch, following live data" cannot always be
   satisfied.** `traceability_report_data()` refuses with `NOTHING_TO_REPORT` when the
   producing runs were reversed — measured: four live output batches are in that state. A
   per-run certificate will meet the same condition when a run is reversed. There is
   therefore a **fourth state the scope does not name: cannot be assembled**, and precedent
   says it must refuse by name rather than print "origin unknown".

6. **"Covers every finished product" is in tension with the measured partial-consumption
   pattern.** 9 of 13 consumptions are partial; 13 consumptions draw on 7 inbound batches.
   One delivery therefore yields several certificates, none of which covers the delivery.

7. **A state-changing operation leaves no trace in the lineage view.** Deep discharge
   produces no `processing_outputs` rows, and `batch_lineage_all` recurses from that table.
   A certificate built on the lineage chain would omit an operation the material went
   through.

---

## Questions for the owner

Unfiltered, in the order the survey raised them. Not triaged, not answered.

1. **Mixed suppliers — what does the certificate say?** The code permits one run to consume
   material from several suppliers; nothing links an output to a particular input. In that
   case, may supplier A's certificate name the run's output batches (which are also B's), or
   must it name only what A put in and stay silent about what came out?

2. **Which quantity goes on the paper?** `inbound_batches.quantity` (what they delivered) or
   `processing_inputs.quantity_consumed` (what this run processed)? Measured: 9 of 13
   consumptions are partial, so under the per-run ruling one delivery produces several
   certificates and none of them covers the whole delivery. Does the certificate also state
   the delivery total and how much of it remains unprocessed?

3. **"Who processed it" — the company, or the operator?** The company name costs nothing.
   The operator's name requires resolving `processing_runs.created_by` through
   `user_directory`, which is gated on `action.manage_permissions` — admin only.

4. **Is `IN-2026-NNNN` enough for the supplier to tie to their own records?** No supplier-side
   reference exists anywhere: no delivery-order number, no consignment note, no weighbridge
   ticket. The only code they have plausibly seen is the purchase order code. Should the
   certificate print `PO-2026-NNNN` as well, or should a supplier-reference field be added to
   inbound batches (a schema change, out of this cut's scope)?

5. **Does `status = NULL` on the GWDF licence row block issuing?** `company_compliance.status`
   is nullable and NULL means "nobody said". The refusal reads "no active GWDF row with a
   cert_no". Is a row with a number but no status active, or not?

6. **How is the licence refusal evaluated?** `company_compliance` is gated on
   `module.suppliers.view`, which Warehouse & Field does not hold — so the issuer cannot read
   the condition that governs them. Evaluate it server-side with owner rights inside the
   issuing function (recommended by the existing pattern), or grant the role read access to
   the licence row?

7. **What marks an INTERNAL EXPORT as "internal record, not issued"?** A watermark, a header
   band, a footer line? And should it be refused when the licence is missing, or is only
   ISSUING refused? (The scope says internal export still works; confirming it is unaffected
   by the new trigger.)

8. **Should the new capability be `action.issue_cod`?** The permission table already has an
   `action` category, the reference page already renders it, and an issuing capability is an
   action rather than a module or a data capability. Confirm the code and its
   English/Chinese names and descriptions — they are printed on the Permission reference
   page for every reader.

9. **The stamp is an SVG, and the PDF renderer cannot embed SVG.** When the file arrives,
   should it be hand-drawn as vector primitives (the `Wordmark.tsx` route) or converted to a
   raster image for embedding?

10. **What does the verification page show for a voided certificate?** It must keep
    resolving — a 404 would turn a document somebody is holding into a thing that never
    existed. Should it name the replacing certificate's number, and should it show the
    voiding reason?

11. **Is a UUID acceptable in the printed verification URL?** It satisfies the ruling
    (random, unguessable, no sequential relationship to the certificate number) and the
    generator already exists. It is 36 characters. The alternative is a shorter random token,
    which needs a generator this system does not have.

12. **The public route's exposure is unmeasured.** Opening one route converts a
    routing-layer gate into a per-relation grants question across 214 tables, 116 views and
    2,258 `anon` grants that `check_mirrors.py` explicitly does not inspect. Eleven
    owner-rights views are readable by `anon` with no permission predicate. Should a cut
    before or alongside the verification page measure what `anon` can actually read, using a
    real anon-key request?

13. **Does the certificate live on the processing run's page?** That is the grain the ruling
    implies, but the route sits under `module.processing.*`, which Warehouse & Field does not
    hold. Gate the page on the new action capability instead of on `module.processing.view`?

14. **The manual documents neither the certificate nor the traceability report.** Should the
    COD cut write both chapters, or only its own?

15. **Which language rule does the certificate follow?** Invoices and purchase orders are
    always English because they go to outsiders. The traceability report follows the
    interface language because it is a report prepared for someone present. The certificate
    of destruction is a legal document issued to an outsider — which rule?

16. **What happens when the run behind an issued certificate is later reversed?** The
    invoice precedent voids and reissues on data change. A reversal is not a data change —
    it says the run did not happen. Is the certificate voided with no replacement, and what
    does its verification page then say to the person holding the paper?
