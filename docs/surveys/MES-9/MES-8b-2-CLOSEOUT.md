# MES-8b-2 close-out (2026-10-19)

Brief: "MES-8b-2 close-out + MES-9 Step 0", step 1. Docs only — no code edit, no database change. Live writes: only the throwaway accounts of §3 / §4
and their own records, all removed (§5).

**Opening check (09:59:02 CST, this session's first command).** Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
`4236db6a01d3328ed18cf9a594d9a18f5dd13b6f`. No git command refused.

## 1 · Broken window (1.1)

| | Time (CST) | Source |
|---|---|---|
| start | **2026-10-17 13:42:39** | measured: `db/migration-windows.tsv:240` (`2026-10-17-mes8b2-wall-display.sql`) |
| end, lower bound | **2026-10-19 09:49:03** | measured: `git reflog show --date=iso refs/remotes/origin/main` → `4236db6a refs/remotes/origin/main@{2026-10-19 09:49:03 +0800}: update by push`; the push `91083d75..4236db6a` carried only the cut's own commit `4236db6a` (committed 2026-10-19 09:47:29) |
| end, upper bound | **2026-10-19 09:59:02** | derived: this session's first command (`date`), with Tim's "deployed" already in hand — a report of what Tim saw, not a reading of Vercel |

**Broken window: at least 44 h 06 min 24 s, at most 44 h 16 min 23 s.** It is long because the cut's commit was made and pushed two days after its
migration (closing readings 2026-10-17 14:35:26; commit 2026-10-19 09:47:29), not because of the deploy.

**What landed on live inside the window** (`mes8b2-closeout-readings.sql`, as `postgres`, `rolbypassrls = true`, base tables, `READ_OWN_EXIT=0`, 10:03:19 CST):
- 13:42:39 → 14:35:26 (10-17): only MES-8b-2's own proof / smoke throwaways — roles 12 / 12, user_roles 13 / 13, role_permissions 650 / 650, employees 9 / 9,
  performance_reviews 4 / 4 (+4 updates), contracts 2 / 2 with their six term tables 1–2 / 1–2, one `cod_verification_failures` row in and out. Every INSERT
  has its DELETE. This is exactly the set the MES-8b-2 hand-back §11 lists.
- **14:35:26 (10-17) → 09:59:02 (10-19): 0 change-log rows.** Nothing at all was written to a logged table in the 43 h before the push and the deploy,
  colleagues included. Change log 55,961 rows / max seq 60,611 — identical to MES-8b-2's closing reading.
- State at 10:03 today: role `floor_display` exists, 0 holders; `data.view_floor_board` held by admin · cfo · floor_display; catalogue 85 (module 35 ·
  action 38 · data 12); 7 accounts, 0 banned, roles admin · finance · warehouse · cto · cco · cfo · gm (one each, unchanged); approvals on, finance / cfo / 1,000;
  `locked_before` 2026-08-01; `require_calibrated_since` NULL; COD-2026-0001 / -0002 sha256 `ba299a4f…f42101` / `717661f6…13a4f9`, objects 34,701 / 34,746 bytes,
  eTags `7fcb4d67…` / `b9f5e8e1…` (identical); views 197, writable (view, role) pairs **0**; pending documents `CLM-2026-0004` only; tables 321; V28 unset.

What was broken inside it (derived — MES-8b-2 hand-back §12): nothing in use. With zero writes after 14:35 there was also nothing for the old app to
mis-write.

**The deployed app is `4236db6a`'s code** (measured in §4: `/display` with 23 count tiles, the display refusal on other routes, the "Kind not stated" list
and the month-end scroller exist only from this commit).

## 2 · Tim's ruling recorded (1.2)

`data.view_floor_board` held by **floor_display · admin · cfo** is **accepted as built** (MES-8b-2 decision 3; Tim 2026-10-19). Written into
`docs/forward-queue.md` item 57 and `docs/role-matrix.md` (the `/display` row and the code row).

## 3 · SESSION-1 manual repro, on the deployed app (1.3)

The repro (`docs/known-issues.md`, "手工复现步骤 … 任何动到 `lib/supabase/middleware.ts` … 之后,按这个走一遍") was walked in a real browser
(chrome-headless-shell driven by puppeteer-core) against **https://new-era-erp.vercel.app**, as one throwaway account
(`mes8b2probe-…-co-s1@test.local`, a throwaway role holding `module.inventory.view` + `module.inventory.edit`). Script:
`docs/surveys/MES-9/mes8b2-closeout-probe.mjs`; log verdict `CLOSEOUT_PROBE_EXIT=0` (second run — see §6).

| Step | What was done | Result |
|---|---|---|
| 1 | sign in through the `/login` form (email + password) | **PASS** — landed on `/`, auth cookie set (1 part) |
| 2 | `/inventory/locations/new`, code = an **existing** location's code (`SG2026081201`), submit | the form opened; the database refused the duplicate before writing any row |
| 3 ① | the localized named refusal is shown | **PASS** — "Location code SG2026081201 is already in use. Codes identify a physical place, …" |
| 3 ② | session survives | **PASS** — no `Set-Cookie` clearing the auth cookie (`Max-Age=0`) in any response of the submission; reload stays on the page; cookie still present |
| 4 | a **successful** submission and a form in **another module**: `/me` → avatar upload, then "Remove" | **PASS** both — the object `avatars/<my uid>.webp` appeared, then was gone; no auth cookie cleared in either submission's `Set-Cookie`; reload after each stays on `/me` |
| 5 | the cookie's stored `expires_at` moved one hour into the past (tokens untouched) — a tab left open for an hour — then 2–4 again | **PASS** all: the server refreshed the session (new refresh token, `expires_at` +1 h); duplicate refusal shown, session alive; upload and removal succeed, session alive after each |

**Skipped / changed, and why:**
- Step 2 uses an **existing** location's code instead of one of my own: `storage_locations` has no hard-delete path (`guard_storage_location_no_hard_delete`,
  `app/inventory/locations/actions.ts:9-11`), so a location I created could never be removed. The existing location is only compared against inside the
  refused statement; nothing of it is read back, changed or decided. 0 `storage_locations` rows in the change log since this session began.
- Step 4's successful submission is the avatar form, not a second location (same reason). Its only record is a storage object named after my own throwaway
  account's uid; the form removed it, the script removed it again by name at exit and read back "not there".
- Step 1 runs the repro against the deployed app, not `npx next dev -p 3210` as the text says — the brief asks for the deployed app.

**No session regression.**

## 4 · Read-only verification (1.4)

### a · The MES-8b-2 brief's fixture list, item by item

The list is the brief's "Fixtures must cover:" sentence (the brief lives only in the MES-8b-2 session transcript; quoted verbatim in item order). Fixture
paths: `db/fixtures/271-…-valued-at-its-metals.sql` (271) and `db/fixtures/273-a-wall-display-…-idle.sql` (273).

| # | Item | Covered by | Evidence |
|---|---|---|---|
| 1 | F18's "kind not stated" list | **271 KIND** | `271:363-369` — 3 kindless batches listed with code and kg (250 + 40 = 290; the pcs batch with quantity and unit) |
| 2 | its exclusion from the valued total | **271 KIND** | `271:370-376` — Ni stays 76 kg / 1,140.00, total 1,140.00; listed once, not as "not measured" / "not in kg" |
| 3 | the incomplete marker | **271 KIND** | `271:381-393` — both sides: only kindless batches left → `complete` false; kind stated → true (the cell that did not bite at first, MES-8b-2 §4) |
| 4 | a recorded non-processable kind unchanged | **271 KIND** | `271:377-380` — the spare part (`FX271-SP`) absent from every list |
| 5 | `floor_board()` counts only, no money, names or health data | **273 COUNTS** (+ GATE) | `273:180-198` — keys exactly `{as_of, refresh_seconds, settings_set, tiles}`, each tile exactly `{section, item_type, count}`, count = its arm's rows; `273:208-211` — a display session reads 0 rows of `operations_now` / `inbound_batches` / `incidents` / `stocktakes` |
| 6 | `/display` open only to a session with `data.view_floor_board` | **273 GATE** (database half) · page: no fixture | `273:201-207` — `floor_board()` refuses a session without the code by name; the page gate is `requireFloorBoard()` (`app/components/moduleGuard.tsx:193-196`), measured over HTTP today (§4 b) |
| 7 | every other route refusing a floor_display-only session | **no fixture** — application code | root layout `app/layout.tsx:153`, six code-free pages, `requireNotFloorDisplay()` `moduleGuard.tsx:176-188`, predicate `lib/floorDisplay.ts:19-26`; proved over HTTP by MES-8b-2 (§5, 13 routes) and today (§4 b, 6 routes) |
| 8 | the idle exemption only for a floor_display-only session, removed by any other role or code | **273 IDLE** | `273:213-255` — every other bootstrap role, a second role with no code (and back after revoking it), every other catalogue code one at a time, the code held through another role, an inactive `floor_display` |
| 9 | idle logout unchanged for every other permission set | **273 IDLE** (database half) · HTTP: no fixture | `273:220-229` — predicate false for an all-codes, HR and account-manager session and every bootstrap role; the HTTP half (307 → `/login?reason=ended` at 31 min for the 7 roles' clones) was MES-8b-2's one-off proof (§6) |
| 10 | the exemption decided server-side | **273 IDLE** (the predicate is in the database, evaluated by `auth.uid()`) · middleware: no fixture | `lib/supabase/middleware.ts:243-248` asks `session_is_floor_display_only()` only when `idleExpired && user`; nothing the browser sends is read |
| 11 | "refreshed at" and the refresh button with V28 unset | **273 COUNTS** (no interval guessed) · the text and button: no fixture | `273:194-198` — `refresh_seconds` null, `settings_set` false; `app/display/RefreshControls.tsx:26-33`; measured today: "Refreshed at 10:12" on the deployed `/display` |
| 12 | V28's arm | **273 V28** | `273:257-297` — no display account → no row; one → one row for the account manager pointing at `/display`; the display itself does not see it; set → row gone; refusals by name |
| 13 | the month-end width fix | **no fixture** — layout | `app/finance/month-end/page.tsx:290` (`overflow-x-auto`); MES-8b-2's layout survey (§8, +6 → 0) and today (§4 b, 0 px for admin · cfo · finance) |
| 14 | change-log exclusions at 8 | **273 LOG** | `273:300-308` — `change_log_coverage_gaps()` gaps 0, excluded 8; `floor_board_settings` change-logged |

**Result:** 8 items (1–5, 8, 12, 14) are covered by a fixture arm; items 6, 9, 10 and 11 by a fixture for their database half only; **items 7 and 13 by no fixture**. The
application halves (route refusals, the middleware's use of the predicate, the "Refreshed at" text, the month-end scroller) were proved once by MES-8b-2's
HTTP proof and layout survey and are re-measured today on the deployed app (§4 b, all working). A SQL fixture cannot reach them — fixtures run in the
database and there is no JS / HTTP runner (`docs/known-issues.md`, SESSION-1: "没有 fixture 能钉住它 —— 没有 JS 运行器"). The MES-8b-2 hand-back did not map
its list item by item and did not say that items 7 and 13 have no fixture. **This is a gap in the record, not in the behaviour.** It is registered as
`MES8B2-APP-HALF-NO-REGRESSION-CHECK` (`docs/known-issues.md`), not built.

### b · Usability on the deployed app (throwaways: clones of admin 85 codes · cfo 36 · finance 43 · warehouse 31; a floor_display-only account)

| Session | `/display` | other routes | `/finance/price-exposure` | `/finance/month-end` at 390 px |
|---|---|---|---|---|
| floor_display only (1 code) | **200**, 23 count tiles, "Refreshed at 10:12", no chrome, no settings panel | `/` `/inventory` `/finance/month-end` `/finance/price-exposure` `/suppliers` `/me`: each **200** with the display refusal and its link back to `/display` (a refusal page, not a redirect — MES-8b-2 decision 5) | (refused, left column) | — |
| admin clone | **200**, 23 tiles + the V28 panel (23 checkboxes) | — | **200**, "Kind not stated — 23 batch(es), 119,104 kg" (IN-2026-0001 887 kg · -0003 80 · -0012 50 · -0029 3,800 · -0156 400 · -0179 300 · -0180 99,970 · …); total "USD 0.00. Incomplete — …" | **200**, page overflow **0 px**, one table inside an `overflow-x: auto` scroller |
| cfo clone | **200**, 23 tiles + the panel | — | **200**, same list and incomplete total | **200**, **0 px** |
| finance clone | **200**, refused (no `data.view_floor_board`) | — | **200**, same list and incomplete total | **200**, **0 px** |
| warehouse clone | **200**, refused | — | **200**, refused (no `module.finance.view`) — as MES-8b-2 §7 | **200**, refused ("Finance"), 0 px |

Nothing missing, nothing not working.

### c · MES-8b-2's decisions taken without asking (`docs/handbacks/MES-8b-2.md` §10)

1. The arms moved into a base view (`operations_arms_all`); `operations_now` became that view plus its per-reader filter.
2. The floor tiles are a closed list of 23 arms.
3. `data.view_floor_board` also goes to cfo. *(Tim 2026-10-19: accepted as built — §2.)*
4. The exemption is asked only when a request is already idle-expired.
5. The route refusal lives in the root layout plus the six code-free pages, not in the middleware.
6. Sign-in is untouched (a display lands on `/` and sees the refusal with a way to `/display`).
7. V28 is set by `action.manage_permissions`, on a panel at the foot of `/display`.
8. No trail subject for `floor_board_settings`.
9. F18 lists non-kg kindless stock with its quantity and unit.
10. Fixture 271 builds a kindless material by dropping and re-adding `materials_kind_stated` `NOT VALID` in its own transaction.
11. The month-end fix is a horizontal scroller around the table.
12. `RefusalPage` gained an optional `backHref`.
13. `session_is_floor_display_only` is allowlisted in both definer scans.
14. Two minor gaps registered, not built (soft navigation into `/display`; the V28 panel on the board).
15. The live proof's HTTP half ran on a local `next dev` with the cut's code against live.
16. The SESSION-1 manual repro was not walked. *(Walked now — §3.)*

## 5 · Nothing of mine remains (`mes8b2-closeout-residue.sql`, `READ_OWN_EXIT=0`, 10:14:40 CST)

Throwaway accounts (`@test.local`) **0** · accounts 7, 0 banned · probe roles **0** · `floor_display` holders **0** · grants without an account **0** · avatar
objects without an account **0** · `.ephemeral/` plan files none · locations 4 (unchanged; none mine). Change log since 09:59:02: only my two runs' throwaways —
roles 10 / 10, user_roles 12 / 12, role_permissions 394 / 394 (INSERT = DELETE). Approvals on finance / cfo / 1,000; `require_calibrated_since` NULL; COD
objects 34,701 / 34,746 bytes, same eTags; pending `CLM-2026-0004`.

## 6 · The first probe run, and why it was re-run

The first run (`CLOSEOUT_PROBE_EXIT=1`) failed three assertions, and all three were the probe's own:
- **sign-in:** the login ends in a server-action redirect (a soft navigation); the probe read the URL before it changed (`/login`, while the cookie was
  already set). Fixed by polling the URL.
- **`/display` for admin and cfo: "46 tiles".** The V28 settings panel's 23 checkboxes carry `data-tile` too (`app/display/DisplaySettingsPanel.tsx:57`);
  the count now takes only the board's `<div data-tile>` (23) and reports the checkboxes separately.
Every other assertion passed in both runs. Its throwaways were removed by its plan in the same way (counted in §5).
