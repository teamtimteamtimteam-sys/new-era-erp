# APR-6 — a manual journal and its reversal reach the ledger only when the CFO approves them (2026-09-25)

The approvals effects are `docs/approvals.md` §3s (N5 built; N1 retired for `journal_entries`, so N1 is now retired everywhere); the
matrix line is `docs/role-matrix.md` §3 (general ledger). **No version number is assigned** — the standing ruling is one number for the
whole approval chain, announced at its end.

**Opening gate:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `e8a054f87ce3b5e6e9d0c88d849bfc8b31bc198f` (APR-5b).
**Approvals were ON and stayed ON.** Every figure below is a script's own exit line or a query named with its identity (`postgres`,
`rolbypassrls = t`, base tables unless a view is named; views read as tim@ under `authenticated`).

## §W · APR-5b's broken window — closed with bounds, labelled by kind

Tim confirmed APR-5b deployed (2026-09-25); no Vercel timestamp was relayed.

| | time (CST) | kind |
|---|---|---|
| start | 19:52:50 | **measured**: `db/apply_migration.sh`'s own line (`db/migration-windows.tsv`) |
| end, lower bound | 20:47:45 | **measured**: the push moved `origin/main` → `e8a054f8` (`git reflog show --date=iso refs/remotes/origin/main`) — no deploy can precede it |
| end, upper bound | 20:56:36 | **derived**: this session's first read of the database clock, `now()` as `postgres` (`rolbypassrls = t`), taken after Tim's "deployed" confirmation had arrived — **a relayed confirmation, not a measurement of Vercel** |

**Window: at least 54 min 55 s, at most 1 h 03 min 46 s.** Also written into `docs/handbacks/APR-5.md` §W.

## §0 · Step 0 (grilling) and Tim's answers

**What grilling found** (code from the mirrors; live read as `postgres`, base tables and `pg_proc`):
1. **The line cannot be drawn by `source_type`.** `post_journal_entry` was SECURITY INVOKER with no permission check, executable by
   `authenticated`, and took any `source_type` the caller named; the journal tables' INSERT policies asked only `module.finance.edit`.
   Finance could post a `purchase`, `payment` or `year_close` entry with typed lines. **All 30 functions that call `post_journal_entry`
   are SECURITY DEFINER owned by `postgres`** (live `pg_proc`, `prosecdef`, `has_function_privilege`) — so the line can be drawn by
   privilege: take the core away from people, and no system path notices.
2. **`SOD_POST_AND_CLOSE` would bind the wrong person.** It reads `journal_entries.created_by` on manual entries; once the CFO's
   approval posts the entry, that is the CFO — the CFO (and admin@, the same person) could no longer lock the month, the raiser could,
   and with finance as raiser nobody could. Month-end would stall.
3. **The journal-screen reversal was wider than "manual":** 16 source types still reversible there, some with their own path
   (expense, freight, allocation, year_close), some with none (sale, stocktake, writeoff, prepayment, revaluation, depreciation, …).
4. **JE-APPEND was still open** (appending lines to a posted entry in an open period); dropping the INSERT policies closes it.
5. **A manual line on 1100 or 2000 makes the list-vs-ledger check read unexplained** — the check names only revaluation and on-account
   payments.
6. Live (2026-09-25, `postgres`, base table): 82 journal entries; **one manual** — JE-2026-0079, 2026-09-14, "Testing", 100.00
   (Dr 6200 / 6400, Cr 1300), posted by chooer@, no `source_id`.

**Tim accepted all twelve recommendations (Q1–Q12)** — every one is built as recommended; §1 names where.

## §1 · What shipped

Migration `db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql` (2,012 lines, built by
`db/scripts/build_apr6_migration.py` from the mirrors). **No new permission code**, so "every new code also goes to admin" had nothing
to grant. It proves itself before COMMIT: approvals on; pending set unchanged; `approval_log`, `journal_entries`, `journal_lines` counts
and Σ debits unchanged; `journal_requests` empty; the manual-poster reading unchanged; no write policy on either journal table and both
guards present; `post_journal_entry` and the three internals not executable by `authenticated`; **no INVOKER function calls
`post_journal_entry`** (30 callers, all DEFINER); `reverse_journal_entry` no longer calls the engine; the new chain has a decider; every
pending document still has a decider who is not its own party.

| Q | built |
|---|---|
| Q1 | `post_journal_entry` EXECUTE revoked from `authenticated` (`db/views/zzz_function_grants.sql`); INSERT policies dropped on `journal_entries` / `journal_lines`; statement-level guards `trg_journal_entries_direct_write` / `trg_journal_lines_direct_write` → `JOURNAL_THROUGH_FUNCTION_ONLY` (`guard_journal_direct_write`). A person's only door: `submit_journal_request`, always `'manual'` |
| Q2 | N1 retired for `journal_entries` (`docs/approvals.md` §3c). `journal_requests.amount_base` = Σ debits (base) from the submit-time dry run, then the posted entry's |
| Q3 | `journal_requests` (`entry` / `reversal`): `submitted → approved` (approval posts at once on the frozen date) · `rejected` (reason) · `withdrawn` (raiser's person or `module.finance.edit`). `submit_journal_request` · `submit_journal_reversal_request` · `decide_journal_request` · `withdraw_journal_request`; internals `journal_request_submit_internal` / `_post_internal` / `_dry_run` (PQ005, flushes the deferred balance check) revoked. Posted entry: `source_id` = the request. Approvals off → born approved, `auto_approved` |
| Q4 | Nothing refuses a lock; approval after a lock refuses `PERIOD_LOCKED` and the request keeps waiting; the CFO panel says so (fixture 225 H) |
| Q5 | `sod_manual_posters_in` = `COALESCE(journal_requests.created_by, journal_entries.created_by)` via `result_journal_entry_id`; also counts a system entry reversed through a request. Fixtures 17 · 122 · 127 · 128 · 143 · 172 still green unchanged in that respect (their manual entries have no request, so they read `created_by` as before) |
| Q6 | `journal_entry_reversal_route` (one judgement for the door, the request and the screen). `reverse_journal_entry` reverses nothing: own-path types → `JE_REVERSE_USE_SOURCE_PATH` (adds expense · freight · allocation · processing_cost · year_close), the rest → `JOURNAL_NEEDS_APPROVED_REQUEST`. The reverse button greys by the same function, with a sentence per own-path type |
| Q7 | `JE_MANUAL_CONTROL_ACCOUNT` on 1100 / 2000 (reversal of a `revaluation` entry excepted); bank allowed, `credits_bank` flagged on the CFO panel. PAYREQ1-MANUAL-JOURNAL-CREDITS-BANK closed; inventory accounts registered (APR6-INVENTORY-ACCOUNTS-MANUAL) |
| Q8 | engine: `approval_chain_gates` row (level 2, `module.finance.view` + `data.view_prices`) · `approval_pending_documents` arm (`blocks_disable`, `fixed_level` 2) · `approval_log` type + read branch · `record_approval_decision` branch · `operations_now` / reminder `journal_request_pending` · `assert_other_decider` → `JOURNAL_REQUEST_NO_OTHER_DECIDER` |
| Q9 | doors closed: see §4 |
| Q10 | the window: see §5 |

**One build decision taken on the way, registered for Tim** (`docs/known-issues.md` § APR6-REVERSAL-OF-CONTROL-ACCOUNT-ENTRIES): Q7's
refusal also applies to **reversal** requests — reversing a `sale` (1100) or `prepayment` (2000) entry through the ledger alone moves the
ledger and not the list, the same unexplained difference as a typed 1100 line. The one exception is a `revaluation` reversal, which the
check still names by `source_type`.

**A second, smaller one:** the reversal request refuses a blank reason with its own code (`JOURNAL_REVERSAL_REASON_REQUIRED`) —
`REASON_REQUIRED` in the finance error family already reads "a reopen reason is required".

**★ Both build decisions accepted by Tim (2026-09-25, with the APR-7 brief):** the 1100 / 2000 refusal also applies to reversal
requests — so some system entries (sales, prepayment applications) have no correction path yet, which
`docs/known-issues.md` § APR6-REVERSAL-OF-CONTROL-ACCOUNT-ENTRIES registers — and a blank reversal reason keeps its own code.

**Screens (en / zh):**
- `/finance/journal/new` — submits a request ("Submit for approval"), states that nothing posts until the CFO approves; 1100 / 2000 stay
  in the account list, disabled, labelled "posted only by its own documents"; the submit button is a `PermissionGate` on
  `module.finance.edit` (visible, disabled, with the reason).
- `/finance/journal` — a requests panel at the top: every waiting request with its lines (or the entry it reverses), amount, frozen
  date, "credits a bank account", the locked-period sentence when it applies, Approve / Reject (disabled with the reason without
  `data.view_prices`) and Withdraw; the ten most recently settled below. Anchors `#jr-<id>` for the dashboard reminder.
- `/finance/journal/[id]` — "Request reversal" with a reason; greyed with the right sentence for own-path types or when a reversal
  request is already waiting.
- Bank reconciliation — one line under "New entry": a manual journal goes to the CFO first and has nothing to match until it posts.

**Fixtures:** 225 (new, 14 arms A–N plus its own fault injection) · 122 (the back door refuses at the door, new JE-APPEND arm) · 205
(own-document gaps 8 → 9) · 111 (42 arms) · 132 · 133 · 143 · 172 · 213 call `reverse_journal_entry_internal` (their subject is the
reversal arithmetic, not the door). **Fault injection:** removing the `post_journal_entry` revoke turned fixture 225 red at A3
(`GATE_EXIT=4`), then restored.

## §2 · Verify — every figure is the script's own line

| step | result |
|---|---|
| `db/gate.py --offline` | `GATE_EXIT=0` (52 s) |
| dry run of the migration file on live (`COMMIT` → probe + `ROLLBACK`, grants replayed) | `DRY_OWN_EXIT=0`; probe: `journal_requests` 0, `authenticated` can post = f |
| backup | `BACKUP_EXIT=0` — `evoltrya-backup-2026-09-25-2157.dump`, TOC 6,336 (previous 6,293, floor 5,663), 22:20 |
| `db/apply_migration.sh` | `APPLY_OWN_EXIT=0`; preflight 15 `CREATE FUNCTION` (5 replaced · 10 new); proof NOTICEs: 30 DEFINER posting callers, 1 decider (tim@) |
| `npm run types:gen` (after `NOTIFY pgrst`) | `TYPES_OWN_EXIT=0` (+130 lines) |
| `npx tsc --noEmit` | `TSC_OWN_EXIT=0` |
| `npm run build` | `BUILD_OWN_EXIT=0` |
| `db/gate.py` (full) | `GATE_EXIT=0` (499 s) — rebuild ✓ · mirrors vs live ✓ · fixtures ✓ · anon surface ✓ (baseline 327) |
| `node scripts/check-i18n.mjs` | `I18N_OWN_EXIT=0` |
| `node scripts/check-error-swallowing.mjs` | `SWALLOW_OWN_EXIT=0` |
| smoke (`node scripts/smoke-routes.mjs`, detached, 22:41 → 23:16) | `SMOKE_EXIT=0` — 236 routes + the probes; 229 timed, median 6,549 ms. Clean-up read back as `postgres` (base tables, 23:17): `auth.users` 7, 0 ephemeral; `roles` 13, 0 ephemeral; 7 unrevoked grants; `.ephemeral/` empty. The six stale `ZZ-SMOKE-*` rows it reports (559–1,202 h old) predate this cut and are left as reported |

## §3 · Live proof and the before / after readings

Script `db/scripts/2026-09-25-apr6-live-proof.sql`, one transaction, `ROLLBACK` at the end — **nothing was left on live**
(`PROOF_OWN_EXIT=0`, started 23:18:05, as `postgres` switching to each real account under `authenticated`).

| cell | who | what | result |
|---|---|---|---|
| S0 | postgres | before | JE 82 · 1000 −127,593.48 · 6200 60.00 · 1300 −100.00 · 2000 −376,404.42 · 1100 43,002.12 |
| A1 / A2 | chooer@ | `post_journal_entry` as a forged `purchase` (1200/2000) · as a `manual` crediting 1000 | `permission denied for function post_journal_entry` · the same |
| A3 / A4 | chooer@ | direct INSERT into `journal_entries` · append a line to JE-2026-0079 (JE-APPEND, open period) | `JOURNAL_THROUGH_FUNCTION_ONLY` · `JOURNAL_THROUGH_FUNCTION_ONLY` |
| A5 / A6 / A7 | chooer@ | `reverse_journal_entry` on JE-2026-0079 · on an expense entry · on a payment entry | `JOURNAL_NEEDS_APPROVED_REQUEST\|JE-2026-0079` · `JE_REVERSE_USE_SOURCE_PATH\|JE-2026-0008\|expense` · `…\|JE-2026-0005\|payment` |
| B1 / B2 | chooer@ · postgres | raise a bank fee (Dr 6200 / Cr 1000, 12.34) | `manual journal #1`, submitted, 12.34, `credits_bank` true, JE unchanged (82) · pending arm `blocks_disable`, `fixed_level` 2, subject NULL, deciders: tim@ |
| B3–B7 | chooer@ · fusheng@ · admin@ · chooer@ · chooer@ | touching 2000 · no finance.edit · CFO's other account · dated 2026-07-31 · unbalanced | `JE_MANUAL_CONTROL_ACCOUNT\|manual journal #2\|2000` · `PERMISSION_DENIED\|module.finance.edit` · `JOURNAL_REQUEST_NO_OTHER_DECIDER\|manual journal #2` · `PERIOD_LOCKED\|2026-07-31\|2026-08-01` · `JOURNAL_UNBALANCED\|…\|5.00\|4.00`; no row left by any of them |
| C1 / C2 / C3 | chooer@ · sandra@ · fusheng@ | decide | `SELF_APPROVAL_FORBIDDEN\|raiser` · `APPROVAL_NOT_AUTHORISED\|2\|cfo` · `PERMISSION_DENIED\|module.finance.view` |
| D1 / D2 / D3 | tim@ · postgres | approve | JE-2026-0080 posted: `manual`, `source_id` = the request, dated 2026-09-25, `created_by` tim@; 1000 −127,593.48 → −127,605.82, 6200 60.00 → 72.34 · log submitted + approved, level 2, tim@, `self_decided` false · `sod_manual_posters_in(today)` counts chooer@, not tim@ |
| E1 / E2 / E3 | chooer@ · chooer@ · tim@ | request a reversal of JE-2026-0080 · a second one · approve | submitted, entry still posted · `JOURNAL_REQUEST_OPEN\|JE-2026-0080\|JE-2026-0080 · reversal #1` · JE-2026-0081 posted, original reversed, 1000 and 6200 back to −127,593.48 / 60.00 |
| F | tim@ | reject without / with a reason | `JOURNAL_REQUEST_REJECT_REASON_REQUIRED\|manual journal #2` · rejected, nothing posted |
| G | fusheng@ · chooer@ | withdraw | `PERMISSION_DENIED\|module.finance.edit` · withdrawn |
| I1 | postgres | end | 0 journal requests waiting; pending documents: 1 expense claim (unchanged) |
| L | tim@ (views) | list vs ledger before / after the lifecycle | AP 416,988.32 / 376,404.42 · AR 57,545.87 / 43,002.12 — **unexplained 0.00 both sides, both times** |

**Not proven on live, on purpose:** the lock-while-waiting cell. A lock on live goes only through `close_period` (month-end, depreciation,
allocation all due) or the CFO's settings door — no honest month-end can be staged in a rolled-back transaction. Fixture 225 H pins it on
the rebuild: the raiser cannot lock (`SOD_POST_AND_CLOSE`), the approving CFO can while a request waits, and approval afterwards is
refused `PERIOD_LOCKED` with the request still waiting.

**Before and after readings** — `db/scripts/2026-09-25-apr6-readings.sql`, before at 21:56:44, after at 23:18:52 (part 1 as `postgres`,
base tables; part 2 as tim@ on views; part 3 each account as itself). The two outputs were diffed:
- **identical:** approvals on (L1 finance, L2 cfo, threshold 1000, locked before 2026-08-01); pending — 1 expense claim (1,000.00),
  2 leave, 1 medical approved-unpaid, 5 open stocktakes, 0 PO / payment / payroll / receipt-price / invoice requests, 0 shipping
  releases; `approval_pending_documents()` = 1 expense claim; journal entries 82 (by source type unchanged; manual 1 — JE-2026-0079,
  chooer@), journal lines 184, Σ debits 1,636,102.89; approval_log 14; `sod_manual_posters_in` all-time = chooer@; balances 1000
  −127,593.48 · 1010 −37,340.89 · 1100 43,002.12 · 1300 −100.00 · 2000 −376,404.42 · 6200 60.00 · 6400 140.00; AP list 416,988.32 /
  ledger 376,404.42, AR list 57,545.87 / ledger 43,002.12, **unexplained 0.00 both sides**; catalogue 66; every role's code count and
  md5 (admin 65 `485022c5…` · auditor 20 · cco 38 · cfo 30 `730763e8…` · cto 32 · finance 38 `49745fb9…` · gm 21 · hr 7 ·
  operations 15 · procurement 16 · sales 17 · warehouse 24) and every account's `current_user_permissions()`; 7 unrevoked grants.
- **changed, as intended:** `journal_requests` exists (0 rows, 0 waiting; before: absent); the two INSERT policies on
  `journal_entries` / `journal_lines` are gone; `trg_journal_entries_direct_write` and `trg_journal_lines_direct_write` present;
  `authenticated` can execute `post_journal_entry`: t → **f**.
- **Nothing left pending by this cut; every pending document still has a decider who is not its own party** (the migration's own proof
  printed each — CLM-2026-0004 → tim@; leave → admin@, tim@; MC-2026-0001 → admin@, chooer@; stocktakes → chooer@; journal_request
  deciders: 1).

## §4 · Doors closed, and who can no longer do what (approvals on)

**Closed:** a forged `purchase` (or any labelled) entry through `post_journal_entry` (ROLE1B4A-PURCHASE-JOURNAL-FORGEABLE) · a manual
journal crediting a bank without approval (PAYREQ1-MANUAL-JOURNAL-CREDITS-BANK) · direct inserts with a self-chosen code,
`created_by`, status or `source_type` · JE-APPEND · reversing a manual entry, or a system entry with no path of its own, without approval
· reversing expense / freight / allocation / processing_cost / year_close entries from the journal screen (they go to their own paths).
No other door was registered as waiting for APR-6 (`docs/known-issues.md`, `docs/approvals.md` searched for "APR-6").

- **Choo Er (finance):** can no longer post a manual journal or reverse any entry in one step — both are requests the CFO approves;
  can no longer post any other `source_type` or write the journal tables directly; cannot use 1100 / 2000 in a manual journal.
  Still records expenses, payments, invoices and every document that posts its own entry, unchanged (N5).
- **admin@:** the same as finance; a request raised from admin@ is refused at submit (`JOURNAL_REQUEST_NO_OTHER_DECIDER` — same person
  as tim@, level 2's only real holder); cannot decide.
- **tim@ (cfo):** newly decides every manual journal and every reversal, on the journal list. Raises nothing (no `module.finance.edit`).
  Approving does **not** make tim@ a "manual poster" for `SOD_POST_AND_CLOSE`.
- **Everyone else:** unchanged — no other role holds `module.finance.edit`.
- **No document is left with only its raiser eligible:** finance's requests → tim@.

## §5 · The broken window — started, end PENDING

**Start: 2026-09-25 22:23:51 CST** (`db/apply_migration.sh`'s own line, also in `db/migration-windows.tsv`; its "applied at" line reads
22:21:37). ~~**End: PENDING — Tim reads it from Vercel.**~~ **Closed with bounds (APR-7, 2026-09-26)** — Tim confirmed APR-6 pushed and
deployed (2026-09-25); no Vercel timestamp was relayed:

| | time (CST) | kind |
|---|---|---|
| start | 22:23:51 | **measured**: `db/migration-windows.tsv` |
| end, lower bound | 23:25:10 | **measured**: the push moved `origin/main` → `272b6345` (`git reflog show --date=iso refs/remotes/origin/main`) — no deploy can precede it |
| end, upper bound | 23:31:13 | **derived**: APR-7's first read of the database clock, `now()` as `postgres` (`rolbypassrls = t`), taken after Tim's "deployed" confirmation had arrived — **a relayed confirmation, not a measurement of Vercel** |

**Window: at least 1 h 01 min 19 s, at most 1 h 07 min 22 s.**

What the old app does against the new database (approvals ON):
- **Posting a manual journal is refused for everyone.** The old "Post Entry" form calls `post_journal_entry`, which `authenticated`
  can no longer execute → `permission denied for function post_journal_entry`, shown by the old copy as the generic unexpected-error
  text. There is no screen to raise a journal request until the deploy.
- **Reversing from the journal page is refused for everyone.** The old button calls `reverse_journal_entry` →
  `JOURNAL_NEEDS_APPROVED_REQUEST|<code>` (manual and no-own-path entries, shown as the generic text with the code) or
  `JE_REVERSE_USE_SOURCE_PATH` (own-path entries — the old sentence, which does not yet mention expenses, freight, allocation,
  processing costs or year-end close).
- **Bank reconciliation:** a bank fee or interest cannot be posted as a manual journal until the deploy (then it goes to the CFO).
- **Unaffected:** month-end (revaluation, depreciation, close, year-end), every document that posts its own entry (expenses, payments,
  invoices, receipts, payroll, processing, stocktakes, shipping), every other approval chain, the switch, everything pending, and every
  other screen. **Live impact:** JE-2026-0079 is the only manual entry on live and nothing is waiting.

## §6 · Commit, push, three SHAs

Reported in the hand-back message: `HEAD`, `origin/main` and `git ls-remote origin main` as full 40-character SHAs (a commit cannot
carry its own hash). Deployment is Tim's to read; the window's end stays PENDING until he does.
**Next cut:** the write-off, processing-rollback and COD-void requests (`docs/forward-queue.md` item 12, provisionally APR-7 — the name
is Tim's).
