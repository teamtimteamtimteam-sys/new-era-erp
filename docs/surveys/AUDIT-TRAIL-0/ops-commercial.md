# AUDIT-TRAIL-0 · Operation map · COMMERCIAL slice

Slice: `app/purchasing/**`, `app/sales/**`, `app/suppliers/**`, `app/logistics/**`, `app/documents/**`, `app/margin/**`, `app/related/**`,
plus the out-of-slice action one of these pages calls (`app/finance/cash-forecast/actions.ts:setExpectedDate`, used by the PO page)
and the shared `app/components/IssuePanel.tsx` (the Issue PDF button). Surveyed 2026-09-29. Read-only: no repo file touched; the live DB was read with `BEGIN READ ONLY … ROLLBACK`
as `postgres` (**rolbypassrls = true**, so every live row count below ignores RLS and counts every row).

## 0. Counts and how they were measured

| # | Number | Method | Kind |
|---|---|---|---|
| a | **30** `'use server'` files in the slice (none in documents/margin/related) | `grep -rlE "^.use server" app/{purchasing,sales,suppliers,logistics,documents,margin,related}` | Measured |
| b | **75** exported server actions in those 30 files | `grep -hE "^export async function" <those files> \| wc -l` | Measured |
| c | **6 of 75** are read-only (`computeLineEstimate`, `collectionContext`, `previewStatement`, `getAttachmentDownloadUrl` ×2, `listCustomersAndMaterials`) | read each body. Their RPCs have empty `all` in fnmap, or the body only calls `.select` / `createSignedUrl` | Measured |
| d | **69** data-writing server actions in the slice, plus **1** out-of-slice action (`setExpectedDate`) and **4** PDF-issuing POST route handlers = **74 write entry points** | c subtracted from b; route handlers from `grep "export async function POST"` in `*/pdf/route.ts` (4 of 4 POST routes record an issue) | Measured |
| e | **2 of 74** have **no UI caller**: `updateQuoteHeader`, `softDeleteCommissionAgreement` (dead code) | `grep -rnw <name> app lib tests` finds only the definition | Measured |
| f | **1 of 74** is **broken on live**: `setDeepDischargeJudgement` does a direct `UPDATE purchase_order_lines`, but APR-10 dropped that table's write policies and added the statement-level `trg_purchase_order_lines_direct_write` → `guard_po_direct_write()`, which unconditionally raises `PO_THROUGH_FUNCTION_ONLY` whenever RLS is active (that is, for any `authenticated` caller). Live: **0 of 11** `purchase_order_lines` rows have `deep_discharge_judgement_code` set | trigger definition via `pg_get_triggerdef`; `db/tables/purchase_order_lines.sql:115-116,227-230`; `SELECT count(*) FILTER (WHERE deep_discharge_judgement_code IS NOT NULL), count(*) FROM purchase_order_lines` (bypass-RLS) | Failure mode **Inferred** (no write was attempted). Row count **Measured** |
| g | **51** distinct `.rpc('<fn>')` names in the slice (plus `cash-forecast/actions.ts`). **32** of them write (non-empty `all` in fnmap) | `grep -rhoE "\.rpc\('[a-z_0-9]+'"` → `at0/commercial_rpcs.txt`, looked up in `fnmap.json` | Measured |
| h | **76 user operations** in §1 (16 purchasing, 20 sales-doc, 11 customer, 2 commission, 11 supplier/forwarder, 16 logistics). Each of the 74 entry points appears once; a few are listed twice because one action serves two user intents (for example createSupplier = new supplier / new forwarder) | hand grouping of d | Measured (enumeration) |
| i | **40** `page.tsx` in the slice. **0** write on load: every RPC a page calls at render (`po_document_data`, `po_may_manage`, `po_category_raise_code`, `approvals_enabled`, `shipping_release_context`, `shipment_document`, `shipping_queue_rows`, `supplier_status_moves`, `customer_collection_context`) has empty `direct` and `all` in fnmap, and no page body calls insert/update/delete/upsert | `find … -name page.tsx`; `grep` of `.rpc(`/`.from(` per page dir; fnmap lookup | Measured |
| j | **15** pages should carry a trail (§4): 12 detail/edit pages + 3 list pages that are the only host for their records | §4 | Inferred (judgement) |

Permission codes for RPCs were taken from `require_permission(...)`/`has_permission(...)` in `funcs.csv`. Codes for direct table writes come from the
`enforce_write_permission` trigger arguments (UPDATE/DELETE only; `pg_trigger.tgargs`) and from the RLS INSERT/ALL policies (`pg_policies`), both read live.
fnmap `all` is an **upper bound**: branches are not evaluated. Where I checked a trigger body and the history row is conditional, I say so.

---

## 1. Operation map

Column key: **Entry** = route · page file · control component. **Perm** = the code the database enforces (the UI `PermissionGate` mirrors it unless noted).
**Direct** = tables the action/RPC writes itself. **Trans.** = additional tables reached via calls/triggers (fnmap `all` minus `direct`).
**Primary** = the record the operation acts on. **Trail page** = where its audit entry should appear. **Ev?** = **E** key business event (status transition / step / document issued) · **F** plain field edit / master-data edit.

### 1A. Purchase orders

| ID | User words | Entry (route · page · control) | Server action | RPC | Perm | Direct | Trans. | Primary | Trail page | Ev? |
|---|---|---|---|---|---|---|---|---|---|---|
| P1 | Raise a purchase order | `/purchasing/orders/new` · `app/purchasing/orders/new/page.tsx` · `NewOrderForm.tsx` | `app/purchasing/orders/new/actions.ts:createOrder` | `create_purchase_order` | `action.raise_po_consumables` / `_equipment` / `_office` by category (`po_category_raise_code`) | purchase_orders IU, purchase_order_lines I, purchase_order_payment_terms I, purchase_order_line_retentions I | approval_log I (`auto_approved` when approvals are off), pricing_term_commitments I, pricing_term_commitment_metals I, purchase_order_history I (upper bound: the line/term history triggers skip INSERT outside amend ctx) | purchase_orders | `/purchasing/orders/[id]` (`app/purchasing/orders/[id]/page.tsx`) | E (created) |
| P2 | Approve a purchase order | `/purchasing/orders/[id]` · page.tsx · `ApprovalControls.tsx` (shown only when approvals are on and the PO is pending) | `orders/[id]/actions.ts:approveOrder` | `approve_purchase_order` | `module.purchasing.view` + `data.view_purchase_prices` + `require_approver_for(level)` | purchase_orders U (approval_status, approved_at/by, draft→confirmed) | approval_log I (`record_approval_decision`), purchase_order_history I (upper bound: the header trigger ignores status columns, so no history row) | purchase_orders | same | E |
| P3 | Reject a purchase order | same · `ApprovalControls.tsx` | `…/actions.ts:rejectOrder` | `reject_purchase_order` | `module.purchasing.view` + `require_approver_for(level)` | purchase_orders U | approval_log I | purchase_orders | same | E |
| P4 | Amend a PO (header, lines, payment schedule) | `/purchasing/orders/[id]/amend` · `amend/page.tsx` · `amend/AmendOrderForm.tsx` | `orders/[id]/amend/actions.ts:amendOrder` | `amend_purchase_order` | `assert_po_manager` = the raiser, or holder of the category's raise code (`po_may_manage`). The page gates on `requireModule(purchasing)` + `requireAllowed(po_may_manage)` | purchase_orders U, purchase_order_lines DIU, purchase_order_payment_terms DI(upsert) | purchase_order_history I (header/line/term triggers with the reason), approval_log I (`void_approval_on_amount_increase`) | purchase_orders | `/purchasing/orders/[id]` (also shown on the amend page) | E (amendment; may void approval) |
| P5 | Cancel a PO | `/purchasing/orders/[id]` · `CancelOrderControl.tsx` | `…/actions.ts:cancelOrder` | `cancel_purchase_order` | `assert_po_manager` | purchase_orders U, purchase_order_history I (`cancelled` + reason + changed_by) | approval_log I (upper bound) | purchase_orders | same | E |
| P6 | Close a PO | same · `CloseReopenControls.tsx:CloseOrderControl` | `…/actions.ts:closeOrder` | `close_purchase_order` | `assert_po_manager` | purchase_orders U (status closed, closed_at, **note appended to `notes`**) | purchase_order_history I: the appended note fires `trg_po_history_header`, logged as a reasonless `header_update` (**Inferred** from the trigger body); approval_log (upper bound) | purchase_orders | same | E |
| P7 | Reopen a PO | same · `CloseReopenControls.tsx:ReopenOrderControl` | `…/actions.ts:reopenOrder` | `reopen_purchase_order` | `assert_po_manager` | purchase_orders U (status, closed_at NULL, reason appended to `notes`) | as P6 | purchase_orders | same | E |
| P8 | Issue the PO PDF (new version to the supplier) | same · `app/components/IssuePanel.tsx` → `POST /purchasing/orders/[id]/pdf` | `app/purchasing/orders/[id]/pdf/route.ts:POST` (route handler, not a server action) | `record_po_issue` (refuses unless approval_status = approved) | `module.purchasing.edit` | po_issues I; Storage bucket `po-documents` (object upload) | — | purchase_orders | same | E (issued vN) |
| P9 | Link a PO to a contract | same · `ContractLinkPanel.tsx` | `orders/[id]/contractActions.ts:linkOrderToContract` | `link_document_to_contract` | `module.suppliers.edit` (PO side; `module.customers.edit` for the SO side) | contract_document_terms I, purchase_orders U (contract_id) | purchase_order_history (upper bound; contract_id is not a watched column, so no row), approval_log (upper bound) | purchase_orders | same (and `/contracts/[id]`, outside this slice) | E (linked) |
| P10 | Record the deep-discharge judgement on a PO line | same · `PoLinesTable.tsx` → `DeepDischargeJudgementControl.tsx` | `…/actions.ts:setDeepDischargeJudgement` | — (direct `.from('purchase_order_lines').update`) | intended `module.purchasing.edit`; **blocked on live** by `guard_po_direct_write` (see §0 f) | purchase_order_lines U | purchase_order_history (the line trigger ignores this column, so no row) | purchase_orders (child: line) | same | F. **BROKEN** |
| P11 | Set the expected date of a payment instalment | same · `PoPaymentTermsTable.tsx` → `ExpectedDateControl.tsx` | `app/finance/cash-forecast/actions.ts:setExpectedDate` (out of slice) | `set_payment_term_expected_date` | `module.purchasing.edit` | purchase_order_payment_terms U (expected_date, _set_by, _set_at) | purchase_order_history (upper bound; the term trigger's jsonb excludes expected_date, so no row) | purchase_orders (child: term) | same | F |
| P12 | Release a retention (warranty holdback) | same · `RetentionPanel.tsx` | `…/actions.ts:releaseRetention` | `release_purchase_order_retention` | `module.finance.edit` | purchase_order_line_retentions U | — | purchase_orders (child via line) | same | E |
| P13 | Create / edit a payment-term template | `/purchasing/payment-terms/new`, `/purchasing/payment-terms/[id]/edit` · `new/page.tsx`, `[id]/edit/page.tsx` · `TemplateForm.tsx` | `purchasing/payment-terms/actions.ts:saveTemplate` | — direct | `module.purchasing.edit` (RLS INSERT/DELETE + trigger UPDATE) | payment_term_templates I/U, payment_term_template_lines D then I (full replace) | — | payment_term_templates | `/purchasing/payment-terms/[id]/edit` | F |
| P14 | Delete a payment-term template | `/purchasing/payment-terms` · `page.tsx` · `TemplatesTable.tsx` → `DeleteTemplateButton.tsx` | `…/payment-terms/actions.ts:deleteTemplate` | — | `module.purchasing.edit` | payment_term_templates U (deleted_at) | — | payment_term_templates | see §3 | E (deleted) |
| P15 | Change receiving (GRN) discrepancy thresholds | `/purchasing/discrepancies` · `page.tsx` · `ReceivingThresholdPanel.tsx` | `purchasing/discrepancies/thresholdActions.ts:updateGrnThresholds` | — | `module.inbound.edit` (panel visible with `module.inbound.view`) | receiving_settings U (singleton `id = true`) | — | receiving_settings | see §3 | F (setting) |
| P16 | Add / edit / remove a company licence | `/purchasing/licences` · `page.tsx` · `LicencePanel.tsx` | `purchasing/licences/licenceActions.ts:saveLicence`, `:softDeleteLicence` | — | `module.suppliers.edit` | company_compliance I/U (soft delete = U deleted_at) | — | company_compliance | see §3 | F |

### 1B. Quotes, sales orders, shipments

| ID | User words | Entry | Server action | RPC | Perm | Direct | Trans. | Primary | Trail page | Ev? |
|---|---|---|---|---|---|---|---|---|---|---|
| S1 | Create a quote | `/sales/quotes/new` · `new/page.tsx` · `NewQuoteForm.tsx` | `sales/quotes/actions.ts:createQuote` | — direct | `module.sales.edit` (RLS INSERT; page `requireEditPermission`) | quotes I, quote_lines I | quote_history I (`trg_quote_history_created`) | quotes | `/sales/quotes/[id]` (`app/sales/quotes/[id]/page.tsx`) | E (created) |
| S2 | Change a quote line's quantity / price | `/sales/quotes/[id]` · page.tsx · `QuoteLinesEditor.tsx` | `…:updateQuoteLine` | — | `module.sales.edit` | quote_lines U | quotes U (`trg_quote_line_touches_parent`). **No quote_history row** | quotes | same | F |
| S3 | Add a quote line | same | `…:addQuoteLine` | — | `module.sales.edit` | quote_lines I | as S2 | quotes | same | F |
| S4 | Remove a quote line | same | `…:removeQuoteLine` | — | `module.sales.edit` | quote_lines **D (hard delete)** | as S2 | quotes | same | F |
| S5 | Change quote validity / notes | **no UI caller** | `…:updateQuoteHeader` | — | `module.sales.edit` | quotes U | — | quotes | same | F (dead) |
| S6 | Convert a quote into a sales order | same · `ConvertControl.tsx` | `…:convertQuote` | `convert_quote` | `module.sales.edit` | quotes U, quote_history I, sales_order_history I | sales_orders I, sales_order_lines I | quotes → new sales_orders | **both** `/sales/quotes/[id]` and `/sales/orders/[id]` | E |
| S7 | Decline a quote | same · `DeclineControl.tsx` | `…:declineQuote` | `decline_quote` | `module.sales.edit` | quotes U, quote_history I | — | quotes | `/sales/quotes/[id]` | E |
| S8 | Issue the quotation PDF | same · `IssuePanel.tsx` → `POST /sales/quotes/[id]/pdf` | `sales/quotes/[id]/pdf/route.ts:POST` | `record_qt_issue` | `module.sales.edit` | qt_issues I, quotes U, quote_history I; Storage upload | — | quotes | same | E |
| S9 | Create a sales order | `/sales/orders/new` · `new/page.tsx` · `NewOrderForm.tsx` | `sales/orders/actions.ts:createSalesOrder` | `create_sales_order` | `module.sales.edit` | sales_orders I, sales_order_lines I, sales_order_history I | — | sales_orders | `/sales/orders/[id]` (`app/sales/orders/[id]/page.tsx`) | E |
| S10 | Confirm / cancel / close a sales order | `/sales/orders/[id]` · page.tsx · `TransitionPanel.tsx` (moves allowed by `SO_ALLOWED_NEXT`: draft→confirmed/cancelled, confirmed→cancelled, shipped→closed) | `…:transitionOrder` | `set_sales_order_status` | `module.sales.edit` | sales_orders U, sales_order_history I | sales_order_reservations IU, inventory_movements I (reservations released on cancel) | sales_orders | same | E |
| S11 | Amend a sales order | `/sales/orders/[id]/amend` · `amend/page.tsx` · `amend/AmendOrderForm.tsx` | `sales/orders/[id]/amend/actions.ts:amendOrder` | `amend_sales_order` | `module.sales.edit` | sales_orders U, sales_order_lines DIU | sales_order_history I (header/line with reason) | sales_orders | `/sales/orders/[id]` | E |
| S12 | Reserve stock for an order line | same · `ReservationSection.tsx` → `ReserveControl.tsx` | `…:reserveForLine` | `reserve_stock` | `module.sales.edit` | — (via callees) | sales_order_reservations I, inventory_movements I, sales_order_history I | sales_orders (child via line) | same (plus the output batch page, outside this slice) | E |
| S13 | Release a reservation | same · `ReleaseControl.tsx` | `…:releaseReservation` | `release_reservation` | `module.sales.edit` | — | sales_order_reservations IU, inventory_movements I, sales_order_history I | sales_orders | same | E |
| S14 | Invoice a sales order | same · `OrderInvoiceSection.tsx` → `CreateOrderInvoiceControl.tsx` | `…:createOrderInvoice` | `create_order_invoice` | `module.finance.edit` | invoices I, invoice_lines I, sales_order_history I | invoice_lines U, journal_entries I, journal_lines I | sales_orders → new invoices | `/sales/orders/[id]` + `/finance/invoices/[id]` | E |
| S15 | Ask for a shipping release (credit/price exception) | same · `ShippingReleaseSection.tsx` → `ShippingReleasePanel.tsx` | `…:submitShippingRelease` | `submit_shipping_release` | `action.request_shipping_release` | shipping_releases I, shipping_release_lines I | approval_log I (subject `shipping_release`) | sales_orders (child: release) | `/sales/orders/[id]` | E |
| S16 | Approve / reject a shipping release | same panel | `…:decideShippingRelease` | `decide_shipping_release` | `module.sales.view` + `data.view_prices` + `require_approver_for(2)` | shipping_releases U | approval_log I | sales_orders (child) | same | E |
| S17 | Withdraw a shipping release request | same panel | `…:withdrawShippingRelease` | `withdraw_shipping_release` | `action.request_shipping_release` | shipping_releases U | — | sales_orders (child) | same | E |
| S18 | Issue the sales-order PDF | same · `IssuePanel.tsx` → `POST /sales/orders/[id]/pdf` | `sales/orders/[id]/pdf/route.ts:POST` | `record_so_issue` | `module.sales.edit` | so_issues I, sales_order_history I; Storage upload | — | sales_orders | same | E |
| S19 | Ship an order (from the shipping queue) | `/logistics/shipping` · `app/logistics/shipping/page.tsx` · `ShipQueueControl.tsx` | `logistics/shipping/actions.ts:shipFromQueue` | `ship_order` | `action.ship_goods` | shipments I, shipment_lines I, sales_orders U, sales_order_reservations U, output_batches U, inventory_movements I, sales_records IU, sales_record_movements I, sales_order_history I | journal_entries I, journal_lines I, sales_order_reservations I | sales_orders → new shipments | `/sales/orders/[id]` **and** `/sales/shipments/[id]` | E |
| S20 | Issue the delivery note PDF | `/sales/shipments/[id]` · `app/sales/shipments/[id]/page.tsx` · `IssuePanel.tsx` → `POST …/pdf` | `sales/shipments/[id]/pdf/route.ts:POST` | `record_shipment_issue` | `action.ship_goods` | shipment_issues I; Storage upload | — | shipments | `/sales/shipments/[id]` | E |

### 1C. Customers

| ID | User words | Entry | Server action | RPC | Perm | Direct | Trans. | Primary | Trail page | Ev? |
|---|---|---|---|---|---|---|---|---|---|---|
| C1 | Add a customer (with a first contact) | `/sales/customers/new` · `new/page.tsx` · `NewCustomerForm.tsx` | `sales/customers/new/actions.ts:createCustomer` | `save_counterparty_contact` (after a direct insert) | `module.customers.edit` | customers I, counterparty_contacts IU | — | customers | `/sales/customers/[id]` (`app/sales/customers/[id]/page.tsx`) | E (created) |
| C2 | Edit customer details | `/sales/customers/[id]/edit` · `[id]/edit/page.tsx` · `EditCustomerForm.tsx` | `…/[id]/edit/actions.ts:updateCustomer` | — | `module.customers.edit` | customers U | customer_credit_history (trigger `log_customer_credit_change`, only when credit columns change; `guard_customer_credit_write` blocks that path) | customers | `/sales/customers/[id]` | F |
| C3 | Delete a customer | `/sales/customers` · `page.tsx` · `CustomersTable.tsx` → `DeleteButton.tsx` | `sales/customers/actions.ts:softDeleteCustomer` | — | `module.customers.edit` | customers U (deleted_at) | — | customers | see §3 | E (deleted) |
| C4 | Set credit limit / credit hold | `/sales/customers/[id]` · page.tsx · `[id]/CreditPanel.tsx` | `sales/customers/creditActions.ts:setCustomerCredit` | `set_customer_credit` | `action.customer_credit` | customers U | customer_credit_history I | customers | same | E (credit decision) |
| C5 | Issue a customer statement | same · `StatementPanel.tsx` | `statementActions.ts:issueStatement` | `issue_customer_statement` | `module.finance.edit` | customer_statements IU (supersede) | — | customers (child: statement) | same | E |
| C6 | Record a collection chase (call/email + optional promise) | same · `ChasePanel.tsx` | `chaseActions.ts:recordChase` | `record_collection_chase` | `module.finance.edit` | collection_chases IU, collection_chase_documents I, collection_promises I | — | customers (child: chase) | same | E |
| C7 | Record a payment-promise outcome | same · `ChasePanel.tsx` | `chaseActions.ts:recordPromiseOutcome` | `record_promise_outcome` | `module.finance.edit` | collection_promises U | — | customers (child) | same | E |
| C8 | Add / edit a contact (customer or supplier) | `/sales/customers/[id]` and `/suppliers/[id]/edit` · `app/sales/customers/ContactsPanel.tsx` | `sales/customers/contactActions.ts:saveContact` | `save_counterparty_contact` | `module.customers.edit` (customer side) / `module.suppliers.edit` (supplier side) | counterparty_contacts IU | — | customers or suppliers | the page it was done on | F |
| C9 | Remove a contact | same | `…:removeContact` | `soft_delete_counterparty_contact` | same pair | counterparty_contacts U | — | same | same | F |
| C10 | Upload a customer attachment | `/sales/customers/[id]/edit` · `AttachmentsPanel.tsx` (the browser uploads to Storage first) | `[id]/edit/attachmentActions.ts:recordAttachment` | — | `module.customers.edit` | customer_attachments I | — | customers | `/sales/customers/[id]` | F |
| C11 | Delete a customer attachment | same | `…:deleteAttachment` | — | `module.customers.edit` | customer_attachments U (soft) | — | customers | same | F |

### 1D. Commission agreements

| ID | User words | Entry | Server action | Perm | Direct | Primary | Trail page | Ev? |
|---|---|---|---|---|---|---|---|---|
| K1 | Create / edit a commission agreement | `/sales/commissions/new`, `/sales/commissions/[id]/edit` · `CommissionForm.tsx` | `sales/commissions/actions.ts:saveCommissionAgreement` | `module.suppliers.edit` (RLS ALL + trigger) | commission_agreements I/U | commission_agreements | `/sales/commissions/[id]/edit` | F |
| K2 | Delete a commission agreement | **no UI caller** | `…:softDeleteCommissionAgreement` | same | commission_agreements U | commission_agreements | (§3) | E (dead) |

### 1E. Suppliers and forwarders (a forwarder is a `suppliers` row with `counterparty_type = 'forwarder'`)

| ID | User words | Entry | Server action | RPC | Perm | Direct | Trans. | Primary | Trail page | Ev? |
|---|---|---|---|---|---|---|---|---|---|---|
| SU1 | Add a supplier (starts as draft) | `/suppliers/new` · `new/page.tsx` · `NewSupplierForm.tsx` | `suppliers/new/actions.ts:createSupplier` | — | `module.suppliers.edit` | suppliers I | — | suppliers | `/suppliers/[id]/edit` (`app/suppliers/[id]/edit/page.tsx`, the only supplier detail page) | E |
| SU1b | Add a forwarder | `/logistics/forwarders` · `page.tsx` · `NewForwarderForm.tsx` | same `createSupplier` (counterparty_type forwarder) | — | `module.suppliers.edit` | suppliers I | — | suppliers | `/logistics/forwarders/[id]` | E |
| SU2 | Edit supplier details | `/suppliers/[id]/edit` · `EditSupplierForm.tsx` | `suppliers/[id]/edit/actions.ts:updateSupplier` | — | `module.suppliers.edit` | suppliers U | — | suppliers | same | F |
| SU3 | Submit / approve / reject / activate / suspend / blacklist / archive a supplier | same · `StatusPanel.tsx` | `statusActions.ts:changeSupplierStatus` | `set_supplier_status` | per move from `supplier_status_moves()`: `module.suppliers.edit`, or `action.supplier_approve` for approve/reject/blacklist; no self-approval | suppliers U | supplier_status_history I, approval_log I (submitted/approved/rejected) | suppliers | same | E |
| SU4 | Delete a supplier | `/suppliers` · `page.tsx` · `SuppliersTable.tsx` → `DeleteButton.tsx` | `suppliers/actions.ts:softDeleteSupplier` | — | `module.suppliers.edit` | suppliers U | — | suppliers | see §3 | E |
| SU5 | Add a compliance certificate | `/suppliers/[id]/edit` · `CompliancePanel.tsx` | `complianceActions.ts:addCompliance` | — | `module.suppliers.edit` | supplier_compliance I | — | suppliers | same | F |
| SU6 | Remove a compliance certificate | same | `…:deleteCompliance` | — | same | supplier_compliance U (soft) | — | suppliers | same | F |
| SU7 | Upload a supplier attachment | same · `AttachmentsPanel.tsx` | `attachmentActions.ts:recordAttachment` | — | same | supplier_attachments I | — | suppliers | same | F |
| SU8 | Delete a supplier attachment | same | `…:deleteAttachment` | — | same | supplier_attachments U | — | suppliers | same | F |
| SU9/10 | Add/edit/remove a supplier contact | = C8/C9 on `/suppliers/[id]/edit` | | | `module.suppliers.edit` | counterparty_contacts | | suppliers | same | F |

### 1F. Logistics

| ID | User words | Entry | Server action | RPC | Perm | Direct | Trans. | Primary | Trail page | Ev? |
|---|---|---|---|---|---|---|---|---|---|---|
| L1 | Book a container | `/logistics/containers` · `page.tsx` · `NewContainerForm.tsx` | `logistics/containers/actions.ts:createContainer` | `create_container` | `module.purchasing.edit` | containers I | — | containers | `/logistics/containers/[id]` (`app/logistics/containers/[id]/page.tsx`) | E |
| L2 | Edit container details (number, vessel, voyage, B/L, dates) | `/logistics/containers/[id]` · page.tsx · `ContainerPanels.tsx` | `containers/[id]/actions.ts:saveContainerHead` | — | `module.purchasing.edit` | containers U | — | containers | same | F |
| L3 | Put a shipment into a container | same | `…:attachShipment` | `attach_shipment_to_container` | `module.purchasing.edit` | shipments U (container_id) | — | containers (+ shipments) | container page **and** `/sales/shipments/[id]` | E |
| L4 | Take a shipment out of a container (with reason) | same | `…:detachShipment` | `detach_shipment_from_container` | `module.purchasing.edit` | shipments U, container_milestones I | — | containers | both | E |
| L5 | Record a container milestone (append-only; a correction is a new row) | same | `…:addMilestone` | — | `module.purchasing.edit` (RLS INSERT) | container_milestones I | — | containers | container page | E |
| L6 | Generate the lane's document checklist | same | `…:instantiateDocuments` | `instantiate_container_documents` | `module.purchasing.edit` | container_documents I | — | containers | same | E |
| L7 | Mark a container document received / not applicable | same | `…:setDocumentStatus` | — | `module.purchasing.edit` | container_documents U | — | containers | same | E (step) |
| L8 | Add an extra container document | same | `…:addDocument` | — | same | container_documents I | — | containers | same | F |
| L9 | Add a port | `/logistics/lanes` · `page.tsx` · `LanesPanel.tsx` | `logistics/lanes/actions.ts:addPort` | — | `module.purchasing.edit` | ports I | — | ports | see §3 | F |
| L10 | Add a lane | same | `…:addLane` | — | same | lanes I | — | lanes | §3 | F |
| L11 | Add a lane document requirement | same | `…:addRequirement` | — | same | lane_document_requirements I | — | lanes | §3 | F |
| L12 | Remove a lane document requirement | same | `…:removeRequirement` | — | same | lane_document_requirements U (soft) | — | lanes | §3 | F |
| L13 | Mark a lane's checklist reviewed | same | `…:markLaneReviewed` | — | same | lanes U (checklist_reviewed_at) | — | lanes | §3 | E (review) |
| L14 | Save forwarder details | `/logistics/forwarders/[id]` · page.tsx · `ForwarderPanels.tsx` | `forwarders/[id]/actions.ts:saveForwarderDetails` | — | `module.purchasing.edit` (**not** `suppliers.edit`) | forwarder_details upsert (IU) | — | suppliers (forwarder) | `/logistics/forwarders/[id]` | F |
| L15 | Add a freight rate quote | same | `…:addRateQuote` | — | same | forwarder_rate_quotes I | — | suppliers (forwarder) | same | F |
| L16 | Remove a freight rate quote | same | `…:removeRateQuote` | — | same | forwarder_rate_quotes U (soft) | — | same | same | F |

`/documents/[key]`, `/related/[subject]/[id]/[target]`, `/margin`, `/sales/customers/overlap`, `/purchasing`, `/sales`, `/logistics` and the list pages
are **read-only**. They contain no write control. **Measured:** no action import, and no insert/update/delete/upsert in their files.

---

## 2. Operations grouped by the trail page that hosts them (quick index)

| Trail page | Operations |
|---|---|
| `/purchasing/orders/[id]` | P1–P12 (P4 is also shown on `/amend`) |
| `/purchasing/payment-terms/[id]/edit` | P13 |
| `/sales/quotes/[id]` | S1–S8 (S6 also on the new SO) |
| `/sales/orders/[id]` | S6 (as "created from quote"), S9–S19 |
| `/sales/shipments/[id]` | S19 (created), S20, L3, L4 |
| `/sales/customers/[id]` | C1, C2, C4–C11 |
| `/suppliers/[id]/edit` | SU1–SU3, SU5–SU8, C8/C9 (supplier side) |
| `/sales/commissions/[id]/edit` | K1 |
| `/logistics/containers/[id]` | L1–L8 |
| `/logistics/forwarders/[id]` | SU1b, L14–L16 (and SU2/SU3 if a forwarder is ever edited through `/suppliers/[id]/edit`) |
| `/logistics/lanes` (list; §3) | L9–L13 |
| `/purchasing/licences` (list; §3) | P16 |
| `/purchasing/discrepancies` (§3) | P15 |

---

## 3. Operations with no fitting page to host their trail

| Op | Why no page | Recommended home | Why there |
|---|---|---|---|
| C3 Delete customer · SU4 Delete supplier · P14 Delete template · (K2 dead) | After a soft delete the record drops off its list, and its detail page 404s or filters `deleted_at IS NULL` | The **detail page itself when opened with view-deleted rights**, otherwise `/settings/deleted` (outside this slice; gated on `data.view_deleted`) | A deletion is the last event of the record's own trail. The deleted-records screen is where a deleted record is still reachable. |
| L9 Add port | Ports have no page at all, only an inline list inside `/logistics/lanes` | `/logistics/lanes` (a trail filtered to ports + lanes + lane_document_requirements) | It is the only screen that creates or shows ports |
| L10–L13 Lane create / requirement add / remove / mark reviewed | Lanes have no detail page (`/logistics/lanes` is one panel) | `/logistics/lanes`, grouped per lane (join `lane_document_requirements.lane_id`) | Same screen performs every lane write |
| P16 Company licence save / remove | `company_compliance` is edited in a list panel with no detail page | `/purchasing/licences` | Only host. Note the page gate is `module.purchasing.view` but the data needs `module.suppliers.view`, so the trail must use the data code |
| P15 GRN threshold change | `receiving_settings` is a singleton setting, edited in a side panel of a report page | `/purchasing/discrepancies` (under the threshold panel, visible only with `module.inbound.view`). A settings-style home is an alternative if AUDIT-TRAIL-1 builds one for singletons | This is where people see the thresholds applied |
| P10 Deep-discharge judgement | Has a home (the PO page), but **cannot currently happen** (§0 f) | `/purchasing/orders/[id]` once fixed (route it through an RPC) | — |
| S5 `updateQuoteHeader`, K2 `softDeleteCommissionAgreement` | No UI caller | none needed until wired | dead code |
| S14 Invoice from SO / S19 Ship | Hosted, but the created record lives in another module (invoice → `/finance/invoices/[id]`; journal lines → finance) | Show on the SO page **and** the created record's page | cross-module |
| Container document template checklists created by L6 | Created in bulk | container page | — |

---

## 4. Pages that should carry a trail

| # | Route · file | Primary table | Child tables that roll up (join path) | Domain history already there | Access check (who may read the trail) |
|---|---|---|---|---|---|
| 1 | `/purchasing/orders/[id]` · `app/purchasing/orders/[id]/page.tsx` | purchase_orders | purchase_order_lines (`purchase_order_id`); purchase_order_payment_terms (`purchase_order_id`); purchase_order_line_retentions (`purchase_order_line_id` → lines); pricing_term_commitments (`purchase_order_line_id`) → pricing_term_commitment_metals (`commitment_id`); po_issues (`purchase_order_id`); contract_document_terms (`purchase_order_id`); approval_log (`subject_type='purchase_order' AND subject_id`); cross-module: inbound_batches (`purchase_order_id`), prepayment_applications, payment_allocations (`purchase_order_id`) | purchase_order_history (10 rows: 4 cancelled, 6 header_update, **Measured**, bypass-RLS); approval_log PO rows 11 (all `auto_approved`, **Measured**) | `requireModule(MOD.purchasing)` = `module.purchasing.view`; price columns masked unless `data.view_purchase_prices` (`canViewPurchasePrices`); money panels need `module.finance.view`; contract panel needs `module.suppliers.view` |
| 2 | `/purchasing/orders/[id]/amend` · `amend/page.tsx` | purchase_orders | as 1 | same | `module.purchasing.view` + `requireAllowed(po_may_manage)` |
| 3 | `/purchasing/payment-terms/[id]/edit` · `[id]/edit/page.tsx` | payment_term_templates | payment_term_template_lines (`template_id`); referenced by suppliers.default_payment_term_template_id | none | `requireModule(MOD.purchasing)`; edit gate `module.purchasing.edit` |
| 4 | `/sales/quotes/[id]` · `app/sales/quotes/[id]/page.tsx` | quotes | quote_lines (`quote_id`); qt_issues (`quote_id`); converted order (`quotes.converted_order_id`) | quote_history (created 3, issued 2, converted 1, **Measured**). The page shows change_type, detail and time, **no actor** | `requireModule(MOD.sales)` = `module.sales.view` |
| 5 | `/sales/orders/[id]` · `app/sales/orders/[id]/page.tsx` | sales_orders | sales_order_lines (`sales_order_id`); sales_order_reservations (`sales_order_line_id` → lines); shipping_releases (`sales_order_id`) → shipping_release_lines (`release_id`); approval_log (`subject_type='shipping_release'`, subject_id = release id); so_issues (`sales_order_id`); shipments (`sales_order_id`); invoices (`sales_order_id`, finance); contract_document_terms (`sales_order_id`); source quote (`quotes.converted_order_id`) | sales_order_history (23 rows over 11 change types, **Measured**). The page shows type, line#, qty/price moves, detail, reason, **no actor** | `module.sales.view`; invoice panels `module.finance.view`; release panel `data.view_prices` |
| 6 | `/sales/orders/[id]/amend` · `amend/page.tsx` | sales_orders | as 5 | same | `requireEditPermission('module.sales.edit')` |
| 7 | `/sales/shipments/[id]` · `app/sales/shipments/[id]/page.tsx` | shipments | shipment_lines (`shipment_id`); shipment_issues (`shipment_id`); container link (`shipments.container_id`) | none | `action.ship_goods` **or** `module.sales.view` |
| 8 | `/sales/customers/[id]` · `app/sales/customers/[id]/page.tsx` | customers | counterparty_contacts (`customer_id`); customer_attachments (`customer_id`); customer_credit_history (`customer_id`); customer_statements (`customer_id`); collection_chases (`customer_id`) → collection_chase_documents, collection_promises (`chase_id`); contracts (`customer_id`, contracts module) | customer_credit_history (1 row, **Measured**), **not read by any page** (grep) | `requireModule(MOD.customers)` = `module.customers.view`; statement/chase panels `module.finance.view`/`.edit`; credit `action.customer_credit` |
| 9 | `/sales/customers/[id]/edit` · `[id]/edit/page.tsx` | customers | as 8 (attachments are edited here) | — | `module.customers.view` (edit gate `module.customers.edit`) |
| 10 | `/suppliers/[id]/edit` · `app/suppliers/[id]/edit/page.tsx` (**no read-only supplier detail page exists**) | suppliers | supplier_compliance (`supplier_id`); supplier_attachments (`supplier_id`); counterparty_contacts (`supplier_id`); supplier_status_history (`supplier_id`); approval_log (`subject_type='supplier'`); commission_agreements (`agent_supplier_id`); contracts (`supplier_id`) | supplier_status_history (0 rows, **Measured**), **not read by any page** | `requireModule(MOD.suppliers)` = `module.suppliers.view`; edit `module.suppliers.edit`; status moves per code |
| 11 | `/sales/commissions/[id]/edit` · `[id]/edit/page.tsx` | commission_agreements | — | none | `requireModule(MOD.suppliers)` = `module.suppliers.view` |
| 12 | `/logistics/containers/[id]` · `app/logistics/containers/[id]/page.tsx` | containers | container_milestones (`container_id`); container_documents (`container_id`); shipments (`container_id`); freight_documents (`container_id`, finance) | container_milestones is itself append-only history | `requireModule(MOD.logistics)` = `module.logistics.view`; writes need `module.purchasing.edit` |
| 13 | `/logistics/forwarders/[id]` · `app/logistics/forwarders/[id]/page.tsx` | suppliers (forwarder) | forwarder_details (`supplier_id`); forwarder_rate_quotes (`supplier_id`); containers (`forwarder_id`); freight_documents (`supplier_id`) | none | `module.logistics.view`; commercial columns `module.suppliers.view`; money `module.finance.view` |
| 14 | `/logistics/lanes` · `app/logistics/lanes/page.tsx` (list-only host) | lanes, ports | lane_document_requirements (`lane_id`); lanes.origin/destination_port_id → ports | none | `module.logistics.view` |
| 15 | `/purchasing/licences` · `app/purchasing/licences/page.tsx` (list-only host) | company_compliance | — | none | page `module.purchasing.view`; data `module.suppliers.view` (`canSeeLicences`) |
| (16) | `/purchasing/discrepancies` · page.tsx (settings side-panel) | receiving_settings | — | none | `module.purchasing.view`; panel `module.inbound.view` |

**Records with no detail page:** ports, lanes, lane_document_requirements, company_compliance, receiving_settings (all in §3). There is no read-only supplier
detail page (the edit page is the detail page). The shipping queue (`/logistics/shipping`) creates shipments, which do have a detail page. `/margin`, `/documents/[key]` and `/related/...`
are cross-record read screens (`requireFunction(FN.margin)` = `data.view_prices` AND (`module.finance.view` OR `module.processing.view`); documents/related
check per target through `RelatedRecords`/`allows`) and host no writes.

---

## 5. What `/purchasing/orders/[id]` shows as history today (brief item 6)

**Finding that contradicts the brief:** the page does **not** read approval decisions. `approval_log` appears in this file only inside a comment (line 854).
`grep -rn "approval_log|approval_decision" app/purchasing app/sales app/suppliers app/logistics` finds that comment and nothing else (**Measured**).
For approval the page reads only `purchase_orders_masked.approval_status` (a badge: pending/approved/rejected) and `rpc('approvals_enabled')`.

What it does show, and how:

1. **"Amendment history" block** (`page.tsx` ~854–895, heading `purchasing.amend.historyTitle` = "Amendment history"):
   `supabase.from('purchase_order_history_masked').select('id, change_type, line_no, amend_reason, changed_at, old_quantity, new_quantity, old_estimated_unit_price, new_estimated_unit_price, old_estimated_total_ccy, new_estimated_total_ccy, payment_term_seq').eq('purchase_order_id', id).order('changed_at', desc).limit(50)` (lines 132-134).
   It reads the masked view (prices withheld without `data.view_purchase_prices`), but renders **only** timestamp, change label (`purchasing.amend.change.{cancelled|header_update|payment_term_add|_update|_remove|line_update|line_add|line_remove}`), `#line_no`, `instalment {seq}`, `old_qty → new_qty`, and `— reason`.
   Prices, header before/after values and **the actor (`changed_by`) are not selected or shown**. The list is capped at 50 rows.
2. **"Amended since vN was issued" warning.** It compares `history[0].changed_at` with the latest `po_issues.issued_at` (lines 220-224).
3. **Issued versions list.** `po_issues` (version, issued_at, issued_by, sha256) is rendered as `vN · issued <time> UTC` links. `issued_by` is fetched but not shown.
4. **Cancellation line.** Taken from `purchase_orders_masked.cancelled_at / cancel_reason / cancelled_by`, with the actor name via `loadActorNames` + `<ActorName>` (the only named actor on the page).
5. **Contract link.** `contract_document_terms.contract_code / linked_at` ("terms copied at …").

**What never reaches this history.** Each item is **Inferred** from the trigger and RPC bodies in `funcs.csv`:

- Approve and reject write `approval_log` only. `trg_po_history_header` watches order_date, expected_delivery_date, fx_rate, estimated_total_ccy, incoterm, terms_text, notes and delivery_location, not status or approval columns.
- Close and reopen change `status` but also **append the reason to `notes`**, so each shows up as an unexplained "Header changed" row with no reason.
- Issuing a PDF, linking a contract, setting an expected date (not in the term trigger's jsonb), releasing a retention and the deep-discharge judgement write no history row.
- The `auto_approved` approval_log row written at creation (when approvals are off) is invisible.
- The PO's creation is not a history row.

Live distribution (bypass-RLS): purchase_order_history has **10** rows (cancelled 4, header_update 6); approval_log has **11** purchase_order rows, all `auto_approved`.

## 6. Other findings for AUDIT-TRAIL-1

- **None of the pages show an actor** in their history lists (PO amendment history, SO history, quote history): `changed_by` is either not selected or not rendered. **Measured** by reading the three selects and renders.
- `supplier_status_history` and `customer_credit_history` are written but **read by no page**. **Measured:** `grep -rlnE "supplier_status_history|customer_credit_history" app lib` finds 3 files and none of them reads the tables: `lib/database.types.ts` (generated types), a comment in `app/suppliers/[id]/edit/statusActions.ts:20`, and the name `customer_credit_history` in the `UNREACHABLE_HISTORY_TABLES` list in `app/components/audit/auditTrailTypes.ts:77` (a named footnote on the batch audit trail).
- Hard delete: `removeQuoteLine` is a real `DELETE` on quote_lines, and no domain history captures it. Only change_log would.
- `change_log` currently has no rows for any commercial table: the top tables are role_permissions 146, employees 6, contracts 4… (**Measured**, `GROUP BY table_name`, bypass-RLS).
- Forwarder writes (L14–L16) are gated on `module.purchasing.edit`, while forwarder creation (SU1b) uses `module.suppliers.edit`. The two codes differ, so a trail on the forwarder page will mix operations gated by different codes.
- Storage objects (PDF issues, attachments) are written outside `public`, so change_log will not see them. The metadata rows (po_issues, qt_issues, so_issues, shipment_issues, *_attachments) carry the event.
