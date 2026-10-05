# UNBLOCK-1 Step 0 — hand-back (2026-10-05)

**Contents:**
- **Step 1 (DATE-PICK-1 close-out):** results in §1.
- **Q-f:** answered and done (§2).
- **Step 0 grilling:** §3–§9.

**STOP GATE:** no code, no migration, no live write. Waiting on Tim's answers to Q1–Q26 (§4).

**Opening checks:**
- **Step 1 session (≈ 14:55 CST):** `b1a9c0cd…` everywhere; tree clean apart from Tim's PDF.
- **This block (15:03 CST):** HEAD = origin/main = `ls-remote` = `8d8cf841157d12a3c7c8370bbe4c580c0652f7cf`; tree clean apart from Tim's untracked `docs/Data capture and ERP integreation.pdf` (not touched).

**Live state (read-only as `postgres`, 15:00:18 CST):** 7 accounts, 0 disabled, approvals `true / finance / cfo / 1000`.

## §1 · Step 1 results, item by item

### 1.1 — No migration, therefore no broken window ✅ (written)

`docs/forward-queue.md` item 33 already said "没有迁移,所以没有破窗"; this close-out added the deployment line in the format of items 29–32,
with the measurement behind it: `git show --stat b1a9c0cd` touches **0** files under `db/migrations/` (the only `db/` file is the read-only
`db/scripts/2026-10-05-datepick1-live-readings.sql`); `db/migration-windows.tsv`'s last row is still 1d-3's `2026-10-05T01:14:31+0800`;
push time `b1a9c0cd … {2026-10-05 14:48:30 +0800}: update by push` (`git reflog show --date=iso refs/remotes/origin/main`).
Deployment itself is Tim's reading on Vercel (relayed, not measured here).

### 1.2 — Known issues registered ✅ (written)

- **`DATEPICK1-390-FIVE-PAGES-OVERFLOW`** — each page named with its overflow and the survey's named culprit:
  `/operation/processing/new` +177 (a `<select>`) · `/finance/freight/new` +27 (a `<select>`; same as `FREIGHT-NEW-PHONE-OVERFLOW`) ·
  `/sales/orders/new` +8 (a `<select>`) · `/sales/quotes/[id]` +8 (the line editor's material `<select>`; same as `AT1B2-QUOTE-PAGE-390-OVERFLOW`) ·
  `/finance/month-end` +6 (a table cell — first registration). Source: the prior session's survey log (`SURVEY390_EXIT=1`, 87 routes measured).
- **`DATEPICK1-PAYROLL-NEW-ONE-500`** — what is known (document status 500 read by CDP at route 46/89, 242 s; the same row still printed
  `ovf=0 clip=0`, so that reading is of a 500 document; 1280 px pass no ≥ 400; fresh `next dev` 200 · 200 with no server error; single-route
  390 px pass `SURVEY390B_EXIT=0`) and what is not (the server-side cause; no stack was captured; link to the cut neither proven nor excluded).

### 1.3 — Read-only verification of what the DATE-PICK-1 report did not mention

| | item | verdict | evidence |
|---|---|---|---|
| a | four typing forms | ✅ | `lib/dates.ts:436-441` — `iso = /^(\d{4})-(\d{1,2})-(\d{1,2})(?:[T ]\S*)?$/` (pasted ISO, a timestamp too) · `packed = /^(\d{2})(\d{2})(\d{4})$/` (DDMMYYYY) · `sep = /^(\d{1,2})[/.-](\d{1,2})[/.-](\d{2}\|\d{4})$/` (D/M/YYYY and DD/MM/YY); `:427-429` `fullYear`: `y.length === 2 ? 2000 + Number(y)` (YY = 20YY). Probe arm (`docs/handbacks/DATE-PICK-1.md:267-270`): `✓ 采购 order_date · 敲 D/M/YYYY "3/9/2026" — 交出 2026-09-03` · `敲 DD/MM/YY "03/09/26" — 交出 2026-09-03` · `敲 DDMMYYYY "03092026"` · `敲 ISO 粘贴 "2026-09-03"` — all `框里 "03/09/2026"` |
| b | Monday first; Chinese month and weekday names; typed format stays DD/MM/YYYY | ✅ | `app/components/ui/date-picker.tsx:484` `const lead = mondayIndex(\`${ym}-01\`)`; `:485` `heads = [...DOW_KEYS.slice(1), DOW_KEYS[0]].map((d) => t('calendar.dow.' + d))` (Mon…Sun); `lib/dates.ts:407-409` `mondayIndex = (getUTCDay() + 6) % 7`. `messages/zh.ts:4568-4571` `monthYear: '{year}年{month}'`, `month: { 1: '1月' … 12: '12月' }`; `:4605` `dow: { 0: '日', 1: '一' … 6: '六' }`. Typed format is locale-free: `lib/dates.ts:474-478` `formatTypedDate` "两种语言同一个样子". Probe (`DATE-PICK-1.md:310-314`): `October 2026 · Mon Tue Wed Thu Fri Sat Sun · 1 号在第 4 列` · `2026年10月 · 一 二 三 四 五 六 日` · `中文界面 · 敲的格式仍是 DD/MM/YYYY — 框里 "03/09/2026"` |
| c | days outside min/max disabled, reason shown | ✅ | `date-picker.tsx:486` `out = (d) => (lo && d < lo) \|\| (hi && d > hi)`; `:541` `aria-disabled={out(d) \|\| undefined}`; `:543` `title={out(d) ? reasonFor(d) : undefined}`; `:544` `onClick={() => { if (!out(d)) onPick(d); else setFocus(d) }}`; `:508-510` Enter/Space `if (!out(focus)) onPick(focus)`; `:550` greyed + line-through; footer reasons built `:442-445` (`reasonBeforeMin` / `reasonFuture` / `reasonAfterMax`), shown under the calendar `:449`. Probe `DATE-PICK-1.md:303`: `{"tomorrowDisabled":"not in this month","title":null,"reason":"Future dates can’t be chosen. Today is 05/10/2026."}`. ⚠ **Honest limit:** that probe arm proved the footer reason but **not** the per-day `title` (tomorrow was in another month, `title:null`); the per-day greying is proved by code reading here, not by a probe |
| d | keyboard: arrows, PageUp/PageDown, Enter, Esc | ✅ | `date-picker.tsx:497-505` `ArrowLeft −1 · ArrowRight +1 · ArrowUp −7 · ArrowDown +7 · PageUp/PageDown ∓1 month (Shift ∓12) · Home/End`; `:508-511` Enter/Space selects; `:405-409` `onEscapeKeyDown` → `e.stopPropagation()`, focus returns to the box; text box `:291-297` Enter commits, Alt+↓ opens. Probe `DATE-PICK-1.md:305-309`: `2026-09-04 · 2026-09-11 · 2026-09-10 · 2026-09-03` · `PageUp 上一个月 · PageDown 回来 — 2026-08-03 · 2026-09-03` · `Enter 选中那一天、月历关上、焦点回到框里` · `Esc 关上月历、值不变、焦点回框` |
| e | fixed width, 32 px high | ✅ | `date-picker.tsx:85` `WIDTH = { date: 'w-[9.75rem]', month: 'w-[7.75rem]', datetime: 'w-[9.75rem]' }`, applied `:335`; time box `:388` `w-[4.75rem] shrink-0`; height from `CONTROL_INPUT` (`:328`) = `app/components/ui/control-style.ts:68` `const BOX = 'h-8'` (32 px). Probe `DATE-PICK-1.md:406`: `390px · 日期框固定宽、32px 高 — 宽 156px · 高 32px` |
| f | handback opens with the v1.4.34 tester line; queue marks DATE-PICK-1 and the DATE-1 picker half complete | ⚠ **PARTLY** | ✅ `docs/handbacks/DATE-PICK-1.md:1` = `v1.4.34 — Every date box now shows and accepts day/month/year: …`. ✅ DATE-PICK-1 marked complete: `docs/forward-queue.md:247` (item 33 "✅ 日期选择器 —— DATE-PICK-1(`v1.4.34`…)"), `:6708` (HISTORY family "✅ DATE-PICK-1(`v1.4.34`…)"). ✅ the 甲 index row: `:4401` "✅ ~~★★ **DATE-1 的选择器那一半**~~ … ✅ DATE-PICK-1(`v1.4.34`,2026-10-05)做完". ❌ **the picker half's home row is not marked:** `:6409` (table "★ DATE-1 交回时新增的三条(2026-09-20)") still reads `★★ **选择器那一半** \| 130 个原生 <input type="date"> / 85 个文件 … 选择器单独报价` with no strike and no ✅. ❌ `:6458` still says the picker cut "已经在队列里 … 住在 … 「★★ 选择器那一半」" and "**等 Tim 答 DATE-0 的 Q1**". (Line numbers after this close-out's 5-line insert at item 33; before it, 4396 / 6404 / 6453.) Two of the three places that describe the picker half still present it as open — the repo's "文档活得比它的对象久" shape. **Not fixed, per the brief** |
| g | DATE-PICK-1's self-taken decisions (`DATE-PICK-1.md` §8, titles) | listed | 1. An invalid date is blocked by three mechanisms, chosen per site. 2. Date-and-time posts `YYYY-MM-DDTHH:MM+08:00`. 3. Typing commits as you go only when the entry is complete. 4. The error under the box appears on leaving it, or at once when a complete entry is impossible / out of range. 5. `DateFilterInput` and `ContractDateInput` deleted; `PaymentDateInput` kept. 6. Fixed widths 9.75 / 7.75 / 4.75 rem. 7. Month names are new messages; weekday names reuse `calendar.dow`. 8. "Future date" wording when `max` = today in Singapore; four `max` moved to `businessToday()`. 9. Draft restore fixed centrally. 10. The picker honours `form.reset()` and keeps Esc to itself. 11. Two pre-existing display-date-in-edit-state defects fixed. 12. The probe catches every server-action POST in the browser. 13. The probe removes the task header's `fieldset disabled` in its DOM. 14. The probe's two fault injections. 15. Comment blanking moved to `scripts/lib/blank-comments.mjs`. 16. A per-table live readings script. 17. PayrollGrid's read-only tint kept. 18. Two look changes accepted (48 px receiving rows; PO expected-date border). 19. Conversion split across five parallel agents with one spec. 20. Claims decision list wires validity per row. 21. "Clear" only on optional boxes; "Today" disabled outside min/max. 22. Pasted ISO timestamp and `/ . -` separators accepted. 23. The probe uses FA-2026-0001, FA-2026-0002 and TASK-2026-0181. 24. Survey route set from the import graph (92). 25. The one HTTP 500 on `/hr/payroll/new` recorded, not chased. 26. The 5 overflowing pages compared against the native control on the same page. 27. The lint baseline tightened to 83 warnings |

### 1.4 — Commit

Docs only, message "DATE-PICK-1 close-out": `docs/forward-queue.md` (item 33 deployment line), `docs/known-issues.md` (the two entries),
this file. Staged by explicit path.

### 1.5 — Assertions in the step-1 brief that I measured and found false or imprecise

1. "the five pages that overflow at 390px (**measured identical with the native box restored**)" — true for **four**. `/sales/quotes/[id]`
   was not swapped: its default view has **no date box at all** (probe: `默认画面里没有日期框,溢出与它无关 溢出 0px · 日期框 0 个`).
   The known-issues entry says this rather than "identical".
2. "Record in docs/forward-queue.md that DATE-PICK-1 had no migration" — **already recorded** in item 33 by DATE-PICK-1 itself; this close-out
   added the measured basis and the push time, not the fact.
3. DATE-PICK-1's own hand-back §9 says 'the "DATE-1 的选择器那一半" row is ✅' — true of the 甲 index row only; the home row is not (§1.3 f).

Everything else re-measured matched: SHAs, clean tree, 7 accounts / 0 disabled, approvals finance / cfo / 1,000, v1.4.34's tester line.


## §2 · Q-f, answered and done

Tim answered Q-f "yes" (2026-10-05). `docs/forward-queue.md`'s two stale rows are struck and marked ✅ with a pointer to DATE-PICK-1 (`v1.4.34`), the old text kept struck through: the "选择器那一半" row in "★ DATE-1 交回时新增的三条" and the "日期选择器那一刀" row, which no longer says it waits on DATE-0 Q1. Commit `b6f04971` "Queue: DATE-1 picker half closed by DATE-PICK-1", pushed 15:03:33 CST.

---

# UNBLOCK-1 · Step 0 (grilling) — STOP GATE

**How the facts were gathered.** Code facts came from four read-only survey agents (no edits, no database). I re-read every claim this hand-back rests on myself; corrections are marked. **Live readings** are mine, read-only, through the Management API **as `postgres` (`rolbypassrls = true`)** between 15:05 and 15:25 CST. They read base tables unless a view is named; a view with a `has_permission()` predicate reads **0 rows for `postgres`** (no JWT), and that is said wherever it applies. The queries are in the session scratchpad (`u1/live1.sql` … `live8.sql`); each reading below names its table. No write of any kind. No code, no migration.

**Live context used throughout** (`role_permissions` × `user_roles`, revoked excluded, 7 accounts):

| account | role | finance.view | data.view_pay | hr.view | processing.view | decide_hr_requests |
|---|---|:-:|:-:|:-:|:-:|:-:|
| tim@ | cfo | ✓ | ✓ | ✓ | ✓ | ✓ |
| admin@ | admin | ✓ | ✓ | ✓ | ✓ | ✓ |
| chooer@ | finance | ✓ | ✓ | ✓ | ✓ | ✓ |
| sandra@ | cco | ✓ | ✓ | ✓ | ✓ | ✓ |
| **phua@** | **cto** | ✓ | **✗** | ✓ | ✓ | ✗ |
| **vince@** | **gm** | ✓ | **✗** | ✓ | ✓ | ✗ |
| **fusheng@** | **warehouse** | **✗** | ✗ | **✗** | ✓ | ✗ |

`data.view_reviews`: admin, cto, cfo, cco, gm, hr (the `hr` role has no holder). `data.view_change_log`: admin, cfo. `action.manage_permissions`: admin only.

## §3 · (a)+(b) The complete item list

Drawn from the repo, not the brief. Sources:
- `docs/forward-queue.md`, the "⬜ ★ 下一刀:UNBLOCK-1" block (`:6717-6733`).
- The open rows of the 甲 index "今天挡得住一个人" (`:4382-4400`).
- The `docs/known-issues.md` entries those rows and the brief point to.

Status: **TRUE** = still true on live/code today · **STALE** = already fixed · **NOT A DEFECT** = the premise is false · **LATENT** = true in code, nobody hit today.

### Group 1 — privacy (Tim's order: first)

**1.1 · `AT1C1-PAYROLL-JOURNAL-SHOWS-INDIVIDUAL-PAY` — payroll journals show one person's pay to finance readers without `data.view_pay`.** TRUE.
- **Who it affects today:** phua@ (cto) and vince@ (gm) can read it.
- **Live (`journal_entries`/`journal_lines`, base tables):** there are 4 entries with `source_type='payroll'` (JE-2026-0017 posting, 5 lines; -0018 pay run, 2 lines; -0019 CPF, 2; -0020 deductions, 2).
  - JE-2026-0018 is `2300 Dr 4,677` and `1000 Cr 4,677`, and the credit memo starts `EMP-`. So both the per-person line **and** the run's total are one person's net pay.
  - The period has 1 payroll line, so the posting entry's totals are also one person's figures.
- **Where it lives:**
  - Writer: `db/functions/pay_payroll_lines.sql:87-90` (one bank credit per person, memo `emp_code || ' ' || legal_name`) and `:99-105` (2300 total; `source_type 'payroll'`).
  - RLS: `journal_lines` has a single SELECT policy, `has_permission('module.finance.view')` (`db/tables/journal_lines.sql:90-93`), and a table-level grant (no column list).
  - Readers that show per-line amounts:
    - `app/finance/journal/[id]/page.tsx:65-70,109-122`
    - `app/finance/journal/page.tsx:107,113` (Σdebit per entry)
    - `app/finance/journal/export/route.ts:67-69,109-112` via `journal_activity_lines` (invoker)
    - `account_ledger` (DEFINER, finance.view) → `app/finance/ledger/[account]`
    - `bank_unmatched_journal_lines` (invoker view) → `/finance/bank/statements/[id]/reconcile`
    - the trail: subject `journal_entry` on `/finance/journal/[id]` and the `ListTrail` on `/finance/payroll-payments`, rendered by `lib/trail/render.ts:2687-2696`
  - Readers that show aggregates only:
    - `app/finance/trial-balance/page.tsx:78`, which fetches every line through PostgREST (`journal_lines.select('account_id, debit, credit')`)
    - `/finance/close` (`:163-171`)
    - the DEFINER statements (P&L, balance sheet, cash flow, packs)
- **Fix:** amounts of payroll journal lines are Restricted to readers without `data.view_pay`. The scope and mechanism are Q1–Q4. **Migration: yes.**

**1.2 · Q16 `AT1D1-KPI-OPEN-CYCLE-SCORES-SELF-READABLE` — an employee can read their own KPI score before the cycle closes, through the API.** TRUE but nothing to read today.
- **Live (`kpi_entries`):** 30 entries, all for employees who have an account; **0 scored**; all 6 `kpi_cycles` are `open`.
- **Who it affects:**
  - The direct-API path (policy "kpi_entries select own", `db/tables/kpi_entries.sql:108-110`, no cycle condition) is open to every account.
  - It matters for chooer@ and fusheng@, who lack `data.view_reviews`. The others can already read every entry through the HR policy (`:99-101`).
  - **New finding (code, inferred, not run):** a second path.
    - Trail subject `kpi_entry` is gated by `module.hr.view` (`db/functions/trail_subjects.sql:249`), and its root goes through `trail_row_visible`, which ORs the table's policies (`trail_row_visible.sql:47-51`). So the self policy admits one's own entry.
    - `kpi_entries` has **no** mask rules.
    - So chooer@ (hr.view ✓, view_reviews ✗) could call `record_trail('kpi_entry', <own id>)` and read score/evidence/feedback once scored.
- **Unaffected:** `/me` reads `my_kpi_entries` (owner view; scores shown only when `cy.status='closed'`, `db/views/my_kpi_entries.sql:42-48`; `feedback_note` is never shown).
- **Fix:** Q5. **Migration: yes.**

**1.3 · Q17 `AT1D1-HR-NOTES-SELF-READABLE` — HR's notes about an employee are readable by that employee.** TRUE.
- **Live (`employees`):** 22 employees, 5 with non-empty `notes`, 0 with `separation_notes`.
- **Where:**
  - `notes` and `separation_notes` are in the column grant (`db/tables/employees.sql:229-230`).
  - The self policy is `:234-236`.
  - `employees_masked` passes both through unmasked (`db/views/employees_masked.sql:35,57`; row filter is hr.view OR self, `:97`).
  - `my_profile` does not include them.
  - `export_my_personal_data`'s `my_record_changes` returns the full change history of the employee's own `employees` row, notes included (`db/functions/export_my_personal_data.sql:71-83`).
  - `/me` prints `employment_history.notes` (`app/me/page.tsx:146-147`).
- **Who:** every employee with an account, about themselves.
- **Fix:** Q6–Q7. **Migration: yes.**

**1.4 · Q18 `AT1D1-HEALTH-TEXT-AND-PERIOD-TOTALS-BEHIND-HR-VIEW-ONLY` — health text and payroll-period totals need only `module.hr.view`.** TRUE.
- **Live:**
  - 1 medical claim (with a description).
  - 6 leave requests (1 with a reason).
  - 1 payroll period, `PAY-2026-0001`, with 1 line, so its totals are one person's pay.
- **Who:** phua@ and vince@ (hr.view ✓, view_pay ✗, decide_hr ✗) read the health text and the period totals.
- **Where:**
  - `medical_claims` is HR-or-self, with no column masking. Its reader is `medical_claim_status` (owner view, `:23-24,48`), used by `/hr/claims`, `/hr/claims/[id]` and `/me`.
  - `leave_requests` has a whole-table grant (`:74-75`), and `/hr/leave/[id]` selects `*`.
  - `payroll_periods` totals print unconditionally on `/hr/payroll/[id]` (`page.tsx:139-145,266-272`) and `/hr/payroll` (`:31-33,76-77`).
  - Finance pages already mask the same totals through `payroll_period_lookup` (`:17-35`, view_pay).
  - Sibling: `payroll_requests.snapshot` (`payroll_period_fingerprint`) holds per-line `employee_id:gross:cpf…` behind hr.view only (0 rows live).
- **Fix:** Q8–Q10. **Migration: yes** (a new data code is migration-level, `db/tables/permissions.sql:4-9`).

**1.5 · Q30 `AT1D1-ANONYMISATION-LEAVES-OTHER-TABLES-UNREDACTED` — anonymising an employee leaves their personal data in other tables and their change log.** TRUE in code, **dormant**.
- **Live:**
  - `hr_settings.personal_data_retention_months` is **NULL**, so `anonymise_employee` refuses (`:54-57`).
  - 0 employees have been anonymised.
  - There is no UI; only admin holds `action.anonymise_employee`.
- **Where:**
  - `anonymise_employee.sql:78-122` → `change_log_redact_employee.sql:34-40`: an in-place UPDATE of `change_log` jsonb, limited to `employees` and `employment_history`.
  - `change_log_redactable_columns.sql:11-19` is an IMMUTABLE constant.
  - Guard: `guard_change_log_append_only.sql:17-26` + `change_log_redaction_ok.sql:10-17`. Only one redaction per log row (`redacted_at IS NULL` → NOT NULL), and only listed columns may be nulled.
- **Not redacted:**
  - `salary_change_requests` (amounts, reason, snapshot)
  - `payroll_lines` (amounts, notes)
  - `payroll_requests.snapshot`
  - `leave_requests.reason / certificate_ref / exception_reason`
  - `medical_claims.description`
- **Fix:** Q11. **Migration: yes.**

### Group 2 — Tim's second item

**2.1 · `AT1D3-ME-PAYSLIP-CURRENCY-NEEDS-HR-VIEW` — on `/me`, payslip amounts show no currency to an employee without `module.hr.view`.** TRUE, latent.
- **Where:** `app/me/page.tsx:268-274` reads `payroll_periods.currency`, which returns 0 rows without hr.view. `formatAmount` then prints a bare number (`lib/format.ts:32-39`).
- **Who:** fusheng@ only, and he has no payslip yet (live: 1 payroll line, not his).
- **Fact that decides the fix:** payroll **can** be in a non-base currency.
  - `payroll_periods.currency` has no base CHECK (`:22`).
  - `upsert_payroll_period.sql:42-52` accepts any currency.
  - `PayrollGrid.tsx:372-381` offers USD.
  - Live: the 1 period is SGD, the base.
- **Fix:** Q12. **Migration: yes** if the currency is added to `my_period_labels()`.

### Group 3 — everything else filed under UNBLOCK-1 or the 甲 index

**3.1 · `AT1B-EQUIPMENT-ADVICE-SHOWS-COSTS` — a processing-only reader sees machine cost and repair spend.** TRUE.
- **Who:** fusheng@ (processing.view ✓, finance.view ✗).
- **Where:**
  - `db/views/equipment_maintenance_advice.sql:20-44`: owner view, gated `finance.view OR processing.view`.
  - It returns `work_cost_base` and `equipment_cost_base`, plus `pct_of_equipment_cost`, from which one cost can be derived from the other.
  - Its only app reader is `/finance/assets/[id]` (`page.tsx:174`), behind the finance gate. The leak is the API.
- **Live:** `equipment_maintenance` has 2 rows. The view itself reads 0 for `postgres` (predicate, no JWT), which is not a measurement of what a holder sees.
- **Fix:** Q13. **Migration: yes.**

**3.2 · IOD-1 "收货库位录不进去" — receipt location can't be entered.** **STALE: fixed 2026-08-13 by IOD-1b.**
- The three creation forms call `create_inbound_batch` / `receive_inbound_batch_against_po` / `create_output_batch`, each passing `p_location_id` (`app/inbound/new/actions.ts:142`, `app/inbound/receive/actions.ts:110`, `app/output/new/actions.ts:80`).
- Each function sets `evoltrya.location_ctx` (`create_inbound_batch.sql:33`, `receive_inbound_batch_against_po.sql:20`, `create_output_batch.sql:19`).
- Each form renders `<LocationPicker>`.
- Migration `2026-08-13-iod1b-batch-creation-rpcs.sql`.
- **Fix:** docs only. Strike `known-issues.md:3481` and the 甲 row `forward-queue.md:4392`.

**3.3 · SO-1b — no entry point for adding lines to a shipped order.** TRUE.
- **Where:**
  - `app/sales/orders/[id]/page.tsx:115`: `amendable = … ['draft','confirmed','partially_shipped'].includes(o.status)`.
  - The amend page and `amend_sales_order` (`:35,40`) accept `shipped` as add-only.
- **Live:** 1 shipped order (`sales_orders`: draft 2 · shipped 1 · cancelled 3).
- **Who:** anyone with sales edit (sandra@, admin@).
- **Fix:** add `'shipped'` to that array, with an add-only hint (Q14). **Migration: no.**

**3.4 · `BTN5B-RECONCILE-UNREACHABLE` — the bank reconcile page can't be opened.** **NOT A DEFECT.**
- **Live (`bank_statements`):**
  - BS-2026-0001 is soft-deleted.
  - BS-2026-0002 is reconciled.
  - There is no open statement.
- The page opens for any open, undeleted statement (`reconcile/page.tsx:47-60`).
- The entry's mechanism is also out of date: a soft-deleted statement now **redirects** to its detail page (`:53-55`, since AT-1c-2) rather than `notFound()`.
- Two in-app ways would open it: import a statement, or un-reconcile BS-2026-0002.
- Nobody is blocked; the page simply has nothing to work on.
- **Fix:** docs only. Move the row out of 甲 (Q22).

**3.5 · Downtime "停机没有删除 / 更正的门" — a wrongly entered downtime can't be fixed or deleted.** TRUE.
- **Live (`equipment_downtime`):** 1 row, FA-2026-0001, still open, started 2026-08-23 18:55, reason "Test-1".
- **Where:**
  - `app/finance/assets/[id]/actions.ts:118-149` only opens and closes.
  - `DowntimePanel.tsx` has no edit or delete control.
  - Policies (`db/tables/equipment_downtime.sql`): UPDATE is allowed for `module.processing.edit` on any column (`:97-101`); there is **no DELETE policy**.
  - Foreign keys from `shift_handover_equipment_refs.downtime_id` (NOT NULL) and `equipment_maintenance.downtime_id` make a hard delete unsafe.
  - The overlap guard `guard_downtime_period` excludes the row itself (`d.id <> NEW.id`).
  - The table is change-logged (`db/views/zzz_change_log_triggers.sql:245`).
  - **Correction to the agent's note:** an in-app correction *would* leave its old values in the change log.
- **Fix:** Q15. **Migration:** yes for void; no for correction.

**3.6 · `ROLE1B3A-NO-OTHER-DECIDER-PO-EXPENSE`, expense half — a claim can be submitted that no one but the submitter could decide.** TRUE, latent.
- **Where:** `submit_expense_claim.sql` never calls `assert_other_decider`. Every other submit path does (15 callers, including `create_purchase_order:372`).
- **Live (`approval_pending_documents()` × `approval_deciders`, as postgres; DEFINER functions):**
  - The one pending document, CLM-2026-0004 (chooer@, 1,000.00, level 2), has a decider: **tim@**.
  - Nobody is stranded today.
  - The shape still bites the first time tim@ (the only real level-2 holder) submits a claim ≥ 1,000, or chooer@ (the only real level-1 holder) submits one < 1,000. The exception is the R2 self-exception.
- **Two corrections to the entry:**
  - `approval_pending_documents.sql:76-78` gives expense claims `blocks_disable = false`, so such a claim does **not** block switching approvals off.
  - `assert_other_decider` passes `NULL` as the subject employee (`:35-36`), while claims apply four-eyes to the subject too (`decide_expense_claim.sql:94`). The fix must pass the subject.
- **Fix:** refuse at submit with `EXPENSE_CLAIM_NO_OTHER_DECIDER|<code>`, as `PO_NO_OTHER_DECIDER` does. **Migration: yes.** No ruling needed: Tim already ruled the shape for POs (APR-10).

**3.7 · `GHOST-GRANTS` — throwaway test accounts can leave real admin grants behind.** PARTLY CLOSED.
- **Live (`user_roles` × `auth.users`):** **0** ghost grants; 7 live grants for 7 accounts.
- The default smoke run no longer grants the real `admin`. It uses a throwaway all-codes role (`scripts/smoke-routes.mjs:2033-2045`).
- The guard counts real holders (`guard_last_admin` via `real_role_grants`, fixture 191).
- **Still open:**
  - smoke `--reach` (`:1793,2883-2893`) and about 25 `probe-*`/`survey-*` scripts (e.g. `survey-phone.mjs:461-463`, `render-pdf-samples.mjs:122-124`) still grant the real `admin`, through ephemeral plans.
  - `render-pdf-samples.mjs` takes no live-lock.
- Nobody is blocked today.
- **Fix:** Q23. **Migration: no.**

**3.8 · PayrollGrid @ 390px.** **STALE: fixed by DRAFT-6 (2026-09-21).**
- `PayrollGrid.tsx:429-442` uses `<EditableTable phone={{mode:'columns'}}>` with the employee column marked `priority`.
- `known-issues.md:8394-8398` already strikes it (table shell `326/326`, `PROBE_OWN_EXIT=0`).
- **Fix:** docs only. Strike 甲 `:4396`.

**3.9 · `ForwarderPanels:167` — the delete button is only half visible.** TRUE in code.
- The 24px reading was not re-measured.
- The table is now at `app/logistics/forwarders/[id]/ForwarderPanels.tsx:175-210`: a raw 5-column table, with delete in the last cell inside `overflow-x-auto`.
- **Fix:** Q16. **Migration: no.**

**3.10 · `/hr/kpi/score` row height.** TRUE in code.
- `ScoreEditor.tsx:90-130`, `key:'kpi'` cell: title, weight, a `<dl>` of target/evidence, and the month-3/month-6 text of each org target. There is no clamp or disclosure.
- Measured in POLISH-1 r3: desktop 252–504px, phone 722–1699px.
- **Fix:** Q17. **Migration: no.**

**3.11 · "两个账号前置" — two account prerequisites.**
- **① STALE.** It says an account holding dictionary edit but not permission management does not exist. Live `role_permissions`: `module.materials.edit` (the code every dictionary uses, `registry.ts:80-150`) is held by cco, cto and finance (sandra@, phua@, chooer@), and none of them holds `action.manage_permissions`.
- **② TRUE.** Only `admin` holds `action.manage_permissions` (live), held by admin@ alone. If admin@ is lost, recovery is direct SQL.
- **The row's "全系统只有一个人登得进来" (only one person can log in) is false:** live has 7 confirmed accounts.
- **Fix:** Q18. **Migration: no.**

**3.12 · `PERIOD-LOCK-RAW-CODE` — error localizers don't know `PERIOD_LOCKED`.** PARTLY STALE.
- **Recount (`find app lib -iname "*errorcodes.ts"`):** **48** files, of which **12** contain `PERIOD_LOCKED` and **36** do not. The entry said 42 / 11 / 31, measured before BUGFIX-1b.
- The raw `PERIOD_LOCKED|…` string no longer reaches the screen. The shared fallback shows `messages/en.ts:1097` "This step could not be completed (code PERIOD_LOCKED). Please pass this code to your administrator." (`lib/machine-text.ts:51,121-142`).
- Still a defect: the person is not told the period is locked, or until when.
- **Fix:** map `PERIOD_LOCKED` once in the shared fallback (`lib/machine-text.ts`) to a sentence naming both dates. No ruling needed. **Migration: no.**

### Group 4 — the AT-0 defects (filed in known-issues, Tim's AT-0 Q34)

**4.1 · `AT0-WITHDRAW-PAYMENT-REQUEST-NO-REQUESTER-CHECK`.** **NOT A DEFECT as written.**
- The entry says "同一族的另外五支都有提交人判据" (the other five in the family have a requester check). Measured:
  - The siblings' idiom is `IF self_leg(created_by, NULL, auth.uid()) <> 'raiser' THEN PERFORM require_permission(<code>)`. That means **the raiser OR any holder of the code** (e.g. `withdraw_invoice_request.sql:21-23`, header `:3` "提单人本人……或任何持 module.finance.edit 的人").
  - `withdraw_payment_request` requires `module.finance.edit`, which every raiser holds. So the behaviour is the same.
  - `withdraw_payroll_request` has the same form.
- **Live:** 0 payment requests.
- **Fix:** Q19.

**4.2 · `AT0-DEEP-DISCHARGE-DIRECT-UPDATE` — the deep-discharge judgement can't be saved.** TRUE.
- **Where:**
  - `app/purchasing/orders/[id]/actions.ts:121-136` does a direct `UPDATE purchase_order_lines`.
  - `guard_po_direct_write` refuses it with `PO_THROUGH_FUNCTION_ONLY` (`db/tables/purchase_order_lines.sql:228-230`). The refusal is translated, so the person sees a red message.
  - The control is `DeepDischargeJudgementControl.tsx:50`.
- **Live (`purchase_order_lines`):** 11 lines, **0** judged.
- **Who:** anyone with purchasing edit (cto, finance, cco, admin).
- **Fix:** a small SECURITY DEFINER `set_po_line_deep_discharge(p_line_id, p_code)`, with the action pointed at it (Q20). **Migration: yes.**

**4.3 · `AT0-RUN-EQUIPMENT-NOT-PASSED` — recording a processing run never records the machine.** TRUE.
- **Live (`processing_runs`, undeleted):** 10 runs, **0** with `equipment_id`.
- **Where:** `commit_processing_run(p_equipment_id DEFAULT NULL)` validates it (`:140-158`). The only caller, `app/operation/processing/new/actions.ts:52-73`, never sends it.
- **Source for a picker:** `equipment_usage` (owner view, finance.view OR processing.view; lists every asset and has no `category` column).
- **Fix:** Q21. **Migration:** no (yes only to add `category` to `equipment_usage`).

**4.4 · `AT0-ACTIONS-WITHOUT-CALLER` — three server actions are never called.** TRUE.
- `deleteEmployee` (`app/hr/employees/actions.ts:357`), `updateQuoteHeader` (`app/sales/quotes/actions.ts:168`) and `softDeleteCommissionAgreement` (`app/sales/commissions/actions.ts:97`) are only defined, never called.
- `rollback_processing_run` is now a named stub that sends you to the warehouse request (`:14-18`).
- **Fix:** delete the three actions and keep the stub (it is a refusal that names the right path). No ruling beyond the brief's "接上界面,或删掉" (wire up or delete). If Tim wants any of the three wired, say so (Q24). **Migration: no.**

**4.5 · `AT0-PO-CLOSE-REASON-IN-NOTES` — closing or reopening a PO writes the reason into its Notes.** TRUE.
- **Where:**
  - `close_purchase_order` and `reopen_purchase_order` (`:47-48`) append `[YYYY-MM-DD HH:MI closed|reopened] reason` to `notes`.
  - `trg_po_history_header` then writes a reasonless `header_update` row.
  - The trail (`render.ts:565-607`) shows "Notes … → …" plus a reasonless "Purchase order amended".
- **Live (`purchase_orders`):** **2 of 11** POs already carry such a suffix in their notes.
- **Fix:** Q25. **Migration:** yes for the write-side fix.

### Group 5 — month close

**5.1 · `AT1C3-LIVE-MONTH-CLOSE-BLOCKED-BY-UNALLOCATED-RUNS` — 8 committed processing runs were never cost-allocated, so no month can close.** TRUE.
- **Live (`processing_runs`):** 8 committed, unallocated, undeleted runs, dated 2026-06-10 → 2026-08-16. `locked_before` is 2026-08-01.
- It blocks every month close (`close_period.sql:36-46` → `PROCESSING_COSTS_UNALLOCATED`).
- **No code defect.** The UI path exists: `/operation/processing/[id]` → `AllocateButton`, `module.finance.edit`, one run at a time.
- **Measured for this Step 0 (live, `sales_records` × `processing_outputs`):**
  - None of the 8 runs has an uncosted sale dated before the lock.
  - 5 uncosted sales would be COGS-posted, dated 2026-08-05 / 08-10 / 08-14 / 08-26, all in the open period. So allocation would **not** hit `PERIOD_LOCKED`.
  - Basis: 7 runs are `metal_value`, 1 is `weight`.
  - `metal_prices` covers 2026-06-25 → 2026-08-10 (12 rows).
  - So **PROC-2026-0001 (2026-06-10) predates every price**. It will most likely refuse with `NO_METAL_VALUE` (inferred from `allocate_processing_costs.sql:366`, not run).
- **Two adjacent code defects found:**
  - `/finance/month-end/page.tsx:107-108` counts only stale runs, or unallocated runs *with a cost change*. `close_period` blocks on **any** unallocated run. So the checklist can show 0 while the close refuses.
  - `localizeProcessingError` (`app/operation/errorCodes.ts`) does not map `PERIOD_LOCKED` / `ALLOCATION_STATE_CHANGING_*` / `ALLOCATION_LEDGER_DIVERGED`. The first is covered by 3.12.
- **Side finding, register only:** `allocate_processing_costs` filters `price_index` for the total (`:356-360`) but not for the per-leg CTE (`:425-437`) or `skipped_metals` (`:398-405`). Once two indices both have prices, legs and total can disagree. Live: every row is one index? NOT MEASURED.
- **Fix:** Q26.

## §4 · (c) Every question for Tim, with a recommended answer and evidence

Questions in one block are independent of each other, except where a question says it depends on another.

❓ **Q1 — Payroll journals: what counts as "an individual's amount"?**
The per-person bank lines are the obvious part. But live JE-2026-0018 shows the run's **2300 total equals the one person paid** (4,677 both sides). The posting entry JE-2026-0017's totals equal the one employee's gross, CPF and net, and so do the CPF/deductions entries. The journal list prints Σdebit per entry.
- (a) only the per-person bank lines (and their reversals);
- (b) every line of the pay-run entries;
- (c) **every line of every journal entry with `source_type='payroll'`** (posting, pay run, CPF, deductions, and their reversals, which keep `source_type`, `reverse_journal_entry_internal.sql:42-63`).

➡️ **(c).**
- It is the only rule that does not leak through a one-person total.
- It is one predicate on `journal_entries.source_type`, with no join to `payroll_lines`.
- It matches Q9's period totals. Masking the HR page while the journal shows the same numbers to the same people (cto and gm hold both) would be theatre.
- Financial statements (P&L 6100, bank balance, trial balance per account) stay visible to finance readers as aggregates: standing decision 1, "the GL is the price data", applied to pay.

❓ **Q2 — Payroll journals: screen only, or the API too?**
`journal_lines` is readable through PostgREST by every `module.finance.view` holder (`journal_lines.sql:90-93`, table grant). Standing decision 1 forbids revoking columns on it.
- (A) **Readers only.** An owner-rights `journal_lines_masked`-style reader with `CASE WHEN has_permission('data.view_pay') OR e.source_type <> 'payroll'`. Switch the journal page, list, export, ledger, reconcile candidates and trail to it. A direct `GET /rest/v1/journal_lines` still returns the amounts.
- (B) **A + a RESTRICTIVE RLS policy** on `journal_lines` hiding payroll-source lines from non-view_pay readers. This closes the API. Cost:
  - every **invoker** aggregate read must move to a DEFINER aggregate, or it silently drops those rows (the `xmodule` disease, AGENTS.md: "0.00 and 受限 are not the same thing");
  - concretely: `/finance/trial-balance` (`page.tsx:78` fetches every line), `/finance/close` (`:163-171`), `/finance/journal` Σdebit (`:107`), and `journal_activity_lines` when called by the export;
  - the DEFINER statements are unaffected (owner bypasses RLS);
  - the trail then calls those lines `row_hidden`/Restricted on its own (`trail_row_visible`).

➡️ **(B).**
- Q16 is in this very group because "the screen hides it, the API gives it". Fixing payroll the (A) way would ship the same shape Tim already named a defect.
- The extra cost is bounded and listed above.
- A fixture must assert the trial balance still **balances** for a finance-without-view_pay reader. That is the regression (B) can cause, and it is silent.

❓ **Q3 — Payroll journals: the line memo (employee code + name).**
Under Q2 (B) the line itself is hidden from the API. The question is what the masked reader shows.

➡️ **Show the memo, restrict only the amounts.**
- *Who* was paid is the fact a finance reader needs to recognise the entry.
- Standing decision 3: the display label follows the document.
- *How much* is the pay data.
- If Tim wants names hidden too, it is one more CASE.

❓ **Q4 — The bank's own copy: `bank_statement_lines` and `bank_line_matches.matched_amount`.**
These carry the bank's per-person salary transfer rows (finance.view RLS, `bank_statement_lines.sql:32-35`). Live: 4 statement lines in total. Masking them would blind reconciliation for anyone without view_pay. Live, every role that holds `module.finance.edit` (finance, admin) also holds view_pay.

➡️ **Out of scope.** Register it as a named known issue, `UNBLOCK1-BANK-STATEMENT-SHOWS-PAY` (it is the bank's document, read only on the reconcile pages). Revisit if a finance.view-only role ever reconciles.

❓ **Q5 — KPI scores before the cycle closes (Q16).**
- (a) Add "cycle closed" to the self policy. This needs a DEFINER helper, because an EXISTS on `kpi_cycles` inside the policy runs under `kpi_cycles` RLS (hr.view only, `kpi_cycles.sql:57-59`).
- (b) **Drop the self policy.** The employee's one read path becomes `my_kpi_entries` (owner view, already hides scores until closed and never shows `feedback_note`).

➡️ **(b).**
- Facts: no app reader uses the self policy (the `/me` reader is `my_kpi_entries`, `app/me/page.tsx:64`).
- Dropping it also closes the trail path found in §3 1.2 (`record_trail('kpi_entry', own id)` → `trail_row_visible`).
- The cut must still grep invoker functions that an employee calls on their own entry before dropping it. Re-check, don't assume.

❓ **Q6 — HR notes (Q17): may an employee read what HR wrote about them?**
Today the API, `employees_masked`, and the export say yes; the screens say no.

➡️ **No, on screen and through the API.**
- Revoke `notes` and `separation_notes` from the column grant.
- In `employees_masked`, add `CASE WHEN has_permission('module.hr.view') THEN … END`.
- Add a matching `change_log_mask_rules` row, `code:module.hr.view`. The existing `code` form (`change_log_rule_visible.sql:14`) already means "this code only, no self clause", so no new rule form is needed.

❓ **Q7 — HR notes (Q17): and the personal-data export?** (Depends on Q6.)
`export_my_personal_data` hands the employee the full change history of their own `employees` row, notes included (`:71-83`). It is the PDPA access-request path, and an access request generally covers opinions about the person unless an exception applies.

➡️ **Keep the export as the one deliberate exception.**
- Write the exception into the known-issue as a ruling, so screen ≠ export is a decision, not drift.
- If Tim's PDPA reading says HR notes are excluded (evaluative-purpose exception), strip `notes`/`separation_notes` from `my_record_changes` in the same migration instead.
- This is Tim's legal call. I am not giving legal advice.

❓ **Q8 — Health text (Q18): a health data code, and who holds it?**
Today 6 of 7 accounts read medical descriptions and leave reasons.

➡️ **A new `data.view_health`.**
- Granted in the same migration to **admin** (standing ruling), **hr**, and the roles that **decide** HR requests: `action.decide_hr_requests` is held by admin, cco, cfo and finance (live).
- cto, gm and warehouse lose access.
- The employee keeps reading their own (self clause).
- It gates `medical_claims.description`/`amount_sgd` and `leave_requests.reason`/`certificate_ref`/`exception_reason`, in the readers (`medical_claim_status`, a new `leave_requests_masked`, `/hr/leave/[id]`) and in the mask rules (`code_or_self:data.view_health:employee_id`).

❓ **Q9 — Payroll period totals (Q18): mask by `data.view_pay` always, or only when a period has one or two people?**

➡️ **Always.**
- The finance side already does exactly this (`payroll_period_lookup.sql:17-35`).
- A size threshold leaks through period-to-period differences.
- It keeps one rule for "pay" across HR, finance and the journal (Q1).
- Covers `/hr/payroll`, `/hr/payroll/[id]`, the trail lines `render.ts:4368-4373`, and `payroll_requests.gross_total`/`amount_base`.

❓ **Q10 — Payroll request snapshot (Q18 sibling): `payroll_requests.snapshot` holds per-employee pay behind hr.view only.**

➡️ **Same rule as Q9.** Restricted to non-view_pay readers, in the same migration. Live: 0 payroll requests, so nothing changes on screen today.

❓ **Q11 — Anonymisation (Q30): how far should it reach?**

➡️ **Redact the free text, keep the amounts.**
- **Null:**
  - `leave_requests.reason` / `certificate_ref` / `exception_reason`
  - `medical_claims.description`
  - `salary_change_requests.reason`
  - `payroll_lines.notes`
- Do this in the base rows and in their change-log rows (extend `change_log_redactable_columns`, plus a widened `change_log_redact_employee`).
- **Keep:** pay amounts and claim amounts. They are accounting records with statutory retention, and once the person is anonymised they belong to "a former employee".
- Live has 0 anonymised employees, so the one-redaction-per-row guard leaves no back-fill problem.
- The guard itself (`guard_change_log_append_only`) does **not** need to change for this. If Tim wants amounts redacted too, say so; it is the same mechanism.

❓ **Q12 — Payslip currency on /me.**
- (1) Add `currency` as a fifth column of `my_period_labels()`.
- (2) Always print the base currency.

➡️ **(1).**
- (2) would be **wrong**, not just imprecise: a USD period is possible (`PayrollGrid.tsx:372-381`, `upsert_payroll_period.sql:42-52`), and its amounts would read as SGD.
- The currency is a property of a period the employee is already allowed to see (code and month).

❓ **Q13 — Equipment maintenance advice (Q14): mask which columns, behind which code?**

➡️ **Null `work_cost_base`, `equipment_cost_base` and `pct_of_equipment_cost` unless `has_permission('module.finance.view')`.**
- Keep `meets_threshold`: it is the advice itself and says only above or below.
- The gate is finance.view, not `data.view_prices` (the `processing_runs_masked` idiom), because both base tables are finance-only (`fixed_assets.sql:111`, `expenses.sql:247`).
- The percentage must go too, or one cost is derivable from the other.

❓ **Q14 — Shipped orders (SO-1b): may a fully shipped order take added lines?**
The engine allows it (fixture 70 H arm), and so does the page. The entry calls this Tim's business judgement; a new order is the alternative.

➡️ **Yes.**
- Add the entry point with an "add lines only" hint.
- The database already flips the status back to `partially_shipped`.
- Refusing would mean a second order for a top-up of the same deal.

❓ **Q15 — Downtime: correction, void, or both?**

➡️ **Both.**
- **Correct** start time and reason in-app: the UPDATE policy and overlap guard already allow it, and the change log keeps the old values.
- **Void with a reason** for a downtime that never happened: `voided_at/by/reason` columns, the guard skips voided rows, and readers filter them.
- **Never hard-delete:** handover and maintenance foreign keys point at it.
- The void needs a migration; the correction does not.

❓ **Q16 — ForwarderPanels delete button.**
TABLE-STYLE-2 measured that `tableC` makes it worse.

➡️ **Convert the quote table to the shared `DataTable` with the phone row-card/priority mode, and put Remove in the row's always-visible action cell.**
This is the house pattern for a destructive row action ("够不着的动作等于不存在", an action you can't reach doesn't exist).

❓ **Q17 — `/hr/kpi/score` row height.**

➡️ **Collapse each row's target, evidence and month-3/month-6 org-target block behind a per-row "Show targets" disclosure.**
- Visible by default: title, weight, score input.
- Acceptance: phone row ≤ 2 screen-heights, desktop ≤ ~120px.
- Measure before and after on the same tree.

❓ **Q18 — Account prerequisites: who can grant admin if admin@ is lost?**
① is satisfied (see §3 3.11). For ②:
- (a) grant `action.manage_permissions` to a second real holder;
- (b) a written break-glass procedure: direct SQL through `~/.pgpass`, recorded in the operating manual.

➡️ **(b).**
- admin@ and tim@ are the same person, so a second holder adds no second person.
- Granting user-administration to a working role widens the most powerful code.
- Move the row to 乙 (it waits on a person, not on work).

❓ **Q19 — Payment-request withdrawal (AT-0).**
The premise is false (§3 4.1).
- (a) close as not-a-defect;
- (b) tighten **all eleven** withdraw functions to raiser-only.

➡️ **(a).**
- Today's rule, "the raiser, or anyone holding that chain's edit code", is consistent across the family.
- Raiser-only would strand a request whose raiser has left.
- Correct the entry's "另外五支都有" (the other five all have it) in place.

❓ **Q20 — Deep-discharge judgement: who may set it, and when?**

➡️ **Anyone with `module.purchasing.edit` (today's UI gate), on any PO that is not cancelled.**
- It is a quality judgement on a line, not a commercial term, so no amend reason and no PO-manager check.
- The change log records each change.

❓ **Q21 — Machine on a processing run: collect it?**

➡️ **Yes, optional.**
- Add a machine `<select>` on `/operation/processing/new`, sourced from `equipment_usage`, excluding disposed assets, defaulting to "not recorded".
- Passing NULL is already a named category (`commit_processing_run.sql:113-138`).
- No migration. Add `category` later with `AT1B-EQUIPMENT-LIST-EVERY-ASSET`.

❓ **Q22 — Reconcile "unreachable".**

➡️ **Reclassify it out of 甲 to 丙 as "no open statement".**
- Correct the mechanism (deleted → redirect).
- No code, and no row created to make it reachable (the entry's own rule).

❓ **Q23 — GHOST-GRANTS: finish it?**

➡️ **Yes, scripts only.**
- Move smoke's throwaway all-codes role into a shared helper in `scripts/ephemeral.mjs`.
- Use it in every probe/survey that grants `code=eq.admin`.
- For `--reach`, clone each real role's permission set into a throwaway role, so it still tests that role's reach.
- Add the live-lock to `render-pdf-samples.mjs`.
- Each changed script gets one fault-injected red run.
- Then close the entry (its closing logic: no script can mint an unattributable real `admin` grant).
- Reclassify from 甲 to 丙 now: nobody is blocked (0 ghosts live).

❓ **Q24 — Three server actions with no caller: delete?**

➡️ **Delete all three.**
- `deleteEmployee` bypasses the anonymisation and deletion rules.
- `updateQuoteHeader` and `softDeleteCommissionAgreement` duplicate paths the UI already takes differently.
- Keep the `rollback_processing_run` stub (a named refusal).

❓ **Q25 — PO close/reopen reason.**
- (a) write side: `close_reason`/`reopen_reason` (+by/at) columns, notes no longer rewritten, and history rows carry `amend_reason`;
- (b) trail only: recognise the `[… closed]` suffix in `render.ts`, as Q10 did for payroll.

➡️ **(a).**
- Unlike the payroll suffixes, this one **rewrites a human-typed field**: the person's own notes are edited by the system.
- The trail already double-reports it as a reasonless amendment.
- The 2 live POs with the suffix: leave their notes as they are (test data; the history is in the change log) and say so in the cut's report.

❓ **Q26 — The 8 unallocated runs.**

➡️ **Tim's own data entry, not a cut** (the same disposition as the materials-kind ruling of 2026-09-20).
- Click **Allocate** on each run at `/operation/processing/[id]`.
- For **PROC-2026-0001**, which predates every metal price, either change its basis to `weight` or enter a price on or before 2026-06-10 first, or request its rollback.
- The **code** half goes into the next cut: the month-end checklist counts exactly what `close_period` blocks on, and the processing localizer maps the allocation error codes.
- Register the `price_index` inconsistency (do not fix it in UNBLOCK-1; it needs its own fixture with two indices).

## §5 · (d) Stale, already fixed, or not worth fixing

| item | verdict | evidence |
|---|---|---|
| IOD-1 receipt location | **fixed 2026-08-13 (IOD-1b)** | §3 3.2 |
| PayrollGrid @ 390px | **fixed 2026-09-21 (DRAFT-6)** | §3 3.8; `known-issues.md:8394-8398` already struck |
| reconcile unreachable | **not a defect** (no open statement) | §3 3.4 |
| two accounts ① | **satisfied** (cco/cto/finance hold `module.materials.edit` without `manage_permissions`) | §3 3.11 |
| "only one person can log in" | **false** (7 confirmed accounts) | live `auth.users` |
| withdraw_payment_request | **premise false** | §3 4.1 |
| PERIOD-LOCK-RAW-CODE counts and "raw string on screen" | **out of date** (48 / 12 / 36; generic sentence now) | §3 3.12 |
| ROLE1B3A "blocks_disable" | **false** | `approval_pending_documents.sql:76-78` |
| GHOST-GRANTS as "blocking a person" | **not blocking** (0 ghosts) | §3 3.7 |
| adjacent, **not** in UNBLOCK-1: `/settings/deleted` vs change log (HISTORY-0 Q30) | the sibling bullet after UNBLOCK-1 (`forward-queue.md:6734`), not filed under it | left where it is |
| 甲 rows already re-filed as 乙 (contract state machine → `CONTRACT-BUNDLE-1`; the material kinds → Tim's own data entry) | not UNBLOCK-1 work | 甲 index |

The stale docs are struck in the first cut's commit (Q22's reclassification included), with the old text kept struck through.

## §6 · (e) How the privacy group meets the audit trails and the change log

The trail decides "Restricted" with **three separate mechanisms**, and a privacy fix that moves one without the others makes the page and the trail say two things.
1. **Rows** follow RLS automatically: `trail_row_visible` ORs the table's permissive SELECT policies (`trail_row_visible.sql:47-51`) and **ANDs any restrictive ones** (`:55-…`, "已经写好" per its header `:6`). That AND branch **has never run on live**: the header records 0 restrictive policies among 287. A RESTRICTIVE policy on `journal_lines` (Q2 B) would be its first use, so the cut must fixture it. A payroll line must come back `row_hidden` for cto and visible for a view_pay holder, or the trail and the API disagree.
2. **Columns** follow a hand-written list, `change_log_mask_rules()` (`:16-104`), evaluated by `change_log_rule_visible` (forms: `code`, `code_or_self`, `pft*`). **The gate pairs it only with views named `<table>_masked`** (`change_log_mask_gaps.sql:16-41`, gate `changemask`, fixture 234). Consequences for this group:
   - Payroll journal lines (Q1) need a **new row-conditional rule form** ("restricted when the parent entry's `source_type='payroll'` and no view_pay"; the precedent is `pft:formula_id`, which looks up another table, `change_log_rule_visible.sql:21-31`). They also need a `journal_lines_masked` view with matching CASE columns, or the gate goes red with `stale_rule`.
   - Q6 notes → `code:module.hr.view`. Q8 health → `code_or_self:data.view_health:employee_id`. Q9 period totals → `code:data.view_pay`. Each comes with its `_masked` view column, which also fixes the existing blind spot that `payroll_period_lookup` and `medical_claim_status` are not `_masked` and so are invisible to the pairing check.
3. **Person names** follow `trail_actor` (hr.view). Not touched by this group.

Plus one renderer defect the fix must carry: **`lib/trail/render.ts:2687-2696` (`journalLineLine`) turns a masked amount into `0.00`.** `imgOf` drops restricted values, then `?? 0`. It must render Restricted (`isRestricted`, `:126-128`), with a wording golden in `scripts/check-trail-wording.mjs`. Otherwise the fix ships "Credit 0.00 SGD", the exact lie AGENTS.md names.

**Change log (Q30).** Redaction is an in-place UPDATE that the append-only guard admits **once per row**, only for listed columns, and only to JSON null. Widening the list is consistent with the guard as written. A second redaction of an already-redacted row is impossible by design (live: 0 anonymised, so nothing needs it). `change_log_redactable_columns` must stay word-for-word in step with `anonymise_employee` (fixture 234 pins it).

**The trail stays consistent** because every masked column gets all four in one migration: policy/grant → `_masked` view CASE → mask rule → page. A fixture arm then reads the same record as page and as trail for: a view_pay holder, cto (no view_pay), fusheng@ (no hr.view), and the employee themself.

## §7 · (f) Proposed order and split

| cut | contents | migration | why this boundary |
|---|---|---|---|
| **U1-A · pay and personal data** | 1.1 payroll journals (Q1–Q3) · 1.2 KPI self-read (Q5) · 1.3 HR notes (Q6–Q7) · 1.4 health code + period totals + request snapshot (Q8–Q10) · 1.5 anonymisation reach (Q11) · 2.1 payslip currency (Q12) · 3.1 equipment advice (Q13) · the trail renderer fix · stale-doc strikes (§5) | **one** | Tim's order (privacy first, payslip second). One mechanism (policy → `_masked` → mask rule → page) and one proof (the four-reader fixture). The advice leak is the same shape, so it rides along. |
| **U1-B · unblock the workflows** | 3.3 shipped add-lines (Q14) · 3.5 downtime correct/void (Q15) · 3.6 expense-claim other-decider · 4.2 deep-discharge function (Q20) · 4.3 machine on runs (Q21) · 4.4 delete dead actions (Q24) · 4.5 PO close/reopen reason (Q25) · 3.12 `PERIOD_LOCKED` shared mapping · 5.1 month-end checklist + processing error codes · 3.9 ForwarderPanels (Q16) · 3.10 kpi/score rows (Q17) · 3.7 GHOST-GRANTS scripts (Q23) | **one** | Write paths and screens, no visibility rules. |
| (Tim, any time) | the 8 runs (Q26) | — | data entry |

**Why two cuts and not one** (the real reason, not size alone):
- U1-A changes **who can read what** across ~10 readers and the trail's masking machinery. Its proof is a role-by-role reading matrix.
- U1-B changes **write paths**. Its proof is workflow arms (submit, refuse, void, allocate).
- Mixed, a red fixture in one would hold the other's window open.
- A wrong visibility rule is the most expensive kind of defect here (it is silent). It deserves a cut whose every check is about visibility.

**Why not more than two:** every other boundary I tried split one mechanism across two migrations, which AGENTS.md's three-changes-in-one-migration rule (WO-1a) warns against.

**Each leaves the system usable:**
- After U1-A, cto and gm read Restricted where they read pay. Nothing else changes for anyone with view_pay.
- After U1-B, each item adds a door; none removes one.

**Optional merge:** if Tim prefers one window, A+B is mechanically possible. I recommend against it for the reason above.

**If Q2 is answered (A) instead of (B):** U1-A shrinks by the four invoker-aggregate moves (about 1 h).

## §8 · (g) Time estimate, calibrated on the recent cuts

**Measured run times** (opening check, i.e. the session's first command, → push to `origin/main`, from each hand-back's opening line and `git reflog show --date=iso refs/remotes/origin/main`):

| cut | migration | opening → push | span |
|---|:-:|---|---|
| AT-1c-1 | yes | 2026-10-03 12:58:07 → 17:16:34 | 4 h 18 m |
| AT-1c-2 | yes | 17:20:24 → 2026-10-04 03:11:04 | 9 h 51 m |
| AT-1c-3 | yes | 07:38:14 → 10:43:28 | 3 h 05 m |
| AT-1d-1 | yes | 11:41:03 → 16:55:17 | 5 h 14 m |
| AT-1d-2 | yes | 16:59:37 → 21:16:28 | 4 h 17 m |
| AT-1d-3 | yes | 23:56:44 → 2026-10-05 02:24:44 | 2 h 28 m |
| DATE-PICK-1 | no | 09:12:02 → 14:48:30 | 5 h 36 m |

**The process floor of a migration cut**, from the measured parts in those hand-backs:
- backup 6–25 min (`BACKUP_EXIT=0` lines: 15:27→15:33, 18:46→18:57, 00:47→01:12)
- `gate.py --offline` ~1 min
- full gate 6–12 min (341 s · 414 s · 731 s)
- build ~2 min
- smoke ~13 min, often one rerun
- the survey/probe of changed routes ~15–30 min
- before/after live readings ~10 min
- hand-back ~30–45 min

**≈ 1 h 30 m – 2 h 15 m.** The smallest recent migration cut (AT-1d-3, 2 h 28 m) is consistent with floor + a small body of work.

| cut | floor | work | total | what the work is |
|---|---|---|---|---|
| **U1-A** | 1 h 30 m – 2 h 15 m | **4 h – 6 h** | **5 h 30 m – 8 h 15 m** | ~10 readers, 5 tables' policies/views, a new mask-rule form + `trail_row_visible` restrictive support, the renderer fix, a new data code, redaction widening, a four-reader fixture + live probe as cto/fusheng/self. Closest measured analogue: AT-1d-1 (5 h 14 m), AT-1c-1 (4 h 18 m). |
| **U1-B** | 1 h 30 m – 2 h 15 m | **3 h – 5 h** | **4 h 30 m – 7 h 15 m** | 4 small DB changes (claim refusal, downtime void, deep-discharge fn, PO reason columns) + 8 app/script changes, each with a fixture arm or a fault-injected script run. Closest analogue: AT-1d-2 (4 h 17 m) and DATE-PICK-1's breadth. |

The upper bounds assume one red-gate round per cut, as in AT-1c-2's 9 h 51 m outlier, which had two. If Q2 is (A), take ~1 h off U1-A.

## §9 · Assertions in the brief (and in the repo) that I measured and found false

1. The brief lists "**receipt location can't be entered (IOD-1)**" and "**PayrollGrid at 390px**" as blocking a person today. Both were **fixed** (2026-08-13 / 2026-09-21); the 甲 rows are stale.
2. "**the bank-reconcile page can't be opened**": no defect. There is no open statement, and the deleted-statement path now redirects.
3. "**an expense claim can be left with no one able to decide it**": true as a shape, but **not today** (CLM-2026-0004's decider is tim@). The entry's `blocks_disable` claim is false.
4. "**withdraw_payment_request has no requester check**": its siblings have none either in the sense meant. Their check is raiser **or** code holder.
5. "**the eight processing runs … block every month close**": true. But the brief's framing ("on live test data", "need a fix") hides that **no code change is needed**; it is eight clicks. One run will likely need a basis change.
6. Repo: `PERIOD-LOCK-RAW-CODE`'s 42/11/31 and "raw code on screen" are out of date (48/12/36; generic sentence).
7. Repo: "两个账号前置" ① and "only one person can log in" are false on live.
8. A survey agent's claim that an in-app downtime correction "would leave no audit trail of old values" is **false**: `equipment_downtime` is change-logged (`zzz_change_log_triggers.sql:245`).
9. A survey agent cited `render.ts:687-696` for the journal-line renderer; the function is at **`:2687-2696`** (re-read).

Matched on re-measurement: 8 unallocated runs; approvals ON (finance / cfo / 1,000); 7 accounts enabled.

## §10 · Stop

No code edits and no migrations. Waiting on Tim's answers to Q1–Q26.
