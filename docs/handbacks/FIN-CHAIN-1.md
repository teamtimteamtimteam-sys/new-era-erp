v1.4.63 — Sales and finance chain fixes, new accounts: 14 new accounts (2600 Loan Payable and 13 expense accounts); an order with a live invoice can no longer be cancelled; order-flow sales cannot be invoiced twice; a short-shipped order can be closed short on purpose; quotation status moves only through its own actions; six more cash-out doors refuse tomorrow's date; a month with an unexplained ledger-vs-list difference cannot be closed; the management pack and the Finance home read the new reconciliation; a freight reversal is dated by the person reversing it; the claims decide button asks the right permission; customer statements and the other outbound PDFs print English dates; system accounts are marked on the trial balance.

# FIN-CHAIN-1 — hand-back (2026-10-20) · sales / finance chain correctness, chart-of-accounts additions, Tim's 35 rulings recorded

The brief "FIN-CHAIN-1 — sales/finance chain correctness + chart-of-accounts additions + recording Tim's 35 rulings of 2026-10-20", with Tim's
rulings on the Step 0 report (same day): **C4 (settlement posting) and C5 (payroll payment reversal) are out of this cut**; Q2–Q13 as written in his reply.
Readings: `docs/surveys/FIN-CHAIN-1/readings/`. Started from `1ae65bb33b892e9d0220963271e2c787c19fbb59` (HEAD = origin/main = ls-remote, tree clean).

## 1 · What changed, per scope item

| Item | What | Proof |
|---|---|---|
| A1 · A2 | 14 non-system accounts in the bootstrap's non-system section and on live: **2600 Loan Payable / 应付借款** (liability · monetary · cash-flow financing) and 6010 · 6130 · 6140 · 6210 · 6220 · 6230 · 6240 · 6250 · 6310 · 6410 · 6420 · 6510 · 6520 (expense · non-monetary). Not created: Freight Charges, Other Operating Expenses, a second Repairs & Maintenance, a second Share Capital; 6300 / 6900 keep their names. | fixture 284; migration self-proof; live proof A1 |
| A3 | Nothing else created (asserted by fixture 284 B). | fixture 284 B |
| A4 | The expense picker filters `account_type = 'expense' AND is_active` (`app/finance/expenses/new/page.tsx:28-33`): the 13 appear, 2600 does not; `record_expense` also refuses 2600 (`ACCOUNT_NOT_EXPENSE`). **Bootstrap defaults: still correct, not just valid** — no column's meaning changed; every existing default row still says what it said; the 14 new rows are Tim's list verbatim (stated in `db/tables/accounts.sql` above the insert). | live proof A4 (HTTP, finance copy); fixture 284 C · D |
| A5 | `/finance/trial-balance` marks `accounts.is_system` with a "System / 系统" badge (hover explains why). First version overflowed 390 px by +21 px (before: 0, measured with the change set aside); the name and badges now sit in a wrapping flex → 0. | live proof A5 (6800 · 2000 badged; 2600 · 6010 not; zh 系统); `readings/survey-390-trial-balance-*.txt` |
| B1 | `set_sales_order_status` refuses cancelling an order that has a live order-flow invoice: `SO_CANCEL_HAS_LIVE_INVOICE|order|invoice`, copy says raise a void request first. | fixture 279 A · E (injection); live proof B1 (SO-2026-0005 / INV-2026-0010 inside the rolled-back tx) |
| B2 | `create_invoice` refuses order-flow sales (`SALE_IS_ORDER_FLOW|batch`); `/finance/invoices/new` lists only `sales_order_line_id IS NULL`. | fixture 279 B; live proof B2 (OUT-2026-0118) |
| B3 | Explicit **close short**: `partially_shipped → closed`, reason required (`SO_CLOSE_REASON_REQUIRED`), refused while any invoiced-but-unshipped quantity is not credited away (`SO_CLOSE_INVOICED_UNSHIPPED|order|line|qty`), remaining reservations released, a `closed` history line with the reason; never automatic. Order page panel gains "Close short". | fixture 279 C · D (live has no partially-shipped order to try — read as postgres) |
| B4 | Row-level guard `trg_quotes_status_through_function` (INVOKER, `row_security_active`): direct `status` / `converted_order_id` / `decline_reason` changes, or a direct insert that is not a draft → `QT_STATUS_THROUGH_FUNCTION_ONLY`; other columns stay editable; the three definer functions pass. | fixture 280 (incl. injection); live proof B4 |
| C1 | The six cash-out doors refuse a future date by name (`DOCUMENT_DATE_IN_FUTURE|<kind>|date|today`); a bank-transfer / WHT request with a future planned date is refused at submit and approval (Tim Q13); the payroll and processing-cost pickers cap at today; the transfer form defaults to the business day. **Existing fixtures moved: zero** (read in Step 0, confirmed by the offline gate). | fixture 281 (each door, today/tomorrow, request leg, injection); live proof C1 (all six + the request) |
| C2 | `management_pack_data`: receivables / payables "unexplained" now from `list_ledger_reconciliation` (stored in the pack with `list_ledger_read_at`; refused sides in `list_ledger_refused_sides`); stock legs still from the only check that answers for them; the old breakdown stays, labelled **"Breakdown by mechanism — not a defect check"** on the pack page; frozen packs untouched (the page tells them apart by `control_unexplained_basis`). `/finance` home: ar / ap legs read the new reconciliation; the out-of-date sentence (`messages/en.ts:1074` and its zh twin) rewritten. | fixture 282 C; live proof C2 |
| C3 | `close_period` refuses `CLOSE_LEDGER_LIST_UNEXPLAINED|side|amount` when today's whole-ledger check shows a difference, `CLOSE_RECON_UNANSWERABLE|side|refusal` when a side cannot be answered; month-end step now `blocked` when it does not agree. | fixture 282 B · D · E · F (injection); live proof: the check close_period reads moves to ap −777.00 after an unexplained entry into 2000; **on live `close_period` answers an earlier gate first** (`PROCESSING_COSTS_UNALLOCATED`, the 8 runs of AT1C3) — reported, not worked around |
| C6 | `reverse_freight_document(id, reason, p_reversal_date)` — required (`REVERSAL_DATE_REQUIRED`), never defaulted, not before the original, a locked period refused (`PERIOD_LOCKED`). Signature changed: old one dropped. Detail page gains a required date (min = document date). Fixtures 100 · 101 · 213 · 242 pass the date their old behaviour used; fixture 214's catalogue count is now 5 functions / 6 calls. | fixture 283; live proof C6 (FRT-2026-0001, refused before any write; old signature gone) |
| C7 | `/finance/claims` decide button: `canViewPrices()` inside the finance-gated page, gate code `data.view_prices` — the same pair `decide_expense_claim` asks; like the journal / invoice / GST decide buttons. | live proof C7 (cfo copy: no control names `module.finance.edit`, the pending claim listed) |
| D1 · Q9 | Customer statement PDF: English body and English dates (`translatorFor('en')`, `noSignatureEn('statement')`); the UI error stays in the reader's language. English dates also on invoice, credit note, delivery note — **and on quotation, sales order and purchase order**, which my Step 0 survey had missed (same leak, same one-line fix; under ruling d2 #12, "always English, like the other outbound documents"). | build; i18n check |
| D2 | Credit note prints `N/A` for lines with no quantity. The stock-snapshot half was already done by IA-BUILD-1 (`app/inventory/reports/snapshot/pdf/route.ts:4-16,47`); entry closed with both halves. | read |
| E | The 35 rulings recorded at their sources with "Tim 2026-10-20"; closed entries struck; created work queued (`docs/forward-queue.md` "FIN-CHAIN-1 之后的队列" and the new "上线准备组 · go-live readiness group"); EXPENSE-MULTILINE-1 is item 62 (next cut), PAYROLL-PAY-REVERSAL-1 item 63 with Tim's ruled shape; SETTLE-1 carries the eight policy questions; Tim's dashboard action (refresh-token interval 60 s) is d1 #46 in the state-of-the-queue. | `git diff` of `docs/` |

## 2 · Verify chain (order as briefed; every exit read from the script's own line)

| # | Step | Result |
|---|---|---|
| 1 | offline gate | `GATE_EXIT=0` (126 s; 288 fixtures). First run was red on two existing fixtures that this cut's rulings legitimately changed — 209 (its closer lacked the price codes → `CLOSE_RECON_UNANSWERABLE`, as Q2 rules; the role got the two codes live finance holds) and 214 (catalogue count 6 → 5 after freight left `reversal_date_for`) |
| 2 | backup | `BACKUP_EXIT=0` — `evoltrya-backup-2026-10-20-1706.dump` (TOC 9,779, previous 9,745) + 16 change_log chunks, rows 71,659 = count; 17:06:10 → ~17:36 CST (≈ 30 min, measured from the log) |
| 3 | live dry run COMMIT→ROLLBACK | `DRY_OWN_EXIT=0` (self-proof passed inside; after rollback: 0 new accounts, two-argument freight function, no guard) |
| 4 | apply | `APPLY_OWN_EXIT=0`; pre-flight 17 warnings, all non-system account codes or comments (14 new codes, 3000 and 6900 named in the pre-checks, and one "this migration touches is_system" note raised by a comment — it changes no `is_system` value); **broken window start 2026-10-20 17:43:01 CST** (`db/migration-windows.tsv`) |
| 5 | types | `TYPES_OWN_EXIT=0` (one change: `reverse_freight_document` gains `p_reversal_date`) |
| 6 | tsc | `TSC_OWN_EXIT=0` |
| 7 | build | `BUILD_OWN_EXIT=0` |
| 8 | full gate | `GATE_EXIT=0` (787 s): rebuild · mirrors vs live (incl. generated types) · all fixtures · anon (327) · no-role (126) · portal (42) |
| 9 | i18n | `I18N_OWN_EXIT=0` |
| 10 | error-swallowing | `SWALLOW_OWN_EXIT=0` (0 unallowed) |
| 11 | layout survey, 12 touched pages | 390 px: 11/12 first, trial balance +21 → fixed → 0 (re-measured); 1280 px: 12/12, 0 overflow, 0 clipped |
| 12 | smoke | `SMOKE_EXIT=0` — 304 ok · 25 skipped (no data) · 0 failed; timed 278 routes, 1,588 s; the 6 stale `ZZ-SMOKE` rows reported as before (not mine, not touched) |
| 13 | live proof | `FINCHAIN1_PROOF_EXIT=0` (third run; the first two stopped on driver/setup errors in my script — an unclaimed insert refused by the saleability guard, and a customer without payment terms answering before B2's check — both fixed in the script, nothing committed by either). Read back as postgres afterwards: approvals ON (finance / cfo / 1,000); 7 real accounts, 0 disabled, roles admin · finance · warehouse · cto · cco · cfo · gm unchanged; throwaway users 0 · roles 0; 2 COD rows; `require_calibrated_since` NULL; list-vs-ledger ap 0.00 · ar 0.00 (read as tim@) |
| 14 | fresh clone, no `.env.local`: `npm ci && npm run build` | recorded in the close report (it builds the commit that contains this file) |

**Broken window — what is broken in it (derived):** the old app's freight reversal sends no date → `REVERSAL_DATE_REQUIRED` (refused by name, nothing written).
Everything else is a tightening: actions the old pages offered that are now refused by name (cancel an invoiced order, a sale-type invoice for an order-flow
sale, a future cash-out date, a close with an unexplained difference) — live had none of these at the moment of the migration (reconciliation 0.00 / 0.00, asserted
in the migration). The end of the window is Tim's reading on Vercel.

## 3 · Corrections to my own Step 0 report

- "The MES7A2CO-NO-CHART-OF-ACCOUNTS-PAGE heading appears twice" was **false** — a survey agent read body text as a heading. The real stale item was next to it:
  **MES7A2CO-ROLLFORWARD-HIDDEN-WITHOUT-RUNS (ruling d2 #33) had already been closed by MES-7b-1 (`v1.4.54`, F14)**; its heading had never been struck.
  Struck now; the go-live group's row 8 says "already done".
- The quotation / sales order / purchase order PDFs had the same Chinese-date leak as the three Tim named in Q9; fixed under d2 #12 (see D1).
- The estimate's gate figure: the full gate took 787 s (MES-9c: 724 s).

## 4 · Registered, not fixed

- On live, `close_period` cannot reach the new refusal today: the 8 never-allocated processing runs (AT1C3-LIVE-MONTH-CLOSE-BLOCKED-BY-UNALLOCATED-RUNS, Tim's own
  action d1 #13) refuse first. The new refusal is proved on the rebuild (fixture 282).
- C4 and C5 queued as Tim ruled (`docs/forward-queue.md` SETTLE-POST group; item 63 PAYROLL-PAY-REVERSAL-1).
