v1.4.55 — Inspections and environmental monitoring: the Safety section can now hold inspection checklists, record each inspection (INS-…) item by item with pass, fail or not applicable, and track every finding until it is closed; environmental test results are recorded against their limits, and a result over its limit automatically opens an incident; behind the scenes, database views can no longer be written to, closing a gap that could have let data be changed around its access rules.

# MES-7b-2 — safety inspections and environmental monitoring (MES group, nineteenth cut; 2026-10-16), with F16

Tim's brief of 2026-10-16: close MES-7b-1 out (step 1), then F16 (no view writable), then build MES-7b-2 as ruled in
`docs/surveys/MES-7b/STEP0-HANDBACK.md` (Q13–Q16, Q17, Q19–Q22, Q27 — the 7b-2 half). Migration
`db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql` (4,692 lines, built from the mirrors by `db/scripts/build_mes7b2_migration.py`).

**Opening check.** Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
`c72a86b2403991a62079716d049167663fffd9ca`. Files staged by explicit path only. No git command was refused.

---

## §0 · Step 1 — MES-7b-1 close-out (committed and pushed before step 2)

Commit `c25dc70c` "MES-7b-1 close-out" (docs only), pushed; afterwards `HEAD` = `origin/main` = `git ls-remote` =
`c25dc70c6a0f1e5a0bfd8bd945f8dd9f0a94120a`; fresh-clone build of that commit `CI_OWN_EXIT=0`, `X_OWN_EXIT=0`.

* **Window closed** in `docs/forward-queue.md` item 53: start **15:49:13 CST** (measured, `db/migration-windows.tsv`) · lower bound of the end
  **16:54:08 CST** (measured: the reflog of the push that moved `origin/main` to `c72a86b2`; `08d5fbf8` went out in the same push) · upper bound
  **17:06:06 CST** (derived: the first command of the close-out session, already holding Tim's "deployed" — a relay, not a measurement of Vercel).
  **Window: at least 1 h 04 min 55 s, at most 1 h 16 min 53 s.**
* **a · fixtures**: the 23 items the brief listed, each mapped to its arm with line references
  (`docs/surveys/MES-7b-2/MES-7b-1-CLOSEOUT.md`); re-run on a fresh rebuild: 267 / 263 / 266 green, the MES-7b-1 injection script 50 cells, 0 wrong.
* **b · the deployed app** (`docs/surveys/MES-7b-2/mes7b1-closeout-pages.mjs`, clones of admin · cto · warehouse · cfo · finance, prefix
  `mes7b1probe`): 20 fetches, all 200; "Record an incident" is a link for admin · cto · warehouse and a disabled control naming
  `module.safety.edit` for cfo · finance. **"Restricted"** read on a local rebuild with MES-7b-1's seed (`mes7b1-closeout-local.mjs`, 35 fetches, all
  200): cto and warehouse read 5 × "Restricted" on the injury incident and no injury text; the handover form offers the incidents and the handover page
  names the one it cites; the pending-values page lists V19 as unconfirmed for all five.
* **c · decisions**: MES-7b-1 §8's 17 decision titles listed in the close-out file.
* **Nothing missing, nothing broken**, so step 2 started. One wording weakness recorded (**W7**): V19's "supplier" line opened "Confirmed by Tim
  against the NEA licence." while V19 is unconfirmed — reworded in this cut to "To be confirmed by Tim against the NEA licence." (en and zh).

## §1 · Opening live readings (before anything changed)

Read **2026-10-16 17:15:56 CST** with `docs/surveys/MES-7b-2/live-readings.sql` (read-only, `READ_OWN_EXIT=0`) as `postgres`
(`rolbypassrls = true`, base tables and the catalog); the reconciliations as tim@ (cfo) switched to `authenticated`.

| What | Reading |
|---|---|
| Codes | catalogue **81** (34 module) · `module.safety.view` 9 roles · `module.safety.edit` admin · cto · warehouse |
| Safety objects | incidents 0 · no inspection or environmental table · document types 60 · laboratories 1 (FRL) · NCRs 0 · tasks 20 (3 not deleted, md5 `3e0c3628…`) |
| Views | 187 (181 owner-rights) · write grants: **anon on 110 views** (SELECT on 107), **authenticated on 163** — 273 (view, role) pairs |
| Standing state | approvals ON (finance / cfo / 1,000) · 7 accounts, **0 disabled** — admin@ admin · chooer@ finance · fusheng@ warehouse · phua@ cto · sandra@ cco · tim@ cfo · vince@ gm · role codes admin 81 · auditor 21 · cco 47 · cfo 34 · cto 39 · finance 43 · gm 22 · hr 8 · operations 16 · procurement 16 · sales 17 · warehouse 31 (`role_permissions` md5 `2cf8ce23…`) · `require_calibrated_since` **NULL** · throwaways 0 · pending: CLM-2026-0004 only |
| CODs | COD-2026-0001 sha256 `ba299a4f…f42101`, 34,701 bytes · COD-2026-0002 sha256 `717661f6…13a4f9`, 34,746 bytes |
| Books | journal 83 entries / 186 lines (md5 `d9827dd9…`) · batches 24 (md5 `6f7a7601…`) · output batches 20 (md5 `aa50fafe…`) · movements 107 (md5 `fe4000bb…`) · safety-state rows 1 · downtime 1 · change_log 44,113 (max seq 48,081) · public tables 305 |
| Reconciliation (tim@) | **AP** 422,188.32 / 381,604.42 / **0.00** · **AR** 57,545.87 / 43,002.12 / **0.00** · 1200 61,387.92 / 172,403.48 / **0.00**, reconciled · 1220 134.86 / 388.20 / **0.00**, reconciled |

**Assertions of the brief measured false or imprecise:** zero. (SHA, clean tree, approvals, 7 accounts enabled, `require_calibrated_since` NULL,
the two COD byte strings, no inspection objects on live — each read above.)

## §2 · F16 — no view is writable

**Before (measured on live, 17:22:06–17:22:22 CST, `db/scripts/2026-10-16-mes7b2-view-writes.mjs`, `VIEW_WRITES_EXIT=0`).** One rolled-back
transaction; for each of the 187 views, as `anon` and as a throwaway (`mes7b2probe`) holding no code, a **zero-row** INSERT, UPDATE and DELETE
(`… WHERE false`, so no row is touched; 1,122 attempts, coverage asserted views × 6). A zero-row write that is *accepted* has passed the view's
privilege, updatability and (for owner-rights views) the base table's privilege as the view owner.

| | views accepting a write | INSERT | UPDATE | DELETE | owner-rights among them |
|---|---|---|---|---|---|
| anon | **33** | 33 | 9 | 9 | 33 |
| authenticated | **45** | 45 | 15 | 14 | 45 |
| either | **45** distinct | | | | |

By grant: **273** (view, role) pairs carried a write privilege (anon 110 views, authenticated 163).

**Write paths through a view: 0.** A scan of `app/`, `lib/`, `db/` and `scripts/` for every write (`.insert` · `.update` · `.upsert` · `.delete`, SQL
`INSERT INTO` · `UPDATE` · `DELETE FROM` · `MERGE`) whose target is in the closed set of 187 view names found none; the dynamic targets (the
dictionaries registry, the contract `dbTable`, `master_import_apply`'s tables, fixtures 116 and 234) resolve to base tables only; every raw REST
call to a view is a GET (`scripts/probe-u1a.mjs`); the only rules on views are `pg_catalog.pg_settings`'. The scanner carried two planted positives
(2 / 2 found). So nothing stopped the revoke.

**What was done.** `db/views/zzz_function_grants.sql` gained an F16 block: for every view in `public`, `REVOKE INSERT, UPDATE, DELETE, TRUNCATE`
from `anon`, `authenticated` and `PUBLIC`. The rebuild runs that file last (`db/check_mirrors.py`'s view order now sorts `zzz_*` after every view —
the depth sort had run it before 32 deeper views, leaving them writable on the rebuild), and `apply_migration.sh` replays it inside **every later
migration's own transaction**, so a future view is stripped in the transaction that creates it. `db/gate.py` has a `viewwrite` line on both sides
(red if any view is writable; red if fewer than 100 views are seen — blind is not clean; the rebuild side creates, grants and must catch a probe
view on every run); `GATE_VIEWWRITE_FAULT=grant` turns the offline gate red naming `pending_values:authenticated:insert`. Fixture 268 arm F16 pins it
too (two injection cells).

**After.** The migration's own closing assertion: **0 pairs (192 views)**. Re-measured on live after the migration (19:21:55–19:22:09 CST, same script,
`VIEW_WRITES_EXIT=0`): **anon 0 views, authenticated 0 views accept a write** (refusals: 42501 permission denied 169 · 55000 view not updatable
405 · 428C9 2, per role). The full gate's `viewwrite` line: live 192 views, rebuild 192 views, none writable, self-test bites. The anon surface
(`db/check_grants.py`) is still a subset of its baseline; one baseline line it names as stale (`processing_run_losses`, a **table** anon holds nothing
on) was removed — it was already stale before this cut (named in the MES-7a-2 and MES-7b-1 gate logs), so it is not F16's doing.
`MES7B1-VIEW-DEFAULT-WRITE-GRANTS` closed.

## §3 · What was built

* **No code, no grant, no approval** changed (Q17 · Q18). Read `module.safety.view`; write `module.safety.edit`.
* **Checklists** (`inspection_templates` + `inspection_template_items`, Q13): code (upper-cased, unique), name, area, frequency in days (V18; empty =
  "Not yet set", never due), ordered items, active or not. **None is seeded.** Saved only through `save_inspection_template`; items are realigned by
  position (an unchanged item keeps its row, a changed one is updated, extra ones deleted) — a checklist is never deleted.
* **Inspections** (`inspection_runs` + `inspection_results`, Q13): `INS-YYYY-NNNN`, gapless per year (`next_inspection_code`, own advisory lock).
  Each run copies the checklist's code, name and area and each result copies its item's text, so **editing the checklist never rewrites a past
  inspection**. Every item exactly once: pass, fail or n/a; **a fail needs a note**. Submitted = immutable (`INSPECTION_RECORD_IMMUTABLE`,
  statement-level, owner included). A correction is a new run citing the old one with a reason; a run can be corrected once (correct the correction
  to change it again); the corrected run is unchanged and names its correction.
* **Findings** (`inspection_findings` + `inspection_finding_closures`, Q14): on a failed item only, with corrective action, an owner (an employee)
  and an optional due date; recorded with the run or later (never on a superseded run). Closed by its own row saying what was done
  (`module.safety.edit`). **"Raise a task"** creates a **personal task for whoever pressed it** (needs `module.tasks.view` or `.edit`), titled with
  the run code and the item; the finding links it once. **Closing the task does not close the finding.** The tasks module is unchanged.
* **Reminders** (`operations_now` 68 → **70**): `inspection_due` (an active checklist with a frequency whose last not-superseded run + frequency ≤
  today, or never run) and `inspection_finding_open` (until closed). Both `module.safety.view`; registered in `lib/reminders.ts` and
  `docs/dashboard-arm-inventory.md`.
* **NCR source `inspection`** (Q15): no longer reserved — it **must cite a finding** (`nonconformance_reports.inspection_finding_id` + CHECK
  `nonconformance_reports_inspection_source`; `open_ncr` refuses by name `NCR_INSPECTION_FINDING_REQUIRED` · `_ONLY_WITH_SOURCE` ·
  `INSPECTION_FINDING_NOT_FOUND`). Opened from the finding (`/quality/ncr/new?finding=<id>`, source fixed); the existing quality hold applies.
  `ncr_rows` names the run and item. Incoming inspection at receipt stays unbuilt and is re-registered (it can no longer borrow this source).
* **Environmental monitoring** (`environmental_parameters` + `environmental_results`, Q16): a parameter dictionary in `/settings/dictionaries`
  (code locked once used, unit, limit + basis max / min — paired; **none seeded**, V20). A result: parameter, sample point, sampled on, laboratory,
  report reference, value. The unit and limit are **copied onto the result**; the judgement is exceeds / within / **not judged** (no limit).
  Append-only (`ENV_RESULT_IMMUTABLE`); a correction is a new row with a reason. **An exceedance opens an `emission_exceedance` incident in the same
  transaction** (`record_incident`; occurred at the sampling date's Singapore midnight; what happened written from the result's facts; responsible =
  the recorder); the recorder must answer "reportable to NEA?" and say what was done. A correction that still exceeds points at the same incident.
* **Pending values** (25 → **29** arms): V18 and V20, each **one row on live from day one** (both dictionaries empty), then one row per active item
  without its value. `docs/mes-pending-values.md` updated.
* **Pages**: §8. Safety's module bar lists Inspections and Environment.
* **Trail**: subjects `inspection_run` · `inspection_template` · `dictionary_environmental_parameters` · `safety_environment`; wording arm ㉝.
* **Registries**: document type `INS` (60 → 61) and two document-type exceptions; eight tables bound to the change log (exclusions stay 8); no masked
  column (rules stay 119); search registry 61; document registry 313 tables.
* **Fixtures**: new **268** (REG · F16 · TPL · NUM · RUN · IMMUT · FIND · TASK · CORR · DUE · V18 · ENV · V20 · NCR · TRAIL); 263 gained the
  inspection-source arms (refuse without a finding · only with the source · not found · accept in a rolled-back sub-block asserting the hold and
  `ncr_rows`); count pins moved in 100 · 101 · 111 · 254 (61 document types, 53 declared gates, 70 arms), none weakened.

## §4 · Verification, in the brief's order

| # | Step | Result |
|---|---|---|
| 1 | Offline gate | **`GATE_OFF_OWN_EXIT=0`**, 101 s; fixture 268 ✓; viewwrite rebuild 192 views ✓ (self-test bites) |
| 2 | Backup | **`BACKUP_EXIT=0`**, `evoltrya-backup-2026-10-16-1840.dump`, 8.3 MB, **9,278** TOC entries (previous 9,110), 18:40:57 → 18:56 CST |
| 3 | Dry run on live | COMMIT → ROLLBACK, **`DRY_OWN_EXIT=0`** (18:56:36 → 19:00:06): F16 273 → 0 pairs (192 views), 313 tables; nothing committed |
| 4 | apply_migration | **window start 2026-10-16 19:03:57 CST** (committed; `db/migration-windows.tsv`), **`APPLY_OWN_EXIT=0`**; pre-flight: 16 functions (2 replaced, 14 new), no account code, 1 column added, 0 on masked tables |
| 5 | Types | `NOTIFY pgrst` then `DO_NOT_TRACK=1 npm run types:gen`, **`TYPESGEN_OWN_EXIT=0`**; differs from my pre-window splice only by relationship entries PostgREST infers and `never` on identity columns in `Update`; the generated file is committed |
| 6 | tsc | **`TSC_OWN_EXIT=0`** |
| 7 | build | **`BUILD_OWN_EXIT=0`** |
| 8 | Full gate | **`GATE_EXIT=0`** (650 s) — rebuildability ✓ · mirrors vs live ✓ (NO DIFFERENCES) · fixtures ✓ (268 ✓) · anon surface ✓ (baseline 328, one stale line named → removed, 327, `check_grants` re-run ✓) · colgrant live and rebuild 505 relations, no gap · **viewwrite live and rebuild 192 views, none writable** · B1 0 · B2 0 |
| 9 | i18n | **`I18N_OWN_EXIT=0`** — 262 dynamic prefixes, all enumerable, 3,033 enumerated keys |
| 10 | Error swallowing | **`SWALLOW_OWN_EXIT=0`** |
| 11 | Layout | §6 |
| 12 | Smoke | **`SMOKE_EXIT=0`** (19:23:38 → 19:48, judged by the script's own line): 288 routes + the probe set — **293 ok, 21 skipped (no data), 0 FAILED**; the three new dynamic pages skip on live because their tables are empty (`/safety/inspections/[id]`, `/safety/inspections/templates/[id]`; they were measured on the local rebuild, §6); `/safety/inspections`, `/safety/inspections/new`, `/safety/inspections/templates/new` and `/safety/environment` rendered 200 on live. Its throwaway (`smoke-1792149835971-all`, 81 codes) was cleaned up — closing readings: 0 throwaway accounts, 0 probe roles. Its scratch report named six old rows not mine (§11), untouched. |
| 13 | Live verification | §5 |
| 14 | Fresh-clone build | the cut's commit `f30c256dfbb41dff76fd38284bd12f2b6b95bde0`, cloned to a scratch directory with no `.env.local`: `npm ci` **`CI_OWN_EXIT=0`**, `npm run build` **`X_OWN_EXIT=0`** (19:50:41 → 19:51:54 CST). This row is recorded in a follow-up docs-only commit, whose own fresh-clone build was run as well before the push |

**Fault injections.** `db/scripts/2026-10-16-mes7b2-fixture-injections.py`: **57 cells on 268 + 2 on 263**, every arm of 268 red at least once,
run on a fresh rebuild after the last database edit (and again on another fresh rebuild at 19:49 CST, after the migration, before the push): **`INJECTIONS_OWN_EXIT=0` (59 cells, 0 wrong)** both times. The first sweep had two cells that did not
bite, and both were the fixture's fault, not the cell's: (1) REG's check of the inspection-source CHECK read `pg_get_constraintdef(NULL) NOT LIKE …`
— a dropped constraint gives NULL, and `IF NULL` is false, so the arm passed blind (the shape `void-assertion-rls-cure` warns about); fixed with
`COALESCE`, and then **every one of 268's 51 `IF … THEN RAISE` conditions was wrapped `IF (…) IS NOT FALSE`**, so a NULL anywhere is red; one
assertion whose NULL legitimately meant "no rows" (DUE) got `COALESCE(…, '{}')`. (2) The run-row fail-count cell swapped `fail` for `pass` — the run
has one of each, so the count was still 1; the cell now counts every result. Several cells go red on a table CHECK, a foreign key or RLS rather than
the function's named error (blank item · direct writes · CORR twice · ENV pairing): the fixture asserts the **named** error, so removing the
function's line is caught; the constraint is a second wall. Wording arm ㉝: `wording-drift-mes7b2` and `wording-part-mes7b2` each exit 1 and bite only
㉝. Gate: `GATE_VIEWWRITE_FAULT=grant` → offline gate exit 1 naming `pending_values:authenticated:insert`.

## §5 · Live verification

Rolled back — `db/scripts/2026-10-16-mes7b2-live-proof.mjs`, **`MES7B2_PROOF_EXIT=0`** (2026-10-16 19:22 CST, **16.3 s in one transaction**).
One psql transaction from BEGIN to ROLLBACK; every action as a throwaway account (prefix `mes7b2probe`, the shared `mintThrowaway` helper): `inv`
(every code, scenery only), `ed` (safety view + edit + tasks view; their employee row inserted in the transaction), `vw` (safety view), `qe` (quality
edit), and clones of the seven roles the seven real accounts hold (`cloneOf`, read-only; the cfo clone reads both reconciliations). My rows were
prefixed `ZZ-PROBE-MES7B2`. No real account, no record that existed before this session, and no bucket was touched. Rehearsed first on a local
rebuild (`--local`, same SQL; the reconciliation step is skipped there because a rebuild has no ledger).

| Step | Result |
|---|---|
| Before | templates 0 · runs 0 · findings 0 · parameters 0 · results 0 · incidents 0 · tasks 20 · NCRs 0 · **F16: 0 (view, role) pairs with a write grant** · V18 + V20 = 2 rows · AP 422,188.32 / 381,604.42 / **0.00** · AR 57,545.87 / 43,002.12 / **0.00** · 1200 61,387.92 / 172,403.48 / **0.00** · 1220 134.86 / 388.20 / **0.00** |
| Checklist | view-only → `PERMISSION_DENIED|module.safety.edit`; ZZ-PROBE-BAY saved with three ordered items |
| Run with a fail | a fail without a note → `INSPECTION_FAIL_NOTE_REQUIRED|2`; **INS-2026-0001** recorded (pass 2 · fail 1, one finding), seen by the view-only reader |
| Submitted is immutable | an editor's UPDATE of a result → `INSPECTION_RECORD_IMMUTABLE|inspection_results|update`; DELETE of the run → `…|inspection_runs|delete` |
| Edit the checklist | items 1 and 2 reworded ✓; the run still reads "1. Extinguishers in place / 2. Cells stored dry, off the floor / 3. Emergency stop tested" |
| Correcting run | without a reason → `INSPECTION_CORRECTION_REASON_REQUIRED`; **INS-2026-0002** corrects INS-2026-0001, which is unchanged (fail 1) and names it; a second correction → `INSPECTION_RUN_ALREADY_CORRECTED|INS-2026-0001` |
| Finding · task | the finding on item 2, owner ZZ-PROBE-MES7B2-E2, on the reminder (1 row); "raise a task" → TASK-2026-0208, **personal, owned by the presser**, titled "INS-2026-0001 · 2. Cells stored dry, off the floor"; the task closed by its owner → **the finding stays open**; closing without saying what was done → `INSPECTION_FINDING_CLOSE_NOTE_REQUIRED` |
| Inspection NCR | source inspection without a finding → `NCR_INSPECTION_FINDING_REQUIRED`; citing the finding on my batch IN-2026-0525: NCR-2026-0001, **the batch on quality hold**, `ncr_rows` names INS-2026-0001 item 2, holding = true |
| Close the finding | closed with what was done ✓; off the reminder (0) |
| Environment | two parameters through the dictionary's RLS path (one with a max limit of 5 mg/Nm3, one without); V20 → 1 row (the one without); an exceedance without the NEA answer → `ENV_EXCEEDANCE_NEA_ANSWER_REQUIRED|7.5|max|5|mg/Nm3`; 7.5 with the answer → **exceeds, INC-2026-0001 (`emission_exceedance`) opened in the same transaction** ("ZZ probe hydrogen fluoride at Stack A: 7.5 mg/Nm3 against a maximum limit of 5 mg/Nm3 …"), the result row carries the copied limit and the incident; the parameter without a limit → **not judged**, no incident (incidents still +1); an UPDATE → `ENV_RESULT_IMMUTABLE|update` |
| End | tasks = 21 (only the one raised here) · reconciliations unchanged, **0.00** both sides |
| After ROLLBACK | templates 0 · items 0 · runs 0 · results 0 · findings 0 · closures 0 · parameters 0 · env results 0 · incidents 0 · tasks 20 · NCRs 0 · probe materials 0 · probe employees 0 |

## §6 · Layout survey (desktop 1280 + phone 390)

Every new page needs data live does not have (no template, run, finding, parameter or result may be created on live), so the survey ran on a local
rebuild of this cut's mirrors seeded with MES-7b-1's role clones plus `docs/surveys/MES-7b-2/local-seed.sql` (three checklists — weekly with four
items, monthly without a frequency, an inactive one; INS-0001 with a fail, an n/a and an overdue finding with a task; INS-0002 with a closed finding,
corrected by INS-0003; three parameters — max, min, none — and four results, one exceeding and opening INC-2026-0004), served by local PostgREST and
`next dev`, measured with the same `MEASURE` string as `scripts/survey-phone.mjs` and its Chrome, with an overflow self-test on every run.

**14 routes × 4 roles (admin · warehouse · cfo · gm) × 2 widths = 112 page loads: all 200, overflow 0, clipped tables 0; the self-test bit on all
8 runs (+400 px).** Routes: `/safety/inspections` · three run pages (open finding · closed finding + corrected · the correction) · `new?template=` ·
`new?corrects=` · `templates/new` · `templates/[id]` · `/safety/environment` · the exceedance incident · `/settings/pending-values` ·
`/settings/dictionaries` · `/quality/ncr/new` · `/operation`.
**One defect found and fixed:** at 390 px the run page with an open finding overflowed **129 px** for roles without one of the three codes
(warehouse · cfo · gm) — the findings panel used `PermissionGate inline`, which puts the disabled button and the nowrap reason chip side by side
(474 px). The panel's three gates now stack (button above the reason); re-measured 0 at 390 and 1280. gm reads `/quality/ncr/new` as the named
refusal (no quality code) — expected.

## §7 · Role table — the seven real roles (clones of their live codes, read-only, in the proof's transaction)

| Role (account) | codes | safety view / edit | checklists | inspection list | the run | its results | environment rows | V18 / V20 rows | record a run |
|---|---|---|---|---|---|---|---|---|---|
| admin (admin@) | 81 | ✓ / ✓ | 1 | 2 | ✓ | 3 | 2 | 0 / 1 | OK |
| cfo (tim@) | 34 | ✓ / — | 1 | 2 | ✓ | 3 | 2 | 0 / 1 | `PERMISSION_DENIED|module.safety.edit` |
| finance (chooer@) | 43 | ✓ / — | 1 | 2 | ✓ | 3 | 2 | 0 / 1 | `PERMISSION_DENIED|module.safety.edit` |
| warehouse (fusheng@) | 31 | ✓ / ✓ | 1 | 2 | ✓ | 3 | 2 | 0 / 1 | OK |
| cto (phua@) | 39 | ✓ / ✓ | 1 | 2 | ✓ | 3 | 2 | 0 / 1 | OK |
| cco (sandra@) | 47 | ✓ / — | 1 | 2 | ✓ | 3 | 2 | 0 / 1 | `PERMISSION_DENIED|module.safety.edit` |
| gm (vince@) | 22 | ✓ / — | 1 | 2 | ✓ | 3 | 2 | 0 / 1 | `PERMISSION_DENIED|module.safety.edit` |

(At that point of the transaction the checklist had a frequency and was just inspected, so V18 had no row and `inspection_due` none; the finding was
closed, so the two inspection reminders read 0 for every role. "Record a run" was tried in a sub-transaction and undone.)

## §8 · Pages (route → file)

| Route | File |
|---|---|
| `/safety/inspections` | `app/safety/inspections/page.tsx` (+ `InspectionTables.tsx`) |
| `/safety/inspections/new` (`?template=` · `?corrects=`) | `app/safety/inspections/new/page.tsx` (+ `RunForm.tsx`) |
| `/safety/inspections/[id]` | `app/safety/inspections/[id]/page.tsx` (+ `[id]/FindingsPanel.tsx`) |
| `/safety/inspections/templates/new` | `app/safety/inspections/templates/new/page.tsx` (+ `TemplateForm.tsx`) |
| `/safety/inspections/templates/[id]` | `app/safety/inspections/templates/[id]/page.tsx` (+ `TemplateForm.tsx`, `InspectionTables.tsx`) |
| `/safety/environment` | `app/safety/environment/page.tsx` (+ `EnvironmentForm.tsx`, `EnvironmentTable.tsx`) |
| changed: `/quality/ncr/new` (`?finding=`) | `app/quality/ncr/new/page.tsx`, `app/quality/ncr/NcrForm.tsx`, `app/quality/samples/BatchPicker.tsx` |
| changed: `/quality/ncr/[id]` (the finding it cites) | `app/quality/ncr/[id]/page.tsx` |
| changed: `/settings/dictionaries` (monitored parameters) | `app/settings/dictionaries/registry.ts` · `page.tsx` · `actions.ts` · `DictSection.tsx` |
| changed: `/settings/pending-values` (V18 · V20), `/tools/reminders` (two arms) | `messages/en.ts`, `messages/zh.ts`, `lib/reminders.ts` |

Actions: `app/safety/actions.ts` (`saveInspectionTemplate` · `recordInspectionRun` · `recordInspectionFinding` · `closeInspectionFinding` ·
`raiseInspectionFindingTask` · `recordEnvironmentalResult`), `app/quality/actions.ts` (`openNcr` takes `inspectionFindingId`).

## §9 · Decisions taken without asking

1. **F16 without `ALTER DEFAULT PRIVILEGES`.** Default privileges cannot tell a view from a table, and 273 of the 303 table mirrors rely on the
   default write grant; changing them would break every future table. The revoke lives in `zzz_function_grants.sql`, which runs last in the rebuild
   and inside every later migration's transaction, plus the gate's `viewwrite` line — a mechanism, not a note.
2. **`zzz_*` view files now replay last** in `db/check_mirrors.py` (the depth sort ran `zzz_function_grants.sql` before 32 deeper views, so they
   stayed writable on the rebuild).
3. **V19's supplier wording (W7)** changed to "To be confirmed by Tim against the NEA licence." — the old line asserted a confirmation that has not
   happened.
4. **Checklist codes are upper-cased** and items are realigned **by position** on edit; a checklist is never deleted (switch it off).
5. **A run can be corrected once**; to change it again, correct the correction. A superseded run takes no new finding.
6. **"Due" counts from the last not-superseded run**; a checklist never inspected is due at once (`never_run`); a checklist without a frequency
   or switched off never reminds.
7. **A finding's task is raised once** (`INSPECTION_TASK_ALREADY_RAISED`), owned by the presser, needs `module.safety.view` and a task code; the
   finding stays open until closed with what was done.
8. **A finding needs an owner** (an employee); the due date is optional; the run page flags it overdue past the due date.
9. **The environmental parameter's code is its key**, locked once a result uses it; limit and basis are paired (`ENV_LIMIT_NEEDS_BASIS`).
10. **An exceedance asks the recorder** whether it is NEA-reportable and what was done — nothing is guessed; the incident occurs at the sampling
    date's Singapore midnight (the lab gives a date, not a time), its "what happened" is written from the result's facts, and its responsible person
    is the recorder (their employee record, else their account email).
11. **A correction that still exceeds reuses the incident** of the result it corrects — one event, one incident.
12. **The inspection-source NCR replaced `NCR_SOURCE_RESERVED`** with three named refusals; the old error code is no longer raised.
13. **`environmental_parameters` is a runtime-config table whose bootstrap is empty** (`RUNTIME_CONFIG_TABLES` + `BOOTSTRAP_MAY_BE_EMPTY`): an empty
    dictionary is the correct default, and V20 says so.
14. **The findings panel's permission gates stack** instead of sitting inline (the 390 px overflow).
15. **Fixture 268's assertions are NULL-red** (`IS NOT FALSE`), after an injection showed one of them passing blind on NULL.
16. **The stale anon-baseline line `processing_run_losses`** (a table, stale since before this cut) was removed, as the gate asks.

## §10 · Closing live readings

Read **2026-10-16 19:48:23 CST**, after the proof and the smoke, with the same `docs/surveys/MES-7b-2/live-readings.sql` (read-only,
`READ_OWN_EXIT=0`, `postgres`, base tables; the reconciliations as tim@ switched to `authenticated`).

| What | Opening (17:15:56) | Closing (19:48:23) |
|---|---|---|
| Inspection / environmental tables | none | the eight new tables, **all empty** (no checklist, run, finding, parameter, result) |
| Incidents · NCRs · tasks | 0 · 0 · 20 (md5 `3e0c3628…`) | **0 · 0 · 20** (md5 `3e0c3628…`, unchanged) |
| Document types | 60 | 61 (INS 1 · INC 1) |
| Views and write grants | 187 · anon any write on 110 · authenticated 163 | **192 · anon any write 0 · authenticated 0** (SELECT: anon 107 · authenticated 167) |
| Codes, roles, grants | catalogue 81 · role codes as §1 · `role_permissions` md5 `2cf8ce23…` | **identical** (81 · same counts · md5 `2cf8ce23…`) |
| Accounts | 7, 0 disabled | **7, 0 disabled**, the same seven with the same roles |
| Approvals · `require_calibrated_since` | ON finance / cfo / 1,000 · NULL | **ON finance / cfo / 1,000 · NULL** |
| Throwaways · pending | 0 · CLM-2026-0004 only | **0 accounts, 0 probe roles · CLM-2026-0004 only** |
| CODs | sha256 `ba299a4f…f42101` / `717661f6…13a4f9`; bucket 34,701 / 34,746 bytes | **byte-identical**: the same two sha256, bucket objects 34,701 / 34,746 bytes (2 objects) |
| Books | journal 83 / 186 (md5 `d9827dd9…`) · batches 24 (`6f7a7601…`) · output batches 20 (`aa50fafe…`) · movements 107 (`fe4000bb…`) · safety states 1 · downtime 1 (`6d8b598a…`) | **identical** — every md5 the same |
| Public tables | 305 | 313 |
| Reconciliation | AP 0.00 · AR 0.00 · 1200 0.00 · 1220 0.00 | **AP 422,188.32 / 381,604.42 / 0.00 · AR 57,545.87 / 43,002.12 / 0.00 · 1200 61,387.92 / 172,403.48 / 0.00, reconciled · 1220 134.86 / 388.20 / 0.00, reconciled** |

**The change log between the two readings** (44,113 → 45,139 rows): the migration's own **3** rows (`document_types` 1 · `document_type_exceptions`
2, stamped 19:01:25 — the migration transaction's `now()`), and otherwise only the throwaway churn of the probes and the smoke — `roles` 35 / 35,
`user_roles` 35 / 35, `role_permissions` 1,252 / 1,252, `employees` 9 / 9, `performance_reviews` 3 / 3 (+3 updates), the smoke's draft `contracts`
6 / 6 and their five term tables, `cod_verification_failures` 2 / 2 — **every INSERT matched by a DELETE**. The proof and the F16 measurement wrote
nothing that survived (rolled back).

## §11 · Registered

* `MES7B1-VIEW-DEFAULT-WRITE-GRANTS` — **closed** (§2).
* `MES7B1-INCOMING-INSPECTION-UNBUILT` — kept and rewritten: the `inspection` source now means a safety-inspection finding, so incoming inspection
  at receipt needs its own source, record, code and entry points.
* Six old scratch rows the smoke's scratch report names (`ZZ-SMOKE-PROBE`, `-M25`, `-NTF`, `-S25`, `-CJK`, `-IB25`, 1,060–1,702 h old, five still
  referenced) — not mine, not touched; reported only, as before.

## §12 · The window

Start **2026-10-16 19:03:57 CST** (measured, `db/migration-windows.tsv`). End: when Tim confirms the deployment in Vercel.
**Broken in the window** (derived, not measured on live): nothing — the old app does not read the new tables; `open_ncr` only gained a trailing
parameter with a default, and the old app calls it by name; the old pending-values page does not know the codes V18 / V20 and would show their
message keys until the deploy; the old reminders page does not draw the two new arm types; F16 removed only write grants no code path used (§2).
