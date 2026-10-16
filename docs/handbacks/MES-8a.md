v1.4.56 — Supplier scorecards and statements: each supplier now has a scorecard counting short and over deliveries, quality problems, assay disputes, discharge mismatches and lapsed certificates, and a recorded review gives it a grade once weights are set, which shows on purchase orders and warns when a prepayment is above that grade's limit; finance can also issue a supplier statement (SST-…) that must tie to the payables ledger, downloaded as a PDF fixed at the moment of issue.

# MES-8a — supplier scorecards and supplier statements, with the COD record checks (MES group, twentieth cut; 2026-10-16), with F17

Tim's brief of 2026-10-16: build MES-8a as ruled in `docs/surveys/MES-8/STEP0-HANDBACK.md` (Q1–Q27 closed; MES-8 is three cuts — **MES-8a** this
one with F17, **MES-8b-1** inbound margin · inventory exposure · compliance pack (Q10–Q18, Q28), **MES-8b-2** wall display (Q19, Q20, Q29)).
Migration `db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql` (5,200 lines, built from the mirrors by
`db/scripts/build_mes8a_migration.py`).

**Opening check.** Tree clean. `HEAD` = `origin/main` = `git ls-remote origin main` = `d99da62ee025032c59901e620ae1bce81a1f2797`. Files staged by
explicit path only. No git command was refused.

---

## §1 · Opening live readings (before anything changed)

Read **2026-10-16 21:00:46 CST** with `docs/surveys/MES-8a/live-readings.sql` (read-only, `READ_OWN_EXIT=0`) as `postgres`
(`rolbypassrls = true`, base tables and the catalog); the reconciliations as tim@ (cfo) switched to `authenticated`. The COD bytes were hashed
with `docs/surveys/MES-8a/cod-bytes.mjs` (Storage API GET only).

| What | Reading |
|---|---|
| Codes | catalogue **81** (34 module · 36 action · 11 data) · `module.suppliers.view` admin · auditor · cco · cfo · cto · finance · gm · procurement · warehouse · `module.finance.view` admin · auditor · cco · cfo · cto · finance · gm · `module.finance.edit` admin · finance · `action.supplier_approve` admin · cfo |
| Suppliers | 17 (md5 `3d18cc35…`): approved goods 1 · draft goods 6 · draft forwarder 1 · draft service 1 · deleted 8 · certificates 4 (SUP-2026-0003 article_18 valid to 2027-03-02) |
| Purchasing | POs 11 (md5 `1de05245…`), 4 with an on-order term (PO-2026-0008/9/10 cancelled, 0011 confirmed — all SUP-2026-0095, 50 %) · terms 24 · prepayment applications 2 (150,000.00) |
| Receiving / quality | batches 24 (md5 `6f7a7601…`) · NCRs 0 · assay disputes 0 |
| Payables ledger 2000 by supplier | employee 5,341.70 · revaluation (not attributable) 4,589.06 · SUP-2026-0002 84,963.54 · SUP-2026-0003 6,101.12 · SUP-2026-0094 0.00 · SUP-2026-0095 280,000.00 · SUP-2026-0445 109.00 · ZZ1B-GDS 500.00 · total **381,604.42** |
| MES-8a objects | none (no table, no SST document type — 61 types) · customer statements 0 · bucket `supplier-statement-documents` absent |
| Standing state | approvals ON (finance / cfo / 1,000) · 7 accounts, **0 disabled** — admin@ admin · chooer@ finance · fusheng@ warehouse · phua@ cto · sandra@ cco · tim@ cfo · vince@ gm · role codes admin 81 · auditor 21 · cco 47 · cfo 34 · cto 39 · finance 43 · gm 22 · hr 8 · operations 16 · procurement 16 · sales 17 · warehouse 31 (role_permissions md5 `2cf8ce23…`) · `require_calibrated_since` NULL · throwaways 0 · pending: CLM-2026-0004 only |
| CODs | COD-2026-0001 sha256 `ba299a4f…c1f42101`, 34,701 bytes · COD-2026-0002 sha256 `717661f6…2513a4f9`, 34,746 bytes (stored bytes hash to the recorded digests) · `cod_issues` 2 rows (md5 `097dacfa…`) |
| Books | journal 83 entries / 186 lines (md5 `d9827dd9…`) · payments 13 (`d7f9bac8…`) · expenses 10 (`cc8989fb…`) · change_log 45,615 (max seq 49,633) · views 192 (writable pairs 0) · public tables 313 · pending arms 29 · buckets avatars 2 · cod 2 · coa 0 · statement 0 · po 11 · invoice 4 · finance-attachments 4 · … |
| Reconciliation (tim@) | **AP** 422,188.32 / 381,604.42 / **0.00** · **AR** 57,545.87 / 43,002.12 / **0.00** · 1200 61,387.92 / 172,403.48 / **0.00**, reconciled · 1220 134.86 / 388.20 / **0.00**, reconciled |

**Assertions of the brief measured false or imprecise:** zero. (SHA, clean tree, approvals, 7 accounts enabled, `require_calibrated_since` NULL,
the two COD byte strings, no view writable — each read above.)

## §2 · What was built

* **Scorecard — live measures** (`supplier_scorecard_measures`, `module.suppliers.view`): over a window the reviewer gives (required, not inverted,
  not in the future — Singapore date), eleven scored counts: short lines (only on closed / cancelled orders), over lines, NCRs by disposition
  (open · accept · accept with penalty · reject · rework · downgrade), assay disputes (withdrawn ones shown only), discharge-judgement mismatches,
  certificate-lapse days (block / warn types the supplier holds). **A comparison never made is null — "Not compared" — never 0.** Grade breaches
  are shown with `caveat: CONTRACT-1`, never scored.
* **Grading**: score = Σ weight × count (null counts add nothing); grade = the first line whose ceiling the score does not pass, the open last line
  catches the rest. Without V23 weights and lines: **"Not graded — V23 not set"**.
* **Reviews** (`record_supplier_review`, `action.supplier_review` → admin · cco): append-only, copying the measures, the V23 weights and lines and
  the V24 caps in force. A correction is a new review citing the corrected one with a reason; `supplier_latest_reviews` (by `seq`, not superseded)
  is the one purchase orders and receiving read.
* **V23 / V24** (`set_supplier_score_settings`, named refusals for every malformed input) on `/suppliers/scorecards`.
* **PO effects** (`supplier_grade_advice_internal`, one implementation): the grade under the supplier select; `PREPAYMENT_ABOVE_GRADE_CAP` when the
  on-order share (percentages + fixed ÷ estimated total; not computable without a total) exceeds the grade's cap — **a warning, never a refusal**;
  `create_purchase_order` returns the same warnings.
* **Receiving**: the grade's sampling level on the batch page and both receipt forms — advice only, **no assay added**.
* **Reminder** `supplier_review_due` (approved / active goods suppliers never reviewed or due) — **silent until V23's window is set** (Q27).
* **Supplier statements** (`SST-YYYY-NNNN`, gapless per year, width `GREATEST(4, digits)` — no truncation): `supplier_statement_data` (read,
  `module.finance.view` + `data.view_purchase_prices` + `module.inbound.view`) derives the ledger side from GL 2000 lines attributed to the supplier
  (original entry first for reversals) and the document side independently (`ap_aging_asof` − unapplied payments − registered residue);
  `issue_supplier_statement` (`module.finance.edit`) refuses `SUPPLIER_STATEMENT_DOES_NOT_TIE` by name, freezes figures, lines, open items, on-account
  payments, received-not-priced receipts, recipient and letterhead into one row; the same period again needs a reason and supersedes the old one.
  Provisional receipts are marked; unpriced ones carry quantity only; employees never get one.
* **PDF**: rendered only from the frozen row (`renderStatement.ts`, shared by the route and the live proof), English, archived in the private bucket
  `supplier-statement-documents` keyed by sha256, recorded in `supplier_statement_issues` (append-only, version per statement); a stored copy whose
  bytes no longer hash to the record answers **409**.
* **F17**: `record_cod_issue` — path under the certificate's folder, one set of bytes per certificate, digest lower-case.
* **Trail**: subjects `supplier_scorecard_review`, `supplier_score_settings`, `supplier_statement`; wording arm ㉞. Every new table change-logged;
  exclusions stay 8; no masked column.

## §3 · Verification, in the brief's order

| # | Step | Result |
|---|---|---|
| 1 | offline gate | `GATE_OFF_EXIT=0` — and again after the dry-run fix below (`GATE_OFF_EXIT=0`) |
| 2 | backup | `BACKUP_EXIT=0` — `evoltrya-backup-2026-10-16-2216.dump`, 8.5 MB, 9,464 TOC entries (22:16:04 → 22:34:51) |
| 3 | dry run on live (COMMIT → ROLLBACK) | first run **`DRY_OWN_EXIT=3`**: the migration's own F16 assertion read 3 (view, role) pairs writable — the three new view mirrors revoked only from `anon`, so `authenticated` kept the platform default write grant until `zzz_function_grants` replays after the body. Mirrors changed to `REVOKE ALL … FROM authenticated, anon` then `GRANT SELECT` (MES-7b-1's convention), migration rebuilt; second run **`DRY_OWN_EXIT=0`** (in the transaction: codes 82 · holders admin,cco · doc types 62 · tables 317 · bucket 1 · writable views 0; after ROLLBACK 81 · 313 · no bucket) |
| — | local rehearsal | HEAD's mirrors rebuilt + the migration body applied = the mirror rebuild, **10,530 catalog rows, 0 differences** (functions, views, columns, constraints, triggers, policies, grants, indexes, seed rows); fixtures 269 / 270 green and the 72 injection cells, 0 wrong, on a fresh rebuild after that last DB edit |
| 4 | apply_migration | `APPLY_OWN_EXIT=0` — **window start 2026-10-16 22:46:29 CST** (`db/migration-windows.tsv`) |
| 5 | generate types | `TYPES_OWN_EXIT=0` (NOTIFY pgrst first; additions only — 4 tables, 4 views, 11 functions) |
| 6 | tsc | `TSC_OWN_EXIT=0` |
| 7 | build | `BUILD_OWN_EXIT=0` |
| 8 | full gate | **`GATE_FULL_EXIT=0`** (683 s): rebuild = live, no differences · colgrant live and rebuild 513 relations in 13 batches, no gap · viewwrite live and rebuild **196 views, none writable** (self-test bit) · fixtures all green · anon surface ⊆ baseline (327) |
| 9 | i18n | `I18N_OWN_EXIT=0` |
| 10 | error-swallowing | `SWALLOW_OWN_EXIT=0` (0 unallowed) |
| 11 | layout survey | §5 — 130 page loads, all 200, this cut's pages 0 px overflow at 1280 and 390; two PDF defects found and fixed |
| 12 | smoke | `SMOKE_EXIT=0` — 292 routes + probes: 295 ok, 23 skipped (no data — including `/finance/supplier-statements/[id]` and its `pdf`, by design), 0 failed; 1,310.5 s timed. Scratch reading at start: 6 stale rows reported (all old `ZZ-SMOKE-*`, 1,064–1,706 h, five still referenced — report only, untouched); after the run 0 throwaway accounts and 0 probe roles on live |
| 13 | live verification | §4 — `MES8A_PROOF_EXIT=0` (fifth run; runs 1–4 red on the proof script, nothing left behind) |
| 14 | fresh-clone build | @@CLONE@@ |

Static chain (all 43 build checks, each by its own exit code) green after the last edit; `scripts/check-pdf-routes.mjs` `PDFROUTES_OWN_EXIT=0`
(11 cases, 12 fault cells biting — the three SST cells `sst-render-live`, `sst-no-409`, `sst-orphan-left` each red only in their case).
**Fixtures:** new **269** (16 arms) and **270** (9 arms); pins moved without weakening in 100 (62 doc types, SST anchor / shape / callable rows),
101, 111 (+ `supplier_review_due`, 71 arms), 254 (62), 195 (the COD path now `<certificate id>/x.pdf`, F17). **Fault injection**
(`db/scripts/2026-10-16-mes8a-fixture-injections.py`): 44 cells on 269 + 28 on 270, every cell red in its named arm, every arm red at least once,
the database identical before and after (`injection_probe.Pristine`, 21 objects). The first run found a real gap — no grade in 269 had a cap without
a sampling level, so a V24 that asked only for the cap passed; the fixture now has one, and the cell bites.

## §4 · Live verification (one rolled-back transaction, throwaways only, storage cleaned)

`db/scripts/2026-10-16-mes8a-live-proof.mjs` — **`MES8A_PROOF_EXIT=0`** (fifth run, 23:43:46 CST, 1 min 21 s in the transaction). One psql transaction from BEGIN to ROLLBACK, every action as a throwaway (prefix `mes8aprobe`: `inv` all codes · `rev` the review code · `cfo` the real cfo role, only to decide receipt price requests · `fe` / `fv` finance edit / view · `cod` the COD issue code · seven clones); my own rows only (prefix `ZZ-PROBE-MES8A`); storage objects removed afterwards and both buckets read back as they were. **Runs 1–4 were red on the proof itself, not on the cut, and each left nothing behind** (0 accounts, 0 roles, 0 grants, 0 objects, read after each): ① the reconciliation helper cleared the caller's identity before the next receipt (`PERMISSION_DENIED|action.receive_goods`); ② a finance editor's `UPDATE` of an issued statement is an RLS no-op (no update policy — the guard never sees it), so the proof now asserts the row is unchanged and tests the guard as the owner; ③ the untouched-rows fingerprint counted my own COD and the settings row the proof sets; ④ a parenthesis in the rewritten fingerprint. The AP list equalled the ledger with **0.00 unexplained after every finance step** (`recon` lines).

* **buckets before** — supplier-statement-documents: Storage API 0 objects, SQL 0:- · cod-documents: SQL 2:2f47744f04a15019cfb1f7429c6c1dac
* **recon start** — ap 422188.32 / 381604.42 / 0.00; ar 57545.87 / 43002.12 / 0.00; 
* **recon opening bill** — ap 422588.32 / 382004.42 / 0.00; ar 57545.87 / 43002.12 / 0.00; 
* **recon deposit** — ap 422588.32 / 382004.42 / 0.00; ar 57545.87 / 43002.12 / 0.00; 
* **setup** — own rows (prefix ZZ-PROBE-MES8A): supplier ZZ-PROBE-MES8A-S, material, POs ZZ-PROBE-MES8A-POA / ZZ-PROBE-MES8A-POB, opening bill EXP-2026-0011, receipts IN-2026-0532 (half of A, unpriced) · IN-2026-0533 (priced, no order) · IN-2026-0534 (B); grn_short_pct on live 40
* **pricing** — approvals are on: IN-2026-0533 and IN-2026-0534 each wait as a submitted receipt price request
* **recon receipts priced through the CFO** — ap 424188.32 / 383604.42 / 0.00; ar 57545.87 / 43002.12 / 0.00; 
* **recon prepayment applied** — ap 423888.32 / 383304.42 / 0.00; ar 57545.87 / 43002.12 / 0.00; 
* **recon payment applied** — ap 423638.32 / 383054.42 / 0.00; ar 57545.87 / 43002.12 / 0.00; 
* **recon payment on account** — ap 423638.32 / 382954.42 / 0.00; ar 57545.87 / 43002.12 / 0.00; 
* **ap** — IN-2026-0533 and IN-2026-0534 priced by the cfo throwaway (provisional provisional/provisional) · deposit 300 applied to IN-2026-0534 · PMT-2026-0011 pays 250 on IN-2026-0533 · PMT-2026-0012 100 on account
* **quality** — NCR-2026-0001 open on the half delivery · a dispute between our 20% Ni and their 17% · ISO certificate valid until 2026-09-25 (lapsed inside the window)
* **measures** — ZZ-PROBE-MES8A-S 2026-09-16…2026-10-16: receipts 3 (1 without a line) · short 1/1 compared · over 0 · discharge mismatch 1 · NCR open 1 · dispute 1 · certificate lapse 21 days · grade breaches shown 0 (not scored, CONTRACT-1)
* **not graded** — V23 pending rows 1 · the review reads «V23_NOT_SET» with no grade · grade advice reviewed, not graded, 0 warnings · the gm clone: «PERMISSION_DENIED\|action.supplier_review»
* **graded** — V23 + V24 set by the reviewer → pending ["V24:C"] (C has neither) · review: score 10.1 → B · a correction without a reason «SUPPLIER_REVIEW_CORRECTION_REASON_REQUIRED» · lines widened, corrected with a reason → A, citing the first; the first still reads B / 10.1 / A ≤ 5 · latest = the correction · V23/V24 rows 0
* **po warning** — PO-2026-0012 created (not refused) with «PREPAYMENT_ABOVE_GRADE_CAP» grade A cap 30% vs 50% on order · the finance clone's form preview: the same warning · the warehouse clone's receipt advice: «Every 10th bag» (grade A) · required assays 0 → 0
* **recon statements issued** — ap 423638.32 / 382954.42 / 0.00; ar 57545.87 / 43002.12 / 0.00; 
* **statement** — preview: opening 400 + charges 1600 − payments 350 − prepayments 300 = closing 1350; open items 1450 − on account 100 − residue 0 → difference 0, ties · lines payment:-250.00:false \| payment:-100.00:false \| prepayment:-300.00:false \| receipt:1000.00:true \| receipt:600.00:true · unpriced IN-2026-0532 50 kg
* **issue** — the viewer «PERMISSION_DENIED\|module.finance.edit» · one cent too many on the ledger → «SUPPLIER_STATEMENT_DOES_NOT_TIE\|ZZ-PROBE-MES8A-S\|-0.01\|1350.01\|1350.00», statements written 0 · SST-2026-0001 issued · the same period without a reason «SUPPLIER_STATEMENT_SUPERSEDE_REASON_REQUIRED\|SST-2026-0001\|ZZ-PROBE-MES8A-S» · with a reason → SST-2026-0002; SST-2026-0001 superseded by it, reason kept, figures kept · the finance editor's UPDATE touches no row (no update policy; both still 1350.00,1350.00) · the owner's edit «SUPPLIER_STATEMENT_IMMUTABLE\|update» and delete «SUPPLIER_STATEMENT_IMMUTABLE\|delete» · recon ap 423638.32 / 382954.42 / 0.00; ar 57545.87 / 43002.12 / 0.00; 
* **pdf** — SST-2026-0002: rendered from the frozen row (26356 bytes, 2 pages) · the viewer's upload refused (HTTP 400) · the issuer uploaded supplier-statement-documents/729889a7-733c-42be-8e04-c1f666922bee/48e3214… · sha recorded (sent upper-case, stored 48e3214017fd…, version 1) · the same bytes again «SUPPLIER_STATEMENT_BYTES_ALREADY_RECORDED\|SST-2026-0002\|1» · on the superseded SST-2026-0001 «SUPPLIER_STATEMENT_SUPERSEDED\|SST-2026-0001» · a path elsewhere «SUPPLIER_STATEMENT_ISSUE_PATH_INVALID\|SST-2026-0002» · the viewer downloaded, sha matches · the paper says «SST-2026-0002» «ZZ-PROBE-MES8A Cells Supplier Pte Ltd» «EVoltrya Recovery Pte. Ltd.» «Provisional price» «IN-2026-0532» «50 kg», no Chinese
* **frozen** — supplier renamed live → SST-2026-0002: the row is identical, the stored bytes identical, the paper still says the old name · the preview (live data) says «ZZ-PROBE-MES8A Renamed Supplier»
* **tampered** — SST-2026-0002: bytes overwritten with the service role (+12 bytes) → downloaded sha 7cacf9a1c95a… ≠ recorded 48e3214017fd… → the route answers 409 (route.ts: sha !== issue.sha256; check-pdf-routes SST-409 proves that branch)
* **bucket policy** — as the issuer, a DELETE of the recorded object touches 0 rows · a viewer deletes 0 · an unrecorded orphan: the issuer deletes 1 in SQL (rolled back) and removes it through the Storage API (HTTP 200, 1 removed)
* **F17** — my own issued certificate ZZ-PROBE-MES8A-COD: a path outside its folder «COD_ISSUE_PATH_INVALID\|ZZ-PROBE-MES8A-COD» · upper-case digest stored abababab… (lower-case) · a second set of bytes «COD_BYTES_ALREADY_RECORDED\|ZZ-PROBE-MES8A-COD» · rows 1
* **recon end** — ap 423638.32 / 382954.42 / 0.00; ar 57545.87 / 43002.12 / 0.00; 
* **untouched** — pre-existing rows identical; pending (others) «expense_claim:CLM-2026-0004»; approvals on; require_calibrated_since NULL; reconciliation ap 423638.32 / 382954.42 / 0.00; ar 57545.87 / 43002.12 / 0.00; 
* **done** — 00:01:20.653931

## §5 · Layout survey (desktop 1280 + phone 390)

Live has no review, no V23 / V24 value and no statement (none may be created there), so the survey ran on a local rebuild of this cut's mirrors
seeded with the seven real roles' codes read from live after the migration (`docs/surveys/MES-8a/local-seed-clones.sql`) plus
`docs/surveys/MES-8a/local-seed-data.sql` (a supplier with every measure — short, over, NCRs, a dispute, a discharge mismatch, a lapsed
certificate — V23 + V24, a graded review corrected by another, a supplier with a not-graded review, one never reviewed, AP activity and two
statements over one period, the first superseded), served by local PostgREST behind the harness gateway and `next dev`, measured with
`scripts/survey-phone.mjs`'s own `MEASURE` string and Chrome, with an overflow self-test on every run (bit on all 10, +400 px). One PDF version
was archived through the local route as the finance clone (POST 200, version 1, bytes in the harness store; GET of the frozen render and of
`?version=1` both 200).

**13 routes × 5 roles (admin · cco · finance · warehouse · gm) × 2 widths = 130 page loads: all 200, clipped tables 0.** Routes:
`/suppliers/scorecards` · `/suppliers/[id]/edit` (graded supplier · not-graded supplier) · `/purchasing/orders/new` · `/inbound/[id]/edit` (the
half delivery · the priced receipt) · `/inbound/new` · `/inbound/receive` · `/finance/supplier-statements` · `/finance/supplier-statements/[id]`
(current · superseded) · `/settings/pending-values` · `/`. The supplier pages were measured again with every `<details>` opened (the review
history is collapsed by default): the not-graded supplier shows "Not compared" 4 times, overflow unchanged.

**This cut's pages: 0 px overflow at both widths.** Two pre-existing overflows appear at 390 px with this seed, and **HEAD's code on the same
database reads exactly the same numbers** (`next dev` of `d99da62e` on another port): the supplier edit page's status-panel permission chip
(+40 px for cco · finance · warehouse · gm on an active supplier, +30 px for gm on an approved one) and the new-PO supplier select stretched by the
longest supplier name (+120 to +246 px). This cut adds 0 px to either; both are registered (`MES8A-390-SUPPLIER-STATUS-CHIP`,
`MES8A-390-PO-SUPPLIER-SELECT`).

**The statement PDF** (Quick Look raster of both pages, and pypdf text): two defects found and fixed — the period read
"16 Sep 2026 ’16 Oct 2026" (the "→" is not in the PDF font; now `periodSeparator` "to" / "至") and the **Currency** header was clipped in both
tables (column 8 % → 11 %). After the fix: A4, 2 pages, summary · movements (receipts marked "Provisional price") · open items · payments not yet
applied · received, not yet priced (quantity only) · frozen-at-issue line · no-signature line, English only. The customer statement has the same
"→" (registered `MES8A-CUSTOMER-STATEMENT-ARROW-GLYPH`, not changed here).

## §6 · Role table — the seven real roles (clones of their live codes, read-only, in the proof's transaction)

| Role (account) | codes | suppliers.view | supplier_review | scorecard row | reviews seen | scorecard preview | PO form advice | receipt page: inbound.view · sampling advice | statement list | the statement | its PDF record | PDF download | issue (finance.edit) | pending V23 · V24 (after V23/V24 set) | record a review |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| admin (admin@) | 82 | yes | yes | 1 | 3 | yes | yes | yes · yes | 2 | 1 | 1 | yes | yes | 0 · 0 | yes |
| finance (chooer@) | 43 | yes | no | 1 | 3 | yes | yes | yes · yes | 2 | 1 | 1 | yes | yes | 0 · 0 | no (PERMISSION_DENIED |
| warehouse (fusheng@) | 31 | yes | no | 1 | 3 | yes | yes | yes · yes | 0 | 0 | 0 | no (HTTP 400) | no | 0 · 0 | no (PERMISSION_DENIED |
| cto (phua@) | 39 | yes | no | 1 | 3 | yes | yes | yes · yes | 2 | 1 | 1 | yes | no | 0 · 0 | no (PERMISSION_DENIED |
| cco (sandra@) | 48 | yes | yes | 1 | 3 | yes | yes | yes · yes | 2 | 1 | 1 | yes | no | 0 · 0 | yes |
| cfo (tim@) | 34 | yes | no | 1 | 3 | yes | yes | yes · yes | 2 | 1 | 1 | yes | no | 0 · 0 | no (PERMISSION_DENIED |
| gm (vince@) | 22 | yes | no | 1 | 3 | yes | yes | yes · yes | 2 | 1 | 1 | yes | no | 0 · 0 | no (PERMISSION_DENIED |

Read in the proof's transaction (`ROLE|` lines of `MES8A_PROOF_EXIT=0`), as clones holding each real role's codes at that moment (cco and admin now include `action.supplier_review`). Every one of the seven holds `module.suppliers.view`, so every one sees the scorecard, the reviews, the PO grade advice, the receipt sampling advice and the V23 / V24 rows (V23 read 1 for the admin clone before the settings were set, 0 after); only admin and cco may record a review. The statement, its PDF record and the PDF itself follow `module.finance.view` — warehouse is the one role without it (list 0, statement 0, download refused by the bucket's read policy, HTTP 400); issuing needs `module.finance.edit` (admin · finance).

## §7 · Pages (route → file)

| Route | File |
|---|---|
| `/suppliers/scorecards` | `app/suppliers/scorecards/page.tsx` (+ `ScorecardsTable.tsx`, `SettingsPanel.tsx`) |
| `/suppliers/[id]/edit` (scorecard panel) | `app/suppliers/[id]/edit/page.tsx` (+ `ScorecardPanel.tsx`, `ReviewForm.tsx`, `app/suppliers/MeasuresTable.tsx`; actions `app/suppliers/scorecardActions.ts`) |
| `/purchasing/orders/new` (grade and prepayment warning) | `app/purchasing/orders/new/NewOrderForm.tsx` (+ `SupplierGradeAdvice.tsx`; `actions.ts` `adviseSupplierGrade`) |
| `/inbound/[id]/edit` (sampling advice) | `app/inbound/[id]/edit/page.tsx` (+ `SamplingAdvice.tsx`) |
| `/inbound/new` · `/inbound/receive` (sampling advice) | `app/inbound/new/NewInboundForm.tsx` · `app/inbound/receive/ReceiveForm.tsx` (+ `app/inbound/SamplingAdviceLive.tsx`, `app/inbound/samplingAdviceAction.ts`) |
| `/finance/supplier-statements` | `app/finance/supplier-statements/page.tsx` (+ `IssuePanel.tsx`, `StatementsTable.tsx`, `actions.ts`) |
| `/finance/supplier-statements/[id]` | `app/finance/supplier-statements/[id]/page.tsx` (+ `StatementDetailTables.tsx`, `ArchiveButton.tsx`) |
| `/finance/supplier-statements/[id]/pdf` | `app/finance/supplier-statements/[id]/pdf/route.ts` (+ `renderStatement.ts`, `SupplierStatementDocument.tsx`) |
| `/settings/pending-values` (V23 · V24) | existing page; rows from `db/views/pending_values.sql` |
| `/` (reminder `supplier_review_due`) | existing dashboard; arm in `db/views/operations_now.sql`, entry in `lib/reminders.ts` |

## §8 · Decisions taken without asking

1. **`grn_discrepancies` split into a base view and a wrapper.** The scorecard needs line-level short / over / discharge for a reader holding
   `module.suppliers.view` but not `module.purchasing.view`; `has_permission` resolves the caller even inside owner views, so the body moved to
   `grn_discrepancies_all` (no grant to staff) and `grn_discrepancies` became the gated wrapper, same 30 columns in live order.
2. **A third trail subject, `supplier_score_settings`**, so V23 / V24 changes have a history of their own (the brief named two).
3. **The reminder is gated on `action.supplier_review`** and lists approved and active goods suppliers (drafts and forwarders not).
4. **Measure semantics:** short and over are counted per order line (DISTINCT), short only on closed / cancelled orders; certificate lapse in days;
   NCRs by `opened_at` (Singapore date); withdrawn disputes shown, not scored.
5. **Null counts are not scored** (a comparison never made is not the supplier's fault); the review copies the nulls.
6. **Grading needs only weights + lines**; the review window drives only the reminder. The V23 pending row stays while any of the three is empty.
7. **V24 entries may be partly set**; a grade missing either value is its own V24 row.
8. **The PO warning is previewed on the form** (one implementation with `create_purchase_order`, which also returns it); the PO page itself does not
   repeat it.
9. **Sampling advice on the batch page and both receipt forms.**
10. **Statement semantics:** periods by entry date; the tie is on the closing balance (ledger side vs document side); "unpriced" = received on or
    before the period end and without a price as of that day; recipient and letterhead frozen into the row; named refusals
    `SUPPLIER_STATEMENT_PRICES_RESTRICTED` and `SUPPLIER_STATEMENT_RECEIPTS_RESTRICTED` (a list with masked amounts, or without receipts, cannot tie);
    its own issue guard (`SUPPLIER_STATEMENT_ISSUE_IMMUTABLE`) rather than borrowing the credit-note one.
11. **SST in the payables nav group**; statements live under finance, not on the supplier page.
12. **The statement list shows the frozen supplier code and name.**
13. **Period dates have no defaults** (both required).
14. **Hand-spliced types before the migration** (no docker here); replaced by the real generation after it.
15. **The statement's English comes from `MESSAGES.en`**, explicitly.
16. **Bucket policies:** read `module.finance.view`; upload `module.finance.edit`; delete `module.finance.edit` only while the object is not
    recorded; no update policy.
17. **"Today" for the measures window is the Singapore date.**
18. **The PDF render moved into `renderStatement.ts`** (a route file may not export helpers) so the route and the live proof share one
    implementation; `check-pdf-routes`' `sst-render-live` cell repointed at the new call site (still bites).
19. **Live-proof scenery:** priced receipts go through a receipt price request that a `realRole: cfo` throwaway approves (approvals are on — the
    MES-6b-2 precedent for a decider identity); the two receivable POs are my own rows inserted as approved (an order from `create_purchase_order`
    waits for approval and cannot be received); the over-cap order itself goes through `create_purchase_order`. No receipt reaches **final** price
    in the proof (that needs an assay-sourced request) — "priced" there means priced through the CFO, provisional.
20. **The lapsed certificate in the proof is an ISO (warn) one**, so it cannot block the proof's own later receipts or order; the live
    `grn_short_pct` is read, not changed (a half delivery is short under any threshold below 50 %).
21. **View grants: `REVOKE ALL … FROM authenticated, anon` then `GRANT SELECT`** on the three new views (the dry-run finding, §3).
22. **PDF period separator "to" / "至" and a wider Currency column** (the layout finding, §5).
23. **Smoke:** `/finance/supplier-statements/[id]` and its `pdf` route mapped to `supplier_statements` and listed in `EXPECTED_SKIPS` (no statement
    on live, by the brief).
24. **RUNTIME CONFIG bootstraps** (AGENTS.md): `role_permissions` — unchanged and still correct (admin's bootstrap takes every code, so it holds
    `action.supplier_review` on a rebuild; cco is not a bootstrap role; live grants come from the migration, as `action.issue_coa`'s did);
    `supplier_score_settings` — one row, all four values NULL, correct by Q4 (nothing guessed).

## §9 · Closing live readings

Read **2026-10-16 23:47:41 CST** with the same `docs/surveys/MES-8a/live-readings.sql` (`READ_OWN_EXIT=0`) and `cod-bytes.mjs` (`COD_OWN_EXIT=0`),
diffed line by line against the opening file. **What changed is exactly what the migration created:**

| What | Opening → closing |
|---|---|
| Codes | catalogue 81 → **82** (action 36 → 37: `action.supplier_review`, held by **admin · cco** only) · role codes admin 81 → 82 · cco 47 → 48 · every other role unchanged · role_permissions md5 `2cf8ce23…` → `7b0b8556…` (those two rows) |
| MES-8a objects | tables 313 → **317** (`supplier_score_settings` · `supplier_scorecard_reviews` · `supplier_statement_issues` · `supplier_statements`) · views 192 → **196**, writable pairs **0 → 0** · document types 61 → **62** (SST) · pending arms 29 → **31** · bucket `supplier-statement-documents` created, **0 objects** |
| Nothing set on live | reviews 0 · statements 0 · statement issues 0 · V23 / V24 all NULL · `require_calibrated_since` **NULL** |
| Unchanged, byte for byte | suppliers 17 (`3d18cc35…`) · POs 11 (`1de05245…`) · terms 24 · batches 24 (`6f7a7601…`) · journal 83 / 186 (`d9827dd9…`) · payments 13 · expenses 10 · certificates 4 · NCRs 0 · disputes 0 · every other bucket's count · 7 accounts, **0 disabled**, same roles · pending: CLM-2026-0004 only |
| CODs | COD-2026-0001 / -0002 recorded digests, paths and stored bytes **identical** (`cod-bytes.mjs` output identical to the opening) · `cod_issues` 2 rows, md5 `097dacfa…` unchanged · cod-documents fingerprint `2:2f47744f…` before and after the proof |
| Reconciliation (tim@) | **AP** 422,188.32 / 381,604.42 / **0.00** · **AR** 57,545.87 / 43,002.12 / **0.00** · 1200 61,387.92 / 172,403.48 / **0.00** · 1220 134.86 / 388.20 / **0.00** — identical to the opening |
| change_log | 45,615 → 49,987 rows (max seq 49,633 → 54,360): the migration's own 5 rows, plus committed throwaway-account bookkeeping (accounts, roles, grants made and removed) from the smoke and the five proof runs — no business row. Throwaways on live afterwards: **0 accounts, 0 probe roles, 0 grants** |

## §10 · Registered

* `MES8A-SAMPLING-LEVEL-ADDS-NO-ASSAY` — the sampling level is advice only.
* `MES8A-GRADE-BREACHES-UNSCORED` — shown, not scored, until CONTRACT-1's criterion is fixed.
* `MES8A-VIEW-OUTSIDE-MIGRATION-WRITABLE` — the Q26 gap (F16's substitution, accepted).
* `MES8A-CUSTOMER-STATEMENT-ARROW-GLYPH` · `MES8A-390-SUPPLIER-STATUS-CHIP` · `MES8A-390-PO-SUPPLIER-SELECT` — found by this cut, not caused by it.
* Closed: `MES7A1-RECORD-COD-ISSUE-PARITY` (F17).

## §11 · The window

Start **2026-10-16 22:46:29 CST** (measured, `db/migration-windows.tsv`). End: the deployment, which Tim confirms on Vercel. **Broken in the
window** (derived): nothing — the old app neither reads nor writes the new tables; `create_purchase_order` only gains a return key;
`grn_discrepancies` keeps its columns and order; the old pending-values page does not know V23 / V24 and draws them as their key names until the
deploy.
