v1.4.69 — The remaining list pages (me, settings, safety, tools, compliance, my-reviews, contracts) now have "Export Excel" and "Export CSV"; the seven of them that showed only their latest N rows say so and export everything; change history says when it stops at 500; pricing formulas show 「受限」 where they were blank, and saving a formula you cannot see the terms of no longer turns them into 0.

# TABLE-EXPORT-2b-1 — hand-back (2026-10-23)

Brief: "TABLE-EXPORT-2b" Step 0 (2026-10-23) and Tim's rulings of the same day, recorded at their source: `docs/table-export.md` § "The rulings — Tim 2026-10-23 (TABLE-EXPORT-2b Step 0)".
Started from `025776a9c347cdecbd1ba04cbad08afbd13606be` (HEAD = origin/main = ls-remote, tree clean). Readings: `docs/surveys/TABLE-EXPORT-2b/readings/`; Step 0 survey: `docs/surveys/TABLE-EXPORT-2b/step0.md`.
**One migration** (Q5 needed it — see §2): `db/migrations/2026-10-23-table-export-2b1-formula-masked-terms-unchanged.sql`.

## 0 · Part 1 — TABLE-EXPORT-2a close-out

| Step | Reading |
|---|---|
| 1.1 | HEAD, origin/main, `git ls-remote origin main` all `025776a9c347cdecbd1ba04cbad08afbd13606be`; tree clean. |
| 1.2 | Production (`https://new-era-erp.vercel.app`), `TE2A_CLOSEOUT_EXIT=0`, 5 / 5: a throwaway reader with a copy of the `finance` role's 43 codes exported `/finance/invoices` as CSV and Excel — HTTP 200, 6 rows each = "Total: 6"; `/finance/payroll-payments` HTTP 200, no error boundary. Read back (as `postgres`, counts only): 7 users, **0 throwaway**, 0 orphan grants. |
| 1.3 | TABLE-EXPORT-2a marked closed (`docs/forward-queue.md` 64a); its hand-back §6 records full gate 1,182 s and smoke 39 min 34 s. |
| (added) | TABLE-FEATURES registered as `docs/forward-queue.md` 64c (after TABLE-EXPORT-3, before the go-live readiness group), Tim's ruling verbatim. |

## 1 · Against each scope item and ruling

| Item | Result |
|---|---|
| A · the 21 `TABLE-EXPORT-2` entries | All converted — 23 files incl. the two parent pages that needed raw fields, ~27 tables: compliance packs · contracts (5) · /me (8 files, 10 tables) · my-reviews · safety environment / incidents / inspections (2) · settings deleted / dictionaries (one export per dictionary) / import / permission reference (one per category) / roles · tools formulas · metal prices (server-paged → its own export route). **`TABLE-EXPORT-2` entries left: 0**; `check-table-export` no longer accepts that cut at all. |
| B · limits on the 2b-1 modules (Q2, Q6) | `/compliance/packs` 300 · `/safety/inspections` runs 200 · `/safety/environment` 300 · `/me` leave · medical · expense 50 each · `/settings/import` 20 (Q1): each keeps its N rows, says "Showing the first N of M — narrow the filters or export" when M > N, and exports every row through a route running the page's own read (`packsRows.ts` · `runRows.ts` · `envRows.ts` · `meRows.ts` · `importRows.ts`). The compliance pack "live for this month" is now its own query, not looked up in the capped list. |
| C · change-history 500 (Q4 of 2026-10-22) | When "show older" stops at 500 and older entries exist, the page says so and how to reach them (`changeHistory.stopsAt`). No export. |
| D · 「受限」 on the formulas table (Q4) | Treatment and discount render 「受限」 / "Restricted" (screen and export) when the reader cannot see that formula's terms; they were blank. |
| E · /hr/reviews (Q10) | All three reads (lines 69–71) go through `mustRows`: a failed read is an error page, not "no reviews". |
| Q5 pricing formula edit | Fixed — see §2. |
| Q5 employee edit | **Measured, not fixed**: on a local rebuild, an editor without `data.view_identity` saving the form clears the stored identity number (`S1234567A` → NULL; control arm keeps it). On live only `cco` (1 holder) has `module.hr.edit` without `data.view_identity`. Registered: `docs/known-issues.md` § EMPLOYEE-EDIT-CLEARS-MASKED-IDENTITY; go-live readiness group row 11. |
| Side finding | **Measured, not changed**: only `warehouse` (1 holder) holds `module.suppliers.view` without `data.view_prices`, and it lacks `module.customers.view`, which `sales_settlements`' read policy requires → it reads 0 rows; no live role has suppliers.view + customers.view without view_prices; the table has 0 rows. Registered: § CONTRACTS-SETTLEMENTS-AMOUNT-UNMASKED; go-live row 12. |
| Q6 split | 2b-2 queued as `docs/forward-queue.md` 64a-3 (v1.4.70) with Q1–Q4 and its half of Q6 verbatim, before TABLE-EXPORT-3. |
| 2b-2 rulings carried | Q1 (capture "recently confirmed", contamination "recent checks") · Q2 notifications · Q3 grants / cycles · Q4 the other 17 sites — all 2b-2, untouched here. |

## 2 · The migration (Q5) — why one was needed

The edit form cannot send "unchanged": a reader without terms visibility never learns the stored value, and `formula_terms_normalize` reads a missing treatment / discount as **0**. So only the database can keep it. The two doors that change an existing formula (`submit_formula_change_request`, `submit_formula_reactivate_request`) now, for a caller for whom `pricing_formula_terms_visible(stored direction)` is false, replace treatment, discount **and payable lines** with the stored values before the request is built (payables are masked the same way and the old page would have submitted them as the string "null"). Signatures unchanged (preflight: 2 replaced, 0 new). The page draws 「受限」 in those three places and sends nothing for them; the action decides "masked" by its own server read of `pricing_formulas_masked`, never from the form. Fixture **292** (A purchase side · B sale side · C control arm sets 0 · D reactivate · E fault injection: the old body writes 0).

**Broken window:** opened **2026-10-23 15:55:48 CST** (`db/migration-windows.tsv`); closes when Tim sees the deployment Ready. During it the old page still submits 0 / 0 for a blind editor and the new database keeps the stored values — the only behaviour that changes is the defect; nothing is broken in the window.

## 3 · Verify chain (every exit read from the script's own line)

| # | Step | Result |
|---|---|---|
| 1 | offline gate | `GATE_EXIT=0`, 134 s |
| 2 | backup | `BACKUP_EXIT=0` — 15:20:55 → 15:49:40 (28 min 45 s); TOC 9,875; change_log 79,192 rows in 18 segments, totals and seq bounds match |
| 3 | live dry run COMMIT → ROLLBACK | `DRY_OWN_EXIT=0`: inside, both functions carry the check, anon false / authenticated true, approvals on; after rollback, old bodies |
| 4 | apply | `APPLY_OWN_EXIT=0`, committed 15:55:48 CST |
| 5 | types | `TYPES_OWN_EXIT=0`, no diff (signatures unchanged) |
| 6 | tsc | `TSC_OWN_EXIT=0` (before and after apply) |
| 7 | build | `BUILD_OWN_EXIT=0` on run 2 (before apply) and again after apply. Run 1 (`build-run1.txt`): the three `/me/*/export` routes were under no registry entry — added to `check-nav-routes` EXCEPTIONS with their reason (same treatment as `/me/avatar`). |
| 8 | full gate | `GATE_EXIT=0` — 15:58:50 → 16:14:43 (**953 s**, verdicts 766 s): rebuild · mirrors vs live · all fixtures incl. 292 · anon (327) · no-role (126) · portal (42) |
| 9 | i18n · error-swallowing | `I18N_OWN_EXIT=0` · `SWALLOW_OWN_EXIT=0` (0 unallowed) |
| 10 | layout survey | 14 pages — one per 2b-1 module plus every 2b-1 part-B page, change-history and `/hr/reviews` (`/me`, `/my-reviews`, `/contracts`, `/compliance/packs`, `/safety/inspections`, `/safety/environment`, `/safety/incidents`, `/settings/import`, `/settings/change-history`, `/settings/dictionaries`, `/settings/roles`, `/tools/pricing/formulas`, `/tools/pricing/metal-prices`, `/hr/reviews`): 390 px 14/14, 0 overflow, 0 clipped (`SURVEY390_OWN_EXIT=0`); 1280 px 14/14, 0, 0 (`SURVEY1280_OWN_EXIT=0`); self-test passed both times. First screen only; the survey session is not an employee, so `/me`'s tables were not on its screen. |
| 11 | smoke | **`SMOKE_EXIT=0` on run 2** (17:03:34 → 17:35:59, **32 min 25 s**): 324 ok · 25 skipped (no data) · 0 failed. Run 1 (`smoke-run1-me-export-403.txt`, 37 min 46 s): 321 ok, 3 failed — the three `/me/*/export` routes answered 403 to smoke's non-employee session, which is the correct answer; declared as expected `[403]` with the reason (same shape as `/portal/my-data`), owner half proven live (M1). |
| 12 | live proof | **`TE2B1_PROOF_EXIT=0`, 22 / 22 PASS on run 4** (`live-proof.txt`; `next start` on this tree against live; real headless Chrome clicks the export buttons, files read back). **F1 prices (purchase terms)** `/tools/pricing/formulas` PF-2026-0001 (direction both): reader without `data.view_purchase_prices` — screen "Restricted", CSV and Excel "Treatment (USD/t)" / "Discount %" = "Restricted"; reader with it — 800 / 20, Excel typed Number; About sheets name the reader. **F2** the blind reader's edit page has no treatment / discount input and no payables bridge, "Restricted" × 7. **Q5 rolled back**: the blind editor (holds `module.pricing.edit`) submitted 0 / 0 / [] + a new name → the request proposes **800 / 20 / 3 payable lines** with the new name; control (sees the terms) → proposes 0 / 0; after ROLLBACK, terms_requests count and the formula's terms identical to before. **C1** `/settings/change-history?show=500` (live 79,000+ change_log rows): the stop notice is on screen and the "older" link is gone (load 107 s); `?show=20`: no notice, link present. **M1** a throwaway employee exported their own leave list: HTTP 200, 0 rows (live holds 6 leave requests of other people — none appeared); an account without an employee profile → 403 EXPORT_DENIED. Runs 1–3 kept: run 1 change-history navigation timed out at 120 s / networkidle2; run 2 waited for a `<main>` element the page does not have; run 3 my criterion asked for a "Code" header where the table's is "Ref" (the measured facts were already right). No masking family other than prices is touched by 2b-1 (the /me tables are the reader's own rows). |
| 13 | COD byte check | `COD_OWN_EXIT=0` before and after: COD-2026-0001 34,701 bytes `ba299a4f3488fc543cdd1f410fabf6523434d39caa0dc58d6f376309c1f42101`; COD-2026-0002 34,746 bytes `717661f6a8166b5f9342324586208e21f29c217aa5d3c047b009e00f2513a4f9` — equal to the `AGENTS.md` baseline. |
| 14 | fresh clone, no `.env.local`: `npm ci && npm run build` | in the close report (it builds the commit that contains this file) |

**Read back after the live steps** (`readback.json`, `recon.txt`): 7 users, 7 enabled, 0 throwaway users / roles / employees, 0 orphan grants; role codes held admin · cco · cfo · cto · finance · gm · warehouse (unchanged); approvals ON (`finance` / `cfo` / 1000); `require_calibrated_since` NULL; 2 CODs; 0 terms requests; PF-2026-0001 still 800 / 20. Reconciliation as tim@ (rolled back): AP and AR agree, unexplained **0.00 / 0.00**.
Not touched: the portal access-token hook, the `portal-uploads` and `claim-receipts` buckets and their policies.

**Measured costs, for the next estimate:** offline gate 134 s · backup 1,725 s · full gate 953 s · smoke 1,945 s (run 2) / 2,266 s (run 1) · layout 157–160 s per width for 14 pages · build ~100 s · live proof ~5 min (C1's `?show=500` alone 107 s).

## 4 · Not measured, handed to Tim

- **A 2b-1 part-B page past its limit, on live.** Live base tables: compliance_packs 0 · inspection_runs 0 · import_batches 2 · own leave / claims per person far below 50. The notice and "past the old limit" are not observed on live; the routes return every row (M1, and the export path is the same code as 2a's B1).
- **The /me tables in the layout survey** — the survey session is not an employee.
- **The employee identity fix** — measured and registered (go-live row 11), not fixed, per Q5.

## 5 · Assertions in the brief measured false

1. "No migration is expected" — Q5 required one (§2); added backup, dry run, apply and types as the brief said, and said why.
2. "Remove the throwaway account" (1.2) — done; read back 0.

## 6 · Decisions taken without asking

1. **Payable lines are treated like treatment and discount** in Q5 — they are masked by the same rule; the old form would have sent the string "null" for them.
2. **The action decides "masked" by its own server read**, never by a flag from the form — a forged flag would have sent a blank as 0 for a reader who can see.
3. **`check-table-export` stops accepting `cut: 'TABLE-EXPORT-2'`** now that it is empty — the list may only shrink.
4. **Import history's "who" cell became data** (name / restricted / not recorded) instead of a React node, so it can travel through the JSON export route; the screen is unchanged.
5. **`/me` export routes refuse a non-employee** (403) and a floor-display session; smoke declares the 403 with its reason.
6. **Expense-claim rows carry `has_receipt` per item** (from `meRows.ts`), so an exported claim beyond the 50 on screen still says whether each line has a receipt.
7. The compliance-pack page's "live pack for this month" is a query of its own, not a lookup in the capped list.
8. Throwaway prefix `te2b1probe`.
