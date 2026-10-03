# AT-1c survey C — the shared finance_settings row (Q25), period-end and settings pages

Read-only. Live queries ran through the Management API as `postgres` (`rolbypassrls = true`, measured in the first query), base tables only.
Helper: `(Step 0 scratchpad, not kept) qC.sh`. **M** = Measured (query or file:line). **I** = Inferred.

---

## A. Q25: the shared `finance_settings` row

### A1. Key and columns (M)
- Key: `id boolean PRIMARY KEY DEFAULT true CHECK (id)` (`db/tables/finance_settings.sql:24`). This is the M5 shape, the same as the three threshold panels, so the page passes `'true'`.
- Live column order (information_schema, M) matches the mirror. Writer of each column:

| # | column | writer (M) | gate | panel |
|---|---|---|---|---|
| 1 | id | — | — | — |
| 2 | locked_before | `setPeriodLock` direct UPDATE (`app/finance/settings/actions.ts:30-36`); `close_period` (`db/functions/close_period.sql:65`); `reopen_period` (`reopen_period.sql:39`) | module.finance.edit / module.finance.edit / action.finance_reopen | **Lock** (`LockForm`, /finance/settings) |
| 3 | updated_at | trigger | — | technical, never shown |
| 4 | updated_by | every writer | — | technical (shared by every panel, so it cannot be attributed to one) |
| 5 | gst_registered | `setGstRegistration` → `set_finance_settings` (`gstActions.ts:55`) | action.finance_settings | **GST** (`GstPanel`) |
| 6 | gst_rate_pct | `set_finance_settings` only, no UI. Dead column: its COMMENT says nothing reads it | action.finance_settings | none |
| 7 | gst_registration_no | same call as gst_registered | action.finance_settings | **GST** |
| 8 | system_start_date | `set_finance_settings` only, no UI (grep of app/: 0 writers) | action.finance_settings | none |
| 9 | fy_end_month | same | same | none |
| 10 | fy_end_day | same | same | none |
| 11 | first_fy_end | same | same | none |
| 12 | default_allocation_basis | same. Read by `/operation/processing/new` (`page.tsx:45`) | same | none |
| 13 | approval_level1_role_code | `set_approvals_policy` (`set_approvals_policy.sql:59-65`) only; direct writes are refused (`guard_approvals_policy_write`) | action.manage_permissions | **Approval policy** |
| 14 | approval_threshold_base | same | same | **Approval policy** |
| 15 | approvals_enabled | same | same | **Approval policy** |
| 16 | approval_level2_role_code | same | same | **Approval policy** |

`set_finance_settings` itself lists the split: `v_allowed` holds the 8 CFO columns and `v_elsewhere` holds the lock plus the 4 approval columns (`set_finance_settings.sql:33-38`). Its header says "今天界面上只有 GST 那一块(Q10:不加新屏)" (line 8): today the only screen for these columns is the GST panel.

### A2. Proposed split (M6 `root_columns`, M5 key)
| subject (proposed) | host | view codes | root_columns | members |
|---|---|---|---|---|
| `finance_lock` | /finance/settings, under LockForm (`page.tsx:132`) | module.finance.view (`page.tsx:24`) | `['locked_before']` | **period_closes** (needs M7, see A4) |
| `finance_gst` | /finance/settings, under GstPanel (`page.tsx:145`) | module.finance.view | `['gst_registered','gst_registration_no']` | — |
| `approval_policy` | /settings/approvals (`app/settings/approvals/page.tsx`) | action.manage_permissions | 4 approval columns | **finance_settings_history** (needs M7). Pattern "one event, two rows": the policy UPDATE and the history INSERT happen in one transaction (`set_approvals_policy.sql:64-80`), as with pricing_formula_history in 1b-3 |

**Columns no panel owns (M):** gst_rate_pct, system_start_date, fy_end_month, fy_end_day, first_fy_end, default_allocation_basis. updated_at and updated_by are technical. Today these six reach no page trail; only `/settings/change-history` shows them. **Decision for Tim:** leave them unowned, or attach the FY columns and system_start_date to the /finance/close year-close trail (they decide year ends), or make GST a "CFO settings" panel that owns all of `v_allowed` (I).

### A3. Approval-policy panel: where it lives, and a conflict (M)
- Route `/settings/approvals`, file `app/settings/approvals/page.tsx`. Guard `requireFunction(FN.approvals)` (`page.tsx:60`) = `action.manage_permissions` (`lib/modules.ts:851`). Action: `app/settings/approvals/actions.ts:69` calls `set_approvals_policy`, which requires `action.manage_permissions` (`set_approvals_policy.sql:39`). /finance/settings only shows a cross-link to it (`page.tsx:101-113`).
- **Conflict:** `docs/forward-queue.md:6571-6572` puts Q25 under **AT-1d** ("设置页(审批方针…);共用一行的设置面板各看各的字段(Q25…锁期那一块再加上月结 / 反结)"). AT-1c (`:6569`) is "ops-finance.md 的 32 条宿主路由", and that list includes /finance/settings (ops-finance §3B). So the AT-1c brief and the forward queue disagree.
  - A natural line: AT-1c does /finance/settings (lock + GST) and /finance/close; AT-1d does /settings/approvals.
  - Splitting it means the M7 mechanism lands in AT-1c, and AT-1d reuses it for `finance_settings_history`. **Tim to rule.**
- **Read-rule problem (M):** the root `finance_settings` is read under `module.finance.view`, `finance_settings_history` under `action.manage_permissions`, and the page under `action.manage_permissions`.
  - Today only `admin` holds manage_permissions, and admin also has finance.view (live role query), so `root_rule='table'` works.
  - Structurally, a manage_permissions holder without finance.view would get TRAIL_NOT_PERMITTED. With M3 `'page'`, that reader would see the root UPDATE as Restricted while the history row is readable, and the post-log fold lets the change_log row speak. **Decision needed** (I).
- Existing `ApprovalsHistory` (`page.tsx:78-82` query, `:129` render; last 10 rows of finance_settings_history) is a pure change history. Under Q26 it should be **replaced** by the trail.

### A4. "The lock's trail also shows month close and reopen" (M + I)
- `close_period` INSERTs period_closes and UPDATEs `finance_settings.locked_before` in one transaction (`close_period.sql:63-67`). `reopen_period` UPDATEs period_closes (reopened_at/by/reason) and locked_before (`reopen_period.sql:28-41`).
- With `root_columns=['locked_before']`, each close or reopen **already** gives a root entry ("lock date moved"). But the notes, the reopen reason and the totals live only in period_closes, and the only pre-log record of a close is the period_closes row (1 live close, period_end 2026-07-31, closed 2026-08-05; finance_settings has no lock history).
- **The registry cannot reach period_closes today (M).** A down-hop needs `table.fk_column::text = parent.id` (`record_trail.sql:116-128`). period_closes has no column pointing at finance_settings, and finance_settings has no column pointing at period_closes, so neither M4 up nor down works.
- **Proposed M7: a "whole-table member of a singleton".** `fk_column NULL` (or `hop='all'`): every row of the table, plus every change_log row of it, matching `match`. Allowed only under an M5 singleton root. It serves period_closes → finance_lock and finance_settings_history → approval_policy. `trail_row_record`'s home walk needs the same case (I).
- **Alternative without a mechanism change:** a constant column `period_closes.settings_id boolean DEFAULT true REFERENCES finance_settings`. Caveat (M, from `record_trail.sql:127`): log-only discovery builds `{fk: 'true'}` as **text**, while the image holds a boolean `true`, so deleted or re-parented rows would not be found. That is the same trap M5 fixed for root keys.
- Year close **does not** move the lock: `close_financial_year` only `SELECT … FOR UPDATE`s finance_settings (`close_financial_year.sql:31`). So it stays out of the settings-page lock panel. See B for /finance/close.

---

## B. Period-end and settings pages
All guards are `requireModule(MOD.finance)` = module.finance.view unless noted (M, grep of each page.tsx). Live counts are as postgres. **Every table below has the `zzz_change_log` trigger and 0 change_log rows** (M). Nothing in this slice has been written since the log began (2026-09-28 23:58:11 +08).

| route · file | guard / extra | root → members (proposal) | M-needs | live |
|---|---|---|---|---|
| /finance/close · `app/finance/close/page.tsx` | :61, can finance.edit :63, finance_reopen :67 | `period_end`: root finance_settings `['locked_before']` + M7 period_closes + M7 year_closes → journal_entries up-hop via `closing_journal_id` and `reversal_journal_id` (FKs, M) → journal_lines (entry_id). Alternatively reuse `finance_lock` and add a ListTrail of `year_close` records | M5 M6 M7 M4 | period_closes 1, year_closes 0 |
| /finance/company · `app/finance/company/page.tsx` | :16; edit can action.finance_settings :20; reads `company_profile_masked` :40 | `company_profile`: root company_profile (`id bool`, M5), no root_columns (one panel owns the whole row: K1–K3). The bank columns are already masked in the trail by mask rules `code:data.view_banking` (`change_log_mask_rules.sql:23-27`). Table read rule is `true` (M) | M5 | 1 row; auditor has finance.view but not view_banking, so auditor sees them masked (M) |
| /finance/revaluation · `app/finance/revaluation/page.tsx` | :46, can finance.edit :48 | No own table. Run = one `journal_entries` row with `source_type='revaluation'` and **source_id NULL** (`revalue_foreign_balances.sql:79-80`). ListTrail over those entries using AT-1c's `journal_entry` subject (lines + reversal) | ListTrail widening | 2 runs (JE-2026-0024, JE-2026-0070), both pre-log |
| /finance/fx (bulk: `/finance/fx/bulk/page.tsx`, :19/:21) | — | **No run row and no journal.** `record_fx_rates_bulk` just loops `record_fx_rate` (`record_fx_rates_bulk.sql:21-35`); the only batch identity is the txid (and the shared `fx_rate_history.changed_at`). Per rate: `fx_rate` subject (root fx_rates, member fx_rate_history `fx_rate_id`, fold "one event, two rows") on /finance/fx/[id]/edit. A batch on /finance/fx needs ListTrail to merge entries **by txid**, and `record_trail` does not return txid (signature `record_trail.sql:36`). Without that, a bulk of N rates is N entries | new (txid merge) | fx_rates 12 |
| /finance/cash-forecast · `page.tsx` | :33, can finance.edit :38 | ListTrail: `cash_forecast` (root cash_forecasts; supersede = INSERT new + UPDATE old in one transaction, `freeze_cash_forecast.sql:32-40`) + `cash_forecast_line` (no FK between the two) | ListTrail widening | 0 / 0 |
| /finance/payroll-payments · `page.tsx` | :18 (RPC accepts finance.edit **or** hr.edit) | Payment journals have `source_type='payroll'` and `source_id = period id` (all 4 live, M). Proposed `payroll_payment` per period: root payroll_periods (read rule **hr.view only**, M) → M3 `page` with module.finance.view; M6 `['cpf_paid_at','cpf_journal_entry_id','deductions_paid_at','deductions_journal_entry_id']`; members payroll_lines (down `payroll_period_id`; read rule finance.view+view_pay or hr.view or self; amounts masked `code_or_self:data.view_pay`) + journal_entries (down `source_id`, match `source_type: payroll`). Gap: a line's non-payment edits would show too, because M6 limits only the root. Fixing that needs **M6 on members** (I) | M3 M6 (+M6-members) | periods 1, lines 1 |
| /hr/payroll/[id] | `requireModule(MOD.hr)` (:32) | canonical period trail. **AT-1d** ("HR 的宿主页", forward-queue:6571) | — | — |
| /finance/processing-costs · `page.tsx` | :18, can finance.edit :20 | processing_cost_entries **is already** a member of `processing_run` (ord 3, history ord 4, `trail_subject_members.sql`). But that subject is processing.view and the root runs read rule is processing.view. Finance page: ListTrail of `processing_cost_settlement` per entry: root processing_cost_entries, M3 `page` (finance.view), M6 `['remitted_at','remitted_journal_entry_id','relieved_at','relief_expense_id']`, up-hops to journal_entries (`remitted_journal_entry_id`) and expenses (`relief_expense_id`) | M3 M6 M4 | 10 entries, 1 relieved (2026-08-05), 0 remitted |
| /finance/wht · `page.tsx` | :33, finance.edit :35, suppliers.view :43 | ListTrail `wht_remittance`: root wht_remittances; journal_entries up `journal_entry_id`; payment_requests down `wht_remittance_id` (FK, M) → approval_log `payment_request` | M4 | 0 |
| /finance/bank · `page.tsx` | :38, finance.edit :40 | ListTrail `bank_transfer`: journal_entries up `journal_entry_id` and `reversal_entry_id`; payment_requests down `transfer_id` and `result_transfer_id` (2 FKs, the port precedent) → approval_log | M4 | 0 |
| /finance/claims · `page.tsx` | :31, finance.edit :36 | `expense_claim`: root expense_claims (read rule finance.view **or own employee**, M); approval_log `expense_claim`; finance_attachments `claim_id` (FK, M); expenses up `expense_id`. Claimant view at `/me` = **AT-1d** (forward-queue:6571 "HR 的宿主页与 /me") | M4 | 4 claims |
| /finance/bank/import · `page.tsx` | :16, finance.edit :18 | ListTrail `bank_import_profile` (including deleted ones) | — | 0 |
| /finance/bank/statements · `page.tsx` | :32 | Deleted statements: either open `/finance/bank/statements/[id]` read-only for data.view_deleted (the §9.10 precedent, preferred) or a ListTrail of deleted rows, using the same subject AT-1c defines for the statement page | — | 2, 1 deleted (BS-2026-0001, 2026-07-30, pre-log; no deleted_by column, so date only) |
| /finance/assets · `page.tsx` | :90, finance.edit :132 | Depreciation run = journal `source_type='depreciation'`, **source_id NULL** (`depreciate_fixed_assets.sql:58-60`); per-asset rows carry `journal_entry_id` (FK, M). `depreciation_run` ListTrail: root journal_entries, members fixed_asset_depreciation (down `journal_entry_id`, home = the asset) + reversal up-hop `reversed_by` | M4 | 0 runs, 0 depreciation rows |
| /finance/journal · `page.tsx` | :41, finance.edit :144 | New-entry requests: anchor `#jr-{id}` (`JournalRequestsPanel.tsx:94`). `journal_request`: approval_log `journal_request`; journal_entries up `result_journal_entry_id` / `target_entry_id` (FKs, M) | M4 | 0 |

**ListTrail vs a per-row trail (I):**
- Use **ListTrail** for small registers with no action card: close (year closes), cash-forecast, bank import profiles, deleted statements, WHT, transfers, revaluation, depreciation runs, processing settlements.
- Use **per-row expandable** where each row is already an action card with an anchor: journal requests (`#jr-id`) and claims (`ClaimDecisionPanel`). That is the Q24 precedent.
- Per-record keys are each table's uuid `id`. The singletons are `'true'`.
- **ListTrail is hard-typed** to `lane|port|company_licence` and two intro keys (`app/components/trail/ListTrail.tsx:28-33`), so it must be widened.
- It costs one `record_trail` call per record (fx and depreciation grow with time).
- Its de-duplication drops only identical entries, so one operation spanning two records shows twice: freeze+supersede, and bulk FX.

**Batch runs (M):** revaluation, depreciation and processing remittance each write **one journal_entries row per run** with `source_id NULL`, identified by `source_type` (`remit_processing_costs.sql:50`). That journal is the run row. Depreciation also has `fixed_asset_depreciation.journal_entry_id`, and remittance has `processing_cost_entries.remitted_journal_entry_id`. FX bulk has no run row at all.

---

## C. Existing history-like sections (Q26 says keep working lists and replace pure change histories)
| section | file:line | verdict |
|---|---|---|
| Close history (with Reopen) | `close/page.tsx:281-286` (`CloseHistoryTable`) | **keep** (Q26 names "close-history tables") |
| Year-close history | `close/page.tsx:327-331` (`YearCloseHistoryTable`) | keep |
| Frozen forecasts register | `cash-forecast/page.tsx:78` (`FrozenForecastsTable`) | keep (working register) |
| Recurring lines | `cash-forecast/page.tsx:74` | keep (editor) |
| Journal requests (open + last 10 decided) | `journal/page.tsx:140-141, 191-196` | keep (request panel) |
| WHT remittances, transfers | `wht/page.tsx:216`, `bank/page.tsx:253` | keep (they carry reverse actions) |
| Approval-policy history | `settings/approvals/page.tsx:78-82, 129` | **replace** (pure change history; an AT-1d page) |
| Lock display | `settings/page.tsx:92-99` | keep (current value) |

---

## D. Pre-log sources and actor kinds (M unless marked)
None of these tables is registered in `trail_prelog_sources.sql` today, except `journal_entries` (created_at/created_by) and `processing_cost_entry_history`. Every by-column is a **login (account)**. Defaults are `auth.uid()` where set; functions write `auth.uid()`; live samples resolve to auth.users. None is an employee (M2 not needed).

| table | proposed sources |
|---|---|
| period_closes | created `closed_at/closed_by`; stamp `reopened_at/reopened_by` + [reopen_reason] |
| year_closes | created `closed_at/closed_by`; stamp `reopened_at/reopened_by` + [reopen_reason, reversal_journal_id] |
| finance_settings_history | created `changed_at/changed_by` (1 live row, 2026-09-22) |
| finance_settings / company_profile | **none**: only `updated_at/updated_by`, which are shared by every panel. GST has no pre-log record at all (gst_registered=true live, no record of who or when) |
| cash_forecasts | created `frozen_at/frozen_by`; stamp `superseded_at`, **by NULL** (`superseded_by` is a forecast id, not a person) + [superseded_by, superseded_reason] |
| cash_forecast_lines | created `created_at`, by NULL (no default; the action doesn't set it, I) |
| expense_claims | created `submitted_at/created_by`; stamp `decided_at/decided_by` + [status, decision_notes, expense_id]; stamp `withdrawn_at` (no withdrawn_by). approval_log has **0 expense_claim rows** live despite 2 decided claims, so the stamp is the only source (a Q11-style exception) |
| journal_requests | created; stamp `withdrawn_at/withdrawn_by` + [status, withdraw_reason]; the decision comes from approval_log |
| wht_remittances, bank_import_profiles, fixed_asset_depreciation | created `created_at/created_by` (+ `deleted_at` stamp, by NULL, on profiles) |
| bank_transfers | created; stamp `reversed_at/reversed_by` + [reversal_entry_id] |
| bank_statements | created; stamp `reconciled_at/reconciled_by`; stamp `deleted_at` (by NULL) |
| payroll_periods / payroll_lines | `cpf_paid_at`, `deductions_paid_at`, `remitted_at` and `relieved_at` are **`date`**, not timestamptz, and `payroll_lines.paid_at` has no by-column. Date-only stamps cannot group with their journal's `created_at`; use the journals' creation instead (already registered) |
| processing_cost_entries | **Correction to ops-finance M10/M11:** remit/relieve do **not** write processing_cost_entry_history. `log_cost_entry_change` logs only create/delete/restore and amount/cost_type/is_estimate changes (`log_cost_entry_change.sql:17-26`). Settlement before the log = the journal or relief-expense creation only |

Read rules worth noting (M): payroll_periods and payroll_requests are hr.view only; processing_cost_entries and processing_runs are processing.view only. Today every module.finance.view role (admin, cfo, finance, cto, gm, cco, auditor) also holds processing.view and hr.view (live role query), so the M3 needs above are structural, not visible today.
