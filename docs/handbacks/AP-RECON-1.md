# AP-RECON-1 — the lists carry what the ledger posted, and a difference has a name (2026-09-24)

- **Batch A** fixes four live defects that kept pulling the open-items lists away from their ledger accounts. The date
  rules (Q7) were moved out of Batch A on Tim's ruling, mid-build (§A5).
- **Batch B** (§B, below) adds the residue register, the standing list-vs-ledger check, the month-end row and the
  strict-equality fixture. It also carries the date rules, back in AP-RECON-1 on Tim's ruling of 2026-09-24, with the
  32 fixtures moved onto real dates.

Identities used throughout:
- **tim@**: `SET LOCAL ROLE authenticated` with sub `634c00f9-…` (`tim@evoltrya.test`, role `cfo`), reading **views**.
- **postgres**: `rolbypassrls = t`, reading **base tables**, through the Management API.

`321f1819-…` is **admin@**, not tim@. AP-RECON-0 first read the view under that sub, and it was re-read as tim@ before any
figure was used.

---

## §0 · Decisions on record

### Tim's answers to AP-RECON-0 (closed; not re-asked)

1. **Taxed bills settle at net + GST.** `ap_open_items`, the payment cap and every reader of the open amount use the full
   amount posted to 2000. → **§A1, shipped.**
2. **Deleting a priced receipt that still owes money is refused by name.** IN-2026-0154, the one live instance, is test data:
   recorded, not repaired. → **§A4, shipped;** row in `docs/known-wrong-until-cutover.md`.
3. **IN-2026-0001 and IN-2026-0003 go into `docs/known-wrong-until-cutover.md`** beside IN-2026-0011/0012. → **done.**
4. **The IN-2026-0029 revaluation and the EXP-2026-0001 residue are left alone and recorded.** → **done** (two rows).
5. **Receivables are reconciled in this cut** (not in a separate survey), to the cent and classified. Live defects of the same
   class are fixed; residue is recorded. → **§1 (reconciliation), §A3 (the fix), residue rows done.**
6. **The 2027 freight: find out why in this cut.** Fix it if it is a code defect; record it if it is data. → **§2.** It is both. The data is recorded; the code half moved to AP-RECON-1c (§A5).
7. **A standing list-vs-ledger check** on the month-end page plus a fixture that fails the gate when a posting path diverges,
   with known residue listed as explained differences. → **Batch B (§B).**

### Tim's answers to AP-RECON-1 grilling (all eleven accepted as recommended)

| Q | ruling | where it landed |
|---|---|---|
| Q1 | two batches: A = the five defects, B = register + check + month-end row + fixture; stop after A | this document |
| Q2 | refuse, by name, an expense carrying both WHT and GST | §A1 — `EXPENSE_WHT_WITH_GST` |
| Q3 | record that a claim's GST is added on top instead of backed out (EXP-0007/0008 over-posted 11.70); fix it as its own cut **immediately after AP-RECON-1**, at the head of the queue | `docs/known-issues.md` § APRECON1-CLAIM-GST-ADDED-ON-TOP; `docs/forward-queue.md` item 2 |
| Q4 | the prepayment-cap fix goes in Batch A | §A2 |
| Q5 | a sale invoice's GST is its own open item in base currency, capped at its GST; the sale row stays in its own currency | §A3 |
| Q6 | supplier payments on account are a computed, named line in the check | Batch B |
| Q7 | business documents refuse a date after today; `assert_posting_allowed` refuses entries after the end of the current month; a reversal may not predate its original; freight form `max` = today | **moved to AP-RECON-1c by Tim, 2026-09-24** — §A5 |
| Q8 | keep `gl_control_reconciliation`'s signature and keys; correct its header; add the new check as its own function; queue re-basing the pack's version | Batch B; queue item 4 |
| Q9 | the migration-only residue table, 12 per-document rows, each with a required reason and a known-wrong reference | Batch B |
| Q10 | revaluation is a computed, named line with its own amount shown | Batch B |
| Q11 | the month-end row shows the unexplained amount per side and links to the reconciliation; it does **not** block `close_period` in this cut. **Blocking the close is a later decision.** | Batch B |

---

## §1 · The receivables reconciliation, to the cent (grilling item a)

**Reads:**
- `ar_open_items`: **view**, as tim@, 2026-09-24 08:24:25 CST → **9 rows, 57,443.00**.
- Account 1100: **base tables**, as postgres, 08:16:38 → **43,002.12** (20 lines).
- **Gap: 14,440.88. Explained: 14,440.88. Unexplained: 0.00.**

| document | list | 1100 | Δ (list − ledger) | class | verdict |
|---|---:|---:|---:|---|---|
| OUT-2026-0007 (SGD 27,500 at 0.74, sold 07-05 23:34) | 20,350.00 | 0.00 | +20,350.00 | sold before sales posting began (07-06); no JE at all | **(a) residue**, already `known-wrong` row 13 |
| OUT-2026-0001 (USD 24,000 at `fx 1`, 07-31) | 24,000.00 | 30,120.00 | −6,120.00 | pre-FIN-0 USD revalued at 1.255 | **(a) residue**, new row |
| RCPT-2026-0001 (USD 250, never allocated) | — | −313.75 | +313.75 | on-account receipt: 250 + its 63.75 revaluation | **(a) residue**, new row; now refused while GST-registered (`GST_UNALLOCATED_RECEIPT_UNSUPPORTED`) |
| OUT-2026-0185 (SGD 1,143) + INV-2026-0009 output tax | 1,143.00 | 1,245.87 | −102.87 | `create_invoice` debits 1100 with the tax (base currency); list and receipt cap see only qty × price, and the invoice itself refused allocations | **(b)+(c) live defect → fixed §A3** |
| OUT-0119, OUT-0120, OUT-0185 (USD), OUT-0186 ×2, INV-0007; INV-0006 and INV-0008 void pairs | 12,950.00 | 12,950.00 | 0.00 | agree | — |
| **total** | **57,443.00** | **43,002.12** | **14,440.88** | | |

The revaluation checks out to the cent. The revaluation lines on 1100 net to 6,770.25 − 714.00 = **6,056.25**, which is
6,120.00 − 63.75.

---

## §2 · The 2027 freight (grilling item c): data entered on purpose, accepted by a code gap

- **What:** FRT-2027-0001…0003, outbound, SGD 1,234.56 each, `doc_date` 2027-09-05, with JE-2027-0001…0003 on the same date.
- **Who and when:** created 2026-08-20 10:52–10:56 by three throwaway logins that no longer exist in `auth.users`. Each was
  reversed about 19 s later (`LOG-4b 验证:冲掉这张 scratch 单`). Their containers CTR-2027-0001/3/5 depart 2027-09-01.
- **Provenance:** commit `be8db062` "LOG-4b:出口运费的界面" describes exactly this end-to-end walk.
- **Not a script and not an off-by-one-year bug:** no script or fixture in the repo contains `2027-09-05` or `ZZLOG4B`.
- **The code gap:**
  - `record_export_freight_document` posts on `p_doc_date` and checks only `IS NULL`.
  - `post_journal_entry` takes the JE number's year from the entry date.
  - `assert_posting_allowed` has only lower bounds: year closed, `locked_before`.
  - `reverse_freight_document` reverses on `CURRENT_DATE` without comparing it to the original, so each reversal is dated a
    year before its original.
- **Other future-dated rows on live:** exactly these three JEs and three freight documents. Other future dates on live are
  forward-looking by nature (quote validity, holidays, due dates).
- **Consequence:** every pair nets to 0 across all time. `gl_control_reconciliation(today)` sees only the reversal legs and
  under-counts 2000 by **3,703.68**.
- **Disposition:** the data is recorded (`known-wrong-until-cutover.md`; also `known-issues.md:2254`). The code half is AP-RECON-1c (§A5).

## §3 · The existing check hides the defects (grilling finding)

`gl_control_reconciliation` (GLEXPORT-1, shown on /finance) reports **`reconciled = true`** on both sides today. It
classifies by mechanism (origination / settlement / revaluation), not by known residue.

Read as tim@ at 08:24:25, its AP origination variance is 48,854.98. That is exactly:
- 49,204.00 of pre-cut-2a receipts;
- −4,032.00 for the deleted-but-owing IN-0154;
- −20.70 for the GST defect;
- +3,703.68 for the 2027 freight originals cut off by its as-of date.

Its 2026-08-28 header says the difference is "逐分钱解释干净" (explained to the cent). → Batch B (`known-issues.md` § APRECON1-GL-CONTROL-RECON-HIDES-DEFECTS).

---

## §A · What Batch A changed

Migration `db/migrations/2026-09-24-aprecon1a-the-list-carries-what-the-ledger-posted.sql`: one new function and 13
replaced views and functions, every one copied verbatim from its mirror. It has no DDL on tables, adds no journal entries,
and changes no column sets.

### A1 · A taxed expense owes net + GST (AP-RECON-0 Q1; AP-RECON-1 Q2)

- **New `expense_payable_ccy(amount_ccy, tax_rate_pct)`** = `amount + tax_amount_for(amount, rate)`. It is the same expression
  `record_expense` posts with, so it is not a second implementation. `tax_base / fx_rate` would be lossy, which is why it
  isn't used. Rows with no tax rate give net, unchanged.
- **Readers moved to it:**
  - `ap_open_items` and `ap_aging_asof` (expense branch): `doc_value_base = amount_base + tax_base`. While nothing is
    settled, `open_base` is that stored sum. `round((net + tax) × fx)` can differ by one cent from the two posted legs;
    fixture 212 A2 pins this.
  - `record_payment_internal` expense cap.
  - `apply_prepayment` expense cap.
  - `expense_claim_status` (`is_paid` / `is_owing`) and `medical_claim_status` (`paid`).
  - The expense detail page, which now reads `ap_open_items` instead of its own `amount_base − allocations` (a second
    implementation that ignored GST and prepayments).
- **Follow automatically:** the payment form pre-fill, the payables page and export, reminders, forwarders, cash forecast,
  management pack.
- **Untouched on purpose:** F5, which reads only the ledger.
- **`EXPENSE_WHT_WITH_GST` (Q2):**
  - What it guards: withholding is computed on the allocated amount, so a gross allocation would withhold on the GST. Σ WHT
    would then exceed the frozen `wht_amount_ccy`, breaking fixture 142 D.
  - When it fires: only when WHT really applies (rate > 0) **and** there really is tax.
  - Live exposure: 0 such expenses.
  - Copy: en and zh, in the expense and WHT mappers.

### A2 · The expense payment cap subtracts prepayment applications (Q4)

- **The gap:** the expense branch of `record_payment_internal` summed posted allocations only. `ap_open_items`,
  `apply_prepayment` and the batch branch already added `prepayment_applications`.
- **On live:** EXP-2026-0006 (400,000, 120,000 prepaid) accepted up to 400,000 and now accepts up to 280,000.

### A3 · A sale invoice's output tax is its own receivable (Q5)

- **`ar_open_items` / `ar_aging_asof`:** a third branch, `doc_kind = 'invoice_gst'`: base currency, amount = `invoices.tax_base`,
  settled by allocations to `invoice_id`. It carries the same gates as the order-invoice branch, and the same void and
  as-at rules.
- **`record_payment_internal`:**
  - The invoice branch now also accepts a `kind = 'sale'` invoice **with tax > 0**, as its tax only: `doc_value = tax_base`,
    base currency, rate 1.
  - Untaxed sale invoices are still `ALLOC_INVALID`.
  - The sale's net is still collected only on the sales record, so it gets no second entry point.
- **Readers moved to it:**
  - `customer_ar_exposure_base`: third term.
  - `customer_statement_data`: charges include sale-invoice tax; applied amounts on a sale invoice use rate 1, because its
    `fx_rate` is NULL and multiplying by it silently drops the receipt.
  - `void_invoice`: a sale invoice with live settlements is refused (`INVOICE_HAS_SETTLEMENTS`), the same rule as order invoices.
- **App:**
  - payments/new maps `invoice_gst` rows to their invoice.
  - The receivables page links them to the invoice and labels them.
  - `finance.docKind.invoice_gst` is `Invoice GST` / `发票销项税`. check-i18n derives the key from the view mirror.
- **Already correct:** `invoice_status` counts allocations to `invoice_id` against `total_base`, which includes tax, so it
  needed no change.

### A4 · A priced receipt that still owes money cannot be deleted (AP-RECON-0 Q2)

- **Refusal:** `soft_delete_inbound_batch` refuses `INBOUND_HAS_OPEN_PAYABLE|<code>|<open>` when
  `qty × price − posted allocations − prepayment applications > 0`.
- **Why it reads base tables:** the gate is `module.inbound.edit`, and `ap_open_items` returns 0 rows without
  `module.finance.view`. So a warehouse reader's "owes 0" would be false.
- **Unpriced batches** still delete.
- **Copy** in `deletion.errors`.

### A5 · The date rules: written, then moved out (Tim's ruling mid-build, 2026-09-24)

- **What was written:** all three Q7 rules, their error codes, en/zh copy in 12 mappers, `max` = today on the freight form,
  and fixture 212 arm F.
- **What the gate said:** `db/gate.py --offline` then failed **32 of 215** fixtures that deliberately post into 2027–2030:
  - 11 on `DOCUMENT_DATE_IN_FUTURE`;
  - 21 on `POSTING_DATE_BEYOND_CURRENT_MONTH` (156 and 157 surface it inside their own messages).

  The fixtures record no reason for those dates. Most likely it keeps them clear of locked or closed periods when run
  against live.
- **Tim's choice** among four options (defer / rewrite now / test-only clock / narrow the rule): **defer to their own cut, with
  the 32 fixtures rewritten there and no bypass in the guards.**
- **Removed from Batch A:**
  - all date code;
  - the three codes and their copy;
  - the form `max`;
  - arm F.
- **Kept:** nothing. The deferred work, the measured count and the fixture list are in `docs/forward-queue.md` item 3.

### Fixtures

- **New `212-the-list-carries-what-the-ledger-posted.sql`**, arms A, A2, B, C, D, E. Each proves first that it cannot pass
  vacuously: the tax is real, the naive product really differs, the prepaid figure is really 280.
- **140 G:** pays the full payable (net + GST). The old arm asserted "paid" after paying the net, which was the defect.
- **161:** pays the batch before each write-off. Its subject is the 1200 side, and a payment touches only 2000 and the bank.

---

## §V · Verification — every figure is the script's own exit line

| step | result |
|---|---|
| `npm run build` (includes check-i18n, check-error-swallowing and 32 other checks) | `BUILD_OWN_EXIT=0` (after one red: check-date-format caught a hand-rolled `todayIsoLocal()`; replaced with `toYmd`; that line later left with the date rules) |
| `db/gate.py --offline`, final | `GATE_OWN_EXIT=0`, 49 s, 216 fixtures |
| fault injection (mirror edit → `--offline` → restore, file compared byte for byte) | **C1** `ap_open_items.open_ccy` back to net → exit 4, **212A** (first run: exit **0** — arm A asserted only `open_base`; it now asserts `open_ccy` too, the number the payment form pre-fills) · **C2** cap ignores prepayments → exit 4, **212B** · **C3** delete refusal off → exit 4, **212E** · **C4** `invoice_gst` branch off → exit 4, **212D** · clean after restore → exit 0 |
| backup (`db/run_detached.sh`, token BACKUP) | `BACKUP_EXIT=0` — `evoltrya-backup-2026-09-24-1012.dump`, 4.6 MB, verified by the script's `pg_restore --list` step, 10:20 |
| `db/apply_migration.sh` | `APPLY_OWN_EXIT=0`; pre-flight: 10 account codes, all `is_system`; 10 CREATE FUNCTION = 9 replaced + 1 new; no columns added; committed atomically with the function-grant replay |
| `npm run types:gen` | `TYPES_OWN_EXIT=0` — `lib/database.types.ts` +4 lines (the new function only) |
| `npx tsc --noEmit` | `TSC_OWN_EXIT=0` |
| `npm run build` (check-i18n and check-error-swallowing inside) | `BUILD_OWN_EXIT=0` |
| `db/gate.py` full (`db/run_detached.sh`, token GATE) | **`GATE_EXIT=0`**, 402 s — 可重建性 ✓ · 镜像 vs 线上 ✓ · 行为断言 ✓ · 匿名面 ✓ (baseline 327) |
| smoke (`db/run_detached.sh`, token SMOKE) | **`SMOKE_EXIT=0`** — 234 routes + probes: 252 ok · 7 skipped (no data) · **0 failed**; 227 timed routes, 590.8 s. Clean-up read at 10:45:38 as postgres from base tables (`auth.users`, `roles`, `user_roles`): this run's user **0**, its role **0**, any `smoke-%` user **0**, any `probe-%` role **0**, orphan grants **0**; `.ephemeral/` empty. The pre-run scratch-row report listed 6 stale rows (523–1,166 h old, pre-existing, report-only) |

## §P · Live proof

### Before and after

| reading | identity · object | before (10:12:38–40 CST) | after (10:32:24–26 CST) |
|---|---|---:|---:|
| `ap_open_items` Σ `open_base` | tim@ · **view** | 16 rows · **416,967.62** | 16 rows · **416,988.32** (+20.70) |
| `ar_open_items` Σ `open_base` | tim@ · **view** | 9 rows · **57,443.00** | 10 rows · **57,545.87** (+102.87) |
| `ap_aging_asof(today)` / `ar_aging_asof(today)` totals | tim@ · function | — | 416,988.32 / 57,545.87 (equal to the views) |
| EXP-2026-0007 / 0008 / 0009 `open_ccy` | tim@ · view | 100 / 30 / 100 | **109 / 32.70 / 109** |
| EXP-2026-0006 `open_ccy` | tim@ · view | 280,000 | 280,000 (unchanged; its **cap** changed, P1) |
| `invoice_gst` rows | tim@ · view | — | 1: INV-2026-0009, SGD, **102.87** |
| account 2000 balance | postgres · base `journal_lines` | −376,404.42 | −376,404.42 |
| account 1100 balance | postgres · base | 43,002.12 | 43,002.12 |
| `journal_entries` count | postgres · base | 82 | 82 |
| `approvals_enabled()` | postgres | true | true |
| `payment_requests` (all / pending) | postgres · base | 0 / 0 | 0 / 0 |
| `leave_requests` pending · `expense_claims` submitted | postgres · base | 2 · 1 | 2 · 1 (pre-existing; nothing added) |

The claim CLM-2026-0002 (EXP-2026-0007) reads `is_owing = true` both before and after. Its payable is now 109.00, and the
11.70 over-posting that affects it is CLAIM-GST-1.

The pre-migration consistency check (postgres, base tables) found all **7** unpaid posted expenses have
`amount_base + tax_base` equal to their 2000 credit, to the cent. The new list figure therefore equals the ledger for every one of them.

### Refusals and read-backs

These ran in **one rolled-back transaction**: a `DO` block that ends with `RAISE EXCEPTION 'PROOF_REPORT …'`, sent through
the Management API as postgres. Claims were set to tim@, or to admin@ for P5, because deletion needs `module.inbound.edit`,
which tim@ (`cfo`, read codes only) does not hold. `journal_entries` is still 82 afterwards.

| # | action | result |
|---|---|---|
| P1 | pay EXP-2026-0006 **280,000.01** | `ALLOC_EXCEEDS\|EXP-2026-0006\|280000.01\|280000.00` — before this cut the cap was 400,000 |
| P2 | pay EXP-2026-0009 **109.00** in one allocation | accepted; it leaves `ap_open_items` (0 rows); 2000 for the expense + payment pair nets **0.00** |
| P3 | receipt **1,245.87** on OUT-2026-0185: 1,143.00 to the sale + 102.87 to INV-2026-0009 | accepted; both rows leave `ar_open_items`; 1100 for sale + invoice + receipt nets **0.00** |
| P5 | soft-delete IN-2026-0152 (priced, unpaid) | `INBOUND_HAS_OPEN_PAYABLE\|IN-2026-0152\|2041.20` |

`EXPENSE_WHT_WITH_GST` was not exercised on live. No live supplier is non-resident with a taxed default, and minting one
would mean an INSERT outside a fixture. Fixture 212 arm C proves both the refusal and its ZP counter-case on the rebuilt database.

## §W · The broken window — closed with bounds (Batch A)

**Start: 2026-09-24 10:21:28 CST** — a **measurement**: `db/apply_migration.sh`'s own line, in `db/migration-windows.tsv`
("库已经是新的了 10:21:29").
**End: between 10:45:55 and 10:51:33 CST** — **bounds, not a measurement.** Tim confirmed the deploy on 2026-09-24
without a timestamp:
- **Lower bound, measured:** 10:45:55. origin/main moved to `fa7821ab` at this time (git's remote-ref log, "update by
  push"). A deploy cannot finish before its push.
- **Upper bound, derived:** 10:51:33. Tim's confirmation came before Batch B's session began; that session's first
  live read was stamped 10:51:33 by the database clock.
**Length: 24 min 27 s to 30 min 05 s.**

What the old app does against the new database while the window is open (approvals ON):

- **Receivables page:** it shows the new `invoice_gst` row (INV-2026-0009, 102.87) as if it were a **sale**. The old page
  branches only on `'invoice'`, so the row links to `/finance/receivables/<null>`, a dead link. The amount and the total are
  right.
- **Old payment form:** it maps that row to `sales_record_id = null`, so allocating to it fails `ALLOC_INVALID`. **Nothing is
  mis-posted**; that 102.87 simply cannot be collected until the deploy, which is also true of today's live app.
- **Old expense page:** it computes its own open amount (`amount_base − allocations`), so EXP-0007/0008/0009 read 100 / 30 /
  100 there while the list reads 109 / 32.70 / 109. A display-only disagreement.
- **Deleting a priced, unpaid receipt** from the old app surfaces the raw code `INBOUND_HAS_OPEN_PAYABLE|…`, because the old
  deletion mapper does not know it. The refusal itself is correct.
- **An expense with WHT and GST together** is refused with the raw `EXPENSE_WHT_WITH_GST|…` in the old app. Live has 0 such cases.
- **Unaffected:** everything else, including payment requests (0 exist), approvals, every other list, and every posting path.
  No ledger figure changes.

---

## §B · Batch B — the list and the ledger agree, and a thing that happened is dated no later than today (2026-09-24)

Migration: `db/migrations/2026-09-24-aprecon1b-the-list-and-the-ledger-agree.sql`, a single transaction, every object
copied verbatim from its mirror. It contains:
- 3 new functions: `list_ledger_reconciliation`, `list_open_base`, `reversal_date_for`;
- 1 new table, `list_ledger_residue`, seeded with 7 rows written only by the migration;
- 18 replaced functions;
- 1 replaced view, `order_invoice_balance_all`, with 3 columns appended and no existing column moved.

It adds no journal entries.

### B0 · Tim's rulings on the Batch B grilling (all accepted as recommended)

| Q | ruling | where it landed |
|---|---|---|
| Q1 | the register holds 7 rows, not 12; IN-0029, OUT-0001 and RCPT-0001 are explained by the computed lines | B1; `known-wrong-until-cutover.md` notes on those rows |
| Q2 | one definition of "on account" for both sides; reversal pairs excluded | B1 |
| Q3 | fix the one-cent defect in this batch, with a partial-payment check | B2 |
| Q4 | a new page, `/finance/list-vs-ledger`; the month-end step reads done or outstanding, never blocked | B3 |
| Q5 | the 7 callers that stamp today's date use the later of today and the original's date; an explicit earlier date is refused by name | B5 |
| Q5b | the journal page reverses on `businessToday()` instead of the UTC date | B5 |
| Q6 | add `relieve_processing_accruals` to Rule 1; queue the six cash doors | B5; queue; known-issues |
| Q7 | fixtures 30 and 47 compute the latest business day on or before today | B6 |
| Q8 | anchor on 2025; fixture 80 on 2024; fixture 16 on spread dates | B6 |
| Q9 | `max` = today on the expense, payment, invoice, export-freight and pay-request inputs as well as freight | B5 |
| Q10 | vacuous arms assert their specific refusal code | B6 |
| Q11 | Part 1, then `--offline`, then Part 2, applied as one migration | done in that order; the stopping line was not needed |
| **added mid-build** | a taxed **order** invoice owes net + tax, the same class as A3; fix it in Batch B | B2 |

### B1 · The standing check: `list_ledger_reconciliation()`

**What it compares, per side, over the whole ledger with no date cut:**
- **AP:** Σ `ap_open_items.open_base` against account 2000, as credits minus debits.
- **AR:** Σ `ar_open_items.open_base` against account 1100, as debits minus credits.

**The three named differences.** Every amount is its contribution to "list − ledger". There is no catch-all line.
- **Residue:** rows from `list_ledger_residue`. This is a migration-only table: RLS on, a SELECT policy for
  `module.finance.view`, no write policy, anon revoked. It is empty on a rebuilt database.
- **Revaluation:** control-account lines whose `source_type` is `revaluation`, computed and named.
- **On account:** `amount_ccy − Σ(allocated_pay − withheld_pay)` at the payment's own rate, which is the same expression
  `record_payment_internal` posts. It counts only payments that are **neither reversed nor themselves a reversal**.
  Without that exclusion, live AP would show 4,866.08 of on-account money that isn't real (PMT-0004/0005/0006/0008).

**Result:** `unexplained = gap − residue − revaluation − on account`, and `agrees` is `unexplained = 0`.

**Gates:**
- It requires `module.finance.view`.
- If the reader lacks `data.view_prices`, both sides return `refusal = 'PRICES_RESTRICTED'` with NULL figures, because
  the list amounts are masked and any difference would be false. No live identity holds finance view without price
  visibility, so this path is proven only by fixture 213 F.

**The 7 register rows.** Each carries a reason and a known-wrong reference. The amounts come from AP-RECON-0 §R and
AP-RECON-1 §1, re-measured today.

| side | document | amount | class |
|---|---|---:|---|
| ap | IN-2026-0001 | 7,104.00 | priced before payable posting |
| ap | IN-2026-0003 | 30,000.00 | priced before payable posting |
| ap | IN-2026-0011 | 2,100.00 | priced before payable posting |
| ap | IN-2026-0012 | 10,000.00 | priced before payable posting |
| ap | IN-2026-0154 | −4,032.00 | deleted while owing |
| ap | EXP-2026-0001 | 0.96 | FIN-2 backfill units (its 0.94 revaluation is on the revaluation line) |
| ar | OUT-2026-0007 | 20,350.00 | sold before sales posting |

`gl_control_reconciliation` keeps its signature and keys (Q8). Only its mirror header changed: the 2026-08-28 claim
that it "explains to the cent" is now marked as not holding, with the reason (grilling §3). Re-basing the management
pack is queued.

### B2 · Two live defects the fixture forced out, both fixed

**The cent (APRECON1-FOREIGN-TAXED-EXPENSE-CENT) is more general than the known-issue entry said.**
- **Where it shows up:** any partial settlement of a *foreign* document can leave the list and the ledger a cent apart.
  - The list shows `round(open × fx)`.
  - A relief took `round(allocated × fx)`.
  - `round(a·f) + round((G−a)·f)` need not equal `round(G·f)`, or the stored two-leg base.
  - Fixture 213 has a pair of numbers for each case that proves it drifts under the old code: expense B, freight A5,
    sale C2, credit note C9.
- **The fix:**
  - New `list_open_base(open, value, birth_base, fx)` is the list's own expression. At full value it returns the base
    posted at birth; at 0 it returns 0; otherwise `round(open × fx)`.
  - `record_payment_internal` relieves `list_open_base(before) − list_open_base(after)` for every document kind.
  - `create_credit_note` does the same, keeping its tax leg row-rounded (F5 reads it). The net leg takes the rest, and
    the debit legs follow, so the entry balances by construction.
  - The ledger left on a document now equals the list at every step, and a close leaves 0.00.
  - `customer_statement_data` now reads `allocated_base` for the applied amount, and the credit note's own 1100 legs
    for credits, so the statement ties exactly.
  - Base-currency documents (fx 1) are unchanged byte for byte.
- **Live exposure:** 0 partially settled foreign documents. The fix acts only on future settlements.

**A taxed ORDER invoice owed only its net (the same class as A3).** Asked mid-build with AskUserQuestion; Tim chose to
fix it in Batch B.
- **The defect:** `create_order_invoice` debits 1100 with net plus a tax leg. But `order_invoice_balance_all` (read by
  the list, aging, exposure and the credit-note ceiling) and the receipt cap in `record_payment_internal` counted
  `Σ invoice_lines` only. The fixture measured it at C11: list 1,200.00 against ledger 1,218.00.
- **Now:**
  - The amount is net + `tax_amount_for` per line, which is the expression `create_order_invoice` posts.
  - Credited amounts include each credit-note line's tax.
  - `open_base` goes through `list_open_base`, with birth = `round(net × fx) + tax_base`.
  - `ar_aging_asof` mirrors the same arithmetic as of a date.
  - The payment branch reads the view (cap, relief, and credit notes now also reduce the cap).
  - The credit note's ceiling (net + tax ≤ open) is now consistent with its own arithmetic.
- **Live exposure:** 0 taxed order invoices, before and after.
- **Fixture 71** had re-created the view with the old column list as a fault injection. It now appends the three new
  columns and remains a real injection.

### B3 · The month-end row and the page

- **`/finance/month-end`, new step `listVsLedger`:**
  - It shows the unexplained amount per side ("now, all dates") and links to `/finance/list-vs-ledger`.
  - Its state is `done` when both are 0.00, otherwise `outstanding`. It is never `blocked` and does not block
    `close_period` (Q11; `known-issues.md` § APRECON1B-CHECK-DOES-NOT-BLOCK-CLOSE).
  - Price-restricted readers see `outstanding` with the reason.
- **`/finance/list-vs-ledger`:**
  - A new page, registered under period-end in `lib/modules.ts`.
  - It renders the function's return as a component-library `DataTable`: seven rows per side, residue documents and
    on-account payments listed, unexplained in green or red. It does no arithmetic of its own.
  - Copy is in en and zh; the residue class labels come from the table's CHECK via the `check-i18n` manifest.
  - `EXPECTED_TABLES` in `check-document-registry.mjs` is now 226 (the new table has `doc_code`, not `code`).

### B4 · Fixture 213 — strict equality after every posting path

- **Setup:** fixed dates in March 2025, its own exchange rates on each date used (plus today's rate for the reprice),
  and the register empty on the rebuilt database.
- **The check:** after each step, `pg_temp.f213_agree` requires no refusal, residue 0 and unexplained **exactly 0.00**
  on both sides. The helper is a transaction-scoped temporary function, rolled back with the fixture.
- **The paths:**
  - **Payables, 21 steps:** priced receipt; USD pricing; reprice; taxed base expense; foreign taxed expense with a
    partial payment and a close; foreign freight with a partial payment and a close; export freight and its payment;
    expense reversal; freight reversal; payment on account (a named line of 500, then 0 after reversal); payment and
    its reversal; PO deposit; prepayment against a receipt; prepayment against an expense; WHT payment; accrual relief
    to a supplier; an open USD expense.
  - **Receivables:** on-account receipt run first (GST off), 300 then 0 after reversal; base sale; foreign sale with a
    partial receipt and a close; sale-invoice tax collected with the net; foreign order invoice through a partial
    receipt, a credit note and a close; taxed base order invoice through a partial receipt, a taxed credit note, a cap
    refusal at +0.01 and a close, with 1100 netting to 0.00 for that invoice; foreign taxed order invoice through a
    partial receipt, a taxed credit note and a close; an order-invoice void; an open USD sale.
  - **D:** revaluation gives a non-zero named line on both sides. Aging as of today equals the lists, and the
    customer's statement ties.
  - **E:** a manual 1.00 into 2000 gives AP unexplained **1.00**, AR 0.00 and `agrees = false`. Reversing it returns
    to 0.
  - **F:** a price-restricted reader gets `PRICES_RESTRICTED` with NULL figures; no finance view gives
    `PERMISSION_DENIED`; the register has no write policy and is not readable by anon.
- **Fault injection:** each case edited a mirror, ran `--offline`, then restored the file (SHA-256 compared byte for
  byte).

| # | injection | verdict |
|---|---|---|
| F1 | on-account line counts reversal pairs | exit 4, **213 C0b** |
| F2 | relief back to `round(alloc × fx)` | exit 4, **213 B2** (list 2,346.74 / ledger 2,346.73) |
| F3 | order-invoice tax dropped from the list | exit 4, **213 C11** |
| F4 | credit-note relief back to `round(total × fx)` | exit 4, **213 C9** |
| F5 | catch-all line forces unexplained to 0 | exit 4, **213 E** |
| — | clean after restore | exit 0 |

### B5 · The three date rules

**Rule 1, `DOCUMENT_DATE_IN_FUTURE|<kind>|<date>|<today>`.** It applies at seven doors:
- `record_expense` (expense)
- `record_payment_internal` (payment; this also covers paying a payment request)
- `record_freight_document` (freight)
- `record_export_freight_document` (export_freight)
- `create_invoice` (invoice)
- `create_order_invoice` (invoice)
- `relieve_processing_accruals` (expense, Q6)

The six cash doors are queued (Q6).

**Rule 2, `POSTING_DATE_BEYOND_CURRENT_MONTH|<date>|<month end>`,** in `assert_posting_allowed`. Every posting passes
through it, including direct inserts into `journal_entries` via the period trigger.

**Rule 3, `REVERSAL_BEFORE_ORIGINAL|<code>|<reversal date>|<original date>`,** in `reverse_journal_entry_internal`.
- The 7 callers that stamp today's date now use `reversal_date_for(entry)`, the later of today and the original's
  date: `reverse_expense`, `reverse_payment_internal`, `reverse_freight_document`, `unpost_payroll_period`,
  `rollback_processing_run` ×2, and `allocate_processing_costs`.
- Callers that pass their own date are refused by name when it is earlier: the journal page, `void_invoice`, WHT
  remittance reversal, and bank-transfer reversal.

**No test switch:** no GUC and no bypass in any guard.

**App:**
- `max = businessToday()` on the freight/export-freight form, the expense form, the new-invoice form, the order-invoice
  control, and `PaymentDateInput` (payment form and pay-request pay date).
- The journal page reverses on `businessToday()` instead of `new Date().toISOString()`, which was the UTC date and
  "yesterday" before 08:00 in Singapore.
- The three codes are translated in en/zh across 12 localizers: assay, hr, pack, freight, finance, payment, invoice,
  wht, credit note, expense, claims, and processing (`processing.errors`, for the accrual relief and run rollback).

**Fixture 214** (all dates relative to today):
- **A:** each of the seven doors refuses tomorrow by exact code **and** accepts today.
- **B:** month-end is accepted; the 1st of next month is refused, both through `post_journal_entry` and by a direct
  insert.
- **C:** a reversal dated before its original is refused; the same day is accepted.
- **D:** an entry dated month-end is reversed today on its own date via `reversal_date_for`. Passing today directly is
  refused. On the last day of a month that half can't separate, and the fixture says so in a NOTICE. A catalogue
  assertion checks that exactly 6 functions reverse through `reversal_date_for` and that none still passes
  `CURRENT_DATE`.

**Fault injection on a local rebuild** (mutated function applied, 214 run, mirror re-applied):

| injection | caught by |
|---|---|
| Rule 1 off in `record_expense` | 214 A (expense) |
| Rule 1 off in `relieve_processing_accruals` | 214 A (accrual_relief) |
| Rule 2 off | 214 B |
| Rule 3 off | 214 C |
| `reverse_expense` back to `CURRENT_DATE` | 214 D (catalogue) |

The fixture was clean again after restore.

### B6 · The 32 fixtures on real dates

- **Measured first:** with the rules in and the fixtures untouched, `db/gate.py --offline` failed **exactly the known
  32**, and 213 passed.
- **The moves (reasons per fixture in the grilling hand-back):**
  - **27 by a uniform year shift keeping month and day:** 2027→2025 (100, 101, 103, 104, 105, 154, 156, 157, 161, 163,
    176, 181, 182, 183, 190, 28, 29, 31, 39, 42, 44, 46, 51); 2030→2025 (210, 211); 2028→2024 (80, keeping it a year
    apart from 28); 2029→2025 (81). Each file gets a header line recording the move.
  - **By hand:**
    - **16:** A/B in March 2025 (51.61 holds); the cap runs at 2026-01-31 and 2026-03-31; dispose at 2026-06-30 and
      re-run at 2026-08-31; D and F unchanged.
    - **17:** closes FY2025, with `system_start_date` 2025-01-01 and the `YEAR_CLOSED|2025-09-15|2025-12-31` literal.
    - **30 and 47:** the fx-gap entry (and 30's resolving rates) sit on the latest business day ≤ today, computed with
      `is_business_day` (Q7). The rest of 30 moved to 2025, including `claim_year` 2025.
    - **38:** 2025, with the missing-metal probe at 2024-12-31 (before the first ni price) and the missing-rate probe
      at 2025-06-10, a Tuesday five days after the rate date.
- **Vacuous arms tightened (Q10):**
  - 46B requires `CREDIT_LIMIT_EXCEEDED`.
  - 154 F5 requires `IOD_SALE_EXCEEDS_AVAILABLE`.
  - 157 G5 requires `SALE_BATCH_EARMARKED` / `SALE_FORM_NOT_SALEABLE` / `IOD_SALE_EXCEEDS_AVAILABLE`.
  - 210 D2 and 211 B10 first assert that the pay date isn't today.
- **Live-runnability:** unchanged in practice. Live has `locked_before` 2026-08-01, so 2025 dates would be
  `PERIOD_LOCKED` there, and most of these fixtures' own `locked_before = NULL` is already refused on live. The gate is
  the runner that counts.

### §BV · Verification — every figure is the script's own exit line

| step | result |
|---|---|
| `db/gate.py --offline`, final (all of Part 1 + Part 2) | `GATE_OWN_EXIT=0`, 53 s, **217** fixture files, 217 ✓ |
| Part 1 fault injection (F1–F5, `--offline`, byte-identical restore) | all five exit 4 on fixture 213; clean exit 0 (`INJ_OWN_EXIT=0`) |
| Part 2 fault injection (local rebuild, five cases) | all five caught by 214; clean after restore |
| migration dress rehearsal (local rebuild from HEAD `fa7821ab` mirrors, then migration) | `MIG_LOCAL_OWN_EXIT=0`; catalog (functions, views, columns, policies — 5,489 lines) **identical** to a rebuild from the new mirrors; register ap 6 / 45,172.96, ar 1 / 20,350.00 |
| static checks (the build's 34 scripts, before the migration) | `CHECKS_OWN_EXIT=0` (after: regenerating `lib/deepRoutes.generated.ts`; the page moved onto `DataTable`; `EXPECTED_TABLES` 225 → 226) |
| backup (`db/run_detached.sh`, token BACKUP) | `BACKUP_EXIT=0` — `evoltrya-backup-2026-09-24-1151.dump`, 4.6 MB, TOC 6,078 (previous 6,076), verified by the script, 11:59 |
| `db/apply_migration.sh` | `APPLY_OWN_EXIT=0`; pre-flight 26 account codes all `is_system`, 21 CREATE FUNCTION = 18 replaced + 3 new, no masked columns; committed atomically with the function-grant replay |
| `npm run types:gen` (after `NOTIFY pgrst, 'reload schema'`) | `TYPES_OWN_EXIT=0` — `lib/database.types.ts` +41 lines (the new table and three functions) |
| `npx tsc --noEmit` | `TSC_OWN_EXIT=0` |
| `npm run build` | `BUILD_OWN_EXIT=0` |
| `node scripts/check-i18n.mjs` / `check-error-swallowing.mjs` | `I18N_OWN_EXIT=0` / `SWALLOW_OWN_EXIT=0` |
| `db/gate.py` full (`db/run_detached.sh`, token GATE) | **`GATE_EXIT=0`**, 369 s wall-clock — 可重建性 ✓ · 镜像 vs 线上 ✓ · 行为断言 ✓ · 匿名面 ✓ (baseline 327) |
| smoke (`db/run_detached.sh`, token SMOKE, `--timeout 2400`) | **`SMOKE_EXIT=124` — the supervisor's timeout, NOT a pass.** The route walk itself completed: 235 routes + probes, **253 ok · 7 skipped (no data) · 0 FAILED**, 228 timed routes 557.4 s. After the summary, the final clean-up printed `✗ 收尾清扫抛出:fetch failed` and the process did not exit until `run_detached` killed it at the 2,400 s limit. Clean-up read afterwards at 14:05:23 CST as postgres from base tables (`auth.users`, `roles`, `user_roles`): this run's user **0**, its role **0**, any `smoke-%` user **0**, any `probe-%` role **0**, orphan grants **0**; `.ephemeral/` empty; no smoke or `next dev` process left. So nothing was left on live, but the verdict line is 124, and this handback does not report it as a pass. **Why it hung (found in CLAIM-GST-1, 2026-09-24, from this run's own log):** the order of the last two lines is
`SMOKE_EXIT=124` *then* `✗ 收尾清扫抛出:fetch failed`. The process had printed its summary and was inside
`exitAfterCleanup` → the name-based sweep (`beforeFinish` → `sweepScratch`), waiting on a REST call with **no timeout**.
It was not the error that hung it; the error was printed only after `run_detached`'s SIGTERM. The SIGTERM itself could
not cut it short, because `exitAfterCleanup` is re-entrant by design (a second call gets the same promise, which was
still waiting). CLAIM-GST-1 bounds the clean-up: 15 s per call, 120 s for the phase, exit **6** naming what was left
(`docs/handbacks/CLAIM-GST-1.md` §S). The pre-run scratch-row report listed 6 stale rows (525–1,167 h old, pre-existing, report-only). |

### §BP · Live proof

**Before and after** (identity and object stated for each):

| reading | identity · object | before (11:50:50–53 CST) | after (12:02:53–54 CST) |
|---|---|---:|---:|
| `ap_open_items` n · Σ `open_base` | tim@ · **view** | 16 · 416,988.32 | 16 · 416,988.32 |
| `ar_open_items` n · Σ `open_base` | tim@ · **view** | 10 · 57,545.87 | 10 · 57,545.87 |
| account 2000 (debit − credit) | postgres · base | −376,404.42 | −376,404.42 |
| account 1100 (debit − credit) | postgres · base | 43,002.12 | 43,002.12 |
| `journal_entries` count | postgres · base | 82 | 82 |
| `approvals_enabled()` | postgres | true | true |
| `payment_requests` all / pending | postgres · base | 0 / 0 | 0 / 0 |
| `leave_requests` pending · `expense_claims` submitted | postgres · base | 2 · 1 | 2 · 1 (pre-existing; nothing added) |
| `list_ledger_residue` | postgres · base | (table absent) | ap 6 rows / 45,172.96 · ar 1 row / 20,350.00 |
| taxed order invoices | postgres · base `invoices` | 0 | 0 |

**Proof: one rolled-back transaction.** A `DO` block ending in `RAISE EXCEPTION 'PROOF_REPORT …'`, sent through the
Management API as postgres at 12:02:26 CST.
- **Claims:** tim@ `634c00f9-…` for the reads; chooer@ `476bf8c8-…` (role `finance`) for the postings; fusheng@
  `c8116e6c-…` (role `warehouse`) for the refusal.
- **Entry count:** 85 inside before the rollback (P3, P5 and P6 each posted one); **82 afterwards**.

| # | action | result |
|---|---|---|
| P1 | `list_ledger_reconciliation()` as tim@ | **AP:** list 416,988.32 (16) · ledger 376,404.42 · gap 40,583.90 · residue 45,172.96 (6) · revaluation −4,589.06 · on account 0.00 · **unexplained 0.00**, agrees. **AR:** list 57,545.87 (10) · ledger 43,002.12 · gap 14,543.75 · residue 20,350.00 (OUT-2026-0007) · revaluation −6,056.25 · on account 250.00 (RCPT-2026-0001) · **unexplained 0.00**, agrees. Every figure equals the grilling's hand arithmetic. |
| P2 | the same, as fusheng@ (no finance view) | `PERMISSION_DENIED|module.finance.view` |
| P3 | manual 1.00 debit into 2000, then P1 again | AP unexplained **1.00**, AR **0.00** |
| P4 | expense / payment / freight dated 2026-09-25 | `DOCUMENT_DATE_IN_FUTURE|expense|2026-09-25|2026-09-24` · `…|payment|…` · `…|freight|…` |
| P5 | manual entry dated 2026-10-01; then one dated 2026-09-30 | `POSTING_DATE_BEYOND_CURRENT_MONTH|2026-10-01|2026-09-30`; 09-30 accepted (JE-2026-0081, rolled back) |
| P6 | reverse that 09-30 entry dated 09-24; then via `reversal_date_for` | `REVERSAL_BEFORE_ORIGINAL|JE-2026-0081|2026-09-24|2026-09-30`; `reversal_date_for` = 2026-09-30; the reversal was dated 2026-09-30 |

Not exercised on live: `PRICES_RESTRICTED`, because no live identity holds finance view without price visibility.
Fixture 213 F proves it.

### §BW · The broken window — started, end PENDING

**Start: 2026-09-24 12:00:00 CST.** This is `db/apply_migration.sh`'s own line ("库已经是新的了 12:00:00"), in
`db/migration-windows.tsv`. The script's "applied at" line reads 11:59:30; the commit came at 12:00:00.
**End: between 14:06:06 and 14:12:29 CST — bounds, not a measurement** (closed in CLAIM-GST-1, 2026-09-24). Tim
confirmed the deploy on 2026-09-24 without a timestamp:
- **Lower bound, measured:** 14:06:06. origin/main moved to `e8fcfb6c` at this time (git's remote-ref log,
  "update by push"). A deploy cannot finish before its push.
- **Upper bound, derived:** 14:12:29. Tim's confirmation came before the CLAIM-GST-1 session began; that session's first
  live read was stamped 14:12:29 by the database clock (as postgres, Management API).
**Length: 2 h 06 min 06 s to 2 h 12 min 29 s.** Most of it is the gate, the smoke (which ran to its 2,400 s limit —
see §BV) and the docs, all of which ran before the push, as AGENTS.md orders.

What the old app does against the new database while the window is open (approvals ON):
- **Nothing is mis-posted and no figure moves.** Every list and ledger reading above is unchanged.
- **Dating a document after today:** a freight, expense, invoice or payment dated after today (including paying a
  payment request with a future pay date) is refused, and the old app shows the raw `DOCUMENT_DATE_IN_FUTURE|…` code.
  Its mappers don't know it, and its forms have no `max`. The refusal itself is correct.
- **Entries after month-end:** any entry dated after the end of this month is refused with a raw
  `POSTING_DATE_BEYOND_CURRENT_MONTH|…`.
- **Journal page, earlier reversal date:** it still sends the UTC date. A reversal of an entry dated later than
  that date is refused with a raw `REVERSAL_BEFORE_ORIGINAL|…`. The same refusal hits before 08:00 in Singapore when
  reversing an entry dated today.
- **Pages that don't exist yet:** the month-end step and `/finance/list-vs-ledger` exist only in the new app. The old
  month-end page simply doesn't show the row.
- **Unaffected:** approvals and payment requests (0 exist), every other page, and every posting path within the rules.
  Relief amounts change only for foreign-currency partial settlements, and live has none.
