v1.4.43 — Discharge: each module in a discharged batch now gets its own pass or fail result, and the batch only counts as discharged and verified once every module has passed or been split out to quarantine; a batch's module count is recorded on the batch page; failed modules can be split into a separate quarantine batch; and three discharge faults are fixed — a partial discharge no longer marks the whole batch, a discharge can be reversed after part of the batch was used, and discharging a self-produced batch no longer takes stock away.

# MES-5a-1 — discharge by module (MES group, seventh cut; 2026-10-08)

Tim answered MES-5a Step 0 on 2026-10-08: **Q2 split** — this cut is MES-5a-1 Discharge only; MES-5a-2 Energy is a later cut. Every discharge
recommendation in `docs/surveys/MES-5a/STEP0-HANDBACK.md` accepted exactly as stated (Q3–Q18, and the discharge parts of Q1, Q29–Q34 and Q36).
Energy (Q19–Q28, Q35, V25, allocation tables, meter readings) is **not** in this cut — recorded in `docs/forward-queue.md` under MES-5a-2, with
Q22 and Q24 marked as awaiting Tim's ruling. Device transforms: MES-3b Q25 and MES-4a Q14 stand (§2.4).
Migration `db/migrations/2026-10-08-mes5a1-discharge-by-module.sql` (built from the mirrors by `db/scripts/build_mes5a1_migration.py`).
Opening SHA: HEAD = origin/main = `aeb7e3da8d3db43f28414c4f055dc848ac18bf13`.

---

## §0 · Opening live readings (before anything changed)

Read on live 2026-10-08 12:06 CST, as `postgres` (`rolbypassrls = true`) on base tables, read-only
(`db/scripts/2026-10-06-mes1-live-readings.sql` — one digest per public table — plus `db/scripts/2026-10-08-mes5a1-live-readings.sql` —
fingerprints that exclude this cut's new columns, so they compare across the migration; reconciliation by
`db/scripts/2026-10-05-at1d3-live-recon.sql` in tim@'s session). All three `*_OWN_EXIT=0`.

| Reading | Value |
|---|---|
| Accounts | 7, 0 disabled, 0 throwaway; admin@ admin · chooer@ finance · fusheng@ warehouse · phua@ cto · sandra@ cco · tim@ cfo · vince@ gm |
| Approvals | ON |
| Pending documents | 1 — `expense_claim:CLM-2026-0004:1000.00` (not mine) |
| Reconciliation (tim@) | AP list 422,188.32 / ledger 381,604.42 / **unexplained 0.00** · AR 57,545.87 / 43,002.12 / **0.00** |
| `change_log` | 13,757 rows, max seq 15,537 (unchanged at the backup and again right before the apply, 12:25) |
| Discharge runs | 1 — PROC-2026-0494, `reversed`, `deep_discharge`, deleted 2026-08-31 11:54:34 |
| Open discharge-related states | inbound `ZZ-PROCCOST1-DEMO` `discharged_verified` (2026-08-31 11:54:13) · output `OUT-2026-0185` `charged_not_discharged` (2026-09-08 23:19:28) |
| Quarantine locations | 0 |
| `require_calibrated_since` | NULL |
| Batches 24 inbound / 20 output · runs 14 · inputs 14 · outputs 17 · inventory movements 107 · locations 4 · devices 4 | fingerprints in §5.3 |
| Sequences | output 680 · inbound 490 |

## §1 · Role-by-role reading table (live, measured)

Read after the migration (`db/scripts/2026-10-08-mes5a1-live-role-table.sql`, `ROLES_OWN_EXIT=0`, 13:14 CST): each real account's own session
(`SET LOCAL ROLE authenticated` + its JWT), one transaction rolled back. Subjects: the one discharge run on live (PROC-2026-0494, reversed), its
input batch `ZZ-PROCCOST1-DEMO`, and the charged output batch `OUT-2026-0185`. ✓/— is the code the page's gate asks (`has_permission`, the same
predicate as `can()`); a number is rows the account reads itself.

| Account (role) | Run page: open · status · results · channels · splits | Record a result · channels / split · split's commit | Discharge cabinets · quarantine locations visible | Inbound batch page: open · module rows · set count | Output batch page: open · module rows · set count | Open a screen photo | V9 edit · V9 rows | Discharge reminders |
|---|---|---|---|---|---|---|---|---|
| admin@ (admin) | ✓ · 0 · 0 · 0 · 0 | ✓ · ✓ · ✓ | 0 · ✓ | ✓ · 0 · ✓ | ✓ · 0 · ✓ | ✓ | ✓ · 0 | 0 |
| chooer@ (finance) | ✓ · 0 · 0 · 0 · 0 | — · — · — | 0 · ✓ | ✓ · 0 · ✓ | ✓ · 0 · ✓ | ✓ | ✓ · 0 | 0 |
| fusheng@ (warehouse) | ✓ · 0 · 0 · 0 · 0 | ✓ · ✓ · ✓ | 0 · ✓ | ✓ · 0 · ✓ | ✓ · 0 · ✓ | ✓ | — · 0 | 0 |
| phua@ (cto) | ✓ · 0 · 0 · 0 · 0 | ✓ · — · — | 0 · ✓ | ✓ · 0 · ✓ | ✓ · 0 · ✓ | ✓ | ✓ · 0 | 0 |
| sandra@ (cco) | ✓ · 0 · 0 · 0 · 0 | — · — · — | 0 · ✓ | ✓ · 0 · ✓ | ✓ · 0 · ✓ | ✓ | ✓ · 0 | 0 |
| tim@ (cfo) | ✓ · 0 · 0 · 0 · 0 | — · — · — | 0 · ✓ | ✓ · 0 · — | ✓ · 0 · — | ✓ | — · 0 | 0 |
| vince@ (gm) | ✓ · 0 · 0 · 0 · 0 | — · — · — | 0 · ✓ | ✓ · 0 · — | ✓ · 0 · — | ✓ | — · 0 | 0 |

How to read it: everyone opens all three pages. Every 0 is a measured empty, not a restriction — live has no module result, channel assignment,
split, module count, discharge cabinet, V9 value or committed discharge run (so neither reminder has a row); the codes beside them separate
"empty" from "not allowed". Recording a result needs `action.confirm_capture` (admin · cto · warehouse); channels and the split need
`action.processing_aftercare` (admin · warehouse), and the split's own run needs `action.processing_commit` (the same two). Setting a count needs
the batch module's edit code or `action.processing_commit` — chooer@, phua@ and sandra@ have it through `module.inbound.edit` /
`module.output.edit` (held today, not granted by this cut). A "—" control renders visible and unpressable, with a sentence naming the code
(DBLOCK-1). **No grant changed; no approval added (Q29).**

## §2 · Every item built

### §2.1 Database (one migration)
- **New tables** (all append-only, RLS read on processing / inbound / output view, change-logged on `id`):
  `discharge_module_results` (module ref, channel, outlet voltage, start voltage, verdict, verdict time, disposition on a fail, duration,
  energy recovered, the V9 in force copied as `pass_voltage_v_at` and the generated `contradicts_pass_voltage`, photo path, notes, source
  manual | device with device / inbox / draft / site pointers, corrections as rows with a reason; one original per run × batch × module),
  `discharge_channel_assignments` (run × batch × channel → module; corrections and withdrawals as rows), `discharge_module_splits`
  (which modules a split run took out of which batch, into which new batch).
- **New columns:** `inbound_batches.module_count` (also in the column-list grant and `inbound_batches_masked`, one migration — the three-change
  rule) and `output_batches.module_count`, both guarded by `guard_batch_module_count` (cell forms only — a form-less material may carry one;
  never below the modules that already have a result, never cleared once there are results; locked once the batch is discharged and verified);
  `materials.discharge_pass_voltage_v` (V9); `operation_types.verifies_by_unit` (seeded TRUE on `deep_discharge` only) and
  `operation_types.started_from_run_page` (TRUE on the new split operation).
- **New operation** `discharge_quarantine_split` (transforming, sort 8): accepts `charged_not_discharged` and `discharged_verified`
  (neither resolved), four input and four output forms (whole pack, module, loose cells, mixed unsorted). Two relation exceptions for
  `discharge_module_splits`.
- **Commit and rollback.** `commit_processing_run`: a `verifies_by_unit` operation records the run and **leaves the safety state alone** (Q5);
  the output-side stock drain is inside `IF v_consumes` (P3). `rollback_processing_run_internal`: restores stock only for consuming operations
  (P2), and re-judges each input batch's verification after the reversal.
- **Verification** (`discharge_verify_batch`, internal): a batch with results is verified when it has a module count and every counted module
  is either passed (latest current result, on a run not reversed) or split out (Q6). Verifying ends the open resolved states (reason
  "verified by module results (PROC-…)", `ended_by_run_id`) and opens the result state with `created_by_run_id` = the run that completed it.
  Losing verification (a failing correction, a reversal) ends the result state and reopens the resolved states.
- **New functions:** `record_discharge_module_result`, `correct_discharge_module_result` (`action.confirm_capture`); `assign_discharge_channel`,
  `correct_discharge_channel`, `split_failed_modules_to_quarantine` (`action.processing_aftercare`; the split's run through
  `commit_processing_run` as usual); `set_batch_module_count`; internal (EXECUTE revoked): `discharge_result_internal`,
  `discharge_channel_internal`, `discharge_verify_batch`, `create_stock_transfer_internal`, `guard_batch_module_count`.
  `create_stock_transfer` is now a wrapper over the internal one (same signature, same gate). `create_inbound_batch` /
  `receive_inbound_batch_against_po` gain a trailing `p_module_count` (default NULL).
- **Views:** `discharge_module_current_all` and `discharge_batch_status_all` (owner, revoked) with the gated readers `discharge_module_rows`
  and `discharge_status_by_batch`; `operations_now` 57 → **59** arms (`discharge_unverified`, `discharge_quarantine_pending`, both
  `module.processing.view`); `pending_values` 17 → **18** arms (V9, `module.materials.view`).
- **Trail** (Q31): results and assignments on the discharge run, splits on the split run (`processing_run`, home); results and splits on
  `inbound_batch` / `output_batch`; results on `device`. Change log 267 → **270** bound tables, exclusions stay 8, mask rules stay 105.
- **Stale record corrected (Q36):** the `processing_runs.equipment_id` column comment (it said no operation ↔ asset link exists; MES-4a built it).
- The migration's own proof: change-log rows exactly as expected, the 59 / 18 arm counts, 105 mask rules, 44 open read policies, anon executes
  exactly `cod_verification(text)` and `ingest_submit(text,text,jsonb)`, every bound key is its primary key, batches / runs / states unchanged
  by the migration, and every pending document still has a decider other than its submitter.

### §2.2 Fixtures
New **fixture 255** (arms MC · COMMIT · VER · CORR · REV · P1 · P2 · P3 · RES · V9 · CHAN · SPLIT · ING). Fault injections
`db/scripts/2026-10-08-mes5a1-fixture-injections.py`: **44 cases on 255 + 5 on the existing fixtures, 0 wrong** (`INJECTIONS_OWN_EXIT=0`),
each red in the arm it names. Changed (Q34 — no assertion removed): **158 D4**, **165 K7**, **251 RUN**, **253 DISCH** move their state
assertions after module results and each gains the counter-assertion (a commit alone does not verify); 165 K7 also gains the P3 stock
assertion and its material became a module form (`ZZ165-MOD`) so it can carry a module count; **111** lists the two new arms (59).

### §2.3 App
See §3. 33 new refusal sentences (en / zh) in the processing family (`app/operation/errorCodes.ts`), including a discharge-specific sentence for
`QUARANTINE_LOCATION_REQUIRED`; the `discharge` message namespace; pending-values labels for V9; dashboard labels for the two arms;
`lib/reminders.ts` entries; `docs/dashboard-arm-inventory.md` M5a1 · M5a2; trail registry (`lib/trail/render.ts`, `text.ts`, the label
catalogue `docs/surveys/AUDIT-TRAIL-0/labels.csv` → `lib/trail/catalogue.generated.ts`), wording arm ㉑ in `scripts/check-trail-wording.mjs`
(fault `wording-drift-mes5a1` → exit 1, red in ㉑ only, measured); `scripts/check-document-registry.mjs` 275 → 278 tables.

### §2.4 Device transforms built: **none**, and why
MES-3b Q25 and MES-4a Q14 stand: no transform is built on a payload format no real device has supplied. Nobody has supplied a per-module
export from the Bosch discharge cabinet (Step 0 §11 — whether it exports per-module voltage at all is still Tim's open fact). So
`ingest_data_classes.discharge_module` keeps no transform and creates no draft — a device message of that class waits as
`awaiting_transform` and never silently becomes a result (fixture 255 ING pins it). Results are recorded by hand (`source = 'manual'`) through
`record_discharge_module_result`, following the MES-4a precedent for run values; the result rows already carry `source`, `device_id`,
`inbox_id`, `draft_id` and `site_from` / `site_to` / `site_dataset_ref`, so a transform can be added later without changing the table.
Channel → module assignments (Q9) **are** built (they are entered by hand and do not depend on any payload).

## §3 · Pages — every new or changed route, with its file

No new route (Q13).

| Route | File(s) | What changed |
|---|---|---|
| `/operation/processing/[id]` | `app/operation/processing/[id]/page.tsx`, `DischargePanel.tsx`, `dischargeActions.ts`, `dischargeData.ts` | on a `verifies_by_unit` run: per input batch the module count, progress, passed / awaiting re-discharge / awaiting split / split out / contradicting V9 and "discharged and verified"; the run's results (with corrections, "a later result supersedes this", split marks, V9 flags, screen photo); record and correct a result (optional photo into `capture-photos`); channel assignments (assign, correct, withdraw); the quarantine split form per batch with failed-for-quarantine modules; the splits made from this run. On a split run: which modules it split, from which discharge run |
| `/inbound/[id]/edit` | `app/inbound/[id]/edit/page.tsx`, `app/components/batch/ModuleCountPanel.tsx`, `moduleCountActions.ts`, `moduleDischargeQuery.ts` | module count (set / change; locked once verified) and each module's latest result, re-discharge count and run |
| `/output/[id]/edit` | `app/output/[id]/edit/page.tsx` (same panel) | the same, plus "split out to quarantine: modules …, by run …" on a split's new batch |
| `/operation/processing/new` | `app/operation/processing/new/page.tsx`, `NewProcessingForm.tsx` | the split operation is not offered (it starts from the run page); on a module-checked operation each cell input shows its module count, or "not recorded" with a link to the batch page |
| `/inbound/new` | `app/inbound/new/NewInboundForm.tsx`, `actions.ts`, `app/inbound/ModuleCountField.tsx` | optional module count on cell forms |
| `/inbound/receive` | `app/inbound/receive/ReceiveForm.tsx`, `actions.ts` | the same field |
| `/materials/new` | `app/materials/new/NewMaterialForm.tsx`, `actions.ts`, `app/materials/DischargePassVoltageField.tsx` | V9 field |
| `/materials/[id]/edit` | `app/materials/[id]/edit/EditMaterialForm.tsx`, `actions.ts` | V9 field |
| `/settings/pending-values` | messages only | V9 |
| `/tools/reminders`, dashboard | `lib/reminders.ts`, messages | `discharge_unverified`, `discharge_quarantine_pending` |
| every audit trail | `lib/trail/render.ts`, `lib/trail/text.ts`, `lib/trail/catalogue.generated.ts` | the three new tables and the new columns |

## §4 · Verification, in the brief's order

| # | Step | Result |
|---|---|---|
| — | Before the window | Preflight ✓ (18 functions: 4 replaced, 14 new; 5 columns, 1 on a masked table). **Live dry run** of the built file, `COMMIT` replaced by a probe + `ROLLBACK`: `DRY_OWN_EXIT=0` (2 m 09 s), and again after the Q36 comment was added: `DRY2_OWN_EXIT=0` (2 m 33 s). Rehearsal of the live proof on a local rebuild of the mirrors: `REHEARSE_OWN_EXIT=0`. tsc against types spliced from that rebuild: 0 errors |
| 1 | Offline gate | `GATEOFF_EXIT=0` (81 s); re-run after the comment fix: `GATEOFF_EXIT=0` |
| 2 | Backup (background) | `BACKUP_EXIT=0`, `evoltrya-backup-2026-10-08-1209.dump` (7,089,087 bytes; TOC 8,288 entries) |
| 3 | `apply_migration.sh` | `APPLY_OWN_EXIT=0`; applied 12:25:51, **committed 12:28:14 CST = window start** (`db/migration-windows.tsv`) |
| 4 | `types:gen` | `TYPES_OWN_EXIT=0` (after `NOTIFY pgrst`); only this cut's relations and functions added |
| 5 | tsc | `TSC_OWN_EXIT=0` |
| 6 | `npm run build` | `BUILD_OWN_EXIT=0` (64 s; all 39 static checks, then `next build`) |
| 7 | Full gate | `GATE_EXIT=0` (506 s): rebuild ✓ · mirrors vs live ✓ (incl. generated types) · fixtures ✓ (258) · anonymous surface ✓ (subset of the 328-line baseline); change log 278 tables · 270 logged · 8 excluded, zero gaps, on both sides |
| 8 | i18n | `I18N_OWN_EXIT=0` |
| 9 | Error swallowing | `SWALLOW_OWN_EXIT=0` (0 unallowed, 9 allowlisted) |
| 10 | Layout survey, 8 pages | 1280 px: **8 / 8** usable. 390 px: **7 / 8** — `/operation/processing/new` +177 px, the input-batch `<select>`: the same page, culprit and amount MES-4a and MES-4b measured as pre-existing; not fixed here. Every other changed page 0 px overflow, 0 clipped tables at both widths. **Not measured:** the run page's record / channel / split forms render only on a committed module-checked run, and live has none (PROC-2026-0494 is reversed, so its panel is read-only); creating one would leave a document on live |
| 11 | Smoke (background) | `SMOKE_EXIT=0` — **273 ok, 12 skipped (no data), 0 failed** (247 routes timed; `/operation/processing/[id]`, `/inbound/[id]/edit`, `/output/[id]/edit` HTTP 200). **Scratch reading:** at start, the same 6 stale rows earlier cuts reported (`ZZ-SMOKE-*`, 861–1,504 h old, five still referenced) — none from this cut; the run's own throwaway account and grants were cleaned (closing readings: 0 throwaway accounts, roles and grants identical) |
| 12 | Live verification | §5 |

## §5 · Live verification

### §5.1 Rolled-back proof — `db/scripts/2026-10-08-mes5a1-live-proof.sql` (`PROOF_OWN_EXIT=0`, 13:13:53–13:14:06, one transaction, ROLLBACK)

Every step in a real account's session; only my own `ZZ-PROBE-MES5A1-*` supplier, materials, batches and quarantine location.

| Step | As | Result |
|---|---|---|
| Receive with a module count; commit a deep discharge | fusheng@ | IN-2026-0491 received with 2 modules; PROC-2026-0725 committed → state still `charged_not_discharged`, stock 200, `discharge_unverified` lists it |
| Every module passes | fusheng@ | M01 0.4 V, M02 0.5 V pass → `discharged_verified`, owned by PROC-2026-0725; reminder cleared; changing the count → `MODULE_COUNT_LOCKED` |
| One fail for quarantine; split | fusheng@ | IN-2026-0492 (3 modules): 2 pass, M03 fail · quarantine → not verified, `discharge_quarantine_pending` lists it; split with no quarantine location → `QUARANTINE_LOCATION_REQUIRED\|charged_not_discharged\|unspecified`; fusheng@ marked `ZZ-PROBE-MES5A1-Q` and split M03 by PROC-2026-0727 → **OUT-2026-0681** (same material, 90 kg, 1 module, `charged_not_discharged`, all 90 kg in the quarantine location); parent now `discharged_verified` (2 passed + 1 split = 3), owned by the split run |
| Re-discharge | fusheng@ | IN-2026-0493 M01 failed 6.2 V (re-discharge) on PROC-2026-0728, passed 0.3 V on PROC-2026-0729 → latest wins, re-discharges 1, verified |
| Partial discharge (P1) | fusheng@ | IN-2026-0494: 10 kg of 100, 1 of 2 modules passed → still `charged_not_discharged` |
| Reverse after a downstream run (P2) | fusheng@ → tim@ | IN-2026-0495: discharge PROC-2026-0731 passed, then 50 kg disassembled by PROC-2026-0732; fusheng@ submitted the rollback request, tim@ (cfo) approved (approvals ON, the APR-7 path) → reversed; stock stays 50; no `reversal_restore`; back to `charged_not_discharged` |
| Self-produced batch (P3) | fusheng@ | `ZZ-PROBE-MES5A1-OB` (output, 100 kg): count set on the batch path, discharged by PROC-2026-0733 → stock still 100, no `processing_consume`, verified |
| Untouched | — | PROC-2026-0494 and the two pre-existing open states identical inside the transaction |
| After ROLLBACK | — | probe materials / suppliers / locations 0 / 0 / 0; results / channels / splits 0 / 0 / 0; module counts / V9 / quarantine locations 0 / 0 / 0; pending documents 1 (CLM-2026-0004, not mine) |

**Burned codes** (sequences do not roll back): IN-2026-0491–0495, PROC-2026-0725–0733, OUT-2026-0681, CEL-2026-00002 (the disassembly's
loose-cell output). Live's next codes skip them.

### §5.2 Read-only
§1 (role table).

### §5.3 Before and after (13:14 CST)
- **Fingerprints excluding this cut's new columns — identical:** inbound batches (24), output batches (20), materials (9), the 7 pre-existing
  operations, their 11 accepted states, 16 input and 21 output forms, the 6 pre-existing relation exceptions, processing runs (14), inputs (14),
  outputs (17), inbound / output safety states (1 / 1), inventory movements (107), storage locations (4), devices (4).
- **PROC-2026-0494 and the two open states:** byte-identical rows.
- **Set on live — exactly the seeded rows:** `verifies_by_unit` on `deep_discharge`; the operation `discharge_quarantine_split` (2 accepted
  states, 4 + 4 forms) with `started_from_run_page`; 2 relation exceptions. **Nothing else:** batches with a module count 0 · materials with V9 0 ·
  quarantine locations 0 · results / channel assignments / splits 0 / 0 / 0 · `require_calibrated_since` NULL.
- **Per-table digests (all public tables):** changed only where the migration changed the table — `inbound_batches`, `output_batches`,
  `materials`, `operation_types` (new column; rows identical by the fingerprints above), the three operation link tables and
  `document_relation_exceptions` (the seeded rows) — plus three new empty tables. One other table moved, not by me: `cod_verification_failures`
  (1 row, digest changed) — the smoke test's `/verify/cod/[token]` probe deletes a failure older than 10 minutes and writes one (MES-4a and
  MES-4b reported the same).
- **Accounts:** 7, 0 disabled, 0 throwaway, roles unchanged; 0 grants without an account.
- **Pending documents:** 1 (CLM-2026-0004) — none of mine.
- **Reconciliation (tim@):** AP 422,188.32 / 381,604.42 / **0.00** · AR 57,545.87 / 43,002.12 / **0.00** — identical to the opening.
- **Change log:** 13,757 → 14,277 rows (max seq 15,537 → 16,238). By table: the migration's own rows (operation_types 1 INSERT + 2 UPDATE,
  safety states 2, input forms 4, output forms 4, relation exceptions 2 — 15, as its proof required); the rest are INSERT/DELETE pairs from the
  smoke and survey throwaway sessions (role_permissions 225 + 225, employees, roles, user_roles, contracts and their term tables,
  performance_reviews) — every pair nets to zero, as the per-table digests show.
- **Sequences:** output 680 → 681 · inbound 490 → 495 (the proof's burned numbers, §5.1).

### §5.4 Broken window
**Start: 2026-10-08 12:28:14 CST** (measured: `db/migration-windows.tsv`). **End: the deploy** — Tim confirms it on Vercel; this machine
does not query it (AGENTS.md).
In the window the old app runs on the new database (**derived**, not measured on live): every old write call still works (`create_inbound_batch` /
`receive_inbound_batch_against_po` take the new trailing parameter with a default; `create_stock_transfer` keeps its signature);
a deep discharge committed from the old app would **not** mark its batch verified (the new rule) and the old app has no panel to record module
results, so such a batch would wait for the deploy — live has no committed discharge; the old dashboard has no sentence for the two new arms
(it would print the key if a row existed; live has none). Reads are unchanged (new columns are additive).

## §6 · Decisions taken without asking

1. **No device transform** (§2.4); manual results go straight to `discharge_module_results` with `source = 'manual'` (the MES-4a precedent),
   not through `submit_manual_capture`, whose path requires a transform for its class.
2. **A third table, `discharge_module_splits`** — Q11's split needs to record which modules left which batch for which new batch; nothing
   else could carry it.
3. **The split also needs `action.processing_commit`** (the code of every run's commit), besides `action.processing_aftercare` (Q10). Live holders
   of the two are identical (admin, warehouse), so no one loses the action.
4. **`operation_types.started_from_run_page`** marks the split operation: the new-run form does not offer it (it needs to know which modules);
   `commit_processing_run` does not refuse it, so the run engine stays one path.
5. **`create_stock_transfer` split into a wrapper and `create_stock_transfer_internal`**, so the split can move its new batch into quarantine
   under the split's own code; the public function keeps its signature and gate.
6. **Losing verification is undone on the safe side:** a correction from pass to fail, or a reversal, ends the result state and reopens the
   states it had resolved.
7. **Verification acts only on batches that have module results** — a batch verified before this cut keeps its state (Q16, no back-fill).
8. **The split's new batch copies the parent's open states** (it is the same modules; the parent is unverified, so it holds
   `charged_not_discharged`), owned by the split run so reversing the split ends them.
9. **The split operation accepts `discharged_verified` as well** (neither resolved), keeping fixture 178's invariant that every operation
   accepts a feedable state.
10. **Two relation exceptions** for `discharge_module_splits` (a module split is not a document relation between the two batches; fixture 103).
11. **The gated status reader is named `discharge_status_by_batch`**, not `discharge_batch_status`, because of the replay-order limitation now
    recorded in `docs/known-issues.md` (`MES5A1-VIEW-REPLAY-ORDER-NOT-TOPOLOGICAL`).
12. **A correction keeps the module reference**; to record a different module, record a new result.
13. **"Latest" = latest verdict time, then latest row id** (a re-discharge recorded late for an earlier verdict time does not win).
14. **The V9 arm lists a material only once a discharge result exists on a batch of it** — listing every cell material before any discharge would
    fill the page with rows nobody can act on yet.
15. **The module-count guard is a SECURITY DEFINER trigger with EXECUTE revoked** — so a direct UPDATE by someone without processing view still
    meets the "below results" and "locked" rules (fixture 255 MC proves the direct path).
16. **Fixture 253 DISCH gained a counter-assertion too** (the brief named 158, 165, 251 and 253 — 253 is included).
17. **Fixture 165 K7's material became a module form** so it can carry a module count.
18. **Screen photo** (Q7, optional): uploaded into the existing `capture-photos` bucket under `discharge/<run>/…` with the result (upload under
    `action.confirm_capture`); opening it follows the bucket's read rule (receipt or logistics view) — not changed by this cut.
19. **The device picker lists active discharge cabinets** (live: none); empty means "not recorded".
20. **The module count shows on a batch page only for cell-carrying forms** — the same criterion as cell construction and the guard.
21. **A typed value that is not a number is refused before sending, with the database's own code** (JSON turns NaN into null, which would
    silently clear an optional value or the count).
22. **The split form's process date defaults to the discharge run's date**, and the button stays disabled while it is empty (a date that decides
    the period).
23. **A reader without inventory view sees "Locations need inventory view rights"** in the split form, not "no quarantine location".
24. **The live proof reversed through the real path** — rollback request by fusheng@, approved by tim@ (approvals stay ON).
25. **Q36 in this cut:** the `processing_runs.equipment_id` comment (migration + mirror), the `docs/forward-queue.md` row on the
    operation ↔ asset link, and `docs/change-log.md` §12.1 / §13.1 (annotated: seven exclusions then, eight since MES-3b). The month-end
    comment (`app/finance/month-end/allocationActions.ts`) is in a file this cut does not touch, so it is left for the cut that does.

## §7 · Assertions measured and found false or imprecise
- **My first draft of the P2 entry in `docs/known-issues.md`** described the failure as a stock-ceiling refusal plus a phantom restore movement;
  Step 0 §1 measured `IOD_RESTORE_MISMATCH|10|0` (a loud refusal) and nothing about a phantom movement. Corrected to the measurement before commit.
- **My first rehearsal of the live proof** assumed a rollback request always waits for a decision; with approvals off (the local rebuild) it
  executes at once. The script now handles both; on live (approvals ON) it went submit → decide.
- **The brief's verification order puts the layout survey after the build**, while the survey refuses to run with a built `.next`
  (AGENTS.md's order is survey → build). Followed the brief: `.next` was removed before the survey; the build is not part of the commit.

## §8 · Docs updated
`docs/forward-queue.md` (item 42; MES table 7a ✅ / 7b next; the MES-5a-2 Energy section with Q19–Q28, Q35, V25 and Q22 / Q24 awaiting Tim;
the stale operation ↔ asset row) · `docs/mes-pending-values.md` (V9 row and "What V9 holds back") · `docs/known-issues.md` (P1, P2, P3 found
and fixed; the replay-order limitation) · `docs/role-matrix.md` (MES-5a-1 row) · `docs/change-log.md` §18 (and the §12.1 / §13.1 annotations) ·
`docs/dashboard-arm-inventory.md` (M5a1, M5a2).
