# MES-7a-1 close-out (2026-10-16) — step 1 of the "MES-7a-1 close-out + MES-7a-2 build" brief

Read-only. No database change and no code change: the only writes are docs and the two files beside this one. The page probe below used
throwaway clones of real roles (`mintThrowaway { cloneOf }`, prefix `mes7a1probe`, already registered in `scripts/ephemeral.mjs`) — accounts,
roles and grants created and removed by the shared ephemeral plan; read back afterwards: **0 throwaway accounts, 0 probe roles**, every
change-log INSERT matched by a DELETE (roles 5 / 5 · user_roles 5 / 5 · role_permissions 233 / 233). No record that existed before was touched.

**Opening check.** First command **2026-10-16 11:12:00 CST**. Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
`e689b241a22de77a90ee4e2c6560827355246139`.

## 1 · Broken window closed

Recorded in `docs/forward-queue.md` item 51, in the MES-6b-2 format:
- start **2026-10-16 00:54:58 CST** (measured: `db/migration-windows.tsv`, `2026-10-15-mes7a1-equipment-reliability.sql`);
- end, lower bound **2026-10-16 02:00:51 CST** (measured: `git reflog show --date=iso refs/remotes/origin/main` →
  `e689b241 refs/remotes/origin/main@{2026-10-16 02:00:51 +0800}: update by push`);
- end, upper bound **2026-10-16 11:12:00 CST** (derived: this session's first command, holding Tim's "deployed" — a relay, not a measurement of
  Vercel).
- **Window: at least 1 h 05 min 53 s, at most 10 h 17 min 02 s.** (The upper bound is wide because it is the next session's start, not a reading.)
- **Downtime, maintenance and interval writes on live inside the window** (read 11:13:45 CST as `postgres`, `rolbypassrls = true`, base tables;
  `mes7a1-window-readings.sql`, `READ_OWN_EXIT=0`): **none**. `equipment_downtime` created 0 · updated 0 · voided 0 (1 row in all, Test-1) ·
  `equipment_maintenance` created 0 · updated 0 (2 rows) · `equipment_service_intervals` created 0 · updated 0 (1 row); the change log holds **no row**
  for `equipment_downtime`, `equipment_maintenance`, `equipment_service_intervals` or `downtime_causes` after 00:54:58. ★ What this reading cannot
  see: a write the database **refused** (the old finance card's direct insert on a dropped policy, the window's derived breakage) leaves no row
  anywhere, so "attempted and refused" is not measurable here — only "no write landed".
- Everything else the change log shows in the window is MES-7a-1's own smoke / survey / proof throwaways, every INSERT matched by a DELETE: roles
  31 / 31 · user_roles 31 / 31 · role_permissions 869 / 869 · employees 7 / 7 · performance_reviews 3 / 3 (+3 updates) · contracts 2 / 2 with their
  term rows · one `cod_verification_failures` row in and out (smoke's 404 probe). First row 01:11:02, last 01:53:55 CST; **0 rows after the push
  (02:00:51)** up to this session. CoAs 0 · CoA byte records 0 · CODs issued in the window 0 · COD byte records 2 · stock movements in the window 0 ·
  causes 3 (`breakdown:failure, planned_maintenance:planned, external:external`).
- **The deployed app is the MES-7a-1 code** (measured, item b): every clone's `/operation/equipment/reliability` answers 200 with the reliability
  table, and the machine page draws `data-section="reliability"` — both exist only from `e689b241`.

## 2 · Read-only verification

### a · The fixture list in the MES-7a-1 block, item by item

The block's list ("Fixtures must cover every item restated in section 1, including: …"). Fixture 265 =
`db/fixtures/265-a-stop-states-its-cause-equipment-is-recorded-through-functions-and-reliability-counts-the-union.sql`; live fixture 265 =
`db/live-fixtures/265-the-certificate-codes-are-held-by-the-ruled-roles.sql`; route check = `scripts/check-pdf-routes.mjs` (run by `db/gate.py`
`:778-792`, both phases; the live fixture by `:794-808`, full gate only). Re-run today: route check `PDFROUTES_OWN_EXIT=0` ("8 个样例 全绿 · 9 个故障格各自咬人");
live fixture `LIVEFX_OWN_EXIT=0` ("LIVE FIXTURE 265 全部通过: ISSUE_COA · NCR_DECIDE · VIEWS · SUBJECT").

| # | Item | Covered by |
|---|---|---|
| 1 | cause dictionary and its classes | 265 CAUSE `:146-165` — seed is exactly one per class (`:148-151`); code `other` refused (`:152-153`); class `other` refused (`:154-155`); a viewer cannot write (`:156-157`); an editor adds (`:158-161`); class locked once cited (`:279-280`), rename still allowed (`:281-282`) |
| 2 | cause required on new downtime; the old row untouched | 265 REQUIRE `:167-212` — owner insert without cause refused `DOWNTIME_CAUSE_REQUIRED` (`:169-174`); a pre-cut row with NULL cause reads unclassified + manual (`:187-195`); closing it leaves the cause NULL (`:196-201`); correcting it requires a cause (`:202-205`) |
| 3 | each of the five functions and its named refusals | OPEN `:214-242` (no code · not found · not a machine · no start · no / unknown / inactive cause · no reason · future · already open; overlap `:275-277`); CLOSE `:244-274` (not found · no end · end before start · future · already closed · voided); CORRECT `:284-316` (not found · voided · needs end · end before start · no cause · no reason · nothing changed · changes cause · cannot close an open row); MAINT `:322-352`; INTERVAL `:354-381` |
| 4 | the dropped direct-write paths refused | 265 DIRECT `:383-418` — insert / update on all three tables `EQUIPMENT_THROUGH_FUNCTION_ONLY|<table>|<op>` (`:385-402`), maintenance delete (`:397-398`), downtime delete still `DOWNTIME_NEVER_DELETED` (`:389-390`), direct void refused (`:391-392`), no INSERT / UPDATE / ALL policy left (`:414-418`) |
| 5 | maintenance citing another machine's or a voided downtime refused | 265 MAINT `:342-345` (`MAINTENANCE_DOWNTIME_OTHER_MACHINE|…|FX265-M`, `MAINTENANCE_DOWNTIME_VOIDED|…`); same-machine open downtime accepted and linked `:346-352` |
| 6 | MTBF / MTTR over overlapping runs, voided rows, open downtime, zero failures, zero hours | 265 REL `:420-473` — R1 [08,12) ∪ R2 [10,14) ∪ R3 [20,22) = 8 h, reversed and timeless runs not counted (`:424-442`); failures 3 incl. 1 open, voided / planned / external / unclassified not counted (`:444-453`); MTBF 2.67, MTTR 2.00 over the 2 closed (`:447-450`); zero failures → `no_failure`, no number (`:463-468`); zero hours → `no_hours` (`:469-473`) |
| 7 | runs-without-machine-or-times count | 265 REL `:454-456` (`runs_without_times` 1, `runs_without_machine` = independent count before + 1) |
| 8 | the equipment list showing equipment only | 265 LIST `:481-488` (`equipment_usage` carries the category) + REL `:474-479` (reliability lists the three machines, not the van); the page filter `app/operation/equipment/page.tsx:38` `.eq('equipment_category', 'equipment')` (a page filter, not a fixture — read as code) |
| 9 | F9's shared lookup and the refusal minting nothing | fixture 264 ISSUER `:447-462` (`coa_issuer()` = the issuer `issue_coa` froze; preferred → legal name; not an employee / no position / no code refused); the 400-before-minting is route behaviour: route check COA-ISSUER `scripts/check-pdf-routes.mjs:133` (400, `issue_coa` never called) with fault cell `coa-issuer-unchecked` `:272-274` |
| 10 | F10's rendering paths and the font check | fixture 195 E2b `:305-313` (`issue_cod` returns exactly the stored snapshot); route check COD-SNAP `:181` (render from the returned snapshot, letterhead from it), COD-STORED `:201` (bare GET of issued / void streams stored bytes), COD-PENDING `:230` (pending = watermarked preview from live data), COD-FONT `:243` (unprintable live data → 400 before `issue_cod`; unprintable snapshot → refused inside render, nothing uploaded); fault cells `cod-render-live` · `cod-letterhead-live` · `cod-bare-get-rerender` · `cod-no-font-precheck` `:278-285` |
| 11 | F11's route checks for both certificates (snapshot, 409) and the cco grant fixture | route check COA-SNAP `:115` · COA-409 `:145` · COD-SNAP `:181` · COD-STORED (409 branch) `:201`; fault cells `coa-render-live` `:270` · `coa-no-409` `:275` · `cod-no-409` `:284`; cco grant: live fixture 265 ISSUE_COA `:19-24` (+ NCR_DECIDE, VIEWS, SUBJECT), wired into the full gate `db/gate.py:794-808` |
| 12 | Save PDF for a CoA without bytes | route check COA-SAVE `:160` (issued, no bytes → renders the stored snapshot, uploads, records; with bytes → refused, nothing uploaded) and fault cell `coa-save-live` `:276-277` |
| 13 | V12 registered | `docs/mes-pending-values.md:178` (not built, trigger "casing-removal machine commissioned"); a doc row, no fixture by design |
| 14 | wording arm ㉚ | `scripts/check-trail-wording.mjs:6818-6948` — drift fault `wording-drift-mes7a1` `:6824` (+ the bite check `:6947`), part fault `partFault('mes7a1', …)` `:6933` / `partFaultBit` `:6948`; ≥ 2 part sentences enforced `:6945` |
| 15 | change-log exclusions at 8 | 265 TRAIL `:502-505` (`change_log_coverage_gaps()` gaps 0, excluded 8); cause dictionary and downtime insert change-logged `:495-501` |

**Nothing on the list is uncovered.** Weaker spots, **recorded, not missing, not fixed**:
- **W3** — item 8's "list shows equipment only" is a page filter (`page.tsx:38`); the fixture proves the column it filters on and that reliability
  filters the same way, but nothing repeatable reads the rendered list. Today's page probe (item b) read it on the deployed app: 2 rows, both machines.
- **W4** — the route check (items 9–12) runs both route handlers against a fake client, not against a database; the database half of each path is
  the SQL fixture (264 / 195). The two halves together are the proof; neither alone is. That is the design MES-7a-1 recorded (decision 8).

### b · Usability on the deployed app, as clones of admin, cco, cto, warehouse and finance

`mes7a1-closeout-pages.mjs` (GET only, `PAGES_PROBE_EXIT=0`, `X_OWN_EXIT=0`, 2026-10-16 11:2x CST; clones = exactly each role's live codes:
admin 79 · cco 46 · cto 37 · warehouse 29 · finance 42). Machine = FA-2026-0001 (the one with live downtime, maintenance and an interval).
**30 fetches, all HTTP 200, no application error.**

| Clone | `/operation/equipment` | `/operation/equipment/[id]` (FA-2026-0001) | `/operation/equipment/reliability` | `/settings/dictionaries` | `/finance/assets` | `/finance/assets/[id]` |
|---|---|---|---|---|---|---|
| admin | 200 · "Equipment" · 2 rows (both machines) | 200 · downtime (open Test-1, "Not classified", **Close this period** pressable — no gate) · maintenance (**Record work** pressable) · intervals (**Add an interval** pressable) · reliability section ("none recorded") | 200 · 2 machines × 4 cells, "none recorded" | 200 · "Downtime causes" with Breakdown · Planned maintenance · External | 200 · "Fixed Assets" · 2 rows | 200 · records read-only, "recorded on the machine's equipment page" pointer · **Capitalise** pressable (no gate) |
| cco | 200 · 2 rows | 200 · same as admin — forms **pressable** (0 gates) | 200 · same | 200 · same | 200 · 2 rows · 3 controls disabled naming `module.finance.edit` | 200 · read-only records + pointer · Capitalise **disabled, names `module.finance.edit`** (1 gate) |
| cto | 200 · 2 rows | 200 · forms **pressable** (0 gates) | 200 · same | 200 · same | 200 · 3 disabled naming `module.finance.edit` | 200 · Capitalise **disabled, names `module.finance.edit`** |
| warehouse | 200 · 2 rows | 200 · records shown; **6 controls disabled, each naming `module.processing.edit`**, with the sentence "Recording maintenance, downtime and service intervals needs edit rights in the processing module …" | 200 · same | 200 · "Downtime causes" with the three causes (fewer other tabs — each tab is gated by its own read code) | 200 · **refused page** (`data-access-denied`, no `module.finance.view`) | 200 · refused page |
| finance | 200 · 2 rows | 200 · same as warehouse — 6 controls disabled naming `module.processing.edit` + the sentence | 200 · same | 200 · same | 200 · 2 rows, no gate | 200 · read-only records + pointer · **Capitalise pressable** (no gate) |

So: holders of `module.processing.edit` (admin, cco, cto) get the downtime, maintenance and interval forms pressable; non-holders (warehouse,
finance) get **no pressable form** — the entry points are drawn disabled and each names the code (the house rule since DBLOCK-1: visible,
unpressable, carrying its reason — not hidden). The reliability view renders for all five; the dictionaries page shows the downtime causes for all
five; `/finance/assets` still reads the records for finance-view holders and offers capitalisation pressable only to holders of
`module.finance.edit` (admin, finance), disabled with the code for cco and cto. **Nothing missing or not working.**

### c · Registrations

- **V12** registered as not built: `docs/mes-pending-values.md:178` (trigger "casing-removal machine commissioned"; MES-4a, never built nor recorded).
- **Closed known-issues entries** (each struck through with a closing note): EQP-2d "设备三张表没有 RPC" `docs/known-issues.md:4336-4338` · EQP-2d
  "没有一处看得见哪些机器没人在盯" `:4380-4382` · `AT1B-EQUIPMENT-LIST-EVERY-ASSET` `:10054-10056` · `MES6B1-COD-PDF-RENDERS-LIVE` `:10736-10738` ·
  `MES6B2-ISSUED-WITHOUT-BYTES` `:10791-10793`.
- **The two COD findings** (Q26, registered, not fixed): `MES7A1-COD-VERIFY-COMMENT-CONTACT` `:10816` · `MES7A1-RECORD-COD-ISSUE-PARITY` `:10823`.
- **The run-event pairing** (Q19): `MES7A1-RUN-EVENT-DOWNTIME-PAIRING` `:10829`. Stale records corrected: `:10835-`.

### d · Self-taken decisions in `docs/handbacks/MES-7a-1.md` §6 (titles)

1 The service-interval DELETE policy stays · 2 No refusal on a disposed machine · 3 A cause's code and class are locked once cited ·
4 `DOWNTIME_NOTHING_CHANGED` · 5 Source is reserved and fixed by a trigger · 6 `downtime_causes` under a dictionary trail block ·
7 W2 pinned by a live fixture in `db/live-fixtures/` · 8 F11 is a fake-client route check with self-injection cells · 9 The constraint-name
localizer removed · 10 Capitalisation stays only on the finance card · 11 On the machine page, expense picker and costs finance-gated, employee
picker HR-gated · 12 Default range = acquisition → now; `runs_without_machine` plant-wide · 13 Fixtures 251 and 263 fixed for time of day ·
14 The migration's change_log proof is txid-scoped · 15 Types hand-spliced before the window, regenerated after · 16 The live proof inserts its
committed runs as the owner · 17 The proof's role table covers 8 roles · 18 `material_kinds.sql:81-83` left for MES-7a-2 · 19 MES-0 README line
citations corrected.

## 3 · Verdict

a and b show nothing missing or not working; W3 / W4 are weaker spots, recorded, none fixed (step 1.4). **Step 2 (MES-7a-2) goes ahead.**
