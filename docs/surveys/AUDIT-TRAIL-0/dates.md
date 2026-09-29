# DATE-PICK survey (AUDIT-TRAIL-0 sub-agent) — 2026-09-29, read-only

Repo: /Users/timchen/Documents/projects/new-era-erp. No repo file touched. Scratch tools: `at0/date/enum.mjs` (TypeScript-AST enumerator),
raw output `at0/date/sites.json`, table `at0/date/table.md` (pasted in §1.4). No live DB was queried for this file.

## 0 · Headline

| What | Number | Method | Status |
|---|---|---|---|
| Native date-ish inputs **in code** | **134** = 125 `date` + 5 `month` + 4 `datetime-local` + 0 `time` + 0 `week` | `at0/date/enum.mjs`: TS AST over every `app/**` `lib/**` .ts/.tsx (1023 files), every `JsxAttribute` named `type` (869 scanned) whose literal value is one of those five | **Measured** |
| Same, by the repo ratchet | **134 code · 8 comment** | `node scripts/check-date-format.mjs` (exit 0) — "原生日期控件:代码里 134 处 · 注释里提到 8 处" | **Measured** |
| Raw grep (code + comments) | 142 lines (131 date + 4 dtl + 7 month) | `grep -rnE 'type="(date|datetime-local|month)"' app lib` ; 142 − 134 = the 8 comment lines, listed in §1.2 | **Measured** |
| Files holding a native site | 90 (85 hold a `type="date"`) | distinct `rel` in sites.json | **Measured** |
| Routes | 81 distinct (by nearest ancestor `page.tsx`; shared components resolved by call site in §1.3) | enum.mjs `route()` | **Inferred** (directory ≠ import graph) |
| **Rendered call sites** (a wrapper counted once per caller) | **144** = 134 − 4 wrapper/helper bodies + 14 wrapper call sites | §1.3 | **Measured** (grep of `<DateFilterInput` 4, `<ContractDateInput` 6, `<PaymentDateInput` 2, `dateField(` 2) |
| Baseline `nativeDateInputs` | 134 — **matches** | scripts/date-format-baseline.json | **Measured** |
| `type: 'date'` in config objects / column specs | **0** | grep `(kind|type|input|inputType|fieldType)\s*:\s*['"](date|month|datetime|ymd)` over app lib = 0 hits; EditableTable/AddRowPanel columns take `edit: (draft,set) => ReactNode` render functions, so their date cells are literal `<input type="date">` inside page files (e.g. NewOrderForm.tsx:528, prop `edit`) and are already in the 134 | **Measured** |
| `type={expr}` inputs | 3 JSX hits, **none date-ish**: `app/components/ui/input.tsx:60` (`<Input type>` passthrough — no caller passes a date type: all 134 sites have tag `input`, 0 have `Input`), `contracts/[id]/TermSection.tsx:141` (text/number), `TaskBoard.tsx:155` (a badge prop) | sites.json `tag` histogram `{input:134}` | **Measured** |

### Reconciliation with DATE-0 (130 date + 4 dtl + 6 month = 140) **Measured / Inferred as marked**
* date 130 → 125: TERMS-EDIT-1 merged contract 3→1 (−2) and HISTORY-1 merged 4 filters → DateFilterInput (−3). 130−5 = 125 ✓ (baseline note records exactly these two tightenings; **Inferred** arithmetic, matches Measured 125).
* month 6 → 5 code: raw grep now finds 7 `type="month"`, of which 2 are comments (`hr/attendance/OpenPeriodForm.tsx:40`, `lib/dates.ts:279`). DATE-0's 6 was most likely 5 code + the OpenPeriodForm comment (DATE-0's grep was not comment-stripped — DATE-1 §Y records five comment-pollution incidents). **Inferred**; no git history consulted.
* Baseline history in the note: 144 (with comments) → 138 (DATE-1, code-only) → 135 → 134.

## 1 · Per-site list

### 1.1 Totals by shape (denominator 134 code sites) — **Measured** from sites.json
| attribute | count |
|---|---|
| `name=` present (posts via FormData / GET) | 63 |
| controlled (`value=`) | 84 · uncontrolled (`defaultValue` or bare) 50 (ContractDateInput counted uncontrolled: spreads caller props; all 6 callers use defaultValue or nothing) |
| `required` | 35 (+ callers: ContractDateInput effective_from REQ) |
| `min=` | 2 · `max=` 10 |
| inside `<form method="get">` | 8 |
| `onBlur` write-back (controlled-input hazard patch) | 4 |
| own `aria-label` | 4 (the rest are wrapped in / pointed at by a `<label>`) |
| `disabled=` | 3 |
| purpose: form field 93 · filter/report param 33 · per-row list/table cell 4 · wrapper/helper bodies 4 | classification rule in enum post-processor: filename `*Toolbar*`/`AsOfControl`/`PackControls`/`date-filter-input`/`StatementPanel` or GET form ⇒ filter; 4 hand-picked per-row sites; else form field. **Inferred** classification |

Class names: `{CONTROL_INPUT}` 77, `{field}` 15, `CONTROL_INPUT w-full` 13, `CONTROL_INPUT block` 10, `block ${inp}` 7, others ≤2; 1 site is a bespoke dashed amber underline style (inline edit). **Measured**.

### 1.2 The 8 comment mentions (not controls) — **Measured**
`purchasing/orders/[id]/PoPaymentTermsTable.tsx:9`, `components/ui/date-filter-input.tsx:4`, `hr/attendance/OpenPeriodForm.tsx:40`, `lib/dates.ts:102,188,263,271,279`.

### 1.3 Wrappers / helpers (one body, several callers) — **Measured** by grep of `<Name` in app lib
| wrapper | body | callers |
|---|---|---|
| `DateFilterInput` | app/components/ui/date-filter-input.tsx:21 — uncontrolled, `name`+`defaultValue`, no validation | settings/change-history/page.tsx:200,204 (`from`,`to`); settings/deleted/page.tsx:198,200 (`from`,`to`) — GET filters |
| `ContractDateInput` | app/contracts/ContractDateInput.tsx:8 — `<input {...props} type="date"/>` | contracts/new/NewContractForm.tsx:135 (effective_from, **required**), :140 (effective_to), :167 (signed_on); contracts/[id]/HeaderForm.tsx:93,98,104 (same three, `defaultValue={values.*}`, `disabled`) |
| `PaymentDateInput` | app/components/finance/PaymentDateInput.tsx:31 — controlled, required, `max={businessToday()}`, onBlur write-back | finance/payments/new/NewPaymentForm.tsx:625; finance/payment-requests/[id]/RequestActions.tsx:153 (`payment_date`) |
| `dateField()` local helper | finance/processing-costs/CostSettlePanel.tsx:90 — controlled, required, red bg when empty | same file :138 (pay-date), :164 (inv-date) |
| none else found | grep for `showPicker|valueAsDate|DatePicker|Calendar` finds only the display calendar `app/components/calendar/MonthGrid.tsx` (+2 pages using it) — **not an input** | |

### 1.4 Every site (134 rows). Route = nearest ancestor dir with page.tsx (**Inferred**); `(shared)` = app/components; value fed is the JSX expression (all feed `YYYY-MM-DD` strings from state/DB/`todayIsoLocal()`/`businessToday()`; month sites feed `YYYY-MM`; datetime-local feed `YYYY-MM-DDTHH:MM` local-time strings).
| # | route (Inferred by dir, see note) | file:line | type | purpose | name= | ctl/unc | value fed | required | min / max |
|--:|---|---|---|---|---|---|---|---|---|
| 1 | (shared) | components/finance/PaymentDateInput.tsx:31 | date | WRAPPER PaymentDateInput -> /finance/payments/new + /finance/payment-requests/[id] (payment_date; REQ; max=businessToday(); controlled + onBlur write-back) | {name} | controlled | {value} | yes |  / {businessToday()} |
| 2 | (shared) | components/ui/date-filter-input.tsx:21 | date | WRAPPER DateFilterInput -> /settings/deleted (from,to) + /settings/change-history (from,to); GET filter; uncontrolled defaultValue | {name} | uncontrolled | {defaultValue} | no |  /  |
| 3 | /contracts | contracts/ContractDateInput.tsx:8 | date | WRAPPER ContractDateInput -> /contracts/new (effective_from REQ, effective_to, signed_on) + /contracts/[id] HeaderForm (same 3, defaultValue, disabled); spreads props | — | either (props) | (caller) | no |  /  |
| 4 | /finance | finance/AgingAsOfControl.tsx:49 | date | filter/report param | — | controlled | {asOf} | no |  / {today} |
| 5 | /finance/assets | finance/assets/AssetActions.tsx:119 | date | form field | — | controlled | {inSvc} | no | {acquisitionDate} /  |
| 6 | /finance/assets | finance/assets/AssetActions.tsx:136 | date | form field | — | controlled | {plan} | no |  /  |
| 7 | /finance/assets/[id] | finance/assets/[id]/DowntimePanel.tsx:157 | datetime-local | form field | — | controlled | {endAt} | no |  /  |
| 8 | /finance/assets/[id] | finance/assets/[id]/DowntimePanel.tsx:215 | datetime-local | form field | — | controlled | {f.startedAt} | no |  /  |
| 9 | /finance/assets/[id] | finance/assets/[id]/MaintenancePanel.tsx:272 | date | form field | — | controlled | {f.performedOn} | no |  /  |
| 10 | /finance/assets/[id] | finance/assets/[id]/MaintenancePanel.tsx:481 | date | form field | — | controlled | {f.expenseDate} | no |  /  |
| 11 | /finance/assets/new | finance/assets/new/NewAssetForm.tsx:64 | date | form field | "acquisition_date" | uncontrolled | — | yes |  /  |
| 12 | /finance/assets | finance/assets/page.tsx:232 | date | filter/report param | "date" | uncontrolled | {d} | no |  /  |
| 13 | /finance/balance-sheet | finance/balance-sheet/BsToolbar.tsx:28 | date | filter/report param | — | controlled | {asOf} | no |  /  |
| 14 | /finance/bank | finance/bank/TransferForm.tsx:56 | date | form field | — | controlled | {date} | no |  /  |
| 15 | /finance/bank/import | finance/bank/import/ImportStatementForm.tsx:434 | date | form field | — | controlled | {effStart} | no |  /  |
| 16 | /finance/bank/import | finance/bank/import/ImportStatementForm.tsx:448 | date | form field | — | controlled | {effEnd} | no |  /  |
| 17 | /finance/cash-forecast | finance/cash-forecast/RecurringLines.tsx:131 | date | form field | — | controlled | {startDate} | no |  /  |
| 18 | /finance/cash-forecast | finance/cash-forecast/RecurringLines.tsx:134 | date | form field | — | controlled | {endDate} | no |  /  |
| 19 | /finance/cashflow | finance/cashflow/CashflowToolbar.tsx:39 | date | filter/report param | — | controlled | {from} | no |  /  |
| 20 | /finance/cashflow | finance/cashflow/CashflowToolbar.tsx:48 | date | filter/report param | — | controlled | {to} | no |  /  |
| 21 | /finance/claims | finance/claims/ClaimDecisionPanel.tsx:161 | date | per-row (table/list cell) | — | controlled | {get(c.claim_id).post} | no |  /  |
| 22 | /finance/expenses | finance/expenses/ExpensesToolbar.tsx:39 | date | filter/report param | — | controlled | {dateFrom} | no |  /  |
| 23 | /finance/expenses | finance/expenses/ExpensesToolbar.tsx:48 | date | filter/report param | — | controlled | {dateTo} | no |  /  |
| 24 | /finance/expenses/[id] | finance/expenses/[id]/ReleasePrepaymentPanel.tsx:81 | date | form field | "release_date" | uncontrolled | — | yes |  /  |
| 25 | /finance/expenses/new | finance/expenses/new/NewExpenseForm.tsx:199 | date | form field | "expense_date" | uncontrolled | {todayIsoLocal()} | yes |  / {businessToday()} |
| 26 | /finance/expenses/new | finance/expenses/new/NewExpenseForm.tsx:530 | date | form field | "asset_in_service_date" | uncontrolled | — | no |  /  |
| 27 | /finance/freight/new | finance/freight/new/NewFreightForm.tsx:229 | date | form field | "doc_date" | uncontrolled | — | yes |  / {businessToday()} |
| 28 | /finance/fx | finance/fx/FxRateFormFields.tsx:100 | date | form field | "rate_date" | uncontrolled | {defaults?.rate_date ?? ''} | yes |  /  |
| 29 | /finance/gst | finance/gst/GstControls.tsx:22 | date | form field | — | controlled | {start} | no |  /  |
| 30 | /finance/gst/[periodId] | finance/gst/[periodId]/GstFilingPanel.tsx:230 | date | form field | — | controlled | {filedOn} | no |  /  |
| 31 | /finance/invoices | finance/invoices/InvoicesToolbar.tsx:34 | date | filter/report param | — | controlled | {dateFrom} | no |  /  |
| 32 | /finance/invoices | finance/invoices/InvoicesToolbar.tsx:43 | date | filter/report param | — | controlled | {dateTo} | no |  /  |
| 33 | /finance/invoices/[id] | finance/invoices/[id]/CreateCreditNoteControl.tsx:259 | date | form field | "note_date" | controlled | {noteDate} | no |  /  |
| 34 | /finance/invoices/[id] | finance/invoices/[id]/VoidInvoiceControl.tsx:111 | date | form field | — | controlled | {reversalDate} | no |  /  |
| 35 | /finance/invoices/new | finance/invoices/new/NewInvoiceForm.tsx:309 | date | form field | "issue_date" | controlled | {issueDate} | yes |  / {businessToday()} |
| 36 | /finance/journal | finance/journal/JournalToolbar.tsx:33 | date | filter/report param | — | controlled | {dateFrom} | no |  /  |
| 37 | /finance/journal | finance/journal/JournalToolbar.tsx:42 | date | filter/report param | — | controlled | {dateTo} | no |  /  |
| 38 | /finance/journal/new | finance/journal/new/NewEntryForm.tsx:115 | date | form field | "entry_date" | uncontrolled | {todayIsoLocal()} | yes |  /  |
| 39 | /finance/month-end | finance/month-end/page.tsx:222 | month | filter/report param | "month" | uncontrolled | {month} | no |  /  |
| 40 | /finance/packs | finance/packs/PackControls.tsx:20 | month | filter/report param | "month" | uncontrolled | {month} | no |  /  |
| 41 | /finance/payments | finance/payments/PaymentsToolbar.tsx:34 | date | filter/report param | — | controlled | {dateFrom} | no |  /  |
| 42 | /finance/payments | finance/payments/PaymentsToolbar.tsx:43 | date | filter/report param | — | controlled | {dateTo} | no |  /  |
| 43 | /finance/payroll-payments | finance/payroll-payments/PayPanel.tsx:83 | date | form field | — | controlled | {date} | yes |  /  |
| 44 | /finance/pnl | finance/pnl/PnlToolbar.tsx:39 | date | filter/report param | — | controlled | {from} | no |  /  |
| 45 | /finance/pnl | finance/pnl/PnlToolbar.tsx:48 | date | filter/report param | — | controlled | {to} | no |  /  |
| 46 | /finance/processing-costs | finance/processing-costs/CostSettlePanel.tsx:90 | date | local helper dateField() called 2x (pay-date, inv-date); REQ; controlled; red bg when empty | — | controlled | {value} | yes |  /  |
| 47 | /finance/revaluation | finance/revaluation/page.tsx:96 | date | filter/report param | "date" | uncontrolled | {d} | no |  /  |
| 48 | /finance/settings | finance/settings/LockForm.tsx:54 | date | form field | — | controlled | {date} | no |  /  |
| 49 | /finance/wht | finance/wht/WhtControls.tsx:61 | date | form field | — | controlled | {on} | no |  /  |
| 50 | /hr/attendance | hr/attendance/OpenPeriodForm.tsx:28 | month | form field | — | controlled | {month} | no |  /  |
| 51 | /hr/claims | hr/claims/ClaimForm.tsx:59 | date | form field | — | controlled | {date} | no |  /  |
| 52 | /hr/claims/[id] | hr/claims/[id]/ClaimControls.tsx:100 | date | form field | — | controlled | {date} | no |  /  |
| 53 | /hr/employees | hr/employees/EmployeeForm.tsx:366 | date | form field | "hire_date" | uncontrolled | {employee?.hire_date ?? todayIsoLocal()} | yes |  /  |
| 54 | /hr/employees | hr/employees/EmployeeForm.tsx:376 | date | form field | "probation_end_date" | uncontrolled | {employee?.probation_end_date ?? ''} | no |  /  |
| 55 | /hr/employees | hr/employees/EmployeeForm.tsx:404 | date | form field | "effective_date" | uncontrolled | — | no |  /  |
| 56 | /hr/employees | hr/employees/EmployeeForm.tsx:480 | date | form field | "work_pass_issue_date" | uncontrolled | {employee?.work_pass_issue_date ?? ''} | yes |  /  |
| 57 | /hr/employees | hr/employees/EmployeeForm.tsx:492 | date | form field | "work_pass_expiry_date" | uncontrolled | {employee?.work_pass_expiry_date ?? ''} | yes |  /  |
| 58 | /hr/employees | hr/employees/EmployeeForm.tsx:513 | date | form field | "separation_date" | uncontrolled | {employee?.separation_date ?? ''} | yes |  /  |
| 59 | /hr/leave | hr/leave/LeaveForm.tsx:153 | date | form field | — | controlled | {start} | no |  /  |
| 60 | /hr/leave | hr/leave/LeaveForm.tsx:164 | date | form field | — | controlled | {end} | no |  /  |
| 61 | /hr/leave/calendar | hr/leave/calendar/page.tsx:93 | month | filter/report param | "month" | uncontrolled | {month} | no |  /  |
| 62 | /hr/leave/holidays | hr/leave/holidays/HolidaysEditor.tsx:73 | date | form field | — | controlled | {date} | no |  /  |
| 63 | /hr/leave | hr/leave/page.tsx:139 | date | filter/report param | "from" | uncontrolled | {sp.from ?? ''} | no |  /  |
| 64 | /hr/leave | hr/leave/page.tsx:143 | date | filter/report param | "to" | uncontrolled | {sp.to ?? ''} | no |  /  |
| 65 | /hr/payroll | hr/payroll/PayrollGrid.tsx:338 | month | form field | "period_month" | uncontrolled | {defaults.period_month} | yes |  /  |
| 66 | /hr/payroll | hr/payroll/PayrollGrid.tsx:362 | date | form field | "payment_date" | uncontrolled | {defaults.payment_date} | yes |  /  |
| 67 | /hr/reviews | hr/reviews/HrDecisionForm.tsx:150 | date | form field | — | controlled | {effective} | no |  /  |
| 68 | /hr/reviews/cycles | hr/reviews/cycles/CycleForm.tsx:55 | date | form field | — | controlled | {start} | no |  /  |
| 69 | /hr/reviews/cycles | hr/reviews/cycles/CycleForm.tsx:59 | date | form field | — | controlled | {end} | no |  /  |
| 70 | /hr/reviews/cycles | hr/reviews/cycles/CycleForm.tsx:63 | date | form field | — | controlled | {due} | no |  /  |
| 71 | /hr/training | hr/training/TrainingForm.tsx:123 | date | form field | "completed_date" | uncontrolled | {record?.completed_date ?? ''} | yes |  /  |
| 72 | /hr/training | hr/training/TrainingForm.tsx:133 | date | form field | "expiry_date" | uncontrolled | {record?.expiry_date ?? ''} | no |  /  |
| 73 | /inbound | inbound/InboundToolbar.tsx:141 | date | filter/report param | — | controlled | {currentDateFrom} | no |  /  |
| 74 | /inbound | inbound/InboundToolbar.tsx:150 | date | filter/report param | — | controlled | {currentDateTo} | no |  /  |
| 75 | /inbound/[id]/assays/new | inbound/[id]/assays/new/AssayForm.tsx:214 | date | form field | "assay_date" | controlled | {assayDate} | yes |  / {todayIsoLocal()} |
| 76 | /inbound/[id]/edit | inbound/[id]/edit/EditInboundForm.tsx:185 | date | form field | "arrival_date" | uncontrolled | {batch.arrival_date ?? ''} | no |  /  |
| 77 | /inbound/[id]/edit | inbound/[id]/edit/PrepaymentPanel.tsx:133 | date | form field | "release_date" | uncontrolled | — | yes |  /  |
| 78 | /inbound/new | inbound/new/NewInboundForm.tsx:368 | date | form field | "arrival_date" | controlled | {arrivalDate} | yes |  /  |
| 79 | /inbound/receive | inbound/receive/ReceiveForm.tsx:313 | date | form field | "arrival_date" | controlled | {arrivalDate} | yes |  /  |
| 80 | /inventory/reports/ledger | inventory/reports/ledger/page.tsx:92 | date | filter/report param | "from" | uncontrolled | {params.from} | no |  /  |
| 81 | /inventory/reports/ledger | inventory/reports/ledger/page.tsx:97 | date | filter/report param | "to" | uncontrolled | {params.to} | no |  /  |
| 82 | /logistics/containers | logistics/containers/NewContainerForm.tsx:72 | date | form field | "departure_date" | uncontrolled | — | yes |  /  |
| 83 | /logistics/containers/[id] | logistics/containers/[id]/ContainerPanels.tsx:97 | date | form field | "expected_arrival_date" | uncontrolled | {head.expected_arrival_date ?? ''} | no |  /  |
| 84 | /logistics/containers/[id] | logistics/containers/[id]/ContainerPanels.tsx:239 | date | form field | "event_date" | uncontrolled | — | yes |  /  |
| 85 | /logistics/forwarders/[id] | logistics/forwarders/[id]/ForwarderPanels.tsx:145 | date | form field | "valid_from" | uncontrolled | — | yes |  /  |
| 86 | /logistics/forwarders/[id] | logistics/forwarders/[id]/ForwarderPanels.tsx:149 | date | form field | "valid_to" | uncontrolled | — | yes |  /  |
| 87 | /logistics/shipping | logistics/shipping/ShipQueueControl.tsx:77 | date | form field | — | controlled | {shipDate} | no |  /  |
| 88 | /me | me/MyExpenseClaimsPanel.tsx:178 | date | form field | — | controlled | {spendDate} | no |  / {today()} |
| 89 | /operation/handovers/new | operation/handovers/new/NewHandoverForm.tsx:87 | date | form field | — | controlled | {date} | no |  /  |
| 90 | /operation/orders/new | operation/orders/new/NewWorkOrderForm.tsx:269 | date | form field | — | controlled | {scheduled} | no |  /  |
| 91 | /operation/processing | operation/processing/ProcessingToolbar.tsx:36 | date | filter/report param | — | controlled | {currentDateFrom} | no |  /  |
| 92 | /operation/processing | operation/processing/ProcessingToolbar.tsx:45 | date | filter/report param | — | controlled | {currentDateTo} | no |  /  |
| 93 | /operation/processing/new | operation/processing/new/NewProcessingForm.tsx:335 | date | form field | — | controlled | {processDate} | yes |  /  |
| 94 | /output | output/OutputToolbar.tsx:126 | date | filter/report param | — | controlled | {currentDateFrom} | no |  /  |
| 95 | /output | output/OutputToolbar.tsx:135 | date | filter/report param | — | controlled | {currentDateTo} | no |  /  |
| 96 | /output/[id]/assays/new | output/[id]/assays/new/OutputAssayForm.tsx:172 | date | form field | "assay_date" | uncontrolled | {todayIsoLocal()} | yes |  / {todayIsoLocal()} |
| 97 | /output/[id]/edit | output/[id]/edit/EditOutputForm.tsx:157 | date | form field | "output_date" | uncontrolled | {batch.output_date ?? ''} | no |  /  |
| 98 | /output/[id]/edit | output/[id]/edit/SalePanel.tsx:322 | date | form field | "sale_date" | uncontrolled | {todayIsoLocal()} | yes |  /  |
| 99 | /output/new | output/new/NewOutputForm.tsx:162 | date | form field | "output_date" | controlled | {outputDate} | yes |  /  |
| 100 | /purchasing/licences | purchasing/licences/LicencePanel.tsx:200 | date | form field | — | controlled | {form.issue_date} | no |  /  |
| 101 | /purchasing/licences | purchasing/licences/LicencePanel.tsx:205 | date | form field | — | controlled | {form.valid_from} | no |  /  |
| 102 | /purchasing/licences | purchasing/licences/LicencePanel.tsx:210 | date | form field | — | controlled | {form.valid_until} | no |  /  |
| 103 | /purchasing/orders | purchasing/orders/OrdersToolbar.tsx:36 | date | filter/report param | — | controlled | {dateFrom} | no |  /  |
| 104 | /purchasing/orders | purchasing/orders/OrdersToolbar.tsx:45 | date | filter/report param | — | controlled | {dateTo} | no |  /  |
| 105 | /purchasing/orders/[id] | purchasing/orders/[id]/ExpectedDateControl.tsx:45 | date | form field | — | controlled | {value} | no |  /  |
| 106 | /purchasing/orders/[id]/amend | purchasing/orders/[id]/amend/AmendOrderForm.tsx:365 | date | form field | "order_date" | uncontrolled | {orderDate} | no |  /  |
| 107 | /purchasing/orders/[id]/amend | purchasing/orders/[id]/amend/AmendOrderForm.tsx:372 | date | form field | "expected_delivery_date" | uncontrolled | {expectedDelivery} | no |  /  |
| 108 | /purchasing/orders/[id]/amend | purchasing/orders/[id]/amend/AmendOrderForm.tsx:561 | date | per-row (table/list cell) | — | controlled | {x.term.due_date} | no |  /  |
| 109 | /purchasing/orders/new | purchasing/orders/new/NewOrderForm.tsx:528 | date | per-row (table/list cell) | — | controlled | {r.due_date} | no |  /  |
| 110 | /purchasing/orders/new | purchasing/orders/new/NewOrderForm.tsx:631 | date | form field | "order_date" | controlled | {orderDate} | yes |  /  |
| 111 | /purchasing/orders/new | purchasing/orders/new/NewOrderForm.tsx:642 | date | form field | "expected_delivery" | uncontrolled | — | no |  /  |
| 112 | /sales/commissions | sales/commissions/CommissionForm.tsx:179 | date | form field | "valid_from" | controlled | {form.valid_from} | no |  /  |
| 113 | /sales/commissions | sales/commissions/CommissionForm.tsx:184 | date | form field | "valid_to" | controlled | {form.valid_to} | no |  /  |
| 114 | /sales/customers | sales/customers/ChasePanel.tsx:226 | date | form field | — | controlled | {chasedOn} | no |  / {today()} |
| 115 | /sales/customers | sales/customers/ChasePanel.tsx:283 | date | form field | — | controlled | {promisedDate} | no | {chasedOn \|\| undefined} /  |
| 116 | /sales/customers | sales/customers/StatementPanel.tsx:132 | date | filter/report param | — | controlled | {from} | no |  /  |
| 117 | /sales/customers | sales/customers/StatementPanel.tsx:137 | date | filter/report param | — | controlled | {to} | no |  /  |
| 118 | /sales/orders/[id] | sales/orders/[id]/CreateOrderInvoiceControl.tsx:52 | date | form field | — | controlled | {issueDate} | no |  / {businessToday()} |
| 119 | /sales/orders/new | sales/orders/new/NewOrderForm.tsx:96 | date | form field | "order_date" | controlled | {orderDate} | yes |  /  |
| 120 | /sales/quotes/[id] | sales/quotes/[id]/ConvertControl.tsx:68 | date | form field | — | controlled | {orderDate} | no |  /  |
| 121 | /sales/quotes/new | sales/quotes/new/NewQuoteForm.tsx:172 | date | form field | "quote_date" | controlled | {quoteDate} | no |  /  |
| 122 | /sales/quotes/new | sales/quotes/new/NewQuoteForm.tsx:183 | date | form field | "valid_until" | controlled | {validUntil} | no |  /  |
| 123 | /suppliers/[id]/edit | suppliers/[id]/edit/CompliancePanel.tsx:253 | date | form field | "valid_from" | uncontrolled | — | no |  /  |
| 124 | /suppliers/[id]/edit | suppliers/[id]/edit/CompliancePanel.tsx:261 | date | form field | "valid_until" | uncontrolled | — | no |  /  |
| 125 | /tools/pricing/calculator | tools/pricing/calculator/CalculatorForm.tsx:206 | date | form field | "reference_date" | uncontrolled | {prefill.date} | yes |  /  |
| 126 | /tools/pricing/metal-prices/[id]/edit | tools/pricing/metal-prices/[id]/edit/EditMetalPriceForm.tsx:102 | date | form field | "price_date" | uncontrolled | {row.price_date} | yes |  /  |
| 127 | /tools/pricing/metal-prices/bulk | tools/pricing/metal-prices/bulk/BulkPricesForm.tsx:158 | date | form field | "price_date" | controlled | {priceDate} | yes |  /  |
| 128 | /tools/pricing/metal-prices/new | tools/pricing/metal-prices/new/NewMetalPriceForm.tsx:116 | date | form field | "price_date" | uncontrolled | {todayIsoLocal()} | yes |  /  |
| 129 | /tools/tasks | tools/tasks/TaskModal.tsx:227 | date | form field | "due_date" | uncontrolled | "" | no |  /  |
| 130 | /tools/tasks | tools/tasks/TaskModal.tsx:238 | datetime-local | form field | "reminder_at" | uncontrolled | "" | no |  /  |
| 131 | /tools/tasks/[id] | tools/tasks/[id]/NodeTree.tsx:119 | date | per-row (table/list cell) | — | controlled | {n.target_date ?? ''} | no |  /  |
| 132 | /tools/tasks/[id] | tools/tasks/[id]/NodeTree.tsx:195 | date | form field | — | controlled | {draftDate} | no |  /  |
| 133 | /tools/tasks/[id] | tools/tasks/[id]/TaskHeader.tsx:159 | date | form field | "due_date" | uncontrolled | {task.due_date ?? ''} | no |  /  |
| 134 | /tools/tasks/[id] | tools/tasks/[id]/TaskHeader.tsx:163 | datetime-local | form field | "reminder_at" | uncontrolled | {toLocalInput(task.reminder_at)} | no |  /  |

## 2 · DATE-0 Q1 / Q6 / §5 and DATE-1 — what was asked and decided

* **DATE-0 Q1** (docs/handbacks/DATE-0-stopgate.md:69): "选择器那一半做不做?" — native `<input type="date">` renders in the **OS locale** format, which "CSS 够不到、JS 改不了", so unifying pickers = replacing 130 controls in 85 files. Options (甲) display only, pickers untouched; (乙) both halves, write our own calendar control; (丙) display first, pickers **their own cut**, priced separately. Recommendation (丙): the halves fail differently — a bad display reads oddly; **a bad picker stops people entering dates, hence documents**.
* **Tim's decision D1** (DATE-1.md:3, :273): "只做显示;一个 `<input type="date">` 都不碰" — pickers became their own cut, queued in `forward-queue.md`; DATE-1 touched 0 native controls (verified 130/85 before and after).
* **Q6** (DATE-0:154): acceptance bar if we write our own: native gives free (1) keyboard reachability, (2) screen-reader announcement, (3) the phone's system date wheel, (4) clearing. A custom one must re-earn each, **measured**, and **390px layout must be measured first after the swap** (INPUT-2/2b paid twice for native-control widths; `/sales/orders/new` overflow +57px from one `<select>`'s intrinsic size).
* **§5.2 ①** (DATE-0:344): `value`/`min`/`max` of a date input must be `YYYY-MM-DD`; an invalid value is **silently treated as empty** (no error). 36 sites fed DB date columns straight in. ②③④: URL filters (`isYmd()` → '' = "no filter" → list silently shows all rows), FormData readers (loud: DB rejects), `/hr/leave/calendar` `month` key. DATE-1 added ARM 5 (`Date.parse(formatDate(...))` → NaN only in zh).
* **DATE-1 display format** (lib/dates.ts) — quoted:
  * `formatDate` → "`01 Sep 2026`(en)/ `2026年9月1日`(zh)": ``isZh(locale) ? `${p.y}年${p.m}月${p.d}日` : `${String(p.d).padStart(2, '0')} ${EN_MONTHS[p.m - 1]} ${p.y}` ``
  * `formatDateTime` → `01 Sep 2026 14:33`; `formatMonth` → `Sep 2026` / `2026年9月`
  * `formatAuditStamp` → "`2026-09-01 14:33`。**与界面语言无关,而这是刻意的。**" ``return `${p.y}-${pad(p.m)}-${pad(p.d)} ${p.hh}:${p.mm}` `` — **Tim's D2 ruling**: audit stamps stay `YYYY-MM-DD HH:MM` ("可排序、可复制、可粘回一条查询里"). Used by /settings/change-history (page.tsx:162,174) and /settings/deleted (:143); 64 files call formatAuditStamp/formatTimestamp (grep -l, **Measured**).
  * `toYmd` / `toYearMonth` → the machine forms.

### ★ Conflicts to put to Tim (**Inferred** from the quotes above)
1. **Audit trail "DD/MM/YYYY" contradicts D2 directly.** D2 ruled audit stamps are `YYYY-MM-DD HH:MM`, language-independent, and DATE-1 implemented it in `formatAuditStamp` + 39 `formatTimestamp` forwarders. AUDIT-TRAIL-1 either (a) prints trail dates via `formatAuditStamp` (keeps D2, contradicts the new ask), (b) changes `formatAuditStamp` to `DD/MM/YYYY HH:MM` (reverses D2 everywhere, incl. change-history/deleted, loses "sortable / pasteable into a query"), or (c) adds a separate trail formatter (a 4th date shape on screen). Needs an explicit ruling.
2. **Input "DD/MM/YYYY" vs display "01 Sep 2026"**: not a contradiction of any ruling, but the same page would show `01/09/2026` in the box and `01 Sep 2026` in the table beside it — Tim's original complaint (DATE-0 line 6) was "同一个日期在一次会话里读出三种样子"; this makes two deliberate shapes. Also his original DATE-0 ask was that the **picker too** show `01 Sep 2026`. Options: box text DD/MM/YYYY while typing but calendar header/aria in "01 Sep 2026"; or display-mode `01 Sep 2026` that switches to DD/MM/YYYY on focus. Ask.
3. **zh UI**: DATE-1 D4 prints `2026年9月1日` in zh. Is the box DD/MM/YYYY in zh too? (Recommend yes — an input mask is not prose — but it is Tim's call.)
4. DD/MM/YYYY is ambiguous with US MM/DD for days ≤12 — the reason D1 picked month names. A placeholder `DD/MM/YYYY` + calendar echo is the mitigation.

## 3 · Design facts for the shared picker

### 3.1 Libraries — **Measured** (`grep package.json`, `ls node_modules`)
* **No date library**: no react-day-picker, date-fns, dayjs, moment, luxon in package.json or node_modules (only `is-date-object`, transitive).
* Available: `radix-ui` ^1.6.7 umbrella → `node_modules/@radix-ui/react-popover` present; `@floating-ui/{core,dom,react-dom,utils}` present. **Popover is not used anywhere in app/ today** (grep `Popover` in app lib .tsx = 0 hits; only the `bg-popover` token in select.tsx). React 19.2.4, Next 16.2.6.
* Reusable in-repo pieces: `app/components/calendar/MonthGrid.tsx` (display month grid, `weekStartsMonday = true` default, "显式传,不猜", `daysInMonth`, `firstDow` via local-time `new Date(y,m-1,1).getDay()`); `lib/bankCsv.ts` `parseBankDate(raw,'DD/MM/YYYY')` (regex `^(\d{1,2})\/(\d{1,2})\/(\d{2}|\d{4})$`, `toIsoIfValid` rejects 31/02, `expandYear('26')` → 2026 i.e. always 20YY); `lib/dates.ts` `toYmd`, `parts`, `EN_MONTHS`; `lib/format.ts` `businessToday()` (Asia/Singapore).

### 3.2 i18n — **Measured**
* `lib/i18n/config.ts`: LOCALES `['en','zh']`, default `en`, cookie `NEXT_LOCALE`; `useLocale()`/`getLocale()`.
* Month names in messages: **0** (only `EN_MONTHS` const in lib/dates.ts:125). zh needs none (`9月`).
* Weekday names exist: `calendar.dow` en `{0:'Sun',1:'Mon',…}` (messages/en.ts:4688), zh `{0:'日',1:'一',…}` (zh.ts:4567), Sunday-indexed; MonthGrid rotates for Monday start. Reuse those keys.

### 3.3 How dates post — **Measured** (`node --disable-warning=MODULE_TYPELESS_PACKAGE_JSON scripts/check-date-data-paths.mjs`, exit 0)
* "ARM4 闭合集合:action 读了 24 个日期键 → 回查到 33 颗 name= 对得上的控件"; 63 native sites carry `name=`. Keys read by server actions via `formData.get('<key>')` include payment_date, order_date, arrival_date, price_date, sale_date, release_date, rate_date, output_date, due_date, assay_date, valid_from/to/until, signed_on, reference_date, quote_date, period_month, note_date, issue_date, entry_date, doc_date, departure_date, completed_date, asset_in_service_date, acquisition_date, expense_date, expiry_date, expected_delivery_date, reminder_at (grep, **Measured**; exact set of 24 is the script's `DATE_PARAM` regex).
* 8 GET forms (filters) post `from`/`to`/`date`/`month` into the URL; `lib/dateFilter.ts` `isYmd()` → '' = no filter.
* ⇒ The picker must render `<input type="hidden" name={name} value={iso}>` (ISO `YYYY-MM-DD`, `''` when empty) and keep the visible text box **unnamed**. For GET filters, empty must still post `from=` (today's behaviour) or be omitted — both are "no filter"; pick one.
* 84 controlled sites call `onChange(e.target.value)` expecting ISO strings → picker API should be `value: string /*YYYY-MM-DD|''*/`, `onChange(iso)`, plus `defaultValue` for the 50 uncontrolled ones (incl. GET forms and `key=`-remount resets).

### 3.4 min/max in use — **Measured** (sites.json, 12 attributes on 134 sites)
`max={businessToday()}` ×5 (PaymentDateInput, NewExpenseForm, NewFreightForm, NewInvoiceForm, CreateOrderInvoiceControl) · `max={todayIsoLocal()}` ×2 (inbound AssayForm, OutputAssayForm) · `max={today()}` ×2 (MyExpenseClaimsPanel, ChasePanel chasedOn) · `max={today}` ×1 (AgingAsOfControl) · `min={acquisitionDate}` ×1 (AssetActions in-service) · `min={chasedOn || undefined}` ×1 (ChasePanel promisedDate). All "no future" or "not before another date". Note `todayIsoLocal()` is a per-file copy (36 copies, DATE1-YMD-BUILDERS) reading **process/browser** tz, vs `businessToday()` = Asia/Singapore.

### 3.5 Server-side empty guards — **Measured** (AGENTS.md §"Dates and amounts that decide a period", line 1078; grep of named errors across app lib db messages)
Rule: a date deciding an FX rate, posting period or amount needs (1) submit **disabled while empty** and (2) server action **rejects empty independently**; never `COALESCE(p_date, CURRENT_DATE)`. Named errors present (occurrence counts across app/lib/db/messages): PAYMENT_DATE_REQUIRED 57, DATE_REQUIRED 43, ARRIVAL_DATE_REQUIRED 42, DOCUMENT_DATE_IN_FUTURE 39, REVERSAL_DATE_REQUIRED 33, REFERENCE_DATE_REQUIRED 29, ORDER_DATE_REQUIRED 28, PROCESS_DATE_REQUIRED 23, SALARY_EFFECTIVE_DATE_REQUIRED 17, CN_NOTE_DATE_REQUIRED 17, OUTPUT_DATE_REQUIRED 16, INVOICE_DATE_REQUIRED 15, FREIGHT_DATE_REQUIRED 14, ASSAY_DATE_INVALID 14, WHT_REMIT_DATE_REQUIRED 13, PRICE_DATE_REQUIRED 13, … (30+ distinct). These stay the backstop — the picker must never turn "typed but invalid" into a silent `''` on an **optional** field (see 3.7).

### 3.6 The controlled-input hazard — **Measured** (AGENTS.md:1087-1090; PaymentDateInput header)
"React never compares a controlled input's value prop against the live DOM, so a field can display a date the app does not have — that is exactly how the cost-settlement bug submitted `""` from a filled-looking box." Today patched by `onBlur` write-back at 4 sites. A custom picker whose hidden input is **derived from React state** (not from the DOM) removes this class by construction — but only if the posted value comes from state, and the visible text is re-parsed on blur/Enter/submit (a half-typed box must not look filled while state is '').

### 3.7 Keyboard / parsing rules to specify (**Inferred** design; parser pieces exist in bankCsv)
* Typing: digits only with auto-inserted `/` after DD and MM; accept `/ - . space` as separators; `1/9/26` → `01/09/2026` on blur.
* Partial input (`01/09/`): state stays `''`, box flagged invalid via `setCustomValidity` so a native form submit is **blocked** (not silently posted empty).
* Invalid calendar date (`31/02/2026`): reject (reuse `toIsoIfValid`), same blocking.
* 2-digit year: `expandYear` → 20YY; document it (no 19YY — hire dates/ birth-ish dates? none of the 134 names is a birth date: grep sites.json names, **Measured** none contain `birth`/`dob`).
* Paste of ISO `2026-09-01` (4-digit-first) → accept; paste `01 Sep 2026` → accept (bankCsv `DD MMM YYYY` case). Paste of US `9/1/2026` is indistinguishable → read as DD/MM (placeholder + calendar echo make it visible).
* min/max out of range: flagged + blocked, calendar days outside range disabled.
* Calendar: Monday first, arrow keys move day, PgUp/PgDn month, Home/End week, Enter selects, Esc closes, focus returns to box; clear button for non-required fields.
* Phone: native gives the OS wheel today; the custom one loses it (Q6 (3)) — either accept the custom popover on phone or use `inputMode="numeric"` text + popover. Must be measured on 390px.

### 3.8 390px / height — **Measured** from docs
* docs/variant-c-spec.md:241 — Tim's ruling R3 (2026-09-10): date inputs follow §4.1 single-line input: **32px high, 8px radius, 1px `--brand-border-strong`, 10px left padding**; §4.1 row: 14px text desktop / 16px phone (16px avoids iOS zoom). Exception E1/E6: `/login` and 48px touch rows (`min-h-[48px]`, ReceiveForm etc.) keep 44–48px — ReceiveForm.tsx:313 arrival_date is on one of those pages; check whether its date box is in the 48px family before forcing 32px.
* AGENTS.md:2385-2393 (INPUT-2b): "在一个【不换行】的容器里,有任何一个【内在尺寸由内容决定】的原生控件 —— 就是危险形状"; `flex-1`/`w-full` don't save it; cheapest cure is `flex-wrap`. A text box + icon button has its own intrinsic width (`size` default 20ch) — give the component a fixed width (≈ `10ch + padding + icon`) so its width is decided by the component, not by content, and run the repo's 390px overflow/drift reading on all 81 routes. Toolbars (33 filter sites, many `from`/`to` pairs side by side) are the likeliest overflow hosts.
* The popover must portal (Radix Popover does) to avoid clipping in `overflow-x-auto` tables (4 per-row sites, EditableTable phone expansion).

## 4 · Ending the ratchet — **Measured** (read of both scripts) + proposal (**Inferred**)
* Today `check-date-format.mjs` dimension ③: regex `/type="(date|month|datetime-local|week)"/g` over comment-blanked text of app/ lib/ .ts/.tsx; fails (exit 1) if count > baseline 134; **also `assertPopulation(..., nativeInputs, 100)` → exit 2 if fewer than 100** — i.e. the finished cut will make the script say "量具坏了" unless rewritten.
* `check-date-data-paths.mjs` likewise: `assertPopulation('文本数出的原生日期控件', textualDateInputs, 100)` (raw, **comments included**, 142 today), `arm1Sinks ≥ 1` (value/min/max on native date inputs; 132 today), `arm4Checked ≥ 5` (name= controls with tag input/Input; the picker's hidden input has `name={name}` dynamic → back-check finds 0). All go red (exit 2) at zero native inputs.
* Replacement check (proposal): "zero native date-ish inputs allowed" — AST: any `JsxAttribute type` with literal `date|month|datetime-local|week|time` on any tag, **plus** `type={expr}` where expr can evaluate to one of those (string literal branches), **plus** `createElement('input',{type:'date'})`, **plus** `.type = 'date'` assignments; allowlist exactly one file (the picker, which should have none — it renders `type="text"` + `type="hidden"`). Population assertions move to the new sink: count `<DatePicker …>` call sites (≈144) with `assertPopulation(≥100)`, and ARM1/ARM4 re-aim to the picker's `value/defaultValue/min/max/name` props (display formatters must not feed them).
* Fault injection: (1) add `<input type="date" />` to a real page → must exit 1 naming file:line; (2) add `type={'date'}` and `type={x ? 'date' : 'text'}` variants → exit 1; (3) put `type="date"` in a **comment** → must stay 0 (comment-stripping proven); (4) `--blind=ast|text` → exit 2 (existing selfproof pattern); (5) pass `value={formatDate(x,'en')}` to `<DatePicker>` → data-paths ARM1 exit 1.
* Purposes: **check-date-data-paths.mjs** — asserts no display formatter (`formatDate/DateTime/Month/AuditStamp`) output flows into the five machine paths (date input value/min/max; URL date params; `month` key; FormData date keys back-checked to `name=` controls; `Date.parse/new Date` of a formatted string), with `--inject=1..4` fault injection and 13 behavioural asserts that import lib/dates.ts & lib/dateFilter.ts. **check-date-null-preserved.mjs** — type-checker gate that a possibly-null date is not unconditionally formatted into a truthy `'—'` when used as a projection / JSX prop (the DATE-1 §X bug: `formatDate(null)` = `'—'` is truthy, flipped `inServiceDate ? …` and blanked a date input). Both run in `npm run build`.

## 5 · month (5) and datetime-local (4)

| type | sites (Measured) | what they are |
|---|---|---|
| month | finance/month-end/page.tsx:222 (GET `month`), finance/packs/PackControls.tsx:20 (`month`, onChange nav), hr/attendance/OpenPeriodForm.tsx:28 (controlled; comment :40 converts YYYY-MM → date), hr/leave/calendar/page.tsx:93 (GET `month`, ARM3 key), hr/payroll/PayrollGrid.tsx:338 (`period_month`, required) | period selectors; value `YYYY-MM` |
| datetime-local | finance/assets/[id]/DowntimePanel.tsx:157 (endAt), :215 (startedAt) — controlled, submit disabled while empty; tools/tasks/TaskModal.tsx:238 & tools/tasks/[id]/TaskHeader.tsx:163 (`reminder_at`, optional, `toLocalInput()` = **browser-local** time, `|| null` on server) | real instants |

Proposal (**Inferred**): one module, three modes sharing parser + popover: `DateField` (DD/MM/YYYY, day grid), `MonthField` (MM/YYYY text, 12-month grid, posts `YYYY-MM`), `DateTimeField` = DateField + a 24h `HH:MM` text box (posts `YYYY-MM-DDTHH:MM`; decide whether it is business-tz Asia/Singapore rather than the browser tz used today — today's datetime-local sites convert in **browser** local time, a latent tz inconsistency with `businessToday()`). Also note `type="time"` = 0 and `week` = 0 today, but the ratchet should ban them too.

## 6 · Things that contradict the brief / earlier numbers
* Brief says "month 6": code count today is **5** (+2 comments). **Measured**.
* Brief lists "`type: 'date'` in config objects/column defs (editable-table/add-row-panel)": **none exist** — those tables take render functions; their date cells are literal inputs already in the 134. **Measured**.
* The ratchet cannot "go to zero" as written: two population assertions (≥100 in each of check-date-format and check-date-data-paths) and ARM1/ARM4 population floors will exit 2. **Measured** (source read).
* Audit trail DD/MM/YYYY reverses Tim's D2 (`formatAuditStamp`). **Measured** (quote), conflict **Inferred**.
