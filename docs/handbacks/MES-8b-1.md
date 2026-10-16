v1.4.57 — Margin, exposure and the compliance pack: each incoming batch now shows what it has earned so far through everything made and sold from it, with the unsold part at cost; the price exposure page shows the value of payable metals still in stock at the latest prices; and once a month is closed, a compliance pack (CPK-…) can be frozen with that month's balance, stock movement, licence position, incidents, environmental results and inspections, downloaded as a PDF fixed at the moment it was frozen.

# MES-8b-1 hand-back — inbound margin, inventory exposure, the monthly compliance pack (2026-10-17)

MES group, cut 21 (the brief "MES-8a close-out + MES-8b-1 build", step 2). Answers Q10–Q18 and Q28 of `docs/surveys/MES-8/STEP0-HANDBACK.md`, and the
MES-8b-1 halves of Q21–Q24, exactly as stated there. Fold-in: the two 390 px overflows MES-8a registered.

## 1 · Step 1 — MES-8a close-out, item by item

Pushed before step 2 began, as `debb6a7a192cf1cde6353811b743946fc756a68b` ("MES-8a close-out"); the full evidence is
`docs/surveys/MES-8b-1/MES-8a-CLOSEOUT.md`.

- **Broken window closed** (forward-queue item 55, MES-7b-2 format): start **2026-10-16 22:46:29 CST** (measured, `db/migration-windows.tsv`) · end between
  **23:54:00** (measured: the push of `556ef6f4`, which carried `1ec4bc44`) and **2026-10-17 00:11:44 CST** (this session's first command, holding Tim's
  relay that it was deployed) → **at least 1 h 07 min 31 s, at most 1 h 25 min 15 s**. Nothing of anyone else's landed on live inside it.
- **a · fixture list:** all **23** items covered by fixtures 269 / 270, the wording arm ㉞ and `check-pdf-routes` — re-run on a fresh rebuild of HEAD's
  mirrors: `FX269_OWN_EXIT=0`, `FX270_OWN_EXIT=0`, `INJECTIONS_OWN_EXIT=0 (44 + 28, 0 wrong)`, both wording faults red in ㉞ only, `PDFROUTES_OWN_EXIT=0`.
  **Nothing uncovered.**
- **b · usability on the deployed app** as clones of admin (82 codes) · cco (48) · finance (43) · warehouse (31) · cfo (34): **25 fetches, all HTTP 200**,
  no application error; the review action offered to admin and cco only, the statement issue action to admin and finance only, both drawn disabled with
  their code for everyone else who can enter the page. States live does not hold (a graded supplier, a statement) on a local rebuild: **35 fetches, all
  200**. **Nothing missing, nothing broken** — so step 2 went ahead.
- **c · the two 390 px overflows** re-measured: supplier page +40 px (cco · finance · warehouse · gm) / +30 px (gm), new-PO page +134 / +120 / +246 px —
  equal to MES-8a's numbers. Fixed in this cut (§7).
- **d · MES-8a's 24 decisions** listed by title in the close-out file.

## 2 · Opening live readings (2026-10-17 00:47:36 CST, `postgres`, `rolbypassrls = true`, base tables; `docs/surveys/MES-8b-1/live-readings.sql`, one rolled-back read)

| What | Reading |
|---|---|
| Inbound batches | 15 (5 with downstream outputs, 3 with downstream sales); pricing final 2 · provisional 13 |
| Output batches | 14 — 12 from a run, **2 with a unit cost**, 10 run outputs without one, 0 cost-incomplete, 2 with no run |
| Sales | 9 `sales_records` on 7 batches; **0 sell-side settlements** (SETTLE-1 — none can post) |
| Metal prices | 7 payable metals, 12 rows, **none indexed**; latest 2026-07-30 (Cu 2026-08-10) |
| Content | 7 inbound batches (19 rows) · 4 output batches (6 rows) |
| On hand | inbound 12 batches / 115,388 kg · output 12 batches / 3,816 kg · nothing outside kg |
| Periods | `locked_before` = `system_start_date` = **2026-08-01** → **no month is locked**, so `compliance_pack_not_frozen` lists nothing on live |
| Licence | gwdf `WDL-21-2-5380`, active 2026-07-01 … 2028-09-01, 500 t; NEA categories 0 · storage limits 0 · ceiling checks 0 |
| Safety | incidents 0 · environmental parameters 0 / results 0 · inspection templates 0 / runs 0 / findings 0 |
| Codes | catalogue 82 (module 34 · action 37 · data 11); `module.compliance.view` / `action.compliance_pack` absent; admin · auditor · cco · cfo · cto · gm all active |
| Holders | `data.view_prices` admin · auditor · cco · cfo · cto · finance · gm · procurement · sales; `module.finance.view` admin · auditor · cco · cfo · cto · finance · gm; `module.processing.view` admin · auditor · cco · cfo · cto · finance · gm · operations · warehouse |
| Buckets | 18; `compliance-documents` absent; `cod-documents` 2 objects (the two issued CODs, sizes 34,701 / 34,746, eTags recorded) |
| Approvals | on · L1 finance · L2 cfo · 1,000 SGD; one pending document (`CLM-2026-0004`, not mine) |
| Accounts | 7 real accounts, 0 disabled; throwaway accounts 0, probe roles 0 |
| Change log | 50,979 rows, max seq 55,352 · views 196, writable (view, role) pairs 0 · tables 317 · pending-value arms 31 · reminder arms 71 |
| Reconciliation | AP list 422,188.32 / ledger 381,604.42 / **unexplained 0.00** · AR 57,545.87 / 43,002.12 / **0.00** |
| COD bytes | both issued CODs: stored bytes' digests = the recorded sha256 |


## 3 · What was built

- **Inbound margin** — `inbound_batch_margin(uuid)` (STABLE, owner rights, standing decision 2): an inbound batch's share of every downstream output is
  MES-5b's mass-consumed share from `batch_balance_tree_all` (exact `share_num / share_den`, multiplied down through every stage — Q10); margin =
  Σ share × (revenue of the quantity sold − the output's `unit_cost_base` × quantity sold); revenue and quantity from `sales_records`, read exactly as
  `batch_margin` reads them (Q11 — this function does not read `sales_settlements` at all; none can post, SETTLE-1). The unsold part shows as on-hand at
  cost (the batch's own remainder at its landed cost + each output's remainder × share × unit cost), never as margin. Any leg without a cost — the
  batch itself unpriced, an output with no unit cost, an output whose cost is incomplete, an output not from a run — makes it **not computable**:
  margin, revenue and on-hand at cost are NULL and each reason is named; nothing sold reads `nothing_sold` with a NULL margin. A panel on
  `/inbound/[id]/edit` after the batch balance; "Restricted" with the codes for other readers.
- **Inventory exposure** — `inventory_metal_exposure()` (same gate): per payable metal (`substances.role`), Σ kg on hand of live inbound and output batches
  of a kind that may be processed × content % × the latest `metal_prices` row on or before today (Singapore date), USD per tonne, each line with its
  price date and a count of batches whose content is newer than the price (Q12, flagged, not changed). "No price", "price ambiguous" (two prices on the
  latest date), "not measured" (no payable content — kg listed, not valued), "unit not kg" listed apart; the total adds only priced metals and says
  whether it is complete. No FX conversion, no threshold. A second section on `/finance/price-exposure` (the sell-side section unchanged).
- **The monthly compliance pack** — `compliance_pack_data(month)` builds the eight sections of Q14 (processing balance plant-wide and per operation ·
  stock roll-forward · licence in force at month end, on-hand by NEA category against its ceiling, uncategorised tonnes, the month's ceiling checks by
  outcome · incidents with kind, NEA-reportable, notified / report / deadline / closed dates — **no injury details, no narrative, no names** ·
  environmental results with their limits and judgements · inspections done and findings still open at month end · "NEA return — format not yet set
  (V26)" · "EU recycling efficiency — method not yet set (V27)" with the month's masses). `freeze_compliance_pack` freezes only a locked month
  (`COMPLIANCE_PACK_MONTH_NOT_LOCKED|YYYY-MM|locked_before`), numbers it `CPK-YYYY-MM`, re-issues `-2`, `-3` … only with a reason (the old pack
  superseded first, its payload untouched); no void. The PDF is rendered only from the frozen payload, in English, archived by sha256 in the private
  bucket `compliance-documents` (read `module.compliance.view` · upload `action.compliance_pack` · delete only an unrecorded object with
  `action.compliance_pack` · no update policy), and a stored version is re-hashed on every download — **409** on mismatch.
- **Codes (Q17)** — `module.compliance.view` → admin · auditor · cco · cfo · cto · gm; `action.compliance_pack` (declares the view) → admin · cto. The
  only grant change on live: **8 rows**. **Pending values** V26 · V27 (one row each from day one, Q18). **Reminder** `compliance_pack_not_frozen` (each
  locked month since `system_start_date` without a live pack; for `action.compliance_pack`). **Month-end** one warning row, never a block.
- Mirrors: 3 tables, 9 functions (+2 replaced: `trail_subjects`, `trail_subject_members`), 2 views replaced (`operations_now`, `pending_values`);
  `compliance_settings` is RUNTIME CONFIG (its bootstrap — one row, all four empty — is still correct: nothing is guessed).

## 4 · Verification, in the brief's order

| # | Step | Result |
|---|---|---|
| 1 | offline gate | `GATE_EXIT=0` ("迁移前相位:✓ 干净") — after moving fixtures 100 / 101 / 111 / 254 (62 → 63 document types; 54 → 55 declared gates; 71 → 72 arms; CPK as `count_month`) and adding the arm's spec rows to `docs/dashboard-arm-inventory.md` |
| 2 | backup (background) | `BACKUP_EXIT=0` from its own log — `evoltrya-backup-2026-10-17-0203.dump`, TOC 9,579 entries (floor 8,517) |
| 3 | COMMIT→ROLLBACK dry run on live | `DRY_OWN_EXIT=0` (54 s, 02:25:34–02:26:28); afterwards live had no `compliance_packs`, 82 codes, no bucket |
| 4 | apply_migration | preflight ✓ (12 `CREATE FUNCTION`: 2 replaced · 10 new); committed atomically with the function grants re-asserted; **window start 2026-10-17 02:30:23 CST** (`db/migration-windows.tsv`) |
| 5 | generate types | `npm run types:gen` from live, `TYPES_OWN_EXIT=0` (replaces the hand splice; +152 lines) |
| 6 | tsc | `TSC_OWN_EXIT=0` |
| 7 | build | `BUILD_OWN_EXIT=0` (the dev server on :3196 stopped first) |
| 8 | full gate | **`GATE_EXIT=0`**, 680 s wall clock: 可重建性 ✓ · 镜像 vs 线上 ✓ (NO DIFFERENCES) · 行为断言 ✓ (every fixture incl. 271 / 272, `check-pdf-routes`, the live 265) · 匿名面 ✓ (anon executes the same two functions). `colgrant` live **516 relations in 13 batches** and rebuild, no gap · `viewwrite` live and rebuild **196 views, none writable** (self-proof bit) · `types` ✓ · `currency` ✓ · `swallow` ✓ |
| 9 | i18n | `I18N_OWN_EXIT=0` (every key, static and dynamic, in en and zh) |
| 10 | error swallowing | `SWALLOW_OWN_EXIT=0` (0 unallowed, 9 allowlisted) |
| 11 | layout survey | §8 |
| 12 | smoke (background) | first run **`SMOKE_EXIT=1`** — its preflight refused before starting the dev server: `compliance_packs` has no `created_at`; fixed in `ORDER_OVERRIDES` (`frozen_at`). Second run **`SMOKE_EXIT=0`**: 296 checks (295 routes + probes), 270 routes timed (1,128 s total, median 3.4 s); `/compliance/packs` 200; `/compliance/packs/[id]` and its `pdf` skipped as expected (no pack on live). **Scratch cleanup:** throwaway accounts on live afterwards **0**, probe roles **0**, no plan file left. The scratch health check reported **6 stale rows** (`ZZ-SMOKE-PROBE`, `-M25`, `-NTF`, `-S25`, `-CJK`, `-IB25`, 1,067–1,710 h old, five still referenced) — not mine, report-only, left alone |
| 13 | live verification | §5 – §6 |
| 14 | fresh-clone build of the pushed commit | §13 |

Fault injection: `db/scripts/2026-10-17-mes8b1-fixture-injections.py` — **88 cells (271: 34 · 272: 54), each red in its own arm, every arm red at
least once**, the database identical before and after (`injection_probe`); re-run on a **fresh rebuild after the migration** → `INJECTIONS_OWN_EXIT=0`.
The wording arm ㉟ and the three CPK cells of `check-pdf-routes` (`cpk-render-live` → CPK-FROZEN, `cpk-no-409` → CPK-409, `cpk-orphan-left` →
CPK-ARCHIVE) bite without the database. Three places have no cell, said in the script's header: the freeze's own `PERIOD_REQUIRED` (the data function
refuses the same way), V26's "either half empty" (the pair check makes half a pair unwritable), and the Singapore date (a cell that is red eight hours a
day is not a cell).

## 5 · Live verification (`db/scripts/2026-10-17-mes8b1-live-proof.mjs`, one rolled-back transaction, throwaway accounts only — `MES8B1_PROOF_EXIT=0`, 1 min 09 s)

The first run stopped before writing anything (`MES8B1_PROOF_EXIT=1`: `freeze` is a reserved word in a temp-table column); afterwards live had 0 throwaway
accounts, 0 probe roles, 0 objects. Second run, step by step (my own rows, prefix `ZZ-PROBE-MES8B1` / `zzp8b1`; the only pre-existing row touched is
`finance_settings.locked_before`, moved inside the rolled-back transaction and read back as 2026-08-01):

- **Receive** A `IN-2026-0535` 300 kg @ 2 and B `IN-2026-0536` 150 kg @ 1 (approvals on → two submitted price requests, decided by a throwaway holding
  the real `cfo` role) and C `IN-2026-0537` 100 kg unpriced.
- **Two stages**: R1 `PROC-2026-0754` A 200 + B 100 → `OUT-2026-0722` 170 + `DST-2026-00003` 80 (allocated by weight: unit cost 2 · 2); R2
  `PROC-2026-0755` `OUT-2026-0722` 100 → `OUT-2026-0723` 90 (unit cost 2.2222); **sell 50 kg of `OUT-2026-0723` at 9, posted** (revenue, receivable,
  cost of sales).
- **Margin of A** (share 200 / 300 everywhere): sold 33.333 · revenue **300.00** · cost of what was sold **74.07** · **margin 225.93** — an independent sum
  from `processing_outputs` and `sales_records` gives 225.93 · **unsold at cost 459.26** (own 100 kg × landed 2 + 2/3 of O1 70 kg · dust 80 kg · O2
  40 kg at their unit costs; independent 459.26) · revenue source `sales_records`.
- **The unpriced leg**: R3 `PROC-2026-0756` C 100 → `OUT-2026-0724` 85 (cost incomplete), 10 kg sold → C reads **not computable** — margin NULL,
  on-hand at cost NULL, reasons `inbound_unpriced:IN-2026-0537` and `output_cost_incomplete:OUT-2026-0724`.
- **Exposure** (as of 2026-10-17): content A Ni 10 % · Co 5 % · `zzp8b1` 1 %, my prices Ni 16,000 and Co 31,000 dated **2026-10-09** → Ni **priced,
  dated 2026-10-09**, A contributes 10 kg · Co priced, dated 2026-10-09, 5 kg · `zzp8b1` **no price**, 1 kg, not valued · B (no content, 50 kg left)
  **not measured** · total priced 315.00 USD · complete false.
- **The pack**: my injury (with every injury field filled), its NEA notification, an environmental result (4.5 against a limit of 10) and an inspection
  (pass 1 · fail 1 · n/a 1, one finding) in **September**. Freezing September while open → `COMPLIANCE_PACK_MONTH_NOT_LOCKED|2026-09|2026-08-01`;
  month-end reads "can be frozen once the month is locked". Lock to 2026-10-01 (rolled back) → the reminder lists **2026-08, 2026-09** for the
  freezer and nothing for a viewer; month-end shows the warning; October → `COMPLIANCE_PACK_MONTH_NOT_LOCKED|2026-10|2026-10-01`; a viewer freezing →
  `PERMISSION_DENIED|action.compliance_pack`. **`CPK-2026-09`** frozen = the preview of that moment, byte for byte; §3 licence `WDL-21-2-5380`;
  §4 my incident (injury, NEA-reportable, notified 2026-09-10); §5 my result (within, limit 10 max); §6 my inspection and its open finding; §7 / §8
  not set (V26 / V27). **None of** the injured person's name, the injury nature, treatment, days lost, what happened, the action taken, the
  responsible person or the inspector's name appears anywhere in the payload. After the freeze the reminder lists only 2026-08 and month-end names
  `CPK-2026-09`.
- **Re-issue**: without a reason → `COMPLIANCE_PACK_SUPERSEDE_REASON_REQUIRED|CPK-2026-09`; a near miss recorded after the freeze leaves `CPK-2026-09`
  unchanged; with a reason → **`CPK-2026-09-2`**, the first superseded by it with the reason kept and its payload identical (1 incident vs 2).
- **PDF**: rendered from the frozen row of `CPK-2026-09-2` (28,202 bytes, 2 pages); a viewer's upload refused (HTTP 400); the freezer uploaded
  `compliance-documents/<pack id>/<sha256>.pdf`; recorded with the digest sent upper-case and stored lower-case, version 1; the same bytes again →
  `COMPLIANCE_PACK_BYTES_ALREADY_RECORDED|CPK-2026-09-2|1`; on the superseded pack → `COMPLIANCE_PACK_SUPERSEDED|CPK-2026-09|…`; a path elsewhere →
  `COMPLIANCE_PACK_ISSUE_PATH_INVALID|CPK-2026-09-2`; a viewer recording → `PERMISSION_DENIED|action.compliance_pack`. The viewer downloaded it, the sha
  matches; the paper says `CPK-2026-09-2`, `2026-09`, both incident codes, the inspection code, the licence number, V26 and V27 — no injury detail, no
  inspector's name, no Chinese. An incident recorded after the freeze: the row and the stored bytes identical, a re-render from the row still lists 2
  incidents (the live preview 3). **Bytes altered** with the service role (+12 bytes) → the download's sha no longer matches the record → the route's
  **409** branch (`route.ts`: `sha !== issue.sha256`; `check-pdf-routes` CPK-409 proves that branch answers 409). Bucket policy: the recorded object
  cannot be deleted (0 rows), a viewer deletes nothing, the freezer removes an unrecorded orphan (1).
- **Reconciliation after every finance step** (start · receipts · priced through the CFO · each stage allocated · the sale · the unpriced leg · end):
  **AP list = ledger + explained items, unexplained 0.00; AR the same, 0.00** — AP 422,188.32 / 381,604.42 → 422,938.32 / 382,354.42 after my two priced
  receipts; AR 57,545.87 / 43,002.12 → 58,085.87 / 43,542.12 after my two sales; all rolled back.
- **Untouched**: every pre-existing row identical (fingerprints of 29 tables, my own rows excluded by creation time), the pending documents exactly the one there was (`CLM-2026-0004`, not mine),
  approvals on, `require_calibrated_since` NULL.
- **After ROLLBACK**: packs 0 · pack issues 0 · settings set 0 · `locked_before` 2026-08-01 · `cod_issues` 2 · probe rows 0 · approvals on.
  **Buckets**: `compliance-documents` 0 objects (Storage API and SQL, = before) · `cod-documents` `2:2f47744f…` (= before).

## 6 · Role table — the 7 real roles' codes, read-only (throwaway clones, inside the same rolled-back transaction)

| Role (codes) | Inbound margin section | `/finance/price-exposure` page · inventory section | Pack list · the pack | Live preview | PDF download | Freeze / re-issue | Pending V26 · V27 |
|---|---|---|---|---|---|---|---|
| admin (84) | yes | yes · yes | 2 · 1 | yes | yes | yes | 1 · 1 |
| finance (43) | yes | yes · yes | 0 · 0 | no (`PERMISSION_DENIED\|module.compliance.view`) | no (HTTP 400) | no (`action.compliance_pack`) | 0 · 0 |
| warehouse (31) | **Restricted** (`PERMISSION_DENIED\|data.view_prices`) | no (no `module.finance.view`) · Restricted (`data.view_prices`) | 0 · 0 | no | no (HTTP 400) | no | 0 · 0 |
| cto (41) | yes | yes · yes | 2 · 1 | yes | yes | **yes** | 1 · 1 |
| cco (49) | yes | yes · yes | 2 · 1 | yes | yes | no (`action.compliance_pack`) | 1 · 1 |
| cfo (35) | yes | yes · yes | 2 · 1 | yes | yes | no (`action.compliance_pack`) | 1 · 1 |
| gm (23) | yes | yes · yes | 2 · 1 | yes | yes | no (`action.compliance_pack`) | 1 · 1 |

The two compliance codes appear only on the six ruled roles (code counts after the migration: admin 82 → 84 · auditor 21 → 22 · cco 48 → 49 · cfo 34 → 35 ·
cto 39 → 41 · gm 22 → 23; finance · warehouse · hr · operations · procurement · sales unchanged). On the pages, a refused control is drawn disabled with
its code (`PermissionGate`); a reader outside standing decision 2 sees the margin and exposure sections as "Restricted" naming the codes.

## 7 · The two 390 px overflows (fold-in)

Measured with `scripts/survey-phone.mjs`'s own `MEASURE` (self-test bit +400 px each run), local co8a, same data, before → after:

| Page | Fix (smallest width change) | 390 px before → after | 1280 px |
|---|---|---|---|
| `/suppliers/[id]/edit` | the status panel's two `PermissionGate inline` get `className="flex-wrap"` | +40 → **0** (cco · finance · warehouse, active supplier) · +30 → **0** (gm, approved supplier) | every gate rect identical |
| `/purchasing/orders/new` | `PermissionGate` `wrap` prop (gate `max-w-full`, refusal text wraps) on the form's gate · form `space-y-6 max-w-full` · category select `max-w-full` | cco / finance +134 → **0** · warehouse +120 → **0** · gm / cfo +246 → **0** | form, both selects and the gate identical |

**MES-8a misidentified the second culprit**: it was the category `<select>` and the three-code permission pill, not the supplier select — the fix MES-8a
suggested would not have moved the reading. Both `MES8A-390-*` entries are closed in `docs/known-issues.md` with these numbers.

## 8 · Layout survey (local co8a seeded with margin, exposure and two frozen packs; 7 roles × 1280 / 390; `LOCAL_LAYOUT_EXIT` per run)

14 pages per role: `/compliance/packs` (default, `?month=2026-09`, `?month=2026-10`), both packs (`CPK-2026-09-2` live, `CPK-2026-09` superseded), an inbound
batch with a computed margin and one not computable, `/finance/price-exposure`, `/finance/month-end`, `/settings/pending-values`, both supplier pages,
`/purchasing/orders/new`, `/`. **1280 px: all 7 runs exit 0** (every page 200, no overflow, no clipped table). **390 px: warehouse exits 0; the other six
exit 1 on exactly one page — `/finance/month-end`, +6 px** — the pre-existing detail column ("No payroll period for this month"); removing this cut's
row on the same DOM leaves it at 6 → registered `MES8B1-390-MONTH-END-DETAIL`, not fixed. Every new page and both fixed pages read **0** at 390 px.

**The pack PDF**: rendered from the seeded frozen pack with the route's own `renderPack.ts` and rasterised page by page (A4, 2 pages): every table fits
its columns, long cells wrap inside them. One flaw found and fixed — section 8's heading sat alone at the foot of page 1; headings now keep their first
lines (`minPresenceAhead`), re-rendered and re-checked; `check-pdf-routes` re-run green.


## 9 · Pages (route → file)

| Route | File(s) | What changed |
|---|---|---|
| `/compliance/packs` | `app/compliance/packs/page.tsx` · `PackSections.tsx` · `FreezePanel.tsx` · `SettingsPanel.tsx` · `PacksTable.tsx` · `actions.ts` · `complianceErrorCodes.ts` · `packTypes.ts` | new: month picker (default the previous month), the live preview of the eight sections, freeze / re-issue with a reason, the list of frozen packs (superseded ones say by whom and why), the V26 / V27 panel and its audit trail |
| `/compliance/packs/[id]` | `app/compliance/packs/[id]/page.tsx` · `ArchiveButton.tsx` | new: the frozen payload drawn with the same sections component, the superseded notice, the PDF links (view · archive · each stored version), the pack's audit trail |
| `/compliance/packs/[id]/pdf` | `app/compliance/packs/[id]/pdf/route.ts` · `renderPack.ts` · `CompliancePackDocument.tsx` | new: `GET` renders the frozen payload (English, no live table read); `GET ?version=N` streams the stored bytes and answers **409** when they no longer match their sha256; `POST` archives into `compliance-documents` at `<pack id>/<sha256>.pdf` and removes the object if the record is refused |
| `/inbound/[id]/edit` | `app/inbound/[id]/edit/page.tsx` · `InboundMarginPanel.tsx` · `InboundMarginTable.tsx` | new panel after the batch balance: margin, revenue, cost of what was sold, the unsold part at cost, per-output lines with shares; "not computable" with each reason named; "Restricted" with the codes for readers outside standing decision 2 |
| `/finance/price-exposure` | `app/finance/price-exposure/page.tsx` · `InventoryExposureSection.tsx` · `ExposureTable.tsx` | new second section: payable metals in stock at the latest price on or before today, each with its price date; "no price", "price ambiguous", "not measured", "not in kg"; "Restricted" outside standing decision 2 |
| `/finance/month-end` | `app/finance/month-end/page.tsx` | one new checklist row: the month's compliance pack — "can be frozen once the month is locked" / "not frozen" (a warning, never a block) / "frozen as CPK-…" |
| `/settings/pending-values` | (unchanged page; `pending_values` view) | V26 and V27 rows |
| `/` (Operations now) | `lib/reminders.ts` | new arm `compliance_pack_not_frozen` → `/compliance/packs?month=YYYY-MM` |
| nav | `lib/modules.ts` | scope `/compliance`; `/compliance/packs` under Safety ("Compliance packs"), `FN.compliancePacks` = `module.compliance.view` |
| `/suppliers/[id]/edit` | `app/suppliers/[id]/edit/StatusPanel.tsx` | fold-in: the two status-panel gates wrap (`flex-wrap`) |
| `/purchasing/orders/new` | `app/purchasing/orders/new/NewOrderForm.tsx` · `app/components/ui/permission-gate.tsx` | fold-in: `PermissionGate` `wrap` prop; form `max-w-full`; category select `max-w-full` |

## 10 · Decisions taken without asking

1. **The pack lives under the Safety nav**, with its own `/compliance` scope and its own read code — the Safety module already holds the incidents,
   inspections and environmental results the pack is mostly made of; a new top-level module for one page would be an empty shelf.
2. **No `/margin/inbound` page.** The Step 0 hand-back's deliverables list (§2) names one beside `/margin`; the brief's own restatement of Q13 says
   "inbound margin is a section on the inbound batch page", and its role table asks for "the inbound batch page's margin section". I built the
   section and not the page — one reader of `inbound_batch_margin`, where the batch is. A list page is one query away if Tim wants it.
3. **A price is "ambiguous" when the latest date has more than one price** (two indices on one day): the exposure refuses to pick one, rather than
   choosing by index order. On live today no price is indexed, so this never fires there.
4. **Exposure counts only materials whose kind may ever be processed** (battery material, e-waste) — spare parts, consumables and packaging carry no
   content and would only add a screen of "not measured".
5. **Incidents in the pack carry no free text and no names**: kind, NEA-reportable, notified, report submitted, deadline and closed dates — not what
   happened, the action taken or the responsible person, for anyone (the brief's "injury and pay data absent", read wide). Inspection findings keep
   their corrective action (that *is* the finding).
6. **Open findings at month end are keyed on the inspection date** (a finding of an inspection on or before the month end that had no closure on or
   before the month end) — a finding recorded later against an earlier inspection still belongs to the month it was found in.
7. **The reminder arm is gated on `action.compliance_pack`** — the people who can act on it (the V18 / supplier-review precedent).
8. **The month-end row reads "na" until the month is locked** — before the lock there is nothing anyone can freeze, so it is not outstanding.
9. **`set_compliance_settings` is gated on `action.compliance_pack` and takes each value as a pair** (format + frequency; method + targets); half a pair
   is refused by name, because half a standard printed on a pack reads as a whole one.
10. **The pack's self-reference (`superseded_by`) is `DEFERRABLE INITIALLY DEFERRED`** — the freeze marks the old pack superseded by the new id before
    the new row exists (the partial unique index allows one live pack per month).
11. **The currency-message baseline was refreshed** (`--update-messages-baseline`): five genuine `USD/t` unit labels on the exposure section (metal
    prices are quoted in USD per tonne by market convention — the rule's own named exception).
12. **`PermissionGate` gained an optional `wrap` prop** instead of a one-off class on the PO form; without it the component renders exactly as before,
    so no other call site moved.
13. **Hand-spliced types before the migration**, replaced by `npm run types:gen` from live after it (the gate's `types` line is green).
14. **"Not computable"** when any leg on the tree has no unit cost or an incomplete one, or the root batch has no landed cost; **"nothing sold" reads
    NULL**, not 0 — both carry their reasons, and neither is ever shown as 0.
15. **Sections in the PDF keep their heading with their first lines** (`minPresenceAhead`) — the layout survey found section 8's heading alone at the
    foot of page 1.
16. **The smoke test sorts `compliance_packs` by `frozen_at`** (the table has no `created_at`; its preflight refused before starting anything) and lists
    the pack page and its `pdf` route in `EXPECTED_SKIPS` (live holds no pack and the brief forbids creating one).
17. **The live proof's "no price" metal is my own payable substance** (`zzp8b1`, inside the rolled-back transaction): all seven payable metals on live
    have a price, and the brief forbids touching a pre-existing price.
18. **"A sale with a posted settlement"** in the live proof is a sale posted through `record_output_sale` (revenue, receivable and cost of sales
    journals posted). A sell-side settlement row can never post today (SETTLE-1), and Q11 says revenue comes only from `sales_records`; the fixture
    (271 REVENUE) proves an unposted settlement changes nothing.
19. **The month-end page's 390 px overflow (6 px) is registered, not fixed** — it is pre-existing (removing this cut's row leaves it at 6) and outside
    the fold-in the brief named.

## 11 · Closing live readings — nothing of mine remains (2026-10-17 ≈ 03:17 CST, the same `live-readings.sql` and `docs/surveys/MES-8a/cod-bytes.mjs`)

Diff against the opening readings (§2), line by line — **every difference is something the migration itself creates**:

| Reading | Opening | Closing |
|---|---|---|
| Catalogue | 82 (module 34 · action 37) | **84** (module 35 · action 38) — `module.compliance.view`, `action.compliance_pack` |
| Holders of the two codes | none | `module.compliance.view` admin · auditor · cco · cfo · cto · gm; `action.compliance_pack` admin · cto (**8 rows**) |
| Role code counts | admin 82 · auditor 21 · cco 48 · cfo 34 · cto 39 · gm 22 | admin 84 · auditor 22 · cco 49 · cfo 35 · cto 41 · gm 23 (finance, warehouse, hr, operations, procurement, sales unchanged) |
| `role_permissions` digest excluding the two codes | `7b0b8556…` | `7b0b8556…` (identical) |
| MES-8b-1 tables · document types | none · 62 | `compliance_pack_issues`, `compliance_packs`, `compliance_settings` · **63** (CPK) |
| Buckets | 18 | 19 — **`compliance-documents`, private, 0 objects** |
| Tables · pending arms · reminder arms | 317 · 31 · 71 | **320 · 33 · 72** |
| Change log | 50,979 rows, max seq 55,352 | 52,864 rows, max seq 57,423 — by table since 55,352: `permissions` +2 / 1 update · `role_permissions` 882 in / 874 out (**+8**) · `document_types` +1 (the migration, 02:28); everything else my smoke and proof throwaways and the smoke's own scenery, **every INSERT matched by a DELETE** (`roles` 23 / 23 · `user_roles` 25 / 25 · `employees` 3 / 3 · `contracts` 2 / 2 and their term rows · `performance_reviews` 1 / 1 · one `cod_verification_failures` row in and out) |
| Fingerprints of 28 tables (inbound, outputs, movements, runs, inputs, outputs, sales, settlements, prices, content, materials, suppliers, journals, payments, expenses, POs, incidents, environmental, inspections, findings, ceiling checks, licence, management packs, customer and supplier statements, finance settings) | recorded | **identical** |
| Periods | `locked_before` = `system_start_date` = 2026-08-01 | **2026-08-01** (no month locked or unlocked) |
| Packs · V26 / V27 · `require_calibrated_since` | — | **0 packs · 0 issues · settings row all empty · NULL** |
| Accounts | 7, 0 disabled; throwaways 0, probe roles 0 | **7, 0 disabled; throwaways 0, probe roles 0** |
| Pending documents | `CLM-2026-0004` | `CLM-2026-0004` (it still has an eligible approver other than its submitter — the migration's self-proof listed every pending document's deciders) |
| Reconciliation | AP 422,188.32 / 381,604.42 / 0.00 · AR 57,545.87 / 43,002.12 / 0.00 | **identical** |
| COD bytes | both match their recorded sha256 | **both match, byte-identical** (sizes 34,701 / 34,746, eTags unchanged) |

## 12 · Broken window

Start **2026-10-17 02:30:23 CST** (measured, `db/apply_migration.sh` → `db/migration-windows.tsv`). End: **the moment Tim sees the deployment succeed on
Vercel** — this process does not query the deployment (AGENTS.md); it will be recorded from Tim's reading. What breaks inside it (derived, not measured
on live): nothing in use — the old app reads none of the new tables or functions; `operations_now` gains one arm that lists nothing on live (no month
is locked); the old pending-values page does not know V26 / V27 and draws their keys until the deploy.

## 13 · Commit, fresh-clone build, push

One commit, staged by explicit path. Before the push: `git clone` of the repository into a scratch directory outside it, checkout of **the commit
being pushed**, no `.env.local`, `npm ci`, `npm run build`, judged only by the build's own exit code (`X_OWN_EXIT=$?` written into its log). A file
cannot carry the result of building itself, so that result — and `HEAD` · `origin/main` · `git ls-remote origin main` after the push — is in the
report that closes this cut, not here.
