v1.4.58 — Wall display: a new floor-display role shows a read-only board of live counts from processing, safety and stock, with no money, names or health details, and a screen signed in with only that role is not logged out when idle; every other account keeps the usual idle logout. The price exposure page now lists stock whose material has no kind instead of leaving it out, and the month-end page fits on a phone again.

# MES-8b-2 hand-back — the wall display, F18 (stock with no material kind), the month-end page at 390 px (2026-10-17)

MES group, cut 22 (the brief "HOUSEKEEPING + MES-8b-2 build"). Answers Q19 · Q20 · Q29 of `docs/surveys/MES-8/STEP0-HANDBACK.md` and the MES-8b-2 halves of
Q21–Q24, exactly as stated there; Q19 as Tim restated it (Q83 supersedes IDLE-DRAFT's "one idle value for every role" in exactly one case). Fold-ins:
F18 (`MES8B1-EXPOSURE-SKIPS-UNKINDED-STOCK`, Tim: fix it) and `MES8B1-390-MONTH-END-DETAIL`. **MES-8 is complete.** MES-9 is next.

## 1 · Housekeeping (before anything else)

- **Opening check.** `HEAD` = `origin/main` = `git ls-remote origin main` = `91083d755735bee5bba60c5b3b383ada739d8118`; tree clean; no git command refused.
- **The previous session's processes stopped, each port read free afterwards** (`lsof -iTCP -sTCP:LISTEN`, 0 listeners each): `next dev` on **:3196** (pids 71938 /
  71955) · PostgREST on **:55521** (71918) and its auth stub on :55522 (71919) · the gate harness's local Postgres on **:55509** (`pgc9`, stopped with `pg_ctl
  stop -m fast`) · and, of the same sessions, a second PostgREST + stub on :55511 / :55512 (30261 / 30262) and two more local clusters on :55481 (`pg`) and
  :55491 (`pg7b2`) under this job's scratch directory, plus the cluster on :55454 in the scratchpad of `a5ac0d90` (the session this one was forked from).
  **Left running, not mine:** two scratch clusters of older sessions (:55444 in `16bccbe5`'s scratchpad, :55472 under `/tmp/m7q`) — named, not touched.
- **The fresh-clone build owed on `91083d75`:** `git clone` into the job scratch directory, checkout of `91083d75…`, no `.env.local`: **`npm ci` → `CI_EXIT=0`**,
  **`npm run build` → `BUILD_EXIT=0`** (both written by the script itself into its logs). Recorded in `docs/known-issues.md` (`MES8B2-FRESH-CLONE-91083D75`).

## 2 · Opening live readings (2026-10-17 12:50:24 CST, `docs/surveys/MES-8b-2/live-readings.sql`, `READ_OWN_EXIT=0`)

Read as `postgres` (`rolbypassrls = true`) on base tables inside `BEGIN READ ONLY … ROLLBACK`, except the exposure (read in admin@'s session, `321f1819…`) and the
two reconciliations (tim@'s session, `634c00f9…`) — those resolve the reader's codes.

| What | Reading |
|---|---|
| Materials | 9, **7 with no kind**; kinds: battery_material · ewaste may be processed; consumable · packaging · spare_part may not |
| Stock on hand by kind | inbound **kind not stated 11 batches / 115,288 kg** (5 with payable content) · inbound processable 1 / 100 kg · output **kind not stated 12 / 3,816 kg** (3 with content) |
| **F18 before** (`inventory_metal_exposure()` as admin) | value of what is measured and priced **USD 0.00** · complete false · not measured **1 batch / 100 kg** · unit not kg 0 · `kind_not_stated` **absent** (the 23 batches appear nowhere); every payable metal "priced", 0 kg |
| Wall display | role `floor_display` 0 · code `data.view_floor_board` 0 · `floor_board_settings` / `operations_arms_all` / `floor_board()` absent |
| Catalogue · roles | 84 codes (module 35 · action 38 · data 11); 12 roles, admin the only system role |
| Accounts | 7 real accounts, 0 disabled: admin@ admin · chooer@ finance · fusheng@ warehouse · phua@ cto · sandra@ cco · tim@ cfo · vince@ gm; throwaways 0, probe roles 0 |
| Codes per role | admin 84 · auditor 22 · cco 49 · cfo 35 · cto 41 · finance 43 · gm 23 · hr 8 · operations 16 · procurement 16 · sales 17 · warehouse 31 |
| Approvals | on · L1 finance · L2 cfo · 1,000; pending documents: **`CLM-2026-0004`** only (not mine) |
| Periods · calibration | `locked_before` = `system_start_date` = 2026-08-01 · `require_calibrated_since` NULL |
| CODs | `COD-2026-0001` sha256 `ba299a4f…f42101` · `COD-2026-0002` `717661f6…13a4f9`; bucket objects 34,701 / 34,746 bytes, eTags `7fcb4d67…` / `b9f5e8e1…` |
| Structure | tables 320 · views 196, writable (view, role) pairs **0** · pending-value arms 33 · reminder arms 72 · change log 53,840 rows, max seq 58,399 |
| Reconciliation | AP list 422,188.32 / ledger 381,604.42 / **unexplained 0.00** · AR 57,545.87 / 43,002.12 / **0.00** · inventory controls reconciled (0.00) |
| Fingerprints | 33 tables recorded (inbound, output, movements, runs, inputs, outputs, sales, settlements, prices, content, materials, kinds, suppliers, POs, journals, payments, expenses, incidents, inspections, packs, statements, finance settings, roles, user roles, pending documents …) |

## 3 · What was built

- **Role and code (Q19 · Q29 · MES-0 Q90).** `floor_display` (active, not a system role) holding exactly `data.view_floor_board` (a `data` code, declaring no view).
  The code goes to **floor_display · admin · cfo** — three grant rows, the only grant change on live. **No account was created**: an admin creates one per screen
  through `/settings/accounts`, holding only `floor_display`.
- **The board (Q20).** `floor_board()` (SECURITY DEFINER, gate `data.view_floor_board`) returns `{as_of, tiles, refresh_seconds, settings_set}` and each tile is
  exactly `{section, item_type, count}` — **counts only**: no subject, code, id, date, name, money or health detail. The tiles are a closed list,
  `floor_board_arms()`: every `operations_now` arm gated by `module.processing.view` / `module.safety.view` / `module.inventory.view` (13 + 4 + 2) plus four floor arms
  gated otherwise (`capture_draft_pending`, `stocktake_open`, `safety_state_dwell`, `quarantine_required`) — **23**. The counts come from the same arm definitions
  `operations_now` uses: the arms moved into a base view `operations_arms_all` (readable by nobody but its owner), and `operations_now` is now that view plus the
  per-reader filter — same columns, same rows (decision 1).
- **`/display` (Q20).** A bare page (no top bar, breadcrumbs or action region): three sections of large count tiles, **"Refreshed at hh:mm"** (Singapore time) and a
  **Refresh** button. With V28 unset it never refreshes by itself — no interval is guessed. Once V28 is given it shows only the chosen tiles in the chosen order
  and refreshes itself every `refresh_seconds`. The auto-refresh never counts as activity (it does not write the activity cookie).
- **V28** — `floor_board_settings` (one row, both empty), set or cleared as a pair through `set_floor_board_settings` (`action.manage_permissions`); refused by name:
  half a pair, a tile that is not a floor arm, a repeated tile, an empty list, a non-positive interval. The panel sits at the foot of `/display` for readers who are not
  a display. Pending-value arm V28: one row while either is empty **and** a live account holds `floor_display` — 0 rows on live (no display account).
- **The idle exemption (Q19).** `session_is_floor_display_only()` — true exactly when the session's roles are `{floor_display}` and its codes are
  `{data.view_floor_board}` (the role side uses the same conditions as `current_user_permissions`). Decided **on the server** from the session's own `auth.uid()`;
  nothing the browser sends takes part. The middleware asks it **only when a request has already been judged idle-expired** and the session has a user; true →
  the request goes through, false or any error → the same logout as today (same redirect, same cookies cleared). On `/display` the root layout keeps the
  `IdleWatcher` (the two-minute warning) for every session that is not a display.
- **Every other route refuses a display session.** The root layout (every hard navigation) replaces the page with one refusal — "This account is a wall display" —
  whose way out is `/display`; the six pages that need no code (`/`, `/me`, `/my-reviews`, `/notifications`, `/welcome`, `/tools/reminders`) ask too (soft
  navigation does not re-render the root layout); every other page already refuses by its own codes (a display holds one data code). `/login` and
  `/set-password` stay open (signing in and the first password change are the ordinary path).
- **F18.** `inventory_metal_exposure()` lists stock whose material has no kind in `kind_not_stated` (code and kg; quantity and unit when not kg) with
  `kind_not_stated_kg`; it is **not valued**, and `complete` is false while any such batch exists. A recorded kind that may not be processed keeps today's treatment
  (absent). The stock section gains "Kind not stated — N batch(es), K kg" with the codes.
- **Month-end at 390 px.** The checklist table is wrapped in `overflow-x-auto` — no width changes anywhere (§8).
- Mirrors: 1 table, 1 new view, 2 replaced views, 4 new functions, 1 replaced function; seeds of `roles`, `permissions`, `role_permissions` (one row each);
  `floor_board_settings` is RUNTIME CONFIG (its bootstrap — one row, both empty — is still correct: nothing is guessed).

## 4 · Verification, in the brief's order

| # | Step | Result |
|---|---|---|
| 1 | offline gate | first run `GATE_EXIT=1` — B2 and the definer scan named `session_is_floor_display_only` (DEFINER, no caller check — by design, it answers about the caller only; allowlisted with that reason in `db/verify_rebuild.py` and `db/check_mirrors.py`) and fixture 271's new arm used the wrong identity; second run **`GATE_EXIT=0`** ("迁移前相位:✓ 干净") after moving the document registry's table pin 320 → 321 and regenerating the deep-route list |
| 2 | backup (background) | **`BACKUP_EXIT=0`** from its own log — `evoltrya-backup-2026-10-17-1317.dump`, TOC 9,641 (previous 9,579, floor 8,621) |
| 3 | COMMIT → ROLLBACK dry run on live | preflight ✓ (6 `CREATE FUNCTION`: 1 replaced · 5 new); **`DRY_OWN_EXIT=0`** (13:37:27–13:39:51); probe inside it: 85 codes, holders admin · cfo · floor_display, 321 tables, 23 floor arms; read back afterwards: 84 codes, no role, no table |
| 4 | apply_migration | committed atomically with the function grants re-asserted, self-proof green (every real account: exempt = false); **window start 2026-10-17 13:42:39 CST** (`db/migration-windows.tsv`) |
| 5 | generate types | `DO_NOT_TRACK=1 npm run types:gen` from live, `TYPES_OWN_EXIT=0` (replaces the hand splice) |
| 6 | tsc | `TSC_OWN_EXIT=0` |
| 7 | build | `BUILD_OWN_EXIT=0` (the local dev server stopped first) |
| 8 | full gate | **`GATE_EXIT=0`**, 684 s: 可重建性 ✓ · 镜像 vs 线上 ✓ · 行为断言 ✓ (every fixture incl. 271 / 273) · 匿名面 ✓ (anon executes the same two functions). `colgrant` live **518 relations in 13 batches**, no gap (and rebuild) · `viewwrite` live and rebuild **197 views, none writable** (self-proof bit) · changelog 321 tables · 313 logged · **8 excluded** · `types` ✓ · `definer` 0 unallowlisted |
| 9 | i18n | `I18N_OWN_EXIT=0` |
| 10 | error swallowing | `SWALLOW_OWN_EXIT=0` (0 unallowed, 9 allowlisted) |
| 11 | layout survey | §8 — every page 0 at every width measured |
| 12 | smoke (background) | **`SMOKE_EXIT=0`**: 296 routes + probes, 271 timed (1,203 s total, median 3.7 s). **Scratch cleanup reading** afterwards on live: throwaway accounts **0**, probe roles **0**, `floor_display` grants **0**, no plan file. The scratch health check reported the same **6 stale rows** as MES-8b-1 (`ZZ-SMOKE-PROBE`, `-M25`, `-NTF`, `-S25`, `-CJK`, `-IB25`, 1,079–1,721 h old, five still referenced) — not mine, report-only, left alone |
| 13 | live verification | §5 – §7 |
| 14 | fresh-clone build of the commit pushed | §11 |

**Fault injection:** `db/scripts/2026-10-17-mes8b2-fixture-injections.py` — **22 cells** (271 KIND / EXPO: 5 · 273: 17), each red in its own arm, every arm red at least
once, the database identical before and after (`injection_probe`). The first sweep found one cell that did **not** bite (removing the kindless term from
`complete`): in fixture 271 `complete` is already false for other reasons, so the assertion could not see the property; the arm now measures both sides (with every
other material made non-processable the kindless batches are the only cause — false; once their kind is stated — true). Re-run on a **fresh rebuild after the
migration**: `REBUILD_OWN_EXIT=0`, `FX271_OWN_EXIT=0`, `FX273_OWN_EXIT=0`, **`INJECTIONS_OWN_EXIT=0` (5 + 17, 0 wrong)**. The script's header names the two places
with no cell (the "no session" and "inactive role" halves of the predicate cannot bite alone) and the middleware half (proved over HTTP, §6).

## 5 · Live verification (`db/scripts/2026-10-17-mes8b2-live-proof.mjs`, `MES8B2_PROOF_EXIT=0`, 14:31 CST)

One rolled-back transaction plus a local `next dev` running this cut's code against live (the middleware, layout and pages are application code; only HTTP
sees them). Throwaway accounts only (prefix `mes8b2probe`): **floor** = the real `floor_display` role itself (1 code) · **fin** = `module.finance.view` +
`data.view_prices` · **c_<role>** = clones of the 7 real roles' current codes (admin 85 · cfo 36 · finance 43 · cco 49 · cto 41 · warehouse 31 · gm 23).

- **The display:** `/display` → 200, **23 tiles**, no chrome, no settings panel; counts shown (live): `work_order_overdue` 1, every other tile 0 at that moment.
  `floor_board()` in the session: exactly `{as_of, refresh_seconds, settings_set, tiles}`, 23 tiles of exactly `{section, item_type, count}`, **every count = its
  arm's rows in `operations_arms_all`**, V28 unset (no interval). The display session reads **0 rows** of `operations_now`, `inbound_batches`, `incidents`,
  `stocktakes`, `employees`, `pending_values`; the warehouse clone calling `floor_board()` → `PERMISSION_DENIED|data.view_floor_board`.
- **Refused elsewhere:** 13 routes — `/` `/me` `/my-reviews` `/notifications` `/tools/reminders` `/finance/month-end` `/finance/price-exposure` `/inventory`
  `/settings/accounts` `/settings/pending-values` `/compliance/packs` `/suppliers` `/operation` — each the display refusal, its way out `/display`.
- **F18 after (live):** `kind_not_stated` **23 batches / 119,104 kg** (inbound 11 · output 12): IN-2026-0001 887 · -0003 80 · -0012 50 · -0029 3,800 · -0156 400 ·
  -0179 300 · -0180 99,970 · -0181 8,000 · -0258 1 · -0321 800 · -0322 1,000 · and the 12 output batches (OUT-2026-0002 1,000 · -0003 590 · …); **complete false**;
  value of what is measured and priced still 0.00 (these batches are not valued); not measured still 1 / 100 kg. Re-read in admin@'s session by the closing
  readings: the same 23 / 119,104 kg. **No material's kind was changed** (materials and kinds fingerprints opening = closing).
- **Untouched:** pre-existing rows identical (inbound, output, movements, materials, kinds, prices, content, stocktakes, journal lines, the V28 row, the real
  roles and their codes, the real accounts' roles); pending documents «`CLM-2026-0004`» exactly; approvals on; `require_calibrated_since` NULL; AP 422,188.32 /
  381,604.42 / **0.00**, AR 57,545.87 / 43,002.12 / **0.00**. After ROLLBACK: `floor_display` holders other than my throwaway 0, its codes
  `data.view_floor_board` only, V28 unset.

## 6 · The idle-logout proof, permission set by permission set

The clock is the session module's own test path: the activity cookie `evoltrya-last-activity` (`lib/session.ts`) set to 31 (and 29) minutes ago — no waiting.
**HTTP** = a real request through the middleware on live data; **DB** = `session_is_floor_display_only()` in that session.

| Permission set | DB: exempt? | HTTP at 29 min | HTTP at 31 min |
|---|---|---|---|
| **only `floor_display`, only `data.view_floor_board`** (the display) | **true** | — | **`/display` 200 — not logged out** |
| admin clone (85 codes, includes `data.view_floor_board`) | false | `/finance/month-end` 200 | **307 → `/login?reason=ended`** (as today) |
| cfo clone (36, includes `data.view_floor_board`) | false | 200 | **307 → `/login?reason=ended`** |
| finance clone (43) | false | 200 | **307 → `/login?reason=ended`** |
| cco clone (49) | false | 200 | **307 → `/login?reason=ended`** |
| cto clone (41) | false | 200 | **307 → `/login?reason=ended`** |
| warehouse clone (31) | false | `/inventory` 200 | **307 → `/login?reason=ended`** |
| gm clone (23) | false | 200 | **307 → `/login?reason=ended`** |
| `floor_display` + **any one other code** (84 codes tried one at a time, each added and undone inside the rolled-back transaction) | **false every time** — and `/display` still opens every time | (not visible over HTTP: the code exists only inside the rolled-back transaction) | — |
| the display account + a second role (no codes, sub-transaction) | false | — | — |

Together: the predicate is true only for the display (DB), and the middleware honours exactly the predicate (HTTP: true → in, false → logged out as
today). The same table on the local harness, where a second role **can** be committed, also gives the HTTP half of "another role removes the exemption":
`floor_display` + a second role at 31 min → 307 `/login?reason=ended` (`docs/surveys/MES-8b-2/mes8b2-local-http.mjs`, `HTTP8B2_EXIT=0`). The migration's
self-proof asked the predicate in each of the **7 real accounts'** own sessions: false for all seven. Fixture 273 IDLE covers every bootstrap role, any other
role, every other catalogue code, a code held through another role, a revoked second role (back to exempt) and an inactive `floor_display` (not exempt).

## 7 · Role table — the 7 real roles' codes (throwaway clones), read-only

| Role (codes) | `/display` | V28 panel | `/finance/price-exposure` (stock section) | `/settings/accounts` | idle exempt |
|---|---|---|---|---|---|
| admin (85) | the board (floor_board yes) | **pressable** | page · stock section with "Kind not stated" | open (manages accounts) | no |
| cfo (36) | the board (floor_board yes) | drawn disabled, names `action.manage_permissions` | page · with "Kind not stated" | refused (`action.manage_permissions`) | no |
| finance (43) | refused (`PERMISSION_DENIED\|data.view_floor_board`) | — | page · with "Kind not stated" | refused | no |
| cco (49) | refused | — | page · with "Kind not stated" | refused | no |
| cto (41) | refused | — | page · with "Kind not stated" | refused | no |
| warehouse (31) | refused | — | page refused (no `module.finance.view`; `PERMISSION_DENIED\|data.view_prices` on the function) | refused | no |
| gm (23) | refused | — | page · with "Kind not stated" | refused | no |

A display account (only `floor_display`): `/display` the board without the panel; every other page, including these two, the display refusal.

## 8 · Layout (`docs/surveys/MES-8b-2/layout-readings.txt`)

- **Live data** (`scripts/survey-phone.mjs`, all-codes throwaway, self-test bit +510 px each run, this cut's code): `/display` at **1920** (a typical wall screen),
  **1280** and **390** px → overflow 0; `/finance/price-exposure` and `/finance/month-end` at 1280 and 390 → 0.
- **Local harness** (a rebuild of the mirrors with this cut applied, local PostgREST and auth stub, never live): `/display` as the display, admin and cfo at
  1920 / 1280 / 390 → 0; price exposure (12 kindless batches seeded locally — the "Kind not stated" list drawn) and month-end as the 7 roles' code clones at
  1280 / 390 → 0 (warehouse: both pages refused, nothing to measure).
- **Month-end, before → after** (the brief's fold-in): **390 px +6 → 0** (live survey); the table stays 364 px, now inside a 326 px horizontal scroller; **1280 px
  0 → 0, table 832 → 832 px, the four columns 40 · 205 · 128 · 458 → identical** (local probe; the live survey reads the same table width). Four candidates were
  measured on the same DOM first (removing `w-32` from the status column: 6 → 6 — this cut had first landed exactly that and the live survey read 6 → 6, so it was
  reverted; `overflow-wrap: anywhere` on the detail or step column: 6 → 0 but squeezes that column to 41–45 px; the scroller: 6 → 0 with no width changed).

## 9 · Pages (route → file)

| Route | File(s) | What changed |
|---|---|---|
| `/display` | `app/display/page.tsx` · `RefreshControls.tsx` · `DisplaySettingsPanel.tsx` · `actions.ts` · `displayErrorCodes.ts` | new: the board (counts only), "Refreshed at", refresh button, auto-refresh only once V28 is set; the V28 panel for readers who are not a display |
| every route (hard navigation) | `app/layout.tsx` · `app/components/AppChrome.tsx` · `app/components/moduleGuard.tsx` (`requireNotFloorDisplay`, `requireFloorBoard`) · `app/components/ui/refusal.tsx` (`backHref`) · `lib/floorDisplay.ts` · `lib/loginRoute.ts` (`isDisplayPath`) | a display session gets the display refusal on any page but `/display`; `/display` has no chrome; `IdleWatcher` kept there for non-display sessions |
| every request (idle) | `lib/supabase/middleware.ts` | the exemption asked only on an already idle-expired request; any error → the logout as today |
| `/`, `/me`, `/my-reviews`, `/notifications`, `/welcome`, `/tools/reminders` | their `page.tsx` | the display refusal (pages that need no code) |
| `/finance/price-exposure` | `app/finance/price-exposure/InventoryExposureSection.tsx` | F18: "Kind not stated — N batch(es), K kg" with the codes; "Incomplete" names the kind |
| `/finance/month-end` | `app/finance/month-end/page.tsx` | the checklist table inside `overflow-x-auto` |
| `/settings/pending-values` | (unchanged page; `pending_values` view) | V28 row (only once a display account exists) |

Tooling moved with the arms (no check weakened): `scripts/check-reminder-arms.mjs` and `scripts/check-i18n.mjs` read `db/views/operations_arms_all.sql`;
`scripts/check-document-registry.mjs` 320 → 321 tables; `scripts/check-nav-routes.mjs` lists `/display` as an exception with its reason; `scripts/ephemeral.mjs`
knows the prefix `mes8b2probe`; `lib/deepRoutes.generated.ts` regenerated.

## 10 · Decisions taken without asking

1. **The arms moved into a base view (`operations_arms_all`) and `operations_now` became that view plus its per-reader filter.** A SECURITY DEFINER board reading
   `operations_now` still sees only the caller's arms (`has_permission` resolves the caller), so a display would read nothing; re-writing the arms inside
   `floor_board()` would be a second implementation of every arm. Same columns and rows; the thirteen fixtures and two scripts that read the view's text were
   pointed at the base view, none loosened.
2. **The floor tiles are a closed list of 23 arms**: every arm gated by the processing, safety or inventory view code, plus `capture_draft_pending`,
   `stocktake_open`, `safety_state_dwell` and `quarantine_required` (floor work gated otherwise). Fixture 273 ARMS fails if a new arm gated by one of the three
   codes is not added.
3. **`data.view_floor_board` also goes to cfo** — MES-0 Q90 names floor_display and admin; the standing rule "the CFO reads everything" (every `data.view_*`,
   `docs/role-matrix.md` §13) adds cfo. It is harmless (counts only) and cfo keeps the idle logout (not a display).
4. **The exemption is asked only when a request is already idle-expired**, not on every request (the middleware is not allowed a database read per request).
   The answer is the same — the exemption only matters at that moment — and it is read live from the session's roles, so adding a code takes effect on the very
   next idle-expired request. An error reading it logs the session out as today (a fault never makes sessions immortal).
5. **The route refusal lives in the root layout plus the six code-free pages**, not in the middleware (no per-request database read); pages that need a code
   refuse a display already. `/login` and `/set-password` stay open to a display (signing in and the first password change).
6. **Sign-in is untouched**: a display account still lands on `/` after signing in and sees the refusal with "Open the floor board" → `/display`. Changing the
   landing would have touched the sign-in path the brief forbids altering.
7. **V28 is set by `action.manage_permissions`** (the admin who creates display accounts — no new code, Q29), on a panel at the foot of `/display`, drawn only for
   sessions that are not a display (a wall screen does not show an admin form); its pending-value row appears only once a display account exists (the V9
   precedent). The pair is required together; the tiles keep the floor-arm order.
8. **No trail subject for `floor_board_settings`** — Q22 for this cut: none unless the role or code needs one; its changes are in the change log.
9. **F18 lists non-kg kindless stock with its quantity and unit** (kg empty) — the same disposition as "not in kg", not a separate list.
10. **Fixture 271 builds a kindless material by dropping `materials_kind_stated`, inserting and re-adding it `NOT VALID` inside its own transaction** — the shape the 7
    live materials have (they predate the constraint); a rebuild cannot otherwise hold one.
11. **The month-end fix is a horizontal scroller around the table**, not a width or wrapping change — the only measured candidate that changes no width.
12. **`RefusalPage` gained an optional `backHref`** (default `/`) so the display refusal points at `/display`; every other caller renders as before.
13. **`session_is_floor_display_only` is allowlisted in both definer scans** (`db/verify_rebuild.py`, `db/check_mirrors.py`) with the reason
    `current_user_permissions` has: it answers only about the caller.
14. **Two minor gaps registered, not built** (`docs/known-issues.md`): a non-display reader soft-navigating into `/display` loses the browser-side warning (no link
    reaches `/display` today; the server-side logout is unchanged), and the V28 panel lives on the board rather than a settings page.
15. **The live proof's HTTP half ran on a local `next dev` with this cut's code against live** (the deploy is Tim's to watch); the "one more code" case is proved in
    the database, because a code added inside a rolled-back transaction is invisible to another connection (§6).
16. **The SESSION-1 manual repro (`docs/known-issues.md`, "任何动到 `lib/supabase/middleware.ts` … 之后,按这个走一遍") was not walked.** Its steps 4–5 submit
    forms successfully, which on live would leave records the brief forbids; and the change sits entirely inside `if (idleExpired && user)` — a request that is
    not idle-expired runs exactly today's code (the client, `getUser()`, the cookie handling and every redirect are untouched). The idle path itself was walked
    over HTTP on live data for every real role's codes (§6).

## 11 · Closing live readings — nothing of mine remains (2026-10-17 14:35:26 CST, the same `live-readings.sql`)

Diff against §2, line by line — **every difference is something the migration itself creates**:

| Reading | Opening | Closing |
|---|---|---|
| Wall display | role 0 · code 0 · no table / view / board | role `floor_display` (active, not system) · code `data.view_floor_board` held by **admin · cfo · floor_display** · **0 accounts hold `floor_display`** · `floor_board_settings` (V28 empty) · `operations_arms_all` · `floor_board()` |
| Catalogue | 84 (data 11) | **85** (data 12) |
| Codes per role | admin 84 · cfo 35 | admin **85** · cfo **36** · floor_display **1** (every other role unchanged) |
| `role_permissions` digest excluding the new code and role | `9949a461…` | `9949a461…` (identical) |
| Roles fingerprint excluding `floor_display` | 13 rows `f66e959e…` | 14 rows, `f66e959e…` (identical) |
| Tables · views · pending arms · arms | 320 · 196 · 33 · 72 | **321 · 197 · 34** · 72 (now counted in `operations_arms_all`; `operations_now`'s own text no longer holds them) |
| Change log | 53,840 rows, max seq 58,399 | 55,961, max seq 60,611 — since 13:40: **the migration's own 5 rows** (`permissions` +1 · `roles` +1 · `role_permissions` +3, one transaction, 13:40:36–37); everything else my smoke / survey / proof throwaways and the smoke's scenery, **every INSERT matched by a DELETE** (roles 12 / 12 beyond the migration's one · user_roles 13 / 13 · role_permissions 650 / 650 beyond its three · employees 9 / 9 · performance_reviews 4 / 4 · contracts 2 / 2 with their term rows · one `cod_verification_failures` row in and out) |
| All other fingerprints (33 tables) | recorded | **identical** — no material's kind changed, no batch, price, content, stocktake or journal line changed |
| F18 | `kind_not_stated` absent · 0.00 · 1 not measured | **23 batches / 119,104 kg** · 0.00 · complete false · 1 not measured |
| Accounts | 7, 0 disabled, roles as §2 | **7, 0 disabled, roles identical**; throwaways 0 · probe roles 0 |
| Pending documents | `CLM-2026-0004` | `CLM-2026-0004` (with an eligible approver other than its submitter — the migration's self-proof listed every pending document's deciders) |
| Approvals · periods · calibration | on · 2026-08-01 · NULL | **on · 2026-08-01 · NULL** (no month locked or unlocked) |
| CODs | sha256 and bytes as §2 | **identical** (34,701 / 34,746 bytes, same eTags, same recorded sha256) |
| Views writable by anon / authenticated | 0 | **0** |
| Reconciliation | AP 0.00 · AR 0.00 unexplained | **AP 0.00 · AR 0.00** (list and ledger figures identical) |

## 12 · Broken window

Start **2026-10-17 13:42:39 CST** (measured, `db/apply_migration.sh` → `db/migration-windows.tsv`). End: **the moment Tim sees the deployment succeed on
Vercel** — this process does not query the deployment (AGENTS.md); it will be recorded from Tim's reading. What breaks inside it (derived, not measured on
live): nothing in use — the old app reads `operations_now` row for row as before; `inventory_metal_exposure` returns two more keys the old page ignores (the
section reads as it did this morning until the deploy); V28's arm has no row on live; the idle exemption is application code, so until the deploy a display
session would still be logged out — and none exists.

## 13 · Commit, fresh-clone build, push

One commit, staged by explicit path. Before the push: `git clone` of the repository into a scratch directory outside it, checkout of **the commit being
pushed**, no `.env.local`, `npm ci`, `npm run build`, judged only by the build's own exit code written into its log. A file cannot carry the result of building
itself, so that result — and `HEAD` · `origin/main` · `git ls-remote origin main` after the push — is in the report that closes this cut, not here.
