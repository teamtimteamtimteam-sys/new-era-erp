v1.4.62 — Supplier certificate uploads: a supplier signed in to the portal can now upload its certificates and compliance documents (PDF, JPEG or PNG, up to 10 MB), which wait for staff to accept or reject them with a reason the supplier can see; nothing a supplier uploads changes the company's records until staff accept it. The change history page opens again even after large batches of changes.

# MES-9c — hand-back (2026-10-20) · certificate uploads and staff review, with the change-history fix (F19)

The brief "MES-9b close-out + MES-9c build: certificate uploads and staff review, with the change-history timeout fix (v1.4.62)". MES-9c answers the write third of
`docs/surveys/MES-9/STEP0-HANDBACK.md` with Tim's §15 rulings (every MES-9c recommendation accepted as stated, Q19 and Q25 included) and the brief's answers:
**V39 = 10 MB per file, PDF / JPEG / PNG, set in this cut's migration**; F19 done first. **It is the last cut of the MES group** — `docs/forward-queue.md` item 60.
Readings: `docs/surveys/MES-9c/readings/`.

## 1 · Step 1 — MES-9b close-out (committed and pushed first)

Commit **`bc4e461b`** "MES-9b close-out" (`50a4e552..bc4e461b`); fresh-clone build of that commit `CI_EXIT=0` · `BUILD_OWN_EXIT=0`. Evidence in full:
`docs/surveys/MES-9c/MES-9b-CLOSEOUT.md`.

- **Opening check** (2026-10-20 10:20:10 CST, this session's first command): tree clean; `HEAD` = `origin/main` = `git ls-remote origin main` =
  `50a4e55278924d8c22684fc3f3d03a7426e41c08`; no git command refused.
- **Broken window closed** in `docs/forward-queue.md` (item 59, the MES-9a format): start **2026-10-19 23:47:32** (measured, `db/migration-windows.tsv`) ·
  end lower bound **2026-10-20 02:01:36** (measured, the push in the reflog; it carried only `50a4e552`) · upper bound **2026-10-20 10:20:10** (derived — this
  session's first command, resting on Tim's "deployed", not a reading of Vercel) → **at least 2 h 14 min 04 s, at most 10 h 32 min 38 s**.
- **Read-only verification:** the MES-9b brief's 8-item fixture list (from the MES-9b session transcript) mapped item by item — **7 fully covered** by fixture
  276 arms (DOCS · DELIV · OPEN · STORE · LOG · EXCL · EVERY · WRITES · GRANTS), fixture 275 EVERY and verdict 8; **item 1 (the hash re-check and 409) covered for
  its database half only** — the re-check is the route, proved once by the local-rebuild download proof. A gap in the record only, already listed under
  `MES9A-APP-HALF-NO-REGRESSION-CHECK`; that entry said the 409 was proved by the *live* proof — it was the *local-rebuild* proof; corrected in the commit. MES-9b's
  22 self-taken decisions listed by title. Nothing missing in the behaviour, so step 2 went ahead.

## 2 · F19 — the change-history timeout (done first)

**Measured before** (read-only, as admin `321f1819…` switched to `authenticated`, 10:26 CST, `readings/f19-before.txt`, `docs/surveys/MES-9c/f19-measure.sql`):
the page's default request (`change_log_rows(p_by_entry => true, p_limit => 21)`) read **381 rows** for its 21 operations (360 of them one throwaway-role grant
batch) in **9,557 ms** and **6,455 ms** — the first over the 8 s cap. The time is the per-row trail work: over the same rows, `trail_row_record` ≈ 3.4 s,
`trail_refs` ≈ 1.5 s, the read-rule check ≈ 1.0 s. The **deployed** (old) page as cfo and admin copies → **HTTP 500** (18,373 ms · 14,639 ms;
`readings/f19-deployed-before.txt`).

**The change (smallest):** `change_log_rows` gained `p_row_before` · `p_row_limit`. The page still selects the same operations (`p_before` · `p_limit`) but takes
their rows **at most 100 per call** (`ROW_PAGE`), so one call's cost is bounded whatever the window holds. What is read, who may read it and the masking are
untouched; without the new parameters the function answers exactly as before. The signature changed, so the migration drops the twelve-argument one first.

**Measured after** (this cut's page on a local `next start` against live, `readings/live-proof.txt`): the same request, paged — **328 rows in 4 calls, slowest
1,704 ms** (1,704 · 1,538 · 1,571 · 476 ms); the page as cfo and admin copies → **HTTP 200** (20,342 ms · 12,614 ms wall clock from this machine, ~0.5 s per round
trip to Supabase; smoke also 200). The criterion is each statement well under 8 s, not the page's seconds.

**Fixture 278** loads 523 change-log rows of one bulk operation (520 roles in one transaction) and asserts: the paged reading equals the single reading row for
row, every column (SAME); each call ≤ 100 rows and ≤ 4 s (BOUND; rebuild: 6 calls, slowest 147 ms); the old readings unchanged (ROWMODE). Fault cells: row limit
ignored → BOUND red; cursor `<=` → SAME red; cursor ignored → BOUND red. `CHANGE-HISTORY-8S-AFTER-BULK-GRANTS` closed with these numbers.

## 3 · What was built

- **V39** — `account_settings.portal_upload_max_bytes` (10,485,760) · `portal_upload_types` (`application/pdf`, `image/jpeg`, `image/png`), added with Tim's values
  as **defaults** (`ADD COLUMN … DEFAULT`: the live row took them without an UPDATE; the fresh-install bootstrap has them too — the bootstrap default is correct,
  it is Tim's number). A `pending_values` arm V39 lists a row only if a value is cleared (then uploads refuse by name). Shown read-only on `/settings/accounts`;
  changing it takes a migration.
- **`portal_certificate_submissions`** — one row per certificate a portal account sent: link, account, supplier, certificate type, number, validity, file name /
  type / size, path in `portal-uploads`, status `uploading → submitted | abandoned`, `submitted → accepted | rejected`, decided at / by, reject reason (required
  for rejected), and on acceptance the `supplier_compliance` and `supplier_attachments` rows it created (CHECKs tie each status to its columns). Written only by
  functions; read by `module.suppliers.view`; change-logged (exclusions stay 9); no masked column; a member of the supplier's trail.
- **Portal functions** (SECURITY DEFINER, each opening with `portal_require_link()`, no supplier id ever a parameter, executable by `supplier_portal` only):
  `portal_certificates()` (its supplier's certificates on file — type, number, valid until; its own submissions and their state with the reject reason; the
  certificate types; V39) · `portal_submission_begin(...)` (**refuses by name before any byte is stored**: `PORTAL_UPLOAD_LIMITS_NOT_SET` ·
  `PORTAL_UPLOAD_TYPE_NOT_ACCEPTED` · `PORTAL_UPLOAD_EMPTY` · `PORTAL_UPLOAD_TOO_LARGE` · `PORTAL_CERT_TYPE_UNKNOWN` · `PORTAL_CERT_DATES_INVALID`; then one
  `uploading` row and its path) · `portal_submission_finish(id)` (the bytes must be there and match the declared size and type → `submitted`) ·
  `portal_submission_abandon(id)` · `portal_can_upload_object(bucket, name)` (the storage policies' judge; never raises).
- **Staff functions** (`module.suppliers.edit`, Q19): `portal_submission_accept(id, copied path, number, issuing body, from, until)` — in one transaction checks
  the copy really is in `supplier-attachments` under the supplier's folder with the same size, inserts the attachment row and the `supplier_compliance` row
  (type from the submission; staff confirm number and dates), marks the submission accepted; `portal_submission_reject(id, reason)` — reason required.
- **Storage** — bucket `portal-uploads` (private, 10 MB, PDF / JPEG / PNG); `supplier_portal` gets `INSERT` on `storage.objects`; policies
  `portal uploads its own pending submission file` (INSERT) and `portal reads its own pending submission file` (SELECT, for the Storage API's read-back), both
  `portal_can_upload_object` — only the path of the account's own `uploading` submission, registered in the last ten minutes; `portal-uploads read by
  suppliers.view` (staff). No update or delete policy. Storage policies 53 → 56, buckets 19 → 20.
- **`/portal/certificates`** (certificates on file, what it has sent and what happened, the upload form with V39 printed) and **`/portal/certificates/upload`**
  (POST multipart: asks the database for V39 and refuses an oversized body by its Content-Length before reading it; **judges the type from the file's own first
  bytes**; `portal_submission_begin` → the session's own token uploads the bytes → `portal_submission_finish`; on a failed upload `portal_submission_abandon`;
  staff session → 403). The portal home links to it.
- **Supplier page** — "Certificates sent through the portal": waiting ones first; open the file (60 s signed link), accept (copies the file with the staff
  member's own session, then `portal_submission_accept`; a failed accept removes the copy and says whether that worked), reject with a reason; decided ones
  with who and when. Controls need `module.suppliers.edit` — shown, unpressable and naming the code otherwise.
- **Trail** — the portal account's rows read "Supplier portal — <supplier name>"; sentences pinned in check-trail-wording ㊲ (fault `wording-drift-mes9c`).
- **Fold-in found by the survey** — `/settings/change-history` at 390 px overflowed +21 px (its filter selects sized by the longest option); `max-w-full` (the
  `/settings/approvals` precedent) → 0 px; 1280 px unchanged (usable).

**Two real defects found by the local proof and fixed before the migration:** ① the route left optional fields out when empty, and with no DEFAULTs PostgREST could
not resolve `portal_submission_begin` (the accept action had the same shape) — the optional parameters now have `DEFAULT NULL` (begin's moved to the end);
② when the file header was not recognised the route fell back to the browser's declared type, so a GIF renamed `.pdf` and sent as `application/pdf` was accepted —
an unrecognised header now goes to the database as `application/octet-stream` and is refused by name.

## 4 · Backup (before the migration) — `db/backup.sh`, `readings/backup.txt`, **`BACKUP_EXIT=0`**

| check | reading |
|---|---|
| start (read 11:06:18 CST) | `change_log` count **67,682** · min(seq) **1** · max(seq) **74,981** |
| main dump | **`MAIN_DUMP_EXIT=0`** (1,156 s) · 7.5 MB · TOC **9,745** (previous 9,721, floor 8,748) |
| chunks | **15**, every **`CHUNK_EXIT=0`**, all on the first try, 5–21 s each |
| rows / first / last | **67,682 = 67,682** · first seq **1 = 1** · last seq **74,981 = 74,981** (manifest `readings/backup-manifest.txt`) |

## 5 · `supplier_portal` baseline lines added (`db/portal-grants-baseline.tsv`, 34 → 42, verdict 8)

| kind | object | privilege |
|---|---|---|
| function | `public.portal_certificates()` | EXECUTE |
| function | `public.portal_submission_begin(p_cert_type text, p_file_name text, p_file_type text, p_file_size bigint, p_cert_no text, p_valid_from date, p_valid_until date)` | EXECUTE |
| function | `public.portal_submission_finish(p_submission_id uuid)` | EXECUTE |
| function | `public.portal_submission_abandon(p_submission_id uuid)` | EXECUTE |
| function | `public.portal_can_upload_object(p_bucket text, p_name text)` | EXECUTE |
| relation | `storage.objects` | INSERT |
| policy | `storage.objects` | portal uploads its own pending submission file |
| policy | `storage.objects` | portal reads its own pending submission file |

Full gate: **42 lines equal on rebuild and live**.

## 6 · Sign-in checks, per account (after the migration, deployed app; `db/scripts/2026-10-19-mes9a-signin-checks.mjs` → `readings/signin-checks.txt`, `MES9A_SIGNIN_EXIT=0`)

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

The hook, sign-in, refresh, idle logout and the display exemption were not changed (the migration's self-proof re-asserts the hook returns the 7 real accounts'
events byte-for-byte unchanged).

## 7 · Live verification — `db/scripts/2026-10-20-mes9c-live-proof.mjs` → `readings/live-proof.txt`, **`MES9C_PROOF_EXIT=0`**

A local `next start` (port 3196) built from this cut's tree, against live; throwaway prefix `mes9cprobe`, suppliers `ZZ-PROBE`. Committed on live: **only** the
throwaway suppliers, contacts, portal links and accounts (removed by the plan). Run 1 (`live-proof-run1.txt`) stopped on a driver bug in my transaction leg
(`%s` where `%L` was needed for a jsonb literal) — the HTTP leg, F19 and the role table all passed in it; it rolled back and left nothing.

- **HTTP:** both portal users → `/portal` links to its certificates; `/portal/certificates` the empty state (none on file, none sent), "Up to 10 MB per file ·
  PDF · JPEG · PNG", the form, nothing of the other; PostgREST `portal_certificates` → own supplier, V39 = 10485760 · PDF / JPEG / PNG, 9 types; **upload of
  10.2 MB → `?error=PORTAL_UPLOAD_TOO_LARGE&p=10485760`; a GIF → `?error=PORTAL_UPLOAD_TYPE_NOT_ACCEPTED`**; the page names the refusal; the Storage API with
  the portal token to a portal-uploads path with no submission → 400; submissions / objects / certificates / attachments unchanged (`0|0|2|4|2`); a cco copy
  POSTing the route → 403, on `/portal/certificates` → refused; `/portal`, `/portal/certificates` (and with a refusal notice) overflow **0 px** at 390 and 1280.
- **F19:** §2.
- **Inside one rolled-back transaction, every trigger on, with the portal users' real token claims as `supplier_portal`:** V39 refusals at begin (size, GIF);
  A's begin → one `uploading` row under its supplier; **the platform's own upload pre-check `storage.can_insert_object` admits A's registered path (PT200) and
  refuses another path and B (42501)**; A's object row through the live policy; B cannot finish A's; A's finish → waiting; only submission rows written; a gm
  copy cannot review (PERMISSION_DENIED); the portal cannot call the review functions (42501); the cco copy stores the copy's row in `supplier-attachments`
  (live upload policy) and accepts → one `supplier_compliance` row with the copied file attached; a second submission rejected — without a reason refused, with a
  reason done; A sees accepted and rejected-with-reason and the new certificate on file; B sees none of it and cannot touch it; the trail names the portal for
  the portal's 4 rows. After the ROLLBACK the counts are back (`0|0|2|4|2 = 0|0|2|4|2`).

### Role table — A's supplier page (review section) and `/settings/change-history`, as each of the 7 real roles' permissions (read-only, throwaway clones)

| Role (clone) | Codes | Supplier page | Review section | Can review (`module.suppliers.edit`) | `/settings/change-history` |
|---|---|---|---|---|---|
| admin | 86 | 200 | sees ("Nothing has been sent through the portal.") | yes | opens |
| cco | 50 | 200 | sees | yes | refused (no `data.view_change_log`) |
| cfo | 36 | 200 | sees | no — shown, unpressable, names the code | opens |
| cto | 41 | 200 | sees | yes | refused |
| finance | 43 | 200 | sees | yes | refused |
| gm | 23 | 200 | sees | no — shown, unpressable, names the code | refused |
| warehouse | 31 | 200 | sees | yes | refused |

All seven hold `module.suppliers.view`; only admin and cfo hold `data.view_change_log` (unchanged, HISTORY-1).

### Before / after (`readings/live-before.txt` 11:05 · `live-after.txt` 12:54, `docs/surveys/MES-9c/live-readings.sql`, as `postgres`)

Every difference is the migration: portal functions 6 → 11, portal storage policies 1 → 3, `storage.objects` INSERT for the portal, V39 set, submissions table
(0 rows), `change_log_rows` fourteen arguments, bucket `portal-uploads` (10 MB · PDF / JPEG / PNG, 0 objects), storage policies 53 → 56 (the md5 over the 53
pre-existing **unchanged**), tables 324 → 325, pending arms 36 → 37 — and the change log 67,682 → 71,659 rows (append-only: sign-in checks, smoke, survey,
proofs' throwaways). **Unchanged:** 7 accounts, 0 disabled, roles admin · finance · warehouse · cto · cco · cfo · gm as before; throwaways 0 (probe roles,
`test.local`, `mes9*probe` accounts, `ZZ-PROBE` suppliers / contacts, `ZZ-PROBE-MES9C` rows, orphan grants); portal links 0; pending `CLM-2026-0004` only (not
mine; eligible approver tim@); `require_calibrated_since` NULL; both CODs' recorded sha256 (`ba299a4f…f42101` · `717661f6…13a4f9`) and snapshot md5s identical;
**all 40 stored objects identical line for line** (md5 `2ff2f65e…`), so every bucket holds exactly what it held; every table fingerprint identical
(`account_settings` without the two new columns included); reconciliation AP **0.00** · AR **0.00** · inventory raw **0.00** · fg **0.00** unexplained.

## 8 · The local-rebuild HTTP proof — `db/scripts/2026-10-20-mes9c-local-upload-proof.mjs` → `readings/local-upload-proof.txt`, **`MES9C_LOCAL_PROOF_EXIT=0`**

A throwaway local cluster built the way `db/gate.py` builds it, two suppliers with a portal account each (live sessions), a staff editor and a staff viewer. The
**unchanged** route `app/portal/certificates/upload/route.ts` and the **unchanged** actions `app/suppliers/[id]/edit/portalSubmissionActions.ts` loaded with jiti,
`@/lib/supabase/server` bound to that database (every call as the acting identity, real RLS; storage writes are real `storage.objects` inserts under the real
policies, bytes on disk). Proved: **oversize → `?error=PORTAL_UPLOAD_TOO_LARGE`, no submission, no object; a GIF → `TYPE_NOT_ACCEPTED`, nothing stored; a GIF named
.pdf and sent as application/pdf → judged by its bytes, refused; a staff session → 403; a valid PDF → `?submitted=1`, one waiting submission, its bytes in
`portal-uploads`; a valid PNG → waiting;** no certificate and no attachment from an upload; a viewer accepting → refused, nothing copied; the editor accepting →
certificate `nea_import` with the checked number, the file copied (same bytes) into `supplier-attachments` and attached; rejecting without a reason refused, with a
reason done; editor and viewer can open the file; **the supplier's view (`portal_certificates`, what `/portal/certificates` renders) shows accepted and
rejected-with-reason and the certificate on file; B sees nothing.**

**Live vs local, exactly:** on **live** — sign-in, the portal pages' empty state and layout, V39's two refusals over HTTP (nothing stored), the Storage API refusing
an unregistered path, staff refusals, F19 over HTTP and in the database, and (rolled back) the whole submission → acceptance / rejection path with real token
claims, the live storage policies and the platform's own upload pre-check. On the **local rebuild** — the route storing a valid file, the accept / reject actions
end to end, and the supplier's view with a status and a reason. In **fixtures 277 / 278** (rebuild, every gate) — all of the database rules, fault-injected.
**Not proved anywhere:** a real Storage API upload of bytes into a committed submission's path (needs a committed submission on live) —
`MES9C-LIVE-STORAGE-UPLOAD-BY-POLICY-NOT-BY-API`.

## 9 · Pages (route → file)

| Route | New / changed | Files |
|---|---|---|
| `/portal` | changed — a link to the certificates page | `app/portal/page.tsx` |
| `/portal/certificates` | new | `app/portal/certificates/page.tsx` |
| `/portal/certificates/upload` | new (Route Handler, POST multipart) | `app/portal/certificates/upload/route.ts` · `app/portal/portalErrorCodes.ts` |
| `/suppliers/[id]/edit` | changed — the review section | `app/suppliers/[id]/edit/page.tsx` · `PortalSubmissionsPanel.tsx` · `PortalSubmissionForms.tsx` · `portalSubmissionActions.ts` |
| `/settings/change-history` | changed — rows read in pages of 100 (F19); filter selects fit 390 px | `app/settings/change-history/page.tsx` |
| `/settings/accounts` | changed — V39 shown read-only | `app/settings/accounts/page.tsx` · `AccountSettingsPanel.tsx` |
| every supplier trail | changed — the submissions as members, their sentences | `lib/trail/render.ts` · `lib/trail/text.ts` · `lib/trail/catalogue.generated.ts` |
| (messages) | en + zh | `messages/en.ts` · `messages/zh.ts` |

Layout survey (`scripts/survey-phone.mjs`, staff session, `readings/survey-390.txt` · `survey-1280.txt`): the supplier page with its review section,
`/settings/change-history`, `/portal/certificates` and `/portal` (both a staff refusal there) at **390 px 4/4 usable** and **1280 px 4/4 usable**, self-test passed;
the first 390 run found the +21 px on `/settings/change-history` (`survey-390-before-fix.txt`), fixed, re-surveyed 0. Portal pages as a portal user: §7.

## 10 · Verification, in the brief's order

| # | Step | Result |
|---|---|---|
| 1 | offline gate | `GATE_EXIT=0` (`readings/gate-offline.txt`; rerun after the DEFAULT fix, green both times) |
| 2 | backup in parts | `BACKUP_EXIT=0` (§4) |
| 3 | dry run COMMIT→ROLLBACK | `DRY_OWN_EXIT=0` (`readings/migration-dry-run.txt`): inside 325 tables, 11 portal functions, storage INSERT, 56 policies (3 portal), 20 buckets, V39, exclusions 9, gaps 0, `change_log_rows` 14 args (authenticated yes, anon no); after rollback 324 / 53 / 19 / 12 args. Before it, the file was applied locally to a database built from **this cut's predecessor's mirrors**: its `pg_dump -s` equals a fresh rebuild of the new mirrors (only pg_dump's random restrict token differs; `readings/migration-local-proof.txt`) |
| 4 | apply | `APPLY_OWN_EXIT=0`; **window start 2026-10-20 11:33:56 CST** (`db/migration-windows.tsv`) |
| 5 | sign-in checks | `MES9A_SIGNIN_EXIT=0` (§6) |
| 6 | types | `TYPES_OWN_EXIT=0` (+191 lines) |
| 7 | tsc | `TSC_OWN_EXIT=0` |
| 8 | build | `BUILD_OWN_EXIT=0` (first attempt stopped on the eslint freeze gate: two unused variables in my own proof scripts — fixed); rebuilt after the change-history fix, `BUILD_OWN_EXIT=0` (`readings/build.txt`) |
| 9 | full gate | `GATE_EXIT=0` (`readings/gate-full.txt`): colgrant live / rebuild 523 relations in 14 batches · viewwrite 198 both sides · change log 325 / 316 / **9** both sides · fixtures 274–278 ✓ · live fixture 266 ✓ · anon 327 · no-role 126 · storage mirror 20 / 56 = live · **portal 42 lines equal both sides** |
| — | injections on a fresh rebuild after the last DB edit | **53 / 53** (44 cells + 5 baselines + 4 verdict-8 cells), `INJ_OWN_EXIT=0` (`readings/injections-fresh-rebuild.txt`; first run 53 / 53 too, `injections-first.txt`) |
| 10 | i18n | `I18N_OWN_EXIT=0` |
| 11 | error swallowing | `SWALLOW_OWN_EXIT=0` |
| 12 | layout survey | §9 |
| 13 | smoke | **`SMOKE_EXIT=0`**: 304 ok · 25 skipped (no data) · 0 failed; `/settings/change-history` 200; `/portal/certificates/upload` registered `[405]` (GET on a POST-only route). Scratch reading at start: the same 6 stale `ZZ-SMOKE` rows (1,149–1,791 h old, five still referenced) — pre-existing, not mine, not touched; its own throwaways removed (closing reading: 0) |
| 14 | live verification + local HTTP proof | §7 `MES9C_PROOF_EXIT=0` · §8 `MES9C_LOCAL_PROOF_EXIT=0` |
| 15 | fresh-clone build | in the closing report (a file cannot carry the result of building itself) |

Files changed after the full gate: `app/settings/change-history/page.tsx` (two classes), the two proof scripts, the F19 "before" script, docs and readings — none read by
the database half of the gate; the static half ran inside the rebuild after the last of them (step 8).

## 11 · Broken window

Start **2026-10-20 11:33:56 CST** (measured). End = when Tim sees the deploy succeed in Vercel (filled in at the next close-out). **What is broken inside it**
(derived, plus one reading): nothing in use. The deployed app is MES-9b's over the new database; it reads none of the new objects; no portal account exists on
live; `change_log_rows` without the new parameters answers as before — so the deployed change-history page still times out (measured HTTP 500, §2), exactly as it
did before this cut, until the deploy.

## 12 · Decisions taken without asking

1. **F19 by paging the rows, not by trimming what is read** — one call's work is bounded; the rows and the masking are identical (fixture 278 SAME).
2. **`change_log_rows` signature changed (DROP + CREATE)** rather than a second function — one reader, as HISTORY-1 required.
3. **V39 stored on `account_settings` as two column defaults** — no new table, no UPDATE on live, bootstrap = Tim's values; **no setter** (changing it takes a migration).
4. **A V39 pending arm anyway** (empty unless cleared) — the pending-values rule (an arm per value).
5. **Two-step upload (begin → bytes → finish, abandon on failure)** — so V39 is judged by the database before any byte is stored, and a row is never "waiting" without its bytes.
6. **The type is judged from the file's first bytes**, never from the browser's claim; an unrecognised header goes in as `application/octet-stream` (refused).
7. **Oversized bodies refused by Content-Length before reading**, using V39 from the database plus a 64 KB multipart allowance.
8. **The storage judge admits only the account's own `uploading` path, for ten minutes**; the same judge on a SELECT policy for the Storage API's read-back.
9. **No delete policy on `portal-uploads`** — submitted bytes are the submission's evidence (`MES9C-ABANDONED-UPLOAD-BYTES-STAY` for the one leftover case).
10. **Staff copy the file with their own session** (Storage `copy` across buckets), then `portal_submission_accept` verifies the copy exists with the same size; a failed accept removes the copy.
11. **The certificate type comes from the submission; staff confirm number, issuing body and dates** (empty → the supplier's values).
12. **The attachment row created on acceptance has no category and no note** (no machine text written into data).
13. **The portal shows its certificates on file** (type, number, valid until — Step 0 §4) as well as its submissions; never who reviewed.
14. **`uploading` and `abandoned` rows are listed nowhere** (neither portal nor staff); they appear only in the trail.
15. **Optional parameters `DEFAULT NULL`** (begin's moved to the end) — found by the local proof.
16. **The staff review controls sit after the portal-accounts section**, inside the supplier page's existing ended-supplier fieldset.
17. **The `/settings/change-history` 390 px fix folded in** (`max-w-full`), found by this cut's survey on a changed page.
18. **Fixture numbering: 277 for MES-9c, 278 for F19.**
19. **Fixtures 275 / 276 hand the five MES-9c functions to 277 by name**; 277 asserts the three fixtures together cover the catalogue.
20. **Fixture 274 and live fixture 266 accept the two portal-uploads policies by name and judge; counts moved 53 → 56 and 19 → 20 buckets.**
21. **The live proof's transaction leg calls `storage.can_insert_object`** as the portal role — the platform's own pre-check — to get as close to a real upload as a rolled-back transaction allows.
22. **F19's "before" over HTTP measured on the deployed app** with throwaway cfo / admin copies (`db/scripts/2026-10-20-mes9c-f19-deployed-before.mjs`).
23. **The live proof's role table judges "can review" by `module.suppliers.edit` held** — no committed submission on live means no buttons to press.
24. **Sign-in checks reuse MES-9a's script unchanged** (its prefix `mes9aprobe`).
25. **The local proof drives the route and the server actions, not a rendered page** (no Next renderer locally; `MES9C-REVIEW-PAGE-NOT-RENDERED-WITH-A-SUBMISSION`).
