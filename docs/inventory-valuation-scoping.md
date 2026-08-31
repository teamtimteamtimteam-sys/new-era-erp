# Inventory valuation — survey, 2026-08-31 (INV-VAL-0)

**Read-only survey. Nothing was built, nothing was migrated, no fixture was run. This document is
the whole deliverable.**

**Recommendation up front: BUILD A SMALLER THING NOW.** Not a new inventory valuation report — a
**third side on `gl_control_reconciliation`** plus **value columns on the RPT-1 snapshot report that
already exists**. Both audiences are served by machinery this repo already owns; almost nothing here
is new. §8 sizes it. §9 says what stays blocked and on what.

**The one finding that reorders everything else:** the brief was commissioned on the premise that no
valuation surface exists, inherited from PROC-COST-1 §4. **Re-measured, that premise is false in
three places** (§1) — and it was already false when it was written, for a reason the brief did not
anticipate. What does not exist is a valuation that *ties to the ledger* — and the machinery for
tying a sub-ledger to a control account was built on 2026-08-28 for AR and AP, with an as-at date,
named variance categories, a no-catch-all rule, and a CSV export (§1.3). Inventory is a **missing
third side**, not a missing capability.

---

## 0 · A CORRECTION TO THIS SURVEY'S OWN BRIEF — dated 2026-08-31

The brief states, as live fact to be reported rather than fixed:

> THE PLANT IS NOT RUNNING … ALL live output batches are TEST RESIDUE … The finished-goods side of
> any valuation is therefore EMPTY BY FACT, not broken.

**That is true about production and false about the ledger.** Measured (§4):

| | SGD |
|---|---|
| Produced side (`remaining_qty` × `processing_outputs.unit_cost_base`) | **388.20** |
| Ledger 1220 Inventory – Finished Goods | **134.86** |

Neither is zero. A valuation report that renders the finished-goods side as "empty" would **disagree
with the ledger it is required to tie to**, on its first line. The ruling that all output is test
residue is untouched — it explains *why* the numbers are small and meaningless as business
information. It does not make them absent. §4 says what the column should render instead.

---

## 1 · WHAT ALREADY EXISTS (STEP 1 / 3d) — three surfaces, re-measured, not trusted

PROC-COST-1 §4 recorded "**实测:不存在**" — there is no valuation reader. **That measurement was
correct for what it measured** (a *posting-grade* unit cost consumed by costing — its own list is
four bullets long and every one of them is about a *consumer of unit cost*) and is **wrong as a
general statement**, which is how the brief inherited it.

**The brief asked to re-check because three cuts have changed costing since. The honest answer is
that the three cuts are not why the premise fails.** All three surfaces below predate PROC-COST-1;
they were never in scope of what it measured. What the cuts since *did* add is
`inbound_batch_landed_unit_cost` (PROC-COST-2) — the single canonical per-unit landed cost that a
valuation would read, which genuinely did not exist when PROC-COST-1 wrote that line. So the brief's
instruction to re-measure was right, and the thing it turned up is the opposite of the one expected:
not "a surface appeared", but **"three surfaces were there all along, and the missing piece was the
reader, which now exists."** Re-measured:

### 1.1 A screen-grade valuation with ageing — `lib/valuation.ts`, 98 lines

Consumed by `/inventory` (`app/inventory/page.tsx`, header comment: "cut 5:估值") and by two
per-material drill-downs, `/inventory/inbound/[materialId]` and `/inventory/output/[materialId]`.

It already computes: batch value, market value from assay metal content × latest metal price,
`agingDays()` from `arrival_date` (inbound) / `output_date` (output), three-band ageing tone, and an
explicit **unpriced count** rendered separately from a zero.

**What it is not.** It values at **`unit_price` only** — grepped across `app/inventory/**`, it never
calls `batch_freight_base`, `batch_processing_cost_base` or `inbound_batch_landed_unit_cost`, so it
is **not landed cost** (§2d/M2). It has no location dimension, no as-at date, no export, and no
ledger tie.

**A correction to this section's own first draft:** `/inventory` **is** a company-wide surface — it
renders a summary bar of `totalInboundValue` / `totalCostValue` / `totalMarketValue` across all
materials, plus an unpriced badge. What is per-material is the *drill-down*, not the valuation.

**Two defects found in it. One is a comment; the other is on a live screen.**

* **★ `marketValue` is a USD figure rendered and labelled as SGD. ★** `metal_prices.price_usd_per_tonne`
  is USD per tonne (the column name says so). `marketValuePerKg()` divides by 1000 and returns
  **USD/kg** — its own module comment says "每公斤市价". Traced through both consumers, **no FX
  conversion is applied anywhere**: `/inventory` renders it `formatAmount(totalMarketValue,
  baseCurrency)` → "SGD", and `/inventory/output/[materialId]` renders it under a column header
  `列头「市价价值 (SGD)」`. On `/inventory` it sits in the **same summary bar** as
  `totalInboundValue` and `totalCostValue`, which genuinely *are* SGD. At the 1.28 rate used for
  IN-2026-0181, the market column understates by roughly 22%, and nothing on screen says the two
  numbers are in different currencies.

  This is not "money without a currency" — that class was audited and closed. This is **money with
  the wrong currency stated**, which is the failure mode that audit's rule 3 exists to prevent
  ("同一块面板中途换币种时,必须标出分界"), reached one layer below where that audit looked.
  **It is live now.** Recorded here, not fixed — this survey is read-only, and it is a correction in
  its own right, not part of a valuation build. **It does mean §6 item 5 must fix the currency, not
  merely the cost basis, before any valuation report reuses this module.**

* **`lib/valuation.ts` says `USD/kg` in two more type comments** (`unitPrice`, `unitCost`) where the
  value is **base currency (SGD)** — `reprice_inbound_batch` writes `original_price × fx_rate`, and
  live confirms it: IN-2026-0181 is `6.34 USD × 1.28 = 8.1152`, stored as 8.1152. Here the
  **screens are right** (`列头「单价 (SGD)」` via `formatMoneyBare`); only the comments lie. Harmless
  today, and directly misleading to whoever builds on this module next — which is the point of
  recording it.
* **`marketValuePerKg()` returns USD/kg** (metal prices are USD/tonne) and is rendered in the same
  table as SGD cost columns. `/inventory` labels them separately, so no screen is wrong today — but
  a valuation report that puts a cost column and a market column side by side inherits a
  **mid-panel currency change**, which is precisely what that audit's rule 3 governs.

### 1.2 A quantity report with location and export — RPT-1

`/inventory/reports/snapshot` — material × location × status, **CSV and PDF export routes both
exist** (`app/inventory/reports/snapshot/{export,pdf}/route.ts`). Siblings: `ledger` (movement
history with from/to date filters), `safety`, `violations`, each with CSV + PDF.

It carries **no money**, and no as-at date. Its header comment already names the location problem
honestly: "线上 79/85 行流水没有库位" — measured today it is **99 of 106** (§3a).

### 1.3 ★ The tie-to-ledger machinery — `gl_control_reconciliation`, GLEXPORT-1, 2026-08-28 ★

**This is the finding that should decide the build.** The function already does, for AR and AP,
every single thing R2 asks for:

* takes an **as-at date** (`p_as_of`, refuses NULL by name — `AS_OF_REQUIRED`);
* reads the ledger side through `journal_activity_lines`, deliberately **not** filtered on
  `status='posted'` (its header records that the posted-only bug appeared four times in this repo,
  once wrong on live for months);
* reads the sub-ledger side from **a different set of tables**, which is the entire basis for the
  two sides being able to disagree;
* decomposes the difference into **named categories with no catch-all bucket**, so
  `unexplained_base` can actually move — its header calls a permanently-zero verdict "装饰,不是检查";
* reports `reconciled` on the **residue**, not on the difference.

Run on live today, as Tim, as-at 2026-08-31:

| side | control | ledger_base | subledger_base | difference | origination | settlement | revaluation | **unexplained** |
|---|---|---|---|---|---|---|---|---|
| ar | 1100 | 43,002.12 | 57,443.00 | 14,440.88 | 20,247.13 | 250.00 | 6,056.25 | **0.00** ✓ |
| ap | 2000 | 372,450.04 | 430,037.62 | 57,587.58 | 62,175.68 | 0.96 | 4,589.06 | **0.00** ✓ |

**And the AP origination variance is already the same root cause as inventory's.** That function's
own header names it: "起单差异主要是五张 cutover 前的进料批次 —— IN-2026-0001/0002/0003/0011/0012
在明细账里有价,而总账里没有【存活的】应付分录". Those are **the same batches** that drive
111,015.56 of the inventory divergence in §2. One cause, two sides — which is the strongest possible
evidence that inventory belongs in this function rather than in a new one.

### 1.4 The month-end snapshot mechanism — it exists, twice (STEP 3d)

**The brief asks whether a snapshot mechanism exists and warns that a second one would be a
duplicate dimension. Two exist.**

**`period_closes` — the trigger.** `close_period(p_period_end, p_notes)`:

* refuses a non-month-end date by name (`NOT_MONTH_END`);
* serialises on `finance_settings` with `FOR UPDATE` and refuses to re-close a locked period
  (`ALREADY_CLOSED`);
* refuses while depreciation is outstanding (`DEPRECIATION_OUTSTANDING`);
* refuses on an unbalanced trial balance (`TRIAL_BALANCE_UNBALANCED`);
* **freezes** `entries_count / total_debits / total_credits`, guarded by
  `guard_period_close_mutation()` which locks every column and forbids `DELETE`;
* **stops two being taken for the same month** with `idx_period_closes_active_period` — a partial
  unique index on `(period_end) WHERE reopened_at IS NULL`;
* re-opening keeps the row and stamps it. Live carries one row: 2026-07-31, 18 entries,
  Σ 757,013.37 both sides, not reopened.

**`management_packs` — the frozen artefact.** GLEXPORT-1's table comment is a direct answer to the
brief's question "who takes it, and what stops two being taken for the same month":

> ★★【一份存下来的包意味着一件事,而这句话就是本表存在的全部理由】★★ **它被产出的那一刻,那个月已经关账了。**

* `CHECK management_packs_month_was_locked` requires `locked_before_at_production > period_end` —
  an open month **cannot be stored**, only previewed;
* re-issue is a **new row + supersede + mandatory reason**, "更正是一个新事件,不是一次编辑";
* the payload is whole-pack `jsonb`, deliberately not split into columns, so a new section does not
  require a schema change;
* it already carries `control_reconciliation` and a **`caveats` block that names each absence with
  its own criterion** — including `control_unexplained` and `control_unexplained_base`;
* the CSV export already prints a `CONTROL ACCOUNT vs SUB-LEDGER` section and a
  `WHAT THIS PACK CANNOT SEE` section.

**So the answer to STEP 3d is: yes, and building a second one would be the duplicate dimension the
brief warned about.** Adding inventory as a section of the existing pack costs a `jsonb_build_object`
key and four CSV rows.

### 1.5 One duplicate dimension that already exists — two ageing definitions

* `aging_bucket(p_days)` — DB, `IMMUTABLE`, bands **0-30 / 31-60 / 61-90 / 90+**, five consumers,
  returns NULL for NULL days because "算不出来的档位不是 90 天以上". Its comment says it was
  extracted precisely because the boundaries had been written three times.
* `AGING_BANDS` in `lib/valuation.ts` — TS, bands **30 / 90**, presentational tone only.

An inventory valuation report must not add a third. **Ruling taken (Q4): adopt `aging_bucket`.**

---

## 2 · THE RECONCILIATION, MEASURED ON LIVE (STEP 2)

All figures SGD (base currency, `currencies.is_base`), as-at 2026-08-31, read via the Management API
as `postgres`.

### 2a · The batch side — 185,703.48

Derived as `Σ remaining_qty × inbound_batch_landed_unit_cost(id)` over the 16 non-deleted inbound
batches. `inbound_batch_landed_unit_cost` is PROC-COST-2's single definition of "what is this batch
worth per unit": `unit_price + (batch_freight_base_all + batch_processing_cost_base_all) / quantity`,
returning NULL when the batch has neither a price nor any capitalised cost.

| batch | remaining | unit_price | freight | proc cost | landed unit | **on-hand value** |
|---|---:|---:|---:|---:|---:|---:|
| IN-2026-0001 | 887 | 1.4800 | 0.00 | 0.00 | 1.4800 | 1,312.76 |
| IN-2026-0002 | 100 | 133.0000 | 0.00 | 0.00 | 133.0000 | 13,300.00 |
| IN-2026-0003 | **80** | 600.0000 | 0.00 | 0.00 | 600.0000 | 48,000.00 |
| IN-2026-0011 | 0 | 150.0000 | 0.00 | 0.00 | 150.0000 | 0.00 |
| IN-2026-0012 | 50 | 200.0000 | 0.00 | 0.00 | 200.0000 | 10,000.00 |
| IN-2026-0029 | 3,800 | 12.0000 | 0.00 | 0.00 | 12.0000 | 45,600.00 |
| IN-2026-0152 | 0 | 5.0400 | 0.00 | 0.00 | 5.0400 | 0.00 |
| IN-2026-0153 | 0 | — | 0.00 | 0.00 | **NULL** | **—** |
| IN-2026-0156 | 400 | 5.1728 | 0.00 | 0.00 | 5.1728 | 2,069.12 |
| IN-2026-0179 | 300 | — | 0.00 | 0.00 | **NULL** | **—** |
| IN-2026-0180 | 99,970 | — | 0.00 | 0.00 | **NULL** | **—** |
| IN-2026-0181 | 8,000 | 8.1152 | 0.00 | 0.00 | 8.1152 | 64,921.60 |
| IN-2026-0258 | 1 | — | 0.00 | 0.00 | **NULL** | **—** |
| IN-2026-0321 | 800 | — | 0.00 | 0.00 | **NULL** | **—** |
| IN-2026-0322 | 1,000 | — | 0.00 | 0.00 | **NULL** | **—** |
| ZZ-PROCCOST1-DEMO | 100 | 5.0000 | 0.00 | 0.00 | 5.0000 | 500.00 |
| | | | | | **TOTAL** | **185,703.48** |

**Two facts about this column that matter more than the total.**

1. **Every freight and processing-cost cell is 0.00, and that is not because nothing was ever
   posted.** One `freight_allocations` row (2,897.00) and one `batch_processing_cost_allocations`
   row (123.45) exist physically. Both are excluded — the freight document is `status='reversed'`,
   the processing run is soft-deleted and `status='reversed'`. This is PROC-COST-2's
   "冲销即解除" working: the carrier rows still exist, the readers exclude them. **So the entire
   capitalisation dimension of any valuation is currently zero on live**, and every mechanism in
   §2d that involves freight or processing cost is currently zero for that reason and not because it
   cannot fire.
2. **102,071 kg of on-hand stock carries no value at all** — 6 batches with NULL landed unit cost,
   99,970 kg of it the `ZZ-SMOKE-PROBE` batch IN-2026-0180. That is **88.4% of the on-hand
   tonnage valued at nothing**. A valuation report that shows only money will show 185,703.48 next
   to a quantity column and imply those kilos are worthless. They are **unpriced**, which is a
   different statement, and §5 requires it to render differently.

### 2b · The ledger side

Every account with `account_type='asset'` was read; only three are inventory accounts.

| account | name | net Dr | lines |
|---|---|---:|---:|
| **1200** | Inventory – Raw Materials | **74,687.92** | 18 |
| **1210** | Inventory – Work in Progress | **0.00** | **0** |
| **1220** | Inventory – Finished Goods | **134.86** | 3 |
| | **Total inventory carrying value per GL** | **74,822.78** | |

Related, not inventory: **5200** Inventory Adjustment (cogs, `is_system`) — Dr **46,432.00**, 3 lines.

**1210 has never been posted to.** Zero lines, `is_system = false`. PROC-COST-1 §1 recorded the
ruling: "一个字都没碰 … 那是建账的人的地盘". A valuation report must render WIP as
**not-applicable, not as 0.00** (§5) — and note that `processing_wip` (the view) is a *quantity*
view of unsaleable output batches, which is a **different definition of WIP** from account 1210.
Nothing reconciles them today and this survey does not propose that it should.

### 2c · THE DIFFERENCE, ACCOUNTED FOR LINE BY LINE

> **185,703.48 − 74,687.92 = 111,015.56**

They do **not** agree. Below is every cause, with its amount. **The causes sum to the difference
exactly; there is no residue.** Attribution was done by resolving each of the 18 journal lines
touching 1200 back to its batch via `journal_entries.source_id` (and via `processing_inputs` for
`source_type='allocation'`, `stocktake_lines` for `'stocktake'`).

**First, the ledger side proves itself.** The 18 lines net to exactly 74,687.92, with all four
reversal pairs netting to zero (25,600 / 247,296 / 2,897 / 123.45):

```
+48,000.00  JE-2026-0015  Pricing IN-2026-0029
+ 2,041.20  JE-2026-0025  Pricing IN-2026-0152        (in-stock share)
+ 4,032.00  JE-2026-0036  Pricing IN-2026-0154        (in-stock share)
- 4,032.00  JE-2026-0038  Write-off IN-2026-0154
+ 2,069.12  JE-2026-0039  Pricing IN-2026-0156        (in-stock share)
+64,921.60  JE-2026-0040  Pricing IN-2026-0181        (in-stock share)
-   444.00  JE-2026-0045  Capitalize PROC-2026-0164   (material cost → 1220)
-40,000.00  JE-2026-0056  Write-off IN-2026-0013
- 2,400.00  JE-2026-0057  Stocktake ST-2026-0080
+   500.00  JE-2026-0071  Pricing ZZ-PROCCOST1-DEMO   (in-stock share)
─────────────────────────────────────────────────────────────────────
= 74,687.92  ✓ equals the account balance
```

**Then, per batch:**

| batch | batch side | GL 1200 net | **difference** | cause |
|---|---:|---:|---:|---|
| IN-2026-0029 | 45,600.00 | 45,600.00 | **0.00** ✓ | 48,000 priced − 2,400 stocktake loss. **Exactly right.** |
| IN-2026-0156 | 2,069.12 | 2,069.12 | **0.00** ✓ | priced after the in-stock split existed |
| IN-2026-0181 | 64,921.60 | 64,921.60 | **0.00** ✓ | same |
| ZZ-PROCCOST1-DEMO | 500.00 | 500.00 | **0.00** ✓ | +500 priced, +123.45 capitalised, −123.45 rolled back |
| IN-2026-0154 | 0.00 | 0.00 | **0.00** ✓ | +4,032 priced, −4,032 written off. Symmetric. |
| IN-2026-0322 | — | 0.00 | **0.00** ✓ | +2,897 freight, −2,897 reversed |
| IN-2026-0002 | 13,300.00 | 0.00 | **+13,300.00** | **(C1)** |
| IN-2026-0012 | 10,000.00 | 0.00 | **+10,000.00** | **(C1)** |
| IN-2026-0003 | 48,000.00 | 0.00 | **+48,000.00** | **(C2)** + **(C4)** |
| IN-2026-0001 | 1,312.76 | −444.00 | **+1,756.76** | **(C2)** + **(C3)** |
| IN-2026-0013 | 0.00 (deleted) | −40,000.00 | **+40,000.00** | **(C5)** |
| IN-2026-0152 | 0.00 | +2,041.20 | **−2,041.20** | **(C6)** |
| | **185,703.48** | **74,687.92** | **111,015.56** ✓ | **sums exactly** |

**(C1) Priced before the posting path existed — +23,300.00.** IN-2026-0002 and IN-2026-0012 were
priced on 2026-07-05 (23:38 and 23:37 per `price_history`). The first pricing journal entry in the
system is JE-2026-0001, dated **2026-07-06**. Five batches were priced that evening
(IN-2026-0002/0003/0011/0012/0013); none produced a journal entry. **These are the same five batches
`gl_control_reconciliation`'s own header names as the bulk of the AP origination variance.**
`docs/known-wrong-until-cutover.md` governs this class: gone on a clean production rebuild.

**(C2) The reprice posts a *delta*, against a base the ledger never received — +49,312.76.**
This is the mechanism worth understanding, because it is not a data problem.

`reprice_inbound_batch` posts the **difference** between old and new price, not the new value:

* IN-2026-0003: priced 88 on 07-05 (**no JE**), repriced to 600 on 07-06 → JE-2026-0001 =
  `(600 − 88) × 50 = 25,600`. Correct arithmetic, anchored to a number 1200 never held.
* IN-2026-0001: priced 53 USD on 07-05 (**no JE**), repriced to 1.48 SGD on 07-06 → JE-2026-0003 =
  `(1.48 − 53) × 4,800 = −247,296`. A credit of a quarter-million against a balance that had never
  been debited.

Both were then reversed, so the ledger's net position on these two batches is 0 (and −444 for
IN-2026-0001 after consumption relief). **The batch side still shows 49,312.76 of stock.**

Note also that JE-2026-0003 posted the **full quantity** (4,800), not an in-stock share — the
`in_stock_ratio` split does not appear until JE-2026-0025 (2026-08-05, FRT-1 era, `line_memo`
`'in-stock share'`). Older entries predate it. Another cutover boundary, inside the same class.

**(C3) Relief fired against a cost that had never been capitalised — +444.00.** PROC-2026-0164
consumed 300 kg of IN-2026-0001 and, because it *was* cost-allocated, credited 1200 by
`300 × 1.48 = 444.00`. **The allocation path is working exactly as designed** — this is the one run
on live that relieves correctly. What makes it a divergence is (C2): the 1.48 basis had never been
debited, so a correct relief drove 1200 to a **credit** balance of −444.00 on a batch still holding
887 kg. Same shape as (C5), different trigger. See (C6) for what happens when relief does *not*
fire.

**(C4) `remaining_qty` exceeds `quantity` — IN-2026-0003 holds 80 against a purchased 50.**
Three stocktakes ran on it (ST-2026-0004 −1, ST-2026-0005 +1, ST-2026-0006 **+30**), all on
2026-07-05, all before the posting path. The batch side values 80 units at 600. This is inside the
48,000 above, but it is a **distinct mechanism** and it is live now — see §2d/M5, where it becomes a
divergence the moment freight touches this batch.

**(C5) Write-off relieved a cost that was never capitalised in — +40,000.00.** IN-2026-0013
(100 kg @ 400, priced 2026-07-05, **no pricing JE**) was deleted 2026-08-17 with reason "Testing".
The delete trigger credited 1200 by `remaining_qty × inbound_batch_landed_unit_cost = 40,000.00`
(JE-2026-0056). **There is no matching debit anywhere in the 18 lines.** The relief is one-sided:
1200 is 40,000 lower than the batch history justifies, and 5200 is 40,000 higher.

This is not a defect in PROC-COST-2 — relieving at landed cost is exactly the correction that cut
made, and it is right. It is the correction meeting cutover-era data that was never capitalised.
**But it is a live property of the relief path worth stating plainly: the write-off trigger does not
check that the cost it is releasing was ever posted in.** On a clean production rebuild this cannot
arise, because every priced batch will have a pricing entry.

**(C6) 1200 carries cost for a batch that no longer exists — −2,041.20.** IN-2026-0152: 405 kg
priced at 5.04 (JE-2026-0025, +2,041.20), fully consumed by PROC-2026-0107 on 2026-08-05.
`remaining_qty` is 0, stage 已加工完. **1200 still holds all 2,041.20**, because
PROC-2026-0107 was committed but never cost-allocated (`allocated_at IS NULL`).

**Measured scope of this mechanism: of 10 non-deleted committed processing runs, only 2 have ever
been allocated** (PROC-2026-0003 and PROC-2026-0164). The other 8 consumed material without ever
relieving 1200. Today only IN-2026-0152 makes it visible in money, because the other 7 runs consumed
batches whose cost was never in 1200 either (C1/C2) — **two errors cancelling**. That cancellation
is arithmetic coincidence, not design, and it will not survive a clean rebuild.

`docs/known-wrong-until-cutover.md` already names two instances of this
(PROC-2026-0106's 200 in the GL and nothing on the batch; PROC-2026-0003's stale allocation), and
FIN-8's "分摊已过期/从未分摊" flag exists to surface it. **What does not exist is anything that
stops a period closing with 8 unallocated runs.** §8 proposes that as the smallest thing worth
adding.

### 2d · EVERY MECHANISM THAT CAN MAKE THE TWO SIDES DIVERGE

Whether or not it has fired. "Current" is the amount on live today.

| # | mechanism | current | what makes it non-zero |
|---|---|---:|---|
| **M1** | **Consumption relieves 1200 only at cost allocation** (C6). A committed run moves stock without touching the ledger until somebody presses allocate. | **−2,041.20**, 8 of 10 committed runs unallocated | Any committed-but-unallocated run consuming a batch whose cost *is* in 1200. Grows with plant activity — **this is the mechanism most likely to dominate once the plant runs.** |
| **M2** | **Two valuation bases coexist.** `/inventory` values at `unit_price`; write-off and stocktake relieve at `inbound_batch_landed_unit_cost`. | **0.00** — freight and processing carriers both read zero (§2a) | The first freight document that posts and is not reversed. Immediate and silent: the screens will show one number, the relief another. |
| **M3** | **`LANDED-DENOM` — the ÷ `quantity` denominator** (`docs/known-issues.md`). Cost capitalised onto a partly-consumed batch under-relieves; the residue strands in 1200. | **0.00** — the only capitalisation on live (123.45) was rolled back | A state-changing run capitalising onto a batch already partly consumed. **Strictly one-directional: it always strands cost in 1200, so the ledger will read *higher* than the batch side.** Fixing it needs a sub-batch identity the carrier tables cannot express — a feature, explicitly not a correction. **A valuation report must name this as a reconciling category, because it will never be zero once the plant runs.** |
| **M4** | **Freight's split posting at document time.** `record_freight_document` splits by `in_stock_ratio` at posting: in-stock share → 1200, consumed share → 5000. The ratio is frozen at that instant. | **0.00** — the one freight doc is reversed | Any freight posted onto a partly-consumed batch. The split is correct *at that moment*; it does not re-derive if the batch is later consumed or repriced. |
| **M5** | **`remaining_qty` can exceed `quantity`** via stocktake gain (C4 — IN-2026-0003 holds 80 of a purchased 50). Landed unit cost divides by `quantity`, then the report multiplies by `remaining_qty`. | Live now, **0.00 in money** — IN-2026-0003 has no freight or processing cost | Any capitalised cost on a batch with a stocktake gain. IN-2026-0003 at 80/50 would over-relieve capitalised cost by **60%**. Note this is the *opposite* direction to M3 and does not cancel it — the two act on different batches. |
| **M6** | **Reprice posts the delta, not the value** (C2). Anchored to whatever 1200 already held. | **+49,312.76** (cutover) | A pricing entry that fails, is reversed and not re-posted, or predates the posting path. Not reachable in normal operation once every receipt posts. |
| **M7** | **Write-off / stocktake relieve without checking the cost was posted in** (C5). | **+40,000.00** (cutover) | Any batch valued but never capitalised. Not reachable once every priced batch posts. |
| **M8** | **Reversed runs and reversed freight are excluded by reader, not by row.** Carrier rows remain physically present; `batch_*_base_all` filter on `deleted_at` / `status`. | **0.00 by design**, and correct — 2 carrier rows excluded | Never, on this path. Recorded because a future reader summing the carrier tables directly (rather than through the `_all` functions) would pick up 3,020.45 of reversed cost. **Any valuation must go through the functions.** |
| **M9** | **Unpriced batches hold quantity with no value** (§2a). | **102,071 kg**, 6 batches | Standing condition. Cannot make the *money* sides disagree — it makes the money side silently incomplete, which is worse, and is why §5 requires "—" not 0.00. |
| **M10** | **1220 is fed only by allocated runs, and relieved only by sales with COGS entries.** | **+253.34** (§4) | An output batch produced and sold without allocation — its cost never enters 1220 and never leaves it. |
| **M11** | **`journal_activity_lines` is one of the five RLS-blind functions** deliberately queued (the brief lists "the layer above `journal_activity_lines`"). `gl_control_reconciliation` reads it. | inherited, unquantified here | An inventory side added to `gl_control_reconciliation` **inherits this**, unchanged. It is not made worse and not fixed. Recorded so the queued fix is known to touch this too. |

---

## 3 · WHAT EACH AUDIENCE NEEDS, MEASURED (STEP 3)

### 3a · R1 — running the business: material, location, ageing

**Slice by material: YES, cleanly.** `inbound_batches.material_id` and `output_batches.material_id`
are both NOT NULL on every live row. `stock_snapshot` and `material_stock_available` already group
this way.

**Slice by location: the dimension exists and is empty.** `location_id` is on
`inventory_movements`, **not on the batch**. Measured:

* `storage_locations`: 4 rows;
* **99 of 106 movements have `location_id IS NULL`** (7 movements carry one, but 6 of those are on
  batches now at zero);
* **exactly one on-hand batch has any location: IN-2026-0258 — 1 kg, unpriced, landed cost NULL.**

**So a by-location valuation today puts 185,703.48 — 100.0% of the value — in "unspecified".**
The dimension is real and correctly modelled; nobody is populating it. Ruling taken (Q7): **ship the
column**, reusing RPT-1's existing grouping and its explanatory note, because a location column that
is correctly empty tells an operator something a suppressed column does not.

**Ageing: computable, with a named hole.**

The date field is `inbound_batches.arrival_date` (`output_batches.output_date` for produced).
**It means what an operator would assume** — it is a business date distinct from row creation:
IN-2026-0001 has `arrival_date` 2026-06-09 against `created_at` 2026-06-07 (batch row raised before
arrival), and ZZ-PROCCOST1-DEMO has arrival 2026-08-30 against created 2026-08-31.

**But it is absent on the batches that hold most of the value.** Of 13 on-hand inbound batches:

| | batches | on-hand value |
|---|---:|---:|
| `arrival_date` present | 9 | 76,734.36 |
| **`arrival_date` NULL** | **4** — IN-0002, IN-0003, IN-0029, IN-0156 | **108,969.12 (58.7%)** |

The alternatives are worse: the first `receipt` movement's `business_date` is NULL on 5 of 13, and
`created_at` is a row timestamp that is demonstrably not the arrival date. Ruling taken (Q4):
**`arrival_date` only, rendering "—" when absent, with `aging_bucket` as the band definition.** An
ageing report where 58.7% of the value sits in a "no date" bucket is an honest and useful finding;
one that invents ages from `created_at` is not.

### 3b · R2 — traceability down to source documents

The path is **complete for inbound and breaks in two named places.**

```
valuation line
  → inbound_batches.code                          ✓ every row
  → purchase_order_id / purchase_order_line_id    ✓ where a PO exists
  → price_history (immutable)                     ✓ every price change, with fx_rate and rate_as_of
  → freight_allocations → freight_documents       ✓ forwarder, status, reversal
  → batch_processing_cost_allocations → processing_runs → processing_cost_entries   ✓
  → journal_entries.source_id → the JE            ✓ for purchase / writeoff / freight / stocktake / allocation
  → inventory_movements                           ✓ complete (see 3c)
```

**Break 1 — reversal entries do not name their source.** Resolving `journal_entries.source_id` for
all 18 lines on 1200: **four fail to resolve, and all four are reversals** (JE-2026-0002, -0004,
-0062, -0074). The original entry names its batch; the reversal does not. Walking *down* from a
batch you will find the original and miss its reversal; walking *up* from a reversal you cannot get
back to the batch without parsing the `memo` text. `gl_control_reconciliation` is immune to this
because it sums both legs by account, but a **line-level drill-down is not**.

**Break 2 — produced batches have no cost lineage of their own.** `output_batches` carries **no
money column at all**. Cost reaches an output batch only via `processing_outputs.unit_cost_base`,
which exists only if the run was allocated — 10 of 12 on-hand output batches have none (§4). For
those, the trail from a finished-goods valuation line to a source document **stops at the batch**.

### 3c · R2's as-at date — "what was inventory worth on 30 June"

**The quantity history is complete. The dates on it are not.**

The good news first, and it is genuinely good: `Σ inventory_movements.qty_delta` equals
`remaining_qty` for **all 16 inbound batches, gap 0.00 on every one** — including
IN-2026-0003 where `remaining_qty` (80) exceeds `quantity` (50), and IN-2026-0180 at 99,970 of
100,000. There is no batch whose position was set by anything other than movements. **Quantity as-at
any date is reconstructable in principle.**

The dates are not:

* **`business_date` is NULL on 31 of 106 movements** (29%), covering 25,785 kg of absolute movement;
* **`business_date`'s minimum is 2026-07-03.** Every movement before that date has none.

So, run today against live:

| "inventory as at 2026-06-30" | Σ qty_delta |
|---|---:|
| filtered on `business_date <= 2026-06-30` | **0.00** |
| filtered on `occurred_at < 2026-07-01` | **7,787.00** |
| unfiltered (today) | 119,304.00 |

**Answering "30 June" today returns a confident, silent zero.** Not an error, not a caveat — a
number an auditor would write down. And `/inventory/reports/ledger` **already filters on
`business_date`** (`ledgerQuery.ts:51-52`), so this hole is already reachable from the UI.

`occurred_at` is NOT NULL on all 106 rows and would "work", but it is a system timestamp, not a
business date — the two already differ on 3 rows, and a backdated receipt would land in the wrong
month, which is the specific error an as-at report exists to prevent.

**Ruling taken (Q5): month-ends only, served from frozen packs. Arbitrary as-at is refused by name
until `business_date` is backfilled and made NOT NULL.** This also happens to be exactly what R3
asks for, so nothing is lost.

**What would be wrong if it shipped anyway:** every month-end before 2026-07-31 reads zero
inventory. The June figure — the one an auditor most plausibly asks for first, being the prior
period-end — would be **0.00 against a real position of 7,787 kg**.

### 3d · Snapshot mechanism

Answered in §1.4: **two exist** (`period_closes`, `management_packs`), plus a third narrower one
(`processing_runs.allocation_snapshot` freezes an allocation basis). A new inventory snapshot table
would be the duplicate dimension the brief warned about. Ruling taken (Q3): **a section inside
`management_packs`.**

---

## 4 · THE PRODUCED SIDE, HONESTLY (STEP 4)

**The premise that this side is empty is false — see §0.** Measured:

| | |
|---|---:|
| Output batches on hand (`remaining_qty > 0`, not deleted) | **12**, 3,816 kg |
| …of which carry **no** `unit_cost_base` at all | **10**, 3,661 kg |
| Produced-side carrying value | **388.20** |
| Ledger 1220 | **134.86** |
| **Difference** | **253.34** |

The 253.34 is **OUT-2026-0007** (95 kg × 2.6667), costed by PROC-2026-0003 on 2026-07-02 — before
the 1220 posting path existed. `docs/known-wrong-until-cutover.md` already carries this row, and
`gl_control_reconciliation`'s header already names its AR twin ("20,350.00 是 OUT-2026-0007 ——
它在明细账里,而总账里**一张分录都没有**"). **One cause, three sides.**

1220's own history is internally consistent: `+944.00` from PROC-2026-0164, `−404.57 × 2` COGS for
two separate 100 kg sales of OUT-2026-0186 (verified against `sales_records` — **two sales, not a
double-post**), leaving 134.86 = OUT-2026-0187's 60 kg × 2.2477. Exactly right.

### What the report should say in this condition

**Not a zero.** This repo has ruled on this shape at least four times — PROC-WIRE-1B-ii's
「不适用」不是「没设」, `aging_bucket` returning NULL rather than `b90_plus` for an
uncomputable age, `management_packs`'s `caveats` naming each absence with its own criterion, and the
pack CSV export which **raises rather than returning an empty file** because "一份【空的 CSV】读起来
像'这个月没有数',那是一句假话".

Applied here, the produced column has **three distinct states that must render differently**:

| state | live example | render |
|---|---|---|
| **worth zero** — costed, and the stock is gone | OUT-2026-0001, sold out | `0.00` |
| **not applicable** — never allocated, so no cost exists to report | OUT-2026-0184, 800 kg | **`—`** + "never allocated" |
| **worth something** — costed and on hand | OUT-2026-0187, 134.86 | the number |

Ruling taken (Q6): **render the real numbers, name the 253.34 as a reconciling difference, and
render the 10 uncosted batches as "—", never as 0.00.** A single "no produced inventory recorded"
banner would be simpler and would contradict 1220 on the report's own face — the report would fail
its primary requirement in order to restate a ruling that is about production, not about the ledger.

**What it should additionally say, because it is the honest reading:** 3,661 kg of the 3,816 kg on
hand has never been costed. The finished-goods total of 388.20 is not a valuation of the produced
stock; it is a valuation of **the 4% of it that a run happened to allocate.** That sentence belongs
on the report, not in this document only.

---

## 5 · PROPOSED SHAPE

**One surface, three sections, serving both audiences — because they disagree about presentation,
not about the number.**

```
INVENTORY VALUATION — as at <month-end> · base currency SGD
Source: frozen pack PACK-2026-07 · month closed 2026-08-05 · not superseded

┌─ SECTION A — RECONCILIATION TO THE GENERAL LEDGER ────────── (R2, auditor)
│  side        control   ledger      sub-ledger   difference   unexplained
│  raw mat.    1200      74,687.92   185,703.48   111,015.56        0.00  ✓
│  finished    1220         134.86      388.20        253.34        0.00  ✓
│  WIP         1210            —           —             —            —   (never posted)
│
│  Named reconciling categories, no catch-all bucket — 1200:
│    never capitalised (pre-cutover)  +23,300.00   (C1)
│    orphaned reprice delta           +49,312.76   (C2)
│    relief without capitalisation    +40,444.00   (C3 + C5)
│    unallocated consumption           −2,041.20   (C6 / M1 — 8 of 10 committed runs)
│    stranded capitalisation                0.00   (M3 — LANDED-DENOM)
│    freight split residue                  0.00   (M4)
│    ─────────────────────────────────────────────
│    accounted for                   +111,015.56
│    UNEXPLAINED                            0.00   ← the only figure that gates "reconciled"
│
│  …and 1220:
│    cost allocated before the 1220 path existed  +253.34  (OUT-2026-0007, M10)
│    UNEXPLAINED                                     0.00
│
├─ SECTION B — BY MATERIAL × LOCATION × STATUS ─────────────── (R1, operations)
│  value at landed cost, qty, and an UNPRICED QTY column beside it
│  location grouping reuses RPT-1; "unspecified" is a normal group (100% today)
│
├─ SECTION C — AGEING ───────────────────────────────────────── (R1, operations)
│  aging_bucket bands: 0-30 / 31-60 / 61-90 / 90+ / NO DATE
│  NO DATE is a rendered band, not a hidden one — 58.7% of value sits there today
│
└─ WHAT THIS REPORT CANNOT SEE ─────────────────────────────── (both)
   · 102,071 kg (88.4% of tonnage) has no price — counted in qty, absent from value
   · 3,661 kg of produced stock was never costed
   · 99 of 106 movements have no location
   · 8 committed processing runs have never been allocated
   · month-ends before 2026-07-31 cannot be reconstructed (business_date floor)
```

Sections A and C both hang off the same landed-cost figure; B is the same figure sliced. **One
definition, three presentations** — which is the property that makes the auditor's total and the
operator's total agree by construction rather than by review.

**Where the evidence does not settle it — two alternatives, stated rather than decided:**

* **A1 — one side or two?** §2b measures 1200 and 1220 as genuinely separate populations
  (inbound batches vs output batches, different sub-ledgers, different failure modes). Presenting a
  single combined "inventory" side would net −253.34 against +111,015.56 and hide M10 entirely.
  **This survey recommends two sides**, matching `gl_control_reconciliation`'s existing per-account
  structure. The counter-argument — that an auditor asks for "inventory", singular — is real, and is
  answered by a total row above two named sides, not by merging them.
* **A0 — market value is deliberately absent from §5.** `/inventory` shows it; the proposed
  valuation surface does not. An auditor's inventory valuation is a **cost** statement; market value
  enters only as the *lower of cost and net realisable value*, which is a write-down judgement
  nobody has ruled on, on a market column that is currently in the wrong currency (§1.1). Putting it
  on the same report would invite exactly the comparison that has not been sanctioned. Recorded so a
  later reader knows it was left out on purpose.
* **A2 — cost basis when the plant runs.** Everything above is **specific identification** by batch,
  which is what the data model expresses and what PROC-COST-2 already posts. PROC-COST-1 §4 flagged
  FIFO/weighted-average as an unanswered question. It remains unanswered, and **it does not need
  answering to build this**: with batch identity preserved end to end, specific identification is
  both correct and the only basis the current model can express. Recording it here so a later reader
  knows it was considered and deferred, not missed. `/inventory` already shows a weighted average
  price per material — that is a *display* aggregate over specifically-identified batches, and does
  not constitute a costing method.

---

## 6 · WHAT CAN BE BUILT NOW

Everything in this list uses machinery that exists and needs no ruling from Tim beyond the seven
already given (§7).

1. **An `inventory` side (or two: `inventory_raw`, `inventory_fg`) on `gl_control_reconciliation`.**
   Ledger side: `journal_activity_lines` filtered to account 1200 / 1220 — identical to the AR/AP
   code path. Sub-ledger side: `Σ remaining_qty × inbound_batch_landed_unit_cost` /
   `Σ remaining_qty × processing_outputs.unit_cost_base`. Named categories per §5, **no catch-all**.
   This is the single highest-value item and it is mostly a `FOREACH` arm.
2. **Value columns on the RPT-1 snapshot report** (`/inventory/reports/snapshot`) — landed cost per
   the ruling, plus an unpriced-quantity column. **Location grouping, CSV and PDF export already
   exist**; this adds columns to a report that already renders and already exports.
3. **An ageing section on the same report**, using `aging_bucket`, with `NO DATE` as a rendered band.
4. **An `inventory_valuation` section in `management_pack_data` + four CSV rows in the pack export**,
   plus `caveats` keys for the five absences in §5. Frozen automatically by the existing
   `freeze_management_pack`; refused for open months by the existing CHECK.
5. **Point `/inventory` and `lib/valuation.ts` at `inbound_batch_landed_unit_cost`** and retire
   `AGING_BANDS` in favour of `aging_bucket`. Closes M2 before it can fire and removes the second
   ageing definition. **Changes no number on live today** (§2a fact 1) — which is exactly why it
   should be done now rather than after freight posts.
6. **Fix the market-value currency** (§1.1) — `marketValuePerKg()` returns USD/kg and both consumers
   label it SGD. **This one changes a live number and is a correction in its own right**, not part
   of a valuation build; it is listed here only because §6 item 5 touches the same module and
   because no valuation report should reuse `lib/valuation.ts` until it is done. It should be sized
   and cut separately.
7. **Correct the two `USD/kg` type comments in `lib/valuation.ts`** (§1.1). No behaviour.

---

## 7 · RULINGS TAKEN IN THIS SURVEY (grilling, 2026-08-31)

| # | question | ruling |
|---|---|---|
| Q1 | Equal, or fully explained? | **Named reconciling differences with a zero-`unexplained` gate.** Copy `gl_control_reconciliation` exactly. |
| Q2 | `unit_price` or landed cost? | **Landed cost**, and `/inventory` changes to match. One definition. |
| Q3 | Where does the snapshot live? | **A section inside `management_packs`.** No second snapshot dimension. |
| Q4 | Ageing base date? | **`arrival_date` only, "—" when absent.** `aging_bucket` is the single band definition. |
| Q5 | Arbitrary as-at? | **Month-ends only, from frozen packs.** Arbitrary as-at refused by name until `business_date` is backfilled. |
| Q6 | Finished-goods rendering? | **Real numbers, 253.34 named, uncosted batches as "—".** Zero and not-applicable never render alike. |
| Q7 | Location dimension? | **Ship it**, reusing RPT-1's grouping and note. Correct-and-empty is information. |

---

## 8 · RECOMMENDED BUILD SIZE — **BUILD A SMALLER THING NOW**

**Not an inventory valuation report. A reconciliation side and some columns.**

The brief allowed "BUILD A SMALLER THING NOW" as a conclusion, and the measurement argues for it
harder than expected — but for the opposite reason to the one anticipated. The brief expected the
answer to be "too little exists". **The answer is that too much exists**: a valuation module with
ageing, a location report with CSV and PDF, a control-account reconciliation with an as-at date and
a no-catch-all rule, a month-end close with a duplicate guard, and a frozen monthly pack that
refuses open months. A new report would be the **fourth** inventory surface and the **third** ageing
definition.

**The reasons, in the order they carry weight:**

1. **The reconciliation is where the value is, and it is nearly free.** §1.3 measures a function that
   already does everything R2 asks, whose own header already names the same five cutover batches that
   drive 111,015.56 of the inventory divergence. Adding a side is a `FOREACH` arm, not a design.
2. **The 111,015.56 is entirely cutover-era and will not exist in production.** All seven causes (C1,
   C2, C3, C4, C5, C6, plus OUT-2026-0007) are either pre-2026-07-06 data or the unallocated-run gap.
   **Building a large reconstruction machine to explain a difference that a clean rebuild deletes
   would be building against the test database.**
3. **The mechanism that *will* matter is M1, and it is not a reporting problem.** Once the plant
   runs, 1200 will drift by every committed-but-unallocated run. No report fixes that. The smallest
   real fix is a close-time gate — see below.
4. **Two ruled-out dimensions are ruled out by measurement, not opinion.** Arbitrary as-at is unsafe
   until `business_date` is backfilled (3c). Location is correctly modelled and empty (3a). Neither
   is a design question any more.
5. **Nothing here is blocked on the plant running.** The reconciliation, the columns, the ageing, the
   pack section and the M2 closure are all buildable and testable against today's live data — which
   is unusual for this repo and argues for doing it now rather than waiting.

**The one addition worth making beyond reporting:** `close_period` already refuses on four named
conditions (`NOT_MONTH_END`, `ALREADY_CLOSED`, `DEPRECIATION_OUTSTANDING`,
`TRIAL_BALANCE_UNBALANCED`). **A fifth — refuse, or at minimum warn by name, while committed runs
remain unallocated** — would stop M1 at the only moment anybody is looking. It is the same shape as
the depreciation gate, in the same function, and it is the difference between a report that
*discovers* the drift each month and a close that *prevents* it. This survey recommends it be scoped
with the build above; it is not part of the reporting work and should not be smuggled in silently.

---

## 9 · WHAT STAYS BLOCKED, AND ON WHAT

| blocked on | what |
|---|---|
| **A ruling from Tim** | Whether `close_period` should **refuse** or merely **warn** on unallocated runs (§8). Refusing is stricter than any existing inventory gate and would have blocked the 2026-07-31 close. |
| **A ruling from Tim** | Whether the report presents **one inventory side or two** (§5, A1). Recommended: two, with a total row. |
| **A month-end process** | Nothing. **This was expected to be a blocker and is not** — `close_period` + `management_packs` + `freeze_management_pack` already provide trigger, owner, duplicate guard and immutability (§1.4). |
| **A data backfill** | Arbitrary as-at dates, until `inventory_movements.business_date` is backfilled and made NOT NULL (§3c). Month-end reporting is **not** blocked on this, because the first frozen pack post-dates the `business_date` floor. |
| **Operations, not code** | Any meaningful by-location valuation (§3a — 99 of 106 movements carry no location) and any meaningful ageing on 58.7% of the value (§3a — 4 on-hand batches have no `arrival_date`). The columns ship; they will read "unspecified" and "no date" until somebody records them. |
| **A plant that has not run** | Nothing about *building* this. Only its usefulness: with 3,661 of 3,816 kg of produced stock never costed and every freight/processing carrier reversed (§2a), the finished-goods and capitalisation columns will be structurally correct and substantively empty until there is real production. |
| **A feature, explicitly not a correction** | `LANDED-DENOM` (M3). Needs sub-batch identity the carrier tables cannot express. Currently zero; **will not stay zero once the plant runs**, which is why §5 lists it as a named reconciling category from day one rather than adding it later. |
