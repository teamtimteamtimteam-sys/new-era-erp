v1.4.45 — Material balance and yield: every batch now shows where its mass went (on hand, sold, written off, and what each processing run made of it), a new monthly balance shows input, outputs, named losses and the unexplained remainder plant-wide and per step, and yield is shown per run, per step and per month; deep discharge and quarantine splits now count as mass passing through rather than consumed, so the lifetime balance on the inventory page may show different figures.

# MES-5b-1 — material balance and yield, the action-implies-view check, the bootstrap admin (MES group, ninth cut; 2026-10-08)

Tim answered MES-5b Step 0 on 2026-10-08 (`docs/surveys/MES-5b/STEP0-HANDBACK.md` §14): **Q2** — three cuts; this is MES-5b-1 Balance and yield
with the f check and the Q31 fix. **Q15** — V37, Not yet set, flags only. **Q16** — the current line does not blend, a future line will:
MES-5b-3 Blending is built later as recommended. **Q31** — the bootstrap admin holds every code, the bootstrap finance role gains
`module.processing.view`, live roles untouched. Every other balance / yield / f recommendation accepted exactly as stated.
Migration `db/migrations/2026-10-08-mes5b1-balance-and-yield.sql` (2,005 lines, built from the mirrors by `db/scripts/build_mes5b1_migration.py`).
Opening SHA: HEAD = origin/main = `git ls-remote origin main` = `a82ac6da824ebb4afb235ee8452af3cb7a1232ae` (tree clean; 19:39 CST).

---

## §0 · Opening live readings (before anything changed)

Read 2026-10-08 **19:40 CST** as `postgres` (`rolbypassrls = true`) over direct psql, `BEGIN READ ONLY … ROLLBACK`, base tables only
(`db/scripts/2026-10-08-mes5b1-opening-readings.sql`, `READ_OWN_EXIT=0`). Re-read identical at 21:08 CST before the backup.

| Reading | Value |
|---|---|
| Runs by era | **14**, all **pre-MES-4a** (`started_at` NULL): 10 committed, 4 reversed (deleted). **MES-4a-era: 0** |
| Runs by operation | no operation 13 · `deep_discharge` 1 (PROC-2026-0494, reversed) · `corrects_run_id` set 0 |
| Closures · loss rows · split rows | **0 · 0 · 0** |
| /inventory lifetime balance, as today's code computed it | Σ over runs with `deleted_at` NULL (`app/inventory/page.tsx:152-155,326-328`): **10 runs · input 5,242 · output 4,193 · loss 1,049** (20.0 %) |
| Material chemistry | 5 live materials: **2 with** (`MAT-2026-0001` NMC, `ZZ-SMOKE-NTF` LFP), **3 without**; 9 rows in all (4 deleted) |
| Every role's codes | admin 74 (all of the 75 but `module.tasks.view_all`) · cco 42 · cfo 32 · cto 34 · finance 41 · gm 21 · warehouse 28 · auditor 20 · hr 8 · operations 15 · procurement 16 · sales 17 · employee 0; catalogue **75** codes (34 action). Holders: admin@ admin · sandra@ cco · tim@ cfo · phua@ cto · chooer@ finance · vince@ gm · fusheng@ warehouse; the other six roles have no holder |
| Accounts · approvals · pending | 7, 0 disabled, 0 throwaway · approvals ON · 1 pending (`expense_claim:CLM-2026-0004:1000.00`, not mine) |
| `change_log` · notifications · `require_calibrated_since` | 17,967 rows, max seq 20,103 · 2 · NULL |
| Operation tolerances | all 8 operations NULL (including `discharge_quarantine_split`) |
| Reconciliation (tim@, 21:08) | AP list 422,188.32 / ledger 381,604.42 / **unexplained 0.00** · AR 57,545.87 / 43,002.12 / **0.00** |

"For every batch that has any" — today's code computes the lifetime balance **plant-wide only**; it has no per-batch figure. The per-batch
reading below is what that plant figure was made of (each batch's input legs into the runs it counted):

| Batch | kg counted by today's /inventory | Runs counted | kg in reversed runs (not counted) |
|---|--:|--:|--:|
| IN-2026-0001 | 4,113 | 6 | 2,000 (PROC-2026-0002) |
| IN-2026-0011 | 14 | 1 | — |
| IN-2026-0152 | 405 | 1 | — |
| IN-2026-0153 | 680 | 1 | — |
| IN-2026-0180 | 30 | 1 | — |
| ZZ-PROCCOST1-DEMO | — | 0 | 10 (PROC-2026-0494, the reversed discharge) |
| ZZ-SMOKE-IB25 | — | 0 | 20 (PROC-2026-0142) |
| OUT-2026-0159 | — | 0 | 10 (PROC-2026-0143) |

## §1 · Role-by-role reading table (live, measured)

Read inside the live proof (`db/scripts/2026-10-08-mes5b1-live-proof.sql` via `.mjs`, `MES5B1_PROOF_EXIT=0`, 22:31:57–22:33:27 CST; the transaction
14.8 s, ROLLBACK), after my rows existed — live has no MES-4a-era run, so without them the yield page and a batch panel would only show the
legacy figures. Each row is a **one-off clone of a real role** (`mintThrowaway { cloneOf }`: a `probe-` role holding exactly that role's codes
at that moment — 74 / 41 / 28 / 34 / 42 / 32 / 21 codes); no real account read or acted. Subjects: my month (2026-10), my supplier one, my inbound
batch A (`IN-2026-0496`) and my output batch O1 (`OUT-2026-0682`). "open / refused" is the page gate (`has_permission`, the same predicate as
`can()`); a number is rows the clone reads itself through the gated reader.

| Real role (live account) | `/operation/balance`: page · monthly rows · this month's input · roll-forward rows | `/operation/yield`: page · rows · **supplier name** | Batch panel on `/inbound/[id]/edit`: page · rows | on `/output/[id]/edit`: page · rows | `/inventory` lifetime input |
|---|---|---|---|---|---|
| admin (admin@) | open · 39 · 400 · 5 | open · 78 · ZZ-PROBE-MES5B1 supplier one | open · 46 | open · 23 | open · 5,642 |
| finance (chooer@) | open · 39 · 400 · 5 | open · 78 · ZZ-PROBE-MES5B1 supplier one | open · 46 | open · 23 | open · 5,642 |
| warehouse (fusheng@) | open · 39 · 400 · 5 | open · 78 · ZZ-PROBE-MES5B1 supplier one | open · 46 | open · 23 | open · 5,642 |
| cto (phua@) | open · 39 · 400 · 5 | open · 78 · ZZ-PROBE-MES5B1 supplier one | open · 46 | open · 23 | open · 5,642 |
| cco (sandra@) | open · 39 · 400 · 5 | open · 78 · ZZ-PROBE-MES5B1 supplier one | open · 46 | open · 23 | open · 5,642 |
| cfo (tim@) | open · 39 · 400 · 5 | open · 78 · ZZ-PROBE-MES5B1 supplier one | open · 46 | open · 23 | open · 5,642 |
| gm (vince@) | open · 39 · 400 · 5 | open · 78 · ZZ-PROBE-MES5B1 supplier one | open · 46 | open · 23 | open · 5,642 |
| *(throwaway `pv`: `module.processing.view` only)* | open · 39 · 400 · 5 | open · 78 · **restricted** | **refused** · (46) | **refused** · (23) | **refused** · 5,642 |

How to read it: **all seven real roles see everything here, and none of them sees the supplier name restricted — every one of them holds
`module.inbound.view`** (opening reading). The restriction is therefore shown by the extra throwaway reader `pv`, which holds only
`module.processing.view`: the yield page opens, and the supplier group reads "restricted" (`group_label` NULL, `group_label_restricted` true —
not blank). Its batch-panel rows are readable through the reader's `module.processing.view` arm, but the two batch pages and `/inventory`
refuse it at their own gates, so it never reaches a panel. "Lifetime input 5,642" = the legacy 5,242 plus my 400 inside the transaction.
**No grant changed; no approval added (Q32).**

## §2 · Every item built

### §2.1 Database (one migration)

- **Twelve new views**, all owner rights (`security_invoker = off`). Seven base views, SELECT revoked from `authenticated` and `anon`:
  `processing_run_flow_all` (each run's class — consumption / pass_through / transfer / reversed — with `not_kg`, the MES-4a era and its kg from
  `processing_run_balance_all`, one arithmetic) · `processing_balance_monthly_all` · `stock_rollforward_monthly_all` · `batch_balance_tree_all`
  (the recursive forward tree, exact shares as `share_num` / `share_den`) · `processing_run_yield_all` · `processing_run_origin_share_all` ·
  `processing_yield_summary_all`. Five gated readers: `processing_balance_monthly` and `stock_rollforward_monthly` (processing, finance or
  inventory view — the code set `processing_run_lookup` used for the same mass figures), `batch_balance_tree` (processing view, or the root
  batch's own view code), `processing_run_yield` and `processing_yield_summary` (processing view; the supplier label only with inbound view).
- **Two new columns:** `permissions.requires_view_any text[]` (33 action codes declared; `action.anonymise_employee`, which has no screen,
  undeclared) with the catalogue's own self-check · `operation_type_output_forms.expected_yield_pct` (V37, 0–100, empty).
- **One seeded value:** `discharge_quarantine_split.balance_tolerance_pct = 0` (Q11).
- **Replaced (same signatures):** `set_role_permissions` (refuses `ACTION_REQUIRES_VIEW|<code>|<views>`) · `split_failed_modules_to_quarantine`
  (closes its own run's balance through `close_run_balance`, in the same transaction) · `pending_values` (+ V37 arm; 19 → 20 arms).
- **Bootstrap only (mirror, not live):** `db/tables/role_permissions.sql` — admin = every code but `module.tasks.view_all`; finance +
  `module.processing.view`; the self-check gains the action-implies-view rule (Q31).
- **Rebuild tooling:** `db/check_mirrors.py` `view_replay_order` sorts by dependency depth (closes `MES5A1-VIEW-REPLAY-ORDER-NOT-TOPOLOGICAL`);
  the `permissions` seed comparison includes the new column.
- **The migration's own proof** (in the same transaction): approvals ON; grants unchanged; accounts unchanged; pending documents unchanged and
  each still has a decider; digests of runs, legs, losses, closures, batches, movements, journals, journal lines, expenses, payments, devices,
  safety states, cost entries and splits unchanged; `operation_types` changed only in the split's tolerance; output forms gained only an empty
  column; `change_log` rows exactly 33 `permissions` + 1 `operation_types`; **every live role satisfies action-implies-view (0 violations)**;
  anon executes exactly the two; base views unreadable, readers readable; 44 open read policies; change-log coverage 0 gaps (8 excluded);
  mask gaps 0 (111 rules); 59 reminder arms; 20 pending-value arms.

### §2.2 Fixtures

- **257** (new) — arms CONS · ATTR · BAL · PRE · INV · MONTH · NOTKG · ROLL · YIELD · V37 · GROUP · READ · FCHECK · LOG. Data: A (NMC, S1, 200) and
  B (no chemistry, S2, 100) into R1 (battery powder line, black mass 170 + collected dust 80, sweepings 20, remainder 30, on a machine); O1 100
  into R2 (90, moisture 4, remainder 6); C (modules, 400) discharged, M03 split out (90), a disassembly reversed and corrected, a disassembly
  of 200 (equipment hold-up 4); a pre-MES-4a run E 50 → 40; a pcs batch run. Exactness is asserted as rationals: for every run node,
  Σ child.x × child.num × parent.den = parent.x × parent.num × child.den; for every batch node, Σ fates = received, unexplained 0,
  consumed = Σ consuming runs, split = Σ split runs.
- **255 SPLIT** gains: the split run is `closed`, its closure row holds remainder 0, input = output = 90, tolerance 0, within, no explanation;
  the split operation's tolerance is 0; the split is absent from the unclosed-balance reminder, the month-end warning and V1.
- **Fault injection** `db/scripts/2026-10-08-mes5b1-fixture-injections.py`: **36 cases on 257 + 2 on 255, each red in the arm it names, every
  arm red at least once; plus 2 rebuild cells** (a mirror copy with finance's `module.processing.view` removed → rebuild fails
  `BOOTSTRAP_ACTION_REQUIRES_VIEW|finance -> action.wo_release`; with `action.wo_create`'s declaration removed → `PERMISSIONS_REQUIRES_VIEW_UNDECLARED|action.wo_create`).
  Last run after the last edit, against a fresh rebuild of the final mirrors: `INJECTIONS_OWN_EXIT=0` (22:35 CST).
- **235** stays at 8 exclusions; **100** and the search / document registries unchanged (no new code prefix).

### §2.3 App

- `/operation/balance` and `/operation/yield` (new, under Operation; `requireFunction(FN.balance / FN.yield)`).
- A balance panel on both batch pages (`app/components/batch/BatchBalancePanel.tsx`).
- `/inventory`'s balance strip reads the monthly view, with a sentence saying discharge and splits are not consumption and a link to the monthly balance.
- Month-end: the "material balances closed" step stays a warning and gains a link to that month's balance.
- Operation page: "Expected yield per output form (V37)" (`ExpectedYieldPanel.tsx`, `setExpectedYield`).
- Role editor: `ACTION_REQUIRES_VIEW` in words (`permissions.errActionRequiresView`).
- Messages `massBalance` (en / zh); `processing.subnav.balance` / `yield`; V37 labels; the constraint sentence for V37.
- Build check `scripts/check-action-view-declared.mjs` (in `npm run build`; faults `CHECK_AVD_FAULT=bogus-view` → exit 1, `blind` → exit 2, both measured).
- Trail: labels for the two new columns; wording arm ㉓ (`wording-drift-mes5b1` → `TW_FAULT_OWN_EXIT=1`, red in ㉓ only; clean `TW_CLEAN_OWN_EXIT=0`).
  The three pinned sentences: "Operation type output form edited · Expected yield (%): (empty) → 70" · "Permission edited · Needs one of these
  views: (empty) → module.processing.view" (system) · "Material balance closed · within tolerance · Input: 90 · Outputs: 90 · Named losses: 0 ·
  Remainder: 0 · Tolerance (%): 0".

## §3 · Pages — every new or changed route, with its file

| Route | File(s) | What changed |
|---|---|---|
| `/operation/balance` (new) | `app/operation/balance/page.tsx`, `MassTable.tsx`, `labels.ts`, `lib/massFormat.ts` | month picker; plant-wide lines with the identity sentence; per operation; stock roll-forward; "live figures, not frozen" |
| `/operation/yield` (new) | `app/operation/yield/page.tsx` (+ the two shared files above) | month and grouping (none · machine · chemistry · supplier); per operation × form / total / losses (recoverable marked) / remainder; V37 column and "Below expected" flag; per run; pre-MES-4a notes |
| `/inbound/[id]/edit` | `app/inbound/[id]/edit/page.tsx`, `app/components/batch/BatchBalancePanel.tsx` | "Where this batch's mass went" |
| `/output/[id]/edit` | `app/output/[id]/edit/page.tsx`, same panel | the same, for an output batch |
| `/inventory` | `app/inventory/page.tsx` | lifetime balance from the monthly view; a note and a link |
| `/finance/month-end` | `app/finance/month-end/page.tsx` | the material-balance step links to that month's balance |
| `/operation/operation-types/[code]` | `page.tsx`, `ExpectedYieldPanel.tsx`, `app/operation/operation-types/actions.ts` | V37 per output form |
| `/settings/roles/[id]` (save) | `app/settings/accountsActions.ts` | the `ACTION_REQUIRES_VIEW` refusal in words |
| `/settings/pending-values` | messages only | V37 |
| navigation | `lib/modules.ts`, `lib/deepRoutes.generated.ts` | Operation › Material balance · Yield |

## §4 · Verification, in the brief's order

| # | Step | Result |
|---|---|---|
| — | Before the window | Local rebuild + fixture 257 iterated off-repo; injection script built and run twice on the local rebuild; pre-window `npm run build` against a temporary type splice from the rebuild catalogue: `PREBUILD_OWN_EXIT=0` (fourth run; the first three caught the deep-route list, a phone-priority literal and the trail catalogue, each fixed). Preflight ✓ (2 functions replaced, 1 temp helper, 2 columns, 0 on masked tables). **Live dry run** of the built file, `COMMIT` → probe + `ROLLBACK`: `DRY_OWN_EXIT=0` (21:03:43 → 21:04:23; probe: 33 declared, tolerance 0, 23 monthly rows). Live proof rehearsed end-to-end on the local rebuild |
| 1 | Offline gate | `GATEOFF_EXIT=0` (78 s; fixtures 255 and 257 ✓) |
| 2 | Backup (background) | `BACKUP_EXIT=0`, `evoltrya-backup-2026-10-08-2107.dump` (7.1 MB; TOC 8,525 entries; previous 8,393); `change_log` 17,967 / max 20,103 at the backup and again just before the apply |
| 3 | `apply_migration.sh` | `APPLY_OWN_EXIT=0`; applied 21:26:38, **committed 21:28:31 CST = window start** (`db/migration-windows.tsv`) |
| 4 | `types:gen` | `TYPES_OWN_EXIT=0` (with `DO_NOT_TRACK=1`; tail clean); 1,270 lines added, 0 removed — this cut's views and the two columns |
| 5 | tsc | `TSC_OWN_EXIT=0` |
| 6 | `npm run build` | `BUILD_OWN_EXIT=0` (every static check incl. `check-action-view-declared` and trail arm ㉓, then `next build`, compiled 22.6 s; both new routes listed) |
| 7 | Full gate | `GATE_EXIT=0` (566 s): rebuild ✓ · mirrors vs live "NO DIFFERENCES" (incl. generated types and the `permissions` seed rows with their declarations) · fixtures ✓ (**260**) · anonymous surface ✓ (subset of the 328-line baseline); change log **282 tables · 274 logged · 8 excluded**, masks **37 tables / 111 columns**, zero gaps, live and rebuild |
| 8 | i18n | `I18N_OWN_EXIT=0` |
| 9 | Error swallowing | `SWALLOW_OWN_EXIT=0` (0 unallowed, 9 allowlisted) |
| 10 | Layout survey | 11 targets, live data, after `rm -rf .next` (the probe refuses a built tree): `/operation/balance`, `/operation/yield`, `?group=supplier`, `?group=chemistry`, `/inventory`, `/finance/month-end?month=2026-08`, `/inbound/<IN-2026-0001>/edit`, `/output/<OUT-2026-0184>/edit`, `/output/<OUT-2026-0003>/edit`, `/operation/operation-types/battery_powder_line`, `/settings/pending-values`. **1280 px: 11 / 11 at 0 px overflow, 0 clipped** (`LSURVEY1280_OWN_EXIT=0`). **390 px: 10 / 11 at 0 / 0**; `/finance/month-end` **+6 px**, culprit a detail `td` — **pre-existing**: the same page on the pre-cut file (`git show HEAD:`, swapped in for one measurement and swapped back) reads the same +6 px with the same culprit (the figure MES-4a recorded) (`LSURVEY390_OWN_EXIT=0`, `LSURVEY_BEFORE_OWN_EXIT=0`) |
| 11 | Smoke (background) | `SMOKE_EXIT=0` — **277 ok, 13 skipped (no data), 0 failed** (264 routes plus the probes; 251 timed, 1,443.7 s). **Scratch reading:** at start, the same 6 stale rows earlier cuts reported (`ZZ-SMOKE-*`, 870.8–1,513.1 h old, five still referenced) — none from this cut; its throwaway account and grants were cleaned (after: 7 accounts, 0 throwaway, 0 probe roles) |
| 12 | Live verification | §5 |

Measured cost of the new reads on live (read-only `EXPLAIN ANALYZE`, `postgres`): one batch's tree for the richest batch (`IN-2026-0001`)
8.8 ms execution / 19.9 ms planning; the whole yield summary 18.5 ms.

## §5 · Live verification

### §5.1 Rolled-back proof — `db/scripts/2026-10-08-mes5b1-live-proof.sql` via `.mjs` (`MES5B1_PROOF_EXIT=0`, 22:31:57–22:33:27 CST; transaction 14.8 s, ROLLBACK)

The driver minted 11 throwaway accounts (`mes5b1probe-…@test.local`: `rcv`, `ops`, `mgr`, `pv` with exactly the codes each step needs, and
seven role clones), ran the SQL as one transaction, and removed the accounts, grants and one-off roles by the ephemeral plan. Setup rows
(two suppliers, five materials, one quarantine location, one probe role, all `ZZ-PROBE-MES5B1-*`) were inserted as the owner; **every action
ran as a throwaway account**. Process date 2026-10-07 (live has no October run; the proof asserts it). Each line is the proof's own `STEP|` output.

| Step | What happened (measured) |
|---|---|
| Receive | rcv received A `IN-2026-0496` (S1, 200 kg) · B `IN-2026-0497` (S2, 100 kg) · C `IN-2026-0498` (S1, 300 kg, 3 modules) |
| Runs | ops committed R1 `PROC-2026-0738` (A 200 + B 100 → black mass 170 + collected dust 80; sweepings 20; remainder 30) and R2 `PROC-2026-0739` (O1 `OUT-2026-0682` 100 → 90; moisture 4; remainder 6) — the black-mass batch's safety state first recorded through `set_output_safety_states`; **both closed** (`closed_explained`: no tolerance set) |
| Discharge + split | ops committed RD `PROC-2026-0740` on C (300 kg, deep discharge), recorded M01 / M02 pass and M03 fail · quarantine, split M03 → `PROC-2026-0741`, child `OUT-2026-0684` 90 kg in the quarantine location; **the split's balance closed in the same step (`closed_within`)** |
| Tree A | received 200 = consumed 200; R1's four children carry the share **200 / 300**; R2's three carry **20,000 / 30,000** through O1; R2 attributed to A and B sums to exactly 100 (Σ x·num = 100 × 300) |
| Tree C | received 300 = on hand 210 + split 90; **deep discharge `PROC-2026-0740` an event: 300 kg passed through, not consumed**; **the split a transfer → `OUT-2026-0684` 90, no loss line, no remainder line** |
| Tree O1 · Q | O1 received 170 = consumed 100 + on hand 70 · Q received 90 = on hand 90 |
| Every level | trees A, B, C, O1, Q: no node off by anything (the rational identity of §2.2) |
| Monthly 2026-10 | input 400 = outputs 340 (black mass 260 · collected dust 80) + named losses 24 (sweepings 20 · moisture 4, measured) + remainder 36 (closed with an explanation); passed through: discharge 300 · split 90 |
| Yield | R1 black mass 56.67 % · dust 26.67 % · total 83.33 % · R2 black mass 90.00 %; month: black mass 65.00 %; **by supplier** S1 input 266.667 · S2 133.333 (both 65.00 %); **by chemistry** NMC 266.667 · "chemistry not recorded" 133.333; no yield for RD or the split |
| V37 | before: 2 pending rows for `battery_powder_line` (black mass, collected dust); ops set black mass = 70 % → R1 (56.67) flagged, R2 (90) not, the month (65) flagged; that pending row gone; **nothing refused** |
| Role save | mgr saved a role holding only `action.manage_devices` → **`ACTION_REQUIRES_VIEW|action.manage_devices|module.processing.view`**; with `module.processing.view` added it saved |
| Untouched | pre-existing runs, batches and movements identical inside the transaction |
| After ROLLBACK | probe suppliers / materials / locations / roles 0 / 0 / 0 / 0 · V37 set 0 · split tolerance 0 (the migration's) · `require_calibrated_since` NULL · runs 14 |

**Burned codes** (sequences do not roll back): IN-2026-0496–0498, PROC-2026-0738–0741, OUT-2026-0682–0684 (and the weighings and the
role-save probe's nothing). Live's next codes skip them.

### §5.2 Read-only — /inventory lifetime balance, before and after (live as it stands, no proof data)

Before: today's code until this cut (`opening-readings.sql` §2 and §4, 19:40 and 21:08, identical). After: the new view
(`db/scripts/2026-10-08-mes5b1-inventory-before-after.sql`, 22:07:53 CST, `INV_OWN_EXIT=0`).

| | Runs | Input | Output | Loss |
|---|--:|--:|--:|--:|
| **Plant — before** | 10 | 5,242 | 4,193 | 1,049 |
| **Plant — after** | 10 | 5,242 | 4,193 | 1,049 |

| Batch | Before: kg counted | After: consumed | After: split out | After: passed through | After: reversed (listed) | Runs |
|---|--:|--:|--:|--:|--:|---|
| IN-2026-0001 | 4,113 | 4,113 | — | — | 2,000 | 0001 · 0003 · 0106 · 0162 · 0163 · 0164 consumption; 0002 reversed |
| IN-2026-0011 | 14 | 14 | — | — | — | 0009 |
| IN-2026-0152 | 405 | 405 | — | — | — | 0107 |
| IN-2026-0153 | 680 | 680 | — | — | — | 0108 |
| IN-2026-0180 | 30 | 30 | — | — | — | 0225 |
| ZZ-PROCCOST1-DEMO | — | — | — | — | 10 | 0494 (the discharge — reversed) |
| ZZ-SMOKE-IB25 | — | — | — | — | 20 | 0142 reversed |
| OUT-2026-0159 | — | — | — | — | 10 | 0143 reversed |

**The figure does not change on live today**, because the only discharge run on live is reversed (it was never counted) and there is no split;
it changes from the first committed discharge or split. Every one of the **44** batches' trees balances (unexplained 0 in all 44).

### §5.3 Read-only — the role table

§1.

### §5.4 Before and after

Before 21:08:07, after 22:34:22 CST; `db/scripts/2026-10-06-mes1-live-readings.sql` (`postgres`, base tables, one digest per public table) and
`db/scripts/2026-10-05-at1d3-live-recon.sql` (tim@'s session, read-only).

| Reading | Before | After |
|---|---|---|
| Per-table digests (281 public base tables; `change_log` counted apart) | — | **277 identical**; the 4 that differ: `permissions` (the 33 declarations), `operation_types` (the split's tolerance 0), `operation_type_output_forms` (the new empty V37 column — 0 values), `cod_verification_failures` (the smoke's documented COD-verify rotation: 1 DELETE + 1 INSERT) |
| Runs · legs · losses · closures · batches · movements · journals · expenses · payments · devices · states | — | identical digests (inside the migration's proof and again here) |
| V37 values · `require_calibrated_since` | — | **0 · NULL** |
| Accounts | 7, 0 disabled, 0 throwaway; admin@ admin · chooer@ finance · fusheng@ warehouse · phua@ cto · sandra@ cco · tim@ cfo · vince@ gm | **identical** |
| Approvals | ON | ON |
| Pending documents | 1 (`CLM-2026-0004`, not mine) | 1 (same) — none of mine |
| Notifications | 2 | **2** |
| Leftovers of mine | — | 0 `mes5b1probe` accounts · 0 `probe-mes5b1*` roles · 0 `ZZ-PROBE-MES5B1` rows |
| `change_log` | 17,967 rows, max seq 20,103 | 19,283 rows, max seq 21,538 — +1,316: the migration's 34 (33 `permissions` UPDATE + 1 `operation_types` UPDATE) and balanced INSERT / DELETE pairs from the throwaway machinery of the three surveys, the smoke and the proof (roles 15 / 15, `user_roles` 15 / 15, `role_permissions` 586 / 586, employees 9 / 9, reviews 4 / 4 + 4 updates, contracts and their five term tables 1–2 / 1–2), plus the COD rotation. The proof itself left none (rolled back) |
| Reconciliation (tim@) | AP 422,188.32 / 381,604.42 / **0.00** · AR 57,545.87 / 43,002.12 / **0.00** | **identical** |

### §5.5 Broken window

Start **2026-10-08 21:28:31 CST** (measured: `apply_migration.sh` printed it at commit and wrote `db/migration-windows.tsv`). End: Tim confirms
the deployment in Vercel (this machine cannot reach Vercel — AGENTS.md). What is broken inside it (**derived**, not measured on live): nothing
the old app calls refuses it — the two replaced functions keep their signatures; a quarantine split from the old app now also closes its own
run's balance (better, not breaking); a role save in the old app that breaks the new rule is refused by name (`ACTION_REQUIRES_VIEW`, shown as
the old localizer's fallback sentence) — no live role is in that position (0 violations, asserted). The old app has no balance or yield page,
no batch panel, and `/inventory` still sums run headers (the same numbers on live today). The old app's generated types lack the new views,
which it does not query.

## §6 · Decisions taken without asking

1. **A run with no operation counts as consumption.** 13 of the 14 live runs predate required operations; they were transforming
   (`operation_kinds` says so), and Q6 says they are included in the mass. Only an operation whose kind does not consume (deep discharge) is
   pass-through.
2. **The split is recognised by its `discharge_module_splits` rows**, not by the operation code — the split function is the only writer, and it
   keeps the classification a fact of the run.
3. **Non-kg: the whole run is left out, not just the leg** (Q10 said "legs"). A run with mixed units has no defined input, remainder or yield;
   it is listed as "unit not kg — not summed"; the batch whose kg left stock still balances (`consumed_not_kg`).
4. **Exactness as a pair of numbers.** Shares are carried as `share_num` / `share_den` (products of leg masses and run inputs), never divided;
   every level is asserted with a rational comparison. `qty` = x × num ÷ den is for the screen only (0.001 kg, 0.01 %). The supplier and
   chemistry groupings use one division (shares to the origin batch) — percentages on screen, not the balance.
5. **The batch identity has more lines than Q5 listed**: "voided by a reversal" (an output of a reversed run) and "consumed by a run with a non-kg
   leg" are real fates, and an "unexplained" line closes it. Unexplained is a real check — consumption comes from run legs, stock from
   movements — not a catch-all; it is 0 on all 44 live batches.
6. **The monthly and roll-forward readers admit processing, finance or inventory view** (the code set `processing_run_lookup` used for the
   same figures), so `/inventory` and the month-end link keep working for whoever reads them today; the `/operation/balance` page itself is
   gated on processing view.
7. **The batch-tree reader admits processing view or the root batch's own view code** (Q4's "plus the batch's own view code").
8. **"Chemistry" and "supplier" follow the run's input back to its origin batches** — inbound batches, and output batches that no run produced
   (made by hand) — by the same proportional share; chemistry is the origin material's.
9. **Yield per operation × month divides by every consuming run of that cell**, not only the runs that produced the form.
10. **A balance closed with remainder exactly 0 counts as "closed within tolerance"** even when no tolerance is set.
11. **Movements with no business date (31 on live, before FIN-32) are in no month**: the roll-forward shows them as their own row; a month's
    closing is the dated movements only, and the page says so. Months run continuously up to the current Singapore month.
12. **V37's arm needs an MES-4a-era *consuming* run** of the operation (so the split operation never appears).
13. **V37 is edited on the operation page** under `module.processing.edit` by a direct update (the same write path as the tolerance); its change
    is in the change log but not on the operation's own trail — registered `MES5B1-V37-NOT-ON-OPERATION-TRAIL` rather than a second migration.
14. **The bootstrap admin holds every code except `module.tasks.view_all`.** The brief says "every permission code, matching the standing
    ruling"; the ruling's own text is "keep + every new code" and records that admin never held `module.tasks.view_all` (reading others'
    personal tasks; "whether to add it is Tim's word"). This matches live admin (74 / 75). **If Tim meant literally all 75, it is a one-word
    change in `role_permissions.sql`.**
15. **"Self" declarations store the code itself** (`action.bulk_import` → `{action.bulk_import}`) rather than a `'self'` marker, so the rule
    "holds at least one of them" needs no special case.
16. **`module.*.edit` codes are not declared**; they keep the existing `EDIT_REQUIRES_VIEW` (their own module's view).
17. **The build check counts a page's gate as a use of its code**, and keeps two hand-written registries with reasons it verifies:
    `PAGE_GATES` (`/settings/import` gates itself with `can('action.bulk_import')`) and `DYNAMIC` (the PO raise codes and `action.approve_review`
    are fetched at runtime from `po_category_raise_code` / `review_approval_code`).
18. **The view replay order was fixed rather than renaming views** (closes `MES5A1-VIEW-REPLAY-ORDER-NOT-TOPOLOGICAL`, its deletion
    condition's injection done) — three reader/base pairs in this cut need it.
19. **The split closes through `close_run_balance`** (one judgement): if someone later adds a required field to the split operation, the split
    refuses by that name instead of closing silently.
20. **The month-end step keeps its link to the run list** and gains a second link to the month's balance.
21. **Fixture 257 runs INV before MONTH**, so an INV fault reds in its own arm.
22. **The live proof adds a fifth throwaway reader `pv` (processing view only)** — every real role holds inbound view, so no real role could
    show the supplier name restricted. `ops` also holds `module.output.edit` (a produced batch's safety state must be recorded before it is
    fed again) and `module.inventory.view` (the split moves its child into the quarantine location).
23. **The live proof dates its runs the day before the run (2026-10-07)** — live has no October run, so the month's figures are the proof's alone.
24. **Probe prefix `mes5b1probe`** added to `scripts/ephemeral.mjs` (the sweep must recognise it).
25. **The tables' first column is always kept on phones** (`MassTable`), the others by each page's declaration.

## §7 · Assertions measured and found false or imprecise

1. **"The /inventory lifetime balance figures as today's code computes them for every batch"** — today's code has no per-batch figure; it sums
   run headers plant-wide. §0 reports the per-batch legs that make up that sum.
2. **The tester line's "the lifetime balance on the inventory page may show different figures"** — on live **today** it shows the same
   figures (5,242 / 4,193 / 1,049): the only discharge is reversed and there is no split. "May" holds; it changes from the first discharge or split.
3. **Q4 "kept exact"** — the tree is exact (rational shares); the supplier / chemistry groupings divide once (rounding beyond the 15th digit).
4. **Q10 "legs … left out of sums"** — the run is left out, not the leg (decision 3).
5. **Step 0 §0 "67 / 67 pairs pass"** — confirmed by the migration's own proof: 0 violations on live (the brief's number re-measured, not quoted).
6. **The brief's opening facts** (SHA, clean tree, 7 accounts enabled, approvals ON, `require_calibrated_since` NULL, nothing set) — all re-measured
   and as stated. No other number was taken without a measurement.
7. **My first rehearsal** fed a freshly produced batch with no recorded safety state (`PRODUCED_SAFETY_STATE_NOT_RECORDED`) and split without
   inventory view (`PERMISSION_DENIED|module.inventory.view`); both are correct refusals — the proof now takes the real steps (decision 22).
8. **My first pre-window builds** failed three static checks (the deep-route list, a phone-priority literal, the trail catalogue); each fixed
   before the window.

## §8 · Docs updated

`docs/forward-queue.md` (item 44; MES group header — MES-5b-2 Reversals next, then MES-5b-3 Blending for the future line (Tim Q16); table row 8
split into 8a ✅ / 8b / 8c; the "per-tonne denominator unchosen" row struck, Q36) · `docs/mes-pending-values.md` (V37 row and "What V37 holds
back") · `docs/known-issues.md` (`MES5A1-VIEW-REPLAY-ORDER-NOT-TOPOLOGICAL` closed; `MES5B1-INPUT-UNIT-NOT-CHECKED-AT-COMMIT`;
`MES5B1-BOOTSTRAP-ADMIN-MINIMAL` registered and closed; `MES5B1-V37-NOT-ON-OPERATION-TRAIL`; the stale bootstrap sentence in
`ROLE1-BOOTSTRAP-MISSING-ROLES` corrected) · `docs/role-matrix.md` (the standing rule is now a mechanism, how it reads and where it is
enforced; the §8 row) · `docs/change-log.md` §20 · `db/migration-windows.tsv` (the window start) · `docs/surveys/AUDIT-TRAIL-0/labels.csv`
(the two new columns).
