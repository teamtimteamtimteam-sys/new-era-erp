# MES-7a Step 0 — hand-back (2026-10-15), with the MES-6b-2 close-out

**STOP GATE.** No code edit, no migration, no live write. The only writes are docs: the close-out (`e8abff7a`, "MES-6b-2 close-out") and this file
with the read-only query file beside it (`live-readings.sql`). Waiting on Tim's answers to Q1–Q26 (§12).

**Opening check.** First command **2026-10-15 22:22:17 CST**. Tree clean. `HEAD` = `origin/main` = `git ls-remote origin main` =
`1ca90256a1057f9761a35cd9a928777b067c583d`; after the close-out `e8abff7acbc3d67db862f1c0f90d931047a10aaf` (fresh clone, no `.env.local`:
`CI_OWN_EXIT=0`, `X_OWN_EXIT=0`). Files staged by explicit path only.

**Live readings (measured, read-only).** `live-readings.sql` at **22:41:17 CST**, as `postgres` (`rolbypassrls = true`) over direct psql to the pooler,
inside `BEGIN READ ONLY … ROLLBACK`, base tables and the catalog; `READ_OWN_EXIT=0`:

| Reading | Value |
|---|---|
| Fixed assets | **2**, both `equipment`, both active, neither in service: FA-2026-0001 Bosch Deep Discharging Machine (acq 2026-08-21) · FA-2026-0002 Mobile Discharging Solution (acq 2026-08-25) |
| Downtime | **1** — FA-2026-0001, open since 2026-08-23 18:55, reason "Test-1", not voided |
| Maintenance | **2** — FA-2026-0001: 2026-08-22 repair (capitalised) · 2026-08-23 service; neither linked to a downtime or an expense |
| Service intervals | 1 — FA-2026-0001 service every 90 days |
| Machines linked to operations | **0** |
| Processing runs | 14 (10 committed) · **with a machine 0 · with start and end 0** · with an operation 1 |
| Run indicators (`run_time_min`, `unplanned_stop*`, `cuts_this_run`) · run events | 0 · 0 |
| Devices | 2 gateways, 2 scales; 0 linked to a machine; no meter |
| Materials (live) by kind | battery_material 1 · packaging 1 · kind not stated 3 · **spare_part 0 · consumable 0**; safety stock set on 0 |
| Spare-part / consumable batches | **0** |
| Stock movements by type | receipt 27 · processing_consume 13 · processing_produce 17 · sale 11 · writeoff 11 · adjustment 5 · status_change in/out 7/7 · reversal restore/void 3/4 · transfer in/out 1/1 |
| Movement-type CHECK | `inventory_movements_movement_type_check` (12 types) · `_pair` · `_side` · `_sign` |
| Purchase orders by category | equipment_goods 11 |
| Document types · public base tables | 59 · 297 |
| Issued CODs (F10) | COD-2026-0001 (2026-09-08 02:21) · COD-2026-0002 (2026-09-08 10:37): snapshot keys `certificate, company, inbound_batch, licence, processing, provenance, supplier`; company keys all nine the letterhead prints; licence WDL-21-2-5380 (NEA); bytes stored for both; **company legal name and supplier name in the snapshot equal today's live values** |
| Standing state (close-out readings, 22:28 / 22:36 CST) | approvals ON (finance / cfo / 1,000) · 7 accounts, 0 disabled · admin 79 / 79 · `action.issue_coa` admin, cco · `action.ncr_decide` admin, cco, cto · `require_calibrated_since` NULL · 0 contracts / NCRs / CoAs · 0 throwaway accounts |

(A `pending_values` count in the same file read **0 rows as `postgres`** — that view resolves the reader's codes and `postgres` carries no JWT, so the
0 is a permission answer, not a measurement (AGENTS.md「一个『0 行』的读数,先问它是谁读的」). The pending-value arms are counted from the mirror
instead: 22 V-numbers in `db/views/pending_values.sql`.)

**How the facts were gathered.** Five read-only sub-agents (none connected to a database, ran a build or imported a script): `docs/known-issues.md`
in full (10,802 lines, every chunk); `docs/forward-queue.md` in full plus every MES Step 0 / hand-back, UNBLOCK-1, U1-B and the equipment docs; the
equipment / runs / devices / stock code map; the F9 / F10 code paths; the active run times of MES-6b-1 and MES-6b-2 from the session transcripts
(script `measure_6b.py`, kept in the job scratch directory). I read in full: AGENTS.md, MES-0 README, the MES-6b Step 0, the MES-6b-1 and MES-6b-2
hand-backs, `docs/mes-pending-values.md`, fixture 264; the specification PDF and `docs/role-matrix.md` were read in earlier blocks and re-checked
only where cited. Load-bearing claims were re-read at file:line today: `equipment_downtime.sql:35,59-71,83-85` · `inventory_movements.sql:22-27,88` ·
`guard_quality_hold.sql:25-28` · `stock_rollforward_monthly_all.sql:9` · `material_kinds.sql:81-83` · `inventory_ledger_triggers.sql:205,221` ·
`finance_journal_triggers.sql:14-22` · `accounts.sql:130,138-146` · `app/finance/assets/[id]/page.tsx:48,69` · `app/operation/equipment/page.tsx:9` ·
`equipment_usage.sql:45` · `app/inbound/[id]/cod/pdf/route.tsx:36-45,107-116,149-152` · `issue_coa.sql:40-56` · `renderCoa.tsx:13-21`.

Tags: **[M]** measured · **[I]** inferred from code reading · **[Q]** quoted from an earlier record · **[S]** specification · **[R]** a Tim ruling on record.

---

## §0 · The MES-6b-2 close-out (step 1)

All of it is in `MES-6b-2-CLOSEOUT.md` beside this file; summary:

1. **Broken window closed** (`docs/forward-queue.md` item 50): start 20:45:44 · end lower bound 22:11:53 (push of `1ca90256`, reflog) · end upper
   bound 22:22:17 (this session's first command, holding Tim's "deployed" — a relay). **At least 1 h 26 min 09 s, at most 1 h 36 min 33 s.** In the
   window: 0 certificates, 0 requests, 0 bucket objects, 0 new assays / NCRs / movements; change log only MES-6b-2's own throwaways, INSERT = DELETE.
2. **a — fixture list:** all 15 items covered (table with file:line in the close-out §2 a). Weaker spots recorded, not missing, not fixed: **W1** the
   409 branch and "rendered from the snapshot" are route behaviour no SQL fixture can reach — proved once by the rolled-back live proof, no repeatable
   check; **W2** the cco grant of `action.issue_coa` is pinned by the migration's own proof and today's reading, not by a fixture. Documentation gap:
   the MES-6b-2 hand-back's fresh-clone line points at a chat report — recorded in the queue.
3. **b — usability:** deployed app, clones of cco · warehouse · cfo · admin: batch page / CoA list / inventory / CoA preview, **16 fetches, all 200**;
   the CoA section, feed chemistry and the named refusal render for all; warehouse and cfo see the issue button disabled naming `action.issue_coa`.
   Local rebuild with my own output batches and final assays: cco issued through the route (200, COA-2026-0001), warehouse refused by code (400,
   nothing issued), all four download the stored PDF ("Issued by Clone cco, Chief Commercial Officer"), a `coa_void` raised by cco shows in the
   cfo clone's CFO request list with Approve pressable (warehouse: disabled, names `module.finance.view`). Nothing missing or not working.
4. **c — issuers vs the PDF font stack:** live holders of `action.issue_coa`: admin@ → "Tim, Chief Financial Officer"; sandra@ → "Sandra, Chief
   Commercial Officer". The repo's own guard (Google Sans + Noto Sans SC, 7,290 code points) finds **0 unrenderable characters** in either; control
   «Lim ≤» → `≤` refused.
5. **d — the 22 self-taken decisions** listed by title in the close-out §2 d.

So step 2 went ahead.

## §1 · What grilling changed in MES-7a's scope

1. **The MTBF denominator exists in the schema but is empty on live** [M + I]. Q71 [R] defines operating hours as the sum of run durations on a
   machine; MES-4a added `processing_runs.started_at / ended_at` (`processing_runs.sql:68-69`) and `assert_run_equipment` makes the machine
   required only where an operation has linked machines (`assert_run_equipment.sql:13-55`). Live: **0 runs carry a machine, 0 carry times, 0
   operation ↔ machine links**. The report can be built and fixtured, and will read "no operating hours recorded" for both machines until Tim
   links machines to operations (his MES-4a close-out action, still open). Q5.
2. **Three records of a stop exist and nothing links them** [I]: `equipment_downtime` (per machine, timestamped, free-text `reason`,
   `equipment_downtime.sql:35`), `processing_run_events` of type `unplanned_stop` (per run, `duration_min`), and the indicators
   `unplanned_stops` / `unplanned_stop_min` (`operation_type_fields.sql:96-97,101-102`). MTBF/MTTR must count one of them, or failures are counted
   twice. Q4, Q19.
3. **Equipment is recorded only from a finance page** [M]: every downtime / maintenance / interval form lives on `/finance/assets/[id]`, gated by
   `module.finance.view` (`page.tsx:48`) and shown with `module.processing.edit` (`:69`); `/operation/equipment/[id]` is read-only. The three tables
   have **no RPCs** — refusals are constraint names (known issue EQP-2d, `known-issues.md:4336-4376`), which MES-0 absorbed into MES-7a
   (README:667). A downtime cause and a parts issue cannot be added cleanly without those functions. Q6.
4. **The spare-part dictionary row contradicts Q70** [Q + R]: `material_kinds.sql:81-83` (PROC-0b N3, a Tim ruling) says spare parts are
   "不按批次追溯"; MES-0 Q70 (Tim, 2026-10-05) says "received as batches of kind `spare_part` … No non-batch inventory". A RUNTIME CONFIG note
   whose meaning changes must be re-read in the same commit (AGENTS.md). Q2.
5. **Issuing a part is a money event, and the chart has no account for it** [M]: an inbound batch's value sits in **1200 Inventory – Raw Materials**
   (`inventory_ledger_triggers.sql:205`); there is no repairs / maintenance expense account (`accounts.sql`: 5xxx are processing COGS, 6000 rent,
   6100 salaries, 6200 utilities, 6300 transport, 6400 professional fees, 6500 bank charges, 6700 depreciation, 6900 misc).
   `docs/fixed-asset-procedures.md:113-114` already says repair, service and wear parts go to "6xxx 的维修科目" — an account that does not exist.
   And `reprice_inbound_batch` splits a later price change into 1200 (in stock) and **5000 Material Cost** (consumed) — a repriced, already-issued
   part would land in material cost. MES-0 sized this cut without any GL work. Q11, Q13.
6. **A new movement type slips past four existing guards and reports silently** [I]: the `sign` and `side` CHECKs end in `ELSE true`; the quality hold
   blocks only the types it lists (`guard_quality_hold.sql:25-28`); `stock_rollforward_monthly_all` drops an unlisted type from every column by
   design ("期末于是对不上库存", `:9`); `batch_balance_tree_all.sql:92-97`, `MovementMixChart.tsx:40-44` and `check-enum-mirrors.mjs:44-51`
   enumerate the types. Q12, Q15, Q23.
7. **F9 cannot be closed in SQL alone** [I]: the issuer's name and position are resolved inline in `issue_coa` (`:40-50`); the preview assembly sets
   `issuer` to NULL (`coa_certificate_data.sql:15-17`), so the route's pre-issue font check skips them (`route.tsx:88-94`, comment `:90`). The fix
   is one shared resolver called by `issue_coa` and by the route before minting. Q8.
8. **F10 is three reads, not one** [I]: the COD POST re-reads live data after issuing (`route.tsx:149-152`, under the comment that says "the frozen
   one"); every render takes the **letterhead from live `company_profile_masked`** (`render()`, `:36-42`), not from the snapshot; and a bare GET of an
   issued certificate re-renders it **in issued mode from live data** (`:107-116`). The COD route also has **no font guard** — a `≤` would print as
   nothing. Q9.
9. **Size** [M + I]: with the RPC, GL, F9 and F10 work, one cut estimates at ≈ 4 h 50 – 7 h 15 calibrated, beyond any measured MES cut (largest
   3 h 55 active). Q1.

## §2 · (a) What MES-7a is, and its exact contents

**MES-0 §8.2 row MES-7a** [Q, `docs/surveys/MES-0/README.md:705`]: functions **21 spare parts · 22 MTBF/MTTR**; "`maintenance_part_issues`, issue
movement type, `downtime_causes`; downtime cause/source; MTBF/MTTR report"; one migration; 2.5 tables / 2 pages; extra "`inventory_movements` type
change: 1–2 h"; estimate **4 h 35 – 8 h 30**. Rulings on record [R, MES-0 Q1–Q96 accepted, README:1141]:
- **Q70** "Received as batches of kind `spare_part`; issued by a new movement type linked to the maintenance record. No non-batch inventory."
- **Q71** "Operating hours = the sum of run durations on that machine (from Q42); failure = downtime with a failure cause. This answers the open
  "分母" … for reliability only, not for availability or OEE."
- **Q89 / §4.1** spare-part issue: no approval ("an inventory movement, like a processing consume").
- **§4.3** trail subject `maintenance_part_issue`.
- **V21** spare-part minimum stock (cto / vendor, equipment acceptance) · **V22** MTBF/MTTR operating-hours basis (answered by Q71).
- **§6 / README:626** "MES-7a adds cause/source to downtime and controller-sourced rows" — built on U1-B's void columns
  (`equipment_downtime.sql:51-56`; `void_equipment_downtime`; Q15 of UNBLOCK-1, `docs/handbacks/U1-B.md:72`).
- **§7 / README:667** absorbed: `AT1B-EQUIPMENT-LIST-EVERY-ASSET` (`known-issues.md:10050-10054`), unmonitored machines (`:4378-4398`),
  equipment tables without functions (`:4336-4376`).
- README:219 / :337: the **replacement record** half of the tool cut count (the counter itself is MES-4a's `cuts_this_run`).

**Folded in (proposed in this brief, for Tim to confirm):** **F9** (CoA issuer checked against the font stack before a number is minted) and **F10**
(the COD PDF renders from its frozen snapshot).

**Proposed contents, by recommended cut (Q1):**

**MES-7a-1 · Reliability and equipment recording (+ F9, F10)**
- **Tables:** `downtime_causes` (dictionary: code, names, `class` = `failure` · `planned` · `external`, active, sort; no "other" row).
- **Columns:** `equipment_downtime.cause_code` (→ `downtime_causes`; required on rows recorded from this cut, NULL on the one live row = "not
  classified") and `source` (`manual` · `device`; `device` reserved — no controller transform).
- **Functions:** `open_equipment_downtime`, `close_equipment_downtime`, `correct_equipment_downtime` (cause included), `record_equipment_maintenance`
  (with an optional downtime of the **same machine, not voided**), `save_equipment_service_interval` — named refusals instead of constraint names;
  direct INSERT / UPDATE policies dropped (void stays `void_equipment_downtime`). `equipment_reliability(p_from, p_to)` (MTBF / MTTR per machine,
  Q5). **F9:** `coa_issuer()` — the one issuer resolver, called by `issue_coa` and by the route before minting. **F10:** `issue_cod` also returns its
  snapshot (additive key).
- **Pages:** `/operation/equipment/[id]` gains the downtime, maintenance and interval panels (moved from `/finance/assets/[id]`, which keeps reading
  them and keeps capitalisation); `/operation/equipment` lists only `equipment` assets and shows "monitored or not"; a reliability report
  (`/operation/equipment/reliability`). **F9:** the CoA issue form says "You will be named as <name>, <position>" and refuses before pressing when
  that line cannot be printed; a "Save PDF" button for an issued certificate with no stored bytes (Q24). **F10:** the COD route renders from the
  snapshot (POST and bare GET), takes the letterhead from it, streams stored bytes for an issued / void certificate, and runs the font guard before
  issuing.
- **Arms / pending values:** none (Q18).

**MES-7a-2 · Spare parts**
- **Tables:** `maintenance_part_issues` (maintenance record · inbound batch · quantity · the movement · issued at / by; append-only; a return is a row
  of its own citing the issue, with a reason).
- **Columns / types:** `inventory_movements.movement_type` + `maintenance_issue` (out, inbound side, `available`) and `maintenance_return` (in, citing
  the issue); the `sign` / `side` / `pair` CHECKs name both.
- **Functions:** `issue_spare_parts(p_maintenance_id, p_lines)`, `return_spare_parts(p_issue_id, p_qty, p_reason)`; the GL posting (Q11, Q13);
  `guard_quality_hold` blocks `maintenance_issue`; `stock_rollforward_monthly_all`, `batch_balance_tree_all` learn the two types.
- **Pages:** an "Issue parts" form and an issued-parts list on the maintenance record (operation equipment page); spare-part receipts through the
  existing receipt pages.
- **Pending value:** **V21** (Q17).

**Left to later cuts or registered** [Q / I]: availability and OEE (Q71 [R] answers the denominator for reliability only; deferred at MES-5a Step 0
:225-227 with no cut); consumables and non-batch inventory (MES-0 absorbed spare parts only, README:660; Stage 2 `forward-queue.md:1065-1066`);
machine ↔ part list and criticality (Q16); V12 tool-replacement cut count (Q18); the controller / workstation transforms (no payload format — the
standing rule); retention ↔ fault link (R7, `docs/equipment-payment-milestones-and-retention.md:300-317`); service-interval granularity
(`known-issues.md:4296-4334`); incidents and inspections (MES-7b).

## §3 · (b) Each function: what is recorded, where it is entered, where it shows, and how it relates to today's layers

| | Spare parts (21) | MTBF / MTTR (22) |
|---|---|---|
| **Recorded** | a receipt = an inbound batch of a `spare_part` material (existing receipt functions, unit as stated, e.g. pcs); an issue = one `maintenance_issue` movement + one `maintenance_part_issues` row tying batch, quantity and maintenance record; a return = `maintenance_return` + its row | a downtime row gains a **cause** (failure · planned · external class) and a **source**; nothing new is stored for MTBF / MTTR — they are computed |
| **Entered** | receipt: `/inbound/new` or against a PO (consumables category allowed for spare parts, `guard_po_line_category.sql:21-25`); issue / return: the maintenance record on `/operation/equipment/[id]` (`module.inventory.edit`, Q12) | downtime open / close / correct with a cause: `/operation/equipment/[id]` (`module.processing.edit`) |
| **Shows** | the maintenance record (parts and value to `data.view_prices` holders), the batch page and its trail, inventory roll-forward and balance tree, safety-stock arm (V21) | `/operation/equipment/reliability` (per machine and range: operating hours, failures, MTBF, MTTR, with the denominator stated) and a line on each machine page |
| **Equipment ledger** (`fixed_assets`, `category = 'equipment'`) | parts are issued against a maintenance record of a machine; no part ↔ machine list (Q16) | per machine; only `equipment` assets (Q7) |
| **Maintenance** (`equipment_maintenance`) | the issue's parent; a capitalised record refuses parts (Q14); `downtime_id` gets its first writer, guarded (Q6) | a repair may cite the failure it fixed |
| **Usage** (`equipment_usage`, `equipment_service_status`) | unchanged | operating hours come from run times, not from the kg-based usage view; the stale "no hours" comments (`equipment_usage.sql:4-8`, `equipment_downtime.sql:69-70`, `equipment_service_intervals.sql:102-104`) are corrected |
| **Machines ↔ operations** (`operation_type_equipment`, 0 live) | — | the only path to a run with a machine (`assert_run_equipment`); empty live → the report reads "no operating hours recorded" |
| **Runs** (`processing_runs`, events, indicators) | — | denominator = union of `[started_at, ended_at)` of committed, not-reversed runs on the machine in the range; run events and indicators are **not** counted (Q4, Q19) |
| **Meters / devices** (`devices.equipment_id`, `meter_readings`) | — | unchanged; the `device` source value is reserved for a future controller transform |

## §4 · (c) Effect on existing pages, functions and fixtures

- **Functions changed (7a-1):** `issue_coa` (calls `coa_issuer()`, same refusals, same order before minting), `issue_cod` (return gains `snapshot`),
  `trail_subjects` / `trail_subject_members` / labels (cause, source, new functions), `void_equipment_downtime` (unchanged body; still the only void
  path). Direct writes to `equipment_downtime` / `equipment_maintenance` / `equipment_service_intervals` move behind functions; `guard_downtime_write`
  and `guard_downtime_period` keep working underneath.
- **Functions changed (7a-2):** the movement-type CHECK and the `sign` / `side` / `pair` CHECKs, `guard_quality_hold`, `stock_rollforward_monthly_all`,
  `batch_balance_tree_all`, `reprice_inbound_batch` / `reprice_split` (Q13), `pending_values`, `inventory_control_reconciliation` (re-read: the
  issued share leaves 1200), `deleted_records` (type list, `:62,78`).
- **Pages:** `/operation/equipment`, `/operation/equipment/[id]` (writes move here), `/finance/assets/[id]` (forms removed, read and capitalise kept),
  the new reliability page, `/output/[id]/edit` (F9 line), `/quality/coa/[id]` (Save PDF), `/inbound/[id]/cod/pdf` route (F10),
  `/inventory/reports/*` (two new movement types), `/settings/dictionaries` (downtime causes), `/settings/pending-values` (V21).
- **Fixtures:** new **265** (7a-1: CAUSE · SOURCE · RPC refusals · LINK same machine / not voided · MTBF / MTTR arithmetic incl. union of overlapping
  runs, zero-failure and zero-hours wording, voided and open rows excluded · F9 resolver = `issue_coa`'s · F10 `issue_cod` returns the stored
  snapshot) and **266** (7a-2: ISSUE · RETURN · GL · HOLD · REPRICE routing · ROLLFORWARD ties · V21 arm). Changed without weakening: 108, 109, 120,
  248 (downtime and maintenance now through functions; the same assertions), 253 (machine links), 111 (arm list unchanged unless Q17 adds none — V21
  is a pending value, not an arm), 257 (balance and roll-forward know the new types), 263 (hold blocks `maintenance_issue`), 56 (pair / sign),
  264 (issuer through `coa_issuer`), 195 (COD issue return), 234 / 235 (new tables bound, exclusions stay 8), `check-enum-mirrors`,
  `check-trail-wording` (arms ㉚ and ㉛). Every new arm fault-injected; injections re-run on a fresh rebuild after the last database edit.

## §5 · (d) Approvals, trails, change log, masking

- **Approvals:** none new (MES-0 §4.1 [R]: a part issue is an inventory movement like a processing consume; downtime, causes and maintenance are
  records of events). A return is a record too. Approvals stay ON, finance / cfo / 1,000. Q10.
- **Trails:** `downtime_causes` under the dictionary trail; downtime cause / source under `equipment` (already the home of downtime);
  `maintenance_part_issues` as a member of `equipment` (home) and of `inbound_batch` (through the movement) — **no subject of its own**, because it has
  no page of its own (MES-0 §4.3 listed one; Q20). Wording arms ㉚ (7a-1) and ㉛ (7a-2), each with a drift fault and a part fault.
- **Change log:** both new tables bound (`gen_change_log_bindings.py --only`); exclusions stay 8.
- **Masking:** none new. Neither table carries money: the GL entry carries the value (decision 1 — finance readers see the ledger), and the
  maintenance page shows a part's value only to `data.view_prices` holders through the existing landed-cost reader. Q20.

## §6 · (e) "Not yet set" values MES-7a adds

| # | value | lives on | page | arm reads | permission | supplied by | when |
|---|---|---|---|---|---|---|---|
| V21 | Spare-part minimum stock, per spare-part material | `materials.safety_stock_qty` (exists, `materials.sql:49-51`; already drives the `safety_stock_below` reminder, `operations_now.sql:344-352`) | the material editor (`/materials/<id>/edit`) | each live `spare_part` material with `safety_stock_qty` empty **and at least one receipt** (V9 precedent: no rows nobody can act on) | `module.materials.view` | cto / the equipment vendor's recommended spares list | at equipment acceptance (7a-2) |

**V22** (operating-hours basis) is answered by Q71 [R] and adds no value. **V12** (tool-replacement cut count, MES-0 README:577) was assigned to MES-4a
and never built or recorded anywhere (`grep V12 docs/` → only MES-0) — Q18 registers it, it is not built here. No other number is introduced: no "open
too long" for downtime, no MTBF target, no availability.

## §7 · (f) F9 and F10 — today's code paths, effects, fixtures

**F9 — MES6B2-ISSUED-WITHOUT-BYTES** (`known-issues.md:10783-10793`)
- **Today:** the route POST runs ⓪ a font check on `coa_certificate_data` (the preview assembly), ① `issue_coa`, ② `renderCoaPdf(snapshot)`, upload,
  `record_coa_issue` (`route.tsx:88-116`). The preview sets `issuer` NULL (`coa_certificate_data.sql:15-17`) and the guard skips NULL text
  (`lib/pdfFontCoverage.ts:251`), so ⓪ never sees the name or position; `issue_coa` resolves them inline (`:40-50`) after the blockers and before
  `next_coa_code` (`:52`); `renderCoaPdf` re-runs the guard and throws (`renderCoa.tsx:18-20`) → 500 "Issue failed" after the number is minted.
- **Change:** `coa_issuer()` (DEFINER, STABLE: `account_person(auth.uid())` → preferred else legal name, `positions.title`; raises
  `COA_ISSUER_NOT_AN_EMPLOYEE` / `COA_ISSUER_POSITION_MISSING|<name>`); `issue_coa` calls it (one implementation); the route's ⓪ fills `issuer` from
  it before `coaUnrenderable` and refuses 400 with nothing minted; the issue form shows the printed line and the refusal before pressing.
- **Effect:** live today both issuers render (close-out §2 c); 0 certificates exist. The known issue narrows to upload / hash failures — closed
  entirely if the Save PDF button is built (Q24).
- **Fixtures:** 264 gains an arm (`coa_issuer()` agrees with `issue_coa`'s snapshot for preferred / legal / no position / not an employee); the
  font refusal is JavaScript — proved by the local route probe and a live-proof step with a throwaway issuer whose position contains `≤`.

**F10 — MES6B1-COD-PDF-RENDERS-LIVE** (`known-issues.md:10730-10737`)
- **Frozen today:** `certificates_of_destruction.snapshot` = `cod_certificate_data()` at issue with the certificate block patched
  (`issue_cod.sql:58-68`): inbound batch (id, code, material code and name, quantity, unit, arrival date, PO code), supplier (name, code), processing
  (completed on), company (all nine letterhead fields), licence (cert no, issuing body, valid from / until, scope), certificate (id, code, status,
  issued at / by, token, completed on), provenance (run ids). Immutable after issue (`guard_cod_immutable_after_issue.sql:12-23`). No key has
  changed since COD-1 / COD-2 (migrations 2026-09-07, 2026-09-08; MES-2 touched `issue_cod` only for the calibration gate).
- **What the PDF reads today:** POST → `issue_cod`, then **`cod_certificate_data` again, live** (`route.tsx:149-152`); `render()` takes the letterhead,
  "Processed by" and the statement from **live** `company_profile_masked` (`:36-42`, `company.ts:43-67`); bare GET re-renders an issued certificate
  in issued mode from live data (`:107-116`; the `void` branch there is unreachable because `cod_certificate_data` filters out void rows). GET
  `?cod=` streams stored bytes with the sha256 re-check and 409 (`:76-105`) — correct already.
- **Change:** POST renders from the snapshot `issue_cod` returns; `render()` takes the company from the snapshot; bare GET of an issued or void
  certificate streams the stored bytes (a pending one keeps the watermarked internal preview from live data); the font guard runs before
  `issue_cod` on the pending assembly and inside `render()`; the misleading comment is corrected. Not frozen and not needed in the snapshot: the
  verification host in the QR (the request origin at issue, already inside the stored bytes) and the void status (live; the page shows it).
- **Effect on already-issued CODs:** COD-2026-0001 and -0002 keep their stored bytes byte for byte (GET `?cod=` unchanged); their snapshots equal
  today's live company and supplier (measured), so any re-render would print the same content; neither is re-issued.
- **The verify page** (`/verify/cod/[token]`, `cod_verification`) already reads the snapshot plus live status (`cod_verification.sql:38-41`) —
  unaffected. One false comment found there (`:96-97` says phone / email / website are not on the paper; the stacked letterhead prints them,
  `CompanyLetterhead.tsx:104-106`) — Q26.
- **Fixtures:** 195 gains an arm (`issue_cod` returns exactly the stored snapshot); the route is proved by the local probe (render text = snapshot,
  bare GET = stored bytes) and a rolled-back live-proof step on a throwaway inbound batch.

## §8 · (g) Migration shape and broken window

- **Shape:** one migration per cut (two if Q1 = two), dated from `date`, built from the mirrors, COMMIT → ROLLBACK dry run on live first; 7a-1
  before 7a-2 (the parts issue hangs on the maintenance function 7a-1 builds).
- **7a-1 window (old app + new DB):** the old `/finance/assets/[id]` forms write the three equipment tables directly. If the cut drops the direct
  INSERT / UPDATE policies and requires a cause on new downtime, **recording downtime, maintenance and intervals from the old app fails** until the
  deploy (derived; who uses it live: the one downtime and two maintenance rows are test rows from August). CoA issue: unchanged signature and
  refusals. COD: `issue_cod` gains a return key the old route ignores. Q21.
- **7a-2 window:** a widened CHECK and new tables; the old app never writes the new types. Nothing breaks.
- **Existing records:** none changed. The open downtime "Test-1" stays open with cause NULL ("not classified", counted as neither failure nor
  planned); the two maintenance rows untouched; 0 spare-part materials or batches; 2 issued CODs and their bytes untouched. No back-fill (Q94 [R]).

## §9 · (h) Time estimate — two numbers, measured calibration

**Measured** [M, transcripts; active = brief → push (6b-2 from the close-out push, the convention of the 6a-2 row), gaps ≥ 10 min excluded unless
they end in a tool result; floor / work split by tool-call class, ±5–10 min; script `measure_6b.py`]:

| cut | active | floor | work | Step-0 est. low | active ÷ low | work ÷ est. work low |
|---|---|---|---|---|---|---|
| MES-1 … MES-6a-2 | (13 rows, `docs/surveys/MES-6b/STEP0-HANDBACK.md` §11) | | | | | |
| MES-6b-1 | 3 h 05 | 1 h 40 | 1 h 26 | 6 h 50 | 0.45 | 0.28 |
| MES-6b-2 | 3 h 07 | 2 h 10 | 0 h 57 | 5 h 40 | 0.55 | 0.24 |
| MES-6b-1 close-out | 0 h 25 | 0 h 13 | 0 h 12 | — | — | — |

6b-1 excludes Tim's two waits (49.6 min for the `!` apply, 30.4 min before his push); counting both, 4 h 25 (0.65). 6b-2's floor carries ≈ 43 min
of failed runs (a backup that hung on a dead socket, a smoke that aborted on its own id query). Floor components (6b-1 / 6b-2, min): backup 14 / 41 ·
full gate 16 / 13 · smoke 23 / 45 · layout 22 / 6 · apply + dry run 7 / 6 · offline gate 6 / 3 · build 3 / 4 · live proof 6 / 12 · fresh clone 1.5 /
1.3. **Medians:** active ÷ low **0.76** (15 cuts) / **0.59** (last five); work ÷ est. work low **0.57** (15) / **0.35** (last five, 0.24–0.66).
**Floor used: 1 h 45 – 2 h 30** (the last four floors measured 1 h 40 – 2 h 18; plus the fresh-clone build and one rerun at the top). This close-out
+ Step 0 block: ≈ 25–30 min close-out (it rendered pages, locally and on the deployed app) + the Step 0.

**Work (raw estimate, minutes):**

| part | 7a-1 reliability + recording + F9 + F10 | 7a-2 spare parts |
|---|---|---|
| orientation | 5 – 5 | 5 – 5 |
| database | causes + cause / source + the five equipment functions + link guard 60 – 90 · reliability function 30 – 45 · housekeeping 15 – 25 · F9 resolver + route 35 – 55 · F10 route + `issue_cod` return + guard 40 – 60 | two movement types + CHECKs + issue / return functions + GL + reprice routing + hold + roll-forward / balance tree 80 – 120 · V21 + kind note 15 – 25 |
| pages | equipment panels moved + reliability page 50 – 80 | issue form + issued list 40 – 60 |
| fixtures + injections | 50 – 80 | 45 – 70 |
| live proof | 15 – 25 | 15 – 25 |
| messages, docs, static | 15 – 25 | 15 – 25 |
| **work** | **5 h 15 – 8 h 10** | **3 h 35 – 5 h 30** |
| **calibrated work (× 0.35, last five)** | **≈ 1 h 50 – 2 h 50** | **≈ 1 h 15 – 1 h 55** |

**Estimates — process floor + work, two numbers per cut:**
- **MES-7a-1 Reliability and equipment recording (+ F9, F10):** floor **1 h 45 – 2 h 30** + work **5 h 15 – 8 h 10** raw (calibrated **1 h 50 – 2 h 50**)
  = **7 h 00 – 10 h 40** raw; **≈ 3 h 35 – 5 h 20** calibrated.
- **MES-7a-2 Spare parts:** floor **1 h 45 – 2 h 30** + work **3 h 35 – 5 h 30** raw (calibrated **1 h 15 – 1 h 55**) = **5 h 20 – 8 h 00** raw;
  **≈ 3 h 00 – 4 h 25** calibrated.
- **One cut instead:** floor 1 h 45 – 2 h 30 + work 8 h 50 – 13 h 40 raw (calibrated 3 h 05 – 4 h 50) = **10 h 35 – 16 h 10** raw; **≈ 4 h 50 – 7 h 20**
  calibrated — above every measured MES cut.
- **F9 and F10 alone** (if Q1 moves them out): work 75 – 115 min raw (≈ 25 – 40 calibrated); 7a-1 without them ≈ 3 h 10 – 4 h 40 calibrated.
- MES-0's own figure for MES-7a was 4 h 35 – 8 h 30 (floor 1 h 30 – 2 h 30), sized before the GL account, the equipment functions and F9 / F10.

---

## §12 · Every open question, with a recommended answer and its evidence

Grilling is a design tree. **Round 1** is the frontier — questions whose prerequisites are settled. **Round 2** questions depend on a round-1
answer; each names it, and its recommendation assumes the round-1 recommendation. If Tim answers a round-1 question differently, the round-2
questions under it are re-asked.

### Round 1

❓ **Q1** - **One cut or two, and where F9 / F10 ride**: as one cut MES-7a is ≈ 4 h 50 – 7 h 20 calibrated, above every measured MES cut (largest
3 h 55 active). It is two proof shapes — read-side reliability over records of events (a dictionary, functions, a report) and a stock movement that
posts money (an inventory type, GL, a reconciliation proof). F9 / F10 are PDF-route proofs with storage, the shape of MES-6b-2.

➡️ **Two cuts: MES-7a-1 Reliability and equipment recording (+ F9, F10)** ≈ 3 h 35 – 5 h 20 calibrated, then **MES-7a-2 Spare parts** ≈ 3 h 00 –
4 h 25. 7a-1 first: the parts issue hangs on the maintenance function it builds. F9 / F10 ride with 7a-1 because neither touches stock or the ledger;
if Tim wants 7a-1 smaller, move them to 7a-2 (7a-1 ≈ 3 h 10 – 4 h 40).

❓ **Q2** - **Spare parts: batches or not**: `material_kinds.sql:81-83` (PROC-0b N3, Tim) says spare parts "挂在一台机器上、有关键度,而且【不按批次追溯】";
MES-0 Q70 (Tim, later) says "received as batches of kind `spare_part` … No non-batch inventory"; every movement must name exactly one batch
(`inventory_movements.sql:88`).

➡️ **Q70 stands: a spare-part receipt is an inbound batch — a lot that carries quantity, location and cost, with no traceability claim beyond
"which receipt it came from".** Rewrite the dictionary note in the same commit (RUNTIME CONFIG meaning change): "received as lots so stock and cost
are counted; issued to a maintenance record; no per-piece traceability". The machine link and criticality the note mentions are Q16.

❓ **Q3** - **Downtime cause**: `reason` is free text (`equipment_downtime.sql:35`); Q71 [R] needs "failure = downtime with a failure cause".

➡️ **A `downtime_causes` dictionary with a class `failure` · `planned` · `external`** (no "other" — the catch-all rule), edited in
`/settings/dictionaries` by `module.processing.edit`; **seeded with one cause per class** (`breakdown` · `planned_maintenance` · `external_stop`) and
nothing finer — the plant's own cause list is Tim's / cto's data. `cause_code` required on downtime recorded from 7a-1 on (an INSERT-time check, the
MES-4a precedent); the live "Test-1" row stays NULL and reads "not classified". `reason` stays as the free-text note.

❓ **Q4** - **Downtime source**: MES-0 (README:626) gives MES-7a "controller-sourced rows"; no controller has a payload format, and the standing rule
forbids a transform on an invented one.

➡️ **`source` = `manual` · `device`, every row `manual` today; `device` is reserved and no transform is built.** A downtime row never cites a run
event; the three stop records stay independent (Q19).

❓ **Q5** - **MTBF / MTTR definitions** (Q71 [R] fixed the basis; the arithmetic is open):
- operating hours: the **union** of `[started_at, ended_at)` of committed, not-reversed runs on the machine inside the range (a plain sum
  double-counts overlapping runs — nothing stops two runs overlapping on one machine);
- failures: downtime rows of class `failure`, not voided, **started** inside the range; MTTR over the **closed** ones;
- MTBF = operating hours ÷ failures; zero failures → "no failure in N h of operation", never a number; zero hours → "no operating hours recorded";
- the range is chosen on the page (defaults to the machine's whole record — no invented window); availability and OEE stay out.

➡️ **As listed.** The page states the denominator in words beside each figure, and reports how many runs had no machine or no times in the
range (the honest reason the numbers are empty today: 0 runs carry a machine).

❓ **Q6** - **Where equipment is recorded, and through what**: today only on `/finance/assets/[id]` (finance gate, `page.tsx:48`), by direct table
writes with constraint-name refusals (EQP-2d, absorbed by MES-0 README:667); `equipment_maintenance.downtime_id` has no writer and no guard.

➡️ **Move the downtime, maintenance and interval forms to `/operation/equipment/[id]`; replace the direct writes with five functions** (open /
close / correct downtime, record maintenance, save interval) that refuse by name; drop the direct INSERT / UPDATE policies (void stays its own
function, DELETE stays refused). The finance page keeps reading them and keeps capitalisation. Maintenance may cite a downtime of the **same
machine, not voided** (`MAINTENANCE_DOWNTIME_OTHER_MACHINE` · `…_VOIDED`). Code unchanged: `module.processing.edit` (live: admin, cco, cto).
Whether warehouse should record downtime is a grant question for Tim (§13), not changed here.

❓ **Q7** - **The absorbed housekeeping** (README:667) and stale records:

➡️ **In 7a-1:** `/operation/equipment` lists only `equipment` assets (`equipment_usage.equipment_category` exists since MES-4a, `:45`; the page comment
`:9` is stale) — closes `AT1B-EQUIPMENT-LIST-EVERY-ASSET`; a "monitored / not monitored" column from `equipment_service_status.monitored` — closes the
unmonitored-machines entry; the five functions close EQP-2d's RPC entry. Correct in place: the three "no run times" comments
(`equipment_downtime.sql:69-70`, `equipment_usage.sql:4-8`, `equipment_service_intervals.sql:102-104`), `commit_processing_run.sql:161-166`,
`equipment_maintenance.sql:97` ("no UPDATE policy" while one exists at `:155-159`), the MES-0 citations (`:58-63` → `:67-71`, `:84` → `:88`).

❓ **Q8** - **F9 — the issuer checked before a number is minted**:

➡️ **One resolver `coa_issuer()` used by `issue_coa` and by the route** (§7): the route fills the issuer into its pre-issue font check and refuses
400 with nothing minted; the issue form shows "You will be named as <name>, <position>" and, when a character cannot be printed, the refusal
before pressing (visible, unpressable, with its reason). Same refusal codes, same order inside `issue_coa`.

❓ **Q9** - **F10 — the COD PDF renders from its snapshot**:

➡️ **POST renders from the snapshot `issue_cod` returns; the letterhead comes from the snapshot; a bare GET of an issued or void certificate
streams the stored bytes; a pending certificate keeps the watermarked internal preview from live data; the font guard runs before `issue_cod`;
the misleading comment goes.** The QR host stays the request origin at issue (it is inside the stored bytes; the production domain is PUR-1 ②'s
own item). The two issued CODs keep their bytes; their snapshots equal today's data, so nothing they print changes.

❓ **Q10** - **Approvals**: MES-0 §4.1 [R] — spare-part issue needs none.

➡️ **None new.** Issue and return are inventory events; causes, downtime and maintenance are records of events. Approvals ON, finance / cfo /
1,000, unchanged.

❓ **Q11** - **The ledger for a part issue**: the batch's landed cost sits in 1200 (`inventory_ledger_triggers.sql:205`); no repairs / maintenance
expense account exists, and `fixed-asset-procedures.md:113-114` names one ("6xxx 的维修科目").

➡️ **Issue: Dr a new expense account "Repairs & Maintenance" / Cr 1200 at the batch's landed unit cost × quantity; return: the reverse.** The account
is `is_system` (the engine names it); **its code and names are Tim's / the accountant's** — proposed `6800`. Stock stays in 1200 (the inventory
valuation views already include every inbound batch, so the control reconciliation stays one rule). The proof: AP list = ledger and the inventory
control reconciliation unexplained 0.00 after an issue and a return, inside a rolled-back transaction.

### Round 2 (each depends on the round-1 answer named)

❓ **Q12** - **(Q2, Q11) The issue itself**: what moves, who may, how it is corrected.

➡️ **`maintenance_issue` (negative, inbound side, `available` bucket) and `maintenance_return` (positive, citing the issue, with a reason), written only
by `issue_spare_parts` / `return_spare_parts`** (direct movement inserts are already refused, `MOVEMENTS_THROUGH_FUNCTION_ONLY`); one
`maintenance_part_issues` row per line; append-only, a correction is a return. Only `spare_part` materials; only to a maintenance record not voided
and not capitalised (Q14); quantity ≤ available. Code: **`module.inventory.edit`** (warehouse, admin, cco hold it live) — no new code; the
maintenance record is readable with `module.processing.view`, which those roles hold (action-implies-view holds).

❓ **Q13** - **(Q11) Unpriced and repriced batches**: a write-off of an unpriced batch moves quantity and posts nothing (`inventory_ledger_triggers.sql:182`);
a later reprice puts the consumed share into 5000 Material Cost (`reprice_inbound_batch.sql:91`).

➡️ **Refuse to issue from an unpriced batch** (`SPARE_PART_UNPRICED|<batch>` — a maintenance cost that silently posts 0 understates the repair);
**a reprice routes the issued share to the maintenance account, not 5000** — one implementation: `reprice_split` learns the movement type. A
provisional price is a price and may be issued.

❓ **Q14** - **(Q11) Parts on a capitalised overhaul**: capitalising goes through the expense document (`record_expense`); parts from stock have no
path into the asset's cost.

➡️ **Refuse issuing parts to a capitalised maintenance record, and refuse capitalising a record that has parts issued** (both by name); register
"parts into a capitalised overhaul" for the first real overhaul. Expensing them silently would understate the asset.

❓ **Q15** - **(Q2, Q12) Quality hold and locations**: `guard_quality_hold` lets any unlisted type through (`:25-28`).

➡️ **Add `maintenance_issue` to the blocked types** (a part under an open NCR is not fitted); `maintenance_return` allowed. Location and quarantine
rules unchanged (spare parts carry no safety states, `has_condition_axes = false`).

❓ **Q16** - **(Q2) Machine ↔ part list and criticality**: the dictionary note promises both; MES-0 sized neither.

➡️ **Not in MES-7a; register it** (`docs/known-issues.md`), returning with the first vendor recommended-spares list. Each issue already records the
machine through its maintenance record.

❓ **Q17** - **(Q2) V21 — minimum stock**:

➡️ **`materials.safety_stock_qty` on spare-part materials** (exists; the `safety_stock_below` reminder already reads it); pending-value arm: each live
`spare_part` material with it empty **and at least one receipt**; `module.materials.view`; supplied by cto / the vendor's list at equipment
acceptance. Row in `docs/mes-pending-values.md` in the same commit (7a-2).

❓ **Q18** - **(Q5) V22 and the orphan V12**:

➡️ **V22 closed by Q71 — no pending value; recorded as answered.** **V12** (tool-replacement cut count, MES-4a) was never built or recorded; register
it with its trigger "casing-removal machine commissioned" in `docs/mes-pending-values.md` (as not built) — no blade, counter or casing machine
exists to attach it to.

❓ **Q19** - **(Q3, Q4) Run stop events vs downtime**: an `unplanned_stop` run event and a downtime row can describe the same stop.

➡️ **Reliability counts downtime only; run events and indicators stay run-level and are not counted** (counting both double-counts). No arm
pairing them now (no rule exists for "the same stop"); registered for the first controller summary.

❓ **Q20** - **(Q1) Trails, change log, masking**:

➡️ **Members, no new subject**: cause and source under `equipment`; part issues under `equipment` (home) and `inbound_batch`; `downtime_causes` under
the dictionary trail; wording arms ㉚ (7a-1) and ㉛ (7a-2) reading `titlePart`, each with a drift and a part fault. Both new tables change-logged,
exclusions stay 8. **No masked column** — money lives in the GL entry; the maintenance page shows part value only to `data.view_prices` holders.

❓ **Q21** - **(Q1, Q6) Migration and window**:

➡️ **One migration per cut, COMMIT → ROLLBACK dry run on live first; no back-fill.** 7a-1's window breaks recording equipment from the old finance
page until the deploy (direct policies dropped, cause required) — accepted and stated, because keeping the direct path would leave the cause
unenforced at the table. Code first, migrate last, so the window stays ≈ deploy time.

❓ **Q22** - **(Q1) Fixtures**:

➡️ **New 265 (7a-1) and 266 (7a-2); changed without weakening the list in §4**; every new arm fault-injected; the injection run repeated on a fresh
rebuild after the last database edit, before the push.

❓ **Q23** - **(Q2, Q12) Stock reports and the scope edge**:

➡️ **Roll-forward and balance tree gain an "issued to maintenance" column (net of returns), so closing still ties to stock; the movement mix chart,
enum mirror and i18n learn both types.** Consumables and non-batch inventory stay out (MES-0 absorbed spare parts only).

❓ **Q24** - **(Q8) Save PDF for a byte-less CoA**: the known issue's deletion condition (`known-issues.md:10793`) is a button that renders the
snapshot and records the hash; F9 alone closes only the font half.

➡️ **Build it in 7a-1** (holders of `action.issue_coa`, shown only on an issued certificate with no `coa_issues` row; `renderCoaPdf(snapshot)` +
`record_coa_issue`) and retire the known issue.

❓ **Q25** - **(Q9) The COD font guard**: the COD route has none (`app/inbound` imports no coverage guard).

➡️ **Include it in F10** — the same `findUnrenderableText` on the COD strings, before `issue_cod` and inside `render()`; a COD with an unprintable
character is refused, never printed blank.

❓ **Q26** - **(Q9) Two COD findings outside F10's path**: `cod_verification.sql:96-97` says phone / email / website are not on the paper (the PDF
prints them); `record_cod_issue` lacks the CoA's lower-casing, path check and named "already recorded" refusal.

➡️ **Register both, fix neither here.** The first sits inside the one anonymous function and changes nothing it returns; the second is a parity
gap with no failure measured. Each is fixed by the next cut that touches its function.

## §13 · Tim's own facts this cut needs (not design questions)

- Which machines run which operations (the MES-4a link page) — without it every MTBF / MTTR reads "no operating hours recorded".
- The plant's downtime cause list beyond the three seeded classes, and who records downtime (today `module.processing.edit`: admin, cco, cto).
- The repairs & maintenance account code and name (Q11), and whether the accountant wants spare parts in a stock account other than 1200.
- The first vendor recommended-spares list (V21; Q16).

## §14 · Assertions measured and found false or imprecise

1. **MES-0 README:132, :1015 cite `equipment_downtime.sql:58-63`** for the "分母" comment — it is now `:59-71` (table comment) after U1-B's void
   columns. **README:131 cites `inventory_movements.sql:84`** for `one_batch` — now `:88`.
2. **MES-0 README:132 "operating hours (runs have a date only)"** — superseded: MES-4a added `started_at` / `ended_at` / `shift_code`.
3. **`material_kinds.sql:81-83` "不按批次追溯"** — contradicts the later Q70 ruling (Q2).
4. **`equipment_maintenance.sql:97` "本表没有 UPDATE 策略"** (said of `capitalised_expense_id`'s writer) — an UPDATE policy for
   `module.processing.edit` exists at `:155-159`, so the sentence is false of the table as written.
5. **`equipment_downtime.sql:91-93`** (the read policy's comment) says "只有 admin/gm 两个都有" `module.processing.edit` and `module.finance.view` — live
   **cco holds both** (measured today, `live-role-codes`: cco has `module.finance.view` and `module.processing.edit`), cto holds
   `module.finance.view` (`docs/handbacks/U1-B.md:55`), and gm holds no `.edit` code since APR-ROUTE-1.
6. **`app/inbound/[id]/cod/pdf/route.tsx:149-150` "照冻下来的那一份渲染"** and the header `:15-17` — the route re-reads live data (F10).
7. **`cod_verification.sql:96-97`** — phone / email / website are on the paper (Q26).
8. **V12** (MES-0 README:577, MES-4a) — never built nor recorded anywhere else in `docs/`.
9. **`known-issues.md:10790` names the contract title as the `≤` source** — the live proof re-tested it through the customer name
   (`2026-10-15-mes6b2-live-proof.mjs:534`); both carry the same character, the finding stands.
10. Zero other assertions of the brief found false: SHA, clean tree, 7 accounts enabled, approvals ON finance / cfo / 1,000, admin holds every code
    (79 / 79), `action.ncr_decide` admin · cco · cto, `action.issue_coa` admin · cco, `require_calibrated_since` NULL, no contract / quality limit /
    NCR / CoA on live, production on the MES-6b-2 app (the close-out read its CoA section on the deployed pages).

## §15 · Stop

No code edits and no migrations. Waiting on Tim's answers to Q1–Q26.
