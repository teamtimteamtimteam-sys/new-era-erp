# TABLE-FEATURES-2 — footer totals survey (read-only, 2026-10-26)

Repo: `/Users/timchen/Documents/projects/new-era-erp`. Ruling under measurement (Tim 2026-10-25, Q1, closed — docs/table-features.md:10): *Footer totals on the 24 amount lists (not /tools/pricing/formulas or /tools/pricing/metal-prices); on commissions, total only the rows that hold an amount. A footer totals every row matching the filters, calculated by the database. One total per currency. If any amount in the set is hidden from the reader, the total reads 「受限」/"Restricted".*

**Method.** Nothing edited except this file; nothing built, run, imported or queried. Read source with `cat`/`grep`/`sed`. The 24 routes come from docs/surveys/TABLE-FEATURES-1/survey-lists.md §3; every amount column and file:line was **re-measured** on today's tree (TF-1 moved lines). Each page's `page.tsx`, its `*Rows.ts`/`*Query.ts`/`*Table.tsx`/`*Panel.tsx`, its export route if any, and the `db/views/*.sql`, `db/functions/*.sql`, `db/tables/*.sql` (RLS policies, CHECKs, NOT NULLs) it reads were read by hand, in five groups. The load-bearing claims were then re-checked directly: expenses and payments reversal mirrors (reverse_expense_internal.sql:143-159; reverse_payment_internal.sql:54-68), the invoices status=all merge (invoices/page.tsx:70-75), the `journal_lines` restrictive policy (journal_lines.sql:106-111), `medical_claim_status` per-row CASE (:27-30), `invoice_status FROM invoices_masked` (:44), `sales_settlements` RLS vs the /contracts gate (sales_settlements.sql:90-92; contracts/page.tsx:64), the `ap_open_items` inbound-row drop (:110,119 + inbound_batches_masked.sql:44), the commissions basis CHECK (commission_agreements.sql:62-67), the expenses summary read (expenses/page.tsx:66-79) and the inventory bar (inventory/page.tsx:325-328).

**PostgREST aggregates.** Nothing in the repo turns them on or off: no `db_aggregates`/`aggregates_enabled` anywhere, no `.sum()` call in app/ or lib/, no `supabase/config.toml`. PostgREST ships with them **off**; switching on is a role setting (`pgrst.db_aggregates_enabled` on `authenticator`) + reload — not app code. Being checked separately; every page below gives both answers. Live `max_rows = 1000` (lib/export/serverRows.ts:6-7; lib/listSort.ts:25 `READ_ROW_LIMIT`) — an aggregate returns one row so it is not affected, but every unpaged list read and every RPC TABLE result is.

**A cross-cutting trap for aggregates ON.** `sum()` skips NULL, so on a `*_masked` view a hidden amount does not make the sum NULL — it makes it *smaller* (AGENTS.md:938-940, "让那一项从合计里消失"). The restricted flag must therefore be computed separately: `count(*)` vs `count(amount)` works **only where the base column is NOT NULL** (then NULL ⇔ hidden). It fails where NULL is legitimate (commissions rate rows, self-approved leave rows, PO tax on untaxed orders, invoice open on void rows, inventory never-costed batches) — there use the permission check (`can(…)`) or an explicit per-row visibility predicate.

## 1. Roll-up

**Denominators.** 24 pages → **29 amount tables** → **52 money columns** (51 amounts + 1 price, inventory `avgPrice`). Counted per page below (tables with no money column — e.g. /me attendance, /finance/wht rates, /finance/electricity meters — are not counted). /finance/journal's requests panel is not a DataTable and is left out.

| Route | Tables / cols | Source | Paged · capped · one read | Masking (how 受限 arises) | Currency | Proposed computation (aggs ON / OFF) | Migration if aggs OFF? |
|---|---|---|---|---|---|---|---|
| /contracts | 1 / 1 | `sales_settlements` | one read | none on column; **RLS drops all rows** without customers.view | USD fixed | ON: `.sum()` + `can()`; OFF: fn | yes |
| /finance/assets | 2 / 5 | `fixed_assets`, `fixed_asset_depreciation`, RPC preview | one read | none | per-row (cost) + base | ON: two sums; OFF: fn. Preview: **existing RPC total already satisfies** | yes (register) |
| /finance/bank | 1 / 2 | `bank_transfers` | cap 50 | none | per-row (account→ccy in JS) | ON: group by account; OFF: fn | yes |
| /finance/bank/statements | 1 / 2 | `bank_statements` | ?page= 20 | none | per-row | **no meaningful sum** (balances) | — |
| /finance/claims | 1 / 1 | `expense_claim_status` | one read | none | per-row | ON: view `.sum()`; OFF: fn | yes |
| /finance/close | 2 / 3 | `period_closes`, `year_closes` | one read | none | base | **no meaningful sum** (cumulative snapshots); netResult only dubious | — |
| /finance/credit-notes | 1 / 1 | `credit_notes` + lines (JS sum) | ?page= 20 | none | per-row | view or fn either way (join header ccy × line amount) | yes (both) |
| /finance/electricity | 1 / 3 | `electricity_allocations_masked` | one read | whole-reader (`data.view_prices`) | base (per-row column exists) | ON: masked view sums + `can()`; OFF: fn | yes |
| /finance/expenses | 1 / 1 | `expenses` | ?page= 20 | none | per-row (+ base) | ON: works except account filter; OFF: fn | yes (account mode: both) |
| /finance/freight | 1 / 1 | `freight_documents` | cap 200 | none | base | ON: `.sum()`; OFF: fn | yes |
| /finance/invoices | 1 / 3 | `invoice_status` / `invoices_masked` | ?page= 20 | whole-reader (`data.view_prices`) on total, open; settled unmasked | base | ON: sums + count vs count; OFF: invoker fn | yes |
| /finance/journal | 1 / 1 | `journal_entries` + `journal_lines_masked` (JS sum) | ?page= 20 | **per row** (payroll entries, `data.view_pay`) | base | ON: embed (unverified); OFF: fn. **Never base `journal_lines`** | yes |
| /finance/payment-requests | 1 / 1 | `payment_requests` | ?page= 20 | none | per-row | ON: group by currency, kind; OFF: fn | yes |
| /finance/payments | 1 / 1 | `payments` | ?page= 20 | none | per-row (+ base) | ON: by direction, cannot net reversals; correct = fn | yes (both, if netting) |
| /finance/self-approved | 1 / 1 | RPC `self_approved_decisions()` | one read (RPC, silently ≤1000) | **per row** (medical, `approval_log_amount_visible`) | per-row | DEFINER fn either way | yes (both) |
| /finance/supplier-statements | 1 / 1 | `supplier_statement_rows` | cap 300 | none | per-row base_currency | **no meaningful sum** (closing balances) | — |
| /finance/wht | 2 / 4 | `wht_liability_by_month`, `wht_remittances` | one read | none | base | ON: view sums; OFF: view/fn | yes |
| /hr/claims | 1 / 1 | `medical_claim_status` | cap 300 | **per row** (others' claims without `data.view_health`) | SGD fixed | ON: sum + count vs count; OFF: fn | yes |
| /hr/payroll | 1 / 2 | `payroll_periods_masked` | one read | whole-reader (`data.view_pay`) | per-row | ON: sums + counts; OFF: fn | yes |
| /inventory | 1 / 4 | 7 reads, aggregated in JS | one read ×7 | whole-reader (`data.view_prices`); market value unmasked | base ×2 + USD | fn either way (market value not expressible) | yes (both) |
| /logistics/forwarders | 1 / 1 | `ap_open_items` (JS sum) | one read | all-or-nothing finance.view; **view silently drops inbound rows** without purchase prices | base | ON: sum + two `can()`s; OFF: fn | yes |
| /me | 3 / 7 | `payroll_lines_masked`, `medical_claim_status`, `expense_claim_status` | payslips one read; claims cap 50 ×2 | own rows: never restricted | per-row / SGD | ON: claims yes, payslips no; OFF: 3 fns | yes (payslips: both) |
| /purchasing/orders | 1 / 4 | `purchase_order_status` / `purchase_orders_masked` | ?page= 20 | whole-reader (`data.view_purchase_prices`; prepaid `module.finance.view`) | per-row + prepaid base | ON: sums + counts/`can()`; OFF: invoker fn | yes |
| /sales/commissions | 1 / 1 | `commission_agreements` | one read | none; rate rows legitimately NULL | per-row | ON: `basis=in.(…)` sum; OFF: fn | yes |

**Counts (each over the 24 pages, each list summing to 24):**
- Paging: **8 paged** `?page=`+`.range` (bank/statements, credit-notes, expenses, invoices, journal, payment-requests, payments, purchasing/orders) · **5 capped** + RowCapNotice (bank 50, freight 200, supplier-statements 300, hr/claims 300, /me claims ×2 at 50) · **11 one read** (contracts, assets, finance/claims, close, electricity, self-approved, wht, hr/payroll, inventory, forwarders, commissions). So on **13** the screen is a slice and only a DB total can be "every row"; on the 11 one-read pages the screen is everything only up to 1,000 rows.
- Masking: **15 never restricted** (contracts*, assets, bank, bank/statements, finance/claims, close, credit-notes, expenses, freight, payment-requests, payments, supplier-statements, wht, commissions, /me) · **6 whole-reader** (electricity, invoices, hr/payroll, inventory, purchasing/orders, forwarders*) · **3 per row** (journal, self-approved, hr/claims). *= rows dropped silently instead (§3).
- URL filters a total must honour: **8 pages** (bank/statements, expenses, invoices, journal, payment-requests, payments, hr/claims, purchasing/orders); the other 16 have only fixed predicates (`deleted_at IS NULL`, `superseded_by IS NULL`, forwarder type …).
- Shared page/export filter parsing in a `*Rows.ts`: **13 pages** (bank, bank/statements, credit-notes, expenses, freight, invoices, journal, payment-requests, payments, supplier-statements, hr/claims, /me claims, purchasing/orders). The 11 one-read pages export client-side from loaded rows (no route, no shared builder). In most `*Rows.ts` the **filter applier is module-private** and must be exported for a totals reader: statementRows.ts:43 `applyFilters`, invoiceRows.ts:71/77 `applyDates`/`applyState`, journalRows.ts:46, requestRows.ts:45, paymentRows.ts:50, claimsRows.ts:60 `filtered()`, orderRows.ts:84-95 — expenses already exports `applyExpenseFilters` (used at expenses/page.tsx:70).
- Needs a migration **even with aggregates ON: 5 pages** (credit-notes — group by an embedded column is unverified, a view is safer; self-approved — RPC + per-row flag + DEFINER; inventory — market value; /me payslips — currency on an hr-only table; expenses account mode — JS id list), plus payments if reversal pairs must net. With aggregates OFF: **every page that gets a total** needs a migration (one function/view each, + db/functions mirror + grants; a new view needs `REVOKE ALL` + `GRANT SELECT`).

**Sum meaning, over the 52 columns:**

| Class | Cols | Which |
|---|---|---|
| Meaningful as is | **18** | contracts amount; assets costBase, accum, preview delta; credit-notes total; invoices total, settled, open (issued only); wht withheld, remitted, unremitted; inventory stock, cost, market; forwarders owed; PO net, gross, prepaid |
| Meaningful only after a status / reversal rule | **16** | bank out, in (reversed transfers); electricity bill, runs, overhead (reversed allocations); expenses (mirror double-count); freight (reversed); journal (reversal 2×; Σ = turnover); payments (mirror double-count, in/out mixed); wht remittance amount (reversed); finance/claims (approved/rejected/withdrawn mixed); hr/claims, /me medical, /me expense (status mix); self-approved (decisions, approved+rejected, possibly two levels); payment-requests (6 kinds) |
| Dubious by what one row is | **12** | assets cost (historic, per ccy), nbv (disposed rows); close netResult (reopened rows); hr/payroll gross, net (per-period totals, all-time, drafts); /me payslips ×5 (per period, drafts, employer CPF); PO tax (untaxed rows NULL); commissions (per-tonne rates) |
| Meaningless | **6** | bank/statements opening, closing; close debits, credits; supplier-statements closing; inventory avgPrice (a price) |
| **Total** | **52** | |

## 2. JS-side filtering, merging and aggregation (hazards for "same filters")

A DB total must apply exactly the page's filter. These pages do part of the work in JS:

| Page | What JS does | file:line | What the DB total must do |
|---|---|---|---|
| /finance/claims | table shows only `status !== 'submitted'` (filter in JS after an unfiltered read) | finance/claims/page.tsx:100-101 | add `status <> 'submitted'` |
| /finance/expenses | `account` filter resolved in JS: unpaged `expense_lines` read (cut at 1,000), JS id list into `.in('id', …)` (URL length), JS per-document line sums | expenseRows.ts:54-64,80 | `EXISTS (… account_code = $a)` in SQL; in account mode sum **line** amounts |
| /finance/invoices | `status=all` appends **all** void rows after each issued page; `total += voidRows.length`; totalPages from issued count only | invoices/page.tsx:66,70-75 | follow the export's clean union (invoices/export/route.ts:26), not the page |
| /finance/assets | accum summed per asset in JS; NBV derived in JS — from an unpaged read | assets/page.tsx:103-109,184,196 | compute in SQL (and ideally per row too, so rows and footer agree) |
| /finance/credit-notes | note total = JS Σ of lines | creditNoteRows.ts:66-67,74-75,97 | join lines → header currency |
| /finance/journal | entry amount = JS Σ debit of lines; restricted if any line restricted | journalRows.ts:94-103,115 | Σ debit over `journal_lines_masked` ⨝ entries; restricted if any `amounts_restricted` |
| /finance/wht | remittance `reversed` derived from a second read | wht/page.tsx:86-97,127 | join `journal_entries` status='posted' |
| /finance/bank | currency per transfer looked up in JS (`''` on miss) | transferRows.ts:73,86-87 | `bank_native_currency(account)` |
| /finance/self-approved | restricted flag rebuilt in JS (RPC returns none) | self-approved/page.tsx:64-68,83 | `approval_log_amount_visible()` in SQL |
| /inventory | whole table built in JS from 7 unpaged reads: material merge, unit merge, kg assumption, partial pricing, deleted-material batches kept, unrounded | inventory/page.tsx:249-307; lib/valuation.ts:86-113 | a function that states its batch set explicitly |
| /logistics/forwarders | owed = JS Σ `open_base` per forwarder | forwarders/page.tsx:90-94 | Σ in SQL |
| /me payslips | currency joined in JS from `my_period_labels()` | me/page.tsx:239-241,330 | owner-rights function |
| /purchasing/orders | gross/tax display mapping | orderRows.ts:190-192 | equivalent to `sum(gross_total_ccy)` — no hazard |

## 3. Rows the reader cannot see (a footer cannot show 受限 for rows it never receives)

1. **/contracts — whole table dropped by RLS.** Gate `requireModule(MOD.suppliers)` (contracts/page.tsx:64) = `module.suppliers.view`; `sales_settlements` SELECT policy is `has_permission('module.customers.view')` (sales_settlements.sql:90-92). A suppliers-only reader gets 0 rows and the "none" sentence (contracts/page.tsx:410-411). A sum would say 0. Fix: compute `restricted = NOT has_permission('module.customers.view')`.
2. **/logistics/forwarders — rows dropped inside an owner-rights view.** `ap_open_items` reads `inbound_batches_masked` (ap_open_items.sql:110) and keeps `ib.unit_price IS NOT NULL` (:119); `unit_price` is NULL without `data.view_purchase_prices` (inbound_batches_masked.sql:44). A finance reader lacking purchase prices silently loses every inbound open item; masked prepayments `COALESCE` to 0 (ap_open_items.sql:101-102,116-118,149-151) so expense rows read too high. Not detectable by count-vs-count; the flag needs `has_permission('data.view_purchase_prices')`. (Pre-existing; also affects the per-row figure today.)
3. **/finance/journal — trap, not current behaviour.** `journal_lines` has a RESTRICTIVE policy hiding payroll lines without `data.view_pay` (journal_lines.sql:106-111). The page reads `journal_lines_masked` (correct). A totals query written against base `journal_lines` would silently shrink — must use the masked view or a DEFINER body (precedent trial_balance_totals.sql:2-5).
4. **/finance/invoices — rows mis-filtered for a masked reader.** Without `data.view_prices`, `total_base` is NULL so `payment_state` can never be `paid` and `overdue` is NULL (invoice_status.sql:36,40): `state=paid`/`overdue` return 0 rows; a paid invoice shows `partial`. The settled total (unmasked) is then over a wrong set.
5. Every other page: the RLS/view predicate is the page-gate permission (all-or-nothing), so a reader past the gate sees every row. Each section cites the policy.

## 4. Per-row masking (restricted depends on which rows match)

- **/hr/claims** — `CASE WHEN has_permission('data.view_health') OR mc.employee_id = current_user_employee() THEN mc.amount_sgd ELSE NULL` (medical_claim_status.sql:27-30). An HR reader without view_health sees own claims and NULL for others; filter `employee=<self>` makes the total fully visible, any other set → 受限. Base NOT NULL > 0 (medical_claims.sql:13) → count(*) vs count(amount_sgd) is exact.
- **/finance/journal** — `WHEN has_permission('data.view_pay') OR e.source_type IS DISTINCT FROM 'payroll' THEN l.debit` (journal_lines_masked.sql:19). Restricted iff the date range contains a payroll entry and the reader lacks view_pay.
- **/finance/self-approved** — `CASE WHEN approval_log_amount_visible(subject_type, subject_id) THEN amount_ccy END` (self_approved_decisions.sql:48); leave rows are legitimately NULL (approval_log.sql:171-173), so count-vs-count fails; use the predicate in SQL.
- /me reads the same per-row views but only own rows → never restricted.

## 5. Per page (sections 1–5 of the brief per page; paths relative to app/<route>/ unless they start with db/ or lib/)

### /contracts — 1 amount table, 1 amount column

| Column | Table file:line | Source + query | Amount / currency | Masking | Sum meaningful? |
|---|---|---|---|---|---|
| settlement `amount` | ContractsTables.tsx:192 | `sales_settlements`, page.tsx:112-116 | `amount_usd` (db/tables/sales_settlements.sql:59); USD fixed, in header (ContractsTables.tsx:82) | none on the column; RLS hides **all** rows unless `module.customers.view` (sales_settlements.sql:90-92) | yes — recorded (not posted) settlement value |

- **Paging:** one read, no limit (page.tsx:112-116) → 1,000-row max_rows applies. Client sort `coverage: 'complete'` (ContractsTables.tsx:194).
- **Filters:** `.is('superseded_by', null)` (page.tsx:115); no URL filter. JS: 1:1 map (page.tsx:219-237), nothing dropped; cell shows `String(amount_usd)` (page.tsx:234).
- **Export:** client-side `exportSpec` on loaded rows (ContractsTables.tsx:195); no export route, no shared query builder.
- **RLS silent drop (flag):** page gate `requireModule(MOD.suppliers)` (page.tsx:64) = `module.suppliers.view` (lib/modules.ts:107); `sales_settlements` RLS requires `module.customers.view` (sales_settlements.sql:92). A reader with suppliers but not customers sees **zero rows** and the "none" sentence (page.tsx:410-411). A sum would read 0, not 受限.
- **Aggregates ON:** `sales_settlements?select=amount_usd.sum()&superseded_by=is.null` + app-side `can('module.customers.view')` → 受限 when false. No migration.
- **Aggregates OFF:** `sales_settlements_totals()` → (currency 'USD', total, restricted = NOT has_permission('module.customers.view')). Migration.
- **Existing total:** none.

### /finance/assets — 2 amount tables, 5 amount columns

| Column | Table file:line | Source + query | Amount / currency | Masking | Sum meaningful? |
|---|---|---|---|---|---|
| `cost` (original ccy) | AssetsTable.tsx:98 | `fixed_assets` `select('*')`, page.tsx:102 | `cost_ccy` / per-row `currency` (fixed_assets.sql:25-26) | none | dubious — historic cost, mixed currencies |
| `costBase` | AssetsTable.tsx:111 | same | `cost_base` (fixed_assets.sql:29) / base | none | yes for active; disposed assets are still listed |
| `accum` | AssetsTable.tsx:120 | `fixed_asset_depreciation` `select('asset_id, amount_base')`, page.tsx:103; **summed in JS** page.tsx:106-109 | Σ `amount_base` / base | none | yes for active; disposal keeps depreciation rows (dispose_fixed_asset_internal.sql:60-61) |
| `nbv` | AssetsTable.tsx:125 | **derived in JS** page.tsx:184,196 | cost_base − accum / base | none | **dubious** for disposed rows (shows cost−accum; book NBV is 0) |
| preview `delta` | DepreciationPreviewTable.tsx:45 | RPC `preview_depreciate_fixed_assets`, page.tsx:112-115 | `delta_base` / base | RPC `require_permission('module.finance.view')` (fn :55) | yes |

- **Paging:** both reads unbounded (page.tsx:102-103). **Live hazard today:** depreciation has one row per asset per month; past 1,000 rows, on-screen accum/NBV are silently wrong (READ-ALL-STOPS-AT-1000). A DB footer would then disagree with the rows above it.
- **Filters:** none on the register; `?date=` (page.tsx:96) feeds only the preview. JS: preview rows filtered `delta_base > 0` (page.tsx:116) — harmless, the function clamps negatives to 0 (fn :107) and its total sums the clamped values (:108).
- **Export:** client `exportSpec` both tables (AssetsTable.tsx:162; DepreciationPreviewTable.tsx:61); no route.
- **RLS:** both tables `module.finance.view` (fixed_assets.sql:109-111; fixed_asset_depreciation.sql:30-32) = page gate → nothing dropped.
- **Aggregates ON:** `fixed_assets?select=currency,cost_ccy.sum(),cost_base.sum()` and `fixed_asset_depreciation?select=amount_base.sum()`; NBV = difference. Excluding disposed needs `fixed_assets!inner(status)` embed filter. No migration; restricted always false.
- **Aggregates OFF:** `fixed_assets_totals()` → (currency, cost_ccy, cost_base, accum, nbv, restricted=false). Migration. Recommended alongside: compute per-asset accum in the DB too so rows and footer agree.
- **Existing total:** the **preview already has a server-computed total row** — RPC's `total_delta` (fn :124-125) appended as a pseudo-row page.tsx:123-125 (`isTotal`). This one already satisfies the ruling (DB-computed, one base currency, no masking). Register: none.

### /finance/bank (transfers) — 1 amount table, 2 amount columns

| Column | Table file:line | Source + query | Amount / currency | Masking | Sum meaningful? |
|---|---|---|---|---|---|
| `out` | TransfersTable.tsx:88 | `bank_transfers`, transferRows.ts:57-67 | `amount_out` (bank_transfers.sql:19); currency = from-account's, **looked up in JS** from `bank_reconciliation_status` (transferRows.ts:73,86) | none | yes per currency — **only if reversed transfers excluded** |
| `in` | TransfersTable.tsx:93 | same | `amount_in` (bank_transfers.sql:20) / to-account ccy (transferRows.ts:87) | none | same |

- **Paging:** cap 50 (transferRows.ts:19; page.tsx:96) + RowCapNotice (page.tsx:239).
- **Filters:** none (sort only, transferRows.ts:31-35). JS: no drops; currency `''` if lookup misses (transferRows.ts:86-87).
- **Reversed rows** stay listed with `reversed_at` set (bank_transfers.sql:24; transferRows.ts:91) — a naive sum counts them.
- Only accounts 1000 and 1010 exist, no self-transfer (bank_transfers.sql:17-18,29).
- **Export:** shares `parseTransferListParams` / `transferCount` / `transferPage` / `shapeTransferRows` (transferRows.ts:33,53,57,70; export/route.ts:11,16-22).
- **RLS:** `module.finance.view` (bank_transfers.sql:40-42) = gate.
- **Aggregates ON:** `bank_transfers?select=from_account,amount_out.sum()&reversed_at=is.null` (+ to_account/amount_in); account→currency in app. No migration.
- **Aggregates OFF:** `bank_transfer_totals()` grouping by `bank_native_currency(from_account)` / `(to_account)` (helper used at bank_reconciliation_rows.sql:17). Migration.
- **Existing total:** none (the account cards above are not a table).

### /finance/bank/statements — 1 amount table, 2 amount columns

| Column | Table file:line | Source + query | Amount / currency | Masking | Sum meaningful? |
|---|---|---|---|---|---|
| `opening` | StatementsTable.tsx:64 | `bank_statements`, statementRows.ts:59-71 | `opening_balance` / per-row `currency` (bank_statements.sql:16,19) | none | **no** — point-in-time balance per statement |
| `closing` | StatementsTable.tsx:69 | same | `closing_balance` (bank_statements.sql:20) | none | **no** — same |

- **Paging:** `?page=` 20/page (page.tsx:24,49-57), `.range` (statementRows.ts:69).
- **Filters:** `deleted_at is null`; `?account=` → `.eq('bank_account_code')`; `?status=` → `.eq('status')` — all in `applyFilters` (statementRows.ts:43-47, not exported), parsed by `parseStatementListParams` (statementRows.ts:30-36). JS: no drops.
- **Export:** shares `parseStatementListParams` / `statementCount` / `statementPage` / `shapeStatementRows` (export/route.ts:9,13-20).
- **RLS:** `module.finance.view` (bank_statements.sql:62-65).
- **Proposed:** no balance sum. Only defensible alternative: net movement Σ(closing − opening) per currency (needs `applyFilters` exported; aggregates or a migration function).
- **Existing total:** record count only (page.tsx:107).

### /finance/claims — 1 amount table, 1 amount column (the pending queue above is cards)

| Column | Table file:line | Source + query | Amount / currency | Masking | Sum meaningful? |
|---|---|---|---|---|---|
| decided `amount` | ClaimDecisionPanel.tsx:93 | view `expense_claim_status`, page.tsx:47-52 | `amount_ccy` (NOT NULL, > 0) / per-row `currency` (view :65-66; expense_claims.sql:23-24) | none; `canDecide`/`data.view_prices` gates only the decision form (ClaimDecisionPanel.tsx:190) | **dubious** — "decided" mixes approved, rejected, withdrawn, and approved-then-expense-reversed (view :74) |

- **Paging:** one read, unbounded (page.tsx:47-52); item read also unbounded (page.tsx:55-59).
- **Filters:** none in the DB. **JS-side filter (hazard):** table shows only `status !== 'submitted'` (page.tsx:101; pending split at :100) — a DB total must add `status <> 'submitted'`.
- **Export:** client `exportSpec` (ClaimDecisionPanel.tsx:291); no route.
- **RLS / predicate:** view is owner-rights with row predicate `has_permission('module.finance.view') OR employee_id = current_user_employee()` (view :57, :90) — same code as page gate → finance reader sees every row.
- **Aggregates ON:** `expense_claim_status?select=currency,amount_ccy.sum()&status=neq.submitted` (optionally `status=eq.approved&expense_reversed=is.false`). No migration; restricted always false.
- **Aggregates OFF:** `expense_claim_totals(p_statuses text[])` with the same predicate. Migration.
- **Existing total:** none.

### /finance/close — 2 amount tables, 3 amount columns

| Column | Table file:line | Source + query | Amount / currency | Masking | Sum meaningful? |
|---|---|---|---|---|---|
| debits | CloseHistoryTable.tsx:60-63 | `period_closes`, page.tsx:80-83 | `total_debits` / base (`getBaseCurrency`, page.tsx:76,117) | none; NOT NULL (period_closes.sql:22) | **No** |
| credits | CloseHistoryTable.tsx:64-67 | same | `total_credits` / base (page.tsx:118) | none; NOT NULL (:23) | **No** |
| netResult | YearCloseHistoryTable.tsx:29-33 | `year_closes`, page.tsx:86-88 | `net_result` / base (page.tsx:214) | none; NOT NULL (year_closes.sql:15) | **Dubious** |

- **Why not:** each `period_closes` row is a **cumulative snapshot from inception** to `period_end` (period_closes.sql:21-23; close_period.sql:65 `WHERE je.entry_date <= p_period_end`) — summing rows counts the same postings many times. Reopened rows are kept and a re-close adds another row (period_closes.sql:9-10). `net_result` is one year's result (year_closes.sql:15); Σ is "cumulative closed-year result" only with `reopened_at IS NULL` (reopened rows are shown greyed, YearCloseHistoryTable.tsx:53).
- **Paging:** one read each, no limit (page.tsx:80-88); ~one row per close.
- **Filters:** none; `?period=` drives only the preview (page.tsx:155-160). JS: reshape only (page.tsx:112-126, 210-218).
- **Export:** client `exportSpec` (CloseHistoryTable.tsx:101; YearCloseHistoryTable.tsx:54); no route.
- **RLS:** `has_permission('module.finance.view')` (period_closes.sql:65-68; year_closes.sql:60-62).
- **Existing DB totals (not footers):** preview Σ debits/credits via RPC `journal_close_preview` (page.tsx:170-178; journal_close_preview.sql:20-23); year preview `net_result` via `preview_close_financial_year` (page.tsx:85,313).
- **Proposal:** no footer. If wanted: Σ `net_result` over `reopened_at IS NULL` — aggregates ON `year_closes?select=net_result.sum()&reopened_at=is.null` (no migration); OFF a function/view (migration). Restricted impossible.

### /finance/credit-notes — 1 amount table, 1 amount column

| Column | Table file:line | Source + query | Amount / currency | Masking | Sum meaningful? |
|---|---|---|---|---|---|
| total | CreditNotesTable.tsx:84-88 | header `credit_notes` (creditNoteRows.ts:47-56); amount = `credit_note_lines.amount` **summed in JS** per note (creditNoteRows.ts:66-67,74-75,97) | Σ lines / **per-row** `credit_notes.currency` (credit_notes.sql:26) | none — `amount` NOT NULL > 0 (credit_note_lines.sql:22); only customer name masked by `can('module.customers.view')` (creditNoteRows.ts:63,92) | yes, per currency (notes immutable, no void — credit_notes.sql:33) |

- **Paging:** `?page=` 20 (page.tsx:24,51-53; creditNoteRows.ts:54); exact head count (creditNoteRows.ts:43-45).
- **Filters:** none (sort only, creditNoteRows.ts:32-34). JS: per-note line sum. Hazard: lines read by `inChunks` 100 ids per request, each unpaged (lib/export/serverRows.ts:80-94) — >1,000 lines in one chunk under-sums silently (export path).
- **Export:** app/finance/credit-notes/export/route.ts:9-20 shares `creditNoteCount`/`creditNotePage`/`shapeCreditNoteRows`.
- **RLS:** both `has_permission('module.finance.view')` (credit_notes.sql:68-69; credit_note_lines.sql:59-60).
- **Proposal:** amount on lines, currency on header → needs a join. **Recommended either way:** view `credit_note_currency_totals` (`SELECT cn.currency, sum(l.amount) … GROUP BY cn.currency`) or function `credit_note_totals()` — migration + `REVOKE ALL`/`GRANT SELECT` (new views get default write grants). Aggregates ON in principle `credit_note_lines?select=amount.sum(),credit_notes!inner(currency)` — grouping on an embedded column unverified. Restricted always false.
- **Existing total:** none.

### /finance/electricity — 1 amount table, 3 amount columns (meters table has none)

| Column | Table file:line | Source + query | Amount / currency | Masking | Sum meaningful? |
|---|---|---|---|---|---|
| amount (bill) | page.tsx:134 (cell :66) | `electricity_allocations_masked`, page.tsx:46-48 | `bill_amount`; column `currency` exists (electricity_allocations.sql:32) but page renders all rows in current base (page.tsx:58,134) | `CASE WHEN has_permission('data.view_prices') THEN bill_amount ELSE NULL` (electricity_allocations_masked.sql:18-21); `MaskedValue canView={showPrices}` (page.tsx:58); `xMasked` (:77) | yes, but reversed bills included |
| runs | page.tsx:136 (cell :68) | same | `allocated_amount` / base | CASE view :32-35 | same |
| overhead | page.tsx:137 (cell :69) | same | `overhead_amount` / base | CASE view :36-39 | same |

- **NULL only ever means hidden:** all three NOT NULL in the table (electricity_allocations.sql:33,41-42). Masking is all-or-nothing per reader (`has_permission` not row-dependent) → restricted = `NOT has_permission('data.view_prices')` = page's `canViewPrices()` (page.tsx:42). Table CHECK `allocated_amount + overhead_amount = bill_amount` (electricity_allocations.sql:53).
- **Paging:** one read, unbounded (page.tsx:46-48); reversals read (:50) unbounded; expense-code `.in` unbatched (:56).
- **Filters:** none; reversed allocations stay, tagged only (page.tsx:54,65). Reversal is a separate row in `electricity_allocation_reversals` (electricity_allocation_reversals.sql:20-22), original keeps positive amount → a sum including them overstates.
- **Export:** client via CellsTable `exportSpec` (page.tsx:142).
- **RLS:** `has_any_permission(finance.view, processing.view)` (electricity_allocations.sql:78-80; view :53). Amount columns revoked from base table (electricity_allocations.sql:84-89) — totals must go through the masked view or a definer function.
- **Aggregates ON:** `electricity_allocations_masked?select=currency,bill_amount.sum(),allocated_amount.sum(),overhead_amount.sum(),count()`; a masked reader gets NULL sums (all-or-nothing, so not a smaller number); drive 受限 from `showPrices` or `count()` vs `bill_amount.count()`. No migration.
- **Aggregates OFF:** `electricity_allocation_totals()` → (currency, bill, runs, overhead, restricted). Migration.
- **Existing total:** none.

### /finance/expenses — 1 amount table, 1 amount column

| Column | Table file:line | Source + query | Amount / currency | Masking | Sum meaningful? |
|---|---|---|---|---|---|
| amount | ExpensesTable.tsx:63-77 | `expenses`, `expensePage` expenseRows.ts:93-105 | shows `amount_ccy` + **per-row** `currency` (ExpensesTable.tsx:66,69), plus `= amount_base` for foreign ccy (:70-73) | none; `amount_ccy`, `amount_base` NOT NULL (expenses.sql:27,30) | **dubious as is** |

- **Reversal double-count (verified):** `reverse_expense_internal` keeps the original as `reversed` and INSERTs a mirror with the **same positive** `amount_ccy`/`amount_base`, status default `posted`, notes `'REVERSAL: ' || code` (db/functions/reverse_expense_internal.sql:143-159; expenses.sql:10). A plain sum counts the reversed expense twice instead of netting to 0. `amount_ccy` is net of tax (expenses.sql:58).
- **Paging:** `?page=` 20 (page.tsx:32,80-86; expenseRows.ts:103).
- **Filters:** `applyExpenseFilters` (expenseRows.ts:75-82) from `parseExpenseListParams` (:37-45): `date_from` → `.gte('expense_date')` (:77), `date_to` → `.lte` (:78), `status` → `.eq('payment_status')` (:79), `account` → `.in('id', accountIds)` (:80).
- **JS-resolved account filter (hazard):** `resolveExpenseFilter` reads `expense_lines … .eq('account_code')` **unpaged** (expenseRows.ts:57) → cut at 1,000 lines, id list silently short; the id list goes into the URL as `.in('id', …)` (URL-length hazard, lib/export/serverRows.ts:77-78); builds a JS per-document line-sum map (:58-60). A DB total must do `EXISTS (SELECT 1 FROM expense_lines WHERE account_code = $a)` and in account mode sum **line** amounts.
- **Export:** app/finance/expenses/export/route.ts:9-20 shares `parseExpenseListParams`, `resolveExpenseFilter`, `expenseCount`, `expensePage`. A totals query can reuse `parseExpenseListParams` but should pass raw params to SQL, not reuse the JS id list.
- **RLS:** `expenses` and `expense_lines` `has_permission('module.finance.view')` (expenses.sql:252-255; expense_lines.sql:69-72). Nothing masked.
- **Aggregates ON:** `expenses?select=currency,amount_ccy.sum()` + same `.gte/.lte/.eq` — works without account filter; account mode still needs the function.
- **Aggregates OFF:** `expense_totals(p_date_from, p_date_to, p_payment_status, p_account)` → (currency, total_ccy, total_base, restricted=false). Migration.
- **Existing total:** see §6.

### /finance/freight — 1 amount table, 1 amount column

| Column | Table file:line | Source + query | Amount / currency | Masking | Sum meaningful? |
|---|---|---|---|---|---|
| amount | FreightTable.tsx:52-56 | `freight_documents`, `freightPage` freightRows.ts:55-66 | `amount_base` / base (freightRows.ts:69,76); table also has `amount_ccy` + `currency` (freight_documents.sql:20-21), not shown | none; NOT NULL (:23) | yes, but reversed documents included |

- **Reversed docs** keep status `reversed` with positive amount, no mirror (freight_documents.sql:31; reverse_freight_document.sql:60 is an UPDATE); listed struck through (FreightTable.tsx:70) → plain sum overstates.
- **Paging:** cap 200 `FREIGHT_SHOWN` (freightRows.ts:18; page.tsx:30) + RowCapNotice (page.tsx:49); head count (freightRows.ts:51-53).
- **Filters:** none from URL; fixed `.is('deleted_at', null)` (:52,61) must be in the total.
- **Export:** app/finance/freight/export/route.ts:10-22 shares `freightCount`/`freightPage`/`shapeFreightRows`.
- **RLS:** `has_permission('module.inbound.view') OR has_permission('module.finance.view')` (freight_documents.sql:94-96).
- **Aggregates ON:** `freight_documents?select=amount_base.sum()&deleted_at=is.null` (opt. `&status=eq.posted`). No migration. **OFF:** `freight_document_totals()`. Migration. Restricted always false.
- **Existing total:** none.

### /finance/invoices — 1 amount table, 3 amount columns

| Column | Table file:line | Source + query | Amount / currency | Masking | Sum meaningful? |
|---|---|---|---|---|---|
| total | InvoicesTable.tsx:110-115 | view `invoice_status` (invoiceRows.ts:90; view reads `FROM invoices_masked i`, invoice_status.sql:44); void branch reads `invoices_masked` (invoiceRows.ts:113-115) | `total_base` / one base ccy (`getBaseCurrency`, invoiceRows.ts:155); `currency` column exists (invoice_status.sql:30) but every amount shown is `_base` | NULL via invoices_masked.sql:33-36 `WHEN has_permission('data.view_prices') THEN total_base ELSE NULL`; 受限 via MaskedValue/xMasked (Table :113-114) | yes (billed); **no** if void rows mixed in (status=all) |
| settled | :116-120 | invoice_status.sql:32 — Σ payment_allocations ⨝ posted payments (:46-54) | `settled_base` / base | **not masked** (view :32; Table renders plain, :118) | yes |
| open | :121-127 | invoice_status.sql:33 = total − settled − credited | `open_base` / base | inherits NULL from total_base → 受限 (Table :125); NULL **legitimately** on void rows (`—`, `isVoid` tells apart, Table :124; invoiceRows.ts:131-132) | yes |

- **Paging:** `?page=` 20, count + `.range` (page.tsx:26,60-68; invoiceRows.ts:93).
- **Filters:** `date_from`/`date_to` → `.gte/.lte('issue_date')` (invoiceRows.ts:73-74, private `applyDates` :71); `state` → `.eq('overdue', true)` or `.eq('payment_state', …)` (:79-80, private `applyState` :77); `status`: `issued` = invoice_status (itself `WHERE status<>'void'`, invoice_status.sql:56), `void` → `invoices_masked .eq('status','void')` (invoiceRows.ts:104,115).
- **JS-side merge (hazard, verified page.tsx:70-75):** with `status=all` the page appends **all** void rows (`fetchAllPages`) after every issued page slice and adds their count to `total` — voids repeat on every page; `totalPages` comes from the issued count only (page.tsx:66). The export does a clean union (export/route.ts:26). A DB total must follow the export, not the page.
- **Masked-reader filter hazard:** without view_prices `total_base` is NULL, so `payment_state` can never be `paid` (invoice_status.sql:36: NULL ≤ 0 → CASE falls through) and `overdue` is NULL (:40). `state=paid` / `state=overdue` return 0 rows for that reader; a fully-paid invoice shows `partial`. The *settled* total (unmasked) would then be over a wrongly filtered set.
- **Export:** export/route.ts:14-27 uses `parseInvoiceListParams` (invoiceRows.ts:48), `issuedCount/issuedPage/voidCount/voidPage` (:85-139).
- **RLS:** `invoices` `has_permission('module.finance.view')` (invoices.sql:149-152), all-or-nothing; amount columns column-REVOKEd (invoices.sql:163-168); views owner-rights + same predicate (invoice_status.sql:56; invoices_masked.sql:54). No per-row drop.
- **Aggregates ON:** same chain on invoice_status `select=total_base.sum(),settled_base.sum(),open_base.sum(),count(),total_base.count()`; restricted when `count() > total_base.count()` (valid: base `total_base` NOT NULL, invoices.sql:38). Mask is permission-wide → `restricted ⇔ count>0 ∧ ¬data.view_prices`. No migration.
- **Aggregates OFF:** invoker `invoice_list_totals(p_from, p_to, p_state, p_status)` → (currency, total, settled, open, restricted = bool_or(total_base IS NULL)). Migration.
- **Existing total:** none.

### /finance/journal — 1 amount table, 1 amount column (requests panel is not a DataTable — out of scope)

| Column | Table file:line | Source + query | Amount / currency | Masking | Sum meaningful? |
|---|---|---|---|---|---|
| amount (Σ debits of the entry) | JournalTable.tsx:66-74 | rows `journal_entries` (journalRows.ts:64); amount **computed in JS** from `journal_lines_masked` (debit, amounts_restricted), `.in` batches (:94-103) | `debit` / base (header, Table :67) | **per row:** journal_lines_masked.sql:19 `WHEN has_permission('data.view_pay') OR e.source_type IS DISTINCT FROM 'payroll' THEN l.debit ELSE NULL` + `amounts_restricted` (:40); JS nulls an entry with any restricted line (journalRows.ts:101,115); 受限 via MaskedValue (Table :69-72). Base debit NOT NULL DEFAULT 0 (journal_lines.sql:17) → NULL only means hidden | **dubious** |

- **Paging:** `?page=` 20 (page.tsx:27,57-65; journalRows.ts:69).
- **Filters:** `date_from`/`date_to` → `.gte/.lte('entry_date')` (journalRows.ts:48-49, private `applyFilters` :46). No status filter. JS: per-entry sum, nothing dropped.
- **Export:** entries/export/route.ts:16-22 uses `parseJournalListParams` (journalRows.ts:36), `journalCount/journalPage/shapeJournalRows`. ./export/route.ts is the separate GL export.
- **RLS silent-drop trap (verified):** `journal_lines` has a RESTRICTIVE policy dropping payroll lines for readers without `data.view_pay` (db/tables/journal_lines.sql:106-111). A total read from base `journal_lines` would be silently smaller and could never show 受限 — must read `journal_lines_masked` or a DEFINER function (precedent: trial_balance_totals.sql header).
- **Sum meaning:** one row = one balanced entry (Σ debits = Σ credits). Σ = gross turnover (total debits), not a balance. A reversal posts an equal **positive** posted entry and flips the original to `reversed` (AGENTS.md:1334-1340); both listed → a reversed entry counts 2×.
- **Aggregates ON:** `journal_lines_masked?select=debit.sum(),debit.count(),count(),journal_entries!inner()&journal_entries.entry_date=gte…` — relies on PostgREST inferring view→table relationship (unverified). Restricted when `count() > debit.count()`.
- **Aggregates OFF:** `journal_list_totals(p_from, p_to)` → (total_debits, restricted). Migration.
- **Existing total:** none.

### /finance/payment-requests — 1 amount table, 1 amount column

| Column | Table file:line | Source + query | Amount / currency | Masking | Sum meaningful? |
|---|---|---|---|---|---|
| amount | PaymentRequestsTable.tsx:58-64 | `payment_requests` (requestRows.ts:66-68) | `amount_ccy` / **per-row** `currency`; `amount_base` (payment_requests.sql:63) is a submit-time estimate (:157-158), not selected | none | **dubious** |

- **Paging:** `?page=` 20 (page.tsx:20,45-50; requestRows.ts:73).
- **Filters:** `status` → `.in('status', set)` (`open` = submitted+approved; `all` none; else one status) (requestRows.ts:27-29,45-48; private `applyFilters` :45). No JS filtering.
- **Export:** export/route.ts:13-21 uses `parseRequestFilter` (requestRows.ts:24), `requestCount/requestPage`.
- **RLS:** finance.view all-or-nothing (payment_requests.sql:190-192). Never restricted.
- **Sum meaning:** `kind` has 6 values (payment_requests.sql:50): payment_out, payment_reversal (of a receipt or a payout), bank_transfer (internal move), wht_remittance and reversals; all amounts positive (:60). An unsigned sum mixes cash out, reversals and internal transfers.
- **Aggregates ON:** `select=currency,kind,amount_ccy.sum()` + same filter. No migration. **OFF:** `payment_request_totals(p_statuses text[])`. Migration.
- **Existing total:** none.

### /finance/payments — 1 amount table, 1 amount column

| Column | Table file:line | Source + query | Amount / currency | Masking | Sum meaningful? |
|---|---|---|---|---|---|
| amount | PaymentsTable.tsx:62-76 (base equivalent :69-73) | `payments` (paymentRows.ts:66-67) | `amount_ccy` / **per-row** `currency`; also `amount_base` | none | **no as an unsigned sum** |

- **Paging:** `?page=` 20 (page.tsx:20,48-55; paymentRows.ts:72).
- **Filters:** `date_from`/`date_to` → `.gte/.lte('payment_date')`; `direction` → `.eq('direction')` (paymentRows.ts:52-54; private `applyFilters` :50). No JS filtering.
- **Export:** export/route.ts:14-20 uses `parsePaymentListParams` (paymentRows.ts:31), `paymentCount/paymentPage`.
- **RLS:** finance.view (payments.sql:111-114). Never restricted.
- **Sum meaning (verified):** in and out mixed, all positive (payments.sql:15,28). A reversal INSERTs a mirror with the **same direction and positive amount**, status default `posted` (db/functions/reverse_payment_internal.sql:54-63), and flips the original to `reversed` (:67-68). Σ all rows counts a reversed payment 2×; Σ posted keeps the mirror as a payment. Mirror identifiable only via another row's `reversed_by_payment` (payments.sql:37) or the `REVERSAL:` notes prefix.
- **Aggregates ON:** `select=currency,direction,amount_ccy.sum(),amount_base.sum()` — cannot net reversal pairs (needs self-join).
- **Correct option (migration):** `payment_list_totals(p_from, p_to, p_direction)` → (currency, in_total, out_total, restricted=false), excluding reversed originals and their mirrors (or signing mirrors negative).
- **Existing total:** none.

### /finance/self-approved — 1 amount table, 1 amount column

| Column | Table file:line | Source + query | Amount / currency | Masking | Sum meaningful? |
|---|---|---|---|---|---|
| amount | SelfApprovedTable.tsx:53-55 | RPC `self_approved_decisions()` (page.tsx:57; db/functions/self_approved_decisions.sql:31-69) | `amount_ccy` / **per-row** `currency` (RPC also returns `amount_base`, :32,50, unused) | **per row:** self_approved_decisions.sql:48 `CASE WHEN approval_log_amount_visible(a.subject_type, a.subject_id) THEN a.amount_ccy END` (medical_claim: view_health or claimant). RPC returns **no restricted flag** — JS rebuilds it: `amount_ccy===null && subject_type='medical_claim' && !hasHealth && not self` (page.tsx:64-68,83) → `<Refusal>`/xRestricted. **Legitimate NULL:** leave_request rows (amount and currency both NULL, approval_log.sql:171-173,182-183). `currency` never masked (:49) | **dubious** |

- **Paging:** one RPC read, no limit; max_rows 1000 applies to RPC TABLE results too (journal/export/route.ts:76-77) — **silent truncation**, while client sort claims `coverage:'complete'` (Table :68).
- **Filters:** none (RPC `WHERE a.self_decided`, :66). JS map drops nothing (page.tsx:70-89).
- **Export:** client `exportSpec`, no serverRows (Table :66) → ≤1000 rows.
- **RLS:** n/a — SECURITY DEFINER + `require_permission('data.view_self_approvals')` RAISE (:34,38); approval_log amount columns REVOKEd (approval_log.sql:300) → any total must be DEFINER.
- **Sum meaning:** one row = one decision, not one claim; approved and rejected mixed (approval_log.sql:312); `level` 1 or 2 (:144) — one claim may appear twice (unverified); leave rows have no amount.
- **Aggregates:** do not apply to an RPC; and count(*) vs count(amount) fails here (leave rows legitimately NULL). **Migration needed either way:** DEFINER `self_approved_totals()` → (currency, total, restricted), same `require_permission`, `sum(amount_ccy) FILTER (WHERE decision='approved')`, `restricted = bool_or(NOT approval_log_amount_visible(subject_type, subject_id))` per currency (restricted medical rows keep their currency).
- **Existing total:** none.

### /finance/supplier-statements — 1 amount table, 1 amount column

| Column | Table file:line | Source + query | Amount / currency | Masking | Sum meaningful? |
|---|---|---|---|---|---|
| closing (期末余额) | StatementsTable.tsx:31 | view `supplier_statement_rows` (statementRows.ts:56-57) | `closing_base` / per-row `base_currency` (view :16,18; table :26,32 — frozen at issue) | none; NOT NULL (table :32); row predicate `has_permission('module.finance.view')` (view :35) = page gate (page.tsx:4; lib/modules.ts:620) | **No** — one row = one statement's closing balance at its own period_end; a supplier has many statements over time (index supplier_id, period_end DESC, table :60); superseded statements stay listed, greyed (StatementsTable.tsx:37; table :43-47). Summing double-counts |

- **Paging:** cap 300 `STATEMENTS_SHOWN` (statementRows.ts:18), `.range` :60, page.tsx:26, RowCapNotice page.tsx:40; count unfiltered (statementRows.ts:49-51).
- **Filters:** none (statementRows.ts:39 "这一页没有筛选"); `shapeStatementRows` maps only (:64-78).
- **Export:** export/route.ts:15-21 reuses `parseSupplierStatementListParams` (:35), `statementCount` (:49), `statementPage` (:53).
- **RLS:** finance.view (table :76-78). No drop.
- **Proposal:** no footer. Aggregates ON would be `supplier_statement_rows?select=base_currency,closing_base.sum()`; OFF a view/function (migration). Restricted always false. Only conceivable alternative: Σ closing of the latest non-superseded statement per supplier (`superseded_at IS NULL` + DISTINCT ON supplier_id) — still adds balances at different dates.
- **Existing total:** none.

### /finance/wht — 2 amount tables (3rd table = rates, no amount), 4 amount columns

| Column | Table file:line | Source + query | Amount / currency | Masking | Sum meaningful? |
|---|---|---|---|---|---|
| withheld | WhtTables.tsx:37-41 | view `wht_liability_by_month` (page.tsx:48-50) | `withheld_base` / base (`getBaseCurrency`, page.tsx:42,116) | none; owner-rights view, predicate finance.view (view :63) = gate (page.tsx:36) | yes — all-time Σ withheld (one row per month, view :43-56) |
| remitted | :42-46 | same | `remitted_base` (posted only, view :36-41) | none | yes |
| unremitted | :47-51 | same | `unremitted_base` | none | **yes, an invariant:** Σ unremitted ≡ balance of account 2150 (view :18-21) |
| remittance `amount` | :99-103 | table `wht_remittances` (page.tsx:51-53) | `amount_base` / base | none; RLS finance.view (wht_remittances.sql:67-70) | **dubious** — register lists reversed remittances; `reversed` derived **in JS** from `journal_entries.status !== 'posted'` (page.tsx:86-97,127); Σ posted = Σ remitted_base above |
| (rates table) | :141-156 | wht_natures + wht_rates | `rate_pct` — a rate | n/a | not an amount |

- **Paging:** one read each, no limit (page.tsx:48-53); client sort `complete` (WhtTables.tsx:72,126). Liability ≈ one row/month; remittances unbounded and growing.
- **Filters:** none. JS: `owing` (page.tsx:105-106) feeds only a dropdown; remittance `reversed` merged from a second read (page.tsx:92-97) — a DB total must join `journal_entries` status='posted' (as view :39-40).
- **Export:** client only (WhtTables.tsx:70,124).
- **Aggregates ON:** `wht_liability_by_month?select=withheld_base.sum(),remitted_base.sum(),unremitted_base.sum()`. **OFF:** view `wht_liability_totals` (migration). Remittances: a join-aware function/view (migration) — or simply show the posted total from the liability sum. Restricted always false; single base currency.
- **Existing total:** none.

### /hr/claims — 1 amount table, 1 amount column

| Column | Table file:line | Source + query | Amount / currency | Masking | Sum meaningful? |
|---|---|---|---|---|---|
| amount | ClaimsTable.tsx:63-69 | view `medical_claim_status` `select('*')` (claimsRows.ts:73) | `amount_sgd` / fixed 'SGD' hard-coded (cell :68, export :67); no currency column (view comment :13) | **per row (verified):** `CASE WHEN has_permission('data.view_health') OR mc.employee_id = current_user_employee() THEN mc.amount_sgd ELSE NULL` (db/views/medical_claim_status.sql:27-30). Without view_health a reader sees own claims, others NULL. Base NOT NULL CHECK > 0 (medical_claims.sql:13) → NULL always = hidden. 受限 via Refusal (:68), xMasked (:67) | mostly; **dubious across statuses** — rejected/withdrawn are rows (page.tsx:62) |

- **Paging:** cap 300 `CLAIMS_SHOWN` (claimsRows.ts:28), `.range` :74, page.tsx:37, RowCapNotice page.tsx:80.
- **Filters (all DB):** private `filtered()` (claimsRows.ts:60-65) from `claimsFilterFrom` (:35-42): `employee` → `.eq('employee_id')`, `year` → `.eq('claim_year')`, `status` → `.eq('settlement_state')`. No JS filtering. Side note: `awaiting_payment_run` (view :51) missing from the status dropdown (page.tsx:62).
- **Export:** export/route.ts:15-20 reuses `claimsFilterFrom`, `claimsCount`, `claimsPage`.
- **RLS:** view owner-rights (:19), predicate `module.hr.view OR own` (:67) = gate MOD.hr (page.tsx:26; modules.ts:142). No drop.
- **Aggregates ON:** `medical_claim_status?select=amount_sgd.sum(),claim_id.count(),amount_sgd.count()` + same `.eq`s; `restricted = count(claim_id) <> count(amount_sgd)`. Never the bare sum. No migration.
- **Aggregates OFF:** `medical_claim_totals(p_employee, p_year, p_status)` → ('SGD', total, restricted), invoker over the view. Migration.
- **Existing total:** none.

### /hr/payroll — 1 amount table, 2 amount columns

| Column | Table file:line | Source + query | Amount / currency | Masking | Sum meaningful? |
|---|---|---|---|---|---|
| gross | PayrollPeriodsTable.tsx:61-67 | view `payroll_periods_masked` (page.tsx:33-37) | `gross_total` / per-row `currency` (page.tsx:35; table :22 DEFAULT 'SGD') | **whole column:** `CASE WHEN has_permission('data.view_pay') THEN gross_total ELSE NULL` (payroll_periods_masked.sql:15-18), no own-row exception (:3); base NOT NULL DEFAULT 0 (table :25) → NULL = hidden; MaskedValue (:66) | **dubious** — one row = one month's payroll total (unique live per month, table :63-64); Σ = all-time payroll (no year filter); includes `draft` periods (table :24) |
| net | :68-74 | same | `net_pay_total` / `currency` | same CASE (view :31-34); NOT NULL (table :29) | same |

- **Paging:** one read, no limit (page.tsx:33-37); client sort (:131). Side hazard: `payroll_lines` read unbounded (page.tsx:38) → head-count column wrong past 1,000 lines (not an amount).
- **Filters:** `.is('deleted_at', null)` only (page.tsx:36). JS maps only (:76-97).
- **Export:** client (PayrollPeriodsTable.tsx:132).
- **RLS:** view predicate hr.view (view :48) = gate (page.tsx:24).
- **Aggregates ON:** `payroll_periods_masked?select=currency,gross_total.sum(),net_pay_total.sum(),id.count(),gross_total.count()&deleted_at=is.null`; restricted when counts differ (= `NOT data.view_pay`). **OFF:** view/function grouped by currency (migration).
- **Existing total:** none (record count only, page.tsx:110).

### /inventory — 1 amount table, 4 money columns (3 summable; avgPrice is a price)

| Column | Table file:line | Source + query | Amount / currency | Masking | Sum meaningful? |
|---|---|---|---|---|---|
| avgPrice | InventoryTable.tsx:88-93 | JS stockValue / pricedQty (page.tsx:479-482,490) | price, base | null when restricted — row shows '—' not 受限 (page.tsx:480-482); export xMasked (:92) | **never sum** |
| stockValue | :94-99 | JS Σ remaining_qty × landed_unit_cost per material (page.tsx:281-292) from `inbound_batch_valuation` (:137-140) | base (`getBaseCurrency`, page.tsx:80) | `CASE WHEN v_prices THEN inbound_batch_landed_unit_cost(ib.id) ELSE NULL` (inbound_batch_valuation_rows.sql:22-23); legitimate NULL (no cost) told apart by unmasked `unpriced` (:29); row '—' (page.tsx:483-484) | yes |
| costValue | :111-115 | JS Σ remaining_qty × unit_cost_base (page.tsx:293-300) from `output_batch_lookup` (:149-153) + `processing_output_lookup` (:162-164) | base | `CASE WHEN has_permission('data.view_prices') THEN unit_cost_base` (processing_output_lookup.sql:13-16); also legitimately NULL before allocation (processing_outputs.sql:17); page folds both (`legCostByBatch` skips both, page.tsx:234) | yes |
| marketValue | :116-123 | JS Σ qty × marketValuePerKg (page.tsx:301-304; lib/valuation.ts:100-113) from `output_batch_metal_lookup` (:166-168) + `metal_prices` (:172-176) + `pricing_settings` (:171) | **USD** hard-coded | not masked (InventoryTable.tsx:40) | yes, separate from base totals |

- **Paging:** none — seven unpaged reads without ORDER BY (inbound_batch_valuation :137-140; output_batch_lookup :149-153; processing_output_lookup :162-164 — all legs incl. sold-out, hits 1,000 first; output_batch_metal_lookup :166-168 every batch × metal; metal_prices :172-176 full history, latest picked in JS valuation.ts:86-95; material_lookup :185-190; processing_balance_monthly :157-160). Past 1,000 the subset is arbitrary.
- **JS-side aggregation (main hazard):** one row per material built by merging inbound + output batches (page.tsx:249-307); units merged into ⚠️混合 (:258-260); market value assumes kg (:303; valuation.ts:98-110); partly-priced metal set silently counts only priced metals (valuation.ts:107-108); inbound batches of a deleted material still counted (name lookup filters deleted_at :190, the valuation function doesn't, inbound_batch_valuation_rows.sql:32-33); JS math unrounded vs DB per-batch rounding (inbound_batch_valuation_rows.sql:24-25; output_batch_valuation.sql:14-17) → cents differ. JS sort by name (:310). No filters.
- **Export:** client (InventoryTable.tsx:136).
- **RLS:** gate inventory.view (page.tsx:72; modules.ts:137); all row predicates include inventory.view (output_batch_lookup :20, processing_output_lookup :18, output_batch_metal_lookup :12, material_lookup :29, metal_prices :109); inbound function `require_permission` (:15). No drop.
- **Existing DB building blocks:** `output_batch_valuation` has `cost_value_base` + unmasked `never_costed` (output_batch_valuation.sql:9-18); `inventory_valuation_snapshot()` (DEFINER, jsonb) returns `produced.costed_value_base`, NULL + named `restriction` when hidden, per-location `value_base` (inventory_valuation_snapshot.sql:63-157), used by /inventory/reports/snapshot (snapshotQuery.ts:67) — but by_location sums `inventory_movements` and filters `mt.deleted_at` (:93), so not the same set as this page.
- **Aggregates ON:** stock `inbound_batch_valuation?select=landed_value_base.sum(),id.count(),landed_value_base.count()&remaining_qty=gt.0`; cost: `output_batch_valuation` with `never_costed=is.false` and count(*) vs count(cost_value_base). Market value **cannot** be expressed (latest price per metal × content % × kg).
- **Either way recommended:** new function `inventory_valuation_totals()` → (measure, currency, total, restricted, + counts unpriced/never-costed/partly-priced). Migration. Must state its batch set explicitly (deleted-material rule, kg rule).
- **Existing total:** the valuation bar — see §6.

### /logistics/forwarders — 1 amount table, 1 amount column

| Column | Table file:line | Source + query | Amount / currency | Masking | Sum meaningful? |
|---|---|---|---|---|---|
| owed (未结应付) | ForwardersTable.tsx:72-84 | `ap_open_items` `.select('counterparty_id, open_base, currency').in('counterparty_id', ids)` (page.tsx:83-88) | `open_base` **summed in JS** per forwarder (page.tsx:90-94); one base ccy from `currencies.is_base` (page.tsx:95-99); per-doc `currency` read but ignored | all-or-nothing: view `WHERE … has_permission('module.finance.view')` (db/views/ap_open_items.sql:178) → 0 rows; page checks `can('module.finance.view')` first (page.tsx:82) and the Table draws 受限 (ForwardersTable.tsx:77-82) | yes, one base currency — total owed to forwarders |

- **Paging:** none. `supplier_lookup` one read (page.tsx:36-44); `ap_open_items` one read (:85) → past 1,000 open documents the per-row owed is already too small today.
- **Filters:** none from URL; `counterparty_type='forwarder'`, `deleted_at IS NULL` (page.tsx:40-41). JS: owed aggregated in JS; zero/falsy → null → 「没有欠款」 (:108,110).
- **Export:** client only (ForwardersTable.tsx:90).
- **Silent row drop inside the view (flag, verified):** `ap_open_items` reads `inbound_batches_masked ib` (ap_open_items.sql:110) and keeps only `ib.unit_price IS NOT NULL` (:119); `unit_price` is masked by `CASE WHEN has_permission('data.view_purchase_prices') …` (inbound_batches_masked.sql:44). So a finance reader **without** `data.view_purchase_prices` silently loses every inbound open item. Prepayment amounts are masked to NULL (prepayment_applications_masked.sql:20-23,30-33) then `COALESCE(…,0)` (ap_open_items.sql:101-102,116-118,149-151) → owed for those rows reads **too high**. Forwarders mostly have freight rows (:156-177), which are unmasked. Neither count(*) vs count(amount) nor `canMoney` detects this; a restricted flag needs `has_permission('data.view_purchase_prices')` too.
- **Aggregates ON:** `ap_open_items?select=open_base.sum()&counterparty_id=in.(ids)` (ids from the same `supplier_lookup` read; long id list → URL length); restricted = `!can('module.finance.view')` + purchase-prices check (a no-finance reader gets 0 rows → sum NULL, indistinguishable from 0 without `can()`).
- **Aggregates OFF:** `forwarder_owed_totals()` → (base currency, total, restricted), over `ap_open_items` ⨝ `suppliers` (forwarder, not deleted). Migration.
- **Existing total:** none.

### /me — 10 DataTables + 1 EditableTable; 3 amount tables, 7 amount columns

DataTables: attendance (MyAttendancePanel.tsx:73), medical claims (MyClaimsPanel.tsx:137), expense claims (MyExpenseClaimsPanel.tsx:335), leave ×3 (MyLeavePanel.tsx:215,230,252), overtime (MyOvertimePanel.tsx:46), payslips (MyPayslipsTable.tsx:95), review goals (MyReviewsPanel.tsx:132), training (MyTrainingTable.tsx:66). Money only on payslips, medical, expense. (Review `new_monthly_salary` is drawn outside a table, MyReviewsPanel.tsx:155-160.)

| Table / column | Table file:line | Source + query | Amount / currency | Masking | Sum meaningful? |
|---|---|---|---|---|---|
| payslips: gross, employer CPF, employee CPF, deductions, net (5) | MyPayslipsTable.tsx:71-91 | `payroll_lines_masked` `.eq('employee_id', employeeId)` (page.tsx:146-149) | `gross_pay`/`employer_cpf`/`employee_cpf`/`other_deductions`/`net_pay`; currency per period, joined **in JS** from RPC `my_period_labels()` (page.tsx:239-241,330; my_period_labels.sql:29) | `CASE WHEN has_permission('data.view_pay') OR employee_id = current_user_employee() THEN …` (payroll_lines_masked.sql:14,18-30); own rows never masked; NOT NULL (payroll_lines.sql:26-30) | **dubious** — one row = one period's payslip (UNIQUE period+employee, payroll_lines.sql:33); lifetime Σ; drafts included (no status filter page.tsx:146-149; status payroll_periods.sql:24); soft-deleted draft periods counted (`my_period_labels` has no deleted_at filter, :29-32); employer CPF is not the employee's money |
| medical claims: amount | MyClaimsPanel.tsx:58-62 | `medical_claim_status` `.eq('employee_id')` (meRows.ts:71-77) | `amount_sgd`, SGD hard-coded (MyClaimsPanel.tsx:60-61) | same CASE as /hr/claims (medical_claim_status.sql:27-30); own rows never masked | **dubious** — all statuses incl. rejected/withdrawn (medical_claims.sql:16-18); existing balance uses approved+paid, current year (medical_claim_balance.sql:81) |
| expense claims: amount | MyExpenseClaimsPanel.tsx:177-192 | `expense_claim_status` `.eq('employee_id')` (meRows.ts:83-89) | `amount_ccy` + per-row `currency` (expense_claim_status.sql:65-66) | none; row predicate `finance.view OR own` (:90) | **dubious** — includes withdrawn/rejected (expense_claims.sql:28-29) |

- **Paging:** payslips one read (≈12 rows/yr). Medical and expense **cap 50** `MY_LIST_SHOWN` (meRows.ts:42; page.tsx:174,181) + RowCapNotice (MyClaimsPanel.tsx:136; MyExpenseClaimsPanel.tsx:334) + exact count (meRows.ts:68-70,80-82).
- **Filters:** `employee_id` only (+ `deleted_at` for leave); sort params only (meRows.ts:29-34). JS: payslip currency join (page.tsx:330); expense items attached, header amounts unaffected (meRows.ts:98-114).
- **Own rows:** RLS + `.eq` both apply (payroll_lines.sql:85-87 + page.tsx:149; medical view :67 + meRows.ts:73; expense view :90 + meRows.ts:85). No own row is ever dropped or masked → **restricted can never fire on /me**.
- **Export:** medical app/me/medical-claims/export/route.ts:9,20-21 (`myMedicalCount`/`myMedicalPage`); expense app/me/expense-claims/export/route.ts:9,20-21 (`myExpenseCount`/`myExpensePage`); payslips client (MyPayslipsTable.tsx:103).
- **Aggregates ON:** medical `medical_claim_status?select=amount_sgd.sum(),count()&employee_id=eq.X`; expense `expense_claim_status?select=currency,amount_ccy.sum()&employee_id=eq.X`. Payslips **cannot**: currency lives on `payroll_periods` (hr.view-only per my_period_labels.sql:36) → owner-rights function needed.
- **Aggregates OFF:** `my_medical_claim_totals()`, `my_expense_claim_totals()`, `my_payslip_totals()` (currency, gross, employer_cpf, employee_cpf, deductions, net, restricted). Migration (payslips need it either way).
- **Existing total:** medical balance box `claimed_sgd`/`remaining_sgd` from RPC `medical_claim_balance` (page.tsx:176-178; MyClaimsPanel.tsx:115-123) — approved+paid, current year; will not equal an all-status footer.

### /purchasing/orders — 1 amount table, 4 amount columns

| Column | Table file:line | Source + query | Amount / currency | Masking | Sum meaningful? |
|---|---|---|---|---|---|
| net | OrdersTable.tsx:93-97 | `purchase_order_status` (orderRows.ts:154-156) or `purchase_orders_masked` when status=cancelled (:122-126) | `estimated_total_ccy` / per-row `currency` | `CASE WHEN has_permission('data.view_purchase_prices') THEN estimated_total_ccy` (purchase_orders_masked.sql:28-31), read by status view (purchase_order_status.sql:35,64); whole reader; `MaskedValue canView={canPurchasePrices}` (OrdersTable.tsx:95) | yes per currency (an estimate: qty × estimated price, purchase_orders.sql:9) |
| tax | :101-104 | same | `tax_total_ccy`; JS null when `!carries_tax` (orderRows.ts:192) | purchase_orders_masked.sql:59-62 | **dubious** — untaxed orders show 「—」 (orderRows.ts:68-69); NULL legitimately → count trick must not be used on tax |
| gross | :105-110 | same | JS `carries_tax ? gross_total_ccy : estimated_total_ccy` (orderRows.ts:190); DB `estimated + COALESCE(tax,0)` (purchase_order_status.sql:62; purchase_orders_masked.sql:68-70) — same number, so `sum(gross_total_ccy)` = screen | purchase_orders_masked.sql:68-70 | yes per currency |
| prepaid | :111-129 | `purchase_order_status` only; cancelled rows null in JS (orderRows.ts:145-147) | `prepaid_base` / base (orderRows.ts:186-187,209); ⚠ `prepaid_remaining_base` badge in the same cell | `CASE WHEN has_permission('module.finance.view') THEN round(COALESCE(pre.prepaid,0),2)` (purchase_order_status.sql:36-38); `MaskedValue canView={canFinance}` (OrdersTable.tsx:117) | yes, base; null in cancelled branch = n/a |

- **Paging:** `?page=` 20 (page.tsx:27,52-59; orderRows.ts:131,161), exact count (:97-106).
- **Filters:** `parsePoListParams` (orderRows.ts:48-57): `date_from` → `.gte('order_date')` (:86), `date_to` → `.lte` (:87), `supplier` → `.eq('supplier_id')` (:88), `status` → `.eq('status')` (:93); no status → view excludes cancelled (purchase_order_status.sql:80); `status=cancelled` switches relation (orderRows.ts:117-151) and its count reads base `purchase_orders` (:98-103). No JS row filtering.
- **Export:** app/purchasing/orders/export/route.ts:11,15,19-21 reuses `parsePoListParams`/`poCount`/`poPage`/`shapePoRows`; `applyFilters`/`applyStatus` (orderRows.ts:84-95) private.
- **RLS:** `has_permission('module.purchasing.view')` (purchase_orders.sql:129-132) = gate (page.tsx:41; modules.ts:108). No drop; masking all-or-nothing per reader.
- **Aggregates ON:** `purchase_order_status?select=currency,estimated_total_ccy.sum(),tax_total_ccy.sum(),gross_total_ccy.sum(),count(),estimated_total_ccy.count()` + filters; prepaid `prepaid_base.sum()` separately (base); cancelled branch same on `purchase_orders_masked`. Restricted: count(*) ≠ count(estimated_total_ccy) (base NOT NULL, purchase_orders.sql:35) or `canViewPurchasePrices()` (orderRows.ts:185); prepaid `canFinance` (:181). No migration.
- **Aggregates OFF:** invoker `purchase_order_totals(p_date_from, p_date_to, p_supplier, p_status)` → (currency, net, tax, gross, restricted) + a base prepaid row. Migration.
- **Existing total:** record count only (page.tsx:116).

### /sales/commissions — 1 amount table, 1 mixed column (rate or amount)

| Column | Table file:line | Source + query | Amount / currency | Masking | Sum meaningful? |
|---|---|---|---|---|---|
| 费率 — shows `rate_pct` OR `amount_ccy` | CommissionsTable.tsx:69-87 | `commission_agreements` `.is('deleted_at', null).order('valid_from')` (page.tsx:47-53) | `amount_ccy` + per-row `currency` | none (base table read directly, page.tsx:49). Discriminator `basis`, CHECK (db/tables/commission_agreements.sql:62-67, verified): `percentage_of_value` → `rate_pct`, amount NULL; `per_tonne`/`fixed_amount` → `amount_ccy` + `currency` NOT NULL. A NULL amount is always a rate row, never hidden | **No / dubious** — `per_tonne` amounts are a price per tonne (label 「按吨」, messages/zh.ts:2296): summing adds up rates; mixing with `fixed_amount` adds unlike things; `fixed_amount` says nothing about "per what" (:90-91); agreements link to no transaction (:31-32,87-88; no accrual :16-18); expired agreements included (no `valid_to` filter, page.tsx:51) |

- **Paging:** one read, no limit (page.tsx:47-53).
- **Filters:** `deleted_at IS NULL` only; JS flattening only (page.tsx:57-65).
- **Export:** client (CommissionsTable.tsx:102).
- **RLS:** `has_permission('module.suppliers.view')` (commission_agreements.sql:107-109) = gate (page.tsx:41; modules.ts:107). Never restricted.
- **Aggregates ON:** `commission_agreements?select=currency,amount_ccy.sum()&deleted_at=is.null&basis=in.(per_tonne,fixed_amount)` (or `basis=eq.fixed_amount`). **OFF:** `commission_amount_totals()`. Migration.
- **Existing total:** none. Side note: a per-tonne amount is shown as plain money with no "/t" (CommissionsTable.tsx:84-85).


## 6. Existing totals today — do they satisfy the ruling?

**/finance/expenses summary line "N 笔 · total".** Count N = exact head count with the same filter (expenses/page.tsx:68; expenseRows.ts:89-91) — correct beyond 1,000. Total = a second read `applyExpenseFilters(supabase.from('expenses').select('id, amount_base'), filter)` with **no `.range`/`.limit`** (expenses/page.tsx:69), summed in JS by `reduce` and rounded after (:73-79); in account mode it sums `accountLineBase.get(id)` from the unpaged lines read (expenseRows.ts:54-60). Rendered at expenses/page.tsx:136-139 in `baseCurrency` (variable still named `totalUsd`, :73). **Does not satisfy:** JS not DB; READ-ALL-STOPS-AT-1000 (past 1,000 matching rows the total covers an arbitrary 1,000 while N shows all); one base-currency figure, not one per currency; counts each reversed expense twice (original + positive mirror, reverse_expense_internal.sql:143-159); cannot show 受限 (nothing on the page is masked, so this last point is moot).

**/inventory valuation bar.** `pricesRestricted = inbound.some(b => !b.unpriced && b.landed_unit_cost === null)` (inventory/page.tsx:325); totals = JS `reduce` over the merged material rows (:326-328); rendered :418-462, base totals 受限 when `pricesRestricted` (:423,431), USD market value printed separately, never 受限 (:450-456). **Does not satisfy:** JS over seven unpaged reads that silently stop at 1,000 (no ORDER BY, so the subset is arbitrary); restriction detected from inbound only — with no priced inbound batch on hand a reader without view_prices sees cost total **0.00 instead of 受限** (masked `unit_cost_base` skipped at :234); masked vs never-costed not told apart on the output side; "every row matching the filters" trivially met (no filters); "one per currency" structurally yes (base ×2, USD ×1) but USD is hard-coded. DB building blocks exist: `output_batch_valuation` (`cost_value_base` + unmasked `never_costed`, output_batch_valuation.sql:9-18) and `inventory_valuation_snapshot()` (DEFINER, NULL + named restriction, inventory_valuation_snapshot.sql:63-157) — but the snapshot's by-location set is `inventory_movements` with `mt.deleted_at` filtered (:93), not this page's set.

**/finance/assets depreciation preview** — total row from the RPC's `total_delta` (preview_depreciate_fixed_assets :124-125), appended as an `isTotal` pseudo-row (assets/page.tsx:123-125). DB-computed, one base currency, nothing masked → **already satisfies** (but it is a pseudo-row, not a DataTable `footer`).

Other DB totals near (not footers): /finance/close preview Σ debits/credits (RPC `journal_close_preview`, close/page.tsx:170-178); /me medical balance (RPC `medical_claim_balance`, me/page.tsx:176-178 — approved+paid, current year). Record counts only: bank/statements (page.tsx:107), hr/payroll (:110), purchasing/orders (:116).

## 7. DataTable footer support, list sorting and filter sharing

- **`footer` exists (TABLE-FOOTER-1, 2026-09-10) and is used by no DataTable.** Type `FooterRow { key, label, cells: Record<colKey, ReactNode>, className? }` (app/components/ui/data-table.tsx:291-310); prop `footer?: (rendered: readonly T[]) => ReadonlyArray<FooterRow>` (:369-374); called with the **visible** rows (:521); unknown column key throws `DATATABLE_FOOTER_UNKNOWN_COLUMN` (:526-538); a cell on the first column throws `DATATABLE_FOOTER_NO_LABEL_ROOM` (:546-556); component computes both breakpoints' colSpans and folds phone-hidden columns' totals into the phone label cell (:557-569, :908-956). The header (:276-281) says explicitly that the component does not sum and does not force the footer to match `rendered` — "balance-sheet 的总资产是服务端算的…那也是对的" — so a server total is a sanctioned use: ignore `rendered`.
- **The three `footer=` hits in app/ are EditableTable** (QuoteLinesEditor.tsx:221, MySelfAssessmentPanel.tsx:231, GoalsEditor.tsx:338 — each file has 0 `<DataTable`), whose footer is a submit area after `</table>`.
- **How to pass a server total in.** `data-table.tsx` is `'use client'` (:1) and so are the page Tables (e.g. ExpensesTable.tsx:1, InvoicesTable.tsx:1, OrdersTable.tsx:1). A function prop cannot cross the server→client boundary, so the server page passes **data** — e.g. `totals: { currency: string; amounts: Record<colKey, number | null>; restricted: boolean }[]` — to the `*Table` client component, which builds `footer={() => totals.map(t => ({ key: t.currency, label: …, cells: { amount: t.restricted ? <Refusal/> : formatMoney(...) } }))}`. One FooterRow per currency gives "one total per currency" naturally.
- **CellsTable** (app/operation/equipment/CellsTable.tsx, `'use client'`) passes no `footer` (grep 0) — /finance/electricity needs it threaded through.
- **lib/listSort.ts** — `parseListSort` / `applyListSort` / `setSortParams` (:34,57,74) handle only `?sort=&dir=`; filter parsing is per page, not shared. Rule ⑤ (:18) already requires the export route to read the same params; a totals reader should be added beside each page's `count`/`page` functions in the same `*Rows.ts` and take the same parsed params object. `READ_ROW_LIMIT = 1000` (:25) is the client-sort cut-off (data-table.tsx:418-419).
- **lib/export/serverRows.ts** — `exportRowsResponse` (count → `fetchAllPages` by 1,000, cap 50,000) is the pattern export routes use with the page's own `count`/`page`/`shape` (:56-68). Fetching all pages and summing in JS would be correct up to 50,000 rows but is not "calculated by the database".
- **SQL precedent for a totals function:** `trial_balance_totals()` — `RETURNS TABLE`, `STABLE SECURITY DEFINER`, `SET search_path`, `PERFORM require_permission('module.finance.view')` first, written precisely because RLS was silently dropping payroll lines from a JS sum (db/functions/trial_balance_totals.sql:1-20). AGENTS.md:930-934: a set-returning function must not express "restricted" as zero rows — return a `restricted` column, or RAISE.

## 8. Ambiguities that may need a decision from Tim

1. **Meaningless sums inside "the 24 amount lists"** (6 columns on 3 pages + 1 price): /finance/bank/statements opening/closing (each row = one statement's balance at one moment, bank_statements.sql:19-20); /finance/close debits/credits (each `period_closes` row is cumulative from inception, close_period.sql:65; re-closes add rows, period_closes.sql:9-10); /finance/supplier-statements closing (many statements per supplier over time incl. superseded, db/tables/supplier_statements.sql:43-47,60); inventory avgPrice (a price). Does the ruling include these pages/columns, or do they get no footer (possibly a different figure, e.g. net movement Σ(closing−opening) on bank statements)? If those 3 pages are dropped the count is 21 pages.
2. **Reversal rule** — expenses and payments insert a positive mirror row (reverse_expense_internal.sql:143-159; reverse_payment_internal.sql:54-68), journal posts an equal positive reversal entry (AGENTS.md:1334-1340): a plain total counts each reversed document 2×. Freight, bank transfers, electricity, wht remittances keep the reversed original with a positive amount. Exclude reversed originals + mirrors? Show them netted? Separate line?
3. **Status scope** — finance/claims (approved/rejected/withdrawn), hr/claims, /me medical/expense (all statuses vs approved+paid), self-approved (approved vs rejected decisions; level 1 and 2), payment-requests (6 kinds), PO (drafts with confirmed), hr/payroll and /me payslips (drafts; all-time vs year).
4. **Commissions** — ruling "total only the rows that hold an amount" still sums `per_tonne` rows, which are a price per tonne (commission_agreements.sql:62-67; messages/zh.ts:2296), mixed with `fixed_amount`. `fixed_amount` only, per basis, or none? Current agreements only?
5. **Payments direction** — signed net or in/out separately (payments.sql:15,28)?
6. **Partial per-row masking** (hr/claims, journal, self-approved): when only some rows are hidden, the ruling says the whole currency total reads 受限 — confirm that the visible part is not shown alongside.
7. **Silently dropped rows** — /contracts (customers.view) and /logistics/forwarders (purchase prices): confirm the footer should read 受限 there by permission check, although the rows themselves are not shown as 受限 today.
8. **Pre-existing truncation** that will make a correct DB footer disagree with the rows above it: /finance/assets accum/NBV (depreciation read unpaged), /logistics/forwarders owed (ap_open_items unpaged), /inventory (7 reads), /finance/self-approved (RPC ≤1000 while claiming `coverage:'complete'`). Fix inside TF-2 or register?
9. **Currency choices** — expenses/freight/electricity/payments carry both a document currency and base: per document currency (ruling) or base? Electricity has a per-row `currency` column but the page renders every row in today's base (electricity/page.tsx:58). Forwarders: base `open_base` vs per-document `open_ccy`.
10. Side findings (register?): invoices masked-reader `state=paid/overdue` returns nothing (invoice_status.sql:36,40); /hr/claims status dropdown lacks `awaiting_payment_run` (medical_claim_status.sql:51 vs hr/claims/page.tsx:62); commission per-tonne amounts shown without "/t" (CommissionsTable.tsx:84-85); expenses total variable still named `totalUsd` (expenses/page.tsx:73).
