# NOROLE-SURFACE close-out (2026-10-19)

Brief: "NOROLE-SURFACE close-out + MES-9a build", step 1. Docs only — no code edit, no database change, no live write. Live reads: none were needed
(every reading below is from git or from the repository).

**Opening check (16:48:51 CST, this session's first command).** Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
`c61acce68242e29d8a8737f5977839693bd26228`. No git command refused.

## 1 · Broken window (1.1)

| | Time (CST) | Source |
|---|---|---|
| start | **2026-10-19 14:46:11** | measured: `db/migration-windows.tsv` (`2026-10-19-norole-surface.sql`, last line) |
| end, lower bound | **2026-10-19 16:36:39** | measured: `git reflog show --date=iso refs/remotes/origin/main` → `c61acce6 refs/remotes/origin/main@{2026-10-19 16:36:39 +0800}: update by push`; the push `ae4bde43..c61acce6` carried only the cut's own commit `c61acce6` (committed 2026-10-19 16:35:00, `git log ae4bde43..c61acce6`) |
| end, upper bound | **2026-10-19 16:48:51** | derived: this session's first command (`date`), with Tim's "deployed" already in hand — a report of what Tim saw, not a reading of Vercel |

**Broken window: at least 1 h 50 min 28 s, at most 2 h 02 min 40 s.**

What was broken inside it (derived — NOROLE-SURFACE hand-back §0, not measured on live here): nothing in use. The cut shipped no app code, so the deployed
app inside the window and after the push is the same code; the hand-back's 182 page readings (§4.1) were taken against the already-deployed app over the new
database and match the pre-migration readings cell for cell.

## 2 · Tim's ruling recorded (1.2)

`NOROLE-PO-ORPHAN-FILE` (`po-documents/4112390a-…/ba8da58e-….pdf`, no `po_issues` row points at it): **left for Tim to delete when convenient; no cut deletes
it** — including any live proof's cleanup plan (it is not a session's own object). Written into `docs/known-issues.md` (that entry) and `docs/forward-queue.md`
(the NOROLE-SURFACE item).

## 3 · Read-only verification (1.3)

### a · The NOROLE-SURFACE brief's fixture list, item by item

The list is the brief's "Fixtures must cover every item restated in section 1, including:" sentence (the brief lives only in the NOROLE-SURFACE session
transcript; quoted in item order). Paths: `db/fixtures/274-a-session-with-no-role-reads-no-permission-table-price-ledger-or-stored-file.sql` (274),
`db/live-fixtures/266-a-signed-in-session-without-a-role-sees-no-stored-file-and-every-bucket-judges-by-code.sql` (L266), `db/check_norole.py` (verdict 7).

| # | Item | Covered by | Evidence |
|---|---|---|---|
| 1 | each of the 9 relations refused for a no-role and a display-only session and readable by each code the predicate names | **274 REL** | `274:147-170` — for each object: norole, display (`floor_display` only) and an unrelated code read 0 (own `user_roles` row excluded); each code in the predicate alone reads every row (`v_total`, re-read after its own grant); a vacuous object (0 rows) raises |
| 2 | a session's own `user_roles` rows and own codes still readable | **274 OWN** | `274:172-183` — own row 1; `role_permissions` 0 (the arm is not vacuous); `current_user_permissions()` 2 codes and `has_permission` answers; no-role 0 codes |
| 3 | trail account labels still shown | **274 TRAIL ①** (+ ② ③ for Tim's build Q21) | `274:186-204` — an employee that reads 0 rows of `accounts` sees its claim's account name in `record_trail`; `:205-229` change-log and employee-page readers see the role grant unrestricted |
| 4 | `collection_promise_status` refused without `module.finance.view` | **274 PROMISE** (+ REL) | `274:231-237` — customers + sales viewer 0; finance viewer 1 (its own promise) |
| 5 | each bucket's read, upload and delete by its code and refused without it | **274 BUCKET · DELETE** · live half **L266 NOROLE** | `274:239-276` — 14 buckets × (norole, display, unrelated code: 0 read, upload refused) × (each read code: reads, does not upload, does not delete) × (each upload code: uploads, deletes an orphan where the bucket is a delete-orphan bucket, deletes nothing elsewhere); L266 `:30-37` — on live a no-role JWT sees 0 objects and 0 buckets |
| 6 | update refused on the 4 attachment buckets | **274 NOUPDATE** · **L266 NOUPDATE** | `274:265-267` — even the upload code updates 0 rows; L266 `:45-47` — on live only `own avatar update` / `finance settings update company-assets` remain |
| 7 | delete refused for a file a record points at and allowed for an orphan | **274 DELETE** · **L266 DELETE** | `274:268-288` — orphan deleted by the upload code; a `customer_attachments`-recorded file not deleted; each delete policy names its record table and column; L266 `:48-59` — live delete policies exactly the 12, each with the unrecorded check |
| 8 | company-assets readable by each PDF route's code | **274 BUCKET** | `274:114-116` + `:248-251` — the 8 read codes, each alone reads the bucket's file |
| 9 | verdict 7's fault cells and its zero-is-blind rule | **verdict 7 self-tests** (a gate check, not a fixture) | `db/check_norole.py:36-42` (the six cells), `:267-309` — ② unreadable baseline raises, ④ removed baseline line goes red, ③ blinded query (universe 0) reads as blindness, ① probe table named, ⑤ coverage floors `:230-236`; ⑥ `GATE_NOROLE_FAULT=policy` is run by `db/gate.py`. ①–⑤ run on every invocation |
| 10 | the storage mirror matching live | **verdict 7 storage comparison** (a gate check) · rebuild count **274 SHAPE** · live count **L266 JUDGE** | `db/check_norole.py:313-322` — every bucket and policy on live = `db/storage/buckets-and-policies.sql` installed on the rebuild, compared key by key; `274:290-298` 52 policies, all judged; L266 `:39-44` 52 on live |

**Result: all 10 items are covered.** Items 1–8 by a fixture arm (rebuild, with the live half of 5–7 in L266); items 9 and 10 by verdict 7, which is a gate
check rather than a fixture — the hand-back lists them under its fixture and verdict sections but never maps the brief's list item by item. **That is a gap in
the record only, not in the behaviour**, and it is closed by this table. **Nothing missing — step 2 starts.**

### b · NOROLE-SURFACE's decisions (`docs/handbacks/NOROLE-SURFACE.md` §8)

Asked during the build (answered by Tim): **Q21** — the audit trails are readers of the permission tables; their codes added to the four predicates.

Taken without asking:
- (a) Storage on the rebuild through a stub.
- (b) Storage policy names follow the newer buckets' style.
- (c) `collection_promise_status` grants not re-stated.
- (d) Verdict 7 runs a rolled-back transaction on live that inserts one `user_roles` row.
- (e) The per-role readings use throwaway role copies inside a rolled-back transaction on live.
- (f) Live fixture 266 is read-only and creates no identity.
- (g) The pages were read against the deployed app.
- (h) Orphan cleanup exercised with files of my own, not records of my own.
- (i) `scripts/ephemeral.mjs` gained the `noroleprobe` prefix.
- (j) Two process slips, recorded so they are not mistaken for results.
