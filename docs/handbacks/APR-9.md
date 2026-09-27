# APR-9 — a salary change and a fixed-asset disposal take effect only after approval (2026-09-27)

Tim's matrix (`docs/role-matrix.md` §4 disposal · §5 salary changes): finance raises both, the CFO approves; nothing takes effect
before approval. One cut — the stopping line (ship salary + the review doors as 9a, disposal as 9b, if the offline gate was not green
with the salary half finished) did **not** trigger. No version number assigned (standing ruling).

Identities throughout: live reads as `postgres` (`rolbypassrls = t`), base tables unless a view is named; views read as tim@
(`634c00f9…`, cfo) under `authenticated`; role holders counted from unrevoked grants only.

## §W · APR-8's broken window — closed with bounds, labelled by kind

Tim confirmed APR-8 deployed (2026-09-26) and has no Vercel "Ready" time to add.

| | time (CST) | kind |
|---|---|---|
| start | 2026-09-26 23:31:04 | **measured**: `db/migration-windows.tsv` |
| end, lower bound | 2026-09-27 00:31:29 | **measured**: the push moved `origin/main` → `2722435a` (`git reflog show --date=iso refs/remotes/origin/main`) |
| end, upper bound | 2026-09-27 07:32:13 | **derived**: this session's first read of `now()` as `postgres`, after Tim's "deployed" confirmation — **a relayed confirmation, not a measurement of Vercel** |

**Window: at least 1 h 0 min 25 s, at most 8 h 1 min 9 s.** Also written into `docs/handbacks/APR-8.md` §6.
**Accepted by Tim (2026-09-27):** APR-8's two build decisions — the "Treatment charge (USD/t)" label baselined in the currency check,
and the removed or rewritten copy that was no longer true.

## §0 · Step 0 (grilling) and Tim's answers

**The finding that shaped the cut (measured at Step 0, `db/scripts` not needed — a one-off rolled-back probe):** as sandra@ (cco,
EMP-2026-0004) under `authenticated`, a direct `INSERT INTO performance_reviews` with `status = 'submitted'`, `submitted_by` = tim@ and
`new_monthly_salary = 9999` for Fu Sheng, then `approve_review` as sandra@ → **approved; `employees.monthly_salary` = 9999 and a
`salary_change` history row**, no CFO. `performance_reviews` had no column guard (`has_column_privilege` true for `status`,
`submitted_by`, `new_monthly_salary`, …) and both routing and four-eyes trusted `submitted_by`. It also set a *first* salary.

Other Step 0 readings: all 6 active employees' salaries NULL; 0 reviews; payroll never reads `monthly_salary` (lines come from the
provider; the grid pre-fills from last period); FA-2026-0001 active, cost 400,000.00, not in service, 0 depreciation; FA-2026-0002
cost 0; 0 disposals ever; 1500 = 400,000.00, 1510 = 0, 7200 = 0.

**Tim accepted all ten recommendations (Q1–Q10), 2026-09-27:**

| Q | ruling | where it landed |
|---|---|---|
| Q1 | close the review side door in this cut | `guard_performance_review_write` + `trg_performance_reviews_guard_write` |
| Q2 | salary chain out of `approval_chain_gates`, in `approval_pending_documents`; one routing definition `review_approval_code` delegates to; other-decider check at submit from the same definition; no new code | `pay_decision_code`, `salary_change_deciders` |
| Q3 | salary chain ignores the switch: always waits, never blocks switching off, never born approved | `blocks_disable = false`; no `approvals_enabled()` read |
| Q4 | finance raises (`module.hr.edit` + `data.view_pay`); nobody raises their own (by person) | `SALARY_CHANGE_OWN_REFUSED` |
| Q5 | effective date required, checked at submit and approval vs posted periods and periods with an open payroll request; salary written at approval, history carries the date; reviews refuse to change a NULL salary | `salary_effective_period_block`; `SALARY_NOT_SET_USE_INITIAL` in `approve_review` / `submit_review` |
| Q6 | one open salary change per employee across both paths; fingerprint = salary + status | `salary_change_open`, `salary_change_fingerprint`, `SALARY_CHANGED_SINCE_REQUEST` |
| Q7 | disposal dated and valued on the approval day; proceeds + bank frozen at submit; estimate beside the posted figures; catch-up rule unchanged | `asset_disposal_execute_internal` (CURRENT_DATE), `estimate` / `result` |
| Q8 | freeze cost changes, cost-entry reversals, commissioning; depreciation, maintenance, planning open; fingerprint at approval | `guard_asset_disposal_freeze`, `asset_disposal_fingerprint` |
| Q9 | `asset_disposal` → source path; register "no disposal reversal yet" | `journal_entry_reversal_route`; `APR9-NO-DISPOSAL-REVERSAL-YET` |
| Q10 | disposal follows APR-7; the live proof as listed | §3 |

## §1 · What shipped

**Migration** `db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql` (built from mirrors by
`db/scripts/build_apr9_migration.py`, 3,081 lines). Its self-proof, in the same transaction: approvals on; grants unchanged; pending
set unchanged; approval_log / journal / assets / depreciation / salaries (count + digest) / history / reviews unchanged; both request
tables empty and without write policies; two guards; ten internals not executable by `authenticated`; disposal chain row level 2
only; **salary not in the chain registry**; `review_approval_code` ≡ `pay_decision_code` on every account × employee pair; the
disposal chain has a decider; every live raiser × employee salary route printed; every pending document has a decider who is not its
own party.

**New tables (2):** `salary_change_requests` · `asset_disposal_requests` (RLS read only; no write policy; anon revoked).
**New functions (21):** `pay_decision_code` · `salary_effective_period_block` · `salary_change_fingerprint` · `salary_change_open` ·
`salary_change_deciders` · `salary_change_execute_internal` · `submit_/decide_/withdraw_salary_change_request` ·
`salary_change_requests_visible` · `guard_performance_review_write` · `asset_disposal_fingerprint` · `dispose_fixed_asset_internal` ·
`asset_disposal_execute_internal` · `asset_disposal_dry_run` (PQ007) · `submit_/decide_/withdraw_asset_disposal_request` ·
`asset_disposal_requests_visible` · `guard_asset_disposal_freeze`.
**Replaced (8):** `review_approval_code` (delegates) · `submit_review` · `approve_review` · `dispose_fixed_asset` (refusal only) ·
`journal_entry_reversal_route` · `record_approval_decision` · `approval_pending_documents` · `approval_chain_gates`.
**Also:** `approval_log` subject-type CHECK + read policy (two branches); `operations_now` two arms; two triggers.

**Screens:** employee page — a salary-change block (raise: new salary, payroll month, reason; the waiting request with old → new,
month, who decides — CFO or cco, from the database; Approve / Reject / Withdraw, visible-but-disabled with the named code, or with
the rule when the reader is the raiser or the subject; recent history). Review page — the HR decision is read-only once submitted and
says why. Fixed assets — the dispose form is now a request (proceeds, bank, reason; **no date box**); a requests panel at the top
(`#adr-<id>`) with the submit-time estimate, a changed-since warning, Approve / Reject / Withdraw, and decided ones showing estimate
beside what posted with a link to the entry; the dispose button is disabled with a pointer while one waits (list and detail page).
`disposeAsset` in `app/finance/month-end/actions.ts` deleted. Dashboard: `asset_disposal_pending`, `salary_change_pending`.
en + zh copy for all of it, plus the source-path sentence for `asset_disposal` entries and the stale "(once it exists) a salary-change
request" copy rewritten (three places).

**Fixtures:** new `228` (A–L: registration · the review side door · salary lifecycle · refusals · CFO-party routing to cco ·
fingerprint and withdraw · ignores the switch · disposal lifecycle · disposal refusals · approvals off · two fault injections, each
proven load-bearing). Changed: `111` (46 arms) · `205` (level-2 chains 11 → 12) · `16` · `107` · `108` · `201` (call
`dispose_fixed_asset_internal` — they pin disposal arithmetic, not the door). Tooling: `check_mirrors.py` allowlist (10 internals),
`check-i18n.mjs` manifest (6 prefixes), `check-document-registry.mjs` 236 → 238.

**Build decisions taken without asking — say if any is wrong:**
1. **The review guard makes the lifecycle columns function-only at every status**, not only after submission: a direct
   `draft → submitted` write with a chosen `submitted_by` *is* the Step 0 forgery. **`employee_id` is added to the frozen-after-submit
   set** (not in Q1's wording): moving a submitted, salary-carrying review to another person moves the raise.
2. **`approve_review`'s effective-date predicate is unchanged** (posted periods only), as is `set_initial_salary`'s; the stricter
   predicate (posted *or* open payroll request) applies to salary-change requests, per Q5's wording. One more question for Tim if he
   wants reviews aligned.
3. **The effective date is chosen as a payroll month** (the 1st), like the first-salary form — `check-date-format` forbids new native
   date inputs, and payroll and the period check are monthly.
4. **The history row's `created_by` is the raiser** (APR-7 Q6 shape); the approver is on the request and in `approval_log`.
5. **Salary requests' `approval_log` rows carry no amount** (PDPA; the `performance_review` shape). Disposal rows carry the amount.
6. **The salary fingerprint also carries anonymised / deleted**, so an anonymisation while waiting refuses by name.
7. **The disposal freeze also stops owner-path writes** (it is not an RLS guard — every writer of `fixed_assets` is an owner path).
8. **`salary_change_pending`'s `item_id` is the employee**, gate `data.view_pay` — the request lives on the employee page.

## §2 · Verify — every figure is the script's own line

| step | result |
|---|---|
| `db/gate.py --offline` | first `GATE_EXIT=4` (54 s): 111 / 203E / 205 — 203E was my own comment naming the level-based approver function inside `approval_chain_gates`' body (prosrc counts comments; PAY-REQ-1's recorded lesson); fixed, 111 and 205 counts moved → **`GATE_EXIT=0`**, 231 fixtures ✓ |
| dry run of the migration file on live (`COMMIT` → probe + `ROLLBACK`) | `DRY_OWN_EXIT=0`, twice (before and after the fixture edits; the rebuilt file byte-identical) |
| backup | `BACKUP_EXIT=0` — `evoltrya-backup-2026-09-27-0957.dump` (5.0 MB), 10:16. ⚠ The first launch was a background call without `nohup … & disown`, so it would have died at the 10-minute harness cap; I stopped it before it wrote anything, deleted its quarantined `.INCOMPLETE` file (0 bytes, never renamed) and relaunched correctly. |
| `db/apply_migration.sh` | `APPLY_OWN_EXIT=0`; pre-flight 29 CREATE FUNCTION (8 replaced · 21 new); proof NOTICEs: 1 decider for `asset_disposal_request`; 9 pending documents each with a decider; salary routes (see §4) |
| `npm run types:gen` | `TYPES_OWN_EXIT=0` (+402 lines) |
| `npx tsc --noEmit` | first `TSC_OWN_EXIT=2` (the asset detail page also renders `AssetActions`; a bank-account arg typed non-null) → fixed without a cast → **`TSC_OWN_EXIT=0`** |
| `npm run build` | `BUILD_OWN_EXIT=0` |
| `db/gate.py` (full) | `GATE_EXIT=0` (296 s) — rebuild ✓ · mirrors vs live ✓ · fixtures ✓ (231) · anon surface ✓ (baseline 327) · types ✓ |
| `node scripts/check-i18n.mjs` | `I18N_OWN_EXIT=0` |
| `node scripts/check-error-swallowing.mjs` | `SWALLOW_OWN_EXIT=0` |
| smoke (`node scripts/smoke-routes.mjs`, detached) | `SMOKE_EXIT=0` — 236 routes + probes; 229 timed, median 4,940 ms. Clean-up read back as `postgres` (base tables, 2026-09-27 11:01): `.ephemeral/` 0 plans; `auth.users` 7, `roles` 13, unrevoked `user_roles` 7 — the real accounts only; both request tables 0 rows |

## §3 · Live proof and the before / after readings

Script `db/scripts/2026-09-27-apr9-live-proof.sql`, one transaction, `ROLLBACK` at the end — **nothing was left on live**
(`PROOF_OWN_EXIT=0`, 2026-09-27 ~11:02 CST, as `postgres` switching to each real account under `authenticated`; read-backs as
`postgres`). After the rollback: 0 salary requests, 0 disposal requests, 0 salaries set, FA-2026-0001 `active`, 82 journal entries.

| cell | who | what | result |
|---|---|---|---|
| S1 | chooer@ | first salaries (ROLE-1 door, unchanged) | Fu Sheng 5,000 · Tim 8,000 · Sandra 6,000 from 2026-10 |
| S2 | chooer@ | request effective 2026-07-15 | `SALARY_EFFECTIVE_IN_POSTED_PERIOD\|PAY-2026-0001` |
| S3 | chooer@ | Fu Sheng 5,000 → 5,500 from 2026-11 | submitted, `decided_via` action.approve_review; salary still 5,000; pending row `blocks_disable` f, level NULL |
| S4 | chooer@ · sandra@ | decide it | both `PERMISSION_DENIED\|action.approve_review` |
| S5 | tim@ | approve | salary 5,500; history 2026-11-01 5,000 → 5,500; log `submitted/- approved/-` |
| S6 | chooer@ → sandra@ | Tim's own raise 8,000 → 8,800 | `decided_via` action.hr_reviews; tim@ `PERMISSION_DENIED\|action.hr_reviews`; sandra@ approves |
| S7 | admin@ | raise for Sandra | `SALARY_CHANGE_NO_OTHER_DECIDER\|EMP-2026-0004 · salary change #1` |
| S8 | sandra@ | **the Step 0 side door** (direct submitted review, `submitted_by` = tim@) | `REVIEW_DIRECT_INSERT_DRAFT_ONLY` |
| S9 | chooer@ | direct `UPDATE employees SET monthly_salary` | `SALARY_DIRECT_WRITE_REFUSED` |
| D1 | chooer@ | old door `dispose_fixed_asset` | `ASSET_DISPOSAL_NEEDS_REQUEST\|FA-2026-0001` |
| D2 | chooer@ | dispose FA-2026-0001, proceeds 50,000 into 1000 | submitted; estimate dated 2026-09-27, cost 400,000, accum 0, loss 350,000; asset still active; no entry; pending row 400,000.00, `blocks_disable` t, level 2 |
| D3 | postgres | switch approvals off while it waits | `APPROVALS_CANNOT_DISABLE_WITH_PENDING\|1\|FA-2026-0001 · disposal #1` |
| D4 | chooer@ | approve own | `SELF_APPROVAL_FORBIDDEN\|raiser` |
| D5 | tim@ | approve | disposed 2026-09-27; JE-2026-0080: 1000 Dr 50,000 · 7200 Dr 350,000 · 1500 Cr 400,000; log `submitted/2/400000 approved/2/400000`; reversal route `source_path` |
| D6 | chooer@ | dispose FA-2026-0002 | `ASSET_HAS_NO_COST\|FA-2026-0002` (dry run at submit), no row |
| D7 | admin@ | dispose FA-2026-0002 | `ASSET_DISPOSAL_NO_OTHER_DECIDER\|FA-2026-0002 · disposal #1`, no row |

**Before and after readings** — `db/scripts/2026-09-27-apr9-readings.sql` (part 1 as `postgres`, base tables, `relkind` self-proved;
part 2 as tim@ on views; part 3 each account as itself), before at 09:55:54, after at 11:03:11 (after the proof and the smoke). Diffed:
- **identical:** approvals on (L1 finance, L2 cfo, threshold 1000, locked before 2026-08-01); pending — `approval_pending_documents()`
  = 1 expense claim (CLM-2026-0004, 1,000.00, `blocks_disable` 0); employees 7 live, **0 salaries set** (digest of the empty set),
  history 3 rows (0 salary changes), reviews 0; payroll PAY-2026-0001 posted, 0 open payroll requests; FA-2026-0001 active 400,000.00
  accum 0, FA-2026-0002 active 0; depreciation rows 0, anchors 0, disposal entries 0; approval_log 14; journal entries 82, lines 184,
  Σ debits 1,636,102.89; balances 1000 −127,593.48 · 1100 43,002.12 · 1200 61,387.92 · **1500 400,000.00 · 1510 0.00 · 7200 0.00** ·
  2000 −376,404.42; **list-vs-ledger (as tim@): AP list 416,988.32 / ledger 376,404.42, AR list 57,545.87 / ledger 43,002.12,
  unexplained 0.00 on both sides**; catalogue 66; holders of the eight relevant codes; every role's code count and md5 (admin 65
  `485022c5…` · cco 38 `59932566…` · cfo 30 `730763e8…` · finance 38 `49745fb9…` · the rest unchanged); every account's
  `current_user_permissions()`; 7 unrevoked grants.
- **changed, as intended:** both request tables exist (0 rows, 0 waiting; before: absent); APR-9 guards 0 → **2**; `authenticated` can
  execute the six doors (**t**) and not `dispose_fixed_asset_internal` / the two execute internals / `pay_decision_code` (**f**; before:
  absent).
- **Nothing left pending by this cut; every pending document still has a decider who is not its own party** (the migration printed
  each: CLM-2026-0004 → tim@; LV-2026-0001 / 0003 → admin@, tim@; MC-2026-0001 → admin@, chooer@; ST-2026-0082…0086 → chooer@).

## §4 · Doors closed, and who can no longer / can newly do what (approvals on)

**Closed:** a review created other than as a draft; any direct change to a review's status, submitter, approval, acknowledgement or
void columns; changing a submitted review's salary, effective date, probation outcome or subject; a review setting a first salary;
disposing of an asset in one step; changing an asset's value columns (adding cost, reversing a cost entry, commissioning) while its
disposal waits; reversing an `asset_disposal` entry from the journal. **Re-asserted:** direct salary writes (`SALARY_DIRECT_WRITE_REFUSED`).

- **Choo Er (finance):** can no longer dispose of an asset in one step. **Newly:** raises salary changes (not her own) and disposal
  requests; withdraws them.
- **Sandra (cco):** can no longer forge a submitted review or edit a submitted one's salary — the path that let her change another
  person's salary without the CFO. **Newly:** decides salary changes where Tim is the raiser or the subject (except her own).
- **Tim as tim@ (cfo):** **newly** approves or rejects every disposal and every salary change where he is not a party.
- **Tim as admin@:** can no longer dispose in one step or write review lifecycle columns directly. A disposal raised as admin@ is
  refused at submit (`ASSET_DISPOSAL_NO_OTHER_DECIDER`); a salary change raised as admin@ routes to cco, and is refused only for
  Sandra's own (`SALARY_CHANGE_NO_OTHER_DECIDER`).
- **Phua · Fu Sheng · Vince:** no change.
- **No request is left with only its raiser eligible:** salary routes printed by the migration — chooer@ → any employee except
  herself: tim@/admin@ (CFO), or sandra@ for Tim; admin@ → anyone but Sandra: sandra@; admin@ → Sandra: nobody → refused at submit.
  Disposal: tim@.

## §5 · Findings registered on the way

- **Closed:** `APR4-DISPOSAL-REVERSAL-LEAVES-ASSET-DISPOSED` (struck, not deleted).
- **Registered:** `APR9-NO-DISPOSAL-REVERSAL-YET` (Tim's Q9).
- **Open question (not a defect):** reviews still use the posted-period-only date check (build decision 2).

## §6 · The broken window — started, end PENDING

**Start: 2026-09-27 10:20:23 CST** (`db/apply_migration.sh`'s own line, also in `db/migration-windows.tsv`; its "applied at" line
reads 10:17:43). **End: PENDING — Tim reads it from Vercel.**

**Closed (APR-10, 2026-09-27) — Tim confirmed APR-9 deployed; bounds labelled by kind:**

| | time (CST) | kind |
|---|---|---|
| start | 2026-09-27 10:20:23 | **measured**: `db/migration-windows.tsv` |
| end, lower bound | 2026-09-27 11:05:58 | **measured**: the push moved `origin/main` → `aaed80f8` (`git reflog show --date=iso refs/remotes/origin/main`) |
| end, upper bound | 2026-09-27 11:15:59 | **derived**: APR-10's first read of `now()` as `postgres`, after Tim's "deployed" confirmation — **a relayed confirmation, not a measurement of Vercel** |

**Window: at least 45 min 35 s, at most 55 min 36 s.**
**Accepted by Tim (2026-09-27):** all eight build decisions in §1 — including decision 2: reviews keep the posted-period-only
effective-date check; the stricter check (posted *or* an open payroll request) stays on salary-change requests only.
The §5 open question is therefore closed.

What the old app does against the new database (approvals ON):
- **Disposing of an asset is refused for everyone** — the old Dispose button (fixed-assets list and asset page) calls
  `dispose_fixed_asset`, which now refuses `ASSET_DISPOSAL_NEEDS_REQUEST`; the old copy has no sentence for it, so it shows the generic
  text. Nothing is posted. There is no screen to raise a disposal request until the deploy.
- **Saving the HR decision on a submitted review is refused** (`REVIEW_FROZEN_AFTER_SUBMIT`, generic text in the old copy); drafts save
  as before.
- **There is no screen to raise a salary change until the deploy** (there was none before either).
- **Unaffected:** first salaries, payroll, depreciation, month-end close, commissioning an asset with no waiting disposal, every other
  approval chain, the switch, everything pending. **Live impact:** nothing was waiting; 0 reviews exist; no asset has ever been disposed of.

## §7 · Commit, push, three SHAs

Reported in the hand-back message: `HEAD`, `origin/main` and `git ls-remote origin main` as full 40-character SHAs (a commit cannot
carry its own hash). Deployment is Tim's to read; the window's end stays PENDING until he does.
**Next cut:** APR-10 — GST filing approval and purchase-order categories (`docs/forward-queue.md` item 15).
