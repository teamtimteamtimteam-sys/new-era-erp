# AUDIT-TRAIL-0 · raw data for three layout mock-ups (LIVE, read-only)

All queries: `psql -X -h aws-1-ap-southeast-1.pooler.supabase.com … -U postgres.wvywpohbwkiinmipmuku`, every session
`BEGIN READ ONLY; … ROLLBACK;`, run as **postgres (rolbypassrls = true)** — so every row count below is the
*unfiltered* count, not what any app reader sees. Query files kept next to this one: `at0/rm_q6.sql … rm_q16.sql`.
Times are shown in Asia/Singapore (= CST +08). Person names resolved with
`employees.preferred_name/legal_name WHERE id = account_person(<auth uid>)`.

---

## a) Purchase order with amendments

### ★ Contradicts the brief: there is NO purchase order with line changes in `purchase_order_history`
**Measured** (rm_q5/rm_q6): `purchase_order_history` has **10 rows over 6 POs; 0 rows** with `line_no` or
`purchase_order_line_id` set; 0 rows with `payment_term_seq` set; 0 rows with `changed_by` null.
`change_type` values present: only `header_update` (6) and `cancelled` (4). The change_log has 0 rows for
`purchase_order*` tables (it started 2026-09-28 23:58). So a PO mock-up with a line change must use an invented line
event, clearly labelled as illustrative.

### Richest real case: PO-2026-0010 (and its re-issue PO-2026-0011)
Supplier **Bosch Rexroth Pte. Ltd.** (short name "Bosch SG"), currency **SGD**, category equipment goods.
Line 1: *not a material* — `asset_id` → fixed asset **FA-2026-0002 "Mobile Discharging Solution"**, qty 1 unit,
estimated unit price 305,550 SGD, amount 305,550.00 SGD, tax code TX, tax 27,499.50 SGD, price source manual.
Payment terms on 0010: #1 "Initial downpayment" 50% on order · #2 "Final payment" 50% on acceptance complete.

| When (SGT) | Who (account → person) | What (source) | Detail |
|---|---|---|---|
| 2026-09-03 16:51:48 | admin@swm-os.test → **Tim** (EMP-2026-0002) | PO created (`purchase_orders.created_at/by`) | 1 line, total 305,550.00 SGD |
| 2026-09-03 16:51:48 | **Tim** | Auto-approved (`approval_log` seq 284, decision `auto_approved`, 305,550.00 SGD) | note (zh, machine): "审批流未启用(finance_settings.approvals_enabled = false)—— 系统直接盖章,没有人做过这个决定" = *approvals were off; the system stamped it, nobody decided* |
| 2026-09-03 16:51:48 | **Tim** | `header_update` (purchase_order_history) | estimated total 0 → 305,550.00 SGD (creation artefact: same microsecond as created_at); order date 2026-09-03, incoterm CIF, expected delivery 2027-02-01, FX 1 — all old = new (the row snapshots unchanged fields too) |
| 2026-09-08 10:41:11 | sandra@evoltrya.test → **Sandra** (EMP-2026-0004) | `header_update` | **order date 2026-09-03 → 2026-09-08; incoterm "CIF" → "CIF or otherwise specified"; notes (empty) → "Payment schedule 50% Advanced, 40% upon delivery, 10% upon completion of training"**; total unchanged 305,550.00 SGD. Reason: *"To change the payment schedule, order date and leaving Incoterms open"* |
| 2026-09-08 10:47:31 | **Sandra** | `cancelled` | Reason: *"Too many errors - will redo one"* (also `purchase_orders.cancelled_at/by/cancel_reason`) |
| 2026-09-08 10:51:38 | **Sandra** | PO-2026-0011 created + auto-approved (approval_log seq 285) + creation `header_update` (0 → 305,550.00 SGD) | 3 payment terms: 50% "First payment: downpayment" on order · 40% "Second payment: Upon delivery" on acceptance complete · 10% "Final payment: training completion" on training complete |

Observations for the mock-up (Measured from the rows above):
* The payment-schedule change Sandra's reason names was **never recorded as a change** — PO-2026-0010's payment terms
  still read 50/50, no `payment_term_seq` history row exists; she wrote it into Notes, cancelled, and re-issued.
* The "which fields changed" of a `header_update` must be computed by diffing old vs new (unchanged fields are stored too).
* Other PO rows (for filler): PO-2026-0006 (Shanghai Yidong Battery Recycle Co. / "Yidong Recycle", USD, line 1
  "Special Battery Material" 50 kg) cancelled 2026-08-17 20:04:44 by Tim, reason "Test"; PO-2026-0007 (Bosch SG) header
  total 0 → 400,000.00 SGD 2026-08-21 15:33:49 by Tim; PO-2026-0008 cancelled 2026-09-03 11:57:35 by Tim "GST not
  included"; PO-2026-0009 cancelled 2026-09-03 16:50:48 by Tim "Wrong Calculation".
* The current PO page history block (`app/purchasing/orders/[id]/page.tsx:855-887`) shows time, change type, line #,
  term #, quantities, reason — but **not `changed_by`** and not the old/new dates/incoterm/notes/amount.

---

## b) Processing run with the richest life: **PROC-2026-0164**
Selection (rm_q9, Measured): of **14** processing_runs, ranked by inputs+outputs+cost entries+cost history+approvals;
0164 is the only one with 2 outputs + 2 cost entries + 2 cost-history rows + allocation + capitalisation.
**0 runs have any `processing_run_losses` row** (table exists; 0 rows joined). **0 approval_log rows** for any run
subject. **0 change_log rows** for `processing%` / `inventory_movements`.

Run header: process date 2026-08-10, status committed, input 300, output 260, loss 40 (only as `loss_qty`, no category
rows), allocation basis metal_value, material cost 444.00, process cost 500.00, total 944.00, capitalised 944.00
(base currency SGD; all four are masked by `data.view_prices`). No work order, no equipment, no operation type.

| # | When (SGT) | Who | Step | Source columns |
|---|---|---|---|---|
| 1 | 2026-08-10 17:36:39 | Tim | Run recorded (committed) | processing_runs.created_at/by |
| 2 | 17:36:39 | *(no actor column)* → Tim via movement | Consumed 300 kg of **IN-2026-0001** (NMC Cathode Foil) | processing_inputs.created_at (no created_by); inventory_movements `processing_consume` −300 created_by Tim |
| 3 | 17:36:39 | *(no actor column)* → Tim via batch/movement | Produced **OUT-2026-0186** NMC Cathode Foil 200 kg, and **OUT-2026-0187** Special Battery Material 60 kg | processing_outputs.created_at (no created_by); output_batches.created_by Tim; movements `processing_produce` +200 / +60 by Tim |
| 4 | 17:36:59 | Tim | Labour cost added: 200.00 (actual) → journal **JE-2026-0043** "Cost PROC-2026-0164 labour" | processing_cost_entries + processing_cost_entry_history (`create`) + journal_entries |
| 5 | 17:37:12 | Tim | Electricity cost added: 300.00 (estimate) → **JE-2026-0044** | same |
| 6 | 17:38:52 | Tim | Cost allocated (metal value): OUT-2026-0186 809.14 (4.0457/kg), OUT-2026-0187 134.86 (2.2477/kg) and capitalised 944.00 → **JE-2026-0045** "Capitalize PROC-2026-0164" | processing_runs.allocated_at/by, processing_outputs.allocated_cost_base/unit_cost_base (no time/actor of their own), journal_entries |
| — | 17:38:52 | Tim | "last updated" | processing_runs.updated_at/by — says only *someone last touched it*, not what |

Steps with **no actor and/or no time of their own** before the change log (Measured from the column lists, rm_q5/rm_q10):
* `processing_inputs` / `processing_outputs`: `created_at` only, **no created_by**; later cost figures on outputs
  (`allocated_cost_base`, `unit_cost_base`, `cost_incomplete`) carry **no time and no actor**.
* Allocation-basis change: `allocation_basis_changed_at` has **no `_by`**.
* Status transitions: there is **no status timestamp** except `allocated_at` and `deleted_at` (reversal); nothing records
  when/who moved draft→committed other than `created_*`.
* Any edit to run header fields (notes, quantities): only `updated_at/by` — the *before* value is lost.
* Across all 14 runs: 1 run has `created_by` null; 3 of 4 deleted/reversed runs have `deleted_by` null (rm_q12).
* Losses by category: 0 rows ever written; only the scalar `loss_qty`.

Alternative with a reversal (demo data, delete_reason names it a demo): **PROC-2026-0494** — created, allocated
and capitalised 2026-08-31 11:54:13 by Tim (cost electricity 123.45 → JE-2026-0072; JE-2026-0073 "Capitalize"),
reversed 11:54:34 by Tim (JE-2026-0074 "REVERSAL: Rollback PROC-2026-0494"; reason "ZZ-PROCCOST1 线上演示:验收"冲销把成本拿回去"").
0 inventory movements joined to it.

---

## c) Role-permission change

### Role **cco** — "Commercial & People" (not a system role)
* roles.created_at 2026-09-04 20:13:42, updated_at 2026-09-07 14:57:56, `updated_by` **null** (no actor).
* All **41** current grants carry `role_permissions.created_at = 2026-09-28 19:00:35.052778`, created_by
  admin@swm-os.test → **Tim** (rm_q13). This is `set_role_permissions` rewriting the whole set: **what was removed or
  already there before 19:00:35 is not recoverable** — it predates change_log (starts 23:58:11 the same day), and
  role_permissions has no history table.
* Grants (code → English label from `permissions.name_en`):
  - Actions: Decide leave requests and medical claims · Performance reviews & KPI · Contracts and their terms ·
    Sell directly from an output batch · Request shipping releases · Raise equipment-and-goods POs
  - Data: View sales prices & costs · View purchase prices · View pay · View company bank details · View sales records ·
    View performance review content · View deleted records
  - Modules (view/edit): Suppliers v/e · Customers v/e · Materials v/e · Pricing v/e · Purchasing v/e · Inbound v/e ·
    Output v/e · Processing v/e · Inventory v/e · Stocktakes v/e · Finance (view) · HR v/e · Tasks v/e ·
    Sales orders v/e · Logistics (view)

### ★ Label source contradicts the brief
The roles screen does **not** label permission codes from `messages/en.ts`. `app/settings/roles/PermissionMatrix.tsx:88-95`
and `:329` render `permissions.name_en` / `name_zh` from the **database** (module rows strip the trailing "(view)").
Measured: 72 permission codes, 0 with empty `name_en`. So an English trail can label a permission code with one join.

### change_log rows for role_permissions (146 rows, Measured)
* seq 2, 3 — 2026-09-28 23:58:11, no session · postgres (the HISTORY-1 migration): granted **data.view_change_log**
  to **admin** ("System Administrator") and **cfo** ("CFO").
* seq 5–76 — 72 INSERTs 2026-09-29 00:27:30.446–.484, no session · service_role: smoke role
  `probe-smoke-all-1790612847744` "smoke (all codes)" (roles row seq 4 INSERT 00:27:28, seq 108 DELETE 00:53:49)
  granted every one of the 72 codes, e.g. seq 5 "Anonymise an employee record", 6 "Apply and unapply assay results",
  7 "Approve performance reviews", 8 "Write off batches", 9 "Bulk import master data", 10 "Contracts and their terms",
  11 "Set customer credit limits and holds", 12 "Decide leave requests and medical claims", 13 "Sell directly from
  an output batch", 14 "Reopen closed months; close and reopen financial years", 15 "Finance settings, chart of
  accounts, currencies and company details", 16 "Performance reviews & KPI", 17 "Issue certificate of destruction",
  18 "Manage roles & permissions", 19 "Metal prices, indices and the quote threshold", 20 "Approve site-staff overtime",
  … 70 "Stocktakes (edit)", 71 "Stocktakes (view)", 72 "Suppliers (edit)", 73 "Suppliers (view)", 74 "Tasks (edit)",
  75 "Tasks (view)", 76 "Tasks (read others' personal)".
* 72 DELETEs 2026-09-29 00:53:49.130–.159 (after the role DELETE at .105 — cascade), no session · service_role.
* `row_key` is `{role_id, permission_code}` — the role is a uuid; the role's name survives only in the roles DELETE
  image (seq 108 `old`), because the role row itself is gone.
* user_roles seq 77 (INSERT 00:27:31) / 98 (DELETE 00:53:42): the smoke role was given to account
  b5116648-… (granted_by the same account).

---

## The 4 change_log rows with actor_kind = 'user' (Measured, rm_q2/rm_q16)
All four: actor_account **b5116648-4e1d-4249-b055-d71a984b57d5**, db_role authenticated, `actor_employee` **null**.
That account **no longer exists in auth.users** (0 rows) and `account_person()` returns null — it is the smoke test's
temporary login. The change-history page would show "account no longer exists" / "no employee record".
There are **0 `auth.users` (ACCOUNT_*) rows** in change_log: the smoke account was created and deleted outside the
accounts screen (record_account_event is only called from there — Inferred from db/functions/record_account_event.sql).

| seq | SGT | Table · op | What it is |
|---|---|---|---|
| 81 | 2026-09-29 00:27:36 | performance_reviews · INSERT | draft probation review 2026-01-01 → 2026-03-31 for smoke employee ZZ-SMOKE-1 (e02613c7…) |
| 82 | 00:27:37 | performance_reviews · UPDATE | reviewer_employee_id null → ZZ-SMOKE-2 (0f794998…); updated_at |
| 92 | 00:50:50 | cod_verification_failures · DELETE | pruned failure #136 (failed 2026-09-28 19:18:17) from the COD-verification throttle window |
| 93 | 00:50:50 | cod_verification_failures · INSERT | new failure #137 — a failed certificate-of-destruction token lookup |

(All three smoke employees ZZ-SMOKE-1..3 are named "【SMOKE 冒烟脚本临时行 · 勿动 · 随时可删】 n"; they, the review, the
role and the contracts were deleted by service_role at 00:53:40–49.) `cod_verification_failures` is the one table with a
change_log trigger but **no SELECT policy** at all (rm_q14/15).
