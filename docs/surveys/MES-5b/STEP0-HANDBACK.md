# MES-5b Step 0 — hand-back (2026-10-08), with the MES-5a-2 close-out rulings

**STOP GATE.** No code edit, no migration, no live write. The only writes are docs:
- the close-out (`76e59c84`, "MES-5a-2 close-out");
- the close-out rulings (`a4647cdd`, "MES-5a-2 close-out rulings": `docs/role-matrix.md`, `docs/forward-queue.md`, `docs/surveys/MES-5b/ruling-f-readings.sql`);
- this file and the read-only query files beside it (`live-readings.sql`, `cost-entry-grants.sql`, `action-view-readings.sql`).

Waiting on Tim's answers to Q1–Q37 (§14).

**Opening check.** First command **2026-10-08 18:58:30 CST**. Tree clean. `HEAD` = `origin/main` = `git ls-remote origin main` =
`76e59c844544347f0bc444dc94590fec35c03c37`. Files staged by explicit path only.

**Live readings (measured, read-only).** All ran as `postgres` (`rolbypassrls = true`) over direct psql to the pooler, inside `BEGIN READ ONLY … ROLLBACK`, on base tables or the catalog:
- `ruling-f-readings.sql` at 18:58 CST;
- `live-readings.sql` at 19:03;
- `cost-entry-grants.sql` at about 19:08;
- `action-view-readings.sql` at 19:11.

All returned `READ_OWN_EXIT=0`. Standing state: 7 accounts, 0 disabled · approvals ON · `require_calibrated_since` NULL.

**How the facts were gathered.** Five read-only sub-agents covered five areas:
- the balance / yield / blending data model;
- the F1 / F2 code paths;
- everything earlier records left to MES-5b;
- the action-code → page-gate mapping;
- cut durations from the eight MES build transcripts.

None of them connected to a database or ran a build. I read the following in full:
- AGENTS.md;
- the specification PDF (pypdf, 11 pages);
- MES-0 §0–§9 for the production, balance and cut-plan parts, and its §12;
- the MES-5a Step 0, the MES-5a-1, MES-5a-2 and MES-4a hand-backs;
- `docs/mes-pending-values.md`;
- `relieve_processing_accruals`, `post_electricity_allocation`, fixture 256 and fixture 100's arm 5;
- `docs/processing-support-as-built.md` §1.6–§2.

`docs/forward-queue.md` and `docs/known-issues.md` are about 780 KB each. I read their MES items, the MES group table and the MES-5a-2 section in full; a sub-agent grepped both whole files for balance, yield, blending, relief and reversal terms. Every load-bearing claim below was re-read at its file:line or measured.

Tags: **[M]** measured · **[I]** inferred from code reading · **[Q]** quoted from an earlier record · **[S]** from the specification.

---

## §0 · The f check — role by role (close-out ruling f, step 1)

**Rule (Tim, 2026-10-08, option A):** every action code is granted together with the view code of the page where that action is used; pages are not widened.

**1 · The MES-5a-2 pages, as the ruling asked** [M, `ruling-f-readings.sql`, 18:58 CST]. Seven roles have a live holder. There are 16 role × code pairs, and **all 16 hold the page's view code; 0 are missing.**

| role (live holder) | action / edit codes held on the MES-5a-2 pages | page gate | holds it |
|---|---|---|---|
| admin (admin@) | `action.manage_devices`, `action.confirm_capture` | `module.processing.view` (`/operation/devices/[id]`) | ✓ ✓ |
| | `action.processing_commit`, `_rollback`, `_aftercare`, `module.processing.edit` | `module.processing.view` (`/operation/processing/[id]`) | ✓ ✓ ✓ ✓ |
| | `module.finance.edit` | `module.finance.view` (`/finance/electricity`) | ✓ |
| cco (sandra@) | `module.processing.edit` | `module.processing.view` | ✓ |
| cfo (tim@) | — none of these codes | — | n/a |
| cto (phua@) | `action.manage_devices`, `action.confirm_capture`, `module.processing.edit` | `module.processing.view` | ✓ ✓ ✓ |
| finance (chooer@) | `module.finance.edit` | `module.finance.view` | ✓ |
| gm (vince@) | — none | — | n/a |
| warehouse (fusheng@) | `action.confirm_capture`, `action.processing_commit`, `_rollback`, `_aftercare` | `module.processing.view` | ✓ ✓ ✓ ✓ |

Result: option A recorded as a standing rule in `docs/role-matrix.md`, and the automated check folded into MES-5b (`a4647cdd`). Step 2 went ahead.

**2 · Every action code, measured afterwards for the design of that check** [M, `action-view-readings.sql`, 19:11 CST].
- Coverage: 33 of the 34 action codes, mapped to the gates of every page that uses them (sub-agent static scan, §1 item 5). `action.anonymise_employee` has no screen.
- Reading: "the role can enter at least one page that uses the code".
- Result: **67 role × code pairs, 67 satisfied, 0 violations** on live.

---

## §1 · What grilling changed in MES-5b's scope

1. **F2's premise is false** [M + I].
   - Month-end relief **does not delete** the estimates it relieves. `relieve_processing_accruals` only stamps `relieved_at` and `relief_expense_id` (`relieve_processing_accruals.sql:109-111`); its own journal clears 2200 (`:75-77`).
   - Live: the one relieved estimate (electricity, 200.00, relief `EXP-2026-0005`, posted) has `deleted = false`.
   - What actually goes wrong after `reverse_expense` on a relief:
     - the ledger is right (2200 is back);
     - but the estimates stay stamped "settled" against a reversed document;
     - they vanish from the month-end accrual step and the settle page;
     - they can never be relieved again (`COST_ENTRY_ALREADY_SETTLED`, `:56-57`);
     - `processing_cost_variance` still reports the reversed relief.
   - So F2 is "clear the stamps in the same transaction", not "un-delete".
   - `docs/known-issues.md:10518-10520` (`MES5A2-RELIEF-REVERSAL-ORPHANS`) states the wrong mechanism (§12).
2. **F1 is three undo paths, not one** [I, code read]. Undoing an allocation means all of the following:
   - reverse the allocation journal (Dr 2200 / Dr 6200 / Cr 2000 or bank);
   - un-settle, then soft-delete, each per-run actual line. The trigger posts Dr 2200 / Cr 5110 (`finance_journal_triggers.sql:66-75`);
   - un-stamp and un-delete each relieved estimate. **Un-deleting posts no journal** (`:77-98`), so the re-accrual Dr 5110 / Cr 2200 must be posted explicitly;
   - record the reversal. Both allocation tables are append-only with **no bypass** (`guard_append_only_log.sql:13-15`), so this needs a new record.
   - **Three things block re-posting a corrected bill after the reversal:**
     - `electricity_allocation_lines.run_id UNIQUE` (`electricity_allocation_lines.sql:18`);
     - the compute's unfiltered "already allocated" check (`electricity_allocation_compute.sql:187,197-201`);
     - the unfiltered "period overlaps" check (`:117-123`).
3. **A side door onto the settlement stamps exists today** [M grant + I].
   - `authenticated` holds UPDATE on `processing_cost_entries.relieved_at` and `remitted_at` (live `has_column_privilege` = true). The UPDATE policy is `module.processing.edit` (admin · cco · cto).
   - `guard_cost_entry_settled` does **not** watch the four stamp columns (`processing_cost_entries.sql:51-62`).
   - So a processing editor can, by a direct PATCH, clear a settlement that finance made.
   - F1 and F2 clear exactly those stamps, so the door should close in the same cut (Q26). Not executed, by design.
4. **`reverse_expense` does not refuse a settled expense** [I].
   - There is no check like `FREIGHT_HAS_SETTLEMENT`.
   - Payment allocations stay in place, ledger 2000 goes debit while the AP list reads 0, and the difference lands in `unexplained` (`list_ledger_reconciliation.sql:113-140`).
   - An unpaid relief or allocation expense paid through a payment request is exactly this case (Q24).
5. **"Its page's view code" is not one code for many action codes** [M, static scan].
   - 15 codes are used on pages with different gates (11 action codes, 4 edit codes). Examples:
     - `action.confirm_capture`: processing view, or inbound / logistics view on the weighbridge pages;
     - `action.processing_commit`: inbound, processing and output view;
     - `module.finance.edit`: seven different gates.
   - Reading it as "all of them" would collide with standing rulings. Warehouse must not hold `module.sales.view` (APR-5b), yet `action.ship_goods` appears on `/sales/orders/[id]`.
   - So the check needs a declared meaning (Q30).
   - **The bootstrap seed already breaks the rule** [M, mirror read]. The bootstrap admin holds `action.manage_devices` and `action.confirm_capture` without `module.processing.view` (`role_permissions.sql:69-77`). The bootstrap finance role holds `action.wo_release` without it (`:126`). A fresh install would fail the check on day one (Q31).
6. **Pass-through mass must not be counted as consumption** [I + M].
   - Deep discharge records its input as throughput, with no stock effect for an inbound batch, and output = input (`commit_processing_run.sql:396-402,430-457`).
   - The quarantine split is a transforming run with output = input (`split_failed_modules_to_quarantine.sql:97-106`).
   - `/inventory`'s lifetime "material balance", `cod_delivery_completion` and `work_order_fulfilment` sum every input leg regardless of operation kind. So today they count discharge throughput as consumption.
   - The new balance must count only `operation_kinds.consumes_input` runs, and treat the split as a mass transfer (Q3, Q12).
7. **Quarantine-split runs sit "open" forever** [I, `processing_run_balance_all.sql:45-51`].
   - The split is transforming with a start time, so its balance is `open` until someone closes it by hand. Its remainder is 0 by construction.
   - It also feeds the `processing_balance_unclosed` reminder and the month-end warning.
   - The V1 arm lists the split operation as needing a tolerance it can never use (`pending_values.sql:198-206`) (Q11).
8. **There is no forward lineage, and the upward lineage cannot be summed** [I].
   - `batch_lineage_all` walks only upward.
   - It repeats each input leg's **whole** `quantity_consumed` on every output of a multi-output run (`batch_lineage_all.sql:19-58`).
   - The per-inbound balance therefore needs its own forward, proportional attribution (Q4).
9. **The specification defines powder yield and says nothing about blending** [S].
   - §3.5 defines "powder mass produced per unit mass of electrode sheet". `electrode_powder_line`'s inputs are cathode sheet, anode sheet and electrode scrap (`operation_type_input_forms.sql:22-24`), so its total input *is* that denominator, and the MES group's `total_input` basis (MES-5a Q23) agrees with it.
   - Blending appears only in MES-0's function list (function 12) and Q58 (Q16).
10. **Live has nothing to exercise the new reports with** [M].
    - All 14 runs predate MES-4a (`started_at` NULL): 10 committed, 4 reversed; 13 have no operation.
    - There are 0 closures, 0 loss rows, 0 contract grade specs and 0 allocations. Only 2 of 5 live materials carry a chemistry.
    - Every figure MES-5b shows on live today is a pre-MES-4a figure. The proofs must bring their own data, as before.
11. **Size.** Balance + yield, the finance reversals and blending are three proof shapes:
    - a read-side report;
    - a GL reversal with the AP = ledger proof;
    - a plan plus the run engine.

    Together they come to about 1.6× the largest measured MES cut even at the measured pace. Recommendation: **three cuts** (Q2).

---

## §2 · (a) Exactly what MES-5b contains

MES-0 §8.2 row 8 [Q, `docs/surveys/MES-0/README.md:702`] gives:
- functions 9, 10 and 12;
- "per-inbound-batch and monthly balance views; yield views; `blending_plans`, `blending_plan_lines`, blending operation";
- size 3.5 tables / 5 pages.

Earlier records add:
- spec 3.5a powder yield (MES-0 `:238`; MES-4b Step 0 `:92-93`);
- the computed regulatory balance, frozen later by MES-8b (MES-0 Q82 `:1056`);
- Tim's fold-ins F1, F2, b and f (`docs/forward-queue.md`, MES row 8).

Proposed contents, by recommended cut:

**MES-5b-1 · Balance and yield (+ the f check)**
- **Views:**
  - `inbound_batch_balance_all` (owner, revoked) + gated reader: the forward, proportional tree per inbound batch (Q4, Q5);
  - `processing_balance_monthly` (plant-wide and per operation, Q8);
  - `processing_yield_all` + reader (per run × output form, per operation × period, Q13–Q14);
  - a stock roll-forward per month from `inventory_movements` (Q8).
- **No new table**, unless V37 (Q15) needs a column: `operation_type_output_forms.expected_yield_pct`.
- **Changed:**
  - `split_failed_modules_to_quarantine` closes its own run's balance, and the split operation is seeded tolerance 0 (Q11);
  - `/inventory`'s lifetime block reads the new view (Q12);
  - the V1 arm stops listing the split operation (by Q11's tolerance 0);
  - V37 arm (Q15);
  - the f check: `permissions.requires_view_any`, the `set_role_permissions` guard, the bootstrap self-check, the seed fixes and a build check (Q30, Q31).
- **Pages:**
  - new `/operation/balance` (monthly, per operation, roll-forward);
  - new `/operation/yield`;
  - a balance panel on `/inbound/[id]/edit` and `/output/[id]/edit`;
  - a link from the month-end step (Q9).

**MES-5b-2 · Reversals (F1, F2 + the b arm)**
- **New table:** `electricity_allocation_reversals` (append-only; one per allocation; reason required).
- **Functions:**
  - new `reverse_electricity_allocation` (Q22);
  - `reverse_expense` gains the relief restore (F2, Q21) and the settled refusal (Q24), and its allocation refusal names the allocation page;
  - `electricity_allocation_compute` ignores reversed allocations (Q23); `run_id UNIQUE` is replaced by a guard (Q23);
  - `guard_cost_entry_settled` watches the stamps (Q26);
  - `post_electricity_allocation` also asks `module.finance.view` (Q28);
  - `relieve_processing_accruals` reads the base currency from data (Q35 of MES-5a, triggered because this cut touches the file);
  - `processing_cost_variance` excludes reversed reliefs.
- **Pages:**
  - a "Reverse this allocation" control with a reason on `/finance/electricity/[id]`;
  - `/finance/expenses/[id]` copy for the relief restore.
- **Fixtures:** 256 gains the paid arm (b); a new reversal fixture.

**MES-5b-3 · Blending**
- **New tables:**
  - `blending_plans` (code `BLD-`);
  - `blending_plan_targets` (metal, min, max);
  - `blending_plan_lines` (batch, planned kg).
- **Operation and functions:**
  - operation `blending` (transforming, started from the plan page);
  - create / edit / release / cancel / execute (execute is a wrapper over `commit_processing_run`, the split precedent);
  - a predicted-composition view.
- **Pages:** `/operation/blending`, `/new`, `/[id]`.
- **Registries:** `BLD` prefix in `document_types`, generator, search registry and fixture 100 (Q17–Q20).

**Left to later cuts** [Q]:
- freezing and filing the regulatory balance, the NEA return (V26) and EU recycling efficiency (V27) → MES-8b (MES-0 Q82);
- profit per inbound batch with its own attribution rule (by the run's `allocation_basis`, not by mass) → MES-8b (Q80);
- re-mapping loss categories to NEA cells → when the NEA report format arrives (`docs/proc-loss-and-saleability.md:139-141`);
- the disposal leg (G10, U6);
- heel quantity (G9) and un-weighed recycle streams (G13) → wait on U5, the line (`docs/proc-operations-wired.md:268-272`, Tim R7: heel is inventory);
- chemistry certainty on outputs (N38) → the assay cut;
- a sales-side grade-breach view (Q20);
- scheduling (MES-0 Q2).

## §3 · (b) The per-batch balance

**Source of truth.**
- Legs are `processing_inputs.quantity_consumed` and `processing_outputs.quantity_produced`, kg in practice. Outputs are refused unless kg (`OUTPUT_UNIT_NOT_KG`, `commit_processing_run.sql:317-319`). Inputs are **not** checked at commit (Q10).
- Named losses are the current end of each correction chain in `processing_run_losses`, with basis `measured` / `derived` (MES-4b).
- The remainder is `total_input − total_output − named` (`processing_run_balance_all.sql:33`).
- Batch stock comes from `inventory_movements` (`remaining_qty = Σ qty_delta`, `inventory_movements.sql:2-5`).

**How an inbound batch reads** (Q4, Q5):

```
IN-2026-0xxx  received 1,000 kg
├─ on hand ........................... 120
├─ sold / written off / adjusted ..... from movements
└─ consumed by processing ............ 880   (consuming runs only; deep discharge throughput shown apart, not consumed)
    ├─ PROC-… manual_disassembly (this batch = 100 % of the run's input)
    │   ├─ CEL-… cells 600 ──▶ fed to PROC-… electrode_separation (share 600/600) ─▶ …
    │   ├─ STR-… structural 200 ──▶ on hand 200
    │   ├─ named losses: sweepings 10 (measured) …
    │   └─ remainder 70 · closed with an explanation | open | before closure (pre-MES-4a)
    └─ PROC-… (a multi-input run: this batch 880 of 1,760 kg → 50 % of every output, loss and remainder)
```

**Rules (MES-0 Q59, made exact):**
- Each consuming run's outputs, named losses and remainder are attributed to its input legs **in proportion to `quantity_consumed`**.
- An output batch fed onward carries its attributed share into the next run, recursively.
- Shares are exact numerics, rounded only on screen, so every node adds up.

**A batch across several runs.** Each run is one branch with its own share. Live: one inbound batch feeds 7 runs, six feed one each [M].

**A quarantine split** (MES-5a-1). It reads as a **transfer**:
- "split out to quarantine → OUT-… 90 kg";
- the child batch carries the share onward as if it were the parent's own mass;
- no loss and no remainder (Q3, Q11).

**Deep discharge.** It shows as an event line on the batch ("discharged and verified by PROC-…"), not as consumption.

**Reversed runs.** They are listed apart with their kg and status, never summed. A run with `corrects_run_id` links to the run it replaces (Q7).

**Pre-MES-4a runs.** They are included in the mass. Their loss shows as **"loss recorded before named losses existed"**, which is unexplained and never named, and their state is `before_closure` (Q6). Live: all 14.

## §4 · (c) The monthly balance

**What it sums** (Q8). By `process_date` month (MES-0 Q59; MES-5a-2 decision 5 used the same):

| line | source |
|---|---|
| input to consuming runs | Σ `total_input`, per operation and plant-wide |
| outputs by form | Σ legs |
| named losses by category × basis (measured / derived) | current loss rows |
| remainder | split by state: closed within tolerance · closed with an explanation · open · before closure (pre-MES-4a) |
| pass-through (not consumption) | deep discharge throughput, quarantine splits — shown apart |
| reversed runs | count and kg, listed, not summed |

A second block is the **stock roll-forward** of the month from `inventory_movements` by `business_date`: opening, receipts, produced, consumed, sold, written off, adjustments, transfers net 0, closing. It carries **no "ties" flag**: closing equals Σ movements by construction, and a flag whose two sides cannot move apart is decoration (AGENTS.md).

**Month-end** (Q9).
- The existing step "Material balances closed" (MES-4a, `app/finance/month-end/page.tsx:201-207`) stays a warning; it never blocks (MES-0 Q48).
- It gains a link to the month's balance page.
- MES-5b freezes nothing. A back-dated run entered later changes a past month's figure, and the page says "live figures, not frozen". Freezing is MES-8b's compliance pack (Q82).

**Live today** [M]:
- months 2026-06 (3 runs), 2026-07 (1), 2026-08 (10);
- the 10 committed runs in 5,242 kg, out 4,193, loss 1,049 — all pre-MES-4a, so all of that 1,049 is "recorded before named losses existed".

## §5 · (d) Yield

**Per run** (Q13):
- per output leg: `quantity_produced ÷ total_input`;
- total mass yield: `total_output ÷ total_input`;
- named loss % by category, remainder %.

**Basis** is total input (MES-5a Q23, ruled, built in `processing_run_energy`). For `electrode_powder_line` that is exactly the specification's "powder per unit of electrode sheet" [S §3.5]. Cathode powder and anode powder show as separate lines.

**How the categories count:**
- collected dust is an **output** (MES-4b), not a loss;
- `equipment_holdup` and `sweepings` are named losses marked recoverable (`loss_categories.is_true_loss = false`, metal "stays", `loss_categories.sql:75-80`).

**Per operation and per period:** Σ output by form ÷ Σ input of that operation's consuming runs in the period. Reversed runs are excluded; pass-through operations have no yield; pre-MES-4a runs are included and labelled.

**Groupings** (Q14): operation · month · output form · machine · chemistry (with the "chemistry not recorded" group, MES-0 Q60) · supplier (through Q4's attribution to the inbound batch; the supplier name follows the batch's own read code, Q32).

**Metal yield** stays `processing_metal_recovery`, linked, not recomputed.

**Targets** (Q15). Recommend **V37 "expected mass yield (%) per operation × output form"**: Not yet set; flags only, never refuses; its arm appears only for operations with at least one MES-4a-era committed run. The repo's record says standard recovery waits on real runs (`docs/forward-queue.md:709,2383-2385`) and Tim ruled yield an estimate, not an auditable KPI (`docs/proc-reality.md:517`). So nothing guesses a number, and the alternative is no target at all. `work_order_expected_outputs` (per work order, with `basis`) stays the per-plan expectation; it is not a standard.

## §6 · (e) Blending

**What a blend is here** (Q16). Combining saleable powder batches of different metal content (black mass, cathode powder…) into one output batch, so that it meets an offtake contract's grade.
- The specification does not mention it [S]. MES-0 function 12 and Q58 do [Q].
- Today the only shape is an ordinary N-in-1-out run. There is no plan, target or prediction (`grep blend|配料` → 0).
- Live: 0 contract grade specs; metal content on 4 output batches and 7 inbound batches [M]. **Whether the plant blends at all is Tim's fact.**

**How it is recorded** (Q17–Q19; MES-0 Q58, accepted):
- **A plan:** output material; target bounds per metal, either copied from a contract's grade spec (min / max, the CONTRACT-1 U8 ruling: bounds, not target ± tolerance) or entered; candidate batches with planned kg.
- **The prediction:** the mass-weighted mean of each candidate's current metal content, with its source (assay or manual). It is "not measured" for any metal that a line lacks.
- **Release:** like a work order — `action.wo_create` creates, `action.wo_release` releases, and the creator never releases.
- **Execution:** a transforming `blending` run through an execute wrapper over `commit_processing_run` (the MES-5a-1 split precedent: no signature change). Actual kg may differ from the plan and the difference is shown.

**Relation to batches, the engine and saleability:**
- Inputs are batches like any run's; lineage, balance, cost allocation and rollback are reused unchanged.
- The output material must be of a `may_be_sold` form (Q20).
- The output batch's metal content is **not** written from the prediction; an assay sets it.

**Specification requirement:** none beyond the general balance rule (§4.1). Every blend limit (share caps, moisture) would be a Not-yet-set value; none is proposed, because the bounds come from the contract (Q20).

## §7 · (f) F1 and F2

**Today's paths** [I, sub-agent map with file:line; spot-checked]:

`reverse_expense` (`module.finance.edit`, `reverse_expense.sql:44`):
- **approvals:** none (role-matrix: expenses unapproved; `approvals.md:1666-1668`);
- **dates:** mirror expense dated today; journal reversed on `reversal_date_for` = `GREATEST(CURRENT_DATE, original)`, so in practice today; period lock enforced on that date;
- **refusals:** an allocation's expense, by name (`:59-61`);
- **reliefs:** a relief expense reverses like any other, with nothing done to its estimates;
- **settled expenses:** not refused.

`relieve_processing_accruals` (`module.finance.edit`):
- journal on the expense date: Dr 2200 accrued, variance to 5xxx, Cr bank / 2000;
- stamps only (`:109-111`);
- the expense row carries the `'SGD', 1` literal (`:105`).

`post_electricity_allocation` (`module.finance.edit`):
- one expense and a journal on the bill date;
- per run, an actual line inserted already remitted, whose insert trigger posts Dr 5110 / Cr 2200 dated **today**;
- covered estimates stamped **and** soft-deleted, whose trigger posts Dr 2200 / Cr 5110 dated today.

**What restoring involves:**
- **F2** — clear `relieved_at` and `relief_expense_id` on the relief's estimates, in the same transaction as `reverse_expense`.
  - No journal is needed: the reversed relief journal already returns 2200.
  - The guard allows it (it watches amount, `deleted_at`, type and estimate flag only).
  - Exception to refuse by name: an electricity estimate whose run has since gained an allocation line. Restoring it would leave the run with an estimate and an actual (MES-5a Q24) (Q21).
- **F1** — in one transaction, under one reversal date:
  1. reverse the expense and journal (`reverse_expense` internals);
  2. per actual line, clear `remitted_*`, then soft-delete it (trigger: Dr 2200 / Cr 5110);
  3. per relieved estimate, clear the stamps, un-delete it, and post Dr 5110 / Cr 2200 explicitly (two statements: the guard refuses doing both at once);
  4. write one `electricity_allocation_reversals` row.
  - The net effect returns 2200, 5110, 6200 and 2000 / bank to their pre-allocation balances (Q22).

**Permissions:** `module.finance.edit` (admin · finance live), the same as post, relieve and reverse. No approval (Q25).

**Ledger proof:** in fixtures and a rolled-back live proof, for each of unpaid and paid:
- post → reverse → AP list = ledger, `unexplained` 0.00 on both sides;
- the four accounts' movements net to zero;
- the reversed expense and its mirror leave `ap_open_items`;
- a corrected bill for the same period posts again (Q23).

Fixtures today prove list = ledger only after posting or relieving, never after reversing (213 A10 reverses an unsettled ordinary expense; 213 A20 and 256 ALLOC do not reverse).

## §8 · (g) Effect on MES-4a closure, MES-5a energy and the fixtures

- **Closure:**
  - `processing_run_balance_all` and `close_run_balance` are unchanged; the new views read them;
  - the split closes its own run (Q11) — the one behaviour change;
  - the month-end warning and the reminder stop listing split runs.
- **Energy:**
  - F1 adds a reversed state to allocations; the compute and the "run already allocated" rule ignore reversed ones;
  - `processing_run_energy` today shows reversed runs (no status filter, `processing_run_energy.sql:50`). The yield view filters them; the energy view is left as it is, because its readers show one run (§12 item 8);
  - per-tonne stays on total input.
- **Fixtures** (no assertion removed, every new arm fault-injected):

| fixture | change |
|---|---|
| 256 | gains the paid arm (b); its REV arm keeps `EXPENSE_IS_ELECTRICITY_ALLOCATION` (the refusal stays, with a route) |
| 213 | gains a relief-reversal arm (F2) |
| 255 SPLIT | gains "the split's own balance is closed" |
| 253 | unchanged (its MONTH arm predates the split; 255 SPLIT asserts the split is absent from the warning) |
| 100 | 32 → 33 functions and 55 → 56 prefixes if `BLD` mints by year (Q17) |
| `check-search-registry` | `EXPECTED_ROWS` +1 |
| `check-document-registry` | tables +3 / +1 |
| 111 | arm count only if a reminder arm is added (none proposed) |
| 235 | stays 8 |

- **New fixtures:** 257 (balance and yield), 258 (reversals), 259 (blending), plus the f check's own fixture arm.

## §9 · (h) Approvals, trails, change log, masking

- **Approvals.** None new (MES-0 §4.1; the house test, `docs/approvals.md:1090-1111`).
  - Reports are reads.
  - Reversals follow `reverse_expense` (no approval today).
  - A blending plan's release is a work-order-style four-eyes step (creator ≠ releaser), not an approval document.
  - Approvals ON / finance / cfo / 1,000 are unchanged.
- **Change log.** Every new table bound (`gen_change_log_bindings.py --only`); no exclusion (235 stays 8). Stamp clears on `processing_cost_entries` are captured by its existing trigger. `processing_cost_entry_history` logs nothing for a stamp-only change (`log_cost_entry_change.sql:26`); the change log carries it (Q27).
- **Trails.**
  - `electricity_allocation_reversals` → the `electricity_allocation` subject (home) and each run;
  - `blending_plans` and their lines and targets → a new subject `blending_plan` (MES-0 §4.3 named it);
  - a blending run → `processing_run` as usual;
  - one wording arm per cut with its own fault (㉓ …).
- **Masking.** Balance, yield and blending are **mass and metal %, not money**, so there are no new masked columns.
  - The allocation reversal's amounts sit behind `data.view_prices`, like the allocation's (the three-change rule in one migration; mask rules +n).
  - The supplier name on yield-by-supplier follows the inbound batch's read code (`module.inbound.view`); without it the group reads "restricted", not missing (AGENTS.md decision 3; `lib/permissions.ts`).

## §10 · (i) "Not yet set" values MES-5b adds

| # | value | lives on | page | arm reads | permission | supplied by | when |
|---|---|---|---|---|---|---|---|
| V37 (if Q15 = yes) | Expected mass yield (%) per operation × output form — flags a run, operation or month below it; never refuses | `operation_type_output_forms.expected_yield_pct` | `/operation/operation-types/<code>` | each active output form of an operation that has ≥ 1 MES-4a-era committed run, with the value empty | `module.processing.view` | Tim with the process engineer, from commissioning runs | after the first real runs of each operation |

**Blending adds none.** Bounds come from contracts or are entered per plan, and no blend limit has been asked for. V1 is untouched except that the split operation stops appearing (Q11).

## §11 · (j) Migration shape, window, and (k) the time estimate

**Shape: one migration per cut**, dated from `date`.
- **5b-1:** views and readers; the split change (CREATE OR REPLACE, same signature) and the operation's tolerance 0; V37 column (`operation_type_output_forms`, RUNTIME CONFIG — bootstrap stays NULL, which is correct); `permissions.requires_view_any` (SEED table: mirror and live move together); the `set_role_permissions` guard; bootstrap seed and self-check; the pending-values arm.
- **5b-2:** the reversals table (masked amounts); `reverse_expense`, `electricity_allocation_compute`, `post_electricity_allocation`, `relieve_processing_accruals` (all CREATE OR REPLACE, signatures unchanged; the new function separate); drop `run_id UNIQUE` and add the guard; the settlement-guard function; the variance view.
- **5b-3:** three tables, the `blending` operation and its form rows, the `BLD` prefix row and generator, functions, the view, the trail subject.

**Broken window (old app + new database)** [I]:
- **5b-1:** additive views. The split now closes its own run; old app unaffected. A role save that breaks the new rule is refused by name (`ACTION_REQUIRES_VIEW`) in the old app too, shown as a fallback sentence. Live roles all pass (§0). Window ≈ deploy time.
- **5b-2:**
  - the old expense page's Reverse on a relief now also restores its estimates (better, not breaking);
  - Reverse on a settled expense is refused by name (new);
  - a direct PATCH of a stamp is refused (the old app does not send one);
  - the old electricity page has no reverse control (there are no live allocations anyway).
- **5b-3:** the `blending` operation is `started_from_run_page`, so the old new-run form never offers it (MES-5a-1 filters on that flag). Window nil.
- **Existing runs, batches and ledger rows:** none is changed by any migration. The 14 pre-MES-4a runs, the one relieved estimate (`EXP-2026-0005`) and the 10 posted expenses stay as recorded. No back-fill.

**Time — process floor plus work, two numbers** [M, eight transcripts; active = brief → push, gaps < 10 min; matches the earlier tables within 46 s]:

| cut | active | floor | work | Step 0 estimate | active ÷ low |
|---|---|---|---|---|---|
| MES-1 | 2 h 39 m | 1 h 38 m (incident) | 1 h 01 m | 4 h 20 – 8 h 35 | 0.61 |
| MES-2 | 2 h 47 m | 1 h 08 m | 1 h 38 m | 2 h 35 – 5 h 10 | 1.08 |
| MES-3a | 2 h 48 m | 1 h 04 m | 1 h 44 m | 2 h 50 – 5 h 15 | 0.99 |
| MES-3b | 2 h 06 m (2 h 26 m with a smoke wait) | 0 h 54 m | 1 h 12 m | 2 h 50 – 4 h 20 | 0.74 |
| MES-4a | 3 h 35 m | 2 h 06 m (reruns) | 1 h 30 m | 3 h 40 – 6 h 20 | 0.98 |
| MES-4b | 3 h 20 m | 1 h 42 m (gate rerun) | 1 h 38 m | 3 h 20 – 6 h 05 | 1.00 |
| MES-5a-1 | 2 h 11 m | 1 h 02 m | 1 h 09 m | 3 h 30 – 5 h 40 | 0.62 |
| MES-5a-2 | 2 h 39 m | 1 h 14 m | 1 h 25 m | 3 h 00 – 4 h 55 | 0.89 |

- **Floor:** clean 0 h 54 m – 1 h 30 m (median ≈ 1 h 05 m); with one incident up to 2 h 06 m. Used below: **1 h 05 m – 1 h 45 m**.
- **Work:** 1 h 01 m – 1 h 44 m per cut, barely tracking scope. Every cut landed at ≤ 1.08 of its estimate's low end (median 0.93), and work alone at a median 0.68 of the estimated work's low end.

**Work, per cut (estimated low – high, then the calibrated expectation at ×0.68):**

| part | 5b-1 | 5b-2 | 5b-3 |
|---|---|---|---|
| orientation | 5 – 5 | 5 – 5 | 5 – 5 |
| database | forward-balance tree 30 – 55 · monthly + roll-forward 15 – 25 · yield 15 – 30 · split close / tolerance 10 – 15 · V37 5 – 10 · f check (column, guard, seed, self-check, build check) 25 – 45 | F1 40 – 70 · F2 20 – 35 · settlement guard 15 – 25 · settled refusal 5 – 10 · post asks view 5 – 5 | 3 tables + `BLD` registry 30 – 50 · operation, execute wrapper, release / cancel, prediction view 35 – 60 |
| pages | 30 – 60 | 10 – 20 | 40 – 75 |
| fixtures + injections | 25 – 45 | 30 – 55 | 25 – 45 |
| live proof | 5 – 10 | 10 – 20 | 5 – 10 |
| messages, docs, static | 15 – 25 | 10 – 15 | 15 – 25 |
| **work** | **3 h 00 – 5 h 25** | **2 h 30 – 4 h 20** | **2 h 35 – 4 h 30** |
| **calibrated work** | **≈ 2 h 05** | **≈ 1 h 40** | **≈ 1 h 45** |

**Estimates:**
- **MES-5b-1 Balance and yield:** floor 1 h 05 – 1 h 45 + work 3 h 00 – 5 h 25 = **4 h 05 – 7 h 10**; calibrated ≈ **3 h 10 – 3 h 50**.
- **MES-5b-2 Reversals:** floor 1 h 05 – 1 h 45 + work 2 h 30 – 4 h 20 = **3 h 35 – 6 h 05**; calibrated ≈ **2 h 45 – 3 h 25**.
- **MES-5b-3 Blending:** floor 1 h 05 – 1 h 45 + work 2 h 35 – 4 h 30 = **3 h 40 – 6 h 15**; calibrated ≈ **2 h 50 – 3 h 30**.
- **One cut instead:** floor 1 h 05 – 1 h 45 + work 8 h 05 – 14 h 15 = **9 h 10 – 16 h 00**; calibrated ≈ **6 h 35 – 7 h 15**, which is 1.8–2.0× the largest measured MES cut (3 h 35 m).
- MES-0's figure for MES-5b without the fold-ins was 6 h 20 – 10 h 45.

---

## §12 · Assertions measured and found false or imprecise

1. **The brief's F2 — "reversing a month-end relief expense leaves the estimates it relieved deleted".** They are not deleted; they stay **stamped as settled** against a reversed document (§1.1, measured live: `deleted = false`).
2. **`docs/known-issues.md:10518-10520` (`MES5A2-RELIEF-REVERSAL-ORPHANS`)** says month-end relief soft-deletes. It does not. `processing_cost_variance.sql:17-19` already says so. To correct in MES-5b-2 (Q36).
3. **`docs/forward-queue.md:1980`** — the "每吨" denominator row still reads "没人选过" (nobody has chosen). MES-5a Q23 ruled `total_input`, and MES-5a-2 built it (Q36).
4. **The ruling f wording "the view code of the page where that action is used"** assumes one page. Fifteen codes are used on pages with different gates (§1.5). The live check of §0 table 1 used one page per code; §0 table 2 measured "at least one page".
5. **The bootstrap seed vs the rule.** The bootstrap admin and finance roles break it (§1.5). The live roles do not.
6. **MES-0 `:109` cites `commit_processing_run.sql:299` for "output ≤ input"**; it is now at `:371-373`.
7. **`docs/handbacks/MES-5a-2.md` §7 decision 9** says relieved estimates are soft-deleted "with the same columns month-end relief uses". The columns are the same; the soft-delete is the allocation's alone.
8. **`processing_run_energy` keeps reversed runs** (no status filter). Not wrong for one run's page, which shows the run's status; wrong for any sum. The yield views must filter.
9. **Electricity actual lines' accrual journals are dated today, not the bill date** (the trigger's `CURRENT_DATE`), while the allocation journal is dated the bill date. Within one posting they net in the same accounts; across a month boundary they land in different periods. Recorded, not a question for this cut.

## §13 · Tim's own facts this cut needs (not design questions)

- Whether the plant blends at all, and on what (black mass from different lines, cathode powder lots…), and for which offtake contract. If not, 5b-3 waits (Q16).
- Which offtake contracts carry grade specs. Live: 0.
- The materials' chemistry. Live: 2 of 5 live materials have one; the "chemistry not recorded" group will hold the rest.

---

## §14 · Every open question, with a recommended answer and its evidence

### A · Scope and cuts

❓ **Q1 — Contents.** MES-0 said 3.5 tables / 5 pages for functions 9, 10, 12. The fold-ins add F1, F2, b and f.
➡️ **As §2.**
- Balance and yield are views and readers plus three pages and two panels, with no new table except V37's column.
- Reversals: one new table and changes to six functions.
- Blending: three tables, one operation and three pages.
- The f check: one catalogue column, a guard, a seed fix and a build check.
- Left out: §2's list.

❓ **Q2 — One cut or three.** One cut is ≈ 9 h 10 – 16 h 00 (calibrated ≈ 6 h 35+), 1.8–2× the largest measured MES cut. The three parts share no table and prove different things: a read-side report; GL reversal with AP = ledger; plan and run engine.
➡️ **Three cuts, in this order:**
1. **MES-5b-1 Balance and yield** (+ the f check), ≈ 4 h 05 – 7 h 10, calibrated ≈ 3 h 10 – 3 h 50;
2. **MES-5b-2 Reversals** (F1, F2 + the b arm), ≈ 3 h 35 – 6 h 05, calibrated ≈ 2 h 45 – 3 h 25;
3. **MES-5b-3 Blending**, ≈ 3 h 40 – 6 h 15, calibrated ≈ 2 h 50 – 3 h 30 — and only if Q16 says the plant blends.

Each fold-in rides the first cut whose domain it touches. Two extra floors (≈ 2 h 10) buy three cuts each inside the measured range.

### B · Balance

❓ **Q3 — What counts as consumption.** Deep discharge's input is throughput (no stock effect, output = input). The quarantine split moves the same mass into a child batch. Today `/inventory`, `cod_delivery_completion` and `work_order_fulfilment` count both as consumption (§1.6).
➡️ **Only runs of a `consumes_input` kind (`operation_kinds`) consume.**
- Deep discharge appears as an event line ("discharged and verified by …"), and its kg as pass-through.
- A quarantine split reads as a **transfer** to its child batch: no loss, no remainder, and the child carries the share onward.

❓ **Q4 — Attribution through multi-input and multi-output runs (MES-0 Q59 "by mass consumed", made exact).**
➡️ **Each consuming run's outputs, named losses and remainder are attributed to its input legs in proportion to `quantity_consumed`; an output batch fed onward carries its attributed share into the next run, recursively, to on-hand, sold, written-off or lost.**
- Shares are exact numerics, rounded only on screen, so every node adds up.
- Implemented as an owner view (`inbound_batch_balance_all`, revoked) with a gated reader under `module.processing.view`, plus the batch's own view code for its own page.
- `batch_lineage` is not reused, because it repeats whole legs (§1.8).

❓ **Q5 — What one batch's balance shows.**
➡️ **Received = on hand + sold + written off + adjustments + consumed** (from `inventory_movements`).
- "Consumed" opens into the run tree of Q4: each run's outputs by form, each output's onward fate, named losses by category and basis, and the remainder with its closure state.
- Discharge events, splits and reversed runs show as separate lines.
- On both `/inbound/[id]/edit` and `/output/[id]/edit` (an output batch's balance is its own forward tree).

❓ **Q6 — Pre-MES-4a runs** (all 14 live runs).
➡️ **Included in the mass.** Their loss shows as "loss recorded before named losses existed" — unexplained, never named — and their state as "before closure". No back-fill (MES-0 Q94).

❓ **Q7 — Reversed and corrected runs.**
➡️ **Reversed runs are excluded from every sum and listed apart, with kg and the date reversed. A run with `corrects_run_id` links to the run it replaced.**

❓ **Q8 — The monthly balance.**
➡️ **By `process_date` month, plant-wide and per operation**, with these lines:
- input to consuming runs;
- outputs by form;
- named losses by category × basis;
- remainder split by state (closed within tolerance / closed with explanation / open / before closure);
- pass-through apart;
- reversed apart.

Plus a **stock roll-forward** from `inventory_movements` by `business_date` (opening, receipts, produced, consumed, sold, written off, adjustments, closing), with **no "ties" flag**: its two sides cannot move apart.

❓ **Q9 — Relation to month-end.**
➡️ **The "Material balances closed" step stays a warning (MES-0 Q48) and gains a link to that month's balance.**
- Nothing is frozen in MES-5b; the page says "live figures, not frozen".
- Freezing per period is MES-8b's compliance pack (MES-0 Q82).

❓ **Q10 — Units.** Inputs are not unit-checked at commit; `inbound_batches.unit` has no CHECK (`inbound_batches.sql:37`). Outputs are refused unless kg.
➡️ **The balance and yield views exclude any leg whose batch unit is not kg and list it as "unit not kg — not summed".** A commit-time input guard is a separate decision, registered in `docs/known-issues.md` rather than built here (no live non-kg batch is known; unmeasured).

❓ **Q11 — Quarantine-split runs sit "open" and V1 asks for their tolerance.**
➡️ **`split_failed_modules_to_quarantine` closes its own run's balance in the same transaction.** The remainder is 0 by construction: weighed output = consumed.
- Seed `balance_tolerance_pct = 0` on `discharge_quarantine_split`. This is not an invented number: the operation moves mass unchanged, so any non-zero remainder is wrong by definition. It also removes the split from the V1 arm.
- Fixture 255 SPLIT gains the closure assertion.

❓ **Q12 — `/inventory`'s lifetime "material balance".** It sums every run, including discharge throughput.
➡️ **It reads the new monthly view's lifetime totals** with Q3's exclusions. This changes a displayed number, and the release line says so. The convention "no date filter" stays.

### C · Yield

❓ **Q13 — What yield is.**
➡️ **Per run:**
- each output leg ÷ total input;
- total output ÷ total input;
- each named loss category ÷ total input;
- remainder ÷ total input.

**Per operation and per month:** the same sums over that operation's consuming runs.

**Basis is total input** (MES-5a Q23). For `electrode_powder_line` that is the specification's "per unit of electrode sheet" (§3.5).

**How categories count:**
- collected dust is an output;
- `equipment_holdup` and `sweepings` are losses marked recoverable;
- pass-through operations have no yield;
- reversed runs are excluded;
- pre-MES-4a runs are included and labelled.

❓ **Q14 — Groupings.**
➡️ **Operation · month · output form · machine · chemistry (with "chemistry not recorded", MES-0 Q60) · supplier** (through Q4 to the inbound batch).
- The supplier name shows to readers who hold `module.inbound.view`; otherwise it reads "restricted" (decision 3: the label follows the batch).
- Metal yield stays `processing_metal_recovery`, linked.

❓ **Q15 — Targets.** The repo's record says a standard invented before real runs is fiction (`forward-queue.md:709,2383-2385`), and Tim ruled yield an estimate, not an auditable KPI (`proc-reality.md:517`).
➡️ **V37 "expected mass yield (%) per operation × output form", Not yet set.**
- It flags a run, operation or month below it and never refuses.
- Its arm appears only for operations with ≥ 1 MES-4a-era committed run (the V9 precedent: no rows nobody can act on).
- It is supplied by Tim with the process engineer after commissioning.

If Tim prefers no target at all, drop V37; the reports do not depend on it.

### D · Blending (MES-5b-3)

❓ **Q16 — Does the plant blend, and what is a blend?** The specification is silent; live has 0 grade specs.
➡️ **A blend = combining saleable powder batches of different metal content into one output batch to meet an offtake grade.** Build it as MES-0 Q58 says, **if Tim confirms the plant will blend**. If not, 5b-3 waits in the queue with its design recorded here.

❓ **Q17 — Plan shape.**
➡️ **Three tables:**
- `blending_plans`: code `BLD-` (yearly, through `document_types`); output material; source contract (optional); status draft / released / executed / cancelled;
- `blending_plan_targets`: metal, min, max — bounds, not target ± tolerance (CONTRACT-1 U8), copied from a contract's grade spec when one is chosen, or entered;
- `blending_plan_lines`: candidate batch, planned kg.

The predicted composition is the mass-weighted mean of each line's current metal content, with its source. It is "not measured" for any metal some line lacks. It is computed, not stored.

❓ **Q18 — Execution.**
➡️ **A transforming operation `blending`** (`started_from_run_page`; inputs and outputs are the saleable powder forms).
- It is executed from the plan page through `execute_blending_plan`, a wrapper over `commit_processing_run` plus a plan → run link. This is the MES-5a-1 split precedent: no signature change on the run engine.
- Actual kg may differ from the plan; the difference is shown.
- The output batch's metal content is not written from the prediction; an assay sets it.

❓ **Q19 — Codes.**
➡️ **No new code.**
- Create and edit: `action.wo_create`. Release: `action.wo_release`, and the creator never releases (the work-order four-eyes). Execute: `action.processing_commit`. Read: `module.processing.view`.
- Batch metal content shows only to readers who hold the batch's view code (`module.inbound.view` / `module.output.view`); otherwise "restricted".
- Under Q30 these codes' declared views already include `module.processing.view`.

❓ **Q20 — Saleability, limits, breaches.**
➡️ **The plan's output material must be of a `may_be_sold` form**; otherwise it is refused by name.
- A prediction outside the bounds is **flagged, never refused** (CONTRACT-1: report, not gate).
- No blend limit values in this cut, because none was supplied.
- The plan page compares the executed batch's later assay with the bounds. A general sales-side grade-breach view (today's is purchase-side only) is not in this cut.

### E · Finance fold-ins (MES-5b-2)

❓ **Q21 — F2, restated.** Relief stamps; it does not delete (§1.1).
➡️ **When `reverse_expense` reverses an expense that relieved estimates, the same transaction clears `relieved_at` and `relief_expense_id` on those estimates.** No journal: the reversed relief journal already restores 2200.
- It refuses by name (`RELIEF_ESTIMATE_NOW_ALLOCATED|<run>`) if an electricity estimate's run has since been covered by an allocation, naming the route: reverse that allocation first.
- `processing_cost_variance` stops counting reversed reliefs.
- The `'SGD', 1` literal in `relieve_processing_accruals` is replaced by the base currency from data, because this cut touches the file (MES-5a Q35).

❓ **Q22 — F1's entry point and shape.**
➡️ **A new function `reverse_electricity_allocation(allocation, reason)`** under `module.finance.edit`, with the reason required (the `reverse_freight_document` precedent).
- `reverse_expense` keeps refusing an allocation's expense, and its sentence names the allocation page.

One transaction, one reversal date (`reversal_date_for`, today in practice; period lock enforced):
1. reverse the expense and journal through `reverse_expense`'s internals;
2. for each actual line, clear `remitted_*`, then soft-delete it (the existing trigger posts Dr 2200 / Cr 5110);
3. for each relieved estimate, clear the stamps, un-delete it, and post Dr 5110 / Cr 2200 explicitly;
4. one row in the new append-only `electricity_allocation_reversals` (amounts masked like the allocation's).

Proof: AP list = ledger, 0.00 unexplained, and 2200 / 5110 / 6200 / 2000 (or bank) back to their pre-allocation balances.

❓ **Q23 — Posting a corrected bill after a reversal.**
➡️ **Drop `electricity_allocation_lines.run_id UNIQUE` and replace it with a guard: a run may sit in at most one non-reversed allocation.** The compute's "already allocated" and "period overlaps" checks ignore reversed allocations. A fixture arm posts → reverses → posts again for the same period.

❓ **Q24 — Paid and settled bills.**
➡️ **A paid-born bill (bank credited at posting) may be reversed: the bank is debited on the reversal date, as `reverse_expense` does today for paid expenses.**
- **Any expense with payment allocations (settled through a payment) is refused by name** in `reverse_expense` — for every expense, not only these two — with the route: reverse the payment first through the payment-reversal request (`FREIGHT_HAS_SETTLEMENT` precedent).
- This closes the AP = ledger divergence of §1.4 for the general path too. The change is one check in a function this cut already edits.

❓ **Q25 — Approval for the reversals.**
➡️ **None.** Expenses carry no approval (role-matrix; `approvals.md:789-815`), and `reverse_expense` has none. A CFO request would be a new ruling.

❓ **Q26 — The settlement-stamp side door** (§1.3, live grant measured).
➡️ **`guard_cost_entry_settled` also refuses any change to `remitted_at`, `remitted_journal_entry_id`, `relieved_at` or `relief_expense_id`** unless the change comes from a finance function. Those functions set a transaction-local context flag, the `reverse_freight_document` context-flag precedent: relieve, remit, post allocation, reverse expense, reverse allocation. The refusal is by name: `COST_ENTRY_SETTLEMENT_THROUGH_FUNCTION_ONLY`.

❓ **Q27 — History rows for stamp changes.**
➡️ **No new history kind.** The change log records every stamp change (who, when, before / after), and the run's audit trail reads it. `processing_cost_entry_history` keeps its four kinds.

❓ **Q28 — The post asks less than its preview** (close-out §2 f).
➡️ **`post_electricity_allocation` also requires `module.finance.view`.** Live holders of edit all hold view (§0), so no one loses the action.

❓ **Q29 — The paid-bill arm (ruling b).**
➡️ **Fixture 256 gains ALLOC-PAID:**
- a paid base-currency bill against the base bank;
- journal Dr 2200 / Dr 6200 / **Cr the bank**;
- the expense `paid` with that bank and no supplier required;
- `ELECTRICITY_BANK_NOT_BASE` for a foreign-currency bank;
- AP = ledger 0.00.

Its own injection: a paid bill credits 2000 → red in that arm. It rides MES-5b-2, because F1 must reverse both branches.

### F · Governance

❓ **Q30 — What the f check checks** (§1.5: fifteen codes have pages with different gates).
➡️ **Declare, per action code, the view codes that let a holder reach a page using it.**
- **Storage:** a new catalogue column `permissions.requires_view_any text[]` (seed table: the mirror and live move together; `self` for codes whose page is gated by the code itself).
- **Rule:** a role holding the code must hold **at least one** of them.
- **Enforced in four places:**
  - `set_role_permissions` refuses `ACTION_REQUIRES_VIEW|<code>|<views>` (beside today's `EDIT_REQUIRES_VIEW`);
  - the bootstrap self-check DO block (`role_permissions.sql:258-274`);
  - a gate fixture over the rebuilt roles;
  - a build check (node, `lib/modules.ts` imported natively) that every declared view is the gate of at least one page using the code, with runtime-fetched codes (`raise_po_*`, `approve_review`) declared.

Measured on live: 67 / 67 pairs pass under this reading (§0 table 2). "All of the pages" is rejected: it collides with warehouse not holding `module.sales.view` (APR-5b).

❓ **Q31 — The bootstrap seed breaks the rule** (`role_permissions.sql:69-77,126`).
➡️ **Add `module.processing.view` to the bootstrap admin and finance roles.** Live finance already holds it (role1b3b); live admin holds every code. The bootstrap admin's minimal set contradicts the standing ruling "admin holds every code" (`docs/role-matrix.md`, 2026-09-24). That larger divergence is registered in `docs/known-issues.md` for Tim, not changed here.

❓ **Q32 — Approvals, trails, change log, masking.**
➡️ **As §9.**
- No new approval.
- Every new table change-logged (235 stays 8).
- New trail subject `blending_plan`; the reversal on the allocation's trail.
- One wording arm per cut with its own fault.
- No new masked columns except the reversal's amounts.
- The supplier label on yield follows the batch's read code.

❓ **Q33 — Pending values.**
➡️ **V37 only (if Q15), with its arm and its `docs/mes-pending-values.md` row in the same commit.** Blending adds none.

### G · Migration, fixtures, records

❓ **Q34 — Migration and window.**
➡️ **Accept §11: one migration per cut.** Every window is ≈ the deploy time: additive views, refusals only on paths the old app does not send, the new operation hidden by `started_from_run_page`. No existing run, batch or ledger row is changed; no back-fill.

❓ **Q35 — Fixtures.**
➡️ **New:** 257 (balance and yield: attribution, pass-through, split, pre-MES-4a, reversed, unit, monthly, yield bases, V37), 258 (reversals: F1 unpaid and paid, re-post, F2, the guard, the settled refusal, ledger proof), 259 (blending), and the f check's arm.
**Changed, without weakening:** 256 (ALLOC-PAID), 213 (relief reversal), 255 SPLIT (closure, and absent from the month-end warning), 100 and the search registry if `BLD` mints yearly.
Every new arm fault-injected; the injection run repeated after the last edit, before the push.

❓ **Q36 — Stale records found (§12 items 2, 3, 6, 7).**
➡️ **Correct each in the cut that touches its file:**
- the known-issues wording and the MES-5a-2 hand-back note go in 5b-2;
- `forward-queue.md:1980` goes in 5b-1 (struck, pointing at MES-5a Q23);
- the MES-0 line reference is left as history, with a note.

❓ **Q37 — `processing_run_energy` shows reversed runs.**
➡️ **Leave the view (its one reader shows the run's own status); every sum over it — the new yield views — filters committed, live runs.** Registered as a note in the view's header comment when 5b-1 touches it.

## §15 · Stop

No code edits and no migrations. Waiting on Tim's answers to Q1–Q37.
