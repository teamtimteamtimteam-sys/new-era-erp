# APR-4 — none of the five documents waits for anyone; the own-task exception is built (2026-09-23)

**Opening gate (passed):** working tree clean; `HEAD` = `origin/main` = `git ls-remote origin main`
= `5b25505f9e88cd23bab491f6415c070bebe4a38e` (APR-ROUTE-1 Batch B). `date` at the gate: **2026-09-23 14:35:44 CST**.

**★ Broken window start** (from the line `db/apply_migration.sh` prints itself):
### `2026-09-23 15:19:53 CST`
Recorded to disk in `db/migration-windows.tsv` as `2026-09-23T15:20:25+0800`. **End: closed — an UPPER BOUND, not a measurement** (INB-PAY-1, 2026-09-23): Tim relayed "APR-4 deployed"; the latest clock reading taken before that relay reached this machine is **15:54:19 CST** (`date`, INB-PAY-1 Step 0). ☞ **Window ≤ 34 min 26 s.** The real end (Vercel Ready) can only be earlier; the commit is 15:45:57, so it cannot be earlier than the push after that.

**★★ What is broken during the window.** Approvals are ON and this cut never touches them. The database is new; production runs the old code:

| what | during the window |
|---|---|
| **approvals** | ★ **Untouched.** No chain, no policy row, no switch. Self-checks ① ② pin it: `approvals_enabled` t, `approval_log` 14 → 14, every pending count unchanged. |
| **Vince (gm) and tasks** | **Can create his own personal task immediately.** The old "New task" button was never gated, and the old form sends `task_type` from its dropdown; if he picks *team* the database refuses by name (`PERMISSION_DENIED|module.tasks.edit` → the old mapper shows `common.restricted`). The old detail page still hands him controls on tasks he cannot change; pressing them is refused by name, as before. |
| **editors on a team task they are not on** | Dragging its card used to be a silent 0-row update (the old action reports "nothing changed"). It is now **`TASK_NOT_EDITABLE`** — the old `taskErrorCodes.ts` does not know it and falls back to the shared fallback (a sentence plus a traceable short code), not a raw string. |
| **creating a task for someone else / changing an owner** | Refused by name for everyone (`TASK_OWNER_NOT_SELF` / `TASK_OWNER_IMMUTABLE`) — the old UI has no path that does either, so nobody meets it. |
| the switch | ★ **Still ON.** Never touched. |

☞ **In one line:** nothing anyone could do before stops working, except the silent no-op above, which now says why it did nothing.

---

## §0 ★★★ The CFO contradiction — Batch B was wrong, APR-3 was right

**Measured (APR-4 Step 0, as `postgres`, `rolbypassrls = t`, base tables `role_permissions` + `roles`):**
`cfo` holds **five** codes — `data.view_pay`, `data.view_prices`, `module.finance.view`, `module.logistics.view`,
**`module.purchasing.view`**. The five rows' `created_at` are 2026-08-30 19:05 (`purchasing.view`, `view_prices`),
2026-09-01 01:12 (`finance.view`, `view_pay`) and 2026-09-01 19:58 (`logistics.view`) — all before APR-3.
`role_permissions` has a primary key and a `created_at`; a revoke-and-regrant would carry a newer date. None does.
**No migration since APR-3 touches `cfo`'s grants** (APR-ROUTE-1 A added `data.view_self_approvals` to three other roles;
B deleted gm's 14 edit codes). This cut's migration re-asserts the five codes in self-check ③, and the live proof reads them
again before and after (below).

**Which reading was wrong and why:** Batch B's handback (B.5) says "**Measured:** `cfo`'s grants on live are exactly
`data.view_prices` and `module.finance.view`". **Its live-proof script (`after-b.sql` in that session's scratchpad) contains
no query of `cfo`'s codes.** The claim appears there only as a comment, and the script then gave the scratch account a
scratch role holding `module.purchasing.view` **before any refusal had been observed** — so nothing in that run could have
contradicted it. The repo's `db/tables/role_permissions.sql` bootstrap has no `cfo` role at all (it says so itself); that
is a plausible source of the belief, **but it is an inference — nothing records where it came from.**

**Consequence:** **no fix is needed and none was made.** A CFO-only account decides purchase orders. B.5's option (a) is
already true; **Tim can create the CFO-only account now.** B.5 is corrected in place (old text struck, kept);
`docs/approvals.md` §3g's Batch B finding likewise; `docs/forward-queue.md`'s CFO row likewise.

> ### ☞ The lesson Tim asked to be recorded
> **A handback's "Measured" must cite the query that measured it** — the table or view, the identity, and where the query
> lives. A "Measured" with no query behind it reads exactly like one with a query, and this one sent a false decision to
> Tim's desk, and Tim held off creating his CFO-only account until it was settled. It is the family AGENTS.md already names
> (「委托书里的【数】来自上一份报告,而不是来自一次测量」); the new face is that **the unmeasured claim was in the
> handback itself, labelled as a measurement** — not copied from an earlier report.

**Batch B's broken window: closed — an UPPER BOUND, not a measurement.** Start 12:55:01 CST (the migration script's own
line). End ≤ **14:35:44 CST**, this cut's opening-gate `date`, taken with Tim's brief ("Batch B deployed") already in hand.
☞ **≤ 1 h 40 min 43 s.** The clock time is measured here; "deployed" is relayed by Tim; the real end (Vercel Ready) can
only be earlier. Written into `docs/handbacks/APR-ROUTE-1.md` in both places it said PENDING.

---

## §1 · The five documents — none has a decision point (Tim's Q1: all dropped)

Status constraints read from the live catalog (`pg_constraint`); counts as `postgres` (`rolbypassrls = t`) from base tables.

| document | status on live | creating it | live rows | waiting now |
|---|---|---|---|---|
| goods receipt `inbound_batches` | `status` **no CHECK, never written** (`draft` on all 24); only `pricing_status` is constrained | stock moves on insert; the payable posts later when priced, and pricing *is* the posting | 24 (15 live) | none |
| invoice `invoices` | `issued` / `void` | born `issued`; `create_order_invoice` posts in the same transaction; trigger freezes all but `issued → void` | 9 | none |
| freight document `freight_documents` | `posted` / `reversed` | born `posted`; journal + inventory capitalisation in the same transaction | 4 (all reversed) | none |
| fixed-asset disposal `fixed_assets` | `active` / `disposed` | `dispose_fixed_asset` posts and sets `disposed` in one step | 2 (0 ever disposed) | none |
| processing run `processing_runs` | `committed` / `reversed` | commit creates the run, consumes stock, creates outputs in one transaction | 14 (10 committed) | none |

* **(c) amounts / routing / deciders:** moot — nothing can be wired. For the record: invoice `total_base` and freight
  `amount_base` are NOT NULL and known at creation; disposal proceeds are typed at disposal (NBV computed, not stored);
  goods receipts have no header amount (quantity × unit price, can be NULL); processing runs' `total_cost_base` is NULL
  until allocation.
* **(d) system-created paths:** none, for all five — every one is created only by a signed-in person through a server action.
* **(e) N4:** `cost_incomplete` is per output leg, written only by `allocate_processing_costs`; cost entries exist only
  after the run; allocation goes stale later. **N4 cannot be judged at commit as it stands** — recorded in approvals.md §3h.
* **(f) disable gate:** nothing joins it.
* `approval_log`'s subject-type list: **untouched** (Tim's Q1).

**Q2** queued one lifecycle candidate (fixed-asset disposal request) and named two, not queued (goods-receipt pricing,
processing-run cost allocation). **Q3** registered five findings in `docs/known-issues.md`; the first —
**a goods receipt priced at creation posts no payable and no price history** (live: IN-2026-0011, IN-2026-0012) — is
queued as **the next cut, ahead of the payment request**.

⚠ **Not in this cut, flagged for Tim:** `docs/forward-queue.md` had also filed the **pricing-terms commitment** (APR-3 Q3's
destination) under APR-4. This cut's brief named five documents and not that one, so it was not touched. It stays queued,
unscheduled.

---

## §2 · What shipped — the own-task exception (Tim's Q4–Q8)

| ruling | mechanism |
|---|---|
| **Q4** own task = `task_type='personal' AND owner_id = current_user_employee()` | `task_is_own(task_type, owner_id)` — the one definition, judged on the row's own columns; read by the insert policy, `can_write_task` and `trg_tasks_guard_write` |
| **Q5** allowed: create (forced personal, own) · header/status · steps add/edit/tick/delete · soft-delete; forbidden: promote · participants · owner; `module.tasks.view` still required | `can_write_task(id)` = `can_edit_task(id)` OR (view AND own) — tasks WITH CHECK, task_nodes write policies and guard, `task_board_rows.may_write`. Participants and promotion stay on `can_edit_task` |
| **Q6** for everyone: owner must be yourself; owner never changes | insert policy `owner_id = current_user_employee()` + guard → `TASK_OWNER_NOT_SELF`; guard → `TASK_OWNER_IMMUTABLE|<code>` |
| **Q7** named refusal, fault-injected | three per-row BEFORE guards; see the deviation below |
| **Q8** one "may edit" predicate, visible-disabled-with-reason | `lib/taskAccess.ts` reads `may_write` / `may_manage` from the database (never compares codes to decide); `TaskEditGate` gives two reasons two sentences; board cards not writable can't be dragged and say "Read only"; the new-task form locks the type to personal without the code (with a hidden input, because a disabled select is not submitted) |

### ★ The one deviation from Q7's wording — forced by a measurement, not a preference
Q7 said *replace* `enforce_write_permission` on the three tables with a per-row trigger. **That cannot work as written:**
① row-level triggers **do not fire when a statement matches zero rows** (measured in SILENT-1; `enforce_write_permission`'s
own header) — so a write the policy's `USING` filtered out would still be a silent zero-row success; and ② fixture 198
requires a trigger **named** `enforce_write_permission` on every table with a write policy. **So:** it stays (on `tasks` and
`task_nodes` it now also accepts `module.tasks.view`, the one change the exception needs), the UPDATE/DELETE `USING` widens
to "rows you can see", and the per-row guards refuse by name. **Net effect is what Q7 asked for:** the exception works, and
every other write is refused **by name** — including one that used to be silent (below). Fault injection F4/F5/F7 proves
each piece bears load.

### ★★ Q6 — what the "before" reading showed, and it corrected the grilling
The grilling said the owner-transfer gap was **inferred, not tested**. Measured **before** the migration (live, one
transaction, ROLLBACK; chooer as `authenticated` + JWT, control `current_user = authenticated`, `auth.uid()` = chooer):

| probe (before) | result |
|---|---|
| editor transfers **his own personal** task to Sandra | ★ **already refused** — `new row violates row-level security policy for table "tasks"` (unnamed). The grilling's inference was wrong for personal tasks. |
| editor transfers **his own team** task to Sandra | ★ **succeeded** (`team_task_transferred_to_sandra = t`) — the gap was real |
| editor creates a **team** task owned by Sandra | ★ **succeeded** (1 row) — Q6(i) was real |

After the migration all three are refused by name (§3). `tasks` read 20 before and after each probe.

### ★ A behaviour change for editors, named
An editor who is **not on** a visible team task used to get a silent 0-row update; now `TASK_NOT_EDITABLE|<code>`.
**Fixtures 92 (arms B, C×2) and 95 (C2, E2, and H's premise)** asserted the old silent zero / the unnamed RLS error and now
assert the named refusal **and** that nothing changed. The invisible cases (someone else's personal task) still read 0 rows.

### Files
- `db/migrations/2026-09-23-apr4-own-tasks-and-five-documents-that-do-not-wait.sql` (7 in-transaction self-checks)
- `db/functions/`: `task_is_own` · `can_write_task` · `trg_tasks_guard_write` · `trg_task_nodes_guard_write` · `trg_task_participants_guard_write`
- `db/tables/`: `tasks` · `task_nodes` · `task_participants` · `db/views/task_board_rows` (two columns at the end)
- `db/fixtures/207-your-own-personal-task-and-nothing-of-anyone-elses.sql` (new) · `92` · `95` (updated as above)
- `lib/taskAccess.ts` · `app/tools/tasks/TaskEditGate.tsx` · `page.tsx` · `TaskBoard.tsx` · `TaskModal.tsx` · `types.ts` · `taskErrorCodes.ts` · `[id]/page.tsx` · `[id]/TaskHeader.tsx` · `[id]/NodeTree.tsx` · `[id]/Participants.tsx`
- `messages/en.ts` · `messages/zh.ts` (`tasks.access.*`, three `opErrors`)
- `lib/database.types.ts` (regenerated)

---

## §3 · Verification — every figure is the script's own exit line

| step | result |
|---|---|
| fixture 207 on a throwaway local rebuild | passed; fixtures 92, 93, 94, 95, 101, 188, 198, 199, 206 run on the same rebuild — 92 and 95 went red as expected (§2) and were updated |
| fault injection, fixture 207, same rebuild | **8 of 8 red at the arm meant to catch each:** F1 owner not frozen → X4 · F2 insert owner free → X6 · F3 exception may promote → X2 · F4 statement trigger edit-only → O2 · F5 tasks USING narrowed back → X5 · F6 participants guard dropped → X3 · F7 task_nodes USING narrowed → X5c · F8 board column reads `can_edit_task` → V1. **Clean rerun passed.** Two harness errors on the first pass, neither the fixture's: five injections died on a syntax error (my extraction dropped the function's `;`), and F4 went red at O2 with an unnamed error — so O1–O3 now name themselves; F8's first version broke `can_write_task` itself and went red at O2 (correct, but it didn't isolate the column), so it was redone as a view-only change |
| `db/gate.py --offline` | `GATE_OFFLINE_EXIT=0`, 51s |
| live dry run, `COMMIT`→`ROLLBACK` | **first attempt aborted** (syntax error: the five new function files lacked the `;` after `$function$` that files carrying a `COMMENT` need; committed nothing — 0 new functions on live afterwards). Fixed in the mirrors, migration regenerated from them; **second dry run: all 7 self-checks passed, 0 new functions remained** |
| backup | `BACKUP_EXIT=0` (the script's own line): `evoltrya-backup-2026-09-23-1507.dump`, 4.5M, TOC 5,966 (previous 5,931, floor 5,337) |
| preflight | 5 CREATE FUNCTION: 0 replaced · 5 new; no account codes |
| `db/apply_migration.sh` | `APPLY_OWN_EXIT=0`; `APR4 自证七条全过`. BEFORE/AFTER: approvals `t`/`t` · approval_log 14/14 · tasks 20/20 · cfo 5 codes/5 codes |
| types | `NOTIFY pgrst`, then `db/wait_for.sh` until the file had `can_write_task` and `may_write` (11s). Diff +7 lines, identical to what the pre-migration hand edit had assumed |
| `npx tsc --noEmit` | `TSC_OWN_EXIT=0` |
| `npm run build` | `BUILD_OWN_EXIT=0` (also green before the migration) |
| `db/gate.py` full | `GATE_EXIT=0`: all four verdicts green (rebuildability · mirrors vs live · fixtures, including 207 · anonymous surface, baseline 327), wall-clock 480s |
| `check-i18n` · `check-error-swallowing` | `I18N_OWN_EXIT=0` · `SWALLOW_OWN_EXIT=0` (0 unallowed) |
| smoke (detached) | `SMOKE_EXIT=0` (the script's own line, via `db/run_detached.sh`): 232 routes plus probes, **251 ok, 6 skipped (no data), 0 FAILED**. Nothing left behind — `.ephemeral` empty, no lock, and **0 `smoke-*` accounts / 0 active grants** (read as `postgres` from base tables `auth.users` + `user_roles`), so the reap tool had nothing to do |

---

## §4 · Live proof — one transaction, ROLLBACK, identity at each block

**Connection:** `postgres`, `rolbypassrls = t`. Each block sets `request.jwt.claims` and `SET LOCAL ROLE authenticated`,
and prints its own control.

| block | identity (control) | result |
|---|---|---|
| Vince | `authenticated` + JWT; `auth.uid()` = vince **t**; `tasks.edit` **f**, `tasks.view` **t** | V1 create own personal → **ok (TASK-2026-0202, rolled back)** · V2 edit header/status → **1 row** · V3 add + tick a step → **1 row** · board: own task `may_write = t`, `may_manage = f`; TASK-2026-0006 `f`/`f` |
| Vince refusals | same | promote own → `PERMISSION_DENIED|module.tasks.edit` · add participant → `PERMISSION_DENIED|module.tasks.edit` · change owner → `TASK_OWNER_IMMUTABLE|TASK-2026-0202` · edit TASK-2026-0006 (**he is a participant**) → `PERMISSION_DENIED|module.tasks.edit` (not a silent zero) · create for Sandra → `TASK_OWNER_NOT_SELF` · create a team task → `PERMISSION_DENIED|module.tasks.edit` |
| chooer (Q6) | `authenticated` + JWT; `auth.uid()` = chooer **t**; `tasks.edit` **t** | create a team task owned by Sandra → **`TASK_OWNER_NOT_SELF`** (before: succeeded) · transfer own team task to Sandra → **`TASK_OWNER_IMMUTABLE|TASK-2026-0206`** (before: succeeded) |
| chooer, E3 | same | edit **TASK-2026-0181** (he is not on it; `may_write = f`) → **`TASK_NOT_EDITABLE|TASK-2026-0181`** (before: silent 0 rows) |

⚠ **One arm of my first proof run was mislabelled, and the correction is recorded rather than hidden.** It pointed E3 at
TASK-2026-0006 on the belief that chooer was not on it; it returned "NOT REFUSED". **Read from `task_participants` (base
table, `postgres`): chooer (EMP-2026-0001) is an active participant of TASK-2026-0006** (he left once on 2026-08-19 and was
re-added). So "not refused" was correct and the label was wrong. E3 was re-run against TASK-2026-0181 (only admin on it),
in its own rolled-back transaction — the row above.

**Before and after** (read as `postgres` from base tables):

| reading | before migration | after migration, before proof | after the proof's ROLLBACK |
|---|---|---|---|
| `approvals_enabled` | t | t | **t** |
| `approval_log` rows | 14 | 14 | **14** |
| purchase orders pending | 0 | 0 | 0 |
| expense claims submitted | 1 | 1 | 1 |
| leave pending | 2 | 2 | 2 |
| medical claims submitted | 0 | 0 | 0 |
| reviews submitted | 0 | 0 | 0 |
| stocktakes open | 5 | 5 | 5 |
| work orders draft | 0 | 0 | 0 |
| tasks | 20 | 20 | **20** (22 inside the proof transaction) |
| TASK-2026-0006 / 0181 status | in_progress / todo | — | in_progress / todo |
| `cfo` codes | 5 (incl. `module.purchasing.view`) | 5 | **5** |

Nothing is left pending on live: no approval chain was touched, and every scratch row was rolled back.

---

## §5 · Claims measured and found false (AGENTS.md requires this section)

1. ★★★ **Batch B: "`cfo`'s grants on live are exactly `data.view_prices` and `module.finance.view` — Measured"** — false;
   five codes, never measured (§0).
2. ★★ **APR-0 §6.2: APR-4's five documents are wireable "without any new routing ruling"** — true about routing, beside the
   point: none has a waiting state (§1).
3. ★ **The grilling's Q6(ii): "an editor can almost certainly hand a personal task to someone else"** (inferred) — false for
   personal tasks (already refused, unnamed); **true for team tasks** (§2).
4. ★ **The survey's "freight reversal … a period lock may refuse it"** — not the real consequence; the reversal lands in
   today's period, not the document's, and raises nothing (`docs/known-issues.md`).
5. ★ **My own E3 label** — chooer is on TASK-2026-0006 (§4).
6. ★ **The survey: "disposal is refused on both live assets"** — only FA-2026-0002 (zero cost) is refused; FA-2026-0001 would post.

**Confirmed true (recorded because a re-check is also a measurement):** `approvals_enabled = t`; `CLM-2026-0004` still
`submitted`; the tasks module had no system-created rows (0 functions insert into `tasks`); Vince owns 0 tasks and is a
participant on TASK-2026-0006.

---

## §6 · Commit, push, three SHAs
Reported in the terminal at push time. **Broken window: start 2026-09-23 15:19:53 CST, end ≤ 15:54:19 CST — an upper bound (Tim relayed "deployed"; the clock reading is INB-PAY-1's), so ≤ 34 min 26 s.**
