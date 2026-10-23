v1.4.71 — The finance reports export in their own layout (trial balance, P&L, balance sheet, cash flow, the 13-week cash forecast) and in a flat CSV that names each line; the depreciation and revaluation previews, cost variance, the month-end checklist, list-vs-ledger, metal exposure, the compliance pack and the payroll and processing-cost panels export too; the payroll and processing-cost panels now say 「受限」/"Restricted" where they showed "—"; the change-history export was stopped on a measurement.

# TABLE-EXPORT-3a — hand-back (2026-10-24)

Brief: "TABLE-EXPORT-3" (Step 0, 2026-10-23) and Tim's rulings Q1–Q12 of the same day, recorded at their source: `docs/table-export.md`
§ "The rulings — Tim 2026-10-23 (TABLE-EXPORT-3 Step 0)". Queue entry `docs/forward-queue.md` 64b; 3b and 3c queued as 64b-2 and 64b-3, the trial-balance period as 64b-4.
Started from `da33da46f3f7e38d5afcc64733a567c854271547` (HEAD = origin/main = ls-remote, tree clean). Step 0 survey: `docs/surveys/TABLE-EXPORT-3/step0.md`;
readings: `docs/surveys/TABLE-EXPORT-3/readings/`. **No migration** — no backup, no dry run, no window.

## 0 · Part 1 and Step 0b — TABLE-EXPORT-2b-2 close-out

Recorded in `docs/handbacks/TABLE-EXPORT-2b-2.md` §8 and `docs/forward-queue.md` 64a-3. The production check ran twice:
run 1 (~23:00 CST, `TE2B2_CLOSEOUT_EXIT=1`) saw 2b-1's code because da33da4's build was still running (Tim, from the Vercel dashboard: started ~22:58, 8 min 14 s, Ready ~23:06);
run 2 (23:34:32 → 23:36:00 CST, script unchanged) **`TE2B2_CLOSEOUT_EXIT=0`, 5 / 5**. 0 throwaway accounts after each. The "116 → 117" premise was false — 116 throughout, 117 is the list total; corrected in the 2b-2 hand-back.

## 1 · Against each scope item and ruling

| Item | Result |
|---|---|
| Writer extension (Q2) | `lib/export/report.ts`: a report is sheets of lines — heading / line / subtotal / total, one indent level. Excel: headings shaded and bold, subtotals and totals bold, a rule above totals, detail lines indented. CSV: one flat table, first column "Line type" (Heading · Account · Subtotal · Total), plus a sheet column when there are several sheets. Cell writing shared with the list writer. Buttons: `app/components/ui/report-export.tsx` (`ReportExportBar`, `FlatExportBar`). |
| Q3 report-computed lines | Exported: P&L section subtotals, gross profit (with margin %, as on screen), net profit; balance-sheet subtotals and both totals; trial-balance totals; cash-flow opening / closing; forecast net / closing; the depreciation total and the revaluation "net to 7110" (written "—" when a rate is missing, as on screen — never 0). Q12 still governs lists (`ExportTable` has no line types). |
| B · trial balance (Q11) | Exported as shown, all-time (headings by account type, accounts indented, totals). Period: queued 64b-4. |
| B · P&L · balance sheet | Layout export; **proven live** (§3 F1, F2): totals equal the screen in Excel and CSV. |
| B · cash flow | Summary as a report; the detail table (C) its own pair. |
| B · cost variance (Q11) | Flat: month · cost type · estimated · actual · variance (the estimated and actual figures were only in a hover). |
| B · month-end (Q11) | Flat: step · state · detail. |
| B · cash forecast (Q5) | Weekly grid: one sheet per currency (CSV adds a Currency column); lines, undated and OPEX-cover tables each their own pair (outflows as negative numbers, currency on each cell). |
| B · payables · receivables (Q9) | PERMANENT, "covered by the special exports (AP ageing, AR ageing, management pack)". |
| C · depreciation · revaluation previews (Q5) | Exported as shown; About sheet "Preview as at <date>, not posted". **Proven live** for depreciation (§3 V). |
| C · list-vs-ledger · metal exposure · compliance pack · cash-flow detail | One pair per table (Q1). List-vs-ledger: one per side, amounts as numbers ("—" when a side cannot answer). Compliance pack: 8 tables (the Step 0 survey said 9 — measured 8 `<DataTable` in the file; the build check's count agrees). |
| C · payroll-payments · processing-cost settle (Q4) | Every row regardless of selection; control columns not exported. **Masked amounts now 「受限」 on screen and "Restricted" in the file** (were "—"), by `MaskedValue`'s rule — TABLE-EXPORT-2 Q8 sent these two panels here. **Proven live** (§3 P, C). |
| C · bank import · electricity previews (Q4) | PERMANENT with the two reasons. |
| Management pack tables (Q9) | PERMANENT. |
| Q10 | `BatchAuditTrailTable.tsx` deleted **with its only importer `BatchAuditTrail.tsx`** (itself unused — §6 item 1); `/hr/reviews/cycles` PERMANENT. |
| **D · change-history (Q7)** | **Not built — stopped on the measurement, as Q7 directs.** See §4. |
| Q12 split | 3b and 3c queued with the rulings verbatim (64b-2, 64b-3), before TABLE-FEATURES. |

**Exemption list at close** (`node scripts/check-table-export.mjs`): **TABLE-EXPORT-3 93 · PERMANENT 7** (100 entries).
116 − 16 converted − 1 deleted − 6 made PERMANENT = 93. PERMANENT: brand-sampler, bank import, electricity new, payables, receivables, management-pack tables, reviews/cycles.
Of the 93: 3b's (finance / purchasing / sales / inbound / inventory / hr detail tables + 25 editable) and 3c's (operation, output, quality, logistics, safety, stocktakes, suppliers, materials, contracts, shared components).

## 2 · Verify chain (in order)

| # | Step | Reading |
|---|---|---|
| 1 | offline gate | `GATE_EXIT=0` (`gate-offline.txt`). |
| 2 | migration | none — no backup, dry run, apply or types. |
| 3 | tsc | `TSC_OWN_EXIT=0` (32 s). |
| 4 | build | run 1 `BUILD_OWN_EXIT=1` — every static check green, `next build` could not fetch the Google font (`fonts.gstatic.com`, "issue establishing a connection", `build-run1-font-fetch.txt`); the host answered HTTP 200 a minute later; **run 2 `BUILD_OWN_EXIT=0`** (127 s). |
| 5 | full gate | run 1 `GATE_EXIT=0` (23:59:22 → 00:17:55, verdicts 871 s, 298 fixtures). **The proof script and the `te3aprobe` prefix landed after it, so it was re-run on the final code:** **run 2 on the final code `GATE_EXIT=0`** (01:29:08 start, verdicts 777 s, 298 fixtures, `gate-full-run2.txt`). Only docs changed after it (this hand-back, the queue line). |
| 6 | i18n | `I18N_OWN_EXIT=0` (one dynamic key caught before the build and made literal). |
| 7 | error-swallowing | `SWALLOW_OWN_EXIT=0`. |
| 8 | layout survey | every touched page measurable on live: 14. **390 px 14 / 14, 0 overflow, 0 clipped; 1280 px 14 / 14, 0 / 0**; self-test passed both times. Run 1 at 390 px died on a CDP timeout and left one clean-up step (`fetch failed`) — reaped (`npm run reap:ephemeral`), read back 0 residue, retried. `/compliance/packs/[id]` not measurable: live has **0** stored packs (as `postgres`, base table) — same `PackSections` as `/compliance/packs`. |
| 9 | smoke | **`SMOKE_EXIT=0`: 336 ok, 25 skipped (no data), 0 failed**, 2,310 s. |
| 10 | live proof | **`TE3A_PROOF_EXIT=0`, 41 / 41** (§3). Run 1 kept (`live-proof-run1-criteria.txt`, 9 FAIL, all my criteria — §5). |
| 11 | COD byte check | `COD_OWN_EXIT=0`: COD-2026-0001 34,701 bytes `ba299a4f3488fc543cdd1f410fabf6523434d39caa0dc58d6f376309c1f42101`; COD-2026-0002 34,746 bytes `717661f6a8166b5f9342324586208e21f29c217aa5d3c047b009e00f2513a4f9` — equal to the `AGENTS.md` baseline. |
| 12 | fresh clone, no `.env.local` | in the close report. |

Build-check fault injection: `CHECK_TABLE_EXPORT_FAULT=nobar` names all 7 converted report tables; `blind` exits 1.

## 3 · Live proof (`readings/live-proof.txt`; `next start` on this tree against live; real headless Chrome; files read back)

Throwaways (prefix `te3aprobe`, shared helper): `fin` = `module.finance.view` + `data.view_pay` + `data.view_prices`; `blind` = `module.finance.view`;
`payblind` = `module.finance.view` + `module.hr.view` (see §5 for why).
- **F1 P&L** 2026-01-01 → 2027-12-31: screen gross −23,365.59, net −44,718.53; Excel net −44718.53 (a number) and gross −23365.59 equal; heading bold, net profit bold, account line indented and not bold; About "Period 2026-01-01 → 2027-12-31"; CSV first column "Line type", net profit typed "Total", line types Account · Heading · Subtotal · Total.
- **F2 balance sheet** as of 2027-12-31: screen total assets = total liabilities + equity = 347,979.75 SGD; Excel equal, number format `#,##0.00 "SGD"`, both bold; CSV "Total" line equal.
- **V depreciation preview** 2027-12-31: screen total 3,259.86 = Excel total row; About "Preview as at 2027-12-31, not posted".
- **P payroll panel**: control reads 4,677.00 SGD on screen, 4677 in Excel, "4677 SGD" in CSV; `payblind` reads **Restricted** on screen, in Excel and in CSV; 1 row each = screen (nothing ticked).
- **C settle panel**: control 300.00 / 100.00 / 300.00 / 200.00 / 123.45 SGD; `blind` reads **Restricted** ×5 on screen and in the CSV.
- **Not proven: the change-history export** — not built (§4).

Read back after the live steps (`readback.sql` / `readback.txt`, as `postgres`, counts only): 7 users, 7 enabled, 0 throwaway users / roles, 0 orphan grants;
role codes admin · cco · cfo · cto · finance · gm · warehouse (unchanged); approvals ON (`finance` / `cfo` / 1000); `require_calibrated_since` NULL; 2 CODs.
Reconciliation as tim@ (rolled back): AP and AR agree, unexplained **0.00 / 0.00**. Not touched: the portal access-token hook, `portal-uploads`, `claim-receipts`.

## 4 · D — change-history export stopped on a measurement (Tim Q7)

Q7: "If reading through change_log_rows proves too slow, stop at that point in your report rather than adding a migration on your own."
Measured (`readings/change-log-rows-timing.txt`): live, as tim@ (cfo, holds `data.view_change_log`), `SET LOCAL ROLE authenticated`, rolled back — `change_log_rows` over the last 7 days,
200 rows a call: **5.57 s / 3.52 s / 4.33 s ≈ 18–28 ms a row** (the page itself records "≈ 17 ms a row", `page.tsx:44`). Same window as `postgres`, base table: **31,414 rows / 2,472 transactions**; whole table 81,401.
**One 7-day export ≈ 157 calls ≈ 10–12 minutes; a 366-day range ≈ 81k rows, and stating its count means reading them all first.** Nothing built, no migration.
Recorded in `docs/known-issues.md` § CHANGE-HISTORY-NO-EXPORT and on 64b. **For Tim:** Q7's shape needs a bulk-masking export reader plus a count with the page's filters — a migration.

## 5 · Assertions measured false

1. **Step 0 survey: "compliance pack: 8 sections, nine DataTables".** Measured 8 `<DataTable` in `PackSections.tsx`; 8 exported.
2. **My proof run 1** (9 FAIL, all criteria): read gross profit by exact label (the cell is "Gross Profit(−…%)" with no space); read the depreciation total from the first cell (a DataTable's first cell can be the phone control);
   looked for an "Amount" column on the payroll panel (it is "Net pay"); and used a finance-only reader for payroll, who sees **no rows** — `payroll_lines_masked` shows rows only to `module.hr.view`, or to `module.finance.view` **and** `data.view_pay` (`db/views/payroll_lines_masked.sql:38`), so there is no cell to mask. The reader who sees rows but not pay is hr.view + finance.view.
3. **Brief: "Q4 … two reasons from your report" for the panels** — held; recorded on the entries.

## 6 · Decisions taken without asking

1. **Deleted `BatchAuditTrail.tsx` with `BatchAuditTrailTable.tsx`** — it is the table's only importer, imported by nothing; deleting the table alone would not compile. `auditTrailQuery.ts`'s `loadBatchAuditTrail` is now also unreferenced; left in place (not in Q10).
2. **The C report bodies not named in Q4 / Q5 / Q9** (list-vs-ledger, metal exposure, compliance pack, cash-flow detail) were exported (Q1: one pair per table) — they are C entries and Q12 puts C in 3a; leaving them would have left `TABLE-EXPORT-3` entries no cut owns.
3. **A cell showing several things exports the screen's own text** where no single value stands for it (forecast description + reference, confidence + owner, the compliance limit "≤ 50", inspection results, list-vs-ledger line + its detail lines joined by "; ").
4. **The payroll and settle panels draw 「受限」 on screen too** (not only in the file) — TABLE-EXPORT-2 Q8 ("both the screen and the export") sent these two panels to TABLE-EXPORT-3.
5. **`FlatExportBar`**: a server page cannot hand column functions to a client component, so cost variance and month-end write typed cells on the server and use the list writer.
6. **Line-type label for non-account reports**: the forecast grid's detail lines say "Line", not "Account" (`lineKind: 'other'`).
7. Throwaway prefix `te3aprobe` (added to `scripts/ephemeral.mjs`).

## 7 · Registered, not fixed

- **CostSettlePanel's variance preview with a masked amount**: `accrued` sums `Number(amount_base)`, so for a reader without `data.view_prices` the "accrued / variance" preview line computes from 0. Such a reader cannot meaningfully settle; noted here, not changed (not in scope).
- CHANGE-HISTORY-NO-EXPORT (§4).

## 8 · Measured costs, for the next estimate

offline gate (`gate-offline.txt`) · tsc 32 s · build 87–127 s · full gate run 1 ~1,113 s whole (verdicts 871 s) · smoke 2,310 s · layout ~191 s (390) / ~173 s (1280) for 14 pages · live proof ~6 min · no backup.
