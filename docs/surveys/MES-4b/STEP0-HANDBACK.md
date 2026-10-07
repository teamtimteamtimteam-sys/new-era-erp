# MES-4b Step 0 — hand-back (2026-10-07)

**STOP GATE.** No code edit, no migration, no live write. The only writes are docs: the close-out rulings (`59a5ffae`), this file and
`docs/surveys/MES-4b/live-readings.sql`. Waiting on Tim's answers to Q1–Q34 (§13).

**Opening check.** First command **2026-10-07 21:10:55 CST**. Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
`0968eb98b683ef497c16afd0bed3e31daf7ee6dc`. Close-out rulings then committed and pushed as `59a5ffae` ("MES-4a close-out rulings"). Files staged by
explicit path only.

**Live readings (measured, read-only):** 21:14 CST, as `postgres` (`rolbypassrls = true`), `BEGIN READ ONLY … ROLLBACK` under
`default_transaction_read_only = on`, business relations all base tables; `docs/surveys/MES-4b/live-readings.sql`, `READ_OWN_EXIT=0`.
7 accounts, 0 disabled · approvals ON · `material_forms` 13 rows (listed in §3) · materials 5 live, 4 with no form, 1 processable ·
output batches 20 (14 live), **one prefix (`OUT-2026-…`), highest stored number 381, every one on a material with no form** · `output_code_seq`
last value 679 · `inbound_code_seq` 488 · inbound batches 24 (15 live) · `document_types` **43** rows · loss categories 7 · loss rows 0 · MES-4a-era
runs 0 · shifts day / night, active, no times · assay results 4, 0 on an output batch · `change_log` 12,364 rows.

**How the facts were gathered.** Three read-only sub-agents (batches / forms / losses; numbering and the document registry; reminder arms,
pending values, trails, change log, masking, dictionaries). None connected to a database or ran a build. I read AGENTS.md, the specification PDF,
MES-0, the MES-4a Step 0 and hand-back, `docs/mes-pending-values.md` and the operation-model records in full in this session, and re-read every
load-bearing claim below at its file:line. Tags: **[M]** measured · **[I]** inferred from code reading · **[Q]** quoted from an earlier record.

---

## §1 · What grilling changed in MES-4b's scope

1. **`output_batches` is not a masked table** [M]: no column-list grant and no `output_batches_masked` (`db/tables/output_batches.sql:131-152`,
   RLS only). MES-0 §8.2 / Q45 say "construction on both batch tables (masked: column + grant + view)". Only `inbound_batches` is masked
   (`inbound_batches.sql:305-318`, `db/views/inbound_batches_masked.sql`). The three-change rule applies to one table, not two.
2. **"Prefix chosen from the material form" cannot be a literal in a function** [M]: fixture 100 arm 6 forbids any registered prefix literal in
   a function body (`db/fixtures/100-…:329-348`), and `document_type_prefix()` takes a registry key (`db/functions/document_type_prefix.sql:10-26`).
   So the mapping must be data: form → registry key → prefix + sequence (Q12).
3. **CODE-WIDTH-4 is wider than "three generators"** [M]: the same `LPAD(…, 4, '0')` sits in **42** generators (9 in `db/tables`, 33 in
   `db/functions`). The **11 gapped** ones (IN, OUT, PROC, ST, TASK, CON, DEV, WB, material, supplier, customer) never reset by year
   (`db/tables/tasks.sql:13`; `docs/known-issues.md:3286`), so their 9,999 is a **lifetime** cap, not a yearly one. PROC is at 705 burned
   (`docs/handbacks/SEARCH-2-stopgate.md:57`, 2026-09-13), OUT at 679 [M]. Q14.
4. **Adding output prefixes changes the search registry's shape** [M]: once `output_batches` carries more than one `document_types` row, search
   filters each row by `code LIKE prefix || '-%'` (`db/functions/search_documents_sql.sql:28-29,53-55`). Old `OUT-` codes stay findable only while
   the OUT row stays. It also moves `EXPECTED_ROWS = 43` (`scripts/check-search-registry.mjs:69`) and fixture 100's count, anchors and shapes.
5. **One existing assertion would go blind** [M]: fixture 195 E4 checks a destruction-certificate snapshot carries no output code with
   `v_snap::text ~ 'OUT-[0-9]{4}-'` (`db/fixtures/195-…:309`). With new prefixes a `CEL-…` code could leak and E4 would stay green. Q34.
6. **The operation ↔ form tables are not a gate** [M]: `operation_type_input_forms` / `_output_forms` are read by no function; the run form uses
   them only as a hint and offers every material for outputs (`app/operation/processing/new/page.tsx:96`, `NewProcessingForm.tsx:759`). New
   product rows there are information, not enforcement (Q10).
7. **No screen edits `material_forms`** [M] (`app/settings/dictionaries/registry.ts:30-35,164`); its write code is `module.materials.edit`
   (`material_forms.sql:70-76`). New forms and their `may_be_sold` arrive by migration — and `may_be_sold` is `NOT NULL` with no default
   (`:49`), so **Tim must answer saleability for each new form now** (Q9).
8. **`loss_categories` sits in neither mirror list** [M] (`db/check_mirrors.py` — no `loss` anywhere), though its header says RUNTIME CONFIG.
   MES-4b adds a column to it; the classification gap closes in the same commit (Q30).
9. **A reminder row needs a real row id** [M]: fixture 47 lets only `fx_rate_gap` carry a NULL `item_id` (`db/fixtures/47-…:327,339-351`). A
   "shift without a check" arm keyed on (date, shift) has no row of its own — it points at the shift's first run (Q24).
10. **"The collected-dust form" is a material form, not a data-entry form** [M]: MES-0 defines it as the form `collected_dust` on an output leg
    (§2 3.5f, §9 "leg (`collected_dust`)", Q55). It is one of Q55's six forms (§4, Q27).
11. **Processing outputs land with no storage location** [M]: the `processing_produce` movement is inserted without `location_id`
    (`db/functions/inventory_ledger_triggers.sql:62`). Collected dust lands the same way (Q27).
12. **Contamination needs a dictionary MES-0 did not name**: two streams (cathode, anode), each with the sheet form it samples, the foreign form it
    looks for and its warning level (V11) — so V11 has a row to live on and the reminder can find separation outputs from data, not codes (Q21).

---

## §2 · (a) Exactly what MES-4b contains

MES-0 §8.2 row 6 [M, `docs/surveys/MES-0/README.md:700`]: "`cell_constructions`, `contamination_checks`; construction on both batch tables
(masked: column + grant + view); loss `basis` (measured/derived) + basis factor; new forms and loss categories (data); per-product prefixes,
`generate_output_code`, per-prefix sequences, `CODE-WIDTH-4` — 4 / 3". MES-4a Step 0 Q2 moved the three Q56 loss categories **into** MES-4a (done,
live 7 categories [M]) and left contamination, loss basis + V10 and the new forms here.

**New tables (3):** `cell_constructions` (dictionary: `wound`, `stacked`, `unknown`; RUNTIME CONFIG) · `contamination_streams` (dictionary:
`cathode`, `anode`; sheet form, foreign form, warning level V11; RUNTIME CONFIG) · `contamination_checks` (append-only records).

**Changed tables:** `inbound_batches` + `cell_construction_code` (masked: column + column grant + `inbound_batches_masked`, one migration) ·
`output_batches` + `cell_construction_code` (not masked) · `processing_run_losses` + `basis` (`measured` | `derived`) + `derived_share_pct`
(snapshot) · `loss_categories` + `may_be_derived` (true on `electrolyte_evaporation` only) · `operation_types` + `electrolyte_share_pct` (V10) +
`electrolyte_loss_applies` + `requires_cell_construction` · `material_forms` +6 rows and + `output_document_key` · `document_types` +12 rows with 12 new sequences ·
`operation_type_output_forms` + rows for the new products.

**Functions:** `generate_output_code` (prefix and sequence from the batch's material form, via the registry) · non-truncating width in the 11
gapped generators · `commit_processing_run` (construction required on separation inputs; construction inherited by cell outputs) · the two
receipt functions (one optional trailing construction parameter) · `set_batch_cell_construction` · `record_derived_electrolyte_loss` ·
`record_contamination_check` / `correct_contamination_check` · `record_run_loss` writes `basis = 'measured'` · `pending_values` + V10, V11 ·
`operations_now` + `contamination_check_missing` (57 arms) · trail registry rows.

**Pages:** **new** `/operation/contamination` (shifts × streams: checked / not checked / not sampled, rates against V11) · **changed**
`/operation/processing/[id]` (contamination panel; loss panel shows basis, "Derive electrolyte loss" on applicable operations) ·
`/operation/operation-types/[code]` (electrolyte share, V10) · `/operation/processing/new` (shows input construction; refuses client-side on a
separation run whose input has none) · `/inbound/new` and `/inbound/receive` (optional construction) · `/inbound/[id]` and `/output/[id]/edit`
(construction control; the output page lists the batch's contamination checks) · `/settings/dictionaries` (cell constructions, contamination
streams) · `/settings/pending-values` (labels) · search labels for 12 new document types.

**Fold-ins (Tim's close-out rulings):** tighten the smoke trail check on `/operation/operation-types/[code]` (Q31); re-run fixture 253's
injections for what changed after 16:11 (Q32).

**Left to later cuts:** per-module discharge, meters, electricity allocation (MES-5a) · per-inbound and monthly balance views, **powder yield**
(spec §3.5 "powder yield"), blending (MES-5b) · residual powder on foil, foil purity, moisture, particle size, samples (MES-6a) · contamination's
price consequence (downgrade, NCR — MES-6b) · dust-concentration alarms (MES-7b) · machine routing by construction (Q8) · a material-forms editor
(Q9) · enforcement of the operation ↔ form tables (Q10) · the 31 gapless generators' width (Q14).

---

## §3 · (b) New batch field and new output products

**Cell construction** — what: wound or stacked (or `unknown` — looked, cannot tell), a property of the **batch**, not the material
(spec §3.4: "batches of the same material category … may differ … depending on source"). Where entered: optional at receipt; on the inbound and
output batch pages; inherited at commit by cell outputs (Q6). Where shown: batch pages, run form beside each input, run page, labels not changed.
Relation: materials keep chemistry (`materials.chemistry`, `db/tables/materials.sql:27`); batches gain construction. Which batches it applies
to: those whose material form still holds cells — `material_forms.implies_dismantling` = true (whole pack, module, loose cells, de-cased cell,
mixed) [M, live forms]. Required at the input of the two operations that split electrodes (Q5). The MES-4a run record is unchanged; the commit
reads the input batches' construction.

**New output products** — six material forms (MES-0 Q55), live today 13 [M]:

| form | made by (output-form rows to add) | prefix (Q54) | saleable (Tim, Q9) |
|---|---|---|---|
| `cathode_powder` | electrode powder line | CPW | recommended yes |
| `anode_powder` | electrode powder line | APW | recommended **no** until Tim says otherwise |
| `copper_foil` | electrode powder line | CUF | recommended yes |
| `aluminium_foil` | electrode powder line | ALF | recommended yes |
| `collected_dust` | electrode powder line, battery powder line | DST | recommended **no** until Tim says otherwise |
| `harness_bms_busbar` | manual disassembly | HBB | recommended yes |

Existing forms gain prefixes too: `cathode_sheet` CTS · `anode_sheet` ANS · `separator` SEP · `casing` CSG · `structural_parts` STR ·
`loose_cells` and `de_cased_cell` CEL; everything else (`black_mass`, `electrode_scrap`, `whole_pack`, `module`, `mixed_unsorted`, `electrolyte`,
and any material with no form) stays `OUT`. A product is a **material** of that form: Tim creates the materials (e.g. "Cathode powder NMC") in the
material editor; MES-4b seeds none. A run's output leg names a material; the batch it creates takes its code from that material's form.
Live effect: none of the 20 output batches changes (all on form-less materials [M]).

## §4 · (c) Contamination checks and the shift reminder

- **Streams** (`contamination_streams`): `cathode` (samples `cathode_sheet`, looks for `anode_sheet`) and `anode` (samples `anode_sheet`, looks
  for `cathode_sheet`), each with `warning_pct` (V11, empty = Not yet set).
- **A check** (`contamination_checks`, append-only): run, stream, the sampled output batch (a leg of that run whose material form is the stream's
  sheet form), kind `sampled` | `not_sampled`, sample mass and foreign mass in **grams** (foreign ≤ sample), rate (generated), sampled at,
  method (free text), recorded by / at, the warning level copied at record time, `corrects_id` + reason. `not_sampled` carries a required reason
  and no masses (Q23).
- **Shift**: read from the run (`processing_runs.process_date`, `shift_code`, both required since MES-4a, `assert_run_header.sql:32-37`) — not
  stored again, so a header correction of the shift (`correct_run_header`) moves the check with it.
- **Reminder** `contamination_check_missing` (`module.processing.view`): one row per (process date, shift, stream) where a committed MES-4a-era
  run produced a leg of the stream's sheet form and no current check (either kind) exists on any run of that date and shift for that stream;
  `item_id` = the earliest such run (fixture 47's row-id rule), `subject` = stream. Pre-MES-4a runs have no shift and never appear.
- **Rate vs V11**: flagged "above the warning level", never refused; with V11 empty, "could not be judged" (NULL), not "within".
- **Entry**: the run page's contamination panel, under `action.processing_aftercare` (the MES-4a code for anything recorded after commit).
  Read: `module.processing.view` **or** `module.output.view` (the sheet batch's buyer-facing quality fact), via a gated reader.
- **Not related to balance closure**: contamination does not change mass (spec §3.4: "the balance still closes normally"); closure neither waits
  for nor reads checks.

## §5 · (d) Electrolyte loss

- **Basis** on every loss row: `measured` (typed kg — today's `record_run_loss`, which writes `measured` explicitly) or `derived`.
- **Share (V10)**: `operation_types.electrolyte_share_pct`, % of the run's input mass, empty = Not yet set; `electrolyte_loss_applies` marks the
  operations where cells are opened or crushed — seeded on `casing_removal`, `electrode_separation`, `electrode_line`, `battery_powder_line`
  (Tim confirms the list, Q17).
- **Derived row** (`record_derived_electrolyte_loss(run, notes)`, aftercare): quantity = share × `total_input` / 100, category must have
  `may_be_derived` (only `electrolyte_evaporation`), share copied onto the row (`derived_share_pct`). Refuses with no share
  (`ELECTROLYTE_SHARE_NOT_SET|<operation>`), on an operation without `electrolyte_loss_applies`, on a state-changing run, and — through the
  existing guard — when named losses would exceed input − outputs (`LOSS_CATEGORIES_EXCEED_LOSS_QTY`). Never computed from the remainder (Q51).
- **Closure**: a derived row is one more named loss — `processing_run_balance_all` sums current rows regardless of category or basis
  (`db/views/processing_run_balance_all.sql:55-59`); remainder = input − outputs − named. A later derived or corrected row reopens a closed run by
  the existing id watermark (`processing_run_closures.sql:8-10`). The balance panel shows how much of the named loss is derived.

## §6 · (e) The collected-dust form

An output leg of material form `collected_dust`, on powder-line runs: weighed like every MES-4a output leg (`commit_processing_run.sql:290-358`),
counted in the run's outputs (so in the balance, as spec §3.5 requires), its own batch with prefix `DST`. It lands with no location, like every
processing output (`inventory_ledger_triggers.sql:62`), and is placed by transfer or scan (MES-3b). It is **not** the loss category `dust_spill`:
dust that is collected and weighed is an output; dust that escaped is a loss. It can be fed back to a run like any output batch (FIN-25), if its
material is marked processable. No safety state is seeded for it (combustible-dust handling is MES-7b).

## §7 · (f) Effect on MES-4a's closure, the run form and existing fixtures

- **Closure:** arithmetic unchanged (§5); one more way to write a named loss.
- **Run form:** shows each input's construction; a separation run with an input lacking a determined construction is blocked with a sentence and
  refused by the server (`INPUT_CELL_CONSTRUCTION_REQUIRED|<batch>`). Outputs unchanged (no form filter, Q10).
- **Fixtures** [M]: fixture 100 (43 → 55 rows, gapped 11 → 23, 12 anchors, 12 shapes at 5 digits) · `check-search-registry` 43 → 55 ·
  fixture 111 (57 arms) · fixture 195 E4 regex (Q34) · fixture 253 NEWOPS (separation inputs need a construction; outputs on a `loose_cells`
  material now mint `CEL-…`) · fixture 158 mentions a separation operation once · fixtures 30 and 47 do not commit separation runs, so the new arm
  does not light in them [I]. `commit_processing_run`'s signature does not change (no call-site churn this time). New fixture 254.

## §8 · (g) Approvals, trails, change log, masking

- **Approvals:** none (MES-0 §4.1: records of events). Approvals ON / finance / cfo / 1,000 unchanged.
- **Change log:** the three new tables bound (no exclusion — fixture 235 keeps 8 exclusions); new columns ride existing triggers.
- **Trail:** `contamination_checks` joins `processing_run` (home) and `output_batch` (not home), the `receipt_ceiling_checks` precedent
  (`trail_subject_members.sql:472-481`); English labels for every new column and enum (`gen-trail-catalogue`, `check-trail-wording`).
- **Masking:** none new — no price or amount. `inbound_batches.cell_construction_code` goes into the column grant **and**
  `inbound_batches_masked` in the same migration; `output_batches` needs neither.

## §9 · (h) "Not yet set" values MES-4b adds

| # | value | page | arm reads | permission | supplied by | when |
|---|---|---|---|---|---|---|
| V10 | Electrolyte share of input mass (%) per operation where cells are opened or crushed | `/operation/operation-types/<code>` | each active operation with `electrolyte_loss_applies` and no share | `module.processing.view` | cell supplier datasheets / process engineer | first electrode-separation batch |
| V11 | Contamination warning level (%) per stream | `/settings/dictionaries` (contamination streams) | each active stream with no warning level | `module.processing.view` | Tim / the first offtake customer's specification | first black-mass offtake contract |

Both arms under `module.processing.view` (fixture 249 pins that a processing reader sees only that code, `db/fixtures/249-…:450-453`). Each arm
and its row in `docs/mes-pending-values.md` in the same commit.

## §10 · (i) Migration shape and broken window

**One migration** `db/migrations/2026-10-0X-mes4b-fields-and-products.sql` (date from `date`): three tables (+ triggers, bindings, anon
decisions); columns (inbound with grant + masked view); six forms and their output-form rows; 12 `document_types` rows + 12 sequences;
`generate_output_code`; 11 generators widened; `commit_processing_run` (CREATE OR REPLACE — signature unchanged); the two receipt functions
(DROP + CREATE — a new trailing parameter; `preflight_migration.py` refuses an overload by CREATE OR REPLACE); new functions; `pending_values`,
`operations_now`; trail registry; `check_mirrors.py` lists (Q30).

**Broken window (old app + new database)** [I]: separation and electrode-line runs whose inputs carry no construction are refused — every batch on
live has none, and the old app has no control to set it, so **no separation run can be recorded until the deploy** (raw code on the old page).
Receipts keep working (the new parameter has a default). New output batches on mapped forms mint new prefixes; the old app shows them as plain
codes; the old search page shows the 12 new document-type labels as raw keys. Everything else reads as before. Aim ≈ 1 h.

**Existing runs and batches:** untouched. Codes do not change; construction is NULL on all 24 inbound and 20 output batches [M]; the 0 live loss rows
mean the basis back-fill touches nothing [M]; no run gains a check or a derived loss.

---

## §11 · (j) Time estimate — floor and work, as two numbers

**Calibration** (active time = brief → push minus waits on Tim):

| cut | active | estimate | active ÷ estimate (low – high) |
|---|---|---|---|
| MES-1 [Q] | 2 h 39 m 00 s | 4 h 20 m – 8 h 35 m | 0.61 – 0.31 |
| MES-2 [Q] | 2 h 46 m 36 s | 2 h 35 m – 5 h 10 m | 1.07 – 0.54 |
| MES-3a [Q] | 2 h 46 m 53 s | 2 h 50 m – 5 h 15 m | 0.98 – 0.53 |
| MES-3b [Q] | 2 h 25 m 27 s | 2 h 50 m – 4 h 20 m | 0.86 – 0.56 |
| **MES-4a [M]** | **3 h 35 m 16 s** | 3 h 40 m – 6 h 20 m | **0.98 – 0.57** |

MES-4a [M]: brief 15:13:42 → push 20:32:27 = 5 h 18 m 45 s, minus Tim's pause 17:15:05 → 18:58:34 = 1 h 43 m 29 s ("pause" queued 17:12:13,
resumed "resume — apply the migration"), from the session transcript `~/.claude/projects/-Users-timchen/3ff2994c-….jsonl` lines 497, 2784–2802.

**Process floor (MES-4b):** as MES-4a — offline gate (likely twice), backup, apply, types, build, full gate, two surveys, smoke, live proofs as
several accounts → **≈ 1 h 05 m clean; ≈ 1 h 35 m with incidents**.

**Work:**

| part | low | high |
|---|---|---|
| orientation | 5 m | 5 m |
| database: 3 tables, 6 columns (one masked), 6 forms, 12 registry rows + sequences, generator rewrite, 11 widths, commit change, receipt functions, 5 new functions, 3 arms | 30 m | 60 m |
| fixtures: new 254 (~10 arms) + ~25 injections; fixture 100 / 111 / 195 / 253, search registry | 25 m | 55 m |
| pages: 1 new route, ~8 changed | 30 m | 65 m |
| messages en / zh | 5 m | 10 m |
| proof scripts and role table | 6 m | 12 m |
| static checks | 5 m | 10 m |
| docs | 7 m | 12 m |
| fold-in 1: smoke trail check tightened, both directions fault-injected | 15 m | 25 m |
| fold-in 2: MES-4a injections re-run on the final rebuild, per arm | 8 m | 15 m |
| **total** | **2 h 16 m** | **4 h 29 m** |

**Estimate: process floor ≈ 1 h 05 m – 1 h 35 m + work ≈ 2 h 15 m – 4 h 30 m = ≈ 3 h 20 m – 6 h 05 m of active time, plus any pause** — against
MES-0's 5 h 45 m – 10 h 45 m. The last five cuts landed at 0.61–1.07 of their low ends; the honest single number is ≈ 3 h 45 m. The largest
uncertainty is the document registry (fixture 100's anchors and the search checks move together). Moving Q14 down to the five named generators
saves ≈ 5 m; dropping the new contamination page (Q25) saves ≈ 15 m.

---

## §12 · Assertions measured and found false or imprecise

1. **MES-0 §8.2 / Q45: "construction on both batch tables (masked: column + grant + view)"** — `output_batches` is not masked (§1.1).
2. **MES-0 Q57 / CODE-WIDTH-4: "the three truncating generators"** — 42 generators share the width; 11 gapped ones have a lifetime cap (§1.3).
   MES-0 cites `docs/known-issues.md:3260`; the entry is now at `:3282`.
3. **MES-0 §1.3 row 14: "41 prefixes"** — 43 live [M] (MES-1 added DEV, MES-2 WB).
4. **`loss_categories` header: "RUNTIME CONFIG"** — not in `RUNTIME_CONFIG_TABLES` or `SEED_TABLES` (§1.8).
5. **The operation ↔ form tables read like a gate** — no function reads them (§1.6).
6. **`document_type_exceptions` header "36 行"** — the seed has 42 rows (`db/tables/document_type_exceptions.sql:53,55-96`).
7. **The brief: "the collected-dust form"** — in MES-0 it is a material form on an output leg, not an entry form (§1.10).

## §13 · Every open question, with a recommended answer and its evidence

### A · Scope

❓ **Q1 — Contents.** MES-0 said 4 tables / 3 pages.
➡️ **As §2: 3 new tables, columns on 6 tables, 6 forms, 12 registry rows, one new page and ~8 changed; the two fold-ins.** Left out: §2's list.

❓ **Q2 — One cut or two.** Estimate ≈ 3 h 20 m – 6 h 05 m, below MES-4a's measured 3 h 35 m + its own high end.
➡️ **One cut**, fold-ins included. Splitting numbering from fields adds a floor (≈ 1 h) and a second window.

### B · Cell construction

❓ **Q3 — The dictionary.** MES-0 Q45 named `wound`, `stacked`, `unknown`.
➡️ **`cell_constructions` with those three rows and a flag `is_determined` (true for wound and stacked); RUNTIME CONFIG; in the dictionary editor
under `module.processing.edit`** (routing is a processing fact).

❓ **Q4 — Which batches carry it, where it is entered, who sets it.**
➡️ **Batches whose material form has `implies_dismantling` = true (cells still inside); optional at receipt (a defaulted trailing parameter on both
receipt functions — NULL means "not recorded"); settable on the inbound and output batch pages by the batch module's edit code or
`action.processing_commit` (the station operator); refused on other forms (`CELL_CONSTRUCTION_NOT_APPLICABLE`).**

❓ **Q5 — Where it is required.** Spec §3.4: construction routes the separation machine.
➡️ **At the input of `electrode_separation` and `electrode_line`: every input batch must carry a determined construction (wound or stacked);
NULL or `unknown` → `INPUT_CELL_CONSTRUCTION_REQUIRED|<batch>`.** Driven by a flag `requires_cell_construction` on `operation_types`, seeded on
those two — not a code list in the function.

❓ **Q6 — Inheritance at commit.**
➡️ **An output batch whose form carries construction (cells, de-cased cells) inherits it when every input agrees on one value; otherwise it
stays NULL and is set on the batch page.**

❓ **Q7 — Changing it later.**
➡️ **Editable (change-logged, shown in the trail) until the batch has fed a committed run; then refused (`CELL_CONSTRUCTION_LOCKED|<run>`) — the
correction is a reversal of that run.**

❓ **Q8 — Construction ↔ machine.** Spec §3.4: separate machines for wound and stacked; live machine links 0 [M].
➡️ **Record only in MES-4b; the operator picks the machine. A construction column on `operation_type_equipment`, checked at commit, waits for the
first separation machine on the asset register.**

### C · Products and forms

❓ **Q9 — The six forms and their saleability.** `may_be_sold` is NOT NULL with no default (`material_forms.sql:49`); saleability is a legal fact
(PROC-BUILD-1 R5: loose cells, de-cased cells, anode sheets not saleable).
➡️ **Add `cathode_powder`, `anode_powder`, `copper_foil`, `aluminium_foil`, `collected_dust`, `harness_bms_busbar` (13 → 19), none implying
dismantling. Saleable: cathode powder, copper foil, aluminium foil, harness/BMS/busbar **yes**; anode powder and collected dust **no** until Tim
says otherwise** — the PROC-BUILD-1 rule: a hard block is the safe side of an unknown, and loosening is one row. **Tim to confirm or change each.**

❓ **Q10 — Operation ↔ form rows for the products.**
➡️ **Add output rows: electrode powder line → cathode powder, anode powder, copper foil, aluminium foil, collected dust; battery powder line →
collected dust; manual disassembly → harness/BMS/busbar. Information only, as today: not enforced at commit, and the output picker stays
unfiltered** (4 of 5 live materials have no form — a filter would hide them).

❓ **Q11 — Materials for the new forms.**
➡️ **None seeded; Tim creates them in the material editor.** No back-fill of forms on existing materials (MES-0 Q94).

### D · Numbering

❓ **Q12 — How the prefix is chosen.** Fixture 100 arm 6 forbids prefix literals in functions.
➡️ **`material_forms.output_document_key` → a `document_types` row (table `output_batches`, gapped, its own sequence, `/output`, `list_q`,
`module.output.view`). `generate_output_code` reads the batch's material form, takes that key (else `output_batch` = OUT), the prefix via
`document_type_prefix` and the sequence named in the row. Mapping as Q54: CPW · APW · CUF · ALF · SEP · DST · CEL (loose and de-cased cells) ·
CSG · STR · HBB · CTS · ANS; OUT for everything else. Changed only by migration on Tim's word** (document types have no write policy today).

❓ **Q13 — Width and reset of the new sequences.**
➡️ **Five digits from the first code (`CPW-2026-00001`), gapped, no yearly reset — the OUT behaviour** (MES-0 Q57).

❓ **Q14 — CODE-WIDTH-4 scope.** 42 sites; 11 gapped with a lifetime cap.
➡️ **All 11 gapped generators stop truncating: pad to 4, grow past 9,999 instead of cutting** (identical codes below 10,000, so fixture 100's shapes
hold). **The 31 gapless generators restart each year — leave them, recorded in the known issue.** The import ceiling
`IMPORT_CODE_NUMBER_TOO_HIGH` (fixture 124 H) stays.

❓ **Q15 — Existing codes and search.**
➡️ **No existing code changes. The OUT row stays registered, so every old `OUT-` code stays findable; each new row finds its own prefix.**

### E · Loss basis and electrolyte

❓ **Q16 — The basis column.**
➡️ **`processing_run_losses.basis` NOT NULL, `measured` | `derived`; `record_run_loss` writes `measured`; existing rows (0 on live [M]) become
`measured`; a derived row carries its share snapshot.**

❓ **Q17 — Where V10 lives, and on which operations.** MES-0 §5: "operation-type settings".
➡️ **`operation_types.electrolyte_share_pct` (% of the run's input mass, 0–100, empty = Not yet set) and `electrolyte_loss_applies`, seeded on
casing removal, electrode separation, electrode line and battery powder line** (cells opened or crushed). **Tim confirms the four.**

❓ **Q18 — The derived row.**
➡️ **`record_derived_electrolyte_loss(run)` under `action.processing_aftercare`: share × total input, category `electrolyte_evaporation` only
(`loss_categories.may_be_derived`), never at commit, never from the remainder; refuses with no share, on an operation it does not apply to, on a
state-changing run, and when named losses would exceed input − outputs.**

❓ **Q19 — Correcting a derived row.**
➡️ **A correction row with a reason, either re-derived (new share) or measured (typed kg) — the MES-4a chain, newest wins.**

❓ **Q20 — Closure.**
➡️ **Unchanged arithmetic; the balance panel shows the derived part; a new or corrected loss row reopens a closed run as today.**

### F · Contamination

❓ **Q21 — The model.**
➡️ **`contamination_streams` (cathode / anode; sheet form; foreign form; warning level V11) and append-only `contamination_checks` (run, stream,
sampled batch, kind sampled | not sampled, sample and foreign mass in grams, rate, sampled at, method, warning level copied, corrections with a
reason).** Flag above V11, never refuse.

❓ **Q22 — Attachment.**
➡️ **To the run and to the sampled output batch (a leg of that run in the stream's sheet form); shift read from the run, not stored.**

❓ **Q23 — A shift that was not sampled.**
➡️ **A `not_sampled` row with a required reason closes the reminder for that shift and stream** — the omission stays on record.

❓ **Q24 — The reminder.**
➡️ **`contamination_check_missing` under `module.processing.view`: one row per (process date, shift, stream) with a committed MES-4a-era run producing
that stream's sheet and no current check; `item_id` = the earliest such run.** 57 arms.

❓ **Q25 — Entry and pages.**
➡️ **Record on the run page (`action.processing_aftercare`); read on the run page, the output batch page and a new list `/operation/contamination`
(shifts × streams, rates against V11) for `module.processing.view` or `module.output.view`.**

❓ **Q26 — Sample instrument.**
➡️ **None in MES-4b** — sample balances are not in the device register and the rate prices nothing directly; the calibration gate stays on
weighings.

### G · Collected dust

❓ **Q27 — The collected-dust output.**
➡️ **An ordinary weighed output leg of form `collected_dust` with prefix DST, landing with no location like every processing output, distinct from
the loss `dust_spill`; no safety state seeded.**

### H · Governance

❓ **Q28 — Approvals, change log, trail, masking.**
➡️ **As §8: no approval; three tables change-logged, no exclusion; contamination checks in the run's and the output batch's trails; no masking; the
inbound column through grant + masked view in one migration.**

❓ **Q29 — Pending values.**
➡️ **V10 and V11 as §9, both under `module.processing.view`, each with its arm and docs row in the same commit.**

❓ **Q30 — Mirror classification.**
➡️ **Add `loss_categories`, `loss_metal_fates`, `cell_constructions` and `contamination_streams` to `RUNTIME_CONFIG_TABLES`** (closing the gap in
§1.8 in the commit that changes `loss_categories`).

### I · Fold-ins

❓ **Q31 — How the smoke knows an operation has changes.**
➡️ **Read the operation's change-log rows directly (a path independent of `record_trail`, which also draws the page — two sides that can move
apart); entries required when there are rows, empty allowed when there are none; refused or missing always fails. Fault-inject both directions**
(blank the trail on a changed operation → red; an unchanged operation empty → green).

❓ **Q32 — Re-running the MES-4a injections.**
➡️ **Run `db/scripts/2026-10-07-mes4a-fixture-injections.py` against the final MES-4b rebuild (fixture 253 changes again in this cut), report
per arm, and name the cases touching `correct_run_header`, `trail_refs` and `trail_ref_label` explicitly; add a case for any of them no
injection reaches.**

### J · Migration and fixtures

❓ **Q33 — Migration and window.**
➡️ **Accept §10: one migration; in the window no separation run can be recorded (construction unset everywhere) and new document-type labels show
as keys in old search; aim ≈ 1 h.**

❓ **Q34 — Fixture 195 E4.**
➡️ **Widen its regex to every output prefix, read from `document_types` where `table_name = 'output_batches'`, and fault-inject a `CEL-` code into
the snapshot to prove it bites.**

## §14 · Stop

No code edits and no migrations. Waiting on Tim's answers to Q1–Q34.
