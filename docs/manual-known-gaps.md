# Operations manual — known gaps, and what comes out when each is fixed

**Cut** MANUAL-2 · **Draft at time of writing** `0ea22fd` (docs/manual-draft.md, tree clean)
**No version number, no release note** — this cut takes neither.

This file is **for the repo. It is not part of the manual and never ships with it.**

## What it is for

Four passages of the manual are true today only because something is unfixed. Each of them
describes a defect accurately, which is the right thing for a manual to do while the defect
is there — and the wrong thing the moment it is gone. A manual that still warns about a fault
that has been repaired is worse than one that never mentioned it, because a reader who trusts
it will work around a problem that no longer exists.

So each row below names **one defect** and **the exact passage that comes out when it is
fixed**. Nothing here asks anyone to rewrite a paragraph. Every row is a deletion.

## How to use a row

Find the passage by its **section and its opening words**, not by line number. Line numbers
are recorded for convenience and go stale the first time anyone edits above them; the
opening words do not. Delete what the "Comes out" column says, rebuild the PDF, and strike
the row from this file.

---

## The rows

### 1 · Inbound CSV export writes the stage column in Chinese

**The defect.** Download the inbound batch list as CSV and the stage column holds the stored
value — `待加工` / `加工中` / `已加工完` — while the screen shows English. Screen and file
disagree on that one column. The **output batch export does not have this fault**, so the
fix has a working example inside the same module to copy.

**Manual passage.** Part 3, section 3.6 *Inventory*, under **Inbound batch**.
Paragraph headed **"A known fault in the exported file."** — line 1513 at `0ea22fd`.

**Comes out.** The whole paragraph, all five lines, ending "…does not have this fault."

**Note for whoever fixes it.** Those three Chinese words are the **only** CJK characters in
the entire manual. When this paragraph goes, the manual is pure Latin text, and the Noto
Sans SC fallback in the build stylesheet stops being load-bearing. Leave the fallback in
place regardless — it costs nothing and the next Chinese string will not announce itself.

### 2 · Ship confirmation dialog denies that credit notes exist

**The defect.** The ship confirmation dialog says corrections would go through a credit note
*"which does not exist yet"*. **Credit notes do exist.** Finance → Credit notes is the
register, and one is raised from the invoice.

**Manual passage.** Part 2, section 2.4.1 *The order flow*, **Step 7 — Ship**.
Final bullet, headed **"One line on the confirmation dialog is wrong."** — line 806 at `0ea22fd`.

**Comes out.** That bullet only — three lines. The bullet directly above it
(**"Undo: there is no undo."**) is unrelated and stays.

**Careful.** Do not also delete the credit-note route described a few paragraphs later under
**"Partially shipped is a dead end"**. That passage tells a reader how to correct a partially
shipped order and is true whether or not the dialog wording is repaired.

### 3 · Six delete dialogs promise a recovery that no screen performs

**The defect.** Six delete confirmation dialogs say **"(Soft delete: data is kept and
recoverable.)"** The first half is true — the record is kept and marked. The second half is
not something anyone can act on: **no screen in the system restores a deleted record.**

**Manual passage.** Part 1, section 1.5 *What "deleted" means here*.
Closing paragraph, beginning **"One wording to be aware of"** — line 176 at `0ea22fd`.

**Comes out.** The whole paragraph, three lines.

**What counts as fixed.** Either the dialogs stop claiming recoverability, **or** a screen
appears that actually restores a deleted record. Both close the gap; they close it in
opposite directions, and the second one would need more of section 1.5 rewritten than this
row covers. If the recovery screen is what ships, treat this row as a flag to re-read the
whole section rather than as a deletion.

### 4 · No screen links a purchase order or sales order to a contract

**The defect.** A contract can be recorded and read, and the register reports against it, but
**no page attaches a purchase order or a sales order to one.**

**This is not the /contracts menu fix, which is done** (MANUAL-FIX-2, `cf3a896` — the
contract register has a menu entry now). That was a missing door to a page that existed.
This is a page that does not exist.

**Manual passage.** Part 3, section 3.1 *Purchasing*, under **The contract**.
Paragraph headed **"There is also no screen yet for linking an order to a contract."** —
line 1087 at `0ea22fd`.

**Comes out.** The whole paragraph, three lines — when the linking screen ships.

**Careful.** The paragraph immediately below (**"Undo: there is none."**) is about contracts
being uncorrectable once recorded. Different defect, not covered by this row, stays.

---

## What this file does not cover

Only defects **the manual currently describes**. A defect the manual is silent about does not
belong here — there is no passage to withdraw, so there is nothing for this file to say. Those
belong in `docs/forward-queue.md` with everything else outstanding.

Nor does it cover passages that would merely become *stale* — a page renamed, a menu moved.
Those are found by rereading, not by a list. Every row here is a passage that becomes **false**
on a specific, nameable fix, which is why each one can be written down in advance.
