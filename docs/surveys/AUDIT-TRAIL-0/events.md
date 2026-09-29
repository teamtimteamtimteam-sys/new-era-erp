# AUDIT-TRAIL-0 · Key-event catalogue (2026-09-29)

Tim's ruling: a key step reads as a **business event**, not a field change
("Processing completed", not "status: committed"). This file enumerates the closed space of state that can produce such
an event, what performs each transition, what English the UI already has, and the recommended wording.

Scratch artefacts (all in `at0/ev/`): `enums.py` + `enums.json` (repo CHECK parse), `live_checks.txt` / `live_enums.json`
(live CHECK parse), `live_enums.txt` (enum types), `pairs.txt` (lifecycle `_at/_by/_on` groups), `trans.py` + `trans.txt`
(who writes which value), `en_flat.tsv` (messages/en.ts flattened, 8,225 leaf keys), `en_match.txt` (value → key matches).

Live queries ran as `postgres` (rolbypassrls = true) inside `BEGIN READ ONLY … ROLLBACK`.

---

## 0. Headline numbers

| What | Number | Method | Status |
|---|--:|---|---|
| `table.column` pairs with a `CHECK (col IN (…))` / `= ANY(ARRAY[…])` enum in `db/tables/*.sql` | **161** on 107 tables | `ev/enums.py` (regex over 240 files, comments stripped, first definition per table.col) | Measured |
| Same, in live `pg_constraint` | **172** | `ev/q1.sql` → `live_checks.txt`; 161 repo pairs all present live, 11 live-only (`approval_log.level`, `kpi_cycles.gate`, `purchase_order_lines.price_status`, `kpi_entries.score_kind`, `work_order_expected_outputs.basis`, `accounts.cash_flow_section`, `assay_results.weight_basis`, `asset_disposal_requests.bank_account`, `expenses.wht_payee_residence`, `suppliers.tax_residence`, `task_nodes.depth`) — none is a lifecycle column except `kpi_cycles.gate` (lock gate M3/M6) | Measured |
| …of which **lifecycle state** columns (name ∈ status, stage, state, approval_status, match_status, pricing_status, payment_status, employment_status) | **46** | filter over `enums.json` | Measured |
| + enum-typed lifecycle column (`suppliers.status`, type `supplier_status`, 8 labels) | **1** | `pg_type.typtype='e'` join `pg_attribute` → 1 row (`live_enums.txt`) | Measured |
| + FK-dictionary lifecycle column (`output_batches.state` → `output_batch_states`, 3 codes) | **1** | read of `db/tables/output_batches.sql` + `SELECT * FROM output_batch_states` (3 rows) | Measured |
| **= lifecycle state columns in the closed space** | **48** | sum | Measured |
| Free-text `status` with no CHECK and no writer (`customers`, `materials`, `inbound_batches.status`, `output_batches.status`) | 4 — every live row is `draft` (7 / 9 / 24 / 20 rows) | `ev/q2.sql` `GROUP BY status` | Measured — **not events; exclude** |
| **Event-vocabulary** enum columns (decision, change_type, action, op, movement_type, milestone, entry_type, outcome, event_type, source_type, grant_type) | **20** | filter over `enums.json` | Measured |
| `kind` enums on request/document tables (select which event a request produces) | 11 | filter over `enums.json` | Measured |
| Lifecycle timestamp groups (`<stem>_at/_by/_on`, excl. `created_*`/`updated_*`), live | **211** (table, stem) groups on the tables listed in `pairs.txt`; top stems: deleted 44, decided 16, withdrawn 13, changed 13 (history tables), issued 11, superseded 7, executed 6, closed 5 | `ev/q3.sql` → `pairs.txt` | Measured |
| …of which carry a business event (excl. `changed_*` on history tables 13, `occurred_at` 3, schedule/date-range stems starts/ends/expires/granted_on/reminder/old_/new_ 9, `read_at` 1, `redacted_at` 1, `insured_by` (a party, not an actor) 1) | **183** | 211 − 28 | Measured (subtraction over `pairs.txt`) |
| Functions that write `approval_log` via `record_approval_decision` | **42** | regex over `at0/funcs.csv` (comments stripped) | Measured |
| **Catalogue rows (§5)** | **233** | `grep -c '^| [A-Z]' events.md` over §5 tables | Measured |
| …needing NEW wording (source `NEW` or `STATE`) | **196** (`NEW` 152 + `STATE` 44) | `grep -c` on the source column | Measured |
| …where an existing key already reads as a past-tense event (`EXISTS`) | **37** | same | Measured |

**Findings that contradict the brief (all Measured):**

1. **There is no "running → completed" processing status.** `processing_runs.status ∈ {committed, reversed}` and a run is
   written in one transaction by `commit_processing_run` (INSERT with `status='committed'`). There is no started/running
   row state anywhere in `processing_runs`. The only "started/in progress" notion is `inbound_batches.stage`
   (`待加工` → `加工中` → `已加工完`, Chinese values), which `commit_processing_run` sets from `remaining_qty`
   (`CASE WHEN v_new_remaining <= 0 THEN '已加工完' ELSE '加工中' END`). So "Processing started" is a *batch* event
   (first partial consumption), "Processing completed" is the run INSERT. The brief's example must be re-mapped (§5 B).
2. **There is no separate weighing step.** No function name or table carries weighbridge/gross/tare data (`grep -l weighbridge|gross_weight|tare db/tables` → only `sales_settlements` and `finance_attachments.doc_type='weighbridge'`). The weight is captured once at receipt (`inbound_batches.quantity` / `declared_qty`) and optionally re-based dry vs as-received by assays (`assay_results.weight_basis`, `moisture_pct`). "Weighed" can only be the receipt event or a weighbridge attachment upload.
3. **Allowed but never written values** (regex over every UPDATE/INSERT in `funcs.csv` + `grep` of `app/**/*.ts`):
   `approval_log.decision = 'countersigned'` (no writer); `medical_claims.status = 'paid'` (no writer — `pay_medical_claim`
   only sets `expense_id`; the UI derives "Paid" via `claims.state_paid`); `kpi_cycles.status` (no writer in functions or
   app; only `locked_at/by` is written); `contracts.status ∈ {expired, terminated}` (no writer; only `draft`→`active` via
   `terms_request_execute_internal` and `active`→`suspended` via a direct app UPDATE in
   `app/components/pricing/termsRequestActions.ts:64-69`); `gst_periods.status` has no writer that sets `open`→`approved` other than `gst_filing_execute_internal`.
   These must still have wording (a manual SQL fix can set them) but will not appear in practice.
4. **Status changes done by direct app UPDATE, not an RPC** (so no domain history row, only `change_log`): `tasks.status`
   (`app/tools/tasks/actions.ts:71`), `contracts.status → suspended`, `review_cycles.status → closed`
   (`app/hr/reviews/actions.ts:279`), `container_documents.status` (`app/logistics/containers/[id]/actions.ts:81`),
   `company_compliance.status` (`app/purchasing/licences/licenceActions.ts:69`), and ~20 `deleted_at` soft-deletes (§6.1).
5. `reopen_purchase_order` and `close_purchase_order` write **no** `purchase_order_history` row; the PO history vocabulary
   has no `created`, `approved`, `closed`, `reopened` or `receiving` value. The PO's lifecycle today is only reconstructible
   from `approval_log` + `po_issues` + `change_log`.

---

## 1. The closed space — lifecycle state columns (48)

Values from the CHECK; "writers" from `ev/trans.txt` (regex: every `UPDATE <table> … SET <col> = '<v>'` and every
`INSERT INTO <table>(… col …)` in `funcs.csv`, comments stripped) plus the app-code grep in finding 4.

| # | table.column | allowed values | transitions actually performed (function → new value) | existing en.ts labels |
|--:|---|---|---|---|
| 1 | purchase_orders.status | draft, confirmed, receiving, closed, cancelled | `create_purchase_order` INSERT draft (approvals on) / confirmed (off); `approve_purchase_order` draft→confirmed; `advance_po_on_receipt` (trigger on inbound_batches INSERT) confirmed→receiving; `close_purchase_order` →closed; `reopen_purchase_order` closed→receiving (has receipts) / confirmed (none); `cancel_purchase_order` →cancelled | `purchasing.status.{draft:'Draft',confirmed:'Confirmed',receiving:'Receiving',closed:'Closed',cancelled:'Cancelled'}` |
| 2 | purchase_orders.approval_status | pending, approved, rejected | `create_purchase_order` INSERT pending/approved; `approve_purchase_order` →approved (+approved_at/by); `reject_purchase_order` →rejected; `void_approval_on_amount_increase` approved→pending (+approval_log `approval_voided`) | `purchasing.approvalState.{pending:'Awaiting approval',approved:'Approved',rejected:'Rejected'}` |
| 3 | sales_orders.status | draft, confirmed, partially_shipped, shipped, closed, cancelled | `create_sales_order` INSERT draft; `set_sales_order_status` draft→confirmed/cancelled, confirmed→cancelled, shipped→closed (the only moves its CASE allows); `ship_order` →partially_shipped/shipped (`sales_order_fulfilment_status`); `amend_sales_order` recomputes partially_shipped↔shipped | `sales.status.*` ('Draft','Confirmed','Partially shipped','Shipped','Closed','Cancelled'); imperatives `sales.action.{confirmed:'Confirm order',closed:'Close order',cancelled:'Cancel order'}` |
| 4 | quotes.status | draft, issued, declined, converted | INSERT draft (no RPC — `quotes` has no INSERT function; app insert + `trg_quote_history_created`); `record_qt_issue` →issued; `decline_quote` →declined; `convert_quote` →converted | `quotes.status.*` ('Draft','Issued','Declined','Converted') |
| 5 | work_orders.status | draft, released, closed, cancelled | `create_work_order` INSERT draft; `release_work_order` →released (+approval_log work_order approved); `close_work_order` →closed; `cancel_work_order` →cancelled | `processing.wo.status.*` ('Draft','Released','Closed','Cancelled') |
| 6 | processing_runs.status | committed, reversed | `commit_processing_run` INSERT committed; `rollback_processing_run_internal` committed→reversed (+deleted_at) | `processing.status.{committed:'Committed',reversed:'Reversed'}` |
| 7 | inbound_batches.stage | 待加工, 加工中, 已加工完 | `create_inbound_batch` INSERT 待加工; `commit_processing_run` →加工中 (partly consumed) / →已加工完 (remaining ≤ 0); `rollback_processing_run_internal` →待加工 (fully restored) / →加工中 | `inbound.stage.{toProcess:'To Process',processing:'Processing',processed:'Processed'}` (keyed by English alias, not by the stored value) |
| 8 | inbound_batches.pricing_status | unpriced, provisional, final | INSERT default provisional; `receipt_price_post_internal` →final | `assay.pricingStatus.{unpriced:'Unpriced',provisional:'Provisional',final:'Final'}` |
| 9 | output_batches.state (FK dict) | 库存中, 部分售出, 已售罄 | INSERT 库存中 by `commit_processing_run`; `record_output_sale` / `ship_order` →部分售出/已售罄; `post_stocktake` | `output.state.{inStock:'In Stock',partiallySold:'Partially Sold',soldOut:'Sold Out'}`; dictionary `output_batch_states.name_en` ('In stock','Partially sold','Sold out') |
| 10 | stocktakes.status | open, posted, cancelled | `open_stocktake` INSERT open; `post_stocktake` →posted (+approval_log stocktake approved); `cancel_stocktake` →cancelled | `stocktakes.status.*` ('Open','Posted','Cancelled') |
| 11 | suppliers.status (enum) | draft, pending_review, approved, rejected, active, suspended, blacklisted, archived | `set_supplier_status` only; 18 legal moves from `supplier_status_moves()` (draft→pending_review/archived; pending_review→approved/rejected/draft; rejected→draft/archived; approved→active/suspended/archived; active→suspended/blacklisted/archived; suspended→active/blacklisted/archived; blacklisted→archived; archived→draft); trigger `log_supplier_status_change` writes supplier_status_history | `suppliers.status.*` (8, e.g. 'Pending Review','Blacklisted'); imperatives `suppliers.statusAction.*` ('Submit for Review','Approve','Return to Draft','Activate','Suspend','Blacklist','Archive') |
| 12 | contracts.status | draft, active, suspended, expired, terminated | app INSERT draft (`app/contracts/new/actions.ts`); `terms_request_execute_internal` draft→active; app UPDATE active→suspended; expired/terminated: no writer | `contracts.status.*` |
| 13 | company_compliance.status | active, suspended, revoked | app upsert (`licenceActions.ts:69-70`), any value | `company.licence.status.*` |
| 14 | container_documents.status | pending, received, not_applicable | app insert pending; app update →received / not_applicable (+na_reason) | `logistics.statusPending:'Pending'`, `logistics.statusReceived:'Received'`, `logistics.statusNa:'Not applicable'` |
| 15 | certificates_of_destruction.status | pending, issued, void | INSERT pending; `issue_cod` →issued (+cod_issues); `void_cod_internal` issued→void | `cod.statusPending:'Ready to issue — not yet sent'`, `cod.statusIssued:'Issued'`, `cod.statusVoid:'Voided'` |
| 16 | invoices.status | issued, void | `create_invoice` / `create_order_invoice` INSERT issued; `void_invoice_internal` →void | `invoice.status.{issued:'Issued',void:'Void'}` |
| 17 | payments.status | posted, reversed | `record_payment_internal` INSERT posted; `reverse_payment_internal` →reversed | `finance.status.{posted:'Posted',reversed:'Reversed'}` |
| 18 | journal_entries.status | posted, reversed | `post_journal_entry` INSERT posted; `reverse_journal_entry_internal` →reversed | same `finance.status.*` |
| 19 | expenses.status | posted, reversed | `record_expense` INSERT; `reverse_expense` →reversed | `finance.status.*` |
| 20 | freight_documents.status | posted, reversed | `record_freight_document` / `record_export_freight_document` INSERT; `reverse_freight_document` →reversed | `finance.status.*` |
| 21 | expenses.payment_status | paid, unpaid | set at INSERT only | `expense.status.{paid:'Paid',unpaid:'Unpaid'}` |
| 22 | freight_documents.payment_status | paid, unpaid | set at INSERT only | `finance.freight.payment.{paid:'Paid',unpaid:'Unpaid (payable)'}` |
| 23 | bank_statements.status | open, reconciled | `import_bank_statement` INSERT open; `reconcile_statement` →reconciled; `unreconcile_statement` →open | `bank.status.*` |
| 24 | bank_statement_lines.match_status | unmatched, matched, ignored | `import_bank_statement` INSERT; `match_bank_line` →matched; `unmatch_bank_line` →unmatched; `ignore_bank_line` →ignored; `unignore_bank_line` →unmatched | `bank.lineStatus.*` |
| 25 | gst_periods.status | open, approved, filed | `open_gst_period` INSERT open; `correct_gst_return` INSERT open; `gst_filing_execute_internal` →approved; `record_gst_filing` →filed | `gstFiling.periodStatus.{open:'Open',awaiting:'Waiting for the CFO',approved:'Approved, not filed yet',filed:'Filed'}` |
| 26 | fixed_assets.status | active, disposed | `create_fixed_asset` / `record_expense` INSERT active; `dispose_fixed_asset_internal` →disposed | `assets.status.*` |
| 27 | payroll_periods.status | draft, posted | `post_payroll_period_internal` →posted; `unpost_payroll_period_internal` →draft | `hr.payrollStatus.*` |
| 28 | attendance_periods.status | open, complete | `open_attendance_period` INSERT; `complete_attendance_period` →complete; `reopen_attendance_period` →open | `attendance.status.*` |
| 29 | employees.employment_status | probation, active, notice, separated | `approve_review` probation→active; app edit (`app/hr/employees/actions.ts:66-74` derives employment_history change_type) | `hr.employmentStatus.*`; `org.status.*` ('serving notice','left') |
| 30 | performance_reviews.status | draft, self_review, submitted, approved, acknowledged, void | `open_probation_review`/`open_review_cycle` INSERT draft; `open_for_self_assessment` →self_review; `submit_review` →submitted; `approve_review` →approved; `acknowledge_review` →acknowledged; `void_review` →void | `reviews.status_*` ('Self-assessment','Submitted','Approved','Acknowledged','Void') |
| 31 | review_cycles.status | draft, open, closed | app insert; `open_review_cycle` →open; app UPDATE →closed | `reviews.cycleStatus_*` |
| 32 | kpi_cycles.status | draft, open, closed | **no writer** | none |
| 33 | leave_requests.status | pending, approved, rejected, cancelled | `submit_leave_request` INSERT pending; `decide_leave_request` →approved/rejected; `cancel_leave_request` →cancelled | `leave.status_*` |
| 34 | medical_claims.status | submitted, approved, rejected, paid, withdrawn | `submit_medical_claim` INSERT; `decide_medical_claim` →approved/rejected; `withdraw_medical_claim` →withdrawn; paid: **no writer** | `claims.state_*` (incl. derived 'Awaiting expense','Expense raised','Part paid') |
| 35 | expense_claims.status | submitted, withdrawn, approved, rejected | `submit_expense_claim`; `decide_expense_claim`; `withdraw_expense_claim` | `expenseClaims.status_*` (submitted 'Waiting') |
| 36 | overtime_batches.status | draft, submitted, approved, rejected, reversed, discarded | `create_overtime_batch` INSERT draft; `submit_overtime_batch` →submitted; `withdraw_overtime_batch` submitted→draft; `decide_overtime_batch` →approved/rejected (`p_decision`); `reverse_overtime_batch` →reversed; `discard_overtime_batch` →discarded | `overtime.status_*` (rejected 'Sent back') |
| 37 | payment_requests.status | submitted, withdrawn, approved, rejected, paid | 6 submit_* INSERT submitted or approved (auto); `decide_payment_request`; `withdraw_payment_request`; `pay_payment_request` →paid | `finance.paymentRequests.status.*` ('Awaiting approval','Approved — ready to pay','Paid',…) |
| 38 | payroll_requests.status | submitted, withdrawn, approved, rejected, executed | `submit_payroll_request`; `decide_payroll_request`; `withdraw_payroll_request`; `post_payroll_period`/`unpost_payroll_period` →executed | `hr.payrollRequest.status.*` (executed 'Done') |
| 39 | receipt_price_requests.status | submitted, approved, rejected, withdrawn | `receipt_price_submit_internal` INSERT (auto-approve path); `decide_receipt_price_request`; `receipt_price_withdraw_internal` | `inbound.priceRequest.status.*` ('Waiting for the CFO','Approved and posted',…) |
| 40 | invoice_requests.status | same 4 | `invoice_request_submit_internal`; `decide_invoice_request`; `withdraw_invoice_request` | `finance.invoiceRequest.status.*` |
| 41 | journal_requests.status | same 4 | `journal_request_submit_internal`; `decide_journal_request`; `withdraw_journal_request` | `finance.journalRequest.status.*` |
| 42 | shipping_releases.status | same 4 | `submit_shipping_release`; `decide_shipping_release`; `withdraw_shipping_release` | `sales.release.status.*` (lower-case 'waiting','approved',…) |
| 43 | warehouse_requests.status | same 4 | `warehouse_request_submit_internal`; `decide_warehouse_request`; `withdraw_warehouse_request` | `warehouseRequest.status.*` |
| 44 | terms_requests.status | same 4 | `terms_request_submit_internal`; `decide_terms_request`; `withdraw_terms_request` | `termsRequest.status.*` (lower-case) |
| 45 | salary_change_requests.status | same 4 | `submit_salary_change_request`; `decide_salary_change_request`; `withdraw_salary_change_request` | `salaryChange.status.*` (lower-case) |
| 46 | asset_disposal_requests.status | same 4 | `submit_asset_disposal_request`; `decide_asset_disposal_request`; `withdraw_asset_disposal_request` | `assetDisposal.status.*` (lower-case) |
| 47 | gst_filing_requests.status | same 4 | `submit_gst_filing_request`; `decide_gst_filing_request`; `withdraw_gst_filing_request` | `gstFiling.status.*` |
| 48 | tasks.status | todo, in_progress, done | app UPDATE only (`app/tools/tasks/actions.ts:71`) | `tasks.status.*` ('To Do','In Progress','Done') |

Request-kind enums that choose which event a request executes (all Measured from `enums.json` + writers in `trans.txt`):
`payment_requests.kind` (payment_out, payment_reversal, bank_transfer, bank_transfer_reversal, wht_remittance, wht_remittance_reversal — labels `finance.paymentRequests.kind.*`), `warehouse_requests.kind` (write_off_inbound, write_off_output, rollback, cod_void — labels only as imperatives `warehouseRequest.trigger.*` 'Request write-off' …), `terms_requests.kind` (formula_create, formula_change, formula_reactivate, contract_activate — `termsRequest.openTitle.*`), `invoice_requests.kind` (credit_note, void — `finance.invoiceRequest.kind.*`), `journal_requests.kind` (entry, reversal — `finance.journalRequest.kind.*` lower-case), `payroll_requests.kind` (post, reversal — `hr.payrollRequest.kind.*` 'Post','Unpost').

---

## 2. Event vocabularies already in the history / event tables

| table.column | values | writer(s) | English used today |
|---|---|---|---|
| approval_log.decision (+ subject_type × 23, level 1/2) | submitted, approved, rejected, acknowledged, countersigned, auto_approved, approval_voided | `record_approval_decision`, called from 42 functions (see §3) | **No per-decision label.** Subject labels exist: `finance.approvals.subject_*` (plural, e.g. 'Purchase orders', 'Write-offs, rollbacks and certificate voids'). `/me` renders `me.decidedBy` / `me.cancelledBy`. Batch trail uses `auditTrail.kind.approval` 'Approval decision'. Live: 15 rows — 11 purchase_order auto_approved, 1 work_order auto_approved, 2 leave approved, 1 medical approved (`ev/q2.sql`). |
| purchase_order_history.change_type | header_update, line_update, line_add, line_remove, cancelled, payment_term_add/update/remove | triggers `trg_po_history_header/line/payment_term`, `cancel_purchase_order` | `purchasing.amend.change.*` ('Header changed','Line added','Instalment removed','Cancelled',…) |
| sales_order_history.change_type | created, confirmed, closed, cancelled, line_added, line_changed, line_removed, issued, reserved, released, invoiced, invoice_voided, shipped, header_update, line_update, line_add, line_remove, credit_noted, converted_from_quote | 12 functions + `trg_so_history_header/line` | `sales.changeType.*` all lower-case ('created','amended — line added','credit note raised','converted from quote',…) |
| quote_history.change_type | created, issued, declined, converted | `trg_quote_history_created`, `record_qt_issue`, `decline_quote`, `convert_quote` | `quotes.changeType.*` lower-case ('converted to order') |
| work_order_history.change_type | created, released, closed, cancelled, header_update, line_add/update/remove, expected_add/update/remove | `create/amend/release/close/cancel_work_order` | `processing.wo.changeType.*` lower-case ('expectation added') |
| task_history.change_type | 14 values | 5 triggers | `tasks.history.type.*` ('Step ticked','Participant taken off','Owner transferred',…) — already event-shaped |
| employment_history.change_type | hired, confirmed, promotion, transfer, type_change, status_change, separated, salary_change, category_change | `approve_review`, `salary_change_execute_internal`, `set_initial_salary`, app insert | `hr.changeType.*` ('Hired','Promotion','Employment type change',…) |
| employee_account_history.action | linked, unlinked | `link_additional_account`, `unlink_additional_account` | none (no reader) |
| fixed_asset_history.change_type | created, updated | trigger `trg_fixed_assets_history` | `assets.history.type.{created:'Card created',updated:'Changed'}` + per-field `assets.history.field.*` |
| fx_rate_history.action | created, corrected, withdrawn | `record_fx_rate`, `withdraw_fx_rate` | none (no reader) |
| pricing_formula_history.change_type | create, update, delete, restore, metal_set, metal_clear | triggers `log_pricing_formula_change`, `log_pricing_formula_metal_change` | none (no screen) |
| processing_cost_entry_history.change_type | create, update, delete, restore | trigger `log_cost_entry_change` | only `auditTrail.kind.cost_entry_change` 'Processing cost entry changed' |
| supplier_status_history (from_status, to_status) | the 18 supplier moves | trigger `log_supplier_status_change` | none (no screen); status nouns from `suppliers.status.*` |
| finance_settings_history (4 approval columns, old/new) | — | `set_approvals_policy` | `finance.approvals.history*` ('Changes to this policy', `historyArrow` '{field}: {from} → {to}', 'in force'/'not in force') — field-change style |
| customer_credit_history (credit_limit, credit_hold old/new) | — | trigger `log_customer_credit_change` | none (no reader) |
| price_history (old/new unit_price) | — | `reprice_inbound_batch` | `auditTrail.kind.price_change` 'Price change' |
| sales_attribution_log | — | `attribute_sale_customer` | `auditTrail.kind.attribution` 'Credit attribution' |
| change_log.op | INSERT, UPDATE, DELETE, TRUNCATE, ACCOUNT_CREATE/DELETE/DISABLE/DISABLE_FAILED/ENABLE/ENABLE_FAILED | `change_log_capture`, `record_account_event` | `changeHistory.op.*` ('Created','Edited','Deleted','Account re-enabled',…) |
| inventory_movements.movement_type | 12 values | 9 functions (§1 trans) | `movements.type.*` ('Processing consume','Status change (out)',…) — ledger nouns, not events |
| journal_entries.source_type | 22 values (16 live) | `post_journal_entry` from many callers | `finance.source.*` ('Order invoice posting','FX revaluation',…) |
| container_milestones.milestone | booked, gated_in, loaded, departed, arrived, customs_cleared, delivered, other | app insert; `detach_shipment_from_container` ('other') | `logistics.milestoneLabel.*` ('Gated in','Customs cleared',…) — already past participles |
| leave_consumption.entry_type | draw, release | `decide_leave_request`, `cancel_leave_request` | none |
| collection_promises.outcome | kept, broken, renegotiated, cancelled | `record_promise_outcome` | none found under an outcome key |
| notifications.event_type | 4 | `notify_landing_warnings`, `notify_class_violations` | `notifications.event.*` full sentences — **system alerts, not audit events; excluded from the catalogue** |

`auditTrail.kind.*` (20 keys, the AUDIT-1 batch trail) is the one existing event-shaped vocabulary: 'Received',
'Output batch created', 'Consumed by processing run', 'Produced by processing run', 'Processing cost allocated', 'Sold',
'Reserved against sales order', 'Shipped', 'Counted in stocktake', 'Traceability report issued', 'Approval decision',
'Purchase order changed', 'Sales order changed', 'Journal entry', …

---

## 3. Approval-log writers (for merging, §6.2)

Measured (regex `record_approval_decision('<subject>', …, '<decision>'` over `funcs.csv`): 42 functions.
Submit-side (`submitted` or `auto_approved` when approvals are off): `create_purchase_order`, `invoice_request_submit_internal`,
`journal_request_submit_internal`, `receipt_price_submit_internal`, `submit_asset_disposal_request`,
`submit_bank_transfer_request`, `submit_bank_transfer_reversal_request`, `submit_gst_filing_request`,
`submit_payment_request`, `submit_payment_reversal_request`, `submit_payroll_request`, `submit_shipping_release`,
`submit_wht_remittance_request`, `submit_wht_remittance_reversal_request`, `terms_request_submit_internal`,
`warehouse_request_submit_internal`; submitted only: `submit_overtime_batch`, `submit_review`, `submit_salary_change_request`,
`set_supplier_status` (also `v_to` for approve/reject).
Decide-side (`approved`/`rejected`): the 15 `decide_*` functions, `approve_purchase_order`, `reject_purchase_order`,
`approve_review`. Other: `acknowledge_review` (acknowledged), `post_stocktake` (stocktake approved),
`release_work_order` (work_order approved), `void_approval_on_amount_increase` (approval_voided).

---

## 4. Non-status events (the INSERT *is* the event) — inventory

Writers Measured by regex `INSERT INTO <table>` over `funcs.csv`:
`po_issues`←`record_po_issue`; `so_issues`←`record_so_issue`; `qt_issues`←`record_qt_issue`; `cod_issues`←`record_cod_issue`;
`invoice_issues`←`record_invoice_issue`; `cn_issues`←`record_cn_issue`; `shipment_issues`←`record_shipment_issue`;
`statement_issues`←`record_statement_issue`; `traceability_report_issues`←`record_traceability_report_issue`;
`prepayment_applications`←`apply_prepayment`; `bank_line_matches`←`match_bank_line`; `container_milestones`← app +
`detach_shipment_from_container`; `stocktake_counts`←`record_stocktake_count`; `leave_consumption`←`decide_leave_request`,
`cancel_leave_request`; `wht_remittances`←`remit_wht_internal`; `shipments`←`ship_order`; `sales_records`←`record_output_sale`,
`ship_order`; `role_permissions`←`set_role_permissions` (DELETE all + INSERT all); `user_roles`←`set_user_roles` (INSERT grants,
UPDATE `revoked_at` for removals, in one call); auth events ← `record_account_event` into `change_log` (`ACCOUNT_*`);
`period_closes`←`close_period`; `year_closes`←`close_financial_year`; `import_batches`←`master_import_apply`;
`equipment_downtime`, `equipment_maintenance`, `supplier_compliance`, `company_compliance`, `container_documents`,
`tasks`, `task_nodes`, `review_cycles`, `contracts`, `quotes` ← app code only (no function INSERT).

Settings: `finance_settings` has 13 non-audit columns; `set_finance_settings` may write only 8 (`gst_registered`,
`gst_registration_no`, `gst_rate_pct`, `system_start_date`, `fy_end_month`, `fy_end_day`, `first_fy_end`,
`default_allocation_basis`) and **writes no domain history** (only `change_log`); `locked_before` is written only by
`close_period` / `reopen_period`; the 4 approval columns only by `set_approvals_policy` (→ `finance_settings_history`).

---

## 5. The catalogue

Columns: **ID** · table · trigger condition · recommended English (short, past-tense, business) · detail line (fields) ·
source. Source values: `EXISTS <key>` = existing text already reads as the event and can be used (sentence-cased) as is;
`STATE <key>` = only a state noun/adjective exists → event phrase is NEW; `NEW` = nothing usable.
`{…}` = interpolated value (always a human label, never a code; masking via `change_log_mask_rules()`).

### A. Purchasing

| ID | table | trigger | wording | detail line | source |
|---|---|---|---|---|---|
| A01 | purchase_orders | INSERT, status draft, approval_status pending (+approval_log submitted) | Purchase order raised — waiting for approval | supplier · total {ccy amount} · {n} lines | NEW |
| A02 | purchase_orders | INSERT, status confirmed, approval_status approved (+approval_log auto_approved) | Purchase order raised (approved automatically — approvals are switched off) | supplier · total · {n} lines | NEW |
| A03 | purchase_orders | approval_status pending→approved, status draft→confirmed (+approval_log approved, level) | Purchase order approved (level {1/2}) | approver · order value in base currency · note | STATE purchasing.approvalState.approved |
| A04 | purchase_orders | approval_status →rejected (+approval_log rejected) | Purchase order rejected | rejected by · reason | STATE purchasing.approvalState.rejected |
| A05 | purchase_orders / approval_log | approval_log approval_voided, approval_status approved→pending | Approval withdrawn — the order value went up | previous total → new total | NEW |
| A06 | purchase_orders | status confirmed→receiving (trigger on first inbound receipt) | First goods received — order now receiving | receipt {batch code} · qty | STATE purchasing.status.receiving |
| A07 | purchase_orders | status →closed, closed_at set | Purchase order closed | closed by · note | STATE purchasing.status.closed |
| A08 | purchase_orders | status closed→receiving/confirmed, closed_at cleared (`reopen_purchase_order`) | Purchase order reopened | reason | NEW |
| A09 | purchase_orders + purchase_order_history | status →cancelled, cancelled_at/by set, history `cancelled` | Purchase order cancelled | reason | EXISTS purchasing.amend.change.cancelled ('Cancelled') |
| A10 | purchase_order_history | one `amend_purchase_order` call → N rows (header_update/line_*/payment_term_*) sharing txid | Purchase order amended | reason · then one sub-line per change using the existing labels below | NEW |
| A11 | purchase_order_history | header_update (sub-line) | Header changed | field: before → after | EXISTS purchasing.amend.change.header_update |
| A12 | purchase_order_history | line_add | Line added | material · qty · price | EXISTS purchasing.amend.change.line_add |
| A13 | purchase_order_history | line_update | Line changed | material · qty/price before → after | EXISTS purchasing.amend.change.line_update |
| A14 | purchase_order_history | line_remove | Line removed | material · qty | EXISTS purchasing.amend.change.line_remove |
| A15 | purchase_order_history | payment_term_add | Instalment added | seq · % · trigger | EXISTS purchasing.amend.change.payment_term_add |
| A16 | purchase_order_history | payment_term_update | Instalment changed | seq · before → after | EXISTS purchasing.amend.change.payment_term_update |
| A17 | purchase_order_history | payment_term_remove | Instalment removed | seq · % | EXISTS purchasing.amend.change.payment_term_remove |
| A18 | po_issues | INSERT | Purchase order issued to the supplier (version {n}) | issued by · document number | NEW |
| A19 | purchase_order_payment_terms | expected_date_set_at set | Instalment due date set | instalment {seq} · date | NEW |
| A20 | purchase_order_line_retentions | released_at/by set | Retention released | line · amount | STATE purchasing.retention.state.released |
| A21 | contract_document_terms | INSERT (`link_document_to_contract`) | Linked to contract {code} | contract · terms carried | NEW |
| A22 | purchase_orders | deleted_at set | Purchase order deleted | reason | STATE deleted.kind.purchase_order |

### B. Receiving, processing, stock

| ID | table | trigger | wording | detail line | source |
|---|---|---|---|---|---|
| B01 | inbound_batches | INSERT (`create_inbound_batch` / `receive_inbound_batch_against_po`) + inventory_movements receipt | Goods received: {qty} {unit} of {material} | supplier · PO · location · declared vs received qty | EXISTS auditTrail.kind.receipt ('Received') |
| B02 | inbound_batches | stage 待加工→加工中 (forward, `commit_processing_run`, remaining > 0) | Processing started — {qty} consumed, {remaining} left | run {code} | STATE inbound.stage.processing |
| B03 | inbound_batches | stage →已加工完 (remaining ≤ 0) | Fully processed | run {code} | STATE inbound.stage.processed |
| B04 | inbound_batches | stage →待加工 or 已加工完→加工中 via `rollback_processing_run_internal` | Returned to stock to process (processing run rolled back) | run {code} · qty restored | NEW |
| B05 | inbound_batches + price_history | unit_price changed (`reprice_inbound_batch`) | Price changed from {old} to {new} | reason · formula · FX | STATE auditTrail.kind.price_change ('Price change') |
| B06 | inbound_batches | pricing_status provisional→final (`receipt_price_post_internal`) | Receipt price finalised | final price · request {code} | STATE assay.pricingStatus.final |
| B07 | inbound_batches | import_permit_verified_at/by set | Import permit verified | permit ref | NEW |
| B08 | inbound_batches | source_reason_recorded_at/by set (`explain_inbound_source`) | Source of the goods explained | reason · note | NEW |
| B09 | inbound_batches | deleted_at set (`soft_delete_inbound_batch_internal`) | Receipt deleted | reason | STATE deleted.kind.inbound_batch |
| B10 | assay_results | INSERT (`record_assay_result`) | Assay recorded ({ours / counterparty's / umpire}) | lab · metals · moisture · weight basis | NEW |
| B11 | assay_results | applied_at/by set (`apply_assay_result`, `apply_output_assay`) | Assay applied to the batch | metal contents before → after | NEW |
| B12 | assay_results | applied_at cleared (`unapply_assay_result`) | Assay un-applied | — | NEW |
| B13 | assay_results | superseded_by set | Assay superseded by a later one | newer assay | NEW |
| B14 | processing_runs | INSERT status committed (`commit_processing_run`, + inputs, outputs, consume/produce movements, output batch INSERTs, input stage updates) | Processing completed: {in} in → {out} out, loss {loss} | operation · equipment · work order · outputs | STATE processing.status.committed |
| B15 | processing_runs | allocated_at/by set (`allocate_processing_costs`, + JE allocation) | Processing costs allocated (by {weight / metal value}) | total cost · per-output unit cost | EXISTS auditTrail.kind.cost_allocation ('Processing cost allocated') |
| B16 | processing_runs | allocation_basis_changed_at set | Cost allocation basis changed to {basis} | before → after | NEW |
| B17 | processing_runs | status committed→reversed + deleted_at (`rollback_processing_run_internal`, from an approved warehouse request `rollback`) | Processing run rolled back | request {code} · reason · approved by | STATE processing.status.reversed |
| B18 | processing_cost_entry_history | change_type create | Processing cost recorded | type · amount · period | NEW |
| B19 | processing_cost_entry_history | change_type update | Processing cost changed | amount/type before → after | STATE auditTrail.kind.cost_entry_change |
| B20 | processing_cost_entry_history | change_type delete | Processing cost deleted | reason | NEW |
| B21 | processing_cost_entry_history | change_type restore | Processing cost restored | — | NEW |
| B22 | processing_cost_entries | relieved_at set (`relieve_processing_accruals`, + expense INSERT) | Accrued cost relieved by a real invoice | expense {code} | NEW |
| B23 | output_batches | INSERT (from a run) | Output batch created | run · material · qty | EXISTS auditTrail.kind.output_created |
| B24 | output_batches | purpose_code saleable_stock→process_feed (`set_output_batch_purpose`) | Set aside as feed for a downstream operation | by | NEW (dictionary `output_batch_purposes.name_en`) |
| B25 | output_batches | purpose_code process_feed→saleable_stock | Released back to saleable stock | by | NEW |
| B26 | output_batches | state 库存中→部分售出 / →已售罄 (by sale/shipment) | Partly sold / Sold out (sub-line of the sale event) | remaining qty | STATE output.state.* |
| B27 | output_batches | deleted_at set by `soft_delete_output_batch_internal` | Output batch deleted | reason | STATE deleted.kind.output_batch |
| B28 | output_batches | deleted_at set by `rollback_processing_run_internal` | Removed — its processing run was rolled back | run {code} | NEW |
| B29 | inventory_movements | writeoff (from approved warehouse request write_off_*) + JE writeoff | Written off: {qty} | request {code} · reason · value | STATE movements.type.writeoff |
| B30 | inventory_movements | status_change_out available + in on_hold (`hold_stock`) | Put on hold: {qty} | reason | NEW |
| B31 | inventory_movements | status_change on_hold→available (`release_stock`) | Released from hold: {qty} | reason | NEW |
| B32 | inventory_movements | transfer_out + transfer_in pair (`create_stock_transfer`) | Moved from {location} to {location} | qty | NEW |
| B33 | work_orders + work_order_history | INSERT / created | Work order created | planned inputs · expected outputs | EXISTS processing.wo.changeType.created |
| B34 | work_orders | draft→released (+history released, approval_log work_order approved) | Work order released | released by | EXISTS processing.wo.changeType.released |
| B35 | work_orders | →closed (+history) | Work order closed | closed by | EXISTS processing.wo.changeType.closed |
| B36 | work_orders | →cancelled (+history) | Work order cancelled | reason | EXISTS processing.wo.changeType.cancelled |
| B37 | work_order_history | `amend_work_order` N rows (header/line/expected_*) | Work order amended (sub-lines: 'header changed', 'line added', 'expectation changed' …) | field before → after | NEW (sub-lines EXISTS processing.wo.changeType.*) |
| B38 | pricing_term_commitments | INSERT (`commit_pricing_terms`) | Pricing terms committed | formula · basis · period | NEW |
| B39 | equipment_downtime | started_at / ended_at | Machine down / Machine back in service | reason · duration | NEW |
| B40 | equipment_maintenance | INSERT (performed_on) | Routine service done / Repair done | notes · cost | STATE equipment.kind.{service:'Routine service',repair:'Repair'} |

### C. Stocktake

| ID | table | trigger | wording | detail line | source |
|---|---|---|---|---|---|
| C01 | stocktakes | INSERT open (`open_stocktake`) | Stocktake started | notes | STATE stocktakes.status.open |
| C02 | stocktake_counts (+stocktake_lines) | INSERT (`record_stocktake_count`) | Counted {batch}: {counted} against {book} on the books | counted by | EXISTS auditTrail.kind.stocktake_line ('Counted in stocktake') |
| C03 | stocktakes | open→posted (+approval_log stocktake approved, adjustment movements, JE stocktake, batch qty updates) | Stocktake posted: {n} adjustments | net qty · value | STATE stocktakes.status.posted |
| C04 | stocktakes | →cancelled, cancelled_at/by | Stocktake cancelled | reason | STATE stocktakes.status.cancelled |
| C05 | inventory_movements | adjustment (sub-line of C03, on the batch page) | Stock adjusted by stocktake: {±qty} | stocktake {code} | STATE movements.type.adjustment |

### D. Sales

| ID | table | trigger | wording | detail line | source |
|---|---|---|---|---|---|
| D01 | quotes + quote_history | INSERT / created | Quotation created | customer · total | EXISTS quotes.changeType.created |
| D02 | quotes + qt_issues + history | draft→issued (`record_qt_issue`) | Quotation issued (version {n}) | issued by | EXISTS quotes.changeType.issued |
| D03 | quotes + history | →declined | Quotation declined | reason | EXISTS quotes.changeType.declined |
| D04 | quotes + history + sales_orders INSERT + so history converted_from_quote | →converted (`convert_quote`) | Converted to sales order {code} | order link | EXISTS quotes.changeType.converted ('converted to order') |
| D05 | sales_order_history | converted_from_quote (the SO side of D04) | Created from quotation {code} | — | EXISTS sales.changeType.converted_from_quote |
| D06 | sales_orders + history | INSERT / created | Sales order created | customer · total | EXISTS sales.changeType.created |
| D07 | sales_orders + history | draft→confirmed (`set_sales_order_status`) | Sales order confirmed | credit headroom at the time | EXISTS sales.changeType.confirmed |
| D08 | sales_orders + history | →cancelled | Sales order cancelled | reason | EXISTS sales.changeType.cancelled |
| D09 | sales_orders + history | shipped→closed | Sales order closed | — | EXISTS sales.changeType.closed |
| D10 | so_issues + history issued | INSERT | Order confirmation issued to the customer (version {n}) | issued by | STATE sales.changeType.issued |
| D11 | sales_order_reservations + movements available→committed + history reserved | INSERT (`reserve_stock_internal`) | Stock reserved: {qty} of {batch} | — | EXISTS auditTrail.kind.reservation ('Reserved against sales order') |
| D12 | sales_order_reservations + movements + history released | released_at set (`release_reservation_internal`) | Reservation released: {qty} of {batch} | reason | STATE sales.changeType.released |
| D13 | shipments + shipment lines + sale movements + reservation consumed_at + output state + SO status + history shipped + JE shipment | INSERT (`ship_order`) | Shipped {qty} — order now {partly shipped / fully shipped} | shipment {code} · container · batches | EXISTS auditTrail.kind.shipment ('Shipped') |
| D14 | sales_orders | partially_shipped↔shipped by `amend_sales_order` (no shipment) | Shipping status recalculated after the order was amended | before → after | NEW |
| D15 | sales_order_history | `amend_sales_order` N rows (header_update/line_*) | Sales order amended (sub-lines 'amended — line added' …) | before → after | NEW (sub-lines EXISTS sales.changeType.*) |
| D16 | shipping_releases + approval_log | INSERT submitted | Shipping release requested | amount · reason | NEW |
| D17 | shipping_releases + approval_log | INSERT approved (auto) | Shipping release approved automatically | — | NEW |
| D18 | shipping_releases + approval_log | →approved | Shipping release approved | approver · note | STATE sales.release.status.approved |
| D19 | shipping_releases + approval_log | →rejected | Shipping release rejected | reason | STATE sales.release.status.rejected |
| D20 | shipping_releases | →withdrawn | Shipping release withdrawn | withdrawn by | STATE sales.release.status.withdrawn |
| D21 | invoices + invoice_issues + history invoiced + JE invoice | INSERT (`create_order_invoice`) | Invoice {number} issued | amount · tax | EXISTS sales.changeType.invoiced ('invoiced') |
| D22 | invoices | INSERT kind sale (`create_invoice`, groups posted sales) | Invoice {number} issued for {n} sales | amount | STATE invoice.status.issued |
| D23 | invoices + history invoice_voided + reversal JE | issued→void (`void_invoice_internal`) | Invoice {number} voided | request {code} · reason | EXISTS sales.changeType.invoice_voided |
| D24 | cn_issues + credit_note_lines + JE credit_note + history credit_noted | INSERT (`create_credit_note_internal`) | Credit note {number} raised | kind ('Not delivered — cancelled' / 'Price / quality adjustment') · amount | EXISTS sales.changeType.credit_noted |
| D25 | invoice_requests (+approval_log) | INSERT submitted | Credit note / invoice void requested | kind · amount · reason | NEW |
| D26 | invoice_requests | INSERT approved (auto) | Credit note / invoice void approved automatically | — | NEW |
| D27 | invoice_requests | →approved | Credit note / invoice void approved | approver | STATE finance.invoiceRequest.status.approved |
| D28 | invoice_requests | →rejected | Credit note / invoice void rejected | reason | STATE finance.invoiceRequest.status.rejected |
| D29 | invoice_requests | →withdrawn | Credit note / invoice void request withdrawn | — | STATE finance.invoiceRequest.status.withdrawn |
| D30 | sales_records + sale movement + JE sale | INSERT (`record_output_sale`) | Sale recorded: {qty} to {customer} | price · amount | EXISTS auditTrail.kind.sale ('Sold') |
| D31 | sales_attribution_log | INSERT | Sale attributed to {customer} | exposure after | STATE auditTrail.kind.attribution ('Credit attribution') |
| D32 | sales_settlements | INSERT (`record_sale_settlement`) | Settlement computed | weight basis · settling party · amount | NEW |
| D33 | sales_settlements | superseded_by set | Settlement replaced by a newer one | newer settlement | NEW |
| D34 | shipment_issues | INSERT | Shipping documents issued (version {n}) | — | NEW |
| D35 | traceability_report_issues | INSERT | Traceability report issued | recipient | EXISTS auditTrail.kind.report_issued |
| D36 | certificates_of_destruction + cod_issues | pending→issued (`issue_cod`) | Certificate of destruction issued | number · completed on | STATE cod.statusIssued |
| D37 | certificates_of_destruction | issued→void (`void_cod_internal`, from warehouse request cod_void) | Certificate of destruction voided | request · reason | EXISTS cod.statusVoid ('Voided') |
| D38 | customer_credit_history | credit_limit old→new | Credit limit changed from {old} to {new} | — | NEW |
| D39 | customer_credit_history | credit_hold false→true | Customer put on credit hold | reason | NEW |
| D40 | customer_credit_history | credit_hold true→false | Credit hold lifted | — | NEW |
| D41 | customer_statements + statement_issues | INSERT (`issue_customer_statement`) | Statement issued up to {date} | balance | NEW |
| D42 | customer_statements | superseded_at/by set | Statement replaced by a newer one | — | NEW |
| D43 | collection_chases (+collection_chase_documents, +collection_promises) | INSERT (`record_collection_chase`) | Customer chased by {phone / email / WhatsApp / in person / letter} | documents chased · promise | NEW |
| D44 | collection_chases | superseded_at/by | Chase note corrected | — | NEW |
| D45 | collection_promises | INSERT | Promise to pay {amount} by {date} | — | NEW |
| D46 | collection_promises | outcome set (`record_promise_outcome`) — one row per value kept/broken/renegotiated/cancelled | Promise kept / Promise broken / Promise renegotiated / Promise cancelled | recorded by | NEW |
| D47 | sales_orders / quotes | deleted_at set | Sales order deleted / Quotation deleted | reason | STATE deleted.kind.sales_order / deleted.kind.quote |

### E. Logistics

| ID | table | trigger | wording | detail line | source |
|---|---|---|---|---|---|
| E01 | container_milestones | INSERT milestone booked | Container booked | date · note | EXISTS logistics.milestoneLabel.booked |
| E02 | container_milestones | gated_in | Container gated in | — | EXISTS logistics.milestoneLabel.gated_in |
| E03 | container_milestones | loaded | Container loaded | — | EXISTS logistics.milestoneLabel.loaded |
| E04 | container_milestones | departed | Container departed | vessel · port | EXISTS logistics.milestoneLabel.departed |
| E05 | container_milestones | arrived | Container arrived | port | EXISTS logistics.milestoneLabel.arrived |
| E06 | container_milestones | customs_cleared | Customs cleared | — | EXISTS logistics.milestoneLabel.customs_cleared |
| E07 | container_milestones | delivered | Container delivered | — | EXISTS logistics.milestoneLabel.delivered |
| E08 | container_milestones | other (incl. `detach_shipment_from_container`) | Container note: {note} / Shipment {code} taken off this container | note | NEW |
| E09 | container_documents | INSERT pending | Document expected: {type} | — | NEW |
| E10 | container_documents | pending→received | Document received: {type} | — | STATE logistics.statusReceived |
| E11 | container_documents | →not_applicable | Document marked not needed: {type} | reason | STATE logistics.statusNa |
| E12 | containers | deleted_at/by set (`soft_delete_container`) | Container deleted | reason | NEW |
| E13 | lanes | checklist_reviewed_at set | Document checklist reviewed | — | NEW |

### F. Finance

| ID | table | trigger | wording | detail line | source |
|---|---|---|---|---|---|
| F01 | payment_requests + approval_log | INSERT submitted (any kind) | {Payment / Bank transfer / Withholding-tax remittance / … } requested | payee · amount · bank account | NEW |
| F02 | payment_requests | INSERT approved (auto) | {kind} approved automatically | — | NEW |
| F03 | payment_requests + approval_log | →approved | {kind} approved — ready to pay | approver | STATE finance.paymentRequests.status.approved |
| F04 | payment_requests + approval_log | →rejected | {kind} request rejected | reason | STATE finance.paymentRequests.status.rejected |
| F05 | payment_requests | →withdrawn | {kind} request withdrawn | — | STATE finance.paymentRequests.status.withdrawn |
| F06 | payment_requests + payments INSERT + JE payment | approved→paid (`pay_payment_request`) | Payment made: {amount} to {payee} | bank account · reference | STATE finance.paymentRequests.status.paid |
| F07 | payments + JE payment | INSERT direction in | Payment received: {amount} from {payer} | bank account · allocated to | NEW |
| F08 | payments + reversal JE | posted→reversed | Payment reversed | request · reason | STATE finance.status.reversed |
| F09 | prepayment_applications (+JE prepayment) | INSERT (`apply_prepayment`) | Prepayment of {amount} applied | against {document} | NEW |
| F10 | bank_transfers + JE transfer | INSERT | Bank transfer recorded: {amount} from {account} to {account} | — | NEW |
| F11 | bank_transfers | reversed_at/by | Bank transfer reversed | reason | NEW |
| F12 | wht_remittances + JE wht_remittance | INSERT (`remit_wht_internal`) | Withholding tax remitted to IRAS | month · amount | EXISTS finance.source.wht_remittance |
| F13 | bank_statements + lines | INSERT (`import_bank_statement`) | Bank statement imported: {n} lines | account · period | NEW |
| F14 | bank_line_matches + line match_status unmatched→matched | INSERT (`match_bank_line`) | Bank line matched to {payment} | amount | STATE bank.lineStatus.matched |
| F15 | bank_statement_lines | matched→unmatched (`unmatch_bank_line`) | Bank line unmatched | — | NEW |
| F16 | bank_statement_lines | →ignored | Bank line ignored | reason | STATE bank.lineStatus.ignored |
| F17 | bank_statement_lines | ignored→unmatched (`unignore_bank_line`) | Bank line no longer ignored | — | NEW |
| F18 | bank_statements + bank_reconciliations + variance items | open→reconciled (`reconcile_statement`) | Statement reconciled | closing balance · {n} variance items | STATE bank.status.reconciled |
| F19 | bank_statements + bank_reconciliations.superseded_at | reconciled→open (`unreconcile_statement`) | Reconciliation undone | reason | NEW |
| F20 | expenses + JE expense (+fixed_assets INSERT) | INSERT posted | Expense recorded: {amount} | supplier · paid/unpaid · asset created | NEW |
| F21 | expenses + reversal | posted→reversed | Expense reversed | reason | STATE finance.status.reversed |
| F22 | freight_documents + JE freight | INSERT | Freight recorded: {amount} ({inbound / outbound}) | allocation basis · batches | NEW |
| F23 | freight_documents | posted→reversed | Freight reversed | reason | STATE finance.status.reversed |
| F24 | journal_requests + approval_log | INSERT submitted (kind entry / reversal) | Manual journal / journal reversal requested | lines · reason | NEW |
| F25 | journal_requests | INSERT approved (auto) | Manual journal approved automatically | — | NEW |
| F26 | journal_requests | →approved (and executed: JE posted) | Manual journal approved and posted | approver · entry number | STATE finance.journalRequest.status.approved |
| F27 | journal_requests | →rejected | Manual journal rejected | reason | STATE finance.journalRequest.status.rejected |
| F28 | journal_requests | →withdrawn | Manual journal request withdrawn | — | STATE finance.journalRequest.status.withdrawn |
| F29 | journal_entries | INSERT source_type manual | Manual journal posted | entry number · total | NEW |
| F30 | journal_entries | posted→reversed + reversal JE INSERT | Journal entry reversed | reversal entry number · reason | STATE finance.status.reversed |
| F31 | journal_entries | INSERT source_type revaluation | FX revaluation posted | as-of date · gain/loss | EXISTS finance.source.revaluation ('FX revaluation') |
| F32 | journal_entries | INSERT source_type depreciation | Depreciation posted for {month} | amount | NEW |
| F33 | journal_entries | any other source_type in the same txid as a business event | (not its own entry — shown as the detail line "Posted to the ledger: {entry number}") | — | NEW |
| F34 | period_closes + finance_settings.locked_before | INSERT (`close_period`) | Month closed up to {period_end} | {n} entries · debits = credits | STATE finance.closeStatus.active ('Closed') |
| F35 | period_closes + finance_settings.locked_before | reopened_at/by set (`reopen_period`) | Month reopened: {period_end} | reason | EXISTS finance.closeStatus.reopened ('Reopened') |
| F36 | year_closes + JE year_close | INSERT (`close_financial_year`) | Financial year closed (year end {date}) | net result | STATE finance.source.year_close |
| F37 | year_closes + reversal JE | reopened_at/by set (`reopen_financial_year`) | Financial year reopened | reason | NEW |
| F38 | finance_settings | gst_registered false→true | Registered for GST (number {no}) | effective | STATE gst.registeredYes |
| F39 | finance_settings | gst_registered true→false | GST registration ended | — | STATE gst.registeredNo |
| F40 | finance_settings | gst_rate_pct changed | GST rate changed from {old}% to {new}% | — | NEW |
| F41 | finance_settings | gst_registration_no changed | GST registration number changed | old → new | NEW |
| F42 | finance_settings | fy_end_month/day or first_fy_end changed | Financial year end changed to {date} | — | NEW |
| F43 | finance_settings | system_start_date changed | System start date changed to {date} | — | NEW |
| F44 | finance_settings | default_allocation_basis changed | Default cost-allocation basis changed to {basis} | — | NEW |
| F45 | finance_settings + finance_settings_history | approvals_enabled false→true (`set_approvals_policy`) | Approvals switched on | level 1 role · level 2 role · threshold | STATE finance.approvals.historyOn ('in force') |
| F46 | same | approvals_enabled true→false | Approvals switched off | — | STATE finance.approvals.historyOff |
| F47 | same | approval_level1_role_code / level2 changed | Level {1/2} approver changed to {role} | before → after | NEW |
| F48 | same | approval_threshold_base changed | Approval threshold changed from {old} to {new} | — | NEW |
| F49 | gst_periods | INSERT open (`open_gst_period`) | GST period opened: {quarter} | — | STATE gstFiling.periodStatus.open |
| F50 | gst_periods | INSERT open (`correct_gst_return`) | GST return reopened for correction | original period · reason | NEW |
| F51 | gst_periods (+gst_filing_requests executed) | open→approved | GST return approved — not filed yet | approver | EXISTS gstFiling.periodStatus.approved ('Approved, not filed yet') |
| F52 | gst_periods | →filed, filed_at/by/on | GST return filed with IRAS on {date} | reference | STATE gstFiling.periodStatus.filed |
| F53 | gst_filing_requests + approval_log | INSERT submitted | GST filing sent to the CFO | — | NEW |
| F54 | gst_filing_requests | INSERT approved (auto) | GST filing approved automatically | — | NEW |
| F55 | gst_filing_requests | →approved | GST filing approved | approver | STATE gstFiling.status.approved |
| F56 | gst_filing_requests | →rejected | GST filing rejected | reason | STATE gstFiling.status.rejected |
| F57 | gst_filing_requests | →withdrawn | GST filing request withdrawn | — | STATE gstFiling.status.withdrawn |
| F58 | fx_rates + fx_rate_history created | INSERT (`record_fx_rate`) | FX rate recorded: {ccy} {rate} for {date} | rate type | NEW |
| F59 | fx_rate_history corrected | re-record same date | FX rate corrected from {prev} to {rate} | reason | NEW |
| F60 | fx_rates.deleted_at + fx_rate_history withdrawn | `withdraw_fx_rate` | FX rate withdrawn | reason | NEW |
| F61 | fixed_assets + fixed_asset_history created | INSERT | Asset card created | cost · useful life | EXISTS assets.history.type.created ('Card created') |
| F62 | fixed_asset_history updated | UPDATE (non-status) | Asset card changed | field before → after (`assets.history.field.*`) | EXISTS assets.history.type.updated ('Changed') |
| F63 | fixed_assets + JE asset_disposal | active→disposed (`dispose_fixed_asset_internal`) | Asset disposed | proceeds · gain/loss · request | STATE assets.status.disposed |
| F64 | asset_disposal_requests + approval_log | INSERT submitted | Asset disposal requested | proceeds · reason | NEW |
| F65 | asset_disposal_requests | INSERT approved (auto) | Asset disposal approved automatically | — | NEW |
| F66 | asset_disposal_requests | →approved (+executed_at) | Asset disposal approved | approver | STATE assetDisposal.status.approved |
| F67 | asset_disposal_requests | →rejected | Asset disposal rejected | reason | STATE assetDisposal.status.rejected |
| F68 | asset_disposal_requests | →withdrawn | Asset disposal request withdrawn | — | STATE assetDisposal.status.withdrawn |
| F69 | cash_forecasts | frozen_at/by set (`freeze_cash_forecast`) | Cash forecast frozen | as-of | NEW |
| F70 | cash_forecasts | superseded_at/by | Cash forecast replaced by a newer one | — | NEW |
| F71 | management_packs | produced_at/by (`freeze_management_pack`) | Management pack produced for {month} | — | NEW |
| F72 | management_packs | superseded_at/by | Management pack replaced by a newer one | — | NEW |
| F73 | pricing_formula_history create (+terms request formula_create executed) | INSERT | Pricing formula created | terms | NEW |
| F74 | pricing_formula_history update | UPDATE | Pricing formula terms changed | before → after | NEW |
| F75 | pricing_formula_history delete | deleted_at set (`delete_pricing_formula`) / deactivate | Pricing formula taken out of use | reason | NEW |
| F76 | pricing_formula_history restore (+terms request formula_reactivate) | | Pricing formula back in use | — | NEW |
| F77 | pricing_formula_history metal_set / metal_clear | | Metal term set: {metal} / Metal term removed: {metal} | payable % · deduction | NEW |
| F78 | terms_requests + approval_log | INSERT submitted | {New formula / Formula change / Formula reactivation / Contract activation} sent to the CFO | — | STATE termsRequest.openTitle.* (sentence already, present tense) |
| F79 | terms_requests | INSERT approved (auto) | {kind} approved automatically | — | NEW |
| F80 | terms_requests | →approved (+executed) | {kind} approved | approver | STATE termsRequest.status.approved |
| F81 | terms_requests | →rejected | {kind} rejected | reason | STATE termsRequest.status.rejected |
| F82 | terms_requests | →withdrawn | {kind} request withdrawn | — | STATE termsRequest.status.withdrawn |
| F83 | contracts | INSERT draft | Contract drafted | counterparty · kind | NEW |
| F84 | contracts | draft→active (`terms_request_execute_internal`) | Contract took effect | approved by · request | STATE contracts.status.active |
| F85 | contracts | active→suspended (app) | Contract suspended | — | STATE contracts.status.suspended |
| F86 | contracts | →expired / →terminated (no writer today) | Contract expired / Contract terminated | reason | STATE contracts.status.* |
| F87 | receipt_price_requests + approval_log | INSERT submitted | Receipt price sent to the CFO | proposed price · source | NEW |
| F88 | receipt_price_requests | INSERT approved (auto) | Receipt price approved automatically | — | NEW |
| F89 | receipt_price_requests | →approved (+ B06) | Receipt price approved and posted | approver | EXISTS inbound.priceRequest.status.approved ('Approved and posted') |
| F90 | receipt_price_requests | →rejected | Receipt price rejected | reason | STATE inbound.priceRequest.status.rejected |
| F91 | receipt_price_requests | →withdrawn | Receipt price request withdrawn | — | STATE inbound.priceRequest.status.withdrawn |
| F92 | warehouse_requests + approval_log | INSERT submitted | {Write-off / Rollback / Certificate void} sent to the CFO | batch · qty · reason | STATE warehouseRequest.trigger.* ('Request write-off' — imperative) |
| F93 | warehouse_requests | INSERT approved (auto) | {kind} approved automatically | — | NEW |
| F94 | warehouse_requests | →approved (+executed_at; executes B17 / B29 / D37) | {kind} approved | approver | STATE warehouseRequest.status.approved |
| F95 | warehouse_requests | →rejected | {kind} rejected | reason | STATE warehouseRequest.status.rejected |
| F96 | warehouse_requests | →withdrawn | {kind} request withdrawn | — | STATE warehouseRequest.status.withdrawn |
| F97 | import_batches | INSERT (`master_import_apply`) | {n} {suppliers / materials / …} imported from a file | file name | NEW |
| F98 | metal_prices | INSERT/UPDATE (`upsert_metal_prices`) | Metal price recorded: {metal} {price} for {date} | source | NEW |

### G. People (HR)

| ID | table | trigger | wording | detail line | source |
|---|---|---|---|---|---|
| G01 | leave_requests | INSERT pending | Leave requested: {days} days of {type} | dates | NEW |
| G02 | leave_requests + leave_consumption draw + approval_log | →approved | Leave approved | approver · balance after | STATE leave.status_approved |
| G03 | leave_requests + approval_log | →rejected | Leave rejected | reason | STATE leave.status_rejected |
| G04 | leave_requests + leave_consumption release | →cancelled | Leave cancelled — days returned | — | STATE leave.status_cancelled |
| G05 | leave_grants | INSERT grant_type entitlement / pro_rata / adjustment | Leave granted: {days} days ({entitlement / pro-rata / adjustment}) | valid until | NEW |
| G06 | leave_grants | INSERT carry_forward (`carry_forward_annual_leave`) | Unused leave carried forward: {days} days | expires on | STATE leave.grantStatus_carried_forward |
| G07 | medical_claims + approval_log | INSERT submitted | Medical claim submitted: {amount} | clinic · date | EXISTS claims.state_submitted ('Submitted') |
| G08 | medical_claims | →approved | Medical claim approved | approver | STATE claims.state_approved |
| G09 | medical_claims | →rejected | Medical claim rejected | reason | STATE claims.state_rejected |
| G10 | medical_claims | →withdrawn | Medical claim withdrawn | — | STATE claims.state_withdrawn |
| G11 | medical_claims | expense_id set (`pay_medical_claim`) | Expense raised to pay the claim | expense {code} | EXISTS claims.state_expense_raised ('Expense raised') |
| G12 | expense_claims | INSERT submitted | Expense claim submitted: {amount} | — | NEW |
| G13 | expense_claims | →approved | Expense claim approved | approver | STATE expenseClaims.status_approved |
| G14 | expense_claims | →rejected | Expense claim rejected | reason | STATE expenseClaims.status_rejected |
| G15 | expense_claims | →withdrawn | Expense claim withdrawn | — | STATE expenseClaims.status_withdrawn |
| G16 | overtime_batches | INSERT draft | Overtime batch started | period | NEW |
| G17 | overtime_batches + approval_log | draft→submitted | Overtime sent for approval: {hours} hours | {n} lines | NEW |
| G18 | overtime_batches | submitted→draft (`withdraw_overtime_batch`) | Overtime taken back for changes | — | NEW |
| G19 | overtime_batches + approval_log | →approved | Overtime approved | approver · amount | STATE overtime.status_approved |
| G20 | overtime_batches + approval_log | →rejected | Overtime sent back | reason | EXISTS overtime.status_rejected ('Sent back') |
| G21 | overtime_batches + overtime_lines.voided_at | →reversed | Overtime reversed | reason | STATE overtime.status_reversed |
| G22 | overtime_batches | →discarded | Overtime batch discarded | — | STATE overtime.status_discarded |
| G23 | payroll_requests + approval_log | INSERT submitted (kind post / reversal) | Payroll posting / unposting sent for approval | month · total | NEW |
| G24 | payroll_requests | INSERT approved (auto) | Payroll posting approved automatically | — | NEW |
| G25 | payroll_requests | →approved | Payroll posting approved | approver | STATE hr.payrollRequest.status.approved |
| G26 | payroll_requests | →rejected | Payroll posting rejected | reason | STATE hr.payrollRequest.status.rejected |
| G27 | payroll_requests | →withdrawn | Payroll request withdrawn | — | STATE hr.payrollRequest.status.withdrawn |
| G28 | payroll_periods + JE payroll + payroll_requests executed | draft→posted | Payroll posted for {month} | gross · CPF · net | STATE hr.payrollStatus.posted |
| G29 | payroll_periods + reversal JE + request executed | posted→draft | Payroll unposted for {month} | reason | STATE hr.payrollRequest.kind.reversal ('Unpost') |
| G30 | payroll_lines | paid_at set (`pay_payroll_lines`) | Salaries paid: {n} employees | total | NEW |
| G31 | payroll_periods | cpf_paid_at / deductions_paid_at set | CPF paid / Deductions paid | date | NEW |
| G32 | salary_change_requests + approval_log | INSERT submitted | Salary change requested: {old} → {new} | effective date | NEW |
| G33 | salary_change_requests + employment_history salary_change + employees | →approved (+executed_at) | Salary change approved | approver | STATE salaryChange.status.approved |
| G34 | salary_change_requests | →rejected | Salary change rejected | reason | STATE salaryChange.status.rejected |
| G35 | salary_change_requests | →withdrawn | Salary change request withdrawn | — | STATE salaryChange.status.withdrawn |
| G36 | employment_history | hired | Hired | position · department | EXISTS hr.changeType.hired |
| G37 | employment_history + employees probation→active | confirmed | Confirmed after probation | review | EXISTS hr.changeType.confirmed ('Confirmed') |
| G38 | employment_history | promotion | Promoted to {position} | — | STATE hr.changeType.promotion ('Promotion') |
| G39 | employment_history | transfer | Transferred to {department} | — | STATE hr.changeType.transfer ('Transfer') |
| G40 | employment_history | type_change | Employment type changed to {type} | — | STATE hr.changeType.type_change |
| G41 | employment_history | status_change | Employment status changed to {status} (e.g. "Notice given") | — | STATE hr.changeType.status_change |
| G42 | employment_history | separated | Left the company ({resignation / retirement / …}) | last day | EXISTS hr.changeType.separated ('Separated') |
| G43 | employment_history | salary_change (incl. `set_initial_salary`) | Salary set to {amount} / Salary changed from {old} to {new} | effective | STATE hr.changeType.salary_change |
| G44 | employment_history | category_change | Work category changed to {office / shopfloor} | — | STATE hr.changeType.category_change |
| G45 | performance_reviews | INSERT draft | {Probation / Annual} review opened | cycle | NEW |
| G46 | performance_reviews | draft→self_review | Opened for self-assessment | — | STATE reviews.status_self_review |
| G47 | performance_reviews | self_assessment_submitted_at set | Self-assessment submitted | — | NEW |
| G48 | performance_reviews + approval_log | →submitted | Review submitted for approval | outcome · proposed salary | EXISTS reviews.status_submitted ('Submitted') |
| G49 | performance_reviews + approval_log + employment_history + employees | →approved | Review approved | approver · outcome applied | STATE reviews.status_approved |
| G50 | performance_reviews + approval_log acknowledged | →acknowledged | Review acknowledged by the employee | — | EXISTS reviews.status_acknowledged ('Acknowledged') |
| G51 | performance_reviews | →void | Review voided | reason | STATE reviews.status_void |
| G52 | review_cycles | draft→open | Review cycle opened: {n} reviews created | — | STATE reviews.cycleStatus_open |
| G53 | review_cycles | open→closed (app) | Review cycle closed | — | STATE reviews.cycleStatus_closed |
| G54 | kpi_cycles | locked_at/by set | KPI scores locked by the {M3 / M6} gate | — | STATE kpi.lockedTag ('locked') |
| G55 | kpi_entries | scored_at/by set (`score_kpi_entry`) | KPI scored: {score} | judged / computed | NEW |
| G56 | attendance_periods | INSERT opened_at/by | Attendance period opened | month | STATE attendance.status.open |
| G57 | attendance_periods + attendance_lines.frozen_at | open→complete | Attendance period completed | — | STATE attendance.status.complete |
| G58 | attendance_periods | complete→open, reopened_at/by | Attendance period reopened | reason | NEW |
| G59 | employee_account_history | action linked | Extra login linked: {account} | — | NEW |
| G60 | employee_account_history | action unlinked | Extra login unlinked: {account} | — | NEW |
| G61 | employees (+employment_history.anonymised_at) | anonymised_at/by set (`anonymise_employee`) | Personal data anonymised | — | NEW |
| G62 | shift_handovers | submitted_at/by (`submit_shift_handover`) | Shift handed over | notes | NEW |
| G63 | shift_handovers | acknowledged_at/by (`acknowledge_shift_handover`) | Shift handover acknowledged | — | NEW |

### H. Suppliers, customers, licences

| ID | table | trigger | wording | detail line | source |
|---|---|---|---|---|---|
| H01 | suppliers + supplier_status_history + approval_log submitted | draft→pending_review | Supplier submitted for review | — | STATE suppliers.statusAction.pending_review ('Submit for Review') |
| H02 | suppliers + history + approval_log | pending_review→approved, approved_at/by | Supplier approved | approver | STATE suppliers.status.approved |
| H03 | suppliers + history + approval_log | pending_review→rejected | Supplier rejected | reason | STATE suppliers.status.rejected |
| H04 | suppliers + history | pending_review→draft | Review withdrawn — back to draft | — | NEW |
| H05 | suppliers + history | rejected→draft | Returned to draft for rework | — | NEW |
| H06 | suppliers + history | approved/suspended→active | Supplier activated / Supplier reinstated (from suspended) | — | STATE suppliers.status.active |
| H07 | suppliers + history | approved/active→suspended | Supplier suspended | reason | STATE suppliers.status.suspended |
| H08 | suppliers + history | active/suspended→blacklisted | Supplier blacklisted | reason | STATE suppliers.status.blacklisted |
| H09 | suppliers + history | any→archived | Supplier archived | — | STATE suppliers.status.archived |
| H10 | suppliers + history | archived→draft | Supplier restored from archive | — | NEW |
| H11 | supplier_compliance | INSERT / deleted_at set | Certificate added: {type} / Certificate removed: {type} | expiry | NEW |
| H12 | company_compliance | INSERT / status →active/suspended/revoked | Licence added / Licence suspended / Licence revoked / Licence reinstated | number · expiry | STATE company.licence.status.* |
| H13 | customers / materials / suppliers | deleted_at set (app) | {Customer / Material / Supplier} deleted | — | NEW |

### I. Access control and accounts

| ID | table | trigger | wording | detail line | source |
|---|---|---|---|---|---|
| I01 | role_permissions | code present after `set_role_permissions`, absent before (set diff) | Permission added: {permission label} | role | NEW |
| I02 | role_permissions | code absent after, present before | Permission removed: {permission label} | role | NEW |
| I03 | user_roles | INSERT (`set_user_roles`) | Role granted: {role name} | granted by | NEW |
| I04 | user_roles | revoked_at/by set | Role removed: {role name} | reason (`revoke_reason`) | NEW |
| I05 | change_log | op ACCOUNT_CREATE | Account created | email (masked) | EXISTS changeHistory.op.ACCOUNT_CREATE |
| I06 | change_log | ACCOUNT_DELETE | Account deleted | — | EXISTS changeHistory.op.ACCOUNT_DELETE |
| I07 | change_log | ACCOUNT_DISABLE | Account disabled | — | EXISTS changeHistory.op.ACCOUNT_DISABLE |
| I08 | change_log | ACCOUNT_DISABLE_FAILED | Account disable failed | error | EXISTS changeHistory.op.ACCOUNT_DISABLE_FAILED |
| I09 | change_log | ACCOUNT_ENABLE | Account re-enabled | — | EXISTS changeHistory.op.ACCOUNT_ENABLE |
| I10 | change_log | ACCOUNT_ENABLE_FAILED | Account re-enable failed | error | EXISTS changeHistory.op.ACCOUNT_ENABLE_FAILED |
| I11 | roles | INSERT / deleted_at set | Role created / Role deactivated | — | NEW |
| I12 | employees / employee_accounts | login link set (`set_user_employee_link`), linked_at/by | Login linked to {employee} / Login unlinked | — | NEW |

### J. Tasks

| ID | table | trigger | wording | detail line | source |
|---|---|---|---|---|---|
| J01 | tasks | status todo→in_progress (app; task_history header_update) | Task started | — | STATE tasks.status.in_progress |
| J02 | tasks | status →done | Task completed | — | STATE tasks.status.done |
| J03 | tasks | status done→todo/in_progress | Task reopened | — | NEW |
| J04 | task_history | promoted_from_personal | Promoted from personal | — | EXISTS tasks.history.type.promoted_from_personal |
| J05 | task_history | node_added | Step added | step title | EXISTS tasks.history.type.node_added |
| J06 | task_history | node_removed | Step deleted | step title | EXISTS tasks.history.type.node_removed |
| J07 | task_history | node_renamed | Step renamed | old → new | EXISTS tasks.history.type.node_renamed |
| J08 | task_history | node_redated | Step re-dated | old → new date | EXISTS tasks.history.type.node_redated |
| J09 | task_history | node_done (task_nodes.done_at/by) | Step ticked | step title | EXISTS tasks.history.type.node_done |
| J10 | task_history | node_undone | Step un-ticked | step title | EXISTS tasks.history.type.node_undone |
| J11 | task_history | node_reordered | Step moved | — | EXISTS tasks.history.type.node_reordered |
| J12 | task_history | participant_added | Participant added | person | EXISTS tasks.history.type.participant_added |
| J13 | task_history | participant_removed | Participant taken off | person | EXISTS tasks.history.type.participant_removed |
| J14 | task_history | participant_left | Participant left | person | EXISTS tasks.history.type.participant_left |
| J15 | task_history | owner_transferred | Owner transferred | old → new owner | EXISTS tasks.history.type.owner_transferred |
| J16 | task_history + tasks.deleted_at | task_deleted | Task deleted | — | EXISTS tasks.history.type.task_deleted |
| J17 | task_history | header_update (non-status fields) | Task edited | field before → after | EXISTS tasks.history.type.header_update |

### K. Generic fallback (any table with no row above)

| ID | table | trigger | wording | detail line | source |
|---|---|---|---|---|---|
| K01 | any (change_log) | INSERT | Created | key fields | EXISTS changeHistory.op.INSERT |
| K02 | any (change_log) | UPDATE of non-lifecycle columns | Edited | field: before → after (masked) | EXISTS changeHistory.op.UPDATE |
| K03 | any (change_log) | DELETE (hard) | Deleted | the row's last values | EXISTS changeHistory.op.DELETE |
| K04 | any | deleted_at set from NULL (table with no specific row above) | Deleted | reason (`delete_reason` where present) | STATE deleted.colWhen ('Deleted') |

---

## 6. Ambiguities and multi-row events

### 6.1 One field change, two (or more) different events — disambiguate by OLD value or by writer

| # | field change | meanings | how to tell them apart (Measured from the function source) |
|--:|---|---|---|
| 1 | purchase_orders.status →receiving | first goods received (A06) / reopened after close (A08) | old value confirmed vs closed; A08 also clears `closed_at` |
| 2 | purchase_orders.status →confirmed | approved (A03) / reopened with no receipts (A08) | old draft + approval_status changes vs old closed |
| 3 | purchase_orders.approval_status →pending | raised (A01) / approval voided by an amount increase (A05) | INSERT vs UPDATE; A05 has an `approval_voided` approval_log row in the same txid |
| 4 | overtime_batches.status →draft | created (G16) / taken back for changes (G18) | INSERT vs UPDATE from submitted |
| 5 | payroll_periods.status posted→draft | "Payroll unposted" (a reversal, with a reversal JE) — NOT "returned to draft" | always a reversal; the payroll_request kind is `reversal` |
| 6 | suppliers.status →draft | review withdrawn (H04) / rework after rejection (H05) / restored from archive (H10) | `from_status` in supplier_status_history |
| 7 | suppliers.status →active | first activation (from approved) / reinstated (from suspended) | from_status |
| 8 | inbound_batches.stage →加工中 | processing started (B02, forward) / partly restored by a rollback (B04) | writer: `commit_processing_run` vs `rollback_processing_run_internal`; rollback txid also sets processing_runs.status reversed |
| 9 | deleted_at set | real deletion with reason (inbound/output batches, processing runs, containers, contacts) / FX rate withdrawn (`withdraw_fx_rate`, F60) / output batch removed because its run was rolled back (B28) / pricing formula taken out of use (F75) / role deactivated (I11, app sets `is_active=false` too) / task deleted (J16) / master-data delete by app on 20+ tables (H13, K04) | writer function; same-txid siblings (fx_rate_history `withdrawn`, processing_runs reversed, pricing_formula_history `delete`). Suppliers have BOTH `deleted_at` (delete) and status `archived` (H09) — never render deleted_at as "Archived". |
| 10 | bank_statement_lines.match_status →unmatched | unmatched (F15) / no longer ignored (F17) | old value matched vs ignored |
| 11 | gst_periods INSERT status open | period opened (F49) / return reopened for correction (F50) | writer: `open_gst_period` vs `correct_gst_return` |
| 12 | *_requests INSERT status approved | submitted and auto-approved because approvals are off (A02, D17, F02, F25, F54, F65, F79, F88, F93, G24, D26) — must not read as a human approval | approval_log decision `auto_approved` in the same txid |
| 13 | approval_log decision approved on subject stocktake / work_order | these are not request approvals but the posting/release itself (C03, B34) | subject_type; fold into the posting/release event |
| 14 | sales_orders.status partially_shipped↔shipped | caused by a shipment (D13) / by an amendment changing ordered qty (D14) | writer `ship_order` vs `amend_sales_order` (only the former inserts a shipment) |
| 15 | journal_entries INSERT | a fresh posting / the reversal of an earlier entry | the reversal carries a link to the original and the original flips to reversed in the same txid → render once as "Journal entry reversed" (F30) |
| 16 | tasks.status change | recorded by task_history as generic `header_update` | read `old`/`new` status inside the history row; J01–J03 must win over J17 |
| 17 | employment_history change_type status_change vs separated vs confirmed | app diff picks one (`app/hr/employees/actions.ts:66-74`); `confirmed` is also written by `approve_review` | writer/actor; if a performance_reviews approval shares the txid, it is G37 via the review |
| 18 | sales_order_history duplicate vocabulary | `line_added`/`line_add`, `line_changed`/`line_update`, `line_removed`/`line_remove` both allowed; current triggers write the short forms | map both spellings to the same event wording |
| 19 | performance_reviews →submitted vs self_assessment_submitted_at | employee's self-assessment (G47) vs manager submitting for approval (G48) | column set |
| 20 | output_batches.state →已售罄 vs remaining_qty → 0 by consumption | "Sold out" (sale) vs fully consumed by a downstream run — the dictionary note says consumption does NOT touch `state` | only a sale/shipment writer sets state |

### 6.2 Multi-row writes that must render as ONE entry

Grouping key: `change_log.txid` (column exists, `db/tables/change_log.sql:38`) — every function below runs in a single
transaction, so "same txid + same subject" = one event. Measured from each function's INSERT/UPDATE list in `funcs.csv`.

| Event | Rows written in the one transaction |
|---|---|
| PO raised (A01/A02) | purchase_orders + purchase_order_lines + purchase_order_payment_terms + approval_log (submitted / auto_approved) — the line/term triggers may also add `line_add`/`payment_term_add` history rows that must be suppressed |
| PO approved (A03) / rejected (A04) | purchase_orders (approval_status, status, approved_at/by) + approval_log |
| PO amended (A10) | N purchase_order_history rows + the underlying line/term/header updates (+ possibly A05) |
| Goods received (B01) | inbound_batches + inventory_movements receipt + purchase_orders status (A06, via trigger) + journal entry purchase if priced |
| Processing completed (B14) | processing_runs + processing_inputs + processing_outputs + processing_run_losses + inventory_movements consume/produce + output_batches INSERT(s) + inbound/output batch remaining/stage updates + batch_processing_cost_allocations |
| Processing rolled back (B17) | warehouse_requests approved/executed + approval_log + processing_runs reversed/deleted + output_batches deleted + inventory_movements reversal_restore/reversal_void + inbound_batches remaining/stage (B04) + reversal JEs |
| Stocktake posted (C03) | stocktakes + approval_log (stocktake approved) + inventory_movements adjustment + inbound/output batch qty + JE stocktake |
| Stock reserved / released (D11/D12) | sales_order_reservations + 2 inventory_movements (status_change_out/in) + sales_order_history |
| Shipped (D13) | shipments + shipment lines + sales_records + inventory_movements sale + reservation consumed_at + output_batches state + sales_orders status + sales_order_history + JE shipment |
| Quote converted (D04/D05) | quotes + quote_history + sales_orders + sales_order_lines + sales_order_history |
| Invoice issued / voided / credit note (D21/D23/D24) | invoices or cn_issues/credit_note_lines + issue register + sales_order_history + JE (+ invoice_requests executed + approval_log for void/credit note) |
| Any request decided (…approved rows in D, F, G) | the request row (status, decided_at/by, executed_at) + approval_log + the executed side effect (payment, JE, write-off, formula, contract, salary, disposal, GST period …) — render as "X approved" with the effect as the detail line, not as two entries |
| Payment made (F06) | payment_requests paid + payments + JE payment (+ prepayment_applications) |
| Month closed / reopened (F34/F35) | period_closes + finance_settings.locked_before |
| Year closed / reopened (F36/F37) | year_closes + JE year_close / reversal JE |
| Approval policy changed (F45–F48) | finance_settings (4 columns) + finance_settings_history — one entry listing each changed setting |
| Leave approved / cancelled (G02/G04) | leave_requests + leave_consumption + approval_log |
| Review approved (G49) | performance_reviews + approval_log + employment_history (confirmed / salary_change) + employees (employment_status, salary) |
| Salary change approved (G33) | salary_change_requests + approval_log + employment_history + employees |
| Supplier status change (H01–H10) | suppliers + supplier_status_history (+ approval_log for review decisions) |
| Roles changed (I03/I04) | `set_user_roles`: INSERT grants + UPDATE revoked_at in one call → one entry "Roles changed" with a sub-line per role granted/removed |
| Permissions changed (I01/I02) | `set_role_permissions`: DELETE all + INSERT all → compute the set difference; unchanged codes appear as delete+insert and must NOT be shown |
| Bank statement reconciled (F18) | bank_statements + bank_reconciliations + bank_reconciliation_variance_items |
| Customer chased (D43) | collection_chases + collection_chase_documents + collection_promises |
| Expense recorded (F20) | expenses + JE expense (+ fixed_assets + fixed_asset_history if capitalised) |

---

## 7. Method notes

- `ev/enums.py`: regex `CHECK\s*\(\s*\(?"?col"?\)?\s*IN\s*\(…\)` and `col = ANY (ARRAY[…])` over `db/tables/*.sql` with `--` comments
  stripped; first definition per table.col kept. Cross-checked against live `pg_constraint` (`ev/q1.sql`): 0 repo pairs missing live.
  The live parse keeps the first `ANY(ARRAY…)` per column, so for 5 columns whose first live constraint is a conditional subset
  (e.g. `approval_log` self-decided guard) the value lists differ — the repo lists are authoritative for values.
- Transitions: `ev/trans.py` — every `UPDATE <t> [alias] SET … ;` statement in `funcs.csv` (743 functions) and every
  `INSERT INTO <t>(cols)` naming the enum column; values kept only if they are members of the enum. Branch conditions are
  not evaluated (an UPPER BOUND, same caveat as `fnmap.json`). App-side writers: `grep -rnE '\.from\(.<table>.\)' -A3 app lib
  components | grep -E '\.(update|insert|upsert|delete)\('` (63 `.from()` hits on the 12 tables checked; comments excluded by reading each hit).
- en.ts: flattened by evaluating a copy of `messages/en.ts` (TS `as const` stripped) in node → `ev/en_flat.tsv` (8,225 leaf keys);
  matched by value set (`ev/en_match.txt`) and then by module namespace by hand. All quoted texts are copied from that file.
- Row counts (`ev/q2.sql`) are as `postgres` (bypasses RLS).
- Catalogue counts: `grep -cE '^\| [A-K][0-9]{2} \|' events.md` and the same with `\| (NEW|STATE)` / `\| EXISTS` on the last column.
