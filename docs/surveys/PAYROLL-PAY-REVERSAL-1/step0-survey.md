# PAYROLL-PAY-REVERSAL-1 — Step 0 survey (2026-10-22)

Started from `5709a2c06aea49d54105b7ffbb4bba56fa316bf7` (HEAD = origin/main = ls-remote, tree clean). Live readings taken as `postgres`
(`rolbypassrls = true`) over psql to the pooler, base tables unless named, 2026-10-22 ~09:55 CST.

## Facts measured

### A · payroll payments
- **One pay call = one journal entry.** `pay_payroll_lines` posts one entry per call: one 2300 debit + one bank credit **per employee**
  (`db/functions/pay_payroll_lines.sql:96-108`), then stamps `paid_at = now()` and `paid_journal_entry_id` on **every** line id passed, including
  net-zero lines that got no bank line (`:111-113`). `pay_payroll_cpf` / `pay_payroll_deductions` post one entry per period and stamp
  `cpf_paid_at` / `deductions_paid_at` with the **payment date** and the entry id (`pay_payroll_cpf.sql:69-80`, `pay_payroll_deductions.sql:68-78`).
  All three: date required, not in the future, gate `module.finance.edit OR module.hr.edit`, refuse while a `reversal` payroll request is open.
- **The period lock on paid periods:** `unpost_payroll_period_internal` refuses `PAYROLL_LINES_PAID` / `PAYROLL_CPF_PAID` / `PAYROLL_DEDUCTIONS_PAID`
  (`:34-42`). `payroll_period_frozen` answers `requested` for **any** open request (`:8-13`). One open request per period
  (`db/tables/payroll_requests.sql:106-108`). Kinds today: `post`, `reversal` (`:63`).
- **Generic reversal route:** `journal_entry_reversal_route.sql:55-60` sends payroll **payment** entries (and their reversals) to `'request'` —
  i.e. today a CFO-approved generic journal reversal request **can** reverse them and leaves the stamps on. Live: JE-2026-0018 / 0019 / 0020
  route `request`; JE-2026-0017 (the posting) `source_path`. Open journal requests on payroll entries: 0.
- **`reverse_journal_entry_internal` refuses a date before the original** (`REVERSAL_BEFORE_ORIGINAL`, `:37-39`).
- **Approvals for payroll:** `decide_payroll_request` = level 2 directly (`:55`), gate `{module.hr.view, data.view_pay}`; raiser `module.hr.edit`
  (`submit_payroll_request.sql:31`). Holders (live `role_permissions`): `cfo` has hr.view + view_pay (decides); `finance` has hr.edit (raises);
  `cfo` does **not** hold hr.edit or finance.edit. Payment-reversal precedent: `docs/approvals.md` §3j/§3k — CFO every one, date given **at execution**.
- **Bank reconciliation:** `match_bank_line` refuses a reversed entry's line (`JL_ENTRY_REVERSED`, `:57-59`). **No reversal path in the repo checks
  `bank_line_matches`** (`grep -l bank_line_matches db/functions/*.sql` → only match / unmatch / reconciliation rows / two trail functions). So
  reversing any matched payment today leaves the statement line matched to a reversed entry. `unmatch_bank_line` refuses once the statement is
  reconciled (`STATEMENT_RECONCILED`).
- **Live:** one period, PAY-2026-0001, posted, 1 line paid by JE-0018, CPF and deductions paid 2026-08-04 (JE-0019 / 0020); 0 of their lines
  matched to a bank line; `locked_before = 2026-08-01` (August open).
- Readers of the stamps outside the pay functions: `app/finance/payroll-payments/{page,PayPanel}.tsx`, `payroll_periods_masked`, `payroll_lines_masked`,
  `payroll_period_lookup`, `hr_alerts` (CPF-due alert reads `cpf_paid_at IS NULL`, `hr_alerts.sql:198`).

### B · leave
- `leave_balance_internal` gives every non-annual quota type its whole `default_days_per_year` for the calendar year of `p_as_of`, no service test
  (`:106-120`). Submit and approval call it with the leave **start date** as `p_as_of` (`submit_leave_request.sql:101`, `decide_leave_request.sql:57`).
- Annual leave already starts from the hire month (`accrued_annual_leave_detail.sql:74-77`).
- Live leave types with a quota (13 types, 11 non-annual with `default_days_per_year`): childcare 6 · compassionate 3 · examination 2 ·
  extended_childcare 2 · hospitalisation 60 · infant_care 12 · marriage 3 · maternity 112 · paternity 28 · shared_parental 70 · sick 14; unpaid none.
  `leave_types.gender_restriction` exists (maternity female, paternity male); **`employees` has no gender column**.
- Live employees: 6 `EMP-` records, hire dates 2026-08-01, 2026-08-11 and four on 2026-09-01 (the four GHOST-GRANTS C-1 ② placeholders —
  inferred from the date, not from a flag). Every one is under 3 months of service today. **Non-annual leave requests on live: 0.**
- `/me` asks `leave_balance` for `'annual'` only (`app/me/page.tsx:158`); the panel is `app/me/MyLeavePanel.tsx` (213 lines).
- Already registered next door: `LEAVEBAL1-HOSPITALISATION-INCLUDES-SICK` (`docs/known-issues.md:246`, Tim Q4: separate cut).

## Assertions in the brief I measured
- "journal_entry_reversal_route.sql:55-63" — the payroll branch is `:55-60`, `RETURN 'request'` at `:61`. True in substance.
- "four live employee records carry placeholder hire dates" — consistent (four on 2026-09-01); not flagged in data, so inferred.
- Measured false at Step 0: zero. **Found during Step 1 (one):** the brief's "docs/known-issues.md … the /me leave-balance entry" does not exist; the item lived only in `docs/forward-queue.md` (LEAVE-BAL-1 Q15).
