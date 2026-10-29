# SYSTEM-MAP-4 — menu clean-up: Tim's 19 items of 2026-10-29 (v1.4.83, 2026-10-30)

Brief: "SYSTEM-MAP-4 — menu clean-up: Tim's 19 items of 2026-10-29 (close-out of GOLIVE-1 first; grilling + survey, then STOP)". Started from
`7c727f660944121fc4dc32c0e820ca128ae273a6`. Tim's rulings on Step 0 (Q1–Q6, 2026-10-30, received 00:21 CST) are recorded in `docs/system-map.md`
("SYSTEM-MAP-4 rulings"). **No migration.**

**Identity of every reading:** database reads were row counts as `postgres` (`rolbypassrls`) on base tables; the reconciliation line as tim@ (rolled
back); COD bytes through the Storage API (list + GET). Pages were read in a real browser through throwaway accounts made by the shared helper
(`scripts/ephemeral.mjs`, prefixes `golive1probe` / `sm4probe` / `survey` / `smoke`), one reader at a time; nothing was pressed and no form was sent.
**Two sub-agents were started (Step 0 only, items 7 and 16); both received the LIVE SAFETY section verbatim, only read code, and neither connected to
live.**

## Part 1 — close-out of GOLIVE-1

| step | reading |
|---|---|
| 1.1 / 1.2 | `db/scripts/2026-10-30-golive-1-closeout-prod-check.mjs` → **`GL1_CLOSEOUT_EXIT=0`** (`readings/part1-prod-check.txt`): one throwaway cfo clone on production — `/contracts` HTTP 200, no error boundary (live has 0 contracts, so no `/contracts/[id]` to open); SUP-2026-0003 (approved) edit page shows row 4's review warning (⇒ production serves bf93b86 / 7c727f6). Nothing pressed. |
| read-back | `readings/part1-readback.txt`: 7 users / 7 enabled, 0 throwaway users / roles / orphan grants, exactly one cfo holder, 11 roles, approvals ON finance/cfo/1000, `require_calibrated_since` NULL, reconciliation AP 0.00 · AR 0.00 |
| 1.3 | `docs/forward-queue.md`: GOLIVE-1 closed — confirmed 2026-10-29 23:50 CST (Tim, relayed), broken window 18:12:03 → 23:50 CST ≈ 5 h 38 min (end point relayed, not measured); GOLIVE-2 scope = rows 9 · 10 · 13 + GOLIVE1-CONTRACT-TERM-COPIES-UNMASKED |

## What each item did

| item | result |
|---|---|
| 1 | `/notifications` child of `/workbench`; the bell and the to-do rows lead to it |
| 3 | Payment terms: button on `/purchasing/orders`, left of "+ New purchase order" |
| 4 | Receiving discrepancies: button on `/inbound`, left of "Field receiving"; home Purchasing → Operation (child of `/inbound`) |
| 5 | Unit converter: fourth card on the Pricing page; home Tools → Purchasing; warehouse reaches it by search only (Q3) |
| 6 | "Stock overview" → "Inventory"; Storage locations · Stocktakes · Scan leave the menu, buttons on `/inventory` (Reports · Scan · Stocktakes · Storage locations) |
| 7 | Runs already recorded start, end and shift (MES-4a); handovers now list the runs of their shift + date (page and new form, read-only); the run list gained Start · End · Shift |
| 8 | Blending plans: button on `/output`, left of "+ Add output" |
| 9 | Yield is the `#yield` section of `/operation/balance` under the same month picker; `/operation/yield` → 307 to it with its filters |
| 10 | Confirm readings leaves the menu; the weighbridge page's link leads to it |
| 11 | Data capture inbox → Equipment, after Instruments and gateways |
| 12 | Reports leave the menu; button on `/inventory`; the four report pages are children of `/inventory` |
| 13 · 15 · 16 | Operation / 运营 · HR / 人事 · ESG / ESG (full Environment, social and governance / 环境、社会与治理) |
| 14 · 19 | Logistics and Equipment first rows read "Overview"; Equipment reliability leaves the menu (the overview links it) |
| 16 (Q1) | ESG Overview (four statements, each by its own code) · Energy intensity · Recovery |
| 17 | COD: button on `/inbound`; home ESG → Operation |
| 18 | Supplier certificates: button on `/suppliers`; home ESG → Purchasing |
| 20 | Tools button → today's date (DD/MM/YYYY, Singapore), every width, opens the calendar; drawer's Tools section removed |

**Registry:** 141 entries (121 menu rows + 20 children) → **144 (110 menu rows + 34 children)**.
**Message lines naming an old name or path rewritten:** en **28**, zh **16** (plus the module labels: 4 lines per language, and 3 retired keys per language —
`nav.stockOverview`, `nav.logisticsOverview`, `nav.equipmentRegister`). zh had fewer because 人事 was already the Chinese label.

## Verify chain (each verdict is the script's own exit line)

| # | step | reading |
|---|---|---|
| 1 | offline gate | **`GATE_EXIT=0`** (`readings/gate-offline.txt`) |
| 2 | backup · dry run · apply · types | not needed — no migration |
| 3 | tsc · build | `TSC_OWN_EXIT=0` · `BUILD_OWN_EXIT=0` (`build.txt`, `build-2.txt` after the date-button padding, `build-final.txt`, `build-for-proof.txt`) |
| 4 | layout survey (before the full gate, so no code changed after it) | 15 pages at **390 px: 15/15 usable, 0 overflow, 0 clipped**; **1280 px: 15/15, 0 / 0** (`layout-390.txt`, `layout-1280.txt`). The handover detail page could not be surveyed: live has 0 handovers (and 0 runs with a shift) — the new-handover form and the list were |
| 5 | bar widths (`widths-1.txt` → `widths-2.txt`) | first reading: English at 1280 overlapped by 3 px (date button 101.6 px); padding 12 → 8 px (93.6 px) → English fits from 1275 px, Chinese from 1068 px; breakpoint stays 1280 |
| 6 | full gate on the final code | **`GATE_EXIT=0`** (`gate-full.txt`, 01:03 → 01:21 CST) |
| 7 | i18n · error-swallowing | `I18N_OWN_EXIT=0` · `SWALLOW_OWN_EXIT=0` |
| 8 | smoke | run 1 stopped by **my own watchdog bug** 9 s in (its health parser printed nothing and read that as unhealthy; no database signal): `SMOKE_EXIT=143`, cleanup done, read-back 0 residue (`smoke-run1-*.txt`, `readback-after-smoke-run1.txt`). Run 2 with the fixed watchdog: **`SMOKE_EXIT=0` — 348 ok, 24 skipped (no data), 0 FAILED**, 01:22:57 → 01:58:53; watchdog never fired, in-db `select 1` ≤ 1 ms, db / rest healthy every minute (`smoke.txt`, `smoke-watchdog.txt`) |
| 9 | live proof, seven roles one at a time | **`SM4_PROOF_EXIT=0`**, all PASS (`live-proof.txt`, `live-proof.json`): every bar = Workbench · Purchasing · Operation · Quality · Sales · Logistics · Finance · HR · ESG · Equipment; every menu row = registry for that role; each entry under exactly one module; none of the 14 departed entries in any menu; every new button present in the ruled order and leading to its page (HTTP 200); the date button reads Singapore's today and opens the calendar at 1440 and 390 px; the 390 drawer = 10 modules + Settings only; yield 307 → `#yield`; ESG pages per registry. One warning recorded: a single round trip of 3,942 ms before warehouse (not an abort). No reader on live lacked a button's target, so the restricted rendering was not exercised on live — it is the code path shared with menu rows |
| 10 | read-back after proof | `readback-after-proof.txt`: 0 throwaway users / roles / grants, exactly one cfo holder, 11 roles, approvals ON, reconciliation 0.00 |
| 11 | COD bytes | `cod-bytes.txt`: COD-2026-0001 34,701 bytes `ba299a4f…`, COD-2026-0002 34,746 bytes `717661f6…` — identical to the AGENTS.md baseline |
| 12 | fresh clone of 327b131, no `.env.local` | `npm ci` `CI_OWN_EXIT=0` · `npm run build` **`FRESH_OWN_EXIT=0`** (`readings/fresh-clone-build.txt`) |
