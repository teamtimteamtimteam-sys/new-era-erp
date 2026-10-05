v1.4.34 — Every date box now shows and accepts day/month/year: type it (e.g. 05/10/2026) or pick from a calendar that starts on Monday, and impossible dates are stopped before saving.

# DATE-PICK-1 — one shared date picker replaces every native date, month and date-and-time box; AT-1d-3 close-out (2026-10-05)

**Opening check:** measured at **2026-10-05 09:12:02 CST** (this session's first command). The tree was clean apart from Tim's untracked
`docs/Data capture and ERP integreation.pdf`, which I did not touch. After `git fetch`, `HEAD` = `origin/main` = `ls-remote` =
`ea4e6018b78f7f4b263962e99732cbbd9d4900da`. **Approvals ON and stayed ON** (finance / cfo / 1,000). 7 real accounts, all enabled, before and after.
No real auth account was created, disabled or deleted; the probe's, survey's and smoke's throwaway accounts came and went through their own
ephemeral plans (§7.1). **No migration** — nothing in this cut needed one.

Every figure is a script's own exit line or a query named with who ran it. Live reads are as `postgres` (`rolbypassrls = true`) on base tables,
through the Management API, unless stated otherwise.

## §1 · Step 1 — the 1d-3 close-out, item by item

**The broken window** is recorded in `docs/forward-queue.md` item 32 (the 1d-2 format):

| | value | source |
|---|---|---|
| start | **2026-10-05 01:14:31 CST** | `db/migration-windows.tsv` (`2026-10-05T01:14:31+0800	2026-10-05-at1d3-trails-pay-and-performance.sql`) |
| end, lower bound | **2026-10-05 02:24:44 CST** | `git reflog show --date=iso refs/remotes/origin/main`: `ea4e6018 refs/remotes/origin/main@{2026-10-05 02:24:44 +0800}: update by push` |
| end, upper bound | **2026-10-05 09:12:02 CST** | this session's first command (`date`). It rests on Tim's "deployed", **not** on a Vercel reading |
| window | **at least 1 h 10 min 13 s, at most 7 h 57 min 31 s** | the upper bound is wide because 6 h 47 min passed between the push and this close-out |

**UNBLOCK-1** now lists `AT1D3-ME-PAYSLIP-CURRENCY-NEEDS-HR-VIEW` directly after the privacy group (`docs/forward-queue.md`).

**Read-only verification of what the 1d-3 report did not mention** (all re-read this session; nothing was missing or partial, so step 2 went ahead):

| | item | verdict | evidence |
|---|---|---|---|
| a | Q11: payroll lines paired by employee | ✅ | `lib/trail/render.ts:4330-4358` — deletes and inserts collected into `del` / `ins` maps keyed by `employee_id`; for each pair, a column whose old and new values are equal is skipped (`if (JSON.stringify(before.old?.[c] ?? null) === JSON.stringify(after.new?.[c] ?? null)) continue`), a changed column is one line `prl.lineHeading · <label>`; an insert without a delete is "Line added", the reverse "Line removed". Golden in `scripts/check-trail-wording.mjs:3478-3481` (Lim Wei Ming unchanged pair, Sandra Tan changed) → expected `:3666-3676`: only `Line · Sandra Tan · Gross pay: 4,000.00 SGD → 4,200.00 SGD` (+ Employee CPF, Net pay), nothing for Lim Wei Ming. Fixture 246 arm PP `:230-235` (`'FIXTURE 246 PP (Q11): the delete and the re-insert of one person''s line must be one operation'`) |
| b | Q10: suffixes stripped; "Payroll unposted"; the label without its raw kind | ✅ | `lib/trail/render.ts:4278-4284` `splitPayrollDecisionNote` (strips `本期含审批人自己的工资行 · this period includes the approver's own pay line: …`, keeps the code) and `:4286-4292` `splitPayrollUnpostNote` (strips `[YYYY-MM-DD HH:MI unposted] reason`); `:4392` `title: withPart(tx(d, 'prl.unposted'), …), reason: typed(reason)`; `lib/trail/text.ts:807` `'prl.unposted': 'Payroll unposted'`, `:828` `'prl.ownLine': "This period includes the approver's own pay line: {code}"`. Label: `scripts/gen-trail-catalogue.mjs:672` hides `payroll_requests: ['label']`; `db/functions/trail_ref_label.sql:199` names a request `… 'unposting request' ELSE 'posting request'`. Fixture 246 R `:410-411` (`LIKE '%post #%'` → `RAISE … 'a payroll request is named by its period without the raw kind'`); goldens `check-trail-wording.mjs:3722-3735` (own-line said in English) and `:3767` ("Payroll unposted", reason "Wrong CPF rate for two people") |
| c | Q5: `my_review` for the reviewer only; approval rows Restricted to a reviewer without hr.view | ✅ | `db/functions/trail_subjects.sql:246` `('my_review', ARRAY[]::text[], 'performance_reviews', 'id', 'gate:reviewer', NULL)` (no page code, M12 gate); `db/functions/trail_root_gate.sql:19` (`reviewer_employee_id = current_user_employee()`); members `trail_subject_members.sql:462-463` (goals, approval_log). Fixture 246 MR `:302-310`: as the reviewer, review and goals present, `IF pg_temp.f246_count(v_j, 'approval_log') <> 0 THEN RAISE … 'the approval rows must be Restricted to a reviewer without hr.view'`, row_hidden present; the reviewed employee and a stranger are refused |
| d | Q6 · Q7: review-cycle wording; approval outcome with salary masked without data.view_pay | ✅ | `lib/trail/text.ts:830` `'rv.openedAnnual': 'Annual review opened (cycle {cycle})'`, `:850-852` `Review cycle created / opened / closed`. Goldens: `check-trail-wording.mjs:3833-3840` "Annual review opened (cycle FY2026 annual)"; `:4032-4037` "Review cycle opened · FY2026 annual" with no review lines; `:3920-3929` "Review approved — Rating: Meets Expectations · Probation outcome: Confirm · **New monthly salary: Restricted** · Effective from: 01/11/2026". Fixture 246 RV `:292-299` (employee row and history not on the review's trail; as a reader without view_pay `new_monthly_salary ? '$restricted'`, rating `MEETS` readable); CY `:319-325` |
| e | Q14 · Q16: no review or KPI trail on /me | ✅ | `app/me/page.tsx` has exactly three `<AuditTrail>` subjects: `:466` `my_leave_request`, `:477` `my_medical_claim`, `:482` `my_expense_claim` (no `my_review`, no `kpi_entry`). `scripts/probe-at1d3.mjs:199-207` asserts the set from source; its injection `me-review-trail` (`:202`) reds it |
| f | Q34: enum English for `kpi_cycles.status` and the other 1d-3 enums | ✅ | `scripts/gen-trail-catalogue.mjs:933-936` → generated `lib/trail/catalogue.generated.ts`: `"kpi_cycles#status":{"draft":"Draft","open":"Open","closed":"Closed"}` · `"kpi_entries#score_kind":{"judged":"Judged","computed":"Computed"}` · `"kpi_cycles#gate":{"M3":"Month 3 gate","M6":"Month 6 gate"}` (read with `grep -o` this session) |
| g | the Chinese/English identical-output check includes a 1d-3 subject | ✅ | `scripts/probe-at1d3.mjs:209-229`: the page list is every payroll period, every review, `/hr/reviews/cycles`, `/hr/reviews/scale`, every KPI month, plus a leave and an employee page; each is fetched with `NEXT_LOCALE` en and zh and asserted `zt === et` (`:226`); injection `cjk` (`:223`) |
| h | the queue marks AT-1d / AUDIT-TRAIL-1 complete as v1.4.33 with DATE-PICK-1 next; the handback opens with the release line | ✅ | `docs/forward-queue.md` item 32 ("AT-1d 三刀做完,AUDIT-TRAIL-1 = `v1.4.33` … 下一刀 DATE-PICK-1(`v1.4.34`)"), the HISTORY-family entries "✅ AUDIT-TRAIL 的后几刀 … AUDIT-TRAIL-1 = `v1.4.33`" and "✅ AT-1d … 三刀都做完了(1d-3,2026-10-05),`v1.4.33` 随它发布", and "⬜ ★ 下一刀:DATE-PICK-1(`v1.4.34`…)" (now marked ✅ by this cut). `docs/handbacks/AUDIT-TRAIL-1d-3.md:1` begins `v1.4.33 — Every page now ends with a plain-English audit trail …` |
| i | 1d-3's self-taken decisions (`AUDIT-TRAIL-1d-3.md` §9, titles) | listed | 1. KPI scoring is registered as a pre-log stamp. 2. Two stamps are deliberately not registered. 3. A re-save read without data.view_pay says one Restricted line. 4. The period's journals are named by structure, never by their memo. 5. A journal's number is shown only to a reader who can see that journal. 6. The approver's-own-pay-line suffix is stripped and said again in English. 7. A payroll request's `label` is hidden; a request is named "PAY-… posting request". 8. The request kind's value labels stay "Post" / "Unpost". 9. "Payroll recorded" counts the people, not each line. 10. Before the log, "Review approved" states the outcome from the review as it is today. 11. A review's name in references is its type and period. 12. The void banner became the shared `EndedBanner`. 13. The KPI block is drawn only where scores are visible. 14. The review-cycle block reads every cycle, deleted ones included. 15. Q19's fix is a SECURITY DEFINER function, not a self-read policy. 16. The migration grants `my_period_labels()` explicitly. 17. approve_review's salary sentence is recognised on the employee page. 18. Two message keys were deleted with their sections. 19. The smoke checks `/my-reviews/[id]`'s trail inside its reviewer session. 20. `/hr/kpi/score` is not in the smoke's `MUST_CONTAIN`. 21. Q19 at page level is proved by identity, not by a page load. 22. The live proof makes its own payroll period and review. 23. The live proof changes one rating's description. 24. Two fixes to `scripts/survey-phone.mjs` for addresses with a query string. 25. Fixture 246's stamp-actor assertions accept any recorded account. 26. KPI generation lines read "F1: Stocktake accuracy (30%)". 27. The rating scale's table noun is "rating". 28. The wording prefixes are `prl.` / `rv.` / `rcy.` / `kpe.`. 29. The "closed cycle can be reopened" side finding was measured false. 30. The 1d-3 window start is filled from `db/migration-windows.tsv` |

## §2 · The count, re-measured (the survey's 134 is from 2026-09-29)

Measured at the start of this cut by an AST enumerator over every `.ts`/`.tsx` under `app/` and `lib/` (every JSX `type` attribute whose literal
is a date kind; scratchpad `dp/enum.mjs`), and independently by `node scripts/check-date-format.mjs` ("代码里 134 处 · 注释里 8 处"):

| kind | native inputs in code | became |
|---|---|---|
| `date` | **125** | `<DatePicker>` (DD/MM/YYYY, posts `YYYY-MM-DD`) |
| `month` | **5** | `<DatePicker kind="month">` (MM/YYYY, posts `YYYY-MM`) |
| `datetime-local` | **4** | `<DatePicker kind="datetime">` (DD/MM/YYYY + HH:MM Singapore time, posts `YYYY-MM-DDTHH:MM+08:00`) |
| `week` / `time` | 0 | — |
| **total** | **134 in 90 files** (+ 8 mentions in comments) | **0 left**, counted two independent ways (§4) |

After: **144 picker call sites** (AST = text = 144). The arithmetic: 134 native sites − 2 wrapper bodies that were deleted (`DateFilterInput`,
`ContractDateInput`) + their 4 + 6 call sites now calling `DatePicker` directly + 2 `PaymentDateInput` call sites (the wrapper is kept and counted
as a picker tag) = 144. `CostSettlePanel`'s local `dateField()` is one call site rendered twice. Comment mentions left: 1, a historical note in
`lib/dates.ts:112`.

The wrappers: `DateFilterInput` (`app/components/ui/date-filter-input.tsx`) and `ContractDateInput` (`app/contracts/ContractDateInput.tsx`) are
**deleted** — both existed only to keep the native count from growing. `PaymentDateInput` **stays** as a thin wrapper (required, not after today in
Singapore — one place for the payment-date rule). `CostSettlePanel`'s `dateField()` helper now renders the picker.

## §3 · What was built

**`app/components/ui/date-picker.tsx`** — one client component, Radix Popover (already installed; no new library):
- **Box:** a text input showing `DD/MM/YYYY` (month `MM/YYYY`; date-and-time adds an `HH:MM` box), 32px high (`CONTROL_INPUT`), fixed width
  (date 9.75rem, month 7.75rem, time 4.75rem), a calendar button inside the box. `inputMode="numeric"` so a phone shows digits (`05102026` works).
- **Typing (Q37):** `D/M/YYYY` · `DD/MM/YY` (= 20YY) · `DDMMYYYY` · a pasted ISO date (`2026-10-05`, a full timestamp too). Separators `/ . -`.
  A complete entry (four-digit year, eight digits, ISO) is taken as you type; a two-digit year when you leave the box or press Enter.
  On leaving, the box is rewritten as `DD/MM/YYYY`. An impossible date (31/02/2026) says "31/02/2026 is not a real date."; a malformed one
  "Type the date as DD/MM/YYYY, for example 05/10/2026."; a date past `max` "… is in the future. Today is 05/10/2026." (or "after the latest date
  allowed here"); before `min` likewise. Chinese interface: the same rules, the messages in Chinese.
- **Blocking:** the picker **never** hands an invalid value on — `onChange` only ever receives a valid ISO string or `''` (cleared).
  ① It sets `setCustomValidity(message)` on its text box, so a native form submit is stopped by the browser before the submit event.
  ② Panels that save through a button `onClick` take `onInvalidChange` and disable their save button (wired at every such site, §5).
  ③ A filter that applies on change simply never receives the invalid value.
  The old `onBlur` write-backs (the "filled-looking box that posts empty" hazard, AGENTS.md) are gone: the posted value comes from React state.
- **Calendar (Q35 · Q39):** Monday first; month and weekday names from the messages (`datePicker.month.*` — new, both languages; weekdays reuse
  `calendar.dow`): "October 2026" / "2026年10月", "Mon … Sun" / "一 … 日". Days outside min/max are greyed, not choosable, with a `title` and the
  reason written under the calendar ("Future dates can't be chosen. Today is 05/10/2026."). Footer: "Today" / "This month", and "Clear" for
  optional boxes.
- **Keyboard:** arrows ±1 day / ±1 week, PageUp/PageDown ±1 month (Shift: ±1 year), Home/End to Monday/Sunday, Enter/Space selects, Esc closes and
  returns focus to the box (and does not also close an enclosing modal); Alt+↓ in the box opens the calendar.
- **Posting:** with `name`, a hidden input carries the ISO value — every server action receives what it received from the native control
  (date `YYYY-MM-DD`, month `YYYY-MM`). Date-and-time posts `YYYY-MM-DDTHH:MM+08:00` (§8 decision 2).
- **Forms:** honours `form.reset()` like a native input; works with draft restore (`lib/useFormDraft.ts` now tells the picker when it rewrote its
  hidden input, and a calendar pick raises the `input` event the draft listens for).

**`lib/dates.ts`** (the one allowlisted date module): `parseTypedDate` · `parseTypedMonth` · `parseTypedTime` · `formatTypedDate` ·
`formatTypedMonth` · `isoDateIfValid` · `daysInMonthOf` · `mondayIndex` · `addDaysIso` · `addMonthsIso` · `toBusinessDateTime` ·
`businessDateTimeIso` · `DATE_PICKER_RESTORE`.

**Messages:** `datePicker.*` in `messages/en.ts` and `messages/zh.ts` (26 keys + 12 month names each). `scripts/check-i18n.mjs` MANIFEST:
`datePicker.month.` → `MONTH_KEYS` in the component.

## §4 · The checks (Q38)

**`scripts/check-date-format.mjs` dimension ③ — "zero native date, month or date-and-time inputs anywhere":**
- Two independent counts: **path A** walks the TypeScript AST (JSX `type="…"`, `type={…'date'…}` including ternaries, `createElement('input',
  {type})`, `el.type = …`, `setAttribute('type', …)`; kinds date · month · datetime-local · week · time); **path B** reads characters only
  (comments blanked, strings kept, whole-file regexes — no line splitting). They must agree (`assertPinned`), and both must be 0.
- **A canary runs first on every invocation:** a fixed source with 5 native controls (incl. a multi-line opening tag and an assignment), one inside a
  comment that must not count, and one picker. Either path miscounting it → exit 2 "I am blind", never "clean".
- Coverage: both paths must see ≥ 500 `type=` attributes (751 / 751) and ≥ 100 picker call sites (144 = 144).
- The baseline's `nativeDateInputs` is pinned to 0 (informational — the check no longer reads it).
- Comment blanking moved to `scripts/lib/blank-comments.mjs` (shared with the next check).

**`scripts/check-date-data-paths.mjs` — re-aimed at the picker's props:** ARM 1 now judges `value` / `defaultValue` / `min` / `max` on `<DatePicker>`
and `<PaymentDateInput>` (141 sinks) — no display formatter may feed them (`formatTypedDate` / `formatTypedMonth` / `formatTrailStamp` /
`formatDocumentDate` added to the display family). ARM 4's back-check reads picker `name=` (24 date keys read by actions → 37 matching controls).
The old "≥ 100 native inputs by text" floor became "picker call sites: AST 144 = text 144, ≥ 100". 19 new behaviour asserts (38 total): every typed
format → the same ISO, impossible dates say "impossible" (31/02, 29/02/2026, 00/10, 05/13), leap day accepted, empty is "not filled", month and time
parsing, the box text is rejected by `isYmd`, `+08:00` offset, UTC → Singapore wall time, Monday-first index.

**Fault injection (real sources run through the same scan, not a synthetic violation):**

| check | injection | result |
|---|---|---|
| check-date-format | `--inject=native` (`type="date"`) | exit 1, names `app/__inject__/DatePickInjection.tsx:2 type="date"` |
| | `--inject=native-expr` (`type={'date'}`) | exit 1, `type={…'date'…}` |
| | `--inject=native-ternary` | exit 1, `type={…'datetime-local'…}` |
| | `--inject=native-month` (multi-line tag) | exit 1, line 3 `type="month"` |
| | `--inject=native-datetime` | exit 1 |
| | `--inject=comment` (only in a comment) | **exit 0** (comment stripping proven) |
| | `--blind=ast` | exit 2: "金丝雀里有 5 处 … 语法树数出 0 / 0,字符数出 5 / 1" |
| | `--blind=text` | exit 2: "… 语法树数出 5 / 1,字符数出 0 / 0" |
| check-date-data-paths | `--inject=picker` (`<DatePicker value={formatDate(…)}>`) | exit 1, ARM 1 names the injected file |
| | `--inject=picker-max` (`max={formatTypedDate(…)}`) | exit 1, ARM 1 |
| | `--inject=picker-name` (`<PaymentDateInput name="zz_inject_date" value={formatDate(…)}>` + an action reading it) | exit 1, ARM 4 (the script exits 2 if the predicted arm stays green) |
| | `--inject=1…4` (the existing arms) | exit 1 each |
| both, clean | — | exit 0 |

## §5 · Pages — every changed route, with its file

92 routes import a changed file (computed from the import graph: every `page.tsx` that transitively imports one). Columns: route · page file ·
the changed files it renders.

| route | page file | changed files it renders |
|---|---|---|
| `/contracts/[id]` | `app/contracts/[id]/page.tsx` | `contracts/[id]/HeaderForm.tsx` |
| `/contracts/new` | `app/contracts/new/page.tsx` | `contracts/new/NewContractForm.tsx` |
| `/finance/assets` | `app/finance/assets/page.tsx` | `finance/assets/page.tsx` · `finance/assets/AssetActions.tsx` |
| `/finance/assets/[id]` | `app/finance/assets/[id]/page.tsx` | `finance/assets/AssetActions.tsx` · `finance/assets/[id]/MaintenancePanel.tsx` · `finance/assets/[id]/DowntimePanel.tsx` |
| `/finance/assets/new` | `app/finance/assets/new/page.tsx` | `finance/assets/new/NewAssetForm.tsx` |
| `/finance/balance-sheet` | `app/finance/balance-sheet/page.tsx` | `finance/balance-sheet/BsToolbar.tsx` |
| `/finance/bank` | `app/finance/bank/page.tsx` | `finance/bank/TransferForm.tsx` |
| `/finance/bank/import` | `app/finance/bank/import/page.tsx` | `finance/bank/import/ImportStatementForm.tsx` |
| `/finance/cash-forecast` | `app/finance/cash-forecast/page.tsx` | `finance/cash-forecast/RecurringLines.tsx` |
| `/finance/cashflow` | `app/finance/cashflow/page.tsx` | `finance/cashflow/CashflowToolbar.tsx` |
| `/finance/claims` | `app/finance/claims/page.tsx` | `finance/claims/ClaimDecisionPanel.tsx` |
| `/finance/expenses` | `app/finance/expenses/page.tsx` | `finance/expenses/ExpensesToolbar.tsx` |
| `/finance/expenses/[id]` | `app/finance/expenses/[id]/page.tsx` | `finance/expenses/[id]/ReleasePrepaymentPanel.tsx` |
| `/finance/expenses/new` | `app/finance/expenses/new/page.tsx` | `finance/expenses/new/NewExpenseForm.tsx` |
| `/finance/freight/new` | `app/finance/freight/new/page.tsx` | `finance/freight/new/NewFreightForm.tsx` |
| `/finance/fx/[id]/edit` | `app/finance/fx/[id]/edit/page.tsx` | `finance/fx/FxRateFormFields.tsx` |
| `/finance/fx/new` | `app/finance/fx/new/page.tsx` | `finance/fx/FxRateFormFields.tsx` |
| `/finance/gst` | `app/finance/gst/page.tsx` | `finance/gst/GstControls.tsx` |
| `/finance/gst/[periodId]` | `app/finance/gst/[periodId]/page.tsx` | `finance/gst/GstControls.tsx` · `finance/gst/[periodId]/GstFilingPanel.tsx` |
| `/finance/invoices` | `app/finance/invoices/page.tsx` | `finance/invoices/InvoicesToolbar.tsx` |
| `/finance/invoices/[id]` | `app/finance/invoices/[id]/page.tsx` | `finance/invoices/[id]/VoidInvoiceControl.tsx` · `finance/invoices/[id]/CreateCreditNoteControl.tsx` |
| `/finance/invoices/new` | `app/finance/invoices/new/page.tsx` | `finance/invoices/new/NewInvoiceForm.tsx` |
| `/finance/journal` | `app/finance/journal/page.tsx` | `finance/journal/JournalToolbar.tsx` |
| `/finance/journal/new` | `app/finance/journal/new/page.tsx` | `finance/journal/new/NewEntryForm.tsx` |
| `/finance/month-end` | `app/finance/month-end/page.tsx` | `finance/month-end/page.tsx` |
| `/finance/packs` | `app/finance/packs/page.tsx` | `finance/packs/PackControls.tsx` |
| `/finance/payables` | `app/finance/payables/page.tsx` | `finance/AgingAsOfControl.tsx` |
| `/finance/payment-requests/[id]` | `app/finance/payment-requests/[id]/page.tsx` | `finance/payment-requests/[id]/RequestActions.tsx` · `components/finance/PaymentDateInput.tsx` |
| `/finance/payments` | `app/finance/payments/page.tsx` | `finance/payments/PaymentsToolbar.tsx` |
| `/finance/payments/new` | `app/finance/payments/new/page.tsx` | `components/finance/PaymentDateInput.tsx` |
| `/finance/payroll-payments` | `app/finance/payroll-payments/page.tsx` | `finance/payroll-payments/PayPanel.tsx` |
| `/finance/pnl` | `app/finance/pnl/page.tsx` | `finance/pnl/PnlToolbar.tsx` |
| `/finance/processing-costs` | `app/finance/processing-costs/page.tsx` | `finance/processing-costs/CostSettlePanel.tsx` |
| `/finance/receivables` | `app/finance/receivables/page.tsx` | `finance/AgingAsOfControl.tsx` |
| `/finance/revaluation` | `app/finance/revaluation/page.tsx` | `finance/revaluation/page.tsx` |
| `/finance/settings` | `app/finance/settings/page.tsx` | `finance/settings/LockForm.tsx` |
| `/finance/wht` | `app/finance/wht/page.tsx` | `finance/wht/WhtControls.tsx` |
| `/hr/attendance` | `app/hr/attendance/page.tsx` | `hr/attendance/OpenPeriodForm.tsx` |
| `/hr/claims/[id]` | `app/hr/claims/[id]/page.tsx` | `hr/claims/[id]/ClaimControls.tsx` |
| `/hr/claims/new` | `app/hr/claims/new/page.tsx` | `hr/claims/ClaimForm.tsx` |
| `/hr/employees/[id]/edit` | `app/hr/employees/[id]/edit/page.tsx` | `hr/employees/EmployeeForm.tsx` |
| `/hr/employees/new` | `app/hr/employees/new/page.tsx` | `hr/employees/EmployeeForm.tsx` |
| `/hr/leave` | `app/hr/leave/page.tsx` | `hr/leave/page.tsx` |
| `/hr/leave/calendar` | `app/hr/leave/calendar/page.tsx` | `hr/leave/calendar/page.tsx` |
| `/hr/leave/holidays` | `app/hr/leave/holidays/page.tsx` | `hr/leave/holidays/HolidaysEditor.tsx` |
| `/hr/leave/new` | `app/hr/leave/new/page.tsx` | `hr/leave/LeaveForm.tsx` |
| `/hr/payroll/[id]/edit` | `app/hr/payroll/[id]/edit/page.tsx` | `hr/payroll/PayrollGrid.tsx` |
| `/hr/payroll/new` | `app/hr/payroll/new/page.tsx` | `hr/payroll/PayrollGrid.tsx` |
| `/hr/reviews/[id]` | `app/hr/reviews/[id]/page.tsx` | `hr/reviews/HrDecisionForm.tsx` |
| `/hr/reviews/cycles` | `app/hr/reviews/cycles/page.tsx` | `hr/reviews/cycles/CycleForm.tsx` |
| `/hr/training/[id]/edit` | `app/hr/training/[id]/edit/page.tsx` | `hr/training/TrainingForm.tsx` |
| `/hr/training/new` | `app/hr/training/new/page.tsx` | `hr/training/TrainingForm.tsx` |
| `/inbound` | `app/inbound/page.tsx` | `inbound/InboundToolbar.tsx` |
| `/inbound/[id]/assays/new` | `app/inbound/[id]/assays/new/page.tsx` | `inbound/[id]/assays/new/AssayForm.tsx` |
| `/inbound/[id]/edit` | `app/inbound/[id]/edit/page.tsx` | `inbound/[id]/edit/EditInboundForm.tsx` · `inbound/[id]/edit/PrepaymentPanel.tsx` |
| `/inbound/new` | `app/inbound/new/page.tsx` | `inbound/new/NewInboundForm.tsx` |
| `/inbound/receive` | `app/inbound/receive/page.tsx` | `inbound/receive/ReceiveForm.tsx` |
| `/inventory/reports/ledger` | `app/inventory/reports/ledger/page.tsx` | `inventory/reports/ledger/page.tsx` |
| `/logistics/containers` | `app/logistics/containers/page.tsx` | `logistics/containers/NewContainerForm.tsx` |
| `/logistics/containers/[id]` | `app/logistics/containers/[id]/page.tsx` | `logistics/containers/[id]/ContainerPanels.tsx` |
| `/logistics/forwarders/[id]` | `app/logistics/forwarders/[id]/page.tsx` | `logistics/forwarders/[id]/ForwarderPanels.tsx` |
| `/logistics/shipping` | `app/logistics/shipping/page.tsx` | `logistics/shipping/ShipQueueControl.tsx` |
| `/me` | `app/me/page.tsx` | `hr/leave/LeaveForm.tsx` · `hr/claims/ClaimForm.tsx` · `me/MyExpenseClaimsPanel.tsx` |
| `/operation/handovers/new` | `app/operation/handovers/new/page.tsx` | `operation/handovers/new/NewHandoverForm.tsx` |
| `/operation/orders/new` | `app/operation/orders/new/page.tsx` | `operation/orders/new/NewWorkOrderForm.tsx` |
| `/operation/processing` | `app/operation/processing/page.tsx` | `operation/processing/ProcessingToolbar.tsx` |
| `/operation/processing/new` | `app/operation/processing/new/page.tsx` | `operation/processing/new/NewProcessingForm.tsx` |
| `/output` | `app/output/page.tsx` | `output/OutputToolbar.tsx` |
| `/output/[id]/assays/new` | `app/output/[id]/assays/new/page.tsx` | `output/[id]/assays/new/OutputAssayForm.tsx` |
| `/output/[id]/edit` | `app/output/[id]/edit/page.tsx` | `output/[id]/edit/EditOutputForm.tsx` · `output/[id]/edit/SalePanel.tsx` |
| `/output/new` | `app/output/new/page.tsx` | `output/new/NewOutputForm.tsx` |
| `/purchasing/licences` | `app/purchasing/licences/page.tsx` | `purchasing/licences/LicencePanel.tsx` |
| `/purchasing/orders` | `app/purchasing/orders/page.tsx` | `purchasing/orders/OrdersToolbar.tsx` |
| `/purchasing/orders/[id]` | `app/purchasing/orders/[id]/page.tsx` | `purchasing/orders/[id]/PoPaymentTermsTable.tsx` · `purchasing/orders/[id]/ExpectedDateControl.tsx` |
| `/purchasing/orders/[id]/amend` | `app/purchasing/orders/[id]/amend/page.tsx` | `purchasing/orders/[id]/amend/AmendOrderForm.tsx` |
| `/purchasing/orders/new` | `app/purchasing/orders/new/page.tsx` | `purchasing/orders/new/NewOrderForm.tsx` |
| `/sales/commissions/[id]/edit` | `app/sales/commissions/[id]/edit/page.tsx` | `sales/commissions/CommissionForm.tsx` |
| `/sales/commissions/new` | `app/sales/commissions/new/page.tsx` | `sales/commissions/CommissionForm.tsx` |
| `/sales/customers/[id]` | `app/sales/customers/[id]/page.tsx` | `sales/customers/StatementPanel.tsx` · `sales/customers/ChasePanel.tsx` |
| `/sales/orders/[id]` | `app/sales/orders/[id]/page.tsx` | `sales/orders/[id]/CreateOrderInvoiceControl.tsx` |
| `/sales/orders/new` | `app/sales/orders/new/page.tsx` | `sales/orders/new/NewOrderForm.tsx` |
| `/sales/quotes/[id]` | `app/sales/quotes/[id]/page.tsx` | `sales/quotes/[id]/ConvertControl.tsx` |
| `/sales/quotes/new` | `app/sales/quotes/new/page.tsx` | `sales/quotes/new/NewQuoteForm.tsx` |
| `/settings/change-history` | `app/settings/change-history/page.tsx` | `settings/change-history/page.tsx` |
| `/settings/deleted` | `app/settings/deleted/page.tsx` | `settings/deleted/page.tsx` |
| `/suppliers/[id]/edit` | `app/suppliers/[id]/edit/page.tsx` | `suppliers/[id]/edit/CompliancePanel.tsx` |
| `/tools/pricing/calculator` | `app/tools/pricing/calculator/page.tsx` | `tools/pricing/calculator/CalculatorForm.tsx` |
| `/tools/pricing/metal-prices/[id]/edit` | `app/tools/pricing/metal-prices/[id]/edit/page.tsx` | `tools/pricing/metal-prices/[id]/edit/EditMetalPriceForm.tsx` |
| `/tools/pricing/metal-prices/bulk` | `app/tools/pricing/metal-prices/bulk/page.tsx` | `tools/pricing/metal-prices/bulk/BulkPricesForm.tsx` |
| `/tools/pricing/metal-prices/new` | `app/tools/pricing/metal-prices/new/page.tsx` | `tools/pricing/metal-prices/new/NewMetalPriceForm.tsx` |
| `/tools/tasks` | `app/tools/tasks/page.tsx` | `tools/tasks/TaskModal.tsx` |
| `/tools/tasks/[id]` | `app/tools/tasks/[id]/page.tsx` | `tools/tasks/[id]/NodeTree.tsx` · `tools/tasks/[id]/TaskHeader.tsx` |

**How each site blocks an invalid date** (from the five conversion reports, checked against the code): sites inside a natively submitted form are
covered by `setCustomValidity` (no wiring); filter toolbars that apply on change need none; **button-submitted panels are wired with
`onInvalidChange` into every button that sends the date** (not into Cancel): `/finance/assets` (commission, plan), `/finance/assets/[id]`
(downtime start and close, maintenance, capitalise), `/finance/bank` (transfer), `/finance/cash-forecast` (recurring line), `/finance/claims`
(per row, Approve only), `/finance/gst` (open period), `/finance/gst/[periodId]` (filing), `/finance/invoices/[id]` (void), `/finance/payroll-payments`
(three pay buttons), `/finance/processing-costs` (remit, relieve), `/finance/settings` (set lock), `/finance/wht`, `/finance/payment-requests/[id]` (pay),
`/hr/attendance`, `/hr/claims/new`, `/hr/claims/[id]` (pay), `/hr/leave/new`, `/hr/leave/holidays`, `/hr/reviews/[id]` (HR decision), `/hr/reviews/cycles`,
`/me` (expense claim), `/operation/handovers/new`, `/operation/orders/new`, `/output/[id]/edit` (the price-quote button; the sale itself is a native
form), `/logistics/shipping`, `/sales/customers/[id]` (chase; statement preview and issue), `/sales/orders/[id]` (create invoice),
`/sales/quotes/[id]` (convert), `/tools/tasks/[id]` (new step).

## §6 · Verification, in the brief's order

| # | step | result |
|---|---|---|
| 1 | offline gate (`db/gate.py --offline`) | `GATE_OFFLINE_EXIT=0` |
| 2 | `npx tsc --noEmit` | `TSC_OWN_EXIT=0` |
| 3 | `npm run build` | first run `BUILD_EXIT=1` — the eslint freeze caught 2 new errors (refs written during render in the picker) and 2 new warnings (two `today()` helpers left unused). Fixed (`useEffectEvent`; the dead helpers deleted), lint baseline tightened (error 41 · warning 86 → 83), rebuilt: `BUILD_EXIT=0` |
| 4 | full gate (`db/gate.py`) | `GATE_EXIT=0` (366 s): rebuildability ✓ · mirrors vs live ✓ · behavioural assertions ✓ · anon surface ✓ (live ⊆ the 327-line baseline) |
| 5 | i18n check | `I18N_OWN_EXIT=0` |
| 6 | error-swallowing check | `SWALLOW_OWN_EXIT=0` (0 unallowed, 9 allowlisted) |
| 7 | layout survey | **89 of the 92 changed routes** (3 have no live record: contracts 0, payment requests 0, commission agreements 0 rows; each one's date component is measured on a sibling route — §8 decision 24). **1280 px:** 88 measured (1 redirect: the only payroll period is posted, so its edit page redirects), **0 page overflow, 0 clipped tables** (`SURVEY1280_EXIT=0`). **390 px:** 87 measured, 0 clipped tables, **5 pages overflow** — `/operation/processing/new` +177 · `/finance/freight/new` +27 · `/sales/orders/new` +8 · `/sales/quotes/[id]` +8 · `/finance/month-end` +6; the culprits named are `<select>` boxes and a table cell, and the probe measured each page with the original native control swapped back in: **identical overflow, so the picker adds 0 px** (§7; `/operation/processing/new`'s overflow from the same select is on record from an earlier cut). The pass also logged one HTTP 500 for `/hr/payroll/new`; not reproducible (§8 decision 25) and re-measured clean on its own pass (`SURVEY390B_EXIT=0`). The 390 px pass's own exit line is `SURVEY390_EXIT=1` because of that one 500 |
| 8 | smoke (background) | first run `SMOKE_EXIT=1`: 259 ok, 9 skipped, **1 failed** — `/my-reviews` HTTP 500 with `查询失败(current_user_permissions): TypeError: fetch failed` (the dev server's request to Supabase failed at the network layer; `/my-reviews` imports nothing this cut changed). Rerun once immediately (AGENTS.md: no measurement of recovery → one immediate retry): **`SMOKE_EXIT=0` — 243 routes + the probes: 260 ok, 9 skipped (no data), 0 failed.** Scratch cleanup reading (both runs): the same 6 stale `ZZ-SMOKE-*` rows as in 1d-1 to 1d-3 — materials PROBE / M25 / NTF, supplier S25, customer CJK, inbound batch IB25 — 5 still referenced; report-only, none deleted |
| 9 | picker probe on live | **`DATEPICK_PROBE_OWN_EXIT=0` — 147 passed, 0 failed** (§7). Its final run took four attempts, none of them a red verdict: ① a CDP timeout on the ledger page (24 checks in), ② a probe defect in the new 390 px section (the quote page draws no picker until "convert" is opened — fixed: such a page is recorded as "0 pickers"), ③ a CDP `Page.navigate` timeout 6 checks in; Supabase round-trips were then measured steady at ~0.8 s (5 of 5) before ④, which passed. Each failed attempt cleaned up after itself (read back: 0 `@test.local` accounts, no plan in `.ephemeral/`). Fault injections: `PROBE_FAULT=no-block` → exit 1, exactly the 8 blocking checks red; `PROBE_FAULT=no-validity` → the 6 native-form blocking checks red and the settings form really navigated with the bad date (§8 decision 14) |
| — | after the gate | files changed after the full gate: comment wording in `lib/dates.ts` and `app/purchasing/orders/[id]/PoPaymentTermsTable.tsx`, the probe script, the docs. Rerun: `npm run build` `BUILD_EXIT=0` (every static check + `next build`; lint error 41 · warning 83 = baseline), and individually `TSC2_OWN_EXIT=0`, `CURRENCY_OWN_EXIT=0`, `SWALLOW2_OWN_EXIT=0`, `I18N2_OWN_EXIT=0`, `DATEFMT_OWN_EXIT=0`, `DATEPATHS_OWN_EXIT=0`, `LINT_OWN_EXIT=0`. The gate reads no comment and no probe, so it was not rerun |

## §7 · The picker probe on live (`scripts/probe-date-pick1.mjs`)

**Nothing it does can write to live.** Every server-action POST (`Next-Action` header) is caught by CDP `Fetch` **in the browser**, its body read,
and the request failed there — not one byte reaches the server. GET filters and `router.push` navigations (read-only) go through. The only live
writes are the throwaway admin account and its grant, removed by the ephemeral plan.

Per module (one form each, plus a GET filter where the module has one): purchasing `/purchasing/orders/new` · sales `/sales/quotes/new` · inventory `/inbound/new` and `/inventory/reports/ledger` · processing `/operation/orders/new` (button-submitted) · finance `/finance/expenses/new` (not after today) · HR `/hr/reviews/cycles` (three boxes, button-submitted) · settings `/settings/change-history`. **Every month box (5):** `/finance/month-end`, `/finance/packs`, `/hr/attendance`, `/hr/leave/calendar`, `/hr/payroll/new`. **Every date-and-time box (4):** downtime start (FA-2026-0002), downtime end (FA-2026-0001, its open period), the new-task modal, the task page header. Out-of-range is tested where a form has a limit (finance: tomorrow is refused, its day greyed with the reason). The full list of checks, as the probe printed them:

- ✓ 采购 order_date · 敲 D/M/YYYY "3/9/2026" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 采购 order_date · 敲 DD/MM/YY "03/09/26" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 采购 order_date · 敲 DDMMYYYY "03092026" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 采购 order_date · 敲 ISO 粘贴 "2026-09-03" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 采购 order_date · 表单数据里是 ISO — 读 new FormData(form)
- ✓ 采购 order_date · 不存在的日子 "31/02/2026" 拦住原生提交 — 框下:"31/02/2026 is not a real date." · 浏览器的校验句与它相同 · 值仍是 2026-09-03 · 点了提交:没有发出任何请求
- ✓ 销售 quote_date · 敲 D/M/YYYY "3/9/2026" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 销售 quote_date · 敲 DD/MM/YY "03/09/26" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 销售 quote_date · 敲 DDMMYYYY "03092026" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 销售 quote_date · 敲 ISO 粘贴 "2026-09-03" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 销售 quote_date · 不存在的日子 "30/02/2026" 拦住原生提交 — 框下:"30/02/2026 is not a real date." · 浏览器的校验句与它相同 · 值仍是 2026-09-03 · 点了提交:没有发出任何请求
- ✓ 销售 valid_until · 敲 D/M/YYYY "3/9/2026" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 销售 valid_until · 敲 DD/MM/YY "03/09/26" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 销售 valid_until · 敲 DDMMYYYY "03092026" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 销售 valid_until · 敲 ISO 粘贴 "2026-09-03" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 库存 arrival_date · 敲 D/M/YYYY "3/9/2026" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 库存 arrival_date · 敲 DD/MM/YY "03/09/26" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 库存 arrival_date · 敲 DDMMYYYY "03092026" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 库存 arrival_date · 敲 ISO 粘贴 "2026-09-03" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 库存 arrival_date · 不存在的日子 "31/04/2026" 拦住原生提交 — 框下:"31/04/2026 is not a real date." · 浏览器的校验句与它相同 · 值仍是 2026-09-03 · 点了提交:没有发出任何请求
- ✓ 库存流水 from · 敲 D/M/YYYY "3/9/2026" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 库存流水 from · 敲 DD/MM/YY "03/09/26" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 库存流水 from · 敲 DDMMYYYY "03092026" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 库存流水 from · 敲 ISO 粘贴 "2026-09-03" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 库存流水 · GET 提交的 URL 是 ISO — ?from=2026-09-03&to=2026-09-30&material_id=&batch=
- ✓ 加工 scheduled · 敲 D/M/YYYY "3/9/2026" — 交出 2026-09-03 · 框里 "03/09/2026"
- ✓ 加工 scheduled · 敲 DD/MM/YY "03/09/26" — 交出 2026-09-03 · 框里 "03/09/2026"
- ✓ 加工 scheduled · 敲 DDMMYYYY "03092026" — 交出 2026-09-03 · 框里 "03/09/2026"
- ✓ 加工 scheduled · 敲 ISO 粘贴 "2026-09-03" — 交出 2026-09-03 · 框里 "03/09/2026"
- ✓ 加工 scheduled · 不存在的日子 "29/02/2026" 关掉按钮提交 — 框下:"29/02/2026 is not a real date." · 值仍是 2026-09-03 · 提交钮 disabled=true
- ✓ 财务 expense_date · 敲 D/M/YYYY "3/9/2026" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 财务 expense_date · 敲 DD/MM/YY "03/09/26" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 财务 expense_date · 敲 DDMMYYYY "03092026" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 财务 expense_date · 敲 ISO 粘贴 "2026-09-03" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 财务 expense_date · 不存在的日子 "31/06/2026" 拦住原生提交 — 框下:"31/06/2026 is not a real date." · 浏览器的校验句与它相同 · 值仍是 2026-09-03 · 点了提交:没有发出任何请求
- ✓ 财务 expense_date · 范围外(明天) "06/10/2026" 拦住原生提交 — 框下:"06/10/2026 is in the future. Today is 05/10/2026." · 浏览器的校验句与它相同 · 值仍是 2026-09-03 · 点了提交:没有发出任何请求
- ✓ 财务 expense_date · 月历里明天点不了、原因写着 — {"tomorrowDisabled":"not in this month","title":null,"reason":"Future dates can’t be chosen. Today is 05/10/2026."}
- ✓ 键盘 · 打开时焦点落在选中的那一天 — 焦点 2026-09-03
- ✓ 键盘 · → +1 天 · ↓ +7 天 · ← −1 · ↑ −7 — 2026-09-04 · 2026-09-11 · 2026-09-10 · 2026-09-03
- ✓ 键盘 · PageUp 上一个月 · PageDown 回来 — 2026-08-03 · 2026-09-03
- ✓ 键盘 · Home 到周一 · End 到周日 — 2026-08-31 · 2026-09-06
- ✓ 键盘 · Enter 选中那一天、月历关上、焦点回到框里 — 选中 2026-09-05 → 交出 2026-09-05 · 月历关了 true · 焦点回框 true
- ✓ 键盘 · Esc 关上月历、值不变、焦点回框 — Esc
- ✓ 月历 · 英文:周一开头,1 号落在它那一列 — October 2026 · Mon Tue Wed Thu Fri Sat Sun · 1 号在第 4 列
- ✓ 月历 · 英文月名 — October 2026
- ✓ 月历 · 中文:周一开头,星期名是中文 — 2026年10月 · 一 二 三 四 五 六 日
- ✓ 月历 · 中文月名(2026年10月 这样) — 2026年10月
- ✓ 中文界面 · 敲的格式仍是 DD/MM/YYYY — 框里 "03/09/2026" · 交出 2026-09-03
- ✓ 中文界面 · 不存在的日子用中文说 — 31/02/2026 不是一个存在的日子。
- ✓ 人事 轮次框 #1 · 敲 D/M/YYYY "3/9/2026" — 交出 2026-09-03 · 框里 "03/09/2026"
- ✓ 人事 轮次框 #1 · 敲 DD/MM/YY "03/09/26" — 交出 2026-09-03 · 框里 "03/09/2026"
- ✓ 人事 轮次框 #1 · 敲 DDMMYYYY "03092026" — 交出 2026-09-03 · 框里 "03/09/2026"
- ✓ 人事 轮次框 #1 · 敲 ISO 粘贴 "2026-09-03" — 交出 2026-09-03 · 框里 "03/09/2026"
- ✓ 人事 轮次框 #2 · 敲 D/M/YYYY "3/9/2026" — 交出 2026-09-03 · 框里 "03/09/2026"
- ✓ 人事 轮次框 #2 · 敲 DD/MM/YY "03/09/26" — 交出 2026-09-03 · 框里 "03/09/2026"
- ✓ 人事 轮次框 #2 · 敲 DDMMYYYY "03092026" — 交出 2026-09-03 · 框里 "03/09/2026"
- ✓ 人事 轮次框 #2 · 敲 ISO 粘贴 "2026-09-03" — 交出 2026-09-03 · 框里 "03/09/2026"
- ✓ 人事 轮次框 #3 · 敲 D/M/YYYY "3/9/2026" — 交出 2026-09-03 · 框里 "03/09/2026"
- ✓ 人事 轮次框 #3 · 敲 DD/MM/YY "03/09/26" — 交出 2026-09-03 · 框里 "03/09/2026"
- ✓ 人事 轮次框 #3 · 敲 DDMMYYYY "03092026" — 交出 2026-09-03 · 框里 "03/09/2026"
- ✓ 人事 轮次框 #3 · 敲 ISO 粘贴 "2026-09-03" — 交出 2026-09-03 · 框里 "03/09/2026"
- ✓ 人事 轮次 start · 不存在的日子 "31/09/2026" 关掉按钮提交 — 框下:"31/09/2026 is not a real date." · 值仍是 2026-09-03 · 提交钮 disabled=true
- ✓ 设置 from · 敲 D/M/YYYY "3/9/2026" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 设置 from · 敲 DD/MM/YY "03/09/26" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 设置 from · 敲 DDMMYYYY "03092026" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 设置 from · 敲 ISO 粘贴 "2026-09-03" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 设置 to · 不存在的日子 "32/01/2026" 拦住原生提交 — 框下:"32/01/2026 is not a real date." · 浏览器的校验句与它相同 · 值仍是  · 点了提交:没有发出任何请求
- ✓ 设置 · GET 提交的 URL 是 ISO — ?from=2026-09-03&to=2026-09-30&area=&type=&record=&who=
- ✓ 月份 /finance/month-end · 敲 M/YYYY "9/2026" — 交出 2026-09 · 隐藏 2026-09 · 框里 "09/2026"
- ✓ 月份 /finance/month-end · 敲 MM/YY "09/26" — 交出 2026-09 · 隐藏 2026-09 · 框里 "09/2026"
- ✓ 月份 /finance/month-end · 敲 MMYYYY "092026" — 交出 2026-09 · 隐藏 2026-09 · 框里 "09/2026"
- ✓ 月份 /finance/month-end · 敲 ISO 粘贴 "2026-09" — 交出 2026-09 · 隐藏 2026-09 · 框里 "09/2026"
- ✓ 月份 /finance/month-end · 不存在的月份 "13/2026" 说出来、值不变 — "13/2026 is not a real month." · 值 2026-09
- ✓ 月份 /finance/month-end · 不存在的月份拦住 GET 提交 — 表单校验 false
- ✓ 月份 /finance/month-end · GET 提交 month=2026-09 — ?month=2026-09
- ✓ 月份 /finance/packs · 敲 M/YYYY "9/2026" — 交出 2026-09 · 隐藏 2026-09 · 框里 "09/2026"
- ✓ 月份 /finance/packs · 敲 MM/YY "09/26" — 交出 2026-09 · 隐藏 2026-09 · 框里 "09/2026"
- ✓ 月份 /finance/packs · 敲 MMYYYY "092026" — 交出 2026-09 · 隐藏 2026-09 · 框里 "09/2026"
- ✓ 月份 /finance/packs · 敲 ISO 粘贴 "2026-09" — 交出 2026-09 · 隐藏 2026-09 · 框里 "09/2026"
- ✓ 月份 /finance/packs · 不存在的月份 "13/2026" 说出来、值不变 — "13/2026 is not a real month." · 值 2026-09
- ✓ 月份 /finance/packs · 选中另一个月就跳到 ?month=2026-08 — ?month=2026-08
- ✓ 月份 /hr/attendance · 敲 M/YYYY "9/2026" — 交出 2026-09 · 隐藏 null · 框里 "09/2026"
- ✓ 月份 /hr/attendance · 敲 MM/YY "09/26" — 交出 2026-09 · 隐藏 null · 框里 "09/2026"
- ✓ 月份 /hr/attendance · 敲 MMYYYY "092026" — 交出 2026-09 · 隐藏 null · 框里 "09/2026"
- ✓ 月份 /hr/attendance · 敲 ISO 粘贴 "2026-09" — 交出 2026-09 · 隐藏 null · 框里 "09/2026"
- ✓ 月份 /hr/attendance · 不存在的月份 "13/2026" 说出来、值不变 — "13/2026 is not a real month." · 值 2026-09
- ✓ 月份 /hr/attendance · 不存在的月份关掉"开月"钮 — disabled=true
- ✓ 月份 /hr/attendance · 提交出去的是 2026-09(被拦在浏览器里) — ["2026-09-01"]
- ✓ 月份 /hr/leave/calendar · 敲 M/YYYY "9/2026" — 交出 2026-09 · 隐藏 2026-09 · 框里 "09/2026"
- ✓ 月份 /hr/leave/calendar · 敲 MM/YY "09/26" — 交出 2026-09 · 隐藏 2026-09 · 框里 "09/2026"
- ✓ 月份 /hr/leave/calendar · 敲 MMYYYY "092026" — 交出 2026-09 · 隐藏 2026-09 · 框里 "09/2026"
- ✓ 月份 /hr/leave/calendar · 敲 ISO 粘贴 "2026-09" — 交出 2026-09 · 隐藏 2026-09 · 框里 "09/2026"
- ✓ 月份 /hr/leave/calendar · 不存在的月份 "13/2026" 说出来、值不变 — "13/2026 is not a real month." · 值 2026-09
- ✓ 月份 /hr/leave/calendar · GET 提交 month=2026-09 — ?month=2026-09
- ✓ 月份 /hr/payroll/new · 敲 M/YYYY "9/2026" — 交出 2026-09 · 隐藏 2026-09 · 框里 "09/2026"
- ✓ 月份 /hr/payroll/new · 敲 MM/YY "09/26" — 交出 2026-09 · 隐藏 2026-09 · 框里 "09/2026"
- ✓ 月份 /hr/payroll/new · 敲 MMYYYY "092026" — 交出 2026-09 · 隐藏 2026-09 · 框里 "09/2026"
- ✓ 月份 /hr/payroll/new · 敲 ISO 粘贴 "2026-09" — 交出 2026-09 · 隐藏 2026-09 · 框里 "09/2026"
- ✓ 月份 /hr/payroll/new · 不存在的月份 "13/2026" 说出来、值不变 — "13/2026 is not a real month." · 值 2026-09
- ✓ 月份 /hr/payroll/new · 不存在的月份拦住原生提交 — 表单校验 false
- ✓ 月份 /hr/payroll/new · 表单数据里是 2026-09 — new FormData(form)
- ✓ 工资 payment_date · 敲 D/M/YYYY "3/9/2026" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 工资 payment_date · 敲 DD/MM/YY "03/09/26" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 工资 payment_date · 敲 DDMMYYYY "03092026" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 工资 payment_date · 敲 ISO 粘贴 "2026-09-03" — 交出 2026-09-03 · 隐藏输入 2026-09-03 · 框里 "03/09/2026"
- ✓ 日期时间 停机开始 · 敲 D/M/YYYY "3/9/2026" + 14:30 — 交出 2026-09-03T14:30+08:00
- ✓ 日期时间 停机开始 · 敲 DD/MM/YY "03/09/26" + 14:30 — 交出 2026-09-03T14:30+08:00
- ✓ 日期时间 停机开始 · 敲 DDMMYYYY "03092026" + 14:30 — 交出 2026-09-03T14:30+08:00
- ✓ 日期时间 停机开始 · 敲 ISO 粘贴 "2026-09-03" + 14:30 — 交出 2026-09-03T14:30+08:00
- ✓ 日期时间 停机开始 · 时刻敲 HHMM "1430" — 交出 2026-09-03T14:30+08:00
- ✓ 日期时间 停机开始 · 不存在的日子说出来、值不变 — "31/02/2026 is not a real date." · 值 2026-09-03T14:30+08:00
- ✓ 日期时间 停机开始 · 不存在的时刻 25:00 说出来、值不变 — "25:00 is not a real time." · 值 2026-09-03T14:30+08:00
- ✓ 日期时间 停机开始 · 不存在的日子关掉保存钮 — disabled=true
- ✓ 日期时间 停机开始 · 提交出去的是新加坡 14:30(+08:00),被拦在浏览器里 — [{"assetId":"c20e3ba1-67a2-48dd-a884-b2f826dcb1ad","startedAt":"2026-09-03T14:30+08:00","reason":"ZZ DATE-PICK-1 probe (never sent)","notes":""}]
- ✓ 日期时间 停机结束 · 敲 D/M/YYYY "3/9/2026" + 14:30 — 交出 2026-09-03T14:30+08:00
- ✓ 日期时间 停机结束 · 敲 DD/MM/YY "03/09/26" + 14:30 — 交出 2026-09-03T14:30+08:00
- ✓ 日期时间 停机结束 · 敲 DDMMYYYY "03092026" + 14:30 — 交出 2026-09-03T14:30+08:00
- ✓ 日期时间 停机结束 · 敲 ISO 粘贴 "2026-09-03" + 14:30 — 交出 2026-09-03T14:30+08:00
- ✓ 日期时间 停机结束 · 时刻敲 HHMM "1430" — 交出 2026-09-03T14:30+08:00
- ✓ 日期时间 停机结束 · 不存在的日子说出来、值不变 — "31/02/2026 is not a real date." · 值 2026-09-03T14:30+08:00
- ✓ 日期时间 停机结束 · 不存在的时刻 25:00 说出来、值不变 — "25:00 is not a real time." · 值 2026-09-03T14:30+08:00
- ✓ 日期时间 停机结束 · 提交出去的是新加坡 14:30(+08:00),被拦在浏览器里 — [{"assetId":"a1560d88-de19-40fe-b78b-3bfa4079762b","downtimeId":"db2399b4-31aa-4a8b-b191-73c04de3bdbc","endedAt":"2026-09-03T14:30+08:00"}]
- ✓ 日期时间 新任务提醒 · 敲 D/M/YYYY "3/9/2026" + 14:30 — 交出 2026-09-03T14:30+08:00
- ✓ 日期时间 新任务提醒 · 敲 DD/MM/YY "03/09/26" + 14:30 — 交出 2026-09-03T14:30+08:00
- ✓ 日期时间 新任务提醒 · 敲 DDMMYYYY "03092026" + 14:30 — 交出 2026-09-03T14:30+08:00
- ✓ 日期时间 新任务提醒 · 敲 ISO 粘贴 "2026-09-03" + 14:30 — 交出 2026-09-03T14:30+08:00
- ✓ 日期时间 新任务提醒 · 时刻敲 HHMM "1430" — 交出 2026-09-03T14:30+08:00
- ✓ 日期时间 新任务提醒 · 不存在的日子说出来、值不变 — "31/02/2026 is not a real date." · 值 2026-09-03T14:30+08:00
- ✓ 日期时间 新任务提醒 · 不存在的时刻 25:00 说出来、值不变 — "25:00 is not a real time." · 值 2026-09-03T14:30+08:00
- ✓ 日期时间 新任务提醒 · 月历里按 Esc 只关月历、弹窗还在 — Esc
- ✓ 日期时间 新任务提醒 · 提交出去的是新加坡 14:30 = 06:30Z,被拦在浏览器里 — [{"title":"ZZ DATE-PICK-1 probe (never sent)","description":null,"status":"todo","priority":"medium","task_type":"personal","due_date":null,"reminder_at":"2026-09-03T06:30:00.000Z","tags":[]}]
- ✓ 日期时间 任务页提醒 · 敲 D/M/YYYY "3/9/2026" + 14:30 — 交出 2026-09-03T14:30+08:00
- ✓ 日期时间 任务页提醒 · 敲 DD/MM/YY "03/09/26" + 14:30 — 交出 2026-09-03T14:30+08:00
- ✓ 日期时间 任务页提醒 · 敲 DDMMYYYY "03092026" + 14:30 — 交出 2026-09-03T14:30+08:00
- ✓ 日期时间 任务页提醒 · 敲 ISO 粘贴 "2026-09-03" + 14:30 — 交出 2026-09-03T14:30+08:00
- ✓ 日期时间 任务页提醒 · 时刻敲 HHMM "1430" — 交出 2026-09-03T14:30+08:00
- ✓ 日期时间 任务页提醒 · 不存在的日子说出来、值不变 — "31/02/2026 is not a real date." · 值 2026-09-03T14:30+08:00
- ✓ 日期时间 任务页提醒 · 不存在的时刻 25:00 说出来、值不变 — "25:00 is not a real time." · 值 2026-09-03T14:30+08:00
- ✓ 日期时间 任务页提醒 · 提交出去的是新加坡 14:30 = 06:30Z,被拦在浏览器里 — ["233b92e2-1427-4a71-8ad8-6cd2c96feee5",{"title":"1123","description":null,"status":"todo","priority":"medium","due_date":null,"reminder_at":"2026-09-03T06:30:00.000Z","tags":[]}]
- ✓ 390px · 日期框固定宽、32px 高 — 宽 156px · 高 32px
- ✓ 390px · 月历整个在屏幕里、整页不横向溢出 — {"l":32,"r":298,"vw":390,"sw":390}
- ✓ 390px /operation/processing/new · 日期框没有把整页撑得比原生控件更宽 — 溢出 177px(日期框)· 177px(换回 1 个原生控件)· 换回来 177px
- ✓ 390px /finance/freight/new · 日期框没有把整页撑得比原生控件更宽 — 溢出 27px(日期框)· 27px(换回 1 个原生控件)· 换回来 27px
- ✓ 390px /sales/orders/new · 日期框没有把整页撑得比原生控件更宽 — 溢出 8px(日期框)· 8px(换回 1 个原生控件)· 换回来 8px
- ✓ 390px /sales/quotes/896c59df-89fc-486f-b50e-d290803cf0bb · 默认画面里没有日期框,溢出与它无关 溢出 0px · 日期框 0 个
- ✓ 390px /finance/month-end · 日期框没有把整页撑得比原生控件更宽 — 溢出 6px(日期框)· 6px(换回 1 个原生控件)· 换回来 6px
- ✓ ★ 整个探针期间没有一个 server action 到达服务端(全部在浏览器里掐掉) — 拦下 5 个

### §7.1 · Before and after

Read as `postgres` with `db/scripts/2026-10-05-datepick1-live-readings.sql` (one row per public base table: row count + every-row digest; plus
`change_log`, accounts, approvals); reconciliation as tim@ (cfo) with `db/scripts/2026-10-05-at1d3-live-recon.sql`.

| reading | before (09:56:07 CST) | after (11:59:18 CST) |
|---|---|---|
| accounts | 7 · 0 disabled · 0 throwaway · 0 grants without an account | **same** |
| approvals | ON | **ON** |
| every public base table (241, count + every-row digest) | as recorded | **240 same, row for row**; 1 differs: `cod_verification_failures` (1 row → 1 row, rotated) |
| pending documents | unchanged | **unchanged** — every table holding them has the same every-row digest, so each still has its eligible approver |
| AP recon | 416,988.32 / 376,404.42, unexplained **0.00**, agrees | **same** |
| AR recon | 57,545.87 / 43,002.12, unexplained **0.00**, agrees | **same** |
| change_log | 5,074 rows, max seq 6,060 | 5,495, max seq 6,545 (**+421**, explained below) |

**The +421 change-log rows (seq > 6,060), grouped by table and operation:** every row key is a create/delete pair of a throwaway — the two smoke
runs' all-codes roles (roles 2 + 2, role_permissions 144 + 144) and contract probes (contracts 4 + 4 and the six term tables, 14 + 14), the
throwaway accounts' grants (user_roles 18 + 18), and the survey and smoke seeded reviewers and reviews (employees 16 + 16, performance_reviews
7 inserts + 7 updates + 7 deletes) — **except the `cod_verification_failures` rotation** (2 deletes + 2 inserts, the smoke's COD check, one per
run), the only net change and the only table digest that moved. The probe itself wrote nothing but its account and grant: every server action it
triggered was failed in the browser. Pre-existing documents: untouched (their tables' digests are unchanged).

## §8 · Decisions taken without asking

1. **An invalid date is blocked by three mechanisms, chosen per site, rather than one generic DOM blocker.** The picker never hands an invalid value
   on; native forms are stopped by `setCustomValidity`; button-submitted panels are wired with `onInvalidChange` into the buttons that send the date
   (a generic "disable every button near me" would also disable Cancel, which AGENTS.md forbids). Filter toolbars need nothing — the invalid value
   never reaches the URL (and clearing it to `''` instead would have silently unfiltered the list, DATE-1's ARM 2).
2. **Date-and-time posts `YYYY-MM-DDTHH:MM+08:00` — Singapore time with its offset — instead of a naive local string.** The offset is computed
   from `Asia/Singapore` by `Intl`, not written as a literal. What the servers now receive: the downtime actions get that string and write it to
   `timestamptz`; the task forms still convert with `new Date(…).toISOString()` and send UTC (`2026-09-03T06:30:00.000Z` for 14:30 SGT — probe §7).
   **An agent's claim that downtime used to be stored 8 h late was measured false:** the database's `TimeZone` is `Asia/Singapore` (as `postgres`:
   `current_setting('TimeZone')` = `Asia/Singapore`, database setting `TimeZone=Asia/Singapore`), so a naive string was already read as Singapore
   time; only the two task reminders depended on the browser's time zone.
3. **Typing commits as you go only when the entry is complete** (four-digit year, eight digits, ISO); a two-digit year waits for leaving the box or
   Enter — otherwise `1/1/20` would commit 2020 on the way to `1/1/2026` and a toolbar would navigate twice.
4. **The error under the box appears on leaving it — or at once when a complete entry is impossible / out of range**, because a button panel has
   already greyed its button and a grey button with no reason is the failure DBLOCK-1 ruled out.
5. **`DateFilterInput` and `ContractDateInput` were deleted; `PaymentDateInput` was kept** as the payment-date rule's one home (required, not after
   today). The first two existed only to keep the native count from growing.
6. **Fixed widths: date 9.75rem (156px), month 7.75rem, time 4.75rem**, sized for `00/00/0000` at the 16px phone font plus the calendar button.
   Sites whose old box was `w-full` / `block` keep their own line with `className="flex"`; every box is narrower than a full-width one now (the
   ruling: a fixed width).
7. **Month names are new messages (`datePicker.month.1…12`, en + zh); weekday names reuse `calendar.dow`** (MonthGrid's keys) — so check-i18n
   enumerates both, rather than taking names from `Intl` that no check can see.
8. **The "future date" wording is used when `max` equals today in Singapore; four pickers' `max` moved from the browser's today to
   `businessToday()`** (inbound and output assay, `/me` expense claim, customer chase) so the limit is the same day the server refuses "future" on.
   The two `today()` helpers that became unused (ChasePanel, `/me`) were deleted; with TaskHeader's `toLocalInput` and TaskModal's
   `toLocalDatetime` that is 4 hand-rolled browser-time-zone date builders fewer (`scripts/date-format-baseline.json` tightened, note dated).
9. **Draft restore is fixed centrally** (`lib/useFormDraft.ts` fires `datepicker:restore` after rewriting a picker's hidden input; the picker
   re-reads it, updates the box and hands the value on), and a calendar pick raises the bubbling `input` event the draft listens for. One agent had
   patched `NewExpenseForm` locally (remount with keys); I removed that patch so there is one mechanism.
10. **The picker honours `form.reset()` and keeps Esc to itself** (stops propagation, so the task modal does not close with the calendar).
11. **Two pre-existing defects found while converting were fixed** (`DATEPICK1-DISPLAY-DATE-IN-EDIT-STATE`): the licence and commission edit forms
    put `formatDate` output (DD/MM/YYYY since AT-1a) into state; saving untouched dates would have sent `05/10/2026`, which live reads as 10 May
    (`DateStyle` = `ISO, MDY`, measured). No live row was affected (licences 1 row and 0 writes since logging began; commission agreements 0 rows).
12. **The probe proves what is posted by catching every server-action POST in the browser and failing it there**, instead of a rolled-back
    transaction — the brief's "rolled-back or probe-created" option, taken one step further: nothing reaches the server at all. GET filters and
    `router.push` navigations were really submitted (read-only).
13. **To reach the task header's reminder box, the probe removes the `fieldset disabled` in that page's DOM.** The throwaway admin is not a
    participant, so the edit link is (correctly) a disabled, explained control; the server would refuse a save anyway, and the submit is caught
    in the browser.
14. **The probe's two fault injections:** `PROBE_FAULT=no-block` (the verdict side: the 8 blocking checks must go red — they did) and
    `PROBE_FAULT=no-validity` (the mechanism side: `setCustomValidity` replaced by a no-op in the page — the 6 native-form checks went red and the
    settings GET form actually navigated with the bad date, after which the probe stopped, exit 2; the 2 button-panel checks stayed green, as
    they should, being a different mechanism).
15. **Comment blanking moved to `scripts/lib/blank-comments.mjs`** so `check-date-data-paths`' text path strips comments too (it first counted a
    `<DatePicker>` mentioned in a JSX comment in PayrollGrid — 137 vs 136 — and said so rather than passing).
16. **A new readings script, `db/scripts/2026-10-05-datepick1-live-readings.sql`,** returns one row per public base table (count + every-row
    digest) through `query_to_xml`, so the before/after comparison is per table, not one digest.
17. **PayrollGrid's read-only tint (Tim's R10/Q9) is kept** through a descendant selector on the picker (`[&_input:read-only]:bg-gray-100`).
18. **Two look changes accepted rather than re-styled:** the receiving page (`/inbound/receive`) is built on 48px touch rows and the picker is 32px
    by ruling R3; the PO page's inline expected-date box lost its amber dashed "estimate" border (the read-only text keeps it).
19. **The conversion was split across five parallel agents with one written spec**, on disjoint file sets; I converted the wrappers and their
    callers myself and reviewed the riskier diffs.
20. **The claims decision list wires validity per row** (only that row's Approve; Reject sends no date).
21. **"Clear" appears only on optional boxes; "Today" / "This month" is disabled when today is outside min/max.**
22. **A pasted full ISO timestamp is accepted and its date taken; separators `/ . -` are accepted** — harmless widenings of Q37's list.
23. **The probe uses FA-2026-0001 (open downtime → the end field), FA-2026-0002 (no open downtime → the start field) and TASK-2026-0181** —
    the only way to render the two downtime fields without writing.
24. **The layout survey's route set was computed from the import graph (92 routes)**; 3 have no live record to open (contracts 0, payment
    requests 0, commission agreements 0 rows) and were not measured — each one's date component is measured on a sibling route
    (`/contracts/new`, `/finance/payments/new`, `/sales/commissions/new`). `/hr/payroll/[id]/edit` redirects (the only period is posted); its grid
    is measured on `/hr/payroll/new`.
25. **The survey's 390 px pass returned HTTP 500 once for `/hr/payroll/new`.** Not reproducible: a fresh `next dev` with an admin session gave 200
    twice with no server error, and a single-route survey pass measured it clean (`SURVEY390B_EXIT=0`). Recorded, not chased further.
26. **The 5 pages that overflow at 390 px were compared with the native control on the same page** (§7) because this cut has no pre-change survey
    reading: the pre-change worktree's dev server would not start with a symlinked `node_modules` (the survey's self-test refused it).
27. **The unused `ShippingSection` warning that disappeared from the lint count** was not touched by this cut; the lint baseline was tightened to
    the measured state (83 warnings).

## §9 · Known issues and queue

- `docs/known-issues.md`: new `DATEPICK1-DISPLAY-DATE-IN-EDIT-STATE` (found and fixed — §8 decision 11) and `DATEPICK1-SMALL-GAPS` (five small
  things measured while converting, not changed here).
- `docs/forward-queue.md`: item 32 (1d-3's window closed); UNBLOCK-1 gains `AT1D3-ME-PAYSLIP-CURRENCY-NEEDS-HR-VIEW` after the privacy group;
  item 33 and the HISTORY-family entry mark **DATE-PICK-1 ✅ (`v1.4.34`)**; the "DATE-1 的选择器那一半" row is ✅; **UNBLOCK-1 is next**.
- No broken window: no migration.
