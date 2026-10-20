# MES-9c close-out (2026-10-20)

Brief: "MES-9c close-out + state of the queue", step 1. Docs only — no code edit, no database change, no live write. Live reads: two, both read-only
(§2 and the pending-values reading in `docs/state-of-the-queue-2026-10-20.md` §c).

**Opening check (2026-10-20 13:36:11 CST, this session's first command).** Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
`321465556a1ed28e317b17973369cb9ea791b456`. No git command refused.

## 1 · Broken window (1.1)

| | Time (CST) | Source |
|---|---|---|
| start | **2026-10-20 11:33:56** | measured: `db/migration-windows.tsv` line 244 (`2026-10-20-mes9c-certificate-uploads.sql`, `bc4e461b`), printed by `apply_migration.sh` (`docs/surveys/MES-9c/readings/apply.txt`) |
| end, lower bound | **2026-10-20 12:59:59** | measured: `git reflog show --date=iso refs/remotes/origin/main` → `32146555 refs/remotes/origin/main@{2026-10-20 12:59:59 +0800}: update by push`; the push `bc4e461b..32146555` carried only the cut's own commit `32146555` (committed 2026-10-20 12:58:03, `git log bc4e461b..32146555`) |
| end, upper bound | **2026-10-20 13:36:11** | derived: this session's first command (`date`), with Tim's "deployed" already in hand. That is Tim's report of what he saw, not a reading of Vercel |

**Broken window: at least 1 h 26 min 03 s, at most 2 h 02 min 15 s.** It bounds the window; it does not measure it.

What was broken inside it (derived — MES-9c hand-back §11, not measured on live here): nothing in use. The deployed app was MES-9b's over the new database; it
read none of the new objects; no portal account existed on live; `change_log_rows` without the two new parameters answers as before, so the deployed
change-history page still timed out after bulk operations (HTTP 500, hand-back §2) exactly as it did before the cut, until the deploy.

## 2 · The access-token hook on live (1.2)

Read 2026-10-20 13:38:11 CST, `GET https://api.supabase.com/v1/projects/wvywpohbwkiinmipmuku/config/auth` with the CLI token, **only the two `hook_*` fields
selected** (`jq '{hook_custom_access_token_enabled, hook_custom_access_token_uri}'`; no other field of the response was printed or stored):

```
{"hook_custom_access_token_enabled":true,"hook_custom_access_token_uri":"pg-functions://postgres/public/portal_access_token_hook"}
```

**The hook is enabled**, pointing at `public.portal_access_token_hook` — unchanged since MES-9a (enabled 18:00:43, off 39 s 18:03:53 → 18:04:32 CST on
2026-10-19, on since). `docs/known-issues.md` `MES9A-HOOK-IS-A-PROJECT-SETTING` still applies: neither the database nor the gate can see this setting; this
reading is the only record of it today.

## 3 · Read-only verification (1.3)

### a · The MES-9c brief's fixture list, item by item

The list is the brief's "Fixtures must cover:" sentence. The brief exists only in the MES-9c session transcript
(`~/.claude/projects/-Users-timchen/4a5d6221-….jsonl`, user message 2026-10-20T02:20:04Z, line 94 of the brief), quoted here in item order. Paths:
`db/fixtures/277-a-supplier-sends-a-certificate-that-changes-nothing-until-staff-accept-it.sql` (277),
`db/fixtures/278-the-change-history-reads-a-bulk-operation-in-bounded-pages-and-loses-no-row.sql` (278), `db/check_portal.py` (verdict 8),
`docs/surveys/MES-9c/readings/injections-fresh-rebuild.txt` (INJ, 53 / 53, `INJ_OWN_EXIT=0`).

| # | Item | Covered by | Evidence |
|---|---|---|---|
| 1 | F19's bulk-row timing and its fault cell | **278 BULK · SAME · BOUND · ROWMODE** | `278:25-83` — 523 change-log rows of one operation (520 roles in one transaction); the paged reading equals the single reading row for row (SAME); each call ≤ 100 rows and ≤ 4 s (BOUND; rebuild 6 calls, slowest 147 ms, INJ:49); old readings unchanged (ROWMODE). Fault cells INJ:35-37 — row limit ignored → BOUND red; cursor `<=` → SAME red; cursor ignored → BOUND red |
| 2 | V39's size and type refusals before any byte is stored | **277 V39** (database half) · **no fixture arm** for the route's own pre-checks | `277:127-155` — 10 MB + 1 byte → `PORTAL_UPLOAD_TOO_LARGE|10485760`; a GIF → `PORTAL_UPLOAD_TYPE_NOT_ACCEPTED`; empty, unknown type, bad dates, V39 cleared → each by name; after every refusal the submissions table and `storage.objects` gained nothing; with no `uploading` submission the portal cannot store bytes at any `portal-uploads` path (42501). Fault cells INJ:2-5. The route's Content-Length refusal before reading the body and its first-bytes type judgement (`app/portal/certificates/upload/route.ts:5-6`, `:35`, `:72`) are app code a SQL fixture cannot reach; proved by the live HTTP proof (10.2 MB → `TOO_LARGE`, GIF → `TYPE_NOT_ACCEPTED`, nothing stored) and the local-rebuild proof (a GIF named .pdf sent as `application/pdf` refused by its bytes) — hand-back §7–§8 |
| 3 | an upload creating only a submission | **277 ONLY** | `277:156-205` — begin → bytes → finish changes only the submissions table and the bucket; every other `public` table's fingerprint identical (stock, prices, ledger, certificates, attachments); change log gains only the submission's rows, authored by the portal account. Fault cells INJ:6-8 |
| 4 | accept creating the `supplier_compliance` row and copying the file | **277 ACCEPT** (database half) | `277:247-283` — no copy → `PORTAL_SUBMISSION_FILE_NOT_COPIED`; copy in another supplier's folder → `FILE_PATH_INVALID`; after the staff copy (an insert into `supplier-attachments` under the live-shaped policy) one `supplier_compliance` row (type from the submission, number and dates as staff confirmed) and one `supplier_attachments` row, submission accepted with both links; only those two tables changed; second accept → `NOT_WAITING`; the portal sees accepted and the new certificate. Fault cells INJ:19-22. The Storage API copy itself and the cleanup on a failed accept are the server action (`app/suppliers/[id]/edit/portalSubmissionActions.ts`), proved by the local-rebuild proof (hand-back §8) |
| 5 | reject requiring a reason shown to the supplier | **277 REJECT** | `277:284-307` — blank reason → `PORTAL_SUBMISSION_REASON_REQUIRED`; with a reason → rejected, no certificate, no attachment, nothing else changed; `portal_certificates()` (what `/portal/certificates` renders) returns `rejected` with the reason; second reject refused. Fault cells INJ:23-24. The page rendered with a rejected submission: registered `MES9C-REVIEW-PAGE-NOT-RENDERED-WITH-A-SUBMISSION` |
| 6 | review only by `module.suppliers.edit` | **277 REVIEW** | `277:225-246` — accept and reject by a `module.suppliers.view` holder and by a no-code reader → `PERMISSION_DENIED`; the portal → 42501; a view holder reads the submissions and the file, a no-code reader 0, the portal cannot read the table. Fault cells INJ:15-18 |
| 7 | two suppliers each refused the other's submissions | **277 EVERY** (with **275 / 276 EVERY** for the six earlier portal functions) | `277:308-408` — enumerates every function `supplier_portal` can execute from the catalogue; each of the five MES-9c functions has a two-supplier case (A sees only A, B only B; the other's submission / path refused; staff sessions 42501; bad claims, ended session, no session, not a portal account, banned → by name; `portal_can_upload_object` answers false, never raises); the three fixtures together must equal the catalogue. Fault cells INJ:25-29 |
| 8 | the `supplier_portal` baseline updated by name and the census check's fault cells | **verdict 8** (a gate check, not a fixture) · **277 GRANTS** | `db/portal-grants-baseline.tsv` 42 lines (8 new, hand-back §5); `db/check_portal.py:251-297` always-on self-tests ① unreadable baseline · ② blinded query · ③ probe grant · ④ removed baseline line; injected cells INJ:50-54 (extra storage UPDATE named · storage INSERT revoked named missing · `portal_submission_begin` revoked named missing · a deleted baseline line named · always-on cells bit). `277:409-436` — five functions SECURITY DEFINER for `supplier_portal` only; two staff functions not for the portal; `storage.objects` INSERT (no UPDATE / DELETE); exactly three storage policies for the role, two by name. Fault cells INJ:30-31 |
| 9 | the trail wording | **check-trail-wording ㊲** (in `npm run build`) · **277 TRAIL** | `scripts/check-trail-wording.mjs:7719-7777` — the gold sentences for begin · send · not sent · accept · reject, with the fault `wording-drift-mes9c` (`:7723`, must go red, `:7777`). `277:437-447` — `trail_actor` names the portal and the supplier; the rejection with its reason is in the change log under the reviewer; submissions are members of the supplier's trail. Fault cell INJ:32 |
| 10 | change-log exclusions at 9 | **277 EXCL** | `277:448-456` — `change_log_coverage_gaps()` 0 gaps, excluded = 9; the submissions table not excluded and not masked; V39 pending arm 0 rows set, 1 row cleared (`277:143-148`). Fault cells INJ:33-34 |

**Result: nothing is missing in the behaviour.** 8 of 10 items are fully covered by a fixture arm or a gate / build check. **Items 2 and 4 are covered for
their database half only**: the route's pre-read size refusal and byte-sniffing (item 2) and the staff session's Storage copy with its failure cleanup
(item 4) are app code a SQL fixture cannot reach; each was proved once by the MES-9c local-rebuild proof (and item 2 also over HTTP on live). That is the
`MES9A-APP-HALF-NO-REGRESSION-CHECK` shape; `docs/known-issues.md:66-67` already lists `/portal/certificates` and `/portal/certificates/upload` under it.
**A gap in the record only, not in the behaviour.**

### b · MES-9c's decisions taken without asking (`docs/handbacks/MES-9c.md` §12), titles only

1. F19 by paging the rows, not by trimming what is read.
2. `change_log_rows` signature changed (DROP + CREATE) rather than a second function.
3. V39 stored on `account_settings` as two column defaults.
4. A V39 pending arm anyway.
5. Two-step upload (begin → bytes → finish, abandon on failure).
6. The type is judged from the file's first bytes.
7. Oversized bodies refused by Content-Length before reading.
8. The storage judge admits only the account's own `uploading` path, for ten minutes.
9. No delete policy on `portal-uploads`.
10. Staff copy the file with their own session.
11. The certificate type comes from the submission; staff confirm number, issuing body and dates.
12. The attachment row created on acceptance has no category and no note.
13. The portal shows its certificates on file as well as its submissions.
14. `uploading` and `abandoned` rows are listed nowhere.
15. Optional parameters `DEFAULT NULL`.
16. The staff review controls sit after the portal-accounts section.
17. The `/settings/change-history` 390 px fix folded in.
18. Fixture numbering: 277 for MES-9c, 278 for F19.
19. Fixtures 275 / 276 hand the five MES-9c functions to 277 by name.
20. Fixture 274 and live fixture 266 accept the two portal-uploads policies by name and judge.
21. The live proof's transaction leg calls `storage.can_insert_object`.
22. F19's "before" over HTTP measured on the deployed app.
23. The live proof's role table judges "can review" by `module.suppliers.edit` held.
24. Sign-in checks reuse MES-9a's script unchanged.
25. The local proof drives the route and the server actions, not a rendered page.

## 4 · Every MES cut is closed (1.4)

The MES-0 survey's cut plan (`docs/surveys/MES-0/README.md` §8.2, lines 689-720) has **15 recommended cuts**; Tim's rulings split them into **25 MES cuts**
(the MES group table, `docs/forward-queue.md:7919-7953`), plus **NOROLE-SURFACE**, which Tim placed before MES-9a as its own cut (MES-9 Q4 · Q30; table row 15-0,
not counted among the 25 — `docs/forward-queue.md:1292` calls MES-9a "the twenty-third"). Cut commit = the commit that carried the version; close-out commit =
the later commit that closed its broken window and checked it (`git log --format='%h %ad %s'`).

| MES-0 §8.2 cut | Cut as shipped | Version | Cut commit | Close-out commit | Queue item |
|---|---|---|---|---|---|
| MES-1 · Entry point | MES-1 | v1.4.37 | `95b43594` (2026-10-06) | `e4318683` | 36 |
| MES-2 · Confirmation, weighing, calibration | MES-2 | v1.4.38 | `3c024e82` (2026-10-06) | `e2e48e0b` | 37 |
| MES-3a · Storage safety | MES-3a | v1.4.39 | `34d7690b` (2026-10-07) | `8bf70218` | 38 |
| MES-3b · Labels and scanning | MES-3b | v1.4.40 | `437359d2` (2026-10-07) | `49ca62e2` | 39 |
| MES-4a · Processing record | MES-4a | v1.4.41 | `51bbdb42` (2026-10-07) | `0968eb98` · rulings `59a5ffae` | 40 |
| MES-4b · New fields and products | MES-4b | v1.4.42 | `2915f3f7` (2026-10-08) | `4c1fd8d1` | 41 |
| MES-5a · Discharge and energy | MES-5a-1 · Discharge | v1.4.43 | `96a2219e` (2026-10-08) | `5647ea6f` | 42 |
| | MES-5a-2 · Energy | v1.4.44 | `6a12e569` (2026-10-08) | `76e59c84` · rulings `a4647cdd` | 43 |
| MES-5b · Balance, yield, blending | MES-5b-1 · Balance and yield | v1.4.45 | `00744eff` (2026-10-08) | `e0adb388` | 44 |
| | MES-5b-2 · Reversals | v1.4.46 | `68aa5277` (2026-10-09) | `032f557a` | 45 |
| | MES-5b-3 · Blending | v1.4.47 | `45ca694c` (2026-10-09) | `cdfd6645` | 46 |
| MES-6a · Samples, arbitration, F/Cl | MES-6a-1 · Samples, arbitration, reversal reasons | v1.4.48 | `d645d5a7` (2026-10-09) | `0565de86` | 47 |
| | MES-6a-2 · F / Cl and quality indicators | v1.4.49 | `8ea0875e` (2026-10-10) — its production build failed; deployed through **HOTFIX-6A2** `1026dc94` (2026-10-14) | `d32a2f01` · rulings `cffc44dc` | 48 |
| MES-6b · NCR, quality hold, CoA | MES-6b-1 · NCR, quality hold, contract quality limits | v1.4.50 | `b7d39271` (2026-10-15) | `d57edf37` | 49 |
| | MES-6b-2 · CoA | v1.4.51 | `1ca90256` (2026-10-15) | `e8abff7a` | 50 |
| MES-7a · Spare parts and reliability | MES-7a-1 · Equipment reliability | v1.4.52 | `e689b241` (2026-10-16) | `99cb8d39` | 51 |
| | MES-7a-2 · Spare parts | v1.4.53 | `afd9977b` (2026-10-16) | `671fb4c3` | 52 |
| MES-7b · Inspections and incidents | MES-7b-1 · Incidents | v1.4.54 | `08d5fbf8` (2026-10-16) | `c25dc70c` | 53 |
| | MES-7b-2 · Safety inspections and environmental monitoring | v1.4.55 | `f30c256d` (2026-10-16) | `6af1b532` | 54 |
| MES-8a · Supplier scorecards and statements | MES-8a | v1.4.56 | `1ec4bc44` (2026-10-16) | `debb6a7a` | 55 |
| MES-8b · Analysis and display | MES-8b-1 · Inbound margin, inventory exposure, compliance pack | v1.4.57 | `f084de52` (2026-10-17) | `91083d75` | 56 |
| | MES-8b-2 · Wall display | v1.4.58 | `4236db6a` (2026-10-19) | `2aadbdc8` | 57 |
| MES-9 · Supplier portal | (NOROLE-SURFACE, row 15-0 — not an MES cut) | v1.4.59 | `c61acce6` (2026-10-19) | `4aae8e98` | — |
| | MES-9a · Identity and isolation | v1.4.60 | `44e98fdd` (2026-10-19) | `ba926879` | 58 |
| | MES-9b · What a supplier sees | v1.4.61 | `50a4e552` (2026-10-20) | `bc4e461b` | 59 |
| | MES-9c · Certificate uploads and staff review | v1.4.62 | `32146555` (2026-10-20) | **this commit** ("MES-9c close-out + state of the queue") | 60 |

**25 of 25 MES cuts closed** (and NOROLE-SURFACE). Every one of the 15 MES-0 cuts is accounted for by one or more shipped cuts; none remains open in the
MES group table (`docs/forward-queue.md:7919-7953`, every live row ✅, every split row struck). **The MES group is closed** — marked in
`docs/forward-queue.md` item 60 and at the group heading (line 7910).
