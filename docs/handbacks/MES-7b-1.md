v1.4.54 — Incidents: a new Safety section records incidents (INC-…) such as thermal runaway, fire, gas or dust releases, injuries and near misses, with what happened and what was done; injury details are visible only to those allowed to see health information and to the injured person; an incident can be linked to the batches it touched, a stoppage, a run event and a shift handover; and an incident marked as reportable to NEA reminds until the notification is recorded and shows the written-report deadline, which is still marked unconfirmed.

# MES-7b-1 — the incident register (MES group, eighteenth cut; 2026-10-16), with F12 · F13 · F14

Tim's brief of 2026-10-16: build MES-7b-1 as ruled in `docs/surveys/MES-7b/STEP0-HANDBACK.md` (Q1–Q28, the 7b-1 half), with the fold-ins
**F12** (the live `spare_part` note), **F13** (one character-level reader for the movement-type lists) and **F14** (`/operation/balance` empty only
when months, lines and roll-forward are all empty). Migration `db/migrations/2026-10-16-mes7b1-incidents.sql` (5,022 lines, built from the mirrors by
`db/scripts/build_mes7b1_migration.py`).

**Opening check.** Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
`a46322612d912559e4518cebcdc80c43d889940a`. Files staged by explicit path only.

---

## §1 · Opening live readings (before anything changed)

Read **2026-10-16 14:21:15 CST** with `docs/surveys/MES-7b-1/live-readings.sql` (read-only, `BEGIN READ ONLY … ROLLBACK`, `READ_OWN_EXIT=0`) as
`postgres` (`rolbypassrls = true`, base tables and the catalog); the two reconciliations in the same transaction as tim@ (`634c00f9…`, cfo) switched to
`authenticated`, because both functions filter by the reader's codes.

| What | Reading |
|---|---|
| Code holders | `module.processing.view` = admin · auditor · cco · cfo · cto · finance · gm · operations · warehouse (9) · `data.view_health` = admin · cco · cfo · finance · hr · `module.quality.edit` = admin · cco · cto · `action.ncr_decide` = admin · cco · cto · `action.issue_coa` = admin · cco · `module.safety.*` **0** · catalogue **79** (32 module · 36 action · 11 data) |
| People and calendar | employees 22 (7 not deleted, 6 with a login) · SG public holidays 2026: 14 active · 2027: 12 active |
| Locations and stock | locations 4 (1 active, 0 quarantine) · movements with a location 7 / 107 (SG2026081201 1 · ZZ-1BCONF 2 · ZZ-IODCONF-A 2 · ZZ-SMOKE-NTFLOC 2) · runs 14, **0 with a machine** |
| Downtime, events, handovers, NCRs | downtime 1 (open 1, md5 `6d8b598a…`) · run events **0** · handovers **0** (items 0, equipment refs 0) · NCRs **0** · NCR source CHECK = manual · customer_complaint · quality_limit · inspection |
| Incident objects | no incident table · document types 59 (INC 0) · masked views 38 |
| F12 before | `spare_part` note = the old text "…而且【不按批次追溯】…" · `material_kinds` md5 `0acf0d80…` |
| Standing state | approvals ON (finance / cfo / 1,000) · 7 accounts, 0 disabled — admin@ admin · chooer@ finance · fusheng@ warehouse · phua@ cto · sandra@ cco · tim@ cfo · vince@ gm · role codes admin 79 · auditor 20 · cco 46 · cfo 33 · cto 37 · finance 42 · gm 21 · hr 8 · operations 15 · procurement 16 · sales 17 · warehouse 29 (`role_permissions` md5 `c4a18882…`) · `require_calibrated_since` NULL · throwaways 0 · pending: CLM-2026-0004 only |
| CODs | COD-2026-0001 sha256 `ba299a4f…f42101`, 34,701 bytes · COD-2026-0002 sha256 `717661f6…13a4f9`, 34,746 bytes |
| Books | journal 83 entries / 186 lines (md5 `d9827dd9…`) · batches 24 (md5 `6f7a7601…`) · movements 107 (md5 `fe4000bb…`) · safety-state rows 1 · change_log 42,388 (max seq 46,262) · public tables 299 |
| Reconciliation (tim@) | **AP** 422,188.32 / 381,604.42 / unexplained **0.00** · **AR** 57,545.87 / 43,002.12 / **0.00** · 1200 61,387.92 / 172,403.48 / **0.00**, reconciled · 1220 134.86 / 388.20 / **0.00**, reconciled |

**Assertions of the brief or of Step 0 measured false or imprecise:**
(1) The NEA duty text ("within 2 working days") is at `docs/forward-queue.md:2402`, not `:2373` — V19's source line cites `:2402`.
(2) Step 0 said the old app would show the two new codes **unlabelled** on the role pages during the window — measured false: the role matrix reads
`name_en` / `name_zh` from the `permissions` table (`app/settings/roles/PermissionMatrix.tsx:63-95`, `app/settings/roles/[id]/page.tsx:36`), so the
new codes appear with their names from the moment the migration commits.
(3) `module.safety.edit` in the brief is "admin, cto, warehouse" — that is what live received; the mirror's bootstrap gives admin and warehouse only,
because the rebuild has no `cto` role (fixture 267 GRANT pins both facts).
Zero other assertions found false (SHA, clean tree, 7 accounts enabled, approvals, holders, `require_calibrated_since`, the two issued CODs, no
incident objects on live).

## §2 · What was built

* **Codes** (Q2): `module.safety.view` → every role holding `module.processing.view` (9 on live); `module.safety.edit` → admin · cto · warehouse
  (edit implies view). Twelve grants on live, nothing else in `role_permissions` moved. `data.view_health` granted to no new role; its description now
  says it also covers injury details.
* **Safety module** (a 10th top-level module, after Operation): `/safety/incidents` (list, NEA status, the V19 panel), `/safety/incidents/new`,
  `/safety/incidents/[id]`. Nav, module registry, breadcrumbs, search and document registry (`INC`, 60 types) know it.
* **`incident_kinds`** (Q4): seven kinds — thermal runaway · fire / smoke · gas release · dust concentration · injury · near miss · emission
  exceedance; no "other" (CHECK). A dictionary in `/settings/dictionaries`; a used code is locked (`INCIDENT_KIND_CODE_LOCKED|<code>|<n>`, counting
  incidents **and** corrections that name it), the name can change.
* **`incidents`** (Q3 · Q5 · Q6): `INC-YYYY-NNNN`, gapless per year (own advisory lock). Required: kind, time (not in the future), what happened,
  immediate action, a responsible person (employee or name), and an answer to "reportable to NEA?". Optional: location, machine, duration, a stoppage,
  a run event. Source `manual`; `device` reserved and refused by name. Written only through `record_incident`; never updated or deleted
  (`INCIDENT_IMMUTABLE`, statement-level, owner included).
* **Injury details** (Q6): injured employee **or** a named outsider (not both), nature, treatment, days lost — five columns out of the column grant,
  read through `incidents_masked` (`data.view_health` **or** the injured employee themselves), five mask rules `code_or_self:data.view_health:
  injured_employee_id`. The injured employee can open **their own** incident page without any safety code (only that one).
* **`incident_updates`** (Q3 · Q10): append-only facts — `nea_notified`, `report_submitted` (each once, with a time not in the future and not before
  the incident), `closed` (a summary), `correction` (one of seven fields, with a reason; refused after closing). The last correction wins (ordered by
  identity, not by `created_at`). The incident row itself never changes.
* **Batch links** (Q7 · Q8 · MES-0 Q73): `suggest_incident_batches` — stock on hand at the incident's location at that moment, and the inputs and
  outputs of committed runs on the incident's machine whose `[started_at, ended_at)` contains the moment; nothing is linked automatically. Confirm a
  suggestion (`location` / `machine_run`, refused if not in the suggestions), or pick any batch (`picked`); unlink once, with a reason. **A link never
  sets a safety state and never moves stock.** To hold a linked batch, a `module.quality.edit` holder opens an NCR with source `incident` from the link
  (`open_ncr` checks the link is active); the existing quality hold applies and an `action.ncr_decide` holder decides it.
* **Citations** (Q9): a stoppage must be on the incident's machine (`INCIDENT_DOWNTIME_OTHER_MACHINE`) and needs a machine; a run event must exist,
  not be withdrawn and not be superseded by a correction. MTBF still counts downtime only (`equipment_reliability` does not read incidents).
* **NEA** (Q10 · Q11): two reminders on the home page and in `operations_now` — "notify NEA" until `nea_notified`, "written report due" until
  `report_submitted` — read `module.safety.view`. The deadline is the incident date (Singapore) plus **V19** working days (`business_days_after`,
  weekends and active SG holidays; NULL — "cannot compute" — when a calendar year it crosses has no holidays). Each reading states its state:
  computed · not set · cannot compute · submitted · not reportable; **V19 = 2, unconfirmed**, stored in `safety_settings` with its source, on the
  pending-values page until confirmed (`set_safety_settings`, `module.safety.edit`; a changed number drops the confirmation).
* **Handover** (Q12): `submit_shift_handover` takes `p_incident_ids`; `shift_handover_incident_refs` stores the reference (no copied text), written
  only through the function. Both the handover page (processing view) and the incident page (safety view) read it.
* **Batch and machine pages**: a "Linked incidents" section on `/inbound/[id]/edit`, `/output/[id]/edit` and `/operation/equipment/[id]`.
* **Trail**: subjects `incident` · `safety_settings` · `dictionary_incident_kinds`; links show on the batch's trail; wording arm ㉜.
* **F12**: the migration sets live's `spare_part` note to the mirror's sentence (extracted from the mirror, not retyped) and reads it back inside the
  transaction before COMMIT.
* **F13**: `scripts/lib/sql-in-list.mjs` — one character-level reader (comments, nested block comments, strings with `''`, quoted identifiers, bracket
  depth), used by `check-enum-mirrors` and `check-i18n`; each runs two self-cells every time (a `)` in a comment must not truncate; a `'ghost'` in a
  comment must not add a value) plus an independent count (delete comments, count quote pairs). Similar readers switched: `check-i18n`'s
  `sqlEnumAnywhere` and `sqlCheckIn` (4 switched, ≤ 5); the Python reader in `db/check_mirrors.py:811` registered (`MES7B1-PY-ROLE-LIST-READER`).
* **F14**: `lib/balanceEmptyState.ts` — the page is empty only when months, lines **and** roll-forward rows are all empty;
  `scripts/check-balance-empty-state.mjs` in the build chain.
* **Fixtures**: new **267** (REG · GRANT · REFUSE · NUM · MASK · DIRECT · UPDATE · KIND · LINK · NCR · CITE · NEA · V19 · HANDOVER · TRAIL); count pins
  moved in 100 · 101 · 111 · 254 (60 document types, 52 / 68 arms), none weakened.

## §3 · Verification, in the brief's order

| # | Step | Result |
|---|---|---|
| 1 | Offline gate | **`GATEOFF_EXIT=0`**, 99 s; fixture 267 ✓ on the rebuild |
| 2 | Backup | **`BACKUP_EXIT=0`**, `evoltrya-backup-2026-10-16-1525.dump`, 8.2 MB, 9,110 TOC entries (previous 9,074), 15:25 → 15:39 CST |
| 3 | Dry run on live | first attempt (15:39:44) stopped on a syntax error — the builder's F12 extractor had taken the VALUES tuple's closing `)` with the note expression; nothing committed (`DRY_OWN_EXIT=3`). Builder fixed (expression ends at `。'`, balanced-parentheses assertion added), migration rebuilt. Second run 15:41:54 → 15:45:29: pre-flight green (19 functions: 3 replaced, 16 new), migration + in-transaction proof + grants replay, then **ROLLBACK**: **`DRY_OWN_EXIT=0`**; F12 read back equal; every pending document has an eligible decider other than its submitter |
| 4 | apply_migration | **window start 2026-10-16 15:49:13 CST** (committed; `db/migration-windows.tsv`), **`APPLY_OWN_EXIT=0`** |
| 5 | Types | `NOTIFY pgrst` then `npm run types:gen`, **`TYPESGEN_OWN_EXIT=0`**; differs from my pre-window splice only by relationship entries PostgREST infers through `incident_people`; the generated file is committed |
| 6 | tsc | **`TSC_OWN_EXIT=0`** |
| 7 | build | **`BUILD_OWN_EXIT=0`** |
| 8 | Full gate | **`GATE_EXIT=0`** (611 s) — rebuildability ✓ · mirrors vs live ✓ (no differences) · fixtures ✓ (267 ✓) · anon surface ✓ (baseline 328) · **colgrant live and rebuild: 492 relations · 13 batches · 40 column-listed tables, no gap** · B1 / B2 0 on both sides |
| 9 | i18n | **`I18N_OWN_EXIT=0`** — 262 dynamic prefixes, all enumerable (the safety enums show in the informational dead-key list because their key is built in a helper, `app/safety/safetyTypes.ts`; every key is defined in both languages) |
| 10 | Error swallowing | **`SWALLOW_OWN_EXIT=0`** (0 unallowed) |
| 11 | Layout | §5 |
| 12 | Smoke | first run **`SMOKE_EXIT=1`** — the smoke script's own id query for `/safety/incidents/[id]` ordered `incidents` by `created_at`, which the table does not have (42703); 222 routes walked before the stop, **0 failed**; its throwaway was removed (read back: 0 accounts, 0 roles, 0 grants). The same defect hit MES-6b-1 (`nonconformance_reports`), so this cut adds the override **and** a static pre-flight (`preflightOrderKeys`: every `ID_SOURCES` table has `created_at` in its mirror or an override, checked before anything starts; fault `SMOKE_PREFLIGHT_FAULT=drop-incidents-order` goes red naming `incidents`, exit 1, no dev server started). Second run **`SMOKE_EXIT=0`: 289 ok, 19 skipped (no data — `/safety/incidents/[id]` among them, an expected skip that will sound when the first real incident is recorded), 0 failed**. Scratch report: the same 6 stale rows from earlier cuts (1,057–1,699 h old, five still referenced), none mine; nothing deleted (the check reports, it does not sweep) |
| 13 | Live verification | §4 |
| 14 | Fresh-clone build | the cut's commit `08d5fbf8c19e9512756eb47afdbe4fc4e19e16e4`, cloned to a scratch directory with no `.env.local`: `npm ci` **`CI_OWN_EXIT=0`**, `npm run build` **`X_OWN_EXIT=0`** (16:49:41 → 16:50:56 CST). This row is recorded by a docs-only follow-up commit, which got its own fresh-clone build before the push (final report) |

**Fault injections.** `db/scripts/2026-10-16-mes7b1-fixture-injections.py`, **50 cells on 267**, every arm red at least once; run on a fresh rebuild
after the last database edit (r2, 15:2x CST): **`INJECTIONS_OWN_EXIT=0` (50 cells, 0 wrong)**. Two first-draft TRAIL cells (disable `zzz_change_log` on
`incident_batches` / `shift_handover_incident_refs`) went red in **REG**, not TRAIL — REG's change-log coverage assertion sees them first; they were
replaced by cells only a `record_trail` read can see (a member joined on the wrong column), and both bite TRAIL. Eight cells go red on a table CHECK or
foreign key rather than the function's named error (REFUSE injury-without-person · DIRECT ×2 · UPDATE reason · KIND code change · LINK reason · NCR
source · HANDOVER unknown incident): the fixture asserts the **named** error, so removing the function's line is caught; the constraint is a second wall.
Wording arm ㉜: `wording-drift-mes7b1` and `wording-part-mes7b1` each bite only ㉜. F13: `ENUM_READER_FAULT=old-regex` makes both checks fail both
self-cells (exit 2); `old-regex-strip` (check-enum-mirrors' original reader: cut, then strip) fails only the truncation cell — the ghost cell stays
green, which is exactly that reader's original defect (it stripped comments, but after cutting). F14: `CHECK_BALANCE_EMPTY_FAULT=two-sources` goes red.

## §4 · Live verification

Rolled back — `db/scripts/2026-10-16-mes7b1-live-proof.mjs`, **`MES7B1_PROOF_EXIT=0`** (2026-10-16 16:44 CST, **18.0 s in one
transaction**). One psql transaction from BEGIN to ROLLBACK; every action as a throwaway account (prefix `mes7b1probe`, made by the shared
`mintThrowaway` helper): `inv` (every code, for the scenery only), `ed` (safety view + edit, no health code), `hl` (safety view + health), `vw` (safety
view), `inj` (only `module.tasks.view` — the injured employee; their employee row inserted in the transaction), `qe` (quality edit), `ho` (processing
view + edit), and clones of the seven roles the seven real accounts hold (`cloneOf`, read-only; the cfo clone reads both reconciliations). My rows
were prefixed `ZZ-PROBE-MES7B1`; the committed run on my machine and the run events were inserted as owner (the fixture's and MES-7a-1's
handling — not the path under proof). No real account, no record that existed before this session, and no bucket was touched; the dictionary rename
was tried in a sub-transaction on a row this migration created, and undone. The script was rehearsed first on a local rebuild (`--local`, same SQL).

| Step | Result |
|---|---|
| Before | incidents 0 · updates 0 · links 0 · handover refs 0 · V19 2, unconfirmed · F12 read back (the mirror's sentence) · AP 422,188.32 / 381,604.42 / **0.00** · AR 57,545.87 / 43,002.12 / **0.00** · 1200 61,387.92 / 172,403.48 / **0.00** · 1220 134.86 / 388.20 / **0.00** |
| Injury, Restricted, self | INC-2026-0001 (injury at my bay, reportable, injured = the `inj` employee). Warehouse clone: incident seen, `injury_visible` false, nature / days lost NULL; reading the base column → `permission denied for table incidents`. Health holder: "ZZ burn to the left hand", 2 days. **The injured person (no safety code) reads their own incident with the injury, and no other (1 row).** Trail: warehouse clone reads `injury_nature = {"$restricted": true}`, cfo clone (health) reads the text |
| Refusals | future time → `INCIDENT_TIME_IN_FUTURE|2026-10-16 17:44` · device source → `INCIDENT_SOURCE_RESERVED|device` · gm clone → `PERMISSION_DENIED|module.safety.edit` |
| Kind code locked | `UPDATE incident_kinds SET code = 'injuries' WHERE code = 'injury'` → `INCIDENT_KIND_CODE_LOCKED|injury|1`; a rename passes (undone) |
| Suggestions | location incident → IN-2026-0522 (100 kg, at ZZ-PROBE-MES7B1-L1); machine incident → IN-2026-0523 (input) and OUT-2026-0720 (output) of the run on that machine at that moment |
| Confirm · pick · unlink | both suggestions confirmed; a batch not suggested → `INCIDENT_LINK_NOT_SUGGESTED|location|IN-2026-0524`; picked by code ✓; unlink without reason → `INCIDENT_UNLINK_REASON_REQUIRED`; with reason ✓; twice → `INCIDENT_LINK_ALREADY_UNLINKED`; **safety-state rows (4) and movements (112) unchanged by linking and unlinking** |
| Incident NCR + hold | an unlinked batch → `NCR_INCIDENT_BATCH_NOT_LINKED|INC-2026-0004`; on the linked output: NCR-2026-0001, source `incident`, names INC-2026-0004, **holding = true** (quality hold open) |
| Citations | another machine's stoppage → `INCIDENT_DOWNTIME_OTHER_MACHINE|ZZ-PROBE-MES7B1-M2`; a withdrawn run event → `INCIDENT_RUN_EVENT_WITHDRAWN` |
| NEA | both reminders (`incident_nea_notify_due` · `incident_report_due`, state computed, deadline 2026-10-20); deadline state computed, 2 working days, **confirmed = false**; notified → only the report reminder; report submitted → no reminder, state `submitted`; V19 on the pending list (unconfirmed) |
| Handover | handover on shift `day` citing two incidents: the handover page's reader (processing view) reads 2 refs, the incident page's reader (safety view only) reads 1; a direct insert → `permission denied for table shift_handover_incident_refs` |
| End | AP / AR / 1200 / 1220 unexplained **0.00** at every step (before, after receipts, at the end) |
| After ROLLBACK | incidents 0 · updates 0 · links 0 · handover refs 0 · probe materials 0 · probe employees 0 · incident NCRs 0 · kind `injury` still "Injury" · V19 2, unconfirmed; throwaway accounts and roles removed by the plan (closing reading: 0 / 0) |

**F14 on a local rebuild** — §5 (live has processing runs, so the runs-less state exists only locally).

## §5 · Layout survey

Live has no incident, no handover and no run event, so the survey ran on a **local rebuild of this cut's mirrors with my own data**
(`docs/surveys/MES-7b-1/local-seed.sql`: three incidents — an injury at a bay with two location links, a notification and a correction; a fire on a
machine with a cited stoppage, a picked link, an unlinked link and an incident NCR holding its batch; a closed near miss — one handover citing two of
them, **no processing run**). Clones carry the seven real roles' codes as read from live after the migration, plus an `inj` account (only
`module.tasks.view`) that is the injured employee. The measure is `scripts/survey-phone.mjs`'s own (read from that file); each run first injects an
overflow and must read it (self-test bit +400 px every time).

**10 runs (390 px and 1,280 px × admin · cfo · gm · warehouse · inj), 118 page loads: all 200, no application error, overflow 0, clipped tables 0.**
Pages: the three safety pages, the handover page and the new-handover form, `/operation/balance`, `/settings/dictionaries`,
`/settings/pending-values`, the NCR page, an inbound batch, an output batch and the machine page.
What each role sees (1,280 px, the injury incident): admin and cfo read the injury ("Chemical burn…", 0 × Restricted); gm and warehouse read
"Restricted" three times and no injury text; cfo and gm see the edit controls drawn and disabled with `module.safety.edit` named; warehouse can edit
but not open an NCR (`module.quality.edit` named). The injured employee (`inj`) opens **their own** incident with the injury shown, and is refused the
list and the other incident.
**F14 on the local rebuild (no runs, four stock movements):** `/operation/balance` shows the "no processing run" line for the processing section
**and** draws the stock roll-forward table (3 tables on the page) for every role — before F14 the whole page was that one line.

## §6 · Role table — the seven real roles (clones of their live codes, read-only)

Same transaction as §4; each clone holds exactly the codes of that real role on live after the migration. "List" = rows of `incident_rows`
(the incident list) in the transaction; "injury" = the injury incident's page; "handover" = the handover page and its incident references; "V19" = the
pending-values page's V19 row; "record" = pressing record (tried in a sub-transaction).

| Role (account) | Codes | safety view / edit / health | Incident list | Injury incident page | Handover page | V19 row | Reminders | Record an incident |
|---|---|---|---|---|---|---|---|---|
| admin (admin@) | 81 | ✓ / ✓ / ✓ | 4 rows | seen, injury shown | seen, 2 refs | 1 | 2 | OK |
| cfo (tim@) | 34 | ✓ / — / ✓ | 4 | seen, injury shown | seen, 2 refs | 1 | 2 | `PERMISSION_DENIED|module.safety.edit` |
| finance (chooer@) | 43 | ✓ / — / ✓ | 4 | seen, injury shown | seen, 2 refs | 1 | 2 | `PERMISSION_DENIED|module.safety.edit` |
| warehouse (fusheng@) | 31 | ✓ / ✓ / — | 4 | seen, **Restricted** | seen, 2 refs | 1 | 2 | OK |
| cto (phua@) | 39 | ✓ / ✓ / — | 4 | seen, **Restricted** | seen, 2 refs | 1 | 2 | OK |
| cco (sandra@) | 47 | ✓ / — / ✓ | 4 | seen, injury shown | seen, 2 refs | 1 | 2 | `PERMISSION_DENIED|module.safety.edit` |
| gm (vince@) | 22 | ✓ / — / — | 4 | seen, **Restricted** | seen, 2 refs | 1 | 2 | `PERMISSION_DENIED|module.safety.edit` |

Every real role can read incidents (each holds `module.processing.view`, so each received `module.safety.view`); recording is admin · cto · warehouse;
injury details follow `data.view_health` exactly (admin · cfo · finance · cco among these seven; hr holds it but no real account is hr).

## §7 · Pages (route → file)

| Route | File | New / changed |
|---|---|---|
| `/safety/incidents` | `app/safety/incidents/page.tsx` (+ `IncidentsTable.tsx`, `SafetySettingsPanel.tsx`, `neaStatus.ts`) | new |
| `/safety/incidents/new` | `app/safety/incidents/new/page.tsx` (+ `IncidentForm.tsx`) | new |
| `/safety/incidents/[id]` | `app/safety/incidents/[id]/page.tsx` (+ `IncidentUpdatesPanel.tsx`, `IncidentBatchesPanel.tsx`) | new |
| `/operation/handovers/new` | `app/operation/handovers/new/page.tsx` · `NewHandoverForm.tsx` · `app/operation/handovers/actions.ts` | changed (cite incidents) |
| `/operation/handovers/[id]` | `app/operation/handovers/[id]/page.tsx` | changed (cited incidents) |
| `/operation/balance` | `app/operation/balance/page.tsx` (+ `lib/balanceEmptyState.ts`) | changed (F14) |
| `/operation/equipment/[id]` | `app/operation/equipment/[id]/page.tsx` (+ `app/components/safety/LinkedIncidents.tsx`) | changed (linked incidents) |
| `/inbound/[id]/edit` · `/output/[id]/edit` | `app/inbound/[id]/edit/page.tsx` · `app/output/[id]/edit/page.tsx` | changed (linked incidents) |
| `/quality/ncr/[id]` | `app/quality/ncr/[id]/page.tsx` | changed (the incident it came from) |
| `/settings/dictionaries` | `app/settings/dictionaries/page.tsx` · `registry.ts` · `actions.ts` | changed (incident kinds, code lock) |
| `/settings/pending-values` · home | `pending_values` · `operations_now` (views) · `lib/reminders.ts` | changed (V19 row; two reminder arms) |

## §8 · Decisions taken without asking

1. **Safety is a 10th top-level module** (after Operation), with its own codes — not a page under Operation; the codes already said "safety".
2. **Injury fields cannot be corrected** — the seven correctable fields (kind, time, what happened, immediate action, responsible name, duration,
   reportable) carry no health data, so the masking never has to follow a value into `incident_updates`. A wrong injury detail is a new incident note
   today; registered by being stated here.
3. **Closing does not clear the NEA reminders** — a closed reportable incident still reminds until the notification and the report are recorded.
4. **F12 uses the mirror's full sentence** (extracted from the mirror by the builder, not retyped), so live and a rebuild agree byte for byte.
5. **The injured employee's own page**: someone without `module.safety.view` who is the injured employee gets a self-only view of that incident (and is
   refused every other), rather than a refusal of their own injury record.
6. **`incident_report_due.item_date` falls back to the incident date** when the deadline is not set or cannot be computed (the home page computes "days
   waiting" from `item_date` and every other arm has one); `doc_kind` carries the deadline state so the card never presents the incident date as a
   deadline.
7. **The seeds of `incident_kinds` and `safety_settings` are not change-logged** — they are inserted before their bindings exist, like every earlier
   seeded dictionary. The migration logged 19 rows on live (12 grants, F12, the two codes and one description, three registry rows); its in-transaction
   proof pins the 13 of `role_permissions` + `material_kinds`.
8. **`shift_handover_incident_refs` is written only through `submit_shift_handover`** (`REVOKE ALL` then `GRANT SELECT`), like the equipment refs.
9. **`incident_people` view** (code and preferred name only, gate `module.safety.view`) for the employee pickers on the incident form —
   `employees`' row policy needs an HR code the recorder does not hold, and widening `employees` reads would expose far more than a name.
10. **New views revoke the platform's default write grants** (`REVOKE ALL … FROM authenticated, anon; GRANT SELECT`) — owner-rights simple views are
    otherwise writable through; the wider finding is registered (`MES7B1-VIEW-DEFAULT-WRITE-GRANTS`, one view probed, not exploitable there).
11. **A superseded run event cannot be cited** (`INCIDENT_RUN_EVENT_CORRECTED|<correction>`) — a withdrawal or correction is another row
    (`corrects_id`), so "not withdrawn" alone would have accepted the original of a corrected event.
12. **The deadline counts from the incident date in Singapore**, and `business_days_after` returns NULL ("cannot compute") when any calendar year it
    crosses has no active SG holiday — no date rather than a date that ignores holidays; bounded at 3,660 steps.
13. **Location suggestions use net stock at that location up to the incident moment** (receipts, transfers, consumption), with no invented time window;
    machine suggestions use committed runs whose `[started_at, ended_at)` contains the moment.
14. **F13 scope**: the two named checks plus `check-i18n`'s `sqlEnumAnywhere` and `sqlCheckIn` switched (4); the Python reader registered, not ported.
15. **The local harness for the layout survey and F14** (no live data exists for these pages); the live proof used a throwaway with every code for the
    scenery (receipts, an output batch), never a real account.
16. **The NCR source `inspection` is left as it was** (reserved; 7b-2's question) and incoming inspection registered as unbuilt.
17. **The dry-run defect** (decision recorded because it changed the builder after the offline gate): the F12 extractor fix touched only the builder;
    no mirror changed, so the offline gate and the injection runs stand.

## §9 · Closing live readings

Read **2026-10-16 16:45:58 CST** with the same file (`READ_OWN_EXIT=0`, `postgres`, base tables). Differences from §1, line by line — and
nothing else differs:

| What | Opening → closing |
|---|---|
| Safety codes | 0 → **2**; holders `module.safety.view` = admin · auditor · cco · cfo · cto · finance · gm · operations · warehouse, `module.safety.edit` = admin · cto · warehouse; catalogue 79 → 81 (module 32 → 34) |
| Role code counts | admin 79 → 81 · auditor 20 → 21 · cco 46 → 47 · cfo 33 → 34 · cto 37 → 39 · finance 42 → 43 · gm 21 → 22 · operations 15 → 16 · warehouse 29 → 31 · hr, procurement, sales unchanged — **`role_permissions` md5 without the safety codes unchanged `c4a18882…`**: roles changed only by the safety grants |
| Incident objects | tables: `incident_batches` · `incident_kinds` · `incident_updates` · `incidents` · `safety_settings` + `shift_handover_incident_refs`; document types 59 → 60 (INC 1); masked views 38 → 39; NCR source CHECK + `incident`, plus `nonconformance_reports_incident_source`; public tables 299 → 305 |
| F12 | the `spare_part` note is the mirror's sentence; `material_kinds` md5 `0acf0d80…` → `14857b50…` (that one note) |
| Created on live by this session | the seven kinds, V19 = 2 unconfirmed, the twelve grants and two codes, the F12 note — **no incident, update, link, handover reference or NCR** (all 0), `require_calibrated_since` NULL |
| Unchanged | approvals ON (finance / cfo / 1,000) · 7 accounts, 0 disabled, same roles · pending: CLM-2026-0004 only (as this reading counts them) · throwaways 0 / 0 · **COD-2026-0001 and -0002: recorded sha256, snapshot md5 and stored bytes (34,701 / 34,746) identical** · journal 83 / 186 and its md5 · batches 24 and md5 · movements 107 and md5 · safety-state rows 1 · downtime 1 and md5 · run events 0 · handovers 0 · employees 22 · locations 4 · holidays |
| Reconciliation (tim@) | **AP 422,188.32 / 381,604.42 / 0.00 · AR 57,545.87 / 43,002.12 / 0.00 · 1200 61,387.92 / 172,403.48 / 0.00 · 1220 134.86 / 388.20 / 0.00** — unchanged |
| change_log | 42,388 → 43,637 (+1,249 rows, seq 46,263–47,605): by table, every throwaway table INSERT = DELETE (roles 16 / 16, user_roles 16 / 16, employees 6 / 6, contracts and their five term tables, performance reviews, one COD verification failure — the smoke's and the proof's own scratch); `role_permissions` 567 INSERT / 555 DELETE = **+12, the safety grants**; and the migration's other rows (permissions 2 + 1, material_kinds 1, three registry rows). No row on any table I did not create or the migration did not change |

The dry run's pending-document list named more documents than this reading counts (stocktakes ST-2026-0082…0089 and MC-2026-0001 raised by colleagues
during the day, each with an eligible decider other than its submitter — the migration's own check); none is mine.

## §10 · Registered

`docs/known-issues.md`: `MES7B1-ALARM-TRANSFORM-WAITS-FOR-FORMAT` (D8) · `MES7B1-INCOMING-INSPECTION-UNBUILT` · `MES7B1-PY-ROLE-LIST-READER` (F13) ·
`MES7B1-VIEW-DEFAULT-WRITE-GRANTS`; closed: `MES7A2-ENUM-PARSERS-STOP-AT-A-COMMENT` (F13) · `MES7A2-SPARE-PART-NOTE-LIVE-STALE` (F12) ·
`MES7A2CO-ROLLFORWARD-HIDDEN-WITHOUT-RUNS` (F14); `MES7A2CO-NO-CHART-OF-ACCOUNTS-PAGE` stays (not folded in). `docs/mes-pending-values.md`: V19.
`docs/role-matrix.md`: the two codes. `docs/change-log.md` §29. `docs/forward-queue.md` item 53; MES group row 12 → 12a closed, **MES-7b-2 next**.

## §11 · The window

Start **2026-10-16 15:49:13 CST** (measured, `db/migration-windows.tsv`). End: Tim's reading of the Vercel deployment of the pushed commit — this
process does not query it (AGENTS.md). **What is broken in the window (derived, not measured on live):** nothing in use — the old app neither reads nor
writes the new tables; `open_ncr`, `ncr_open_internal` and `submit_shift_handover` gained a trailing defaulted parameter (DROP + CREATE), and the old
app's named-argument calls without it still resolve; the role pages show the two new codes with their names.
