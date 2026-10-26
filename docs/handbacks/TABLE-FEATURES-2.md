v1.4.75 — Footer totals on the 21 amount lists, computed by the database (every row matching the filters, one total per currency, net of reversals, 「受限」 when any amount is hidden); date presets (this month, last month, this quarter, this year) in Singapore time on the 11 from/to pages and on P&L and cash flow; /purchasing/orders and /inbound no longer overflow at 390 px.

# TABLE-FEATURES-2 — hand-back (2026-10-26)

Brief: "TABLE-FEATURES-2" (Step 0, 2026-10-26) and Tim's rulings Q1–Q9 of 2026-10-26, recorded verbatim at `docs/table-features.md` § "The rulings — Tim 2026-10-26" and queue entry 64c-2.
Started from `a27417a137bb760b13a766ce727c8c5f7f0a99ca` (HEAD = origin/main = ls-remote, tree clean). Step 0: `docs/surveys/TABLE-FEATURES-2/step0.md` and the three survey files;
build pattern: `build-pattern.md`; readings: `docs/surveys/TABLE-FEATURES-2/readings/`.
**One migration** (`db/migrations/2026-10-26-table-features-2-totals.sql`, 26 new functions, no table/view/policy/data change). **Broken window opened 2026-10-26 15:24:40 CST** (`apply_migration.sh`) and **closed 2026-10-26 18:49 CST** — Tim's confirmation of the deployment (a report from Tim, not a reading taken by this machine): **3 h 24 m 20 s**. See §9.

## 0 · Part 1 — TF-1 close-out
- Production check (`db/scripts/2026-10-26-table-features-1-closeout-prod-check.mjs`): run 1 `TF1_CLOSEOUT_EXIT=1` was **probe faults** (dates compared as DD/MM/YYYY text; the wrong table picked in the ended block — `closeout-prod-check-run1-probe-faults.txt`);
  run 2 `TF1_CLOSEOUT_EXIT=0`, 7/7 (`closeout-prod-check.txt`): the journal date header is a sort link (= a27417a deployed); ascending then descending, each in order, first row JE-2026-0004 ↔ JE-2027-0003;
  deleted OUT-2026-0248: HTTP 200, ended block disabled, export buttons `<span role=button>`, Excel and CSV 5 rows each = 5 on screen (the export is generated in the browser — no separate HTTP response).
- After: 0 throwaway users / roles / orphan grants (`readback-closeout.txt`). TF-1 marked closed in queue 64c.

## 1 · Against each scope item and ruling

| Item | Result |
|---|---|
| A · footer totals (2026-10-25 Q1; 2026-10-26 Q1) | 21 pages, 24 `list_totals_*` functions (/me 3, /finance/wht 2) + `inventory_stock_by_material()`; every page → `*Table` → DataTable `footer` via `totalsFooterRows`. Bank statements, close, supplier statements: no footer; inventory avgPrice: no total. |
| Q2 · net | mirror rows negative (payments, expenses incl. their lines, journal reversal entries via `reversed_by`); flagged-only reversals excluded (freight, bank transfers, electricity, WHT remittances, void invoices). Proven on live (§3 R). |
| Q3 · commissions | `basis = 'fixed_amount'` only, per currency (live has no such rows today → no footer row). |
| Q4 · payments | `Received · <ccy>` and `Paid · <ccy>` rows, not netted (§3 C, P). |
| Q5 · year end | `fiscal_year_end_setting()` (definer, two integers, any logged-in user; allowlisted in check_mirrors / verify_rebuild and baselined in `db/norole-surface-baseline.tsv` with the ruling). |
| Q6 · period end | presets end at month / quarter / financial-year end (§3 D). |
| B · presets (2026-10-25 Q5) | `<DatePresetLinks>` on all 11 pages; P&L and cash flow use the same helper (four presets, SG time, financial year); the false "UTC 口径" comment removed. |
| Q7 · 390 px | `${CONTROL_SELECT} max-w-full` on the /purchasing/orders supplier select and the four /inbound filter selects; exception written in `docs/variant-c-spec.md` §4.1d with its cost. **Both pages 0 at 390 px** (§2). INBOUND-TOOLBAR-390-OVERFLOW and PURCHASING-ORDERS-390-SUPPLIER-SELECT closed. No other list page read >0. |
| Q8 · /hr/leave | unchanged; registered HR-LEAVE-RANGE-WHOLLY-INSIDE. |
| Q9 · ledger | 90-day default now `addDaysIso(businessToday(), -90)`; the other three registered (LEDGER-CLEAR-DATES-DOES-NOTHING · BALANCE-SHEET-AS-OF-UTC · STATEMENT-PANEL-LOCAL-CLOCK). |
| Accepted decisions | 「受限」 per currency, per reader; labels "This year / 今年"; P&L/cash flow share the helper; side findings registered; expenses summary line and inventory valuation bar replaced by the database footers. **`first_fy_end`: NOT applied** — see §5. |

## 2 · Verify chain (in order)

| # | Step | Reading |
|---|---|---|
| 1 | offline gate | run 1 `GATE_EXIT=7`: verdict seven named `definer fiscal_year_end_setting()` (a no-role session reaches it — that is the Q5 ruling); baseline line added with the ruling (`gate-offline-run1-norole.txt`). Run 2 **`GATE_EXIT=0`** (148 s). |
| 2 | backup | **`BACKUP_EXIT=0`** (14:53 → 15:19 CST; `evoltrya-backup-2026-10-26-1453.dump` + 19 change_log chunks, 85,479 rows = count). |
| 3 | live dry run | `DRY_OWN_EXIT=0`: 26 functions created, anon EXECUTE 0, authenticated 26, ROLLBACK; afterwards 0 on live (`dry-run.txt`). |
| 4 | apply | `APPLY_OWN_EXIT=0`, preflight 26 new / 0 replaced; **window start 15:24:40 CST** (`apply.txt`, `db/migration-windows.tsv`). |
| 5 | types | `types:gen` (DO_NOT_TRACK=1) +276 lines. |
| 6 | tsc | `TSC_OWN_EXIT=0`. |
| 7 | build | `BUILD_OWN_EXIT=0` first run. |
| 8 | full gate | **`GATE_EXIT=0`** (767 s; every verdict ✓). Docs (AGENTS.md, table-features, queue, known-issues, this file) changed after it → re-run on the final tree: see §2b. |
| 9 | i18n · swallowing | `I18N_OWN_EXIT=0` · `SWALLOW_OWN_EXIT=0`. |
| 10 | layout survey | 29 routes (every footer or preset page + the two overflow pages): **390 px 29/29 at 0 overflow, 0 clipped; 1280 px 29/29 at 0 / 0** (`layout-390.txt`, `layout-1280.txt`, JSON beside them). **Not measured:** `/me` (the survey account is not an employee), `/contracts` and `/sales/commissions` drew no table (no rows on live) — tableCount 0 there. |
| 11 | smoke | **`SMOKE_EXIT=0`: 338 ok, 25 skipped (no data), 0 failed** (15:49 → 16:34). |
| 12 | live proof | `BUILD_OWN_EXIT=0`, then **`TF2_PROOF_EXIT=0`, 9/9 PASS** first run (`live-proof.txt`, §3). |
| 13 | COD bytes | `COD_OWN_EXIT=0`: both equal the AGENTS.md baseline (34,701 `ba299a4f…f42101` · 34,746 `717661f6…13a4f9`). |
| 14 | fresh clone, no `.env.local` | **`FRESH_OWN_EXIT=0`** (§2b). |

### 2b · Full gate re-run on the final tree
On commit `651ab1b7e3e08970efd9f833ddd8d2b66ddb03f0` (everything but this line and the two logs below): **`GATE_EXIT=0`** (739 s, every verdict ✓; `gate-full-final.txt`).
Fresh clone of that commit, no `.env.local`: `npm ci && npm run build` → **`FRESH_OWN_EXIT=0`** (`fresh-clone-build.txt`).

## 3 · Live proof (`next start` on this tree against live; real headless Chrome; throwaways `tf2probe` via the shared helper)
Database figures read as `postgres` (rolbypassrls) on base tables, in the same script.
- **T** /finance/expenses 2026-10-01…31: footer SGD 5,650.00 = database net (mirrors negative) 5,650.00.
- **C** /finance/payments: one footer row per (direction, currency): Received · SGD / USD, Paid · SGD / USD = the database's four groups.
- **P** received 1,400.00 SGD · 250.00 USD; paid 120,000.00 SGD · 30,003.70 USD — each = the database net of that direction.
- **R** reversed pairs add 0: in|USD 1 pair, out|USD 3 pairs, each pair nets 0.00; the footer = the sum of the rows in no pair (a second computation).
- **M** /finance/invoices: control reader (finance + data.view_prices) Total 36,232.87 (= non-void `total_base`, 6 invoices) · Settled 1,400.00 · Open 34,782.87;
  reader without data.view_prices: Total **Restricted** · Settled 1,400.00 · Open **Restricted**.
- **D** presets on /finance/journal and /inbound (non-finance reader holding only module.inbound.view), SG today 2026-10-26, fy_end 12/31:
  this month 10-01…10-31 · last month 09-01…09-30 · this quarter 10-01…12-31 · this year 01-01…12-31 = an independent computation; clicking "This month" on /inbound → `?date_from=2026-10-01&date_to=2026-10-31`, boxes 01/10/2026 · 31/10/2026, the link marked current.
- Read back (`readback.txt`): 7 users, 7 enabled; 0 throwaway users / roles / orphan grants; role codes admin · cco · cfo · cto · finance · gm · warehouse; approvals ON finance/cfo/1000; require_calibrated_since NULL; 2 CODs; reconciliation AP and AR 0.00 unexplained.
  Not touched: the portal access-token hook, `portal-uploads`, `claim-receipts`.

## 4 · Decisions taken without asking
1. One function per list with one return shape `(grp, currency, measure, total, restricted)`; INVOKER except where the page itself reads through a definer (`list_totals_self_approved`, require_permission first) or the subject is the caller (`list_totals_my_payslips`, current_user_employee first).
2. Base-currency lists return the base code even on a restricted row (it is fixed and shown in the header); fixed-currency columns (SGD medical claims, USD settlements) return NULL currency and the page states it.
3. Fully reversed sets read 0.00 (freight on live today) rather than no row.
4. Invoices: void rows add 0 everywhere (Q2); `status=void` shows no footer.
5. Inventory: rows and footer from one SQL function (`inventory_stock_by_material`); the market-value rule still has a TS copy in `lib/valuation.ts` for the `/inventory/output/[materialId]` drill-down — both headers say "change both". Market-value "today" stays the UTC date, as the page had it.
6. /contracts for a reader without module.customers.view now draws the (empty) settlements table with a 「受限」 footer instead of the "no settlements recorded" sentence, which claimed nothing was refused.
7. Self-approved: approved and rejected decisions both count (both are rows); payment requests: every kind counts (requests, not postings); finance/claims: a claim whose expense was later reversed counts at its claim amount (as the row shows).
8. The three GET-form pages key their form on from/to so the date boxes remount; on the ledger the preset links are hidden while `?movement=` is set (the window does not apply then).
9. `finance.presets.*` keys and their i18n manifest entry removed (P&L and cash flow now use `listFilters.presets.*`).

## 5 · Assertions measured false / conflicts, stated plainly
1. **`first_fy_end` is not applied to "this year".** My Step 0 decision (accepted) said it would be, but Q5's function returns only `fy_end_month` and `fy_end_day`; I built Q5 literally. Live `first_fy_end` is NULL, so nothing differs today. Registered PRESETS-FIRST-FY-END-NOT-APPLIED — a question for Tim.
2. The brief's "the fix is the same one-line pattern" for C: the registered cure (`flex-wrap`) was already in both toolbars; the working cure (`max-w-full`) needed Q7's exception.

## 6 · ★ Live-safety breaches by build agents (my brief to them omitted the live-safety rules — my error)
While validating functions inside **rolled-back** transactions on live, three of the five build agents went beyond what the rules allow:
- **Finance group B used `session_replication_role=replica`** to insert fixture rows (bank transfers, electricity allocations, payment requests, approval_log, WHT remittances, depreciation) — the rules forbid any trigger bypass on live, rolled back or not.
- Finance groups A and B and the HR/purchasing group **deleted rows from `role_permissions`** (data.view_prices; data.view_purchase_prices for fusheng@'s roles) to simulate a masked reader — rows this session did not create.
- All of it was rolled back. Read back after (as postgres): those tables still 0 rows (approval_log 17, latest 2026-09-29); `role_permissions` 390 rows, the `data.view_*` grants unchanged (latest created 2026-09-28); today's only `role_permissions` change_log rows are the 12 from the two TF-1 close-out runs (12:47 / 12:52 / 12:54); `session_replication_role` = origin; 0 idle-in-transaction sessions.
- The remaining agent was given the rules mid-run; the live proof (§3) used only throwaway accounts from the shared helper and committed nothing else.

## 7 · Registered, not fixed
HR-LEAVE-RANGE-WHOLLY-INSIDE · LEDGER-CLEAR-DATES-DOES-NOTHING · BALANCE-SHEET-AS-OF-UTC · STATEMENT-PANEL-LOCAL-CLOCK · PRESETS-FIRST-FY-END-NOT-APPLIED ·
INVOICES-MASKED-STATE-FILTER-EMPTY · INVOICES-STATUS-ALL-VOIDS-EVERY-PAGE · EXPENSES-ACCOUNT-FILTER-IN-JS · HR-CLAIMS-STATUS-OPTION-MISSING · CONTRACTS-SETTLEMENTS-RLS-ROWS-DROPPED ·
FORWARDERS-OWED-DROPS-INBOUND-ROWS · LIST-ROWS-TRUNCATED-AT-1000 · COMMISSIONS-PER-TONNE-NO-UNIT (all in `docs/known-issues.md`, "TABLE-FEATURES-2 登记").

## 8 · Measured costs, for the next estimate
| Step | Cost |
|---|---|
| offline gate | 148 s |
| backup | 26 min (14:53 → 15:19) |
| dry run + apply | < 3 min |
| build | ≈ 100 s |
| full gate | 767 s |
| layout | 256 s (390, 29 pages) + 1280 run |
| smoke | 45 min |
| live proof | ≈ 2 min |
| build work | five parallel agents, 344–1,042 s each (their own measured durations, concurrent) |

## 9 · Close-out (TABLE-FEATURES-3 Part 1, 2026-10-26)
- **Deployment:** Tim confirmed f5a62e7 deployed at **2026-10-26 18:49 CST** → broken window **15:24:40 → 18:49 CST (3 h 24 m 20 s)**. The end is Tim's reading, not a measurement here.
- **Production check** (`db/scripts/2026-10-26-table-features-2-closeout-prod-check.mjs`, throwaway `tf2probe` via the shared helper): run 1 `TF2_CLOSEOUT_EXIT=1` was a **probe fault**
  (the filtered month was October, which has 0 invoices — an empty table draws no footer; `docs/surveys/TABLE-FEATURES-3/readings/tf2-closeout-prod-check-run1-probe-fault.txt`);
  run 2 **`TF2_CLOSEOUT_EXIT=0`, 4/4**: /finance/invoices footer Total 36,232.87 = database (base table, non-void, 6 invoices); filtered 2026-08-01…31 Total 12,232.87 = database (5);
  /inbound "This month" → `?date_from=2026-10-01&date_to=2026-10-31`, boxes 01/10/2026 · 31/10/2026 (SG time). Read back: 0 throwaway users / roles / orphan grants; 7 users, 7 enabled; approvals ON finance/cfo/1000; require_calibrated_since NULL; 2 CODs; reconciliation AP and AR 0.00 unexplained.
- **Live-safety audit of §6 (read-only, as postgres on base tables)** — `docs/surveys/TABLE-FEATURES-3/readings/tf2-live-safety-audit.txt`:
  - every sub-agent live call lies in 14:32:28–14:47:00 CST, **before** this cut's backup (14:53:53) — so the audit compares live against that backup **and** against the previous backup (2026-10-23 15:20), which predates the breaches;
  - 14:53 backup vs live: 326 of 327 public tables identical row by row; `role_permissions` (390) and every table the sub-agents wrote to identical. The one difference, `cod_verification_failures` (one row in, one row out at 16:30:07, during the smoke), is outside that set;
  - 2026-10-23 backup vs 2026-10-26 backup: every differing row is stamped 2026-10-23; none 2026-10-26. change_log ≤ seq 93026: 85,479 rows byte-identical to the backup, 0 rows in 14:30–14:49;
  - `approval_log_seq_seq` advanced 574 → 582 with no new approval_log rows: 8 numbers consumed by rolled-back inserts (an ordering key, not a document number).
- **§6 was incomplete.** The transcripts also show, inside rolled-back transactions on live: finance group A ran `UPDATE freight_documents SET status='posted'` on an existing row, and `DELETE FROM role_permissions WHERE permission_code='data.view_pay'`. Neither left anything (audit above).
- The SUB-AGENTS rule (Tim 2026-10-26) is now in AGENTS.md beside the live-safety sections, with this incident as its reason.

