# TABLE-FEATURES-3 — Step 0 (2026-10-26)

Brief: "TABLE-FEATURES-3" (Tim 2026-10-26). Rulings Q2 · Q3 · Q11 of 2026-10-25 are closed (`docs/table-features.md`); this file records only what was measured and what is new.
Started from `f5a62e79f60c37ffdb5228df804032d31f824ff3` (HEAD = origin/main = ls-remote, tree clean).

## Part 1 readings
- Live-safety audit of TF-2 §6: `readings/tf2-live-safety-audit.txt` (method, both backups, change_log, sequences, transcript findings).
- Production check: `readings/tf2-closeout-prod-check.txt` (run 2, 4/4) · run 1 probe fault `readings/tf2-closeout-prod-check-run1-probe-fault.txt` · read back `readings/readback-closeout.txt`.

## A · Saved views — the 84 list pages (`survey-lists.mjs` → `survey-lists.tsv`)
Method: for each route in `scripts/check-list-sorting.mjs` LIST_ROUTES, the `.tsx/.ts` files in the route directory (comments stripped): `<DataTable|EditableTable|CellsTable` count,
`mode: 'client'` / `mode: 'server'` count, the keys of the page's `searchParams` type, `'use client'` files holding filter-like `useState`.
- **All 84 keep their filters in the URL.** The one client-state hit (`/hr/employees` `EmployeeForm.tsx`) is a form, not a filter. Q3's premise holds.
- **29 pages have a real filter in the URL** (keys other than page / sort / dir / trail / k / warn / corrects); **55 have sort only** (40 browser-sorted, 15 database-sorted).
- **48 pages sort in the browser** (React state in `app/components/ui/data-table.tsx`) — that sort is not in the URL yet; 8 of them are filter pages. Database sort is already `?<prefix>sort=&<prefix>dir=` (`lib/listSort.ts:31-42`, the prefix exists for two tables on one page).
- **16 pages draw more than one table** (e.g. `/compliance/packs` 9, `/me` 10) — each table's sort needs its own URL key.
- No preference table exists; precedent `user_dock` (one row per user, own-row policies; `docs/surveys/TABLE-FEATURES-1/survey-infra.md` §A).
- Date presets write literal dates (`?date_from=2026-10-01&date_to=2026-10-31`) — a view saved from "This month" stores October.

## B · Bulk actions — the 7 lists
| List | Renders as | Single-item action → DB function | Reason on reject |
|---|---|---|---|
| /finance/journal `JournalRequestsPanel.tsx` | **cards** (one `<div>` per open request, `:107`) | `decideJournalRequest` → `decide_journal_request` (fixed level 2 / CFO) | UI + SA + DB `JOURNAL_REQUEST_REJECT_REASON_REQUIRED` (`decide_journal_request.sql:49-52`) |
| /inventory `WarehouseRequestsPanel.tsx` | **cards** | `decideWarehouseRequest` → `decide_warehouse_request` | UI + SA + DB |
| /contracts + /tools/pricing/formulas `TermsRequestsPanel.tsx` | DataTable | `decideTermsRequest` → `decide_terms_request` | UI + SA + DB |
| /finance/assets `AssetDisposalRequestsPanel.tsx` | **cards** | `decideDisposalRequest` → `decide_asset_disposal_request` | UI + SA + DB |
| /finance/claims `ClaimDecisionPanel.tsx` | **cards** | `decideClaim` (approve=false) → `decide_expense_claim_items(p_claim_id, false, …, p_notes)` | DB only |
| /operation/capture pending drafts | DataTable (`page.tsx`), buttons in `CaptureControls.tsx` | `rejectDraft` → `reject_capture_draft(p_draft_id, p_reason)` | UI + SA + DB |
- DataTable `selection` exists (`data-table.tsx:358`, select-all over `visible`, `:667-674`) but reaches only the 2 DataTable lists; the 4 card lists need a checkbox per card.
- `TermsRequestsPanel` is also drawn on two detail pages (`/contracts/[id]/page.tsx:218`, `/tools/pricing/formulas/[id]/edit/page.tsx:141`); Q2 names the 2 list pages, so bulk is a prop the list pages turn on.
- Per-item results: `showActionMessage` already takes one entry per item with its own subject (all 4 request panels use it).
- **CFO level admits only real holders of the `cfo` role** (`approval_level_eligible.sql` → `real_role_holders`); a throwaway role from the shared helper never qualifies.
- **Live today (read as postgres, base tables, read-only):** journal / warehouse / terms / asset-disposal requests **0 rows each**, capture drafts **0**, expense claims 1 submitted.

## C · Leave and medical-claim reject
- `decide_leave_request(p_request_id, p_approve, p_notes)` and `decide_medical_claim(p_claim_id, p_approve, p_notes)` reject with no reason check (`decide_leave_request.sql:39-47`, `decide_medical_claim.sql:19-26`).
- The 12 engine chains raise `<CHAIN>_REJECT_REASON_REQUIRED|<label>` in the function (`decide_journal_request.sql:49-52`) — the same shape fits here.
- Callers: app `app/hr/leave/actions.ts`, `app/hr/leave/[id]/DecideControls.tsx` (free optional notes input), `app/hr/claims/actions.ts`, `ClaimControls.tsx`; 11 fixtures — every reject call in them already passes a non-blank note (grep of `false, '…'`).
- Live: 1 rejected leave request has blank notes → the rule goes in the function (as every chain does), not a table CHECK, which that row would fail.

## Corrections measured while building (2026-10-26)
1. **28 filter pages, not 29.** The count above used a two-pass regex that left `corrects` on `/safety/environment` (it pre-fills a correction form; not a filter).
   Recounted by splitting the keys (`survey-lists.tsv`): 28 filter pages · 8 of them browser-sorted · 56 sort-only.
2. **The terms panel is a card list too.** Its DataTable is each request's change table inside the card; the requests are cards. So 5 of the 7 bulk lists are card
   lists and only the weighbridge drafts are a table (a server-rendered `CellsTable`).
