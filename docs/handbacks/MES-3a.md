v1.4.39 — Storage safety: receipts are now checked against the licence's storage ceiling for each NEA waste category (refused when over, recorded when no ceiling is set yet); swollen or leaking batteries can only be received or moved into a location marked as quarantine; each safety state shows how long it has been on site and warns when its period passes; safety-state history is kept with who ended each state and why; and the receipt page shows any change to its weighbridge ticket's net weight. Note: no quarantine location is marked yet, so swollen or leaking deliveries are refused until one is.

# MES-3a — storage safety (MES group, third cut; 2026-10-06 → 07)

Tim answered MES-3a Step 0 on 2026-10-06: every recommendation for Q1–Q33 in `docs/surveys/MES-3a/STEP0-HANDBACK.md` accepted exactly
as stated; rulings 1–5 in its §0 stand; all MES-0, MES-1 and MES-2 rulings stand as amended; the scope changes reported there accepted.
Migration `db/migrations/2026-10-06-mes3a-storage-safety.sql` (built from the mirrors by `db/scripts/build_mes3a_migration.py`).

---

## §1 · Role-by-role reading table (live, measured)

`db/scripts/2026-10-06-mes3a-live-role-table.sql`, run 2026-10-07 on live as `postgres` inside **one transaction that ends in ROLLBACK**
(`ROLES_OWN_EXIT=0`). It first creates, as real accounts through the real functions, what the three pages read — an NEA category and a
5 t ceiling for it under the licence in force (admin@), a categorised receipt carrying an open "water-exposed" state and a second receipt in
a normal location that is then recorded "swollen or leaking" (fusheng@), a normal location (admin@) — then reads each page's sources and
gates as each of the 7 real accounts (`SET LOCAL ROLE authenticated` + that account's JWT, which is what PostgREST does per request).

| account | role | `/inventory/storage-safety` | ceiling rows | dwell rows | quarantine rows | batch page | state rows | ceiling record | end a state | location editor | mark quarantine | `quarantine_required` reminder |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| admin@swm-os.test | admin | yes | 2 | 2 | 1 | yes | 2 | within, within | yes | yes | yes | 1 |
| chooer@evoltrya.test | finance | yes | 2 | 2 | 1 | yes | 2 | within, within | yes | yes | yes | 1 |
| fusheng@evoltrya.test | warehouse | yes | 2 | 2 | 1 | yes | 2 | within, within | yes | yes | yes | 1 |
| phua@evolytra.test | cto | yes | 2 | 2 | 1 | yes | 2 | within, within | yes | yes | yes | 1 |
| sandra@evoltrya.test | cco | yes | 2 | 2 | 1 | yes | 2 | within, within | yes | yes | yes | 1 |
| tim@evoltrya.test | cfo | yes | 2 | 2 | 1 | yes | 2 | within, within | no (shown, disabled) | yes | no (shown, disabled) | 1 |
| vince@evoltrya.test | gm | yes | 2 | 2 | 1 | yes | 2 | within, within | no (shown, disabled) | yes | no (shown, disabled) | 1 |

How each cell was read: page / editor = `has_permission('module.inventory.view')` (the page's `requireModule`); ceiling rows = rows of
`storage_ceiling_status` (the category row + the licence-total row); dwell / quarantine rows = rows of `safety_state_dwell` /
`quarantine_exposure` for the two probe batches; batch page = `module.inbound.view`; state rows / ceiling record = the base tables
`inbound_batch_safety_states` / `receipt_ceiling_checks` under RLS; end a state = `module.inbound.edit`; mark quarantine =
`module.inventory.edit` (what `save_storage_location` requires); reminder = rows of `operations_now`. Q32 confirmed: all seven hold
`module.inventory.view`. No grant changed in this cut.

---

## §2 · Every item built

**Tables (3 new):** `nea_waste_categories` (seeded **empty**; V29) · `licence_storage_limits` (licence × category, `limit_tonnes > 0`, one per
category) · `receipt_ceiling_checks` (one row per receipt and per manual output batch, five outcomes, **append-only** — UPDATE, DELETE and
TRUNCATE refused by a statement-level guard).

**Table changes (5):** `materials.nea_waste_category_code` · `storage_locations.is_quarantine` (default false) ·
`inbound_safety_states.dwell_warning_days` (V3) and `.requires_quarantine` (V4; seeded swollen/leaking = true, discharged = false, others empty) ·
the two safety-state fact tables re-keyed with history (`id`, `ended_at`, `ended_by`, `end_reason`, `ended_by_run_id`, plus
`created_by_run_id` and `reopened_from_id`; one open row per batch × state; a guard refuses delete, rewrite, a second close and a blank reason;
the direct INSERT / DELETE policies dropped) · `inventory_movements` loses its direct INSERT policy and refuses a direct write
`MOVEMENTS_THROUGH_FUNCTION_ONLY` (Q3).

**Functions:** new `storage_licence_in_force` · `quantity_in_tonnes` · `receipt_ceiling_check_internal` · `assert_quarantine_landing` ·
`set_output_safety_states` · three guards. Changed: both receipt functions and `create_output_batch` (ceiling check; receipts also the
quarantine gate) · `create_stock_transfer` (quarantine gate on the in-leg) · `set_inbound_safety_states` (a diff: adds and ends only what
changed; reason required on un-tick) · `commit_processing_run` (ends resolved states naming the run; records what it writes) ·
`rollback_processing_run_internal` (Q2: ends what the run wrote, re-opens what it ended) · `assert_receipt_reading_calibrated` (ruling 1) ·
`save_storage_location` (quarantine flag) · `processing_inputs`' guard and `processing_wip` read only open states · `trail_subjects`,
`trail_subject_members`. Dropped (Q11): `licence_storage_within_limit`, `hazardous_qty_on_hand_tonnes`; fixture 152 rewritten.

**Views:** new `nea_category_on_hand_all` (base, unreadable by clients) · `storage_ceiling_status` · `safety_state_dwell` ·
`quarantine_exposure`. `operations_now` +3 arms (52 → **55**): `storage_ceiling_exceeded`, `safety_state_dwell`, `quarantine_required`.
`pending_values` +5: **V2, V29, V3, V4, V34** (rows in `docs/mes-pending-values.md`).

**Fold-ins:** ruling 1 (an out-of-calibration reading always refuses pricing, its preview and `issue_cod`; the switch governs only the two
"not recorded" codes) · ruling 2 (each share on the receipt page shows "Ticket now: net · all shares · difference", amber when the difference
is not 0) · ruling 5 (`ingest_process_pending` header comment) · Q2 · Q3. Pricing (Q28): no grant change — proven live (§5.1 ⑤).

**App:** the new page; the nine changed pages (§3); the audit trail (ceilings under the licence, the arrival check under each batch, the
category dictionary as a subject, "Safety state recorded · ended (with reason) · reopened by a rollback"; `check-trail-wording` arm ⑰);
three reminders; English and Chinese for everything (Q26 / Q27 wording verbatim).

---

## §3 · Pages — every new or changed route, with its file

| route | what changed | files |
|---|---|---|
| **`/inventory/storage-safety`** (new) | ceilings per NEA category + licence total under today's licence; open states on site with days and period; stock that should be in quarantine; a line naming how many quarantine locations exist | `app/inventory/storage-safety/page.tsx`, `StorageSafetyTables.tsx`; registry `lib/modules.ts` |
| `/purchasing/licences` | a ceilings panel per waste-disposal licence (one field per NEA category; blank = "Not yet set"); the licence's own limit described as the total | `app/purchasing/licences/page.tsx`, `StorageLimitsPanel.tsx`, `licenceActions.ts`, `licenceErrorCodes.ts` |
| `/settings/dictionaries` | a number field kind; dwell warning days and requires-quarantine on intake safety states (shown in the table, blank = "Not yet set"); the NEA category dictionary; its trail | `app/settings/dictionaries/registry.ts`, `DictSection.tsx`, `actions.ts`, `page.tsx` |
| `/materials/new`, `/materials/[id]/edit` | NEA waste category picker ("Not yet set" by default) | `app/materials/NeaCategoryPicker.tsx`, `neaCategoryOptions.ts`, `neaCategoryQuery.ts`, `app/materials/new/{page,actions,NewMaterialForm}.tsx/ts`, `app/materials/[id]/edit/{page,actions,EditMaterialForm}.tsx/ts`, `materialErrorCodes.ts` |
| `/inventory/locations`, `/inventory/locations/new`, `/inventory/locations/[id]/edit` | "Quarantine location" checkbox; a Quarantine column | `app/inventory/locations/{page,LocationsTable,LocationForm,actions}.tsx/ts`, `new/page.tsx`, `[id]/edit/page.tsx` |
| `/inbound/new`, `/inbound/receive` (receipt forms ×2) | the new refusals (`QUARANTINE_LOCATION_REQUIRED`, `STORAGE_CEILING_EXCEEDED`, `STORAGE_CEILING_UNIT_NOT_CONVERTIBLE`) read as sentences; the outcome is shown on the receipt page | `app/components/inventory/stockErrorCodes.ts` (the forms' actions already route through it) |
| `/inbound/[id]/edit` | intake panel: un-ticking asks for a reason; safety-state history with the dwell line and the quarantine banner; the ceiling outcome; the ticket line (ruling 2) | `app/inbound/[id]/edit/{page,IntakeConditionPanel,intakeConditionActions,TicketSharesPanel}.tsx/ts`, `app/components/safety/{SafetyStateHistory,CeilingCheckPanel}.tsx` |
| `/output/[id]/edit` | safety panel writes through `set_output_safety_states`; "End <state>" with a reason; history, dwell line, banner; ceiling outcome | `app/output/[id]/edit/{page,SafetyStatePanel,safetyActions}.tsx/ts`, the two shared components |
| `/operation/calibration` | ruling 1 wording (Q26) | `app/operation/calibration/page.tsx`, `messages/{en,zh}.ts` |
| `/settings/pending-values` | V2, V29, V3, V4, V34 | `messages/{en,zh}.ts` (the page itself unchanged) |
| home / reminders | three arms | `lib/reminders.ts`, `docs/dashboard-arm-inventory.md` |

---

## §4 · Verification, in the brief's order

| # | step | result | log |
|---|---|---|---|
| 1 | offline gate | `GATEOFF_EXIT=0`, 68 s | `~/mes3a-work/logs/gate-offline.log` |
| 2 | backup | `BACKUP_EXIT=0` — `evoltrya-backup-2026-10-07-0002.dump`, 6.3 MB, 7,812 TOC entries (previous 7,635; floor 6,871); started 00:02, done 00:27. Applied at 09:04, so I re-read live first: `change_log` 10,142 rows / max seq 11,375, identical to the before readings — nothing had moved since the backup | `backup.log` |
| — | dry run of the migration **file** (COMMIT → probe + ROLLBACK, grants replay included) | first run **red** in the migration's own proof block (`column reference "k" is ambiguous` — the temp table's column vs a PL/pgSQL loop variable); fixed in the builder (aliased), rebuilt, re-run `DRY_OWN_EXIT=0` (new functions 3/3, new tables 3/3). The fix touched only the proof block, not a mirror, so the offline gate stands | `dryrun.log` |
| 3 | apply_migration | `APPLY_OWN_EXIT=0`; preflight's two warnings are the two intended drops (Q11). **Window start 2026-10-07 09:07:01 CST** (`db/migration-windows.tsv`) | `apply.log` |
| 4 | generate types | after the migration's `NOTIFY pgrst` + 25 s; new objects present, dropped functions absent | `types.log` |
| 5 | tsc | first run 1 error (`.eq()` on a column picked at runtime from two tables) → split per table → `TSC_EXIT=0` | `tsc.log` |
| 6 | build | first run: deep-route list stale → `gen-deep-routes --write`; second: `check-date-null-preserved` caught `formatDate(s.ended_at)` on a nullable → guarded; third `BUILD_OWN_EXIT=0` | `build.log` |
| 7 | full gate | `GATE_EXIT=0`, 398 s — rebuildable ✓ · mirrors vs live ✓ · fixtures ✓ (251 ✓) · anon surface ✓ (baseline 328) | `gate-full.log` |
| 8 | i18n | `I18N_EXIT=0` — every key in en and zh; 240 dynamic prefixes all enumerable | `i18n-final.txt` |
| 9 | error swallowing | `SWALLOW_EXIT=0` | `swallow.txt` |
| 10 | layout survey, 14 pages (the 10 static routes of §3 + a receipt with a live state, an output batch with a live state, a material, a location) | **390 px 14 / 14 usable**, **1280 px 14 / 14 usable** (`SURVEY_EXIT=0` ×2); `.next` removed before each | `survey390.log`, `survey1280.log` |
| 11 | smoke | `SMOKE_EXIT=0` — 268 ok, 10 skipped (no data), **0 failed**; 09:25 → ~09:41 | `smoke.log` |
| 12 | live verification | §5 | |

**Scratch cleanup reading (step 11).** `check:scratch` before and after the smoke reads the **same six** stale rows, all weeks old and none
from this session: materials `ZZ-SMOKE-PROBE` (1,477 h, referenced by 1 inbound batch), `ZZ-SMOKE-M25` (1,477 h, 1 inbound + 2 output),
`ZZ-SMOKE-NTF` (1,309 h, 2 inbound), supplier `ZZ-SMOKE-S25` (1,477 h, 1 inbound), customer `ZZ-SMOKE-CJK` (834 h, unreferenced), inbound
batch `ZZ-SMOKE-IB25` (1,477 h, 1 processing input). Reported, not removed (the check's rule). The smoke's own throwaway account, role and
grants were removed: after it, live has 7 accounts, 0 throwaway, 0 grants without an account.

**Security proof — fixture 251, 11 arms** (PV · CEIL · TOTAL · UNIT · EXCEEDED · DWELL · QUAR · HIST · RUN · MOVE · TICKET), each
fault-injected: `db/scripts/2026-10-06-mes3a-fixture-injections.py`, 39 cases, every one red in its named arm (`INJECTIONS_OWN_EXIT=0`).
Fixture 250's GATE arm rewritten for ruling 1, with its MES-2 injections re-pointed (42 cases, exit 0). **Two concurrent receipts:**
`db/scripts/2026-10-06-mes3a-ceiling-concurrency.py` on a throwaway rebuild — with the locks, the second receipt waited for the first and
was then refused (`CONC_OWN_EXIT=0`); with the two `FOR UPDATE`s removed, both committed (6.4 t against a 5.7 t ceiling), so the lock is
what keeps the second one out. Fixture coverage against the brief: each outcome (within · ceiling_not_set · category_not_set ·
licence_not_in_force · unit_not_convertible) and the refusal on both receipt functions and `create_output_batch`; the licence total;
`storage_ceiling_exceeded` after processing and after a lowered ceiling; dwell (clock stable across saves, the per-state line,
`safety_state_dwell`, "Not yet set"); quarantine (receipt and transfer refused, into quarantine always allowed, recording on placed stock
flagged not refused, next move restricted); history (add/close only what changed, reason on un-tick, delete refused, close once, a run's
close and a rollback's re-open); Q2; Q3; ruling 1 (out-of-calibration refused by pricing, its preview and `issue_cod` with the switch NULL;
the two "not recorded" codes only on or after the switch date); ruling 2 (the TICKET arm proves the line's data — after a gross weighing is
corrected, `weighbridge_ticket_weights` reads net 7,900 and difference −100; the amber styling when the difference ≠ 0
(`data-ticket-now="differs"`) is in the component and is **not** exercised by a fixture — live has no ticket, so no page shows it yet);
V2 · V29 · V3 · V4 · V34.

---

## §5 · Live verification

### §5.1 · Rolled-back proofs — `db/scripts/2026-10-06-mes3a-live-proof.sql` (`PROOF_OWN_EXIT=0`, one transaction, ROLLBACK)

The live waste-disposal licence **WDL-21-2-5380 is already in force today** (2026-07-01 → 2028-09-01). It is a pre-existing document, so it
was **read, not edited**: no period was set on it; the ceiling was a new `licence_storage_limits` row under it, inside the rollback.

| cell | who | action | result |
|---|---|---|---|
| ① | admin@ | NEA category `ZZP3A`; ceiling 2 t under WDL-21-2-5380 | — |
| ① | fusheng@ | receive 1,000 kg of a `ZZP3A` material | `within` (0 t on site before · limit 2 t · licence total 500 t) |
| ① | fusheng@ | receive 1,500 kg more | `STORAGE_CEILING_EXCEEDED\|WDL-21-2-5380\|ZZP3A\|1.000\|1.500\|2` |
| ① | fusheng@ | receive 100 kg of a material with no category | `category_not_set` |
| ② | fusheng@ | swollen/leaking into a normal location | `QUARANTINE_LOCATION_REQUIRED\|swollen_leaking\|ZZ-PROBE-MES3A-N` |
| ② | admin@ → fusheng@ | mark `ZZ-PROBE-MES3A-Q` quarantine; receive 50 kg swollen/leaking into it | received |
| ② | fusheng@ | transfer 20 kg of it to the normal location | `QUARANTINE_LOCATION_REQUIRED\|swollen_leaking\|ZZ-PROBE-MES3A-N` |
| ③ | fusheng@ | add "water-exposed" | dwell line: 0 days · period Not yet set · `not_set` |
| ③ | — | period 1 day (set in the transaction), save again | same row, recorded time unchanged; 0 days · period 1 · `within` |
| ③ | fusheng@ | un-tick with no reason | `SAFETY_STATE_END_REASON_REQUIRED\|water_exposed` |
| ③ | fusheng@ | un-tick with a reason | row kept: ended by fusheng@ · "MES-3a live proof: dried and re-inspected" |
| ⑤ | chooer@ (finance) | price my own receipt at 2 SGD/kg | a request, `submitted` |
| ⑤ | tim@ (cfo) | approve | `approved`, unit price 2.0000 posted. The receipt has no weighing and the switch is empty: **not refused** (ruling 1) |
| ④ | fusheng@ | discharge run on that receipt | "discharged" open, owned by the run; "charged" ended "resolved by processing run PROC-…" |
| ④ | fusheng@ submits rollback · tim@ approves | | run `reversed`; "discharged" ended "undone by rollback of PROC-…: MES-3a live proof: wrong batch"; "charged" re-opened with its original recorded time |

The codes the proof printed (IN-2026-0480–0484, PROC-2026-0714) were taken from sequences and are not returned on rollback — the house
numbering already has gaps by design (live's highest receipt is IN-2026-0322); no document carries them.

### §5.2 · Read-only

- **A receipt made today would record `category_not_set`:** licence in force today = WDL-21-2-5380; NEA categories 0; materials with a
  category 0 → `receipt_ceiling_check_internal` reaches its category branch.
- **`/settings/pending-values` shows V34:** read as fusheng@ (warehouse) — one row, V34 · Quarantine location · `/inventory/locations`. As
  admin@: V29 ×1, V3 ×5, V4 ×3, V34 ×1. V2 has no rows because there is no category yet (it lists licence × category).

### §5.3 · Before and after

Before: 2026-10-06 21:19:26 (`~/mes3a-work/logs/before.txt`); after: 2026-10-07 ~09:50 (`after.txt`, `after-mes3a.txt`); same query
(`db/scripts/2026-10-06-mes1-live-readings.sql`, row count + digest of every public base table, as `postgres`) plus
`db/scripts/2026-10-06-mes3a-live-readings.sql`.

- **250 tables identical.**
- The five altered tables, recomputed over their **pre-MES-3a columns**: `materials` 9 · `storage_locations` 4 · `inbound_safety_states` 5 ·
  `inbound_batch_safety_states` 1 · `output_batch_safety_states` 1 — **all five digests equal to before**. Their new columns: no category,
  no quarantine flag, no dwell period, `requires_quarantine` as seeded (swollen = true, discharged = false, others null); the two live state rows
  are still open with their own recorded time.
- `document_type_exceptions` 37 → 38: the migration's one row (`nea_waste_categories`). The three new tables: 0 rows each.
- `cod_verification_failures` 1 → 1, digest changed: it is the public verification page's failure budget, not a document; the smoke's
  `/verify` probe (09:39:30) rotated its single row (one DELETE + one INSERT in the change log).
- `change_log` 10,142 → 10,650 (max seq 11,375 → 12,048): the migration's 3 rows, and the smoke's own setup and teardown, balanced
  (roles 3/3, user_roles 3/3, employees 7/7, role_permissions 225/225, performance_reviews 3/3, contracts and their 6 child tables 1–2 each
  way) plus the budget row above. Nothing of mine remains.
- **Nothing set by this cut:** categories 0 · ceilings 0 · ceiling records 0 · dwell periods 0 · quarantine locations 0 ·
  `require_calibrated_since` NULL.
- **Accounts:** 7, 0 disabled, 0 throwaway, roles unchanged (admin · finance · warehouse · cto · cco · cfo · gm); approvals ON;
  0 grants without an account.
- **Pending documents:** 1, CLM-2026-0004 1,000.00 — unchanged; its decider (tim@) is not its submitter. I leave no pending document.
- **Reconciliation** (as tim@): AP list 422,188.32 / ledger 381,604.42 / **unexplained 0.00**; AR 57,545.87 / 43,002.12 / **0.00** —
  identical to before.

### §5.4 · Broken window

Start **2026-10-07 09:07:01 CST** (measured, `db/migration-windows.tsv`). End = the moment Tim sees the deployment succeed on Vercel
(a report from Tim, to be recorded at the next close-out). **Closed at the close-out (2026-10-07):** end between **09:49:19** (measured,
the push in `git reflog … refs/remotes/origin/main`) and **10:08:13** (the close-out's first command, holding Tim's "deployed" — a report,
not a Vercel reading) → **42 min 18 s – 1 h 01 min 12 s**; `docs/forward-queue.md` item 38. Everything from step 4 on ran inside the window. What is broken in it
(**derived**, Step 0 Q33, not measured on live): the output batch page's safety panel cannot add or end a state (the old page wrote
directly; the policies are gone); the intake panel cannot un-tick a state (the old page sends no reason); new refusal codes show raw on the
old pages. Nothing else.

---

## §6 · Decisions taken without asking

1. **Two extra columns on the safety-state tables:** `created_by_run_id` and `reopened_from_id`. Q22 listed five; a rollback can only undo
   exactly what its run did (Q2) if the run's own rows are marked, and a re-opened row says which one it replaces.
2. **The outcome is judged by the category ceiling; the licence total is checked too and recorded in `total_*`.** Over the total refuses
   with category `*`.
3. **The check runs after the receipt's INSERT** (the batch's own movement is already counted) and locks the licence row and the limit row
   (`FOR UPDATE`) before reading on-hand — READ COMMITTED gives each statement a fresh snapshot, so the waiter sees the first receipt.
4. **`receipt_ceiling_checks` is append-only by a statement-level guard** (UPDATE / DELETE / TRUNCATE): a row-level one let an RLS-filtered
   UPDATE "succeed" on zero rows (the SILENT-1 family). The fact-table guard is statement-level for the same reason.
5. **The concurrency proof is a script on a throwaway rebuild, not a fixture** — it needs two connections; it refuses any supabase/pooler DSN.
6. **`storage_licence_in_force` is SECURITY DEFINER and on the B2 allowlist** (both `db/check_mirrors.py` and `db/verify_rebuild.py`): owner
   views call it as the reader, and function EXECUTE is not covered by owner rights (AGENTS.md).
7. **The dwell line does not say who recorded the state;** the audit trail at the foot of the page does.
8. **Ceilings are offered only on waste-disposal (gwdf) licences** — the only type `storage_licence_in_force` reads.
9. **`save_storage_location`'s new `p_is_quarantine` defaults NULL = keep** on update (false on create), so older callers cannot clear it.
10. **V29's material rows** count only materials of a battery kind (`material_kinds.has_condition_axes`) and appear only once a category exists
    (before that, the one "no categories" row says it).
11. **Fixture 114 F3** (it deleted a state to set up a failure) now proves the delete is refused, and its half-failure call passes a reason.
12. **The arrival check is a trail member of `output_batch` with `home = false`** (its home subject is the inbound batch).
13. **Ruling 2 reuses the weighbridge panel's keys** plus the one new key Q27 specified.
14. **The MES-2 injection script's GATE cases** were re-targeted for ruling 1 (names and targets), and one new case added (§7 of Step 0).
15. **`trail_prelog_sources` unchanged**, though Step 0 §6 said it would gain the ended stamp: the prelog only rebuilds events from before the
    change log began, and a state can only be ended from MES-3a on — when the log already records every close — so such a stamp row would
    always be skipped.
16. **"Safety state recorded / reopened" are key events on the trail.** Before, a state was only ever added alongside a receipt; now a save
    adds one on its own, and a block with no lines and `key: false` was being dropped to the generic "edited" sentence.
17. **The live licence was not edited** for the ceiling proof (§5.1): it is already in force, so "set an in-force licence period" needed no
    change; the ceiling was added under it, inside the rollback.
18. **Wording I wrote** (Q26/Q27 texts are verbatim): the storage-safety page, the ceiling sentences, the history lines, the end-reason
    dialog, the error texts, and the "supplied by" lines of V2–V34 (taken from Step 0 §11). `calibration.requireSince` (listed in §7, no text
    given in Q26) now reads "Refuse missing instruments and weighings from". The quarantine refusal does not print the raw state code.
19. **The old `materials.errors.inbound_batch_safety_states_pkey` message was removed** — that constraint now names the id; the duplicate is
    `<table>_open_once`, with its own message.
20. **A defect found by the dry run was fixed in the builder** (§4), and the migration rebuilt before apply.

---

## §7 · Assertions measured and found false or imprecise

1. **Step 0 §6: "`trail_prelog_sources.sql:65-66` gains the ended stamp."** Not needed — §6 item 15.
2. **The brief's "set an in-force licence period".** The only waste-disposal licence on live is already in force today (read, §5.1).
3. **The earlier copy of the migration file** predated the statement-level guard fix (it still had row-level and separate delete triggers on
   `receipt_ceiling_checks`); the fixtures had been right because the gate builds from the mirrors. Rebuilt before the dry run.

---

## §8 · Docs updated

`docs/forward-queue.md` (item 38: MES-3a closed; MES-3b next) · `docs/mes-pending-values.md` (V2, V29, V3, V4, V34) · `docs/change-log.md`
(§14: safety-state history, the calibration rule as restored; §13's ruling marked landed) · `docs/role-matrix.md` (§8 storage-safety row —
no grant change) · `docs/known-issues.md` (PROC-3 §1 closed; MES3A-QUARANTINE-PATHS-THAT-CANNOT-REFUSE, MES3A-CEILING-ONLY-CATEGORISED,
MES3A-CEILING-PROCESSING-OUTPUTS) · `docs/dashboard-arm-inventory.md` (M3a–M3c) · `docs/handbacks/MES-2.md` (the pricing line corrected in
place, Q28).
