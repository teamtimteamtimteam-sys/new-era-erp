v1.4.37 — The system now has a secure entry point for plant equipment: devices and gateways can be registered under Operation › Devices, each gateway gets its own revocable key, incoming data waits in a visible inbox until staff process it, and Settings › Pending values lists every standard the plant still has to supply.

# MES-1 — the data entry point (MES group, first cut; 2026-10-06)

Tim answered MES-1 Step 0 on 2026-10-06: every recommendation for Q1–Q30 in `docs/surveys/MES-1/STEP0-HANDBACK.md` §12 accepted as
stated; MES-0 Q1–Q96 stand. This cut builds all of it. **MES-1 is closed. The next cut is MES-2 · Confirmation, weighing, calibration.**

**Opening state:** `HEAD` = `origin/main` = **`ed6d2f11`** ("MES-1 Step 0: hand-back (docs only)"), tree clean apart from this cut's files.
Files were staged by explicit path only.

**Live state, before and after:** approvals ON throughout; the 7 accounts enabled throughout, each with the same role; one pending
document before and after (CLM-2026-0004, decider tim@). No real account was created, disabled or deleted. Harness throwaway accounts
were created and reaped (§5). Reconciliation: payables and receivables **0.00 unexplained** before and after (§5).

Every figure below is a script's own exit line or a query naming who ran it. "As postgres" means psql as `postgres`
(`rolbypassrls = true`), reading base tables. Working logs are in `~/mes1-work/logs/` (outside the repo). The live server is
PostgreSQL **17.6** (read before building, Q5: built-in `sha256()` and `gen_random_uuid()`, no pgcrypto).

## §1 · Role-by-role reading table (live, measured)

`db/scripts/2026-10-06-mes1-live-role-table.sql` — psql as postgres, then for each of the 7 real accounts `SET LOCAL ROLE authenticated`
plus that person's JWT (what PostgREST does per request), reading the three pages' sources for the probe gateway (retired by then, its
rows still present). One transaction, `ROLLBACK`; `ROLE_OWN_EXIT=0`, 2026-10-06 15:09:29 CST (log time).

| what the page reads | admin@ (admin) | chooer@ (finance) | fusheng@ (warehouse) | phua@ (cto) | sandra@ (cco) | tim@ (cfo) | vince@ (gm) |
|---|---|---|---|---|---|---|---|
| the three pages (`module.processing.view`) | opens | opens | opens | opens | opens | opens | opens |
| register / keys / retry / discard / limits (`action.manage_devices`) | **pressable** | disabled, names the code | disabled, names the code | **pressable** | disabled, names the code | disabled, names the code | disabled, names the code |
| devices page: probe gateway + its device | 2 | 2 | 2 | 2 | 2 | 2 | 2 |
| devices page: probe gateway status | retired · keys 0 | same | same | same | same | same | same |
| device page: keys (`gateway_keys_masked`) · hash | 2 rows · hash NULL | same | same | same | same | same | same |
| base table `gateway_keys.key_hash` | **42501** | 42501 | 42501 | 42501 | 42501 | 42501 | 42501 |
| inbox: probe rows by status | discarded 1, transformed 4 | same | same | same | same | same | same |
| device page: transmission log rows | 10 | 10 | 10 | 10 | 10 | 10 | 10 |
| device page: outages | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| pending values visible | 2 (V5 0 · V6 2) | same | same | same | same | same | same |
| a staff session calling `ingest_submit` | **42501** | 42501 | 42501 | 42501 | 42501 | 42501 | 42501 |

**Measured, and worth saying:** all seven roles hold `module.processing.view` today, so all seven open the three pages. Only cto and
admin hold the new code. V5 reads 0 because the only gateway is retired; V6 reads 2 because both active shifts have no start/end time
(by design until Tim supplies them).

## §2 · Every item built

| item (Step 0 Q) | built |
|---|---|
| Q1 four routes | `/operation/devices`, `/operation/devices/[id]`, `/operation/capture/inbox`, `/settings/pending-values` |
| Q2 pending values | view `pending_values`: one arm per value, each with its own permission; V5 and V6 seeded; `docs/mes-pending-values.md` with the rule that later cuts add arm + row in the same commit |
| Q3 data classes | `ingest_data_classes`: the eight MES-0 classes with no transformer, plus `connection_test` (`transform_connection_test_v1`); registry changes only by migration (no write path, no write policy) |
| Q4 the one anonymous door | `ingest_submit(text, text, jsonb)` SECURITY DEFINER; EXECUTE to `anon` only — revoked from `authenticated` **and** `service_role`; fixture 249 asserts both. Anonymous functions on live: exactly `cod_verification(text)` and `ingest_submit(text,text,jsonb)` (gate 匿名面 line) |
| Q5 keys | `'ngk_'` + two `gen_random_uuid()` hex (244 random bits), stored as `sha256(UTF-8 bytes)` in `gateway_keys.key_hash`; secret returned once by `issue_gateway_key`; at most two active keys per gateway (`GATEWAY_KEY_TWO_ACTIVE`) |
| Q6 ownership | a message for a device not carried by this gateway → `DEVICE_NOT_ON_THIS_GATEWAY` (one code for unknown / retired / other gateway's) |
| Q7 per-call state | `ingest_submit` only inserts; `devices` is never written by a gateway; last-heard derived on read (`gateway_health`) |
| Q8 heartbeats | one `heartbeat_hour` bucket row per gateway-hour; four counter columns grow only through the function (guard reads a transaction-local flag) |
| Q9 rate limit | failures logged one row each until 30 per presented code / 10 min or 300 overall (editable in `ingest_settings`); beyond that one overflow row per 10 min; a valid key is never throttled (authentication runs first) |
| Q10 refusals | every authentication failure answers exactly `{"ok": false, "code": "refused"}`; presented codes truncated to 64 characters; the exact reason is in the transmission log |
| Q11 transformation | never in the anonymous call; `ingest_process_pending` (needs `module.processing.view`) behind a **Process received** button; retry / discard need `action.manage_devices` |
| Q12 / Q15 errors | envelope errors rejected and not stored; payload errors stored and fail visibly (`failed` + code); discard keeps the code and needs a reason; rows are never deleted |
| Q13 sequences | identity (gateway, stream, seq); same content → `duplicates`; different content → `SEQ_REUSED`; gaps per stream (`ingest_sequence_gaps`); `site_to` > 5 min ahead flagged `clock_ahead` |
| Q14 manual entry | inbox `source` column + CHECK (`device` / `manual`); the full manual path is MES-2 |
| Q16 / Q17 statuses | "Not yet heard from" and "Not yet set — silence cannot be judged" raise no reminder |
| Q18 caller address | `X-Forwarded-For` stored as reported, labelled "reported address (not verified)", else "not available" |
| Q19 anomalies | `ingest_transmission_anomalies`: refused calls · overflow · sequence reuse · clock ahead; out-of-hours waits for V6 |
| Q20 the key hash | mask rule form **`never`** (`gateway_keys.key_hash`), `gateway_keys_masked` (always NULL), column outside the SELECT grant; the trail shows only the 8-character prefix |
| Q21 outages | their own section on the gateway page (excluded tables do not reach the trail) |
| Q22 settings history | `ingest_settings` logged, trail subject `ingest_settings` on the devices page |
| Q23 reminders | two arms: `gateway_silent`, `capture_inbox_failed` (`operations_now` 47 → 49) |
| Q24 interface doc | `docs/integration/gateway-interface.md`, English, for vendors: transport, envelope, heartbeat, responses, back-fill, key rotation, `connection_test`, a commissioning checklist |
| Q25 probe rows | the probe gateway `ZZ-PROBE-GW-…` was retired at the end; its rows stay as test data, one line in `docs/known-wrong-until-cutover.md` |
| Q26 free plan | the device pages show the free-plan line until Tim says otherwise |
| Q27 open policies | fixture 249 POL: the 44 open `USING (true)` read policies for `authenticated` are still 44, none on a MES-1 table |
| Q28 device codes | `DEV-YYYY-NNNN` through `document_types` (sequence-backed, gaps allowed), generated on save; the human label is `name` |
| Q29 machines | machine labels read through `equipment_usage` (processing readers cannot read `fixed_assets`) |
| Q30 stale notes | struck in this cut, pointing to U1-B, old text kept struck through: `docs/forward-queue.md` (LEAK-1 note), `docs/known-issues.md` (PROBE-KILL-LEAK header note; the DRAFT-6 ForwarderPanels note) |

New permission code: **`action.manage_devices`** → cto · admin (`docs/role-matrix.md`).

## §3 · Pages — every new or changed route, with its file

| route | file(s) | what |
|---|---|---|
| `/operation/devices` (new) | `app/operation/devices/page.tsx` · `DeviceForm.tsx` · `IngestSettingsPanel.tsx` · `actions.ts` · `deviceFields.ts` · `deviceErrorCodes.ts` | inbox counts; gateways with status read-on-read; devices; register form (gated); ingestion limits panel (gated) and its trail; free-plan line |
| `/operation/devices/[id]` (new) | `app/operation/devices/[id]/page.tsx` · `DeviceControls.tsx` · `KeysPanel.tsx` | header; edit / retire (gated); for a gateway: status, keys (prefix only, issue / revoke), carried devices, recent calls with reported address, gaps, outages, anomalies; for a device: recent messages; the six contract data-interface terms; the device trail |
| `/operation/capture/inbox` (new) | `app/operation/capture/inbox/page.tsx` · `InboxControls.tsx` · `actions.ts` | rows by status, payload, error code; **Process received**; retry / discard with reason |
| `/settings/pending-values` (new) | `app/settings/pending-values/page.tsx` | every pending value the reader may see, each linking to where it is filled |
| menu, reminders, search | `lib/modules.ts` (Operation › Devices, inbox under it; Settings › Pending values) · `lib/reminders.ts` (two arms) · search doc type `device` | |
| trails | `lib/trail/render.ts` · `lib/trail/text.ts` · `app/components/trail/AuditTrail.tsx` · `lib/trail/catalogue.generated.ts` | subjects `device` (with its keys) and `ingest_settings` |

Messages in `messages/en.ts` and `messages/zh.ts` (`devices.*`, `inbox.*`, `pendingValues.*`, two dashboard items, one search type).

## §4 · Verification, in the brief's order

| # | step | result | source |
|---|---|---|---|
| 1 | offline gate | `GATE_OFFLINE_EXIT=0` (63 s), on the final mirrors | `gate-off1.log` |
| 2 | backup (background) | `BACKUP_EXIT=0` — `evoltrya-backup-2026-10-06-1132.dump`, 5.9 MB, TOC 7465 (previous 7421) | `backup.log` |
| 2b | live dry run (COMMIT → ROLLBACK) | `DRY_OWN_EXIT=0`; inside it: anon can execute `ingest_submit`, authenticated cannot; 9 data classes, 0 devices | `dry.log` |
| 3 | apply_migration | committed atomically with the function-grant replay; **window start 2026-10-06 11:39:23 CST** (`db/migration-windows.tsv`; the script printed 11:38:25 at its start); pre-flight: 23 CREATE FUNCTION, 5 replacements, 18 new | `apply.log` |
| 4 | types | `TYPES_OWN_EXIT=0` (after `NOTIFY pgrst`); `lib/maskedTables.ts` 35 tables (`gateway_keys` added) | `types.log` |
| 5 | tsc | `TSC_OWN_EXIT=0` (and again after the fix below) | `tsc*.log` |
| 6 | build | `BUILD_OWN_EXIT=0` | `build.log`, `build4.log` |
| 7 | full gate | `GATE_EXIT=0` (361 s) — 可重建性 ✓ · 镜像 vs 线上 ✓ · 行为断言 ✓ (fixture 249 included) · 匿名面 ✓ (live ⊂ baseline 328; anonymous functions exactly `cod_verification`, `ingest_submit`) | `gate-full.log` |
| 8 | i18n | `I18N_OWN_EXIT=0` | `i18n.log`, `i18n2.log` |
| 9 | error swallowing | `SWALLOW_OWN_EXIT=0` (0 unallowed) | `swallow.log` |
| 10 | layout survey | 390 px and 1280 px: **3 / 3 usable** on the three list routes (empty live), then **5 / 5 at both widths** with the probe's rows — the three routes plus the gateway page and the device page (`SURVEY2_EXIT=0` ×2); U1 and U2 both 5 / 5 | `survey390/1280.log`, `survey2-390/1280.log` |
| 11 | smoke (background) | run 1 `SMOKE_EXIT=0` — 263 ok · 10 skipped (no data) · 0 FAILED. **Run 2 (after the fix): see §4.1** | `smoke.log`, `smoke2.log` |
| 12 | live verification | §1, §5 | |

### §4.1 · A defect the survey caught after smoke passed — and the reruns

The layout survey of `/operation/devices/[id]`, run with the probe gateway's real id, got **HTTP 500 on both device pages**. A dev
server under a throwaway session (`db/scripts/2026-10-06-mes1-page-error.mjs`) printed the cause:
`TypeError: … DeviceForm.tsx … TERM_KEYS.map is not a function`. The server page imported a **value** from a `'use client'` file. Across
that boundary it arrives as a client reference, not the array. `tsc` and `next build` were both green, and smoke run 1 could not reach the
page: live had no devices, and the route was on the expected-skip list.

**Fix:** the constants and types moved to a plain module, `app/operation/devices/deviceFields.ts`, and every importer reads values from it;
the i18n manifest points at it. Afterwards, on the dev server: **7 / 7 requests 200, 0 server errors** (both device pages, the trail
expanded, the list, the inbox and its failed filter, pending values). `/operation/devices/[id]` is **off** smoke's expected-skip list,
because live now has a device, so every smoke run opens one.

**Something the reruns caught, which is now a known issue:** the first rebuild went red in i18n (10 "missing" keys). The new file's
header comment named the term-keys array, and `check-i18n`'s `tsArray` reads the **first mention** of a name, comments included. That made
it read the device kinds as term keys. I reworded the comment and did not change the checker
(`docs/known-issues.md` `MES1-I18N-TSARRAY-READS-FIRST-MENTION`).

**Reruns after the change:** survey 5 / 5 at both widths (before the comment-only edit; nothing that renders changed after it) · tsc 0 ·
build 0 (run 4; run 3 red only on lint warnings in the diagnostic script, fixed) · i18n 0 · full gate: run 2 died on a dropped pooler
connection (`server closed the connection unexpectedly`, not a verdict), retried once at once, **run 3 `GATE_EXIT=0`** (448 s) ·
smoke run 2: **`SMOKE_EXIT=0` — 264 ok · 9 skipped (no data) · 0 FAILED**, now opening `/operation/devices/[id]` (one more ok, one fewer skip than run 1).

**Smoke's scratch-cleanup reading:** `npm run check:scratch` after smoke run 1 reports the **same 6** stale rows as every recent cut, all
pre-existing (`ZZ-SMOKE-PROBE` · `-M25` · `-NTF` · `-S25` · `-CJK` · `-IB25`, 815–1,458 h old; 5 still referenced, "不要直接删"),
`SCRATCH_OWN_EXIT=1` (its "stale rows exist" code). After smoke run 2: the same 6, nothing new. As postgres after everything:
`auth.users` like `%@test.local` **0** · `roles` like `probe-%` **0** · grants without an account **0** · `.ephemeral/` empty.

### §4.2 · Security proof — fixture 249, arm by arm, each fault-injected

`db/fixtures/249-a-gateway-can-only-append-and-a-key-is-the-only-door.sql` runs as postgres. Anonymous calls really switch to `anon`;
staff reads and writes really switch to `authenticated` plus a JWT. `db/scripts/2026-10-06-mes1-fixture-injections.py` on a local
rebuild: **clean run green, 33 injections, 0 wrong, each red in the arm it names** (`INJECTIONS_OWN_EXIT=0`, `inj2.log`).
Every arm goes red on at least one injection.

| arm | what it pins | injection(s) → went red with |
|---|---|---|
| DEV | devices registered only through `save_device` with `action.manage_devices`; code generated on save | save_device stops asking for the code → "a reader without action.manage_devices registered a device" |
| GRANT | `ingest_submit` anon-only (not authenticated, not service_role); exactly two anonymous functions; inner dispatcher/transformers callable by nobody outside; new tables and views unreadable to anon | granted back to authenticated · granted to service_role · a third anonymous function (the inbox processor) · the dispatcher callable by authenticated · anon may read the inbox — each red in GRANT |
| POL | 44 open read policies, none on a MES-1 table | an open read policy on the inbox → "45 … expected 44" |
| HASH | the key hash visible to nobody: no grant, 42501 on the base table, masked view NULL, change-log rule `never`, not in the trail | key_hash granted · masked view shows the hash · the never rule answers visible |
| APPEND | the anonymous call writes only inbox, transmission log and outages (per-transaction table counters), deletes nothing, updates only buckets | the call touches its gateway's device row → "devices upd+8" |
| RESP | answer keys ⊆ {ok, accepted, duplicates, rejected, code}; no table content | the answer carries the gateway's name |
| AUTH | unknown gateway · wrong key · other gateway's key · revoked key · retired gateway → exactly `{"ok": false, "code": "refused"}` | a refusal names its reason · a revoked key accepted · a retired gateway judged by its keys only |
| SIZE | > 256 KB · > 500 messages · wrong shape answered by name to authenticated callers only | payload cap 100× · message cap unchecked |
| OWN | another gateway's device → `DEVICE_NOT_ON_THIS_GATEWAY`, nothing stored | a gateway may write for any device |
| SEQ | duplicates; `SEQ_REUSED`; a restarted stream; gaps per stream; clock-ahead flag | reuse counted as duplicate · clock-ahead never flagged · the gap view forgets gaps before the first number |
| HB | heartbeat buckets grow only through the function and never shrink; not in the inbox | a bucket grows without the flag · a bucket may shrink |
| STAT | not_yet_heard · interval_not_set · silent · ok, derived on read; outage on reconnect; none without an interval | no outage on reconnect · an unset interval reads as ok |
| PV | V5 and V6 rows, each behind its own code | pending values stop asking for each arm's code |
| XF | `connection_test` transformed / failed (visible, with code) / awaiting / retry / discard with reason, never deleted; processing needs processing.view | a failure marked transformed · an inbox row deletable · anyone may process |
| ROT | at most two active keys; the second keeps working after the first is revoked | a third active key allowed |
| LIM | 30 per code / 300 overall then one overflow row per 10 min; the answer unchanged; a valid key never throttled | global ceiling gone · per-code budget gone · a valid key throttled once the budget is spent |

**Trail wording:** `scripts/check-trail-wording.mjs` arm **⑮** has 7 goldens: device registered / changed / retired, key issued /
revoked (prefix only), ingestion limits changed. `TRAIL_WORDING_FAULT=wording-drift-mes1` → red in ⑮ only.

## §5 · Live verification — before and after

**The probe over HTTPS** — `db/scripts/2026-10-06-mes1-live-probe.mjs` (`MES1_PROBE_EXIT=0`, **33 / 33 assertions**, 2026-10-06 15:08 CST).
The gateway side is anonymous and calls `POST /rest/v1/rpc/ingest_submit` with the public key, exactly as the vendor document says.
The staff side is a throwaway account from the shared helper (`mintThrowaway`, prefix `mes1probe`, holding only
`action.manage_devices` + `module.processing.view`), reaped at the end.

| step | measured |
|---|---|
| register | gateway **DEV-2026-0001** `ZZ-PROBE-GW-1791270494758`, no interval → **V5 row** in pending values; status `not_yet_heard`; device **DEV-2026-0002** under it |
| key | secret `ngk_` + 64 hex returned once (prefix `ed25da38`); masked view hash NULL; base-table `key_hash` → **HTTP 403 / 42501** for the staff session |
| heartbeat | `{"ok": true}` |
| connection_test | seq 1 and 2 accepted; seq 3 for `DEV-0000-0000` → `DEVICE_NOT_ON_THIS_GATEWAY` |
| duplicate | same seq, same content → `duplicates: [1]`, nothing stored |
| reused sequence | seq 1, different content → `rejected: SEQ_REUSED` |
| wrong key · unknown gateway | both exactly `{"ok": false, "code": "refused"}` |
| process (staff) | **Process received** → 2 processed: seq 1 **transformed** (`{"text": "MES-1 live probe"}`), seq 2 **failed** `CONNECTION_TEST_TEXT_REQUIRED`; reminder `capture_inbox_failed` appeared on the device; discarded with a reason (code kept); reminder gone |
| interval and silence | interval 5 s → V5 row gone; after 7 s `silent` and reminder `gateway_silent`; the next heartbeat recorded **one outage** (interval 5) |
| rotation | second key → 2 active; both accepted (seq 4 old, seq 5 new); old key revoked → `refused`; new key still accepted (seq 6); 3 more transformed |
| log | calls: accepted ×6, `bad_key`, `revoked_key`, (later) `retired_gateway`; heartbeat bucket count 2; caller addresses stored as reported (two egress addresses) or "not available" on the bucket row |
| retire | device and gateway retired → status `retired`, active keys 0; the new key → `refused` |

Also measured as postgres: `anon` has `statement_timeout = 3s` (authenticated 8 s). Every probe call returned in well under that, but a
full 500-message batch has not been timed on live (`docs/known-issues.md` `MES1-ANON-STATEMENT-TIMEOUT-3S`).

**Before** 2026-10-06 11:30:34 CST (before the backup and the migration), **after** 2026-10-06 16:04:55 CST (after smoke run 2; the first
after-read died on a dropped pooler connection and was retried once) — `db/scripts/2026-10-06-mes1-live-readings.sql` (the U1-B readings: every public base table row count +
digest, accounts, approvals, pending documents; as postgres).

**Tables: 242 before, 249 after; every difference explained** (`diff` of the two readings):

| table | before → after | why |
|---|---|---|
| 7 new tables | — → `devices` 2 · `gateway_keys` 2 · `gateway_outages` 1 · `ingest_inbox` 5 · `ingest_transmissions` 11 · `ingest_data_classes` 9 · `ingest_settings` 1 | the migration's two seeds (9 classes, 1 settings row) and the **probe gateway's own rows** (10 transmission rows for it and 1 refusal for the presented code `ZZ-PROBE-GW-UNKNOWN-…`); all in `docs/known-wrong-until-cutover.md` |
| `permissions` | 73 → 74 | the migration: `action.manage_devices` |
| `role_permissions` | 343 → 345 | the migration: that code to admin and cto |
| `document_types` | 41 → 42 | the migration: `device` (`DEV`) |
| `document_type_exceptions` | 36 → 37 | the migration: `ingest_data_classes` |
| `cod_verification_failures` | 1 → 1, digest changed | smoke's `/verify/cod/[token]` probe writes its rate-limit row by design (U1-A and U1-B saw the same) |
| `expenses` 9 → 10 · `journal_entries` 82 → 83 · `journal_lines` 184 → 186 | **not mine** | **EXP-2026-0010** (SGD 5,200.00) and its entry JE-2026-0080, created by **chooer@** at 2026-10-06 12:11:29 SGT, during the pause (as postgres: `expenses.created_by`, and the change log's actor). It is why payables moved +5,200.00 on **both** sides (416,988.32 / 376,404.42 → 422,188.32 / 381,604.42) with **0.00 unexplained** before and after; receivables unchanged (57,545.87 / 43,002.12, 0.00). I did not touch it |
| change log (`~summary`) | 7,623 rows / seq 8,700 → 9,269 / 10,495 | every row after seq 8,700 accounted for (as postgres, grouped by actor, table and op): harness throwaways created and removed in pairs (`role_permissions` 742/742 · `roles` 11/11 · `user_roles` 11/11 · `employees` 18/18 · the smoke's contract and its six term tables in pairs · probation reviews 8 inserted / 8 updated / 8 deleted · the COD row 2/2); the probe's `devices` 2 inserts + 3 updates and `gateway_keys` 2 inserts + 2 revokes (actor: the reaped `mes1probe` throwaway); the migration's 5 rows (actor `postgres`); chooer@'s expense (3 rows) |

Every other table — every pre-existing document — has the same row count and digest. **Accounts:** before and after,
`admin@=admin · chooer@=finance · fusheng@=warehouse · phua@=cto · sandra@=cco · tim@=cfo · vince@=gm`, 0 disabled, 0 throwaway, approvals ON,
0 grants without an account, 1 pending document (CLM-2026-0004 → tim@). **Apart from the probe gateway's own rows, nothing of mine remains.**

### §5.1 · Broken window

| | value | source |
|---|---|---|
| start | **2026-10-06 11:39:23 CST** | `db/migration-windows.tsv` (`2026-10-06T11:39:23+0800	2026-10-06-mes1-entry-point.sql	ed6d2f11`); the script printed 11:38:25 at its start |
| end | Tim's Vercel reading (to be recorded at the next close-out) | a report, not a measurement from this machine |

**What was broken inside it** (derived from the old code, not measured on live): nothing that the old app reads changed. The migration
only adds things: new tables, views, functions, one permission, two document-type rows and two reminder arms. The old app has no route
that reads them. The two new reminder arms produce rows only once a gateway exists (from 15:08, the probe). The old reminders page
(`app/tools/reminders/page.tsx`) iterates its own registry, `REMINDERS`, and every other `operations_now` reader filters named item
types, so the old app **does not show** those rows: the two reminders are invisible until the deploy, nothing more. The session paused
once at Tim's request while the window was open (after the 390 px survey, before the 1280 px one).

## §6 · Decisions taken without asking

1. **The bootstrap admin holds `action.manage_devices`**, as admin holds every code (standing ruling); the live grant is admin + cto.
2. **Throttled and over-budget authentication failures answer `refused`.** There is no separate "throttled" code, because one would tell a
   caller that its guesses are being counted.
3. **`too_large` / `too_many` / `malformed` are named only to authenticated callers**; an unauthenticated caller always gets `refused`.
4. **Unknown, retired and other-gateway devices share `DEVICE_NOT_ON_THIS_GATEWAY`** (Q6's "one code").
5. **Retiring a gateway also revokes its keys**, so a retired gateway is refused by key as well as by status.
6. **Discarding an inbox row keeps its error code**; the "failed has a code" constraint became an implication.
7. **Transform functions are IMMUTABLE** and take only the payload, so a transformer cannot read or write tables.
8. **`save_device(p_fields jsonb, p_id uuid DEFAULT NULL)`**: parameters in that order, so PostgREST can call it without an id to create.
9. **The trail shows a key by its 8-character prefix without `ngk_`**, because the trail's machine-token scan refuses `ngk_…`.
10. **The anomaly view has no out-of-hours arm until V6 is supplied.**
11. **The inbox sits in the menu under Devices** (parent `/operation/devices`), not as its own menu entry.
12. **Settings › Pending values is gated `module.processing.view`** (the only arms today are processing values); each arm still asks its
    own code.
13. **No spec-appendix row per device** (MES-0 mentioned one). The six contract data-interface terms are columns on the device instead.
14. **The heartbeat body is `{"heartbeat": true}`** and nothing else.
15. **The overflow bucket is a fixed 600 s**; the two budgets and the window are editable in `ingest_settings`.
16. **At most two active keys per gateway** (`GATEWAY_KEY_TWO_ACTIVE`): two is enough to rotate without a gap, and a third has no use.
17. **`/operation/devices/[id]` came off smoke's expected-skip list** once the probe gateway existed, so every smoke run now opens a device page.
18. **The diagnostic script that found the 500 is committed** (`db/scripts/2026-10-06-mes1-page-error.mjs`) as the record of how it was
    found; it uses the shared throwaway helper and reaps its account.
19. **The probe also registered an unknown-gateway refusal under `ZZ-PROBE-GW-UNKNOWN-…`**. That row has no gateway id and cannot be
    deleted (append-only); it is in the known-wrong line next to the probe's rows.

## §7 · Assertions in the brief (and in the repo) measured and found false or imprecise

- "Register probe gateway `ZZ-PROBE-GW-…`": the **code** is generated (`DEV-2026-0001`, Q28); `ZZ-PROBE-GW-1791270494758` is its **name**.
- The page fault in §4.1: tsc green and build green, but the page was dead. Smoke could not see it because live had no device. **Only a
  measurement with a real id (the survey) reached it.**
- `check-i18n`'s `tsArray` is described as reading "`as const` arrays". It reads the first textual mention of the name, comments
  included (§4.1, known issue).
- Zero other assertions in the brief measured false. Checked: server version 17.6 (≥ 13), 44 open policies, 7 accounts, approvals ON,
  one pending document, the reconciliation.

## §8 · Docs updated

`docs/forward-queue.md` (item 36; MES-1 closed; MES-2 next; the Q30 strike) · `docs/mes-pending-values.md` (new; V5, V6) ·
`docs/integration/gateway-interface.md` (new) · `docs/role-matrix.md` (`action.manage_devices`; processing row) · `docs/change-log.md`
(§1 count 242 of 249; §2 the three ingestion logs as the second accepted exclusion kind; §7; §12 the `never` mask rule, 104 → 105) ·
`docs/dashboard-arm-inventory.md` (two arms and destinations) · `docs/known-issues.md` (two new entries; Q30 strikes) ·
`docs/known-wrong-until-cutover.md` (the probe's rows).

**Bootstrap check (AGENTS.md RUNTIME CONFIG rule):** `ingest_settings` is runtime config. Its bootstrap (30 · 600 · 300 · 262,144 · 500 ·
300) is what Q7 / Q9 / Q13 ruled and still means exactly that; no existing seeded column changed meaning.
