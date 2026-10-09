v1.4.46 — Reversals: a posted electricity bill can now be reversed with a reason, which undoes its entries and brings back the hand-typed estimates it replaced so a corrected bill can be posted; reversing a month-end relief now lets those estimates be relieved again; an expense that has already been paid through a payment can no longer be reversed until the payment itself is reversed; and settlement marks on costs can only be changed by the finance steps that own them.

# MES-5b-2 — reversals (MES group, tenth cut; 2026-10-09)

Tim's brief of 2026-10-09 ("MES-5b-1 close-out + MES-5b-2 build: reversals"): every MES-5b Step 0 recommendation for the reversals accepted as
stated (Q21–Q29 and the reversal parts of Q1, Q32, Q34–Q36; `docs/surveys/MES-5b/STEP0-HANDBACK.md` §14 E), with the fold-in
`MES5B1-V37-NOT-ON-OPERATION-TRAIL`. Migration `db/migrations/2026-10-09-mes5b2-reversals.sql` (2,748 lines, built from the mirrors by
`db/scripts/build_mes5b2_migration.py`). Opening SHA: HEAD = origin/main = `git ls-remote origin main` = `00744effe656e8a6eb20c9c73ee099db0bdd55b1`
(tree clean; first command 2026-10-09 13:06:49 CST). Step 1 committed and pushed as `e0adb3884a298c3fc625ed531b7e1e0850cc3659` ("MES-5b-1 close-out").

---

## §0 · Step 1 — MES-5b-1 close-out, item by item

Full evidence (file:line, fixture arms, live readings, the role × page table): `docs/surveys/MES-5b/MES-5b-1-CLOSEOUT.md`.

| Item | Result |
|---|---|
| 1 · Broken window | Start 2026-10-08 21:28:31 CST (measured, `db/migration-windows.tsv`) · end lower bound 22:39:22 CST (measured, `git reflog` of `origin/main` → `00744eff`) · end upper bound 2026-10-09 13:06:49 CST (this session's first command, resting on Tim's "deployed", not a Vercel reading) → **1 h 10 min 51 s – 15 h 38 min 18 s**. Nobody used the new features in it (runs since the window 0, V37 set 0, closures 0, splits 0). Recorded in `docs/forward-queue.md` item 44 |
| 2a · The MES-5b-1 fixture list | **All 14 items covered** — fixture 257 arms CONS · ATTR · BAL · PRE · MONTH · ROLL · NOTKG · INV · YIELD · GROUP · V37 · FCHECK · LOG, fixture 255 SPLIT, two rebuild cells, the build check, wording arm ㉓; re-measured on HEAD: offline gate `GATEOFF_EXIT=0`, `check-action-view-declared` 0, ㉓ clean 0 / fault 1 |
| 2b · Unit check, per-tonne row, wording arm, exclusions | **Present** — `MES5B1-INPUT-UNIT-NOT-CHECKED-AT-COMMIT` (`docs/known-issues.md:10536`), the per-tonne row struck (`docs/forward-queue.md:1999`), ㉓ green / red under its fault, exclusions 8 (fixture 257 LOG, fixture 235) |
| 2c · Admin's codes ruling | The ruling as recorded (`docs/role-matrix.md:208`, "keep + every new code", headed "holds every code") **does not contain** a `module.tasks.view_all` exception — the row records that admin never held it and that adding it is Tim's word. MES-5b-1 built 74 / 75. **Mismatch recorded for Tim:** `docs/known-issues.md` `MES5B1C-ADMIN-TASKS-VIEW-ALL-UNRULED`; nothing changed |
| 2d · Usability on live | All seven real roles open `/operation/balance`, `/operation/yield` and both batch panels (hand-back §1). Re-measured: each real account's own read-only session holds the gate codes and reads the rows (monthly 23, roll-forward 5, run yield 30 — all pre-MES-4a, trees 103 / 10); seven one-off clones fetched the four views on the **deployed** app: 28 × HTTP 200, title present, no error text, "before balance closure" printed on balance, yield and the inbound panel (live has no output batch that fed a run, so the output panel has nothing to label) |
| 2e · Self-taken decisions | 25 titles listed in the close-out file §2 e |
| 3 · Commit | `e0adb388` "MES-5b-1 close-out", pushed |
| 4 · Stop? | a, b and d pass → step 2 went ahead; c is recorded, not a stop |

## §1 · Opening live readings (before anything changed)

Read 2026-10-09 **13:26 CST** as `postgres` (`rolbypassrls = true`) over direct psql, `BEGIN READ ONLY … ROLLBACK`, base tables; the
reconciliation in tim@'s (cfo) session (`db/scripts/2026-10-09-mes5b2-opening-readings.sql`, `READ_OWN_EXIT=0`).

| Reading | Value |
|---|---|
| Expenses by kind × settlement (kind derived from what points at the expense) | ordinary: 1 paid at posting (`EXP-2026-0002`, 18.50) · 1 **part-settled through a payment** (`EXP-2026-0001`, 3.70) · 4 unpaid open (`EXP-2026-0003/0004/0009/0010`, 5,300.74) — month-end relief: 1 paid at posting (`EXP-2026-0005`, 214) — capital append: 1 **prepayment applied** (`EXP-2026-0006`, 400,000.00) — expense claim: 1 unpaid open (`EXP-2026-0007`, 100) — medical claim: 1 unpaid open (`EXP-2026-0008`, 30) — electricity allocation: 0 — reversed: 0 |
| Relief expenses and their estimates | `EXP-2026-0005` (posted, not reversed, paid, 2026-08-05, 214.00): **1** estimate relieved — `PROC-2026-0003` electricity 200, `relieved_at` 2026-08-05, **not deleted**. No reversed relief |
| Electricity allocations · lines | **0 · 0** |
| Cost entries by type × estimate × mark | electricity actual open 1 (123.45) · electricity estimate open 4 (980) · electricity estimate **relieved** 1 (200) · labour actual open 4 (900); remitted 0; deleted 0. Marks pointing at a reversed relief: **0** |
| AP / AR (tim@) | AP list 422,188.32 / ledger 381,604.42 / **unexplained 0.00** · AR 57,545.87 / 43,002.12 / **0.00** |
| Standing state | 7 accounts, 0 disabled, 0 throwaway · approvals ON · `require_calibrated_since` NULL · 1 pending (`expense_claim CLM-2026-0004` 1,000.00, not mine) · `change_log` 19,855 rows (max seq 22,110) · notifications 2 · payments 13 (9 posted) · journals 83 |

## §2 · Role-by-role reading table (live, measured)

Read inside the live proof (`db/scripts/2026-10-09-mes5b2-live-proof.sql` via `.mjs`, `MES5B2_PROOF_EXIT=0`, 15:38:54–15:39:57 CST; the
transaction 11.2 s, ROLLBACK), after bill A had been reversed and the corrected bill posted — the allocation page needs an allocation, and one
exists only inside that transaction. Each row is a **one-off clone of a real role** (`mintThrowaway { cloneOf }`: exactly that role's codes at
that moment; the proof asserts the clone's code set equals the real role's, row by row — all seven matched). No real account read or acted.
"Open" is the page gate (`has_permission`, the same predicate as `can()`); "pressable" is the code the control's `PermissionGate` asks; amounts
are what the clone reads in its own session through the `_masked` views.

| Real role (live account) | `/finance/electricity/[id]`: page | Reverse control | Bill amount | Reversal amounts (bill / lines / estimates) | Reversal counts (lines / estimates) | `/finance/expenses/[id]`: page | Reverse expense | Relief: estimates it would bring back | AP · AR unexplained |
|---|---|---|---|---|---|---|---|---|---|
| admin (admin@) | open | **pressable** | 600 | 600 / 450.00 / 370 | 2 / 2 | open | **pressable** | 1 | 0.00 · 0.00 |
| finance (chooer@) | open | **pressable** | 600 | 600 / 450.00 / 370 | 2 / 2 | open | **pressable** | 1 | 0.00 · 0.00 |
| warehouse (fusheng@) | **refused** (no `module.finance.view`) | not pressable | **masked** | **masked** | 2 / 2 | **refused** | not pressable | 1 | no `module.finance.view` |
| cto (phua@) | open | visible, not pressable | 600 | 600 / 450.00 / 370 | 2 / 2 | open | visible, not pressable | 1 | 0.00 · 0.00 |
| cco (sandra@) | open | visible, not pressable | 600 | 600 / 450.00 / 370 | 2 / 2 | open | visible, not pressable | 1 | 0.00 · 0.00 |
| cfo (tim@) | open | visible, not pressable | 600 | 600 / 450.00 / 370 | 2 / 2 | open | visible, not pressable | 1 | 0.00 · 0.00 |
| gm (vince@) | open | visible, not pressable | 600 | 600 / 450.00 / 370 | 2 / 2 | open | visible, not pressable | 1 | 0.00 · 0.00 |

How to read it: **only admin and finance can reverse** (they alone hold `module.finance.edit`); everyone else who can open the page sees the
control disabled with the sentence naming the code (DBLOCK-1). **Warehouse is the only role without `data.view_prices` (and without
`module.finance.view`)**: the allocation and reversal amounts read NULL through the `_masked` views ("restricted", not 0.00) while the counts stay
visible, and both finance pages refuse it at their gate. The relief count reads through `processing_cost_entry_lookup`, which admits finance or
processing view — so a finance-only reader sees the real number, not a refusal posing as "0". **No grant changed; no approval added (Q25 · Q32).**

## §3 · Every item built

### §3.1 Database (one migration)

- **New table `electricity_allocation_reversals`** — one row per reversed bill (`allocation_id` unique), reason required, append-only
  (`guard_append_only_log`), RLS select `module.finance.view` or `module.processing.view` (the allocation's), change-logged. Masked amounts
  (`bill_amount`, `actual_line_amount`, `restored_estimate_amount`) out of the column-list grant and read through the new
  `electricity_allocation_reversals_masked` (`data.view_prices`), with three new rows in `change_log_mask_rules` (111 → 114) — one migration.
- **New functions:** `reverse_electricity_allocation(allocation, reason)` (SECURITY DEFINER, `module.finance.edit`) · `reverse_expense_internal`
  (the body that used to be `reverse_expense`'s, moved verbatim, plus the settlement refusals; revoked) · `guard_electricity_line_one_live_allocation`
  (trigger; revoked).
- **Replaced (same signatures):** `reverse_expense` (F2 restore + `RELIEF_ESTIMATE_NOW_ALLOCATED`; the allocation refusal carries the allocation id)
  · `electricity_allocation_compute` (overlap and "already allocated" ignore reversed allocations) · `post_electricity_allocation` (also
  `module.finance.view`; sets the settlement context) · `relieve_processing_accruals` (base currency from data; settlement context) ·
  `remit_processing_costs` (settlement context) · `trail_subjects` (comment) · `trail_subject_members` (+4 members) · `change_log_mask_rules` (+3).
- **Structure:** `electricity_allocation_lines.run_id` unique constraint dropped → plain index + the one-live guard trigger; `guard_cost_entry_settled`
  refuses any change to the four settlement stamps (and a born-settled insert) without the finance context → `COST_ENTRY_SETTLEMENT_THROUGH_FUNCTION_ONLY`.
- **Views:** `processing_cost_variance` counts posted reliefs only · `processing_run_energy` reads only the non-reversed allocation's line ·
  `processing_cost_entry_lookup` gains `relief_expense_id`.
- **The migration's own proof** (same transaction): approvals ON; grants, accounts, pending documents unchanged (each still has a decider);
  digests of runs, cost entries and their history, expenses, journals and lines, payments and allocations, prepayment applications, devices,
  assets, asset cost entries, allocations, lines and output forms unchanged; `change_log` moved by **0**; the new table empty; run_id no longer
  unique with the guard and index present; both cost-entry guards present; the SGD literal gone; anon executes exactly the two; the reversal
  function DEFINER and callable, the internals not; reversal amounts out of the column grant; 44 open read policies; change-log coverage 0 gaps
  (8 excluded); mask gaps 0 (114 rules); 59 reminder arms and 20 pending-value arms unchanged.

### §3.2 Fixtures

- **258** (new) — arms PERM · UNPAID · REPOST · PAID · F2 · VAR · CCY · LOCK · KINDS · GUARD · MASK · LOG · AGREE (AP = ledger, 0.00 both sides,
  after every step). Data: machine A (300 kWh, two runs by run time 100 / 200) — unpaid bill 600 / 400 kWh relieving estimates 120 + 250, reversed,
  re-posted at 640; machine B (100 kWh, two runs) — paid bill 300 / 200 kWh from the base bank, reversed; month-end reliefs (W on a run later
  allocated → refused until that bill is reversed; X reversed and relieved again as Y; Z reversed with its stamps put back to prove the variance
  filter); ordinary / employee / relief / capital-append expenses and the corrected bill each paid through a payment → refused; a prepayment-applied
  expense → refused; a processing editor's direct stamp changes and a born-settled insert → refused; a period lock → refused, nothing changed.
- **256** gains **ALLOC-PAID** (a paid base-currency bill: Dr 2200 125 / Dr 6200 125 / Cr the base bank 250; the expense paid with that bank and no
  supplier; a foreign-currency bank refused by name; never on the AP list; AP = ledger 0.00).
- **213** gains **A20a / A20b** (reverse the month-end relief → its estimate unstamped, AP = ledger; relieve again → AP = ledger).
- **Fault injection** `db/scripts/2026-10-09-mes5b2-fixture-injections.py`: **42 cells on 258 + 1 on 256 (the paid bill crediting payables — Q29's
  own fault) + 1 on 213**, each red in the arm it names, every 258 arm red at least once. Last run after the last edit, against a fresh rebuild of the
  final mirrors: **`INJECTIONS_OWN_EXIT=0` (14:51 CST)**.
- **235** stays at 8 exclusions; **100** stays at 32 (the expense-code minting moved from `reverse_expense` into `reverse_expense_internal` — same count).

### §3.3 App

- `/finance/electricity/[id]`: a "Reverse this bill" section — the control (`ReverseAllocationControl.tsx`: ConfirmButton with consequences and a
  required reason, `PermissionGate` on `module.finance.edit`) on a live bill; on a reversed bill, the reversal record (date, reason, reversal
  expense and journal, where the money went back to, lines removed, estimates brought back — amounts masked without `data.view_prices`).
- `/finance/electricity`: a reversed bill is marked "reversed" in its row.
- `/finance/expenses/[id]`: the reverse button stays visible but unpressable, with the reason and the route, when the expense is an electricity
  bill (link to the bill), has been paid through a payment, or has a prepayment applied; on a month-end relief the confirmation says how many
  estimates come back.
- `/operation/processing/[id]`: the energy panel reads the line of the live allocation (a run can now have a reversed line and a live one).
- Messages (en / zh): `energy.reverse*`, `energy.reversal*`, `energy.reversedTag`, `energy.errors.*` (10 new), `expense.reverse*` (4), `expense.errors.*`
  (4 new + the allocation sentence names the page), `processing.errors.COST_ENTRY_SETTLEMENT_THROUGH_FUNCTION_ONLY`; `energy.noReversal` removed.
- Trail: the reversal ("Electricity bill reversed") on the bill and on each run it covered; V37 on the operation page; wording arm **㉔**
  (`wording-drift-mes5b2` → red in ㉔ only, 2 sentences). The three pinned sentences: "Electricity bill reversed · Reversal date … · Run shares removed
  (count): 2 · Estimates brought back: 370.00 SGD …" (on the bill and on a run, reason in the reason slot) · "Operation type output form edited ·
  Expected yield (%): (empty) → 70" (on the operation page).
- Registries: `lib/trail/render.ts` subject tables, `scripts/gen-trail-catalogue.mjs` + `docs/surveys/AUDIT-TRAIL-0/labels.csv` (15 columns),
  `scripts/check-document-registry.mjs` 282 → 283, `lib/maskedTables.ts`, `scripts/ephemeral.mjs` prefix `mes5b2probe`.

## §4 · Pages — every new or changed route, with its file

| Route | File(s) | What changed |
|---|---|---|
| `/finance/electricity/[id]` | `app/finance/electricity/[id]/page.tsx`, `ReverseAllocationControl.tsx`, `app/finance/electricity/actions.ts` (`reverseAllocation`), `energyErrorCodes.ts` | the reversal section: control or record |
| `/finance/electricity` | `app/finance/electricity/page.tsx` | "reversed" mark on a reversed bill |
| `/finance/expenses/[id]` | `app/finance/expenses/[id]/page.tsx`, `ReverseExpenseButton.tsx`, `app/finance/expenseErrorCodes.ts` | blocked reverse with reason and route; relief consequence |
| `/operation/processing/[id]` | `app/operation/processing/[id]/page.tsx` | the share line read by allocation |
| `/operation/operation-types/[code]` | (trail only — `lib/trail/render.ts`) | V37 changes on the page's own audit trail |
| every audit trail | `lib/trail/render.ts`, `lib/trail/text.ts`, `lib/trail/catalogue.generated.ts` | the reversal; output forms on the operation subject |
| processing cost edits (error text) | `app/operation/errorCodes.ts` | `COST_ENTRY_SETTLEMENT_THROUGH_FUNCTION_ONLY` in words |

## §5 · Verification, in the brief's order

| # | Step | Result |
|---|---|---|
| — | Before the window | Local rebuild + fixture 258 iterated off-repo (the live tree untouched); injection matrix built and run on the rebuild; a pre-window `npm run build` against a temporary type splice: `PREBUILD_EXIT=0` (third run — the first two caught `lib/maskedTables.ts` and the document-registry table count, each fixed); live proof rehearsed end to end on a local copy (`REHEARSE_OWN_EXIT=0`); preflight ✓ (13 functions: 9 replaced, 4 new; no masked-table column added). **Live dry run** of the built file, `COMMIT` → grants re-assert + probe + `ROLLBACK`: first attempt refused by the migration's own proof (a grant changed mid-transaction — a layout survey's throwaway account was being created at the same time from a scratch copy that holds its own live-lock; nothing kept); re-run alone **`DRY_OWN_EXIT=0`** (14:19:48 → 14:22:21; probe: 0 reversals, 114 mask rules, the unique constraint gone; every pending document still has a decider). Harness layout survey before the window: 0 / 0 at both widths |
| 1 | Offline gate | `GATEOFF_EXIT=0` (90 s; fixtures 213 · 235 · 256 · 258 ✓) |
| 2 | Backup (background) | `BACKUP_EXIT=0`, `evoltrya-backup-2026-10-09-1424.dump` (7.2 MB; TOC 8,563 entries; previous 8,525) — 14:24 → 14:45 |
| 3 | `apply_migration.sh` | `APPLY_OWN_EXIT=0`; applied 14:45:59, **committed 14:48:26 CST = window start** (`db/migration-windows.tsv`) |
| 4 | `types:gen` | `TYPES_OWN_EXIT=0` (with `DO_NOT_TRACK=1`): the new table, view and function, `relief_expense_id` on the lookup view, and 15 `isOneToOne: true → false` flips — the dropped `run_id` unique (230 lines in, 32 out) |
| 5 | tsc | `TSC_OWN_EXIT=0` |
| 6 | `npm run build` | `BUILD_EXIT=0` (every static check incl. trail arm ㉔, then `next build`, compiled in 31.0 s) |
| 7 | Full gate | `GATE_EXIT=0` (573 s): rebuild ✓ · mirrors vs live "NO DIFFERENCES" (incl. generated types) · fixtures ✓ (**261**) · anonymous surface ✓ (subset of the 328-line baseline); change log **283 tables · 275 logged · 8 excluded**, masks **38 tables / 114 columns**, zero gaps, live and rebuild |
| 8 | i18n | `I18N_OWN_EXIT=0` |
| 9 | Error swallowing | `SWALLOW_OWN_EXIT=0` (0 unallowed, 9 allowlisted) |
| 10 | Layout survey | 9 targets × 2 widths (`LSURVEY390_EXIT=0`, `LSURVEY1280_EXIT=0`), **every one 0 px overflow, 0 clipped tables**: `/finance/electricity`, `/finance/expenses/<EXP-2026-0001>` (part-paid → the blocked button with its reason), `/<EXP-2026-0006>` (prepayment applied → blocked), `/<EXP-2026-0005>` (relief), `/operation/processing/<PROC-2026-0003>`, `/operation/operation-types/battery_powder_line` (live data) and three scratch harnesses — the allocation page unreversed (control) and reversed (a 180-character reason), the list with a reversed row — because live has no allocation and this cut may not create one |
| 11 | Smoke (background) | `SMOKE_EXIT=0` — **277 ok, 13 skipped (no data), 0 failed** (264 routes plus the probes; 251 timed, 1,163.0 s; `/finance/electricity/[id]` skipped — no live allocation, in `EXPECTED_SKIPS`). **Scratch reading:** at start, the same 6 stale rows earlier cuts reported (`ZZ-SMOKE-*`, 888–1,530 h old, five still referenced) — none from this cut; after: 0 throwaway accounts, 0 probe roles, 7 accounts, 0 disabled |
| 12 | Live verification | §6 |

## §6 · Live verification

### §6.1 Rolled-back proof — `db/scripts/2026-10-09-mes5b2-live-proof.sql` via `.mjs` (`MES5B2_PROOF_EXIT=0`, 15:38:54–15:39:57 CST; transaction 11.2 s, ROLLBACK)

The driver minted 11 throwaway accounts (`mes5b2probe-…@test.local`: `dev`, `cap`, `ops`, `fin` with exactly the codes each step needs, and seven
role clones), ran the SQL as one transaction, and removed the accounts, grants and one-off roles by the ephemeral plan. Setup rows (a supplier, a
material, a batch, two machines `ZZ-PROBE-MES5B2-EQ` / `-EQ2`, a probe operation cloned from deep discharge) were inserted as the owner; the one
payment that settles an expense is setup too (owner, `record_payment_internal` — decision 21). **Every action the proof is about ran as a throwaway
account.** A first run stopped at the settled-expense setup (`TAX_CODE_REQUIRED|supplier` — live is GST-registered, the local rehearsal was not;
nothing kept); the expense now carries the zero-rated purchase code `ZP`. Each line is the proof's own `STEP|` output.

| Step | What happened (measured) |
|---|---|
| Start | AP 422,188.32 / 381,604.42 / **0.00** · AR 57,545.87 / 43,002.12 / **0.00** (c_cfo) |
| Runs | ops committed `PROC-2026-0746` · `-0747` (machine A, 2026-08-30 – 09-08) · `-0748` (machine B, 09-14 – 09-17) · `-0749`; ops typed estimates 120 / 250 / 90 (electricity) and 80 (gas) |
| Unpaid bill posted | fin posted bill A `EXP-2026-0011` (600.00 / 400 kWh): r1 150.00 · r2 300.00 · 6200 150.00; estimates 120 + 250 relieved; AP 422,788.32 / 382,204.42 / **0.00** |
| Unpaid bill reversed | `reverse_expense` on it refused `EXPENSE_IS_ELECTRICITY_ALLOCATION` (naming the allocation); `reverse_electricity_allocation` (reason given) → **estimates 120 + 250 restored, 2 re-accruals Dr 5110 / Cr 2200 posted, one reversal record (2 lines 450.00, 2 estimates 370.00), expense and journal reversed; 2200 / 5110 / 6200 / 2000 back to before the bill; the runs' live cost lines exactly as before**; AP back to 422,188.32 / 381,604.42 / **0.00** |
| Corrected bill | fin posted `EXP-2026-0013` for the **same period** (640.00): r1 160.00 · r2 320.00; the restored estimates relieved again; AP **0.00** |
| Paid bill | fin posted `EXP-2026-0014` (300.00 from bank 1000: **Cr bank 300.00**, payables untouched) and reversed it: **bank debited back**, 2200 / 5110 / 6200 / 2000 / 1000 back, estimate 90 restored; AP **0.00** |
| Relief | fin relieved the 80 estimate (`EXP-2026-0016`, 100.00), **reversed it (estimate back to unsettled, no extra journal)**, relieved it again (`EXP-2026-0018`, 95.00, currency SGD read from data); AP **0.00** |
| Settled refused | fin: `reverse_expense` on `EXP-2026-0019` (paid 100.00 through `PMT-2026-0010`) → **`EXPENSE_HAS_SETTLEMENT|EXP-2026-0019|100|SGD`**; reversing the corrected bill after it was paid → **`EXPENSE_HAS_SETTLEMENT|EXP-2026-0013|640|SGD`**; AP **0.00** |
| Stamp side door | ops (`module.processing.edit`) clearing a remitted stamp directly → **`COST_ENTRY_SETTLEMENT_THROUGH_FUNCTION_ONLY|remitted`**; clearing a relieved stamp → **`…|relieved`** |
| Untouched | pre-existing runs, cost lines, expenses, journals and their lines, payments and their allocations, devices identical inside the transaction; notifications 2 (unchanged); pending documents unchanged (`expense_claim:CLM-2026-0004`) |
| After ROLLBACK | probe suppliers / materials / batches / assets / operations 0 / 0 / 0 / 0 / 0 · meters / allocations / reversals 0 / 0 / 0 · `require_calibrated_since` NULL · pending documents 1 |

**Burned codes** (sequences do not roll back): `PROC-2026-0742`–`0749` (two runs of the proof), `EXP-2026-0011`–`0019`, `PMT-2026-0010` and the
journal and device codes the proof drew. Live's next codes skip them.

### §6.2 Read-only — the role table

§2.

### §6.3 Before and after

Before 14:24:28 (after the opening reading and before the backup), after 15:40:12 CST; `db/scripts/2026-10-06-mes1-live-readings.sql` (`postgres`,
base tables, one digest per public table) and `db/scripts/2026-10-05-at1d3-live-recon.sql` (tim@'s session, read-only); plus the opening reading re-run.

| Reading | Before | After |
|---|---|---|
| Per-table digests (282 public base tables before; `change_log` counted apart) | — | **every one identical** except `cod_verification_failures` (the smoke's documented COD-verify rotation: 1 DELETE + 1 INSERT); one new table `electricity_allocation_reversals`, **0 rows** |
| Expenses by kind and settlement · reliefs and their estimates · allocations · cost entries by mark | §1 | **identical** (the opening reading re-run, line for line) |
| `require_calibrated_since` | NULL | **NULL** |
| Accounts | 7, 0 disabled, 0 throwaway; admin@ admin · chooer@ finance · fusheng@ warehouse · phua@ cto · sandra@ cco · tim@ cfo · vince@ gm | **identical** |
| Approvals | ON | ON |
| Pending documents | 1 (`CLM-2026-0004`, not mine) | 1 (same) — none of mine |
| Notifications | 2 | **2** |
| Leftovers of mine | — | 0 `mes5b2probe` accounts · 0 `probe-` roles · 0 `ZZ-PROBE-MES5B2` rows |
| `change_log` | 20,338 rows, max seq 22,593 | 22,071 rows, max seq 24,730 — every row since the before-reading is a balanced INSERT / DELETE pair from the throwaway machinery of the surveys, the smoke and the proof (roles 25 / 25, `user_roles` 25 / 25, `role_permissions` 795 / 795, employees 7 / 7, reviews 3 / 3 + 3 updates, contracts and their five term tables 1–2 / 1–2) plus the COD rotation; **the migration wrote 0** (its proof asserts it). The proof itself left none (rolled back) |
| Reconciliation (tim@) | AP 422,188.32 / 381,604.42 / **0.00** · AR 57,545.87 / 43,002.12 / **0.00** | **identical** |

### §6.4 Broken window

Start **2026-10-09 14:48:26 CST** (measured: `apply_migration.sh` printed it at commit and wrote `db/migration-windows.tsv`). End: Tim confirms
the deployment in Vercel (this machine cannot reach Vercel — AGENTS.md). What is broken inside it (**derived**, not measured on live): the old app's
calls keep their signatures; the old expense page's Reverse on a month-end relief now also brings its estimates back (better, not breaking); Reverse
on an expense settled through a payment or with a prepayment applied is refused by name (new — the old localizer shows its fallback sentence); a
direct change to a settlement stamp is refused (the old app sends none); the old electricity pages have no reverse control (live has no allocation).
**One measured consequence, the other direction:** the new app on the old database 500s on `/finance/electricity` and `/finance/expenses/[id]`
(they read the new view and column) — seen in the pre-window survey from the scratch copy; it cannot happen in production because the migration
went first and the deploy follows the push.

## §7 · Decisions taken without asking

1. **One implementation of "reverse an expense".** `reverse_expense`'s body moved verbatim into `reverse_expense_internal`; `reverse_expense` and
   `reverse_electricity_allocation` both call it. The settlement refusals live there, so every kind of expense and both paths pass the same check.
2. **A prepayment-applied expense is refused too** (`EXPENSE_HAS_PREPAYMENT_APPLIED`). Same AP = ledger break as a payment (measured by an
   injection), and an application cannot be undone, so the sentence routes to a manual journal request. Registered
   `MES5B2-PREPAYMENT-APPLIED-EXPENSE-NOT-REVERSIBLE` (live: `EXP-2026-0006` becomes non-reversible).
3. **Part-settled counts as settled** (any posted payment allocation > 0), not only fully paid.
4. **The settlement guard also covers inserts.** A cost line born with a stamp is refused unless the finance context is present (only
   `post_electricity_allocation` writes one).
5. **The context flag** is `evoltrya.cost_settlement_ctx`, transaction-local, set immediately before the stamp writes and cleared immediately after
   (so a later direct write in the same transaction is still refused — fixture 258 GUARD). The owner gets no bypass.
6. **One reversal date, asserted.** Everything posts on today: the journal reversal uses `reversal_date_for(…)`, the cost-line triggers and the
   re-accruals use today; the function refuses (`ELECTRICITY_REVERSAL_DATE_SPLIT`) if those ever differ instead of splitting across two dates.
7. **Re-accrual: one journal per restored estimate** (`processing_cost`, source = the estimate, Dr 5110 / Cr 2200, memo "Cost restored … (bill …
   reversed)") — the same shape as the estimate's own accrual, so each cost line's journal trail stays its own.
8. **A state check before reversing**: the run lines must still be settled in the allocation's journal and the relieved estimates must equal the
   allocation's recorded count and amount, else `ELECTRICITY_ALLOCATION_STATE_CHANGED` (cannot happen while the stamps are guarded; it refuses
   rather than half-reverse).
9. **What the reversal record holds:** date, reason, reversal expense and journal, payment status and bank, bill amount, run lines removed (count,
   amount), estimates brought back (count, amount); the three amounts masked.
10. **`run_id UNIQUE` → a BEFORE INSERT guard plus a plain index**; the guard also refuses the same run twice within one allocation.
11. **`reverse_electricity_allocation` asks `module.finance.edit` only** (Q22 as written); Q28's "also view" applies to posting.
12. **The run-energy view reads only the live allocation's line** (needed once a run can carry two lines); the run page reads the share by
    allocation id.
13. **The F2 "now allocated" check takes the allocation advisory lock** when the expense relieved anything, and looks at electricity estimates only
    (only electricity can be allocated).
14. **The variance view filters `status = 'posted'`** on the relief expense — that also covers a relief reversed before this cut whose stamps were
    never cleared (live: 0).
15. **`processing_cost_entry_lookup` gains `relief_expense_id`** so the finance-gated expense page can say how many estimates a relief reversal brings
    back (the base table is processing-gated; reading it as finance would show "0", a refusal posing as a count).
16. **The expense page blocks, not hides.** The server-refused cases (an allocation's expense, settled through a payment, prepayment applied) render
    the button disabled with the reason and route, kept separate from the permission gate (record state ≠ permission).
17. **The allocation refusal carries the allocation id** (`EXPENSE_IS_ELECTRICITY_ALLOCATION|code|id`); the sentence names the page; the expense
    page links to the bill.
18. **"Every expense kind" in the fixtures** = every writer of expenses: ordinary supplier expense, employee-payee expense (the path expense claims
    and medical claims take through `record_expense`), month-end relief, electricity allocation, capital append — plus prepayment-applied.
19. **The trail shows the reversal on each covered run** through an up-hop stepping stone (run → its share line → the allocation, not shown → the
    reversal), and V37 on the operation page with the same generic sentence as the change history (no new operation-type wording).
20. **The allocation page was surveyed through scratch harnesses** (a copy of the real page fed canned rows: unreversed with the control, reversed
    with a long reason, and the list with a reversed row), run from a scratch copy of the tree — live has no allocation and this cut may not create
    one (the MES-5a-2 precedent).
21. **In the live proof, the payment that settles an expense is setup**, written as the owner through `record_payment_internal` (the function an
    approved payment request executes); every action the proof is about (post, reverse, relieve, the refused reversals, the refused stamp change)
    runs as a throwaway account.
22. **Mask rules +3** on the reversal's three amounts; counts, reason and dates are not masked.

## §8 · Assertions measured and found false or imprecise

1. **The brief's opening facts** (SHA, clean tree, 7 accounts enabled, approvals ON, `require_calibrated_since` NULL, nothing set) — all re-measured
   and as stated.
2. **Step 0 §11's "5b-2 window: the old electricity page has no reverse control (there are no live allocations anyway)"** — true; the window has a
   second face the Step 0 did not name: the *new* app against the *old* database fails on two finance pages (§6.4). Harmless by order of operations.
3. **Step 0 §7 "reverse_expense … no check like FREIGHT_HAS_SETTLEMENT"** — confirmed, and the same divergence exists for a **prepayment
   applied** to an expense, which Q24 did not name (decision 2).
4. **Step 0 §12 item 9** (electricity actual lines' accrual journals dated today) — still true and now relied on: the reversal posts everything on
   today and asserts it (decision 6).
5. **My first live dry run** failed on its own proof because a layout survey ran from a scratch copy at the same time (the scratch copy's live-lock is
   a different file) — a concurrency mistake of mine, not a migration defect; re-run alone it passed. **My first live proof** stopped at
   `TAX_CODE_REQUIRED` (live is GST-registered; the local rehearsal was not). Both rolled back, nothing kept.
6. **`docs/known-issues.md` `MES5A2-RELIEF-REVERSAL-ORPHANS`** said month-end relief soft-deletes; it does not — corrected (Q36), with the MES-5a-2
   hand-back's decision 9.
7. **`scripts/check-trail-wording.mjs` ㉓'s comment** said V37 shows only on the change history — true until this cut; struck in place, pointing at ㉔.

## §9 · Docs updated

`docs/forward-queue.md` (item 44: the MES-5b-1 window closed and the close-out results; item 45; MES group header and table rows 8b ✅ / 8c next) ·
`docs/known-issues.md` (`MES5A2-RELIEF-REVERSAL-ORPHANS` mechanism corrected and closed; `MES5A2-NO-ALLOCATION-REVERSAL`, `MES5A2-RELIEVE-SGD-LITERAL`,
`MES5B1-V37-NOT-ON-OPERATION-TRAIL` closed; `MES5B2-SETTLEMENT-STAMP-SIDE-DOOR` registered and closed; `MES5B2-PREPAYMENT-APPLIED-EXPENSE-NOT-REVERSIBLE`;
`MES5B1C-ADMIN-TASKS-VIEW-ALL-UNRULED` from step 1) · `docs/handbacks/MES-5a-2.md` (§7 decision 9 corrected) · `docs/role-matrix.md` (§8 row) ·
`docs/change-log.md` §21 · `db/migration-windows.tsv` (the window start) · `docs/surveys/AUDIT-TRAIL-0/labels.csv` (the new table) ·
`docs/surveys/MES-5b/MES-5b-1-CLOSEOUT.md` (step 1).
