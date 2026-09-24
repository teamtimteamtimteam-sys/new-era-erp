# AP-RECON-1 · Batch A — the lists carry what the ledger posted (2026-09-24)

Batch A fixes four live defects that kept pulling the open-items lists away from their ledger accounts. The date rules
(Q7) were moved out to their own cut on Tim's ruling, mid-build (§A5). Batch B (the residue register, the standing
check, the month-end row and its fixture) has not been started — this session stops after Batch A.

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

## §W · The broken window — started, end PENDING

**Start: 2026-09-24 10:21:28 CST** (`db/apply_migration.sh`'s own line; `db/migration-windows.tsv`; "库已经是新的了 10:21:29").
**End: PENDING. Tim reads it from Vercel.**

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

## §B · Batch B, as agreed (not started)

- **Residue register** (Q9):
  - Migration-only table: side, document code, amount, class, `reason` NOT NULL, known-wrong reference.
  - No write policies, following the `document_type_exceptions` pattern.
  - Seeded with the per-document rows:
    - **AP:** IN-0001, 0003, 0011, 0012 (A); IN-0154 (B); IN-0029 revaluation; EXP-0001.
    - **AR:** OUT-0007; OUT-0001 revaluation; RCPT-0001.
  - The count is to be re-checked against Q9's "12" when the rows are written. Revaluation and on-account are computed lines, not rows.
- **Standing check** (Q6, Q8, Q10):
  - A new function computes, per side: list total vs ledger balance (whole ledger, no date cut), minus the registered
    residue (per document), minus revaluation lines (computed, named, shown), minus payments on account (computed, named).
  - The unexplained amount must be 0.00. There is no catch-all bucket.
  - `gl_control_reconciliation`: keep its signature and keys, correct its header, queue the pack re-base.
- **Month-end row** (Q11): per side, the unexplained amount and a link to the reconciliation. It does **not** block `close_period`.
- **Fixture:** on a rebuilt database the register is empty, so the check must be strict equality after every posting path.
  Fault-inject it. It will force APRECON1-FOREIGN-TAXED-EXPENSE-CENT.
