v1.4.52 — Equipment reliability: downtime and maintenance are now recorded on each machine's equipment page, every new stoppage needs a cause classed as failure, planned or external, and each machine shows its mean time between failures and mean time to repair from its recorded runs; certificates of analysis show who they will be issued as before you press issue, and certificates of destruction now print exactly what was fixed when they were issued.

# MES-7a-1 — equipment reliability, issuer check (F9), COD from snapshot (F10), PDF route checks (F11), Save PDF (Q24) (MES group, sixteenth cut; 2026-10-16)

Tim's brief of 2026-10-15: build MES-7a-1 as ruled in `docs/surveys/MES-7a/STEP0-HANDBACK.md` (Q3–Q9 · Q18–Q22 · Q24–Q26; Q2 and Q11 recorded
for MES-7a-2). Migration `db/migrations/2026-10-15-mes7a1-equipment-reliability.sql` (2,425 lines, built from the mirrors by
`db/scripts/build_mes7a1_migration.py`). Opening SHA: HEAD = origin/main = `git ls-remote origin main` =
`ae52ac38682dd0e22c5bb4e743255249566e5101` (tree clean).

---

## §1 · Opening live readings (before anything changed)

Read 2026-10-15 23:31:02 CST as `postgres` (`rolbypassrls = true`, base tables) with `docs/surveys/MES-7a-1/opening-readings.sql`
(read-only, ends in ROLLBACK, `READ_OWN_EXIT=0`); stored bytes read through the Storage API with `docs/surveys/MES-7a-1/cod-bytes-sha.mjs`
(GET only, `CODSHA_OWN_EXIT=0`); reconciliation in tim@'s session with `db/scripts/2026-10-05-at1d3-live-recon.sql`.

| What | Reading |
|---|---|
| Assets | FA-2026-0001 Bosch Deep Discharging Machine (equipment, active, acquired 2026-08-21) · FA-2026-0002 Mobile Discharging Solution (equipment, active, 2026-08-25) — 2 equipment, 0 other |
| Downtime | 1 — FA-2026-0001 from 2026-08-23 18:55, open, not voided, reason "Test-1", row md5 `16d2687e…` |
| Maintenance | 2 on FA-2026-0001 — 2026-08-22 repair (capitalised, no capitalised expense) · 2026-08-23 service; neither linked to a downtime or an expense |
| Service intervals | 1 — FA-2026-0001 service every 90 days, lead 2, warn |
| Runs | 14 in all, 10 committed and live; 0 with a machine, 0 with start + end; operation ↔ machine links 0 |
| CODs | COD-2026-0001 issued 2026-09-08 02:21, recorded and stored sha256 `ba299a4f3488fc543cdd1f410fabf6523434d39caa0dc58d6f376309c1f42101` (34,701 bytes) · COD-2026-0002 issued 2026-09-08 10:37, `717661f6a8166b5f9342324586208e21f29c217aa5d3c047b009e00f2513a4f9` (34,746 bytes); `cod-documents` holds exactly those two objects |
| CoAs | 0 certificates · 0 byte records · 0 void requests · `coa-documents` 0 objects |
| Standing state | approvals ON (finance / cfo / 1,000) · 7 accounts, 0 disabled · role code counts admin 79 · auditor 20 · cco 46 · cfo 33 · cto 37 · finance 42 · gm 21 · hr 8 · operations 15 · procurement 16 · sales 17 · warehouse 29 · catalogue 79 (admin 79) · `action.issue_coa` admin, cco · `action.issue_cod` admin, warehouse · `action.ncr_decide` admin, cco, cto · `module.processing.edit` admin, cco, cto, operations · `require_calibrated_since` NULL · throwaways 0 · pending CLM-2026-0004 only · change_log 38,358 rows (max seq 42,069) · 59 document types · 297 tables · 17 buckets |
| Reconciliation (tim@) | AP 422,188.32 / 381,604.42 / **0.00** · AR 57,545.87 / 43,002.12 / **0.00** |

Zero assertions of the brief measured false (SHA, clean tree, 7 accounts enabled, approvals, `require_calibrated_since`, two issued CODs).

## §2 · What was built

* **Downtime causes (Q3).** `downtime_causes` (code, class failure · planned · external — no "other", English and Chinese names, active, order,
  notes), seeded breakdown / failure · planned_maintenance / planned · external / external; read `module.processing.view` or `module.finance.view`,
  written `module.processing.edit` in `/settings/dictionaries`. `equipment_downtime.cause_code` required on every new row (checked at insert;
  the live Test-1 row stays NULL and reads "Not classified"); an inactive cause is refused; `reason` stays free text.
* **Source (Q4).** `equipment_downtime.source` manual · device; every row is manual; device is refused today and a source never changes.
* **Recording through functions (Q6).** `open_equipment_downtime` · `close_equipment_downtime` · `correct_equipment_downtime` ·
  `record_equipment_maintenance` · `save_equipment_service_interval`, each with named refusals; `void_equipment_downtime` unchanged; the direct
  INSERT / UPDATE policies on the three tables are dropped and a statement-level guard refuses direct writes by name
  (`EQUIPMENT_THROUGH_FUNCTION_ONLY|table|op`); DELETE stays refused (the service-interval DELETE policy stays). Maintenance may cite only a
  same-machine, non-voided downtime (`MAINTENANCE_DOWNTIME_OTHER_MACHINE` · `MAINTENANCE_DOWNTIME_VOIDED`). The forms moved to
  `/operation/equipment/[id]`; `/finance/assets/[id]` keeps reading the records (read-only panels pointing at the machine page) and keeps
  capitalisation.
* **Reliability (Q5 · Q19).** `equipment_reliability(machine, from, to)`: operating hours = union of `[started_at, ended_at)` of committed,
  not-reversed runs on the machine inside the range; failure = non-voided failure-class downtime starting in the range; MTTR over the closed ones;
  MTBF = hours ÷ failures; zero failures → "No failure in N h of operation", zero hours → "No operating hours recorded"; the range is chosen on the
  page (`/operation/equipment/reliability`, and a section on each machine page) and defaults to the machine's whole record (acquisition → now);
  the page states the denominator and how many runs in the range have no machine or no times. No availability or OEE. Downtime only — run events
  are not counted.
* **List (Q7).** `/operation/equipment` lists equipment only, with a Monitored column (`equipment_service_status.monitored`).
* **F9.** One `coa_issuer()` (employee, name, position) used by `issue_coa` and by the route; the route checks the name and position against the
  font stack before issuing — 400, nothing minted; the form says "You will be named as <name>, <position>." and shows the refusal before pressing.
* **F10 (Q9 · Q25).** The COD route renders from the snapshot `issue_cod` returns (letterhead from the snapshot); a bare GET of an issued or void
  COD streams the stored bytes (sha256 re-checked, 409 on mismatch); a pending COD keeps the watermarked internal preview from live data; a font
  check runs before `issue_cod` and inside `render()`; the misleading comment is corrected; the QR host stays the request origin.
* **F11.** `scripts/check-pdf-routes.mjs` runs both route handlers unchanged against a fake client: COA-SNAP · COA-ISSUER · COA-409 · COA-SAVE ·
  COD-SNAP · COD-STORED · COD-PENDING · COD-FONT, with 9 self-injection cells that each bite; `db/gate.py` runs it (both phases) and
  `db/live-fixtures/265-…` (full gate only), which pins cco's grant of `action.issue_coa`.
* **Q24.** "Save PDF" on an issued CoA with no stored bytes (holders of `action.issue_coa`; others see it disabled with the code): renders the stored
  snapshot, uploads, records through `record_coa_issue`.
* **Q18 · Q26 · Q19** registered (`docs/mes-pending-values.md` V12; `docs/known-issues.md` MES-7a-1 section). Trail: no new subject; cause and
  source under `equipment`; `dictionary_downtime_causes`; wording arm ㉚. One new change-logged table, exclusions 8, no masked column.
* **Fixtures.** New 265 (CAUSE · REQUIRE · OPEN · CLOSE · CORRECT · MAINT · INTERVAL · DIRECT · REL · LIST · TRAIL); changed without weakening
  108 · 109 · 120 · 180 · 248 (causes on direct inserts, then through the functions), 195 (E2b: `issue_cod` returns the stored snapshot), 264
  (ISSUER), 251 · 263 (time-of-day flakes found running after midnight SGT — see §6).

## §3 · Verification, in the brief's order

| # | Step | Result |
|---|---|---|
| 1 | Offline gate | `GATEOFF_EXIT=0`, 99 s (after fixing the 251 / 263 midnight flakes) |
| 2 | Backup | **`BACKUP_EXIT=0`**, `evoltrya-backup-2026-10-16-0032.dump`, 8.0 MB, 9,036 TOC entries (previous 8,961), 00:32:27 → 00:49 CST |
| 3 | Dry run on live | pre-flight green (17 functions: 4 replaced, 13 new; 2 columns, 0 on a masked table); the migration, its in-transaction proof and the grants replay ran and were rolled back: `DRY\|causes=breakdown:failure,planned_maintenance:planned,external:external\|downtime_unclassified=1\|policies=0`; `DRY_OWN_EXIT=0` |
| 4 | apply_migration | **window start 2026-10-16 00:54:58 CST** (committed; `db/migration-windows.tsv`), `APPLY_OWN_EXIT=0` |
| 5 | Types | `npm run types:gen` exit 0; differs from my pre-window splice only by two internal functions PostgREST lists (`downtime_cause_check`, `equipment_record_target`) and one line wrap — generated file committed |
| 6 | tsc | `TSC_OWN_EXIT=0` |
| 7 | build | `BUILD_OWN_EXIT=0` |
| 8 | Full gate | **`GATE_EXIT=0`**, 617 s — all verdicts green; colgrant live and rebuild **479 relations · 12 batches · 39 column-listed tables, no gap**; types match live; fixture 265 ✓; `check-pdf-routes` 8 cases green · 9 fault cells bite; live fixture 265 ✓; anon surface a subset of the 328-line baseline |
| 9 | i18n | `I18N_OWN_EXIT=0` |
| 10 | Error swallowing | `SWALLOW_OWN_EXIT=0` (0 unallowed) |
| 11 | Layout | live, 6 changed pages with data (`/operation/equipment`, `/operation/equipment/[id]`, `/operation/equipment/reliability`, `/finance/assets/[id]`, `/settings/dictionaries`, `/output/[id]/edit`) × 390 / 1280 px: **0 overflow · 0 clipped** (`S390_EXIT=0` · `S1280_EXIT=0`, self-test bit). Local rebuild with my own data (states live has none of: classified, closed and corrected stops, a repair citing one, two overlapping runs, a run with no machine, an interval, reliability with values, a byte-less issued CoA): 9 pages × 390 / 1280 × clones of admin · cco · cfo · warehouse = **72 measurements, all 200, 0 overflow, 0 clipped** (same MEASURE string as the survey, self-test bit each run). The machine page says "MTBF: 8 h between failures" (6 h + 2 h of runs, one failure); the CoA page shows Save PDF (disabled with the code for cfo and warehouse); warehouse is refused by the route with the permission sentence; cco's save stored the bytes and the button disappeared. PDFs looked at: a saved CoA (1 page, "Issued by Clone cco, Chief Commercial Officer") and the proof's COD-2026-0003 (1 page, snapshot supplier, letterhead with contact lines, licence, QR, seal) |
| 12 | Smoke | **`SMOKE_EXIT=0`: 287 ok, 18 skipped (no data), 0 failed.** Scratch report: the same 6 stale rows from earlier cuts (1,042–1,684 h old, four still referenced), none of mine |
| 13 | Live verification | §4 |
| 14 | Fresh-clone build | from the pushed commit, no `.env.local` — see the final report |

Fault injections: `db/scripts/2026-10-15-mes7a1-fixture-injections.py`, 37 cells on 265 + 3 on 264 / 195, repeated on a fresh rebuild after the last
database edit (2026-10-16 01:57 CST): **`INJECTIONS_OWN_EXIT=0` (40 cells, 0 wrong)**. Wording arm ㉚: `wording-drift-mes7a1` and
`wording-part-mes7a1` each bite only ㉚.

## §4 · Live verification (rolled back; `db/scripts/2026-10-16-mes7a1-live-proof.mjs`, `MES7A1_PROOF_EXIT=0`)

One transaction held open by a psql coprocess, every action as a throwaway account (prefix `mes7a1probe`), my own rows prefixed
`ZZ-PROBE-MES7A1`; the two PDF routes ran unchanged inside it (jiti; `@/lib/supabase/server` replaced by a client bound to the transaction,
storage the real Storage API with the throwaway's token). First run `MES7A1_PROOF_EXIT=1`: every step passed, then my own "nothing pre-existing
changed" fingerprint hashed the whole certificate tables and so counted the COD and CoA the proof had just made. The plan cleaned up
(buckets back to the 2 original objects with the same sha, 0 throwaways, 0 probe rows — read afterwards). I fixed the fingerprint (per-table
names, certificates only from before the proof) and the second run passed (2026-10-16 01:51–01:53 CST, 55.6 s in the transaction):

| Step | Result |
|---|---|
| Record | on my machine: failure downtime opened with cause breakdown (source manual) → closed (2 h) → corrected with a new reason → repair recorded citing it |
| Refused | maintenance citing another machine's downtime `MAINTENANCE_DOWNTIME_OTHER_MACHINE\|…` · a voided one `MAINTENANCE_DOWNTIME_VOIDED\|…` · direct insert `EQUIPMENT_THROUGH_FUNCTION_ONLY\|equipment_downtime\|insert` · direct update `…\|update` · no cause `DOWNTIME_CAUSE_REQUIRED` · a processing viewer `PERMISSION_DENIED\|module.processing.edit` |
| Reliability | runs [01:00,05:00) [03:00,07:00) [12:00,14:00) on the machine + one with no machine → **8 h** (overlap once, 3 runs) · failures 1 (the voided one not counted) · **MTBF 8 h · MTTR 2 h** · runs without a machine 2 = an independent count (both mine: that run and the COD's run) · a reader without the processing view refused |
| CoA issuer | issuer named «Lim ≤ (probe)»: the route returned **400** before issuing; certificates still 0, next number still COA-2026-0001 |
| Save PDF | COA-2026-0001 issued by «Tan (probe)» through `issue_coa` with no bytes → route `POST {storeFor}` rendered the snapshot, uploaded, recorded; stored sha = recorded; `?coa=` streams it; a second save refused |
| COD | pending → internal preview from live data · issued COD-2026-0003 through the route → rendered from the returned snapshot (supplier, letterhead «EVoltrya Recovery Pte. Ltd.»), stored, sha recorded · supplier renamed live → a bare GET streams the stored bytes (same sha), not a re-render |
| Untouched | every pre-existing downtime, maintenance, interval, asset, cause, link, certificate, byte record, batch, assay, run, movement, request, approval, supplier, material, employee, position, journal, expense, permission, grant and setting identical; pending «expense_claim:CLM-2026-0004»; approvals on; `require_calibrated_since` NULL; reconciliation AP 422,188.32 / 381,604.42 / 0.00 · AR 57,545.87 / 43,002.12 / 0.00 |
| After ROLLBACK | downtime 1 · maintenance 2 · intervals 1 · causes 3 · CoAs 0 · CoA byte records 0 · CODs issued 2 · COD byte records 2 · probe rows 0 |
| Buckets | 2 objects uploaded by the proof, both removed; `coa-documents` 0 objects · `cod-documents` the same 2 paths with the same sha256 as before |

### Role table (clones of the 8 roles the 7 real accounts hold, codes read at the run; read-only)

| Role | Codes | Processing view (list, machine page, reliability) | Record equipment | Finance view (`/finance/assets`) | Capitalise (finance edit) | Downtime rows seen | Causes seen (dictionary) |
|---|---|---|---|---|---|---|---|
| admin | 79 | yes | yes | yes | yes | 2 | 3 |
| cfo | 33 | yes | no (`module.processing.edit`) | yes | no | 2 | 3 |
| finance | 42 | yes | no (`module.processing.edit`) | yes | yes | 2 | 3 |
| warehouse | 29 | yes | no (`module.processing.edit`) | no | no | 2 | 3 |
| cto | 37 | yes | yes | yes | no | 2 | 3 |
| operations | 15 | yes | yes | no | no | 2 | 3 |
| cco | 46 | yes | yes | yes | no | 2 | 3 |
| gm | 21 | yes | no (`module.processing.edit`) | yes | no | 2 | 3 |

The dictionaries page is entered by every role (each tab gated by its own read code); the cause tab is edited by holders of
`module.processing.edit`. "Record equipment" was tried with a real `open_equipment_downtime` call undone in a sub-transaction.

## §5 · Pages new or changed (route → file)

| Route | File(s) |
|---|---|
| `/operation/equipment` | `app/operation/equipment/page.tsx` (equipment only, Monitored column, link to reliability) |
| `/operation/equipment/[id]` | `app/operation/equipment/[id]/page.tsx` · `actions.ts` (new) · `DowntimePanel.tsx` · `MaintenancePanel.tsx` · `ServiceIntervalPanel.tsx` (moved from `app/finance/assets/[id]/`) · `app/operation/equipment/equipmentErrorCodes.ts` (moved) · `app/operation/equipment/reliability.ts` (new) |
| `/operation/equipment/reliability` (new) | `app/operation/equipment/reliability/page.tsx` · `lib/modules.ts` (nav entry under Equipment) |
| `/finance/assets/[id]` | `app/finance/assets/[id]/page.tsx` (panels read-only from the machine page) · `actions.ts` (capitalise and planned in-service only) |
| `/settings/dictionaries` | `registry.ts` · `actions.ts` · `page.tsx` (Downtime causes, class choice, trail block) |
| `/output/[id]/edit` (CoA section) | `CoaSection.tsx` · `CoaIssueForm.tsx` ("You will be named as …", refusal before pressing) |
| `/output/[id]/coa/pdf` (route) | `app/output/[id]/coa/pdf/route.tsx` (issuer and font check before issue; `POST {storeFor}`) |
| `/quality/coa/[id]` | `page.tsx` · `SavePdfButton.tsx` (new) |
| `/inbound/[id]/cod/pdf` (route) | `app/inbound/[id]/cod/pdf/route.tsx` · `app/inbound/codPdf.ts` (new) |
| Trail | `app/components/trail/AuditTrail.tsx` · `lib/trail/render.ts` · catalogue regenerated |

## §6 · Decisions I took without asking

1. **The service-interval DELETE policy stays.** Removing an interval is not a record of the machine; the action checks a row was deleted.
2. **No refusal on a disposed machine.** The brief named none; a disposed machine's last stoppage can still be closed or corrected.
3. **A cause's code and class are locked once a downtime cites it** (`DOWNTIME_CAUSE_CLASS_LOCKED`) — otherwise reclassifying a cause would rewrite past MTBF.
4. **`DOWNTIME_NOTHING_CHANGED`**: a correction that changes nothing is refused, so the change log never records an empty correction.
5. **Source is reserved and fixed by a trigger** (device refused on insert, never changed), not by the functions alone.
6. **`downtime_causes` sits under a dictionary trail block** (`dictionary_downtime_causes`), not a record subject (Q20: no new subject).
7. **W2 (cco holds `action.issue_coa`) is pinned by a live fixture** in a new `db/live-fixtures/` directory the full gate runs (read-only), because it is a live grant a rebuild cannot see.
8. **F11 is a fake-client route check with self-injection cells**, run by the gate, rather than a live-only proof.
9. **The constraint-name localizer was removed**: every refusal is now `CODE|args` from the functions; unique violations are caught and re-raised as named codes.
10. **Capitalisation stays only on the finance card**; the machine page links to it.
11. **On the machine page the expense picker and costs are finance-gated** (`module.finance.view`) and the employee picker HR-gated, so a processing-only reader sees neither.
12. **Default range = acquisition (SGT midnight) → now; `runs_without_machine` is plant-wide** for the range (it says the denominator may be incomplete; it is the same on every row).
13. **Fixtures 251 and 263 fixed for time of day** (found running after midnight SGT): 263 takes the process date from the run's start, 251 uses `LEAST(…, now())` for the verdict time. Neither assertion changed.
14. **The migration's change_log proof is txid-scoped** (counts this transaction's rows only), so colleagues testing on live cannot make it fail.
15. **Types were hand-spliced before the window** and regenerated after (§3 step 5).
16. **The live proof inserts its committed runs (and the COD's inbound / run legs) as the owner** — the run-commit path is not what it tests; everything it asserts about equipment goes through the five functions as throwaways.
17. **The proof's role table covers 8 roles** (the 7 accounts hold admin + cfo and cto + operations together).
18. **`material_kinds.sql:81-83` ("不按批次追溯", Step 0 §14 item 3) is left for MES-7a-2**, the cut Q2 rules on.
19. **MES-0 README line citations corrected** (Step 0 §14 items 1–2); the other §14 items are fixed in the mirrors (4, 5), by F10 (6) or registered (7, 8).

## §7 · Closing live readings

Read 2026-10-16 01:54:30 CST with the same file (`READ_OWN_EXIT=0`) and the same bucket reader (`CODSHA_OWN_EXIT=0`): identical to §1 except
what the migration created — `CAUSES|present` (the 3 seeded causes), 298 tables, the Test-1 row's md5 (it now carries `cause_code` NULL and
`source` manual; with those two columns removed its md5 is `16d2687ec0b2ac6e94196d001c4c1f11`, unchanged) — and change_log 40,264 rows (max seq
44,064): +1,906, of which 1 is the migration's `document_type_exceptions` INSERT and the rest throwaway roles / grants / accounts / employees /
reviews / contracts from the survey, smoke and proof, every INSERT matched by a DELETE. Both COD objects byte-identical (sha above).
7 accounts enabled, roles unchanged; `require_calibrated_since` NULL; approvals ON finance / cfo / 1,000; reconciliation 0.00 on both sides
(the proof, tim@-equivalent cfo clone). Nothing of mine remains: 0 throwaway accounts, 0 probe roles, 0 `ZZ-PROBE-MES7A1` rows, 0 CoAs.

## §8 · Broken window

Start **2026-10-16 00:54:58 CST** (`db/migration-windows.tsv`). End: when Tim confirms the deployment on Vercel. **What is broken in the window
(derived, Step 0 Q21):** the deployed (old) app records downtime, maintenance and intervals from `/finance/assets/[id]` with direct writes —
those policies are gone and new downtime needs a cause, so those three forms refuse until the deploy. Reading is unaffected; the old COD route
still renders from live data (no new COD was issued on live).
