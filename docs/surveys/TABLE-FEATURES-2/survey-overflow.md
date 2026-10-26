# TABLE-FEATURES-2 · Survey — the two 390 px toolbar-select overflows

**Method:** read-only source and docs reading (2026-10-26). **Nothing was measured for this survey**: no browser, no build, no dev server,
no script, no DB. Every px number below is copied from a committed reading, and its file is cited. Anything without a reading is marked **inferred**.

---

## 0 · The two registered overflows (what was measured, and when)

| Page | Reading | Overflow | Culprit (probe prints only the first 60 chars of the class) |
|---|---|--:|---|
| `/purchasing/orders` | `docs/surveys/TABLE-FEATURES-1/readings/layout-390.txt:14`, `:31` (file mtime 2026-10-25 21:28) | **+59** | `select.h-8 rounded-lg border border-input bg-transparent pl-2.5 pr-` |
| `/purchasing/orders` on an untouched f156ee1 tree | `docs/surveys/TABLE-FEATURES-1/readings/layout-390-baseline-f156ee1-purchasing-orders.txt:8`, `:17` | **+59** | same |
| `/inbound` | `docs/surveys/TABLE-EXPORT-2b-2/readings/layout-390.txt:14`, `:36` (mtime 2026-10-23 20:45) | **+59** | same |
| `/inbound` with `page.tsx` reverted to HEAD 2249696e | `docs/surveys/TABLE-EXPORT-2b-2/readings/layout-390-inbound-before.txt:8`, `:17` | **+59** | same |
| both pages, one day earlier | `docs/surveys/TABLE-EXPORT-1/readings/layout-390.txt:9` (`/inbound`), `:16` (`/purchasing/orders`) (mtime 2026-10-22 20:36) | **0** | — |

Registrations: `docs/known-issues.md:11711` (PURCHASING-ORDERS-390-SUPPLIER-SELECT), `docs/known-issues.md:11623` (INBOUND-TOOLBAR-390-OVERFLOW);
`docs/handbacks/TABLE-EXPORT-2b-2.md:50`, `:67`; `docs/handbacks/TABLE-FEATURES-1.md:48`.
Both entries name "live data widened a select" as the cause and say that is **inferred, not measured per option** (`docs/known-issues.md:11628`, `:11716`).

The class string the probe prints is `CONTROL_SELECT`. It is built at `app/components/ui/control-style.ts:128` from
`BOX` `h-8` (`:68`) + `SHAPE` `rounded-lg border border-input bg-transparent` (`:71`) + `PAD_SELECT` `pl-2.5 pr-6 py-1` (`:84`) + … .
**Every toolbar select in the repo has this same string**, so the probe's culprit text cannot tell which select on a page it means (see §5).

---

## 1 · `/purchasing/orders` — `app/purchasing/orders/OrdersToolbar.tsx`

**Markup (verbatim):**

- Container `:33` — `<div className="mb-4 flex flex-wrap items-center gap-3">`
- Children in order: `<label className="">` + `DatePicker` (`:34-40`), `<label className="">` + `DatePicker` (`:41-47`),
  **supplier select `:48-59`**, status select `:60-71`.
- Supplier select `:48` `<select`, `:51` `className={CONTROL_SELECT}` (no other class), first option `:53` `t('purchasing.filterAllSuppliers')`,
  data options `:54-58` → `{s.name}` (`:56`).
- Status select `:60`, `:63` `className={CONTROL_SELECT}`, options from the constant `STATUSES` (`:10`). Its text comes from fixed translation keys, not from data.

**Option text source:** `app/purchasing/orders/page.tsx:78-84`: `supplier_lookup` `.select('id, legal_name')`, `.is('deleted_at', null)`,
`.neq('counterparty_type', 'forwarder')`, `.order('legal_name')`. It is mapped to `name: s.legal_name` (`:86-87`) and passed in at `:113`.
**So the option text is each non-forwarder supplier's full legal name.** Which name is the longest today was not read (no DB queries in this survey).

**Ancestors:** `<ListPage>` (`page.tsx:96`) renders `<div className={[padding ?? 'p-8', maxWidth]…}>` (`app/components/ui/list-page.tsx:137`).
On a 390 px phone that leaves 326 px of content width. 326 is the same "available width" figure the repo's earlier readings use
(`docs/variant-c-spec.md:475`, `docs/agents/measurement-lessons-history.md:166`). The root `<body className="min-h-full flex flex-col">`
(`app/layout.tsx:185`) is a column flexbox, so page width is not driven by content along that axis.

**Mechanism (from source + the repo's own lessons; the select's own min-content was not measured):**

1. The container **already has `flex-wrap`** (`:33`). So the INPUT-2b cure ("give the non-wrapping container `flex-wrap`",
   `AGENTS.md:2461-2465`) **is already in place and is not enough**. This is the FONT-1 M12 situation exactly:
   `docs/agents/measurement-lessons-history.md:162-171` ("the container is already `flex-wrap`, the culprit is one atomic control, wrapping cannot split it").
2. The select is a direct flex item with no width class. That gives it `flex-basis: auto` = max-content, and `min-width: auto` = its min-content.
   For a native `<select>` the min-content is the longest `<option>` text + `pl-2.5` + `pr-6` + border (`control-style.ts:47-49`; `measurement-lessons-history.md:120-123`).
3. With wrapping, the select gets a line to itself but still cannot shrink below its min-content. **Inferred** width ≈ 326 + 59 = **385 px**
   (derived from the reading; not measured as an element width).
4. This is `AGENTS.md:2544-2546`: when one indivisible child sets the min-content, "换行、`flex-shrink`、`min-w-0` 全部无效"
   (wrapping, `flex-shrink` and `min-w-0` all do nothing) at the container level. The width bound has to go on the select itself.

---

## 2 · `/inbound` — `app/inbound/InboundToolbar.tsx`

**Markup (verbatim):**

- Container `:77` — `<div className="mb-4 flex flex-wrap items-center gap-3">` (**byte-identical to OrdersToolbar `:33`**)
- Search `:78-84`: `className={`${CONTROL_INPUT} w-60 max-w-full`}` (`:83`). The search box is already bounded.
- Stage select `:85`, `:88` `className={CONTROL_SELECT}`, options from the constant `STAGE_OPTIONS` → `t(o.labelKey)` (`:91-95`)
- **Supplier select `:97`**, `:100` `className={CONTROL_SELECT}`, data options `:103-107` → `{s.label}` (`:105`)
- **Material select `:109`**, `:112` `className={CONTROL_SELECT}`, data options `:115-119` → `{m.label}` (`:117`)
- Pricing-status select `:122`, `:125` `className={CONTROL_SELECT}`, constant `PRICING_STATUS_VALUES` (`:128-132`)
- Two `<label className="flex items-center gap-1">` + `DatePicker` (`:134-147`)

**Option text sources** (`app/inbound/page.tsx`):
- Supplier: `supplier_lookup` `.select('id, legal_name, counterparty_type')` `.order('legal_name')` (`:77-82`). Forwarders are dropped in TS
  (`:145-147` `.filter((s) => s.counterparty_type !== 'forwarder').map((s) => ({ id: s.id, label: s.legal_name }))`).
- Material: `material_lookup` `.select('id, name')` (`:84-87`) → `label: m.name` (`:130-134`).

**Which select is the culprit — inferred, not measured:** the probe's culprit text is the same for all four selects (§0). Three points suggest the **supplier** select:

- The supplier option set is the same as on `/purchasing/orders`: same view, same `deleted_at` filter, same forwarder exclusion
  (SQL `.neq` at orders `page.tsx:83` vs TS `.filter` at inbound `page.tsx:146`).
- Both pages read exactly **+59** in the same container shape.
- Both went 0 → +59 in the same window (2026-10-22 20:36 → 2026-10-23 20:45, §0).

A different select (material) producing the identical 59 px would be a coincidence.
**Not proven:** the probe JSON keeps the top 4 culprits with `right`/`width` (`scripts/survey-phone.mjs:256-260`, `:343`), but the `.survey-out/` JSON is not committed.
A fix cut must bound the **material** select at `:109` too. It has the same shape, and `material_lookup.name` is data-driven.

---

## 3 · Toolbars with the same shape that do NOT overflow (as of their last reading)

**There is no structural difference. They use the same container classes and the same `CONTROL_SELECT`. What differs is the length of their longest option text today.**

| Page | File:line (container · select) | Verbatim classes | Option text | Last 390 reading |
|---|---|---|---|---|
| `/output` | `app/output/OutputToolbar.tsx:75` · customer `:95`/`:98`, material `:107`/`:110` | container `mb-4 flex flex-wrap items-center gap-3`; selects `{CONTROL_SELECT}` | `customer_lookup.legal_name` (`app/output/page.tsx:71-72`, `:115`); `material_lookup.name` (`:76`, `:120`) | **0**, `docs/surveys/TABLE-EXPORT-1/readings/layout-390.txt:15` (10-22 20:36, **before** the window in which the other two broke) |
| `/finance/expenses` | `app/finance/expenses/ExpensesToolbar.tsx:36` · account `:60`/`:63` | same / `{CONTROL_SELECT}` | `{a.code} {a.name}` (`:67-69`) | **0**, `docs/surveys/TABLE-EXPORT-2a/readings/layout-390.txt:15` (10-23 00:52) |
| `/hr/leave` | `app/hr/leave/page.tsx:65` form · type `:77`, employee `:88` | form `flex gap-2 flex-wrap items-end mb-4`; wrapper `<label className="">`; select `` `block ${sel}` `` with `sel = CONTROL_SELECT` (`:50`) | type `name_zh/name_en` (`:81`); employee `{e.code} — {e.legal_name}` (`:91`) | **0**, `docs/surveys/TABLE-FEATURES-1/readings/layout-390.txt:10` (10-25) |
| `/hr/claims` | `app/hr/claims/page.tsx:58` form · employee `:68` | form `flex gap-2 flex-wrap items-end mb-4`; `` `block ${sel}` ``, `sel = CONTROL_SELECT` (`:44`) | `{e.code} — {e.legal_name}` (`:71`) | **0**, `docs/surveys/TABLE-EXPORT-2b-2/readings/layout-390.txt:8` (10-23) |
| `/hr/reviews` | `app/hr/reviews/page.tsx:88` form · cycle `:91`, employee `:118` | same as leave; `sel = CONTROL_SELECT` (`:66`) | cycle `c.name`; `{e.code} · {e.legal_name}` (`:122`) | **0**, `docs/surveys/TABLE-EXPORT-2b-2/readings/layout-390.txt:12` (10-23) |

**Pages that DO bound the select. These are the repo's precedents, each with a reading:**

| Where | Verbatim | Context | Reading |
|---|---|---|---|
| `app/settings/approvals/ApprovalsForm.tsx:130`, `:167` | `` `${CONTROL_SELECT} max-w-full` `` | select in a **block** `<div>` (not a flex item), parent `space-y-3 max-w-2xl` (`:121`) | 390 px select 639 → 292, page 298 → 0; 1280 px 566 → 566 (`docs/handbacks/MES-9a.md` §8; `docs/surveys/MES-9b/MES-9a-CLOSEOUT.md:55`) |
| `app/settings/change-history/page.tsx:196` (+ siblings) | select `` `${CONTROL_SELECT} max-w-full` ``; label `flex flex-col gap-1 min-w-0 max-w-full` (`:186`…); form `flex flex-wrap items-end gap-2 mb-4 text-sm` (`:185`) | select inside a column-flex label that is the flex-wrap item; comment `:184` cites the approvals precedent | +21 → 0 (`docs/handbacks/MES-9c.md:77-78`); 0 again at `TABLE-EXPORT-2b/readings/layout-390.txt` (10-23) |
| `app/operation/processing/new/NewProcessingForm.tsx:663` | `` `${CONTROL_SELECT} flex-1 basis-full sm:basis-0 min-w-0 max-w-full` `` | select as a **direct flex item sharing a row** | +177 → 0; with only `min-w-0 max-w-full` it shrank to **95 px** on the shared row, hence `basis-full sm:basis-0` (`docs/handbacks/MES-5a-2.md:145-147`, `docs/forward-queue.md:533`) |
| `/purchasing/orders/new` category select | `` `${CONTROL_SELECT} max-w-full` `` + form `space-y-6 max-w-full` | — | +120…+246 → 0 (`docs/known-issues.md:11311-11313`) |
| `app/portal/certificates/page.tsx:134` | `` `${CONTROL_SELECT} w-full max-w-full` `` in label `block text-sm min-w-0 basis-full sm:basis-0 flex-1` (`:132`) | flex-wrap row (`:131`) | — |

**Shared components:**
- `app/components/ui/select.tsx` is the Radix select, not a native `<select>`. Its trigger is `flex w-fit …` (`:47`). It is used only by
  `app/settings/accounts/CreateAccountPanel.tsx` and `app/brand-sampler/Variant.tsx`. **None of the list toolbars use it.**
- `app/components/ui/input.tsx` emits `INPUT_COMPONENT_CLASS`, which contains `w-full min-w-0` (`control-style.ts:266-269`). That applies to `<Input>` only.
- **`CONTROL_SELECT` deliberately carries no width rule.** `control-style.ts:41-57`: "这个文件里一个 `w-*` 都不许出现" (no `w-*` class may appear in this file).
  The only width-like classes in the file are `max-w-0 min-w-full` on `CONTROL_TEXTAREA` (`:167`, BUGFIX-1a).

---

## 4 · Candidate fix and by-shape candidates

### 4.1 ⚠ A written rule stands in the way — this needs Tim's ruling before any fix

`docs/variant-c-spec.md:474` (§4.1d, INPUT-2b, Tim 2026-09-11) says: **"不许加 `min-w-0`,也不许加 `max-w-full`"** (do not add `min-w-0`; do not add `max-w-full`) on a native select.
The measured reasons are at `:475` and `:507-512`:
- `min-w-0` collapsed a `flex-1` select **364 → 70 px**, so every option was clipped.
- `max-w-full` alone did nothing (364 px stayed 364 px).

`:1384` restates that the ban "原样有效" (still stands as written) for `<select>`.

**But the code base has since broken that ban four times, each with a reading:** MES-9a, MES-9c, MES-5a-2 and MES-8b-1 (§3 table).
MES-5a-2 cites "the ruling's `min-w-0 max-w-full`" (`docs/handbacks/MES-5a-2.md:146`; `docs/forward-queue.md:513`). The spec text was **not updated** to record that relaxation.
A TABLE-FEATURES-2 fix should either cite that later ruling or get a fresh one, and should update §4.1d either way.

**Information-loss cost (the reason for the ban, `variant-c-spec.md:1362`):**
- A bounded select displays a long supplier name clipped in its **closed** state on a phone. **Inferred** loss: about the last 59 px of the longest name, and only when that supplier is the selected one.
- The default "All suppliers" option is short and is not affected.
- The native picker that opens on iOS lists the full option text. That is platform behaviour, not measured here.

### 4.2 Candidate one-liner (per select, at the call site; `control-style.ts` unchanged)

```
className={`${CONTROL_SELECT} max-w-full`}
```

- **Why it should work here (inferred from the flex spec, NOT measured):**
  - These toolbar selects have no `flex-1`, so their flex-basis is `auto`. The 364 → 70 collapse came from `flex-1` (basis 0%) (`variant-c-spec.md:507-509`).
  - The flex item's automatic minimum (`min-width:auto`) is clamped by a definite `max-width`.
  - The toolbar's width is definite: block `<div>` → `ListPage` `p-8` div → column-flex `<body>`.
  - The approvals / change-history / orders-new precedents read 0 with exactly this class.
- **Why it might not:** INPUT-2b measured `max-w-full` alone as having no effect on `/sales/orders/new` (`variant-c-spec.md:511`). FONT-1 measured it as having no effect behind a `<fieldset>`
  (`:1363`: "百分比 `max-width` 在内在尺寸计算里当 `none`" — a percentage `max-width` counts as `none` when intrinsic sizes are computed). Neither toolbar has a fieldset ancestor in source. That was checked only for the files cited above; the full ancestor chain was not read rendered.
- **Fallback, in order** (each must be injected and read, per `AGENTS.md:2539-2546`):
  1. `min-w-0 max-w-full`. Risk: shrinking to the row's leftovers (the 95 px case).
  2. `min-w-0 max-w-full basis-full sm:basis-0`. This is the MES-5a-2 shape, and it gives the select its own row below 640 px.
- **Desktop guard:** at 1280 px the longest option (~385 px, inferred) is far below the toolbar's width, so the cap should not bind. Each fix still needs a 1280 px reading.

### 4.3 By-shape candidates: same `<select>` + data-driven option text + flex-wrap row, no width bound

**These are by-shape candidates, not measurements.** Each is "0 at its last reading", and each can break on its own when a long name is added to its source table.

| # | Page | File:line (select / className) | Container (verbatim) | Option text source |
|---|---|---|---|---|
| 1 | `/purchasing/orders` | `OrdersToolbar.tsx:48` / `:51` | `:33` `mb-4 flex flex-wrap items-center gap-3` | supplier `legal_name` — **measured +59** |
| 2 | `/inbound` supplier | `InboundToolbar.tsx:97` / `:100` | `:77` same | supplier `legal_name` — **measured +59 (select inferred)** |
| 3 | `/inbound` material | `InboundToolbar.tsx:109` / `:112` | `:77` same | `material_lookup.name` |
| 4 | `/output` customer | `app/output/OutputToolbar.tsx:95` / `:98` | `:75` same | `customer_lookup.legal_name` — **last read 0 on 10-22, before the window; highest-risk unmeasured** |
| 5 | `/output` material | `OutputToolbar.tsx:107` / `:110` | `:75` same | `material_lookup.name` (same list as #3) |
| 6 | `/finance/expenses` | `app/finance/expenses/ExpensesToolbar.tsx:60` / `:63` | `:36` same | `{a.code} {a.name}` |
| 7 | `/hr/employees` | `app/hr/employees/EmployeesToolbar.tsx:50` / `:53` | `:33` same | `departments` → `d.label` (`app/hr/employees/page.tsx:60-66`) |
| 8 | `/materials` | `app/materials/MaterialToolbar.tsx:71` / `:74` | `:63` same | kind `name_zh / name_en` |
| 9 | `/tools/pricing/metal-prices` | `MetalPricesToolbar.tsx:42` / `:45` | `:41` same | `substanceOptions` → `o.label` |
| 10 | `/hr/leave` type, employee | `app/hr/leave/page.tsx:77`, `:88` (`` `block ${sel}` `` same line) | `:65` `flex gap-2 flex-wrap items-end mb-4`, inside `<label className="">` | `name_zh/en`; `{e.code} — {e.legal_name}` |
| 11 | `/hr/claims` employee | `app/hr/claims/page.tsx:68` | `:58` `flex gap-2 flex-wrap items-end mb-4`, inside `<label className="">` | `{e.code} — {e.legal_name}` |
| 12 | `/hr/reviews` cycle, employee | `app/hr/reviews/page.tsx:91`, `:118` | `:88` same as leave | `c.name`; `{e.code} · {e.legal_name}` |
| 13 | `/hr/kpi/score` | `app/hr/kpi/score/page.tsx:198` / `:200` `{CONTROL_SELECT}` | form `:193` `mb-6 flex flex-wrap items-end gap-2`, wrapper `<div>` `:194` | `c.name` (cycle names; low risk) |
| 14 | `/finance/fx` | `app/finance/fx/FxToolbar.tsx:28` / `:31` | `:27` same | currency codes (low risk) |

The pages in rows 10–12 wrap the select in a `<label className="">` with `block` on the select.
So the flex item is the label, and the label's min-content is the select's. The cap would go on the select, plus `max-w-full` on the label, as in the change-history shape (`:186`).

Excluded: toolbars whose options are all fixed translation keys. These are status selects, `PaymentsToolbar.tsx:46`, `InvoicesToolbar.tsx:46`/`:58`,
`StatementsToolbar.tsx:30`/`:39` (hard-coded options), and `TrainingToolbar.tsx:28`/`:40`.

---

## 5 · The probe: `scripts/survey-phone.mjs` (read, not run)

**Do not import it:** it calls `onlyWhenRunDirectly` (`:69`), mints a throwaway all-codes account on live (`mintThrowaway`, `:458`), and starts `next dev` on 3198 (`:72`).

- **Usage:** `:26`: `node scripts/survey-phone.mjs [--limit=N] [--only=/prefix] [--routes=/a,/b] [--paths=/concrete/url,…] [--width=N]`. The default width is 390 (`:75`).
- **`--routes` does NOT take query strings.**
  - It is parsed with `.split('=')[1]` (`:809`), so the value is cut at the first `=`.
  - Each entry must match a route pattern in the resolved route list exactly (`want.has(t.route)`, `:813-814`). Anything else throws "--routes named routes that are not measurable" (`:816`).
- **`--paths` DOES take query strings.** It reads the whole remainder after `--paths=` (`:823`, AUDIT-TRAIL-1d-3 comment `:821-822`). It records `pathname + search` (`:318`).
  - The two flags are merged when both are given (`:826`).
  - This was used in practice: `docs/surveys/TABLE-FEATURES-1/readings/layout-kpi-score-concrete.txt:8` measured `/hr/kpi/score?cycle=…`.
  - ☞ **The memory claim "only takes routes" is out of date.** For a filtered state such as `/purchasing/orders?supplier=<id>`, use `--paths`.
- **Overflow:** `overflowPx = round(max(documentElement.scrollWidth, body.scrollWidth) − documentElement.clientWidth)` (`:232-235`).
- **Culprits** (`:247-263`):
  - It collects every element whose `getBoundingClientRect().right > vw + 1` and which is not inside an `overflow-x: auto|scroll` ancestor.
  - It sorts them deepest first and keeps the top 4 with `tag`, `cls` (120 chars), `right`, `width` and `depth` (`:343`).
  - The summary line prints only `culprits[0]` with the class cut to **60 chars** (`:985`). That is why all toolbar selects read identically.
  - The probe does not report option text or min-content.
- **Self-test:** it fault-injects a wide element and a clipped table, and refuses to give readings if it cannot see them (`:770-797`).
- **Preconditions:** it refuses to run when `.next/BUILD_ID` exists, i.e. on a production build (`:653`; `AGENTS.md:2142`). It writes `.survey-out/phone-390.json` (`:945`).
- **What it cannot see:** anything behind an interaction, and soft navigation (`:4-11`, `:47-50`). A selected long supplier is only on screen if it is loaded through `--paths` with the query string.

**What a fix cut has to read** (not done here):
1. The rendered width of each data-driven select at 390 px, before and after the fix, on one DOM.
2. 1280 px widths unchanged.
3. Whether the longest name in the closed state is clipped when it is the selected value.

This needs an injection probe or the survey with `--paths=/purchasing/orders?supplier=<longest-id>`.
