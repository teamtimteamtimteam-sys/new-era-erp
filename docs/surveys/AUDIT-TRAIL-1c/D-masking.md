# D — Finance masking and row rules for the AT-1c tables (read-only survey, 2026-10-03)

How these were measured: live queries went through psql (~/.pgpass, pooler DSN from db/apply_migration.sh:39), each wrapped in `BEGIN READ ONLY; … ROLLBACK;`. They ran as **postgres, rolbypassrls = true** (measured), so RLS did not filter any row count below.
The helper script is `D_psql.sh`. Note that `q.sh`, `policies.txt` and `tables.txt` in this folder were written by a parallel agent, which overwrote one of my helpers partway through, so every `D_*` file was re-run from scratch.
Tags: **M** means measured (by a query or at a file:line). **I** means inferred.

## 1. Column masking today

| Table | Masked columns | Code | Base table SELECT revoked on those columns | View row filter |
|---|---|---|---|---|
| company_profile | bank_name, bank_account_name, bank_account_no, bank_swift, bank_address | data.view_banking | yes | none (policy `true`) |
| invoices | subtotal_base, tax_base, total_base, fx_rate | data.view_prices | yes | finance.view |
| invoice_lines | unit_price, amount_base, amount_ccy, tax_base | data.view_prices | yes, plus tax_code and tax_rate_pct | finance.view |
| sales_records | unit_price, fx_rate, amount_base, price_provenance | data.view_prices | yes | finance.view |
| prepayment_applications | amount_base, amount_ccy | data.view_purchase_prices | yes | finance.view |
| payroll_lines | gross_pay, employer_cpf, employee_cpf, other_deductions, net_pay | code_or_self:data.view_pay:employee_id | yes | hr.view OR self OR (finance.view AND view_pay) |
| processing_cost_entries | amount_base | data.view_prices | yes | processing.view |
| processing_cost_entry_history | old_amount_base, new_amount_base | data.view_prices | yes | processing.view |

- **M** Every column above has a row in change_log_mask_rules (db/functions/change_log_mask_rules.sql:23-104). That is 81 rules across 27 tables.
- **M** Run live, `change_log_mask_gaps()` returned `{"gaps": [], "examined_tables": 27, "examined_columns": 81}`. Nothing is missing and nothing is stale. The gate checks this at db/gate.py:620-645.
- **M** Each view's row filter matches its base table's SELECT policy, so trail_row_visible reaches the same verdict as the screen.
- **M** invoice_lines.tax_code and tax_rate_pct are revoked on the base table but are left unmasked in the view on purpose (db/views/invoice_lines_masked.sql:4-6). They are not hidden on screen, so they cannot leak.
- **M** No other AT-1c table has a `_masked` view or a column-list grant. Every other table has a whole-table SELECT grant (D_rls.txt). approval_log has column grants on all of its columns, so nothing is masked there.
- **Not masked, by standing decision 1:** journal_entries, journal_lines, expenses, payments, payment_allocations, credit_notes and credit_note_lines (which carry amounts), bank_*, gst_*, fixed_asset_*, wht_remittances, cash_forecast*, management_packs and payroll_periods totals.

## 2. Bank details
- company_profile: the five bank columns need data.view_banking (**M**). Among finance.view roles, only `auditor` lacks it, and auditor has 0 holders.
- **M** The `bank_account_code` columns (bank_statements, bank_import_profiles, payments, expenses, freight_documents, payment_requests) are GL account codes. A CHECK constrains them to `IN ('1000','1010')` (db/tables/bank_statements.sql:15), and the live distinct values are 1000 and 1010. asset_disposal_requests.bank_account has the same constraint (db/tables/asset_disposal_requests.sql:69). None of these is an account number.
- **M** No supplier, customer or employee table has a bank column at all. A regex over every column name for bank|account_no|iban|swift|payee found none, so no counterparty bank detail can be reached through a finance document.
- **M** bank_statement_lines has description, reference and amount, with no counterparty account column. Live it has 4 rows, and none contains a run of 8 or more digits. **I** Description text from an imported bank CSV could carry payee names or account fragments. It is unmasked on screen as well, so this is not a trail-specific leak.
- **M** bank_import_profiles has 0 rows. **I** Its `mapping` jsonb holds CSV column mapping, not account data.

## 3. Payroll figures
- payroll_lines amounts: covered by the code_or_self:data.view_pay rule above (**M**).
- **M** payroll_periods has unmasked totals: gross_total, employer_cpf_total, employee_cpf_total, other_deductions_total and net_pay_total. Its row policy is hr.view only (db/tables/payroll_periods.sql:86).
- **M** expense_claims policy is `finance.view OR employee_id = current_user_employee()` (db/tables/expense_claims.sql:80-83). It has no column masking.
- **M, open question:** pay_payroll_lines posts **one bank credit journal line per employee**. Each line carries that person's net pay, with `line_memo = emp_code || ' ' || legal_name` (db/functions/pay_payroll_lines.sql:4-5 and 85-90). Live there are 4 payroll journal entries with 11 lines, and 1 of those lines is per-person.
  - journal_lines is unmasked (decision 1), so roles with finance.view but without data.view_pay can read individual net pay, both on the journal screen and in any trail that includes that journal. Those roles are **cto and gm (1 holder each)** and auditor (0 holders).
  - The FIN-4 comment (db/tables/payroll_lines.sql:54-55) accepts per-person net pay for *reconciliation*, but that row policy also requires view_pay.
  - **Question for Tim:** does decision 1 ("finance.view implies prices") also mean finance.view implies individual pay through the GL?
- CPF and deductions journals are aggregated per period (pay_payroll_cpf.sql:69, pay_payroll_deductions.sql:68), so they expose no individual figures.
- Which trails would show payroll rows: none of the current subjects includes payroll tables (trail_subject_members, **M**). In AT-1c, a journal or payroll-payments subject that reaches payroll_lines shows rows to hr.view holders or to finance.view plus view_pay holders, with amounts masked for anyone without view_pay. Journal lines are always shown in full.

## 4. Row rules that are not plain finance.view (live pg_policies, 0 RESTRICTIVE)
- **approval_log** (approval_log.sql:218): a CASE on subject_type.
  - finance.view for payment, expense, expense_claim, payment_request, invoice_request, journal_request, warehouse_request, asset_disposal_request and gst_filing_request.
  - hr.view for payroll_request.
  - hr.view AND view_pay for salary_change_request.
  - **pricing.view for terms_request, including requests about contracts.**
  - inbound.view AND view_purchase_prices for receipt_price_request.
  - Any other subject type falls to ELSE false.
- **contracts** (contracts.sql:126): `(customer_id NOT NULL AND customers.view) OR (supplier_id NOT NULL AND suppliers.view)`. All contract_* term tables use an EXISTS on contracts with the same predicate (for example contract_pricing_terms.sql:69).
  - Seven term tables also have an **ALL policy `action.contract_terms`**: grade_specs, insurance, penalty, pricing, refining, settlement and volume. contract_document_terms does not.
  - trail_row_visible ORs ALL policies into the visibility check, as real RLS does, so holders of action.contract_terms (admin, cco) can see those term rows.
- **terms_requests** (terms_requests.sql:115): `(formula_id AND pricing.view AND view_prices AND view_purchase_prices) OR (contract_id AND EXISTS contracts-owner predicate)`.
- **equipment_maintenance / equipment_downtime / equipment_service_intervals** (lines 145 / 85 / 152): `finance.view OR processing.view`. A finance reader sees these rows on an asset page, so they are visible, not Restricted.
- **expense_claims**: finance.view OR own row. **payroll_lines**: hr.view, OR finance.view AND view_pay, OR own row (payroll_lines.sql:49, 56, 85). **payroll_periods**: hr.view only.
- **processing_cost_entries / _history** (101 / 46): processing.view only. A finance reader who lacks processing.view would see these rows as Restricted.
- **freight_documents / freight_allocations** (freight_documents.sql:94 / 123): inbound.view OR finance.view, plus an ALL policy for finance.edit.
- **cash_forecast_lines**: finance.view, plus an ALL policy for finance.edit.
- **company_profile**: `true`.
- **Today's outcome (M, from the section 5 matrix):** every role holding module.finance.view also holds hr.view, processing.view, suppliers.view, customers.view and pricing.view. So for current finance readers, every row type above is visible, never Restricted. The only exceptions are payroll_lines for cto, gm and auditor: the rows are visible through hr.view, but the amounts are masked. A future finance-only role would see Restricted for payroll_periods/lines, processing_cost_*, contracts and terms rows.

## 4b. Side finding: employee references bypass the hr.view name rule (M, question)
- trail_actor hides other people's names from readers without module.hr.view.
- trail_ref_label's `employees` branch (db/functions/trail_ref_label.sql:60-62) returns preferred_name or legal_name **without** that check. The live definition contains no `module.hr.view` string.
- The renderer resolves `fk_person` columns through refs (lib/trail/render.ts:263). That applies to expense_claims.employee_id and payroll_lines.employee_id (catalogue kind `fk_person`), and to expenses, payments, payment_requests and equipment_maintenance.performed_by_employee_id.
- This contradicts the trail_actor header comment, which says references to people go through the same rule.
- It costs no current finance reader anything, because they all hold hr.view. The question is whether decision 3 (the label follows the document) covers it.

## 5. Live role matrix (M; user_roles.revoked_at IS NULL counted as holders; role_permissions has no revoked_at)
| Role (holders) | fin.view | banking | pay | prices | purch_prices | hr.view |
|---|---|---|---|---|---|---|
| admin (1) | Y | Y | Y | Y | Y | Y |
| cfo (1) | Y | Y | Y | Y | Y | Y |
| finance (1) | Y | Y | Y | Y | Y | Y |
| cco (1) | Y | Y | Y | Y | Y | Y |
| cto (1) | Y | Y | – | Y | Y | Y |
| gm (1) | Y | Y | – | Y | Y | Y |
| auditor (0) | Y | – | – | Y | Y | Y |
| hr (0) | – | – | Y | – | – | Y |
| procurement (0), sales (0) | – | – | – | Y | Y | – |
| warehouse (1) | – | – | – | – | Y | – |
| operations (inactive, deleted) | – | – | – | – | – | – |

All of these queries ran as postgres with rolbypassrls = true.
