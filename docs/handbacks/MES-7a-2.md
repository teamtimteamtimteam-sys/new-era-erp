v1.4.53 — Spare parts: spare parts are received as stock lots and issued against a maintenance record, which moves their cost from stock to a new Repairs & Maintenance expense account (6800); parts can be returned with a reason, cannot be issued while unpriced or on hold, and the stock reports now show what was issued to maintenance.

# MES-7a-2 — spare parts issued to maintenance (MES group, seventeenth cut; 2026-10-16), with the MES-7a-1 close-out

Tim's brief of 2026-10-16: close out MES-7a-1 (step 1), then build MES-7a-2 as ruled in `docs/surveys/MES-7a/STEP0-HANDBACK.md` (Q2 · Q10–Q17 ·
Q20–Q23; Q11: 6800 Repairs & Maintenance, a system account). Migration `db/migrations/2026-10-16-mes7a2-spare-parts.sql` (3,008 lines, built from
the mirrors by `db/scripts/build_mes7a2_migration.py`).

**Opening check.** First command **2026-10-16 11:12:00 CST**. Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
`e689b241a22de77a90ee4e2c6560827355246139`. Files staged by explicit path only.

---

## §0 · Step 1 — the MES-7a-1 close-out, item by item

Full evidence in `docs/surveys/MES-7a-2/MES-7a-1-CLOSEOUT.md`; committed as **"MES-7a-1 close-out"** (`99cb8d39ee072214cb7e35c3390e21d096d1c2e2`,
fresh clone with no `.env.local`: `CI_OWN_EXIT=0`, `X_OWN_EXIT=0`) and pushed before step 2 began.

1. **Broken window closed** (`docs/forward-queue.md` item 51): start **2026-10-16 00:54:58 CST** (`db/migration-windows.tsv`) · end lower bound
   **02:00:51 CST** (reflog: `e689b241 … update by push`) · end upper bound **11:12:00 CST** (this session's first command, holding Tim's "deployed" —
   a relay, not a Vercel reading). **At least 1 h 05 min 53 s, at most 10 h 17 min 02 s.** Downtime / maintenance / interval writes on live in the
   window: **none** (read 11:13:45 CST as `postgres`, base tables, `mes7a1-window-readings.sql`, `READ_OWN_EXIT=0`: created / updated / voided 0 on all
   three tables; no change-log row for them or for `downtime_causes`). A write the database *refused* leaves no row, so "attempted and refused" is not
   measurable — only "none landed". Everything else in the window was MES-7a-1's own throwaways, INSERT = DELETE; 0 rows after the push.
2. **a · fixture list** — all 15 items covered (table with file:line in the close-out §2 a). Weaker spots recorded, not missing: **W3** "the list shows
   equipment only" is a page filter (`app/operation/equipment/page.tsx:38`) — the fixture pins the column it filters on; **W4** the route check runs the
   handlers against a fake client, the database half is fixtures 264 / 195. Re-run today: `scripts/check-pdf-routes.mjs` `PDFROUTES_OWN_EXIT=0`
   (8 cases, 9 fault cells bite); `db/live-fixtures/265-…` `LIVEFX_OWN_EXIT=0`.
   **b · usability on the deployed app** — clones of admin · cco · cto · warehouse · finance, six pages each, **30 fetches, all 200, no application
   error** (`mes7a1-closeout-pages.mjs`, `PAGES_PROBE_EXIT=0`). Holders of `module.processing.edit` (admin, cco, cto) get the downtime, maintenance and
   interval forms pressable; warehouse and finance see them drawn but unpressable, six controls each naming `module.processing.edit` with the
   explanation (the DBLOCK-1 rule — visible, unpressable, with the reason); the reliability view renders for all five; the dictionaries page shows the
   three downtime causes for all five; `/finance/assets` still reads the records, capitalisation pressable for admin and finance, disabled naming
   `module.finance.edit` for cco and cto; warehouse is refused finance (its codes). **Nothing missing or not working.**
   **c** · V12 registered as not built (`docs/mes-pending-values.md:178`); the five closed known-issues entries struck through with closing notes; the
   two COD findings and the run-event pairing registered (`docs/known-issues.md:10816 · 10823 · 10829`).
   **d** · the 19 self-taken decisions of `docs/handbacks/MES-7a-1.md` §6, titles in the close-out §2 d.
3. So **step 2 went ahead** (brief 1.4).

## §1 · Opening live readings (before anything changed)

Read 2026-10-16 11:24:23 CST with `docs/surveys/MES-7a-2/opening-readings.sql` (read-only, ends in ROLLBACK, `READ_OWN_EXIT=0`) as `postgres`
(`rolbypassrls = true`, base tables and the catalog); the two reconciliations in the same transaction as tim@ (`634c00f9…`, cfo) switched to
`authenticated`, because both functions filter by the reader's codes.

| What | Reading |
|---|---|
| Accounts 6000–6999 | 6000 Rent · 6100 Salaries & Wages (system) · 6110 CPF – Employer (system) · 6120 Staff Welfare & Medical (system) · 6200 Utilities (system) · 6300 Transport & Logistics (system) · 6400 Professional Fees · 6500 Bank Charges · 6600 FX Gain/Loss (inactive) · 6700 Depreciation Expense (system) · 6900 Miscellaneous |
| **6800** | **absent** on live; no account named like repair / maintenance / 维修; absent in the repo (`grep` over `db/ app/ lib/ messages/` and the two docs) — so the brief's stop condition did not fire |
| System accounts | 36: 1000 · 1010 · 1100 · 1200 · 1220 · 1300 · 1400 · 1500 · 1510 · 2000 · 2100 · 2150 · 2200 · 2300 · 2400 · 2500 · 3100 · 4000 · 5000 · 5100 · 5110 · 5120 · 5130 · 5140 · 5150 · 5190 · 5200 · 6100 · 6110 · 6120 · 6200 · 6300 · 6700 · 7100 · 7110 · 7200 (45 accounts in all) |
| Spare parts | materials by kind: battery_material 1 · packaging 1 · not stated 3 · **spare_part 0** (safety stock set on 0); spare-part batches **0**; the `spare_part` note still read "【不按批次追溯】" |
| Maintenance | 2, both FA-2026-0001: 2026-08-22 repair (capitalised = true, no capitalised expense) · 2026-08-23 service (not capitalised) |
| Movement types | the CHECK names 12 (receipt · processing_consume · processing_produce · reversal_restore · reversal_void · sale · writeoff · adjustment · status_change_out / in · transfer_out / in); live counts adjustment 5 · processing_consume 13 · processing_produce 17 · receipt 27 · reversal_restore 3 · reversal_void 4 · sale 11 · status_change in/out 7/7 · transfer in/out 1/1 · writeoff 11 (107 movements, newest 2026-09-08); `maintenance_part_issues` absent |
| Reconciliation (tim@) | **AP** list 422,188.32 / ledger 381,604.42 / unexplained **0.00** · **AR** 57,545.87 / 43,002.12 / **0.00** · **inventory control** 1200: ledger 61,387.92 / subledger 172,403.48 / unexplained **0.00**, reconciled · 1220: 134.86 / 388.20 / **0.00**, reconciled |
| Standing state | approvals ON (finance / cfo / 1,000) · 7 accounts, 0 disabled — admin@ admin · chooer@ finance · fusheng@ warehouse · phua@ cto · sandra@ cco · tim@ cfo · vince@ gm · role codes admin 79 · auditor 20 · cco 46 · cfo 33 · cto 37 · finance 42 · gm 21 · hr 8 · operations 15 · procurement 16 · sales 17 · warehouse 29 · `action.issue_coa` admin, cco · `action.ncr_decide` admin, cco, cto · `module.inventory.edit` admin, cco, cto, finance, operations, sales, warehouse · `module.materials.view` admin, auditor, cco, cfo, cto, finance, gm, operations, procurement, sales · `require_calibrated_since` NULL · throwaways 0 · pending CLM-2026-0004 only · change_log 40,750 rows (max seq 44,550) · 298 tables · COD-2026-0001 / -0002 issued, recorded sha256 `ba299a4f…f42101` / `717661f6…13a4f9`, bucket objects 34,701 / 34,746 bytes |

**Assertions of the brief measured false or imprecise:** (1) "only to a maintenance record that is **not voided**" — `equipment_maintenance` has no
void at all (no column, no function, DELETE refused by name), so the condition has no subject today; recorded and pinned (decision 4,
`MES7A2-MAINTENANCE-HAS-NO-VOID`). (2) Step 0 Q12 says `module.inventory.edit` is held by "warehouse, admin, cco" — live today it is admin · cco · cto ·
finance · operations · sales · warehouse (opening reading); the code is unchanged, the list was wider than written. (3) Step 0 said a reprice's
consumed share goes to 5000 and an issue would land there — true before this cut, now routed (Q13). Zero other assertions found false (SHA, clean tree,
7 accounts enabled, approvals, holders of `action.ncr_decide` / `action.issue_coa`, `require_calibrated_since`, two issued CODs).

## §2 · What was built

* **6800 Repairs & Maintenance** (Q11): a system expense account (`is_system`; the code and English name are Tim's; the Chinese name 维修保养费 is mine).
  Named by code in `issue_spare_parts`, `return_spare_parts` and `reprice_inbound_batch`. `docs/fixed-asset-procedures.md` now names it.
* **Two movement types** (Q12): `maintenance_issue` (negative, inbound side, `available`) and `maintenance_return` (positive), written only by the two
  functions (`trg_inventory_movements_maintenance_ctx` refuses any other writer by name, `MAINTENANCE_MOVEMENT_THROUGH_FUNCTION_ONLY`). The type,
  sign and side CHECKs name both.
* **`maintenance_part_issues`** (Q12 · Q20): one row per issue line or per return (a return cites its issue and carries a reason); append-only
  (`PART_ISSUE_IMMUTABLE` for everyone), written only through the functions (`PART_ISSUES_THROUGH_FUNCTION_ONLY`); carries no money (the value is on
  the journal entry it points at); read `module.processing.view` or `module.inventory.view`; change-logged; no masked column.
* **`issue_spare_parts(maintenance, date, lines)`** · **`return_spare_parts(issue, qty, date, reason)`** (Q10 · Q12–Q15), `module.inventory.edit`, no
  approval. Issue: only `spare_part` batches (`PART_NOT_SPARE_PART`), only to a record not capitalised (`PART_ISSUE_CAPITALISED`), quantity ≤ available
  summed per batch (`PART_ISSUE_EXCEEDS_AVAILABLE`), refused when unpriced (`SPARE_PART_UNPRICED|<batch>`; a provisional price is a price), refused
  under a quality hold (`guard_quality_hold` now lists `maintenance_issue`); date required, not in the future. Posts **Dr 6800 / Cr 1200** at the
  landed unit cost. Return: reason required, ≤ what is still out, not before the issue, not into a written-off batch, allowed under a hold; posts the
  reverse. A part-issue entry is `source_type = 'maintenance_part'` and is not reversible from the journal page (a correction is a return).
* **Capitalising a record with parts is refused** (Q14) by a trigger on `equipment_maintenance` (`MAINTENANCE_HAS_PARTS`); "parts into a capitalised
  overhaul" registered.
* **Reprice** (Q13): `reprice_split` takes the batch's net quantity issued to maintenance (`inbound_batch_maintenance_net_qty`) and returns a
  `maintenance_share_usd`; `reprice_inbound_batch` posts it to 6800, not 5000; `preview_reprice_inbound_batch` returns it and the assay impact preview
  shows it when it is not zero. One implementation, two callers; the old four-argument `reprice_split` was dropped.
* **Inventory control reconciliation**: part-issue lines on 1200 are attributed to their batch; the M3 / M4 mechanism items count only processing
  consumption (a part issue already relieved its landed cost).
* **Reports** (Q23): `stock_rollforward_monthly(_all)` gain **`issued_to_maintenance`** (net of returns), so closing still equals opening plus the
  month; `batch_balance_tree_all` gains the fate line **`maintenance`**, and `unexplained` subtracts it; the movement-mix chart, the enum-mirror check and
  the translations learn both types. Consumables and non-batch inventory stay out.
* **V21** (Q17): `pending_values` arm — each spare-part material with `safety_stock_qty` empty and at least one receipt (`module.materials.view`),
  row in `docs/mes-pending-values.md`.
* **`material_kinds`** (Q2): the `spare_part` note rewritten in the mirror ("received as lots so stock and cost are counted; issued against a
  maintenance record; no per-piece traceability"). RUNTIME CONFIG — live's row is untouched (decision 6).
* **Machine page** (`/operation/equipment/[id]`): a "Spare parts issued to maintenance" panel — the issues with returns, the still-out value at
  today's landed cost for holders of `data.view_prices` and `module.inventory.view`, an "Issue spare parts" form and a "Return" form per issue,
  gated `module.inventory.edit` (visible, unpressable with the code for others); capitalised records and unpriced / held / empty batches are visible
  in the pickers but not selectable, with the reason. `spare_part_stock` (owner rights, `module.inventory.view`) gives the form available quantity,
  "priced" as a boolean and the hold — the same predicates the function uses, no price.
* **Trail**: no new subject; part issues live under `equipment` and show under `inbound_batch` with their entries; wording arm ㉛ (four sentences,
  drift and part faults).
* **Fixtures**: new **266** (REG · PERM · REFUSE · VOID · ISSUE · RETURN · DIRECT · CAPITAL · REPRICE · HOLD · ROLL · V21 · RECON · TRAIL);
  changed without weakening **263** (HOLD refuses `maintenance_issue`, allows `maintenance_return`) and **257** (the roll-forward identity includes the
  new column).

## §3 · Verification, in the brief's order

| # | Step | Result |
|---|---|---|
| 1 | Offline gate | `GATEOFF_EXIT=0`, 100 s (12:06:49 → 12:08:29 CST); fixture 266 ✓ on the rebuild |
| 2 | Backup | **`BACKUP_EXIT=0`**, `evoltrya-backup-2026-10-16-1208.dump`, 8.1 MB, 9,074 TOC entries (previous 9,036), 12:08 → 12:24 CST |
| 3 | Dry run on live | pre-flight green (14 functions: 6 replaced, 8 new; 2 warnings: 6800 not yet in `accounts` — the migration adds it); the migration, its in-transaction proof and the grants replay ran and were rolled back: `DRY|6800=Repairs & Maintenance:true|types=14|issues=0|v21 arm=1|tables=299`; `DRY_OWN_EXIT=0` |
| 4 | apply_migration | **window start 2026-10-16 12:30:24 CST** (committed; `db/migration-windows.tsv`), `APPLY_OWN_EXIT=0` |
| 5 | Types | `npm run types:gen` `TYPES_OWN_EXIT=0`; differs from my pre-window splice only by the relationship entries PostgREST infers through the new view; generated file committed |
| 6 | tsc | `TSC_OWN_EXIT=0` |
| 7 | build | `BUILD_OWN_EXIT=0`; re-run after the layout fixes (five app files changed after this row and after the full gate): `BUILD_OWN_EXIT=0` again, and the gate's app-reading checks re-run directly — error swallowing, currency literals, i18n, masked reads, select columns, component library, phone columns, all exit 0. The re-run first caught a lint warning in my record copy of the local runner, fixed |
| 8 | Full gate | **`GATE_EXIT=0`** — all verdicts; colgrant live and rebuild **481 relations · 13 batches · 39 column-listed tables, no gap**; accounts seed live 37 = mirrored 37; types match live; fixture 266 ✓; `check-pdf-routes` ✓; anon surface a subset of the 328-line baseline (the gate notes the baseline still lists `processing_run_losses`, which predates this cut) |
| 9 | i18n | `I18N_OWN_EXIT=0` |
| 10 | Error swallowing | `SWALLOW_OWN_EXIT=0` (0 unallowed) |
| 11 | Layout | **live data**, `scripts/survey-phone.mjs` on the 8 changed routes (`/operation/equipment/[id]`, `/operation/balance`, `/inventory/reports`, `/settings/pending-values`, `/inbound/[id]/edit`, `/output/[id]/edit`, `/inbound/[id]/assays/[assayId]`, `/operation/equipment`): **390 px 8 / 8 usable, 1280 px 8 / 8 usable, 0 overflow, 0 clipped** (`S390_EXIT=0` · `S1280_EXIT=0`, self-test bit). **Local rebuild with my own data** (`docs/surveys/MES-7a-2/local-seed.sql`: priced, unpriced and held spare-part batches, an issue, a return, a second issue, a reprice after the issue, an NCR): 8 pages × 390 / 1280 × clones of admin · cco · warehouse · cfo = **64 measurements, all 200, 0 overflow, 0 clipped** (`docs/surveys/MES-7a-2/local-layout7a2.mjs`, self-test bit in all 8 runs). The first local run found two defects, both fixed before the numbers above: the machine page **500'd for every price viewer** (it called `inbound_batch_landed_unit_cost`, which staff cannot execute — now reads `inbound_batch_valuation`), and **+114 px at 390 px** for readers without `module.processing.edit` when no stop is open (an existing MES-7a-1 header and inline gate that did not wrap — now `flex-wrap`; FA-2026-0001 on live has an open stop, which is why MES-7a-1's survey never drew it) |
| 12 | Smoke | **`SMOKE_EXIT=0`: 287 ok, 18 skipped (no data), 0 failed** (12:49 → 13:14 CST). Scratch report: the same 6 stale rows from earlier cuts (1,053–1,696 h old, five still referenced), none mine |
| 13 | Live verification | §4 |
| 14 | Fresh-clone build | the cut's commit `afd9977b8f35cecd1501f259c850ed001d272849`, cloned to a scratch directory with no `.env.local`: `npm ci` **`CI_OWN_EXIT=0`**, `npm run build` **`X_OWN_EXIT=0`** (13:21:28 → 13:22:41 CST). This row is recorded by a docs-only follow-up commit, which got its own fresh-clone build before the push (final report) |

Fault injections: `db/scripts/2026-10-16-mes7a2-fixture-injections.py`, 34 cells on 266 + 1 on 263, repeated on a fresh rebuild after the last database
edit (2026-10-16 12:44:51 CST): **`INJECTIONS_OWN_EXIT=0` (35 cells, 0 wrong)**. The first run had one cell that did not bite (RECON) — the injection
removed the reconciliation's attribution of part-issue lines, but `unexplained` compares the 1200 **account total** with the subledger, so attribution
only decides how a difference is *classified*; the cell now injects a defect only the reconciliation can see (a second, unattributed 1200 relief),
and it bites. Wording arm ㉛: `wording-drift-mes7a2` and `wording-part-mes7a2` each bite only ㉛.

## §4 · Live verification

Rolled back — `db/scripts/2026-10-16-mes7a2-live-proof.mjs`, **`MES7A2_PROOF_EXIT=0`** (2026-10-16 13:15 CST, 11.3 s in one transaction). One psql
transaction from BEGIN to ROLLBACK; every action as a throwaway account (prefix `mes7a2probe`): `inv` (inventory · processing · inbound · quality codes,
sees prices) and clones of the seven roles the seven real accounts hold (`cloneOf`, read-only; the cfo clone reads both reconciliations). My rows were
prefixed `ZZ-PROBE-MES7A2`. Pricing went through the engine (`reprice_inbound_batch`, decision 13). No bucket was touched.

| Step | Result |
|---|---|
| Before anything | AP 422,188.32 / 381,604.42 / **0.00** · AR 57,545.87 / 43,002.12 / **0.00** · 1200 61,387.92 / 172,403.48 / **0.00** · 1220 134.86 / 388.20 / **0.00** |
| Receipts | IN-2026-0520 (10 pcs, priced 5.00 — `pricing_status` provisional) and IN-2026-0521 (5 pcs, unpriced); a repair and a capitalised overhaul on my machine → AP / AR / inventory control 0.00 |
| **Issue 4** | IN-2026-0520 → JE-2026-0082 **1200 Cr 20.00 · 6800 Dr 20.00** (4 × landed 5.00), source `maintenance_part`; remaining 6 → reconciliations 0.00 (1200 ledger and subledger both fell by 20.00) |
| **Return 1** with a reason | JE-2026-0083 **1200 Dr 5.00 · 6800 Cr 5.00**; the row cites the issue; reason "ZZ probe: one blade was not needed" → 0.00 |
| Refused | unpriced batch `SPARE_PART_UNPRICED|IN-2026-0521` · capitalised record `PART_ISSUE_CAPITALISED|ZZ-PROBE-MES7A2-M|2026-10-14` · capitalising the record with parts `MAINTENANCE_HAS_PARTS|ZZ-PROBE-MES7A2-M|2026-10-14|1` · a return without a reason `PART_RETURN_REASON_REQUIRED` |
| **Reprice 5 → 6** | JE-2026-0084 **1200 Dr 7.00 · 6800 Dr 3.00 · 2000 Cr 10.00**, nothing to 5000 (7 in stock, 3 net issued to maintenance) → 0.00 |
| **Hold** | an NCR on IN-2026-0520 (NCR-2026-0001 inside the transaction) → issue refused `QUALITY_HOLD_OPEN|IN-2026-0520|NCR-2026-0001`; a return allowed (remaining 8) → 0.00 |
| Roll-forward | pcs: issued to maintenance −2 (4 out, 2 back) · closing 13 = the stock in pcs |
| After ROLLBACK | probe materials 0 · part issues 0 · maintenance movements 0 · `maintenance_part` entries 0; throwaway accounts and roles removed by the plan (0 / 0 read back) |

### Role table (clones of the 7 roles the 7 real accounts hold, codes read at the run; read-only — the issue was tried in a sub-transaction and undone)

| Role (account) | Codes | Parts section (rows of my record seen) | Issue / return parts | Roll-forward (`/operation/balance`, rows) | 6800 in the chart (trial balance) | Pending values: V21 row for my part |
|---|---|---|---|---|---|---|
| admin (admin@) | 79 | 2 | **yes** | 4 | seen | 1 |
| cfo (tim@) | 33 | 2 | no — `PERMISSION_DENIED|module.inventory.edit` | 4 | seen | 1 |
| finance (chooer@) | 42 | 2 | **yes** | 4 | seen | 1 |
| warehouse (fusheng@) | 29 | 2 | **yes** | 4 | seen | 0 (no `module.materials.view`) |
| cto (phua@) | 37 | 2 | **yes** | 4 | seen | 1 |
| cco (sandra@) | 46 | 2 | **yes** | 4 | seen | 1 |
| gm (vince@) | 21 | 2 | no — `PERMISSION_DENIED|module.inventory.edit` | 4 | seen | 1 |

Every role reads the parts section (each holds `module.processing.view` or `module.inventory.view`) and the spare-part stock view; account rows are
readable by every signed-in user (`USING (true)`), so 6800 shows wherever the trial balance is open to that role (its page gate is unchanged). The
still-out **value** on the machine page needs `data.view_prices` and `module.inventory.view` together (local layout run: admin, cco and cfo saw values;
warehouse saw "Amounts are shown only to people who can see prices.").

## §5 · Pages new or changed (route → file)

| Route | File(s) |
|---|---|
| `/operation/equipment/[id]` | `app/operation/equipment/[id]/page.tsx` (part issues, spare-part stock, landed cost through `inbound_batch_valuation`) · `SparePartsPanel.tsx` (new) · `actions.ts` (`issueSpareParts`, `returnSpareParts`) · `DowntimePanel.tsx` · `MaintenancePanel.tsx` · `ServiceIntervalPanel.tsx` (header rows wrap) · `app/operation/equipment/equipmentErrorCodes.ts` (22 codes) |
| `/operation/balance` | `app/operation/balance/page.tsx` (roll-forward column "Issued to maintenance (net of returns)") |
| `/inbound/[id]/edit` · `/output/[id]/edit` (balance panel) | `app/components/batch/BatchBalancePanel.tsx` (fate line `maintenance`) |
| `/inventory/reports` | `app/inventory/reports/MovementMixChart.tsx` (14 types) |
| `/settings/pending-values` | no file change — V21 comes from `pending_values` and the two message keys |
| `/inbound/[id]/assays/[assayId]` | `app/inbound/[id]/assays/actions.ts` · `AssayImpactPreview.tsx` (maintenance share line when not zero) |
| `/finance/journal/[id]` · bank reconcile workspace | no file change — the new source type's label and "use the source path" sentence are message keys |
| Trail (every page that shows an audit trail) | `lib/trail/render.ts` · `lib/trail/text.ts` · `lib/trail/catalogue.generated.ts` · `scripts/gen-trail-catalogue.mjs` · `docs/surveys/AUDIT-TRAIL-0/labels.csv` |

No new route. Messages: `messages/en.ts` · `messages/zh.ts`.

## §6 · Decisions I took without asking

1. **The Chinese name of 6800 is 维修保养费** — Tim named the code and the English name only.
2. **An issue's amount is the difference of two valuations** (`round(before × landed, 2) − round(after × landed, 2)`), not `round(qty × landed, 2)`, so 1200 tracks the subledger to the cent.
3. **A return is valued at today's landed cost**, not the issue's — a reprice has already moved the issued share's difference to 6800, so this keeps 1200 equal to stock.
4. **No void was built for maintenance records**; the "not voided" condition is recorded as having no subject and pinned by fixture 266 VOID (a void column turns it red).
5. **Capitalising is refused only while parts are still out** (issued − returned > 0); a fully returned record can be capitalised.
6. **`material_kinds` on live is not updated** — RUNTIME CONFIG and outside "what the migration creates"; registered with how to change it on `/settings/dictionaries`.
7. **The table carries no money**; the machine page computes still-out value from today's landed cost, shown only to readers with `data.view_prices` **and** `module.inventory.view` (the valuation reader needs both).
8. **`spare_part_stock`** — a new owner-rights read view restating the function's own predicates (available, priced as a boolean, hold) so the form never offers what the function refuses; no price in it.
9. **Returns land in "unspecified location"** (available bucket); put-away is a transfer. Registered.
10. **`maintenance_part` journals are `source_path`** in `journal_entry_reversal_route` — corrected by a return, not reversed from the journal page.
11. **`inventory_control_reconciliation` M3 / M4** add the net maintenance quantity back to remaining, so a part issue is not counted again as stranded capitalisation or freight residue.
12. **One line per issue in the form** (the function accepts several lines; the screen sends one).
13. **The live proof prices through the engine** (`reprice_inbound_batch`, as owner with the throwaway's JWT) — with approvals on, a priced receipt is a CFO request; the door is unchanged and not what this cut tests.
14. **The comment explaining the new movement types sits outside the CHECK's `IN (...)` list** — inside it, two parsers silently undercounted; registered.
15. **Layout fixes in MES-7a-1 files** (three panel headers and the downtime gate wrap) — the overflow was on the page this cut changes, in a state live can reach.
16. **The role table uses the trial balance for "the chart of accounts"** — there is no chart-of-accounts page; account rows are readable by every signed-in user (`USING (true)`).
17. **Fixture 257's added term is vacuous on its own data** (no maintenance movement) and has no injection cell; 266 ROLL carries the bite.
18. **A new throwaway prefix `mes7a2probe`** in `scripts/ephemeral.mjs` for the live proof.

## §7 · Closing live readings

Read 2026-10-16 13:16 CST with the same file (`READ_OWN_EXIT=0`) and the same COD byte reader (`docs/surveys/MES-7a-1/cod-bytes-sha.mjs`, GET only,
`CODSHA_OWN_EXIT=0`): **identical to §1 except what the migration created** — `ACCT6800|PRESENT` (system accounts 36 → 37, accounts 45 → 46),
`PARTS_TABLE|present`, 298 → 299 tables. Unchanged: spare-part materials 0 and batches 0; the two maintenance rows (same row md5); movement counts and
107 movements; journal entries 83 / lines 186 (same md5 of every entry); batches 24 and materials 9 (same md5); the live `spare_part` note (still the
old text — decision 6); approvals ON finance / cfo / 1,000; 7 accounts, 0 disabled, each with its one role; role code counts; holders of
`action.issue_coa`, `action.ncr_decide`, `module.inventory.edit`, `module.materials.view`; `require_calibrated_since` NULL; throwaways 0 / probe roles 0;
pending CLM-2026-0004 only; **AP 422,188.32 / 381,604.42 / 0.00 · AR 57,545.87 / 43,002.12 / 0.00 · 1200 0.00 unexplained, reconciled · 1220 0.00,
reconciled**. Both issued CODs' stored bytes: 34,701 bytes sha256 `ba299a4f…f42101` and 34,746 bytes `717661f6…13a4f9` — equal to the recorded hashes.
Change log 40,750 → 41,910 rows (+1,160): the migration's one `accounts` INSERT (6800), and the survey, smoke and proof throwaways — role_permissions
536 / 536, roles 11 / 11, user_roles 11 / 11, employees 7 / 7, performance_reviews 3 / 3 (+3 updates: smoke's seeded review), contracts and their
term rows 2 / 2 · 1 / 1 …, one `cod_verification_failures` row in and out (smoke's 404 probe) — every INSERT matched by a DELETE. Nothing of mine
remains.

## §8 · Broken window

Start **2026-10-16 12:30:24 CST** (`db/migration-windows.tsv`). End: when Tim confirms the deployment on Vercel. **What breaks in the window**
(derived, Step 0 Q21): nothing in use — the old app never writes the new types, never reads the new table or view, reads every roll-forward column it
had (one more exists), and ignores the new reprice key. The machine page's parts panel and the new columns appear only with the deploy.
