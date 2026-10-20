# EXPENSE-MULTILINE-1 — Step 0 survey (2026-10-20)

Every object that reads or writes `expenses`, and what changes for each **under the recommended shape** (header keeps its id, code and
stored document totals; a new `expense_lines` table holds account · tax code · net · tax · notes · capital/PO-line links per line).
If Tim rules differently on Q1–Q12 of the Step 0 report, the "changes" column moves with the ruling.

> **Ruled 2026-10-20 (Tim), and where the build differs from this survey:** Q1 — capital documents stay **one line**, so the
> asset / cost-entry / anchor / maintenance tables get **no** `expense_line_id`, the PO-line link and `uq_expenses_live_po_line`
> stay on the header, and `reverse_expense_internal` keeps reading one cost entry. Q3 (changed) — claims get items (§0b below).
> Q15 — no export. The approval roster (`approval_chain_gates`) now names `decide_expense_claim_items`, the function that
> actually enforces the level (fixture 203E: roster = catalogue). Everything else as listed.

**How it was measured:** live catalog read as `postgres` over psql (`rolbypassrls`, base tables): `pg_constraint` (FKs into `expenses`),
`pg_depend`/`pg_rewrite` (views), `pg_proc.prosrc ~ '\mexpenses\M'` plus a second pass for `'expense'` / `expense_id` without the table name;
repo `grep` over `app/ lib/ scripts/ db/fixtures/`. No browser, no route census.

## Live data (as `postgres`, base table, 2026-10-20 ~19:45 CST)

`expenses` 10 rows: 10 posted · 0 reversed · 0 mirrors · 2 `paid` · 8 `unpaid` · 1 with a PO line · 4 tax-coded · 0 WHT · 3 owed to employees.
Rows hanging off them: `journal_entries` (source `expense`) 10 · `payment_allocations` 1 · `finance_attachments` 1 · `fixed_asset_cost_entries` 1 ·
`prepayment_applications` 1 · `expense_claims` 1 · `medical_claims` 1 · `processing_cost_entries.relief_expense_id` 1 · `fixed_assets` 0 · anchors 0 ·
maintenance 0 · electricity 0 · assay disputes 0. Largest live document by lines: PO 1 · invoice 1 · journal entry 5.

## Foreign keys into `expenses` (14) — all point at the DOCUMENT; none changes target

| FK | changes |
|---|---|
| `expenses.reversed_by_expense` | none (mirror is a document) |
| `payment_allocations.expense_id` | none — a payment settles the document's one payable |
| `finance_attachments.expense_id` | none — attachments belong to the document |
| `prepayment_applications.expense_id` | none — cap stays `amount_ccy + tax_ccy` of the header (`apply_prepayment.sql:182`) |
| `expense_claims.expense_id` · `medical_claims.expense_id` | none — one claim → one one-line document |
| `processing_cost_entries.relief_expense_id` · `electricity_allocations.expense_id` · `electricity_allocation_reversals.reversal_expense_id` · `assay_disputes.fee_expense_id` | none |
| `fixed_assets.expense_id` · `fixed_asset_cost_entries.expense_id` · `fixed_asset_depreciation_anchors.expense_id` · `equipment_maintenance.capitalised_expense_id` | **gain an `expense_line_id`** if capital is per line (Q1) — the document id alone cannot say which line bought which asset |
| `equipment_maintenance.expense_id` | none (a pointer to the document) |

Payment requests carry `expense_id` inside `payment_requests.allocations` (jsonb), checked by `payment_request_required.sql:55-78` — **unchanged** (header id kept).

## Writers (functions that INSERT into `expenses`)

| object | changes |
|---|---|
| `record_expense` (765 lines) | split: a new document writer takes header + `p_lines jsonb`; **`record_expense` keeps its exact signature as a one-line wrapper** (Q11) so its 3 SQL callers, 2 app callers and 140 fixture calls (38 files) are untouched. Per-line: account check, 1500↔asset pairing (`:76`), PO-line block (`:96-188`), tax resolve + `tax_amount_for`/`tax_included_in`, capital new/append/anchor (`:575-745`). Per-document: date, FX, payee, WHT (`:397`), WHT-vs-GST refusal (`:424`), code, ONE journal entry |
| `reverse_expense_internal` (203) | mirror header + mirror lines; asset cost return must **loop over every cost entry** (today one `SELECT … INTO`, `:89`); `EXPENSE_HAS_ASSET` (`:53`) per Q4 |
| `post_electricity_allocation` (133) · `relieve_processing_accruals` (124) | write one line beside the header they already write |

## Other functions (reading)

| object | changes |
|---|---|
| `guard_expense_mutation` (in `db/tables/expenses.sql`) | drops moved columns; a sibling guard makes `expense_lines` insert-only (no UPDATE/DELETE) |
| `guard_expense_po_line` + `uq_expenses_live_po_line` | move to lines; the partial index needs the document's status on the line (or a trigger) — a partial index cannot read another table (same reason `invoice_lines` carries `invoice_voided`) |
| `guard_gst_switch` (`:47`) | reads `expense_lines.tax_code` |
| `guard_po_line_received_floor` (`:28`) | reads the line's PO link |
| `apply_prepayment` | selects `e.tax_rate_pct` but never uses it (`:144`, only `:182` reads tax) — drop from the select |
| `record_payment_internal` · `ap_aging_asof` · `supplier_statement_data` · `payment_request_required` · `record_approval_decision` · `decide_expense_claim` · `pay_medical_claim` · `link_dispute_fee` · `record_equipment_maintenance` · `electricity_allocation_compute` · `reverse_electricity_allocation` · `reverse_expense` · `relieve…` callers | **none** — header totals/ids only (WHT rate read per document, `record_payment_internal.sql:485`) |
| `trail_subject_members` · `trail_prelog_sources` · `trail_subjects` · `trail_refs` | add `expense_lines` as a member table of the `expense` subject (change_log trigger on the new table) |
| GST return / F5 | **none** — derived from `journal_lines.tax_code`; each expense line keeps its own tax-coded debit leg |
| `search_documents_sql` (registry `document_types`: `expense` matches `payee_name, notes`) | none required; line notes are not searchable unless added (not proposed) |

## Views (6) — all read header-level columns only

`ap_open_items` · `assay_dispute_rows` · `equipment_maintenance_advice` · `expense_claim_status` · `medical_claim_status` · `processing_cost_variance` → **none**, provided the header keeps `amount_ccy` / `amount_base` / `tax_ccy` / `tax_base` as stored document totals (Q10).

## Pages / app files (26 files grep-hit)

| file | changes |
|---|---|
| `app/finance/expenses/new/NewExpenseForm.tsx` (588) · `actions.ts` (138) · `page.tsx` (210) | rewrite to header + line grid; server action validates lines; grid draft (Q8); 390 px |
| `app/finance/expenses/[id]/page.tsx` (385) | header + lines table; account/tax per line; capital links per line |
| `app/finance/expenses/page.tsx` · `ExpensesTable.tsx` | account column + account filter (`page.tsx:68`) — Q9 |
| `app/finance/gst/page.tsx:39` | count tax-coded lines instead of documents |
| `lib/trail/render.ts:3751` | `account_code` leaves the header row's value list; line rows rendered |
| `app/finance/assets/[id]/actions.ts:40` (add cost) · MaintenancePanel capitalise path | none (one-line wrapper) |
| payment-requests / payments / processing-costs / assets / electricity / equipment / disputes / claims / purchasing pages | none — read `id, code` or totals |
| `app/finance/expenseErrorCodes.ts` · messages | new refusal codes (line-indexed) |

**CSV export: there is none.** No expense CSV route or button exists (`grep -i csv|export app/finance/expenses/*` → only TS `export` keywords). Brief assertion measured false.
**PDFs: none read `expenses` directly**; the supplier statement PDF reads `supplier_statement_data` (header totals) → unchanged.

## Fixtures

43 files mention `expenses` / `record_expense`; 38 call `record_expense(` (140 calls) — untouched under the wrapper. 3–4 read moved
header columns; 4 insert into `expenses` directly (47 · 105 · 245 · 261) → edited. New fixtures: document shape, mixed GST, capital per line, reversal, migration backfill.

## Not in scope, found on the way

- `relieve_processing_accruals` still defaults `p_payment_status = 'paid'` (`:21`) — a cash-out at creation with no payment request, the shape PAY-REQ-1 closed in `record_expense` (`:217`). Not registered in `docs/known-issues.md` (grep: 0 hits). Q12.

---

# Step 0b — expense-claim items (Tim 2026-10-20, Q3 changed)

Measured the same way (live as `postgres` over psql; repo grep). Recommended shape: `expense_claims` stays the header (code, employee,
status, decision, totals); new `expense_claim_items` (date, receipt amount (tax-inclusive, as today), description, no-receipt reason, and — filled at
approval — account and tax code). Approval creates ONE expense document with one line per item.

## Live data
`expense_claims` **4 rows, not 2**: CLM-2026-0001 withdrawn · 0002 approved (→ the one live claim expense, 6120 / TX) · 0003 rejected · 0004 submitted
(the one nobody can approve, `docs/known-wrong-until-cutover.md:226`). `finance_attachments` with a `claim_id`: **0**.

## Functions (read `expense_claims`)
| object | changes |
|---|---|
| `submit_expense_claim` | takes items; keeps its signature as a one-item wrapper (19 fixture calls) |
| `decide_expense_claim` | per-item account + tax; evidence check per item; one `record_expense`-family call with N lines; keeps its signature for one-item claims (32 fixture calls) |
| `withdraw_expense_claim` · `next_expense_claim_code` | none |
| `expense_claim_amount_base` | none if the header keeps the total and one date/currency (reads `amount_ccy, currency, spend_date`, `:54`) |
| `approval_pending_documents` · `my_document_decisions` · `self_approved_decisions` · `record_approval_decision` · `payment_request_required` · `approval_chain_gates` · `approval_log_readable` · `self_approval_exception` | none — header columns only (code, employee, status, decision, `expense_id`) |
| `trail_subject_members` (`:377-379`) | add `expense_claim_items` to `expense_claim` / `my_expense_claim` |
| view `expense_claim_status` | unchanged columns; items read separately (or an item count added) |
| search (`document_types.expense_claim` matches `description, no_receipt_reason, decision_notes`) | header only; item text not searchable unless the registry learns child tables |

## Pages
| file | changes |
|---|---|
| `app/me/MyExpenseClaimsPanel.tsx` (236) — the ONLY submit form | single-amount form → item grid; phone-first (390 px); no draft hook today |
| `app/finance/claims/ClaimDecisionPanel.tsx` (234) · `page.tsx` · `actions.ts` | one account/tax select per claim (`:148-166`) → per item |
| `app/finance/claims/[id]` | **does not exist** (brief assumed a detail page) |
| `/hr/claims` + `/hr/claims/[id]` | **medical claims** (`medical_claim_status`, `submit/decide/pay_medical_claim`) — share no table with expense claims; unaffected unless Q-medical says otherwise |
| `lib/trail/render.ts:3771-3775` | item rows rendered; `account_code` moves to items |

## Receipts — a missing capability, not a choice
No code path uploads a receipt to a claim: `FinanceAttachmentParent.kind` is `sale | inbound | payment | expense` (`app/components/finance/financeAttachmentTypes.ts:35`),
`finance_attachments` INSERT needs `module.finance.edit` and SELECT needs `module.finance.view` (live `pg_policy`), and an employee holds neither.
`has_receipt` is displayed (`MyExpenseClaimsPanel.tsx:114`, `ClaimDecisionPanel.tsx:140`) but can only ever be false for a claim made in the app;
so every claim needs a no-receipt reason or is refused `EXPENSE_CLAIM_NO_EVIDENCE` (`decide_expense_claim.sql:166`).

## Masking
No `data.view_health` predicate on any expense-claim object (grep 0). Tim 2026-10-20: general claim descriptions are not masked → item descriptions likewise.

## Fixtures / scripts
12 fixtures (19 `submit_expense_claim(` · 32 `decide_expense_claim(` · 8 direct `INSERT INTO expense_claims`), 7 proof scripts.
