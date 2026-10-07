# Pending values — the standards the plant still has to supply

**Created by MES-1 (2026-10-06, MES-0 §5 · Q92 · Q93; MES-1 Step 0 Q1 · Q2, Tim).**

This file and the page **Settings › Pending values** (`/settings/pending-values`) are two views of one list.
The page is read from the database view `pending_values` (`db/views/pending_values.sql`): **one arm per value**,
each arm carrying **its own permission code**, and a reader sees only the arms whose code they hold.
Each row on the page is one concrete thing still empty — which value, on which record, and where to fill it.
When the value is supplied, the row disappears by itself (the view stores nothing).

**Rule (Tim, Q2):** every later MES cut that introduces a pending value adds **its arm to `pending_values` and its row
to this file in the same commit.** A value listed here but with no arm, or an arm with no row here, is a defect.

The full catalogue of values the MES group will need (V1–V15 and the qualitative ones) is in
`docs/surveys/MES-0/README.md` §5. Only values whose cut has shipped appear below.

## Live arms

| # | value | where the page sends you | arm reads | permission | supplied by | trigger | added by |
|---|---|---|---|---|---|---|---|
| V5 | Heartbeat interval per gateway (seconds) | the gateway's device page (`/operation/devices/<id>`) | every gateway not retired whose `devices.heartbeat_interval_s` is empty | `module.processing.view` | integrator / device vendor | gateway commissioning | MES-1 |
| V6 | Shift start and end times (working hours) | `/settings/dictionaries` (Shifts — **moved here by MES-4a, Step 0 Q5**; it used to point at `/operation/handovers`) | every active shift whose `shifts.starts_at` and `ends_at` are both empty | `module.processing.view` | Tim | shift times decided | MES-1 (relabelled MES-4a) |
| V8 | Calibration reminder lead days (one number for every instrument) | `/operation/calibration` (the settings panel) | the single `ingest_settings` row while `calibration_lead_days` is empty | `module.processing.view` | Tim / the calibration body's recommended notice | before the first certificate nears its expiry | MES-2 |
| V33 | Capacity (and its unit) of each instrument in use | the instrument's device page (`/operation/devices/<id>`) | every scale, weighbridge, meter or inline instrument not retired and not `reserved` whose `devices.capacity` is empty | `module.processing.view` | instrument vendor / nameplate | instrument installation | MES-2 |
| V2 | Storage ceiling (t) per licence × NEA waste category | `/purchasing/licences` (the ceilings panel under each waste-disposal licence) | the waste-disposal licence in force today × each active NEA category with no `licence_storage_limits` row | `module.suppliers.view` | NEA licence conditions | NEA licence issued | MES-3a |
| V29 | The NEA waste category list, then each material's category | `/settings/dictionaries` (NEA waste categories), then the material editor | one row while `nea_waste_categories` has no active row; once one exists, each active material of a battery kind (`material_kinds.has_condition_axes`) with no category | `module.materials.view` | NEA licence categories | NEA licence issued | MES-3a |
| V3 | Dwell warning days per safety state | `/settings/dictionaries` (intake safety states) | each active safety state whose `dwell_warning_days` is empty | `module.materials.view` | Tim with the WSH officer; licence storage conditions | NEA licence issued, or the first swollen / leaking receipt | MES-3a |
| V4 | Whether a safety state requires quarantine | `/settings/dictionaries` (intake safety states) | each active safety state whose `requires_quarantine` is empty (seeded: swollen / leaking = yes, discharged = no) | `module.materials.view` | Tim / WSH officer | before the first receipt of damaged stock | MES-3a |
| V34 | A quarantine location | `/inventory/locations` (the location editor's "Quarantine location" box) | one row while any active safety state requires quarantine and no active location is marked quarantine | `module.inventory.view` | Tim / the warehouse | before the first swollen / leaking receipt | MES-3a |
| V30 | Marking text, packing instruction and label size per UN dangerous-goods number | `/settings/dictionaries` (UN dangerous-goods numbers) | each active `dangerous_goods_codes` row with any of `marking_text`, `packing_instruction`, `label_size` empty | `module.materials.view` | a DG-qualified forwarder | before the first export | MES-3b |
| V31 | HS code of each battery material | the material editor (`/materials/<id>/edit`) | each live material of a battery kind (`material_kinds.has_condition_axes`) with `hs_code` empty | `module.materials.view` | the customs broker | before the first export | MES-3b |
| V35 | UN dangerous-goods number of each battery material | the material editor (`/materials/<id>/edit`) | each live material of a battery kind with `dg_code` empty | `module.materials.view` | the forwarder, with Tim | before the first export or the first dangerous-goods shipment | MES-3b |
| V1 | Material-balance tolerance (% of input) per transforming operation | the operation's page (`/operation/operation-types/<code>`) | each active operation whose kind produces outputs and whose `operation_types.balance_tolerance_pct` is empty (state-changing operations — deep discharge — have no balance and no row) | `module.processing.view` | Tim with the process engineer | before balances are closed routinely | MES-4a |
| V36 | Range (lower / upper bound) of a process parameter or indicator | the operation's page (`/operation/operation-types/<code>`, Parameters and indicators) | each active `operation_type_fields` row with `has_range` = true and both `range_min` and `range_max` empty (none of the 27 seeded fields declares a range, so the arm is empty until someone says a field has one) | `module.processing.view` | equipment vendor / process engineer | equipment commissioning | MES-4a |
| V10 | Electrolyte share (% of the step's input) of each operation whose equipment releases electrolyte | the operation's page (`/operation/operation-types/<code>`, Electrolyte) | each active operation with `operation_types.electrolyte_loss_applies` ticked ("Electrolyte evaporates in this step") and `electrolyte_share_pct` empty — **seeded unticked everywhere, so the arm is empty until Tim ticks an operation himself** | `module.processing.view` | the cell supplier's datasheet / the process engineer | before the first electrode-separation batch | MES-4b |
| V11 | Cross-contamination warning line (% foreign material) per stream — cathode sheet with anode in it, anode sheet with cathode in it | `/settings/dictionaries` (Contamination streams) | each active `contamination_streams` row whose `warning_pct` is empty (both seeded empty) | `module.processing.view` | Tim / the first black-mass offtake contract's specification | before the first offtake contract | MES-4b |

**What "Not yet set" means for V5.** A gateway with no heartbeat interval cannot be judged silent: its status reads
**"Not yet set — silence cannot be judged"**, it raises no `gateway_silent` reminder, and no outage is recorded for it.
Nothing guesses an interval.

**What V6 holds back.** `ingest_transmission_anomalies` lists refused calls, overflow buckets, sequence reuse and
clock-ahead messages today. The **out-of-hours** arm (transmissions outside working hours) is not built until V6 is supplied — there is no
definition of "working hours" to compare against, and inventing one would flag honest night shifts.

**What V1 holds back (MES-4a, Step 0 Q18 · Q19).** A run's material balance (input = weighed outputs + named losses + remainder) can always be
closed. The tolerance only decides whether the close needs a **written explanation**: within it, the explanation is optional; outside it — or with
**no tolerance set** — `close_run_balance` refuses without one (`RUN_BALANCE_EXPLANATION_REQUIRED`). So an empty V1 makes every close of that
operation's runs ask for a sentence. The tolerance in force is copied into each closure row, so changing V1 later never rewrites an old closure.
Nothing guesses a tolerance.

**What V36 holds back (MES-4a, Step 0 Q12).** A value outside its field's range is **recorded and flagged**, never refused. A field that has a
range but no bounds yet is recorded with no flag at all (`out_of_range` is NULL — "could not be judged", not "within range"). The bounds in force
are copied onto each recorded value (`range_min_at` / `range_max_at`), so a later range change does not re-judge old values.

**What V6 holds back (relabelled by MES-4a, Step 0 Q5).** Since MES-4a every new run states its shift, and the shift's hours are edited in the
Shifts dictionary (`/settings/dictionaries`, a time field). Until V6 is supplied a shift has no hours, so nothing compares a run's start and end
with its shift; the out-of-hours transmission arm below stays unbuilt for the same reason.

**What V8 holds back (MES-2).** Each calibration record carries its certificate's own **valid-until** (required), so
"is this instrument in calibration today" never waits on V8. What V8 adds is the **warning before** expiry: with it empty,
`instrument_calibration_now.approaching` is never true and the `instrument_calibration_approaching` reminder has no rows; the
`instrument_calibration_due` reminder (already expired, failed, or never calibrated, for an instrument in use) works without it.
Nothing guesses a lead time.

**What V33 holds back (MES-2, Step 0 Q11 · V33).** A weighing confirmed against an instrument with a capacity is refused above it
(`WEIGHING_ABOVE_CAPACITY`, units kg / t / g; no unit = kg). An instrument with **no** capacity cannot be checked, so a reading
from it is accepted as given — and this row stays on the page until the nameplate figure is entered. Nothing guesses a capacity.

**What V2 and V29 hold back (MES-3a, Step 0 Q4–Q12).** Every receipt (both receipt functions) and every manual output batch writes
one append-only `receipt_ceiling_checks` row. With no category list (V29) every one of them records **`category_not_set`**; with a
category but no ceiling for it under the licence in force (V2) it records **`ceiling_not_set`**; with no waste-disposal licence in force
that day, **`licence_not_in_force`**. In all three the receipt is **accepted** — a ceiling nobody has supplied is not a ceiling of zero.
Only a ceiling that **is** set refuses (`STORAGE_CEILING_EXCEEDED`). The licence's own approved storage limit (500 t on live) is kept as the
**total across all NEA categories** and checks only categorised stock — so until V29 is supplied it constrains nothing. Nothing guesses a
category or a ceiling.

**What V3 holds back (MES-3a, Q14 · Q15).** The clock for each safety state runs from when it was recorded, in Singapore calendar days,
and every batch page shows it ("recorded … · N days on site"). With no dwell period the line reads **"warning period: Not yet set"** and
the `safety_state_dwell` reminder has no rows for that state. Nothing guesses a period.

**What V4 holds back (MES-3a, Q18).** A state whose `requires_quarantine` is empty is **treated as not requiring quarantine** (the
damaged, water-exposed and charged states today). Swollen / leaking is seeded **yes** (MES-0 Q34) and discharged **no**.

**What V34 holds back (MES-3a, Q19 · Q21).** While swollen / leaking requires quarantine and no active location is marked as
quarantine, **every swollen or leaking delivery is refused** (`QUARANTINE_LOCATION_REQUIRED`), and a batch recorded swollen or leaking
after it was placed can only move into a quarantine location. Marking one location in the location editor clears this row.

**What V30 holds back (MES-3b, Step 0 Q11 · Q14).** The four UN numbers (UN3480, UN3481, UN3090, UN3091, class 9, with their UN proper
shipping names) are seeded; what the forwarder requires on the package — the marking text, the packing instruction and the label size —
is not. Until it is supplied a batch label prints the UN number, the class and the proper shipping name only, marked "data, not a
regulated package mark". The system never prints a regulated mark (the class-9 hazard label or the lithium battery mark) on its own.

**What V31 holds back (MES-3b, Q17).** A material's HS code (6–12 digits, dots allowed — a shape check, not a standard) prints on the
material page, the material list and export, the shipment page and the delivery note. Until it is supplied those places carry none. It is
not printed on labels and not on the sales invoice in this cut.

**What V35 holds back (MES-3b, Q12 · Q15).** The UN number cannot be worked out from a material's chemistry or form (nothing records
lithium-ion against lithium-metal, or "contained in equipment"), so a person chooses it on each material. Until then a battery material's
labels, its delivery-note lines and the shipping queue say **"DG code not set"**. Nothing is refused — there is no export flag yet to key
a refusal on; the refusal arrives with the first-export / Basel item.

**What V10 holds back (MES-4b, Step 0 Q17–Q20 · Q29, with Tim's change to Q17).** Whether a step releases electrolyte is a plant fact, so it is a tick
on the operation (**"Electrolyte evaporates in this step"**, editable on the operation page under `module.processing.edit`), seeded **unticked
everywhere** — Tim ticks it himself. On a ticked operation an electrolyte-evaporation loss can be **calculated** instead of weighed:
`record_derived_electrolyte_loss` writes share × total input ÷ 100 (rounded to 3 decimals) as a loss row marked **derived**, carrying the share
it used. With the share empty that refuses (`ELECTROLYTE_SHARE_NOT_SET`) and the loss can still be **measured** and recorded as before. A derived
loss can be corrected to a measured one at any time; the correction reopens a closed balance exactly like any other loss correction. Nothing
guesses a share. The evaporated electrolyte is carried by the extraction airflow to the back-end environmental equipment for treatment — it
stays a named loss (`electrolyte_evaporation`); the compressor is equipment, not an operation, and is not linked to runs.

**What V11 holds back (MES-4b, Step 0 Q21–Q24 · Q29).** Contamination checks are recorded per run and stream either way — a sampled row (sample mass,
foreign mass, the rate computed by the database) or a `not_sampled` row with a reason. The warning line in force is **copied onto each check**,
so changing V11 later never re-judges an old check. With it empty, `above_warning` is NULL ("could not be judged", not "within the line"),
and the per-shift grid shows the rate with no flag. The reminder `contamination_check_missing` (a shift whose committed sheet-producing runs
have no check for a stream) does **not** wait on V11.
