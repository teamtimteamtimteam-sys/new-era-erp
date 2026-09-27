# EMP-SELF-1 — employees find their own leave and claims, see who decided and why, and cancel or withdraw what is still pending (2026-09-27)

The remaining part of EMP-SELF-1 (EMP-SELF-0's G1, G2, G3 and Q9; its Batch 1, F1, shipped inside APR-ROUTE-1 as R5), plus three
fold-ins: TERMS-EDIT-1's broken window, the ended-contract header, and the exposure report's status. **No version number is assigned** —
one number for the whole approval chain, and per Tim's 2026-09-27 ruling that is now the next cut.

**Opening gate:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `888c97c4d39df7e3fe4c8b6626cd2979e3861b38` (TERMS-EDIT-1).
**Approvals were ON and stayed ON.** Every figure below is a script's own exit line or a query named with its identity (`postgres`,
`rolbypassrls = t`, base tables unless a view is named; "as X" = `SET LOCAL ROLE authenticated` + X's JWT, `auth.uid()` checked each time).

## §W · TERMS-EDIT-1's broken window — closed with bounds, labelled by kind

Tim confirmed TERMS-EDIT-1 deployed (2026-09-27), with no Vercel "Ready" time.

| | time (CST) | kind |
|---|---|---|
| start | 2026-09-27 18:02:10 | **measured**: `db/migration-windows.tsv` |
| end, lower bound | 2026-09-27 20:09:28 | **measured**: the push moved `origin/main` → `888c97c4` (`git reflog show --date=iso refs/remotes/origin/main`) |
| end, upper bound | 2026-09-27 20:21:25 | **derived**: this session's first read of `now()` as `postgres`, taken with Tim's "deployed" already in hand — a relayed confirmation, not a measurement of Vercel |

**Window: at least 2 h 07 min 18 s, at most 2 h 19 min 15 s.** Also written into `docs/handbacks/TERMS-EDIT-1.md` §7.
**Tim accepted TERMS-EDIT-1's build decisions 1 and 2 (2026-09-27):** the four "USD per tonne" labels stay baselined; the shared
`ContractDateInput` and the tightened date baseline stand. Recorded in `TERMS-EDIT-1.md` §7.

## §0 · Step 0 (grilling) and Tim's answers

`mattpocock-skills:grilling` was invoked on this cut's scope; the survey was sized to it (the named functions, pages and records, plus live
reads). **What grilling found** (live, read-only transactions, 2026-09-27 20:21–20:40):

1. **All six named accounts are linked and open `/me` today** — as each account under `authenticated`: `my_profile` 1 row each (chooer →
   EMP-2026-0001, fusheng → 0006, phua → 0005, sandra → 0004, vince → 0003, **tim@ → EMP-2026-0002 as an *additional* account**, APR-ROUTE-1 B).
   Own leave / medical / expense rows visible to each equal their true own counts. `approval_log` stays permission-scoped: fusheng reads 12
   rows, all `purchase_order` / `work_order` (his warehouse codes), none of the three self-service kinds.
2. **`cancel_leave_request` and `withdraw_expense_claim` had the NULL-blind gate too**, not only the three `submit_*`: for an identity with
   no employee record, `NOT (false OR x = NULL)` is NULL and the `IF` never fires. **Measured:** a signed-in identity with no employee record
   and no role reached "cannot execute UPDATE in a read-only transaction" in `withdraw_expense_claim(CLM-2026-0004)` (chooer's) — every check
   passed. fusheng (linked) got `PERMISSION_DENIED`. 15 functions share the shape (`grep`); 5 write, 10 read balances. *Derived from the code,
   not measured before the fix:* the same hole let such an identity **submit** leave / claims for any employee id, not only NULL — fixture 231
   N1–N3 now pin the refusal.
3. **An employee could cancel their own *approved* leave**, even leave already taken — `cancel_leave_request` refused only `cancelled` /
   `rejected`.
4. **Cancelling overwrites `decided_by` / `decision_notes`**, so a cancelled leave names its canceller, not its approver.
5. **Deciders moved since EMP-SELF-0:** ROLE-1 Batch 1 put leave and medical decisions on `action.decide_hr_requests` (holders: admin@, chooer@,
   tim@ — revoked grants excluded). APR-9 touched none of the scoped functions (`git log db34b2c4..HEAD` over them).
6. **Contracts:** 0 on live. `guard_contract_write` read only `request:` / `active`; `price_exposure_report` counted every non-deleted contract;
   the smoke's sell needle accepted only two sentences.

**Tim accepted all eight recommendations (2026-09-27):**

| Q | built |
|---|---|
| Q1 | the employee's own arm in `cancel_leave_request` cancels only `pending`, else `LEAVE_OWN_CANCEL_PENDING_ONLY\|code\|status`; `module.hr.edit` still cancels approved leave |
| Q2 | all five NULL-blind writes gated `NOT COALESCE(…, false)`; `withdraw_medical_claim` born hardened; the ten balance readers registered (`EMPSELF1-BALANCE-READERS-NULL-BLIND`) |
| Q3 | label by status — "Cancelled by … · reason" from the same fields; the HR-cancel overwrite registered (`EMPSELF1-HR-CANCEL-OVERWRITES-APPROVER`) |
| Q4 | the decider is the person: `account_person(decided_by)` → `preferred_name`, else `legal_name` (the `ActorName.tsx` rule, blank preferred names fall back); decider = subject → "decided by you (flagged)", derived from the document |
| Q5 | one owner-rights function `my_document_decisions()` → `(kind, doc_id, decider, decided_at, decision_notes, self_decided)`, caller's own documents only, 0 rows with no employee record; EXECUTE to `authenticated`, not `anon`; both claim views unchanged |
| Q6 | a third named zero `no_active_contracts` (en + zh) with a count line; the smoke needle accepts the three sentences or the positions table's header |
| Q7 | every update to an expired / terminated contract refused `CONTRACT_TERMS_FROZEN\|code\|expired/terminated`, status changes included; a draft may still go straight to expired / terminated; fixture 230 F3 flipped |
| Q8 | `withdraw_medical_claim` has an HR arm (`module.hr.edit`) in the database; the only button this cut is the employee's on `/me` |

## §1 · What shipped

**Database** — one migration, `db/migrations/2026-09-27-emp-self1-find-see-and-withdraw-your-own.sql`, built by
`db/scripts/build_emp_self1_migration.py` from the mirrors:
- `medical_claims`: status `withdrawn`, column `withdrawn_at` (appended), constraint `medical_claims_withdraw_shape`
  (`withdrawn` ⇔ `withdrawn_at` set — the `expense_claims` shape). No column grants on this table, so nothing to extend.
- **New** `withdraw_medical_claim(uuid)` (DEFINER; own or `module.hr.edit`; `submitted` only, else `MEDICAL_CLAIM_NOT_SUBMITTED|code|status`;
  never touches `decided_*`).
- **New** `my_document_decisions()` (DEFINER, `STABLE`, SQL; the in-body `current_user_employee()` is its caller check).
- **Replaced** `submit_leave_request` · `submit_medical_claim` · `submit_expense_claim` · `cancel_leave_request` · `withdraw_expense_claim`
  (the COALESCE gate; `cancel_leave_request` also the Q1 rule), `guard_contract_write` (Q7), `price_exposure_report` (Q6: positions,
  `contracts_with_pricing_terms` and `pricing_terms_total` count `active` contracts only; coverage adds `contracts_active`).
- **No new permission code**, so the standing "grant every new code to admin in the same migration" had nothing to grant. The migration's
  own proof asserted: grants unchanged; approvals still on; pending documents identical before/after; approval_log, journal entries / lines /
  debit total, contracts, and the three document tables' (code, status, decided_by) digests unchanged; the new functions' shape and ACL;
  all five gates COALESCE-hardened; `my_document_decisions()` gives 0 rows to a caller with no JWT; exposure still `no_contracts`; and every
  pending document still has a decider who is not its own party (9 printed, below).
- **Fixture 231** (N · C · W · D · E · H · I — seven arms, one a fault injection). **Fixture 230 F3 flipped** (it pinned the old header rule).

**Screens** — en and zh copy for everything:
- Avatar menu: the row is now **"Me: leave, claims, payslips" / 「我:请假、报销、工资单」**, followed by **"My leave" / 「我的请假」** →
  `/me#leave` and **"My claims" / 「我的报销」** → `/me#claims`. No new route, no permission (same as `/me`).
- `/me`: anchors `#leave` and `#claims` (`scroll-mt-20`). Each of the three tables gains a **Decision** column (who · when · note; "Cancelled
  by …" on cancelled leave; "Decided by you (flagged)" when the decider is the subject). Leave notes read the row's own `decision_notes`
  (the EMP-SELF-0 leave note); the expense note moved from the description cell into the decision column so it is not shown twice.
- `/me` leave: **Cancel request** on pending rows (confirmation dialog naming the request); on approved rows the button is **visible,
  disabled, with the reason** ("only HR can cancel approved leave"). `/me` medical: **Withdraw** on submitted claims; visible-disabled with the
  reason on approved / paid ones. Rejected / cancelled / withdrawn rows have no control — there is no refused action there.
- `/hr/claims`: the status filter lists **Withdrawn**; a withdrawn claim shows no decide / pay controls (they render only for submitted /
  approved).
- `/finance/price-exposure`: the new named zero, and a count line ("N contract(s) on file, M in effect") above the sell section.
- Error copy: `LEAVE_OWN_CANCEL_PENDING_ONLY`, `MEDICAL_CLAIM_NOT_SUBMITTED` (the status is translated, not printed raw), `MEDICAL_CLAIM_NOT_FOUND`.
  The contract header already mapped `CONTRACT_TERMS_FROZEN|…|expired/terminated` to its named sentence.

**Build decisions taken without asking — say if any is wrong:**
1. **The expense panel's Withdraw keeps its old behaviour** (shown only on submitted rows, hidden otherwise). The two new controls follow the
   visible-disabled-with-reason rule; converting the existing expense control was not in scope.
2. **Cancel and Withdraw take no reason.** `cancel_leave_request`'s reason is optional in the database; asking for one would make it required
   in the dialog (`ConfirmButton`'s reason field is always required).
3. **The live proof ran after the smoke**, not before it, so the two never ran on live at the same time.

## §2 · Verify — every figure is the script's own line

| step | result |
|---|---|
| `db/gate.py --offline` | `GATE_OFFLINE_EXIT=0` on the first run (54 s), 234 fixtures ✓ incl. 231, 230 (F3 flipped), 205, 150, 12; re-run after the app, copy and script edits: `GATE_OFFLINE_EXIT=0` (60 s) |
| before readings | `READINGS_OWN_EXIT=0` (21:01:10, `db/scripts/2026-09-27-emp-self1-readings.sql`) |
| backup (detached, nohup) | `BACKUP_EXIT=0` — `evoltrya-backup-2026-09-27-2105.dump` (5.1 MB, TOC 6,600; previous 6,598, floor 5,938), done 21:33 (≈ 28 min; the file stayed 0 bytes through the catalogue phase — `pg_stat_activity` showed `EXECUTE dumpFunc(…)` progressing) |
| dry run of the migration file on live (`COMMIT` → probe + `ROLLBACK`) | `DRY_OWN_EXIT=0`; probe: both new functions present, `medical_claims_withdraw_shape` 1; all proof assertions passed; 9 pending documents each with a decider |
| `db/apply_migration.sh` | `APPLY_OWN_EXIT=0`; preflight: 10 `CREATE FUNCTION` — 7 replaced · 3 new (the third is the proof's `pg_temp` helper); 1 column added, 0 on a masked table; every proof assertion passed |
| types | `NOTIFY pgrst`, then `db/wait_for.sh` until both new functions appeared (59 s); `TYPES_OWN_EXIT=0` (+15 lines: `withdrawn_at` ×3, `my_document_decisions`, `withdraw_medical_claim`) |
| `npx tsc --noEmit` | `TSC_OWN_EXIT=0` |
| `npm run build` | `BUILD_OWN_EXIT=0` on the first run; no tracked file regenerated |
| `db/gate.py` (full, detached) | **`GATE_EXIT=0`** (522 s) — rebuild ✓ · mirrors vs live ✓ (structure, seeds, bootstrap, definer) · fixtures ✓ · anonymous surface ✓ (baseline 327) |
| `node scripts/check-i18n.mjs` | `I18N_OWN_EXIT=0` |
| `node scripts/check-error-swallowing.mjs` | `SWALLOW_OWN_EXIT=0` (0 unallowed, 9 allowlisted) |
| smoke — run 1 (detached) | **`SMOKE_EXIT=1` at import, before anything started**: my new exposure needle `priceExposure.colBaseEvent` ("Base event", 10 characters) was refused by the smoke's own `longestLiteral` guard (≥ 12) — the guard doing its job. No route requested, no account created: `.ephemeral/` 0 plans |
| smoke — run 2 (needle = the positions table's "Ordered quantity", `priceExposure.colQuantity`) | **`SMOKE_EXIT=0`** — **256 ok, 7 skipped (no data), 0 failed** (237 routes + probes; 230 timed, total 1,679.3 s, median 6,850 ms). Clean-up read back as `postgres` (base tables, 22:38:18): `.ephemeral/` 0 plans; `auth.users` 7 (0 `smoke-%`); `roles` 13 (0 `probe-%` / `fixture-%`); unrevoked `user_roles` 7; `ZZ-SMOKE%` employees 0; contracts 0; pricing terms 0. The scratch-row report listed 6 **pre-existing** ZZ-SMOKE rows (606–1,249 h old, 5 still referenced) — report-only, not this run's |
| after the full gate and build | only `scripts/smoke-routes.mjs` (the needle), `db/scripts/…-live-proof.sql` (the P4 expectation) and docs changed. Smoke run 2 executed that exact smoke file; the gate check that reads `db/` and `scripts/` text was re-run on the final tree: `CCY_OWN_EXIT=0`. Neither `next build` nor the full gate reads those files otherwise, so they were not re-run |
| live proof | `PROOF_OWN_EXIT=0` on the second run (§3). The first run stopped by name at P4 (`PROOF_OWN_EXIT=3`, nothing committed): it expected fusheng to read exactly 3 decisions, but he already had one on live (CLM-2026-0003, rejected by Choo Er — seen in Step 0). The expectation was wrong, not the reader; the script now counts his earlier decided documents first |
| after readings | `READINGS_OWN_EXIT=0` (22:39:55) |

## §3 · Live proof and the before / after readings

Script `db/scripts/2026-09-27-emp-self1-live-proof.sql`, one transaction, `ROLLBACK` at the end — **nothing was left on live**
(`PROOF_OWN_EXIT=0`, rolled back 2026-09-27 22:39:24 CST). Connection `postgres` (`rolbypassrls = t`); each cell switches to the real
account's JWT under `authenticated` and first asserts `auth.uid()` and `current_user`.

| cell | who | what | result |
|---|---|---|---|
| P0 | postgres | identity | approvals on · journal entries 82 · fusheng → EMP-2026-0006 · sandra → 0004 · tim@ → 0002 (additional account) |
| P1 | fusheng@ (plain employee: no HR or finance code) | submit two unpaid leave requests, two medical claims, two expense claims | LV-2026-0004 / 0005 · MC-2026-0002 / 0003 · CLM-2026-0005 / 0006 |
| P2 | sandra@ (second person) | submit one leave request, one medical claim | LV-2026-0006 · MC-2026-0004 |
| P3 | chooer@ · tim@ | decide | chooer: fusheng's leave 1 **approved** ("Approved — cover arranged"), medical 1 **rejected** ("Receipt missing"), expense 1 **rejected** ("Not a business trip", level 1 with approvals on); sandra's leave approved ("OK"). tim@: sandra's medical rejected ("Dental is not covered") |
| P4 | fusheng@ | `my_document_decisions()` | **4 rows = his 1 earlier decided document + the 3 decided here**, every one "by Choo Er" with its note; none of sandra's. His leave note also reads through `leave_requests` (own-rows RLS, base table): "Approved — cover arranged" |
| P5 | fusheng@ | cancel / withdraw his own | leave 2 (pending) → **cancelled**; leave 1 (approved) → **`LEAVE_OWN_CANCEL_PENDING_ONLY\|LV-2026-0004\|approved`**; medical 2 → **withdrawn**; medical 1 (rejected) → **`MEDICAL_CLAIM_NOT_SUBMITTED\|MC-2026-0002\|rejected`**; expense 2 → **withdrawn** |
| P6 | fusheng@ · sandra@ | each only their own | fusheng cancelling sandra's leave / withdrawing her medical claim → `PERMISSION_DENIED\|module.hr.edit` (both). sandra's reader: **2 rows, only hers** — "leave by Choo Er · OK", "medical by **Tim** · Dental is not covered": tim@'s decision shows the person behind EMP-2026-0002 (preferred name), not the account |
| P7 | an identity with no employee record (random `sub`) | `withdraw_expense_claim(CLM-2026-0004)` (chooer's) | **`PERMISSION_DENIED\|module.finance.edit`**, status still submitted — Step 0 measured the same call reaching its UPDATE before the migration |
| P8 | sandra@ | a draft buy contract set to expired, then edited | title → **`CONTRACT_TERMS_FROZEN\|CON-2026-0080\|expired`**; back to draft → **same refusal** |
| P9 | sandra@ → tim@ | a sell **draft** carrying a pricing term; tim@ reads `price_exposure_report()` | **`no_active_contracts`, 0 positions**; coverage: contracts 2 (1 sell, 1 buy), active 0, contracts with pricing terms 0 |
| K | postgres | end of the transaction | journal entries 82 → 82 · approvals on · `approval_log` 19 inside the transaction (+5 decisions), all rolled back |

The rolled-back contracts advanced `contract_code_seq` (CON-2026-0080 and the next number are burned), as TERMS-EDIT-1 recorded for its
own proof. Leave / claim codes are computed from the tables, so the proof burned none (its second run reused LV-2026-0004).

**Before and after readings** — `db/scripts/2026-09-27-emp-self1-readings.sql` (part 1 as `postgres`, base tables, `relkind` printed; part 2
as tim@ on views; part 3 each account as itself). Before at 21:01:10 (before the backup), after at 22:39:55 (after the migration, both smoke
runs and the proof); `READINGS_OWN_EXIT=0` both times. Diffed (`diff` of the two outputs):
- **identical:** approvals on (L1 finance, L2 cfo, threshold 1000, locked before 2026-08-01); every document by status (leave: approved 1,
  pending 2 · medical: approved 1 · expense: approved 1, rejected 1, submitted 1, withdrawn 1); contracts 0 (ZZ-SMOKE 0), pricing terms 0;
  `approval_log` 14; journal entries 82, lines 184, Σ debits 1,636,102.89; balances 1000 −127,593.48 · 1100 43,002.12 · 1200 61,387.92 ·
  1400 18.00 · 2000 −376,404.42 · 2100 −102.87; catalogue 69; holders of the six relevant codes; **every role's code count, md5 and code
  list** (admin 68 `957c088c…` · cco 39 `0f3799de…` · cfo 30 `730763e8…` · finance 39 `1898acc0…` · gm 21 · cto 32 · warehouse 26 · …);
  every real account's `current_user_permissions()`; 7 unrevoked grants; `approval_pending_documents()` = 1 expense claim (1,000.00,
  `blocks_disable` 0); pending: LV-2026-0001 / 0003, MC-2026-0001 approved-unpaid, CLM-2026-0004; as tim@ on the views: AP list 416,988.32 /
  ledger 376,404.42, AR list 57,545.87 / ledger 43,002.12, **unexplained 0.00 on both sides**.
- **changed, as intended (and only these):** `medical_claims_status_check` gains `withdrawn`; `medical_claims_withdraw_shape` and
  `withdrawn_at` exist; `withdraw_medical_claim` and `my_document_decisions` absent → present (both DEFINER, `authenticated` t, `anon` f); the
  seven replaced functions' definition md5s changed (still DEFINER / INVOKER as before, `anon` f); the exposure coverage gains
  `contracts_active: 0` (state still `no_contracts`); each account's own `my_document_decisions()` count, read as itself: admin@ 0 · chooer@ 3
  (LV-2026-0002, MC-2026-0001, CLM-2026-0002) · fusheng@ 1 (CLM-2026-0003) · phua@ 0 · sandra@ 0 · tim@ 0 · vince@ 0.

## §4 · Who can do what now (approvals on)

- **Every employee with an account linked to an employee record** (all six real accounts, including tim@ through EMP-2026-0002): finds
  leave and claims from the avatar menu; sees who decided each of their own leave requests, medical claims and expense claims, when, and
  the note; **newly** cancels their own pending leave and withdraws their own submitted medical claim on `/me`; still withdraws their own
  submitted expense claim. **Newly refused:** cancelling their own approved leave (`LEAVE_OWN_CANCEL_PENDING_ONLY` — ask HR).
- **HR (`module.hr.edit`: admin@, chooer@)**: unchanged on screen; in the database also withdraws a submitted medical claim (Q8).
- **Deciders**: unchanged — leave / medical `action.decide_hr_requests` (admin@, chooer@, tim@); expense claims by tier (L1 finance =
  chooer@, L2 cfo = tim@).
- **Sandra (cco) and admin@ (`action.contract_terms`)**: **newly refused** any header change on an expired or terminated contract, status
  included (`CONTRACT_TERMS_FROZEN`); a draft can still be set straight to expired / terminated. The screen already disabled it.
- **Readers of `/finance/price-exposure`** (`module.finance.view`): drafts, suspended, expired and terminated contracts no longer count as
  positions; the page names that zero and shows the count.
- **An account with no employee record** (none on live today): **newly refused** by all five writes and by `withdraw_medical_claim`; reads 0
  rows from `my_document_decisions()`. It can still read balances through the ten registered readers.
- **Nothing left pending by this cut; every pending document still has a decider who is not its own party** (the migration printed each):
  CLM-2026-0004 → tim@; LV-2026-0001 / 0003 → admin@, tim@; MC-2026-0001 (pay) → admin@, chooer@; ST-2026-0082…0086 → chooer@.

## §5 · Findings closed and registered

- **Closed:** `TERMSEDIT1-ENDED-HEADER-WRITABLE` (Q7) · `TERMSEDIT1-EXPOSURE-IGNORES-STATUS` (Q6) — struck through in `docs/known-issues.md`
  with closing notes; and TERMS-EDIT-1's open broken window (§W). These are the three registered items this cut closes.
- **Registered (Tim's Q2 · Q3):** `EMPSELF1-BALANCE-READERS-NULL-BLIND` (the ten balance readers, named with the `grep` that finds them) ·
  `EMPSELF1-HR-CANCEL-OVERWRITES-APPROVER`.
- **Queue:** `docs/forward-queue.md` item 17 done; Tim's 2026-09-27 order written as items 18–20 — **one version number for the whole approval
  chain, with a detailed description → handover → overtime in a new window**; the colleagues' test comes after the version number, scheduled
  by Tim, and no longer blocks it; "Tim creates colleague accounts" removed (the accounts exist — Step 0 finding 1).

## §6 · Screen inventory — every action this cut adds or changes

| action | who | route | file |
|---|---|---|---|
| Find self-service: "Me: leave, claims, payslips" · "My leave" · "My claims" | every signed-in person | avatar menu → `/me`, `/me#leave`, `/me#claims` | `app/components/nav/AvatarMenu.tsx` · `messages/en.ts` / `zh.ts` (`nav.*`) |
| Submit leave / medical claim / expense claim (unchanged) | the employee | `/me` | `app/me/MyLeavePanel.tsx` · `MyClaimsPanel.tsx` · `MyExpenseClaimsPanel.tsx` |
| See who decided, when, and the note — leave · medical · expense | the employee, own documents only | `/me` (Decision column) | `app/me/DecisionCell.tsx` · `app/me/page.tsx` (`my_document_decisions()`) · the three panels |
| Cancel own pending leave (confirm dialog) | the employee | `/me#leave` | `app/me/MyLeavePanel.tsx` → `app/hr/leave/actions.ts` `cancelLeave` |
| Cancel own approved leave — shown disabled with the reason | the employee | `/me#leave` | `app/me/MyLeavePanel.tsx` |
| Withdraw own submitted medical claim (confirm dialog) | the employee | `/me#claims` | `app/me/MyClaimsPanel.tsx` → `app/hr/claims/actions.ts` `withdrawMedicalClaim` |
| Withdraw an approved / paid medical claim — shown disabled with the reason | the employee | `/me#claims` | `app/me/MyClaimsPanel.tsx` |
| Withdraw own submitted expense claim (unchanged) | the employee | `/me#claims` | `app/me/MyExpenseClaimsPanel.tsx` → `app/finance/claims/actions.ts` `withdrawClaim` |
| Decide leave / medical (unchanged) | `action.decide_hr_requests` | `/hr/leave/[id]` · `/hr/claims/[id]` | `app/hr/leave/[id]/DecideControls.tsx` · `app/hr/claims/[id]/ClaimControls.tsx` |
| Decide expense claims (unchanged) | L1 finance · L2 cfo | `/finance/claims` | `app/finance/claims/` |
| Filter HR's claims list by Withdrawn | `module.hr.view` | `/hr/claims` | `app/hr/claims/page.tsx` |
| Edit an expired / terminated contract's header — refused by the database, screen already disabled | nobody | `/contracts/[id]` | `app/contracts/[id]/HeaderForm.tsx` (unchanged) · `db/functions/guard_contract_write.sql` |
| Read the price exposure: new "none in effect" zero and the count line | `module.finance.view` | `/finance/price-exposure` | `app/finance/price-exposure/page.tsx` |

## §7 · The broken window — started, end PENDING

**Start: 2026-09-27 21:38:32 CST** (`db/apply_migration.sh`'s own "the database is new" line, also in `db/migration-windows.tsv`; its
"applied at" line reads 21:36:10). **End: PENDING — Tim reads it from Vercel.**

What the old app does against the new database (approvals ON):
- **Cancelling one's own approved leave** is now refused; the old app has no such button (`/me` had no cancel at all), and HR's cancel on
  `/hr/leave/[id]` is unaffected (`module.hr.edit`). The new code has no sentence in the old app; it would show the generic text.
- **The five hardened writes** answer every linked account exactly as before; only an account with no employee record (none on live) is
  newly refused.
- **`withdraw_medical_claim` and `my_document_decisions()`** exist but the old app never calls them; no medical claim can become `withdrawn`
  through the old app. (Had one been withdrawn through the API, the old `/me` and `/hr/claims` would print the raw key `claims.state_withdrawn`.)
- **Contracts and the exposure report:** 0 contracts on live, so neither change is reachable; the report still answers `no_contracts`.
- **Unchanged:** everything else — submitting on `/me`, every decision screen, both claim views, the approval switch, everything pending.

## §8 · Commit, push, three SHAs

Reported in the hand-back message: `HEAD`, `origin/main` and `git ls-remote origin main` as full 40-character SHAs (a commit cannot carry
its own hash). Deployment is Tim's to read; the window's end stays PENDING until he does.
**Next cut:** one version number for the whole approval chain, with a detailed description — `docs/forward-queue.md` item 18.
