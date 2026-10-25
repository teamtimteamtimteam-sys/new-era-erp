# TABLE-FEATURES-1 — Step 0 (2026-10-25)

Brief: TABLE-FEATURES-1 (queue entry 64c, Tim 2026-10-23). Started from `f156ee129225648523e27a8ddcbe898e2bf91f78` (HEAD = origin/main = ls-remote, tree clean).
Survey files (read-only greps and reads, each count with its method and file:line): `survey-lists.md` (list pages, money lists, sorting, print/sticky),
`survey-approvals.md` (approval-type lists, bulk patterns, where rules are enforced), `survey-infra.md` (saved-view storage, sticky/frozen feasibility,
ended-record exports, fiscal calendar). Spot-checked by hand: `decide_leave_request.sql` and `decide_medical_claim.sql` contain 0 `REASON` checks;
`selection=` appears only at `CostSettlePanel.tsx:150,177` outside brand-sampler; 8 files use server sorting; 17 files use `EndedFieldset`.

## Part 1 — TABLE-EXPORT-3c close-out

- Run 1 (20:17 CST): HTTP 200 on both pages but 0 export pairs — production was not yet serving f156ee1 (`readings/closeout-prod-check-run1-no-export-bars.txt`).
- Waited 10 minutes as the brief says. Run 2 (20:31 CST) `TE3C_CLOSEOUT_EXIT=0`, 6 / 6 (`readings/closeout-prod-check.txt`): PROC-2026-0001 draws 7 export pairs;
  its outputs table exports 2 rows (Excel and CSV) = 2 on screen; `/related/processing_run/<PROC-2026-0001>/output_batch` exports 2 rows = 2 on screen = `data-related-total` 2.
- After both runs: 0 throwaway users, 0 throwaway roles, 0 orphan grants (`readings/readback-run1.txt`, `readings/readback-closeout.txt`; as `postgres`, base tables).
- 3c marked closed in `docs/forward-queue.md` 64b-3.

## Survey headline numbers (method in the survey files)

| What | Reading |
|---|---|
| List pages | 271 `page.tsx` → 148 not detail/new/edit → **84 table list pages** (+12 card/bullet lists, 21 reports, 2 action panels, 29 not lists). The old "114" counted files; the same file count today is 112. |
| Table type on the 84 | 73 DataTable · 8 CellsTable (cannot switch any feature on) · 3 EditableTable · 0 hand-built |
| Features on the 84 | server sort 7 · column toggle 0 · search 0 · client paging 0 · selection 0 · footer 0 |
| Paging on the 84 | 19 server-paged · 17 capped with "first N of M" · **48 read everything (stop silently at 1,000 rows — READ-ALL-STOPS-AT-1000)** |
| Repo-wide DataTable | 235 call sites in 182 files: sorting 8 files (7 server + brand-sampler) · column toggle 1 · search 1 · paging 1 (all three only brand-sampler) · selection 1 file (2 sites) · footer 0 |
| Date-range filters | 11 list pages (`/finance/expenses` `/finance/invoices` `/finance/journal` `/finance/payments` `/purchasing/orders` `/inbound` `/output` `/operation/processing` `/hr/leave` `/inventory/reports/ledger` `/settings/deleted`) |
| Money lists | 26 (24 with amounts + 2 price-only); 10 masked for some readers; 15 multi-currency; 14 paged or capped; 2 already show a total (`/finance/expenses`, `/inventory`) |
| Approval-type lists | decide in the list: 5 request panels (journal, warehouse, terms ×2 pages, asset disposal) + expense-claim queue + capture pending drafts. Decide only on the detail page: leave, medical claims, payment requests, POs, overtime, reviews, NCR, suppliers |
| Approval rules | all in DB functions, one document per call (`forbid_self_approval`, `require_approver_for`, `approval_level_for`); no existing per-item partial-failure pattern |
| Saved views | no per-user preference table; precedent `user_dock` (Tim: a table, not a cookie); about 34 list pages keep filters in the URL; DataTable keeps sort/columns in React state |
| Sticky header | will not stick as built: `overflow-x-auto` (`data-table.tsx:592`, `editable-table.tsx:783`) makes the wrapper the scroll container; page scrolls by window; top bar sticky ≈53 px (`TopNav.tsx:221`) |
| Print | no print stylesheet anywhere |
| Ended records | 19 `EndedFieldset` blocks in 17 files, 12 wrap exports (≈38 export sites); 5 PermissionGate sites grey an export for a reader without edit rights; 1 live record (`MetalContentPanel.tsx:243`) |
| Migration needed | saved views only (new table) |

The questions, recommendations, estimate and split are in the Step 0 report to Tim (same session), reproduced below.

## What grilling changed in the scope

1. **The ended-record fix covers every table control, not only export.** `<fieldset disabled>` also greys the search box, client sort headers, the pager and the
   checkboxes, so sorting would arrive already broken on ended records. The fix is also wider than registered: 12 ended blocks (≈38 export sites, not 3 pages),
   5 PermissionGate sites and 1 live record (`survey-infra.md` §C).
2. **A sticky header needs a design decision**, not just a CSS class: the current wrapper prevents it (`data-table.tsx:592`).
3. **"Sorting on every list page" is 84 pages**, of which 48 read without paging and stop at 1,000 rows. Client sort there is "complete" only below 1,000 rows,
   so the type rule (`data-table.tsx:284`) needs a run-time guard, or those pages need server sort.
4. **Bulk actions fit 7 lists, not the register lists.** Leave, medical claims, payment requests, POs, overtime and reviews decide only on the detail page;
   bulk there means first adding in-row decisions. Expense-claim approve needs an account and tax code per line, and capture confirm needs a weight per draft, so only their reject can be one click.
5. **Saved views need a migration** (no preference table), and saving sort or visible columns means moving DataTable's state into the URL.
6. **Footer totals**: 14 money lists page or cap, so an on-screen sum is not the filtered total; 15 mix currencies; 10 mask amounts.
7. **Findings to rule on:** leave and medical-claim rejects need no reason anywhere (0 checks in the DB functions); 5 lists filter by a document date but sort by
   `created_at`; `/hr/leave` lifts pending requests to the top only after the 300-row cap; `/operation/processing` accepts `?sort=` with no control;
   existing P&L/cash-flow date presets compute in UTC, not Singapore time.

## Questions for Tim (recommendations in the session report)

Q1 money lists and footer scope · Q2 bulk actions · Q3 saved views · Q4 sticky header and frozen column (incl. 390 px) · Q5 date presets · Q6 printing ·
Q7 default sort · Q8 which pages count for "every list page" · Q9 how the 48 unpaged lists sort · Q10 ended-record fix breadth · Q11 leave / medical reject reason ·
Q12 the other side findings · Q13 split.

## Estimate (seconds; process costs measured in TABLE-EXPORT-3b/3c, work costs are inference)

Process floor, no migration: offline gate 140 + tsc 15 + build 2 × 100 + full gate 1,043 + i18n/swallow 10 + layout 15 pages × 2 widths × 26 = 780 + smoke 2,640
+ live proof 532 + COD 30 + fresh-clone build 300 (inference) = **5,690 s ≈ 1.6 h**. With a migration add backup 1,740 + dry run 60 + apply 30 + types 30 = 1,860 → **7,550 s ≈ 2.1 h**.
