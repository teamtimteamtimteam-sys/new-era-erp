v1.4.61 — What suppliers see in the portal: a supplier signed in to the portal can now open its own purchase orders, statements and certificates of destruction exactly as they were issued, and see its own deliveries and weighbridge tickets without any prices; it never sees another supplier's records, live prices or anything internal, and every download is logged.

# MES-9b — hand-back (2026-10-19/20) · what a supplier sees

The brief "MES-9a close-out + MES-9b build: what a supplier sees in the portal (v1.4.61)", stopped once on a failed backup, then resumed by "MES-9b resume:
backup in parts, Tim's rulings, then verify from step 3". MES-9b answers the read third of `docs/surveys/MES-9/STEP0-HANDBACK.md` with Tim's §15 rulings
(Q14 · Q15 · Q16–Q18 · Q22 as recommended) and the four resume rulings below. Readings: `docs/surveys/MES-9b/readings/`.

## 0 · Tim's rulings on resume (2026-10-19) — closed

1. **Backup in two parts** — a `pg_dump` of everything except the data of `public.change_log`, and that data in contiguous `seq` chunks (each well under 3 minutes);
   verified by the main dump's exit code, every chunk's exit code, and the chunks' row total / first / last `seq` against `count(*)` / `min` / `max` read at the
   start. Made the repo's backup procedure, with a restore note. A failed chunk is retried once, then STOP. → §2.
2. **`MES9B-FINAL-ASSAY-NOT-SHOWN` accepted as registered** — the portal shows no assay results in this cut; a later cut may add a frozen, issued assay report.
3. **`MES9B-STORAGE-FUNCTIONS-FOLLOW-THE-PLATFORM` accepted** — the 19 storage functions stay in the `supplier_portal` baseline; when Supabase changes them,
   verdict 8 goes red and the baseline is reviewed and updated by name.
4. **Live proof** — no throwaway supplier statement committed on live, no `session_replication_role` or other trigger bypass on live for any purpose. The portal's
   HTTP download (stored PDF, hash re-check, 409, log row) is proved on a **local rebuild** with data of its own; on live every proof stays inside rolled-back
   transactions and HTTP proves only what needs no committed document. → §6, §7.

## 1 · Step 1 — MES-9a close-out (committed and pushed first)

Commit **`ba926879`** "MES-9a close-out" (`44e98fdd..ba926879`), fresh-clone build of that commit `CI_EXIT=0` · `BUILD_OWN_EXIT=0`. Evidence in full:
`docs/surveys/MES-9b/MES-9a-CLOSEOUT.md`.

- **Opening check** (2026-10-19 20:47:02 CST, first command): tree clean; `HEAD` = `origin/main` = `git ls-remote` = `44e98fdd36faae920d67b9814fe7cb1cc8b5a09e`.
- **Broken window closed** in `docs/forward-queue.md` (item 58): start **18:00:11** (measured) · end lower bound **20:36:11** (measured, the push in the reflog) ·
  upper bound **20:47:02** (derived — this session's first command, resting on Tim's "deployed", not a reading of Vercel) → **2 h 36 min 00 s – 2 h 46 min 51 s**.
- **Recorded:** Tim's confirmation that the real staff accounts sign in normally with the hook enabled; the hook was off for **39 s** (18:03:53 → 18:04:32) during MES-9a.
- **Read-only verification:** the MES-9a brief's 15-item fixture list mapped item by item — 12 covered by a fixture-275 arm or a gate check; **3 with no fixture arm**
  (forced first-sign-in hold · route separation · the approvals width) — application halves no SQL fixture reaches, each proved once by MES-9a's HTTP proof. A gap
  in the record only, registered **`MES9A-APP-HALF-NO-REGRESSION-CHECK`**; step 2 went ahead. MES-9a's 21 self-taken
  decisions listed by title.

## 2 · The backup procedure change (ruling 1) and its readings

**Why.** The first attempt of step 2 (21:28 and 21:53) failed twice the same way: `pg_dump: error: Dumping the contents of table "change_log" failed …
SSL SYSCALL error: EOF detected`, ~24–26 minutes in (`readings/backup-failed-1.txt`, `-2.txt`). Each left a backend `idle in transaction` holding **638 locks**;
both were ended with `pg_terminate_backend` (the dump's own backend; it only read). The cut stopped there (the retry rule), and Tim ruled the backup in parts.

**What changed.** `db/backup.sh` (new, in the repo) replaces `~/evoltrya-backups/backup.sh` as the pre-migration gate (AGENTS.md "The backup runs BEFORE the
migration", `docs/fresh-install-checklist.md` "从备份还原 · Restoring from a backup"):
① one `pg_dump -F c --exclude-table-data=public.change_log` (the table's structure is in it); ② `change_log`'s rows in `seq` ranges of 5,000 (measured 26 s for
the first range before choosing it), one `\copy` each, written as `evoltrya-backup-<stamp>.change_log.NNN.copy`; a failed chunk is retried once, then exit 1;
③ the three checks, plus the old script's four (quarantine name first, 100 KB floor, `pg_restore --list`, TOC entries within 10 % of the previous dump);
everything keeps its `.INCOMPLETE` name until the whole set passes. A manifest records the three start numbers and each chunk.
**Restore** (in the script header and the checklist): `pg_restore` the main dump → `\copy public.change_log FROM` each chunk in number order → compare
`count / min / max` with the manifest → `setval(pg_get_serial_sequence('public.change_log','seq'), max(seq))`.
**Fault-injected and restore-proved** on a throwaway local cluster (`db/scripts/2026-10-19-backup-injections.sh` → `readings/backup-injections.txt`,
`BKINJ_OWN_EXIT=0`, 6/6): clean run → restore equals the source row for row (count | min | max | md5 of every row) and the sequence continues above it; a chunk
failing once → retried, exit 0; failing twice → exit 1, refused by name, no good-named file; a dropped row → the count check refuses.

**The readings** (`readings/backup.txt`, `readings/backup-manifest.txt`, run 23:00–23:39 CST, **`BACKUP_EXIT=0`**):

| check | reading |
|---|---|
| start (read 23:01:01 CST) | `change_log` count **64,239** · min(seq) **1** · max(seq) **71,494** |
| main dump | **`MAIN_DUMP_EXIT=0`** (1,973 s) · 7.5 MB · TOC 9,721 (previous 9,669, floor 8,702) · no `change_log` data in it, its table present |
| chunks | **15**, every **`CHUNK_EXIT=0`**, all on the first try, 8–45 s each |
| rows / first / last | **64,239 = 64,239** · first seq **1 = 1** · last seq **71,494 = 71,494** |

## 3 · What was built

- **A download log** `portal_document_downloads` (Q22): one row per issued document a portal account took — account, link, supplier, kind, issue row, code,
  version, bucket, path, recorded sha256, moment. Append-only by its own guard (UPDATE per row, DELETE / TRUNCATE per statement → `PORTAL_DOWNLOAD_LOG_APPEND_ONLY`).
  Written only by `portal_document_open()`; no write grant or policy for `authenticated` / `anon`; read by `module.suppliers.view`. **The ninth change-log exclusion**
  ("Supplier portal download log (MES-9b, MES-9 Step 0 Q22): itself an append-only record of every issued document a portal user took; logging it again doubles the
  volume and adds no fact."). Every check that pinned 8 now pins 9 (18 fixtures + the migration's self-proof); none loosened.
- **Four portal functions**, each `SECURITY DEFINER`, each opening with `portal_require_link()`, no supplier id ever a parameter, executable by `supplier_portal` only:
  `portal_documents()` (orders · statements · certificates, each only with its issued versions; never-issued → "Not issued", void → "Void", superseded → its
  replacement; drafts / pending / rejected / deleted orders absent; **no amount anywhere**) · `portal_deliveries()` (receipts and the tickets on them, "as recorded";
  a shared ticket only carries the caller's share; no price, plate, note, stage, location) · `portal_document_open(kind, issue)` (ownership, void and deleted checks,
  then one log row, then path + recorded sha256; another supplier's and a missing one are the same refusal) · `portal_can_read_object(bucket, name)` (the storage
  policy's judge; never raises).
- **Storage:** `supplier_portal` gets `USAGE` on schema `storage` and `SELECT` on `storage.objects`, and one policy, `"portal reads its own logged issued documents"`
  (`TO supplier_portal`, the three document buckets, `portal_can_read_object`): it admits **only the object the account logged in the last two minutes**, so every
  byte taken is preceded by a log row (taking it straight from the Storage API without the log is not possible). Storage policies 52 → 53.
- **`/portal`** links to the two new pages; **`/portal/documents`** (each issued PDF as a download link); **`/portal/deliveries`** ("As recorded at …");
  **`/portal/documents/file`** (the route: `portal_document_open` → Storage with the session's own token → sha256 re-check → 409 on a mismatch; staff → 403).
- **Supplier page:** the portal section gains "Documents downloaded through the portal" (latest 50; `module.suppliers.view`).

## 4 · `supplier_portal` baseline lines added (`db/portal-grants-baseline.tsv`, 8 → 34, verdict 8)

| kind | object | privilege |
|---|---|---|
| schema | `storage` | USAGE |
| function | `public.portal_documents()` | EXECUTE |
| function | `public.portal_deliveries()` | EXECUTE |
| function | `public.portal_document_open(p_kind text, p_issue_id uuid)` | EXECUTE |
| function | `public.portal_can_read_object(p_bucket text, p_name text)` | EXECUTE |
| relation | `storage.objects` | SELECT |
| policy | `storage.objects` | portal reads its own logged issued documents |
| function ×19 | `storage.allow_any_operation` · `allow_only_operation` · `can_insert_object` · `enforce_bucket_lifecycle_service_role` · `enforce_bucket_name_length` · `extension` · `filename` · `foldername` · `get_common_prefix` · `get_size_by_bucket` · `list_multipart_uploads_with_delimiter` · `list_objects_with_delimiter` · `operation` · `protect_bucket_control_columns` · `protect_delete` · `search` · `search_by_timestamp` · `search_v2` · `update_updated_at_column` (full identity signatures in the file) | EXECUTE (PUBLIC's default, platform-owned, invoker rights — ruling 3) |

The rebuild side carries the same 19 signatures as stubs in `db/storage/platform-storage-stub.sql`. Verdict 8's enumeration had a latent defect found here: its
first UNION branch was `rolname` (63-byte `name`), truncating every longer object name — fixed with `::text` in `db/check_portal.py`. Full gate: **34 lines equal on
rebuild and live**.

## 5 · Sign-in checks, per account (after the migration, 23:48–23:51 CST, deployed app; `db/scripts/2026-10-19-mes9a-signin-checks.mjs` → `readings/signin-checks.txt`, `MES9A_SIGNIN_EXIT=0`)

| Account (throwaway copy) | Sign-in | Codes | Refresh | Rotation | Idle |
|---|---|---|---|---|---|
| admin | ok · authenticated | 86 | ok · rotated | grandparent → 400, active → 200 | 29 min → `/` 200 · 31 min → 307 `/login?reason=ended` |
| cco | ok · authenticated | 50 | ok · rotated | same | same |
| cfo | ok · authenticated | 36 | ok · rotated | same | same |
| cto | ok · authenticated | 41 | ok · rotated | same | same |
| finance | ok · authenticated | 43 | ok · rotated | same | same |
| gm | ok · authenticated | 23 | ok · rotated | same | same |
| warehouse | ok · authenticated | 31 | ok · rotated | same | same |
| display only (`floor_display`) | ok · authenticated | 1 | ok · rotated | same | 31 min → `/display` 200 (exempt, as before) |
| portal (throwaway) | ok · **supplier_portal** | — (`portal_me` own supplier; `current_user_permissions` 403) | ok · supplier_portal · rotated | same | the portal's idle logout is app code (unchanged) |

The hook, sign-in, refresh, idle logout and the display exemption were not changed by this cut (the migration's self-proof re-asserts the hook returns the 7 real
accounts' events byte-for-byte unchanged).

## 6 · Live verification (ruling 4) — `db/scripts/2026-10-19-mes9b-live-proof.mjs` → `readings/live-proof.txt`, **`MES9B_PROOF_EXIT=0`**, 67 PASS

Local `next start` (port 3196) built from this cut's tree, against live, browser chrome-headless-shell; throwaway accounts prefix `mes9bprobe`, suppliers `ZZ-PROBE`.
Committed on live: **only** the throwaway suppliers, contacts, portal links and accounts (removed by the plan). Two earlier runs are kept: run 1 (`-run1.txt`) stopped
on a driver bug (it assumed a statement issue exists on live — none does); run 2 (`-run2.txt`) on a status move (`draft → approved` is not legal; the transaction
now goes `draft → pending_review → approved`). Both rolled back, both left nothing (read back 0 throwaways after each).

**Over HTTP, nothing but throwaway identities committed:** both portal users sign in (password grant), tokens `supplier_portal`; `/portal` shows its own supplier and
the two links, nothing of the other; six staff routes (`/` · `/suppliers` · `/finance/journal` · `/inventory` · `/purchasing/orders` · its own supplier page) refused
with the way back to `/portal`; `/portal/documents` and `/portal/deliveries` render the **empty state for a supplier with no issued document** (three "None." ·
two "None." + "As recorded at …"); PostgREST `portal_documents` / `portal_deliveries` → its own supplier, empty lists; **another supplier's real issued documents**
(the oldest live `po_issues` and `cod_issues` rows — `supplier_statement_issues` is empty on live) → `portal_document_open` 400 `PORTAL_DOCUMENT_NOT_FOUND` and the
route 404, **0 log rows written**; the Storage API with the portal token on a real certificate's object → refused; it lists nothing in the three document buckets;
a staff copy on `/portal/documents/file` → 403, on `/portal/documents` → refused; page overflow **0 px** at 390 and 1280 for `/portal`, `/portal/documents`,
`/portal/deliveries` as a portal user.

**Inside one rolled-back transaction, every trigger on** (throwaway suppliers moved to approved, an order issued + a draft, a statement issued, two receipts with a
unit price and a note, an issued and a void certificate, an own ticket and a ticket shared between A and B), each portal function called **with the portal user's real
token claims** as `supplier_portal`: documents = its issued order (not the draft), its statement, its issued and void certificates (void → no document), nothing of the
other, no amount; deliveries = its receipts and tickets, only its share of the shared ticket (A 311 kg, B 422 kg), no price, plate or note; opening its order and its
certificate → path + recorded sha256 + one log row each; the other's order / certificate → `PORTAL_DOCUMENT_NOT_FOUND`; its void certificate → `PORTAL_DOCUMENT_VOID`;
the live storage policy shows it **0** of the document objects on live; it cannot read the log table (42501); no change-logged row from `supplier_portal`.
After the ROLLBACK: 0 orders / receipts / tickets / certificates / statements / log rows of the run.

### Role table — A's supplier page and the download log as each of the 7 real roles' permissions (read-only, throwaway clones)

| Role (clone) | Codes | Supplier page | Portal accounts section | Download log section | Rows shown | PostgREST `portal_document_downloads` (A) |
|---|---|---|---|---|---|---|
| admin | 86 | 200 | sees | sees | "No downloads yet." | 200, 0 rows |
| cco | 50 | 200 | sees | sees | "No downloads yet." | 200, 0 rows |
| cfo | 36 | 200 | sees | sees | "No downloads yet." | 200, 0 rows |
| cto | 41 | 200 | sees | sees | "No downloads yet." | 200, 0 rows |
| finance | 43 | 200 | sees | sees | "No downloads yet." | 200, 0 rows |
| gm | 23 | 200 | sees | sees | "No downloads yet." | 200, 0 rows |
| warehouse | 31 | 200 | sees | sees | "No downloads yet." | 200, 0 rows |

All seven hold `module.suppliers.view`. With no committed download on live the log is empty for everyone; a reader's rows are proved in fixture 276 LOG (a
`module.suppliers.view` reader reads A's 3 rows; a reader without it reads 0).

### Before / after (`readings/live-before.txt` 21:28 · `live-mid.txt` 01:33 · `live-after.txt` 01:55, `docs/surveys/MES-9b/live-readings.sql`, as `postgres`)

Every difference is the migration: `PORTAL_9B` (download log table 0 rows, storage USAGE + SELECT, 1 portal policy, six portal functions, exclusions 8 → 9) · storage
policies 52 → 53 (the md5 over the 52 others **unchanged**) · tables 323 → 324 — and the change log, 64,239 → 67,682 rows (append-only: the sign-in checks', the
smoke runs', the survey's and the proofs' throwaways). **Unchanged:** 7 accounts, 0 disabled, roles admin · finance · warehouse · cto · cco · cfo · gm as before;
throwaways 0 (probe roles, `test.local` accounts, `mes9*probe` accounts, `ZZ-PROBE` suppliers and contacts, `ZZ-PROBE-MES9B` rows, orphan grants); portal links 0;
pending `CLM-2026-0004` only (not mine; eligible approver tim@); `require_calibrated_since` NULL; both CODs' recorded sha256 (`ba299a4f…f42101` · `717661f6…13a4f9`)
and snapshot md5s identical; **all 40 stored objects identical** (md5 `2ff2f65e…`); every table fingerprint identical; reconciliation AP **0.00** · AR **0.00** ·
inventory raw **0.00** · fg **0.00** unexplained.

## 7 · The local-rebuild HTTP proof (ruling 4) — `db/scripts/2026-10-19-mes9b-local-download-proof.mjs` → `readings/local-download-proof.txt`, **`MES9B_LOCAL_PROOF_EXIT=0`**, 19 PASS

A throwaway local cluster built the way `db/gate.py` builds it (rebuild + storage stub + the storage mirror), seeded with two suppliers, a portal account each with a
live session, orders (v1, v2), statements, certificates (issued, void), PDF bytes on disk. **The route `app/portal/documents/file/route.ts` is loaded unchanged** (jiti)
with `@/lib/supabase/server` bound to that database: `.rpc` runs as `supplier_portal` with the account's claims; `.storage.download` first asks, as the same identity,
whether `storage.objects` returns that row (the real policy decides), then reads the bytes. Proved: order v2, order v1, statement and certificate for A, and order,
statement and certificate for B → **200, the stored bytes, sha256 re-checked, one log row each**; A asking for B's order / statement / certificate and B for A's order →
**404, no log row**; A's void certificate → **410**; an unknown kind → 400; a staff session → **403**; A's stored order bytes altered → **409** "Stored document does
not match its recorded digest"; an object A never logged → invisible to it; A's just-logged object → invisible to B; the log table read directly → refused; A's log =
exactly 5 rows (4 served + the 409 attempt).

**Live vs local, exactly:** on **live** — sign-in, landing, staff-route refusals, the empty states, PostgREST lists, refusal of other suppliers' real issued
documents (function, route, Storage API, listing), no log written by refusals, the staff 403, layout of the three portal pages, and (rolled back) every portal
function's answer on orders, statements, receipts, certificates and tickets with real token claims plus the live storage policy's answer. On the **local rebuild** —
the download itself: stored PDF served, hash re-checked, 409 on a mismatch, the log row per download, 404 / 410 / 400 / 403. In **fixture 276** (rebuild, every gate)
— all of the above as database assertions, fault-injected.

## 8 · Pages (route → file)

| Route | New / changed | Files |
|---|---|---|
| `/portal` | changed — links to documents and deliveries (the "coming" text that promised assays is gone) | `app/portal/page.tsx` |
| `/portal/documents` | new | `app/portal/documents/page.tsx` |
| `/portal/deliveries` | new | `app/portal/deliveries/page.tsx` |
| `/portal/documents/file` | new (Route Handler, PDF attachment) | `app/portal/documents/file/route.ts` · `app/portal/portalErrorCodes.ts` |
| `/suppliers/[id]/edit` | changed — the download log in the portal section | `app/suppliers/[id]/edit/PortalAccountsPanel.tsx` |
| (messages) | en + zh | `messages/en.ts` · `messages/zh.ts` |

Layout survey (`scripts/survey-phone.mjs`, staff session, `readings/survey.txt`): `/suppliers/<SUP-2026-0003>/edit`, `/portal`, `/portal/documents`,
`/portal/deliveries` at **390 px 4/4 usable** and **1280 px 4/4 usable**, overflow 0, nothing clipped, self-test passed. The first attempt of both widths failed its
self-test and its cleanup with `fetch failed` (a network outage to Supabase); its plans were reaped and read back clean (0 throwaways, 0 survey employees, 0 orphan
grants), then the retry passed. Portal pages as a portal user: §6.

## 9 · Verification, in the brief's order

| # | Step | Result |
|---|---|---|
| 1 | offline gate | `GATE_EXIT=0` (`readings/gate-offline.txt`) |
| 2 | backup in parts | `BACKUP_EXIT=0` (§2); the two whole-database attempts before it `BACKUP_EXIT=1` |
| 3 | dry run COMMIT→ROLLBACK | `DRY_OWN_EXIT=0` (`readings/migration-dry-run.txt`): inside 324 tables, six portal functions, storage USAGE + SELECT, 53 policies (1 portal), exclusions 9, gaps 0; after rollback 323 / 52 / no USAGE |
| 4 | apply | `APPLY_OWN_EXIT=0`; **window start 2026-10-19 23:47:32 CST** (`db/migration-windows.tsv`) |
| 5 | sign-in checks | `MES9A_SIGNIN_EXIT=0` (§5) |
| 6 | types | `TYPES_OWN_EXIT=0` (+98 lines) |
| 7 | tsc | `TSC_OWN_EXIT=0` |
| 8 | build | `BUILD_OWN_EXIT=0` |
| 9 | full gate | `GATE_EXIT=0` (`readings/gate-full.txt`): colgrant live / rebuild 522 relations in 14 batches, 40 masked · viewwrite 198 both sides · change log 324 / 315 / **9** · fixtures 274 · 275 · 276 ✓ (282 fixtures) · live fixture 266 ✓ · anon 327 · no-role 126 · storage mirror 19 / 53 = live · **portal 34 lines equal both sides** |
| — | injections on a fresh rebuild after the last DB edit | **42 / 42** (33 cells + 3 baselines + 6 verdict-8 cells), `INJ_OWN_EXIT=0` (`readings/injections-fresh-rebuild.txt`) |
| 10 | i18n | `I18N_OWN_EXIT=0` |
| 11 | error swallowing | `SWALLOW_OWN_EXIT=0` |
| 12 | layout survey | §8 |
| 13 | smoke | **run 1 `SMOKE_EXIT=6`**: 302 ok · 25 skipped · **0 failed**, cleanup hit `HTTP 504 Gateway Timeout` on one step (plan reaped, read back clean). **Run 2 `SMOKE_EXIT=1`**: `/settings/change-history` → 500, `change_log_rows` statement timeout — reproduced read-only at the database level (8.0 s against the 8 s cap; the latest 51 operations are 501 throwaway rows), not this cut's code: registered `CHANGE-HISTORY-8S-AFTER-BULK-GRANTS`. Scratch reading at both starts: the same 6 stale `ZZ-SMOKE` rows (1,137–1,780 h old, five still referenced) — pre-existing, not mine, not touched |
| 14 | live verification + local HTTP proof | §6 `MES9B_PROOF_EXIT=0` · §7 `MES9B_LOCAL_PROOF_EXIT=0` |
| 15 | fresh-clone build | in the closing report (a file cannot carry the result of building itself) |

## 10 · Broken window

Start **2026-10-19 23:47:32 CST** (measured). End = when Tim sees the deploy succeed in Vercel (filled in at the next close-out). **What is broken inside it**
(derived): nothing in use — the deployed app is MES-9a's over the new database; it reads none of the new objects; no portal account exists on live; staff tokens are
unchanged (§5).

## 11 · Decisions taken without asking

1. **Storage by the session's own token, through a policy keyed on the log row** — not the service role (house rule in `lib/supabase/admin.ts`), and not "its own
   supplier's object" alone (that would let a portal token take bytes from the Storage API without a log row, so Q22's log could miss downloads).
2. **The log row is written before the bytes are fetched**, so a 409 also leaves a row (`MES9B-DOWNLOAD-LOG-RECORDS-THE-REQUEST`).
3. **The two-minute window** for the storage predicate.
4. **One refusal for "another supplier's" and "does not exist"** (`PORTAL_DOCUMENT_NOT_FOUND`) — no existence oracle.
5. **Void certificates are listed but never handed out** (`PORTAL_DOCUMENT_VOID`, 410); superseded statements and earlier order versions are handed out, labelled.
6. **Orders listed:** not deleted, and (issued, or approved and not a draft) — drafts, pending and rejected orders are not documents sent to a supplier.
7. **Pending certificates are listed** as "Not issued yet", with no number.
8. **Receipts show** code, arrival date, material name, quantity and unit, order code and ticket codes — no status (always `draft` on live) or stage.
9. **Tickets show** code, direction, completion, void state and only the caller's share in kg — no gross / tare (a shared ticket's total would reveal the other's).
10. **Assays not shown** (Step 0 §4 listed them, the brief's restated Q14 did not) — ruled by Tim on resume (§0.2).
11. **The 19 storage functions in the baseline, mirrored as stubs on the rebuild** — ruled by Tim on resume (§0.3).
12. **Fixture 275's EVERY arm hands the four MES-9b functions to fixture 276 by name**; 276 asserts the two fixtures together cover the catalogue.
13. **Fixture 274 and live fixture 266 accept the 53rd policy by name and judge** (`portal_can_read_object`), counts moved 52 → 53.
14. **The judge-name fix in verdict 8** (`rolname::text`).
15. **`docs/change-log.md` §2's exclusion table** gained the missing `scan_events` row as well as the ninth.
16. **Sign-in checks reuse MES-9a's script unchanged** (its prefix `mes9aprobe`).
17. **The backup script lives in the repo** (`db/backup.sh`); `~/evoltrya-backups/backup.sh` is left in place, no longer the gate.
18. **Chunk width 5,000 `seq`**, from a measured 26 s for the first range.
19. **The two failed dumps' backends were ended with `pg_terminate_backend`** (the dumps' own read-only transactions).
20. **Smoke judged by its own line, and both runs reported as they are** (6 then 1) rather than run a third time; the change-history timeout registered, not fixed.
21. **The local download proof drives the route handler**, not a browser page: the documents page itself is proved on live (empty state) and in fixture 276.
22. **The live proof's real "other supplier" documents** are the oldest live `po_issues` / `cod_issues` rows, read and refused, never opened.
