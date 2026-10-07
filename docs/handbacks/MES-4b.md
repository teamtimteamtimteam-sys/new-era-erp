v1.4.42 — Products and processing detail: cell batches can now record whether the cells are wound or stacked, and electrode separation requires it; six new products (cathode powder, anode powder, copper foil, aluminium foil, collected dust and harness/BMS/busbar) get their own batch number prefixes such as CPW and DST; each loss now shows whether it was measured or calculated, and electrolyte evaporation can be calculated from a set share; and cathode and anode contamination checks are recorded per shift, with a reminder when a shift has none.

# MES-4b — cell construction, output products and numbering, loss basis and electrolyte, contamination checks (MES group, sixth cut; 2026-10-07 → 08)

Tim answered MES-4b Step 0 on 2026-10-07: every recommendation for Q1–Q34 in `docs/surveys/MES-4b/STEP0-HANDBACK.md` accepted, except
**Q9** (the six forms: collected dust is **not** saleable for now; the other five — anode powder included — are saleable) and **Q17**
(`operation_types.electrolyte_loss_applies`, labelled "Electrolyte evaporates in this step", editable on the operation page under
`module.processing.edit`, seeded FALSE everywhere — Tim ticks it himself; `electrolyte_share_pct` (V10) unchanged; the electrolyte-evaporation
category says the evaporated electrolyte is carried by the extraction airflow to the back-end environmental equipment and stays a named loss;
the compressor is equipment, not an operation). Migration `db/migrations/2026-10-07-mes4b-fields-and-products.sql` (built from the mirrors by
`db/scripts/build_mes4b_migration.py`). Opening SHA: HEAD = origin/main = `git ls-remote` = `e54a0b5e680be679b4bee465c80dc5be91059783`, tree clean.

---

## §0 · Opening live readings (before anything changed)

Read on live 2026-10-07 22:04 CST (and the stable digests again 23:30, before the backup), as `postgres` (`rolbypassrls = true`) on base tables,
read-only (`db/scripts/2026-10-06-mes1-live-readings.sql` + `db/scripts/2026-10-07-mes4b-live-readings.sql`; reconciliation by
`db/scripts/2026-10-05-at1d3-live-recon.sql` in tim@'s session).

| Reading | Value |
|---|---|
| Accounts | 7, none disabled, 0 throwaway — admin@ admin · chooer@ finance · fusheng@ warehouse · phua@ cto · sandra@ cco · tim@ cfo · vince@ gm |
| Approvals | ON |
| Pending documents | 1 — `expense_claim` CLM-2026-0004, 1,000.00; its decider (tim@) is not its submitter |
| `material_forms` | 13 rows (digest `e5a41cc35076`) |
| `materials` | 9 rows (`f59204c998e3`): 5 live, 4 with no form, 1 processable |
| `output_batches` | 20 rows (`9472ede0319b`), 14 live; one prefix (`OUT-2026-…`), highest number 381; every one on a form-less material |
| `output_code_seq` · `inbound_code_seq` | 679 · 488 |
| `inbound_batches` | 24 rows (`d0d87c2f9b37`), 15 live |
| `document_types` | 43 |
| `loss_categories` | 7 (the 6 other than electrolyte: `71a59018abe1`) · `processing_run_losses` 0 rows |
| `processing_runs` | 14 rows (`1178654c22aa`); MES-4a runs (with a start time) 0 |
| `operation_types` | 7 rows (`e787b09161e0`) |
| Shifts | day / night, neither with times |
| `assay_results` | 4 (0 on output batches) |
| Calibration switch (`require_calibrated_since`) | NULL |
| Pending-value arms read as `postgres` | 0 (the view asks `has_permission`, which is false with no JWT — a measured empty, not a statement about live) |
| `change_log` | 12,364 rows, max seq 13,974 (unchanged between the backup and the apply) |
| Reconciliation (tim@) | AP list 422,188.32 / ledger 381,604.42 / **unexplained 0.00** · AR 57,545.87 / 43,002.12 / **0.00** |

## §1 · Role-by-role reading table (live, measured)

Read on live after the migration (`db/scripts/2026-10-07-mes4b-live-role-table.sql`, `ROLES_OWN_EXIT=0`, 2026-10-08 01:19 CST): each real
account's own session (`SET LOCAL ROLE authenticated` + its JWT), one transaction rolled back. A ✓/— cell is the code the page's gate asks
(`has_permission` — the same predicate as `can()`); a number is the rows that account reads itself.

| Account (role) | `/operation/contamination`: open · shift cells · checks · streams | Run page: open · record a check · calculate electrolyte · record a measured loss · edit the electrolyte setting | Inbound batch page: open · constructions read · set construction (inbound) · set construction (output) | Dictionaries edit (the two new) | V10 + V11 rows |
|---|---|---|---|---|---|
| admin@ (admin) | ✓ · 0 · 0 · 2 | ✓ · ✓ · ✓ · ✓ · ✓ | ✓ · 3 · ✓ · ✓ | ✓ | 2 |
| chooer@ (finance) | ✓ · 0 · 0 · 2 | ✓ · — · — · — · — | ✓ · 3 · ✓ · ✓ | — | 2 |
| fusheng@ (warehouse) | ✓ · 0 · 0 · 2 | ✓ · ✓ · ✓ · ✓ · — | ✓ · 3 · ✓ · ✓ | — | 2 |
| phua@ (cto) | ✓ · 0 · 0 · 2 | ✓ · — · — · ✓ · ✓ | ✓ · 3 · ✓ · ✓ | ✓ | 2 |
| sandra@ (cco) | ✓ · 0 · 0 · 2 | ✓ · — · — · ✓ · ✓ | ✓ · 3 · ✓ · ✓ | ✓ | 2 |
| tim@ (cfo) | ✓ · 0 · 0 · 2 | ✓ · — · — · — · — | ✓ · 3 · — · — | — | 2 |
| vince@ (gm) | ✓ · 0 · 0 · 2 | ✓ · — · — · — · — | ✓ · 3 · — · — | — | 2 |

How to read it: everyone can open the three pages and read the 3 constructions and 2 streams. 0 shift cells and 0 checks are measured empties
(live has no MES-4a run producing a sheet, and no check), not restrictions — the codes beside them say so. 2 pending-value rows = V11 for both
streams (V10 is 0: no operation is ticked). chooer@ (finance) can set a construction because the finance role holds `module.inbound.edit` /
`module.output.edit` today (measured, not granted by this cut). A "—" control renders visible and unpressable, with a sentence naming the code
(DBLOCK-1). **No grant changed.**

## §2 · Every item built

**Database (one migration).**
- Three new tables: `cell_constructions` (wound · stacked · unknown, Q3; RUNTIME CONFIG), `contamination_streams` (cathode sheet with anode in
  it · anode sheet with cathode in it, warning line V11 empty; RUNTIME CONFIG), `contamination_checks` (append-only; `sampled` with sample and
  foreign mass, the rate and "above the warning line" computed by the database; or `not_sampled` with a reason; the warning line in force copied
  onto the row; corrections are rows).
- New columns: `inbound_batches.cell_construction_code` (also in the column-list grant and `inbound_batches_masked`, one migration) and
  `output_batches.cell_construction_code`, both guarded by `guard_batch_cell_construction` (only on cell forms — a form-less material may carry
  one; locked once the batch fed a committed run); `material_forms.output_document_key`; `processing_run_losses.basis` (measured | derived) and
  `derived_share_pct` (present exactly when derived); `loss_categories.may_be_derived` (electrolyte evaporation only);
  `operation_types.electrolyte_share_pct` (V10), `electrolyte_loss_applies` (seeded FALSE everywhere, Q17), `requires_cell_construction`
  (electrode separation and electrode line).
- Six forms (Q9): cathode powder, anode powder, copper foil, aluminium foil, collected dust (not saleable), harness/BMS/busbar; seven
  operation ↔ form information rows (Q10).
- Twelve output document types on `output_batches` (CPW · APW · CUF · ALF · SEP · DST · CEL · CSG · STR · HBB · CTS · ANS), each with its own
  gapped sequence; `generate_output_code` chooses form → registry key → prefix + sequence, falls back to `OUT`; five digits for the new ones, four
  for OUT; nothing truncates. The eleven gapped generators stop truncating (`LPAD(n, GREATEST(4, length(n)), '0')`, identical below 10,000).
- `commit_processing_run`: an operation that requires construction refuses an input whose construction is not determined
  (`INPUT_CELL_CONSTRUCTION_REQUIRED|<batch>`, after the safety-state refusal); outputs on a cell form inherit the construction when every input
  agrees.
- `create_inbound_batch` / `receive_inbound_batch_against_po`: new trailing `p_cell_construction` (default NULL; unknown code refused by name).
- New functions: `set_batch_cell_construction`, `record_derived_electrolyte_loss`, `rederive_electrolyte_loss`, `record_contamination_check`,
  `correct_contamination_check`; internal `contamination_check_internal` (revoked). `record_run_loss` / `correct_run_loss` write `measured`.
- Views: `contamination_shift_status_all` (owner, revoked) with its gated reader `contamination_shift_status`; `contamination_check_rows`;
  `operations_now` + arm `contamination_check_missing` (57 arms); `pending_values` + V10, V11 (17 arms); `processing_run_balance(_all)` gains
  `derived_loss_qty`; `inbound_batches_masked` and `material_lookup` (`form_code`) gain a column.
- Trail: contamination checks on `processing_run` (home) and `output_batch`; two dictionary subjects. Change log: three new bindings (267 bound).
- `RUNTIME_CONFIG_TABLES` (check_mirrors) gains `loss_categories`, `loss_metal_fates`, `cell_constructions`, `contamination_streams`.
  **Bootstrap still correct (AGENTS.md):** no seeded column changed meaning; the two loss tables were simply unclassified before.

**Fixtures.** New fixture 254 (arms CC · FORM · NUM · LOSS · CONT · DUST · PV), fault-injected per arm
(`db/scripts/2026-10-07-mes4b-fixture-injections.py`, **37 cases, 0 wrong**, `INJECTIONS_OWN_EXIT=0`). Changed: 100 (55 rows, 23 gapped,
widths), 111 (57 arms), 113 (19 forms), 153 (basis on direct inserts), 195 (E4 reads every output prefix from the registry, a `CEL-` injection
must be caught and the old `OUT-` regex is shown to miss it), 253 (wound input for IB5; TRAIL asserts `trail_refs` and `trail_ref_label`; the
direct-insert probe carries `basis`, so it tests the grant and not the new NOT NULL), 245 (leave date = first business day from +30 — see §6).

**App.** See §3. Error sentences for 22 new refusal codes (en / zh); pending-values labels V10, V11; dashboard item; two dictionaries
(decimal field kind); nav entry and `FN.contamination`; trail wording arm ⑳ (`scripts/check-trail-wording.mjs`, fault
`wording-drift-mes4b` turns it red, measured exit 1); search docType labels for the 12 new keys.

## §3 · Pages — every new or changed route, with its file

| Route | File(s) | What changed |
|---|---|---|
| `/operation/contamination` (new) | `app/operation/contamination/page.tsx`, `ContaminationGrid.tsx`, `ContaminationChecksList.tsx`, `checkRows.ts` | per shift × stream: sampled / not sampled / missing, rate and flag; the checks list with corrections |
| `/operation/processing/[id]` | `app/operation/processing/[id]/page.tsx`, `ContaminationPanel.tsx`, `contaminationActions.ts`, `LossPanel.tsx`, `lossActions.ts`, `ProcessingTables.tsx`, `RunRecordPanels.tsx` | contamination panel (record, not sampled with a reason, correct); losses show Measured / Calculated, "Calculate" and "Recalculate" for electrolyte, the category description; inputs show construction; balance shows the calculated part |
| `/operation/processing/new` | `app/operation/processing/new/page.tsx`, `NewProcessingForm.tsx` | on an operation that requires construction, an undetermined input is blocked with a sentence and a link to its batch page |
| `/operation/operation-types/[code]` | `app/operation/operation-types/[code]/page.tsx`, `OperationTypeEditor.tsx`, `../actions.ts` | Electrolyte section: the tick, the share (or "Not yet set"), and a note when the operation requires construction |
| `/inbound/new` | `app/inbound/new/page.tsx`, `NewInboundForm.tsx`, `actions.ts`, `app/inbound/CellConstructionField.tsx`, `cellConstructionQuery.ts` | construction picker for cell forms |
| `/inbound/receive` | `app/inbound/receive/page.tsx`, `ReceiveForm.tsx`, `actions.ts` | the same picker |
| `/inbound/[id]/edit` | `app/inbound/[id]/edit/page.tsx`, `app/components/batch/CellConstructionPanel.tsx`, `cellConstructionActions.ts` | set the construction later; locked after a committed run |
| `/output/[id]/edit` | `app/output/[id]/edit/page.tsx` (same panel) | the same, for output batches |
| `/settings/dictionaries` | `app/settings/dictionaries/registry.ts`, `DictSection.tsx`, `page.tsx` | Cell constructions and Contamination streams (warning line, decimal); header row wraps (390 px fix, §4 step 10) |
| `/settings/pending-values` | messages only | V10, V11 |
| `/tools/reminders`, dashboard | `lib/reminders.ts` | `contamination_check_missing` |

## §4 · Verification, in the brief's order

| # | Step | Result |
|---|---|---|
| 1 | Offline gate | `GATEOFF_EXIT=0` (third run, after the fixture fixes from the first two) |
| — | Preflight + live dry run (COMMIT → ROLLBACK, grants replayed) | preflight passed (26 functions: 16 replaced · 10 new; 9 columns, 1 on a masked table); `DRY_PROBE \| 55 \| 19 \| 3 \| 2` (document types · forms · constructions · streams), `DRY_OWN_EXIT=0` |
| 2 | Backup (background) | `BACKUP_EXIT=0`, `evoltrya-backup-2026-10-07-2325.dump` (6,963,522 bytes; TOC 8,168 entries); change log unchanged between it and the apply |
| 3 | `apply_migration.sh` | `APPLY_OWN_EXIT=0`; applied 23:55:15, **committed 23:58:59 CST = window start** (`db/migration-windows.tsv`) |
| 4 | `types:gen` | `TYPES_OWN_EXIT=0`; replaced the temporary splice |
| 5 | tsc | `TSC_OWN_EXIT=0` |
| 6 | `npm run build` | `BUILD_OWN_EXIT=0`; **re-run after the last app change** (DictSection, trail wording): `BUILD_EXIT=0` |
| 7 | Full gate | first run `GATE_EXIT=4`: fixture 245 refused its own setup (`NO_WORKING_DAYS\|2026-11-07`) — it booked leave on `CURRENT_DATE + 30`, which became a Saturday when the clock passed midnight; not caused by this cut (§6 decision 11). Fixed, plus the fixture-253 edits (Q32), then **`GATE_EXIT=0`** (545 s): rebuild ✓ · mirrors vs live ✓ (incl. generated types) · fixtures ✓ (257) · anonymous surface ✓ (subset of the 328-line baseline) |
| — | Mirror-list fault injection | a temporary view-phase file emptied the four RUNTIME CONFIG tables after replay: offline gate `GATEOFF_EXIT=1`, `bootstrap ✗ 引导后为空:['cell_constructions', 'contamination_streams', 'loss_categories', 'loss_metal_fates']`; file removed; the clean full gate above is the control |
| 8 | i18n | `I18N_OWN_EXIT=0` (and again inside the re-run build) |
| 9 | Error swallowing | `SWALLOW_OWN_EXIT=0` (and again inside the re-run build: 0 unallowed) |
| 10 | Layout survey, 10 pages, 1280 px and 390 px | 1280: **10 / 10** usable. 390: 8 / 10 — `/operation/processing/new` +177 px (an input-batch `<select>`: the same page, the same culprit and exactly the same +177 px MES-4a measured and proved pre-existing; not fixed here) and `/settings/dictionaries` +19 px (the "edit rights" line pushed out of a non-wrapping header row by the two new, longer section titles — **mine**). Fixed with `flex-wrap` on that row; re-measured: **0 px at 390 and at 1280** |
| 11 | Smoke (background) | `SMOKE_EXIT=0` — **273 ok, 12 skipped (no data), 0 failed** (247 routes timed). Its default pick for `/operation/operation-types/[code]` was
`electrode_line` (1 change-log row → entries required) — green. **Q31, the two other arms:** `SMOKE_ONLY` + `SMOKE_TRAIL_BLANK=1` →
`SMOKE_EXIT=1` ("data-audit-trail=\"empty\" … electrode_line has 1 row that should read as entries"); `SMOKE_ONLY` + `SMOKE_OPTYPE_CODE=deep_discharge`
(0 change rows, empty allowed) → `SMOKE_EXIT=0`. **Scratch reading:** at start, the same 6 stale rows MES-4a reported (`ZZ-SMOKE-*`,
849–1,492 h old, five still referenced) — none from this cut; each run's own throwaway account was cleaned (closing readings: 0 throwaway accounts,
`roles` / `role_permissions` / `user_roles` / `employees` digests identical to the opening). |
| 12 | MES-4a fault-injection re-run (Q32) | §5.5 |
| 13 | Live verification | §5 |

## §5 · Live verification

### §5.1 · Rolled-back proofs — `db/scripts/2026-10-07-mes4b-live-proof.sql` (`PROOF_OWN_EXIT=0`, one transaction, ROLLBACK)

Each step in a real account's own session (fusheng@ warehouse for floor work, phua@ cto for configuration); all data mine
(`ZZ-PROBE-MES4B-*`: one supplier, 13 probe materials — one of each new form plus the cell and sheet forms); no existing document, batch or run
read or written. Dry-run first on the local rebuild.

| Step | Who | Reading |
|---|---|---|
| Receive a cell batch with and without a construction | fusheng@ | IN-2026-0489 with wound, IN-2026-0490 with none |
| Set the missing one on the batch page's path | fusheng@ | `set_batch_cell_construction` → stacked |
| Separation on an unknown-construction input | fusheng@ | `INPUT_CELL_CONSTRUCTION_REQUIRED\|ZZ-PROBE-MES4B-IB-UNK` |
| Commit on wound input; inheritance | fusheng@ | PROC-2026-0722 committed on wound input; casing removal PROC-2026-0723 → **CEL-2026-00001 inherits wound** |
| The lock | fusheng@ | changing the input batch's construction → `CELL_CONSTRUCTION_LOCKED\|PROC-2026-0722` |
| Outputs of each new form get their prefix | fusheng@ | **CPW-2026-00001 · APW-2026-00001 · CUF-2026-00001 · ALF-2026-00001 · DST-2026-00001 · CEL-2026-00001**, plus CTS-2026-00001, ANS-2026-00001 (sheets) and OUT-2026-0680 (a form-less black-mass material → OUT, four digits) |
| Tick electrolyte, set the share | phua@ | electrode separation ticked, share 12.5 % |
| Derived loss; a closed run reopens | fusheng@ | 12.5 kg (12.5 % × 100 kg), basis derived, share kept; the closed balance reopened (`open`) |
| Correct it to measured | fusheng@ | closed again, corrected to measured 11 kg with its reason; reopened again (`open`) |
| Reminder appears | fusheng@ | `contamination_check_missing` shows 2 rows for PROC-2026-0722 (both streams) |
| A check above a set V11 | phua@ → fusheng@ | cathode warning line 1 %; a 2 % check is recorded and **flagged above** (never refused) |
| A not_sampled row with a reason; the reminder clears | fusheng@ | anode not sampled with a reason → reminder 0 rows |
| After ROLLBACK | postgres | probe materials 0 · electrolyte flags 0 · warning lines 0 · contamination checks 0 · batches with a construction 0 |

The proof minted codes from sequences, which do not roll back, so live's next codes skip them: IN-2026-0489/0490, PROC-2026-0722/0723,
OUT-2026-0680, the first number of eight new prefixes (CPW, APW, CUF, ALF, DST, CEL, CTS, ANS → live's first real one will be `…-00002`),
one supplier code and 13 material codes — the same shape as earlier proofs' document codes.

### §5.2 · Read-only

The role table (§1).

### §5.3 · Before and after

Closing readings 2026-10-08 01:19–01:20 CST after the proof and all smoke runs (same scripts, read-only, `postgres`, base tables):
- **Untouched (stable digests, excluding the new columns and rows):** `inbound_batches` 24 / `d0d87c2f9b37` · `loss_categories` (other than
  electrolyte) 6 / `71a59018abe1` · `material_forms` (pre-MES-4b rows) 13 / `e5a41cc35076` · `materials` 9 / `f59204c998e3` · `operation_types`
  (pre-MES-4b rows) 7 / `e787b09161e0` · `output_batches` 20 / `9472ede0319b` · `processing_run_losses` 0 · `processing_runs` 14 / `1178654c22aa`
  — **identical to the opening.** (Whole-row digests of `inbound_batches`, `output_batches`, `loss_categories`, `material_forms` and
  `operation_types` changed only because rows gained the new columns or the seeded values below.)
- **Set by the migration, nothing else:** forms 13 → **19** · document types 43 → **55** · operation ↔ output-form rows 14 → **21** ·
  document-type exceptions 42 → 44 · constructions **3** · streams **2** (V11 empty) · operations requiring construction **electrode_line,
  electrode_separation** · loss rows not measured **0** · batches with a construction **0** · operations with the electrolyte flag or a share **0** ·
  V11 lines set **0** · contamination checks **0** · `require_calibrated_since` NULL · materials created **0**.
- **Sequences:** output 679 → 680 · inbound 488 → 490 (the proof's burned numbers, §5.1).
- **Nothing of mine remains:** `ZZ-PROBE-MES4B%` materials 0, suppliers 0; accounts 7, none disabled, 0 throwaway, 0 grants without account;
  approvals ON; pending 1 — CLM-2026-0004, 1,000.00, unchanged (decider tim@, not its submitter).
- **One other table moved, not by me:** `cod_verification_failures` (1 row, digest changed) — the smoke test's `/verify/cod/[token]` probe deletes
  and inserts one, as in MES-4a.
- **Change log:** 12,364 → 13,757 rows (max seq 13,974 → 15,537). By table: the migration's rows (material forms 6 INSERT + 13 UPDATE, document
  types 12, operation ↔ output forms 7, document-type exceptions 2, operation types 2 UPDATE, loss categories 1 UPDATE) and matched INSERT / DELETE
  pairs from the throwaway-account runs (role_permissions 600 / 600, roles 8 / 8, user_roles 8 / 8, employees 19 / 19, contracts and terms,
  performance reviews). The rolled-back proof and role table left none.
- **Reconciliation (tim@):** AP 422,188.32 / 381,604.42 / **0.00** · AR 57,545.87 / 43,002.12 / **0.00** — identical to the opening.

### §5.4 · Broken window

Opened **23:58:59 CST** on 2026-10-07 (migration committed; `db/migration-windows.tsv`). It closes when the deployment reaches Ready — that end
time comes from Tim, not from this machine. What was broken inside it (old app + new database; **derived**, not measured on live):
- **Nothing that writes is refused by the old app's own calls:** the receipt functions' new parameter has a default; `record_run_loss` /
  `correct_run_loss` kept their signatures and now write `measured`; `commit_processing_run`'s new refusal fires only on electrode separation /
  electrode line with an undetermined input (live has no such run).
- **The old dashboard has no sentence for `contamination_check_missing`** — it would print the raw key if a row existed; live has none (no MES-4a
  run produces a sheet).
- **Everything that reads** kept working — every new column is an addition, appended at the end of the views that gained one.
- Smoke, survey and the proofs ran against the new database with the **new** code (local dev server), so they say nothing about the old app.

### §5.5 · Q32 — the MES-4a injections against the final MES-4b build

`python3 db/scripts/2026-10-07-mes4a-fixture-injections.py` against the local rebuild of the final mirrors: **71 cases, 0 wrong,
`INJECTIONS_OWN_EXIT=0`** (68 before + 3 added). The four names Tim gave, case by case:

| Named item | Case | Red where | Note |
|---|---|---|---|
| `correct_run_header` (after the rename) | **new** — HDR · "a pre-MES-4a run header may be corrected (the renamed refusal is gone)": `IF v_run.started_at IS NULL` → `IF false` | HDR: "correcting a pre-MES-4a header should be RUN_HEADER_PREDATES_RECORD, got OK" | no earlier case reached the renamed refusal |
| `correct_run_header` | CORR · "any header field is correctable" | CORR: `processing_run_corrections_field_check` | unchanged |
| `correct_run_header` | CORR · "a correction leaves no row" | CORR: "each of the six fields should correct, leaving one row each" | unchanged |
| fixture 253 itself | all 71 run against the edited 253 | each in its own arm | the edited arms (HDR via IB5, TRAIL, LOSS) are the ones below |
| fixture 253 · LOSS | "a direct write path is back" | LOSS: "no direct write path should be left, got OK" | **first run** it went red for the wrong reason (`null value in column "basis"` — the probe insert predated the new column); the probe now carries `basis`, so the red is the injected grant + policy letting the insert through |
| `trail_refs` | **new** — TRAIL · "a recorded value no longer names its field": the `processing_run_values` branch → `IF false` | TRAIL: "a recorded value should name its field in the trail (trail_refs)" | needed a new assertion in 253 (it existed only as a smoke-visible string before) |
| `trail_ref_label` | **new** — TRAIL · "a recipe version is no longer labelled code + version": `' v'` → `' version '` | TRAIL: "should be labelled \"ZZ253-STD v1\" (trail_ref_label), got ZZ253-STD version 1" | same |
| record_trail (context) | TRAIL · "a run's trail drops its values" / "a code-keyed root has no members again" | TRAIL | unchanged |

## §6 · Decisions taken without asking

1. **A form-less material may carry a construction.** The guard refuses only when the batch's material has a form that does not imply
   dismantling; with no form at all it allows it. Live's existing materials are mostly form-less (§0), and refusing would make the field unusable
   on them.
2. **A derived quantity is rounded to 3 decimals** (share × total input ÷ 100) — the precision every other loss quantity is shown at.
3. **Calculating (and recalculating) the electrolyte loss asks `action.processing_aftercare` only** — the code that already records values and
   closes balances after commit. Recording a measured loss keeps its MES-4a pair (`aftercare` or `module.processing.edit`).
4. **Correcting a derived row to the same number as a measured figure is allowed.** The same-value refusal applies only when the original was
   measured; switching basis is a real change even when the number matches.
5. **A "not sampled" row requires that the run produced that stream's sheet** (`CONTAMINATION_RUN_HAS_NO_SHEET`), exactly like a sampled one —
   otherwise a run could silence the reminder for a stream it never made.
6. **`material_lookup` gained `form_code`** (appended) so the receipt forms can tell whether a material is a cell form without a second query.
7. **`trail_row_record` left unchanged.** It picks the first document type of a table by key (`db/functions/trail_row_record.sql:85`); with 13
   types now on `output_batches` that is `output_aluminium_foil`, not the OUT row. Harmless, measured by reading: all 13 rows carry the same
   route (`/output`) and link mode, and the returned `doc_key` is read by nothing in the UI (`grep doc_key lib/trail app/components/trail` →
   only the type declaration, `lib/trail/render.ts:27`).
8. **The smoke test picks an operation with changes by default** (`SMOKE_OPTYPE_CODE` overrides; Q31): a changed operation with an empty trail
   fails, an unchanged one may be empty.
9. **Live proof codes are burned** (sequences do not roll back) — §5.1 lists them.
10. **The dictionary header row wraps** (`flex-wrap`), a shared component: every dictionary section benefits; desktop unchanged (measured).
11. **Fixture 245's date was made calendar-proof** (first business day from `CURRENT_DATE + 30`) — a pre-existing time dependency that turned
    the gate red when the clock passed midnight onto a +30 Saturday (fixtures README rule 4). Not part of MES-4b's scope; fixed because the
    gate must be green before the push.
12. **Trail wording arm ⑳ added** — six sentences, generated, read by hand, then pinned (contamination ×3, derived loss, derived → measured,
    construction set on a batch).

## §7 · Assertions measured and found false or imprecise

- **My own fixture-253 probe** (direct insert into `processing_run_losses`) went red for the new NOT NULL rather than the grant once `basis`
  existed — found by the Q32 re-run; corrected (§5.5).
- **Fixture 245** was calendar-dependent (§4 step 7).
- **`survey-phone --routes=/operation/operation-types/[code]`** is not measurable (a text segment with no id source); measured through
  `--paths=/operation/operation-types/electrode_separation` instead.

## §8 · Docs updated

`docs/forward-queue.md` (MES-4b and its two fold-ins closed; the three open plant facts recorded; MES-5a next) · `docs/mes-pending-values.md`
(V10, V11) · `docs/known-issues.md` (`CODE-WIDTH-4`: the 11 gapped generators closed, the 31 yearly-reset generators listed and left) ·
`docs/role-matrix.md` (MES-4b row) · `docs/change-log.md` §17 · `docs/dashboard-arm-inventory.md` (M4b).
