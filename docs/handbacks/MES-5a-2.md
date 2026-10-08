v1.4.44 — Energy: electricity meters can be set up on devices and their readings recorded, each processing run gets its share of a machine's metered electricity (by recorded run energy, or by run time when that is missing), and an electricity bill is posted once through an allocation that spreads it across the runs it covers and replaces any hand-typed estimates on them; on phones, the new processing run form and the discharge result and quarantine split forms no longer run wider than the screen.

# MES-5a-2 — energy (MES group, eighth cut; 2026-10-08)

Tim's brief of 2026-10-08 ("MES-5a-1 close-out ruling + MES-5a-2 build: energy, with the 390px fixes"): the four close-out fixes (two 390 px
forms on the discharge run page, the +177 px input-batch picker on `/operation/processing/new`, and a fault injection for the masked-view side
of the inbound `module_count` grant check) are inside this cut; Q19–Q36 answered and closed (Q22 and Q24 as recommended; Q20 with **no device
transform** on an invented payload format). Migration `db/migrations/2026-10-08-mes5a2-energy.sql` (2,986 lines, built from the mirrors by
`db/scripts/build_mes5a2_migration.py`). Opening SHA: HEAD = origin/main = `5647ea6f198d8432964cc7717b4140fd6556bed9` (the MES-5a-1 close-out).

---

## §0 · Opening live readings (before anything changed)

Read on live 2026-10-08, as `postgres` (`rolbypassrls = true`) on base tables, read-only: the opening reading at **14:18 CST**
(`docs/surveys/MES-5a-2/opening-readings.sql`) and the full before-reading at **15:37:54 CST** (`db/scripts/2026-10-08-mes5a2-live-readings.sql`,
one digest per public table plus the summary lines); reconciliation by `db/scripts/2026-10-05-at1d3-live-recon.sql` in tim@'s session (that
function filters by the reader's codes — the owner has no JWT and would read a refusal, not a measurement).

| Reading | Value |
|---|---|
| Accounts | 7, 0 disabled, 0 throwaway; admin@ admin · chooer@ finance · fusheng@ warehouse · phua@ cto · sandra@ cco · tim@ cfo · vince@ gm |
| Approvals | ON |
| Pending documents | 1 — `expense_claim:CLM-2026-0004:1000.00` (not mine) |
| Reconciliation (tim@) | AP list 422,188.32 / ledger 381,604.42 / **unexplained 0.00** · AR 57,545.87 / 43,002.12 / **0.00** |
| Devices | 4 — 2 scales, 2 gateways; **0 meters** |
| `energy_kwh` run values | **0** (the field exists on four operations: battery powder line, electrode line, electrode powder line, electrode separation) |
| Electricity cost lines (`processing_cost_entries`) | 6 live (5 estimates, 1 actual) · 4 estimates open · 1 relieved · 0 remitted · 0 soft-deleted |
| Expenses on 5110 / 6200 | 1 / 0 |
| System accounts | 35; `6200` **not** a system account |
| `change_log` | 16,531 rows, max seq 18,593 |
| Notifications | 2 |
| `require_calibrated_since` | NULL |
| Public base tables | 278 (digest per table in the before-reading log) |

## §1 · Role-by-role reading table (live, measured)

Read inside the live proof (`db/scripts/2026-10-08-mes5a2-live-proof.sql`, driver `MES5A2_PROOF_EXIT=0`, 16:51–16:52 CST), after the
allocation was posted and before the ROLLBACK — the allocation page needs an allocation, and one exists only inside that transaction. Each row is
a **one-off clone of a real role** (`mintThrowaway { cloneOf }`: a `probe-` role holding exactly that role's codes at that moment; the proof
asserts the clone's code set equals the real role's, row by row — `codes_match` true for all seven). No real account was used to act or to read.
Subjects: my meter on my machine (2 current readings), my run without recorded energy (`PROC-2026-0737`, its share 150 kWh by run time, 167.19),
my allocation (bill 1,337.50 / 1,200 kWh, 3 lines). ✓/— is the code the page's gate or control asks (`has_permission`, the same predicate as
`can()`); a number is rows the clone reads in its own session.

| Real role (live account) | Device page: open · meter readings · set meter · record reading | Run page: open · energy · basis · its share's amount | Allocation page: open · rows · bill amount · bill kWh · lines | Post a bill | V25 rows | AP · AR unexplained |
|---|---|---|---|---|---|---|
| admin (admin@) | ✓ · 2 · ✓ · ✓ | ✓ · 150 kWh (allocated) · run time · 167.19 | ✓ · 1 · 1,337.50 · 1,200 · 3 | ✓ | 1 | 0.00 · 0.00 |
| finance (chooer@) | ✓ · 2 · — · — | ✓ · 150 kWh (allocated) · run time · 167.19 | ✓ · 1 · 1,337.50 · 1,200 · 3 | ✓ | 1 | 0.00 · 0.00 |
| warehouse (fusheng@) | ✓ · 2 · — · ✓ | ✓ · 150 kWh (allocated) · run time · **restricted** | — (page closed: no `module.finance.view`) · the view gives 1 row · **restricted** · 1,200 · 3 | — | 0 | no `module.finance.view` |
| cto (phua@) | ✓ · 2 · ✓ · ✓ | ✓ · 150 kWh (allocated) · run time · 167.19 | ✓ · 1 · 1,337.50 · 1,200 · 3 | — | 1 | 0.00 · 0.00 |
| cco (sandra@) | ✓ · 2 · — · — | ✓ · 150 kWh (allocated) · run time · 167.19 | ✓ · 1 · 1,337.50 · 1,200 · 3 | — | 1 | 0.00 · 0.00 |
| cfo (tim@) | ✓ · 2 · — · — | ✓ · 150 kWh (allocated) · run time · 167.19 | ✓ · 1 · 1,337.50 · 1,200 · 3 | — | 1 | 0.00 · 0.00 |
| gm (vince@) | ✓ · 2 · — · — | ✓ · 150 kWh (allocated) · run time · 167.19 | ✓ · 1 · 1,337.50 · 1,200 · 3 | — | 1 | 0.00 · 0.00 |

How to read it: everyone opens the device and run pages and sees the kWh; **warehouse is the only role without `data.view_prices`, so the run's
share and the bill read "restricted" (NULL through the `_masked` views — not 0.00) while every kWh stays visible**. Setting a meter needs
`action.manage_devices` (admin · cto); recording a reading needs `action.confirm_capture` (admin · cto · warehouse); posting a bill needs
`module.finance.edit` (admin · finance) — a "—" control renders visible and unpressable with a sentence naming the code (DBLOCK-1). The allocation
pages are behind `module.finance.view`, which warehouse lacks; the V25 row is behind the same code. The AP / AR column is
`list_ledger_reconciliation()` in the clone's own session (its list includes the rolled-back bill: AP list 423,525.82 = 422,188.32 + 1,337.50,
ledger 382,941.92 = 381,604.42 + 1,337.50). **No grant changed; no approval added (Q29).**

## §2 · Every item built

### §2.1 Database (one migration)

- **Four new tables**, all change-logged (two triggers each), RLS on, SELECT-only to `authenticated`, no write policy:
  `meter_readings` (cumulative register readings, kWh, **append-only**: a correction or a withdrawal is a new row pointing at the old one,
  `corrects_id` unique, with its reason; `is_register_reset` + `reset_reason`; `source` manual | device with `inbox_id`, `draft_id` and the
  site-data pointer), `electricity_settings` (one row, `shared_pool_rule` = V25, RUNTIME CONFIG), `electricity_allocations` (one per bill,
  append-only; CHECKs: allocated + overhead = bill, the kWh identities, the payment shape) and `electricity_allocation_lines` (one per run,
  `run_id` unique, `basis` recorded_energy | run_time printed on every line, append-only).
- **Masked amounts** (Q30, one migration): the five amount columns of `electricity_allocations` and `electricity_allocation_lines.amount` are
  out of the column-list SELECT grant and read only through `electricity_allocations_masked` / `electricity_allocation_lines_masked`
  (`has_permission('data.view_prices')`), with six new rows in `change_log_mask_rules` (105 → 111). kWh are not masked.
- **Views:** `meter_readings_current` (chain end, not withdrawn; `previous_kwh`, `delta_kwh` — empty on the first reading and on a reset) ·
  `processing_run_energy` (own `energy_kwh` where recorded, else the allocated kWh, `energy_source`, the allocation's basis, kWh per tonne of
  **total input**, energy recovered from discharge results shown apart — never netted).
- **Functions:** `record_meter_reading` · `correct_meter_reading` (`action.confirm_capture`; refusals `METER_READING_*`, `METER_RESET_REASON_REQUIRED`,
  `METER_CORRECTION_REASON_REQUIRED`) · `meter_reading_internal` (revoked) · `electricity_allocation_compute` (revoked; the **one** implementation
  the preview and the post share) · `preview_electricity_allocation` (`module.finance.view`) · `post_electricity_allocation`
  (`module.finance.edit`) · `set_electricity_shared_pool_rule` (`module.finance.edit`).
- **Replaced:** `reverse_expense` (refuses an allocation's expense by name, `EXPENSE_IS_ELECTRICITY_ALLOCATION`) · `trail_subjects` /
  `trail_subject_members` (subjects `electricity_allocation` and `electricity_settings`; meter readings on the device; the share line on the
  run) · `change_log_mask_rules` · `pending_values` (arm V25) · `processing_cost_variance` (excludes soft-deleted estimates).
- **One pre-existing row changed:** account `6200` becomes a system account (the allocation posts to it by code).
- **Proof inside the migration:** approvals ON before and after; grants, approval settings and accounts unchanged; pending documents unchanged
  and each has a decider; row digests of runs, cost entries, run values, expenses, journals, journal lines, devices and payments unchanged;
  exactly one `change_log` row (the account); 36 system accounts; the new tables empty except the settings row (rule NULL); no meter; anon
  executes exactly the two functions it did; staff functions SECURITY DEFINER, internal ones revoked; amounts out of the column grant; 44 open
  read policies; change-log coverage 0 gaps (8 excluded), mask gaps 0 (111 rules); operations_now 59 arms; pending_values 19 arms.

### §2.2 Fixtures

- **256** (new) — arms METER · READ · RUNE · SPLIT · TONNE · ALLOC · CCY · PERM · MASK · LOG · V25 · REV. Bill 1,337.50 / 1,200 kWh; machine A
  600 kWh split 450 / 150 by recorded energy; machine B 400 kWh split 100 / 300 by run time; shared pool 50 kWh (with a reset inside, that pair
  not counted); machine D unmeasured (one reading). Runs 501.56 / 167.19 / 111.46 / 334.38; to runs 1,114.59; to 6200 222.91.
- **Fault injection:** `db/scripts/2026-10-08-mes5a2-fixture-injections.py` — 41 cases on 256, each red in the arm it names, plus **one on 255**:
  `ALTER VIEW inbound_batches_masked RENAME COLUMN module_count TO module_count_hidden` → red in 255 MC (the masked-view side of the inbound
  `module_count` grant check, ruling item 4). `INJECTIONS_OWN_EXIT=0`, 0 wrong.
- **235** stays at 8 exclusions.
- **100** re-pinned: arm 5's coverage count of functions that mint a code by `MAX(split_part(code))` moves 31 → **32** —
  `post_electricity_allocation` mints the expense code with the same `EXP` numbering as relief, and carries the `LIKE` filter the arm checks
  (the offline gate's first run named it, §5 step 1). No assertion removed.

### §2.3 App

- Device page: a meter block (machine or "shared pool", readings with "since previous", record / correct / withdraw behind `action.confirm_capture`).
- Run page: an energy panel (own vs allocated, basis, per tonne, recovered shown apart; amounts behind `data.view_prices`).
- `/finance/electricity` (list, meters overview, the V25 panel and its trail), `/finance/electricity/new` (preview, then post; any change to the
  inputs throws the preview away), `/finance/electricity/[id]` (header, split, lines with basis, trail). Navigation: Finance › Period end.
- Messages: a new `energy` namespace (en and zh), `finance.subnav.electricity`, `expense.errors.EXPENSE_IS_ELECTRICITY_ALLOCATION`, V25.
- Trail: `describeEnergy` family, meter readings in the device family, `set.electricity`; wording arm ㉒ (`wording-drift-mes5a2` turns it red).

### §2.4 Device transforms built: **none**

Q20: no meter has supplied a payload format, so nothing is built on an invented one. Readings carry `source`, `inbox_id`, `draft_id` and the
site-data pointer so a device path can land later without a schema change.

## §3 · The three fixed forms — before and after (390 px and desktop)

Measured with `scripts/survey-phone.mjs` run from a scratch copy of HEAD (outside the repo). The discharge forms render only on a committed
module-checked run and live has none, so they were measured on a scratch harness: the real `DischargePanel` with the real `loadDischargePanel`,
fed by my own committed discharge run on a **local rebuild** of the mirrors. `/operation/processing/new` was measured against **live** data, plus a
scratch-only hook that injects one 58-character option. Names at live length: cabinet label 46 characters, quarantine location 34.

| Page | Data | 390 px before | 390 px after | Desktop before → after |
|---|---|--:|--:|---|
| Discharge run page — record result + quarantine split | live-length names | **+92 px** | **0** | 0 → 0 |
| Discharge run page — record result + quarantine split | 58-character names | **+182 px** | **0** | 0 → 0 |
| `/operation/processing/new` | live data | **+177 px** | **0** | 0 → 0 |
| `/operation/processing/new` | with a 58-character option | **+180 px** | **0** | 0 → 0 |

Per control at 390 px (the survey's per-form readout, `zzForms`, which names each control's form and its longest option):

| Control | Live-length names: before → after | 58-character names: before → after | Desktop 1280 px (live / 58): before → after |
|---|---|---|---|
| Discharge cabinet select (record result) | 437 → **300** px | 527 → **300** px | 390 / 468 → 390 / 468 px |
| Photo file box (record result) | 350 → **158** px | 350 → **158** px | unchanged |
| Quarantine-location select (split) | 339 → **300** px | 500 → **300** px | 303 / 445 → 303 / 445 px |
| Input-batch select (`/operation/processing/new`) | 518 → **292** px (its own row) | 521 → **292** px | 473 → 473 px |

Every other control on the three forms has the same width before and after at both widths (the channel select 158 px; the split's shift
select 95 px at 390 px — its longest option is 5 characters, so that is its own width, not a squeeze). The input-batch select needed
`basis-full sm:basis-0` beyond the ruling's `min-w-0 max-w-full`: a first pass with only those let it shrink to **95 px** on its shared row at
390 px (measured: `after390`), so it now takes its own row below 640 px and keeps its desktop basis above.

After the fix, re-measured in step 10 on the current code (`LSURVEY_EXIT=0`): both discharge harnesses and `/operation/processing/new` read
**0 px at 390 px and 0 px at 1280 px**. (The 58-character option on `/operation/processing/new` was injected by a scratch-only hook in the first
two passes; the step-10 pass measured that page against live data only.)

## §4 · Pages — every new or changed route, with its file

| Route | File(s) | What changed |
|---|---|---|
| `/finance/electricity` (new) | `app/finance/electricity/page.tsx`, `SharedPoolRulePanel.tsx`, `actions.ts`, `energyErrorCodes.ts` | posted bills (masked view), meters overview (restricted without `module.processing.view`), the V25 panel and its audit trail |
| `/finance/electricity/new` (new) | `app/finance/electricity/new/page.tsx`, `new/NewAllocationForm.tsx`, `actions.ts` | the bill form; preview (the database's own arithmetic), then post; base currency only |
| `/finance/electricity/[id]` (new) | `app/finance/electricity/[id]/page.tsx` | one allocation: header, how the bill splits, one line per run with its basis, audit trail |
| `/operation/devices/[id]` | `app/operation/devices/[id]/page.tsx`, `MeterPanel.tsx`, `meterActions.ts` | on a meter: its machine or "shared pool", readings, record / correct / withdraw |
| `/operation/processing/[id]` | `app/operation/processing/[id]/page.tsx`, `EnergyPanel.tsx`, `DischargePanel.tsx` | the energy panel; the discharge result and quarantine split forms fixed at 390 px |
| `/operation/processing/new` | `app/operation/processing/new/NewProcessingForm.tsx` | the input-batch select fixed at 390 px |
| `/finance/expenses/[id]` (reverse) | `app/finance/expenseErrorCodes.ts` | the refusal for an allocation's expense |
| `/settings/pending-values` | messages only | V25 |
| every audit trail | `lib/trail/render.ts`, `lib/trail/text.ts`, `lib/trail/catalogue.generated.ts`, `app/components/trail/AuditTrail.tsx` | the four new tables, two new subjects |
| navigation | `lib/modules.ts`, `lib/deepRoutes.generated.ts` | Finance › Period end › Electricity bills |

## §5 · Verification, in the brief's order

| # | Step | Result |
|---|---|---|
| — | Before the window | Static chain and tsc against types spliced from a local rebuild of the mirrors: 0 errors; a pre-window `next build`: `PREBUILD_OWN_EXIT=0`. Rehearsal of the live proof on a local copy of the rebuild (approvals ON, the seven roles' live code sets copied in): every step as expected. Preflight ✓ (12 functions: 4 replaced, 8 new; the 6200 warning is the migration's own promotion). **Live dry run** of the built file, `COMMIT` replaced by the grant re-assert + `ROLLBACK`: `DRY_EXIT=0` (15:45:44 → 15:47:51, 2 m 07 s). The harness layout survey (meter panel, energy panel, allocation detail, preview) ran before the window too: 0 / 0 at both widths |
| 1 | Offline gate | First run `GATEOFF_EXIT=4`: fixture 100 arm 5 counts the functions that mint a code by `MAX(split_part(code))` — 31 expected, 32 seen; the 32nd is `post_electricity_allocation` (the expense code, the same `EXP` numbering as relief, with the `LIKE` filter the arm checks). Count moved 31 → 32 with its reason in the fixture; re-run `GATEOFF_EXIT=0` (77 s) |
| 2 | Backup (background) | `BACKUP_EXIT=0`, `evoltrya-backup-2026-10-08-1548.dump` (7,274,297 bytes; TOC 8,393 entries; previous 8,288) |
| 3 | `apply_migration.sh` | `APPLY_EXIT=0`; applied 16:03:46, **committed 16:05:51 CST = window start** (`db/migration-windows.tsv`) |
| 4 | `types:gen` | `TYPES_OWN_EXIT=0` (after the migration's `NOTIFY pgrst`); this cut's 4 tables, 4 views, 5 functions added, and one relationships block re-sorted by the generator (150 lines out, 164 in — the new foreign keys to `processing_runs`) |
| 5 | tsc | `TSC_OWN_EXIT=0` |
| 6 | `npm run build` | First `BUILD_OWN_EXIT=1`: `lib/maskedTables.ts` lagged the new types (fixed with `node scripts/gen-masked-tables.mjs`, +2 tables); second `BUILD_OWN_EXIT=1`: the lint freeze caught one new warning (an unused import in my proof driver, removed); third **`BUILD_OWN_EXIT=0`** (every static check, then `next build`, compiled in 22.8 s; `/finance/electricity`, `/new`, `/[id]` in the route list) |
| 7 | Full gate | `GATE_EXIT=0` (514 s): rebuild ✓ · mirrors vs live ✓ (incl. generated types; "NO DIFFERENCES") · fixtures ✓ (**259**) · anonymous surface ✓ (subset of the 328-line baseline); change log **282 tables · 274 logged · 8 excluded**, mask list **37 tables / 111 columns**, zero gaps, on both sides |
| 8 | i18n | `I18N_OWN_EXIT=0` |
| 9 | Error swallowing | `SWALLOW_OWN_EXIT=0` (0 unallowed, 9 allowlisted) |
| 10 | Layout survey | `LSURVEY_EXIT=0` — 12 targets × 2 widths, **every one 0 px overflow, 0 clipped tables, HTTP 200**: `/finance/electricity`, `/finance/electricity/new`, `/finance/expenses/[id]`, `/operation/devices/[id]`, `/operation/processing/[id]`, `/operation/processing/new`, `/settings/pending-values` (live data) and five scratch harnesses (the discharge forms at live-length and 58-character names; the meter panel with 5 readings and the energy panel; the allocation detail with 3 lines; the form with its preview filled — 1 machine, 3 runs) fed by rows off a local rebuild, because live has no meter, reading or allocation and this cut may not create one. Before / after of the three fixed forms in §3 |
| 11 | Smoke (background) | `SMOKE_EXIT=0` — **275 ok, 13 skipped (no data), 0 failed** (262 routes plus the probes; 249 routes timed, 1,099.8 s; `/finance/electricity` and `/finance/electricity/new` HTTP 200; `/finance/electricity/[id]` skipped — no live allocation, registered in `EXPECTED_SKIPS`). **Scratch reading:** at start, the same 6 stale rows earlier cuts reported (`ZZ-SMOKE-*`, 865–1,508 h old, five still referenced) — none from this cut; the run's own throwaway account and grants were cleaned (after-reading: 0 throwaway accounts) |
| 12 | Live verification | §6 |

## §6 · Live verification

### §6.1 Rolled-back proof — `db/scripts/2026-10-08-mes5a2-live-proof.sql` via `db/scripts/2026-10-08-mes5a2-live-proof.mjs` (`MES5A2_PROOF_EXIT=0`, 16:51:14–16:52:35 CST; the transaction 13.1 s, ROLLBACK)

The driver minted 11 throwaway accounts (`mes5a2probe-…@test.local`; four with exactly the codes each step needs, seven role clones), ran the
SQL as one transaction, and removed the accounts, grants and one-off roles by the ephemeral plan. Setup rows (a supplier, a material, a batch,
two machines `ZZ-PROBE-MES5A2-EQ` / `-EQ2`, a probe operation cloned from deep discharge plus an `energy_kwh` field) were inserted as the owner;
**every action ran as a throwaway account**. Period 2026-09-18 – 2026-09-27. Each line below is the proof's own `STEP|` output.

| Step | What happened (measured) |
|---|---|
| Meters | dev made `DEV-2026-0015` on `ZZ-PROBE-MES5A2-EQ` and `DEV-2026-0016` with no machine (shared pool); cap (no `action.manage_devices`) refused `PERMISSION_DENIED\|action.manage_devices` |
| Readings | cap recorded M1 1,000 → 1,600 and M2 50 → 80; ops (no `action.confirm_capture`) refused; M1 1,500 after 1,600 refused `METER_READING_BELOW_PREVIOUS\|1500\|1600` |
| Reset | M2 reset to 5 without a reason refused `METER_RESET_REASON_REQUIRED`; with a reason accepted, its delta empty; a direct UPDATE refused `APPEND_ONLY` |
| All runs with energy | ops committed `PROC-2026-0734` (30 kWh, 60 min) and `PROC-2026-0735` (10 kWh, 120 min) on EQ → preview: **450 kWh · recorded_energy** and **150 kWh · recorded_energy** |
| One run without | ops committed `PROC-2026-0737` (no energy, 60 min) → preview: every EQ run **by run_time, 150 / 300 / 150 kWh**, the basis on every line; metered 630 (EQ 600 + pool 30), unmetered 570; to runs 668.76, to 6200 668.74; estimate to relieve: 50 on `PROC-2026-0734` only |
| Refusals | a CNY bill refused by name on preview and on post: `ELECTRICITY_BILL_CURRENCY_NOT_BASE\|CNY\|SGD` (base read from `currencies.is_base`); finv (no `module.finance.edit`) refused `PERMISSION_DENIED\|module.finance.edit`; nothing left behind by either |
| Post | c_finance previewed and posted `ZZ-PROBE-MES5A2-BILL` (SGD 1,337.50, 1,200 kWh, unpaid, probe supplier): **the posted header and the 3 lines equal the preview, key by key** |
| Ledger | **one** expense `EXP-2026-0011` (1,337.50 SGD, account 5110; expenses +1 exactly); 3 actual electricity lines, each the run's share, settled in `JE-2026-0083`; journal **Dr 2200 668.76 · Dr 6200 668.74 · Cr 2000 1,337.50**, balanced |
| Estimates | the typed estimate 50 on `PROC-2026-0734` relieved (soft-deleted, relief → `EXP-2026-0011`); the estimate 40 on `PROC-2026-0736` (machine without a meter) untouched; ledger moves 2200 +50.00 · 5110 +618.76 · 6200 +668.74 (unmetered 570 kWh + pool 30 kWh stay in overhead) · 2000 −1,337.50 |
| AP = ledger | before the post: unexplained 0.00 both sides; after (c_cfo session): AP list 423,525.82 / ledger 382,941.92 / **0.00** · AR 57,545.87 / 43,002.12 / **0.00** |
| Run energy | dev reads `PROC-2026-0734`: **own 30 kWh** (source recorded; the bill's share 150 kWh shown apart) and `PROC-2026-0737`: 150 kWh (source allocated, run_time) |
| Mask | dev (no `data.view_prices`) reads the allocation: 3 lines, every amount NULL, kWh visible; bill amount NULL, 1,200 kWh visible |
| Untouched | pre-existing runs, cost lines, expenses, journals, payments, devices and safety states identical inside the transaction; notifications 2 (unchanged); pending documents unchanged (`expense_claim:CLM-2026-0004`) |
| After ROLLBACK | probe suppliers / materials / assets / operations 0 / 0 / 0 / 0 · meters / readings / allocations / lines 0 / 0 / 0 / 0 · V25 rule NULL · `require_calibrated_since` NULL · pending documents 1 |

### §6.2 Read-only

The role table (§1) was read inside the same transaction by the seven role clones.

### §6.3 Before and after

Before 15:37:54, after 16:52:43 CST; `db/scripts/2026-10-08-mes5a2-live-readings.sql` (`postgres`, `rolbypassrls = true`, base tables) and
`db/scripts/2026-10-05-at1d3-live-recon.sql` (tim@'s session, read-only).

| Reading | Before | After |
|---|---|---|
| Public base tables | 277 + `change_log` | 281 + `change_log` (the 4 new: `electricity_settings` 1 row — rule NULL; `meter_readings`, `electricity_allocations`, `electricity_allocation_lines` 0) |
| Per-table digests | — | **275 of 277 identical**; the two that differ are explained below |
| `accounts` | 45 rows, digest `3a6386b9166c` | 45 rows, `ee9935c132e2` — only `6200` moved: `change_log` seq 18917, UPDATE, `changed_columns` = `is_system`, `updated_at` (the touch trigger), at 16:03:53 by the migration. 35 → **36** system accounts |
| `cod_verification_failures` | 1 row | 1 row, different digest — the route smoke's documented COD-verify probe: 1 DELETE + 1 INSERT at 16:48:37 (the same rotation earlier cuts recorded) |
| Runs · cost lines · expenses · journals · journal lines · payments · devices · run values · safety states | 14 · 10 · 10 · 83 · 186 · 13 · 4 · 0 · 1 / 1 | identical digests |
| Meters · readings · allocations · V25 | 0 · n/a · n/a · n/a | **0 · 0 · 0 / 0 · rule NULL** |
| Electricity lines (live / open estimates / relieved / remitted) | 6 / 4 / 1 / 0 | 6 / 4 / 1 / 0 |
| `require_calibrated_since` | NULL | **NULL** |
| Accounts | 7, 0 disabled, 0 throwaway; roles as in §0 | **identical** |
| Approvals | ON | ON |
| Pending documents | 1 (`CLM-2026-0004`, not mine) | 1 (same) — none of mine |
| Notifications | 2 | **2** — no message left the database (`notifications` is the only message-bearing table; no `pg_net`) |
| Leftovers of mine | — | 0 `mes5a2probe` accounts · 0 `probe-mes5a2probe` roles · 0 `ZZ-PROBE-MES5A2` rows |
| `change_log` | 16,531 rows, max seq 18,593 | 17,967 rows, max seq 20,103 — +1,436, every one balanced: throwaway machinery of the two surveys, the smoke and the proof inserted and deleted in equal numbers (roles 16 / 16, `user_roles` 16 / 16, `role_permissions` 657 / 657, `employees` 11 / 11, reviews 5 / 5 (+5 updates), contracts and their five term tables 1–2 / 1–2), plus the migration's one `accounts` UPDATE and the COD rotation |
| Reconciliation (tim@) | AP 422,188.32 / 381,604.42 / **0.00** · AR 57,545.87 / 43,002.12 / **0.00** | **identical** |

### §6.4 Broken window

Start **2026-10-08 16:05:51 CST** (measured: `apply_migration.sh` printed it at commit and wrote `db/migration-windows.tsv`). End: Tim confirms the
deployment in Vercel (this machine cannot reach Vercel — AGENTS.md). What is broken inside it (**derived**, not measured on live): the old app
has no meter block, energy panel or `/finance/electricity`, so nobody can use the new machinery until the deploy; nothing the old app calls was
changed in a way that refuses it — the replaced functions keep their signatures, `reverse_expense` refuses only an allocation's expense (none
exists), `processing_cost_variance` only drops soft-deleted estimates (none on live: soft-deleted electricity lines 0), and 6200 becoming a
system account means `guard_system_account` now refuses deleting, deactivating, re-coding or un-marking it (`SYSTEM_ACCOUNT_PROTECTED` /
`SYSTEM_ACCOUNT_CODE_IMMUTABLE`) — in the old app or the new. The old app's generated types lack the new relations, which it
does not query.

## §7 · Decisions taken without asking

1. **V25 lives in a new one-row table `electricity_settings`** (RUNTIME CONFIG; its bootstrap — one row, rule NULL — is correct: NULL means "not
   given", which is the live truth). The rule is free text and is **recorded, not applied** in this cut: every allocation still leaves the shared
   pool in 6200, and the preview says so when a rule is written.
2. **`bill_kwh` is required.** The price per kWh (bill ÷ kWh) is what turns a run's kWh into money, and the unmetered remainder is bill kWh minus
   metered kWh; neither exists without it.
3. **A register reset makes the interval across it unmeasured** (that pair is skipped; the readings before and after still count).
4. **A machine counts as measured only if each of its meters has at least two readings in the period**; otherwise its runs are not covered (their
   estimates stay) and the preview names the machine as not measured.
5. **A run belongs to a period by its `process_date`.** The period window is read in Asia/Singapore days.
6. **Rounding:** kWh shares to 0.001 with the last run taking the remainder; amounts to the cent, any excess over the bill taken back from the
   largest line, and overhead = bill − allocated, so allocated + overhead = bill exactly.
7. **Periods may not overlap** (`ELECTRICITY_PERIOD_OVERLAPS` names the earlier bill), and a run already in an allocation is refused
   (`ELECTRICITY_RUN_ALREADY_ALLOCATED`) — the same electricity cannot be allocated twice.
8. **The share lines are settled through `remitted_*`** (remitted at the bill date by the allocation's journal), so they appear in the
   processing-costs settlement trail as a remittance and can never be remitted again.
9. **Relieved estimates are soft-deleted** with `relieved_at` and `relief_expense_id` stamped (the same columns month-end relief uses); their
   reversal journal is dated by the existing trigger (CURRENT_DATE). `processing_cost_variance` now excludes soft-deleted estimates.
10. **`reverse_expense` refuses an allocation's expense**, and there is no reversal path for an allocation in this cut (known-issues
    `MES5A2-NO-ALLOCATION-REVERSAL`).
11. **The expense's account is `fin_cost_account('electricity')` = 5110** (the month-end relief precedent); **no GST line** (same as relief).
12. **6200 is promoted to a system account**, because the allocation posts to it by code.
13. **The preview needs `module.finance.view`** (it reads costs and the ledger shape); posting needs `module.finance.edit` (Q27).
14. **The page offers the base currency only** (a control the server will certainly refuse is not offered); the server refuses a foreign
    bill by name anyway. A paid bill uses the base-currency bank account (`bankAccountFor(base)`).
15. **The wording arm is ㉒** (㉑ was taken by MES-5a-1).
16. **No month-end change:** an allocation leaves nothing unallocated (the whole bill is posted at once), so there is no "unallocated bills" step.
17. **The input-batch picker on `/operation/processing/new` got `basis-full sm:basis-0`** beyond the ruling's `min-w-0 max-w-full` (measured:
    without it the select shrank to 95 px at 390 px); desktop unchanged.
18. **The live proof's machines, operation and batch are my own**: two `ZZ-PROBE-MES5A2-*` fixed assets and a probe operation cloned row by row
    from deep discharge's configuration plus an `energy_kwh` field (no live discharge operation has that field; editing deep discharge itself, even
    rolled back, would touch pre-existing configuration). Setup rows were inserted as the owner; every action ran as a throwaway account.
19. **The role table reads as one-off clones of the seven real roles** (`mintThrowaway { cloneOf }` — exactly the role's codes at that moment, asserted
    inside the proof), not as the real accounts, because the allocation page needs an allocation and one exists only inside the rolled-back proof.

## §8 · Assertions measured and found false or imprecise

1. **"Location select 500 → 300" vs "→ 95".** A comparison I wrote between survey passes paired controls by position and printed the split
   form's quarantine-location select as shrinking to 95 px. Re-read by each control's own form and longest option (`zzForms`): the location
   select is 339 / 500 → **300** px; the 95 px control is the split's **shift** select (longest option 5 characters), unchanged before and after.
   No code changed on the strength of the wrong reading.
2. **My before-reading's `accounts minus is_system` fingerprint** was meant to stay identical across the migration; it did not, because the
   accounts touch trigger also moves `updated_at` on the promoted row. Measured through `change_log` seq 18917 (`changed_columns` = `is_system`,
   `updated_at`), so the reading is explained, but the fingerprint was one column too narrow.
3. **"There are no live meters, so the device page's meter block cannot be surveyed on live"** — true (0 meters), and the same holds for
   `/finance/electricity/[id]` (0 allocations). Both were surveyed through scratch harnesses fed by rows from a local rebuild (§5 step 10);
   their live rendering is unmeasured until the first real meter and bill exist.
4. **The brief's opening facts, re-measured:** 7 accounts and their roles, approvals ON, the one pending document, AP / AR 0.00 — all as stated.
   No other number in the brief was taken without a measurement.

## §9 · Docs updated

`docs/forward-queue.md` (item 42: close-out item e closed; new item 43; MES group header and table row 7b closed, MES-5b next; the MES-5a-2
section marked closed with Q20's change) · `docs/mes-pending-values.md` (V25 row and its "what it holds back") · `docs/known-issues.md` (the
+177 px row closed; `MES5A2-RELIEVE-SGD-LITERAL` (Q35), `MES5A2-NO-ALLOCATION-REVERSAL`, `MES5A2-RELIEF-REVERSAL-ORPHANS`) · `docs/role-matrix.md`
(one row) · `docs/change-log.md` (§19) · `db/migration-windows.tsv` (the window start).
