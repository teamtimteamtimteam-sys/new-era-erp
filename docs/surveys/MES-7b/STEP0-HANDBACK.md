# MES-7b Step 0 — hand-back (2026-10-16), with the MES-7a-2 close-out

**STOP GATE.** No code edit, no migration, no live write. The only writes are docs: the close-out (`671fb4c3`, "MES-7a-2 close-out") and this file
with the read-only query file beside it (`live-readings.sql`). Waiting on Tim's answers to Q1–Q28 (§12).

**Opening check.** First command **2026-10-16 13:31:34 CST**. Tree clean. `HEAD` = `origin/main` = `git ls-remote origin main` =
`c5d4cf674bd39a91b261a8d4c870f5bce98d524d`; after the close-out `671fb4c3c817b81f159cde0651c4f7148f0ce624` (fresh clone, no `.env.local`:
`CI_OWN_EXIT=0`, `X_OWN_EXIT=0`). Files staged by explicit path only.

**Live readings (measured, read-only).** `live-readings.sql` at **13:48:47 CST** (re-run after two column-name fixes in my own query file; the final run
`READ_OWN_EXIT=0`), as `postgres` (`rolbypassrls = true`) over direct psql to the pooler, inside `BEGIN READ ONLY … ROLLBACK`, base tables and the
catalog only (no gated view — `postgres` carries no JWT); close-out readings at 13:39:55 (`closeout-readings.sql`):

| Reading | Value |
|---|---|
| Safety codes | `module.safety.*` **0**; catalogue **79** (module 32 · action 36 · data 11) |
| `module.processing.view` holders | admin · auditor · cco · cfo · cto · finance · gm · operations · warehouse (cfo already among them) |
| `module.processing.edit` · `module.quality.edit` · `action.processing_aftercare` | admin · cco · cto · operations · admin · cco · cto · admin · warehouse |
| `data.view_health` holders | admin · cco · cfo · finance · hr — **not cto, not warehouse** |
| Employees | 22 rows, 7 not deleted |
| Holiday calendar | 2026: 14 active · **2027: 12 active** |
| Ingestion | class `safety_alarm`: target "Incidents (MES-7b)", `transform_function` NULL, `manual_entry_code` NULL, `creates_draft` false, active; devices: gateway 2 · scale 2 (no `alarm_panel`); inbox rows of `safety_alarm` 0 |
| Run exception events | types `unplanned_stop` · `equipment_alarm` · `safety_alarm` (all active); events **0** |
| NCRs | **0** |
| Downtime · tasks · locations | 1 · 20 · 4 (0 quarantine) |
| Safety states | charged_not_discharged · discharged_verified · damaged_deformed · water_exposed · swollen_leaking |
| Where a batch was | movements with a location **7 / 107**; runs with a machine and a start **0 / 14** |
| Document types | 59 (no INC, no INS) |
| Licences (`company_compliance`) | 1 |
| Reminder / pending arms | `operations_now` 66 · `pending_values` 24 (23 values) |
| Standing state | approvals ON (finance / cfo / 1,000) · 7 accounts, 0 disabled, one role each (admin@ admin · chooer@ finance · fusheng@ warehouse · phua@ cto · sandra@ cco · tim@ cfo · vince@ gm) · role codes admin 79 · auditor 20 · cco 46 · cfo 33 · cto 37 · finance 42 · gm 21 · hr 8 · operations 15 · procurement 16 · sales 17 · warehouse 29 · `action.ncr_decide` admin, cco, cto · `action.issue_coa` admin, cco · `require_calibrated_since` NULL · throwaways 0 · pending CLM-2026-0004 only · COD-2026-0001 / -0002 recorded sha `ba299a4f…f42101` / `717661f6…13a4f9`, objects 34,701 / 34,746 bytes · AP 422,188.32 / 381,604.42 / **0.00** · AR 57,545.87 / 43,002.12 / **0.00** · 1200 and 1220 **0.00, reconciled** · 299 tables |
| F12 — the live `spare_part` note | still "机器的备件。【自成一类】它挂在一台机器上、有关键度,而且【不按批次追溯】……(PROC-0b N3,Tim 裁定)。" |

**How the facts were gathered.** Four read-only sub-agents (none connected to a database, ran a build or imported a script): `docs/known-issues.md` in
full (10,891 lines, last line read 10891); `docs/forward-queue.md` in full (7,550 lines) plus every MES Step 0 and hand-back from MES-1 to MES-6b-2;
the MES-7b code map (ingestion, NCRs, run events, downtime, safety states / hold / quarantine, tasks, working days, arms, health masking, codes,
document types, trail, change-log exclusions, buckets, pages, the two enum parsers, `material_kinds`); and the active run times of MES-7a-1 and
MES-7a-2 from the session transcripts (`measure_7a.py`, the `measure_6b.py` method, kept in the job scratch directory). I read in full: AGENTS.md,
the specification PDF, MES-0 README, the MES-7a Step 0, the MES-7a-1 and MES-7a-2 hand-backs, `docs/mes-pending-values.md`, `docs/role-matrix.md`,
fixture 266. Load-bearing claims re-read at file:line today: `nonconformance_reports.sql:11-12,38,59-61,89` · `open_ncr.sql:43-51` ·
`fixture 263:247-248` · `ingest_data_classes.sql:50` · `ingest_transform_row.sql:36-43` · `submit_manual_capture.sql:33-41` ·
`capture_confirm_internal.sql:55-56` · `processing_run_events.sql:13-47` · `processing_event_types.sql:22-25` · `inbound_safety_states.sql:49-55` ·
`tasks.sql:17-37,115-120` · `shift_handovers.sql:4` · `shift_handover_equipment_refs.sql:8-17` · `handover_item_types.sql:24` ·
`is_business_day.sql:6-17` · `operations_now.sql:226-235,1059` · `pending_values.sql:75-82,340` · `change_log_mask_rules.sql:66-71` ·
`change_log_exclusions.sql:20-27` · `check-enum-mirrors.mjs:58-66` · `check-i18n.mjs:188-193,710` · `inventory_movements.sql:22-32` ·
`material_kinds.sql:81-84` · `check_mirrors.py:225,245` · `app/operation/balance/page.tsx:106`.

Tags: **[M]** measured · **[I]** inferred from code reading · **[Q]** quoted from an earlier record · **[S]** specification · **[R]** a Tim ruling on record.

---

## §0 · The MES-7a-2 close-out (step 1)

All of it is in `MES-7a-2-CLOSEOUT.md` beside this file; summary:

1. **Broken window closed** (`docs/forward-queue.md` item 52): start 12:30:24 · end lower bound 13:24:18 (push of `c5d4cf67`, reflog; `afd9977b` went in
   the same push) · end upper bound 13:31:34 (this session's first command, holding Tim's "deployed" — a relay). **At least 53 min 54 s, at most
   1 h 01 min 10 s.** In the window: 0 part issues, 0 maintenance movements, 0 `maintenance_part` entries, 0 6800 lines, 0 spare-part materials or
   batches, 0 new movements; change log only MES-7a-2's own throwaways, INSERT = DELETE, 0 rows after the push.
2. **Tim's rulings recorded:** maintenance void and fixture 266's VOID guard accepted as built; 维修保养费 stands; **F12** (live spare-part note) and
   **F13** (the two under-counting checks) are fold-ins for the next build cut (forward-queue item 52 and MES group row 12; known-issues entries annotated).
3. **a — fixture list:** all 18 items covered (table with file:line in the close-out §2 a); re-run today on a fresh local rebuild: 266 / 263 / 257
   green, the cut's injection script `INJECTIONS_OWN_EXIT=0` (34 + 1 cells, 0 wrong), `check-enum-mirrors` and `check-i18n` green. Weaker spots recorded:
   **W5** the two type-list parsers (= F13), **W6** "voided" has no subject (accepted).
4. **b — usability:** deployed app, clones of admin · cco · finance · warehouse **and cfo** (the four hold `module.inventory.edit`, so "disabled to
   others" needed a role without it): 4 pages × 5 = **20 fetches, all 200**. Parts panel drawn for all; "Issue spare parts" pressable for the four,
   disabled naming `module.inventory.edit` for cfo; roll-forward column "Issued to maintenance (net of returns)" for all; trial balance lists 6800 for
   all but warehouse (refused finance); V21 has no live row (no spare part on live). Local rebuild with my own data: **25 fetches, all 200** — 2 Return
   buttons (cfo: 3 controls disabled naming the code), value column only for price viewers, V21 rows for both received spare parts.
   **Found, registered, not caused by MES-7a-2, not stopping step 2 (my judgement):** ① **no chart-of-accounts page exists and no page says which
   account is a system account** (`MES7A2CO-NO-CHART-OF-ACCOUNTS-PAGE`) — the brief's "chart of accounts shows 6800 as a system account" has no subject;
   ② **with no processing run, `/operation/balance` hides the whole stock roll-forward** (`page.tsx:106`, from MES-5b-1) — live has runs so the
   deployed page is fine (`MES7A2CO-ROLLFORWARD-HIDDEN-WITHOUT-RUNS`). Q25 · Q26.
5. **c** — the three entries quoted with lines (`known-issues.md:10869-10879`, `:10845-10850`, `:10852-10856`). **d** — 18 decisions listed.

So step 2 went ahead.

## §1 · What grilling changed in MES-7b's scope

1. **Size → two cuts** [M + I]. MES-0 sized MES-7b at 7 tables / 5 pages, **8 h 05 – 15 h 15**, the largest row of the plan after MES-4a. Drawn out
   (§2), it is two proof shapes: an **incident register** carrying a legal deadline, health masking and batch links; and **inspections + environmental
   monitoring** (templates, runs, findings, lab results). Together ≈ 4 h 25 – 6 h 35 calibrated, above every measured MES cut (largest 3 h 55). Q1.
2. **The NCR source reserved "for MES-7b" means something else in the mirror** [M]. `nonconformance_reports.sql:11-12,89` and `open_ncr.sql:48` reserve
   `inspection` for "**来料检验**" (incoming inspection of a receipt — a quality act); MES-0 function 23 is a **safety** inspection of the plant (no batch
   on it). They are different things sharing a word. Q15.
3. **"Findings raised as tasks" (MES-0 Q72) has no mechanism** [M]. `tasks` carries no source link (`tasks.sql:17-37`), its INSERT policy requires
   `owner_id = current_user_employee()` (`:115-120`), and nothing in the database writes a task (0 `INSERT INTO tasks` in `db/functions`). Q14.
4. **The alarm transform cannot be built** [R + M]. The standing rule forbids a device transform on an invented payload format; no alarm panel exists
   (devices: 2 gateways, 2 scales) and no vendor has supplied a format. The `safety_alarm` class stays `transform_function` NULL (rows would wait
   `awaiting_transform`, `ingest_transform_row.sql:36-43`); incidents are entered by hand, with a reserved `device` source like downtime. Q5.
5. **Safety editors cannot read injury details** [M]. MES-0 Q90 gives `module.safety.edit` to cto · warehouse · admin; injury details sit behind
   `data.view_health`, which **cto and warehouse do not hold**. The person who records an injury would see "Restricted" right after saving. Q6.
6. **The NEA deadline rule collides with "no invented number"** [R]. MES-0 Q74 pre-fills "2 working days" from the repo's record of the duty
   (`docs/forward-queue.md:2373`); the brief's standing rule says every limit is a "Not yet set" value. Q11.
7. **No working-day arithmetic exists** [M]. `is_business_day()` answers one date; there is no "N working days after" function. Both 2026 and 2027
   calendars are on live. Q10.
8. **Batch suggestions will be empty on today's data** [M]. "Suggested from the location and machine at that time" (MES-0 Q73) reads movement
   locations (7 / 107 carry one) and runs on a machine (0 / 14 carry a machine and times). The mechanism can be built and fixtured; live suggests
   nothing until the floor records locations and machines. Q7.
9. **The handover register was told to wait for this cut** [Q]. `forward-queue.md:2373` / `shift_handovers.sql:4`: once the WSH register exists,
   handovers cite incidents "and not before". Q12.
10. **Two fold-ins confirmed by Tim plus one proposed** [R + M]: F12 · F13 (Tim), F14 the roll-forward empty state (close-out finding, proposed).
    Q23–Q25.

## §2 · (a) What MES-7b is, and its exact contents

**MES-0 §8.2 row MES-7b** [Q, `docs/surveys/MES-0/README.md:706`]: functions **23 safety inspections · 24 thermal runaway / emissions**; tables
`inspection_templates`, `inspection_template_items`, `inspection_runs`, `inspection_results`, `incidents`, `incident_batches`,
`environmental_monitoring_results`; "alarm transform; report-deadline arm"; one migration; 7 tables / 5 pages; extras "working-day deadline + health
masking: 1–2 h"; estimate **8 h 05 – 15 h 15**. Rulings on record [R, MES-0 Q1–Q96 accepted, README:1141]:
- **Q72** "Templates with items (V18), runs by an inspector with pass/fail/N-A per item, findings raised as tasks."
- **Q73** "One incident per alarm event; affected batches suggested from the location and machine at that time and confirmed by a person; marking is a
  link (and optionally a hold), never a safety state" (Tim's ruling, `inbound_safety_states.sql:49-55`).
- **Q74** "A setting pre-filled '2 working days', citing `docs/forward-queue.md:1686` (now `:2373`), flagged 'to be confirmed against the licence' (V19)."
- **Q75** "Periodic results entered from an accredited lab with limits V20; an exceedance raises an incident. Continuous sensors arrive only as alarms."
- **Q76** "New `module.safety.view` / `module.safety.edit`; injury details behind `data.view_health`." **Q90** view → every role holding
  `module.processing.view`, plus cfo; edit → cto, warehouse, admin; every code also to admin. **Q91** injury details by `data.view_health`.
- **Q53** prefixes `INC-`, `INS-`. **Q89 / §4.1** inspections and incidents need no approval (records of events). **§4.3** trail subjects
  `inspection_run`, `incident`. **§4.2** masking: incident injury details → `code_or_self:data.view_health:employee_id`.
- **V18** inspection frequency and items per checklist · **V19** incident written-report deadline · **V20** emission limits per monitored parameter.
- **§2 / §9 [S]**: deep discharge temperature and gas (HF, electrolyte vapour), cutting-station temperature and smoke, dust concentration — site layer,
  **exceptions to ERP**; NEA duty "立即通报 … 两个工作日内提交书面报告" (`forward-queue.md:2373`); environmental monitoring when the line runs (`:2380`).
- Earlier Step 0s left to MES-7b [Q]: the alarm transform (MES-1 Step 0:189-190; MES-2 Step 0:166,172); incidents and holds from alarms (MES-3a
  Step 0:140-141); dust-concentration alarms and combustible-dust handling (MES-4b Step 0:92-95,165); thermal-runaway / HF alarms, incidents from
  alarms, emissions (MES-5a Step 0:225-227); NCRs from inspections (MES-6b Step 0:127,331-337; `open_ncr.sql:48`).

**Proposed contents, by recommended cut (Q1):**

**MES-7b-1 · Incidents (+ F12, F13, F14 if Q25)**
- **Tables:** `incident_kinds` (dictionary, RUNTIME CONFIG: code, names, sort, active; seeded per Q4, no "other"); `incidents` (`INC-` gapless yearly:
  kind, occurred at, location, machine, what happened, immediate action, responsible person, NEA-reportable yes / no, source `manual` · `device`
  (reserved), injured person and injury details — masked, Q6); `incident_updates` (append-only rows: NEA notified · written report submitted ·
  closed · correction with a reason); `incident_batches` (links, suggested or picked, confirmed by a person); `safety_settings` (one row: V19).
- **Functions:** `record_incident`, `record_incident_update` (notify / report / close / correct, each with named refusals), `suggest_incident_batches`
  (location as of the time from movements, runs on the machine spanning the time), `link_incident_batch` / `unlink_incident_batch` (with a reason),
  `business_days_after(date, n)` (working days on `is_business_day`), `incident_nea_status` (deadline per incident). Direct writes refused by name.
- **Codes:** `module.safety.view` / `.edit` (Q2), nav module "Safety".
- **Pages:** `/safety/incidents` (list + record form), `/safety/incidents/[id]` (detail: batches with suggestions, NEA status, updates, trail);
  `/settings/dictionaries` gains "Incident kinds"; the V19 panel on the incidents page.
- **Arms:** `incident_nea_notify_due` and `incident_report_due` (`operations_now`, `module.safety.view`); pending value **V19**.
- **Fold-ins:** F12 (Q23), F13 (Q24), F14 if Q25.

**MES-7b-2 · Inspections and environmental monitoring**
- **Tables:** `inspection_templates` (`code`, name, area, frequency in days — V18, active), `inspection_template_items` (ordered checks);
  `inspection_runs` (`INS-` gapless yearly: template, the items **copied** at the run, inspector, when, where); `inspection_results` (per item
  pass · fail · n/a, a note required on fail); `inspection_findings` (a failed item's finding: corrective action, owner, closure row);
  `environmental_parameters` (dictionary: parameter, unit, limit — V20, none seeded); `environmental_results` (parameter, sample point, sampled on,
  laboratory, report reference, value, the limit **copied**, exceeds yes / no / not judged; append-only with corrections).
- **Functions:** template save, `record_inspection_run` (results + findings in one submit), `close_inspection_finding`, `record_environmental_result`
  (an exceedance opens an incident of kind `emission_exceedance` in the same transaction, Q75); the NCR source `inspection` per Q15.
- **Pages:** `/safety/inspections` (templates and runs), `/safety/inspections/templates/[id]`, `/safety/inspections/[id]` (a run with findings),
  `/safety/environment` (parameters and results).
- **Arms:** `inspection_due` (a template with a frequency whose last run is older — only when V18 is set), `inspection_finding_open`; pending values
  **V18**, **V20**.

**Left to later cuts or registered** [Q / I]: the alarm transform and any controller safety summary (no payload format — the standing rule; register
D8 as "waiting on the alarm panel's format"); continuous emission sensors (Q75: alarms only); the NEA return and compliance pack (MES-8b, V26);
incident ↔ downtime / run-event auto-pairing (no rule for "the same event", like `MES7A1-RUN-EVENT-DOWNTIME-PAIRING`); a chart-of-accounts page (Q26);
fire-suppression / gas-detector equipment registers (site layer, specification §3.1, §3.3 — "outside the scope of this document").

## §3 · (b) Each function: recorded, entered, shown, and its relation to today's layers

| | Incidents (24) | Safety inspections (23) | Environmental monitoring (24) |
|---|---|---|---|
| **Recorded** | one `incidents` row per event (kind, time, place, machine, account, action, responsible, reportable); later facts as `incident_updates` rows; batches as links; injury details masked | a run of a template: each item pass / fail / n/a (+ note), findings with corrective action and closure | a lab result per parameter and sampling, the limit in force copied, exceedance flag |
| **Entered** | `/safety/incidents` (`module.safety.edit`, Q2 / Q28) — by hand; a `device` source is reserved | `/safety/inspections` (`module.safety.edit`) | `/safety/environment` (`module.safety.edit`) |
| **Shows** | incident list and page with NEA status; two reminder arms; the linked batches' pages (a "Linked incidents" line, owner of the batch page's view code); the machine page (incidents citing it) | runs, open findings arm, due arm (when V18 is set) | results with "exceeds / within / not judged", and the incident it opened |
| **Run exception events** (`processing_run_events`, 0 live; type `safety_alarm` exists) | an incident **may cite** a run event (optional link); a `safety_alarm` run event is a run-level fact and does **not** create an incident by itself; neither is counted twice (Q9) | — | — |
| **Downtime** (`equipment_downtime`) | an incident may cite the downtime it caused (same machine); MTBF counts downtime only, unchanged (Q9) | an inspection may name a machine; no downtime is opened by it | — |
| **Safety states** (`inbound_safety_states`) | **never set or changed** by an incident (Tim's ruling, `:49-55`); the batch link is the mark | — | — |
| **NCRs / quality hold** (0 live) | optional: a quality editor may open an NCR on a linked batch from the incident (Q8) | a fail on a batch-related item may open an NCR with source `inspection` (Q15) | — |
| **Contamination checks** (`contamination_checks`) | none — those are quality samples of streams; a dust-concentration **alarm** is an incident kind | — | — |
| **Devices / ingestion** (`safety_alarm` class, no transform; no `alarm_panel` device) | unchanged; source `device` reserved; the class keeps waiting (Q5) | — | lab results are typed, not ingested (no `inline_quality` transform either) |
| **Hand-overs** (`shift_handovers`) | a handover may cite incidents, by a reference table like `shift_handover_equipment_refs` (Q12) | — | — |

## §4 · (c) Effect on existing pages, functions and fixtures

- **Functions changed:** `operations_now` (+2 arms in 7b-1, +2 in 7b-2), `pending_values` (+V19; +V18, +V20), `trail_subjects` /
  `trail_subject_members` / `trail_prelog_sources` (subjects `incident`, `inspection_run`), `change_log_mask_rules` (injury columns),
  `document_types` (INC, INS → 61), `open_ncr` (7b-2, Q15: `inspection` accepted with a finding cited; `nonconformance_reports` CHECK and comments
  re-worded), `permissions` / `role_permissions` (two codes, Q2), `check-enum-mirrors.mjs` and `check-i18n.mjs` (F13), `material_kinds` live row (F12),
  `app/operation/balance/page.tsx:106` (F14 if Q25).
- **Pages:** new `/safety/*` (2 in 7b-1, 4 in 7b-2), `/settings/dictionaries` (incident kinds; environmental parameters), `/settings/pending-values`
  (V18–V20), the batch pages and the machine page (a linked-incidents line), `/operation/handovers/[id]` (Q12), `/quality/ncr/new` (7b-2, source),
  `lib/modules.ts` (a Safety module).
- **Fixtures:** new **267** (7b-1: KIND · RECORD · REFUSE · UPDATE · DIRECT · MASK (health, self) · LINK (suggestion by location as of the time and by
  machine run, confirm, unlink with reason, never a safety state) · NEA (working days across a weekend and a public holiday, calendar missing → not
  computable, both arms) · V19 · TRAIL) and **268** (7b-2). Changed without weakening: **263** (`inspection` stops being reserved — `:247-248` become an
  accepted-with-finding arm and a refused-without-finding arm), **100 / 101 / 254** (document-type counts), **234 / 235** (new tables bound, exclusions
  stay 8), **257** FCHECK (new codes declare their views), **111** if it pins arm lists, `check-search-registry` `EXPECTED_ROWS` 59 → 61,
  `check-document-registry` `EXPECTED_TABLES` / `EXPECTED_CODE_TABLES`, `check-reminder-arms`, `check-trail-wording` (㉜ in 7b-1, ㉝ in 7b-2).
  Every new arm fault-injected; the injection run repeated on a fresh rebuild after the last database edit.

## §5 · (d) Approvals, trails, change log, masking

- **Approvals:** none new (MES-0 §4.1 [R]: inspections and incidents are records of events; Q89). Approvals stay ON, finance / cfo / 1,000. Q18.
- **Trails:** subjects `incident` (home of `incidents`, `incident_updates`, `incident_batches`; also shown under each linked batch) and `inspection_run`
  (runs, results, findings); templates and environmental parameters under a dictionary trail; environmental results under a `safety_environment`
  list trail (they have no page of their own). Wording arms ㉜ (7b-1) and ㉝ (7b-2), each with a drift and a part fault. Q19.
- **Change log:** every new table bound (`gen_change_log_bindings.py --only`); exclusions stay 8.
- **Masking:** injured employee, injury nature, treatment, days lost → column-list grant + `incidents_masked` + `change_log_mask_rules`
  `code_or_self:data.view_health:injured_employee_id` (one migration, the three-changes rule); a non-employee's name and details → `data.view_health`
  only. No money anywhere in MES-7b. Q6.

## §6 · (e) "Not yet set" values MES-7b adds

| # | value | lives on | page | arm reads | permission | supplied by | when |
|---|---|---|---|---|---|---|---|
| V19 | Written-report deadline after an NEA-reportable incident, in working days | `safety_settings.nea_report_working_days` (+ `confirmed_at`) | `/safety/incidents` (settings panel) | the one row while the value is empty **or not confirmed against the licence** (Q11) | `module.safety.view` | Tim, confirmed against the NEA licence conditions | NEA licence issued (7b-1) |
| V18 | Inspection frequency (days) per template, and the template's items | `inspection_templates.frequency_days`; items are template data | `/safety/inspections/templates/[id]` | one row while no active template exists (the V29 precedent); then each active template with frequency empty | `module.safety.view` | a qualified safety engineering firm / the WSH officer | before line start (7b-2) |
| V20 | Emission limit per monitored parameter | `environmental_parameters.limit_value` (+ basis max / min) | `/safety/environment` | one row while no parameter exists; then each active parameter with no limit | `module.safety.view` | the NEA licence | NEA licence issued (7b-2) |

No other number is introduced: no "incident open too long", no inspection pass rate, no finding due date default, no batch-suggestion time window
beyond the incident's own time (Q7).

## §7 · (f) F12 and F13 — today's code and data, effects, fixtures

**F12 — `MES7A2-SPARE-PART-NOTE-LIVE-STALE`**
- **Today:** mirror `material_kinds.sql:81-84` carries the new note ("received as lots so stock and cost are counted … issued against a maintenance
  record … no per-piece traceability"); live still says "不按批次追溯" (read 13:39:55). `material_kinds` is RUNTIME CONFIG (`check_mirrors.py:225,245`),
  so no gate compares the row.
- **Change:** the next migration (7b-1) `UPDATE public.material_kinds SET notes = <the mirror's text> WHERE code = 'spare_part' AND notes <> <it>` —
  idempotent, change-logged as an ordinary update; the in-transaction proof reads it back equal to the mirror. RUNTIME CONFIG rule: the commit states
  that the bootstrap default is still correct (it is the text Tim ruled in Q2).
- **Effect:** none on behaviour (a note). **Fixture:** 266 REG already pins the mirror's wording on a rebuild; the live half is the migration's own
  proof (a rebuild cannot see live's row) — the same shape as live fixture 265 if Tim wants it repeatable (Q23).

**F13 — `MES7A2-ENUM-PARSERS-STOP-AT-A-COMMENT`**
- **Today:** `check-enum-mirrors.mjs:58-66` captures `([^)]+)` then strips `--` comments — a `)` inside a comment still truncates the list;
  `check-i18n.mjs:188-193` captures the same way and **does not strip comments** — a quoted word in a comment is counted as a value. The one comment
  still inside the list (`inventory_movements.sql:30-31`, IOD-1) is harmless only because it has no `)` or `'`. `check-i18n` reads 2 enums this way
  (`movements.type.` `:710`, `movements.bucket.` `:725`) and others through `sqlCheckIn` / `sqlEnumAnywhere` (same capture shape — not part of F13's
  brief; measured count reported by 7b-1).
- **Change:** one shared character-level reader in `scripts/lib/` (strings, `--` and `/* */` comments, parenthesis depth — no line assumption, the
  AGENTS.md "按字符走" rule) used by both checks; each check gets its own fault cell: a comment holding `)` placed mid-list (must not truncate) and a
  comment holding `'ghost'` (must not add) — each must turn the check red when the reader is swapped back to the old regex, and green with the new
  one; a coverage assertion (values parsed = an independent count of quoted literals outside comments). The IOD-1 comment can then stay where it is.
- **Effect:** both checks read 14 movement types today, unchanged. **Fixture:** the checks' own self-injection cells (they run in `npm run build`).

## §8 · (g) Migration shape and broken window

- **Shape:** one migration per cut, dated from `date`, built from the mirrors, COMMIT → ROLLBACK dry run on live first; 7b-1 before 7b-2 (exceedance →
  incident, NCR source cites a finding).
- **7b-1 window (old app + new DB):** new tables, two new codes granted to live roles (Q2), the F12 note. The old app never reads the new tables; its
  role pages list two codes it has no label for (raw key, until the deploy) — derived, cosmetic; nothing in use breaks.
- **7b-2 window:** new tables; `open_ncr` accepts `inspection` only with a finding cited — the old app never sends it. Nothing breaks.
- **Existing records:** none changed except F12's one dictionary row. No back-fill (Q94 [R]); 0 NCRs, 0 run events on live.

## §9 · (h) Time estimate — two numbers, measured calibration

**Measured** [M, transcripts; active = brief → push (7a-2 from the close-out push, the 6a-2 / 6b-2 convention); gaps ≥ 10 min excluded unless they
end in a tool result (none in either cut); floor / work by tool-call class; 7a-1 ±5–8 min (empty tool descriptions after a compaction, classified by
command text), 7a-2 ±5 min; script `measure_7a.py`]:

| cut | active | floor | work | Step-0 est. low (raw) | active ÷ low | work ÷ est. work low |
|---|---|---|---|---|---|---|
| MES-1 … MES-6a-2 | (13 rows, `docs/surveys/MES-6b/STEP0-HANDBACK.md` §11) | | | | | |
| MES-6b-1 | 3 h 05 | 1 h 40 | 1 h 26 | 6 h 50 | 0.45 | 0.28 |
| MES-6b-2 | 3 h 07 | 2 h 10 | 0 h 57 | 5 h 40 | 0.55 | 0.24 |
| **MES-7a-1** | **2 h 35** | **1 h 25** | **1 h 09** | 7 h 00 | **0.37** | **0.22** |
| **MES-7a-2** | **2 h 01** | **1 h 16** | **0 h 45** | 5 h 20 | **0.38** | **0.21** |
| MES-7a-1 close-out | 0 h 11 | 0 h 05 | 0 h 06 | — | — | — |

No waits for Tim in either cut. Floor components (7a-1 / 7a-2, min): backup 17 / 16 · full gate 13 / 12 · smoke 25 / 24 · layout 10 / 6 · apply + dry
run 5 / 5 · offline gate 3 / 3 · build 4 / 5 · live proof 6 / 3 · fresh clone 1.3 / 2.5 · injections 0.4 / 0.3. Failed / re-run floor: 7a-1 4.7 min
(offline gate on the midnight fixtures, a proof rerun), 7a-2 1.9 min not hidden under another floor job. **Medians:** active ÷ low **0.75** (17 cuts) /
**0.45** (last five, 0.37–1.10); work ÷ est. work low **0.57** (17) / **0.24** (last five, 0.21–0.66); median floor 1 h 24 (17) / 1 h 40 (last five).
**Floor used: 1 h 20 – 2 h 00** (the two 7a floors 1 h 16 / 1 h 25, plus the live dry run, the fresh-clone build and one rerun at the top).
This close-out + Step 0 block: ≈ 50–60 min close-out (it rendered pages on the deployed app and a local rebuild) + the Step 0.

**Work (raw estimate, minutes):**

| part | 7b-1 Incidents (+ F12, F13) | 7b-2 Inspections + environment |
|---|---|---|
| orientation | 5 – 5 | 5 – 5 |
| database | kinds + incidents + updates + masked view / grants / mask rules + five functions 80 – 120 · batch links + suggestion 35 – 55 · working days + NEA status + two arms + V19 30 – 45 · codes, grants, nav 20 – 30 | templates / items / runs / results / findings + functions 100 – 150 · finding → task 15 – 25 · NCR source `inspection` 20 – 30 · parameters / results + exceedance → incident 50 – 75 · V18 / V20 + two arms 20 – 30 |
| fold-ins | F12 5 – 10 · F13 30 – 45 (F14 +10 – 15 if Q25) | — |
| pages | incidents list + detail + dictionary 60 – 90 | inspections list, template editor, run page, environment 90 – 130 |
| fixtures + injections | 55 – 85 | 55 – 85 |
| live proof | 15 – 25 | 15 – 25 |
| messages, docs, static, trail arm, document type | 30 – 45 | 30 – 45 |
| **work** | **6 h 05 – 9 h 15** | **6 h 40 – 10 h 00** |
| **calibrated work (× 0.24, last-five median)** | **≈ 1 h 30 – 2 h 15** | **≈ 1 h 35 – 2 h 25** |

**Estimates — process floor + work, two numbers per cut:**
- **MES-7b-1 Incidents (+ F12, F13):** floor **1 h 20 – 2 h 00** + work **≈ 1 h 30 – 2 h 15** (raw 6 h 05 – 9 h 15) = **≈ 2 h 50 – 4 h 15**
  (with F14: + ≈ 5 min).
- **MES-7b-2 Inspections and environmental monitoring:** floor **1 h 20 – 2 h 00** + work **≈ 1 h 35 – 2 h 25** (raw 6 h 40 – 10 h 00) =
  **≈ 2 h 55 – 4 h 25**.
- **One cut instead:** floor 1 h 20 – 2 h 00 + work ≈ 3 h 05 – 4 h 40 (raw 12 h 45 – 19 h 15) = **≈ 4 h 25 – 6 h 40** — above every measured MES cut.
- With the all-cut work median (× 0.57) instead of the last five, the work numbers are 3 h 30 – 5 h 15 (7b-1) and 3 h 50 – 5 h 40 (7b-2) — the
  pessimistic bound; the last five cuts all landed at or below the × 0.24 – 0.28 band.
- MES-0's own figure for MES-7b was 8 h 05 – 15 h 15 raw (floor 1 h 30 – 2 h 30).

---

## §12 · Every open question, with a recommended answer and its evidence

Grilling is a design tree. **Round 1** is the frontier — questions whose prerequisites are settled. **Round 2** questions depend on a round-1 answer;
each names it, and its recommendation assumes the round-1 recommendation. If Tim answers a round-1 question differently, the round-2 questions under it
are re-asked.

### Round 1

❓ **Q1** - **One cut or two**: as one cut MES-7b is ≈ 4 h 25 – 6 h 40 calibrated (§9), above every measured MES cut (largest 3 h 55 active). It is two
proof shapes: a register with a legal deadline, health masking and batch links; and checklists + lab results. Environmental exceedances open incidents
(Q75), so incidents come first.

➡️ **Two cuts: MES-7b-1 Incidents (+ F12, F13, and F14 if Q25)** ≈ 2 h 50 – 4 h 15, then **MES-7b-2 Inspections and environmental monitoring**
≈ 2 h 55 – 4 h 25. F12 / F13 ride with 7b-1 because it is the next migration and the next build.

❓ **Q2** - **Safety codes and who holds them**: MES-0 Q90 [R] — `module.safety.view` to every role holding `module.processing.view` plus cfo; `.edit` to
cto, warehouse, admin. Live `module.processing.view`: admin · auditor · cco · cfo · cto · finance · gm · operations · warehouse [M].

➡️ **As ruled:** `module.safety.view` → admin · auditor · cco · cfo · cto · finance · gm · operations · warehouse; `module.safety.edit` → admin · cto ·
warehouse (granted in 7b-1's migration; admin by the standing rule). Edit requires view (`EDIT_REQUIRES_VIEW`). No `action.*` code is needed
(recording is the module's edit).

❓ **Q3** - **What an incident records, and how it is corrected**: the spec's exception record is "time, type, duration, action taken, responsible person"
[S §3.1]; process records are append-only, corrections are rows with a reason [R].

➡️ **`incidents`**: `INC-` (gapless yearly), kind, occurred at (required, not in the future), location (optional), machine (optional, equipment
assets only), what happened (required), immediate action (required), responsible person (employee or free text, required), duration (optional),
NEA-reportable yes / no (required, Q10), source `manual` (`device` reserved). The row never changes; **`incident_updates`** carries later facts:
`nea_notified` (when, how, reference), `report_submitted` (when, reference), `closed` (summary), `correction` (field, new value, reason). The page
shows the current state from both.

❓ **Q4** - **Incident kinds**: the safety signals the specification sends to the ERP as exceptions (temperature rise / thermal runaway, electrolyte vapour
and HF, smoke and fire, dust concentration) [S §2, §3.1, §3.3, §3.5, §9], plus the WSH register's injury and near miss [Q `forward-queue.md:2373`]
and emission exceedance (Q75). The catch-all rule forbids "other".

➡️ **A dictionary `incident_kinds`, RUNTIME CONFIG, edited under `module.safety.edit` in `/settings/dictionaries`, seeded with seven kinds:**
`thermal_runaway` · `fire_smoke` · `gas_release` · `dust_concentration` · `injury` · `near_miss` · `emission_exceedance`; no "other". A kind's code is
locked once an incident cites it (the downtime-cause precedent).

❓ **Q5** - **The alarm transform**: MES-0 §8.2 lists it; the standing rule forbids a transform on an invented payload format; no alarm panel exists
(devices: 2 gateways, 2 scales) [M].

➡️ **Not built.** `safety_alarm` keeps `transform_function` NULL (a row would wait `awaiting_transform` and be processed when a transform exists,
`ingest_process_pending`); incidents are recorded by hand through `record_incident`; `incidents.source` = `manual` · `device`, `device` refused today
and never changed (the downtime precedent). Registered: D8 waits for the alarm panel's documented event format.

❓ **Q7** - **Batches an incident touched**: MES-0 Q73 [R] — suggested from the location and machine at that time, confirmed by a person, a link, never a
safety state. Live: 7 / 107 movements carry a location, 0 / 14 runs a machine and times [M].

➡️ **Suggestions = (a) batches with stock at the incident's location at its time (net of movements up to then, by `location_id`), (b) input and output
batches of committed runs on the incident's machine whose `[started_at, ended_at)` contains the time.** No time window is invented around the
moment. The person confirms each (and may pick any other batch by code); an unlink needs a reason. A linked batch's page shows "Linked incidents".
On today's data the suggestion list is honestly empty — said so on the page ("no location / machine history at that time").

❓ **Q8** - **"Optionally a hold" (Q73)**: a quality hold today is an open NCR (`nonconformance_reports`, opened by `module.quality.edit`, decided by
`action.ncr_decide`); `hold_stock` is a stock-bucket move.

➡️ **No automatic hold.** On the incident page, a holder of `module.quality.edit` may open an NCR on a linked batch with **a new source `incident`**
citing the incident (the existing hold then applies and is decided as today). Recording an incident never moves stock. *(Alternative, cheaper: no
link — the quality editor opens a `manual` NCR and writes the INC code in it.)*

❓ **Q9** - **Downtime and run events**: the same physical event can be a downtime row, a `safety_alarm` run event and an incident. MES-7a-1 left
downtime ↔ run-event pairing registered, not built [Q `known-issues.md:10829-10833`].

➡️ **Optional citations, no auto-pairing:** an incident may cite one downtime row (same machine) and one run event; neither creates the other;
reliability counts downtime only, unchanged; nothing is counted twice because only incidents feed the incident register and only downtime feeds MTBF.

❓ **Q10** - **The NEA duty**: "工伤或火灾事故须立即通报、并在两个工作日内提交书面报告" [Q `forward-queue.md:2373`]; no working-day arithmetic exists [M].

➡️ **Per incident, the recorder answers "NEA-reportable?" (required; the duty text is shown beside it — no dictionary rule decides it). For a
reportable incident: an arm `incident_nea_notify_due` until an `nea_notified` update exists ("immediately" — no number); an arm
`incident_report_due` with the deadline = V19 working days counted from the next working day after the incident's Singapore date
(`business_days_after`, on `is_business_day`; a missing holiday calendar → "cannot be computed", never a guessed date).** Both arms read
`module.safety.view`.

❓ **Q12** - **Hand-overs citing incidents**: the handover module was told to cite the WSH register once it exists, and not before
[Q `shift_handovers.sql:4`, `forward-queue.md:2373`]; the pattern exists (`shift_handover_equipment_refs`).

➡️ **Include in 7b-1:** `shift_handover_incident_refs` (handover, incident) like the equipment refs, picked on the handover form; the stale comments
(`shift_handovers.sql:4`, `handover_item_types.sql:24`) corrected. ≈ 15 min. *(Or register it for later.)*

❓ **Q13** - **Inspections (7b-2)**: MES-0 Q72 [R] — templates with items (V18), runs by an inspector with pass / fail / n-a per item.

➡️ **Templates (code, name, area, frequency days — V18, active) with ordered items; a run copies the items' text at the moment it is recorded, so editing
a template never rewrites a past run; a run is submitted whole (inspector = an employee, when, where — location / machine optional), a fail needs a
note; a submitted run is immutable; a mistaken run is corrected by a new run citing it with a reason. `INS-` gapless yearly.** No template seeded —
the checklists are the safety firm's (V18).

❓ **Q16** - **Environmental monitoring (7b-2)**: MES-0 Q75 [R] — lab results with limits V20; an exceedance raises an incident.

➡️ **`environmental_parameters` (dictionary: code, name, unit, limit, basis max / min; none seeded — the parameters are the licence's) and
`environmental_results` (parameter, sample point, sampled on, laboratory from `laboratories`, report reference, value; the limit copied at entry;
exceeds = true / false / NULL "not judged" when no limit); append-only, corrections as rows. An exceedance opens an incident of kind
`emission_exceedance` in the same transaction (NEA-reportable left for the person to answer on that incident).** Continuous sensors stay alarms.

❓ **Q17** - **Pages and navigation**: no Safety module exists (`lib/modules.ts`) [M].

➡️ **A new nav module "Safety" (gate `module.safety.view`), entries Incidents (7b-1), Inspections and Environment (7b-2); dictionaries in
`/settings/dictionaries`.** Five pages over the two cuts, as MES-0 sized.

❓ **Q18** - **Approvals**: MES-0 §4.1 / Q89 [R].

➡️ **None new.** Incidents, updates, inspections, findings and lab results are records of events. Approvals stay ON, finance / cfo / 1,000.

❓ **Q20** - **Pending values**: V18, V19, V20 (§6).

➡️ **As §6:** arms on `pending_values` with `module.safety.view`, rows in `docs/mes-pending-values.md` in the same commit; V19 in 7b-1, V18 and V20 in
7b-2; V18 and V20 list one row while their dictionary is empty (the V29 precedent).

❓ **Q21** - **Migration and window**:

➡️ **One migration per cut, COMMIT → ROLLBACK dry run on live first; no back-fill; code first, migrate last.** 7b-1's window: the old app shows two
unlabelled codes on the role pages (cosmetic, until the deploy); nothing in use breaks. 7b-2's window breaks nothing.

❓ **Q23** - **F12**: the live note is still the old text; RUNTIME CONFIG, so no gate compares it [M].

➡️ **7b-1's migration sets the live row to the mirror's text (idempotent `UPDATE … WHERE notes <> …`), its in-transaction proof reads it back; the
commit states the bootstrap default is still correct.** No new fixture (266 REG pins the mirror); if Tim wants live pinned repeatably, a line in live
fixture 265's family (≈ 5 min).

❓ **Q24** - **F13**: both parsers can be hidden from or added to by a comment (§7) [M].

➡️ **One shared character-level reader used by both checks, with two fault cells each (a `)` in a comment must not truncate; a quoted word in a comment
must not add) and an independent count as the coverage assertion.** `sqlCheckIn` / `sqlEnumAnywhere` in `check-i18n` have the same capture shape:
7b-1 reports how many readers use it and moves them onto the shared reader only if the count is small (≤ 5); otherwise registers them.

❓ **Q25** - **F14 — the roll-forward's empty state** (close-out finding): with no processing run, `/operation/balance` shows only "No processing run has
been recorded yet" and hides the stock roll-forward (`page.tsx:106`, MES-5b-1) [M].

➡️ **Fold it into 7b-1 as F14:** the page is empty only when the processing months, the processing lines **and** the roll-forward rows are all empty;
one local page check on a runs-less rebuild proves the roll-forward renders. ≈ 10–15 min raw.

❓ **Q26** - **The chart of accounts and system accounts** (close-out finding): no page lists the chart or shows `is_system` [M].

➡️ **Not in MES-7b** (nothing in it needs it); registered (`MES7A2CO-NO-CHART-OF-ACCOUNTS-PAGE`). If Tim wants it, a "System" marker on the trial
balance's account rows is ≈ 15 min and could ride as F15 — Tim's call.

❓ **Q27** - **Document prefixes**: MES-0 Q53 [R] — `INC-`, `INS-`; 59 types live, no INC / INS [M].

➡️ **`INC` (7b-1) and `INS` (7b-2), gapless yearly with width `GREATEST(4, …)` like NCR / COA**; registry, search and fixtures 100 / 101 / 254 move with
them.

❓ **Q28** - **Who may record an incident**: MES-0 gives recording to `module.safety.edit` (admin · cto · warehouse). A near miss is often reported by
whoever saw it.

➡️ **`module.safety.edit` only, as ruled.** Widening to every `module.safety.view` holder is a one-line grant decision Tim can make later; recording
needs no new code either way.

### Round 2 (each depends on the round-1 answer named)

❓ **Q6** - **(Q2, Q3) Injury details and health masking**: MES-0 Q76 / Q91 [R] — behind `data.view_health`. Live `data.view_health`: admin · cco · cfo ·
finance · hr; **not cto, not warehouse** — the two non-admin safety editors [M].

➡️ **Injured person (employee or a named non-employee), nature of injury, treatment, days lost: masked columns on `incidents` (column-list grant +
`incidents_masked` + `change_log_mask_rules` `code_or_self:data.view_health:injured_employee_id`), recorded by any `module.safety.edit` holder; after
saving, a recorder without `data.view_health` sees "Restricted" with a line saying the details are kept for HR / health readers. The injured employee
reads their own.** No grant of `data.view_health` to cto or warehouse (that would widen leave and medical reading too). *(Alternative: injury details
recorded only by `data.view_health` holders on a second step — slower to record.)*

❓ **Q11** - **(Q10) V19's value**: MES-0 Q74 [R] pre-fills "2 working days" from the repo's record of the duty, flagged unconfirmed; the brief's standing
rule says every limit is a "Not yet set" value.

➡️ **Store 2 with `confirmed_at` empty and the source shown ("repo record `forward-queue.md:2373`, not yet confirmed against the licence"); the
deadline is computed and shown as "unconfirmed"; V19 stays on the pending-values page until someone with `module.safety.edit` confirms it against the
licence.** This keeps the legal duty tracked from day one without presenting it as confirmed. *(The strict alternative: leave it empty — the report
arm then shows "deadline not set" and computes nothing.)*

❓ **Q14** - **(Q13) Findings "raised as tasks"**: `tasks` has no source link and only its owner can insert it [M].

➡️ **A finding is its own record (`inspection_findings`: corrective action, owner employee, optional due date chosen by the person — no default,
closure row with what was done); the arm `inspection_finding_open` reminds. "Raise a task" on a finding creates a personal task for the person
pressing it, linked from the finding (`inspection_findings.task_id`) — closing the task does not close the finding.** `tasks` itself is not changed.
*(Alternative: add a source link and a system insert path to `tasks` — touches a module every page uses; not recommended for this cut.)*

❓ **Q15** - **(Q13) The NCR source `inspection`**: reserved "for MES-7b" but described as incoming inspection (来料检验) in the mirror
(`nonconformance_reports.sql:11-12,89`, `open_ncr.sql:48`); MES-0 function 23 is a safety inspection of the plant [M].

➡️ **Use it for an inspection finding that concerns a batch:** `open_ncr('inspection', …)` must cite an `inspection_findings` row (refused without one,
`NCR_INSPECTION_FINDING_REQUIRED`), opened by a `module.quality.edit` holder as today; the comments are re-worded to "an inspection finding".
Incoming (receipt) inspection stays unbuilt and is registered as its own item. Fixture 263 `:247-248` become an accepted-with-finding arm and a
refused-without-finding arm. *(Alternative: keep `inspection` reserved for incoming inspection and give safety findings no NCR path.)*

❓ **Q19** - **(Q1) Trails, change log, masking**: MES-0 §4.3 lists subjects `incident`, `inspection_run`.

➡️ **Subjects `incident` (7b-1) and `inspection_run` (7b-2); incidents also visible under each linked batch; dictionaries under the dictionary trail;
environmental results under a `safety_environment` list trail. Wording arms ㉜ and ㉝, each with a drift and a part fault. Every new table
change-logged, exclusions stay 8. Masking only the injury columns (Q6).**

❓ **Q22** - **(Q1) Fixtures**:

➡️ **New 267 (7b-1) and 268 (7b-2); changed without weakening the list in §4** (263 per Q15 in 7b-2); every new arm fault-injected; the injection run
repeated on a fresh rebuild after the last database edit, before the push; F13's cells live in the checks themselves.

## §13 · Tim's own facts this cut needs (not design questions)

- Whether the NEA licence confirms "immediate notification + written report within 2 working days", and for which incident kinds (V19, Q10, Q11).
- The plant's inspection checklists and frequencies (V18) and the monitored emission parameters with their limits (V20) — from the safety engineering
  firm and the NEA licence.
- Who in the plant records incidents (today's ruling: cto · warehouse · admin, Q28) and who reads injury details (`data.view_health`, Q6).

## §14 · Assertions measured and found false or imprecise

1. **Brief: "the NCR source reserved for them [inspections]".** The mirror reserves `inspection` for **incoming** inspection (来料检验,
   `nonconformance_reports.sql:11-12,89`; `open_ncr.sql:48`) — not the safety inspection of MES-0 function 23. Q15.
2. **MES-0 README:1025 / Q74 cite `docs/forward-queue.md:1686`** for the NEA duty — it is now `:2373` (the file grew).
3. **MES-0 §8.2 "alarm transform"** — not buildable under the standing rule (no payload format exists); Q5.
4. **MES-0 Q72 "findings raised as tasks"** — `tasks` has no path for it today (§1 item 3); Q14.
5. **A sub-agent counted 114 permission codes in `db/tables/permissions.sql`**; live has **79** (module 32 · action 36 · data 11) and admin holds
   79 / 79 — the catalogue figure used here is the live one.
6. Close-out: the brief's "chart of accounts shows 6800 as a system account" has no subject (no such page; Q26).
7. Zero other assertions of the brief found false: SHA `c5d4cf67`, clean tree, 7 accounts enabled, approvals ON finance / cfo / 1,000, admin holds every
   code (79 / 79), `action.ncr_decide` admin · cco · cto, `action.issue_coa` admin · cco, `require_calibrated_since` NULL, two issued CODs with their
   recorded hashes and byte sizes unchanged, production on the MES-7a-2 code (the close-out read its new panel and column on the deployed pages).

## §15 · Stop

No code edits and no migrations. Waiting on Tim's answers to Q1–Q28.
