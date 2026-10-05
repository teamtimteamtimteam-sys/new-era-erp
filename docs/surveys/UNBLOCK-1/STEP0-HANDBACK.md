# UNBLOCK-1 Step 0 — hand-back: **step 1 (DATE-PICK-1 close-out) only; Step 0 NOT started** (2026-10-05)

**Why Step 0 did not start:** the brief's step 1.5 — "If ANY of a–f is missing or only partly done: do NOT fix it and do NOT start step 2."
Item **f is only partly done** (§1.3 f below): `docs/forward-queue.md` marks DATE-PICK-1 complete in three places and the "DATE-1 的选择器那一半"
row of the 甲 index complete, but **the picker half's own home row still reads open, and a second row still says it is waiting on Tim**.
I did not fix it. Everything else in step 1 is present. No grilling, no live measurement of UNBLOCK-1 items, no code, no migration.

**Opening check** (this session's first command, 2026-10-05 ≈ 14:55 CST): tree clean apart from Tim's untracked
`docs/Data capture and ERP integreation.pdf` (not touched); after `git fetch`, `HEAD` = `origin/main` = `ls-remote origin main` =
`b1a9c0cd81d785437fc45a71b95dcca52819fabb`.
**Live state, re-measured (read-only, 15:00:18 CST, as `postgres`, `rolbypassrls = true`, Management API, base tables `auth.users` and
`finance_settings`):** 7 accounts · 0 disabled (`banned_until > now()`) · 0 `@test.local` throwaways · approvals `true / finance / cfo / 1000`.
Matches the brief. No write of any kind was made to live.

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

## §2 · What Tim needs to decide before Step 0 runs

**Q-f · The stale picker-half rows.** Recommended answer: **authorise a docs-only fix as the first act of the next block** — strike the
`:6409` row with a ✅ pointer to DATE-PICK-1 (`v1.4.34`) and amend `:6458` to say the picker cut is done (not waiting on DATE-0 Q1), keeping the
original text struck through per the repo's rule — then run UNBLOCK-1 Step 0 as briefed. Evidence: §1.3 f. Cost: two edits, one commit,
no measurement; it changes no meaning anywhere else (the 甲 index row and item 33 already say ✅).

## §3 · Assertions in the brief that I measured and found false or imprecise

1. "the five pages that overflow at 390px (**measured identical with the native box restored**)" — true for **four**. `/sales/quotes/[id]`
   was not swapped: its default view has **no date box at all** (probe: `默认画面里没有日期框,溢出与它无关 溢出 0px · 日期框 0 个`).
   The known-issues entry says this rather than "identical".
2. "Record in docs/forward-queue.md that DATE-PICK-1 had no migration" — **already recorded** in item 33 by DATE-PICK-1 itself; this close-out
   added the measured basis and the push time, not the fact.
3. DATE-PICK-1's own hand-back §9 says 'the "DATE-1 的选择器那一半" row is ✅' — true of the 甲 index row only; the home row is not (§1.3 f).

Everything else re-measured matched: SHAs, clean tree, 7 accounts / 0 disabled, approvals finance / cfo / 1,000, v1.4.34's tester line.

## §4 · Stop

Step 2 (UNBLOCK-1 Step 0 grilling) **not started**. Waiting on Tim's answer to Q-f.
