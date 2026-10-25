v1.4.73 — Every remaining detail-page table exports to Excel and CSV: operation, output, quality, logistics, safety, stocktakes, suppliers, materials, contracts and the eight shared components (settlement history and the batch movement trail included); previews say so in their About sheet; the spare-parts value column and the maintenance advice say "Restricted" instead of hiding or "—"; the exemption list holds only PERMANENT entries and the build check accepts nothing else. The TABLE-EXPORT family is closed.

# TABLE-EXPORT-3c — hand-back (2026-10-25)

Brief: "TABLE-EXPORT-3c" (Step 0, 2026-10-25) and Tim's rulings Q1–Q5 of 2026-10-25, recorded at their source:
`docs/table-export.md` § "The rulings — Tim 2026-10-25 (TABLE-EXPORT-3c Step 0)". Queue entry `docs/forward-queue.md` 64b-3.
Started from `7fe03e1dfd6b2b60ae31e6fd1b092bfdda664773` (HEAD = origin/main = ls-remote, tree clean). Step 0 survey: `docs/surveys/TABLE-EXPORT-3c/step0.md`;
readings: `docs/surveys/TABLE-EXPORT-3c/readings/`. **No migration**, so no backup, no dry run and no window.

## 0 · Part 1 — TABLE-EXPORT-3b close-out (2026-10-25)

- **Production check:** `db/scripts/2026-10-25-table-export-3b-closeout-prod-check.mjs` → `TE3B_CLOSEOUT_EXIT=0`, 8 / 8 (`readings/closeout-prod-check.txt`, 17:03 CST).
  A throwaway with only `module.purchasing.view` saw two export pairs on PO-2026-0009 (= 3b deployed); its lines export (Excel and CSV) has 4 rows and the
  subtotal, GST and total rows read "Restricted". Expected dates: 0 of 24 live payment terms have one (as `postgres`, base table), so the check proves the "—"
  defect is gone, not a drawn date — PO-2026-0002's three terms (owned events) read "not estimated yet". The first run checked only PO-2026-0009, whose two
  terms have no owner and draw the same sentence before and after 3b, so it could not tell the fix apart (`closeout-prod-check-run1-nondiscriminating.txt`).
- Afterwards 0 throwaway users, roles or orphan grants (`readback-closeout.txt`). 3b marked closed in the queue.

## 1 · Against each scope item and ruling

| Item | Result |
|---|---|
| Shared components (8) | Settlement history (trail; total row last on 3 of 4 pages) · finance attachments (metadata) · batch movements (trail) · module discharge · metal content · price breakdown · terms requests (one pair per open request) · related records (server route, keyset batches of 100). |
| Operation (12 files, 25 tables) | Blending ×3 · downtime · maintenance · spare parts · operation-type fields + machines · work order ×3 · processing run ×14 (contamination, cost, discharge ×3, losses, WO variance, lineage, inputs, outputs, recovery, values, events, header corrections — a trail). |
| Other modules (17 files, 23 tables) | Containers ×2 and forwarder freight (the 3 hand-built tables, now DataTables) · forwarder rate quotes · output assays, traceability ×2, assay metals, apply preview · CoA ×2 · dispute metals · sample custody (trail) + assays · incident linked batches · incident updates (trail) · stocktake posted lines · supplier attachments + compliance · material attachments · contract terms (8 per page). |
| Q1 · spare-parts value | Column kept for every reader; 「受限」 on screen and "Restricted" in the file without the price code; the "column hidden" sentence removed. **Proven live as far as live allows** (§3 S): the column and its header are there for a reader without `data.view_prices`, the sentence is gone. The "Restricted" cell itself is **not measurable on live**: 0 spare-part issues (as `postgres`, base table), and issuing one is a real transaction. |
| Q2 (a) | Stocktake review differences: PERMANENT with Tim's reason. |
| Q2 (b) | Output assay apply preview exported; About "Preview, not applied". Not measurable on live (0 output assays). |
| Q2 (c) | Price breakdown exported on all four pages it appears on; About "Price preview as at <Singapore time>". **Proven live** on the calculator (§3 V). |
| Q2 (d) | Incident suggested batches: PERMANENT with Tim's reason (the linked-batches table in the same file exports). |
| Q3 | Registered (`docs/known-issues.md` § CONTRACT-TERMS-RATES-UNMASKED, next to the settlements entry) and folded into go-live readiness row 12. The export writes what the screen shows. |
| Q4 | Registered (`docs/known-issues.md` § PO-TERM-NOT-APPLICABLE-SENTENCE-FALSE). |
| Q5 | Not split; the whole scope fit. |
| Accepted · maintenance advice | Without `module.finance.view` the two masked numbers in the advice sentence draw 「受限」 (MaskedValue) and the file writes "Restricted" in that sentence. |
| Accepted · 12 silent reads | Settlement allocations (receivables, invoices, expenses, payables, payments), movements (inbound and output edit), attachments (payments, supplier ×3, material) now go through `mustRows`. |
| Accepted · hand-built tables | Container shipments, container documents and forwarder freight are DataTables. |
| Accepted · related records | `app/components/related/relatedRows.ts` (shared with the page) + `/related/[subject]/[id]/[target]/export` and `/documents/[key]/export`. |
| Family close | Exemption list = **24 PERMANENT, nothing else**; `check-table-export` criterion ⑥ refuses any other category (fault injection `cut:` went red, `readings/check-table-export-fault-cut.txt`); queue entry 64b-3 and the umbrella entry closed; `docs/table-export.md` § "The family at close". |

**Final exemption list** (`node scripts/check-table-export.mjs` → `273 tables · 244 declare export · 24 exemptions, all PERMANENT`): see `docs/table-export.md`
§ "The family at close" for every entry and its reason.

## 2 · Verify chain (in order)

| # | Step | Reading |
|---|---|---|
| 1 | offline gate | `GATE_EXIT=0` (`gate-offline.txt`). |
| 2 | migration | none. |
| 3 | tsc | `TSC_OWN_EXIT=0` (15 s). |
| 4 | build | Run 1 `BUILD_OWN_EXIT=1`: the component-library ratchet named a pinned `text-xs` on two cells of the new freight table (`build-run1-pinned-font.txt`); removed. Run 2 `BUILD_OWN_EXIT=1`: `check-nav-routes` named the two new export routes (`build-run2-nav-exceptions.txt`); added as EXCEPTIONS with reasons, beside `/me`'s three export routes. **Run 3 `BUILD_OWN_EXIT=0`** (90 s). |
| — | proof dry run | Before the gate, so a fix to its criteria lands before the gate. Run 1 `TE3C_PROOF_EXIT=1` (`live-proof-run1.txt`): ① the trail reader lacked `module.inventory.view` (the movement rows' read policy) — screen and file were both 0 rows, so a proof fault; ② **a real defect**: a reader who cannot see a processing input's batch (RLS) got "—" for batch, material and construction on screen and blank cells in the file. Fixed under TABLE-EXPORT-2 Q8 (「受限」 / "Restricted"; the table's CHECK guarantees exactly one parent, so a missing embed can only be RLS). Run 2 `TE3C_PROOF_EXIT=0`. |
| 5 | full gate | Run 1 on the code as of then: `GATE_EXIT=0` (18:27:36 → 18:43:39, ≈ 963 s; `gate-full-run1-before-smoke-fix.txt`). Smoke then needed a script change (row 9), so the gate re-ran on the final code: run 2 `GATE_EXIT=5`, DNS could not resolve the pooler — an environment fault, the gate says so (`gate-full-run2-dns-env-fault.txt`); retried once immediately (live answered `select 1` again): **run 3 `GATE_EXIT=0`** on the final code (19:49:18 → 20:06:20, ≈ 1,022 s; `gate-full.txt`), every verdict green. Only this hand-back changed after it. |
| 6 | i18n | `I18N_OWN_EXIT=0` (five new keys: `logistics.colDocSource`, `logistics.colDocStatus`, `table.export.aboutAssayPreviewValue`, `table.export.aboutPricePreviewValue`, `table.export.rowChanged`; one dead key removed, `equipment.parts.valueRestricted`). |
| 7 | error-swallowing | `SWALLOW_OWN_EXIT=0`. |
| 8 | layout survey | 15 pages: one detail page per measurable 3c module plus one page per shared component that live can draw. **390 px 15 / 15 and 1280 px 13 / 13 at 0 overflow, 0 clipped** (`layout-390.txt`, `layout-390-concrete.txt`, `layout-1280.txt`; self-test passed every run). Two pages first read `tableCount 0` (an open stocktake, an empty container) and were re-measured on concrete records that draw the tables. **Not measurable:** quality, safety and contract detail pages (0 rows on live; `layout-390-run1-unmeasurable-routes.txt`); the price breakdown (drawn only after a calculation) and the terms-request panel (only for an open request). |
| 9 | smoke | Run 1 stopped in its pre-flight, before any server: the two new export routes had no id source (`smoke-run1-preflight-export-routes.txt`). They now share the related pages' live lookup of a non-empty key / triple. **Run 2 `SMOKE_EXIT=0`: 338 ok, 25 skipped (no data), 0 failed** (19:00:53 → 19:35:48). It reported 6 stale scratch rows from earlier cuts (1,275–1,918 h old); reported, not swept. |
| 10 | live proof | **`TE3C_PROOF_EXIT=0`, 26 PASS + 1 NOT-MEASURED** (`live-proof.txt`, §3). |
| 11 | COD byte check | `COD_OWN_EXIT=0`: COD-2026-0001 34,701 bytes `ba299a4f3488fc543cdd1f410fabf6523434d39caa0dc58d6f376309c1f42101`; COD-2026-0002 34,746 bytes `717661f6a8166b5f9342324586208e21f29c217aa5d3c047b009e00f2513a4f9`. Both equal the `AGENTS.md` baseline. |
| 12 | fresh clone, no `.env.local` | In the close report. |

## 3 · Live proof (`readings/live-proof.txt`; `next start` on this tree against live; real headless Chrome; files read back)

Throwaways (prefix `te3cprobe`, shared helper): `batches` (`module.inbound.view` + `module.output.view` + `module.inventory.view`) · `procblind` (`module.processing.view`) ·
`pricing` (`module.pricing.view` + both price codes). Row counts read as `postgres` on base tables.

- **T · one shared trail on two pages:** batch movements on `/inbound/<IN-2026-0001>/edit` — 10 rows in Excel and CSV = 10 `inventory_movements`; on
  `/output/<OUT-2026-0118>/edit` — 8 = 8. Each About sheet names its batch.
- **P · a processing-run table:** PROC-2026-0001 inputs — 1 row = 1 `processing_inputs`; for `procblind` batch, material and construction read "Restricted"
  and the quantity is the number 1000. Its outputs: 2 rows = 2, allocated cost and unit cost "Restricted" in all four cells.
- **S · spare parts (Q1):** FA-2026-0001 for `procblind` — HTTP 200, the value column header is on screen, the removed sentence is gone; Excel and CSV
  headers carry the column; 0 rows = 0 issues. **NOT-MEASURED:** the "Restricted" cell itself (0 issues on live).
- **V · a preview with its About note (Q2c):** the calculator (PF-2026-0001, 1,000 kg, 2026-07-30, Ni 10 / Co 5) — the price breakdown's Excel About sheet
  reads `Preview = Price preview as at 2026-10-25 …`, 2 metal rows; CSV 2 rows.

Read back after the live steps (`readback.txt`, as `postgres`, counts only): 7 users, 7 enabled; 0 throwaway users and roles; 0 orphan grants; 0 clean-up
plans; role codes admin · cco · cfo · cto · finance · gm · warehouse; approvals ON (`finance` / `cfo` / 1000); `require_calibrated_since` NULL; 2 CODs;
reconciliation as tim@ (rolled back) AP and AR 0.00 / 0.00 unexplained. Not touched: the portal access-token hook, `portal-uploads`, `claim-receipts`.

## 4 · Decisions taken without asking

1. **Processing inputs a reader cannot see** draw 「受限」 (found by the proof; TABLE-EXPORT-2 Q8).
2. **Visible layout changes:** the container document checklist's one composite cell became Document type · Regime · Source · Status · N/A reason + the form
   column; supplier compliance's "Validity" became Valid from · Valid until (so both are real dates). Nothing else changed on screen except §1's rulings.
3. **Money whose currency is in the column header** exports a bare number (processing cost and outputs), per the existing rule in `docs/table-export.md`.
4. **Composite cells** export the main value or the screen's text, each named in a comment (e.g. the maintenance capital cell is its three sentences joined,
   so the "Restricted" in the advice survives; a badge beside a value is not exported).
5. **Export names:** contract terms are `contract-detail-<section>` because the contracts list already exports `contract-pricing-terms`.
6. Throwaway prefix `te3cprobe` (added to `scripts/ephemeral.mjs`); `scripts/smoke-routes.mjs` covers the two export routes.

## 5 · Assertions measured false

1. Step 0 survey listed the processing inputs' batch as "inference, not measured"; the proof measured it: "—" where 「受限」 belongs (fixed, §4.1).
2. `app/contracts/[id]/page.tsx:258` "seven" term tables — there are 8 (not changed; a comment).
3. The seven earlier-survey statements in `docs/surveys/TABLE-EXPORT-3c/step0.md` §3.

## 6 · Registered, not fixed

- **CONTRACT-TERMS-RATES-UNMASKED** (Q3, go-live row 12) and **PO-TERM-NOT-APPLICABLE-SENTENCE-FALSE** (Q4).
- **EXPORT-DISABLED-ON-ENDED-RECORDS**: on a written-off payables batch, a deleted supplier and a deleted material, the attachment / compliance export buttons
  sit inside `EndedFieldset` (`<fieldset disabled>`) and are disabled.

## 7 · Measured costs, for the next estimate

| Step | Cost |
|---|---|
| offline gate | (`gate-offline.txt`) |
| tsc | 15 s |
| build | 87–91 s |
| full gate | ≈ 963 s · ≈ 1,022 s |
| layout | 286 s (390, 13 pages) · 145 s (390, 2 pages) · 286 s (1280, 13 pages) |
| smoke | ≈ 2,095 s |
| live proof | 532 s |
| conversion | five parallel agents on disjoint files, 195–636 s each (each agent's own measured duration; they ran concurrently) |

No backup.
