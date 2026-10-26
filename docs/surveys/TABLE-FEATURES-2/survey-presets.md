# TABLE-FEATURES-2 — date-range presets survey (read-only, 2026-10-26)

What Tim ruled (closed): presets are **this month, last month, this quarter, this year**. Calendar month and quarter use **Singapore time**. "This year" reads the configured year end (`finance_settings.fy_end_month/day`). The presets go on all 11 pages that have a from/to filter, and the P&L and cash-flow presets are corrected to Singapore time.

How this was measured: source reads only (cat, grep, sed). No build, no script, no DB. Paths are relative to the repo root. Line numbers were re-measured today. Several of them have **drifted** from `docs/surveys/TABLE-FEATURES-1/survey-lists.md` §2 (for example, expenseRows.ts 65-66 is now 77-78, and the processing query lives in `app/operation/processingQuery.ts`, not under `app/operation/processing/`).

---

## 1. The 11 pages

### 1a. Per-page table

| Route | Guard | Toolbar / form (file:line) | Params | Column (type) and comparison | Toolbar kind | Default | How a preset could set from/to |
|---|---|---|---|---|---|---|---|
| /finance/expenses | `requireModule(MOD.finance)` | `app/finance/expenses/ExpensesToolbar.tsx:10`; DatePickers :39,:46; call site `page.tsx:131-133` (in Suspense) | `date_from`, `date_to` (parsed by `parseDateRange`, `expenseRows.ts:38`) | `expense_date` (date NOT NULL, `db/tables/expenses.sql:26`). `gte` :77, `lte` :78 of `expenseRows.ts` | Client, controlled DatePicker, `onChange(key,value)` → `router.push` **one key per call** (:26-33), clears `page` | none (empty = unfiltered) | Button with onClick → one push setting **both** keys and deleting `page`. The current `onChange` can't do it: two calls in a row would each build from the same stale `searchParams`, so the second push drops the first key. |
| /finance/invoices | finance | `app/finance/invoices/InvoicesToolbar.tsx:10`; :34,:41; `page.tsx:101-103` | `date_from`, `date_to` (`invoiceRows.ts:49`) | `issue_date` (date NOT NULL, `invoices.sql:31`). `gte` :73, `lte` :74 | Client, single-key `onChange` (:21-28) | none | Same as expenses |
| /finance/journal | finance | `app/finance/journal/JournalToolbar.tsx:9`; :32,:39; `page.tsx:175-177` | `date_from`, `date_to` (`journalRows.ts:37`) | `entry_date` (date NOT NULL, `journal_entries.sql:54`). `gte` :48, `lte` :49 | Client, single-key `onChange` (:19-26) | none | Same |
| /finance/payments | finance | `app/finance/payments/PaymentsToolbar.tsx:10`; :34,:41; `page.tsx:96-98` | `date_from`, `date_to` (`paymentRows.ts:32`) | `payment_date` (date NOT NULL, `payments.sql:33`). `gte` :52, `lte` :53 | Client, single-key `onChange` (:21-28) | none | Same |
| /purchasing/orders | `MOD.purchasing` | `app/purchasing/orders/OrdersToolbar.tsx:12`; :36,:43; `page.tsx:112-114` | `date_from`, `date_to` (`orderRows.ts:49`) | `order_date` (date NOT NULL, `purchase_orders.sql:27`). `gte` :86, `lte` :87 | Client, single-key `onChange` (:23-30) | none | Same |
| /inbound | `MOD.inbound` | `app/inbound/InboundToolbar.tsx:17`; :136,:143; `page.tsx:245-247` | `date_from`, `date_to` (`inboundQuery.ts:76`) | `arrival_date` (date, nullable, `inbound_batches.sql:40`). `gte` :177, `lte` :180 | Client. `buildHref(updates)` already takes **several keys** (:51-59); `onFilterChange` pushes one (:71-73) | none | `router.push(buildHref({date_from, date_to, page: null}))`. The helper exists. |
| /output | `MOD.output` | `app/output/OutputToolbar.tsx:16`; :121,:128; `page.tsx:186-188` | `date_from`, `date_to` (`outputQuery.ts:70`) | `output_date` (date, nullable, `output_batches.sql:40`). `gte` :161, `lte` :164 | Client, multi-key `buildHref` (:49-57) | none | Same as inbound |
| /operation/processing | `MOD.processing` | `app/operation/processing/ProcessingToolbar.tsx:8`; :35,:42; `page.tsx:120-122` | `date_from`, `date_to` (`app/operation/processingQuery.ts:40`) | `process_date` (date, nullable, `processing_runs.sql:20`). `gte` :57, `lte` :58 of `app/operation/processingQuery.ts` | Client, multi-key `buildHref` (:17-25) | none | Same as inbound |
| /hr/leave | `MOD.hr` | **No toolbar component.** Inline server `<form method="get">` in `app/hr/leave/page.tsx:65`; DatePickers `:97` (`name="from"`), `:101` (`name="to"`); submit button :103 | `from`, `to` (`leaveRows.ts:40-49`) | `start_date ≥ from` (`leaveRows.ts:69`) AND `end_date ≤ to` (:70). Both date NOT NULL (`leave_requests.sql:12-13`). A request is shown only if it lies **entirely inside** the range. | Server component, GET form + Submit, **uncontrolled** DatePicker (`defaultValue`) | none | `<Link>` built on the server: current params plus from/to (keep status/type/employee/sort/dir). No client JS needed. |
| /inventory/reports/ledger | `MOD.inventory` | **No toolbar component.** Inline server `<form method="get">` in `app/inventory/reports/ledger/page.tsx:89`; DatePickers :95 (`from`), :99 (`to`); hidden sort/dir :91-92; submit :111 | `from`, `to` (`ledgerQuery.ts:57-58`) | `business_date` (date, nullable, `inventory_movements.sql:36`). `gte` `ledgerQuery.ts:122`, `lte` :123. The window does **not** apply when `?movement=` is set (:119-121). | Server, GET form + Submit, uncontrolled DatePicker | **from = last 90 days** (see 1c); to = '' (open) | `<Link>` keeping material_id, batch, sort, dir; drop `movement` |
| /settings/deleted | `requireFunction(FN.deleted)` (action.manage_permissions) | **No toolbar component.** Inline server `<form action="/settings/deleted">` `page.tsx:227`; DatePickers :230 (`from`), :232 (`to`); Submit :233. The kind filter uses `<Link>`s built by `filterHref()` (`page.tsx:140-150`, used at :204). | `from`, `to` (validated by `isYmd`, :120-121) | `deleted_at` (**timestamptz**, via the view `deleted_records`). `gte('deleted_at', from)` :128; `lt('deleted_at', to + 1 day)` :131 (see 1b) | Server, GET form + Submit, uncontrolled DatePicker. Kind links already exist. | none | Easiest: extend the existing `filterHref({from, to})` (it already merges kind/from/to) and render preset `<Link>`s next to the kind links |

**Is there a shared toolbar or date-range component?** No. `app/components/ui/` has `date-picker.tsx` (the only date box on the site) but no range or preset component. A grep for `DateRange|date-range|RangeToolbar` finds only `parseDateRange` call sites. The shared pieces are:
- `lib/dateFilter.ts:5` `isYmd`
- `lib/dateFilter.ts:11` `parseDateRange` (`date_from`/`date_to` only)

The 8 client toolbars are copies of each other ("端口自 …" comments).
- `PnlToolbar` and `CashflowToolbar` are byte-identical except the name. Their `push(from, to)` (`PnlToolbar.tsx:24-32`) is the only two-key writer, and it does **not** delete `page` (those pages have no paging).

**Two param naming schemes:**
- `date_from`/`date_to`: 8 client-toolbar pages plus P&L/cash-flow.
- `from`/`to`: hr/leave, ledger, settings/deleted (all server GET forms), plus change-history and reliability.

### 1b. /settings/deleted — what a date "to" means

```ts
// app/settings/deleted/page.tsx:128-131
if (from) q = q.gte('deleted_at', from)
// to 是一个【日期】,而 deleted_at 是时刻 —— 用当天的下一天做上界,
// 否则当天的记录会被整天漏掉(经典的边界错)。
if (to) q = q.lt('deleted_at', new Date(new Date(to).getTime() + 86400000).toISOString().slice(0, 10))
```

- The JS step is safe. `new Date('YYYY-MM-DD')` parses as UTC midnight, adding 86,400,000 ms gives the next UTC midnight, and slicing gives the **next calendar date string**, with no time and no drift. So "to" is **inclusive through the end of that day**.
- **Which time zone that day is in is never stated in the code.** The bare `'YYYY-MM-DD'` reaches Postgres and is cast to timestamptz in the **session TimeZone**, which is the database-level GUC `Asia/Singapore` (`db/database-settings.sql:24`). That GUC is guarded by `db/fixtures/15-current-date-is-singapore-today.sql` (arm A checks `current_setting('TimeZone')`).
- So both bounds are effectively **SGT midnight**: from = `from 00:00 SGT`, to = `< (to+1) 00:00 SGT`. That matches the SGT display (`formatTrailStamp`, :173).
- It is correct today **by an implicit dependency**. A role-level or session-level TimeZone override would silently move both bounds to UTC.
- Compare `/operation/equipment/reliability/page.tsx:30-37`, which does it explicitly: `new Date(\`${day}T00:00:00+08:00\`)`, with the end bound moved to the next day.

### 1c. Ledger 90-day default

```ts
// app/inventory/reports/reportShared.ts:30-36
export const LEDGER_DEFAULT_DAYS = 90
export function defaultLedgerFrom(): string {
    const d = new Date()
    d.setDate(d.getDate() - LEDGER_DEFAULT_DAYS)
    return d.toISOString().slice(0, 10)
}
```

- It is computed on the **server** (`parseLedgerParams`, `ledgerQuery.ts:57`).
- `setDate` uses the **server process's local TZ**, and `toISOString()` gives the **UTC** date. On a TZ=UTC server, from 00:00 to 07:59 SGT this is "UTC today − 90". That is SG yesterday − 90, so the window is one SG day too long. It is the same class of defect as the P&L one, but it is **not** inside the ruling's "correct P&L and cash-flow".
- **Existing defect worth knowing:** `from: (sp.from ?? '').trim() || defaultLedgerFrom()` (`ledgerQuery.ts:57`) means an empty `from` always becomes the 90-day default. But `reports.ledger.windowNote` promises "Clear the dates to widen it" (`messages/en.ts:4536`, `zh.ts:4421`). Clearing the From box and submitting sends `from=`, which is the default again. **The window can't be widened by clearing.** You can only widen it by typing an earlier date.

### 1d. Uncontrolled DatePicker on the three GET-form pages (risk, not verified)

`DatePicker` with `defaultValue` keeps its value in `useState(() => normalize(kind, defaultValue))` (`app/components/ui/date-picker.tsx:126-127`). The "outside value changed" effect (:145-154) watches `iso`, and in uncontrolled mode that is the component's own state. So **a new `defaultValue` arriving from a soft navigation is not shown** unless the component remounts.

On hr/leave, ledger and settings/deleted, a preset `<Link>` would update the URL and the results. Whether the two boxes also update depends on whether Next remounts the page subtree when searchParams change. **That has to be checked in a browser.** The safe build is `key={from + '|' + to}` on the form or the pickers.

---

## 2. The existing P&L and cash-flow presets

### Code

```ts
// app/finance/pnl/page.tsx:55
const ymdUtc = (d: Date) => d.toISOString().slice(0, 10)
// app/finance/pnl/page.tsx:73-83
    // 默认区间 = 本月;预设:本月 / 上月 / 今年(UTC 口径,与 DB date 同参照)
    const now = new Date()
    const y = now.getUTCFullYear()
    const m = now.getUTCMonth()
    const thisMonth = { from: ymdUtc(new Date(Date.UTC(y, m, 1))), to: ymdUtc(new Date(Date.UTC(y, m + 1, 0))) }
    const lastMonth = { from: ymdUtc(new Date(Date.UTC(y, m - 1, 1))), to: ymdUtc(new Date(Date.UTC(y, m, 0))) }
    const thisYear = { from: `${y}-01-01`, to: `${y}-12-31` }
    const { dateFrom, dateTo } = parseDateRange(sp)
    const from = dateFrom || thisMonth.from
    const to = dateTo || thisMonth.to
```

- The P&L passes presets to `<PnlToolbar presets=[thisMonth, lastMonth, thisYear]>` at `pnl/page.tsx:168-177`.
- Cash flow repeats the same code at `app/finance/cashflow/page.tsx:47` (ymdUtc) and **:65-75**: the comment "预设与损益表【逐字一致】—— 三张报表的"本月/上月/今年"必须指同样的区间", then `now`, `y`, `m`, the three presets and the defaults. The presets array is at :95-100 and passed to `CashflowToolbar` at :149.
- Toolbars: `app/finance/pnl/PnlToolbar.tsx:50-59` and `app/finance/cashflow/CashflowToolbar.tsx:50-59` render one `<Button onClick={() => push(p.from, p.to)}>` each, with label `t('finance.presets.' + p.key)`.
- The comment says "three reports", but only these two have presets. `/finance/balance-sheet` is as-of-only and uses `new Date().toISOString().slice(0, 10)` (`balance-sheet/page.tsx:82`), which is a separate UTC-today defect outside the ruling.

### Which presets

`thisMonth`, `lastMonth`, `thisYear`. There is **no quarter**. **Default** (no params) = thisMonth.

### How the dates are computed

- On the **server** (server component).
- `y`/`m` come from **`getUTCFullYear()`/`getUTCMonth()`**, so the result does not depend on the server's local TZ.
- Bounds are built with `Date.UTC(...)` and formatted with `toISOString()`. Because they are UTC instants rendered in UTC, **`toISOString()` adds no drift**. Day 0 for month end is correct, and so is month −1 across January (`Date.UTC` normalises it).

### What is wrong compared with Singapore time

- **The only defect is which month and year count as "now"**: it is the **UTC** month and year, not the SG one.
- From **00:00 to 07:59 SGT on the 1st of each month**, UTC is still on the last day of the previous month. In that window:
  - the **default range and "This month"** show the **previous** month;
  - **"Last month"** shows the month before that;
  - on **1 January 00:00–07:59 SGT**, **"This year"** shows the **previous** year.
- Outside those 8 hours a month, all results are correct.
- The comment "UTC 口径,与 DB date 同参照" (pnl :73) has been **false since FIN-20**: the DB "today" is Singapore (`db/database-settings.sql:8-12,24`; fixture 15). `lib/format.ts:67-83` records a production instance of this same `toISOString().slice(0,10)` mistake (CONV-7 ②).

### Does either use the financial year?

**No.** `thisYear` is hard-coded to the calendar year `${y}-01-01 … ${y}-12-31` (pnl :79, cashflow :71). Neither page reads `finance_settings`.

---

## 3. finance_settings, the FY definition, and "today in SG" helpers

### 3a. Columns (`db/tables/finance_settings.sql`)

| Column | Line | Type / constraint / default |
|---|---|---|
| `fy_end_month` | :39 | `integer NOT NULL DEFAULT 12 CHECK (fy_end_month BETWEEN 1 AND 12)` |
| `fy_end_day` | :40 | `integer NOT NULL DEFAULT 31 CHECK (fy_end_day BETWEEN 1 AND 31)` (no cross-check against the month) |
| `first_fy_end` | :41 | `date`, nullable. "首个财年可长达 18 个月 … 只影响第一次年结" (COMMENT :157) |
| `system_start_date` | :34 | `date`, nullable |

- COMMENT :155 on `fy_end_day`: **"短月自动收敛到月末(2/30 → 2/28)"**.
- :36-37: "引导默认 12/31 即 Tim 申报的 FYE". The declared FYE is **31 Dec**, so today "this FY" = calendar year, unless live has been changed. **Not queried.**
- Single-row table (`id boolean PK CHECK (id)`, :24).
- **RLS: SELECT needs `module.finance.view`** (:130-133). The cross-module view `finance_settings_lookup` (`db/views/finance_settings_lookup.sql:7-13`, security_invoker = off) exposes **only** `id, gst_registered, gst_rate_pct, default_allocation_basis`. Its row predicate is finance.view OR customers.view OR suppliers.view OR processing.view. Line :3 warns: "加一列等于扩一次权 —— 连着 db/fixtures/194 一起想".
- **Consequence:** of the 11 pages, only the 4 finance pages can read `fy_end_*` today. purchasing, inbound, output, processing, hr, inventory and settings/deleted cannot. A direct read there returns zero rows (RLS) and **no error**.

### 3b. How the year-close defines the FY (the definition presets should reuse)

```sql
-- db/functions/preview_close_financial_year.sql:37-70 (STABLE SECURITY DEFINER; require_permission('module.finance.view') :34)
-- 推导下一个应结财年末:首结看 first_fy_end(申报的长/短首年),否则从
-- system_start 所在年的循环日起;此后 = 上一个仍有效年结之后的第一个循环日。
-- 短月收敛:fy_end_day 超出该月天数时取月末。
...
v_expected := make_date(v_y, v_fs.fy_end_month,
    LEAST(v_fs.fy_end_day,
          EXTRACT(day FROM (date_trunc('month', make_date(v_y, v_fs.fy_end_month, 1))
                            + interval '1 month - 1 day'))::integer));
IF v_expected <= v_prev THEN v_y := v_y + 1; ... END IF;
```

- **FY end in year Y** = `make_date(Y, fy_end_month, LEAST(fy_end_day, days_in_month(Y, fy_end_month)))`. This expression is repeated **4 times inline** (:46-49, :52-55, :60-63, :66-69). It is not a function.
- **FY start is never computed anywhere.** `v_start date` is declared (:29) and never used. The close is cumulative (`je.entry_date <= v_end`, :86), so it never needs a start. The **implied** definition is start = previous FY end + 1 day. For example, fy_end 31 Mar gives this year = 1 Apr (previous year) to 31 Mar.
- **Edge cases under this definition:**
  - fy_end 29 Feb (or 30/31 Feb): **28 Feb in common years, 29 Feb in leap years**.
  - fy_end_day 31 with month 4/6/9/11: the 30th.
  - fy_end **28** Feb in a leap year stays 28 Feb, so 29 Feb starts the next FY. LEAST only clamps down.
  - Because the end date moves, consecutive FYs stay contiguous: start = prior end + 1.
- `first_fy_end` overrides **only the first close** (:42-43). A long or short first year (system_start … first_fy_end) breaks the cycle once.
- `close_financial_year` takes its year end from `preview_close_financial_year(p_year_end)` (`close_financial_year.sql:33`). `assert_posting_allowed` only reads `year_closes.year_end` (:37-41). `set_finance_settings` (:35-36, :76-78) only writes the columns.
- **No TS mirror exists.** `app/finance/close/page.tsx:336` shows `yp.expected_year_end` from the RPC. A grep for `fyEnd|fiscal|financialYear|fyStart` in app/ and lib/ finds no helper.
- **There is no "financial year containing date D" helper, in TS or SQL.** It would have to be written fresh, mirroring the expression above:
  1. E = FYend(year(D)); if D > E, then E = FYend(year(D)+1).
  2. Start = FYend(year(E)−1) + 1 day.
- Related precedent: calendar quarters are `date_trunc('quarter', …)` (`db/functions/open_gst_period.sql:19-20`, GST periods "must be a whole calendar quarter").

### 3c. Existing "today in Singapore" and date-math helpers

| Helper | file:line | Notes / users |
|---|---|---|
| `BUSINESS_TIMEZONE = 'Asia/Singapore'` | `lib/format.ts:65` | Exported; mirror of the DB GUC |
| **`businessToday()`** → `YYYY-MM-DD` SG | `lib/format.ts:84-87` | `Intl.DateTimeFormat('en-CA', {timeZone})`. **~30 call sites**, server and client: e.g. `app/finance/page.tsx:108`, `app/hr/page.tsx:121`, `app/operation/page.tsx:73`, `app/sales/page.tsx:65`, `app/purchasing/page.tsx:71`, `app/logistics/page.tsx:63`, `app/hr/leave/calendar/page.tsx:47` (this month), `app/operation/balance/page.tsx:39`, `app/operation/yield/page.tsx:55`, **`app/compliance/packs/page.tsx:36` (last month = `addMonthsIso(businessToday().slice(0,7)+'-01', -1)`, a ready-made precedent)**, `app/finance/journal/requestActions.ts:67`; client: `date-picker.tsx:156,568`, `finance/bank/TransferForm.tsx:32,55`, and many `max={businessToday()}` |
| `BUSINESS_TIMEZONE` (private copy) | `lib/dates.ts:130` | "与 lib/format.ts 同源。两处必须同改" |
| `toYmd(Date)` → SG date | `lib/dates.ts:328` | Through `fromDate` (:182-195), SG TZ |
| `isoDateIfValid`, `daysInMonthOf`, `addDaysIso`, `addMonthsIso` | `lib/dates.ts:395, 402, 413, 420` | Pure string/UTC arithmetic with no TZ. **Enough for month/quarter/FY bounds** (`addMonthsIso` clamps to month end) |
| `SG_TZ`, `sgParts(d)` | `lib/export/write.ts:17, 20` | Export-only |
| Inline Intl | `app/inbound/[id]/edit/TicketSharesPanel.tsx:28` | Ad hoc |
| `+08:00` literal | `app/operation/equipment/reliability/page.tsx:34` | Day bound |
| DB `CURRENT_DATE` | `db/database-settings.sql:24`; fixture 15 | SG today in SQL |

Same-class defects that **are not** in the ruling (listed only):
- `app/sales/customers/StatementPanel.tsx:43-50` `lastMonth()`: a client component using the **local** clock (`getFullYear/getMonth`), so the SSR TZ and the browser TZ can differ.
- `app/finance/balance-sheet/page.tsx:82`.
- `reportShared.ts:32-36` (above).
- 30 files contain `toISOString().slice(0, 10)`.

---

## 4. "This year / this month / this quarter": through period end or through today? (for Tim)

- **Precedent, both pages: through the period end, future dates included.**
  - thisMonth.to = last day of the month (`pnl/page.tsx:77`, `Date.UTC(y, m + 1, 0)`).
  - thisYear.to = `${y}-12-31` (:79).
  - The **default** range is also the whole month (:82-83).
  - Same in cash flow, :69-75.
- For the 11 lists the difference only shows if rows have future dates. Examples: POs with a future order_date, approved future leave, scheduled inbound arrival_date. In those cases "through period end" shows them and "through today" hides them.
- **Recommendation: through period end** (FY start → FY end, month start → month end, quarter start → quarter end). Reasons: it matches the P&L/cash-flow precedent, the two must stay "逐字一致" (`cashflow/page.tsx:65`), and the result does not change during the period. Write it down as a decision.

---

## 5. Is "today" decided on the server or the client? Hydration

- **P&L / cash flow:** on the **server** (server component `page.tsx`). The toolbar gets finished `{key, from, to}` props, so there is no client date math and no hydration risk.
- **hr/leave, ledger, settings/deleted:** server components, so preset `<Link>`s would be computed on the server. No risk, apart from the remount question in 1d.
- **8 client toolbars:** none computes dates today. If presets were computed in the client toolbar with `businessToday()`, SSR and hydration would only differ when the render crosses SG midnight (businessToday is TZ-pinned, not browser-local). Even so, any rendered output that depends on the date (for example an "active preset" highlight or a title with dates) could mismatch.
- **Recommendation:** follow the P&L precedent. Compute `{key, from, to}` on the server in each `page.tsx` with one pure shared helper, e.g. `datePresets(todaySg, fyEndMonth, fyEndDay)`, and pass the result as a prop. For the 3 GET-form pages, render links.
- The DatePicker already calls `businessToday()` during client render (`date-picker.tsx:156`), but only for the max bound and error text, so it shows nothing until the user acts.

---

## 6. i18n keys that already exist

| Key | en | zh |
|---|---|---|
| `finance.presets.thisMonth / lastMonth / thisYear` | `messages/en.ts:8953-8957` ('This month', 'Last month', 'This year') | `messages/zh.ts:8738-8742` ('本月', '上月', '今年') |
| `datePicker.today / thisMonth / clear` | `en.ts:5368` | `zh.ts:5247` ('今天', '本月', '清空') |
| `listFilters.dateFrom / dateTo` | `en.ts:10744-10747` ('From', 'To') | `zh.ts:10508-10511` ('开始日期', '结束日期') |

- **No `thisQuarter` key anywhere.** No "financial year" preset label (other "financial year" strings are refusal messages, e.g. `en.ts:1249, 9381`).
- The `finance.presets.*` keys sit in the **finance** namespace. The 7 non-finance pages would either borrow it or move to a shared namespace (e.g. `listFilters.presets.*`, with P&L/cash flow pointed there).
- Note (`lib/dates.ts:98-104`): `check-i18n` reads comments that look like `t('…')` calls as real call sites.

---

## Outside the 11 (listed only; the ruling doesn't cover them)

| Route | from/to | Notes |
|---|---|---|
| /finance/pnl, /finance/cashflow | `date_from`/`date_to` | Covered by the ruling's "correct to SG time" (§2) |
| /settings/change-history | `from`/`to`, `isYmd` (`page.tsx:87-88`); GET form `:185`, DatePickers :188 / :192 | Passed to the RPC `change_log_rows` as `p_from/p_to` (:117-119) |
| /operation/equipment/reliability | `from`/`to`; explicit SG bounds `page.tsx:30-37`; GET form :105, DatePickers :108/:112 | Has its own default-range note (:120) |
