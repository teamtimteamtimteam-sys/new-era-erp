# AP-RECON-0 · Why the open-payables list and the payables ledger disagree — survey only (2026-09-24)

No code change, no migration, no gate, no build, no smoke. Every read below is a `SELECT`, either through the
Management API as `postgres` (`rolbypassrls = t`) or in the same call after `SET LOCAL ROLE authenticated` with
tim@'s claims (`634c00f9-…`, `tim@evoltrya.test`, role `cfo`). No read wrote anything.

## §R · The reconciliation — every cent of the gap, per document

**The gap is 40,563.20, and the explained differences add up to exactly 40,563.20. Nothing is unexplained.**

Sign convention: "ledger" is the payable that account 2000 holds for the document, meaning credits minus debits. Revaluation is spread across the USD lines it revalued (see class D).
"Δ" = view − ledger.

| # | document | counterparty | view `open_base` | ledger (2000) | Δ | class |
|---|---|---|---:|---:|---:|---|
| 1 | IN-2026-0003 | Shanghai Yidong | 30,000.00 | 0.00 | **+30,000.00** | A · priced before payable posting began (new) |
| 2 | IN-2026-0001 | Shanghai Yidong | 7,104.00 | 0.00 | **+7,104.00** | A · priced before payable posting began (new) |
| 3 | IN-2026-0012 | Acme | 10,000.00 | 0.00 | **+10,000.00** | A · priced before payable posting began (known) |
| 4 | IN-2026-0011 | Acme | 2,100.00 | 0.00 | **+2,100.00** | A · priced before payable posting began (known) |
| 5 | IN-2026-0154 (soft-deleted) | Shanghai Yidong | — (not in the view) | 4,032.00 | **−4,032.00** | B · a deleted receipt: the view drops it, the ledger keeps it |
| 6 | IN-2026-0029 | Acme | 18,000.00 | 22,590.00 | **−4,590.00** | D · USD revaluation, ledger only (48,000 − 30,000 prepaid, at 1 → 1.255) |
| 7 | EXP-2026-0001 | Acme | 0.96 | −0.94 | **+1.90** | E · FIN-2 backfill units (0.96) + the revaluation of its USD payment line (0.94) |
| 8 | EXP-2026-0007 | Choo Er Teh (employee) | 100.00 | 109.00 | **−9.00** | C · GST leg on 2000, not in the view |
| 9 | EXP-2026-0008 | Choo Er Teh (employee) | 30.00 | 32.70 | **−2.70** | C · GST leg (BL) on 2000, not in the view |
| 10 | EXP-2026-0009 | Ever Higher | 100.00 | 109.00 | **−9.00** | C · GST leg on 2000, not in the view |
| — | IN-2026-0152, 0156, 0181, ZZ-PROCCOST1-DEMO | Acme / Shanghai Yidong / ZZ1B | 69,531.92 | 69,531.92 | 0.00 | agree |
| — | EXP-2026-0003, 0004, 0006 | Acme / Bosch Rexroth | 280,000.74 | 280,000.74 | 0.00 | agree |
| — | freight (4 docs, 8 JEs), PMT-2026-0005 (2 JEs) | forwarder / — | 0.00 | 0.00 | 0.00 | agree (every pair nets to 0) |
| | **total** | | **416,967.62** | **376,404.42** | **40,563.20** | |

Row 6 and row 7 split the two revaluation entries. JE-2026-0024 credits 61,121.54 and JE-2026-0070 debits 56,532.48, a net credit of 4,589.06. The split:
- 18,000 × 0.255 = 4,590.00 is IN-2026-0029's share;
- 3.70 × 0.255 = 0.9435 is EXP-2026-0001's USD payment line, rounded to −0.94;
- 4,590.00 − 0.94 = 4,589.06, the net of the two entries to the cent.

### Per supplier

| counterparty | view | ledger | Δ |
|---|---:|---:|---:|
| Shanghai Yidong Battery Recycle Co. | 39,173.12 | 6,101.12 | +33,072.00 |
| Acme Battery Recycling Pte Ltd | 97,064.50 | 89,552.60 | +7,511.90 |
| Bosch Rexroth Pte. Ltd. | 280,000.00 | 280,000.00 | 0.00 |
| ZZ1B Goods Ltd | 500.00 | 500.00 | 0.00 |
| Ever Higher Pte Ltd | 100.00 | 109.00 | −9.00 |
| Choo Er Teh (employee) | 130.00 | 141.70 | −11.70 |
| **total** | **416,967.62** | **376,404.42** | **+40,563.20** |

### By class

| class | amount | what it is | verdict |
|---|---:|---|---|
| A | +49,204.00 | 4 receipts in the view that the ledger never posted | **(a) test-data residue**: 2 already known, **2 not recorded anywhere** |
| B | −4,032.00 | 1 soft-deleted receipt the ledger still owes | **(b) a view defect, and a gap in the delete path.** Test data today, but the path is live |
| C | −20.70 | GST legs on 2000 that the view and the payment cap cannot see | **(b)+(c) a live defect** in the view and the payment path. It recurs on every taxed unpaid expense |
| D | −4,590.00 | revaluation of the pre-FIN-0 USD payable on IN-2026-0029 | **(a) residue** of the FIN-0 base-currency switch |
| E | +1.90 | EXP-2026-0001: FIN-2's backfill put base units in `allocated_ccy`, plus the revaluation of its USD payment | **(a) residue** of FIN-0 / FIN-2 |
| | **+40,563.20** | | |

---

## §1 · Step 1 — both sides re-measured

### The two reads

| read | identity | table or view | time (CST) | result |
|---|---|---|---|---|
| `SELECT count(*), sum(open_base) … FROM ap_open_items` | **tim@**: `authenticated` with sub `634c00f9-…`; `has_permission('module.finance.view') = true` | **view** `ap_open_items` | 2026-09-24 08:13:41 | **16 rows, 416,967.62** (inbound 136,735.92 · expense 280,231.70 · freight 0 rows) |
| `SELECT sum(debit − credit) … FROM journal_lines JOIN accounts WHERE code = '2000'` | **postgres**, `rolbypassrls = t` | **base tables** `journal_lines` / `journal_entries` / `accounts` | 2026-09-24 08:13:42 | **35 lines, debit 486,931.96, credit 863,336.38, balance −376,404.42** |

The same read through `ap_aging_asof(current_date)` as tim@ (08:16:46) also gives **416,967.62**. That function feeds `/finance/payables`.

**The briefed view figure (416,837.62) does not reproduce.** Today's figure is 130.00 higher, and 130.00 is exactly
EXP-2026-0007 + EXP-2026-0008, the two employee claims (dated 09-11 and 09-12, so they existed when the brief was taken).
416,837.62 is therefore the supplier-only total. I cannot tell from here which reader produced it. The briefed 2000 balance
(−376,404.42) reproduces exactly, and the gap is **40,563.20**, not ~40,433.20.

### What the view counts as "open" (`pg_get_viewdef('ap_open_items')`, read live)

Three branches in a `UNION ALL`, filtered by `open_ccy > 0 AND has_permission('module.finance.view')`:

| branch | source | included when | amount | currency | subtracts |
|---|---|---|---|---|---|
| inbound | `inbound_batches_masked` | `deleted_at IS NULL AND unit_price IS NOT NULL` | `round(quantity × unit_price, 2)`, always **base** | the base currency, whatever the PO was in | posted `payment_allocations.allocated_ccy` + `prepayment_applications.amount_base` |
| expense | `expenses` (supplier **or** employee) | `payment_status = 'unpaid' AND status = 'posted'`, and no other expense names it in `reversed_by_expense` | `amount_ccy`, the **net amount, excluding GST** (`record_expense` says so: "p_amount 始终是不含税净额") | the expense's own; `open_base = open_ccy × fx_rate` | posted allocations (`allocated_ccy`) + prepayment applications (`amount_ccy`) |
| freight | `freight_documents` | `payment_status = 'unpaid' AND status = 'posted' AND deleted_at IS NULL` | `amount_ccy` | own; × `fx_rate` | posted allocations only (no prepayment arm) |

What it does **not** include: POs (a prepayment is an asset, not a payable), revaluation, and any 2000 line whose source document is deleted or has no document.
- **Reversals:** a reversed payment drops out because the join requires `p.status = 'posted'`. A reversed expense drops out through `reversed_by_expense`. A reversed freight document leaves `posted` status.
- **Overpayments:** `open_ccy > 0` hides a document that has been paid past its amount, rather than showing it as negative.

### What posts to account 2000 (postgres, base tables, grouped by `journal_entries.source_type`, `status`)

| source_type | entry status | entries | debit | credit | net (dr − cr) |
|---|---|---:|---:|---:|---:|
| purchase | posted | 8 | 25,600.00 | 368,859.92 | −343,259.92 |
| purchase | reversed | 2 | 247,296.00 | 25,600.00 | +221,696.00 |
| expense | posted | 7 | 0 | 400,255.14 | −400,255.14 |
| prepayment | posted | 2 | 150,000.00 | 0 | +150,000.00 |
| payment | posted | 2 | 3.70 | 899.10 | −895.40 |
| payment | reversed | 1 | 899.10 | 0 | +899.10 |
| freight | posted | 4 | 6,600.68 | 0 | +6,600.68 |
| freight | reversed | 4 | 0 | 6,600.68 | −6,600.68 |
| revaluation | posted | 2 | 56,532.48 | 61,121.54 | −4,589.06 |
| **total** | | | **486,931.96** | **863,336.38** | **−376,404.42** |

"reversed" is the status of an **original** entry whose reversal also exists. The reversal is its own `posted` row, so each
pair appears on two lines above and nets to zero. Only two supplier payments have ever touched 2000:
- **PMT-2026-0001** (3.70);
- **PMT-2026-0005**, reversed.

Everything else was settled by prepayment applications: JE-2026-0016 for 30,000 and JE-2026-0065 for 120,000.

---

## §2 · Step 2 — each class, with its evidence

### A · Receipts the view counts but the ledger never posted — +49,204.00 · (a) residue

Supplier payables started posting on 2026-07-06 10:02 (cut 2a). The first `purchase` entry is JE-2026-0001.

- **IN-2026-0011 (2,100.00) and IN-2026-0012 (10,000.00)** are the two in-view entries among the four legacy receipts in
  `docs/known-wrong-until-cutover.md`. The other two, IN-2026-0013 and IN-2026-0002, are soft-deleted, so they are in neither the view nor the ledger.
- **IN-2026-0001 (7,104.00) and IN-2026-0003 (30,000.00) are the same kind but are not in that file.** They were missed
  because each **has** `purchase` entries, so a scan for receipts with no purchase entry passes over them. Read from `price_history`:
  - **IN-2026-0003:** first priced 07-05 23:37:56 at 88 (before cut 2a, never posted). Repriced 07-06 10:02:23 to 600. Cut 2a posted
    only the **delta**, (600 − 88) × 50 = 25,600 (JE-2026-0001), and that delta was reversed at 10:03:29 (JE-2026-0002). Net on
    2000: 0. The batch is worth 30,000.00.
  - **IN-2026-0001:** first priced 07-05 23:38:25 at 53 (never posted). Repriced 07-06 10:08:29 to 1.48 (SGD 2 × 0.74). The delta,
    (1.48 − 53) × 4,800 = −247,296, was posted as a **debit** to 2000 (JE-2026-0003) and reversed at 10:09:26 (JE-2026-0004).
    Net on 2000: 0. The batch is worth 7,104.00.
  - Both pairs were posted and reversed within a minute, by `admin@`, on cut 2a's first morning. They read as the cut's
    own acceptance walk. **The original price was never on the ledger, so neither was the batch.**
- Why this disappears at cutover: production is rebuilt with posting live from day one. This class needs a price that
  pre-dates payable posting.

### B · A deleted receipt: the view drops it, the ledger keeps it — −4,032.00 · (b) a view defect and a gap in the delete path

- **IN-2026-0154** was priced 08-06 00:05 at 10.08 (USD 8 × 1.26). JE-2026-0036 credits 2000 4,032.00.
- It was soft-deleted at 00:49:25 with `delete_reason = NULL` (before reasons were required). The delete posted **JE-2026-0038:
  debit 5200, credit 1200, 4,032.00**. It wrote off the stock and **left the payable alone**.
- `soft_delete_inbound_batch` (repo mirror, read) does nothing to 2000.
- The view excludes the batch (`ib.deleted_at IS NULL`), and so does `record_payment_internal`. Its batch branch reads
  `WHERE ib.id = v_batch_id AND ib.deleted_at IS NULL`, else `ALLOC_INVALID`.
- **So 4,032.00 of payable sits on 2000 with no document that can be seen or paid.** The only way to clear it is a manual journal.
- The document itself is test data. **The path is live:** any priced receipt deleted today does the same thing. Whether the
  payable should survive the delete is a business question (Q2).

### C · The GST leg on 2000 that the view cannot see — −20.70 · (b)+(c) a live defect

- `record_expense` credits 2000 **twice** when unpaid: `amount_ccy` (net) and a separate `'GST on EXP-…'` leg for the tax. It says
  the supplier "收的是净额 + 税" (is owed the net plus the tax).
  - JE-2026-0076: 100.00 + 9.00.
  - JE-2026-0077: 30.00 + 2.70 (BL, blocked input tax: the payable is still gross).
  - JE-2026-0078: 100.00 + 9.00.
- The view uses `e.amount_ccy` (net) as the document amount. **`record_payment_internal` does the same.** Its expense branch sets
  `doc_value = e.amount_ccy`, and the `ALLOC_EXCEEDS` check refuses any allocation above `amount_ccy − settled`.
- **Consequence on live code:** a taxed bill can only ever be settled to its net amount. Pay the supplier the 109 they invoiced,
  and 9 either fails `ALLOC_EXCEEDS` or goes in unallocated. After the net is settled, the expense leaves every open list, and the 9 stays on 2000 for good.
- This is not test residue. GST-2 is live and every new taxed unpaid expense adds its tax to this class.
- The two affected employee claims (EXP-2026-0007/0008) come through the same `record_expense`, so the claim-reimbursement path has the same shortfall.
- Receipts have no GST leg. The pricing path posts net only, and no function that posts `purchase` entries references GST.

### D · Revaluation of a pre-FIN-0 USD payable — −4,590.00 · (a) residue

- The USD-labelled lines on 2000 net to a **credit of USD 17,996.30**: JE-2026-0015 credits 48,000 (IN-2026-0029 at `fx 1`),
  JE-2026-0016 debits 30,000 (prepayment), and JE-2026-0010 debits 3.70. The other USD lines are reversal pairs that net to 0.
- Revaluing 17,996.30 from 1 to 1.255 gives 4,589.0565. The two revaluation entries net to **4,589.06**, matching to the cent.
- The view prices every receipt in base (`currency` = base, `v_doc_fx := 1` in the payment path, "FIN-0 起批次价值即本位币"). So IN-2026-0029 shows
  SGD 18,000, while the ledger holds USD 18,000 = SGD 22,590.
- This is the same fact as `known-wrong-until-cutover.md`'s first row and its PO-2026-0001 row: pre-FIN-0 USD documents at 1:1, deliberately not restated. IN-2026-0029 is received against PO-2026-0001.
- After FIN-0 no receipt carries a foreign currency, so no new receipt can join this class.

### E · EXP-2026-0001's 0.96 — +1.90 · (a) residue

- EXP-2026-0001 is **SGD 5 at 0.74 = 3.70 base**, created 07-30, when the base was still USD.
- PMT-2026-0001 paid **USD 3.70** and allocated 3.70 to it (`allocated_base = 3.70`).
- FIN-2 (2026-08-04) added `allocated_ccy` and backfilled it with **`UPDATE … SET allocated_ccy = allocated_base`**
  (`db/migrations/2026-08-04-fin2-settle-in-document-currency.sql:16`). The allocation therefore reads 3.70 **SGD** against an
  SGD 5 document.
- The view computes (5 − 3.70) = 1.30 SGD open, × 0.74 = **0.96**. The ledger's credit and debit are 3.70 each, so it is fully settled.
  `payment_status` was never flipped from `unpaid`, which is why the view still picks it up at all.
- The remaining 0.94 is this payment line's share of the revaluation (class D).
- This is the family of `known-wrong-until-cutover.md`'s second row (1100: "FIN-2 之前的结算在本位币空间跑"). New allocations are written in the document's currency, so no new document can join this class.

### Things read on the way that do not move the gap

- **Three freight entries are dated in 2027.** JE-2027-0001/0002/0003, "export freight payable", have `entry_date = 2027-09-05` and are
  reversed by JE-2026-0058/0059/0060, dated 2026-08-20. Each pair nets to 0 on 2000, so they do not affect this reconciliation. A
  reversal dated a year **before** its original, and a JE-2027 number series, would still show up in any as-of-date report
  spanning 2026-08-20 to 2027-09-05. I did not investigate further (read-only survey, out of scope). Q6 asks whether to.
- `ap_open_items` hides overpaid documents (`open_ccy > 0`). None exist on live today: every allocation is at or below its document.

---

## §3 · Fix proposal — one cut

**AP-RECON-1: the open lists and the payment cap settle what the ledger posted.** It depends on Q1 and Q2.

1. The expense branch of `ap_open_items` and `ap_aging_asof`, and the expense branch of `record_payment_internal`
   (`doc_value`, `ALLOC_EXCEEDS`), all use **net + tax**: `amount_ccy + (tax_base / fx_rate)`, or better, a stored `tax_ccy`
   column if Q1 wants one. The expense detail page's "still owed" follows from the view. The switch that marks an expense `paid` must move to the same total.
2. Deleting a receipt that is priced and still owes money is **refused with a named error**
   (`INBOUND_HAS_OPEN_PAYABLE|<code>|<open>`). Stock losses go through the write-off path, which keeps the document (Q2).
3. A rolled-back fixture pins both: a taxed expense settles to zero on 2000 through one allocation of the gross amount, and a priced unpaid receipt cannot be deleted.
4. Class A, D and E residue is **not touched** (Q3, Q4).

**Estimate, two numbers:**
- **Process floor: 39 min.** Measured on PAY-REQ-1 Batch A, from `apply_migration.sh` start (22:15:37) to push (22:54:27). That covers backup,
  migration, gate (183–650 s measured), build, smoke and commit.
- **Work: 2–3 h.** An estimate, not a measurement. It covers three function or view bodies, one new refusal, their mirrors, one fixture and the page copy.
  Most of it is re-reading `record_payment_internal` (817 lines) around the WHT and FX arms that also compute from `doc_value`.

### The receivables side: yes, the same mismatch exists

Quick read-only check:
- `ar_open_items` read as **tim@** through the **view** at 08:16:46: **9 rows, 57,443.00**.
- Account **1100** read as **postgres** from base tables at 08:16:38: **+43,002.12** (20 lines).
- **Gap: 14,440.88, not reconciled here.**

Two visible leads:
- `known-wrong-until-cutover.md`'s second row already records a pre-FIN-2 USD mismatch on 1100.
- OUT-2026-0007 shows `open_ccy` 27,500 SGD but `open_base` 20,350. That is an SGD document still carrying a pre-FIN-0 0.74 rate, the same shape as class E.

Whether any live defect sits in the AR path, such as output-tax legs on 1100 that the view does not see, has not been checked. That is Q5.

---

## §0 · Fold-in

### PAY-REQ-1 Batch B's broken window — closed with bounds, labelled by kind

| | time (CST) | kind |
|---|---|---|
| start | 2026-09-24 00:07:06 | `db/apply_migration.sh`'s own line (`db/migration-windows.tsv`) |
| end, lower bound | 00:40:42 | the push (`origin/main` reflog: `be4aff86 … 2026-09-24 00:40:42 +0800: update by push`). No deploy can come before it |
| end, upper bound | 08:13:41 | the first clock reading of this session, taken after Tim's "deployed" relay. **A relayed confirmation, not a measurement of Vercel** |

**Window: at least 33m36s, at most 8h06m35s.** The upper bound is loose because the relay came the next morning. Vercel's deploy time would close it.

### admin@ holds every code again (recorded in `docs/role-matrix.md` and `docs/handbacks/ROLE-1.md`)

- At **2026-09-23 23:33:27 CST**, Tim, signed in as admin@, restored all **45** codes to the `admin` role. This reverses ROLE-1 Q8.
- Re-read at 08:17:14 as `postgres` from base table `role_permissions`: **45 rows**, `min(created_at) = max(created_at) =
  2026-09-23 23:33:27.309521+08`.
- Claude recommended going back to system administration only, for two reasons:
  - admin@ and tim@ are one person, so a request raised on admin@ cannot then be approved on tim@;
  - a compromised admin password now carries every power.
- **Tim has not ruled on reverting. The role stays as it is, and it is not raised again unless Tim raises it.**

### Step 0 (grilling)

The block asks for grilling first and then the survey. The decisions it surfaced are all ones this survey can take as recommended without closing anything off, so they were taken as recommended and are listed here for Tim to overturn:
- **G1**: count every view row, **including employee claims**, because 2000 carries them.
- **G2**: reconcile the state **now**, not as of a past date.
- **G3**: spread revaluation across the documents it revalued rather than leaving it as one unexplained line.
- **G4**: IN-2026-0154 counts on the ledger side even though it is deleted.

One fact grilling found the hard way: **the sub `321f1819-…` is `admin@swm-os.test`, not tim@**. My own working notes had it labelled
as "Tim's". The view read above was re-run as tim@ (`634c00f9-…`). Neither admin@'s role set (admin + cfo) nor tim@'s (cfo) changes the
view total today, because both hold `module.finance.view`.

---

## Questions for Tim

**Q1 · Should a taxed bill's payable be its gross amount (net + GST) in the open lists and in the payment cap?**
➡️ **Yes.** The ledger already posts gross to 2000 (JE-2026-0076/0077/0078) and the supplier invoices gross. Today the 9.00 on each
bill cannot be allocated (`ALLOC_EXCEEDS`) and stays on 2000 once the net is paid. This is the one live defect in the gap
(class C, −20.70 today, growing with every taxed unpaid expense).

**Q2 · When someone deletes a receipt that is priced and still unpaid, what happens to the payable?**
➡️ **Refuse the delete by name while it owes money.** A physical loss is written off without deleting the document, so the supplier debt stays visible and payable.
Evidence: IN-2026-0154's 4,032.00 is on 2000 but in no list and cannot be paid (`ALLOC_INVALID`). The only way out is a manual journal.
Alternative: keep deleted-but-priced receipts in the view and in the payment path. I don't recommend it, because a deleted document you can still pay reads as a contradiction.

**Q3 · IN-2026-0001 and IN-2026-0003 (37,104.00): add them to `known-wrong-until-cutover.md` and leave them alone, as with IN-2026-0011/0012?**
➡️ **Yes, same disposition as INB-PAY-1 Q4: no catch-up posting.** Repricing cannot fix them because the posted delta was reversed and the base price was never
posted. A catch-up journal would invent an entry dated today for a July receipt. The line goes in with the next cut, because this block may only touch its listed doc lines.

**Q4 · Classes D and E (−4,590.00 and +1.90): leave them as FIN-0 / FIN-2 residue?**
➡️ **Yes.** They are the same fact as two rows already in `known-wrong-until-cutover.md` (pre-FIN-0 USD at 1:1, and pre-FIN-2 settlement in base units). Name the two amounts in those rows in the next cut so nobody measures them again.

**Q5 · Open AR-RECON-0: the same survey for `ar_open_items` (57,443.00) against 1100 (43,002.12), a gap of 14,440.88?**
➡️ **Yes, before AP-RECON-1 is built,** so that if the receivables side has the output-tax twin of class C, one cut fixes both views and both payment paths.
Evidence: the gap exists and is roughly a third the size of the AP gap. At least one row has the class-E shape.

**Q6 · Look at the three freight entries dated 2027-09-05 (JE-2027-0001…0003) whose reversals are dated 2026-08-20?**
➡️ **Yes, as a line in AR-RECON-0 or a separate small survey.** They do not move this gap, but an as-of report between those
dates sees only one side of each pair, and a 2027 number series on a 2026 ledger needs an explanation.

**Q7 · Should AP-RECON-1 add a standing check: view total + named residue = −(2000 balance)?**
➡️ **Yes, as a fixture arm on rebuilt data, where the residue is zero and the check becomes strict equality.** The gap stayed invisible until a
grilling happened to compare the two numbers. A check that failed on the first stranded GST leg would have caught class C the day GST-2 shipped.
