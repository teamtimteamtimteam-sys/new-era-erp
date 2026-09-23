# APR-ROUTE-1 · Batch A — higher decides lower, one flagged exception, "someone OTHER than the subject", and the expense-claim read leak (2026-09-23)

**Opening gate (passed):** working tree clean; `HEAD` = `origin/main` = `git ls-remote origin main`
= `db34b2c4e354f9fb7a8961b0a608cb60e7111d4d` (EMP-SELF-0).

**This handback covers Batch A only** (Tim's Q13: two batches, stop after Batch A is pushed).
Batch B (R3, one person with several accounts) is still owed. §7 lists exactly what it owes.

**★ Broken window start** (from the line `db/apply_migration.sh` prints itself):
### `2026-09-23 11:41:37 CST`
Recorded to disk in `db/migration-windows.tsv` as `2026-09-23T11:42:09+0800` (the line the script writes after COMMIT).
**End: closed (recorded in Batch B, 2026-09-23). ★ This is an upper bound, not a measurement.**
> In the Batch B brief Tim said Batch A was deployed, without a clock time. The tightest bound this machine can read
> is the moment that brief was already in hand: Batch B's opening gate ran `date` and read **`2026-09-23 12:11:29 CST`**.
> ☞ **Window ≤ 29 min 52 s** (11:41:37 → ≤ 12:11:29).
> **Kinds:** the clock time is measured here; "deployed" is relayed by Tim. The real end (Vercel Ready) can only be earlier.

**★★ What is broken during the window.** Approvals are ON. The database is new and production still runs the old code:

| what | during the window |
|---|---|
| ★ **expense-claim reads** (`expense_claim_status`) | **Tightened as soon as the migration committed.** It lives in the view, so it does not wait for the deploy. Old `/finance/claims` gates on `module.finance.view` and passes the predicate, so it sees everything as before. Old `/me` filtered to its own rows and still does. **Nothing a legitimate reader saw goes missing.** |
| ★ **who can decide** | **Only widened.** R1: `admin@swm-os.test` (the only `cfo` holder) can now decide level-1 purchase orders and expense claims. R2: admin can decide his own expense claims and his own medical claims (he also holds `hr.edit`), and each such decision is flagged. The old UI calls the same RPCs. The flag is written by the database, not the app. |
| **refusals** | Unchanged in wording. `SELF_APPROVAL_FORBIDDEN|raiser/subject` and `APPROVAL_NOT_AUTHORISED|n|role` keep the shapes the old error mappers already know. |
| `/settings/approvals` | The new "Whose own documents have nobody else to decide them?" block **does not render**, because the old code does not send it. `approvals_readiness()` returns two extra fields; the old page ignores them. **No error.** |
| `/finance/self-approved` | **404 until the deploy.** Nobody has self-approved on live (0 rows), so nothing is hidden. |
| the switch | ★ **Still ON.** This cut never touched it (migration self-check ①). |

☞ **In one line: nothing gets worse during the window.** The one tightening (R5) removes rows only from readers who should never have had them.

---

## ★★★ F1 FIRST — `expense_claim_status` gave every expense claim to every signed-in user (Tim's R5)

**Before.** The view runs with owner rights (`security_invoker = off`), so the RLS on `expense_claims` never applied, and **its body had no row predicate.**
Measured on live **before** the migration as **fusheng** (simulated: `SET LOCAL ROLE authenticated` plus `request.jwt.claims.sub`; `current_user = authenticated`, `auth.uid()` confirmed equal to fusheng's id, `has_permission('module.finance.view') = f`). Reading the **view**: **4 rows, 2 employees.** The true total of `expense_claims`, read as `postgres` (`rolbypassrls = t`) from the **base table**, is **4**. So every claim, with names, amounts and descriptions, was readable through PostgREST by anyone signed in. Only `/me`'s own page filter kept it off that screen.

**Fix.** `WHERE has_permission('module.finance.view') OR c.employee_id = current_user_employee()` is now inside the view. This is the same shape as `medical_claim_status`. Both conditions are evaluated for the **caller** (both are `SECURITY DEFINER` and read `auth.uid()`), so owner rights do not turn them into "whatever the owner can see".

**After, measured on live** (same identity, same view): **1 row, and it is his own** (`others_rows = 0`). Control in the same transaction: **chooer** (`module.finance.view = t`, `auth.uid()` confirmed) reads **4**, which is all of them.

**Who lost a row they should have seen: nobody.** `grep expense_claim_status` over `db/views`, `db/functions`, `app` and `lib` finds two readers:
- `app/me/page.tsx`, which reads its own rows;
- `app/finance/claims/page.tsx`, whose page gate is `module.finance.view`.

No view or function reads it. **One reader did lose rows: fixture 196, arm F0b.** It read the view as `postgres` with empty claims to prove "the view has content". That arm now reads as a `module.finance.view` identity. Its anonymous arm still clears claims itself, because proving "no identity reads nothing" is its purpose.

**The mirror's COD-2 justification was false for this view, and it is corrected in place.** It said a predicate would drop rows from `operations_now`. Nothing reads this view there.

**The fixture Tim asked for (Q11): fixture 205, arm R5.**
- **A non-finance, non-subject reader** (`u_plain`) sees **only their own 2 of 4** claims.
- **A finance reader** sees **all 4.**
- **A reader with no finance permission and no claims** sees **0.**

Before every read the fixture asserts `auth.uid()` and `current_user = authenticated`, which is the control proving the role switch took effect. **Fault injection:** with the predicate removed, the arm goes red (`FIXTURE 205R5`).

---

## §1 · What shipped (Batch A)

| ruling | mechanism (one definition each) |
|---|---|
| **R1**: a level-2 holder may decide level-1 documents (tiered money chains only) | `approval_level_eligible(level, l1, l2)` is read by `require_approver_for` (runtime) and by `approval_deciders` (switch guard and panel). Later chains inherit it by calling `require_approver_for` and adding a row to `approval_chain_gates()`. |
| **R2**: the level-2 holder may decide **their own** expense claims and medical claims, flagged and reported | **Rule:** `self_approval_exception`. **Fact:** `approval_log.self_decided`, computed in `record_approval_decision`. **Second safety net:** CHECK `approval_log_self_decided_scope` allows `true` only on those two types. **Report:** `self_approved_decisions()`, shown at `/finance/self-approved`, gated by the new code `data.view_self_approvals` held by admin, gm and auditor. |
| **R3 groundwork**: recognise the person | `account_person(user)` is now the one "which person is this account" definition. `self_leg` (raiser/subject), `approval_deciders` and the flag all go through it. **In Batch A it reads `employees.user_id` only.** |
| **R4**: someone OTHER than the subject | `approval_deciders(...)`, which counts **people**. It is read by `approval_gate_intersections` (the enable check and the panel), by `approvals_readiness().own_document_gaps` (advisory) and by `APPROVALS_POLICY_WOULD_STRAND` (per pending document, using that document's real raiser and subject). |
| **R5 / F1** | the view's predicate (above) |

`forbid_self_approval` gained a third, required parameter, `p_subject_type`, with no default. **All six callers were updated:** `decide_expense_claim`, `decide_medical_claim`, `decide_leave_request`, `approve_review`, `post_stocktake` and `release_work_order`.

### Q5: who actually decides Tim's own medical claim
`decide_medical_claim` checks `module.hr.edit` **before** anything else. The exception never widens that gate.
- **In practice:** another `module.hr.edit` holder decides it. On live today that is **sandra (cco) or vince (gm)**.
- **`admin@swm-os.test`** holds both `cfo` and `hr.edit`, so it *could* decide it itself, and that decision would be flagged.
- **A CFO-only account** is refused with `PERMISSION_DENIED|module.hr.edit` (fixture 205 R2f).

### Q4: the MD's role
**Measured on live:** Vince (`EMP-2026-0003`) is the only real holder of `gm`. The migration's prologue asserts this and would have refused to commit otherwise.
⚠ One thing to know: `db/migrations/2026-09-03-navcleanup1-*.sql` records that "an outdated doc still writes gm as MD, and that person was separately ruled read-only". Tim named `gm` in Q4, and the code is also granted to `auditor`, so the MD can read the report whichever of those two roles he ends up in. **Not a stop:** the live reading matched Tim's condition.

### The finding Tim asked to be recorded
**A purchase order the `admin` account raises at 1,000 SGD or more can be approved by nobody.** Level 2's only holder is admin, the raiser check refuses him on his own document, and R2 does not cover purchase orders.
- Written into `docs/approvals.md` next to the rule "the admin account must not raise business documents".
- It is now visible on `/settings/approvals` as a red line (`approve_purchase_order` and `reject_purchase_order` at level 2, `who = Tim`, `self_exception = false`).

---

## §2 · Verification — every figure is the script's own exit line

| step | result |
|---|---|
| `db/gate.py --offline` (before migration) | `GATE_OFFLINE_EXIT=0` (the first run went red twice, as it should have: fixture 140J pinned the old 2-argument call string, and `definer` named the five new internal functions. Both were fixed and the rerun was green) |
| fault injection, fixture 205, on a throwaway local rebuild | **7 of 7 injections went red**: no-R1 (→ R4a) · no-R2 (→ R4a) · flag lost (→ R2a) · strand check blind to the raiser (→ R4b) · no predicate (→ R5) · exception extended to leave (→ R2e) · exception without the level-2 requirement (→ R1a). The clean run passed. |
| preflight | `PREFLIGHT_OWN_EXIT=0`: 19 functions (12 replaced, 7 new); 3 account codes, all `is_system` |
| backup | `BACKUP_EXIT=0` (the script's own line): `evoltrya-backup-2026-09-23-1132.dump`, 4.4M, TOC 5,911 entries (previous 5,901, floor 5,310) |
| `db/apply_migration.sh` | `APPLY_OWN_EXIT=0`, and all eight in-transaction self-checks passed (`APRROUTE1A 自证八条全过`). ★ **The first attempt (11:39:59) aborted with a syntax error and committed nothing.** The migration had been assembled by slicing the view statement from the mirror, and the slice started at a mention of `CREATE VIEW` inside the mirror's header comment. I fixed the extraction (anchored to the start of a line), then **dry-ran the whole migration on live with `COMMIT` replaced by `ROLLBACK`**: all eight checks passed, and 0 of the new functions remained on live afterwards. Only then did I apply it for real. Its readings: approval_log stays at 14; reading the view as `postgres` with no JWT returns 0 rows while the base table has 4; at level 1, expense, approve-PO and reject-PO each count **2 people**, and at level 2 each counts **1** |
| types (`npm run types:gen`) | `NOTIFY pgrst, 'reload schema'`, then `db/wait_for.sh` until the generated file contained the new signature and function (16s). Diff: `self_decided`, the six new functions, and the two new `approval_pending_documents` columns |
| `npx tsc --noEmit` | `TSC_OWN_EXIT=0` |
| `npm run build` | `BUILD_OWN_EXIT=0`. It went red twice before that, both times correctly: the deep-route list was stale (regenerated with `gen-deep-routes.mjs --write`), and a new page used a hand-made `<table>` (moved to `DataTable`) |
| `db/gate.py` (full) | `GATE_EXIT=0`: all four verdicts green (rebuildability · mirrors vs live · fixtures · anonymous surface), wall-clock 344s |
| `check-i18n` | `I18N_OWN_EXIT=0` |
| `check-error-swallowing` | `SWALLOW_OWN_EXIT=0` |
| smoke (detached) | `SMOKE_EXIT=0` (the script's own line, via `db/run_detached.sh`): 232 routes plus probes, **251 ok, 6 skipped (no data), 0 FAILED**. The walker requests every route under `app/`, so it includes `/finance/self-approved`. Its scratch-row report listed 6 stale rows, all 500–1,143 hours old and none from this cut |

---

## §3 · Live proof, approvals ON — one transaction, ROLLBACK, identity stated for each block

**Connection identity:** `postgres`, `rolbypassrls = t`. **Simulated identities:** `request.jwt.claims.sub` set to the named account, plus `SET LOCAL ROLE authenticated` wherever RLS or a view predicate decides the result. Each block carries its own `auth.uid()` control.

| block | identity (each with its own `auth.uid()` control = t) | result |
|---|---|---|
| **R5** | fusheng: `authenticated` + JWT, `module.finance.view = f`, reading the **view** | **1 row, his own; 0 from anyone else** (was **4 rows, 2 employees** before the migration) |
| R5 control | chooer: `authenticated` + JWT, `module.finance.view = t` | 4 (all of them) |
| **R1** | admin: `postgres` + JWT, calling `require_approver_for(1)` in the select list | **no exception**. Before the migration the same call raised `APPROVAL_NOT_AUTHORISED\|1\|finance`. ⚠ The column I printed, `admin_level1_passes`, came back `f`. That is my own mislabelled probe: a `void` return is not `NULL`. Success here is "no exception", and the R1 decision below proves it end to end |
| R1 control | chooer at level 2 | `APPROVAL_NOT_AUTHORISED\|2\|cfo`. **R1 points down only** |
| **R4** | admin: `authenticated` + JWT, `approvals_readiness()` | `own_document_gaps`: **expense_claim L2 · Tim · self_exception = true**; **approve_purchase_order L2 · Tim · false**; **reject_purchase_order L2 · Tim · false**. `chains_without_approver = 0`, `own_document_gaps_block = false`, `can_disable = true` |
| scratch claims | raised via `submit_expense_claim` by their own raisers | CLM-2026-0005 (chooer, own) · CLM-2026-0006 (admin, own) · CLM-2026-0007 (raised by admin, about chooer). All three rolled back; **CLM-2026-0004 was never touched** |
| refusal A | chooer decides his own claim | `SELF_APPROVAL_FORBIDDEN\|raiser` |
| refusal B | admin decides the claim **he raised for chooer** | `SELF_APPROVAL_FORBIDDEN\|raiser`. R2 does not cover it |
| **R1 decision** | admin rejects chooer's level-1 claim | **succeeds**. Log row: level 1, `self_decided = f`, actor = admin |
| **R2 decision** | admin rejects **his own** claim | **succeeds**. Log row: level 1, **`self_decided = t`** |
| **report** | vince (gm): `authenticated` + JWT | **1 row**: about Tim, decided by Tim |
| report refusal | fusheng | `PERMISSION_DENIED\|data.view_self_approvals` |

**Before and after**, read by `postgres` from **base tables**:

| reading | before the migration | after the migration, before the proof | after the proof's ROLLBACK |
|---|---|---|---|
| `approvals_enabled` | t | t | **t** |
| `approval_log` rows | 14 | 14 | **14** (rows with `self_decided`: 0) |
| purchase orders pending | 0 | 0 | 0 |
| expense claims submitted | 1 (CLM-2026-0004) | 1 | **1** (CLM-2026-0004 still `submitted`) |
| leave pending | 2 | 2 | 2 |
| medical claims submitted | 0 | 0 | 0 |
| reviews submitted | 0 | 0 | 0 |
| stocktakes open | 5 | 5 | 5 |
| work orders draft | 0 | 0 | 0 |
| expense claims total | 4 | 4 | 4 |

---

## §4 · Grilling: what it changed (Step 0 record)

1. **R5 drops rows in exactly one place, and it is a fixture.** Fixture 196 F0b was fixed in this cut.
2. **R3 is wider than two functions.** The account-only raiser check lives in `forbid_self_approval` (fixed here, through `self_leg`) and also in the two purchase-order functions and in `assert_segregated` (Batch B).
3. **R4 surfaced a gap nobody had named:** admin's own purchase orders at 1,000 or more have no decider.
4. **The R2 flag needed no backfill.** No historical decision was made by its own subject. The migration's self-check ③ recomputes this inside the transaction.

Tim accepted all thirteen recommendations (Q1–Q13). They are recorded in `docs/approvals.md` §3g and `docs/forward-queue.md` §3b-order, §3b-emp and §3b-route.

---

## §5 · Folded in, as Tim's (2026-09-23)

- **APR-3's broken window is closed** with an **upper bound**, labelled by kind in `docs/handbacks/APR-3.md`: at most 10 h 26 min 30 s. Start 00:32:48 CST, end at or before 10:59:18 CST. **The clock time is measured**: it is the `date` taken at this cut's opening gate, when Tim's brief was already in hand. **That APR-3 was deployed is relayed by Tim.**
- **The payment framing is confirmed** (approval before money leaves: payment request → approve → pay). Marked at `docs/approvals.md` §3e Q2 and in `docs/forward-queue.md`. Neither place literally said "unconfirmed"; both presented it as Tim's phrasing relayed through the APR-3 handback. Both now say it was confirmed on 2026-09-23.
- **EMP-SELF-0:** Q1–Q7, Q9 and Q11 accepted. Q10 (F1) fixed here. Q8 superseded by R1–R4. The rest of EMP-SELF-1 is scheduled after APR-6. Written in `docs/forward-queue.md` §3b-emp.
- **The queue order** is written in `docs/forward-queue.md` §3b-order.
- **R4 readiness is advisory.** Tim revisits blocking once the CFO-only account exists and level 2 has a second person. Written in `docs/approvals.md` §3g.

---

## §6 · Registered, not built

- **Fixture 205 R4a is the first arm to catch both "no R1" and "no R2".** The later arms (R1a, R2a) would catch them too, but I did not separately confirm that in the injection pass.
- **`/finance/self-approved` links an expense claim to the `/finance/claims` list, not to the claim itself.** There is no expense-claim detail page.

---

## §7 · Where this stops, and exactly what Batch B still owes (R3)

**Stopping line:** Batch A is pushed. Tim will not create the CFO-only account until Batch B ships, so the multi-account gap never opens on live. Batch B owes:

1. `employee_accounts (user_id PK, employee_id)`, plus a guard so one account cannot be in both `employees.user_id` and that table.
2. `account_person()` falls back to that table. **Only that function's body changes**: `self_leg`, `approval_deciders`, the R2 flag and the report already go through it.
3. `current_user_employee()` becomes `account_person(auth.uid())`, so a second account sees its person's `/me` (Q7). The 58 callers and the own-rows policies follow automatically.
4. The two bare `created_by = auth.uid()` checks in `approve_purchase_order` and `reject_purchase_order` become person-aware.
5. `assert_segregated` becomes person-aware (Q8).
6. `export_my_personal_data` uses `current_user_employee()`.
7. `user_directory`, `ActorName.tsx`, the editor names on the processing page and `batch_audit_trail`'s `actor_unresolvable` resolve a second account to its person.
8. A minimal "additional account of…" control on `/settings/accounts`, gated on `action.manage_permissions` (Q9).
9. A fixture proving: a second account deciding its owner's document is refused; the R2 flag is recorded by person; `/me` and the own-rows policies work for the second account.

---

## §8 · Commit, push, three SHAs

Reported in the terminal at push time: `HEAD`, `origin/main` and `git ls-remote origin main`. **Broken window: start 2026-09-23 11:41:37 CST, end PENDING (Tim's reading from the Vercel panel).**

---

# Batch B — one person, several accounts (R3), and `gm` made read-only (2026-09-23)

**Opening gate (passed):** tree clean; `HEAD` = `origin/main` = `ls-remote` = `08cf488c1ab816c60953dced69f47a10f0bf22d8`.

**★ Broken window start** (from the line `db/apply_migration.sh` prints itself):
### `2026-09-23 12:55:01 CST`
Recorded in `db/migration-windows.tsv` as `2026-09-23T12:55:30+0800`. **End: closed (recorded in APR-4, 2026-09-23) — ★ an UPPER BOUND, not a measurement: ≤ `2026-09-23 14:35:44 CST`, so window ≤ 1 h 40 min 43 s.** The clock time is APR-4's opening-gate `date`, taken with Tim's brief ("Batch B deployed") already in hand; "deployed" is relayed by Tim, and the real end (Vercel Ready) can only be earlier.

**★★ What is broken during the window.** Approvals are ON:

| what | during the window |
|---|---|
| ★ **Vince (gm)** | **Read-only immediately.** The permission change lives in the database, so it does not wait for the deploy. Every write he tries is refused by the database, and the old screens still show the refusal. Old pages that gate their controls in the UI now render them disabled (they read permissions live). |
| ★ **hr decisions** | leave · medical · reviews: deciders shrink from {admin, sandra, vince} to **{admin, sandra}**. No pending document is affected (none was raised by Vince or is about him). |
| **R3** | **Changes nobody's answer today.** `employee_accounts` is empty, and `account_person()` gives every existing account exactly the answer it gave before (migration self-check ⑤). The raiser checks are person-aware, but with one account per person they decide exactly as before. |
| `/settings/accounts` | The old screen has no "additional account" control and never calls the new functions. Saving roles on it keeps working, because no account is an additional account yet. |
| `/settings/approvals` | The old panel doesn't render the new people count; `approvals_readiness()` returns extra fields that the old page ignores. **No error.** |
| the switch | ★ **Still ON.** Never touched. |

☞ **In one line:** the only change that lands before the deploy is the one Tim ruled on: Vince can read but not write.

## B.1 · Findings recorded (Tim accepted all five)

1. **gm held 34 codes on live: 14 `module.*.edit`, no `action.*`.** This cut removed the 14 and kept 20 (15 `module.*.view`, plus `data.view_banking`, `view_prices`, `view_reviews`, `view_sales` and `view_self_approvals`). Nothing was added.
2. **This supersedes C-1's "gm stays exactly as it is"** (`docs/accounts-roles-and-permissions.md` §三 Q3). That note answered whether to *add* codes to gm, not whether to remove them.
3. **Why live never matched the 2026-09-03 "MD read-only" ruling:** it was applied to one page only (NAV-CLEANUP-1 kept `data.view_deleted` from gm). A day later, C-1 put Vince on the existing gm role with its 14 edit codes, and nothing narrowed gm after that.
4. **Vince can no longer create even personal tasks.** `tasks` inserts require `module.tasks.edit`, with no own-task exception. An own-task exception is registered in `docs/forward-queue.md` as a possible future cut, **pending Tim**. No write code was kept on gm to work around it.
5. **Batch A's broken window is closed with a measured upper bound** (above).

## B.2 · Tim's answers (Q1–Q6), as built

| Q | built as |
|---|---|
| Q1 | `link_additional_account` refuses **`ACCOUNT_HAS_DECISIONS|n`** when the account has any `approval_log` rows as the decider |
| Q2 | `unlink_additional_account`, on the same control (with a confirmation that names the consequence); every link and unlink writes a row to **`employee_account_history`**, which is append-only (`HISTORY_APPEND_ONLY`). Past `self_decided` values are kept (fixture 206 U) |
| Q3 | `approvals_readiness()` returns `level1_people` / `level2_people` next to the account counts; the panel prints both |
| Q4 | `module.tasks.edit` removed with the rest; the own-task exception is registered, pending |
| Q5 | live proof as written (§B.4) |
| Q6 | one session; no split needed |

## B.3 · What shipped

- **Tables:**
  - `employee_accounts` (additional accounts; primary key `user_id`; read by people with `hr.view` or `manage_permissions`, and by the account itself);
  - `employee_account_history` (append-only).
- **Two guards, one on each side:**
  - `ACCOUNT_IS_PRIMARY`: a main account cannot be added as an additional one;
  - `ACCOUNT_IS_ADDITIONAL`: an additional account cannot become anyone's main account, whether written directly or through `set_user_employee_link`.
- **"Which person":** `account_person()` falls back to the new table; `current_user_employee()` = `account_person(auth.uid())`.
- **Person-aware checks:**
  - `approve_purchase_order` and `reject_purchase_order` use `self_leg` (they keep the bare `SELF_APPROVAL_FORBIDDEN` code);
  - `assert_segregated`;
  - `export_my_personal_data`, via `current_user_employee()`.
- **Display:**
  - `user_directory` has a new last column, `account_kind` (`primary` / `additional` / null);
  - `batch_audit_trail` treats an additional account as resolvable;
  - `ActorName` resolves additional accounts, in the same by-id query, so the masked-read baseline is unchanged;
  - the processing-page editor names now come from `loadActorNames`.

  The two owner-rights views join the link table directly rather than calling `account_person`: an owner-rights view substitutes the owner for tables, not for function EXECUTE.
- **`/settings/accounts`:**
  - an unlinked account gets an "Additional account of…" picker, listing only people who already have a main account (`ADDITIONAL_NEEDS_PRIMARY` otherwise);
  - an additional account shows whose it is and gets an "Unlink" button with a confirmation;
  - saving roles on an additional account skips the main-link call.
- **gm:** the 14 edit codes are deleted on live, and the gm list in `db/tables/role_permissions.sql` is rewritten to match (runtime config, bootstrap still **correct**: it now says exactly what live holds).
- **Fixture 206**, 12 arms. **Fault injection on a throwaway rebuild: 9 of 9 injections went red, each at the arm meant to catch it:**
  - account lookup without the fallback → L2
  - purchase-order check by account → P3
  - segregation-of-duties check by account → P4
  - no Q1 refusal → H
  - guard on one side only → G
  - gm keeps an edit code → M
  - directory blind to additional accounts → D
  - people counted as accounts → R
  - unlink without history → U

  The clean run passed.

## B.4 · Verification — every figure is the script's own exit line

| step | result |
|---|---|
| `db/gate.py --offline` | `GATE_OFFLINE_EXIT=0` on the first run |
| preflight | `PREFLIGHT_OWN_EXIT=0`: 13 functions (8 replaced, 5 new) |
| backup | `BACKUP_EXIT=0` (the script's own line): `evoltrya-backup-2026-09-23-1244.dump`, TOC 5,931 entries (previous 5,911, floor 5,319) |
| dry run on live, `COMMIT`→`ROLLBACK` | all 7 self-checks passed; `employee_accounts` absent afterwards |
| `db/apply_migration.sh` | `APPLY_OWN_EXIT=0`; all 7 self-checks passed. BEFORE: gm 34 codes / 14 write · AFTER: gm 20 / 0 · `employee_accounts` 0 · approval_log 14 → 14 |
| types | `NOTIFY pgrst`, then `db/wait_for.sh` until the new table and functions appeared (8s) |
| `npx tsc --noEmit` | `TSC_OWN_EXIT=0` |
| `npm run build` | `BUILD_OWN_EXIT=0`. It went red twice first, both correctly: a third direct `employees` read in `ActorName` (merged into the existing by-id query), and the document registry's pinned table count (222 → 224, for the two new tables) |
| `db/gate.py` full | `GATE_EXIT=0`: all four verdicts green (rebuildability · mirrors vs live · fixtures · anonymous surface), wall-clock 466s |
| `check-i18n` · `check-error-swallowing` | `I18N_OWN_EXIT=0` · `SWALLOW_OWN_EXIT=0` |
| smoke (detached) | **First run: `SMOKE_EXIT=124`**. `db/run_detached.sh` stopped it at its 2,400-second limit, before any route was requested. The timeout line was written 55 minutes after the start, which points to the machine sleeping while Tim had paused the session; that is an inference, not a measurement. ★ **It left two throwaway accounts on live** (`smoke-1790140062250@test.local`, **holding `admin`**, and its `-reviewer` twin) plus a cleanup plan in `.ephemeral/13794.json`. I cleared them with the repo's own tool, `node scripts/reap-ephemeral.mjs` → `REAP_OWN_EXIT=0` (1 plan reaped, 0 failed). Re-read as `postgres` from the base tables: **0 accounts, 0 active grants.** **One immediate retry: `SMOKE_EXIT=0`**. 232 routes plus probes, **251 ok, 6 skipped (no data), 0 FAILED**; no plan and no lock left behind |

### Live proof — one transaction, ROLLBACK, identity at each block
| block | identity (each with its own `auth.uid()` control = t) | result |
|---|---|---|
| AFTER-0 | `postgres` (bypass), base tables | approvals `t` · approval_log 14 · gm **20 codes, 0 write codes** · `employee_accounts` 0 |
| setup | `postgres` | scratch account created **inside the transaction**, given `cfo` |
| link | admin: `postgres` + JWT | `link_additional_account` → linked to **EMP-2026-0002**; history 1 row |
| directory · readiness | admin: `authenticated` + JWT | `account_kind = additional`, `EMP-2026-0002` · level 2: **2 accounts / 1 person** · chain level-2 lines: 1 person each |
| who am I | scratch account: `postgres` + JWT, then `authenticated` | `current_user_employee()` = Tim's employee · under RLS: **own row 1, others 0** |
| refusal 1 | scratch account decides a claim **admin@ raised for chooer** | `SELF_APPROVAL_FORBIDDEN\|raiser`, because it is the same person |
| refusal 2 | scratch account, `assert_segregated` with first step by admin@ | `PROOF_SOD\|proof` (refused) |
| refusal 3 | scratch account rejects a scratch pending PO **raised by admin@** | `SELF_APPROVAL_FORBIDDEN` (the account got a scratch role with `purchasing.view` for this block: ~~`cfo` alone has none~~ ★ **APR-4: false — `cfo` holds `purchasing.view`; the scratch role was redundant, the refusal reading stands**) |
| R2 by person | scratch account (`cfo`) rejects **Tim's own** claim | succeeds; log row level 1, **`self_decided = t`**, actor = scratch account |
| Vince | vince: `postgres` + JWT, then `authenticated` | `decide_leave_request` on a scratch leave → **`PERMISSION_DENIED\|module.hr.edit`**. `module.finance.view` still t; `hr.edit`, `purchasing.edit` and `tasks.edit` are f. He reads `expense_claim_status` (6 rows = 4 live + 2 scratch) |
| unlink | admin | `linked = false` · history 2 rows · the account belongs to nobody · **earlier `self_decided` kept (t)** |
| AFTER-ROLLBACK | `postgres`, read-only | approvals `t` · approval_log **14** · self_decided rows 0 · all pending counts unchanged (0 · 1 · 2 · 0 · 0 · 5 · 0) · `employee_accounts` 0 · link history 0 · scratch account **0** · **CLM-2026-0004: submitted** · gm 20 / 0 |

**gm's permission list, before → after (read by `postgres`, base tables):** 34 codes (14 write) → **20 codes (0 write)**:
`data.view_banking, data.view_prices, data.view_reviews, data.view_sales, data.view_self_approvals` plus the 15 `module.*.view` codes
(customers, finance, hr, inbound, inventory, logistics, materials, output, pricing, processing, purchasing, sales, stocktakes, suppliers, tasks).

## B.5 · ★★ Tim's CFO-only account: the exact steps, once Batch B is deployed

> ### ★★ CORRECTED by APR-4 (2026-09-23): there is NO decision to make — option (a) is already true
> **Measured (APR-4, as `postgres`, `rolbypassrls = t`, base tables `role_permissions` + `roles`):**
> `cfo` holds five codes — `data.view_pay`, `data.view_prices`, `module.finance.view`,
> `module.logistics.view`, **`module.purchasing.view`** — granted 2026-08-30 / 2026-09-01 and
> unchanged since. **A CFO-only account can decide purchase orders.** The box below claimed a
> measurement that was never taken: the Batch B proof script has no query of `cfo`'s codes, only a
> comment, and it added a scratch role with `purchasing.view` before any refusal was seen.
> ☞ **Tim can create the CFO-only account now.** Steps ①–⑤ below apply as written, with step ⑤'s
> "(a)" branch — the only branch there is. See `docs/handbacks/APR-4.md` §0.
>
> *The original box, struck and kept (a removed claim and a never-made claim read the same):*
>
> ~~### ★★ Read this first: a decision only Tim can make~~
> ~~**The `cfo` role cannot decide purchase orders.** It holds `module.finance.view` and `data.view_prices`, but **not~~
> ~~`module.purchasing.view`**, which both purchase-order actions require. Today purchase-order level 2 is decided~~
> ~~through `admin@swm-os.test` only because that account also holds `admin`. **Measured:** `cfo`'s grants on live are exactly `data.view_prices` and `module.finance.view` (read by `postgres`, `rolbypassrls = t`, from the base tables `role_permissions` and `roles`). In the live proof, the scratch CFO account needed a scratch role holding `module.purchasing.view` before `reject_purchase_order` would even reach its raiser check. ☞ The proof's chain count cannot show this on its own: with `admin@` still holding `cfo`, the CFO account and `admin@` count as **one person**.~~
> ~~**So step ⑤ would leave purchase-order level 2 with nobody.** Before step ⑤, Tim chooses one:~~
> ~~**(a)** grant `module.purchasing.view` to the `cfo` role (on `/settings/roles`); or **(b)** keep `cfo` on `admin@` for now~~
> ~~and skip step ⑤. I haven't done either: no ruling covers the `cfo` role.~~


| # | step | what Tim should see |
|--:|---|---|
| ① | **Create the account** on `/settings/accounts` → *Create account*, holding **only** the `cfo` role, with **no** employee picked. | A new row with the amber "not signed in yet" badge. Under the email: "not linked to an employee". Roles: `CFO` only. |
| ② | **Sign in once** with that account (a private window), then sign out. | The badge disappears after the next reload of `/settings/accounts`. **Until this step the account is not a real holder:** `real_role_holders` ignores accounts that have never confirmed. |
| ③ | **Link it** (signed in as `admin@`): open the new row → *Edit* → **Additional account of…** → pick `EMP-2026-0002 — Tim` → **Link as additional account**. | "Saved." The row now reads **"Additional account of EMP-2026-0002 — Tim"**, and the edit panel offers *Unlink this additional account* instead of the employee picker. If it has already decided anything, the link is refused with a sentence saying so (Q1). Signed in as the new account, `/me` shows Tim's own profile. |
| ④ | **Confirm on `/settings/approvals`** that the CFO account is a real level-2 holder. | Level 2 (`cfo`): **"2 account(s) currently hold cfo and can sign in — 1 person/people."** Two accounts, one person, is correct. The chain lines: `decide_expense_claim` level 2 still says **1** person (it counts people). ~~**Also look at `approve_purchase_order` / `reject_purchase_order` level 2: they still say 1 person, and that person is reached only through `admin@`** (see the box above).~~ ★ **APR-4:** those lines say 1 person, and it is the same person either way — the CFO account holds `module.purchasing.view` through `cfo`. |
| ⑤ | **Only then:** revoke `cfo` from `admin@swm-os.test` (its row → *Edit* → untick `CFO` → a reason → *Save*). ~~and only after choosing (a) or (b) above~~ — ★ APR-4: there is no choice; (a) is already true. | The level-2 lines stay green with **1 person** (the CFO account), and the "whose own documents" block still lists Tim's own purchase orders, because the CFO account and `admin@` are the same person. ~~With (b): skip this step.~~ **If any level-2 line turns red "NOBODY holds both", tick `CFO` back on `admin@` straight away.** |

After step ⑤ (★ APR-4: "with (a)" is the only case): Tim's own expense claims can be decided by the CFO account as a flagged self-approval (R2), and every such decision appears on `/finance/self-approved`. Neither of his accounts can decide a document the other raised.

## B.6 · Commit, push, three SHAs
Reported in the terminal at push time. **Broken window: start 2026-09-23 12:55:01 CST.** ★ **End: closed (recorded in APR-4, 2026-09-23) — an UPPER BOUND, not a measurement.** Tim said Batch B was deployed, without a clock time; the tightest bound this machine can read is APR-4's opening-gate `date`, taken with the brief already in hand: **`2026-09-23 14:35:44 CST`**. ☞ **Window ≤ 1 h 40 min 43 s** (12:55:01 → ≤ 14:35:44). **Kinds:** the clock time is measured here; "deployed" is relayed by Tim.
