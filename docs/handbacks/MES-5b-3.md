v1.4.47 — Blending (for the future line): a blending plan can be drawn up from saleable powder batches against minimum and maximum metal targets, shows the predicted composition before anything is mixed, must be released by someone other than its author, and is carried out as a processing run whose result is checked against the targets once the blended batch is assayed; admin can now also see everyone's tasks.

# MES-5b-3 — blending (MES group, eleventh cut; 2026-10-09)

Tim's brief of 2026-10-09 ("MES-5b-2 close-out + MES-5b-3 build: blending"): every MES-5b Step 0 blending recommendation accepted as stated
(Q16–Q20 and the blending parts of Q1, Q32, Q34–Q36; `docs/surveys/MES-5b/STEP0-HANDBACK.md` §14 D), Q16 "the current line does not blend; a future
line will", and the fold-in "admin holds `module.tasks.view_all`". Migration `db/migrations/2026-10-09-mes5b3-blending.sql` (2,318 lines, built from
the mirrors by `db/scripts/build_mes5b3_migration.py`). Opening SHA: HEAD = origin/main = `git ls-remote origin main` =
`68aa5277c95c4abb1bb5218a972a77174e10b0ac` (tree clean; first command 2026-10-09 15:56:43 CST). Step 1 committed and pushed as
`032f557a06f4c9f1f130fd69e87aa6fcd614260d` ("MES-5b-2 close-out").

---

## §0 · Step 1 — MES-5b-2 close-out, item by item

Full evidence (file:line, fixture arms, live readings, the deployed-app table): `docs/surveys/MES-5b/MES-5b-2-CLOSEOUT.md`.

| Item | Result |
|---|---|
| 1 · Broken window | Start 2026-10-09 14:48:26 CST (measured, `db/migration-windows.tsv`) · end lower bound 15:45:02 CST (measured, `git reflog` of `origin/main` → `68aa5277`) · end upper bound 15:56:43 CST (this session's first command, resting on Tim's "deployed", not a Vercel reading) → **56 min 36 s – 1 h 08 min 17 s**. Nobody used the new features in it (allocations 0, reversals 0, reversed expenses 0, expenses created since 0, stamps since 0). Recorded in `docs/forward-queue.md` item 45 |
| 2 · Rulings | `MES5B2-PREPAYMENT-APPLIED-EXPENSE-NOT-REVERSIBLE` recorded as **ruled** (`docs/known-issues.md`, hand-back MES-5b-2 decision 2). `MES5B1C-ADMIN-TASKS-VIEW-ALL-UNRULED`: ruling recorded in step 1, **closed in this cut** (below) |
| 3a · V37 fold-in | ✓ — `trail_subject_members.sql:516` (same line on live), `lib/trail/render.ts:1136-1138`, fixture 258 LOG `:554-557` with its injection cell; wording arm ㉔ clean `TW_CLEAN_OWN_EXIT=0`, fault `TW_FAULT_OWN_EXIT=1` (red in ㉔ only) |
| 3b · Q28 | ✓ — `post_electricity_allocation.sql:44-45` (live: both checks present); fixture 258 PERM `:207-212`; injection `:66-67` |
| 3c · Q21 | ✓ — `processing_cost_variance.sql:42` (`ex.status = 'posted'`, live same); `relieve_processing_accruals.sql:110` (`base_currency_code(), 1`; live: no `'SGD'` literal); fixture 258 VAR · CCY with injections |
| 3d · Q23 | ✓ — fixture 258 REPOST `:281-306` (post → reverse → post for the same period); injections `:94-103`; live: no unique on `run_id`, the one-live guard present |
| 3e · known-issues | ✓ — relief-reversal entry corrected (mechanism) and closed `:10536`; side door closed `:10602`; SGD literal closed `:10507` |
| 3f · Usability on live | Deployed app, clones of admin (74 codes) · finance (41) · warehouse (28): admin and finance open both expense pages (HTTP 200), the Reverse button is pressable, pressing it opens the dialog naming the expense, and on the relief it says how many estimates come back; warehouse is refused at the gate on all four pages, no Reverse control in the page. **Two assumptions of the brief measured false:** live has **0** electricity allocations, so the allocation page cannot render on the deployed app (a non-existent id → 404 for admin / finance, refused for warehouse); and **the expense reversal has no reason field** — it never had one (`reverse_expense` takes none; only the allocation reversal requires a reason, Q22). Neither is a defect in MES-5b-2, so step 2 went ahead |
| 3g · Decisions | 22 titles listed in the close-out file §2 g |
| 4 · Commit | `032f557a` "MES-5b-2 close-out", pushed |
| 5 · Stop? | a–e pass; f passes on what the deployed app can show, with the two false assumptions recorded → step 2 went ahead |

## §1 · Opening live readings (before anything changed)

Read 2026-10-09 **16:11:29 CST** as `postgres` (`rolbypassrls = true`) over direct psql, `BEGIN READ ONLY … ROLLBACK`, base tables
(`db/scripts/2026-10-09-mes5b3-opening-readings.sql`, `READ_OWN_EXIT=0`).

| Reading | Value |
|---|---|
| Assays | **4** (all on inbound batches; 0 on output batches) · 14 assay metal rows |
| Batches with metal content | inbound **7** batches (19 rows, all source *unknown* — pre-PROC-1) · output **4** batches (6 rows, all *manual*) |
| Contract grade specs | **0** (0 contracts carry one) |
| Saleable powder batches (black mass · cathode powder · anode powder — `may_be_sold` true for all three) | **0** inbound · **0** output; no live material has one of those forms |
| Work-order permission holders | `action.wo_create`: admin (admin@) · warehouse (fusheng@) · `action.wo_release`: admin · finance (chooer@) · `action.processing_commit`: admin · warehouse · `module.processing.view`: admin · cco · cfo · cto · finance · gm · warehouse (+ auditor, operations — no holder) · `module.inbound.view` / `module.output.view`: all seven real roles. `module.tasks.view_all`: **no role** |
| Every role's codes | catalogue **75** (34 action) · admin **74** (missing only `module.tasks.view_all`) · cco 42 · cfo 32 · cto 34 · finance 41 · gm 21 · warehouse 28 · auditor 20 · hr 8 · operations 15 · procurement 16 · sales 17 · employee 0 |
| Standing state | 7 accounts, 0 disabled, 0 throwaway · approvals ON · `require_calibrated_since` NULL · 1 pending (`expense_claim CLM-2026-0004` 1,000.00, not mine) · `change_log` 22,667 rows (max seq 25,326) · notifications 2 · runs 14 · work orders 1 · document types 55 · 8 operations (only the quarantine split started from the run page) |
| Reconciliation (tim@, 17:04 CST) | AP list 422,188.32 / ledger 381,604.42 / **unexplained 0.00** · AR 57,545.87 / 43,002.12 / **0.00** |

## §2 · Role-by-role reading table (live, measured)

Read inside the live proof (`db/scripts/2026-10-09-mes5b3-live-proof.sql` via `.mjs`, `MES5B3_PROOF_EXIT=0`, 18:10:59–18:12:14 CST; the transaction
6.5 s, ROLLBACK), after my plan existed and had been executed — live has no plan, so without one the plan page would read nothing. Each row is a
**one-off clone of a real role** (`mintThrowaway { cloneOf }`: exactly that role's codes at that moment — 75 / 41 / 28 / 34 / 42 / 32 / 21); no real
account read or acted. "Open" is the page gate (`has_permission('module.processing.view')`, the same predicate as `requireFunction(FN.blending)`);
create / release / execute are the codes the controls' `PermissionGate` asks; "content" and "prediction" are what the clone reads itself through
`blending_plan_line_metals` / `blending_plan_prediction`.

| Real role (live account) | `/operation/blending` and a plan page | Create / edit / cancel (`action.wo_create`) | Release (`action.wo_release`) | Execute (`action.processing_commit`) | Batch metal content | Predicted composition |
|---|---|---|---|---|---|---|
| admin (admin@) | open | **yes** | **yes** (never their own plan) | **yes** | shown | shown (ni 16.00 · co 4.50 · li not measured) |
| finance (chooer@) | open | no | **yes** | no | shown | shown |
| warehouse (fusheng@) | open | **yes** | no | **yes** | shown | shown |
| cto (phua@) | open | no | no | no | shown | shown |
| cco (sandra@) | open | no | no | no | shown | shown |
| cfo (tim@) | open | no | no | no | shown | shown |
| gm (vince@) | open | no | no | no | shown | shown |
| *(throwaway `pv`: `module.processing.view` only)* | open | no | no | no | **restricted** | **restricted** |

How to read it: **creating is warehouse's (and admin's), releasing is finance's (and admin's), executing is warehouse's (and admin's)** — the
work-order split, as Q19 asked. A creator can never release their own plan, whatever codes they hold (the proof's creator held both codes and was
refused `SELF_APPROVAL_FORBIDDEN|raiser`). **No real role sees metal content restricted** — every one of them holds `module.inbound.view` and
`module.output.view` (opening reading) — so the restriction is shown by the extra throwaway reader `pv`: the page opens, the batch content and the
prediction read "Restricted" (not blank, not 0); the targets' bounds stay visible. Those without a code see the control, disabled, with the sentence
naming the code (DBLOCK-1). **The only grant change in this cut is admin gaining `module.tasks.view_all`; no approval added (Q32).**

## §3 · Every item built

### §3.1 Database (one migration)

- **Three new tables** (all change-logged, RLS select `module.processing.view`, no write policy — functions only):
  `blending_plans` (code `BLD-YYYY-NNNN`, status draft / released / executed / cancelled with consistency CHECKs, output material, optional source
  contract, release / execute / cancel stamps, `run_id` → the blending run) · `blending_plan_targets` (metal, min / max — at least one, ordered, 0–100;
  source `contract` with the grade spec it was copied from, or `manual`; one row per metal) · `blending_plan_lines` (one inbound **or** output batch,
  planned kg > 0, one line per batch).
- **New functions:** `next_blending_plan_code` (yearly, gapless, the WO shape) · `blending_plan_write_children` (the one validator for create and
  amend; INVOKER, revoked) · `create_blending_plan` · `amend_blending_plan` · `release_blending_plan` · `cancel_blending_plan` ·
  `execute_blending_plan` (a wrapper over `commit_processing_run`; the engine's signature unchanged) · `guard_blending_run_from_plan` (trigger) ·
  `guard_blended_batch_metals_from_assay` (trigger, owner rights).
- **New views** (owner rights): `blending_plan_line_metals_all` (base, revoked) · `blending_plan_line_metals` · `blending_plan_prediction` ·
  `blending_plan_execution` · `blending_plan_outcome`.
- **Seeds on live:** operation `blending` (transforming, `started_from_run_page`, no tolerance) with input and output forms black mass · cathode
  powder · anode powder and the safety state `discharged_verified`; `document_types` row `blending_plan` / `BLD`; admin + `module.tasks.view_all`.
- **Replaced (same signatures):** `trail_subjects` (+ `blending_plan`) · `trail_subject_members` (+ targets, lines).
- **Bootstrap (mirror):** `db/tables/role_permissions.sql` — the bootstrap admin holds **every** code (the `module.tasks.view_all` exclusion removed).
- **The migration's own proof** (same transaction): approvals ON; grants changed by exactly `admin:module.tasks.view_all` and admin holds 75 / 75;
  every role satisfies action-implies-view; accounts and pending documents unchanged (each still has a decider); digests of runs, legs, batches, metal
  content, assays, movements, journals, expenses, payments, work orders, devices, materials, contracts, grade specs, forms, closures and losses
  unchanged; `change_log` moved only by INSERTs on the seeded tables (**10 rows** on live); the new tables empty; both guards present; blending
  started from the run page with no tolerance; the engine's signature identical; 56 document types with BLD; anon executes exactly the two; the five
  staff functions DEFINER and callable, the three internals not; the base view unreadable; 44 open read policies; change-log coverage 0 gaps (8
  excluded); mask rules 114; 59 reminder arms and 20 pending-value arms unchanged.

### §3.2 Fixtures

- **259** (new) — arms PLAN · SALE · TGT · PRED · REL · EXEC · ASSAY · READ · LOG · ADMIN. Data: inbound black mass A (ni 20 · co 6, by hand) and
  B (ni 10, by hand), output black mass C (ni 16 · co 4 from an applied assay), a pcs batch, a module batch; a contract with three grade specs (ni ≥ 17
  generic, co ≤ 6 for black mass, mn ≤ 1 for cathode powder) and a second contract. Plan one A 300 + C 200 → ni 18.4 within 18–22, co 5.2 above max 5,
  li not measured; executed A 310 + C 190 → 495; assay ni 18.9 · co 5.3 → within / above max / not in the assay. Plan two A 100 + B 100 → ni 15, co not
  measured (1 of 2).
- **100** (55 → 56 prefixes, 32 → 33 MAX+1 minting functions, 22 → 23 called) · **101** (47 → 48 (table, code) pairs) · **254** (registry 55 → 56) ·
  **257** FCHECK (the bootstrap admin holds every code).
- **Fault injection** `db/scripts/2026-10-09-mes5b3-fixture-injections.py`: **37 cells on 259 + 1 on 100 (BLD gone) + 1 on 257 (admin lacks
  `module.tasks.view_all`)**, each red in the arm it names, every 259 arm red at least once. One cell deliberately not written: "execute no longer asks
  `action.processing_commit`" — the engine asks the same code first, so that injection cannot go red (two layers, recorded in the script header). Last
  run after the last edit, against a fresh rebuild of the final mirrors: **`INJECTIONS_OWN_EXIT=0` (17:47 CST)**.
- **235** stays at 8 exclusions.

### §3.3 App

- `/operation/blending` (list; "New blending plan" gated on `action.wo_create`), `/operation/blending/new` (the plan form), `/operation/blending/[id]`
  (header; targets and prediction; candidate batches with their current metal content, actual kg and the difference; the blended batch's latest assay
  against the targets; the draft's edit form; the execute form on a released plan; release / cancel; the audit trail).
- Navigation: Operation › Blending plans (`lib/modules.ts`, `FN.blending`).
- Messages (en / zh): `blending.*` (statuses, flags, verdicts, sources, kinds, bases, 31 error sentences), `processing.subnav.blending`.
- Error codes: `app/operation/blending/blendingErrorCodes.ts` (the engine's codes during execution fall through to the processing localizer).
- Trail: subject `blending_plan` in `lib/trail/render.ts` and `AuditTrail.tsx`; table names and two enum label sets in `scripts/gen-trail-catalogue.mjs`;
  33 column rows in `docs/surveys/AUDIT-TRAIL-0/labels.csv`; wording arm **㉕** (`wording-drift-mes5b3` → red in ㉕ only). The six pinned sentences:
  "Blending plan created · Blending plan number: BLD-2026-0001 · Status: Draft · Material: MAT-2026-0042 · Notes: …" · "Blending target created · Metal:
  Nickel · Min %: 18 · Max %: 22 · Source: Entered by hand" · "Blending line created · Inbound batch: IN-2026-0501 · Planned kg: 300" · "Blending plan
  edited · Status: Draft → Released · Released: … · Released by: (empty) → Choo Er" · the same for executed (with "Blending run") and cancelled (with
  "Cancel reason").
- Registries: `scripts/check-search-registry.mjs` 55 → 56 · `scripts/check-document-registry.mjs` 283 → 286 tables, 86 → 87 with a code ·
  `scripts/check-i18n.mjs` (seven dynamic prefixes wired to their sources) · `scripts/smoke-routes.mjs` (id source, trail assertion, expected skip) ·
  `scripts/ephemeral.mjs` prefix `mes5b3probe` · `lib/deepRoutes.generated.ts`.

## §4 · Pages — every new or changed route, with its file

| Route | File(s) | What changed |
|---|---|---|
| `/operation/blending` (new) | `app/operation/blending/page.tsx`, `BlendingPlansTable.tsx`, `blendingTypes.ts` | the plan list |
| `/operation/blending/new` (new) | `app/operation/blending/new/page.tsx`, `BlendingPlanForm.tsx`, `options.ts`, `actions.ts`, `blendingErrorCodes.ts` | create a plan |
| `/operation/blending/[id]` (new) | `app/operation/blending/[id]/page.tsx`, `BlendingTables.tsx`, `BlendingPlanActions.tsx`, `ExecuteBlendForm.tsx`, `../BlendingPlanForm.tsx` | targets and prediction, lines, outcome, edit, execute, release / cancel, trail |
| `/operation` (overview) and the Operation sub-navigation | `lib/modules.ts`, `lib/deepRoutes.generated.ts` | the new entry |
| every audit trail | `lib/trail/render.ts`, `lib/trail/catalogue.generated.ts`, `app/components/trail/AuditTrail.tsx` | the `blending_plan` subject |
| `/operation/processing/new` | *(no file changed)* | `blending` is absent (`started_from_run_page`) |
| `/settings/pending-values` | *(no file changed)* | V1 now also lists `blending` |

## §5 · Verification, in the brief's order

| # | Step | Result |
|---|---|---|
| — | Before the window | Fixture 259 iterated on a local rebuild; injection matrix built and run there; pre-window `npm run build` against a temporary type splice generated from the local rebuild: `PREBUILD_OWN_EXIT=0` (sixth run — earlier runs caught the deep-route list, a masked-table read, pinned cell font classes, a locale number formatter and two lint warnings in my step-1 probe script, each fixed); live proof rehearsed end to end on the local rebuild (`REHEARSE_OWN_EXIT=0`); preflight ✓ (12 functions: 2 replaced, 10 new). **Live dry run** of the built file (`COMMIT` → grants re-assert + probe + `ROLLBACK`): **`DRY_OWN_EXIT=0`** (17:01:48 → 17:04:07; probe: 0 plans, 56 document types, admin 75 / 75, blending started from the run page) |
| 1 | Offline gate | `GATEOFF_EXIT=0` (third run; the first caught the registry counts pinned in fixtures 101 and 254, the second a DEFINER helper with no caller check — made INVOKER) |
| 2 | Backup (background) | `BACKUP_EXIT=0`, `evoltrya-backup-2026-10-09-1704.dump` (7.3 MB; TOC 8,604 entries; previous 8,563) — 17:04 → 17:19 |
| 3 | `apply_migration.sh` | `APPLY_OWN_EXIT=0`; applied 17:19:41, **committed 17:21:45 CST = window start** (`db/migration-windows.tsv`) |
| 4 | `types:gen` | `TYPES_OWN_EXIT=0` (with `DO_NOT_TRACK=1`; tail clean): 863 lines added — the three tables, five views, seven functions |
| 5 | tsc | `TSC_OWN_EXIT=0` |
| 6 | `npm run build` | `BUILD_OWN_EXIT=0` (every static check incl. trail arm ㉕, then `next build`, compiled in 20.6 s; the three routes listed) |
| 7 | Full gate | `GATE_EXIT=0` (529 s): rebuild ✓ · mirrors vs live "NO DIFFERENCES" (incl. generated types) · fixtures ✓ (**262**) · anonymous surface ✓ (subset of the 328-line baseline); change log **286 tables · 278 logged · 8 excluded**, masks **38 tables / 114 columns**, zero gaps, live and rebuild |
| 8 | i18n | `I18N_OWN_EXIT=0` |
| 9 | Error swallowing | `SWALLOW_OWN_EXIT=0` (0 unallowed, 9 allowlisted) |
| 10 | Layout survey | 4 targets × 2 widths: `/operation`, `/operation/blending`, `/operation/blending/new` (live data — no powder batch, so empty selects) and a temporary harness rendering the real `[id]` components with canned rows (live has no plan; the harness was never committed). First 390 px pass: the harness **+107 px**, culprit the permission notice beside the cancel input (an `inline` gate does not wrap) → `flex-wrap` on both gates in `BlendingPlanActions.tsx`; re-run: **every target 0 px overflow, 0 clipped at 390 and 1280** (`LSURVEY390_OWN_EXIT=0`, `LSURVEY1280_OWN_EXIT=0`). Then tsc (`TSC_OWN_EXIT=0`) and build (`BUILD_OWN_EXIT=0`, compiled 24.6 s) re-run for the changed file |
| 11 | Smoke (background) | `SMOKE_EXIT=0` — **279 ok, 14 skipped (no data), 0 failed** (267 routes plus the probes; 253 timed, 1,085.6 s; `/operation/blending/[id]` skipped — no live plan, in `EXPECTED_SKIPS`). **Scratch reading:** at start, the same 6 stale rows earlier cuts reported (`ZZ-SMOKE-*`, 890–1,533 h old, five still referenced) — none from this cut; after: 0 throwaway accounts, 0 probe roles, 7 accounts, 0 disabled |
| 12 | Live verification | §6 |

## §6 · Live verification

### §6.1 Rolled-back proof — `db/scripts/2026-10-09-mes5b3-live-proof.sql` via `.mjs` (`MES5B3_PROOF_EXIT=0`, 18:10:59–18:12:14 CST; transaction 6.5 s, ROLLBACK)

The driver minted 13 throwaway accounts (`mes5b3probe-…@test.local`: `wc`, `wr`, `ops`, `lab`, `apl`, `pv` with exactly the codes each step needs, and
seven role clones), ran the SQL as one transaction, and removed the accounts, grants and one-off roles by the ephemeral plan. Setup rows (a supplier,
a saleable black-mass material, a non-saleable anode-sheet material, two black-mass output batches with the `discharged_verified` state, all
`ZZ-PROBE-MES5B3-*`) were inserted as the owner; **every action the proof is about ran as a throwaway account**, including the assays that give the two
batches their metal content. Each line is the proof's own `STEP|` output.

| Step | What happened (measured) |
|---|---|
| Start | AP 422,188.32 / 381,604.42 / **0.00** · AR 57,545.87 / 43,002.12 / **0.00** (c_cfo) |
| Setup | B1 `OUT-2026-0685` 600 kg (ni 20 · co 6, from `ASY-2026-0005`) · B2 `OUT-2026-0686` 400 kg (ni 12 · co 3, from `ASY-2026-0006`) — recorded by lab, applied by apl |
| Plan + prediction | wc created `BLD-2026-0001` (draft; ni 15–18, co ≤ 4, li ≥ 1; B1 300 + B2 300): **ni 16 within · co 4.5 above max — flagged, not refused · li not measured**; both lines' content from an assay |
| Not saleable | wc, anode sheet as output → **`BLEND_OUTPUT_NOT_SALEABLE|ZZ-PROBE-MES5B3-AS|anode_sheet|负极片|Anode sheet`** |
| Release | wc (holding `action.wo_release` too) → **`SELF_APPROVAL_FORBIDDEN|raiser`**; wr (a second throwaway) released it |
| Execute | ops, `blending` straight into the engine → **`BLEND_RUN_FROM_PLAN_ONLY`**; ops from the plan: run `PROC-2026-0751` (blending, input 600, output 595) → blended batch `OUT-2026-0687`; **B1 planned 300 actual 310 (+10) · B2 planned 300 actual 290 (−10)**; no metal content written |
| Assay | before: every target `not_assayed`; lab recorded `ASY-2026-0007` on the blended batch (ni 16.2 · co 4.4) → **ni within · co above max · li not in the assay**; typing content onto the blended batch → `BLEND_CONTENT_FROM_ASSAY_ONLY` |
| Roles | §2 |
| Untouched | pre-existing runs, legs, batches, metal content, assays, movements, journals, expenses, payments, work orders, grade specs identical inside the transaction; notifications 2; pending `expense_claim:CLM-2026-0004`; reconciliation 0.00 / 0.00 |
| After ROLLBACK | plans 0 · probe materials 0 · probe suppliers 0 · `require_calibrated_since` NULL |

**Burned codes** (sequences do not roll back): `OUT-2026-0685`–`0687`, `PROC-2026-0751` and the weighing and movement numbers the proof drew; earlier
the smoke and the surveys drew their usual ones. BLD, ASY and the other gapless codes burn nothing (they are MAX+1 inside the rolled-back transaction).

### §6.2 Read-only — the role table

§2.

### §6.3 Before and after

Before 17:04:24 (after the dry run, before the backup), after 18:12:26 CST; `db/scripts/2026-10-06-mes1-live-readings.sql` (`postgres`, base tables,
one digest per public table) and `db/scripts/2026-10-05-at1d3-live-recon.sql` (tim@'s session, read-only); plus targeted reads.

| Reading | Before | After |
|---|---|---|
| Per-table digests (282 public base tables before, 285 after; `change_log` counted apart) | — | **every one identical** except the migration's own: `operation_types` 8 → 9, `operation_type_input_forms` 20 → 23, `operation_type_output_forms` 25 → 28, `operation_type_safety_states` 13 → 14, `document_types` 55 → 56, `role_permissions` 348 → 349 (admin + `module.tasks.view_all`) — and `cod_verification_failures` (the smoke's documented COD-verify rotation: 1 DELETE + 1 INSERT); three new tables, **0 rows** each |
| Runs · legs · batches · metal content · assays · movements · journals · expenses · payments · work orders · grade specs | — | identical (inside the migration's proof, inside the live proof, and in the digests here) |
| Every real role's codes | admin 74 · cco 42 · cfo 32 · cto 34 · finance 41 · gm 21 · warehouse 28 | admin **75 / 75** · cco 42 · cfo 32 · cto 34 · finance 41 · gm 21 · warehouse 28 |
| Accounts | 7, 0 disabled, 0 throwaway; admin@ admin · chooer@ finance · fusheng@ warehouse · phua@ cto · sandra@ cco · tim@ cfo · vince@ gm | **identical** |
| Approvals · pending · notifications | ON · 1 (`CLM-2026-0004`, not mine) · 2 | ON · 1 (same) · 2 — none of mine |
| `require_calibrated_since` | NULL | **NULL** |
| Leftovers of mine | — | 0 `mes5b3probe` accounts · 0 `probe-` roles · 0 `ZZ-PROBE-MES5B3` rows · 0 blending plans |
| `change_log` | 22,667 rows, max seq 25,326 | 24,134 rows, max seq 26,852 — the migration's **10** INSERTs (seeds + the admin grant) and balanced INSERT / DELETE pairs from the throwaway machinery of the surveys, the smoke and the proof (roles 18 / 18, `user_roles` 18 / 18, `role_permissions` 664 / 664 besides the admin grant, employees 11 / 11, reviews 5 / 5 + 5 updates, contracts and their term tables 1–2 / 1–2) plus the COD rotation. The proof itself left none (rolled back) |
| Reconciliation (tim@) | AP 422,188.32 / 381,604.42 / **0.00** · AR 57,545.87 / 43,002.12 / **0.00** | **identical** |
| V1 (pending values, tim@'s session) | 6 operations | 7 — `blending` added (its tolerance deliberately not set) |

### §6.4 Broken window

Start **2026-10-09 17:21:45 CST** (measured: `apply_migration.sh` printed it at commit and wrote `db/migration-windows.tsv`). End: Tim confirms the
deployment in Vercel (this machine cannot reach Vercel — AGENTS.md). What is broken inside it (**derived**, not measured on live): nothing the old app
calls — `blending` is `started_from_run_page`, so the old new-run form never offers it; the two new guards refuse only paths the old app does not take
(a blending run outside a plan; typed content on a blended batch — live has none); the old app has no blending pages; admin's extra code is read by
the old app the same way as any code (admin@ can now read others' personal tasks, which is the ruling). The old app's generated types lack the new
objects, which it does not query.

## §7 · Decisions taken without asking

1. **"Saleable powder" = the blending operation's own declared forms** (black mass, cathode powder, anode powder — all `may_be_sold`). The output
   material is refused by name if its form may not be sold (`BLEND_OUTPUT_NOT_SALEABLE`, Q20) **and**, separately, if it is not a form blending
   produces (`BLEND_OUTPUT_FORM_NOT_BLENDABLE`); a line's batch must be a form blending takes (`BLEND_LINE_FORM_NOT_BLENDABLE`). Kg only.
2. **Blending accepts only `discharged_verified`** batches (safety-state acceptance), which also keeps fixture 178 D3's coincidence true.
3. **No tolerance, field, machine or recipe set on `blending`** (the brief: nothing set on live beyond the operation) — so it now appears under
   **V1** like every other transforming operation (not a new pending value).
4. **A database guard for "only from the plan page"**: a transaction-local flag set by `execute_blending_plan` around the engine call; any other
   blending insert is refused `BLEND_RUN_FROM_PLAN_ONLY`. Insert only (a run's operation cannot be changed afterwards anyway).
5. **"Content from an assay only" is a guard on `output_batch_metals`**: a non-assay row on a blended batch is refused
   (`BLEND_CONTENT_FROM_ASSAY_ONLY`); the trigger is owner rights so a reader who cannot see processing cannot read "zero rows" as permission.
6. **The outcome compares the blended batch's latest valid recorded assay** (not deleted, not superseded; by assay date, then code) — recording is
   enough, applying is not required; values compared as recorded with the weight basis shown, no conversion (the `contract_grade_breaches` precedent).
7. **The prediction is restricted when the reader cannot view any one of the plan's batches** (with one line, the prediction *is* that batch's
   content); the targets' bounds are never masked.
8. **Prediction on planned kg; the flag compares the unrounded value** (the screen rounds to two decimals).
9. **Actual kg is not stored on the lines** — it is the run's input legs (`blending_plan_execution`), so a second copy cannot drift; actual 0 = not used.
10. **`BLEND_NO_OTHER_RELEASER` at create** (the work-order rule: a plan nobody else can release is not born).
11. **Four-eyes is the creator only** (the work-order rule); an editor of someone else's draft is not barred from releasing it.
12. **Release needs at least one target and one line.**
13. **Cancel is `action.wo_create`** (an edit), draft or released, reason required; an executed plan cannot be cancelled (its run goes through rollback).
14. **A plan stays `executed` if its run is later rolled back**; the page says the run was rolled back; no re-execution in this cut.
15. **Editing a draft replaces its targets and lines wholesale** (change-logged deletes and inserts).
16. **Copying a contract:** no targets given + a contract → every grade spec applicable to the output material (a material-specific spec wins over a
    generic one for the same metal); a spec named explicitly must belong to the plan's contract and suit the material; copied bounds are snapshots.
17. **Planned kg is not refused above a batch's stock** (a plan can be for later); the engine refuses at execution as usual. The form lists only kg
    batches with stock left.
18. **The validator is INVOKER, not DEFINER** (the `reverse_expense_internal` shape — the offline gate's definer check caught the first version).
19. **The trail uses the generic wording family**, with the parent plan id hidden on child rows (the trail lives on that plan).
20. **The plan page shows the contract as "Restricted"** when the reader cannot read it (contracts follow customer / supplier view).
21. **`execute_blending_plan`**: allocation basis `weight`, no machine, notes default "Blending plan BLD-…".
22. **The live proof's batches are output batches** inserted as setup, with their metal content from assays recorded and applied by throwaways
    (the brief's "batches with assays"); its creator also held the release code, to prove the self-refusal rather than a missing code.
23. **The layout survey used a temporary harness** of the real `[id]` components (live has no plan; never committed).
24. **My step-1 probe script's two lint warnings were fixed in this cut** (an IIFE and a ternary used as statements) — the build's lint freeze caught them.
25. **One fixture (259) carries the admin arm too**, beside the existing 257 FCHECK assertion.

## §8 · Assertions measured and found false or imprecise

1. **Step 1 f** — "the allocation page … renders the reverse action": live has no allocation; "an expense page … with its reason field": the expense
   reversal never had one (§0).
2. **Step 0 §8's fixture list** names 100 and the search / document registries for BLD; **fixtures 101 and 254 also pin the registry** (47 → 48 pairs,
   55 → 56 rows) — found by the offline gate, updated.
3. **Step 0 §10 "V1 is untouched except that the split stops appearing"** — true for MES-5b-1; with this cut `blending` appears under V1 (decision 3).
4. **My first V1 reading after the migration read 0 rows** — as `postgres`, on a gated view (`pending_values` answers per caller). Re-read in tim@'s
   session: 7. Recorded because it is exactly AGENTS.md's "a 0-row reading: ask who read it".
5. **My verification shell once imported `scripts/smoke-routes.mjs` while checking its syntax** (an `import()` executes the module). Checked at once:
   no process, no live-lock, 0 throwaway accounts on live — it did nothing; the real smoke ran later on its own.
6. **The brief's opening facts** (SHA, clean tree, 7 accounts enabled, approvals ON, `require_calibrated_since` NULL, admin 74 / 75, nothing set) — all
   re-measured and as stated.

## §9 · Docs updated

`docs/forward-queue.md` (item 45: the MES-5b-2 window closed and the close-out; item 46; MES group header and table rows 8c ✅ / 9 next) ·
`docs/known-issues.md` (`MES5B2-PREPAYMENT-APPLIED-EXPENSE-NOT-REVERSIBLE` ruled; `MES5B1C-ADMIN-TASKS-VIEW-ALL-UNRULED` closed) · `docs/role-matrix.md`
(admin holds every code; the blending row) · `docs/change-log.md` §22 · `docs/mes-pending-values.md` (V1 lists blending) · `docs/handbacks/MES-5b-2.md`
(the prepayment ruling) · `db/migration-windows.tsv` (the window start) · `docs/surveys/AUDIT-TRAIL-0/labels.csv` (the three tables) ·
`docs/surveys/MES-5b/MES-5b-2-CLOSEOUT.md` (step 1).
