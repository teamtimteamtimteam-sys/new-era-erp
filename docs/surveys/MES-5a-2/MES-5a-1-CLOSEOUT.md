# MES-5a-1 close-out — step 1 of the MES-5a-1 close-out + MES-5a-2 brief (2026-10-08)

**Verdict: e does not pass, so MES-5a-2 did not start** (the brief's step 1.5). a, b, c, d, f and g read as stated. Nothing was fixed.
The window close and Tim's own action are in `docs/forward-queue.md` item 42.

**Opening check.** First command **2026-10-08 13:38:17 CST**. Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
`96a2219ecb213493cbbc599efd9324673f19604e`. Files staged by explicit path only.

**Identities.** Every live reading below ran as `postgres` (`rolbypassrls = true`) over the Management API, read-only (`BEGIN READ ONLY`), on base
tables unless named. Every "local" result ran on a throwaway cluster in this job's scratch directory, rebuilt from the HEAD mirrors
(`db/verify_rebuild.py --offline`, `REBUILD_OWN_EXIT=0`, 278 public tables, B1 0 · B2 0) — never on live.

---

## 1 · Broken window — closed (bounded)

- **Start:** 2026-10-08 12:28:14 CST — measured, `db/migration-windows.tsv:225`.
- **End, lower bound:** 2026-10-08 13:18:49 CST — measured, `git reflog show --date=iso refs/remotes/origin/main`:
  `96a2219e refs/remotes/origin/main@{2026-10-08 13:18:49 +0800}: update by push`.
- **End, upper bound:** 2026-10-08 13:38:17 CST — this session's first command, with Tim's "deployed" already in hand. It rests on what Tim said,
  not on a Vercel reading.
- **Window: 50 min 35 s – 1 h 10 min 03 s.**
- Close-out reading (14:07 CST, `docs/surveys/MES-5a-2/closeout-readings.sql`): module results 0 · channel assignments 0 · splits 0 · batches with a
  module count 0 / 0 · materials with V9 0 · quarantine locations 0 · runs created since the window opened 0 (the only discharge run is the reversed
  PROC-2026-0494) · `require_calibrated_since` NULL · 7 accounts, 0 banned. Nobody used the new discharge features in the window.

## 2 · Tim's own action — recorded under item 42

Mark a quarantine location in the location editor (`/inventory/locations`, the "Quarantine location" box; `save_storage_location` asks
`module.inventory.edit`, `db/functions/save_storage_location.sql:29`). Live has **0**. Until one exists the discharge quarantine split is refused
(`QUARANTINE_LOCATION_REQUIRED`).

## 3 · Read-only verification

### a · The opening live readings, as recorded in the hand-back — present

`docs/handbacks/MES-5a-1.md:14-33` (§0): read 12:06 CST as `postgres`, base tables, three named scripts (`2026-10-06-mes1-live-readings.sql`,
`2026-10-08-mes5a1-live-readings.sql`, `2026-10-05-at1d3-live-recon.sql`), all `*_OWN_EXIT=0`. Rows: accounts (7, 0 disabled, roles named) ·
approvals ON · pending documents 1 (`CLM-2026-0004`, not the cut's) · reconciliation in tim@'s session (AP 422,188.32 / 381,604.42 / **0.00** ·
AR 57,545.87 / 43,002.12 / **0.00**) · change log 13,757 rows / max seq 15,537 · discharge runs 1 (PROC-2026-0494, reversed) · the two open
discharge-related states · quarantine locations 0 · `require_calibrated_since` NULL · batch / run / movement / location / device counts ·
sequences. The same figures appear after the proof in §5.3 (`:183-203`).

### b · The MES-5a-1 brief's "Fixtures must cover" list — every item covered; every new arm red under injection, re-run on HEAD

The brief's list (MES-5a-1 session transcript, user message of 2026-10-08 03:07:51Z) against fixture 255
(`db/fixtures/255-a-batch-is-discharged-when-every-module-says-so-and-a-failed-one-goes-to-quarantine.sql`):

| Brief item | Fixture · arm | Lines |
|---|---|---|
| module_count optional at receipt, set later, `BATCH_MODULE_COUNT_REQUIRED` at the first result, locked after verification | 255 MC (+ VER, P1) | receipt `:195`, none `:201`, viewer refused `:203`, set later `:206`, required `:225`, locked by function `:274` and by direct UPDATE `:276`, not below results `:328` |
| module references unique within a batch, reused on re-discharge | 255 VER | same module twice on a run `:256`; re-discharge reuses the ref, latest wins, count derived `:261,:269` |
| commit on a verifies_by_unit operation leaves the state alone; a commit alone never verifies | 255 COMMIT + 158 / 165 / 251 / 253 | `:232`, stock untouched `:234` |
| verification: all pass · one failed for re-discharge · split to quarantine · more results than the count · reversed run's results not counted | 255 VER · SPLIT · REV | `:261` · `:250` · `:470` · `:254` · `:314` |
| P1 partial discharge | 255 P1 | `:322,:325` |
| P2 reversed after a downstream run, stock correct | 255 P2 | `:337-345` |
| P3 self-produced batch stock unchanged | 255 P3 + 165 K7 | `:355` |
| result fields, disposition required on a fail, corrections with a reason | 255 RES · VER · CORR | `:360-372` · `:245,:247` · `:282-300` |
| V9 flags, never decides; empty V9 = could not be judged | 255 V9 | `:380-400` |
| channel assignments append-only; unassigned channel in the inbox *if a transform was built* | 255 CHAN · ING | `:405-428` · no transform built, device rows wait `awaiting_transform` `:485` |
| quarantine split: mass consumed, new batch charged in the quarantine location, refused with none | 255 SPLIT | `:445`, `:458`, `:463`, `:466` |
| state history and reversal after verification by results | 255 VER · REV · SPLIT | `:266` · `:314` · `:479` |
| the two reminder arms appearing and clearing | 255 COMMIT · VER · SPLIT | `discharge_unverified` `:236,:271`; `discharge_quarantine_pending` `:442,:472` |
| inbound module_count in the grant and masked view | 255 MC | `:217-220` |
| 158 D4, 165 K7, 251 RUN, 253 DISCH | item c | — |

**Fault injection, re-run.** The recorded run (`INJECTIONS_OWN_EXIT=0`, 44 + 5) is logged at 11:39 CST; after it, `db/tables/processing_runs.sql`
(the Q36 column comment, 12:16) and the migration changed. So `db/scripts/2026-10-08-mes5a1-fixture-injections.py` was re-run against the local
rebuild of HEAD: **`INJECTIONS_OWN_EXIT=0` — 44 injections on 255 + 5 on 158 / 165 / 251 / 253, 0 wrong**, each red in the arm it names
(MC 5 · MC|VER 1 · MC|P1 1 · COMMIT 2 · VER 6 · CORR 4 · REV 1 · P1 1 · P2 1 · P3 1 · RES 4 · V9 4 · CHAN 4 · SPLIT 8 · ING 1; 158 D4 · 165 K7 ×2 ·
251 RUN · 253 DISCH), and the clean run green. The six fixtures alone on the same rebuild: 158 · 165 · 251 · 253 · 255 · 111 all exit 0.
One precision note: the MC grant/view assertion (`:217-220`) checks both the column grant and `inbound_batches_masked`; its injection removes the
grant only — the view half is asserted but has no injection of its own.

### c · Fixtures 158 D4, 165 K7, 251 RUN, 253 DISCH — moved after the results, counter-assertion added, nothing removed

`git diff aeb7e3da 96a2219e` on the four files: +64 / −3. The three removed lines are a variable swap (165: `v_mat` → `v_mat_mod`, so the batch is a
module form that can carry a count), a comment (253 header) and one criterion string (251, below). `RAISE EXCEPTION` counts before → after:
158 12 → 13 · 165 15 → 17 · 251 82 → 83 · 253 123 → 125. No assertion removed.

- **158 D4** (`db/fixtures/158-…:134-144`): counter-assertion "a commit alone verified the batch" `:135-140`; count set and two passes `:142-144`;
  the original state assertions follow unchanged.
- **165 K7** (`165-…:210-228`): P3 stock assertion `:210-216`; counter-assertion `:217-223`; count and one pass `:224-228`; the original state
  assertions follow unchanged.
- **251 RUN** (`251-…:459-470`): counter-assertion `:462-464`; count and a pass `:465-466`; the original assertion follows, with its end-reason
  criterion changed from `'resolved by processing run PROC-%'` to `'verified by module results (PROC-%'` — the new end reason, still naming the run
  and still on `ended_by_run_id`. Changed, not removed.
- **253 DISCH** (`253-…:461-472`): counter-assertion `:463-465`; two passes; then the after-results assertion `:469-472`. The header and
  `not_applicable` assertions before it are unchanged.

### d · V9, the inbound module_count, P1–P3 — present

- V9 arm: `db/views/pending_values.sql:232-243` (`'V9'`, `module.materials.view`, listed only once a result exists on a batch of the material);
  docs row `docs/mes-pending-values.md:37` plus "What V9 holds back".
- `inbound_batches.module_count`: column `db/tables/inbound_batches.sql:99`, column-list grant `:340-342`, masked view
  `db/views/inbound_batches_masked.sql:78`.
- `docs/known-issues.md`: `MES5A-P1-PARTIAL-DISCHARGE-FLIPS-WHOLE-BATCH` `:16`, `MES5A-P2-DISCHARGE-ROLLBACK-RESTORES-STOCK` `:26`,
  `MES5A-P3-SELF-PRODUCED-DISCHARGE-TAKES-STOCK` `:34` — each struck through, "✅ closed in MES-5a-1 (`v1.4.43`)" (found and fixed).

### e · The three run-page forms at desktop and 390 px — **the module-result form overflows at 390 px; the split form overflows with longer names**

**How it was measured.** No local Supabase stack exists on this machine (no Docker, no PostgREST), so the app cannot run against the rebuild. Instead:
1. on the local rebuild, as an all-codes session of my own, I received two module batches (3 and 2 modules), marked a quarantine location, registered
   a discharge cabinet, committed a deep discharge (PROC-2026-0049 on the rebuild), assigned four channels and recorded four results (pass,
   fail · quarantine, fail · re-discharge, pass);
2. the run panel's queries were read back from that database as that session (`SET LOCAL ROLE authenticated` + JWT; the same relations and columns
   `loadDischargePanel` selects);
3. in a scratch copy of HEAD outside the repo, a one-off route rendered the real `DischargePanel`, built by the real `loadDischargePanel` whose
   queries were answered from those rows, inside the run page's own wrapper (`ListPage`, `max-w-3xl`);
4. `scripts/survey-phone.mjs` (the repo's probe, self-test passed each run) measured it at 390 and 1280, with two extra fields per control
   (which form it belongs to, its width and right edge).

**Readings** (page overflow at 390 / per form; desktop 1280 is 0 in every case):

| Data | Result form | Channel form | Split form | Page at 390 |
|---|---|---|---|---|
| short names (cabinet label 25 chars, location 13) | **file input 350 px → right edge 395** | fits | fits | **+5 px** |
| live-length names (cabinet "DEV-… — Bosch Deep Discharging Machine", 46 chars; location 34 chars, the longest live label is 34) | cabinet `<select>` 437 px | fits | location `<select>` 339 px, its block 352 / 326 | **+92 px** |
| long names (58 / 52 chars) | cabinet `<select>` 527 px | fits | location `<select>` 456 px | **+182 px** |

Live label lengths (read-only, this close-out): devices 41–43 chars, storage locations 27–34, the two discharge machines on the asset register 42 and 45.

- **Module results form:** overflows at 390 regardless of data — the photo `<input type="file">` (`CONTROL_FILE_BUTTON`,
  `app/operation/processing/[id]/DischargePanel.tsx:311`) is 350 px wide; the cabinet picker (`:299`) then grows with the device label.
- **Channel assignment form:** fits at every data set measured.
- **Quarantine split form:** the location picker (`:497`) grows with the location label; it pushes past its own block at 34 chars and past the page
  at 52.
- Tables: 3 on the panel, all inside scrollers, 0 clipped.

**Recommendation (not applied).** Give the two pickers and their labels `min-w-0 max-w-full` and the file input `max-w-full`. Tried in the scratch copy
only, with the 58 / 52-character names: 390 px page overflow **182 → 0**, every form's block at its own width; desktop widths unchanged
(cabinet 468 px, location 406 px, before and after). It is the same native-`<select>`-in-a-row shape AGENTS.md records (INPUT-2b) and the
`/operation/processing/new` +177 px picker MES-4a / 4b / 5a-1 reported.

### f · Side effects of the live proof's request (submitted by fusheng@, approved by tim@) — nothing left the database; no notification row remains

- **The path:** `db/scripts/2026-10-08-mes5a1-live-proof.sql:197` (`submit_rollback_request`) and `:202` (`decide_warehouse_request`), inside one
  transaction ending `ROLLBACK` (`:240`); run over psql, so no application code ran. Its log ends `ROLLBACK` with the after-readings 0 / 0 / 0.
- **Neither function writes a notification.** Repo-wide, only `notify_class_violations` and `notify_landing_warnings` insert into `notifications`
  (grep of `db/functions/*.sql`).
- **No mechanism exists that could send from inside a transaction** (live catalog, read-only): extensions `pg_stat_statements pg_trgm pgcrypto plpgsql
  supabase_vault uuid-ossp` — no `pg_net`, `http` or `dblink`; no `supabase_functions.hooks` table (database webhooks); **no public function body
  mentions `net.http`, `http_post`, `dblink`, `pg_notify` or `NOTIFY`**; the `supabase_realtime` publication carries **no** tables. The triggers on
  `warehouse_requests`, `approval_log`, `notifications` and `processing_runs` are change-log capture, append-only guards, code generation and write
  guards only.
- **No email or push path exists in the app:** no mail or push library in `app/`, `lib/`, `scripts/` or `package.json`; `app/settings/accounts/UserRow.tsx:218`
  records that the system has no mail service.
- **Rows today:** `notifications` 2 rows in all, **0** created since 13:13 CST, **0** mentioning PROC-2026-073x or `ZZ-PROBE-MES5A1`;
  `warehouse_requests` 0 rows mentioning those codes.
- **So nothing was sent, to anyone.**

### g · Self-taken decisions in `docs/handbacks/MES-5a-1.md` §6 (titles)

1. No device transform.
2. A third table, `discharge_module_splits`.
3. The split also needs `action.processing_commit`.
4. `operation_types.started_from_run_page`.
5. `create_stock_transfer` split into a wrapper and `create_stock_transfer_internal`.
6. Losing verification is undone on the safe side.
7. Verification acts only on batches that have module results.
8. The split's new batch copies the parent's open states.
9. The split operation accepts `discharged_verified` as well.
10. Two relation exceptions for `discharge_module_splits`.
11. The gated status reader is named `discharge_status_by_batch`.
12. A correction keeps the module reference.
13. "Latest" = latest verdict time, then latest row id.
14. The V9 arm lists a material only once a discharge result exists on a batch of it.
15. The module-count guard is a SECURITY DEFINER trigger with EXECUTE revoked.
16. Fixture 253 DISCH gained a counter-assertion too.
17. Fixture 165 K7's material became a module form.
18. Screen photo into the existing `capture-photos` bucket.
19. The device picker lists active discharge cabinets.
20. The module count shows only for cell-carrying forms.
21. A typed value that is not a number is refused before sending.
22. The split form's process date defaults to the discharge run's date.
23. A reader without inventory view sees "Locations need inventory view rights".
24. The live proof reversed through the real path.
25. Q36 in this cut (and the month-end comment left for the cut that touches it).

## 4 · Assertions measured and found false or imprecise

- **`docs/handbacks/MES-5a-1.md` §4 row 10 ("Not measured: the run page's record / channel / split forms")** — accurate as written; this close-out
  measured them (item e) and two of the three overflow at 390 px.
- **The MES-5a-1 report's injection run** was not the last thing before the push: it predates the last mirror edit (item b). Re-run on HEAD: unchanged
  verdict.
- Zero other assertions found false.
