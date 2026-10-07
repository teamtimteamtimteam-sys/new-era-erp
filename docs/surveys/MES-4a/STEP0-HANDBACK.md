# MES-4a Step 0 — hand-back (2026-10-07)

**Contents:** the MES-3b close-out, item by item §0 · what grilling changed §1 · the design (a)–(l) §2–§13 · the time estimate (m) §14 ·
every open question §15 · assertions found false or imprecise §16 · stop §17.

**STOP GATE.** No code edit, no migration, no live write. The only writes are docs: the close-out (`49ca62e2`, `docs/forward-queue.md`
item 39), this file and `docs/surveys/MES-4a/live-readings.sql`. Waiting on Tim's answers to Q1–Q36 (§15).

**Opening check.** First command **2026-10-07 14:42:53 CST**. Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
**`437359d23c3efcf1d48d385f51b26a0673e0e501`** (MES-3b, v1.4.40). Files staged by explicit path only.

**Live readings: NOT TAKEN.** The read-only psql session to live (`BEGIN READ ONLY … ROLLBACK`, `default_transaction_read_only = on`) was
**refused by this session's permission check** ("Production Reads"). I did not try another route. Every live figure below is therefore quoted
from an earlier hand-back with its date and tagged **[Q]**, never [M]. The readings this Step 0 wanted are written out, ready to run, in
`docs/surveys/MES-4a/live-readings.sql` (read-only; the header gives the command) — the build cut runs it as its opening reading, or Tim runs it
with `! PGOPTIONS=… psql … -f docs/surveys/MES-4a/live-readings.sql`.

**How the facts were gathered.** Three read-only sub-agents (today's processing record; machines, shifts, weighings, ingestion, registries,
trail and permissions; cut-duration calibration from the session transcript `~/.claude/projects/-Users-timchen/648f0b61-….jsonl`, the
`refs/remotes/origin/main` reflog and `~/mes3b-work/logs/` mtimes). None connected to a database or ran a build. I read the specification PDF,
MES-0, the MES-3b Step 0 and hand-back, `docs/mes-pending-values.md` and the operation-model records (`docs/operation-model-scoping.md`
PROC-MODEL-0, `docs/proc-loss-and-saleability.md` PROC-BUILD-1, `docs/proc-batch-purpose-and-state-dictionary.md` PROC-WIRE-1A,
`docs/proc-operations-wired.md` PROC-WIRE-1B-i, `docs/proc-cost-capitalisation.md` PROC-COST-1) in full, and re-read every load-bearing
claim at its file:line before using it (the commit function's mass check and loss default, the NOT VALID operation check, the loss panel's
upsert and delete, the loss table's cascade, rollback not touching losses, `processing_runs_blocking_close`, the weighing subject CHECK,
`capture_confirm_internal`'s class refusal, `equipment_usage`'s missing category filter, the form's output validation, the absence of any
writer of `shifts`). Tags: **[M]** measured (file:line read or an exact grep) · **[I]** inferred from code reading, not executed · **[Q]**
quoted from an earlier hand-back.

---

## §0 · Step 1 — the MES-3b close-out

### §0.1 · Broken window — closed (`docs/forward-queue.md` item 39, commit `49ca62e2`)

| | time (CST) | source |
|---|---|---|
| start | **2026-10-07 11:56:14** | measured — `db/migration-windows.tsv:222` (`2026-10-07-mes3b-labels-scanning.sql`) |
| end, lower bound | **2026-10-07 13:36:35** | measured — `git reflog show --date=iso refs/remotes/origin/main`: `437359d2 … {2026-10-07 13:36:35 +0800}: update by push` |
| end, upper bound | **2026-10-07 14:42:53** | this session's first command (`date`), holding Tim's "deployed" — **a report, not a Vercel reading** |
| **window** | **1 h 40 min 21 s – 2 h 46 min 39 s** | |

What was broken in it (derived, MES-3b hand-back §5.4, not measured on live): nothing. Of the window, **41 min 03 s** was a pause Tim asked for
while the window was open (11:56:31 → 12:37:34, measured from the transcript by the calibration agent). The Android camera check on
`/inventory/scan` is recorded in the same item as Tim's own action after deploy.

### §0.2 · Items a–h, read-only — **all present, none partly done**

**a. Label templates; print page; reprint reason — PRESENT** [M].
- `db/tables/label_templates.sql:23-25` `object_kind … CHECK (object_kind IN ('inbound_batch', 'output_batch', 'storage_location'))` ·
  `page_size … CHECK (page_size IN ('A6', 'A5'))` · `show_dg boolean NOT NULL DEFAULT true`; seed `:31-37` six rows (`inbound_a6` … `location_a5`,
  the location ones `show_dg = false`).
- Edited under `module.inventory.edit`: `:51-52` `USING (has_permission('module.inventory.edit')) WITH CHECK (…)`, `:59`
  `enforce_write_permission('module.inventory.edit')`; registered in the dictionary editor with the new `choice` kind
  (`app/settings/dictionaries/registry.ts:42` `kind: 'boolean' | 'text' | 'number' | 'choice'`, `:217`, `:224`).
- Print page: `app/components/labels/LabelPrinter.tsx:48` preview (`buildLabelDocument({ … pageSize: template.page_size, showDg: template.show_dg …})`)
  · `:81` template `<select … data-label-template>` · `:86-87` copies (`type="number" min="1"`) · `:93-95` reason textarea · `:53` reason required
  on a reprint · `:59` `printLabel(…)` then `:66` `f.contentWindow?.print()`.
- `db/functions/record_label_print.sql:41-43` `v_reprint := v_n > 0; IF v_reprint AND NULLIF(btrim(p_reason), '') IS NULL THEN RAISE EXCEPTION
  'LABEL_REPRINT_REASON_REQUIRED|%'`; messages `messages/en.ts:7478`, `zh.ts:7269`. Fixture 252 PRINT (`:185`, `:206`); live proof MES-3b §5.1 step 2b [Q].

**b. DG dictionary, DG data on documents, "not set" warning — PRESENT** [M].
- `db/tables/dangerous_goods_codes.sql:34-39` seeds `UN3480` 'LITHIUM ION BATTERIES (including lithium ion polymer batteries)', `UN3481`
  '…CONTAINED IN EQUIPMENT or … PACKED WITH EQUIPMENT…', `UN3090` 'LITHIUM METAL BATTERIES (including lithium alloy batteries)', `UN3091`, each
  `dg_class '9'`.
- Shipment document lines: `db/functions/shipment_document.sql:60` `'dg_code', m.dg_code` · `:64` `'dg_missing', COALESCE(mk.has_condition_axes,
  false) AND m.dg_code IS NULL`.
- Delivery note: `app/sales/shipments/[id]/pdf/DeliveryNoteDocument.tsx:100-101` `{l.dg && …}` / `{!l.dg && l.dg_missing && <Text …>DG: not set</Text>}`.
- Shipping queue: `db/functions/shipping_queue_rows.sql:25` trailing `dg_code text, dg_missing boolean, quarantine_states text`; page
  `app/logistics/shipping/page.tsx:114` `{l.head.dg_missing && <span … data-queue-dg-missing>{t('logistics.shipping.dgMissing')}</span>}`.
- Warning text: `messages/en.ts:385`/`:4217` 'DG code not set'; label `:7487`. Fixture 252 DG (`:348`, `:427`).

**c. Quarantine flag, no refusal — PRESENT** [M].
- Queue `app/logistics/shipping/page.tsx:140-142` `{r.quarantine_states && (<p className="mb-1 text-amber-700" data-queue-quarantine=…>`;
  delivery note `DeliveryNoteDocument.tsx:103` `Open safety state: {l.quarantine}`; shipment page `ShipmentLinesTable.tsx:86`.
- No refusal: `grep -c "quarant\|safety" db/functions/ship_order.sql db/functions/reserve_stock_internal.sql` → 0 / 0.
  Fixture 252 `:413` `RAISE EXCEPTION 'FIXTURE 252 SHIP: shipping without a scan (and a flagged batch) was refused'` (the arm asserts it ships).

**d. HS code check — PRESENT** [M].
- `db/tables/materials.sql:74-75` `hs_code text CONSTRAINT materials_hs_code_shape CHECK (hs_code ~ '^[0-9]+(\.[0-9]+)*$' AND
  length(replace(hs_code, '.', '')) BETWEEN 6 AND 12)`.
- Shows on: material editor `app/materials/DgHsFields.tsx:31-32` · list `app/materials/page.tsx:84,164` · export `app/materials/export/route.ts:15,98` ·
  shipment page `app/sales/shipments/[id]/page.tsx:119` · delivery note `DeliveryNoteDocument.tsx:102` `HS {l.hs}` · `shipment_document.sql:65`.
  Fixture 252 HS (5 digits, 13 digits, letters, trailing dot refused). Live proof step 1 refused `85493` [Q].

**e. Scanning — PRESENT** [M].
- `app/components/scan/ScanField.tsx:23-24` `typeof w.BarcodeDetector === 'function' ? w.BarcodeDetector : null`; `:47-48` `canCamera = …
  detectorCtor() !== null && !!navigator.mediaDevices?.getUserMedia`; `:146` `{canCamera && (` — the camera button exists only there.
- `/inventory/scan` transfer: `app/inventory/scan/ScanTransfer.tsx:82` (scan batch), `:103` (scan source), `:112` (scan destination), `:7`
  "走的仍是 create_stock_transfer".
- Feed: `app/operation/processing/new/NewProcessingForm.tsx:447` `<ScanField context="feed" accept={['inbound_batch', 'output_batch']} compact`.
- Ship: `app/logistics/shipping/ShipQueueControl.tsx:80` `<ScanField context="ship" …>`; `actions.ts:29` sends `scanned_code` only when one was
  scanned; `db/functions/ship_order.sql:110-114` `v_scanned := NULLIF(btrim(…)); IF v_scanned IS NOT NULL THEN … RAISE EXCEPTION
  'SHIP_SCAN_MISMATCH|%|%'` — no scan, no check. Fixture 252 SHIP (`:23` "不带 → 照发", `:413`).

**f. `scan_events` append-only, excluded from the change log — PRESENT** [M].
- `db/tables/scan_events.sql:35-37` `CREATE TRIGGER trg_scan_events_append_only … FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();`
  Fixture 252 LOG `:302` `'APPEND_ONLY|scan_events|update'` asserted.
- `db/functions/change_log_exclusions.sql:27` `('scan_events', 'Scan log (MES-3b): itself an append-only record …')`;
  `docs/change-log.md:1079` "**Excluded: `scan_events`** (MES-3b Step 0 Q20) …".

**g. `nea_waste_categories` in both lists, with the injected fault — PRESENT** [M].
- `db/check_mirrors.py:307` (`RUNTIME_CONFIG_TABLES`, with `:310` `dangerous_goods_codes`, `:312` `label_templates`) and `:321-325`
  `BOOTSTRAP_MAY_BE_EMPTY: set = { … "nea_waste_categories", }`; used at `:1122`.
- Fault proof `~/mes3b-work/logs/gate-off-q3inject.log:17` `bootstrap  ✗ 引导后为空:['nea_waste_categories']` · `:297` `GATEOFF_EXIT=1`
  (hand-back §4 row "Q3 fault").

**h. V30, V31, V35; decision 21 — PRESENT** [M].
- `db/views/pending_values.sql:146` `'V30'` · `:155` `'V31'` · `:165` `'V35'`; labels `messages/en.ts:10318-10320`; the page reads the view
  (`app/settings/pending-values/page.tsx:29`). `docs/mes-pending-values.md:30-32` (rows) and `:71-83` (what each holds back).
- `docs/handbacks/MES-3a.md:240-246` decision **21** ("The ceilings section … admits `module.suppliers.view` OR `module.inventory.view` …
  accepted as built by Tim (MES-3b Step 0 Q0, 2026-10-07)").

### §0.3 · (i) The five Step 0 assertions MES-3b reported as false (`docs/handbacks/MES-3b.md` §7)

1. **"MES-3a's change-log binding for `nea_waste_categories` is keyed correctly."** It was keyed on `'id'`, but that table has no `id` — its key
   is `code`. MES-3b re-keyed it and now asserts every binding's key equals its primary key.
2. **"`shipping_queue_rows` gains two trailing columns."** It gained three: `dg_code`, `dg_missing` and `quarantine_states`
   (`shipping_queue_rows.sql:25`).
3. **"One function `label_data_preview`."** It was built as `label_print_preview` (the read) plus two internal helpers,
   `label_print_context` and `label_object_data` (`ls db/functions | grep label_`).
4. **"The dictionary editor's existing text kinds can carry the templates."** They could not; object kind, paper size and DG class are fixed
   lists, so a `choice` kind was added (`registry.ts:42`).
5. **"The 390 px overflow on `/operation/processing/new` comes from this cut."** It does not: the HEAD version of the form, before MES-3b,
   measured the same +177 px (`~/mes3b-work/logs/survey390-before-processing.log:8` `ovf=177`).

### §0.4 · (j) Decisions MES-3b took without asking (`docs/handbacks/MES-3b.md` §6), titles only

1. Six seeded templates, not three. · 2. `label_prints` is a trail member of all three subjects, home on the inbound batch. · 3. The stored QR
path is unencoded and relative. · 4. Print = record, then print through an off-screen iframe. · 5. The labels line does not name who printed.
· 6. `scan_events.method` has a third value, `link`. · 7. A signed-out short-link visit is not logged. · 8. A deleted batch resolves as
`unknown`. · 9. Batch codes match case-insensitively; location codes exactly first. · 10. `/b/` resolves batches only, `/loc/` locations only.
· 11. Preview and print carry an outer "any of three view codes" check. · 12. No upper bound on copies. · 13. DG English names are the UN
proper shipping names; Chinese names are translations. · 14. HS codes 6–12 digits, dots between groups. · 15. The delivery note prints DG /
HS / quarantine as English sub-lines. · 16. The shipping queue gained three columns. · 17. The `nea_waste_categories` binding re-keyed `'id'` →
`'code'`. · 18. `label_prints`' one-object constraint written `num_nonnulls(...) = 1`. · 19. A `choice` field kind in the dictionary editor.
· 20. `P_DICTIONARIES` widened by `module.inventory.view`. · 21. The label code at 8.5 units. · 22. Print pages take `?template=`. · 23. A
weighbridge ticket matched by its typed or scanned `WB-` code on the client. · 24. The receipt scan also on `/output/new`. · 25.
`scanned_code` trimmed and compared case-insensitively. · 26. A "UN / HS" list column and two export columns. · 27. The two label route
handlers replaced by pages. · 28. Smoke and the layout survey skip `/b/[code]` and `/loc/[code]`. · 29. A location's flags come back only
when found. · 30. Wording written by the session.

**Verdict: a–h all present, none partly done** — so step 2 ran.

---

## §1 · What grilling changed in MES-4a's scope

1. **Making times, shift and weighings required costs most in the fixtures, not in the function.** 46 fixtures call `commit_processing_run`
   on **133** non-comment lines (`grep -h "commit_processing_run(" db/fixtures/*.sql | grep -v "^\s*--" | wc -l`), and the harness forbids a
   shared helper by design (`db/fixtures/_harness.md:1-2`). Every transforming call needs start, end, shift and a weighing per output. A
   weighing today needs an inbox row and a draft (`weighings.inbox_id … NOT NULL UNIQUE`, `draft_id … NOT NULL UNIQUE`,
   `db/tables/weighings.sql:20-44`). Recording a manual weighing **inside** the commit (spec §3.2 rule 1, "weighing and recording occur within
   the same action") keeps that churn to new parameters, not new set-up blocks. **Q24.**
2. **"Required" belongs at closure, not at commit.** Device indicators arrive at batch close through the gateway (spec §6.2) — after the
   operator has recorded the run. If required parameters were enforced at commit, a device-fed value could never complete a run. **Q11.**
3. **Losses are written after commit, by upsert and hard delete, from the page** — not through any function
   (`app/operation/processing/[id]/lossActions.ts:46` `.upsert(…)`, `:57` `.delete()`; `LossPanel.tsx:91-95` "行【真的没了】"). Q49's
   append-only losses is a reshaping of `processing_run_losses` (its key is `(run_id, loss_category_code)`, `processing_run_losses.sql:10-18`)
   plus two functions. **Q28.**
4. **A supplied `loss_qty` is never compared with input − output** (`commit_processing_run.sql:299-300` `COALESCE(p_loss_qty, v_total_input -
   v_total_output)`; only `LOSS_NEGATIVE` checks it). A typed loss that differs from the missing mass is exactly the "difference figure"
   the spec (§4.1) says has no audit value. **Q17.**
5. **The deep-discharge run cannot be recorded from the page** [I, code read, not executed]: the form hides the output section for an
   operation that produces no outputs (`NewProcessingForm.tsx:117,542`), yet still refuses to submit with no valid output (`:247-250`
   `if (validOutputs.length === 0) { setError(t('processing.validation.needValidOutput')); return }`). Only fixtures 158–160 commit one. MES-4a
   rewrites this form anyway. **Q4.**
6. **No screen can set shift times.** `grep -rln "'shifts'\|UPDATE shifts\|INTO shifts" db/functions app lib` hits only the three handover
   pages, which read; `shifts` is not in the dictionary registry. Yet V6 sends people to `/operation/handovers`
   (`db/views/pending_values.sql:56`) and `docs/mes-pending-values.md:22` calls it "the shift dictionary". V7 (shift times, MES-0 §5) is the
   same two columns. **Q5, Q35.**
7. **The machine picker offers every asset card**, vehicles and office assets included: `equipment_usage` has no category filter
   (`db/views/equipment_usage.sql:42-45`), while `fixed_assets.category` is `equipment | vehicle | office | other`
   (`fixed_assets.sql:15-16`). The operation ↔ machine link (Q41) fixes it by construction. **Q9.**
8. **The ingestion layer can only confirm weighings**: `capture_confirm_internal.sql:55-56` `IF d.data_class <> 'weighing' THEN RAISE
   EXCEPTION 'CAPTURE_CLASS_HAS_NO_RECORD|%'`. `controller_summary` and `workstation_event` have no transform
   (`ingest_data_classes.sql:41-50`). No controller point list exists (D3), so a payload would be invented — the MES-3b Q25 precedent. **Q14.**
9. **The brief's Q43 line and MES-0 disagree on what lives in MES-4a.** MES-0 Q43 names the function-13 *counts* (hard-case, pouch, manual
   adjudication, misclassification, damaged cells, scrap by cause, cut counts) as indicators; MES-0 §1.3 row 13 and §8.2 put contamination
   checks, the measured/derived loss basis and the collected-dust form in **MES-4b**. The brief's paraphrase of Q43 lists cross-contamination,
   electrolyte and dust among the MES-4a fields. **Q2.**
10. **Live counts were not re-measured** (live read refused; see the header). **§12, §16.**

---

## §2 · (a) Exactly what MES-4a contains, against the MES-0 cut plan

MES-0 §8.2 row 5 [M, `docs/surveys/MES-0/README.md:699`]: "`operation_type_fields` …, `processing_run_values`, `process_recipes`,
`processing_run_events`, `processing_run_corrections`, `operation_type_equipment`; run start/end/shift/operator; machine required where linked;
tolerance per operation; closure step; losses append-only; UPDATE-policy debt closed; new operation types per Q37; controller and workstation
transforms — 7 / 4".

**New tables (9):**

| table | purpose | write |
|---|---|---|
| `operation_type_fields` | per operation: field code, names, kind (`parameter` · `indicator`), value type, unit, required, range (min/max, NULL = Not yet set when `has_range`), active, order (Q10) | `module.processing.edit` |
| `operation_type_equipment` | operation ↔ machine (`fixed_assets`, category `equipment`) (Q9) | `module.processing.edit` |
| `process_recipes` | named recipe per operation (Q16) | `module.processing.edit` |
| `process_recipe_versions` | immutable version + its parameter values (append-only) | `module.processing.edit` |
| `processing_run_values` | one row per value recorded on a run; append-only, `corrects_id` + reason; `source` manual / device / recipe; site pointer (Q11–Q14, Q29) | commit; afterwards `action.processing_aftercare` |
| `processing_run_events` | exceptions: time, type, duration, action taken, responsible person; append-only, `corrects_id` (Q15) | same |
| `processing_event_types` | fixed list of event types (RUNTIME CONFIG) (Q15) | `module.processing.edit` |
| `processing_run_closures` | balance closure rows, append-only: snapshot of input / outputs / named losses / remainder / tolerance, explanation, who, when, superseded (Q19) | `action.processing_aftercare` |
| `processing_run_corrections` | header-field corrections: field, old, new, reason, who, when (Q30) | aftercare / `module.processing.edit` per field |

**Changed tables:** `processing_runs` + `started_at`, `ended_at`, `shift_code`, `recipe_version_id`, `corrects_run_id` (masked table: column +
column grant + `processing_runs_masked`, one migration — AGENTS.md "Adding a column to a masked table") · `processing_outputs` + `weighing_id`
(also a column-list grant table with `processing_outputs_masked`, `processing_outputs.sql:49-51`) · `processing_run_losses` reshaped
append-only (Q28) · `operation_types` + `balance_tolerance_pct` (V1) · `operation_types` +2 rows `casing_removal`, `electrode_separation`
with their form and safety-state rows (Q3) · `shifts` editable (Q5).

**Functions:** `commit_processing_run` (new trailing parameters, Q7–Q9, Q11, Q16, Q24, Q31) · `record_run_value` / `correct_run_value` ·
`record_run_event` / `correct_run_event` · `record_run_loss` / `correct_run_loss` (replacing the page's direct writes) · `close_run_balance` and
a read-only `run_balance(run)` (the equation the page and the closure share — "a screen that previews a posting asks the database") ·
`correct_run_header` · `correct_weighing` (refuse when linked, Q26) · `pending_values` +1 arm (V1) and V6 relabelled · `operations_now` +1 arm ·
month-end reader · trail registry rows.

**Pages:** **new** `/operation/operation-types` (list) and `/operation/operation-types/[code]` (fields, machines, tolerance, recipes and
versions) — the dictionary registry cannot hold per-operation child lists (`registry.ts:26-29`, keyed on `code` alone) · **changed**
`/operation/processing/new` (times, shift, machine filtered by operation, recipe, values, a weighing per output, the deep-discharge fix) ·
`/operation/processing/[id]` (header shows operation, machine, times, shift, recipe; values; events; loss panel rewritten append-only; balance
panel and closure; header corrections) · `/operation/processing` (list: a balance column) · `/settings/dictionaries` (shifts with a `time`
kind, Q5) · `/finance/month-end` (warning arm) · `/tools/reminders` (the new arm renders) · `/settings/pending-values` (V1).

**Left to later cuts:**
- **MES-4b:** `cell_constructions` and construction on both batch tables; `contamination_checks` (Q52) and the per-shift reminder; loss
  `basis` measured/derived and the electrolyte share V10 (Q51); the new forms (`cathode_powder` … `collected_dust`, Q55) and loss categories
  (`sampling_consumption`, `equipment_holdup`, `sweepings`, Q56 — **see Q2**); per-product prefixes and `CODE-WIDTH-4`.
- **MES-5a:** per-module discharge results; meters and electricity allocation.
- **MES-5b:** per-inbound-batch and monthly balance views, yield, blending plans.
- **Not built here:** `transform_controller_summary_v1` / `transform_workstation_event_v1` (Q14); weighings on inputs (Q27).

> **Q56 note.** The brief lists Q56 (sampling consumption, equipment hold-up, sweepings) among the rulings that stand; MES-0 §8.2 places the
> new loss categories in MES-4b ("new forms and loss categories (data)"). They are three dictionary rows. Because MES-4a builds the closure that
> names losses, adding them here costs one INSERT and lets the first closures use them — **Q2 asks whether to move them in.**

---

## §3 · (b) Today's processing record

**How a run is recorded and committed** [M]. One SECURITY DEFINER function, `commit_processing_run(p_process_date, p_notes, p_loss_qty,
p_inputs, p_outputs, p_allocation_basis, p_work_order_id, p_equipment_id, p_operation_type_code)` (`commit_processing_run.sql:1-5`, 465 lines),
called once by `app/operation/processing/new/actions.ts:56`. In order: `require_permission('action.processing_commit')` (`:40`) → required date,
basis, operation (`:41-72`) → operation kind (`:81-89`) → optional work order (`:99-111`) → optional machine (`:140-158`) → shape checks
`NO_INPUTS` / `NO_OUTPUTS` / `LOSS_NEGATIVE` (`:170-193`) → inputs locked and checked against available stock (`:197-251`) → outputs
(`:255-264`) → **`OUTPUT_EXCEEDS_INPUT` (`:269-272`)** → state-changing: output := input, any loss refused `STATE_CHANGE_LOSS_NOT_ZERO`
(`:284-290`) → header INSERT with `loss_qty = COALESCE(p_loss_qty, input − output)` (`:299-300`) → drain stock and write input legs; end and
write safety states (`:310-422`) → create output batches and output legs (`:428-447`) → `refresh_cod_for_batch` (`:456-461`). One function, one
transaction [I]: any raise rolls everything back.

**Where inputs, outputs and losses live** [M]. `processing_inputs` (one parent of two, `quantity_consumed`, `processing_inputs.sql:11-21`) ·
`processing_outputs` (`output_batch_id`, `quantity_produced`, cost columns; **no weighing reference**, `processing_outputs.sql:11-20`) ·
`processing_runs.loss_qty` (one number) · `processing_run_losses` (categorised rows written **later** from the run page; PK
`(run_id, loss_category_code)`, `quantity > 0`, `ON DELETE CASCADE`, `processing_run_losses.sql:10-18`) · `processing_run_loss_breakdown`
(`unexplained_qty = loss_qty − categorised`, `db/views/processing_run_loss_breakdown.sql:15-18`; read by no page — `LossPanel.tsx:50` computes its own).
Loss categories (`loss_categories.sql:53-65`): `moisture` · `dust_spill` · `residue_disposal` (not a true loss) · `electrolyte_evaporation`.
The categorised sum may not exceed `loss_qty` (`LOSS_CATEGORIES_EXCEED_LOSS_QTY`, `guard_processing_run_losses.sql:17-23`; skipped when NULL).

**Rulings that conflict with how it works today:**

| ruling | today | conflict |
|---|---|---|
| spec §4.1 / Q46–Q47 balance closure | only `OUTPUT_EXCEEDS_INPUT`; a supplied `loss_qty` is believed (`:299-300`) | no closure exists; a typed loss can hide unexplained mass (Q17, Q19) |
| spec §4.2 / Q49 append-only | losses upserted and hard-deleted from the page (`lossActions.ts:46,57`); UPDATE policies on runs, inputs, outputs, losses (`processing_runs.sql:162-165`, `processing_inputs.sql:279-282`, `processing_outputs.sql:41-44`, `processing_run_losses.sql:53-62`) — `ROLE1B3B-PROCESSING-UPDATE-POLICIES` (`docs/known-issues.md:186-193`) | Q28, Q32 |
| Q49 corrections | no correction column anywhere on the processing tables; quantity correction = whole-run rollback (`warehouse_requests` kind `rollback`, CFO level 2 — `docs/approvals.md:1701,1747`) | correction rows and `corrects_run_id` are new (Q29–Q31) |
| Q22 weighings | outputs are typed numbers | Q24 |
| Q41–Q42 machine, start, end, shift | `equipment_id` optional, unchecked against the operation; `process_date` (a `date`) only | Q7, Q9 |
| commit in one transaction | values, weighings and times must be **inside** the same commit to be required at it | Q11 puts "required" at closure; times, shift, machine and weighings at commit |
| rollback | `rollback_processing_run_internal` reverses stock, outputs, safety states and GL, and does not touch losses or cost entries (`grep -c processing_run_losses` → 0); refuses if an output was consumed (`OUTPUT_CONSUMED`) | unchanged; a reversed run's closure and values stay as history (Q31) |
| existing loss rows | editable rows keyed per category | migrate in place as originals (Q28) |

---

## §4 · (c) Parameters and indicators per operation

- **Configuration (Q10):** `operation_type_fields (operation_type_code, field_code)` — `kind` (`parameter` = a setting the run used ·
  `indicator` = a result the run produced), `value_type` (`number` · `count` (integer ≥ 0) · `text` · `yes_no`), `unit` (free text, e.g. `kWh`,
  `min`, `pcs`), `is_required`, `has_range`, `range_min`, `range_max` (NULL = **Not yet set** when `has_range`), `is_active`, `sort_order`,
  names, notes. A field is never deleted, only retired, so old values keep their meaning.
- **How a run records values (Q11):** a value row `(run_id, field, value, source, recorded_by, recorded_at, corrects_id, correction_reason,
  inbox_id, site_from, site_to, site_dataset_ref)`. The field must belong to the run's operation (`RUN_VALUE_FIELD_NOT_ON_OPERATION`). Values
  can be given at commit (the form shows the operation's fields, pre-filled from a recipe) or later on the run page. **Required fields are
  checked by the closure** (`RUN_REQUIRED_VALUES_MISSING|<fields>`), not by the commit.
- **Out of range (Q12):** recorded and flagged (amber, "outside the range set for this parameter"), never refused — a reading is a fact.
- **Device-fed later (Q14):** the value row already carries `source = 'device'`, `inbox_id` and the site pointer (MES-0 §3.9). When a
  controller's point list exists, a migration adds `transform_controller_summary_v1` and a confirm branch in `capture_confirm_internal`
  that writes value rows against a run chosen at confirmation (as tickets are chosen today) — the value table does not change.
- **Where "Not yet set" ranges show:** on the operation page beside the field, on the run page beside any value of that field ("range: Not yet
  set"), and on `/settings/pending-values` as **V36** (Q35) — one row per active field with `has_range` and no min/max.
- **Seeded fields (Q13)** — from the specification, none required, none with a range:

| operation | fields (kind indicator unless marked) | spec |
|---|---|---|
| `manual_disassembly` | modules in (count) · cells out (count) · cells damaged in disassembly (count) | §3.2 |
| `casing_removal` (new) | cells in, hard case (count) · cells in, pouch (count) · classified by (`text`: visual / equipment) · units the equipment could not identify, judged by hand (count) · misclassifications (count) · scrap: cut through · internal short · smoke · fire (4 counts) · cuts this run (count) | §3.3 |
| `electrode_separation` (new) and `electrode_line` | cells in (count) · run time (min) · energy (kWh) · unplanned stops (count) · unplanned stop time (min) | §3.4 |
| `electrode_powder_line`, `battery_powder_line` | run time (min) · energy (kWh) | §3.5 |
| `deep_discharge` | none in MES-4a (per-module results, duration and energy are MES-5a) | §3.1 |

## §5 · (d) Recipes

- **Model (Q16):** `process_recipes (id, operation_type_code, code, name_en, name_zh, is_active)` + `process_recipe_versions (id, recipe_id,
  version int, values jsonb {field_code: value}, notes, created_by, created_at)`, append-only; a change is a new version; `UNIQUE (recipe_id,
  version)`. Only `parameter` fields of the recipe's operation may appear in a version (`RECIPE_FIELD_NOT_A_PARAMETER`).
- **What a run records:** `processing_runs.recipe_version_id` (optional). Choosing one pre-fills the run's parameter values with `source =
  'recipe'`; what the run actually used is what its value rows say, and the run page shows any value that differs from the recipe version.
- **No code prefix:** a recipe code is typed (a dictionary-like name, e.g. `CATH-STD`); `document_type_exceptions` row for `process_recipes.code`.

## §6 · (e) Balance closure

- **The equation, per run** (each run is one split point): **input = Σ outputs + Σ named losses + remainder**, read by `run_balance(run)`:
  input = Σ `quantity_consumed`; outputs = Σ `quantity_produced` (each from its weighing, Q24); named losses = Σ current loss rows; remainder =
  input − outputs − named losses. `loss_qty` becomes input − outputs for new runs (Q17), so "unexplained" is the remainder, by construction.
  Named losses may not exceed input − outputs (today's inequality, kept).
- **Tolerance per operation (Q18):** `operation_types.balance_tolerance_pct` (% of input), NULL = Not yet set (**V1**), set on the operation page
  under `module.processing.edit`. Snapshotted into the closure row.
- **Closing (Q19):** `close_run_balance(run, explanation)` — refuses if a required value is missing or an output has no weighing; remainder 0 →
  closes; |remainder| within a set tolerance → closes, explanation optional; tolerance not set and remainder ≠ 0 → explanation required
  (Q46); beyond tolerance → explanation required (Q47), no second person. `RUN_BALANCE_EXPLANATION_REQUIRED|<remainder>|<tolerance or not set>`.
- **Who closes:** holders of `action.processing_aftercare` (Q50) — warehouse · admin by the role matrix (`docs/role-matrix.md:212`, [Q]; live
  holders not re-measured).
- **After closure:** a later loss or value correction marks the closure superseded; the run is unclosed again until someone re-closes.
- **State-changing runs (Q20):** input = output and loss = 0 by construction (`:284-290`) → "balance: not applicable", no closure.
- **What month-end lists (Q22):** a warning arm "runs with an unclosed balance" (committed, live, `process_date` ≤ period end, transforming,
  committed from MES-4a on, no current closure). **`close_period` unchanged** — it blocks only on unallocated runs today
  (`processing_runs_blocking_close.sql:20-32`). Plus an `operations_now` arm `processing_balance_unclosed` (`module.processing.view`).
- **Cost allocation (Q23):** independent. `allocate_processing_costs` reads output quantities and metal content, never losses
  (`grep -i loss` → 0); closure moves no money. Allocation does not wait for closure — otherwise `close_period`, which blocks on unallocated
  runs, would in effect block on unclosed balances, against Q48.

## §7 · (f) Weighings on outputs (Q22)

- **Link (Q24):** `processing_outputs.weighing_id → weighings`, `UNIQUE` (one weighing serves one leg). The weighing must be confirmed,
  standalone net (`ticket_id IS NULL`, `role = 'net'`, the subject shape at `weighings.sql:37-38`), not superseded (`corrects_id` chain), and the
  leg's quantity **is** its `weight_kg` (unit kg). Two ways to supply it at commit: pick an existing confirmed weighing (device-fed or entered at
  `/operation/capture`), or type the weight at commit — the commit records a manual weighing through the same inbox → transform → confirm path
  in its own transaction (instrument optional; "instrument not recorded" is flagged as MES-2 does).
- **Calibration (Q25):** a weighing from an instrument out of calibration is refused at commit (`READING_INSTRUMENT_NOT_CALIBRATED`, the
  MES-3a ruling 1 shape); no instrument → flagged only while `require_calibrated_since` is NULL.
- **A linked weighing is not correctable (Q26):** `correct_weighing` refuses `WEIGHING_IN_USE|<run code>` — a quantity correction is a
  reversal plus a new run (Q49).
- **Runs without one:** a transforming run committed from MES-4a on cannot exist without them (`OUTPUT_WEIGHING_REQUIRED|<leg>`). Earlier runs
  keep none and show "recorded before weighings were required". State-changing runs have no outputs.

## §8 · (g) Machine, start, end and shift

- **Machine (Q9):** `operation_type_equipment (operation_type_code, fixed_asset_id)`, only `fixed_assets.category = 'equipment'`. At commit: if the
  operation has at least one linked asset not disposed, `p_equipment_id` is required (`EQUIPMENT_REQUIRED_FOR_OPERATION|<op>`) and must be one of
  them (`EQUIPMENT_NOT_LINKED_TO_OPERATION|<code>|<op>`). The existing acquisition / disposal checks stay (`:140-158`). **No link is seeded**
  (which machine runs which operation is Tim's data, entered on the operation page) — so until someone links a machine, nothing changes.
- **The U1-B picker:** reads the chosen operation's linked machines instead of every asset card; with no links it says "no machine is linked
  to this operation" and stays optional (`NewProcessingForm.tsx:350-371`, `new/page.tsx:120-133`).
- **Start, end, shift (Q7):** `started_at`, `ended_at` (timestamptz), `shift_code → shifts` — required for runs committed from MES-4a on:
  `RUN_TIMES_REQUIRED`, `RUN_SHIFT_REQUIRED`, `RUN_END_BEFORE_START`, `RUN_IN_FUTURE`, `RUN_DATE_OUTSIDE_RUN_TIME` (the process date must lie
  between the Singapore dates of start and end); backed by `CHECK … NOT VALID` like `processing_runs_operation_type_required`
  (`processing_runs.sql:142-144`). Shift is chosen, never derived (times are NULL by design, `shifts.sql:13,31-33`).
- **Operator (Q8):** `created_by` is the person who committed at the station; no separate column.
- **Effect on live runs:** none. NOT VALID constraints leave existing rows alone; their new columns stay NULL (Q94). Live had **14 rows, 10
  undeleted, 0 with a machine** on 2026-10-05 [Q, MES-0 §10.6] — not re-measured.

## §9 · (h) Corrections

- **Quantities (Q31):** today's path, unchanged — a rollback request (`submit_rollback_request`, CFO level 2) reverses the run; the replacement
  run carries `corrects_run_id`, which must point at a **reversed** run not already corrected (`RUN_CORRECTS_NOT_REVERSED`,
  `RUN_ALREADY_CORRECTED`). Both runs show the link.
- **Losses, values, events (Q28, Q29):** append-only rows; a correction is a new row with `corrects_id` and a required reason; readers take the
  newest non-superseded row. Withdrawing a loss is a correction to 0 (`quantity > 0 OR corrects_id IS NOT NULL`).
- **Header fields (Q30):** start, end, shift, machine, recipe version, notes — `correct_run_header(run, field, value, reason)` writes a
  `processing_run_corrections` row (old, new, reason) and updates the header; the original stays in the correction row and the change log.
  Process date, quantities, operation and work order: never (reversal + new run).
- **Policies (Q32):** drop the UPDATE policies on `processing_runs`, `processing_inputs`, `processing_outputs` and the INSERT/UPDATE/DELETE
  policies on `processing_run_losses`; every write goes through a function. Measured: no app path writes those three tables directly
  (`grep -rn "\.update(" app/operation/processing` hits only `costActions.ts:97,133`, which update `processing_cost_entries`). Fixture 222 P3
  (a direct notes update allowed) and L1 (warehouse updates and deletes losses) flip.

## §10 · (i) Electrolyte loss and cross-contamination, as ruled

- **Electrolyte (Q51):** derived = electrolyte share of cell mass (V10, "Not yet set") × input mass, marked `derived`, never the remainder. Per the
  MES-0 cut plan this is **MES-4b** (loss `basis` + V10). MES-4a keeps the closure arithmetic blind to how a loss row was obtained, so a derived
  row slots in as one more named loss; until then electrolyte is either a measured `electrolyte_evaporation` row or part of the remainder (with
  an explanation) — never invented. **Q2.**
- **Cross-contamination (Q52):** checks per stream, attached to the output batch and the run's shift, with a reminder for shifts without a check
  — **MES-4b** (`contamination_checks`). It needs MES-4a's `shift_code` on runs, which is why 4a comes first. **Q2.**

## §11 · (j) Approvals, audit trails, change log, masking

- **Approvals: none new** (MES-0 §4.1: run values, events, closures are records of events; closure beyond tolerance needs an explanation, not an
  approver, Q47). Quantity correction keeps the CFO rollback request. Approvals ON / finance / cfo / 1,000 unchanged.
- **Change log:** every new table gets the two triggers; **no exclusion** (volumes are per run, not per sample). New columns on
  `processing_runs` / `processing_outputs` ride their triggers.
- **Trail:** `processing_run` (`trail_subjects.sql:158`) gains members `processing_run_values`, `processing_run_events`,
  `processing_run_closures`, `processing_run_corrections` (today's eight at `trail_subject_members.sql:37-44`); new subject `operation_type`
  (fields, machines, recipes, versions, tolerance) by the seven steps (`docs/change-log.md:446-471`); `check-trail-wording` gains an arm.
- **Masking: none new.** No price or amount in any new column. But `processing_runs` and `processing_outputs` are column-list-grant tables with
  `_masked` views: every new column needs the grant and the view in the same migration (`colgrant` would catch it late).

## §12 · (k) "Not yet set" values MES-4a adds

| # | value | page | arm reads | permission | supplied by | when |
|---|---|---|---|---|---|---|
| V1 | Allowed balance variance per operation (% of input) | `/operation/operation-types/<code>` | each active **transforming** operation with `balance_tolerance_pct` empty | `module.processing.view` | Tim with cto (process engineer) | end of commissioning of each stage |
| V7 | Shift start and end times | `/settings/dictionaries` (shifts) | **the V6 arm** — same two columns (Q35) | `module.processing.view` | Tim | before line start |
| V36 (new) | Range of a parameter that has one | `/operation/operation-types/<code>` | each active field with `has_range` and no min/max (0 rows at seed — Q13 seeds none with a range) | `module.processing.view` | equipment vendor / process engineer | each stage's commissioning |

Each with its arm and its row in `docs/mes-pending-values.md` in the same commit (MES-1 Q2 rule). V10 (electrolyte share) and V11
(contamination warning level) stay with MES-4b.

## §13 · (l) Migration shape and broken-window assessment

**One migration** `db/migrations/2026-10-0X-mes4a-processing-record.sql` (date from `date`): the nine tables (+ triggers, change-log bindings,
anon decisions, `document_type_exceptions`); `processing_runs` and `processing_outputs` columns with grants and masked views; the losses
reshape (add `id bigserial`, drop the composite PK, add `corrects_id`, `correction_reason`, append-only guard; existing rows become originals);
policy drops; two operation types with form and safety rows; `commit_processing_run` (`DROP` + `CREATE` — the parameter list grows, and
`preflight_migration.py` refuses a `CREATE OR REPLACE` that changes the signature); the new functions; `pending_values`, `operations_now`,
month-end reader; trail registry. `check_mirrors.py`: `operation_type_fields`, `operation_type_equipment`, `processing_event_types` RUNTIME
CONFIG (recipes are data, not config). Registries that move: 46 fixtures / 133 call lines, fixtures 153 and 222 (L1, P3), new fixture 253,
`lib/database.types.ts`, `lib/modules.ts`, the trail catalogue.

**Broken window (old app + new database)** [I]: PostgREST resolves `commit_processing_run` by argument names, so the old form's call still
reaches the function — and is **refused** (`RUN_TIMES_REQUIRED` …, raw code on the old page): **nobody can record a processing run until the
deploy**. The old loss panel's upsert / delete fails (policies dropped): **losses cannot be categorised until the deploy**. Reads are unaffected
(columns only added). Expected window ≈ MES-3b's without the pause (≈ 1 h).

**Existing test runs:** live had 14 rows / 10 undeleted (2026-10-05 [Q]) and **8 committed, unallocated** runs dated 2026-06-10 → 2026-08-16
(UNBLOCK-1 Step 0 §3 5.1 [Q]; U1-B Q26 left them to Tim's own data entry). MES-4a leaves all of them as they are: no times, shift, weighings
or closure ("recorded before balance closure"), not listed by the new month-end or reminder arms (Q21); their loss rows migrate as original
rows. The 8 unallocated runs keep blocking `close_period` exactly as today — MES-4a adds no block. **Not re-measured; the readings file has the
queries.**

---

## §14 · (m) Time estimate — floor and work, as two numbers

**Calibration** (active time = opening → push minus waits on Tim):

| cut | opening → push | pauses | **active** | estimate | active ÷ estimate (low – high) |
|---|---|---|---|---|---|
| MES-1 [Q] | 10:39:40 → 16:07:50 | 2 h 49 m 10 s | **2 h 39 m 00 s** | 4 h 20 m – 8 h 35 m | 0.61 – 0.31 |
| MES-2 [Q] | 16:52:22 → 20:40:21 | 1 h 01 m 23 s | **2 h 46 m 36 s** | 2 h 35 m – 5 h 10 m | 1.07 – 0.54 |
| MES-3a [Q] | 21:18:39 → 09:49:19 | 9 h 43 m 47 s | **2 h 46 m 53 s** | 2 h 50 m – 5 h 15 m | 0.98 – 0.53 |
| **MES-3b [M]** | 10:30:04 → 13:36:35 | 41 m 03 s (Tim's pause, 11:56:31 → 12:37:34) | **2 h 25 m 27 s** | 2 h 50 m – 4 h 20 m | **0.86 – 0.56** |

MES-3b split [M bounds, I categories; `/Users/timchen/.claude/jobs/94c80e21/tmp/split.py`]: building **1 h 02 m 37 s** (orientation 4 m 42 s ·
database layer 11 m 22 s · fixtures + 38 injections 9 m 57 s · pages 28 m 31 s · messages 2 m 59 s · proof scripts 5 m 06 s) · static 5 m 17 s ·
**clean floor 57 m 16 s** (smoke 20 m 21 s · surveys 11 m 12 s · full gate 9 m 31 s · dry run + apply + types 6 m 31 s · backup unoverlapped
5 m 14 s · live proofs 2 m 45 s · offline gate 1 m 20 s · commit 22 s) · incidents 13 m 23 s · docs 6 m 54 s. Work = 1 h 14 m 48 s (0.65 of its
low end); floor + incidents 1 h 10 m 39 s (inside its 55 m – 1 h 20 m).

**Process floor (MES-4a):** MES-3b's clean floor (57 m) + a longer gate (a new fixture and 46 touched ones; the offline gate re-run more than
once is likely) + smoke and the 390 / 1280 surveys over two more routes + live proofs as several accounts (commit with weighings, closure,
corrections) → **≈ 1 h 05 m clean; ≈ 1 h 35 m with incidents** (MES-3b had 13 m; the commit rewrite raises the odds of a red offline gate).

**Work:**

| part | basis | low | high |
|---|---|---|---|
| orientation | MES-3b 5 m | 5 m | 5 m |
| database layer: 9 tables, 2 masked tables' columns, losses reshape, policy drops, two operation types, `commit_processing_run` rewrite, ~10 functions, arms | MES-3b 11 m for 4 tables + 6 functions; MES-3a 33 m; the commit function is the largest in the area | 40 m | 70 m |
| fixtures: new fixture 253 (~12 arms) + ~25 injections; 133 call lines in 46 fixtures (scripted rewrite, then chase reds); fixtures 153, 222 | MES-3b 10 m for 1 fixture + 38 injections | 45 m | 85 m |
| pages: operation page (new, 2 routes), new-run form rework, run page (values, events, losses, balance, corrections), list column, shifts in the registry, month-end, reminders | MES-3b 28.5 m for 3 new routes + ~12 changed pages | 45 m | 80 m |
| messages en / zh | MES-3b 3 m | 5 m | 10 m |
| proof scripts and role table | MES-3b 5 m | 6 m | 12 m |
| static checks | MES-3b 5 m | 5 m | 10 m |
| docs | MES-3b 7 m | 7 m | 12 m |
| **total** | | **2 h 33 m** | **4 h 44 m** |

**Estimate: process floor ≈ 1 h 05 m – 1 h 35 m + work ≈ 2 h 35 m – 4 h 45 m = ≈ 3 h 40 m – 6 h 20 m of active time, plus any pause** —
against MES-0's 8 h 40 m – 15 h 30 m. The last four cuts landed at 0.61, 1.07, 0.98 and 0.86 of their low ends, so the low end is likely
but not safe; the honest single number is ≈ 4 h 30 m. The largest uncertainty is the fixture churn (133 call lines). Each item Tim moves out
(Q2's loss categories, Q4, Q5, Q15's events) takes 5–15 m off; splitting the cut (Q6) adds one floor (≈ 1 h) and a second window.

---

## §15 · Every open question, with a recommended answer and its evidence

Questions in one block are independent unless one names another.

### A · Scope

❓ **Q1 — Contents.** MES-0 said 7 tables / 4 pages.
➡️ **As §2: 9 new tables, columns on `processing_runs` / `processing_outputs`, losses reshaped append-only, two operation types, a new operation
page (2 routes), the run form and run page reworked; fold-ins Q4, Q5.** Left out: §2's list.

❓ **Q2 — The brief's Q43 line vs the MES-0 cut plan.** MES-0 Q43 names the function-13 *counts*; MES-0 §8.2 puts contamination checks, the
measured/derived loss basis with V10 and the collected-dust form in MES-4b, and the new loss categories (Q56) in MES-4b too. The brief lists
contamination, electrolyte and dust among MES-4a's fields.
➡️ **Follow the MES-0 plan: MES-4a builds the counts as configured indicators; contamination checks, loss basis + V10 and the new forms stay in
MES-4b. Move only Q56's three loss categories into MES-4a** (three dictionary rows; the first closures can name them).

❓ **Q3 — The two new operation types (MES-0 Q37).**
➡️ **`casing_removal`: input `loose_cells`; outputs `de_cased_cell`, `casing`. `electrode_separation`: input `de_cased_cell`; outputs
`cathode_sheet`, `anode_sheet`, `separator`. Both transforming, both accept `discharged_verified` only** — the split of `electrode_line`'s own
rows (`operation_type_input_forms.sql:20-21`, `output_forms.sql:18-21`, `safety_states.sql:53`). `electrode_line` stays active for a combined machine.

❓ **Q4 — Fold-in: the deep-discharge run cannot be recorded from the page** (§1.5; `NewProcessingForm.tsx:247-250` vs `:117,542`) [I].
➡️ **Fold it in:** the output check applies only when the operation produces outputs; a live proof records a deep-discharge run through the page.

❓ **Q5 — Fold-in: no screen sets shift times** (§1.6), while V6 (and V7) send people to a page that cannot.
➡️ **Fold it in:** register `shifts` in the dictionary editor with a new `time` field kind (start and end; both or neither, the
`shifts_hours_paired` CHECK); V6's link goes there.

❓ **Q6 — One cut or two.** Estimate ≈ 3 h 40 m – 6 h 20 m, under the largest measured cut (AT-1c-2, 9 h 50 m [Q, MES-0 §8.3]).
➡️ **One cut.** Splitting (record vs closure) adds a floor (≈ 1 h) and a second window on the same commit function.

### B · The run header

❓ **Q7 — Start, end and shift (MES-0 Q42).**
➡️ **`started_at`, `ended_at` (timestamptz), `shift_code` required for runs committed from MES-4a on, enforced by the function
(`RUN_TIMES_REQUIRED`, `RUN_SHIFT_REQUIRED`, `RUN_END_BEFORE_START`, `RUN_IN_FUTURE`, `RUN_DATE_OUTSIDE_RUN_TIME`) and backed by `CHECK … NOT VALID`.
The process date stays the business date of the stock movements and must lie between the Singapore dates of start and end. Shift is chosen.
Historical runs stay NULL.**

❓ **Q8 — Operator.** The spec names an operator per record (§5); runs have `created_by`.
➡️ **No new column: the person who commits at the station is the operator (`created_by`).** A confirming person already exists on device drafts (MES-2).

❓ **Q9 — Machines per operation (MES-0 Q41).**
➡️ **`operation_type_equipment` (operation, asset), assets of category `equipment` only; a run of an operation with at least one linked asset
not disposed must name one of them (`EQUIPMENT_REQUIRED_FOR_OPERATION`, `EQUIPMENT_NOT_LINKED_TO_OPERATION`). No link is seeded — Tim links
the machines on the operation page. The picker shows only the chosen operation's machines.**

### C · Parameters and indicators

❓ **Q10 — The field model (MES-0 Q43).**
➡️ **`operation_type_fields`: kind `parameter` | `indicator`; value type `number` | `count` | `text` | `yes_no`; unit; `is_required`;
`has_range` with min/max (empty = Not yet set); retired, never deleted. Edited on the operation page under `module.processing.edit`.**

❓ **Q11 — When values are entered, and where "required" bites.**
➡️ **At commit or later on the run page, as append-only value rows; required fields are checked by the balance closure, not by the commit** —
so a device value arriving after the operator has recorded the run can still complete it.

❓ **Q12 — A value outside its range.**
➡️ **Recorded and flagged, never refused.**

❓ **Q13 — Which fields are seeded.**
➡️ **§4's table, from the specification: none required, none with a range.** Requiring any of them is Tim's later setting, not code.

❓ **Q14 — Device-fed values and the two ingestion classes.** MES-0's plan lists "controller and workstation transforms"; no controller point
list exists (D3), so the payload would be invented; `capture_confirm_internal` confirms only weighings (`:55-56`).
➡️ **Not built in MES-4a** (the MES-3b Q25 precedent). Value and event rows carry `source`, `inbox_id` and the site pointer now, so a later
transform lands without a table change. The two classes keep waiting as `awaiting_transform`.

❓ **Q15 — Exception events (spec §3.1 / §5).**
➡️ **`processing_run_events`: time, type, duration (min), action taken, responsible person (text or an employee), append-only; types from a
dictionary seeded `unplanned_stop`, `equipment_alarm`, `safety_alarm` (no "other").**

### D · Recipes

❓ **Q16 — Recipes (MES-0 Q44).**
➡️ **Named recipes per operation with immutable numbered versions holding parameter values; a run records the version it used (optional), which
pre-fills its parameters; the run page shows where actual values differ. Typed codes, no document prefix. `module.processing.edit`.**

### E · Balance closure

❓ **Q17 — `loss_qty` on new runs.**
➡️ **Derived: input − outputs, always. A supplied `p_loss_qty` that differs is refused (`LOSS_QTY_NOT_INPUT_MINUS_OUTPUT`).** Named losses may
not exceed it (today's rule, kept). The remainder is the unexplained mass.

❓ **Q18 — Tolerance.**
➡️ **`operation_types.balance_tolerance_pct` (% of input), empty = Not yet set (V1), set on the operation page under
`module.processing.edit`, copied into each closure row.**

❓ **Q19 — Closing a run.**
➡️ **`close_run_balance(run, explanation)` by `action.processing_aftercare`: refuses while a required value or an output weighing is missing;
remainder 0 closes; within a set tolerance closes; tolerance not set and remainder ≠ 0, or beyond tolerance, needs a written explanation (Q46,
Q47). Closure rows are append-only; a later loss or value correction supersedes the closure and the run is unclosed again.**

❓ **Q20 — State-changing runs (deep discharge).**
➡️ **No closure: input = output and loss = 0 by construction (`commit_processing_run.sql:284-290`); shown "balance: not applicable".**

❓ **Q21 — Runs committed before MES-4a.**
➡️ **Not closable, labelled "recorded before balance closure", left out of the month-end and reminder lists** (Q94: no back-fill; all test data).

❓ **Q22 — Month-end and the reminder (MES-0 Q48).**
➡️ **A month-end warning arm (runs with an unclosed balance up to the period end) that does not block; `close_period` unchanged. An
`operations_now` arm `processing_balance_unclosed` under `module.processing.view`.**

❓ **Q23 — Cost allocation.**
➡️ **Independent of closure in both directions.** Allocation never reads losses; closure moves no money; if allocation waited for closure,
`close_period` (which blocks on unallocated runs) would in effect block on unclosed balances, against Q48.

### F · Weighings

❓ **Q24 — How an output links to its weighing (MES-0 Q22).**
➡️ **`processing_outputs.weighing_id`, unique; a confirmed, standalone net weighing, not superseded; the leg's quantity is its kg. Either pick an
existing confirmed weighing, or type the weight at commit and the commit records a manual weighing through the inbox → transform → confirm path
in the same transaction (instrument optional, flagged when absent). `OUTPUT_WEIGHING_REQUIRED` for new transforming runs; outputs are in kg.**

❓ **Q25 — Calibration at commit.**
➡️ **A weighing from an instrument out of calibration is refused (`READING_INSTRUMENT_NOT_CALIBRATED`, MES-3a ruling 1); a weighing with no
instrument is flagged only while `require_calibrated_since` is NULL.**

❓ **Q26 — Correcting a weighing already linked to an output.**
➡️ **Refused (`WEIGHING_IN_USE|<run>`): the correction is a reversal plus a new run (Q49).**

❓ **Q27 — Inputs.** The spec weighs inputs too (§4.1); Q22 covers outputs.
➡️ **No weighing reference on inputs in MES-4a:** an input's mass is drawn from a batch whose own record (receipt or upstream output) already
carries it.

### G · Corrections

❓ **Q28 — Append-only losses.**
➡️ **Reshape `processing_run_losses` in place: an `id` key, `corrects_id` and a required reason; one current row per category; a withdrawal is a
correction to 0; written only through `record_run_loss` / `correct_run_loss` (aftercare or processing edit, as today); existing rows become
originals; the page's upsert and delete go.**

❓ **Q29 — Values and events.**
➡️ **The same shape (`corrects_id` + reason, newest wins), no separate corrections table for them.**

❓ **Q30 — Header fields.**
➡️ **Start, end, shift, machine, recipe version and notes are corrected through `correct_run_header`, which writes a
`processing_run_corrections` row (old, new, reason) and updates the header. Process date, quantities, operation and work order: never — reversal
plus a new run.**

❓ **Q31 — Quantity corrections.**
➡️ **Unchanged rollback request (CFO); the replacement run takes `corrects_run_id`, which must point at a reversed run not already corrected;
both pages show the link.**

❓ **Q32 — The UPDATE-policy debt (`ROLE1B3B-PROCESSING-UPDATE-POLICIES`).**
➡️ **Drop the UPDATE policies on runs, inputs and outputs and the write policies on losses; every write through a function; close the known
issue.** No app path uses them (measured); fixture 222 P3 and L1 flip.

### H · Approvals, permissions, register

❓ **Q33 — Approvals, change log, trail, masking.**
➡️ **As §11: no approval; every new table logged, no exclusion; four new members of `processing_run` and a new `operation_type` subject; no
new masking, with the three-change rule for the new columns on `processing_runs` and `processing_outputs`.**

❓ **Q34 — Permissions.**
➡️ **No new code.** Configuration (fields, machines, tolerance, recipes, event types) `module.processing.edit`; commit `action.processing_commit`;
later values, events, losses and closure `action.processing_aftercare` (or `module.processing.edit` for losses, as today); header corrections the
same as the field's owner.

❓ **Q35 — Pending values.**
➡️ **V1 (tolerance per transforming operation) and V36 (parameter ranges) as new arms; V7 is answered by the V6 arm (same columns) — its label
and docs row name both uses and its link moves to the shift editor.** Each arm and its docs row in the same commit.

❓ **Q36 — Migration and broken window.**
➡️ **Accept §13: one migration; in the window nobody can record a run or categorise a loss from the old pages (named refusals); reads
unaffected; aim ≈ 1 h.**

---

## §16 · Assertions measured and found false or imprecise

1. **Brief, Q43 line: "the function 13 counts (… cross-contamination sampling, electrolyte loss measured or estimated, dust collected) live
   there."** MES-0 Q43 (`README.md:908-910`) names only counts; contamination checks, the loss basis and the dust form are MES-4b in MES-0 §1.3
   row 13 and §8.2 (`:113`, `:700`). A difference to rule (Q2), not an error in the rulings.
2. **Brief: "the effect on the 10–14 existing test runs and the 8 runs without cost allocation."** **Not re-measured** — the live read was
   refused. Last measurements: 14 rows, 10 undeleted, 0 with a machine (MES-0 §10.6, 2026-10-05); 8 committed unallocated (UNBLOCK-1 Step 0 §3
   5.1; still open in `docs/known-issues.md:10067-10075`).
3. **MES-0 §8.2: "controller and workstation transforms" in MES-4a.** Recommended out (Q14): no point list exists, and the confirm path accepts
   only weighings.
4. **`docs/mes-pending-values.md:22`: V6's page is "`/operation/handovers` (the shift dictionary)".** That page only reads shifts; no screen sets
   shift times (Q5).
5. **MES-0 §1.3 row 11 "Only `processing_runs.notes`" for parameters** — still true, and operation types (PROC-WIRE-1B-i) now exist to hang
   them on (`operation_types.sql:59-72`); MES-0 was written after them, so this is a confirmation.
6. **The machine picker "offers machines"** (U1-B Q21): it offers every asset card, any category (§1.7).
7. **`/operation/processing/new` records every operation** — not a deep-discharge run [I] (§1.5).

Matched on re-reading (repo only): a–h present; `require_calibrated_since` NULL as of MES-3b §5.3 [Q]; 5 operation types; 4 loss categories;
2 shifts with NULL times; `weighings` subject is a ticket or nothing; `processing_runs_operation_type_required` NOT VALID; rollback leaves
losses alone; `close_period` blocks only on unallocated runs.

## §17 · Stop

No code edits and no migrations. Waiting on Tim's answers to Q1–Q36.
