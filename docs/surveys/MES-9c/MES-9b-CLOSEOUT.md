# MES-9b close-out (2026-10-20)

Brief: "MES-9b close-out + MES-9c build: certificate uploads and staff review, with the change-history timeout fix (v1.4.62)", step 1. Docs only — no code
edit, no database change, no live write. Live reads: none were needed (every reading below is from git, from the repository, or from the MES-9b session's own
transcript).

**Opening check (2026-10-20 10:20:10 CST, this session's first command).** Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
`50a4e55278924d8c22684fc3f3d03a7426e41c08`. No git command refused.

## 1 · Broken window (1.1)

| | Time (CST) | Source |
|---|---|---|
| start | **2026-10-19 23:47:32** | measured: `db/migration-windows.tsv` line 243 (`2026-10-19-mes9b-what-a-supplier-sees.sql`), printed by `apply_migration.sh` (`docs/surveys/MES-9b/readings/apply.txt`) |
| end, lower bound | **2026-10-20 02:01:36** | measured: `git reflog show --date=iso refs/remotes/origin/main` → `50a4e552 refs/remotes/origin/main@{2026-10-20 02:01:36 +0800}: update by push`; the push `ba926879..50a4e552` carried only the cut's own commit `50a4e552` (committed 2026-10-20 01:59:44, `git log ba926879..50a4e552`) |
| end, upper bound | **2026-10-20 10:20:10** | derived: this session's first command (`date`), with Tim's "deployed" already in hand. That is Tim's report of what he saw, not a reading of Vercel |

**Broken window: at least 2 h 14 min 04 s, at most 10 h 32 min 38 s.** The upper bound is long because it runs overnight to this session's first command; it
bounds the window, it does not measure it.

What was broken inside it (derived — MES-9b hand-back §10, not measured on live here): nothing in use. The deployed app was MES-9a's over the new database; it
read none of the new objects; no portal account existed on live (the live proof's throwaways were created and removed inside the window); staff tokens were
unchanged (hand-back §5, `MES9A_SIGNIN_EXIT=0`).

## 2 · Read-only verification (1.2)

### a · The MES-9b brief's fixture list, item by item

The list is the brief's "Fixtures must cover every item restated above, including:" sentence. The brief exists only in the MES-9b session transcript
(`~/.claude/projects/-Users-timchen/639e83b2-….jsonl`, user message 2026-10-19T12:46:57Z), quoted here in item order. Paths:
`db/fixtures/276-a-supplier-sees-its-own-issued-documents-and-deliveries-and-every-download-is-logged.sql` (276), `db/check_portal.py` (verdict 8),
`db/scripts/2026-10-19-mes9b-local-download-proof.mjs` → `docs/surveys/MES-9b/readings/local-download-proof.txt` (LDP).

| # | Item | Covered by | Evidence |
|---|---|---|---|
| 1 | each document kind served only as its stored issued PDF with the hash re-checked and 409 on a mismatch | **276 OPEN** (database half) · **no fixture arm** for the re-check and the 409 | `276:225-256` — order, statement and certificate each answer bucket · path · **recorded** sha256 · filename, one log row each; nothing else is ever handed out. The re-check and the 409 are the route (`app/portal/documents/file/route.ts:56-58`), proved once by LDP (`local-download-proof.txt:17` — A's altered order → 409 "Stored document does not match its recorded digest"; `:22` the 409 attempt leaves its log row) |
| 2 | a document never issued, voided or superseded shown as such and never rendered from live data | **276 DOCS** · **276 OPEN** | `276:187-207` — an approved, never-issued order has `issues = []`; a void certificate has no document and names its replacement; a pending certificate has no number; a superseded statement names its replacement; no amount, price or note anywhere in the answer. `:250-251` a void certificate → `PORTAL_DOCUMENT_VOID` |
| 3 | receipts and weighbridge tickets without any price field | **276 DELIV** | `276:209-223` — code · quantity · unit · material · arrival date; a shared ticket carries only A's share; no unit price, pricing, plate or note (regex over the whole answer) |
| 4 | two suppliers each refused the other's documents, receipts and tickets in every portal function | **276 EVERY** (with **275 EVERY** for the two MES-9a functions) | `276:316-386` — loops over every function `supplier_portal` can execute (from the catalogue); A sees A and nothing of B, B the reverse; the other's document → `PORTAL_DOCUMENT_NOT_FOUND`; a function with no case in 275 or 276 goes red |
| 5 | the download log written only by the portal function and readable by staff | **276 LOG** · **276 OPEN** | `276:285-305` — direct insert by staff or portal → 42501; portal reads it directly → 42501; a `module.suppliers.view` reader reads A's 3 rows, a reader without it 0; UPDATE / DELETE / TRUNCATE → `PORTAL_DOWNLOAD_LOG_APPEND_ONLY`. `:254-256` a refusal writes no row |
| 6 | the change-log exclusion moved to 9 with its reason | **276 EXCL** | `276:307-314` — 0 gaps, `excluded` = 9, `portal_document_downloads` is the ninth with its Q22 reason, it writes no change-log row |
| 7 | the supplier_portal baseline updated by name and the census check's fault cells | **verdict 8** (a gate check, not a fixture) · **276 GRANTS** | `db/check_portal.py:251-296` — ① unreadable baseline raises, ② blinded query reads as blindness, ③ a probe grant is named, ④ a removed baseline line goes red; extra / missing lines red on rebuild and live (`:266-271`); `db/portal-grants-baseline.tsv` 34 lines. `276:400-411` the four functions executable by `supplier_portal` only, storage USAGE only, exactly one storage policy for the role |
| 8 | nothing written by a portal user beyond its own download-log rows | **276 WRITES** · **276 STORE** | `276:388-398` — no change-log row from `supplier_portal`; it can write no relation in `public` or `storage`; it reads only `storage.objects`. `276:274-280` insert / update / delete on `storage.objects` → 42501 |

Fault injection: 33 fixture-276 cells + 3 baselines + 6 verdict-8 cells = 42 / 42 bit on a fresh rebuild after the last database edit
(`docs/surveys/MES-9b/readings/injections-fresh-rebuild.txt`, `INJ_OWN_EXIT=0`).

**Result: nothing is missing in the behaviour.** 7 of 8 items are fully covered by a fixture arm or a gate check. **Item 1 is covered for its database half only**:
the hash re-check and the 409 live in the route handler, which a SQL fixture cannot reach (no JS / HTTP runner); it was proved once, on a local rebuild, by LDP.
That is the `MES9A-APP-HALF-NO-REGRESSION-CHECK` shape, and `docs/known-issues.md` already lists `/portal/documents/file` under it — but that paragraph said the
409 was proved by "MES-9b's one-off **live** proof"; it was the **local-rebuild** proof (the live proof had no committed document to download, ruling 4). Corrected
in this commit. **A gap in the record only, not in the behaviour. Step 2 starts.**

### b · MES-9b's decisions taken without asking (`docs/handbacks/MES-9b.md` §11), titles only

1. Storage by the session's own token, through a policy keyed on the log row.
2. The log row is written before the bytes are fetched.
3. The two-minute window for the storage predicate.
4. One refusal for "another supplier's" and "does not exist".
5. Void certificates are listed but never handed out.
6. Orders listed: not deleted, and issued or approved-and-not-draft.
7. Pending certificates are listed as "Not issued yet".
8. Receipts show code, arrival date, material, quantity and unit, order code and ticket codes.
9. Tickets show code, direction, completion, void state and only the caller's share.
10. Assays not shown.
11. The 19 storage functions in the baseline, mirrored as stubs on the rebuild.
12. Fixture 275's EVERY arm hands the four MES-9b functions to fixture 276 by name.
13. Fixture 274 and live fixture 266 accept the 53rd policy by name and judge.
14. The judge-name fix in verdict 8.
15. `docs/change-log.md` §2's exclusion table gained the missing `scan_events` row as well as the ninth.
16. Sign-in checks reuse MES-9a's script unchanged.
17. The backup script lives in the repo.
18. Chunk width 5,000 `seq`.
19. The two failed dumps' backends were ended with `pg_terminate_backend`.
20. Smoke judged by its own line, and both runs reported as they are.
21. The local download proof drives the route handler, not a browser page.
22. The live proof's real "other supplier" documents are read and refused, never opened.
