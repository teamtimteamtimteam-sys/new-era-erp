# Survey: bulk actions on approval-type lists (TABLE-FEATURES Step 0 input)

Repo: /Users/timchen/Documents/projects/new-era-erp. Read-only survey 2026-10-25. I only used grep, find, sed and cat. I ran no npm, build, gate or smoke, and imported no scripts.
Paths below are repo-relative.

## How things were measured
- Decision RPC call sites: `grep -rnE "rpc\(\s*['\"](decide_|approve_|reject_|pay_|withdraw_|cancel_leave|confirm_capture|portal_submission_reject|acknowledge_review|void_review|approve_review|set_review_conclusion|record_approval_decision)" app lib --include='*.ts' --include='*.tsx'` gave 49 hits (full list in section 6).
- DB rules: `grep -nE "RAISE|forbid_self|require_approver|approval_level_for|approvals_enabled|require_permission"` over each `db/functions/<fn>.sql`.
- Reason prompts: `grep -rlE 'reason=\{\{' app --include='*.tsx' | wc -l` gave **43 files** using `<ConfirmButton reason=…>`.
- Selection: `grep -rnE '\bselection[=:?]' app lib` gave **2 uses**, both in `CostSettlePanel.tsx`.
- Partial-failure patterns: `grep -rnE 'Promise\.allSettled|allSettled|failedCount|failed:|okCount|succeeded'` found **0** `Promise.allSettled` uses. The only hits were ingest counters and PDF route messages.
- Client loops that await per item: `grep -A3 'for (const x of '` piped to `grep await` found one relevant loop, `app/me/ClaimReceipts.tsx:54-59`.
- Refusal mapping style per actions file: `grep -c refuseFromCoded` and `grep -cE 'await localize[A-Za-z]+Error\('` (table in section 3).
- Paging: grepped for `.range(`, `PAGE_SIZE =`, `_SHOWN =` and `pageSize=` in the row and page files.

---

## 1. Approval-type lists

Key: **Where decided** = the screen that holds the decide buttons. **Reason on reject** names each layer that enforces it: UI (ConfirmButton `reason` keeps the confirm button disabled while the reason is blank), SA (the server action checks for blank), DB (a named RAISE).

**Main finding: almost no approval chain lets you decide from a list row.** Most "lists" are registers that link to a detail page, and the decide buttons live on that detail page. Only a few screens put decide buttons beside each item in a queue (rows 1, 6, 7, 8, 9 and 12 below).

### A. Queues with decide buttons on each item (where bulk selection could attach directly)

| # | Route / component | Per-item actions (label → server action → DB fn) | Reason on reject | Bulk today | Loading |
|---|---|---|---|---|---|
| 1 | `/finance/claims` expense-claim decision queue. Rendered as **cards, not a table** (`app/finance/claims/ClaimDecisionPanel.tsx`, page `app/finance/claims/page.tsx:100-126`) | Approve → `decideClaim` (`app/finance/claims/actions.ts:49-70`) → `decide_expense_claim_items`. Approve also needs **an account and tax code for every line plus a posting date** (`ClaimDecisionPanel.tsx:239-249`). Reject → same action with approve=false (`:251-257`). Withdraw → `withdrawClaim` → `withdraw_expense_claim` (`actions.ts:41-47`) | DB only: `EXPENSE_CLAIM_REJECT_REASON_REQUIRED` (`db/functions/decide_expense_claim_items.sql:134-135`). UI only sets a title hint (`ClaimDecisionPanel.tsx:255`). The SA does not check. | none | **Unbounded**: one query on `expense_claim_status` with no range or limit (`page.tsx:47-52`). The lower "decided" register is a DataTable without pageSize. |
| 2 | `/finance/journal` → `JournalRequestsPanel.tsx` | Approve (ConfirmButton) → `decideJournalRequest` (`app/finance/journal/requestActions.ts:21-36`) → `decide_journal_request` (`JournalRequestsPanel.tsx:169-180`). Reject (ConfirmButton + reason) (`:181-193`). Withdraw (`:198-209`) → `withdraw_journal_request` | UI + SA (`requestActions.ts:24-26`) + DB `JOURNAL_REQUEST_REJECT_REASON_REQUIRED` (`decide_journal_request.sql:51-52`) | none | Every submitted request (no limit) plus the last 10 decided (`app/finance/journal/page.tsx:100-101`) |
| 3 | `/inventory` → `app/inventory/WarehouseRequestsPanel.tsx` | Approve (`:168-176`) / Reject + reason (`:180-189`) → `decideWarehouseRequest` (`app/components/inventory/warehouseRequestActions.ts:54-69`) → `decide_warehouse_request`. Withdraw (`:197-205`) | UI + SA (`warehouseRequestActions.ts:57-58`) + DB `WAREHOUSE_REQUEST_REJECT_REASON_REQUIRED` (`decide_warehouse_request.sql:45`) | none | `warehouse_requests_visible(p_recent=>10)`: all open plus the last 10 (`app/inventory/page.tsx:96`) |
| 4 | `/contracts`, `/tools/pricing/formulas` (also each formula's edit page and `/contracts/[id]`) → `app/components/pricing/TermsRequestsPanel.tsx` | Approve (`:131-139`) / Reject + reason (`:143-152`) → `decideTermsRequest` (`termsRequestActions.ts:22-37`) → `decide_terms_request`. Withdraw (`:160-168`) | UI + SA (`termsRequestActions.ts:25-26`) + DB `TERMS_REQUEST_REJECT_REASON_REQUIRED` (`decide_terms_request.sql:45`) | none | `terms_requests_visible`: all open plus recent (`app/components/pricing/termsRequestsData.ts:117`) |
| 5 | `/finance/assets` → `app/finance/assets/AssetDisposalRequestsPanel.tsx` | Approve (`:150-158`) / Reject + reason (`:162-171`) → `decideDisposalRequest` (`disposalRequestActions.ts:47-62`) → `decide_asset_disposal_request`. Withdraw (`:179-187`) | UI + SA (`disposalRequestActions.ts:50-51`) + DB `ASSET_DISPOSAL_REJECT_REASON_REQUIRED` (`decide_asset_disposal_request.sql:43`) | none | `asset_disposal_requests_visible(p_recent=>10)` (`app/finance/assets/page.tsx:145`) |
| 6 | `/operation/capture`, the "pending drafts" DataTable. Its `actions` column is a control column (`app/operation/capture/page.tsx:138-148`); the buttons are `DraftActions` in `CaptureControls.tsx` | Reject (ConfirmButton + reason, `CaptureControls.tsx:109-122`) → `rejectDraft` (`app/operation/capture/actions.ts:49-56`) → `reject_capture_draft`. Confirm (`:140`) → `confirmDraft` (`actions.ts:31-47`) → `confirm_capture_draft`. Confirm needs a weight, a **subject**, and a reason when the weight is changed. | UI + SA (`actions.ts:50`) + DB `CAPTURE_REJECT_REASON_REQUIRED` (`reject_capture_draft.sql:18-19`) | none | **Capped at the first 200** oldest pending drafts (`captureRows.ts:22,46`). `RowCapNotice` says "first N of M" (`page.tsx:136`). Not paged. |

These are not approvals, but a decision list does already exist at `/operation/capture/inbox` (`InboxControls.tsx`). Its "Process received" button is one DB batch call that returns per-row counts (section 2c). Retry and discard are per row.

### B. Registers whose decide buttons sit only on the detail page

| # | List route (register) | Where decided | Per-row actions | Reason on reject | Paging |
|---|---|---|---|---|---|
| 7 | `/hr/leave` (`LeaveRequestsTable.tsx`, no action column) | `/hr/leave/[id]` `DecideControls.tsx:76-101` | Approve / Reject → `decideLeave` (`app/hr/leave/actions.ts:156-170`) → `decide_leave_request`. Cancel (when approved) → `cancelLeave` → `cancel_leave_request`. Notes is a free optional input (`DecideControls.tsx:66-73`). | **Not required anywhere.** `decide_leave_request.sql` takes p_notes and never raises on blank (reject path `:36-46`). | Capped: `LEAVE_SHOWN = 300` (`leaveRows.ts:18`), ordered newest start_date first. "Pending first" is sorted **after** the cap (`leaveRows.ts:72-77`), so a pending request older than the newest 300 by start date does not appear. |
| 8 | `/hr/claims` medical claims (`ClaimsTable.tsx`) | `/hr/claims/[id]` `ClaimControls.tsx:78-88` (decide), `:142-153` (Pay, ConfirmButton) | Approve / Reject → `decideClaim` (`app/hr/claims/actions.ts:35-43`) → `decide_medical_claim`. Pay → `payClaim` (`actions.ts:58-85`) → `pay_medical_claim`, which needs an expense date and a tax code when GST is on. | **Not required.** `decide_medical_claim.sql` has no reason check. | Capped: `CLAIMS_SHOWN = 300` (`claimsRows.ts:18`), ordered by claim_date desc (`:54`) |
| 9 | `/finance/payment-requests` (`PaymentRequestsTable.tsx`). Default filter "open" = submitted **+ approved** (`requestRows.ts:20,27-28`), so the approve queue and the pay queue are mixed. | `/finance/payment-requests/[id]` `RequestActions.tsx` (around `:110-198`) | Approve / Reject (ConfirmButton + reason) → `decidePaymentRequest` (`[id]/actions.ts:31-46`) → `decide_payment_request`. Pay → `payPaymentRequest` (`:57-95`) → `pay_payment_request`; it needs a date and, for payment_out, an optional rate, and the right inputs differ by kind. Withdraw → `withdraw_payment_request`. | UI + SA (`[id]/actions.ts:34-36`) + DB `PAYMENT_REQUEST_REJECT_REASON_REQUIRED` (`decide_payment_request.sql:58-59`) | **Server-paged**, `PAGE_SIZE = 20` (`page.tsx:19`), prev/next links |
| 10 | `/purchasing/orders` | `/purchasing/orders/[id]` `ApprovalControls.tsx:42-78` | Approve (ConfirmButton) → `approveOrder` (`[id]/actions.ts:75-90`) → `approve_purchase_order`. Reject (ConfirmButton + reason) → `rejectOrder` (`:94-109`) → `reject_purchase_order` | UI + DB bare `REJECT_REASON_REQUIRED` (`reject_purchase_order.sql:30-31`). The SA deliberately sends an empty string (`[id]/actions.ts:92-93`). | **Server-paged**, `PAGE_SIZE = 20` (`page.tsx:26`). **The list cannot filter or show approval_status.** `PO_STATUSES` covers draft, confirmed, receiving, closed and cancelled only (`orderRows.ts:25`); `grep approval app/purchasing/orders/*.ts*` returns 0. |
| 11 | `/hr/overtime` (`BatchesTable.tsx`) | `/hr/overtime/[id]` `BatchDetail.tsx:219-241` | Approve / Reject (ConfirmButton + reason) → `decideOvertimeBatch` (`app/hr/overtime/actions.ts:96-107`) → `decide_overtime_batch` | UI + DB `OVERTIME_REJECT_NOTE_REQUIRED` (`decide_overtime_batch.sql:48`). The SA does not check. | Unbounded (`page.tsx:29-32`) |
| 12 | `/hr/reviews` (`ReviewsTable.tsx`) | `/hr/reviews/[id]` `ReviewActions.tsx` (approve around `:133-137`, void `:184`) | Approve → `approveReview` (`actions.ts:142-148`) → `approve_review`. There is **no reject**; the only negative action is Void (needs a reason) → `void_review`. The UI hides Approve from the submitter (`ReviewActions.tsx`, `status==='submitted' && !isSubmitter`). | Void: DB `REASON_REQUIRED` (`void_review.sql:26-27`) | Capped: `REVIEWS_SHOWN = 200` (`reviewsRows.ts:19`) |
| 13 | `/quality/ncr` | `/quality/ncr/[id]/DecideForm.tsx:39` | Disposition + note → `decideNcr` (`app/quality/actions.ts:157-175`) → `decide_ncr`. The disposition decides which penalty document is required. | DB `NCR_DECISION_NOTE_REQUIRED` (`decide_ncr.sql:43`) | n/a |
| 14 | `/suppliers` (status filter, server-paged with `SUPPLIER_PAGE_SIZE`, `app/suppliers/page.tsx:51-57`) | `/suppliers/[id]/edit` `StatusPanel.tsx:140-159` | Approve / reject a supplier → `set_supplier_status` (`statusActions.ts:28`). Portal submissions: accept / reject → `portal_submission_accept/reject` (`portalSubmissionActions.ts:43-90`) | `set_supplier_status` takes only `p_note`, with no reason RAISE (`set_supplier_status.sql:26-51`) | server-paged |

### C. Approval chains with exactly one open request per parent document (one panel per detail page, so no list exists to bulk over)
- Payroll: `/hr/payroll/[id]` `PostControls.tsx:222-235` → `decide_payroll_request` (DB `PAYROLL_REQUEST_REJECT_REASON_REQUIRED`, `decide_payroll_request.sql:69-70`)
- Invoice requests: `/finance/invoices/[id]` `InvoiceRequestPanel.tsx:107-120` → `decide_invoice_request` (`INVOICE_REQUEST_REJECT_REASON_REQUIRED`, `:47`)
- GST filing: `/finance/gst/[periodId]` `GstFilingPanel.tsx:170-183` → `decide_gst_filing_request` (`:43`)
- Receipt price: `/inbound/[id]/edit` `ReceiptPriceRequestPanel.tsx:120-133` → `decide_receipt_price_request` (`:58`)
- Shipping release: `/sales/orders/[id]` `ShippingReleasePanel.tsx:183-197` → `decide_shipping_release` (`:47`)
- Salary change: `/hr/employees/[id]` `SalaryChangePanel.tsx:188-201` → `decide_salary_change_request` (`:43`)

All six follow the same three layers: UI ConfirmButton reason, SA blank check, DB named `*_REJECT_REASON_REQUIRED`.

### D. Looked at and found not to be approval lists
- `/finance/payables`: AP aging report. Its only action is a link to record a payment (`page.tsx:124-126`).
- `/finance/expenses`: register; reverse only, on the detail page.
- `/finance/self-approved`: read-only report from `self_approved_decisions`.
- `/hr/attendance`: open, sync, complete or reopen a period.
- `/settings/pending-values`: configuration to-do list.
- `/stocktakes/[id]/review`: one Post button.
- `/settings/approvals`: read-only readiness panel (`ApprovalsPanel.tsx:1-13`).
- `/me/*`, `/my-reviews`: the employee's own lists, `MY_LIST_SHOWN = 50` (`meRows.ts:15`), with withdraw and acknowledge only.

**There is no cross-chain approval inbox.** The nearest is `/tools/reminders`, which links only. It reads the `operations_now` view (`app/tools/reminders/page.tsx:105-111`), and its item types (`lib/reminders.ts:135-400`) include leave_pending, claim_pending (medical only), review_submitted, payment / payroll / receipt_price / invoice / shipping / journal / warehouse / terms / asset_disposal / salary_change / gst_filing *_pending, and supplier_pending_approval. **It has no pending-PO-approval item and no pending-expense-claim item.** `grep -nE "expense|purchase_order|po_pending" lib/reminders.ts` matched only an href builder at `:159`.
The DB has a per-row "everything awaiting approval" function, `approval_pending_documents()` (`db/functions/approval_pending_documents.sql:61-62`; 14 chains at `:69-179`: purchase_order, expense_claim, payment, payroll, receipt_price, invoice, shipping_release, journal, warehouse, terms, asset_disposal, gst_filing, salary_change, overtime_batch). However, EXECUTE has been revoked from authenticated (`:47`), and leave, medical claims, reviews, NCR and suppliers are not in it.

---

## 2. Approval engine: where rules are enforced

**Everything is enforced in the DB function. The app forwards the call and maps the error code to text.** Several actions files say so in their headers (e.g. `app/finance/claims/actions.ts:4-7`, `app/purchasing/orders/[id]/actions.ts:70-74`).

### 2a. Building blocks (db/functions)
- `approvals_enabled()` returns `COALESCE(finance_settings.approvals_enabled, false)` (`approvals_enabled.sql:1-8`).
- `approval_level_for(amount_base)` reads `approval_threshold_base`. It raises `APPROVAL_THRESHOLD_NOT_SET` (`:21-23`) and `APPROVAL_AMOUNT_REQUIRED` (`:25-26`), then returns `approval_level_at(...)`.
- `require_approver_for(level)` reads `approval_level1_role_code` and `approval_level2_role_code`. It raises `APPROVAL_LEVEL1_ROLE_NOT_SET` (`:17-18`), `APPROVAL_LEVEL2_ROLE_NOT_SET` (`:22-23`) and `APPROVAL_LEVEL_INVALID|n` (`:26`), and raises `APPROVAL_NOT_AUTHORISED|level|role` (`:32-34`) if `auth.uid()` is not in `approval_level_eligible`. Level 1 also admits level-2 holders (`approval_level_eligible.sql:37-44`).
- `forbid_self_approval(raiser, subject_employee, subject_type)` (`forbid_self_approval.sql:58-83`) uses `self_leg`, which compares people rather than accounts (the same person's other account also counts). It raises `SELF_APPROVAL_FORBIDDEN|raiser` or `|subject`. The only exception is `self_approval_exception(...)` (`self_approval_exception.sql:41-55`): an expense claim, medical claim or leave request where the user is the subject and also a real holder of the level-2 (CFO) role. `/finance/self-approved` reports those cases.
- `record_approval_decision(subject_type, id, decision, level, note)` writes approval_log on every decision (`record_approval_decision.sql:1`).
- `assert_other_decider(...)` raises a caller-supplied `*_NO_OTHER_DECIDER` code. It is used at **submit** time, not decide time (`assert_other_decider.sql:22-35`).

### 2b. Per chain
| Decide fn | Permission gate | approvals_enabled? | Level | Four-eyes |
|---|---|---|---|---|
| `approve_purchase_order` / `reject_purchase_order` | `module.purchasing.view` + `data.view_purchase_prices` (approve `:12,28`; reject `:11`) | required, `APPROVALS_NOT_ENABLED` (`:31-32` / `:14-15`) | by amount: `approval_level_for` + `require_approver_for` (`:54-55` / `:35-36`) | **Inline** `self_leg(...)` check raising the bare `SELF_APPROVAL_FORBIDDEN` (`approve_purchase_order.sql:44-49`; reject `:28`). These two do not use forbid_self_approval (see `lib/selfApproval.ts:15-17`). |
| `decide_expense_claim_items` | `module.finance.view` + `data.view_prices` (`:89-90`) | **optional**: tiered only when it is on (`:85,113-128`) | by amount | `forbid_self_approval` (`:109`) |
| `decide_payment_request`, `decide_journal_request`, `decide_warehouse_request`, `decide_terms_request`, `decide_asset_disposal_request`, `decide_invoice_request`, `decide_gst_filing_request`, `decide_receipt_price_request`, `decide_shipping_release`, `decide_payroll_request` | module + price/pay codes (e.g. payment `:40-41`) | required, `APPROVALS_NOT_ENABLED` | **fixed level 2 (CFO)**: `require_approver_for(2)` (e.g. payment `:55`, journal `:48`) | `forbid_self_approval` |
| `decide_leave_request`, `decide_medical_claim` | `action.decide_hr_requests` (`:18` / `:9`) | not consulted | none | `forbid_self_approval` (`:31` / `:17`) |
| `decide_overtime_batch` | `action.overtime_approve` (`:28`) | not required (only noted in the log, `:67-69`) | none | `forbid_self_approval` once for the submitter, then once per employee in the batch (`:41-44`) |
| `decide_salary_change_request` | `module.hr.view` + `data.view_pay` + a per-person code (`:25-35`) | — | routed by person, not by level | `forbid_self_approval` (`:39`) |
| `approve_review` | `review_approval_code(...)` (`:24`) | — | — | `forbid_self_approval` (`:39`) |
| `decide_ncr` | `action.ncr_decide` (`:28`) | — | — | `forbid_self_approval` (`:37`) |
| `set_supplier_status` (approve/reject) | `action.supplier_approve` | not part of the engine | — | `forbid_self_approval` (`:56`) |

Status guards (bulk callers will see these for stale rows): `*_NOT_SUBMITTED|code|status`, `PO_NOT_PENDING|code|status`, `REQUEST_NOT_PENDING|status` (leave), `CLAIM_NOT_SUBMITTED|status` (medical). Each names the item.

### 2c. One DB call per item? Yes.
Every `decide_*`, `approve_*` and `reject_*` takes **one document id** and runs as its own transaction (one `supabase.rpc` = one PostgREST request = one transaction). So a bulk action can loop the existing server action per id and collect a refusal for each item. **The rules need no rework.** Caveats:
- **Expense-claim approve** needs per-line account and tax codes plus a posting date (`decide_expense_claim_items.sql:153-190`: `EXPENSE_CLAIM_ACCOUNT_REQUIRED`, `_TAX_CODE_REQUIRED`, `_NO_EVIDENCE`). Bulk *reject* works; bulk *approve* cannot be one click.
- **Pay** actions (`pay_payment_request`, `pay_medical_claim`) need a date and kind-specific inputs.
- **Capture confirm** needs a weight and a subject per draft.
- **NCR** needs a disposition plus a penalty document.
- Each server action calls `revalidatePath` (e.g. `payment-requests/[id]/actions.ts` `refresh()` around `:15-29`), so N calls trigger N revalidations.

### 2d. Existing "one action, many items" patterns
1. **Single RPC over an id array, all or nothing.** `PayPanel.tsx` (checkbox column hand-built at `:182-183`, button `:234-236`) → `payLines` (`app/finance/month-end/actions.ts:20-31`) → `pay_payroll_lines(p_line_ids uuid[])`. The DB raises on the first bad line (`PAYROLL_LINE_ALREADY_PAID|emp`, `pay_payroll_lines.sql:72-87`) and the whole call rolls back. `CostSettlePanel.tsx` (DataTable `selection` at `:150,177`; buttons `:158-161`, `:212-217`) → `remitCosts` / `relieveAccruals` → `remit_processing_costs` / `relieve_processing_accruals`, also array-in and all or nothing. **Neither reports partial results.** On error they show one banner; on success they clear the selection (`CostSettlePanel.tsx:69-75`, `PayPanel.tsx:67-72`).
2. **DB-side loop with per-row outcomes.** `ingest_process_pending(p_limit)` returns `{processed, transformed, failed, awaiting}` (`ingest_process_pending.sql:14-40`). Each row runs in a subtransaction, `ingest_transform_row.sql:55` `EXCEPTION WHEN OTHERS`. The UI shows the counts (`InboxControls.tsx:32`). `master_import_apply` collects a per-row `{row, column, code}` error array (`:225-240`). `record_fx_rates_bulk` names the failing row but still rolls back (`FX_BULK_ROW|idx|msg`, `:35-38`).
3. **Client-side sequential loop with per-item problems.** `app/me/ClaimReceipts.tsx:54-62` uploads each file, collects `"${name}: ${error}"` into `problems[]`, and joins them into one error line. **This is the only client loop of this kind.** There is no `Promise.allSettled` anywhere in app/ or lib/.

---

## 3. How refusals are shown today

- **`lib/action-refusal.ts`** defines `ActionOutcome {error, detail, field, success}` (`:25-30`) and `ActionRefusal` (`:32-45`). `refusePermission` (`:54`) turns `PERMISSION_DENIED|code` into one sentence. `refuseFromDriver` (`:63`) handles unrecognised text. `refuseFromCoded(raw, localize)` (`:173-196`) parses `CODE|args`, routes PERMISSION_DENIED, uses the domain localizer, and otherwise falls back to the driver text, with the raw text placed in `detail`.
- **60 `*ErrorCodes.ts` files** (`find app lib -name '*ErrorCodes.ts' | wc -l`); 37 files call `refuseFromCoded`. `SELF_APPROVAL_FORBIDDEN` text is shared through `lib/selfApproval.ts:18` (two sentences, raiser and subject, plus the bare code), and 20 localizers reference it.
- Mapping style per decision actions file (`grep -c`):
  - Use `refuseFromCoded` (returns `detail`): payment-requests, journal requestActions, warehouse, terms, asset-disposal, salary change, invoices (partly), capture.
  - Use plain `{error: await localizeXError()}` with no `detail`: leave, hr/claims, finance/claims, purchasing orders, overtime, reviews, quality/NCR, hr/payroll, gst, inbound pricing, sales orders.
- **Display.**
  - The newer request panels call `showActionMessage({subject, headline, body, detail})` (`app/components/ui/action-message.tsx:73-101`). That is a page-level, non-blocking region holding a **list** of entries, each with a required `subject` (e.g. `JournalRequestsPanel.tsx:88-97`, `WarehouseRequestsPanel.tsx:78`). 37 files use it. Because it takes one entry per item and each entry names its item, it already fits per-item bulk refusals.
  - The older screens (leave `DecideControls.tsx:54-58`, ClaimDecisionPanel, PayPanel, CostSettlePanel) keep a local `error` string shown as a red box.
- **Reusable reason prompt: yes, `ConfirmButton` with the `reason={{ placeholder }}` prop** (`app/components/ui/confirm-dialog.tsx:68-108`, `369-393`). It adds a required textarea, the confirm button stays disabled while `reason.trim()===''` (`:124`, `:309`), and the text goes to `onConfirm(reason)`. The old `app/components/ReasonPrompt.tsx` was folded into it and deleted (`confirm-dialog.tsx:92-96`). 43 files use `reason={{`. It is a button that triggers its own dialog. There is no standalone imperative `useConfirm`, and only `ConfirmTier`, `ConfirmContent` and `ConfirmButton` are exported (`grep '^export'`: `:66,68,369`). A bulk "Reject N selected" button can still be a ConfirmButton with `reason` and a `subject` like "3 claims".
- `app/components/ui/refusal.tsx` is the "restricted / not recorded" pill for data states, not for action refusals.

---

## 4. Paging: what "select all" could mean

DataTable select-all toggles only `visible` (`data-table.tsx:610-617`). `visible` is the client-side page slice when `pageSize` is set (`:465-467`). None of the approval lists set a DataTable `pageSize` (`grep pageSize=` over their tables returns 0).

| List | How rows reach the screen | "Select all" covers |
|---|---|---|
| `/finance/payment-requests` | **server-paged**, 20/page (`page.tsx:19`, `requestRows.ts:58`) | **only the 20 on screen** |
| `/purchasing/orders` | **server-paged**, 20/page (`page.tsx:26,57`) | only the page on screen (and the list shows no approval status) |
| `/suppliers` | **server-paged** (`page.tsx:51-57`) | page only |
| `/hr/leave` | capped at the first 300, no paging (`leaveRows.ts:18`, `page.tsx:41`, RowCapNotice `:107`) | the shown 300, not all matches |
| `/hr/claims` | capped at the first 300 (`claimsRows.ts:18`) | shown 300 |
| `/hr/reviews` | capped at the first 200 (`reviewsRows.ts:19`) | shown 200 |
| `/operation/capture` pending drafts | capped at the first 200 (`captureRows.ts:22`, `page.tsx:47`) | shown 200 |
| `/finance/claims` queue | unbounded single read (`page.tsx:47-52`) | all |
| `/finance/journal` requests | all submitted, unbounded (`journal/page.tsx:100`) | all |
| `/inventory`, `/contracts` + `/tools/pricing/formulas`, `/finance/assets` request panels | all open, via `*_visible(p_recent)` | all |
| `/hr/overtime` | unbounded (`page.tsx:29-32`) | all |

---

## 5. Surprises
1. **There is almost no list-level deciding.** Leave, medical claims, payment requests, POs, overtime and reviews all decide only on the detail page. A bulk action there would be new list-level deciding, not a batch version of existing row buttons.
2. **Leave and medical-claim reject need no reason anywhere** (UI, SA or DB), unlike every engine chain. A bulk reject would make this gap more visible.
3. **The PO list can neither show nor filter `approval_status`**, and reminders has no pending-PO item. Nothing in the app lists pending POs.
4. **Expense claims are missing from `/tools/reminders`**, and the claim queue renders as cards rather than a DataTable. Approving an expense claim needs per-line account and tax codes, so only bulk reject can be a single click.
5. **`/hr/leave` sorts "pending first" after the 300-row cap** (`leaveRows.ts:72-77`), so old pending requests can fall off the list.
6. **The payment-requests default filter mixes "approve" (submitted) and "pay" (approved) rows.** Those are two different actions with different inputs.
7. **PO approve and reject use an inline bare `SELF_APPROVAL_FORBIDDEN`**, not `forbid_self_approval` (deliberately left, `lib/selfApproval.ts:15-17`).
8. **Every existing multi-item write is all or nothing** (array RPC). The only per-item partial reporting is in ingest and import (DB) and in the ClaimReceipts upload loop (client).
9. **The reviews UI hides Approve from the submitter** (`!isSubmitter`), duplicating the DB four-eyes rule. The other panels show the button and let the DB refuse.

## 6. Raw RPC call-site list (49 hits)
- `app/operation/capture/actions.ts:38,52`
- `app/operation/weighbridge/actions.ts:63`
- `app/suppliers/[id]/edit/portalSubmissionActions.ts:85`
- `app/sales/orders/actions.ts:212,227`
- `app/quality/actions.ts:109,162`
- `app/purchasing/orders/[id]/actions.ts:80,99`
- `app/components/inventory/warehouseRequestActions.ts:61,73`
- `app/components/pricing/termsRequestActions.ts:29,41`
- `app/inbound/[id]/edit/pricingActions.ts:81,96`
- `app/hr/payroll/actions.ts:148,160`
- `app/hr/overtime/actions.ts:61,87`
- `app/hr/leave/actions.ts:162,174`
- `app/hr/claims/actions.ts:37,49,65`
- `app/hr/reviews/actions.ts:115,144,152,164`
- `app/hr/employees/salaryChangeActions.ts:51,63`
- `app/finance/journal/requestActions.ts:28,42`
- `app/finance/month-end/actions.ts:26,37,47`
- `app/finance/gst/actions.ts:51,63`
- `app/finance/invoices/[id]/actions.ts:65,80`
- `app/finance/fx/[id]/edit/actions.ts:89`
- `app/finance/payment-requests/[id]/actions.ts:38,50,87`
- `app/finance/assets/disposalRequestActions.ts:54,66`
- `app/finance/claims/actions.ts:43,58`
