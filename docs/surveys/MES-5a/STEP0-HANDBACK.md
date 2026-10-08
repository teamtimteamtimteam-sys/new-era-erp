# MES-5a Step 0 — hand-back (2026-10-08), with the MES-4b close-out

**STOP GATE.** No code edit, no migration, no live write. The only writes are docs: the MES-4b close-out (`4c1fd8d1`, "MES-4b close-out":
`docs/forward-queue.md` + `docs/surveys/MES-5a/closeout-readings.sql`), this file and `docs/surveys/MES-5a/live-readings.sql`.
Waiting on Tim's answers to Q1–Q36 (§12).

**Opening check.** First command **2026-10-08 09:02:44 CST**. Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
`2915f3f78d31bd7ded05a1399775db398f440e4d`. Files staged by explicit path only.

**Live readings (measured, read-only).** As `postgres` (`rolbypassrls = true`), `BEGIN READ ONLY … ROLLBACK` under `default_transaction_read_only = on`,
every business relation a base table. Close-out: `docs/surveys/MES-5a/closeout-readings.sql`, 09:14 CST, `READ_OWN_EXIT=0`. Step 0:
`docs/surveys/MES-5a/live-readings.sql`, 09:27 and 09:32 CST, `READ_OWN_EXIT=0`. Standing state: 7 accounts, 0 disabled · approvals ON ·
`require_calibrated_since` NULL.

**Local measurements.** A throwaway cluster in this job's scratch directory, rebuilt from the HEAD mirrors (`db/verify_rebuild.py --skip-diff`,
`REBUILD_EXIT=0`; its B1/B2 step read live's catalog, read-only: B1 0 · B2 0). The gate proved the mirrors equal to live at MES-4b's full gate
(`GATE_EXIT=0`, 00:24 CST), and no migration has run since. Every "measured on the rebuild" result below comes from that database, never from live.

**How the facts were gathered.** Four read-only sub-agents covered the discharge path, the energy and cost path, the governance machinery and the
cut durations. None connected to a database or ran a build. I read AGENTS.md, the specification PDF (text extracted with pypdf, 11 pages),
MES-0, the MES-4b Step 0 and hand-back, the MES-4a hand-back, `docs/mes-pending-values.md`, the operation-model records
(`docs/operation-model-scoping.md`, PROC-MODEL-0; `docs/proc-loss-and-saleability.md`, PROC-BUILD-1) and the MES-4b build brief (from its session
transcript) in full. `docs/forward-queue.md` is 774 KB. I read its MES items 36–41, the MES group table, the discharge-direction section
(`:544-595`) and the event-trigger table (`:1855-1869`), and a sub-agent grepped the whole file for discharge, electricity and meter entries.
I re-read every load-bearing claim at its file:line, or measured it.
Tags: **[M]** measured · **[I]** inferred from code reading · **[Q]** quoted from an earlier record.

---

## §0 · MES-4b close-out — step 1 results, item by item

**1 · Broken window — closed (bounded), recorded in `docs/forward-queue.md` under item 41.**
- **Start:** 2026-10-07 23:58:59 CST. Measured from `db/migration-windows.tsv:224`.
- **End, lower bound:** 2026-10-08 08:52:38 CST. Measured from the reflog line `2915f3f7 … {2026-10-08 08:52:38 +0800}: update by push`.
- **End, upper bound:** 2026-10-08 09:02:44 CST. This is this session's first command, taken with Tim's "deployed" already in hand. It rests on what Tim said, not on a Vercel reading.
- **Window: 8 h 53 min 39 s – 9 h 03 min 45 s.** It was long because the push was late. At 01:23:25 the auto-mode classifier refused the cut's own `git push` ("Out-of-Place Publication"). Tim ran `! git push origin main` at 08:52:38. About 7 h 29 min of the window was spent waiting for that push; source: the MES-4b session transcript, last lines.

**2 · Tim's own action — recorded under item 41.** Create materials of the six new forms in the material editor. Live today there are 0 materials
on those forms [M]. The entry gives the exact fields: kind `battery_material`, source required, size format left empty.

**3 · Read-only verification**

**a. The MES-4b brief's "Fixtures must cover" list** (from the MES-4b build brief, §3), item by item:

| Brief item | Fixture · arm | Evidence |
|---|---|---|
| Construction: set at receipt, set later, refused on a non-cell form, required at the two separation inputs (missing and unknown), inherited when inputs agree, NULL when they don't, locked after a committed run | **254 CC** | receipt `:162-164`; later `:173`; black mass at receipt and later `:184,188`; both operations × missing and unknown, in a loop over `['electrode_separation','electrode_line']` `:206-221`; inherit `:233`; disagree `:242`; locked `:253,255` |
| The six forms and saleability; collected dust refused for sale; anode powder allowed | **254 FORM** | `:271`; a real sale attempt is refused `SALE_FORM_NOT_SALEABLE\|collected_dust` `:273`; anode powder sells `:277` |
| Numbering: each prefix from the form, OUT fallback, five digits, past 9,999 without truncation, below 10,000 unchanged, old OUT- found by search, registry count at its new total | **254 NUM** + **100** + `check-search-registry` | 13-prefix map `:107-109,294`; found under its own type `:298`; OUT fallback `:307`; OUT- found `:310`; 4 digits below 10,000 `:321`; OUT and IN at 10000 `:322-336`; generators scan `:343`; registry 55 / 13 `:282`; fixture 100 "55 个前缀" (measured on the rebuild, `F100_EXIT=0`); `EXPECTED_ROWS = 55` (`scripts/check-search-registry.mjs:71`) |
| Loss basis on record_run_loss; derived loss and each refusal (incl. the no-flag operation); re-derive; switch to measured; reopen a closed run | **254 LOSS** | measured basis `:351`; no flag `:356`; no share `:359`; over input − outputs `:362`; state-changing `:368`; viewer `:373`; derived row `:382`; re-derive `:400-409`; reopen `:411`; to measured `:417-419` |
| Contamination: a check, a correction, not_sampled with and without a reason, a rate above V11 flagged, the reminder appearing and clearing | **254 CONT** | reminder appears `:431,438`; flagged `:459-461`; correction `:468`; no reason `:476`; with a reason `:478`; clears `:481` |
| Collected dust as a DST output leg | **254 DUST** | `:533-542` |
| The mirror-check lists with the four tables, red on an injected fault | gate `bootstrap` (not a fixture) | item c |
| V10 and V11 | **254 PV** | `:547-561` |
| The smoke trail check in both directions (Q31) | smoke | an operation with changes and a blanked trail → `SMOKE_EXIT=1` ("electrode_line has 1 row that should read as entries"); an unchanged operation (`deep_discharge`) → `SMOKE_EXIT=0` (MES-4b logs `smoke-q31-blank.log:22,35`, `smoke-q31-unchanged.log:21,33`) |
| Fixture 195 E4 with the CEL- injection | **195 E4** | item b |

**Every new arm's fault injection is red, re-measured this session against HEAD, not read from the old logs.** That matters because MES-4b's own
injection log (22:49) predates its last edits; the edit after it was `material_lookup`, which no arm reads.
- `db/scripts/2026-10-07-mes4b-fixture-injections.py` on the HEAD rebuild: **37 injections, 0 wrong**, `INJECTIONS_OWN_EXIT=0`. Each was red in its named arm (CC 8 · FORM 2 · NUM 6 · LOSS 9 · CONT 9 · DUST 1 · PV 2), and the clean run passed.
- `db/scripts/2026-10-07-mes4a-fixture-injections.py` (which carries MES-4b's three added cases): **71 injections, 0 wrong**. Named cases:
  - HDR "a pre-MES-4a run header may be corrected" → `RUN_HEADER_PREDATES_RECORD`;
  - TRAIL `trail_refs` → "should name its field";
  - TRAIL `trail_ref_label` → "got ZZ253-STD version 1".

**b. Fixture 195 E4** (`db/fixtures/195-…:313-327`).
- It reads every output prefix from `document_types WHERE table_name = 'output_batches'` (`:313-315`).
- Coverage is itself an assertion: fewer than 13 prefixes is a red "blind" (`:317-318`).
- An in-fixture CEL- injection must be caught (`:321-322`), and the old `OUT-` regex must miss it (`:324-325`).
- Re-measured on the rebuild:
  - clean `F195_CLEAN_EXIT=0`;
  - injection 1 (the registry read narrowed to OUT) → `F195_INJ1_EXIT=3`, "E4 失败:登记表里只读到 1 个产出批前缀";
  - injection 2 (the criterion forced back to `(OUT)-[0-9]{4}-`) → `F195_INJ2_EXIT=3`, "E4 失败:注入的 CEL- 号没有被判据认出来".

**c. The four tables in the mirror-check classification.**
- All four are in `RUNTIME_CONFIG_TABLES` (`db/check_mirrors.py:321,324`). That one list is read by both checkers: `check_mirrors.py:1077` (bootstrap counts) and `db/gate.py:544` (bootstrap emptiness).
- They are not in `SEED_TABLES`, by design. A table is classified into exactly one of the two lists, and Step 0 Q30 put them in RUNTIME CONFIG. The repo's own phrase for the gap was "两张清单都不在" ("in neither list", `:318`).
- Re-measured on the rebuild with the gate's own list and predicate, inside a rolled-back transaction:
  - clean: 45 tables checked, empty `[]`;
  - with the four emptied: `['cell_constructions','contamination_streams','loss_categories','loss_metal_fates']`.
- MES-4b's own offline-gate injection log reads `bootstrap ✗ 引导后为空:[…the four…]` and `GATEOFF_EXIT=1` (`gateoff-bootinj.log:17,305`).
- **Wording note, not a gap:** the brief's "both mirror-check lists" literally means two lists. The tables are in one list, which both tools read.

**d. V10 and V11.**
- Arms in `db/views/pending_values.sql:210-226`: V10 is `electrolyte_loss_applies AND electrolyte_share_pct IS NULL`; V11 is `warning_pct IS NULL`. Both are under `module.processing.view`.
- Rows at `docs/mes-pending-values.md:35-36`, plus the "What V10 / V11 holds back" paragraphs at `:103-116`.
- Fixture 254 PV covers them (above).

**e. Generators.**
- **31 yearly-reset generators** are listed by name in `docs/known-issues.md:3284-3296` (counting method included: 33 files − 2 that mention the old form only in comments).
- **11 never-resetting generators:**
  - 10 use `LPAD(n, GREATEST(4, length(n)), '0')`: `generate_weighbridge_ticket_code.sql:17`, `generate_device_code.sql:17`, `suppliers.sql:113`, `materials.sql:106`, `customers.sql:73`, `inbound_batches.sql:147`, `contracts.sql:109`, `stocktakes.sql:23`, `processing_runs.sql:132`, `tasks.sql:63`.
  - The 11th is OUT: `output_batches.sql:135-137`, `GREATEST(v_width, length(n))` with width 4 for OUT and 5 for the new prefixes.
- The expression evaluated on the rebuild: `7→0007 (old 0007) · 381→0381 · 9999→9999 · 10000→10000 (old 1000) · 123456→123456 (old 1234)`.
- **End-to-end minting of a 10,000th code is measured for IN and OUT only** (254 NUM `:322-336`). The other nine are verified by reading. A documentation-precision note, not a gap.

**f. Saleability on live** [M, `f_form`]: `collected_dust` **not saleable**. Cathode powder, anode powder, copper foil, aluminium foil and harness/BMS/busbar
are **saleable**. All six are active and mapped to their output keys.

**g. Electrolyte on live** [M].
- `electrolyte_loss_applies` is FALSE on all 7 operations; flagged 0, share set 0 (`g_op`, `g_op_flag_true|0|0|7`).
- The flag is editable on the operation page:
  - the checkbox is labelled from `messages/en.ts:4108` "Electrolyte evaporates in this step" (zh `:3997`);
  - it sits in `<PermissionGate code="module.processing.edit">` (`OperationTypeEditor.tsx:211-225`, `EDIT` at `:31`);
  - the page computes `can('module.processing.edit')` (`[code]/page.tsx:58`);
  - the server action `setElectrolyte` updates `operation_types` and refuses zero rows (`app/operation/operation-types/actions.ts:63-76`);
  - the database policy on live is `operation_types write by permission` = `has_permission('module.processing.edit')` (`g_policy`).
- The description:
  - live `loss_categories.notes` for `electrolyte_evaporation` states the extraction airflow to the back-end environmental equipment (`g_lc … notes_names_back_end_equipment = t`; the text is in `db/migrations/2026-10-07-mes4b-fields-and-products.sql:345-348`);
  - the run page shows the English sentence from `messages/en.ts:3369` ("…carried by the extraction airflow through a duct to the back-end environmental (abatement) equipment for treatment…") at `LossPanel.tsx:237`.

**h. Fixture 245** (`git diff 2915f3f7~1 2915f3f7`).
- Only the leave date changed: a new `v_leave` is the first business day from `CURRENT_DATE + 30`, and `submit_leave_request` uses it instead of `CURRENT_DATE + 30`. That is +5 / −1 lines.
- `RAISE EXCEPTION` count 35 → 35 and `IF` count 34 → 34: **no assertion removed or weakened.**
- Re-run on the rebuild: `F245_EXIT=0`.

**i. Usability on live today — both work.**
- **The material editor** [M].
  - The form picker lists every active form with no filter (`materialAxesQuery.ts:15-16`).
  - The size-format field is hidden for forms that do not imply dismantling (`MaterialAxesPicker.tsx:170`).
  - The insert is gated by the RLS policy `materials insert … has_permission('module.materials.edit')` (`db/tables/materials.sql:122-125`) and by `guard_material_condition_axes` (form and source required for battery kinds; size format refused on these forms).
  - Measured on the rebuild, as a session holding **only** `module.materials.view` + `module.materials.edit`: six materials created, one per new form, with the editor's insert columns. A size format on copper foil was refused `MATERIAL_SIZE_FORMAT_NOT_APPLICABLE|copper_foil`.
  - Live: `battery_material` is active with `has_condition_axes = t`; three sources are active; the trigger is enabled; `module.materials.edit` is held by 6 roles and 4 live accounts.
- **Construction on a cell batch** [M].
  - The batch pages render the panel for cell forms and form-less materials (`app/inbound/cellConstructionQuery.ts`; `inbound/[id]/edit/page.tsx:930-935`, `output/[id]/edit/page.tsx:495-499`).
  - Edit right: `module.inbound.edit` / `module.output.edit` or `action.processing_commit` (`:268`, `:212`), the same pair as `set_batch_cell_construction`.
  - Measured on the rebuild:
    - a cell batch received with no construction (`IN-…`, NULL);
    - a session holding only `module.output.edit` was refused `PERMISSION_DENIED|module.inbound.edit`;
    - a session holding only `module.inbound.view` + `module.inbound.edit` set it to `wound`.
  - Live: **one** cell-form batch with no construction and not locked, `ZZ-PROCCOST1-DEMO` (inbound). Also 9 inbound and 14 output batches on form-less materials, settable. Holders: `module.inbound.edit` (5 accounts), `module.output.edit` (5 accounts).

**j. Self-taken decisions in `docs/handbacks/MES-4b.md` §6:**
1. A form-less material may carry a construction.
2. A derived quantity is rounded to 3 decimals.
3. Calculating (and recalculating) the electrolyte loss asks `action.processing_aftercare` only.
4. Correcting a derived row to the same number as a measured figure is allowed.
5. A "not sampled" row requires that the run produced that stream's sheet.
6. `material_lookup` gained `form_code`.
7. `trail_row_record` was left unchanged.
8. The smoke test picks an operation with changes by default.
9. Live proof codes are burned.
10. The dictionary header row wraps.
11. Fixture 245's date was made calendar-proof.
12. Trail wording arm ⑳ was added.

**Step 1 verdict: nothing in a–i is missing or works differently from what was stated.** Two wording/precision notes (c, e) are recorded in
`docs/forward-queue.md`. Step 2 went ahead.

---

## §1 · What grilling changed in MES-5a's scope

1. **The flip moves out of the commit** [M].
   - Today `commit_processing_run` flips a state-changing run's whole input batch to `discharged_verified` at commit: inbound `:466-478`, output `:519-531`. MES-0 cited `:354-363`, which has since moved.
   - Per-module results arrive after the commit: as gateway drafts (`ingest_data_classes.discharge_module` exists, transform NULL, `ingest_data_classes.sql:44-46`), or by hand.
   - So the flip must happen when the results complete, not when the run is committed (Q5).
2. **The whole-batch flip on a partial discharge is now measured, not inferred** [M, rebuild]. Discharging 10 kg of a 100 kg charged batch left `remaining_qty = 100` and opened `discharged_verified` on the **whole** batch (probe P1).
3. **Two more defects in today's discharge path, both measured on the rebuild** (probe in this job's scratch directory, rolled back):
   - **P3 — discharging a self-produced batch drains stock that never left.** A 100 kg output batch discharged 10 kg came out at `remaining_qty = 90`, with a `processing_consume` movement of −10. The output-side branch has no `v_consumes` check (`commit_processing_run.sql:494-507`); the inbound side has one (`:435`). Fixture 165 K7 discharges an output batch but never reads its stock (`165-…:189-215`).
   - **P2 — a discharge run cannot be reversed once its batch has been partly used.** Discharge 10 of 100, then disassemble 50, then reverse the discharge: `IOD_RESTORE_MISMATCH|10|0`. Rollback "restores" stock the discharge never drained: `rollback_processing_run_internal.sql:71-139` has no consumes branch; `mirror_consume_restore.sql:36-37` then finds no rows. It is loud, not silent; fixtures 160 and 251 reverse only full batches.
   - Both sit on the lines MES-5a must rewrite (Q14, Q15).
4. **A required field cannot carry the module count** [M]. `operation_type_fields.is_required` is read only by the balance-closure view (`processing_run_balance_all.sql:68-74`), and a discharge has no closure (`not_applicable`). Nothing at commit enforces it. The module count therefore needs its own home (Q4).
5. **No batch split exists anywhere** (grep for split / carve / parent in functions → only `reprice_split`, unrelated). MES-0 Q23's "quarantine splits the failed modules into their own batch" needs a mechanism. The cheapest one reuses the run engine (Q11).
6. **Capture confirmation knows only weighings** [M]: `capture_confirm_internal.sql:55` raises `CAPTURE_CLASS_HAS_NO_RECORD` for every other class. Also, `submit_manual_capture.sql:39` accepts devices of kind scale / weighbridge / meter / inline_instrument only, not `discharge_cabinet`. Both need a branch (Q10).
7. **The electricity mechanics MES-0 Q26 names would post twice** [M + I].
   - Q26: "allocation writes `processing_cost_entries(electricity, is_estimate = false)` and relieves estimates".
   - An actual cost entry posts Dr 5110 / Cr 2200 at entry (`fin_journal_cost_entry`, `finance_journal_triggers.sql:42-101`). It is settled by `remit_processing_costs`, Dr 2200 / Cr bank, with no bill document.
   - A bill keyed through Expenses can only reach 6200, because `record_expense` refuses 5xxx with `ACCOUNT_NOT_EXPENSE` (`record_expense.sql:82-83`).
   - So "allocation writes actual entries" plus "the bill recorded as an expense" would put the bill in the ledger twice. The allocation must be the bill's single entry (Q24).
8. **Splitting a machine's metered kWh across its runs is an allocation rule nobody has ruled** (Q22). Meters give register readings. Runs have start and end times (MES-4a), and some operations have an `energy_kwh` indicator (`operation_type_fields.sql:95,100,105,107`); deep discharge has none. The repo's record: "发明一条分摊规则正是本仓库记过账的那种失败" ("inventing an allocation rule is the kind of failure this repo has already paid for", `processing-support-as-built.md:170-173`).
9. **V9 cannot be one number** [I]. A module's end voltage depends on its series count, so "pass voltage for manual verdicts" per operation would be wrong for every second module type. It belongs per material, and it flags, never decides (Q8).
10. **Size.** Combined, the cut is 5 tables, 2 columns, ~5 changed functions, 2 transforms, a split, a GL posting path and ~5 pages, against a largest measured MES cut of 3 h 35 m. The two halves share no table and have different proofs (safety admission vs GL posting). Recommendation: split into **MES-5a-1 Discharge** and **MES-5a-2 Energy** (Q2).

---

## §2 · (a) Exactly what MES-5a contains

MES-0 §8.2 row 7 [Q, `docs/surveys/MES-0/README.md:701`] gives the scope as `discharge_module_results`, `discharge_channel_assignments`, `meter_readings` and `electricity_allocations`, with "verdict → safety state by module; quarantine split of failed modules; allocation posts processing cost entries — 4 / 4". Earlier Step 0s added:
- the discharge and meter transforms (MES-1 Step 0 `:189`, MES-2 `:172`);
- the quarantine split (MES-3a Step 0 `:140`; `docs/known-issues.md:10440-10446` "要做成'拒'的话 … = MES-5a" — "making it refuse … = MES-5a");
- the deep-discharge fields MES-4a seeded none of (MES-4a Step 0 `:299`).

**Discharge half (MES-5a-1 if split).**
- **New tables (2):**
  - `discharge_module_results` — append-only. One row per module per discharge attempt: module ref, channel, outlet voltage, verdict, verdict time, duration, energy recovered, disposition on failure, source / inbox / draft / site pointer, optional photo, corrections with a reason.
  - `discharge_channel_assignments` — append-only. Channel → module ref per run, needed to resolve device rows that arrive keyed by channel.
- **Changed tables:**
  - `inbound_batches.module_count` (masked: column, grant and `_masked` view in one migration) and `output_batches.module_count`.
  - `operation_types.verifies_by_unit` (seeded TRUE on `deep_discharge` only).
  - `materials.discharge_pass_voltage_v` (V9).
  - `ingest_data_classes.discharge_module` gets its transform, manual-entry code and `creates_draft`.
  - A new operation type `discharge_quarantine_split` (transforming), with its safety-state and form rows.
- **Functions:**
  - `commit_processing_run`: no flip when `verifies_by_unit`; the output-side drain respects `v_consumes` (P3).
  - `rollback_processing_run_internal`: no stock restore for non-consuming runs (P2).
  - `transform_discharge_module_v1`; a discharge branch in `capture_confirm_internal`; `discharge_cabinet` in `submit_manual_capture`.
  - `record_discharge_module_result` / `correct_discharge_module_result`, `assign_discharge_channel`, `set_batch_module_count`, and an internal `discharge_verify_batch` (the flip).
  - `split_failed_modules_to_quarantine`.
  - Two reminder arms; the V9 arm.
- **Pages:**
  - changed `/operation/processing/[id]`: a module-results panel on discharge runs (channels, results, completeness, split);
  - changed `/inbound/[id]/edit` and `/output/[id]/edit`: module count, and the per-module summary from the batch's discharge runs;
  - changed `/operation/processing/new`: shows the batch's module count and refuses a discharge without one;
  - changed the material editor (V9);
  - changed `/settings/pending-values` and the reminders.
  - No new route is needed (Q13).

**Energy half (MES-5a-2 if split).**
- **New tables (3):**
  - `meter_readings` — append-only register readings (kWh at a time), source / inbox / site pointer, corrections.
  - `electricity_allocations` — one per bill: period, supplier, invoice reference, amount, bill kWh; masked amounts.
  - `electricity_allocation_lines` — per run: kWh, share, amount, basis label; masked amounts.
- **Changed:** `ingest_data_classes.meter_reading` gets its transform; `devices` — no new column (a meter's machine is `devices.equipment_id`, NULL = shared pool).
- **Functions:**
  - `transform_meter_reading_v1` and its confirm branch; `record_meter_reading` / `correct_meter_reading`.
  - `preview_electricity_allocation` and `post_electricity_allocation` (one implementation, two callers — AGENTS.md "A screen that previews a posting ASKS the database").
  - Energy views: per machine per period, per run, per tonne (Q23); the V25 arm.
- **Pages:**
  - new `/finance/electricity` (list) and `/finance/electricity/new` (the allocation, previewed then posted);
  - changed `/operation/devices/[id]` (meter: readings, machine or shared pool);
  - changed `/operation/processing/[id]` (energy figures);
  - changed `/finance/month-end` (unallocated bills are listed, not blocking — the MES-4a pattern).

**Left to later cuts:** per-inbound and monthly balance, yield, blending (MES-5b) · thermal-runaway / HF alarms (site layer, MES-7b) · incidents from
alarms (MES-7b) · per-module **temperature** (site layer; exceptions only) · scheduling of discharge channels · machine routing by construction ·
availability / OEE (the open "分母" denominator ruling) · emissions (MES-7b).

## §3 · (b) Discharge

- **What is recorded per batch and run.**
  - **Run header (unchanged, MES-4a):** operation `deep_discharge`; start, end and shift; machine (required once a cabinet is linked); input batch and the mass put through (throughput — no stock effect for an inbound batch, `:435`); `loss_qty` 0 (`:394-400`); balance `not_applicable`.
  - **New, per module:** the module's identity (Q3), its channel, the outlet voltage (V), the verdict (pass / fail), the verdict time, the duration (min), the energy recovered (Wh, regenerative units, spec §3.1), and the disposition when failed (`re_discharge` | `quarantine`, mandatory, spec §3.1).
  - **Method:** device-fed through the `discharge_module` class, or entered by hand — `source = 'manual'`, "per-module data not exported", optional screen photo (MES-0 Q25) in the existing `capture-photos` bucket (MES-2).
  - **Per batch (derived, not stored — one source):** module count (stated on the batch), modules passed / failed / re-discharged / quarantined, total duration, energy recovered, failed count by disposition.
- **Start and end voltage.** The spec asks for the **outlet residual voltage** per module (§3.1, §9) and the curve's terminal form. The curve stays at the site behind the pointer (`site_from` / `site_to` / `site_dataset_ref`, MES-1). A start voltage is not in the spec. Recommendation: optional column, no judgement (Q7).
- **Verification.**
  - The batch becomes `discharged_verified` when every one of its `module_count` modules either has a current **pass** result or has been split out to quarantine (MES-0 Q23, restated in Q6).
  - Who writes it: the result-recording function, through `discharge_verify_batch`. It writes the same rows the commit writes today — ends `charged_not_discharged` with `ended_by_run_id`, opens `discharged_verified` with `created_by_run_id`.
  - So **MES-3a's state history and the existing reversal semantics carry over unchanged**: rollback ends rows created by the run and reopens rows the run ended (`rollback_processing_run_internal.sql:148-178`, fixture 251).
  - Results of a reversed run stop counting.
- **Relation to today.** The deep-discharge operation, its accepted states (`operation_type_safety_states.sql:45-48`), the fire gate (`guard_processing_input`) and the purchase-time judgement (`deep_discharge_judgements`, U1-B Q20) are unchanged. The judgement remains a separate axis; nothing reads it at commit (`deep_discharge_judgements.sql:45-58`). Tim's ruling stands that thermal-runaway history is not a safety state (`inbound_safety_states.sql:49-55`).
- **Live today** [M]:
  - 1 discharge run ever: PROC-2026-0494, **reversed**, 10 of 100 kg of `ZZ-PROCCOST1-DEMO`;
  - 0 MES-4a-era runs;
  - open states: inbound `discharged_verified` 1, output `charged_not_discharged` 1;
  - state rows written by a run: 0;
  - 0 discharge cabinets in `devices`; 0 machine links;
  - the two discharge machines are on the asset register (FA-2026-0001 Bosch, FA-2026-0002 Mobile), not in service.

## §4 · (c) Energy

- **What a meter is.** A `devices` row of kind `meter` (exists, MES-1, `devices.sql:28-30`), with calibration (MES-2) and capacity V33 already. Live: 0 meters.
- **What it attaches to.** A machine through `devices.equipment_id` (exists, nullable), or — when NULL — the **shared pool** (MES-0 Q27).
  - Operations reach a meter through their linked machines (`operation_type_equipment`, MES-4a).
  - Runs reach it through `processing_runs.equipment_id`.
  - The site is one site, so it needs no column.
- **How readings arrive.** Register readings (cumulative kWh at a moment), by hand on the meter's device page or device-fed through `meter_reading` (transform NULL today, `ingest_data_classes.sql:46`). They are append-only with corrections, and carry source, inbox, draft and site pointer (the `weighings` shape, `weighings.sql:24-66`).
- **How energy per run and per tonne is derived.**
  - Per machine per period = last reading − first reading in the period (a reading lower than the previous one needs a declared register reset, Q20).
  - Per run:
    - the run's own `energy_kwh` value where the controller or operator recorded it (MES-4a fields on four operations);
    - otherwise the machine's metered kWh split across its runs by the rule Tim gives (Q22);
    - discharge runs also show energy **recovered** (sum of module rows), which is not consumption.
  - Per tonne = kWh ÷ the denominator Tim rules (Q23, `docs/forward-queue.md:1891`).
- **Money.**
  - A bill is entered once, on an electricity allocation for a period. Its metered part is split across that period's runs by kWh and written as each run's electricity cost line.
  - The unmetered and shared remainder goes to overhead (6200), and is not spread until V25 is set (MES-0 Q26 · Q27).
  - Posting path: Q24. Live today [M]: 6 electricity cost lines (1 actual, 5 estimates, 1 of them relieved); 1 expense on 5110; 0 on 6200; 0 `energy_kwh` values.

## §5 · (d) Effect on MES-4a's run record, closure and fixtures

- **Run record.** The header, values, events, corrections and the run form are unchanged. A discharge run gains a results panel. `deep_discharge` gets **no** `operation_type_fields` (Q17): per-batch figures are derived from module rows, and a required field would enforce nothing at commit (§1.4).
- **Closure.** Unchanged. A discharge is still `not_applicable` (`processing_run_balance_all.sql:47`; `close_run_balance` → `RUN_BALANCE_NOT_APPLICABLE`). The split run is transforming, so its balance closes like any run (input = weighed output → remainder 0).
- **Fixtures that change, without weakening.** These assert the flip **at commit**, so their assertions move to "after the results":
  - 158 D4 (charged ended, discharged added);
  - 165 K7 (output-batch flip; it also gains the stock assertion for P3);
  - 251 RUN (state history on rollback);
  - 253 DISCH (header and `not_applicable` unchanged).

  Unchanged:
  - 115 (gate);
  - 159 F1–F8 (narrowing and cost);
  - 160 (cost; F8 `remaining_qty` stays 100 — still true);
  - 111 (57 → 59 arms);
  - 47 (if an arm fires on its data);
  - 100 / 102 (registry: no new code-bearing table);
  - `check-document-registry` `EXPECTED_TABLES` 275 → 277 or 280.

  New fixture 255 (discharge) / 256 (energy).
- **Live.** The 14 runs, 0 losses and 0 values are untouched. The one reversed discharge run gets no results. Existing open states stay as they are (no back-fill, MES-0 Q94).

## §6 · (e) Approvals, audit trails, change log, masking

- **Approvals.** None new (MES-0 §4.1, the house test `docs/approvals.md:1090-1111`).
  - Module results, assignments, readings and the split are records of events.
  - The electricity allocation is the bill's entry, like `relieve_processing_accruals` today: not an approval document, because `expense` is not wired (`approvals.md:789-800`).
  - Paying the bill goes through payment requests (tiered at 1,000 SGD, CFO level 2). Approvals ON / finance / cfo / 1,000 are unchanged.
- **Change log.** Every new table is bound (generator `gen_change_log_bindings.py --only`); no exclusion, so fixture 235 stays at 8. New columns ride existing triggers. Mask rules gain the allocation amounts (105 → 107–109).
- **Trails.**
  - `discharge_module_results` and `discharge_channel_assignments` → `processing_run` (home) plus `inbound_batch` / `output_batch` (the `contamination_checks` precedent, `trail_subject_members.sql:494-495`);
  - `meter_readings` → `device`;
  - `electricity_allocations` and its lines → a new subject `electricity_allocation`, plus `processing_run` (not home);
  - wording arm ㉑ with its own fault.
- **Masking.**
  - Allocation and line **amounts** are behind `data.view_prices`, the processing-cost rule (`change_log_mask_rules.sql:102`) — `REVOKE SELECT` + column grant + `_masked` view + mask rules, in one migration.
  - kWh, voltages, verdicts and counts are not masked.
  - `inbound_batches.module_count` goes through the three-change rule (column grant + `inbound_batches_masked`); `output_batches` is not masked.

## §7 · (f) "Not yet set" values MES-5a adds

| # | value | lives on | page | arm reads | permission | supplied by | when |
|---|---|---|---|---|---|---|---|
| V9 | Discharge pass voltage per module (V), **per material** — flags a recorded verdict that contradicts it, never decides | `materials.discharge_pass_voltage_v` | material editor | each live material of a form that implies dismantling (whole pack, module, loose cells, mixed) with no value — **only once a discharge result exists on a batch of it**, so the page does not fill with every cell material at once | `module.materials.view` | Bosch documentation / module datasheet | discharge commissioning |
| V25 | Treatment of unmetered and shared-meter electricity (how the shared pool is spread; until set it stays overhead) | one setting row (the allocation settings) | `/finance/electricity` | one row while any shared-pool meter exists and the rule is empty | `module.finance.view` | Tim | first utility bill after meters connect |

No tariff value is needed: the money comes from the bill, split by kWh. Discharge duration has **no** threshold in MES-5a. It is recorded and not
judged; a "duration window" would be a new value nobody has asked for (Q8). Both arms and their `docs/mes-pending-values.md` rows land in the
same commit (Tim, MES-1 Q2).

## §8 · (g) Migration shape and broken-window assessment

**Shape.** One migration per cut (two if Q2 splits), date from `date`. New tables with triggers, bindings and anon decisions.
- **Discharge:**
  - columns, the inbound one with grant + masked view;
  - the operation flag and the split operation's dictionary rows;
  - `commit_processing_run` and `rollback_processing_run_internal` (CREATE OR REPLACE, signatures unchanged);
  - `capture_confirm_internal` / `submit_manual_capture` (CREATE OR REPLACE, unchanged signatures);
  - the class row update (install seed: `ingest_data_classes` is in `SEED_TABLES`, so the mirror and live move together);
  - new functions; internal ones revoked from `authenticated`;
  - views and arms; trail registry.
- **Energy:** tables (allocation masked), the class row, functions, views, the arm, trail.

**Broken window (old app + new database)** [I]:
- **Discharge:**
  - a discharge run committed from the old form commits but **no longer verifies the batch** (the flip moved). The batch stays `charged_not_discharged` until results are entered after the deploy; there is no refusal and no raw code.
  - The old run page shows no results panel.
  - The P2 / P3 fixes change nothing the old app sends.
  - Live has 0 MES-4a-era runs and no cabinet, so the practical effect is nil. Aim ≈ 1 h.
- **Energy:** new tables only; nothing the old app calls changes. Window ≈ the time to deploy.
- **Existing runs, batches, states:** untouched. `module_count` is NULL on all 24 inbound and 20 output batches. No result is back-filled onto the reversed PROC-2026-0494. The open `discharged_verified` on one inbound batch and `charged_not_discharged` on one output batch stay as recorded.

## §9 · (h) Time estimate — process floor and work, as two numbers

**Calibration** (active time = brief → push minus waits on Tim; transcript-measured by a sub-agent, matching the earlier §11 table to within 6 s):

| cut | active | estimate | active ÷ low – ÷ high |
|---|---|---|---|
| MES-1 | 2 h 39 m | 4 h 20 m – 8 h 35 m | 0.61 – 0.31 |
| MES-2 | 2 h 46 m | 2 h 35 m – 5 h 10 m | 1.07 – 0.54 |
| MES-3a | 2 h 46 m | 2 h 50 m – 5 h 15 m | 0.98 – 0.53 |
| MES-3b | 2 h 25 m | 2 h 50 m – 4 h 20 m | 0.86 – 0.56 |
| MES-4a | 3 h 35 m | 3 h 40 m – 6 h 20 m | 0.98 – 0.57 |
| **MES-4b [M]** | **3 h 19 m 54 s** | 3 h 20 m – 6 h 05 m | **1.00 – 0.55** |

**MES-4b [M]** runs from the brief at 22:03:30 (session `33f1ea65…`, transcript line 9) to the refused push at 01:23:25. There were no waits
inside. The 7 h 29 m wait for the push afterwards is excluded.

The phase split is measured:
- work before the backup took **1 h 22 m**, against an estimate of 2 h 16 m – 4 h 29 m (0.61 of the low end);
- backup to push took 1 h 58 m, which contains about 15 m of work, so the **process floor was ≈ 1 h 40 m – 1 h 45 m**, against an estimate of 1 h 05 m – 1 h 35 m. That figure includes one failed full gate (≈ 11 m), one survey relaunch (≈ 3 m) and a 26 m smoke.

So work ran faster than estimated and the floor ran slower.

**Floor (one cut):** offline gate (×2), backup (≈ 25 m), dry run, apply, types, build, full gate (≈ 9 m), survey, smoke (≈ 26 m), injections, live
proofs and role table, before/after readings → **≈ 1 h 25 m clean, ≈ 1 h 50 m with an incident**.

**Work, calibrated on MES-4b's measured 0.6–0.7 of its own low end:**

| part | low | high |
|---|---|---|
| orientation | 5 m | 5 m |
| discharge database: 2 tables, 2 columns (one masked), flag, split operation, commit + rollback changes (P2, P3), transform + confirm + manual branches, record / correct / assign / count / verify / split functions, 2 arms, V9 | 45 m | 80 m |
| energy database: 3 tables (one masked + lines), transform + confirm branch, readings functions, preview + post allocation (GL), energy views, V25 | 35 m | 65 m |
| fixtures: 255 discharge (~9 arms) + 256 energy (~6 arms incl. ledger and AP = ledger), ~45 injections; 158 / 165 / 251 / 253 / 111 / 47 edits | 45 m | 90 m |
| GL proof on live (rolled back): allocation posts once, reconciliation 0.00 | 10 m | 20 m |
| pages: 1–2 new (`/finance/electricity`, `/new`), ~7 changed | 40 m | 80 m |
| messages en / zh, error families | 10 m | 15 m |
| proof scripts and role table | 10 m | 20 m |
| static checks | 5 m | 10 m |
| docs (gateway-interface §7b/§7c, pending values, known issues, role matrix, change log, arm inventory) | 10 m | 15 m |
| **total** | **3 h 35 m** | **6 h 40 m** |

**Estimate, one cut: floor ≈ 1 h 25 m – 1 h 50 m + work ≈ 3 h 35 m – 6 h 40 m = ≈ 5 h 00 m – 8 h 30 m.**
MES-0's figure was 7 h 10 m – 12 h 30 m. The last six cuts landed at 0.61–1.07 of their low ends, so the honest single number is ≈ 5 h. That is
**1.4× the largest measured MES cut**.

**Split (Q2):**
- **MES-5a-1 Discharge:** floor 1 h 25 m – 1 h 50 m + work 2 h 05 m – 3 h 50 m = **3 h 30 m – 5 h 40 m**.
- **MES-5a-2 Energy:** floor 1 h 20 m – 1 h 45 m + work 1 h 40 m – 3 h 10 m = **3 h 00 m – 4 h 55 m**.
- The split costs one more floor (≈ 1 h 25 m) and one more window, and buys two cuts each within the measured range, each with one proof shape.

## §10 · Assertions measured and found false or imprecise

1. **MES-0 Q24 / §1.1 row 2: "`commit_processing_run.sql:354-363`".** The flip is now at `:466-478` (inbound) and `:519-531` (output); `:354-363` is output-weighing calibration code.
2. **MES-0 §0.7 / §1.2: the Tim ruling at `inbound_safety_states.sql:44-50`.** It is at `:49-55`.
3. **MES-0 §1.1 row 3: "posted Dr 5110 / Cr 2200 (`allocate_processing_costs.sql:260`)".** `:260` is a comment. The posting is the trigger `fin_journal_cost_entry` (`finance_journal_triggers.sql:42-101`), dated `CURRENT_DATE`.
4. **MES-0 §7: "每吨" at `docs/forward-queue.md:1689`** (also cited as `:1865`). It is now at `:1891`, and "operation ↔ asset link … 今天根本不存在" ("does not exist at all today") at `:1892` is stale: MES-4a built `operation_type_equipment`. The `processing_runs.equipment_id` column comment (`processing_runs.sql:214-218`) says the same stale thing.
5. **MES-0 Q26: "allocation writes `processing_cost_entries(electricity, is_estimate = false)` and relieves estimates".** Taken literally alongside a bill recorded as an expense, this double-posts (§1.7). It is a mechanics gap in the ruling, put to Tim as Q24.
6. **`docs/change-log.md` §12.1 / §13.1: "7 exclusions … stays 7".** Fixture 235 asserts **8** (`235-…:134`, since MES-3b's `scan_events`).
7. **MES-0 Q23 / MES-0 §1.1 row 2: "Whole-batch flip on partial discharge [I]".** Now **measured** (P1).
8. **Not in any record before this survey:** P2 and P3 (§1.3).
9. **`relieve_processing_accruals.sql:105` inserts its expense with the literal `'SGD', 1`** while its journal uses `base_currency_code()`. `scripts/check-currency-literals.mjs` scans SQL judgements (`=` / `<>`), not `VALUES` literals, so it passes. It is a blind spot, not a live wrong number while the base is SGD. Not fixed here (Q35).
10. **`app/finance/month-end/allocationActions.ts:3,12` says the default basis is `metal_value`.** The function uses the run's chosen basis.

---

## §11 · Tim's own facts this cut needs (not questions of design)

- Whether the Bosch cabinet exports per-module voltage (spec §8.1). Until it does, results are entered per module by hand (MES-0 Q25), and the batch shows "per-module data not exported".
- How modules are identified on the floor (serial plate, sticker, position). This feeds Q3.
- Which meters the electrical contractor installs, and on which machines. Until then: 0 meters, and the energy pages show "no meter registered".

## §12 · Every open question, with a recommended answer and its evidence

### A · Scope

❓ **Q1 — Contents.** MES-0 §8.2 said 4 tables / 4 pages.
➡️ **As §2:** discharge — 2 tables, 2 columns (one masked), a flag, a split operation, the commit and rollback changes, 2 transforms. Energy — 3 tables (allocation + lines, masked amounts), readings, allocation. Pages: 1–2 new, ~7 changed. Left out: §2's list.

❓ **Q2 — One cut or two.** Combined ≈ 5 h 00 m – 8 h 30 m, 1.4× the largest measured MES cut (3 h 35 m). The halves share no table. Their proofs differ: safety admission and stock versus GL posting and AP = ledger — MES-0 §8.3's own reason for every other pair.
➡️ **Two cuts: MES-5a-1 Discharge (≈ 3 h 30 m – 5 h 40 m), then MES-5a-2 Energy (≈ 3 h 00 m – 4 h 55 m).** One extra floor (≈ 1 h 25 m), and each cut stays within the measured range. If Tim prefers one cut, the plan in §2 holds unchanged.

### B · Discharge

❓ **Q3 — Module identity.** No module identity exists anywhere (MES-0 §1.1 row 2).
➡️ **`module_ref` text, required, unique among the batch's modules.** It holds the module's serial if one is legible, otherwise a position label the operator writes on it (M01, M02…). A re-discharge reuses the same ref. The channel is a separate field.

❓ **Q4 — How the batch knows how many modules it has.** A required field enforces nothing at commit (§1.4).
➡️ **`module_count` on both batch tables.** The inbound column follows the three-change rule.
- Optional at receipt, as a trailing parameter defaulted NULL (the MES-4b construction pattern), and settable on the batch page by the batch module's edit code or `action.processing_commit`.
- **Required before the first module result is recorded** (`BATCH_MODULE_COUNT_REQUIRED|<batch>`).
- Editable, change-logged, until the batch is verified; then locked (`MODULE_COUNT_LOCKED|<batch>`).
- Not required to commit the run, so a discharge can start before anyone has counted.

❓ **Q5 — Where verification happens.**
➡️ **Not at commit any more.** A flag `operation_types.verifies_by_unit`, seeded TRUE on `deep_discharge` only — data, not a code list, like `requires_cell_construction`. When it is set, `commit_processing_run` records the run and leaves the state alone. The flip is written by the result functions when the batch's results complete, with `created_by_run_id` / `ended_by_run_id` exactly as today, so state history and rollback keep working.

❓ **Q6 — The verification rule (MES-0 Q23, made exact).**
➡️ **A batch becomes `discharged_verified` when every one of its `module_count` modules either has a current `pass` result (latest non-superseded row, on a non-reversed run) or has been split out to quarantine.**
- A failed module marked `re_discharge` keeps the batch `charged_not_discharged` until a later pass.
- A count of results above `module_count` is refused (`DISCHARGE_MODULES_EXCEED_COUNT`).

❓ **Q7 — What a module result row holds.**
➡️ **Required:** module ref, outlet voltage (V, ≥ 0), verdict (`pass` | `fail`), verdict time, source.
**Required when the verdict is `fail`:** disposition `re_discharge` | `quarantine` (spec §3.1 "mandatory field").
**Optional:**
- channel, start voltage, duration (min), energy recovered (Wh);
- a screen photo in the existing `capture-photos` bucket (MES-0 Q25);
- inbox, draft and site pointer (device rows).
**Corrections** are rows with a reason (`corrects_id`). No other column.

❓ **Q8 — Who decides the verdict, and V9.**
➡️ **The verdict is recorded as given** — by the cabinet, or by the operator reading it.
- **V9 is per material** (`materials.discharge_pass_voltage_v`), because a module's end voltage depends on its series count (§1.9).
- V9 only **flags** a pass whose voltage is above it, or a fail below it. It never refuses and never decides.
- Empty V9 means "could not be judged".
- Duration is recorded, not judged: no threshold value in this cut.

❓ **Q9 — Channel → module assignments.**
➡️ **`discharge_channel_assignments` per run, append-only with corrections.** They are recorded when modules are loaded. They are required for device rows that arrive keyed by channel: the transform resolves channel → module, and an unassigned channel fails the transform visibly in the inbox. They are optional for manual entry, which names both.

❓ **Q10 — Entry paths and codes.**
➡️ **One pipe** (MES-0 §3.5):
- manual results go through `submit_manual_capture('discharge_module', …)` with the run as subject;
- device rows become drafts confirmed through `confirm_capture_draft`;
- `capture_confirm_internal` gains a discharge branch, and `submit_manual_capture` accepts `discharge_cabinet`.
- **Code: `action.confirm_capture`** for both, the code the capture pipe already uses. Live: admin, cto, warehouse — 3 accounts.
- Channel assignment and the quarantine split use `action.processing_aftercare` (MES-4a's "after commit" code; live: admin, warehouse).

❓ **Q11 — The quarantine split mechanism.** No batch split exists (§1.5).
➡️ **A new transforming operation `discharge_quarantine_split`, run from the discharge run's page.** One action: pick the failed modules marked `quarantine`, weigh them (typed or picked, MES-4a's every-output-weighed rule) and pick a quarantine location. It then, in one transaction:
- commits a run that consumes that mass from the parent batch;
- produces one output batch of the same material;
- records the moved module refs;
- sets the new batch `charged_not_discharged`;
- transfers it into the chosen quarantine location (MES-3a's gate allows transfers into quarantine).

It is **refused when no quarantine location exists** (`QUARANTINE_LOCATION_REQUIRED`; V34 — live has 0). It reuses lineage, allocation, rollback and balance as they are. The parent's verification counts split modules as resolved.

❓ **Q12 — Re-discharge.**
➡️ **A later `deep_discharge` run on the same batch records new results under the same module refs; the latest wins.** The re-discharge count per module is derived (results − 1) and is not stored.

❓ **Q13 — Pages.**
➡️ **No new route for discharge.**
- A "Module results" panel on `/operation/processing/[id]` for discharge runs: channels, entry, results with flags, completeness "n of N verified", and the split action.
- Module count and the per-module summary on both batch pages.
- `/operation/processing/new` shows the input's module count. It does not refuse without one, because Q4 refuses at the first result instead.

❓ **Q14 — Fix P3 (discharging a self-produced batch drains its stock).**
➡️ **Yes, in this cut.** The output-side branch takes the same `v_consumes` guard the inbound side has (`:435`), and fixture 165 K7 gains the stock assertion. It is the same lines Q5 rewrites, and an unfixed stock drain on a discharge is a wrong number.

❓ **Q15 — Fix P2 (a discharge cannot be reversed once its batch was partly used).**
➡️ **Yes, in this cut.** `rollback_processing_run_internal` restores stock only for runs whose operation consumes. Otherwise it only reverses state, cost and results. A new arm reverses a discharge after a downstream run.

❓ **Q16 — Existing discharge history on live.**
➡️ **No back-fill** (MES-0 Q94). PROC-2026-0494 (reversed) gets no results. The open `discharged_verified` on one inbound batch and `charged_not_discharged` on one output batch stay as recorded.

❓ **Q17 — Deep-discharge fields (MES-4a seeded none).**
➡️ **None.** Every per-batch figure the spec lists (§3.1i: count, duration, energy recovered, failed count and disposition) is derived from module rows and the run header, shown on the run and batch pages. Storing them again would create a second source that can disagree.

❓ **Q18 — Reminders.**
➡️ **Two arms (57 → 59), both under `module.processing.view`:**
- `discharge_unverified` — a batch with a committed discharge run that is not verified. Its `item_id` is the latest such run.
- `discharge_quarantine_pending` — a module whose current result is `fail` / `quarantine` and that has not been split. Its `item_id` is the run.

### C · Energy

❓ **Q19 — What a meter attaches to.**
➡️ **A `meter` device; its machine is `devices.equipment_id`, and NULL means the shared pool** (MES-0 Q27). No new mapping table. The machine is set on the device page under `action.manage_devices` (live: admin, cto).

❓ **Q20 — Readings.**
➡️ **Cumulative register readings (kWh at a moment), append-only, corrections with a reason.**
- A reading below the previous one is refused unless it is marked as a register reset, with a reason.
- Manual entry is on the device page under `action.confirm_capture`; the device path goes through `transform_meter_reading_v1`.
- No reading frequency is imposed.

❓ **Q21 — Energy per run.**
➡️ **The run's own `energy_kwh` value where recorded** (controller or operator — MES-4a fields on four operations). Otherwise the machine's metered kWh is split by Q22. Discharge runs show **energy recovered** separately; it is never netted against consumption.

❓ **Q22 — Splitting a machine's metered kWh across its runs in a period.** An allocation rule nobody has ruled (§1.8).
➡️ **By recorded run energy when every run of that machine in the period has `energy_kwh`. Otherwise by run time (`ended_at − started_at`), with the basis printed on every line** ("split by run time — controller energy not recorded"). Tim to confirm or replace.

❓ **Q23 — The per-tonne denominator** (`docs/forward-queue.md:1891`, open since PROC-SUPPORT-1).
➡️ **`total_input`.** Every per-mass figure the MES group has defined is "% of input": V1 tolerance, V10 share, closure.

❓ **Q24 — The bill's posting path** (§1.7).
➡️ **The allocation is the bill's single entry.** In one transaction:
- it records the bill once as an expense document (supplier, invoice reference, date, amount, payment status — the `relieve_processing_accruals` shape);
- it writes each run's electricity cost line for its share;
- it settles those lines in its own journal (Dr 2200 for the shares, Dr 6200 for the unmetered or shared remainder, Cr AP / bank for the bill);
- it relieves any hand-typed electricity estimate on the same runs in that period, so no run carries both.

The ledger shows the bill exactly once. Proof: AP list = ledger and reconciliation 0.00 on a rolled-back live posting. A preview function shares the arithmetic (AGENTS.md).

❓ **Q25 — The unmetered and shared remainder (V25).**
➡️ **Overhead (6200) until V25 is set; V25 is Tim's rule for spreading the shared pool.** Its arm shows while a shared-pool meter exists and the rule is empty.

❓ **Q26 — Hand-typed electricity lines.**
➡️ **Stay** (MES-0 Q26: manual entry stays for unmetered machines). An allocation relieves only the estimates on the runs it covers.

❓ **Q27 — Who allocates.**
➡️ **`module.finance.edit`**, the code of `allocate_processing_costs`, remit and relieve. Live: admin, finance — 2 accounts.

❓ **Q28 — Currency of the bill.**
➡️ **Base currency only. A foreign-currency bill is refused by name (`ELECTRICITY_BILL_CURRENCY_NOT_BASE`).** Utility bills are local. The base currency is read from `currencies.is_base`; relieve's `'SGD', 1` literal is not copied (§10.9).

### D · Governance

❓ **Q29 — Approvals.**
➡️ **None new.** These are records of events; the bill's payment goes through payment requests (tiered 1,000).

❓ **Q30 — Masking.**
➡️ **Allocation and line amounts behind `data.view_prices`** (the processing-cost rule, `change_log_mask_rules.sql:102`): column grant + `_masked` view + mask rules in one migration. kWh, voltages, verdicts and counts are open to their module's view code. `inbound_batches.module_count` goes into the grant and `inbound_batches_masked`.

❓ **Q31 — Change log and trails.**
➡️ **Every new table bound, no exclusion (fixture 235 stays 8).** Trails as §6; wording arm ㉑ with its own fault.

❓ **Q32 — Pending values.**
➡️ **V9 and V25 as §7, each with its arm and its `docs/mes-pending-values.md` row in the same commit.**

### E · Migration, fixtures, records

❓ **Q33 — Migration and window.**
➡️ **Accept §8.** One migration per cut. In the discharge window a discharge run commits but does not verify its batch until results are entered after the deploy; live has no MES-4a-era run, so nothing is affected. Aim ≈ 1 h.

❓ **Q34 — Existing fixtures that assert the flip at commit (158 D4, 165 K7, 251 RUN, 253 DISCH).**
➡️ **Move each flip assertion to after the module results, and add the counter-assertion that the commit alone no longer verifies.** No assertion is removed. Each new arm is fault-injected.

❓ **Q35 — `relieve_processing_accruals`'s `'SGD', 1` literal and the currency check's blind spot for `VALUES` literals.**
➡️ **Record both in `docs/known-issues.md` in MES-5a-2.** Fix the literal there if MES-5a-2 touches that function. Widening the check is a separate decision: a check that suddenly scans `VALUES` would need its own allowlist pass.

❓ **Q36 — Stale records found (§10.3, §10.4, §10.6, §10.10).**
➡️ **Correct them in the cut that touches each file.** The `processing_runs.equipment_id` comment and `forward-queue.md:1892` go in MES-5a-1. `change-log.md` §12.1 / §13.1 and the month-end comment go in whichever cut edits those files first. No separate cut.

## §13 · Stop

No code edits and no migrations. Waiting on Tim's answers to Q1–Q36.
