# Evoltrya OS — Operations Manual

---

# PART 1 — GETTING STARTED

## 1.1 Signing in

Open the address your administrator gave you. The sign-in screen asks for **Email** and
**Password**, and the button is **Sign in**.

Accounts are created by an administrator under **Settings → Accounts**. There is no
self-registration, and the screen says so: *"No account yet? Contact an administrator"*.
When your account is created you are handed an initial password in person. The first time you
sign in you are sent to **Set your password**, which shows *"You are signing in as … Choose a
password to finish setting up your account."* The new password must be at least 8 characters.
Until you set it, that screen shows no menus and no modules. The only other control on it is
**Not you? Log out**.

Three things can go wrong at sign-in, and each says which:

| What you see | What it means |
|---|---|
| Wrong email or password | Check the email for typos, and the capitalisation of your password. |
| This email has not been confirmed yet | Your password is fine. Open the invitation email and follow the confirmation link, or ask an administrator to send it again. |
| Too many attempts — try again in a few minutes | Sign-in for this email is paused for a few minutes. Your account is not locked. |

If you are signed out while working, the sign-in screen says **Your session has ended** and
adds *"Anything you had typed on the previous page was not saved."* After a period of no
activity you are warned before that happens. The warning is headed **You will be signed out
shortly** and carries a **Continue working** button, which keeps you exactly where you are.

If you are locked out entirely, an administrator can restore access.

## 1.2 What you are looking at

After signing in you land on the home page. It carries the company mark, a greeting, and a
search box that does not work yet and says so: *"Search is not built yet. This box is where it
will live — for now it does nothing, so it does not take what you type either."* Everything you
do is reached from the module bar above it.

If your account holds no module permissions, the home page tells you that your account is
signed in, that no module has been granted to it, and to ask an administrator to assign you a
role.

**What is waiting for you is on Tools → Reminders**, not on the home page. That page gathers
every waiting signal across the modules you can reach.

Immediately after you set your password for the first time you are taken to one of two places.
If your account is linked to an employee record, you go to **My profile**. If it is not, you go
to a page headed **Your account is ready**, which tells you an administrator will finish
setting up your access, and that your own profile, payslips and training will appear once the
link to your employee record is made. That is not an error. It means the account exists and the
link has not been made yet.

Three pages are yours alone and do not depend on module permissions:

- **My profile** — your own record, payslips and training. Its subtitle reads *"Your own record.
  Only you and HR can see this."* If your account is not yet linked to an employee record, it
  says so and tells you to ask an administrator.
- **My reviews** — performance reviews you conduct, if you conduct any.
- **Notifications** — what the system has raised for you.

## 1.3 How the navigation is arranged

There is a bar of nine top-level modules across the top:

**Purchasing · Logistics · Operation · Sales · Finance · Inventory · HR · Tools · Settings**

A module name is a button that opens a menu. It is not itself a link, so clicking a module
name never takes you anywhere on its own. The menu under it lists that module's pages.

Six points about that menu will save you looking for pages in the wrong place.

**A module opens if any single page under it opens for you.** There is no separate
"can you enter this module" permission. If you hold only the stocktake permission, the
Inventory menu opens and Stocktakes is clickable.

**Entries you cannot open are shown, not hidden.** They are drawn as the entry's own name
followed by **· Restricted**, and hovering one shows *"Requires module access"*. A module you
cannot enter at all is drawn the same way on the top bar. You can always see that a feature
exists, whether or not you can use it.

**A page can sit under more than one module.** Inbound appears under Purchasing, Inventory and
Operation. Output appears under Operation and Inventory. Commissions appears under Purchasing
and Sales. Freight appears under Logistics and Finance. It is the same page in each case.

**Finance is the only module with a third level.** Its menu is grouped: **Reports · Journal ·
Receivables · Payables · Period end · Configuration**, with Overview above the groups.

**Some pages are not in any menu.** Twenty-one working pages have no menu entry of their own.
Every one of them is reached in one click from a page that does have a menu entry, and the door
is named wherever the page is described. The full list is in section 3.10. The one people look
hardest for is **Field Receiving**, where goods are received against a purchase order: it is a
button on the Inbound page, not a menu entry.

**Leave has its own tab strip.** The HR menu shows one entry, **Leave**. Inside that page a
strip of six tabs — **Requests · Balances · Calendar · Annual operations · Leave types ·
Public holidays** — leads to five more pages; Requests is the Leave page itself. The module
menu gives no hint that they are there.

## 1.4 What a code like PO-2026-0001 means

Every document carries a code with three parts: a prefix saying what kind of document it is,
the four-digit year, and a number counted within that year. `PO-2026-0001` is the first
purchase order of 2026.

The prefixes:

| Prefix | Document |
|---|---|
| `PO-` | Purchase order |
| `SO-` | Sales order |
| `QT-` | Quotation |
| `INV-` | Invoice |
| `CN-` | Credit note |
| `SHP-` | Shipment |
| `IN-` | Inbound batch |
| `OUT-` | Output batch |
| `PROC-` | Processing run |
| `WO-` | Work order |
| `JE-` | Journal entry |
| `PMT-` | Payment |
| `EXP-` | Expense |
| `FA-` | Fixed asset |
| `ST-` | Stocktake |
| `STMT-` | Bank statement |
| `LV-` | Leave request |
| `CLM-` | Expense claim |
| `MC-` | Medical claim |
| `PAY-` | Payroll period |
| `ASY-` | Assay result |
| `CTR-` | Container |
| `CON-` | Contract |

Two of these count differently, and the difference matters if you ever have to explain a gap.
Purchase orders, sales orders, quotations, invoices, credit notes and shipments are numbered
without gaps: the system takes the highest number used that year and adds one. Inbound and
output batch codes come from a counter that keeps going even if a save is abandoned, so their
numbers can skip. A missing `IN-` number is normal. A missing `PO-` number is not.

A contract's number takes its year from the date the contract comes into force, not from the
day it was typed in. Everything else takes the year from the document's own date.

You cannot choose a code. The system assigns it when the record is created.

## 1.5 What "deleted" means here

No document is ever removed from this system. Deleting one leaves the record in place, marked
as deleted, together with **who deleted it** and **why**. A reason is required, and the system
refuses the deletion without one.

Deleted records disappear from the lists and detail pages where they used to appear. They are
listed on **Settings → Deleted records**, which needs the `data.view_deleted` capability. That
page is a register, not a recycle bin: **there is no restore.** Nothing in the system puts a
deleted record back.

Deleting a batch is not only a bookkeeping act. For an inbound or output batch, the
confirmation says: *"This keeps the record and writes a write-off movement for the remaining
quantity — it does not erase the batch. Who deleted it and why are both recorded."* The stock
leaves the books.

Two qualifications:

1. **Some documents cannot be deleted at all.** Invoices, credit notes, journal entries,
   payments, expenses and shipments refuse deletion outright. So does the stock movement
   ledger. For these, see 1.6 below and the module sections: the correction is a reversal or a
   credit note, never a deletion.
2. **Configuration and the rows inside a document are removed outright, not marked.** A public
   holiday, a storage location's allowed material classes, a line on a draft quotation, a
   maintenance interval on a machine, a metal on a pricing formula, a step inside a task:
   removing one of these deletes the row. It is gone, it cannot be undone, and it is not listed
   on Settings → Deleted records, because there is nothing left to list. The confirmation
   dialog is the only warning you get.

One wording to be aware of: some delete confirmations still say *"(Soft delete: data is kept
and recoverable.)"* The first half is true. The second half is not something you can act on, as
no screen recovers a deleted record.

## 1.6 Reversal, not correction

Most of Finance, and all of the stock ledger, is append-only. You do not edit a posted document
and you do not delete it. You post a second, opposite document.

- A posted **journal entry** is reversed by a reversing entry.
- A posted **payment** is reversed by a reversal.
- An **invoice** can be voided, but only while nothing has been settled against it and nothing
  has shipped against it.
- A **shipment** cannot be touched once written. The only correction is a **credit note**, and
  a credit note itself cannot be changed once raised.
- A **stock movement** can never be edited or removed. Stock history only grows.

Read this section before you start entering documents. Wherever a process step in Part 2 has no
undo, it says so in those words.

## 1.7 How permissions affect what you see

Permission in this system answers two different questions, and it answers them in two different
ways.

**Can you open this page?** If not, the page says so: *"You do not have access to this module.
This is a permission answer, not an empty result — ask an administrator to grant you access to
this module."* You never get an empty page instead.

**Can you see this number?** A page you can open may still withhold particular values. The cell
reads **Restricted**. It is never blank and never zero. The most common case is money:
`data.view_prices` is a separate capability from any module, so a person can open the purchase
order list, see every order and every quantity, and see **Restricted** where the amounts are.

The same care runs through empty lists. Where a list is empty because you cannot see its
contents, the page says which. On the contract form, for example: *"Customers are not listed
here because you do not have access to customer records. That is a permission answer, not an
empty customer list."*

There is one deliberate exception to the pattern. Where a person's name cannot be shown because
**this account has no employee record**, that is stated as a fact about the data, not drawn as
a permission refusal. A gap in the data and a wall in the permissions are different things and
are shown differently.

Every capability has a name. A step that needs `module.finance.edit` needs exactly that string,
and that string is what an administrator ticks under **Settings → Roles**. Part 4 lists every
capability by name.

## 1.8 Words used throughout

**Batch.** A quantity of one material, received or produced as one lot, with its own code. An
**inbound batch** (`IN-`) is material that arrived. An **output batch** (`OUT-`) is material
that came out of processing. Stock is held as batches, not as a single pooled quantity.

**Movement.** One recorded change to stock: a receipt, a consumption, a sale, a transfer, a
write-off, an adjustment. Every stock figure in the system is added up from movements when you
open the page. Movements are never edited or deleted.

**Assay.** A laboratory result saying what a batch actually contains, which metals and at what
percentage. It is recorded against a batch and then applied, and applying it restates what the
batch is worth.

**Journal entry.** The accounting record of a transaction, as two or more lines that must add
to zero. Journal entries are posted, never edited, and corrected only by reversal.

**Ledger.** In finance, the accumulated journal entries. In stock, the accumulated movements.

**Incoterm.** A three-letter trade term (CIF, FOB, DAP and so on) saying who pays for carriage
and insurance, and at what point risk passes from seller to buyer.

**GST.** Singapore goods and services tax. Purchase orders are recorded exclusive of GST; the
tax is recorded when the supplier's invoice is entered as an expense.

**Base currency.** The currency the books are kept in. Foreign-currency documents are converted
at a recorded rate, and that rate is stored on the document rather than looked up again later.

**Reservation.** Stock set aside for a specific sales order line, from a specific batch at a
specific location. Reserved stock is still on hand but is no longer available to anything else.

**Earmark.** An output batch marked as feed for a downstream operation rather than as saleable
stock. An earmarked batch cannot be reserved, sold or shipped until the earmark is released.

## 1.9 Dates

The system almost never fills a date in for you, and where it refuses to, it says why. A process
date decides which metal prices a cost allocation uses. An invoice issue date decides which
accounting period the entry lands in. A ship date decides which period revenue lands in. An
arrival date is the day the goods actually arrived.

Each of these records something that happened in the world, and only the person entering it
knows when that was. So blank stays blank. Expect to type a date on almost every document, and
expect a refusal that names the field if you do not.

---

# PART 2 — BUSINESS PROCESSES

Real work crosses modules. Receiving one lorry-load touches purchasing, inventory, assay and
finance in a single afternoon. This part follows six pieces of work from beginning to end,
across whatever modules they pass through. Part 3 is the place to look a single page up.

Each process opens by naming the people involved. Each step then gives four things: which page
it is on, what permission it needs, what happens if the step before it was skipped, and how to
undo a mistake. Where a step has no undo, it says so in those words.

Where a refusal is quoted, it is the sentence the screen shows, so that what is in front of you
can be matched to the page.

## 2.1 Receiving a load into stock

The people involved: whoever weighs and books in the load at the gate; whoever records the
condition of the material; whoever enters the laboratory result; whoever prices the batch.

### Step 1 — Have a purchase order, or a reason for not having one

Material can be received either against a purchase order line or with no order at all. The
second case is legitimate, a free sample or a spot delivery, but the system asks you to say
which it was.

- **Page:** Purchasing → Purchase orders → **+ New Purchase Order**. See 2.2 for how to raise one.
- **Permission:** `module.purchasing.edit` to raise an order.
- **If not done:** you can still receive, but you must choose a reason under **Source (no
  purchase order)**. Choosing "other" without typing an explanation is refused: *"This reason
  requires a written explanation."*
- **Undo:** an order with nothing received against it can be cancelled with a reason. See 2.2.

### Step 2 — Book the load in

There are two doors. **Field Receiving** weighs one material at the scale: kilograms, no price,
and it can receive against a purchase order line. **Add Inbound** is the full entry, with unit,
unit price and stage.

**Field Receiving**

- **Page:** Purchasing → **Inbound**, then the **Field Receiving** button at the top right.
  There is no menu entry for this page.
- **Permission:** the Inbound page needs `module.inbound.view`; saving needs
  `module.inbound.edit`.
- **What you enter:** Supplier, Material, **Weighed Quantity (kg)**, **Arrival Date**, and
  optionally **Declared quantity (optional)** and Notes. The declared quantity is what the
  supplier said was coming. It is never prefilled from the purchase order, because the order is
  ours and the declaration is theirs. Left blank it means "not recorded", which is not zero.
- **The button is Save & Get Label.** Saving creates the batch and prints its label. The next
  screen is headed **Received** and offers **Receive Next**.
- **If the arrival date is missing:** *"The arrival date is required — the stock movement
  records the day the goods actually arrived, and it is never filled in for you. Nothing was
  saved."*
- **Undo:** delete the batch from its own page, giving a reason. That writes a write-off
  movement for the whole remaining quantity and marks the batch deleted. It is not a way to
  correct a typo. See the end of this section.

**Add Inbound**

- **Page:** Purchasing → **Inbound** → **+ Add Inbound**.
- **Permission:** `module.inbound.edit`.
- **Against a purchase order:** the form has **Against purchase order** and then **Select an
  order line…**, showing ordered and remaining quantity per line. If you leave it blank you
  must give a source reason instead.
- **Undo:** the batch can be edited afterwards (**Edit Inbound**) for most fields. The unit
  price is not an ordinary field. See step 5.

**What happens the moment you save.** The batch exists and the material is stock. The receipt
movement is written in the same act that creates the batch. Assay and pricing change what the
batch is worth; they do not decide whether it is there.

### Step 3 — Record the condition on arrival

- **Page:** Inbound → open the batch (**Edit Inbound**), section **Condition on arrival**.
- **Permission:** `module.inbound.edit`.
- **What you record:** **Safety state**, where you tick everything that is true of the load, and
  **Chemistry certainty**. A load can be both water-exposed and damaged, and nothing is
  pre-ticked.
- **The blank is meaningful.** A load with nothing ticked reads *"No safety state is recorded for
  this load. That means NOBODY HAS RECORDED ONE - it does not mean the load is safe."* The two
  chemistry answers are also different from each other: **Mixed** is for material you know to be
  mixed. Material you could not identify is **Unknown, pending identification**.
- **If not done:** the batch cannot be processed. Committing a processing run that consumes it
  is refused: *"Batch {code} has NO recorded safety state. That means NOBODY HAS RECORDED ONE
  — it does not mean the load is safe."* Record it here, then commit the run again.
- **Undo:** re-open the panel and change the ticks. Saving replaces the whole set with what is
  ticked, so re-tick everything that is still true.
- **Not every batch answers these questions.** For material that is not battery material the
  panel says the axes do not apply. Only battery material carries a safety state and a chemistry
  certainty.

### Step 4 — Record the assay result

- **Page:** Inbound → open the batch → **+ Record assay**. The page it opens is headed
  **Record Assay Result**.
- **Permission:** `module.inbound.edit` to record and to apply.
- **Two acts, not one.** Recording the result stores it. **Applying** it is what restates the
  batch: it updates the recorded metal content and, where the batch is priced from a formula,
  restates what is payable. The button that does both at once is **Record and apply**;
  otherwise use **Apply now** on the result.
- **If applied twice:** refused. An assay result can be applied once.
- **If the batch was priced against a contract formula but the terms were never committed:**
  *"{batch} references pricing formula {formula} with no settlement terms recorded at the time."*
  Settlement refuses rather than reading the formula as it stands today.
- **Undo:** **Unapply**, with a reason. Read the warning before you do: *"Unapplying restores
  the metal content record but does NOT reverse the price change."* Reprice explicitly if that
  is what you want. Unapplying is not a full reversal.
- **A later result supersedes an earlier one.** The superseded result stays on file, marked
  **Superseded by {code}**.

### Step 5 — Price the batch

A batch moves through three pricing states: **unpriced → provisional → final**.

- **Page:** Inbound → open the batch (**Edit Inbound**), and use the repricing control there.
- **Permission:** `module.inbound.edit`.
- **Why price is not an ordinary field.** The unit price is what is owed to the supplier.
  Changing it changes the debt, so it goes through its own action and leaves a price-history
  record. It cannot be typed over in the ordinary way.
- **If the currency has no accepted rate for that date:** the repricing is refused by name and
  nothing is saved. Enter the rate under **Finance → FX Rates** first.
- **Undo:** reprice again. Every price the batch has carried stays on the price history.

### What the batch has cost

The batch page shows **Landed cost**: what the batch has cost so far. The purchase price is what
is owed to the supplier. Freight and processing cost are capitalised onto the batch separately
and never change the purchase price. If the batch has no unit price yet, the page says the
landed cost cannot be totalled rather than showing a partial number.

### How to undo the whole thing

**You do not undo a receipt.** The stock movement written when the batch was created cannot be
edited or removed. What you can do is delete the batch with a reason, which writes a write-off
movement for whatever is left and marks the batch deleted, with your name and your reason on
it. If material was received against the wrong supplier or the wrong material, that is the
route, and the reason field is where you say so. There is no restore afterwards.

---

## 2.2 Buying, from order to payment

The people involved: whoever negotiates and raises the order; whoever receives against it (2.1);
whoever enters the supplier's invoice; whoever pays it.

### A note before the first step: approvals are switched off

This system has a two-level purchase approval chain. The chain is built and configured, and it
is **not in force**. The approvals page states it: *"Approvals are NOT in force. Orders are
stamped approved by the system when they are raised; nobody decides them."*

So **a purchase order is created already approved**. There is no approval step in the process
below, because there is no approval to wait for. Trying to approve one is refused, for the same
reason.

Where the state is reported: **Settings → Approvals**. That page is read-only. It shows whether
approvals are in force, which role approves at level 1, the amount threshold, which role
approves at or above it, and what turning the switch would do. It does not carry the switch, and
neither does anything else: *"This panel is read-only. There is no screen anywhere in the system
for configuring the approval chain."* Turning approvals on is a change made directly to the
database.

If approvals are ever switched on, an order is then raised as a draft and must be approved
before goods can be received against it or a deposit released. Turning the switch on leaves
existing orders receivable, and turning it off never retroactively approves anything.

### Step 1 — Raise the purchase order

- **Page:** Purchasing → Purchase orders → **+ New Purchase Order**.
- **Permission:** `module.purchasing.edit`.
- **Choose the kind first.** An order is either **Materials** or **Equipment**, never both. The
  rule is enforced when you submit, so choosing before you type saves the typing. Mixing them is
  refused: *"One order is either all material or all equipment."* An order carrying both would
  have an ordered quantity that adds kilograms to machines.
- **What is required:** an **Order date**, a supplier, a currency with an accepted FX rate, and
  at least one line. Refusals, by name: *"An order date is required — it decides which FX rate
  values the order"*; *"Add at least one line"*.
- **Equipment orders are different.** Each line is one machine, and the machine's asset card
  must already exist: *"Pick a machine registered under Finance → Assets."* A purchase order
  line never creates a machine. An equipment order is also never received into stock: a machine
  arriving creates no batch, has no assay and does not enter a location, so the order carries no
  receive action at all.
- **GST.** Amounts on a purchase order are exclusive of GST. An order is a commitment, not a tax
  point. Input GST is recorded later, when the supplier's invoice is entered as an expense,
  using that supplier's default tax code.
- **Payment terms** can be attached from a template (**Purchasing → Payment terms**), setting
  instalments with their triggers and due dates. Percentages across the instalments cannot
  exceed 100.
- **Undo:** **Amend** on the order, with a reason. Quantity, price and dates can be amended.
  Supplier and currency cannot: changing either makes it a different deal, so raise a new order
  instead. Every change is recorded. Changing the order date re-derives the FX rate for that
  date, and if no rate is on file the amendment is refused rather than a rate being guessed.
  Amending a closed order is refused until you reopen it: *"This order is closed. Reopen it
  first."*

### Step 2 — Receive against it

Covered in full in 2.1. The relevant fact here is that receiving is what turns an order into
something you owe against.

- **If the order does not exist or was cancelled:** you cannot receive against it. Receive with
  a stated source reason instead, or raise the order.

### Step 3 — Record the supplier's invoice as an expense

- **Page:** Finance → Expenses → **+ New Expense**.
- **Permission:** `module.finance.edit`.
- **What it does:** posts to the ledger. This is where input GST is recorded. Enter the amount
  **net** of GST and pick a tax code. The tax is computed on top: a claimable code posts it to
  input tax, a blocked code posts it into the expense itself. The supplier's default code is
  offered, and where there is none the form refuses to guess: *"No default is available, so a
  code must be picked here."* TX, ZP, EP, BL and OP all behave differently on the return.
- **Non-resident payees.** If the payee is recorded as non-resident, the form asks whether tax
  must be withheld and will not accept a blank. Where withholding genuinely does not apply,
  choose **Not subject to withholding** rather than leaving the field empty. An expense that
  attracts withholding cannot be recorded as already paid; record it unpaid and withhold at the
  payment.
- **Capital purchases.** Ticking **Capital expenditure (fixed asset)** posts to fixed assets and
  creates the register entry in the same transaction, so the asset cannot exist without the
  payable behind it.
- **If the equipment line has already been expensed:** refused. *"One line is expensed once."*
  If the price changed, amend the order line instead.
- **Undo:** **there is no undo.** An expense cannot be edited or deleted. The correction is a
  **reversal**, which posts an opposite entry and leaves both on the ledger.

### Step 4 — Pay

- **Page:** Finance → Payments → **+ Record Payment**.
- **Permission:** `module.finance.edit`.
- **What is required:** a payment date, a direction, a counterparty of the right kind for that
  direction, an amount, a currency and its rate, and the documents the payment settles.
- **Currency must match.** *"{document} is a {currency} document — settle it with a {currency}
  payment (got {other})."*
- **You cannot over-allocate.** Allocating more than a document's open amount is refused, and so
  is allocating more in total than the payment is for.
- **You cannot allocate to another party's document.** *"Document {code} belongs to a different
  counterparty."*
- **Deposits.** Where a deposit was paid on the order, releasing it against an invoice is a
  separate act on the invoice. Releasing moves that money from prepayments onto the invoice; no
  cash moves. The deposit is measured in base currency at the rate it was paid at, the release
  amount is in the invoice's currency, and the server converts.
- **Undo:** **there is no undo.** A payment cannot be edited or deleted. The correction is a
  **reversal**.

### Step 5 — Close the order

- **Page:** the order's own page, **Close order**.
- **Permission:** `module.purchasing.edit`.
- **Refused if:** the order is cancelled, or already closed.
- **Notes are required where a deposit is unresolved:** *"This order has {amount} of unapplied
  prepayment — a note explaining how it is resolved is required to close."*
- **Undo:** **Reopen**, with a reason. Reopening returns the order to the status it held before
  it was closed.

### Cancelling an order

Cancelling is narrow.

- **Refused once anything has been received:** *"Cannot cancel: {n} inbound batch(es) are linked
  to this order"*.
- **Refused once a deposit has been released:** *"Purchase order {code} already has a deposit
  released against it."* Cancelling would leave that release pointing at a void order, so
  reverse the release first.
- **A reason is required.**
- **There is no undo.** A cancelled order is closed for good and cannot be reopened. Who
  cancelled it and why are both recorded.

If goods have already arrived, the order cannot be cancelled at all. Close it instead, with a
note.

---

## 2.3 Processing a batch into output

The people involved: whoever plans the work; whoever releases the plan; whoever records what
actually ran; whoever settles the cost.

A **work order** is the plan. A **processing run** is what happened. They are separate records,
and a run does not have to have a plan behind it.

### Step 1 — Write the work order (optional)

- **Page:** Operation → Work orders → **+ New work order**.
- **Permission:** `module.processing.edit`.
- **What it is:** a plan of what to process, how much, and when. What actually happened lives on
  the processing runs, and the progress figures on the work order are read from those runs
  rather than stored.
- **Planned inputs are by material, not by batch.** When a plan is written the batches often do
  not exist yet, and which batch to use is a decision made on the day.
- **Expected outputs are optional**, and every expectation row must say where its number came
  from: **Planner estimate**, **Seeded from industry experience (low confidence)** or
  **Calibrated against real production**. There is no default. An empty expectation table means
  nobody estimated, which is not the same as expecting zero.
- **It saves as a draft.** Releasing it is a separate step.
- **Undo:** **Amend plan**, with a reason. A planned quantity cannot be reduced below what
  linked runs have already consumed.

### Step 2 — Release the work order

- **Page:** the work order's own page, **Release**.
- **Permission:** `module.processing.edit`.
- **If not done:** a run cannot be worked against it. *"Work order {code} is {status} — only a
  RELEASED order can be worked against."* A draft has not been agreed yet; a closed or cancelled
  one has already ended.
- **Refused if not a draft:** only a draft can be released.
- **Undo:** there is no un-release. A released order is closed or cancelled, never returned to
  draft. Cancelling is refused once any run has been worked against it: *"Work order {code}
  already has {n} processing run(s) against it, so it cannot be cancelled — close it instead."*
  Cancelling would say the work never happened, and the material really did move.

### Step 3 — Record the processing run

- **Page:** Operation → Processing runs → **+ Add Processing Run**.
- **Permission:** `module.processing.edit`.
- **What you choose:**
  - **Work order (optional)** — only released orders are listed. Inputs are not prefilled from
    the plan: a plan names materials, a run names batches, and a guessed batch would be a
    plausible wrong answer.
  - **Operation** — the operation decides what the machine accepts. Some operations produce no
    new batch at all: the same batch goes in and comes out with its state changed.
  - **Process Date** — required. It decides the movement date and which metal prices the
    allocation uses. The Save button is disabled while it is blank.
  - **Cost allocation basis** — prefilled from the company default in Finance settings, and
    changeable here. It decides each output batch's reported gross margin, so it is a choice,
    never a default.
  - **Inputs (consume inbound)** — batches and quantities. The same batch cannot be added twice.
  - **Outputs (produced goods)** — material, quantity, purity. Total output cannot exceed total
    input.
- **If the input batch has no condition recorded:** refused, with the route out named. See
  2.1 step 3.
- **If the input carries a safety state that may not be fed:** *"Batch {code} carries safety
  states that may not be fed: {states}."* Every one of them has to be cleared. A load that is
  discharged and water-exposed is still water-exposed; discharging it does not cancel the water.
- **If the operation does not accept what the batch is carrying:** the refusal says so, and it
  is not the same answer as "may not be fed". Another operation may well accept the batch:
  charged material goes through Deep discharge first, and packs that cannot be discharged go to
  the Battery processing line.
- **If the machine is not yet acquired, or has been disposed of:** refused by name.
- **Undo:** **Delete Processing Run** on the run's page, which asks *"Roll this processing run
  back?"* and confirms with **Roll back this run**. A reason is required. Rolling back reverses
  the run: the consumed inputs are restored to their batches, the output batches are voided, and
  reversing movements are written to the stock ledger. It cannot itself be undone. A reversed
  run stays listed against its work order, because it really was worked, but its consumption
  stops counting anywhere.

### Step 4 — Allocate the cost

This is a separate, later step. Committing a run does not do it.

- **Page:** the run's own page, **Cost Allocation**.
- **Permission:** `module.processing.edit`. Allocating cost is a processing right, not a finance
  one: the run decides how its own cost is spread.
- **What it does:** puts cost onto the output batches. Committing a run produces the batches;
  allocating is what gives them a unit cost.
- **If not done:** the run sits committed and unallocated indefinitely, and the batches carry no
  cost. The page says: *"This run has cost entries but has never been allocated."* The ledger
  carries them and no batch does. Month-end close refuses while any run is in this state.
- **If the cost entries changed after the last allocation:** the page says *"Allocation is out
  of date — cost entries changed after the last allocation"*. Re-running it posts the difference
  to inventory for the in-stock share, to cost of goods sold for the sold share, and to
  inventory adjustment for the written-off share, dated today.
- **If allocating by metal value and no output batch has a priced metal:** *"No priced metal
  content on any output batch."* Record assay results, add a price for at least one contained
  metal under Metal Prices, or allocate by weight instead.
- **Undo:** re-allocate. Allocation records themselves cannot be edited.

### Step 5 — Decide what the output batch is for

An output batch carries two independent answers: how much of it has been sold, and what it is
for. The second is set by hand.

- **Page:** Operation → Output → open the batch (**Edit Output**), section **Purpose**.
- **Permission:** `module.processing.edit`. Promising a batch to the plant is a processing
  decision, not a sales one, so a person with sales rights alone cannot change it.
- **What it means:** whether this batch is saleable stock, or is already earmarked as feed for a
  downstream operation. This is a separate axis from the sales state: a batch can be both in
  stock and already promised to the plant.
- **If earmarked:** selling, reserving and shipping are all refused. That is not a statement that
  the material may not be sold. Release it back to saleable stock and it sells.
- **Undo:** change the purpose back. Both directions need processing edit rights.

### Step 6 — Record the safety state of the output batch

Self-produced material faces the same gate as bought material.

- **Page:** Operation → Output → open the batch (**Edit Output**), section **Safety state**.
- **Permission:** `module.output.edit`.
- **If not done:** *"No safety state has been recorded. That means NOBODY HAS LOOKED, not that
  the batch is safe."* The batch cannot be fed into any operation until someone records one here.

---


## 2.4 Selling, from quotation to cash

Material leaves this company by one of two routes. They are separate processes, not two ways of
doing the same thing. Read the first paragraph of each before deciding which one you are in.

**The order flow** starts from a quotation, produces a sales order, reserves specific stock,
invoices, then ships. It posts to the ledger at invoicing and again at shipment.

**The direct sale** records a sale straight off an output batch. It moves stock and posts at the
moment of sale. Invoicing afterwards is a separate, later act that gathers posted sales onto a
document and posts nothing.

### 2.4.1 The order flow

**The order is invoiced before it is shipped.** Most people describe a sale the other way round,
so this is the first thing to fix in your head. The system enforces it line by line, and the
invoicing panel states it on screen: *"Order flow requires INVOICE BEFORE SHIPMENT."*

#### Step 1 — Raise the quotation

- **Page:** Sales → Quotations → **New quotation**.
- **Permission:** `module.sales.edit`.
- **What it is:** the document before the commitment. A quotation touches no stock and no
  ledger. Its one special power is converting into a sales order, copying the quote exactly.
- **The customer does not have to be onboarded.** A name and a country are enough, which is the
  point: you quote people before they buy.
- **Both dates are required and neither is defaulted.** The validity date is a commitment, and a
  defaulted one would never expire on the day it should.
- **Saving creates a draft.** Issuing is a separate step, and issuing is what sends it to the
  customer.
- **Undo:** a quotation stays editable after issue, because negotiating is what it is for.
  Changing it after issue puts a banner on the page: *"This quotation has been changed since it
  was last issued — the copy the customer holds no longer matches."* Re-issue it to send the
  current version. Each issue appends a version, and older versions are kept.

#### Step 2 — Issue it

- **Page:** the quotation, **Issue PDF**.
- **Permission:** `module.sales.edit`.
- **If there are no lines:** *"Add at least one line first."* An issued quotation with no lines
  is a blank page to the customer.
- **The system does not know whether the customer received it.** There is no "sent" flag,
  because the system cannot see what the counterparty received.

#### Step 3 — Convert it to a sales order, or record the decline

- **Page:** the quotation, **Convert to sales order** or **Record decline**.
- **Permission:** `module.sales.edit`.
- **If the quotation was never issued:** *"Issue this quotation first."* A draft has not been
  offered to anyone yet.
- **If it expired:** *"This quotation expired on {date}, so it cannot be converted."* Change the
  validity date and issue a new version, so that the customer is looking at a price that is
  still on offer.
- **If it was declined, or already converted:** refused by name, naming the order it became.
- **The order date is the day the customer accepted, not the quotation date.** It decides the
  order number's year and the FX period, so it is never filled in for you.
- **What conversion does:** creates a draft sales order copying the quotation exactly — same
  lines, quantities, prices, price provenance, currency and FX rate, with nothing re-derived.
  The quotation then freezes, so that the offer and the order it produced cannot drift apart.
- **Declining requires a reason.** Three months later nobody remembers why a quotation did not
  close.
- **Undo:** **there is no undo of a conversion.** The quotation is frozen from that moment:
  *"Quotation {code} became a sales order and can no longer be changed."* If the order was
  wrong, cancel the order and raise a new quotation.

A sales order can also be raised directly at Sales → Orders → **New order**, without a
quotation.

#### Step 4 — Confirm the order

- **Page:** the order's own page, **Confirm order**.
- **Permission:** `module.sales.edit`.
- **What it does:** freezes customer, currency, FX rate, order date and all lines. Notes stay
  editable.
- **If the customer is on credit hold:** *"Customer {code} is on credit hold, so this order
  cannot be confirmed."* Lift the hold under Customers, or leave the order as a draft.
- **If the order has no lines:** refused. An order with nothing on it cannot be confirmed.
- **Undo:** a confirmed order can be **cancelled**. It cannot be returned to draft.

#### Step 5 — Reserve the stock

Shipping consumes a reservation, so this step is not optional. Only a reservation says which
batch and which location the goods come from.

- **Page:** the order's own page, **Reserved stock** section, **Reserve**.
- **Permission:** `module.sales.edit`.
- **If the order is not confirmed:** *"Order {code} is a {status}, so stock cannot be reserved
  against it."* A draft is not yet a promise; confirm the order first.
- **Only output batches can be reserved.** Sales draw from output batches, and incoming material
  has to be processed first.
- **If the batch is earmarked for processing:** *"Batch {code} is earmarked as {purpose}, so it
  is not saleable stock and can be neither reserved nor shipped."* That is not a statement that
  the material may not be sold. Release the earmark on the output batch page, or use a different
  batch.
- **If you try to reserve more than the line is for:** *"Cannot reserve {qty} — this line is for
  {line} and {already} is already spoken for (shipped plus reserved)."* Reserving more would
  promise the same line twice.
- **If the batch does not hold that much:** *"Cannot reserve {qty} — only {available} is
  available in that batch and location."* Reserving does not create stock; it sets aside what is
  already there.
- **What reserving does:** moves that quantity into the committed bucket for the line. Sales and
  processing cannot touch it until it is released here, or shipped.
- **Undo:** **Release**, with a reason. A reason is required because taking back a promise is
  exactly what nobody can reconstruct later. Releasing returns the stock to available. A partial
  release cancels the reservation and records a new one for the remainder, so each row stays a
  true record of what was promised. The system never releases a reservation for you.

#### Step 6 — Invoice

- **Page:** the order's own page, **Invoicing** section, **Create invoice ({n} line(s))**. This
  is on the sales order, not on the Finance → Invoices page.
- **Permission:** seeing the section needs `module.finance.view`; raising the invoice needs
  `module.finance.edit`, because an invoice is a posting document.
- **If the order is still a draft:** *"Only a confirmed order can be invoiced."*
- **The issue date decides the posting period and is required.** It is never defaulted.
- **What it posts:** AR against contract liability, at the order's rate. Shipping requires this
  invoice. The credit limit is checked here, because invoicing is where the exposure is created.
- **Per line.** You can invoice part of an order, and then ship only that part.
- **Undo:** **void the invoice**, but only while it is still voidable. Voiding is refused once
  anything has been settled against it, and refused once anything has shipped against it. After
  that the correction is a **credit note**.

#### Step 7 — Ship

- **Page:** the order's own page, **Ship**. You pick which reservation is being shipped.
- **Permission:** `module.sales.edit`.
- **A ship date is required:** *"The ship date is required — it is the day the goods physically
  left, and it decides which period the revenue lands in. Nothing was saved."*
- **If the line is not on a live issued invoice:** *"Line {n} of order {code} is not on a live
  posted invoice."* Order flow is invoice-before-shipment: raise the invoice first. Nothing is
  shipped in the meantime.
- **If the line is not reserved:** *"No active reservation on this line."* Reserve the stock
  first.
- **If you ship more than is reserved:** *"Cannot ship {qty} — that reservation is for
  {reserved}."* Reserve more first, or ship what is reserved.
- **If the order is not in a shippable state:** refused. Only a confirmed or partially shipped
  order can ship.
- **What it does:** writes a shipment (`SHP-`), moves the stock out, releases the contract
  liability into revenue at the rate stored on the invoice, and moves the order to **Partially
  shipped** or **Shipped**. Shipping creates no new receivable: the debt was recognised when the
  invoice was raised, and that invoice stays the one and only AR row for the order.
- **Undo:** **there is no undo.** A shipment cannot be edited or deleted, and the invoice behind
  it can no longer be voided.
- **One line on the confirmation dialog is wrong.** It says corrections would go through a
  credit note *"which does not exist yet"*. Credit notes do exist. Finance → Credit notes is the
  register, and one is raised from the invoice.

#### Partially shipped is a dead end

Read this before you ship, not after.

Once an order reaches **Partially shipped** it has no legal move to any other status. Not back
to confirmed, not on to shipped except by shipping the rest, not to cancelled, not to closed.

The way to correct a partially shipped order is a **credit note**. It is raised on the invoice's
own page: **Finance → Invoices → the invoice → Raise a credit note**, which needs
`module.finance.edit`. The Credit notes page in the menu is the register, not the place a credit
note is created. A credit note is immutable from the moment it is created. It has no status, it
cannot be edited, and it cannot be deleted. Read it back before you save it.

#### Step 8 — Take the cash

- **Page:** Finance → Receivables, or Finance → Payments → **+ Record Payment**.
- **Permission:** `module.finance.edit`.
- **What it does:** settles the invoice.
- **Undo:** **there is no undo.** A payment is reversed, not deleted.

### 2.4.2 The direct sale

Where material is sold straight off an output batch with no order behind it.

#### Step 1 — Record the sale

- **Page:** Operation → Output → open the batch (**Edit Output**), section **Record Sale**.
- **Permission:** `module.output.edit`.
- **What is required:** quantity, unit price, currency, exchange rate, sale date, and normally a
  customer. The sale date sets the FX rate used, the inventory movement date, and the period
  both journals post to, so it is never filled in for you.
- **Pricing** can be a manual price, a spot price at market, or a formula. Choosing a formula
  and pressing **Compute price** fills it in and shows the working. Editing the figure
  afterwards reverts it to manual.
- **If no customer is chosen:** the form warns rather than refusing. The sale is recorded, but it
  is not credit-checked and it does not count towards anyone's exposure. It belongs to nobody
  until a customer is attached to it later, and it cannot be invoiced to a customer before that.
- **Credit control:** if the customer is on hold, or the sale would take them past their limit,
  the sale is refused. The panel shows the limit, the outstanding and the headroom before you
  press the button.
- **If the batch is earmarked for processing:** refused, as for reservation.
- **What it does:** moves the stock out and posts both the revenue and the cost of goods sold.
- **Undo:** **there is no undo.** The sale record cannot be edited or deleted, and the stock
  movement it wrote cannot be removed. A credit note is not the route here. Credit notes apply
  to order-flow invoices only. For a direct sale, the correction is to void the invoice or
  reverse the receipt.

#### Step 2 — Invoice the sale

- **Page:** Finance → Invoices → **+ New Invoice**.
- **Permission:** `module.finance.view` to open the page, `module.finance.edit` to save it.
- **What it does:** gathers posted sales that are not yet on a live invoice onto one invoice for
  a chosen customer. This kind of invoice does **not** post a journal entry. The ledger entries
  were already made when the sale was recorded.
- **Sales with no customer are listed** and marked as such. They can be invoiced to the customer
  you choose.
- **Undo:** void the invoice, subject to the same limits as above. A credit note cannot be
  raised against this kind of invoice.

---

## 2.5 Stocktake

The people involved: whoever counts on the floor; whoever reviews the differences and posts.

### Step 1 — Open the stocktake

- **Page:** Inventory → Stocktakes → **+ New Stocktake**.
- **Permission:** `module.stocktakes.edit`.
- **What it does:** opens a count (`ST-`) with status **Open**, listing the batches to be
  counted.
- **Undo:** **Cancel Stocktake**, with a reason. The counted lines are kept for the record but
  will never be posted. Who cancelled it and why are both recorded.

### Step 2 — Count

- **Page:** the stocktake's own page, or the batch page while a count is running. The batch
  page shows a banner: *"Stocktake {code} in progress — record this batch's count."*
- **Permission:** `module.stocktakes.edit`.
- **What you enter:** a counted quantity per batch, and optional notes. The page shows
  **Current**, **Book**, **Counted** and **Delta** side by side, and summarises how many batches
  have been counted and how many of them differ.
- **Undo:** **Re-count** re-opens a line. Nothing has left the ledger yet.

### Step 3 — Review and post

- **Page:** the stocktake → **Review & Post**.
- **Permission:** `module.stocktakes.edit`.
- **What posting does:** writes one adjustment movement per differing batch and sets its stock to
  the counted quantity. If there are no differences the page says so, and posting changes
  nothing.
- **If the stocktake is not open:** refused. *"Stocktake is not open (status: {status})."*
- **If a batch on the count has since been deleted:** *"Batch {code} has been deleted."*
- **Undo:** **there is no undo.** A posted stocktake is final and has no transition out. The
  adjustment movements it wrote cannot be removed. To correct a wrong count, open a new
  stocktake and count again.

---

## 2.6 Month-end close

The people involved: finance, with HR for the payroll steps.

Closing a period locks it. The work is to get every open item settled first, and the
**Month-end** page lists those items as steps you can walk down.

- **Page:** Finance → Month-end.
- **Permission:** `module.finance.view` to read it. Each step's own page has its own permission.

The page shows ten steps, each marked **done**, **outstanding**, **blocked** or **n/a**, each
linking to the page that clears it:

| # | Step | Where it is cleared |
|---|---|---|
| 1 | Board rates entered for every foreign-posting day | Finance → FX Rates |
| 2 | Payroll posted | HR → Payroll |
| 3 | Employees paid | Finance → Salary payments |
| 4 | CPF remitted | Finance → Salary payments |
| 5 | Deductions remitted | Finance → Salary payments |
| 6 | Processing accruals settled | Finance → Cost settlement |
| 7 | Batch costs match cost entries | Operation → Processing runs |
| 8 | Depreciation posted | Finance → Fixed assets |
| 9 | Revaluation run | Finance → Revaluation |
| 10 | Period locked | Finance → Close |

Three of these report themselves as blocked rather than merely outstanding: employees cannot be
marked paid before the payroll is posted; a currency with no mid rate on file for the date has
to have one entered under FX first; and the revaluation has to be run before the step that
depends on it.

**CPF is not a reason to hold the close.** It is due by the 14th of the following month and its
journal lands in that month, so locking this month does not block it.

### Locking the period

- **Page:** Finance → Close.
- **Permission:** `module.finance.edit`.
- **Refused, in this order:**
  - the date given is not a month end;
  - that period is already closed;
  - depreciation has not been run for the period: *"Depreciation of {amount} is still
    outstanding — the period cannot be locked until it is posted."* Locking first would make the
    charge unreachable without reopening the period;
  - a committed processing run still has no cost allocation;
  - the trial balance does not balance.
- **Undo:** **Reopen**, on the same page, with a reason. The period's entries become editable
  again, the close record is kept, and the lock date moves back. Reopening the same close twice
  is refused by name. Reopening a month does not reopen a closed financial year: an entry dated
  inside a closed year is still refused until the year itself is reopened.

### Closing the financial year

Also on the Close page, and separate from the monthly lock. It has its own preview and its own
checks: the final month closed, trial balance level, revaluation level and depreciation level.
Draft payroll periods and open accruals are flagged as warnings and do not block it.

Closing the year takes every P&L account to zero and posts the net result to 3100. The year then
refuses new entries until it is deliberately reopened.

**Undo:** **Reopen year**, with a reason. The closing entry is reversed, the audit trail is
kept, and the year accepts entries again.

### Filing GST

Separate from the month-end close, and quarterly.

- **Page:** Finance → GST.
- **Permission:** `module.finance.edit`.
- **The return must tie before you file:** *"THE RETURN DOES NOT TIE — do not file it until the
  difference is explained."* The page names the two checks that can fail: documents against
  statute, and documents against ledger.
- **A quarter cannot be filed while its books are still open:** *"This quarter ends on {end} but
  the books are only closed up to {locked}."* A filed return whose entries can still change is
  not a record of anything.
- **The filing itself happens elsewhere.** Filing happens on the IRAS portal. This system records
  what was filed, when, and by whom; it submits nothing.
- **Undo:** **there is no undo.** A filed return is a record of what was filed and is never
  edited. The correction is **Raise a correction**, which creates a new return pointing at the
  one it corrects, leaving the original exactly as it was filed.

---

# PART 3 — MODULE REFERENCE

Nine modules sit on the top bar. Each is taken in turn below: what it is for, the pages under
it, what each page does, and the documents it produces with the states those documents move
through.

Where a state is **final**, nothing moves the document out of it.

Where a page has no menu entry, the entry point is given. Section 3.10 lists them all in one
place.

**Seven of the nine modules open with a menu entry called Overview.** Tools and Settings have
none. The page itself is headed with the module's name rather than the word Overview, so
"Purchasing → Overview" opens a page headed **Purchasing**. Six of the seven carry only the
facts that span several of the module's pages and that no single page can state on its own; the
pages themselves are in the menu above. Inventory's is older and different in shape; see 3.6.

## 3.1 Purchasing

What you buy, who you buy it from, and what has arrived against it.

| Page | Menu | What it does |
|---|---|---|
| Overview | yes | What is still coming in — orders confirmed or part-received, how many are past their expected delivery date, and how much buying runs under a contract. |
| Purchase orders | yes | The order register. Raise, amend, close, reopen and cancel orders. |
| Receiving discrepancies | yes | Where what arrived does not match what was ordered: short, over, declared against weighed, a different material than ordered, or an assay outside tolerance. Each is measured against a threshold set under receiving settings. |
| Payment terms | yes | Instalment templates that can be applied to an order: share, trigger and due date per instalment. |
| Suppliers | yes | Supplier master data, compliance certificates and attachments. |
| Contracts | yes | The contract register, and the only place a contract is created. |
| Licences | yes | This company's own licences, not a supplier's: number, kind, issuing body, validity and the approved storage limit. A supplier's licences live on that supplier's own compliance record. |
| Commissions | yes | Commission agreements with agents. Also under Sales. |
| Inbound | yes | Received batches. Also under Inventory and Operation; see 3.6. |
| Field Receiving | **no** — from **Inbound** | Weigh and book in one material at the scale, optionally against a purchase order line. |

### The purchase order

Code `PO-`. Two kinds, chosen when it is raised and never mixed: **Materials** and
**Equipment**.

**States:** Draft · Confirmed · Receiving · Closed · Cancelled.

| From | To | By |
|---|---|---|
| Draft | Confirmed | Approving it. See the note below on why you will not see this in practice. |
| Confirmed / Receiving | Closed | **Close order**, with notes if a deposit is unresolved |
| Closed | back to its previous state | **Reopen**, with a reason |
| any live state | Cancelled | **Cancel order**, with a reason, and only while nothing has been received and no deposit released |

**Final:** Cancelled. A cancelled order is closed for good and cannot be reopened. Closed is not
final: it reopens.

**Approval status** is a second, separate marker on the order: Pending · Approved · Rejected.
Both Approved and Rejected are final, and neither can be changed once set. Because approvals are
switched off, every order is created with approval status **Approved** and status
**Confirmed**. In practice you will never see a draft purchase order.

**Deleting:** marked, not removed.

### The contract

Code `CON-`. Created at Purchasing → Contracts → **New contract**.

Creating a contract needs edit rights on whichever side it is with: `module.suppliers.edit` for
a contract with a supplier, `module.customers.edit` for one with a customer. Reading the
register needs `module.suppliers.view`, so a person who holds only customer access cannot open
the register at all.

**What you record:** who the contract is with, a **Kind** (Supply, Offtake, Framework, Service,
Other), a **Title**, an **In force from** date, an optional **In force until** (blank means no
fixed end, and means exactly that), optional headline terms (signed date, currency, incoterm,
payment terms in days, document reference, notes) and a **Status**.

A contract is with a supplier or with a customer, never both. Picking a supplier makes it a
buy-side contract; picking a customer makes it sell-side. Where the same company is both to you,
that is two contracts, because they are two agreements.

**Status is chosen at creation and is permanent.** The two choices are **Active** and
**Draft**:

- **Active** — purchase and sales orders can be linked to this contract, and a linked order
  copies its terms.
- **Draft** — still being negotiated. The contract is recorded and readable, but no order can be
  linked to it, and anything raised against it is refused.

The form states plainly that the choice cannot be revisited: nothing in the system moves a
contract from one status to another, so whichever you pick is what it stays. Pick Draft only if
you are content for the contract to stay unusable.

The other three values a contract can hold — Suspended, Expired, Terminated — appear in the
register but cannot be chosen at creation and cannot be reached afterwards.

**After creation, the only thing you can do with a contract is read it.** It cannot be edited,
amended, moved to another status or deleted. Record it only when you are content with what it
says.

**There is also no screen yet for linking an order to a contract.** A contract can be recorded
and read, and the register reports against it, but no page attaches a purchase order or a sales
order to one.

**Undo: there is none.** A contract recorded wrongly stays in the register as recorded.

**Refusals when creating one:**

- *"A contract is with exactly one party — either a supplier or a customer, not both and not
  neither. Nothing was saved."*
- *"The contract needs a title, so that a person reading the register can tell what the
  agreement is. Nothing was saved."*
- *"The date the contract takes effect is required."* Without it the register cannot say whether
  the agreement was in force when an order was raised.
- *"The end of the term is earlier than its start, so nothing was saved."*
- *"Payment terms must be a whole number of days between 0 and 365. Nothing was saved."*
- *"Recording a contract needs permission to edit whichever side it is with."*

**What a contract is for.** A purchase order is not a contract. A long-term supply agreement is:
it is the relationship a document is raised under. Contract terms — grade specification,
insurance obligations, volume commitments — live on the contract, and a document raised under
one copies the terms in force at that moment. Later edits to the contract do not reach it. The
register also reports grade specifications not met, measured against the specification the
document copied when it was linked.

**Read the coverage figures before the breach figures.** Nothing forces a document to carry a
contract, and that is on purpose, because spot purchases do not run under an agreement. So "no
contract breached" can also mean "nobody linked anything".

### Payment term templates

A template holds instalments: a label, a share, a trigger event and a due date offset. Applying
one to an order writes its schedule onto that order. Percentages across instalments cannot
exceed 100. A template with a fixed-amount instalment must state the currency that amount is in.

Editing a template replaces all its lines. Templates are read only when applied, so changing one
does not reach orders that already used it.

**Removing an instalment line removes the row outright.** It is not marked as deleted and it is
not listed on Settings → Deleted records.

## 3.2 Logistics

Getting goods from one place to another, and the paperwork that has to travel with them.

| Page | Menu | What it does |
|---|---|---|
| Overview | yes | Where every container has got to, counted by its latest milestone; how many shipments are not yet attached to a container. |
| Forwarders | yes | Freight forwarders, their rate quotes and contacts. |
| Lanes and document checklists | yes | Routes, and which documents each route requires. |
| Containers | yes | Containers (`CTR-`), their milestones, their ETA and their documents. |
| Freight | yes | Freight invoices. Also under Finance. |

**Logistics has no edit capability.** There is `module.logistics.view` and nothing else. Writing
to logistics data is gated on `module.purchasing.edit`. On the role screen the Edit box for
Logistics is drawn as a dash, with a note that the module has no separate edit permission and
its View permission is the whole of it.

### Freight

A freight invoice is recorded at Finance → Freight → **+ Record freight**, on a page headed
**Record a freight invoice**. It needs `module.finance.edit`.

**Freight is capitalised, not expensed.** It goes into the cost of the material it carried. The
page states the trade-off that comes with that: a wrong apportionment now sits inside inventory
instead of showing on the P&L.

You choose the basis on which the freight is spread across batches, by weight or by value. The
two diverge most when it matters most, on a light expensive batch travelling with heavy cheap
material. Pick the one the invoice actually supports; where the forwarder itemised per batch,
use that.

**Undo:** **Reverse this freight document**. A reversed document has no reverse button, because
reversing it again is refused by name.

## 3.3 Operation

The plant: what was planned, what ran, and what came out.

| Page | Menu | What it does |
|---|---|---|
| Overview | yes | Plan against what actually happened, and how much output is still mid-process. |
| Work orders | yes | The plan register (`WO-`). |
| Processing runs | yes | What actually ran (`PROC-`), with inputs, outputs, loss and cost. |
| Work in progress | yes | Output batches earmarked as feed and still holding quantity — what is waiting, how much, and for which operation. |
| Shift handover | yes | What one shift hands to the next. |
| Inbound | yes | Also under Purchasing and Inventory. |
| Output | yes | Also under Inventory. |

### Work order

Code `WO-`. **States:** Draft · Released · Closed · Cancelled.

| From | To | By |
|---|---|---|
| Draft | Released | **Release** |
| Draft | Cancelled | **Cancel order**, with a reason |
| Released | Closed | **Close**, with a reason |
| Released | Cancelled | **Cancel order**, refused once any run has been worked against it |

**Final:** Closed and Cancelled. There is no un-release and no un-close.

Closing a plan short of its quantity is allowed and recorded. A rule forcing you to shrink the
plan before closing it would erase the variance instead.

**Amending** a released plan is allowed with a reason, but a planned quantity cannot go below
what the linked runs have already consumed.

**A work order has no deleted marker.** It cannot be deleted at all.

### Processing run

Code `PROC-`. **States:** Committed · Reversed.

A run is created committed. The only move is **Delete Processing Run**, with a reason, which
sets it Reversed, restores the consumed inputs, voids the output batches and writes reversing
movements. **Reversed is final.**

A reversed run stays listed against its work order, because it really was worked against that
order, but its consumption no longer counts anywhere.

**Loss is recorded in categories, not as one number.** Water and volatiles leave but the metal
stays. Dust and spillage take the metal with them. Residue sent for disposal is not a loss at
all. Collapsed into one number, recovery could never be right. Categorised amounts need not add
up to the run's loss total, but may not exceed it.

**Cost allocation** is a separate act, described in 2.3 step 4.

### Shift handover

Records what one shift hands to the next: the date, the shift, who handed over, who took over,
and the content. The incoming person **acknowledges** it, and until they do the state is named
rather than blank: *"Unacknowledged means THE NEXT SHIFT HAS NOT SAID THEY READ THIS."* It does
not mean the field is empty.

A handover does not record what the shift processed, because a processing run carries only a
date and no time of day, so no run can be attributed to a shift. Nor does it record incidents:
those belong on the workplace incident and near-miss register, which is not yet built. Equipment
tick boxes point at downtime already recorded elsewhere rather than restating it.

## 3.4 Sales

Offering, committing, and getting paid.

| Page | Menu | What it does |
|---|---|---|
| Overview | yes | Where the work is sitting across quote → order → shipment → invoice, and credit exposure with the customers who have no limit set. |
| Quotations | yes | The quotation register (`QT-`). |
| Orders | yes | The sales order register (`SO-`), with reservation, invoicing and shipping on each order's page. |
| Customers | yes | Customer master data, credit limits and holds. |
| Commissions | yes | Commission agreements. Also under Purchasing. |
| Counterparty overlap | **no** — from **Customers** | Companies that are both a customer and a supplier. |

### Quotation

Code `QT-`. **States:** Draft · Issued · Declined · Converted.

| From | To | By |
|---|---|---|
| Draft | Issued | **Issue PDF** |
| Issued | Declined | **Record decline**, with a reason |
| Issued | Converted | **Convert to sales order** |

**Final:** Converted and Declined. A converted quotation is frozen: *"Quotation {code} became a
sales order and can no longer be changed."* The offer and the order it produced must not drift
apart.

A quotation stays editable after issue, and re-issuing appends a version rather than replacing
one. Older versions are kept, because the copy the customer holds is a specific version.

**Deleting:** marked, not removed.

### Sales order

Code `SO-`. **States:** Draft · Confirmed · Partially shipped · Shipped · Closed · Cancelled.

The permitted moves, in full:

| From | To |
|---|---|
| Draft | Confirmed, or Cancelled |
| Confirmed | Cancelled (and to Partially shipped / Shipped by shipping) |
| Partially shipped | **nothing** |
| Shipped | Closed |
| Closed | final |
| Cancelled | final |

**Partially shipped is a dead end.** It has no legal move out. Not back, not forward except by
shipping the remainder, not to cancelled. **The way to correct a partially shipped order is a
credit note**, raised on the invoice's own page. That is the undo slot for this state, and there
is no other.

**Final:** Closed, Cancelled, and in practice Partially shipped.

The order page lists the moves available from wherever it is, rather than listing what is
forbidden. The database holds the same table and always wins. Where nothing is left, the page
says the order is in a final state with no further transitions.

**Deleting:** marked, not removed.

### Shipment

Code `SHP-`. **No status at all, and no way to change it.** A shipment is written by shipping an
order and nothing else writes one. It cannot be edited and it cannot be deleted.

**Undo: there is none.** The correction is a credit note.

### Customers

Customer master data: legal name, country, contacts, credit limit and credit hold. A customer's
status is free text with no state machine behind it. It is an attribute of the record, not a
document lifecycle.

**Credit control** happens in two places. On the order flow it is applied when the invoice is
raised, because invoicing is where the exposure is created. On a direct sale it is applied when
the sale is recorded. A customer on hold blocks both.

A sale recorded with no customer belongs to nobody. It can be attached to a customer afterwards
on the receivables page, and that attachment is **one-way**: it cannot be changed to a different
customer or undone.

## 3.5 Finance

The ledger, and everything that posts to it. This is the largest module and the only one with a
third level in its menu: **Reports · Journal · Receivables · Payables · Period end ·
Configuration**, with Overview above them.

Everything here needs `module.finance.view` to read. Anything that posts needs
`module.finance.edit`.

### Overview

The state of the books: which day the books are locked to, the ledger against the sub-ledgers
for receivables, payables, raw stock and finished stock, and the net position. Where a figure
cannot be reached the page says so rather than printing a zero, because answering anyway would
give a confident 0.00.

### Reports

| Page | What it does |
|---|---|
| Trial Balance | Every account and its balance. |
| P&L | Profit and loss for a period. |
| Balance Sheet | Assets, liabilities and equity as at a date. |
| Cash flow | Cash movement for a period. |
| Cash forecast | What is expected to come in and go out, week by week over thirteen weeks, in the currency it actually moves in. Amounts with no date are listed separately and are not in any week. |
| Price exposure | Material bought on a floating price against material sold on a fixed price. The purchase side is not modelled, and the page states that rather than showing a zero. |
| Batch Gross Margin | Revenue per output batch against its allocated processing cost. Needs `data.view_prices` **and** either finance or processing access. |

The margin page carries a distinction that catches people. Its cost figure is the run's current
allocated unit cost multiplied by the quantity sold. The general ledger posts cost of goods sold
once, at the moment of sale, and never restates it. The two figures are different and both are
correct.

### Journal

**Journal** lists entries. **New Entry** raises one by hand.

Journal entry, code `JE-`. **States:** Posted · Reversed. The only move is a reversal.
**Reversed is final.** A journal entry cannot be edited and cannot be deleted.

### Receivables

| Page | What it does |
|---|---|
| Receivables | What customers owe, by document, with ageing. |
| Invoices | The invoice register (`INV-`), and **+ New Invoice** for gathering posted direct sales onto a document. |
| Credit notes | The credit note register (`CN-`). A credit note is raised from the invoice it credits, not from here. |

**Invoice**, code `INV-`. Two kinds. An **order** invoice is raised from a sales order and posts
to the ledger. A **sale** invoice gathers already-posted direct sales and posts nothing.

**States:** Issued · Void. The only move is **void**, and voiding is refused once anything has
been settled against the invoice or anything has shipped against it. **Void is final.** An
invoice cannot be edited and cannot be deleted.

**Credit note**, code `CN-`. **No status column and no transitions. It is immutable from the
moment it is created**, and cannot be edited or deleted.

A credit note reduces what the customer owes on that one invoice, after the invoice can no
longer be voided. It is not a refund: no money moves, and it cannot take the invoice below zero.

Credit notes apply to order-flow invoices only. For an invoice that gathered direct sales, the
correction is still to void the invoice.

The credit note date is required and never defaulted. It decides which accounting period the
reversal lands in, and a defaulted date could never hit a locked period, so leaving it blank
would slip through where filling it in correctly does not.

### Payables

| Page | What it does |
|---|---|
| Payables | What is owed, by document, with ageing. |
| Payments | The payment register (`PMT-`), and **+ Record Payment**. |
| Expenses | The expense register (`EXP-`), and **+ New Expense**. |
| Expense claims | Staff expense claims (`CLM-`) raised in HR and turned into payables here. |
| Fixed assets | The asset register (`FA-`), depreciation and disposal. |
| Freight | Freight invoices. Also under Logistics. |

**Payment**, code `PMT-`. **States:** Posted · Reversed. The only move is a reversal.
**Reversed is final.** It cannot be edited or deleted.

**Expense**, code `EXP-`. Its marker is a payment status: Unpaid or Paid. The correction is a
reversal. It cannot be edited or deleted.

**Fixed asset**, code `FA-`. **States:** Active · Disposed. Moves: put in service, record
acceptance, dispose. **Disposed is final.** An asset card has no deleted marker.

An asset card can carry maintenance intervals and, where the purchase order had retention terms,
a retention clock. **Retention is never paid automatically.** When it falls due, confirm that the
machine gave no trouble during the retention period, then state how much is released and how
much is withheld.

**Removing a maintenance interval removes the row outright**, and it means something specific:
that this machine is no longer watched for this kind of work. That is not the same as leaving it
monitored but off the dashboard.

### Period end

| Page | What it does |
|---|---|
| Month-end | The ten closing steps, each linking to the page that clears it. See 2.6. |
| Salary payments | Pay employees, remit CPF, remit deductions. |
| Cost settlement | Turn processing accruals into real invoices and post the variance. |
| Revaluation | Restate foreign-currency balances at the closing rate. |
| Cost variance | Estimated against actual processing costs, by cost type across months. |
| Close | Lock a period; reopen a locked one with a reason. |
| GST | The quarterly return and its filing record. |
| Withholding tax | Tax withheld from payments to non-residents, and what is owed to IRAS. |
| Monthly pack | The month in one document: statements, ageing, reconciliation, and what it cannot see. |
| Bank | Bank reconciliation. |

**Cost settlement** distinguishes two things on one page: actual costs waiting to be remitted,
and estimates waiting to be relieved with the real invoice. Relieving posts the variance, and
the invoice date decides which month it lands in — relieving a July accrual with an August date
puts the variance in the wrong month.

**Revaluation** refuses without a closing mid rate for every foreign currency in play. Re-running
the same date posts nothing.

**Close.** A period close records who closed it and when. Reopening asks for a reason and warns
that the period's entries become editable again. Closing the financial year is a separate act
with its own preview: every P&L account is taken to zero, the net result posts to 3100, and the
year then refuses new entries until it is deliberately reopened.

**GST period. States:** Open · Filed. **Filed is final** — a filed return is a record of what was
filed and is never edited. The correction is a new return that points at the one it corrects. A
GST period has no deleted marker.

**Monthly pack.** A stored pack means the month was already closed when it was produced. Open
months can be previewed and exported but are never stored.

**Bank** — reconciliation. **Bank statement**, code `STMT-`. **States:** Open · Reconciled, and
this one is reversible: reconciling and unreconciling both exist.

Two sub-pages have no menu entry, both reached from the Bank page: **Statements** and **Import
Statement**. Importing maps CSV columns to fields, and the mapping can be saved for next time.
The reconciliation identity is printed on the page: closing balance, plus items on your books
the bank has not shown, plus items the bank shows that are not on your books, equals the ledger
balance.

**Transfer between own accounts** is on the Bank page. Both amounts are entered exactly as the
bank reported them, in their own currencies, so both statements can reconcile.

### Configuration

| Page | What it does |
|---|---|
| Settings | Company-wide finance settings, including the default cost allocation basis and the period lock date. |
| Company | Company details as they print on documents, and GST registration. |
| FX Rates | Exchange rates by date and currency. |

**FX Rates** has one sub-page with no menu entry, reached from the FX page: **Enter a week**, a
grid for filling gaps. Cells that already hold a rate are read-only there. To change one, open
it from the link in the cell and give a reason, which keeps the previous number on record.

Rate history is immutable. A rate is corrected by recording a new one with a reason, not by
overwriting.

## 3.6 Inventory

What is on hand, where it is, and what it is worth.

| Page | Menu | What it does |
|---|---|---|
| Overview | yes | Headed **Inventory**. Material balance across all processing runs, and current stock by material, backed by the movement ledger. This overview is a stock listing rather than the set of cross-page facts the other module overviews carry. |
| Storage locations | yes | Locations, their zones, and which material classes each one accepts. |
| Stocktakes | yes | Physical counts (`ST-`). |
| Materials | yes | The material dictionary. |
| Reports | yes | Four read-only reports; see below. |
| Inbound | yes | Received batches (`IN-`). Also under Purchasing and Operation. |
| Output | yes | Produced batches (`OUT-`). Also under Operation. |

### Reports

The Reports page is a card wall. All four sub-pages are reached from it and none is in the menu.
Nothing on them is stored: every figure is derived from the movement ledger when you open the
page.

| Report | What it shows |
|---|---|
| **Stock snapshot** | What is on hand, by material, location and status, with ageing. |
| **Class violations** | Stock sitting where its material class is not allowed. |
| **Safety stock** | Monitored materials and how they stand against their thresholds. |
| **Movement ledger** | Every stock movement, filterable by date, material and batch. |

The snapshot values stock at landed cost, which is purchase price plus freight plus capitalised
processing cost. That is the same definition used by write-off, stocktake and the general ledger
reconciliation. Without `data.view_prices` the value columns read **Restricted**, which is not
zero: the quantities are complete and only the money is withheld.

Stock with no location recorded is shown as its own group. That is a normal state rather than
missing data — the goods are real, and a transfer can assign a location at any time.

### Inbound batch

Code `IN-`. Its marker is a **pricing status**: Unpriced · Provisional · Final. It also carries a
**Stage**: To Process · Processing · Processed.

There is no state machine in the usual sense. Pricing status follows from what has been
recorded, and repricing moves it. See 2.1.

**Deleting:** marked, with a reason, and it writes a write-off movement for the remaining
quantity.

**A known fault in the exported file.** Download the inbound list as CSV and the stage column
holds the stored value, which is in Chinese (`待加工` / `加工中` / `已加工完`), not the English
shown on screen. The screen and the file will not read the same for that one column. Nothing
else is affected, and the stored data itself is unchanged. The output batch export does not have
this fault.

### Output batch

Code `OUT-`. It carries **two independent markers**, and confusing them is the most common
mistake on this page.

**State — how much has been sold.** In stock · Partially sold · Sold out. **This is written by
the system**, not chosen. A person picks the starting value once, when creating the batch, and
after that selling and shipping maintain it. Note what *Sold out* does and does not mean: it
means sold, not empty. A batch consumed by a downstream process also reaches zero remaining, and
does not get this state.

**Purpose — what the batch is for.** Saleable stock, or earmarked as feed for a downstream
operation. This is chosen by hand and needs `module.processing.edit`. An earmarked batch cannot
be reserved, sold or shipped.

**Deleting:** marked, with a reason, and it writes a write-off movement.

### Stocktake

Code `ST-`. **States:** Open · Posted · Cancelled.

| From | To | By |
|---|---|---|
| Open | Posted | **Confirm & Post** |
| Open | Cancelled | **Cancel Stocktake**, with a reason |

**Both Posted and Cancelled are final.** A posted stocktake has no move out, and the adjustment
movements it wrote cannot be removed. See 2.5.

### Storage locations

A location has a code, a name, a zone and a set of allowed material classes. A location with no
allowed classes shows **not configured**, which the page distinguishes from allowing nothing:
zero rows means nobody has decided yet.

Putting stock in a location that does not accept its class is refused, and the refusal names
three ways out: pick another location, add the class to that location, or correct the material's
classification.

**Removing an allowed class removes the row outright.** It is not marked as deleted and it is
not listed on Settings → Deleted records.

### Materials

The material dictionary: name, category, unit, classification and form. Material status is free
text with no state machine. It is master data, not a document.

The **form** decides saleability. A material whose form may not be sold under the law cannot be
quoted or sold. Where the form was never set the refusal is a different one, and says so: that
is not a statement that the material may not be sold, and the way out is to set the form under
Materials.

## 3.7 HR

People, pay, time and performance.

| Page | Menu | What it does |
|---|---|---|
| Overview | yes | Headcount in service, the attendance and payroll cycle, and total monthly fixed gross. |
| Employees | yes | The employee register, employment history and documents. |
| Departments | yes | Departments and their heads. |
| Attendance | yes | Monthly sheets of overtime and unpaid leave. |
| Payroll | yes | Payroll periods (`PAY-`) and their posting. |
| Leave | yes | Leave requests (`LV-`), plus five tabbed sub-pages. |
| Claims | yes | Medical claims (`MC-`). |
| Training | yes | Training records. |
| Reviews | yes | Performance reviews, plus two sub-pages. |
| KPI | yes | KPI scorecards. |
| KPI scoring | **no** — from **KPI** | Entering scores. Needs `module.hr.edit`. |
| Review cycles | **no** — from **Reviews** | Opening a review cycle. |
| Rating scale | **no** — from **Reviews** | The rating scale reviews are scored against. |
| Organisation chart | yes | Reporting lines. |

Everything here needs `module.hr.view`. Pay figures additionally need `data.view_pay`, identity
and work pass numbers need `data.view_identity`, and review content needs `data.view_reviews`.

### Leave

The Leave page carries its own tab strip — **Requests · Balances · Calendar · Annual
operations · Leave types · Public holidays** — and it is the only way to reach the five
sub-pages behind it. Requests is the Leave page itself.

**Leave request**, code `LV-`. **States:** Pending · Approved · Rejected · Cancelled.

| From | To | By |
|---|---|---|
| Pending | Approved or Rejected | **Approve** / **Reject** |
| Pending or Approved | Cancelled | **Cancel leave** |

**Approved, Rejected and Cancelled are all final** as far as the request is concerned.
Cancelling releases the days back to the grants they came from, and the ledger keeps both
entries.

**Days are counted by the system**, not typed: weekends and public holidays are excluded, and
the count is computed by the database. Where Monday-to-Friday counting is wrong, on a six-day or
shift schedule, there is an explicit exception path that asks for the days and a reason. An
exception can exceed a leave type's standard days but can never exceed an accrued annual leave
balance, because that balance is a real entitlement rather than a policy.

Refusals worth knowing before you submit:

- *"Not enough leave: {available} days available, {requested} requested."*
- *"You will have {n} days accrued by then, and you asked for {m}."* Annual leave is earned
  monthly, and the message names the date from which there will be enough.
- *"Annual leave cannot be taken during probation."* It keeps accruing month by month from the
  start date, and whatever has accrued becomes bookable on confirmation.
- *"These dates overlap request {code}."*
- *"A medical certificate is needed: {n} days already taken this year against a {m}-day
  allowance."*

**Annual operations** is where the year's entitlement is granted and where last year's unused
balance is carried forward. Both are safe to run twice: a second run is refused rather than
doubling anyone up.

**Leave types** and **Public holidays** are configuration. Day counts, certificate thresholds
and active flags are data, changed here without a release. Public holidays are added year by
year as they are gazetted, and lunar dates are not computed — they come from the official
announcement. **Removing a holiday removes the row outright**, and it is not listed on
Settings → Deleted records.

### Medical claims

Code `MC-`. **Stored states:** Submitted · Approved · Rejected · Paid.

| From | To | By |
|---|---|---|
| Submitted | Approved or Rejected | the decision |
| Approved | Paid | raising the expense and paying it |

**Paid and Rejected are final.**

The list screen shows more than four, because it refines Approved by how far the money has got:
**Submitted · Approved · Rejected · Awaiting expense · Expense raised · Part paid · Paid**.
Those extra three are read from the linked expense and its settlements, not stored on the claim.
The claim itself is in one of the four states above.

A claim is settled by turning it into a payable. **Raise expense** creates an unpaid expense on
staff welfare and medical, settled through the usual payment run. That step needs finance
permission: HR approves the claim, and finance turns it into a payable.

Refused if the claim exceeds the remaining entitlement, if it is not approved yet, or if an
expense has already been raised for it.

### Expense claims

Code `CLM-`. **States:** Submitted · Withdrawn · Approved · Rejected. A claim is decided or
withdrawn, and all three end states are final. An expense claim has no deleted marker.

### Payroll

**Payroll period**, code `PAY-`. **States:** Draft · Posted. **This one is reversible:**
**Post to ledger** and **Unpost** both exist, and unposting asks for a reason. Unposting
reverses the journal entry and returns the period to draft.

Figures are prefilled from last month, with a warning to check every row against the provider
report before saving.

### Attendance

**Attendance period. States:** Open · Complete.

| From | To | By |
|---|---|---|
| Open | Complete | **Mark complete** |
| Complete | Open | **Reopen**, with a reason, and only while that month's payroll is not posted |

The sheet is what is reported to the payroll provider each month: overtime hours and unpaid
leave. Nothing on it is calculated into pay; the provider does that.

Marking complete freezes the sheet and lets that month's payroll be posted. It is refused while
anyone is unanswered: *"{n} line(s) still have nobody's answer."* Recording zero is an answer;
leaving a line blank is not.

Once payroll is posted the sheet can no longer be reopened. Unpost the payroll first.

### Performance reviews

**States:** Draft · Self-assessment · Submitted · Approved · Acknowledged · Void.

A review is created by opening a review cycle, or raised as a probation review from the employee
record. A probation review cannot be raised without a probation end date on file, because that
date is what the confirmation decision turns on and what the reminders count down to.

Goals carry a target and a unit, and both are set together. A goal without a unit can never take
a number later: neither the self-assessment nor the reviewer can add the unit afterwards.

Finalising a self-assessment locks it, and an empty one cannot be corrected without the reviewer
reopening it.

Review content needs `data.view_reviews`. Without it, a person sees their own and no others, and
the page says so rather than showing an empty list.

## 3.8 Tools

Small things that do not belong to one module.

| Page | Menu | What it does |
|---|---|---|
| Tasks | yes | The task board. |
| Calendar | yes | Everything dated, on one month. |
| Unit converter | yes | Mass, metal grade, and wet-to-dry weight. |
| Reminders | yes | What is waiting and what is falling due, across every module. |
| Pricing | yes | A hub of three pricing pages. |

**Calendar** is read-only and open to any signed-in person, but each item obeys its own module's
permission. It gathers everything dated that you can already see elsewhere onto one month. It is
a place to look rather than a place to edit: click an item to go to the page that owns it. Where
a source could not be read, the page says the month is incomplete rather than showing it as
empty.

**Unit converter** is open to any signed-in person and reads no business data. Three conversions,
each showing its formula and where its numbers come from. The wet-to-dry conversion calls the
same database function the settlement path calls, so this tool and an invoice cannot disagree.

**Reminders** gathers waiting signals from every module, and an item appears only if your
permissions reach its own module. It separates three answers carefully: a real zero, where you
can see those items and right now they hold nothing; a permission wall, where the account cannot
answer whether they hold anything; and nothing visible at all.

**Pricing** is a card wall with three sub-pages, none of them in the menu:

| Card | What it does |
|---|---|
| **Pricing formulas** | Agreed payable percentages and charges per counterparty. |
| **Calculator** | Value a batch from its assay and current metal prices. |
| **Metal prices** | Every price recorded, newest first. |

Under Metal prices there is a fourth page, one level further down: **Bulk entry**, headed **Daily
Metal Prices**, for entering a day's prices in one go. Reading metal prices is open; writing them
needs `module.pricing.edit`.

**Removing a metal from a pricing formula removes the row outright.**

### Tasks

**States:** To do · In progress · Done. A task is either **Personal** or **Team**.

**A personal task is private, and no permission overrides that.** The page says: *"This is a
personal task. Only you can see it and change it."* Nobody else can read it: not a colleague,
not a manager, not an administrator. It is a boundary of the system rather than a permission
somebody could be granted, and no screen offers to grant it.

**Make this a team task** promotes a personal task. Once other people have worked on it the
promotion cannot be reversed, because turning it personal again would leave them unable to read
what they worked on.

Promotion needs your login to be linked to an employee record. If it is not, the page says to
ask HR to link the account.

**Steps.** A task can carry steps, and a step can carry one level of sub-steps. Steps are
reordered and renamed in place. **Deleting a step removes the row outright**, as with the other
child rows and configuration described in 1.5: it is not recorded on Settings → Deleted records
and nothing puts it back. The confirmation dialog is the only warning you get. A step that has
sub-steps is refused rather than removed with its children.

**Deleting a task** marks it, as with any other document.

## 3.9 Settings

Administration.

| Page | Menu | What it does |
|---|---|---|
| Accounts | yes | System accounts, the roles they hold, and the employee record each is linked to. Create an account. |
| Roles | yes | Roles and their capabilities. |
| Permission reference | yes | The full capability catalogue, and who holds each one. |
| Dictionaries | yes | Reference lists used by materials and receiving. |
| Bulk import | yes | Load rows from a CSV file. |
| Approvals | yes | The purchase approval chain, read-only. |
| Deleted records | yes | What was deleted, by whom, and why. |

Accounts, Roles, Permission reference and Approvals all need `action.manage_permissions`.
Deleted records needs `data.view_deleted`. Bulk import needs `action.bulk_import`. Dictionaries
needs either materials or inbound access.

**Accounts.** An account is created here, with exactly one role: an account with no role will
not be created. The account can sign in as soon as it exists, and the initial password is handed
to the person directly, who is then required to change it at first sign-in. An account can be
linked to one employee record, and an employee already linked elsewhere is not offered.

Removing a role from a person asks for a reason, and it is recorded.

**Bulk import** loads materials, counterparties, employees, departments and storage locations
from CSV. It is the only action in the system that inserts hundreds of rows at once. Each
template's third line lists the accepted values for every restricted column.

**Deleted records** is a register, not a recycle bin. There is no restore anywhere in the system.

## 3.10 Pages with no menu entry, and where to find them

Twenty-one working pages are not listed in any menu. Each is one click from a page that is.

| Page | Where the door is |
|---|---|
| Field Receiving | Inbound → **Field Receiving** |
| Import Bank Statement | Finance → Bank → **Import Statement** |
| Bank Statements | Finance → Bank → **Statements** |
| Enter a week of rates | Finance → FX Rates → **Enter a week** |
| Leave balances | HR → Leave → **Balances** tab |
| Leave calendar | HR → Leave → **Calendar** tab |
| Annual leave operations | HR → Leave → **Annual operations** tab |
| Public holidays | HR → Leave → **Public holidays** tab |
| Leave types | HR → Leave → **Leave types** tab |
| KPI scoring | HR → KPI → **KPI scoring** |
| Review cycles | HR → Reviews → **Review cycles** |
| Rating scale | HR → Reviews → **Rating scale** |
| Movement ledger | Inventory → Reports → **Movement ledger** |
| Safety stock | Inventory → Reports → **Safety stock** |
| Stock snapshot | Inventory → Reports → **Stock snapshot** |
| Class violations | Inventory → Reports → **Class violations** |
| Counterparty overlap | Sales → Customers → **Counterparty overlap** |
| Price Calculator | Tools → Pricing → **Calculator** |
| Pricing Formulas | Tools → Pricing → **Pricing formulas** |
| Metal Prices | Tools → Pricing → **Metal prices** |
| Daily Metal Prices | Tools → Pricing → Metal prices → **Bulk entry** |

---

# PART 4 — ROLE QUICK REFERENCE

## 4.1 Roles are data, not a fixed list

The roles described below are the ones this company uses today. They were fitted to how the
company is organised now, and they are not built into the system.

Permissions are composed one capability at a time. A role is a name with a set of capabilities
attached, and nothing anywhere in the system tests a role by name. Every gate asks whether the
signed-in person holds a particular capability, and that resolves through whichever roles they
hold. To every gate in the system, a role created this afternoon works exactly like one that has
been there since the beginning.

So read the table below as a description of how access is arranged today, not as a law about who
may do what. New roles can be created, existing ones renamed or re-granted, and people moved
between them, as the company grows. None of it needs a developer, a code change, a migration or
a deployment. The roles page says the same thing in one line: *"Roles and their grants are data
— changing them is an edit here, not a release."*

## 4.2 How to create a role

Everything below is gated on one capability, `action.manage_permissions`.

1. Sign in as somebody holding `action.manage_permissions`.
2. Go to **Settings → Roles** and choose **Add role**. The page notes the order of work: *"Save
   the role first, then set its permissions on the next screen."*
3. Fill in the role's **Code**, its **Name (EN)** and **Name (ZH)**, optional descriptions in
   both languages, and a sort order. The code is a stable identifier such as `warehouse`, and it
   is permanent: *"It cannot be changed later"*, and afterwards *"The code is fixed after
   creation — policies and grants identify the role by it."*
4. Save. **The role now exists and grants nothing.** It has zero capabilities until you give it
   some.
5. Open the role and tick capabilities in the permission matrix, then **Save permissions**.
6. Go to **Settings → Accounts** and give the role to a person.

Two rules the matrix enforces while you tick:

- **Edit requires View.** *"A role that can change records but not read them cannot save at all,
  because writes read the row back. Ticking Edit ticks View; unticking View unticks Edit."* If
  edit is granted without view the save is refused by name rather than quietly corrected.
- **A module with no separate edit capability shows a dash, not a box.** Logistics is the only
  one: *"This module has no separate edit permission — its View permission is the whole of it."*

Renaming, reordering and deactivating a role are all done on the role's own page. Retiring one
is done from the role list, and it warns first how many people will lose it.

## 4.3 The one thing nobody can do

**The administrator role is protected.** It cannot be deleted, cannot be deactivated, cannot be
soft-deleted, and its protected flag cannot be cleared. All four attempts are refused by name.

Alongside that, the system refuses to be left with no administrator at all. Removing the last
administrator role from the last person holding it is refused: *"This would leave the system
with no administrator, so it was refused. Grant the administrator role to somebody else first,
then remove it here."*

The protected flag is not something the interface can set, so a second protected role cannot be
made. Everything you create through the interface is an ordinary role.

## 4.4 What the capabilities are

There are 39 capabilities, in three kinds. Thirty-eight of them are listed in the tables below;
the thirty-ninth is described at the end of this section, because no role holds it and no screen
grants it.

**Module capabilities** say which part of the system you reach. Most come in a pair, view and
edit.

| Capability | What it covers |
|---|---|
| `module.customers.view` / `.edit` | Customer master data |
| `module.finance.view` / `.edit` | Ledger, receivables, payables, payments |
| `module.hr.view` / `.edit` | Employees, payroll and training |
| `module.inbound.view` / `.edit` | Inbound batches and receiving |
| `module.inventory.view` / `.edit` | Inventory and material balance |
| `module.logistics.view` | Forwarders, lanes, rate quotes, containers and shipping documents — **view only; there is no edit capability** |
| `module.materials.view` / `.edit` | The material dictionary |
| `module.output.view` / `.edit` | Output batches and sales |
| `module.pricing.view` / `.edit` | Pricing formulas, calculator, metal prices |
| `module.processing.view` / `.edit` | Processing runs and traceability |
| `module.purchasing.view` / `.edit` | Purchase orders and payment schedules |
| `module.sales.view` / `.edit` | Sales orders — create, confirm, cancel, issue |
| `module.stocktakes.view` / `.edit` | Physical counts and adjustments |
| `module.suppliers.view` / `.edit` | Supplier master data |
| `module.tasks.view` / `.edit` | The task board |

**Data capabilities** say which values you see on pages you can already open. They cut across
every module, and this is where the **Restricted** cells come from.

| Capability | What it reveals |
|---|---|
| `data.view_prices` | Unit prices, pricing formulas, costs and margins |
| `data.view_pay` | Salary, CPF and payroll figures |
| `data.view_identity` | Identity numbers and work pass numbers |
| `data.view_reviews` | Ratings, written conclusions, self-assessments and goal results in performance reviews |
| `data.view_sales` | Quantity, unit price, amount, customer and date of sales made from output batches |
| `data.view_banking` | Company bank account name, number, SWIFT and bank address as printed on invoices |
| `data.view_deleted` | The deleted-records register, across every module. Audit-natured, not a day-to-day permission. |

**Action capabilities** are two operations that stand apart from any module.

| Capability | What it allows |
|---|---|
| `action.manage_permissions` | Create roles and change who holds what |
| `action.bulk_import` | Load materials, counterparties, employees, departments and storage locations from a CSV file. The only action that inserts hundreds of rows at once. |

The thirty-ninth capability is `module.tasks.view_all`, which would let its holder read other
people's **personal** tasks. **No role holds it, and no screen can grant it.** Personal tasks are
private from everybody, including an administrator. That is a boundary of the system, not a
permission somebody could be given.

## 4.5 The roles in use today

Every role defined in the system is listed here. Roles marked **held** have at least one person
in them today; the rest are defined and waiting for one. A role with no holder still works — it
grants exactly what is listed against it the moment somebody is given it.

### System Administrator — `admin` · held · **protected**

*"Full access to everything, including who can see what."*

Holds every capability except `module.tasks.view_all`, which nobody holds. It is the only
protected role: it cannot be deleted, deactivated or stripped of its flag. One other role,
Commercial & People, also holds `action.manage_permissions` and can therefore administer
accounts and roles.

### General Manager — `gm` · held

*"Sees the whole business, including costs and margins, but cannot change who has access."*

Edit rights across purchasing, sales, customers, suppliers, materials, inbound, output,
inventory, stocktakes, processing, pricing, finance, HR and tasks. View on logistics. Sees
prices, sales, banking and review content. **Does not hold `action.manage_permissions`**, so it
cannot change roles or grants, and it does not see the deleted-records register.

### Commercial & People — `cco` · held

*"Customers, sales and everything about people, plus system administration: accounts, roles and
permissions. Reads every other module without changing it."*

Edit rights on sales, HR, materials and tasks. Read on everything else. Holds
`action.manage_permissions` and `action.bulk_import`, and every data capability. This is the
second role that can administer accounts and roles.

### CFO — `cfo` · held

*"Approves purchase orders at or above the approval threshold. Deliberately cannot raise purchase
orders."*

Five capabilities: view on finance, purchasing and logistics, plus pay and price visibility. It
holds no edit capability at all, so the role that approves a large order cannot also raise one.

Approvals are switched off, so this role approves nothing today. See 2.2.

### Finance — `finance` · held

*"Ledger, payables, receivables, invoicing and payments, with full cost visibility."*

Edit on finance, purchasing, suppliers, customers, materials, inbound, output, inventory,
pricing and tasks. View on logistics. Sees banking, pay, prices and sales. No HR, no processing,
no stocktakes.

### Operations Supervisor — `operations` · held

*"Runs processing, inventory and stocktakes: quantities, yields and recovery, never prices."*

Edit on processing, inbound, output, inventory, stocktakes, materials and tasks. View on
logistics. **Holds no data capabilities at all**, so every money column reads **Restricted**.
Quantities are complete; the prices are not shown.

### Warehouse & Field — `warehouse` · held

*"Receiving, output and stock counts on the floor; no commercial data."*

Edit on inbound, output, inventory, stocktakes and tasks. View on logistics. No prices, no sales
figures, no purchasing, no processing.

### Procurement — `procurement` · defined, nobody holds it today

*"Negotiates and raises purchase orders; sees prices but cannot pay anyone."*

Edit on purchasing, suppliers, materials, pricing, inbound and tasks. View on inventory and
logistics. Sees prices. **No finance capability**, so it cannot record an expense or a payment.

### Sales — `sales` · defined, nobody holds it today

*"Customers, output batches and sales; invoicing is handled by finance."*

Edit on sales, customers, output, inventory, pricing and tasks. View on materials and logistics.
Sees prices and sales figures. **No finance capability.** A holder of this role can raise and
confirm an order and reserve stock against it, but cannot raise the invoice. Because the order
flow is invoice-before-shipment, that also means the role cannot ship. See 2.4.1.

### Human Resources — `hr` · defined, nobody holds it today

*"Employee records, payroll and training, including pay and identity data."*

Edit on HR and tasks. Sees pay, identity and review content. Nothing else.

### Read-only Auditor — `auditor` · defined, nobody holds it today

*"Sees every module and all costs, changes nothing; no bank details, no salaries."*

View on every module. Sees prices, sales figures and the deleted-records register. **Not one
edit capability**, and no `data.view_pay`, no `data.view_banking`, no `data.view_identity`, no
`data.view_reviews`.

Of the roles defined today, only this one, System Administrator and Commercial & People hold
`data.view_deleted`, so only they can open Settings → Deleted records.

## 4.6 Reading the table above

Two habits will save time.

**A module capability and a data capability answer different questions.** Holding
`module.purchasing.view` gets you onto the purchase order list. Whether the amounts on it are
figures or the word **Restricted** is decided separately, by `data.view_prices`. A role can see
every order and no money, and that arrangement is on purpose.

**Edit is not a superset of the process.** Raising a sales order needs `module.sales.edit`.
Invoicing it needs `module.finance.edit`. Shipping needs `module.sales.edit` again but cannot
happen until somebody with finance rights has invoiced. A process that crosses two modules needs
two people, or one person holding both.